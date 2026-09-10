//! Help page (`/:help`, wttr.in style) plus the scoreboard one-line view.
//!
//! Single owner of all help copy: `renderHelp` serves text (color-,
//! quiet-, and oneline-aware), minimal HTML, and a structured JSON body
//! from the same literals, and `scoreOneLine` is the scoreboard `?0`
//! fallback (one game per line, no box rules). Per-game and per-team
//! one-line shapes belong to the render-stream owners (`detail_view`,
//! `team_view`; home already has `render.homeOneLine`); this module only
//! covers the scoreboard.
//!
//! Wiring is NOT done here: `main.zig`/`worker.zig` own the exhaustive
//! `switch (route)`, so they gain the `.help` arm and the scoreboard
//! `.text` oneline branch (see the report's wiring snippet). Color default
//! (`null` means on; entry points pre-resolve `NO_COLOR` into
//! `route.color` before calling) is documented on `renderHelp`.

const std = @import("std");
const core = @import("sprts_core");
const domain = core.domain;
const router = @import("router.zig");
const render = @import("render.zig");

/// Serve the help page in the negotiated format. Text honors the route's
/// display flags (null color defaults on; callers pre-resolve NO_COLOR);
/// HTML is always plain (browsers cannot use ANSI); JSON is a fixed
/// structured body (display flags do not apply).
pub fn renderHelp(arena: std.mem.Allocator, route: router.HelpRoute, format: router.Format) ![]u8 {
    return switch (format) {
        .text => textHelp(arena, route, route.color orelse true),
        .html => htmlHelp(arena, route),
        .json => jsonHelp(arena),
    };
}

/// Scoreboard one-line fallback (`?0`): one game per line,
/// `{state} {status} {AWAY} {score} @ {HOME} {score}[ ✓]`, no box rules.
/// Pre-game duels with no scores print `{state} {status} {AWAY} @ {HOME}`;
/// non-duels fall back to the game name. `quiet` drops the heading and the
/// prev/next nav footer. Zero ANSI when `color` is off; an empty board is
/// always exactly `No games scheduled.\n`.
pub fn scoreOneLine(arena: std.mem.Allocator, board: domain.Scoreboard, color: bool, quiet: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    const w = &out.writer;
    if (board.games.len == 0) {
        try w.writeAll("No games scheduled.\n");
        return out.toOwnedSlice();
    }
    if (!quiet) {
        const heading = try std.fmt.allocPrint(arena, "{s}  {s}\n", .{ board.league_name, board.date });
        defer arena.free(heading);
        try colorize(w, "2", heading, color);
    }
    for (board.games) |game| try writeScoreLine(w, game, color);
    if (!quiet) {
        const previous = try core.date.shift(arena, board.date, -1);
        defer arena.free(previous);
        const next = try core.date.shift(arena, board.date, 1);
        defer arena.free(next);
        try w.print("/{s}?date={s}    /{s}?date={s}\n", .{ board.league, previous, board.league, next });
    }
    return out.toOwnedSlice();
}

fn stateColor(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "in")) return "1;31";
    if (std.mem.eql(u8, state, "pre")) return "33";
    return "2";
}

fn writeScoreLine(w: *std.Io.Writer, game: domain.Game, color: bool) !void {
    if (color) try w.print("\x1b[{s}m", .{stateColor(game.state)});
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
    try w.writeByte('\n');
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

fn section(w: *std.Io.Writer, title: []const u8, color: bool) !void {
    try colorize(w, "2", title, color);
    try w.writeByte('\n');
}

fn textHelp(arena: std.mem.Allocator, route: router.HelpRoute, color: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    const w = &out.writer;
    if (route.oneline) {
        try writeCompactHelp(w);
        return out.toOwnedSlice();
    }
    if (!route.quiet) try colorize(w, "2", "sprts — scores in your terminal\n", color);
    try section(w, "ROUTES", color);
    try w.writeAll(
        \\  /                              home: every league today, live first
        \\  /all                           every league one day (same ?date=, ?0)
        \\  /{league}                      scoreboard, e.g. /mlb
        \\  /{league}?date=YYYY-MM-DD      scoreboard for one day
        \\  /{league}?week=N               football week only, ignored elsewhere
        \\  /{league}/{id}                 one game (all digits = game, else team)
        \\  /{league}/{abbr}               one team, e.g. /mlb/phi
        \\  /{league}/{date}/{away}-{home}[-N] game by date+teams, 302, e.g. /mlb/2026-09-09/min-det (-2 = doubleheader game 2; curl -L)
        \\  /{league}/{date}/event[-N] Nth game on the day board, 302, e.g. /ufc/2026-09-05/event-14 (bare event = 1; every game: bouts, sessions, fields, name-only duels; curl -L)
        \\  /{league}/{YYYY}/week{N}/{a}-{h}[-N] football week game, 302, e.g. /nfl/2026/week1/ne-sea (curl -L)
        \\  /{league}/{YYYY}/week{N}/event[-N] Nth game of the football week, 302 (curl -L)
        \\  duel aliases match two team abbreviations only: cards, races, tournaments, name-only duels use event-N (browse the day board for the list)
        \\  /{league}/{abbr}/today        today's game, redirects to it
        \\  /{league}/standings            current table, no date
        \\  /{league}/teams                 team list as JSON (no text twin: picker payload)
        \\  /{league}/tour                  live terminal tour in the browser (xterm.js + SSE, read-only)
        \\  /tour                           all-leagues terminal tour (same player, /all feed)
        \\  /api/v1/leagues                leagues as JSON
        \\  /api/v1/{league}[/{id|abbr}]   same shapes as JSON
        \\  /api/v1/all, .../standings, .../teams  digest, table, and team list as JSON
        \\  /openapi.json                  API spec
        \\  /docs                          human API reference
        \\  /llms.txt                      agent API guide, plain text
        \\  /healthz                       ok
        \\  /:help, /help                  this page (also /{league}/:help)
        \\
    );
    try section(w, "FLAGS (every human route; JSON ignores display flags)", color);
    try w.writeAll(
        \\  color=0|1  width=N (52..200)  height=N (max games)
        \\  quiet=0|1 (no header/footer)  oneline=0|1 (?0, text only)  format=text|html
        \\  date=YYYY-MM-DD|today|tomorrow|yesterday, default today in ET (scoreboard, all)  week=N (football only)
        \\  stream=sse (scoreboard text only, curl -N)  tz=utc (default et)
        \\  art=off strips team-mark art (tofu terminals); anything else art on
        \\
    );
    try section(w, "ALIASES (combined ?0pq or split ?0&q; unknown letters ignored)", color);
    try w.writeAll(
        \\  T=color=0  A=color=1  q=quiet  0=oneline
        \\  long flags win (?color=1&T is color on); later alias wins (?T&A is on)
        \\
    );
    try section(w, "LINKS", color);
    try w.writeAll(
        \\  text rows print game:/team: links; HTML makes them clickable
        \\  boards end with prev/next ?date= links
        \\
    );
    try section(w, "LEAGUES", color);
    try w.writeAll("  ");
    for (core.leagues.all, 0..) |league, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(league.slug);
    }
    try w.writeAll("\n");
    try section(w, "SOURCES", color);
    try w.writeAll(
        \\  live scores: ESPN scoreboard (site.api.espn.com)
        \\  NFL offseason/history: nflverse games.csv snapshot (CC-BY-4.0, github.com/nflverse/nflverse-data), refreshed daily in-season, not live
        \\  every board names its source; snapshot boards are never live and never carry betting odds
        \\
    );
    try section(w, "INSTALL", color);
    try w.writeAll("  install -m755 tools/sprts ~/.local/bin/sprts\n");
    try section(w, "EXAMPLES", color);
    try w.writeAll(
        \\  curl localhost:8080/mlb
        \\  curl 'localhost:8080/mlb?date=2026-09-06'
        \\  curl 'localhost:8080/mlb/401816828?0'
        \\  curl -L localhost:8080/mlb/2026-09-09/min-det
        \\  curl -L localhost:8080/mlb/2026-09-09/min-det-2
        \\  curl -L localhost:8080/ufc/2026-09-05/event-14
        \\  curl -L localhost:8080/nfl/2026/week1/ne-sea
        \\  curl localhost:8080/all
        \\  curl localhost:8080/nfl/standings
        \\  curl -N 'localhost:8080/mlb?stream=sse'
        \\
    );
    if (!route.quiet) try w.print("Code: {s}\n", .{render.repo_url});
    return out.toOwnedSlice();
}

/// `?0` on the help page itself: the whole page as one line per topic.
fn writeCompactHelp(w: *std.Io.Writer) !void {
    try w.writeAll("sprts: / /all /{league} /{league}?date=YYYY-MM-DD /{league}?week=N(football) /{league}/{id}(digits=game,else team) /{league}/{abbr} /{league}/{date}/{away}-{home}[-N](redirect, curl -L) /{league}/{date}/event[-N](Nth game, redirect, curl -L) /{league}/{YYYY}/week{N}/{away}-{home}[-N](football redirect, curl -L) /{league}/{YYYY}/week{N}/event[-N](football redirect, curl -L) /{league}/standings /{league}/teams(JSON only) /{league}/tour /tour /api/v1/... /openapi.json /docs /llms.txt /healthz /:help\n");
    try w.writeAll("flags: color=0|1 width=N height=N quiet oneline(?0 text only) stream=sse format=text|html date=YYYY-MM-DD|today|tomorrow|yesterday week=N tz=utc art=off | aliases T A q 0 (long wins; later alias wins)\n");
    try w.writeAll("install: install -m755 tools/sprts ~/.local/bin/sprts\n");
    try w.writeAll("try: curl localhost:8080/mlb\n");
}

/// Minimal browser page: the same copy as text, never ANSI, with links.
fn htmlHelp(arena: std.mem.Allocator, route: router.HelpRoute) ![]u8 {
    const body = try textHelp(arena, route, false);
    defer arena.free(body);
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    const w = &out.writer;
    try render.pageHead(w, "sprts help");
    try render.writeEscapedBodyH1(w, body);
    try w.writeAll("</pre><nav><a href=\"/\">leagues</a><a href=\"/openapi.json\">spec</a>");
    try render.closePageWithNav(w);
    return out.toOwnedSlice();
}

const HelpEntry = struct {
    name: []const u8,
    description: []const u8,
};

const HelpDoc = struct {
    schema_version: []const u8 = "1",
    routes: []const HelpEntry,
    flags: []const HelpEntry,
    links: []const u8,
    install: []const u8,
    examples: []const []const u8,
};

/// Structured body for `/api/v1/` help targets (JSON by address):
/// same routes, flags, links, install line, and examples as the text page.
fn jsonHelp(arena: std.mem.Allocator) ![]u8 {
    // Validated through the shared `render.validatedJson` gate with the
    // other JSON renderers (see it for why strict zchema validation is
    // unusable process-wide).
    return render.validatedJson(HelpDoc, arena, .{
        .routes = &[_]HelpEntry{
            .{ .name = "/", .description = "Home: every league today, live first" },
            .{ .name = "/all", .description = "Every league one day (same ?date=, ?0)" },
            .{ .name = "/{league}", .description = "Scoreboard, e.g. /mlb" },
            .{ .name = "/{league}?date=YYYY-MM-DD", .description = "Scoreboard for one day" },
            .{ .name = "/{league}?week=N", .description = "Football week only, ignored elsewhere" },
            .{ .name = "/{league}/{id}", .description = "One game (all digits = game, else team)" },
            .{ .name = "/{league}/{abbr}", .description = "One team, e.g. /mlb/phi" },
            .{ .name = "/{league}/{date}/{away}-{home}", .description = "One game by date and teams, 302 to the game (date or today|tomorrow|yesterday; -N = doubleheader game N, 1 = first; curl -L; duel-only, cards/races 404 with the day board)" },
            .{ .name = "/{league}/{date}/event[-N]", .description = "Nth game on the day board, 302 to the game (bare event = 1; every game: bouts, sessions, fields, name-only duels; curl -L)" },
            .{ .name = "/{league}/{YYYY}/week{N}/{away}-{home}", .description = "Football week game by teams, 302 to the game (-N = doubleheader game N; curl -L)" },
            .{ .name = "/{league}/{YYYY}/week{N}/event[-N]", .description = "Nth game of the football week, 302 to the game (bare event = 1; curl -L)" },
            .{ .name = "/{league}/standings", .description = "Current table, no date" },
            .{ .name = "/{league}/teams", .description = "Team list: id, abbrev, name per team. JSON-only (no text twin: picker payload); the human path serves the same JSON body" },
            .{ .name = "/{league}/tour", .description = "Live terminal tour in the browser: vendored xterm.js fed by the SSE stream, read-only (no keyboard control)" },
            .{ .name = "/tour", .description = "All-leagues terminal tour, same player on the /all feed" },
            .{ .name = "/api/v1/leagues", .description = "Leagues as JSON" },
            .{ .name = "/api/v1/{league}[/{id|abbr}]", .description = "Same shapes as JSON" },
            .{ .name = "/api/v1/all, .../standings, .../teams", .description = "Digest, table, and team list as JSON" },
            .{ .name = "/openapi.json", .description = "API spec" },
            .{ .name = "/docs", .description = "Human API reference" },
            .{ .name = "/llms.txt", .description = "Agent API guide, plain text" },
            .{ .name = "/healthz", .description = "ok" },
            .{ .name = "/:help, /help", .description = "This page (also /{league}/:help)" },
        },
        .flags = &[_]HelpEntry{
            .{ .name = "color=0|1", .description = "ANSI color (aliases T=0, A=1)" },
            .{ .name = "width=N", .description = "Total terminal columns, 52..200" },
            .{ .name = "height=N", .description = "Max games shown" },
            .{ .name = "quiet=0|1", .description = "No header/footer (alias q)" },
            .{ .name = "oneline=0|1", .description = "One game per line, text only (alias 0)" },
            .{ .name = "format=text|html", .description = "Explicit response format" },
            .{ .name = "date=YYYY-MM-DD", .description = "Scoreboard and digest day" },
            .{ .name = "week=N", .description = "Football week only, ignored elsewhere" },
            .{ .name = "stream=sse", .description = "Scoreboard text-only live feed" },
            .{ .name = "tz=utc", .description = "Day zone, default et" },
            .{ .name = "art=off", .description = "Strip team-mark art for tofu terminals; anything else art on" },
            .{ .name = "precedence", .description = "Long flags win over aliases; later alias wins" },
        },
        .links = "Text rows print game:/team: links; HTML makes them clickable. Boards end with prev/next ?date= links. NFL history/offseason via nflverse games.csv (CC-BY-4.0, github.com/nflverse/nflverse-data): snapshot boards name their source.",
        .install = "install -m755 tools/sprts ~/.local/bin/sprts",
        .examples = &[_][]const u8{
            "curl localhost:8080/mlb",
            "curl 'localhost:8080/mlb?date=2026-09-06'",
            "curl 'localhost:8080/mlb/401816828?0'",
            "curl -L localhost:8080/mlb/2026-09-09/min-det",
            "curl -L localhost:8080/mlb/2026-09-09/min-det-2",
            "curl -L localhost:8080/ufc/2026-09-05/event-14",
            "curl -L localhost:8080/nfl/2026/week1/ne-sea",
            "curl localhost:8080/all",
            "curl localhost:8080/nfl/standings",
            "curl -N 'localhost:8080/mlb?stream=sse'",
        },
    });
}

fn helpRoute(color: ?bool, quiet: bool, oneline: bool) router.HelpRoute {
    return .{ .color = color, .quiet = quiet, .oneline = oneline };
}

fn twoGameBoard() domain.Scoreboard {
    return .{
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
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false, .home_away = "away" },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true, .home_away = "home" },
                },
            },
            .{
                .id = "2",
                .name = "Second at Third",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "7:05 PM ET",
                .participants = &.{
                    .{ .id = "c", .name = "Second", .abbreviation = "SEC", .score = "", .winner = false },
                    .{ .id = "d", .name = "Third", .abbreviation = "THI", .score = "", .winner = false },
                },
            },
        },
    };
}

test "one line per game with no box rules" {
    const output = try scoreOneLine(std.testing.allocator, twoGameBoard(), false, true);
    defer std.testing.allocator.free(output);
    _ = try std.unicode.Utf8View.init(output);
    var lines = std.mem.splitScalar(u8, output[0 .. output.len - 1], '\n');
    var count: usize = 0;
    while (lines.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(std.mem.indexOf(u8, output, "post Final AWY 2 @ HME 5 ✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pre 7:05 PM ET SEC @ THI") != null);
    for ([_][]const u8{ "┌", "├", "└", "│", "─" }) |rule| {
        try std.testing.expect(std.mem.indexOf(u8, output, rule) == null);
    }
}

test "color off strips all ANSI, color on marks state" {
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
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "0", .winner = false, .home_away = "away" },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "3", .winner = false, .home_away = "home" },
                },
            },
        },
    };
    const plain = try scoreOneLine(std.testing.allocator, board, false, true);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "in Top 7th AWY 0 @ HME 3") != null);
    const colored = try scoreOneLine(std.testing.allocator, board, true, true);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[1;31m") != null);
    _ = try std.unicode.Utf8View.init(colored);
}

test "empty board is a single line in any mode" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{},
    };
    for ([_]struct { color: bool, quiet: bool }{
        .{ .color = false, .quiet = true },
        .{ .color = true, .quiet = false },
    }) |mode| {
        const output = try scoreOneLine(std.testing.allocator, board, mode.color, mode.quiet);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings("No games scheduled.\n", output);
    }
}

test "non-duels fall back to the game name, quiet toggles framing" {
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
                    .{ .id = "v", .name = "Max Verstappen", .abbreviation = "VER", .score = "#1", .winner = true },
                },
            },
        },
    };
    const bare = try scoreOneLine(std.testing.allocator, board, false, true);
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("post Final Pirelli Italian Grand Prix ✓\n", bare);
    const framed = try scoreOneLine(std.testing.allocator, board, false, false);
    defer std.testing.allocator.free(framed);
    try std.testing.expect(std.mem.indexOf(u8, framed, "F1  2026-09-06\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, framed, "/f1?date=2026-09-05") != null);
    try std.testing.expect(std.mem.indexOf(u8, framed, "/f1?date=2026-09-07") != null);
    _ = try std.unicode.Utf8View.init(framed);
}

test "help text documents every route, flag, alias, install, and example" {
    const output = try renderHelp(std.testing.allocator, helpRoute(null, false, false), .text);
    defer std.testing.allocator.free(output);
    _ = try std.unicode.Utf8View.init(output);
    for ([_][]const u8{
        "/",
        "/all",
        "/{league}",
        "?date=",
        "?week=N",
        "/{league}/{id}",
        "all digits",
        "else team",
        "/{league}/{abbr}",
        "standings",
        "/{league}/teams",
        "no text twin",
        "picker",
        "/api/v1/",
        "/api/v1/all",
        "/openapi.json",
        "/docs",
        "/llms.txt",
        "/healthz",
        ":help",
        "color",
        "width",
        "height",
        "quiet",
        "oneline",
        "text only",
        "stream",
        "format",
        "tz=",
        "art=off",
        "game:",
        "team:",
        "prev/next",
        "T=color=0",
        "long flags win",
        "install -m755 tools/sprts ~/.local/bin/sprts",
        "curl localhost:8080/mlb",
        "curl localhost:8080/all",
        "curl localhost:8080/nfl/standings",
        "mlb",
        "Code: ",
        "SOURCES",
        "nflverse",
        "CC-BY-4.0",
        "never carry betting odds",
    }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, output, token) != null);
    }
}

test "help quiet strips framing, oneline compacts, color toggles ANSI" {
    const full = try renderHelp(std.testing.allocator, helpRoute(null, false, false), .text);
    defer std.testing.allocator.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, "scores in your terminal") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "Code: ") != null);

    const quiet = try renderHelp(std.testing.allocator, helpRoute(false, true, false), .text);
    defer std.testing.allocator.free(quiet);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "scores in your terminal") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "Code: ") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "ROUTES") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "\x1b[") == null);

    const colored = try renderHelp(std.testing.allocator, helpRoute(true, false, false), .text);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[2m") != null);

    const compact = try renderHelp(std.testing.allocator, helpRoute(false, false, true), .text);
    defer std.testing.allocator.free(compact);
    var lines = std.mem.splitScalar(u8, compact[0 .. compact.len - 1], '\n');
    var count: usize = 0;
    while (lines.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 4), count);
    // Compact page carries the same surface: digest, standings, agent
    // guide, week/tz flags, and the digits rule, not just the basics.
    for ([_][]const u8{ "/all", "/{league}/{id}", "digits=game", "standings", "/{league}/teams", "/llms.txt", "/docs", "week=N", "tz=utc", "text only", "art=off" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, compact, token) != null);
    }
}

test "help HTML is minimal and never carries ANSI" {
    const page = try renderHelp(std.testing.allocator, helpRoute(null, false, false), .html);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<h1 id=\"content\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Skip to content") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ":help") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
}

test "help JSON parses with routes, flags, links, install, and examples" {
    const doc = try renderHelp(std.testing.allocator, helpRoute(null, false, false), .json);
    defer std.testing.allocator.free(doc);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, doc, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("1", root.get("schema_version").?.string);
    try std.testing.expect(root.get("routes").?.array.items.len > 0);
    try std.testing.expect(root.get("flags").?.array.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, root.get("install").?.string, "tools/sprts") != null);
    try std.testing.expect(root.get("examples").?.array.items.len > 0);
    // Drift pins: every route/flag the text page documents lives here too.
    const route_names = root.get("routes").?.array.items;
    for ([_][]const u8{ "/all", "/{league}?week=N", "/{league}/{id}", "/{league}/standings", "/{league}/teams", "/api/v1/all, .../standings, .../teams", "/llms.txt", "/docs" }) |want| {
        var found = false;
        for (route_names) |entry| {
            if (std.mem.eql(u8, entry.object.get("name").?.string, want)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    // Digits rule rides the game description, not just the name.
    {
        var found = false;
        for (route_names) |entry| {
            if (std.mem.eql(u8, entry.object.get("name").?.string, "/{league}/{id}")) {
                found = std.mem.indexOf(u8, entry.object.get("description").?.string, "else team") != null;
                break;
            }
        }
        try std.testing.expect(found);
    }
    const flag_names = root.get("flags").?.array.items;
    for ([_][]const u8{ "week=N", "tz=utc", "oneline=0|1", "stream=sse", "art=off" }) |want| {
        var found = false;
        for (flag_names) |entry| {
            if (std.mem.eql(u8, entry.object.get("name").?.string, want)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    // Oneline is text-only: HTML and JSON ignore ?0.
    {
        var found = false;
        for (flag_names) |entry| {
            if (std.mem.eql(u8, entry.object.get("name").?.string, "oneline=0|1")) {
                found = std.mem.indexOf(u8, entry.object.get("description").?.string, "text only") != null;
                break;
            }
        }
        try std.testing.expect(found);
    }
    // Game/team links and prev/next date nav ride the links field, plus
    // the nflverse attribution for snapshot-filled NFL boards.
    try std.testing.expect(std.mem.indexOf(u8, root.get("links").?.string, "game:") != null);
    try std.testing.expect(std.mem.indexOf(u8, root.get("links").?.string, "prev/next") != null);
    try std.testing.expect(std.mem.indexOf(u8, root.get("links").?.string, "nflverse") != null);
    try std.testing.expect(std.mem.indexOf(u8, root.get("links").?.string, "CC-BY-4.0") != null);
    // Digest and standings examples stay in parity with the text page.
    var saw_all = false;
    var saw_standings = false;
    for (root.get("examples").?.array.items) |entry| {
        if (std.mem.indexOf(u8, entry.string, "/all") != null) saw_all = true;
        if (std.mem.indexOf(u8, entry.string, "standings") != null) saw_standings = true;
    }
    try std.testing.expect(saw_all);
    try std.testing.expect(saw_standings);
}

test "scoreboard one-line fallback renders no team marks" {
    // Verified, not assumed: `?0` prints abbreviations only, so `?art=off`
    // is meaningless there — proven by zero braille for mark-shipping
    // teams (PHI/NYM) plus byte-identical color-off output.
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
    try std.testing.expect(core.art.teamArt("mlb", "PHI", .xs) != null);
    const output = try scoreOneLine(std.testing.allocator, board, false, true);
    defer std.testing.allocator.free(output);
    var i: usize = 0;
    while (i + 1 < output.len) : (i += 1) {
        try std.testing.expect(!(output[i] == 0xE2 and output[i + 1] >= 0xA0 and output[i + 1] <= 0xA3));
    }
    try std.testing.expectEqualStrings("post Final PHI 5 @ NYM 3 ✓\n", output);
}
