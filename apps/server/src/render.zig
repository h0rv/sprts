const std = @import("std");
const core = @import("sprts_core");
const z = @import("zchema");
const domain = core.domain;
const leagues = core.leagues;
const dates = core.date;
const router = @import("router.zig");
const provider = @import("provider.zig");
const table = @import("table.zig");

/// Box-table surface, re-exported from the shared `table` module so views
/// that reached these through `render` (e.g. `team_view`) keep compiling
/// during the migration. New code should import `table.zig` directly.
pub const Rule = table.Rule;
pub const Table = table.Table;
pub const writeCell = table.writeCell;
pub const writeCellRight = table.writeCellRight;
pub const writeRow = table.writeRow;
pub const writeRule = table.writeRule;
pub const fit = table.fit;
pub const countCells = table.countCells;
pub const writeArtRow = table.writeArtRow;
pub const writeGameMarks = table.writeGameMarks;

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

/// `width` is total terminal columns; the borders take 2. Never shrinks
/// below the classic 52-wide box, so team art and the fixed participant
/// cells always fit — extra room stretches the flexible rows and names.
/// `height` caps the games listed (`+N more` trailer); null/0 = all.
pub fn text(allocator: std.mem.Allocator, board: domain.Scoreboard, color: bool, width: ?u16, height: ?u16) ![]u8 {
    const inner: usize = @min(@max(width orelse 52, 52), 200) - 2;
    const shown: usize = @min(height orelse board.games.len, board.games.len);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const t = Table{ .writer = w, .inner = inner, .color = color };
    try t.rule(.top);
    const heading = try std.fmt.allocPrint(allocator, "{s}  {s}", .{ board.league_name, board.date });
    defer allocator.free(heading);
    try t.row(heading, "2");
    if (board.games.len == 0) {
        try t.rule(.mid);
        try t.row("No games scheduled.", null);
    }
    for (board.games[0..shown]) |game| {
        try t.rule(.mid);
        try t.row(game.status, statusColor(game.state));
        try writeGameMarks(w, allocator, board.league, &game, inner, color);
        if (game.participants.len == 0) {
            try t.row(game.name, null);
        }
        for (game.participants) |participant| {
            try t.participantRow(participant);
        }
    }
    if (shown < board.games.len) {
        const more = try std.fmt.allocPrint(allocator, "+{d} more", .{board.games.len - shown});
        defer allocator.free(more);
        try t.rule(.mid);
        try t.row(more, "2");
    }
    try t.rule(.bottom);
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

fn statusColor(state: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, state, "in")) return "1;31";
    if (std.mem.eql(u8, state, "pre")) return "33";
    return null;
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

pub fn home(allocator: std.mem.Allocator, color: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try colorize(w, "2", "sprts\n", color);
    try writeRule(w, .top, default_inner_width);
    for (leagues.all) |league| {
        try w.writeAll("│ ");
        try writeCell(w, league.slug, 13, null, color);
        try w.writeByte(' ');
        try writeCell(w, league.name, 34, null, color);
        try w.writeAll(" │\n");
    }
    try writeRule(w, .bottom, default_inner_width);
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
pub fn homeLive(
    allocator: std.mem.Allocator,
    color: bool,
    host: []const u8,
    boards: []const provider.LeagueResult,
    day: []const u8,
    quiet: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    if (!quiet) {
        const heading = try std.fmt.allocPrint(allocator, "sprts  {s}", .{day});
        defer allocator.free(heading);
        try colorize(w, "2", heading, color);
        try w.writeByte('\n');
    }
    try writeRule(w, .top, default_inner_width);
    try homeSections(allocator, w, boards, color, false, day);
    try writeRule(w, .bottom, default_inner_width);
    if (!quiet) try homeFooter(w, host, color);
    return out.toOwnedSlice();
}

/// Home one-line (`/?0`): every game today is ONE line, no box, no
/// header/footer — same per-game shape as `scoreOneLine`, across leagues.
/// Idle leagues (no board or no games) emit nothing; with no games at all
/// the body is a single `No games scheduled.` line.
pub fn homeOneLine(
    allocator: std.mem.Allocator,
    boards: []const provider.LeagueResult,
    color: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var any = false;
    for (boards) |result| {
        const board = result.board orelse continue;
        for (board.games) |game| {
            try writeBoardGameOneLine(&out.writer, result.league.slug, board.date, game, color);
            any = true;
        }
    }
    if (!any) try out.writer.writeAll("No games scheduled.\n");
    return out.toOwnedSlice();
}

/// Compact one-liner per game: `MLB  NYY 0 @ BOS 3 ✓  Top 7th`.
/// Non-duels fall back to the game name. Returns null for nothing to show.
fn gameLine(allocator: std.mem.Allocator, league: *const leagues.League, game: domain.Game) !?[]u8 {
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
            return try std.fmt.allocPrint(allocator, "{s}  {s} {s} @ {s} {s}{s}  {s}", .{
                league.slug,
                away.abbreviation,
                away.score,
                home_team.abbreviation,
                home_team.score,
                if (away.winner) " ✓" else if (home_team.winner) " ✓" else "",
                game.status,
            });
        }
        return try std.fmt.allocPrint(allocator, "{s}  {s} @ {s}  {s}", .{
            league.slug,
            away.abbreviation,
            home_team.abbreviation,
            game.status,
        });
    }
    if (game.participants.len == 0 and game.name.len == 0) return null;
    return try std.fmt.allocPrint(allocator, "{s}  {s}  {s}", .{ league.slug, game.name, game.status });
}

fn gameIsLive(game: domain.Game) bool {
    return std.mem.eql(u8, game.state, "in");
}

/// Live games first, then the rest of today, then idle leagues as links.
/// Leagues with no board (fetch failed) count as idle: the page never
/// fails because of one league.
fn homeSections(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    boards: []const provider.LeagueResult,
    color: bool,
    comptime html: bool,
    day: []const u8,
) !void {
    var live = false;
    var today = false;
    for (boards) |result| {
        const board = result.board orelse continue;
        for (board.games) |game| {
            if (gameIsLive(game)) {
                if (!live) {
                    live = true;
                    try writeRule(w, .mid, default_inner_width);
                    try writeRow(w, "LIVE NOW", default_inner_width - 2, "1;31", color and !html);
                }
                try homeGameLine(allocator, w, result.league, game, day, color and !html, html);
            }
        }
    }
    for (boards) |result| {
        const board = result.board orelse continue;
        var shown = false;
        for (board.games) |game| {
            if (gameIsLive(game)) continue;
            if (!shown) {
                if (!today) {
                    today = true;
                    try writeRule(w, .mid, default_inner_width);
                    try writeRow(w, "TODAY", default_inner_width - 2, "2", color and !html);
                }
                shown = true;
            }
            try homeGameLine(allocator, w, result.league, game, day, color and !html, html);
        }
    }
    try writeRule(w, .mid, default_inner_width);
    try writeRow(w, "ALL LEAGUES", default_inner_width - 2, "2", color and !html);
    for (boards) |result| {
        const board = result.board;
        if (board != null and board.?.games.len > 0) continue;
        try w.writeAll("│ ");
        if (html) try w.print("<a href=\"/{s}\">", .{result.league.slug});
        try writeCell(w, result.league.slug, 13, null, false);
        try w.writeByte(' ');
        try writeCell(w, result.league.name, 34, null, false);
        if (html) try w.writeAll("</a>");
        try w.writeAll(" │\n");
    }
}

fn homeGameLine(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    league: *const leagues.League,
    game: domain.Game,
    day: []const u8,
    color: bool,
    html: bool,
) !void {
    const line = try gameLine(allocator, league, game) orelse return;
    defer allocator.free(line);
    try w.writeAll("│ ");
    if (html) try w.print("<a href=\"/{s}?date={s}\">", .{ league.slug, day });
    try writeCell(w, line, 48, statusColor(game.state), color);
    if (html) try w.writeAll("</a>");
    try w.writeAll(" │\n");
}

fn homeFooter(w: *std.Io.Writer, host: []const u8, color: bool) !void {
    try colorize(w, "2", "Try: curl ", color);
    try colorize(w, "2", host, color);
    try colorize(w, "2", "/mlb\n", color);
    try colorize(w, "2", "API: ", color);
    try colorize(w, "2", host, color);
    try colorize(w, "2", "/api/v1/leagues  Spec: ", color);
    try colorize(w, "2", host, color);
    try colorize(w, "2", "/openapi.json\n", color);
    try colorize(w, "2", "Code: " ++ repo_url ++ "\n", color);
}

fn writeShortDate(w: *std.Io.Writer, date: []const u8) !void {
    if (date.len >= 10 and date[4] == '-' and date[7] == '-') {
        const m = date[5..7];
        const d = date[8..10];
        const mm = if (m[0] == '0') m[1..] else m;
        const dd = if (d[0] == '0') d[1..] else d;
        try w.print("{s}/{s}", .{ mm, dd });
    } else {
        try w.writeAll(date);
    }
}

fn writeBoardGameOneLine(w: *std.Io.Writer, league_slug: []const u8, board_date: []const u8, game: domain.Game, color: bool) !void {
    const code: ?[]const u8 = if (color) statusColor(game.state) else null;
    if (code) |c| try w.print("\x1b[{s}m", .{c});
    try w.writeAll(league_slug);
    try w.writeByte(' ');
    try writeShortDate(w, board_date);
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

/// Minimal browser page: the same table as text, never ANSI, with real
/// links. Browsers cannot use terminal escapes, so HTML output is always
/// uncolored and the text renderer stays the single source of layout.
pub fn scoreHtml(allocator: std.mem.Allocator, board: domain.Scoreboard, width: ?u16, height: ?u16) ![]u8 {
    const body = try text(allocator, board, false, width, height);
    defer allocator.free(body);
    const previous = try dates.shift(allocator, board.date, -1);
    defer allocator.free(previous);
    const next = try dates.shift(allocator, board.date, 1);
    defer allocator.free(next);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const title = try std.fmt.allocPrint(allocator, "{s} scores", .{board.league_name});
    defer allocator.free(title);
    try pageHead(w, title);
    try w.writeAll("<pre>");
    try escapeInto(w, body);
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/{s}?date={s}\">earlier</a>", .{ board.league, previous });
    try w.print("<a href=\"/{s}\">today</a>", .{board.league});
    try w.print("<a href=\"/{s}?date={s}\">later</a>", .{ board.league, next });
    try w.print("<a href=\"/api/v1/{s}?date={s}\">json</a>", .{ board.league, board.date });
    try w.writeAll("</nav></main></body></html>");
    return out.toOwnedSlice();
}

pub fn homeHtml(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try pageHead(w, "sprts");
    try w.writeAll("<pre>sprts\n");
    try writeRule(w, .top, default_inner_width);
    for (leagues.all) |league| {
        try w.writeAll("│ ");
        try w.print("<a href=\"/{s}\">", .{league.slug});
        try writeCell(w, league.slug, 13, null, false);
        try w.writeByte(' ');
        try writeCell(w, league.name, 34, null, false);
        try w.writeAll("</a> │\n");
    }
    try writeRule(w, .bottom, default_inner_width);
    try w.writeAll("Try: curl localhost:8080/mlb\n");
    try w.writeAll("</pre><nav><a href=\"/api/v1/leagues\">json</a></nav></main></body></html>");
    return out.toOwnedSlice();
}

/// Live HTML home: same sections as `homeLive`, never ANSI, with links.
/// Game lines link to their league page; the nav mirrors `homeHtml`.
pub fn homeHtmlLive(
    allocator: std.mem.Allocator,
    host: []const u8,
    boards: []const provider.LeagueResult,
    day: []const u8,
    quiet: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const heading = try std.fmt.allocPrint(allocator, "sprts  {s}", .{day});
    defer allocator.free(heading);
    try pageHead(w, heading);
    try w.writeAll("<pre>");
    try writeRule(w, .top, default_inner_width);
    try homeSections(allocator, w, boards, false, true, day);
    try writeRule(w, .bottom, default_inner_width);
    if (!quiet) {
        try w.writeAll("Try: curl ");
        try escapeInto(w, host);
        try w.writeAll("/mlb\nAPI: ");
        try escapeInto(w, host);
        try w.writeAll("/api/v1/leagues  Spec: ");
        try escapeInto(w, host);
        try w.writeAll("/openapi.json\nCode: " ++ repo_url ++ "\n");
    }
    try w.writeAll("</pre>");
    if (!quiet) {
        try w.writeAll("<nav><a href=\"/api/v1/leagues\">json</a><a href=\"/openapi.json\">spec</a><a href=\"" ++ repo_url ++ "\">github</a></nav>");
    }
    try w.writeAll("</main></body></html>");
    return out.toOwnedSlice();
}

pub fn pageHead(w: *std.Io.Writer, title: []const u8) !void {
    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>");
    try escapeInto(w, title);
    try w.writeAll("</title>" ++ page_style ++ "</head><body><main>");
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
    \\<style>html,body{margin:0;background:#10140f;color:#e6ebe7}main{max-width:640px;margin:auto;padding:20px 14px}pre{margin:0;font:14px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;word-wrap:break-word}nav{margin-top:14px;display:flex;gap:16px;font:14px ui-monospace,monospace}a{color:#6fd3a0}</style>
;

pub fn leaguesJson(allocator: std.mem.Allocator) ![]u8 {
    return validatedJson(leagues.LeagueList, allocator, .{ .leagues = &leagues.all });
}

pub fn errorBody(allocator: std.mem.Allocator, message: []const u8, format: router.Format) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    switch (format) {
        .text => try out.writer.print("sprts: {s}\n", .{message}),
        .html => {
            try pageHead(&out.writer, "sprts error");
            try out.writer.writeAll("<pre>sprts: ");
            try escapeInto(&out.writer, message);
            try out.writer.writeAll("</pre><nav><a href=\"/\">leagues</a></nav></main></body></html>");
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

test "text renderer draws a table and no HTML" {
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
    try std.testing.expect(std.mem.indexOf(u8, output, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<html") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
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

    const homepage = try homeHtml(std.testing.allocator);
    defer std.testing.allocator.free(homepage);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "<a href=\"/mlb\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "\x1b[") == null);

    const err = try errorBody(std.testing.allocator, "a<b", .html);
    defer std.testing.allocator.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "a&lt;b") != null);
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
    const output = try homeLive(std.testing.allocator, false, "example.test", &results, "2026-09-06", false);
    defer std.testing.allocator.free(output);
    try expectAlignedTable(output);
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
    const output = try homeLive(std.testing.allocator, false, "example.test", &results, "2026-09-06", false);
    defer std.testing.allocator.free(output);
    const live_at = std.mem.indexOf(u8, output, "LIVE NOW").?;
    const today_at = std.mem.indexOf(u8, output, "TODAY").?;
    const leagues_at = std.mem.indexOf(u8, output, "ALL LEAGUES").?;
    try std.testing.expect(live_at < today_at);
    try std.testing.expect(today_at < leagues_at);
    try std.testing.expect(std.mem.indexOf(u8, output, "mlb  AWY 0 @ HME 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nba  TRD @ FRT  7:05 PM ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nfl") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "example.test/mlb") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "example.test/api/v1/leagues") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, repo_url) != null);
    try expectAlignedTable(output);

    const page = try homeHtmlLive(std.testing.allocator, "example.test", &results, "2026-09-06", false);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb?date=2026-09-06\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nfl\">") != null);
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
    try expectAlignedTableColored(colored);
    const plain = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    try expectAlignedTable(plain);
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
    // Top rule: ┌ + 78 × ─ + ┐\n.
    const eol = std.mem.indexOfScalar(u8, wide, '\n').?;
    try std.testing.expectEqual(@as(usize, 3 + 78 * 3 + 3), eol);
    _ = try std.unicode.Utf8View.init(wide);

    // Narrow requests never shrink below the classic 52-wide box.
    const narrow = try text(std.testing.allocator, board, false, 40, null);
    defer std.testing.allocator.free(narrow);
    const narrow_eol = std.mem.indexOfScalar(u8, narrow, '\n').?;
    try std.testing.expectEqual(@as(usize, 3 + 50 * 3 + 3), narrow_eol);
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
