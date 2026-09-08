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
        .description = "Multi-league digest for one date: one Scoreboard per league in league order; " ++
            "unavailable leagues render as zero-game boards (see digest.DigestJson). " ++
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
            "Pass ?week=N (strict positive integer; ESPN honors it only for football leagues, otherwise ignored).",
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
    // league's outage degrades to a zero-game board entry.
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
    for ([_][]const u8{ "listLeagues", "getAll", "getScoreboard", "getGame", "getTeam" }) |id| {
        try std.testing.expect(std.mem.indexOf(u8, doc, id) != null);
    }
    for ([_][]const u8{ "LeagueList", "DigestJson", "Scoreboard", "DetailGame", "ScheduleTeamView", "ErrorBody" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, doc, name) != null);
    }
    // Digest envelope reuses existing field names only (see digest.DigestJson).
    for ([_][]const u8{ "\"date\"", "\"leagues\"", "\"schema_version\"" }) |field| {
        try std.testing.expect(std.mem.indexOf(u8, doc, field) != null);
    }
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
    try std.testing.expect(router.isJsonTarget("/api/v1/leagues"));
    try std.testing.expect(router.isJsonTarget("/api/v1/all?date=2026-09-06"));
    try std.testing.expect(router.isJsonTarget("/api/v1/mlb/401816828"));
    try std.testing.expect(router.isJsonTarget("/api/v1/mlb/PHI"));
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
    // Digest envelope shape: existing field names only.
    {
        const schemas = parsed.value.object.get("components").?.object.get("schemas").?.object;
        try std.testing.expect(schemas.get("DigestJson") != null);
        const props = schemas.get("DigestJson").?.object.get("properties").?.object;
        try std.testing.expect(props.get("schema_version") != null);
        try std.testing.expect(props.get("date") != null);
        try std.testing.expect(props.get("leagues") != null);
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
