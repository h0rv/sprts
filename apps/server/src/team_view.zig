//! Per-team text/HTML/JSON views built ONLY on render.zig's existing
//! box primitives (`writeCell`/`writeRow`/`writeRule`/`fit`) via re-export.
//!
//! Seam note for the table-stream owner: this module reaches the private
//! primitives by re-exporting them from render.zig (see the `pub` markers
//! there). If the refactor moves or renames them, this file breaks at
//! compile time at the import — grep for `render.write` uses here. It does
//! not copy any layout logic; alignment rules stay in render.zig.

const std = @import("std");
const core = @import("sprts_core");
const z = @import("zchema");
const schedule = core.schedule;
const render = @import("render.zig");
const router = @import("router.zig");

/// Text view: logo mark, header (name, record, standing), LIVE row when
/// present, last results (up to 5), then the next games (up to 5). `height`
/// caps the next tail (`+N more`); last games always show all five so the
/// recent form reads at a glance. Empty when nothing is scheduled.
pub fn renderText(allocator: std.mem.Allocator, view: schedule.TeamView, color: bool, width: ?u16, height: ?u16) ![]u8 {
    const inner: usize = @min(@max(width orelse 52, 52), 200) - 2;
    const upcoming = view.next[0..@min(view.next.len, height orelse view.next.len)];
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try render.writeRule(w, .top, inner);
    // Team logo mark above the header when the generator has one.
    if (core.art.teamArt(view.league, view.team.abbrev, .xs)) |mark| {
        const use_mark = if (color)
            core.art.teamArtColor(view.league, view.team.abbrev, .xs) orelse mark
        else
            mark;
        var lines = std.mem.splitScalar(u8, use_mark, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try render.writeArtRow(w, line, inner);
        }
        try render.writeRule(w, .mid, inner);
    }
    {
        const header = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ view.team.name, view.team.abbrev });
        defer allocator.free(header);
        try render.writeRow(w, header, inner - 2, null, color);
    }
    if (view.team.record_summary) |record| {
        const line = if (view.team.standing_summary) |standing|
            try std.fmt.allocPrint(allocator, "{s}  {s}", .{ record, standing })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{record});
        defer allocator.free(line);
        try render.writeRow(w, line, inner - 2, "2", color);
    } else if (view.team.standing_summary) |standing| {
        try render.writeRow(w, standing, inner - 2, "2", color);
    }
    if (view.live) |live| {
        try render.writeRule(w, .mid, inner);
        try render.writeRow(w, "LIVE NOW", inner - 2, "1;31", color);
        const live_line = try gameLine(allocator, live);
        defer allocator.free(live_line);
        try render.writeRow(w, live_line, inner - 2, "1;31", color);
    }
    if (view.last.len > 0) {
        try render.writeRule(w, .mid, inner);
        try render.writeRow(w, "Last 5:", inner - 2, null, color);
        for (view.last) |game| {
            const line = try gameLineFull(allocator, view.league, game);
            defer allocator.free(line);
            try render.writeRow(w, line, inner - 2, null, color);
        }
    }
    if (upcoming.len > 0) {
        try render.writeRule(w, .mid, inner);
        try render.writeRow(w, "Next 5:", inner - 2, null, color);
        for (upcoming) |game| {
            const next_line = try gameLineFull(allocator, view.league, game);
            defer allocator.free(next_line);
            try render.writeRow(w, next_line, inner - 2, null, color);
            if (game.probable.len > 0) {
                const line = try std.fmt.allocPrint(allocator, "  Probable: {s}", .{game.probable});
                defer allocator.free(line);
                try render.writeRow(w, line, inner - 2, "2", color);
            }
        }
        if (upcoming.len < view.next.len) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more", .{view.next.len - upcoming.len});
            defer allocator.free(more);
            try render.writeRule(w, .mid, inner);
            try render.writeRow(w, more, inner - 2, "2", color);
        }
    } else if (view.last.len == 0 and view.live == null) {
        try render.writeRule(w, .mid, inner);
        try render.writeRow(w, "No games scheduled.", inner - 2, null, color);
    }
    try render.writeRule(w, .bottom, inner);
    return out.toOwnedSlice();
}

/// One game body line. Final/live results (`"L 4-5"`, `"3-2 Top 7th"`) carry
/// no opponent, so they get `"<date> <vs/at OPP> <result>"`; upcoming
/// results already read `"vs OPP 7:05 PM"`, so they get `"<date> <result>"`.
fn gameLine(allocator: std.mem.Allocator, game: schedule.GameRef) ![]u8 {
    const date = game.date[0..@min(game.date.len, 10)];
    if (std.mem.eql(u8, game.state, "pre")) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ date, game.result });
    }
    const versus = if (std.mem.eql(u8, game.home_away, "away")) "at" else "vs";
    return std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ date, versus, game.opponent_abbrev, game.result });
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
/// (no SGR in HTML): `renderText(mono)` body is only the fallback for
/// sections this builder does not re-emit.
pub fn teamHtml(allocator: std.mem.Allocator, view: schedule.TeamView, league_slug: []const u8, width: ?u16, height: ?u16) ![]u8 {
    const inner: usize = @min(@max(width orelse 52, 52), 200) - 2;
    const upcoming = view.next[0..@min(view.next.len, height orelse view.next.len)];
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const title = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ view.team.name, view.team.abbrev });
    defer allocator.free(title);
    try render.pageHead(w, title);
    try w.writeAll("<pre>");
    try render.writeRule(w, .top, inner);
    if (core.art.teamArt(view.league, view.team.abbrev, .xs)) |mark| {
        var lines = std.mem.splitScalar(u8, mark, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try render.writeArtRow(w, line, inner);
        }
        try render.writeRule(w, .mid, inner);
    }
    {
        const header = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ view.team.name, view.team.abbrev });
        defer allocator.free(header);
        try writeHtmlCell(allocator, header, null, inner, w);
    }
    if (view.team.record_summary) |record| {
        const line = if (view.team.standing_summary) |standing|
            try std.fmt.allocPrint(allocator, "{s}  {s}", .{ record, standing })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{record});
        defer allocator.free(line);
        try writeHtmlCell(allocator, line, "dim", inner, w);
    } else if (view.team.standing_summary) |standing| {
        try writeHtmlCell(allocator, standing, "dim", inner, w);
    }
    if (view.live) |live| {
        try render.writeRule(w, .mid, inner);
        try writeHtmlCell(allocator, "LIVE NOW", "live", inner, w);
        try teamGameHtml(allocator, w, league_slug, live, "live", inner);
    }
    if (view.last.len > 0) {
        try render.writeRule(w, .mid, inner);
        try writeHtmlCell(allocator, "Last 5:", null, inner, w);
        for (view.last) |game| try teamGameHtml(allocator, w, league_slug, game, null, inner);
    }
    if (upcoming.len > 0) {
        try render.writeRule(w, .mid, inner);
        try writeHtmlCell(allocator, "Next 5:", null, inner, w);
        for (upcoming) |game| {
            try teamGameHtml(allocator, w, league_slug, game, null, inner);
            if (game.probable.len > 0) {
                const line = try std.fmt.allocPrint(allocator, "  Probable: {s}", .{game.probable});
                defer allocator.free(line);
                try writeHtmlCell(allocator, line, "dim", inner, w);
            }
        }
        if (upcoming.len < view.next.len) {
            const more = try std.fmt.allocPrint(allocator, "+{d} more", .{view.next.len - upcoming.len});
            defer allocator.free(more);
            try render.writeRule(w, .mid, inner);
            try writeHtmlCell(allocator, more, "dim", inner, w);
        }
    } else if (view.last.len == 0 and view.live == null) {
        try render.writeRule(w, .mid, inner);
        try writeHtmlCell(allocator, "No games scheduled.", null, inner, w);
    }
    try render.writeRule(w, .bottom, inner);
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/{s}\">scores</a>", .{league_slug});
    try w.print("<a href=\"/api/v1/{s}/{s}\">json</a>", .{ league_slug, view.team.abbrev });
    try w.writeAll("</nav></main></body></html>");
    return out.toOwnedSlice();
}

/// One schedule row as HTML: `│ <a>line</a> │` linking to the game view.
/// Empty ids (should not happen; the provider always sets one) render
/// as a plain row rather than a dead link.
fn teamGameHtml(allocator: std.mem.Allocator, w: *std.Io.Writer, league: []const u8, game: schedule.GameRef, css: ?[]const u8, inner: usize) !void {
    const line = try gameLine(allocator, game);
    defer allocator.free(line);
    try w.writeAll("│ ");
    if (game.id.len > 0) {
        try w.print("<a href=\"/{s}/{s}\">", .{ league, game.id });
    }
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try render.writeCell(&cell.writer, line, inner - 2, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    if (css) |class| {
        try w.writeAll("<span class=\"");
        try w.writeAll(class);
        try w.writeAll("\">");
    }
    try render.escapeInto(w, padded);
    if (css != null) try w.writeAll("</span>");
    if (game.id.len > 0) try w.writeAll("</a>");
    try w.writeAll(" │\n");
}

/// Padded + escaped cell with optional color span, no borders or link.
fn writeHtmlCell(allocator: std.mem.Allocator, s: []const u8, css: ?[]const u8, inner: usize, w: *std.Io.Writer) !void {
    try w.writeAll("│ ");
    if (css) |class| {
        try w.writeAll("<span class=\"");
        try w.writeAll(class);
        try w.writeAll("\">");
    }
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try render.writeCell(&cell.writer, s, inner - 2, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    try render.escapeInto(w, padded);
    if (css != null) try w.writeAll("</span>");
    try w.writeAll(" │\n");
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
    try std.testing.expect(std.mem.indexOf(u8, capped, "2026-09-08") == null);

    const colored = try renderText(std.testing.allocator, testView(), true, null, null);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[1;31m") != null);
    const plain = try renderText(std.testing.allocator, testView(), false, null, null);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
}

test "team text renders an empty view and honors width" {
    const empty: schedule.TeamView = .{
        .league = "mlb",
        .league_name = "MLB",
        .team = .{ .id = "22", .abbrev = "PHI", .name = "Philadelphia Phillies" },
    };
    const output = try renderText(std.testing.allocator, empty, false, 80, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "No games scheduled.") != null);
    const eol = std.mem.indexOfScalar(u8, output, '\n').?;
    try std.testing.expectEqual(@as(usize, 3 + 78 * 3 + 3), eol);
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
