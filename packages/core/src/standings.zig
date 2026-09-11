const std = @import("std");

/// Provider-neutral league standings types.
///
/// ESPN shape notes (verified against fixture-shaped payloads, never live):
/// every sport serves `children[]` where each child carries a group name
/// plus `standings.entries[]`; US team sports nest one level deeper
/// (conference -> division) while soccer serves one flat level. The
/// provider walks `children` recursively, so both shapes normalize here.
///
/// `StandingEntry` keeps provider-shaped display strings (ESPN's
/// `displayValue` when present, else the numeric `value` rendered as
/// text): `"11"`, `"34"`. Fields are optional because sports disagree —
/// baseball has no ties column, MLB/NBA have no points column — and a
/// missing stat renders as `-`, never as zero. Names are provider-neutral
/// (`wins`, not ESPN's stat keys); rendering changes never alter JSON
/// field names.
pub const StandingEntry = struct {
    team_id: []const u8,
    abbrev: []const u8,
    name: []const u8,
    wins: ?[]const u8 = null,
    losses: ?[]const u8 = null,
    ties: ?[]const u8 = null,
    points: ?[]const u8 = null,
    /// Current streak display (e.g. "W3") when the provider ships it;
    /// null otherwise (renders nothing, never zero).
    streak: ?[]const u8 = null,
    /// Games-behind display (e.g. "2.5") when the provider ships it;
    /// null otherwise.
    games_behind: ?[]const u8 = null,

    pub const jsonschema = .{
        .name = "StandingEntry",
        .description = "One team's row in a standings group.",
    };
};

/// One division/conference/table block: the ESPN child name verbatim
/// (`"AFC East"`, `"NL West"`, `"English Premier League"`).
pub const StandingGroup = struct {
    name: []const u8,
    entries: []const StandingEntry = &.{},

    pub const jsonschema = .{
        .name = "StandingGroup",
        .description = "One division, conference, or table block.",
    };
};

/// A league's current standings: identity plus groups in provider order.
/// `season` is the calendar year the standings were fetched under (the
/// standings endpoint is current-season only; there is no season selector).
pub const LeagueStandings = struct {
    schema_version: []const u8 = "1",
    league: []const u8,
    league_name: []const u8,
    season: []const u8,
    groups: []const StandingGroup = &.{},
    source: []const u8 = "",

    pub const jsonschema = .{
        .name = "LeagueStandings",
        .fields = .{
            .schema_version = .{ .@"const" = "1" },
        },
    };
};

test "standings wire shape round-trips with the schema marker" {
    const entry: StandingEntry = .{
        .team_id = "2",
        .abbrev = "BUF",
        .name = "Buffalo Bills",
        .wins = "11",
        .losses = "3",
    };
    const group: StandingGroup = .{ .name = "AFC East", .entries = &.{entry} };
    const standings: LeagueStandings = .{
        .league = "nfl",
        .league_name = "NFL",
        .season = "2026",
        .groups = &.{group},
        .source = "test",
    };
    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const raw = try std.json.Stringify.valueAlloc(tmp.allocator(), standings, .{});
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"schema_version\":\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"abbrev\":\"BUF\"") != null);
    const parsed = try std.json.parseFromSliceLeaky(LeagueStandings, tmp.allocator(), raw, .{});
    try std.testing.expectEqualStrings("AFC East", parsed.groups[0].name);
    try std.testing.expect(parsed.groups[0].entries[0].ties == null);
    try std.testing.expectEqualStrings("11", parsed.groups[0].entries[0].wins.?);
}

test "standings streak and games-behind default null and round-trip" {
    const entry: StandingEntry = .{
        .team_id = "19",
        .abbrev = "NYY",
        .name = "New York Yankees",
        .wins = "80",
        .losses = "63",
        .streak = "W3",
        .games_behind = "2.5",
    };
    try std.testing.expectEqualStrings("W3", entry.streak.?);
    try std.testing.expectEqualStrings("2.5", entry.games_behind.?);
    // Absent stays absent (renders nothing, never zero).
    const bare: StandingEntry = .{ .team_id = "2", .abbrev = "BUF", .name = "Buffalo Bills" };
    try std.testing.expect(bare.streak == null);
    try std.testing.expect(bare.games_behind == null);
    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const raw = try std.json.Stringify.valueAlloc(tmp.allocator(), entry, .{});
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"streak\":\"W3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"games_behind\":\"2.5\"") != null);
    const legacy = try std.json.parseFromSliceLeaky(
        StandingEntry,
        tmp.allocator(),
        "{\"team_id\":\"2\",\"abbrev\":\"BUF\",\"name\":\"Buffalo Bills\"}",
        .{},
    );
    try std.testing.expect(legacy.streak == null);
    try std.testing.expect(legacy.games_behind == null);
}
