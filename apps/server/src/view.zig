//! Shared view-layer section composers + format emitters (phases 0-1).
//!
//! Target: every view module (`render`, `detail_view`, `team_view`,
//! `standings_view`, `digest`) composes plain strings here and emits them
//! through `emitText`/`emitHtml`, which reuse the `table.zig`/`render.zig`
//! primitives. Composers return plain strings with `color = false`; color
//! wraps at emit time, never inside. No per-view IR, no JSON changes.
//!
//! Phase 0: `Section` + thin `emitText`/`emitHtml` wrappers. No callers.
//! Phase 1: standings `entryRows`/`hasPoints` (verbatim move from
//! `standings_view.zig`); standings text/HTML rewire to it.

const std = @import("std");
const core = @import("sprts_core");
const standings = core.standings;
const render = @import("render.zig");
const table = @import("table.zig");

/// One composed section: a heading plus pre-composed rows (`color =
/// false`). Emitters fit/pad via the shared primitives; composers never
/// emit ANSI.
pub const Section = struct {
    heading: []const u8,
    rows: []const []const u8,
};

/// Text emitter: dim heading, one separator rule, then one fitted line
/// per row. Thin wrapper over `table.writeLine`/`table.writeSeparator`.
pub fn emitText(
    allocator: std.mem.Allocator,
    section: Section,
    cols: usize,
    color: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try table.writeLine(w, section.heading, cols, "2", color);
    try table.writeSeparator(w, cols);
    for (section.rows) |row| {
        try table.writeLine(w, row, cols, null, color);
    }
    return out.toOwnedSlice();
}

/// HTML emitter: page head titled by the heading, the heading as `<h1>`,
/// one escaped line per row, then the shared page close. Thin wrapper
/// over `render.pageHead`/`render.writeHtmlH1`/`render.writeHtmlLine`/
/// `render.closePageWithNav`.
pub fn emitHtml(
    allocator: std.mem.Allocator,
    section: Section,
    cols: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try render.pageHead(w, section.heading);
    try render.writeHtmlH1(w, allocator, section.heading, cols, "dim");
    for (section.rows) |row| {
        try render.writeHtmlLine(w, allocator, row, cols, null, null);
    }
    try w.writeAll("</pre><nav>");
    try render.closePageWithNav(w);
    return out.toOwnedSlice();
}

/// True when at least one entry anywhere carries points (hockey, soccer).
/// Verbatim move of `standings_view.countPoints`.
pub fn hasPoints(st: standings.LeagueStandings) bool {
    for (st.groups) |group| {
        for (group.entries) |entry| {
            if (entry.points != null) return true;
        }
    }
    return false;
}

/// One composed standings entry row (`color = false`, trailing blanks
/// trimmed, no newline). Verbatim move of `standings_view.writeEntryRow`'s
/// composition; the caller writes the row plus `'\n'`.
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
/// slice itself (see `freeRows`).
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

/// Free an `entryRows` result.
pub fn freeRows(allocator: std.mem.Allocator, rows: [][]u8) void {
    for (rows) |row| allocator.free(row);
    allocator.free(rows);
}

test "view emitText behaves like the table primitives" {
    const rows = [_][]const u8{ "BOS  Boston Bruins 38-14-9   85", "BUF  Buffalo Sabres 30-25   68" };
    const section: Section = .{ .heading = "NHL standings  2026", .rows = &rows };
    const got = try emitText(std.testing.allocator, section, 52, false);
    defer std.testing.allocator.free(got);
    var want: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer want.deinit();
    try table.writeLine(&want.writer, section.heading, 52, "2", false);
    try table.writeSeparator(&want.writer, 52);
    for (rows) |row| try table.writeLine(&want.writer, row, 52, null, false);
    const expected = try want.toOwnedSlice();
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, got);
    _ = try std.unicode.Utf8View.init(got);
}

test "view emitHtml behaves like the render primitives" {
    const rows = [_][]const u8{"BOS  Boston Bruins 38-14-9   85"};
    const section: Section = .{ .heading = "NHL standings", .rows = &rows };
    const got = try emitHtml(std.testing.allocator, section, 52);
    defer std.testing.allocator.free(got);
    var want: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer want.deinit();
    try render.pageHead(&want.writer, section.heading);
    try render.writeHtmlH1(&want.writer, std.testing.allocator, section.heading, 52, "dim");
    for (rows) |row| try render.writeHtmlLine(&want.writer, std.testing.allocator, row, 52, null, null);
    try want.writer.writeAll("</pre><nav>");
    try render.closePageWithNav(&want.writer);
    const expected = try want.toOwnedSlice();
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(got);
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
    defer freeRows(std.testing.allocator, rows);
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
    defer freeRows(std.testing.allocator, rows);
    try std.testing.expect(std.mem.indexOf(u8, rows[0], "80-63") != null);
}
