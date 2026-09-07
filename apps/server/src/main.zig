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
        group.async(io, serveConnection, .{ allocator, io, stream, adapter, color_default });
    }
}

fn serveConnection(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, adapter: server_app.provider.EspnAdapter, color_default: bool) void {
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
        handleRequest(allocator, io, &request, adapter, color_default) catch |err| {
            std.log.err("request failed: {t}", .{err});
            return;
        };
    }
}

fn handleRequest(allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, adapter: server_app.provider.EspnAdapter, color_default: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (request.head.method != .GET and request.head.method != .HEAD) {
        return respond(request, "method not allowed\n", .text, .method_not_allowed, &.{.{ .name = "allow", .value = "GET, HEAD" }});
    }

    var accept: []const u8 = "";
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "accept")) accept = header.value;
    }

    const target = request.head.target;
    const format = server_app.router.formatFor(target, accept);

    switch (server_app.router.parse(target)) {
        .health => try respond(request, "ok\n", .text, .ok, &.{.{ .name = "cache-control", .value = "no-store" }}),
        .openapi => try respond(request, try server_app.spec.openApiJson(arena), .json, .ok, commonHeaders()),
        .home => |color| {
            const body = switch (format) {
                .text => try server_app.render.home(arena, color orelse color_default),
                .html => try server_app.render.homeHtml(arena),
                .json => try server_app.render.leaguesJson(arena),
            };
            try respond(request, body, format, .ok, commonHeaders());
        },
        .leagues => try respond(request, try server_app.render.leaguesJson(arena), .json, .ok, commonHeaders()),
        .bad_date => try respondError(arena, request, "date must be YYYY-MM-DD", format, .bad_request),
        .not_found => try respondError(arena, request, "route not found", format, .not_found),
        .scoreboard => |score_route| {
            const league = core.leagues.find(score_route.league) orelse {
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const day = score_route.date orelse try core.date.today(arena, io);
            const board = adapter.fetch(arena, league, day) catch |err| {
                std.log.warn("ESPN request failed for {s}: {t}", .{ league.slug, err });
                try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                return;
            };
            const body = switch (format) {
                .text => try server_app.render.text(arena, board, score_route.color orelse color_default, score_route.width, score_route.height),
                .html => try server_app.render.scoreHtml(arena, board, score_route.width, score_route.height),
                .json => try server_app.render.json(arena, board),
            };
            try respond(request, body, format, .ok, commonHeaders());
        },
        .game => |game_route| {
            const league = core.leagues.find(game_route.league) orelse {
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const game_detail = adapter.fetchDetail(arena, league, game_route.id) catch |err| switch (err) {
                error.GameNotFound => {
                    try respondError(arena, request, "game not found", format, .not_found);
                    return;
                },
                else => {
                    std.log.warn("ESPN detail request failed for {s} {s}: {t}", .{ league.slug, game_route.id, err });
                    try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                    return;
                },
            };
            const body = switch (format) {
                .text => try server_app.detail_view.renderText(arena, game_detail, game_route.color orelse color_default, game_route.width, game_route.height),
                .html => try server_app.detail_view.detailHtml(arena, game_detail, game_route.width, game_route.height),
                .json => try server_app.detail_view.json(arena, game_detail),
            };
            try respond(request, body, format, .ok, commonHeaders());
        },
        .team => |team_route| {
            const league = core.leagues.find(team_route.league) orelse {
                try respondError(arena, request, "unknown league; see /api/v1/leagues", format, .not_found);
                return;
            };
            const view = server_app.provider.fetchTeam(adapter, arena, league, team_route.abbr) catch |err| switch (err) {
                error.TeamNotFound => {
                    try respondError(arena, request, "unknown team; see /api/v1/leagues", format, .not_found);
                    return;
                },
                else => {
                    std.log.warn("ESPN team request failed for {s}/{s}: {t}", .{ league.slug, team_route.abbr, err });
                    try respondError(arena, request, "scores are temporarily unavailable", format, .bad_gateway);
                    return;
                },
            };
            const body = switch (format) {
                .text => try server_app.team_view.renderText(arena, view, team_route.color orelse color_default, team_route.width, team_route.height),
                .html => try server_app.team_view.teamHtml(arena, view, league.slug, team_route.width, team_route.height),
                .json => try server_app.team_view.renderJson(arena, view),
            };
            try respond(request, body, format, .ok, commonHeaders());
        },
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
