const std = @import("std");
const core = @import("sprts_core");
const z = @import("zchema");
const domain = core.domain;
const leagues = core.leagues;
const dates = core.date;
const router = @import("router.zig");
const provider = @import("provider.zig");
const table = @import("table.zig");
const tz = @import("tz.zig");

/// Box-table surface, re-exported from the shared `table` module so views
/// that reached these through `render` (e.g. `team_view`) keep compiling
/// during the migration. New code should import `table.zig` directly.
pub const Rule = table.Rule;
pub const Table = table.Table;
pub const writeCell = table.writeCell;
pub const writeCellRight = table.writeCellRight;
pub const writeRow = table.writeRow;
pub const writeRule = table.writeRule;
pub const fit = table.fit;
pub const countCells = table.countCells;
pub const writeArtRow = table.writeArtRow;
pub const writeGameMarks = table.writeGameMarks;

/// Classic box: 52 terminal columns, 50 between the borders.
const default_inner_width = 50;

/// Shared JSON response gate for every JSON renderer in this binary
/// (`render.json`, `render.leaguesJson`, `detail_view.json`,
/// `team_view.renderJson`).
///
/// Strict `z.serializeAndValidate` cannot be used here: zchema's
/// `cachedCompiled` keys its compiled-schema cache on a `Holder` struct
/// that ignores the generic parameter, so the first type validated in a
/// process wins and every later type validates against the wrong schema
/// (verified: validating `Scoreboard` first makes a strict `GameDetail`
/// check fail with `ResponseValidationFailed`). zchema is an external
/// dependency (root `build.zig.zon`), not vendored, so the cache key
/// cannot be fixed in place; the coordinator owns the upstream fix.
///
/// Until then all renderers validate the same weaker way: serialize with
/// `std.json` and parse back into `T` in scratch memory. Zig types plus
/// required fields are still enforced, so a normalization bug still
/// surfaces instead of silently shipping invalid JSON; JSON Schema
/// constraints (`additionalProperties`, `format`) are not. Validation
/// scratch lives in a temporary arena so `std.testing.allocator` tests
/// don't leak. Field names on the wire are untouched: rendering changes
/// never alter JSON field names.
pub fn validatedJson(comptime T: type, allocator: std.mem.Allocator, value: T) ![]u8 {
    {
        var tmp = std.heap.ArenaAllocator.init(allocator);
        defer tmp.deinit();
        const raw = try std.json.Stringify.valueAlloc(tmp.allocator(), value, .{});
        _ = try std.json.parseFromSliceLeaky(T, tmp.allocator(), raw, .{});
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn json(allocator: std.mem.Allocator, board: domain.Scoreboard) ![]u8 {
    return validatedJson(domain.Scoreboard, allocator, board);
}

/// `width` is total terminal columns of the document (no frame takes
/// space). Never shrinks below the classic 52-wide page; extra room
/// stretches names. `height` caps the games listed (`+N more` trailer);
/// null/0 = all. The heading names its zone (`MLB  2026-09-06 ET`) so
/// output never silently disagrees with ESPN by a day; explicit `?date`
/// boards carry the request zone the same way.
///
/// Pipe-less by design like the detail and team pages: heading, games
/// separated by rules, blank air before the footer nav. Columns align
/// left; rows are ragged, never padded.
pub fn textWithZone(allocator: std.mem.Allocator, board: domain.Scoreboard, color: bool, width: ?u16, height: ?u16, zone: tz.Zone) ![]u8 {
    const cols: usize = @min(@max(width orelse 52, 52), 200);
    const shown: usize = @min(height orelse board.games.len, board.games.len);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const tag = try tz.zoneTag(allocator, zone);
    defer allocator.free(tag);
    const heading = try std.fmt.allocPrint(allocator, "{s}  {s} {s}", .{ board.league_name, board.date, tag });
    defer allocator.free(heading);
    try table.writeLine(w, heading, cols, "2", color);
    try table.writeSeparator(w, cols);
    if (board.games.len == 0) {
        try table.writeLine(w, "No games scheduled.", cols, null, color);
    }
    for (board.games[0..shown]) |game| {
        try table.writeLine(w, game.status, cols, statusColor(game.state), color);
        if (game.participants.len == 0) {
            try table.writeLine(w, game.name, cols, null, color);
        }
        for (game.participants) |participant| {
            const line = try scoreParticipantLine(allocator, participant, cols);
            defer allocator.free(line);
            if (color and participant.winner) try w.writeAll("\x1b[32m");
            try w.writeAll(line);
            if (color and participant.winner) try w.writeAll("\x1b[0m");
            try w.writeByte('\n');
        }
        try writeGameMarks(w, allocator, board.league, &game, cols, color);
        // Plain-text pointer to the game view; the HTML renderer turns
        // the status row into a real link instead (see scoreHtml).
        {
            const game_link = try std.fmt.allocPrint(allocator, "game: /{s}/{s}   team: /{s}/{s}", .{
                board.league,                                                             game.id, board.league,
                if (game.participants.len > 0) game.participants[0].abbreviation else "",
            });
            defer allocator.free(game_link);
            try table.writeLine(w, game_link, cols, "2", color);
        }
        // Separator rule closes each game block: the HTML linkifier keys
        // status rows off it, and it gives dense days a quiet rhythm.
        try table.writeSeparator(w, cols);
    }
    if (shown < board.games.len) {
        const more = try std.fmt.allocPrint(allocator, "+{d} more", .{board.games.len - shown});
        defer allocator.free(more);
        try table.writeLine(w, more, cols, "2", color);
    }
    try w.writeByte('\n');
    const previous = try dates.shift(allocator, board.date, -1);
    defer allocator.free(previous);
    const next = try dates.shift(allocator, board.date, 1);
    defer allocator.free(next);
    try w.print("/{s}?date={s}    /{s}?date={s}\n", .{
        board.league,
        previous,
        board.league,
        next,
    });
    return out.toOwnedSlice();
}

/// One scoreboard participant row, column-aligned like the old table
/// interior (abbr, name, score, winner tick, record) but borderless and
/// unpadded. Winner coloring wraps at emit time, never inside.

fn scoreParticipantLine(allocator: std.mem.Allocator, p: domain.Participant, cols: usize) ![]u8 {
    var rec_w: usize = 0;
    if (p.record) |r| rec_w = table.textCells(r);
    rec_w = @min(rec_w, 10);
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const b = &buf.writer;
    if (p.abbreviation.len > 0) {
        try writeCell(b, p.abbreviation, 4, null, false);
        try b.writeByte(' ');
        try writeCell(b, p.name, cols -| 4 -| 2 -| 4 -| 2 -| (if (p.record != null) rec_w + 3 else 0), null, false);
    } else {
        // Athlete identities carry no abbreviation: the name absorbs it.
        try writeCell(b, p.name, cols -| 7 -| (if (p.record != null) rec_w + 3 else 0), null, false);
    }
    try b.writeByte(' ');
    try writeCellRight(b, p.score, 4, null, false);
    if (p.record) |r| {
        try b.writeAll(" (");
        try writeCell(b, r, rec_w, null, false);
        try b.writeByte(')');
    }
    if (p.winner) try b.writeAll(" ✓") else try b.writeAll("  ");
    const raw = try buf.toOwnedSlice();
    defer allocator.free(raw);
    return allocator.dupe(u8, std.mem.trimEnd(u8, raw, " "));
}

/// ET-default wrapper: no `?tz=` means the Eastern day, so existing
/// callers (and the digest sections they compose) keep rendering.
pub fn text(allocator: std.mem.Allocator, board: domain.Scoreboard, color: bool, width: ?u16, height: ?u16) ![]u8 {
    return textWithZone(allocator, board, color, width, height, .et);
}

fn statusColor(state: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, state, "in")) return "1;31";
    if (std.mem.eql(u8, state, "pre")) return "33";
    return null;
}

fn colorize(w: *std.Io.Writer, code: []const u8, s: []const u8, enabled: bool) !void {
    if (!enabled) {
        try w.writeAll(s);
        return;
    }
    try w.print("\x1b[{s}m", .{code});
    try w.writeAll(s);
    try w.writeAll("\x1b[0m");
}

pub fn home(allocator: std.mem.Allocator, color: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try colorize(w, "2", "sprts\n", color);
    try table.writeSeparator(w, 50);
    for (leagues.all) |league| {
        var cell: std.Io.Writer.Allocating = .init(allocator);
        defer cell.deinit();
        try writeCell(&cell.writer, league.slug, 13, null, color);
        try cell.writer.writeByte(' ');
        try writeCell(&cell.writer, league.name, 34, null, color);
        const padded = try cell.toOwnedSlice();
        defer allocator.free(padded);
        try w.writeAll(std.mem.trimEnd(u8, padded, " "));
        try w.writeByte('\n');
    }
    try w.writeByte('\n');
    try colorize(w, "2", "Try: curl localhost:8080/mlb\n", color);
    return out.toOwnedSlice();
}

pub const default_host = "localhost:8080";
pub const repo_url = "https://github.com/h0rv/sprts";

/// Host text safe to echo back to clients: hostname characters only,
/// capped in length. Anything else falls back to the local default so a
/// hostile Host header cannot bloat or break the page.
pub fn sanitizeHost(value: ?[]const u8) []const u8 {
    const v = value orelse return default_host;
    if (v.len == 0 or v.len > 64) return default_host;
    for (v) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', ':' => {},
        else => return default_host,
    };
    return v;
}

/// Live home page: leagues with live games first, then the rest of today
/// as compact one-liners, then idle leagues as links. Leagues whose fetch
/// failed render as plain links, so one ESPN outage never fails the page.
/// The heading names its zone (`sprts  2026-09-06 ET`); section rows keep
/// the shared `homeSections` layout untouched (the HTML home owns it too).
pub fn homeLiveWithZone(
    allocator: std.mem.Allocator,
    color: bool,
    host: []const u8,
    boards: []const provider.LeagueResult,
    day: []const u8,
    quiet: bool,
    zone: tz.Zone,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    if (!quiet) {
        const tag = try tz.zoneTag(allocator, zone);
        defer allocator.free(tag);
        const heading = try std.fmt.allocPrint(allocator, "sprts  {s} {s}", .{ day, tag });
        defer allocator.free(heading);
        try colorize(w, "2", heading, color);
        try w.writeByte('\n');
    }
    try table.writeSeparator(w, 50);
    try homeSections(allocator, w, boards, color, false, day);
    try w.writeByte('\n');
    if (!quiet) try homeFooter(w, host, color);
    return out.toOwnedSlice();
}

/// ET-default wrapper for `homeLiveWithZone`.
pub fn homeLive(
    allocator: std.mem.Allocator,
    color: bool,
    host: []const u8,
    boards: []const provider.LeagueResult,
    day: []const u8,
    quiet: bool,
) ![]u8 {
    return homeLiveWithZone(allocator, color, host, boards, day, quiet, .et);
}

/// Home one-line (`/?0`): every game today is ONE line, no box, no
/// header/footer — same per-game shape as `scoreOneLine`, across leagues.
/// Idle leagues (no board or no games) emit nothing; with no games at all
/// the body is a single `No games scheduled.` line.
/// Each line carries the zone (`mlb 9/6 ET ...`) via `tz.labelFor`'s zone.
pub fn homeOneLineWithZone(
    allocator: std.mem.Allocator,
    boards: []const provider.LeagueResult,
    color: bool,
    zone: tz.Zone,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var any = false;
    const tag = try tz.zoneTag(allocator, zone);
    defer allocator.free(tag);
    for (boards) |result| {
        const board = result.board orelse continue;
        for (board.games) |game| {
            try writeBoardGameOneLine(&out.writer, result.league.slug, board.date, game, color, tag);
            any = true;
        }
    }
    if (!any) try out.writer.writeAll("No games scheduled.\n");
    return out.toOwnedSlice();
}

/// ET-default wrapper for `homeOneLineWithZone`.
pub fn homeOneLine(
    allocator: std.mem.Allocator,
    boards: []const provider.LeagueResult,
    color: bool,
) ![]u8 {
    return homeOneLineWithZone(allocator, boards, color, .et);
}

/// Compact one-liner per game, column-aligned across the page: leagues,
/// teams, and scores share fixed columns so days scan vertically; only
/// the trailing status is ragged. `mlb  CLE   9 @ BAL   5 ✓  Bot 7th`.
/// `slug_w`/`abbr_w` are page-wide maxima (computed in `homeSections`).
/// A two-participant game always reads as a duel: team sides are
/// `{abbr} {score}`; athlete sides (empty abbreviation, e.g. UFC) read
/// as bare names joined with ` v `. Records stay out: they would drown
/// the line (`ufc  Name 9-0-0` reads like a score). Non-duels fall back
/// to the game name. Returns null for nothing to show.
fn gameLine(allocator: std.mem.Allocator, league: *const leagues.League, game: domain.Game, slug_w: usize, abbr_w: usize) !?[]u8 {
    if (game.participants.len == 2) {
        const first = game.participants[0];
        const second = game.participants[1];
        const away, const home_team = if (std.mem.eql(u8, second.home_away orelse "", "home"))
            .{ first, second }
        else if (std.mem.eql(u8, first.home_away orelse "", "home"))
            .{ second, first }
        else
            .{ first, second };
        // Winner tick rides a fixed 2-cell column so scores align whether
        // or not the game is decided yet.
        const mark: []const u8 = if (away.winner or home_team.winner) " ✓" else "  ";
        const date_part = splitStatus(shortStatus(game.status));
        const date = date_part.date;
        const rest = date_part.rest;
        if (away.abbreviation.len > 0 and home_team.abbreviation.len > 0) {
            // Column duel: slug, sides, scores, tick, then the date word
            // (if any) and the status tail. Callers fit to the frame.
            var buf: std.Io.Writer.Allocating = .init(allocator);
            errdefer buf.deinit();
            const b = &buf.writer;
            try writeCell(b, league.slug, slug_w, null, false);
            try b.writeByte(' ');
            try writeCell(b, away.abbreviation, abbr_w, null, false);
            try b.writeByte(' ');
            try writeCellRight(b, away.score, 3, null, false);
            try b.writeAll(" @ ");
            try writeCell(b, home_team.abbreviation, abbr_w, null, false);
            try b.writeByte(' ');
            try writeCellRight(b, home_team.score, 3, null, false);
            try b.writeAll(mark);
            try b.writeAll("  ");
            try writeCell(b, date, 5, null, false);
            const norm = try tz.normalizeEastern(allocator, rest);
            defer allocator.free(norm);
            try b.writeAll(norm);
            return try buf.toOwnedSlice();
        }
        if (away.abbreviation.len > 0 or home_team.abbreviation.len > 0) {
            const away_side = try sideText(allocator, away);
            defer allocator.free(away_side);
            const home_side = try sideText(allocator, home_team);
            defer allocator.free(home_side);
            const mark2: []const u8 = if (away.winner or home_team.winner) " ✓" else "  ";
            var buf: std.Io.Writer.Allocating = .init(allocator);
            errdefer buf.deinit();
            try writeCell(&buf.writer, league.slug, slug_w, null, false);
            try buf.writer.writeByte(' ');
            if (away_side.len > 0 and home_side.len > 0) {
                const joiner: []const u8 = " v ";
                try buf.writer.writeAll(away_side);
                try buf.writer.writeAll(joiner);
                try buf.writer.writeAll(home_side);
            } else {
                const side = if (away_side.len > 0) away_side else home_side;
                try buf.writer.writeAll(side);
            }
            try buf.writer.writeAll(mark2);
            try gameLineTail(allocator, &buf.writer, date, rest);
            return try buf.toOwnedSlice();
        }
        if (away.name.len > 0 or home_team.name.len > 0) {
            var buf: std.Io.Writer.Allocating = .init(allocator);
            errdefer buf.deinit();
            try writeCell(&buf.writer, league.slug, slug_w, null, false);
            try buf.writer.writeByte(' ');
            try buf.writer.writeAll(away.name);
            try buf.writer.writeAll(" v ");
            try buf.writer.writeAll(home_team.name);
            if (away.winner or home_team.winner) try buf.writer.writeAll(" ✓") else try buf.writer.writeAll("  ");
            try gameLineTail(allocator, &buf.writer, date, rest);
            return try buf.toOwnedSlice();
        }
        if (away.score.len > 0 or home_team.score.len > 0) {
            var buf: std.Io.Writer.Allocating = .init(allocator);
            errdefer buf.deinit();
            try writeCell(&buf.writer, league.slug, slug_w, null, false);
            try buf.writer.writeByte(' ');
            try writeCell(&buf.writer, away.abbreviation, abbr_w, null, false);
            try buf.writer.writeByte(' ');
            try writeCellRight(&buf.writer, away.score, 3, null, false);
            try buf.writer.writeAll(" @ ");
            try writeCell(&buf.writer, home_team.abbreviation, abbr_w, null, false);
            try buf.writer.writeByte(' ');
            try writeCellRight(&buf.writer, home_team.score, 3, null, false);
            if (away.winner or home_team.winner) try buf.writer.writeAll(" ✓") else try buf.writer.writeAll("  ");
            try gameLineTail(allocator, &buf.writer, date, rest);
            return try buf.toOwnedSlice();
        }
        var tail_buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer tail_buf.deinit();
        try writeCell(&tail_buf.writer, league.slug, slug_w, null, false);
        try tail_buf.writer.writeByte(' ');
        try tail_buf.writer.writeAll(away.abbreviation);
        try tail_buf.writer.writeAll(" @ ");
        try tail_buf.writer.writeAll(home_team.abbreviation);
        try tail_buf.writer.writeAll("  ");
        const tail_part = splitStatus(shortStatus(game.status));
        const tail_date = tail_part.date;
        const tail_rest = tail_part.rest;
        try writeCell(&tail_buf.writer, tail_date, 5, null, false);
        try tail_buf.writer.writeAll(tail_rest);
        return try tail_buf.toOwnedSlice();
    }
    if (game.participants.len == 0 and game.name.len == 0) return null;
    var name_buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer name_buf.deinit();
    try writeCell(&name_buf.writer, league.slug, slug_w, null, false);
    try name_buf.writer.writeByte(' ');
    try name_buf.writer.writeAll(game.name);
    try name_buf.writer.writeAll("  ");
    const name_part = splitStatus(shortStatus(game.status));
    const name_date = name_part.date;
    const name_rest = name_part.rest;
    try writeCell(&name_buf.writer, name_date, 5, null, false);
    try name_buf.writer.writeAll(name_rest);
    return try name_buf.toOwnedSlice();
}

/// Short date: `2026-09-08` becomes `09-08`. The year is implicit in
/// the page heading; anything not shaped like a date passes through.
fn shortDate(day: []const u8) []const u8 {
    if (day.len >= 10 and day[4] == '-' and day[7] == '-') return day[5..10];
    return day;
}

/// Split a home status into its leading date word and the tail: `9/9 -
/// 8:20 PM EDT` becomes date `9/9` + `8:20 PM EDT`; anything else
/// (`Final`, `Bot 7th`, `Scheduled`) has no date word. The date column
/// aligns kickoff times down the page.
fn splitStatus(status: []const u8) struct { date: []const u8, rest: []const u8 } {
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
/// fixed column, then the status tail. Keeps every gameLine branch in
/// the same rhythm without repeating the separators.
fn gameLineTail(allocator: std.mem.Allocator, w: *std.Io.Writer, date: []const u8, rest: []const u8) !void {
    try w.writeAll("  ");
    try writeCell(w, date, 5, null, false);
    const norm = try tz.normalizeEastern(allocator, rest);
    defer allocator.free(norm);
    try w.writeAll(norm);
}

/// Short status: strip a leading `YYYY-` year prefix (`2026-09-08`
/// becomes `09-08`) so home lines stay compact. The year is implicit
/// in the page heading; anything not shaped like a date passes through.
fn shortStatus(status: []const u8) []const u8 {
    if (status.len >= 5 and status[4] == '-' and status[0] >= '0' and status[0] <= '9') {
        var i: usize = 0;
        while (i + 4 < status.len and status[i] >= '0' and status[i] <= '9' and status[i + 4] == '-') i += 1;
        if (i >= 4) return status[5..];
    }
    return status;
}

/// One side of a duel: `{abbr} {score}`, falling back to the full name
/// when the abbreviation is missing (UFC-style bouts). Records stay
/// out: they would drown the line (`ufc  Name 9-0-0` reads like a
/// score). An abbr side always duels; a fully empty side collapses so
/// a lone named side never prints a bare `@` opponent.
fn sideText(allocator: std.mem.Allocator, p: domain.Participant) ![]u8 {
    if (p.abbreviation.len > 0 and p.score.len > 0) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ p.abbreviation, p.score });
    }
    if (p.abbreviation.len > 0) return allocator.dupe(u8, p.abbreviation);
    if (p.name.len > 0) return std.fmt.allocPrint(allocator, "@{s}", .{p.name});
    if (p.score.len > 0) return allocator.dupe(u8, p.score);
    return allocator.dupe(u8, "");
}

fn gameIsLive(game: domain.Game) bool {
    return std.mem.eql(u8, game.state, "in");
}

/// Live games first, then one section per league with games today
/// (league header links to the league page in HTML), then idle leagues
/// as links. Leagues with no board (fetch failed) count as idle: the
/// page never fails because of one league. Rules are sparing: the frame
/// opens once at the top and closes once at the bottom; sections breathe
/// through blank spacer rows, never mid rules — the grid stays quiet
/// even on dense days.
fn homeSections(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    boards: []const provider.LeagueResult,
    color: bool,
    comptime html: bool,
    day: []const u8,
) !void {
    // Page-wide column widths so league, team, and score columns align
    // down the whole page: widest slug/abbreviation among leagues with
    // shown games (idle-league rows keep their own fixed cells). Floors
    // keep narrow days compact; caps bound exotic abbreviations.
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
    slug_w = @min(slug_w, 10);
    abbr_w = @min(abbr_w, 5);
    var separated = false;
    var live = false;
    for (boards) |result| {
        const board = result.board orelse continue;
        for (board.games) |game| {
            if (gameIsLive(game)) {
                if (!live) {
                    live = true;
                    if (html) {
                        try writeHtmlLine(w, allocator, "LIVE NOW", 50, "live", null);
                    } else {
                        try table.writeLine(w, "LIVE NOW", 50, "1;31", color);
                    }
                }
                try homeGameLine(allocator, w, result.league, game, color and !html, html, slug_w, abbr_w);
            }
        }
    }
    if (live) separated = true;
    for (boards) |result| {
        const board = result.board orelse continue;
        var has_today = false;
        for (board.games) |game| {
            if (!gameIsLive(game)) {
                has_today = true;
                break;
            }
        }
        if (!has_today) continue;
        if (separated) try w.writeByte('\n');
        // League header: name plus M/D date (year is implicit in the
        // page heading). Whole line links to the league page in HTML.
        const header = try std.fmt.allocPrint(allocator, "{s}  {s}", .{ result.league.name, shortDate(day) });
        defer allocator.free(header);
        if (html) {
            const href = try homeLeagueHref(allocator, result.league.slug, day);
            defer allocator.free(href);
            try writeHtmlLine(w, allocator, header, 50, "dim", href);
        } else {
            try table.writeLine(w, header, 50, "2", color);
        }
        for (board.games) |game| {
            if (gameIsLive(game)) continue;
            try homeGameLine(allocator, w, result.league, game, color and !html, html, slug_w, abbr_w);
        }
        separated = true;
    }
    var idle_first = true;
    for (boards) |result| {
        const board = result.board;
        if (board != null and board.?.games.len > 0) continue;
        if (idle_first) {
            idle_first = false;
            if (separated) try w.writeByte('\n');
            if (html) {
                try writeHtmlLine(w, allocator, "ALL LEAGUES", 50, "dim", null);
            } else {
                try table.writeLine(w, "ALL LEAGUES", 50, "2", color);
            }
        }
        if (html) {
            const href = try homeLeagueHref(allocator, result.league.slug, day);
            defer allocator.free(href);
            try w.writeAll("<a href=\"");
            try escapeInto(w, href);
            try w.writeAll("\">");
        }
        {
            var cell: std.Io.Writer.Allocating = .init(allocator);
            defer cell.deinit();
            try writeCell(&cell.writer, result.league.slug, 13, null, false);
            try cell.writer.writeByte(' ');
            try writeCell(&cell.writer, result.league.name, 34, null, false);
            const padded = try cell.toOwnedSlice();
            defer allocator.free(padded);
            const trimmed = std.mem.trimEnd(u8, padded, " ");
            if (html) {
                try escapeInto(w, trimmed);
            } else {
                try w.writeAll(trimmed);
            }
        }
        if (html) try w.writeAll("</a>");
        try w.writeByte('\n');
    }
}

/// Padded + escaped cell with optional color span, without borders or
/// link. Shared by home game lines; keeps the span inside the anchor so
/// the whole row stays one link.
fn writeHtmlCell(allocator: std.mem.Allocator, s: []const u8, css: ?[]const u8, w: *std.Io.Writer) !void {
    if (css) |class| {
        try w.writeAll("<span class=\"");
        try w.writeAll(class);
        try w.writeAll("\">");
    }
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try writeCell(&cell.writer, s, default_inner_width - 2, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    try escapeCellInto(w, padded);
    if (css != null) try w.writeAll("</span>");
}

/// Section header row for the HTML home renderer (league names, LIVE
/// NOW, ALL LEAGUES): padded cell with optional span and link. Linked
/// headers wrap the trimmed text only; padding stays outside the anchor
/// so underlines never cross the row.
fn writeHtmlRow(allocator: std.mem.Allocator, s: []const u8, css: ?[]const u8, inner: usize, w: *std.Io.Writer, link: ?[]const u8) !void {
    _ = inner;
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try writeCell(&cell.writer, s, default_inner_width - 2, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    const trimmed = std.mem.trimEnd(u8, padded, " ");
    try w.writeAll("│ ");
    if (link) |href| {
        try w.writeAll("<a href=\"");
        try escapeInto(w, href);
        try w.writeAll("\">");
    }
    if (css) |class| {
        try w.writeAll("<span class=\"");
        try w.writeAll(class);
        try w.writeAll("\">");
    }
    try escapeCellInto(w, trimmed);
    if (css != null) try w.writeAll("</span>");
    if (link != null) try w.writeAll("</a>");
    var pad: usize = padded.len - trimmed.len;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
    try w.writeAll(" │\n");
}

/// HTML home game line: the whole row is one link to the game view,
/// with the live/upcoming color span inside it.
fn writeHtmlGameLine(allocator: std.mem.Allocator, line: []const u8, game: domain.Game, w: *std.Io.Writer, href: []const u8) !void {
    try w.writeAll("│ ");
    try w.writeAll("<a href=\"");
    try escapeInto(w, href);
    try w.writeAll("\">");
    try writeHtmlCell(allocator, line, stateClass(game.state), w);
    try w.writeAll("</a> │\n");
}

fn homeGameLine(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    league: *const leagues.League,
    game: domain.Game,
    color: bool,
    html: bool,
    slug_w: usize,
    abbr_w: usize,
) !void {
    const line = try gameLine(allocator, league, game, slug_w, abbr_w) orelse return;
    defer allocator.free(line);
    if (html) {
        // Sibling anchors only: non-team text links the game view,
        // each side links its team page, matching the scoreboard's
        // granular links. The live/upcoming color span wraps the
        // siblings (a span containing anchors is valid HTML). The
        // status word carries the live/upcoming color span.
        const href = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ league.slug, game.id });
        defer allocator.free(href);
        try writeHtmlHomeGameLine(allocator, line, league, game, w, href);
        return;
    }
    try table.writeLine(w, line, 50, statusColor(game.state), color);
}

/// HTML home game line: `│ <span><a game>..</a><a team>abbr</a>..</span> │`.
/// Sibling anchors only, never nested: non-team text chunks link to the
/// game view, each participant abbreviation links to its team page. The
/// status word carries the live/upcoming color span. Padding reuses
/// writeCell so the frame aligns with the text renderer.
fn writeHtmlHomeGameLine(allocator: std.mem.Allocator, line: []const u8, league: *const leagues.League, game: domain.Game, w: *std.Io.Writer, href: []const u8) !void {
    try writeLinkedGameCell(allocator, line, league, game, w, href);
    try w.writeByte('\n');
}

/// Cell content for a home game line: the fitted line split into sibling
/// anchors — every non-team chunk links the game view, each participant
/// abbreviation wraps in a team link. Only non-empty abbreviations link:
/// nameless bouts (UFC-style) emit a single game link, so rows stay valid
/// either way. Abbreviations are matched positionally (away first, then
/// home) so a truncated name can never steal another team's link.
/// Unmatched tails (scores, status) ride the trailing game link. The line
/// is ragged (fitted, trailing blanks trimmed); stripping tags
/// concatenates back to the same line, so visible text matches the text
/// renderer byte for byte.
fn writeLinkedGameCell(allocator: std.mem.Allocator, line: []const u8, league: *const leagues.League, game: domain.Game, w: *std.Io.Writer, game_href: []const u8) !void {
    const css = stateClass(game.state);
    if (css) |class| {
        try w.writeAll("<span class=\"");
        try w.writeAll(class);
        try w.writeAll("\">");
    }
    // Collect the fitted line first so link offsets stay aligned; the
    // line stays ragged (trailing blanks trimmed) so underlines stop at
    // the text and visible text matches the text renderer byte for byte.
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try writeCell(&cell.writer, line, 50, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    const trimmed = std.mem.trimEnd(u8, padded, " ");
    var cursor: usize = 0;
    const content = trimmed;
    if (game.participants.len == 2) {
        const first = game.participants[0];
        const second = game.participants[1];
        const away, const home_team = if (std.mem.eql(u8, second.home_away orelse "", "home"))
            .{ first, second }
        else if (std.mem.eql(u8, first.home_away orelse "", "home"))
            .{ second, first }
        else
            .{ first, second };
        for ([2]domain.Participant{ away, home_team }) |part| {
            if (part.abbreviation.len == 0) continue;
            if (std.mem.indexOf(u8, content[cursor..], part.abbreviation)) |rel| {
                const at = cursor + rel;
                if (at > cursor) {
                    try w.writeAll("<a href=\"");
                    try escapeInto(w, game_href);
                    try w.writeAll("\">");
                    try escapeCellInto(w, content[cursor..at]);
                    try w.writeAll("</a>");
                }
                const team_href = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ league.slug, part.abbreviation });
                defer allocator.free(team_href);
                try w.writeAll("<a href=\"");
                try escapeInto(w, team_href);
                try w.writeAll("\">");
                try escapeCellInto(w, part.abbreviation);
                try w.writeAll("</a>");
                cursor = at + part.abbreviation.len;
            }
        }
    }
    if (content[cursor..].len > 0) {
        try w.writeAll("<a href=\"");
        try escapeInto(w, game_href);
        try w.writeAll("\">");
        try escapeCellInto(w, content[cursor..]);
        try w.writeAll("</a>");
    }
    if (css != null) try w.writeAll("</span>");
}

fn homeFooter(w: *std.Io.Writer, host: []const u8, color: bool) !void {
    try colorize(w, "2", "Try: curl ", color);
    try colorize(w, "2", host, color);
    try colorize(w, "2", "/mlb\n", color);
    try colorize(w, "2", "Docs: ", color);
    try colorize(w, "2", host, color);
    try colorize(w, "2", "/docs\n", color);
    try colorize(w, "2", "Code: " ++ repo_url ++ "\n", color);
}

fn writeShortDate(w: *std.Io.Writer, date: []const u8) !void {
    if (date.len >= 10 and date[4] == '-' and date[7] == '-') {
        const m = date[5..7];
        const d = date[8..10];
        const mm = if (m[0] == '0') m[1..] else m;
        const dd = if (d[0] == '0') d[1..] else d;
        try w.print("{s}/{s}", .{ mm, dd });
    } else {
        try w.writeAll(date);
    }
}

fn writeBoardGameOneLine(w: *std.Io.Writer, league_slug: []const u8, board_date: []const u8, game: domain.Game, color: bool, zone_tag: []const u8) !void {
    const code: ?[]const u8 = if (color) statusColor(game.state) else null;
    if (code) |c| try w.print("\x1b[{s}m", .{c});
    try w.writeAll(league_slug);
    try w.writeByte(' ');
    try writeShortDate(w, board_date);
    try w.writeByte(' ');
    try w.writeAll(zone_tag);
    try w.writeByte(' ');
    try w.writeAll(game.status);
    if (game.participants.len == 2) {
        const first = game.participants[0];
        const second = game.participants[1];
        const away, const home_team = if (std.mem.eql(u8, second.home_away orelse "", "home"))
            .{ first, second }
        else if (std.mem.eql(u8, first.home_away orelse "", "home"))
            .{ second, first }
        else
            .{ first, second };
        if (away.score.len > 0 or home_team.score.len > 0) {
            try w.print(" {s} {s} @ {s} {s}", .{
                away.abbreviation, away.score, home_team.abbreviation, home_team.score,
            });
            if (away.winner or home_team.winner) try w.writeAll(" ✓");
        } else {
            try w.print(" {s} @ {s}", .{ away.abbreviation, home_team.abbreviation });
        }
    } else if (game.name.len > 0) {
        try w.writeByte(' ');
        try w.writeAll(game.name);
        var won = false;
        for (game.participants) |p| if (p.winner) {
            won = true;
            break;
        };
        if (won) try w.writeAll(" ✓");
    } else if (game.participants.len > 0) {
        for (game.participants, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte(' ');
            try w.writeAll(p.abbreviation);
        }
    }
    if (code) |_| try w.writeAll("\x1b[0m");
    try w.writeByte('\n');
}

/// True when any participant in the first `shown` games has a color mark.
/// The score HTML linkifier only reads the color twin on art rows, so a
/// false here means the twin render can be skipped with identical output.
fn boardHasColorArt(board: domain.Scoreboard, shown: usize) bool {
    for (board.games[0..shown]) |game| {
        for (game.participants) |participant| {
            if (core.art.teamArtColor(board.league, participant.abbreviation, .xs) != null) return true;
        }
    }
    return false;
}

/// Minimal browser page: the same table as text, never ANSI, with real
/// links. Browsers cannot use terminal escapes, so SGR never reaches the
/// page raw: team marks re-render as rgb spans while the text renderer
/// stays the single source of layout.
/// The title and the table heading both name the zone
/// (`MLB scores 2026-09-06 ET`); the date nav stays date-only.
pub fn scoreHtmlWithZone(allocator: std.mem.Allocator, board: domain.Scoreboard, width: ?u16, height: ?u16, zone: tz.Zone) ![]u8 {
    const shown_pre: usize = @min(height orelse board.games.len, board.games.len);
    const body = try textWithZone(allocator, board, false, width, height, zone);
    defer allocator.free(body);
    // Fast path: no shown participant has a color mark, so the linkifier
    // never reads the color twin (only art rows consult it). Reuse the
    // mono body instead of rendering the full table twice.
    var color_owned: ?[]u8 = null;
    defer if (color_owned) |b| allocator.free(b);
    if (boardHasColorArt(board, shown_pre)) {
        color_owned = try textWithZone(allocator, board, true, width, height, zone);
    }
    const color_body = color_owned orelse body;
    const previous = try dates.shift(allocator, board.date, -1);
    defer allocator.free(previous);
    const next = try dates.shift(allocator, board.date, 1);
    defer allocator.free(next);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const tag = try tz.zoneTag(allocator, zone);
    defer allocator.free(tag);
    const title = try std.fmt.allocPrint(allocator, "{s} scores {s} {s}", .{ board.league_name, board.date, tag });
    defer allocator.free(title);
    try pageHead(w, title);
    try w.writeAll("<pre>");
    const shown: usize = shown_pre;
    const inner: usize = @min(@max(width orelse 52, 52), 200) - 2;
    try writeLinkedScoreboard(w, allocator, board, body, color_body, inner, shown);
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/{s}?date={s}\">earlier</a>", .{ board.league, previous });
    try w.print("<a href=\"/{s}\">today</a>", .{board.league});
    try w.print("<a href=\"/{s}?date={s}\">later</a>", .{ board.league, next });
    try w.print("<a href=\"/api/v1/{s}?date={s}\">json</a>", .{ board.league, board.date });
    try closePageWithNav(w);
    return out.toOwnedSlice();
}

/// ET-default wrapper for `scoreHtmlWithZone`.
pub fn scoreHtml(allocator: std.mem.Allocator, board: domain.Scoreboard, width: ?u16, height: ?u16) ![]u8 {
    return scoreHtmlWithZone(allocator, board, width, height, .et);
}

/// Post-pass linkifier for `scoreHtml`: re-emits the plain-text table
/// line by line, wrapping each game's status cell in a
/// `<a href="/{league}/{id}" id="game-{id}">` anchor and each team's
/// abbreviation/name in `<a href="/{league}/{abbr}">` anchors. The
/// `text` renderer stays the single source of layout: only invisible
/// tags are added, so the visible text matches `text(color=false)`
/// byte for byte. Everything — including built hrefs — escapes via
/// `escapeInto`, so hostile provider text (`<OT>`-style statuses) can
/// never break the page. Team marks ride along in color: art rows
/// (braille, no participant hit) re-emit from a color=true twin body via
/// `table.writeArtLineHtml`, so SGR becomes rgb spans and `\x1b[` never
/// reaches the page. Every other row uses the mono body, so the visible
/// text still matches `text(color=false)` byte for byte.
fn writeLinkedScoreboard(w: *std.Io.Writer, allocator: std.mem.Allocator, board: domain.Scoreboard, body: []const u8, color_body: []const u8, inner: usize, shown: usize) !void {
    _ = inner;
    var game_idx: usize = 0;
    var current: ?usize = null;
    var part_pos: usize = 0;
    var pending_rule = false;
    var first_row = true;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var color_lines = std.mem.splitScalar(u8, color_body, '\n');
    while (lines.next()) |line| {
        // Lockstep twin: same layout, plus SGR on art rows (and ANSI
        // elsewhere, which only art rows ever read). Desync falls back
        // to the mono line, never to raw escapes.
        const color_line = color_lines.next() orelse line;
        if (line.len == 0) {
            // Blank separators breathe; the body's single trailing empty
            // (after its final newline) carries no row.
            if (lines.peek() == null) continue;
            try w.writeByte('\n');
            continue;
        }
        if (isRuleLine(line)) {
            try escapeInto(w, line);
            try w.writeByte('\n');
            if (current != null and game_idx >= shown) {
                // No more game slots: the next row is the `+N more`
                // trailer, not a new game.
                current = null;
            }
            pending_rule = true;
            continue;
        }
        if (line[0] == '/') {
            // The trailing `/{league}?date=` footer carries no links.
            try escapeInto(w, line);
            try w.writeByte('\n');
            continue;
        }
        if (first_row) {
            // Heading row: league context already, no link.
            first_row = false;
            try escapeInto(w, line);
            try w.writeByte('\n');
            continue;
        }
        if (pending_rule) {
            pending_rule = false;
            if (game_idx < shown) {
                const game = &board.games[game_idx];
                current = game_idx;
                part_pos = 0;
                game_idx += 1;
                try writeGameStatusRow(w, allocator, board.league, game, line, true);
                continue;
            }
            // `+N more` trailer or the empty-schedule note.
            current = null;
            try escapeInto(w, line);
            try w.writeByte('\n');
            continue;
        }
        if (current) |gi| {
            const game = &board.games[gi];
            if (game.participants.len == 0) {
                // Name-only game row: the name stands in for the game, so
                // link it too but skip the anchor id — the status row
                // above already owns `game-{id}`.
                try writeGameStatusRow(w, allocator, board.league, game, line, false);
                continue;
            }
            if (isColorArtRow(line, game, part_pos)) {
                // Colored mark row: spans, no link, cursor untouched.
                try writeColorArtRow(w, color_line);
                continue;
            }
            try writeLinkedParticipantRow(w, allocator, board.league, game, &part_pos, line);
            continue;
        }
        try escapeInto(w, line);
        try w.writeByte('\n');
    }
}

/// A separator rule is nothing but ─ cells: headings, statuses, and art
/// never consist solely of them, so rows cannot be mistaken for rules.
fn isRuleLine(line: []const u8) bool {
    if (line.len == 0 or line.len % 3 != 0) return false;
    var i: usize = 0;
    while (i < line.len) : (i += 3) {
        if (!std.mem.eql(u8, line[i..][0..3], "─")) return false;
    }
    return true;
}
/// Status (or name-only) row for one game: the trimmed line becomes the
/// game link and carries the per-game anchor id. Made `with_id` so a
/// caller can reuse the wrapper for rows that already live inside a
/// linked context without duplicating ids. Padding never enters the
/// anchor, so underlines stop at the text.
fn writeGameStatusRow(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    league_slug: []const u8,
    game: *const domain.Game,
    line: []const u8,
    with_id: bool,
) !void {
    const trimmed = std.mem.trimEnd(u8, line, " ");
    const href = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ league_slug, game.id });
    defer allocator.free(href);
    try w.writeAll("<a href=\"");
    try escapeInto(w, href);
    if (with_id) {
        try w.writeAll("\" id=\"game-");
        try escapeInto(w, game.id);
    }
    try w.writeAll("\">");
    try escapeInto(w, trimmed);
    try w.writeAll("</a>");
    try w.writeByte('\n');
}

/// Participant row: link the row's own participant to its team page.
/// Rows are consumed positionally per game — the Nth post-pass row maps
/// to the Nth participant — so art rows (which the renderer emits as
/// whole side-by-side pairs, not per participant) must never advance
/// the cursor. A row is linked only when it still carries its own
/// participant's abbreviation (survives truncation best) or full name;
/// art rows never match either and fall through as escaped plain text.
/// Empty-abbr (athlete-style) rows stay unlinked — there is no team
/// page to point at — while the game anchor above still navigates.
fn writeLinkedParticipantRow(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    league_slug: []const u8,
    game: *const domain.Game,
    part_pos: *usize,
    line: []const u8,
) !void {
    if (part_pos.* >= game.participants.len) {
        // Marks or overflow padding: no participant left to link.
        try escapeInto(w, line);
        try w.writeByte('\n');
        return;
    }
    const p = &game.participants[part_pos.*];
    const abbr_hit = p.abbreviation.len > 0 and std.mem.indexOf(u8, line, p.abbreviation) != null;
    const name_hit = p.name.len > 0 and std.mem.indexOf(u8, line, p.name) != null;
    if (!abbr_hit and !name_hit) {
        // Mark row or wrapped art: keep the cursor, no link.
        try escapeInto(w, line);
        try w.writeByte('\n');
        return;
    }
    part_pos.* += 1;
    if (p.abbreviation.len == 0) {
        try escapeInto(w, line);
        try w.writeByte('\n');
        return;
    }
    const href = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ league_slug, p.abbreviation });
    defer allocator.free(href);
    var cursor: usize = 0;
    if (std.mem.indexOf(u8, line[cursor..], p.abbreviation)) |rel| {
        const at = cursor + rel;
        try escapeInto(w, line[cursor..at]);
        try w.writeAll("<a href=\"");
        try escapeInto(w, href);
        try w.writeAll("\">");
        try escapeInto(w, p.abbreviation);
        try w.writeAll("</a>");
        cursor = at + p.abbreviation.len;
    }
    // A truncated name (ellipsis) is absent from the line, so only link
    // it when the full name is present; the abbr link above stays.
    if (p.name.len > 0) {
        if (std.mem.indexOf(u8, line[cursor..], p.name)) |rel| {
            const at = cursor + rel;
            try escapeInto(w, line[cursor..at]);
            try w.writeAll("<a href=\"");
            try escapeInto(w, href);
            try w.writeAll("\">");
            try escapeInto(w, p.name);
            try w.writeAll("</a>");
            cursor = at + p.name.len;
        }
    }
    try escapeInto(w, line[cursor..]);
    try w.writeByte('\n');
}

/// Art-row detector for the linkifier: a row inside a game that carries
/// braille but neither the current participant's abbreviation nor name.
/// Mirrors `writeLinkedParticipantRow`'s miss condition exactly so the two
/// can never disagree about what links: anything flagged here is a row
/// the linker would have left unlinked with the cursor held.
/// Order-agnostic: marks render AFTER the participant rows, so trailing
/// art rows arrive with the cursor exhausted (`part_pos >= len`). Those
/// still carry braille and match no participant's abbr/name; the pointer
/// row also arrives with the cursor exhausted but carries no braille, so
/// it stays unflagged. Checking every participant in the exhausted case
/// keeps the mirror exact (the linker would miss there too).
fn isColorArtRow(line: []const u8, game: *const domain.Game, part_pos: usize) bool {
    if (part_pos < game.participants.len) {
        const p = &game.participants[part_pos];
        if (p.abbreviation.len > 0 and std.mem.indexOf(u8, line, p.abbreviation) != null) return false;
        if (p.name.len > 0 and std.mem.indexOf(u8, line, p.name) != null) return false;
        return containsBraille(line);
    }
    for (game.participants) |*q| {
        if (q.abbreviation.len > 0 and std.mem.indexOf(u8, line, q.abbreviation) != null) return false;
        if (q.name.len > 0 and std.mem.indexOf(u8, line, q.name) != null) return false;
    }
    return containsBraille(line);
}

/// True when the line holds braille cells (U+2800-U+28FF: E2 A0-A3 ...).
/// Box rules (E2 94), the winner check (E2 9C), and the ellipsis
/// (E2 80) never match, so only mark rows qualify.
fn containsBraille(line: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        if (line[i] == 0xE2 and line[i + 1] >= 0xA0 and line[i + 1] <= 0xA3) return true;
    }
    return false;
}

/// One colored mark row as HTML: the color twin's line becomes rgb spans
/// via `table.writeArtLineHtml`, ragged like the text renderer.
/// Link-free and cursor-free by construction.
fn writeColorArtRow(
    w: *std.Io.Writer,
    color_line: []const u8,
) !void {
    try table.writeArtLineHtml(w, color_line, &htmlEscapeByte);
    try w.writeByte('\n');
}

/// One-byte HTML escaper for `table.writeArtLineHtml`: escape `&<>"'`,
/// pass glyph bytes through. Mirrors `escapeInto` per byte.
fn htmlEscapeByte(w: *std.Io.Writer, b: u8) !void {
    switch (b) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(b),
    }
}

/// One borderless HTML content line for the document-style views (game
/// detail, team): fitted to `cols` exactly like the text renderer
/// (truncate, trailing blanks trimmed), then optional link wrapping,
/// optional span class, newline. Column rows arrive pre-composed so text
/// and HTML share the same strings and the visible text stays identical.
pub fn writeHtmlLine(w: *std.Io.Writer, allocator: std.mem.Allocator, s: []const u8, cols: usize, css: ?[]const u8, link: ?[]const u8) !void {
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try writeCell(&cell.writer, s, cols, null, false);
    const padded = try cell.toOwnedSlice();
    defer allocator.free(padded);
    const trimmed = std.mem.trimEnd(u8, padded, " ");
    if (link) |href| {
        try w.writeAll("<a href=\"");
        try escapeInto(w, href);
        try w.writeAll("\">");
    }
    if (css) |class| {
        try w.writeAll("<span class=\"");
        try w.writeAll(class);
        try w.writeAll("\">");
    }
    try escapeInto(w, trimmed);
    if (css != null) try w.writeAll("</span>");
    if (link != null) try w.writeAll("</a>");
    try w.writeByte('\n');
}

/// Per-league today link shared by the static home rows and the live
/// home rows: `/{slug}?date={day}` when a day is in hand, dateless
/// `/{slug}` otherwise. One spelling everywhere, so the shortcut never
/// drifts between the two homes. Returned raw; callers escape it.
fn homeLeagueHref(allocator: std.mem.Allocator, slug: []const u8, day: ?[]const u8) ![]u8 {
    if (day) |d| {
        return try std.fmt.allocPrint(allocator, "/{s}?date={s}", .{ slug, d });
    }
    return try std.fmt.allocPrint(allocator, "/{s}", .{slug});
}

/// Static home: league slugs link to today's board for that league
/// (`/{slug}` defaults to today). The optional `day` spells the today
/// link out as `/{slug}?date={day}`; without it rows stay exactly as
/// before. The date lives in the href only, so the 52-column box stays
/// aligned either way. Nav always carries json/spec/github.
pub fn homeHtml(allocator: std.mem.Allocator) ![]u8 {
    return homeHtmlDay(allocator, null);
}

/// Home page mark: the pixel-S favicon displayed above the table (outside
/// `<pre>`, so visible-text tests never see it). Fixed size, cached with
/// the favicon itself.
pub const home_logo_mark =
    "<a class=\"logo-home\" href=\"/\">" ++
    "<span class=\"logo-dark\">" ++ logo_dark_svg ++ "</span>" ++
    "<span class=\"logo-light\">" ++ logo_light_svg ++ "</span></a>\n";

pub fn homeHtmlDay(allocator: std.mem.Allocator, day: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try pageHead(w, "sprts");
    try w.writeAll("<pre>");
    try table.writeSeparator(w, 50);
    for (leagues.all) |league| {
        const href = try homeLeagueHref(allocator, league.slug, day);
        defer allocator.free(href);
        var cell: std.Io.Writer.Allocating = .init(allocator);
        defer cell.deinit();
        try writeCell(&cell.writer, league.slug, 13, null, false);
        try cell.writer.writeByte(' ');
        try writeCell(&cell.writer, league.name, 34, null, false);
        const padded = try cell.toOwnedSlice();
        defer allocator.free(padded);
        try w.writeAll("<a href=\"");
        try escapeInto(w, href);
        try w.writeAll("\">");
        try escapeInto(w, std.mem.trimEnd(u8, padded, " "));
        try w.writeAll("</a>\n");
    }
    try w.writeByte('\n');
    try w.writeAll("Try: curl localhost:8080/mlb\n");
    try w.writeAll("</pre><nav><a href=\"/docs\">docs</a><a href=\"/openapi.json\">spec</a><a href=\"" ++ repo_url ++ "\">github</a>");
    try closePageWithNav(w);
    return out.toOwnedSlice();
}

/// Live HTML home: same sections as `homeLive`, never ANSI, with links.
/// Game lines link to their league page; per-league links spell today
/// out (`/{slug}?date={day}`), sharing the static home spelling. The
/// nav mirrors `homeHtml`.
pub fn homeHtmlLive(
    allocator: std.mem.Allocator,
    host: []const u8,
    boards: []const provider.LeagueResult,
    day: []const u8,
    quiet: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const heading = try std.fmt.allocPrint(allocator, "sprts  {s}", .{day});
    defer allocator.free(heading);
    try pageHead(w, heading);
    try w.writeAll("<pre>\n");
    try homeSections(allocator, w, boards, false, true, day);
    if (!quiet) {
        try w.writeAll("Try: curl ");
        try escapeInto(w, host);
        try w.writeAll("/mlb\nDocs: ");
        try escapeInto(w, host);
        try w.writeAll("/docs\nCode: " ++ repo_url ++ "\n");
    }
    try w.writeAll("</pre>");
    if (!quiet) {
        try w.writeAll("<nav><a href=\"/docs\">docs</a><a href=\"/openapi.json\">spec</a><a href=\"" ++ repo_url ++ "\">github</a>");
        try closePageWithNav(w);
    } else {
        try w.writeAll("</main></body></html>");
    }
    return out.toOwnedSlice();
}

pub fn pageHead(w: *std.Io.Writer, title: []const u8) !void {
    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<link rel=\"icon\" type=\"image/svg+xml\" href=\"/favicon.svg\">" ++
        "<title>");
    try escapeInto(w, title);
    try w.writeAll("</title>" ++ page_style ++ theme_script ++ "</head><body><main>" ++ home_logo_mark);
}

/// Escaped copy of a padded cell: escape `&<>"'` but pass spaces and
/// box-safe bytes through untouched.
fn escapeCellInto(w: *std.Io.Writer, cell: []const u8) !void {
    try escapeInto(w, cell);
}

pub fn escapeInto(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(byte),
    };
}

const page_style =
    \\<style>:root{--bg:#10140f;--ink:#e6ebe7;--muted:#8b968f;--link:#6fd3a0;--live:#ff7b7b;--up:#e8c547;--win:#5fd08a}html[data-theme="light"]{--bg:#f4f1e8;--ink:#1c2420;--muted:#5f6a63;--link:#0b6e4f;--live:#c81e1e;--up:#8a6d00;--win:#0b6e4f}html,body{margin:0;background:var(--bg);color:var(--ink)}main{max-width:640px;margin:auto;padding:20px 14px}pre{margin:0;font:16px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;word-wrap:break-word}a{color:var(--link)}pre a{color:var(--link);text-decoration:none}pre a:hover{text-decoration:underline;text-underline-offset:2px}.dim{color:var(--muted)}.live{color:var(--live);font-weight:bold}.upcoming{color:var(--up)}.win{color:var(--win);font-weight:bold}nav{margin-top:14px;font:14px ui-monospace,monospace}nav a{margin-right:16px}@media(max-width:480px){main{padding:12px 8px}pre{font-size:13px}}.logo-dark,.logo-light{display:block;margin:0 0 10px}.logo-light{display:none}html[data-theme="light"] .logo-dark{display:none}html[data-theme="light"] .logo-light{display:block}}</style>
;

/// Site mark: 8x8 pixel S in chunky rects on a dark rounded square —
/// the tinygrad/pi.dev kind of minimal geometric favicon, in our own
/// palette. Served verbatim at `/favicon.svg` and linked from every
/// page head; no script, no external assets, no font dependency.
pub const favicon_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" shape-rendering="crispEdges"><rect width="64" height="64" fill="#10140f"/><g transform="translate(2,24) scale(0.3158)" fill="#e6ebe7"><polygon points="0,10 20,10 20,20 0,20" /><polygon points="0,20 30,20 30,30 0,30" /><polygon points="10,30 30,30 30,40 10,40" /><polygon points="40,10 50,10 50,50 40,50" /><polygon points="40,10 70,10 70,20 40,20" /><polygon points="60,20 70,20 70,40 60,40" /><polygon points="40,30 70,30 70,40 40,40" /><polygon points="80,10 90,10 90,40 80,40" /><polygon points="80,10 110,10 110,20 80,20" /><polygon points="130,40 130,20 120,20 120,10 130,10 130,0 140,0 140,10 150,10 150,20 140,20 140,30 150,30 150,40" /><polygon points="160,10 180,10 180,20 160,20" /><polygon points="160,20 190,20 190,30 160,30" /><polygon points="170,30 190,30 190,40 170,40" /></g></svg>
;

/// Pixel wordmark `sprts` (lowercase, chunky rects like the
/// favicon): transparent backgrounds so the page shows through.
/// `logo_dark_svg` carries light ink for dark surfaces,
/// `logo_light_svg` dark ink for light surfaces; the home page
/// shows one or the other via the theme-swap classes below.
pub const logo_dark_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="-10 -10 210 70" width="120" shape-rendering="crispEdges" fill="#e6ebe7"><polygon points="0,10 20,10 20,20 0,20" /><polygon points="0,20 30,20 30,30 0,30" /><polygon points="10,30 30,30 30,40 10,40" /><polygon points="40,10 50,10 50,50 40,50" /><polygon points="40,10 70,10 70,20 40,20" /><polygon points="60,20 70,20 70,40 60,40" /><polygon points="40,30 70,30 70,40 40,40" /><polygon points="80,10 90,10 90,40 80,40" /><polygon points="80,10 110,10 110,20 80,20" /><polygon points="130,40 130,20 120,20 120,10 130,10 130,0 140,0 140,10 150,10 150,20 140,20 140,30 150,30 150,40" /><polygon points="160,10 180,10 180,20 160,20" /><polygon points="160,20 190,20 190,30 160,30" /><polygon points="170,30 190,30 190,40 170,40" /></svg>
;

pub const logo_light_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="-10 -10 210 70" width="120" shape-rendering="crispEdges" fill="#1c2420"><polygon points="0,10 20,10 20,20 0,20" /><polygon points="0,20 30,20 30,30 0,30" /><polygon points="10,30 30,30 30,40 10,40" /><polygon points="40,10 50,10 50,50 40,50" /><polygon points="40,10 70,10 70,20 40,20" /><polygon points="60,20 70,20 70,40 60,40" /><polygon points="40,30 70,30 70,40 40,40" /><polygon points="80,10 90,10 90,40 80,40" /><polygon points="80,10 110,10 110,20 80,20" /><polygon points="130,40 130,20 120,20 120,10 130,10 130,0 140,0 140,10 150,10 150,20 140,20 140,30 150,30 150,40" /><polygon points="160,10 180,10 180,20 160,20" /><polygon points="160,20 190,20 190,30 160,30" /><polygon points="170,30 190,30 190,40 170,40" /></svg>
;
/// Footer theme toggle: a single localStorage key persists the choice;
/// without one the OS preference wins (matchMedia before first paint, so
/// there is no dark flash either way). The footer link flips `data-theme`
/// and re-persists it; with storage blocked (private mode) the toggle
/// still works per page and every load falls back to the OS theme, so
/// pages can never disagree with each other.
const theme_script =
    \\<script>(function(){try{var t=localStorage.getItem("sprts-theme");if(t!=="light"&&t!=="dark"){t=(window.matchMedia&&matchMedia("(prefers-color-scheme: light)").matches)?"light":"dark";}document.documentElement.dataset.theme=t;}catch(e){}})();</script>
    \\<script>function sprtsTheme(){try{var h=document.documentElement;var n=h.dataset.theme==="light"?"dark":"light";h.dataset.theme=n;localStorage.setItem("sprts-theme",n);}catch(e){}return false;}</script>
;

/// Theme toggle link appended to every page footer nav. A plain link
/// (not a button) so it needs no button CSS and keeps the plaintext
/// vibe; with JS off it is a harmless `#` jump.
pub fn themeNavSuffix() []const u8 {
    return "<a href=\"#\" onclick=\"return sprtsTheme()\">light/dark</a>";
}

/// Closing tags shared by every HTML page: theme toggle link, then
/// nav, main, body, html. Callers write their own nav links first,
/// then this. Keeps footers identical everywhere.
pub fn closePageWithNav(w: *std.Io.Writer) !void {
    try w.writeAll(themeNavSuffix());
    try w.writeAll("</nav></main></body></html>");
}

/// CSS class matching the ANSI role for a game state: live games glow
/// red, upcoming games read yellow, finished games stay plain.
fn stateClass(state: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, state, "in")) return "live";
    if (std.mem.eql(u8, state, "pre")) return "upcoming";
    return null;
}

pub fn leaguesJson(allocator: std.mem.Allocator) ![]u8 {
    return validatedJson(leagues.LeagueList, allocator, .{ .leagues = &leagues.all });
}

pub fn errorBody(allocator: std.mem.Allocator, message: []const u8, format: router.Format) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    switch (format) {
        .text => try out.writer.print("sprts: {s}\n", .{message}),
        .html => {
            try pageHead(&out.writer, "sprts error");
            try out.writer.writeAll("<pre>sprts: ");
            try escapeInto(&out.writer, message);
            try out.writer.writeAll("</pre><nav><a href=\"/\">leagues</a>");
            try closePageWithNav(&out.writer);
        },
        .json => {
            try out.writer.writeAll("{\"error\":");
            try std.json.Stringify.value(message, .{}, &out.writer);
            try out.writer.writeAll("}\n");
        },
    }
    return out.toOwnedSlice();
}

test "JSON renderer exposes stable schema marker" {
    const board: domain.Scoreboard = .{ .league = "mlb", .league_name = "MLB", .date = "2026-09-06", .source = "test", .games = &.{} };
    const output = try json(std.testing.allocator, board);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"schema_version\": \"1\"") != null);
}

test "text renderer draws a document and no HTML" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    // Pipe-less document: heading, one separator, blank-separated game,
    // date footer — no box-drawing bytes anywhere.
    for ([_][]const u8{ "┌", "├", "└", "│", "─" }) |rule| {
        if (std.mem.eql(u8, rule, "─")) continue; // the separator lives here
        try std.testing.expect(std.mem.indexOf(u8, output, rule) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, output, "─") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "AWY") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "   5 ✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<html") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(output);
    // Long names truncate inside their column: every content line fits.
    const wide_board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Atlético Madrid Club de Fútbol with extra tail", .abbreviation = "ATM", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const wide = try text(std.testing.allocator, wide_board, false, null, null);
    defer std.testing.allocator.free(wide);
    try expectNoBrokenLines(wide, 52);
    try std.testing.expect(std.mem.indexOf(u8, wide, "…") != null);
}

test "text renderer colors by default and strips with the flag off" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "in",
                .status = "Top 7th",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "0", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "3", .winner = true },
                },
            },
        },
    };
    const colored = try text(std.testing.allocator, board, true, null, null);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[1;31m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[32m") != null);
    const plain = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
}

test "text renderer never splits a code point when truncating" {
    const board: domain.Scoreboard = .{
        .league = "laliga",
        .league_name = "La Liga",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Atletico Madrid at a team with a very long name indeed",
                .starts_at = "2026-09-06T17:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "a", .name = "Atlético Madrid Club de Fútbol with extra", .abbreviation = "ATM", .score = "", .winner = false },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    _ = try std.unicode.Utf8View.init(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "…") != null);
}

test "HTML pages link and never carry ANSI" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final <OT>",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const page = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb?date=2026-09-05\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/api/v1/mlb?date=2026-09-06\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Final &lt;OT&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    // Game and team links: status cell links the game (with anchor id),
    // team abbrevs link their team pages.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/1\" id=\"game-1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/AWY\">AWY</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/HME\">HME</a>") != null);
    // Hostile status text stays escaped even inside a link (padding
    // follows the text inside the anchor, so only check the escape).
    try std.testing.expect(std.mem.indexOf(u8, page, "<OT>") == null);
    // Visible text still matches the unlinked table byte for byte.
    try expectVisiblePreText(page, board, null, null);
    // Every page carries the clickable brand: logo links back home.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a class=\"logo-home\" href=\"/\">") != null);

    const homepage = try homeHtml(std.testing.allocator);
    defer std.testing.allocator.free(homepage);
    // Pixel mark above the table, outside the plaintext block: both
    // theme variants ride along, CSS shows exactly one.
    try std.testing.expect(std.mem.indexOf(u8, homepage, home_logo_mark) != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "logo-dark") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "logo-light") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "<a href=\"/mlb\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "<a href=\"/docs\">docs</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "<a href=\"/openapi.json\">spec</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "<a href=\"" ++ repo_url ++ "\">github</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, homepage, "\x1b[") == null);

    const dated = try homeHtmlDay(std.testing.allocator, "2026-09-06");
    defer std.testing.allocator.free(dated);
    try std.testing.expect(std.mem.indexOf(u8, dated, "<a href=\"/mlb?date=2026-09-06\">") != null);

    const err = try errorBody(std.testing.allocator, "a<b", .html);
    defer std.testing.allocator.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "a&lt;b") != null);
}

/// Renders `text` escaped (no tags) and expects it to equal the visible
/// `<pre>` text of `page` with tags stripped and entities decoded: the
/// linkifier adds invisible tags only, never layout.
fn expectVisiblePreText(page: []const u8, board: domain.Scoreboard, width: ?u16, height: ?u16) !void {
    const open = std.mem.indexOf(u8, page, "<pre>").?;
    const close = std.mem.indexOf(u8, page, "</pre>").?;
    const pre = page[open + "<pre>".len .. close];
    var visible: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer visible.deinit();
    var i: usize = 0;
    while (i < pre.len) {
        if (pre[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, pre, i, '>') orelse return error.TestUnexpectedResult;
            i = end + 1;
            continue;
        }
        if (pre[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, pre, i, ';') orelse return error.TestUnexpectedResult;
            const entity = pre[i .. semi + 1];
            if (std.mem.eql(u8, entity, "&amp;")) {
                try visible.writer.writeByte('&');
            } else if (std.mem.eql(u8, entity, "&lt;")) {
                try visible.writer.writeByte('<');
            } else if (std.mem.eql(u8, entity, "&gt;")) {
                try visible.writer.writeByte('>');
            } else if (std.mem.eql(u8, entity, "&quot;")) {
                try visible.writer.writeByte('"');
            } else if (std.mem.eql(u8, entity, "&#39;")) {
                try visible.writer.writeByte('\'');
            } else return error.TestUnexpectedResult;
            i = semi + 1;
            continue;
        }
        try visible.writer.writeByte(pre[i]);
        i += 1;
    }
    const visible_slice = try visible.toOwnedSlice();
    defer std.testing.allocator.free(visible_slice);
    const want = try text(std.testing.allocator, board, false, width, height);
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, visible_slice);
}

test "scoreboard links read by color, padding outside anchors" {
    // Links carry no static underline (hover only); cell padding still
    // rides outside anchors so a hover underline stops at the text:
    // no anchor may close on a blank (padded-inside form `  </a>`).
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const page = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(page);
    var lines = std.mem.splitScalar(u8, page, '\n');
    var anchors: usize = 0;
    while (lines.next()) |line| {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, line, cursor, "</a>")) |end| {
            anchors += 1;
            try std.testing.expect(end > 0);
            try std.testing.expect(line[end - 1] != ' ');
            cursor = end + 1;
        }
    }
    try std.testing.expect(anchors > 0);
    try expectVisiblePreText(page, board, null, null);
}

test "scoreHtml art rows stay pos-indexed and unlinked" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "9",
                .name = "PHI at NYM",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "1", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = true },
                    .{ .id = "2", .name = "New York Mets", .abbreviation = "NYM", .score = "3", .winner = false },
                },
            },
        },
    };
    const page = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(page);
    // Both participants link on their own row, in positional order: the
    // first team link after the game anchor must be PHI's, not NYM's.
    const game_at = std.mem.indexOf(u8, page, "id=\"game-9\"").?;
    const phi_at = std.mem.indexOf(u8, page, "<a href=\"/mlb/PHI\">PHI</a>").?;
    const nym_at = std.mem.indexOf(u8, page, "<a href=\"/mlb/NYM\">NYM</a>").?;
    try std.testing.expect(game_at < phi_at);
    try std.testing.expect(phi_at < nym_at);
    // Mark rows carry art, never links: the art's first line is escaped
    // verbatim. With PHI vs NYM marks present the marks may sit side by
    // side on one line; that line must still be link-free.
    const mark = core.art.teamArt("mlb", "PHI", .xs).?;
    const first_line = mark[0..std.mem.indexOfScalar(u8, mark, '\n').?];
    if (core.art.teamArt("mlb", "NYM", .xs)) |_| {
        if (core.art.teamArtColor("mlb", "PHI", .xs)) |_| {
            // Colored marks: SGR becomes rgb spans, never raw escapes,
            // and art rows stay link-free (spans only, no anchors).
            try std.testing.expect(std.mem.indexOf(u8, page, "rgb(") != null);
            var lines = std.mem.splitScalar(u8, page, '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, "rgb(") != null) {
                    try std.testing.expect(std.mem.indexOf(u8, line, "<a href") == null);
                }
            }
        } else {
            // Mono marks: art row(s) must escape the mark without anchors.
            try std.testing.expect(std.mem.indexOf(u8, page, first_line) != null);
            var lines = std.mem.splitScalar(u8, page, '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, first_line) != null) {
                    try std.testing.expect(std.mem.indexOf(u8, line, "<a href") == null);
                }
            }
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try expectVisiblePreText(page, board, null, null);
    _ = try std.unicode.Utf8View.init(page);
}

test "scoreHtml skips the color twin when no team has color art" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{.{
            .id = "1",
            .name = "Away at Home",
            .starts_at = "2026-09-06T17:00Z",
            .state = "post",
            .status = "Final",
            .participants = &.{
                .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
            },
        }},
    };
    // Gate fires: neither fixture abbr ships a color sidecar.
    try std.testing.expect(!boardHasColorArt(board, board.games.len));
    // The twin carries nothing the linkifier would read: stripping SGR
    // from the color render reproduces the mono body, so reusing the
    // mono body as the twin is byte-identical for this board.
    const mono = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(mono);
    const colored = try text(std.testing.allocator, board, true, null, null);
    defer std.testing.allocator.free(colored);
    var stripped: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stripped.deinit();
    try stripAnsi(&stripped.writer, colored);
    const stripped_slice = try stripped.toOwnedSlice();
    defer std.testing.allocator.free(stripped_slice);
    try std.testing.expectEqualStrings(mono, stripped_slice);
    // Fast-path page: no rgb spans, no escapes, same visible text.
    const page = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "rgb(") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/1\" id=\"game-1\">") != null);
    try expectVisiblePreText(page, board, null, null);
    _ = try std.unicode.Utf8View.init(page);
}

test "scoreHtml narrow width keeps links and layout" {
    const board = testBoard();
    const page = try scoreHtml(std.testing.allocator, board, 40, 2);
    defer std.testing.allocator.free(page);
    // Width 40 clamps to the classic 52-wide box; height 2 shows two
    // games plus the `+1 more` trailer with no link.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/1\" id=\"game-1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/2\" id=\"game-2\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"game-3\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "+1 more") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    try expectVisiblePreText(page, board, 40, 2);
}

test "page style is plaintext: no buttons, pre always scrolls" {
    try std.testing.expect(std.mem.indexOf(u8, page_style, "width=device-width") == null); // head, not style
    // Plaintext nav: bare inline links, never button chrome.
    try std.testing.expect(std.mem.indexOf(u8, page_style, "min-height:44px") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "border:1px") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "border-radius") == null);
    // The page must never scroll sideways: output is borderless, so pre
    // wraps and narrow screens get a smaller face instead of a scrollbar
    // (the frame era scrolled with pre + overflow-x).
    try std.testing.expect(std.mem.indexOf(u8, page_style, "white-space:pre-wrap;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "overflow-x:auto") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "max-width:480px") != null);
    // Theme rides on CSS vars; the toggle flips data-theme + localStorage.
    try std.testing.expect(std.mem.indexOf(u8, page_style, "--bg") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "data-theme") != null);
}

test "footer nav ends with the theme toggle on every page" {
    const board: domain.Scoreboard = .{ .league = "mlb", .league_name = "MLB", .date = "2026-09-06", .source = "test", .games = &.{} };
    const scoreboard = try scoreHtml(std.testing.allocator, board, null, null);
    defer std.testing.allocator.free(scoreboard);
    try std.testing.expect(std.mem.indexOf(u8, scoreboard, "light/dark") != null);
    try std.testing.expect(std.mem.indexOf(u8, scoreboard, "sprtsTheme()") != null);
    try std.testing.expect(std.mem.indexOf(u8, scoreboard, "localStorage") != null);
    // First visits without a stored choice follow the OS theme.
    try std.testing.expect(std.mem.indexOf(u8, scoreboard, "prefers-color-scheme") != null);
    // Every page head links the favicon and serves valid SVG for it.
    try std.testing.expect(std.mem.indexOf(u8, scoreboard, "rel=\"icon\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, favicon_svg, "<svg "));
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "</svg>") != null);
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "<script") == null);
    // Pixel mark, not a font glyph: chunky polygons with crisp edges.
    // The favicon carries the wordmark's notched `s` on a sharp dark tile.
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "shape-rendering=\"crispEdges\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "<polygon") != null);
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "<rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, favicon_svg, "<text") == null);
    // Wordmark variants: dark surfaces get light ink and vice versa, no
    // fonts anywhere, theme swap rides the data-theme CSS classes.
    try std.testing.expect(std.mem.indexOf(u8, logo_dark_svg, "#e6ebe7") != null);
    try std.testing.expect(std.mem.indexOf(u8, logo_light_svg, "#1c2420") != null);
    try std.testing.expect(std.mem.indexOf(u8, logo_dark_svg, "viewBox=\"-10 -10 210 70\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, logo_light_svg, "font") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "logo-light") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_style, "logo-dark") != null);
    const err = try errorBody(std.testing.allocator, "nope", .html);
    defer std.testing.allocator.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "light/dark") != null);
}

fn expectAlignedTable(output: []const u8) !void {
    // Every table line (rules and rows) must share one display width, or
    // the right border drifts. Byte length is the wrong check: one box
    // rule is 3 bytes per column. Widths here count columns per code
    // point (Latin and box characters are narrow, astral pair output
    // counts wide). Header, hint, and navigation lines live outside the
    // table and are skipped.
    var width: ?usize = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != 0xE2) continue;
        const w = displayWidth(line);
        if (width) |first| {
            try std.testing.expectEqual(first, w);
        } else {
            width = w;
        }
        count += 1;
    }
    try std.testing.expect(count > 0);
}

/// Mid rules (`├`) in a rendered home page. The home frame is quiet by
/// design: exactly 2 (LIVE block close, frame close). A per-game or
/// per-league rule would push this past 2 and fail the caller.
fn countRules(output: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "├")) n += 1;
    }
    return n;
}

/// Every rendered line fits its frame: no row may exceed the frame
/// width, or it wraps on narrow screens and the box "breaks". Frame
/// lines start with a 3-byte box glyph; hint/nav lines outside the
/// table are skipped. Callers pass the expected frame width.
fn expectNoBrokenLines(output: []const u8, frame_width: usize) !void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != 0xE2) continue;
        try std.testing.expect(displayWidth(line) <= frame_width);
        count += 1;
    }
    try std.testing.expect(count > 0);
}

fn displayWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            w += 1;
            i += 1;
        } else if (b & 0xE0 == 0xC0) {
            w += 1;
            i += 2;
        } else if (b & 0xF0 == 0xE0) {
            w += 1;
            i += 3;
        } else {
            w += 2;
            i += 4;
        }
    }
    return w;
}

test "home table rows align with the frame" {
    var results: [core.leagues.all.len]provider.LeagueResult = undefined;
    for (&core.leagues.all, 0..) |*league, i| results[i] = .{ .league = league };
    const output = try homeLive(std.testing.allocator, false, "example.test", &results, "2026-09-06", false);
    defer std.testing.allocator.free(output);
    try expectAlignedTable(output);
    try expectNoBrokenLines(output, 52);
    try std.testing.expect(countRules(output) == 0);
}

test "home groups live games, then today, then idle leagues" {
    const live_board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "in",
                .status = "Top 7th",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "0", .winner = false, .home_away = "away" },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "3", .winner = true, .home_away = "home" },
                },
            },
        },
    };
    const today_board: domain.Scoreboard = .{
        .league = "nba",
        .league_name = "NBA",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "2",
                .name = "Third at Fourth",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "7:05 PM ET",
                .participants = &.{
                    .{ .id = "c", .name = "Third", .abbreviation = "TRD", .score = "", .winner = false },
                    .{ .id = "d", .name = "Fourth", .abbreviation = "FRT", .score = "", .winner = false },
                },
            },
        },
    };
    const results = [_]provider.LeagueResult{
        .{ .league = core.leagues.find("mlb").?, .board = live_board },
        .{ .league = core.leagues.find("nba").?, .board = today_board },
        .{ .league = core.leagues.find("nfl").? },
    };
    const output = try homeLive(std.testing.allocator, false, "example.test", &results, "2026-09-06", false);
    defer std.testing.allocator.free(output);
    const live_at = std.mem.indexOf(u8, output, "LIVE NOW").?;
    const nba_at = std.mem.indexOf(u8, output, "NBA").?;
    const leagues_at = std.mem.indexOf(u8, output, "ALL LEAGUES").?;
    try std.testing.expect(live_at < nba_at);
    try std.testing.expect(nba_at < leagues_at);
    // Empty-abbr duels name their sides: single-named bouts show the
    // known fighter, fully nameless bouts fall back to the game name.
    const ufc_board: domain.Scoreboard = .{
        .league = "ufc",
        .league_name = "UFC",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "9",
                .name = "Contender Series",
                .starts_at = "2026-09-06T23:00Z",
                .state = "pre",
                .status = "9/8 - 7:00 PM EDT",
                .participants = &.{
                    .{ .id = "x", .name = "Colton Loud", .abbreviation = "", .score = "", .winner = false },
                    .{ .id = "y", .name = "Christian Natividad", .abbreviation = "", .score = "", .winner = false },
                },
            },
        },
    };
    const ufc_line = try gameLine(std.testing.allocator, core.leagues.find("ufc").?, ufc_board.games[0], 3, 3);
    defer std.testing.allocator.free(ufc_line.?);
    // Athlete sides join with " v "; records stay out of the line.
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, " v ") != null);
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, " v ") != null);
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, "Colton Loud") != null);
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, "Christian Natividad") != null);
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, "9/8") != null);
    try std.testing.expect(std.mem.indexOf(u8, ufc_line.?, "2026") == null);
    // One known abbreviation: abbr side duels the named side.
    const half_board: domain.Scoreboard = .{
        .league = "ufc",
        .league_name = "UFC",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "8",
                .name = "Contender Series",
                .starts_at = "2026-09-06T23:00Z",
                .state = "pre",
                .status = "9/8 - 7:00 PM EDT",
                .participants = &.{
                    .{ .id = "x", .name = "Colton Loud", .abbreviation = "LOUD", .score = "", .winner = false },
                    .{ .id = "y", .name = "Christian Natividad", .abbreviation = "", .score = "", .winner = false },
                },
            },
        },
    };
    const half_line = try gameLine(std.testing.allocator, core.leagues.find("ufc").?, half_board.games[0], 3, 4);
    defer std.testing.allocator.free(half_line.?);
    try std.testing.expect(std.mem.indexOf(u8, half_line.?, "LOUD") != null);
    try std.testing.expect(std.mem.indexOf(u8, half_line.?, "Christian Natividad") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mlb AWY   0 @ HME   3 ✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nba TRD     @ FRT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nfl") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "example.test/mlb") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "example.test/docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, repo_url) != null);
    try expectAlignedTable(output);
    // Whitespace: a blank line separates each section, and zero
    // mid rules exist — sections breathe through air, never grid.
    // The frame opens once (top rule) and never closes with borders,
    // so dense days stay quiet instead of rendering a rule per section.
    try std.testing.expect(countRules(output) == 0);
    // No line exceeds the 52-column frame, so nothing wraps and the box
    // cannot "break" on narrow screens.
    try expectNoBrokenLines(output, 52);

    const page = try homeHtmlLive(std.testing.allocator, "example.test", &results, "2026-09-06", false);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/1\">") != null);
    // Granular team spans inside the game link: each side links its team.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/AWY\">AWY</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/HME\">HME</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nba?date=2026-09-06\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nfl?date=2026-09-06\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "github") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
}

test "sanitizeHost falls back on hostile input" {
    try std.testing.expectEqualStrings("localhost:8080", sanitizeHost(null));
    try std.testing.expectEqualStrings("sprts.horv.co", sanitizeHost("sprts.horv.co"));
    try std.testing.expectEqualStrings("localhost:8080", sanitizeHost("evil\"><script>"));
    try std.testing.expectEqualStrings("localhost:8080", sanitizeHost(""));
}

test "scoreboard table rows align with the frame" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    try expectAlignedTable(output);
}

test "text renderer prints both marks side by side" {
    const home_mark = core.art.teamArt("mlb", "PHI", .xs).?;
    const home_first = home_mark[0..std.mem.indexOfScalar(u8, home_mark, '\n').?];
    const away_mark = core.art.teamArt("mlb", "NYM", .xs).?;
    const away_first = away_mark[0..std.mem.indexOfScalar(u8, away_mark, '\n').?];
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "PHI at NYM",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "1", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = true },
                    .{ .id = "2", .name = "New York Mets", .abbreviation = "NYM", .score = "3", .winner = false },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    // Both first rows land on the same output line: horizontal card.
    var found = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, home_first) != null and
            std.mem.indexOf(u8, line, away_first) != null) found = true;
    }
    try std.testing.expect(found);
    _ = try std.unicode.Utf8View.init(output);
}

test "text renderer colors marks and strips them with color=false" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "PHI at NYY",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "1", .name = "Philadelphia Phillies", .abbreviation = "PHI", .score = "5", .winner = true },
                    .{ .id = "2", .name = "New York Yankees", .abbreviation = "NYY", .score = "3", .winner = false },
                },
            },
        },
    };
    const colored = try text(std.testing.allocator, board, true, null, null);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[38;5;") != null);
    const plain = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    // No line exceeds the page: ragged rows still fit their columns.
    try expectNoBrokenLines(plain, 52);
    // Stripping SGR from the colored render reproduces the mono render.
    var stripped: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stripped.deinit();
    try stripAnsi(&stripped.writer, colored);
    const stripped_slice = try stripped.toOwnedSlice();
    defer std.testing.allocator.free(stripped_slice);
    try std.testing.expectEqualStrings(plain, stripped_slice);
}

fn stripAnsi(w: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            var j = i + 2;
            while (j < s.len and s[j] != 'm') : (j += 1) {}
            i = if (j < s.len) j + 1 else s.len;
            continue;
        }
        try w.writeByte(s[i]);
        i += 1;
    }
}

fn expectAlignedTableColored(output: []const u8) !void {
    // Same frame-alignment check as expectAlignedTable, but ANSI-aware:
    // strip SGR runs first so colored marks measure by visible cells.
    var stripped: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stripped.deinit();
    try stripAnsi(&stripped.writer, output);
    const slice = try stripped.toOwnedSlice();
    defer std.testing.allocator.free(slice);
    try expectAlignedTable(slice);
}

test "text renderer prints no mark for teams without one" {
    const mark = core.art.teamArt("mlb", "PHI", .xs).?;
    const first_line = mark[0..std.mem.indexOfScalar(u8, mark, '\n').?];
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, first_line) == null);
}

test "athlete-style rows show the full name with an empty abbr cell" {
    const board: domain.Scoreboard = .{
        .league = "f1",
        .league_name = "F1",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Pirelli Italian Grand Prix",
                .starts_at = "2026-09-06T10:30Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "5498", .name = "Charles Leclerc", .abbreviation = "", .score = "#1", .winner = false },
                    .{ .id = "868", .name = "Lewis Hamilton", .abbreviation = "", .score = "#2", .winner = true },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Charles Leclerc") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Lewis Hamilton") != null);
    // Empty abbr cell + separator shift the name over, never truncated.
    var abbr_ellipsis = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Leclerc") != null or
            std.mem.indexOf(u8, line, "Hamilton") != null)
        {
            abbr_ellipsis = abbr_ellipsis or (std.mem.indexOf(u8, line, "…") != null);
        }
    }
    try std.testing.expect(!abbr_ellipsis);
    try expectAlignedTable(output);
}

test "records render after the score in team rows" {
    const board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false, .record = "69-74" },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, " (69-74)") != null);
    try expectAlignedTable(output);
}

test "multibyte names keep the frame aligned" {
    const board: domain.Scoreboard = .{
        .league = "f1",
        .league_name = "F1",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Pirelli Italian Grand Prix",
                .starts_at = "2026-09-06T10:30Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "27", .name = "Nico Hülkenberg", .abbreviation = "", .score = "#7", .winner = false },
                },
            },
        },
    };
    const output = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hülkenberg") != null);
    try expectAlignedTable(output);
}

fn testBoard() domain.Scoreboard {
    return .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "a", .name = "Away", .abbreviation = "AWY", .score = "2", .winner = false },
                    .{ .id = "h", .name = "Home", .abbreviation = "HME", .score = "5", .winner = true },
                },
            },
            .{
                .id = "2",
                .name = "Second at Third",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "c", .name = "Second", .abbreviation = "SEC", .score = "", .winner = false },
                    .{ .id = "d", .name = "Third", .abbreviation = "THI", .score = "", .winner = false },
                },
            },
            .{
                .id = "3",
                .name = "Fourth at Fifth",
                .starts_at = "2026-09-06T21:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{
                    .{ .id = "e", .name = "Fourth", .abbreviation = "FOU", .score = "", .winner = false },
                    .{ .id = "f", .name = "Fifth", .abbreviation = "FIF", .score = "", .winner = false },
                },
            },
        },
    };
}

test "text renderer honors an explicit width" {
    const board = testBoard();
    const wide = try text(std.testing.allocator, board, false, 80, null);
    defer std.testing.allocator.free(wide);
    // Heading first, then an 80-wide separator rule.
    var lines = std.mem.splitScalar(u8, wide, '\n');
    try std.testing.expectEqualStrings("MLB  2026-09-06 ET", lines.next().?);
    const rule = lines.next().?;
    try std.testing.expectEqual(displayWidth(rule), 80);
    _ = try std.unicode.Utf8View.init(wide);

    // Narrow requests never shrink below the classic 52-wide page.
    const narrow = try text(std.testing.allocator, board, false, 40, null);
    defer std.testing.allocator.free(narrow);
    var narrow_lines = std.mem.splitScalar(u8, narrow, '\n');
    try std.testing.expectEqualStrings("MLB  2026-09-06 ET", narrow_lines.next().?);
    try std.testing.expectEqual(displayWidth(narrow_lines.next().?), 52);
}

test "text renderer caps games with height and counts the rest" {
    const board = testBoard();
    const capped = try text(std.testing.allocator, board, false, null, 2);
    defer std.testing.allocator.free(capped);
    try std.testing.expect(std.mem.indexOf(u8, capped, "Final") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "+1 more") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "Fourth at Fifth") == null);
    _ = try std.unicode.Utf8View.init(capped);

    const all = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "more") == null);
}

test "scoreboard text heading names the zone" {
    const board = testBoard();
    const et = try textWithZone(std.testing.allocator, board, false, null, null, .et);
    defer std.testing.allocator.free(et);
    try std.testing.expect(std.mem.indexOf(u8, et, "MLB  2026-09-06 ET") != null);
    try expectNoBrokenLines(et, 52);

    const utc = try textWithZone(std.testing.allocator, board, false, null, null, .utc);
    defer std.testing.allocator.free(utc);
    try std.testing.expect(std.mem.indexOf(u8, utc, "MLB  2026-09-06 UTC") != null);

    const fixed = try textWithZone(std.testing.allocator, board, false, null, null, .{ .fixed = -300 });
    defer std.testing.allocator.free(fixed);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "MLB  2026-09-06 UTC-5") != null);

    // ET-default wrapper keeps the label so unwired callers never go bare.
    const plain = try text(std.testing.allocator, board, false, null, null);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "MLB  2026-09-06 ET") != null);
}

test "scoreHtml title and heading name the zone" {
    const board = testBoard();
    const page = try scoreHtmlWithZone(std.testing.allocator, board, null, null, .et);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "MLB scores 2026-09-06 ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "MLB  2026-09-06 ET") != null);

    const utc_page = try scoreHtmlWithZone(std.testing.allocator, board, null, null, .utc);
    defer std.testing.allocator.free(utc_page);
    try std.testing.expect(std.mem.indexOf(u8, utc_page, "MLB scores 2026-09-06 UTC") != null);
}

test "home text heading and one-lines name the zone" {
    var results: [core.leagues.all.len]provider.LeagueResult = undefined;
    for (&core.leagues.all, 0..) |*league, i| results[i] = .{ .league = league };
    const live = try homeLiveWithZone(std.testing.allocator, false, "example.test", &results, "2026-09-06", false, .et);
    defer std.testing.allocator.free(live);
    try std.testing.expect(std.mem.indexOf(u8, live, "sprts  2026-09-06 ET") != null);

    const utc_live = try homeLiveWithZone(std.testing.allocator, false, "example.test", &results, "2026-09-07", false, .utc);
    defer std.testing.allocator.free(utc_live);
    try std.testing.expect(std.mem.indexOf(u8, utc_live, "sprts  2026-09-07 UTC") != null);

    const board = testBoard();
    const mlb = core.leagues.find("mlb").?;
    const one_sections = [_]provider.LeagueResult{.{ .league = mlb, .board = board }};
    const lines = try homeOneLineWithZone(std.testing.allocator, &one_sections, false, .et);
    defer std.testing.allocator.free(lines);
    try std.testing.expect(std.mem.indexOf(u8, lines, "mlb 9/6 ET") != null);
    const utc_lines = try homeOneLineWithZone(std.testing.allocator, &one_sections, false, .utc);
    defer std.testing.allocator.free(utc_lines);
    try std.testing.expect(std.mem.indexOf(u8, utc_lines, "mlb 9/6 UTC") != null);
}

test "?tz= wiring flips day and label, invalid is ignored" {
    const arena = std.testing.allocator;
    // 2026-09-07T00:00Z: still Sep 6 in ET, already Sep 7 in UTC.
    const epoch: i64 = 1788739200;
    const et_zone = tz.zoneFromTarget("/mlb");
    try std.testing.expect(et_zone == .et);
    const et_day = try tz.resolveDay(arena, null, epoch, et_zone);
    defer arena.free(et_day);
    try std.testing.expectEqualStrings("2026-09-06", et_day);
    const et_label = try tz.labelFor(arena, et_day, et_zone);
    defer arena.free(et_label);
    try std.testing.expectEqualStrings("9/6 ET", et_label);

    const utc_zone = tz.zoneFromTarget("/mlb?tz=utc");
    try std.testing.expect(utc_zone == .utc);
    const utc_day = try tz.resolveDay(arena, null, epoch, utc_zone);
    defer arena.free(utc_day);
    try std.testing.expectEqualStrings("2026-09-07", utc_day);
    const utc_label = try tz.labelFor(arena, utc_day, utc_zone);
    defer arena.free(utc_label);
    try std.testing.expectEqualStrings("9/7 UTC", utc_label);

    // Invalid ?tz= is ignored: ET default stands for both day and label.
    const bogus_zone = tz.zoneFromTarget("/mlb?tz=bogus");
    try std.testing.expect(bogus_zone == .et);
    const bogus_day = try tz.resolveDay(arena, null, epoch, bogus_zone);
    defer arena.free(bogus_day);
    try std.testing.expectEqualStrings("2026-09-06", bogus_day);

    // Explicit ?date wins verbatim in every zone.
    const explicit = try tz.resolveDay(arena, "2026-01-01", epoch, .utc);
    defer arena.free(explicit);
    try std.testing.expectEqualStrings("2026-01-01", explicit);
}

test "live home idle leagues link today with the date" {
    // Idle league only: no board, so it lands in the ALL LEAGUES rows.
    const results = [_]provider.LeagueResult{
        .{ .league = core.leagues.find("nfl").? },
    };
    const day = "2026-09-06";
    const page = try homeHtmlLive(std.testing.allocator, "example.test", &results, day, false);
    defer std.testing.allocator.free(page);
    // Same spelling as the static dated home: today spelled out.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nfl?date=2026-09-06\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nfl\">") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    // Dateless fallback is unchanged: static home without a day stays bare.
    const bare = try homeHtml(std.testing.allocator);
    defer std.testing.allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "<a href=\"/nfl\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "?date=") == null);
    // Hostile day text stays escaped in the shared spelling, both homes.
    const hostile = "2026-09-06&<>\"'";
    const evil_live = try homeHtmlLive(std.testing.allocator, "example.test", &results, hostile, true);
    defer std.testing.allocator.free(evil_live);
    try std.testing.expect(std.mem.indexOf(u8, evil_live, "/nfl?date=2026-09-06&amp;&lt;&gt;&quot;&#39;") != null);
    try std.testing.expect(std.mem.indexOf(u8, evil_live, hostile) == null);
    try std.testing.expect(std.mem.indexOf(u8, evil_live, "\x1b[") == null);
    const evil_static = try homeHtmlDay(std.testing.allocator, hostile);
    defer std.testing.allocator.free(evil_static);
    try std.testing.expect(std.mem.indexOf(u8, evil_static, "/nfl?date=2026-09-06&amp;&lt;&gt;&quot;&#39;") != null);
    try std.testing.expect(std.mem.indexOf(u8, evil_static, hostile) == null);
    _ = try std.unicode.Utf8View.init(evil_live);
}

test "home html game lines use sibling anchors, never nested" {
    const live_board: domain.Scoreboard = .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "401816854",
                .name = "Away at Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "in",
                .status = "Bot 7th",
                .participants = &.{
                    .{ .id = "a", .name = "Cleveland Guardians", .abbreviation = "CLE", .score = "9", .winner = false, .home_away = "away" },
                    .{ .id = "h", .name = "Baltimore Orioles", .abbreviation = "BAL", .score = "5", .winner = false, .home_away = "home" },
                },
            },
        },
    };
    const today_board: domain.Scoreboard = .{
        .league = "nba",
        .league_name = "NBA",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "2",
                .name = "Third at Fourth",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "7:05 PM ET",
                .participants = &.{
                    .{ .id = "c", .name = "Third", .abbreviation = "TRD", .score = "", .winner = false },
                    .{ .id = "d", .name = "Fourth", .abbreviation = "FRT", .score = "", .winner = false },
                },
            },
        },
    };
    const results = [_]provider.LeagueResult{
        .{ .league = core.leagues.find("mlb").?, .board = live_board },
        .{ .league = core.leagues.find("nba").?, .board = today_board },
        .{ .league = core.leagues.find("nfl").? },
    };
    const page = try homeHtmlLive(std.testing.allocator, "example.test", &results, "2026-09-06", false);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    // Every game/team href from the nested layout is still present.
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/401816854\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/CLE\">CLE</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/mlb/BAL\">BAL</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nba/2\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nba/TRD\">TRD</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/nba/FRT\">FRT</a>") != null);
    // Same spans and footer/nav as before.
    try std.testing.expect(std.mem.indexOf(u8, page, "<span class=\"live\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<span class=\"upcoming\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/docs\">docs</a>") != null);
    // No game line nests anchors: on each <pre> line an <a *> open must
    // always close before the next <a *> opens (depth never exceeds 1).
    const open = std.mem.indexOf(u8, page, "<pre>").?;
    const close = std.mem.indexOf(u8, page, "</pre>").?;
    const pre = page[open + "<pre>".len .. close];
    var pre_lines = std.mem.splitScalar(u8, pre, '\n');
    var game_lines: usize = 0;
    while (pre_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "401816854") != null or std.mem.indexOf(u8, line, "CLE") != null) game_lines += 1;
        var depth: usize = 0;
        var j: usize = 0;
        while (j < line.len) {
            const open_at = std.mem.indexOf(u8, line[j..], "<a ");
            const close_at = std.mem.indexOf(u8, line[j..], "</a>");
            if (open_at == null and close_at == null) break;
            if (open_at != null and (close_at == null or open_at.? < close_at.?)) {
                try std.testing.expectEqual(@as(usize, 0), depth);
                depth += 1;
                j += open_at.? + "<a ".len;
            } else {
                try std.testing.expectEqual(@as(usize, 1), depth);
                depth -= 1;
                j += close_at.? + "</a>".len;
            }
        }
        try std.testing.expectEqual(@as(usize, 0), depth);
    }
    try std.testing.expect(game_lines > 0);
    // Visible text unchanged: stripping tags + decoding entities still
    // shows the same game lines as the text renderer.
    var visible: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer visible.deinit();
    var i: usize = 0;
    while (i < pre.len) {
        if (pre[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, pre, i, '>') orelse return error.TestUnexpectedResult;
            i = end + 1;
            continue;
        }
        if (pre[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, pre, i, ';') orelse return error.TestUnexpectedResult;
            const entity = pre[i .. semi + 1];
            if (std.mem.eql(u8, entity, "&amp;")) {
                try visible.writer.writeByte('&');
            } else if (std.mem.eql(u8, entity, "&lt;")) {
                try visible.writer.writeByte('<');
            } else if (std.mem.eql(u8, entity, "&gt;")) {
                try visible.writer.writeByte('>');
            } else if (std.mem.eql(u8, entity, "&quot;")) {
                try visible.writer.writeByte('"');
            } else if (std.mem.eql(u8, entity, "&#39;")) {
                try visible.writer.writeByte('\'');
            } else return error.TestUnexpectedResult;
            i = semi + 1;
            continue;
        }
        try visible.writer.writeByte(pre[i]);
        i += 1;
    }
    const visible_slice = try visible.toOwnedSlice();
    defer std.testing.allocator.free(visible_slice);
    try std.testing.expect(std.mem.indexOf(u8, visible_slice, "mlb CLE   9 @ BAL   5") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible_slice, "Bot 7th") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible_slice, "nba TRD     @ FRT") != null);
    _ = try std.unicode.Utf8View.init(page);
}


test "tmp debug narrow" {
    const board = testBoard();
    const page = try scoreHtml(std.testing.allocator, board, 40, 2);
    defer std.testing.allocator.free(page);
    std.debug.print("\n=====PAGE=====\n{s}\n=====END=====\n", .{page});
}



