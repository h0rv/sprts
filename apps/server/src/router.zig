const std = @import("std");
const dates = @import("sprts_core").date;

pub const Format = enum { text, html, json };

pub const ScoreboardRoute = struct {
    league: []const u8,
    date: ?[]const u8,
    /// ESPN week selector (football leases it; most sports ignore it).
    /// Strict positive int like width/height; null = date-driven board.
    week: ?u16 = null,
    /// ESPN season-type selector (football only, like week): 1=preseason,
    /// 2=regular, 3=postseason, 4=off-season. Strict 1-4; null = ESPN
    /// default (current). Without it preseason and playoff weeks are
    /// unreachable — ESPN defaults an untyped week to the regular season.
    seasontype: ?u16 = null,
    color: ?bool,
    width: ?u16,
    height: ?u16,
    /// Team-mark art kill-switch: `?art=off` strips every braille logo
    /// (tofu terminals); anything else (including absent) keeps art on.
    art: bool = true,
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
    /// Accepted for uniformity; the detail view renders no team marks,
    /// so this changes nothing (see ScoreboardRoute.art).
    art: bool = true,
    quiet: bool = false,
    oneline: bool = false,
};

pub const TeamRoute = struct {
    league: []const u8,
    abbr: []const u8,
    color: ?bool,
    width: ?u16,
    height: ?u16,
    /// Team-mark art kill-switch (see ScoreboardRoute.art): strips the
    /// logo block above the header in text and HTML.
    art: bool = true,
    quiet: bool = false,
    oneline: bool = false,
};

/// Human shortcut: `/{league}/{abbr}/today` jumps to the team's game
/// today (or falls back to its team page when none). The numeric id stays
/// the resolution address — this redirects, never renders — while every
/// renderer links the human form; `api` preserves the address family on
/// redirect (`/api/v1/` twins stay numeric API addresses). Display flags
/// are meaningless on a redirect and stay unset.
pub const TodayRoute = struct {
    league: []const u8,
    abbr: []const u8,
    api: bool,
};

/// Human game address, date form: `/{league}/{YYYY-MM-DD}/{away}-{home}`
/// (lowercase abbrevs, e.g. `/mlb/2026-09-09/min-det`; the relative tokens
/// `today|tomorrow|yesterday` ride too). This is the linked (canonical
/// presentation) form, but it still 302s to the legacy numeric
/// `/{league}/{id}` — which keeps rendering — never renders here, and has
/// no `/api/v1/` twin (JSON keeps ids, plus the additive `slug` field).
/// A doubleheader (same pair twice one day) takes an optional `-N` suffix
/// (`/{league}/{date}/{away}-{home}-2`): 1-based among same-pair games in
/// board order, 1 = first; absent is 1 (current behavior). Out-of-range N
/// misses at lookup (404); malformed suffixes stay not_found here.
pub const DateAliasRoute = struct {
    league: []const u8,
    date: []const u8,
    away: []const u8,
    home: []const u8,
    /// Doubleheader game number, 1-based (null = absent = first).
    n: ?u16 = null,
};

/// Human game address, week form (football only — the serve layer gates on
/// the league sport): `/{league}/{YYYY}/week{N}/{away}-{home}`, e.g.
/// `/nfl/2026/week1/ne-sea`. A football convenience spelling of the same
/// canonical scheme: 302s to the legacy numeric address like the date
/// form, no twin.
/// Same optional `-N` doubleheader suffix as the date form.
pub const WeekAliasRoute = struct {
    league: []const u8,
    season: []const u8,
    week: u16,
    away: []const u8,
    home: []const u8,
    /// Doubleheader game number, 1-based (null = absent = first).
    n: ?u16 = null,
};

/// Human game ordinal, date form: `/{league}/{YYYY-MM-DD}/event[-N]`
/// (bare `event` is 1; `event-2` is the second game; the relative tokens
/// `today|tomorrow|yesterday` ride too). The linked form for every game
/// no abbr pair can name — still 302s to the legacy numeric address,
/// never renders, no `/api/v1/` twin (JSON keeps ids plus `slug`).
/// N counts EVERY game on the day board in listed order (duels and
/// non-duels alike), so every game has a human URL even when no abbr pair
/// can name it. Out-of-range N misses at lookup (404); malformed shapes
/// stay not_found here. Checked BEFORE the duel form: `event-2` would
/// otherwise parse as away=event/home=2.
pub const DateEventRoute = struct {
    league: []const u8,
    date: []const u8,
    /// 1-based board ordinal (bare `event` parses as 1).
    n: u16 = 1,
};

/// Human game ordinal, week form (football only — the serve layer gates on
/// the league sport): `/{league}/{YYYY}/week{N}/event[-N]`, e.g.
/// `/nfl/2026/week1/event-3`. 302s like the date form, no twin.
pub const WeekEventRoute = struct {
    league: []const u8,
    season: []const u8,
    week: u16,
    /// 1-based board ordinal (bare `event` parses as 1).
    n: u16 = 1,
};
/// Schedule/Standings/Teams tabs). No date or week: the endpoint is the
/// current table only. Display flags ride along like every human route.
pub const StandingsRoute = struct {
    league: []const u8,
    color: ?bool,
    width: ?u16,
    height: ?u16,
    /// Accepted for uniformity; the standings table renders no team
    /// marks, so this changes nothing (see ScoreboardRoute.art).
    art: bool = true,
    quiet: bool = false,
    oneline: bool = false,
};

/// Team-list tab (`/{league}/teams`, plaintextsports parity with the
/// Schedule/Standings/Teams tabs): every member team's id/abbrev/name in
/// provider order. No date or week: membership is current-only. JSON-only
/// (the team picker is a JSON-client affordance; there is no text table),
/// so display flags are accepted for uniformity and ignored on dispatch.
pub const TeamsRoute = struct {
    league: []const u8,
};

/// Read-only terminal tour (`/{league}/tour`, plus the all-leagues
/// `/tour`): the live TUI in a browser via vendored xterm.js fed by the
/// text SSE stream. Null league is the digest tour (`/all` feed). No date
/// or size to carry: the page sizes itself from the terminal and
/// refetches `?stream=sse` on resize. Human-only, always HTML (no JSON
/// twin — the `/api/v1/` spellings serve the same page). A team
/// literally abbreviated "tour" is unreachable, like "standings" and
/// "teams" before it; the serve layer 404s unknown league slugs.
pub const TourRoute = struct {
    league: ?[]const u8,
};

/// Vendored xterm.js assets for the tour page (`/tour-assets/...`):
/// exact filenames only, anything else stays not_found.
pub const TourAssetRoute = struct {
    name: []const u8,
};

pub const HomeRoute = struct {
    date: ?[]const u8,
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
    /// Team-mark art kill-switch (see ScoreboardRoute.art): the digest
    /// concatenates scoreboard sections, so its marks strip the same way.
    art: bool = true,
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
    teams: TeamsRoute,
    today: TodayRoute,
    date_alias: DateAliasRoute,
    week_alias: WeekAliasRoute,
    date_event: DateEventRoute,
    week_event: WeekEventRoute,
    standings: StandingsRoute,
    tour: TourRoute,
    tour_asset: TourAssetRoute,
    help: HelpRoute,
    openapi,
    docs,
    llms,
    favicon,
    health,
    not_found,
    bad_date,
};

pub fn parse(target: []const u8) Route {
    const query_at = std.mem.indexOfScalar(u8, target, '?');
    var path = target[0 .. query_at orelse target.len];
    // Friendlier routing: strip ONE trailing slash pre-parse so `/mlb/`,
    // `/all/`, `/healthz/`, and `/api/v1/leagues/` (plus every other
    // slash-terminated address) parse like their bare twins. Root `/`
    // stays (it is the home route), and `//` stays not_found (only one
    // slash strips, leaving `/`, whose empty league misses below).
    if (path.len > 1 and path[path.len - 1] == '/' and !std.mem.eql(u8, path, "//")) {
        path = path[0 .. path.len - 1];
    }
    const query = if (query_at) |at| target[at + 1 ..] else "";
    const display = parseDisplay(query);

    if (std.mem.eql(u8, path, "/") or path.len == 0) {
        const day = queryValue(query, "date");
        if (day) |value| if (!dates.validate(value) and !dates.isRelativeToken(value)) return .bad_date;
        return .{ .home = .{
            .date = day,
            .color = display.color,
            .quiet = display.quiet,
            .oneline = display.oneline,
        } };
    }
    if (std.mem.eql(u8, path, "/healthz")) return .health;
    if (std.mem.eql(u8, path, "/openapi.json")) return .openapi;
    if (std.mem.eql(u8, path, "/docs")) return .docs;
    if (std.mem.eql(u8, path, "/favicon.svg")) return .favicon;
    if (std.mem.eql(u8, path, "/tour-assets/xterm.min.js")) return .{ .tour_asset = .{ .name = "xterm.min.js" } };
    if (std.mem.eql(u8, path, "/tour-assets/xterm.css")) return .{ .tour_asset = .{ .name = "xterm.css" } };
    if (std.mem.eql(u8, path, "/llms.txt")) return .llms;
    if (std.mem.eql(u8, path, "/api/v1/leagues") or std.mem.eql(u8, path, "/api/v1")) return .leagues;

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
    // Human shortcut: /{league}/{abbr}/today redirects to the team's game
    // today (team page fallback when none). Caught before the game/team
    // split, which only sees two segments; anything deeper or different
    // stays not_found.
    if (std.mem.indexOfScalar(u8, slug, '/')) |slash| {
        const league = slug[0..slash];
        const segment = slug[slash + 1 ..];
        if (league.len == 0 or segment.len == 0) return .not_found;
        // Three-segment human shortcut (see TodayRoute): anything deeper
        // or different stays not_found.
        if (std.mem.indexOfScalar(u8, segment, '/')) |slash2| {
            const seg2 = segment[0..slash2];
            const seg3 = segment[slash2 + 1 ..];
            const api = std.mem.startsWith(u8, path, api_prefix);
            if (seg2.len > 0 and std.mem.eql(u8, seg3, "today") and
                !isHelpSegment(seg2) and !isStandingsSegment(seg2) and !isTeamsSegment(seg2) and !isTourSegment(seg2))
            {
                return .{ .today = .{
                    .league = league,
                    .abbr = seg2,
                    .api = api,
                } };
            }
            // Human game aliases (human URLs only — no /api/v1/ twins,
            // JSON keeps ids): date form `/{league}/{date}/{away}-{home}[-N]`
            // or the ordinal `/{league}/{date}/event[-N]`, and football
            // week form `/{league}/{YYYY}/week{N}/{matchup}[-N]` or
            // `/{league}/{YYYY}/week{N}/event[-N]`. Anything else stays
            // not_found. The ordinal checks first: `event-2` would
            // otherwise parse as a duel (away=event, home=2).
            if (!api) {
                if (isAliasDate(seg2)) {
                    if (parseEventSegment(seg3)) |n| {
                        return .{ .date_event = .{
                            .league = league,
                            .date = seg2,
                            .n = n,
                        } };
                    }
                    // Reserved ordinal namespace: malformed `event-*`
                    // never falls through to the duel form.
                    if (isEventPrefixed(seg3)) return .not_found;
                    if (parseMatchup(seg3)) |matchup| {
                        return .{ .date_alias = .{
                            .league = league,
                            .date = seg2,
                            .away = matchup.away,
                            .home = matchup.home,
                            .n = matchup.n,
                        } };
                    }
                } else if (isSeason(seg2)) {
                    if (std.mem.indexOfScalar(u8, seg3, '/')) |slash3| {
                        const week_seg = seg3[0..slash3];
                        const duel = seg3[slash3 + 1 ..];
                        if (parseWeekSegment(week_seg)) |week| {
                            if (parseEventSegment(duel)) |n| {
                                return .{ .week_event = .{
                                    .league = league,
                                    .season = seg2,
                                    .week = week,
                                    .n = n,
                                } };
                            }
                            // Reserved ordinal namespace (see the date
                            // form): malformed `event-*` never duels.
                            if (isEventPrefixed(duel)) return .not_found;
                            if (parseMatchup(duel)) |matchup| {
                                return .{ .week_alias = .{
                                    .league = league,
                                    .season = seg2,
                                    .week = week,
                                    .away = matchup.away,
                                    .home = matchup.home,
                                    .n = matchup.n,
                                } };
                            }
                        }
                    }
                }
            }
            return .not_found;
        }
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
            .art = parseArt(queryValue(query, "art")),
            .quiet = display.quiet,
            .oneline = display.oneline,
        } };
        // Team-list tab: caught before the game/team split so the literal
        // never falls into the team view (no team is abbreviated "teams",
        // and game ids are digits-only, so the match is exact).
        if (isTeamsSegment(segment)) return .{ .teams = .{
            .league = league,
        } };
        // Terminal tour: caught before the game/team split so the
        // literal never falls into the team view (no team is abbreviated
        // "tour", and game ids are digits-only, so the match is exact).
        if (isTourSegment(segment)) return .{ .tour = .{
            .league = league,
        } };
        const sized = .{
            .color = display.color,
            .width = queryUint(queryValue(query, "width")),
            .height = queryUint(queryValue(query, "height")),
            .art = parseArt(queryValue(query, "art")),
            .quiet = display.quiet,
            .oneline = display.oneline,
        };
        if (isAllDigits(segment)) return .{ .game = .{
            .league = league,
            .id = segment,
            .color = sized.color,
            .width = sized.width,
            .height = sized.height,
            .art = sized.art,
            .quiet = sized.quiet,
            .oneline = sized.oneline,
        } };
        return .{ .team = .{
            .league = league,
            .abbr = segment,
            .color = sized.color,
            .width = sized.width,
            .height = sized.height,
            .art = sized.art,
            .quiet = sized.quiet,
            .oneline = sized.oneline,
        } };
    }

    const day = queryValue(query, "date");
    if (day) |value| if (!dates.validate(value) and !dates.isRelativeToken(value)) return .bad_date;
    if (std.mem.eql(u8, slug, "all")) return .{ .all = .{
        .date = day,
        .color = display.color,
        .width = queryUint(queryValue(query, "width")),
        .height = queryUint(queryValue(query, "height")),
        .art = parseArt(queryValue(query, "art")),
        .quiet = display.quiet,
        .oneline = display.oneline,
    } };
    // Digest terminal tour: the all-leagues player. Trivial next to the
    // per-league arm above (one more literal, league null).
    if (isTourSegment(slug)) return .{ .tour = .{ .league = null } };
    return .{ .scoreboard = .{
        .league = slug,
        .date = day,
        .week = queryUint(queryValue(query, "week")),
        .seasontype = parseSeasonType(queryValue(query, "seasontype")),
        .color = display.color,
        .width = queryUint(queryValue(query, "width")),
        .height = queryUint(queryValue(query, "height")),
        .art = parseArt(queryValue(query, "art")),
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

/// Date-ish second segment of the date alias: strict YYYY-MM-DD or one of
/// the relative tokens the scoreboard honors (lowercase-exact, like ?date=).
fn isAliasDate(s: []const u8) bool {
    return dates.validate(s) or dates.isRelativeToken(s);
}

/// Four-digit season for the week alias (`/{league}/{YYYY}/week{N}/...`).
fn isSeason(s: []const u8) bool {
    if (s.len != 4) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// `week{N}` selector, N = 1-99 (prefix case-insensitive, like standings).
fn parseWeekSegment(s: []const u8) ?u16 {
    if (s.len < 5 or s.len > 6) return null;
    if (!std.ascii.eqlIgnoreCase(s[0..4], "week")) return null;
    var n: u16 = 0;
    for (s[4..]) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    if (n < 1 or n > 99) return null;
    return n;
}

/// `{away}-{home}` duel, plus the optional doubleheader suffix
/// `{away}-{home}-{N}` (N = 1-99, strict positive like week/width/height).
/// Abbrevs are dashless 1-8 ASCII alnum, so the split is unambiguous: two
/// parts is the plain duel, three parts with an all-digit tail is the Nth
/// same-pair game. Anything else (no dash, empty side, long/non-alnum
/// side, bad N like `-0`/`-100`/`-x`, four parts) stays not_found.
fn parseMatchup(s: []const u8) ?struct { away: []const u8, home: []const u8, n: ?u16 } {
    const dash = std.mem.indexOfScalar(u8, s, '-') orelse return null;
    const away = s[0..dash];
    const rest = s[dash + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash2| {
        const home = rest[0..dash2];
        const tail = rest[dash2 + 1 ..];
        if (std.mem.indexOfScalar(u8, tail, '-') != null) return null;
        if (!isAliasAbbr(away) or !isAliasAbbr(home)) return null;
        const n = parseGameNumber(tail) orelse return null;
        return .{ .away = away, .home = home, .n = n };
    }
    if (!isAliasAbbr(away) or !isAliasAbbr(rest)) return null;
    return .{ .away = away, .home = rest, .n = null };
}

/// Doubleheader game number: all digits, fits u16, 1-99 (week parity).
/// Anything else is not a suffix (the matchup stays not_found).
fn parseGameNumber(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 2) return null;
    var n: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    if (n < 1 or n > 99) return null;
    return n;
}

/// Ordinal game selector: bare `event` is 1, `event-N` (N = 1-99) is N.
/// Prefix case-insensitive like week/standings. Anything else is not an
/// ordinal (the caller falls through to the duel form, unless the
/// reserved `event-` prefix applies — see `isEventPrefixed`): `event-0`,
/// `event-100`, non-digit tails, empty tails, extra dashes, and longer
/// literals like `events` or `eventx` (no dash: not even prefixed).
fn parseEventSegment(s: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(s, "event")) return 1;
    if (s.len < 7) return null;
    if (!std.ascii.eqlIgnoreCase(s[0..5], "event")) return null;
    if (s[5] != '-') return null;
    return parseGameNumber(s[6..]);
}

/// Reserved ordinal namespace: bare `event` or anything starting with
/// `event-` (case-insensitive). Valid ordinals parse via
/// `parseEventSegment`; anything else under the prefix (`event-0`,
/// `event-x`, `event-bos`) is not_found — it must never fall through to
/// the duel form (`event-0` would otherwise read as away=event/home=0).
/// A team literally abbreviated "event" keeps its id and team page; only
/// the alias slot reserves the word.
fn isEventPrefixed(s: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(s, "event")) return true;
    if (s.len < 7) return false;
    if (!std.ascii.eqlIgnoreCase(s[0..5], "event")) return false;
    return s[5] == '-';
}

fn isAliasAbbr(s: []const u8) bool {
    if (s.len == 0 or s.len > 8) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// Global help addresses: `/:help`, `/help`, and the `/api/v1/` twins.
/// A bare `help` team abbrev (`/mlb/help`) is NOT matched here — it arrives
/// as slug `mlb/help` and is caught by `isHelpSegment` in the two-segment
/// branch, so help never falls into the team view.
fn isHelpPath(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(path, "/:help") or
        std.ascii.eqlIgnoreCase(path, "/help") or
        std.ascii.eqlIgnoreCase(path, "/api/v1/:help") or
        std.ascii.eqlIgnoreCase(path, "/api/v1/help");
}

/// Second segment of `/{league}/standings` (and the `/api/v1/` twin).
fn isStandingsSegment(segment: []const u8) bool {
    return std.ascii.eqlIgnoreCase(segment, "standings");
}

/// Second segment of `/{league}/teams` (and the `/api/v1/` twin).
fn isTeamsSegment(segment: []const u8) bool {
    return std.ascii.eqlIgnoreCase(segment, "teams");
}

/// `tour` literal for `/{league}/tour` and the bare `/tour` digest tour
/// (and the `/api/v1/` twins, which serve the same page — the tour has
/// no JSON twin). Case-insensitive like standings/teams/help.
fn isTourSegment(segment: []const u8) bool {
    return std.ascii.eqlIgnoreCase(segment, "tour");
}

/// Second segment of `/{league}/:help` or `/{league}/help`.
/// Case-insensitive like standings/teams (team abbrevs match that way).
fn isHelpSegment(segment: []const u8) bool {
    return std.ascii.eqlIgnoreCase(segment, ":help") or std.ascii.eqlIgnoreCase(segment, "help");
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
    // The bare `/api/v1` root lists leagues (see parse), so it is JSON
    // like every other `/api/v1/` address; longer lookalikes (`/api/v10`)
    // only match via the trailing-slash prefix, never bare.
    return std.mem.startsWith(u8, path, "/api/v1/") or std.mem.eql(u8, path, "/api/v1");
}

/// True when a game-detail request renders the one-line fallback instead of
/// the full box: text format plus the oneline flag (`?0`, `?oneline=1`,
/// `?one-line=1`, and the bare `?oneline` spelling). HTML and JSON ignore
/// `?0` and keep their full renders — team-route precedent, the flag is
/// text-only — so `/{league}/{id}?0&format=html` and every `/api/v1/` game
/// address stay full. Both serve paths (native `main.zig`, worker
/// `serveDetail`) branch on this so their dispatches cannot drift.
pub fn gameOneLine(route: GameRoute, format: Format) bool {
    return format == .text and route.oneline;
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

/// Team-mark art kill-switch: `?art=off` (case-insensitive) strips every
/// braille logo for tofu terminals; anything else (including absent)
/// keeps art on. Layout is untouched: renderers skip the art rows
/// entirely, so no holes or dangling blank rows remain.
fn parseArt(value: ?[]const u8) bool {
    const v = value orelse return true;
    return !std.ascii.eqlIgnoreCase(v, "off");
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

/// ESPN season-type selector: strict 1-4 (1=preseason, 2=regular,
/// 3=postseason, 4=off-season). Anything else is ignored (falls back to
/// the ESPN default), like every other strict router param.
fn parseSeasonType(value: ?[]const u8) ?u16 {
    const n = queryUint(value) orelse return null;
    if (n < 1 or n > 4) return null;
    return n;
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
    try std.testing.expect(parse("/favicon.svg") == .favicon);
    try std.testing.expect(parse("/favicon.svg?v=2") == .favicon);
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

test "seasontype param parses strict 1-4" {
    try std.testing.expect(parse("/mlb").scoreboard.seasontype == null);
    try std.testing.expect(parse("/nfl?seasontype=1").scoreboard.seasontype.? == 1);
    try std.testing.expect(parse("/nfl?seasontype=2").scoreboard.seasontype.? == 2);
    try std.testing.expect(parse("/nfl?seasontype=3").scoreboard.seasontype.? == 3);
    try std.testing.expect(parse("/nfl?seasontype=4").scoreboard.seasontype.? == 4);
    try std.testing.expect(parse("/nfl?seasontype=0").scoreboard.seasontype == null);
    try std.testing.expect(parse("/nfl?seasontype=5").scoreboard.seasontype == null);
    try std.testing.expect(parse("/nfl?seasontype=99").scoreboard.seasontype == null);
    try std.testing.expect(parse("/mlb?seasontype=abc").scoreboard.seasontype == null);
    try std.testing.expect(parse("/mlb?seasontype=2x").scoreboard.seasontype == null);
    try std.testing.expect(parse("/mlb?seasontype=").scoreboard.seasontype == null);
    // Composes with week, date, and display params.
    const composed = parse("/nfl?date=2026-09-06&week=1&seasontype=3&width=80").scoreboard;
    try std.testing.expect(composed.week.? == 1);
    try std.testing.expect(composed.seasontype.? == 3);
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
    try std.testing.expect(parse("/all?date=Tomorrow") == .bad_date);
    try std.testing.expect(parse("/api/v1/all?date=Tomorrow") == .bad_date);
    // A league literally named "all" is unreachable; the digest owns /all.
    try std.testing.expect(parse("/all") != .scoreboard);
}

test "bad dates and unknown shapes still route" {
    try std.testing.expect(parse("/mlb?date=2026-13-40") == .bad_date);
    try std.testing.expect(parse("/mlb/a/b") == .not_found);
    try std.testing.expect(parse("/api/v1/mlb?date=2026-13-40") == .bad_date);
    // Relative tokens are lowercase-exact; any other casing stays strict.
    try std.testing.expect(parse("/mlb?date=Tomorrow") == .bad_date);
    try std.testing.expect(parse("/mlb?date=TODAY") == .bad_date);
    try std.testing.expect(parse("/mlb?date= tomorrow") == .bad_date);
}

test "relative date tokens parse on scoreboard and all routes" {
    // Raw tokens ride through verbatim; the serve path resolves them via
    // core.date.resolveDate(arena, raw, request_day).
    for ([_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "/mlb?date=today", .want = "today" },
        .{ .path = "/mlb?date=tomorrow", .want = "tomorrow" },
        .{ .path = "/mlb?date=yesterday", .want = "yesterday" },
    }) |case| {
        const route = parse(case.path);
        try std.testing.expect(route == .scoreboard);
        try std.testing.expectEqualStrings(case.want, route.scoreboard.date.?);
    }
    for ([_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "/all?date=today", .want = "today" },
        .{ .path = "/all?date=tomorrow", .want = "tomorrow" },
        .{ .path = "/all?date=yesterday", .want = "yesterday" },
    }) |case| {
        const route = parse(case.path);
        try std.testing.expect(route == .all);
        try std.testing.expectEqualStrings(case.want, route.all.date.?);
    }
    // /api/v1/ twins parse the same tokens (JSON by address).
    const api_board = parse("/api/v1/mlb?date=tomorrow");
    try std.testing.expect(api_board == .scoreboard);
    try std.testing.expectEqualStrings("tomorrow", api_board.scoreboard.date.?);
    try std.testing.expect(isJsonTarget("/api/v1/mlb?date=tomorrow"));
    const api_all = parse("/api/v1/all?date=yesterday");
    try std.testing.expect(api_all == .all);
    try std.testing.expectEqualStrings("yesterday", api_all.all.date.?);
    // Tokens compose with display params.
    const composed = parse("/mlb?date=today&width=80").scoreboard;
    try std.testing.expectEqualStrings("today", composed.date.?);
    try std.testing.expect(composed.width.? == 80);
}

test "home honors an optional date like scoreboard and all" {
    // Dateless home is unchanged: today by serve-time default.
    try std.testing.expect(parse("/").home.date == null);
    try std.testing.expect(parse("/").home.color == null);
    // Strict dates and relative tokens ride through verbatim; the serve
    // path resolves them via tz.resolveDay like every other dated route.
    try std.testing.expectEqualStrings("2026-09-01", parse("/?date=2026-09-01").home.date.?);
    try std.testing.expectEqualStrings("today", parse("/?date=today").home.date.?);
    try std.testing.expectEqualStrings("tomorrow", parse("/?date=tomorrow").home.date.?);
    try std.testing.expectEqualStrings("yesterday", parse("/?date=yesterday").home.date.?);
    // Junk dates miss the same way they do on scoreboard and all.
    try std.testing.expect(parse("/?date=2026-13-40") == .bad_date);
    try std.testing.expect(parse("/?date=Tomorrow") == .bad_date);
    try std.testing.expect(parse("/?date=TODAY") == .bad_date);
    // Date composes with the display flags.
    const composed = parse("/?date=2026-09-01&q&0").home;
    try std.testing.expectEqualStrings("2026-09-01", composed.date.?);
    try std.testing.expect(composed.quiet);
    try std.testing.expect(composed.oneline);
    try std.testing.expect(parse("/?date=2026-09-01&color=0").home.color.? == false);
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
    // One trailing slash strips pre-parse, so `/mlb/` is the scoreboard.
    try std.testing.expectEqualStrings("mlb", parse("/mlb/").scoreboard.league);
    try std.testing.expect(parse("//phi") == .not_found);
}

test "today shortcut parses team scope with address family" {
    const short = parse("/mlb/PHI/today").today;
    try std.testing.expectEqualStrings("mlb", short.league);
    try std.testing.expectEqualStrings("PHI", short.abbr);
    try std.testing.expect(!short.api);
    const api = parse("/api/v1/mlb/PHI/today").today;
    try std.testing.expect(api.api);
    try std.testing.expectEqualStrings("PHI", api.abbr);
    // Deeper paths, wrong tails, and reserved words stay not_found.
    try std.testing.expect(parse("/mlb/PHI/today/x") == .not_found);
    try std.testing.expect(parse("/mlb/PHI/yesterday") == .not_found);
    // One trailing slash strips pre-parse, so `/mlb/PHI/` is the team view.
    try std.testing.expectEqualStrings("PHI", parse("/mlb/PHI/").team.abbr);
    try std.testing.expect(parse("/mlb//today") == .not_found);
    try std.testing.expect(parse("/mlb/help/today") == .not_found);
    try std.testing.expect(parse("/mlb/standings/today") == .not_found);
    // Query strings ride along ignored (redirects carry no query).
    try std.testing.expectEqualStrings("PHI", parse("/mlb/PHI/today?color=0").today.abbr);
}

test "date alias parses date and matchup, human only" {
    const alias = parse("/mlb/2026-09-09/min-det").date_alias;
    try std.testing.expectEqualStrings("mlb", alias.league);
    try std.testing.expectEqualStrings("2026-09-09", alias.date);
    try std.testing.expectEqualStrings("min", alias.away);
    try std.testing.expectEqualStrings("det", alias.home);
    // Relative tokens ride verbatim like ?date= (serve resolves the zone).
    for ([_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "/mlb/today/min-det", .want = "today" },
        .{ .path = "/mlb/tomorrow/nyy-bos", .want = "tomorrow" },
        .{ .path = "/mlb/yesterday/lad-sf", .want = "yesterday" },
    }) |case| {
        const route = parse(case.path);
        try std.testing.expect(route == .date_alias);
        try std.testing.expectEqualStrings(case.want, route.date_alias.date);
    }
    // Matchup case is preserved raw (matching is case-insensitive downstream).
    const upper = parse("/mlb/2026-09-09/MIN-DET").date_alias;
    try std.testing.expectEqualStrings("MIN", upper.away);
    try std.testing.expectEqualStrings("DET", upper.home);
    // Query strings ride along ignored (redirects carry no query).
    try std.testing.expectEqualStrings("min", parse("/mlb/2026-09-09/min-det?color=0").date_alias.away);
    // No /api/v1/ twins: JSON keeps ids.
    try std.testing.expect(parse("/api/v1/mlb/2026-09-09/min-det") == .not_found);
    try std.testing.expect(parse("/api/v1/mlb/today/min-det") == .not_found);
    // Bad shapes stay not_found: no dash, two dashes, empty side, long
    // side, non-alnum side, bad date, token casing, deeper paths.
    try std.testing.expect(parse("/mlb/2026-09-09/mindet") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/min--det") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/-det") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/min-") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/min-detroit99") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/min-d.t") == .not_found);
    try std.testing.expect(parse("/mlb/09-09/min-det") == .not_found);
    try std.testing.expect(parse("/mlb/2026-13-40/min-det") == .not_found);
    try std.testing.expect(parse("/mlb/Today/min-det") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/min-det/x") == .not_found);
    // One trailing slash strips pre-parse, so the bare date rides the
    // two-segment team split like its slashless twin (dispatch 404s it as
    // an unknown team).
    try std.testing.expectEqualStrings("2026-09-09", parse("/mlb/2026-09-09/").team.abbr);
    // Existing two-segment regions are untouched by the alias shapes.
    try std.testing.expect(parse("/mlb/a/b") == .not_found);
    try std.testing.expect(parse("/mlb/phi") == .team);
    try std.testing.expect(parse("/mlb/401816828") == .game);
}

test "week alias parses season, week, and matchup, human only" {
    const alias = parse("/nfl/2026/week1/ne-sea").week_alias;
    try std.testing.expectEqualStrings("nfl", alias.league);
    try std.testing.expectEqualStrings("2026", alias.season);
    try std.testing.expect(alias.week == 1);
    try std.testing.expectEqualStrings("ne", alias.away);
    try std.testing.expectEqualStrings("sea", alias.home);
    // Week range 1-99; league slug rides verbatim (sport gate is dispatch).
    try std.testing.expect(parse("/nfl/2026/week18/kc-buf").week_alias.week == 18);
    try std.testing.expect(parse("/nfl/2026/week99/kc-buf").week_alias.week == 99);
    try std.testing.expectEqualStrings("ncaaf", parse("/ncaaf/2026/week2/uga-tx").week_alias.league);
    try std.testing.expectEqualStrings("mlb", parse("/mlb/2026/week1/nyy-bos").week_alias.league);
    // No /api/v1/ twins: JSON keeps ids.
    try std.testing.expect(parse("/api/v1/nfl/2026/week1/ne-sea") == .not_found);
    // Bad shapes stay not_found: week 0/100, bad prefix, short season,
    // bad matchup, missing segments, deeper paths.
    try std.testing.expect(parse("/nfl/2026/week0/ne-sea") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week100/ne-sea") == .not_found);
    try std.testing.expect(parse("/nfl/2026/wk1/ne-sea") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week/ne-sea") == .not_found);
    try std.testing.expect(parse("/nfl/2026/weekx/ne-sea") == .not_found);
    try std.testing.expect(parse("/nfl/26/week1/ne-sea") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1/nesea") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1/ne--sea") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1/") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1/ne-sea/x") == .not_found);
    try std.testing.expect(parse("/nfl/2026/ne-sea") == .not_found);
}

test "alias game-number suffix parses on both forms, human only" {
    // Date form: -2 selects the second same-pair game, absent stays null
    // (= first, current behavior).
    const dated = parse("/mlb/2026-09-09/min-det-2").date_alias;
    try std.testing.expectEqualStrings("min", dated.away);
    try std.testing.expectEqualStrings("det", dated.home);
    try std.testing.expect(dated.n.? == 2);
    try std.testing.expect(parse("/mlb/2026-09-09/min-det").date_alias.n == null);
    try std.testing.expect(parse("/mlb/2026-09-09/min-det-1").date_alias.n.? == 1);
    try std.testing.expect(parse("/mlb/2026-09-09/min-det-99").date_alias.n.? == 99);
    // Rides the relative tokens like the plain duel.
    try std.testing.expect(parse("/mlb/today/min-det-2").date_alias.n.? == 2);
    // Week form carries the same suffix.
    const week = parse("/nfl/2026/week1/ne-sea-2").week_alias;
    try std.testing.expect(week.week == 1);
    try std.testing.expectEqualStrings("ne", week.away);
    try std.testing.expect(week.n.? == 2);
    try std.testing.expect(parse("/nfl/2026/week1/ne-sea").week_alias.n == null);
    // No /api/v1/ twins for the suffixed shapes either.
    try std.testing.expect(parse("/api/v1/mlb/2026-09-09/min-det-2") == .not_found);
    try std.testing.expect(parse("/api/v1/nfl/2026/week1/ne-sea-2") == .not_found);
    // Bad suffixes stay not_found: N of 0/100, non-digit tails, empty
    // tails, extra dashes, and bad abbrevs alongside a good suffix.
    try std.testing.expect(parse("/mlb/2026-09-09/min-det-0") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/min-det-100") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/min-det-x") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/min-det-2x") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/min-det-") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/min-det-2-3") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/min--det-2") == .not_found);
    try std.testing.expect(parse("/mlb/2026-09-09/-det-2") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1/ne-sea-0") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1/ne-sea-100") == .not_found);
}

test "event ordinal parses on the date form, human only" {
    // Bare `event` is the first game; `event-N` is the Nth in board order.
    const bare = parse("/ufc/2026-09-05/event").date_event;
    try std.testing.expectEqualStrings("ufc", bare.league);
    try std.testing.expectEqualStrings("2026-09-05", bare.date);
    try std.testing.expect(bare.n == 1);
    const second = parse("/ufc/2026-09-05/event-2").date_event;
    try std.testing.expectEqualStrings("ufc", second.league);
    try std.testing.expect(second.n == 2);
    try std.testing.expect(parse("/f1/2025-09-07/event-3").date_event.n == 3);
    try std.testing.expect(parse("/f1/2025-09-07/event-99").date_event.n == 99);
    // Rides the relative tokens like the duel form.
    try std.testing.expectEqualStrings("today", parse("/ufc/today/event-2").date_event.date);
    try std.testing.expectEqualStrings("tomorrow", parse("/pga/tomorrow/event").date_event.date);
    // Case-insensitive prefix like week/standings; query strings ride
    // along ignored (redirects carry no query).
    try std.testing.expect(parse("/ufc/2026-09-05/EVENT-2").date_event.n == 2);
    try std.testing.expect(parse("/ufc/2026-09-05/Event").date_event.n == 1);
    try std.testing.expect(parse("/ufc/2026-09-05/event-2?color=0").date_event.n == 2);
    // Beats the duel parse: `event-2` as away=event/home=2 would mislead
    // (a team literally abbreviated "event" aside), so it must be the
    // ordinal, never the duel.
    try std.testing.expect(parse("/ufc/2026-09-05/event-2") == .date_event);
    // No /api/v1/ twins: JSON keeps ids.
    try std.testing.expect(parse("/api/v1/ufc/2026-09-05/event-2") == .not_found);
    try std.testing.expect(parse("/api/v1/ufc/2026-09-05/event") == .not_found);
    // Bad shapes stay not_found: N of 0/100, non-digit tails, empty
    // tails, extra dashes, longer literals, and bad dates.
    try std.testing.expect(parse("/ufc/2026-09-05/event-0") == .not_found);
    try std.testing.expect(parse("/ufc/2026-09-05/event-100") == .not_found);
    try std.testing.expect(parse("/ufc/2026-09-05/event-x") == .not_found);
    try std.testing.expect(parse("/ufc/2026-09-05/event-2x") == .not_found);
    try std.testing.expect(parse("/ufc/2026-09-05/event-") == .not_found);
    try std.testing.expect(parse("/ufc/2026-09-05/event-2-3") == .not_found);
    try std.testing.expect(parse("/ufc/2026-09-05/events") == .not_found);
    try std.testing.expect(parse("/ufc/2026-09-05/eventx") == .not_found);
    try std.testing.expect(parse("/ufc/2026-09-05/event-2/x") == .not_found);
    try std.testing.expect(parse("/ufc/2026-13-40/event-2") == .not_found);
    try std.testing.expect(parse("/ufc/Today/event-2") == .not_found);
    // A duel side literally abbreviated "event" cannot use the alias slot
    // (the `event-` prefix is reserved for the ordinal); it keeps its id
    // and team page.
    try std.testing.expect(parse("/mlb/2026-09-09/event-bos") == .not_found);
    // Existing regions untouched.
    try std.testing.expect(parse("/mlb/2026-09-09/min-det") == .date_alias);
    try std.testing.expect(parse("/mlb/phi") == .team);
}

test "event ordinal parses on the week form, human only" {
    const ordinal = parse("/nfl/2026/week1/event-2").week_event;
    try std.testing.expectEqualStrings("nfl", ordinal.league);
    try std.testing.expectEqualStrings("2026", ordinal.season);
    try std.testing.expect(ordinal.week == 1);
    try std.testing.expect(ordinal.n == 2);
    try std.testing.expect(parse("/nfl/2026/week1/event").week_event.n == 1);
    try std.testing.expect(parse("/nfl/2026/week18/event-16").week_event.n == 16);
    try std.testing.expectEqualStrings("ncaaf", parse("/ncaaf/2026/week2/EVENT-3").week_event.league);
    // Beats the duel parse here too.
    try std.testing.expect(parse("/nfl/2026/week1/event-2") == .week_event);
    // No /api/v1/ twins.
    try std.testing.expect(parse("/api/v1/nfl/2026/week1/event-2") == .not_found);
    try std.testing.expect(parse("/api/v1/nfl/2026/week1/event") == .not_found);
    // Bad shapes stay not_found.
    try std.testing.expect(parse("/nfl/2026/week1/event-0") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1/event-100") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1/event-x") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1/event-") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1/event-2-3") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week0/event-2") == .not_found);
    try std.testing.expect(parse("/nfl/26/week1/event-2") == .not_found);
    try std.testing.expect(parse("/nfl/2026/week1/event-2/x") == .not_found);
    // A duel side literally abbreviated "event" cannot use the alias slot
    // (the `event-` prefix is reserved); it keeps its id and team page.
    try std.testing.expect(parse("/nfl/2026/week1/event-sea") == .not_found);
    // Duel form untouched.
    try std.testing.expect(parse("/nfl/2026/week1/ne-sea") == .week_alias);
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

test "teams routes parse before the game/team split" {
    const short = parse("/nfl/teams").teams;
    try std.testing.expectEqualStrings("nfl", short.league);
    const api = parse("/api/v1/mlb/teams").teams;
    try std.testing.expectEqualStrings("mlb", api.league);
    try std.testing.expect(isJsonTarget("/api/v1/mlb/teams"));
    try std.testing.expect(!isJsonTarget("/mlb/teams"));
    // Case-insensitive like standings and team abbrevs; neighboring
    // regions untouched.
    try std.testing.expect(parse("/mlb/TEAMS") == .teams);
    try std.testing.expect(parse("/mlb/Teams") == .teams);
    try std.testing.expect(parse("/mlb/help") == .help);
    try std.testing.expect(parse("/mlb/standings") == .standings);
    try std.testing.expect(parse("/mlb/401816828") == .game);
    try std.testing.expect(parse("/mlb/phi") == .team);
    // Deeper paths are not routes; a bare /teams is a (unknown) league.
    try std.testing.expect(parse("/mlb/teams/x") == .not_found);
    try std.testing.expect(parse("/teams") == .scoreboard);
    // Reserved words never ride the today shortcut as team abbrevs.
    try std.testing.expect(parse("/mlb/teams/today") == .not_found);
    // Unknown-league slugs still parse: the serve layer answers 404 via
    // the league lookup, so the route carries the slug verbatim.
    try std.testing.expectEqualStrings("quidditch", parse("/quidditch/teams").teams.league);
}

test "game one-line flag spellings parse on the detail route" {
    // Exact bug-report addresses: both spellings must set the flag.
    try std.testing.expect(parse("/mlb/401816856?0").game.oneline);
    try std.testing.expect(parse("/mlb/401816856?oneline=1").game.oneline);
    // The remaining spellings ride the same parseDisplay path.
    try std.testing.expect(parse("/mlb/401816856?one-line=1").game.oneline);
    try std.testing.expect(parse("/mlb/401816856?oneline").game.oneline);
    try std.testing.expect(parse("/mlb/401816856?0&q").game.oneline);
    try std.testing.expect(parse("/mlb/401816856?color=0&0").game.oneline);
    // Off spellings stay full-box: bare, explicit 0, long-wins-over-alias.
    try std.testing.expect(!parse("/mlb/401816856").game.oneline);
    try std.testing.expect(!parse("/mlb/401816856?oneline=0").game.oneline);
    try std.testing.expect(!parse("/mlb/401816856?0&oneline=0").game.oneline);
    // The /api/v1/ twin parses the same flag (JSON by address; dispatch
    // ignores ?0 there, covered below).
    try std.testing.expect(parse("/api/v1/mlb/401816856?0").game.oneline);
}

test "game detail dispatch honors one-line for text only" {
    // Dispatch-level: parse output plus formatFor feed the same predicate
    // both serve paths branch on, so these assertions pin the renderer
    // selection for the bug-report addresses.
    const alias = parse("/mlb/401816856?0").game;
    try std.testing.expect(gameOneLine(alias, formatFor("/mlb/401816856?0", "*/*")));
    const long = parse("/mlb/401816856?oneline=1").game;
    try std.testing.expect(gameOneLine(long, formatFor("/mlb/401816856?oneline=1", "*/*")));
    // Bare stays full-box.
    const bare = parse("/mlb/401816856").game;
    try std.testing.expect(!gameOneLine(bare, formatFor("/mlb/401816856", "*/*")));
    // ?0 combined with HTML stays full-page (team-route precedent: the flag
    // is text-only), via Accept header and via ?format= alike.
    try std.testing.expect(!gameOneLine(alias, formatFor("/mlb/401816856?0", "text/html")));
    try std.testing.expect(!gameOneLine(alias, formatFor("/mlb/401816856?format=html&0", "*/*")));
    // JSON ignores ?0 too, address-driven and Accept-driven alike.
    const api = parse("/api/v1/mlb/401816856?0").game;
    try std.testing.expect(!gameOneLine(api, formatFor("/api/v1/mlb/401816856?0", "*/*")));
    try std.testing.expect(!gameOneLine(alias, formatFor("/mlb/401816856?0", "application/json")));
}

test "llms.txt parses exact with query ignored" {
    try std.testing.expect(parse("/llms.txt") == .llms);
    try std.testing.expect(parse("/llms.txt?foo=bar") == .llms);
    try std.testing.expect(parse("/llms.txt?color=0") == .llms);
    try std.testing.expect(!isJsonTarget("/llms.txt"));
    try std.testing.expect(!isJsonTarget("/llms.txt?foo=bar"));
    // Near misses are not the agent page (one trailing slash strips
    // pre-parse, so `/llms.txt/` IS the agent page).
    try std.testing.expect(parse("/llms.txt/") == .llms);
    try std.testing.expect(parse("/llms") == .scoreboard);
}

test "art kill-switch parses off case-insensitively, anything else is on" {
    // Default: art on everywhere it is accepted.
    try std.testing.expect(parse("/mlb").scoreboard.art);
    try std.testing.expect(parse("/mlb/401816828").game.art);
    try std.testing.expect(parse("/mlb/phi").team.art);
    try std.testing.expect(parse("/all").all.art);
    try std.testing.expect(parse("/nfl/standings").standings.art);
    // `off` in any casing strips art; anything else keeps it on.
    try std.testing.expect(!parse("/mlb?art=off").scoreboard.art);
    try std.testing.expect(!parse("/mlb?art=OFF").scoreboard.art);
    try std.testing.expect(!parse("/mlb?art=Off").scoreboard.art);
    try std.testing.expect(parse("/mlb?art=on").scoreboard.art);
    try std.testing.expect(parse("/mlb?art=0").scoreboard.art);
    try std.testing.expect(parse("/mlb?art=false").scoreboard.art);
    try std.testing.expect(parse("/mlb?art=").scoreboard.art);
    try std.testing.expect(parse("/mlb?art=of").scoreboard.art);
    // Rides every art-carrying route shape, human and API alike.
    try std.testing.expect(!parse("/mlb/401816828?art=off").game.art);
    try std.testing.expect(!parse("/mlb/phi?art=OFF").team.art);
    try std.testing.expect(!parse("/all?date=2026-09-06&art=off").all.art);
    try std.testing.expect(!parse("/nfl/standings?art=off").standings.art);
    try std.testing.expect(!parse("/api/v1/mlb?art=off").scoreboard.art);
    try std.testing.expect(!parse("/api/v1/mlb/PHI?art=off").team.art);
    // Composes with the other display params.
    const composed = parse("/mlb?width=80&height=3&art=off&color=0").scoreboard;
    try std.testing.expect(!composed.art);
    try std.testing.expect(composed.width.? == 80);
    try std.testing.expect(composed.height.? == 3);
    try std.testing.expect(composed.color.? == false);
    // Redirects and mark-free pages carry no art flag.
    try std.testing.expect(@TypeOf(parse("/mlb/PHI/today").today) == TodayRoute);
    try std.testing.expect(@TypeOf(parse("/").home) == HomeRoute);
}

test "bare api root lists leagues like /api/v1/leagues" {
    // No trailing slash used to fall into human slug parsing (league
    // `api`, team `v1`); now it is the leagues listing. There is no
    // separate API root route, so dispatch serves the same leagues body.
    try std.testing.expect(parse("/api/v1") == .leagues);
    try std.testing.expect(parse("/api/v1/") == .leagues);
    try std.testing.expect(parse("/api/v1?foo=bar") == .leagues);
    try std.testing.expect(isJsonTarget("/api/v1"));
    try std.testing.expect(isJsonTarget("/api/v1/"));
    try std.testing.expectEqual(Format.json, formatFor("/api/v1", "*/*"));
    // Longer lookalikes are not the root: they ride the usual slug split.
    try std.testing.expect(parse("/api/v10") != .leagues);
    try std.testing.expect(parse("/api/v1x") != .leagues);
    try std.testing.expect(!isJsonTarget("/api/v10"));
}

test "help segments match case-insensitively like standings" {
    // Per-league spellings never fall into the team view, whatever case.
    try std.testing.expect(parse("/mlb/HELP") == .help);
    try std.testing.expect(parse("/mlb/Help") == .help);
    try std.testing.expect(parse("/mlb/:HELP") == .help);
    try std.testing.expect(parse("/mlb/:Help") == .help);
    try std.testing.expect(parse("/api/v1/mlb/HELP") == .help);
    try std.testing.expect(parse("/api/v1/mlb/:help") == .help);
    // Global spellings (and the /api/v1/ twins) match whatever case.
    try std.testing.expect(parse("/:HELP") == .help);
    try std.testing.expect(parse("/HELP") == .help);
    try std.testing.expect(parse("/Help") == .help);
    try std.testing.expect(parse("/api/v1/HELP") == .help);
    try std.testing.expect(parse("/api/v1/:HELP") == .help);
    // Display flags ride along in any casing.
    try std.testing.expect(parse("/mlb/HELP?0q").help.oneline);
    try std.testing.expect(parse("/mlb/HELP?0q").help.quiet);
    try std.testing.expect(parse("/HELP?T").help.color.? == false);
    // Reserved-word guard on the today shortcut is case-insensitive too.
    try std.testing.expect(parse("/mlb/HELP/today") == .not_found);
    try std.testing.expect(parse("/mlb/Help/today") == .not_found);
    // Almost-help still misses into the team view.
    try std.testing.expect(parse("/mlb/HELPful") == .team);
}

test "one trailing slash strips pre-parse, root and double slash stay" {
    // Single-segment routes parse like their bare twins.
    try std.testing.expectEqualStrings("mlb", parse("/mlb/").scoreboard.league);
    try std.testing.expect(parse("/all/") == .all);
    try std.testing.expect(parse("/healthz/") == .health);
    try std.testing.expect(parse("/api/v1/leagues/") == .leagues);
    try std.testing.expect(parse("/docs/") == .docs);
    try std.testing.expect(parse("/openapi.json/") == .openapi);
    try std.testing.expect(parse("/llms.txt/") == .llms);
    try std.testing.expect(parse("/favicon.svg/") == .favicon);
    // Two-segment routes parse like their bare twins.
    try std.testing.expectEqualStrings("PHI", parse("/mlb/PHI/").team.abbr);
    try std.testing.expectEqualStrings("401816828", parse("/mlb/401816828/").game.id);
    try std.testing.expect(parse("/mlb/standings/") == .standings);
    try std.testing.expect(parse("/mlb/teams/") == .teams);
    try std.testing.expect(parse("/mlb/help/") == .help);
    try std.testing.expect(parse("/api/v1/mlb/") == .scoreboard);
    try std.testing.expect(parse("/api/v1/mlb/standings/") == .standings);
    // Queries survive the strip.
    try std.testing.expectEqualStrings("2026-09-06", parse("/mlb/?date=2026-09-06").scoreboard.date.?);
    try std.testing.expectEqualStrings("2026-09-06", parse("/all/?date=2026-09-06").all.date.?);
    try std.testing.expect(parse("/mlb/?date=2026-13-40") == .bad_date);
    // Root `/` stays home (never strips to empty).
    try std.testing.expect(parse("/") == .home);
    try std.testing.expectEqualStrings("2026-09-01", parse("/?date=2026-09-01").home.date.?);
    // Only ONE slash strips: `//` stays 404 and doubled tails still miss.
    try std.testing.expect(parse("//") == .not_found);
    try std.testing.expect(parse("/mlb//") == .not_found);
    try std.testing.expect(parse("/api/v1/leagues//") == .not_found);
    try std.testing.expect(parse("/mlb/standings/x/") == .not_found);
}

test "tour routes parse for one league and the digest" {
    // Per-league player carries the slug verbatim (serve layer 404s
    // unknown leagues via the league lookup, standings precedent).
    const league_tour = parse("/mlb/tour").tour;
    try std.testing.expectEqualStrings("mlb", league_tour.league.?);
    try std.testing.expectEqualStrings("quidditch", parse("/quidditch/tour").tour.league.?);
    // Bare /tour is the all-leagues player (null league, `/all` feed).
    try std.testing.expect(parse("/tour").tour.league == null);
    // Case-insensitive like standings/teams/help; query ignored; one
    // trailing slash strips pre-parse like every other route.
    try std.testing.expect(parse("/mlb/TOUR") == .tour);
    try std.testing.expect(parse("/TOUR").tour.league == null);
    try std.testing.expect(parse("/mlb/tour?width=80") == .tour);
    try std.testing.expect(parse("/mlb/tour/") == .tour);
    try std.testing.expect(parse("/tour/").tour.league == null);
    // No JSON twin: the /api/v1/ spellings serve the same HTML page.
    try std.testing.expect(parse("/api/v1/mlb/tour") == .tour);
    try std.testing.expect(parse("/api/v1/tour").tour.league == null);
    // Never a game or a team: digits rule and abbrevs don't reach here.
    try std.testing.expect(parse("/mlb/tour") != .team);
    try std.testing.expect(parse("/mlb/tour") != .game);
    // Deeper paths stay not_found; `tour` never rides the today shortcut
    // as a team abbrev.
    try std.testing.expect(parse("/mlb/tour/x") == .not_found);
    try std.testing.expect(parse("/mlb/tour/today") == .not_found);
    // Human addresses, so never JSON by address.
    try std.testing.expect(!isJsonTarget("/mlb/tour"));
    try std.testing.expect(!isJsonTarget("/tour"));
}

test "tour assets are exact vendored filenames only" {
    try std.testing.expect(parse("/tour-assets/xterm.min.js") == .tour_asset);
    try std.testing.expect(parse("/tour-assets/xterm.css") == .tour_asset);
    try std.testing.expectEqualStrings("xterm.min.js", parse("/tour-assets/xterm.min.js").tour_asset.name);
    // Query strings ride along ignored (cache-busting `?v=` still serves).
    try std.testing.expect(parse("/tour-assets/xterm.min.js?v=1") == .tour_asset);
    try std.testing.expect(parse("/tour-assets/xterm.css/") == .tour_asset);
    // Anything else is not an asset: unknown names fall into the team
    // view like any other second segment (serve layer 404s them).
    try std.testing.expect(parse("/tour-assets/other.js") == .team);
    try std.testing.expect(parse("/tour-assets/xterm.js") == .team);
    // Bare /tour-assets (slash or not) is a (unknown) league slug like
    // /teams was: the serve layer answers 404 via the league lookup.
    try std.testing.expect(parse("/tour-assets/") == .scoreboard);
    // Bare /tour-assets is a (unknown) league slug like /teams was:
    // the serve layer answers 404 via the league lookup.
    try std.testing.expect(parse("/tour-assets") == .scoreboard);
}
