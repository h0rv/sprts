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
//!   (same fresh bucket: 10s when the render has live games, else 30s)
//!   are served directly; on upstream failure a stale entry
//!   from the current 300s bucket is served, else 502. Errors are never
//!   cached. All formats render from a single normalized board fetch.
//!   Render variants ride in the key (see `variantTag`): `?color`,
//!   `?width`, `?height`, text `?0`, and the effective request zone
//!   (`?tz=`) each namespace their own
//!   fully-rendered body, so the first variant in a 30s bucket never
//!   shadows the others.
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
const help = @import("help.zig");
const detail_view = @import("detail_view.zig");
const team_view = @import("team_view.zig");
const standings_view = @import("standings_view.zig");
const spec = @import("spec.zig");
const provider = @import("provider.zig");
const edge = @import("edge_cache.zig");
const digest = @import("digest.zig");
const stream = @import("stream.zig");
const tz = @import("tz.zig");

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

/// CF timezone signal for zone guessing: `request.cf.timezone` (IANA
/// name). Fallible → null (local dev, missing property, bad JSON all
/// fall back to the ET default via `tz.zoneFromWorkerRequest`).
fn cfTimezone(request: *const workers.Request) ?[]const u8 {
    const cf = request.cf() catch return null;
    const props = cf orelse return null;
    return props.timezone;
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

    // Zone once per request: explicit ?tz= beats the CF source guess
    // (`request.cf.timezone` / `CF-Timezone` header) beats the ET default.
    // Missing ?date resolves in this zone (ESPN parity); explicit ?date
    // wins verbatim via tz.resolveDay.
    const cf_header: ?[]const u8 = incomingHeader(request, "CF-Timezone") catch null;
    const zone = tz.zoneFromWorkerRequest(target, cfTimezone(request), cf_header);

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
        .docs => {
            const body = try spec.docsHtml(alloc);
            return staticResponse(body, contentType(.html), null);
        },
        .llms => {
            const body = try spec.llmsTxt(alloc);
            return staticResponse(body, contentType(.text), null);
        },
        .favicon => {
            return staticResponse(render.favicon_svg, "image/svg+xml", null);
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
            const day = try tz.resolveDay(alloc, home_route.date, epochSecondsNow(), zone);
            const boards = try adapter.fetchAll(alloc, day);
            defer provider.EspnAdapter.releaseAll(boards);
            const color = home_route.color orelse try colorDefault(env);
            const body = switch (format) {
                .text => if (home_route.oneline)
                    try render.homeOneLineWithZone(alloc, boards, color, zone)
                else
                    try render.homeLiveWithZone(alloc, color, host, boards, day, home_route.quiet, zone),
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
        .help => |help_route| {
            const color = help_route.color orelse try colorDefault(env);
            const body = try help.renderHelp(alloc, .{
                .color = color,
                .quiet = help_route.quiet,
                .oneline = help_route.oneline,
            }, format);
            return staticResponse(body, contentType(format), null);
        },
        .all => |route| return serveAll(env, alloc, route, format, zone),
        .scoreboard => |route| {
            // SSE trigger mirrors main.zig exactly: ?stream= query flag
            // (ScoreboardRoute.stream, filled from the query half by
            // router.parse) OR'd with the Accept: text/event-stream half via
            // router.wantsStream. Text-only: JSON/HTML stream requests get
            // the normal single response. HEAD never streams (an open-ended
            // body makes no sense there): falls back to the single response.
            const wants_sse = route.stream or router.wantsStream(target, accept);
            if (wants_sse and format == .text and method == .GET and route.week == null) {
                return serveStream(env, alloc, route, zone);
            }
            return serveBoard(env, alloc, route, format, zone);
        },
        .game => |route| return serveDetail(env, alloc, route, format, zone),
        .team => |route| return serveTeam(env, alloc, route, format, zone),
        .today => |route| return serveToday(env, alloc, route, format),
        .date_alias => |route| return serveDateAlias(env, alloc, route, format, zone),
        .week_alias => |route| return serveWeekAlias(env, alloc, route, format),
        .standings => |route| return serveStandings(env, alloc, route, format, zone),
        .teams => |route| return serveTeams(env, alloc, route, format),
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
    zone: tz.Zone,
) !workers.Response {
    const color = route.color orelse try colorDefault(env);
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };

    // Canonicalize: lowercase slug, concrete day (missing ?date resolves in
    // the request zone via tz.resolveDay), path prefix and non-date query
    // excluded from the key.
    const epoch_s = epochSecondsNow();
    const slug = try edge.canonicalSlug(alloc, league.slug);
    const day = try tz.resolveDay(alloc, route.date, epoch_s, zone);
    // Render variants join the edge key: bodies are cached fully rendered,
    // so two widths (or color on/off, art on/off, or ?0, or ?tz= zones) in one 30s bucket
    // need different entries — otherwise the first variant shadows the rest.
    // The TTL variant joins the key too (see edge_cache docs): liveness is
    // only known post-fetch, so BOTH variants are built up front and probed
    // live-first; the fetch below selects the matching one for the store.
    const tag_live = try variantTag(alloc, format, route.width, route.height, color, format == .text and route.oneline, zone, route.art, true);
    const tag_final = try variantTag(alloc, format, route.width, route.height, color, format == .text and route.oneline, zone, route.art, false);
    const board_live = try edge.boardKey(alloc, slug, day, tag_live);
    const board_final = try edge.boardKey(alloc, slug, day, tag_final);
    const fresh_live = try edge.freshKey(alloc, board_live, epoch_s, true);
    const fresh_final = try edge.freshKey(alloc, board_final, epoch_s, false);
    const stale_live = try edge.staleKey(alloc, board_live, epoch_s);
    const stale_final = try edge.staleKey(alloc, board_final, epoch_s);

    const cache = workers.Cache.default();

    // Fresh hit: a same-bucket match proves age < window (10s live, 30s
    // final). Live first, so a live render is never shadowed by an older
    // final entry in the same epoch.
    if (cache.match(.{ .url = fresh_live })) |hit| {
        var resp = hit.clone();
        resp.setHeader("cache-control", edge.client_cache_control);
        resp.setHeader("x-sprts-cache", "hit");
        return resp;
    }
    if (cache.match(.{ .url = fresh_final })) |hit| {
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
        // Both TTL variants are probed (live first): the cached render's
        // liveness is only known to its key.
        if (route.week == null) {
            if (cache.match(.{ .url = stale_live })) |stale| {
                var resp = stale.clone();
                resp.setHeader("cache-control", edge.client_cache_control);
                resp.setHeader("x-sprts-cache", "stale");
                return resp;
            }
            if (cache.match(.{ .url = stale_final })) |stale| {
                var resp = stale.clone();
                resp.setHeader("cache-control", edge.client_cache_control);
                resp.setHeader("x-sprts-cache", "stale");
                return resp;
            }
        }
        return errorResponse(alloc, "scores are temporarily unavailable", format, .bad_gateway);
    };
    const body = switch (format) {
        .text => if (route.oneline)
            try help.scoreOneLine(alloc, board, color, route.quiet)
        else
            try render.textWithZoneArt(alloc, board, color, route.width, route.height, zone, route.art),
        .html => try render.scoreHtmlWithZoneArtMtime(alloc, board, route.width, route.height, zone, route.art, epoch_s),
        .json => try render.json(alloc, board),
    };

    var resp = boardResponse(body, format, "miss");

    // Store fresh (10s when the rendered board has live games, else 30s)
    // + stale (300s retention) renders. Only successful renders reach this
    // point, so errors are never cached.
    // Week boards are never stored (key has no week component).
    if (route.week != null) return resp;
    const live = edge.isLiveBoard(board);
    const fresh_key = if (live) fresh_live else fresh_final;
    const stale_key = if (live) stale_live else stale_final;
    var for_fresh = resp.clone();
    cache.put(.{ .url = fresh_key }, &for_fresh);
    var for_stale = resp.clone();
    for_stale.setHeader("cache-control", edge.stale_cache_control);
    for_stale.setHeader("x-sprts-cache", "stale");
    cache.put(.{ .url = stale_key }, &for_stale);
    return resp;
}

/// Game detail (wt-detail): same edge-cache scheme as the board, keyed on
/// `detail/<slug>/<id>/<format>` plus the render variants (see `variantTag`)
/// (fresh 10s/30s bucket by rendered liveness, stale 300s on upstream
/// error). Unknown game ids are
/// 404; upstream failures are 502; errors are never cached. Text `?0` keys
/// through the shared gameOneLine predicate, so the full box and the
/// one-line fallback never shadow each other in a fresh bucket while
/// HTML/JSON (which ignore `?0`) keep one coherent entry.
fn serveDetail(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.GameRoute,
    format: router.Format,
    zone: tz.Zone,
) !workers.Response {
    const color = route.color orelse try colorDefault(env);
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };

    const epoch_s = epochSecondsNow();
    const slug = try edge.canonicalSlug(alloc, league.slug);
    // Variant edge namespace: the cached body is a render, not the
    // normalized payload (unlike the native cache), so every render variant
    // (width/height/color, plus `?0` text via the shared gameOneLine
    // predicate, plus the effective request zone) needs its own key —
    // otherwise whichever renders first in a
    // 30s bucket shadows the others. HTML/JSON ignore `?0` (team-route
    // precedent: the flag is text-only), so they keep the l0 tag and their
    // stale fallback stays variant-coherent. The detail view renders no
    // team marks, so art keys as true and `?art=off` shares the art-on
    // entry (same rule as `?0` on HTML/JSON above). Liveness is only known
    // post-fetch, so BOTH TTL variants are built up front and probed
    // live-first; the fetch below selects the matching one for the store.
    const oneline = router.gameOneLine(route, format);
    const tag_live = try variantTag(alloc, format, route.width, route.height, color, oneline, zone, true, true);
    const tag_final = try variantTag(alloc, format, route.width, route.height, color, oneline, zone, true, false);
    const detail_live = try edge.detailKey(alloc, slug, route.id, tag_live);
    const detail_final = try edge.detailKey(alloc, slug, route.id, tag_final);
    const fresh_live = try edge.detailFreshKey(alloc, detail_live, epoch_s, true);
    const fresh_final = try edge.detailFreshKey(alloc, detail_final, epoch_s, false);
    const stale_live = try edge.detailStaleKey(alloc, detail_live, epoch_s);
    const stale_final = try edge.detailStaleKey(alloc, detail_final, epoch_s);

    const cache = workers.Cache.default();

    if (cache.match(.{ .url = fresh_live })) |hit| {
        var resp = hit.clone();
        resp.setHeader("cache-control", edge.client_cache_control);
        resp.setHeader("x-sprts-cache", "hit");
        return resp;
    }
    if (cache.match(.{ .url = fresh_final })) |hit| {
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
            // Both TTL variants are probed (live first): the cached
            // render's liveness is only known to its key.
            if (cache.match(.{ .url = stale_live })) |stale| {
                var resp = stale.clone();
                resp.setHeader("cache-control", edge.client_cache_control);
                resp.setHeader("x-sprts-cache", "stale");
                return resp;
            }
            if (cache.match(.{ .url = stale_final })) |stale| {
                var resp = stale.clone();
                resp.setHeader("cache-control", edge.client_cache_control);
                resp.setHeader("x-sprts-cache", "stale");
                return resp;
            }
            return errorResponse(alloc, "scores are temporarily unavailable", format, .bad_gateway);
        },
    };
    // Text dispatch via the shared predicate (mirrors the native game arm):
    // text + ?0 selects renderTextOneLine, every other combination keeps
    // the full renderers (html/json ignore ?0 by team-route precedent).
    const body = if (router.gameOneLine(route, format))
        try detail_view.renderTextOneLine(alloc, game_detail, color, route.quiet)
    else switch (format) {
        .text => try detail_view.renderText(alloc, game_detail, color, route.width, route.height),
        .html => try detail_view.detailHtmlMtime(alloc, game_detail, route.width, route.height, epoch_s),
        .json => try detail_view.json(alloc, game_detail),
    };

    var resp = boardResponse(body, format, "miss");

    // Fresh window follows the rendered detail: 10s when the game is live,
    // else 30s; stale stays 300s.
    const live = edge.isLiveDetail(game_detail);
    const fresh_key = if (live) fresh_live else fresh_final;
    const stale_key = if (live) stale_live else stale_final;
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
    zone: tz.Zone,
) !workers.Response {
    const color = route.color orelse try colorDefault(env);
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", .text, .not_found);
    };

    const epoch_s = epochSecondsNow();
    const day = try tz.resolveDay(alloc, route.date, epoch_s, zone);

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
    const initial_text = try render.textWithZoneArt(alloc, initial, color, route.width, route.height, zone, route.art);
    const initial_frame = try stream.frameWithMtime(alloc, initial_text, epoch_s);

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
        const body = render.textWithZoneArt(alloc, board, color, route.width, route.height, zone, route.art) catch continue;
        const event = stream.frameWithMtime(alloc, body, epochSecondsNow()) catch continue;
        sse.write(event);
        // Per-request arena memory grows with each tick's render; the outer
        // entry arena is freed when the request ends, and frames for a
        // final-slate resource stop changing (300s cadence, fingerprint
        // stable), so steady-state allocation is bounded in practice.
    }

    sse.close();
    return sse.response();
}

/// Render-variant edge tag: format plus every display flag that changes the
/// cached body (width/height/color/art/one-line) plus the effective request
/// zone (`?tz=`). The edge stores fully-rendered
/// bodies (unlike the native payload cache), so two variants sharing one 30s
/// bucket entry would shadow each other: the first render wins and the other
/// variant serves the wrong body until the bucket rolls. Null width/height
/// encode as 0 (the renderer default); `oneline` is the effective flag —
/// callers pass false where the renderer ignores `?0` (HTML/JSON,
/// standings), so identical bodies share one entry and stale fallbacks stay
/// variant-coherent. `art` follows the same rule: detail and standings
/// render no team marks, so their callers pass true and `?art=off` shares
/// the art-on entry there. The zone uses the short `tz.zoneTag` form
/// (`ET`/`UTC`/`UTC-5`/...) so `?tz=utc` renders never share an entry with
/// the ET default in one bucket and vice versa. The TTL variant (`live`)
/// namespaces the freshness window in the tag itself (`/v/live` vs
/// `/v/final`), backing the `fl`/`f` bucket-prefix split in `edge_cache`:
/// a live render cached at t=0 can never satisfy a final lookup at t=29
/// as fresh. Board/detail callers probe both variants (live first) since
/// liveness is only known post-fetch; every other caller passes false and
/// stays on the flat window.
fn variantTag(
    arena: std.mem.Allocator,
    format: router.Format,
    width: ?u16,
    height: ?u16,
    color: bool,
    oneline: bool,
    zone: tz.Zone,
    art: bool,
    live: bool,
) ![]u8 {
    const zone_tag = try tz.zoneTag(arena, zone);
    defer arena.free(zone_tag);
    return std.fmt.allocPrint(arena, "{s}/w{d}/h{d}/c{d}/l{d}/z{s}/a{d}/v{s}", .{
        edge.formatTag(format),
        width orelse 0,
        height orelse 0,
        @intFromBool(color),
        @intFromBool(oneline),
        zone_tag,
        @intFromBool(art),
        @as([]const u8, if (live) "live" else "final"),
    });
}

/// `/all?0` worker composer: the same shared composer as native `allOneLine`
/// (main.zig) — digest sections adapt to `provider.LeagueResult` and render
/// through `render.homeOneLineWithZone`, so both serve paths emit
/// byte-identical lines. `quiet` is moot (`?0` has no header/footer, `/?0`
/// parity) and only threads through for signature symmetry.
fn serveAllOneLine(
    alloc: std.mem.Allocator,
    sections: []const digest.DigestSection,
    color: bool,
    quiet: bool,
    zone: tz.Zone,
) ![]u8 {
    _ = quiet;
    const results = try alloc.alloc(provider.LeagueResult, sections.len);
    defer alloc.free(results);
    for (sections, 0..) |section, i| results[i] = .{ .league = section.league, .board = section.board };
    return render.homeOneLineWithZone(alloc, results, color, zone);
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

/// Human shortcut `/{league}/{abbr}/today`: resolve the team's game
/// today and redirect to its canonical address (game id, or the team
/// page when none). Fresh-only, no-store; the game id stays canonical
/// so bookmarks and the JSON API keep one address per game.
fn serveToday(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.TodayRoute,
    format: router.Format,
) !workers.Response {
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };
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
        workers.log("upstream ESPN team fetch failed for {s} {s}", .{ league.slug, route.abbr });
        return errorResponse(alloc, "scores are temporarily unavailable", format, .bad_gateway);
    };
    const target = if (core.schedule.findTodayGame(view)) |game|
        if (route.api)
            try std.fmt.allocPrint(alloc, "/api/v1/{s}/{s}", .{ league.slug, game.id })
        else
            try std.fmt.allocPrint(alloc, "/{s}/{s}", .{ league.slug, game.id })
    else if (route.api)
        try std.fmt.allocPrint(alloc, "/api/v1/{s}/{s}", .{ league.slug, route.abbr })
    else
        try std.fmt.allocPrint(alloc, "/{s}/{s}", .{ league.slug, route.abbr });
    const body = try std.fmt.allocPrint(alloc, "{s}\n", .{target});
    var resp = workers.Response.new();
    resp.setStatus(.found);
    resp.setHeader("location", target);
    resp.setHeader("cache-control", "no-store");
    resp.setHeader("x-content-type-options", "nosniff");
    resp.setBody(body);
    return resp;
}

/// Human game alias, date form `/{league}/{date}/{away}-{home}[-N]`: resolve
/// the day in the request zone, fetch that board fresh, redirect to the
/// canonical `/{league}/{id}` (a miss 404s: plain on all-duel days,
/// duel-only hint past them). Fresh-only,
/// no-store, no `/api/v1/` twin (serveToday parity).
fn serveDateAlias(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.DateAliasRoute,
    format: router.Format,
    zone: tz.Zone,
) !workers.Response {
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };
    var transport_state = WorkerTransport{};
    const base_url = (try env.get("SPRTS_ESPN_BASE_URL")) orelse default_base_url;
    const adapter = provider.EspnAdapter{
        .allocator = alloc,
        .io = workers.io(),
        .base_url = base_url,
        .transport = transport_state.asTransport(),
        .clock = workerClock,
    };
    const day = try tz.resolveDay(alloc, route.date, epochSecondsNow(), zone);
    const board = adapter.fetch(alloc, league, day) catch {
        workers.log("upstream ESPN fetch failed for {s} {s}", .{ league.slug, day });
        return errorResponse(alloc, "scores are temporarily unavailable", format, .bad_gateway);
    };
    const game = provider.findGameByMatchupN(board, route.away, route.home, route.n orelse 1) orelse {
        const browse = try std.fmt.allocPrint(alloc, "/{s}?date={s}", .{ league.slug, day });
        return errorResponse(alloc, try provider.aliasMissMessage(alloc, board, browse), format, .not_found);
    };
    const target = try std.fmt.allocPrint(alloc, "/{s}/{s}", .{ league.slug, game.id });
    const body = try std.fmt.allocPrint(alloc, "{s}\n", .{target});
    var resp = workers.Response.new();
    resp.setStatus(.found);
    resp.setHeader("location", target);
    resp.setHeader("cache-control", "no-store");
    resp.setHeader("x-content-type-options", "nosniff");
    resp.setBody(body);
    return resp;
}

/// Human game alias, week form `/{league}/{YYYY}/week{N}/{away}-{home}`
/// (football only — gated on the league sport): fetch the week's board with
/// NO dates param (ESPN resolves the week alone), verify the response season
/// year against the URL season (ESPN ignores unknown season params — a
/// mismatch 404s, never misleads), redirect to the canonical game id.
/// Fresh-only, no-store (serveToday parity).
fn serveWeekAlias(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.WeekAliasRoute,
    format: router.Format,
) !workers.Response {
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };
    if (!std.mem.eql(u8, league.sport, "Football")) {
        return errorResponse(alloc, "week games are football-only", format, .not_found);
    }
    const season = std.fmt.parseInt(u16, route.season, 10) catch {
        return errorResponse(alloc, "game not found", format, .not_found);
    };
    var transport_state = WorkerTransport{};
    const base_url = (try env.get("SPRTS_ESPN_BASE_URL")) orelse default_base_url;
    const adapter = provider.EspnAdapter{
        .allocator = alloc,
        .io = workers.io(),
        .base_url = base_url,
        .transport = transport_state.asTransport(),
        .clock = workerClock,
    };
    const week_board = adapter.fetchWeekBoard(alloc, league, route.season, route.week) catch {
        workers.log("upstream ESPN week fetch failed for {s}", .{league.slug});
        return errorResponse(alloc, "scores are temporarily unavailable", format, .bad_gateway);
    };
    if (week_board.season_year == null or week_board.season_year.? != season) {
        return errorResponse(alloc, "game not found", format, .not_found);
    }
    const game = provider.findGameByMatchupN(week_board.board, route.away, route.home, route.n orelse 1) orelse {
        const browse = try std.fmt.allocPrint(alloc, "/{s}?week={d}", .{ league.slug, route.week });
        return errorResponse(alloc, try provider.aliasMissMessage(alloc, week_board.board, browse), format, .not_found);
    };
    const target = try std.fmt.allocPrint(alloc, "/{s}/{s}", .{ league.slug, game.id });
    const body = try std.fmt.allocPrint(alloc, "{s}\n", .{target});
    var resp = workers.Response.new();
    resp.setStatus(.found);
    resp.setHeader("location", target);
    resp.setHeader("cache-control", "no-store");
    resp.setHeader("x-content-type-options", "nosniff");
    resp.setBody(body);
    return resp;
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
    zone: tz.Zone,
) !workers.Response {
    const color = route.color orelse try colorDefault(env);
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };

    const epoch_s = epochSecondsNow();
    const slug = try edge.canonicalSlug(alloc, league.slug);
    const abbr = try edge.canonicalAbbr(alloc, route.abbr);
    const tag = try variantTag(alloc, format, route.width, route.height, color, format == .text and route.oneline, zone, route.art, false);
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
        .text => if (route.oneline)
            try team_view.renderTextOneLine(alloc, view, color, route.quiet)
        else
            try team_view.renderTextArt(alloc, view, color, route.width, route.height, route.art),
        .html => try team_view.teamHtmlArt(alloc, view, league.slug, route.width, route.height, route.art),
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

/// League standings through one normalized `fetchStandings` per request,
/// every format rendered from it. Edge scheme mirrors the team path:
/// `standings/<slug>/<format>` namespace, fresh 60s bucket served directly,
/// stale 600s bucket on upstream failure (else 502); errors never cached.
/// `error.UnsupportedLeague` is authoritative (no table for this league),
/// so it bypasses even the stale path with a 404.
fn serveStandings(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.StandingsRoute,
    format: router.Format,
    zone: tz.Zone,
) !workers.Response {
    const color = route.color orelse try colorDefault(env);
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };

    const epoch_s = epochSecondsNow();
    const slug = try edge.canonicalSlug(alloc, league.slug);
    // Standings has no one-line renderer (the flag never changes the body),
    // so `oneline` keys as false and `?0` shares the full entry. The zone
    // still namespaces the key so a `?tz=` render never shadows the default.
    // Team marks never render here either, so art keys as true like oneline.
    const tag = try variantTag(alloc, format, route.width, route.height, color, false, zone, true, false);
    const key = try edge.standingsKey(alloc, slug, tag);
    const fresh_key = try edge.standingsFreshKey(alloc, key, epoch_s);
    const stale_key = try edge.standingsStaleKey(alloc, key, epoch_s);

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

    const table_data = provider.fetchStandings(adapter, alloc, league) catch |err| {
        if (err == error.UnsupportedLeague) {
            return errorResponse(alloc, "standings unavailable for this league; see /api/v1/leagues", format, .not_found);
        }
        workers.log("upstream ESPN standings fetch failed for {s}", .{league.slug});
        if (cache.match(.{ .url = stale_key })) |stale| {
            var resp = stale.clone();
            resp.setHeader("cache-control", edge.client_cache_control);
            resp.setHeader("x-sprts-cache", "stale");
            return resp;
        }
        return errorResponse(alloc, "scores are temporarily unavailable", format, .bad_gateway);
    };
    const body = switch (format) {
        .text => try standings_view.text(alloc, table_data, color, route.width, route.height),
        .html => try standings_view.html(alloc, table_data, route.width, route.height),
        .json => try standings_view.json(alloc, table_data),
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

/// League team list through the edge cache. JSON-only like the native
/// arm (no text table exists for a picker): every format serves the same
/// JSON body. Edge scheme uses the dedicated 24h teams namespace (see
/// `edge.teamsKey`): membership barely changes, so fresh serves 24h and
/// stale covers 24h on upstream failure (else 502); errors never cached.
fn serveTeams(
    env: *workers.Env,
    alloc: std.mem.Allocator,
    route: router.TeamsRoute,
    format: router.Format,
) !workers.Response {
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };

    const epoch_s = epochSecondsNow();
    const slug = try edge.canonicalSlug(alloc, league.slug);
    const key = try edge.teamsKey(alloc, slug);
    const fresh_key = try edge.teamsFreshKey(alloc, key, epoch_s);
    const stale_key = try edge.teamsStaleKey(alloc, key, epoch_s);

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

    const list = provider.fetchTeams(adapter, alloc, league) catch {
        workers.log("upstream ESPN teams fetch failed for {s}", .{league.slug});
        if (cache.match(.{ .url = stale_key })) |stale| {
            var resp = stale.clone();
            resp.setHeader("cache-control", edge.client_cache_control);
            resp.setHeader("x-sprts-cache", "stale");
            return resp;
        }
        return errorResponse(alloc, "scores are temporarily unavailable", format, .bad_gateway);
    };
    const body = try render.teamsJson(alloc, list);

    var resp = boardResponse(body, .json, "miss");

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
    zone: tz.Zone,
) !workers.Response {
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
    const day = try tz.resolveDay(alloc, route.date, epoch_s, zone);
    // Digest-level edge entry: /all fans out one normalized fetch per
    // league (~20 subrequests), and Workers Free allows 50 per invocation,
    // so per-league edge traffic would blow the budget — the old code did
    // a match + put per league (~60 ops) and prod 500d with "too many
    // subrequests". Now the digest caches its own fully-rendered body
    // (fresh-hit = ~2 ops) and the loop does plain fetches only: no
    // per-league match (it never saved anything — the digest composition
    // below re-renders regardless) and no warming puts (single-league
    // routes fetch on their own demand at 3 ops each). First hit costs
    // ~20 fetches + 1 put; repeats cost one match. The variant tag must
    // include oneline: ?0 renders a different body than the full digest.
    // Art joins the tag too: digest sections carry scoreboard marks.
    const tag = try variantTag(alloc, format, route.width, route.height, color, format == .text and route.oneline, zone, route.art, false);
    const digest_key = try edge.boardKey(alloc, "all", day, tag);
    const fresh_key = try edge.freshKey(alloc, digest_key, epoch_s, false);
    const cache = workers.Cache.default();
    // Fresh hit: same 30s bucket, so age < 30s. Serve the stored render.
    if (cache.match(.{ .url = fresh_key })) |hit| {
        var resp = hit.clone();
        resp.setHeader("cache-control", edge.client_cache_control);
        resp.setHeader("x-sprts-cache", "hit");
        return resp;
    }
    const sections = try alloc.alloc(digest.DigestSection, core.leagues.all.len);
    for (&core.leagues.all, 0..) |*league, i| {
        sections[i] = .{ .league = league };
        const board = adapter.fetch(alloc, league, day) catch {
            // One league's outage never fails the digest: mark the
            // section unavailable and keep the others.
            sections[i].board = null;
            continue;
        };
        sections[i].board = board;
    }
    const body = switch (format) {
        .text => if (route.oneline)
            try serveAllOneLine(alloc, sections, color, route.quiet, zone)
        else
            try digest.textWithZoneArt(alloc, sections, day, color, route.width, route.height, route.quiet, zone, route.art),
        .html => try digest.htmlWithZoneArt(alloc, sections, day, route.width, route.height, route.quiet, zone, route.art),
        .json => try digest.json(alloc, sections, day),
    };
    var resp = staticResponse(body, contentType(format), "miss");
    var for_fresh = resp.clone();
    cache.put(.{ .url = fresh_key }, &for_fresh);
    return resp;
}

test "edge variant tags split width, color, art, and one-line in one bucket" {
    const arena = std.testing.allocator;
    const bucket: i64 = 12_345; // one shared 30s + 300s bucket below
    const keyFor = struct {
        fn key(a: std.mem.Allocator, width: ?u16, color: bool, oneline: bool, art: bool) ![]u8 {
            const tag = try variantTag(a, .text, width, null, color, oneline, .et, art, false);
            defer a.free(tag);
            const board = try edge.boardKey(a, "mlb", "2026-09-06", tag);
            defer a.free(board);
            return edge.freshKey(a, board, bucket, false);
        }
    }.key;
    const base = try keyFor(arena, null, true, false, true);
    defer arena.free(base);
    // A different width in the same bucket is a different entry: sharing
    // one would serve the first variant's body to the second request.
    const wide = try keyFor(arena, 120, true, false, true);
    defer arena.free(wide);
    try std.testing.expect(!std.mem.eql(u8, base, wide));
    // Color off renders a different body, so it keys differently too.
    const mono = try keyFor(arena, null, false, false, true);
    defer arena.free(mono);
    try std.testing.expect(!std.mem.eql(u8, base, mono));
    // ?art=off renders a different body (no mark rows), so it keys apart.
    const no_art = try keyFor(arena, null, true, false, false);
    defer arena.free(no_art);
    try std.testing.expect(!std.mem.eql(u8, base, no_art));
    // ?0 text is its own namespace (full box and one line never share).
    const one_line = try keyFor(arena, null, true, true, true);
    defer arena.free(one_line);
    try std.testing.expect(!std.mem.eql(u8, base, one_line));
    // Identical variants converge on one entry.
    const again = try keyFor(arena, null, true, false, true);
    defer arena.free(again);
    try std.testing.expectEqualStrings(base, again);
}

test "one bucket never shadows another variant's body" {
    const arena = std.testing.allocator;
    const board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "",
                .starts_at = "2026-09-06T17:00Z",
                .state = "in",
                .status = "Top 7th",
                .participants = &.{
                    .{ .id = "a", .name = "Away Club", .abbreviation = "AWY", .score = "0", .winner = false, .home_away = "away" },
                    .{ .id = "h", .name = "Home Club", .abbreviation = "HME", .score = "3", .winner = false, .home_away = "home" },
                },
            },
        },
    };
    // Width changes the render, so widths must key apart ...
    const narrow = try render.textWithZone(arena, board, true, 80, null, .et);
    defer arena.free(narrow);
    const wide = try render.textWithZone(arena, board, true, 120, null, .et);
    defer arena.free(wide);
    try std.testing.expect(!std.mem.eql(u8, narrow, wide));
    const narrow_tag = try variantTag(arena, .text, 80, null, true, false, .et, true, false);
    defer arena.free(narrow_tag);
    const wide_tag = try variantTag(arena, .text, 120, null, true, false, .et, true, false);
    defer arena.free(wide_tag);
    try std.testing.expect(!std.mem.eql(u8, narrow_tag, wide_tag));
    // ... and color on/off changes the render, so it keys apart too.
    const mono = try render.textWithZone(arena, board, false, 80, null, .et);
    defer arena.free(mono);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, mono, "\x1b[") == null);
    const color_tag = try variantTag(arena, .text, 80, null, true, false, .et, true, false);
    defer arena.free(color_tag);
    const mono_tag = try variantTag(arena, .text, 80, null, false, false, .et, true, false);
    defer arena.free(mono_tag);
    try std.testing.expect(!std.mem.eql(u8, color_tag, mono_tag));
}

test "edge variant tags split ET and UTC zones in one bucket" {
    const arena = std.testing.allocator;
    const bucket: i64 = 12_345; // one shared bucket: zones must not shadow
    // The bodies diverge (zone-named heading), so the tags must too.
    const board: core.domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{},
    };
    const et_body = try render.textWithZone(arena, board, true, null, null, .et);
    defer arena.free(et_body);
    const utc_body = try render.textWithZone(arena, board, true, null, null, .utc);
    defer arena.free(utc_body);
    try std.testing.expect(!std.mem.eql(u8, et_body, utc_body));
    try std.testing.expect(std.mem.indexOf(u8, et_body, " ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, utc_body, " UTC") != null);
    // Board namespace: same bucket, same display flags, zones key apart.
    const et_tag = try variantTag(arena, .text, null, null, true, false, .et, true, false);
    defer arena.free(et_tag);
    const utc_tag = try variantTag(arena, .text, null, null, true, false, .utc, true, false);
    defer arena.free(utc_tag);
    try std.testing.expect(!std.mem.eql(u8, et_tag, utc_tag));
    const et_board = try edge.boardKey(arena, "mlb", "2026-09-06", et_tag);
    defer arena.free(et_board);
    const utc_board = try edge.boardKey(arena, "mlb", "2026-09-06", utc_tag);
    defer arena.free(utc_board);
    const et_fresh = try edge.freshKey(arena, et_board, bucket, false);
    defer arena.free(et_fresh);
    const utc_fresh = try edge.freshKey(arena, utc_board, bucket, false);
    defer arena.free(utc_fresh);
    try std.testing.expect(!std.mem.eql(u8, et_fresh, utc_fresh));
    // Identical zones converge on one entry.
    const et_again = try variantTag(arena, .text, null, null, true, false, .et, true, false);
    defer arena.free(et_again);
    try std.testing.expectEqualStrings(et_tag, et_again);
    // Fixed offsets namespace apart from each other and from ET/UTC.
    const fixed_tag = try variantTag(arena, .text, null, null, true, false, .{ .fixed = -300 }, true, false);
    defer arena.free(fixed_tag);
    try std.testing.expect(!std.mem.eql(u8, et_tag, fixed_tag));
    try std.testing.expect(!std.mem.eql(u8, utc_tag, fixed_tag));
    // Every other variant-cached namespace rides the same tag, so detail,
    // team, standings, and the digest-level /all entry inherit the zone
    // split in the same bucket.
    const et_detail = try edge.detailKey(arena, "mlb", "1", et_tag);
    defer arena.free(et_detail);
    const utc_detail = try edge.detailKey(arena, "mlb", "1", utc_tag);
    defer arena.free(utc_detail);
    const et_detail_fresh = try edge.detailFreshKey(arena, et_detail, bucket, false);
    defer arena.free(et_detail_fresh);
    const utc_detail_fresh = try edge.detailFreshKey(arena, utc_detail, bucket, false);
    defer arena.free(utc_detail_fresh);
    try std.testing.expect(!std.mem.eql(u8, et_detail_fresh, utc_detail_fresh));
    const et_team = try edge.teamKey(arena, "mlb", "phi", et_tag);
    defer arena.free(et_team);
    const utc_team = try edge.teamKey(arena, "mlb", "phi", utc_tag);
    defer arena.free(utc_team);
    const et_team_fresh = try edge.teamFreshKey(arena, et_team, bucket);
    defer arena.free(et_team_fresh);
    const utc_team_fresh = try edge.teamFreshKey(arena, utc_team, bucket);
    defer arena.free(utc_team_fresh);
    try std.testing.expect(!std.mem.eql(u8, et_team_fresh, utc_team_fresh));
    const et_st = try edge.standingsKey(arena, "mlb", et_tag);
    defer arena.free(et_st);
    const utc_st = try edge.standingsKey(arena, "mlb", utc_tag);
    defer arena.free(utc_st);
    const et_st_fresh = try edge.standingsFreshKey(arena, et_st, bucket);
    defer arena.free(et_st_fresh);
    const utc_st_fresh = try edge.standingsFreshKey(arena, utc_st, bucket);
    defer arena.free(utc_st_fresh);
    try std.testing.expect(!std.mem.eql(u8, et_st_fresh, utc_st_fresh));
}

test "worker all?0 matches the native one-line composer" {
    const arena = std.testing.allocator;
    const mlb = core.leagues.find("mlb").?;
    const sections = [_]digest.DigestSection{
        .{
            .league = mlb,
            .board = .{
                .league = "mlb",
                .league_name = "MLB",
                .date = "2026-09-06",
                .source = "test",
                .games = &.{
                    .{
                        .id = "1",
                        .name = "",
                        .starts_at = "2026-09-06T17:00Z",
                        .state = "post",
                        .status = "Final",
                        .participants = &.{
                            .{ .id = "a", .name = "Away Club", .abbreviation = "AWY", .score = "2", .winner = false, .home_away = "away" },
                            .{ .id = "h", .name = "Home Club", .abbreviation = "HME", .score = "5", .winner = true },
                        },
                    },
                },
            },
        },
        .{ .league = core.leagues.find("nfl").? },
    };
    // M/D ZONE label (never the raw date), status plus winner on the
    // scored duel, away resolved checking both sides; the null-board
    // league emits nothing.
    const lines = try serveAllOneLine(arena, &sections, false, false, .et);
    defer arena.free(lines);
    try std.testing.expect(std.mem.indexOf(u8, lines, "mlb 9/6 ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "2026-09-06") == null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "Final AWY 2 @ HME 5 ✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "nfl") == null);
    // Quiet is moot (/?0 parity): both modes byte-identical.
    const hushed = try serveAllOneLine(arena, &sections, false, true, .et);
    defer arena.free(hushed);
    try std.testing.expectEqualStrings(lines, hushed);
}

test "edge variant tags split live and final TTL variants in one bucket" {
    const arena = std.testing.allocator;
    const live_tag = try variantTag(arena, .text, null, null, true, false, .et, true, true);
    defer arena.free(live_tag);
    const final_tag = try variantTag(arena, .text, null, null, true, false, .et, true, false);
    defer arena.free(final_tag);
    try std.testing.expect(!std.mem.eql(u8, live_tag, final_tag));
    // Identical liveness converges on one entry.
    const live_again = try variantTag(arena, .text, null, null, true, false, .et, true, true);
    defer arena.free(live_again);
    try std.testing.expectEqualStrings(live_tag, live_again);
    // A live render cached at t=0 is unservable as fresh at t=29: the live
    // 10s bucket rolled AND the final key (different tag, different bucket
    // prefix) never held the entry.
    const live_board = try edge.boardKey(arena, "mlb", "2026-09-06", live_tag);
    defer arena.free(live_board);
    const final_board = try edge.boardKey(arena, "mlb", "2026-09-06", final_tag);
    defer arena.free(final_board);
    const live_key = try edge.freshKey(arena, live_board, 0, true);
    defer arena.free(live_key);
    const live_late = try edge.freshKey(arena, live_board, 29, true);
    defer arena.free(live_late);
    try std.testing.expect(!std.mem.eql(u8, live_key, live_late));
    const final_late = try edge.freshKey(arena, final_board, 29, false);
    defer arena.free(final_late);
    try std.testing.expect(!std.mem.eql(u8, live_key, final_late));
}
