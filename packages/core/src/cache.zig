//! Cache-facing helpers: TTL windows, key canonicalization, and liveness.
//!
//! Portable and pure (no sockets, no clock), so both the native
//! `NativeCache` and the edge key builders share one definition of the
//! windows and the canonical forms. Cache key formats themselves stay
//! with the cache modules; only the inputs' normalization lives here.

const std = @import("std");
const domain = @import("domain.zig");
const detail = @import("detail.zig");

/// Fresh window in seconds (`TTL max-age=30`).
pub const fresh_ttl_s: i64 = 30;
/// Fresh window for live boards/details: any `in` game on the board (or an
/// `in` detail game) refreshes every 10s instead of 30s.
pub const live_fresh_ttl_s: i64 = 10;
/// Stale window in seconds (serve stale on upstream error up to 300s).
pub const stale_ttl_s: i64 = 300;

/// Teams-list window: 24h fresh + 24h stale (resolution barely changes).
pub const teams_fresh_ttl_s: i64 = 24 * 60 * 60;
pub const teams_stale_ttl_s: i64 = 24 * 60 * 60;

/// Schedule window: 60s fresh + 600s stale (game states move; payload heavy).
pub const schedule_fresh_ttl_s: i64 = 60;
pub const schedule_stale_ttl_s: i64 = 600;

/// Lowercase a key component in place. The single lowercasing primitive
/// behind `canonicalSlug`/`canonicalAbbr` (and the stream sub-key scheme).
pub fn lowercase(buf: []u8) void {
    for (buf) |*byte| byte.* = std.ascii.toLower(byte.*);
}

/// Lowercase a league slug for cache-key canonicalization.
pub fn canonicalSlug(arena: std.mem.Allocator, slug: []const u8) ![]u8 {
    const out = try arena.dupe(u8, slug);
    lowercase(out);
    return out;
}

/// Lowercase a team abbreviation for cache-key canonicalization.
pub fn canonicalAbbr(arena: std.mem.Allocator, abbr: []const u8) ![]u8 {
    const out = try arena.dupe(u8, abbr);
    lowercase(out);
    return out;
}

/// True when any game on the board is in progress (`state == "in"`). A
/// mixed board (one live game among finals) counts as live.
pub fn isLiveBoard(board: domain.Scoreboard) bool {
    for (board.games) |game| {
        if (std.mem.eql(u8, game.state, "in")) return true;
    }
    return false;
}

/// True when the detail game is in progress: `state == "in"`, or a live
/// situation is present (the provider only attaches one to `in` games, so
/// both readings agree in practice; either suffices).
pub fn isLiveDetail(game: detail.GameDetail) bool {
    if (std.mem.eql(u8, game.state, "in")) return true;
    return game.situation != null;
}

fn liveTestGame(state: []const u8) domain.Game {
    return .{
        .id = "1",
        .name = "",
        .starts_at = "2026-09-06T17:00Z",
        .state = state,
        .status = if (std.mem.eql(u8, state, "in")) "Top 7th" else "Final",
        .participants = &.{},
    };
}

test "canonicalSlug and canonicalAbbr lowercase their input" {
    const slug = try canonicalSlug(std.testing.allocator, "MLB");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("mlb", slug);
    const abbr = try canonicalAbbr(std.testing.allocator, "PHI");
    defer std.testing.allocator.free(abbr);
    try std.testing.expectEqualStrings("phi", abbr);
}

test "isLiveBoard counts any in-progress game, including mixed boards" {
    const live: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{liveTestGame("in")},
    };
    const final_board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{liveTestGame("post")},
    };
    const mixed: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{ liveTestGame("post"), liveTestGame("in"), liveTestGame("pre") },
    };
    try std.testing.expect(isLiveBoard(live));
    try std.testing.expect(isLiveBoard(mixed));
    try std.testing.expect(!isLiveBoard(final_board));
}

test "isLiveDetail counts an in state or a live situation alone" {
    const live: detail.GameDetail = .{
        .id = "9",
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .state = "in",
        .status = "Bot 6th",
        .participants = &.{},
        .situation = .{ .balls = 2, .strikes = 1, .outs = 1 },
    };
    const final: detail.GameDetail = .{
        .id = "9",
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .participants = &.{},
    };
    const situation_only: detail.GameDetail = .{
        .id = "9",
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .participants = &.{},
        .situation = .{ .balls = 0, .strikes = 0, .outs = 2 },
    };
    try std.testing.expect(isLiveDetail(live));
    try std.testing.expect(isLiveDetail(situation_only));
    try std.testing.expect(!isLiveDetail(final));
}
