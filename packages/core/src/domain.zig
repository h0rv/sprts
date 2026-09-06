pub const Participant = struct {
    id: []const u8,
    name: []const u8,
    abbreviation: []const u8,
    score: []const u8,
    winner: bool,
    home_away: ?[]const u8 = null,
};

pub const Game = struct {
    id: []const u8,
    name: []const u8,
    starts_at: []const u8,
    state: []const u8,
    status: []const u8,
    participants: []const Participant,
};

pub const Scoreboard = struct {
    schema_version: []const u8 = "1",
    league: []const u8,
    league_name: []const u8,
    date: []const u8,
    source: []const u8,
    games: []const Game,
};
