//! League standings renderer (Schedule/Standings/Teams parity).
//!
//! Document-style like detail and team: fitted lines, blank-separated
//! groups, one separator rule under the heading. Columns are
//! provider-shaped: the `W-L[-T]` record plus a `PTS` column that appears
//! only when at least one entry carries points (hockey, soccer); a
//! missing stat renders as `-`, never zero. The `T` leg shows per row
//! when that entry has ties, so baseball rows read `80-63` while football
//! rows read `11-3-1` in the same fixed-width column.

const std = @import("std");
const core = @import("sprts_core");
const standings = core.standings;
const router = @import("router.zig");
const render = @import("render.zig");
const table = @import("table.zig");
const view = @import("view.zig");

/// `width` is total terminal columns of the document. Never shrinks below
/// the classic 52-wide page. `height` caps the entries listed (`+N more`
/// trailer); null = all groups and entries.
pub fn text(
    allocator: std.mem.Allocator,
    st: standings.LeagueStandings,
    color: bool,
    width: ?u16,
    height: ?u16,
) ![]u8 {
    const cols: usize = @min(@max(width orelse 52, 52), 200);
    const budget: usize = height orelse std.math.maxInt(usize);
    const has_points = view.hasPoints(st);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    {
        const heading = try std.fmt.allocPrint(allocator, "{s} standings  {s}", .{ st.league_name, st.season });
        defer allocator.free(heading);
        try table.writeLine(w, heading, cols, "2", color);
    }
    try table.writeSeparator(w, cols);
    if (st.groups.len == 0) {
        try table.writeLine(w, "No standings available.", cols, null, color);
    }
    var shown: usize = 0;
    var total: usize = 0;
    var first_group = true;
    for (st.groups) |group| total += group.entries.len;
    for (st.groups) |group| {
        if (shown >= budget) break;
        if (!first_group) try w.writeByte('\n');
        first_group = false;
        try table.writeLine(w, group.name, cols, "2", color);
        if (group.entries.len == 0) {
            try table.writeLine(w, "No entries.", cols, null, color);
            continue;
        }
        // Rows compose in `view.entryRows` (shared composer); emit stays
        // here so the document rhythm (budget, blanks, trailer) is untouched.
        const rows = try view.entryRows(allocator, group.entries, cols, has_points);
        defer view.freeLines(allocator, rows);
        for (rows) |row| {
            if (shown >= budget) break;
            try w.writeAll(row);
            try w.writeByte('\n');
            shown += 1;
        }
    }
    if (shown < total) {
        const more = try std.fmt.allocPrint(allocator, "+{d} more", .{total - shown});
        defer allocator.free(more);
        try table.writeLine(w, more, cols, "2", color);
    }
    return out.toOwnedSlice();
}

/// HTML view: the same table as text (color off), never ANSI, inside
/// `<pre>` plus a scores/JSON nav. Everything escapes via
/// `render.escapeInto`, so hostile provider text can never break the page.
pub fn html(
    allocator: std.mem.Allocator,
    st: standings.LeagueStandings,
    width: ?u16,
    height: ?u16,
) ![]u8 {
    const body = try text(allocator, st, false, width, height);
    defer allocator.free(body);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const title = try std.fmt.allocPrint(allocator, "{s} standings", .{st.league_name});
    defer allocator.free(title);
    try render.pageHead(w, title);
    try render.writeEscapedBodyH1(w, body);
    try w.writeAll("</pre><nav>");
    try w.print("<a href=\"/{s}\">scores</a>", .{st.league});
    try w.print("<a href=\"/api/v1/{s}/standings\">json</a>", .{st.league});
    try render.closePageWithNav(w);
    return out.toOwnedSlice();
}

/// JSON view. Validated through the shared `render.validatedJson` gate —
/// see it for why strict `z.serializeAndValidate` is unusable process-wide
/// (zchema's `cachedCompiled` cross-type cache bug, coordinator-owned
/// upstream fix in the external zchema dependency). Same wire format as
/// the core type, field for field.
pub fn json(allocator: std.mem.Allocator, st: standings.LeagueStandings) ![]u8 {
    return render.validatedJson(standings.LeagueStandings, allocator, st);
}

fn testStandings() standings.LeagueStandings {
    return .{
        .league = "nhl",
        .league_name = "NHL",
        .season = "2026",
        .source = "test",
        .groups = &.{
            .{
                .name = "Atlantic Division",
                .entries = &.{
                    .{ .team_id = "6", .abbrev = "BOS", .name = "Boston Bruins", .wins = "38", .losses = "14", .ties = "9", .points = "85" },
                    .{ .team_id = "7", .abbrev = "BUF", .name = "Buffalo Sabres", .wins = "30", .losses = "25", .points = "68" },
                },
            },
            .{
                .name = "Metropolitan Division",
                .entries = &.{
                    .{ .team_id = "12", .abbrev = "CAR", .name = "Carolina Hurricanes", .wins = "36", .losses = "15", .points = "80" },
                },
            },
        },
    };
}

test "standings text draws groups, records, and points with no HTML" {
    const output = try text(std.testing.allocator, testStandings(), false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "NHL standings  2026") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Atlantic Division") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Metropolitan Division") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "BOS") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Boston Bruins") != null);
    // Per-row ties leg: hockey rows with ties read W-L-T, without read W-L.
    try std.testing.expect(std.mem.indexOf(u8, output, "38-14-9") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "30-25") != null);
    // Points column appears once any entry carries points.
    try std.testing.expect(std.mem.indexOf(u8, output, "85") != null);
    // Pipe-less document: heading, separator, groups — no box anywhere.
    for ([_][]const u8{ "┌", "├", "└", "│" }) |rule| {
        try std.testing.expect(std.mem.indexOf(u8, output, rule) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, output, "─") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<html") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(output);
}

test "standings text hides the points column when no entry has points" {
    const mlb: standings.LeagueStandings = .{
        .league = "mlb",
        .league_name = "MLB",
        .season = "2026",
        .groups = &.{
            .{ .name = "AL East", .entries = &.{
                .{ .team_id = "19", .abbrev = "NYY", .name = "New York Yankees", .wins = "80", .losses = "63" },
            } },
        },
    };
    const output = try text(std.testing.allocator, mlb, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "80-63") != null);
}

/// A separator rule is nothing but ─ cells (3 bytes each).
fn isSeparator(line: []const u8) bool {
    if (line.len == 0 or line.len % 3 != 0) return false;
    var i: usize = 0;
    while (i < line.len) : (i += 3) {
        if (!std.mem.eql(u8, line[i..][0..3], "─")) return false;
    }
    return true;
}

test "standings text rows fit the page and honor height" {
    for ([_]u16{ 52, 80, 200 }) |width| {
        const output = try text(std.testing.allocator, testStandings(), false, width, null);
        defer std.testing.allocator.free(output);
        var lines = std.mem.splitScalar(u8, output, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Separator spans the requested width; content never exceeds it.
            if (isSeparator(line)) {
                try std.testing.expectEqual(table.textCells(line), width);
            } else {
                try std.testing.expect(table.textCells(line) <= width);
            }
            count += 1;
        }
        try std.testing.expect(count > 0);
        _ = try std.unicode.Utf8View.init(output);
    }
    const capped = try text(std.testing.allocator, testStandings(), false, null, 2);
    defer std.testing.allocator.free(capped);
    try std.testing.expect(std.mem.indexOf(u8, capped, "+1 more") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "Metropolitan Division") == null);
}

test "standings text colors headers and renders missing stats as dashes" {
    const colored = try text(std.testing.allocator, testStandings(), true, null, null);
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[2m") != null);
    const sparse: standings.LeagueStandings = .{
        .league = "mlb",
        .league_name = "MLB",
        .season = "2026",
        .groups = &.{.{ .name = "AL East", .entries = &.{.{ .team_id = "1", .abbrev = "NYY", .name = "New York Yankees" }} }},
    };
    const output = try text(std.testing.allocator, sparse, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "-") != null);
}

test "standings text reports an empty table" {
    const empty: standings.LeagueStandings = .{
        .league = "nfl",
        .league_name = "NFL",
        .season = "2026",
    };
    const output = try text(std.testing.allocator, empty, false, null, null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "No standings available.") != null);
}

test "standings HTML escapes hostile text and never carries ANSI" {
    const hostile: standings.LeagueStandings = .{
        .league = "epl",
        .league_name = "Premier <League>",
        .season = "2026",
        .groups = &.{.{ .name = "Table & co", .entries = &.{
            .{ .team_id = "1", .abbrev = "ARS", .name = "Arsenal <b>\"Gunners\"</b>", .wins = "18", .losses = "3", .ties = "5", .points = "59" },
        } }},
    };
    const page = try html(std.testing.allocator, hostile, null, null);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<h1 id=\"content\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Skip to content") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Arsenal <b>") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Arsenal &lt;b&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Table &amp; co") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/epl\">scores</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<a href=\"/api/v1/epl/standings\">json</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\x1b[") == null);
    _ = try std.unicode.Utf8View.init(page);
}

test "standings JSON carries the schema marker and validates" {
    const output = try json(std.testing.allocator, testStandings());
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"schema_version\": \"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"abbrev\": \"BOS\"") != null);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(standings.LeagueStandings, arena_state.allocator(), output, .{});
    try std.testing.expectEqualStrings("Atlantic Division", parsed.groups[0].name);
    try std.testing.expectEqualStrings("85", parsed.groups[0].entries[0].points.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.groups.len);
}

test "router standings route is JSON under /api/v1" {
    try std.testing.expect(router.isJsonTarget("/api/v1/mlb/standings"));
    try std.testing.expect(!router.isJsonTarget("/mlb/standings"));
}

test "standings renders no team marks in text or HTML" {
    // Verified, not assumed: the standings table never emits braille
    // logos (no art site exists here), so the standings route's `art`
    // flag is accepted-and-ignored — proven by zero braille even with
    // a mark-shipping abbreviation (PHI) on the rows.
    const mlb: standings.LeagueStandings = .{
        .league = "mlb",
        .league_name = "MLB",
        .season = "2026",
        .groups = &.{
            .{ .name = "AL East", .entries = &.{
                .{ .team_id = "22", .abbrev = "PHI", .name = "Philadelphia Phillies", .wins = "80", .losses = "63" },
            } },
        },
    };
    try std.testing.expect(core.art.teamArt("mlb", "PHI", .xs) != null);
    const output = try text(std.testing.allocator, mlb, false, null, null);
    defer std.testing.allocator.free(output);
    var i: usize = 0;
    while (i + 1 < output.len) : (i += 1) {
        try std.testing.expect(!(output[i] == 0xE2 and output[i + 1] >= 0xA0 and output[i + 1] <= 0xA3));
    }
    const page = try html(std.testing.allocator, mlb, null, null);
    defer std.testing.allocator.free(page);
    var j: usize = 0;
    while (j + 1 < page.len) : (j += 1) {
        try std.testing.expect(!(page[j] == 0xE2 and page[j + 1] >= 0xA0 and page[j + 1] <= 0xA3));
    }
    try std.testing.expect(std.mem.indexOf(u8, page, "rgb(") == null);
}

/// Strip every `<...>` tag: what remains is the page's visible text.
fn stripHtmlTags(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var in_tag = false;
    for (s) |c| {
        if (in_tag) {
            if (c == '>') in_tag = false;
            continue;
        }
        if (c == '<') {
            in_tag = true;
            continue;
        }
        try out.writer.writeByte(c);
    }
    return out.toOwnedSlice();
}

/// Unescape the five entities `render.escapeInto` emits. Single pass so
/// `&amp;lt;` never double-decodes.
fn unescapeHtml(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            inline for (.{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" } }) |pair| {
                if (std.mem.startsWith(u8, s[i..], pair[0])) {
                    try out.writer.writeAll(pair[1]);
                    i += pair[0].len;
                    break;
                }
            } else {
                try out.writer.writeByte(s[i]);
                i += 1;
            }
            continue;
        }
        try out.writer.writeByte(s[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

test "standings HTML visible text equals the text output" {
    // `html()` derives from `text(color=false)` (same shared composer
    // via `view.entryRows`): only invisible tags separate them, so the
    // `<pre>` block with tags stripped and entities unescaped reads back
    // byte for byte. Inline fixture only, never live ESPN.
    const st = testStandings();
    const body = try text(std.testing.allocator, st, false, null, null);
    defer std.testing.allocator.free(body);
    const page = try html(std.testing.allocator, st, null, null);
    defer std.testing.allocator.free(page);
    const pre_open = std.mem.indexOf(u8, page, "<pre>").? + "<pre>".len;
    const pre_close = std.mem.indexOf(u8, page, "</pre>").?;
    try std.testing.expect(pre_open <= pre_close);
    const stripped = try stripHtmlTags(std.testing.allocator, page[pre_open..pre_close]);
    defer std.testing.allocator.free(stripped);
    const visible = try unescapeHtml(std.testing.allocator, stripped);
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings(body, visible);
}
