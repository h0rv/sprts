const std = @import("std");
const core = @import("sprts_core");
const z = @import("zchema");
const domain = core.domain;
const leagues = core.leagues;
const dates = core.date;
const router = @import("router.zig");

const inner_width = 50;

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

pub fn text(allocator: std.mem.Allocator, board: domain.Scoreboard, color: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try writeRule(w, .top);
    const heading = try std.fmt.allocPrint(allocator, "{s}  {s}", .{ board.league_name, board.date });
    defer allocator.free(heading);
    try writeRow(w, heading, inner_width - 2, "2", color);
    if (board.games.len == 0) {
        try writeRule(w, .mid);
        try writeRow(w, "No games scheduled.", inner_width - 2, null, color);
    }
    for (board.games) |game| {
        try writeRule(w, .mid);
        try writeRow(w, game.status, inner_width - 2, statusColor(game.state), color);
        if (teamArtForGame(board.league, &game)) |mark| {
            var lines = std.mem.splitScalar(u8, mark, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                try writeArtRow(w, line);
            }
        }
        if (game.participants.len == 0) {
            try writeRow(w, game.name, inner_width - 2, null, color);
        }
        for (game.participants) |participant| {
            try writeParticipantRow(w, participant, color);
        }
    }
    try writeRule(w, .bottom);
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

fn teamArtForGame(league_slug: []const u8, game: *const domain.Game) ?[]const u8 {
    for (game.participants) |participant| {
        if (core.art.teamArt(league_slug, participant.abbreviation, .sm)) |mark| return mark;
    }
    return null;
}

/// Art rows are braille: 3 bytes per glyph but one terminal cell each, so
/// byte-based writeCell would slice glyphs and break the rules. Count code
/// points instead; the tool guarantees single-cell glyphs.
fn writeArtRow(w: *std.Io.Writer, line: []const u8) !void {
    try w.writeAll("│ ");
    try w.writeAll(line);
    var cells: usize = 0;
    var view = std.unicode.Utf8View.init(line) catch return error.InvalidArt;
    var it = view.iterator();
    while (it.nextCodepoint()) |_| cells += 1;
    var i: usize = cells;
    while (i < inner_width - 2) : (i += 1) try w.writeByte(' ');
    try w.writeAll(" │\n");
}

fn writeParticipantRow(w: *std.Io.Writer, participant: domain.Participant, color: bool) !void {
    const mark: ?[]const u8 = if (participant.winner) "32" else null;
    try w.writeAll("│ ");
    try writeCell(w, participant.abbreviation, 4, mark, color);
    try w.writeByte(' ');
    try writeCell(w, participant.name, 36, mark, color);
    try w.writeByte(' ');
    try writeCellRight(w, participant.score, 4, mark, color);
    if (participant.winner) {
        if (color) try w.writeAll("\x1b[32m");
        try w.writeAll(" ✓");
        if (color) try w.writeAll("\x1b[0m");
    } else {
        try w.writeAll("  ");
    }
    try w.writeAll(" │\n");
}

fn writeRow(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    try w.writeAll("│ ");
    try writeCell(w, s, width, code, color);
    try w.writeAll(" │\n");
}

const Rule = enum { top, mid, bottom };

fn writeRule(w: *std.Io.Writer, which: Rule) !void {
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
    while (i < inner_width) : (i += 1) try w.writeAll("─");
    try w.writeAll(right);
}

/// Writes `s` fitted to exactly `width` bytes, truncating at a code point
/// boundary with an ellipsis when too long. Escape bytes are never part of
/// the width: color wraps the fitted bytes only.
fn writeCell(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    const end, const ellipsis = fit(s, width);
    const use_color = color and code != null;
    if (use_color) try w.print("\x1b[{s}m", .{code.?});
    try w.writeAll(s[0..end]);
    if (ellipsis) try w.writeAll("…");
    if (use_color) try w.writeAll("\x1b[0m");
    const pad: usize = end + (if (ellipsis) "...".len else 0);
    // "…" is 3 bytes; byte padding keeps the rules aligned for the
    // Latin names this server renders.
    var i: usize = pad;
    while (i < width) : (i += 1) try w.writeByte(' ');
}

fn writeCellRight(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    const end, const ellipsis = fit(s, width);
    const use_color = color and code != null;
    const pad: usize = end + (if (ellipsis) "...".len else 0);
    var spaces: usize = 0;
    while (pad + spaces < width) : (spaces += 1) {}
    while (spaces > 0) : (spaces -= 1) try w.writeByte(' ');
    if (use_color) try w.print("\x1b[{s}m", .{code.?});
    try w.writeAll(s[0..end]);
    if (ellipsis) try w.writeAll("…");
    if (use_color) try w.writeAll("\x1b[0m");
}

fn fit(s: []const u8, width: usize) struct { usize, bool } {
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
    try writeRule(w, .top);
    for (leagues.all) |league| {
        try w.writeAll("│ ");
        try writeCell(w, league.slug, 13, null, color);
        try w.writeByte(' ');
        try writeCell(w, league.name, 36, null, color);
        try w.writeAll(" │\n");
    }
    try writeRule(w, .bottom);
    try colorize(w, "2", "Try: curl localhost:8080/mlb\n", color);
    return out.toOwnedSlice();
}

/// Minimal browser page: the same table as text, never ANSI, with real
/// links. Browsers cannot use terminal escapes, so HTML output is always
/// uncolored and the text renderer stays the single source of layout.
pub fn scoreHtml(allocator: std.mem.Allocator, board: domain.Scoreboard) ![]u8 {
    const body = try text(allocator, board, false);
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
    try writeRule(w, .top);
    for (leagues.all) |league| {
        try w.writeAll("│ ");
        try w.print("<a href=\"/{s}\">", .{league.slug});
        try writeCell(w, league.slug, 13, null, false);
        try w.writeByte(' ');
        try writeCell(w, league.name, 36, null, false);
        try w.writeAll("</a> │\n");
    }
    try writeRule(w, .bottom);
    try w.writeAll("Try: curl localhost:8080/mlb\n");
    try w.writeAll("</pre><nav><a href=\"/api/v1/leagues\">json</a></nav></main></body></html>");
    return out.toOwnedSlice();
}

fn pageHead(w: *std.Io.Writer, title: []const u8) !void {
    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>");
    try escapeInto(w, title);
    try w.writeAll("</title>" ++ page_style ++ "</head><body><main>");
}

fn escapeInto(w: *std.Io.Writer, value: []const u8) !void {
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
    const output = try text(std.testing.allocator, board, false);
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
    const colored = try text(std.testing.allocator, board, true);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[1;31m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[32m") != null);
    const plain = try text(std.testing.allocator, board, false);
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
    const output = try text(std.testing.allocator, board, false);
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
    const page = try scoreHtml(std.testing.allocator, board);
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

test "text renderer prints the mark for teams that have one" {
    const mark = core.art.teamArt("mlb", "PHI", .sm).?;
    const first_line = mark[0..std.mem.indexOfScalar(u8, mark, '\n').?];
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
    const output = try text(std.testing.allocator, board, false);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, first_line) != null);
    _ = try std.unicode.Utf8View.init(output);
}

test "text renderer prints no mark for teams without one" {
    const mark = core.art.teamArt("mlb", "PHI", .sm).?;
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
    const output = try text(std.testing.allocator, board, false);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, first_line) == null);
}
