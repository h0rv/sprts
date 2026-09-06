const std = @import("std");
const dates = @import("sprts_core").date;

pub const Format = enum { text, html, json };

pub const ScoreboardRoute = struct {
    league: []const u8,
    date: ?[]const u8,
    color: ?bool,
    width: ?u32,
    height: ?u32,
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
        .width = queryUint(queryValue(query, "width")),
        .height = queryUint(queryValue(query, "height")),
    } };
}

/// Response format for a request. The address decides first: `/api/v1/`
/// routes are always JSON. Otherwise an explicit `?format=text` or
/// `?format=html` wins, then the Accept header (browsers send text/html),
/// and plain text is the default. No User-Agent sniffing.
pub fn formatFor(target: []const u8, accept: []const u8) Format {
    if (isJsonTarget(target)) return .json;
    const query_at = std.mem.indexOfScalar(u8, target, '?');
    const query = if (query_at) |at| target[at + 1 ..] else "";
    if (queryValue(query, "format")) |explicit| {
        if (std.ascii.eqlIgnoreCase(explicit, "html")) return .html;
        if (std.ascii.eqlIgnoreCase(explicit, "text")) return .text;
    }
    if (containsIgnoreCase(accept, "application/json")) return .json;
    if (containsIgnoreCase(accept, "text/html")) return .html;
    return .text;
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

fn queryUint(value: ?[]const u8) ?u32 {
    const v = value orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }
    return false;
}

test "short routes parse and API targets are JSON" {
    const short = parse("/mlb");
    try std.testing.expect(short == .scoreboard);
    try std.testing.expect(!isJsonTarget("/mlb"));
    try std.testing.expect(!isJsonTarget("/mlb?date=2026-09-06"));
    try std.testing.expect(isJsonTarget("/api/v1/mlb?date=2026-09-06"));
    try std.testing.expect(isJsonTarget("/api/v1/leagues"));
    try std.testing.expect(!isJsonTarget("/"));
}

test "format comes from address, query, then Accept" {
    try std.testing.expectEqual(Format.text, formatFor("/mlb", "*/*"));
    try std.testing.expectEqual(Format.html, formatFor("/mlb", "text/html,application/xhtml+xml"));
    try std.testing.expectEqual(Format.text, formatFor("/mlb?format=text", "text/html"));
    try std.testing.expectEqual(Format.html, formatFor("/mlb?format=html", "*/*"));
    try std.testing.expectEqual(Format.json, formatFor("/mlb", "application/json"));
    try std.testing.expectEqual(Format.json, formatFor("/api/v1/mlb", "*/*"));
    try std.testing.expectEqual(Format.text, formatFor("/", "*/*"));
    try std.testing.expectEqual(Format.html, formatFor("/", "text/html"));
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
