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
    // Zone + clock once per request: missing ?date resolves to the ET
    // calendar day (ESPN parity); explicit ?date wins verbatim via
    // tz.resolveDay. Native has no client-TZ signal: ET default + ?tz=.
    const zone = server_app.tz.zoneFromTarget(target);
    const now_s = adapter.clock(io);

    switch (route) {
        .health => {
            status = .ok;
            try respond(request, "ok\n", .text, .ok, &.{.{ .name = "cache-control", .value = "no-store" }});
        },
        .openapi => {
            status = .ok;
            try respond(request, try server_app.spec.openApiJson(arena), .json, .ok, commonHeaders());
        },
        .docs => {
            status = .ok;
            try respond(request, try server_app.spec.docsHtml(arena), .html, .ok, commonHeaders());
        },
        .llms => {
            status = .ok;
            try respond(request, try server_app.spec.llmsTxt(arena), .text, .ok, commonHeaders());
        },
        .favicon => {
            // Static bytes with their own content type (not a Format:
            // respond() only maps text/html/json).
            status = .ok;
            var fav_headers: [3]std.http.Header = undefined;
            fav_headers[0] = .{ .name = "content-type", .value = "image/svg+xml" };
            fav_headers[1] = .{ .name = "cache-control", .value = "public, max-age=86400" };
            fav_headers[2] = .{ .name = "x-content-type-options", .value = "nosniff" };
            try request.respond(server_app.render.favicon_svg, .{ .status = status, .extra_headers = fav_headers[0..] });
        },
        .home => |home_route| {
            status = .ok;
            // Explicit ?date wins verbatim via tz.resolveDay (relative
            // tokens ride the request zone); missing ?date is today.
            // Boards come from the shared per-league cache entries (same
            // as /all and the single-board route): fetch-once-per-window
            // with the live/final TTL split, not 20 fresh upstream
            // fetches per hit. Outages degrade to links (null boards).
            const day = try server_app.tz.resolveDay(arena, home_route.date, now_s, zone);
            const boards = try adapter.fetchAllCached(arena, cache, day, cache.now());
            const color = home_route.color orelse color_default;
            const body = switch (format) {
                .text => if (home_route.oneline)
                    try server_app.render.homeOneLineWithZone(arena, boards, color, zone)
                else
                    try server_app.render.homeLiveWithZone(arena, color, host, boards, day, home_route.quiet, zone, home_route.date != null),
                .html => try server_app.render.homeHtmlLive(arena, host, boards, day, home_route.quiet, home_route.date != null),
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
            const slug = try core.cache.canonicalSlug(arena, league.slug);
            const day = try server_app.tz.resolveDay(arena, score_route.date, now_s, zone);
            // SSE is a text-only progressive render: JSON and HTML shape a
            // document, not a redraw loop. Header- or query-triggered stream
            // requests on those formats get the normal single response.
            // A ?week=/seasontype board also takes the single response: the
            // shared stream poll key has no week component, so selector
            // boards never join the shared poll.
            const wants_sse = score_route.stream or server_app.router.wantsStream(target, accept);
            if (wants_sse and format == .text and score_route.week == null and score_route.seasontype == null) {
                status = .ok;
                // GET only: HEAD must not start an open-ended body. Fall back
                // to the normal single response, consistent with non-stream.
                if (request.head.method == .HEAD) {
                    const board_once = adapter.fetchWeek(arena, league, day, score_route.week, score_route.seasontype) catch |err| {
                        status = .bad_gateway;
                        std.log.warn("ESPN request failed for {s}: {t}", .{ league.slug, err });
                        try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                        return;
                    };
                    const body = try server_app.render.textWithZoneArt(arena, board_once, score_route.color orelse color_default, score_route.width, score_route.height, zone, score_route.art);
                    try respond(request, body, format, .ok, commonHeaders());
                    return;
                }
                try serveSse(allocator, arena, io, request, adapter, subscriber_counts, subscriber_mutex, shared_poll, league, day, score_route, color_default, zone);
                return;
            }
            // ?week=/seasontype boards bypass the cache: the board key is
            // (slug, day) and a selector must never poison date-driven
            // entries. Direct fetchWeek keeps the default null path cached
            // as before.
            if (score_route.week != null or score_route.seasontype != null) {
                const week_start = std.Io.Clock.Timestamp.now(io, .awake);
                const board = adapter.fetchWeek(arena, league, day, score_route.week, score_route.seasontype) catch |err| {
                    upstream_ms = elapsedMs(week_start, io);
                    status = .bad_gateway;
                    std.log.warn("ESPN request failed for {s}: {t}", .{ league.slug, err });
                    try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                    return;
                };
                cache_state = "n/a";
                status = .ok;
                const body = switch (format) {
                    .text => try server_app.render.textWithZoneArt(arena, board, score_route.color orelse color_default, score_route.width, score_route.height, zone, score_route.art),
                    .html => try server_app.render.scoreHtmlWithZoneArtMtime(arena, board, score_route.width, score_route.height, zone, score_route.art, now_s),
                    .json => try server_app.render.json(arena, board),
                };
                try respond(request, body, format, .ok, commonHeaders());
                return;
            }
            // TTL variants resolve inside getOrFetchBoard: liveness is only
            // known post-fetch, so both the live (10s) and final (30s)
            // entries are probed before fetching.
            var fetch_ctx = BoardFetchCtx{ .adapter = adapter, .league = league, .day = day };
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            const cached = cache.getOrFetchBoard(arena, slug, day, cache.now(), &fetch_ctx, fetchBoardPayload) catch |err| {
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
                    try server_app.render.textWithZoneArt(arena, board, score_route.color orelse color_default, score_route.width, score_route.height, zone, score_route.art),
                .html => try server_app.render.scoreHtmlWithZoneArtMtime(arena, board, score_route.width, score_route.height, zone, score_route.art, now_s),
                .json => try server_app.render.json(arena, board),
            };
            const extra = cacheHeaders(cache_state);
            try respond(request, body, format, .ok, &extra);
        },
        .all => |all_route| {
            status = .ok;
            const day = try server_app.tz.resolveDay(arena, all_route.date, now_s, zone);
            // Shared fan-out with home: same per-league cache entries,
            // fetch-once-per-window across home/board/digest.
            const results = try adapter.fetchAllCached(arena, cache, day, cache.now());
            var sections = try arena.alloc(server_app.digest.DigestSection, results.len);
            for (results, 0..) |result, i| sections[i] = .{ .league = result.league, .board = result.board };
            cache_state = "n/a";
            const color = all_route.color orelse color_default;
            const body = switch (format) {
                .text => if (all_route.oneline)
                    try allOneLine(arena, sections, color, all_route.quiet, zone)
                else
                    try server_app.digest.textWithZoneArt(arena, sections, day, color, all_route.width, all_route.height, all_route.quiet, zone, all_route.art, all_route.date != null),
                .html => try server_app.digest.htmlWithZoneArt(arena, sections, day, all_route.width, all_route.height, all_route.quiet, zone, all_route.art, all_route.date != null),
                .json => try server_app.digest.json(arena, sections, day),
            };
            try respond(request, body, format, .ok, commonHeaders());
        },
        .game => |game_route| {
            const league = core.leagues.find(game_route.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const slug = try core.cache.canonicalSlug(arena, league.slug);
            var fetch_ctx = DetailFetchCtx{ .adapter = adapter, .league = league, .id = game_route.id };
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            const cached = cache.getOrFetchDetail(arena, slug, game_route.id, cache.now(), &fetch_ctx, fetchDetailPayload) catch |err| {
                if (core.isNotFound(err)) {
                    upstream_ms = elapsedMs(start, io);
                    status = .not_found;
                    try respondError(arena, request, "game not found", format, .not_found);
                    return;
                }
                upstream_ms = elapsedMs(start, io);
                status = .bad_gateway;
                std.log.warn("ESPN detail request failed for {s} {s}: {t}", .{ league.slug, game_route.id, err });
                try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                return;
            };
            upstream_ms = if (cached.outcome == .hit) 0 else elapsedMs(start, io);
            cache_state = @tagName(cached.outcome);
            status = .ok;
            const game_detail = cached.data.detail;
            // One-line fallback via the shared predicate: text + ?0 selects
            // renderTextOneLine, every other combination keeps the full box
            // (html/json ignore ?0 by team-route precedent).
            const body = if (server_app.router.gameOneLine(game_route, format))
                try server_app.detail_view.renderTextOneLine(arena, game_detail, game_route.color orelse color_default, game_route.quiet)
            else switch (format) {
                .text => try server_app.detail_view.renderText(arena, game_detail, game_route.color orelse color_default, game_route.width, game_route.height),
                .html => try server_app.detail_view.detailHtmlMtime(arena, game_detail, game_route.width, game_route.height, now_s),
                .json => try server_app.detail_view.json(arena, game_detail),
            };
            const extra = cacheHeaders(cache_state);
            try respond(request, body, format, .ok, &extra);
        },
        .today => |today_route| {
            // Human shortcut: resolve the team's game today, then redirect
            // to its canonical address (game id, or the team page when no
            // game today). Fresh-only, no-store, no query carried over.
            const league = core.leagues.find(today_route.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const view = server_app.provider.fetchTeam(adapter, arena, league, today_route.abbr) catch |err| {
                if (core.isNotFound(err)) {
                    status = .not_found;
                    try respondError(arena, request, "unknown team; see /api/v1/leagues", format, .not_found);
                    return;
                }
                status = .bad_gateway;
                std.log.warn("ESPN team request failed for {s}/{s}: {t}", .{ league.slug, today_route.abbr, err });
                try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                return;
            };
            const dest = if (core.schedule.findTodayGame(view)) |game|
                if (today_route.api)
                    try std.fmt.allocPrint(arena, "/api/v1/{s}/{s}", .{ league.slug, game.id })
                else
                    try std.fmt.allocPrint(arena, "/{s}/{s}", .{ league.slug, game.id })
            else if (today_route.api)
                try std.fmt.allocPrint(arena, "/api/v1/{s}/{s}", .{ league.slug, today_route.abbr })
            else
                try std.fmt.allocPrint(arena, "/{s}/{s}", .{ league.slug, today_route.abbr });
            defer arena.free(dest);
            status = .found;
            const redirect_body = try std.fmt.allocPrint(arena, "{s}\n", .{dest});
            defer arena.free(redirect_body);
            const redirect_headers = [_]std.http.Header{
                .{ .name = "location", .value = dest },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            };
            try request.respond(redirect_body, .{ .status = status, .extra_headers = &redirect_headers });
        },
        .date_alias => |alias| {
            // Human game alias, date form: resolve the day (relative tokens
            // ride the request zone via tz.resolveDay, like the scoreboard),
            // fetch that board fresh, and redirect to the canonical game id
            // (alias.n orelse 1 selects among doubleheader same-pair games).
            // A miss 404s: plain on all-duel days, duel-only hint past them.
            // Fresh-only, no-store, no query carried over (today-arm parity).
            const league = core.leagues.find(alias.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const day = try server_app.tz.resolveDay(arena, alias.date, now_s, zone);
            const board = adapter.fetch(arena, league, day) catch |err| {
                status = .bad_gateway;
                std.log.warn("ESPN request failed for {s}: {t}", .{ league.slug, err });
                try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                return;
            };
            const game = server_app.provider.findGameByMatchupN(board, alias.away, alias.home, alias.n orelse 1) orelse {
                status = .not_found;
                const browse = try std.fmt.allocPrint(arena, "/{s}?date={s}", .{ league.slug, day });
                defer arena.free(browse);
                try respondError(arena, request, try server_app.provider.aliasMissMessage(arena, board, browse), format, .not_found);
                return;
            };
            const dest = try std.fmt.allocPrint(arena, "/{s}/{s}", .{ league.slug, game.id });
            defer arena.free(dest);
            status = .found;
            const redirect_body = try std.fmt.allocPrint(arena, "{s}\n", .{dest});
            defer arena.free(redirect_body);
            const redirect_headers = [_]std.http.Header{
                .{ .name = "location", .value = dest },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            };
            try request.respond(redirect_body, .{ .status = status, .extra_headers = &redirect_headers });
        },
        .week_alias => |alias| {
            // Human game alias, week form (football only): fetch the week's
            // board with NO dates param (ESPN resolves the week alone;
            // sending dates alongside empties the slate), verify the response
            // season year against the URL season (ESPN ignores unknown season
            // params — a mismatch 404s, never misleads), and redirect to the
            // canonical game id. Fresh-only, no-store (today-arm parity).
            const league = core.leagues.find(alias.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            if (!std.mem.eql(u8, league.sport, "Football")) {
                status = .not_found;
                try respondError(arena, request, "week games are football-only", format, .not_found);
                return;
            }
            const season = std.fmt.parseInt(u16, alias.season, 10) catch {
                status = .not_found;
                try respondError(arena, request, "game not found", format, .not_found);
                return;
            };
            const week_board = adapter.fetchWeekBoard(arena, league, alias.season, alias.week) catch |err| {
                status = .bad_gateway;
                std.log.warn("ESPN week request failed for {s}: {t}", .{ league.slug, err });
                try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                return;
            };
            if (week_board.season_year == null or week_board.season_year.? != season) {
                status = .not_found;
                try respondError(arena, request, "game not found", format, .not_found);
                return;
            }
            const game = server_app.provider.findGameByMatchupN(week_board.board, alias.away, alias.home, alias.n orelse 1) orelse {
                status = .not_found;
                const browse = try std.fmt.allocPrint(arena, "/{s}?week={d}", .{ league.slug, alias.week });
                defer arena.free(browse);
                try respondError(arena, request, try server_app.provider.aliasMissMessage(arena, week_board.board, browse), format, .not_found);
                return;
            };
            const dest = try std.fmt.allocPrint(arena, "/{s}/{s}", .{ league.slug, game.id });
            defer arena.free(dest);
            status = .found;
            const redirect_body = try std.fmt.allocPrint(arena, "{s}\n", .{dest});
            defer arena.free(redirect_body);
            const redirect_headers = [_]std.http.Header{
                .{ .name = "location", .value = dest },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            };
            try request.respond(redirect_body, .{ .status = status, .extra_headers = &redirect_headers });
        },
        .date_event => |alias| {
            // Human game ordinal, date form: resolve the day (relative
            // tokens ride the request zone via tz.resolveDay, like the
            // scoreboard), fetch that board fresh, and redirect to the
            // Nth game in board order (every game: duels and non-duels
            // alike). A miss 404s with the duel/non-duel-aware message.
            // Fresh-only, no-store (date-alias-arm parity).
            const league = core.leagues.find(alias.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const day = try server_app.tz.resolveDay(arena, alias.date, now_s, zone);
            const board = adapter.fetch(arena, league, day) catch |err| {
                status = .bad_gateway;
                std.log.warn("ESPN request failed for {s}: {t}", .{ league.slug, err });
                try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                return;
            };
            const game = server_app.provider.findGameByOrdinal(board, alias.n) orelse {
                status = .not_found;
                const browse = try std.fmt.allocPrint(arena, "/{s}?date={s}", .{ league.slug, day });
                defer arena.free(browse);
                try respondError(arena, request, try server_app.provider.aliasMissMessage(arena, board, browse), format, .not_found);
                return;
            };
            const dest = try std.fmt.allocPrint(arena, "/{s}/{s}", .{ league.slug, game.id });
            defer arena.free(dest);
            status = .found;
            const redirect_body = try std.fmt.allocPrint(arena, "{s}\n", .{dest});
            defer arena.free(redirect_body);
            const redirect_headers = [_]std.http.Header{
                .{ .name = "location", .value = dest },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            };
            try request.respond(redirect_body, .{ .status = status, .extra_headers = &redirect_headers });
        },
        .week_event => |alias| {
            // Human game ordinal, week form (football only): fetch the
            // week's board with NO dates param, verify the response season
            // year against the URL season (a mismatch 404s, never
            // misleads), and redirect to the Nth game in board order.
            // Fresh-only, no-store (week-alias-arm parity).
            const league = core.leagues.find(alias.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            if (!std.mem.eql(u8, league.sport, "Football")) {
                status = .not_found;
                try respondError(arena, request, "week games are football-only", format, .not_found);
                return;
            }
            const season = std.fmt.parseInt(u16, alias.season, 10) catch {
                status = .not_found;
                try respondError(arena, request, "game not found", format, .not_found);
                return;
            };
            const week_board = adapter.fetchWeekBoard(arena, league, alias.season, alias.week) catch |err| {
                status = .bad_gateway;
                std.log.warn("ESPN week request failed for {s}: {t}", .{ league.slug, err });
                try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                return;
            };
            if (week_board.season_year == null or week_board.season_year.? != season) {
                status = .not_found;
                try respondError(arena, request, "game not found", format, .not_found);
                return;
            }
            const game = server_app.provider.findGameByOrdinal(week_board.board, alias.n) orelse {
                status = .not_found;
                const browse = try std.fmt.allocPrint(arena, "/{s}?week={d}", .{ league.slug, alias.week });
                defer arena.free(browse);
                try respondError(arena, request, try server_app.provider.aliasMissMessage(arena, week_board.board, browse), format, .not_found);
                return;
            };
            const dest = try std.fmt.allocPrint(arena, "/{s}/{s}", .{ league.slug, game.id });
            defer arena.free(dest);
            status = .found;
            const redirect_body = try std.fmt.allocPrint(arena, "{s}\n", .{dest});
            defer arena.free(redirect_body);
            const redirect_headers = [_]std.http.Header{
                .{ .name = "location", .value = dest },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            };
            try request.respond(redirect_body, .{ .status = status, .extra_headers = &redirect_headers });
        },
        .team => |team_route| {
            const league = core.leagues.find(team_route.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const slug = try core.cache.canonicalSlug(arena, league.slug);
            const abbr = try core.cache.canonicalAbbr(arena, team_route.abbr);
            const key: server_app.native_cache.Key = .{ .team = .{ .slug = slug, .abbr = abbr } };
            var fetch_ctx = TeamFetchCtx{ .adapter = adapter, .league = league, .abbr = team_route.abbr };
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            const cached = cache.getOrFetch(arena, key, cache.now(), &fetch_ctx, fetchTeamPayload) catch |err| {
                if (core.isNotFound(err)) {
                    upstream_ms = elapsedMs(start, io);
                    status = .not_found;
                    try respondError(arena, request, "unknown team; see /api/v1/leagues", format, .not_found);
                    return;
                }
                upstream_ms = elapsedMs(start, io);
                status = .bad_gateway;
                std.log.warn("ESPN team request failed for {s}/{s}: {t}", .{ league.slug, team_route.abbr, err });
                try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                return;
            };
            upstream_ms = if (cached.outcome == .hit) 0 else elapsedMs(start, io);
            cache_state = @tagName(cached.outcome);
            status = .ok;
            const view = cached.data.team;
            const body = switch (format) {
                .text => if (team_route.oneline)
                    try server_app.team_view.renderTextOneLine(arena, view, team_route.color orelse color_default, team_route.quiet)
                else
                    try server_app.team_view.renderTextArt(arena, view, team_route.color orelse color_default, team_route.width, team_route.height, team_route.art),
                .html => try server_app.team_view.teamHtmlArt(arena, view, league.slug, team_route.width, team_route.height, team_route.art),
                .json => try server_app.team_view.renderJson(arena, view),
            };
            const extra = cacheHeaders(cache_state);
            try respond(request, body, format, .ok, &extra);
        },
        .standings => |standings_route| {
            const league = core.leagues.find(standings_route.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const slug = try core.cache.canonicalSlug(arena, league.slug);
            const key: server_app.native_cache.Key = .{ .standings = .{ .slug = slug } };
            var fetch_ctx = StandingsFetchCtx{ .adapter = adapter, .league = league };
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            const cached = cache.getOrFetch(arena, key, cache.now(), &fetch_ctx, fetchStandingsPayload) catch |err| {
                if (core.isNotFound(err)) {
                    upstream_ms = elapsedMs(start, io);
                    status = .not_found;
                    try respondError(arena, request, "standings unavailable for this league; see /api/v1/leagues", format, .not_found);
                    return;
                }
                upstream_ms = elapsedMs(start, io);
                status = .bad_gateway;
                std.log.warn("ESPN standings request failed for {s}: {t}", .{ league.slug, err });
                try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                return;
            };
            upstream_ms = if (cached.outcome == .hit) 0 else elapsedMs(start, io);
            cache_state = @tagName(cached.outcome);
            status = .ok;
            const table_data = cached.data.standings;
            const body = switch (format) {
                .text => try server_app.standings_view.text(arena, table_data, standings_route.color orelse color_default, standings_route.width, standings_route.height),
                .html => try server_app.standings_view.html(arena, table_data, standings_route.width, standings_route.height),
                .json => try server_app.standings_view.json(arena, table_data),
            };
            const extra = cacheHeaders(cache_state);
            try respond(request, body, format, .ok, &extra);
        },
        .tour => |tour_route| {
            // Read-only terminal tour: same-origin HTML page loading
            // vendored xterm.js, fed by the text SSE stream. Ignores
            // content negotiation (curl gets the page too); unknown
            // leagues 404 like the scoreboard.
            if (tour_route.league) |slug| {
                const league = core.leagues.find(slug) orelse {
                    status = .not_found;
                    try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                    return;
                };
                status = .ok;
                try respond(request, try server_app.tour.tourHtml(arena, league.slug), .html, .ok, commonHeaders());
            } else {
                status = .ok;
                try respond(request, try server_app.tour.tourHtml(arena, null), .html, .ok, commonHeaders());
            }
        },
        .tour_asset => |asset| {
            // Vendored xterm.js bytes with their own content type (not a
            // Format: respond() only maps text/html/json) — favicon
            // pattern, long-cache immutable vendor bytes.
            status = .ok;
            const is_js = std.mem.eql(u8, asset.name, "xterm.min.js");
            const body = if (is_js) server_app.tour.xterm_js else server_app.tour.xterm_css;
            const content_type = if (is_js) server_app.tour.js_content_type else server_app.tour.css_content_type;
            var asset_headers: [3]std.http.Header = undefined;
            asset_headers[0] = .{ .name = "content-type", .value = content_type };
            asset_headers[1] = .{ .name = "cache-control", .value = "public, max-age=86400" };
            asset_headers[2] = .{ .name = "x-content-type-options", .value = "nosniff" };
            try request.respond(body, .{ .status = status, .extra_headers = asset_headers[0..] });
        },
        .teams => |teams_route| {
            // JSON-only endpoint (no text/HTML twin): the team list is a
            // picker payload for JSON clients, and no text table exists
            // for it — so the human path serves the same JSON body.
            const league = core.leagues.find(teams_route.league) orelse {
                status = .not_found;
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const slug = try core.cache.canonicalSlug(arena, league.slug);
            const key: server_app.native_cache.Key = .{ .teams = .{ .slug = slug } };
            var fetch_ctx = TeamsFetchCtx{ .adapter = adapter, .league = league };
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            const cached = cache.getOrFetch(arena, key, cache.now(), &fetch_ctx, fetchTeamsPayload) catch |err| {
                upstream_ms = elapsedMs(start, io);
                status = .bad_gateway;
                std.log.warn("ESPN teams request failed for {s}: {t}", .{ league.slug, err });
                try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                return;
            };
            upstream_ms = if (cached.outcome == .hit) 0 else elapsedMs(start, io);
            cache_state = @tagName(cached.outcome);
            status = .ok;
            const body = try server_app.render.teamsJson(arena, cached.data.teams);
            const extra = cacheHeaders(cache_state);
            try respond(request, body, .json, .ok, &extra);
        },
    }
}

/// `/all?0`: every game in the digest, one per line, across leagues.
///
/// Shared composer: digest sections adapt trivially to
/// `provider.LeagueResult` (same `league` + `board` fields) and render
/// through `render.homeOneLineWithZone` — the exact composer the worker
/// `serveAll` one-line branch uses, so both serve paths emit byte-identical
/// lines: homeOneLine per-game shape, `M/D ZONE` labels, status plus winner
/// check on scored duels, both-sides home/away resolution. `?0` carries no
/// header/footer by construction (same as `/?0`), so `quiet` selects
/// nothing and both modes render identically. Idle/unavailable leagues emit
/// nothing; an empty digest is a single `No games scheduled.` line.
fn allOneLine(
    arena: std.mem.Allocator,
    sections: []const server_app.digest.DigestSection,
    color: bool,
    quiet: bool,
    zone: server_app.tz.Zone,
) ![]u8 {
    _ = quiet;
    const results = try arena.alloc(server_app.provider.LeagueResult, sections.len);
    defer arena.free(results);
    for (sections, 0..) |section, i| results[i] = .{ .league = section.league, .board = section.board };
    return server_app.render.homeOneLineWithZone(arena, results, color, zone);
}

/// Compact route label for the per-request log line. Boards, details, and
/// teams carry their cache-key components so hits/stales are attributable.
fn routeLabel(arena: std.mem.Allocator, route: server_app.router.Route) ![]u8 {
    return switch (route) {
        .health => arena.dupe(u8, "health"),
        .openapi => arena.dupe(u8, "openapi"),
        .docs => arena.dupe(u8, "docs"),
        .llms => arena.dupe(u8, "llms"),
        .favicon => arena.dupe(u8, "favicon"),
        .home => |r| std.fmt.allocPrint(arena, "home/{s}", .{r.date orelse "today"}),
        .leagues => arena.dupe(u8, "leagues"),
        .bad_date => arena.dupe(u8, "bad_date"),
        .not_found => arena.dupe(u8, "not_found"),
        .help => arena.dupe(u8, "help"),
        .scoreboard => |r| std.fmt.allocPrint(arena, "board/{s}/{s}", .{ r.league, r.date orelse "today" }),
        .all => |r| std.fmt.allocPrint(arena, "all/{s}", .{r.date orelse "today"}),
        .game => |r| std.fmt.allocPrint(arena, "detail/{s}/{s}", .{ r.league, r.id }),
        .team => |r| std.fmt.allocPrint(arena, "team/{s}/{s}", .{ r.league, r.abbr }),
        .today => |r| std.fmt.allocPrint(arena, "today/{s}/{s}", .{ r.league, r.abbr }),
        .date_alias => |r| std.fmt.allocPrint(arena, "date-alias/{s}/{s}", .{ r.league, r.date }),
        .week_alias => |r| std.fmt.allocPrint(arena, "week-alias/{s}/{s}", .{ r.league, r.season }),
        .date_event => |r| std.fmt.allocPrint(arena, "date-event/{s}/{s}", .{ r.league, r.date }),
        .week_event => |r| std.fmt.allocPrint(arena, "week-event/{s}/{s}", .{ r.league, r.season }),
        .standings => |r| std.fmt.allocPrint(arena, "standings/{s}", .{r.league}),
        .tour => |r| if (r.league) |slug| try std.fmt.allocPrint(arena, "tour/{s}", .{slug}) else arena.dupe(u8, "tour"),
        .tour_asset => |r| std.fmt.allocPrint(arena, "tour-asset/{s}", .{r.name}),
        .teams => |r| std.fmt.allocPrint(arena, "teams/{s}", .{r.league}),
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
const StandingsFetchCtx = struct { adapter: server_app.provider.EspnAdapter, league: *const core.leagues.League };
const TeamsFetchCtx = struct { adapter: server_app.provider.EspnAdapter, league: *const core.leagues.League };

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

fn fetchStandingsPayload(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!server_app.native_cache.Data {
    const c: *StandingsFetchCtx = @ptrCast(@alignCast(ctx));
    return .{ .standings = try server_app.provider.fetchStandings(c.adapter, arena, c.league) };
}

fn fetchTeamsPayload(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!server_app.native_cache.Data {
    const c: *TeamsFetchCtx = @ptrCast(@alignCast(ctx));
    return .{ .teams = try server_app.provider.fetchTeams(c.adapter, arena, c.league) };
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
    zone: server_app.tz.Zone,
) !void {
    const stream = server_app.stream;
    const color = score_route.color orelse color_default;
    const day_owned = try arena.dupe(u8, day);
    const key = try stream.subKey(arena, league.slug, day_owned, color, score_route.width, score_route.height, score_route.art);

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

    const initial_text = try server_app.render.textWithZoneArt(arena, initial, color, score_route.width, score_route.height, zone, score_route.art);
    const initial_frame = try stream.frameWithMtime(arena, initial_text, adapter.clock(io));
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
                const body = server_app.render.textWithZoneArt(poll_arena, board, color, score_route.width, score_route.height, zone, score_route.art) catch continue;
                const event = stream.frameWithMtime(poll_arena, body, now_s) catch continue;
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

test "all?0 shares the home one-line shape with zone labels" {
    const arena = std.testing.allocator;
    const mlb = core.leagues.find("mlb").?;
    const sections = [_]server_app.digest.DigestSection{.{
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
                        .{ .id = "h", .name = "Home Club", .abbreviation = "HME", .score = "5", .winner = true, .home_away = "home" },
                    },
                },
            },
        },
    }};
    const lines = try allOneLine(arena, &sections, false, false, .et);
    defer arena.free(lines);
    // M/D ZONE label, never the raw board date; status plus the winner
    // check survive on a scored duel.
    try std.testing.expect(std.mem.indexOf(u8, lines, "mlb 9/6 ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "2026-09-06") == null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "Final AWY 2 @ HME 5 ✓") != null);

    const utc = try allOneLine(arena, &sections, false, false, .utc);
    defer arena.free(utc);
    try std.testing.expect(std.mem.indexOf(u8, utc, "mlb 9/6 UTC") != null);
}

test "all?0 resolves home and away checking both sides" {
    const arena = std.testing.allocator;
    const mlb = core.leagues.find("mlb").?;
    const sections = [_]server_app.digest.DigestSection{.{
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
    }};
    // Away marked first, home side unmarked: checking only the second side
    // flips the duel to `HME 5 @ AWY 2`.
    const lines = try allOneLine(arena, &sections, false, false, .et);
    defer arena.free(lines);
    try std.testing.expect(std.mem.indexOf(u8, lines, "AWY 2 @ HME 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "HME 5 @ AWY 2") == null);
}

test "all?0 counts every game it prints" {
    const arena = std.testing.allocator;
    const mlb = core.leagues.find("mlb").?;
    const sections = [_]server_app.digest.DigestSection{.{
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
                    .state = "pre",
                    .status = "Scheduled",
                    .participants = &.{
                        .{ .id = "s", .name = "Solo Club", .abbreviation = "SOLO", .score = "", .winner = false },
                    },
                },
            },
        },
    }};
    // A one-participant, nameless game fell into the old trailing
    // else-continue without setting the shown flag and printed a false
    // `No games scheduled.` for a non-empty digest.
    const lines = try allOneLine(arena, &sections, false, false, .et);
    defer arena.free(lines);
    try std.testing.expect(std.mem.indexOf(u8, lines, "SOLO") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "No games scheduled.") == null);
}

test "all?0 quiet is moot and color toggles ANSI" {
    const arena = std.testing.allocator;
    const mlb = core.leagues.find("mlb").?;
    const sections = [_]server_app.digest.DigestSection{.{
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
                    .state = "in",
                    .status = "Top 7th",
                    .participants = &.{
                        .{ .id = "a", .name = "Away Club", .abbreviation = "AWY", .score = "0", .winner = false, .home_away = "away" },
                        .{ .id = "h", .name = "Home Club", .abbreviation = "HME", .score = "3", .winner = false, .home_away = "home" },
                    },
                },
            },
        },
    }};
    // ?0 carries no header/footer (/?0 parity), so quiet selects nothing:
    // both modes render byte-identically.
    const loud = try allOneLine(arena, &sections, false, false, .et);
    defer arena.free(loud);
    const hushed = try allOneLine(arena, &sections, false, true, .et);
    defer arena.free(hushed);
    try std.testing.expectEqualStrings(loud, hushed);
    try std.testing.expect(std.mem.indexOf(u8, loud, "\x1b[") == null);
    const colored = try allOneLine(arena, &sections, true, false, .et);
    defer arena.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
}

test "all?0 empty digest and idle leagues" {
    const arena = std.testing.allocator;
    const mlb = core.leagues.find("mlb").?;
    const empty = try allOneLine(arena, &[_]server_app.digest.DigestSection{}, false, false, .et);
    defer arena.free(empty);
    try std.testing.expectEqualStrings("No games scheduled.\n", empty);
    // Unavailable leagues (null board) emit nothing but still land on the
    // empty line instead of a blank body.
    const idle = [_]server_app.digest.DigestSection{.{ .league = mlb }};
    const idle_lines = try allOneLine(arena, &idle, false, false, .et);
    defer arena.free(idle_lines);
    try std.testing.expectEqualStrings("No games scheduled.\n", idle_lines);
}
