const std = @import("std");
const core = @import("sprts_core");
const espn = @import("espn_client");

pub const ClockFn = *const fn (io: std.Io) i64;

fn realClock(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

pub const EspnAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8 = "https://site.api.espn.com/apis/site/v2",
    transport: ?espn.HttpTransport = null,
    clock: ClockFn = realClock,
    /// Upstream deadline in milliseconds for the built-in `StdTransport`
    /// (a hung ESPN fails with `error.Timeout` into the stale path / 502
    /// instead of hanging the connection). Injected `transport` fakes
    /// ignore it. Zero disables the watchdog.
    upstream_timeout_ms: u64 = 5000,

    pub fn today(self: EspnAdapter, arena: std.mem.Allocator) ![]u8 {
        return core.date.todayFromEpoch(arena, self.clock(self.io));
    }

    /// `week` threads into the ESPN `week=` query param (football honors
    /// it; most sports ignore it). Null is the default date-driven board
    /// and preserves the historical call shape.
    pub fn fetch(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8) !core.domain.Scoreboard {
        return self.fetchWeek(arena, league, day, null);
    }

    pub fn fetchWeek(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8, week: ?u16) !core.domain.Scoreboard {
        const endpoint = endpointFor(league.slug) orelse return error.UnsupportedLeague;
        const compact_day = try core.date.compact(arena, day);
        const week_int: ?i64 = if (week) |w| @intCast(w) else null;
        const url = try espn.buildScoreboardUrl(arena, self.base_url, endpoint.sport, endpoint.league, compact_day, week_int, null, null);
        var status: std.http.Status = undefined;
        var body: []const u8 = undefined;
        if (self.transport) |transport| {
            const result = try transport.fetch(arena, url, espn.default_headers);
            status = result.status;
            body = result.body;
        } else {
            var std_transport = espn.StdTransport{ .allocator = self.allocator, .io = self.io, .timeout_ms = self.upstream_timeout_ms };
            const result = try std_transport.fetch(arena, url, espn.default_headers);
            status = result.status;
            body = result.body;
        }
        if (status != .ok) {
            std.log.warn("ESPN returned HTTP {d}", .{@intFromEnum(status)});
            return error.UpstreamResponse;
        }
        return parseAndNormalize(arena, league, day, body);
    }

    pub fn fetchDetail(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, game_id: []const u8) !core.detail.GameDetail {
        return detailFetch(self, arena, league, game_id);
    }

    /// Fetch every league's board for one day, one thread per league.
    /// Threads share only self (the allocator must be thread-safe; the
    /// GPA is) and write only their own slot. On targets without threads
    /// each fetch runs inline. Board memory lives in per-league stores;
    /// call releaseAll once the rendered page no longer needs the boards.
    pub fn fetchAll(self: EspnAdapter, arena: std.mem.Allocator, day: []const u8) ![]LeagueResult {
        const results = try arena.alloc(LeagueResult, core.leagues.all.len);
        const slots = try arena.alloc(?std.Thread, core.leagues.all.len);
        @memset(slots, null);
        for (&core.leagues.all, 0..) |*league, i| {
            results[i] = .{ .league = league };
            const store = try arena.create(std.heap.ArenaAllocator);
            store.* = std.heap.ArenaAllocator.init(self.allocator);
            results[i].store = store;
            const args = try arena.create(FetchArgs);
            args.* = .{ .adapter = self, .league = league, .day = day, .slot = &results[i] };
            if (comptime builtin.single_threaded) {
                fetchOne(args);
            } else {
                slots[i] = std.Thread.spawn(.{}, fetchOne, .{args}) catch null;
                if (slots[i] == null) fetchOne(args);
            }
        }
        for (slots) |maybe| if (maybe) |t| t.join();
        return results;
    }

    pub fn releaseAll(results: []LeagueResult) void {
        for (results) |result| if (result.store) |store| store.deinit();
    }
};

/// One league's board for the home page. A null board means the fetch
/// failed; the league renders as a plain link, so one ESPN outage
/// never fails the page.
pub const LeagueResult = struct {
    league: *const core.leagues.League,
    board: ?core.domain.Scoreboard = null,
    store: ?*std.heap.ArenaAllocator = null,
};

const builtin = @import("builtin");

const FetchArgs = struct {
    adapter: EspnAdapter,
    league: *const core.leagues.League,
    day: []const u8,
    slot: *LeagueResult,
};

fn fetchOne(args: *const FetchArgs) void {
    const store = args.slot.store orelse return;
    args.slot.board = args.adapter.fetch(store.allocator(), args.league, args.day) catch null;
}

const Endpoint = struct { sport: []const u8, league: []const u8 };
const endpoints = [_]struct { slug: []const u8, endpoint: Endpoint }{
    .{ .slug = "nfl", .endpoint = .{ .sport = "football", .league = "nfl" } },
    .{ .slug = "ncaaf", .endpoint = .{ .sport = "football", .league = "college-football" } },
    .{ .slug = "nba", .endpoint = .{ .sport = "basketball", .league = "nba" } },
    .{ .slug = "wnba", .endpoint = .{ .sport = "basketball", .league = "wnba" } },
    .{ .slug = "ncaam", .endpoint = .{ .sport = "basketball", .league = "mens-college-basketball" } },
    .{ .slug = "ncaaw", .endpoint = .{ .sport = "basketball", .league = "womens-college-basketball" } },
    .{ .slug = "mlb", .endpoint = .{ .sport = "baseball", .league = "mlb" } },
    .{ .slug = "nhl", .endpoint = .{ .sport = "hockey", .league = "nhl" } },
    .{ .slug = "mls", .endpoint = .{ .sport = "soccer", .league = "usa.1" } },
    .{ .slug = "epl", .endpoint = .{ .sport = "soccer", .league = "eng.1" } },
    .{ .slug = "laliga", .endpoint = .{ .sport = "soccer", .league = "esp.1" } },
    .{ .slug = "bundesliga", .endpoint = .{ .sport = "soccer", .league = "ger.1" } },
    .{ .slug = "seriea", .endpoint = .{ .sport = "soccer", .league = "ita.1" } },
    .{ .slug = "ligue1", .endpoint = .{ .sport = "soccer", .league = "fra.1" } },
    .{ .slug = "ucl", .endpoint = .{ .sport = "soccer", .league = "uefa.champions" } },
    .{ .slug = "atp", .endpoint = .{ .sport = "tennis", .league = "atp" } },
    .{ .slug = "wta", .endpoint = .{ .sport = "tennis", .league = "wta" } },
    .{ .slug = "f1", .endpoint = .{ .sport = "racing", .league = "f1" } },
    .{ .slug = "ufc", .endpoint = .{ .sport = "mma", .league = "ufc" } },
    .{ .slug = "pga", .endpoint = .{ .sport = "golf", .league = "pga" } },
};

fn endpointFor(slug: []const u8) ?Endpoint {
    for (endpoints) |entry| if (std.mem.eql(u8, entry.slug, slug)) return entry.endpoint;
    return null;
}

const ScoreboardResponse = struct {
    events: []const Event = &.{},
};

const Event = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    shortName: []const u8 = "",
    date: []const u8 = "",
    status: ?Status = null,
    competitions: []const Competition = &.{},
};

const Status = struct { type: StatusType = .{} };
const StatusType = struct {
    state: []const u8 = "pre",
    shortDetail: []const u8 = "Scheduled",
    description: []const u8 = "Scheduled",
};
const Competition = struct {
    id: []const u8 = "",
    date: []const u8 = "",
    status: ?Status = null,
    competitors: []const Competitor = &.{},
};
const Competitor = struct {
    id: []const u8 = "",
    order: i64 = 0,
    homeAway: []const u8 = "",
    score: []const u8 = "",
    winner: bool = false,
    team: ?Team = null,
    athlete: ?Athlete = null,
    records: []const Record = &.{},
};
const Record = struct {
    type: []const u8 = "",
    summary: []const u8 = "",
};
const Team = struct {
    id: []const u8 = "",
    displayName: []const u8 = "Unknown",
    name: []const u8 = "Unknown",
    abbreviation: []const u8 = "?",
};
const Athlete = struct {
    displayName: []const u8 = "Unknown",
    fullName: []const u8 = "Unknown",
    shortName: []const u8 = "?",
};
const Identity = struct {
    id: []const u8,
    name: []const u8,
    abbreviation: []const u8,
};

pub fn parseAndNormalize(arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8, body: []const u8) !core.domain.Scoreboard {
    const response = try std.json.parseFromSliceLeaky(ScoreboardResponse, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    var games: std.ArrayList(core.domain.Game) = .empty;
    for (response.events) |event| {
        for (event.competitions, 0..) |competition, competition_index| {
            var participants: std.ArrayList(core.domain.Participant) = .empty;
            for (competition.competitors) |competitor| {
                const identity: Identity = identity: {
                    if (competitor.team) |team| break :identity Identity{
                        .id = team.id,
                        .name = if (team.displayName.len > 0) team.displayName else team.name,
                        .abbreviation = team.abbreviation,
                    };
                    if (competitor.athlete) |athlete| break :identity Identity{
                        .id = competitor.id,
                        .name = if (athlete.displayName.len > 0) athlete.displayName else athlete.fullName,
                        .abbreviation = "",
                    };
                    continue;
                };
                const record: ?[]const u8 = record: {
                    for (competitor.records) |r| {
                        if (std.mem.eql(u8, r.type, "total") and r.summary.len > 0) break :record r.summary;
                    }
                    break :record null;
                };
                const score = if (competitor.score.len > 0)
                    competitor.score
                else if (competition.competitors.len > 2 and competitor.order > 0)
                    try std.fmt.allocPrint(arena, "#{d}", .{competitor.order})
                else
                    "";
                try participants.append(arena, .{
                    .id = identity.id,
                    .name = identity.name,
                    .abbreviation = identity.abbreviation,
                    .score = score,
                    .winner = competitor.winner,
                    .home_away = if (competitor.homeAway.len > 0) competitor.homeAway else null,
                    .record = record,
                });
            }
            const status_type = if (competition.status) |status|
                status.type
            else if (event.status) |status|
                status.type
            else
                StatusType{};
            const game_id = if (competition.id.len > 0) competition.id else if (competition_index == 0) event.id else try std.fmt.allocPrint(arena, "{s}-{d}", .{ event.id, competition_index });
            try games.append(arena, .{
                .id = game_id,
                .name = if (event.name.len > 0) event.name else event.shortName,
                .starts_at = if (competition.date.len > 0) competition.date else event.date,
                .state = status_type.state,
                .status = if (status_type.shortDetail.len > 0) status_type.shortDetail else status_type.description,
                .participants = try participants.toOwnedSlice(arena),
            });
        }
    }
    return .{
        .league = league.slug,
        .league_name = league.name,
        .date = try copy(arena, day),
        .source = "site.api.espn.com",
        .games = try games.toOwnedSlice(arena),
    };
}

fn copy(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    return arena.dupe(u8, value);
}

test "every public league has an ESPN endpoint mapping" {
    for (core.leagues.all) |league| try std.testing.expect(endpointFor(league.slug) != null);
}

test "raw ESPN response is normalized without depending on unrelated fields" {
    const fixture =
        \\{"ignored":"value","events":[{"id":"401","name":"Away at Home","date":"2026-09-06T17:00Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"competitors":[{"homeAway":"away","score":"2","winner":false,"team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"homeAway":"home","score":"5","winner":true,"team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const board = try parseAndNormalize(arena_state.allocator(), core.leagues.find("mlb").?, "2026-09-06", fixture);
    try std.testing.expectEqual(@as(usize, 1), board.games.len);
    try std.testing.expectEqualStrings("Home", board.games[0].participants[1].name);
    try std.testing.expect(board.games[0].participants[1].winner);
}

test "athlete competitors use full names with no abbreviation" {
    const fixture =
        \\{"events":[{"id":"600057442","name":"Pirelli Italian Grand Prix","date":"2026-09-04T10:30Z","competitions":[{"id":"401839098","date":"2026-09-04T10:30Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"5498","order":1,"winner":false,"athlete":{"displayName":"Charles Leclerc","fullName":"Charles Leclerc","shortName":"C. Leclerc"}},{"id":"868","order":2,"winner":true,"athlete":{"displayName":"Lewis Hamilton","fullName":"Lewis Hamilton","shortName":"L. Hamilton"}}]}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const board = try parseAndNormalize(arena_state.allocator(), core.leagues.find("f1").?, "2026-09-06", fixture);
    try std.testing.expectEqual(@as(usize, 1), board.games.len);
    try std.testing.expectEqual(@as(usize, 2), board.games[0].participants.len);
    try std.testing.expectEqualStrings("Charles Leclerc", board.games[0].participants[0].name);
    try std.testing.expectEqualStrings("", board.games[0].participants[0].abbreviation);
    try std.testing.expectEqualStrings("Lewis Hamilton", board.games[0].participants[1].name);
    try std.testing.expectEqualStrings("", board.games[0].participants[1].abbreviation);
    try std.testing.expect(board.games[0].participants[1].winner);
}

test "competitor records normalize the total summary" {
    const fixture =
        \\{"events":[{"id":"401","name":"Away at Home","date":"2026-09-06T17:00Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"competitors":[{"homeAway":"away","score":"2","winner":false,"team":{"id":"a","displayName":"Away","abbreviation":"AWY"},"records":[{"name":"overall","type":"total","summary":"69-74"},{"name":"Home","type":"home","summary":"36-38"}]},{"homeAway":"home","score":"5","winner":true,"team":{"id":"h","displayName":"Home","abbreviation":"HME"},"records":[{"name":"Home","type":"home","summary":"40-30"}]}]}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const board = try parseAndNormalize(arena_state.allocator(), core.leagues.find("mlb").?, "2026-09-06", fixture);
    try std.testing.expectEqualStrings("69-74", board.games[0].participants[0].record.?);
    try std.testing.expect(board.games[0].participants[1].record == null);
    // Team identities keep their abbreviations.
    try std.testing.expectEqualStrings("AWY", board.games[0].participants[0].abbreviation);
}

const FakeTransportState = struct {
    seen_url: ?[]const u8 = null,
    body: []const u8,
    status: std.http.Status = .ok,

    fn dispatch(ptr: *anyopaque, arena: std.mem.Allocator, url: []const u8, extra_headers: []const std.http.Header) anyerror!espn.FetchResult {
        _ = extra_headers;
        const self: *FakeTransportState = @ptrCast(@alignCast(ptr));
        self.seen_url = try arena.dupe(u8, url);
        return .{ .status = self.status, .body = try arena.dupe(u8, self.body) };
    }

    fn asTransport(self: *FakeTransportState) espn.HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

fn fakeClock(_: std.Io) i64 {
    return 1788739200; // 2026-09-07T00:00:00Z
}

test "EspnAdapter accepts injected transport and clock" {
    const fixture =
        \\{"events":[]}
    ;
    var fake = FakeTransportState{ .body = fixture };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const test_io = threaded.io();
    const adapter = EspnAdapter{
        .allocator = std.testing.allocator,
        .io = test_io,
        .base_url = "https://example.test/base",
        .transport = fake.asTransport(),
        .clock = fakeClock,
    };
    const day = try adapter.today(arena);
    try std.testing.expectEqualStrings("2026-09-07", day);
    const board = try adapter.fetch(arena, core.leagues.find("mlb").?, "2026-09-06");
    try std.testing.expectEqualStrings("mlb", board.league);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/baseball/mlb/scoreboard?dates=20260906",
        fake.seen_url.?,
    );
}

test "fetchWeek threads week into the scoreboard URL, null preserves behavior" {
    var fake = FakeTransportState{ .body = "{\"events\":[]}" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const adapter = EspnAdapter{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
        .base_url = "https://example.test/base",
        .transport = fake.asTransport(),
        .clock = fakeClock,
    };
    _ = try adapter.fetchWeek(arena, core.leagues.find("nfl").?, "2026-09-06", 2);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?dates=20260906&week=2",
        fake.seen_url.?,
    );
    _ = try adapter.fetchWeek(arena, core.leagues.find("nfl").?, "2026-09-06", null);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?dates=20260906",
        fake.seen_url.?,
    );
}

/// Shared-nothing fake: safe to call from fetchAll worker threads.
const StaticTransport = struct {
    body: []const u8,

    fn dispatch(ptr: *anyopaque, arena: std.mem.Allocator, url: []const u8, extra_headers: []const std.http.Header) anyerror!espn.FetchResult {
        _ = url;
        _ = extra_headers;
        const self: *StaticTransport = @ptrCast(@alignCast(ptr));
        return .{ .status = .ok, .body = try arena.dupe(u8, self.body) };
    }

    fn asTransport(self: *StaticTransport) espn.HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

const FailingTransport = struct {
    fn dispatch(ptr: *anyopaque, arena: std.mem.Allocator, url: []const u8, extra_headers: []const std.http.Header) anyerror!espn.FetchResult {
        _ = ptr;
        _ = arena;
        _ = url;
        _ = extra_headers;
        return error.Boom;
    }

    fn asTransport(self: *FailingTransport) espn.HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

test "fetchAll resolves every league in one call" {
    var fake = StaticTransport{ .body = "{\"events\":[]}" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const adapter = EspnAdapter{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
        .base_url = "https://example.test/base",
        .transport = fake.asTransport(),
        .clock = fakeClock,
    };
    const results = try adapter.fetchAll(arena, "2026-09-06");
    defer EspnAdapter.releaseAll(results);
    try std.testing.expectEqual(core.leagues.all.len, results.len);
    for (results, 0..) |result, i| {
        try std.testing.expectEqualStrings(core.leagues.all[i].slug, result.league.slug);
        try std.testing.expect(result.board != null);
        try std.testing.expectEqual(@as(usize, 0), result.board.?.games.len);
    }
}

test "fetchAll degrades to null boards instead of failing" {
    var fake = FailingTransport{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const adapter = EspnAdapter{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
        .base_url = "https://example.test/base",
        .transport = fake.asTransport(),
        .clock = fakeClock,
    };
    const results = try adapter.fetchAll(arena, "2026-09-06");
    defer EspnAdapter.releaseAll(results);
    try std.testing.expectEqual(core.leagues.all.len, results.len);
    for (results) |result| try std.testing.expect(result.board == null);
}

// --- Game detail (wt-detail). Appended; existing scoreboard code above is untouched. ---
//
// fetchDetail mirrors the scoreboard path: fetch the per-event summary,
// derive the game date from header.competitions[0].date, re-fetch that date's
// board through the existing fetch path, locate the game by id
// (error.GameNotFound), then enrich the board row with summary-only fields.
// Every fetch honors the injected transport with a StdTransport fallback, so
// the curl UA workaround applies on all paths.

const SummaryResponse = struct {
    header: ?SummaryHeader = null,
    plays: ?[]const SummaryPlay = null,
    boxscore: ?SummaryBoxscore = null,
    gameInfo: ?SummaryGameInfo = null,
    seasonseries: ?[]const SummarySeries = null,
};

const SummaryHeader = struct {
    competitions: []const SummaryCompetition = &.{},
};

const SummaryCompetition = struct {
    id: []const u8 = "",
    date: []const u8 = "",
    status: ?SummaryStatus = null,
    competitors: []const SummaryCompetitor = &.{},
    series: ?[]const SummarySeries = null,
    situation: ?SummarySituation = null,
};

const SummaryStatus = struct {
    type: SummaryStatusType = .{},
    featuredAthletes: []const SummaryFeatured = &.{},
};

const SummaryStatusType = struct {
    state: []const u8 = "pre",
    shortDetail: []const u8 = "Scheduled",
    description: []const u8 = "Scheduled",
};

const SummaryFeatured = struct {
    name: []const u8 = "",
    athlete: ?SummaryAthlete = null,
};

const SummaryAthlete = struct {
    displayName: []const u8 = "",
    fullName: []const u8 = "",
};

const SummaryCompetitor = struct {
    id: []const u8 = "",
    homeAway: []const u8 = "",
    winner: bool = false,
    score: std.json.Value = .null,
    hits: std.json.Value = .null,
    errors: std.json.Value = .null,
    team: ?SummaryTeam = null,
    linescores: []const SummaryLinescore = &.{},
    record: []const SummaryRecord = &.{},
    probables: []const SummaryProbable = &.{},
};

const SummaryTeam = struct {
    id: []const u8 = "",
    displayName: []const u8 = "Unknown",
    abbreviation: []const u8 = "?",
};

const SummaryLinescore = struct {
    displayValue: std.json.Value = .null,
};

const SummaryRecord = struct {
    type: []const u8 = "",
    summary: []const u8 = "",
};

const SummaryProbable = struct {
    athlete: ?SummaryAthlete = null,
};

const SummarySituation = struct {
    balls: ?i64 = null,
    strikes: ?i64 = null,
    outs: ?i64 = null,
    onFirst: ?std.json.Value = null,
    onSecond: ?std.json.Value = null,
    onThird: ?std.json.Value = null,
    pitcher: ?std.json.Value = null,
    batter: ?std.json.Value = null,
    lastPlay: ?std.json.Value = null,
};

const SummaryPlay = struct {
    text: []const u8 = "",
    scoringPlay: bool = false,
    awayScore: std.json.Value = .null,
    homeScore: std.json.Value = .null,
    period: ?SummaryPeriod = null,
    pitchCount: ?SummaryCount = null,
    resultCount: ?SummaryCount = null,
    outs: ?i64 = null,
    onFirst: ?std.json.Value = null,
    onSecond: ?std.json.Value = null,
    onThird: ?std.json.Value = null,
    participants: []const SummaryPlayParticipant = &.{},
};

const SummaryPeriod = struct {
    displayValue: []const u8 = "",
};

const SummaryCount = struct {
    balls: ?i64 = null,
    strikes: ?i64 = null,
};

const SummaryPlayParticipant = struct {
    type: []const u8 = "",
    athlete: ?SummaryIdRef = null,
};

const SummaryIdRef = struct {
    id: std.json.Value = .null,
};

fn refId(ref: ?SummaryIdRef) ?[]const u8 {
    const value = (ref orelse return null).id;
    return switch (value) {
        .string, .number_string => |text| text,
        else => null,
    };
}

const SummaryBoxscore = struct {
    teams: []const SummaryBoxTeam = &.{},
    players: []const SummaryPlayerGroup = &.{},
};

const SummaryBoxTeam = struct {
    team: ?SummaryTeam = null,
    statistics: []const SummaryTeamStats = &.{},
};

const SummaryTeamStats = struct {
    name: []const u8 = "",
    displayName: []const u8 = "",
    stats: []const SummaryTeamStat = &.{},
};

const SummaryTeamStat = struct {
    name: []const u8 = "",
    displayName: []const u8 = "",
    displayValue: std.json.Value = .null,
};

const SummaryPlayerGroup = struct {
    team: ?SummaryTeam = null,
    statistics: []const SummaryPlayerStats = &.{},
};

const SummaryPlayerStats = struct {
    names: []const []const u8 = &.{},
    totals: []const std.json.Value = &.{},
    athletes: []const SummaryPlayerAthlete = &.{},
};

const SummaryPlayerAthlete = struct {
    athlete: ?SummaryAthleteId = null,
    stats: []const std.json.Value = &.{},
};

const SummaryAthleteId = struct {
    id: []const u8 = "",
    displayName: []const u8 = "",
    fullName: []const u8 = "",
};

const SummaryGameInfo = struct {
    attendance: std.json.Value = .null,
    venue: ?SummaryVenue = null,
};

const SummaryVenue = struct {
    fullName: []const u8 = "",
};

const SummarySeries = struct {
    summary: []const u8 = "",
    completed: bool = false,
    totalCompetitions: i64 = 0,
    events: []const SummarySeriesEvent = &.{},
};

const SummarySeriesEvent = struct {
    id: []const u8 = "",
};

const SeriesScheduleResponse = struct {
    events: []const SeriesScheduleEvent = &.{},
};

const SeriesScheduleEvent = struct {
    id: []const u8 = "",
    competitions: []const SeriesScheduleCompetition = &.{},
};

const SeriesScheduleCompetition = struct {
    competitors: []const SeriesScheduleCompetitor = &.{},
};

const SeriesScheduleCompetitor = struct {
    winner: bool = false,
    team: ?SummaryTeam = null,
};

/// Scalar or string JSON leaf as text. Numbers (ESPN scores, hits, attendance)
/// render as decimal; null and aggregates yield null.
fn jsonText(arena: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |s| s,
        .number_string => |s| s,
        .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        .array, .object => null,
    };
}

fn valuePresent(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return switch (v) {
        .null => false,
        .bool => |b| b,
        else => true,
    };
}

fn adapterFetchUrl(self: EspnAdapter, arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    var status: std.http.Status = undefined;
    var body: []const u8 = undefined;
    if (self.transport) |transport| {
        const result = try transport.fetch(arena, url, espn.default_headers);
        status = result.status;
        body = result.body;
    } else {
        var std_transport = espn.StdTransport{ .allocator = self.allocator, .io = self.io, .timeout_ms = self.upstream_timeout_ms };
        const result = try std_transport.fetch(arena, url, espn.default_headers);
        status = result.status;
        body = result.body;
    }
    if (status != .ok) {
        std.log.warn("ESPN returned HTTP {d}", .{@intFromEnum(status)});
        return error.UpstreamResponse;
    }
    return body;
}

fn findSummaryCompetitor(competitors: []const SummaryCompetitor, board_id: []const u8) ?SummaryCompetitor {
    for (competitors) |competitor| {
        if (competitor.team) |team| if (std.mem.eql(u8, team.id, board_id)) return competitor;
        if (competitor.id.len > 0 and std.mem.eql(u8, competitor.id, board_id)) return competitor;
    }
    return null;
}

fn summaryRecord(records: []const SummaryRecord) ?[]const u8 {
    for (records) |record| if (std.mem.eql(u8, record.type, "total") and record.summary.len > 0) return record.summary;
    for (records) |record| if (record.summary.len > 0) return record.summary;
    return null;
}

fn athleteName(athlete: ?SummaryAthlete) ?[]const u8 {
    const a = athlete orelse return null;
    if (a.displayName.len > 0) return a.displayName;
    if (a.fullName.len > 0) return a.fullName;
    return null;
}

/// Boxscore player lookup by ESPN athlete id (live plays only carry ids).
fn playerName(boxscore: ?SummaryBoxscore, wanted: []const u8) ?[]const u8 {
    const box = boxscore orelse return null;
    for (box.players) |group| for (group.statistics) |stats| for (stats.athletes) |entry| {
        const a = entry.athlete orelse continue;
        if (!std.mem.eql(u8, a.id, wanted)) continue;
        if (a.displayName.len > 0) return a.displayName;
        if (a.fullName.len > 0) return a.fullName;
        return null;
    };
    return null;
}

fn playParticipantId(participants: []const SummaryPlayParticipant, role: []const u8) ?[]const u8 {
    for (participants) |entry| {
        if (!std.mem.eql(u8, entry.type, role)) continue;
        const id = refId(entry.athlete) orelse continue;
        if (id.len > 0) return id;
    }
    return null;
}

fn deriveSituation(
    arena: std.mem.Allocator,
    live: ?SummarySituation,
    plays: ?[]const SummaryPlay,
    boxscore: ?SummaryBoxscore,
) !?core.detail.Situation {
    if (live) |situation| {
        if (situation.balls != null and situation.strikes != null and situation.outs != null) {
            var runners: std.ArrayList([]const u8) = .empty;
            if (valuePresent(situation.onFirst)) try runners.append(arena, "1st");
            if (valuePresent(situation.onSecond)) try runners.append(arena, "2nd");
            if (valuePresent(situation.onThird)) try runners.append(arena, "3rd");
            return .{
                .balls = situation.balls.?,
                .strikes = situation.strikes.?,
                .outs = situation.outs.?,
                .runners = try runners.toOwnedSlice(arena),
                .batter = try jsonText(arena, situation.batter orelse .null),
                .pitcher = try jsonText(arena, situation.pitcher orelse .null),
                .last_play = try jsonText(arena, situation.lastPlay orelse .null),
            };
        }
    }
    // Live summary payloads omit header.competitions[].situation; the last
    // play carries the same facts (result count, outs, runners, matchup ids).
    const play_list = plays orelse &[0]SummaryPlay{};
    if (play_list.len == 0) return null;
    const last = play_list[play_list.len - 1];
    const count = last.resultCount orelse last.pitchCount orelse SummaryCount{};
    var runners: std.ArrayList([]const u8) = .empty;
    if (valuePresent(last.onFirst) or playParticipantId(last.participants, "onFirst") != null) try runners.append(arena, "1st");
    if (valuePresent(last.onSecond) or playParticipantId(last.participants, "onSecond") != null) try runners.append(arena, "2nd");
    if (valuePresent(last.onThird) or playParticipantId(last.participants, "onThird") != null) try runners.append(arena, "3rd");
    var batter: ?[]const u8 = null;
    if (playParticipantId(last.participants, "batter")) |id| batter = playerName(boxscore, id);
    var pitcher: ?[]const u8 = null;
    if (playParticipantId(last.participants, "pitcher")) |id| pitcher = playerName(boxscore, id);
    return .{
        .balls = count.balls orelse 0,
        .strikes = count.strikes orelse 0,
        .outs = last.outs orelse 0,
        .runners = try runners.toOwnedSlice(arena),
        .batter = batter,
        .pitcher = pitcher,
        .last_play = if (last.text.len > 0) last.text else null,
    };
}

/// "ATL leads series 2-1" -> "ATL leads 2-1", plus " (game N of M)" when the
/// current game is one of the series events. Prefers top-level seasonseries,
/// falls back to the header competition series.
fn summarySeries(arena: std.mem.Allocator, response: SummaryResponse, game_id: []const u8) !?[]const u8 {
    const seasonseries: []const SummarySeries = response.seasonseries orelse &.{};
    const comp_series: []const SummarySeries = if (response.header) |header|
        (if (header.competitions.len > 0) (header.competitions[0].series orelse &.{}) else &.{})
    else
        &.{};
    const source: ?SummarySeries = if (seasonseries.len > 0 and seasonseries[0].summary.len > 0)
        seasonseries[0]
    else if (comp_series.len > 0 and comp_series[0].summary.len > 0)
        comp_series[0]
    else
        null;
    const series = source orelse return null;
    const needle = " leads series ";
    const cleaned: []const u8 = if (std.mem.indexOf(u8, series.summary, needle)) |at|
        try std.fmt.allocPrint(arena, "{s} leads {s}", .{
            series.summary[0..at],
            series.summary[at + needle.len ..],
        })
    else
        series.summary;
    var position: ?usize = null;
    for (series.events, 0..) |event, index| if (std.mem.eql(u8, event.id, game_id)) {
        position = index + 1;
        break;
    };
    const total: i64 = if (series.totalCompetitions > 0) series.totalCompetitions else @intCast(series.events.len);
    if (position) |n| {
        if (total > 0) return try std.fmt.allocPrint(arena, "{s} (game {d} of {d})", .{ cleaned, n, total });
    }
    return cleaned;
}

fn scheduleOpponentIds(event: SeriesScheduleEvent, team_id: []const u8) ?[]const u8 {
    for (event.competitions) |competition| {
        var seen_self = false;
        var other: ?[]const u8 = null;
        for (competition.competitors) |competitor| {
            const id = if (competitor.team) |team| team.id else continue;
            if (std.mem.eql(u8, id, team_id)) {
                seen_self = true;
            } else if (other == null) {
                other = id;
            }
        }
        if (seen_self) return other;
    }
    return null;
}

fn scheduleWinner(event: SeriesScheduleEvent) ?[]const u8 {
    for (event.competitions) |competition| for (competition.competitors) |competitor| {
        if (!competitor.winner) continue;
        if (competitor.team) |team| return team.id;
    };
    return null;
}

/// Series fallback when the summary carries no series field: fetch both teams'
/// season schedules, find the consecutive-vs-same-opponent block containing
/// this game, and render "ABBR leads W-L (game N of M)". Any fetch or shape
/// problem yields null (series omitted) rather than an error.
fn seriesFromSchedules(
    self: EspnAdapter,
    arena: std.mem.Allocator,
    endpoint: Endpoint,
    season: []const u8,
    competition: SummaryCompetition,
    game_id: []const u8,
) !?[]const u8 {
    var team_ids: [2][]const u8 = undefined;
    var team_abbrs: [2][]const u8 = undefined;
    var count: usize = 0;
    for (competition.competitors) |competitor| {
        if (count == team_ids.len) break;
        const team = competitor.team orelse continue;
        if (team.id.len == 0) continue;
        team_ids[count] = team.id;
        team_abbrs[count] = team.abbreviation;
        count += 1;
    }
    if (count < 2) return null;
    for ([2]usize{ 0, 1 }) |side| {
        const self_id = team_ids[side];
        const other_id = team_ids[1 - side];
        const url = espn.buildScheduleUrl(arena, self.base_url, endpoint.sport, endpoint.league, self_id, season) catch continue;
        const body = adapterFetchUrl(self, arena, url) catch continue;
        const schedule = std.json.parseFromSliceLeaky(SeriesScheduleResponse, arena, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch continue;
        var game_index: ?usize = null;
        for (schedule.events, 0..) |event, index| if (std.mem.eql(u8, event.id, game_id)) {
            game_index = index;
            break;
        };
        const at = game_index orelse continue;
        // Expand to the consecutive block vs the same opponent.
        var start = at;
        while (start > 0) {
            const opponent = scheduleOpponentIds(schedule.events[start - 1], self_id) orelse break;
            if (!std.mem.eql(u8, opponent, other_id)) break;
            start -= 1;
        }
        var end = at;
        while (end + 1 < schedule.events.len) {
            const opponent = scheduleOpponentIds(schedule.events[end + 1], self_id) orelse break;
            if (!std.mem.eql(u8, opponent, other_id)) break;
            end += 1;
        }
        const first_opponent = scheduleOpponentIds(schedule.events[at], self_id) orelse continue;
        if (!std.mem.eql(u8, first_opponent, other_id)) continue;
        var self_wins: i64 = 0;
        var other_wins: i64 = 0;
        for (schedule.events[start .. end + 1]) |event| {
            const winner = scheduleWinner(event) orelse continue;
            if (std.mem.eql(u8, winner, self_id)) {
                self_wins += 1;
            } else if (std.mem.eql(u8, winner, other_id)) {
                other_wins += 1;
            }
        }
        const total: i64 = @intCast(end - start + 1);
        const n: i64 = @intCast(at - start + 1);
        if (self_wins == other_wins) {
            return try std.fmt.allocPrint(arena, "Tied {d}-{d} (game {d} of {d})", .{ self_wins, other_wins, n, total });
        }
        const leader = if (self_wins > other_wins) team_abbrs[side] else team_abbrs[1 - side];
        const wins = @max(self_wins, other_wins);
        const losses = @min(self_wins, other_wins);
        return try std.fmt.allocPrint(arena, "{s} leads {d}-{d} (game {d} of {d})", .{ leader, wins, losses, n, total });
    }
    return null;
}

// depth: box-score team totals (additive; existing detail code above untouched).
//
// ESPN already ships `boxscore.teams[].statistics[]` in the summary payload
// this path fetches; it was simply never threaded through. Formats up to 4
// stats per side (first 2 teams) as "{ABBR} {label} {value}" so both sides
// stay visible under the renderer's 8-line cap. A null boxscore or empty
// statistics yield an empty list (section skipped, never an error).
fn boxTeamStats(arena: std.mem.Allocator, boxscore: ?SummaryBoxscore) ![]const []const u8 {
    const box = boxscore orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (box.teams[0..@min(box.teams.len, 2)]) |side| {
        const abbr: []const u8 = if (side.team) |team| team.abbreviation else "?";
        var taken: usize = 0;
        outer: for (side.statistics) |group| {
            for (group.stats) |stat| {
                if (taken >= 4) break :outer;
                const value = (try jsonText(arena, stat.displayValue)) orelse continue;
                if (value.len == 0) continue;
                const label: []const u8 = if (stat.displayName.len > 0) stat.displayName else stat.name;
                if (label.len == 0) continue;
                try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ abbr, label, value }));
                taken += 1;
            }
        }
    }
    return out.toOwnedSlice(arena);
}

pub fn detailFetch(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, game_id: []const u8) !core.detail.GameDetail {
    const endpoint = endpointFor(league.slug) orelse return error.UnsupportedLeague;
    const summary_url = try espn.buildSummaryUrl(arena, self.base_url, endpoint.sport, endpoint.league, game_id);
    const summary_body = try adapterFetchUrl(self, arena, summary_url);
    const response = try std.json.parseFromSliceLeaky(SummaryResponse, arena, summary_body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    const header = response.header orelse return error.GameNotFound;
    if (header.competitions.len == 0) return error.GameNotFound;
    const competition = header.competitions[0];
    if (competition.date.len < 10) return error.UpstreamResponse;
    const day = competition.date[0..10];
    if (!core.date.validate(day)) return error.UpstreamResponse;
    // Reuse the scoreboard path: the board is the source of the game row
    // (identity, state, status), so a game missing from its date's board is
    // an unknown id even when the summary endpoint answered.
    const board = try self.fetch(arena, league, day);
    var board_game: ?core.domain.Game = null;
    for (board.games) |game| if (std.mem.eql(u8, game.id, game_id)) {
        board_game = game;
        break;
    };
    const game = board_game orelse return error.GameNotFound;

    var participants: std.ArrayList(core.detail.DetailParticipant) = .empty;
    for (game.participants) |participant| {
        const match = findSummaryCompetitor(competition.competitors, participant.id);
        var lines: std.ArrayList(core.detail.LineScore) = .empty;
        var hits: ?[]const u8 = null;
        var errors: ?[]const u8 = null;
        var record: ?[]const u8 = null;
        var probable: ?[]const u8 = null;
        if (match) |competitor| {
            for (competitor.linescores, 0..) |line, index| {
                const display = (try jsonText(arena, line.displayValue)) orelse "-";
                try lines.append(arena, .{ .period = @intCast(index + 1), .display = display });
            }
            hits = try jsonText(arena, competitor.hits);
            errors = try jsonText(arena, competitor.errors);
            record = summaryRecord(competitor.record);
            if (competitor.probables.len > 0) probable = athleteName(competitor.probables[0].athlete);
        }
        try participants.append(arena, .{
            .id = participant.id,
            .name = participant.name,
            .abbreviation = participant.abbreviation,
            .score = participant.score,
            .winner = participant.winner,
            .home_away = participant.home_away,
            .lines = try lines.toOwnedSlice(arena),
            .hits = hits,
            .errors = errors,
            .record = record,
            .probable = probable,
        });
    }

    var decisions: std.ArrayList(core.detail.Decision) = .empty;
    if (competition.status) |status| for (status.featuredAthletes) |featured| {
        const outcome: []const u8 = if (std.mem.eql(u8, featured.name, "winningPitcher"))
            "W"
        else if (std.mem.eql(u8, featured.name, "losingPitcher"))
            "L"
        else if (std.mem.eql(u8, featured.name, "savingPitcher"))
            "SV"
        else
            continue;
        const name = athleteName(featured.athlete) orelse continue;
        try decisions.append(arena, .{ .outcome = outcome, .name = name });
    };

    var scoring_plays: std.ArrayList(core.detail.ScoringPlay) = .empty;
    const plays = response.plays orelse &[0]SummaryPlay{};
    for (plays) |play| {
        if (!play.scoringPlay) continue;
        const period = if (play.period) |p| p.displayValue else "";
        const away_score = (try jsonText(arena, play.awayScore)) orelse "";
        const home_score = (try jsonText(arena, play.homeScore)) orelse "";
        try scoring_plays.append(arena, .{
            .period = period,
            .text = play.text,
            .away_score = away_score,
            .home_score = home_score,
        });
    }

    // Leaders: team totals plus the top performers per side, as plain strings.
    var leaders: std.ArrayList([]const u8) = .empty;
    if (response.boxscore) |boxscore| {
        const groups = boxscore.players[0..@min(boxscore.players.len, 2)];
        for (groups) |group| {
            const abbr: []const u8 = if (group.team) |team| team.abbreviation else "?";
            for (group.statistics[0..@min(group.statistics.len, 1)]) |stats| {
                if (stats.totals.len > 0) {
                    const total = (try jsonText(arena, stats.totals[0])) orelse "?";
                    const label: []const u8 = if (stats.names.len > 0) stats.names[0] else "total";
                    try leaders.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ abbr, label, total }));
                }
                for (stats.athletes[0..@min(stats.athletes.len, 4)]) |entry| {
                    const reference = entry.athlete orelse continue;
                    const name: []const u8 = if (reference.displayName.len > 0)
                        reference.displayName
                    else if (reference.fullName.len > 0)
                        reference.fullName
                    else
                        continue;
                    if (entry.stats.len > 0) {
                        const head = (try jsonText(arena, entry.stats[0])) orelse "";
                        if (head.len > 0) {
                            try leaders.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ name, head }));
                            continue;
                        }
                    }
                    try leaders.append(arena, name);
                }
            }
        }
    }

    const situation: ?core.detail.Situation = if (std.mem.eql(u8, game.state, "in"))
        try deriveSituation(arena, competition.situation, response.plays, response.boxscore)
    else
        null;

    var venue: ?[]const u8 = null;
    var attendance: ?i64 = null;
    if (response.gameInfo) |info| {
        if (info.venue) |building| {
            if (building.fullName.len > 0) venue = building.fullName;
        }
        attendance = switch (info.attendance) {
            .integer => |n| n,
            else => null,
        };
    }

    var series: ?[]const u8 = null;
    if (try summarySeries(arena, response, game.id)) |from_summary| {
        series = from_summary;
    } else {
        series = try seriesFromSchedules(self, arena, endpoint, day[0..4], competition, game.id);
    }

    // depth: box-score team totals ride the already-fetched summary payload.
    const team_stats = try boxTeamStats(arena, response.boxscore);

    return .{
        .id = try copy(arena, game.id),
        .league = league.slug,
        .league_name = league.name,
        .date = try copy(arena, day),
        .state = game.state,
        .status = game.status,
        .venue = venue,
        .attendance = attendance,
        .series = series,
        .participants = try participants.toOwnedSlice(arena),
        .situation = situation,
        .decisions = try decisions.toOwnedSlice(arena),
        .scoring_plays = try scoring_plays.toOwnedSlice(arena),
        .leaders = try leaders.toOwnedSlice(arena),
        // depth: box-score team totals (optional; empty when not supplied).
        .team_stats = team_stats,
    };
}

const DetailFake = struct {
    summary_body: []const u8,
    board_body: []const u8,
    sched_a_id: []const u8 = "",
    sched_a_body: []const u8 = "",
    sched_b_body: []const u8 = "",
    summary_calls: usize = 0,
    board_calls: usize = 0,
    sched_calls: usize = 0,

    fn dispatch(ptr: *anyopaque, arena: std.mem.Allocator, url: []const u8, extra_headers: []const std.http.Header) anyerror!espn.FetchResult {
        _ = extra_headers;
        const self: *DetailFake = @ptrCast(@alignCast(ptr));
        if (std.mem.indexOf(u8, url, "/summary?") != null) {
            self.summary_calls += 1;
            return .{ .status = .ok, .body = try arena.dupe(u8, self.summary_body) };
        }
        if (std.mem.indexOf(u8, url, "/scoreboard") != null) {
            self.board_calls += 1;
            return .{ .status = .ok, .body = try arena.dupe(u8, self.board_body) };
        }
        if (std.mem.indexOf(u8, url, "/schedule") != null) {
            self.sched_calls += 1;
            if (self.sched_a_id.len > 0 and std.mem.indexOf(u8, url, self.sched_a_id) != null) {
                if (self.sched_a_body.len > 0) return .{ .status = .ok, .body = try arena.dupe(u8, self.sched_a_body) };
                return .{ .status = .not_found, .body = try arena.dupe(u8, "{}") };
            }
            if (self.sched_b_body.len > 0) {
                return .{ .status = .ok, .body = try arena.dupe(u8, self.sched_b_body) };
            }
            return .{ .status = .not_found, .body = try arena.dupe(u8, "{}") };
        }
        return .{ .status = .not_found, .body = try arena.dupe(u8, "{}") };
    }

    fn asTransport(self: *DetailFake) espn.HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

fn detailAdapter(fake: *DetailFake) EspnAdapter {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return .{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
        .base_url = "https://example.test/base",
        .transport = fake.asTransport(),
        .clock = fakeClock,
    };
}

const detail_board_fixture =
    \\{"events":[{"id":"401816828","name":"Atlanta Braves at Philadelphia Phillies","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final","description":"Final"}},"competitions":[{"id":"401816828","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final","description":"Final"}},"competitors":[{"homeAway":"away","score":"5","winner":true,"team":{"id":"15","displayName":"Atlanta Braves","abbreviation":"ATL"}},{"homeAway":"home","score":"4","winner":false,"team":{"id":"22","displayName":"Philadelphia Phillies","abbreviation":"PHI"}}]}]}]}
;

const detail_summary_fixture =
    \\{"header":{"competitions":[{"id":"401816828","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final","description":"Final"},"featuredAthletes":[{"name":"winningPitcher","athlete":{"displayName":"Dylan Lee","fullName":"Dylan Lee"}},{"name":"losingPitcher","athlete":{"displayName":"Jhoan Duran","fullName":"Jhoan Duran"}},{"name":"savingPitcher","athlete":{"displayName":"Raisel Iglesias","fullName":"Raisel Iglesias"}}]},"competitors":[{"id":"22","homeAway":"home","winner":false,"score":4,"hits":7,"errors":0,"team":{"id":"22","displayName":"Philadelphia Phillies","abbreviation":"PHI"},"linescores":[{"displayValue":"2"},{"displayValue":"0"},{"displayValue":"0"},{"displayValue":"0"},{"displayValue":"0"},{"displayValue":"0"},{"displayValue":"2"},{"displayValue":"0"},{"displayValue":"0"}],"record":[{"type":"total","summary":"80-63"}],"probables":[{"athlete":{"displayName":"Aaron Nola","fullName":"Aaron Nola"}}]},{"id":"15","homeAway":"away","winner":true,"score":5,"hits":10,"errors":1,"team":{"id":"15","displayName":"Atlanta Braves","abbreviation":"ATL"},"linescores":[{"displayValue":"0"},{"displayValue":"0"},{"displayValue":"0"},{"displayValue":"0"},{"displayValue":"0"},{"displayValue":"1"},{"displayValue":"0"},{"displayValue":"3"},{"displayValue":"1"}],"record":[{"type":"total","summary":"85-58"}],"probables":[{"athlete":{"displayName":"Tyler Mahle","fullName":"Tyler Mahle"}}]}]}]},"plays":[{"text":"Arraez hit sacrifice fly to center, Schwarber scored.","scoringPlay":true,"awayScore":0,"homeScore":1,"period":{"displayValue":"1st Inning"}},{"text":"Bohm doubled to left, Turner scored.","scoringPlay":true,"awayScore":0,"homeScore":2,"period":{"displayValue":"1st Inning"}},{"text":"Acuña Jr. hit sacrifice fly to right, Yastrzemski scored.","scoringPlay":true,"awayScore":1,"homeScore":2,"period":{"displayValue":"6th Inning"}},{"text":"Hill homered to left (388 feet).","scoringPlay":true,"awayScore":1,"homeScore":3,"period":{"displayValue":"7th Inning"}},{"text":"Schwarber homered to right (371 feet).","scoringPlay":true,"awayScore":1,"homeScore":4,"period":{"displayValue":"7th Inning"}},{"text":"Acuña Jr. homered to left center (414 feet), Yastrzemski scored and Baldwin scored.","scoringPlay":true,"awayScore":4,"homeScore":4,"period":{"displayValue":"8th Inning"}},{"text":"Riley tripled to center, Albies scored.","scoringPlay":true,"awayScore":5,"homeScore":4,"period":{"displayValue":"9th Inning"}},{"text":"Pitch 1 : Ball 1","scoringPlay":false,"awayScore":5,"homeScore":4,"period":{"displayValue":"9th Inning"}}],"boxscore":{"players":[{"team":{"id":"15","abbreviation":"ATL"},"statistics":[{"names":["H-AB","AB","R"],"totals":["10-35","35","5"],"athletes":[{"athlete":{"id":"4810190","displayName":"Drake Baldwin","fullName":"Drake Baldwin"},"stats":["2-4","4","1"]}]}]},{"team":{"id":"22","abbreviation":"PHI"},"statistics":[{"names":["H-AB","AB","R"],"totals":["7-32","32","4"],"athletes":[{"athlete":{"id":"1","displayName":"Kyle Schwarber","fullName":"Kyle Schwarber"},"stats":["2-4","4","2"]}]}]}]},"gameInfo":{"attendance":42793,"venue":{"fullName":"Citizens Bank Park"}},"seasonseries":[{"summary":"ATL leads series 2-1","completed":false,"totalCompetitions":4,"events":[{"id":"401816798"},{"id":"401816813"},{"id":"401816828"},{"id":"401816843"}]}]}
;

test "fetchDetail enriches the board row with summary fields" {
    var fake = DetailFake{ .summary_body = detail_summary_fixture, .board_body = detail_board_fixture };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "401816828");
    try std.testing.expectEqual(@as(usize, 1), fake.summary_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.board_calls);
    try std.testing.expectEqualStrings("401816828", detail.id);
    try std.testing.expectEqualStrings("mlb", detail.league);
    try std.testing.expectEqualStrings("2026-09-06", detail.date);
    try std.testing.expectEqualStrings("post", detail.state);
    try std.testing.expectEqualStrings("Final", detail.status);
    try std.testing.expectEqualStrings("Citizens Bank Park", detail.venue.?);
    try std.testing.expectEqual(@as(i64, 42793), detail.attendance.?);
    try std.testing.expectEqualStrings("ATL leads 2-1 (game 3 of 4)", detail.series.?);
    try std.testing.expectEqual(@as(usize, 2), detail.participants.len);
    const home = detail.participants[1];
    try std.testing.expectEqualStrings("PHI", home.abbreviation);
    try std.testing.expectEqual(@as(usize, 9), home.lines.len);
    try std.testing.expectEqualStrings("2", home.lines[0].display);
    try std.testing.expectEqualStrings("7", home.hits.?);
    try std.testing.expectEqualStrings("0", home.errors.?);
    try std.testing.expectEqualStrings("80-63", home.record.?);
    try std.testing.expectEqualStrings("Aaron Nola", home.probable.?);
    try std.testing.expectEqual(@as(usize, 3), detail.decisions.len);
    try std.testing.expectEqualStrings("W", detail.decisions[0].outcome);
    try std.testing.expectEqualStrings("Dylan Lee", detail.decisions[0].name);
    try std.testing.expectEqualStrings("SV", detail.decisions[2].outcome);
    try std.testing.expectEqual(@as(usize, 7), detail.scoring_plays.len);
    try std.testing.expectEqualStrings("1st Inning", detail.scoring_plays[0].period);
    try std.testing.expectEqualStrings("0", detail.scoring_plays[0].away_score);
    try std.testing.expectEqualStrings("Riley tripled to center, Albies scored.", detail.scoring_plays[6].text);
    try std.testing.expect(detail.situation == null);
    try std.testing.expect(detail.leaders.len >= 4);
    try std.testing.expectEqualStrings("ATL H-AB 10-35", detail.leaders[0]);
    try std.testing.expectEqualStrings("Drake Baldwin 2-4", detail.leaders[1]);
}

test "fetchDetail reports GameNotFound when the board lacks the id" {
    var fake = DetailFake{ .summary_body = detail_summary_fixture, .board_body = "{\"events\":[]}" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.GameNotFound,
        detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "401816828"),
    );
}

test "fetchDetail omits series when nothing derives it" {
    const summary =
        \\{"header":{"competitions":[{"id":"7","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"a","homeAway":"away","winner":true,"score":"1","team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"id":"h","homeAway":"home","winner":false,"score":"0","team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]},"plays":null,"gameInfo":{}}
    ;
    const board =
        \\{"events":[{"id":"7","name":"Away at Home","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"7","date":"2026-09-06T17:10Z","competitors":[{"homeAway":"away","score":"1","winner":true,"team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"homeAway":"home","score":"0","winner":false,"team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}]}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "7");
    try std.testing.expect(detail.series == null);
    try std.testing.expect(detail.situation == null);
    try std.testing.expectEqual(@as(usize, 0), detail.scoring_plays.len);
}

test "fetchDetail derives the series from team schedules when the summary lacks one" {
    const summary =
        \\{"header":{"competitions":[{"id":"401816828","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"22","homeAway":"home","winner":false,"score":4,"team":{"id":"22","displayName":"Philadelphia Phillies","abbreviation":"PHI"}},{"id":"15","homeAway":"away","winner":true,"score":5,"team":{"id":"15","displayName":"Atlanta Braves","abbreviation":"ATL"}}]}]},"plays":null}
    ;
    const schedule =
        \\{"events":[{"id":"401816798","competitions":[{"competitors":[{"winner":false,"team":{"id":"22","abbreviation":"PHI"}},{"winner":true,"team":{"id":"15","abbreviation":"ATL"}}]}]},{"id":"401816813","competitions":[{"competitors":[{"winner":true,"team":{"id":"22","abbreviation":"PHI"}},{"winner":false,"team":{"id":"15","abbreviation":"ATL"}}]}]},{"id":"401816828","competitions":[{"competitors":[{"winner":false,"team":{"id":"22","abbreviation":"PHI"}},{"winner":true,"team":{"id":"15","abbreviation":"ATL"}}]}]},{"id":"401816843","competitions":[{"competitors":[{"team":{"id":"22","abbreviation":"PHI"}},{"team":{"id":"15","abbreviation":"ATL"}}]}]}]}
    ;
    var fake = DetailFake{
        .summary_body = summary,
        .board_body = detail_board_fixture,
        .sched_a_id = "/teams/22/",
        .sched_a_body = schedule,
        .sched_b_body = schedule,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "401816828");
    try std.testing.expectEqualStrings("ATL leads 2-1 (game 3 of 4)", detail.series.?);
}

test "fetchDetail derives live situation from the last play" {
    const summary =
        \\{"header":{"competitions":[{"id":"9","date":"2026-09-06T19:10Z","status":{"type":{"state":"in","shortDetail":"Bot 6th"}} ,"competitors":[{"id":"a","homeAway":"away","winner":false,"score":0,"team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"id":"h","homeAway":"home","winner":false,"score":4,"team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]},"plays":[{"text":"Acuña Jr. doubled to left.","scoringPlay":false,"awayScore":0,"homeScore":4,"period":{"displayValue":"6th Inning"}},{"text":"Pitch 4 : Strike 2 Foul","scoringPlay":false,"awayScore":0,"homeScore":4,"period":{"displayValue":"6th Inning"},"resultCount":{"balls":2,"strikes":2},"outs":2,"onFirst":{},"onSecond":{},"participants":[{"type":"pitcher","athlete":{"id":"5007765"}},{"type":"batter","athlete":{"id":"4872685"}}]}],"boxscore":{"players":[{"team":{"id":"h","abbreviation":"HME"},"statistics":[{"names":["H-AB"],"totals":["4-20"],"athletes":[{"athlete":{"id":"4872685","displayName":"Test Batter","fullName":"Test Batter"},"stats":["1-3"]}]}]}]}}
    ;
    const board =
        \\{"events":[{"id":"9","name":"Away at Home","date":"2026-09-06T19:10Z","status":{"type":{"state":"in","shortDetail":"Bot 6th"}},"competitions":[{"id":"9","date":"2026-09-06T19:10Z","status":{"type":{"state":"in","shortDetail":"Bot 6th"}},"competitors":[{"homeAway":"away","score":"0","winner":false,"team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"homeAway":"home","score":"4","winner":false,"team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}]}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "9");
    const situation = detail.situation orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i64, 2), situation.balls);
    try std.testing.expectEqual(@as(i64, 2), situation.strikes);
    try std.testing.expectEqual(@as(i64, 2), situation.outs);
    try std.testing.expectEqual(@as(usize, 2), situation.runners.len);
    try std.testing.expectEqualStrings("1st", situation.runners[0]);
    try std.testing.expectEqualStrings("Test Batter", situation.batter.?);
    try std.testing.expectEqualStrings("Pitch 4 : Strike 2 Foul", situation.last_play.?);
    try std.testing.expectEqual(@as(usize, 0), detail.scoring_plays.len);
    try std.testing.expectEqual(@as(usize, 2), fake.sched_calls);
    try std.testing.expect(detail.series == null);
}

// ---- Per-team view (additive; existing fns above are untouched) ----

/// Season rule: the schedule season is the current calendar year from the
/// adapter clock. Around the December/January wrap (early January, before
/// ESPN publishes the new schedule) the current-year schedule comes back
/// empty, so `fetchTeam` falls back to the previous year once. An empty
/// fallback yields a view with no games rather than an error.
///
/// Live join: the schedule cannot tell live games apart (a game later today
/// still reads `pre`), so schedule event ids are intersected with that
/// date's scoreboard `state == in` games via `fetch`. The board fetch is
/// enrichment only: on failure `live` is null instead of an error.
pub fn fetchTeam(adapter: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, abbrev: []const u8) !core.schedule.TeamView {
    return fetchTeamImpl(adapter, arena, league, abbrev);
}

const TeamListResponse = struct {
    sports: []const TeamListSport = &.{},
};
const TeamListSport = struct {
    leagues: []const TeamListLeague = &.{},
};
const TeamListLeague = struct {
    teams: []const TeamListEntry = &.{},
};
const TeamListEntry = struct {
    team: ?TeamListTeam = null,
};
const TeamListTeam = struct {
    id: []const u8 = "",
    abbreviation: []const u8 = "",
    displayName: []const u8 = "Unknown",
};

const ScheduleResponse = struct {
    team: ?ScheduleTeam = null,
    events: []const ScheduleEvent = &.{},
};
const ScheduleTeam = struct {
    id: []const u8 = "",
    abbreviation: []const u8 = "?",
    displayName: []const u8 = "Unknown",
    recordSummary: ?[]const u8 = null,
    standingSummary: ?[]const u8 = null,
};
const ScheduleEvent = struct {
    id: []const u8 = "",
    date: []const u8 = "",
    competitions: []const ScheduleCompetition = &.{},
};
const ScheduleCompetition = struct {
    id: []const u8 = "",
    date: []const u8 = "",
    status: ?Status = null,
    competitors: []const ScheduleCompetitor = &.{},
};
const ScheduleCompetitor = struct {
    id: []const u8 = "",
    homeAway: []const u8 = "",
    winner: ?bool = null,
    score: ?std.json.Value = null,
    team: ?ScheduleOpponent = null,
    probables: []const ScheduleProbable = &.{},
};
const ScheduleOpponent = struct {
    id: []const u8 = "",
    abbreviation: []const u8 = "?",
    displayName: []const u8 = "Unknown",
};
const ScheduleProbable = struct {
    athlete: ?ScheduleAthlete = null,
};
const ScheduleAthlete = struct {
    displayName: []const u8 = "",
    shortName: []const u8 = "",
};

const ParsedSchedule = struct {
    team: core.schedule.TeamInfo,
    events: []core.schedule.ScheduleEvent,
};

fn resolveTeamId(body: []const u8, arena: std.mem.Allocator, abbrev: []const u8) !?[]const u8 {
    const response = try std.json.parseFromSliceLeaky(TeamListResponse, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    for (response.sports) |sport| {
        for (sport.leagues) |league| {
            for (league.teams) |entry| {
                if (entry.team) |team| {
                    if (std.ascii.eqlIgnoreCase(team.abbreviation, abbrev)) return team.id;
                }
            }
        }
    }
    return null;
}

fn scoreText(arena: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const v = value orelse return "";
    switch (v) {
        .string => |s| return s,
        .integer => |n| return std.fmt.allocPrint(arena, "{d}", .{n}),
        .float => |n| {
            if (n == @trunc(n)) return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
            return std.fmt.allocPrint(arena, "{d}", .{n});
        },
        .number_string => |s| return s,
        .object => |obj| {
            const display = obj.get("displayValue") orelse return "";
            switch (display) {
                .string => |s| return s,
                .integer => |n| return std.fmt.allocPrint(arena, "{d}", .{n}),
                .float => |n| {
                    if (n == @trunc(n)) return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
                    return std.fmt.allocPrint(arena, "{d}", .{n});
                },
                .number_string => |s| return s,
                else => return "",
            }
        },
        else => return "",
    }
}

fn parseSchedule(arena: std.mem.Allocator, body: []const u8, abbrev: []const u8) !ParsedSchedule {
    const response = try std.json.parseFromSliceLeaky(ScheduleResponse, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    const header = response.team orelse ScheduleTeam{};
    const ours_id = header.id;
    var events: std.ArrayList(core.schedule.ScheduleEvent) = .empty;
    for (response.events) |event| {
        if (event.competitions.len == 0) continue;
        // Event-level status is always null; the competition level is
        // authoritative (same rule as the scoreboard path).
        const competition = event.competitions[0];
        const status_type: StatusType = if (competition.status) |status| status.type else StatusType{};
        var ours: ?ScheduleCompetitor = null;
        var opp: ?ScheduleCompetitor = null;
        for (competition.competitors) |competitor| {
            const id = if (competitor.team) |team| team.id else competitor.id;
            const abbr = if (competitor.team) |team| team.abbreviation else "";
            if ((ours_id.len > 0 and std.mem.eql(u8, id, ours_id)) or
                std.ascii.eqlIgnoreCase(abbr, abbrev))
            {
                ours = competitor;
            } else if (opp == null) {
                opp = competitor;
            }
        }
        const our_side = ours orelse continue;
        const opp_side = opp orelse ScheduleCompetitor{};
        const opp_team = opp_side.team orelse ScheduleOpponent{};
        const our_score = try scoreText(arena, our_side.score);
        const opp_score = try scoreText(arena, opp_side.score);
        var probable: []const u8 = "";
        if (our_side.probables.len > 0) {
            if (our_side.probables[0].athlete) |athlete| {
                probable = if (athlete.displayName.len > 0) athlete.displayName else athlete.shortName;
            }
        }
        try events.append(arena, .{
            .id = if (competition.id.len > 0) competition.id else event.id,
            .date = if (competition.date.len > 0) competition.date else event.date,
            .opponent_abbrev = opp_team.abbreviation,
            .opponent_name = opp_team.displayName,
            .home_away = our_side.homeAway,
            .state = status_type.state,
            .status = if (status_type.shortDetail.len > 0) status_type.shortDetail else status_type.description,
            .our_score = our_score,
            .opp_score = opp_score,
            .won = our_side.winner,
            .probable = probable,
        });
    }
    return .{
        .team = .{
            .id = ours_id,
            .abbrev = header.abbreviation,
            .name = header.displayName,
            .record_summary = header.recordSummary,
            .standing_summary = header.standingSummary,
        },
        .events = try events.toOwnedSlice(arena),
    };
}

/// Upcoming display: `"vs ATL 5:05 PM"` / `"at NYM 7:15 PM"` (UTC, from the
/// ISO timestamp). Falls back to the calendar date when no time parses.
fn upcomingResult(arena: std.mem.Allocator, event: core.schedule.ScheduleEvent) ![]u8 {
    const versus = if (std.mem.eql(u8, event.home_away, "away")) "at" else "vs";
    if (event.date.len >= 16 and event.date[13] == ':') {
        const hour = std.fmt.parseInt(u8, event.date[11..13], 10) catch {
            return std.fmt.allocPrint(arena, "{s} {s} {s}", .{ versus, event.opponent_abbrev, event.date });
        };
        const minute = event.date[14..16];
        const twelve = if (hour % 12 == 0) @as(u8, 12) else hour % 12;
        const suffix: []const u8 = if (hour < 12) "AM" else "PM";
        return std.fmt.allocPrint(arena, "{s} {s} {d}:{s} {s}", .{ versus, event.opponent_abbrev, twelve, minute, suffix });
    }
    const prefix = if (event.date.len >= 10) event.date[0..10] else event.date;
    return std.fmt.allocPrint(arena, "{s} {s} {s}", .{ versus, event.opponent_abbrev, prefix });
}

/// Final display: `"W 5-3"` / `"L 2-4"` (our score first). A numeric tie
/// with no winner flag renders `"D"`. Missing scores fall back to status.
fn finalResult(arena: std.mem.Allocator, event: core.schedule.ScheduleEvent) ![]u8 {
    if (event.our_score.len == 0 or event.opp_score.len == 0) {
        return arena.dupe(u8, event.status);
    }
    const prefix: []const u8 = prefix: {
        if (event.won) |won| break :prefix if (won) "W" else "L";
        const ours = std.fmt.parseInt(i64, event.our_score, 10) catch break :prefix "F";
        const theirs = std.fmt.parseInt(i64, event.opp_score, 10) catch break :prefix "F";
        break :prefix if (ours == theirs) "D" else if (ours > theirs) "W" else "L";
    };
    return std.fmt.allocPrint(arena, "{s} {s}-{s}", .{ prefix, event.our_score, event.opp_score });
}

fn gameRefFromEvent(arena: std.mem.Allocator, event: core.schedule.ScheduleEvent) !core.schedule.GameRef {
    const result = if (std.mem.eql(u8, event.state, "post"))
        try finalResult(arena, event)
    else
        try upcomingResult(arena, event);
    return .{
        .id = event.id,
        .date = event.date,
        .opponent_abbrev = event.opponent_abbrev,
        .opponent_name = event.opponent_name,
        .home_away = event.home_away,
        .status = event.status,
        .state = event.state,
        .our_score = event.our_score,
        .opp_score = event.opp_score,
        .result = result,
        .probable = event.probable,
    };
}

/// Live display from a board game: `"{our}-{opp} {status}"`, e.g.
/// `"3-2 Top 7th"`. Ours is matched by abbreviation (case-insensitive);
/// the first other participant is the opponent.
fn liveRefFromBoardGame(arena: std.mem.Allocator, game: core.domain.Game, abbrev: []const u8) !?core.schedule.GameRef {
    var ours: ?core.domain.Participant = null;
    var opp: ?core.domain.Participant = null;
    for (game.participants) |participant| {
        if (std.ascii.eqlIgnoreCase(participant.abbreviation, abbrev)) {
            ours = participant;
        } else if (opp == null) {
            opp = participant;
        }
    }
    const our_side = ours orelse return null;
    const opp_side = opp orelse return null;
    const our_home_away = our_side.home_away orelse "";
    return .{
        .id = game.id,
        .date = game.starts_at,
        .opponent_abbrev = opp_side.abbreviation,
        .opponent_name = opp_side.name,
        .home_away = our_home_away,
        .status = game.status,
        .state = game.state,
        .our_score = our_side.score,
        .opp_score = opp_side.score,
        .result = try std.fmt.allocPrint(arena, "{s}-{s} {s}", .{ our_side.score, opp_side.score, game.status }),
        .probable = "",
    };
}

fn fetchTeamImpl(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, abbrev: []const u8) !core.schedule.TeamView {
    const endpoint = endpointFor(league.slug) orelse return error.UnsupportedLeague;
    const today = try self.today(arena);
    const season = today[0..4];

    const teams_body = try adapterFetchUrl(self, arena, try espn.buildTeamsUrl(arena, self.base_url, endpoint.sport, endpoint.league));
    const team_id = (try resolveTeamId(teams_body, arena, abbrev)) orelse return error.TeamNotFound;

    var parsed = try parseSchedule(arena, try adapterFetchUrl(
        self,
        arena,
        try espn.buildScheduleUrl(arena, self.base_url, endpoint.sport, endpoint.league, team_id, season),
    ), abbrev);
    if (parsed.events.len == 0) {
        const year = try std.fmt.parseInt(u16, season, 10);
        const previous = try std.fmt.allocPrint(arena, "{d}", .{year - 1});
        parsed = try parseSchedule(arena, try adapterFetchUrl(
            self,
            arena,
            try espn.buildScheduleUrl(arena, self.base_url, endpoint.sport, endpoint.league, team_id, previous),
        ), abbrev);
    }

    const split = core.schedule.splitSchedule(parsed.events, today);
    var next: std.ArrayList(core.schedule.GameRef) = .empty;
    for (split.upcoming[0..@min(split.upcoming.len, 5)]) |event| {
        try next.append(arena, try gameRefFromEvent(arena, event));
    }
    var last: std.ArrayList(core.schedule.GameRef) = .empty;
    var i: usize = split.past.len;
    while (i > 0 and last.items.len < 5) {
        i -= 1;
        try last.append(arena, try gameRefFromEvent(arena, split.past[i]));
    }

    var live: ?core.schedule.GameRef = null;
    if (self.fetch(arena, league, today)) |board| {
        for (board.games) |game| {
            if (!std.mem.eql(u8, game.state, "in")) continue;
            for (parsed.events) |event| {
                if (!std.mem.eql(u8, event.id, game.id)) continue;
                live = try liveRefFromBoardGame(arena, game, parsed.team.abbrev);
                break;
            }
            if (live != null) break;
        }
    } else |err| {
        std.log.warn("team live join failed for {s}: {t}", .{ abbrev, err });
    }

    // depth: full-season overflow beyond the 5/5 window above. `parsed.events`
    // is the whole season already in hand — no extra upstream fetch. `last`
    // holds the newest past games, so the overflow is the older head reversed
    // (newest-first, continuing `last`); `next` holds the soonest upcoming,
    // so the overflow is the tail in order (continuing `next`).
    var extra_past: std.ArrayList(core.schedule.GameRef) = .empty;
    if (split.past.len > last.items.len) {
        var j: usize = split.past.len - last.items.len;
        while (j > 0) {
            j -= 1;
            try extra_past.append(arena, try gameRefFromEvent(arena, split.past[j]));
        }
    }
    var extra_next: std.ArrayList(core.schedule.GameRef) = .empty;
    if (split.upcoming.len > next.items.len) {
        for (split.upcoming[next.items.len..]) |event| {
            try extra_next.append(arena, try gameRefFromEvent(arena, event));
        }
    }

    return .{
        .league = league.slug,
        .league_name = league.name,
        .team = parsed.team,
        .last = try last.toOwnedSlice(arena),
        .next = try next.toOwnedSlice(arena),
        .live = live,
        // depth: full-season overflow (optional; empty when within the window).
        .extra_past = try extra_past.toOwnedSlice(arena),
        .extra_next = try extra_next.toOwnedSlice(arena),
    };
}

const TeamFixtureState = struct {
    teams_body: []const u8,
    schedule_body: []const u8,
    board_body: []const u8,
    fail_board: bool = false,
    schedule_calls: usize = 0,
    first_schedule_url: ?[]const u8 = null,
    last_schedule_url: ?[]const u8 = null,

    fn dispatch(ptr: *anyopaque, arena: std.mem.Allocator, url: []const u8, extra_headers: []const std.http.Header) anyerror!espn.FetchResult {
        _ = extra_headers;
        const self: *TeamFixtureState = @ptrCast(@alignCast(ptr));
        if (std.mem.indexOf(u8, url, "scoreboard") != null) {
            if (self.fail_board) return .{ .status = .bad_gateway, .body = try arena.dupe(u8, "{}") };
            return .{ .status = .ok, .body = try arena.dupe(u8, self.board_body) };
        }
        if (std.mem.indexOf(u8, url, "schedule") != null) {
            self.schedule_calls += 1;
            const seen = try arena.dupe(u8, url);
            if (self.first_schedule_url == null) self.first_schedule_url = seen;
            self.last_schedule_url = seen;
            return .{ .status = .ok, .body = try arena.dupe(u8, self.schedule_body) };
        }
        return .{ .status = .ok, .body = try arena.dupe(u8, self.teams_body) };
    }

    fn asTransport(self: *TeamFixtureState) espn.HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

const team_fixture_teams =
    \\{"sports":[{"leagues":[{"teams":[{"team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"}},{"team":{"id":"12","abbreviation":"ATL","displayName":"Atlanta Braves"}}]}]}]}
;

const team_fixture_schedule =
    \\{"team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies","recordSummary":"80-63","standingSummary":"2nd in NL East"},"events":[
    \\{"id":"401814694","date":"2026-09-05T23:10Z","competitions":[{"id":"401814694","date":"2026-09-05T23:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"homeAway":"home","winner":true,"score":{"displayValue":"5"},"team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"probables":[]},{"homeAway":"away","winner":false,"score":{"displayValue":"3"},"team":{"id":"1","abbreviation":"NYM","displayName":"New York Mets"},"probables":[]}]}]},
    \\{"id":"live1","date":"2026-09-07T17:05Z","competitions":[{"id":"live1","date":"2026-09-07T17:05Z","status":{"type":{"state":"pre","shortDetail":"9/7 - 1:05 PM EDT"}},"competitors":[{"homeAway":"home","team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"probables":[{"athlete":{"id":"39667","displayName":"Jesus Luzardo","shortName":"J. Luzardo"}}]},{"homeAway":"away","team":{"id":"12","abbreviation":"ATL","displayName":"Atlanta Braves"},"probables":[]}]}]},
    \\{"id":"401816844","date":"2026-09-08T17:05Z","competitions":[{"id":"401816844","date":"2026-09-08T17:05Z","status":{"type":{"state":"pre","shortDetail":"9/8 - 1:05 PM EDT"}},"competitors":[{"homeAway":"away","team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"probables":[]},{"homeAway":"home","team":{"id":"12","abbreviation":"ATL","displayName":"Atlanta Braves"},"probables":[]}]}]}
    \\]}
;

const team_fixture_board =
    \\{"events":[{"id":"live1","name":"Atlanta Braves at Philadelphia Phillies","date":"2026-09-07T17:05Z","status":{"type":{"state":"in","shortDetail":"Top 7th"}},"competitions":[{"id":"live1","date":"2026-09-07T17:05Z","status":{"type":{"state":"in","shortDetail":"Top 7th"}},"competitors":[{"homeAway":"away","score":"2","team":{"id":"12","displayName":"Atlanta Braves","abbreviation":"ATL"}},{"homeAway":"home","score":"3","team":{"id":"22","displayName":"Philadelphia Phillies","abbreviation":"PHI"}}]}]}]}
;

fn teamTestAdapter(fake: *TeamFixtureState) EspnAdapter {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return .{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
        .base_url = "https://example.test/base",
        .transport = fake.asTransport(),
        .clock = fakeClock,
    };
}

test "fetchTeam resolves abbrev case-insensitively and joins live" {
    var fake = TeamFixtureState{
        .teams_body = team_fixture_teams,
        .schedule_body = team_fixture_schedule,
        .board_body = team_fixture_board,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const adapter = teamTestAdapter(&fake);
    const view = try fetchTeam(adapter, arena, core.leagues.find("mlb").?, "phi");
    try std.testing.expectEqualStrings("PHI", view.team.abbrev);
    try std.testing.expectEqualStrings("Philadelphia Phillies", view.team.name);
    try std.testing.expectEqualStrings("80-63", view.team.record_summary.?);
    try std.testing.expectEqualStrings("2nd in NL East", view.team.standing_summary.?);
    try std.testing.expectEqualStrings("W 5-3", view.last[0].result);
    try std.testing.expectEqual(@as(usize, 1), view.last.len);
    try std.testing.expectEqual(@as(usize, 2), view.next.len);
    try std.testing.expectEqualStrings("Jesus Luzardo", view.next[0].probable);
    try std.testing.expect(view.live != null);
    try std.testing.expectEqualStrings("Top 7th", view.live.?.status);
    try std.testing.expectEqualStrings("3", view.live.?.our_score);
    try std.testing.expectEqual(@as(usize, 1), fake.schedule_calls);
}

test "fetchTeam returns TeamNotFound for unknown abbrev" {
    var fake = TeamFixtureState{
        .teams_body = team_fixture_teams,
        .schedule_body = team_fixture_schedule,
        .board_body = team_fixture_board,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const adapter = teamTestAdapter(&fake);
    try std.testing.expectError(
        error.TeamNotFound,
        fetchTeam(adapter, arena_state.allocator(), core.leagues.find("mlb").?, "zzz"),
    );
}

test "fetchTeam falls back to the previous season when the schedule is empty" {
    var fake = TeamFixtureState{
        .teams_body = team_fixture_teams,
        .schedule_body = team_fixture_schedule_empty,
        .board_body = team_fixture_board,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const adapter = teamTestAdapter(&fake);
    const view = try fetchTeam(adapter, arena_state.allocator(), core.leagues.find("mlb").?, "PHI");
    try std.testing.expectEqual(@as(usize, 2), fake.schedule_calls);
    try std.testing.expect(std.mem.indexOf(u8, fake.first_schedule_url.?, "season=2026") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.last_schedule_url.?, "season=2025") != null);
    try std.testing.expectEqual(@as(usize, 0), view.last.len);
    try std.testing.expectEqual(@as(usize, 0), view.next.len);
}

test "fetchTeam still renders when the live board fetch fails" {
    var fake = TeamFixtureState{
        .teams_body = team_fixture_teams,
        .schedule_body = team_fixture_schedule,
        .board_body = team_fixture_board,
        .fail_board = true,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const adapter = teamTestAdapter(&fake);
    const view = try fetchTeam(adapter, arena_state.allocator(), core.leagues.find("mlb").?, "PHI");
    try std.testing.expect(view.live == null);
    try std.testing.expectEqual(@as(usize, 1), view.last.len);
}

const team_fixture_schedule_empty =
    \\{"team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"events":[]}
;

// depth: full-season overflow + box-score team totals (appended; existing
// provider tests above untouched). No new upstream fetches: both ride
// payloads the existing paths already fetch.
test "depth fetchTeam threads overflow beyond the last/next five" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 7 past (Aug, all PHI wins) + 7 upcoming (Sep, all pre) around the
    // fake today of 2026-09-07.
    var sched: std.Io.Writer.Allocating = .init(arena);
    try sched.writer.writeAll("{\"team\":{\"id\":\"22\",\"abbreviation\":\"PHI\",\"displayName\":\"Philadelphia Phillies\",\"recordSummary\":\"80-63\",\"standingSummary\":\"2nd in NL East\"},\"events\":[");
    var n: u8 = 1;
    while (n <= 7) : (n += 1) {
        if (n > 1) try sched.writer.writeByte(',');
        try sched.writer.print(
            "{{\"id\":\"p{d}\",\"date\":\"2026-08-{d:0>2}T19:05Z\",\"competitions\":[{{\"id\":\"p{d}\",\"date\":\"2026-08-{d:0>2}T19:05Z\",\"status\":{{\"type\":{{\"state\":\"post\",\"shortDetail\":\"Final\"}}}},\"competitors\":[{{\"homeAway\":\"home\",\"winner\":true,\"score\":{{\"displayValue\":\"5\"}},\"team\":{{\"id\":\"22\",\"abbreviation\":\"PHI\",\"displayName\":\"Philadelphia Phillies\"}},\"probables\":[]}},{{\"homeAway\":\"away\",\"winner\":false,\"score\":{{\"displayValue\":\"3\"}},\"team\":{{\"id\":\"1\",\"abbreviation\":\"NYM\",\"displayName\":\"New York Mets\"}},\"probables\":[]}}]}}]}}",
            .{ n, 19 + n, n, 19 + n },
        );
    }
    n = 1;
    while (n <= 7) : (n += 1) {
        try sched.writer.writeByte(',');
        try sched.writer.print(
            "{{\"id\":\"f{d}\",\"date\":\"2026-09-{d:0>2}T19:05Z\",\"competitions\":[{{\"id\":\"f{d}\",\"date\":\"2026-09-{d:0>2}T19:05Z\",\"status\":{{\"type\":{{\"state\":\"pre\",\"shortDetail\":\"Scheduled\"}}}},\"competitors\":[{{\"homeAway\":\"home\",\"team\":{{\"id\":\"22\",\"abbreviation\":\"PHI\",\"displayName\":\"Philadelphia Phillies\"}},\"probables\":[]}},{{\"homeAway\":\"away\",\"team\":{{\"id\":\"1\",\"abbreviation\":\"NYM\",\"displayName\":\"New York Mets\"}},\"probables\":[]}}]}}]}}",
            .{ n, 7 + n, n, 7 + n },
        );
    }
    try sched.writer.writeAll("]}");
    const sched_body = try sched.toOwnedSlice();
    var fake = TeamFixtureState{
        .teams_body = team_fixture_teams,
        .schedule_body = sched_body,
        .board_body = team_fixture_board,
        .fail_board = true, // live join off; overflow is schedule-only.
    };
    const adapter = teamTestAdapter(&fake);
    const view = try fetchTeam(adapter, arena, core.leagues.find("mlb").?, "PHI");
    try std.testing.expect(view.live == null);
    try std.testing.expectEqual(@as(usize, 5), view.last.len);
    try std.testing.expectEqualStrings("p7", view.last[0].id);
    try std.testing.expectEqualStrings("W 5-3", view.last[0].result);
    try std.testing.expectEqual(@as(usize, 2), view.extra_past.len);
    try std.testing.expectEqualStrings("p2", view.extra_past[0].id);
    try std.testing.expectEqualStrings("p1", view.extra_past[1].id);
    try std.testing.expectEqual(@as(usize, 5), view.next.len);
    try std.testing.expectEqualStrings("f1", view.next[0].id);
    try std.testing.expectEqual(@as(usize, 2), view.extra_next.len);
    try std.testing.expectEqualStrings("f6", view.extra_next[0].id);
    try std.testing.expectEqualStrings("f7", view.extra_next[1].id);
}

test "depth fetchTeam leaves overflow empty within the window" {
    var fake = TeamFixtureState{
        .teams_body = team_fixture_teams,
        .schedule_body = team_fixture_schedule,
        .board_body = team_fixture_board,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const view = try fetchTeam(teamTestAdapter(&fake), arena_state.allocator(), core.leagues.find("mlb").?, "PHI");
    try std.testing.expectEqual(@as(usize, 0), view.extra_past.len);
    try std.testing.expectEqual(@as(usize, 0), view.extra_next.len);
}

test "depth detailFetch threads boxscore team totals and skips cleanly without" {
    const summary =
        \\{"header":{"competitions":[{"id":"401816828","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"15","homeAway":"away","winner":true,"score":5,"team":{"id":"15","displayName":"Atlanta Braves","abbreviation":"ATL"}},{"id":"22","homeAway":"home","winner":false,"score":4,"team":{"id":"22","displayName":"Philadelphia Phillies","abbreviation":"PHI"}}]}]},"boxscore":{"teams":[{"team":{"id":"15","abbreviation":"ATL"},"statistics":[{"name":"batting","displayName":"Batting","stats":[{"name":"atBats","displayName":"At Bats","displayValue":"35"},{"name":"runs","displayName":"Runs","displayValue":"5"}]}]},{"team":{"id":"22","abbreviation":"PHI"},"statistics":[{"name":"batting","displayName":"Batting","stats":[{"name":"atBats","displayName":"At Bats","displayValue":"33"},{"name":"runs","displayName":"Runs","displayValue":"4"}]}]}]}}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = detail_board_fixture };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const with_stats = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "401816828");
    try std.testing.expectEqual(@as(usize, 4), with_stats.team_stats.len);
    try std.testing.expectEqualStrings("ATL At Bats 35", with_stats.team_stats[0]);
    try std.testing.expectEqualStrings("ATL Runs 5", with_stats.team_stats[1]);
    try std.testing.expectEqualStrings("PHI At Bats 33", with_stats.team_stats[2]);
    try std.testing.expectEqualStrings("PHI Runs 4", with_stats.team_stats[3]);

    // No boxscore payload: empty list, never an error.
    var bare_fake = DetailFake{ .summary_body = detail_summary_minimal, .board_body = detail_board_minimal };
    const bare = try detailAdapter(&bare_fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "7");
    try std.testing.expectEqual(@as(usize, 0), bare.team_stats.len);
}

const detail_summary_minimal =
    \\{"header":{"competitions":[{"id":"7","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"a","homeAway":"away","winner":true,"score":"1","team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"id":"h","homeAway":"home","winner":false,"score":"0","team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}}
;

const detail_board_minimal =
    \\{"events":[{"id":"7","name":"Away at Home","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"7","date":"2026-09-06T17:10Z","competitors":[{"homeAway":"away","score":"1","winner":true,"team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"homeAway":"home","score":"0","winner":false,"team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}]}
;
