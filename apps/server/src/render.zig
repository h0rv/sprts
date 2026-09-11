const std = @import("std");
const core = @import("sprts_core");
const z = @import("zchema");
const domain = core.domain;
const leagues = core.leagues;
const dates = core.date;
const router = @import("router.zig");
const provider = @import("provider.zig");
const table = @import("table.zig");
const tz = @import("tz.zig");
const view = @import("view.zig");

/// Classic box: 52 terminal columns, 50 between the borders.
const default_inner_width = 50;

/// Shared JSON response gate for every JSON renderer in this binary
/// (`render.json`, `render.leaguesJson`, `detail_view.json`,
/// `team_view.renderJson`).
///
/// Strict `z.serializeAndValidate` cannot be used here: zchema's
/// `cachedCompiled` keys its compiled-schema cache on a `Holder` struct
/// that ignores the generic parameter, so the first type validated in a
/// process wins and every later type validates against the wrong schema
/// (verified: validating `Scoreboard` first makes a strict `GameDetail`
/// check fail with `ResponseValidationFailed`). zchema is an external
/// dependency (root `build.zig.zon`), not vendored, so the cache key
/// cannot be fixed in place; the coordinator owns the upstream fix.
///
/// Until then all renderers validate the same weaker way: serialize with
/// `std.json` and parse back into `T` in scratch memory. Zig types plus
/// required fields are still enforced, so a normalization bug still
/// surfaces instead of silently shipping invalid JSON; JSON Schema
/// constraints (`additionalProperties`, `format`) are not. Validation
/// scratch lives in a temporary arena so `std.testing.allocator` tests
/// don't leak. Field names on the wire are untouched: rendering changes
/// never alter JSON field names.
pub fn validatedJson(comptime T: type, allocator: std.mem.Allocator, value: T) ![]u8 {
    {
        var tmp = std.heap.ArenaAllocator.init(allocator);
        defer tmp.deinit();
        const raw = try std.json.Stringify.valueAlloc(tmp.allocator(), value, .{});
        _ = try std.json.parseFromSliceLeaky(T, tmp.allocator(), raw, .{});
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn json(allocator: std.mem.Allocator, board: domain.Scoreboard) ![]u8 {
    return validatedJson(domain.Scoreboard, allocator, board);
}

test "scoreboard json carries both id and slug" {
    // Additive slug: every game row carries its day-unique human id next
    // to the numeric one, which stays the resolution address. Parse-back
    // through the shared gate proves the shape still validates.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-09",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .slug = "min-det",
                .name = "",
                .starts_at = "2026-09-09T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{},
            },
            .{
                .id = "race",
                .slug = "event-2",
                .name = "Grand Prix",
                .starts_at = "2026-09-09T13:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{},
            },
        },
    };
    const body = try json(arena, board);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\": \"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"slug\": \"min-det\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"slug\": \"event-2\"") != null);
    const parsed = try std.json.parseFromSliceLeaky(domain.Scoreboard, arena, body, .{});
    try std.testing.expectEqualStrings("1", parsed.games[0].id);
    try std.testing.expectEqualStrings("min-det", parsed.games[0].slug);
    try std.testing.expectEqualStrings("event-2", parsed.games[1].slug);
}

/// `width` is total terminal columns of the document (no frame takes
/// space). Never shrinks below the classic 52-wide page; extra room
/// stretches names. `height` caps the games listed (`+N more` trailer);
/// null/0 = all. The heading names its zone (`MLB  2026-09-06 ET`) so
/// output never silently disagrees with ESPN by a day; explicit `?date`
/// boards carry the request zone the same way.
///
/// Pipe-less by design like the detail and team pages: heading, games
/// separated by rules, blank air before the footer nav. Columns align
/// left; rows are ragged, never padded.
/// Team-mark art kill-switch (`?art=off`): when `art` is false every
/// braille logo row is skipped outright — no holes, no dangling blank
/// art rows — while scores, names, and rules align exactly as with art
/// on minus the art rows. Text stays the single source of layout: the
/// HTML renderer derives from this body, so visible text matches.
pub fn textWithZoneArt(allocator: std.mem.Allocator, board: domain.Scoreboard, color: bool, width: ?u16, height: ?u16, zone: tz.Zone, art: bool) ![]u8 {
    const cols: usize = @min(@max(width orelse 52, 52), 200);
    const shown: usize = @min(height orelse board.games.len, board.games.len);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const tag = try tz.zoneTag(allocator, zone);
    defer allocator.free(tag);
    const heading = try view.scoreboardHeading(allocator, board.league_name, board.date, tag);
    defer allocator.free(heading);
    try table.writeLine(w, heading, cols, "2", color);
    try table.writeSeparator(w, cols);
    if (board.games.len == 0) {
        try table.writeLine(w, "No games scheduled.", cols, null, color);
    }
    for (board.games[0..shown]) |game| {
        try table.writeLine(w, game.status, cols, view.statusAnsi(game.state), color);
        if (game.participants.len == 0) {
            try table.writeLine(w, game.name, cols, null, color);
        }
        for (game.participants) |participant| {
            const line = try view.scoreParticipantLine(allocator, participant, cols);
            defer allocator.free(line);
            if (color and participant.winner) try w.writeAll("\x1b[32m");
            try w.writeAll(line);
            if (color and participant.winner) try w.writeAll("\x1b[0m");
            try w.writeByte('\n');
        }
        if (art) try table.writeGameMarks(w, allocator, board.league, &game, cols, color);
        // TV broadcaster the provider carried on the game row (first
        // ESPN `broadcasts[].names` entry, geo-feed fallback): one `TV:`
        // line per game, skipped when the provider supplies none. The
        // HTML linkifier escapes it as plain text (see
        // writeLinkedScoreboard's TV branch), so visible text matches.
        if (game.network) |network| {
            const tv_line = try std.fmt.allocPrint(allocator, "TV: {s}", .{network});
            defer allocator.free(tv_line);
            try table.writeLine(w, tv_line, cols, null, color);
        }
        // Plain-text pointer to the game view; the HTML renderer turns
        // the status row into a real link instead (see scoreHtml).
        {
            const game_link = try view.scoreGameLink(allocator, board.league, board.date, game);
            defer allocator.free(game_link);
            try table.writeLine(w, game_link, cols, "2", color);
        }
        // Separator rule closes each game block: the HTML linkifier keys
        // status rows off it, and it gives dense days a quiet rhythm.
        try table.writeSeparator(w, cols);
    }
    if (shown < board.games.len) {
        const more = try std.fmt.allocPrint(allocator, "+{d} more", .{board.games.len - shown});
        defer allocator.free(more);
        try table.writeLine(w, more, cols, "2", color);
    }
    try w.writeByte('\n');
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

/// Zone-aware wrapper with art on: existing callers (and the digest
/// sections they compose) keep rendering exactly as before.
pub fn textWithZone(allocator: std.mem.Allocator, board: domain.Scoreboard, color: bool, width: ?u16, height: ?u16, zone: tz.Zone) ![]u8 {
    return textWithZoneArt(allocator, board, color, width, height, zone, true);
}

/// ET-default wrapper honoring the art flag.
pub fn textArt(allocator: std.mem.Allocator, board: domain.Scoreboard, color: bool, width: ?u16, height: ?u16, art: bool) ![]u8 {
    return textWithZoneArt(allocator, board, color, width, height, .et, art);
}

/// ET-default wrapper: no `?tz=` means the Eastern day, so existing
/// callers (and the digest sections they compose) keep rendering.
pub fn text(allocator: std.mem.Allocator, board: domain.Scoreboard, color: bool, width: ?u16, height: ?u16) ![]u8 {
    return textWithZone(allocator, board, color, width, height, .et);
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

/// Compact `sprts` wordmark for terminal home pages: the same 13
/// (`logo_dark_svg`, 13 polygons on a 10-unit grid) transliterated row
/// for row at one cell per pixel — s stays the notched block (`██_`/`███`/`_██`), p the bowl with
/// its descender stem, r stem+flag, t the ascender with crossbar and
/// right foot, s again. Letters sit on 3-cell columns with a 2-cell gap:
/// five rows (ascender, three x-height rows, descender) by ~23 columns,
/// ragged right, never ANSI: the heading below keeps its dim color while
/// the banner stays plaintext. Shown on both text homes above the heading
/// (quiet mode skips it with the rest of the header chrome); HTML and
/// JSON never see it.
pub const text_home_banner_small: []const u8 =
    \\                █
    \\██   ███  ███  ███  ██
    \\███  █ █  █     █   ███
    \\ ██  ███  █     ██   ██
    \\     █
++ "\n";

test "text homes show the block sprts wordmark above the heading" {
    // The compact banner itself: block rows, ragged within 26 cells,
    // at most 6 rows, valid UTF-8, zero ANSI on its own.
    var rows: usize = 0;
    var banner_lines = std.mem.splitScalar(u8, text_home_banner_small, '\n');
    while (banner_lines.next()) |line| {
        if (line.len == 0) continue;
        rows += 1;
        try std.testing.expect(std.mem.indexOf(u8, line, "█") != null);
        try std.testing.expect(table.textCells(line) <= 26);
        try std.testing.expect(std.mem.indexOf(u8, line, "\x1b") == null);
    }
    try std.testing.expect(rows <= 6);
    try std.testing.expectEqual(@as(usize, 5), rows);
    _ = try std.unicode.Utf8View.init(text_home_banner_small);

    // Static home: banner opens the page, `sprts` heading unchanged.
    const static = try home(std.testing.allocator, false);
    defer std.testing.allocator.free(static);
    try std.testing.expect(std.mem.startsWith(u8, static, text_home_banner_small));
    try std.testing.expect(std.mem.indexOf(u8, static, "sprts\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, static, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(static);

    // Static home keeps the banner ANSI-free with color on: only the
    // heading below it carries the dim span.
    const static_color = try home(std.testing.allocator, true);
    defer std.testing.allocator.free(static_color);
    try std.testing.expect(std.mem.startsWith(u8, static_color, text_home_banner_small));
    try std.testing.expect(std.mem.indexOf(u8, static_color[0..text_home_banner_small.len], "\x1b[") == null);

    // Live home: banner above the dated heading, heading unchanged.
    var results: [core.leagues.all.len]provider.LeagueResult = undefined;
    for (&core.leagues.all, 0..) |*league, i| results[i] = .{ .league = league };
    const live = try homeLive(std.testing.allocator, false, "example.test", &results, "2026-09-06", false, false);
    defer std.testing.allocator.free(live);
    const banner_at = std.mem.indexOf(u8, live, "██").?;
    const heading_at = std.mem.indexOf(u8, live, "sprts  2026-09-06 ET").?;
    try std.testing.expect(banner_at < heading_at);
    try std.testing.expect(std.mem.indexOf(u8, live, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(live);

    // Colored live home: banner stays plaintext, heading keeps dim.
    const colored = try homeLive(std.testing.allocator, true, "example.test", &results, "2026-09-06", false, false);
    defer std.testing.allocator.free(colored);
    const colored_head = std.mem.indexOf(u8, colored, "sprts  2026-09-06 ET").?;
    try std.testing.expect(colored_head > text_home_banner_small.len);
    try std.testing.expect(std.mem.startsWith(u8, colored, text_home_banner_small));
    try std.testing.expect(std.mem.indexOf(u8, colored[0..text_home_banner_small.len], "\x1b[") == null);

    // Quiet mode drops the banner with the rest of the header chrome.
    const quiet = try homeLive(std.testing.allocator, false, "example.test", &results, "2026-09-06", true, false);
    defer std.testing.allocator.free(quiet);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "█") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "sprts") == null);
}

pub fn home(allocator: std.mem.Allocator, color: bool) ![]u8 {
    return homeDay(allocator, color, null);
}

/// Dated static home: the same league list as `home`, plus the date-nav
/// line under the heading when a day is in hand. Dateless stays
/// byte-identical to `home` (no day, no nav to compute) so the bare
/// landing page never changes.
pub fn homeDay(allocator: std.mem.Allocator, color: bool, day: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(text_home_banner_small);
    try colorize(w, "2", "sprts\n", color);
    if (day) |d| try writeHomeNavLine(w, allocator, d);
    try table.writeSeparator(w, 50);
    for (leagues.all) |league| {
        var cell: std.Io.Writer.Allocating = .init(allocator);
        defer cell.deinit();
        try table.writeCell(&cell.writer, league.slug, 13, null, color);
        try cell.writer.writeByte(' ');
        try table.writeCell(&cell.writer, league.name, 34, null, color);
        const padded = try cell.toOwnedSlice();
        defer allocator.free(padded);
        try w.writeAll(std.mem.trimEnd(u8, padded, " "));
        try w.writeByte('\n');
    }
    try w.writeByte('\n');
    try colorize(w, "2", "Try: curl localhost:8080/mlb\n", color);
    return out.toOwnedSlice();
}

pub const default_host = "localhost:8080";
pub const repo_url = "https://github.com/h0rv/sprts";

/// Host text safe to echo back to clients: hostname characters only,
/// capped in length. Anything else falls back to the local default so a
/// hostile Host header cannot bloat or break the page.
pub fn sanitizeHost(value: ?[]const u8) []const u8 {
    const v = value orelse return default_host;
    if (v.len == 0 or v.len > 64) return default_host;
    for (v) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', ':' => {},
        else => return default_host,
    };
    return v;
}

/// Live home page: leagues with live games first, then the rest of today
/// as compact one-liners, then idle leagues as links. Leagues whose fetch
/// failed render as plain links, so one ESPN outage never fails the page.
/// `dated` selects the explicit-`?date` past view: leagues with an
/// answered-but-empty board (off-day) are skipped entirely — no idle rows,
/// no `ALL LEAGUES` block unless a fetch actually failed — while failed
/// leagues (null board) keep their plain-link degraded rows. Dateless
/// (today) rendering is unchanged.
/// The heading names its zone (`sprts  2026-09-06 ET`); the date-nav line
/// sits directly under it, above the sections (see `writeHomeNavLine`);
/// section rows keep the shared `homeSections` layout untouched (the HTML
/// home owns it too).
pub fn homeLiveWithZone(
    allocator: std.mem.Allocator,
    color: bool,
    host: []const u8,
    boards: []const provider.LeagueResult,
    day: []const u8,
    quiet: bool,
    zone: tz.Zone,
    dated: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    if (!quiet) {
        try w.writeAll(text_home_banner_small);
        const tag = try tz.zoneTag(allocator, zone);
        defer allocator.free(tag);
        const heading = try std.fmt.allocPrint(allocator, "sprts  {s} {s}", .{ day, tag });
        defer allocator.free(heading);
        try colorize(w, "2", heading, color);
        try w.writeByte('\n');
    }
    // Date nav sits directly under the heading (or tops quiet mode,
    // which drops the heading): the same unconditional line the
    // scoreboard footer prints, so navigation never depends on chrome.
    try writeHomeNavLine(w, allocator, day);
    try table.writeSeparator(w, 50);
    try homeSections(allocator, w, boards, color, false, day, dated);
    try w.writeByte('\n');
    if (!quiet) try homeFooter(w, host, color);
    return out.toOwnedSlice();
}

/// ET-default wrapper for `homeLiveWithZone` (`dated=false`: today view).
pub fn homeLive(
    allocator: std.mem.Allocator,
    color: bool,
    host: []const u8,
    boards: []const provider.LeagueResult,
    day: []const u8,
    quiet: bool,
    dated: bool,
) ![]u8 {
    return homeLiveWithZone(allocator, color, host, boards, day, quiet, .et, dated);
}

/// Home one-line (`/?0`): every game today is ONE line, no box, no
/// header/footer — same per-game shape as `scoreOneLine`, across leagues.
/// Idle leagues (no board or no games) emit nothing; with no games at all
/// the body is a single `No games scheduled.` line.
/// Each line carries the zone (`mlb 09-06 ET ...`) via `tz.labelFor`'s zone.
pub fn homeOneLineWithZone(
    allocator: std.mem.Allocator,
    boards: []const provider.LeagueResult,
    color: bool,
    zone: tz.Zone,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var any = false;
    const tag = try tz.zoneTag(allocator, zone);
    defer allocator.free(tag);
    for (boards) |result| {
        const board = result.board orelse continue;
        for (board.games) |game| {
            try writeBoardGameOneLine(&out.writer, result.league.slug, board.date, game, color, tag);
            any = true;
        }
    }
    if (!any) try out.writer.writeAll("No games scheduled.\n");
    return out.toOwnedSlice();
}

/// ET-default wrapper for `homeOneLineWithZone`.
pub fn homeOneLine(
    allocator: std.mem.Allocator,
    boards: []const provider.LeagueResult,
    color: bool,
) ![]u8 {
    return homeOneLineWithZone(allocator, boards, color, .et);
}

/// Home row composers live in the shared `view` module now (Phase 4):
/// `view.homeGameLine` (+ `homeSplitStatus`/`homeGameTail`/
/// `homeShortStatus`/`homeSideText`), `view.homeColumnWidths`, and
/// `view.homeLeagueHeader`. The emitters below (`homeGameLine`,
/// `homeSections`, the HTML linkifier) own links, spans, and section
/// breathing and call those for composition, so text and HTML share
/// every row string.
fn gameIsLive(game: domain.Game) bool {
    return std.mem.eql(u8, game.state, "in");
}

/// Live games first, then one section per league with games today
/// (league header links to the league page in HTML), then idle leagues
/// as links. Leagues with no board (fetch failed) count as idle: the
/// page never fails because of one league. Rules are sparing: the frame
/// opens once at the top and closes once at the bottom; sections breathe
/// through blank spacer rows, never mid rules — the grid stays quiet
/// even on dense days.
fn homeSections(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    boards: []const provider.LeagueResult,
    color: bool,
    comptime html: bool,
    day: []const u8,
    dated: bool,
) !void {
    // Page-wide column widths so league, team, and score columns align
    // down the whole page: widest slug/abbreviation among leagues with
    // shown games (idle-league rows keep their own fixed cells). Floors
    // keep narrow days compact; caps bound exotic abbreviations.
    const widths = view.homeColumnWidths(provider.LeagueResult, boards);
    const slug_w = widths.slug_w;
    const abbr_w = widths.abbr_w;
    var separated = false;
    var live = false;
    for (boards) |result| {
        const board = result.board orelse continue;
        for (board.games) |game| {
            if (gameIsLive(game)) {
                if (!live) {
                    live = true;
                    if (html) {
                        try writeHtmlLine(w, allocator, "LIVE NOW", 50, "live", null);
                    } else {
                        try table.writeLine(w, "LIVE NOW", 50, "1;31", color);
                    }
                }
                try homeGameLine(allocator, w, result.league, board.date, game, color and !html, html, slug_w, abbr_w);
            }
        }
    }
    if (live) separated = true;
    for (boards) |result| {
        const board = result.board orelse continue;
        var has_today = false;
        for (board.games) |game| {
            if (!gameIsLive(game)) {
                has_today = true;
                break;
            }
        }
        if (!has_today) continue;
        if (separated) try w.writeByte('\n');
        // League header: name plus M/D date (year is implicit in the
        // page heading). Whole line links to the league page in HTML.
        const header = try view.homeLeagueHeader(allocator, result.league.name, day);
        defer allocator.free(header);
        if (html) {
            const href = try homeLeagueHref(allocator, result.league.slug, day);
            defer allocator.free(href);
            try writeHtmlLine(w, allocator, header, 50, "dim", href);
        } else {
            try table.writeLine(w, header, 50, "2", color);
        }
        for (board.games) |game| {
            if (gameIsLive(game)) continue;
            try homeGameLine(allocator, w, result.league, board.date, game, color and !html, html, slug_w, abbr_w);
        }
        separated = true;
    }
    var idle_first = true;
    for (boards) |result| {
        const board = result.board;
        if (board != null and board.?.games.len > 0) continue;
        // Dated past view: an answered-but-empty board is an off-day —
        // skip it entirely. A missing board is an upstream failure and
        // keeps its degraded link row (with the ALL LEAGUES header only
        // when such a row exists); today views list every idle league.
        if (dated and board != null) continue;
        if (idle_first) {
            idle_first = false;
            if (separated) try w.writeByte('\n');
            if (html) {
                try writeHtmlLine(w, allocator, "ALL LEAGUES", 50, "dim", null);
            } else {
                try table.writeLine(w, "ALL LEAGUES", 50, "2", color);
            }
        }
        if (html) {
            const href = try homeLeagueHref(allocator, result.league.slug, day);
            defer allocator.free(href);
            try w.writeAll("<a href=\"");
            try escapeInto(w, href);
            try w.writeAll("\">");
        }
        {
            var cell: std.Io.Writer.Allocating = .init(allocator);
            defer cell.deinit();
            try table.writeCell(&cell.writer, result.league.slug, 13, null, false);
            try cell.writer.writeByte(' ');
            try table.writeCell(&cell.writer, result.league.name, 34, null, false);
            const padded = try cell.toOwnedSlice();
            defer allocator.free(padded);
            const trimmed = std.mem.trimEnd(u8, padded, " ");
            if (html) {
                try escapeInto(w, trimmed);
            } else {
                try w.writeAll(trimmed);
            }
        }
        if (html) try w.writeAll("</a>");
        try w.writeByte('\n');
    }
}

/// Padded + escaped cell with optional color span, without borders or
/// link. Shared by home game lines; keeps the span inside the anchor so
/// the whole row stays one link.
fn writeHtmlCell(allocator: std.mem.Allocator, s: []const u8, css: ?[]const u8, w: *std.Io.Writer) !void {
    if (css) |class| {
        try w.writeAll("<span class=\"");
        try w.writeAll(class);
        try w.writeAll("\">");
    }
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try table.writeCell(&cell.writer, s, default_inner_width - 2, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    try escapeCellInto(w, padded);
    if (css != null) try w.writeAll("</span>");
}

/// Section header row for the HTML home renderer (league names, LIVE
/// NOW, ALL LEAGUES): padded cell with optional span and link. Linked
/// headers wrap the trimmed text only; padding stays outside the anchor
/// so underlines never cross the row.
fn writeHtmlRow(allocator: std.mem.Allocator, s: []const u8, css: ?[]const u8, inner: usize, w: *std.Io.Writer, link: ?[]const u8) !void {
    _ = inner;
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try table.writeCell(&cell.writer, s, default_inner_width - 2, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    const trimmed = std.mem.trimEnd(u8, padded, " ");
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
    try escapeCellInto(w, trimmed);
    if (css != null) try w.writeAll("</span>");
    if (link != null) try w.writeAll("</a>");
    var pad: usize = padded.len - trimmed.len;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
    try w.writeAll(" │\n");
}

/// HTML home game line: the whole row is one link to the game view,
/// with the live/upcoming color span inside it.
fn writeHtmlGameLine(allocator: std.mem.Allocator, line: []const u8, game: domain.Game, w: *std.Io.Writer, href: []const u8) !void {
    try w.writeAll("│ ");
    try w.writeAll("<a href=\"");
    try escapeInto(w, href);
    try w.writeAll("\">");
    try writeHtmlCell(allocator, line, view.statusCssClass(game.state), w);
    try w.writeAll("</a> │\n");
}

fn homeGameLine(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    league: *const leagues.League,
    board_date: []const u8,
    game: domain.Game,
    color: bool,
    html: bool,
    slug_w: usize,
    abbr_w: usize,
) !void {
    const line = try view.homeGameLine(allocator, league, game, slug_w, abbr_w) orelse return;
    defer allocator.free(line);
    if (html) {
        // Sibling anchors only: non-team text links the game view,
        // each side links its team page, matching the scoreboard's
        // granular links. The live/upcoming color span wraps the
        // siblings (a span containing anchors is valid HTML). The
        // status word carries the live/upcoming color span.
        const href = try domain.gameHref(allocator, league.slug, board_date, game);
        defer allocator.free(href);
        try writeHtmlHomeGameLine(allocator, line, league, game, w, href);
        return;
    }
    try table.writeLine(w, line, 50, view.statusAnsi(game.state), color);
}

/// HTML home game line: `│ <span><a game>..</a><a team>abbr</a>..</span> │`.
/// Sibling anchors only, never nested: non-team text chunks link to the
/// game view, each participant abbreviation links to its team page. The
/// status word carries the live/upcoming color span. Padding reuses
/// writeCell so the frame aligns with the text renderer.
fn writeHtmlHomeGameLine(allocator: std.mem.Allocator, line: []const u8, league: *const leagues.League, game: domain.Game, w: *std.Io.Writer, href: []const u8) !void {
    try writeLinkedGameCell(allocator, line, league, game, w, href);
    try w.writeByte('\n');
}

/// Cell content for a home game line: the fitted line split into sibling
/// anchors — every non-team chunk links the game view, each participant
/// abbreviation wraps in a team link. Only non-empty abbreviations link:
/// nameless bouts (UFC-style) emit a single game link, so rows stay valid
/// either way. Abbreviations are matched positionally (away first, then
/// home) so a truncated name can never steal another team's link.
/// Unmatched tails (scores, status) ride the trailing game link. The line
/// is ragged (fitted, trailing blanks trimmed); stripping tags
/// concatenates back to the same line, so visible text matches the text
/// renderer byte for byte.
fn writeLinkedGameCell(allocator: std.mem.Allocator, line: []const u8, league: *const leagues.League, game: domain.Game, w: *std.Io.Writer, game_href: []const u8) !void {
    const css = view.statusCssClass(game.state);
    if (css) |class| {
        try w.writeAll("<span class=\"");
        try w.writeAll(class);
        try w.writeAll("\">");
    }
    // Collect the fitted line first so link offsets stay aligned; the
    // line stays ragged (trailing blanks trimmed) so underlines stop at
    // the text and visible text matches the text renderer byte for byte.
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try table.writeCell(&cell.writer, line, 50, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    const trimmed = std.mem.trimEnd(u8, padded, " ");
    var cursor: usize = 0;
    const content = trimmed;
    if (game.participants.len == 2) {
        const first = game.participants[0];
        const second = game.participants[1];
        const away, const home_team = if (std.mem.eql(u8, second.home_away orelse "", "home"))
            .{ first, second }
        else if (std.mem.eql(u8, first.home_away orelse "", "home"))
            .{ second, first }
        else
            .{ first, second };
        for ([2]domain.Participant{ away, home_team }) |part| {
            if (part.abbreviation.len == 0) continue;
            if (std.mem.indexOf(u8, content[cursor..], part.abbreviation)) |rel| {
                const at = cursor + rel;
                if (at > cursor) {
                    try w.writeAll("<a href=\"");
                    try escapeInto(w, game_href);
                    try w.writeAll("\">");
                    try escapeCellInto(w, content[cursor..at]);
                    try w.writeAll("</a>");
                }
                const team_href = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ league.slug, part.abbreviation });
                defer allocator.free(team_href);
                try w.writeAll("<a href=\"");
                try escapeInto(w, team_href);
                try w.writeAll("\">");
                try escapeCellInto(w, part.abbreviation);
                try w.writeAll("</a>");
                cursor = at + part.abbreviation.len;
            }
        }
    }
    if (content[cursor..].len > 0) {
        try w.writeAll("<a href=\"");
        try escapeInto(w, game_href);
        try w.writeAll("\">");
        try escapeCellInto(w, content[cursor..]);
        try w.writeAll("</a>");
    }
    if (css != null) try w.writeAll("</span>");
}

fn homeFooter(w: *std.Io.Writer, host: []const u8, color: bool) !void {
    try colorize(w, "2", "Try: curl ", color);
    try colorize(w, "2", host, color);
    try colorize(w, "2", "/mlb\n", color);
    try colorize(w, "2", "Docs: ", color);
    try colorize(w, "2", host, color);
    try colorize(w, "2", "/docs\n", color);
    try colorize(w, "2", "Code: " ++ repo_url ++ "\n", color);
}

fn writeBoardGameOneLine(w: *std.Io.Writer, league_slug: []const u8, board_date: []const u8, game: domain.Game, color: bool, zone_tag: []const u8) !void {
    const code: ?[]const u8 = if (color) view.statusAnsi(game.state) else null;
    if (code) |c| try w.print("\x1b[{s}m", .{c});
    try w.writeAll(league_slug);
    try w.writeByte(' ');
    try w.writeAll(view.shortDate(board_date));
    try w.writeByte(' ');
    try w.writeAll(zone_tag);
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
            try w.print(" {s} {s} @ {s} {s}", .{
                away.abbreviation, away.score, home_team.abbreviation, home_team.score,
            });
            if (away.winner or home_team.winner) try w.writeAll(" ✓");
        } else {
            try w.print(" {s} @ {s}", .{ away.abbreviation, home_team.abbreviation });
        }
    } else if (game.name.len > 0) {
        try w.writeByte(' ');
        try w.writeAll(game.name);
        var won = false;
        for (game.participants) |p| if (p.winner) {
            won = true;
            break;
        };
        if (won) try w.writeAll(" ✓");
    } else if (game.participants.len > 0) {
        for (game.participants, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte(' ');
            try w.writeAll(p.abbreviation);
        }
    }
    if (code) |_| try w.writeAll("\x1b[0m");
    try w.writeByte('\n');
}

/// True when any participant in the first `shown` games has a color mark.
/// The score HTML linkifier only reads the color twin on art rows, so a
/// false here means the twin render can be skipped with identical output.
/// Pub so the digest HTML composer can reuse the same fast path per
/// section (see `digest.htmlWithZoneArt`).
pub fn boardHasColorArt(board: domain.Scoreboard, shown: usize) bool {
    for (board.games[0..shown]) |game| {
        for (game.participants) |participant| {
            if (core.art.teamArtColor(board.league, participant.abbreviation, .xs) != null) return true;
        }
    }
    return false;
}

/// Minimal browser page: the same table as text, never ANSI, with real
/// links. Browsers cannot use terminal escapes, so SGR never reaches the
/// page raw: team marks re-render as rgb spans while the text renderer
/// stays the single source of layout.
/// The title and the table heading both name the zone
/// (`MLB scores 2026-09-06 ET`); the date nav stays date-only.
pub fn scoreHtmlWithZoneArt(allocator: std.mem.Allocator, board: domain.Scoreboard, width: ?u16, height: ?u16, zone: tz.Zone, art: bool) ![]u8 {
    return scoreHtmlWithZoneArtMtime(allocator, board, width, height, zone, art, 0);
}

/// Scoreboard HTML with the render epoch for the freshness line: live
/// boards (`state == "in"`) arm `<pre data-live="1">` plus the fresh div
/// and live script; final boards render exactly as `scoreHtmlWithZoneArt`
/// always did (no marker, no div, no script — static bytes unchanged).
// `mtime_s` is the render epoch stamping the fresh div; callers pass the
// request clock, tests pass a fixed epoch.
pub fn scoreHtmlWithZoneArtMtime(allocator: std.mem.Allocator, board: domain.Scoreboard, width: ?u16, height: ?u16, zone: tz.Zone, art: bool, mtime_s: i64) ![]u8 {
    const shown_pre: usize = @min(height orelse board.games.len, board.games.len);
    const body = try textWithZoneArt(allocator, board, false, width, height, zone, art);
    defer allocator.free(body);
    // Fast path: no shown participant has a color mark, so the linkifier
    // never reads the color twin (only art rows consult it). Reuse the
    // mono body instead of rendering the full table twice. With art off
    // there are no art rows at all, so the twin is skipped the same way.
    var color_owned: ?[]u8 = null;
    defer if (color_owned) |b| allocator.free(b);
    if (art and boardHasColorArt(board, shown_pre)) {
        color_owned = try textWithZoneArt(allocator, board, true, width, height, zone, art);
    }
    const color_body = color_owned orelse body;
    const previous = try dates.shift(allocator, board.date, -1);
    defer allocator.free(previous);
    const next = try dates.shift(allocator, board.date, 1);
    defer allocator.free(next);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const tag = try tz.zoneTag(allocator, zone);
    defer allocator.free(tag);
    const title = try std.fmt.allocPrint(allocator, "{s} scores {s} {s}", .{ board.league_name, board.date, tag });
    defer allocator.free(title);
    try pageHeadLive(w, title, boardIsLive(board));
    const shown: usize = shown_pre;
    const inner: usize = @min(@max(width orelse 52, 52), 200) - 2;
    try writeLinkedScoreboard(w, allocator, board, body, color_body, inner, shown, true);
    try w.writeAll("</pre>");
    try writeScoreSummaries(w, board, shown);
    // Live pages stream: freshness line plus the updater script. Final
    // pages stay byte-identical to the static render (no div, no script).
    if (boardIsLive(board)) {
        try writeFreshDiv(w, allocator, mtime_s);
        try w.writeAll(live_script);
    }
    try w.writeAll("<nav>");
    try w.print("<a href=\"/{s}?date={s}\">earlier</a>", .{ board.league, previous });
    try w.print("<a href=\"/{s}\">today</a>", .{board.league});
    try w.print("<a href=\"/{s}?date={s}\">later</a>", .{ board.league, next });
    try w.print("<a href=\"/api/v1/{s}?date={s}\">json</a>", .{ board.league, board.date });
    try closePageWithNav(w);
    return out.toOwnedSlice();
}

/// ET-default wrapper for `scoreHtmlWithZone`.
pub fn scoreHtml(allocator: std.mem.Allocator, board: domain.Scoreboard, width: ?u16, height: ?u16) ![]u8 {
    return scoreHtmlWithZone(allocator, board, width, height, .et);
}

/// Zone-aware wrapper with art on: existing callers keep rendering
/// exactly as before.
pub fn scoreHtmlWithZone(allocator: std.mem.Allocator, board: domain.Scoreboard, width: ?u16, height: ?u16, zone: tz.Zone) ![]u8 {
    return scoreHtmlWithZoneArt(allocator, board, width, height, zone, true);
}

/// ET-default wrapper honoring the art flag.
pub fn scoreHtmlArt(allocator: std.mem.Allocator, board: domain.Scoreboard, width: ?u16, height: ?u16, art: bool) ![]u8 {
    return scoreHtmlWithZoneArt(allocator, board, width, height, .et, art);
}

/// Post-pass linkifier for `scoreHtml`: re-emits the plain-text table
/// line by line, wrapping each game's status cell in a
/// `<a href="/{league}/{id}" id="game-{id}">` anchor and each team's
/// abbreviation/name in `<a href="/{league}/{abbr}">` anchors. The
/// `text` renderer stays the single source of layout: only invisible
/// tags are added, so the visible text matches `text(color=false)`
/// byte for byte. Everything — including built hrefs — escapes via
/// `escapeInto`, so hostile provider text (`<OT>`-style statuses) can
/// never break the page. Team marks ride along in color: art rows
/// (braille, no participant hit) re-emit from a color=true twin body via
/// `table.writeArtLineHtml`, so SGR becomes rgb spans and `\x1b[` never
/// reaches the page. Every other row uses the mono body, so the visible
/// text still matches `text(color=false)` byte for byte.
///
/// Pub so the digest HTML composer reuses it per league section (see
/// `digest.htmlWithZoneArt`): one call per section with that section's
/// board slice. `heading_as_h1` selects whether the section heading
/// doubles as the page `<h1>` title (the skip link's `#content`
/// target): true for a standalone board and the digest's first section,
/// false for later digest sections so the page keeps exactly one `<h1>`.
/// A demoted heading escapes as plain text, so visible text is identical
/// either way.
pub fn writeLinkedScoreboard(w: *std.Io.Writer, allocator: std.mem.Allocator, board: domain.Scoreboard, body: []const u8, color_body: []const u8, inner: usize, shown: usize, heading_as_h1: bool) !void {
    _ = inner;
    var game_idx: usize = 0;
    var current: ?usize = null;
    var part_pos: usize = 0;
    var pending_rule = false;
    var first_row = heading_as_h1;
    // Name-only games (no participants) link exactly one content row
    // (the name); every later row in the block — the `TV:` line, the
    // plain-text game pointer — escapes as plain text. Participant games
    // consume rows positionally via `part_pos` instead.
    var name_linked = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var color_lines = std.mem.splitScalar(u8, color_body, '\n');
    while (lines.next()) |line| {
        // Lockstep twin: same layout, plus SGR on art rows (and ANSI
        // elsewhere, which only art rows ever read). Desync falls back
        // to the mono line, never to raw escapes.
        const color_line = color_lines.next() orelse line;
        if (line.len == 0) {
            // Blank separators breathe; the body's single trailing empty
            // (after its final newline) carries no row.
            if (lines.peek() == null) continue;
            try w.writeByte('\n');
            continue;
        }
        if (table.isRuleLine(line)) {
            try escapeInto(w, line);
            try w.writeByte('\n');
            if (current != null and game_idx >= shown) {
                // No more game slots: the next row is the `+N more`
                // trailer, not a new game.
                current = null;
            }
            pending_rule = true;
            continue;
        }
        if (line[0] == '/') {
            // The trailing `/{league}?date=` footer carries no links.
            try escapeInto(w, line);
            try w.writeByte('\n');
            continue;
        }
        if (first_row) {
            // Heading row doubles as the page `<h1>` title (the skip
            // link's `#content` target): league context already, no link.
            first_row = false;
            try w.writeAll(h1_open);
            try escapeInto(w, line);
            try w.writeAll("</h1>\n");
            continue;
        }
        if (pending_rule) {
            pending_rule = false;
            if (game_idx < shown) {
                const game = &board.games[game_idx];
                current = game_idx;
                part_pos = 0;
                name_linked = false;
                game_idx += 1;
                try writeGameStatusRow(w, allocator, board.league, board.date, game, line, true);
                continue;
            }
            // `+N more` trailer or the empty-schedule note.
            current = null;
            try escapeInto(w, line);
            try w.writeByte('\n');
            continue;
        }
        if (current) |gi| {
            const game = &board.games[gi];
            // TV broadcaster line (`TV: {network}`, emitted by
            // `textWithZoneArt` after the art rows): plain escaped text,
            // never a link. It always follows every participant row, so
            // requiring the cursor (or the single name row) to be spent
            // keeps a hostile `TV: ...` participant name linkable.
            if (game.network != null and std.mem.startsWith(u8, line, "TV: ")) {
                const spent = if (game.participants.len == 0) name_linked else part_pos >= game.participants.len;
                if (spent) {
                    try escapeInto(w, line);
                    try w.writeByte('\n');
                    continue;
                }
            }
            if (game.participants.len == 0) {
                if (!name_linked) {
                    // Name-only game row: the name stands in for the game,
                    // so link it too but skip the anchor id — the status
                    // row above already owns `game-{id}`.
                    name_linked = true;
                    try writeGameStatusRow(w, allocator, board.league, board.date, game, line, false);
                    continue;
                }
                // Later rows in a name-only block (TV line, pointer)
                // are plain text: the two links above already navigate.
                try escapeInto(w, line);
                try w.writeByte('\n');
                continue;
            }
            if (isColorArtRow(line, game, part_pos)) {
                // Colored mark row: spans, no link, cursor untouched.
                try writeColorArtRow(w, color_line);
                continue;
            }
            try writeLinkedParticipantRow(w, allocator, board.league, game, &part_pos, line);
            continue;
        }
        try escapeInto(w, line);
        try w.writeByte('\n');
    }
}

/// Status (or name-only) row for one game: the trimmed line becomes the
/// game link and carries the per-game anchor id. The href is the human
/// `/{league}/{date}/{slug}` (numeric legacy fallback inside), while the
/// anchor id stays the numeric game id so fragment links never rot.
/// Made `with_id` so a caller can reuse the wrapper for rows that already
/// live inside a linked context without duplicating ids. Padding never
/// enters the anchor, so underlines stop at the text.
fn writeGameStatusRow(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    league_slug: []const u8,
    board_date: []const u8,
    game: *const domain.Game,
    line: []const u8,
    with_id: bool,
) !void {
    const trimmed = std.mem.trimEnd(u8, line, " ");
    const href = try domain.gameHref(allocator, league_slug, board_date, game.*);
    defer allocator.free(href);
    try w.writeAll("<a href=\"");
    try escapeInto(w, href);
    if (with_id) {
        try w.writeAll("\" id=\"game-");
        try escapeInto(w, game.id);
    }
    try w.writeAll("\">");
    try escapeInto(w, trimmed);
    try w.writeAll("</a>");
    try w.writeByte('\n');
}

/// Participant row: link the row's own participant to its team page.
/// Rows are consumed positionally per game — the Nth post-pass row maps
/// to the Nth participant — so art rows (which the renderer emits as
/// whole side-by-side pairs, not per participant) must never advance
/// the cursor. A row is linked only when it still carries its own
/// participant's abbreviation (survives truncation best) or full name;
/// art rows never match either and fall through as escaped plain text.
/// Empty-abbr (athlete-style) rows stay unlinked — there is no team
/// page to point at — while the game anchor above still navigates.
fn writeLinkedParticipantRow(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    league_slug: []const u8,
    game: *const domain.Game,
    part_pos: *usize,
    line: []const u8,
) !void {
    if (part_pos.* >= game.participants.len) {
        // Marks or overflow padding: no participant left to link.
        try escapeInto(w, line);
        try w.writeByte('\n');
        return;
    }
    const p = &game.participants[part_pos.*];
    const abbr_hit = p.abbreviation.len > 0 and std.mem.indexOf(u8, line, p.abbreviation) != null;
    const name_hit = p.name.len > 0 and std.mem.indexOf(u8, line, p.name) != null;
    if (!abbr_hit and !name_hit) {
        // Mark row or wrapped art: keep the cursor, no link.
        try escapeInto(w, line);
        try w.writeByte('\n');
        return;
    }
    part_pos.* += 1;
    if (p.abbreviation.len == 0) {
        try escapeInto(w, line);
        try w.writeByte('\n');
        return;
    }
    const href = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ league_slug, p.abbreviation });
    defer allocator.free(href);
    var cursor: usize = 0;
    if (std.mem.indexOf(u8, line[cursor..], p.abbreviation)) |rel| {
        const at = cursor + rel;
        try escapeInto(w, line[cursor..at]);
        try w.writeAll("<a href=\"");
        try escapeInto(w, href);
        try w.writeAll("\">");
        try escapeInto(w, p.abbreviation);
        try w.writeAll("</a>");
        cursor = at + p.abbreviation.len;
    }
    // A truncated name (ellipsis) is absent from the line, so only link
    // it when the full name is present; the abbr link above stays.
    if (p.name.len > 0) {
        if (std.mem.indexOf(u8, line[cursor..], p.name)) |rel| {
            const at = cursor + rel;
            try escapeInto(w, line[cursor..at]);
            try w.writeAll("<a href=\"");
            try escapeInto(w, href);
            try w.writeAll("\">");
            try escapeInto(w, p.name);
            try w.writeAll("</a>");
            cursor = at + p.name.len;
        }
    }
    try escapeInto(w, line[cursor..]);
    try w.writeByte('\n');
}

/// Art-row detector for the linkifier: a row inside a game that carries
/// braille but neither the current participant's abbreviation nor name.
/// Mirrors `writeLinkedParticipantRow`'s miss condition exactly so the two
/// can never disagree about what links: anything flagged here is a row
/// the linker would have left unlinked with the cursor held.
/// Order-agnostic: marks render AFTER the participant rows, so trailing
/// art rows arrive with the cursor exhausted (`part_pos >= len`). Those
/// still carry braille and match no participant's abbr/name; the pointer
/// row also arrives with the cursor exhausted but carries no braille, so
/// it stays unflagged. Checking every participant in the exhausted case
/// keeps the mirror exact (the linker would miss there too).
fn isColorArtRow(line: []const u8, game: *const domain.Game, part_pos: usize) bool {
    if (part_pos < game.participants.len) {
        const p = &game.participants[part_pos];
        if (p.abbreviation.len > 0 and std.mem.indexOf(u8, line, p.abbreviation) != null) return false;
        if (p.name.len > 0 and std.mem.indexOf(u8, line, p.name) != null) return false;
        return containsBraille(line);
    }
    for (game.participants) |*q| {
        if (q.abbreviation.len > 0 and std.mem.indexOf(u8, line, q.abbreviation) != null) return false;
        if (q.name.len > 0 and std.mem.indexOf(u8, line, q.name) != null) return false;
    }
    return containsBraille(line);
}

/// True when the line holds braille cells (U+2800-U+28FF: E2 A0-A3 ...).
/// Box rules (E2 94), the winner check (E2 9C), and the ellipsis
/// (E2 80) never match, so only mark rows qualify.
fn containsBraille(line: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        if (line[i] == 0xE2 and line[i + 1] >= 0xA0 and line[i + 1] <= 0xA3) return true;
    }
    return false;
}

/// One colored mark row as HTML: the color twin's line becomes rgb spans
/// via `table.writeArtLineHtml`, ragged like the text renderer.
/// Link-free and cursor-free by construction, and `aria-hidden` so
/// assistive tech skips the braille (the sr-only game summaries after
/// `</pre>` carry the same game instead).
fn writeColorArtRow(
    w: *std.Io.Writer,
    color_line: []const u8,
) !void {
    try w.writeAll("<span aria-hidden=\"true\">");
    try table.writeArtLineHtml(w, color_line, &htmlEscapeByte);
    try w.writeAll("</span>\n");
}

/// One-byte HTML escaper for `table.writeArtLineHtml`: escape `&<>"'`,
/// pass glyph bytes through. Mirrors `escapeInto` per byte.
fn htmlEscapeByte(w: *std.Io.Writer, b: u8) !void {
    switch (b) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(b),
    }
}

/// One borderless HTML content line for the document-style views (game
/// detail, team): fitted to `cols` exactly like the text renderer
/// (truncate, trailing blanks trimmed), then optional link wrapping,
/// optional span class, newline. Column rows arrive pre-composed so text
/// and HTML share the same strings and the visible text stays identical.
pub fn writeHtmlLine(w: *std.Io.Writer, allocator: std.mem.Allocator, s: []const u8, cols: usize, css: ?[]const u8, link: ?[]const u8) !void {
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try table.writeCell(&cell.writer, s, cols, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    const trimmed = std.mem.trimEnd(u8, padded, " ");
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
    try escapeInto(w, trimmed);
    if (css != null) try w.writeAll("</span>");
    if (link != null) try w.writeAll("</a>");
    try w.writeByte('\n');
}

/// Title-line variant of `writeHtmlLine`: the fitted row becomes the page
/// `<h1>` (the skip link's `#content` target) with identical text and no
/// link. UA margins die in CSS, so the row keeps its exact box and
/// `<pre>` visible text never changes.
pub fn writeHtmlH1(w: *std.Io.Writer, allocator: std.mem.Allocator, s: []const u8, cols: usize, css: ?[]const u8) !void {
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try table.writeCell(&cell.writer, s, cols, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    const trimmed = std.mem.trimEnd(u8, padded, " ");
    try w.writeAll(h1_open);
    if (css) |class| {
        try w.writeAll("<span class=\"");
        try w.writeAll(class);
        try w.writeAll("\">");
    }
    try escapeInto(w, trimmed);
    if (css != null) try w.writeAll("</span>");
    try w.writeAll("</h1>\n");
}

/// Escape a whole text body blob with its first line wrapped as the page
/// `<h1>` title (help, standings, digest share this shape). The tags strip
/// clean, so `<pre>` visible text never changes.
pub fn writeEscapedBodyH1(w: *std.Io.Writer, body: []const u8) !void {
    if (std.mem.indexOfScalar(u8, body, '\n')) |nl| {
        try w.writeAll(h1_open);
        try escapeInto(w, body[0..nl]);
        try w.writeAll("</h1>\n");
        try escapeInto(w, body[nl + 1 ..]);
    } else if (body.len > 0) {
        try w.writeAll(h1_open);
        try escapeInto(w, body);
        try w.writeAll("</h1>");
    }
}

/// Wrap the first line of an already-rendered HTML block as the page
/// `<h1>` title; remaining bytes pass through untouched. Used where the
/// title line is positional (the live home's first section row), never
/// structural: tags strip clean, so visible text never changes.
fn writeH1FirstLine(w: *std.Io.Writer, rendered: []const u8) !void {
    if (std.mem.indexOfScalar(u8, rendered, '\n')) |nl| {
        if (nl == 0) {
            try w.writeAll(rendered);
            return;
        }
        try w.writeAll(h1_open);
        try w.writeAll(rendered[0..nl]);
        try w.writeAll("</h1>\n");
        try w.writeAll(rendered[nl + 1 ..]);
    } else if (rendered.len > 0) {
        try w.writeAll(h1_open);
        try w.writeAll(rendered);
        try w.writeAll("</h1>");
    }
}

/// Screen-reader game summaries for scoreboard pages: one visually-hidden
/// paragraph per shown game (`Game {id}: {status}...`), emitted after
/// `</pre>` so tag-stripped visible-text assertions never see them. Art
/// rows inside the table are `aria-hidden`; these paragraphs are their
/// non-visual equivalent (game id, status, and sides always present).
fn writeScoreSummaries(w: *std.Io.Writer, board: domain.Scoreboard, shown: usize) !void {
    if (shown == 0) return;
    try w.writeAll("<div class=\"sr-only\">");
    for (board.games[0..shown]) |game| {
        try w.writeAll("<p>Game ");
        try escapeInto(w, game.id);
        try w.writeAll(": ");
        try escapeInto(w, game.status);
        if (game.participants.len > 0) {
            try w.writeAll(". ");
            for (game.participants, 0..) |p, i| {
                if (i > 0) try w.writeAll(" vs ");
                if (p.name.len > 0) {
                    try escapeInto(w, p.name);
                } else if (p.abbreviation.len > 0) {
                    try escapeInto(w, p.abbreviation);
                }
                if (p.score.len > 0) {
                    try w.writeByte(' ');
                    try escapeInto(w, p.score);
                }
            }
        } else if (game.name.len > 0) {
            try w.writeAll(". ");
            try escapeInto(w, game.name);
        }
        try w.writeAll("</p>");
    }
    try w.writeAll("</div>");
}

/// Prev/next dates for a home day, via the same `dates.shift` the
/// scoreboard footer uses — month boundaries roll over by construction
/// (`2026-09-01` → `2026-08-31`). Returned owned; callers free both.
/// Shared composer behind the text and HTML nav lines so the two homes
/// can never disagree on the dates. Null unless `day` is a strict
/// calendar date: serve paths resolve tokens first, so renderers always
/// see strict days in practice; hostile text renders no nav instead of
/// failing the page (the league-href escaping tests pin this).
fn homeNavDates(allocator: std.mem.Allocator, day: []const u8) !?struct { prev: []u8, next: []u8 } {
    if (!dates.validate(day)) return null;
    const prev = try dates.shift(allocator, day, -1);
    errdefer allocator.free(prev);
    const next = try dates.shift(allocator, day, 1);
    return .{ .prev = prev, .next = next };
}

/// Home date-nav line, text spelling: `/all?date={prev}    /all?date={next}`.
/// Same 4-space join as the scoreboard footer (`/{league}?date=` × 2);
/// the target is `/all` — the date-addressable all-leagues view — while
/// `/` itself renders the live overview. Plain, never ANSI: the scoreboard
/// footer precedent, so piped output stays clean.
fn writeHomeNavLine(w: *std.Io.Writer, allocator: std.mem.Allocator, day: []const u8) !void {
    const nav = try homeNavDates(allocator, day) orelse return;
    defer allocator.free(nav.prev);
    defer allocator.free(nav.next);
    try w.print("/all?date={s}    /all?date={s}\n", .{ nav.prev, nav.next });
}

/// HTML twin of `writeHomeNavLine`: byte-identical visible text, each
/// half its own link. Hrefs escape via `escapeInto` like every other
/// built href, so hostile day text can never break the page.
fn writeHomeNavHtml(w: *std.Io.Writer, allocator: std.mem.Allocator, day: []const u8) !void {
    const nav = try homeNavDates(allocator, day) orelse return;
    defer allocator.free(nav.prev);
    defer allocator.free(nav.next);
    const prev_href = try std.fmt.allocPrint(allocator, "/all?date={s}", .{nav.prev});
    defer allocator.free(prev_href);
    const next_href = try std.fmt.allocPrint(allocator, "/all?date={s}", .{nav.next});
    defer allocator.free(next_href);
    try w.writeAll("<a href=\"");
    try escapeInto(w, prev_href);
    try w.writeAll("\">");
    try escapeInto(w, prev_href);
    try w.writeAll("</a>    <a href=\"");
    try escapeInto(w, next_href);
    try w.writeAll("\">");
    try escapeInto(w, next_href);
    try w.writeAll("</a>\n");
}

/// Per-league today link shared by the static home rows and the live
/// home rows: `/{slug}?date={day}` when a day is in hand, dateless
/// `/{slug}` otherwise. One spelling everywhere, so the shortcut never
/// drifts between the two homes. Returned raw; callers escape it.
fn homeLeagueHref(allocator: std.mem.Allocator, slug: []const u8, day: ?[]const u8) ![]u8 {
    if (day) |d| {
        return try std.fmt.allocPrint(allocator, "/{s}?date={s}", .{ slug, d });
    }
    return try std.fmt.allocPrint(allocator, "/{s}", .{slug});
}

/// Static home: league slugs link to today's board for that league
/// (`/{slug}` defaults to today). The optional `day` spells the today
/// link out as `/{slug}?date={day}`; without it rows stay exactly as
/// before. The date lives in the href only, so the 52-column box stays
/// aligned either way. Nav always carries json/spec/github.
pub fn homeHtml(allocator: std.mem.Allocator) ![]u8 {
    return homeHtmlDay(allocator, null);
}

/// Home page mark: the pixel-S favicon displayed above the table (outside
/// `<pre>`, so visible-text tests never see it). Fixed size, cached with
/// the favicon itself.
pub const home_logo_mark =
    "<a class=\"logo-home\" href=\"/\" aria-label=\"sprts home\">" ++
    "<span class=\"logo-dark\">" ++ logo_dark_svg ++ "</span>" ++
    "<span class=\"logo-light\">" ++ logo_light_svg ++ "</span></a>\n";

/// Skip-to-content link: the first `<main>` child on every HTML page,
/// visually hidden until focused. Its target is the page `<h1>
/// (see `h1_open`), so keyboard and screen-reader users land on the
/// title line past the brand mark.
pub const skip_link = "<a class=\"skip-link\" href=\"#content\">Skip to content</a>";

/// Page-title heading opener: every HTML page wraps its title line in
/// exactly one `<h1 id="content">`. The id serves the skip link; the
/// `h1{margin:0;padding:0;font:inherit}` rule kills UA margins so the
/// row keeps its exact box and `<pre>` visible text never changes.
pub const h1_open = "<h1 id=\"content\">";

pub fn homeHtmlDay(allocator: std.mem.Allocator, day: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try pageHead(w, "sprts");
    try table.writeSeparator(w, 50);
    // Dated static home carries the same nav as the live homes, above the
    // league rows; dateless stays exactly as before (no day, no nav).
    if (day) |d| try writeHomeNavHtml(w, allocator, d);
    // The first league row doubles as the page `<h1>` title (the skip
    // link's `#content` target): tags strip clean, so visible text and
    // layout never change.
    for (leagues.all, 0..) |league, i| {
        const href = try homeLeagueHref(allocator, league.slug, day);
        defer allocator.free(href);
        var cell: std.Io.Writer.Allocating = .init(allocator);
        defer cell.deinit();
        try table.writeCell(&cell.writer, league.slug, 13, null, false);
        try cell.writer.writeByte(' ');
        try table.writeCell(&cell.writer, league.name, 34, null, false);
        const padded = try cell.toOwnedSlice();
        defer allocator.free(padded);
        if (i == 0) try w.writeAll(h1_open);
        try w.writeAll("<a href=\"");
        try escapeInto(w, href);
        try w.writeAll("\">");
        try escapeInto(w, std.mem.trimEnd(u8, padded, " "));
        try w.writeAll("</a>");
        if (i == 0) try w.writeAll("</h1>");
        try w.writeByte('\n');
    }
    try w.writeByte('\n');
    try w.writeAll("Try: curl localhost:8080/mlb\n");
    try w.writeAll("</pre><nav><a href=\"/docs\">docs</a><a href=\"/openapi.json\">spec</a><a href=\"" ++ repo_url ++ "\">github</a>");
    try closePageWithNav(w);
    return out.toOwnedSlice();
}

/// Live HTML home: same sections as `homeLive`, never ANSI, with links.
/// Game lines link to their league page; per-league links spell today
/// out (`/{slug}?date={day}`), sharing the static home spelling. The
/// footer nav mirrors `homeHtml`; the date-nav line up top mirrors the
/// live text home's (`writeHomeNavLine`, same visible text). `dated`
/// skips off-day leagues exactly like the text home (see `homeLive`).
pub fn homeHtmlLive(
    allocator: std.mem.Allocator,
    host: []const u8,
    boards: []const provider.LeagueResult,
    day: []const u8,
    quiet: bool,
    dated: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const heading = try std.fmt.allocPrint(allocator, "sprts  {s}", .{day});
    defer allocator.free(heading);
    try pageHead(w, heading);
    // Date nav opens the page, ahead of the sections: the HTML twin of
    // the live text home's nav line. Emitted directly (not through the
    // section buffer) so the first section row keeps the page `<h1>`.
    try writeHomeNavHtml(w, allocator, day);
    // Sections render aside, then the first row becomes the page `<h1>`
    // title (see `writeH1FirstLine`): tags strip clean, so visible text
    // and layout never change.
    {
        var sec: std.Io.Writer.Allocating = .init(allocator);
        defer sec.deinit();
        try homeSections(allocator, &sec.writer, boards, false, true, day, dated);
        const rendered = try sec.toOwnedSlice();
        defer allocator.free(rendered);
        try writeH1FirstLine(w, rendered);
    }
    if (!quiet) {
        try w.writeAll("Try: curl ");
        try escapeInto(w, host);
        try w.writeAll("/mlb\nDocs: ");
        try escapeInto(w, host);
        try w.writeAll("/docs\nCode: " ++ repo_url ++ "\n");
    }
    try w.writeAll("</pre>");
    if (!quiet) {
        try w.writeAll("<nav><a href=\"/docs\">docs</a><a href=\"/openapi.json\">spec</a><a href=\"" ++ repo_url ++ "\">github</a>");
        try closePageWithNav(w);
    } else {
        try w.writeAll("</main></body></html>");
    }
    return out.toOwnedSlice();
}

/// Shared page opener: doctype through `<main>`, the clickable brand,
/// and the `<pre>` opening as one owned byte run, so the logo stack
/// (`<main>` .. `<pre>`) is identical on every HTML page. Callers emit
/// content immediately after; nothing may interpose whitespace there —
/// a stray `\n` after `<pre>` is preserved by `pre-wrap` and renders
/// as a blank row, shifting that page's logo-to-content gap alone.
pub fn pageHead(w: *std.Io.Writer, title: []const u8) !void {
    return pageHeadLive(w, title, false);
}

/// Page opener with the live-stream marker: when `live` is true the `<pre>`
/// carries `data-live="1"`, which arms the live-update script (see
/// `live_script`); otherwise the opener is byte-identical to `pageHead`, so
/// static pages keep their exact bytes.
pub fn pageHeadLive(w: *std.Io.Writer, title: []const u8, live: bool) !void {
    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<link rel=\"icon\" type=\"image/svg+xml\" href=\"/favicon.svg\">" ++
        "<title>");
    try escapeInto(w, title);
    // Theme script before the stylesheet: the stored/OS theme lands on
    // `data-theme` ahead of first CSS application, so navigating between
    // pages never flashes the default theme (the reported "reset").
    try w.writeAll("</title>" ++ theme_script ++ page_style ++ "</head><body><main>" ++ skip_link ++ home_logo_mark);
    if (live) {
        try w.writeAll("<pre data-live=\"1\">");
    } else {
        try w.writeAll("<pre>");
    }
}

/// True when any game on the board is live (`state == "in"`): the page
/// arms its live-update script and stamps freshness instead of rendering
/// bare static HTML.
pub fn boardIsLive(board: domain.Scoreboard) bool {
    for (board.games) |game| {
        if (std.mem.eql(u8, game.state, "in")) return true;
    }
    return false;
}

/// Freshness copy for a render age in seconds: seconds under a minute,
/// minutes under an hour, hours beyond. Mirrors the browser tick in
/// `live_script` so server and client read the same.
pub fn freshAgeText(allocator: std.mem.Allocator, age_s: u64) ![]u8 {
    if (age_s < 10) return allocator.dupe(u8, "updated just now");
    if (age_s < 60) return std.fmt.allocPrint(allocator, "updated {d}s ago", .{age_s});
    if (age_s < 3600) return std.fmt.allocPrint(allocator, "updated {d}m ago", .{age_s / 60});
    return std.fmt.allocPrint(allocator, "updated {d}h ago", .{age_s / 3600});
}

/// Freshness line for a live HTML page: a `<div class="fresh">` carrying
/// the render epoch in `data-mtime` (the script upgrades the copy live)
/// with the at-render text beside it. No-JS readers still see when the
/// page rendered; text formats never see it (curl stays clean).
pub fn writeFreshDiv(w: *std.Io.Writer, allocator: std.mem.Allocator, mtime_s: i64) !void {
    const copy = try freshAgeText(allocator, 0);
    defer allocator.free(copy);
    try w.print("<div class=\"fresh\" data-mtime=\"{d}\" style=\"opacity:.65\">{s}</div>", .{ mtime_s, copy });
}

/// Live-update script for HTML scoreboard/detail pages: when the page
/// carries a live game (`<pre data-live="1">`) it opens an `EventSource`
/// to the same URL with `?stream=sse`, swaps the `<pre>` body per frame
/// (clear-screen prefix stripped, `data:` lines split), stamps arrival
/// time, and ticks the freshness line every 5s with backoff reconnects.
/// Without the marker (or without `EventSource`) it returns at once, so
/// the static page is untouched: the no-JS fallback is today's page.
pub const live_script =
    \\<script>(function(){
    \\var p=document.querySelector('pre[data-live]');
    \\if(!p||!window.EventSource)return;
    \\var f=document.querySelector('.fresh');
    \\var last=f&&f.dataset.mtime?parseInt(f.dataset.mtime,10):Math.floor(Date.now()/1000);
    \\var wait=1000;
    \\function fmt(s){
    \\if(s<10)return 'updated just now';
    \\if(s<60)return 'updated '+s+'s ago';
    \\if(s<3600)return 'updated '+Math.floor(s/60)+'m ago';
    \\return 'updated '+Math.floor(s/3600)+'h ago';}
    \\function age(){
    \\var s=Math.max(0,Math.floor(Date.now()/1000)-last);
    \\if(f)f.textContent=fmt(s);}
    \\function show(t){
    \\var lines=t.split('\n');
    \\for(var i=0;i<lines.length;i++){if(lines[i].indexOf('data:')===0)lines[i]=lines[i].slice(5);}
    \\t=lines.join('\n').replace(/^\x1b\[2J\x1b\[H/,'');
    \\p.textContent=t;}
    \\function connect(){
    \\var u=new URL(location.href);
    \\u.searchParams.set('stream','sse');
    \\var es=new EventSource(u.toString());
    \\es.onmessage=function(e){show(e.data);last=Math.floor(Date.now()/1000);age();wait=1000;};
    \\es.onerror=function(){es.close();setTimeout(connect,wait);wait=Math.min(wait*2,30000);};}
    \\age();
    \\setInterval(age,5000);
    \\connect();
    \\})();</script>
;

/// Escaped copy of a padded cell: escape `&<>"'` but pass spaces and
/// box-safe bytes through untouched.
fn escapeCellInto(w: *std.Io.Writer, cell: []const u8) !void {
    try escapeInto(w, cell);
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
    \\<style>:root{--bg:#0d0e10;--ink:#f2f3f4;--muted:#8a8f98;--link:#6fd3a0;--live:#ff7b7b;--up:#e8c547;--win:#5fd08a}html[data-theme="light"]{--bg:#f4f1e8;--ink:#1c2420;--muted:#5f6a63;--link:#0b6e4f;--live:#c81e1e;--up:#8a6d00;--win:#0b6e4f}html,body{margin:0;background:var(--bg);color:var(--ink)}main{max-width:640px;margin:auto;padding:20px 14px}pre{margin:0;font:16px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;word-wrap:break-word}a{color:var(--link)}pre a{color:var(--link);font-weight:bold;text-decoration:none}pre a:hover{text-decoration:underline;text-underline-offset:2px}.dim{color:var(--muted)}.live{color:var(--live);font-weight:bold}.upcoming{color:var(--up)}.win{color:var(--win);font-weight:bold}nav{margin-top:14px;font:14px ui-monospace,monospace}nav a{margin-right:16px;padding:6px 2px}@media(max-width:480px){main{padding:12px 8px}pre{font-size:13px}}.logo-dark,.logo-light{display:block;margin:0 0 10px}.logo-light{display:none}html[data-theme="light"] .logo-dark{display:none}html[data-theme="light"] .logo-light{display:block}}a:focus-visible{outline:2px solid var(--link);outline-offset:2px}h1{margin:0;padding:0;font:inherit}.skip-link{position:absolute;left:-9999px;top:0;padding:8px;background:var(--bg);color:var(--link)}.skip-link:focus{position:static}.sr-only{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}@media(prefers-contrast:more){.live{font-weight:900;text-decoration:underline}}</style>
;

/// Site mark: 8x8 pixel S in chunky rects on a dark rounded square —
/// the tinygrad/pi.dev kind of minimal geometric favicon, in our own
/// palette. Served verbatim at `/favicon.svg` and linked from every
/// page head; no script, no external assets, no font dependency.
pub const favicon_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" shape-rendering="crispEdges"><rect width="64" height="64" fill="#0d0e10"/><g transform="translate(2,24) scale(0.3158)" fill="#f2f3f4"><polygon points="0,10 20,10 20,20 0,20" /><polygon points="0,20 30,20 30,30 0,30" /><polygon points="10,30 30,30 30,40 10,40" /><polygon points="40,10 50,10 50,50 40,50" /><polygon points="40,10 70,10 70,20 40,20" /><polygon points="60,20 70,20 70,40 60,40" /><polygon points="40,30 70,30 70,40 40,40" /><polygon points="80,10 90,10 90,40 80,40" /><polygon points="80,10 110,10 110,20 80,20" /><polygon points="130,40 130,20 120,20 120,10 130,10 130,0 140,0 140,10 150,10 150,20 140,20 140,30 150,30 150,40" /><polygon points="160,10 180,10 180,20 160,20" /><polygon points="160,20 190,20 190,30 160,30" /><polygon points="170,30 190,30 190,40 170,40" /></g></svg>
;

/// Pixel wordmark `sprts` (lowercase, chunky rects like the
/// favicon): transparent backgrounds so the page shows through.
/// `logo_dark_svg` carries light ink for dark surfaces,
/// `logo_light_svg` dark ink for light surfaces; the home page
/// shows one or the other via the theme-swap classes below.
pub const logo_dark_svg =
    \\<svg aria-hidden="true" xmlns="http://www.w3.org/2000/svg" viewBox="-10 -10 210 70" width="120" shape-rendering="crispEdges" fill="#f2f3f4"><polygon points="0,10 20,10 20,20 0,20" /><polygon points="0,20 30,20 30,30 0,30" /><polygon points="10,30 30,30 30,40 10,40" /><polygon points="40,10 50,10 50,50 40,50" /><polygon points="40,10 70,10 70,20 40,20" /><polygon points="60,20 70,20 70,40 60,40" /><polygon points="40,30 70,30 70,40 40,40" /><polygon points="80,10 90,10 90,40 80,40" /><polygon points="80,10 110,10 110,20 80,20" /><polygon points="130,40 130,20 120,20 120,10 130,10 130,0 140,0 140,10 150,10 150,20 140,20 140,30 150,30 150,40" /><polygon points="160,10 180,10 180,20 160,20" /><polygon points="160,20 190,20 190,30 160,30" /><polygon points="170,30 190,30 190,40 170,40" /></svg>
;

pub const logo_light_svg =
    \\<svg aria-hidden="true" xmlns="http://www.w3.org/2000/svg" viewBox="-10 -10 210 70" width="120" shape-rendering="crispEdges" fill="#1c2420"><polygon points="0,10 20,10 20,20 0,20" /><polygon points="0,20 30,20 30,30 0,30" /><polygon points="10,30 30,30 30,40 10,40" /><polygon points="40,10 50,10 50,50 40,50" /><polygon points="40,10 70,10 70,20 40,20" /><polygon points="60,20 70,20 70,40 60,40" /><polygon points="40,30 70,30 70,40 40,40" /><polygon points="80,10 90,10 90,40 80,40" /><polygon points="80,10 110,10 110,20 80,20" /><polygon points="130,40 130,20 120,20 120,10 130,10 130,0 140,0 140,10 150,10 150,20 140,20 140,30 150,30 150,40" /><polygon points="160,10 180,10 180,20 160,20" /><polygon points="160,20 190,20 190,30 160,30" /><polygon points="170,30 190,30 190,40 170,40" /></svg>
;
/// Footer theme toggle: a single localStorage key persists the choice;
/// without one the OS preference wins (matchMedia before first paint, so
/// there is no dark flash either way). The footer link flips `data-theme`
/// and re-persists it; with storage blocked (private mode) the toggle
/// still works per page and every load falls back to the OS theme, so
/// pages can never disagree with each other.
const theme_script =
    \\<script>(function(){try{var t=localStorage.getItem("sprts-theme");if(t!=="light"&&t!=="dark"){t=(window.matchMedia&&matchMedia("(prefers-color-scheme: light)").matches)?"light":"dark";}document.documentElement.dataset.theme=t;}catch(e){}})();</script>
    \\<script>function sprtsTheme(){try{var h=document.documentElement;var n=h.dataset.theme==="light"?"dark":"light";h.dataset.theme=n;localStorage.setItem("sprts-theme",n);var b=document.querySelector(".theme-toggle");if(b)b.setAttribute("aria-pressed",n==="dark"?"true":"false");}catch(e){}return false;}document.addEventListener("DOMContentLoaded",function(){try{var b=document.querySelector(".theme-toggle");if(b)b.setAttribute("aria-pressed",document.documentElement.dataset.theme==="dark"?"true":"false");}catch(e){}});</script>
;

/// Theme toggle link appended to every page footer nav. A plain link
/// (not a button) so it needs no button CSS and keeps the plaintext
/// vibe; with JS off it is a harmless `#` jump. It carries
/// `role="button"` with `aria-pressed` tracking the dark theme, so
/// assistive tech announces it as the toggle it is.
pub fn themeNavSuffix() []const u8 {
    return "<a class=\"theme-toggle\" href=\"#\" role=\"button\" aria-pressed=\"false\" onclick=\"return sprtsTheme()\">light/dark</a>";
}

/// Closing tags shared by every HTML page: theme toggle link, then
/// nav, main, body, html. Callers write their own nav links first,
/// then this. Keeps footers identical everywhere.
pub fn closePageWithNav(w: *std.Io.Writer) !void {
    try w.writeAll(themeNavSuffix());
    try w.writeAll("</nav></main></body></html>");
}

pub fn leaguesJson(allocator: std.mem.Allocator) ![]u8 {
    return validatedJson(leagues.LeagueList, allocator, .{ .leagues = &leagues.all });
}

/// Team-list JSON (`GET /api/v1/{league}/teams`), through the same
/// shared validation gate as every other JSON renderer.
pub fn teamsJson(allocator: std.mem.Allocator, list: core.schedule.TeamList) ![]u8 {
    return validatedJson(core.schedule.TeamList, allocator, list);
}

pub fn errorBody(allocator: std.mem.Allocator, message: []const u8, format: router.Format) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    switch (format) {
        .text => try out.writer.print("sprts: {s}\n", .{message}),
        .html => {
            try pageHead(&out.writer, "sprts error");
            try out.writer.writeAll(h1_open ++ "sprts: ");
            try escapeInto(&out.writer, message);
            try out.writer.writeAll("</h1></pre><nav><a href=\"/\">leagues</a>");
            try closePageWithNav(&out.writer);
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

test "text renderer draws a document and no HTML" {
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
    // Pipe-less document: heading, one separator, blank-separated game,
    // date footer — no box-drawing bytes anywhere.
    for ([_][]const u8{ "┌", "├", "└", "│", "─" }) |rule| {
        if (std.mem.eql(u8, rule, "─")) continue; // the separator lives here
        try std.testing.expect(std.mem.indexOf(u8, output, rule) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, output, "─") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "AWY") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "   5 ✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<html") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(output);
    // Long names truncate inside their column: every content line fits.
    const wide_board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Atlético Madrid Club de Fútbol with extra tail", .abbreviation = "ATM", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const wide = try text(std.testing.allocator, wide_board, false, null, null);
    defer std.testing.allocator.free(wide);
    try expectNoBrokenLines(wide, 52);
    try std.testing.expect(std.mem.indexOf(u8, wide, "…") != null);
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
                .slug = "awy-hme",
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
    // Game and team links: status cell links the human game address
    // (with the numeric anchor id), team abbrevs link their team pages.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/2026-09-06/awy-hme\" id=\"game-1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/AWY\">AWY</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/HME\">HME</a>") != null);
    // Hostile status text stays escaped even inside a link (padding
    // follows the text inside the anchor, so only check the escape).
    try std.testing.expect(std.mem.indexOf(u8, page, "<OT>") == null);
    // Visible text still matches the unlinked table byte for byte.
    try expectVisiblePreText(page, board, null, null);
    // Every page carries the clickable brand: logo links back home with
    // an accessible name; theme SVGs hide from assistive tech.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a class=\"logo-home\" href=\"/\" aria-label=\"sprts home\">") != null);

    const homepage = try homeHtml(std.testing.allocator);
    defer std.testing.allocator.free(homepage);
    // Pixel mark above the table, outside the plaintext block: both
    // theme variants ride along, CSS shows exactly one.
    try std.testing.expect(std.mem.indexOf(u8, homepage, home_logo_mark) != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "logo-dark") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "logo-light") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "<a href=\"/mlb\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "<a href=\"/docs\">docs</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "<a href=\"/openapi.json\">spec</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "<a href=\"" ++ repo_url ++ "\">github</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "\x1b[") == null);

    const dated = try homeHtmlDay(std.testing.allocator, "2026-09-06");
    defer std.testing.allocator.free(dated);
    try std.testing.expect(std.mem.indexOf(u8, dated, "<a href=\"/mlb?date=2026-09-06\">") != null);

    const err = try errorBody(std.testing.allocator, "a<b", .html);
    defer std.testing.allocator.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "a&lt;b") != null);
}

/// `<pre>` body of an HTML page, tolerating the live marker: live pages
/// open with `<pre data-live="1">`, static pages with bare `<pre>`.
fn preBody(page: []const u8) []const u8 {
    const tag_open = std.mem.indexOf(u8, page, "<pre").?;
    const content = std.mem.indexOfScalarPos(u8, page, tag_open, '>').? + 1;
    const close = std.mem.indexOf(u8, page, "</pre>").?;
    return page[content..close];
}

test "live scoreboard pages arm the updater and stamp freshness" {
    const live_board: domain.Scoreboard = .{
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
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "3", .winner = false },
                },
            },
        },
    };
    try std.testing.expect(boardIsLive(live_board));
    const page = try scoreHtmlWithZoneArtMtime(std.testing.allocator, live_board, null, null, .et, true, 1757328000);
    defer std.testing.allocator.free(page);
    // Marker arms the script; the bare opener is gone.
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre data-live=\"1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") == null);
    // Freshness line carries the render epoch for the script; the no-JS
    // copy reads fresh at render.
    try std.testing.expect(std.mem.indexOf(u8, page, "<div class=\"fresh\" data-mtime=\"1757328000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "updated just now") != null);
    // Updater script: same-URL EventSource with ?stream=sse, pre swap,
    // 5s freshness tick, backoff reconnect, inert without the marker.
    try std.testing.expect(std.mem.indexOf(u8, page, "EventSource") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "searchParams.set('stream','sse')") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "setInterval(age,5000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "wait=Math.min(wait*2,30000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, live_script, "if(!p||!window.EventSource)return;") != null);
    // Script stays small: the whole tag under 30 lines.
    var script_lines: usize = 1;
    for (live_script) |byte| if (byte == '\n') {
        script_lines += 1;
    };
    try std.testing.expect(script_lines < 30);
    // Additions carry no escapes: the ANSI-free page contract holds.
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    // Visible pre text still matches the text renderer byte for byte.
    try expectVisiblePreText(page, live_board, null, null);
}

test "final scoreboard pages stay static bytes" {
    // JS-free stability: with no live game the page carries zero live
    // bytes — bare opener, no marker, no fresh div, no updater script.
    const final_board: domain.Scoreboard = .{
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
    try std.testing.expect(!boardIsLive(final_board));
    const page = try scoreHtml(std.testing.allocator, final_board, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-live") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-mtime") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"fresh\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "EventSource") == null);
    try expectVisiblePreText(page, final_board, null, null);
}

test "freshness copy graduates seconds to minutes to hours" {
    const cases = [_]struct { age: u64, want: []const u8 }{
        .{ .age = 0, .want = "updated just now" },
        .{ .age = 9, .want = "updated just now" },
        .{ .age = 12, .want = "updated 12s ago" },
        .{ .age = 59, .want = "updated 59s ago" },
        .{ .age = 60, .want = "updated 1m ago" },
        .{ .age = 150, .want = "updated 2m ago" },
        .{ .age = 3599, .want = "updated 59m ago" },
        .{ .age = 3600, .want = "updated 1h ago" },
        .{ .age = 7260, .want = "updated 2h ago" },
    };
    for (cases) |case| {
        const copy = try freshAgeText(std.testing.allocator, case.age);
        defer std.testing.allocator.free(copy);
        try std.testing.expectEqualStrings(case.want, copy);
    }
}

/// Renders `text` escaped (no tags) and expects it to equal the visible
/// `<pre>` text of `page` with tags stripped and entities decoded: the
/// linkifier adds invisible tags only, never layout.
fn expectVisiblePreText(page: []const u8, board: domain.Scoreboard, width: ?u16, height: ?u16) !void {
    const pre = preBody(page);
    var visible: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer visible.deinit();
    var i: usize = 0;
    while (i < pre.len) {
        if (pre[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, pre, i, '>') orelse return error.TestUnexpectedResult;
            i = end + 1;
            continue;
        }
        if (pre[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, pre, i, ';') orelse return error.TestUnexpectedResult;
            const entity = pre[i .. semi + 1];
            if (std.mem.eql(u8, entity, "&amp;")) {
                try visible.writer.writeByte('&');
            } else if (std.mem.eql(u8, entity, "&lt;")) {
                try visible.writer.writeByte('<');
            } else if (std.mem.eql(u8, entity, "&gt;")) {
                try visible.writer.writeByte('>');
            } else if (std.mem.eql(u8, entity, "&quot;")) {
                try visible.writer.writeByte('"');
            } else if (std.mem.eql(u8, entity, "&#39;")) {
                try visible.writer.writeByte('\'');
            } else return error.TestUnexpectedResult;
            i = semi + 1;
            continue;
        }
        try visible.writer.writeByte(pre[i]);
        i += 1;
    }
    const visible_slice = try visible.toOwnedSlice();
    defer std.testing.allocator.free(visible_slice);
    const want = try text(std.testing.allocator, board, false, width, height);
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, visible_slice);
}

test "scoreboard links read by color, padding outside anchors" {
    // Links carry no static underline (hover only) — the non-color cue
    // is bold (`pre a` keeps color + hover-underline); cell padding still
    // rides outside anchors so a hover underline stops at the text:
    // no anchor may close on a blank (padded-inside form `  </a>`).
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
    const page = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(page);
    var lines = std.mem.splitScalar(u8, page, '\n');
    var anchors: usize = 0;
    while (lines.next()) |line| {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, line, cursor, "</a>")) |end| {
            anchors += 1;
            try std.testing.expect(end > 0);
            try std.testing.expect(line[end - 1] != ' ');
            cursor = end + 1;
        }
    }
    try std.testing.expect(anchors > 0);
    try expectVisiblePreText(page, board, null, null);
}

test "web accessibility: names, focus, art, targets, live, headings, links" {
    // Fixture: live duel with color marks (PHI ships a color sidecar),
    // so art rows, live state, and summaries all render at once.
    try std.testing.expect(core.art.teamArtColor("mlb", "PHI", .xs) != null);
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "9",
                .name = "PHI at NYM",
                .starts_at = "2026-09-06T17:00Z",
                .state = "in",
                .status = "Top 7th",
                .participants = &.{
                    .{ .id = "1", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = false },
                    .{ .id = "2", .name = "New York Mets", .abbreviation = "NYM", .score = "3", .winner = false },
                },
            },
        },
    };
    const page = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(page);

    // 1. Logo link has an accessible name; theme SVGs hide from AT.
    try std.testing.expect(std.mem.indexOf(u8, page, "aria-label=\"sprts home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, logo_dark_svg, "aria-hidden=\"true\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, logo_light_svg, "aria-hidden=\"true\"") != null);

    // 2. Keyboard focus is visible.
    try std.testing.expect(std.mem.indexOf(u8, page_style, "a:focus-visible{outline:2px solid var(--link);outline-offset:2px}") != null);

    // 3. Theme toggle announces as a button with pressed state.
    try std.testing.expect(std.mem.indexOf(u8, page, "role=\"button\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "aria-pressed=\"") != null);

    // 4. Braille art rows hide from AT; one sr-only summary per game
    // carries the game id and status outside `<pre>`.
    var art_rows: usize = 0;
    var page_lines = std.mem.splitScalar(u8, page, '\n');
    while (page_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "rgb(") != null) {
            art_rows += 1;
            try std.testing.expect(std.mem.indexOf(u8, line, "aria-hidden=\"true\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, line, "<a href") == null);
        }
    }
    try std.testing.expect(art_rows > 0);
    try std.testing.expect(std.mem.indexOf(u8, page_style, ".sr-only{") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<div class=\"sr-only\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Game 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Top 7th") != null);

    // 5. Nav links get touch-sized padding (never min-height chrome).
    try std.testing.expect(std.mem.indexOf(u8, page_style, "nav a{margin-right:16px;padding:") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "min-height:44px") == null);

    // 6. Live state never rides on color alone: bold plus a
    // forced-contrast strengthening rule.
    try std.testing.expect(std.mem.indexOf(u8, page_style, ".live{color:var(--live);font-weight:bold}") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "prefers-contrast") != null);
    const mlb_live = [_]provider.LeagueResult{.{ .league = core.leagues.find("mlb").?, .board = board }};
    const live_home_page = try homeHtmlLive(std.testing.allocator, "example.test", &mlb_live, "2026-09-06", false, false);
    defer std.testing.allocator.free(live_home_page);
    try std.testing.expect(std.mem.indexOf(u8, live_home_page, "<span class=\"live\">") != null);

    // 7. Exactly one `<h1>` title plus a skip link as the first `<main>`
    // child; visible `<pre>` text never changes.
    var h1_hits: usize = 0;
    var rest: []const u8 = page;
    while (std.mem.indexOf(u8, rest, "<h1")) |at| {
        h1_hits += 1;
        rest = rest[at + "<h1".len ..];
    }
    try std.testing.expectEqual(@as(usize, 1), h1_hits);
    try std.testing.expect(std.mem.indexOf(u8, page, "<h1 id=\"content\">MLB  2026-09-06 ET</h1>") != null);
    const main_at = std.mem.indexOf(u8, page, "<main>").?;
    try std.testing.expect(std.mem.startsWith(u8, page[main_at + "<main>".len ..], skip_link));
    try expectVisiblePreText(page, board, null, null);

    // 8. Links keep color + hover-underline with bold as the non-color
    // cue, never a resting underline (owner style decision).
    try std.testing.expect(std.mem.indexOf(u8, page_style, "pre a{color:var(--link);font-weight:bold;text-decoration:none}") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "pre a:hover{text-decoration:underline;") != null);

    // Every page type carries the same heading + skip landmarks.
    const static_home = try homeHtml(std.testing.allocator);
    defer std.testing.allocator.free(static_home);
    try std.testing.expect(std.mem.indexOf(u8, static_home, "<h1 id=\"content\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, static_home, skip_link) != null);
    var idle: [core.leagues.all.len]provider.LeagueResult = undefined;
    for (&core.leagues.all, 0..) |*league, i| idle[i] = .{ .league = league };
    const live_home = try homeHtmlLive(std.testing.allocator, "example.test", &idle, "2026-09-06", false, false);
    defer std.testing.allocator.free(live_home);
    try std.testing.expect(std.mem.indexOf(u8, live_home, "<h1 id=\"content\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, live_home, skip_link) != null);
    const err = try errorBody(std.testing.allocator, "nope", .html);
    defer std.testing.allocator.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "<h1 id=\"content\">sprts: nope</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, err, skip_link) != null);
    _ = try std.unicode.Utf8View.init(page);
}

test "scoreHtml art rows stay pos-indexed and unlinked" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "9",
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
    const page = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(page);
    // Both participants link on their own row, in positional order: the
    // first team link after the game anchor must be PHI's, not NYM's.
    const game_at = std.mem.indexOf(u8, page, "id=\"game-9\"").?;
    const phi_at = std.mem.indexOf(u8, page, "<a href=\"/mlb/PHI\">PHI</a>").?;
    const nym_at = std.mem.indexOf(u8, page, "<a href=\"/mlb/NYM\">NYM</a>").?;
    try std.testing.expect(game_at < phi_at);
    try std.testing.expect(phi_at < nym_at);
    // Mark rows carry art, never links: the art's first line is escaped
    // verbatim. With PHI vs NYM marks present the marks may sit side by
    // side on one line; that line must still be link-free.
    const mark = core.art.teamArt("mlb", "PHI", .xs).?;
    const first_line = mark[0..std.mem.indexOfScalar(u8, mark, '\n').?];
    if (core.art.teamArt("mlb", "NYM", .xs)) |_| {
        if (core.art.teamArtColor("mlb", "PHI", .xs)) |_| {
            // Colored marks: SGR becomes rgb spans, never raw escapes,
            // and art rows stay link-free (spans only, no anchors).
            try std.testing.expect(std.mem.indexOf(u8, page, "rgb(") != null);
            var lines = std.mem.splitScalar(u8, page, '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, "rgb(") != null) {
                    try std.testing.expect(std.mem.indexOf(u8, line, "<a href") == null);
                }
            }
        } else {
            // Mono marks: art row(s) must escape the mark without anchors.
            try std.testing.expect(std.mem.indexOf(u8, page, first_line) != null);
            var lines = std.mem.splitScalar(u8, page, '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, first_line) != null) {
                    try std.testing.expect(std.mem.indexOf(u8, line, "<a href") == null);
                }
            }
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try expectVisiblePreText(page, board, null, null);
    _ = try std.unicode.Utf8View.init(page);
}

test "scoreHtml skips the color twin when no team has color art" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{.{
            .id = "1",
            .name = "Away at Home",
            .starts_at = "2026-09-06T17:00Z",
            .state = "post",
            .status = "Final",
            .participants = &.{
                .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
            },
        }},
    };
    // Gate fires: neither fixture abbr ships a color sidecar.
    try std.testing.expect(!boardHasColorArt(board, board.games.len));
    // The twin carries nothing the linkifier would read: stripping SGR
    // from the color render reproduces the mono body, so reusing the
    // mono body as the twin is byte-identical for this board.
    const mono = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(mono);
    const colored = try text(std.testing.allocator, board, true, null, null);
    defer std.testing.allocator.free(colored);
    var stripped: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stripped.deinit();
    try stripAnsi(&stripped.writer, colored);
    const stripped_slice = try stripped.toOwnedSlice();
    defer std.testing.allocator.free(stripped_slice);
    try std.testing.expectEqualStrings(mono, stripped_slice);
    // Fast-path page: no rgb spans, no escapes, same visible text. The
    // fixture carries no stamped slug, so the status row keeps the legacy
    // numeric href (fallback pin).
    const page = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "rgb(") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/1\" id=\"game-1\">") != null);
    try expectVisiblePreText(page, board, null, null);
    _ = try std.unicode.Utf8View.init(page);
}

test "scoreHtml narrow width keeps links and layout" {
    const board = testBoard();
    const page = try scoreHtml(std.testing.allocator, board, 40, 2);
    defer std.testing.allocator.free(page);
    // Width 40 clamps to the classic 52-wide box; height 2 shows two
    // games plus the `+1 more` trailer with no link.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/2026-09-06/awy-hme\" id=\"game-1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/2026-09-06/sec-thi\" id=\"game-2\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"game-3\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "+1 more") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try expectVisiblePreText(page, board, 40, 2);
}

test "empty abbreviations emit no team link, text and HTML" {
    // Name-only athletes (tennis): no abbreviation, so no team page to
    // point at. The text pointer keeps the game link alone; the HTML
    // linkifier keeps the game anchor alone. Never a bare `/atp/` href.
    const board: domain.Scoreboard = .{
        .league = "atp",
        .league_name = "ATP",
        .date = "2026-09-10",
        .source = "test",
        .games = &.{.{
            .id = "182772",
            .name = "US Open",
            .starts_at = "2026-09-10T00:00Z",
            .state = "post",
            .status = "Final",
            .participants = &.{
                .{ .id = "3310", .name = "Botic Van De Zandschulp", .abbreviation = "", .score = "0", .winner = false },
                .{ .id = "2375", .name = "Alexander Zverev", .abbreviation = "", .score = "3", .winner = true },
            },
        }},
    };
    const body = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "game: /atp/182772") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "team:") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "team: /atp/") == null);
    const page = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/atp/182772\" id=\"game-182772\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"/atp/\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try expectVisiblePreText(page, board, null, null);
    _ = try std.unicode.Utf8View.init(page);
}

test "page style is plaintext: no buttons, pre always scrolls" {
    try std.testing.expect(std.mem.indexOf(u8, page_style, "width=device-width") == null); // head, not style
    // Plaintext nav: bare inline links, never button chrome.
    try std.testing.expect(std.mem.indexOf(u8, page_style, "min-height:44px") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "border:1px") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "border-radius") == null);
    // The page must never scroll sideways: output is borderless, so pre
    // wraps and narrow screens get a smaller face instead of a scrollbar
    // (the frame era scrolled with pre + overflow-x).
    try std.testing.expect(std.mem.indexOf(u8, page_style, "white-space:pre-wrap;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "overflow-x:auto") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "max-width:480px") != null);
    // Theme rides on CSS vars; the toggle flips data-theme + localStorage.
    try std.testing.expect(std.mem.indexOf(u8, page_style, "--bg") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "data-theme") != null);
}

test "footer nav ends with the theme toggle on every page" {
    const board: domain.Scoreboard = .{ .league = "mlb", .league_name = "MLB", .date = "2026-09-06", .source = "test", .games = &.{} };
    const scoreboard = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(scoreboard);
    try std.testing.expect(std.mem.indexOf(u8, scoreboard, "light/dark") != null);
    try std.testing.expect(std.mem.indexOf(u8, scoreboard, "sprtsTheme()") != null);
    try std.testing.expect(std.mem.indexOf(u8, scoreboard, "localStorage") != null);
    // First visits without a stored choice follow the OS theme.
    try std.testing.expect(std.mem.indexOf(u8, scoreboard, "prefers-color-scheme") != null);
    // Every page head links the favicon and serves valid SVG for it.
    try std.testing.expect(std.mem.indexOf(u8, scoreboard, "rel=\"icon\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, favicon_svg, "<svg "));
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "</svg>") != null);
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "<script") == null);
    // Pixel mark, not a font glyph: chunky polygons with crisp edges.
    // The favicon carries the wordmark's notched `s` on a sharp dark tile.
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "shape-rendering=\"crispEdges\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "<polygon") != null);
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "<rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "<text") == null);
    // Wordmark variants: dark surfaces get light ink and vice versa, no
    // fonts anywhere, theme swap rides the data-theme CSS classes.
    try std.testing.expect(std.mem.indexOf(u8, logo_dark_svg, "#f2f3f4") != null);
    try std.testing.expect(std.mem.indexOf(u8, logo_light_svg, "#1c2420") != null);
    try std.testing.expect(std.mem.indexOf(u8, logo_dark_svg, "viewBox=\"-10 -10 210 70\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, logo_light_svg, "font") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "logo-light") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "logo-dark") != null);
    const err = try errorBody(std.testing.allocator, "nope", .html);
    defer std.testing.allocator.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "light/dark") != null);
}

test "theme head block is identical on every page type" {
    // One shared `pageHead` owns the theme script, so navigating between
    // pages can never disagree about the stored theme. Every HTML page
    // must carry the exact same block verbatim.
    const board: domain.Scoreboard = .{ .league = "mlb", .league_name = "MLB", .date = "2026-09-06", .source = "test", .games = &.{} };
    const scoreboard = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(scoreboard);
    const static_home = try homeHtml(std.testing.allocator);
    defer std.testing.allocator.free(static_home);
    var idle: [core.leagues.all.len]provider.LeagueResult = undefined;
    for (&core.leagues.all, 0..) |*league, i| idle[i] = .{ .league = league };
    const live_home = try homeHtmlLive(std.testing.allocator, "example.test", &idle, "2026-09-06", false, false);
    defer std.testing.allocator.free(live_home);
    const err = try errorBody(std.testing.allocator, "nope", .html);
    defer std.testing.allocator.free(err);
    for ([_][]const u8{ scoreboard, static_home, live_home, err }) |page| {
        try std.testing.expect(std.mem.indexOf(u8, page, theme_script) != null);
    }
    // Same block, same position contract: head opens, scripts run, then
    // the stylesheet, all before `</head>`.
    for ([_][]const u8{ scoreboard, static_home }) |page| {
        const script_at = std.mem.indexOf(u8, page, theme_script).?;
        const style_at = std.mem.indexOf(u8, page, page_style).?;
        const head_end = std.mem.indexOf(u8, page, "</head>").?;
        try std.testing.expect(script_at < style_at);
        try std.testing.expect(style_at < head_end);
    }
    // Quiet live home keeps the head script (persistence) even though it
    // drops the footer nav chrome.
    const quiet = try homeHtmlLive(std.testing.allocator, "example.test", &idle, "2026-09-06", true, false);
    defer std.testing.allocator.free(quiet);
    try std.testing.expect(std.mem.indexOf(u8, quiet, theme_script) != null);
}

test "theme persistence contract: one key, data-theme both ways, OS fallback" {
    // The init script reads exactly the key the toggle writes; anything
    // else resets the theme on every navigation.
    try std.testing.expect(std.mem.indexOf(u8, theme_script, "localStorage.getItem(\"sprts-theme\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, theme_script, "localStorage.setItem(\"sprts-theme\",n)") != null);
    // `sprts-theme` appears exactly twice: one read, one write. A third
    // occurrence means a divergent key somewhere.
    var key_hits: usize = 0;
    var rest: []const u8 = theme_script;
    while (std.mem.indexOf(u8, rest, "sprts-theme")) |at| {
        key_hits += 1;
        rest = rest[at + "sprts-theme".len ..];
    }
    try std.testing.expectEqual(@as(usize, 2), key_hits);
    // Both directions ride `data-theme` (never a class swap), and first
    // visits fall back to the OS preference.
    try std.testing.expect(std.mem.indexOf(u8, theme_script, "document.documentElement.dataset.theme=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, theme_script, "h.dataset.theme") != null);
    try std.testing.expect(std.mem.indexOf(u8, theme_script, "matchMedia") != null);
    try std.testing.expect(std.mem.indexOf(u8, theme_script, "prefers-color-scheme") != null);
    // The toggle footer the script's writer needs is on every
    // non-quiet page.
    const board: domain.Scoreboard = .{ .league = "mlb", .league_name = "MLB", .date = "2026-09-06", .source = "test", .games = &.{} };
    const scoreboard = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(scoreboard);
    try std.testing.expect(std.mem.indexOf(u8, scoreboard, themeNavSuffix()) != null);
    const static_home = try homeHtml(std.testing.allocator);
    defer std.testing.allocator.free(static_home);
    try std.testing.expect(std.mem.indexOf(u8, static_home, themeNavSuffix()) != null);
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
        // The block wordmark rides above the heading, outside the table:
        // full blocks would otherwise count as (ragged) table rows.
        if (std.mem.indexOf(u8, line, "█") != null) continue;
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

/// Mid rules (`├`) in a rendered home page. The home frame is quiet by
/// design: exactly 2 (LIVE block close, frame close). A per-game or
/// per-league rule would push this past 2 and fail the caller.
fn countRules(output: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "├")) n += 1;
    }
    return n;
}

/// Every rendered line fits its frame: no row may exceed the frame
/// width, or it wraps on narrow screens and the box "breaks". Frame
/// lines start with a 3-byte box glyph; hint/nav lines outside the
/// table are skipped. Callers pass the expected frame width.
fn expectNoBrokenLines(output: []const u8, frame_width: usize) !void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != 0xE2) continue;
        // Banner rows carry full blocks, not frame cells; the wordmark
        // test below owns their width, so they skip the frame check.
        if (std.mem.indexOf(u8, line, "█") != null) continue;
        try std.testing.expect(displayWidth(line) <= frame_width);
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
    var results: [core.leagues.all.len]provider.LeagueResult = undefined;
    for (&core.leagues.all, 0..) |*league, i| results[i] = .{ .league = league };
    const output = try homeLive(std.testing.allocator, false, "example.test", &results, "2026-09-06", false, false);
    defer std.testing.allocator.free(output);
    try expectAlignedTable(output);
    try expectNoBrokenLines(output, 52);
    try std.testing.expect(countRules(output) == 0);
}

test "home groups live games, then today, then idle leagues" {
    const live_board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .slug = "awy-hme",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "in",
                .status = "Top 7th",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "0", .winner = false, .home_away = "away" },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "3", .winner = true, .home_away = "home" },
                },
            },
        },
    };
    const today_board: domain.Scoreboard = .{
        .league = "nba",
        .league_name = "NBA",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "2",
                .name = "Third at Fourth",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "7:05 PM ET",
                .participants = &.{
                    .{ .id = "c", .name = "Third", .abbreviation = "TRD", .score = "", .winner = false },
                    .{ .id = "d", .name = "Fourth", .abbreviation = "FRT", .score = "", .winner = false },
                },
            },
        },
    };
    const results = [_]provider.LeagueResult{
        .{ .league = core.leagues.find("mlb").?, .board = live_board },
        .{ .league = core.leagues.find("nba").?, .board = today_board },
        .{ .league = core.leagues.find("nfl").? },
    };
    const output = try homeLive(std.testing.allocator, false, "example.test", &results, "2026-09-06", false, false);
    defer std.testing.allocator.free(output);
    const live_at = std.mem.indexOf(u8, output, "LIVE NOW").?;
    const nba_at = std.mem.indexOf(u8, output, "NBA").?;
    const leagues_at = std.mem.indexOf(u8, output, "ALL LEAGUES").?;
    try std.testing.expect(live_at < nba_at);
    try std.testing.expect(nba_at < leagues_at);
    // Empty-abbr duels name their sides: single-named bouts show the
    // known fighter, fully nameless bouts fall back to the game name.
    const ufc_board: domain.Scoreboard = .{
        .league = "ufc",
        .league_name = "UFC",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "9",
                .name = "Contender Series",
                .starts_at = "2026-09-06T23:00Z",
                .state = "pre",
                .status = "9/8 - 7:00 PM EDT",
                .participants = &.{
                    .{ .id = "x", .name = "Colton Loud", .abbreviation = "", .score = "", .winner = false },
                    .{ .id = "y", .name = "Christian Natividad", .abbreviation = "", .score = "", .winner = false },
                },
            },
        },
    };
    const ufc_line = try view.homeGameLine(std.testing.allocator, core.leagues.find("ufc").?, ufc_board.games[0], 3, 3);
    defer std.testing.allocator.free(ufc_line.?);
    // Athlete sides join with " v "; records stay out of the line.
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, " v ") != null);
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, " v ") != null);
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, "Colton Loud") != null);
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, "Christian Natividad") != null);
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, "9/8") != null);
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, "2026") == null);
    // One known abbreviation: abbr side duels the named side.
    const half_board: domain.Scoreboard = .{
        .league = "ufc",
        .league_name = "UFC",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "8",
                .name = "Contender Series",
                .starts_at = "2026-09-06T23:00Z",
                .state = "pre",
                .status = "9/8 - 7:00 PM EDT",
                .participants = &.{
                    .{ .id = "x", .name = "Colton Loud", .abbreviation = "LOUD", .score = "", .winner = false },
                    .{ .id = "y", .name = "Christian Natividad", .abbreviation = "", .score = "", .winner = false },
                },
            },
        },
    };
    const half_line = try view.homeGameLine(std.testing.allocator, core.leagues.find("ufc").?, half_board.games[0], 3, 4);
    defer std.testing.allocator.free(half_line.?);
    try std.testing.expect(std.mem.indexOf(u8, half_line.?, "LOUD") != null);
    try std.testing.expect(std.mem.indexOf(u8, half_line.?, "Christian Natividad") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mlb AWY   0 @ HME   3 ✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nba TRD     @ FRT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nfl") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "example.test/mlb") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "example.test/docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, repo_url) != null);
    try expectAlignedTable(output);
    // Whitespace: a blank line separates each section, and zero
    // mid rules exist — sections breathe through air, never grid.
    // The frame opens once (top rule) and never closes with borders,
    // so dense days stay quiet instead of rendering a rule per section.
    try std.testing.expect(countRules(output) == 0);
    // No line exceeds the 52-column frame, so nothing wraps and the box
    // cannot "break" on narrow screens.
    try expectNoBrokenLines(output, 52);

    const page = try homeHtmlLive(std.testing.allocator, "example.test", &results, "2026-09-06", false, false);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/2026-09-06/awy-hme\">") != null);
    // Granular team spans inside the game link: each side links its team.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/AWY\">AWY</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/HME\">HME</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nba?date=2026-09-06\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nfl?date=2026-09-06\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "github") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
}

test "sanitizeHost falls back on hostile input" {
    try std.testing.expectEqualStrings("localhost:8080", sanitizeHost(null));
    try std.testing.expectEqualStrings("sprts.horv.co", sanitizeHost("sprts.horv.co"));
    try std.testing.expectEqualStrings("localhost:8080", sanitizeHost("evil\"><script>"));
    try std.testing.expectEqualStrings("localhost:8080", sanitizeHost(""));
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

test "text renderer colors marks and strips them with color=false" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "PHI at NYY",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "1", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = true },
                    .{ .id = "2", .name = "New York Yankees", .abbreviation = "NYY", .score = "3", .winner = false },
                },
            },
        },
    };
    const colored = try text(std.testing.allocator, board, true, null, null);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[38;5;") != null);
    const plain = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    // No line exceeds the page: ragged rows still fit their columns.
    try expectNoBrokenLines(plain, 52);
    // Stripping SGR from the colored render reproduces the mono render.
    var stripped: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stripped.deinit();
    try stripAnsi(&stripped.writer, colored);
    const stripped_slice = try stripped.toOwnedSlice();
    defer std.testing.allocator.free(stripped_slice);
    try std.testing.expectEqualStrings(plain, stripped_slice);
}

fn stripAnsi(w: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            var j = i + 2;
            while (j < s.len and s[j] != 'm') : (j += 1) {}
            i = if (j < s.len) j + 1 else s.len;
            continue;
        }
        try w.writeByte(s[i]);
        i += 1;
    }
}

fn expectAlignedTableColored(output: []const u8) !void {
    // Same frame-alignment check as expectAlignedTable, but ANSI-aware:
    // strip SGR runs first so colored marks measure by visible cells.
    var stripped: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stripped.deinit();
    try stripAnsi(&stripped.writer, output);
    const slice = try stripped.toOwnedSlice();
    defer std.testing.allocator.free(slice);
    try expectAlignedTable(slice);
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
                .slug = "awy-hme",
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
                .slug = "sec-thi",
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
                .slug = "fou-fif",
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
    // Heading first, then an 80-wide separator rule.
    var lines = std.mem.splitScalar(u8, wide, '\n');
    try std.testing.expectEqualStrings("MLB  2026-09-06 ET", lines.next().?);
    const rule = lines.next().?;
    try std.testing.expectEqual(displayWidth(rule), 80);
    _ = try std.unicode.Utf8View.init(wide);

    // Narrow requests never shrink below the classic 52-wide page.
    const narrow = try text(std.testing.allocator, board, false, 40, null);
    defer std.testing.allocator.free(narrow);
    var narrow_lines = std.mem.splitScalar(u8, narrow, '\n');
    try std.testing.expectEqualStrings("MLB  2026-09-06 ET", narrow_lines.next().?);
    try std.testing.expectEqual(displayWidth(narrow_lines.next().?), 52);
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

test "scoreboard text heading names the zone" {
    const board = testBoard();
    const et = try textWithZone(std.testing.allocator, board, false, null, null, .et);
    defer std.testing.allocator.free(et);
    try std.testing.expect(std.mem.indexOf(u8, et, "MLB  2026-09-06 ET") != null);
    try expectNoBrokenLines(et, 52);

    const utc = try textWithZone(std.testing.allocator, board, false, null, null, .utc);
    defer std.testing.allocator.free(utc);
    try std.testing.expect(std.mem.indexOf(u8, utc, "MLB  2026-09-06 UTC") != null);

    const fixed = try textWithZone(std.testing.allocator, board, false, null, null, .{ .fixed = -300 });
    defer std.testing.allocator.free(fixed);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "MLB  2026-09-06 UTC-5") != null);

    // ET-default wrapper keeps the label so unwired callers never go bare.
    const plain = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "MLB  2026-09-06 ET") != null);
}

test "scoreHtml title and heading name the zone" {
    const board = testBoard();
    const page = try scoreHtmlWithZone(std.testing.allocator, board, null, null, .et);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "MLB scores 2026-09-06 ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "MLB  2026-09-06 ET") != null);

    const utc_page = try scoreHtmlWithZone(std.testing.allocator, board, null, null, .utc);
    defer std.testing.allocator.free(utc_page);
    try std.testing.expect(std.mem.indexOf(u8, utc_page, "MLB scores 2026-09-06 UTC") != null);
}

test "home text heading and one-lines name the zone" {
    var results: [core.leagues.all.len]provider.LeagueResult = undefined;
    for (&core.leagues.all, 0..) |*league, i| results[i] = .{ .league = league };
    const live = try homeLiveWithZone(std.testing.allocator, false, "example.test", &results, "2026-09-06", false, .et, false);
    defer std.testing.allocator.free(live);
    try std.testing.expect(std.mem.indexOf(u8, live, "sprts  2026-09-06 ET") != null);

    const utc_live = try homeLiveWithZone(std.testing.allocator, false, "example.test", &results, "2026-09-07", false, .utc, false);
    defer std.testing.allocator.free(utc_live);
    try std.testing.expect(std.mem.indexOf(u8, utc_live, "sprts  2026-09-07 UTC") != null);

    const board = testBoard();
    const mlb = core.leagues.find("mlb").?;
    const one_sections = [_]provider.LeagueResult{.{ .league = mlb, .board = board }};
    const lines = try homeOneLineWithZone(std.testing.allocator, &one_sections, false, .et);
    defer std.testing.allocator.free(lines);
    try std.testing.expect(std.mem.indexOf(u8, lines, "mlb 09-06 ET") != null);
    const utc_lines = try homeOneLineWithZone(std.testing.allocator, &one_sections, false, .utc);
    defer std.testing.allocator.free(utc_lines);
    try std.testing.expect(std.mem.indexOf(u8, utc_lines, "mlb 09-06 UTC") != null);
}

test "live home opens with prev/next date nav under the heading" {
    var results: [core.leagues.all.len]provider.LeagueResult = undefined;
    for (&core.leagues.all, 0..) |*league, i| results[i] = .{ .league = league };
    // Month boundary: Sep 1 navigates to Aug 31 and Sep 2.
    const output = try homeLive(std.testing.allocator, false, "example.test", &results, "2026-09-01", false, false);
    defer std.testing.allocator.free(output);
    const nav = "/all?date=2026-08-31    /all?date=2026-09-02";
    const nav_at = std.mem.indexOf(u8, output, nav).?;
    // Directly under the date heading, above the sections.
    const heading_at = std.mem.indexOf(u8, output, "sprts  2026-09-01 ET").?;
    try std.testing.expect(nav_at > heading_at);
    try std.testing.expect(output[nav_at - 1] == '\n');
    try std.testing.expect(output[nav_at + nav.len] == '\n');
    const leagues_at = std.mem.indexOf(u8, output, "ALL LEAGUES").?;
    try std.testing.expect(nav_at < leagues_at);
    // Text lockstep: plain line, no tags, no ANSI.
    try std.testing.expect(std.mem.indexOf(u8, output, "<") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(output);
    try expectAlignedTable(output);
    try expectNoBrokenLines(output, 52);
    try std.testing.expect(countRules(output) == 0);

    // Quiet mode drops the heading but keeps the nav on top.
    const quiet = try homeLive(std.testing.allocator, false, "example.test", &results, "2026-09-01", true, false);
    defer std.testing.allocator.free(quiet);
    try std.testing.expect(std.mem.indexOf(u8, quiet, nav) != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "sprts") == null);
}

test "live HTML home nav links mirror the text nav" {
    var results: [core.leagues.all.len]provider.LeagueResult = undefined;
    for (&core.leagues.all, 0..) |*league, i| results[i] = .{ .league = league };
    const page = try homeHtmlLive(std.testing.allocator, "example.test", &results, "2026-09-01", false, false);
    defer std.testing.allocator.free(page);
    // Same visible text as the text nav, each half its own well-formed link.
    const linked = "<a href=\"/all?date=2026-08-31\">/all?date=2026-08-31</a>" ++
        "    " ++
        "<a href=\"/all?date=2026-09-02\">/all?date=2026-09-02</a>";
    const nav_at = std.mem.indexOf(u8, page, linked).?;
    // Inside <pre>, ahead of the sections.
    const pre_at = std.mem.indexOf(u8, page, "<pre>").?;
    try std.testing.expect(nav_at > pre_at);
    const leagues_at = std.mem.indexOf(u8, page, "ALL LEAGUES").?;
    try std.testing.expect(nav_at < leagues_at);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
}

test "static homes carry the same date nav when dated" {
    // Dated static text home: nav under the heading, same spelling.
    const dated = try homeDay(std.testing.allocator, false, "2026-09-01");
    defer std.testing.allocator.free(dated);
    const nav = "/all?date=2026-08-31    /all?date=2026-09-02";
    const nav_at = std.mem.indexOf(u8, dated, nav).?;
    const heading_at = std.mem.indexOf(u8, dated, "sprts\n").?;
    try std.testing.expect(nav_at > heading_at);
    try std.testing.expect(std.mem.indexOf(u8, dated, "<") == null);
    // Dateless static home is unchanged: no day, no nav.
    const plain = try home(std.testing.allocator, false);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "?date=") == null);
    // Dated static HTML home: linked twins of the same line.
    const html_dated = try homeHtmlDay(std.testing.allocator, "2026-09-01");
    defer std.testing.allocator.free(html_dated);
    try std.testing.expect(std.mem.indexOf(u8, html_dated, "<a href=\"/all?date=2026-08-31\">/all?date=2026-08-31</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_dated, "<a href=\"/all?date=2026-09-02\">/all?date=2026-09-02</a>") != null);
    _ = try std.unicode.Utf8View.init(dated);
    // Hostile day text renders no nav instead of failing the page.
    const hostile = try homeDay(std.testing.allocator, false, "2026-09-06&<>\"'");
    defer std.testing.allocator.free(hostile);
    try std.testing.expect(std.mem.indexOf(u8, hostile, "?date=") == null);
}

test "?tz= wiring flips day and label, invalid is ignored" {
    const arena = std.testing.allocator;
    // 2026-09-07T00:00Z: still Sep 6 in ET, already Sep 7 in UTC.
    const epoch: i64 = 1788739200;
    const et_zone = tz.zoneFromTarget("/mlb");
    try std.testing.expect(et_zone == .et);
    const et_day = try tz.resolveDay(arena, null, epoch, et_zone);
    defer arena.free(et_day);
    try std.testing.expectEqualStrings("2026-09-06", et_day);
    const et_label = try tz.labelFor(arena, et_day, et_zone);
    defer arena.free(et_label);
    try std.testing.expectEqualStrings("9/6 ET", et_label);

    const utc_zone = tz.zoneFromTarget("/mlb?tz=utc");
    try std.testing.expect(utc_zone == .utc);
    const utc_day = try tz.resolveDay(arena, null, epoch, utc_zone);
    defer arena.free(utc_day);
    try std.testing.expectEqualStrings("2026-09-07", utc_day);
    const utc_label = try tz.labelFor(arena, utc_day, utc_zone);
    defer arena.free(utc_label);
    try std.testing.expectEqualStrings("9/7 UTC", utc_label);

    // Invalid ?tz= is ignored: ET default stands for both day and label.
    const bogus_zone = tz.zoneFromTarget("/mlb?tz=bogus");
    try std.testing.expect(bogus_zone == .et);
    const bogus_day = try tz.resolveDay(arena, null, epoch, bogus_zone);
    defer arena.free(bogus_day);
    try std.testing.expectEqualStrings("2026-09-06", bogus_day);

    // Explicit ?date wins verbatim in every zone.
    const explicit = try tz.resolveDay(arena, "2026-01-01", epoch, .utc);
    defer arena.free(explicit);
    try std.testing.expectEqualStrings("2026-01-01", explicit);
}

test "live home idle leagues link today with the date" {
    // Idle league only: no board, so it lands in the ALL LEAGUES rows.
    const results = [_]provider.LeagueResult{
        .{ .league = core.leagues.find("nfl").? },
    };
    const day = "2026-09-06";
    const page = try homeHtmlLive(std.testing.allocator, "example.test", &results, day, false, false);
    defer std.testing.allocator.free(page);
    // Same spelling as the static dated home: today spelled out.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nfl?date=2026-09-06\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nfl\">") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    // Dateless fallback is unchanged: static home without a day stays bare.
    const bare = try homeHtml(std.testing.allocator);
    defer std.testing.allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "<a href=\"/nfl\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "?date=") == null);
    // Hostile day text stays escaped in the shared spelling, both homes.
    const hostile = "2026-09-06&<>\"'";
    const evil_live = try homeHtmlLive(std.testing.allocator, "example.test", &results, hostile, true, false);
    defer std.testing.allocator.free(evil_live);
    try std.testing.expect(std.mem.indexOf(u8, evil_live, "/nfl?date=2026-09-06&amp;&lt;&gt;&quot;&#39;") != null);
    try std.testing.expect(std.mem.indexOf(u8, evil_live, hostile) == null);
    try std.testing.expect(std.mem.indexOf(u8, evil_live, "\x1b[") == null);
    const evil_static = try homeHtmlDay(std.testing.allocator, hostile);
    defer std.testing.allocator.free(evil_static);
    try std.testing.expect(std.mem.indexOf(u8, evil_static, "/nfl?date=2026-09-06&amp;&lt;&gt;&quot;&#39;") != null);
    try std.testing.expect(std.mem.indexOf(u8, evil_static, hostile) == null);
    _ = try std.unicode.Utf8View.init(evil_live);
}

test "home html game lines use sibling anchors, never nested" {
    const live_board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "401816854",
                .slug = "cle-bal",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "in",
                .status = "Bot 7th",
                .participants = &.{
                    .{ .id = "a", .name = "Cleveland Guardians", .abbreviation = "CLE", .score = "9", .winner = false, .home_away = "away" },
                    .{ .id = "h", .name = "Baltimore Orioles", .abbreviation = "BAL", .score = "5", .winner = false, .home_away = "home" },
                },
            },
        },
    };
    const today_board: domain.Scoreboard = .{
        .league = "nba",
        .league_name = "NBA",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "2",
                .name = "Third at Fourth",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "7:05 PM ET",
                .participants = &.{
                    .{ .id = "c", .name = "Third", .abbreviation = "TRD", .score = "", .winner = false },
                    .{ .id = "d", .name = "Fourth", .abbreviation = "FRT", .score = "", .winner = false },
                },
            },
        },
    };
    const results = [_]provider.LeagueResult{
        .{ .league = core.leagues.find("mlb").?, .board = live_board },
        .{ .league = core.leagues.find("nba").?, .board = today_board },
        .{ .league = core.leagues.find("nfl").? },
    };
    const page = try homeHtmlLive(std.testing.allocator, "example.test", &results, "2026-09-06", false, false);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    // Every game/team href from the nested layout is still present.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/2026-09-06/cle-bal\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/CLE\">CLE</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/BAL\">BAL</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nba/2\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nba/TRD\">TRD</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nba/FRT\">FRT</a>") != null);
    // Same spans and footer/nav as before.
    try std.testing.expect(std.mem.indexOf(u8, page, "<span class=\"live\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<span class=\"upcoming\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/docs\">docs</a>") != null);
    // No game line nests anchors: on each <pre> line an <a *> open must
    // always close before the next <a *> opens (depth never exceeds 1).
    const open = std.mem.indexOf(u8, page, "<pre>").?;
    const close = std.mem.indexOf(u8, page, "</pre>").?;
    const pre = page[open + "<pre>".len .. close];
    var pre_lines = std.mem.splitScalar(u8, pre, '\n');
    var game_lines: usize = 0;
    while (pre_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "401816854") != null or std.mem.indexOf(u8, line, "CLE") != null) game_lines += 1;
        var depth: usize = 0;
        var j: usize = 0;
        while (j < line.len) {
            const open_at = std.mem.indexOf(u8, line[j..], "<a ");
            const close_at = std.mem.indexOf(u8, line[j..], "</a>");
            if (open_at == null and close_at == null) break;
            if (open_at != null and (close_at == null or open_at.? < close_at.?)) {
                try std.testing.expectEqual(@as(usize, 0), depth);
                depth += 1;
                j += open_at.? + "<a ".len;
            } else {
                try std.testing.expectEqual(@as(usize, 1), depth);
                depth -= 1;
                j += close_at.? + "</a>".len;
            }
        }
        try std.testing.expectEqual(@as(usize, 0), depth);
    }
    try std.testing.expect(game_lines > 0);
    // Visible text unchanged: stripping tags + decoding entities still
    // shows the same game lines as the text renderer.
    var visible: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer visible.deinit();
    var i: usize = 0;
    while (i < pre.len) {
        if (pre[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, pre, i, '>') orelse return error.TestUnexpectedResult;
            i = end + 1;
            continue;
        }
        if (pre[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, pre, i, ';') orelse return error.TestUnexpectedResult;
            const entity = pre[i .. semi + 1];
            if (std.mem.eql(u8, entity, "&amp;")) {
                try visible.writer.writeByte('&');
            } else if (std.mem.eql(u8, entity, "&lt;")) {
                try visible.writer.writeByte('<');
            } else if (std.mem.eql(u8, entity, "&gt;")) {
                try visible.writer.writeByte('>');
            } else if (std.mem.eql(u8, entity, "&quot;")) {
                try visible.writer.writeByte('"');
            } else if (std.mem.eql(u8, entity, "&#39;")) {
                try visible.writer.writeByte('\'');
            } else return error.TestUnexpectedResult;
            i = semi + 1;
            continue;
        }
        try visible.writer.writeByte(pre[i]);
        i += 1;
    }
    const visible_slice = try visible.toOwnedSlice();
    defer std.testing.allocator.free(visible_slice);
    try std.testing.expect(std.mem.indexOf(u8, visible_slice, "mlb CLE   9 @ BAL   5") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible_slice, "Bot 7th") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible_slice, "nba TRD     @ FRT") != null);
    _ = try std.unicode.Utf8View.init(page);
}

test "logo stack is byte-identical across page types" {
    // The shared composer (`pageHead`) owns `<main>` through `<pre>`:
    // home, live home, and scoreboard must agree there byte for byte.
    // A stray `\n` after `<pre>` on any one page is preserved by
    // `pre-wrap` and renders as a blank row, shifting only that page's
    // logo-to-content gap (team/detail/help/digest/standings share the
    // same composer, so they match by construction).
    const board = testBoard();
    const score = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(score);
    const static = try homeHtml(std.testing.allocator);
    defer std.testing.allocator.free(static);
    var results: [1]provider.LeagueResult = .{.{ .league = core.leagues.find("mlb").? }};
    results[0].board = board;
    const live = try homeHtmlLive(std.testing.allocator, "example.test", &results, "2026-09-06", false, false);
    defer std.testing.allocator.free(live);
    const pages = [_][]const u8{ score, static, live };
    var stacks: [3][]const u8 = undefined;
    for (pages, 0..) |page, i| {
        const main_at = std.mem.indexOf(u8, page, "<main>").?;
        const pre_at = std.mem.indexOf(u8, page, "<pre>").?;
        stacks[i] = page[main_at .. pre_at + "<pre>".len];
        // Content starts immediately: no blank row between logo and body.
        try std.testing.expect(page[pre_at + "<pre>".len] != '\n');
    }
    try std.testing.expectEqualStrings(stacks[0], stacks[1]);
    try std.testing.expectEqualStrings(stacks[0], stacks[2]);
}

/// Art-off layout contract: `off` must equal `on` minus the art rows —
/// braille lines drop, and a blank line directly following a dropped line
/// drops too (interior mark blanks in the stacked path, blank pair rows
/// in the side-by-side card). Every kept line stays within `cols` cells.
fn expectArtOffLayout(off: []const u8, on: []const u8, cols: usize) !void {
    try std.testing.expect(!containsBraille(off));
    _ = try std.unicode.Utf8View.init(off);
    var want: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer want.deinit();
    var dropped_prev = false;
    var on_lines = std.mem.splitScalar(u8, on, '\n');
    while (on_lines.next()) |line| {
        // Rebuild the body byte-exactly: each split segment regains its
        // terminator except the trailing empty from the final newline.
        const terminator = on_lines.peek() != null;
        if (containsBraille(line)) {
            dropped_prev = true;
            continue;
        }
        if (line.len == 0 and dropped_prev) continue;
        dropped_prev = false;
        try want.writer.writeAll(line);
        if (terminator) try want.writer.writeByte('\n');
    }
    const want_slice = try want.toOwnedSlice();
    defer std.testing.allocator.free(want_slice);
    try std.testing.expectEqualStrings(want_slice, off);
    var off_lines = std.mem.splitScalar(u8, off, '\n');
    while (off_lines.next()) |line| {
        if (line.len == 0) continue;
        // SGR wraps the fitted bytes only and is never part of the
        // width: measure visible cells with escapes skipped.
        const plain = try stripSgr(std.testing.allocator, line);
        defer std.testing.allocator.free(plain);
        try std.testing.expect(table.textCells(plain) <= cols);
    }
}

/// Copy `s` minus SGR `ESC[...m` runs (visible cells only, for width
/// checks on colored lines). Plain bytes pass through untouched.
fn stripSgr(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var k: usize = 0;
    while (k < s.len) {
        if (s[k] == 0x1b and k + 1 < s.len and s[k + 1] == '[') {
            var m = k + 2;
            while (m < s.len and s[m] != 'm') : (m += 1) {}
            k = if (m < s.len) m + 1 else s.len;
            continue;
        }
        try out.writer.writeByte(s[k]);
        k += 1;
    }
    return out.toOwnedSlice();
}

fn artDuelBoard() domain.Scoreboard {
    return .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "9",
                .slug = "phi-nym",
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
}

test "art off strips every mark, keeps layout minus the art rows" {
    const arena = std.testing.allocator;
    // Both sides ship marks, so art-on carries braille (the precondition:
    // without it this test would pass vacuously).
    try std.testing.expect(core.art.teamArt("mlb", "PHI", .xs) != null);
    try std.testing.expect(core.art.teamArt("mlb", "NYM", .xs) != null);
    const board = artDuelBoard();
    for ([_]?u16{ null, 80, 120 }) |width| {
        const cols: usize = @min(@max(width orelse 52, 52), 200);
        const on = try text(arena, board, false, width, null);
        defer arena.free(on);
        try std.testing.expect(containsBraille(on));
        const off = try textArt(arena, board, false, width, null, false);
        defer arena.free(off);
        try expectArtOffLayout(off, on, cols);
        // Scores, names, and pointers survive verbatim.
        for ([_][]const u8{ "Final", "PHI", "NYM", "5 ✓", "game: /mlb/2026-09-06/phi-nym" }) |token| {
            try std.testing.expect(std.mem.indexOf(u8, off, token) != null);
        }
        // Colored art-off: marks skip (not just uncolor), still no braille.
        const on_color = try textWithZoneArt(arena, board, true, width, null, .et, true);
        defer arena.free(on_color);
        const off_color = try textWithZoneArt(arena, board, true, width, null, .et, false);
        defer arena.free(off_color);
        try expectArtOffLayout(off_color, on_color, cols);
    }
    // Art on is the default: the wrapper renders byte-identically.
    const wrapped = try textWithZone(arena, board, false, null, null, .et);
    defer arena.free(wrapped);
    const explicit = try textWithZoneArt(arena, board, false, null, null, .et, true);
    defer arena.free(explicit);
    try std.testing.expectEqualStrings(wrapped, explicit);
}

test "art off drops stacked marks and their interior blanks too" {
    const arena = std.testing.allocator;
    // One participant takes the stacked (not side-by-side) path, where
    // interior mark blanks survive as empty lines (MLS ATX xs carries
    // one). Art-off must drop those blanks with the mark, not orphan them.
    try std.testing.expect(core.art.teamArt("mls", "ATX", .xs) != null);
    const board: domain.Scoreboard = .{
        .league = "mls",
        .league_name = "MLS",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "7",
                .slug = "event-1",
                .name = "ATX at HOU",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "1", .name = "Austin FC", .abbreviation = "ATX", .score = "1", .winner = true },
                },
            },
        },
    };
    const on = try text(arena, board, false, null, null);
    defer arena.free(on);
    try std.testing.expect(containsBraille(on));
    const off = try textArt(arena, board, false, null, null, false);
    defer arena.free(off);
    try expectArtOffLayout(off, on, 52);
    try std.testing.expect(std.mem.indexOf(u8, off, "Austin FC") != null);
    try std.testing.expect(std.mem.indexOf(u8, off, "game: /mls/2026-09-06/event-1") != null);
}

/// Visible-text twin of `expectVisiblePreText` for the art flag: the
/// art-off page's `<pre>` text must equal the art-off text body, so the
/// linkifier adds invisible tags only, never layout.
fn expectVisiblePreTextArt(page: []const u8, board: domain.Scoreboard, width: ?u16, height: ?u16, art: bool) !void {
    const pre = preBody(page);
    var visible: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer visible.deinit();
    var i: usize = 0;
    while (i < pre.len) {
        if (pre[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, pre, i, '>') orelse return error.TestUnexpectedResult;
            i = end + 1;
            continue;
        }
        if (pre[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, pre, i, ';') orelse return error.TestUnexpectedResult;
            const entity = pre[i .. semi + 1];
            if (std.mem.eql(u8, entity, "&amp;")) {
                try visible.writer.writeByte('&');
            } else if (std.mem.eql(u8, entity, "&lt;")) {
                try visible.writer.writeByte('<');
            } else if (std.mem.eql(u8, entity, "&gt;")) {
                try visible.writer.writeByte('>');
            } else if (std.mem.eql(u8, entity, "&quot;")) {
                try visible.writer.writeByte('"');
            } else if (std.mem.eql(u8, entity, "&#39;")) {
                try visible.writer.writeByte('\'');
            } else return error.TestUnexpectedResult;
            i = semi + 1;
            continue;
        }
        try visible.writer.writeByte(pre[i]);
        i += 1;
    }
    const visible_slice = try visible.toOwnedSlice();
    defer std.testing.allocator.free(visible_slice);
    const want = try textWithZoneArt(std.testing.allocator, board, false, width, height, .et, art);
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, visible_slice);
}

test "art-off HTML carries no marks, no logo spans, same visible text" {
    const arena = std.testing.allocator;
    const board = artDuelBoard();
    const page = try scoreHtmlArt(arena, board, null, null, false);
    defer arena.free(page);
    try std.testing.expect(!containsBraille(page));
    // No logo spans: art rows re-render as rgb spans when on, so their
    // absence proves every mark row is gone (not merely unlinked).
    try std.testing.expect(std.mem.indexOf(u8, page, "rgb(") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    // Links survive: the human game anchor and both team links navigate.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/2026-09-06/phi-nym\" id=\"game-9\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/PHI\">PHI</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/NYM\">NYM</a>") != null);
    try expectVisiblePreTextArt(page, board, null, null, false);
    _ = try std.unicode.Utf8View.init(page);
    // Art on keeps its spans (precondition: this board really has color
    // marks, so the rgb( absence above is meaningful, not vacuous).
    const on_page = try scoreHtml(arena, board, null, null);
    defer arena.free(on_page);
    if (core.art.teamArtColor("mlb", "PHI", .xs) != null) {
        try std.testing.expect(std.mem.indexOf(u8, on_page, "rgb(") != null);
    }
}

test "home and one-line views render no team marks" {
    // Verified, not assumed: the home page (live, one-line) and the
    // scoreboard one-line fallback print abbreviations only, so `?art=off`
    // is meaningless there — but they must prove it by rendering zero
    // braille even for teams that ship marks (PHI/NYM do).
    const arena = std.testing.allocator;
    try std.testing.expect(core.art.teamArt("mlb", "PHI", .xs) != null);
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "9",
                .name = "PHI at NYM",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "1", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = true, .home_away = "away" },
                    .{ .id = "2", .name = "New York Mets", .abbreviation = "NYM", .score = "3", .winner = false, .home_away = "home" },
                },
            },
        },
    };
    const mlb = core.leagues.find("mlb").?;
    const results = [_]provider.LeagueResult{.{ .league = mlb, .board = board }};
    const live = try homeLiveWithZone(arena, false, "example.test", &results, "2026-09-06", false, .et, false);
    defer arena.free(live);
    try std.testing.expect(!containsBraille(live));
    const live_html = try homeHtmlLive(arena, "example.test", &results, "2026-09-06", false, false);
    defer arena.free(live_html);
    try std.testing.expect(!containsBraille(live_html));
    const one_line = try homeOneLineWithZone(arena, &results, false, .et);
    defer arena.free(one_line);
    try std.testing.expect(!containsBraille(one_line));
    _ = try std.unicode.Utf8View.init(live);
}

test "dated home skips idle leagues, keeps failed-league links" {
    // Past-day home: MLB happened, NFL answered empty (off-day), NBA
    // failed to answer (outage). The dated view reads like the home
    // summary — only leagues/games that happened — while the outage keeps
    // its plain-link degraded row (never a silent drop).
    const arena = std.testing.allocator;
    const mlb_board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2025-09-10",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2025-09-10T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false, .record = "77-70", .home_away = "away" },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true, .record = "89-58", .home_away = "home" },
                },
            },
        },
    };
    const nfl_board: domain.Scoreboard = .{
        .league = "nfl",
        .league_name = "NFL",
        .date = "2025-09-10",
        .source = "test",
        .games = &.{},
    };
    const results = [_]provider.LeagueResult{
        .{ .league = core.leagues.find("mlb").?, .board = mlb_board },
        .{ .league = core.leagues.find("nfl").?, .board = nfl_board },
        .{ .league = core.leagues.find("nba").? },
    };
    const dated = try homeLive(arena, false, "example.test", &results, "2025-09-10", false, true);
    defer arena.free(dated);
    // The game that happened renders with its section header and line.
    try std.testing.expect(std.mem.indexOf(u8, dated, "MLB  09-10") != null);
    try std.testing.expect(std.mem.indexOf(u8, dated, "mlb AWY   2 @ HME   5") != null);
    // Off-day league leaves no row: its link would point at an empty
    // dated board, so nothing references it at all.
    try std.testing.expect(std.mem.indexOf(u8, dated, "nfl") == null);
    try std.testing.expect(std.mem.indexOf(u8, dated, "NFL") == null);
    // Failed league keeps its degraded link under ALL LEAGUES.
    try std.testing.expect(std.mem.indexOf(u8, dated, "ALL LEAGUES") != null);
    try std.testing.expect(std.mem.indexOf(u8, dated, "nba           NBA") != null);
    _ = try std.unicode.Utf8View.init(dated);
    // Today view of the same results is unchanged: the off-day league
    // still lists as an idle link next to the failed one.
    const today = try homeLive(arena, false, "example.test", &results, "2025-09-10", false, false);
    defer arena.free(today);
    try std.testing.expect(std.mem.indexOf(u8, today, "nfl           NFL") != null);
    try std.testing.expect(std.mem.indexOf(u8, today, "nba           NBA") != null);
    // A clean dated day (nothing failed) drops the ALL LEAGUES block
    // entirely instead of printing an empty frame.
    const clean_results = [_]provider.LeagueResult{
        .{ .league = core.leagues.find("mlb").?, .board = mlb_board },
        .{ .league = core.leagues.find("nfl").?, .board = nfl_board },
    };
    const clean = try homeLive(arena, false, "example.test", &clean_results, "2025-09-10", false, true);
    defer arena.free(clean);
    try std.testing.expect(std.mem.indexOf(u8, clean, "ALL LEAGUES") == null);
    try std.testing.expect(std.mem.indexOf(u8, clean, "MLB  09-10") != null);
}

test "dated home matches today render when every league played" {
    // Byte-parity lock: with no empty and no failed boards the dated flag
    // selects nothing, so a past home renders exactly like today — same
    // sections, same colors, same links (text + HTML).
    const arena = std.testing.allocator;
    const mlb_board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2025-09-10",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .slug = "awy-hme",
                .name = "Away at Home",
                .starts_at = "2025-09-10T17:00Z",
                .state = "in",
                .status = "Top 7th",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "0", .winner = false, .home_away = "away" },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "3", .winner = false, .home_away = "home" },
                },
            },
        },
    };
    const results = [_]provider.LeagueResult{
        .{ .league = core.leagues.find("mlb").?, .board = mlb_board },
    };
    const dated = try homeLive(arena, true, "example.test", &results, "2025-09-10", false, true);
    defer arena.free(dated);
    const today = try homeLive(arena, true, "example.test", &results, "2025-09-10", false, false);
    defer arena.free(today);
    try std.testing.expectEqualStrings(today, dated);
    // Live color survives the past view (status red): nothing about the
    // request date mutes the palette.
    try std.testing.expect(std.mem.indexOf(u8, dated, "\x1b[1;31m") != null);
    const dated_html = try homeHtmlLive(arena, "example.test", &results, "2025-09-10", false, true);
    defer arena.free(dated_html);
    const today_html = try homeHtmlLive(arena, "example.test", &results, "2025-09-10", false, false);
    defer arena.free(today_html);
    try std.testing.expectEqualStrings(today_html, dated_html);
    try std.testing.expect(std.mem.indexOf(u8, dated_html, "<a href=\"/mlb/2025-09-10/awy-hme\">") != null);
    _ = try std.unicode.Utf8View.init(dated);
    _ = try std.unicode.Utf8View.init(dated_html);
}

test "past scoreboard keeps records, winner colors, marks, and links" {
    // Content contract for past dates: a final board from last season
    // renders the full today treatment — records, winner tick + green,
    // team marks, game/team links — because no renderer consults the
    // request date, only the board in hand.
    const arena = std.testing.allocator;
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2025-09-10",
        .source = "test",
        .games = &.{
            .{
                .id = "9",
                .slug = "phi-nym",
                .name = "PHI at NYM",
                .starts_at = "2025-09-10T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "1", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = true, .record = "83-61" },
                    .{ .id = "2", .name = "New York Mets", .abbreviation = "NYM", .score = "3", .winner = false, .record = "74-70" },
                },
            },
        },
    };
    try std.testing.expect(core.art.teamArt("mlb", "PHI", .xs) != null);
    const colored = try text(arena, board, true, null, null);
    defer arena.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "(83-61)") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "(74-70)") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[32m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "✓") != null);
    try std.testing.expect(containsBraille(colored));
    try std.testing.expect(std.mem.indexOf(u8, colored, "MLB  2025-09-10 ET") != null);
    _ = try std.unicode.Utf8View.init(colored);
    const page = try scoreHtml(arena, board, null, null);
    defer arena.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/2025-09-10/phi-nym\" id=\"game-9\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/PHI\">PHI</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/NYM\">NYM</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try expectVisiblePreText(page, board, null, null);
}

test "scoreboard hostile fixture keeps text and HTML visible text equal" {
    // Phase 4 lock: scoreboard rows compose in `view` (shared by text
    // and the HTML linkifier post-pass), so hostile provider text must
    // read identically in both. Long multibyte names, markup-looking
    // statuses, empty scores/abbreviations, records, a name-only game,
    // and an athlete-style game ride one board through both emitters.
    const arena = std.testing.allocator;
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away <b>&\"quoted\"</b> at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final <OT> & \"extra\"",
                .participants = &.{
                    .{ .id = "a", .name = "Atlético Madrid Club de Fútbol with an extremely long tail that never ends", .abbreviation = "AWY", .score = "2", .winner = false, .record = "69-74" },
                    .{ .id = "h", .name = "Home\tTeam 漢字", .abbreviation = "HME", .score = "5", .winner = true, .record = "80-63" },
                },
            },
            .{
                .id = "2",
                .name = "Contender Series <pre>",
                .starts_at = "2026-09-06T23:00Z",
                .state = "pre",
                .status = "9/8 - 7:00 PM EDT",
                .participants = &.{
                    .{ .id = "x", .name = "Colton Loud & Partners", .abbreviation = "", .score = "", .winner = false },
                    .{ .id = "y", .name = "Christian Natividad", .abbreviation = "", .score = "", .winner = false },
                },
            },
            .{
                .id = "3",
                .name = "Rain-delayed <i>showcase</i> & friends",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{},
            },
        },
    };
    // No raw markup or escapes leak into the text body; every content
    // line fits the frame and stays valid UTF-8.
    const body = try text(arena, board, false, null, null);
    defer arena.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "<OT>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(body);
    try expectNoBrokenLines(body, 52);
    // The HTML page escapes the hostile bytes and its visible `<pre>`
    // text still matches the text renderer byte for byte.
    const page = try scoreHtml(arena, board, null, null);
    defer arena.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Final &lt;OT&gt; &amp; &quot;extra&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<OT>") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try expectVisiblePreText(page, board, null, null);
    // Same contract through the view helper the new suites use: strip
    // each HTML pre line and compare against the text lines.
    const pre = preBody(page);
    var pre_lines = std.mem.splitScalar(u8, pre, '\n');
    var text_lines = std.mem.splitScalar(u8, body, '\n');
    while (true) {
        const h = pre_lines.next();
        const t = text_lines.next();
        try std.testing.expectEqual(h == null, t == null);
        if (h == null) break;
        const clean = try view.stripHtmlVisible(arena, h.?);
        defer arena.free(clean);
        try std.testing.expectEqualStrings(t.?, clean);
    }
    _ = try std.unicode.Utf8View.init(page);
}

// Per-sport scoreboard VIEW parity: every league family shows everything
// its board rows support — records on team rows, the TV broadcaster line
// when the provider supplies one — in text AND HTML with identical
// visible text. Inline fixtures only, never live ESPN. Provider gaps
// (data absent upstream) are reported in the commit message, not faked:
// soccer rows often carry no records, tennis/racing/MMA/golf rows carry
// athlete names with no abbreviations or records, and no sport carries
// win probabilities on `domain.Game` yet.
fn familyScoreboard() domain.Scoreboard {
    return .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "9",
                .name = "PHI at NYM",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .network = "ESPN & <Deportes>",
                .participants = &.{
                    .{ .id = "1", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = true, .record = "83-61" },
                    .{ .id = "2", .name = "New York Mets", .abbreviation = "NYM", .score = "3", .winner = false, .record = "74-70" },
                },
            },
            .{
                .id = "10",
                .name = "Contender Series",
                .starts_at = "2026-09-06T23:00Z",
                .state = "pre",
                .status = "9/8 - 7:00 PM EDT",
                .network = "PPV",
                .participants = &.{
                    .{ .id = "x", .name = "Colton Loud", .abbreviation = "", .score = "", .winner = false },
                    .{ .id = "y", .name = "Christian Natividad", .abbreviation = "", .score = "", .winner = false },
                },
            },
            .{
                .id = "11",
                .name = "Rain-delayed <showcase> & friends",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "Scheduled",
                .network = "ESPN+",
                .participants = &.{},
            },
        },
    };
}

test "family scoreboard renders records and TV lines in text and HTML" {
    const arena = std.testing.allocator;
    const board = familyScoreboard();
    const body = try text(arena, board, false, null, null);
    defer arena.free(body);
    // Team rows carry records; every game with a broadcaster gets a TV line.
    for ([_][]const u8{ "Final", "(83-61)", "(74-70)", "TV: ESPN & <Deportes>", "TV: PPV", "TV: ESPN+", "Colton Loud", "Rain-delayed <showcase> & friends" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, body, token) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, body, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(body);
    try expectNoBrokenLines(body, 52);
    // HTML escapes the hostile broadcaster; visible text matches byte for byte.
    const page = try scoreHtml(arena, board, null, null);
    defer arena.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "TV: ESPN &amp; &lt;Deportes&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "TV: ESPN & <Deportes>") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<Deportes>") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try expectVisiblePreText(page, board, null, null);
    _ = try std.unicode.Utf8View.init(page);
}

test "family scoreboard without networks skips every TV line" {
    const arena = std.testing.allocator;
    var board = familyScoreboard();
    var games = [_]domain.Game{ board.games[0], board.games[1], board.games[2] };
    games[0].network = null;
    games[1].network = null;
    games[2].network = null;
    board.games = &games;
    const body = try text(arena, board, false, null, null);
    defer arena.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "TV:") == null);
    // Records still render: the TV skip drops one line, nothing else.
    try std.testing.expect(std.mem.indexOf(u8, body, "(83-61)") != null);
    const page = try scoreHtml(arena, board, null, null);
    defer arena.free(page);
    try expectVisiblePreText(page, board, null, null);
}

test "family scoreboard per-league boards keep TV parity" {
    // One duel per league family through the same text/HTML contract:
    // football, basketball, hockey, soccer, tennis, racing, MMA, golf.
    const arena = std.testing.allocator;
    const families = [_]struct { slug: []const u8, name: []const u8, away: domain.Participant, home: domain.Participant, network: ?[]const u8 }{
        .{ .slug = "nfl", .name = "NFL", .away = .{ .id = "a", .name = "Kansas City Chiefs", .abbreviation = "KC", .score = "27", .winner = true, .record = "11-3" }, .home = .{ .id = "h", .name = "Philadelphia Eagles", .abbreviation = "PHI", .score = "24", .winner = false, .record = "10-4" }, .network = "FOX" },
        .{ .slug = "nba", .name = "NBA", .away = .{ .id = "a", .name = "Boston Celtics", .abbreviation = "BOS", .score = "112", .winner = true, .record = "45-20" }, .home = .{ .id = "h", .name = "Los Angeles Lakers", .abbreviation = "LAL", .score = "108", .winner = false, .record = "40-25" }, .network = "TNT" },
        .{ .slug = "nhl", .name = "NHL", .away = .{ .id = "a", .name = "Boston Bruins", .abbreviation = "BOS", .score = "4", .winner = true, .record = "38-14-9" }, .home = .{ .id = "h", .name = "Buffalo Sabres", .abbreviation = "BUF", .score = "3", .winner = false, .record = "30-25-6" }, .network = "ESPN+" },
        .{ .slug = "epl", .name = "Premier League", .away = .{ .id = "a", .name = "Arsenal", .abbreviation = "ARS", .score = "2", .winner = true }, .home = .{ .id = "h", .name = "Chelsea", .abbreviation = "CHE", .score = "1", .winner = false }, .network = "NBC" },
        .{ .slug = "atp", .name = "ATP", .away = .{ .id = "a", .name = "Carlos Alcaraz", .abbreviation = "", .score = "2", .winner = true }, .home = .{ .id = "h", .name = "Jannik Sinner", .abbreviation = "", .score = "1", .winner = false }, .network = "ESPN2" },
        .{ .slug = "f1", .name = "Formula 1", .away = .{ .id = "a", .name = "Max Verstappen", .abbreviation = "", .score = "1st", .winner = true }, .home = .{ .id = "h", .name = "Lando Norris", .abbreviation = "", .score = "2nd", .winner = false }, .network = "ESPN" },
        .{ .slug = "ufc", .name = "UFC", .away = .{ .id = "a", .name = "Islam Makhachev", .abbreviation = "", .score = "W", .winner = true }, .home = .{ .id = "h", .name = "Arman Tsarukyan", .abbreviation = "", .score = "L", .winner = false }, .network = "PPV" },
        .{ .slug = "pga", .name = "PGA Tour", .away = .{ .id = "a", .name = "Scottie Scheffler", .abbreviation = "", .score = "-12", .winner = true }, .home = .{ .id = "h", .name = "Rory McIlroy", .abbreviation = "", .score = "-10", .winner = false }, .network = "CBS" },
    };
    for (families) |family| {
        const board: domain.Scoreboard = .{
            .league = family.slug,
            .league_name = family.name,
            .date = "2026-09-06",
            .source = "test",
            .games = &.{
                .{
                    .id = "1",
                    .name = "Away at Home",
                    .starts_at = "2026-09-06T17:00Z",
                    .state = "post",
                    .status = "Final",
                    .network = family.network,
                    .participants = &.{ family.away, family.home },
                },
            },
        };
        const body = try text(arena, board, false, null, null);
        defer arena.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, family.away.name) != null);
        try std.testing.expect(std.mem.indexOf(u8, body, family.home.name) != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "TV: ") != null);
        if (family.away.record) |record| {
            try std.testing.expect(std.mem.indexOf(u8, body, record) != null);
        }
        _ = try std.unicode.Utf8View.init(body);
        const page = try scoreHtml(arena, board, null, null);
        defer arena.free(page);
        try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
        try expectVisiblePreText(page, board, null, null);
    }
}
