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
const stream = @import("stream.zig");

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
    const host = render.sanitizeHost(try incomingHeader(request, "host"));

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
        .home => |home_route| {
            var transport_state = WorkerTransport{};
            const base_url = (try env.get("SPRTS_ESPN_BASE_URL")) orelse default_base_url;
            const adapter = provider.EspnAdapter{
                .allocator = alloc,
                .io = workers.io(),
                .base_url = base_url,
                .transport = transport_state.asTransport(),
                .clock = workerClock,
            };
            const day = try edge.resolveDay(alloc, null, epochSecondsNow());
            const boards = try adapter.fetchAll(alloc, day);
            defer provider.EspnAdapter.releaseAll(boards);
            const color = home_route.color orelse try colorDefault(env);
            const body = switch (format) {
                .text => if (home_route.oneline)
                    try render.homeOneLine(alloc, boards, color)
                else
                    try render.homeLive(alloc, color, host, boards, day, home_route.quiet),
                .html => try render.homeHtmlLive(alloc, host, boards, day, home_route.quiet),
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
        .all => |route| return serveAll(env, alloc, route, format),
        .scoreboard => |route| {
            // SSE trigger mirrors main.zig exactly: ?stream= query flag
            // (ScoreboardRoute.stream, filled from the query half by
            // router.parse) OR'd with the Accept: text/event-stream half via
            // router.wantsStream. Text-only: JSON/HTML stream requests get
            // the normal single response. HEAD never streams (an open-ended
            // body makes no sense there): falls back to the single response.
            const wants_sse = route.stream or router.wantsStream(target, accept);
            if (wants_sse and format == .text and method == .GET and route.week == null) {
                return serveStream(env, alloc, route);
            }
            return serveBoard(env, alloc, route, format);
        },
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
    // ?week= threads into fetchWeek directly (never cached: the board key
    // is (slug, day), and a week selector must not poison date entries).
    const board = adapter.fetchWeek(alloc, league, day, route.week) catch {
        workers.log("upstream ESPN fetch failed for {s} {s}", .{ slug, day });
        // Manual stale-on-upstream-error: same 300s bucket, so age < 300s.
        // Week boards skip the stale path (nothing cached under the key).
        if (route.week == null) {
            if (cache.match(.{ .url = stale_key })) |stale| {
                var resp = stale.clone();
                resp.setHeader("cache-control", edge.client_cache_control);
                resp.setHeader("x-sprts-cache", "stale");
                return resp;
            }
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
    // Week boards are never stored (key has no week component).
    if (route.week != null) return resp;
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

fn serveStream(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.ScoreboardRoute,
) !workers.Response {
    const color = route.color orelse try colorDefault(env);
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", .text, .not_found);
    };

    const epoch_s = epochSecondsNow();
    const day = try edge.resolveDay(alloc, route.date, epoch_s);

    var transport_state = WorkerTransport{};
    const base_url = (try env.get("SPRTS_ESPN_BASE_URL")) orelse default_base_url;
    const adapter = provider.EspnAdapter{
        .allocator = alloc,
        .io = workers.io(),
        .base_url = base_url,
        .transport = transport_state.asTransport(),
        .clock = workerClock,
    };

    // Fetch before opening the stream: an unavailable upstream still gets
    // the normal single 502 instead of an empty SSE body (mirrors the
    // native serveSse; errors are never cached).
    const initial = adapter.fetch(alloc, league, day) catch {
        workers.log("upstream ESPN fetch failed for {s} {s}", .{ league.slug, day });
        return errorResponse(alloc, "scores are temporarily unavailable", .text, .bad_gateway);
    };

    // Reuse the shared text render + SSE framing verbatim: full text render
    // (respecting color/width/height) prefixed with the clear-screen escape
    // via stream.frame, so plain `curl -N` repaints in place.
    const initial_text = try render.text(alloc, initial, color, route.width, route.height);
    const initial_frame = try stream.frame(alloc, initial_text);

    var sse = workers.StreamingResponse.start(.{ .status = .ok });
    sse.setHeader("content-type", stream.content_type);
    sse.setHeader("cache-control", stream.cache_control);
    sse.setHeader("connection", "keep-alive");
    sse.setHeader("vary", edge.vary_value);
    sse.setHeader("x-content-type-options", "nosniff");
    sse.write(initial_frame);

    var last = stream.fingerprint(initial);
    var interval_s = stream.pollIntervalSec(initial);
    var elapsed_s: u64 = 0;
    const tick_s: u64 = 1;

    // Bounded loop, not `while (true)`: a bare infinite loop makes this
    // function's inferred error set infinite, which callers cannot name or
    // handle. The worker has no client-disconnect signal to break on anyway
    // (writes only surface errors at close). The final-slate cadence (300s)
    // bounds real duration; ~6h of 1s ticks covers a live game at 12s polls.
    // Each iteration is one JSPI sleep + at most one ESPN fetch.
    const max_ticks: u64 = 6 * 60 * 60;
    var tick: u64 = 0;
    while (tick < max_ticks) : (tick += 1) {
        workers.sleep(@intCast(tick_s * 1000));
        elapsed_s += tick_s;

        if (elapsed_s % stream.keepalive_s == 0) {
            sse.write(stream.keepalive_frame);
        }

        if (elapsed_s < interval_s) continue;
        elapsed_s = 0;

        const board = adapter.fetch(alloc, league, day) catch |err| {
            workers.log("upstream ESPN fetch failed for {s}: {any}", .{ league.slug, err });
            continue;
        };
        interval_s = stream.pollIntervalSec(board);
        const current = stream.fingerprint(board);
        if (!stream.changed(last, current)) continue;
        last = current;
        const body = render.text(alloc, board, color, route.width, route.height) catch continue;
        const event = stream.frame(alloc, body) catch continue;
        sse.write(event);
        // Per-request arena memory grows with each tick's render; the outer
        // entry arena is freed when the request ends, and frames for a
        // final-slate resource stop changing (300s cadence, fingerprint
        // stable), so steady-state allocation is bounded in practice.
    }

    sse.close();
    return sse.response();
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

/// Multi-league digest: `/all?date=` (and `/api/v1/all?date=` JSON).
/// One normalized fetch per league (same per-league edge-cache scheme as
/// serveBoard: fresh 30s hit served directly, stale 300s on upstream
/// failure with the section marked unavailable, else the league renders
/// unavailable); one league's outage never fails the digest. Bounded by
/// the league set with a per-league game cap in the renderer. Date-driven
/// only: no week fan-out.
fn serveAll(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.AllRoute,
    format: router.Format,
) !workers.Response {
    const digest = @import("digest.zig");
    const color = route.color orelse try colorDefault(env);
    const epoch_s = epochSecondsNow();
    var transport_state = WorkerTransport{};
    const base_url = (try env.get("SPRTS_ESPN_BASE_URL")) orelse default_base_url;
    const adapter = provider.EspnAdapter{
        .allocator = alloc,
        .io = workers.io(),
        .base_url = base_url,
        .transport = transport_state.asTransport(),
        .clock = workerClock,
    };
    const day = try edge.resolveDay(alloc, route.date, epoch_s);
    const tag = edge.formatTag(format);
    const sections = try alloc.alloc(digest.DigestSection, core.leagues.all.len);
    const cache = workers.Cache.default();
    for (&core.leagues.all, 0..) |*league, i| {
        sections[i] = .{ .league = league };
        const slug = try edge.canonicalSlug(alloc, league.slug);
        const board_key = try edge.boardKey(alloc, slug, day, tag);
        const fresh_key = try edge.freshKey(alloc, board_key, epoch_s);
        const stale_key = try edge.staleKey(alloc, board_key, epoch_s);
        _ = stale_key;
        // Edge stores renders, not boards, so the digest always does one
        // normalized fetch per league and refreshes that league's edge
        // entries from it. A fresh hit still saves nothing here — the
        // render below is the digest composition, not the league render —
        // but the per-league put() keeps single-league routes warm.
        _ = cache.match(.{ .url = fresh_key });
        const board = adapter.fetch(alloc, league, day) catch {
            // One league's outage never fails the digest: mark the
            // section unavailable and keep the others.
            sections[i].board = null;
            continue;
        };
        sections[i].board = board;
        // Refresh per-league edge entries from the normalized board.
        const body = switch (format) {
            .text => render.text(alloc, board, color, route.width, route.height) catch continue,
            .html => render.scoreHtml(alloc, board, route.width, route.height) catch continue,
            .json => render.json(alloc, board) catch continue,
        };
        var resp = boardResponse(body, format, "miss");
        var for_fresh = resp.clone();
        cache.put(.{ .url = fresh_key }, &for_fresh);
        var for_stale = resp.clone();
        for_stale.setHeader("cache-control", edge.stale_cache_control);
        for_stale.setHeader("x-sprts-cache", "stale");
        cache.put(.{ .url = stale_key }, &for_stale);
    }
    const body = switch (format) {
        .text => try digest.text(alloc, sections, day, color, route.width, route.height, route.quiet),
        .html => try digest.html(alloc, sections, day, route.width, route.height, route.quiet),
        .json => try digest.json(alloc, sections, day),
    };
    return staticResponse(body, contentType(format), null);
}
