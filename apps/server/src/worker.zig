//! Cloudflare Worker entry for sprts (wasm32+wasi, JSPI).
//!
//! Maps each Worker request to its target path+query, routes via the shared
//! `router.parse`, serves scoreboards through `EspnAdapter` with a
//! `WorkerTransport` + Workers Cache API edge cache, and renders with the
//! shared `render`/`spec` modules. Every human route returns plain text;
//! JSON lives under `/api/v1/` only.
//!
//! Worker notes:
//! - `workers.fetch` / `Cache.match` / `Cache.put` are JSPI-suspending but
//!   present a synchronous Zig interface, matching `espn.HttpTransport`.
//! - Outbound ESPN reads send the ESPN curl UA + `accept: application/json`
//!   (see `edge_cache.upstreamHeaders`; header construction is unit-tested
//!   natively since live header delivery can only be observed on deploy).
//! - The edge cache is keyed on the normalized board (lowercase league slug +
//!   concrete day + format; see `edge_cache.zig`). Fresh hits
//!   (same 30s bucket) are served directly; on upstream failure a stale entry
//!   from the current 300s bucket is served, else 502. Errors are never
//!   cached. All formats render from a single normalized board fetch.
//!   Render flags stay out of the key: `?color`/`?width`/`?height` are
//!   applied after the fetch.
//! - Color defaults to on; `?color=0` turns it off and `?color=1` forces it
//!   on. A `NO_COLOR` worker env var flips the default off.
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
const detail_view = @import("detail_view.zig");
const team_view = @import("team_view.zig");
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

    const method = request.method();
    if (method != .GET and method != .HEAD) {
        var resp = workers.Response.new();
        resp.setStatus(.method_not_allowed);
        resp.setHeader("content-type", "text/plain; charset=utf-8");
        resp.setHeader("allow", "GET, HEAD");
        resp.setBody("method not allowed\n");
        return resp;
    }

    const format = router.formatFor(target, accept);

    switch (router.parse(target)) {
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
        .home => |color| {
            const body = switch (format) {
                .text => try render.home(alloc, color orelse try colorDefault(env)),
                .html => try render.homeHtml(alloc),
                .json => try render.leaguesJson(alloc),
            };
            return staticResponse(body, contentType(format), null);
        },
        .leagues => {
            const body = try render.leaguesJson(alloc);
            return staticResponse(body, contentType(.json), null);
        },
        .bad_date => return errorResponse(alloc, "date must be YYYY-MM-DD", format, .bad_request),
        .not_found => return errorResponse(alloc, "route not found", format, .not_found),
        .scoreboard => |route| return serveBoard(env, alloc, route, format),
        .game => |route| return serveDetail(env, alloc, route, format),
        .team => |route| return serveTeam(env, alloc, route, format),
    }
}

/// Worker color default: on unless the `NO_COLOR` env var is set.
/// A remote client's own environment never reaches us; `?color` is the
/// remote switch.
fn colorDefault(env: *workers.Env) !bool {
    return (try env.get("NO_COLOR")) == null;
}

fn serveBoard(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.ScoreboardRoute,
    format: router.Format,
) !workers.Response {
    const color = route.color orelse try colorDefault(env);
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };

    // Canonicalize: lowercase slug, concrete day (missing ?date resolves via
    // todayFromEpoch), path prefix and non-date query excluded from the key.
    const epoch_s = epochSecondsNow();
    const slug = try edge.canonicalSlug(alloc, league.slug);
    const day = try edge.resolveDay(alloc, route.date, epoch_s);
    const tag = edge.formatTag(format);
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
        return errorResponse(alloc, "scores are temporarily unavailable", format, .bad_gateway);
    };
    const body = switch (format) {
        .text => try render.text(alloc, board, color, route.width, route.height),
        .html => try render.scoreHtml(alloc, board, route.width, route.height),
        .json => try render.json(alloc, board),
    };

    var resp = boardResponse(body, format, "miss");

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

/// Game detail (wt-detail): same edge-cache scheme as the board, keyed on
/// `detail/<slug>/<id>/<format>` (fresh 30s bucket, stale 300s on upstream
/// error). Unknown game ids are 404; upstream failures are 502; errors are
/// never cached. Render flags stay out of the key.
fn serveDetail(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.GameRoute,
    format: router.Format,
) !workers.Response {
    const color = route.color orelse try colorDefault(env);
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };

    const epoch_s = epochSecondsNow();
    const slug = try edge.canonicalSlug(alloc, league.slug);
    const tag = edge.formatTag(format);
    const detail_key = try edge.detailKey(alloc, slug, route.id, tag);
    const fresh_key = try edge.detailFreshKey(alloc, detail_key, epoch_s);
    const stale_key = try edge.detailStaleKey(alloc, detail_key, epoch_s);

    const cache = workers.Cache.default();

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

    const game_detail = adapter.fetchDetail(alloc, league, route.id) catch |err| switch (err) {
        error.GameNotFound => return errorResponse(alloc, "game not found", format, .not_found),
        else => {
            workers.log("upstream ESPN detail fetch failed for {s} {s}", .{ slug, route.id });
            if (cache.match(.{ .url = stale_key })) |stale| {
                var resp = stale.clone();
                resp.setHeader("cache-control", edge.client_cache_control);
                resp.setHeader("x-sprts-cache", "stale");
                return resp;
            }
            return errorResponse(alloc, "scores are temporarily unavailable", format, .bad_gateway);
        },
    };
    const body = switch (format) {
        .text => try detail_view.renderText(alloc, game_detail, color, route.width, route.height),
        .html => try detail_view.detailHtml(alloc, game_detail, route.width, route.height),
        .json => try detail_view.json(alloc, game_detail),
    };

    var resp = boardResponse(body, format, "miss");

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

/// Team view through the edge cache. Mirrors `serveBoard` with the team
/// key scheme (see edge_cache.zig): one normalized `fetchTeam` per request,
/// every format rendered from it; fresh 60s bucket served directly, stale
/// 600s bucket on upstream failure (else 502), errors never cached.
/// Unknown abbrev (`error.TeamNotFound`) is a 404, never a cache entry.
fn serveTeam(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.TeamRoute,
    format: router.Format,
) !workers.Response {
    const color = route.color orelse try colorDefault(env);
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };

    const epoch_s = epochSecondsNow();
    const slug = try edge.canonicalSlug(alloc, league.slug);
    const abbr = try edge.canonicalAbbr(alloc, route.abbr);
    const tag = edge.formatTag(format);
    const key = try edge.teamKey(alloc, slug, abbr, tag);
    const fresh_key = try edge.teamFreshKey(alloc, key, epoch_s);
    const stale_key = try edge.teamStaleKey(alloc, key, epoch_s);

    const cache = workers.Cache.default();

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

    const view = provider.fetchTeam(adapter, alloc, league, route.abbr) catch |err| {
        if (err == error.TeamNotFound) {
            return errorResponse(alloc, "unknown team; see /api/v1/leagues", format, .not_found);
        }
        workers.log("upstream ESPN team fetch failed for {s} {s}", .{ slug, abbr });
        if (cache.match(.{ .url = stale_key })) |stale| {
            var resp = stale.clone();
            resp.setHeader("cache-control", edge.client_cache_control);
            resp.setHeader("x-sprts-cache", "stale");
            return resp;
        }
        return errorResponse(alloc, "scores are temporarily unavailable", format, .bad_gateway);
    };
    const body = switch (format) {
        .text => try team_view.renderText(alloc, view, color, route.width, route.height),
        .html => try team_view.teamHtml(alloc, view, league.slug, route.width, route.height),
        .json => try team_view.renderJson(alloc, view),
    };

    var resp = boardResponse(body, format, "miss");

    var for_fresh = resp.clone();
    cache.put(.{ .url = fresh_key }, &for_fresh);
    var for_stale = resp.clone();
    for_stale.setHeader("cache-control", edge.stale_cache_control);
    for_stale.setHeader("x-sprts-cache", "stale");
    cache.put(.{ .url = stale_key }, &for_stale);
    return resp;
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
