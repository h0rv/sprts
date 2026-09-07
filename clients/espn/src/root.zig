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
pub const StdTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn fetch(
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

test "buildScheduleUrl mirrors the team schedule path" {
    const url = try buildScheduleUrl(
        std.testing.allocator,
        "https://site.api.espn.com/apis/site/v2",
        "baseball",
        "mlb",
        "22",
        "2026",
    );
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/teams/22/schedule?season=2026",
        url,
    );
}
