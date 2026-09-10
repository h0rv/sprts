/// One-shot text rendering over the typed sprts client structs (wave 2).
///
/// Deliberately separate from the server-side document renderers: those
/// shape full text/HTML/JSON documents, while this printer owns the CLI's
/// compact `AWY 2 @ HME 5  Final` rows. Generic over the scoreboard and
/// digest game shapes (same fields, different generated type names).

const std = @import("std");
const sprts_client = @import("sprts_client");
const gen = sprts_client.gen;

/// Nullable digest entry: a null board is an upstream outage for that
/// league, rendered as an outage line instead of crashing.
pub const DigestSection = struct {
    slug: []const u8,
    league_name: []const u8,
    date: []const u8,
    board: ?gen.DigestJsonLeaguesItem,
};

/// Compact human scoreboard: league header plus one row per game.
pub fn renderScoreboard(allocator: std.mem.Allocator, board: sprts_client.Scoreboard) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try header(&out.writer, board.league_name, board.league, board.date);
    if (board.games.len == 0) try out.writer.writeAll("  No games scheduled.\n");
    for (board.games) |game| try gameRow(&out.writer, game);
    return out.toOwnedSlice();
}

/// All-leagues digest: slugs in `degraded` render an outage line even
/// though the API carries them as zero-game boards (off-day lookalike).
pub fn renderDigest(allocator: std.mem.Allocator, digest: sprts_client.DigestJson) ![]u8 {
    const sections = try allocator.alloc(DigestSection, digest.leagues.len);
    defer allocator.free(sections);
    for (digest.leagues, 0..) |*entry, i| {
        sections[i] = .{
            .slug = entry.league,
            .league_name = entry.league_name,
            .date = entry.date,
            .board = if (isDegraded(digest.degraded, entry.league)) null else entry.*,
        };
    }
    return renderDigestSections(allocator, digest.date, sections);
}

pub fn renderDigestSections(allocator: std.mem.Allocator, date: []const u8, sections: []const DigestSection) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (sections.len == 0) {
        try out.writer.writeAll("No games scheduled.\n");
        return out.toOwnedSlice();
    }
    _ = date;
    for (sections) |section| {
        try header(&out.writer, section.league_name, section.slug, section.date);
        const board = section.board orelse {
            try out.writer.writeAll("  scores unavailable (upstream outage)\n");
            continue;
        };
        if (board.games.len == 0) try out.writer.writeAll("  No games scheduled.\n");
        for (board.games) |game| try gameRow(&out.writer, game);
    }
    return out.toOwnedSlice();
}

fn header(w: *std.Io.Writer, name: []const u8, slug: []const u8, date: []const u8) !void {
    try w.print("{s} ({s}) — {s}\n", .{ name, slug, date });
}

/// `AWY 2 (10-5) @ HME 5 (12-3)  Final`; records only where present,
/// scores only when posted, degenerate shapes fall back to name + status.
fn gameRow(w: *std.Io.Writer, game: anytype) !void {
    const away = pickSide(game.participants, "away", 0);
    const home = pickSide(game.participants, "home", 1);
    const a = away orelse return writeSolo(w, game);
    const h = home orelse return writeSolo(w, game);
    if (std.mem.eql(u8, a.id, h.id)) return writeSolo(w, game);
    try w.writeAll("  ");
    try teamChunk(w, a);
    try w.writeAll(" @ ");
    try teamChunk(w, h);
    try w.print("  {s}\n", .{game.status});
}

fn writeSolo(w: *std.Io.Writer, game: anytype) !void {
    const label = if (game.name.len > 0) game.name else game.id;
    try w.print("  {s}  {s}\n", .{ label, game.status });
}

fn teamChunk(w: *std.Io.Writer, p: anytype) !void {
    try w.writeAll(p.abbreviation);
    if (p.record) |record| try w.print(" ({s})", .{record});
    if (p.score.len > 0) try w.print(" {s}", .{p.score});
}

fn pickSide(parts: anytype, want: []const u8, fallback: usize) ?@TypeOf(parts[0]) {
    for (parts) |p| {
        if (p.home_away) |ha| if (std.mem.eql(u8, ha, want)) return p;
    }
    if (fallback < parts.len) return parts[fallback];
    return null;
}

fn isDegraded(degraded: []const []const u8, slug: []const u8) bool {
    for (degraded) |entry| if (std.mem.eql(u8, entry, slug)) return true;
    return false;
}

fn cannedBoard() gen.Scoreboard {
    return .{
        .source = "test",
        .date = "2026-09-06",
        .games = &.{
            .{
                .id = "1",
                .name = "",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away Club", .abbreviation = "AWY", .score = "2", .winner = false, .home_away = "away", .record = "10-5" },
                    .{ .id = "h", .name = "Home Club", .abbreviation = "HME", .score = "5", .winner = true, .home_away = "home", .record = "12-3" },
                },
            },
            .{
                .id = "2",
                .name = "",
                .starts_at = "2026-09-06T19:00Z",
                .state = "in",
                .status = "Top 7th",
                .participants = &.{
                    .{ .id = "b", .name = "Bee Club", .abbreviation = "BEE", .score = "0", .winner = false, .home_away = "away", .record = null },
                    .{ .id = "c", .name = "Cee Club", .abbreviation = "CEE", .score = "3", .winner = false, .home_away = "home", .record = null },
                },
            },
            .{
                .id = "3",
                .name = "",
                .starts_at = "2026-09-06T23:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "d", .name = "Dee Club", .abbreviation = "DEE", .score = "", .winner = false, .home_away = "away", .record = "1-1" },
                    .{ .id = "e", .name = "Eee Club", .abbreviation = "EEE", .score = "", .winner = false, .home_away = "home", .record = "2-0" },
                },
            },
        },
        .schema_version = "1",
        .league = "mlb",
        .league_name = "MLB",
    };
}

test "scoreboard prints header plus final in-progress and scheduled rows" {
    const text = try renderScoreboard(std.testing.allocator, cannedBoard());
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "MLB (mlb) — 2026-09-06") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "AWY (10-5) 2 @ HME (12-3) 5  Final") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "BEE 0 @ CEE 3  Top 7th") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "DEE (1-1) @ EEE (2-0)  Scheduled") != null);
}

test "scoreboard resolves sides when only one side is marked" {
    const board = gen.Scoreboard{
        .source = "test",
        .date = "2026-09-06",
        .games = &.{
            .{
                .id = "1",
                .name = "",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away Club", .abbreviation = "AWY", .score = "2", .winner = false, .home_away = "away", .record = null },
                    .{ .id = "h", .name = "Home Club", .abbreviation = "HME", .score = "5", .winner = true, .home_away = null, .record = null },
                },
            },
        },
        .schema_version = "1",
        .league = "mlb",
        .league_name = "MLB",
    };
    const text = try renderScoreboard(std.testing.allocator, board);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "AWY 2 @ HME 5  Final") != null);
}

test "scoreboard falls back on degenerate games" {
    var board = cannedBoard();
    board.games = &.{
        .{
            .id = "9",
            .name = "Solo Contest",
            .starts_at = "2026-09-06T17:00Z",
            .state = "pre",
            .status = "Scheduled",
            .participants = &.{
                .{ .id = "s", .name = "Solo Club", .abbreviation = "SOLO", .score = "", .winner = false, .home_away = null, .record = null },
            },
        },
    };
    const text = try renderScoreboard(std.testing.allocator, board);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Solo Contest  Scheduled") != null);
}

test "degraded digest row renders an outage line not a crash" {
    const digest = gen.DigestJson{
        .date = "2026-09-06",
        .schema_version = "1",
        .degraded = &.{"mlb"},
        .leagues = &.{
            .{
                .source = "test",
                .date = "2026-09-06",
                .games = &.{},
                .schema_version = "1",
                .league = "mlb",
                .league_name = "MLB",
            },
            .{
                .source = "test",
                .date = "2026-09-06",
                .games = &.{
                    .{
                        .id = "7",
                        .name = "",
                        .starts_at = "2026-09-06T17:00Z",
                        .state = "post",
                        .status = "Final",
                        .participants = &.{
                            .{ .id = "a", .name = "Away Club", .abbreviation = "AWY", .score = "2", .winner = false, .home_away = "away", .record = null },
                            .{ .id = "h", .name = "Home Club", .abbreviation = "HME", .score = "5", .winner = true, .home_away = "home", .record = null },
                        },
                    },
                },
                .schema_version = "1",
                .league = "nfl",
                .league_name = "NFL",
            },
        },
    };
    const text = try renderDigest(std.testing.allocator, digest);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "MLB (mlb)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "scores unavailable (upstream outage)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "NFL (nfl)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "AWY 2 @ HME 5  Final") != null);

    // Literal null board plus a slug renders the same outage line.
    const sections = [_]DigestSection{.{
        .slug = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .board = null,
    }};
    const outage = try renderDigestSections(std.testing.allocator, "2026-09-06", &sections);
    defer std.testing.allocator.free(outage);
    try std.testing.expect(std.mem.indexOf(u8, outage, "MLB (mlb)") != null);
    try std.testing.expect(std.mem.indexOf(u8, outage, "scores unavailable (upstream outage)") != null);
}
