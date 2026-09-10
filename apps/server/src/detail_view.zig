//! Per-game detail renderer: a pipe-less document, not a box grid.
//!
//! Built on the shared `table.zig` cell primitives (`writeLine`,
//! `textCells`) plus the shared `view` section composers that
//! column-align each section (participants, scoring plays, leaders,
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
const vd = @import("view.zig");

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
    // TV broadcaster the provider copied from the scoreboard row (same
    // ESPN payload, no extra fetch): one `TV:` line under the status,
    // skipped when the provider supplies none. The HTML path below
    // emits the same string, so visible text stays identical.
    if (game.network) |network| {
        const tv_line = try std.fmt.allocPrint(allocator, "TV: {s}", .{network});
        defer allocator.free(tv_line);
        try table.writeLine(w, tv_line, cols, null, color);
    }
    const psec = try vd.participantSection(allocator, game.participants, cols);
    defer vd.freeSection(allocator, psec);
    for (psec.rows, game.participants) |line, entry| {
        if (color and entry.winner) try w.writeAll("\x1b[32m");
        try w.writeAll(line);
        if (color and entry.winner) try w.writeAll("\x1b[0m");
        try w.writeByte('\n');
    }
    if (game.venue) |venue| {
        try w.writeByte('\n');
        if (game.attendance) |crowd| {
            if (crowd != 0) {
                const line = try std.fmt.allocPrint(allocator, "{s} ({d})", .{ venue, crowd });
                defer allocator.free(line);
                try table.writeLine(w, line, cols, null, color);
            } else {
                try table.writeLine(w, venue, cols, null, color);
            }
        } else {
            try table.writeLine(w, venue, cols, null, color);
        }
    } else if (game.attendance) |crowd| {
        if (crowd != 0) {
            try w.writeByte('\n');
            const line = try std.fmt.allocPrint(allocator, "Attendance {d}", .{crowd});
            defer allocator.free(line);
            try table.writeLine(w, line, cols, null, color);
        }
    }
    if (vd.maxPeriod(game) > 0) {
        try w.writeByte('\n');
        const grid = try vd.lineScoreSection(allocator, game);
        defer vd.freeSection(allocator, grid);
        for (grid.rows, 0..) |line, i| {
            const mark: ?[]const u8 = if (i == 0) "2" else if (i - 1 < game.participants.len and game.participants[i - 1].winner) "32" else null;
            try table.writeLine(w, line, cols, mark, color);
        }
    }
    if (game.situation) |situation| {
        try w.writeByte('\n');
        const chip = try vd.situationText(allocator, situation);
        defer allocator.free(chip);
        // Live situation never truncates: the chip and the last play
        // wrap onto ragged continuation lines (same composer feeds the
        // HTML path below, so visible text stays identical).
        const chip_lines = try table.wrapLines(allocator, chip, cols);
        defer vd.freeLines(allocator, chip_lines);
        for (chip_lines) |line| try table.writeLine(w, line, cols, "1;31", color);
        if (situation.last_play) |last| {
            const play_lines = try table.wrapLines(allocator, last, cols);
            defer vd.freeLines(allocator, play_lines);
            for (play_lines) |line| try table.writeLine(w, line, cols, null, color);
        }
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
        const limit: usize = @min(height orelse 5, game.scoring_plays.len);
        const start = game.scoring_plays.len - limit;
        const scoring = try vd.scoringSection(allocator, game.scoring_plays[start..], cols);
        defer vd.freeSection(allocator, scoring);
        try table.writeLine(w, scoring.heading.?, cols, "2", color);
        for (scoring.rows) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
        if (start > 0) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more (?height={d})", .{ start, game.scoring_plays.len });
            defer allocator.free(more);
            try table.writeLine(w, more, cols, "2", color);
        }
    }
    // Lineups replace leaders when the provider ships a batting group:
    // nine starters per side beats a redundant top-4 for baseball.
    if (game.lineups.len > 0) {
        try w.writeByte('\n');
        try table.writeLine(w, "Lineups", cols, "2", color);
        for (game.lineups) |side| {
            const side_sec = try vd.lineupSection(allocator, side, cols);
            defer vd.freeSection(allocator, side_sec);
            try table.writeLine(w, side_sec.heading.?, cols, "2", color);
            for (side_sec.rows) |line| {
                try w.writeAll(line);
                try w.writeByte('\n');
            }
        }
    } else if (game.leaders.len > 0) {
        try w.writeByte('\n');
        const leaders = try vd.leadersSection(allocator, game.leaders[0..@min(game.leaders.len, 8)], game.participants, cols);
        defer vd.freeLeadersSection(allocator, leaders);
        try table.writeLine(w, leaders.heading, cols, "2", color);
        for (leaders.block.lines, leaders.block.is_header) |line, header| {
            if (header) try table.writeLine(w, line, cols, "2", color) else {
                try w.writeAll(line);
                try w.writeByte('\n');
            }
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
        const tstats = try vd.teamStatsSection(allocator, game.team_stats[0..@min(game.team_stats.len, 8)], cols);
        defer vd.freeSection(allocator, tstats);
        try table.writeLine(w, tstats.heading.?, cols, "2", color);
        for (tstats.rows) |line| {
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
    return detailHtmlMtime(allocator, game, width, height, 0);
}

/// Detail HTML with the render epoch for the freshness line: live games
/// (`state == "in"`) arm `<pre data-live="1">` plus the fresh div and
/// live script; final games render exactly as `detailHtml` always did
/// (no marker, no div, no script — static bytes unchanged).
pub fn detailHtmlMtime(allocator: std.mem.Allocator, game: detail.GameDetail, width: ?u16, height: ?u16, mtime_s: i64) ![]u8 {
    const cols: usize = @min(@max(width orelse 52, 52), 200);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const title = try std.fmt.allocPrint(allocator, "{s} game detail", .{game.league_name});
    defer allocator.free(title);
    const live_page = std.mem.eql(u8, game.state, "in");
    try render.pageHeadLive(w, title, live_page);
    // Heading names league + full date + zone once (see renderText).
    const zone_tag = try tz.zoneTag(allocator, .et);
    defer allocator.free(zone_tag);
    const heading = try std.fmt.allocPrint(allocator, "{s}  {s} {s}", .{ game.league_name, game.date, zone_tag });
    defer allocator.free(heading);
    try render.writeHtmlH1(w, allocator, heading, cols, "dim");
    const status_href = try std.fmt.allocPrint(allocator, "/{s}?date={s}", .{ game.league, game.date });
    defer allocator.free(status_href);
    const status = try tz.normalizeEastern(allocator, game.status);
    defer allocator.free(status);
    try render.writeHtmlLine(w, allocator, status, cols, stateClass(game.state), status_href);
    if (game.network) |network| {
        const tv_line = try std.fmt.allocPrint(allocator, "TV: {s}", .{network});
        defer allocator.free(tv_line);
        try render.writeHtmlLine(w, allocator, tv_line, cols, null, null);
    }
    const psec = try vd.participantSection(allocator, game.participants, cols);
    defer vd.freeSection(allocator, psec);
    for (psec.rows, game.participants) |line, entry| {
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
            if (crowd != 0) {
                const line = try std.fmt.allocPrint(allocator, "{s} ({d})", .{ venue, crowd });
                defer allocator.free(line);
                try render.writeHtmlLine(w, allocator, line, cols, null, null);
            } else {
                try render.writeHtmlLine(w, allocator, venue, cols, null, null);
            }
        } else {
            try render.writeHtmlLine(w, allocator, venue, cols, null, null);
        }
    } else if (game.attendance) |crowd| {
        if (crowd != 0) {
            try w.writeByte('\n');
            const line = try std.fmt.allocPrint(allocator, "Attendance {d}", .{crowd});
            defer allocator.free(line);
            try render.writeHtmlLine(w, allocator, line, cols, null, null);
        }
    }
    if (vd.maxPeriod(game) > 0) {
        try w.writeByte('\n');
        const grid = try vd.lineScoreSection(allocator, game);
        defer vd.freeSection(allocator, grid);
        for (grid.rows, 0..) |line, i| {
            const css: ?[]const u8 = if (i == 0) "dim" else if (i - 1 < game.participants.len and game.participants[i - 1].winner) "win" else null;
            try render.writeHtmlLine(w, allocator, line, cols, css, null);
        }
    }
    if (game.situation) |situation| {
        try w.writeByte('\n');
        const chip = try vd.situationText(allocator, situation);
        defer allocator.free(chip);
        const chip_lines = try table.wrapLines(allocator, chip, cols);
        defer vd.freeLines(allocator, chip_lines);
        for (chip_lines) |line| try render.writeHtmlLine(w, allocator, line, cols, "live", null);
        if (situation.last_play) |last| {
            const play_lines = try table.wrapLines(allocator, last, cols);
            defer vd.freeLines(allocator, play_lines);
            for (play_lines) |line| try render.writeHtmlLine(w, allocator, line, cols, null, null);
        }
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
        const limit: usize = @min(height orelse 5, game.scoring_plays.len);
        const start = game.scoring_plays.len - limit;
        const scoring = try vd.scoringSection(allocator, game.scoring_plays[start..], cols);
        defer vd.freeSection(allocator, scoring);
        try render.writeHtmlLine(w, allocator, scoring.heading.?, cols, "dim", null);
        for (scoring.rows) |line| try render.writeHtmlLine(w, allocator, line, cols, null, null);
        if (start > 0) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more (?height={d})", .{ start, game.scoring_plays.len });
            defer allocator.free(more);
            try render.writeHtmlLine(w, allocator, more, cols, "dim", null);
        }
    }
    if (game.lineups.len > 0) {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "Lineups", cols, "dim", null);
        for (game.lineups) |side| {
            const side_sec = try vd.lineupSection(allocator, side, cols);
            defer vd.freeSection(allocator, side_sec);
            try render.writeHtmlLine(w, allocator, side_sec.heading.?, cols, "dim", null);
            for (side_sec.rows) |line| try render.writeHtmlLine(w, allocator, line, cols, null, null);
        }
    } else if (game.leaders.len > 0) {
        try w.writeByte('\n');
        const leaders = try vd.leadersSection(allocator, game.leaders[0..@min(game.leaders.len, 8)], game.participants, cols);
        defer vd.freeLeadersSection(allocator, leaders);
        try render.writeHtmlLine(w, allocator, leaders.heading, cols, "dim", null);
        for (leaders.block.lines, leaders.block.is_header) |line, header| {
            try render.writeHtmlLine(w, allocator, line, cols, if (header) "dim" else null, null);
        }
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
        const tstats = try vd.teamStatsSection(allocator, game.team_stats[0..@min(game.team_stats.len, 8)], cols);
        defer vd.freeSection(allocator, tstats);
        try render.writeHtmlLine(w, allocator, tstats.heading.?, cols, "dim", null);
        for (tstats.rows) |line| try render.writeHtmlLine(w, allocator, line, cols, null, null);
    }
    try w.writeAll("</pre>");
    // Live games stream like scoreboards: freshness line plus the updater
    // script. Final games stay byte-identical to the static render.
    if (live_page) {
        try render.writeFreshDiv(w, allocator, mtime_s);
        try w.writeAll(render.live_script);
    }
    try w.writeAll("<nav>");
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

test "detail leaders group players under team totals" {
    var game = testDetail();
    game.leaders = &.{ "ATL H-AB 10-35", "Drake Baldwin 2-4", "PHI H-AB 7-32", "Kyle Schwarber 2-4" };
    const output = try renderText(std.testing.allocator, game, false, null, null);
    defer std.testing.allocator.free(output);
    // Player rows inherit their team's abbreviation; team totals stay.
    try std.testing.expect(std.mem.indexOf(u8, output, "ATL  Drake Baldwin") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PHI  Kyle Schwarber") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ATL H-AB") != null);
    _ = try std.unicode.Utf8View.init(output);
    const page = try detailHtml(std.testing.allocator, game, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "ATL  Drake Baldwin") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<span class=\"dim\">ATL H-AB") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
}

test "detail text suppresses zero attendance but keeps nonzero" {
    // Live UCL audit: unknown crowds rendered as "Spotify Camp Nou
    // (0)". A zero crowd now reads as a bare venue (and a missing
    // venue reads as nothing), while a real crowd still shows.
    var silent = testDetail();
    silent.venue = "Spotify Camp Nou";
    silent.attendance = 0;
    const quiet = try renderText(std.testing.allocator, silent, false, null, null);
    defer std.testing.allocator.free(quiet);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "Spotify Camp Nou") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "(0)") == null);
    const quiet_html = try detailHtml(std.testing.allocator, silent, null, null);
    defer std.testing.allocator.free(quiet_html);
    try std.testing.expect(std.mem.indexOf(u8, quiet_html, "Spotify Camp Nou") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet_html, "(0)") == null);
    var loud = testDetail();
    loud.venue = "Spotify Camp Nou";
    loud.attendance = 50578;
    const noisy = try renderText(std.testing.allocator, loud, false, null, null);
    defer std.testing.allocator.free(noisy);
    try std.testing.expect(std.mem.indexOf(u8, noisy, "Spotify Camp Nou (50578)") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, page, "<h1 id=\"content\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Skip to content") != null);
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

test "live detail pages arm the updater and stamp freshness" {
    var game = testDetail();
    game.state = "in";
    game.status = "Top 7th";
    const page = try detailHtmlMtime(std.testing.allocator, game, null, null, 1757328000);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre data-live=\"1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<div class=\"fresh\" data-mtime=\"1757328000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "updated just now") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "EventSource") != null);
    // Live content still renders; additions carry no escapes.
    try std.testing.expect(std.mem.indexOf(u8, page, "Top 7th") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
}

test "final detail pages stay static bytes" {
    // JS-free stability: a final game carries zero live bytes.
    const page = try detailHtml(std.testing.allocator, testDetail(), null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-live") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-mtime") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "EventSource") == null);
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

test "detail live situation wraps the matchup instead of truncating" {
    // Regression: a live MLB header once rendered
    // `0-0, 1 out, bases empty Cristopher Sanchez vs Yor…` — the
    // pitcher-vs-batter tail cut by the truncating writer. Situation
    // lines now wrap at word boundaries onto continuation lines.
    var game = testDetail();
    game.state = "in";
    game.status = "Top 6th";
    game.situation = .{
        .balls = 0,
        .strikes = 0,
        .outs = 1,
        .runners = &.{},
        .batter = "Yordan Alvarez",
        .pitcher = "Cristopher Sanchez",
        .last_play = "Cristopher Sanchez throws a four-seam fastball to Yordan Alvarez for a very long called strike description",
    };
    const output = try renderText(std.testing.allocator, game, false, null, null);
    defer std.testing.allocator.free(output);
    _ = try std.unicode.Utf8View.init(output);
    // Both names survive in full — nothing elided.
    try std.testing.expect(std.mem.indexOf(u8, output, "Cristopher Sanchez") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Yordan Alvarez") != null);
    // No ellipsis on any situation line (other sections, e.g. scoring
    // plays, still truncate by design — scope the check to the wrapped
    // chip and last-play rows).
    var no_elide = std.mem.splitScalar(u8, output, '\n');
    while (no_elide.next()) |line| {
        if (std.mem.indexOf(u8, line, "0-0,") != null or
            std.mem.indexOf(u8, line, "Sanchez") != null or
            std.mem.indexOf(u8, line, "Alvarez") != null or
            std.mem.indexOf(u8, line, "four-seam") != null or
            std.mem.indexOf(u8, line, "fastball") != null or
            std.mem.indexOf(u8, line, "called strike") != null)
        {
            try std.testing.expect(std.mem.indexOf(u8, line, "…") == null);
        }
    }
    // Joining wrapped lines with spaces reconstructs the full chip and
    // the full last play, proving no word was dropped or cut.
    var joined: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer joined.deinit();
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (line.len == 0) try joined.writer.writeByte(' ') else {
            try joined.writer.writeAll(line);
            try joined.writer.writeByte(' ');
        }
    }
    const flat = try joined.toOwnedSlice();
    defer std.testing.allocator.free(flat);
    try std.testing.expect(std.mem.indexOf(u8, flat, "0-0, 1 out, bases empty Cristopher Sanchez vs Yordan Alvarez") != null);
    try std.testing.expect(std.mem.indexOf(u8, flat, "Cristopher Sanchez throws a four-seam fastball to Yordan Alvarez for a very long called strike description") != null);
    // The chip spans at least two lines: the opener and the tail never
    // share one row (60 cells cannot fit 52).
    var opener: ?[]const u8 = null;
    var tail: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(table.textCells(line) <= 52);
        if (std.mem.indexOf(u8, line, "0-0,") != null) opener = line;
        if (std.mem.indexOf(u8, line, "Alvarez") != null and std.mem.indexOf(u8, line, "0-0,") == null) tail = line;
    }
    try std.testing.expect(opener != null);
    try std.testing.expect(tail != null);
    try std.testing.expect(opener.?.ptr != tail.?.ptr);
    // HTML carries the same wrapped words with no ANSI; situation rows
    // carry no ellipsis (scoping as above).
    const page = try detailHtml(std.testing.allocator, game, null, null);
    defer std.testing.allocator.free(page);
    _ = try std.unicode.Utf8View.init(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Cristopher Sanchez") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Yordan Alvarez") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    var page_lines = std.mem.splitScalar(u8, page, '\n');
    while (page_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "0-0,") != null or
            std.mem.indexOf(u8, line, "Sanchez") != null or
            std.mem.indexOf(u8, line, "Alvarez") != null or
            std.mem.indexOf(u8, line, "four-seam") != null or
            std.mem.indexOf(u8, line, "fastball") != null or
            std.mem.indexOf(u8, line, "called strike") != null)
        {
            try std.testing.expect(std.mem.indexOf(u8, line, "…") == null);
        }
    }
}

test "detail lineups replace leaders when a batting group ships" {
    var game = testDetail();
    game.leaders = &.{"ATL H-AB 10-35"};
    game.lineups = &.{
        .{
            .team = "ATL",
            .total = "10-35",
            .entries = &.{
                .{ .order = 1, .position = "RF", .name = "Ronald Acuna Jr.", .hitting = "2-3", .runs = "1", .average = ".255" },
                .{ .order = 2, .position = "DH", .name = "Marcell Ozuna", .hitting = "0-4" },
            },
        },
    };
    const output = try renderText(std.testing.allocator, game, false, null, null);
    defer std.testing.allocator.free(output);
    _ = try std.unicode.Utf8View.init(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Lineups") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Ronald Acuna Jr.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2-3") != null);
    // Leaders yield to lineups: no redundant section.
    try std.testing.expect(std.mem.indexOf(u8, output, "Leaders") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ATL H-AB") == null);
    const page = try detailHtml(std.testing.allocator, game, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Ronald Acuna Jr.") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Leaders") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
}

test "game detail renders no team marks in text or HTML" {
    // Verified, not assumed: the detail view never emits braille logos
    // (no art site exists here), so the game route's `art` flag is
    // accepted-and-ignored — proven by zero braille for mark-shipping
    // teams (PHI) in both formats.
    try std.testing.expect(core.art.teamArt("mlb", "PHI", .xs) != null);
    const output = try renderText(std.testing.allocator, testDetail(), false, null, null);
    defer std.testing.allocator.free(output);
    var i: usize = 0;
    while (i + 1 < output.len) : (i += 1) {
        try std.testing.expect(!(output[i] == 0xE2 and output[i + 1] >= 0xA0 and output[i + 1] <= 0xA3));
    }
    const page = try detailHtml(std.testing.allocator, testDetail(), null, null);
    defer std.testing.allocator.free(page);
    var j: usize = 0;
    while (j + 1 < page.len) : (j += 1) {
        try std.testing.expect(!(page[j] == 0xE2 and page[j + 1] >= 0xA0 and page[j + 1] <= 0xA3));
    }
    try std.testing.expect(std.mem.indexOf(u8, page, "rgb(") == null);
}

test "detail scoring plays wrap long text instead of truncating" {
    var game = testDetail();
    game.state = "in";
    game.scoring_plays = &.{
        .{ .period = "Q2", .text = "7-0 Eli Raridon 2 Yd pass from Drake Maye (Anders Carlson Kick)", .away_score = "7", .home_score = "0" },
    };
    const output = try renderText(std.testing.allocator, game, false, null, null);
    defer std.testing.allocator.free(output);
    _ = try std.unicode.Utf8View.init(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Anders Carlson Kick") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(And…") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Scoring") != null);
    const page = try detailHtml(std.testing.allocator, game, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Anders Carlson Kick") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
}

// Phase 2: hostile-fixture visible-text equality. Every row the shared
// `view` composers produce must surface verbatim in the text page
// and as visible text (tags stripped, entities unescaped) in the HTML
// page — even when ESPN strings smuggle controls, ANSI, CJK width, and
// `&<>"'` through every field at once.
fn hostileDetail() detail.GameDetail {
    return .{
        .id = "9",
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .state = "in",
        .status = "Top 7th\nExtra \x1b[31m",
        .venue = "Citizens\tBank \nPark & Pavilion",
        .attendance = 42793,
        .series = "ATL leads 2-1 <game 3>",
        .participants = &.{
            .{
                .id = "15",
                .name = "Atlético Madrid Club de Fútbol with an extremely long tail that never ends \x1b[31m",
                .abbreviation = "AWY",
                .score = "12",
                .winner = true,
                .home_away = "away",
                .lines = &.{ .{ .period = 1, .display = "1" }, .{ .period = 2, .display = "0" } },
                .hits = "10",
                .errors = "1",
                .record = "69-74\r\nx",
                .probable = "A & B <ace> \nTaijuan",
            },
            .{
                .id = "22",
                .name = "Home\tTeam 漢字日本語の非常に長い名前で枠を超える名前",
                .abbreviation = "",
                .score = "",
                .winner = false,
                .home_away = "home",
                .lines = &.{ .{ .period = 1, .display = "0" }, .{ .period = 2, .display = "3" } },
                .hits = "7",
                .errors = "0",
            },
        },
        .decisions = &.{.{ .outcome = "W", .name = "Dylan\nLee & Son" }},
        .situation = .{
            .balls = 3,
            .strikes = 2,
            .outs = 2,
            .runners = &.{ "1st", "2nd" },
            .batter = "Yordan\nAlvarez <slugger>",
            .pitcher = "Cristopher\tSanchez & Co.",
            .last_play = "A very long last play with controls \n\t\x1b[0m and CJK 漢字 that must wrap, never truncate",
        },
        .scoring_plays = &.{
            .{ .period = "1st\nInning", .text = "", .away_score = "1", .home_score = "0" },
            .{ .period = "9th Inning", .text = "Riley tripled to center, Albies scored & the " ++ "crowd went wild 漢字 with a tail that wraps around the page width", .away_score = "5", .home_score = "4" },
        },
        .lineups = &.{
            .{
                .team = "AWY",
                .total = "12-40",
                .entries = &.{.{ .order = 1, .position = "RF", .name = "Acuña\nJr. & <rookie>", .hitting = "2-3" }},
            },
        },
        .leaders = &.{ "AWY H-AB 10-35", "Hostile\nPlayer & <x> 1-5" },
        .team_stats = &.{ "AWY <b> & \"hits\" 10", "HOU Games\tPlayed 1" },
    };
}

fn containsLine(haystack: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, haystack, '\n');
    while (it.next()) |line| if (std.mem.eql(u8, line, needle)) return true;
    return false;
}

/// One shared-composer row on both surfaces, replaying the real
/// emitters: the text page writes section rows raw but fitted lines
/// (grid, wraps, headings) through `writeLine`, while the HTML path
/// always refits before escaping — so each side is compared against
/// what its own emitter produces from the same composed string.
fn emitTextLine(row: []const u8, cols: usize) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try table.writeLine(&buf.writer, row, cols, null, false);
    const s = try buf.toOwnedSlice();
    defer std.testing.allocator.free(s);
    return std.testing.allocator.dupe(u8, std.mem.trimEnd(u8, s, "\n"));
}

fn emitHtmlVisible(row: []const u8, cols: usize) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try render.writeHtmlLine(&buf.writer, std.testing.allocator, row, cols, null, null);
    const s = try buf.toOwnedSlice();
    defer std.testing.allocator.free(s);
    return vd.stripHtmlVisible(std.testing.allocator, std.mem.trimEnd(u8, s, "\n"));
}

fn expectRowInBoth(text: []const u8, seen: []const u8, row: []const u8, cols: usize, text_raw: bool) !void {
    if (text_raw) {
        try std.testing.expect(containsLine(text, row));
    } else {
        const fitted = try emitTextLine(row, cols);
        defer std.testing.allocator.free(fitted);
        try std.testing.expect(containsLine(text, fitted));
    }
    const visible = try emitHtmlVisible(row, cols);
    defer std.testing.allocator.free(visible);
    try std.testing.expect(containsLine(seen, visible));
}

/// Visible text of a detail page: the `<pre>` block with tags stripped
/// and entities unescaped, line for line.
fn visiblePre(arena: std.mem.Allocator, page: []const u8) ![]u8 {
    const pre_open = std.mem.indexOf(u8, page, "<pre") orelse return error.TestUnexpectedResult;
    const pre_gt = std.mem.indexOfScalarPos(u8, page, pre_open, '>') orelse return error.TestUnexpectedResult;
    const pre_close = std.mem.indexOf(u8, page, "</pre>") orelse return error.TestUnexpectedResult;
    try std.testing.expect(pre_gt < pre_close);
    var visible: std.Io.Writer.Allocating = .init(arena);
    errdefer visible.deinit();
    var raw = std.mem.splitScalar(u8, page[pre_gt + 1 .. pre_close], '\n');
    while (raw.next()) |line| {
        const clean = try vd.stripHtmlVisible(arena, line);
        defer arena.free(clean);
        try visible.writer.writeAll(clean);
        try visible.writer.writeByte('\n');
    }
    return visible.toOwnedSlice();
}

test "hostile detail sections read identically in text and HTML" {
    const arena = std.testing.allocator;
    const game = hostileDetail();
    const cols: usize = 52;
    const text = try renderText(arena, game, false, null, null);
    defer arena.free(text);
    const page = try detailHtml(arena, game, null, null);
    defer arena.free(page);
    _ = try std.unicode.Utf8View.init(text);
    _ = try std.unicode.Utf8View.init(page);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b") == null);
    // Visible HTML: the `<pre>` block with tags stripped and entities
    // unescaped, line for line.
    const seen = try visiblePre(arena, page);
    defer arena.free(seen);
    // Every shared-composer row lands verbatim in both surfaces.
    const psec = try vd.participantSection(arena, game.participants, cols);
    defer vd.freeSection(arena, psec);
    try std.testing.expectEqual(@as(usize, 2), psec.rows.len);
    for (psec.rows) |row| try expectRowInBoth(text, seen, row, cols, true);
    const grid = try vd.lineScoreSection(arena, game);
    defer vd.freeSection(arena, grid);
    for (grid.rows) |row| try expectRowInBoth(text, seen, row, cols, false);
    const chip = try vd.situationText(arena, game.situation.?);
    defer arena.free(chip);
    const chip_lines = try table.wrapLines(arena, chip, cols);
    defer vd.freeLines(arena, chip_lines);
    for (chip_lines) |row| try expectRowInBoth(text, seen, row, cols, false);
    const play_lines = try table.wrapLines(arena, game.situation.?.last_play.?, cols);
    defer vd.freeLines(arena, play_lines);
    try std.testing.expect(play_lines.len > 1);
    for (play_lines) |row| try expectRowInBoth(text, seen, row, cols, false);
    const scoring = try vd.scoringSection(arena, game.scoring_plays, cols);
    defer vd.freeSection(arena, scoring);
    try expectRowInBoth(text, seen, scoring.heading.?, cols, false);
    for (scoring.rows) |row| try expectRowInBoth(text, seen, row, cols, true);
    const side = try vd.lineupSection(arena, game.lineups[0], cols);
    defer vd.freeSection(arena, side);
    try expectRowInBoth(text, seen, side.heading.?, cols, false);
    for (side.rows) |row| try expectRowInBoth(text, seen, row, cols, true);
    // Lineups replace leaders by design, so the leaders block renders
    // from a lineup-less twin of the same hostile game.
    var plain = game;
    plain.lineups = &.{};
    const text2 = try renderText(arena, plain, false, null, null);
    defer arena.free(text2);
    const page2 = try detailHtml(arena, plain, null, null);
    defer arena.free(page2);
    _ = try std.unicode.Utf8View.init(text2);
    const seen2 = try visiblePre(arena, page2);
    defer arena.free(seen2);
    const leaders = try vd.leadersSection(arena, game.leaders, game.participants, cols);
    defer vd.freeLeadersSection(arena, leaders);
    try expectRowInBoth(text2, seen2, leaders.heading, cols, false);
    for (leaders.block.lines, leaders.block.is_header) |row, header| try expectRowInBoth(text2, seen2, row, cols, !header);
    const tstats = try vd.teamStatsSection(arena, game.team_stats, cols);
    defer vd.freeSection(arena, tstats);
    for (tstats.rows) |row| try expectRowInBoth(text, seen, row, cols, true);
    // Hostile chrome folds the same way on both sides: no raw control,
    // no raw escape, no raw `&<>` survives the HTML surface.
    try std.testing.expect(containsLine(text, "Top 7th Extra  [31m"));
    try std.testing.expect(containsLine(seen, "Top 7th Extra  [31m"));
    try std.testing.expect(containsLine(text, "Citizens Bank  Park & Pavilion (42793)"));
    try std.testing.expect(containsLine(seen, "Citizens Bank  Park & Pavilion (42793)"));
    try std.testing.expect(containsLine(text, "Series: ATL leads 2-1 <game 3>"));
    try std.testing.expect(containsLine(seen, "Series: ATL leads 2-1 <game 3>"));
    try std.testing.expect(std.mem.indexOf(u8, seen, "\x1b[31m") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "&amp;") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "&lt;") == null);
}

// Per-sport VIEW parity: every league family renders everything its data
// supports. Each fixture below exercises the fields `core.detail` carries
// for that sport (linescores/periods, records, leaders, lineups,
// decisions, situations, venues, attendance, series, network) and asserts
// each renders in text AND HTML with identical visible text. Inline
// fixtures only, never live ESPN. Provider gaps (data absent upstream)
// are reported in the commit message, not faked here: tennis/golf/racing
// carry no linescores/records/leaders upstream, MMA carries no W/L/SV
// decisions, non-baseball sports carry no batting lineups or ball-strike
// situations, and no sport carries win probabilities in `core.*` yet.
fn familyMlb() detail.GameDetail {
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
        .network = "ESPN & <Deportes>",
        .participants = &.{
            .{
                .id = "15",
                .name = "Atlanta Braves",
                .abbreviation = "ATL",
                .score = "5",
                .winner = true,
                .home_away = "away",
                .lines = &.{ .{ .period = 1, .display = "0" }, .{ .period = 9, .display = "1" } },
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
                .lines = &.{ .{ .period = 1, .display = "2" }, .{ .period = 9, .display = "0" } },
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
            .{ .period = "9th Inning", .text = "Riley tripled to center, Albies scored.", .away_score = "5", .home_score = "4" },
        },
        .leaders = &.{"ATL H-AB 10-35"},
        .lineups = &.{
            .{
                .team = "ATL",
                .total = "10-35",
                .entries = &.{.{ .order = 1, .position = "RF", .name = "Ronald Acuna Jr.", .hitting = "2-3" }},
            },
        },
        .team_stats = &.{"ATL At Bats 35"},
    };
}

fn familyNfl() detail.GameDetail {
    return .{
        .id = "401772958",
        .league = "nfl",
        .league_name = "NFL",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .venue = "Lincoln Financial Field",
        .attendance = 69596,
        .network = "FOX",
        .participants = &.{
            .{
                .id = "12",
                .name = "Kansas City Chiefs",
                .abbreviation = "KC",
                .score = "27",
                .winner = true,
                .home_away = "away",
                .lines = &.{
                    .{ .period = 1, .display = "7" },
                    .{ .period = 2, .display = "10" },
                    .{ .period = 3, .display = "3" },
                    .{ .period = 4, .display = "7" },
                },
                .record = "11-3",
            },
            .{
                .id = "22",
                .name = "Philadelphia Eagles",
                .abbreviation = "PHI",
                .score = "24",
                .winner = false,
                .home_away = "home",
                .lines = &.{
                    .{ .period = 1, .display = "3" },
                    .{ .period = 2, .display = "7" },
                    .{ .period = 3, .display = "7" },
                    .{ .period = 4, .display = "7" },
                },
                .record = "10-4",
            },
        },
        .scoring_plays = &.{
            .{ .period = "Q4", .text = "Jalen Hurts 1 Yd run (Jake Elliott Kick)", .away_score = "27", .home_score = "24" },
        },
        .leaders = &.{"KC Passing 320 YDS", "Jalen Hurts 25/34, 280 YDS"},
        .team_stats = &.{"KC Total Yards 410"},
    };
}

fn familyNba() detail.GameDetail {
    return .{
        .id = "401584672",
        .league = "nba",
        .league_name = "NBA",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .venue = "TD Garden",
        .attendance = 19156,
        .network = "TNT",
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
                .record = "40-25",
            },
        },
        .scoring_plays = &.{
            .{ .period = "Q4", .text = "Jayson Tatum 26-foot three point shot.", .away_score = "112", .home_score = "108" },
        },
        .leaders = &.{"BOS PTS 112", "Jayson Tatum 34 PTS"},
    };
}

fn familyNhl() detail.GameDetail {
    return .{
        .id = "401789012",
        .league = "nhl",
        .league_name = "NHL",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final/OT",
        .venue = "TD Garden",
        .attendance = 17850,
        .network = "ESPN+",
        .participants = &.{
            .{
                .id = "6",
                .name = "Boston Bruins",
                .abbreviation = "BOS",
                .score = "4",
                .winner = true,
                .home_away = "home",
                .lines = &.{
                    .{ .period = 1, .display = "1" },
                    .{ .period = 2, .display = "2" },
                    .{ .period = 3, .display = "0" },
                    .{ .period = 4, .display = "1" },
                },
                .record = "38-14-9",
            },
            .{
                .id = "7",
                .name = "Buffalo Sabres",
                .abbreviation = "BUF",
                .score = "3",
                .winner = false,
                .home_away = "away",
                .lines = &.{
                    .{ .period = 1, .display = "1" },
                    .{ .period = 2, .display = "1" },
                    .{ .period = 3, .display = "1" },
                    .{ .period = 4, .display = "0" },
                },
                .record = "30-25-6",
            },
        },
        .scoring_plays = &.{
            .{ .period = "OT", .text = "David Pastrnak wrist shot, assisted by Brad Marchand.", .away_score = "3", .home_score = "4" },
        },
        .leaders = &.{"BOS Shots 34", "David Pastrnak 2 G"},
    };
}

fn familySoccer() detail.GameDetail {
    return .{
        .id = "784123",
        .league = "epl",
        .league_name = "Premier League",
        .date = "2026-09-06",
        .state = "post",
        .status = "Full Time",
        .venue = "Emirates Stadium",
        .attendance = 60704,
        .network = "NBC",
        .participants = &.{
            .{
                .id = "110",
                .name = "Arsenal",
                .abbreviation = "ARS",
                .score = "2",
                .winner = true,
                .home_away = "home",
                .record = "18-3-5",
            },
            .{
                .id = "83",
                .name = "Chelsea",
                .abbreviation = "CHE",
                .score = "1",
                .winner = false,
                .home_away = "away",
                .record = "14-6-6",
            },
        },
        .scoring_plays = &.{
            .{ .period = "78'", .text = "Bukayo Saka right footed shot from the centre of the box.", .away_score = "1", .home_score = "2" },
        },
        .leaders = &.{"ARS Shots 14", "Bukayo Saka 1 G"},
        .team_stats = &.{"ARS Possession 58"},
    };
}

fn familyTennis() detail.GameDetail {
    // Tennis carries athletes (no abbreviations), a venue, and a
    // broadcaster; linescores/records/leaders are absent upstream, so
    // the view renders the duel rows plus venue/network with no grid.
    return .{
        .id = "atp-9",
        .league = "atp",
        .league_name = "ATP",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .venue = "Arthur Ashe Stadium",
        .network = "ESPN2",
        .participants = &.{
            .{ .id = "p1", .name = "Carlos Alcaraz", .abbreviation = "", .score = "2", .winner = true },
            .{ .id = "p2", .name = "Jannik Sinner", .abbreviation = "", .score = "1", .winner = false },
        },
    };
}

fn familyRacing() detail.GameDetail {
    // F1 carries the starting-driver field as athlete rows plus the
    // circuit venue; no linescores, records, or leaders upstream.
    return .{
        .id = "f1-12",
        .league = "f1",
        .league_name = "Formula 1",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .venue = "Monza Circuit",
        .attendance = 93900,
        .network = "ESPN",
        .participants = &.{
            .{ .id = "d1", .name = "Max Verstappen", .abbreviation = "", .score = "1st", .winner = true },
            .{ .id = "d2", .name = "Lando Norris", .abbreviation = "", .score = "2nd", .winner = false },
        },
    };
}

fn familyMma() detail.GameDetail {
    // UFC carries the bout as athlete rows plus venue/broadcaster; no
    // linescores, W/L/SV decisions, or batting lineups upstream.
    return .{
        .id = "ufc-7",
        .league = "ufc",
        .league_name = "UFC",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .venue = "T-Mobile Arena",
        .attendance = 19600,
        .network = "PPV",
        .participants = &.{
            .{ .id = "f1", .name = "Islam Makhachev", .abbreviation = "", .score = "W", .winner = true },
            .{ .id = "f2", .name = "Arman Tsarukyan", .abbreviation = "", .score = "L", .winner = false },
        },
        .leaders = &.{"Fight of the Night: Main Event"},
    };
}

fn familyGolf() detail.GameDetail {
    // PGA carries the leaderboard as athlete rows plus the course venue;
    // no linescores, records, or leaders upstream.
    return .{
        .id = "pga-4",
        .league = "pga",
        .league_name = "PGA Tour",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .venue = "Augusta National Golf Club",
        .network = "CBS",
        .participants = &.{
            .{ .id = "g1", .name = "Scottie Scheffler", .abbreviation = "", .score = "-12", .winner = true },
            .{ .id = "g2", .name = "Rory McIlroy", .abbreviation = "", .score = "-10", .winner = false },
        },
    };
}

fn familyLiveBaseball() detail.GameDetail {
    // Live chip: ball-strike situation plus last play wrap under the
    // network line; decisions stay absent mid-game.
    var game = familyMlb();
    game.state = "in";
    game.status = "Top 7th";
    game.decisions = &.{};
    game.situation = .{
        .balls = 2,
        .strikes = 1,
        .outs = 1,
        .runners = &.{"1st"},
        .batter = "Ronald Acuna Jr.",
        .pitcher = "Aaron Nola",
        .last_play = "Ball 3 outside.",
    };
    return game;
}

/// Per-row parity for one family fixture, replaying the real emitters:
/// rows the text page writes raw (participants, scoring plays, leaders,
/// lineups, team stats) must land verbatim in text and fitted in HTML;
/// rows the text page fits through `writeLine` (heading, status, TV,
/// venue, grid, chip, decisions, headings, series) must match fitted on
/// both sides. Follows the hostile-fixture contract above (`expectRowInBoth`);
/// whole-page byte equality cannot hold where `table.fit` truncates on
/// byte length for multibyte rows, so each surface is compared against
/// what its own emitter produces from the same composed string.
fn expectDetailParity(game: detail.GameDetail) !void {
    const arena = std.testing.allocator;
    const cols: usize = 52;
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    const page = try detailHtml(arena, game, null, null);
    defer arena.free(page);
    _ = try std.unicode.Utf8View.init(body);
    _ = try std.unicode.Utf8View.init(page);
    try std.testing.expect(std.mem.indexOf(u8, body, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    const seen = try visiblePre(arena, page);
    defer arena.free(seen);
    // Heading + status + TV: fitted on both sides.
    const zone_tag = try tz.zoneTag(arena, .et);
    defer arena.free(zone_tag);
    const heading = try std.fmt.allocPrint(arena, "{s}  {s} {s}", .{ game.league_name, game.date, zone_tag });
    defer arena.free(heading);
    try expectRowInBoth(body, seen, heading, cols, false);
    const status = try tz.normalizeEastern(arena, game.status);
    defer arena.free(status);
    try expectRowInBoth(body, seen, status, cols, false);
    if (game.network) |network| {
        const tv_line = try std.fmt.allocPrint(arena, "TV: {s}", .{network});
        defer arena.free(tv_line);
        try expectRowInBoth(body, seen, tv_line, cols, false);
    }
    // Participants: raw in text, fitted in HTML.
    const psec = try vd.participantSection(arena, game.participants, cols);
    defer vd.freeSection(arena, psec);
    for (psec.rows) |row| try expectRowInBoth(body, seen, row, cols, true);
    // Venue / attendance: fitted.
    if (game.venue) |venue| {
        if (game.attendance) |crowd| {
            if (crowd != 0) {
                const line = try std.fmt.allocPrint(arena, "{s} ({d})", .{ venue, crowd });
                defer arena.free(line);
                try expectRowInBoth(body, seen, line, cols, false);
            } else {
                try expectRowInBoth(body, seen, venue, cols, false);
            }
        } else {
            try expectRowInBoth(body, seen, venue, cols, false);
        }
    } else if (game.attendance) |crowd| {
        if (crowd != 0) {
            const line = try std.fmt.allocPrint(arena, "Attendance {d}", .{crowd});
            defer arena.free(line);
            try expectRowInBoth(body, seen, line, cols, false);
        }
    }
    // Linescore grid: fitted.
    if (vd.maxPeriod(game) > 0) {
        const grid = try vd.lineScoreSection(arena, game);
        defer vd.freeSection(arena, grid);
        for (grid.rows) |row| try expectRowInBoth(body, seen, row, cols, false);
    }
    // Situation chip + last play: wrapped, fitted.
    if (game.situation) |situation| {
        const chip = try vd.situationText(arena, situation);
        defer arena.free(chip);
        const chip_lines = try table.wrapLines(arena, chip, cols);
        defer vd.freeLines(arena, chip_lines);
        for (chip_lines) |row| try expectRowInBoth(body, seen, row, cols, false);
        if (situation.last_play) |last| {
            const play_lines = try table.wrapLines(arena, last, cols);
            defer vd.freeLines(arena, play_lines);
            for (play_lines) |row| try expectRowInBoth(body, seen, row, cols, false);
        }
    }
    // Decisions + probables: fitted.
    for (game.decisions) |decision| {
        const line = try std.fmt.allocPrint(arena, "{s}: {s}", .{ decision.outcome, decision.name });
        defer arena.free(line);
        try expectRowInBoth(body, seen, line, cols, false);
    }
    for (game.participants) |entry| {
        if (entry.probable) |starter| {
            const line = try std.fmt.allocPrint(arena, "SP {s}: {s}", .{ entry.abbreviation, starter });
            defer arena.free(line);
            try expectRowInBoth(body, seen, line, cols, false);
        }
    }
    // Scoring plays: heading fitted, rows raw.
    if (game.scoring_plays.len > 0) {
        const scoring = try vd.scoringSection(arena, game.scoring_plays, cols);
        defer vd.freeSection(arena, scoring);
        try expectRowInBoth(body, seen, scoring.heading.?, cols, false);
        for (scoring.rows) |row| try expectRowInBoth(body, seen, row, cols, true);
    }
    // Lineups replace leaders: headings fitted, rows raw either way.
    if (game.lineups.len > 0) {
        try expectRowInBoth(body, seen, "Lineups", cols, false);
        for (game.lineups) |side| {
            const side_sec = try vd.lineupSection(arena, side, cols);
            defer vd.freeSection(arena, side_sec);
            try expectRowInBoth(body, seen, side_sec.heading.?, cols, false);
            for (side_sec.rows) |row| try expectRowInBoth(body, seen, row, cols, true);
        }
    } else if (game.leaders.len > 0) {
        const leaders = try vd.leadersSection(arena, game.leaders[0..@min(game.leaders.len, 8)], game.participants, cols);
        defer vd.freeLeadersSection(arena, leaders);
        try expectRowInBoth(body, seen, leaders.heading, cols, false);
        for (leaders.block.lines, leaders.block.is_header) |row, header| try expectRowInBoth(body, seen, row, cols, !header);
    }
    // Series: fitted.
    if (game.series) |series| {
        const series_line = try std.fmt.allocPrint(arena, "Series: {s}", .{series});
        defer arena.free(series_line);
        try expectRowInBoth(body, seen, series_line, cols, false);
    }
    // Team stats: heading fitted, rows raw.
    if (game.team_stats.len > 0) {
        const tstats = try vd.teamStatsSection(arena, game.team_stats[0..@min(game.team_stats.len, 8)], cols);
        defer vd.freeSection(arena, tstats);
        try expectRowInBoth(body, seen, tstats.heading.?, cols, false);
        for (tstats.rows) |row| try expectRowInBoth(body, seen, row, cols, true);
    }
}

test "family mlb renders every supported section in text and HTML" {
    const arena = std.testing.allocator;
    const game = familyMlb();
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    for ([_][]const u8{ "Final", "TV: ESPN", "Citizens Bank Park (42793)", "R   H   E", "85-58", "80-63", "W: Dylan Lee", "SV: Raisel Iglesias", "SP PHI: Aaron Nola", "Scoring plays", "Riley tripled", "Lineups", "Ronald Acuna Jr.", "Team stats", "ATL At Bats", "Series: ATL leads" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, body, token) != null);
    }
    // Hostile broadcaster escapes in HTML, visible text keeps the raw `&<>`.
    const page = try detailHtml(arena, game, null, null);
    defer arena.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "TV: ESPN &amp; &lt;Deportes&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<Deportes>") == null);
    try expectDetailParity(game);
}

test "family nfl renders quarters, leaders, and venue in text and HTML" {
    const arena = std.testing.allocator;
    const game = familyNfl();
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    for ([_][]const u8{ "Final", "TV: FOX", "Lincoln Financial Field (69596)", "Total", "11-3", "10-4", "Jalen Hurts 1 Yd run", "KC Passing", "Total Yards" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, body, token) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, body, "R   H   E") == null);
    try expectDetailParity(game);
}

test "family nba renders quarters and leaders in text and HTML" {
    const arena = std.testing.allocator;
    const game = familyNba();
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    for ([_][]const u8{ "Final", "TV: TNT", "TD Garden (19156)", "Total", "112", "45-20", "Tatum", "Jayson Tatum" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, body, token) != null);
    }
    try expectDetailParity(game);
}

test "family nhl renders periods and records in text and HTML" {
    const arena = std.testing.allocator;
    const game = familyNhl();
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    for ([_][]const u8{ "Final/OT", "TV: ESPN+", "TD Garden (17850)", "Total", "38-14-9", "Pastrnak" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, body, token) != null);
    }
    try expectDetailParity(game);
}

test "family soccer renders leaders and venue without a grid in text and HTML" {
    const arena = std.testing.allocator;
    const game = familySoccer();
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    for ([_][]const u8{ "Full Time", "TV: NBC", "Emirates Stadium (60704)", "18-3-5", "Saka", "Possession" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, body, token) != null);
    }
    // No period cells upstream: no linescore grid, no R/H/E, no Total.
    try std.testing.expect(std.mem.indexOf(u8, body, "Total") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "R   H   E") == null);
    try expectDetailParity(game);
}

test "family tennis renders athletes, venue, and network in text and HTML" {
    const arena = std.testing.allocator;
    const game = familyTennis();
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    for ([_][]const u8{ "Final", "TV: ESPN2", "Arthur Ashe Stadium", "Carlos Alcaraz", "Jannik Sinner" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, body, token) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, body, "Total") == null);
    try expectDetailParity(game);
}

test "family racing renders the field and circuit in text and HTML" {
    const arena = std.testing.allocator;
    const game = familyRacing();
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    for ([_][]const u8{ "Final", "TV: ESPN", "Monza Circuit (93900)", "Max Verstappen", "Lando Norris" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, body, token) != null);
    }
    try expectDetailParity(game);
}

test "family mma renders the bout, venue, and leaders in text and HTML" {
    const arena = std.testing.allocator;
    const game = familyMma();
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    for ([_][]const u8{ "Final", "TV: PPV", "T-Mobile Arena (19600)", "Islam Makhachev", "Fight of the Night" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, body, token) != null);
    }
    try expectDetailParity(game);
}

test "family golf renders the leaderboard and course in text and HTML" {
    const arena = std.testing.allocator;
    const game = familyGolf();
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    for ([_][]const u8{ "Final", "TV: CBS", "Augusta National", "Scottie Scheffler", "Rory McIlroy" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, body, token) != null);
    }
    try expectDetailParity(game);
}

test "family live baseball renders the situation chip under the network line" {
    const arena = std.testing.allocator;
    const game = familyLiveBaseball();
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    const tv_at = std.mem.indexOf(u8, body, "TV: ESPN").?;
    const chip_at = std.mem.indexOf(u8, body, "2-1, 1 out").?;
    try std.testing.expect(tv_at < chip_at);
    try std.testing.expect(std.mem.indexOf(u8, body, "Aaron Nola vs Ronald Acuna Jr.") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Ball 3 outside.") != null);
    try expectDetailParity(game);
    // Live HTML arms the updater without breaking parity.
    const page = try detailHtml(arena, game, null, null);
    defer arena.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-live") != null);
}

test "family detail without a network skips the TV line on both surfaces" {
    const arena = std.testing.allocator;
    var game = familyNba();
    game.network = null;
    const body = try renderText(arena, game, false, null, null);
    defer arena.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "TV:") == null);
    try expectDetailParity(game);
}
