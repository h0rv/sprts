pub const Participant = struct {
    id: []const u8,
    name: []const u8,
    abbreviation: []const u8,
    score: []const u8,
    winner: bool,
    home_away: ?[]const u8 = null,
    record: ?[]const u8 = null,

    pub const jsonschema = .{
        .name = "Participant",
        .description = "A team, athlete, driver, fighter, or other entrant.",
        .fields = .{
            .home_away = .{ .description = "The team-sport side when the provider supplies one." },
            .record = .{ .description = "The win-loss style overall record when the provider supplies one." },
        },
    };
};

pub const Game = struct {
    id: []const u8,
    name: []const u8,
    starts_at: []const u8,
    state: []const u8,
    status: []const u8,
    participants: []const Participant,

    pub const jsonschema = .{
        .name = "Game",
        .description = "One game, bout, race, tournament, or other competition.",
        .fields = .{
            .starts_at = .{ .format = "date-time" },
        },
    };
};

pub const Scoreboard = struct {
    schema_version: []const u8 = "1",
    league: []const u8,
    league_name: []const u8,
    date: []const u8,
    source: []const u8,
    games: []const Game,

    pub const jsonschema = .{
        .name = "Scoreboard",
        .fields = .{
            .schema_version = .{ .@"const" = "1" },
            .date = .{ .format = "date" },
        },
    };
};
