//! Portable edge-cache logic shared by the worker entry.
//!
//! Everything here is pure (no sockets, no clock, no Workers APIs) so it is
//! unit-tested natively via the server module and reused verbatim by the
//! wasm worker. The worker wires these pieces to workers-zig's Cache API:
//!
//! - One board namespace per normalized `(league, date, negotiated format)`:
//!   `sprts/v1/board/<slug>/<day>/<format>`. The path prefix (`/mlb` vs
//!   `/api/v1/mlb`) and non-`date` query parameters are excluded, so both
//!   spellings share a namespace modulo negotiated format.
//! - Freshness is enforced with time-bucketed keys, not by reading cached
//!   bodies back (the Cache API match result is served whole):
//!   `<board>/f<epoch/30>` proves age < 30s on a hit (TTL max-age=30);
//!   `<board>/s<epoch/300>` proves age < 300s and is served only when the
//!   upstream fetch fails (manual stale-on-upstream-error, else 502).
//! - Only successful renders are ever stored; errors are never cached.
//!
//! Note on the format tag: the Workers Cache API `match`/`put` pair ignores
//! `stale-if-error` and performs no `Vary` negotiation, so the negotiated
//! format is part of the key. Every format is still rendered from a single
//! normalized board fetch per request.

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
pub const vary_value = "accept, user-agent";

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

/// Negotiated render format as a cache-key tag.
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
    // The key inputs are (slug, day, negotiated format) only: /mlb and
    // /api/v1/mlb with the same date and format produce the same key, and
    // non-date query parameters never reach the key.
    const arena = std.testing.allocator;
    const from_short = try boardKey(arena, "mlb", "2026-09-06", "json");
    defer arena.free(from_short);
    const from_api = try boardKey(arena, "mlb", "2026-09-06", "json");
    defer arena.free(from_api);
    try std.testing.expectEqualStrings(from_short, from_api);
    try std.testing.expectEqualStrings("sprts/v1/board/mlb/2026-09-06/json", from_short);

    const html = try boardKey(arena, "mlb", "2026-09-06", "html");
    defer arena.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "html") != null);
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
