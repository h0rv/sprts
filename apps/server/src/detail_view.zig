//! Per-game detail renderer (wt-detail).
//!
//! Built ONLY on the shared `table.zig` box primitives (`writeCell`,
//! `writeRow`, `writeRule`, `writeCellRight`, `fit`). Layout mirrors the
//! scoreboard box rules (52-min columns, `+N more` trailer for scoring
//! plays via `height`): header (teams + score + status + venue/attendance),
//! linescore grid (period columns + R/H/E), live situation chip, decisions
//! + probables, scoring plays (latest 5), series line.

const std = @import("std");
const core = @import("sprts_core");
const z = @import("zchema");
const detail = core.detail;
const router = @import("router.zig");
const render = @import("render.zig");
const table = @import("table.zig");
const tz = @import("tz.zig");
const writeCell = table.writeCell;
const writeCellRight = table.writeCellRight;
const writeRow = table.writeRow;
const writeRule = table.writeRule;

/// Classic box: 52 terminal columns, 50 between the borders.
const default_inner_width = 50;

pub fn json(allocator: std.mem.Allocator, game: detail.GameDetail) ![]u8 {
    // Validated through the shared `render.validatedJson` gate — see it
    // for why strict `z.serializeAndValidate` is unusable process-wide
    // (zchema's `cachedCompiled` cross-type cache bug, coordinator-owned
    // upstream fix). Same wire format as before, field for field.
    return render.validatedJson(detail.GameDetail, allocator, game);
}

/// `width` is total terminal columns; the borders take 2. Never shrinks
/// below the classic 52-wide box. `height` caps the scoring plays listed
/// (`+N more` trailer); null/0 = latest 5.
pub fn renderText(allocator: std.mem.Allocator, game: detail.GameDetail, color: bool, width: ?u16, height: ?u16) ![]u8 {
    const inner: usize = @min(@max(width orelse 52, 52), 200) - 2;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try writeRule(w, .top, inner);
    // one-line: heading gains the zone label via `tz.labelFor` (ET default;
    // `?tz=` plumbing stays in main/worker, which this task must not touch).
    const zone_label = try tz.labelFor(allocator, game.date, .et);
    defer allocator.free(zone_label);
    const heading = try std.fmt.allocPrint(allocator, "{s}  {s} ({s})", .{ game.league_name, game.date, zone_label });
    defer allocator.free(heading);
    try writeRow(w, heading, inner - 2, "2", color);
    try writeRule(w, .mid, inner);
    try writeRow(w, game.status, inner - 2, statusColor(game.state), color);
    for (game.participants) |entry| {
        try writeDetailParticipantRow(w, entry, color, inner);
    }
    if (game.venue) |venue| {
        if (game.attendance) |crowd| {
            const line = try std.fmt.allocPrint(allocator, "{s} ({d})", .{ venue, crowd });
            defer allocator.free(line);
            try writeRow(w, line, inner - 2, null, color);
        } else {
            try writeRow(w, venue, inner - 2, null, color);
        }
    } else if (game.attendance) |crowd| {
        const line = try std.fmt.allocPrint(allocator, "Attendance {d}", .{crowd});
        defer allocator.free(line);
        try writeRow(w, line, inner - 2, null, color);
    }
    if (maxPeriod(game) > 0) {
        try writeRule(w, .mid, inner);
        try writeLineScore(w, allocator, game, inner, color);
    }
    if (game.situation) |situation| {
        try writeRule(w, .mid, inner);
        const chip = try situationText(allocator, situation);
        defer allocator.free(chip);
        try writeRow(w, chip, inner - 2, "1;31", color);
        if (situation.last_play) |last| try writeRow(w, last, inner - 2, null, color);
    }
    if (game.decisions.len > 0 or hasProbables(game)) {
        try writeRule(w, .mid, inner);
        for (game.decisions) |decision| {
            const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ decision.outcome, decision.name });
            defer allocator.free(line);
            try writeRow(w, line, inner - 2, null, color);
        }
        for (game.participants) |entry| {
            if (entry.probable) |starter| {
                const line = try std.fmt.allocPrint(allocator, "SP {s}: {s}", .{ entry.abbreviation, starter });
                defer allocator.free(line);
                try writeRow(w, line, inner - 2, null, color);
            }
        }
    }
    if (game.scoring_plays.len > 0) {
        try writeRule(w, .mid, inner);
        try writeRow(w, "Scoring plays", inner - 2, "2", color);
        const limit: usize = @min(height orelse 5, game.scoring_plays.len);
        const start = game.scoring_plays.len - limit;
        for (game.scoring_plays[start..]) |play| {
            const line = try std.fmt.allocPrint(allocator, "{s} {s}-{s} {s}", .{ play.period, play.away_score, play.home_score, play.text });
            defer allocator.free(line);
            try writeRow(w, line, inner - 2, null, color);
        }
        if (start > 0) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more", .{start});
            defer allocator.free(more);
            try writeRow(w, more, inner - 2, "2", color);
        }
    }
    if (game.leaders.len > 0) {
        try writeRule(w, .mid, inner);
        try writeRow(w, "Leaders", inner - 2, "2", color);
        for (game.leaders[0..@min(game.leaders.len, 8)]) |leader| {
            try writeRow(w, leader, inner - 2, null, color);
        }
    }
    if (game.series) |series| {
        try writeRule(w, .mid, inner);
        const series_line = try std.fmt.allocPrint(allocator, "Series: {s}", .{series});
        defer allocator.free(series_line);
        try writeRow(w, series_line, inner - 2, null, color);
    }
    try writeRule(w, .bottom, inner);
    const back = try std.fmt.allocPrint(allocator, "/{s}?date={s}\n", .{ game.league, game.date });
    defer allocator.free(back);
    try w.writeAll(back);
    return out.toOwnedSlice();
}

/// Minimal browser page: section-by-section like the text renderer,
/// never ANSI, with links. The status row links back to the league
/// scoreboard; each participant row links to its team view. Colors ride
/// as spans (live/upcoming/winner) so the web matches the terminal.
pub fn detailHtml(allocator: std.mem.Allocator, game: detail.GameDetail, width: ?u16, height: ?u16) ![]u8 {
    const inner: usize = @min(@max(width orelse 52, 52), 200) - 2;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const title = try std.fmt.allocPrint(allocator, "{s} game detail", .{game.league_name});
    defer allocator.free(title);
    try pageHead(w, title);
    try w.writeAll("<pre>");
    // one-line: heading gains the zone label via `tz.labelFor` (ET default; see renderText).
    const zone_label = try tz.labelFor(allocator, game.date, .et);
    defer allocator.free(zone_label);
    const heading = try std.fmt.allocPrint(allocator, "{s}  {s} ({s})", .{ game.league_name, game.date, zone_label });
    defer allocator.free(heading);
    try htmlRow(allocator, heading, "dim", inner, w, null);
    const status_href = try std.fmt.allocPrint(allocator, "/{s}?date={s}", .{ game.league, game.date });
    defer allocator.free(status_href);
    try htmlRow(allocator, game.status, stateClass(game.state), inner, w, status_href);
    for (game.participants) |entry| {
        const href = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ game.league, entry.abbreviation });
        defer allocator.free(href);
        const row = try participantLine(allocator, entry, inner);
        defer allocator.free(row);
        try htmlRow(allocator, row, if (entry.winner) "win" else null, inner, w, href);
    }
    if (game.venue) |venue| {
        if (game.attendance) |crowd| {
            const line = try std.fmt.allocPrint(allocator, "{s} ({d})", .{ venue, crowd });
            defer allocator.free(line);
            try htmlRow(allocator, line, null, inner, w, null);
        } else {
            try htmlRow(allocator, venue, null, inner, w, null);
        }
    } else if (game.attendance) |crowd| {
        const line = try std.fmt.allocPrint(allocator, "Attendance {d}", .{crowd});
        defer allocator.free(line);
        try htmlRow(allocator, line, null, inner, w, null);
    }
    if (maxPeriod(game) > 0) {
        const line = try lineScoreLine(allocator, game, inner);
        defer allocator.free(line);
        try htmlRow(allocator, line, null, inner, w, null);
    }
    if (game.situation) |situation| {
        const chip = try situationText(allocator, situation);
        defer allocator.free(chip);
        try htmlRow(allocator, chip, "live", inner, w, null);
        if (situation.last_play) |last| try htmlRow(allocator, last, null, inner, w, null);
    }
    if (game.decisions.len > 0 or hasProbables(game)) {
        for (game.decisions) |decision| {
            const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ decision.outcome, decision.name });
            defer allocator.free(line);
            try htmlRow(allocator, line, null, inner, w, null);
        }
        for (game.participants) |entry| {
            if (entry.probable) |starter| {
                const line = try std.fmt.allocPrint(allocator, "SP {s}: {s}", .{ entry.abbreviation, starter });
                defer allocator.free(line);
                try htmlRow(allocator, line, null, inner, w, null);
            }
        }
    }
    if (game.scoring_plays.len > 0) {
        try htmlRow(allocator, "Scoring plays", "dim", inner, w, null);
        const limit: usize = @min(height orelse 5, game.scoring_plays.len);
        const start = game.scoring_plays.len - limit;
        for (game.scoring_plays[start..]) |play| {
            const line = try std.fmt.allocPrint(allocator, "{s} {s}-{s} {s}", .{ play.period, play.away_score, play.home_score, play.text });
            defer allocator.free(line);
            try htmlRow(allocator, line, null, inner, w, null);
        }
        if (start > 0) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more", .{start});
            defer allocator.free(more);
            try htmlRow(allocator, more, "dim", inner, w, null);
        }
    }
    if (game.leaders.len > 0) {
        try htmlRow(allocator, "Leaders", "dim", inner, w, null);
        for (game.leaders[0..@min(game.leaders.len, 8)]) |leader| {
            try htmlRow(allocator, leader, null, inner, w, null);
        }
    }
    if (game.series) |series| {
        const series_line = try std.fmt.allocPrint(allocator, "Series: {s}", .{series});
        defer allocator.free(series_line);
        try htmlRow(allocator, series_line, null, inner, w, null);
    }
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/{s}?date={s}\">scores</a>", .{ game.league, game.date });
    try w.print("<a href=\"/api/v1/{s}/{s}\">json</a>", .{ game.league, game.id });
    try w.writeAll("</nav></main></body></html>");
    return out.toOwnedSlice();
}

/// One HTML table row: padded + escaped cell with optional color span
/// and link. Mirrors render.zig's writeHtmlTable (kept local: those
/// helpers are private to render.zig, see the module doc).
fn htmlRow(allocator: std.mem.Allocator, s: []const u8, css: ?[]const u8, inner: usize, w: *std.Io.Writer, link: ?[]const u8) !void {
    try w.writeAll("│ ");
    if (link) |href| {
        try w.writeAll("<a href=\"");
        try escapeInto(w, href);
        try w.writeAll("\">");
    }
    if (css) |class| {
        try w.writeAll("<span class=\"");
        try w.writeAll(class);
        try w.writeAll("\">");
    }
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try writeCell(&cell.writer, s, inner - 2, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    try escapeCellInto(w, padded);
    if (css != null) try w.writeAll("</span>");
    if (link != null) try w.writeAll("</a>");
    try w.writeAll(" │\n");
}

/// Escaped copy of a padded cell: escape `&<>"'` but pass spaces and
/// box-safe bytes through untouched.
fn escapeCellInto(w: *std.Io.Writer, cell: []const u8) !void {
    for (cell) |byte| switch (byte) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(byte),
    };
}

/// CSS class matching the ANSI role for a game state.
fn stateClass(state: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, state, "in")) return "live";
    if (std.mem.eql(u8, state, "pre")) return "upcoming";
    return null;
}

/// Plain-text participant row content (no borders, no ANSI) for the HTML
/// linker. Mirrors writeDetailParticipantRow layout.
fn participantLine(allocator: std.mem.Allocator, participant: detail.DetailParticipant, inner: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try writeCell(w, participant.abbreviation, 4, null, false);
    try w.writeByte(' ');
    try writeCell(w, participant.name, inner - 2 - 12, null, false);
    try w.writeByte(' ');
    try writeCellRight(w, participant.score, 4, null, false);
    if (participant.winner) {
        try w.writeAll(" ✓");
    } else {
        try w.writeAll("  ");
    }
    return out.toOwnedSlice();
}

/// Linescore grid as one pre-wrapped block (period columns + R/H/E).
/// The text renderer emits one row per line; HTML wraps the same lines
/// in a single cell each so the grid survives escaping.
fn lineScoreLine(allocator: std.mem.Allocator, game: detail.GameDetail, inner: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const periods = maxPeriod(game);
    var head: std.Io.Writer.Allocating = .init(allocator);
    defer head.deinit();
    try head.writer.writeAll("    ");
    var p: usize = 1;
    while (p <= periods) : (p += 1) try head.writer.print("{d:>3}", .{p});
    try head.writer.writeAll("   R   H   E");
    const head_text = try head.toOwnedSlice();
    defer allocator.free(head_text);
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.writeAll(head_text);
    for (game.participants) |entry| {
        var line: std.Io.Writer.Allocating = .init(allocator);
        defer line.deinit();
        try line.writer.print("{s:<4}", .{entry.abbreviation});
        var i: usize = 0;
        while (i < periods) : (i += 1) {
            const cell: []const u8 = if (i < entry.lines.len) entry.lines[i].display else "-";
            try line.writer.print("{s:>3}", .{cell});
        }
        try line.writer.print("   {s:>3}   {s:>3}   {s:>3}", .{
            entry.score,
            entry.hits orelse "-",
            entry.errors orelse "-",
        });
        const text = try line.toOwnedSlice();
        defer allocator.free(text);
        try body.writer.writeByte('\n');
        try body.writer.writeAll(text);
    }
    _ = inner;
    return body.toOwnedSlice();
}

fn statusColor(state: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, state, "in")) return "1;31";
    if (std.mem.eql(u8, state, "pre")) return "33";
    return null;
}

fn hasProbables(game: detail.GameDetail) bool {
    for (game.participants) |entry| if (entry.probable != null) return true;
    return false;
}

fn maxPeriod(game: detail.GameDetail) usize {
    var n: usize = 0;
    for (game.participants) |entry| n = @max(n, entry.lines.len);
    return n;
}

fn situationText(allocator: std.mem.Allocator, situation: detail.Situation) ![]u8 {
    var runners: std.Io.Writer.Allocating = .init(allocator);
    defer runners.deinit();
    if (situation.runners.len == 0) {
        try runners.writer.writeAll("bases empty");
    } else {
        for (situation.runners, 0..) |base, i| {
            if (i > 0) try runners.writer.writeAll(",");
            try runners.writer.writeAll(base);
        }
    }
    const bases = try runners.toOwnedSlice();
    defer allocator.free(bases);
    const matchup = if (situation.batter != null and situation.pitcher != null)
        try std.fmt.allocPrint(allocator, " {s} vs {s}", .{ situation.pitcher.?, situation.batter.? })
    else if (situation.batter) |batter|
        try std.fmt.allocPrint(allocator, " {s} batting", .{batter})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(matchup);
    return std.fmt.allocPrint(allocator, "{d}-{d}, {d} out, {s}{s}", .{
        situation.balls,
        situation.strikes,
        situation.outs,
        bases,
        matchup,
    });
}

/// Linescore grid: `TEAM 1 2 3 R H E`. Period columns right-align in 3 cells;
/// missing cells render `-`. R/H/E come from the last score plus hits/errors.
fn writeLineScore(w: *std.Io.Writer, allocator: std.mem.Allocator, game: detail.GameDetail, inner: usize, color: bool) !void {
    const periods = maxPeriod(game);
    var head: std.Io.Writer.Allocating = .init(allocator);
    defer head.deinit();
    try head.writer.writeAll("    ");
    var p: usize = 1;
    while (p <= periods) : (p += 1) try head.writer.print("{d:>3}", .{p});
    try head.writer.writeAll("   R   H   E");
    const head_text = try head.toOwnedSlice();
    defer allocator.free(head_text);
    try writeRow(w, head_text, inner - 2, "2", color);
    for (game.participants) |entry| {
        var line: std.Io.Writer.Allocating = .init(allocator);
        defer line.deinit();
        try line.writer.print("{s:<4}", .{entry.abbreviation});
        var i: usize = 0;
        while (i < periods) : (i += 1) {
            const cell: []const u8 = if (i < entry.lines.len) entry.lines[i].display else "-";
            try line.writer.print("{s:>3}", .{cell});
        }
        try line.writer.print("   {s:>3}   {s:>3}   {s:>3}", .{
            entry.score,
            entry.hits orelse "-",
            entry.errors orelse "-",
        });
        const text = try line.toOwnedSlice();
        defer allocator.free(text);
        const mark: ?[]const u8 = if (entry.winner) "32" else null;
        try writeRow(w, text, inner - 2, mark, color);
    }
    if (game.participants.len > 0) {
        if (game.participants[0].record) |record| {
            const line = try std.fmt.allocPrint(allocator, "{s} {s}", .{ game.participants[0].abbreviation, record });
            defer allocator.free(line);
            try writeRow(w, line, inner - 2, null, color);
        }
        if (game.participants.len > 1) {
            if (game.participants[1].record) |record| {
                const line = try std.fmt.allocPrint(allocator, "{s} {s}", .{ game.participants[1].abbreviation, record });
                defer allocator.free(line);
                try writeRow(w, line, inner - 2, null, color);
            }
        }
    }
}

fn writeDetailParticipantRow(w: *std.Io.Writer, participant: detail.DetailParticipant, color: bool, inner: usize) !void {
    const mark: ?[]const u8 = if (participant.winner) "32" else null;
    try w.writeAll("│ ");
    try writeCell(w, participant.abbreviation, 4, mark, color);
    try w.writeByte(' ');
    // Fixed cells around the name: abbr 4 + spaces 2 + score 4 + check 2.
    try writeCell(w, participant.name, inner - 2 - 12, mark, color);
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

fn testDetail() detail.GameDetail {
    return .{
        .id = "401816828",
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .venue = "Citizens Bank Park",
        .attendance = 42793,
        .series = "ATL leads 2-1 (game 3 of 4)",
        .participants = &.{
            .{
                .id = "15",
                .name = "Atlanta Braves",
                .abbreviation = "ATL",
                .score = "5",
                .winner = true,
                .home_away = "away",
                .lines = &.{
                    .{ .period = 1, .display = "0" },
                    .{ .period = 2, .display = "0" },
                    .{ .period = 8, .display = "3" },
                    .{ .period = 9, .display = "1" },
                },
                .hits = "10",
                .errors = "1",
                .record = "85-58",
                .probable = "Tyler Mahle",
            },
            .{
                .id = "22",
                .name = "Philadelphia Phillies",
                .abbreviation = "PHI",
                .score = "4",
                .winner = false,
                .home_away = "home",
                .lines = &.{
                    .{ .period = 1, .display = "2" },
                    .{ .period = 2, .display = "0" },
                    .{ .period = 7, .display = "2" },
                    .{ .period = 9, .display = "0" },
                },
                .hits = "7",
                .errors = "0",
                .record = "80-63",
                .probable = "Aaron Nola",
            },
        },
        .decisions = &.{
            .{ .outcome = "W", .name = "Dylan Lee" },
            .{ .outcome = "L", .name = "Jhoan Duran" },
            .{ .outcome = "SV", .name = "Raisel Iglesias" },
        },
        .scoring_plays = &.{
            .{ .period = "1st Inning", .text = "Arraez hit sacrifice fly to center, Schwarber scored.", .away_score = "0", .home_score = "1" },
            .{ .period = "9th Inning", .text = "Riley tripled to center, Albies scored.", .away_score = "5", .home_score = "4" },
        },
        .leaders = &.{"ATL 10-35"},
    };
}

test "detail text renders the box and all sections" {
    const output = try renderText(std.testing.allocator, testDetail(), false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Final") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Citizens Bank Park (42793)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  R   H   E") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "W: Dylan Lee") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SP PHI: Aaron Nola") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Scoring plays") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Riley tripled") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Series: ATL leads 2-1 (game 3 of 4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<html") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(output);
}

test "detail text shows the live situation chip" {
    var game = testDetail();
    game.state = "in";
    game.status = "Bot 6th";
    game.situation = .{
        .balls = 2,
        .strikes = 2,
        .outs = 2,
        .runners = &.{ "1st", "2nd" },
        .batter = "Test Batter",
        .pitcher = "Test Pitcher",
        .last_play = "Pitch 4 : Strike 2 Foul",
    };
    const output = try renderText(std.testing.allocator, game, true, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "2-2, 2 out, 1st,2nd") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Test Pitcher vs Test Batter") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Pitch 4 : Strike 2 Foul") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1;31m") != null);
}

test "detail text truncates unicode and long names without splitting" {
    var game = testDetail();
    const home: detail.DetailParticipant = game.participants[1];
    var parts = [_]core.detail.DetailParticipant{ game.participants[0], .{
        .id = home.id,
        .name = "Atlético Madrid Club de Fútbol with a very long tail indeed",
        .abbreviation = home.abbreviation,
        .score = home.score,
        .winner = home.winner,
        .home_away = home.home_away,
        .lines = game.participants[1].lines,
        .hits = game.participants[1].hits,
        .errors = game.participants[1].errors,
        .record = game.participants[1].record,
        .probable = game.participants[1].probable,
    } };
    game.participants = &parts;
    var plays = [_]core.detail.ScoringPlay{ game.scoring_plays[0], game.scoring_plays[1] };
    plays[0].text = "Acuña Jr. doubled to left with a very long description tail that keeps going";
    game.scoring_plays = &plays;
    const output = try renderText(std.testing.allocator, game, false, null, null);
    defer std.testing.allocator.free(output);
    _ = try std.unicode.Utf8View.init(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "…") != null);
}

test "detail json validates and carries the schema marker" {
    // `json()` validates through the shared `render.validatedJson` gate
    // (round-trip: types + required fields enforced). This test asserts
    // the schema marker plus a full parse-back of the wire output.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const output = try json(arena, testDetail());
    try std.testing.expect(std.mem.indexOf(u8, output, "\"schema_version\": \"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "401816828") != null);
    const parsed = try std.json.parseFromSliceLeaky(detail.GameDetail, arena, output, .{});
    try std.testing.expectEqualStrings("401816828", parsed.id);
    try std.testing.expectEqual(@as(usize, 2), parsed.participants.len);
    try std.testing.expectEqualStrings("Citizens Bank Park", parsed.venue.?);
}

test "detail html wraps in pre and links back" {
    const page = try detailHtml(std.testing.allocator, testDetail(), null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb?date=2026-09-06\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/api/v1/mlb/401816828\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    // Participant rows link to their team views, status carries no ANSI.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/ATL\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/PHI\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<span") != null);
}

test "detail error bodies reuse the shared error renderer" {
    const body = try @import("render.zig").errorBody(std.testing.allocator, "game view coming soon", .text);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "game view coming soon") != null);
}

// one-line: game-detail `?0` support. Additive section (sibling agent
// `views-depth` owns the box renderers above; only the 2-line heading
// hooks touch existing functions). The footer reuses this module's
// back-link (`/{league}?date={date}`).

/// Game-detail one-line fallback (`?0`): an optional dim heading, one
/// `{state} {status} {AWAY} {score} @ {HOME} {score}[ ✓]` game line, and
/// an optional back-link footer. Pre-game duels with no scores print
/// `{state} {status} {AWAY} @ {HOME}`; other participant counts list
/// abbrevs (`{state} {status} A,B[ ✓]`). `quiet` drops heading and footer,
/// leaving exactly the game line. Only the state token carries color;
/// zero ANSI when `color` is off. Always ends in `\n`.
pub fn renderTextOneLine(arena: std.mem.Allocator, game: detail.GameDetail, color: bool, quiet: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    const w = &out.writer;
    if (!quiet) {
        const label = try tz.labelFor(arena, game.date, .et);
        defer arena.free(label);
        const heading = try std.fmt.allocPrint(arena, "{s}  {s} ({s})\n", .{ game.league_name, game.date, label });
        defer arena.free(heading);
        try oneLineColorize(w, "2", heading, color);
    }
    try writeDetailOneLine(w, game, color);
    if (!quiet) {
        try w.print("/{s}?date={s}\n", .{ game.league, game.date });
    }
    return out.toOwnedSlice();
}

// one-line: per-game line duplicated from `help.writeScoreLine`
// (~15-line shape, attributed here instead of imported: `help.zig` owns
// the scoreboard stream and this module owns the detail stream, so a
// cross-module import would couple the two owners). Adapted: detail has
// no game `.name`, so non-duels list abbrevs.
fn writeDetailOneLine(w: *std.Io.Writer, game: detail.GameDetail, color: bool) !void {
    if (color) try w.print("\x1b[{s}m", .{oneLineStateColor(game.state)});
    try w.writeAll(game.state);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeByte(' ');
    try w.writeAll(game.status);
    if (game.participants.len == 2) {
        const first = game.participants[0];
        const second = game.participants[1];
        const away, const home_team = if (std.mem.eql(u8, second.home_away orelse "", "home"))
            .{ first, second }
        else if (std.mem.eql(u8, first.home_away orelse "", "home"))
            .{ second, first }
        else
            .{ first, second };
        if (away.score.len > 0 or home_team.score.len > 0) {
            try w.print(" {s} {s} @ {s} {s}", .{ away.abbreviation, away.score, home_team.abbreviation, home_team.score });
        } else {
            try w.print(" {s} @ {s}", .{ away.abbreviation, home_team.abbreviation });
        }
        if (away.winner or home_team.winner) try w.writeAll(" ✓");
    } else if (game.participants.len > 0) {
        for (game.participants, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte(' ');
            try w.writeAll(p.abbreviation);
        }
        var won = false;
        for (game.participants) |p| if (p.winner) {
            won = true;
            break;
        };
        if (won) try w.writeAll(" ✓");
    }
    try w.writeByte('\n');
}

// one-line: state palette duplicated from `help.stateColor` (see above).
fn oneLineStateColor(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "in")) return "1;31";
    if (std.mem.eql(u8, state, "pre")) return "33";
    return "2";
}

// one-line: dim-heading colorizer (same shape as `help.colorize`).
fn oneLineColorize(w: *std.Io.Writer, code: []const u8, s: []const u8, enabled: bool) !void {
    if (!enabled) {
        try w.writeAll(s);
        return;
    }
    try w.print("\x1b[{s}m", .{code});
    try w.writeAll(s);
    try w.writeAll("\x1b[0m");
}

// one-line: tests (append-only block; box tests above belong to views-depth).
test "detail one-line is a single game line with no box rules" {
    const output = try renderTextOneLine(std.testing.allocator, testDetail(), false, true);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("post Final ATL 5 @ PHI 4 ✓\n", output);
    _ = try std.unicode.Utf8View.init(output);
}

test "detail one-line compacts pre-game duels without scores" {
    var game = testDetail();
    var parts = [_]detail.DetailParticipant{ game.participants[0], game.participants[1] };
    parts[0].score = "";
    parts[1].score = "";
    parts[0].winner = false;
    parts[1].winner = false;
    game.participants = &parts;
    game.state = "pre";
    game.status = "7:05 PM";
    const output = try renderTextOneLine(std.testing.allocator, game, false, true);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("pre 7:05 PM ATL @ PHI\n", output);
}

test "detail one-line honors quiet framing, color, and zone label" {
    const framed = try renderTextOneLine(std.testing.allocator, testDetail(), false, false);
    defer std.testing.allocator.free(framed);
    try std.testing.expect(std.mem.indexOf(u8, framed, "MLB  2026-09-06 (9/6 ET)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, framed, "post Final ATL 5 @ PHI 4 ✓\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, framed, "/mlb?date=2026-09-06\n") != null);
    for ([_][]const u8{ "┌", "├", "└", "│", "─" }) |rule| {
        try std.testing.expect(std.mem.indexOf(u8, framed, rule) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, framed, "\x1b[") == null);

    const colored = try renderTextOneLine(std.testing.allocator, testDetail(), true, true);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[2mpost\x1b[0m Final ATL 5 @ PHI 4 ✓\n") != null);

    var live = testDetail();
    live.state = "in";
    live.status = "Top 7th";
    const live_line = try renderTextOneLine(std.testing.allocator, live, true, true);
    defer std.testing.allocator.free(live_line);
    try std.testing.expect(std.mem.indexOf(u8, live_line, "\x1b[1;31min\x1b[0m Top 7th ATL 5 @ PHI 4 ✓\n") != null);
}

test "detail box headings carry the zone label" {
    const text = try renderText(std.testing.allocator, testDetail(), false, null, null);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "MLB  2026-09-06 (9/6 ET)") != null);
    const page = try detailHtml(std.testing.allocator, testDetail(), null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "(9/6 ET)") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
}
