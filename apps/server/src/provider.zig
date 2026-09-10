const std = @import("std");
const core = @import("sprts_core");
const espn = @import("espn_client");
const edge_cache = @import("edge_cache.zig");
const native_cache = @import("native_cache.zig");

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
    /// it; most sports ignore it) and `season_type` into `seasontype=`
    /// (1=preseason, 2=regular, 3=postseason; null is the ESPN default).
    /// Without a season type there is no way to reach preseason or playoff
    /// weeks. Null week is the default date-driven board and preserves the
    /// historical call shape. A null `day` omits the `dates=` param entirely
    /// (ESPN resolves the week alone; sending dates alongside a week
    /// empties the slate) — the week-alias lookup path. Non-null days
    /// coerce from `[]const u8`, so existing callers are untouched.
    pub fn fetch(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8) !core.domain.Scoreboard {
        return self.fetchWeek(arena, league, day, null, null);
    }

    /// Football boards resolve weeks, not dates (verified live 2026-09-10:
    /// `?dates=` alone returns an empty slate even mid-season, and `?dates=`
    /// alongside `?week=` empties it too — while `?week=` alone returns the
    /// full 16-game slate). So for football with an explicit week the dates
    /// param is dropped; every other shape keeps its historical URL. Date-
    /// driven football days (week null) still send `dates=` — day-granular
    /// by feed design (game days list that day's games), which the date-
    /// alias lookup depends on for past seasons.
    pub fn fetchWeek(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, day: ?[]const u8, week: ?u16, season_type: ?u16) !core.domain.Scoreboard {
        const body = try self.fetchWeekBody(arena, league, day, week, season_type);
        // Null day only arrives via fetchWeekBoard below (week-alias
        // lookup), which labels explicitly; the fallback keeps board.date
        // well-formed for any future dateless caller.
        return parseAndNormalize(arena, league, day orelse "0000-00-00", body);
    }

    /// Lookup for the human week alias (`/{league}/{YYYY}/week{N}/{away}-{home}`,
    /// football only — enforced by the caller via the league sport): fetch the
    /// week's board with NO dates param and report the response season year.
    /// The caller verifies `season_year` against the URL season (ESPN ignores
    /// unknown season params, so a mismatch must 404, never mislead).
    /// Normalization day is `{season}-01-01`: unused downstream (only the
    /// game id is used), a well-formed placeholder keeping board.date valid.
    pub fn fetchWeekBoard(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, season: []const u8, week: u16) !WeekBoard {
        const body = try self.fetchWeekBody(arena, league, null, week, null);
        const day = try std.fmt.allocPrint(arena, "{s}-01-01", .{season});
        return .{
            .board = try parseAndNormalize(arena, league, day, body),
            .season_year = try parseSeasonYear(arena, body),
        };
    }

    fn fetchWeekBody(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, day: ?[]const u8, week: ?u16, season_type: ?u16) ![]const u8 {
        const endpoint = endpointFor(league.slug) orelse return error.UnsupportedLeague;
        // Football + explicit week: drop dates (see fetchWeek). Other
        // sports keep dates+week: ESPN ignores week there, so the pairing
        // is harmless and preserves historical URLs.
        const drop_dates = week != null and std.mem.eql(u8, endpoint.sport, "football");
        const compact_day = if (drop_dates) null else if (day) |d| try core.date.compact(arena, d) else null;
        const week_int: ?i64 = if (week) |w| @intCast(w) else null;
        const season_int: ?i64 = if (season_type) |t| @intCast(t) else null;
        const url = try espn.buildScoreboardUrl(arena, self.base_url, endpoint.sport, endpoint.league, compact_day, week_int, season_int, null);
        return fetchUrl(self, arena, url);
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

    /// Cache-backed fan-out for home (`/`) and digest (`/all`): one
    /// `NativeCache.getOrFetchBoard` per league — the SAME `(slug, day)`
    /// entries the single-board route uses, so home/board/digest share
    /// fetch-once-per-window with the live (10s) / final (30s) split
    /// (`getOrFetchBoard` probes both TTL variants; liveness is only known
    /// post-fetch). A failed league degrades to a null board (`fetchAll`
    /// parity: one ESPN outage never fails the page); the stale fallback
    /// still applies inside `getOrFetchBoard`. Boards borrow `arena` (hit
    /// clones, miss payloads), so callers must NOT `releaseAll` — `store`
    /// stays null. Sequential: the request arena is not thread-safe, and
    /// warm hits do no I/O, so threads buy nothing here (`fetchAll` keeps
    /// them for the uncached worker path).
    pub fn fetchAllCached(self: EspnAdapter, arena: std.mem.Allocator, cache: *native_cache.NativeCache, day: []const u8, at: i64) ![]LeagueResult {
        const results = try arena.alloc(LeagueResult, core.leagues.all.len);
        for (&core.leagues.all, 0..) |*league, i| {
            results[i] = .{ .league = league };
            const slug = try core.cache.canonicalSlug(arena, league.slug);
            var ctx = BoardCacheCtx{ .adapter = self, .league = league, .day = day };
            if (cache.getOrFetchBoard(arena, slug, day, at, &ctx, fetchBoardCached)) |cached| {
                results[i].board = cached.data.board;
            } else |_| {
                results[i].board = null;
            }
        }
        return results;
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

/// Upstream seam for `fetchAllCached`: one normalized board payload per
/// league, stored by `getOrFetchBoard` under its content-derived TTL
/// variant (live 10s / final 30s).
const BoardCacheCtx = struct { adapter: EspnAdapter, league: *const core.leagues.League, day: []const u8 };

fn fetchBoardCached(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!native_cache.Data {
    const c: *BoardCacheCtx = @ptrCast(@alignCast(ctx));
    return .{ .board = try c.adapter.fetch(arena, c.league, c.day) };
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
    /// Racing carries the track here instead of a competition venue
    /// (`circuit.fullName`, e.g. "Madring"); every other sport omits it.
    circuit: ?BoardCircuit = null,
    /// Tennis carries tournament draws here (event-level competitions
    /// stay empty); every other sport omits them.
    groupings: ?[]const BoardGrouping = null,
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
    broadcasts: []const ScoreboardBroadcast = &.{},
    geoBroadcasts: []const ScoreboardGeoBroadcast = &.{},
    venue: ?BoardVenue = null,
    leaders: ?[]const BoardLeaderCat = null,
};
/// ESPN competition venue: only `fullName` is surfaced (city + court
/// details stay upstream). Absent on sparse payloads.
const BoardVenue = struct {
    fullName: []const u8 = "",
};
/// ESPN racing circuit (event level): the track name standing in for a
/// competition venue on sessions that carry none of their own.
const BoardCircuit = struct {
    fullName: []const u8 = "",
};
/// ESPN board linescore: quarter/period/set score. Display text wins,
/// else the numeric value; tennis sets add `tiebreak` ("7(7)").
/// `period` is explicit on team sports, absent on tennis sets (order).
const BoardLinescore = struct {
    value: std.json.Value = .null,
    displayValue: std.json.Value = .null,
    period: ?i64 = null,
    tiebreak: std.json.Value = .null,
    winner: ?bool = null,
};
/// ESPN board leader category (football-style combined table): the
/// category label plus one entry per leader, each carrying its athlete.
const BoardLeaderCat = struct {
    name: []const u8 = "",
    displayName: []const u8 = "",
    leaders: []const BoardLeaderEntry = &.{},
};
const BoardLeaderEntry = struct {
    displayValue: std.json.Value = .null,
    value: std.json.Value = .null,
    athlete: ?SummaryAthlete = null,
};
/// ESPN tennis draw: the grouping label plus that draw's matches.
/// Matches reuse `Competition` (same keys: id/date/status/
/// competitors/broadcasts/venue); round/notes stay upstream.
const BoardGrouping = struct {
    grouping: ?BoardGroupingMeta = null,
    competitions: []const Competition = &.{},
};
const BoardGroupingMeta = struct {
    displayName: []const u8 = "",
};
/// ESPN competition broadcast: `names` carries the TV networks
/// (e.g. `["ESPN"]`); every other field is ignored.
const ScoreboardBroadcast = struct {
    names: []const []const u8 = &.{},
};
/// ESPN per-market geo feed: only the media short name is usable as a
/// network fallback (e.g. a regional feed name); market/type are ignored.
const ScoreboardGeoBroadcast = struct {
    media: ?ScoreboardGeoMedia = null,
};
const ScoreboardGeoMedia = struct {
    shortName: ?[]const u8 = null,
};
/// Broadcaster for one competition: the first non-empty
/// `broadcasts[].names` entry in order, else the first non-empty
/// geo-feed media short name, else null (absent stays absent).
fn competitionNetwork(competition: Competition) ?[]const u8 {
    for (competition.broadcasts) |broadcast| {
        for (broadcast.names) |name| {
            if (name.len > 0) return name;
        }
    }
    for (competition.geoBroadcasts) |geo| {
        const media = geo.media orelse continue;
        const short = media.shortName orelse continue;
        if (short.len > 0) return short;
    }
    return null;
}
const Competitor = struct {
    id: []const u8 = "",
    order: i64 = 0,
    homeAway: []const u8 = "",
    score: []const u8 = "",
    winner: bool = false,
    team: ?Team = null,
    athlete: ?Athlete = null,
    records: []const Record = &.{},
    linescores: ?[]const BoardLinescore = null,
    form: ?[]const u8 = null,
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

/// Venue for one board game: the competition venue first, else the
/// event circuit (racing sessions carry no venue of their own), else
/// null (absent stays absent).
fn competitionVenue(competition: Competition, event: Event) ?[]const u8 {
    if (competition.venue) |venue| if (venue.fullName.len > 0) return venue.fullName;
    if (event.circuit) |circuit| if (circuit.fullName.len > 0) return circuit.fullName;
    return null;
}

/// One period/set display shared by the board and detail paths: display
/// text wins, else the numeric value, else "-" (never blank). Tennis
/// sets append their tiebreak ("7(7)"). Both pages read the same so a
/// set score can never render "7(7)" on the board and "-" on detail.
fn linescoreDisplay(arena: std.mem.Allocator, display_value: std.json.Value, value: std.json.Value, tiebreak: std.json.Value) ![]const u8 {
    const base = (try jsonText(arena, display_value)) orelse (try jsonText(arena, value)) orelse "-";
    const points = try jsonText(arena, tiebreak);
    if (points) |p| if (p.len > 0) return try std.fmt.allocPrint(arena, "{s}({s})", .{ base, p });
    return base;
}

/// Per-period display for one board competitor: display text, else the
/// numeric value, else "-" (the detail fallback). Tennis sets append
/// their tiebreak ("7(7)"); explicit periods win, else payload order.
fn competitorLines(arena: std.mem.Allocator, linescores: ?[]const BoardLinescore) ![]const core.domain.LineScore {
    const list = linescores orelse return &.{};
    var out: std.ArrayList(core.domain.LineScore) = .empty;
    for (list, 0..) |line, index| {
        const display = try linescoreDisplay(arena, line.displayValue, line.value, line.tiebreak);
        try out.append(arena, .{
            .period = line.period orelse @as(i64, @intCast(index + 1)),
            .display = display,
        });
    }
    return out.toOwnedSlice(arena);
}

/// Combined board leader table (football-style): every category, up to 2
/// entries each, as "{name} {displayValue}". Bare numbers take their
/// category label (the detail soccer rule); empty names/values skip.
fn boardLeaders(arena: std.mem.Allocator, groups: ?[]const BoardLeaderCat) ![]const []const u8 {
    const list = groups orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |category| {
        for (category.leaders[0..@min(category.leaders.len, 2)]) |entry| {
            const name = athleteName(entry.athlete) orelse continue;
            const display = (try jsonText(arena, entry.displayValue)) orelse (try jsonText(arena, entry.value)) orelse "";
            if (display.len == 0) continue;
            if (isBareNumber(display)) {
                const label: []const u8 = if (category.displayName.len > 0)
                    category.displayName
                else if (category.name.len > 0)
                    category.name
                else
                    "total";
                try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ name, label, display }));
            } else {
                try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ name, display }));
            }
        }
    }
    return out.toOwnedSlice(arena);
}

/// Sets won from a tennis match's set linescores (winner flags), as
/// text. Null when no sets are posted yet (unplayed matches score "").
fn setsWon(arena: std.mem.Allocator, competitor: Competitor) !?[]const u8 {
    const lines = competitor.linescores orelse return null;
    if (lines.len == 0) return null;
    var won: i64 = 0;
    for (lines) |line| {
        if (line.winner orelse false) won += 1;
    }
    return try std.fmt.allocPrint(arena, "{d}", .{won});
}

/// One board participant from a raw competitor. Null when the competitor
/// carries neither a team nor an athlete (nothing to name). The
/// `score_override` (tennis sets-won) wins over the score/order rules.
fn boardParticipant(
    arena: std.mem.Allocator,
    competitor: Competitor,
    competitors_len: usize,
    score_override: ?[]const u8,
) !?core.domain.Participant {
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
        return null;
    };
    const record: ?[]const u8 = record: {
        for (competitor.records) |r| {
            if (std.mem.eql(u8, r.type, "total") and r.summary.len > 0) break :record r.summary;
        }
        break :record null;
    };
    const score = if (score_override) |explicit|
        explicit
    else if (competitor.score.len > 0)
        competitor.score
    else if (competitors_len > 2 and competitor.order > 0)
        try std.fmt.allocPrint(arena, "#{d}", .{competitor.order})
    else
        "";
    return .{
        .id = identity.id,
        .name = identity.name,
        .abbreviation = identity.abbreviation,
        .score = score,
        .winner = competitor.winner,
        .home_away = if (competitor.homeAway.len > 0) competitor.homeAway else null,
        .record = record,
        .lines = try competitorLines(arena, competitor.linescores),
        .form = competitor.form,
    };
}

const BoardGameArgs = struct {
    id: []const u8,
    name: []const u8,
    starts_at: []const u8,
    state: []const u8,
    status: []const u8,
    participants: []const core.domain.Participant,
    network: ?[]const u8,
    venue: ?[]const u8,
    leaders: []const []const u8,
};

fn assembleBoardGame(args: BoardGameArgs) core.domain.Game {
    return .{
        .id = args.id,
        .name = args.name,
        .starts_at = args.starts_at,
        .state = args.state,
        .status = args.status,
        .participants = args.participants,
        .network = args.network,
        .venue = args.venue,
        .leaders = args.leaders,
    };
}

/// One normalized board game from an event plus one competition (or one
/// tennis `groupings` match, which reuses `Competition`). `game_id` carries
/// the caller's id fallback rule; `tennis` selects sets-won scores and the
/// day filter (a tennis match boards only when dated the requested `day`;
/// dateless callers match nothing, never everything). Returns null for a
/// filtered-out tennis match; event-level competitions always build.
fn buildBoardGame(
    arena: std.mem.Allocator,
    event: Event,
    competition: Competition,
    day: []const u8,
    game_id: []const u8,
    tennis: bool,
) !?core.domain.Game {
    if (tennis) {
        if (competition.date.len < 10) return null;
        if (!std.mem.eql(u8, competition.date[0..10], day)) return null;
    }
    var participants: std.ArrayList(core.domain.Participant) = .empty;
    for (competition.competitors) |competitor| {
        const score_override = if (tennis) try setsWon(arena, competitor) else null;
        if (try boardParticipant(arena, competitor, competition.competitors.len, score_override)) |participant| {
            try participants.append(arena, participant);
        }
    }
    const status_type = if (competition.status) |status|
        status.type
    else if (event.status) |status|
        status.type
    else
        StatusType{};
    return assembleBoardGame(.{
        .id = game_id,
        .name = if (event.name.len > 0) event.name else event.shortName,
        .starts_at = if (competition.date.len > 0) competition.date else event.date,
        .state = status_type.state,
        .status = if (status_type.shortDetail.len > 0) status_type.shortDetail else status_type.description,
        .participants = try participants.toOwnedSlice(arena),
        .network = competitionNetwork(competition),
        .venue = competitionVenue(competition, event),
        .leaders = try boardLeaders(arena, competition.leaders),
    });
}

pub fn parseAndNormalize(arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8, body: []const u8) !core.domain.Scoreboard {
    const response = try std.json.parseFromSliceLeaky(ScoreboardResponse, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    var games: std.ArrayList(core.domain.Game) = .empty;
    for (response.events) |event| {
        for (event.competitions, 0..) |competition, competition_index| {
            const game_id = if (competition.id.len > 0) competition.id else if (competition_index == 0) event.id else try std.fmt.allocPrint(arena, "{s}-{d}", .{ event.id, competition_index });
            if (try buildBoardGame(arena, event, competition, day, game_id, false)) |game| {
                try games.append(arena, game);
            }
        }
        // Tennis tournaments carry no event-level competitions: the
        // draws live under `groupings`. Only matches dated the requested
        // day board (dateless callers match nothing, never everything).
        if (event.groupings) |groupings| {
            for (groupings) |grouping| {
                for (grouping.competitions) |match| {
                    const game_id = if (match.id.len > 0) match.id else event.id;
                    if (try buildBoardGame(arena, event, match, day, game_id, true)) |game| {
                        try games.append(arena, game);
                    }
                }
            }
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

test "competition broadcasts normalize to the game network" {
    const fixture =
        \\{"events":[{"id":"401","name":"Away at Home","date":"2026-09-06T17:00Z","status":{"type":{"state":"pre","shortDetail":"7:05 PM ET"}},"competitions":[{"broadcasts":[{"names":["ESPN"]}],"competitors":[{"homeAway":"away","score":"","team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"homeAway":"home","score":"","team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const board = try parseAndNormalize(arena_state.allocator(), core.leagues.find("mlb").?, "2026-09-06", fixture);
    try std.testing.expectEqualStrings("ESPN", board.games[0].network.?);
}

test "game network is null without broadcasts and falls back to geo feeds" {
    // No broadcasts at all: absent stays absent.
    const bare =
        \\{"events":[{"id":"401","name":"Away at Home","date":"2026-09-06T17:00Z","competitions":[{"competitors":[{"homeAway":"away","team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"homeAway":"home","team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const plain = try parseAndNormalize(arena_state.allocator(), core.leagues.find("mlb").?, "2026-09-06", bare);
    try std.testing.expect(plain.games[0].network == null);
    // Empty names skipped; geo media short name fills the gap.
    const geo =
        \\{"events":[{"id":"402","name":"Away at Home","date":"2026-09-06T17:00Z","competitions":[{"broadcasts":[{"names":[]}],"geoBroadcasts":[{"media":{"shortName":"MASN"},"market":{"id":"x"},"type":{}}],"competitors":[{"homeAway":"away","team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"homeAway":"home","team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}]}
    ;
    const fallback = try parseAndNormalize(arena_state.allocator(), core.leagues.find("mlb").?, "2026-09-06", geo);
    try std.testing.expectEqualStrings("MASN", fallback.games[0].network.?);
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
    // Football + week drops dates: dates alongside a week empties the
    // slate (verified live), the week alone resolves the full slate.
    _ = try adapter.fetchWeek(arena, core.leagues.find("nfl").?, "2026-09-06", 2, null);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?week=2",
        fake.seen_url.?,
    );
    _ = try adapter.fetchWeek(arena, core.leagues.find("nfl").?, "2026-09-06", null, null);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?dates=20260906",
        fake.seen_url.?,
    );
    // Non-football keeps dates+week (ESPN ignores week there; the pairing
    // is harmless and preserves historical URLs).
    _ = try adapter.fetchWeek(arena, core.leagues.find("mlb").?, "2026-09-06", 2, null);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/baseball/mlb/scoreboard?dates=20260906&week=2",
        fake.seen_url.?,
    );
}

test "fetchWeek threads seasontype into the scoreboard URL" {
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
    const nfl = core.leagues.find("nfl").?;
    // Playoff week: week alone (dates dropped) plus seasontype=3.
    _ = try adapter.fetchWeek(arena, nfl, "2026-09-06", 1, 3);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?week=1&seasontype=3",
        fake.seen_url.?,
    );
    // Preseason: seasontype=1 rides the same way.
    _ = try adapter.fetchWeek(arena, nfl, "2026-09-06", 1, 1);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?week=1&seasontype=1",
        fake.seen_url.?,
    );
    // Null season type preserves the bare week shape.
    _ = try adapter.fetchWeek(arena, nfl, null, 1, null);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?week=1",
        fake.seen_url.?,
    );
    // Season type without a week still threads through (date-driven).
    _ = try adapter.fetchWeek(arena, nfl, "2026-09-06", null, 3);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?dates=20260906&seasontype=3",
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

/// Counting fake for `fetchAllCached` (never live ESPN): records every
/// upstream URL it sees. The fan-out is sequential, so no locking. Serves
/// a live slate for the MLB endpoint and empty slates elsewhere, so a
/// refetched board keeps the liveness it was seeded with.
const CountingTransport = struct {
    calls: usize = 0,
    last_url: ?[]const u8 = null,
    live_body: []const u8,
    empty_body: []const u8 = "{\"events\":[]}",

    fn dispatch(ptr: *anyopaque, arena: std.mem.Allocator, url: []const u8, extra_headers: []const std.http.Header) anyerror!espn.FetchResult {
        _ = extra_headers;
        const self: *CountingTransport = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.last_url = try arena.dupe(u8, url);
        const body = if (std.mem.indexOf(u8, url, "baseball/mlb") != null) self.live_body else self.empty_body;
        return .{ .status = .ok, .body = try arena.dupe(u8, body) };
    }

    fn asTransport(self: *CountingTransport) espn.HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

const home_cache_day = "2026-09-06";

/// Final seed board for one league; `with_game` adds a single post game so
/// the test can prove the content came from the cache (the transport
/// serves only empties for non-MLB endpoints).
fn seedFinalBoard(league_slug: []const u8, league_name: []const u8, with_game: bool) core.domain.Scoreboard {
    if (with_game) return .{
        .league = league_slug,
        .league_name = league_name,
        .date = home_cache_day,
        .source = "seed",
        .games = &.{.{
            .id = "seed-1",
            .name = "Seeded Away at Seeded Home",
            .starts_at = "2026-09-06T17:00Z",
            .state = "post",
            .status = "Final",
            .participants = &.{},
        }},
    };
    return .{
        .league = league_slug,
        .league_name = league_name,
        .date = home_cache_day,
        .source = "seed",
        .games = &.{},
    };
}

/// Live seed board: one in-progress game, so the entry lands under the
/// 10s live TTL variant.
fn seedLiveBoard(league_slug: []const u8, league_name: []const u8) core.domain.Scoreboard {
    return .{
        .league = league_slug,
        .league_name = league_name,
        .date = home_cache_day,
        .source = "seed",
        .games = &.{.{
            .id = "live-1",
            .name = "Seeded Away at Seeded Home",
            .starts_at = "2026-09-06T17:00Z",
            .state = "in",
            .status = "Top 7th",
            .participants = &.{},
        }},
    };
}

fn homeCacheTestAdapter(fake: *CountingTransport, threaded: *std.Io.Threaded) EspnAdapter {
    return .{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
        .base_url = "https://example.test/base",
        .transport = fake.asTransport(),
        .clock = fakeClock,
    };
}

fn findResult(results: []LeagueResult, slug: []const u8) LeagueResult {
    for (results) |result| if (std.mem.eql(u8, result.league.slug, slug)) return result;
    unreachable;
}

test "fetchAllCached serves seeded entries with zero upstream fetches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    var cache = native_cache.NativeCache.init(std.testing.allocator, threaded.io(), fakeClock);
    defer cache.deinit();
    const t0: i64 = 1_000_000;
    for (&core.leagues.all) |*league|
        try cache.put(
            .{ .board = .{ .slug = league.slug, .day = home_cache_day, .live = false } },
            .{ .board = seedFinalBoard(league.slug, league.name, std.mem.eql(u8, league.slug, "mlb")) },
            t0,
        );
    var fake = CountingTransport{ .live_body = "{\"events\":[]}" };
    const adapter = homeCacheTestAdapter(&fake, &threaded);
    // Near the end of the 30s final window: still zero upstream fetches.
    const results = try adapter.fetchAllCached(arena, &cache, home_cache_day, t0 + edge_cache.fresh_ttl_s - 1);
    try std.testing.expectEqual(core.leagues.all.len, results.len);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(fake.last_url == null);
    for (results, 0..) |result, i| {
        try std.testing.expectEqualStrings(core.leagues.all[i].slug, result.league.slug);
        try std.testing.expect(result.board != null);
        // Boards borrow the request arena: no per-league stores to release.
        try std.testing.expect(result.store == null);
    }
    const mlb = findResult(results, "mlb");
    try std.testing.expectEqual(@as(usize, 1), mlb.board.?.games.len);
    try std.testing.expectEqualStrings("seed-1", mlb.board.?.games[0].id);
}

test "fetchAllCached refetches live boards on the 10s window while finals hold 30s" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    var cache = native_cache.NativeCache.init(std.testing.allocator, threaded.io(), fakeClock);
    defer cache.deinit();
    const t0: i64 = 1_000_000;
    for (&core.leagues.all) |*league| {
        const live = std.mem.eql(u8, league.slug, "mlb");
        const board = if (live) seedLiveBoard(league.slug, league.name) else seedFinalBoard(league.slug, league.name, false);
        try cache.put(
            .{ .board = .{ .slug = league.slug, .day = home_cache_day, .live = live } },
            .{ .board = board },
            t0,
        );
    }
    const live_body =
        \\{\"events\":[{\"id\":\"9\",\"name\":\"Away at Home\",\"date\":\"2026-09-06T17:00Z\",\"status\":{\"type\":{\"state\":\"in\",\"shortDetail\":\"Top 7th\"}},\"competitions\":[{\"id\":\"9\",\"date\":\"2026-09-06T17:00Z\",\"status\":{\"type\":{\"state\":\"in\",\"shortDetail\":\"Top 7th\"}},\"competitors\":[]}]}]}
    ;
    var fake = CountingTransport{ .live_body = live_body };
    const adapter = homeCacheTestAdapter(&fake, &threaded);
    const mlb_url = "https://example.test/base/sports/baseball/mlb/scoreboard?dates=20260906";

    // Inside the 10s live window: everything cached, zero fetches, and the
    // seeded live game is what home would render.
    const warm = try adapter.fetchAllCached(arena, &cache, home_cache_day, t0 + edge_cache.live_fresh_ttl_s - 1);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqualStrings("in", findResult(warm, "mlb").board.?.games[0].state);

    // Past the live window but inside the final window: exactly one fetch,
    // and it is the live league's URL; every final board still hits.
    const results = try adapter.fetchAllCached(arena, &cache, home_cache_day, t0 + edge_cache.live_fresh_ttl_s);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings(mlb_url, fake.last_url.?);
    // The refetch stays live (in-progress slate), so it rolls the 10s
    // window instead of promoting to the 30s one.
    const mlb = findResult(results, "mlb");
    try std.testing.expectEqual(@as(usize, 1), mlb.board.?.games.len);
    try std.testing.expectEqualStrings("in", mlb.board.?.games[0].state);

    // At t0+29 the live board (re-stored at t0+10 on its 10s window)
    // refetches while every final board (t0 on the 30s window) still
    // hits: one fetch again, same URL.
    fake.calls = 0;
    fake.last_url = null;
    _ = try adapter.fetchAllCached(arena, &cache, home_cache_day, t0 + edge_cache.fresh_ttl_s - 1);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings(mlb_url, fake.last_url.?);
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
    // Football (NCAAF/NFL) ships scoring plays here instead of `plays`:
    // every entry is a scoring play, `period` carries `number` only.
    scoringPlays: ?[]const SummaryScoringPlay = null,
    boxscore: ?SummaryBoxscore = null,
    gameInfo: ?SummaryGameInfo = null,
    seasonseries: ?[]const SummarySeries = null,
    // Football-style top-level leaders (per-team categories with display
    // values, e.g. "21/25, 320 YDS, 3 TD"). Preferred over the boxscore
    // fallback when present; the wire shape (`leaders: []string`) is same.
    leaders: ?[]const SummaryTopTeam = null,
    // Injury report: per-team entries with status + athlete; details
    // carry the body part when ESPN specifies one.
    injuries: ?[]const SummaryInjuryTeam = null,
    // Win-probability samples across the game; the last entry is the
    // current (live) or final probability. Empty when ESPN ships none.
    winprobability: ?[]const SummaryWinProb = null,
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
    // Tennis sets carry numeric values with optional tiebreaks and no
    // display text (same wire shape as the board path); the detail
    // mapping renders them with the shared board semantics ("7(7)").
    value: std.json.Value = .null,
    tiebreak: std.json.Value = .null,
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
    // Football `scoringPlays` periods carry only this (1-4 = quarters).
    number: ?i64 = null,
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

const SummaryScoringPlay = struct {
    text: []const u8 = "",
    awayScore: std.json.Value = .null,
    homeScore: std.json.Value = .null,
    period: ?SummaryPeriod = null,
};

const SummaryTopTeam = struct {
    team: ?SummaryTeam = null,
    leaders: []const SummaryTopCategory = &.{},
};

const SummaryTopCategory = struct {
    name: []const u8 = "",
    displayName: []const u8 = "",
    leaders: []const SummaryTopEntry = &.{},
};

const SummaryTopEntry = struct {
    displayValue: std.json.Value = .null,
    value: std.json.Value = .null,
    athlete: ?SummaryAthlete = null,
};

const SummaryInjuryTeam = struct {
    team: ?SummaryTeam = null,
    injuries: []const SummaryInjury = &.{},
};

const SummaryInjury = struct {
    status: std.json.Value = .null,
    athlete: ?SummaryAthlete = null,
    details: ?SummaryInjuryDetails = null,
};

const SummaryInjuryDetails = struct {
    type: []const u8 = "",
};

const SummaryWinProb = struct {
    homeWinPercentage: ?f64 = null,
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
    // Grouped shape (baseball-style): per-stat rows live in `stats`.
    stats: []const SummaryTeamStat = &.{},
    // Flat shape (football-style): this entry IS one stat; the label is
    // `label`, falling back to `displayName`/`name`.
    label: []const u8 = "",
    displayValue: std.json.Value = .null,
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
    // Football groups omit `names` and key columns by stat id instead
    // (e.g. "completions/passingAttempts"); the totals label falls back
    // to a humanized first key.
    keys: []const []const u8 = &.{},
    totals: []const std.json.Value = &.{},
    athletes: []const SummaryPlayerAthlete = &.{},
};

const SummaryPlayerAthlete = struct {
    athlete: ?SummaryAthleteId = null,
    stats: []const std.json.Value = &.{},
    batOrder: ?i64 = null,
    starter: ?bool = null,
    position: ?SummaryPosition = null,
};

const SummaryPosition = struct {
    abbreviation: []const u8 = "",
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

/// Single upstream GET used by every provider fetch: honors the injected
/// transport with a `StdTransport` fallback, and maps any non-200 to
/// `error.UpstreamResponse`. URL construction stays with the callers
/// (`fetchWeekBody` builds scoreboard URLs; detail/schedule/teams build
/// theirs); only the transport-fallback + status check live here.
fn fetchUrl(self: EspnAdapter, arena: std.mem.Allocator, url: []const u8) ![]const u8 {
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

/// Series line. Regular-season (`seasonseries`) wording stays modest —
/// "X leads season series W-L" / "X won season series W-L" / "Season
/// series tied W-L" — because "wins series" overstates a 4-game set.
/// Playoff (`header.competitions[].series`) wording keeps the historical
/// shape ("X leads W-L", anything else verbatim). Either source is
/// suppressed when it is not a series at all (one or zero total games:
/// "game 1 of 1"), yielding null. Prefers top-level seasonseries, falls
/// back to the header competition series.
fn summarySeries(arena: std.mem.Allocator, response: SummaryResponse, game_id: []const u8) !?[]const u8 {
    const seasonseries: []const SummarySeries = response.seasonseries orelse &.{};
    const comp_series: []const SummarySeries = if (response.header) |header|
        (if (header.competitions.len > 0) (header.competitions[0].series orelse &.{}) else &.{})
    else
        &.{};
    const from_season: bool = seasonseries.len > 0 and seasonseries[0].summary.len > 0;
    const source: ?SummarySeries = if (from_season)
        seasonseries[0]
    else if (comp_series.len > 0 and comp_series[0].summary.len > 0)
        comp_series[0]
    else
        null;
    const series = source orelse return null;
    const total: i64 = if (series.totalCompetitions > 0) series.totalCompetitions else @intCast(series.events.len);
    // One game is not a series (and zero games is no information at all).
    if (total <= 1) return null;
    // ESPN-verbatim playoff summaries can echo the view's own prefix
    // ("Series tied 1-1" renders as "Series: Series tied 1-1"). Strip
    // one leading "series "/"series: " (case-insensitive) so the render
    // stays single; mid-string wording ("X leads series ...") is untouched.
    const summary = stripSeriesPrefix(series.summary);
    const cleaned: []const u8 = if (from_season)
        try seasonSeriesText(arena, summary)
    else if (std.mem.indexOf(u8, summary, " leads series ")) |at|
        try std.fmt.allocPrint(arena, "{s} leads {s}", .{
            summary[0..at],
            summary[at + " leads series ".len ..],
        })
    else
        summary;
    var position: ?usize = null;
    for (series.events, 0..) |event, index| if (std.mem.eql(u8, event.id, game_id)) {
        position = index + 1;
        break;
    };
    if (position) |n| {
        return try std.fmt.allocPrint(arena, "{s} (game {d} of {d})", .{ cleaned, n, total });
    }
    return cleaned;
}

/// One leading "series "/"series: " (any case) is the view's own prefix
/// echoed back by ESPN verbatim ("Series tied 1-1"); anything else —
/// including a bare "Series" with no trailing separator — passes through.
fn stripSeriesPrefix(text: []const u8) []const u8 {
    if (text.len > 7 and std.ascii.eqlIgnoreCase(text[0..7], "series:")) {
        const rest = std.mem.trimStart(u8, text[7..], " ");
        if (rest.len > 0) return rest;
        return text;
    }
    if (text.len > 7 and std.ascii.eqlIgnoreCase(text[0..6], "series") and text[6] == ' ') {
        const rest = text[7..];
        if (rest.len > 0) return rest;
    }
    return text;
}

/// Regular-season series phrasing: "ATL leads series 2-1" becomes
/// "ATL leads season series 2-1", "BOS wins series 3-1" becomes
/// "BOS won season series 3-1" (a completed set, not a playoff win).
/// Anything else passes through verbatim.
fn seasonSeriesText(arena: std.mem.Allocator, summary: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, summary, " leads series ")) |at| {
        return std.fmt.allocPrint(arena, "{s} leads season series {s}", .{
            summary[0..at],
            summary[at + " leads series ".len ..],
        });
    }
    if (std.mem.indexOf(u8, summary, " wins series ")) |at| {
        return std.fmt.allocPrint(arena, "{s} won season series {s}", .{
            summary[0..at],
            summary[at + " wins series ".len ..],
        });
    }
    if (std.mem.indexOf(u8, summary, " won series ")) |at| {
        return std.fmt.allocPrint(arena, "{s} won season series {s}", .{
            summary[0..at],
            summary[at + " won series ".len ..],
        });
    }
    return summary;
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
        const body = fetchUrl(self, arena, url) catch continue;
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
        // A lone game is a matchup, not a series; the summary path makes
        // the same call, so both builders agree.
        if (total <= 1) return null;
        if (self_wins == other_wins) {
            return try std.fmt.allocPrint(arena, "Season series tied {d}-{d} (game {d} of {d})", .{ self_wins, other_wins, n, total });
        }
        const leader = if (self_wins > other_wins) team_abbrs[side] else team_abbrs[1 - side];
        const wins = @max(self_wins, other_wins);
        const losses = @min(self_wins, other_wins);
        return try std.fmt.allocPrint(arena, "{s} leads season series {d}-{d} (game {d} of {d})", .{ leader, wins, losses, n, total });
    }
    return null;
}

// depth: box-score team totals (additive; existing detail code above untouched).
//
// ESPN already ships `boxscore.teams[].statistics[]` in the summary payload
// this path fetches; it was simply never threaded through. Formats up to 4
// stats per side (first 2 teams) as "{ABBR} {label} {value}" so both sides
// stay visible under the renderer's 8-line cap. Both ESPN shapes are
// mapped: grouped (`statistics[].stats[]`, baseball-style) and flat
// (`statistics[]` carrying `label`/`displayValue` directly,
// football-style). Generic participation counters ("Games Played",
// "Team Games Played" — the only exact generic counters observed across
// live baseball/football payloads) are filtered so JSON and text stay in
// parity; the list is pinned by test. A null boxscore or empty statistics
// yield an empty list (section skipped, never an error).
const junk_team_stats = [_][]const u8{ "Games Played", "Team Games Played" };

fn isJunkTeamStat(name: []const u8, display_name: []const u8, label: []const u8) bool {
    for (junk_team_stats) |junk| {
        if (std.mem.eql(u8, name, junk) or std.mem.eql(u8, display_name, junk) or std.mem.eql(u8, label, junk)) return true;
    }
    return false;
}

fn boxTeamStats(arena: std.mem.Allocator, boxscore: ?SummaryBoxscore) ![]const []const u8 {
    const box = boxscore orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (box.teams[0..@min(box.teams.len, 2)]) |side| {
        const abbr: []const u8 = if (side.team) |team| team.abbreviation else "?";
        var taken: usize = 0;
        outer: for (side.statistics) |group| {
            if (group.stats.len > 0) {
                for (group.stats) |stat| {
                    if (taken >= 4) break :outer;
                    const value = (try jsonText(arena, stat.displayValue)) orelse continue;
                    if (value.len == 0) continue;
                    const label: []const u8 = if (stat.displayName.len > 0) stat.displayName else stat.name;
                    if (label.len == 0) continue;
                    if (isJunkTeamStat(stat.name, stat.displayName, "")) continue;
                    try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ abbr, label, value }));
                    taken += 1;
                }
                continue;
            }
            // Flat shape: one stat per entry.
            if (taken >= 4) break :outer;
            const value = (try jsonText(arena, group.displayValue)) orelse continue;
            if (value.len == 0) continue;
            const label: []const u8 = if (group.label.len > 0) group.label else if (group.displayName.len > 0) group.displayName else group.name;
            if (label.len == 0) continue;
            if (isJunkTeamStat(group.name, group.displayName, group.label)) continue;
            try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ abbr, label, value }));
            taken += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

/// Period label for a football `scoringPlays` entry: the display value
/// when ESPN ships one, otherwise "Q{n}" from the bare quarter number
/// (football periods never carry display text — verified live NCAAF
/// 2026-09-05: `period: {"number": 1}`). Empty when neither exists.
fn scoringPlayPeriod(arena: std.mem.Allocator, period: ?SummaryPeriod) ![]const u8 {
    const p = period orelse return "";
    if (p.displayValue.len > 0) return p.displayValue;
    if (p.number) |n| return try std.fmt.allocPrint(arena, "Q{d}", .{n});
    return "";
}

/// Top-level leaders (football-style): up to 2 teams, 2 categories each,
/// 2 entries each, as "{name} {displayValue}" when the display value is
/// self-describing ("21/25, 320 YDS, 3 TD"). Soccer categories ship bare
/// numbers instead ("5" under "Shots"), so bare values render with
/// their category label ("Dani Olmo Shots 5") rather than a bare
/// number. Entries without a name or a value are skipped.
fn topLeaders(arena: std.mem.Allocator, groups: ?[]const SummaryTopTeam, out: *std.ArrayList([]const u8)) !void {
    const list = groups orelse return;
    for (list[0..@min(list.len, 2)]) |group| {
        for (group.leaders[0..@min(group.leaders.len, 2)]) |category| {
            for (category.leaders[0..@min(category.leaders.len, 2)]) |entry| {
                const name = athleteName(entry.athlete) orelse continue;
                const display = (try jsonText(arena, entry.displayValue)) orelse (try jsonText(arena, entry.value)) orelse "";
                if (display.len == 0) continue;
                if (isBareNumber(display)) {
                    const label: []const u8 = if (category.displayName.len > 0)
                        category.displayName
                    else if (category.name.len > 0)
                        try humanizeStatKey(arena, category.name)
                    else
                        "total";
                    try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ name, label, display }));
                } else {
                    try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ name, display }));
                }
            }
        }
    }
}

/// Boxscore leaders fallback (team totals plus top performers per side).
/// The column label is the first non-empty `names` entry (soccer groups
/// may carry empty names); football groups omit `names` and key columns
/// by stat id instead, so the label falls back to a humanized first
/// non-empty key ("completions/passingAttempts" -> "Completions/passing
/// attempts") instead of the bare "total". Athlete rows with bare
/// numbers ("5") carry the same label ("Dani Olmo Shots 5");
/// self-describing composites ("2-4", "18/33") keep the historical
/// bare shape.
fn boxscoreLeaders(arena: std.mem.Allocator, boxscore: SummaryBoxscore, out: *std.ArrayList([]const u8)) !void {
    const groups = boxscore.players[0..@min(boxscore.players.len, 2)];
    for (groups) |group| {
        const abbr: []const u8 = if (group.team) |team| team.abbreviation else "?";
        for (group.statistics[0..@min(group.statistics.len, 1)]) |stats| {
            const label = try statLabel(arena, stats.names, stats.keys);
            if (stats.totals.len > 0) {
                const total = (try jsonText(arena, stats.totals[0])) orelse "?";
                try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ abbr, label, total }));
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
                        if (isBareNumber(head)) {
                            try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ name, label, head }));
                        } else {
                            try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ name, head }));
                        }
                        continue;
                    }
                }
                try out.append(arena, name);
            }
        }
    }
}

/// First usable column label for a boxscore stat group: the first
/// non-empty `names` entry, else a humanized first non-empty key, else
/// "total". Soccer groups may carry empty names, so a blank entry must
/// not win over a usable key.
fn statLabel(arena: std.mem.Allocator, names: []const []const u8, keys: []const []const u8) ![]const u8 {
    for (names) |name| if (name.len > 0) return name;
    for (keys) |key| if (key.len > 0) return try humanizeStatKey(arena, key);
    return "total";
}

/// A leader value with no self-describing structure ("5", "108") needs
/// its stat label attached; composites ("2-4", "18/33",
/// "21/25, 320 YDS, 3 TD") already read on their own and keep the
/// historical shape.
fn isBareNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if ((c < '0' or c > '9') and c != '.' and c != ',') return false;
    }
    return true;
}

/// Starting lineups from the boxscore batting group (keys carrying
/// `atBats`): starters with a batting order, in payload order, one side
/// per player group. Groups without a batting group (football shapes)
/// contribute nothing, so other sports keep empty lineups.
fn boxscoreLineups(arena: std.mem.Allocator, boxscore: SummaryBoxscore, out: *std.ArrayList(core.detail.LineupSide)) !void {
    const groups = boxscore.players[0..@min(boxscore.players.len, 2)];
    for (groups) |group| {
        const abbr: []const u8 = if (group.team) |team| team.abbreviation else "?";
        const batting = for (group.statistics) |stats| {
            if (statKeyIndex(stats.keys, "atBats") != null) break stats;
        } else continue;
        const hab = statKeyIndex(batting.keys, "hits-atBats") orelse 0;
        const runs = statKeyIndex(batting.keys, "runs");
        const rbis = statKeyIndex(batting.keys, "RBIs");
        const walks = statKeyIndex(batting.keys, "walks");
        const strikeouts = statKeyIndex(batting.keys, "strikeouts");
        const average = statKeyIndex(batting.keys, "avg");
        var entries: std.ArrayList(core.detail.LineupEntry) = .empty;
        for (batting.athletes) |entry| {
            if ((entry.starter orelse true) == false) continue;
            const order = entry.batOrder orelse continue;
            const reference = entry.athlete orelse continue;
            const name: []const u8 = if (reference.displayName.len > 0)
                reference.displayName
            else if (reference.fullName.len > 0)
                reference.fullName
            else
                continue;
            const pos: []const u8 = if (entry.position) |p| p.abbreviation else "";
            try entries.append(arena, .{
                .order = order,
                .position = pos,
                .name = name,
                .hitting = (if (hab < entry.stats.len) try jsonText(arena, entry.stats[hab]) else null) orelse "",
                .runs = statText(arena, entry.stats, runs) catch "",
                .rbis = statText(arena, entry.stats, rbis) catch "",
                .walks = statText(arena, entry.stats, walks) catch "",
                .strikeouts = statText(arena, entry.stats, strikeouts) catch "",
                .average = statText(arena, entry.stats, average) catch "",
            });
        }
        if (entries.items.len == 0) continue;
        try out.append(arena, .{
            .team = abbr,
            .total = (if (hab < batting.totals.len) try jsonText(arena, batting.totals[hab]) else null) orelse "",
            .entries = try entries.toOwnedSlice(arena),
        });
    }
}

fn statKeyIndex(keys: []const []const u8, wanted: []const u8) ?usize {
    for (keys, 0..) |key, i| if (std.mem.eql(u8, key, wanted)) return i;
    return null;
}

fn statText(arena: std.mem.Allocator, stats: []const std.json.Value, index: ?usize) ![]const u8 {
    const i = index orelse return "";
    if (i >= stats.len) return "";
    return (try jsonText(arena, stats[i])) orelse "";
}

/// "completions/passingAttempts" -> "Completions/passing attempts": a
/// space before each camel hump (an uppercase following a lowercase or
/// digit, lowercased), first letter capitalized. Acronym runs ("H-AB")
/// pass through untouched. Purely presentational for key-only stat groups.
fn humanizeStatKey(arena: std.mem.Allocator, key: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    for (key, 0..) |c, i| {
        const prev: u8 = if (i > 0) key[i - 1] else 0;
        const prev_lower = (prev >= 'a' and prev <= 'z') or (prev >= '0' and prev <= '9');
        if (i > 0 and c >= 'A' and c <= 'Z' and prev_lower) {
            try out.writer.writeByte(' ');
            try out.writer.writeByte(c + ('a' - 'A'));
        } else if (i == 0 and c >= 'a' and c <= 'z') {
            try out.writer.writeByte(c - ('a' - 'A'));
        } else {
            try out.writer.writeByte(c);
        }
    }
    return out.toOwnedSlice();
}

/// Board lookup for one game id: the UTC-date board first (existing
/// behavior — ESPN answers dateless summary lookups against it), then the
/// Eastern-day board derived from the summary timestamp. Evening games in
/// the Americas date next-day UTC while boards and links run Eastern, so
/// the fallback is what keeps them viewable. Returns the game plus the
/// day of the board that held it (callers date the detail off the match,
/// never the raw UTC stamp). Null when both boards miss.
fn findBoardGame(
    self: EspnAdapter,
    arena: std.mem.Allocator,
    league: *const core.leagues.League,
    game_id: []const u8,
    utc_day: []const u8,
    timestamp: []const u8,
) !?struct { game: core.domain.Game, day: []const u8 } {
    const board = try self.fetch(arena, league, utc_day);
    for (board.games) |game| {
        if (std.mem.eql(u8, game.id, game_id)) return .{ .game = game, .day = utc_day };
    }
    const epoch = core.date.parseTimestampUTC(timestamp) orelse return null;
    const et_day = try core.date.todayInTz(arena, epoch, core.date.etOffsetMinutes(epoch));
    if (std.mem.eql(u8, et_day, utc_day)) return null;
    const et_board = try self.fetch(arena, league, et_day);
    for (et_board.games) |game| {
        if (std.mem.eql(u8, game.id, game_id)) return .{ .game = game, .day = et_day };
    }
    return null;
}

pub fn detailFetch(self: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League, game_id: []const u8) !core.detail.GameDetail {
    const endpoint = endpointFor(league.slug) orelse return error.UnsupportedLeague;
    const summary_url = try espn.buildSummaryUrl(arena, self.base_url, endpoint.sport, endpoint.league, game_id);
    const summary_body = try fetchUrl(self, arena, summary_url);
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
    // an unknown id even when the summary endpoint answered. Evening games
    // in the Americas land on the next UTC day while ESPN boards — and the
    // links rendered from them — run on Eastern days, so fall back to the
    // ET-day board before calling the id unknown (an 8:20 PM ET kickoff is
    // dated next-day UTC). Truly unknown ids miss both boards and still 404.
    const hit = try findBoardGame(self, arena, league, game_id, day, competition.date) orelse
        return error.GameNotFound;
    const game = hit.game;

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
                // Board semantics (display, else value, else "-", plus
                // tiebreak): tennis summaries carry numeric set values
                // with no display text, which the old display-only read
                // rendered as "-" per set.
                const display = try linescoreDisplay(arena, line.displayValue, line.value, line.tiebreak);
                try lines.append(arena, .{ .period = @intCast(index + 1), .display = display });
            }
            hits = try jsonText(arena, competitor.hits);
            errors = try jsonText(arena, competitor.errors);
            // Pre-game summaries often omit records; the board row already
            // carries the same ESPN record summary, so fall back to it
            // rather than rendering a record-less preview.
            record = summaryRecord(competitor.record) orelse participant.record;
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
    // Football payloads carry scoring plays here instead (every entry
    // scores; `period` is a bare quarter number). Appended after any
    // `plays`-derived rows; each source is chronological on its own.
    const scoring_list = response.scoringPlays orelse &[0]SummaryScoringPlay{};
    for (scoring_list) |play| {
        if (play.text.len == 0) continue;
        const away_score = (try jsonText(arena, play.awayScore)) orelse "";
        const home_score = (try jsonText(arena, play.homeScore)) orelse "";
        try scoring_plays.append(arena, .{
            .period = try scoringPlayPeriod(arena, play.period),
            .text = play.text,
            .away_score = away_score,
            .home_score = home_score,
        });
    }

    // Leaders: the top-level `leaders` blocks when ESPN ships them
    // (football-style: "Julian Sayin 21/25, 320 YDS, 3 TD"); otherwise the
    // boxscore fallback below (team totals plus top performers per side).
    // Either way the wire shape is unchanged: plain strings.
    var leaders: std.ArrayList([]const u8) = .empty;
    try topLeaders(arena, response.leaders, &leaders);
    if (leaders.items.len == 0) {
        if (response.boxscore) |boxscore| {
            try boxscoreLeaders(arena, boxscore, &leaders);
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
        // ESPN reports 0 for unknown attendance (soccer); a zero crowd
        // is "missing", never a "(0)" suffix downstream.
        attendance = switch (info.attendance) {
            .integer => |n| if (n > 0) n else null,
            .float => |f| if (f > 0) @intFromFloat(f) else null,
            else => null,
        };
    }

    var series: ?[]const u8 = null;
    if (try summarySeries(arena, response, game.id)) |from_summary| {
        series = from_summary;
    } else {
        series = try seriesFromSchedules(self, arena, endpoint, hit.day[0..4], competition, game.id);
    }

    // depth: starting lineups from the batting group (baseball).
    var lineups: std.ArrayList(core.detail.LineupSide) = .empty;
    if (response.boxscore) |boxscore| {
        try boxscoreLineups(arena, boxscore, &lineups);
    }

    // depth: box-score team totals ride the already-fetched summary payload.
    const team_stats = try boxTeamStats(arena, response.boxscore);

    // Injury report: one line per entry (team abbreviated, status, body
    // part when specified). Entries without a name or a status skip;
    // no report yields an empty list, never an error.
    var injuries: std.ArrayList([]const u8) = .empty;
    if (response.injuries) |teams| {
        for (teams) |entry| {
            const abbr: []const u8 = if (entry.team) |team| team.abbreviation else "?";
            const prefix: []const u8 = if (abbr.len > 0 and !std.mem.eql(u8, abbr, "?"))
                try std.fmt.allocPrint(arena, "{s} ", .{abbr})
            else
                "";
            for (entry.injuries) |injury| {
                const name = athleteName(injury.athlete) orelse continue;
                const status = (try jsonText(arena, injury.status)) orelse "";
                if (status.len == 0) continue;
                const suffix: []const u8 = if (injury.details) |details|
                    (if (details.type.len > 0) try std.fmt.allocPrint(arena, " ({s})", .{details.type}) else "")
                else
                    "";
                try injuries.append(arena, try std.fmt.allocPrint(arena, "{s}{s} {s}{s}", .{ prefix, name, status, suffix }));
            }
        }
    }

    // Win probability: the last sample's home share, labeled with the
    // home abbreviation (the feed's perspective). Empty or percentage-
    // less samples yield null, never a fabricated zero.
    var win_probability: ?[]const u8 = null;
    if (response.winprobability) |samples| {
        if (samples.len > 0) {
            if (samples[samples.len - 1].homeWinPercentage) |share| {
                var home_abbr: ?[]const u8 = null;
                for (competition.competitors) |competitor| {
                    if (!std.mem.eql(u8, competitor.homeAway, "home")) continue;
                    home_abbr = if (competitor.team) |team| team.abbreviation else null;
                    break;
                }
                if (home_abbr) |abbr| {
                    win_probability = try std.fmt.allocPrint(arena, "{s} {d:.1}%", .{ abbr, share * 100 });
                }
            }
        }
    }

    return .{
        .id = try copy(arena, game.id),
        .league = league.slug,
        .league_name = league.name,
        .date = try copy(arena, hit.day),
        .state = game.state,
        .status = game.status,
        .venue = venue,
        .attendance = attendance,
        .series = series,
        // Zero new fetches: the board row already parsed this game's
        // competition broadcasts above, so the detail copies it over.
        .network = game.network,
        .participants = try participants.toOwnedSlice(arena),
        .situation = situation,
        .decisions = try decisions.toOwnedSlice(arena),
        .scoring_plays = try scoring_plays.toOwnedSlice(arena),
        .leaders = try leaders.toOwnedSlice(arena),
        .lineups = try lineups.toOwnedSlice(arena),
        // depth: box-score team totals (optional; empty when not supplied).
        .team_stats = team_stats,
        .injuries = try injuries.toOwnedSlice(arena),
        .win_probability = win_probability,
    };
}

const DetailFake = struct {
    summary_body: []const u8,
    board_body: []const u8,
    /// Alternate board body served when the scoreboard URL carries
    /// `board_alt_dates` (compact YYYYMMDD): models the ET-day board
    /// differing from the UTC-day board for evening games.
    board_alt_body: []const u8 = "",
    board_alt_dates: []const u8 = "",
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
            if (self.board_alt_body.len > 0 and self.board_alt_dates.len > 0 and
                std.mem.indexOf(u8, url, self.board_alt_dates) != null)
            {
                return .{ .status = .ok, .body = try arena.dupe(u8, self.board_alt_body) };
            }
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
    try std.testing.expectEqualStrings("ATL leads season series 2-1 (game 3 of 4)", detail.series.?);
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
    try std.testing.expect(detail.network == null);
    try std.testing.expect(detail.leaders.len >= 4);
    try std.testing.expectEqualStrings("ATL H-AB 10-35", detail.leaders[0]);
    try std.testing.expectEqualStrings("Drake Baldwin 2-4", detail.leaders[1]);
}

test "fetchDetail copies the board network with no extra fetch" {
    const board =
        \\{"events":[{"id":"9","name":"Atlanta Braves at Philadelphia Phillies","date":"2026-09-06T17:10Z","competitions":[{"id":"9","date":"2026-09-06T17:10Z","status":{"type":{"state":"pre","shortDetail":"7:05 PM ET"}},"broadcasts":[{"names":["FS1"]}],"competitors":[{"homeAway":"away","team":{"id":"15","displayName":"Atlanta Braves","abbreviation":"ATL"}},{"homeAway":"home","team":{"id":"22","displayName":"Philadelphia Phillies","abbreviation":"PHI"}}]}]}]}
    ;
    const summary =
        \\{"header":{"competitions":[{"id":"9","date":"2026-09-06T17:10Z","status":{"type":{"state":"pre","shortDetail":"7:05 PM ET"}},"competitors":[{"id":"22","homeAway":"home","team":{"id":"22","displayName":"Philadelphia Phillies","abbreviation":"PHI"}},{"id":"15","homeAway":"away","team":{"id":"15","displayName":"Atlanta Braves","abbreviation":"ATL"}}]}]}}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "9");
    try std.testing.expectEqualStrings("FS1", detail.network.?);
    // One summary + one board fetch: the network rode the board payload.
    try std.testing.expectEqual(@as(usize, 1), fake.summary_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.board_calls);
}

const evening_summary_fixture =
    \\{"header":{"competitions":[{"id":"401872656","date":"2026-09-10T00:20Z","status":{"type":{"state":"pre","shortDetail":"9/9 - 8:20 PM EDT","description":"Scheduled"}},"competitors":[{"id":"25","homeAway":"home","winner":false,"score":0,"team":{"id":"25","displayName":"Seattle Seahawks","abbreviation":"SEA"}},{"id":"17","homeAway":"away","winner":false,"score":0,"team":{"id":"17","displayName":"New England Patriots","abbreviation":"NE"}}]}]}}
;

const evening_board_fixture =
    \\{"events":[{"id":"401872656","name":"New England Patriots at Seattle Seahawks","date":"2026-09-09T20:20Z","status":{"type":{"state":"pre","shortDetail":"9/9 - 8:20 PM EDT"}},"competitions":[{"competitors":[{"homeAway":"away","score":"0","winner":false,"team":{"id":"17","displayName":"New England Patriots","abbreviation":"NE"},"records":[{"type":"total","summary":"0-0"}]},{"homeAway":"home","score":"0","winner":false,"team":{"id":"25","displayName":"Seattle Seahawks","abbreviation":"SEA"},"records":[{"type":"total","summary":"0-0"}]}]}]}]}
;

test "fetchDetail finds evening games on the ET-day board" {
    // 8:20 PM ET Sep 9 lands on Sep 10 UTC: the UTC-day board misses while
    // the Eastern-day board (the one our links render from) holds the game.
    // The pre-game summary carries no records, so the board row supplies
    // them and the detail dates off the matched Eastern day.
    var fake = DetailFake{
        .summary_body = evening_summary_fixture,
        .board_body = "{\"events\":[]}",
        .board_alt_body = evening_board_fixture,
        .board_alt_dates = "20260909",
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("nfl").?, "401872656");
    try std.testing.expectEqual(@as(usize, 1), fake.summary_calls);
    try std.testing.expectEqual(@as(usize, 2), fake.board_calls);
    try std.testing.expectEqualStrings("401872656", detail.id);
    try std.testing.expectEqualStrings("nfl", detail.league);
    try std.testing.expectEqualStrings("2026-09-09", detail.date);
    try std.testing.expectEqualStrings("pre", detail.state);
    try std.testing.expectEqualStrings("9/9 - 8:20 PM EDT", detail.status);
    try std.testing.expectEqual(@as(usize, 2), detail.participants.len);
    try std.testing.expectEqualStrings("NE", detail.participants[0].abbreviation);
    try std.testing.expectEqualStrings("SEA", detail.participants[1].abbreviation);
    try std.testing.expectEqualStrings("0-0", detail.participants[1].record.?);
    try std.testing.expectEqual(@as(usize, 0), detail.scoring_plays.len);
    _ = try std.unicode.Utf8View.init(detail.status);
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
    try std.testing.expectEqualStrings("ATL leads season series 2-1 (game 3 of 4)", detail.series.?);
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
    // ESPN marks scheduled games with no summary yet `false` (verified
    // live: every 2026 NFL future game; every completed 2025 game `true`).
    // Absent on older/sparser payloads, which means available.
    boxscoreAvailable: ?bool = null,
    // ESPN flags kickoffs with no set time yet (`false` with a midnight
    // placeholder date; schema: "Whether the game time is valid").
    // Absent on older/sparser payloads, which means a real time.
    timeValid: ?bool = null,
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
    /// Ids whose kickoff ESPN marks unknown (`timeValid: false`): their
    /// dates are midnight placeholders, rendered as TBD downstream.
    unknown_time: []const []const u8,
};

fn resolveTeamId(body: []const u8, arena: std.mem.Allocator, abbrev: []const u8) !?[]const u8 {
    const response = try std.json.parseFromSliceLeaky(TeamListResponse, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    // Id-based resolution first (numeric route segments like /ncaaf/194),
    // abbrev fallback second (case-insensitive, first match wins). Both
    // scan the same list so one fetch serves either spelling.
    var abbrev_match: ?[]const u8 = null;
    for (response.sports) |sport| {
        for (sport.leagues) |league| {
            for (league.teams) |entry| {
                if (entry.team) |team| {
                    if (std.mem.eql(u8, team.id, abbrev)) return team.id;
                    if (abbrev_match == null and std.ascii.eqlIgnoreCase(team.abbreviation, abbrev)) abbrev_match = team.id;
                }
            }
        }
    }
    return abbrev_match;
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
    var unknown_time: std.ArrayList([]const u8) = .empty;
    for (response.events) |event| {
        if (event.competitions.len == 0) continue;
        // Event-level status is always null; the competition level is
        // authoritative (same rule as the scoreboard path).
        const competition = event.competitions[0];
        const event_id = if (competition.id.len > 0) competition.id else event.id;
        // Only an explicit `false` marks the time unknown: a missing flag
        // (older or sparser payloads) keeps the historical
        // format-the-timestamp behavior, so unannotated leagues never
        // lose their kickoff times.
        if (competition.timeValid) |valid| {
            if (!valid) try unknown_time.append(arena, event_id);
        }
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
            .id = event_id,
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
        .unknown_time = try unknown_time.toOwnedSlice(arena),
    };
}

/// Upcoming display: `"vs ATL 5:05 PM"` / `"at NYM 7:15 PM"` (US Eastern,
/// converted from the UTC ISO timestamp via `core.date`, EDT/EST by the rule
/// at the game instant). Kickoffs ESPN marks unknown (`timeValid: false`,
/// threaded in as `time_unknown`) render `"vs ILL TBD"`: the payload date
/// is a midnight placeholder, so formatting it would invent a 12:00 AM
/// kickoff (seen live: ncaaf/OSU 09-26 vs ILL). Falls back to the raw UTC
/// wall time when the timestamp shape is unknown, and to the calendar date
/// when no time parses.
fn upcomingResult(arena: std.mem.Allocator, event: core.schedule.ScheduleEvent, time_unknown: bool) ![]u8 {
    const versus = if (std.mem.eql(u8, event.home_away, "away")) "at" else "vs";
    if (time_unknown) {
        return std.fmt.allocPrint(arena, "{s} {s} TBD", .{ versus, event.opponent_abbrev });
    }
    if (event.date.len >= 16 and event.date[13] == ':') {
        var hour = std.fmt.parseInt(u8, event.date[11..13], 10) catch {
            return std.fmt.allocPrint(arena, "{s} {s} {s}", .{ versus, event.opponent_abbrev, event.date });
        };
        var minute: u8 = std.fmt.parseInt(u8, event.date[14..16], 10) catch {
            return std.fmt.allocPrint(arena, "{s} {s} {s}", .{ versus, event.opponent_abbrev, event.date });
        };
        // ESPN timestamps are UTC; team pages read Eastern. Shift the wall
        // clock by the offset in force at the game instant (September
        // kickoffs land in EDT, January tip-offs in EST).
        if (core.date.parseTimestampUTC(event.date)) |epoch| {
            const shifted = epoch + @as(i64, core.date.etOffsetMinutes(epoch)) * std.time.s_per_min;
            const wall = @mod(shifted, std.time.s_per_day);
            hour = @intCast(@divFloor(wall, std.time.s_per_hour));
            minute = @intCast(@divFloor(@mod(wall, std.time.s_per_hour), std.time.s_per_min));
        }
        const twelve = if (hour % 12 == 0) @as(u8, 12) else hour % 12;
        const suffix: []const u8 = if (hour < 12) "AM" else "PM";
        return std.fmt.allocPrint(arena, "{s} {s} {d}:{d:0>2} {s}", .{ versus, event.opponent_abbrev, twelve, minute, suffix });
    }
    const prefix = if (event.date.len >= 10) event.date[0..10] else event.date;
    return std.fmt.allocPrint(arena, "{s} {s} {s}", .{ versus, event.opponent_abbrev, prefix });
}

/// Final display: `"W 5-3"` / `"L 2-4"` (our score first), `"D 2-2"` for
/// numeric ties. A tie is a draw whatever the winner flag reads: ESPN marks
/// both sides `winner: false` on soccer draws, which used to render
/// `"L 0-0"`. Missing scores fall back to status.
fn finalResult(arena: std.mem.Allocator, event: core.schedule.ScheduleEvent) ![]u8 {
    if (event.our_score.len == 0 or event.opp_score.len == 0) {
        return arena.dupe(u8, event.status);
    }
    const ours = std.fmt.parseInt(i64, event.our_score, 10) catch null;
    const theirs = std.fmt.parseInt(i64, event.opp_score, 10) catch null;
    if (ours) |o| if (theirs) |t| {
        if (o == t) return std.fmt.allocPrint(arena, "D {s}-{s}", .{ event.our_score, event.opp_score });
        if (event.won) |won| return std.fmt.allocPrint(arena, "{s} {s}-{s}", .{ if (won) "W" else "L", event.our_score, event.opp_score });
        return std.fmt.allocPrint(arena, "{s} {s}-{s}", .{ if (o > t) "W" else "L", event.our_score, event.opp_score });
    };
    if (event.won) |won| return std.fmt.allocPrint(arena, "{s} {s}-{s}", .{ if (won) "W" else "L", event.our_score, event.opp_score });
    return std.fmt.allocPrint(arena, "F {s}-{s}", .{ event.our_score, event.opp_score });
}

/// Ids ESPN flagged with unknown kickoffs (`timeValid: false`, collected
/// at parse) still carry their schedule ids downstream, so the upcoming
/// formatter can tell placeholder midnights from real ones.
fn timeUnknown(ids: []const []const u8, id: []const u8) bool {
    for (ids) |known| if (std.mem.eql(u8, known, id)) return true;
    return false;
}

fn gameRefFromEvent(arena: std.mem.Allocator, event: core.schedule.ScheduleEvent, unknown_time: []const []const u8) !core.schedule.GameRef {
    const result = if (std.mem.eql(u8, event.state, "post"))
        try finalResult(arena, event)
    else if (std.mem.eql(u8, event.state, "in"))
        // Live rows render `"<date> <vs/at OPP> <result>"`, so the result
        // must not repeat the opponent the way upcoming results do.
        try liveScheduleResult(arena, event)
    else
        try upcomingResult(arena, event, timeUnknown(unknown_time, event.id));
    return .{
        // Game ids always link: detail renders board-backed previews for
        // games without a summary yet and 404s gracefully only for truly
        // unknown ids, so scheduled games stay navigable (Next 5 links).
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

/// Flag upcoming rows falling on today's Eastern calendar day (`pre`
/// only): renderers surface them in a top-center Today section instead
/// of only inside Next 5. A midnight-UTC timestamp still flags when its
/// Eastern day is today (evening games), and vice versa. Unparseable
/// dates simply stay unflagged.
fn markTodayGames(arena: std.mem.Allocator, games: []core.schedule.GameRef, today_et: []const u8) !void {
    for (games) |*game| {
        if (!std.mem.eql(u8, game.state, "pre")) continue;
        const epoch = core.date.parseTimestampUTC(game.date) orelse continue;
        const et_day = try core.date.todayInTz(arena, epoch, core.date.etOffsetMinutes(epoch));
        defer arena.free(et_day);
        game.today = std.mem.eql(u8, et_day, today_et);
    }
}

/// Live display from schedule scores alone: `"{our}-{opp} {status}"` (the
/// board shape, no opponent); bare status when no scores are posted yet.
fn liveScheduleResult(arena: std.mem.Allocator, event: core.schedule.ScheduleEvent) ![]u8 {
    if (event.our_score.len > 0 and event.opp_score.len > 0) {
        return std.fmt.allocPrint(arena, "{s}-{s} {s}", .{ event.our_score, event.opp_score, event.status });
    }
    return arena.dupe(u8, event.status);
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

    // The default teams endpoint pages at 50 entries (verified live:
    // NCAAF's list omits Ohio State), so college lookups 404. A large
    // limit returns the whole membership (761 for NCAAF) in one fetch;
    // pro leagues are unaffected beyond a bigger (cached) body.
    const teams_url = try std.fmt.allocPrint(arena, "{s}?limit=1000", .{try espn.buildTeamsUrl(arena, self.base_url, endpoint.sport, endpoint.league)});
    const teams_body = try fetchUrl(self, arena, teams_url);
    const team_id = (try resolveTeamId(teams_body, arena, abbrev)) orelse return error.TeamNotFound;

    var parsed = try parseSchedule(arena, try fetchUrl(
        self,
        arena,
        try espn.buildScheduleUrl(arena, self.base_url, endpoint.sport, endpoint.league, team_id, season),
    ), abbrev);
    if (parsed.events.len == 0) {
        const year = try std.fmt.parseInt(u16, season, 10);
        const previous = try std.fmt.allocPrint(arena, "{d}", .{year - 1});
        parsed = try parseSchedule(arena, try fetchUrl(
            self,
            arena,
            try espn.buildScheduleUrl(arena, self.base_url, endpoint.sport, endpoint.league, team_id, previous),
        ), abbrev);
    }

    const split = try core.schedule.splitSchedule(arena, parsed.events, today);
    var next: std.ArrayList(core.schedule.GameRef) = .empty;
    for (split.upcoming[0..@min(split.upcoming.len, 5)]) |event| {
        try next.append(arena, try gameRefFromEvent(arena, event, parsed.unknown_time));
    }
    var last: std.ArrayList(core.schedule.GameRef) = .empty;
    var i: usize = split.past.len;
    while (i > 0 and last.items.len < 5) {
        i -= 1;
        try last.append(arena, try gameRefFromEvent(arena, split.past[i], parsed.unknown_time));
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
            try extra_past.append(arena, try gameRefFromEvent(arena, split.past[j], parsed.unknown_time));
        }
    }
    var extra_next: std.ArrayList(core.schedule.GameRef) = .empty;
    if (split.upcoming.len > next.items.len) {
        for (split.upcoming[next.items.len..]) |event| {
            try extra_next.append(arena, try gameRefFromEvent(arena, event, parsed.unknown_time));
        }
    }
    // Flag today's upcoming rows top-center: Eastern calendar day derived
    // from each event's timestamp (evening UTC stamps land on the played
    // day), `pre` only so finals stay in Last and live rows under LIVE
    // NOW. Renderers surface flagged rows in a Today section and skip
    // them in Next/Later below; arrays keep schedule order regardless.
    const today_et = try core.date.todayET(arena, self.clock(self.io));
    try markTodayGames(arena, next.items, today_et);
    try markTodayGames(arena, extra_next.items, today_et);

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
    teams_url: ?[]const u8 = null,

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
        self.teams_url = try arena.dupe(u8, url);
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

// ---- League standings (additive; existing fns above are untouched) ----
//
// ESPN serves current standings at `{base}/sports/{sport}/{league}/standings`
// (same path convention as `buildScoreboardUrl`, hand-built here because the
// generated client only exposes the soccer operation — `getSoccerStandings`
// — so the portable `HttpTransport` seam carries every sport instead).
//
// Supported sports: football, basketball, baseball, hockey, soccer (resolved
// through the same `endpointFor` sport/league keys as the scoreboard, so a
// league without a mapping — or a mapped sport ESPN has no table for, such
// ---- League team list (additive; existing fns above are untouched) ----

/// Team picker payload behind `GET /api/v1/{league}/teams`: one ESPN
/// teams fetch (same `?limit=1000` shape as the team view, so college
/// memberships arrive whole), mapped to id/abbrev/name rows in provider
/// order. No record: the teams payload carries none, and per-team records
/// would cost one schedule fetch per team instead of this single call.
/// Empty membership yields an empty list, never an error.
pub fn fetchTeams(adapter: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League) !core.schedule.TeamList {
    const endpoint = endpointFor(league.slug) orelse return error.UnsupportedLeague;
    const url = try std.fmt.allocPrint(arena, "{s}?limit=1000", .{try espn.buildTeamsUrl(arena, adapter.base_url, endpoint.sport, endpoint.league)});
    return parseTeamList(arena, league, try fetchUrl(adapter, arena, url));
}

pub fn parseTeamList(arena: std.mem.Allocator, league: *const core.leagues.League, body: []const u8) !core.schedule.TeamList {
    const response = try std.json.parseFromSliceLeaky(TeamListResponse, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    var teams: std.ArrayList(core.schedule.TeamListEntry) = .empty;
    for (response.sports) |sport| {
        for (sport.leagues) |entrant| {
            for (entrant.teams) |entry| {
                const team = entry.team orelse continue;
                if (team.id.len == 0) continue;
                try teams.append(arena, .{
                    .id = team.id,
                    .abbrev = team.abbreviation,
                    .name = if (team.displayName.len > 0) team.displayName else "Unknown",
                });
            }
        }
    }
    return .{
        .league = league.slug,
        .league_name = league.name,
        .teams = try teams.toOwnedSlice(arena),
        .source = "site.api.espn.com",
    };
}

test "parseTeamList maps every team in provider order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const list = try parseTeamList(arena_state.allocator(), core.leagues.find("mlb").?, team_fixture_teams);
    try std.testing.expectEqualStrings("mlb", list.league);
    try std.testing.expectEqualStrings("MLB", list.league_name);
    try std.testing.expectEqualStrings("1", list.schema_version);
    try std.testing.expectEqualStrings("site.api.espn.com", list.source);
    try std.testing.expectEqual(@as(usize, 2), list.teams.len);
    try std.testing.expectEqualStrings("22", list.teams[0].id);
    try std.testing.expectEqualStrings("PHI", list.teams[0].abbrev);
    try std.testing.expectEqualStrings("Philadelphia Phillies", list.teams[0].name);
    try std.testing.expectEqualStrings("ATL", list.teams[1].abbrev);
}

test "parseTeamList tolerates empty and teamless payloads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mlb = core.leagues.find("mlb").?;
    const empty = try parseTeamList(arena, mlb, "{\"sports\":[]}");
    try std.testing.expectEqual(@as(usize, 0), empty.teams.len);
    try std.testing.expectEqualStrings("mlb", empty.league);
    const teamless = try parseTeamList(arena, mlb, "{\"sports\":[{\"leagues\":[{\"teams\":[{},{\"team\":{\"id\":\"\"}}]}]}]}");
    try std.testing.expectEqual(@as(usize, 0), teamless.teams.len);
}

test "fetchTeams hits the teams endpoint with the college-sized limit" {
    var fake = TeamFixtureState{
        .teams_body = team_fixture_teams,
        .schedule_body = team_fixture_schedule,
        .board_body = team_fixture_board,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const list = try fetchTeams(teamTestAdapter(&fake), arena_state.allocator(), core.leagues.find("mlb").?);
    try std.testing.expectEqual(@as(usize, 2), list.teams.len);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/baseball/mlb/teams?limit=1000",
        fake.teams_url.?,
    );
}

// as tennis, racing, MMA, golf — fails with `error.UnsupportedLeague`
// without ever contacting upstream). The serve layer maps that to 404
// ("standings unavailable for league"); a non-200 upstream is
// `error.UpstreamResponse` (serve layer 502), mirroring the scoreboard.
//
// Response shape: every sport serves `children[]`; US team sports nest one
// level (conference -> division) while soccer serves one flat level, so the
// parser walks `children` recursively and collects every node carrying a
// `standings.entries[]` block under that node's name. Entry stats are
// name-looked-up (`wins`/`losses`/`ties`+`draws`/`points`+`pts`), preferring
// `displayValue` with the numeric `value` as fallback, kept as display
// text per `core.standings` (a missing stat is null, never zero).
// `season` is the adapter-clock year: the endpoint is current-season only.

/// Pure URL builder for the standings endpoint, mirroring
/// `espn.buildScoreboardUrl`'s `{base}/sports/{sport}/{league}/...` shape.
pub fn buildStandingsUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    sport: []const u8,
    league: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sports/{s}/{s}/standings", .{ base_url, sport, league });
}

fn standingsSupported(sport: []const u8) bool {
    return std.mem.eql(u8, sport, "football") or
        std.mem.eql(u8, sport, "basketball") or
        std.mem.eql(u8, sport, "baseball") or
        std.mem.eql(u8, sport, "hockey") or
        std.mem.eql(u8, sport, "soccer");
}

pub fn fetchStandings(adapter: EspnAdapter, arena: std.mem.Allocator, league: *const core.leagues.League) !core.standings.LeagueStandings {
    const endpoint = endpointFor(league.slug) orelse return error.UnsupportedLeague;
    if (!standingsSupported(endpoint.sport)) return error.UnsupportedLeague;
    const url = try buildStandingsUrl(arena, adapter.base_url, endpoint.sport, endpoint.league);
    const body = try fetchUrl(adapter, arena, url);
    const today = try adapter.today(arena);
    return parseStandings(arena, league, today[0..4], body);
}

const StandingsResponse = struct {
    children: []const StandingsNode = &.{},
};

const StandingsNode = struct {
    name: []const u8 = "",
    displayName: []const u8 = "",
    abbreviation: []const u8 = "",
    standings: ?StandingsBlock = null,
    children: []const StandingsNode = &.{},
};

const StandingsBlock = struct {
    entries: []const StandingsRawEntry = &.{},
};

const StandingsRawEntry = struct {
    team: ?StandingsRawTeam = null,
    stats: []const StandingsRawStat = &.{},
};

const StandingsRawTeam = struct {
    id: []const u8 = "",
    abbreviation: []const u8 = "?",
    displayName: []const u8 = "Unknown",
};

const StandingsRawStat = struct {
    name: []const u8 = "",
    value: std.json.Value = .null,
    displayValue: ?[]const u8 = null,
};

fn standingsStatText(arena: std.mem.Allocator, stats: []const StandingsRawStat, names: []const []const u8) !?[]const u8 {
    for (stats) |stat| {
        for (names) |wanted| {
            if (!std.mem.eql(u8, stat.name, wanted)) continue;
            if (stat.displayValue) |display| {
                if (display.len > 0) return display;
            }
            if (try jsonText(arena, stat.value)) |rendered| {
                if (rendered.len > 0) return rendered;
            }
            return null;
        }
    }
    return null;
}

fn groupDisplayName(node: StandingsNode) []const u8 {
    if (node.name.len > 0) return node.name;
    if (node.displayName.len > 0) return node.displayName;
    return node.abbreviation;
}

fn collectStandingsGroups(
    arena: std.mem.Allocator,
    nodes: []const StandingsNode,
    out: *std.ArrayList(core.standings.StandingGroup),
) !void {
    for (nodes) |node| {
        if (node.standings) |block| {
            var entries: std.ArrayList(core.standings.StandingEntry) = .empty;
            for (block.entries) |raw| {
                const team = raw.team orelse continue;
                try entries.append(arena, .{
                    .team_id = team.id,
                    .abbrev = team.abbreviation,
                    .name = if (team.displayName.len > 0) team.displayName else "Unknown",
                    .wins = try standingsStatText(arena, raw.stats, &.{"wins"}),
                    .losses = try standingsStatText(arena, raw.stats, &.{"losses"}),
                    .ties = try standingsStatText(arena, raw.stats, &.{ "ties", "draws" }),
                    .points = try standingsStatText(arena, raw.stats, &.{ "points", "pts" }),
                });
            }
            try out.append(arena, .{
                .name = groupDisplayName(node),
                .entries = try entries.toOwnedSlice(arena),
            });
        }
        try collectStandingsGroups(arena, node.children, out);
    }
}

pub fn parseStandings(
    arena: std.mem.Allocator,
    league: *const core.leagues.League,
    season: []const u8,
    body: []const u8,
) !core.standings.LeagueStandings {
    const response = try std.json.parseFromSliceLeaky(StandingsResponse, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    var groups: std.ArrayList(core.standings.StandingGroup) = .empty;
    try collectStandingsGroups(arena, response.children, &groups);
    return .{
        .league = league.slug,
        .league_name = league.name,
        .season = try copy(arena, season),
        .groups = try groups.toOwnedSlice(arena),
        .source = "site.api.espn.com",
    };
}

const StandingsFake = struct {
    seen_url: ?[]const u8 = null,
    body: []const u8,
    status: std.http.Status = .ok,

    fn dispatch(ptr: *anyopaque, arena: std.mem.Allocator, url: []const u8, extra_headers: []const std.http.Header) anyerror!espn.FetchResult {
        _ = extra_headers;
        const self: *StandingsFake = @ptrCast(@alignCast(ptr));
        self.seen_url = try arena.dupe(u8, url);
        return .{ .status = self.status, .body = try arena.dupe(u8, self.body) };
    }

    fn asTransport(self: *StandingsFake) espn.HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

fn standingsTestAdapter(fake: *StandingsFake) EspnAdapter {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return .{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
        .base_url = "https://example.test/base",
        .transport = fake.asTransport(),
        .clock = fakeClock,
    };
}

test "standings URLs follow the scoreboard path convention per sport" {
    const cases = [_]struct { slug: []const u8, want: []const u8 }{
        .{ .slug = "nfl", .want = "https://example.test/base/sports/football/nfl/standings" },
        .{ .slug = "nba", .want = "https://example.test/base/sports/basketball/nba/standings" },
        .{ .slug = "mlb", .want = "https://example.test/base/sports/baseball/mlb/standings" },
        .{ .slug = "nhl", .want = "https://example.test/base/sports/hockey/nhl/standings" },
        .{ .slug = "epl", .want = "https://example.test/base/sports/soccer/eng.1/standings" },
        .{ .slug = "mls", .want = "https://example.test/base/sports/soccer/usa.1/standings" },
    };
    for (cases) |c| {
        var fake = StandingsFake{ .body = "{\"children\":[]}" };
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const standings = try fetchStandings(standingsTestAdapter(&fake), arena_state.allocator(), core.leagues.find(c.slug).?);
        try std.testing.expectEqualStrings(c.want, fake.seen_url.?);
        try std.testing.expectEqualStrings(c.slug, standings.league);
        try std.testing.expectEqualStrings("2026", standings.season);
    }
}

test "fetchStandings rejects sports without an ESPN table" {
    for ([_][]const u8{ "atp", "wta", "f1", "ufc", "pga" }) |slug| {
        var fake = StandingsFake{ .body = "{\"children\":[]}" };
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        try std.testing.expectError(
            error.UnsupportedLeague,
            fetchStandings(standingsTestAdapter(&fake), arena_state.allocator(), core.leagues.find(slug).?),
        );
        // Rejected before any upstream contact.
        try std.testing.expect(fake.seen_url == null);
    }
}

test "fetchStandings maps a non-200 upstream to UpstreamResponse" {
    var fake = StandingsFake{ .body = "{}", .status = .bad_gateway };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.UpstreamResponse,
        fetchStandings(standingsTestAdapter(&fake), arena_state.allocator(), core.leagues.find("mlb").?),
    );
}

const standings_nfl_fixture =
    \\{"children":[
    \\{"name":"AFC","abbreviation":"AFC","children":[
    \\{"name":"AFC East","abbreviation":"AFCE","standings":{"entries":[
    \\{"team":{"id":"2","abbreviation":"BUF","displayName":"Buffalo Bills"},"stats":[{"name":"wins","value":11,"displayValue":"11"},{"name":"losses","value":3,"displayValue":"3"},{"name":"ties","value":1,"displayValue":"1"}]},
    \\{"team":{"id":"15","abbreviation":"MIA","displayName":"Miami Dolphins"},"stats":[{"name":"wins","value":7,"displayValue":"7"},{"name":"losses","value":7,"displayValue":"7"},{"name":"ties","value":0,"displayValue":"0"}]}
    \\]}},
    \\{"name":"AFC West","abbreviation":"AFCW","standings":{"entries":[
    \\{"team":{"id":"12","abbreviation":"KC","displayName":"Kansas City Chiefs"},"stats":[{"name":"wins","value":12,"displayValue":"12"},{"name":"losses","value":2,"displayValue":"2"}]}
    \\]}}
    \\]},
    \\{"name":"NFC","abbreviation":"NFC","children":[
    \\{"name":"NFC North","abbreviation":"NFCN","standings":{"entries":[
    \\{"team":{"id":"22","abbreviation":"DET","displayName":"Detroit Lions"},"stats":[{"name":"wins","value":10,"displayValue":"10"},{"name":"losses","value":4,"displayValue":"4"}]}
    \\]}}
    \\]}
    \\]}
;

test "standings parse the nested football shape with ties" {
    var fake = StandingsFake{ .body = standings_nfl_fixture };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const standings = try fetchStandings(standingsTestAdapter(&fake), arena_state.allocator(), core.leagues.find("nfl").?);
    try std.testing.expectEqual(@as(usize, 3), standings.groups.len);
    try std.testing.expectEqualStrings("AFC East", standings.groups[0].name);
    try std.testing.expectEqual(@as(usize, 2), standings.groups[0].entries.len);
    const buf = standings.groups[0].entries[0];
    try std.testing.expectEqualStrings("BUF", buf.abbrev);
    try std.testing.expectEqualStrings("Buffalo Bills", buf.name);
    try std.testing.expectEqualStrings("11", buf.wins.?);
    try std.testing.expectEqualStrings("3", buf.losses.?);
    try std.testing.expectEqualStrings("1", buf.ties.?);
    // Football carries no points column.
    try std.testing.expect(buf.points == null);
    // Conference nodes without a block contribute no group of their own.
    try std.testing.expectEqualStrings("AFC West", standings.groups[1].name);
    try std.testing.expectEqualStrings("NFC North", standings.groups[2].name);
}

const standings_nba_fixture =
    \\{"children":[
    \\{"name":"Eastern Conference","displayName":"Eastern Conference","children":[
    \\{"name":"Atlantic","standings":{"entries":[
    \\{"team":{"id":"2","abbreviation":"BOS","displayName":"Boston Celtics"},"stats":[{"name":"wins","value":45,"displayValue":"45"},{"name":"losses","value":12,"displayValue":"12"}]}
    \\]}}
    \\]},
    \\{"name":"Western Conference","children":[
    \\{"name":"Pacific","standings":{"entries":[
    \\{"team":{"id":"14","abbreviation":"LAL","displayName":"Los Angeles Lakers"},"stats":[{"name":"wins","value":33,"displayValue":"33"},{"name":"losses","value":24,"displayValue":"24"}]}
    \\]}}
    \\]}
    \\]}
;

test "standings parse the nested basketball shape" {
    var fake = StandingsFake{ .body = standings_nba_fixture };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const standings = try fetchStandings(standingsTestAdapter(&fake), arena_state.allocator(), core.leagues.find("nba").?);
    try std.testing.expectEqual(@as(usize, 2), standings.groups.len);
    try std.testing.expectEqualStrings("Atlantic", standings.groups[0].name);
    try std.testing.expectEqualStrings("BOS", standings.groups[0].entries[0].abbrev);
    try std.testing.expectEqualStrings("45", standings.groups[0].entries[0].wins.?);
    try std.testing.expect(standings.groups[0].entries[0].ties == null);
    try std.testing.expectEqualStrings("Pacific", standings.groups[1].name);
}

const standings_mlb_fixture =
    \\{"children":[
    \\{"name":"American League","children":[
    \\{"name":"AL East","standings":{"entries":[
    \\{"team":{"id":"19","abbreviation":"NYY","displayName":"New York Yankees"},"stats":[{"name":"wins","value":80},{"name":"losses","value":63}]},
    \\{"team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"stats":[{"name":"wins","value":80,"displayValue":"80"},{"name":"losses","value":63,"displayValue":"63"}]}
    \\]}}
    \\]}
    \\]}
;

test "standings fall back to numeric values without displayValue" {
    var fake = StandingsFake{ .body = standings_mlb_fixture };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const standings = try fetchStandings(standingsTestAdapter(&fake), arena_state.allocator(), core.leagues.find("mlb").?);
    try std.testing.expectEqual(@as(usize, 1), standings.groups.len);
    try std.testing.expectEqualStrings("AL East", standings.groups[0].name);
    // Bare numerics still render as text.
    try std.testing.expectEqualStrings("80", standings.groups[0].entries[0].wins.?);
    try std.testing.expectEqualStrings("63", standings.groups[0].entries[0].losses.?);
    try std.testing.expectEqualStrings("PHI", standings.groups[0].entries[1].abbrev);
}

const standings_nhl_fixture =
    \\{"children":[
    \\{"name":"Eastern Conference","children":[
    \\{"name":"Atlantic Division","standings":{"entries":[
    \\{"team":{"id":"6","abbreviation":"BOS","displayName":"Boston Bruins"},"stats":[{"name":"wins","value":38,"displayValue":"38"},{"name":"losses","value":14,"displayValue":"14"},{"name":"ties","value":9,"displayValue":"9"},{"name":"points","value":85,"displayValue":"85"}]}
    \\]}}
    \\]}
    \\]}
;

test "standings parse the hockey shape with points" {
    var fake = StandingsFake{ .body = standings_nhl_fixture };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const standings = try fetchStandings(standingsTestAdapter(&fake), arena_state.allocator(), core.leagues.find("nhl").?);
    try std.testing.expectEqual(@as(usize, 1), standings.groups.len);
    try std.testing.expectEqualStrings("Atlantic Division", standings.groups[0].name);
    const bos = standings.groups[0].entries[0];
    try std.testing.expectEqualStrings("85", bos.points.?);
    try std.testing.expectEqualStrings("38", bos.wins.?);
}

const standings_soccer_fixture =
    \\{"id":"eng.1","name":"English Premier League","abbreviation":"EPL","children":[
    \\{"id":"eng.1","name":"English Premier League","abbreviation":"EPL","standings":{"entries":[
    \\{"team":{"id":"360","abbreviation":"ARS","displayName":"Arsenal"},"stats":[{"name":"wins","value":18,"displayValue":"18"},{"name":"losses","value":3,"displayValue":"3"},{"name":"draws","value":5,"displayValue":"5"},{"name":"points","value":59,"displayValue":"59"}]},
    \\{"team":{"id":"359","abbreviation":"MCI","displayName":"Manchester City"},"stats":[{"name":"wins","value":17,"displayValue":"17"},{"name":"losses","value":4,"displayValue":"4"},{"name":"draws","value":5,"displayValue":"5"},{"name":"points","value":56,"displayValue":"56"}]}
    \\]}}
    \\]}
;

test "standings parse the flat soccer shape with draws and points" {
    var fake = StandingsFake{ .body = standings_soccer_fixture };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const standings = try fetchStandings(standingsTestAdapter(&fake), arena_state.allocator(), core.leagues.find("epl").?);
    try std.testing.expectEqual(@as(usize, 1), standings.groups.len);
    try std.testing.expectEqualStrings("English Premier League", standings.groups[0].name);
    const ars = standings.groups[0].entries[0];
    try std.testing.expectEqualStrings("ARS", ars.abbrev);
    try std.testing.expectEqualStrings("5", ars.ties.?);
    try std.testing.expectEqualStrings("59", ars.points.?);
}
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

fn schedEvent(state: []const u8, our_score: []const u8, opp_score: []const u8, won: ?bool) core.schedule.ScheduleEvent {
    return .{
        .id = "t",
        .date = "2026-09-05T19:05Z",
        .opponent_abbrev = "ATL",
        .opponent_name = "Atlanta Braves",
        .home_away = "home",
        .state = state,
        .status = "Final",
        .our_score = our_score,
        .opp_score = opp_score,
        .won = won,
    };
}

test "finals derive draws from tied scores whatever the winner flag reads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // ESPN marks both sides winner=false on soccer draws: "L 0-0" before.
    try std.testing.expectEqualStrings("D 2-2", try finalResult(arena, schedEvent("post", "2", "2", false)));
    try std.testing.expectEqualStrings("D 0-0", try finalResult(arena, schedEvent("post", "0", "0", false)));
    // Null-flag draws already worked; winner flags still decide non-ties.
    try std.testing.expectEqualStrings("D 1-1", try finalResult(arena, schedEvent("post", "1", "1", null)));
    try std.testing.expectEqualStrings("W 2-1", try finalResult(arena, schedEvent("post", "2", "1", true)));
    try std.testing.expectEqualStrings("W 3-1", try finalResult(arena, schedEvent("post", "3", "1", null)));
    try std.testing.expectEqualStrings("L 1-3", try finalResult(arena, schedEvent("post", "1", "3", false)));
    try std.testing.expectEqualStrings("L 1-3", try finalResult(arena, schedEvent("post", "1", "3", null)));
    // Missing scores fall back to status.
    try std.testing.expectEqualStrings("Final", try finalResult(arena, schedEvent("post", "", "", null)));
}

test "upcoming times read Eastern, not UTC" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = core.schedule.ScheduleEvent{
        .id = "t",
        .date = "",
        .opponent_abbrev = "DAL",
        .opponent_name = "Dallas",
        .home_away = "home",
        .state = "pre",
        .status = "Scheduled",
    };
    // The reported NFL kickoff: Sept 13 8:20 PM ET is 09-14T00:20Z.
    var sept = base;
    sept.date = "2026-09-14T00:20Z";
    try std.testing.expectEqualStrings("vs DAL 8:20 PM", try upcomingResult(arena, sept, false));
    // Away sides and the EDT offset likewise shift back four hours.
    var away = base;
    away.home_away = "away";
    away.opponent_abbrev = "PHI";
    away.date = "2026-09-08T22:40Z";
    try std.testing.expectEqualStrings("at PHI 6:40 PM", try upcomingResult(arena, away, false));
    // January reads EST: 02:30Z is 9:30 PM the evening before.
    var jan = base;
    jan.date = "2026-01-15T02:30Z";
    try std.testing.expectEqualStrings("vs DAL 9:30 PM", try upcomingResult(arena, jan, false));
    // Unparsable timestamps keep the old fallbacks, never an error.
    var bad = base;
    bad.date = "sometime";
    try std.testing.expectEqualStrings("vs DAL sometime", try upcomingResult(arena, bad, false));
}

test "live schedule rows carry no opponent repeat in the result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var live = schedEvent("in", "2", "3", null);
    live.status = "Top 9th";
    const with_scores = try gameRefFromEvent(arena, live, &.{});
    try std.testing.expectEqualStrings("2-3 Top 9th", with_scores.result);
    var unscored = schedEvent("in", "", "", null);
    unscored.status = "Top 9th";
    const bare = try gameRefFromEvent(arena, unscored, &.{});
    try std.testing.expectEqualStrings("Top 9th", bare.result);
}

// Partition regression (FakeTransportState, never live ESPN): a postponed
// game with a past date, a draw flagged winner=false on both sides, and a
// cross-midnight live game interleave one final. Only the final is past;
// everything else stays upcoming in schedule order.
const team_partition_schedule =
    \\{"team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies","recordSummary":"80-63","standingSummary":"2nd in NL East"},"events":[
    \\{"id":"ppd1","date":"2026-09-04T19:05Z","competitions":[{"id":"ppd1","date":"2026-09-04T19:05Z","status":{"type":{"state":"pre","shortDetail":"Postponed"}},"competitors":[{"homeAway":"home","team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"probables":[]},{"homeAway":"away","team":{"id":"12","abbreviation":"ATL","displayName":"Atlanta Braves"},"probables":[]}]}]},
    \\{"id":"draw1","date":"2026-09-05T19:05Z","competitions":[{"id":"draw1","date":"2026-09-05T19:05Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"homeAway":"home","winner":false,"score":{"displayValue":"2"},"team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"probables":[]},{"homeAway":"away","winner":false,"score":{"displayValue":"2"},"team":{"id":"12","abbreviation":"ATL","displayName":"Atlanta Braves"},"probables":[]}]}]},
    \\{"id":"live9","date":"2026-09-06T22:40Z","competitions":[{"id":"live9","date":"2026-09-06T22:40Z","status":{"type":{"state":"in","shortDetail":"Top 9th"}},"competitors":[{"homeAway":"home","score":{"displayValue":"2"},"team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"probables":[]},{"homeAway":"away","score":{"displayValue":"3"},"team":{"id":"12","abbreviation":"ATL","displayName":"Atlanta Braves"},"probables":[]}]}]},
    \\{"id":"fut1","date":"2026-09-08T17:05Z","competitions":[{"id":"fut1","date":"2026-09-08T17:05Z","status":{"type":{"state":"pre","shortDetail":"Scheduled"}},"competitors":[{"homeAway":"home","team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"probables":[]},{"homeAway":"away","team":{"id":"12","abbreviation":"ATL","displayName":"Atlanta Braves"},"probables":[]}]}]}
    \\]}
;

test "fetchTeam partitions by completion across interleaved dates" {
    var fake = TeamFixtureState{
        .teams_body = team_fixture_teams,
        .schedule_body = team_partition_schedule,
        .board_body = team_fixture_board,
        .fail_board = true, // live join off; partitioning is schedule-only.
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // fakeClock today is 2026-09-07: the 09-06 live game is cross-midnight.
    const view = try fetchTeam(teamTestAdapter(&fake), arena_state.allocator(), core.leagues.find("mlb").?, "PHI");
    try std.testing.expect(view.live == null);
    try std.testing.expectEqual(@as(usize, 1), view.last.len);
    try std.testing.expectEqualStrings("draw1", view.last[0].id);
    try std.testing.expectEqualStrings("D 2-2", view.last[0].result);
    try std.testing.expectEqual(@as(usize, 3), view.next.len);
    try std.testing.expectEqualStrings("ppd1", view.next[0].id);
    try std.testing.expectEqualStrings("live9", view.next[1].id);
    try std.testing.expectEqualStrings("2-3 Top 9th", view.next[1].result);
    try std.testing.expectEqualStrings("fut1", view.next[2].id);
    try std.testing.expectEqualStrings("vs ATL 1:05 PM", view.next[2].result);
    try std.testing.expectEqual(@as(usize, 0), view.extra_past.len);
    try std.testing.expectEqual(@as(usize, 0), view.extra_next.len);
}

// ---- Data-quality lane (appended; existing tests above untouched) ----
//
// 1. College teams paginate: the default teams endpoint serves 50 entries
//    (NCAAF omits Ohio State), so abbrev lookup 404'd. The provider now
//    requests `?limit=1000` (761 for NCAAF, verified live) and resolves
//    numeric segments by team id with abbrev fallback.
// 2. Scheduled games with no summary yet (ESPN `boxscoreAvailable: false`,
//    verified live: all 2026 NFL futures false, all completed 2025 true)
//    map to id-less `GameRef`s — plain text in every team view, stable JSON.
// 3. `boxTeamStats` filters exact generic counters and maps the flat
//    football shape (`label`/`displayValue` per entry).
// 4. Season-series wording stays modest; trivial (<=1 game) series omit.
// 5. NBA schedule payloads carry no record/standing anywhere (verified live
//    2026-09-09: header and competitors alike) — ESPN-thin, pinned here.
// 6. Football summaries ship `scoringPlays` (not `plays`) and top-level
//    `leaders`; boxscore groups key columns by stat id (`keys`, no `names`).

const ncaaf_teams_two_osu =
    \\{"sports":[{"leagues":[{"teams":[{"team":{"id":"194","abbreviation":"OSU","displayName":"Ohio State Buckeyes"}},{"team":{"id":"3161","abbreviation":"OSU","displayName":"Ohio State Newark Titans"}}]}]}]}
;

const ncaaf_osu_schedule =
    \\{"team":{"id":"194","abbreviation":"OSU","displayName":"Ohio State Buckeyes","recordSummary":"1-0"},"events":[
    \\{"id":"401858432","date":"2026-09-05T16:30Z","competitions":[{"id":"401858432","date":"2026-09-05T16:30Z","status":{"type":{"state":"post","shortDetail":"Final"}},"boxscoreAvailable":true,"competitors":[{"homeAway":"home","winner":true,"score":{"displayValue":"48"},"team":{"id":"194","abbreviation":"OSU","displayName":"Ohio State Buckeyes"},"probables":[]},{"homeAway":"away","winner":false,"score":{"displayValue":"10"},"team":{"id":"2050","abbreviation":"BALL","displayName":"Ball State Cardinals"},"probables":[]}]}]},
    \\{"id":"401858500","date":"2026-09-12T19:30Z","competitions":[{"id":"401858500","date":"2026-09-12T19:30Z","status":{"type":{"state":"pre","shortDetail":"Scheduled"}},"boxscoreAvailable":false,"competitors":[{"homeAway":"away","team":{"id":"194","abbreviation":"OSU","displayName":"Ohio State Buckeyes"},"probables":[]},{"homeAway":"home","team":{"id":"999","abbreviation":"XYZ","displayName":"X Y Zed"},"probables":[]}]}]}
    \\]}
;

test "fetchTeam resolves college abbrevs past the 50-team page" {
    var fake = TeamFixtureState{
        .teams_body = ncaaf_teams_two_osu,
        .schedule_body = ncaaf_osu_schedule,
        .board_body = team_fixture_board,
        .fail_board = true, // schedule-only; live join off.
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const view = try fetchTeam(teamTestAdapter(&fake), arena_state.allocator(), core.leagues.find("ncaaf").?, "OSU");
    // Full membership in one fetch, first abbrev match wins.
    try std.testing.expect(std.mem.indexOf(u8, fake.teams_url.?, "limit=1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.first_schedule_url.?, "/teams/194/") != null);
    try std.testing.expectEqualStrings("Ohio State Buckeyes", view.team.name);
    try std.testing.expectEqualStrings("1-0", view.team.record_summary.?);
    try std.testing.expectEqualStrings("W 48-10", view.last[0].result);
}

test "fetchTeam resolves numeric ids with abbrev fallback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Numeric segment matches by id even when the abbrev differs.
    try std.testing.expectEqualStrings("194", (try resolveTeamId(ncaaf_teams_two_osu, arena, "194")).?);
    // Abbrev still matches (first of the duplicate OSU entries).
    try std.testing.expectEqualStrings("194", (try resolveTeamId(ncaaf_teams_two_osu, arena, "osu")).?);
    // Unknown either way stays a 404, never a schedule fetch.
    try std.testing.expect(try resolveTeamId(ncaaf_teams_two_osu, arena, "9999") == null);
    var fake = TeamFixtureState{
        .teams_body = ncaaf_teams_two_osu,
        .schedule_body = ncaaf_osu_schedule,
        .board_body = team_fixture_board,
        .fail_board = true,
    };
    const by_id = try fetchTeam(teamTestAdapter(&fake), arena, core.leagues.find("ncaaf").?, "194");
    try std.testing.expectEqualStrings("OSU", by_id.team.abbrev);
    try std.testing.expectError(
        error.TeamNotFound,
        fetchTeam(teamTestAdapter(&fake), arena, core.leagues.find("ncaaf").?, "9999"),
    );
}

test "fetchTeam keeps ids linkable for pre-summary games" {
    var fake = TeamFixtureState{
        .teams_body = ncaaf_teams_two_osu,
        .schedule_body = ncaaf_osu_schedule,
        .board_body = team_fixture_board,
        .fail_board = true,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const view = try fetchTeam(teamTestAdapter(&fake), arena_state.allocator(), core.leagues.find("ncaaf").?, "OSU");
    // Completed game keeps its link; the scheduled future keeps its id too:
    // detail renders board-backed previews for games without a summary
    // yet and 404s gracefully only for truly unknown ids, so upcoming
    // games stay navigable (Next 5 links).
    try std.testing.expectEqualStrings("401858432", view.last[0].id);
    try std.testing.expectEqual(@as(usize, 1), view.next.len);
    try std.testing.expectEqualStrings("401858500", view.next[0].id);
    try std.testing.expectEqualStrings("at XYZ 3:30 PM", view.next[0].result);
    try std.testing.expectEqualStrings("XYZ", view.next[0].opponent_abbrev);
}

test "fetchTeam flags today's upcoming rows Eastern" {
    // Fake today is 2026-09-07T00:00Z: Eastern Sep 6. The 19:05Z row and
    // the 02:00Z row both fall on Sep 6 ET (the evening edge); 15:00Z is
    // Sep 7 ET. The completed row never flags, whatever its date.
    const sched =
        \\{"team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"events":[{"id":"done","date":"2026-09-06T15:00Z","competitions":[{"id":"done","date":"2026-09-06T15:00Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"homeAway":"home","team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"},"score":{"displayValue":"5"},"winner":true},{"homeAway":"away","team":{"id":"1","abbreviation":"NYM","displayName":"New York Mets"},"score":{"displayValue":"3"},"winner":false}]}]},{"id":"t1","date":"2026-09-06T19:05Z","competitions":[{"id":"t1","date":"2026-09-06T19:05Z","status":{"type":{"state":"pre","shortDetail":"Scheduled"}},"competitors":[{"homeAway":"home","team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"}},{"homeAway":"away","team":{"id":"1","abbreviation":"NYM","displayName":"New York Mets"}}]}]},{"id":"t2","date":"2026-09-07T02:00Z","competitions":[{"id":"t2","date":"2026-09-07T02:00Z","status":{"type":{"state":"pre","shortDetail":"Scheduled"}},"competitors":[{"homeAway":"home","team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"}},{"homeAway":"away","team":{"id":"1","abbreviation":"NYM","displayName":"New York Mets"}}]}]},{"id":"t3","date":"2026-09-07T15:00Z","competitions":[{"id":"t3","date":"2026-09-07T15:00Z","status":{"type":{"state":"pre","shortDetail":"Scheduled"}},"competitors":[{"homeAway":"home","team":{"id":"22","abbreviation":"PHI","displayName":"Philadelphia Phillies"}},{"homeAway":"away","team":{"id":"1","abbreviation":"NYM","displayName":"New York Mets"}}]}]}]}
    ;

    var fake = TeamFixtureState{
        .teams_body = team_fixture_teams,
        .schedule_body = sched,
        .board_body = team_fixture_board,
        .fail_board = true,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const view = try fetchTeam(teamTestAdapter(&fake), arena_state.allocator(), core.leagues.find("mlb").?, "PHI");
    try std.testing.expectEqual(@as(usize, 1), view.last.len);
    try std.testing.expect(!view.last[0].today);
    try std.testing.expectEqual(@as(usize, 3), view.next.len);
    try std.testing.expect(view.next[0].today);
    try std.testing.expect(view.next[1].today);
    try std.testing.expect(!view.next[2].today);
}

test "junk team-stats filter pins the exact generic counters" {
    try std.testing.expectEqual(@as(usize, 2), junk_team_stats.len);
    try std.testing.expectEqualStrings("Games Played", junk_team_stats[0]);
    try std.testing.expectEqualStrings("Team Games Played", junk_team_stats[1]);
    try std.testing.expect(isJunkTeamStat("atBats", "At Bats", "") == false);
    try std.testing.expect(isJunkTeamStat("wins", "Wins", "") == false);
}

test "detailFetch filters junk counters and maps the flat shape" {
    const summary =
        \\{"header":{"competitions":[{"id":"9","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"a","homeAway":"away","winner":true,"score":5,"team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"id":"h","homeAway":"home","winner":false,"score":4,"team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]},"boxscore":{"teams":[{"team":{"id":"a","abbreviation":"AWY"},"statistics":[{"name":"batting","displayName":"Batting","stats":[{"name":"gamesPlayed","displayName":"Games Played","displayValue":"1"},{"name":"atBats","displayName":"At Bats","displayValue":"35"}]}]},{"team":{"id":"h","abbreviation":"HME"},"statistics":[{"name":"gp","displayName":"GP","displayValue":"1","label":"Team Games Played"},{"name":"totalYards","displayValue":"165","label":"Total Yards"}]}]}}
    ;
    const board =
        \\{"events":[{"id":"9","name":"Away at Home","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"9","date":"2026-09-06T17:10Z","competitors":[{"homeAway":"away","score":"5","winner":true,"team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"homeAway":"home","score":"4","winner":false,"team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}]}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "9");
    // Grouped junk skipped, grouped legit kept; flat junk skipped by label,
    // flat legit mapped via label.
    try std.testing.expectEqual(@as(usize, 2), detail.team_stats.len);
    try std.testing.expectEqualStrings("AWY At Bats 35", detail.team_stats[0]);
    try std.testing.expectEqualStrings("HME Total Yards 165", detail.team_stats[1]);
}

const series_board =
    \\{"events":[{"id":"g7","name":"Boston at Someone","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"g7","date":"2026-09-06T17:10Z","competitors":[{"homeAway":"away","score":"5","winner":true,"team":{"id":"a","displayName":"Boston","abbreviation":"BOS"}},{"homeAway":"home","score":"1","winner":false,"team":{"id":"h","displayName":"Someone","abbreviation":"SOM"}}]}]}]}
;

test "seasonseries wins phrasing stays modest" {
    const summary =
        \\{"header":{"competitions":[{"id":"g7","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"a","homeAway":"away","winner":true,"score":5,"team":{"id":"a","displayName":"Boston","abbreviation":"BOS"}},{"id":"h","homeAway":"home","winner":false,"score":1,"team":{"id":"h","displayName":"Someone","abbreviation":"SOM"}}]}]},"seasonseries":[{"summary":"BOS wins series 3-1","completed":true,"totalCompetitions":4,"events":[{"id":"g4"},{"id":"g5"},{"id":"g6"},{"id":"g7"}]}]}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = series_board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "g7");
    try std.testing.expectEqualStrings("BOS won season series 3-1 (game 4 of 4)", detail.series.?);
    // Answered from the summary: no schedule derivation fetches.
    try std.testing.expectEqual(@as(usize, 0), fake.sched_calls);
}

test "trivial series suppress to null in both builders" {
    // Summary path: a lone game is not a series.
    const single_summary =
        \\{"header":{"competitions":[{"id":"g7","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"a","homeAway":"away","winner":true,"score":5,"team":{"id":"a","displayName":"Boston","abbreviation":"BOS"}},{"id":"h","homeAway":"home","winner":false,"score":1,"team":{"id":"h","displayName":"Someone","abbreviation":"SOM"}}]}]},"seasonseries":[{"summary":"BOS leads series 1-0","completed":false,"totalCompetitions":1,"events":[{"id":"g7"}]}]}
    ;
    // Schedule fallback path: any fetch problem (here 404) also omits.
    var fake = DetailFake{ .summary_body = single_summary, .board_body = series_board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "g7");
    try std.testing.expect(detail.series == null);

    // Schedule-derived path: a one-game block is a matchup, not a series.
    const bare_summary =
        \\{"header":{"competitions":[{"id":"solo","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"a","homeAway":"away","winner":true,"score":5,"team":{"id":"a","displayName":"Boston","abbreviation":"BOS"}},{"id":"h","homeAway":"home","winner":false,"score":1,"team":{"id":"h","displayName":"Someone","abbreviation":"SOM"}}]}]}}
    ;
    const solo_board =
        \\{"events":[{"id":"solo","name":"Boston at Someone","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"solo","date":"2026-09-06T17:10Z","competitors":[{"homeAway":"away","score":"5","winner":true,"team":{"id":"a","displayName":"Boston","abbreviation":"BOS"}},{"homeAway":"home","score":"1","winner":false,"team":{"id":"h","displayName":"Someone","abbreviation":"SOM"}}]}]}]}
    ;
    const solo_sched =
        \\{"events":[{"id":"solo","competitions":[{"competitors":[{"winner":true,"team":{"id":"a","abbreviation":"BOS"}},{"winner":false,"team":{"id":"h","abbreviation":"SOM"}}]}]}]}
    ;
    var fake2 = DetailFake{
        .summary_body = bare_summary,
        .board_body = solo_board,
        .sched_a_id = "/teams/a/",
        .sched_a_body = solo_sched,
        .sched_b_body = solo_sched,
    };
    const solo = try detailAdapter(&fake2).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "solo");
    try std.testing.expect(solo.series == null);
}

test "playoff series wording passes through" {
    const summary =
        \\{"header":{"competitions":[{"id":"g7","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"series":[{"summary":"BOS wins series 4-2","completed":true,"totalCompetitions":7,"events":[{"id":"g1"},{"id":"g2"},{"id":"g3"},{"id":"g4"},{"id":"g5"},{"id":"g6"},{"id":"g7"}]}],"competitors":[{"id":"a","homeAway":"away","winner":true,"score":5,"team":{"id":"a","displayName":"Boston","abbreviation":"BOS"}},{"id":"h","homeAway":"home","winner":false,"score":1,"team":{"id":"h","displayName":"Someone","abbreviation":"SOM"}}]}]}}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = series_board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "g7");
    try std.testing.expectEqualStrings("BOS wins series 4-2 (game 7 of 7)", detail.series.?);
    try std.testing.expectEqual(@as(usize, 0), fake.sched_calls);
}

test "schedule-derived series uses season phrasing" {
    const summary =
        \\{"header":{"competitions":[{"id":"401816828","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"22","homeAway":"home","winner":false,"score":4,"team":{"id":"22","displayName":"Philadelphia Phillies","abbreviation":"PHI"}},{"id":"15","homeAway":"away","winner":true,"score":5,"team":{"id":"15","displayName":"Atlanta Braves","abbreviation":"ATL"}}]}]},"plays":null}
    ;
    const tied_sched =
        \\{"events":[{"id":"401816798","competitions":[{"competitors":[{"winner":false,"team":{"id":"22","abbreviation":"PHI"}},{"winner":true,"team":{"id":"15","abbreviation":"ATL"}}]}]},{"id":"401816813","competitions":[{"competitors":[{"winner":true,"team":{"id":"22","abbreviation":"PHI"}},{"winner":false,"team":{"id":"15","abbreviation":"ATL"}}]}]},{"id":"401816828","competitions":[{"competitors":[{"winner":false,"team":{"id":"22","abbreviation":"PHI"}},{"winner":true,"team":{"id":"15","abbreviation":"ATL"}}]}]},{"id":"401816843","competitions":[{"competitors":[{"team":{"id":"22","abbreviation":"PHI"}},{"team":{"id":"15","abbreviation":"ATL"}}]}]}]}
    ;
    var fake = DetailFake{
        .summary_body = summary,
        .board_body = detail_board_fixture,
        .sched_a_id = "/teams/22/",
        .sched_a_body = tied_sched,
        .sched_b_body = tied_sched,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // 2-1 block omits the unplayed finale: leader phrasing, same suffix.
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "401816828");
    try std.testing.expectEqualStrings("ATL leads season series 2-1 (game 3 of 4)", detail.series.?);
}

const nba_thin_schedule =
    \\{"team":{"id":"2","abbreviation":"BOS","displayName":"Boston Celtics"},"events":[
    \\{"id":"401809936","date":"2025-10-22T23:30Z","competitions":[{"id":"401809936","date":"2025-10-22T23:30Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"homeAway":"home","winner":false,"score":{"value":116,"displayValue":"116"},"team":{"id":"2","abbreviation":"BOS","displayName":"Boston Celtics"},"probables":[]},{"homeAway":"away","winner":true,"score":{"value":117,"displayValue":"117"},"team":{"id":"23","abbreviation":"PHI","displayName":"Philadelphia 76ers"},"probables":[]}]}]}
    \\]}
;

const nba_thin_teams =
    \\{"sports":[{"leagues":[{"teams":[{"team":{"id":"2","abbreviation":"BOS","displayName":"Boston Celtics"}}]}]}]}
;

test "fetchTeam renders ESPN-thin NBA payloads without record or standing" {
    // Live 2026-09-09 shape: the NBA schedule header carries no
    // recordSummary/standingSummary and competitors carry no records, so
    // the view builds with nulls rather than failing. ESPN-thin, not a
    // mapping gap: there is no record field to map.
    var fake = TeamFixtureState{
        .teams_body = nba_thin_teams,
        .schedule_body = nba_thin_schedule,
        .board_body = team_fixture_board,
        .fail_board = true,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const view = try fetchTeam(teamTestAdapter(&fake), arena_state.allocator(), core.leagues.find("nba").?, "BOS");
    try std.testing.expect(view.team.record_summary == null);
    try std.testing.expect(view.team.standing_summary == null);
    try std.testing.expectEqual(@as(usize, 1), view.last.len);
    try std.testing.expectEqualStrings("L 116-117", view.last[0].result);
}

const ncaaf_detail_summary =
    \\{"header":{"competitions":[{"id":"401858432","date":"2026-09-05T16:30Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"2050","homeAway":"away","winner":false,"score":10,"team":{"id":"2050","displayName":"Ball State Cardinals","abbreviation":"BALL"}},{"id":"194","homeAway":"home","winner":true,"score":48,"team":{"id":"194","displayName":"Ohio State Buckeyes","abbreviation":"OSU"}}]}]},"scoringPlays":[{"text":"Jeremiah Smith 48 Yd pass from Julian Sayin (Connor Hawkins Kick)","awayScore":0,"homeScore":7,"period":{"number":1}},{"text":"Brody Boehm 54 Yd Field Goal","awayScore":3,"homeScore":21,"period":{"number":2}}],"leaders":[{"team":{"id":"194","abbreviation":"OSU"},"leaders":[{"name":"passingYards","displayName":"Passing Yards","leaders":[{"displayValue":"21/25, 320 YDS, 3 TD","athlete":{"displayName":"Julian Sayin","fullName":"Julian Sayin"}}]}]},{"team":{"id":"2050","abbreviation":"BALL"},"leaders":[{"name":"passingYards","displayName":"Passing Yards","leaders":[{"displayValue":"18/33, 89 YDS","athlete":{"displayName":"Keldric Luster","fullName":"Keldric Luster"}}]}]}],"boxscore":{"players":[{"team":{"id":"2050","abbreviation":"BALL"},"statistics":[{"keys":["completions/passingAttempts","passingYards"],"totals":["20/37","120"],"athletes":[{"athlete":{"id":"5075392","displayName":"Keldric Luster"},"stats":["18/33","89"]}]}]}]}}
;

const ncaaf_detail_board =
    \\{"events":[{"id":"401858432","name":"Ball State Cardinals at Ohio State Buckeyes","date":"2026-09-05T16:30Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"401858432","date":"2026-09-05T16:30Z","competitors":[{"homeAway":"away","score":"10","winner":false,"team":{"id":"2050","displayName":"Ball State Cardinals","abbreviation":"BALL"}},{"homeAway":"home","score":"48","winner":true,"team":{"id":"194","displayName":"Ohio State Buckeyes","abbreviation":"OSU"}}]}]}]}
;

test "fetchDetail maps football scoringPlays and top-level leaders" {
    var fake = DetailFake{ .summary_body = ncaaf_detail_summary, .board_body = ncaaf_detail_board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("ncaaf").?, "401858432");
    // scoringPlays (not `plays`): bare quarter numbers read Q1/Q2.
    try std.testing.expectEqual(@as(usize, 2), detail.scoring_plays.len);
    try std.testing.expectEqualStrings("Q1", detail.scoring_plays[0].period);
    try std.testing.expectEqualStrings("Jeremiah Smith 48 Yd pass from Julian Sayin (Connor Hawkins Kick)", detail.scoring_plays[0].text);
    try std.testing.expectEqualStrings("0", detail.scoring_plays[0].away_score);
    try std.testing.expectEqualStrings("7", detail.scoring_plays[0].home_score);
    try std.testing.expectEqualStrings("Q2", detail.scoring_plays[1].period);
    // Top-level leaders win over the boxscore fallback (same wire shape).
    try std.testing.expectEqual(@as(usize, 2), detail.leaders.len);
    try std.testing.expectEqualStrings("Julian Sayin 21/25, 320 YDS, 3 TD", detail.leaders[0]);
    try std.testing.expectEqualStrings("Keldric Luster 18/33, 89 YDS", detail.leaders[1]);
}

test "fetchDetail labels key-only boxscore totals without a bare total" {
    const summary =
        \\{"header":{"competitions":[{"id":"401858432","date":"2026-09-05T16:30Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"2050","homeAway":"away","winner":false,"score":10,"team":{"id":"2050","displayName":"Ball State Cardinals","abbreviation":"BALL"}},{"id":"194","homeAway":"home","winner":true,"score":48,"team":{"id":"194","displayName":"Ohio State Buckeyes","abbreviation":"OSU"}}]}]},"boxscore":{"players":[{"team":{"id":"2050","abbreviation":"BALL"},"statistics":[{"keys":["completions/passingAttempts","passingYards"],"totals":["20/37","120"],"athletes":[{"athlete":{"id":"5075392","displayName":"Keldric Luster"},"stats":["18/33","89"]}]}]}]}}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = ncaaf_detail_board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("ncaaf").?, "401858432");
    try std.testing.expectEqual(@as(usize, 2), detail.leaders.len);
    try std.testing.expectEqualStrings("BALL Completions/passing attempts 20/37", detail.leaders[0]);
    try std.testing.expectEqualStrings("Keldric Luster 18/33", detail.leaders[1]);
}

test "humanizeStatKey spaces camel humps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("Completions/passing attempts", try humanizeStatKey(arena, "completions/passingAttempts"));
    try std.testing.expectEqualStrings("Passing yards", try humanizeStatKey(arena, "passingYards"));
    try std.testing.expectEqualStrings("H-AB", try humanizeStatKey(arena, "H-AB"));
}

const ucl_detail_board =
    \\{"events":[{"id":"784123","name":"Inter Milan at FC Barcelona","date":"2026-04-15T19:00Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"784123","date":"2026-04-15T19:00Z","competitors":[{"homeAway":"away","score":"2","winner":false,"team":{"id":"110","displayName":"Inter Milan","abbreviation":"INT"}},{"homeAway":"home","score":"3","winner":true,"team":{"id":"83","displayName":"FC Barcelona","abbreviation":"BAR"}}]}]}]}
;

test "fetchDetail labels bare-number soccer top leaders and drops zero attendance" {
    // Live UCL audit: soccer top-level categories ship bare numbers
    // ("5" under "Shots"), which used to render as "Dani Olmo 5",
    // and ESPN reports 0 for unknown attendance ("Spotify Camp Nou
    // (0)"). Both now read labeled / suppressed.
    const summary =
        \\{"header":{"competitions":[{"id":"784123","date":"2026-04-15T19:00Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"110","homeAway":"away","winner":false,"score":2,"team":{"id":"110","displayName":"Inter Milan","abbreviation":"INT"}},{"id":"83","homeAway":"home","winner":true,"score":3,"team":{"id":"83","displayName":"FC Barcelona","abbreviation":"BAR"}}]}]},"leaders":[{"team":{"id":"83","abbreviation":"BAR"},"leaders":[{"name":"shots","displayName":"Shots","leaders":[{"displayValue":5,"athlete":{"displayName":"Dani Olmo","fullName":"Dani Olmo"}}]},{"name":"passes","displayName":"Passes","leaders":[{"displayValue":108,"athlete":{"displayName":"Pau Cubarsí","fullName":"Pau Cubarsí"}}]}]}],"gameInfo":{"attendance":0,"venue":{"fullName":"Spotify Camp Nou"}}}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = ucl_detail_board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("ucl").?, "784123");
    try std.testing.expectEqual(@as(usize, 2), detail.leaders.len);
    try std.testing.expectEqualStrings("Dani Olmo Shots 5", detail.leaders[0]);
    try std.testing.expectEqualStrings("Pau Cubarsí Passes 108", detail.leaders[1]);
    try std.testing.expectEqualStrings("Spotify Camp Nou", detail.venue.?);
    try std.testing.expect(detail.attendance == null);
}

test "fetchDetail labels key-only soccer boxscore leaders with empty names" {
    // Soccer boxscore groups may carry empty `names` with key-only
    // columns; the totals label and bare athlete values must still read
    // labeled via humanized keys, never bare numbers.
    const summary =
        \\{"header":{"competitions":[{"id":"784123","date":"2026-04-15T19:00Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"110","homeAway":"away","winner":false,"score":2,"team":{"id":"110","displayName":"Inter Milan","abbreviation":"INT"}},{"id":"83","homeAway":"home","winner":true,"score":3,"team":{"id":"83","displayName":"FC Barcelona","abbreviation":"BAR"}}]}]},"boxscore":{"players":[{"team":{"id":"83","abbreviation":"BAR"},"statistics":[{"names":["",""],"keys":["goals","assists"],"totals":[3,2],"athletes":[{"athlete":{"id":"9001","displayName":"Dani Olmo","fullName":"Dani Olmo"},"stats":[2,1]}]}]}]},"gameInfo":{"attendance":50578,"venue":{"fullName":"Spotify Camp Nou"}}}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = ucl_detail_board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("ucl").?, "784123");
    try std.testing.expectEqual(@as(usize, 2), detail.leaders.len);
    try std.testing.expectEqualStrings("BAR Goals 3", detail.leaders[0]);
    try std.testing.expectEqualStrings("Dani Olmo Goals 2", detail.leaders[1]);
    // Nonzero attendance still parses through.
    try std.testing.expectEqual(@as(i64, 50578), detail.attendance.?);
}

test "fetchTeam renders TBD for timeValid-false kickoffs" {
    // The reported ncaaf/OSU 09-26 vs ILL shape: ESPN carries a midnight
    // placeholder with an explicit `timeValid: false`, which used to
    // render as a literal 12:00 AM. The flag (never the clock) decides:
    // a genuine midnight ET kickoff with a valid flag still formats.
    const tbd_schedule =
        \\{"team":{"id":"194","abbreviation":"OSU","displayName":"Ohio State Buckeyes"},"events":[
        \\{"id":"tbd1","date":"2026-09-26T04:00Z","competitions":[{"id":"tbd1","date":"2026-09-26T04:00Z","timeValid":false,"status":{"type":{"state":"pre","shortDetail":"Scheduled"}},"competitors":[{"homeAway":"home","team":{"id":"194","abbreviation":"OSU","displayName":"Ohio State Buckeyes"},"probables":[]},{"homeAway":"away","team":{"id":"21","abbreviation":"ILL","displayName":"Illinois Fighting Illini"},"probables":[]}]}]},
        \\{"id":"real1","date":"2026-09-27T04:00Z","competitions":[{"id":"real1","date":"2026-09-27T04:00Z","timeValid":true,"status":{"type":{"state":"pre","shortDetail":"Scheduled"}},"competitors":[{"homeAway":"away","team":{"id":"194","abbreviation":"OSU","displayName":"Ohio State Buckeyes"},"probables":[]},{"homeAway":"home","team":{"id":"99","abbreviation":"XYZ","displayName":"X Y Zed"},"probables":[]}]}]}
        \\]}
    ;
    var fake = TeamFixtureState{
        .teams_body = ncaaf_teams_two_osu,
        .schedule_body = tbd_schedule,
        .board_body = team_fixture_board,
        .fail_board = true, // schedule-only; live join off.
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const view = try fetchTeam(teamTestAdapter(&fake), arena_state.allocator(), core.leagues.find("ncaaf").?, "OSU");
    try std.testing.expectEqual(@as(usize, 2), view.next.len);
    try std.testing.expectEqualStrings("vs ILL TBD", view.next[0].result);
    try std.testing.expectEqualStrings("at XYZ 12:00 AM", view.next[1].result);
}

test "stripSeriesPrefix drops one echoed view prefix" {
    try std.testing.expectEqualStrings("tied 1-1", stripSeriesPrefix("Series tied 1-1"));
    try std.testing.expectEqualStrings("tied 1-1", stripSeriesPrefix("Series: tied 1-1"));
    try std.testing.expectEqualStrings("tied 1-1", stripSeriesPrefix("series tied 1-1"));
    try std.testing.expectEqualStrings("BOS wins series 4-2", stripSeriesPrefix("BOS wins series 4-2"));
    try std.testing.expectEqualStrings("Series", stripSeriesPrefix("Series"));
}

test "playoff verbatim series renders without a doubled prefix" {
    const summary =
        \\{"header":{"competitions":[{"id":"g7","date":"2026-09-06T17:10Z","status":{"type":{"state":"post","shortDetail":"Final"}},"series":[{"summary":"Series tied 1-1","completed":false,"totalCompetitions":4,"events":[{"id":"g5"},{"id":"g6"},{"id":"g7"},{"id":"g8"}]}],"competitors":[{"id":"a","homeAway":"away","winner":true,"score":5,"team":{"id":"a","displayName":"Boston","abbreviation":"BOS"}},{"id":"h","homeAway":"home","winner":false,"score":1,"team":{"id":"h","displayName":"Someone","abbreviation":"SOM"}}]}]}}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = series_board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "g7");
    try std.testing.expectEqualStrings("tied 1-1 (game 3 of 4)", detail.series.?);
    // Answered from the summary: no schedule derivation fetches.
    try std.testing.expectEqual(@as(usize, 0), fake.sched_calls);
}

test "boxscoreLineups keeps starters in order with positions" {
    const boxscore: SummaryBoxscore = .{
        .players = &.{
            .{
                .team = .{ .abbreviation = "ATL" },
                .statistics = &.{
                    .{
                        .names = &.{ "H-AB", "AB", "R", "AVG" },
                        .keys = &.{ "hits-atBats", "atBats", "runs", "avg" },
                        .totals = &.{ .{ .string = "10-35" }, .{ .string = "35" }, .{ .string = "5" }, .{ .string = "" } },
                        .athletes = &.{
                            .{
                                .athlete = .{ .displayName = "Ronald Acuna Jr." },
                                .stats = &.{ .{ .string = "2-3" }, .{ .string = "3" }, .{ .string = "1" }, .{ .string = ".255" } },
                                .batOrder = 2,
                                .starter = true,
                                .position = .{ .abbreviation = "RF" },
                            },
                            .{
                                .athlete = .{ .displayName = "Bench Bat" },
                                .stats = &.{.{ .string = "1-1" }},
                                .batOrder = null,
                                .starter = false,
                                .position = .{ .abbreviation = "PH" },
                            },
                        },
                    },
                    .{
                        .names = &.{"IP"},
                        .keys = &.{"inningsPitched"},
                        .athletes = &.{},
                    },
                },
            },
        },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(core.detail.LineupSide) = .empty;
    try boxscoreLineups(arena_state.allocator(), boxscore, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("ATL", out.items[0].team);
    try std.testing.expectEqualStrings("10-35", out.items[0].total);
    try std.testing.expectEqual(@as(usize, 1), out.items[0].entries.len);
    const leadoff = out.items[0].entries[0];
    try std.testing.expectEqual(@as(i64, 2), leadoff.order);
    try std.testing.expectEqualStrings("RF", leadoff.position);
    try std.testing.expectEqualStrings("Ronald Acuna Jr.", leadoff.name);
    try std.testing.expectEqualStrings("2-3", leadoff.hitting);
    try std.testing.expectEqualStrings("1", leadoff.runs);
    try std.testing.expectEqualStrings(".255", leadoff.average);
}

// ---- Human game aliases (additive; existing fns above are untouched) ----
//
// `/{league}/{YYYY-MM-DD}/{away}-{home}` (all leagues) and the football-only
// `/{league}/{YYYY}/week{N}/{away}-{home}` redirect to the canonical
// `/{league}/{id}` game page. No `/api/v1/` twins (JSON keeps ids).

/// Week-alias board: the normalized week slate plus the raw response's
/// `season.year` for the caller to verify against the URL season.
pub const WeekBoard = struct {
    board: core.domain.Scoreboard,
    season_year: ?u16,
};

const WeekSeasonEnvelope = struct {
    season: ?WeekSeasonBlock = null,
};

const WeekSeasonBlock = struct {
    year: std.json.Value = .null,
};

/// Raw scoreboard envelope `season.year`. Tolerates integer and string
/// years; null when absent or non-numeric (the caller 404s: a missing year
/// can never confirm the URL season).
fn parseSeasonYear(arena: std.mem.Allocator, body: []const u8) !?u16 {
    const env = try std.json.parseFromSliceLeaky(WeekSeasonEnvelope, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    const year_value = (env.season orelse return null).year;
    return switch (year_value) {
        .integer => |n| if (n >= 0 and n <= 9999) @intCast(n) else null,
        .number_string, .string => |s| std.fmt.parseInt(u16, s, 10) catch null,
        else => null,
    };
}

/// Matchup lookup for the human game aliases: the Nth game whose two
/// participants carry non-empty abbreviations matching `away`/`home`,
/// case-insensitive (N = 1 selects the first — the historical
/// `findGameByMatchup` behavior). Exact away/home order wins first, then
/// the swapped order; board order wins within each pass, so N counts down
/// the concatenated [exact..., swapped...] list — doubleheaders share the
/// pair, and `/{league}/{date}/{away}-{home}-2` is the second listing.
/// N of 0, or past the last same-pair game, misses (the caller 404s).
/// Needs two-abbr duels: games without exactly two participants, or with
/// an empty abbreviation (tennis-style athlete rows, and every bout, race
/// field, and tournament field), never match — see `boardHasNonDuels`.
pub fn findGameByMatchupN(board: core.domain.Scoreboard, away: []const u8, home: []const u8, n: u16) ?*const core.domain.Game {
    if (n == 0) return null;
    var seen: usize = 0;
    for (board.games) |*game| {
        if (!isDuel(game, away, home)) continue;
        seen += 1;
        if (seen == n) return game;
    }
    for (board.games) |*game| {
        if (!isDuel(game, home, away)) continue;
        seen += 1;
        if (seen == n) return game;
    }
    return null;
}

/// First-wins matchup lookup (the bare `/{league}/{date}/{away}-{home}`
/// form): N = 1 of `findGameByMatchupN`.
pub fn findGameByMatchup(board: core.domain.Scoreboard, away: []const u8, home: []const u8) ?*const core.domain.Game {
    return findGameByMatchupN(board, away, home, 1);
}

/// Ordinal lookup for the human `event[-N]` aliases: the Nth game on the
/// board in listed order (1-based), counting EVERY game — duels and
/// non-duels alike. N of 0, or past the last game, misses (the caller
/// 404s, never a wrong redirect). This is the only alias form that can
/// name a non-duel, by design (see below).
///
/// Scheme choice, with evidence. Name slugs were rejected: a UFC card
/// boards ~14 bouts under ONE event name (every bout names the card, so a
/// slug collides 14 ways), an F1 weekend boards ~3 sessions under one
/// Grand Prix name (practice/quali/race collide), and a PGA tournament
/// boards one field of ~95 abbreviation-less athletes (no pair exists at
/// all). Names are also unstable: sponsor prefixes come and go
/// ("Pirelli Italian Grand Prix" vs "Italian Grand Prix"), cards get
/// renamed, and a slug would rot or collide. Tennis proves the same point
/// at duel size: two athletes, empty abbreviations, so no abbr pair can
/// match — and surname slugs are fragile (diacritics, shared surnames,
/// hyphenation). The board ordinal is deterministic from the fetched
/// slate alone: date + position, no string normalization, stable within
/// the day, and it can never resolve to the wrong game (out-of-range is
/// a 404). Duels keep their abbr pairs; `event-N` reaches everything.
pub fn findGameByOrdinal(board: core.domain.Scoreboard, n: u16) ?*const core.domain.Game {
    if (n == 0) return null;
    if (n > board.games.len) return null;
    return &board.games[n - 1];
}
/// match: anything but a two-participant game with both abbreviations set
/// (fight cards, race sessions, tournament fields, athlete duels). The
/// alias miss message uses this to tell a duel-only dead end apart from a
/// typo'd pair on an all-duel day.
pub fn boardHasNonDuels(board: core.domain.Scoreboard) bool {
    for (board.games) |*game| {
        if (game.participants.len != 2) return true;
        if (game.participants[0].abbreviation.len == 0) return true;
        if (game.participants[1].abbreviation.len == 0) return true;
    }
    return false;
}

/// 404 body for a human game alias that matched nothing. Plain
/// "game not found" on all-duel days (likely a typo'd pair); when the
/// board also carries cards, races, or tournaments — events without
/// abbreviations, so no abbr pair can ever match them — the message says
/// the duel aliases are duel-only and points at the ordinal form plus the
/// day board for the event list. `browse` is the caller's board address
/// (`/{slug}?date={day}` for the date form, `/{slug}?week={N}` for the
/// week form); the ordinal example reuses the board's own date so the
/// hint stays copy-pasteable.
pub fn aliasMissMessage(arena: std.mem.Allocator, board: core.domain.Scoreboard, browse: []const u8) ![]u8 {
    if (!boardHasNonDuels(board)) return arena.dupe(u8, "game not found");
    return std.fmt.allocPrint(arena, "game not found; duel aliases match two team abbreviations only — cards, races, tournaments, and name-only duels use /{s}/{s}/event-N (N = game number on the day board), browse {s} for the event list", .{ board.league, board.date, browse });
}

fn isDuel(game: *const core.domain.Game, first: []const u8, second: []const u8) bool {
    if (game.participants.len != 2) return false;
    const a = game.participants[0].abbreviation;
    const b = game.participants[1].abbreviation;
    if (a.len == 0 or b.len == 0) return false;
    return std.ascii.eqlIgnoreCase(a, first) and std.ascii.eqlIgnoreCase(b, second);
}

fn matchupBoard() core.domain.Scoreboard {
    return .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-09",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "",
                .starts_at = "2026-09-09T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Minnesota Twins", .abbreviation = "MIN", .score = "2", .winner = false, .home_away = "away" },
                    .{ .id = "h", .name = "Detroit Tigers", .abbreviation = "DET", .score = "5", .winner = true, .home_away = "home" },
                },
            },
            .{
                .id = "2",
                .name = "",
                .starts_at = "2026-09-09T19:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "c", .name = "Chicago Cubs", .abbreviation = "CHC", .score = "1", .winner = false, .home_away = "away" },
                    .{ .id = "d", .name = "St. Louis Cardinals", .abbreviation = "STL", .score = "3", .winner = true, .home_away = "home" },
                },
            },
        },
    };
}

test "findGameByMatchup matches exact order, swapped, and case" {
    const board = matchupBoard();
    // Exact away/home order first.
    try std.testing.expectEqualStrings("1", findGameByMatchup(board, "min", "det").?.id);
    try std.testing.expectEqualStrings("2", findGameByMatchup(board, "chc", "stl").?.id);
    // Swapped order still lands (second pass).
    try std.testing.expectEqualStrings("1", findGameByMatchup(board, "det", "min").?.id);
    // Case-insensitive throughout.
    try std.testing.expectEqualStrings("1", findGameByMatchup(board, "MIN", "DET").?.id);
    try std.testing.expectEqualStrings("1", findGameByMatchup(board, "Min", "Det").?.id);
    try std.testing.expectEqualStrings("1", findGameByMatchup(board, "DET", "MIN").?.id);
}

test "findGameByMatchup misses unknown pairs and non-duels" {
    const board = matchupBoard();
    // Unknown abbrevs, cross-game pairs, and half pairs never match.
    try std.testing.expect(findGameByMatchup(board, "nyy", "bos") == null);
    try std.testing.expect(findGameByMatchup(board, "min", "stl") == null);
    try std.testing.expect(findGameByMatchup(board, "min", "min") == null);
    try std.testing.expect(findGameByMatchup(board, "", "det") == null);
    // Fewer than two participants, more than two, or an empty abbreviation
    // (tennis-style athlete rows) never match.
    const thin: core.domain.Scoreboard = .{
        .league = "f1",
        .league_name = "F1",
        .date = "2026-09-09",
        .source = "test",
        .games = &.{
            .{
                .id = "solo",
                .name = "Race",
                .starts_at = "2026-09-09T10:30Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "v", .name = "Max Verstappen", .abbreviation = "VER", .score = "#1", .winner = true },
                },
            },
            .{
                .id = "trio",
                .name = "",
                .starts_at = "2026-09-09T10:30Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "A Club", .abbreviation = "AAA", .score = "", .winner = false },
                    .{ .id = "b", .name = "B Club", .abbreviation = "BBB", .score = "", .winner = false },
                    .{ .id = "c", .name = "C Club", .abbreviation = "CCC", .score = "", .winner = false },
                },
            },
            .{
                .id = "blank",
                .name = "",
                .starts_at = "2026-09-09T10:30Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "a", .name = "Player One", .abbreviation = "", .score = "", .winner = false },
                    .{ .id = "b", .name = "Player Two", .abbreviation = "", .score = "", .winner = false },
                },
            },
        },
    };
    try std.testing.expect(findGameByMatchup(thin, "ver", "x") == null);
    try std.testing.expect(findGameByMatchup(thin, "aaa", "bbb") == null);
    try std.testing.expect(findGameByMatchup(thin, "", "") == null);
    // Empty board never matches.
    const empty: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-09",
        .source = "test",
        .games = &.{},
    };
    try std.testing.expect(findGameByMatchup(empty, "min", "det") == null);
}

test "findGameByMatchup first wins on doubleheaders" {
    // A doubleheader shares the pair: the earliest board entry is the
    // redirect, in exact and swapped order alike.
    const board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-09",
        .source = "test",
        .games = &.{
            .{
                .id = "first",
                .name = "",
                .starts_at = "2026-09-09T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Minnesota Twins", .abbreviation = "MIN", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Detroit Tigers", .abbreviation = "DET", .score = "5", .winner = true },
                },
            },
            .{
                .id = "second",
                .name = "",
                .starts_at = "2026-09-09T20:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "a", .name = "Minnesota Twins", .abbreviation = "MIN", .score = "", .winner = false },
                    .{ .id = "h", .name = "Detroit Tigers", .abbreviation = "DET", .score = "", .winner = false },
                },
            },
        },
    };
    try std.testing.expectEqualStrings("first", findGameByMatchup(board, "min", "det").?.id);
    try std.testing.expectEqualStrings("first", findGameByMatchup(board, "det", "min").?.id);
}

test "findGameByMatchupN disambiguates doubleheaders, out-of-range misses" {
    const board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-09",
        .source = "test",
        .games = &.{
            .{
                .id = "first",
                .name = "",
                .starts_at = "2026-09-09T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Minnesota Twins", .abbreviation = "MIN", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Detroit Tigers", .abbreviation = "DET", .score = "5", .winner = true },
                },
            },
            .{
                .id = "second",
                .name = "",
                .starts_at = "2026-09-09T20:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "a", .name = "Minnesota Twins", .abbreviation = "MIN", .score = "", .winner = false },
                    .{ .id = "h", .name = "Detroit Tigers", .abbreviation = "DET", .score = "", .winner = false },
                },
            },
        },
    };
    // Absent suffix is 1 (the bare lookup delegates): first listing wins.
    try std.testing.expectEqualStrings("first", findGameByMatchupN(board, "min", "det", 1).?.id);
    try std.testing.expectEqualStrings("first", findGameByMatchup(board, "min", "det").?.id);
    // -2 selects the second game; -3 on a 2-game day misses (caller 404s).
    try std.testing.expectEqualStrings("second", findGameByMatchupN(board, "min", "det", 2).?.id);
    try std.testing.expect(findGameByMatchupN(board, "min", "det", 3) == null);
    // Swapped order rides the same numbering (exact pass first).
    try std.testing.expectEqualStrings("first", findGameByMatchupN(board, "det", "min", 1).?.id);
    try std.testing.expectEqualStrings("second", findGameByMatchupN(board, "det", "min", 2).?.id);
    try std.testing.expect(findGameByMatchupN(board, "det", "min", 3) == null);
    // N of 0 misses; unknown pairs miss at every N.
    try std.testing.expect(findGameByMatchupN(board, "min", "det", 0) == null);
    try std.testing.expect(findGameByMatchupN(board, "nyy", "bos", 1) == null);
    try std.testing.expect(findGameByMatchupN(board, "nyy", "bos", 2) == null);
}

test "findGameByMatchupN counts exact before swapped" {
    // Mixed listing order: the swapped-order game boards first, but the
    // exact pass still wins N = 1, and N = 2 falls to the swapped pass.
    const board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-09",
        .source = "test",
        .games = &.{
            .{
                .id = "listed-first",
                .name = "",
                .starts_at = "2026-09-09T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "h", .name = "Detroit Tigers", .abbreviation = "DET", .score = "5", .winner = true },
                    .{ .id = "a", .name = "Minnesota Twins", .abbreviation = "MIN", .score = "2", .winner = false },
                },
            },
            .{
                .id = "listed-second",
                .name = "",
                .starts_at = "2026-09-09T20:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "a", .name = "Minnesota Twins", .abbreviation = "MIN", .score = "", .winner = false },
                    .{ .id = "h", .name = "Detroit Tigers", .abbreviation = "DET", .score = "", .winner = false },
                },
            },
        },
    };
    try std.testing.expectEqualStrings("listed-second", findGameByMatchupN(board, "min", "det", 1).?.id);
    try std.testing.expectEqualStrings("listed-first", findGameByMatchupN(board, "min", "det", 2).?.id);
    try std.testing.expect(findGameByMatchupN(board, "min", "det", 3) == null);
}

test "boardHasNonDuels separates cards and fields from duel days" {
    // All-duel day: every game is two abbr'd participants.
    try std.testing.expect(!boardHasNonDuels(matchupBoard()));
    // Empty board is all-duel (plain miss, no hint).
    const empty: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-09",
        .source = "test",
        .games = &.{},
    };
    try std.testing.expect(!boardHasNonDuels(empty));
    // Fight card: one 2-athlete bout with empty abbreviations.
    const card: core.domain.Scoreboard = .{
        .league = "ufc",
        .league_name = "UFC",
        .date = "2026-09-05",
        .source = "test",
        .games = &.{
            .{
                .id = "401913130",
                .name = "UFC Fight Night: Hooker vs. Parnasse",
                .starts_at = "2026-09-05T22:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Sofia Montenegro", .abbreviation = "", .score = "", .winner = true },
                    .{ .id = "b", .name = "Delphine Benouaich", .abbreviation = "", .score = "", .winner = false },
                },
            },
        },
    };
    try std.testing.expect(boardHasNonDuels(card));
    try std.testing.expect(findGameByMatchupN(card, "sof", "del", 1) == null);
    // Race field: twenty athletes, no abbreviations.
    const field: core.domain.Scoreboard = .{
        .league = "f1",
        .league_name = "F1",
        .date = "2025-09-07",
        .source = "test",
        .games = &.{
            .{
                .id = "401737814",
                .name = "Pirelli Italian Grand Prix",
                .starts_at = "2025-09-07T13:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Max Verstappen", .abbreviation = "", .score = "#1", .winner = true },
                    .{ .id = "b", .name = "Lando Norris", .abbreviation = "", .score = "#2", .winner = false },
                    .{ .id = "c", .name = "Oscar Piastri", .abbreviation = "", .score = "#3", .winner = false },
                },
            },
        },
    };
    try std.testing.expect(boardHasNonDuels(field));
    try std.testing.expect(findGameByMatchupN(field, "ver", "nor", 1) == null);
}

test "aliasMissMessage hints the board only past duels" {
    const arena = std.testing.allocator;
    // All-duel day: the historical plain miss, unchanged.
    const plain = try aliasMissMessage(arena, matchupBoard(), "/mlb?date=2026-09-09");
    defer arena.free(plain);
    try std.testing.expectEqualStrings("game not found", plain);
    // Fight-card day: duel-only note plus the browse address.
    const card: core.domain.Scoreboard = .{
        .league = "ufc",
        .league_name = "UFC",
        .date = "2026-09-05",
        .source = "test",
        .games = &.{
            .{
                .id = "401913130",
                .name = "UFC Fight Night: Hooker vs. Parnasse",
                .starts_at = "2026-09-05T22:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Sofia Montenegro", .abbreviation = "", .score = "", .winner = true },
                    .{ .id = "b", .name = "Delphine Benouaich", .abbreviation = "", .score = "", .winner = false },
                },
            },
        },
    };
    const hinted = try aliasMissMessage(arena, card, "/ufc?date=2026-09-05");
    defer arena.free(hinted);
    try std.testing.expect(std.mem.indexOf(u8, hinted, "game not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, hinted, "two team abbreviations") != null);
    try std.testing.expect(std.mem.indexOf(u8, hinted, "/ufc?date=2026-09-05") != null);
    // The hint names the ordinal form with a copy-pasteable board date.
    try std.testing.expect(std.mem.indexOf(u8, hinted, "event-N") != null);
    try std.testing.expect(std.mem.indexOf(u8, hinted, "/ufc/2026-09-05/event-N") != null);
}

/// UFC card fixture: 14 bouts, ONE shared event name. A name slug could
/// never pick a bout (14-way collision); the ordinal names each bout by
/// board position. Abbr pairs match nothing here (empty abbreviations).
fn ufcCardBoard() core.domain.Scoreboard {
    return .{
        .league = "ufc",
        .league_name = "UFC",
        .date = "2026-09-05",
        .source = "test",
        .games = @constCast(&[_]core.domain.Game{
            .{ .id = "bout-01", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-05T22:00Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a1", .name = "Fighter A1", .abbreviation = "", .score = "", .winner = true },
                .{ .id = "b1", .name = "Fighter B1", .abbreviation = "", .score = "", .winner = false },
            }) },
            .{ .id = "bout-02", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-05T22:20Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a2", .name = "Fighter A2", .abbreviation = "", .score = "", .winner = false },
                .{ .id = "b2", .name = "Fighter B2", .abbreviation = "", .score = "", .winner = true },
            }) },
            .{ .id = "bout-03", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-05T22:40Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a3", .name = "Fighter A3", .abbreviation = "", .score = "", .winner = true },
                .{ .id = "b3", .name = "Fighter B3", .abbreviation = "", .score = "", .winner = false },
            }) },
            .{ .id = "bout-04", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-05T23:00Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a4", .name = "Fighter A4", .abbreviation = "", .score = "", .winner = true },
                .{ .id = "b4", .name = "Fighter B4", .abbreviation = "", .score = "", .winner = false },
            }) },
            .{ .id = "bout-05", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-05T23:20Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a5", .name = "Fighter A5", .abbreviation = "", .score = "", .winner = false },
                .{ .id = "b5", .name = "Fighter B5", .abbreviation = "", .score = "", .winner = true },
            }) },
            .{ .id = "bout-06", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-05T23:40Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a6", .name = "Fighter A6", .abbreviation = "", .score = "", .winner = true },
                .{ .id = "b6", .name = "Fighter B6", .abbreviation = "", .score = "", .winner = false },
            }) },
            .{ .id = "bout-07", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-06T00:00Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a7", .name = "Fighter A7", .abbreviation = "", .score = "", .winner = true },
                .{ .id = "b7", .name = "Fighter B7", .abbreviation = "", .score = "", .winner = false },
            }) },
            .{ .id = "bout-08", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-06T00:20Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a8", .name = "Fighter A8", .abbreviation = "", .score = "", .winner = false },
                .{ .id = "b8", .name = "Fighter B8", .abbreviation = "", .score = "", .winner = true },
            }) },
            .{ .id = "bout-09", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-06T00:40Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a9", .name = "Fighter A9", .abbreviation = "", .score = "", .winner = true },
                .{ .id = "b9", .name = "Fighter B9", .abbreviation = "", .score = "", .winner = false },
            }) },
            .{ .id = "bout-10", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-06T01:00Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a10", .name = "Fighter A10", .abbreviation = "", .score = "", .winner = true },
                .{ .id = "b10", .name = "Fighter B10", .abbreviation = "", .score = "", .winner = false },
            }) },
            .{ .id = "bout-11", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-06T01:20Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a11", .name = "Fighter A11", .abbreviation = "", .score = "", .winner = false },
                .{ .id = "b11", .name = "Fighter B11", .abbreviation = "", .score = "", .winner = true },
            }) },
            .{ .id = "bout-12", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-06T01:40Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a12", .name = "Fighter A12", .abbreviation = "", .score = "", .winner = true },
                .{ .id = "b12", .name = "Fighter B12", .abbreviation = "", .score = "", .winner = false },
            }) },
            .{ .id = "bout-13", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-06T02:00Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a13", .name = "Fighter A13", .abbreviation = "", .score = "", .winner = true },
                .{ .id = "b13", .name = "Fighter B13", .abbreviation = "", .score = "", .winner = false },
            }) },
            .{ .id = "bout-14", .name = "UFC Fight Night: Hooker vs. Parnasse", .starts_at = "2026-09-06T02:30Z", .state = "post", .status = "Final", .participants = @constCast(&[_]core.domain.Participant{
                .{ .id = "a14", .name = "Sofia Montenegro", .abbreviation = "", .score = "", .winner = true },
                .{ .id = "b14", .name = "Delphine Benouaich", .abbreviation = "", .score = "", .winner = false },
            }) },
        }),
    };
}

/// F1 weekend fixture: 3 sessions, ONE shared Grand Prix name. A name
/// slug collides 3 ways; the ordinal separates practice/quali/race.
fn f1WeekendBoard() core.domain.Scoreboard {
    return .{
        .league = "f1",
        .league_name = "F1",
        .date = "2025-09-07",
        .source = "test",
        .games = &.{
            .{
                .id = "practice-3",
                .name = "Pirelli Italian Grand Prix",
                .starts_at = "2025-09-06T10:30Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Max Verstappen", .abbreviation = "", .score = "#1", .winner = true },
                    .{ .id = "b", .name = "Lando Norris", .abbreviation = "", .score = "#2", .winner = false },
                },
            },
            .{
                .id = "qualifying",
                .name = "Pirelli Italian Grand Prix",
                .starts_at = "2025-09-06T14:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Max Verstappen", .abbreviation = "", .score = "#1", .winner = true },
                    .{ .id = "b", .name = "Lando Norris", .abbreviation = "", .score = "#2", .winner = false },
                    .{ .id = "c", .name = "Oscar Piastri", .abbreviation = "", .score = "#3", .winner = false },
                },
            },
            .{
                .id = "401737814",
                .name = "Pirelli Italian Grand Prix",
                .starts_at = "2025-09-07T13:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Max Verstappen", .abbreviation = "", .score = "#1", .winner = true },
                    .{ .id = "b", .name = "Lando Norris", .abbreviation = "", .score = "#2", .winner = false },
                    .{ .id = "c", .name = "Oscar Piastri", .abbreviation = "", .score = "#3", .winner = false },
                },
            },
        },
    };
}

test "ordinal reaches every bout on a shared-name UFC card" {
    const card = ufcCardBoard();
    try std.testing.expectEqual(@as(usize, 14), card.games.len);
    // Every bout resolves by position; no abbr pair can name any of them.
    try std.testing.expectEqualStrings("bout-01", findGameByOrdinal(card, 1).?.id);
    try std.testing.expectEqualStrings("bout-07", findGameByOrdinal(card, 7).?.id);
    try std.testing.expectEqualStrings("bout-14", findGameByOrdinal(card, 14).?.id);
    try std.testing.expect(findGameByOrdinal(card, 15) == null);
    try std.testing.expect(findGameByOrdinal(card, 0) == null);
    try std.testing.expect(findGameByMatchupN(card, "sof", "del", 1) == null);
    try std.testing.expect(boardHasNonDuels(card));
    // End-to-end shape of the serve path: the ordinal URL parses and the
    // lookup lands on the fetched board's game id.
    const router = @import("router.zig");
    const route = router.parse("/ufc/2026-09-05/event-14");
    try std.testing.expect(route == .date_event);
    try std.testing.expectEqualStrings("bout-14", findGameByOrdinal(card, route.date_event.n).?.id);
    const bare = router.parse("/ufc/2026-09-05/event");
    try std.testing.expectEqualStrings("bout-01", findGameByOrdinal(card, bare.date_event.n).?.id);
}

test "ordinal separates same-name F1 sessions" {
    const weekend = f1WeekendBoard();
    try std.testing.expectEqualStrings("practice-3", findGameByOrdinal(weekend, 1).?.id);
    try std.testing.expectEqualStrings("qualifying", findGameByOrdinal(weekend, 2).?.id);
    try std.testing.expectEqualStrings("401737814", findGameByOrdinal(weekend, 3).?.id);
    try std.testing.expect(findGameByOrdinal(weekend, 4) == null);
    try std.testing.expect(findGameByOrdinal(weekend, 0) == null);
    try std.testing.expect(findGameByMatchupN(weekend, "ver", "nor", 1) == null);
    const router = @import("router.zig");
    try std.testing.expect(router.parse("/f1/2025-09-07/event-3").date_event.n == 3);
}

test "ordinal reaches a PGA field and a name-only tennis duel" {
    // PGA: one tournament game with a 95-athlete abbreviation-less field
    // (probe shape); the game itself is event-1, unreachable by any pair.
    var field_storage: [95]core.domain.Participant = undefined;
    for (&field_storage, 0..) |*slot, i| slot.* = .{
        .id = "p",
        .name = "Golfer",
        .abbreviation = "",
        .score = "E",
        .winner = i == 0,
    };
    const pga: core.domain.Scoreboard = .{
        .league = "pga",
        .league_name = "PGA Tour",
        .date = "2026-09-09",
        .source = "test",
        .games = &.{
            .{
                .id = "tournament-1",
                .name = "Tour Championship",
                .starts_at = "2026-09-09T12:00Z",
                .state = "in",
                .status = "Round 3",
                .participants = &field_storage,
            },
        },
    };
    try std.testing.expectEqualStrings("tournament-1", findGameByOrdinal(pga, 1).?.id);
    try std.testing.expect(findGameByOrdinal(pga, 2) == null);
    try std.testing.expect(findGameByMatchupN(pga, "a", "b", 1) == null);
    try std.testing.expect(boardHasNonDuels(pga));
    // Tennis: a two-athlete duel with empty abbreviations. No abbr pair
    // can match (surname slugs rejected: diacritics, shared surnames,
    // hyphenation), but the ordinal reaches it like any other game.
    const tennis: core.domain.Scoreboard = .{
        .league = "atp",
        .league_name = "ATP",
        .date = "2026-09-09",
        .source = "test",
        .games = &.{
            .{
                .id = "tennis-1",
                .name = "Jannik Sinner vs. Carlos Alcaraz",
                .starts_at = "2026-09-09T14:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Jannik Sinner", .abbreviation = "", .score = "2", .winner = true },
                    .{ .id = "b", .name = "Carlos Alcaraz", .abbreviation = "", .score = "1", .winner = false },
                },
            },
        },
    };
    try std.testing.expectEqualStrings("tennis-1", findGameByOrdinal(tennis, 1).?.id);
    try std.testing.expect(findGameByMatchupN(tennis, "sin", "alc", 1) == null);
    try std.testing.expect(boardHasNonDuels(tennis));
    const router = @import("router.zig");
    try std.testing.expect(router.parse("/atp/2026-09-09/event").date_event.n == 1);
    try std.testing.expect(router.parse("/pga/2026-09-09/event-1").date_event.n == 1);
}

test "ordinal counts every game on a mixed board, duels keep pairs" {
    // Duels and non-duels interleaved: the ordinal counts ALL games in
    // board order while the duel form keeps working (doubleheader -N too).
    const mixed: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-09",
        .source = "test",
        .games = &.{
            .{
                .id = "d1",
                .name = "",
                .starts_at = "2026-09-09T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Minnesota Twins", .abbreviation = "MIN", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Detroit Tigers", .abbreviation = "DET", .score = "5", .winner = true },
                },
            },
            .{
                .id = "race-1",
                .name = "Pirelli Italian Grand Prix",
                .starts_at = "2026-09-09T18:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Max Verstappen", .abbreviation = "", .score = "#1", .winner = true },
                    .{ .id = "b", .name = "Lando Norris", .abbreviation = "", .score = "#2", .winner = false },
                },
            },
            .{
                .id = "d2",
                .name = "",
                .starts_at = "2026-09-09T20:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "a", .name = "Minnesota Twins", .abbreviation = "MIN", .score = "", .winner = false },
                    .{ .id = "h", .name = "Detroit Tigers", .abbreviation = "DET", .score = "", .winner = true },
                },
            },
        },
    };
    try std.testing.expectEqualStrings("d1", findGameByOrdinal(mixed, 1).?.id);
    try std.testing.expectEqualStrings("race-1", findGameByOrdinal(mixed, 2).?.id);
    try std.testing.expectEqualStrings("d2", findGameByOrdinal(mixed, 3).?.id);
    try std.testing.expect(findGameByOrdinal(mixed, 4) == null);
    // Duel lookups are untouched, doubleheader numbering included.
    try std.testing.expectEqualStrings("d1", findGameByMatchupN(mixed, "min", "det", 1).?.id);
    try std.testing.expectEqualStrings("d2", findGameByMatchupN(mixed, "min", "det", 2).?.id);
    try std.testing.expect(findGameByMatchupN(mixed, "min", "det", 3) == null);
}

test "ordinal survives renames and shared-name collisions" {
    // Sponsor rename: the same race boards first as "Pirelli Italian
    // Grand Prix", then as "Italian Grand Prix". A name slug would rot
    // or need remapping; the ordinal resolves the same game id either way.
    const before: core.domain.Scoreboard = .{
        .league = "f1",
        .league_name = "F1",
        .date = "2025-09-07",
        .source = "test",
        .games = &.{
            .{
                .id = "401737814",
                .name = "Pirelli Italian Grand Prix",
                .starts_at = "2025-09-07T13:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Max Verstappen", .abbreviation = "", .score = "#1", .winner = true },
                },
            },
        },
    };
    const after: core.domain.Scoreboard = .{
        .league = "f1",
        .league_name = "F1",
        .date = "2025-09-07",
        .source = "test",
        .games = &.{
            .{
                .id = "401737814",
                .name = "Italian Grand Prix",
                .starts_at = "2025-09-07T13:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Max Verstappen", .abbreviation = "", .score = "#1", .winner = true },
                },
            },
        },
    };
    try std.testing.expectEqualStrings("401737814", findGameByOrdinal(before, 1).?.id);
    try std.testing.expectEqualStrings("401737814", findGameByOrdinal(after, 1).?.id);
    // Shared-name collision: two bouts, one card name. The ordinal picks
    // each deterministically; a slug could only ever name one of them.
    const card = ufcCardBoard();
    try std.testing.expectEqualStrings("bout-01", findGameByOrdinal(card, 1).?.id);
    try std.testing.expectEqualStrings("bout-02", findGameByOrdinal(card, 2).?.id);
    try std.testing.expect(!std.mem.eql(u8, findGameByOrdinal(card, 1).?.id, findGameByOrdinal(card, 2).?.id));
}

const week_alias_fixture =
    \\{"season":{"year":2026},"events":[{"id":"401","name":"NE at SEA","date":"2026-09-07T17:00Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"competitors":[{"homeAway":"away","score":"20","winner":true,"team":{"id":"a","displayName":"Patriots","abbreviation":"NE"}},{"homeAway":"home","score":"17","winner":false,"team":{"id":"h","displayName":"Seahawks","abbreviation":"SEA"}}]}]}]}
;

fn weekAliasAdapter(fake: *FakeTransportState, io: std.Io) EspnAdapter {
    return .{
        .allocator = std.testing.allocator,
        .io = io,
        .base_url = "https://example.test/base",
        .transport = fake.asTransport(),
        .clock = fakeClock,
    };
}

test "fetchWeek null day omits dates, non-null preserves behavior" {
    var fake = FakeTransportState{ .body = "{\"events\":[]}" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const adapter = weekAliasAdapter(&fake, threaded.io());
    const nfl = core.leagues.find("nfl").?;
    _ = try adapter.fetchWeek(arena, nfl, null, 1, null);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?week=1",
        fake.seen_url.?,
    );
    // Football + week drops dates (see fetchWeek): the old dates+week
    // shape emptied the slate, the week alone resolves it.
    _ = try adapter.fetchWeek(arena, nfl, "2026-09-06", 2, null);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?week=2",
        fake.seen_url.?,
    );
}

test "fetchWeekBoard reports the week slate with its season year" {
    var fake = FakeTransportState{ .body = week_alias_fixture };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const adapter = weekAliasAdapter(&fake, threaded.io());
    const result = try adapter.fetchWeekBoard(arena, core.leagues.find("nfl").?, "2026", 1);
    // No dates param: ESPN resolves the week alone.
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?week=1",
        fake.seen_url.?,
    );
    try std.testing.expect(result.season_year.? == 2026);
    // Normalization day is the season placeholder (only the id is used).
    try std.testing.expectEqualStrings("2026-01-01", result.board.date);
    try std.testing.expectEqualStrings("401", findGameByMatchup(result.board, "ne", "sea").?.id);
    try std.testing.expectEqualStrings("401", findGameByMatchup(result.board, "sea", "ne").?.id);
    try std.testing.expect(findGameByMatchup(result.board, "kc", "buf") == null);
}

test "season year tolerates string years and absence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect((try parseSeasonYear(arena, "{\"season\":{\"year\":2026}}")).? == 2026);
    try std.testing.expect((try parseSeasonYear(arena, "{\"season\":{\"year\":\"2026\"}}")).? == 2026);
    try std.testing.expect((try parseSeasonYear(arena, "{\"events\":[]}")) == null);
    try std.testing.expect((try parseSeasonYear(arena, "{\"season\":{}}")) == null);
    try std.testing.expect((try parseSeasonYear(arena, "{\"season\":{\"year\":null}}")) == null);
    try std.testing.expect((try parseSeasonYear(arena, "{\"season\":{\"year\":\"soon\"}}")) == null);
}

/// Postseason week shape (live `?seasontype=3&week=1` 2026-09-10: season
/// type 3, TBD pairings, pre state): normalizes to scheduled games with
/// their states mapped through, and the season year still parses.
const playoff_week_fixture =
    \\{"season":{"type":3,"year":2026},"week":{"number":1},"events":[{"id":"401872910","name":"TBD at TBD","date":"2027-01-16T05:00Z","status":{"type":{"state":"pre","shortDetail":"TBD"}},"competitions":[{"competitors":[{"homeAway":"away","score":"","team":{"id":"1","displayName":"TBD","abbreviation":"TBD"}},{"homeAway":"home","score":"","team":{"id":"2","displayName":"TBD","abbreviation":"TBD"}}]}]},{"id":"401872911","name":"TBD at TBD","date":"2027-01-16T05:00Z","status":{"type":{"state":"pre","shortDetail":"TBD"}},"competitions":[{"competitors":[{"homeAway":"away","score":"","team":{"id":"3","displayName":"TBD","abbreviation":"TBD"}},{"homeAway":"home","score":"","team":{"id":"4","displayName":"TBD","abbreviation":"TBD"}}]}]}]}
;

test "postseason week slate normalizes with states mapped" {
    var fake = FakeTransportState{ .body = playoff_week_fixture };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const adapter = weekAliasAdapter(&fake, threaded.io());
    const nfl = core.leagues.find("nfl").?;
    const board = try adapter.fetchWeek(arena, nfl, "2026-09-06", 1, 3);
    try std.testing.expectEqualStrings(
        "https://example.test/base/sports/football/nfl/scoreboard?week=1&seasontype=3",
        fake.seen_url.?,
    );
    try std.testing.expectEqual(@as(usize, 2), board.games.len);
    for (board.games) |game| {
        try std.testing.expectEqualStrings("pre", game.state);
        try std.testing.expectEqualStrings("TBD", game.status);
    }
    try std.testing.expectEqualStrings("401872910", board.games[0].id);
    try std.testing.expect((try parseSeasonYear(arena, playoff_week_fixture)).? == 2026);
}

// Offseason date shape (live `?dates=20260601` 2026-09-10: empty events,
// null season/week): a clean empty board, NOT an error. An empty board
// serves 200 `No games scheduled.` while a transport failure serves 502,
// so no-games (offseason) stays distinguishable from outage by status.
test "empty offseason slate is an empty board, outage stays an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const nfl = core.leagues.find("nfl").?;
    // Null season/week envelope, zero events: parses to zero games.
    var calm = FakeTransportState{ .body = "{\"events\":[]}" };
    const quiet = weekAliasAdapter(&calm, threaded.io());
    const board = try quiet.fetch(arena, nfl, "2026-06-01");
    try std.testing.expectEqual(@as(usize, 0), board.games.len);
    try std.testing.expectEqualStrings("nfl", board.league);
    try std.testing.expect((try parseSeasonYear(arena, "{\"events\":[]}")) == null);
    // Same address, upstream failure: the outage error (serve layer 502),
    // never an empty board.
    var down = FakeTransportState{ .body = "{\"events\":[]}", .status = .bad_gateway };
    const failing = weekAliasAdapter(&down, threaded.io());
    try std.testing.expectError(error.UpstreamResponse, failing.fetch(arena, nfl, "2026-06-01"));
}

test "past-date game alias parses and resolves to the canonical game" {
    // End-to-end shape of the serve path (`main.serveConnection` date_alias
    // arm, `worker.serveDateAlias`): the pretty URL parses, the past day
    // passes through verbatim, and the matchup lookup lands on the board
    // fetched for that day. The router import stays function-local: the
    // production edge is serve-only, and both serve modules' own tests do
    // not execute under `zig build test`, so this pins the coupling here.
    const router = @import("router.zig");
    const route = router.parse("/mlb/2025-09-10/min-det");
    try std.testing.expect(route == .date_alias);
    const alias = route.date_alias;
    try std.testing.expectEqualStrings("mlb", alias.league);
    try std.testing.expectEqualStrings("2025-09-10", alias.date);
    try std.testing.expectEqualStrings("min", alias.away);
    try std.testing.expectEqualStrings("det", alias.home);
    try std.testing.expect(alias.n == null);
    // The past-day board the fetch returns: same duel shape as a today
    // board, only the date is last season.
    const board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2025-09-10",
        .source = "test",
        .games = &.{
            .{
                .id = "401",
                .name = "",
                .starts_at = "2025-09-10T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Minnesota Twins", .abbreviation = "MIN", .score = "2", .winner = false, .home_away = "away" },
                    .{ .id = "h", .name = "Detroit Tigers", .abbreviation = "DET", .score = "5", .winner = true, .home_away = "home" },
                },
            },
        },
    };
    try std.testing.expectEqualStrings("2025-09-10", board.date);
    const game = findGameByMatchupN(board, alias.away, alias.home, alias.n orelse 1).?;
    try std.testing.expectEqualStrings("401", game.id);
    // Redirect target the serve path builds from the hit.
    const target = try std.fmt.allocPrint(std.testing.allocator, "/{s}/{s}", .{ alias.league, game.id });
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("/mlb/401", target);
    // Swapped and uppercase spellings land on the same past game, while
    // an unknown pair still misses (404, never a wrong redirect).
    try std.testing.expectEqualStrings("401", findGameByMatchup(board, "det", "min").?.id);
    try std.testing.expectEqualStrings("401", findGameByMatchup(board, "MIN", "DET").?.id);
    try std.testing.expect(findGameByMatchup(board, "nyy", "bos") == null);
}

// ---- Per-sport DATA gaps (appended; existing tests above untouched) ----
//
// Verified live 2026-09-10 (8 requests): NFL board (?week=1) + summary,
// WNBA/EPL/NHL/ATP/F1/UFC boards. PGA unaudited (budget); NBA/NCAAM/NCAAM
// inferred from WNBA (same basketball shape), NCAAF from NFL, WTA/other
// soccer from ATP/EPL. Every fix below rides a payload the fetch already
// makes: zero new upstream requests.

test "board venue reads competition first, circuit fallback, else null" {
    // NFL shape: competition venue wins.
    const with_venue =
        \\{"events":[{"id":"401872656","name":"NE at SEA","date":"2026-09-10T00:20Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"401872656","date":"2026-09-10T00:20Z","venue":{"fullName":"Lumen Field"},"competitors":[{"homeAway":"away","score":"10","team":{"id":"17","displayName":"Patriots","abbreviation":"NE"}},{"homeAway":"home","score":"13","team":{"id":"25","displayName":"Seahawks","abbreviation":"SEA"}}]}]}]}
    ;
    // F1 shape: sessions carry no venue; the event circuit stands in.
    const with_circuit =
        \\{"events":[{"id":"600057443","name":"Spanish Grand Prix","date":"2026-09-11T11:30Z","status":{"type":{"state":"pre","shortDetail":"9/11"}},"circuit":{"fullName":"Madring"},"competitions":[{"id":"401839103","date":"2026-09-11T11:30Z","competitors":[]}]}]}
    ;
    // Neither: absent stays absent.
    const bare =
        \\{"events":[{"id":"9","name":"Away at Home","date":"2026-09-06T17:00Z","competitions":[{"id":"9","date":"2026-09-06T17:00Z","competitors":[{"homeAway":"away","team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"homeAway":"home","team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nfl = try parseAndNormalize(arena, core.leagues.find("nfl").?, "2026-09-09", with_venue);
    try std.testing.expectEqualStrings("Lumen Field", nfl.games[0].venue.?);
    const f1 = try parseAndNormalize(arena, core.leagues.find("f1").?, "2026-09-11", with_circuit);
    try std.testing.expectEqualStrings("Madring", f1.games[0].venue.?);
    try std.testing.expectEqual(@as(usize, 0), f1.games[0].participants.len);
    const plain = try parseAndNormalize(arena, core.leagues.find("mlb").?, "2026-09-06", bare);
    try std.testing.expect(plain.games[0].venue == null);
}

test "board linescores thread quarters, absent stays empty" {
    // NFL post-game quarters ride the board payload itself.
    const final =
        \\{"events":[{"id":"401872656","name":"NE at SEA","date":"2026-09-10T00:20Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"401872656","date":"2026-09-10T00:20Z","competitors":[{"homeAway":"away","score":"10","team":{"id":"17","displayName":"Patriots","abbreviation":"NE"},"linescores":[{"value":0,"displayValue":"0","period":1},{"value":7,"displayValue":"7","period":2}]},{"homeAway":"home","score":"13","team":{"id":"25","displayName":"Seahawks","abbreviation":"SEA"},"linescores":[{"value":0,"displayValue":"0","period":1},{"value":0,"displayValue":"0","period":2}]}]}]}]}
    ;
    // Pre-game: no linescores key at all.
    const pre =
        \\{"events":[{"id":"9","name":"Away at Home","date":"2026-09-06T17:00Z","competitions":[{"id":"9","date":"2026-09-06T17:00Z","competitors":[{"homeAway":"away","team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"homeAway":"home","team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nfl = core.leagues.find("nfl").?;
    const board = try parseAndNormalize(arena, nfl, "2026-09-09", final);
    const away = board.games[0].participants[0];
    try std.testing.expectEqual(@as(usize, 2), away.lines.len);
    try std.testing.expectEqual(@as(i64, 1), away.lines[0].period.?);
    try std.testing.expectEqualStrings("0", away.lines[0].display);
    try std.testing.expectEqualStrings("7", away.lines[1].display);
    const scheduled = try parseAndNormalize(arena, nfl, "2026-09-06", pre);
    try std.testing.expectEqual(@as(usize, 0), scheduled.games[0].participants[0].lines.len);
}

test "tennis set scores thread values with tiebreaks" {
    // Live ATP shape: numeric values, no display text, tiebreaks on
    // the breaker set only.
    const fixture =
        \\{"events":[{"id":"189-2026","name":"US Open","date":"2026-08-24T15:05Z","groupings":[{"grouping":{"displayName":"Men's Singles"},"competitions":[{"id":"184607","date":"2026-08-24T15:05Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"1","order":2,"winner":false,"athlete":{"displayName":"Roberto Carballes Baena"} ,"linescores":[{"value":6,"tiebreak":3,"winner":false},{"value":3,"winner":false}]},{"id":"2","order":1,"winner":true,"athlete":{"displayName":"Jacob Fearnley"},"linescores":[{"value":7,"tiebreak":7,"winner":true},{"value":6,"winner":true}]}]}]}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const board = try parseAndNormalize(arena_state.allocator(), core.leagues.find("atp").?, "2026-08-24", fixture);
    try std.testing.expectEqual(@as(usize, 1), board.games.len);
    const loser = board.games[0].participants[0];
    try std.testing.expectEqualStrings("0", loser.score);
    try std.testing.expectEqualStrings("6(3)", loser.lines[0].display);
    try std.testing.expectEqualStrings("3", loser.lines[1].display);
    const winner = board.games[0].participants[1];
    try std.testing.expectEqualStrings("2", winner.score);
    try std.testing.expectEqualStrings("7(7)", winner.lines[0].display);
}

test "tennis draws board only their day, else nothing" {
    const tournament =
        \\{"events":[{"id":"189-2026","name":"US Open","date":"2026-08-24T15:05Z","status":{"type":{"state":"post","shortDetail":"Final"}},"venue":{"displayName":"New York, USA"},"groupings":[{"grouping":{"displayName":"Men's Singles"},"competitions":[{"id":"184607","date":"2026-08-24T15:05Z","startDate":"2026-08-24T15:05Z","status":{"type":{"state":"post","shortDetail":"Final"}},"venue":{"fullName":"New York, USA"},"broadcasts":[{"names":["ESPN+"]}],"competitors":[{"id":"1","order":2,"winner":false,"athlete":{"displayName":"Roberto Carballes Baena"},"linescores":[{"value":6,"tiebreak":3,"winner":false}]},{"id":"2","order":1,"winner":true,"athlete":{"displayName":"Jacob Fearnley"},"linescores":[{"value":7,"tiebreak":7,"winner":true}]}]},{"id":"184608","date":"2026-08-25T15:05Z","status":{"type":{"state":"pre","shortDetail":"Scheduled"}},"competitors":[{"id":"3","order":1,"athlete":{"displayName":"Scheduled One"}},{"id":"4","order":2,"athlete":{"displayName":"Scheduled Two"}}]}]}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const atp = core.leagues.find("atp").?;
    // Match day: the dated match boards with its draw context.
    const day = try parseAndNormalize(arena, atp, "2026-08-24", tournament);
    try std.testing.expectEqual(@as(usize, 1), day.games.len);
    try std.testing.expectEqualStrings("184607", day.games[0].id);
    try std.testing.expectEqualStrings("US Open", day.games[0].name);
    try std.testing.expectEqualStrings("New York, USA", day.games[0].venue.?);
    try std.testing.expectEqualStrings("ESPN+", day.games[0].network.?);
    try std.testing.expectEqualStrings("Roberto Carballes Baena", day.games[0].participants[0].name);
    // Next day: only the scheduled match; unplayed sets score blank.
    const next = try parseAndNormalize(arena, atp, "2026-08-25", tournament);
    try std.testing.expectEqual(@as(usize, 1), next.games.len);
    try std.testing.expectEqualStrings("184608", next.games[0].id);
    try std.testing.expectEqualStrings("", next.games[0].participants[0].score);
    try std.testing.expectEqual(@as(usize, 0), next.games[0].participants[0].lines.len);
    // Off days (and the dateless lookup placeholder) board nothing.
    const off = try parseAndNormalize(arena, atp, "2026-09-10", tournament);
    try std.testing.expectEqual(@as(usize, 0), off.games.len);
    const dateless = try parseAndNormalize(arena, atp, "0000-00-00", tournament);
    try std.testing.expectEqual(@as(usize, 0), dateless.games.len);
}

test "fetchDetail resolves tennis matches listed under groupings" {
    // Live ATP shape: the board event carries no event-level
    // competitions (the key is absent), the draw lives under
    // `groupings`, and both board and summary competitors are athletes
    // with numeric set values plus tiebreaks (no display text).
    const board =
        \\{"events":[{"id":"189-2026","name":"US Open","date":"2026-08-24T15:05Z","status":{"type":{"state":"post","shortDetail":"Final"}},"groupings":[{"grouping":{"displayName":"Men's Singles"},"competitions":[{"id":"184607","date":"2026-08-24T15:05Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"1","order":2,"winner":false,"athlete":{"displayName":"Roberto Carballes Baena"},"linescores":[{"value":6,"tiebreak":3,"winner":false},{"value":3,"winner":false}]},{"id":"2","order":1,"winner":true,"athlete":{"displayName":"Jacob Fearnley"},"linescores":[{"value":7,"tiebreak":7,"winner":true},{"value":6,"winner":true}]}]}]}]}]}
    ;
    const summary =
        \\{"header":{"competitions":[{"id":"184607","date":"2026-08-24T15:05Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"1","homeAway":"away","winner":false,"score":0,"linescores":[{"value":6,"tiebreak":3},{"value":3}]},{"id":"2","homeAway":"home","winner":true,"score":2,"linescores":[{"value":7,"tiebreak":7},{"value":6}]}]}]}}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("atp").?, "184607");
    try std.testing.expectEqual(@as(usize, 1), fake.summary_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.board_calls);
    try std.testing.expectEqualStrings("184607", detail.id);
    try std.testing.expectEqualStrings("atp", detail.league);
    try std.testing.expectEqualStrings("2026-08-24", detail.date);
    try std.testing.expectEqualStrings("post", detail.state);
    try std.testing.expectEqualStrings("Final", detail.status);
    try std.testing.expectEqual(@as(usize, 2), detail.participants.len);
    // Athlete identities carry no abbreviation; sets won score the row.
    try std.testing.expectEqualStrings("Roberto Carballes Baena", detail.participants[0].name);
    try std.testing.expectEqualStrings("", detail.participants[0].abbreviation);
    try std.testing.expectEqualStrings("0", detail.participants[0].score);
    try std.testing.expectEqualStrings("Jacob Fearnley", detail.participants[1].name);
    try std.testing.expectEqualStrings("", detail.participants[1].abbreviation);
    try std.testing.expectEqualStrings("2", detail.participants[1].score);
    try std.testing.expect(detail.participants[1].winner);
    // Set linescores render with tiebreaks, never "-" per set.
    try std.testing.expectEqual(@as(usize, 2), detail.participants[0].lines.len);
    try std.testing.expectEqualStrings("6(3)", detail.participants[0].lines[0].display);
    try std.testing.expectEqualStrings("3", detail.participants[0].lines[1].display);
    try std.testing.expectEqual(@as(usize, 2), detail.participants[1].lines.len);
    try std.testing.expectEqualStrings("7(7)", detail.participants[1].lines[0].display);
    try std.testing.expectEqualStrings("6", detail.participants[1].lines[1].display);
}

test "board leaders map the combined table, absent stays empty" {
    // Live NFL post-game shape: combined categories, team refs ignored.
    const with_leaders =
        \\{"events":[{"id":"401872656","name":"NE at SEA","date":"2026-09-10T00:20Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"401872656","date":"2026-09-10T00:20Z","leaders":[{"name":"passingYards","displayName":"Passing Leader","leaders":[{"displayValue":"16/22, 187 YDS, 1 TD","value":187,"athlete":{"displayName":"Drew Lock"}}]},{"name":"tackles","displayName":"Tackles","leaders":[{"displayValue":9,"value":9,"athlete":{"displayName":"Jordyn Brooks"}}]}],"competitors":[{"homeAway":"away","score":"10","team":{"id":"17","displayName":"Patriots","abbreviation":"NE"}},{"homeAway":"home","score":"13","team":{"id":"25","displayName":"Seahawks","abbreviation":"SEA"}}]}]}]}
    ;
    // Null table (every pre-game board): empty, never an error.
    const without =
        \\{"events":[{"id":"9","name":"Away at Home","date":"2026-09-06T17:00Z","competitions":[{"id":"9","date":"2026-09-06T17:00Z","leaders":null,"competitors":[{"homeAway":"away","team":{"id":"a","displayName":"Away","abbreviation":"AWY"}},{"homeAway":"home","team":{"id":"h","displayName":"Home","abbreviation":"HME"}}]}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nfl = core.leagues.find("nfl").?;
    const board = try parseAndNormalize(arena, nfl, "2026-09-09", with_leaders);
    try std.testing.expectEqual(@as(usize, 2), board.games[0].leaders.len);
    try std.testing.expectEqualStrings("Drew Lock 16/22, 187 YDS, 1 TD", board.games[0].leaders[0]);
    // Bare numbers take their category label (the detail soccer rule).
    try std.testing.expectEqualStrings("Jordyn Brooks Tackles 9", board.games[0].leaders[1]);
    const bare = try parseAndNormalize(arena, nfl, "2026-09-06", without);
    try std.testing.expectEqual(@as(usize, 0), bare.games[0].leaders.len);
}

test "soccer form threads, absent stays null" {
    // Live EPL shape: per-competitor recent-results string.
    const with_form =
        \\{"events":[{"id":"401879285","name":"BRE at BOU","date":"2026-09-12T14:00Z","competitions":[{"id":"401879285","date":"2026-09-12T14:00Z","competitors":[{"homeAway":"away","score":"0","team":{"id":"1","displayName":"Brentford","abbreviation":"BRE"},"form":"WDDLD"},{"homeAway":"home","score":"0","team":{"id":"2","displayName":"Bournemouth","abbreviation":"BOU"}}]}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const board = try parseAndNormalize(arena_state.allocator(), core.leagues.find("epl").?, "2026-09-12", with_form);
    try std.testing.expectEqualStrings("WDDLD", board.games[0].participants[0].form.?);
    try std.testing.expect(board.games[0].participants[1].form == null);
}

test "detail injuries thread statuses, absent stays empty" {
    const summary =
        \\{"header":{"competitions":[{"id":"401872656","date":"2026-09-10T00:20Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"17","homeAway":"away","winner":false,"score":10,"team":{"id":"17","displayName":"New England Patriots","abbreviation":"NE"}},{"id":"26","homeAway":"home","winner":true,"score":13,"team":{"id":"26","displayName":"Seattle Seahawks","abbreviation":"SEA"}}]}]},"injuries":[{"team":{"id":"26","abbreviation":"SEA"},"injuries":[{"status":"Doubtful","athlete":{"displayName":"Sam Darnold"},"details":{"type":"Hip"}},{"status":"Out","athlete":{"displayName":"No Detail Man"}}]},{"team":{"id":"17","abbreviation":"NE"},"injuries":[]}]}
    ;
    const board =
        \\{"events":[{"id":"401872656","name":"NE at SEA","date":"2026-09-10T00:20Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"401872656","date":"2026-09-10T00:20Z","competitors":[{"homeAway":"away","score":"10","team":{"id":"17","displayName":"New England Patriots","abbreviation":"NE"}},{"homeAway":"home","score":"13","team":{"id":"26","displayName":"Seattle Seahawks","abbreviation":"SEA"}}]}]}]}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const detail = try detailAdapter(&fake).fetchDetail(arena_state.allocator(), core.leagues.find("nfl").?, "401872656");
    try std.testing.expectEqual(@as(usize, 2), detail.injuries.len);
    try std.testing.expectEqualStrings("SEA Sam Darnold Doubtful (Hip)", detail.injuries[0]);
    try std.testing.expectEqualStrings("SEA No Detail Man Out", detail.injuries[1]);

    // No report key at all: empty list, never an error.
    var bare_fake = DetailFake{ .summary_body = detail_summary_minimal, .board_body = detail_board_minimal };
    const bare = try detailAdapter(&bare_fake).fetchDetail(arena_state.allocator(), core.leagues.find("mlb").?, "7");
    try std.testing.expectEqual(@as(usize, 0), bare.injuries.len);
}

test "detail win probability reads the last sample, absent stays null" {
    const summary =
        \\{"header":{"competitions":[{"id":"401872656","date":"2026-09-10T00:20Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"17","homeAway":"away","winner":false,"score":10,"team":{"id":"17","displayName":"New England Patriots","abbreviation":"NE"}},{"id":"26","homeAway":"home","winner":true,"score":13,"team":{"id":"26","displayName":"Seattle Seahawks","abbreviation":"SEA"}}]}]},"winprobability":[{"homeWinPercentage":0.6127},{"homeWinPercentage":1.0}]}
    ;
    const board =
        \\{"events":[{"id":"401872656","name":"NE at SEA","date":"2026-09-10T00:20Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"id":"401872656","date":"2026-09-10T00:20Z","competitors":[{"homeAway":"away","score":"10","team":{"id":"17","displayName":"New England Patriots","abbreviation":"NE"}},{"homeAway":"home","score":"13","team":{"id":"26","displayName":"Seattle Seahawks","abbreviation":"SEA"}}]}]}]}
    ;
    var fake = DetailFake{ .summary_body = summary, .board_body = board };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const detail = try detailAdapter(&fake).fetchDetail(arena, core.leagues.find("nfl").?, "401872656");
    try std.testing.expectEqualStrings("SEA 100.0%", detail.win_probability.?);

    // Empty samples and missing keys both stay null (never a zero).
    const empty_summary =
        \\{"header":{"competitions":[{"id":"401872656","date":"2026-09-10T00:20Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitors":[{"id":"17","homeAway":"away","winner":false,"score":10,"team":{"id":"17","displayName":"New England Patriots","abbreviation":"NE"}},{"id":"26","homeAway":"home","winner":true,"score":13,"team":{"id":"26","displayName":"Seattle Seahawks","abbreviation":"SEA"}}]}]},"winprobability":[]}
    ;
    var empty_fake = DetailFake{ .summary_body = empty_summary, .board_body = board };
    const empty = try detailAdapter(&empty_fake).fetchDetail(arena, core.leagues.find("nfl").?, "401872656");
    try std.testing.expect(empty.win_probability == null);
    var bare_fake = DetailFake{ .summary_body = detail_summary_minimal, .board_body = detail_board_minimal };
    const bare = try detailAdapter(&bare_fake).fetchDetail(arena, core.leagues.find("mlb").?, "7");
    try std.testing.expect(bare.win_probability == null);
}
