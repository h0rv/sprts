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
    /// Detail-side extras (baseball totals, probable starters): null
    /// unless the provider supplies them. These reunify the old
    /// `detail.DetailParticipant` into this single struct — every field
    /// stays optional, so both wire shapes only ever gain keys.
    hits: ?[]const u8 = null,
    errors: ?[]const u8 = null,
    probable: ?[]const u8 = null,

    pub const jsonschema = .{
        .name = "Participant",
        .description = "A team, athlete, driver, fighter, or other entrant.",
        .fields = .{
            .home_away = .{ .description = "The team-sport side when the provider supplies one." },
            .record = .{ .description = "The win-loss style overall record when the provider supplies one." },
            .lines = .{ .description = "Per-period scores when the provider supplies them; empty otherwise." },
            .form = .{ .description = "Recent-results string (e.g. soccer WDDLD) when the provider supplies one." },
            .hits = .{ .description = "Total hits (or sport equivalent) when the provider supplies them." },
            .errors = .{ .description = "Total errors (or sport equivalent) when the provider supplies them." },
            .probable = .{ .description = "Probable starter name when the provider supplies one." },
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

// NOTE: game detail lives in exactly one place — `detail.GameDetail`
// (`detail.zig`) — and team schedules in exactly one place —
// `schedule.TeamView` / `schedule.GameRef` (`schedule.zig`). The older
// `domain` duplicates (`ScoringPlay`, `GameDetail`, `ScheduleGame`,
// `TeamView`) were removed; nothing on the wire lost a field, the live
// structs only ever gain optional keys.
