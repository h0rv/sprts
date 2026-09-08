/// The complete generated Site API surface. It is namespaced so future ESPN
/// API families can be added without breaking imports.
pub const site = @import("generated.zig");
const std = @import("std");

pub const Client = site.Client;
pub const getScoreboard = site.getScoreboard;
pub const getScoreboardResult = site.getScoreboardResult;
pub const GenericScoreboardResponse = site.GenericScoreboardResponse;

pub const user_agent = "curl/8.17.0 sprts-espn-client/0.1";
pub const accept_json_value = "application/json";
// NOTE: every transport must send `user_agent` — ESPN rejects the default
// agents. `StdTransport` overrides it below; the worker path sends the same
// value via `edge_cache.upstreamHeaders` (see worker.zig).
pub const default_headers: []const std.http.Header = &.{.{ .name = "accept", .value = accept_json_value }};

/// Pure URL builder mirroring the scoreboard path used by `getScoreboardRaw`.
/// Returns an owned slice allocated with `allocator`.
pub fn buildScoreboardUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    sport: []const u8,
    league: []const u8,
    dates: ?[]const u8,
    week: ?i64,
    season_type: ?i64,
    groups: ?[]const u8,
) ![]u8 {
    var url: std.Io.Writer.Allocating = .init(allocator);
    defer url.deinit();
    try url.writer.print("{s}/sports/{s}/{s}/scoreboard", .{ base_url, sport, league });
    var first = true;
    try query(&url.writer, &first, "dates", dates);
    try queryInt(&url.writer, &first, "week", week);
    try queryInt(&url.writer, &first, "seasontype", season_type);
    try query(&url.writer, &first, "groups", groups);
    return url.toOwnedSlice();
}

/// Pure URL builder for the per-event summary endpoint, mirroring
/// `buildScoreboardUrl`. Returns an owned slice allocated with `allocator`.
pub fn buildSummaryUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    sport: []const u8,
    league: []const u8,
    event_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sports/{s}/{s}/summary?event={s}", .{ base_url, sport, league, event_id });
}

/// Pure URL builder for the teams list used to resolve an abbreviation to
/// an ESPN team id: `{base}/sports/{sport}/{league}/teams`.
pub fn buildTeamsUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    sport: []const u8,
    league: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sports/{s}/{s}/teams", .{ base_url, sport, league });
}

/// Portable fetch result. `body` is owned by the caller-provided arena.
pub const FetchResult = struct {
    status: std.http.Status,
    body: []u8,
};

/// Portable transport seam. A future WorkerTransport can implement the same
/// interface without touching callers; `body` is allocated in `arena`.
pub const HttpTransport = struct {
    ptr: *anyopaque,
    fetchFn: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) anyerror!FetchResult,

    pub fn fetch(
        self: HttpTransport,
        arena: std.mem.Allocator,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !FetchResult {
        return self.fetchFn(self.ptr, arena, url, extra_headers);
    }
};

/// Non-wasm transport backed by the existing `std.http.Client` path.
/// Keeps the curl UA workaround plus `accept: application/json`.
///
/// `timeout_ms` bounds every fetch: the request runs on a concurrent Io
/// task while the caller waits on an event with the deadline. A hung ESPN
/// fails with `error.Timeout` (callers map that into stale/502) instead of
/// hanging the connection. Zero disables the watchdog (direct fetch); when
/// the Io backend offers no concurrency (single-threaded tests) the fetch
/// also runs direct.
pub const StdTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    timeout_ms: u64 = 5000,

    pub fn fetch(
        self: StdTransport,
        arena: std.mem.Allocator,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !FetchResult {
        if (self.timeout_ms == 0) return fetchDirect(self, arena, url, extra_headers);
        var done: std.Io.Event = .unset;
        var future = self.io.concurrent(fetchTask, .{ self, arena, url, extra_headers, &done }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return fetchDirect(self, arena, url, extra_headers),
        };
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(@as(i64, @intCast(@min(self.timeout_ms, std.math.maxInt(i64))))),
            .clock = .awake,
        } };
        done.waitTimeout(self.io, timeout) catch |err| switch (err) {
            error.Canceled => {
                _ = future.cancel(self.io) catch null;
                return error.Canceled;
            },
            error.Timeout => {
                // Still running past the deadline: ask the worker to stop
                // (this interrupts its pending socket op) and fail fast. A
                // worker that finished in the race window serves its result.
                if (future.cancel(self.io)) |ok| return ok else |_| return error.Timeout;
            },
        };
        return future.await(self.io);
    }

    fn fetchTask(
        task_self: StdTransport,
        task_arena: std.mem.Allocator,
        task_url: []const u8,
        task_headers: []const std.http.Header,
        task_done: *std.Io.Event,
    ) anyerror!FetchResult {
        defer task_done.set(task_self.io);
        return fetchDirect(task_self, task_arena, task_url, task_headers);
    }

    fn fetchDirect(
        self: StdTransport,
        arena: std.mem.Allocator,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !FetchResult {
        var http: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer http.deinit();
        var response_body: std.Io.Writer.Allocating = .init(arena);
        defer response_body.deinit();
        const response = try http.fetch(.{
            .location = .{ .url = url },
            // ESPN currently allows curl clients and rejects unknown agents. Keep
            // the package identity in the suffix so operators can identify it.
            .headers = .{ .user_agent = .{ .override = user_agent } },
            .extra_headers = extra_headers,
            .response_writer = &response_body.writer,
        });
        return .{
            .status = response.status,
            .body = try response_body.toOwnedSlice(),
        };
    }

    fn dispatch(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) anyerror!FetchResult {
        const self: *StdTransport = @ptrCast(@alignCast(ptr));
        return self.fetch(arena, url, extra_headers);
    }

    pub fn asTransport(self: *StdTransport) HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

/// ESPN rejects the std.http default user agent. openapi2zig 0.5.6 models
/// custom headers as extra headers, which cannot replace Zig's standard user
/// agent header. Keep the workaround in this client package so applications do
/// not need a second HTTP implementation.
pub fn getScoreboardRaw(client: *Client, sport: []const u8, league: []const u8, dates: ?[]const u8, week: ?i64, season_type: ?i64, groups: ?[]const u8) !site.RawResponse {
    const url = try buildScoreboardUrl(client.allocator, client.base_url, sport, league, dates, week, season_type, groups);
    defer client.allocator.free(url);

    var response_body: std.Io.Writer.Allocating = .init(client.allocator);
    defer response_body.deinit();
    const response = try client.http.fetch(.{
        .location = .{ .url = url },
        // ESPN currently allows curl clients and rejects unknown agents. Keep
        // the package identity in the suffix so operators can identify it.
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = default_headers,
        .response_writer = &response_body.writer,
    });
    return .{
        .allocator = client.allocator,
        .status = response.status,
        .body = try response_body.toOwnedSlice(),
    };
}

fn query(writer: *std.Io.Writer, first: *bool, name: []const u8, value: ?[]const u8) !void {
    const actual = value orelse return;
    try separator(writer, first);
    try writer.print("{s}={s}", .{ name, actual });
}

fn queryInt(writer: *std.Io.Writer, first: *bool, name: []const u8, value: ?i64) !void {
    const actual = value orelse return;
    try separator(writer, first);
    try writer.print("{s}={d}", .{ name, actual });
}

fn separator(writer: *std.Io.Writer, first: *bool) !void {
    try writer.writeByte(if (first.*) '?' else '&');
    first.* = false;
}

test {
    _ = site;
}

test "buildSummaryUrl mirrors the summary path" {
    const url = try buildSummaryUrl(
        std.testing.allocator,
        "https://site.api.espn.com/apis/site/v2",
        "baseball",
        "mlb",
        "401816828",
    );
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/summary?event=401816828",
        url,
    );
}

test "buildScoreboardUrl mirrors scoreboard path and query order" {
    const url = try buildScoreboardUrl(
        std.testing.allocator,
        "https://site.api.espn.com/apis/site/v2",
        "baseball",
        "mlb",
        "20260906",
        null,
        null,
        null,
    );
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard?dates=20260906",
        url,
    );

    const bare = try buildScoreboardUrl(
        std.testing.allocator,
        "https://example.test",
        "football",
        "nfl",
        null,
        null,
        null,
        null,
    );
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("https://example.test/sports/football/nfl/scoreboard", bare);
}

/// Pure URL builder for a team's season schedule, used for series
/// derivation. Returns an owned slice allocated with `allocator`.
pub fn buildScheduleUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    sport: []const u8,
    league: []const u8,
    team_id: []const u8,
    season: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sports/{s}/{s}/teams/{s}/schedule?season={s}", .{ base_url, sport, league, team_id, season });
}

test "team URL builders mirror the teams and schedule paths" {
    const teams = try buildTeamsUrl(
        std.testing.allocator,
        "https://site.api.espn.com/apis/site/v2",
        "baseball",
        "mlb",
    );
    defer std.testing.allocator.free(teams);
    try std.testing.expectEqualStrings(
        "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/teams",
        teams,
    );

    const schedule = try buildScheduleUrl(
        std.testing.allocator,
        "https://site.api.espn.com/apis/site/v2",
        "baseball",
        "mlb",
        "22",
        "2026",
    );
    defer std.testing.allocator.free(schedule);
    try std.testing.expectEqualStrings(
        "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/teams/22/schedule?season=2026",
        schedule,
    );
}

const builtin_timeout_test = @import("builtin");

/// Test upstream: accepts one connection, stalls, then answers `{}`.
/// Runs as an Io task (proper task context for the stall sleep). Errors are
/// swallowed: a client that timed out is gone by answer time.
fn stallThenAnswer(listener_ptr: *std.Io.net.Server, io: std.Io, delay_ms: i64) !void {
    var stream = listener_ptr.accept(io) catch return;
    defer stream.close(io);
    const delay: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(delay_ms), .clock = .awake };
    delay.sleep(io) catch return;
    var buf: [256]u8 = undefined;
    var writer = stream.writer(io, &buf);
    writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}") catch return;
    writer.interface.flush() catch return;
}

fn timeoutTestUrl(arena: std.mem.Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/sports/baseball/mlb/scoreboard?dates=20260906", .{port});
}

test "StdTransport fails fast with error.Timeout on a hung upstream" {
    if (builtin_timeout_test.single_threaded) return;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var server = try io.concurrent(stallThenAnswer, .{ &listener, io, 2000 });
    defer server.await(io) catch {};
    var transport = StdTransport{ .allocator = std.testing.allocator, .io = io, .timeout_ms = 100 };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = try timeoutTestUrl(arena, listener.socket.address.getPort());
    try std.testing.expectError(error.Timeout, transport.fetch(arena, url, &.{}));
}

test "StdTransport serves a fast upstream inside the deadline" {
    if (builtin_timeout_test.single_threaded) return;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var server = try io.concurrent(stallThenAnswer, .{ &listener, io, 0 });
    defer server.await(io) catch {};
    var transport = StdTransport{ .allocator = std.testing.allocator, .io = io, .timeout_ms = 5000 };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = try timeoutTestUrl(arena, listener.socket.address.getPort());
    const result = try transport.fetch(arena, url, &.{});
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expectEqualStrings("{}", result.body);
}
