const std = @import("std");
const dates = @import("sprts_core").date;

pub const Format = enum { text, html, json };

pub const ScoreboardRoute = struct {
    league: []const u8,
    date: ?[]const u8,
    format: Format,
};

pub const Route = union(enum) {
    home: Format,
    leagues,
    scoreboard: ScoreboardRoute,
    health,
    not_found,
    bad_date,
};

pub fn parse(target: []const u8, accept: []const u8, user_agent: []const u8) Route {
    const query_at = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. query_at orelse target.len];
    const query = if (query_at) |at| target[at + 1 ..] else "";
    const requested_format = queryValue(query, "format");
    const format = chooseFormat(accept, user_agent, requested_format);

    if (std.mem.eql(u8, path, "/") or path.len == 0) return .{ .home = format };
    if (std.mem.eql(u8, path, "/healthz")) return .health;
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
        .format = if (std.mem.startsWith(u8, path, api_prefix)) .json else format,
    } };
}

fn queryValue(query: []const u8, wanted: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..equals], wanted)) return field[equals + 1 ..];
    }
    return null;
}

fn chooseFormat(accept: []const u8, user_agent: []const u8, explicit: ?[]const u8) Format {
    if (explicit) |value| {
        if (std.ascii.eqlIgnoreCase(value, "json")) return .json;
        if (std.ascii.eqlIgnoreCase(value, "html")) return .html;
        if (std.ascii.eqlIgnoreCase(value, "text")) return .text;
    }
    if (containsIgnoreCase(accept, "application/json")) return .json;
    if (containsIgnoreCase(accept, "text/plain")) return .text;
    if (startsWithIgnoreCase(user_agent, "curl/") or startsWithIgnoreCase(user_agent, "wget/") or startsWithIgnoreCase(user_agent, "httpie/")) return .text;
    return .html;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }
    return false;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

test "curl gets text while browsers get HTML and API is JSON" {
    try std.testing.expectEqual(Format.text, parse("/mlb", "*/*", "curl/8.0").scoreboard.format);
    try std.testing.expectEqual(Format.html, parse("/mlb", "text/html", "Mozilla/5.0").scoreboard.format);
    try std.testing.expectEqual(Format.json, parse("/api/v1/mlb?date=2026-09-06", "*/*", "curl/8.0").scoreboard.format);
    try std.testing.expect(parse("/mlb?date=tomorrow", "", "") == .bad_date);
}
