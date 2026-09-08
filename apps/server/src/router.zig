const std = @import("std");
const dates = @import("sprts_core").date;

pub const Format = enum { text, html, json };

pub const ScoreboardRoute = struct {
    league: []const u8,
    date: ?[]const u8,
    /// ESPN week selector (football leases it; most sports ignore it).
    /// Strict positive int like width/height; null = date-driven board.
    week: ?u16 = null,
    color: ?bool,
    width: ?u16,
    height: ?u16,
    quiet: bool = false,
    oneline: bool = false,
    stream: bool = false,
};

pub const GameRoute = struct {
    league: []const u8,
    id: []const u8,
    color: ?bool,
    width: ?u16,
    height: ?u16,
    quiet: bool = false,
    oneline: bool = false,
};

pub const TeamRoute = struct {
    league: []const u8,
    abbr: []const u8,
    color: ?bool,
    width: ?u16,
    height: ?u16,
    quiet: bool = false,
    oneline: bool = false,
};

/// Standings tab (`/{league}/standings`, plaintextsports parity with the
/// Schedule/Standings/Teams tabs). No date or week: the endpoint is the
/// current table only. Display flags ride along like every human route.
pub const StandingsRoute = struct {
    league: []const u8,
    color: ?bool,
    width: ?u16,
    height: ?u16,
    quiet: bool = false,
    oneline: bool = false,
};

pub const HomeRoute = struct {
    color: ?bool,
    quiet: bool = false,
    oneline: bool = false,
};

/// Help page route (`/:help`, wttr.in style). No league, date, or size to
/// carry: the page is static copy plus display flags.
pub const HelpRoute = struct {
    color: ?bool,
    quiet: bool = false,
    oneline: bool = false,
};

pub const AllRoute = struct {
    date: ?[]const u8,
    color: ?bool,
    width: ?u16,
    height: ?u16,
    quiet: bool = false,
    oneline: bool = false,
};

pub const Route = union(enum) {
    home: HomeRoute,
    leagues,
    all: AllRoute,
    scoreboard: ScoreboardRoute,
    game: GameRoute,
    team: TeamRoute,
    standings: StandingsRoute,
    help: HelpRoute,
    openapi,
    docs,
    health,
    not_found,
    bad_date,
};

pub fn parse(target: []const u8) Route {
    const query_at = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. query_at orelse target.len];
    const query = if (query_at) |at| target[at + 1 ..] else "";
    const display = parseDisplay(query);

    if (std.mem.eql(u8, path, "/") or path.len == 0) return .{ .home = .{
        .color = display.color,
        .quiet = display.quiet,
        .oneline = display.oneline,
    } };
    if (std.mem.eql(u8, path, "/healthz")) return .health;
    if (std.mem.eql(u8, path, "/openapi.json")) return .openapi;
    if (std.mem.eql(u8, path, "/docs")) return .docs;
    if (std.mem.eql(u8, path, "/api/v1/leagues")) return .leagues;

    // Help page (wttr.in `:help` style): global `/:help`, `/help` plus the
    // `/api/v1/` twins. Per-league `/{league}/:help` and `/{league}/help`
    // (and the `/api/v1/{league}/` twins) are caught in the two-segment
    // branch below before the game/team split, so a help segment never
    // falls into the team view. Display flags ride along via the same
    // `display` parsed once at the top (aliases + precedence documented
    // on `parseDisplay`).
    if (isHelpPath(path)) return .{ .help = .{
        .color = display.color,
        .quiet = display.quiet,
        .oneline = display.oneline,
    } };

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
        if (isHelpSegment(segment)) return .{ .help = .{
            .color = display.color,
            .quiet = display.quiet,
            .oneline = display.oneline,
        } };
        // Standings tab: caught before the game/team split so the literal
        // never falls into the team view (no team is abbreviated
        // "standings", and game ids are digits-only, so the match is exact).
        if (isStandingsSegment(segment)) return .{ .standings = .{
            .league = league,
            .color = display.color,
            .width = queryUint(queryValue(query, "width")),
            .height = queryUint(queryValue(query, "height")),
            .quiet = display.quiet,
            .oneline = display.oneline,
        } };
        const sized = .{
            .color = display.color,
            .width = queryUint(queryValue(query, "width")),
            .height = queryUint(queryValue(query, "height")),
            .quiet = display.quiet,
            .oneline = display.oneline,
        };
        if (isAllDigits(segment)) return .{ .game = .{
            .league = league,
            .id = segment,
            .color = sized.color,
            .width = sized.width,
            .height = sized.height,
            .quiet = sized.quiet,
            .oneline = sized.oneline,
        } };
        return .{ .team = .{
            .league = league,
            .abbr = segment,
            .color = sized.color,
            .width = sized.width,
            .height = sized.height,
            .quiet = sized.quiet,
            .oneline = sized.oneline,
        } };
    }

    const day = queryValue(query, "date");
    if (day) |value| if (!dates.validate(value)) return .bad_date;
    if (std.mem.eql(u8, slug, "all")) return .{ .all = .{
        .date = day,
        .color = display.color,
        .width = queryUint(queryValue(query, "width")),
        .height = queryUint(queryValue(query, "height")),
        .quiet = display.quiet,
        .oneline = display.oneline,
    } };
    return .{ .scoreboard = .{
        .league = slug,
        .date = day,
        .week = queryUint(queryValue(query, "week")),
        .color = display.color,
        .width = queryUint(queryValue(query, "width")),
        .height = queryUint(queryValue(query, "height")),
        .quiet = display.quiet,
        .oneline = display.oneline,
        .stream = wantsStream(target, ""),
    } };
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Global help addresses: `/:help`, `/help`, and the `/api/v1/` twins.
/// A bare `help` team abbrev (`/mlb/help`) is NOT matched here — it arrives
/// as slug `mlb/help` and is caught by `isHelpSegment` in the two-segment
/// branch, so help never falls into the team view.
fn isHelpPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/:help") or
        std.mem.eql(u8, path, "/help") or
        std.mem.eql(u8, path, "/api/v1/:help") or
        std.mem.eql(u8, path, "/api/v1/help");
}

/// Second segment of `/{league}/standings` (and the `/api/v1/` twin).
fn isStandingsSegment(segment: []const u8) bool {
    return std.ascii.eqlIgnoreCase(segment, "standings");
}

/// Second segment of `/{league}/:help` or `/{league}/help`.
fn isHelpSegment(segment: []const u8) bool {
    return std.mem.eql(u8, segment, ":help") or std.mem.eql(u8, segment, "help");
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

/// True when the scoreboard request asks for a live SSE stream: either the
/// `?stream=` query flag (`sse`, `1`, or `true`, case-insensitive) or an
/// `Accept: text/event-stream` header. `parse` fills `ScoreboardRoute.stream`
/// from the query half; callers OR in the header half with this helper.
pub fn wantsStream(target: []const u8, accept: []const u8) bool {
    const query_at = std.mem.indexOfScalar(u8, target, '?');
    const query = if (query_at) |at| target[at + 1 ..] else "";
    if (queryValue(query, "stream")) |value| {
        if (std.ascii.eqlIgnoreCase(value, "sse")) return true;
        if (std.ascii.eqlIgnoreCase(value, "1")) return true;
        if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    }
    return containsIgnoreCase(accept, "text/event-stream");
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

fn parseFlagBool(value: ?[]const u8) ?bool {
    const v = value orelse return null;
    if (v.len == 1 and v[0] == '0') return false;
    if (v.len == 1 and v[0] == '1') return true;
    return null;
}

const DisplayFlags = struct {
    color: ?bool,
    quiet: bool,
    oneline: bool,
};

/// Single-letter display aliases, wttr.in style. `?T` is `?color=0`,
/// `?A` is `?color=1`, `?q` is quiet (no header/footer), `?0` is one-line.
/// Both combined (`?0q`, `?0pq` with unknown letters ignored) and
/// `&`-separated (`?0&q`) spellings work on every human route,
/// including the `:help` page.
/// Precedence: long flags win over aliases regardless of order
/// (`?color=1&T` and `?T&color=1` are both color on; `?q&quiet=0` and
/// `?quiet=0&q` are both quiet off); an invalid long flag is ignored so
/// the alias still applies (`?color=off&T` is color off). Among aliases
/// alone the later letter wins (`?T&A` is color on, `?A&T` off).
fn parseDisplay(query: []const u8) DisplayFlags {
    const long_color = parseColor(queryValue(query, "color"));
    const long_quiet = parseFlagBool(queryValue(query, "quiet"));
    const long_oneline = parseFlagBool(queryValue(query, "oneline")) orelse
        parseFlagBool(queryValue(query, "one-line"));
    var alias_color: ?bool = null;
    var alias_quiet = false;
    var alias_oneline = false;
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, field, '=');
        const name = if (equals) |e| field[0..e] else field;
        const value: ?[]const u8 = if (equals) |e| field[e + 1 ..] else null;
        if (equals == null) {
            if (std.mem.eql(u8, name, "quiet")) {
                alias_quiet = true;
                continue;
            }
            if (std.mem.eql(u8, name, "oneline") or std.mem.eql(u8, name, "one-line")) {
                alias_oneline = true;
                continue;
            }
            for (name) |c| switch (c) {
                'T' => alias_color = false,
                'A' => alias_color = true,
                'q' => alias_quiet = true,
                '0' => alias_oneline = true,
                else => {},
            };
        } else if (name.len == 1) {
            switch (name[0]) {
                'T' => alias_color = false,
                'A' => alias_color = true,
                'q' => {
                    if (value) |v| {
                        if (v.len == 1 and v[0] == '0') alias_quiet = false else alias_quiet = true;
                    } else alias_quiet = true;
                },
                '0' => {
                    if (value) |v| {
                        if (v.len == 1 and v[0] == '0') alias_oneline = false else alias_oneline = true;
                    } else alias_oneline = true;
                },
                else => {},
            }
        }
    }
    return .{
        .color = if (long_color) |c| c else alias_color,
        .quiet = if (long_quiet) |q| q else alias_quiet,
        .oneline = if (long_oneline) |o| o else alias_oneline,
    };
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
    try std.testing.expect(parse("/docs") == .docs);
    try std.testing.expect(!isJsonTarget("/docs"));
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
    try std.testing.expect(parse("/?color=0").home.color.? == false);
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

test "week param parses strict like width and height" {
    try std.testing.expect(parse("/mlb").scoreboard.week == null);
    try std.testing.expect(parse("/nfl?week=1").scoreboard.week.? == 1);
    try std.testing.expect(parse("/nfl?week=18").scoreboard.week.? == 18);
    try std.testing.expect(parse("/mlb?week=abc").scoreboard.week == null);
    try std.testing.expect(parse("/mlb?week=0").scoreboard.week == null);
    try std.testing.expect(parse("/mlb?week=999999").scoreboard.week == null);
    try std.testing.expect(parse("/mlb?week=2x").scoreboard.week == null);
    try std.testing.expect(parse("/mlb?week=").scoreboard.week == null);
    // Composes with date and display params.
    const composed = parse("/nfl?date=2026-09-06&week=2&width=80").scoreboard;
    try std.testing.expect(composed.week.? == 2);
    try std.testing.expect(composed.width.? == 80);
    try std.testing.expectEqualStrings("2026-09-06", composed.date.?);
}

test "all route parses date and display flags, never a league" {
    const all = parse("/all").all;
    try std.testing.expect(all.date == null);
    try std.testing.expect(all.color == null);
    const dated = parse("/all?date=2026-09-06").all;
    try std.testing.expectEqualStrings("2026-09-06", dated.date.?);
    const api = parse("/api/v1/all?date=2026-09-06").all;
    try std.testing.expectEqualStrings("2026-09-06", api.date.?);
    try std.testing.expect(isJsonTarget("/api/v1/all?date=2026-09-06"));
    try std.testing.expect(!isJsonTarget("/all?date=2026-09-06"));
    const sized = parse("/all?width=80&height=3").all;
    try std.testing.expect(sized.width.? == 80);
    try std.testing.expect(sized.height.? == 3);
    try std.testing.expect(parse("/all?date=tomorrow") == .bad_date);
    try std.testing.expect(parse("/api/v1/all?date=tomorrow") == .bad_date);
    // A league literally named "all" is unreachable; the digest owns /all.
    try std.testing.expect(parse("/all") != .scoreboard);
}

test "bad dates and unknown shapes still route" {
    try std.testing.expect(parse("/mlb?date=tomorrow") == .bad_date);
    try std.testing.expect(parse("/mlb/a/b") == .not_found);
    try std.testing.expect(parse("/api/v1/mlb?date=tomorrow") == .bad_date);
}

test "single-letter aliases combine and separate" {
    // Combined wttr.in style.
    const combined = parse("/mlb?0q").scoreboard;
    try std.testing.expect(combined.oneline);
    try std.testing.expect(combined.quiet);
    try std.testing.expect(combined.color == null);
    // Unknown letters are ignored, so ?0pq behaves like ?0q.
    const wttr = parse("/mlb?0pq").scoreboard;
    try std.testing.expect(wttr.oneline);
    try std.testing.expect(wttr.quiet);
    // &-separated spells the same flags.
    const separate = parse("/mlb?0&q").scoreboard;
    try std.testing.expect(separate.oneline);
    try std.testing.expect(separate.quiet);
    // Mixed combined + separate + long width composes.
    const mixed = parse("/mlb?0&q&width=80").scoreboard;
    try std.testing.expect(mixed.oneline);
    try std.testing.expect(mixed.quiet);
    try std.testing.expect(mixed.width.? == 80);
    // Aliases ride on every route shape.
    try std.testing.expect(parse("/?0q").home.oneline);
    try std.testing.expect(parse("/?0q").home.quiet);
    try std.testing.expect(parse("/mlb/401816828?0").game.oneline);
    try std.testing.expect(parse("/mlb/phi?q").team.quiet);
}

test "long flags win over aliases, later alias wins" {
    try std.testing.expect(parse("/mlb?T").scoreboard.color.? == false);
    try std.testing.expect(parse("/mlb?A").scoreboard.color.? == true);
    // Long ?color wins over either alias, whichever order they appear in.
    try std.testing.expect(parse("/mlb?color=1&T").scoreboard.color.? == true);
    try std.testing.expect(parse("/mlb?T&color=1").scoreboard.color.? == true);
    try std.testing.expect(parse("/mlb?color=0&A").scoreboard.color.? == false);
    try std.testing.expect(parse("/mlb?A&color=0").scoreboard.color.? == false);
    // Invalid long is ignored, so the alias still applies.
    try std.testing.expect(parse("/mlb?color=off&T").scoreboard.color.? == false);
    // Among aliases alone, the later letter wins.
    try std.testing.expect(parse("/mlb?T&A").scoreboard.color.? == true);
    try std.testing.expect(parse("/mlb?A&T").scoreboard.color.? == false);
    try std.testing.expect(parse("/mlb?TA").scoreboard.color.? == true);
    try std.testing.expect(parse("/mlb?AT").scoreboard.color.? == false);
    // Long quiet/oneline win over ?q/?0 the same way.
    try std.testing.expect(parse("/mlb?q&quiet=0").scoreboard.quiet == false);
    try std.testing.expect(parse("/mlb?quiet=0&q").scoreboard.quiet == false);
    try std.testing.expect(parse("/mlb?0&oneline=0").scoreboard.oneline == false);
    try std.testing.expect(parse("/mlb?quiet=1").scoreboard.quiet);
    try std.testing.expect(parse("/mlb?oneline=1").scoreboard.oneline);
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

test "stream flag parses query values and Accept header" {
    try std.testing.expect(!parse("/mlb").scoreboard.stream);
    try std.testing.expect(parse("/mlb?stream=sse").scoreboard.stream);
    try std.testing.expect(parse("/mlb?stream=SSE").scoreboard.stream);
    try std.testing.expect(parse("/mlb?stream=1").scoreboard.stream);
    try std.testing.expect(parse("/mlb?stream=true").scoreboard.stream);
    try std.testing.expect(parse("/mlb?stream=True").scoreboard.stream);
    try std.testing.expect(parse("/mlb?stream=TRUE").scoreboard.stream);
    try std.testing.expect(!parse("/mlb?stream=0").scoreboard.stream);
    try std.testing.expect(!parse("/mlb?stream=no").scoreboard.stream);
    try std.testing.expect(!parse("/mlb?stream=").scoreboard.stream);
    try std.testing.expect(!wantsStream("/mlb", "*/*"));
    try std.testing.expect(!wantsStream("/mlb", "text/html"));
    try std.testing.expect(wantsStream("/mlb", "text/event-stream"));
    try std.testing.expect(wantsStream("/mlb", "Text/Event-Stream"));
    try std.testing.expect(wantsStream("/mlb", "text/html, text/event-stream"));
    try std.testing.expect(wantsStream("/mlb?stream=sse", ""));
    // Stream and display params compose: the poll key must vary renders.
    try std.testing.expect(parse("/mlb?stream=sse&width=80").scoreboard.stream);
    try std.testing.expect(parse("/mlb?stream=sse&width=80").scoreboard.width.? == 80);
}

test "help routes parse with display flags" {
    // Global spellings plus the /api/v1/ twins (JSON by address, rendered
    // from the same help route).
    try std.testing.expect(parse("/:help") == .help);
    try std.testing.expect(parse("/help") == .help);
    try std.testing.expect(parse("/api/v1/:help") == .help);
    try std.testing.expect(parse("/api/v1/help") == .help);
    try std.testing.expect(isJsonTarget("/api/v1/:help"));
    try std.testing.expect(isJsonTarget("/api/v1/help"));
    // Per-league spellings (and the API twins) never fall into the team view.
    try std.testing.expect(parse("/mlb/:help") == .help);
    try std.testing.expect(parse("/mlb/help") == .help);
    try std.testing.expect(parse("/api/v1/mlb/:help") == .help);
    try std.testing.expect(parse("/api/v1/mlb/help") == .help);
    // Display aliases (combined, separate, and precedence) ride on help too.
    const combined = parse("/:help?0pq").help;
    try std.testing.expect(combined.oneline);
    try std.testing.expect(combined.quiet);
    try std.testing.expect(combined.color == null);
    const separate = parse("/mlb/help?0&q").help;
    try std.testing.expect(separate.oneline);
    try std.testing.expect(separate.quiet);
    try std.testing.expect(parse("/help?T").help.color.? == false);
    try std.testing.expect(parse("/help?A").help.color.? == true);
    try std.testing.expect(parse("/help?color=1&T").help.color.? == true);
    try std.testing.expect(parse("/help?T&color=1").help.color.? == true);
    try std.testing.expect(parse("/help?q&quiet=0").help.quiet == false);
    try std.testing.expect(parse("/help?0&oneline=0").help.oneline == false);
    // Help beats date validation: a bad ?date on a help address still helps.
    try std.testing.expect(parse("/:help?date=tomorrow") == .help);
    // Almost-help still misses: deeper paths and team abbrevs are untouched.
    try std.testing.expect(parse("/mlb/help/x") == .not_found);
    try std.testing.expect(parse("/mlb/helpful").team.abbr[0] == 'h');
}

test "standings routes parse before the game/team split" {
    const short = parse("/nfl/standings").standings;
    try std.testing.expectEqualStrings("nfl", short.league);
    try std.testing.expect(short.color == null);
    const api = parse("/api/v1/mlb/standings").standings;
    try std.testing.expectEqualStrings("mlb", api.league);
    try std.testing.expect(isJsonTarget("/api/v1/mlb/standings"));
    try std.testing.expect(!isJsonTarget("/mlb/standings"));
    // Display flags ride along (combined, separate, and precedence).
    const sized = parse("/nhl/standings?width=80&height=3").standings;
    try std.testing.expect(sized.width.? == 80);
    try std.testing.expect(sized.height.? == 3);
    try std.testing.expect(parse("/epl/standings?T").standings.color.? == false);
    try std.testing.expect(parse("/epl/standings?0q").standings.oneline);
    try std.testing.expect(parse("/epl/standings?0q").standings.quiet);
    // Case-insensitive like team abbrevs; help and game regions untouched.
    try std.testing.expect(parse("/mlb/STANDINGS") == .standings);
    try std.testing.expect(parse("/mlb/help") == .help);
    try std.testing.expect(parse("/mlb/401816828") == .game);
    try std.testing.expect(parse("/mlb/phi") == .team);
    // Deeper paths are not routes; a bare /standings is a (unknown) league.
    try std.testing.expect(parse("/mlb/standings/x") == .not_found);
    try std.testing.expect(parse("/standings") == .scoreboard);
    // Unknown-league slugs still parse: the serve layer answers 404 via
    // the league lookup, so the route carries the slug verbatim.
    try std.testing.expectEqualStrings("quidditch", parse("/quidditch/standings").standings.league);
}
