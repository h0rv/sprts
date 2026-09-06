/// The complete generated Site API surface. It is namespaced so future ESPN
/// API families can be added without breaking imports.
pub const site = @import("generated.zig");
const std = @import("std");

pub const Client = site.Client;
pub const getScoreboard = site.getScoreboard;
pub const getScoreboardResult = site.getScoreboardResult;
pub const GenericScoreboardResponse = site.GenericScoreboardResponse;

/// ESPN rejects the std.http default user agent. openapi2zig 0.5.6 models
/// custom headers as extra headers, which cannot replace Zig's standard user
/// agent header. Keep the workaround in this client package so applications do
/// not need a second HTTP implementation.
pub fn getScoreboardRaw(client: *Client, sport: []const u8, league: []const u8, dates: ?[]const u8, week: ?i64, season_type: ?i64, groups: ?[]const u8) !site.RawResponse {
    var url: std.Io.Writer.Allocating = .init(client.allocator);
    defer url.deinit();
    try url.writer.print("{s}/sports/{s}/{s}/scoreboard", .{ client.base_url, sport, league });
    var first = true;
    try query(&url.writer, &first, "dates", dates);
    try queryInt(&url.writer, &first, "week", week);
    try queryInt(&url.writer, &first, "seasontype", season_type);
    try query(&url.writer, &first, "groups", groups);

    var response_body: std.Io.Writer.Allocating = .init(client.allocator);
    defer response_body.deinit();
    const response = try client.http.fetch(.{
        .location = .{ .url = url.written() },
        // ESPN currently allows curl clients and rejects unknown agents. Keep
        // the package identity in the suffix so operators can identify it.
        .headers = .{ .user_agent = .{ .override = "curl/8.17.0 sprts-espn-client/0.1" } },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
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
