//! Multi-league digest for `GET /all` (`/api/v1/all` JSON): one bounded
//! section per league, each capped at `default_games_per_league` games with
//! a `+N more` pointer to the league route. All leagues are included; no
//! league is dropped to meet a budget — the per-league game cap is the
//! bound, so one request fans out to at most `leagues.len` upstream
//! fetches (each cache-guarded), never unboundedly.
//!
//! Failure semantics: one league's upstream failure never fails the digest.
//! A league whose board is missing renders an `unavailable` section (text)
//! or a zero-game board entry plus its slug in `DigestJson.degraded` (JSON)
//! and the rest render normally.
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
const view = @import("view.zig");
const tz = @import("tz.zig");

/// Games shown per league section before the `+N more` pointer.
pub const default_games_per_league: u16 = 5;

pub const DigestSection = struct {
    league: *const core.leagues.League,
    board: ?core.domain.Scoreboard = null,
};

/// JSON shape for `/api/v1/all`: reuse `domain.Scoreboard` verbatim per
/// league, plus one additive outage signal. Unavailable leagues are
/// zero-game boards with the league/date/source identity intact, and their
/// slugs are listed in `degraded`: zero games plus absent-from-`degraded`
/// means off-day, zero games plus present means outage (retry later).
/// Nothing was renamed or removed; `degraded` is always emitted
/// (possibly `[]`).
pub const DigestJson = struct {
    schema_version: []const u8 = "1",
    date: []const u8,
    leagues: []const core.domain.Scoreboard,
    degraded: []const []const u8 = &.{},

    pub const jsonschema = .{
        .name = "DigestJson",
        .fields = .{
            .degraded = .{ .description = "Slugs of leagues whose upstream fetch failed for this digest; their entries are zero-game boards. Empty means every league answered, so zero games is an off-day." },
        },
    };
};

/// Text digest: one shared-composer section per league (Phase 5 rides
/// `render.text`, which composes every row through the `view` section
/// composers, so digest text and HTML can never drift from the
/// scoreboard), capped at `games_per_league` via the existing `height`
/// param, plus a `+N more → /<slug>?date=<day>` pointer line when
/// capped. Missing boards render a one-line `unavailable` section; output is always valid UTF-8
/// (it only concatenates `render.text` output and ASCII pointers) and
/// strips all color when `color` is false (same flag as `render.text`).
/// The heading names its zone (`sprts all  2026-09-06 ET`). `dated`
/// selects the explicit-`?date` past view: answered-but-empty boards
/// (off-day) are skipped entirely — no empty sections, no `No games
/// scheduled` noise — while missing boards (upstream failure) keep their
/// `unavailable` degraded markers and the JSON `degraded` list (see
/// `DigestJson`) still tells outage apart from off-day.
pub fn textWithZoneArt(
    allocator: std.mem.Allocator,
    sections: []const DigestSection,
    day: []const u8,
    color: bool,
    width: ?u16,
    height: ?u16,
    quiet: bool,
    zone: tz.Zone,
    art: bool,
    dated: bool,
) ![]u8 {
    const per_league = height orelse default_games_per_league;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    if (!quiet) {
        const tag = try tz.zoneTag(allocator, zone);
        defer allocator.free(tag);
        const heading = try view.digestHeading(allocator, day, tag);
        defer allocator.free(heading);
        if (color) try w.print("\x1b[2m{s}\x1b[0m\n", .{heading}) else try w.print("{s}\n", .{heading});
    }
    for (sections) |section| {
        const board = section.board orelse {
            const marker = try view.digestUnavailable(allocator, section.league.slug, day);
            defer allocator.free(marker);
            try w.print("{s}\n", .{marker});
            continue;
        };
        // Dated past view: an answered-but-empty board is an off-day —
        // skip the section entirely (see `dated`). A missing board above
        // is an upstream failure and keeps its degraded marker.
        if (dated and board.games.len == 0) continue;
        const capped = @min(per_league, board.games.len);
        const slice: core.domain.Scoreboard = .{
            .league = board.league,
            .league_name = board.league_name,
            .date = board.date,
            .source = board.source,
            .games = board.games[0..capped],
        };
        const body = try render.textWithZoneArt(allocator, slice, color, width, null, zone, art);
        defer allocator.free(body);
        try w.writeAll(body);
        if (capped < board.games.len) {
            try w.print("+{d} more -> /{s}?date={s}\n", .{ board.games.len - capped, board.league, day });
        }
    }
    if (!quiet) try w.writeAll("more: /<league>?date=<day>\n");
    return out.toOwnedSlice();
}

/// Wrapper with art on (`dated=false`: today view): existing callers keep
/// rendering exactly as before.
pub fn textWithZone(
    allocator: std.mem.Allocator,
    sections: []const DigestSection,
    day: []const u8,
    color: bool,
    width: ?u16,
    height: ?u16,
    quiet: bool,
    zone: tz.Zone,
    dated: bool,
) ![]u8 {
    return textWithZoneArt(allocator, sections, day, color, width, height, quiet, zone, true, dated);
}

/// ET-default wrapper for `textWithZone` (`dated=false`: today view).
pub fn text(
    allocator: std.mem.Allocator,
    sections: []const DigestSection,
    day: []const u8,
    color: bool,
    width: ?u16,
    height: ?u16,
    quiet: bool,
    dated: bool,
) ![]u8 {
    return textWithZone(allocator, sections, day, color, width, height, quiet, .et, dated);
}

/// JSON digest: one `domain.Scoreboard` per league in `core.leagues.all`
/// order; missing boards become zero-game boards so the league set is
/// stable, and their slugs land in `DigestJson.degraded` (see `json`).
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
        .degraded = try degradedSlugs(tmp.allocator(), sections),
    });
}

/// Slugs of sections with no board: the additive outage signal carried on
/// `DigestJson.degraded`. Stringify scratch like `jsonBoards` (see `json`);
/// slugs are static league identities, so no dupe is needed.
fn degradedSlugs(allocator: std.mem.Allocator, sections: []const DigestSection) ![]const []const u8 {
    var count: usize = 0;
    for (sections) |section| {
        if (section.board == null) count += 1;
    }
    const slugs = try allocator.alloc([]const u8, count);
    var i: usize = 0;
    for (sections) |section| {
        if (section.board == null) {
            slugs[i] = section.league.slug;
            i += 1;
        }
    }
    return slugs;
}

/// HTML digest: the text digest (uncolored) in a `<pre>` block with nav.
/// Same single-source layout principle as `render.scoreHtml`. `dated`
/// skips off-day sections exactly like the text digest (see
/// `textWithZoneArt`).
pub fn htmlWithZoneArt(allocator: std.mem.Allocator, sections: []const DigestSection, day: []const u8, width: ?u16, height: ?u16, quiet: bool, zone: tz.Zone, art: bool, dated: bool) ![]u8 {
    const body = try textWithZoneArt(allocator, sections, day, false, width, height, true, zone, art, dated);
    defer allocator.free(body);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const tag = try tz.zoneTag(allocator, zone);
    defer allocator.free(tag);
    const title = try std.fmt.allocPrint(allocator, "sprts all {s} {s}", .{ day, tag });
    defer allocator.free(title);
    try render.pageHead(w, title);
    try render.writeEscapedBodyH1(w, body);
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/all?date={s}\">all</a>", .{day});
    try w.print("<a href=\"/api/v1/all?date={s}\">json</a>", .{day});
    try render.closePageWithNav(w);
    _ = quiet;
    return out.toOwnedSlice();
}

/// Wrapper with art on (`dated=false`: today view): existing callers keep
/// rendering exactly as before.
pub fn htmlWithZone(allocator: std.mem.Allocator, sections: []const DigestSection, day: []const u8, width: ?u16, height: ?u16, quiet: bool, zone: tz.Zone, dated: bool) ![]u8 {
    return htmlWithZoneArt(allocator, sections, day, width, height, quiet, zone, true, dated);
}

/// ET-default wrapper for `htmlWithZone` (`dated=false`: today view).
pub fn html(allocator: std.mem.Allocator, sections: []const DigestSection, day: []const u8, width: ?u16, height: ?u16, quiet: bool, dated: bool) ![]u8 {
    return htmlWithZone(allocator, sections, day, width, height, quiet, .et, dated);
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
    const output = try text(arena, &sections, "2026-09-06", false, null, 3, false, false);
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
    const output = try text(arena, &sections, "2026-09-06", false, null, null, true, false);
    try std.testing.expect(std.mem.indexOf(u8, output, "+3 more -> /mlb?date=2026-09-06") != null);
    _ = try std.unicode.Utf8View.init(output);
}

test "digest json reuses Scoreboard shapes with stable league set" {
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = null },
    };
    const output = try json(std.testing.allocator, &sections, "2026-09-06");
    defer std.testing.allocator.free(output);
    // Per-league shape is Scoreboard verbatim; the envelope adds only the
    // additive `degraded` outage signal (see DigestJson).
    try std.testing.expect(std.mem.indexOf(u8, output, "\"schema_version\": \"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"league\": \"mlb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"games\": []") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"degraded\": [\n    \"mlb\"\n  ]") != null);
    _ = try std.unicode.Utf8View.init(output);
}

test "digest json distinguishes outage from off-day" {
    // Off-day (present board, zero games) and outage (missing board) look
    // identical per league; only the envelope `degraded` list tells them
    // apart. Parse the wire body and assert the distinction survives.
    const off_day: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "site.api.espn.com",
        .games = &.{},
    };
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = off_day },
        .{ .league = core.leagues.find("nfl").?, .board = null },
    };
    const output = try json(std.testing.allocator, &sections, "2026-09-06");
    defer std.testing.allocator.free(output);
    const parsed = try std.json.parseFromSlice(DigestJson, std.testing.allocator, output, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("2026-09-06", parsed.value.date);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.leagues.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.leagues[0].games.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.leagues[1].games.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.degraded.len);
    try std.testing.expectEqualStrings("nfl", parsed.value.degraded[0]);
    _ = try std.unicode.Utf8View.init(output);
}

test "digest json omits degraded when every league answers" {
    const board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "site.api.espn.com",
        .games = &.{},
    };
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = board },
    };
    const output = try json(std.testing.allocator, &sections, "2026-09-06");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"degraded\": []") != null);
    _ = try std.unicode.Utf8View.init(output);
}

test "digest html links and never carries ANSI" {
    var html_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer html_arena_state.deinit();
    const html_arena = html_arena_state.allocator();
    const html_sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = null },
    };
    const page = try html(html_arena, &html_sections, "2026-09-06", null, null, false, false);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<h1 id=\"content\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Skip to content") != null);
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
    const colored = try text(arena, &sections, "2026-09-06", true, null, null, true, false);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
    const plain = try text(arena, &sections, "2026-09-06", false, null, null, true, false);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    const stripped = try stripAnsi(arena, colored);
    try std.testing.expectEqualStrings(plain, stripped);
    _ = try std.unicode.Utf8View.init(plain);
}

fn containsBraille(s: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == 0xE2 and s[i + 1] >= 0xA0 and s[i + 1] <= 0xA3) return true;
    }
    return false;
}

test "digest art off strips section marks, keeps sections and pointers" {
    // The digest concatenates scoreboard sections, so its marks strip
    // through the same flag (PHI vs NYM ships real marks: precondition).
    try std.testing.expect(core.art.teamArt("mlb", "PHI", .xs) != null);
    const board: core.domain.Scoreboard = .{
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
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = board },
        .{ .league = core.leagues.find("nfl").?, .board = null },
    };
    const on = try textWithZone(std.testing.allocator, &sections, "2026-09-06", false, null, null, false, .et, false);
    defer std.testing.allocator.free(on);
    try std.testing.expect(containsBraille(on));
    const off = try textWithZoneArt(std.testing.allocator, &sections, "2026-09-06", false, null, null, false, .et, false, false);
    defer std.testing.allocator.free(off);
    try std.testing.expect(!containsBraille(off));
    _ = try std.unicode.Utf8View.init(off);
    // Sections, cap pointers, and outage markers survive the strip.
    for ([_][]const u8{ "sprts all", "Final", "PHI", "NYM", "/nfl?date=2026-09-06: unavailable", "more: /<league>?date=<day>" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, off, token) != null);
    }
    // HTML derives from the same art-off body: no marks, no escapes.
    const page = try htmlWithZoneArt(std.testing.allocator, &sections, "2026-09-06", null, null, false, .et, false, false);
    defer std.testing.allocator.free(page);
    try std.testing.expect(!containsBraille(page));
    try std.testing.expect(std.mem.indexOf(u8, page, "rgb(") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "PHI") != null);
    _ = try std.unicode.Utf8View.init(page);
}

test "dated digest skips off-day leagues, keeps outage markers" {
    // Mixed past-day digest: MLB played, NFL answered empty (off-day),
    // NBA failed to answer (outage). The dated view reads like the home
    // summary — only leagues/games that happened — while the outage stays
    // visible as a degraded marker (the `degraded` concept: null board).
    const arena = std.testing.allocator;
    const mlb_board: core.domain.Scoreboard = .{
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
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false, .record = "77-70" },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true, .record = "89-58" },
                },
            },
        },
    };
    const nfl_board: core.domain.Scoreboard = .{
        .league = "nfl",
        .league_name = "NFL",
        .date = "2025-09-10",
        .source = "test",
        .games = &.{},
    };
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = mlb_board },
        .{ .league = core.leagues.find("nfl").?, .board = nfl_board },
        .{ .league = core.leagues.find("nba").? },
    };
    const dated = try text(arena, &sections, "2025-09-10", false, null, null, false, true);
    defer arena.free(dated);
    // The game that happened renders whole: status, records, pointers.
    for ([_][]const u8{ "MLB", "Final", "AWY", "HME", "(77-70)", "(89-58)", "more: /<league>?date=<day>" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, dated, token) != null);
    }
    // Off-day league vanishes entirely: no section, no noise line.
    try std.testing.expect(std.mem.indexOf(u8, dated, "NFL") == null);
    try std.testing.expect(std.mem.indexOf(u8, dated, "No games scheduled") == null);
    // Failed league keeps its degraded marker (not a silent drop).
    try std.testing.expect(std.mem.indexOf(u8, dated, "/nba?date=2025-09-10: unavailable") != null);
    _ = try std.unicode.Utf8View.init(dated);
    // Today view of the same sections is unchanged: the off-day league
    // still renders its (noisy but long-standing) empty section.
    const today = try text(arena, &sections, "2025-09-10", false, null, null, false, false);
    defer arena.free(today);
    try std.testing.expect(std.mem.indexOf(u8, today, "NFL  2025-09-10 ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, today, "No games scheduled.") != null);
    try std.testing.expect(std.mem.indexOf(u8, today, "/nba?date=2025-09-10: unavailable") != null);
}

test "dated digest matches today render when every league played" {
    // Byte-parity lock: with no empty and no failed sections the dated
    // flag selects nothing, so a past view renders exactly like today —
    // same sections, same colors, same marks, same links (text + HTML).
    const arena = std.testing.allocator;
    const mlb_board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2025-09-10",
        .source = "test",
        .games = &.{
            .{
                .id = "9",
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
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = mlb_board },
    };
    const dated_text = try text(arena, &sections, "2025-09-10", true, null, null, false, true);
    defer arena.free(dated_text);
    const today_text = try text(arena, &sections, "2025-09-10", true, null, null, false, false);
    defer arena.free(today_text);
    try std.testing.expectEqualStrings(today_text, dated_text);
    // Colors and marks survive the past view (winner green, braille art).
    try std.testing.expect(std.mem.indexOf(u8, dated_text, "\x1b[") != null);
    try std.testing.expect(containsBraille(dated_text));
    const dated_html = try html(arena, &sections, "2025-09-10", null, null, false, true);
    defer arena.free(dated_html);
    const today_html = try html(arena, &sections, "2025-09-10", null, null, false, false);
    defer arena.free(today_html);
    try std.testing.expectEqualStrings(today_html, dated_html);
    try std.testing.expect(std.mem.indexOf(u8, dated_html, "PHI") != null);
    try std.testing.expect(std.mem.indexOf(u8, dated_html, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(dated_text);
    _ = try std.unicode.Utf8View.init(dated_html);
}

test "digest hostile fixture keeps text and HTML visible text equal" {
    // Phase 5 lock: digest sections ride `render.text` (which composes
    // every row through the shared `view` composers), so hostile
    // provider text must read identically in the digest text body and
    // the HTML page's visible `<pre>` text — cap pointer, outage
    // marker, and all. Seven games also pins the `+2 more` pointer
    // through the escape round-trip (`>` becomes `&gt;` and back).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const games = try arena.alloc(core.domain.Game, 7);
    for (games, 0..) |*game, i| {
        game.* = .{
            .id = try std.fmt.allocPrint(arena, "{d}", .{i}),
            .name = "Away <b>&\"quoted\"</b> at Home",
            .starts_at = "2026-09-06T17:00Z",
            .state = if (i == 0) "in" else "post",
            .status = if (i == 0) "Top 7th <live>" else "Final <OT> & \"extra\"",
            .participants = &.{
                .{ .id = "a", .name = "Atlético Madrid Club de Fútbol with an extremely long tail that never ends", .abbreviation = "AWY", .score = "2", .winner = false, .record = "69-74" },
                .{ .id = "h", .name = "Home\tTeam 漢字", .abbreviation = "HME", .score = "5", .winner = true, .record = "80-63" },
            },
        };
    }
    const board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = games,
    };
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = board },
        .{ .league = core.leagues.find("nfl").?, .board = null },
    };
    // Quiet text body: the same flags the HTML page escapes.
    const body = try text(arena, &sections, "2026-09-06", false, null, null, true, false);
    try std.testing.expect(std.mem.indexOf(u8, body, "+2 more -> /mlb?date=2026-09-06") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/nfl?date=2026-09-06: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(body);
    const page = try html(arena, &sections, "2026-09-06", null, null, false, false);
    try std.testing.expect(std.mem.indexOf(u8, page, "Final &lt;OT&gt; &amp; &quot;extra&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<OT>") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
    // Visible `<pre>` text (tags stripped, entities decoded) matches
    // the text body line for line.
    const seen = try view.expectVisibleParity(arena, page);
    defer arena.free(seen);
    try std.testing.expectEqualStrings(body, seen);
}
