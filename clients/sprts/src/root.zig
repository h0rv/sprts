/// Hand-written wrapper over the generated sprts JSON API client.
///
/// `src/generated.zig` is produced by `tools/generate-sprts-client` from the
/// live `/openapi.json` document (single source of truth:
/// `apps/server/src/spec.zig`). Never hand-edit the generated file.
///
/// This module adds what the generator cannot: a portable `HttpTransport`
/// seam with an injectable fetch fn (tests inject a fake; no network), pure
/// URL builders mirroring the generated paths, and typed fetch fns that run
/// those URLs over any transport and return the generated types.
pub const gen = @import("generated.zig");
const std = @import("std");

pub const Client = gen.Client;
pub const ApiResult = gen.ApiResult;
pub const Owned = gen.Owned;
pub const RawResponse = gen.RawResponse;

pub const LeagueList = gen.LeagueList;
pub const DigestJson = gen.DigestJson;
pub const Scoreboard = gen.Scoreboard;
pub const DetailGame = gen.DetailGame;
pub const ScheduleTeamView = gen.ScheduleTeamView;
pub const LeagueStandings = gen.LeagueStandings;
pub const ErrorBody = gen.ErrorBody;

pub const listLeagues = gen.listLeagues;
pub const getAll = gen.getAll;
pub const getScoreboard = gen.getScoreboard;
pub const getGame = gen.getGame;
pub const getTeam = gen.getTeam;
pub const getStandings = gen.getStandings;

/// Production base URL (host only: generated paths already carry the
/// `/api/v1` prefix). Overridable per client via `withBaseUrl`; the CLI
/// layer reads `SPRTS_BASE_URL` and applies it there.
pub const default_base_url = "https://sprts.horv.co";

/// Client aimed at production. No API key: the public API needs none.
pub fn initClient(allocator: std.mem.Allocator, io: std.Io) Client {
    var client = Client.init(allocator, io, "");
    client.withBaseUrl(default_base_url);
    return client;
}

/// Pure URL builder for `listLeagues`: `{base}/api/v1/leagues`.
pub fn buildLeaguesUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/api/v1/leagues", .{base_url});
}

/// Pure URL builder for `getAll`: `{base}/api/v1/all[?date=]`.
pub fn buildAllUrl(allocator: std.mem.Allocator, base_url: []const u8, date: ?[]const u8) ![]u8 {
    var url: std.Io.Writer.Allocating = .init(allocator);
    defer url.deinit();
    try url.writer.print("{s}/api/v1/all", .{base_url});
    var first = true;
    try query(&url.writer, &first, "date", date);
    return url.toOwnedSlice();
}

/// Pure URL builder for `getScoreboard`: `{base}/api/v1/{league}[?date=][&week=]`.
/// Mirrors the generated query order (`date`, then `week`). The `stream`
/// param is SSE-only (text feed, no JSON shape) so the JSON client omits it.
pub fn buildScoreboardUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    league: []const u8,
    date: ?[]const u8,
    week: ?i64,
) ![]u8 {
    var url: std.Io.Writer.Allocating = .init(allocator);
    defer url.deinit();
    try url.writer.print("{s}/api/v1/{s}", .{ base_url, league });
    var first = true;
    try query(&url.writer, &first, "date", date);
    try queryInt(&url.writer, &first, "week", week);
    return url.toOwnedSlice();
}

/// Pure URL builder for `getGame`: `{base}/api/v1/{league}/{id}` (id digits only).
pub fn buildGameUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    league: []const u8,
    id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/api/v1/{s}/{s}", .{ base_url, league, id });
}

/// Pure URL builder for `getTeam`: `{base}/api/v1/{league}/{abbr}`.
pub fn buildTeamUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    league: []const u8,
    abbr: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/api/v1/{s}/{s}", .{ base_url, league, abbr });
}

/// Pure URL builder for `getStandings`: `{base}/api/v1/{league}/standings`.
pub fn buildStandingsUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    league: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/api/v1/{s}/standings", .{ base_url, league });
}

/// Portable fetch result. `body` is owned by the caller-provided arena.
pub const FetchResult = struct {
    status: std.http.Status,
    body: []u8,
};

/// Portable transport seam. Tests inject a fake with a canned body (no
/// network); a future live transport implements the same interface without
/// touching callers. `body` is allocated in `arena`.
pub const HttpTransport = struct {
    ptr: *anyopaque,
    fetchFn: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) anyerror!FetchResult,

    pub fn fetch(
        self: HttpTransport,
        arena: std.mem.Allocator,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !FetchResult {
        return self.fetchFn(self.ptr, arena, url, extra_headers);
    }
};

pub const accept_json_value = "application/json";
pub const default_headers: []const std.http.Header = &.{.{ .name = "accept", .value = accept_json_value }};

/// Typed fetch over any transport returning the generated types. Each builds
/// its URL with the matching builder, fetches over `transport`, and parses
/// the body with the generated `parseRawResponse` (non-2xx surfaces as
/// `.api_error`, bad JSON as `.parse_error`).

pub fn fetchLeagues(
    arena: std.mem.Allocator,
    transport: HttpTransport,
    base_url: []const u8,
) !ApiResult(LeagueList) {
    const url = try buildLeaguesUrl(arena, base_url);
    const res = try transport.fetch(arena, url, default_headers);
    return gen.parseRawResponse(LeagueList, .{ .allocator = arena, .status = res.status, .body = res.body });
}

pub fn fetchAll(
    arena: std.mem.Allocator,
    transport: HttpTransport,
    base_url: []const u8,
    date: ?[]const u8,
) !ApiResult(DigestJson) {
    const url = try buildAllUrl(arena, base_url, date);
    const res = try transport.fetch(arena, url, default_headers);
    return gen.parseRawResponse(DigestJson, .{ .allocator = arena, .status = res.status, .body = res.body });
}

pub fn fetchScoreboard(
    arena: std.mem.Allocator,
    transport: HttpTransport,
    base_url: []const u8,
    league: []const u8,
    date: ?[]const u8,
    week: ?i64,
) !ApiResult(Scoreboard) {
    const url = try buildScoreboardUrl(arena, base_url, league, date, week);
    const res = try transport.fetch(arena, url, default_headers);
    return gen.parseRawResponse(Scoreboard, .{ .allocator = arena, .status = res.status, .body = res.body });
}

pub fn fetchGame(
    arena: std.mem.Allocator,
    transport: HttpTransport,
    base_url: []const u8,
    league: []const u8,
    id: []const u8,
) !ApiResult(DetailGame) {
    const url = try buildGameUrl(arena, base_url, league, id);
    const res = try transport.fetch(arena, url, default_headers);
    return gen.parseRawResponse(DetailGame, .{ .allocator = arena, .status = res.status, .body = res.body });
}

pub fn fetchTeam(
    arena: std.mem.Allocator,
    transport: HttpTransport,
    base_url: []const u8,
    league: []const u8,
    abbr: []const u8,
) !ApiResult(ScheduleTeamView) {
    const url = try buildTeamUrl(arena, base_url, league, abbr);
    const res = try transport.fetch(arena, url, default_headers);
    return gen.parseRawResponse(ScheduleTeamView, .{ .allocator = arena, .status = res.status, .body = res.body });
}

pub fn fetchStandings(
    arena: std.mem.Allocator,
    transport: HttpTransport,
    base_url: []const u8,
    league: []const u8,
) !ApiResult(LeagueStandings) {
    const url = try buildStandingsUrl(arena, base_url, league);
    const res = try transport.fetch(arena, url, default_headers);
    return gen.parseRawResponse(LeagueStandings, .{ .allocator = arena, .status = res.status, .body = res.body });
}

fn query(writer: *std.Io.Writer, first: *bool, name: []const u8, value: ?[]const u8) !void {
    const actual = value orelse return;
    try separator(writer, first);
    try writer.print("{s}={s}", .{ name, actual });
}

fn queryInt(writer: *std.Io.Writer, first: *bool, name: []const u8, value: ?i64) !void {
    const actual = value orelse return;
    try separator(writer, first);
    try writer.print("{s}={d}", .{ name, actual });
}

fn separator(writer: *std.Io.Writer, first: *bool) !void {
    try writer.writeByte(if (first.*) '?' else '&');
    first.* = false;
}

test {
    _ = gen;
}

test "URL builders mirror the /api/v1 paths" {
    const base = "https://sprts.horv.co";
    const leagues = try buildLeaguesUrl(std.testing.allocator, base);
    defer std.testing.allocator.free(leagues);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/leagues", leagues);

    const game = try buildGameUrl(std.testing.allocator, base, "mlb", "401816828");
    defer std.testing.allocator.free(game);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/mlb/401816828", game);

    const team = try buildTeamUrl(std.testing.allocator, base, "mlb", "PHI");
    defer std.testing.allocator.free(team);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/mlb/PHI", team);

    const standings = try buildStandingsUrl(std.testing.allocator, base, "nfl");
    defer std.testing.allocator.free(standings);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/nfl/standings", standings);
}

test "scoreboard and digest builders carry date and week" {
    const base = "https://sprts.horv.co";
    const dated = try buildScoreboardUrl(std.testing.allocator, base, "mlb", "2026-09-06", null);
    defer std.testing.allocator.free(dated);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/mlb?date=2026-09-06", dated);

    const week = try buildScoreboardUrl(std.testing.allocator, base, "nfl", null, 2);
    defer std.testing.allocator.free(week);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/nfl?week=2", week);

    const bare = try buildScoreboardUrl(std.testing.allocator, base, "nba", null, null);
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/nba", bare);

    const all = try buildAllUrl(std.testing.allocator, base, "2026-09-06");
    defer std.testing.allocator.free(all);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/all?date=2026-09-06", all);

    const all_bare = try buildAllUrl(std.testing.allocator, base, null);
    defer std.testing.allocator.free(all_bare);
    try std.testing.expectEqualStrings("https://sprts.horv.co/api/v1/all", all_bare);
}

test "generated output keeps the six operation IDs" {
    // Drift guard: regenerating from /openapi.json must keep the six
    // operations the wrapper (builders + fetch fns) is written against.
    const source = @embedFile("generated.zig");
    for ([_][]const u8{
        "pub fn listLeagues",
        "pub fn getAll",
        "pub fn getScoreboard",
        "pub fn getGame",
        "pub fn getTeam",
        "pub fn getStandings",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, source, needle) != null);
    }
}

test "initClient defaults to the production base URL" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var client = initClient(std.testing.allocator, io);
    defer client.deinit();
    try std.testing.expectEqualStrings(default_base_url, client.base_url);
    client.withBaseUrl("http://localhost:8080");
    try std.testing.expectEqualStrings("http://localhost:8080", client.base_url);
}

const FakeTransportState = struct {
    seen_url: ?[]const u8 = null,
    body: []const u8,
    status: std.http.Status = .ok,

    fn dispatch(ptr: *anyopaque, arena: std.mem.Allocator, url: []const u8, extra_headers: []const std.http.Header) anyerror!FetchResult {
        _ = extra_headers;
        const self: *FakeTransportState = @ptrCast(@alignCast(ptr));
        self.seen_url = try arena.dupe(u8, url);
        return .{ .status = self.status, .body = try arena.dupe(u8, self.body) };
    }

    fn asTransport(self: *FakeTransportState) HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

test "fetchScoreboard parses canned JSON without network" {
    const canned =
        \\{"schema_version":"1","league":"mlb","league_name":"MLB","date":"2026-09-06","source":"test","games":[]}
    ;
    var fake = FakeTransportState{ .body = canned };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var result = try fetchScoreboard(arena, fake.asTransport(), "https://example.test", "mlb", "2026-09-06", null);
    defer result.deinit();
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb?date=2026-09-06", fake.seen_url.?);
    switch (result) {
        .ok => |*ok| {
            try std.testing.expectEqualStrings("mlb", ok.value().league);
            try std.testing.expectEqualStrings("2026-09-06", ok.value().date);
            try std.testing.expectEqual(@as(usize, 0), ok.value().games.len);
        },
        else => return error.ExpectedOk,
    }
}

test "fetchLeagues surfaces api_error on non-200" {
    var fake = FakeTransportState{ .body = "{}", .status = .not_found };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var result = try fetchLeagues(arena, fake.asTransport(), "https://example.test");
    defer result.deinit();
    try std.testing.expectEqualStrings("https://example.test/api/v1/leagues", fake.seen_url.?);
    try std.testing.expect(result == .api_error);
}
