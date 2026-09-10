const std = @import("std");

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
    /// Day-unique human id for this game on its board date: `{away}-{home}[-N]`
    /// (lowercase abbreviations, duel games) or `event-N` (N = 1-based board
    /// ordinal, every other game). Stamped by the provider at parse time from
    /// board order — no fetch needed to link it — and carried additively in
    /// JSON next to the numeric `id` (which stays the resolution address).
    /// Empty on hand-built boards that never went through the provider.
    slug: []const u8 = "",
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
            .slug = .{ .description = "Day-unique human id on the board date: {away}-{home}[-N] for duels, event-N otherwise. Additive; id stays the resolution address." },
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
// structs only ever gain optional keys./// Human slug helpers: the day-unique ids behind `Game.slug` and every
/// rendered game link. Pure string math over in-hand boards — no fetch,
/// no provider — so scoreboard, home, digest, team, and detail renderers
/// share one spelling. The duel form names the listed participant order
/// (`{away}-{home}`, lowercase); the ordinal form (`event-N`) names
/// everything else by 1-based board position. Slugs never carry the
/// date or league: callers join `/{league}/{date}/{slug}` (see
/// `gameHref`), matching the human alias routes.
/// True when a game can wear the duel form: exactly two participants,
/// both abbreviated (cards, races, fields, and athlete duels fail this
/// and take the ordinal form, like the alias lookup downstream).
pub fn isDuelGame(game: Game) bool {
    if (game.participants.len != 2) return false;
    return game.participants[0].abbreviation.len > 0 and game.participants[1].abbreviation.len > 0;
}

fn lowerDuplicated(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// Bare duel pair, already ordered (`{away}-{home}`, lowercase, no `-N`).
/// The caller orders the sides; team-schedule rows pass the away side
/// first from their home/away flag.
pub fn duelSlug(allocator: std.mem.Allocator, first_abbr: []const u8, second_abbr: []const u8) ![]u8 {
    const first = try lowerDuplicated(allocator, first_abbr);
    defer allocator.free(first);
    const second = try lowerDuplicated(allocator, second_abbr);
    defer allocator.free(second);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ first, second });
}

/// Canonical slug for the game at `index` on its day board: the duel
/// form for duels, `event-N` (N = 1-based board ordinal) for everything
/// else. The `-N` doubleheader suffix counts same-order listings only
/// (rank among board games with the same participant order,
/// case-insensitive): that mirrors the alias lookup's exact-order pass,
/// so every emitted slug resolves back to its own game with no suffix
/// when rank is 1 and `-rank` past it, whatever swapped listings share
/// the day. `index` must be in bounds.
pub fn boardGameSlug(allocator: std.mem.Allocator, games: []const Game, index: usize) ![]u8 {
    const game = games[index];
    if (isDuelGame(game)) {
        const a = game.participants[0].abbreviation;
        const b = game.participants[1].abbreviation;
        var rank: u16 = 0;
        for (games[0 .. index + 1]) |other| {
            if (other.participants.len != 2) continue;
            if (std.ascii.eqlIgnoreCase(other.participants[0].abbreviation, a) and
                std.ascii.eqlIgnoreCase(other.participants[1].abbreviation, b))
            {
                rank += 1;
            }
        }
        const base = try duelSlug(allocator, a, b);
        defer allocator.free(base);
        if (rank <= 1) return allocator.dupe(u8, base);
        return std.fmt.allocPrint(allocator, "{s}-{d}", .{ base, rank });
    }
    return std.fmt.allocPrint(allocator, "event-{d}", .{index + 1});
}

/// Link target for one board game: the human `/{league}/{date}/{slug}`
/// when the game carries a stamped slug, else the legacy numeric
/// `/{league}/{id}` (hand-built boards, unknown shapes). One decision
/// point so every renderer falls back the same way.
pub fn gameHref(allocator: std.mem.Allocator, league_slug: []const u8, board_date: []const u8, game: Game) ![]u8 {
    if (game.slug.len > 0) {
        return std.fmt.allocPrint(allocator, "/{s}/{s}/{s}", .{ league_slug, board_date, game.slug });
    }
    return std.fmt.allocPrint(allocator, "/{s}/{s}", .{ league_slug, game.id });
}

fn slugParticipants(away_abbr: []const u8, home_abbr: []const u8) [2]Participant {
    return .{
        .{ .id = "a", .name = "A", .abbreviation = away_abbr, .score = "", .winner = false },
        .{ .id = "b", .name = "B", .abbreviation = home_abbr, .score = "", .winner = false },
    };
}

fn slugDuel(parts: []const Participant) Game {
    return .{
        .id = "x",
        .name = "",
        .starts_at = "",
        .state = "post",
        .status = "Final",
        .participants = parts,
    };
}

test "duel games slug the listed pair, everything else the ordinal" {
    const arena = std.testing.allocator;
    const min_det = slugParticipants("MIN", "DET");
    try std.testing.expect(isDuelGame(slugDuel(&min_det)));
    try std.testing.expect(!isDuelGame(.{
        .id = "x",
        .name = "Card",
        .starts_at = "",
        .state = "pre",
        .status = "Scheduled",
        .participants = &.{
            .{ .id = "a", .name = "Fighter One", .abbreviation = "", .score = "", .winner = false },
            .{ .id = "b", .name = "Fighter Two", .abbreviation = "", .score = "", .winner = false },
        },
    }));
    try std.testing.expect(!isDuelGame(.{
        .id = "x",
        .name = "Race",
        .starts_at = "",
        .state = "pre",
        .status = "Scheduled",
        .participants = &.{},
    }));
    const pair = try duelSlug(arena, "MIN", "DET");
    defer arena.free(pair);
    try std.testing.expectEqualStrings("min-det", pair);
}

test "board slugs disambiguate doubleheaders, ordinals count every game" {
    const arena = std.testing.allocator;
    const p0 = slugParticipants("MIN", "DET");
    const p1 = slugParticipants("MIN", "DET");
    const p2 = slugParticipants("DET", "MIN");
    const games = [_]Game{
        slugDuel(&p0),
        slugDuel(&p1),
        slugDuel(&p2),
        .{
            .id = "race",
            .name = "Grand Prix",
            .starts_at = "",
            .state = "pre",
            .status = "Scheduled",
            .participants = &.{},
        },
    };
    // Same-order listings rank 1 (bare) then 2 (`-2`); the swapped
    // listing ranks 1 in its own order, so no suffix collides.
    const want = [_][]const u8{ "min-det", "min-det-2", "det-min", "event-4" };
    for (games, 0..) |_, i| {
        const slug = try boardGameSlug(arena, &games, i);
        defer arena.free(slug);
        try std.testing.expectEqualStrings(want[i], slug);
    }
}

test "game href prefers the slug, falls back to the numeric id" {
    const arena = std.testing.allocator;
    const human = try gameHref(arena, "mlb", "2026-09-09", .{
        .id = "9",
        .name = "",
        .starts_at = "",
        .state = "post",
        .status = "Final",
        .slug = "min-det-2",
        .participants = &.{},
    });
    defer arena.free(human);
    try std.testing.expectEqualStrings("/mlb/2026-09-09/min-det-2", human);
    const parts = slugParticipants("MIN", "DET");
    const legacy = try gameHref(arena, "mlb", "2026-09-09", slugDuel(&parts));
    defer arena.free(legacy);
    try std.testing.expectEqualStrings("/mlb/x", legacy);
}
