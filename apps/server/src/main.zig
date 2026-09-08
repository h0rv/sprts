const std = @import("std");
const server_app = @import("sprts_server");
const core = @import("sprts_core");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const host = init.environ_map.get("SPRTS_HOST") orelse "0.0.0.0";
    const port_text = init.environ_map.get("PORT") orelse init.environ_map.get("SPRTS_PORT") orelse "8080";
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidPort;
    const base_url = init.environ_map.get("SPRTS_ESPN_BASE_URL") orelse "https://site.api.espn.com/apis/site/v2";
    const address = try std.Io.net.IpAddress.parse(host, port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("listening on http://{s}:{d}", .{ host, listener.socket.address.getPort() });
    const adapter: server_app.provider.EspnAdapter = .{ .allocator = allocator, .io = io, .base_url = base_url };
    var cache = server_app.native_cache.NativeCache.init(allocator, io, server_app.native_cache.realClock);
    defer cache.deinit();
    var subscriber_counts = server_app.stream.Subscribers.init(allocator);
    defer subscriber_counts.deinit(allocator);
    var subscriber_mutex: std.Io.Mutex = .init;
    var shared_poll = server_app.stream.SharedCache.init(allocator);
    defer shared_poll.deinit(allocator);
    // Server-side color default, read once. A remote client's own NO_COLOR
    // or TERM never reaches us; remote callers use ?color=0 or ?color=1.
    const term = init.environ_map.get("TERM") orelse "";
    const color_default = init.environ_map.get("NO_COLOR") == null and !std.mem.eql(u8, term, "dumb");
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.log.err("accept failed: {t}", .{err});
            continue;
        };
        group.async(io, serveConnection, .{ allocator, io, stream, adapter, color_default, &cache, &subscriber_counts, &subscriber_mutex, &shared_poll });
    }
}

fn serveConnection(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, adapter: server_app.provider.EspnAdapter, color_default: bool, cache: *server_app.native_cache.NativeCache, subscriber_counts: *server_app.stream.Subscribers, subscriber_mutex: *std.Io.Mutex, shared_poll: *server_app.stream.SharedCache) void {
    defer stream.close(io);
    var receive_buffer: [16 * 1024]u8 = undefined;
    var send_buffer: [16 * 1024]u8 = undefined;
    var connection_reader = stream.reader(io, &receive_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);
    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.warn("invalid HTTP request: {t}", .{err});
                return;
            },
        };
        handleRequest(allocator, io, &request, adapter, color_default, cache, subscriber_counts, subscriber_mutex, shared_poll) catch |err| {
            std.log.err("request failed: {t}", .{err});
            return;
        };
    }
}

fn handleRequest(allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, adapter: server_app.provider.EspnAdapter, color_default: bool, cache: *server_app.native_cache.NativeCache, subscriber_counts: *server_app.stream.Subscribers, subscriber_mutex: *std.Io.Mutex, shared_poll: *server_app.stream.SharedCache) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Structured per-request log line, emitted once on every exit path.
    var status: std.http.Status = .internal_server_error;
    var cache_state: []const u8 = "n/a";
    var upstream_ms: i64 = 0;
    var route_label: []const u8 = request.head.target;
    var format_label: []const u8 = "text";
    defer std.log.info("method={s} route={s} format={s} status={d} cache={s} upstream_ms={d}", .{
        @tagName(request.head.method),
        route_label,
        format_label,
        @intFromEnum(status),
        cache_state,
        upstream_ms,
    });

    if (request.head.method != .GET and request.head.method != .HEAD) {
        status = .method_not_allowed;
        return respond(request, "method not allowed\n", .text, .method_not_allowed, &.{.{ .name = "allow", .value = "GET, HEAD" }});
    }

    var accept: []const u8 = "";
    var host_header: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "accept")) accept = header.value;
        if (std.ascii.eqlIgnoreCase(header.name, "host")) host_header = header.value;
    }
    const host = server_app.render.sanitizeHost(host_header);

    const target = request.head.target;
    const format = server_app.router.formatFor(target, accept);
    format_label = @tagName(format);
    const route = server_app.router.parse(target);
    route_label = try routeLabel(arena, route);

    switch (route) {
        .health => {
            status = .ok;
            try respond(request, "ok\n", .text, .ok, &.{.{ .name = "cache-control", .value = "no-store" }});
        },
        .openapi => {
            status = .ok;
            try respond(request, try server_app.spec.openApiJson(arena), .json, .ok, commonHeaders());
        },
        .home => |home_route| {
            status = .ok;
            const day = try core.date.today(arena, io);
            const boards = try adapter.fetchAll(arena, day);
            defer server_app.provider.EspnAdapter.releaseAll(boards);
            const color = home_route.color orelse color_default;
            const body = switch (format) {
                .text => if (home_route.oneline)
                    try server_app.render.homeOneLine(arena, boards, color)
                else
                    try server_app.render.homeLive(arena, color, host, boards, day, home_route.quiet),
                .html => try server_app.render.homeHtmlLive(arena, host, boards, day, home_route.quiet),
                .json => try server_app.render.leaguesJson(arena),
            };
            try respond(request, body, format, .ok, commonHeaders());
        },
        .leagues => {
            status = .ok;
            try respond(request, try server_app.render.leaguesJson(arena), .json, .ok, commonHeaders());
        },
        .bad_date => {
            status = .bad_request;
            try respondError(arena, request, "date must be YYYY-MM-DD", format, .bad_request);
        },
        .not_found => {
            status = .not_found;
            try respondError(arena, request, "route not found", format, .not_found);
        },
        .help => |help_route| {
            status = .ok;
            const body = try server_app.help.renderHelp(arena, .{
                .color = help_route.color orelse color_default,
                .quiet = help_route.quiet,
                .oneline = help_route.oneline,
            }, format);
            try respond(request, body, format, .ok, commonHeaders());
        },
        .scoreboard => |score_route| {
            const league = core.leagues.find(score_route.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const slug = try server_app.edge_cache.canonicalSlug(arena, league.slug);
            const day = score_route.date orelse try core.date.today(arena, io);
            // SSE is a text-only progressive render: JSON and HTML shape a
            // document, not a redraw loop. Header- or query-triggered stream
            // requests on those formats get the normal single response.
            const wants_sse = score_route.stream or server_app.router.wantsStream(target, accept);
            if (wants_sse and format == .text) {
                status = .ok;
                // GET only: HEAD must not start an open-ended body. Fall back
                // to the normal single response, consistent with non-stream.
                if (request.head.method == .HEAD) {
                    const board_once = adapter.fetch(arena, league, day) catch |err| {
                        status = .bad_gateway;
                        std.log.warn("ESPN request failed for {s}: {t}", .{ league.slug, err });
                        try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                        return;
                    };
                    const body = try server_app.render.text(arena, board_once, score_route.color orelse color_default, score_route.width, score_route.height);
                    try respond(request, body, format, .ok, commonHeaders());
                    return;
                }
                try serveSse(allocator, arena, io, request, adapter, subscriber_counts, subscriber_mutex, shared_poll, league, day, score_route, color_default);
                return;
            }
            const key: server_app.native_cache.Key = .{ .board = .{ .slug = slug, .day = day } };
            var fetch_ctx = BoardFetchCtx{ .adapter = adapter, .league = league, .day = day };
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            const cached = cache.getOrFetch(arena, key, cache.now(), &fetch_ctx, fetchBoardPayload) catch |err| {
                upstream_ms = elapsedMs(start, io);
                status = .bad_gateway;
                std.log.warn("ESPN request failed for {s}: {t}", .{ league.slug, err });
                try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                return;
            };
            upstream_ms = if (cached.outcome == .hit) 0 else elapsedMs(start, io);
            cache_state = @tagName(cached.outcome);
            status = .ok;
            const board = cached.data.board;
            const body = switch (format) {
                .text => if (score_route.oneline)
                    try server_app.help.scoreOneLine(arena, board, score_route.color orelse color_default, score_route.quiet)
                else
                    try server_app.render.text(arena, board, score_route.color orelse color_default, score_route.width, score_route.height),
                .html => try server_app.render.scoreHtml(arena, board, score_route.width, score_route.height),
                .json => try server_app.render.json(arena, board),
            };
            const extra = cacheHeaders(cache_state);
            try respond(request, body, format, .ok, &extra);
        },
        .game => |game_route| {
            const league = core.leagues.find(game_route.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const slug = try server_app.edge_cache.canonicalSlug(arena, league.slug);
            const key: server_app.native_cache.Key = .{ .detail = .{ .slug = slug, .id = game_route.id } };
            var fetch_ctx = DetailFetchCtx{ .adapter = adapter, .league = league, .id = game_route.id };
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            const cached = cache.getOrFetch(arena, key, cache.now(), &fetch_ctx, fetchDetailPayload) catch |err| switch (err) {
                error.GameNotFound => {
                    upstream_ms = elapsedMs(start, io);
                    status = .not_found;
                    try respondError(arena, request, "game not found", format, .not_found);
                    return;
                },
                else => {
                    upstream_ms = elapsedMs(start, io);
                    status = .bad_gateway;
                    std.log.warn("ESPN detail request failed for {s} {s}: {t}", .{ league.slug, game_route.id, err });
                    try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                    return;
                },
            };
            upstream_ms = if (cached.outcome == .hit) 0 else elapsedMs(start, io);
            cache_state = @tagName(cached.outcome);
            status = .ok;
            const game_detail = cached.data.detail;
            const body = switch (format) {
                .text => try server_app.detail_view.renderText(arena, game_detail, game_route.color orelse color_default, game_route.width, game_route.height),
                .html => try server_app.detail_view.detailHtml(arena, game_detail, game_route.width, game_route.height),
                .json => try server_app.detail_view.json(arena, game_detail),
            };
            const extra = cacheHeaders(cache_state);
            try respond(request, body, format, .ok, &extra);
        },
        .team => |team_route| {
            const league = core.leagues.find(team_route.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const slug = try server_app.edge_cache.canonicalSlug(arena, league.slug);
            const abbr = try server_app.edge_cache.canonicalAbbr(arena, team_route.abbr);
            const key: server_app.native_cache.Key = .{ .team = .{ .slug = slug, .abbr = abbr } };
            var fetch_ctx = TeamFetchCtx{ .adapter = adapter, .league = league, .abbr = team_route.abbr };
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            const cached = cache.getOrFetch(arena, key, cache.now(), &fetch_ctx, fetchTeamPayload) catch |err| switch (err) {
                error.TeamNotFound => {
                    upstream_ms = elapsedMs(start, io);
                    status = .not_found;
                    try respondError(arena, request, "unknown team; see /api/v1/leagues", format, .not_found);
                    return;
                },
                else => {
                    upstream_ms = elapsedMs(start, io);
                    status = .bad_gateway;
                    std.log.warn("ESPN team request failed for {s}/{s}: {t}", .{ league.slug, team_route.abbr, err });
                    try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                    return;
                },
            };
            upstream_ms = if (cached.outcome == .hit) 0 else elapsedMs(start, io);
            cache_state = @tagName(cached.outcome);
            status = .ok;
            const view = cached.data.team;
            const body = switch (format) {
                .text => try server_app.team_view.renderText(arena, view, team_route.color orelse color_default, team_route.width, team_route.height),
                .html => try server_app.team_view.teamHtml(arena, view, league.slug, team_route.width, team_route.height),
                .json => try server_app.team_view.renderJson(arena, view),
            };
            const extra = cacheHeaders(cache_state);
            try respond(request, body, format, .ok, &extra);
        },
    }
}

/// Compact route label for the per-request log line. Boards, details, and
/// teams carry their cache-key components so hits/stales are attributable.
fn routeLabel(arena: std.mem.Allocator, route: server_app.router.Route) ![]u8 {
    return switch (route) {
        .health => arena.dupe(u8, "health"),
        .openapi => arena.dupe(u8, "openapi"),
        .home => arena.dupe(u8, "home"),
        .leagues => arena.dupe(u8, "leagues"),
        .bad_date => arena.dupe(u8, "bad_date"),
        .not_found => arena.dupe(u8, "not_found"),
        .help => arena.dupe(u8, "help"),
        .scoreboard => |r| std.fmt.allocPrint(arena, "board/{s}/{s}", .{ r.league, r.date orelse "today" }),
        .game => |r| std.fmt.allocPrint(arena, "detail/{s}/{s}", .{ r.league, r.id }),
        .team => |r| std.fmt.allocPrint(arena, "team/{s}/{s}", .{ r.league, r.abbr }),
    };
}

fn elapsedMs(start: std.Io.Clock.Timestamp, io: std.Io) i64 {
    return start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
}

/// Upstream fetch adapters for the cache: each returns one normalized
/// payload, which `getOrFetch` stores on success. Render flags are applied
/// after the lookup, so they never enter the key.
const BoardFetchCtx = struct { adapter: server_app.provider.EspnAdapter, league: *const core.leagues.League, day: []const u8 };
const DetailFetchCtx = struct { adapter: server_app.provider.EspnAdapter, league: *const core.leagues.League, id: []const u8 };
const TeamFetchCtx = struct { adapter: server_app.provider.EspnAdapter, league: *const core.leagues.League, abbr: []const u8 };

fn fetchBoardPayload(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!server_app.native_cache.Data {
    const c: *BoardFetchCtx = @ptrCast(@alignCast(ctx));
    return .{ .board = try c.adapter.fetch(arena, c.league, c.day) };
}

fn fetchDetailPayload(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!server_app.native_cache.Data {
    const c: *DetailFetchCtx = @ptrCast(@alignCast(ctx));
    return .{ .detail = try c.adapter.fetchDetail(arena, c.league, c.id) };
}

fn fetchTeamPayload(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!server_app.native_cache.Data {
    const c: *TeamFetchCtx = @ptrCast(@alignCast(ctx));
    return .{ .team = try server_app.provider.fetchTeam(c.adapter, arena, c.league, c.abbr) };
}

/// Success headers for cached routes: the shared cache headers plus the
/// edge-parity `x-sprts-cache` hit/miss/stale marker.
fn cacheHeaders(cache_state: []const u8) [4]std.http.Header {
    var extra: [4]std.http.Header = undefined;
    @memcpy(extra[0..3], commonHeaders());
    extra[3] = .{ .name = "x-sprts-cache", .value = cache_state };
    return extra;
}

/// Serve one SSE connection for a (league, day, render) resource. The first
/// frame goes out immediately from a normal ESPN fetch; afterwards polls are
/// shared per resource: each 1s tick at most one subscriber fetches ESPN per
/// interval (mutex-guarded SharedCache in stream.zig), and the rest fan out
/// from the cached frame. Only a changed fingerprint pushes a new frame. The
/// render uses the same text path as a single response, so colors and
/// width/height behave identically. Subscriber-gated: attaching/detaching the
/// shared counts is what starts/stops ESPN polling for the resource — the
/// last detach stops the timer and drops the cache entry. A failed body write
/// means the client went away, so detach and return (ending the loop)
/// instead of erroring the connection.
fn serveSse(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    adapter: server_app.provider.EspnAdapter,
    subscriber_counts: *server_app.stream.Subscribers,
    subscriber_mutex: *std.Io.Mutex,
    shared_poll: *server_app.stream.SharedCache,
    league: *const core.leagues.League,
    day: []const u8,
    score_route: server_app.router.ScoreboardRoute,
    color_default: bool,
) !void {
    const stream = server_app.stream;
    const color = score_route.color orelse color_default;
    const day_owned = try arena.dupe(u8, day);
    const key = try stream.subKey(arena, league.slug, day_owned, color, score_route.width, score_route.height);

    // Fetch before opening the stream: an unavailable upstream still gets
    // the normal single 502 instead of an empty SSE body.
    const initial = adapter.fetch(arena, league, day_owned) catch |err| {
        std.log.warn("ESPN request failed for {s}: {t}", .{ league.slug, err });
        try respondError(arena, request, "scores are temporarily unavailable", .text, .bad_gateway);
        return;
    };

    var send_buffer: [16 * 1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .status = .ok,
            .keep_alive = true,
            .extra_headers = &.{
                .{ .name = "content-type", .value = stream.content_type },
                .{ .name = "cache-control", .value = stream.cache_control },
                .{ .name = "connection", .value = "keep-alive" },
                .{ .name = "vary", .value = "accept" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            },
        },
    });

    const initial_text = try server_app.render.text(arena, initial, color, score_route.width, score_route.height);
    const initial_frame = try stream.frame(arena, initial_text);
    body_writer.writer.writeAll(initial_frame) catch return;
    // Two-stage flush: the inner writer buffers up to 16KB before emitting
    // a chunk (BodyWriter.flush only flushes the socket side), so drain it
    // first or small frames never reach the client until the buffer fills.
    body_writer.writer.flush() catch return;
    body_writer.flush() catch return;

    {
        subscriber_mutex.lockUncancelable(io);
        defer subscriber_mutex.unlock(io);
        _ = subscriber_counts.attach(gpa, key) catch {
            body_writer.end() catch {};
            return;
        };
    }
    defer {
        subscriber_mutex.lockUncancelable(io);
        defer subscriber_mutex.unlock(io);
        const remaining = subscriber_counts.detach(gpa, key);
        if (remaining == 0) shared_poll.remove(gpa, key);
    }

    var last = stream.fingerprint(initial);
    const initial_interval = stream.pollIntervalSec(initial);
    {
        // Warm the shared cache so later subscribers share this poll. Only
        // store when no fresh entry exists, so a racing connect fetch can't
        // clobber a newer frame another subscriber just published.
        const now_s = adapter.clock(io);
        subscriber_mutex.lockUncancelable(io);
        defer subscriber_mutex.unlock(io);
        if (shared_poll.needsPoll(key, now_s)) {
            shared_poll.store(gpa, key, now_s, last, initial_interval, initial_frame) catch {};
        }
    }
    var elapsed_s: u64 = 0;
    const tick_s: u64 = 1;

    while (true) {
        const step: std.Io.Timeout = .{ .duration = .{
            .raw = .fromSeconds(@intCast(tick_s)),
            .clock = .real,
        } };
        step.sleep(io) catch return;
        elapsed_s += tick_s;

        if (elapsed_s % @as(u64, stream.keepalive_s) == 0) {
            body_writer.writer.writeAll(stream.keepalive_frame) catch return;
            body_writer.writer.flush() catch return;
            body_writer.flush() catch return;
        }

        {
            subscriber_mutex.lockUncancelable(io);
            const active = subscriber_counts.count(key);
            subscriber_mutex.unlock(io);
            if (active == 0) return;
        }

        // Block scope per tick: the poll scratch arena is backed by the
        // long-lived gpa (not the per-request arena) so deinit each
        // iteration truly frees fetch buffers instead of accumulating them
        // in the connection arena for the life of the stream.
        {
            var poll_arena_state = std.heap.ArenaAllocator.init(gpa);
            defer poll_arena_state.deinit();
            const poll_arena = poll_arena_state.allocator();

            const now_s = adapter.clock(io);
            const is_fetcher = blk: {
                subscriber_mutex.lockUncancelable(io);
                defer subscriber_mutex.unlock(io);
                break :blk shared_poll.claim(gpa, key, now_s) catch false;
            };

            if (is_fetcher) {
                const board = adapter.fetch(poll_arena, league, day_owned) catch |err| {
                    // Claim already advanced last_poll, so the failure backs
                    // off: no cache update, next attempt only after the
                    // interval, one fetch attempt total per tick.
                    std.log.warn("ESPN request failed for {s}: {t}", .{ league.slug, err });
                    continue;
                };
                const current = stream.fingerprint(board);
                const next_interval = stream.pollIntervalSec(board);
                const body = server_app.render.text(poll_arena, board, color, score_route.width, score_route.height) catch continue;
                const event = stream.frame(poll_arena, body) catch continue;
                {
                    subscriber_mutex.lockUncancelable(io);
                    defer subscriber_mutex.unlock(io);
                    shared_poll.store(gpa, key, now_s, current, next_interval, event) catch {};
                }
                if (!stream.changed(last, current)) continue;
                last = current;
                body_writer.writer.writeAll(event) catch return;
                body_writer.writer.flush() catch return;
                body_writer.flush() catch return;
            } else {
                // Fan-out: copy the cached frame while still holding the
                // lock — the fetcher may free/replace it on store.
                var hit_fp: u64 = undefined;
                const pending_copy: []u8 = blk: {
                    subscriber_mutex.lockUncancelable(io);
                    defer subscriber_mutex.unlock(io);
                    const entry = shared_poll.get(key) orelse break :blk null;
                    if (!entry.ready) break :blk null;
                    if (!stream.changed(last, entry.fingerprint)) break :blk null;
                    hit_fp = entry.fingerprint;
                    const copy = poll_arena.dupe(u8, entry.frame) catch break :blk null;
                    break :blk copy;
                } orelse continue;
                last = hit_fp;
                body_writer.writer.writeAll(pending_copy) catch return;
                body_writer.writer.flush() catch return;
                body_writer.flush() catch return;
            }
        }
    }
}

fn respondError(arena: std.mem.Allocator, request: *std.http.Server.Request, message: []const u8, format: server_app.router.Format, status: std.http.Status) !void {
    try respond(request, try server_app.render.errorBody(arena, message, format), format, status, commonHeaders());
}

fn respond(request: *std.http.Server.Request, body: []const u8, format: server_app.router.Format, status: std.http.Status, extra: []const std.http.Header) !void {
    const content_type = switch (format) {
        .text => "text/plain; charset=utf-8",
        .html => "text/html; charset=utf-8",
        .json => "application/json; charset=utf-8",
    };
    var headers: [5]std.http.Header = undefined;
    headers[0] = .{ .name = "content-type", .value = content_type };
    var length: usize = 1;
    for (extra) |header| {
        headers[length] = header;
        length += 1;
    }
    try request.respond(body, .{ .status = status, .extra_headers = headers[0..length] });
}

fn commonHeaders() []const std.http.Header {
    return &.{
        .{ .name = "cache-control", .value = "public, max-age=30, stale-if-error=300" },
        .{ .name = "vary", .value = "accept" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
}
