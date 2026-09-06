const std = @import("std");
const dates = @import("sprts_core").date;

pub const Format = enum { text, html, json };

pub const ScoreboardRoute = struct {
    league: []const u8,
    date: ?[]const u8,
    color: ?bool,
    width: ?u16,
    height: ?u16,
};

pub const GameRoute = struct {
    league: []const u8,
    id: []const u8,
    color: ?bool,
    width: ?u16,
    height: ?u16,
};

pub const TeamRoute = struct {
    league: []const u8,
    abbr: []const u8,
    color: ?bool,
    width: ?u16,
    height: ?u16,
};

pub const Route = union(enum) {
    home: ?bool,
    leagues,
    scoreboard: ScoreboardRoute,
    game: GameRoute,
    team: TeamRoute,
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
    if (slug.len == 0) return .not_found;
    // Two-segment addresses: /{league}/{id} (all digits) is a game view,
    // /{league}/{abbr} is a team view. Deeper paths are not routes.
    if (std.mem.indexOfScalar(u8, slug, '/')) |slash| {
        const league = slug[0..slash];
        const segment = slug[slash + 1 ..];
        if (league.len == 0 or segment.len == 0 or
            std.mem.indexOfScalar(u8, segment, '/') != null) return .not_found;
        const display = .{
            .color = color,
            .width = queryUint(queryValue(query, "width")),
            .height = queryUint(queryValue(query, "height")),
        };
        if (isAllDigits(segment)) return .{ .game = .{
            .league = league,
            .id = segment,
            .color = display.color,
            .width = display.width,
            .height = display.height,
        } };
        return .{ .team = .{
            .league = league,
            .abbr = segment,
            .color = display.color,
            .width = display.width,
            .height = display.height,
        } };
    }

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

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
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

/// Strict positive integer for display params: all digits, fits u16,
/// nonzero. Anything else is ignored (falls back to the default).
fn queryUint(value: ?[]const u8) ?u16 {
    const v = value orelse return null;
    if (v.len == 0 or v.len > 5) return null;
    var n: u32 = 0;
    for (v) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    if (n == 0 or n > 65535) return null;
    return @intCast(n);
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

test "display params parse strict" {
    try std.testing.expect(parse("/mlb").scoreboard.width == null);
    try std.testing.expect(parse("/mlb").scoreboard.height == null);
    try std.testing.expect(parse("/mlb?width=80").scoreboard.width.? == 80);
    try std.testing.expect(parse("/mlb?height=10").scoreboard.height.? == 10);
    try std.testing.expect(parse("/mlb?width=abc").scoreboard.width == null);
    try std.testing.expect(parse("/mlb?width=0").scoreboard.width == null);
    try std.testing.expect(parse("/mlb?width=999999").scoreboard.width == null);
    try std.testing.expect(parse("/mlb?width=80x").scoreboard.width == null);
}

test "bad dates and unknown shapes still route" {
    try std.testing.expect(parse("/mlb?date=tomorrow") == .bad_date);
    try std.testing.expect(parse("/mlb/a/b") == .not_found);
    try std.testing.expect(parse("/api/v1/mlb?date=tomorrow") == .bad_date);
}

test "second segment splits game ids from team abbrevs" {
    const game = parse("/mlb/401816828").game;
    try std.testing.expectEqualStrings("mlb", game.league);
    try std.testing.expectEqualStrings("401816828", game.id);
    const api_game = parse("/api/v1/mlb/401816828").game;
    try std.testing.expectEqualStrings("401816828", api_game.id);
    const team = parse("/mlb/phi").team;
    try std.testing.expectEqualStrings("mlb", team.league);
    try std.testing.expectEqualStrings("phi", team.abbr);
    const api_team = parse("/api/v1/nfl/kc?width=90").team;
    try std.testing.expectEqualStrings("kc", api_team.abbr);
    try std.testing.expect(api_team.width.? == 90);
    try std.testing.expect(parse("/mlb/") == .not_found);
    try std.testing.expect(parse("//phi") == .not_found);
}
