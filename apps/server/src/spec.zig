const core = @import("sprts_core");
const z = @import("zchema");
const digest = @import("digest.zig");

const ScoreboardPath = struct {
    league: []const u8,
};

const ScoreboardQuery = struct {
    date: ?[]const u8 = null,
    stream: ?[]const u8 = null,
    week: ?u16 = null,

    pub const jsonschema = .{
        .fields = .{
            .date = .{ .format = "date" },
            .stream = .{},
            // zchema only emits bare-type schemas for path/query params
            // (field overrides do not reach the document); the description
            // stays next to the type and the endpoint description repeats
            // the football-only rule, mirroring the GamePath pattern below.
            .week = .{ .description = "ESPN week selector; strict positive integer, honored only for football leagues, otherwise ignored" },
        },
    };
};

// Query for the multi-league digest. Date-driven only (`?date=`); `week`
// is NOT fanned out (see digest.zig header). Display flags only affect
// text/HTML, so under `/api/v1/` the response is always JSON.
const AllQuery = struct {
    date: ?[]const u8 = null,

    pub const jsonschema = .{
        .fields = .{
            .date = .{ .format = "date" },
        },
    };
};

// Second segment of a game address. The router treats an all-digits
// segment as a game id and anything else as a team abbreviation, so the
// digits rule is load-bearing for which endpoint answers. It is repeated
// in the endpoint description below because zchema only emits bare-type
// schemas for path/query params (field overrides like `pattern` do not
// reach the document); the struct keeps the rule next to the type.
const GamePath = struct {
    league: []const u8,
    id: []const u8,

    pub const jsonschema = .{
        .fields = .{
            .id = .{
                .pattern = "^[0-9]+$",
                .description = "ESPN game id; digits only, anything else routes to the team view",
            },
        },
    };
};

const TeamPath = struct {
    league: []const u8,
    abbr: []const u8,

    pub const jsonschema = .{
        .fields = .{
            .abbr = .{ .description = "Team abbreviation, e.g. PHI" },
        },
    };
};

pub const ApiSpec = z.Spec(.{
    z.endpoint(.GET, "/api/v1/leagues", .{
        .operation_id = "listLeagues",
        .summary = "List supported leagues",
        .responses = .{z.case(.ok, core.leagues.LeagueList)},
    }),
    z.endpoint(.GET, "/api/v1/all", .{
        .operation_id = "getAll",
        .summary = "Scores for all leagues and date",
        .description = "Multi-league digest for one date: one Scoreboard per league in league order. " ++
            "Outages degrade additively, never by shape change: a failed league renders as a zero-game " ++
            "board with its slug in the top-level degraded list (zero games plus absent-from-degraded " ++
            "means off-day; present means outage, retry later; see digest.DigestJson). " ++
            "Game starts_at is UTC ISO-8601; text/HTML headings name the request zone (default ET). " ++
            "The source field names the upstream host (normally site.api.espn.com). " ++
            "Date-driven only (?date=YYYY-MM-DD, defaults to today); week is NOT fanned out.",
        .query = AllQuery,
        .responses = .{
            z.case(.ok, digest.DigestJson),
            z.case(.bad_request, z.ErrorBody),
        },
    }),
    z.endpoint(.GET, "/api/v1/{league}", .{
        .operation_id = "getScoreboard",
        .summary = "Scores for one league and date",
        .description = "Pass ?stream=sse (or Accept: text/event-stream) for a text-only SSE feed: " ++
            "framed as data: lines plus blank-line terminators, each event prefixed with the " ++
            "clear-screen escape \\x1b[2J\\x1b[H for in-place redraw, with : ping keepalive comments. " ++
            "Example: curl -N /nba?stream=sse. Text-only; JSON and HTML always return a single response. " ++
            "Pass ?week=N (strict positive integer; ESPN honors it only for football leagues, otherwise ignored). " ++
            "JSON Scoreboard: game starts_at is UTC ISO-8601 while text/HTML headings name the request " ++
            "zone (default ET); source names the upstream host (normally site.api.espn.com).",
        .path = ScoreboardPath,
        .query = ScoreboardQuery,
        .responses = .{
            z.case(.ok, core.domain.Scoreboard),
            z.case(.bad_request, z.ErrorBody),
            z.case(.not_found, z.ErrorBody),
            z.case(.bad_gateway, z.ErrorBody),
        },
    }),
    // Display flags (`color`, `width`, `height`) only affect text/HTML
    // rendering, so no endpoint lists them: under `/api/v1/` the response
    // is always JSON. Only `date` on the scoreboard/all digest selects data
    // (bad `date` 400 is only possible there); game/team can only miss
    // (404) or lose upstream (502). The digest never 404s or 502s: one
    // league's outage degrades to a zero-game board entry plus its slug in
    // the digest `degraded` list.
    z.endpoint(.GET, "/api/v1/{league}/{id}", .{
        .operation_id = "getGame",
        .summary = "One game with linescore and scoring plays",
        .description = "The second segment is a game only when it is all digits; anything else routes to the team view.",
        .path = GamePath,
        .responses = .{
            z.case(.ok, core.detail.GameDetail),
            z.case(.not_found, z.ErrorBody),
            z.case(.bad_gateway, z.ErrorBody),
        },
    }),
    z.endpoint(.GET, "/api/v1/{league}/{abbr}", .{
        .operation_id = "getTeam",
        .summary = "One team: last result, live game, and upcoming schedule",
        .path = TeamPath,
        .responses = .{
            z.case(.ok, core.schedule.TeamView),
            z.case(.not_found, z.ErrorBody),
            z.case(.bad_gateway, z.ErrorBody),
        },
    }),
    // Standings tab (plaintextsports parity). Current table only: no date
    // or week query. Unknown slugs and leagues without an ESPN table are
    // both 404; upstream failure is 502.
    z.endpoint(.GET, "/api/v1/{league}/standings", .{
        .operation_id = "getStandings",
        .summary = "Current standings table for one league",
        .path = ScoreboardPath,
        .responses = .{
            z.case(.ok, core.standings.LeagueStandings),
            z.case(.not_found, z.ErrorBody),
            z.case(.bad_gateway, z.ErrorBody),
        },
    }),
});

pub fn openApiJson(allocator: std.mem.Allocator) ![]u8 {
    return z.openApiJson(ApiSpec, allocator, .{
        .title = "sprts API",
        .version = "1.0.0",
        .description = "Provider-neutral sports scores and schedules.",
    });
}

/// API reference page (Scalar UI via zchema's docs module, spec served
/// from `/openapi.json`). Linked from every page footer as `docs`.
/// Agent-first API surface at `/llms.txt`. Plain text, never ANSI.
pub fn llmsTxt(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(
        "sprts - scores in your terminal\n" ++
            "Provider-neutral sports scores and schedules, ESPN-backed.\n" ++
            "Plain text by default, HTML with ?format=html, JSON under /api/v1/.\n" ++
            "\n" ++
            "Base URL: this host (local http://localhost:8080). Same paths on prod.\n" ++
            "\n" ++
            "DOCS\n" ++
            "  /openapi.json - full API spec, single source of truth\n" ++
            "  /docs - human API reference\n" ++
            "  /llms.txt - this file\n" ++
            "\n" ++
            "JSON API\n" ++
            "  GET /api/v1/leagues - List supported leagues. (listLeagues)\n" ++
            "  GET /api/v1/all - Scores for all leagues and date. params: date. degraded lists outage slugs. (getAll)\n" ++
            "  GET /api/v1/league - Scores for one league and date. params: date, week football-only. (getScoreboard)\n" ++
            "  GET /api/v1/league/id - One game with linescore and scoring plays. id digits only. (getGame)\n" ++
            "  GET /api/v1/league/abbr - One team: last result, live game, upcoming schedule. (getTeam)\n" ++
            "  GET /api/v1/league/standings - Current standings table for one league. (getStandings)\n" ++
            "\n" ++
            "DIGITS RULE\n" ++
            "  Second segment all digits is a game: /mlb/401816828.\n" ++
            "  Anything else is a team: /mlb/PHI.\n" ++
            "\n" ++
            "TEXT HTML JSON\n" ++
            "  Text default: curl localhost:8080/mlb\n" ++
            "  HTML: curl localhost:8080/mlb?format=html\n" ++
            "  JSON: curl localhost:8080/api/v1/mlb\n" ++
            "\n" ++
            "FLAGS text and HTML only, JSON ignores display flags\n" ++
            "  ?date=YYYY-MM-DD scoreboard day, default today (today/tomorrow/yesterday also work)\n" ++
            "  ?week=N football-only week selector, ignored elsewhere\n" ++
            "  ?color=0 color off, ?color=1 color on\n" ++
            "  ?width=N ?height=N terminal size cap\n" ++
            "  ?0 one-line per game, text-only\n" ++
            "  ?art=off strips team-mark art for tofu terminals, anything else art on\n" ++
            "\n" ++
            "JSON DIGEST OUTAGES\n" ++
            "  /api/v1/all never 404s or 502s: a failed league is a zero-game board plus its slug in degraded.\n" ++
            "  Zero games with the slug absent from degraded is an off-day; present means outage, retry later.\n" ++
            "  Text /all marks the same leagues unavailable.\n" ++
            "\n" ++
            "ZONES SOURCE\n" ++
            "  starts_at is UTC ISO-8601; text and HTML headings name the request zone, default ET.\n" ++
            "  source is the upstream host, normally site.api.espn.com.\n" ++
            "\n" ++
            "EXAMPLES\n" ++
            "  curl localhost:8080/mlb\n" ++
            "  curl localhost:8080/mlb?date=2026-09-06\n" ++
            "  curl localhost:8080/mlb?format=html\n" ++
            "  curl localhost:8080/api/v1/leagues\n" ++
            "  curl localhost:8080/api/v1/all\n" ++
            "  curl localhost:8080/api/v1/mlb?date=2026-09-06\n" ++
            "  curl localhost:8080/mlb/401816828?0\n" ++
            "  curl localhost:8080/mlb/PHI/today\n" ++
            "  curl localhost:8080/openapi.json\n" ++
            "\n" ++
            "LEAGUES\n" ++
            "  ",
    );
    for (core.leagues.all, 0..) |league, i| {
        if (i > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(league.slug);
    }
    try out.writer.writeAll("\n");
    return out.toOwnedSlice();
}
pub fn docsHtml(allocator: std.mem.Allocator) ![]u8 {
    return z.docsHtml(allocator, .{
        .title = "sprts API",
        .spec_url = "/openapi.json",
    });
}

const std = @import("std");
const router = @import("router.zig");
const render = @import("render.zig");
const detail_view = @import("detail_view.zig");
const team_view = @import("team_view.zig");

test "spec emits all five JSON operations" {
    const doc = try openApiJson(std.testing.allocator);
    defer std.testing.allocator.free(doc);
    for ([_][]const u8{ "listLeagues", "getAll", "getScoreboard", "getGame", "getTeam", "getStandings" }) |id| {
        try std.testing.expect(std.mem.indexOf(u8, doc, id) != null);
    }
    for ([_][]const u8{ "LeagueList", "DigestJson", "Scoreboard", "DetailGame", "ScheduleTeamView", "LeagueStandings", "ErrorBody" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, doc, name) != null);
    }
    // Digest envelope is Scoreboard shapes plus the additive `degraded`
    // outage signal (see digest.DigestJson); nothing renamed or removed.
    for ([_][]const u8{ "\"date\"", "\"leagues\"", "\"schema_version\"", "\"degraded\"" }) |field| {
        try std.testing.expect(std.mem.indexOf(u8, doc, field) != null);
    }
}

test "llms.txt is plain agent surface with every operation" {
    const doc = try llmsTxt(std.testing.allocator);
    defer std.testing.allocator.free(doc);
    for ([_][]const u8{ "listLeagues", "getAll", "getScoreboard", "getGame", "getTeam", "getStandings" }) |id| {
        try std.testing.expect(std.mem.indexOf(u8, doc, id) != null);
    }
    for ([_][]const u8{ "curl localhost:8080/mlb", "?format=html", "/api/v1/", "/openapi.json", "/docs", "?color=0", "?width", "?height", "?0", "?date=", "?week", "?art=off", "digits", "mlb", "nfl", "Base URL" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, doc, token) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, doc, "\x1b") == null);
    _ = try std.unicode.Utf8View.init(doc);
    try std.testing.expect(router.parse("/llms.txt") == .llms);
    try std.testing.expect(router.parse("/llms.txt?color=0") == .llms);
}

test "docs page serves the Scalar UI pointed at the spec" {
    const page = try docsHtml(std.testing.allocator);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "/openapi.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "text/html") == null); // body, not headers
    try std.testing.expect(std.mem.indexOf(u8, page, "<html") != null);
}

test "served openapi.json parses and covers every JSON route" {
    // Drift guard: the document served at `/openapi.json` must parse and
    // must describe every `/api/v1/` JSON route the router serves.
    // Representative targets exercise each router shape; only the
    // `/api/v1/` spellings are JSON by address, the short ones by Accept.
    try std.testing.expect(router.parse("/api/v1/leagues") == .leagues);
    try std.testing.expect(router.parse("/api/v1/all?date=2026-09-06") == .all);
    try std.testing.expect(router.parse("/api/v1/mlb?date=2026-09-06") == .scoreboard);
    try std.testing.expect(router.parse("/api/v1/nfl?week=2") == .scoreboard);
    try std.testing.expect(router.parse("/api/v1/nfl?week=2").scoreboard.week.? == 2);
    try std.testing.expect(router.parse("/api/v1/mlb/401816828") == .game);
    try std.testing.expect(router.parse("/api/v1/mlb/PHI") == .team);
    try std.testing.expect(router.parse("/api/v1/nfl/standings") == .standings);
    try std.testing.expect(router.isJsonTarget("/api/v1/leagues"));
    try std.testing.expect(router.isJsonTarget("/api/v1/all?date=2026-09-06"));
    try std.testing.expect(router.isJsonTarget("/api/v1/mlb/401816828"));
    try std.testing.expect(router.isJsonTarget("/api/v1/mlb/PHI"));
    try std.testing.expect(router.isJsonTarget("/api/v1/nfl/standings"));
    try std.testing.expect(router.parse("/mlb/401816828") == .game);
    try std.testing.expectEqual(router.Format.json, router.formatFor("/mlb/401816828", "application/json"));

    const doc = try openApiJson(std.testing.allocator);
    defer std.testing.allocator.free(doc);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, doc, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;
    const Case = struct {
        path: []const u8,
        operation_id: []const u8,
        errors: []const []const u8,
    };
    const cases = [_]Case{
        .{ .path = "/api/v1/leagues", .operation_id = "listLeagues", .errors = &.{} },
        .{ .path = "/api/v1/all", .operation_id = "getAll", .errors = &.{"400"} },
        .{ .path = "/api/v1/{league}", .operation_id = "getScoreboard", .errors = &.{ "400", "404", "502" } },
        .{ .path = "/api/v1/{league}/{id}", .operation_id = "getGame", .errors = &.{ "404", "502" } },
        .{ .path = "/api/v1/{league}/{abbr}", .operation_id = "getTeam", .errors = &.{ "404", "502" } },
        .{ .path = "/api/v1/{league}/standings", .operation_id = "getStandings", .errors = &.{ "404", "502" } },
    };
    for (cases) |c| {
        try std.testing.expect(paths.get(c.path) != null);
        const get = paths.get(c.path).?.object.get("get").?.object;
        try std.testing.expectEqualStrings(c.operation_id, get.get("operationId").?.string);
        const responses = get.get("responses").?.object;
        try std.testing.expect(responses.get("200") != null);
        for (c.errors) |code| try std.testing.expect(responses.get(code) != null);
    }
    // The digest never 404s or 502s: one league's outage degrades to a
    // zero-game board entry, so only 400 (bad date) rides alongside 200.
    {
        const get = paths.get("/api/v1/all").?.object.get("get").?.object;
        const responses = get.get("responses").?.object;
        try std.testing.expect(responses.get("404") == null);
        try std.testing.expect(responses.get("502") == null);
    }
    // Scoreboard carries the optional integer `week` query param (strict
    // positive u16 in the router; ESPN honors it only for football).
    {
        const get = paths.get("/api/v1/{league}").?.object.get("get").?.object;
        const params = get.get("parameters").?.array;
        var saw_date = false;
        var saw_week = false;
        for (params.items) |item| {
            const name = item.object.get("name").?.string;
            const location = item.object.get("in").?.string;
            if (!std.mem.eql(u8, location, "query")) continue;
            if (std.mem.eql(u8, name, "date")) saw_date = true;
            if (std.mem.eql(u8, name, "week")) {
                saw_week = true;
                try std.testing.expectEqualStrings("query", location);
                try std.testing.expect(!item.object.get("required").?.bool);
                const schema = item.object.get("schema").?.object;
                try std.testing.expectEqualStrings("integer", schema.get("type").?.string);
            }
        }
        try std.testing.expect(saw_date);
        try std.testing.expect(saw_week);
    }
    // The digest is date-driven only: `week` must not appear on getAll.
    {
        const get = paths.get("/api/v1/all").?.object.get("get").?.object;
        const params = get.get("parameters").?.array;
        var saw_date = false;
        for (params.items) |item| {
            const name = item.object.get("name").?.string;
            try std.testing.expect(!std.mem.eql(u8, name, "week"));
            if (std.mem.eql(u8, name, "date")) saw_date = true;
        }
        try std.testing.expect(saw_date);
    }
    // Digest envelope shape: Scoreboard entries plus the additive outage
    // signal; per-league shapes stay verbatim.
    {
        const schemas = parsed.value.object.get("components").?.object.get("schemas").?.object;
        try std.testing.expect(schemas.get("DigestJson") != null);
        const props = schemas.get("DigestJson").?.object.get("properties").?.object;
        try std.testing.expect(props.get("schema_version") != null);
        try std.testing.expect(props.get("date") != null);
        try std.testing.expect(props.get("leagues") != null);
        try std.testing.expect(props.get("degraded") != null);
    }
    // The digest description documents the outage signal and the
    // zone/source contract, so /openapi.json pins them like /llms.txt.
    {
        const get = paths.get("/api/v1/all").?.object.get("get").?.object;
        const desc = get.get("description").?.string;
        for ([_][]const u8{ "degraded", "off-day", "UTC", "ET", "source" }) |token| {
            try std.testing.expect(std.mem.indexOf(u8, desc, token) != null);
        }
        const board_get = paths.get("/api/v1/{league}").?.object.get("get").?.object;
        const board_desc = board_get.get("description").?.string;
        for ([_][]const u8{ "UTC", "ET", "source" }) |token| {
            try std.testing.expect(std.mem.indexOf(u8, board_desc, token) != null);
        }
    }
}

test "all JSON renderers validate in one process" {
    // Regression guard for the zchema `cachedCompiled` cross-type cache
    // bug: strict per-type validation fails once Scoreboard, GameDetail,
    // and TeamView outputs are all validated in one process, so every
    // renderer shares `render.validatedJson`. Emit one of each here and
    // check the schema markers plus a distinguishing field.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{},
    };
    const board_json = try render.json(arena, board);
    try std.testing.expect(std.mem.indexOf(u8, board_json, "\"schema_version\": \"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_json, "\"source\": \"test\"") != null);

    const game: core.detail.GameDetail = .{
        .id = "401816828",
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .participants = &.{},
    };
    const game_json = try detail_view.json(arena, game);
    try std.testing.expect(std.mem.indexOf(u8, game_json, "\"schema_version\": \"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, game_json, "401816828") != null);

    const view: core.schedule.TeamView = .{
        .league = "mlb",
        .league_name = "MLB",
        .team = .{ .id = "22", .abbrev = "PHI", .name = "Philadelphia Phillies" },
    };
    const view_json = try team_view.renderJson(arena, view);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"schema_version\": \"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, view_json, "\"abbrev\": \"PHI\"") != null);

    const list_json = try render.leaguesJson(arena);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"schema_version\": \"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"slug\": \"mlb\"") != null);
}

test "llms.txt examples all route" {
    // Pin the doc to reality: every curl example path must parse to a real
    // route. The bare /api/v1/ empty-slug address is .not_found, so it must
    // never appear here again.
    const doc = try llmsTxt(std.testing.allocator);
    defer std.testing.allocator.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "localhost:8080/api/v1/\n") == null);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "curl ") == null) continue;
        const marker = std.mem.indexOf(u8, line, "localhost:8080") orelse continue;
        const path = std.mem.trim(u8, line[marker + "localhost:8080".len ..], " \t\r");
        if (path.len == 0) continue;
        count += 1;
        try std.testing.expect(router.parse(path) != .not_found);
    }
    try std.testing.expect(count >= 8);
    // Outage and zone/source contracts live in the agent surface too.
    for ([_][]const u8{ "degraded", "off-day", "UTC", "site.api.espn.com" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, doc, token) != null);
    }
}

test "series-tied lines never double the Series prefix" {
    // Fixture inputs are the exact strings the provider builders emit: the
    // schedule-derived path already speaks season-series language, while the
    // ESPN summary path passes playoff wording through verbatim. Detail
    // views prefix unconditionally, so only the first shape is clean.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base: core.detail.GameDetail = .{
        .id = "401816828",
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .participants = &.{},
    };
    var tied = base;
    tied.series = "Season series tied 1-1 (game 2 of 4)";
    const tied_text = try detail_view.renderText(arena, tied, false, null, null);
    try std.testing.expect(std.mem.indexOf(u8, tied_text, "Series: Season series tied 1-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, tied_text, "Series: Series") == null);
    // ESPN-verbatim playoff wording still doubles the prefix through the
    // unconditional "Series: " render; normalizing "Series tied ..." belongs
    // in provider.summarySeries (out of this lane), pinned here as the repro.
    var verbatim = base;
    verbatim.series = "Series tied 1-1 (game 2 of 4)";
    const verbatim_text = try detail_view.renderText(arena, verbatim, false, null, null);
    try std.testing.expect(std.mem.indexOf(u8, verbatim_text, "Series: Series tied 1-1") != null);
    // JSON carries the provider string with no prefix, so it never doubles.
    const verbatim_json = try detail_view.json(arena, verbatim);
    try std.testing.expect(std.mem.indexOf(u8, verbatim_json, "Series tied 1-1 (game 2 of 4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, verbatim_json, "Series: Series") == null);
    _ = try std.unicode.Utf8View.init(tied_text);
}
