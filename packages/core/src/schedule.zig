const std = @import("std");

/// Provider-neutral per-team schedule types plus the pure helpers shared by
/// the team stream (`/{league}/{abbr}`) and the game-detail stream.
///
/// ESPN notes (verified live 2026-09-06):
/// - The schedule endpoint cannot tell live games apart: a game later today
///   still reads `pre`. The provider joins "LIVE NOW" by intersecting
///   schedule event ids with that date's scoreboard `state == in` games.
/// - Event-level `status` is always null; the competition-level status is
///   authoritative. `ScheduleEvent` therefore carries the competition state.
pub const TeamInfo = struct {
    id: []const u8,
    abbrev: []const u8,
    name: []const u8,
    record_summary: ?[]const u8 = null,
    standing_summary: ?[]const u8 = null,

    pub const jsonschema = .{
        .name = "ScheduleTeamInfo",
        .description = "Identity and season summary for one team.",
    };
};

/// One schedule row from the perspective of the viewed team. `result` is a
/// display string: `"W 4-2"` / `"L 3-5"` / `"D 2-2"` for finals, `"vs OPP 7:05 PM"` /
/// `"at OPP 7:05 PM"` (US Eastern) for upcoming games.
pub const GameRef = struct {
    id: []const u8,
    date: []const u8,
    opponent_abbrev: []const u8,
    opponent_name: []const u8,
    home_away: []const u8,
    status: []const u8,
    state: []const u8 = "pre",
    our_score: []const u8 = "",
    opp_score: []const u8 = "",
    result: []const u8 = "",
    probable: []const u8 = "",
    /// True when this upcoming game falls on today's Eastern calendar
    /// day: renderers surface these rows in a top-center Today section
    /// instead of only inside Next 5. Additive; defaults false.
    today: bool = false,

    pub const jsonschema = .{
        .name = "ScheduleGameRef",
        .description = "One schedule row from the viewed team's perspective.",
        .fields = .{
            .date = .{ .format = "date-time" },
            .today = .{ .description = "Upcoming game on today's Eastern day; render top-center." },
        },
    };
};

pub const TeamView = struct {
    schema_version: []const u8 = "1",
    league: []const u8,
    league_name: []const u8,
    team: TeamInfo,
    last: []const GameRef = &.{},
    next: []const GameRef = &.{},
    live: ?GameRef = null,
    // depth: full-season overflow beyond `last`/`next` (both capped at 5 by
    // the provider). `extra_past` continues `last` newest-first; `extra_next`
    // continues `next` chronological. Empty when there is nothing beyond the
    // window; renderers skip the sections rather than erroring.
    extra_past: []const GameRef = &.{},
    extra_next: []const GameRef = &.{},

    pub const jsonschema = .{
        .name = "ScheduleTeamView",
        .description = "Per-team view: header, last results, upcoming games, live game when present.",
        .fields = .{
            .schema_version = .{ .@"const" = "1" },
            .extra_past = .{ .description = "Older past games beyond the last window, newest-first; empty when none." },
            .extra_next = .{ .description = "Later upcoming games beyond the next window, chronological; empty when none." },
        },
    };
};

/// One entry in a league's team list: ESPN identity only. No record:
/// the teams endpoint carries none, and per-team records would cost one
/// schedule fetch per team (N+1) instead of the single list fetch.
pub const TeamListEntry = struct {
    id: []const u8,
    abbrev: []const u8,
    name: []const u8,

    pub const jsonschema = .{
        .name = "ScheduleTeamListEntry",
        .description = "One team's identity in a league team list.",
    };
};

/// A league's full team membership in provider order: the picker payload
/// behind `GET /api/v1/{league}/teams`. One ESPN teams fetch, no
/// per-team fan-out; empty when the provider lists no teams.
pub const TeamList = struct {
    schema_version: []const u8 = "1",
    league: []const u8,
    league_name: []const u8,
    teams: []const TeamListEntry = &.{},
    source: []const u8 = "",

    pub const jsonschema = .{
        .name = "ScheduleTeamList",
        .description = "Team list for one league: identity rows for every member team.",
        .fields = .{
            .schema_version = .{ .@"const" = "1" },
        },
    };
};

/// Raw schedule row used by the pure helpers below. The provider builds
/// these from the ESPN schedule payload (competition level) before mapping
/// to `GameRef`s.
pub const ScheduleEvent = struct {
    id: []const u8,
    date: []const u8,
    opponent_abbrev: []const u8,
    opponent_name: []const u8,
    home_away: []const u8 = "",
    state: []const u8 = "pre",
    status: []const u8 = "Scheduled",
    our_score: []const u8 = "",
    opp_score: []const u8 = "",
    won: ?bool = null,
    probable: []const u8 = "",
};

pub const Split = struct {
    past: []ScheduleEvent,
    upcoming: []ScheduleEvent,
};

/// First live game, else first flagged upcoming row (next then extras):
/// backing for `/{league}/{abbr}/today`. Null when the team has no game
/// today. Pure scan; the provider flags rows, views render them.
pub fn findTodayGame(view: TeamView) ?GameRef {
    if (view.live) |live| return live;
    for (view.next) |game| if (game.today) return game;
    for (view.extra_next) |game| if (game.today) return game;
    return null;
}

fn datePrefix(date: []const u8) []const u8 {
    return if (date.len >= 10) date[0..10] else date;
}

/// A game is past only once it is completed (`post`). Live games stay
/// upcoming so the live join can surface them — even across UTC midnight —
/// and postponed games (`pre` with a past date) wait in upcoming instead of
/// filing under Last as phantom results. Completion decides, not the
/// calendar: date-prefix bucketing once filed a live 09-08 Top-9th game
/// under Last 5 while it was still being played on 09-09.
fn isPastEvent(event: ScheduleEvent) bool {
    if (std.mem.eql(u8, event.state, "in")) return false;
    return std.mem.eql(u8, event.state, "post");
}

/// Partition a schedule into completed (`state == post`) and upcoming
/// (anything else) halves, preserving schedule order in each. Both slices
/// are allocated from `arena`: postponed and cross-midnight live games can
/// interleave the completed ones, so no single split point would stay
/// correct. `today` is retained for call-site stability and ignored.
pub fn splitSchedule(arena: std.mem.Allocator, events: []const ScheduleEvent, today: []const u8) !Split {
    _ = today;
    var past: std.ArrayList(ScheduleEvent) = .empty;
    var upcoming: std.ArrayList(ScheduleEvent) = .empty;
    for (events) |event| {
        if (isPastEvent(event)) {
            try past.append(arena, event);
        } else {
            try upcoming.append(arena, event);
        }
    }
    return .{
        .past = try past.toOwnedSlice(arena),
        .upcoming = try upcoming.toOwnedSlice(arena),
    };
}

pub const Series = struct {
    opponent_abbrev: []const u8,
    opponent_name: []const u8,
    games: []const ScheduleEvent,
    wins: u32,
    losses: u32,
};

/// Consecutive schedule games against the same opponent form a series.
/// Returns the contiguous block (same opponent abbrev, case-insensitive)
/// containing the event identified by `key` — either a schedule event id
/// or a date (`YYYY-MM-DD` prefix or full ISO timestamp) — with the W-L
/// record inside that block. Returns null when `key` matches nothing.
pub fn seriesFor(events: []const ScheduleEvent, key: []const u8) ?Series {
    var at: ?usize = null;
    for (events, 0..) |event, i| {
        if (std.mem.eql(u8, event.id, key) or
            std.mem.eql(u8, event.date, key) or
            std.mem.eql(u8, datePrefix(event.date), key))
        {
            at = i;
            break;
        }
    }
    const index = at orelse return null;
    const abbrev = events[index].opponent_abbrev;
    var start: usize = index;
    while (start > 0 and std.ascii.eqlIgnoreCase(events[start - 1].opponent_abbrev, abbrev)) : (start -= 1) {}
    var end: usize = index + 1;
    while (end < events.len and std.ascii.eqlIgnoreCase(events[end].opponent_abbrev, abbrev)) : (end += 1) {}
    const block = events[start..end];
    var wins: u32 = 0;
    var losses: u32 = 0;
    for (block) |event| {
        if (event.won) |won| {
            if (won) {
                wins += 1;
            } else {
                losses += 1;
            }
        }
    }
    return .{
        .opponent_abbrev = abbrev,
        .opponent_name = events[index].opponent_name,
        .games = block,
        .wins = wins,
        .losses = losses,
    };
}

fn testEvent(id: []const u8, date: []const u8, state: []const u8) ScheduleEvent {
    return .{
        .id = id,
        .date = date,
        .opponent_abbrev = "OPP",
        .opponent_name = "Opponents",
        .home_away = "home",
        .state = state,
        .status = "Scheduled",
    };
}

test "team list wire shape round-trips with the schema marker" {
    const list: TeamList = .{
        .league = "mlb",
        .league_name = "MLB",
        .teams = &.{
            .{ .id = "22", .abbrev = "PHI", .name = "Philadelphia Phillies" },
            .{ .id = "12", .abbrev = "ATL", .name = "Atlanta Braves" },
        },
        .source = "test",
    };
    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const raw = try std.json.Stringify.valueAlloc(tmp.allocator(), list, .{});
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"schema_version\":\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"abbrev\":\"PHI\"") != null);
    const parsed = try std.json.parseFromSliceLeaky(TeamList, tmp.allocator(), raw, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed.teams.len);
    try std.testing.expectEqualStrings("22", parsed.teams[0].id);
    try std.testing.expectEqualStrings("Philadelphia Phillies", parsed.teams[0].name);
    // Empty membership parses to an empty list, never an error.
    const empty: TeamList = .{ .league = "mlb", .league_name = "MLB" };
    try std.testing.expectEqual(@as(usize, 0), empty.teams.len);
    try std.testing.expectEqualStrings("1", empty.schema_version);
}

test "splitSchedule partitions past and upcoming around today" {
    const events = [_]ScheduleEvent{
        testEvent("1", "2026-09-04T19:05Z", "post"),
        testEvent("2", "2026-09-06T17:05Z", "post"),
        testEvent("3", "2026-09-06T19:05Z", "pre"),
        testEvent("4", "2026-09-08T19:05Z", "pre"),
    };
    const split = try splitSchedule(std.testing.allocator, &events, "2026-09-06");
    defer std.testing.allocator.free(split.past);
    defer std.testing.allocator.free(split.upcoming);
    try std.testing.expectEqual(@as(usize, 2), split.past.len);
    try std.testing.expectEqual(@as(usize, 2), split.upcoming.len);
    try std.testing.expectEqualStrings("2", split.past[1].id);
    try std.testing.expectEqualStrings("3", split.upcoming[0].id);
}

test "splitSchedule keeps live games on the upcoming side" {
    const events = [_]ScheduleEvent{
        testEvent("1", "2026-09-06T17:05Z", "in"),
    };
    const split = try splitSchedule(std.testing.allocator, &events, "2026-09-06");
    defer std.testing.allocator.free(split.past);
    defer std.testing.allocator.free(split.upcoming);
    try std.testing.expectEqual(@as(usize, 0), split.past.len);
    try std.testing.expectEqual(@as(usize, 1), split.upcoming.len);
}

test "splitSchedule files by completion when dates interleave" {
    // A postponed game (pre, past date) sits between finals and a live game
    // that started yesterday is still `in`: neither is a result yet, so
    // both stay upcoming even though no single split point separates them.
    const events = [_]ScheduleEvent{
        testEvent("ppd", "2026-09-04T19:05Z", "pre"),
        testEvent("old", "2026-09-05T19:05Z", "post"),
        testEvent("live", "2026-09-06T22:40Z", "in"),
        testEvent("fut", "2026-09-08T19:05Z", "pre"),
    };
    const split = try splitSchedule(std.testing.allocator, &events, "2026-09-07");
    defer std.testing.allocator.free(split.past);
    defer std.testing.allocator.free(split.upcoming);
    try std.testing.expectEqual(@as(usize, 1), split.past.len);
    try std.testing.expectEqualStrings("old", split.past[0].id);
    try std.testing.expectEqual(@as(usize, 3), split.upcoming.len);
    try std.testing.expectEqualStrings("ppd", split.upcoming[0].id);
    try std.testing.expectEqualStrings("live", split.upcoming[1].id);
    try std.testing.expectEqualStrings("fut", split.upcoming[2].id);
}

test "seriesFor finds the contiguous block and counts wins" {
    const events = [_]ScheduleEvent{
        .{ .id = "1", .date = "2026-09-01T19:05Z", .opponent_abbrev = "NYM", .opponent_name = "New York Mets", .state = "post", .won = true },
        .{ .id = "2", .date = "2026-09-02T19:05Z", .opponent_abbrev = "nym", .opponent_name = "New York Mets", .state = "post", .won = false },
        .{ .id = "3", .date = "2026-09-03T19:05Z", .opponent_abbrev = "ATL", .opponent_name = "Atlanta Braves", .state = "pre" },
        .{ .id = "4", .date = "2026-09-04T19:05Z", .opponent_abbrev = "NYM", .opponent_name = "New York Mets", .state = "pre" },
    };
    const by_id = seriesFor(&events, "2").?;
    try std.testing.expectEqual(@as(usize, 2), by_id.games.len);
    try std.testing.expectEqual(@as(u32, 1), by_id.wins);
    try std.testing.expectEqual(@as(u32, 1), by_id.losses);
    try std.testing.expectEqualStrings("nym", by_id.opponent_abbrev);

    const by_date = seriesFor(&events, "2026-09-03").?;
    try std.testing.expectEqual(@as(usize, 1), by_date.games.len);
    try std.testing.expectEqualStrings("ATL", by_date.opponent_abbrev);

    // Same opponent separated by another block is a different series.
    const later = seriesFor(&events, "4").?;
    try std.testing.expectEqual(@as(usize, 1), later.games.len);

    try std.testing.expect(seriesFor(&events, "nope") == null);
}

test "findTodayGame prefers live, then flagged upcoming" {
    const live = GameRef{ .id = "l", .date = "2026-09-06T19:05Z", .opponent_abbrev = "A", .opponent_name = "A", .home_away = "home", .status = "Top 7th", .state = "in", .result = "1-0 Top 7th" };
    const base = TeamView{
        .league = "mlb",
        .league_name = "MLB",
        .team = .{ .id = "22", .abbrev = "PHI", .name = "Philadelphia Phillies" },
        .next = &.{
            .{ .id = "t", .date = "2026-09-06T23:10Z", .opponent_abbrev = "B", .opponent_name = "B", .home_away = "away", .status = "Scheduled", .state = "pre", .result = "at B", .today = true },
            .{ .id = "f", .date = "2026-09-08T19:05Z", .opponent_abbrev = "C", .opponent_name = "C", .home_away = "home", .status = "Scheduled", .state = "pre", .result = "vs C" },
        },
    };
    // Live outranks flagged upcoming.
    var with_live = base;
    with_live.live = live;
    try std.testing.expectEqualStrings("l", findTodayGame(with_live).?.id);
    // Otherwise the first flagged row wins; unflagged views have none.
    try std.testing.expectEqualStrings("t", findTodayGame(base).?.id);
    var bare = base;
    bare.next = &.{base.next[1]};
    try std.testing.expect(findTodayGame(bare) == null);
}
