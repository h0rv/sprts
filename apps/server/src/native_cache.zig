//! In-process TTL cache for the native server path.
//!
//! Mirrors the `edge_cache` scheme instead of inventing a second one:
//!
//! - Namespaces use the same components: board `(slug, day)`, detail
//!   `(slug, id)`, team `(slug, abbr)`, standings `(slug)` (no date: the
//!   endpoint is the current table only). Slugs/abbrevs must arrive
//!   pre-canonicalized (lowercase via `edge_cache.canonicalSlug` /
//!   `canonicalAbbr`); canonicalization stays in the serve layer exactly
//!   like the worker's `serveBoard`/`serveTeam`.
//! - Fresh windows serve directly (board/detail 30s, team 60s); a stale
//!   entry (board/detail 300s, team 600s) is served only when the upstream
//!   fetch fails, else the error propagates (the native 502). The TTL
//!   constants are reused from `edge_cache`, not redeclared.
//! - Only successful fetches are ever stored; errors (including
//!   `GameNotFound`/`TeamNotFound`/`UnsupportedLeague`, which bypass even
//!   the stale path) are never cached.
//!
//! One deliberate difference from the edge: the native cache stores the
//! NORMALIZED payload (`Scoreboard`/`GameDetail`/`TeamView`), not the
//! render. Render flags (`color`/`width`/`height`/`quiet`/`oneline`) stay
//! out of the key and are applied at render time, so flag variants can
//! never poison each other. A corollary is that the render format is not
//! part of the data key either: one normalized fetch serves text, html,
//! and json alike (the same single-fetch principle the edge applies per
//! request, extended across requests).
//!
//! Thread safety: every method locks a mutex, so the cache is safe to
//! share across the threaded accept loop in `main.zig`. The lock is never
//! held across an upstream fetch (`getOrFetch` looks up, unlocks,
//! fetches, then re-locks to store), so slow upstreams never serialize
//! requests. Fetch callbacks must not call back into the cache (the
//! mutex is not recursive).
//!
//! Eviction: entries are bounded by `capacity` (default 256). On insert
//! at capacity, expired entries (past their stale horizon) are reaped
//! first; if still full, the entry whose stale window ends soonest is
//! evicted. Worst-case memory is capacity times the largest payload.

const std = @import("std");
const core = @import("sprts_core");
const edge = @import("edge_cache.zig");

const domain = core.domain;

pub const ClockFn = *const fn (io: std.Io) i64;

pub fn realClock(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

pub const Kind = enum { board, detail, team, standings, teams };

fn kindOf(key: Key) Kind {
    return switch (key) {
        .board => .board,
        .detail => .detail,
        .team => .team,
        .standings => .standings,
        .teams => .teams,
    };
}

/// Fresh window, reused from `edge_cache`: board/detail share the 30s
/// board window; team renders track the 60s schedule window. Standings
/// track the schedule window too: tables move at schedule cadence (a game
/// final at a time), not at live-score cadence.
pub fn freshTtl(kind: Kind) i64 {
    return switch (kind) {
        .board, .detail => edge.fresh_ttl_s,
        .team, .standings, .teams => edge.schedule_fresh_ttl_s,
    };
}

/// Stale window, reused from `edge_cache`: 300s board/detail, 600s team.
/// Standings reuse the 600s schedule window: a stale table still renders
/// usefully (positions barely move in 10 minutes).
pub fn staleTtl(kind: Kind) i64 {
    return switch (kind) {
        .board, .detail => edge.stale_ttl_s,
        .team, .standings, .teams => edge.schedule_stale_ttl_s,
    };
}

/// Cache key. Components mirror the `edge_cache` namespaces; see the
/// module docs for why the render format is not part of the data key.
pub const Key = union(enum) {
    board: struct { slug: []const u8, day: []const u8 },
    detail: struct { slug: []const u8, id: []const u8 },
    team: struct { slug: []const u8, abbr: []const u8 },
    standings: struct { slug: []const u8 },
    teams: struct { slug: []const u8 },
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(@tagName(std.meta.activeTag(key)));
        switch (key) {
            .board => |b| {
                h.update(b.slug);
                h.update(b.day);
            },
            .detail => |d| {
                h.update(d.slug);
                h.update(d.id);
            },
            .team => |t| {
                h.update(t.slug);
                h.update(t.abbr);
            },
            .standings => |s| {
                h.update(s.slug);
            },
            .teams => |t| {
                h.update(t.slug);
            },
        }
        return h.final();
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .board => |x| std.mem.eql(u8, x.slug, b.board.slug) and std.mem.eql(u8, x.day, b.board.day),
            .detail => |x| std.mem.eql(u8, x.slug, b.detail.slug) and std.mem.eql(u8, x.id, b.detail.id),
            .team => |x| std.mem.eql(u8, x.slug, b.team.slug) and std.mem.eql(u8, x.abbr, b.team.abbr),
            .standings => |x| std.mem.eql(u8, x.slug, b.standings.slug),
            .teams => |x| std.mem.eql(u8, x.slug, b.teams.slug),
        };
    }
};

/// Normalized payload stored per entry. Format-neutral by construction.
pub const Data = union(enum) {
    board: domain.Scoreboard,
    detail: core.detail.GameDetail,
    team: core.schedule.TeamView,
    standings: core.standings.LeagueStandings,
    teams: core.schedule.TeamList,
};

pub const Outcome = enum { hit, miss, stale };

pub const Cached = struct {
    data: Data,
    outcome: Outcome,
};

/// Upstream fetch seam. Returns a normalized payload borrowing `arena`;
/// `getOrFetch` clones successes into cache-owned memory.
pub const FetchFn = *const fn (ctx: *anyopaque, arena: std.mem.Allocator) anyerror!Data;

fn dupeOpt(a: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    const s = value orelse return null;
    return try a.dupe(u8, s);
}

/// Deep copy into `a`; the result borrows nothing from the source.
pub fn cloneScoreboard(a: std.mem.Allocator, board: domain.Scoreboard) !domain.Scoreboard {
    const games = try a.alloc(domain.Game, board.games.len);
    for (board.games, 0..) |game, i| {
        const participants = try a.alloc(domain.Participant, game.participants.len);
        for (game.participants, 0..) |p, j| {
            participants[j] = .{
                .id = try a.dupe(u8, p.id),
                .name = try a.dupe(u8, p.name),
                .abbreviation = try a.dupe(u8, p.abbreviation),
                .score = try a.dupe(u8, p.score),
                .winner = p.winner,
                .home_away = try dupeOpt(a, p.home_away),
                .record = try dupeOpt(a, p.record),
            };
        }
        games[i] = .{
            .id = try a.dupe(u8, game.id),
            .name = try a.dupe(u8, game.name),
            .starts_at = try a.dupe(u8, game.starts_at),
            .state = try a.dupe(u8, game.state),
            .status = try a.dupe(u8, game.status),
            .participants = participants,
            .network = try dupeOpt(a, game.network),
        };
    }
    return .{
        .schema_version = try a.dupe(u8, board.schema_version),
        .league = try a.dupe(u8, board.league),
        .league_name = try a.dupe(u8, board.league_name),
        .date = try a.dupe(u8, board.date),
        .source = try a.dupe(u8, board.source),
        .games = games,
    };
}

pub fn cloneGameDetail(a: std.mem.Allocator, detail: core.detail.GameDetail) !core.detail.GameDetail {
    const participants = try a.alloc(core.detail.DetailParticipant, detail.participants.len);
    for (detail.participants, 0..) |p, i| {
        const lines = try a.alloc(core.detail.LineScore, p.lines.len);
        for (p.lines, 0..) |line, j| {
            lines[j] = .{ .period = line.period, .display = try a.dupe(u8, line.display) };
        }
        participants[i] = .{
            .id = try a.dupe(u8, p.id),
            .name = try a.dupe(u8, p.name),
            .abbreviation = try a.dupe(u8, p.abbreviation),
            .score = try a.dupe(u8, p.score),
            .winner = p.winner,
            .home_away = try dupeOpt(a, p.home_away),
            .lines = lines,
            .hits = try dupeOpt(a, p.hits),
            .errors = try dupeOpt(a, p.errors),
            .record = try dupeOpt(a, p.record),
            .probable = try dupeOpt(a, p.probable),
        };
    }
    const situation: ?core.detail.Situation = if (detail.situation) |s| blk: {
        const runners = try a.alloc([]const u8, s.runners.len);
        for (s.runners, 0..) |runner, i| runners[i] = try a.dupe(u8, runner);
        break :blk .{
            .balls = s.balls,
            .strikes = s.strikes,
            .outs = s.outs,
            .runners = runners,
            .batter = try dupeOpt(a, s.batter),
            .pitcher = try dupeOpt(a, s.pitcher),
            .last_play = try dupeOpt(a, s.last_play),
        };
    } else null;
    const decisions = try a.alloc(core.detail.Decision, detail.decisions.len);
    for (detail.decisions, 0..) |d, i| {
        decisions[i] = .{ .outcome = try a.dupe(u8, d.outcome), .name = try a.dupe(u8, d.name) };
    }
    const scoring_plays = try a.alloc(core.detail.ScoringPlay, detail.scoring_plays.len);
    for (detail.scoring_plays, 0..) |play, i| {
        scoring_plays[i] = .{
            .period = try a.dupe(u8, play.period),
            .text = try a.dupe(u8, play.text),
            .away_score = try a.dupe(u8, play.away_score),
            .home_score = try a.dupe(u8, play.home_score),
        };
    }
    const leaders = try a.alloc([]const u8, detail.leaders.len);
    for (detail.leaders, 0..) |leader, i| leaders[i] = try a.dupe(u8, leader);
    return .{
        .schema_version = try a.dupe(u8, detail.schema_version),
        .id = try a.dupe(u8, detail.id),
        .league = try a.dupe(u8, detail.league),
        .league_name = try a.dupe(u8, detail.league_name),
        .date = try a.dupe(u8, detail.date),
        .state = try a.dupe(u8, detail.state),
        .status = try a.dupe(u8, detail.status),
        .venue = try dupeOpt(a, detail.venue),
        .attendance = detail.attendance,
        .series = try dupeOpt(a, detail.series),
        .network = try dupeOpt(a, detail.network),
        .participants = participants,
        .situation = situation,
        .decisions = decisions,
        .scoring_plays = scoring_plays,
        .leaders = leaders,
    };
}

fn cloneGameRef(a: std.mem.Allocator, ref: core.schedule.GameRef) !core.schedule.GameRef {
    return .{
        .id = try a.dupe(u8, ref.id),
        .date = try a.dupe(u8, ref.date),
        .opponent_abbrev = try a.dupe(u8, ref.opponent_abbrev),
        .opponent_name = try a.dupe(u8, ref.opponent_name),
        .home_away = try a.dupe(u8, ref.home_away),
        .status = try a.dupe(u8, ref.status),
        .state = try a.dupe(u8, ref.state),
        .our_score = try a.dupe(u8, ref.our_score),
        .opp_score = try a.dupe(u8, ref.opp_score),
        .result = try a.dupe(u8, ref.result),
        .probable = try a.dupe(u8, ref.probable),
    };
}

fn cloneGameRefOpt(a: std.mem.Allocator, ref: ?core.schedule.GameRef) !?core.schedule.GameRef {
    const r = ref orelse return null;
    return try cloneGameRef(a, r);
}

pub fn cloneTeamView(a: std.mem.Allocator, view: core.schedule.TeamView) !core.schedule.TeamView {
    const next = try a.alloc(core.schedule.GameRef, view.next.len);
    for (view.next, 0..) |ref, i| next[i] = try cloneGameRef(a, ref);
    const last = try a.alloc(core.schedule.GameRef, view.last.len);
    for (view.last, 0..) |ref, i| last[i] = try cloneGameRef(a, ref);
    return .{
        .schema_version = try a.dupe(u8, view.schema_version),
        .league = try a.dupe(u8, view.league),
        .league_name = try a.dupe(u8, view.league_name),
        .team = .{
            .id = try a.dupe(u8, view.team.id),
            .abbrev = try a.dupe(u8, view.team.abbrev),
            .name = try a.dupe(u8, view.team.name),
            .record_summary = try dupeOpt(a, view.team.record_summary),
            .standing_summary = try dupeOpt(a, view.team.standing_summary),
        },
        .last = last,
        .next = next,
        .live = try cloneGameRefOpt(a, view.live),
    };
}

pub fn cloneStandings(a: std.mem.Allocator, st: core.standings.LeagueStandings) !core.standings.LeagueStandings {
    const groups = try a.alloc(core.standings.StandingGroup, st.groups.len);
    for (st.groups, 0..) |group, i| {
        const entries = try a.alloc(core.standings.StandingEntry, group.entries.len);
        for (group.entries, 0..) |entry, j| {
            entries[j] = .{
                .team_id = try a.dupe(u8, entry.team_id),
                .abbrev = try a.dupe(u8, entry.abbrev),
                .name = try a.dupe(u8, entry.name),
                .wins = try dupeOpt(a, entry.wins),
                .losses = try dupeOpt(a, entry.losses),
                .ties = try dupeOpt(a, entry.ties),
                .points = try dupeOpt(a, entry.points),
            };
        }
        groups[i] = .{
            .name = try a.dupe(u8, group.name),
            .entries = entries,
        };
    }
    return .{
        .schema_version = try a.dupe(u8, st.schema_version),
        .league = try a.dupe(u8, st.league),
        .league_name = try a.dupe(u8, st.league_name),
        .season = try a.dupe(u8, st.season),
        .groups = groups,
        .source = try a.dupe(u8, st.source),
    };
}

pub fn cloneTeamList(a: std.mem.Allocator, list: core.schedule.TeamList) !core.schedule.TeamList {
    const teams = try a.alloc(core.schedule.TeamListEntry, list.teams.len);
    for (list.teams, 0..) |entry, i| {
        teams[i] = .{
            .id = try a.dupe(u8, entry.id),
            .abbrev = try a.dupe(u8, entry.abbrev),
            .name = try a.dupe(u8, entry.name),
        };
    }
    return .{
        .schema_version = try a.dupe(u8, list.schema_version),
        .league = try a.dupe(u8, list.league),
        .league_name = try a.dupe(u8, list.league_name),
        .teams = teams,
        .source = try a.dupe(u8, list.source),
    };
}

fn cloneData(a: std.mem.Allocator, data: Data) !Data {
    return switch (data) {
        .board => |b| .{ .board = try cloneScoreboard(a, b) },
        .detail => |d| .{ .detail = try cloneGameDetail(a, d) },
        .team => |t| .{ .team = try cloneTeamView(a, t) },
        .standings => |s| .{ .standings = try cloneStandings(a, s) },
        .teams => |t| .{ .teams = try cloneTeamList(a, t) },
    };
}

const Entry = struct {
    /// Owns the key strings and the cloned payload; dropped on eviction.
    store: *std.heap.ArenaAllocator,
    data: Data,
    fresh_until: i64,
    stale_until: i64,
};

pub const NativeCache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    clock: ClockFn,
    mutex: std.Io.Mutex = .init,
    map: std.HashMap(Key, Entry, KeyContext, 80),
    capacity: usize = 256,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, clock: ClockFn) NativeCache {
        return .{
            .allocator = allocator,
            .io = io,
            .clock = clock,
            .map = std.HashMap(Key, Entry, KeyContext, 80).init(allocator),
        };
    }

    pub fn deinit(cache: *NativeCache) void {
        var it = cache.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.store.deinit();
            cache.allocator.destroy(entry.value_ptr.store);
        }
        cache.map.deinit();
    }

    pub fn now(cache: NativeCache) i64 {
        return cache.clock(cache.io);
    }

    /// Fresh hit clones the payload into `arena`, or null on miss/expiry.
    pub fn getFresh(cache: *NativeCache, arena: std.mem.Allocator, key: Key, at: i64) !?Data {
        try cache.mutex.lock(cache.io);
        defer cache.mutex.unlock(cache.io);
        const entry = cache.map.get(key) orelse return null;
        if (at >= entry.fresh_until) return null;
        return try cloneData(arena, entry.data);
    }

    /// Stale hit (upstream-error fallback) clones into `arena`, or null.
    pub fn getStale(cache: *NativeCache, arena: std.mem.Allocator, key: Key, at: i64) !?Data {
        try cache.mutex.lock(cache.io);
        defer cache.mutex.unlock(cache.io);
        const entry = cache.map.get(key) orelse return null;
        if (at >= entry.stale_until) return null;
        return try cloneData(arena, entry.data);
    }

    /// Stores a successful fetch, cloning it into cache-owned memory.
    /// Evicts at capacity (expired first, else soonest-stale). Never fails
    /// a request: callers serve the fetched payload even if storing OOMs.
    pub fn put(cache: *NativeCache, key: Key, data: Data, at: i64) !void {
        const kind = kindOf(key);
        const store = try cache.allocator.create(std.heap.ArenaAllocator);
        errdefer cache.allocator.destroy(store);
        store.* = std.heap.ArenaAllocator.init(cache.allocator);
        errdefer store.deinit();
        const owned_key: Key = switch (key) {
            .board => |b| .{ .board = .{
                .slug = try store.allocator().dupe(u8, b.slug),
                .day = try store.allocator().dupe(u8, b.day),
            } },
            .detail => |d| .{ .detail = .{
                .slug = try store.allocator().dupe(u8, d.slug),
                .id = try store.allocator().dupe(u8, d.id),
            } },
            .team => |t| .{ .team = .{
                .slug = try store.allocator().dupe(u8, t.slug),
                .abbr = try store.allocator().dupe(u8, t.abbr),
            } },
            .standings => |s| .{ .standings = .{
                .slug = try store.allocator().dupe(u8, s.slug),
            } },
            .teams => |t| .{ .teams = .{
                .slug = try store.allocator().dupe(u8, t.slug),
            } },
        };
        const owned_data = try cloneData(store.allocator(), data);
        const entry = Entry{
            .store = store,
            .data = owned_data,
            .fresh_until = at + freshTtl(kind),
            .stale_until = at + staleTtl(kind),
        };

        try cache.mutex.lock(cache.io);
        defer cache.mutex.unlock(cache.io);
        if (cache.map.getEntry(owned_key)) |existing| {
            existing.value_ptr.store.deinit();
            cache.allocator.destroy(existing.value_ptr.store);
            existing.value_ptr.* = entry;
            // Re-key so the map holds the fresh store's slices.
            existing.key_ptr.* = owned_key;
            return;
        }
        while (cache.map.count() >= cache.capacity) {
            const victim = cache.evictVictim(at) orelse break;
            cache.removeLocked(victim);
        }
        try cache.map.put(owned_key, entry);
    }

    pub fn count(cache: *NativeCache) !usize {
        try cache.mutex.lock(cache.io);
        defer cache.mutex.unlock(cache.io);
        return cache.map.count();
    }

    /// Fresh hit returns `.hit`; a successful fetch stores and returns
    /// `.miss`; a failed fetch with a live stale entry returns `.stale`,
    /// else the fetch error propagates. `GameNotFound`/`TeamNotFound`/
    /// `UnsupportedLeague` bypass the stale path (a 404 is authoritative,
    /// never staleable).
    pub fn getOrFetch(
        cache: *NativeCache,
        arena: std.mem.Allocator,
        key: Key,
        at: i64,
        ctx: *anyopaque,
        fetch: FetchFn,
    ) !Cached {
        if (try cache.getFresh(arena, key, at)) |data| return .{ .data = data, .outcome = .hit };
        const data = fetch(ctx, arena) catch |err| {
            if (err == error.GameNotFound or err == error.TeamNotFound or err == error.UnsupportedLeague) return err;
            if (try cache.getStale(arena, key, at)) |stale| return .{ .data = stale, .outcome = .stale };
            return err;
        };
        cache.put(key, data, at) catch |err| {
            std.log.warn("native cache store failed: {t}", .{err});
        };
        return .{ .data = data, .outcome = .miss };
    }

    fn removeLocked(cache: *NativeCache, key: Key) void {
        const removed = cache.map.fetchRemove(key) orelse return;
        removed.value.store.deinit();
        cache.allocator.destroy(removed.value.store);
    }

    /// Victim selection, called with the mutex held: an expired entry
    /// first, else the entry whose stale window ends soonest.
    fn evictVictim(cache: *NativeCache, at: i64) ?Key {
        var victim: ?Key = null;
        var victim_stale: i64 = std.math.maxInt(i64);
        var it = cache.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.stale_until <= at) return entry.key_ptr.*;
            if (entry.value_ptr.stale_until < victim_stale) {
                victim_stale = entry.value_ptr.stale_until;
                victim = entry.key_ptr.*;
            }
        }
        return victim;
    }
};

// --- Tests (FakeTransport-style: no live ESPN; time is an explicit param) ---

const FakeBoard = struct {
    calls: usize = 0,
    fail: bool = false,
    fail_err: anyerror = error.UpstreamResponse,

    fn boardFixture() domain.Scoreboard {
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
                        .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false, .home_away = "away", .record = "69-74" },
                        .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true, .home_away = "home" },
                    },
                },
            },
        };
    }

    fn fetch(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!Data {
        const self: *FakeBoard = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.fail) return self.fail_err;
        return .{ .board = try cloneScoreboard(arena, boardFixture()) };
    }
};

fn testCache() NativeCache {
    return NativeCache.init(std.testing.allocator, test_threaded.io(), fakeClock);
}

var test_threaded: std.Io.Threaded = .init_single_threaded;

fn fakeClock(_: std.Io) i64 {
    return 1788739200; // 2026-09-07T00:00:00Z
}

const board_key: Key = .{ .board = .{ .slug = "mlb", .day = "2026-09-06" } };

test "fresh hit avoids a second upstream fetch" {
    var cache = testCache();
    defer cache.deinit();
    var fake = FakeBoard{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t0: i64 = 1_000_000;

    const first = try cache.getOrFetch(arena, board_key, t0, &fake, FakeBoard.fetch);
    try std.testing.expectEqual(Outcome.miss, first.outcome);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("1", first.data.board.games[0].id);

    const second = try cache.getOrFetch(arena, board_key, t0, &fake, FakeBoard.fetch);
    try std.testing.expectEqual(Outcome.hit, second.outcome);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("HME", second.data.board.games[0].participants[1].abbreviation);
    try std.testing.expectEqualStrings("69-74", second.data.board.games[0].participants[0].record.?);
}

test "stale entry is served when the upstream fails" {
    var cache = testCache();
    defer cache.deinit();
    var fake = FakeBoard{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t0: i64 = 1_000_000;

    _ = try cache.getOrFetch(arena, board_key, t0, &fake, FakeBoard.fetch);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    // Fresh for 30s: still a hit at t0+29 without touching upstream.
    _ = try cache.getOrFetch(arena, board_key, t0 + edge.fresh_ttl_s - 1, &fake, FakeBoard.fetch);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    // Past fresh but inside the 300s stale window: the failed fetch falls
    // back to the stale payload.
    fake.fail = true;
    const stale = try cache.getOrFetch(arena, board_key, t0 + edge.fresh_ttl_s, &fake, FakeBoard.fetch);
    try std.testing.expectEqual(Outcome.stale, stale.outcome);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqualStrings("Final", stale.data.board.games[0].status);

    // Past the stale horizon the error propagates (native 502 upstream).
    try std.testing.expectError(error.UpstreamResponse, cache.getOrFetch(arena, board_key, t0 + edge.stale_ttl_s, &fake, FakeBoard.fetch));
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
}

test "errors are never cached" {
    var cache = testCache();
    defer cache.deinit();
    var fake = FakeBoard{ .fail = true };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.UpstreamResponse, cache.getOrFetch(arena, board_key, 1_000_000, &fake, FakeBoard.fetch));
    try std.testing.expectEqual(@as(usize, 0), try cache.count());
    // A second request retries upstream instead of replaying the error.
    try std.testing.expectError(error.UpstreamResponse, cache.getOrFetch(arena, board_key, 1_000_000, &fake, FakeBoard.fetch));
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), try cache.count());
}

test "not-found errors bypass even a live stale entry" {
    var cache = testCache();
    defer cache.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t0: i64 = 1_000_000;
    const detail_key: Key = .{ .detail = .{ .slug = "mlb", .id = "7" } };

    const DetailFake = struct {
        fn fetch(ctx: *anyopaque, a: std.mem.Allocator) anyerror!Data {
            _ = ctx;
            _ = a;
            return error.GameNotFound;
        }
    };
    var ctx: u8 = 0;
    // Seed a stale-eligible detail entry directly.
    const seeded: Data = .{ .detail = .{
        .id = "7",
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .participants = &.{},
    } };
    try cache.put(detail_key, seeded, t0);
    try std.testing.expectError(
        error.GameNotFound,
        cache.getOrFetch(arena, detail_key, t0 + edge.fresh_ttl_s, &ctx, DetailFake.fetch),
    );
}

test "a timed-out upstream falls back to stale" {
    var cache = testCache();
    defer cache.deinit();
    var fake = FakeBoard{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t0: i64 = 1_000_000;

    _ = try cache.getOrFetch(arena, board_key, t0, &fake, FakeBoard.fetch);
    fake.fail = true;
    fake.fail_err = error.Timeout;
    const stale = try cache.getOrFetch(arena, board_key, t0 + edge.fresh_ttl_s, &fake, FakeBoard.fetch);
    try std.testing.expectEqual(Outcome.stale, stale.outcome);
    try std.testing.expectEqualStrings("mlb", stale.data.board.league);
}

test "team entries use the 60s fresh / 600s stale schedule windows" {
    var cache = testCache();
    defer cache.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t0: i64 = 1_000_000;
    const team_key: Key = .{ .team = .{ .slug = "mlb", .abbr = "phi" } };

    const TeamFake = struct {
        calls: usize = 0,
        fail: bool = false,
        fn fetch(ctx: *anyopaque, a: std.mem.Allocator) anyerror!Data {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.fail) return error.UpstreamResponse;
            const next = try a.alloc(core.schedule.GameRef, 1);
            next[0] = .{
                .id = "2",
                .date = "2026-09-08T17:05Z",
                .opponent_abbrev = "ATL",
                .opponent_name = "Atlanta Braves",
                .home_away = "away",
                .status = "9/8 - 1:05 PM EDT",
                .result = "at ATL 1:05 PM",
            };
            return .{ .team = .{
                .league = "mlb",
                .league_name = "MLB",
                .team = .{ .id = "22", .abbrev = "PHI", .name = "Philadelphia Phillies", .record_summary = "80-63" },
                .next = next,
            } };
        }
    };
    var team_fake = TeamFake{};
    try std.testing.expectEqual(edge.schedule_fresh_ttl_s, freshTtl(.team));
    try std.testing.expectEqual(edge.schedule_stale_ttl_s, staleTtl(.team));

    _ = try cache.getOrFetch(arena, team_key, t0, &team_fake, TeamFake.fetch);
    _ = try cache.getOrFetch(arena, team_key, t0 + edge.schedule_fresh_ttl_s - 1, &team_fake, TeamFake.fetch);
    try std.testing.expectEqual(@as(usize, 1), team_fake.calls);

    team_fake.fail = true;
    const stale = try cache.getOrFetch(arena, team_key, t0 + edge.schedule_fresh_ttl_s, &team_fake, TeamFake.fetch);
    try std.testing.expectEqual(Outcome.stale, stale.outcome);
    try std.testing.expectEqualStrings("PHI", stale.data.team.team.abbrev);
    try std.testing.expectEqualStrings("80-63", stale.data.team.team.record_summary.?);
    // Stale holds to 599s, expires at 600s.
    _ = try cache.getOrFetch(arena, team_key, t0 + edge.schedule_stale_ttl_s - 1, &team_fake, TeamFake.fetch);
    try std.testing.expectError(error.UpstreamResponse, cache.getOrFetch(arena, team_key, t0 + edge.schedule_stale_ttl_s, &team_fake, TeamFake.fetch));
}

test "cached payloads survive the source arena" {
    var cache = testCache();
    defer cache.deinit();
    const t0: i64 = 1_000_000;
    {
        var src = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer src.deinit();
        var fake = FakeBoard{};
        _ = try cache.getOrFetch(src.allocator(), board_key, t0, &fake, FakeBoard.fetch);
    }
    var dst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer dst.deinit();
    const hit = try cache.getFresh(dst.allocator(), board_key, t0);
    try std.testing.expect(hit != null);
    try std.testing.expectEqualStrings("Away at Home", hit.?.board.games[0].name);
    try std.testing.expectEqualStrings("away", hit.?.board.games[0].participants[0].home_away.?);
}

test "keys are case-sensitive: callers canonicalize like the edge" {
    var cache = testCache();
    defer cache.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const upper: Key = .{ .board = .{ .slug = "MLB", .day = "2026-09-06" } };
    try std.testing.expect((try cache.getFresh(arena, upper, 1_000_000)) == null);
    // Same components in different namespaces never collide.
    const team_key: Key = .{ .team = .{ .slug = "mlb", .abbr = "2026-09-06" } };
    try std.testing.expect((try cache.getFresh(arena, team_key, 1_000_000)) == null);
}

test "capacity bounds the map, reaping expired entries first" {
    var cache = testCache();
    defer cache.deinit();
    cache.capacity = 2;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old: Data = .{ .board = FakeBoard.boardFixture() };
    const t0: i64 = 1_000_000;
    const k1: Key = .{ .board = .{ .slug = "mlb", .day = "2026-09-01" } };
    const k2: Key = .{ .board = .{ .slug = "mlb", .day = "2026-09-02" } };
    const k3: Key = .{ .board = .{ .slug = "mlb", .day = "2026-09-03" } };
    try cache.put(k1, old, t0);
    try cache.put(k2, old, t0);
    try std.testing.expectEqual(@as(usize, 2), try cache.count());
    // Both entries are past stale at t0+301: the third insert reaps one.
    try cache.put(k3, old, t0 + edge.stale_ttl_s + 1);
    try std.testing.expectEqual(@as(usize, 2), try cache.count());
    try std.testing.expect((try cache.getFresh(arena, k3, t0 + edge.stale_ttl_s + 1)) != null);
    // Nothing expired: inserting a fourth evicts the soonest-stale entry.
    const k4: Key = .{ .board = .{ .slug = "mlb", .day = "2026-09-04" } };
    try cache.put(k4, old, t0 + edge.stale_ttl_s + 1);
    try std.testing.expectEqual(@as(usize, 2), try cache.count());
    try std.testing.expect((try cache.getFresh(arena, k4, t0 + edge.stale_ttl_s + 1)) != null);
}

test "windows reuse the edge_cache constants" {
    try std.testing.expectEqual(edge.fresh_ttl_s, freshTtl(.board));
    try std.testing.expectEqual(edge.stale_ttl_s, staleTtl(.board));
    try std.testing.expectEqual(edge.fresh_ttl_s, freshTtl(.detail));
    try std.testing.expectEqual(edge.stale_ttl_s, staleTtl(.detail));
}

test "concurrent hammer stays consistent" {
    if (@import("builtin").single_threaded) return;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var cache = NativeCache.init(std.testing.allocator, io, fakeClock);
    defer cache.deinit();

    const Hammer = struct {
        calls: std.atomic.Value(usize) = .init(0),
        fn fetch(ctx: *anyopaque, a: std.mem.Allocator) anyerror!Data {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.calls.fetchAdd(1, .seq_cst);
            return .{ .board = try cloneScoreboard(a, FakeBoard.boardFixture()) };
        }
        fn run(cache_ptr: *NativeCache, ctx: *anyopaque) void {
            var thread_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer thread_arena.deinit();
            // Contention may legitimately cause a few duplicate upstream
            // fetches; consistency (no crash, correct data) is the assert.
            for (0..25) |_| {
                const cached = cache_ptr.getOrFetch(thread_arena.allocator(), board_key, 1_000_000, ctx, fetch) catch continue;
                if (!std.mem.eql(u8, cached.data.board.league, "mlb")) continue;
            }
        }
    };
    var hammer = Hammer{};
    const workers = 8;
    var threads: [workers]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Hammer.run, .{ &cache, &hammer });
    for (&threads) |*t| t.join();
    // At least one upstream happened, at most one per iteration, and the
    // entry is intact afterwards.
    try std.testing.expect(hammer.calls.load(.seq_cst) >= 1);
    try std.testing.expect(hammer.calls.load(.seq_cst) <= workers * 25);
    var check_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer check_arena.deinit();
    const hit = try cache.getFresh(check_arena.allocator(), board_key, 1_000_000);
    try std.testing.expect(hit != null);
    try std.testing.expectEqualStrings("5", hit.?.board.games[0].participants[1].score);
}

test "standings entries use the schedule windows and survive the cache" {
    try std.testing.expectEqual(edge.schedule_fresh_ttl_s, freshTtl(.standings));
    try std.testing.expectEqual(edge.schedule_stale_ttl_s, staleTtl(.standings));
    var cache = testCache();
    defer cache.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t0: i64 = 1_000_000;
    const key: Key = .{ .standings = .{ .slug = "nhl" } };

    const StandingsFake = struct {
        calls: usize = 0,
        fail: bool = false,
        fail_err: anyerror = error.UpstreamResponse,
        fn fetch(ctx: *anyopaque, a: std.mem.Allocator) anyerror!Data {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.fail) return self.fail_err;
            return .{ .standings = try cloneStandings(a, .{
                .league = "nhl",
                .league_name = "NHL",
                .season = "2026",
                .source = "test",
                .groups = &.{
                    .{ .name = "Atlantic Division", .entries = &.{
                        .{ .team_id = "6", .abbrev = "BOS", .name = "Boston Bruins", .wins = "38", .losses = "14", .points = "85" },
                    } },
                },
            }) };
        }
    };
    var fake = StandingsFake{};
    const first = try cache.getOrFetch(arena, key, t0, &fake, StandingsFake.fetch);
    try std.testing.expectEqual(Outcome.miss, first.outcome);
    const second = try cache.getOrFetch(arena, key, t0, &fake, StandingsFake.fetch);
    try std.testing.expectEqual(Outcome.hit, second.outcome);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("BOS", second.data.standings.groups[0].entries[0].abbrev);
    try std.testing.expectEqualStrings("85", second.data.standings.groups[0].entries[0].points.?);
    // Stale serves on upstream failure; unsupported leagues never stale.
    fake.fail = true;
    const stale = try cache.getOrFetch(arena, key, t0 + edge.schedule_fresh_ttl_s, &fake, StandingsFake.fetch);
    try std.testing.expectEqual(Outcome.stale, stale.outcome);
    fake.fail_err = error.UnsupportedLeague;
    try std.testing.expectError(
        error.UnsupportedLeague,
        cache.getOrFetch(arena, key, t0 + edge.schedule_fresh_ttl_s, &fake, StandingsFake.fetch),
    );
}
