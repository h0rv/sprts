//! nflverse fallback source for NFL boards.
//!
//! ESPN's scoreboard returns 200-with-0-events where there is nothing to
//! show: offseason, preseason, playoffs history, and bye-week-adjacent
//! dates. nflverse `games.csv`
//! (https://github.com/nflverse/nflverse-data, CC-BY-4.0, daily in-season,
//! same-day latency, NOT live) fills exactly those gaps: it carries final
//! scores and the schedule for every NFL game since 1999, including an
//! `espn` column with the ESPN game id — the free join key.
//!
//! Shape of the integration:
//!
//! - `Source` is the vtable concept around fetching (`fetchBoard`-shaped).
//!   `NflverseSource` implements it; the ESPN side implements it via
//!   `provider.EspnSource` (kept in `provider.zig`: this module only
//!   depends on `core`, so the ESPN adapter cannot live here without a
//!   circular import).
//! - `NflverseSource` is backed by a periodically refreshed `games.csv`
//!   SNAPSHOT, never a per-request download: the sidecar
//!   `tools/fetch-nflverse` (or any cron hitting the same two files)
//!   refreshes `{dir}/games.csv` daily in-season and bumps
//!   `{dir}/timestamp.txt` afterwards. The source re-reads the CSV only
//!   when the stamp changes (`timestamp.txt`-gated) and otherwise serves
//!   the parsed snapshot from its in-process store. A missing directory
//!   degrades to "no fallback" (null), never to a failed request.
//! - Per-league preference: `nfl` prefers `{espn, nflverse}`, every other
//!   league is ESPN-only (`preferenceFor`).
//! - Policy is FALLBACK-NOT-MERGE (`pickBoard`): a non-empty ESPN board
//!   always wins (this covers the live case — any `in` game means the
//!   board is non-empty), and an empty ESPN board dated today stays ESPN
//!   (ESPN is authoritative for today; games may still go live). Only a
//!   transport error or a 200-with-0-events board off-today falls back to
//!   the snapshot, wholesale — per-game merges would mix provenances, so
//!   the join primitives (`findByEspnId`, `applyScore`) exist only as the
//!   honest building blocks with the blank rule baked in. nflverse boards
//!   are never live (the CSV is daily), so they land under the final TTL
//!   variant of the cache automatically, labeled with `source_label`
//!   instead of `site.api.espn.com`.
//! - Detail enrichment stays ESPN-only: `games.csv` carries no
//!   play-by-play, situations, win probability, or probables, so grafting
//!   snapshot rows onto a live detail view would mislead. `fetchDetail`
//!   is untouched by the fallback.
//!
//! CSV columns, documented. Mapped: `espn` (join key), `gameday`
//! (YYYY-MM-DD board date), `season`, `week`, `game_type` (PRE/REG/POST),
//! `away_team`/`home_team` (abbrevs), `away_score`/`home_score`,
//! `gametime` (ET kickoff for pre-game status). Skipped: everything else,
//! notably the betting columns (`spread_line`, `total_line`,
//! `away_moneyline`, `home_moneyline`, spread/total odds) — PLAN.md
//! non-goals forbid betting odds, so they are never mapped, never
//! surfaced, and the parser does not even look them up.

const std = @import("std");
const core = @import("sprts_core");

/// Distinct `source` label for snapshot-filled boards. ESPN boards keep
/// `site.api.espn.com`; the JSON `source` field (and everything rendered
/// from it) stays honest about which upstream served the board.
pub const source_label: []const u8 = "github.com/nflverse/nflverse-data";

/// Attribution for the snapshot, surfaced on the help page (`help.zig`
/// SOURCES section) and the fetch script header.
pub const attribution: []const u8 = "NFL history/offseason via nflverse games.csv (CC-BY-4.0, github.com/nflverse/nflverse-data); daily snapshot, not live.";

pub const Preference = enum { espn_only, espn_then_nflverse };

/// Per-league source preference: only `nfl` gets the nflverse secondary;
/// every other league is ESPN-only.
pub fn preferenceFor(slug: []const u8) Preference {
    if (std.mem.eql(u8, slug, "nfl")) return .espn_then_nflverse;
    return .espn_only;
}

/// Fetch vtable around board retrieval (`fetchBoard`-shaped). Detail
/// enrichment is deliberately outside it (see the module docs: snapshot
/// rows cannot enrich a live detail view).
pub const Source = struct {
    ptr: *anyopaque,
    fetchBoardFn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8) anyerror!?core.domain.Scoreboard,

    /// One day's board, or null when this source has nothing for the day
    /// (the caller keeps its ESPN board / error in that case).
    pub fn fetchBoard(self: Source, arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8) anyerror!?core.domain.Scoreboard {
        return self.fetchBoardFn(self.ptr, arena, league, day);
    }
};

/// One parsed `games.csv` row. Scores are null when the CSV cell is blank
/// (unplayed games); a blank score renders as `""`, never `"0"`.
pub const Row = struct {
    espn_id: []const u8,
    date: []const u8,
    season: []const u8,
    week: []const u8,
    game_type: []const u8,
    away: []const u8,
    home: []const u8,
    away_score: ?[]const u8,
    home_score: ?[]const u8,
    gametime: []const u8,
};

const column_names = [_][]const u8{
    "espn",      "gameday",   "season",     "week",       "game_type",
    "away_team", "home_team", "away_score", "home_score", "gametime",
};

/// Split one CSV line into fields, honoring double quotes (`""` escapes a
/// quote). Flat and dependency-free: stadium names and future columns may
/// contain commas, so a naive comma split would misalign the join key.
fn splitCsvLine(arena: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var in_quotes = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"') {
            if (in_quotes and i + 1 < line.len and line[i + 1] == '"') {
                i += 1; // escaped quote, stays inside the field
            } else {
                in_quotes = !in_quotes;
            }
        } else if (c == ',' and !in_quotes) {
            try fields.append(arena, unquote(line[start..i]));
            start = i + 1;
        }
    }
    try fields.append(arena, unquote(line[start..]));
    return fields.toOwnedSlice(arena);
}

fn unquote(field: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, field, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn blankToNull(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

/// Parse a `games.csv` snapshot into rows. Only the documented columns are
/// looked up by header name; every other column (including the betting
/// columns PLAN.md forbids) is ignored positionally. Rows without an
/// `espn` id are skipped: the id is the join key, a row without one can
/// never board. Pure (no I/O), so fixtures test it directly.
pub fn parseSnapshot(arena: std.mem.Allocator, csv: []const u8) ![]const Row {
    var lines = std.mem.splitScalar(u8, csv, '\n');
    const header_line = blk: {
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            break :blk line;
        }
        return &.{};
    };
    const header = try splitCsvLine(arena, header_line);
    var index: [@typeInfo(@TypeOf(column_names)).array.len]?usize = .{null} ** column_names.len;
    for (header, 0..) |name, i| {
        for (column_names, 0..) |wanted, w| {
            if (std.mem.eql(u8, name, wanted)) index[w] = i;
        }
    }
    // The join key and the board date are mandatory: without them no row
    // can board, so an exotic header fails loudly instead of silently
    // boarding nothing.
    if (index[0] == null or index[1] == null) return error.BadSnapshotHeader;
    var rows: std.ArrayList(Row) = .empty;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const fields = try splitCsvLine(arena, line);
        const at = struct {
            fn at(cols: []const []const u8, i: ?usize) []const u8 {
                const k = i orelse return "";
                if (k >= cols.len) return "";
                return std.mem.trim(u8, cols[k], " \t");
            }
        }.at;
        const espn_id = at(fields, index[0]);
        if (espn_id.len == 0) continue;
        try rows.append(arena, .{
            .espn_id = try arena.dupe(u8, espn_id),
            .date = try arena.dupe(u8, at(fields, index[1])),
            .season = try arena.dupe(u8, at(fields, index[2])),
            .week = try arena.dupe(u8, at(fields, index[3])),
            .game_type = try arena.dupe(u8, at(fields, index[4])),
            .away = try arena.dupe(u8, at(fields, index[5])),
            .home = try arena.dupe(u8, at(fields, index[6])),
            .away_score = if (blankToNull(at(fields, index[7]))) |s| try arena.dupe(u8, s) else null,
            .home_score = if (blankToNull(at(fields, index[8]))) |s| try arena.dupe(u8, s) else null,
            .gametime = try arena.dupe(u8, at(fields, index[9])),
        });
    }
    return rows.toOwnedSlice(arena);
}

const TeamName = struct { abbrev: []const u8, name: []const u8 };

/// Abbrev to full name. nflverse rows carry abbrevs only (no ESPN team
/// ids), so participant identity is abbrev-derived; unknown abbrevs fall
/// back to the abbrev itself rather than dropping the game.
const team_names = [_]TeamName{
    .{ .abbrev = "ARI", .name = "Arizona Cardinals" },
    .{ .abbrev = "ATL", .name = "Atlanta Falcons" },
    .{ .abbrev = "BAL", .name = "Baltimore Ravens" },
    .{ .abbrev = "BUF", .name = "Buffalo Bills" },
    .{ .abbrev = "CAR", .name = "Carolina Panthers" },
    .{ .abbrev = "CHI", .name = "Chicago Bears" },
    .{ .abbrev = "CIN", .name = "Cincinnati Bengals" },
    .{ .abbrev = "CLE", .name = "Cleveland Browns" },
    .{ .abbrev = "DAL", .name = "Dallas Cowboys" },
    .{ .abbrev = "DEN", .name = "Denver Broncos" },
    .{ .abbrev = "DET", .name = "Detroit Lions" },
    .{ .abbrev = "GB", .name = "Green Bay Packers" },
    .{ .abbrev = "HOU", .name = "Houston Texans" },
    .{ .abbrev = "IND", .name = "Indianapolis Colts" },
    .{ .abbrev = "JAX", .name = "Jacksonville Jaguars" },
    .{ .abbrev = "KC", .name = "Kansas City Chiefs" },
    .{ .abbrev = "LAC", .name = "Los Angeles Chargers" },
    .{ .abbrev = "LAR", .name = "Los Angeles Rams" },
    .{ .abbrev = "LV", .name = "Las Vegas Raiders" },
    .{ .abbrev = "MIA", .name = "Miami Dolphins" },
    .{ .abbrev = "MIN", .name = "Minnesota Vikings" },
    .{ .abbrev = "NE", .name = "New England Patriots" },
    .{ .abbrev = "NO", .name = "New Orleans Saints" },
    .{ .abbrev = "NYG", .name = "New York Giants" },
    .{ .abbrev = "NYJ", .name = "New York Jets" },
    .{ .abbrev = "PHI", .name = "Philadelphia Eagles" },
    .{ .abbrev = "PIT", .name = "Pittsburgh Steelers" },
    .{ .abbrev = "SEA", .name = "Seattle Seahawks" },
    .{ .abbrev = "SF", .name = "San Francisco 49ers" },
    .{ .abbrev = "TB", .name = "Tampa Bay Buccaneers" },
    .{ .abbrev = "TEN", .name = "Tennessee Titans" },
    .{ .abbrev = "WAS", .name = "Washington Commanders" },
};

fn teamName(abbrev: []const u8) []const u8 {
    for (team_names) |entry| if (std.mem.eql(u8, entry.abbrev, abbrev)) return entry.name;
    return abbrev;
}

/// `gametime` (`HH:MM`, ET kickoff) to ESPN-flavored status
/// (`1:00 PM ET`). Unparseable input rides through raw rather than
/// dropping the game.
fn preStatus(arena: std.mem.Allocator, gametime: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, gametime, " \t");
    if (t.len >= 4) {
        const hour = std.fmt.parseInt(u8, t[0..2], 10) catch return try arena.dupe(u8, t);
        const minute = if (t.len >= 5 and t[2] == ':') std.fmt.parseInt(u8, t[3..5], 10) catch return try arena.dupe(u8, t) else return try arena.dupe(u8, t);
        if (hour <= 23 and minute <= 59) {
            const hour12 = if (hour == 0) 12 else if (hour > 12) hour - 12 else hour;
            const suffix: []const u8 = if (hour < 12) "AM" else "PM";
            return try std.fmt.allocPrint(arena, "{d}:{d:0>2} {s} ET", .{ hour12, minute, suffix });
        }
    }
    if (t.len == 0) return try arena.dupe(u8, "Scheduled");
    return try arena.dupe(u8, t);
}

/// Build one day's board from parsed rows, or null when no row matches
/// the day (the caller keeps its ESPN board / error then). Game ids are
/// the ESPN ids, so boards join 1:1 with ESPN's. Scores: both present
/// means final (`post`/`Final`, winner to the higher score, ties flag
/// neither); anything else is `pre` with the kickoff status. States are
/// never `in` — the snapshot is daily, not live — which is also what
/// keeps these boards on the cache's final TTL variant automatically.
/// `starts_at` is date-only: `games.csv` kickoffs are ET-local with no
/// UTC instant, and fake precision would mislead the zone renderers.
pub fn boardFromRows(arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8, rows: []const Row) !?core.domain.Scoreboard {
    var games: std.ArrayList(core.domain.Game) = .empty;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.date, day)) continue;
        const away_name = teamName(row.away);
        const home_name = teamName(row.home);
        const away_score = row.away_score orelse "";
        const home_score = row.home_score orelse "";
        const played = row.away_score != null and row.home_score != null;
        var away_winner = false;
        var home_winner = false;
        if (played) {
            const a = std.fmt.parseInt(i64, away_score, 10) catch null;
            const h = std.fmt.parseInt(i64, home_score, 10) catch null;
            if (a != null and h != null) {
                away_winner = a.? > h.?;
                home_winner = h.? > a.?;
            }
        }
        const participants = try arena.alloc(core.domain.Participant, 2);
        participants[0] = .{
            .id = try arena.dupe(u8, row.away),
            .name = try arena.dupe(u8, away_name),
            .abbreviation = try arena.dupe(u8, row.away),
            .score = try arena.dupe(u8, away_score),
            .winner = away_winner,
            .home_away = "away",
        };
        participants[1] = .{
            .id = try arena.dupe(u8, row.home),
            .name = try arena.dupe(u8, home_name),
            .abbreviation = try arena.dupe(u8, row.home),
            .score = try arena.dupe(u8, home_score),
            .winner = home_winner,
            .home_away = "home",
        };
        // Snapshot games are either final or scheduled, never live —
        // the CSV is daily, not live — which is also what keeps these
        // boards on the cache's final TTL variant automatically.
        const state: []const u8 = if (played) "post" else "pre";
        try games.append(arena, .{
            .id = try arena.dupe(u8, row.espn_id),
            .name = try std.fmt.allocPrint(arena, "{s} at {s}", .{ away_name, home_name }),
            .starts_at = try arena.dupe(u8, row.date),
            .state = state,
            .status = if (played) try arena.dupe(u8, "Final") else try preStatus(arena, row.gametime),
            .participants = participants,
        });
    }
    if (games.items.len == 0) return null;
    return .{
        .league = try arena.dupe(u8, league.slug),
        .league_name = try arena.dupe(u8, league.name),
        .date = try arena.dupe(u8, day),
        .source = try arena.dupe(u8, source_label),
        .games = try games.toOwnedSlice(arena),
    };
}

/// Join helper: find a board game by ESPN id (the shared key across both
/// sources). Returns the game by value; participant slices stay borrowed
/// from the board.
pub fn findByEspnId(board: core.domain.Scoreboard, id: []const u8) ?core.domain.Game {
    for (board.games) |game| if (std.mem.eql(u8, game.id, id)) return game;
    return null;
}

/// Blank-never-overwrites: copy a snapshot score onto a board score only
/// when the snapshot cell is non-blank. A blank nflverse cell means
/// "unknown", never zero, so it must not clobber a known score. The
/// fallback path switches whole boards (FALLBACK-NOT-MERGE) and never
/// calls this per-game; it is the shared rule for any future enrichment
/// so the invariant is stated once and tested here.
pub fn applyScore(base: *[]const u8, overlay: ?[]const u8) void {
    const o = overlay orelse return;
    if (o.len == 0) return;
    base.* = o;
}

/// FALLBACK-NOT-MERGE policy over already-fetched boards. ESPN wins
/// whenever its board is non-empty (any `in` game implies non-empty, so
/// the live case needs no special-casing) and whenever the board date is
/// today (ESPN is authoritative for today; games may still go live).
/// Otherwise the snapshot board serves wholesale when it has the day;
/// with no snapshot either, the (empty) ESPN board stands.
pub fn pickBoard(espn: core.domain.Scoreboard, day: []const u8, today: []const u8, snapshot: ?core.domain.Scoreboard) core.domain.Scoreboard {
    if (espn.games.len > 0) return espn;
    if (day.len > 0 and today.len > 0 and std.mem.eql(u8, day, today)) return espn;
    return snapshot orelse espn;
}

/// Snapshot-backed `Source`: a periodically refreshed `games.csv` sidecar
/// (`tools/fetch-nflverse`), `timestamp.txt`-gated, parsed snapshot held
/// in-process. NEVER a per-request download: the only per-request file
/// read is the tiny stamp; the CSV is re-read solely when the stamp
/// changes. Thread-safe via the mutex (the native accept loop shares one
/// instance); every board is built into the caller's arena, so no payload
/// outlives the request.
pub const NflverseSource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Snapshot directory holding `games.csv` + `timestamp.txt`. Empty
    /// means memory-only (tests): the store serves preloaded rows and
    /// never touches the filesystem.
    dir: []const u8,
    mutex: std.Io.Mutex = .init,
    store: ?*std.heap.ArenaAllocator = null,
    rows: []const Row = &.{},
    stamp: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) NflverseSource {
        return .{ .allocator = allocator, .io = io, .dir = dir };
    }

    /// Memory-only source for tests: preloaded rows, no filesystem.
    pub fn initMemory(rows: []const Row) NflverseSource {
        return .{
            .allocator = std.testing.allocator,
            .io = testIo(),
            .dir = "",
            .rows = rows,
        };
    }

    pub fn deinit(self: *NflverseSource) void {
        if (self.store) |store| {
            store.deinit();
            self.allocator.destroy(store);
            self.store = null;
            self.rows = &.{};
            self.stamp = "";
        }
    }

    pub fn asSource(self: *NflverseSource) Source {
        return .{ .ptr = self, .fetchBoardFn = dispatch };
    }

    fn dispatch(ptr: *anyopaque, arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8) anyerror!?core.domain.Scoreboard {
        const self: *NflverseSource = @ptrCast(@alignCast(ptr));
        return self.boardForDay(arena, league, day);
    }

    /// One day's snapshot board, or null when the snapshot is unavailable
    /// (unconfigured directory, unreadable files) or simply has no games
    /// that day. Null never fails the request: the caller keeps its ESPN
    /// board or error.
    pub fn boardForDay(self: *NflverseSource, arena: std.mem.Allocator, league: *const core.leagues.League, day: []const u8) !?core.domain.Scoreboard {
        if (self.dir.len == 0) return boardFromRows(arena, league, day, self.rows);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.ensureFreshLocked();
        return boardFromRows(arena, league, day, self.rows);
    }

    /// Reload `games.csv` when `timestamp.txt` moved. A failed reload
    /// keeps serving the previous snapshot (log + continue); a first load
    /// that fails leaves zero rows (callers see null, i.e. no fallback).
    fn ensureFreshLocked(self: *NflverseSource) !void {
        const stamp_path = try std.fmt.allocPrint(self.allocator, "{s}/timestamp.txt", .{self.dir});
        defer self.allocator.free(stamp_path);
        const stamp_raw = std.Io.Dir.cwd().readFileAlloc(self.io, stamp_path, self.allocator, .limited(64)) catch |err| {
            if (self.store == null) std.log.warn("nflverse snapshot stamp unreadable ({t}): no fallback until tools/fetch-nflverse runs", .{err});
            return;
        };
        defer self.allocator.free(stamp_raw);
        const stamp = std.mem.trim(u8, stamp_raw, " \t\r\n");
        if (self.store != null and std.mem.eql(u8, stamp, self.stamp)) return;
        const csv_path = try std.fmt.allocPrint(self.allocator, "{s}/games.csv", .{self.dir});
        defer self.allocator.free(csv_path);
        const csv = std.Io.Dir.cwd().readFileAlloc(self.io, csv_path, self.allocator, .limited(64 * 1024 * 1024)) catch |err| {
            std.log.warn("nflverse snapshot reload failed ({t}): keeping previous snapshot", .{err});
            return;
        };
        defer self.allocator.free(csv);
        const next = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(next);
        next.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer next.deinit();
        const rows = try parseSnapshot(next.allocator(), csv);
        const owned_stamp = try next.allocator().dupe(u8, stamp);
        if (self.store) |old| {
            old.deinit();
            self.allocator.destroy(old);
        }
        self.store = next;
        self.rows = rows;
        self.stamp = owned_stamp;
    }
};

fn testIo() std.Io {
    return test_threaded.io();
}

var test_threaded: std.Io.Threaded = .init_single_threaded;

const sample_csv =
    \\game_id,season,game_type,week,gameday,weekday,gametime,away_team,away_score,home_team,home_score,location,result,total,overtime,old_game_id,gsis,nfl_detail_id,pfr,pff,espn,ftn,away_rest,home_rest,away_moneyline,home_moneyline,spread_line,away_spread_odds,home_spread_odds,total_line,under_odds,over_odds,div_game,roof,surface,temp,wind,stadium
    \\2024_01_KC_BAL,2024,REG,1,2024-09-05,Thursday,20:20,KC,27,BAL,20,Home,27,47,0,2024090500,00-0036499,,,,401671889,,7,7,-150,130,-3.0,-110,-110,47.0,-110,-110,0,outdoors,grass,76,5,M&T Bank Stadium
    \\2024_01_GB_PHI,2024,REG,1,2024-09-06,Friday,20:15,GB,29,PHI,34,Neutral,34,63,0,2024090600,00-0036500,,,,401671890,,7,7,150,-170,2.5,-110,-110,48.5,-110,-110,0,dome,turf,68,0,Arena Corinthians
    \\2024_02_KC_CIN,2024,REG,2,2024-09-15,Sunday,16:25,KC,,CIN,,Home,,,,2024091500,00-0036599,,,,401671901,,10,10,-250,210,-6.5,-110,-110,48.0,-110,-110,1,outdoors,grass,80,8,GEHA Field
    \\2023_21_KC_SF,2023,POST,22,2024-02-11,Sunday,18:30,KC,25,SF,22,Neutral,25,47,1,2024021100,00-0036122,,,,401671887,,14,14,105,-125,2.0,-110,-110,47.5,-115,-105,0,dome,turf,68,0,Allegiant Stadium
;

test "snapshot parses rows with scores, blanks, and game types" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try parseSnapshot(arena_state.allocator(), sample_csv);
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    // Join key + scores round-trip.
    try std.testing.expectEqualStrings("401671889", rows[0].espn_id);
    try std.testing.expectEqualStrings("27", rows[0].away_score.?);
    try std.testing.expectEqualStrings("20", rows[0].home_score.?);
    // Unplayed game: blank cells are null, never "0".
    try std.testing.expect(rows[2].away_score == null);
    try std.testing.expect(rows[2].home_score == null);
    // Season phases ride along for filtering upstream of the board.
    try std.testing.expectEqualStrings("REG", rows[0].game_type);
    try std.testing.expectEqualStrings("POST", rows[3].game_type);
    try std.testing.expectEqualStrings("22", rows[3].week);
    try std.testing.expectEqualStrings("16:25", rows[2].gametime);
}

test "snapshot ignores betting columns even with absurd values" {
    // PLAN.md non-goals forbid betting odds: the parser never looks up
    // moneyline/spread columns, so hostile values cannot surface. The
    // fixture header carries them (proving they exist upstream); the row
    // boards purely on scores.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try parseSnapshot(arena_state.allocator(), sample_csv);
    const board = (try boardFromRows(arena_state.allocator(), core.leagues.find("nfl").?, "2024-09-05", rows)).?;
    try std.testing.expectEqualStrings("27", board.games[0].participants[0].score);
    try std.testing.expectEqualStrings("20", board.games[0].participants[1].score);
    const rendered = try std.json.Stringify.valueAlloc(arena_state.allocator(), board, .{});
    defer arena_state.allocator().free(rendered);
    for ([_][]const u8{ "-150", "-3.0", "47.0", "moneyline", "spread" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, rendered, token) == null);
    }
}

test "snapshot boards one day with ESPN ids and honest source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try parseSnapshot(arena, sample_csv);
    const board = (try boardFromRows(arena, core.leagues.find("nfl").?, "2024-09-06", rows)).?;
    try std.testing.expectEqualStrings("nfl", board.league);
    try std.testing.expectEqualStrings("2024-09-06", board.date);
    try std.testing.expectEqualStrings(source_label, board.source);
    try std.testing.expectEqual(@as(usize, 1), board.games.len);
    const game = board.games[0];
    // Join key: the ESPN game id, so fallback boards address games exactly
    // like ESPN boards do.
    try std.testing.expectEqualStrings("401671890", game.id);
    try std.testing.expectEqualStrings("post", game.state);
    try std.testing.expectEqualStrings("Final", game.status);
    try std.testing.expectEqualStrings("Green Bay Packers at Philadelphia Eagles", game.name);
    try std.testing.expectEqualStrings("GB", game.participants[0].abbreviation);
    try std.testing.expectEqualStrings("away", game.participants[0].home_away.?);
    try std.testing.expectEqualStrings("29", game.participants[0].score);
    try std.testing.expect(game.participants[1].winner);
    try std.testing.expect(!game.participants[0].winner);
    // A day with no rows is null (caller keeps ESPN), not an empty board
    // claiming the label.
    try std.testing.expect((try boardFromRows(arena, core.leagues.find("nfl").?, "2024-09-07", rows)) == null);
}

test "unplayed snapshot games board pre with kickoff status" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try parseSnapshot(arena, sample_csv);
    const board = (try boardFromRows(arena, core.leagues.find("nfl").?, "2024-09-15", rows)).?;
    const game = board.games[0];
    try std.testing.expectEqualStrings("pre", game.state);
    try std.testing.expectEqualStrings("4:25 PM ET", game.status);
    // Blank scores stay blank, never "0"; no winner flags pre-game.
    try std.testing.expectEqualStrings("", game.participants[0].score);
    try std.testing.expectEqualStrings("", game.participants[1].score);
    try std.testing.expect(!game.participants[0].winner);
    try std.testing.expect(!game.participants[1].winner);
    // Snapshot boards are never live: the cache's final TTL variant
    // follows automatically (isLiveBoard reads content, never provenance).
    try std.testing.expect(!core.cache.isLiveBoard(board));
}

test "quoted commas do not misalign the join key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const csv =
        \\game_id,season,game_type,week,gameday,weekday,gametime,away_team,away_score,home_team,home_score,espn,stadium
        \\2024_01_KC_BAL,2024,REG,1,2024-09-05,Thursday,20:20,KC,27,BAL,20,401671889,"M&T Bank, Stadium"
    ;
    const rows = try parseSnapshot(arena, csv);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("401671889", rows[0].espn_id);
    try std.testing.expectEqualStrings("27", rows[0].away_score.?);
}

test "rows without an ESPN id cannot board" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const csv =
        \\game_id,season,game_type,week,gameday,weekday,gametime,away_team,away_score,home_team,home_score,espn
        \\2024_01_KC_BAL,2024,REG,1,2024-09-05,Thursday,20:20,KC,27,BAL,20,
    ;
    const rows = try parseSnapshot(arena, csv);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
    try std.testing.expectError(error.BadSnapshotHeader, parseSnapshot(arena, "game_id,season\n2024_01,2024\n"));
}

test "per-league preference is nfl-only" {
    try std.testing.expectEqual(Preference.espn_then_nflverse, preferenceFor("nfl"));
    for ([_][]const u8{ "mlb", "nba", "ncaaf", "nhl", "mls", "epl" }) |slug| {
        try std.testing.expectEqual(Preference.espn_only, preferenceFor(slug));
    }
}

test "join finds games by ESPN id across sources" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try parseSnapshot(arena, sample_csv);
    const board = (try boardFromRows(arena, core.leagues.find("nfl").?, "2024-09-05", rows)).?;
    const found = findByEspnId(board, "401671889").?;
    try std.testing.expectEqualStrings("Kansas City Chiefs at Baltimore Ravens", found.name);
    try std.testing.expect(findByEspnId(board, "999999999") == null);
}

test "blank snapshot scores never overwrite known scores" {
    var away: []const u8 = "21";
    var home: []const u8 = "";
    // Blank overlay ("unknown") leaves a known score alone ...
    applyScore(&away, "");
    try std.testing.expectEqualStrings("21", away);
    applyScore(&away, null);
    try std.testing.expectEqualStrings("21", away);
    // ... while a real snapshot score fills a blank.
    applyScore(&home, "14");
    try std.testing.expectEqualStrings("14", home);
    // Non-blank overwrites non-blank: the rule is only about blanks.
    applyScore(&away, "24");
    try std.testing.expectEqualStrings("24", away);
}

fn pickTestBoard(arena: std.mem.Allocator, comptime n: usize, state: []const u8, source: []const u8) !core.domain.Scoreboard {
    const games = try arena.alloc(core.domain.Game, n);
    for (games) |*game| game.* = .{
        .id = "401671889",
        .name = "Kansas City Chiefs at Baltimore Ravens",
        .starts_at = "2024-09-05",
        .state = state,
        .status = "Final",
        .participants = &.{},
    };
    return .{
        .league = "nfl",
        .league_name = "NFL",
        .date = "2024-09-05",
        .source = source,
        .games = games,
    };
}

test "pickBoard: ESPN wins non-empty, live, and today; snapshot fills the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const espn_empty = try pickTestBoard(arena, 0, "pre", "site.api.espn.com");
    const espn_final = try pickTestBoard(arena, 1, "post", "site.api.espn.com");
    const espn_live = try pickTestBoard(arena, 1, "in", "site.api.espn.com");
    const snapshot = try pickTestBoard(arena, 1, "post", source_label);

    // Non-empty ESPN always wins — finals and live alike, on any date.
    try std.testing.expectEqualStrings("site.api.espn.com", pickBoard(espn_final, "2024-09-05", "2024-09-06", snapshot).source);
    try std.testing.expectEqualStrings("site.api.espn.com", pickBoard(espn_live, "2024-09-06", "2024-09-06", snapshot).source);
    // Empty ESPN today stays ESPN (authoritative; games may still go live).
    const today_empty = pickBoard(espn_empty, "2024-09-06", "2024-09-06", snapshot);
    try std.testing.expectEqualStrings("site.api.espn.com", today_empty.source);
    try std.testing.expectEqual(@as(usize, 0), today_empty.games.len);
    // Empty ESPN off-today falls back wholesale with the honest label.
    const filled = pickBoard(espn_empty, "2024-09-05", "2024-09-06", snapshot);
    try std.testing.expectEqualStrings(source_label, filled.source);
    try std.testing.expectEqual(@as(usize, 1), filled.games.len);
    // No snapshot either: the empty ESPN board stands (never an error).
    const standing = pickBoard(espn_empty, "2024-09-05", "2024-09-06", null);
    try std.testing.expectEqualStrings("site.api.espn.com", standing.source);
}

test "Source vtable dispatches to the snapshot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try parseSnapshot(arena, sample_csv);
    var source = NflverseSource.initMemory(rows);
    const board = (try source.asSource().fetchBoard(arena, core.leagues.find("nfl").?, "2024-09-05")).?;
    try std.testing.expectEqualStrings(source_label, board.source);
    try std.testing.expect((try source.asSource().fetchBoard(arena, core.leagues.find("nfl").?, "2024-09-07")) == null);
}
