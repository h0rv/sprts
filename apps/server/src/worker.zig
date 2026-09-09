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
//!   Render variants ride in the key (see `variantTag`): `?color`,
//!   `?width`, `?height`, and text `?0` each namespace their own
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
            const day = try tz.resolveDay(alloc, null, epochSecondsNow(), zone);
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
        .game => |route| return serveDetail(env, alloc, route, format),
        .team => |route| return serveTeam(env, alloc, route, format),
        .standings => |route| return serveStandings(env, alloc, route, format),
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
    // so two widths (or color on/off, or ?0) in one 30s bucket need
    // different entries — otherwise the first variant shadows the rest.
    const tag = try variantTag(alloc, format, route.width, route.height, color, format == .text and route.oneline);
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
        .text => if (route.oneline)
            try help.scoreOneLine(alloc, board, color, route.quiet)
        else
            try render.textWithZone(alloc, board, color, route.width, route.height, zone),
        .html => try render.scoreHtmlWithZone(alloc, board, route.width, route.height, zone),
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
/// `detail/<slug>/<id>/<format>` plus the render variants (see `variantTag`)
/// (fresh 30s bucket, stale 300s on upstream error). Unknown game ids are
/// 404; upstream failures are 502; errors are never cached. Text `?0` keys
/// through the shared gameOneLine predicate, so the full box and the
/// one-line fallback never shadow each other in a fresh bucket while
/// HTML/JSON (which ignore `?0`) keep one coherent entry.
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
    // Variant edge namespace: the cached body is a render, not the
    // normalized payload (unlike the native cache), so every render variant
    // (width/height/color, plus `?0` text via the shared gameOneLine
    // predicate) needs its own key — otherwise whichever renders first in a
    // 30s bucket shadows the others. HTML/JSON ignore `?0` (team-route
    // precedent: the flag is text-only), so they keep the l0 tag and their
    // stale fallback stays variant-coherent.
    const tag = try variantTag(alloc, format, route.width, route.height, color, router.gameOneLine(route, format));
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
    // Text dispatch via the shared predicate (mirrors the native game arm):
    // text + ?0 selects renderTextOneLine, every other combination keeps
    // the full renderers (html/json ignore ?0 by team-route precedent).
    const body = if (router.gameOneLine(route, format))
        try detail_view.renderTextOneLine(alloc, game_detail, color, route.quiet)
    else switch (format) {
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
    const initial_text = try render.textWithZone(alloc, initial, color, route.width, route.height, zone);
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
        const body = render.textWithZone(alloc, board, color, route.width, route.height, zone) catch continue;
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

/// Render-variant edge tag: format plus every display flag that changes the
/// cached body (width/height/color/one-line). The edge stores fully-rendered
/// bodies (unlike the native payload cache), so two variants sharing one 30s
/// bucket entry would shadow each other: the first render wins and the other
/// variant serves the wrong body until the bucket rolls. Null width/height
/// encode as 0 (the renderer default); `oneline` is the effective flag —
/// callers pass false where the renderer ignores `?0` (HTML/JSON,
/// standings), so identical bodies share one entry and stale fallbacks stay
/// variant-coherent.
fn variantTag(
    arena: std.mem.Allocator,
    format: router.Format,
    width: ?u16,
    height: ?u16,
    color: bool,
    oneline: bool,
) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/w{d}/h{d}/c{d}/l{d}", .{
        edge.formatTag(format),
        width orelse 0,
        height orelse 0,
        @intFromBool(color),
        @intFromBool(oneline),
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
    const tag = try variantTag(alloc, format, route.width, route.height, color, format == .text and route.oneline);
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
            try team_view.renderText(alloc, view, color, route.width, route.height),
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
) !workers.Response {
    const color = route.color orelse try colorDefault(env);
    const league = core.leagues.find(route.league) orelse {
        return errorResponse(alloc, "unknown league; see /api/v1/leagues", format, .not_found);
    };

    const epoch_s = epochSecondsNow();
    const slug = try edge.canonicalSlug(alloc, league.slug);
    // Standings has no one-line renderer (the flag never changes the body),
    // so `oneline` keys as false and `?0` shares the full entry.
    const tag = try variantTag(alloc, format, route.width, route.height, color, false);
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
    // Variant key for the per-league refresh puts below: the stored bodies
    // are full renders (never one-line), so `oneline` is always false here
    // — a digest refresh warms the full-render entries single-league routes
    // read, never the `?0` namespace.
    const tag = try variantTag(alloc, format, route.width, route.height, color, false);
    const sections = try alloc.alloc(digest.DigestSection, core.leagues.all.len);
    const cache = workers.Cache.default();
    for (&core.leagues.all, 0..) |*league, i| {
        sections[i] = .{ .league = league };
        const slug = try edge.canonicalSlug(alloc, league.slug);
        const board_key = try edge.boardKey(alloc, slug, day, tag);
        const fresh_key = try edge.freshKey(alloc, board_key, epoch_s);
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
            .text => render.textWithZone(alloc, board, color, route.width, route.height, zone) catch continue,
            .html => render.scoreHtmlWithZone(alloc, board, route.width, route.height, zone) catch continue,
            .json => render.json(alloc, board) catch continue,
        };
        var resp = boardResponse(body, format, "miss");
        var for_fresh = resp.clone();
        cache.put(.{ .url = fresh_key }, &for_fresh);
    }
    const body = switch (format) {
        .text => if (route.oneline)
            try serveAllOneLine(alloc, sections, color, route.quiet, zone)
        else
            try digest.textWithZone(alloc, sections, day, color, route.width, route.height, route.quiet, zone),
        .html => try digest.htmlWithZone(alloc, sections, day, route.width, route.height, route.quiet, zone),
        .json => try digest.json(alloc, sections, day),
    };
    return staticResponse(body, contentType(format), null);
}

test "edge variant tags split width, color, and one-line in one bucket" {
    const arena = std.testing.allocator;
    const bucket: i64 = 12_345; // one shared 30s + 300s bucket below
    const keyFor = struct {
        fn key(a: std.mem.Allocator, width: ?u16, color: bool, oneline: bool) ![]u8 {
            const tag = try variantTag(a, .text, width, null, color, oneline);
            defer a.free(tag);
            const board = try edge.boardKey(a, "mlb", "2026-09-06", tag);
            defer a.free(board);
            return edge.freshKey(a, board, bucket);
        }
    }.key;
    const base = try keyFor(arena, null, true, false);
    defer arena.free(base);
    // A different width in the same bucket is a different entry: sharing
    // one would serve the first variant's body to the second request.
    const wide = try keyFor(arena, 120, true, false);
    defer arena.free(wide);
    try std.testing.expect(!std.mem.eql(u8, base, wide));
    // Color off renders a different body, so it keys differently too.
    const mono = try keyFor(arena, null, false, false);
    defer arena.free(mono);
    try std.testing.expect(!std.mem.eql(u8, base, mono));
    // ?0 text is its own namespace (full box and one line never share).
    const one_line = try keyFor(arena, null, true, true);
    defer arena.free(one_line);
    try std.testing.expect(!std.mem.eql(u8, base, one_line));
    // Identical variants converge on one entry.
    const again = try keyFor(arena, null, true, false);
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
    const narrow_tag = try variantTag(arena, .text, 80, null, true, false);
    defer arena.free(narrow_tag);
    const wide_tag = try variantTag(arena, .text, 120, null, true, false);
    defer arena.free(wide_tag);
    try std.testing.expect(!std.mem.eql(u8, narrow_tag, wide_tag));
    // ... and color on/off changes the render, so it keys apart too.
    const mono = try render.textWithZone(arena, board, false, 80, null, .et);
    defer arena.free(mono);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, mono, "\x1b[") == null);
    const color_tag = try variantTag(arena, .text, 80, null, true, false);
    defer arena.free(color_tag);
    const mono_tag = try variantTag(arena, .text, 80, null, false, false);
    defer arena.free(mono_tag);
    try std.testing.expect(!std.mem.eql(u8, color_tag, mono_tag));
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
