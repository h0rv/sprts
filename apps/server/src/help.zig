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
        \\  /{league}                      scoreboard, e.g. /mlb
        \\  /{league}?date=YYYY-MM-DD      scoreboard for one day
        \\  /{league}/{id}                 one game (id is all digits)
        \\  /{league}/{abbr}               one team, e.g. /mlb/phi
        \\  /api/v1/leagues                leagues as JSON
        \\  /api/v1/{league}[/{id|abbr}]   same shapes as JSON
        \\  /openapi.json                  API spec
        \\  /healthz                       ok
        \\  /:help, /help                  this page (also /{league}/:help)
        \\
    );
    try section(w, "FLAGS (every human route; JSON ignores display flags)", color);
    try w.writeAll(
        \\  color=0|1  width=N (52..200)  height=N (max games)
        \\  quiet=0|1 (no header/footer)  oneline=0|1 (?0)  format=text|html
        \\  date=YYYY-MM-DD (scoreboard)  stream=sse (scoreboard text only, curl -N)
        \\
    );
    try section(w, "ALIASES (combined ?0pq or split ?0&q; unknown letters ignored)", color);
    try w.writeAll(
        \\  T=color=0  A=color=1  q=quiet  0=oneline
        \\  long flags win (?color=1&T is color on); later alias wins (?T&A is on)
        \\
    );
    try section(w, "LEAGUES", color);
    try w.writeAll("  ");
    for (core.leagues.all, 0..) |league, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(league.slug);
    }
    try w.writeAll("\n");
    try section(w, "INSTALL", color);
    try w.writeAll("  install -m755 tools/sprts ~/.local/bin/sprts\n");
    try section(w, "EXAMPLES", color);
    try w.writeAll(
        \\  curl localhost:8080/mlb
        \\  curl 'localhost:8080/mlb?date=2026-09-06'
        \\  curl 'localhost:8080/mlb/401816828?0'
        \\  curl -N 'localhost:8080/mlb?stream=sse'
        \\
    );
    if (!route.quiet) try w.print("Code: {s}\n", .{render.repo_url});
    return out.toOwnedSlice();
}

/// `?0` on the help page itself: the whole page as one line per topic.
fn writeCompactHelp(w: *std.Io.Writer) !void {
    try w.writeAll("sprts: / /{league} /{league}?date=YYYY-MM-DD /{league}/{id} /{league}/{abbr} /api/v1/... /openapi.json /healthz /:help\n");
    try w.writeAll("flags: color=0|1 width=N height=N quiet oneline stream=sse format=text|html date=YYYY-MM-DD | aliases T A q 0 (long wins; later alias wins)\n");
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
    try w.writeAll("<pre>");
    try render.escapeInto(w, body);
    try w.writeAll("</pre><nav><a href=\"/\">leagues</a><a href=\"/openapi.json\">spec</a></nav></main></body></html>");
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
    install: []const u8,
    examples: []const []const u8,
};

/// Structured body for `/api/v1/` help targets (JSON by address):
/// same routes, flags, install line, and examples as the text page.
fn jsonHelp(arena: std.mem.Allocator) ![]u8 {
    // Validated through the shared `render.validatedJson` gate with the
    // other JSON renderers (see it for why strict zchema validation is
    // unusable process-wide).
    return render.validatedJson(HelpDoc, arena, .{
        .routes = &[_]HelpEntry{
            .{ .name = "/", .description = "Home: every league today, live first" },
            .{ .name = "/{league}", .description = "Scoreboard, e.g. /mlb" },
            .{ .name = "/{league}?date=YYYY-MM-DD", .description = "Scoreboard for one day" },
            .{ .name = "/{league}/{id}", .description = "One game (id is all digits)" },
            .{ .name = "/{league}/{abbr}", .description = "One team, e.g. /mlb/phi" },
            .{ .name = "/api/v1/leagues", .description = "Leagues as JSON" },
            .{ .name = "/api/v1/{league}[/{id|abbr}]", .description = "Same shapes as JSON" },
            .{ .name = "/openapi.json", .description = "API spec" },
            .{ .name = "/healthz", .description = "ok" },
            .{ .name = "/:help, /help", .description = "This page (also /{league}/:help)" },
        },
        .flags = &[_]HelpEntry{
            .{ .name = "color=0|1", .description = "ANSI color (aliases T=0, A=1)" },
            .{ .name = "width=N", .description = "Total terminal columns, 52..200" },
            .{ .name = "height=N", .description = "Max games shown" },
            .{ .name = "quiet=0|1", .description = "No header/footer (alias q)" },
            .{ .name = "oneline=0|1", .description = "One game per line (alias 0)" },
            .{ .name = "format=text|html", .description = "Explicit response format" },
            .{ .name = "date=YYYY-MM-DD", .description = "Scoreboard day" },
            .{ .name = "stream=sse", .description = "Scoreboard text-only live feed" },
            .{ .name = "precedence", .description = "Long flags win over aliases; later alias wins" },
        },
        .install = "install -m755 tools/sprts ~/.local/bin/sprts",
        .examples = &[_][]const u8{
            "curl localhost:8080/mlb",
            "curl 'localhost:8080/mlb?date=2026-09-06'",
            "curl 'localhost:8080/mlb/401816828?0'",
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
        "/{league}",
        "?date=",
        "/{league}/{id}",
        "/{league}/{abbr}",
        "/api/v1/",
        "/openapi.json",
        "/healthz",
        ":help",
        "color",
        "width",
        "height",
        "quiet",
        "oneline",
        "stream",
        "format",
        "T=color=0",
        "long flags win",
        "install -m755 tools/sprts ~/.local/bin/sprts",
        "curl localhost:8080/mlb",
        "mlb",
        "Code: ",
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
    try std.testing.expect(std.mem.indexOf(u8, compact, "/{league}/{id}") != null);
}

test "help HTML is minimal and never carries ANSI" {
    const page = try renderHelp(std.testing.allocator, helpRoute(null, false, false), .html);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ":help") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
}

test "help JSON parses with routes, flags, install, and examples" {
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
}
