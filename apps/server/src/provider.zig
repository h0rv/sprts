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

fn getBody(self: EspnAdapter, arena: std.mem.Allocator, url: []const u8) ![]const u8 {
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

    const teams_body = try getBody(self, arena, try espn.buildTeamsUrl(arena, self.base_url, endpoint.sport, endpoint.league));
    const team_id = (try resolveTeamId(teams_body, arena, abbrev)) orelse return error.TeamNotFound;

    var parsed = try parseSchedule(arena, try getBody(
        self,
        arena,
        try espn.buildScheduleUrl(arena, self.base_url, endpoint.sport, endpoint.league, team_id, season),
    ), abbrev);
    if (parsed.events.len == 0) {
        const year = try std.fmt.parseInt(u16, season, 10);
        const previous = try std.fmt.allocPrint(arena, "{d}", .{year - 1});
        parsed = try parseSchedule(arena, try getBody(
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

    return .{
        .league = league.slug,
        .league_name = league.name,
        .team = parsed.team,
        .last = if (split.past.len > 0) try gameRefFromEvent(arena, split.past[split.past.len - 1]) else null,
        .next = try next.toOwnedSlice(arena),
        .live = live,
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
    try std.testing.expectEqualStrings("W 5-3", view.last.?.result);
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
    try std.testing.expect(view.last == null);
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
    try std.testing.expect(view.last != null);
}

const team_fixture_schedule_empty =
    \\{"team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"events":[]}
;
