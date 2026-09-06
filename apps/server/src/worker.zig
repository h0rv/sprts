//! Cloudflare Worker entry for sprts (wasm32+wasi, JSPI).
//!
//! Maps each Worker request to `(target path+query, accept, user-agent)`,
//! routes via the shared `router.parse`, serves scoreboards through
//! `EspnAdapter` with a `WorkerTransport` + Workers Cache API edge cache, and
//! renders with the shared `render`/`spec` modules.
//!
//! Worker notes:
//! - `workers.fetch` / `Cache.match` / `Cache.put` are JSPI-suspending but
//!   present a synchronous Zig interface, matching `espn.HttpTransport`.
//! - Outbound ESPN reads send the ESPN curl UA + `accept: application/json`
//!   (see `edge_cache.upstreamHeaders`; header construction is unit-tested
//!   natively since live header delivery can only be observed on deploy).
//! - The edge cache is keyed on the normalized board (lowercase league slug +
//!   concrete day + negotiated format; see `edge_cache.zig`). Fresh hits
//!   (same 30s bucket) are served directly; on upstream failure a stale entry
//!   from the current 300s bucket is served, else 502. Errors are never
//!   cached. All formats render from a single normalized board fetch.
//! - Allocation is per-request via `env.allocator` only. This module never
//!   imports `main.zig`: no `std.http.Server`, sockets, threads, or system
//!   clock in the worker path (epoch seconds come from `workers.now()`).
//! - zchema arrives as the stock root module compiled for wasm (per-file
//!   granularity is unexpressible: Zig requires one-file-one-module and
//!   zchema's sources import each other relatively). Only the portable entry
//!   points are ever reached (`serializeAndValidate`, `openApiJson`, `Spec`,
//!   `endpoint`, `case`, `ErrorBody`); `std.http.Server` appears in that
//!   code solely as parameter/return types, never sockets or threads.

const std = @import("std");
const workers = @import("workers-zig");
const core = @import("sprts_core");
const espn = @import("espn_client");

const router = @import("router.zig");
const render = @import("render.zig");
const spec = @import("spec.zig");
const provider = @import("provider.zig");
const edge = @import("edge_cache.zig");

const default_base_url = "https://site.api.espn.com/apis/site/v2";

/// Outbound ESPN transport over workers-zig fetch.
/// `workers.fetch` suspends on JSPI and resumes with the full response, so
/// this satisfies the sync-style `espn.HttpTransport` seam directly.
const WorkerTransport = struct {
    fn dispatch(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) anyerror!espn.FetchResult {
        _ = ptr;
        const headers = try edge.upstreamHeaders(arena, extra_headers);
        var upstream = try workers.fetch(arena, url, .{ .method = .GET, .headers = headers });
        defer upstream.deinit();
        return .{
            .status = upstream.status(),
            .body = try arena.dupe(u8, try upstream.bytes()),
        };
    }

    fn asTransport(self: *WorkerTransport) espn.HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

/// Adapter clock: `workers.now()` is `Date.now()` in milliseconds.
fn workerClock(_: std.Io) i64 {
    return @intFromFloat(@floor(workers.now() / 1000.0));
}

fn epochSecondsNow() i64 {
    return @intFromFloat(@floor(workers.now() / 1000.0));
}

/// First case-insensitive match for an incoming request header.
fn incomingHeader(request: *const workers.Request, name: []const u8) !?[]const u8 {
    const entries = try request.headers();
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
    }
    return null;
}

pub fn fetch(request: *workers.Request, env: *workers.Env, _: *workers.Context) !workers.Response {
    // Per-request arena; freed automatically when the request ends.
    const alloc = env.allocator;

    const target = edge.targetFromUrl(try request.url());
    // NOTE: workers-zig's Request.header() does not compile (it returns an
    // `![]const u8` error union where `!?[]const u8` is declared), so scan
    // the headers() entries instead.
    const accept = (try incomingHeader(request, "accept")) orelse "";
    const user_agent = (try incomingHeader(request, "user-agent")) orelse "";

    const method = request.method();
    if (method != .GET and method != .HEAD) {
        var resp = workers.Response.new();
        resp.setStatus(.method_not_allowed);
        resp.setHeader("content-type", "text/plain; charset=utf-8");
        resp.setHeader("allow", "GET, HEAD");
        resp.setBody("method not allowed\n");
        return resp;
    }

    switch (router.parse(target, accept, user_agent)) {
        .health => {
            var resp = workers.Response.new();
            resp.setStatus(.ok);
            resp.setHeader("content-type", "text/plain; charset=utf-8");
            resp.setHeader("cache-control", "no-store");
            resp.setBody("ok\n");
            return resp;
        },
        .openapi => {
            const body = try spec.openApiJson(alloc);
            return staticResponse(body, contentType(.json), null);
        },
        .home => |format| {
            const body = try render.home(alloc, format);
            return staticResponse(body, contentType(format), null);
        },
        .leagues => {
            const body = try render.leaguesJson(alloc);
            return staticResponse(body, contentType(.json), null);
        },
        .bad_date => return errorResponse(alloc, "date must be YYYY-MM-DD", .text, .bad_request),
        .not_found => return errorResponse(alloc, "route not found", .text, .not_found),
        .scoreboard => |route| return serveBoard(env, alloc, route),
    }
}

fn serveBoard(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.ScoreboardRoute,
) !workers.Response {
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", route.format, .not_found);
    };

    // Canonicalize: lowercase slug, concrete day (missing ?date resolves via
    // todayFromEpoch), path prefix and non-date query excluded from the key.
    const epoch_s = epochSecondsNow();
    const slug = try edge.canonicalSlug(alloc, league.slug);
    const day = try edge.resolveDay(alloc, route.date, epoch_s);
    const tag = edge.formatTag(route.format);
    const board_key = try edge.boardKey(alloc, slug, day, tag);
    const fresh_key = try edge.freshKey(alloc, board_key, epoch_s);
    const stale_key = try edge.staleKey(alloc, board_key, epoch_s);

    const cache = workers.Cache.default();

    // Fresh hit: same 30s bucket, so age < 30s. Serve the stored render.
    if (cache.match(.{ .url = fresh_key })) |hit| {
        var resp = hit.clone();
        resp.setHeader("cache-control", edge.client_cache_control);
        resp.setHeader("x-sprts-cache", "hit");
        return resp;
    }

    var transport_state = WorkerTransport{};
    const base_url = (try env.get("SPRTS_ESPN_BASE_URL")) orelse default_base_url;
    const adapter = provider.EspnAdapter{
        .allocator = alloc,
        .io = workers.io(),
        .base_url = base_url,
        .transport = transport_state.asTransport(),
        .clock = workerClock,
    };

    // Single normalized board fetch; every format renders from this board.
    const board = adapter.fetch(alloc, league, day) catch {
        workers.log("upstream ESPN fetch failed for {s} {s}", .{ slug, day });
        // Manual stale-on-upstream-error: same 300s bucket, so age < 300s.
        if (cache.match(.{ .url = stale_key })) |stale| {
            var resp = stale.clone();
            resp.setHeader("cache-control", edge.client_cache_control);
            resp.setHeader("x-sprts-cache", "stale");
            return resp;
        }
        return errorResponse(alloc, "scores are temporarily unavailable", route.format, .bad_gateway);
    };
    const body = switch (route.format) {
        .text => try render.text(alloc, board),
        .html => try render.html(alloc, board),
        .json => try render.json(alloc, board),
    };

    var resp = boardResponse(body, route.format, "miss");

    // Store fresh (30s retention) + stale (300s retention) renders.
    // Only successful renders reach this point, so errors are never cached.
    var for_fresh = resp.clone();
    cache.put(.{ .url = fresh_key }, &for_fresh);
    var for_stale = resp.clone();
    for_stale.setHeader("cache-control", edge.stale_cache_control);
    for_stale.setHeader("x-sprts-cache", "stale");
    cache.put(.{ .url = stale_key }, &for_stale);
    return resp;
}

fn contentType(format: router.Format) []const u8 {
    return switch (format) {
        .text => "text/plain; charset=utf-8",
        .html => "text/html; charset=utf-8",
        .json => "application/json; charset=utf-8",
    };
}

/// Non-board responses (static renders + errors): shared cache headers for
/// downstream parity with the native server, never written to the edge cache.
fn staticResponse(body: []const u8, content_type: []const u8, cache_state: ?[]const u8) workers.Response {
    var resp = workers.Response.new();
    resp.setStatus(.ok);
    resp.setHeader("content-type", content_type);
    resp.setHeader("cache-control", edge.client_cache_control);
    resp.setHeader("vary", edge.vary_value);
    resp.setHeader("x-content-type-options", "nosniff");
    if (cache_state) |state| resp.setHeader("x-sprts-cache", state);
    resp.setBody(body);
    return resp;
}

fn boardResponse(body: []const u8, format: router.Format, cache_state: []const u8) workers.Response {
    return staticResponse(body, contentType(format), cache_state);
}

fn errorResponse(
    alloc: std.mem.Allocator,
    message: []const u8,
    format: router.Format,
    status: std.http.Status,
) !workers.Response {
    const body = try render.errorBody(alloc, message, format);
    var resp = staticResponse(body, contentType(format), null);
    resp.setStatus(status);
    return resp;
}
