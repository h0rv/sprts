const std = @import("std");
const core = @import("sprts_core");
const espn = @import("espn_client");

pub const EspnAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8 = "https://site.api.espn.com/apis/site/v2",

    pub fn fetch(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8) !core.domain.Scoreboard {
        const endpoint = endpointFor(league.slug) orelse return error.UnsupportedLeague;
        const compact_day = try core.date.compact(arena, day);
        var client = espn.Client.init(self.allocator, self.io, "");
        defer client.deinit();
        client.withBaseUrl(self.base_url);
        var response = try espn.getScoreboardRaw(&client, endpoint.sport, endpoint.league, compact_day, null, null, null);
        defer response.deinit();
        if (response.status != .ok) {
            std.log.warn("ESPN returned HTTP {d}", .{@intFromEnum(response.status)});
            return error.UpstreamResponse;
        }
        return parseAndNormalize(arena, league, day, response.body);
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

fn parseAndNormalize(arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8, body: []const u8) !core.domain.Scoreboard {
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
