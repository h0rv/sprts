//! Per-game detail renderer: a pipe-less document, not a box grid.
//!
//! Built on the shared `table.zig` cell primitives (`writeCell`,
//! `writeCellRight`, `writeLine`, `textCells`) plus small local composers
//! that column-align each section (participants, scoring plays, leaders,
//! stats). Sections breathe through blank lines, wttr.in-style; the
//! scoreboard keeps the box, documents don't. Text and HTML share every
//! composed string so the two can never drift.

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

pub fn json(allocator: std.mem.Allocator, game: detail.GameDetail) ![]u8 {
    // Validated through the shared `render.validatedJson` gate — see it
    // for why strict `z.serializeAndValidate` is unusable process-wide
    // (zchema's `cachedCompiled` cross-type cache bug, coordinator-owned
    // upstream fix). Same wire format as before, field for field.
    return render.validatedJson(detail.GameDetail, allocator, game);
}

/// `width` is total terminal columns of the document. Never shrinks below
/// the classic 52-wide page. `height` caps the scoring plays listed
/// (`+N more (?height=M)` trailer); null/0 = latest 5.
///
/// Pipe-less by design: the page reads as aligned prose with blank lines
/// between sections (wttr.in-style), not a box grid. Column rows
/// (participants, scoring plays, leaders, stats) share composers with
/// `detailHtml` so text and HTML can never drift.
pub fn renderText(allocator: std.mem.Allocator, game: detail.GameDetail, color: bool, width: ?u16, height: ?u16) ![]u8 {
    const cols: usize = @min(@max(width orelse 52, 52), 200);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    // Heading names league + full date + zone once (`MLB  2026-09-06 ET`,
    // the board shape): no `M/D` repeat. The status arrives with ESPN's
    // specific suffix (`... PM EDT`); fold it to the generic heading
    // convention so rows and headings read one label.
    const zone_tag = try tz.zoneTag(allocator, .et);
    defer allocator.free(zone_tag);
    const heading = try std.fmt.allocPrint(allocator, "{s}  {s} {s}", .{ game.league_name, game.date, zone_tag });
    defer allocator.free(heading);
    try table.writeLine(w, heading, cols, "2", color);
    const status = try tz.normalizeEastern(allocator, game.status);
    defer allocator.free(status);
    try table.writeLine(w, status, cols, statusColor(game.state), color);
    const plines = try participantLines(allocator, game.participants, cols);
    defer freeLines(allocator, plines);
    for (plines, game.participants) |line, entry| {
        if (color and entry.winner) try w.writeAll("\x1b[32m");
        try w.writeAll(line);
        if (color and entry.winner) try w.writeAll("\x1b[0m");
        try w.writeByte('\n');
    }
    if (game.venue) |venue| {
        try w.writeByte('\n');
        if (game.attendance) |crowd| {
            const line = try std.fmt.allocPrint(allocator, "{s} ({d})", .{ venue, crowd });
            defer allocator.free(line);
            try table.writeLine(w, line, cols, null, color);
        } else {
            try table.writeLine(w, venue, cols, null, color);
        }
    } else if (game.attendance) |crowd| {
        try w.writeByte('\n');
        const line = try std.fmt.allocPrint(allocator, "Attendance {d}", .{crowd});
        defer allocator.free(line);
        try table.writeLine(w, line, cols, null, color);
    }
    if (maxPeriod(game) > 0) {
        try w.writeByte('\n');
        const grid = try lineScoreLines(allocator, game);
        defer freeLines(allocator, grid);
        for (grid, 0..) |line, i| {
            const mark: ?[]const u8 = if (i == 0) "2" else if (i - 1 < game.participants.len and game.participants[i - 1].winner) "32" else null;
            try table.writeLine(w, line, cols, mark, color);
        }
    }
    if (game.situation) |situation| {
        try w.writeByte('\n');
        const chip = try situationText(allocator, situation);
        defer allocator.free(chip);
        try table.writeLine(w, chip, cols, "1;31", color);
        if (situation.last_play) |last| try table.writeLine(w, last, cols, null, color);
    }
    if (game.decisions.len > 0 or hasProbables(game)) {
        try w.writeByte('\n');
        for (game.decisions) |decision| {
            const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ decision.outcome, decision.name });
            defer allocator.free(line);
            try table.writeLine(w, line, cols, null, color);
        }
        for (game.participants) |entry| {
            if (entry.probable) |starter| {
                const line = try std.fmt.allocPrint(allocator, "SP {s}: {s}", .{ entry.abbreviation, starter });
                defer allocator.free(line);
                try table.writeLine(w, line, cols, null, color);
            }
        }
    }
    if (game.scoring_plays.len > 0) {
        try w.writeByte('\n');
        try table.writeLine(w, "Scoring plays", cols, "2", color);
        const limit: usize = @min(height orelse 5, game.scoring_plays.len);
        const start = game.scoring_plays.len - limit;
        const rows = try scoringLines(allocator, game.scoring_plays[start..], cols);
        defer freeLines(allocator, rows);
        for (rows) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
        if (start > 0) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more (?height={d})", .{ start, game.scoring_plays.len });
            defer allocator.free(more);
            try table.writeLine(w, more, cols, "2", color);
        }
    }
    if (game.leaders.len > 0) {
        try w.writeByte('\n');
        try table.writeLine(w, "Leaders", cols, "2", color);
        const rows = try keyValueLines(allocator, game.leaders[0..@min(game.leaders.len, 8)], cols);
        defer freeLines(allocator, rows);
        for (rows) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    if (game.series) |series| {
        try w.writeByte('\n');
        const series_line = try std.fmt.allocPrint(allocator, "Series: {s}", .{series});
        defer allocator.free(series_line);
        try table.writeLine(w, series_line, cols, null, color);
    }
    // depth: box-score team totals (optional; skipped when the provider
    // supplies none). Capped like Leaders: first 8 lines, no trailer.
    if (game.team_stats.len > 0) {
        try w.writeByte('\n');
        try table.writeLine(w, "Team stats", cols, "2", color);
        const rows = try keyValueLines(allocator, game.team_stats[0..@min(game.team_stats.len, 8)], cols);
        defer freeLines(allocator, rows);
        for (rows) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    try w.writeByte('\n');
    const back = try std.fmt.allocPrint(allocator, "/{s}?date={s}\n", .{ game.league, game.date });
    defer allocator.free(back);
    try w.writeAll(back);
    return out.toOwnedSlice();
}

/// Browser page mirroring `renderText` line for line: the same composed
/// strings, real links, state colors as spans. Blank lines breathe where
/// the text page breathes; no rules, no borders.
pub fn detailHtml(allocator: std.mem.Allocator, game: detail.GameDetail, width: ?u16, height: ?u16) ![]u8 {
    const cols: usize = @min(@max(width orelse 52, 52), 200);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const title = try std.fmt.allocPrint(allocator, "{s} game detail", .{game.league_name});
    defer allocator.free(title);
    try render.pageHead(w, title);
    try w.writeAll("<pre>");
    // Heading names league + full date + zone once (see renderText).
    const zone_tag = try tz.zoneTag(allocator, .et);
    defer allocator.free(zone_tag);
    const heading = try std.fmt.allocPrint(allocator, "{s}  {s} {s}", .{ game.league_name, game.date, zone_tag });
    defer allocator.free(heading);
    try render.writeHtmlLine(w, allocator, heading, cols, "dim", null);
    const status_href = try std.fmt.allocPrint(allocator, "/{s}?date={s}", .{ game.league, game.date });
    defer allocator.free(status_href);
    const status = try tz.normalizeEastern(allocator, game.status);
    defer allocator.free(status);
    try render.writeHtmlLine(w, allocator, status, cols, stateClass(game.state), status_href);
    const plines = try participantLines(allocator, game.participants, cols);
    defer freeLines(allocator, plines);
    for (plines, game.participants) |line, entry| {
        const href = if (entry.abbreviation.len > 0)
            try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ game.league, entry.abbreviation })
        else
            null;
        defer if (href) |h| allocator.free(h);
        try render.writeHtmlLine(w, allocator, line, cols, if (entry.winner) "win" else null, href);
    }
    if (game.venue) |venue| {
        try w.writeByte('\n');
        if (game.attendance) |crowd| {
            const line = try std.fmt.allocPrint(allocator, "{s} ({d})", .{ venue, crowd });
            defer allocator.free(line);
            try render.writeHtmlLine(w, allocator, line, cols, null, null);
        } else {
            try render.writeHtmlLine(w, allocator, venue, cols, null, null);
        }
    } else if (game.attendance) |crowd| {
        try w.writeByte('\n');
        const line = try std.fmt.allocPrint(allocator, "Attendance {d}", .{crowd});
        defer allocator.free(line);
        try render.writeHtmlLine(w, allocator, line, cols, null, null);
    }
    if (maxPeriod(game) > 0) {
        try w.writeByte('\n');
        const grid = try lineScoreLines(allocator, game);
        defer freeLines(allocator, grid);
        for (grid, 0..) |line, i| {
            const css: ?[]const u8 = if (i == 0) "dim" else if (i - 1 < game.participants.len and game.participants[i - 1].winner) "win" else null;
            try render.writeHtmlLine(w, allocator, line, cols, css, null);
        }
    }
    if (game.situation) |situation| {
        try w.writeByte('\n');
        const chip = try situationText(allocator, situation);
        defer allocator.free(chip);
        try render.writeHtmlLine(w, allocator, chip, cols, "live", null);
        if (situation.last_play) |last| try render.writeHtmlLine(w, allocator, last, cols, null, null);
    }
    if (game.decisions.len > 0 or hasProbables(game)) {
        try w.writeByte('\n');
        for (game.decisions) |decision| {
            const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ decision.outcome, decision.name });
            defer allocator.free(line);
            try render.writeHtmlLine(w, allocator, line, cols, null, null);
        }
        for (game.participants) |entry| {
            if (entry.probable) |starter| {
                const line = try std.fmt.allocPrint(allocator, "SP {s}: {s}", .{ entry.abbreviation, starter });
                defer allocator.free(line);
                try render.writeHtmlLine(w, allocator, line, cols, null, null);
            }
        }
    }
    if (game.scoring_plays.len > 0) {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "Scoring plays", cols, "dim", null);
        const limit: usize = @min(height orelse 5, game.scoring_plays.len);
        const start = game.scoring_plays.len - limit;
        const rows = try scoringLines(allocator, game.scoring_plays[start..], cols);
        defer freeLines(allocator, rows);
        for (rows) |line| try render.writeHtmlLine(w, allocator, line, cols, null, null);
        if (start > 0) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more (?height={d})", .{ start, game.scoring_plays.len });
            defer allocator.free(more);
            try render.writeHtmlLine(w, allocator, more, cols, "dim", null);
        }
    }
    if (game.leaders.len > 0) {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "Leaders", cols, "dim", null);
        const rows = try keyValueLines(allocator, game.leaders[0..@min(game.leaders.len, 8)], cols);
        defer freeLines(allocator, rows);
        for (rows) |line| try render.writeHtmlLine(w, allocator, line, cols, null, null);
    }
    if (game.series) |series| {
        try w.writeByte('\n');
        const series_line = try std.fmt.allocPrint(allocator, "Series: {s}", .{series});
        defer allocator.free(series_line);
        try render.writeHtmlLine(w, allocator, series_line, cols, null, null);
    }
    // depth: box-score team totals (optional; skipped when absent).
    if (game.team_stats.len > 0) {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "Team stats", cols, "dim", null);
        const rows = try keyValueLines(allocator, game.team_stats[0..@min(game.team_stats.len, 8)], cols);
        defer freeLines(allocator, rows);
        for (rows) |line| try render.writeHtmlLine(w, allocator, line, cols, null, null);
    }
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/{s}?date={s}\">scores</a>", .{ game.league, game.date });
    try w.print("<a href=\"/api/v1/{s}/{s}\">json</a>", .{ game.league, game.id });
    try render.closePageWithNav(w);
    return out.toOwnedSlice();
}

/// CSS class matching the ANSI role for a game state.
fn stateClass(state: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, state, "in")) return "live";
    if (std.mem.eql(u8, state, "pre")) return "upcoming";
    return null;
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

/// Baseball keeps the R/H/E linescore; every other sport gets periods +
/// Total. Unknown slugs keep the baseball shape as the safe default.
fn isBaseball(league_slug: []const u8) bool {
    const league = core.leagues.find(league_slug) orelse return true;
    return std.mem.eql(u8, league.sport, "Baseball");
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

/// Free a `[][]u8` built by the composers below.
fn freeLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

/// Split a "label ... value" row at its last space: leaders
/// (`Jeremy Pena 1-5`) and team stats (`HOU Games Played 1`) align the
/// trailing value right. No space means the whole string is the label.
fn splitValue(s: []const u8) struct { label: []const u8, value: []const u8 } {
    const at = std.mem.lastIndexOfScalar(u8, s, ' ') orelse return .{ .label = s, .value = "" };
    return .{ .label = s[0..at], .value = s[at + 1 ..] };
}

/// Aligned key/value rows: labels left, values sharing one right column
/// (widest value wins). Value-less rows render as plain fitted lines.
/// `total` is the content width. Shared by text and HTML.
fn keyValueLines(allocator: std.mem.Allocator, items: []const []const u8, total: usize) ![][]u8 {
    var value_w: usize = 0;
    for (items) |item| value_w = @max(value_w, table.textCells(splitValue(item).value));
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    for (items) |item| {
        const parts = splitValue(item);
        var buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer buf.deinit();
        if (parts.value.len == 0) {
            try writeCell(&buf.writer, parts.label, total, null, false);
        } else {
            try writeCell(&buf.writer, parts.label, total -| value_w -| 1, null, false);
            try buf.writer.writeByte(' ');
            try writeCellRight(&buf.writer, parts.value, value_w, null, false);
        }
        const raw = try buf.toOwnedSlice();
        defer allocator.free(raw);
        try out.append(allocator, try allocator.dupe(u8, std.mem.trimEnd(u8, raw, " ")));
    }
    return out.toOwnedSlice(allocator);
}

/// Aligned scoring-play rows: period | running score | description, with
/// one shared period/score column per section. Score fuses the structured
/// away/home fields (`6-4`) so the text column starts together.
fn scoringLines(allocator: std.mem.Allocator, plays: []const detail.DetailScoringPlay, total: usize) ![][]u8 {
    var period_w: usize = 0;
    var score_w: usize = 0;
    for (plays) |play| {
        period_w = @max(period_w, table.textCells(play.period));
        score_w = @max(score_w, table.textCells(play.away_score) + 1 + table.textCells(play.home_score));
    }
    period_w = @min(period_w, 14);
    score_w = @min(score_w, 9);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    for (plays) |play| {
        const score = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ play.away_score, play.home_score });
        defer allocator.free(score);
        var buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer buf.deinit();
        try writeCell(&buf.writer, play.period, period_w, null, false);
        try buf.writer.writeByte(' ');
        try writeCell(&buf.writer, score, score_w, null, false);
        try buf.writer.writeByte(' ');
        try writeCell(&buf.writer, play.text, total -| period_w -| 1 -| score_w -| 1, null, false);
        const raw = try buf.toOwnedSlice();
        defer allocator.free(raw);
        try out.append(allocator, try allocator.dupe(u8, std.mem.trimEnd(u8, raw, " ")));
    }
    return out.toOwnedSlice(allocator);
}

/// Participant block rows: `ABBR name … score ✓ record`. The name flexes;
/// abbreviation, score, and record ride fixed right-ish columns so
/// multi-team blocks scan. Winner coloring wraps the whole line at emit
/// time (text) or rides a span (HTML), never inside the composer.
fn participantLines(allocator: std.mem.Allocator, participants: []const detail.DetailParticipant, total: usize) ![][]u8 {
    var abbr_w: usize = 0;
    var rec_w: usize = 0;
    for (participants) |p| {
        abbr_w = @max(abbr_w, table.textCells(p.abbreviation));
        if (p.record) |r| rec_w = @max(rec_w, table.textCells(r));
    }
    abbr_w = @min(abbr_w, 4);
    rec_w = @min(rec_w, 10);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    for (participants) |p| {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer buf.deinit();
        const fixed: usize = abbr_w + 2 + 3 + 2 + (if (p.record != null) rec_w + 1 else 0);
        try writeCell(&buf.writer, p.abbreviation, abbr_w, null, false);
        try buf.writer.writeByte(' ');
        try writeCell(&buf.writer, p.name, total -| fixed, null, false);
        try buf.writer.writeByte(' ');
        try writeCellRight(&buf.writer, p.score, 3, null, false);
        if (p.winner) try buf.writer.writeAll(" ✓") else try buf.writer.writeAll("  ");
        if (p.record) |r| {
            try buf.writer.writeByte(' ');
            try writeCellRight(&buf.writer, r, rec_w, null, false);
        }
        const raw = try buf.toOwnedSlice();
        defer allocator.free(raw);
        try out.append(allocator, try allocator.dupe(u8, std.mem.trimEnd(u8, raw, " ")));
    }
    return out.toOwnedSlice(allocator);
}

/// Linescore grid as plain strings: header, one row per team, then a
/// combined records line (`PHI 81-63 · HOU 73-71`, absent when no team
/// carries one). Baseball keeps periods + R/H/E; every other sport shows
/// periods + a single Total column (no H/E placeholders). The sport keys
/// off `core.leagues.find(game.league)`; an unknown slug keeps the
/// baseball shape as the safe default. One composer for text and HTML so
/// the grid can never drift between them (the old HTML path collapsed it
/// to one line and dropped the records entirely).
fn lineScoreLines(allocator: std.mem.Allocator, game: detail.GameDetail) ![][]u8 {
    const baseball = isBaseball(game.league);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    const periods = maxPeriod(game);
    var head: std.Io.Writer.Allocating = .init(allocator);
    defer head.deinit();
    try head.writer.writeAll("    ");
    var p: usize = 1;
    while (p <= periods) : (p += 1) try head.writer.print("{d:>3}", .{p});
    if (baseball) {
        try head.writer.writeAll("   R   H   E");
    } else {
        try head.writer.writeAll("   Total");
    }
    try out.append(allocator, try head.toOwnedSlice());
    for (game.participants) |entry| {
        var line: std.Io.Writer.Allocating = .init(allocator);
        defer line.deinit();
        try line.writer.print("{s:<4}", .{entry.abbreviation});
        var i: usize = 0;
        while (i < periods) : (i += 1) {
            const cell: []const u8 = if (i < entry.lines.len) entry.lines[i].display else "-";
            try line.writer.print("{s:>3}", .{cell});
        }
        if (baseball) {
            try line.writer.print("   {s:>3}   {s:>3}   {s:>3}", .{
                entry.score,
                entry.hits orelse "-",
                entry.errors orelse "-",
            });
        } else {
            try line.writer.print("   {s:>5}", .{entry.score});
        }
        try out.append(allocator, try line.toOwnedSlice());
    }
    var recs: std.Io.Writer.Allocating = .init(allocator);
    defer recs.deinit();
    var first = true;
    for (game.participants) |entry| {
        const record = entry.record orelse continue;
        if (!first) try recs.writer.writeAll(" · ");
        first = false;
        try recs.writer.print("{s} {s}", .{ entry.abbreviation, record });
    }
    if (!first) try out.append(allocator, try recs.toOwnedSlice());
    return out.toOwnedSlice(allocator);
}

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

test "detail text reads as aligned sections without box rules" {
    const output = try renderText(std.testing.allocator, testDetail(), false, null, null);
    defer std.testing.allocator.free(output);
    // Pipe-less document: no box-drawing bytes anywhere.
    for ([_][]const u8{ "┌", "├", "└", "│", "─" }) |rule| {
        try std.testing.expect(std.mem.indexOf(u8, output, rule) == null);
    }
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
    // Scoring plays share period/score columns: the 9th-inning row opens
    // with its period and running score before the description.
    try std.testing.expect(std.mem.indexOf(u8, output, "9th Inning 5-4 Riley tripled") != null);
    // The lone leader row right-aligns its value at the page width.
    var lines = std.mem.splitScalar(u8, output, '\n');
    var found = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "10-35") == null) continue;
        found = true;
        try std.testing.expect(std.mem.endsWith(u8, line, "10-35"));
    }
    try std.testing.expect(found);
    // Every line fits the 52-column page: composed rows are exact width,
    // fitted rows truncate, so nothing sticks out past the margin.
    var all = std.mem.splitScalar(u8, output, '\n');
    while (all.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(table.textCells(line) <= 52);
    }
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
    // Pipe-less like text: no rules or borders anywhere.
    for ([_][]const u8{ "┌", "├", "└", "│", "─" }) |rule| {
        try std.testing.expect(std.mem.indexOf(u8, page, rule) == null);
    }
    // Linescore renders one row per line (not one collapsed cell) and the
    // records line survives alongside the grid.
    try std.testing.expect(std.mem.indexOf(u8, page, "R   H   E") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "85-58") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "9th Inning 5-4 Riley tripled") != null);
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
        const zone_tag = try tz.zoneTag(arena, .et);
        defer arena.free(zone_tag);
        const heading = try std.fmt.allocPrint(arena, "{s}  {s} {s}\n", .{ game.league_name, game.date, zone_tag });
        defer arena.free(heading);
        try oneLineColorize(w, "2", heading, color);
    }
    try writeDetailOneLine(w, arena, game, color);
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
fn writeDetailOneLine(w: *std.Io.Writer, arena: std.mem.Allocator, game: detail.GameDetail, color: bool) !void {
    if (color) try w.print("\x1b[{s}m", .{oneLineStateColor(game.state)});
    try w.writeAll(game.state);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeByte(' ');
    const status = try tz.normalizeEastern(arena, game.status);
    defer arena.free(status);
    try w.writeAll(status);
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
    try std.testing.expect(std.mem.indexOf(u8, framed, "MLB  2026-09-06 ET\n") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, text, "MLB  2026-09-06 ET") != null);
    // No `M/D` repeat: the full date appears once, the zone beside it.
    try std.testing.expect(std.mem.indexOf(u8, text, "(9/6") == null);
    const page = try detailHtml(std.testing.allocator, testDetail(), null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "2026-09-06 ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "(9/6") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
}
// depth: box-score team stats section (appended; existing tests above untouched).
test "detail depth team stats render with data and skip without" {
    var game = testDetail();
    game.team_stats = &.{ "ATL At Bats 35", "PHI At Bats 33" };
    const output = try renderText(std.testing.allocator, game, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Team stats") != null);
    // Aligned form: label, shared value column, value (`ATL At Bats … 35`).
    try std.testing.expect(std.mem.indexOf(u8, output, "ATL At Bats") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "35") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(output);
    // Values share one right column: both stat rows end at the same width
    // with their values flush right.
    var lines = std.mem.splitScalar(u8, output, '\n');
    var widths: [2]usize = .{ 0, 0 };
    var n: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "At Bats") == null) continue;
        try std.testing.expect(n < widths.len);
        widths[n] = line.len;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(widths[0], widths[1]);

    const bare = try renderText(std.testing.allocator, testDetail(), false, null, null);
    defer std.testing.allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "Team stats") == null);
    _ = try std.unicode.Utf8View.init(bare);
}

test "detail depth team stats html escapes and carries no ansi" {
    var game = testDetail();
    game.team_stats = &.{"ATL <b> & \"hits\" 10"};
    const page = try detailHtml(std.testing.allocator, game, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Team stats") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "&lt;b&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<b>") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);

    const bare = try detailHtml(std.testing.allocator, testDetail(), null, null);
    defer std.testing.allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "Team stats") == null);
}

test "detail depth team stats ride the json wire format additively" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var game = testDetail();
    game.team_stats = &.{"ATL At Bats 35"};
    const output = try json(arena, game);
    try std.testing.expect(std.mem.indexOf(u8, output, "team_stats") != null);
    const parsed = try std.json.parseFromSliceLeaky(detail.GameDetail, arena, output, .{});
    try std.testing.expectEqual(@as(usize, 1), parsed.team_stats.len);
    // Payloads without the field still parse (additive default).
    const legacy = try std.json.parseFromSliceLeaky(detail.GameDetail, arena, try json(arena, testDetail()), .{});
    try std.testing.expectEqual(@as(usize, 0), legacy.team_stats.len);
}

// per-sport linescore: baseball keeps periods + R/H/E, every other sport
// shows periods + a single Total column (no H/E placeholders). The NBA
// fixture carries hits/errors on purpose to lock that the sport — not
// the presence of hits/errors — keys the decision.
fn testNbaDetail() detail.GameDetail {
    return .{
        .id = "401584672",
        .league = "nba",
        .league_name = "NBA",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .participants = &.{
            .{
                .id = "2",
                .name = "Boston Celtics",
                .abbreviation = "BOS",
                .score = "112",
                .winner = true,
                .home_away = "away",
                .lines = &.{
                    .{ .period = 1, .display = "28" },
                    .{ .period = 2, .display = "25" },
                    .{ .period = 3, .display = "30" },
                    .{ .period = 4, .display = "29" },
                },
                .hits = "HITS",
                .errors = "ERRS",
                .record = "45-20",
            },
            .{
                .id = "14",
                .name = "Los Angeles Lakers",
                .abbreviation = "LAL",
                .score = "108",
                .winner = false,
                .home_away = "home",
                .lines = &.{
                    .{ .period = 1, .display = "27" },
                    .{ .period = 2, .display = "26" },
                    .{ .period = 3, .display = "28" },
                    .{ .period = 4, .display = "27" },
                },
                .hits = "HITS",
                .errors = "ERRS",
                .record = "40-25",
            },
        },
    };
}

fn testNcaamDetail() detail.GameDetail {
    return .{
        .id = "401638291",
        .league = "ncaam",
        .league_name = "NCAA Men's Basketball",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .participants = &.{
            .{
                .id = "150",
                .name = "Duke Blue Devils",
                .abbreviation = "DUKE",
                .score = "77",
                .winner = true,
                .home_away = "away",
                .lines = &.{
                    .{ .period = 1, .display = "35" },
                    .{ .period = 2, .display = "42" },
                },
                .record = "28-5",
            },
            .{
                .id = "153",
                .name = "North Carolina Tar Heels",
                .abbreviation = "UNC",
                .score = "73",
                .winner = false,
                .home_away = "home",
                .lines = &.{
                    .{ .period = 1, .display = "33" },
                    .{ .period = 2, .display = "40" },
                },
                .record = "26-7",
            },
        },
    };
}

test "detail linescore shows Total instead of R/H/E for NBA quarters" {
    const output = try renderText(std.testing.allocator, testNbaDetail(), false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "R   H   E") == null);
    // Hits/errors ride along on the fixture but never render: the sport
    // keys the shape, not the fields.
    try std.testing.expect(std.mem.indexOf(u8, output, "HITS") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ERRS") == null);
    // Quarter columns plus the total still render per team.
    try std.testing.expect(std.mem.indexOf(u8, output, "28") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "112") != null);
    // Records line and winner check survive the new shape.
    try std.testing.expect(std.mem.indexOf(u8, output, "BOS 45-20 · LAL 40-25") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓") != null);
    _ = try std.unicode.Utf8View.init(output);

    const colored = try renderText(std.testing.allocator, testNbaDetail(), true, null, null);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[32m") != null);

    const page = try detailHtml(std.testing.allocator, testNbaDetail(), null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Total") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "R   H   E") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "HITS") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "ERRS") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "BOS 45-20 · LAL 40-25") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
}

test "detail linescore shows Total instead of R/H/E for NCAAM halves" {
    const output = try renderText(std.testing.allocator, testNcaamDetail(), false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "R   H   E") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "77") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "DUKE 28-5 · UNC 26-7") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓") != null);
    _ = try std.unicode.Utf8View.init(output);

    const page = try detailHtml(std.testing.allocator, testNcaamDetail(), null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Total") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "R   H   E") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "DUKE 28-5 · UNC 26-7") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
}

test "detail scoring trailer hints at ?height=" {
    var game = testDetail();
    var plays = [_]detail.DetailScoringPlay{
        .{ .period = "1st Inning", .text = "First run.", .away_score = "1", .home_score = "0" },
        .{ .period = "2nd Inning", .text = "Second run.", .away_score = "2", .home_score = "0" },
        .{ .period = "3rd Inning", .text = "Third run.", .away_score = "3", .home_score = "0" },
        .{ .period = "4th Inning", .text = "Fourth run.", .away_score = "4", .home_score = "0" },
        .{ .period = "5th Inning", .text = "Fifth run.", .away_score = "5", .home_score = "0" },
        .{ .period = "6th Inning", .text = "Sixth run.", .away_score = "6", .home_score = "0" },
        .{ .period = "7th Inning", .text = "Seventh run.", .away_score = "7", .home_score = "0" },
    };
    game.scoring_plays = &plays;
    const text = try renderText(std.testing.allocator, game, false, null, 5);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "+2 more (?height=7)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[") == null);
    const page = try detailHtml(std.testing.allocator, game, null, 5);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "+2 more (?height=7)") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    // Full height lists every play with no trailer.
    const all = try renderText(std.testing.allocator, game, false, null, 7);
    defer std.testing.allocator.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "more") == null);
    // JSON carries every play regardless of height (no trailer there).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const wire = try json(arena_state.allocator(), game);
    try std.testing.expect(std.mem.indexOf(u8, wire, "?height") == null);
}

test "detail statuses read the generic ET convention" {
    var game = testDetail();
    game.state = "pre";
    game.status = "9/8 - 7:40 PM EDT";
    const text = try renderText(std.testing.allocator, game, false, null, null);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "9/8 - 7:40 PM ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "EDT") == null);
    const page = try detailHtml(std.testing.allocator, game, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "9/8 - 7:40 PM ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "EDT") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    const line = try renderTextOneLine(std.testing.allocator, game, false, true);
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "9/8 - 7:40 PM ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "EDT") == null);
}
