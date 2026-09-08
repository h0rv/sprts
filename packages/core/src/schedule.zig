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
/// display string: `"W 4-2"` / `"L 3-5"` for finals, `"vs OPP 7:05 PM"` /
/// `"at OPP 7:05 PM"` (UTC) for upcoming games.
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

    pub const jsonschema = .{
        .name = "ScheduleGameRef",
        .description = "One schedule row from the viewed team's perspective.",
        .fields = .{
            .date = .{ .format = "date-time" },
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
    past: []const ScheduleEvent,
    upcoming: []const ScheduleEvent,
};

fn datePrefix(date: []const u8) []const u8 {
    return if (date.len >= 10) date[0..10] else date;
}

fn isPastEvent(event: ScheduleEvent, today: []const u8) bool {
    const prefix = datePrefix(event.date);
    if (std.mem.order(u8, prefix, today) == .lt) return true;
    if (std.mem.order(u8, prefix, today) == .gt) return false;
    // Same calendar day: only completed games count as past. Live (`in`)
    // games stay upcoming so the live join can surface them.
    return std.mem.eql(u8, event.state, "post");
}

/// Partition a date-ascending schedule into past/upcoming around `today`
/// (`YYYY-MM-DD`). Pure and allocation-free: returns subslices.
pub fn splitSchedule(events: []const ScheduleEvent, today: []const u8) Split {
    var first_upcoming: usize = events.len;
    for (events, 0..) |event, i| {
        if (!isPastEvent(event, today)) {
            first_upcoming = i;
            break;
        }
    }
    return .{
        .past = events[0..first_upcoming],
        .upcoming = events[first_upcoming..],
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

test "splitSchedule partitions past and upcoming around today" {
    const events = [_]ScheduleEvent{
        testEvent("1", "2026-09-04T19:05Z", "post"),
        testEvent("2", "2026-09-06T17:05Z", "post"),
        testEvent("3", "2026-09-06T19:05Z", "pre"),
        testEvent("4", "2026-09-08T19:05Z", "pre"),
    };
    const split = splitSchedule(&events, "2026-09-06");
    try std.testing.expectEqual(@as(usize, 2), split.past.len);
    try std.testing.expectEqual(@as(usize, 2), split.upcoming.len);
    try std.testing.expectEqualStrings("2", split.past[1].id);
    try std.testing.expectEqualStrings("3", split.upcoming[0].id);
}

test "splitSchedule keeps live games on the upcoming side" {
    const events = [_]ScheduleEvent{
        testEvent("1", "2026-09-06T17:05Z", "in"),
    };
    const split = splitSchedule(&events, "2026-09-06");
    try std.testing.expectEqual(@as(usize, 0), split.past.len);
    try std.testing.expectEqual(@as(usize, 1), split.upcoming.len);
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
