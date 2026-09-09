//! Multi-league digest for `GET /all` (`/api/v1/all` JSON): one bounded
//! section per league, each capped at `default_games_per_league` games with
//! a `+N more` pointer to the league route. All leagues are included; no
//! league is dropped to meet a budget — the per-league game cap is the
//! bound, so one request fans out to at most `leagues.len` upstream
//! fetches (each cache-guarded), never unboundedly.
//!
//! Failure semantics: one league's upstream failure never fails the digest.
//! A league whose board is missing renders an `unavailable` section (text)
//! or a zero-game board entry (JSON) and the rest render normally.
//! Native path goes through `NativeCache.getOrFetch` per league (same
//! fresh/stale windows as single boards); the worker path reuses
//! `serveBoard`-style per-league fetch+render. `week` is NOT fanned out:
//! the digest is date-driven (`?date=` only).
//!
//! Week note: `?week=` is honored per-league by ESPN only where the sport
//! supports it (football: NFL/NCAAF). Other leagues ignore the param and
//! return the date-driven board.

const std = @import("std");
const core = @import("sprts_core");
const render = @import("render.zig");
const tz = @import("tz.zig");

/// Games shown per league section before the `+N more` pointer.
pub const default_games_per_league: u16 = 5;

pub const DigestSection = struct {
    league: *const core.leagues.League,
    board: ?core.domain.Scoreboard = null,
};

/// JSON shape for `/api/v1/all`: reuse `domain.Scoreboard` verbatim per
/// league (no new field names); unavailable leagues are zero-game boards
/// with the league/date/source identity intact.
pub const DigestJson = struct {
    schema_version: []const u8 = "1",
    date: []const u8,
    leagues: []const core.domain.Scoreboard,
};

/// Text digest: one `render.text` section per league, capped at
/// `games_per_league` via the existing `height` param, plus a
/// `+N more → /<slug>?date=<day>` pointer line when capped. Missing boards
/// render a one-line `unavailable` section; output is always valid UTF-8
/// (it only concatenates `render.text` output and ASCII pointers) and
/// strips all color when `color` is false (same flag as `render.text`).
/// The heading names its zone (`sprts all  2026-09-06 ET`).
pub fn textWithZone(
    allocator: std.mem.Allocator,
    sections: []const DigestSection,
    day: []const u8,
    color: bool,
    width: ?u16,
    height: ?u16,
    quiet: bool,
    zone: tz.Zone,
) ![]u8 {
    const per_league = height orelse default_games_per_league;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    if (!quiet) {
        const tag = try tz.zoneTag(allocator, zone);
        defer allocator.free(tag);
        const heading = try std.fmt.allocPrint(allocator, "sprts all  {s} {s}", .{ day, tag });
        defer allocator.free(heading);
        if (color) try w.print("\x1b[2m{s}\x1b[0m\n", .{heading}) else try w.print("{s}\n", .{heading});
    }
    for (sections) |section| {
        const board = section.board orelse {
            try w.print("/{s}?date={s}: unavailable\n", .{ section.league.slug, day });
            continue;
        };
        const capped = @min(per_league, board.games.len);
        const slice: core.domain.Scoreboard = .{
            .league = board.league,
            .league_name = board.league_name,
            .date = board.date,
            .source = board.source,
            .games = board.games[0..capped],
        };
        const body = try render.textWithZone(allocator, slice, color, width, null, zone);
        defer allocator.free(body);
        try w.writeAll(body);
        if (capped < board.games.len) {
            try w.print("+{d} more -> /{s}?date={s}\n", .{ board.games.len - capped, board.league, day });
        }
    }
    if (!quiet) try w.writeAll("more: /<league>?date=<day>\n");
    return out.toOwnedSlice();
}

/// ET-default wrapper for `textWithZone`.
pub fn text(
    allocator: std.mem.Allocator,
    sections: []const DigestSection,
    day: []const u8,
    color: bool,
    width: ?u16,
    height: ?u16,
    quiet: bool,
) ![]u8 {
    return textWithZone(allocator, sections, day, color, width, height, quiet, .et);
}

/// JSON digest: one `domain.Scoreboard` per league in `core.leagues.all`
/// order; missing boards become zero-game boards so the league set is
/// stable and the shape reuses existing field names only.
pub fn jsonBoards(allocator: std.mem.Allocator, sections: []const DigestSection, day: []const u8) ![]core.domain.Scoreboard {
    const boards = try allocator.alloc(core.domain.Scoreboard, sections.len);
    for (sections, 0..) |section, i| {
        if (section.board) |board| {
            boards[i] = board;
        } else {
            boards[i] = .{
                .league = section.league.slug,
                .league_name = section.league.name,
                .date = day,
                .source = "site.api.espn.com",
                .games = &.{},
            };
        }
    }
    return boards;
}

pub fn json(allocator: std.mem.Allocator, sections: []const DigestSection, day: []const u8) ![]u8 {
    // Boards slice is stringify scratch: build it in a temp arena so the
    // caller's allocator owns only the returned body (no leak to free).
    var tmp = std.heap.ArenaAllocator.init(allocator);
    defer tmp.deinit();
    return render.validatedJson(DigestJson, allocator, .{
        .date = day,
        .leagues = try jsonBoards(tmp.allocator(), sections, day),
    });
}

/// HTML digest: the text digest (uncolored) in a `<pre>` block with nav.
/// Same single-source layout principle as `render.scoreHtml`.
pub fn htmlWithZone(allocator: std.mem.Allocator, sections: []const DigestSection, day: []const u8, width: ?u16, height: ?u16, quiet: bool, zone: tz.Zone) ![]u8 {
    const body = try textWithZone(allocator, sections, day, false, width, height, true, zone);
    defer allocator.free(body);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const tag = try tz.zoneTag(allocator, zone);
    defer allocator.free(tag);
    const title = try std.fmt.allocPrint(allocator, "sprts all {s} {s}", .{ day, tag });
    defer allocator.free(title);
    try render.pageHead(w, title);
    try w.writeAll("<pre>");
    try render.escapeInto(w, body);
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/all?date={s}\">all</a>", .{day});
    try w.print("<a href=\"/api/v1/all?date={s}\">json</a>", .{day});
    try render.closePageWithNav(w);
    _ = quiet;
    return out.toOwnedSlice();
}

/// ET-default wrapper for `htmlWithZone`.
pub fn html(allocator: std.mem.Allocator, sections: []const DigestSection, day: []const u8, width: ?u16, height: ?u16, quiet: bool) ![]u8 {
    return htmlWithZone(allocator, sections, day, width, height, quiet, .et);
}

fn stripAnsi(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            var j = i + 2;
            while (j < s.len and s[j] != 'm') : (j += 1) {}
            i = if (j < s.len) j + 1 else s.len;
            continue;
        }
        try out.writer.writeByte(s[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

test "digest text renders multi-section with cap pointer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const games = try arena.alloc(core.domain.Game, 7);
    for (games, 0..) |*game, i| {
        game.* = .{
            .id = try std.fmt.allocPrint(arena, "{d}", .{i}),
            .name = "Away at Home",
            .starts_at = "2026-09-06T17:00Z",
            .state = "post",
            .status = "Final",
            .participants = &.{
                .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
            },
        };
    }
    const mlb_board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = games,
    };
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = mlb_board },
        .{ .league = core.leagues.find("nfl").?, .board = null },
    };
    const output = try text(arena, &sections, "2026-09-06", false, null, 3, false);
    // Capped at 3 of 7: pointer carries the remaining count + league route.
    try std.testing.expect(std.mem.indexOf(u8, output, "+4 more -> /mlb?date=2026-09-06") != null);
    // Failed league degrades to an unavailable marker, digest survives.
    try std.testing.expect(std.mem.indexOf(u8, output, "/nfl?date=2026-09-06: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(output);
}

test "digest text default cap is five per league" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const games = try arena.alloc(core.domain.Game, 8);
    for (games, 0..) |*game, i| {
        game.* = .{
            .id = try std.fmt.allocPrint(arena, "{d}", .{i}),
            .name = "Away at Home",
            .starts_at = "2026-09-06T17:00Z",
            .state = "post",
            .status = "Final",
            .participants = &.{},
        };
    }
    const board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = games,
    };
    const sections = [_]DigestSection{.{ .league = core.leagues.find("mlb").?, .board = board }};
    const output = try text(arena, &sections, "2026-09-06", false, null, null, true);
    try std.testing.expect(std.mem.indexOf(u8, output, "+3 more -> /mlb?date=2026-09-06") != null);
    _ = try std.unicode.Utf8View.init(output);
}

test "digest json reuses Scoreboard shapes with stable league set" {
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = null },
    };
    const output = try json(std.testing.allocator, &sections, "2026-09-06");
    defer std.testing.allocator.free(output);
    // No new field names: Scoreboard + DigestJson envelope only.
    try std.testing.expect(std.mem.indexOf(u8, output, "\"schema_version\": \"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"league\": \"mlb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"games\": []") != null);
    _ = try std.unicode.Utf8View.init(output);
}

test "digest html links and never carries ANSI" {
    var html_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer html_arena_state.deinit();
    const html_arena = html_arena_state.allocator();
    const html_sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = null },
    };
    const page = try html(html_arena, &html_sections, "2026-09-06", null, null, false);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "/api/v1/all?date=2026-09-06") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
}

test "digest color strip round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board: core.domain.Scoreboard = .{
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
    const sections = [_]DigestSection{.{ .league = core.leagues.find("mlb").?, .board = board }};
    const colored = try text(arena, &sections, "2026-09-06", true, null, null, true);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
    const plain = try text(arena, &sections, "2026-09-06", false, null, null, true);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    const stripped = try stripAnsi(arena, colored);
    try std.testing.expectEqualStrings(plain, stripped);
    _ = try std.unicode.Utf8View.init(plain);
}
