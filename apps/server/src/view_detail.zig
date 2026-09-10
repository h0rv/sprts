//! Shared view-layer section composers for the pipe-less document views
//! (game detail, team): the ONE place that turns provider data into
//! fitted, column-aligned row strings over the `table.zig` primitives.
//!
//! Shape: every composer builds rows with color disabled; color, links,
//! and headings ride at emit time in `detail_view` / `team_view`, so text
//! and HTML can never drift. A headed group is a `Section`
//! (`{ heading, rows }`); leader groups keep their per-row team-header
//! flags in a `LeadersBlock` / `LeadersSection` instead.
//!
//! `table.zig` owns cells, fitting, and sanitization; this module owns
//! column geometry (which column flexes, which shares a right edge).
//! Renderers own emit (ANSI spans, `<a>`/`<span>` wrapping, blank-line
//! breathing, overflow trailers, `?height` slicing).

const std = @import("std");
const core = @import("sprts_core");
const detail = core.detail;
const schedule = core.schedule;
const table = @import("table.zig");

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

pub fn leadersLines(
    allocator: std.mem.Allocator,
    leaders: []const []const u8,
    participants: []const detail.DetailParticipant,
    total: usize,
) !LeadersBlock {
    var teams: std.ArrayList(?[]const u8) = .empty;
    defer teams.deinit(allocator);
    var value_w: usize = 0;
    var current: ?[]const u8 = null;
    for (leaders) |item| {
        const parts = splitValue(item);
        if (leaderHeaderTeam(parts.label, participants)) |team| current = team;
        try teams.append(allocator, current);
        value_w = @max(value_w, table.textCells(parts.value));
    }
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    var headers: std.ArrayList(bool) = .empty;
    errdefer headers.deinit(allocator);
    for (leaders, teams.items) |item, team| {
        const parts = splitValue(item);
        const header = leaderHeaderTeam(parts.label, participants) != null;
        const label = if (!header and team != null)
            try std.fmt.allocPrint(allocator, "{s}  {s}", .{ team.?, parts.label })
        else
            try allocator.dupe(u8, parts.label);
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
        try headers.append(allocator, header);
    }
    return .{ .lines = try out.toOwnedSlice(allocator), .is_header = try headers.toOwnedSlice(allocator) };
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
/// `total` is the content width. Shared by text and HTML.
pub fn keyValueLines(allocator: std.mem.Allocator, items: []const []const u8, total: usize) ![][]u8 {
    var value_w: usize = 0;
    for (items) |item| value_w = @max(value_w, table.textCells(splitValue(item).value));
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }
    for (items) |item| {
        const parts = splitValue(item);
        var buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer buf.deinit();
        if (parts.value.len == 0) {
            try table.writeCell(&buf.writer, parts.label, total, null, false);
        } else {
            try table.writeCell(&buf.writer, parts.label, total -| value_w -| 1, null, false);
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
    return .{ .heading = heading, .rows = try keyValueLines(allocator, items, total) };
}

/// Team-stats group as a `Section` headed `Team stats`.
pub fn teamStatsSection(allocator: std.mem.Allocator, stats: []const []const u8, total: usize) !Section {
    return .{
        .heading = try allocator.dupe(u8, "Team stats"),
        .rows = try keyValueLines(allocator, stats, total),
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

// --- Team schedule composers (same shapes): record/standing lines,
// game rows, and the fit-then-trim document line. Moved here from
// `team_view` so Today/Last/Next overflow and the live row share one
// geometry with the detail sections above. ---

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

/// Schedule line with a game pointer for linking: the base `gameLine`
/// plus `  /{league}/{id}` so terminals can jump to the game view.
/// HTML callers link the row instead.
pub fn gameLineFull(allocator: std.mem.Allocator, league: []const u8, game: schedule.GameRef) ![]u8 {
    const base = try gameLine(allocator, game);
    defer allocator.free(base);
    if (game.id.len == 0) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "{s}  /{s}/{s}", .{ base, league, game.id });
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

        const kv = try keyValueLines(arena, &.{ "ATL <b> & \"hits\"\t10", "no-value-row", "HOU Games Played 1" }, total);
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
    const full = try gameLineFull(arena, "nfl", late);
    defer arena.free(full);
    try std.testing.expect(std.mem.endsWith(u8, full, "  /nfl/x"));
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
    const bare = try gameLineFull(arena, "nfl", noid);
    defer arena.free(bare);
    try std.testing.expectEqualStrings("09-08 vs NYG W 5-3", bare);

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
