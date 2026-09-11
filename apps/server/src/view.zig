//! Shared view-layer section composers: the ONE place that turns provider
//! data into fitted, column-aligned row strings over the `table.zig`
//! primitives. Every view module (`render`, `detail_view`, `team_view`,
//! `standings_view`, `digest`) composes plain strings here; renderers own
//! emit. Composers return plain strings with `color = false`; color wraps
//! at emit time, never inside. No per-view IR, no JSON changes.
//!
//! Shape: every composer builds rows with color disabled; color, links,
//! and headings ride at emit time, so text and HTML can never drift. A
//! headed group is a `Section` (`{ heading, rows }`, owned — free with
//! `freeSection`); leader groups keep their per-row team-header flags in
//! a `LeadersBlock` / `LeadersSection` instead.
//!
//! `table.zig` owns cells, fitting, and sanitization; this module owns
//! column geometry (which column flexes, which shares a right edge).
//! Renderers own emit (ANSI spans, `<a>`/`<span>` wrapping, blank-line
//! breathing, overflow trailers, `?height` slicing).

const std = @import("std");
const core = @import("sprts_core");
const standings = core.standings;
const detail = core.detail;
const domain = core.domain;
const schedule = core.schedule;
const table = @import("table.zig");
const tz = @import("tz.zig");

/// One headed group of pre-composed rows: the heading plus every row was
/// composed with color disabled; the caller tints/wraps/links at emit
/// time. Free with `freeSection`.
pub const Section = struct {
    heading: ?[]u8,
    rows: [][]u8,
};

/// Free a `Section` built by the `*Section` composers below.
pub fn freeSection(allocator: std.mem.Allocator, section: Section) void {
    if (section.heading) |h| allocator.free(h);
    freeLines(allocator, section.rows);
}

/// Free a `[][]u8` built by the composers below.
pub fn freeLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

/// True when at least one entry anywhere carries points (hockey, soccer).
pub fn hasPoints(st: standings.LeagueStandings) bool {
    for (st.groups) |group| {
        for (group.entries) |entry| {
            if (entry.points != null) return true;
        }
    }
    return false;
}

/// One composed standings entry row (`color = false`, trailing blanks
/// trimmed, no newline); the caller writes the row plus `'\n'`.
pub fn entryRow(
    allocator: std.mem.Allocator,
    entry: standings.StandingEntry,
    cols: usize,
    points_col: bool,
) ![]u8 {
    // Fixed cells around the name: abbr 4 + spaces + record 9 + points 4
    // when the column shows; the name absorbs the rest. Ragged, never
    // padded.
    const record_width: usize = 9;
    const points_width: usize = 4;
    const fixed: usize = 4 + 2 + record_width + (if (points_col) 1 + points_width else 0);
    const name_width: usize = cols -| fixed;
    var record_buf: [32]u8 = undefined;
    const wins = entry.wins orelse "-";
    const losses = entry.losses orelse "-";
    const record: []const u8 = if (entry.ties) |ties|
        std.fmt.bufPrint(&record_buf, "{s}-{s}-{s}", .{ wins, losses, ties }) catch "-"
    else
        std.fmt.bufPrint(&record_buf, "{s}-{s}", .{ wins, losses }) catch "-";
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const b = &buf.writer;
    try table.writeCell(b, entry.abbrev, 4, null, false);
    try b.writeByte(' ');
    try table.writeCell(b, entry.name, name_width, null, false);
    try b.writeByte(' ');
    try table.writeCellRight(b, record, record_width, null, false);
    if (points_col) {
        try b.writeByte(' ');
        try table.writeCellRight(b, entry.points orelse "-", points_width, null, false);
    }
    const raw = try buf.toOwnedSlice();
    defer allocator.free(raw);
    return allocator.dupe(u8, std.mem.trimEnd(u8, raw, " "));
}

/// Composed rows for one entry slice. Caller frees each row plus the
/// slice itself (see `freeLines`).
pub fn entryRows(
    allocator: std.mem.Allocator,
    entries: []const standings.StandingEntry,
    cols: usize,
    points_col: bool,
) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |row| allocator.free(row);
        out.deinit(allocator);
    }
    for (entries) |entry| {
        try out.append(allocator, try entryRow(allocator, entry, cols, points_col));
    }
    return out.toOwnedSlice(allocator);
}

test "view entryRows carry records, ties legs, and the points column" {
    const entries = [_]standings.StandingEntry{
        .{ .team_id = "6", .abbrev = "BOS", .name = "Boston Bruins", .wins = "38", .losses = "14", .ties = "9", .points = "85" },
        .{ .team_id = "7", .abbrev = "BUF", .name = "Buffalo Sabres", .wins = "30", .losses = "25", .points = "68" },
    };
    try std.testing.expect(hasPoints(.{
        .league = "nhl",
        .league_name = "NHL",
        .season = "2026",
        .groups = &.{.{ .name = "Atlantic Division", .entries = &entries }},
    }));
    const rows = try entryRows(std.testing.allocator, &entries, 52, true);
    defer freeLines(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expect(std.mem.indexOf(u8, rows[0], "38-14-9") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows[1], "30-25") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows[0], "85") != null);
    for (rows) |row| _ = try std.unicode.Utf8View.init(row);
}

test "view hasPoints hides the column when no entry has points" {
    const st: standings.LeagueStandings = .{
        .league = "mlb",
        .league_name = "MLB",
        .season = "2026",
        .groups = &.{.{ .name = "AL East", .entries = &.{
            .{ .team_id = "19", .abbrev = "NYY", .name = "New York Yankees", .wins = "80", .losses = "63" },
        } }},
    };
    try std.testing.expect(!hasPoints(st));
    const rows = try entryRows(std.testing.allocator, st.groups[0].entries, 52, false);
    defer freeLines(std.testing.allocator, rows);
    try std.testing.expect(std.mem.indexOf(u8, rows[0], "80-63") != null);
}

/// The widest period count across a game's participants: zero when no
/// team carries linescore cells (the grid is then skipped outright).
pub fn maxPeriod(game: detail.GameDetail) usize {
    var n: usize = 0;
    for (game.participants) |entry| n = @max(n, entry.lines.len);
    return n;
}

/// Baseball keeps the R/H/E linescore; every other sport gets periods +
/// Total. Unknown slugs keep the baseball shape as the safe default.
pub fn isBaseball(league_slug: []const u8) bool {
    const league = core.leagues.find(league_slug) orelse return true;
    return std.mem.eql(u8, league.sport, "Baseball");
}

/// Live baseball chip: `B-S, outs, bases[. matchup]`. Wraps (never
/// truncates) at emit time; shared by text and HTML so the chip reads
/// identically in both.
pub fn situationText(allocator: std.mem.Allocator, situation: detail.Situation) ![]u8 {
    var runners: std.Io.Writer.Allocating = .init(allocator);
    defer runners.deinit();
    if (situation.runners.len == 0) {
        try runners.writer.writeAll("bases empty");
    } else {
        for (situation.runners, 0..) |base, i| {
            if (i > 0) try runners.writer.writeAll(",");
            try runners.writer.writeAll(base);
        }
    }
    const bases = try runners.toOwnedSlice();
    defer allocator.free(bases);
    const matchup = if (situation.batter != null and situation.pitcher != null)
        try std.fmt.allocPrint(allocator, " {s} vs {s}", .{ situation.pitcher.?, situation.batter.? })
    else if (situation.batter) |batter|
        try std.fmt.allocPrint(allocator, " {s} batting", .{batter})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(matchup);
    return std.fmt.allocPrint(allocator, "{d}-{d}, {d} out, {s}{s}", .{
        situation.balls,
        situation.strikes,
        situation.outs,
        bases,
        matchup,
    });
}

/// One side's lineup as `keyValueLines` items: `{order}. {pos} {name}
/// {hitting}`, split on the last space so H-AB shares a right column.
/// Shared by text and HTML.
pub fn lineupItems(allocator: std.mem.Allocator, side: detail.LineupSide) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    for (side.entries) |entry| {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{d}. {s} {s} {s}", .{ entry.order, entry.position, entry.name, entry.hitting }));
    }
    return out.toOwnedSlice(allocator);
}

/// One leaders section: column-aligned rows plus a per-row team-header
/// flag. A row whose first token is an all-caps participant abbreviation
/// (`HOU` in `HOU H-AB 10-35`) opens that team's group and renders dim;
/// following player rows inherit the team as a prefix column
/// (`HOU  Jeremy Pena  1-5`) so the team is never a guess. Sections
/// without team headers render exactly like `keyValueLines`.
pub const LeadersBlock = struct {
    lines: [][]u8,
    is_header: []bool,
};

/// Free a `LeadersBlock` built by `leadersLines`.
pub fn freeLeadersBlock(allocator: std.mem.Allocator, block: LeadersBlock) void {
    freeLines(allocator, block.lines);
    allocator.free(block.is_header);
}

/// A headed leaders group: the section heading plus its block. Free with
/// `freeLeadersSection`.
pub const LeadersSection = struct {
    heading: []u8,
    block: LeadersBlock,
};

/// Free a `LeadersSection` built by `leadersSection`.
pub fn freeLeadersSection(allocator: std.mem.Allocator, section: LeadersSection) void {
    allocator.free(section.heading);
    freeLeadersBlock(allocator, section.block);
}

/// The team a leader row opens, if its first token names a participant:
/// all-caps 2-4 characters matching an abbreviation exactly (player
/// names are title case, so they never qualify). Null for player rows
/// and for sections without team splits.
pub fn leaderHeaderTeam(label: []const u8, participants: []const detail.DetailParticipant) ?[]const u8 {
    const sp = std.mem.indexOfScalar(u8, label, ' ') orelse return null;
    const token = label[0..sp];
    if (token.len < 2 or token.len > 4) return null;
    for (token) |c| if (c < 'A' or c > 'Z') return null;
    for (participants) |p| if (std.mem.eql(u8, p.abbreviation, token)) return token;
    return null;
}

/// Optional per-row label mapping for `keyValueLines`: leaders pass
/// their team-prefix mapping, plain sections pass null and labels go
/// through verbatim. The mapper sees the row index so leaders can reuse
/// the precomputed per-row team/header tables without re-scanning.
pub const LabelPrefix = struct {
    ctx: ?*const anyopaque = null,
    map: ?*const fn (ctx: ?*const anyopaque, allocator: std.mem.Allocator, index: usize, label: []const u8) std.mem.Allocator.Error![]u8 = null,

    pub fn apply(self: LabelPrefix, allocator: std.mem.Allocator, index: usize, label: []const u8) ![]u8 {
        if (self.map) |f| return f(self.ctx, allocator, index, label);
        return allocator.dupe(u8, label);
    }
};

/// Per-row tables backing the leaders label mapping: the running team
/// per row plus which rows open a group. Borrowed for the
/// `keyValueLines` call only.
const LeaderPrefixCtx = struct {
    teams: []const ?[]const u8,
    headers: []const bool,
};

/// `leadersLines` as a `keyValueLines` label mapping: header rows keep
/// the bare label; player rows inherit the running team as a prefix
/// column (`HOU  Jeremy Pena  1-5`) so the team is never a guess.
fn leaderLabel(ctx: ?*const anyopaque, allocator: std.mem.Allocator, index: usize, label: []const u8) ![]u8 {
    const tables: *const LeaderPrefixCtx = @ptrCast(@alignCast(ctx.?));
    if (!tables.headers[index]) {
        if (tables.teams[index]) |team| return std.fmt.allocPrint(allocator, "{s}  {s}", .{ team, label });
    }
    return allocator.dupe(u8, label);
}

pub fn leadersLines(
    allocator: std.mem.Allocator,
    leaders: []const []const u8,
    participants: []const detail.DetailParticipant,
    total: usize,
) !LeadersBlock {
    var teams: std.ArrayList(?[]const u8) = .empty;
    defer teams.deinit(allocator);
    var headers: std.ArrayList(bool) = .empty;
    errdefer headers.deinit(allocator);
    var value_w: usize = 0;
    var current: ?[]const u8 = null;
    for (leaders) |item| {
        const parts = splitValue(item);
        const header = leaderHeaderTeam(parts.label, participants);
        if (header) |team| current = team;
        try teams.append(allocator, current);
        try headers.append(allocator, header != null);
        value_w = @max(value_w, table.textCells(parts.value));
    }
    const prefix = LeaderPrefixCtx{ .teams = teams.items, .headers = headers.items };
    const lines = try keyValueLines(allocator, leaders, total, LabelPrefix{ .ctx = &prefix, .map = leaderLabel });
    return .{ .lines = lines, .is_header = try headers.toOwnedSlice(allocator) };
}

/// Split a "label ... value" row at its last space: leaders
/// (`Jeremy Pena 1-5`) and team stats (`HOU Games Played 1`) align the
/// trailing value right. No space means the whole string is the label.
pub fn splitValue(s: []const u8) struct { label: []const u8, value: []const u8 } {
    const at = std.mem.lastIndexOfScalar(u8, s, ' ') orelse return .{ .label = s, .value = "" };
    return .{ .label = s[0..at], .value = s[at + 1 ..] };
}

/// Aligned key/value rows: labels left, values sharing one right column
/// (widest value wins). Value-less rows render as plain fitted lines.
/// `total` is the content width. Shared by text and HTML. `prefix`
/// optionally remaps each row label (`leadersLines` passes its
/// team-prefix mapping); null keeps labels verbatim.
pub fn keyValueLines(allocator: std.mem.Allocator, items: []const []const u8, total: usize, prefix: ?LabelPrefix) ![][]u8 {
    var value_w: usize = 0;
    for (items) |item| value_w = @max(value_w, table.textCells(splitValue(item).value));
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    for (items, 0..) |item, i| {
        const parts = splitValue(item);
        const label = if (prefix) |p| try p.apply(allocator, i, parts.label) else try allocator.dupe(u8, parts.label);
        defer allocator.free(label);
        var buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer buf.deinit();
        if (parts.value.len == 0) {
            try table.writeCell(&buf.writer, label, total, null, false);
        } else {
            try table.writeCell(&buf.writer, label, total -| value_w -| 1, null, false);
            try buf.writer.writeByte(' ');
            try table.writeCellRight(&buf.writer, parts.value, value_w, null, false);
        }
        const raw = try buf.toOwnedSlice();
        defer allocator.free(raw);
        try out.append(allocator, try allocator.dupe(u8, std.mem.trimEnd(u8, raw, " ")));
    }
    return out.toOwnedSlice(allocator);
}

/// Aligned scoring-play rows: period | running score | description, with
/// one shared period/score column per section. Score fuses the structured
/// away/home fields (`6-4`) so the text column starts together.
pub fn scoringLines(allocator: std.mem.Allocator, plays: []const detail.DetailScoringPlay, total: usize) ![][]u8 {
    var period_w: usize = 0;
    var score_w: usize = 0;
    for (plays) |play| {
        period_w = @max(period_w, table.textCells(play.period));
        score_w = @max(score_w, table.textCells(play.away_score) + 1 + table.textCells(play.home_score));
    }
    period_w = @min(period_w, 14);
    score_w = @min(score_w, 9);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    for (plays) |play| {
        const score = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ play.away_score, play.home_score });
        defer allocator.free(score);
        // Play text wraps (like situation lines) instead of truncating:
        // the period/score prefix rides the first row, continuations
        // indent to the text column. Never lose live info to an ellipsis.
        var prefix: std.Io.Writer.Allocating = .init(allocator);
        defer prefix.deinit();
        try table.writeCell(&prefix.writer, play.period, period_w, null, false);
        try prefix.writer.writeByte(' ');
        try table.writeCell(&prefix.writer, score, score_w, null, false);
        try prefix.writer.writeByte(' ');
        const head = try prefix.toOwnedSlice();
        defer allocator.free(head);
        const text_w = total -| period_w -| 1 -| score_w -| 1;
        const wrapped = try table.wrapLines(allocator, play.text, text_w);
        defer freeLines(allocator, wrapped);
        if (wrapped.len == 0) {
            try out.append(allocator, try allocator.dupe(u8, std.mem.trimEnd(u8, head, " ")));
            continue;
        }
        const indent = try allocator.alloc(u8, head.len);
        defer allocator.free(indent);
        @memset(indent, ' ');
        for (wrapped, 0..) |row, i| {
            const line = try std.fmt.allocPrint(allocator, "{s}{s}", .{ if (i == 0) head else indent, row });
            defer allocator.free(line);
            try out.append(allocator, try allocator.dupe(u8, std.mem.trimEnd(u8, line, " ")));
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Participant block rows: `ABBR name … score ✓ record`. The name flexes;
/// abbreviation, score, and record ride fixed right-ish columns so
/// multi-team blocks scan. Winner coloring wraps the whole line at emit
/// time (text) or rides a span (HTML), never inside the composer.
pub fn participantLines(allocator: std.mem.Allocator, participants: []const detail.DetailParticipant, total: usize) ![][]u8 {
    var abbr_w: usize = 0;
    var rec_w: usize = 0;
    for (participants) |p| {
        abbr_w = @max(abbr_w, table.textCells(p.abbreviation));
        if (p.record) |r| rec_w = @max(rec_w, table.textCells(r));
    }
    abbr_w = @min(abbr_w, 4);
    rec_w = @min(rec_w, 10);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    for (participants) |p| {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer buf.deinit();
        const fixed: usize = abbr_w + 2 + 3 + 2 + (if (p.record != null) rec_w + 1 else 0);
        try table.writeCell(&buf.writer, p.abbreviation, abbr_w, null, false);
        try buf.writer.writeByte(' ');
        try table.writeCell(&buf.writer, p.name, total -| fixed, null, false);
        try buf.writer.writeByte(' ');
        try table.writeCellRight(&buf.writer, p.score, 3, null, false);
        if (p.winner) try buf.writer.writeAll(" ✓") else try buf.writer.writeAll("  ");
        if (p.record) |r| {
            try buf.writer.writeByte(' ');
            try table.writeCellRight(&buf.writer, r, rec_w, null, false);
        }
        const raw = try buf.toOwnedSlice();
        defer allocator.free(raw);
        try out.append(allocator, try allocator.dupe(u8, std.mem.trimEnd(u8, raw, " ")));
    }
    return out.toOwnedSlice(allocator);
}

/// Linescore grid as plain strings: header, one row per team, then a
/// combined records line (`PHI 81-63 · HOU 73-71`, absent when no team
/// carries one). Baseball keeps periods + R/H/E; every other sport shows
/// periods + a single Total column (no H/E placeholders). The sport keys
/// off `core.leagues.find(game.league)`; an unknown slug keeps the
/// baseball shape as the safe default. One composer for text and HTML so
/// the grid can never drift between them.
pub fn lineScoreLines(allocator: std.mem.Allocator, game: detail.GameDetail) ![][]u8 {
    const baseball = isBaseball(game.league);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    const periods = maxPeriod(game);
    var head: std.Io.Writer.Allocating = .init(allocator);
    defer head.deinit();
    try head.writer.writeAll("    ");
    var p: usize = 1;
    while (p <= periods) : (p += 1) try head.writer.print("{d:>3}", .{p});
    if (baseball) {
        try head.writer.writeAll("   R   H   E");
    } else {
        try head.writer.writeAll("   Total");
    }
    try out.append(allocator, try head.toOwnedSlice());
    for (game.participants) |entry| {
        var line: std.Io.Writer.Allocating = .init(allocator);
        defer line.deinit();
        try line.writer.print("{s:<4}", .{entry.abbreviation});
        var i: usize = 0;
        while (i < periods) : (i += 1) {
            const cell: []const u8 = if (i < entry.lines.len) entry.lines[i].display else "-";
            try line.writer.print("{s:>3}", .{cell});
        }
        if (baseball) {
            try line.writer.print("   {s:>3}   {s:>3}   {s:>3}", .{
                entry.score,
                entry.hits orelse "-",
                entry.errors orelse "-",
            });
        } else {
            try line.writer.print("   {s:>5}", .{entry.score});
        }
        try out.append(allocator, try line.toOwnedSlice());
    }
    var recs: std.Io.Writer.Allocating = .init(allocator);
    defer recs.deinit();
    var first = true;
    for (game.participants) |entry| {
        const record = entry.record orelse continue;
        if (!first) try recs.writer.writeAll(" · ");
        first = false;
        try recs.writer.print("{s} {s}", .{ entry.abbreviation, record });
    }
    if (!first) try out.append(allocator, try recs.toOwnedSlice());
    return out.toOwnedSlice(allocator);
}

/// Participant block as a `Section` (no heading): winner tint rides at
/// emit time, keyed off the participants slice in order.
pub fn participantSection(
    allocator: std.mem.Allocator,
    participants: []const detail.DetailParticipant,
    total: usize,
) !Section {
    return .{ .heading = null, .rows = try participantLines(allocator, participants, total) };
}

/// Linescore grid as a `Section` (no heading): the header row renders
/// dim at emit time, team rows carry the winner tint by index.
pub fn lineScoreSection(allocator: std.mem.Allocator, game: detail.GameDetail) !Section {
    return .{ .heading = null, .rows = try lineScoreLines(allocator, game) };
}

/// Scoring plays as a `Section` headed `Scoring plays`. Height slicing
/// and the `+N more (?height=M)` trailer stay in the caller (emit
/// concern); the composer aligns whatever slice it receives.
pub fn scoringSection(
    allocator: std.mem.Allocator,
    plays: []const detail.DetailScoringPlay,
    total: usize,
) !Section {
    return .{
        .heading = try allocator.dupe(u8, "Scoring plays"),
        .rows = try scoringLines(allocator, plays, total),
    };
}

/// One lineup side as a `Section` headed `{team} {total}`.
pub fn lineupSection(allocator: std.mem.Allocator, side: detail.LineupSide, total: usize) !Section {
    const heading = try std.fmt.allocPrint(allocator, "{s} {s}", .{ side.team, side.total });
    errdefer allocator.free(heading);
    const items = try lineupItems(allocator, side);
    defer freeLines(allocator, items);
    return .{ .heading = heading, .rows = try keyValueLines(allocator, items, total, null) };
}

/// Team-stats group as a `Section` headed `Team stats`.
pub fn teamStatsSection(allocator: std.mem.Allocator, stats: []const []const u8, total: usize) !Section {
    return .{
        .heading = try allocator.dupe(u8, "Team stats"),
        .rows = try keyValueLines(allocator, stats, total, null),
    };
}

/// Leaders group as a `LeadersSection` headed `Leaders`. The caller caps
/// the slice (first 8) before composing, as before.
pub fn leadersSection(
    allocator: std.mem.Allocator,
    leaders: []const []const u8,
    participants: []const detail.DetailParticipant,
    total: usize,
) !LeadersSection {
    return .{
        .heading = try allocator.dupe(u8, "Leaders"),
        .block = try leadersLines(allocator, leaders, participants, total),
    };
}

// --- Team schedule composers: one shared geometry for Today/Last/Next overflow and the live row. ---

/// Record/standing header line (`{record}  {standing}`, each half
/// omitted when absent). Null when the team carries neither, so callers
/// skip the line outright. Shared by text and HTML.
pub fn recordStandingsLine(
    allocator: std.mem.Allocator,
    record: ?[]const u8,
    standing: ?[]const u8,
) !?[]u8 {
    if (record) |rec| {
        if (standing) |st| {
            return try std.fmt.allocPrint(allocator, "{s}  {s}", .{ rec, st });
        }
        return try std.fmt.allocPrint(allocator, "{s}", .{rec});
    } else if (standing) |st| {
        return try std.fmt.allocPrint(allocator, "{s}", .{st});
    }
    return null;
}

/// Eastern calendar day (`YYYY-MM-DD`) for a schedule instant: full UTC
/// timestamps shift to the Eastern day, date-only strings pass through.
/// Fallback (never errors): unknown shapes keep their raw prefix.
pub fn gameDay(allocator: std.mem.Allocator, iso: []const u8) ![]u8 {
    if (core.date.parseTimestampUTC(iso)) |epoch| {
        return core.date.todayInTz(allocator, epoch, core.date.etOffsetMinutes(epoch));
    }
    return allocator.dupe(u8, iso[0..@min(iso.len, 10)]);
}

/// Short date: `2026-09-08` becomes `09-08`. The year is implicit in the
/// page context.
pub fn shortDate(day: []const u8) []const u8 {
    if (day.len >= 10 and day[4] == '-' and day[7] == '-') return day[5..10];
    return day;
}

/// One game body line. Final/live results (`"L 4-5"`, `"3-2 Top 7th"`) carry
/// no opponent, so they get `"<date> <vs/at OPP> <result>"`; upcoming
/// results already read `"vs OPP 7:05 PM"`, so they get `"<date> <result>"`.
pub fn gameLine(allocator: std.mem.Allocator, game: schedule.GameRef) ![]u8 {
    // Eastern calendar day: ESPN instants are UTC, so an 8:20 PM ET kickoff
    // reads as the next UTC day without this shift (matches the ET times
    // already in `result`; `GameRef.date` itself stays a true UTC instant).
    const day = try gameDay(allocator, game.date);
    defer allocator.free(day);
    const prefix = shortDate(day);
    if (std.mem.eql(u8, game.state, "pre")) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, game.result });
    }
    const versus = if (std.mem.eql(u8, game.home_away, "away")) "at" else "vs";
    return std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ prefix, versus, game.opponent_abbrev, game.result });
}

/// Human link for one team-schedule row: `/{league}/{ET-date}/{slug}`
/// where the slug is the bare duel pair (away side first, lowercase),
/// ordered from the row's home/away flag against the viewed team's
/// abbreviation. Board order is not in hand here, so no `-N`
/// doubleheader suffix: the rare second game resolves to its first
/// (the alias default), never to a wrong day or pairing. Falls back to
/// the legacy numeric `/{league}/{id}` when either abbreviation is
/// empty (no pair exists to name). Pure string math, no fetch.
pub fn scheduleGameHref(allocator: std.mem.Allocator, league: []const u8, own_abbr: []const u8, game: schedule.GameRef) ![]u8 {
    if (own_abbr.len == 0 or game.opponent_abbrev.len == 0) {
        return std.fmt.allocPrint(allocator, "/{s}/{s}", .{ league, game.id });
    }
    const away, const home_team = if (std.mem.eql(u8, game.home_away, "away"))
        .{ own_abbr, game.opponent_abbrev }
    else
        .{ game.opponent_abbrev, own_abbr };
    const slug = try domain.duelSlug(allocator, away, home_team);
    defer allocator.free(slug);
    const day = try gameDay(allocator, game.date);
    defer allocator.free(day);
    return std.fmt.allocPrint(allocator, "/{s}/{s}/{s}", .{ league, day, slug });
}

/// Schedule line with a game pointer for linking: the base `gameLine`
/// plus the human `/{league}/{date}/{slug}` address (numeric legacy
/// fallback inside `scheduleGameHref`) so terminals can jump to the
/// game view. HTML callers link the row instead. The pointer rides the
/// same fitted line, so a hostile row wider than the frame truncates it
/// (the HTML link stays whole); real rows fit with room to spare.
pub fn gameLineFull(allocator: std.mem.Allocator, league: []const u8, own_abbr: []const u8, game: schedule.GameRef) ![]u8 {
    const base = try gameLine(allocator, game);
    defer allocator.free(base);
    if (game.id.len == 0) return allocator.dupe(u8, base);
    const href = try scheduleGameHref(allocator, league, own_abbr, game);
    defer allocator.free(href);
    return std.fmt.allocPrint(allocator, "{s}  {s}", .{ base, href });
}

/// Fit `s` to `cols` terminal cells through the shared `table.writeCell`,
/// then strip the padding: document lines breathe instead of forming a
/// box column. Color wraps the fitted bytes only; the padding is trimmed
/// ahead of the reset so the SGR span survives intact.
pub fn fitLine(allocator: std.mem.Allocator, s: []const u8, cols: usize, code: ?[]const u8, color: bool) ![]u8 {
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try table.writeCell(&cell.writer, s, cols, code, color);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    if (color and code != null and std.mem.endsWith(u8, padded, "\x1b[0m")) {
        const body = std.mem.trimEnd(u8, padded[0 .. padded.len - "\x1b[0m".len], " ");
        return std.fmt.allocPrint(allocator, "{s}\x1b[0m", .{body});
    }
    return allocator.dupe(u8, std.mem.trimEnd(u8, padded, " "));
}

/// Strip one HTML content line back to its visible text: tag runs
/// (`<a …>`, `<span …>`, `</…>`) vanish, entities unescape. Test helper
/// for the visible-text-equality batteries in `detail_view`/`team_view`:
/// text emits the composed row raw, HTML emits it escaped inside tags,
/// and both must read the same after this fold.
pub fn stripHtmlVisible(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, line, i, '>') orelse break;
            i = end + 1;
            continue;
        }
        if (line[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, line, i, ';');
            if (semi) |s| {
                const entity = line[i .. s + 1];
                if (std.mem.eql(u8, entity, "&amp;")) {
                    try out.append(allocator, '&');
                    i = s + 1;
                    continue;
                } else if (std.mem.eql(u8, entity, "&lt;")) {
                    try out.append(allocator, '<');
                    i = s + 1;
                    continue;
                } else if (std.mem.eql(u8, entity, "&gt;")) {
                    try out.append(allocator, '>');
                    i = s + 1;
                    continue;
                } else if (std.mem.eql(u8, entity, "&quot;")) {
                    try out.append(allocator, '"');
                    i = s + 1;
                    continue;
                } else if (std.mem.eql(u8, entity, "&#39;")) {
                    try out.append(allocator, '\'');
                    i = s + 1;
                    continue;
                }
            }
        }
        try out.append(allocator, line[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Visible text of a page's `<pre>` block, line for line via
/// `stripHtmlVisible`: the parity surface the text and HTML emitters must
/// agree on. Lines join with `'\n'` and no trailing newline, mirroring
/// the text bodies. Errors when the page carries no well-formed `<pre>`
/// block, so callers get the visible string (or a hard failure) instead
/// of re-deriving tag-stripping loops per view. Test helper only.
pub fn expectVisibleParity(allocator: std.mem.Allocator, page: []const u8) ![]u8 {
    const pre_open = std.mem.indexOf(u8, page, "<pre") orelse return error.TestUnexpectedResult;
    const pre_gt = std.mem.indexOfScalarPos(u8, page, pre_open, '>') orelse return error.TestUnexpectedResult;
    const pre_close = std.mem.indexOf(u8, page, "</pre>") orelse return error.TestUnexpectedResult;
    if (pre_gt >= pre_close) return error.TestUnexpectedResult;
    var visible: std.Io.Writer.Allocating = .init(allocator);
    errdefer visible.deinit();
    var raw = std.mem.splitScalar(u8, page[pre_gt + 1 .. pre_close], '\n');
    var first = true;
    while (raw.next()) |line| {
        const clean = try stripHtmlVisible(allocator, line);
        defer allocator.free(clean);
        if (!first) try visible.writer.writeByte('\n');
        first = false;
        try visible.writer.writeAll(clean);
    }
    return visible.toOwnedSlice();
}

fn hostileParticipants() [2]detail.DetailParticipant {
    return .{
        .{
            .id = "a",
            .name = "Atlético Madrid Club de Fútbol with an extremely long tail that never ends \x1b[31m",
            .abbreviation = "AWY",
            .score = "2",
            .winner = false,
            .home_away = "away",
            .lines = &.{.{ .period = 1, .display = "1" }},
            .record = "69-74\r\nx",
        },
        .{
            .id = "h",
            .name = "Home\tTeam 漢字",
            .abbreviation = "",
            .score = "",
            .winner = true,
            .home_away = "home",
            .lines = &.{.{ .period = 1, .display = "0" }},
        },
    };
}

test "composers hold width, alignment, and valid UTF-8 on hostile input" {
    const arena = std.testing.allocator;
    const parts = hostileParticipants();
    for ([2]usize{ 52, 200 }) |total| {
        const rows = try participantLines(arena, &parts, total);
        defer freeLines(arena, rows);
        try std.testing.expectEqual(@as(usize, 2), rows.len);
        for (rows) |row| {
            _ = try std.unicode.Utf8View.init(row);
            try std.testing.expect(table.textCells(row) <= total);
            try std.testing.expect(std.mem.indexOf(u8, row, "\x1b") == null);
            try std.testing.expect(std.mem.indexOf(u8, row, "\n") == null);
        }
        // Winner row keeps its check; hostile bytes never leak raw.
        try std.testing.expect(std.mem.indexOf(u8, rows[1], "✓") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows[0], "\x1b[31m") == null);

        const kv = try keyValueLines(arena, &.{ "ATL <b> & \"hits\"\t10", "no-value-row", "HOU Games Played 1" }, total, null);
        defer freeLines(arena, kv);
        try std.testing.expectEqual(@as(usize, 3), kv.len);
        for (kv) |row| {
            _ = try std.unicode.Utf8View.init(row);
            try std.testing.expect(table.textCells(row) <= total);
        }
        // Values share one right column.
        try std.testing.expect(std.mem.endsWith(u8, kv[0], "10"));
        try std.testing.expect(std.mem.endsWith(u8, kv[2], "1"));

        const plays = [_]detail.DetailScoringPlay{
            .{ .period = "1st\nInning", .text = "", .away_score = "1", .home_score = "0" },
            .{ .period = "9th Inning", .text = "Riley tripled to center, Albies scored with a very long tail that wraps 漢字.", .away_score = "5", .home_score = "4" },
        };
        const scored = try scoringLines(arena, &plays, total);
        defer freeLines(arena, scored);
        try std.testing.expect(scored.len >= 2);
        for (scored) |row| {
            _ = try std.unicode.Utf8View.init(row);
            try std.testing.expect(table.textCells(row) <= total);
            try std.testing.expect(std.mem.indexOf(u8, row, "\n") == null);
        }

        const leaders = try leadersLines(arena, &.{ "AWY H-AB 10-35", "Hostile\nPlayer 1-5", "10-35" }, &parts, total);
        defer freeLeadersBlock(arena, leaders);
        try std.testing.expectEqual(@as(usize, 3), leaders.lines.len);
        try std.testing.expect(leaders.is_header[0]);
        try std.testing.expect(!leaders.is_header[1]);
        for (leaders.lines) |row| {
            _ = try std.unicode.Utf8View.init(row);
            try std.testing.expect(table.textCells(row) <= total);
            try std.testing.expect(std.mem.indexOf(u8, row, "\n") == null);
        }

        const items = try lineupItems(arena, .{
            .team = "AWY",
            .total = "2-10",
            .entries = &.{.{ .order = 1, .position = "RF", .name = "Acuña\tJr.", .hitting = "2-3" }},
        });
        defer freeLines(arena, items);
        try std.testing.expectEqual(@as(usize, 1), items.len);
        _ = try std.unicode.Utf8View.init(items[0]);
    }
}

test "situation, linescore, and section builders agree on hostile input" {
    const arena = std.testing.allocator;
    const chip = try situationText(arena, .{
        .balls = 3,
        .strikes = 2,
        .outs = 2,
        .runners = &.{ "1st", "2nd" },
        .batter = "Yordan\nAlvarez",
        .pitcher = "Cristopher\tSanchez",
    });
    defer arena.free(chip);
    try std.testing.expectEqualStrings("3-2, 2 out, 1st,2nd Cristopher\tSanchez vs Yordan\nAlvarez", chip);

    try std.testing.expect(maxPeriod(.{
        .id = "x",
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .state = "post",
        .status = "Final",
        .participants = &hostileParticipants(),
    }) == 1);
    try std.testing.expect(isBaseball("mlb"));
    try std.testing.expect(!isBaseball("nba"));
    try std.testing.expect(isBaseball("zzz-unknown"));

    // Section builders compose color=false with owned headings; freeing
    // drops every byte (covered under `-Dtest` leaks via the allocator).
    const pseq = try participantSection(arena, &hostileParticipants(), 52);
    defer freeSection(arena, pseq);
    try std.testing.expect(pseq.heading == null);
    try std.testing.expectEqual(@as(usize, 2), pseq.rows.len);

    const sseq = try scoringSection(arena, &.{.{ .period = "1st", .text = "Run.", .away_score = "1", .home_score = "0" }}, 52);
    defer freeSection(arena, sseq);
    try std.testing.expectEqualStrings("Scoring plays", sseq.heading.?);

    const lseq = try lineupSection(arena, .{ .team = "AWY", .total = "2-10", .entries = &.{} }, 52);
    defer freeSection(arena, lseq);
    try std.testing.expectEqualStrings("AWY 2-10", lseq.heading.?);
    try std.testing.expectEqual(@as(usize, 0), lseq.rows.len);

    const tseq = try teamStatsSection(arena, &.{ "AWY At Bats 35", "HOU At Bats 33" }, 52);
    defer freeSection(arena, tseq);
    try std.testing.expectEqualStrings("Team stats", tseq.heading.?);
    try std.testing.expectEqual(@as(usize, 2), tseq.rows.len);

    const gseq = try leadersSection(arena, &.{ "AWY H-AB 10-35", "Drake Baldwin 2-4" }, &hostileParticipants(), 52);
    defer freeLeadersSection(arena, gseq);
    try std.testing.expectEqualStrings("Leaders", gseq.heading);
    try std.testing.expect(gseq.block.is_header[0]);
}

test "team composers keep record, game, and fit semantics" {
    const arena = std.testing.allocator;
    const both = try recordStandingsLine(arena, "80-63", "2nd in NL East");
    defer if (both) |b| arena.free(b);
    try std.testing.expectEqualStrings("80-63  2nd in NL East", both.?);
    const rec_only = try recordStandingsLine(arena, "80-63", null);
    defer if (rec_only) |b| arena.free(b);
    try std.testing.expectEqualStrings("80-63", rec_only.?);
    const st_only = try recordStandingsLine(arena, null, "2nd in NL East");
    defer if (st_only) |b| arena.free(b);
    try std.testing.expectEqualStrings("2nd in NL East", st_only.?);
    try std.testing.expect(try recordStandingsLine(arena, null, null) == null);

    const late: schedule.GameRef = .{
        .id = "x",
        .date = "2026-09-14T00:20Z",
        .opponent_abbrev = "NYG",
        .opponent_name = "New York Giants",
        .home_away = "away",
        .status = "9/13 - 8:20 PM EDT",
        .state = "pre",
        .result = "vs NYG 8:20 PM",
    };
    const line = try gameLine(arena, late);
    defer arena.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, "09-13 "));
    const full = try gameLineFull(arena, "nfl", "DAL", late);
    defer arena.free(full);
    try std.testing.expect(std.mem.endsWith(u8, full, "  /nfl/2026-09-13/dal-nyg"));
    const noid: schedule.GameRef = .{
        .id = "",
        .date = "2026-09-08",
        .opponent_abbrev = "NYG",
        .opponent_name = "New York Giants",
        .home_away = "home",
        .status = "Final",
        .state = "post",
        .result = "W 5-3",
    };
    const bare = try gameLineFull(arena, "nfl", "DAL", noid);
    defer arena.free(bare);
    try std.testing.expectEqualStrings("09-08 vs NYG W 5-3", bare);
    // No opponent abbreviation (nameless bouts): the numeric address.
    const nameless: schedule.GameRef = .{
        .id = "bout-9",
        .date = "2026-09-06T23:00Z",
        .opponent_abbrev = "",
        .opponent_name = "",
        .home_away = "",
        .status = "Scheduled",
        .state = "pre",
        .result = "vs TBD",
    };
    const fallback = try scheduleGameHref(arena, "ufc", "", nameless);
    defer arena.free(fallback);
    try std.testing.expectEqualStrings("/ufc/bout-9", fallback);
    // Home side lists second: the opponent opens the pair.
    const homer = try scheduleGameHref(arena, "mlb", "PHI", .{
        .id = "9",
        .date = "2026-09-06T17:00Z",
        .opponent_abbrev = "NYM",
        .opponent_name = "New York Mets",
        .home_away = "home",
        .status = "Final",
        .state = "post",
        .result = "W 5-3",
    });
    defer arena.free(homer);
    try std.testing.expectEqualStrings("/mlb/2026-09-06/nym-phi", homer);

    const fitted = try fitLine(arena, "Short line", 52, null, false);
    defer arena.free(fitted);
    try std.testing.expectEqualStrings("Short line", fitted);
    const wide = try fitLine(arena, "Atlético Madrid Club de Fútbol with a very long tail indeed and more", 12, null, false);
    defer arena.free(wide);
    _ = try std.unicode.Utf8View.init(wide);
    try std.testing.expect(table.textCells(wide) <= 12);

    try std.testing.expectEqualStrings("09-08", shortDate("2026-09-08"));
    try std.testing.expectEqualStrings("raw", shortDate("raw"));
    const day = try gameDay(arena, "2026-09-08");
    defer arena.free(day);
    try std.testing.expectEqualStrings("2026-09-08", day);

    const vis = try stripHtmlVisible(arena, "<a href=\"/mlb/x\">A &amp; B &lt;ace&gt;</a>");
    defer arena.free(vis);
    try std.testing.expectEqualStrings("A & B <ace>", vis);
}

// --- Scoreboard/home/digest composers: row strings behind the scoreboard,
// home, and digest sections. Renderers own emit; composers stay plain
// (`color = false`) so text and HTML can never drift. ---

/// True when the board carries at least one game and every game is final
/// (`state == "post"`): nothing live, nothing scheduled. Scoreboard
/// composers render these boards as compact home-summary rows; any other
/// board (a live/scheduled game anywhere, or no games at all) keeps the
/// rich card form.
pub fn boardIsAllFinal(board: domain.Scoreboard) bool {
    if (board.games.len == 0) return false;
    for (board.games) |game| {
        if (!std.mem.eql(u8, game.state, "post")) return false;
    }
    return true;
}

/// Scoreboard heading: `{League}  {date} {zone}`. Shared by text and
/// HTML (via the text body the linkifier post-passes).
/// Kept out of the one-line `?0` renderers, which stay bare by design.
pub fn scoreboardHeading(
    allocator: std.mem.Allocator,
    league_name: []const u8,
    date: []const u8,
    zone_tag: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}  {s} {s}", .{ league_name, date, zone_tag });
}

/// Plain-text pointer under each scoreboard game: the canonical human
/// address (`/{league}/{date}/{slug}` — duel pair or `event-N`), falling
/// back to the legacy numeric `/{league}/{id}` when the game carries no
/// stamped slug, plus the first participant's team pointer (empty when
/// the game has none). The HTML renderer turns the status row into a
/// real link instead.
pub fn scoreGameLink(
    allocator: std.mem.Allocator,
    league: []const u8,
    board_date: []const u8,
    game: domain.Game,
) ![]u8 {
    const target = try domain.gameHref(allocator, league, board_date, game);
    defer allocator.free(target);
    const first_abbr = if (game.participants.len > 0) game.participants[0].abbreviation else "";
    if (first_abbr.len == 0) return std.fmt.allocPrint(allocator, "game: {s}", .{target});
    return std.fmt.allocPrint(allocator, "game: {s}   team: /{s}/{s}", .{ target, league, first_abbr });
}

/// One scoreboard participant row, column-aligned like the old table
/// interior (abbr, name, score, winner tick, record) but borderless and
/// unpadded. Winner coloring wraps at emit time, never inside.
pub fn scoreParticipantLine(allocator: std.mem.Allocator, p: domain.Participant, cols: usize) ![]u8 {
    var rec_w: usize = 0;
    if (p.record) |r| rec_w = table.textCells(r);
    rec_w = @min(rec_w, 10);
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const b = &buf.writer;
    if (p.abbreviation.len > 0) {
        try table.writeCell(b, p.abbreviation, 4, null, false);
        try b.writeByte(' ');
        try table.writeCell(b, p.name, cols -| 4 -| 2 -| 4 -| 2 -| (if (p.record != null) rec_w + 3 else 0), null, false);
    } else {
        // Athlete identities carry no abbreviation: the name absorbs it.
        try table.writeCell(b, p.name, cols -| 7 -| (if (p.record != null) rec_w + 3 else 0), null, false);
    }
    try b.writeByte(' ');
    try table.writeCellRight(b, p.score, 4, null, false);
    if (p.record) |r| {
        try b.writeAll(" (");
        try table.writeCell(b, r, rec_w, null, false);
        try b.writeByte(')');
    }
    if (p.winner) try b.writeAll(" ✓") else try b.writeAll("  ");
    const raw = try buf.toOwnedSlice();
    defer allocator.free(raw);
    return allocator.dupe(u8, std.mem.trimEnd(u8, raw, " "));
}

/// ANSI role for a game state: live games glow red, upcoming games read
/// yellow, finished games stay plain. The HTML twin is `statusCssClass`.
pub fn statusAnsi(state: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, state, "in")) return "1;31";
    if (std.mem.eql(u8, state, "pre")) return "33";
    return null;
}

/// CSS class matching the ANSI role for a game state: live games glow
/// red, upcoming games read yellow, finished games stay plain.
pub fn statusCssClass(state: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, state, "in")) return "live";
    if (std.mem.eql(u8, state, "pre")) return "upcoming";
    return null;
}

/// Page-wide home column widths so league, team, and score columns align
/// down the whole page: widest slug/abbreviation among leagues with
/// shown games (idle-league rows keep their own fixed cells). Floors
/// keep narrow days compact; caps bound exotic abbreviations. Takes a
/// slice of `LeagueResult`-shaped entries (`{ .league.slug,
/// .board.?games }`); the element stays generic so this module stays
/// provider-neutral.
pub fn homeColumnWidths(comptime T: type, boards: []const T) struct { slug_w: usize, abbr_w: usize } {
    var slug_w: usize = 3;
    var abbr_w: usize = 2;
    for (boards) |result| {
        const board = result.board orelse continue;
        if (board.games.len == 0) continue;
        slug_w = @max(slug_w, table.textCells(result.league.slug));
        for (board.games) |game| {
            for (game.participants) |p| abbr_w = @max(abbr_w, table.textCells(p.abbreviation));
        }
    }
    return .{ .slug_w = @min(slug_w, 10), .abbr_w = @min(abbr_w, 5) };
}

/// Page-wide compact widths for one all-final scoreboard: same floors
/// (slug 3, abbr 2), measuring (`table.textCells`), and caps (10, 5) as
/// `homeColumnWidths`, but over the board's own games with the board slug
/// as the only league head. Keeps the summary rows in the same columns
/// as the home rows.
pub const CompactWidths = struct { slug_w: usize, abbr_w: usize };

pub fn scoreboardCompactWidths(board: domain.Scoreboard) CompactWidths {
    var slug_w: usize = 3;
    var abbr_w: usize = 2;
    if (board.games.len > 0) {
        slug_w = @max(slug_w, table.textCells(board.league));
        for (board.games) |game| {
            for (game.participants) |p| abbr_w = @max(abbr_w, table.textCells(p.abbreviation));
        }
    }
    return .{ .slug_w = @min(slug_w, 10), .abbr_w = @min(abbr_w, 5) };
}

/// Home league section header: `{name}  {M/D}` (the year is implicit in
/// the page heading). Whole line links to the league page at emit time.
pub fn homeLeagueHeader(allocator: std.mem.Allocator, name: []const u8, day: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}  {s}", .{ name, shortDate(day) });
}

/// Middle slot for a home duel line: fixed score columns (both sides
/// grid-aligned), single-abbr sides (`CLE 9 v BAL 5`, UFC-style), or
/// bare names (`Away v Home`). The slug head, winner tick, and
/// `homeGameTail` tail stay shared in `homeDuelLine`.
const HomeDuelMiddle = enum {
    columns,
    sides,
    names,
};

/// Shared composer for the four home duel lines: one slug head, one
/// winner tick, one `homeGameTail` tail — only the middle varies, so
/// the branches can never drift row by row.
fn homeDuelLine(
    allocator: std.mem.Allocator,
    league: *const core.leagues.League,
    away: domain.Participant,
    home_team: domain.Participant,
    date: []const u8,
    rest: []const u8,
    slug_w: usize,
    abbr_w: usize,
    middle: HomeDuelMiddle,
) ![]u8 {
    // Winner tick rides a fixed 2-cell column so scores align whether
    // or not the game is decided yet.
    const mark: []const u8 = if (away.winner or home_team.winner) " ✓" else "  ";
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const b = &buf.writer;
    try table.writeCell(b, league.slug, slug_w, null, false);
    try b.writeByte(' ');
    switch (middle) {
        .columns => {
            // Column duel: sides, scores, tick, then the date word
            // (if any) and the status tail. Callers fit to the frame.
            try table.writeCell(b, away.abbreviation, abbr_w, null, false);
            try b.writeByte(' ');
            try table.writeCellRight(b, away.score, 3, null, false);
            try b.writeAll(" @ ");
            try table.writeCell(b, home_team.abbreviation, abbr_w, null, false);
            try b.writeByte(' ');
            try table.writeCellRight(b, home_team.score, 3, null, false);
            try b.writeAll(mark);
        },
        .sides => {
            const away_side = try homeSideText(allocator, away);
            defer allocator.free(away_side);
            const home_side = try homeSideText(allocator, home_team);
            defer allocator.free(home_side);
            if (away_side.len > 0 and home_side.len > 0) {
                try b.writeAll(away_side);
                try b.writeAll(" v ");
                try b.writeAll(home_side);
            } else {
                const side = if (away_side.len > 0) away_side else home_side;
                try b.writeAll(side);
            }
            try b.writeAll(mark);
        },
        .names => {
            try b.writeAll(away.name);
            try b.writeAll(" v ");
            try b.writeAll(home_team.name);
            try b.writeAll(mark);
        },
    }
    try homeGameTail(allocator, b, date, rest);
    return try buf.toOwnedSlice();
}

/// Compact home one-liner per game, column-aligned across the page:
/// leagues, teams, and scores share fixed columns so days scan
/// vertically; only the trailing status is ragged.
/// `mlb  CLE   9 @ BAL   5 ✓  Bot 7th`. `slug_w`/`abbr_w` are page-wide
/// maxima (see `homeColumnWidths`). A two-participant game always reads
/// as a duel: team sides are `{abbr} {score}`; athlete sides (empty
/// abbreviation, e.g. UFC) read as bare names joined with ` v `.
/// Records stay out: they would drown the line
/// (`ufc  Name 9-0-0` reads like a score). Non-duels fall back to the
/// game name. Returns null for nothing to show.
pub fn homeGameLine(allocator: std.mem.Allocator, league: *const core.leagues.League, game: domain.Game, slug_w: usize, abbr_w: usize) !?[]u8 {
    if (game.participants.len == 2) {
        const first = game.participants[0];
        const second = game.participants[1];
        const away, const home_team = if (std.mem.eql(u8, second.home_away orelse "", "home"))
            .{ first, second }
        else if (std.mem.eql(u8, first.home_away orelse "", "home"))
            .{ second, first }
        else
            .{ first, second };
        const date_part = homeSplitStatus(homeShortStatus(game.status));
        // The four duel middles (column duel, single-abbr sides, bare
        // names, score-only columns) share one composer; only the middle
        // slot varies. Anything emptier falls to the bare tail below.
        const middle: ?HomeDuelMiddle = if (away.abbreviation.len > 0 and home_team.abbreviation.len > 0)
            .columns
        else if (away.abbreviation.len > 0 or home_team.abbreviation.len > 0)
            .sides
        else if (away.name.len > 0 or home_team.name.len > 0)
            .names
        else if (away.score.len > 0 or home_team.score.len > 0)
            .columns
        else
            null;
        if (middle) |m| {
            return try homeDuelLine(allocator, league, away, home_team, date_part.date, date_part.rest, slug_w, abbr_w, m);
        }
        var tail_buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer tail_buf.deinit();
        try table.writeCell(&tail_buf.writer, league.slug, slug_w, null, false);
        try tail_buf.writer.writeByte(' ');
        try tail_buf.writer.writeAll(away.abbreviation);
        try tail_buf.writer.writeAll(" @ ");
        try tail_buf.writer.writeAll(home_team.abbreviation);
        try tail_buf.writer.writeAll("  ");
        const tail_part = homeSplitStatus(homeShortStatus(game.status));
        const tail_date = tail_part.date;
        const tail_rest = tail_part.rest;
        try table.writeCell(&tail_buf.writer, tail_date, 5, null, false);
        try tail_buf.writer.writeAll(tail_rest);
        return try tail_buf.toOwnedSlice();
    }
    if (game.participants.len == 0 and game.name.len == 0) return null;
    var name_buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer name_buf.deinit();
    try table.writeCell(&name_buf.writer, league.slug, slug_w, null, false);
    try name_buf.writer.writeByte(' ');
    try name_buf.writer.writeAll(game.name);
    try name_buf.writer.writeAll("  ");
    const name_part = homeSplitStatus(homeShortStatus(game.status));
    const name_date = name_part.date;
    const name_rest = name_part.rest;
    try table.writeCell(&name_buf.writer, name_date, 5, null, false);
    try name_buf.writer.writeAll(name_rest);
    return try name_buf.toOwnedSlice();
}

/// Split a home status into its leading date word and the tail: `9/9 -
/// 8:20 PM EDT` becomes date `9/9` + `8:20 PM EDT`; anything else
/// (`Final`, `Bot 7th`, `Scheduled`) has no date word. The date column
/// aligns kickoff times down the page.
pub fn homeSplitStatus(status: []const u8) struct { date: []const u8, rest: []const u8 } {
    var i: usize = 0;
    while (i < status.len and status[i] >= '0' and status[i] <= '9') : (i += 1) {}
    var j = i;
    if (j < status.len and (status[j] == '/' or status[j] == '-')) {
        j += 1;
        const k = j;
        while (j < status.len and status[j] >= '0' and status[j] <= '9') : (j += 1) {}
        if (j > k and j + 2 < status.len and status[j] == ' ' and status[j + 1] == '-' and status[j + 2] == ' ') {
            return .{ .date = status[0..j], .rest = status[j + 3 ..] };
        }
    }
    return .{ .date = "", .rest = status };
}

/// Shared tail for home game lines: two spaces, the date word in its
/// fixed column, then the status tail. Keeps every `homeGameLine` branch
/// in the same rhythm without repeating the separators.
pub fn homeGameTail(allocator: std.mem.Allocator, w: *std.Io.Writer, date: []const u8, rest: []const u8) !void {
    try w.writeAll("  ");
    try table.writeCell(w, date, 5, null, false);
    const norm = try tz.normalizeEastern(allocator, rest);
    defer allocator.free(norm);
    try w.writeAll(norm);
}

/// Short status: strip a leading `YYYY-` year prefix (`2026-09-08`
/// becomes `09-08`) so home lines stay compact. The year is implicit
/// in the page heading; anything not shaped like a date passes through.
pub fn homeShortStatus(status: []const u8) []const u8 {
    if (status.len >= 5 and status[4] == '-' and status[0] >= '0' and status[0] <= '9') {
        var i: usize = 0;
        while (i + 4 < status.len and status[i] >= '0' and status[i] <= '9' and status[i + 4] == '-') i += 1;
        if (i >= 4) return status[5..];
    }
    return status;
}

/// One side of a home duel: `{abbr} {score}`, falling back to the full
/// name when the abbreviation is missing (UFC-style bouts). Records stay
/// out: they would drown the line (`ufc  Name 9-0-0` reads like a
/// score). An abbr side always duels; a fully empty side collapses so
/// a lone named side never prints a bare `@` opponent.
pub fn homeSideText(allocator: std.mem.Allocator, p: domain.Participant) ![]u8 {
    if (p.abbreviation.len > 0 and p.score.len > 0) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ p.abbreviation, p.score });
    }
    if (p.abbreviation.len > 0) return allocator.dupe(u8, p.abbreviation);
    if (p.name.len > 0) return std.fmt.allocPrint(allocator, "@{s}", .{p.name});
    if (p.score.len > 0) return allocator.dupe(u8, p.score);
    return allocator.dupe(u8, "");
}

/// Digest heading: `sprts all  {date} {zone}`. Shared by text and HTML
/// (via the text body the digest page escapes).
pub fn digestHeading(allocator: std.mem.Allocator, day: []const u8, zone_tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "sprts all  {s} {s}", .{ day, zone_tag });
}

/// Digest outage marker for a league whose upstream fetch failed: the
/// degraded row its section leaves behind. Answered-but-empty boards
/// (off-day) never reach this composer — dated views skip them.
pub fn digestUnavailable(allocator: std.mem.Allocator, slug: []const u8, day: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/{s}?date={s}: unavailable", .{ slug, day });
}

test "scoreboard composers hold width and hostile input" {
    const arena = std.testing.allocator;
    const heading = try scoreboardHeading(arena, "MLB", "2026-09-06", "ET");
    defer arena.free(heading);
    try std.testing.expectEqualStrings("MLB  2026-09-06 ET", heading);
    const link = try scoreGameLink(arena, "mlb", "2026-09-06", .{
        .id = "9",
        .name = "",
        .starts_at = "",
        .state = "post",
        .status = "Final",
        .slug = "phi-nym",
        .participants = &.{
            .{ .id = "a", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = true },
        },
    });
    defer arena.free(link);
    try std.testing.expectEqualStrings("game: /mlb/2026-09-06/phi-nym   team: /mlb/PHI", link);
    // Unstamped games (hand-built boards) keep the legacy numeric pointer.
    const bare = try scoreGameLink(arena, "mlb", "2026-09-06", .{
        .id = "9",
        .name = "",
        .starts_at = "",
        .state = "post",
        .status = "Final",
        .participants = &.{},
    });
    defer arena.free(bare);
    try std.testing.expectEqualStrings("game: /mlb/9", bare);
    try std.testing.expectEqualStrings("1;31", statusAnsi("in") orelse "");
    try std.testing.expectEqualStrings("33", statusAnsi("pre") orelse "");
    try std.testing.expect(statusAnsi("post") == null);
    try std.testing.expectEqualStrings("live", statusCssClass("in") orelse "");
    try std.testing.expectEqualStrings("upcoming", statusCssClass("pre") orelse "");
    try std.testing.expect(statusCssClass("post") == null);
    const hostile: domain.Participant = .{
        .id = "a",
        .name = "Atlético Madrid Club de Fútbol with an extremely long tail that never ends \x1b[31m",
        .abbreviation = "AWY",
        .score = "2",
        .winner = false,
        .record = "69-74\r\nx",
    };
    for ([2]usize{ 52, 200 }) |cols| {
        const row = try scoreParticipantLine(arena, hostile, cols);
        defer arena.free(row);
        _ = try std.unicode.Utf8View.init(row);
        try std.testing.expect(table.textCells(row) <= cols);
        try std.testing.expect(std.mem.indexOf(u8, row, "\x1b") == null);
        try std.testing.expect(std.mem.indexOf(u8, row, "\n") == null);
        try std.testing.expect(std.mem.indexOf(u8, row, "(69-74") != null);
    }
    const athlete: domain.Participant = .{ .id = "x", .name = "Charles Leclerc", .abbreviation = "", .score = "#1", .winner = true };
    const arow = try scoreParticipantLine(arena, athlete, 52);
    defer arena.free(arow);
    try std.testing.expect(std.mem.indexOf(u8, arow, "Charles Leclerc") != null);
    try std.testing.expect(std.mem.indexOf(u8, arow, "✓") != null);
    _ = try std.unicode.Utf8View.init(arow);
}

test "home composers keep duel, athlete, and header semantics" {
    const arena = std.testing.allocator;
    const mlb = core.leagues.find("mlb").?;
    const ufc = core.leagues.find("ufc").?;
    const duel: domain.Game = .{
        .id = "1",
        .name = "Away at Home",
        .starts_at = "2026-09-06T17:00Z",
        .state = "in",
        .status = "Bot 7th",
        .participants = &.{
            .{ .id = "a", .name = "Cleveland Guardians", .abbreviation = "CLE", .score = "9", .winner = false, .home_away = "away" },
            .{ .id = "h", .name = "Baltimore Orioles", .abbreviation = "BAL", .score = "5", .winner = false, .home_away = "home" },
        },
    };
    const line = try homeGameLine(arena, mlb, duel, 3, 3);
    defer if (line) |l| arena.free(l);
    try std.testing.expect(std.mem.indexOf(u8, line.?, "mlb CLE   9 @ BAL   5") != null);
    try std.testing.expect(std.mem.indexOf(u8, line.?, "Bot 7th") != null);
    const bout: domain.Game = .{
        .id = "9",
        .name = "Contender Series",
        .starts_at = "2026-09-06T23:00Z",
        .state = "pre",
        .status = "9/8 - 7:00 PM EDT",
        .participants = &.{
            .{ .id = "x", .name = "Colton Loud", .abbreviation = "", .score = "", .winner = false },
            .{ .id = "y", .name = "Christian Natividad", .abbreviation = "", .score = "", .winner = false },
        },
    };
    const aline = try homeGameLine(arena, ufc, bout, 3, 3);
    defer if (aline) |l| arena.free(l);
    try std.testing.expect(std.mem.indexOf(u8, aline.?, " v ") != null);
    try std.testing.expect(std.mem.indexOf(u8, aline.?, "2026") == null);
    const empty: domain.Game = .{ .id = "", .name = "", .starts_at = "", .state = "pre", .status = "", .participants = &.{} };
    try std.testing.expect(try homeGameLine(arena, mlb, empty, 3, 3) == null);
    const header = try homeLeagueHeader(arena, "Major League Baseball", "2026-09-06");
    defer arena.free(header);
    try std.testing.expectEqualStrings("Major League Baseball  09-06", header);
    try std.testing.expectEqualStrings("2026-09-08", homeShortStatus("2026-09-08"));
    try std.testing.expectEqualStrings("Final", homeShortStatus("Final"));
    const split = homeSplitStatus("9/9 - 8:20 PM EDT");
    try std.testing.expectEqualStrings("9/9", split.date);
    const norm_rest = try tz.normalizeEastern(arena, split.rest);
    defer arena.free(norm_rest);
    try std.testing.expectEqualStrings("8:20 PM ET", norm_rest);
    const dhead = try digestHeading(arena, "2026-09-06", "ET");
    defer arena.free(dhead);
    try std.testing.expectEqualStrings("sprts all  2026-09-06 ET", dhead);
    const down = try digestUnavailable(arena, "nfl", "2026-09-06");
    defer arena.free(down);
    try std.testing.expectEqualStrings("/nfl?date=2026-09-06: unavailable", down);
    _ = try std.unicode.Utf8View.init(line.?);
    _ = try std.unicode.Utf8View.init(aline.?);
}

test "all-final predicate and compact widths" {
    const arena = std.testing.allocator;
    const final_game: domain.Game = .{
        .id = "1",
        .name = "",
        .starts_at = "2026-09-06T17:00Z",
        .state = "post",
        .status = "Final",
        .participants = &.{
            .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
            .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
        },
    };
    const live_game: domain.Game = .{
        .id = "2",
        .name = "",
        .starts_at = "2026-09-06T19:00Z",
        .state = "in",
        .status = "Top 7th",
        .participants = &.{
            .{ .id = "c", .name = "Second", .abbreviation = "SEC", .score = "0", .winner = false },
            .{ .id = "d", .name = "Third", .abbreviation = "THI", .score = "3", .winner = false },
        },
    };
    const all_final: domain.Scoreboard = .{ .league = "mlb", .league_name = "MLB", .date = "2026-09-06", .source = "test", .games = &.{final_game} };
    try std.testing.expect(boardIsAllFinal(all_final));
    const mixed: domain.Scoreboard = .{ .league = "mlb", .league_name = "MLB", .date = "2026-09-06", .source = "test", .games = &.{ final_game, live_game } };
    try std.testing.expect(!boardIsAllFinal(mixed));
    const empty: domain.Scoreboard = .{ .league = "mlb", .league_name = "MLB", .date = "2026-09-06", .source = "test", .games = &.{} };
    try std.testing.expect(!boardIsAllFinal(empty));
    // Widths mirror the home floors/caps over the board's own games.
    const widths = scoreboardCompactWidths(all_final);
    try std.testing.expectEqual(@as(usize, 3), widths.slug_w);
    try std.testing.expectEqual(@as(usize, 3), widths.abbr_w);
    const wide_widths = scoreboardCompactWidths(empty);
    try std.testing.expectEqual(@as(usize, 3), wide_widths.slug_w);
    try std.testing.expectEqual(@as(usize, 2), wide_widths.abbr_w);
    // The compact row composes through the home duel line.
    const mlb = core.leagues.find("mlb").?;
    const row = try homeGameLine(arena, mlb, final_game, widths.slug_w, widths.abbr_w);
    defer if (row) |r| arena.free(r);
    try std.testing.expect(std.mem.indexOf(u8, row.?, "mlb AWY   2 @ HME   5") != null);
    try std.testing.expect(std.mem.indexOf(u8, row.?, "Final") != null);
}
