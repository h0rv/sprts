const std = @import("std");

/// Provider-neutral per-game detail view. Baseball-first in spirit but every
/// field name is sport-neutral (`period`, never `inning`).
pub const DetailLineScore = struct {
    period: ?i64 = null,
    display: []const u8 = "",

    pub const jsonschema = .{
        .name = "DetailLineScore",
        .description = "One period's score for one side of a game.",
    };
};

/// Detail-side participant. Identity fields mirror `domain.Participant`
/// (`domain.Participant` itself is untouched); this struct only adds the
/// per-period breakdown plus hits/errors/record/probable starter.
pub const DetailParticipant = struct {
    id: []const u8,
    name: []const u8,
    abbreviation: []const u8,
    score: []const u8,
    winner: bool,
    home_away: ?[]const u8 = null,
    lines: []const DetailLineScore = &.{},
    hits: ?[]const u8 = null,
    errors: ?[]const u8 = null,
    record: ?[]const u8 = null,
    probable: ?[]const u8 = null,

    pub const jsonschema = .{
        .name = "DetailParticipant",
        .description = "One side of a game with its per-period breakdown.",
        .fields = .{
            .home_away = .{ .description = "The team-sport side when the provider supplies one." },
            .hits = .{ .description = "Total hits (or sport equivalent) when the provider supplies them." },
            .errors = .{ .description = "Total errors (or sport equivalent) when the provider supplies them." },
            .record = .{ .description = "Overall record summary, e.g. \"88-56\"." },
            .probable = .{ .description = "Probable starter name when the provider supplies one." },
        },
    };
};

pub const DetailSituation = struct {
    balls: i64 = 0,
    strikes: i64 = 0,
    outs: i64 = 0,
    runners: []const []const u8 = &.{},
    batter: ?[]const u8 = null,
    pitcher: ?[]const u8 = null,
    last_play: ?[]const u8 = null,

    pub const jsonschema = .{
        .name = "DetailSituation",
        .description = "Live game situation: count, outs, occupied bases, matchup.",
        .fields = .{
            .runners = .{ .description = "Occupied bases as \"1st\", \"2nd\", \"3rd\"; empty when no runners." },
        },
    };
};

pub const DetailDecision = struct {
    outcome: []const u8,
    name: []const u8,

    pub const jsonschema = .{
        .name = "DetailDecision",
        .description = "A crediting decision: W, L, or SV plus the athlete name.",
    };
};

pub const DetailScoringPlay = struct {
    period: []const u8,
    text: []const u8,
    away_score: []const u8,
    home_score: []const u8,

    pub const jsonschema = .{
        .name = "DetailScoringPlay",
        .description = "One scoring play with the running score afterward.",
    };
};

pub const DetailGame = struct {
    schema_version: []const u8 = "1",
    id: []const u8,
    league: []const u8,
    league_name: []const u8,
    date: []const u8,
    state: []const u8,
    status: []const u8,
    venue: ?[]const u8 = null,
    attendance: ?i64 = null,
    series: ?[]const u8 = null,
    participants: []const DetailParticipant,
    situation: ?DetailSituation = null,
    decisions: []const DetailDecision = &.{},
    scoring_plays: []const DetailScoringPlay = &.{},
    leaders: []const []const u8 = &.{},

    pub const jsonschema = .{
        .name = "DetailGame",
        .description = "Provider-neutral per-game detail: header, linescore data, live situation, decisions, scoring plays, leaders.",
        .fields = .{
            .schema_version = .{ .@"const" = "1" },
            .date = .{ .format = "date" },
            .venue = .{ .description = "Venue full name when the provider supplies one." },
            .attendance = .{ .description = "Ticketed attendance when the provider supplies it." },
            .series = .{ .description = "Series summary supplied by the provider; absent when not derivable." },
            .leaders = .{ .description = "Short statistical leader strings, e.g. team totals and top performers." },
        },
    };
};

test "detail structs carry jsonschema names" {
    try std.testing.expectEqualStrings("DetailLineScore", DetailLineScore.jsonschema.name);
    try std.testing.expectEqualStrings("DetailParticipant", DetailParticipant.jsonschema.name);
    try std.testing.expectEqualStrings("DetailSituation", DetailSituation.jsonschema.name);
    try std.testing.expectEqualStrings("DetailDecision", DetailDecision.jsonschema.name);
    try std.testing.expectEqualStrings("DetailScoringPlay", DetailScoringPlay.jsonschema.name);
    try std.testing.expectEqualStrings("DetailGame", DetailGame.jsonschema.name);
}

test "game detail defaults to empty collections" {
    const game_detail: DetailGame = .{
        .id = "1",
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .state = "pre",
        .status = "Scheduled",
        .participants = &.{},
    };
    try std.testing.expectEqualStrings("1", game_detail.schema_version);
    try std.testing.expect(game_detail.venue == null);
    try std.testing.expect(game_detail.situation == null);
    try std.testing.expectEqual(@as(usize, 0), game_detail.decisions.len);
    try std.testing.expectEqual(@as(usize, 0), game_detail.scoring_plays.len);
    try std.testing.expectEqual(@as(usize, 0), game_detail.leaders.len);
}

pub const LineScore = DetailLineScore;
pub const Situation = DetailSituation;
pub const Decision = DetailDecision;
pub const ScoringPlay = DetailScoringPlay;
pub const GameDetail = DetailGame;
