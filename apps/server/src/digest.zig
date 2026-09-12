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
const table = @import("table.zig");
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
///
/// When `dated` the sections stop concatenating scoreboard cards and reuse
/// the home recap shape instead (see `datedText`): same row composer,
/// same widths, same heading/nav spelling as the dated home, so a past
/// `/all?date=` reads as the same exact recap view.
///
/// Delegate, not a 302 to `/?date=`: the redirect is byte-identical for
/// text/HTML/?0 but drops dated digest JSON — `/api/v1/all?date=` carries
/// per-day scoreboards plus the `degraded` outage list (see `DigestJson`),
/// while `/?date=` and `/api/v1/` serve the bare league list (see
/// `render.leaguesJson`), so JSON clients would lose every score. The
/// delegate keeps all three formats on one route with no extra hop.
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
    // Dated past view delegates to the home-shaped composer (rows, widths,
    // heading, and nav all match the dated home); `width`/`art` are no-ops
    // there (home is fixed 50 columns and never carries marks).
    if (dated) return datedText(allocator, sections, day, color, per_league, quiet, zone);
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

/// Dated digest text: the explicit-`?date` past view reads as the same
/// recap as the dated home. Section bodies delegate to the home row
/// composer (`view.homeGameLine` over page-wide `view.homeColumnWidths`,
/// emitted with `view.statusAnsi` like the home emitter), so rows carry no
/// marks, no TV lines, no records, and no `game:` pointers — whatever the
/// board mix, even all-final past boards that already took the compact
/// branch. The heading and top nav use the home spelling (`sprts  {day}
/// {zone}`, `/all?date=` prev/next plus the separator), so the per-league
/// `/{slug}?date=` footers vanish with the scoreboard cards.
///
/// Intentional differences from the dated home (kept, not drift):
/// - one bounded section per league in digest order with the `+N more`
///   pointer (the digest display bound; home shows every game and regroups
///   live games under `LIVE NOW`, which the digest never emits);
/// - null boards keep the `/<slug>?date=<day>: unavailable` degraded
///   marker inline instead of home's `ALL LEAGUES` idle regrouping (the
///   outage signal; off-day empties are still skipped entirely);
/// - the footer stays `more: /<league>?date=<day>`: the digest signature
///   carries no host, so home's `Try:/Docs:/Code:` footer cannot render;
/// - no wordmark banner (the `/` home chrome above its heading).
fn datedText(
    allocator: std.mem.Allocator,
    sections: []const DigestSection,
    day: []const u8,
    color: bool,
    per_league: u16,
    quiet: bool,
    zone: tz.Zone,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    if (!quiet) {
        const tag = try tz.zoneTag(allocator, zone);
        defer allocator.free(tag);
        // Home heading spelling (`sprts  {day} {zone}`), same dim gating.
        const heading = try std.fmt.allocPrint(allocator, "sprts  {s} {s}", .{ day, tag });
        defer allocator.free(heading);
        if (color) try w.print("\x1b[2m{s}\x1b[0m\n", .{heading}) else try w.print("{s}\n", .{heading});
    }
    // Date nav sits directly under the heading (and tops quiet mode, which
    // drops the heading): the home spelling, unconditional like home's.
    if (try datedNavDates(allocator, day)) |nav| {
        defer allocator.free(nav.prev);
        defer allocator.free(nav.next);
        try w.print("/all?date={s}    /all?date={s}\n", .{ nav.prev, nav.next });
    }
    try table.writeSeparator(w, 50);
    // Page-wide widths like the home page so rows align down the whole
    // digest exactly as they do down the home.
    const widths = view.homeColumnWidths(DigestSection, sections);
    var emitted = false;
    for (sections) |section| {
        const board = section.board orelse {
            const marker = try view.digestUnavailable(allocator, section.league.slug, day);
            defer allocator.free(marker);
            try w.print("{s}\n", .{marker});
            emitted = true;
            continue;
        };
        // Answered-but-empty is an off-day: skip the section entirely.
        if (board.games.len == 0) continue;
        const capped = @min(per_league, board.games.len);
        if (emitted) try w.writeByte('\n');
        emitted = true;
        const header = try view.homeLeagueHeader(allocator, section.league.name, day);
        defer allocator.free(header);
        try table.writeLine(w, header, 50, "2", color);
        for (board.games[0..capped]) |game| {
            // Nothing to show falls back to no row, like the home emitter.
            const line = try view.homeGameLine(allocator, section.league, game, widths.slug_w, widths.abbr_w) orelse continue;
            defer allocator.free(line);
            try table.writeLine(w, line, 50, view.statusAnsi(game.state), color);
        }
        if (capped < board.games.len) {
            try w.print("+{d} more -> /{s}?date={s}\n", .{ board.games.len - capped, board.league, day });
        }
    }
    // Blank air before the footer, like the home page.
    try w.writeByte('\n');
    if (!quiet) try w.writeAll("more: /<league>?date=<day>\n");
    return out.toOwnedSlice();
}

/// Prev/next dates for a dated digest day, via the same `core.date.shift`
/// the scoreboard footer and the home nav use. Null unless `day` is a
/// strict calendar date: serve paths resolve relative tokens first, so
/// renderers see strict days in practice; hostile text renders no nav
/// instead of failing the page (the home `homeNavDates` precedent).
fn datedNavDates(allocator: std.mem.Allocator, day: []const u8) !?struct { prev: []u8, next: []u8 } {
    if (!core.date.validate(day)) return null;
    const prev = try core.date.shift(allocator, day, -1);
    errdefer allocator.free(prev);
    const next = try core.date.shift(allocator, day, 1);
    return .{ .prev = prev, .next = next };
}

/// Per-league dated link for digest HTML headers: `/{slug}?date={day}`,
/// the home league-href spelling (the home helper is private to render,
/// so the one line is repeated here instead of drifting).
fn datedLeagueHref(allocator: std.mem.Allocator, slug: []const u8, day: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/{s}?date={s}", .{ slug, day });
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
///
/// Game and team hrefs ride the shared scoreboard linkifier
/// (`render.writeLinkedScoreboard`, one call per league section with that
/// section's board slice), so every status cell links its game view and
/// every abbreviation links its team page — same anchors, same
/// scoped-underline CSS (padding outside anchors), same empty-abbr guard
/// as scoreboards. Digest-level lines (outage markers, `+N more`
/// pointers) escape as plain text; only invisible tags are added, so the
/// `<pre>` visible text matches the quiet text digest byte for byte.
///
/// When `dated` the page reuses the home recap shape instead (see
/// `datedHtml`): section bodies link like the home rows (sibling game +
/// team anchors, live/upcoming spans, no `id="game-"` anchors, no art
/// spans), and the title/nav use the home spelling — so a past
/// `/all?date=` reads as the same exact recap view as the dated home.
pub fn htmlWithZoneArt(allocator: std.mem.Allocator, sections: []const DigestSection, day: []const u8, width: ?u16, height: ?u16, quiet: bool, zone: tz.Zone, art: bool, dated: bool) ![]u8 {
    const per_league = height orelse default_games_per_league;
    // Dated past view delegates to the home-shaped composer (rows, links,
    // title, and nav all match the dated home); `width`/`zone`/`art` are
    // no-ops there (home HTML is fixed 50 columns, carries no zone in its
    // title, and never renders marks).
    if (dated) return datedHtml(allocator, sections, day, per_league);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const tag = try tz.zoneTag(allocator, zone);
    defer allocator.free(tag);
    const title = try std.fmt.allocPrint(allocator, "sprts all {s} {s}", .{ day, tag });
    defer allocator.free(title);
    try render.pageHead(w, title);
    const inner: usize = @min(@max(width orelse 52, 52), 200) - 2;
    // First emitted content line doubles as the page `<h1>` title (the
    // skip link's `#content` target), mirroring `writeEscapedBodyH1`;
    // later section headings render plain so the page keeps one `<h1>`.
    var h1_done = false;
    for (sections) |section| {
        const board = section.board orelse {
            const marker = try view.digestUnavailable(allocator, section.league.slug, day);
            defer allocator.free(marker);
            if (!h1_done) {
                try w.writeAll(render.h1_open);
                try render.escapeInto(w, marker);
                try w.writeAll("</h1>\n");
                h1_done = true;
            } else {
                try render.escapeInto(w, marker);
                try w.writeByte('\n');
            }
            continue;
        };
        // Dated past view: an answered-but-empty board is an off-day —
        // skip the section entirely, exactly like `textWithZoneArt`.
        if (dated and board.games.len == 0) continue;
        const capped = @min(per_league, board.games.len);
        const slice: core.domain.Scoreboard = .{
            .league = board.league,
            .league_name = board.league_name,
            .date = board.date,
            .source = board.source,
            .games = board.games[0..capped],
        };
        // Same bodies the text digest concatenates (uncolored mono plus
        // the color twin only when a shown mark needs it), through the
        // shared linkifier — never a second one.
        const body = try render.textWithZoneArt(allocator, slice, false, width, null, zone, art);
        defer allocator.free(body);
        var color_owned: ?[]u8 = null;
        defer if (color_owned) |b| allocator.free(b);
        if (art and render.boardHasColorArt(slice, capped)) {
            color_owned = try render.textWithZoneArt(allocator, slice, true, width, null, zone, art);
        }
        const color_body = color_owned orelse body;
        try render.writeLinkedScoreboard(w, allocator, slice, body, color_body, inner, capped, !h1_done);
        h1_done = true;
        if (capped < board.games.len) {
            const pointer = try std.fmt.allocPrint(allocator, "+{d} more -> /{s}?date={s}", .{ board.games.len - capped, board.league, day });
            defer allocator.free(pointer);
            try render.escapeInto(w, pointer);
            try w.writeByte('\n');
        }
    }
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

/// Dated digest HTML: the explicit-`?date` past view links like the dated
/// home. Game rows split into sibling anchors — every non-team chunk links
/// the game view, each participant abbreviation links its team page — with
/// the live/upcoming color span wrapping the siblings, exactly the home
/// link shape (see `writeDatedHomeGameCell`). No `id="game-"` anchors (the
/// scoreboard linkifier's shape; home has none), no art rows, so no
/// braille, `rgb(`, or ANSI bytes reach the page by construction. Headers
/// link their league page with the dim span, like home headers. The title
/// and top nav use the home spelling (`sprts  {day}`, `/all?date=`
/// prev/next twins).
///
/// The `<pre>` visible text matches the quiet dated text digest byte for
/// byte (same lines, same order, including the top separator and the
/// blank air): the separator rides as plain text — `─` needs no escaping
/// — and only invisible tags are added. Intentional differences from the
/// dated home HTML (kept, not drift): per-league digest order with the
/// `+N more` pointer (no `LIVE NOW` regrouping, no `ALL LEAGUES` block —
/// outage markers stay inline), and the digest `all`/`json` nav (the
/// digest route identity; the host-dependent home footer text cannot
/// render without a host in the digest signature).
fn datedHtml(
    allocator: std.mem.Allocator,
    sections: []const DigestSection,
    day: []const u8,
    per_league: u16,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const title = try std.fmt.allocPrint(allocator, "sprts  {s}", .{day});
    defer allocator.free(title);
    try render.pageHead(w, title);
    // HTML twin of the dated text nav: byte-identical visible text, each
    // half its own link (the home nav-HTML shape).
    if (try datedNavDates(allocator, day)) |nav| {
        defer allocator.free(nav.prev);
        defer allocator.free(nav.next);
        const prev_href = try std.fmt.allocPrint(allocator, "/all?date={s}", .{nav.prev});
        defer allocator.free(prev_href);
        const next_href = try std.fmt.allocPrint(allocator, "/all?date={s}", .{nav.next});
        defer allocator.free(next_href);
        try w.writeAll("<a href=\"");
        try render.escapeInto(w, prev_href);
        try w.writeAll("\">");
        try render.escapeInto(w, prev_href);
        try w.writeAll("</a>    <a href=\"");
        try render.escapeInto(w, next_href);
        try w.writeAll("\">");
        try render.escapeInto(w, next_href);
        try w.writeAll("</a>\n");
    }
    // The top separator rides as plain text so the `<pre>` visible text
    // stays byte-identical to the quiet dated text digest (which prints
    // the same separator line under its nav).
    {
        var sep_buf: std.Io.Writer.Allocating = .init(allocator);
        defer sep_buf.deinit();
        try table.writeSeparator(&sep_buf.writer, 50);
        const sep = try sep_buf.toOwnedSlice();
        defer allocator.free(sep);
        try render.escapeInto(w, std.mem.trimEnd(u8, sep, "\n"));
        try w.writeByte('\n');
    }
    // Sections render aside, then the first row becomes the page `<h1>`
    // title (the home-HTML shape): tags strip clean, so visible text and
    // layout never change.
    {
        var sec: std.Io.Writer.Allocating = .init(allocator);
        defer sec.deinit();
        const widths = view.homeColumnWidths(DigestSection, sections);
        var emitted = false;
        for (sections) |section| {
            const board = section.board orelse {
                const marker = try view.digestUnavailable(allocator, section.league.slug, day);
                defer allocator.free(marker);
                try render.escapeInto(&sec.writer, marker);
                try sec.writer.writeByte('\n');
                emitted = true;
                continue;
            };
            if (board.games.len == 0) continue;
            const capped = @min(per_league, board.games.len);
            if (emitted) try sec.writer.writeByte('\n');
            emitted = true;
            const header = try view.homeLeagueHeader(allocator, section.league.name, day);
            defer allocator.free(header);
            const href = try datedLeagueHref(allocator, section.league.slug, day);
            defer allocator.free(href);
            try render.writeHtmlLine(&sec.writer, allocator, header, 50, "dim", href);
            for (board.games[0..capped]) |game| {
                const line = try view.homeGameLine(allocator, section.league, game, widths.slug_w, widths.abbr_w) orelse continue;
                defer allocator.free(line);
                const game_href = try core.domain.gameHref(allocator, section.league.slug, board.date, game);
                defer allocator.free(game_href);
                try writeDatedHomeGameCell(allocator, line, section.league, game, &sec.writer, game_href);
                try sec.writer.writeByte('\n');
            }
            if (capped < board.games.len) {
                const pointer = try std.fmt.allocPrint(allocator, "+{d} more -> /{s}?date={s}", .{ board.games.len - capped, board.league, day });
                defer allocator.free(pointer);
                try render.escapeInto(&sec.writer, pointer);
                try sec.writer.writeByte('\n');
            }
        }
        const rendered = try sec.toOwnedSlice();
        defer allocator.free(rendered);
        try writeDatedH1FirstLine(w, rendered);
    }
    // Blank air matching the quiet dated text digest (which prints one
    // before its footer), so visible-text parity holds line for line.
    try w.writeByte('\n');
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/all?date={s}\">all</a>", .{day});
    try w.print("<a href=\"/api/v1/all?date={s}\">json</a>", .{day});
    try render.closePageWithNav(w);
    return out.toOwnedSlice();
}

/// Dated digest game cell: the home link shape. The fitted row splits into
/// sibling anchors — every non-team chunk links the game view, each
/// participant abbreviation wraps in a team link — with the live/upcoming
/// color span around the siblings (a span containing anchors is valid
/// HTML). Only non-empty abbreviations link: nameless bouts emit a single
/// game link, so rows stay valid either way. Abbreviations match
/// positionally (away first, then home) so a truncated name can never
/// steal another team's link. Unmatched tails (scores, status) ride the
/// trailing game link. The line is ragged (fitted, trailing blanks
/// trimmed); stripping tags concatenates back to the same line, so visible
/// text matches the dated text digest byte for byte. Padding reuses
/// `table.writeCell` so the frame aligns with the text renderer.
fn writeDatedHomeGameCell(allocator: std.mem.Allocator, line: []const u8, league: *const core.leagues.League, game: core.domain.Game, w: *std.Io.Writer, game_href: []const u8) !void {
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
        for ([2]core.domain.Participant{ away, home_team }) |part| {
            if (part.abbreviation.len == 0) continue;
            if (std.mem.indexOf(u8, content[cursor..], part.abbreviation)) |rel| {
                const at = cursor + rel;
                if (at > cursor) {
                    try w.writeAll("<a href=\"");
                    try render.escapeInto(w, game_href);
                    try w.writeAll("\">");
                    try render.escapeInto(w, content[cursor..at]);
                    try w.writeAll("</a>");
                }
                const team_href = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ league.slug, part.abbreviation });
                defer allocator.free(team_href);
                try w.writeAll("<a href=\"");
                try render.escapeInto(w, team_href);
                try w.writeAll("\">");
                try render.escapeInto(w, part.abbreviation);
                try w.writeAll("</a>");
                cursor = at + part.abbreviation.len;
            }
        }
    }
    if (content[cursor..].len > 0) {
        try w.writeAll("<a href=\"");
        try render.escapeInto(w, game_href);
        try w.writeAll("\">");
        try render.escapeInto(w, content[cursor..]);
        try w.writeAll("</a>");
    }
    if (css != null) try w.writeAll("</span>");
}

/// Wrap the first line of an already-rendered dated digest block as the
/// page `<h1>` title; remaining bytes pass through untouched. The home
/// shape (the live home wraps its first section row the same way): tags
/// strip clean, so visible text never changes.
fn writeDatedH1FirstLine(w: *std.Io.Writer, rendered: []const u8) !void {
    if (std.mem.indexOfScalar(u8, rendered, '\n')) |nl| {
        if (nl == 0) {
            try w.writeAll(rendered);
            return;
        }
        try w.writeAll(render.h1_open);
        try w.writeAll(rendered[0..nl]);
        try w.writeAll("</h1>\n");
        try w.writeAll(rendered[nl + 1 ..]);
    } else if (rendered.len > 0) {
        try w.writeAll(render.h1_open);
        try w.writeAll(rendered);
        try w.writeAll("</h1>");
    }
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
            // Scheduled tail keeps the board mixed so the section renders
            // its rich card (an all-final board goes compact).
            .{
                .id = "10",
                .name = "AWY at HME",
                .starts_at = "2026-09-06T23:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "3", .name = "Away", .abbreviation = "AWY", .score = "", .winner = false },
                    .{ .id = "4", .name = "Home", .abbreviation = "HME", .score = "", .winner = false },
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
            // Scheduled tail keeps the board mixed so the section renders
            // its rich card (an all-final board goes compact).
            .{
                .id = "2",
                .name = "Later",
                .starts_at = "2025-09-10T23:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "x", .name = "Later Away", .abbreviation = "LAW", .score = "", .winner = false },
                    .{ .id = "y", .name = "Later Home", .abbreviation = "LHM", .score = "", .winner = false },
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
    // The dated view reads like the dated home: home heading/nav spelling,
    // home section header, home rows for the games that happened.
    for ([_][]const u8{ "sprts  2025-09-10 ET", "/all?date=2025-09-09    /all?date=2025-09-11", "MLB  09-10", "Final", "AWY", "HME", "Scheduled", "more: /<league>?date=<day>" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, dated, token) != null);
    }
    // Home rows carry no records, no pointers, no scoreboard chrome.
    for ([_][]const u8{ "(77-70)", "(89-58)", "game:", "sprts all", "MLB  2025-09-10 ET" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, dated, token) == null);
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

test "dated digest matches dated home rows, not scoreboard cards" {
    // Row-equality lock: the dated digest delegates its section bodies to
    // the home row composer, so every dated-home section line (nav,
    // headers, rows) reads byte-identical in the dated digest. Same
    // fixture day through both renderers; widths agree because both use
    // page-wide `view.homeColumnWidths` over the same boards.
    const provider = @import("provider.zig");
    const arena = std.testing.allocator;
    const day = "2025-09-10";
    const mlb_board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = day,
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
                    .{ .id = "1", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = true, .record = "83-61", .home_away = "away" },
                    .{ .id = "2", .name = "New York Mets", .abbreviation = "NYM", .score = "3", .winner = false, .record = "74-70", .home_away = "home" },
                },
            },
            .{
                .id = "10",
                .slug = "awy-hme",
                .name = "Away at Home",
                .starts_at = "2025-09-10T19:00Z",
                .state = "in",
                .status = "Top 7th",
                .participants = &.{
                    .{ .id = "3", .name = "Away", .abbreviation = "AWY", .score = "0", .winner = false, .home_away = "away" },
                    .{ .id = "4", .name = "Home", .abbreviation = "HME", .score = "3", .winner = false, .home_away = "home" },
                },
            },
            .{
                .id = "11",
                .slug = "law-lhm",
                .name = "Later",
                .starts_at = "2025-09-10T23:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "5", .name = "Later Away", .abbreviation = "LAW", .score = "", .winner = false, .home_away = "away" },
                    .{ .id = "6", .name = "Later Home", .abbreviation = "LHM", .score = "", .winner = false, .home_away = "home" },
                },
            },
        },
    };
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = mlb_board },
    };
    var results = [_]provider.LeagueResult{
        .{ .league = core.leagues.find("mlb").?, .board = mlb_board },
    };
    // Same boards, same page-wide geometry on both sides.
    const home_widths = view.homeColumnWidths(provider.LeagueResult, &results);
    const digest_widths = view.homeColumnWidths(DigestSection, &sections);
    try std.testing.expectEqual(home_widths.slug_w, digest_widths.slug_w);
    try std.testing.expectEqual(home_widths.abbr_w, digest_widths.abbr_w);
    const home_text = try render.homeLive(arena, false, "example.test", &results, day, false, true);
    defer arena.free(home_text);
    const dated_text = try text(arena, &sections, day, false, null, null, false, true);
    defer arena.free(dated_text);
    // Heading, nav, headers, and every game row match the dated home.
    try std.testing.expect(std.mem.indexOf(u8, dated_text, "sprts  2025-09-10 ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, dated_text, "/all?date=2025-09-09    /all?date=2025-09-11") != null);
    var home_lines = std.mem.splitScalar(u8, home_text, '\n');
    while (home_lines.next()) |line| {
        if (line.len == 0) continue;
        // Section chrome and rows only: banner, heading, LIVE regrouping,
        // and the host footer are home-only by contract (see `datedText`).
        // Rows start with the slug cell, so the footer (`Try: curl
        // example.test/mlb`) never matches the row prefix.
        if (std.mem.startsWith(u8, line, "mlb ") or
            std.mem.indexOf(u8, line, "MLB") != null or
            std.mem.startsWith(u8, line, "/all?date"))
        {
            try std.testing.expect(std.mem.indexOf(u8, dated_text, line) != null);
        }
    }
    // The digest keeps per-league order instead of home's `LIVE NOW`
    // regrouping: rows are identical, grouping differs when live games
    // are present (past recap days are usually all-final, so no gap).
    try std.testing.expect(std.mem.indexOf(u8, home_text, "LIVE NOW") != null);
    try std.testing.expect(std.mem.indexOf(u8, dated_text, "LIVE NOW") == null);
    // Scoreboard chrome is gone: full-date section headings, pointers,
    // records, TV lines, and the digest's own old heading.
    for ([_][]const u8{ "MLB  2025-09-10 ET", "game:", "(83-61)", "(74-70)", "TV:", "sprts all" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, dated_text, token) == null);
    }
    _ = try std.unicode.Utf8View.init(dated_text);
}

test "dated digest html reuses home links without scoreboard anchors" {
    // Link-shape lock: dated digest rows link like home rows (sibling game
    // + team anchors with live/upcoming spans), never like scoreboard rows
    // (`id="game-"` anchors, no spans). Same fixture as the text
    // row-equality test so rows and links cover the same games.
    const provider = @import("provider.zig");
    const arena = std.testing.allocator;
    const day = "2025-09-10";
    const mlb_board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = day,
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
                    .{ .id = "1", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = true, .record = "83-61", .home_away = "away" },
                    .{ .id = "2", .name = "New York Mets", .abbreviation = "NYM", .score = "3", .winner = false, .record = "74-70", .home_away = "home" },
                },
            },
            .{
                .id = "10",
                .slug = "awy-hme",
                .name = "Away at Home",
                .starts_at = "2025-09-10T19:00Z",
                .state = "in",
                .status = "Top 7th",
                .participants = &.{
                    .{ .id = "3", .name = "Away", .abbreviation = "AWY", .score = "0", .winner = false, .home_away = "away" },
                    .{ .id = "4", .name = "Home", .abbreviation = "HME", .score = "3", .winner = false, .home_away = "home" },
                },
            },
            .{
                .id = "11",
                .slug = "law-lhm",
                .name = "Later",
                .starts_at = "2025-09-10T23:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "5", .name = "Later Away", .abbreviation = "LAW", .score = "", .winner = false, .home_away = "away" },
                    .{ .id = "6", .name = "Later Home", .abbreviation = "LHM", .score = "", .winner = false, .home_away = "home" },
                },
            },
        },
    };
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("mlb").?, .board = mlb_board },
    };
    var results = [_]provider.LeagueResult{
        .{ .league = core.leagues.find("mlb").?, .board = mlb_board },
    };
    const page = try html(arena, &sections, day, null, null, false, true);
    defer arena.free(page);
    const home_page = try render.homeHtmlLive(arena, "example.test", &results, day, false, true);
    defer arena.free(home_page);
    // Scoreboard anchor shape is gone; team links ride every row.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"game-") == null);
    for ([_][]const u8{
        "<a href=\"/mlb/PHI\">PHI</a>",
        "<a href=\"/mlb/NYM\">NYM</a>",
        "<a href=\"/mlb/AWY\">AWY</a>",
        "<a href=\"/mlb/HME\">HME</a>",
        "<a href=\"/mlb/LAW\">LAW</a>",
        "<a href=\"/mlb/LHM\">LHM</a>",
    }) |team_link| {
        try std.testing.expect(std.mem.indexOf(u8, page, team_link) != null);
        try std.testing.expect(std.mem.indexOf(u8, home_page, team_link) != null);
    }
    // Raw game hrefs (human slugs) survive verbatim on both pages.
    for ([_][]const u8{
        "/mlb/2025-09-10/phi-nym",
        "/mlb/2025-09-10/awy-hme",
        "/mlb/2025-09-10/law-lhm",
    }) |game_href| {
        try std.testing.expect(std.mem.indexOf(u8, page, game_href) != null);
        try std.testing.expect(std.mem.indexOf(u8, home_page, game_href) != null);
    }
    // Span styles match home: live/upcoming on rows, dim on headers, and
    // no art spans anywhere (no logos in dated views by construction).
    for ([_][]const u8{ "class=\"live\"", "class=\"upcoming\"", "class=\"dim\"" }) |span| {
        try std.testing.expect(std.mem.indexOf(u8, page, span) != null);
        try std.testing.expect(std.mem.indexOf(u8, home_page, span) != null);
    }
    try std.testing.expect(!containsBraille(page));
    try std.testing.expect(std.mem.indexOf(u8, page, "rgb(") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
    // The tags add no visible text: parity with the quiet dated digest.
    const body = try text(arena, &sections, day, false, null, null, true, true);
    defer arena.free(body);
    const seen = try view.expectVisibleParity(arena, page);
    defer arena.free(seen);
    try std.testing.expectEqualStrings(body, seen);
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

test "digest html links every shown game and team like scoreboards" {
    // Seven games pin the default cap at five: the five shown rows carry
    // the shared linkifier's game + team anchors, the two hidden ones
    // carry none, and the `+2 more` pointer escapes as plain text.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const games = try arena.alloc(core.domain.Game, 7);
    for (games, 0..) |*game, i| {
        game.* = .{
            .id = try std.fmt.allocPrint(arena, "{d}", .{i}),
            .slug = try std.fmt.allocPrint(arena, "awy-hme-{d}", .{i}),
            .name = "Away at Home",
            .starts_at = "2026-09-06T17:00Z",
            // Scheduled lead keeps the shown slice mixed so it renders
            // its rich card (an all-final board goes compact). The lead
            // sits inside the cap, so seven games still pin the cap at
            // five and the `+2 more` pointer is unchanged.
            .state = if (i == 0) "pre" else "post",
            .status = if (i == 0) "Scheduled" else "Final",
            .participants = if (i == 0) &.{
                .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "", .winner = false },
                .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "", .winner = false },
            } else &.{
                .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false, .record = "69-74" },
                .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true, .record = "80-63" },
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
    const page = try html(arena, &sections, "2026-09-06", null, null, false, false);
    // Shown rows: status cells link the game view (slug href, numeric
    // anchor id), abbrevs link the team pages — the scoreboard shape.
    for (0..5) |i| {
        const game_anchor = try std.fmt.allocPrint(arena, "<a href=\"/mlb/2026-09-06/awy-hme-{d}\" id=\"game-{d}\">", .{ i, i });
        defer arena.free(game_anchor);
        try std.testing.expect(std.mem.indexOf(u8, page, game_anchor) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/AWY\">AWY</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/HME\">HME</a>") != null);
    // Hidden rows stay unlinked; the cap pointer is plain escaped text.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"game-5\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"game-6\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "+2 more -&gt; /mlb?date=2026-09-06") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "/nfl?date=2026-09-06: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
    // The tags add no visible text: parity with the quiet text digest.
    const body = try text(arena, &sections, "2026-09-06", false, null, null, true, false);
    const seen = try view.expectVisibleParity(arena, page);
    defer arena.free(seen);
    try std.testing.expectEqualStrings(body, seen);
}

test "digest html empty-abbr rows emit no team link" {
    // Athlete-style rows (tennis): no abbreviation, so no team page to
    // point at — the shared linkifier keeps the game anchor alone and
    // never emits a bare `/atp/` href, exactly like scoreboards (see the
    // `team: /atp/` guard precedent in `render.zig`).
    const board: core.domain.Scoreboard = .{
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
    const sections = [_]DigestSection{
        .{ .league = core.leagues.find("atp").?, .board = board },
    };
    const arena = std.testing.allocator;
    const page = try html(arena, &sections, "2026-09-10", null, null, false, false);
    defer arena.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/atp/182772\" id=\"game-182772\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"/atp/\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
    const body = try text(arena, &sections, "2026-09-10", false, null, null, true, false);
    defer arena.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "team: /atp/") == null);
    const seen = try view.expectVisibleParity(arena, page);
    defer arena.free(seen);
    try std.testing.expectEqualStrings(body, seen);
}
