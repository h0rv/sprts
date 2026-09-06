const std = @import("std");
const dates = @import("sprts_core").date;

pub const Format = enum { text, json };

pub const ScoreboardRoute = struct {
    league: []const u8,
    date: ?[]const u8,
    color: ?bool,
};

pub const Route = union(enum) {
    home: ?bool,
    leagues,
    scoreboard: ScoreboardRoute,
    openapi,
    health,
    not_found,
    bad_date,
};

pub fn parse(target: []const u8) Route {
    const query_at = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. query_at orelse target.len];
    const query = if (query_at) |at| target[at + 1 ..] else "";
    const color = parseColor(queryValue(query, "color"));

    if (std.mem.eql(u8, path, "/") or path.len == 0) return .{ .home = color };
    if (std.mem.eql(u8, path, "/healthz")) return .health;
    if (std.mem.eql(u8, path, "/openapi.json")) return .openapi;
    if (std.mem.eql(u8, path, "/api/v1/leagues")) return .leagues;

    const api_prefix = "/api/v1/";
    const slug = if (std.mem.startsWith(u8, path, api_prefix))
        path[api_prefix.len..]
    else if (path[0] == '/')
        path[1..]
    else
        return .not_found;
    if (slug.len == 0 or std.mem.indexOfScalar(u8, slug, '/') != null) return .not_found;

    const day = queryValue(query, "date");
    if (day) |value| if (!dates.validate(value)) return .bad_date;
    return .{ .scoreboard = .{
        .league = slug,
        .date = day,
        .color = color,
    } };
}

pub fn isJsonTarget(target: []const u8) bool {
    const query_at = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. query_at orelse target.len];
    return std.mem.startsWith(u8, path, "/api/v1/");
}

fn queryValue(query: []const u8, wanted: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..equals], wanted)) return field[equals + 1 ..];
    }
    return null;
}

fn parseColor(value: ?[]const u8) ?bool {
    const v = value orelse return null;
    if (v.len == 1 and v[0] == '0') return false;
    if (v.len == 1 and v[0] == '1') return true;
    return null;
}

test "short routes are text and API routes are JSON" {
    const short = parse("/mlb");
    try std.testing.expect(short == .scoreboard);
    try std.testing.expect(!isJsonTarget("/mlb"));
    try std.testing.expect(!isJsonTarget("/mlb?date=2026-09-06"));
    try std.testing.expect(isJsonTarget("/api/v1/mlb?date=2026-09-06"));
    try std.testing.expect(isJsonTarget("/api/v1/leagues"));
    try std.testing.expect(!isJsonTarget("/"));
}

test "headers change nothing" {
    // parse takes the target only. There is no Accept or User-Agent
    // sniffing, so a browser address and a curl address route identically.
    const route = parse("/mlb");
    try std.testing.expect(route == .scoreboard);
    try std.testing.expectEqualStrings("mlb", route.scoreboard.league);
}

test "color flag parsing is exact" {
    try std.testing.expect(parse("/mlb").scoreboard.color == null);
    try std.testing.expect(parse("/mlb?color=0").scoreboard.color.? == false);
    try std.testing.expect(parse("/mlb?color=1").scoreboard.color.? == true);
    try std.testing.expect(parse("/mlb?color=off").scoreboard.color == null);
    try std.testing.expect(parse("/?color=0").home.? == false);
}

test "bad dates and unknown shapes still route" {
    try std.testing.expect(parse("/mlb?date=tomorrow") == .bad_date);
    try std.testing.expect(parse("/mlb/extra") == .not_found);
    try std.testing.expect(parse("/api/v1/mlb?date=tomorrow") == .bad_date);
}
