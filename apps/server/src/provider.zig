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

    pub fn today(self: EspnAdapter, arena: std.mem.Allocator) ![]u8 {
        return core.date.todayFromEpoch(arena, self.clock(self.io));
    }

    pub fn fetch(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8) !core.domain.Scoreboard {
        const endpoint = endpointFor(league.slug) orelse return error.UnsupportedLeague;
        const compact_day = try core.date.compact(arena, day);
        const url = try espn.buildScoreboardUrl(arena, self.base_url, endpoint.sport, endpoint.league, compact_day, null, null, null);
        var status: std.http.Status = undefined;
        var body: []const u8 = undefined;
        if (self.transport) |transport| {
            const result = try transport.fetch(arena, url, espn.default_headers);
            status = result.status;
            body = result.body;
        } else {
            var std_transport = espn.StdTransport{ .allocator = self.allocator, .io = self.io };
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
};

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
                        .abbreviation = athlete.shortName,
                    };
                    continue;
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

const ScheduleResponse = struct {
    events: []const ScheduleEvent = &.{},
};

const ScheduleEvent = struct {
    id: []const u8 = "",
    competitions: []const ScheduleCompetition = &.{},
};

const ScheduleCompetition = struct {
    competitors: []const ScheduleCompetitor = &.{},
};

const ScheduleCompetitor = struct {
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
        var std_transport = espn.StdTransport{ .allocator = self.allocator, .io = self.io };
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

fn scheduleOpponentIds(event: ScheduleEvent, team_id: []const u8) ?[]const u8 {
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

fn scheduleWinner(event: ScheduleEvent) ?[]const u8 {
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
        const schedule = std.json.parseFromSliceLeaky(ScheduleResponse, arena, body, .{
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
