//! Per-team text/HTML/JSON views in the pipe-less document style
//! (wttr.in spirit): fitted lines separated by blank lines, no box
//! rules. Line fitting goes through the shared `table.writeLine` and
//! `render.writeHtmlLine`; this module holds no layout logic.

const std = @import("std");
const core = @import("sprts_core");
const z = @import("zchema");
const schedule = core.schedule;
const render = @import("render.zig");
const router = @import("router.zig");
const table = @import("table.zig");
const tz = @import("tz.zig");

/// Text view: logo mark, header (name, record, standing), LIVE row when
/// present, last results (up to 5), then the next games (up to 5). `height`
/// caps the next tail (`+N more`); last games always show all five so the
/// recent form reads at a glance. Empty when nothing is scheduled.
pub fn renderText(allocator: std.mem.Allocator, view: schedule.TeamView, color: bool, width: ?u16, height: ?u16) ![]u8 {
    const cols: usize = @min(@max(width orelse 52, 52), 200);
    const upcoming = view.next[0..@min(view.next.len, height orelse view.next.len)];
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    // Team logo mark above the header when the generator has one: raw
    // braille lines, no box, no padding (color sidecar when asked).
    if (core.art.teamArt(view.league, view.team.abbrev, .xs)) |mark| {
        const use_mark = if (color)
            core.art.teamArtColor(view.league, view.team.abbrev, .xs) orelse mark
        else
            mark;
        var lines = std.mem.splitScalar(u8, use_mark, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try w.writeAll(line);
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
    }
    {
        // one-line: header gains the zone label via `tz.labelFor` (ET default;
        // `?tz=` plumbing stays in main/worker, which this task must not touch).
        const zone_tag = try zoneTag(allocator, view);
        defer allocator.free(zone_tag);
        const header = if (zone_tag.len == 0)
            try std.fmt.allocPrint(allocator, "{s} ({s})", .{ view.team.name, view.team.abbrev })
        else
            try std.fmt.allocPrint(allocator, "{s} ({s})  {s}", .{ view.team.name, view.team.abbrev, zone_tag });
        defer allocator.free(header);
        try table.writeLine(w, header, cols, null, color);
    }
    if (view.team.record_summary) |record| {
        const line = if (view.team.standing_summary) |standing|
            try std.fmt.allocPrint(allocator, "{s}  {s}", .{ record, standing })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{record});
        defer allocator.free(line);
        try table.writeLine(w, line, cols, "2", color);
    } else if (view.team.standing_summary) |standing| {
        try table.writeLine(w, standing, cols, "2", color);
    }
    if (view.live) |live| {
        try w.writeByte('\n');
        try table.writeLine(w, "LIVE NOW", cols, "1;31", color);
        const live_line = try gameLine(allocator, live);
        defer allocator.free(live_line);
        try table.writeLine(w, live_line, cols, "1;31", color);
    }
    if (view.last.len > 0) {
        try w.writeByte('\n');
        try table.writeLine(w, "Last 5:", cols, null, color);
        for (view.last) |game| {
            const line = try gameLineFull(allocator, view.league, game);
            defer allocator.free(line);
            try table.writeLine(w, line, cols, null, color);
        }
    }
    if (upcoming.len > 0) {
        try w.writeByte('\n');
        try table.writeLine(w, "Next 5:", cols, null, color);
        for (upcoming) |game| {
            const next_line = try gameLineFull(allocator, view.league, game);
            defer allocator.free(next_line);
            try table.writeLine(w, next_line, cols, null, color);
            if (game.probable.len > 0) {
                const line = try std.fmt.allocPrint(allocator, "  Probable: {s}", .{game.probable});
                defer allocator.free(line);
                try table.writeLine(w, line, cols, "2", color);
            }
        }
        if (upcoming.len < view.next.len) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more", .{view.next.len - upcoming.len});
            defer allocator.free(more);
            try table.writeLine(w, more, cols, "2", color);
        }
    } else if (view.last.len == 0 and view.live == null) {
        try w.writeByte('\n');
        try table.writeLine(w, "No games scheduled.", cols, null, color);
    }
    // depth: full-season overflow beyond Last/Next 5 (optional; skipped when
    // absent). Each side shows up to `height orelse 5` rows with a `+N more`
    // trailer, mirroring the Next tail. Earlier continues Last newest-first;
    // Later continues Next chronological, with probable starters like Next.
    if (view.extra_past.len > 0) {
        try w.writeByte('\n');
        try table.writeLine(w, "Earlier:", cols, null, color);
        const shown_past = view.extra_past[0..@min(view.extra_past.len, @as(usize, height orelse 5))];
        for (shown_past) |game| {
            const line = try gameLineFull(allocator, view.league, game);
            defer allocator.free(line);
            try table.writeLine(w, line, cols, null, color);
        }
        if (shown_past.len < view.extra_past.len) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more", .{view.extra_past.len - shown_past.len});
            defer allocator.free(more);
            try table.writeLine(w, more, cols, "2", color);
        }
    }
    if (view.extra_next.len > 0) {
        try w.writeByte('\n');
        try table.writeLine(w, "Later:", cols, null, color);
        const shown_next = view.extra_next[0..@min(view.extra_next.len, @as(usize, height orelse 5))];
        for (shown_next) |game| {
            const next_line = try gameLineFull(allocator, view.league, game);
            defer allocator.free(next_line);
            try table.writeLine(w, next_line, cols, null, color);
            if (game.probable.len > 0) {
                const line = try std.fmt.allocPrint(allocator, "  Probable: {s}", .{game.probable});
                defer allocator.free(line);
                try table.writeLine(w, line, cols, "2", color);
            }
        }
        if (shown_next.len < view.extra_next.len) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more", .{view.extra_next.len - shown_next.len});
            defer allocator.free(more);
            try table.writeLine(w, more, cols, "2", color);
        }
    }
    // Back link to the league board, separated like any other section.
    try w.writeByte('\n');
    try w.print("/{s}\n", .{view.league});
    return out.toOwnedSlice();
}

/// Fit `s` to `cols` terminal cells through the shared `table.writeCell`,
/// then strip the padding: document lines breathe instead of forming a
/// box column. Color wraps the fitted bytes only; the padding is trimmed
/// ahead of the reset so the SGR span survives intact.
fn fitLine(allocator: std.mem.Allocator, s: []const u8, cols: usize, code: ?[]const u8, color: bool) ![]u8 {
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try table.writeCell(&cell.writer, s, cols, code, color);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    if (color and code != null and std.mem.endsWith(u8, padded, "\x1b[0m")) {
        const body = std.mem.trimEnd(u8, padded[0 .. padded.len - "\x1b[0m".len], " ");
        return std.fmt.allocPrint(allocator, "{s}\x1b[0m", .{body});
    }
    return allocator.dupe(u8, std.mem.trimEnd(u8, padded, " "));
}

/// One game body line. Final/live results (`"L 4-5"`, `"3-2 Top 7th"`) carry
/// no opponent, so they get `"<date> <vs/at OPP> <result>"`; upcoming
/// results already read `"vs OPP 7:05 PM"`, so they get `"<date> <result>"`.
fn gameLine(allocator: std.mem.Allocator, game: schedule.GameRef) ![]u8 {
    // Eastern calendar day: ESPN instants are UTC, so an 8:20 PM ET kickoff
    // reads as the next UTC day without this shift (matches the ET times
    // already in `result`; `GameRef.date` itself stays a true UTC instant).
    const day = try gameDay(allocator, game.date);
    defer allocator.free(day);
    const prefix = shortDate(day);
    if (std.mem.eql(u8, game.state, "pre")) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, game.result });
    }
    const versus = if (std.mem.eql(u8, game.home_away, "away")) "at" else "vs";
    return std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ prefix, versus, game.opponent_abbrev, game.result });
}

/// Eastern calendar day (`YYYY-MM-DD`) for a schedule instant: full UTC
/// timestamps shift to the Eastern day, date-only strings pass through.
/// Fallback (never errors): unknown shapes keep their raw prefix. Pair
/// with `shortDate` for the `MM-DD` line prefix, or with `tz.labelFor`
/// for the `M/D ZONE` header tag.
fn gameDay(allocator: std.mem.Allocator, iso: []const u8) ![]u8 {
    if (core.date.parseTimestampUTC(iso)) |epoch| {
        return core.date.todayInTz(allocator, epoch, core.date.etOffsetMinutes(epoch));
    }
    return allocator.dupe(u8, iso[0..@min(iso.len, 10)]);
}

/// Short date: `2026-09-08` becomes `09-08`. Matches render.zig's
/// home headers; the year is implicit in the page context.
fn shortDate(day: []const u8) []const u8 {
    if (day.len >= 10 and day[4] == '-' and day[7] == '-') return day[5..10];
    return day;
}

/// Schedule line with a game pointer for linking: the base `gameLine`
/// plus `  /{league}/{id}` so terminals can jump to the game view.
/// HTML callers link the row instead (see `teamScheduleHtml`).
fn gameLineFull(allocator: std.mem.Allocator, league: []const u8, game: schedule.GameRef) ![]u8 {
    const base = try gameLine(allocator, game);
    defer allocator.free(base);
    if (game.id.len == 0) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "{s}  /{s}/{s}", .{ base, league, game.id });
}

/// HTML view: same sections as text (logo, header, live, last 5, next 5),
/// never ANSI, with links. Schedule rows link to their game views; the
/// nav mirrors the scoreboard pages. Logo marks render as plain braille
/// (no SGR in HTML). Sections breathe through blank lines, never rules.
pub fn teamHtml(allocator: std.mem.Allocator, view: schedule.TeamView, league_slug: []const u8, width: ?u16, height: ?u16) ![]u8 {
    const cols: usize = @min(@max(width orelse 52, 52), 200);
    const upcoming = view.next[0..@min(view.next.len, height orelse view.next.len)];
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const title = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ view.team.name, view.team.abbrev });
    defer allocator.free(title);
    try render.pageHead(w, title);
    try w.writeAll("<pre>");
    // Colored logo mark as HTML rows: SGR runs become rgb spans via
    // `table.writeArtLineHtml` (mono marks emit plain glyphs). No box,
    // no padding — art lines are ragged by nature.
    if (core.art.teamArtColor(view.league, view.team.abbrev, .xs) orelse
        core.art.teamArt(view.league, view.team.abbrev, .xs)) |mark|
    {
        var lines = std.mem.splitScalar(u8, mark, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try table.writeArtLineHtml(w, line, escapeByte);
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
    }
    {
        // one-line: header gains the zone label via `tz.labelFor` (ET default; see renderText).
        const zone_tag = try zoneTag(allocator, view);
        defer allocator.free(zone_tag);
        const header = if (zone_tag.len == 0)
            try std.fmt.allocPrint(allocator, "{s} ({s})", .{ view.team.name, view.team.abbrev })
        else
            try std.fmt.allocPrint(allocator, "{s} ({s})  {s}", .{ view.team.name, view.team.abbrev, zone_tag });
        defer allocator.free(header);
        try render.writeHtmlLine(w, allocator, header, cols, null, null);
    }
    if (view.team.record_summary) |record| {
        const line = if (view.team.standing_summary) |standing|
            try std.fmt.allocPrint(allocator, "{s}  {s}", .{ record, standing })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{record});
        defer allocator.free(line);
        try render.writeHtmlLine(w, allocator, line, cols, "dim", null);
    } else if (view.team.standing_summary) |standing| {
        try render.writeHtmlLine(w, allocator, standing, cols, "dim", null);
    }
    if (view.live) |live| {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "LIVE NOW", cols, "live", null);
        try teamGameHtml(allocator, w, league_slug, live, "live", cols);
    }
    if (view.last.len > 0) {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "Last 5:", cols, null, null);
        for (view.last) |game| try teamGameHtml(allocator, w, league_slug, game, null, cols);
    }
    if (upcoming.len > 0) {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "Next 5:", cols, null, null);
        for (upcoming) |game| {
            try teamGameHtml(allocator, w, league_slug, game, null, cols);
            if (game.probable.len > 0) {
                const line = try std.fmt.allocPrint(allocator, "  Probable: {s}", .{game.probable});
                defer allocator.free(line);
                try render.writeHtmlLine(w, allocator, line, cols, "dim", null);
            }
        }
        if (upcoming.len < view.next.len) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more", .{view.next.len - upcoming.len});
            defer allocator.free(more);
            try render.writeHtmlLine(w, allocator, more, cols, "dim", null);
        }
    } else if (view.last.len == 0 and view.live == null) {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "No games scheduled.", cols, null, null);
    }
    // depth: full-season overflow beyond Last/Next 5 (optional; skipped when
    // absent). Same caps and trailers as text; rows link to game views.
    if (view.extra_past.len > 0) {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "Earlier:", cols, null, null);
        const shown_past = view.extra_past[0..@min(view.extra_past.len, @as(usize, height orelse 5))];
        for (shown_past) |game| try teamGameHtml(allocator, w, league_slug, game, null, cols);
        if (shown_past.len < view.extra_past.len) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more", .{view.extra_past.len - shown_past.len});
            defer allocator.free(more);
            try render.writeHtmlLine(w, allocator, more, cols, "dim", null);
        }
    }
    if (view.extra_next.len > 0) {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "Later:", cols, null, null);
        const shown_next = view.extra_next[0..@min(view.extra_next.len, @as(usize, height orelse 5))];
        for (shown_next) |game| {
            try teamGameHtml(allocator, w, league_slug, game, null, cols);
            if (game.probable.len > 0) {
                const line = try std.fmt.allocPrint(allocator, "  Probable: {s}", .{game.probable});
                defer allocator.free(line);
                try render.writeHtmlLine(w, allocator, line, cols, "dim", null);
            }
        }
        if (shown_next.len < view.extra_next.len) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more", .{view.extra_next.len - shown_next.len});
            defer allocator.free(more);
            try render.writeHtmlLine(w, allocator, more, cols, "dim", null);
        }
    }
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/{s}\">scores</a>", .{league_slug});
    try w.print("<a href=\"/api/v1/{s}/{s}\">json</a>", .{ league_slug, view.team.abbrev });
    try render.closePageWithNav(w);
    return out.toOwnedSlice();
}

/// One schedule row as HTML: the fitted line linking to the game view.
/// Empty ids (should not happen; the provider always sets one) render
/// as a plain line rather than a dead link.
fn teamGameHtml(allocator: std.mem.Allocator, w: *std.Io.Writer, league: []const u8, game: schedule.GameRef, css: ?[]const u8, cols: usize) !void {
    const line = try gameLine(allocator, game);
    defer allocator.free(line);
    const trimmed = try fitLine(allocator, line, cols, null, false);
    defer allocator.free(trimmed);
    if (game.id.len > 0) {
        try w.print("<a href=\"/{s}/{s}\">", .{ league, game.id });
    }
    if (css) |class| {
        try w.writeAll("<span class=\"");
        try w.writeAll(class);
        try w.writeAll("\">");
    }
    try render.escapeInto(w, trimmed);
    if (css != null) try w.writeAll("</span>");
    if (game.id.len > 0) try w.writeAll("</a>");
    try w.writeByte('\n');
}


/// One-byte HTML escaper for `table.writeArtLineHtml`: escape `&<>"'`,
/// pass glyph bytes through. Mirrors `render.escapeInto` per byte.
fn escapeByte(w: *std.Io.Writer, b: u8) !void {
    switch (b) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(b),
    }
}

/// JSON view. Validated through the shared `render.validatedJson` gate —
/// see it for why strict `z.serializeAndValidate` is unusable process-wide
/// (zchema's `cachedCompiled` cross-type cache bug, coordinator-owned
/// upstream fix in the external zchema dependency). Same wire format as
/// before, field for field.
pub fn renderJson(allocator: std.mem.Allocator, view: schedule.TeamView) ![]u8 {
    return render.validatedJson(schedule.TeamView, allocator, view);
}

fn testView() schedule.TeamView {
    return .{
        .league = "mlb",
        .league_name = "MLB",
        .team = .{
            .id = "22",
            .abbrev = "PHI",
            .name = "Philadelphia Phillies",
            .record_summary = "80-63",
            .standing_summary = "2nd in NL East",
        },
        .last = &.{.{
            .id = "401814694",
            .date = "2026-09-05T23:10Z",
            .opponent_abbrev = "NYM",
            .opponent_name = "New York Mets",
            .home_away = "home",
            .status = "Final",
            .state = "post",
            .our_score = "5",
            .opp_score = "3",
            .result = "W 5-3",
        }},
        .next = &.{
            .{
                .id = "live1",
                .date = "2026-09-07T17:05Z",
                .opponent_abbrev = "ATL",
                .opponent_name = "Atlanta Braves",
                .home_away = "home",
                .status = "9/7 - 1:05 PM EDT",
                .state = "pre",
                .result = "vs ATL 1:05 PM",
                .probable = "Jesus Luzardo",
            },
            .{
                .id = "401816844",
                .date = "2026-09-08T17:05Z",
                .opponent_abbrev = "ATL",
                .opponent_name = "Atlanta Braves",
                .home_away = "away",
                .status = "9/8 - 1:05 PM EDT",
                .state = "pre",
                .result = "at ATL 1:05 PM",
            },
        },
        .live = .{
            .id = "live1",
            .date = "2026-09-07T17:05Z",
            .opponent_abbrev = "ATL",
            .opponent_name = "Atlanta Braves",
            .home_away = "home",
            .status = "Top 7th",
            .state = "in",
            .our_score = "3",
            .opp_score = "2",
            .result = "3-2 Top 7th",
        },
    };
}

test "team text shows header, live, last, and next with probables" {
    const output = try renderText(std.testing.allocator, testView(), false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Philadelphia Phillies (PHI)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "80-63") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2nd in NL East") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "LIVE NOW") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "3-2 Top 7th") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Last 5:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "W 5-3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/mlb/401814694") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Probable: Jesus Luzardo") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<html") == null);
    _ = try std.unicode.Utf8View.init(output);
}

test "team text honors height and colors live rows" {
    const capped = try renderText(std.testing.allocator, testView(), false, null, 1);
    defer std.testing.allocator.free(capped);
    try std.testing.expect(std.mem.indexOf(u8, capped, "+1 more") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "09-08") == null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "09-07") != null);

    const colored = try renderText(std.testing.allocator, testView(), true, null, null);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[1;31m") != null);
    const plain = try renderText(std.testing.allocator, testView(), false, null, null);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
}

test "team text renders an empty view and honors width" {
    const empty: schedule.TeamView = .{
        // Artless league: no mark precedes the header, so the header
        // opens the pipe-less page.
        .league = "zzz",
        .league_name = "MLB",
        .team = .{ .id = "22", .abbrev = "PHI", .name = "Philadelphia Phillies" },
    };
    const output = try renderText(std.testing.allocator, empty, false, 80, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "No games scheduled.") != null);
    try std.testing.expect(std.mem.startsWith(u8, output, "Philadelphia Phillies (PHI)\n"));
    _ = try std.unicode.Utf8View.init(output);
    // Width honored: every fitted line stays within the 80 columns.
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(table.textCells(line) <= 80);
    }
}

test "team HTML links and never carries ANSI" {
    const page = try teamHtml(std.testing.allocator, testView(), "mlb", null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/scores\">") == null);
    // Schedule rows link to their game views; both last and next shown.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/401814694\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/live1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Last 5:") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Next 5:") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/api/v1/mlb/PHI\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    // Pipe-less like text: no rules or borders anywhere.
    for ([_][]const u8{ "┌", "├", "└", "│", "─" }) |rule| {
        try std.testing.expect(std.mem.indexOf(u8, page, rule) == null);
    }
    // Colored logo: SGR runs become rgb spans, never raw escapes.
    try std.testing.expect(std.mem.indexOf(u8, page, "38;5;") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<span style=\"color:rgb(") != null);

    const err = try @import("render.zig").errorBody(std.testing.allocator, "unknown team; see /api/v1/leagues", .html);
    defer std.testing.allocator.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "unknown team") != null);
}

test "team JSON carries the schema marker and validates" {
    const output = try renderJson(std.testing.allocator, testView());
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"schema_version\": \"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"abbrev\": \"PHI\"") != null);
    // Full parse-back: `renderJson` validates through the shared
    // `render.validatedJson` gate, so the wire output must read back.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(schedule.TeamView, arena_state.allocator(), output, .{});
    try std.testing.expectEqualStrings("PHI", parsed.team.abbrev);
    try std.testing.expectEqual(@as(usize, 2), parsed.next.len);
    // Empty view validates too.
    const empty: schedule.TeamView = .{
        .league = "mlb",
        .league_name = "MLB",
        .team = .{ .id = "22", .abbrev = "PHI", .name = "Philadelphia Phillies" },
    };
    const empty_json = try renderJson(std.testing.allocator, empty);
    defer std.testing.allocator.free(empty_json);
    try std.testing.expect(std.mem.indexOf(u8, empty_json, "\"schema_version\": \"1\"") != null);
}

test "router team route carries display params" {
    const team = router.parse("/mlb/phi?width=90").team;
    try std.testing.expectEqualStrings("phi", team.abbr);
    try std.testing.expect(team.width.? == 90);
}

// one-line: team `?0` support. Additive section (sibling agent
// `views-depth` owns the box renderers above; only the 2-line header
// hooks touch existing functions).

/// Team one-line fallback (`?0`): everything about a team on one line.
///
/// Exact framed shape (`quiet == false`):
///   `{ABBR}[ {record}][  {standing}] | Last: {last} | Next: {next}[ | Live: {live}]`
/// - `{record}` / `{standing}` mirror the box's record line (`{record}  {standing}`,
///   each omitted when absent).
/// - `{last}` / `{next}` are the schedule `GameRef.result` display strings
///   (`"W 5-3"`, `"vs ATL 1:05 PM"`; falls back to `status` when `result` is
///   empty), comma-joined across all entries, or `none` when empty.
/// - ` | Live: {live}` appears only when `view.live` is present.
/// `quiet` drops the `{ABBR} ... | ` identity prefix, leaving the bare
/// `Last: ... | Next: ...[ | Live: ...]` segments. Color tints only the
/// `Live:` result (`1;31`); zero ANSI when `color` is off. Always ends in `\n`.
pub fn renderTextOneLine(arena: std.mem.Allocator, view: schedule.TeamView, color: bool, quiet: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    const w = &out.writer;
    if (!quiet) {
        try w.writeAll(view.team.abbrev);
        if (view.team.record_summary) |record| {
            if (view.team.standing_summary) |standing| {
                try w.print(" {s}  {s}", .{ record, standing });
            } else {
                try w.print(" {s}", .{record});
            }
        } else if (view.team.standing_summary) |standing| {
            try w.print(" {s}", .{standing});
        }
        try w.writeAll(" | ");
    }
    try w.writeAll("Last: ");
    try writeResults(w, view.last);
    try w.writeAll(" | Next: ");
    try writeResults(w, view.next);
    if (view.live) |live| {
        try w.writeAll(" | Live: ");
        const s: []const u8 = if (live.result.len > 0) live.result else live.status;
        if (color) {
            try w.print("\x1b[1;31m{s}\x1b[0m", .{s});
        } else {
            try w.writeAll(s);
        }
    }
    try w.writeByte('\n');
    return out.toOwnedSlice();
}

// one-line: comma-joined `result` (else `status`) list, or `none`.
fn writeResults(w: *std.Io.Writer, games: []const schedule.GameRef) !void {
    if (games.len == 0) {
        try w.writeAll("none");
        return;
    }
    for (games, 0..) |game, i| {
        if (i > 0) try w.writeAll(", ");
        if (game.result.len > 0) {
            try w.writeAll(game.result);
        } else {
            try w.writeAll(game.status);
        }
    }
}

// one-line: header-hook instant (next game first, then live, then first last);
// null when the view carries no games. Full timestamp (not the date
// prefix) so `zoneTag` can shift evening games to the Eastern day.
fn zoneDayFor(view: schedule.TeamView) ?[]const u8 {
    if (view.next.len > 0) return view.next[0].date;
    if (view.live) |live| return live.date;
    if (view.last.len > 0) return view.last[0].date;
    return null;
}

// one-line: `M/D ZONE` header tag via `tz.labelFor` (ET default), or "" when dateless.
// The hook day is an ESPN UTC instant; shift to the Eastern calendar day
// first so evening games tag the day they were played, not the next UTC
// morning (same shift as `gameLine`).
fn zoneTag(allocator: std.mem.Allocator, view: schedule.TeamView) ![]u8 {
    const day = zoneDayFor(view) orelse return allocator.dupe(u8, "");
    const et = try gameDay(allocator, day);
    defer allocator.free(et);
    return tz.labelFor(allocator, et, .et);
}

// one-line: tests (append-only block; box tests above belong to views-depth).
test "team one-line is a single compact line with no box rules" {
    const output = try renderTextOneLine(std.testing.allocator, testView(), false, false);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("PHI 80-63  2nd in NL East | Last: W 5-3 | Next: vs ATL 1:05 PM, at ATL 1:05 PM | Live: 3-2 Top 7th\n", output);
    _ = try std.unicode.Utf8View.init(output);
}

test "team one-line honors quiet framing and strips color when off" {
    const quiet = try renderTextOneLine(std.testing.allocator, testView(), false, true);
    defer std.testing.allocator.free(quiet);
    try std.testing.expectEqualStrings("Last: W 5-3 | Next: vs ATL 1:05 PM, at ATL 1:05 PM | Live: 3-2 Top 7th\n", quiet);
    for ([_][]const u8{ "┌", "├", "└", "│", "─" }) |rule| {
        try std.testing.expect(std.mem.indexOf(u8, quiet, rule) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, quiet, "\x1b[") == null);

    const colored = try renderTextOneLine(std.testing.allocator, testView(), true, false);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[1;31m3-2 Top 7th\x1b[0m") != null);

    const empty: schedule.TeamView = .{
        .league = "mlb",
        .league_name = "MLB",
        .team = .{ .id = "22", .abbrev = "PHI", .name = "Philadelphia Phillies" },
    };
    const bare = try renderTextOneLine(std.testing.allocator, empty, false, false);
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("PHI | Last: none | Next: none\n", bare);
}

test "team game lines and zone tag use the Eastern calendar day" {
    // 2026-09-14T00:20Z is Sept 13, 8:20 PM ET: the UTC date prefix alone
    // would read 09-14. GameRef.date stays the true instant; display shifts.
    const late = schedule.GameRef{
        .id = "x",
        .date = "2026-09-14T00:20Z",
        .opponent_abbrev = "NYG",
        .opponent_name = "New York Giants",
        .home_away = "away",
        .status = "9/13 - 8:20 PM EDT",
        .state = "pre",
        .result = "vs NYG 8:20 PM",
    };
    const line = try gameLine(std.testing.allocator, late);
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, "09-13 "));
    // Date-only strings (no time to shift) pass through untouched.
    const dated = schedule.GameRef{
        .id = "y",
        .date = "2026-09-08",
        .opponent_abbrev = "NYG",
        .opponent_name = "New York Giants",
        .home_away = "home",
        .status = "Final",
        .state = "post",
        .result = "W 5-3",
    };
    const line2 = try gameLine(std.testing.allocator, dated);
    defer std.testing.allocator.free(line2);
    try std.testing.expect(std.mem.startsWith(u8, line2, "09-08 "));
    // The header tag shifts too: next game is the 8:20 PM ET kickoff.
    var view = testView();
    view.live = null;
    view.last = &.{};
    view.next = &.{late};
    const tag = try zoneTag(std.testing.allocator, view);
    defer std.testing.allocator.free(tag);
    try std.testing.expectEqualStrings("9/13 ET", tag);
}

test "team box headers carry the zone label" {
    const text = try renderText(std.testing.allocator, testView(), false, null, null);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Philadelphia Phillies (PHI)  9/7 ET") != null);
    const page = try teamHtml(std.testing.allocator, testView(), "mlb", null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "9/7 ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
}
// depth: full-season overflow sections (appended; existing tests above untouched).
fn depthOverflowView() schedule.TeamView {
    var view = testView();
    view.extra_past = &.{
        .{
            .id = "old1",
            .date = "2026-09-04T19:05Z",
            .opponent_abbrev = "NYM",
            .opponent_name = "New York Mets",
            .home_away = "away",
            .status = "Final",
            .state = "post",
            .our_score = "2",
            .opp_score = "4",
            .result = "L 2-4",
        },
    };
    view.extra_next = &.{
        .{
            .id = "fut1",
            .date = "2026-09-09T19:05Z",
            .opponent_abbrev = "NYM",
            .opponent_name = "New York Mets",
            .home_away = "home",
            .status = "9/9 - 3:05 PM EDT",
            .state = "pre",
            .result = "vs NYM 3:05 PM",
            .probable = "Ranger Suarez",
        },
    };
    return view;
}

test "team depth overflow renders earlier and later with data, skips without" {
    const output = try renderText(std.testing.allocator, depthOverflowView(), false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Earlier:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Later:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "L 2-4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/mlb/old1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/mlb/fut1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Probable: Ranger Suarez") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(output);
    // Pipe-less document style: rows carry the fitted line only, with
    // no box borders anywhere in the page.
    for ([_][]const u8{ "│", "┌", "└", "├", "─" }) |rule| {
        try std.testing.expect(std.mem.indexOf(u8, output, rule) == null);
    }
    var lines = std.mem.splitScalar(u8, output, '\n');
    var found = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "/mlb/fut1") == null) continue;
        found = true;
        try std.testing.expectEqualStrings("09-09 vs NYM 3:05 PM  /mlb/fut1", line);
    }
    try std.testing.expect(found);

    const bare = try renderText(std.testing.allocator, testView(), false, null, null);
    defer std.testing.allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "Earlier:") == null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "Later:") == null);
    _ = try std.unicode.Utf8View.init(bare);
}

test "team depth overflow honors height with trailers" {
    var refs = [_]schedule.GameRef{
        .{ .id = "f1", .date = "2026-09-09T19:05Z", .opponent_abbrev = "NYM", .opponent_name = "New York Mets", .home_away = "home", .status = "pre", .state = "pre", .result = "vs NYM" },
        .{ .id = "f2", .date = "2026-09-10T19:05Z", .opponent_abbrev = "NYM", .opponent_name = "New York Mets", .home_away = "home", .status = "pre", .state = "pre", .result = "vs NYM" },
        .{ .id = "f3", .date = "2026-09-11T19:05Z", .opponent_abbrev = "NYM", .opponent_name = "New York Mets", .home_away = "home", .status = "pre", .state = "pre", .result = "vs NYM" },
    };
    var view = testView();
    view.extra_next = &refs;
    const capped = try renderText(std.testing.allocator, view, false, null, 2);
    defer std.testing.allocator.free(capped);
    try std.testing.expect(std.mem.indexOf(u8, capped, "/mlb/f1") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "/mlb/f2") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "/mlb/f3") == null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "+1 more") != null);
    _ = try std.unicode.Utf8View.init(capped);
}

test "team depth overflow html links and escapes, never ansi" {
    // Copy the overflow row onto the stack before mutating: the fixture
    // slices point at comptime-known (read-only) memory.
    var refs = [_]schedule.GameRef{depthOverflowView().extra_next[0]};
    refs[0].probable = "A & B <ace>";
    var view = depthOverflowView();
    view.extra_next = &refs;
    const page = try teamHtml(std.testing.allocator, view, "mlb", null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Earlier:") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Later:") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/old1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/fut1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "A &amp; B &lt;ace&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);

    const bare = try teamHtml(std.testing.allocator, testView(), "mlb", null, null);
    defer std.testing.allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "Earlier:") == null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "Later:") == null);
}

test "team depth overflow rides the json wire format additively" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const output = try renderJson(arena, depthOverflowView());
    try std.testing.expect(std.mem.indexOf(u8, output, "extra_past") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "extra_next") != null);
    const parsed = try std.json.parseFromSliceLeaky(schedule.TeamView, arena, output, .{});
    try std.testing.expectEqual(@as(usize, 1), parsed.extra_past.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.extra_next.len);
    try std.testing.expectEqualStrings("old1", parsed.extra_past[0].id);
    // Payloads without the fields still parse (additive defaults).
    const legacy = try std.json.parseFromSliceLeaky(schedule.TeamView, arena, try renderJson(arena, testView()), .{});
    try std.testing.expectEqual(@as(usize, 0), legacy.extra_past.len);
    try std.testing.expectEqual(@as(usize, 0), legacy.extra_next.len);
}

