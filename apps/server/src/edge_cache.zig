//! Portable edge-cache logic shared by the worker entry.
//!
//! Everything here is pure (no sockets, no clock, no Workers APIs) so it is
//! unit-tested natively via the server module and reused verbatim by the
//! wasm worker. The worker wires these pieces to workers-zig's Cache API:
//!
//! - One board namespace per `(league, date, format)`:
//!   `sprts/v1/board/<slug>/<day>/<format>`. The path prefix (`/mlb` vs
//!   `/api/v1/mlb`) and non-`date` query parameters are excluded, so both
//!   spellings share a namespace modulo format.
//! - Freshness is enforced with time-bucketed keys, not by reading cached
//!   bodies back (the Cache API match result is served whole):
//!   `<board>/f<epoch/30>` proves age < 30s on a hit (TTL max-age=30);
//!   `<board>/s<epoch/300>` proves age < 300s and is served only when the
//!   upstream fetch fails (manual stale-on-upstream-error, else 502).
//! - Only successful renders are ever stored; errors are never cached.
//!
//! Note on the format tag: the Workers Cache API `match`/`put` pair ignores
//! `stale-if-error`, so the format is part of the key. Every format is still
//! rendered from a single normalized board fetch per request. The format
//! varies by address and Accept header, so responses carry `Vary: accept`.

const std = @import("std");
const core = @import("sprts_core");
const espn = @import("espn_client");
const router = @import("router.zig");

/// Fresh window in seconds (`TTL max-age=30`).
pub const fresh_ttl_s: i64 = 30;
/// Stale window in seconds (serve stale on upstream error up to 300s).
pub const stale_ttl_s: i64 = 300;

/// Client-facing cache header; mirrors the native server's common headers.
/// (The Cache API ignores `stale-if-error` on match/put, hence the manual
/// stale path above; downstream HTTP caches still honor it.)
pub const client_cache_control = "public, max-age=30, stale-if-error=300";
pub const vary_value = "accept";

/// Retention headers stored on fresh/stale edge entries so old time buckets
/// can be reaped by the edge.
pub const fresh_cache_control = "public, max-age=30";
pub const stale_cache_control = "public, max-age=300";

/// Strip scheme + authority from a Worker request URL, returning path+query.
/// `"https://sprts.horv.co/mlb?date=2026-09-06"` -> `"/mlb?date=2026-09-06"`.
/// Returns `"/"` when the URL carries no path.
pub fn targetFromUrl(url: []const u8) []const u8 {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |at| url[at + 3 ..] else url;
    if (std.mem.indexOfScalar(u8, after_scheme, '/')) |slash| return after_scheme[slash..];
    return "/";
}

/// Lowercase a league slug for cache-key canonicalization.
pub fn canonicalSlug(arena: std.mem.Allocator, slug: []const u8) ![]u8 {
    const out = try arena.dupe(u8, slug);
    for (out) |*byte| byte.* = std.ascii.toLower(byte.*);
    return out;
}

/// Resolve the board day: an explicit `?date` is used verbatim (the router
/// already validated it); otherwise derive today from epoch seconds.
pub fn resolveDay(arena: std.mem.Allocator, date: ?[]const u8, epoch_s: i64) ![]u8 {
    if (date) |day| return arena.dupe(u8, day);
    return core.date.todayFromEpoch(arena, epoch_s);
}

/// Render format as a cache-key tag. The address and Accept header decide it.
pub fn formatTag(format: router.Format) []const u8 {
    return switch (format) {
        .text => "text",
        .html => "html",
        .json => "json",
    };
}

/// Board namespace: `sprts/v1/board/<slug>/<day>/<format>`.
pub fn boardKey(arena: std.mem.Allocator, slug: []const u8, day: []const u8, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "sprts/v1/board/{s}/{s}/{s}", .{ slug, day, tag });
}

/// Fresh key: board key + 30s bucket. A hit in the current bucket proves the
/// entry is less than 30s old.
pub fn freshKey(arena: std.mem.Allocator, board_key: []const u8, epoch_s: i64) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/f{d}", .{ board_key, @divFloor(epoch_s, fresh_ttl_s) });
}

/// Stale key: board key + 300s bucket. A hit in the current bucket proves the
/// entry is less than 300s old.
pub fn staleKey(arena: std.mem.Allocator, board_key: []const u8, epoch_s: i64) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/s{d}", .{ board_key, @divFloor(epoch_s, stale_ttl_s) });
}

/// Upstream request headers: the ESPN curl UA plus `accept: application/json`,
/// then caller extras (deduped so a caller-supplied accept/user-agent cannot
/// shadow the ESPN workaround). Pure so header survival is unit-testable;
/// WorkerTransport sends the result verbatim via workers-zig fetch.
pub fn upstreamHeaders(arena: std.mem.Allocator, extra: []const std.http.Header) ![]std.http.Header {
    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.append(arena, .{ .name = "user-agent", .value = espn.user_agent });
    try headers.append(arena, .{ .name = "accept", .value = espn.accept_json_value });
    for (extra) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "accept")) continue;
        try headers.append(arena, header);
    }
    return headers.toOwnedSlice(arena);
}

test "targetFromUrl strips origin and keeps path plus query" {
    try std.testing.expectEqualStrings("/mlb?date=2026-09-06", targetFromUrl("https://sprts.horv.co/mlb?date=2026-09-06"));
    try std.testing.expectEqualStrings("/api/v1/mlb", targetFromUrl("http://localhost:8080/api/v1/mlb"));
    try std.testing.expectEqualStrings("/", targetFromUrl("https://sprts.horv.co"));
    try std.testing.expectEqualStrings("/", targetFromUrl("https://sprts.horv.co?date=2026-09-06"));
    try std.testing.expectEqualStrings("/mlb", targetFromUrl("/mlb"));
}

test "canonicalSlug lowercases the league slug" {
    const slug = try canonicalSlug(std.testing.allocator, "MLB");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("mlb", slug);
}

test "resolveDay prefers explicit date and otherwise uses epoch" {
    const explicit = try resolveDay(std.testing.allocator, "2026-09-06", 1788739200);
    defer std.testing.allocator.free(explicit);
    try std.testing.expectEqualStrings("2026-09-06", explicit);

    const derived = try resolveDay(std.testing.allocator, null, 1788739200);
    defer std.testing.allocator.free(derived);
    try std.testing.expectEqualStrings("2026-09-07", derived);
}

test "board keys unify path spellings and strip non-date query" {
    // The key inputs are (slug, day, format) only: /mlb and
    // /api/v1/mlb with the same date and format produce the same key, and
    // non-date query parameters never reach the key.
    const arena = std.testing.allocator;
    const from_short = try boardKey(arena, "mlb", "2026-09-06", "json");
    defer arena.free(from_short);
    const from_api = try boardKey(arena, "mlb", "2026-09-06", "json");
    defer arena.free(from_api);
    try std.testing.expectEqualStrings(from_short, from_api);
    try std.testing.expectEqualStrings("sprts/v1/board/mlb/2026-09-06/json", from_short);

    const text = try boardKey(arena, "mlb", "2026-09-06", "text");
    defer arena.free(text);
    try std.testing.expect(!std.mem.eql(u8, text, from_short));

    const html = try boardKey(arena, "mlb", "2026-09-06", "html");
    defer arena.free(html);
    try std.testing.expect(!std.mem.eql(u8, html, from_short));
}

test "fresh and stale buckets bound entry age" {
    const arena = std.testing.allocator;
    const board = try boardKey(arena, "mlb", "2026-09-06", "json");
    defer arena.free(board);

    const fresh_start = try freshKey(arena, board, 0);
    defer arena.free(fresh_start);
    const fresh_end = try freshKey(arena, board, 29);
    defer arena.free(fresh_end);
    const fresh_next = try freshKey(arena, board, 30);
    defer arena.free(fresh_next);
    try std.testing.expectEqualStrings(fresh_start, fresh_end);
    try std.testing.expect(!std.mem.eql(u8, fresh_start, fresh_next));

    const stale_start = try staleKey(arena, board, 0);
    defer arena.free(stale_start);
    const stale_end = try staleKey(arena, board, 299);
    defer arena.free(stale_end);
    const stale_next = try staleKey(arena, board, 300);
    defer arena.free(stale_next);
    try std.testing.expectEqualStrings(stale_start, stale_end);
    try std.testing.expect(!std.mem.eql(u8, stale_start, stale_next));
}

test "upstreamHeaders always carries the ESPN UA and JSON accept" {
    const arena = std.testing.allocator;
    const headers = try upstreamHeaders(arena, espn.default_headers);
    defer arena.free(headers);
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    var seen_ua = false;
    var seen_accept = false;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) {
            seen_ua = true;
            try std.testing.expectEqualStrings(espn.user_agent, header.value);
        }
        if (std.ascii.eqlIgnoreCase(header.name, "accept")) {
            seen_accept = true;
            try std.testing.expectEqualStrings(espn.accept_json_value, header.value);
        }
    }
    try std.testing.expect(seen_ua and seen_accept);
}

// ---- Per-team view keys (append-only; board fns above are untouched) ----
//
// Cache scheme mirrors the board's fresh + stale bucketing, with windows
// tuned per upstream cost and change rate:
//
// - teams-list: the abbreviation→id resolution. Changes only when ESPN adds
//   or renames teams, so it sits in a LONG 24h namespace
//   (`sprts/v1/teams/<slug>` + 24h buckets). Never shorter than the board
//   TTLs; resolution churn is nil compared to scores.
// - schedule: a full season of one team (~60s fresh + 600s stale buckets).
//   Fresher than the teams list because game states move, but a longer
//   stale window than the board: the view still renders usefully stale
//   (last/next barely move in 10 minutes) and the schedule payload is heavy.
// - team JSON render: cached per `(slug, abbr, format)` like the board
//   namespace so text/html/json share one normalized TeamView fetch per
//   request. The league slug and abbrev are lowercased before keying.

/// Teams-list window: 24h fresh + 24h stale (resolution barely changes).
pub const teams_fresh_ttl_s: i64 = 24 * 60 * 60;
pub const teams_stale_ttl_s: i64 = 24 * 60 * 60;

/// Schedule window: 60s fresh + 600s stale (game states move; payload heavy).
pub const schedule_fresh_ttl_s: i64 = 60;
pub const schedule_stale_ttl_s: i64 = 600;

/// Lowercase a team abbreviation for cache-key canonicalization.
pub fn canonicalAbbr(arena: std.mem.Allocator, abbr: []const u8) ![]u8 {
    const out = try arena.dupe(u8, abbr);
    for (out) |*byte| byte.* = std.ascii.toLower(byte.*);
    return out;
}

/// Teams-list namespace: `sprts/v1/teams/<slug>`.
pub fn teamsKey(arena: std.mem.Allocator, slug: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "sprts/v1/teams/{s}", .{slug});
}

/// Teams-list fresh key: 24h bucket; a hit proves age < 24h.
pub fn teamsFreshKey(arena: std.mem.Allocator, teams_key: []const u8, epoch_s: i64) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/f{d}", .{ teams_key, @divFloor(epoch_s, teams_fresh_ttl_s) });
}

/// Teams-list stale key: 24h bucket for upstream-error fallback.
pub fn teamsStaleKey(arena: std.mem.Allocator, teams_key: []const u8, epoch_s: i64) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/s{d}", .{ teams_key, @divFloor(epoch_s, teams_stale_ttl_s) });
}

/// Schedule namespace: `sprts/v1/schedule/<slug>/<abbr>/<season>`.
pub fn scheduleKey(arena: std.mem.Allocator, slug: []const u8, abbr: []const u8, season: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "sprts/v1/schedule/{s}/{s}/{s}", .{ slug, abbr, season });
}

/// Schedule fresh key: 60s bucket; a hit proves age < 60s.
pub fn scheduleFreshKey(arena: std.mem.Allocator, schedule_key: []const u8, epoch_s: i64) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/f{d}", .{ schedule_key, @divFloor(epoch_s, schedule_fresh_ttl_s) });
}

/// Schedule stale key: 600s bucket, served on upstream failure (else 502).
pub fn scheduleStaleKey(arena: std.mem.Allocator, schedule_key: []const u8, epoch_s: i64) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/s{d}", .{ schedule_key, @divFloor(epoch_s, schedule_stale_ttl_s) });
}

/// Team render namespace: `sprts/v1/team/<slug>/<abbr>/<format>`.
/// Render flags stay out of the key (`?color`/`?width`/`?height` apply after
/// the fetch); non-JSON formats share the normalized fetch modulo format.
pub fn teamKey(arena: std.mem.Allocator, slug: []const u8, abbr: []const u8, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "sprts/v1/team/{s}/{s}/{s}", .{ slug, abbr, tag });
}

/// Team fresh key: same 60s window as the schedule (renders track it).
pub fn teamFreshKey(arena: std.mem.Allocator, team_key: []const u8, epoch_s: i64) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/f{d}", .{ team_key, @divFloor(epoch_s, schedule_fresh_ttl_s) });
}

/// Team stale key: same 600s window as the schedule.
pub fn teamStaleKey(arena: std.mem.Allocator, team_key: []const u8, epoch_s: i64) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/s{d}", .{ team_key, @divFloor(epoch_s, schedule_stale_ttl_s) });
}

test "team keys canonicalize slug and abbrev" {
    const arena = std.testing.allocator;
    const slug = try canonicalSlug(arena, "MLB");
    defer arena.free(slug);
    const abbr = try canonicalAbbr(arena, "PHI");
    defer arena.free(abbr);
    const key = try teamKey(arena, slug, abbr, "json");
    defer arena.free(key);
    try std.testing.expectEqualStrings("sprts/v1/team/mlb/phi/json", key);

    const teams = try teamsKey(arena, slug);
    defer arena.free(teams);
    try std.testing.expectEqualStrings("sprts/v1/teams/mlb", teams);

    const sched = try scheduleKey(arena, slug, abbr, "2026");
    defer arena.free(sched);
    try std.testing.expectEqualStrings("sprts/v1/schedule/mlb/phi/2026", sched);
}

test "team buckets bound entry age" {
    const arena = std.testing.allocator;
    const teams = try teamsKey(arena, "mlb");
    defer arena.free(teams);
    const teams_a = try teamsFreshKey(arena, teams, 0);
    defer arena.free(teams_a);
    const teams_b = try teamsFreshKey(arena, teams, teams_fresh_ttl_s - 1);
    defer arena.free(teams_b);
    const teams_c = try teamsFreshKey(arena, teams, teams_fresh_ttl_s);
    defer arena.free(teams_c);
    try std.testing.expectEqualStrings(teams_a, teams_b);
    try std.testing.expect(!std.mem.eql(u8, teams_a, teams_c));

    const sched = try scheduleKey(arena, "mlb", "phi", "2026");
    defer arena.free(sched);
    const fresh_a = try scheduleFreshKey(arena, sched, 0);
    defer arena.free(fresh_a);
    const fresh_b = try scheduleFreshKey(arena, sched, 59);
    defer arena.free(fresh_b);
    const fresh_c = try scheduleFreshKey(arena, sched, 60);
    defer arena.free(fresh_c);
    try std.testing.expectEqualStrings(fresh_a, fresh_b);
    try std.testing.expect(!std.mem.eql(u8, fresh_a, fresh_c));

    const stale_a = try scheduleStaleKey(arena, sched, 0);
    defer arena.free(stale_a);
    const stale_b = try scheduleStaleKey(arena, sched, 599);
    defer arena.free(stale_b);
    const stale_c = try scheduleStaleKey(arena, sched, 600);
    defer arena.free(stale_c);
    try std.testing.expectEqualStrings(stale_a, stale_b);
    try std.testing.expect(!std.mem.eql(u8, stale_a, stale_c));
}
