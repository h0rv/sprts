pub const LineScore = struct {
    period: ?i64 = null,
    display: []const u8 = "",

    pub const jsonschema = .{
        .name = "LineScore",
        .description = "One period's score for one side of a game, e.g. a quarter or a tennis set.",
    };
};

pub const Participant = struct {
    id: []const u8,
    name: []const u8,
    abbreviation: []const u8,
    score: []const u8,
    winner: bool,
    home_away: ?[]const u8 = null,
    record: ?[]const u8 = null,
    /// Per-period breakdown (quarters, periods, innings, sets) when the
    /// provider supplies one; empty otherwise.
    lines: []const LineScore = &.{},
    /// Recent-results string (e.g. soccer "WDDLD") when the provider
    /// supplies one; null otherwise.
    form: ?[]const u8 = null,

    pub const jsonschema = .{
        .name = "Participant",
        .description = "A team, athlete, driver, fighter, or other entrant.",
        .fields = .{
            .home_away = .{ .description = "The team-sport side when the provider supplies one." },
            .record = .{ .description = "The win-loss style overall record when the provider supplies one." },
            .lines = .{ .description = "Per-period scores when the provider supplies them; empty otherwise." },
            .form = .{ .description = "Recent-results string (e.g. soccer WDDLD) when the provider supplies one." },
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
    /// TV broadcaster (first ESPN `broadcasts[].names` entry, geo feed
    /// short name as fallback); null when the provider supplies none.
    network: ?[]const u8 = null,
    /// Venue full name from the ESPN competition (racing falls back to
    /// the event circuit); null when the provider supplies none.
    venue: ?[]const u8 = null,
    /// Per-game statistical leaders (e.g. "Drew Lock 16/22, 187 YDS");
    /// empty when the provider supplies none.
    leaders: []const []const u8 = &.{},

    pub const jsonschema = .{
        .name = "Game",
        .description = "One game, bout, race, tournament, or other competition.",
        .fields = .{
            .starts_at = .{ .format = "date-time" },
            .network = .{ .description = "TV broadcaster when the provider supplies one." },
            .venue = .{ .description = "Venue full name when the provider supplies one." },
            .leaders = .{ .description = "Per-game statistical leader strings when the provider supplies them." },
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

/// One scoring play inside a finished or live game.
pub const ScoringPlay = struct {
    period: []const u8 = "",
    text: []const u8 = "",
    away_score: i64 = 0,
    home_score: i64 = 0,

    pub const jsonschema = .{ .name = "ScoringPlay" };
};

/// Full detail for one game: the scoreboard row plus venue, scoring
/// plays, and win/loss pitchers of record where the provider has them.
pub const GameDetail = struct {
    schema_version: []const u8 = "1",
    league: []const u8,
    league_name: []const u8,
    id: []const u8,
    name: []const u8,
    date: []const u8,
    state: []const u8,
    status: []const u8,
    venue: []const u8 = "",
    attendance: i64 = 0,
    winner: []const u8 = "",
    loser: []const u8 = "",
    participants: []const Participant = &.{},
    scoring_plays: []const ScoringPlay = &.{},
    source: []const u8 = "",

    pub const jsonschema = .{
        .name = "GameDetail",
        .fields = .{
            .schema_version = .{ .@"const" = "1" },
            .date = .{ .format = "date" },
        },
    };
};

/// One game on a team's schedule: opponent, home/away, result or start.
pub const ScheduleGame = struct {
    id: []const u8 = "",
    date: []const u8 = "",
    opponent: []const u8 = "",
    opponent_name: []const u8 = "",
    home_away: []const u8 = "",
    state: []const u8 = "",
    status: []const u8 = "",
    score_for: []const u8 = "",
    score_against: []const u8 = "",
    won: ?bool = null,

    pub const jsonschema = .{
        .name = "ScheduleGame",
        .fields = .{ .date = .{ .format = "date-time" } },
    };
};

/// A team page: identity plus last result and upcoming games.
pub const TeamView = struct {
    schema_version: []const u8 = "1",
    league: []const u8,
    league_name: []const u8,
    team: []const u8 = "",
    team_name: []const u8 = "",
    record: []const u8 = "",
    standing: []const u8 = "",
    last: ?ScheduleGame = null,
    next: []const ScheduleGame = &.{},
    source: []const u8 = "",

    pub const jsonschema = .{
        .name = "TeamView",
        .fields = .{ .schema_version = .{ .@"const" = "1" } },
    };
};
