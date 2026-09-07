const std = @import("std");
const core = @import("sprts_core");
const z = @import("zchema");
const domain = core.domain;
const leagues = core.leagues;
const dates = core.date;
const router = @import("router.zig");

/// Classic box: 52 terminal columns, 50 between the borders.
const default_inner_width = 50;

pub fn json(allocator: std.mem.Allocator, board: domain.Scoreboard) ![]u8 {
    // Validate against the schema derived from the domain types before
    // rendering. A normalization bug becomes a 502 upstream error instead of
    // silently shipping invalid JSON. Validation scratch lives in a temporary
    // arena so `std.testing.allocator` tests don't leak.
    {
        var tmp = std.heap.ArenaAllocator.init(allocator);
        defer tmp.deinit();
        const validation_json = try z.serializeAndValidate(domain.Scoreboard, tmp.allocator(), board, true);
        _ = validation_json;
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(board, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// `width` is total terminal columns; the borders take 2. Never shrinks
/// below the classic 52-wide box, so team art and the fixed participant
/// cells always fit — extra room stretches the flexible rows and names.
/// `height` caps the games listed (`+N more` trailer); null/0 = all.
pub fn text(allocator: std.mem.Allocator, board: domain.Scoreboard, color: bool, width: ?u16, height: ?u16) ![]u8 {
    const inner: usize = @min(@max(width orelse 52, 52), 200) - 2;
    const shown: usize = @min(height orelse board.games.len, board.games.len);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const table = Table{ .writer = w, .inner = inner, .color = color };
    try table.rule(.top);
    const heading = try std.fmt.allocPrint(allocator, "{s}  {s}", .{ board.league_name, board.date });
    defer allocator.free(heading);
    try table.row(heading, "2");
    if (board.games.len == 0) {
        try table.rule(.mid);
        try table.row("No games scheduled.", null);
    }
    for (board.games[0..shown]) |game| {
        try table.rule(.mid);
        try table.row(game.status, statusColor(game.state));
        try writeGameMarks(w, allocator, board.league, &game, inner);
        if (game.participants.len == 0) {
            try table.row(game.name, null);
        }
        for (game.participants) |participant| {
            try table.participantRow(participant);
        }
    }
    if (shown < board.games.len) {
        const more = try std.fmt.allocPrint(allocator, "+{d} more", .{board.games.len - shown});
        defer allocator.free(more);
        try table.rule(.mid);
        try table.row(more, "2");
    }
    try table.rule(.bottom);
    const previous = try dates.shift(allocator, board.date, -1);
    defer allocator.free(previous);
    const next = try dates.shift(allocator, board.date, 1);
    defer allocator.free(next);
    try w.print("/{s}?date={s}    /{s}?date={s}\n", .{
        board.league,
        previous,
        board.league,
        next,
    });
    return out.toOwnedSlice();
}

fn statusColor(state: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, state, "in")) return "1;31";
    if (std.mem.eql(u8, state, "pre")) return "33";
    return null;
}

/// Both teams' marks side by side at `.xs`: a horizontal card instead of
/// a tall stacked block. A side with no mark is skipped; if the pair is
/// wider than the box, the marks stack vertically.
fn writeGameMarks(w: *std.Io.Writer, allocator: std.mem.Allocator, league: []const u8, game: *const domain.Game, inner: usize) !void {
    var marks: [2][]const u8 = undefined;
    var n: usize = 0;
    for (game.participants) |p| {
        if (n == marks.len) break;
        if (core.art.teamArt(league, p.abbreviation, .xs)) |mark| {
            marks[n] = mark;
            n += 1;
        }
    }
    if (n == 0) return;

    var rows: [2]std.ArrayList([]const u8) = .{ .empty, .empty };
    defer for (rows[0..n]) |*r| r.deinit(allocator);
    var widths: [2]usize = .{ 0, 0 };
    for (marks[0..n], 0..) |mark, i| {
        var lines = std.mem.splitScalar(u8, mark, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            widths[i] = @max(widths[i], countCells(line));
            try rows[i].append(allocator, line);
        }
    }

    const gap: usize = 2;
    if (n < 2 or widths[0] + gap + widths[1] > inner - 2) {
        for (marks[0..n]) |mark| {
            var lines = std.mem.splitScalar(u8, mark, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                try writeArtRow(w, line, inner);
            }
        }
        return;
    }
    const height = @max(rows[0].items.len, rows[1].items.len);
    for (0..height) |r| {
        try w.writeAll("│ ");
        for (0..2) |i| {
            if (i == 1) {
                var g: usize = 0;
                while (g < gap) : (g += 1) try w.writeByte(' ');
            }
            const line = if (r < rows[i].items.len) rows[i].items[r] else "";
            try w.writeAll(line);
            var pad: usize = widths[i] - countCells(line);
            while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        }
        var fill: usize = inner - 2 - (widths[0] + gap + widths[1]);
        while (fill > 0) : (fill -= 1) try w.writeByte(' ');
        try w.writeAll(" │\n");
    }
}

/// Terminal cells in a line. The tool guarantees single-cell glyphs, so
/// code points are cells; on invalid UTF-8 fall back to bytes.
fn countCells(line: []const u8) usize {
    var view = std.unicode.Utf8View.init(line) catch return line.len;
    var cells: usize = 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |_| cells += 1;
    return cells;
}

/// Art rows are braille: 3 bytes per glyph but one terminal cell each, so
/// byte-based writeCell would slice glyphs and break the rules. Count code
/// points instead; the tool guarantees single-cell glyphs.
fn writeArtRow(w: *std.Io.Writer, line: []const u8, inner: usize) !void {
    try w.writeAll("│ ");
    try w.writeAll(line);
    var i: usize = countCells(line);
    while (i < inner - 2) : (i += 1) try w.writeByte(' ');
    try w.writeAll(" │\n");
}

fn writeParticipantRow(w: *std.Io.Writer, participant: domain.Participant, color: bool, inner: usize) !void {
    const table = Table{ .writer = w, .inner = inner, .color = color };
    try table.participantRow(participant);
}

pub const Rule = enum { top, mid, bottom };

pub const Table = struct {
    writer: *std.Io.Writer,
    inner: usize,
    color: bool,

    pub fn rule(self: Table, which: Rule) !void {
        try writeRule(self.writer, which, self.inner);
    }

    pub fn row(self: Table, line: []const u8, code: ?[]const u8) !void {
        try writeRow(self.writer, line, self.inner - 2, code, self.color);
    }

    pub fn participantRow(self: Table, participant: domain.Participant) !void {
        const mark: ?[]const u8 = if (participant.winner) "32" else null;
        const w = self.writer;
        const inner = self.inner;
        const suffix_len: usize = if (participant.record) |record|
            2 + countCells(record) + 1
        else
            0;
        try w.writeAll("│ ");
        // Fixed cells around the name: abbr 4 + spaces 2 + score 4 + check 2.
        var name_width: usize = undefined;
        if (participant.abbreviation.len > 0) {
            try writeCell(w, participant.abbreviation, 4, mark, self.color);
            try w.writeByte(' ');
            name_width = inner - 2 - 12;
        } else {
            // Athlete identities carry no abbreviation: the name absorbs
            // the abbr cell plus its separator.
            name_width = inner - 2 - 7;
        }
        name_width = name_width -| suffix_len;
        try writeCell(w, participant.name, name_width, mark, self.color);
        try w.writeByte(' ');
        try writeCellRight(w, participant.score, 4, mark, self.color);
        if (participant.record) |record| {
            const use_color = self.color and mark != null;
            if (use_color) try w.print("\x1b[{s}m", .{mark.?});
            try w.writeAll(" (");
            try w.writeAll(record);
            try w.writeByte(')');
            if (use_color) try w.writeAll("\x1b[0m");
        }
        if (participant.winner) {
            if (self.color) try w.writeAll("\x1b[32m");
            try w.writeAll(" ✓");
            if (self.color) try w.writeAll("\x1b[0m");
        } else {
            try w.writeAll("  ");
        }
        try w.writeAll(" │\n");
    }
};

pub fn writeRow(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    try w.writeAll("│ ");
    try writeCell(w, s, width, code, color);
    try w.writeAll(" │\n");
}

pub fn writeRule(w: *std.Io.Writer, which: Rule, inner: usize) !void {
    const left: []const u8 = switch (which) {
        .top => "┌",
        .mid => "├",
        .bottom => "└",
    };
    const right: []const u8 = switch (which) {
        .top => "┐\n",
        .mid => "┤\n",
        .bottom => "┘\n",
    };
    try w.writeAll(left);
    var i: usize = 0;
    while (i < inner) : (i += 1) try w.writeAll("─");
    try w.writeAll(right);
}

/// Writes `s` fitted to exactly `width` cells, truncating at a code point
/// boundary with an ellipsis when too long. Escape bytes are never part of
/// the width: color wraps the fitted bytes only.
pub fn writeCell(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    const end, const ellipsis = fit(s, width);
    const use_color = color and code != null;
    if (use_color) try w.print("\x1b[{s}m", .{code.?});
    try w.writeAll(s[0..end]);
    if (ellipsis) try w.writeAll("…");
    if (use_color) try w.writeAll("\x1b[0m");
    const n_written: usize = countCells(s[0..end]) + (if (ellipsis) @as(usize, 1) else 0);
    var i: usize = n_written;
    while (i < width) : (i += 1) try w.writeByte(' ');
}

fn writeCellRight(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    const end, const ellipsis = fit(s, width);
    const use_color = color and code != null;
    const n_written: usize = countCells(s[0..end]) + (if (ellipsis) @as(usize, 1) else 0);
    var spaces: usize = width -| n_written;
    while (spaces > 0) : (spaces -= 1) try w.writeByte(' ');
    if (use_color) try w.print("\x1b[{s}m", .{code.?});
    try w.writeAll(s[0..end]);
    if (ellipsis) try w.writeAll("…");
    if (use_color) try w.writeAll("\x1b[0m");
}

/// Fits `s` into `width` columns, truncating at a code point boundary
/// with an ellipsis when too long. Unchanged byte-budget truncation:
/// only the padding in the callers moved from bytes to cells.
pub fn fit(s: []const u8, width: usize) struct { usize, bool } {
    if (s.len <= width) return .{ s.len, false };
    if (width < 4) return .{ 0, true };
    var end: usize = width - 3;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return .{ end, true };
}

fn colorize(w: *std.Io.Writer, code: []const u8, s: []const u8, enabled: bool) !void {
    if (!enabled) {
        try w.writeAll(s);
        return;
    }
    try w.print("\x1b[{s}m", .{code});
    try w.writeAll(s);
    try w.writeAll("\x1b[0m");
}

pub fn home(allocator: std.mem.Allocator, color: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try colorize(w, "2", "sprts\n", color);
    try writeRule(w, .top, default_inner_width);
    for (leagues.all) |league| {
        try w.writeAll("│ ");
        try writeCell(w, league.slug, 13, null, color);
        try w.writeByte(' ');
        try writeCell(w, league.name, 34, null, color);
        try w.writeAll(" │\n");
    }
    try writeRule(w, .bottom, default_inner_width);
    try colorize(w, "2", "Try: curl localhost:8080/mlb\n", color);
    return out.toOwnedSlice();
}

/// Minimal browser page: the same table as text, never ANSI, with real
/// links. Browsers cannot use terminal escapes, so HTML output is always
/// uncolored and the text renderer stays the single source of layout.
pub fn scoreHtml(allocator: std.mem.Allocator, board: domain.Scoreboard, width: ?u16, height: ?u16) ![]u8 {
    const body = try text(allocator, board, false, width, height);
    defer allocator.free(body);
    const previous = try dates.shift(allocator, board.date, -1);
    defer allocator.free(previous);
    const next = try dates.shift(allocator, board.date, 1);
    defer allocator.free(next);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const title = try std.fmt.allocPrint(allocator, "{s} scores", .{board.league_name});
    defer allocator.free(title);
    try pageHead(w, title);
    try w.writeAll("<pre>");
    try escapeInto(w, body);
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/{s}?date={s}\">earlier</a>", .{ board.league, previous });
    try w.print("<a href=\"/{s}\">today</a>", .{board.league});
    try w.print("<a href=\"/{s}?date={s}\">later</a>", .{ board.league, next });
    try w.print("<a href=\"/api/v1/{s}?date={s}\">json</a>", .{ board.league, board.date });
    try w.writeAll("</nav></main></body></html>");
    return out.toOwnedSlice();
}

pub fn homeHtml(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try pageHead(w, "sprts");
    try w.writeAll("<pre>sprts\n");
    try writeRule(w, .top, default_inner_width);
    for (leagues.all) |league| {
        try w.writeAll("│ ");
        try w.print("<a href=\"/{s}\">", .{league.slug});
        try writeCell(w, league.slug, 13, null, false);
        try w.writeByte(' ');
        try writeCell(w, league.name, 34, null, false);
        try w.writeAll("</a> │\n");
    }
    try writeRule(w, .bottom, default_inner_width);
    try w.writeAll("Try: curl localhost:8080/mlb\n");
    try w.writeAll("</pre><nav><a href=\"/api/v1/leagues\">json</a></nav></main></body></html>");
    return out.toOwnedSlice();
}

pub fn pageHead(w: *std.Io.Writer, title: []const u8) !void {
    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>");
    try escapeInto(w, title);
    try w.writeAll("</title>" ++ page_style ++ "</head><body><main>");
}

pub fn escapeInto(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(byte),
    };
}

const page_style =
    \\<style>html,body{margin:0;background:#10140f;color:#e6ebe7}main{max-width:640px;margin:auto;padding:20px 14px}pre{margin:0;font:14px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;word-wrap:break-word}nav{margin-top:14px;display:flex;gap:16px;font:14px ui-monospace,monospace}a{color:#6fd3a0}</style>
;

pub fn leaguesJson(allocator: std.mem.Allocator) ![]u8 {
    const list = leagues.LeagueList{ .leagues = &leagues.all };
    {
        var tmp = std.heap.ArenaAllocator.init(allocator);
        defer tmp.deinit();
        _ = try z.serializeAndValidate(leagues.LeagueList, tmp.allocator(), list, true);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(list, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn errorBody(allocator: std.mem.Allocator, message: []const u8, format: router.Format) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    switch (format) {
        .text => try out.writer.print("sprts: {s}\n", .{message}),
        .html => {
            try pageHead(&out.writer, "sprts error");
            try out.writer.writeAll("<pre>sprts: ");
            try escapeInto(&out.writer, message);
            try out.writer.writeAll("</pre><nav><a href=\"/\">leagues</a></nav></main></body></html>");
        },
        .json => {
            try out.writer.writeAll("{\"error\":");
            try std.json.Stringify.value(message, .{}, &out.writer);
            try out.writer.writeAll("}\n");
        },
    }
    return out.toOwnedSlice();
}

test "JSON renderer exposes stable schema marker" {
    const board: domain.Scoreboard = .{ .league = "mlb", .league_name = "MLB", .date = "2026-09-06", .source = "test", .games = &.{} };
    const output = try json(std.testing.allocator, board);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"schema_version\": \"1\"") != null);
}

test "text renderer draws a table and no HTML" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<html") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
}

test "text renderer colors by default and strips with the flag off" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "in",
                .status = "Top 7th",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "0", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "3", .winner = true },
                },
            },
        },
    };
    const colored = try text(std.testing.allocator, board, true, null, null);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[1;31m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[32m") != null);
    const plain = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
}

test "text renderer never splits a code point when truncating" {
    const board: domain.Scoreboard = .{
        .league = "laliga",
        .league_name = "La Liga",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Atletico Madrid at a team with a very long name indeed",
                .starts_at = "2026-09-06T17:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "a", .name = "Atlético Madrid Club de Fútbol with extra", .abbreviation = "ATM", .score = "", .winner = false },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    _ = try std.unicode.Utf8View.init(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "…") != null);
}

test "HTML pages link and never carry ANSI" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final <OT>",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const page = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb?date=2026-09-05\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/api/v1/mlb?date=2026-09-06\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Final &lt;OT&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);

    const homepage = try homeHtml(std.testing.allocator);
    defer std.testing.allocator.free(homepage);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "<a href=\"/mlb\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "\x1b[") == null);

    const err = try errorBody(std.testing.allocator, "a<b", .html);
    defer std.testing.allocator.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "a&lt;b") != null);
}

fn expectAlignedTable(output: []const u8) !void {
    // Every table line (rules and rows) must share one display width, or
    // the right border drifts. Byte length is the wrong check: one box
    // rule is 3 bytes per column. Widths here count columns per code
    // point (Latin and box characters are narrow, astral pair output
    // counts wide). Header, hint, and navigation lines live outside the
    // table and are skipped.
    var width: ?usize = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != 0xE2) continue;
        const w = displayWidth(line);
        if (width) |first| {
            try std.testing.expectEqual(first, w);
        } else {
            width = w;
        }
        count += 1;
    }
    try std.testing.expect(count > 0);
}

fn displayWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            w += 1;
            i += 1;
        } else if (b & 0xE0 == 0xC0) {
            w += 1;
            i += 2;
        } else if (b & 0xF0 == 0xE0) {
            w += 1;
            i += 3;
        } else {
            w += 2;
            i += 4;
        }
    }
    return w;
}

test "home table rows align with the frame" {
    const output = try home(std.testing.allocator, false);
    defer std.testing.allocator.free(output);
    try expectAlignedTable(output);
}

test "scoreboard table rows align with the frame" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    try expectAlignedTable(output);
}

test "text renderer prints both marks side by side" {
    const home_mark = core.art.teamArt("mlb", "PHI", .xs).?;
    const home_first = home_mark[0..std.mem.indexOfScalar(u8, home_mark, '\n').?];
    const away_mark = core.art.teamArt("mlb", "NYM", .xs).?;
    const away_first = away_mark[0..std.mem.indexOfScalar(u8, away_mark, '\n').?];
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "PHI at NYM",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "1", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = true },
                    .{ .id = "2", .name = "New York Mets", .abbreviation = "NYM", .score = "3", .winner = false },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    // Both first rows land on the same output line: horizontal card.
    var found = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, home_first) != null and
            std.mem.indexOf(u8, line, away_first) != null) found = true;
    }
    try std.testing.expect(found);
    _ = try std.unicode.Utf8View.init(output);
}

test "text renderer prints no mark for teams without one" {
    const mark = core.art.teamArt("mlb", "PHI", .xs).?;
    const first_line = mark[0..std.mem.indexOfScalar(u8, mark, '\n').?];
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, first_line) == null);
}

test "athlete-style rows show the full name with an empty abbr cell" {
    const board: domain.Scoreboard = .{
        .league = "f1",
        .league_name = "F1",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Pirelli Italian Grand Prix",
                .starts_at = "2026-09-06T10:30Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "5498", .name = "Charles Leclerc", .abbreviation = "", .score = "#1", .winner = false },
                    .{ .id = "868", .name = "Lewis Hamilton", .abbreviation = "", .score = "#2", .winner = true },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Charles Leclerc") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Lewis Hamilton") != null);
    // Empty abbr cell + separator shift the name over, never truncated.
    var abbr_ellipsis = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Leclerc") != null or
            std.mem.indexOf(u8, line, "Hamilton") != null)
        {
            abbr_ellipsis = abbr_ellipsis or (std.mem.indexOf(u8, line, "…") != null);
        }
    }
    try std.testing.expect(!abbr_ellipsis);
    try expectAlignedTable(output);
}

test "records render after the score in team rows" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false, .record = "69-74" },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, " (69-74)") != null);
    try expectAlignedTable(output);
}

test "multibyte names keep the frame aligned" {
    const board: domain.Scoreboard = .{
        .league = "f1",
        .league_name = "F1",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Pirelli Italian Grand Prix",
                .starts_at = "2026-09-06T10:30Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "27", .name = "Nico Hülkenberg", .abbreviation = "", .score = "#7", .winner = false },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hülkenberg") != null);
    try expectAlignedTable(output);
}

fn testBoard() domain.Scoreboard {
    return .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
            .{
                .id = "2",
                .name = "Second at Third",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "c", .name = "Second", .abbreviation = "SEC", .score = "", .winner = false },
                    .{ .id = "d", .name = "Third", .abbreviation = "THI", .score = "", .winner = false },
                },
            },
            .{
                .id = "3",
                .name = "Fourth at Fifth",
                .starts_at = "2026-09-06T21:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "e", .name = "Fourth", .abbreviation = "FOU", .score = "", .winner = false },
                    .{ .id = "f", .name = "Fifth", .abbreviation = "FIF", .score = "", .winner = false },
                },
            },
        },
    };
}

test "text renderer honors an explicit width" {
    const board = testBoard();
    const wide = try text(std.testing.allocator, board, false, 80, null);
    defer std.testing.allocator.free(wide);
    // Top rule: ┌ + 78 × ─ + ┐\n.
    const eol = std.mem.indexOfScalar(u8, wide, '\n').?;
    try std.testing.expectEqual(@as(usize, 3 + 78 * 3 + 3), eol);
    _ = try std.unicode.Utf8View.init(wide);

    // Narrow requests never shrink below the classic 52-wide box.
    const narrow = try text(std.testing.allocator, board, false, 40, null);
    defer std.testing.allocator.free(narrow);
    const narrow_eol = std.mem.indexOfScalar(u8, narrow, '\n').?;
    try std.testing.expectEqual(@as(usize, 3 + 50 * 3 + 3), narrow_eol);
}

test "text renderer caps games with height and counts the rest" {
    const board = testBoard();
    const capped = try text(std.testing.allocator, board, false, null, 2);
    defer std.testing.allocator.free(capped);
    try std.testing.expect(std.mem.indexOf(u8, capped, "Final") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "+1 more") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "Fourth at Fifth") == null);
    _ = try std.unicode.Utf8View.init(capped);

    const all = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "more") == null);
}
