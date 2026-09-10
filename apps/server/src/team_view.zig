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
/// present, today's upcoming games top-center, last results, then the
/// next games. `height` reaches the overflow tails (`+N more (?height=M)`
/// with query links in the footer); last games always show so recent form
/// reads at a glance. Empty when nothing is scheduled.
/// Team-mark art kill-switch (`?art=off`): when `art` is false the logo
/// block above the header is skipped outright — no dangling blank row —
/// while the header and every section align exactly as with art on.
pub fn renderTextArt(allocator: std.mem.Allocator, view: schedule.TeamView, color: bool, width: ?u16, height: ?u16, art: bool) ![]u8 {
    const cols: usize = @min(@max(width orelse 52, 52), 200);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    // Team logo mark above the header when the generator has one: raw
    // braille lines, no box, no padding (color sidecar when asked).
    const art_mark = if (art) core.art.teamArt(view.league, view.team.abbrev, .xs) else null;
    if (art_mark) |mark| {
        const use_mark = if (color)
            core.art.teamArtColor(view.league, view.team.abbrev, .xs) orelse mark
        else
            mark;
        var lines = std.mem.splitScalar(u8, use_mark, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try table.writeContrastLine(w, line);
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
    // Today: flagged upcoming rows top-center, next[] then extra_next[].
    // Flagged rows skip Next below, so nothing shows twice.
    var today_open = false;
    for (view.next) |game| {
        if (!game.today) continue;
        if (!today_open) {
            try w.writeByte('\n');
            try table.writeLine(w, "Today:", cols, null, color);
            today_open = true;
        }
        try writeTeamGameFull(allocator, w, view.league, game, cols, color);
    }
    for (view.extra_next) |game| {
        if (!game.today) continue;
        if (!today_open) {
            try w.writeByte('\n');
            try table.writeLine(w, "Today:", cols, null, color);
            today_open = true;
        }
        try writeTeamGameFull(allocator, w, view.league, game, cols, color);
    }
    // Overflow reach for the footer query link: a height revealing every
    // hidden row on either side.
    var any_shown = view.live != null or today_open;
    if (view.last.len > 0) {
        try w.writeByte('\n');
        try table.writeLine(w, "Last 5:", cols, null, color);
        for (view.last) |game| try writeTeamGameFull(allocator, w, view.league, game, cols, color);
        any_shown = true;
        const shown_extra = view.extra_past[0..@min(view.extra_past.len, height orelse 0)];
        for (shown_extra) |game| try writeTeamGameFull(allocator, w, view.league, game, cols, color);
        if (shown_extra.len < view.extra_past.len) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more (?height={d})  /{s}/{s}?height={d}", .{ view.extra_past.len - shown_extra.len, view.extra_past.len, view.league, view.team.abbrev, view.extra_past.len });
            defer allocator.free(more);
            try table.writeLine(w, more, cols, "2", color);
        }
    }
    {
        // Upcoming window over the raw array (today rows ride along in
        // the indices but skip display); extras continue it below.
        const upcoming = view.next[0..@min(view.next.len, height orelse view.next.len)];
        var upcoming_total: usize = 0;
        for (view.next) |game| if (!game.today) {
            upcoming_total += 1;
        };
        var extra_total: usize = 0;
        for (view.extra_next) |game| if (!game.today) {
            extra_total += 1;
        };
        const shown_extra = view.extra_next[0..@min(view.extra_next.len, height orelse 0)];
        var shown: usize = 0;
        var shown_extra_unflagged: usize = 0;
        for (shown_extra) |game| if (!game.today) {
            shown_extra_unflagged += 1;
        };
        var next_open = false;
        for (upcoming) |game| {
            if (game.today) continue;
            if (!next_open) {
                try w.writeByte('\n');
                try table.writeLine(w, "Next 5:", cols, null, color);
                next_open = true;
            }
            try writeTeamGameFull(allocator, w, view.league, game, cols, color);
            shown += 1;
        }
        for (shown_extra) |game| {
            if (game.today) continue;
            if (!next_open) {
                try w.writeByte('\n');
                try table.writeLine(w, "Next 5:", cols, null, color);
                next_open = true;
            }
            try writeTeamGameFull(allocator, w, view.league, game, cols, color);
        }
        const hidden = (upcoming_total - shown) + (extra_total - shown_extra_unflagged);
        if (hidden > 0) {
            if (!next_open) {
                try w.writeByte('\n');
                try table.writeLine(w, "Next 5:", cols, null, color);
                next_open = true;
            }
            // A height reaching every row on this side silences the
            // trailer: the upcoming window and the extras window alike.
            const side_height = @max(view.next.len, view.extra_next.len);
            const more = try std.fmt.allocPrint(allocator, "+{d} more (?height={d})  /{s}/{s}?height={d}", .{ hidden, side_height, view.league, view.team.abbrev, side_height });
            defer allocator.free(more);
            try table.writeLine(w, more, cols, "2", color);
        }
        if (next_open) any_shown = true;
    }
    if (!any_shown) {
        try w.writeByte('\n');
        try table.writeLine(w, "No games scheduled.", cols, null, color);
    }
    // Back link plus a query-param expansion link whenever overflow rows
    // stay hidden (replaces the old Earlier/Later sections: previous and
    // next history stay one click away without the wall of rows).
    try w.writeByte('\n');
    try w.print("/{s}\n", .{view.league});
    {
        const shown_past_extra = @min(view.extra_past.len, height orelse 0);
        const shown_next_extra = @min(view.extra_next.len, height orelse 0);
        const hidden = (view.extra_past.len - shown_past_extra) + (view.extra_next.len - shown_next_extra);
        if (hidden > 0) {
            const reach = @max(view.extra_past.len, view.next.len, view.extra_next.len);
            try w.print("more: /{s}/{s}?height={d}\n", .{ view.league, view.team.abbrev, reach });
        }
    }
    return out.toOwnedSlice();
}

/// Wrapper with art on: existing callers keep rendering exactly as before.
pub fn renderText(allocator: std.mem.Allocator, view: schedule.TeamView, color: bool, width: ?u16, height: ?u16) ![]u8 {
    return renderTextArt(allocator, view, color, width, height, true);
}

/// One schedule row plus its probable starter, shared by every section
/// so Today/Last/Next overflow all read the same.
fn writeTeamGameFull(allocator: std.mem.Allocator, w: *std.Io.Writer, league_slug: []const u8, game: schedule.GameRef, cols: usize, color: bool) !void {
    const line = try gameLineFull(allocator, league_slug, game);
    defer allocator.free(line);
    try table.writeLine(w, line, cols, null, color);
    if (game.probable.len > 0) {
        const pline = try std.fmt.allocPrint(allocator, "  Probable: {s}", .{game.probable});
        defer allocator.free(pline);
        try table.writeLine(w, pline, cols, "2", color);
    }
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
pub fn teamHtmlArt(allocator: std.mem.Allocator, view: schedule.TeamView, league_slug: []const u8, width: ?u16, height: ?u16, art: bool) ![]u8 {
    const cols: usize = @min(@max(width orelse 52, 52), 200);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const title = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ view.team.name, view.team.abbrev });
    defer allocator.free(title);
    try render.pageHead(w, title);
    // Colored logo mark as HTML rows: SGR runs become rgb spans via
    // `table.writeArtLineHtml` (mono marks emit plain glyphs). No box,
    // no padding — art lines are ragged by nature.
    const html_mark = if (art)
        core.art.teamArtColor(view.league, view.team.abbrev, .xs) orelse
            core.art.teamArt(view.league, view.team.abbrev, .xs)
    else
        null;
    if (html_mark) |mark| {
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
    // Today: flagged upcoming rows top-center (mirrors text). Flagged
    // rows skip Next below, so nothing shows twice.
    var today_open = false;
    for (view.next) |game| {
        if (!game.today) continue;
        if (!today_open) {
            try w.writeByte('\n');
            try render.writeHtmlLine(w, allocator, "Today:", cols, null, null);
            today_open = true;
        }
        try writeTeamGameFullHtml(allocator, w, league_slug, game, null, cols);
    }
    for (view.extra_next) |game| {
        if (!game.today) continue;
        if (!today_open) {
            try w.writeByte('\n');
            try render.writeHtmlLine(w, allocator, "Today:", cols, null, null);
            today_open = true;
        }
        try writeTeamGameFullHtml(allocator, w, league_slug, game, null, cols);
    }
    const reach_height = @max(view.extra_past.len, view.next.len, view.extra_next.len);
    const more_href = try std.fmt.allocPrint(allocator, "/{s}/{s}?height={d}", .{ league_slug, view.team.abbrev, reach_height });
    defer allocator.free(more_href);
    var any_shown = view.live != null or today_open;
    if (view.last.len > 0) {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "Last 5:", cols, null, null);
        for (view.last) |game| try teamGameHtml(allocator, w, league_slug, game, null, cols);
        any_shown = true;
        const shown_extra = view.extra_past[0..@min(view.extra_past.len, height orelse 0)];
        for (shown_extra) |game| try teamGameHtml(allocator, w, league_slug, game, null, cols);
        if (shown_extra.len < view.extra_past.len) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more (?height={d})", .{ view.extra_past.len - shown_extra.len, view.extra_past.len });
            defer allocator.free(more);
            const href = try std.fmt.allocPrint(allocator, "/{s}/{s}?height={d}", .{ league_slug, view.team.abbrev, view.extra_past.len });
            defer allocator.free(href);
            try render.writeHtmlLine(w, allocator, more, cols, "dim", href);
        }
    }
    {
        const upcoming = view.next[0..@min(view.next.len, height orelse view.next.len)];
        var upcoming_total: usize = 0;
        for (view.next) |game| if (!game.today) {
            upcoming_total += 1;
        };
        var extra_total: usize = 0;
        for (view.extra_next) |game| if (!game.today) {
            extra_total += 1;
        };
        const shown_extra = view.extra_next[0..@min(view.extra_next.len, height orelse 0)];
        var shown: usize = 0;
        var shown_extra_unflagged: usize = 0;
        for (shown_extra) |game| if (!game.today) {
            shown_extra_unflagged += 1;
        };
        var next_open = false;
        for (upcoming) |game| {
            if (game.today) continue;
            if (!next_open) {
                try w.writeByte('\n');
                try render.writeHtmlLine(w, allocator, "Next 5:", cols, null, null);
                next_open = true;
            }
            try writeTeamGameFullHtml(allocator, w, league_slug, game, null, cols);
            shown += 1;
        }
        for (shown_extra) |game| {
            if (game.today) continue;
            if (!next_open) {
                try w.writeByte('\n');
                try render.writeHtmlLine(w, allocator, "Next 5:", cols, null, null);
                next_open = true;
            }
            try writeTeamGameFullHtml(allocator, w, league_slug, game, null, cols);
        }
        const hidden = (upcoming_total - shown) + (extra_total - shown_extra_unflagged);
        if (hidden > 0) {
            if (!next_open) {
                try w.writeByte('\n');
                try render.writeHtmlLine(w, allocator, "Next 5:", cols, null, null);
                next_open = true;
            }
            const side_height = @max(view.next.len, view.extra_next.len);
            const more = try std.fmt.allocPrint(allocator, "+{d} more (?height={d})", .{hidden, side_height});
            defer allocator.free(more);
            const href = try std.fmt.allocPrint(allocator, "/{s}/{s}?height={d}", .{ league_slug, view.team.abbrev, side_height });
            defer allocator.free(href);
            try render.writeHtmlLine(w, allocator, more, cols, "dim", href);
        }
        if (next_open) any_shown = true;
    }
    if (!any_shown) {
        try w.writeByte('\n');
        try render.writeHtmlLine(w, allocator, "No games scheduled.", cols, null, null);
    }
    // Overflow sections are gone (Earlier/Later removed): extras surface
    // inside Last/Next above, and the footer query link below reaches
    // anything still hidden.
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/{s}\">scores</a>", .{league_slug});
    try w.print("<a href=\"/api/v1/{s}/{s}\">json</a>", .{ league_slug, view.team.abbrev });
    {
        const shown_past_extra = @min(view.extra_past.len, height orelse 0);
        const shown_next_extra = @min(view.extra_next.len, height orelse 0);
        if (view.extra_past.len > shown_past_extra or view.extra_next.len > shown_next_extra) {
            try w.print("<a href=\"{s}\">more</a>", .{more_href});
        }
    }
    try render.closePageWithNav(w);
    return out.toOwnedSlice();
}

/// One schedule row plus its probable starter as HTML, shared by every
/// section so Today/Last/Next overflow all read the same.
fn writeTeamGameFullHtml(allocator: std.mem.Allocator, w: *std.Io.Writer, league_slug: []const u8, game: schedule.GameRef, css: ?[]const u8, cols: usize) !void {
    try teamGameHtml(allocator, w, league_slug, game, css, cols);
    if (game.probable.len > 0) {
        const line = try std.fmt.allocPrint(allocator, "  Probable: {s}", .{game.probable});
        defer allocator.free(line);
        try render.writeHtmlLine(w, allocator, line, cols, "dim", null);
    }
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

/// Wrapper with art on: existing callers keep rendering exactly as before.
pub fn teamHtml(allocator: std.mem.Allocator, view: schedule.TeamView, league_slug: []const u8, width: ?u16, height: ?u16) ![]u8 {
    return teamHtmlArt(allocator, view, league_slug, width, height, true);
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
    try std.testing.expect(std.mem.indexOf(u8, capped, "+1 more (?height=2)") != null);
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
    try writeResults(w, arena, view.last);
    try w.writeAll(" | Next: ");
    try writeResults(w, arena, view.next);
    if (view.live) |live| {
        try w.writeAll(" | Live: ");
        if (live.result.len > 0) {
            if (color) {
                try w.print("\x1b[1;31m{s}\x1b[0m", .{live.result});
            } else {
                try w.writeAll(live.result);
            }
        } else {
            const s = try tz.normalizeEastern(arena, live.status);
            defer arena.free(s);
            if (color) {
                try w.print("\x1b[1;31m{s}\x1b[0m", .{s});
            } else {
                try w.writeAll(s);
            }
        }
    }
    try w.writeByte('\n');
    return out.toOwnedSlice();
}

// one-line: comma-joined `result` (else `status`) list, or `none`.
// Empty results fall back to the ESPN status, folded to the generic ET
// convention like every other displayed row time.
fn writeResults(w: *std.Io.Writer, arena: std.mem.Allocator, games: []const schedule.GameRef) !void {
    if (games.len == 0) {
        try w.writeAll("none");
        return;
    }
    for (games, 0..) |game, i| {
        if (i > 0) try w.writeAll(", ");
        if (game.result.len > 0) {
            try w.writeAll(game.result);
        } else {
            const status = try tz.normalizeEastern(arena, game.status);
            defer arena.free(status);
            try w.writeAll(status);
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

test "team depth overflow hides extras by default, height reveals with query links" {
    const output = try renderText(std.testing.allocator, depthOverflowView(), false, null, null);
    defer std.testing.allocator.free(output);
    // No Earlier/Later sections: overflow hides behind trailers + footer.
    try std.testing.expect(std.mem.indexOf(u8, output, "Earlier:") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Later:") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/mlb/old1") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/mlb/fut1") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "+1 more (?height=1)  /mlb/PHI?height=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "+1 more (?height=2)  /mlb/PHI?height=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "more: /mlb/PHI?height=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(output);
    // Pipe-less document style: rows carry the fitted line only, with
    // no box borders anywhere in the page.
    for ([_][]const u8{ "│", "┌", "└", "├", "─" }) |rule| {
        try std.testing.expect(std.mem.indexOf(u8, output, rule) == null);
    }
    // Explicit height reveals the overflow rows with pointers intact.
    const tall = try renderText(std.testing.allocator, depthOverflowView(), false, null, 9);
    defer std.testing.allocator.free(tall);
    try std.testing.expect(std.mem.indexOf(u8, tall, "L 2-4") != null);
    try std.testing.expect(std.mem.indexOf(u8, tall, "/mlb/old1") != null);
    try std.testing.expect(std.mem.indexOf(u8, tall, "Probable: Ranger Suarez") != null);
    var lines = std.mem.splitScalar(u8, tall, '\n');
    var found = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "/mlb/fut1") == null) continue;
        found = true;
        try std.testing.expectEqualStrings("09-09 vs NYM 3:05 PM  /mlb/fut1", line);
    }
    try std.testing.expect(found);
    // Fully revealed: no trailers, no footer query link.
    try std.testing.expect(std.mem.indexOf(u8, tall, "more:") == null);
    try std.testing.expect(std.mem.indexOf(u8, tall, "+1 more") == null);

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
    try std.testing.expect(std.mem.indexOf(u8, capped, "+1 more (?height=3)") != null);
    _ = try std.unicode.Utf8View.init(capped);
}

test "team today section leads with flagged rows, skips them below" {
    var view = testView();
    var next = [_]schedule.GameRef{ view.next[0], view.next[1] };
    next[0].today = true;
    view.next = &next;
    const output = try renderText(std.testing.allocator, view, false, null, null);
    defer std.testing.allocator.free(output);
    // Today opens before Last, carries the flagged game once with link.
    const today_at = std.mem.indexOf(u8, output, "Today:").?;
    const last_at = std.mem.indexOf(u8, output, "Last 5:").?;
    const next_at = std.mem.indexOf(u8, output, "Next 5:").?;
    try std.testing.expect(today_at < last_at);
    try std.testing.expect(last_at < next_at);
    try std.testing.expect(std.mem.indexOf(u8, output, "09-07 vs ATL 1:05 PM  /mlb/live1") != null);
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, output, cursor, "09-07 vs ATL 1:05 PM")) |at| {
        count += 1;
        cursor = at + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    // Next 5 shows the unflagged game only.
    try std.testing.expect(std.mem.indexOf(u8, output[next_at..], "09-08 at ATL 1:05 PM") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[next_at..], "09-07 vs ATL") == null);
    _ = try std.unicode.Utf8View.init(output);
    const page = try teamHtml(std.testing.allocator, view, "mlb", null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Today:") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/live1\">09-07 vs ATL 1:05 PM</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
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
    // No Earlier/Later sections: overflow hides behind trailers + footer.
    try std.testing.expect(std.mem.indexOf(u8, page, "Earlier:") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Later:") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "/mlb/old1") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "/mlb/fut1") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, ">more</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
    // Explicit height reveals the overflow rows with links and escapes.
    const tall = try teamHtml(std.testing.allocator, view, "mlb", null, 9);
    defer std.testing.allocator.free(tall);
    try std.testing.expect(std.mem.indexOf(u8, tall, "<a href=\"/mlb/old1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, tall, "<a href=\"/mlb/fut1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, tall, "A &amp; B &lt;ace&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, tall, ">more</a>") == null);

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

test "team trailers hint at ?height= and empty results read ET" {
    // Capped Next tail names the height that lists everything.
    const capped = try renderText(std.testing.allocator, testView(), false, null, 1);
    defer std.testing.allocator.free(capped);
    try std.testing.expect(std.mem.indexOf(u8, capped, "+1 more (?height=2)") != null);
    const page = try teamHtml(std.testing.allocator, testView(), "mlb", null, 1);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "+1 more (?height=2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    // Empty results fall back to the ESPN status, folded to generic ET.
    var view = testView();
    var next = [_]schedule.GameRef{ view.next[0], view.next[1] };
    next[0].result = "";
    next[0].status = "9/7 - 1:05 PM EDT";
    next[1].result = "";
    next[1].status = "1/15 - 7:00 PM EST";
    view.next = &next;
    view.last = &.{};
    view.live = null;
    const quiet = try renderTextOneLine(std.testing.allocator, view, false, true);
    defer std.testing.allocator.free(quiet);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "9/7 - 1:05 PM ET, 1/15 - 7:00 PM ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "EDT") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "EST") == null);
}

fn containsBraille(s: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == 0xE2 and s[i + 1] >= 0xA0 and s[i + 1] <= 0xA3) return true;
    }
    return false;
}

test "art off strips the team logo, header leads with no dangling blank" {
    const arena = std.testing.allocator;
    // Precondition: PHI really ships a mark, so the strip is meaningful.
    try std.testing.expect(core.art.teamArt("mlb", "PHI", .xs) != null);
    const view = testView();
    const on = try renderText(arena, view, false, null, null);
    defer arena.free(on);
    try std.testing.expect(containsBraille(on));
    const off = try renderTextArt(arena, view, false, null, null, false);
    defer arena.free(off);
    try std.testing.expect(!containsBraille(off));
    _ = try std.unicode.Utf8View.init(off);
    // No dangling blank art row: the header opens the page.
    try std.testing.expect(std.mem.startsWith(u8, off, "Philadelphia Phillies (PHI)"));
    // Layout intact: art-off equals art-on minus the leading mark block
    // (braille lines plus the single blank breathing row after them).
    var header_at: usize = 0;
    var on_lines = std.mem.splitScalar(u8, on, '\n');
    while (on_lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Philadelphia Phillies (PHI)")) break;
        header_at += line.len + 1;
    }
    try std.testing.expect(header_at < on.len);
    try std.testing.expectEqualStrings(on[header_at..], off);
    // Sections survive: record, live, last, next, probables.
    for ([_][]const u8{ "80-63", "LIVE NOW", "Last 5:", "Next 5:", "Probable: Jesus Luzardo" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, off, token) != null);
    }
    // Colored art-off skips the mark too (not just uncolors it).
    const off_color = try renderTextArt(arena, view, true, null, null, false);
    defer arena.free(off_color);
    try std.testing.expect(!containsBraille(off_color));
    try std.testing.expect(std.mem.indexOf(u8, off_color, "\x1b[1;31m") != null);
    // Art on is the default: the wrapper renders byte-identically.
    const explicit = try renderTextArt(arena, view, false, null, null, true);
    defer arena.free(explicit);
    try std.testing.expectEqualStrings(on, explicit);
}

test "art-off team HTML carries no marks, no logo spans" {
    const arena = std.testing.allocator;
    const view = testView();
    const page = try teamHtmlArt(arena, view, "mlb", null, null, false);
    defer arena.free(page);
    try std.testing.expect(!containsBraille(page));
    try std.testing.expect(std.mem.indexOf(u8, page, "rgb(") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Philadelphia Phillies (PHI)") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/401814694\">") != null);
    _ = try std.unicode.Utf8View.init(page);
    // Art on keeps its spans (precondition check, mirrors the text test).
    const on_page = try teamHtml(arena, view, "mlb", null, null);
    defer arena.free(on_page);
    if (core.art.teamArtColor("mlb", "PHI", .xs) != null) {
        try std.testing.expect(std.mem.indexOf(u8, on_page, "<span style=\"color:rgb(") != null);
    }
}
