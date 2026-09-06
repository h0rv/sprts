const std = @import("std");

pub const League = struct {
    slug: []const u8,
    name: []const u8,
    sport: []const u8,
};

/// Adding a competition is deliberately data-only: no router, adapter, or
/// renderer changes are needed.
pub const all = [_]League{
    .{ .slug = "nfl", .name = "NFL", .sport = "Football" },
    .{ .slug = "ncaaf", .name = "NCAA Football", .sport = "Football" },
    .{ .slug = "nba", .name = "NBA", .sport = "Basketball" },
    .{ .slug = "wnba", .name = "WNBA", .sport = "Basketball" },
    .{ .slug = "ncaam", .name = "NCAA Men's Basketball", .sport = "Basketball" },
    .{ .slug = "ncaaw", .name = "NCAA Women's Basketball", .sport = "Basketball" },
    .{ .slug = "mlb", .name = "MLB", .sport = "Baseball" },
    .{ .slug = "nhl", .name = "NHL", .sport = "Hockey" },
    .{ .slug = "mls", .name = "MLS", .sport = "Soccer" },
    .{ .slug = "epl", .name = "Premier League", .sport = "Soccer" },
    .{ .slug = "laliga", .name = "La Liga", .sport = "Soccer" },
    .{ .slug = "bundesliga", .name = "Bundesliga", .sport = "Soccer" },
    .{ .slug = "seriea", .name = "Serie A", .sport = "Soccer" },
    .{ .slug = "ligue1", .name = "Ligue 1", .sport = "Soccer" },
    .{ .slug = "ucl", .name = "UEFA Champions League", .sport = "Soccer" },
    .{ .slug = "atp", .name = "ATP", .sport = "Tennis" },
    .{ .slug = "wta", .name = "WTA", .sport = "Tennis" },
    .{ .slug = "f1", .name = "Formula 1", .sport = "Racing" },
    .{ .slug = "ufc", .name = "UFC", .sport = "MMA" },
    .{ .slug = "pga", .name = "PGA Tour", .sport = "Golf" },
};

pub fn find(slug: []const u8) ?*const League {
    for (&all) |*league| {
        if (std.ascii.eqlIgnoreCase(slug, league.slug)) return league;
    }
    return null;
}

test "find is case insensitive and unknown leagues are absent" {
    try std.testing.expectEqualStrings("NBA", find("NbA").?.name);
    try std.testing.expect(find("quidditch") == null);
}
