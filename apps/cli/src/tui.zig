/// Interactive TUI loop for `sprts-tui` (wave 3), ported from pts `ui.zig`.
///
/// Same bones: raw-mode stdin, poll-based key reads, alternate screen,
/// per-frame render, footer with freshness. The data layer differs: pts
/// scrapes pages over HTTP, this TUI fetches typed JSON over the sprts
/// client's injectable `HttpTransport` (tests inject fakes; no network) and
/// consumes `?stream=sse` snapshots (see `sse.zig`) to drive live refreshes
/// instead of re-polling.
///
/// Views: leagues picker -> scoreboard -> game detail -> team schedule, plus
/// standings off `s`. `enter` opens the selected row (game, or a team row
/// inside game/standings); `b`/esc pops back and refetches like pts. Pure
/// helpers (keys, viewport, filter, age, navigation, loaders, row text) are
/// unit-tested; only the terminal loop itself needs a live TTY.
const std = @import("std");
const core = @import("sprts_core");
const sprts_client = @import("sprts_client");
const gen = sprts_client.gen;
const cli = @import("cli.zig");
const sse = @import("sse.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Keys (vim-first, pts conventions)
// ---------------------------------------------------------------------------

pub const Key = enum {
    none,
    quit,
    down,
    up,
    page_down,
    page_up,
    prev_day,
    next_day,
    top,
    bottom,
    enter,
    back,
    refresh,
    standings,
    auto,
    help,
    filter,
};

/// Single-byte key decoding. Lone ESC decodes to back; escape sequences
/// (`ESC [ A` ...) are resolved by `decodeEscapeTail` in the loop.
pub fn decodeByte(b: u8) Key {
    return switch (b) {
        'q' => .quit,
        'j' => .down,
        'k' => .up,
        'd', ' ' => .page_down,
        'u' => .page_up,
        'h' => .prev_day,
        'l' => .next_day,
        'g' => .top,
        'G' => .bottom,
        '\r', '\n' => .enter,
        'b' => .back,
        27 => .back,
        'r' => .refresh,
        's' => .standings,
        'a' => .auto,
        '?' => .help,
        '/' => .filter,
        else => .none,
    };
}

/// Decode the bytes after an ESC: `A`/`B` arrows, `C`/`D` day steps,
/// `5`/`6` page steps (optional `~` terminator). Anything else is back.
pub fn decodeEscapeTail(tail: []const u8) Key {
    if (tail.len == 0) return .back;
    if (tail[0] != '[') return .back;
    const code = if (tail.len > 1) tail[1] else return .back;
    return switch (code) {
        'A' => .up,
        'B' => .down,
        'C' => .next_day,
        'D' => .prev_day,
        '5' => .page_up,
        '6' => .page_down,
        else => .back,
    };
}

// ---------------------------------------------------------------------------
// Viewport / scroll math (pts: header row + clamped scroll window)
// ---------------------------------------------------------------------------

pub const header_rows: usize = 2;
pub const footer_rows: usize = 2;
pub const min_body_rows: usize = 1;
pub const list_header_rows: usize = 1;

/// Body rows available for list content given a terminal height.
pub fn bodyRows(term_rows: usize) usize {
    const reserved = header_rows + footer_rows;
    if (term_rows > reserved + min_body_rows) return term_rows - reserved;
    return min_body_rows;
}

/// Selectable rows visible at once (one header line above the list).
pub fn visibleRows(body_rows: usize) usize {
    if (body_rows > list_header_rows) return body_rows - list_header_rows;
    return min_body_rows;
}

/// Scroll offset keeping `selected` on screen.
pub fn ensureVisible(selected: usize, scroll: usize, visible: usize) usize {
    if (visible == 0) return 0;
    if (selected < scroll) return selected;
    if (selected >= scroll + visible) return selected - visible + 1;
    return scroll;
}

/// Clamp a selection into `[0, count)`.
pub fn clampSelected(selected: usize, count: usize) usize {
    if (count == 0) return 0;
    if (selected >= count) return count - 1;
    return selected;
}

pub fn moveDown(selected: usize, count: usize, amount: usize) usize {
    if (count == 0) return 0;
    return @min(count - 1, selected + amount);
}

pub fn moveUp(selected: usize, amount: usize) usize {
    if (selected > amount) return selected - amount;
    return 0;
}

// ---------------------------------------------------------------------------
// Filter matching (case-insensitive substring over row fields)
// ---------------------------------------------------------------------------

pub fn matchesFilter(query: []const u8, fields: []const []const u8) bool {
    if (query.len == 0) return true;
    for (fields) |field| {
        if (std.ascii.indexOfIgnoreCase(field, query) != null) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Last-updated footer age ("updated 12s ago", minutes/hours graduation)
// ---------------------------------------------------------------------------

/// Human age of the latest fetch or SSE `:mtime` frame. Future timestamps
/// clamp to zero; graduation is seconds < minutes < hours.
pub fn formatAge(allocator: Allocator, now_s: i64, updated_s: i64) ![]u8 {
    const age: i64 = if (now_s > updated_s) now_s - updated_s else 0;
    if (age < 60) return std.fmt.allocPrint(allocator, "updated {d}s ago", .{age});
    if (age < 3600) return std.fmt.allocPrint(allocator, "updated {d}m ago", .{@divTrunc(age, 60)});
    return std.fmt.allocPrint(allocator, "updated {d}h ago", .{@divTrunc(age, 3600)});
}

// ---------------------------------------------------------------------------
// Navigation state (history stack of lightweight frames; back refetches)
// ---------------------------------------------------------------------------

pub const ViewTag = enum { leagues, board, game, team, standings };

pub const Frame = struct {
    view: ViewTag,
    league: []const u8,
    target: []const u8,
    date: ?[]const u8,
};

pub const Navigator = struct {
    alloc: Allocator,
    current: Frame,
    history: std.ArrayList(Frame) = .empty,

    pub fn init(alloc: Allocator, root: Frame) !Navigator {
        return .{ .alloc = alloc, .current = try dupeFrame(alloc, root) };
    }

    pub fn deinit(self: *Navigator) void {
        freeFrame(self.alloc, &self.current);
        for (self.history.items) |*frame| freeFrame(self.alloc, frame);
        self.history.deinit(self.alloc);
    }

    /// Push `current` and move to `next`; selection resets at the call site.
    /// `next` is duped BEFORE `current` is freed: every caller threads
    /// `current` slices (league/date) into `next`, so freeing first reads
    /// freed memory (garbage league -> 404 -> `BadStatus` on open).
    pub fn open(self: *Navigator, next: Frame) !void {
        var owned = try dupeFrame(self.alloc, next);
        errdefer freeFrame(self.alloc, &owned);
        try self.history.append(self.alloc, try dupeFrame(self.alloc, self.current));
        freeFrame(self.alloc, &self.current);
        self.current = owned;
    }

    /// Pop back; false when already at the root (caller stays put).
    pub fn back(self: *Navigator) bool {
        const prev = self.history.pop() orelse return false;
        freeFrame(self.alloc, &self.current);
        self.current = prev;
        return true;
    }

    fn dupeFrame(alloc: Allocator, frame: Frame) !Frame {
        return .{
            .view = frame.view,
            .league = try alloc.dupe(u8, frame.league),
            .target = try alloc.dupe(u8, frame.target),
            .date = if (frame.date) |d| try alloc.dupe(u8, d) else null,
        };
    }

    fn freeFrame(alloc: Allocator, frame: *Frame) void {
        alloc.free(frame.league);
        alloc.free(frame.target);
        if (frame.date) |d| alloc.free(d);
    }
};

// ---------------------------------------------------------------------------
// Typed loaders over the transport seam (fake-friendly, no network)
// ---------------------------------------------------------------------------

pub const LoadError = error{ FetchFailed, BadStatus, BadBody, OutOfMemory };

/// Fetch a league scoreboard; arena owns the returned slices.
pub fn loadBoard(
    arena: Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    league: []const u8,
    date: ?[]const u8,
) LoadError!sprts_client.Scoreboard {
    var result = sprts_client.fetchScoreboard(arena, transport, base_url, league, date, null) catch return error.FetchFailed;
    return switch (result) {
        .ok => |*ok| ok.value().*,
        .api_error => error.BadStatus,
        .parse_error => error.BadBody,
    };
}

/// Fetch one game detail; arena owns the returned slices.
pub fn loadGame(
    arena: Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    league: []const u8,
    id: []const u8,
) LoadError!sprts_client.DetailGame {
    var result = sprts_client.fetchGame(arena, transport, base_url, league, id) catch return error.FetchFailed;
    return switch (result) {
        .ok => |*ok| ok.value().*,
        .api_error => error.BadStatus,
        .parse_error => error.BadBody,
    };
}

/// Fetch one team schedule view; arena owns the returned slices.
pub fn loadTeam(
    arena: Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    league: []const u8,
    abbr: []const u8,
) LoadError!sprts_client.ScheduleTeamView {
    var result = sprts_client.fetchTeam(arena, transport, base_url, league, abbr) catch return error.FetchFailed;
    return switch (result) {
        .ok => |*ok| ok.value().*,
        .api_error => error.BadStatus,
        .parse_error => error.BadBody,
    };
}

/// Fetch league standings; arena owns the returned slices.
pub fn loadStandings(
    arena: Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    league: []const u8,
) LoadError!sprts_client.LeagueStandings {
    var result = sprts_client.fetchStandings(arena, transport, base_url, league) catch return error.FetchFailed;
    return switch (result) {
        .ok => |*ok| ok.value().*,
        .api_error => error.BadStatus,
        .parse_error => error.BadBody,
    };
}

/// Fetch the league picker list; arena owns the returned slices.
pub fn loadLeagues(
    arena: Allocator,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
) LoadError!sprts_client.LeagueList {
    var result = sprts_client.fetchLeagues(arena, transport, base_url) catch return error.FetchFailed;
    return switch (result) {
        .ok => |*ok| ok.value().*,
        .api_error => error.BadStatus,
        .parse_error => error.BadBody,
    };
}

/// True while any board game is live (`state == "in"`, the server's cadence key).
pub fn boardHasLive(board: sprts_client.Scoreboard) bool {
    for (board.games) |game| {
        if (std.mem.eql(u8, game.state, "in")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Server-parity text kit (production web/curl views, text mode)
//
// Mirrors `apps/server/src/table.zig` (cell widths, fit, padded cells) and
// `apps/server/src/render.zig` (`scoreParticipantLine`, `statusColor`,
// `writeGameMarks`, `text_home_banner_small`). String literals below are
// duplicated from those server sources with citing comments; the CLI never
// imports server code.
// ---------------------------------------------------------------------------

/// Server text boards render 52 columns wide by default
/// (`textWithZoneArt` clamps `width orelse 52` into `52..200`); the TUI
/// uses the same width so participant rows match byte for byte.
pub const board_cols: usize = 52;

/// Team-mark height cap: braille cards stay a glanceable block instead of
/// pushing games off the viewport (checked-in xs marks are ~4 rows).
pub const mark_cap_height: usize = 6;

/// Block `sprts` wordmark topping every TUI screen. Letterforms duplicated
/// from the server's `text_home_banner_small` in
/// `apps/server/src/render.zig` (same 13-polygon pixel logo, one cell per
/// pixel, 3-cell letters with 2-cell gaps). Never ANSI, like the original.
pub const tui_banner: []const u8 =
    \\                █
    \\██   ███  ███  ███  ██
    \\███  █ █  █     █   ███
    \\ ██  ███  █     ██   ██
    \\     █
++ "\n";

pub fn renderBanner(w: *std.Io.Writer) !void {
    try w.writeAll(tui_banner);
}

/// Terminal cells for one code point: 0 for combining marks, 2 for
/// East-Asian wide, 1 for everything else (controls render as one blank
/// cell). Mirrors `cellWidth` in `apps/server/src/table.zig`.
fn cellWidth(cp: u21) usize {
    if (isCombining(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

/// Combining-mark ranges, mirrored from `apps/server/src/table.zig`.
fn isCombining(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x0483 and cp <= 0x0489) or
        (cp >= 0x0591 and cp <= 0x05BD) or
        cp == 0x05BF or
        (cp >= 0x05C1 and cp <= 0x05C2) or
        (cp >= 0x05C4 and cp <= 0x05C5) or
        cp == 0x05C7 or
        (cp >= 0x0610 and cp <= 0x061A) or
        (cp >= 0x064B and cp <= 0x065F) or
        cp == 0x0670 or
        (cp >= 0x06D6 and cp <= 0x06DC) or
        (cp >= 0x06DF and cp <= 0x06E4) or
        (cp >= 0x06E7 and cp <= 0x06E8) or
        (cp >= 0x06EA and cp <= 0x06ED) or
        cp == 0x0711 or
        (cp >= 0x0730 and cp <= 0x074A) or
        (cp >= 0x07A6 and cp <= 0x07B0) or
        (cp >= 0x0900 and cp <= 0x0903) or
        (cp >= 0x093A and cp <= 0x094F) or
        (cp >= 0x0951 and cp <= 0x0957) or
        (cp >= 0x0962 and cp <= 0x0963) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE20 and cp <= 0xFE2F);
}

/// East-Asian wide ranges, mirrored from `apps/server/src/table.zig`.
fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        cp == 0x231A or cp == 0x231B or
        cp == 0x2329 or cp == 0x232A or
        (cp >= 0x23E9 and cp <= 0x23EC) or
        cp == 0x23F0 or cp == 0x23F3 or
        cp == 0x25FD or cp == 0x25FE or
        cp == 0x2614 or cp == 0x2615 or
        (cp >= 0x2648 and cp <= 0x2653) or
        cp == 0x267F or cp == 0x2693 or cp == 0x26A1 or
        cp == 0x26AA or cp == 0x26AB or
        cp == 0x26BD or cp == 0x26BE or
        cp == 0x26C4 or cp == 0x26C5 or
        cp == 0x26CE or cp == 0x26D4 or
        cp == 0x26EA or
        cp == 0x26F2 or cp == 0x26F3 or
        cp == 0x26F5 or cp == 0x26FA or cp == 0x26FD or
        cp == 0x2705 or cp == 0x270A or cp == 0x270B or
        cp == 0x2728 or cp == 0x274C or cp == 0x274E or
        (cp >= 0x2753 and cp <= 0x2755) or
        cp == 0x2757 or
        (cp >= 0x2795 and cp <= 0x2797) or
        cp == 0x27B0 or cp == 0x27BF or
        cp == 0x2B1B or cp == 0x2B1C or
        cp == 0x2B50 or cp == 0x2B55 or
        (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x20000 and cp <= 0x2FFFD) or
        (cp >= 0x30000 and cp <= 0x3FFFD);
}

/// Decode one code point: byte length and value. Invalid bytes decode as
/// U+FFFD with length 1. Mirrors `decode` in `apps/server/src/table.zig`.
fn decodeCell(s: []const u8, i: usize) struct { len: usize, cp: u21 } {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .len = 1, .cp = 0xFFFD };
    if (i + len > s.len) return .{ .len = 1, .cp = 0xFFFD };
    const cp = std.unicode.utf8Decode(s[i..][0..len]) catch return .{ .len = 1, .cp = 0xFFFD };
    return .{ .len = len, .cp = cp };
}

fn isControl(cp: u21) bool {
    return cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F);
}

/// Terminal cells in a text cell (name, status, record). Mirrors
/// `textCells` in `apps/server/src/table.zig`.
fn textCells(s: []const u8) usize {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeCell(s, i);
        cells += cellWidth(d.cp);
        i += d.len;
    }
    return cells;
}

/// Fits `s` into `width` columns: byte length to keep plus whether an
/// ellipsis is owed. Mirrors `fit` in `apps/server/src/table.zig`.
fn fitEnd(s: []const u8, width: usize) struct { usize, bool } {
    if (s.len <= width) return .{ s.len, false };
    if (width < 4) return .{ 0, true };
    var end: usize = width - 3;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return .{ end, true };
}

/// Copy `s[0..end]` with hardening: controls become one ASCII space each,
/// invalid bytes become U+FFFD. Mirrors `writeSanitized` in
/// `apps/server/src/table.zig`.
fn writeSanitized(w: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeCell(s, i);
        if (d.cp == 0xFFFD and !(s[i] == 0xEF and d.len == 3)) {
            try w.writeAll("�");
        } else if (isControl(d.cp)) {
            try w.writeByte(' ');
        } else {
            try w.writeAll(s[i..][0..d.len]);
        }
        i += d.len;
    }
}

/// `s` fitted to exactly `width` cells, left-aligned. Color wraps at emit
/// time, never inside. Mirrors `writeCell` in `apps/server/src/table.zig`.
fn writeCell(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    const end, const ellipsis = fitEnd(s, width);
    try writeSanitized(w, s[0..end]);
    if (ellipsis) try w.writeAll("…");
    const n_written: usize = textCells(s[0..end]) + (if (ellipsis) @as(usize, 1) else 0);
    var i: usize = n_written;
    while (i < width) : (i += 1) try w.writeByte(' ');
}

/// `s` fitted to exactly `width` cells, right-aligned. Mirrors
/// `writeCellRight` in `apps/server/src/table.zig`.
fn writeCellRight(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    const end, const ellipsis = fitEnd(s, width);
    const n_written: usize = textCells(s[0..end]) + (if (ellipsis) @as(usize, 1) else 0);
    var spaces: usize = width -| n_written;
    while (spaces > 0) : (spaces -= 1) try w.writeByte(' ');
    try writeSanitized(w, s[0..end]);
    if (ellipsis) try w.writeAll("…");
}

/// Server ANSI roles (`statusColor` in `apps/server/src/render.zig`): live
/// rows read red, upcoming yellow, everything else plain. Winner rows wrap
/// green at emit time; headings dim. `enabled == false` emits zero escapes.
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

/// One columnar participant row, byte-identical to the server's
/// `scoreParticipantLine` in `apps/server/src/render.zig` for the same
/// inputs at the same `cols`: abbr in 4, padded name, right-aligned score
/// in 4, ` (record)`, winner ` ✓`, trailing blanks trimmed. Generic over
/// the board and detail participant shapes (same fields, different
/// generated type names).
pub fn participantRow(allocator: Allocator, p: anytype, cols: usize) ![]u8 {
    const rec_w: usize = if (p.record) |r| @min(textCells(r), 10) else 0;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const b = &buf.writer;
    if (p.abbreviation.len > 0) {
        try writeCell(b, p.abbreviation, 4);
        try b.writeByte(' ');
        try writeCell(b, p.name, cols -| 4 -| 2 -| 4 -| 2 -| (if (p.record != null) rec_w + 3 else 0));
    } else {
        // Athlete identities carry no abbreviation: the name absorbs it.
        try writeCell(b, p.name, cols -| 7 -| (if (p.record != null) rec_w + 3 else 0));
    }
    try b.writeByte(' ');
    try writeCellRight(b, p.score, 4);
    if (p.record) |r| {
        try b.writeAll(" (");
        try writeCell(b, r, rec_w);
        try b.writeByte(')');
    }
    if (p.winner) try b.writeAll(" ✓") else try b.writeAll("  ");
    const raw = try buf.toOwnedSlice();
    defer allocator.free(raw);
    return allocator.dupe(u8, std.mem.trimEnd(u8, raw, " "));
}

/// Both teams' braille marks as terminal rows, mirroring the server's
/// `writeGameMarks` card in `apps/server/src/table.zig`: direct
/// `core.art.teamArt(league, abbr, .xs)` lookups, side by side with a
/// 2-cell gap when the pair fits in `cols`, stacked otherwise. Color on
/// resolves the color sidecar and strips its SGR runs (the TUI owns its
/// own palette, so mark escapes never reach the frame); color off takes
/// the mono mark. Height is capped at `mark_cap_height` rows; a side with
/// no mark is skipped, so unknown abbrevs yield zero rows. Caller frees
/// each row and the slice.
pub fn gameMarks(
    allocator: Allocator,
    league: []const u8,
    first_abbr: []const u8,
    second_abbr: []const u8,
    color: bool,
    cols: usize,
) ![][]u8 {
    var sides: [2]std.ArrayList([]u8) = .{ .empty, .empty };
    var widths: [2]usize = .{ 0, 0 };
    var n: usize = 0;
    errdefer {
        for (&sides) |*side| {
            for (side.items) |row| allocator.free(row);
            side.deinit(allocator);
        }
    }
    for ([2][]const u8{ first_abbr, second_abbr }) |abbr| {
        if (n == sides.len) break;
        const raw = if (color)
            core.art.teamArtColor(league, abbr, .xs) orelse
                core.art.teamArt(league, abbr, .xs)
        else
            core.art.teamArt(league, abbr, .xs);
        const mark = raw orelse continue;
        var stripped: std.Io.Writer.Allocating = .init(allocator);
        defer stripped.deinit();
        try core.art.stripSgr(&stripped.writer, mark);
        const blob = try stripped.toOwnedSlice();
        defer allocator.free(blob);
        var collected: std.ArrayList([]const u8) = .empty;
        defer collected.deinit(allocator);
        var lines = std.mem.splitScalar(u8, blob, '\n');
        while (lines.next()) |line| try collected.append(allocator, line);
        // Drop only the trailing empty from the file's final newline;
        // interior blanks are real logo rows.
        if (collected.items.len > 0 and collected.items[collected.items.len - 1].len == 0)
            _ = collected.pop();
        for (collected.items[0..@min(collected.items.len, mark_cap_height)]) |line| {
            widths[n] = @max(widths[n], core.art.countCells(line));
            try sides[n].append(allocator, try allocator.dupe(u8, line));
        }
        if (sides[n].items.len == 0) continue;
        n += 1;
    }
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |row| allocator.free(row);
        out.deinit(allocator);
    }
    const gap: usize = 2;
    if (n == 2 and widths[0] + gap + widths[1] <= cols -| 2) {
        const height = @max(sides[0].items.len, sides[1].items.len);
        for (0..height) |r| {
            var row: std.Io.Writer.Allocating = .init(allocator);
            defer row.deinit();
            for (0..2) |i| {
                if (i == 1) {
                    var g: usize = 0;
                    while (g < gap) : (g += 1) try row.writer.writeByte(' ');
                }
                const line = if (r < sides[i].items.len) sides[i].items[r] else "";
                try row.writer.writeAll(line);
                var pad: usize = widths[i] - core.art.countCells(line);
                while (pad > 0) : (pad -= 1) try row.writer.writeByte(' ');
            }
            try out.append(allocator, try allocator.dupe(u8, std.mem.trimEnd(u8, row.written(), " ")));
        }
    } else {
        for (sides[0..n]) |side| {
            for (side.items) |line| try out.append(allocator, try allocator.dupe(u8, line));
        }
    }
    for (sides[0..n]) |*side| {
        for (side.items) |row| allocator.free(row);
        side.deinit(allocator);
    }
    return out.toOwnedSlice(allocator);
}

fn pickSide(
    parts: []const gen.ScoreboardGamesItemParticipantsItem,
    want: []const u8,
    fallback: usize,
) ?gen.ScoreboardGamesItemParticipantsItem {
    for (parts) |p| {
        if (p.home_away) |ha| if (std.mem.eql(u8, ha, want)) return p;
    }
    if (fallback < parts.len) return parts[fallback];
    return null;
}

pub fn gameFilterFields(game: gen.ScoreboardGamesItem) [5][]const u8 {
    const away = pickSide(game.participants, "away", 0);
    const home = pickSide(game.participants, "home", 1);
    return .{
        if (away) |a| a.name else "",
        if (away) |a| a.abbreviation else "",
        if (home) |h| h.name else "",
        if (home) |h| h.abbreviation else "",
        game.status,
    };
}

pub fn standingsRowText(allocator: Allocator, group: []const u8, entry: gen.LeagueStandingsGroupsItemEntriesItem) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(entry.abbrev);
    const wins = entry.wins orelse "";
    const losses = entry.losses orelse "";
    if (wins.len > 0 or losses.len > 0) {
        try w.writeAll(" ");
        try w.writeAll(wins);
        try w.writeByte('-');
        try w.writeAll(losses);
        if (entry.ties) |ties| {
            try w.writeByte('-');
            try w.writeAll(ties);
        }
    }
    try w.print("  {s}  {s}", .{ entry.name, group });
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Screen renderers (header + scroll window + footer; help overlay)
// ---------------------------------------------------------------------------

pub const ViewContext = struct {
    league_name: []const u8 = "",
    league: []const u8 = "",
    date: []const u8 = "",
    view_label: []const u8 = "",
    age_text: []const u8 = "",
    auto_refresh: bool = false,
    filter: []const u8 = "",
    err: ?[]const u8 = null,
    color: bool = true,
    view: ViewTag = .board,
};

pub fn renderHeader(w: *std.Io.Writer, ctx: ViewContext) !void {
    if (ctx.color) try w.writeAll("\x1b[2m");
    if (ctx.league_name.len > 0) {
        try w.print("{s} ({s}) — {s}  [{s}]", .{ ctx.league_name, ctx.league, ctx.date, ctx.view_label });
    } else {
        try w.print("sprts  [{s}]", .{ctx.view_label});
    }
    if (ctx.color) try w.writeAll("\x1b[0m");
    try w.writeByte('\n');
    if (ctx.filter.len > 0) try w.print("filter: {s}\n", .{ctx.filter}) else try w.writeByte('\n');
}

pub const BoardOptions = struct {
    color: bool = true,
    cols: usize = board_cols,
};

/// Scoreboard blocks in the server's section rhythm (`textWithZoneArt` in
/// `apps/server/src/render.zig`): dim `GAMES` heading, then per game the
/// status line (red live, yellow upcoming), columnar participant rows
/// (`participantRow`), the braille mark card, and a separator rule. Only
/// the status line carries the selection gutter, so participant rows stay
/// byte-identical to the server. Nothing emits ANSI with `color == false`.
pub fn renderBoardRows(
    w: *std.Io.Writer,
    allocator: Allocator,
    league: []const u8,
    games: []const gen.ScoreboardGamesItem,
    filter: []const u8,
    selected: usize,
    scroll: usize,
    visible: usize,
    opts: BoardOptions,
) !void {
    try colorize(w, "2", "GAMES", opts.color);
    try w.writeByte('\n');
    if (games.len == 0) {
        try w.writeAll("No games scheduled.\n");
        return;
    }
    var filtered: usize = 0;
    var emitted: usize = 0;
    for (games) |game| {
        const fields = gameFilterFields(game);
        if (!matchesFilter(filter, &fields)) continue;
        if (filtered < scroll) {
            filtered += 1;
            continue;
        }
        if (emitted >= visible) return;
        var status: std.Io.Writer.Allocating = .init(allocator);
        defer status.deinit();
        try status.writer.print("{s}{s}", .{ if (filtered == selected) "> " else "  ", game.status });
        if (statusColor(game.state)) |code| try colorize(w, code, status.written(), opts.color) else try w.writeAll(status.written());
        try w.writeByte('\n');
        if (game.participants.len == 0) {
            const label = if (game.name.len > 0) game.name else game.id;
            try w.print("  {s}\n", .{label});
        }
        for (game.participants) |p| {
            const row = try participantRow(allocator, p, opts.cols);
            defer allocator.free(row);
            if (opts.color and p.winner) try w.writeAll("\x1b[32m");
            try w.writeAll(row);
            if (opts.color and p.winner) try w.writeAll("\x1b[0m");
            try w.writeByte('\n');
        }
        const first = if (game.participants.len > 0) game.participants[0].abbreviation else "";
        const second = if (game.participants.len > 1) game.participants[1].abbreviation else "";
        const marks = try gameMarks(allocator, league, first, second, opts.color, opts.cols);
        defer {
            for (marks) |line| allocator.free(line);
            allocator.free(marks);
        }
        for (marks) |line| try w.print("{s}\n", .{line});
        var i: usize = 0;
        while (i < opts.cols) : (i += 1) try w.writeAll("─");
        try w.writeByte('\n');
        filtered += 1;
        emitted += 1;
    }
    if (filtered == 0) try w.writeAll("No games match filter. Press / to change.\n");
}

/// Persistent bottom help bar: freshness plus the key line. The game view
/// additionally hints `b back` (context-sensitive: every other view pops
/// with the same key, but only the drill-in view advertises it).
pub fn renderFooter(w: *std.Io.Writer, ctx: ViewContext) !void {
    if (ctx.err) |msg| try w.print("ERROR: {s}\n", .{msg});
    try w.print("{s} · auto:{s} · j/k move · h/l day · enter open · s standings · / filter · r refresh · a auto · ? help ·", .{
        ctx.age_text,
        if (ctx.auto_refresh) "on" else "off",
    });
    if (ctx.view == .game) try w.writeAll(" b back ·");
    try w.writeAll(" q quit\n");
}

pub fn renderHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\sprts-tui - Help
        \\
        \\j/down       Move down            k/up         Move up
        \\h/left       Previous day         l/right      Next day
        \\enter        Open game or team    b/esc        Back
        \\s            Standings            /            Filter
        \\r            Refresh              a            Toggle auto-refresh
        \\?            This help            q            Quit
        \\
        \\Live boards and live games auto-refresh from the server SSE
        \\stream while auto is on; anything else polls on refresh.
        \\
        \\Press ? or b to close.
        \\
    );
}

// ---------------------------------------------------------------------------
// Paint control (flicker fix: diffed writes, throttled footer, SSE debounce)
//
// The loop used to `render()` a full-screen `writeFrame` on every wakeup
// (~1Hz via `poll_tick_ms`), and the footer `updated Ns ago` ticker changed
// the frame bytes every second, so the MLB board visibly flickered even
// with unchanged data. Now: full repaints happen only when the content
// hash moves; the footer refreshes at most every `footer_throttle_s` via
// cursor-addressed line writes (never a full repaint); back-to-back SSE
// frames inside `sse_debounce_s` coalesce instead of refetching per frame.
// Row/header/footer bytes are untouched, so vim keys, navigation, and
// rendering stay byte-identical.
// ---------------------------------------------------------------------------

/// Full repaints are content-driven; the footer line refreshes at most
/// this often (cursor-addressed, never a full repaint).
pub const footer_throttle_s: i64 = 5;

/// SSE frames landing sooner than this after the last applied frame defer
/// their refetch (freshness still updates); the pending frame applies on
/// the next tick past the window.
pub const sse_debounce_s: i64 = 2;

/// Stable hash of one frame's bytes; the repaint gate compares these.
pub fn hashFrame(bytes: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(bytes);
    return h.final();
}

/// True when the footer line is due for its cursor-addressed refresh.
pub fn footerDue(now_s: i64, last_footer_s: ?i64) bool {
    const last = last_footer_s orelse return true;
    return now_s - last >= footer_throttle_s;
}

/// True when an SSE-triggered refetch may run (debounce window elapsed).
pub fn sseApplyDue(now_s: i64, last_apply_s: ?i64) bool {
    const last = last_apply_s orelse return true;
    return now_s - last >= sse_debounce_s;
}

/// True when a fresh SSE snapshot hash should refetch now; false defers
/// the frame (caller stashes it as pending) so rapid bursts coalesce.
pub fn sseShouldApply(now_s: i64, last_apply_s: ?i64, hash_changed: bool) bool {
    return hash_changed and sseApplyDue(now_s, last_apply_s);
}

pub const PaintDecision = enum { full, footer_only, none };

/// Content change always wins a full repaint; otherwise only a due footer
/// earns its line write; a footer tick alone never triggers a full paint.
pub fn decidePaint(content_changed: bool, footer_due: bool) PaintDecision {
    if (content_changed) return .full;
    if (footer_due) return .footer_only;
    return .none;
}

/// Counting test-double for the repaint gate: feed it one content hash per
/// tick (plus the clock) and it counts full-screen vs footer-line writes.
/// Steady state with unchanged data yields exactly one full paint total;
/// footer ticks alone never add a full paint.
pub const FrameDeduper = struct {
    last_content_hash: ?u64 = null,
    last_footer_s: ?i64 = null,
    full_paints: usize = 0,
    footer_paints: usize = 0,

    pub fn observe(self: *FrameDeduper, now_s: i64, content_hash: u64) PaintDecision {
        return self.observeMasked(now_s, content_hash, true);
    }

    /// Same gate with the footer line suppressed (the help overlay owns
    /// every row, so a footer write would clobber its bottom lines).
    pub fn observeMasked(self: *FrameDeduper, now_s: i64, content_hash: u64, footer_allowed: bool) PaintDecision {
        const changed = self.last_content_hash == null or self.last_content_hash.? != content_hash;
        const decision = decidePaint(changed, footer_allowed and footerDue(now_s, self.last_footer_s));
        switch (decision) {
            .full => {
                self.last_content_hash = content_hash;
                self.last_footer_s = now_s;
                self.full_paints += 1;
            },
            .footer_only => {
                self.last_footer_s = now_s;
                self.footer_paints += 1;
            },
            .none => {},
        }
        return decision;
    }
};

/// Screen row for footer line `line_index` of `line_count` footer lines:
/// the footer always owns the bottom lines of the terminal.
pub fn footerRow(term_rows: usize, line_index: usize, line_count: usize) usize {
    if (line_count == 0) return term_rows;
    if (term_rows < line_count) return line_index + 1;
    return term_rows - line_count + 1 + line_index;
}

// ---------------------------------------------------------------------------
// Terminal plumbing (ported from pts ui.zig: raw mode, poll, alt screen)
// ---------------------------------------------------------------------------

const escape_key: u8 = 27;
const delete_key: u8 = 127;
const backspace_key: u8 = 8;
const poll_tick_ms: i32 = 1000;
const refresh_interval_s: i64 = 15;

pub const RawMode = struct {
    active: bool = false,
    original: if (@import("builtin").os.tag == .linux) std.posix.termios else void = if (@import("builtin").os.tag == .linux) undefined else {},

    pub fn init() RawMode {
        if (@import("builtin").os.tag != .linux) return .{};
        var self: RawMode = .{};
        self.original = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return .{};
        var raw = self.original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw) catch return .{};
        self.active = true;
        return self;
    }

    pub fn deinit(self: *RawMode) void {
        if (@import("builtin").os.tag != .linux) return;
        if (self.active) std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
    }
};

/// True when `fd` is a terminal (tcgetattr fails on pipes/files).
/// No `isatty` in this Zig version; termios probing is the equivalent.
pub fn fdIsTerminal(fd: std.posix.fd_t) bool {
    if (@import("builtin").os.tag != .linux) return false;
    _ = std.posix.tcgetattr(fd) catch return false;
    return true;
}

pub fn stdioIsTerminal() bool {
    return fdIsTerminal(std.posix.STDIN_FILENO) and fdIsTerminal(std.posix.STDOUT_FILENO);
}

fn inputReady(timeout_ms: i32) !bool {
    if (@import("builtin").os.tag == .windows) return true;
    var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&fds, timeout_ms) != 0;
}

fn readByte(io: std.Io) !u8 {
    var b: [1]u8 = undefined;
    while (true) {
        const n = try std.Io.File.stdin().readStreaming(io, &.{&b});
        if (n != 0) return b[0];
    }
}

fn readEscapeTail(io: std.Io) !Key {
    if (!try inputReady(0)) return .back;
    const b1 = try readByte(io);
    if (b1 != '[') return .back;
    if (!try inputReady(0)) return .back;
    const b2 = try readByte(io);
    // Consume a trailing `~` on `5`/`6` when present.
    if ((b2 == '5' or b2 == '6') and try inputReady(0)) {
        const b3 = try readByte(io);
        if (b3 == '~') return if (b2 == '5') .page_up else .page_down;
        return decodeEscapeTail(&.{ '[', b2 });
    }
    return decodeEscapeTail(&.{ '[', b2 });
}

fn readKey(io: std.Io, timeout_ms: i32) !Key {
    if (!try inputReady(timeout_ms)) return .none;
    const first = try readByte(io);
    if (first == escape_key) return readEscapeTail(io);
    return decodeByte(first);
}

fn promptFilter(io: std.Io, allocator: Allocator, old: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.print("\x1b[?25h\nfilter [{s}]: ", .{old});
    try writeStdout(io, out.written());

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    while (true) {
        var b: [1]u8 = undefined;
        const n = try std.Io.File.stdin().readStreaming(io, &.{&b});
        if (n == 0) continue;
        if (b[0] == '\r' or b[0] == '\n') break;
        if (b[0] == escape_key) break;
        if (b[0] == delete_key or b[0] == backspace_key) {
            if (list.items.len > 0) {
                list.shrinkRetainingCapacity(list.items.len - 1);
                try writeStdout(io, "\x08 \x08");
            }
            continue;
        }
        if (b[0] < ' ') continue;
        try list.append(allocator, b[0]);
        try writeStdout(io, &b);
    }
    try writeStdout(io, "\x1b[?25l");
    if (list.items.len == 0) return allocator.dupe(u8, "");
    return list.toOwnedSlice(allocator);
}

fn terminalSize() struct { rows: usize, cols: usize } {
    if (@import("builtin").os.tag == .linux) {
        var ws: std.posix.winsize = undefined;
        const rc = std.os.linux.ioctl(std.posix.STDOUT_FILENO, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        return .{
            .rows = if (rc == 0 and ws.row > 0) ws.row else 24,
            .cols = if (rc == 0 and ws.col > 0) ws.col else 80,
        };
    }
    return .{ .rows = 24, .cols = 80 };
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeFrame(io: std.Io, bytes: []const u8) !void {
    // Re-assert hidden: the filter prompt briefly shows the cursor, and a
    // visible cursor parked on repainted cells reads as flicker.
    try writeStdout(io, "\x1b[?25l");
    var start: usize = 0;
    for (bytes, 0..) |b, i| {
        if (b != '\n') continue;
        if (i > start) try writeStdout(io, bytes[start..i]);
        try writeStdout(io, "\x1b[K\n");
        start = i + 1;
    }
    if (start < bytes.len) try writeStdout(io, bytes[start..]);
    try writeStdout(io, "\x1b[K\x1b[J");
}

/// Footer-only refresh: rewrite just the bottom line(s) via cursor
/// addressing, leaving every other cell untouched (no clear, no home).
/// `footer_bytes` is the `renderFooter` output; each non-empty line lands
/// on its owned bottom row and the cursor parks home (still hidden).
fn writeFooterLines(io: std.Io, allocator: Allocator, term_rows: usize, footer_bytes: []const u8) !void {
    try writeStdout(io, "\x1b[?25l");
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, footer_bytes, '\n');
    while (split.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(allocator, line);
    }
    for (lines.items, 0..) |line, i| {
        const row = footerRow(term_rows, i, lines.items.len);
        var seq: std.Io.Writer.Allocating = .init(allocator);
        defer seq.deinit();
        try seq.writer.print("\x1b[{d};1H\x1b[K", .{row});
        try writeStdout(io, seq.written());
        try writeStdout(io, line);
    }
    try writeStdout(io, "\x1b[H");
}

// ---------------------------------------------------------------------------
// Interactive session
// ---------------------------------------------------------------------------

const Tui = struct {
    gpa: Allocator,
    io: std.Io,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    view_arena: std.heap.ArenaAllocator,
    nav: Navigator,
    selected: usize = 0,
    scroll: usize = 0,
    filter: []u8,
    auto_refresh: bool = true,
    color: bool = true,
    show_help: bool = false,
    last_update_s: ?i64 = null,
    last_fetch_s: ?i64 = null,
    last_error: ?[]u8 = null,
    sse_hash: ?u64 = null,
    last_sse_apply_s: ?i64 = null,
    pending_sse_hash: ?u64 = null,
    pending_sse_mtime: ?i64 = null,
    deduper: FrameDeduper = .{},
    leagues: ?sprts_client.LeagueList = null,
    board: ?sprts_client.Scoreboard = null,
    game: ?sprts_client.DetailGame = null,
    team: ?sprts_client.ScheduleTeamView = null,
    standings: ?sprts_client.LeagueStandings = null,

    fn init(
        gpa: Allocator,
        io: std.Io,
        transport: sprts_client.HttpTransport,
        base_url: []const u8,
        root: Frame,
    ) !Tui {
        const filter = try gpa.dupe(u8, "");
        errdefer gpa.free(filter);
        var nav = try Navigator.init(gpa, root);
        errdefer nav.deinit();
        return .{
            .gpa = gpa,
            .io = io,
            .transport = transport,
            .base_url = base_url,
            .view_arena = std.heap.ArenaAllocator.init(gpa),
            .nav = nav,
            .filter = filter,
        };
    }

    fn deinit(self: *Tui) void {
        self.view_arena.deinit();
        self.nav.deinit();
        self.gpa.free(self.filter);
        if (self.last_error) |msg| self.gpa.free(msg);
    }

    fn viewAlloc(self: *Tui) Allocator {
        return self.view_arena.allocator();
    }

    /// Wipe per-view fetched data (all view slices are arena-owned).
    fn resetView(self: *Tui) void {
        self.view_arena.deinit();
        self.view_arena = std.heap.ArenaAllocator.init(self.gpa);
        self.leagues = null;
        self.board = null;
        self.game = null;
        self.team = null;
        self.standings = null;
        self.selected = 0;
        self.scroll = 0;
    }

    fn setError(self: *Tui, comptime fmt: []const u8, args: anytype) void {
        if (self.last_error) |msg| self.gpa.free(msg);
        self.last_error = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
    }

    fn clearError(self: *Tui) void {
        if (self.last_error) |msg| self.gpa.free(msg);
        self.last_error = null;
    }

    fn nowS(self: *Tui) i64 {
        return std.Io.Clock.real.now(self.io).toSeconds();
    }

    fn markUpdated(self: *Tui) void {
        const now = self.nowS();
        self.last_update_s = now;
        self.last_fetch_s = now;
    }

    fn frameDate(self: *Tui) ?[]const u8 {
        return self.nav.current.date;
    }

    fn loadCurrent(self: *Tui) void {
        const frame = self.nav.current;
        switch (frame.view) {
            .leagues => self.reloadLeagues(),
            .board => self.reloadBoard(),
            .game => self.reloadGame(frame.league, frame.target),
            .team => self.reloadTeam(frame.league, frame.target),
            .standings => self.reloadStandings(frame.league),
        }
    }

    fn reloadLeagues(self: *Tui) void {
        self.resetView();
        self.leagues = loadLeagues(self.viewAlloc(), self.transport, self.base_url) catch |err| {
            self.setError("leagues failed: {t}", .{err});
            return;
        };
        self.clearError();
        self.markUpdated();
    }

    fn reloadBoard(self: *Tui) void {
        const frame = self.nav.current;
        self.resetView();
        self.board = loadBoard(self.viewAlloc(), self.transport, self.base_url, frame.league, frame.date) catch |err| {
            self.setError("scoreboard failed: {t}", .{err});
            return;
        };
        // Server-canonical date keeps h/l stepping exact.
        if (self.board) |board| {
            const owned = self.gpa.dupe(u8, board.date) catch null;
            if (owned) |day| {
                if (self.nav.current.date) |old| self.gpa.free(old);
                self.nav.current.date = day;
            }
        }
        self.clearError();
        self.markUpdated();
    }

    fn reloadGame(self: *Tui, league: []const u8, id: []const u8) void {
        self.resetView();
        self.game = loadGame(self.viewAlloc(), self.transport, self.base_url, league, id) catch |err| {
            self.setError("game failed: {t}", .{err});
            return;
        };
        self.clearError();
        self.markUpdated();
    }

    fn reloadTeam(self: *Tui, league: []const u8, abbr: []const u8) void {
        self.resetView();
        self.team = loadTeam(self.viewAlloc(), self.transport, self.base_url, league, abbr) catch |err| {
            self.setError("team failed: {t}", .{err});
            return;
        };
        self.clearError();
        self.markUpdated();
    }

    fn reloadStandings(self: *Tui, league: []const u8) void {
        self.resetView();
        self.standings = loadStandings(self.viewAlloc(), self.transport, self.base_url, league) catch |err| {
            self.setError("standings failed: {t}", .{err});
            return;
        };
        self.clearError();
        self.markUpdated();
    }

    fn openFrame(self: *Tui, next: Frame) void {
        self.nav.open(next) catch {
            self.setError("out of memory", .{});
            return;
        };
        self.resetView();
        self.setFilter("");
        self.resetSse();
        self.loadCurrent();
    }

    fn goBack(self: *Tui) void {
        if (self.show_help) {
            self.show_help = false;
            return;
        }
        if (!self.nav.back()) return;
        self.resetView();
        self.setFilter("");
        self.resetSse();
        self.loadCurrent();
    }

    /// Fresh view, fresh stream: drop hashes, pending frames, and the
    /// debounce clock so the new view's first snapshot applies at once.
    fn resetSse(self: *Tui) void {
        self.sse_hash = null;
        self.last_sse_apply_s = null;
        self.pending_sse_hash = null;
        self.pending_sse_mtime = null;
    }

    fn setFilter(self: *Tui, value: []const u8) void {
        self.gpa.free(self.filter);
        self.filter = self.gpa.dupe(u8, value) catch self.gpa.dupe(u8, "") catch unreachable;
        self.selected = 0;
        self.scroll = 0;
        self.selected = clampSelected(self.selected, self.rowCount());
    }

    fn rowCount(self: *Tui) usize {
        const frame = self.nav.current;
        var n: usize = 0;
        switch (frame.view) {
            .leagues => {
                const list = self.leagues orelse return 0;
                for (list.leagues) |entry| {
                    if (matchesFilter(self.filter, &.{ entry.slug, entry.name })) n += 1;
                }
            },
            .board => {
                const board = self.board orelse return 0;
                for (board.games) |game| {
                    const fields = gameFilterFields(game);
                    if (matchesFilter(self.filter, &fields)) n += 1;
                }
            },
            .game => {
                const game = self.game orelse return 0;
                for (game.participants) |p| {
                    if (matchesFilter(self.filter, &.{ p.abbreviation, p.name })) n += 1;
                }
            },
            .team => return 0,
            .standings => {
                const table = self.standings orelse return 0;
                for (table.groups) |group| {
                    for (group.entries) |entry| {
                        if (matchesFilter(self.filter, &.{ entry.abbrev, entry.name, group.name })) n += 1;
                    }
                }
            },
        }
        return n;
    }

    fn clampSelection(self: *Tui) void {
        self.selected = clampSelected(self.selected, self.rowCount());
        if (self.scroll > self.selected) self.scroll = self.selected;
    }

    fn selectedGame(self: *Tui) ?gen.ScoreboardGamesItem {
        const board = self.board orelse return null;
        var n: usize = 0;
        for (board.games) |game| {
            const fields = gameFilterFields(game);
            if (!matchesFilter(self.filter, &fields)) continue;
            if (n == self.selected) return game;
            n += 1;
        }
        return null;
    }

    fn selectedLeague(self: *Tui) ?gen.LeagueListLeaguesItem {
        const list = self.leagues orelse return null;
        var n: usize = 0;
        for (list.leagues) |entry| {
            if (!matchesFilter(self.filter, &.{ entry.slug, entry.name })) continue;
            if (n == self.selected) return entry;
            n += 1;
        }
        return null;
    }

    fn selectedParticipant(self: *Tui) ?gen.DetailGameParticipantsItem {
        const game = self.game orelse return null;
        var n: usize = 0;
        for (game.participants) |p| {
            if (!matchesFilter(self.filter, &.{ p.abbreviation, p.name })) continue;
            if (n == self.selected) return p;
            n += 1;
        }
        return null;
    }

    fn selectedStanding(self: *Tui) ?gen.LeagueStandingsGroupsItemEntriesItem {
        const table = self.standings orelse return null;
        var n: usize = 0;
        for (table.groups) |group| {
            for (group.entries) |entry| {
                if (!matchesFilter(self.filter, &.{ entry.abbrev, entry.name, group.name })) continue;
                if (n == self.selected) return entry;
                n += 1;
            }
        }
        return null;
    }

    fn openSelected(self: *Tui) void {
        const frame = self.nav.current;
        switch (frame.view) {
            .leagues => {
                const entry = self.selectedLeague() orelse return;
                self.openFrame(.{ .view = .board, .league = entry.slug, .target = "", .date = frame.date });
            },
            .board => {
                const game = self.selectedGame() orelse return;
                self.openFrame(.{ .view = .game, .league = frame.league, .target = game.id, .date = frame.date });
            },
            .game => {
                const p = self.selectedParticipant() orelse return;
                self.openFrame(.{ .view = .team, .league = frame.league, .target = p.abbreviation, .date = frame.date });
            },
            .standings => {
                const entry = self.selectedStanding() orelse return;
                self.openFrame(.{ .view = .team, .league = frame.league, .target = entry.abbrev, .date = frame.date });
            },
            .team => {},
        }
    }

    fn openStandings(self: *Tui) void {
        const frame = self.nav.current;
        if (frame.view == .leagues or frame.league.len == 0) {
            self.setError("pick a league first", .{});
            return;
        }
        if (frame.view == .standings) return;
        self.openFrame(.{ .view = .standings, .league = frame.league, .target = "", .date = frame.date });
    }

    fn stepDay(self: *Tui, delta: i32) void {
        const frame = self.nav.current;
        if (frame.view != .board) return;
        const day = frame.date orelse {
            self.setError("no date loaded yet", .{});
            return;
        };
        const shifted = core.date.shift(self.gpa, day, delta) catch {
            self.setError("bad date '{s}'", .{day});
            return;
        };
        defer self.gpa.free(shifted);
        self.gpa.free(self.nav.current.date.?);
        self.nav.current.date = self.gpa.dupe(u8, shifted) catch {
            self.setError("out of memory", .{});
            return;
        };
        self.resetSse();
        self.reloadBoard();
    }

    /// Auto-refresh tick: live boards/games consume the SSE stream and only
    /// refetch typed JSON when a fresh frame lands; SSE errors fall back to
    /// plain polling. Quiet views refresh on the same cadence.
    fn tick(self: *Tui) void {
        if (!self.auto_refresh) return;
        const now = self.nowS();
        const last = self.last_fetch_s orelse 0;
        if (self.last_fetch_s != null and now - last < refresh_interval_s) return;
        self.last_fetch_s = now;
        const frame = self.nav.current;
        switch (frame.view) {
            .board => self.tickBoard(),
            .game => {
                const game = self.game orelse return;
                if (std.mem.eql(u8, game.state, "in")) self.tickGame(frame.league, frame.target);
            },
            else => {},
        }
    }

    fn tickBoard(self: *Tui) void {
        const frame = self.nav.current;
        const board = self.board;
        const live = if (board) |b| boardHasLive(b) else true;
        if (!live) {
            // Settled slate: cheap poll keeps day boundaries exact.
            // Identical payloads repaint nothing (paint gate hashes).
            self.reloadBoard();
            return;
        }
        const now = self.nowS();
        // Flush a debounced frame once the window elapses.
        if (self.pending_sse_hash) |pending| {
            if (sseApplyDue(now, self.last_sse_apply_s)) {
                self.sse_hash = pending;
                self.last_sse_apply_s = now;
                if (self.pending_sse_mtime) |m| self.touchUpdated(m);
                self.pending_sse_hash = null;
                self.pending_sse_mtime = null;
                self.reloadBoard();
            }
            return;
        }
        const snap = sse.fetchSnapshot(self.viewAlloc(), self.transport, self.base_url, frame.league, frame.date) catch {
            self.reloadBoard(); // polling fallback
            return;
        };
        if (self.sse_hash != null and self.sse_hash.? == snap.hash) {
            if (snap.mtime) |m| self.touchUpdated(m);
            return;
        }
        // Freshness moves even when the refetch itself is deferred.
        if (snap.mtime) |m| self.touchUpdated(m);
        if (!sseShouldApply(now, self.last_sse_apply_s, true)) {
            // Rapid burst: coalesce into one refetch past the window.
            self.pending_sse_hash = snap.hash;
            self.pending_sse_mtime = snap.mtime;
            return;
        }
        self.sse_hash = snap.hash;
        self.last_sse_apply_s = now;
        self.reloadBoard();
    }

    fn tickGame(self: *Tui, league: []const u8, id: []const u8) void {
        const frame = self.nav.current;
        const now = self.nowS();
        if (self.pending_sse_hash) |pending| {
            if (sseApplyDue(now, self.last_sse_apply_s)) {
                self.sse_hash = pending;
                self.last_sse_apply_s = now;
                if (self.pending_sse_mtime) |m| self.touchUpdated(m);
                self.pending_sse_hash = null;
                self.pending_sse_mtime = null;
                self.reloadGame(league, id);
            }
            return;
        }
        const snap = sse.fetchSnapshot(self.viewAlloc(), self.transport, self.base_url, league, frame.date) catch {
            self.reloadGame(league, id); // polling fallback
            return;
        };
        if (self.sse_hash != null and self.sse_hash.? == snap.hash) {
            if (snap.mtime) |m| self.touchUpdated(m);
            return;
        }
        if (snap.mtime) |m| self.touchUpdated(m);
        if (!sseShouldApply(now, self.last_sse_apply_s, true)) {
            self.pending_sse_hash = snap.hash;
            self.pending_sse_mtime = snap.mtime;
            return;
        }
        self.sse_hash = snap.hash;
        self.last_sse_apply_s = now;
        self.reloadGame(league, id);
    }

    /// Freshness without visible change: monotonic, and never by itself a
    /// reason to repaint (the footer owns its throttled line write).
    fn touchUpdated(self: *Tui, mtime: i64) void {
        if (self.last_update_s == null or mtime > self.last_update_s.?)
            self.last_update_s = mtime;
    }

    fn timeoutMs(self: *Tui) i32 {
        if (!self.auto_refresh) return poll_tick_ms;
        const last = self.last_fetch_s orelse return 0;
        const due = last + refresh_interval_s;
        const now = self.nowS();
        if (now >= due) return 0;
        const delta = due - now;
        if (delta > poll_tick_ms) return poll_tick_ms;
        return @intCast(delta);
    }

    /// One full frame with `true`, or a content probe with `false`.
    /// Probes render the identical bytes (sentinel age) without mutating
    /// navigation state; only real paints commit the scroll window.
    /// `clampSelection` runs in both: it is idempotent, so probes stay
    /// consistent with the paint they gate.
    fn renderInto(self: *Tui, w: *std.Io.Writer, age_text: []const u8, commit_scroll: bool) !void {
        try w.writeAll("\x1b[H");
        try renderBanner(w);

        if (self.show_help) {
            try renderHelp(w);
            return;
        }

        const size = terminalSize();
        const visible = visibleRows(bodyRows(size.rows));
        self.clampSelection();
        const scroll = ensureVisible(self.selected, self.scroll, visible);
        if (commit_scroll) self.scroll = scroll;

        const frame = self.nav.current;
        const label: []const u8 = switch (frame.view) {
            .leagues => "leagues",
            .board => "scores",
            .game => "game",
            .team => "team",
            .standings => "standings",
        };
        const league_name: []const u8 = switch (frame.view) {
            .board => if (self.board) |b| b.league_name else "",
            .game => if (self.game) |g| g.league_name else "",
            .team => if (self.team) |t| t.league_name else "",
            .standings => if (self.standings) |s| s.league_name else "",
            .leagues => "",
        };
        try renderHeader(w, .{
            .league_name = league_name,
            .league = frame.league,
            .date = frame.date orelse "",
            .view_label = label,
            .filter = self.filter,
            .color = self.color,
        });

        switch (frame.view) {
            .leagues => try self.renderLeagues(w, scroll, visible),
            .board => try self.renderBoard(w, scroll, visible),
            .game => try self.renderGame(w, scroll, visible),
            .team => try self.renderTeam(w),
            .standings => try self.renderStandings(w, scroll, visible),
        }

        try renderFooter(w, .{
            .age_text = age_text,
            .auto_refresh = self.auto_refresh,
            .err = self.last_error,
            .view = frame.view,
        });
    }

    /// Force a full repaint with live footer age (byte-identical bytes).
    fn render(self: *Tui) !void {
        var aw = std.Io.Writer.Allocating.init(self.gpa);
        defer aw.deinit();
        const now = self.nowS();
        const age_text = if (self.last_update_s) |updated|
            try formatAge(self.gpa, now, updated)
        else
            try self.gpa.dupe(u8, "not updated yet");
        defer self.gpa.free(age_text);
        try self.renderInto(&aw.writer, age_text, true);
        try writeFrame(self.io, aw.written());
    }

    /// Content bytes for the repaint gate: the exact frame with a fixed
    /// age sentinel, so the per-second `updated Ns ago` ticker never
    /// counts as a content change.
    fn buildContentBytes(self: *Tui) ![]u8 {
        var aw = std.Io.Writer.Allocating.init(self.gpa);
        defer aw.deinit();
        try self.renderInto(&aw.writer, "", false);
        return self.gpa.dupe(u8, aw.written());
    }

    /// Footer-only refresh: live age over cursor-addressed lines.
    fn paintFooter(self: *Tui) !void {
        const now = self.nowS();
        const age_text = if (self.last_update_s) |updated|
            try formatAge(self.gpa, now, updated)
        else
            try self.gpa.dupe(u8, "not updated yet");
        defer self.gpa.free(age_text);
        var aw = std.Io.Writer.Allocating.init(self.gpa);
        defer aw.deinit();
        try renderFooter(&aw.writer, .{
            .age_text = age_text,
            .auto_refresh = self.auto_refresh,
            .err = self.last_error,
            .view = self.nav.current.view,
        });
        try writeFooterLines(self.io, self.gpa, terminalSize().rows, aw.written());
    }

    /// Repaint gate: full paint only on content change, footer line at
    /// most every `footer_throttle_s`, silence otherwise. Returns the
    /// decision so tests can count full-screen writes per N ticks.
    fn paintIfNeeded(self: *Tui) !PaintDecision {
        const content = try self.buildContentBytes();
        defer self.gpa.free(content);
        const decision = self.deduper.observeMasked(self.nowS(), hashFrame(content), !self.show_help);
        switch (decision) {
            .full => try self.render(),
            .footer_only => try self.paintFooter(),
            .none => {},
        }
        return decision;
    }

    fn renderLeagues(self: *Tui, w: *std.Io.Writer, scroll: usize, visible: usize) !void {
        try colorize(w, "2", "LEAGUES", self.color);
        try w.writeByte('\n');
        const list = self.leagues orelse {
            try w.writeAll("No leagues loaded. Press r to retry.\n");
            return;
        };
        var filtered: usize = 0;
        var emitted: usize = 0;
        for (list.leagues) |entry| {
            if (!matchesFilter(self.filter, &.{ entry.slug, entry.name })) continue;
            if (filtered < scroll) {
                filtered += 1;
                continue;
            }
            if (emitted >= visible) return;
            try w.print("{s}{s} — {s}\n", .{ if (filtered == self.selected) "> " else "  ", entry.slug, entry.name });
            filtered += 1;
            emitted += 1;
        }
        if (filtered == 0) try w.writeAll("No leagues match filter. Press / to change.\n");
    }

    fn renderBoard(self: *Tui, w: *std.Io.Writer, scroll: usize, visible: usize) !void {
        const board = self.board orelse {
            try colorize(w, "2", "GAMES", self.color);
            try w.writeAll("\nNo games loaded. Press r to retry.\n");
            return;
        };
        try renderBoardRows(w, self.gpa, board.league, board.games, self.filter, self.selected, scroll, visible, .{ .color = self.color });
    }

    fn renderGame(self: *Tui, w: *std.Io.Writer, scroll: usize, visible: usize) !void {
        const game = self.game orelse {
            try w.writeAll("GAME\nNo game loaded. Press r to retry.\n");
            return;
        };
        const away = pickDetailSide(game.participants, "away", 0);
        const home = pickDetailSide(game.participants, "home", 1);
        if (away != null and home != null) {
            try w.print("{s} {s} @ {s} {s}  {s}\n", .{
                away.?.abbreviation, away.?.score, home.?.abbreviation, home.?.score, game.status,
            });
        } else {
            try w.print("{s}  {s}\n", .{ game.id, game.status });
        }
        if (game.venue) |venue| try w.print("venue: {s}\n", .{venue});
        if (game.series) |series| try w.print("series: {s}\n", .{series});
        try colorize(w, "2", "TEAMS (enter opens schedule)", self.color);
        try w.writeByte('\n');
        var filtered: usize = 0;
        var emitted: usize = 0;
        for (game.participants) |p| {
            if (!matchesFilter(self.filter, &.{ p.abbreviation, p.name })) continue;
            if (filtered < scroll) {
                filtered += 1;
                continue;
            }
            if (emitted >= visible) return;
            const row = try participantRow(self.gpa, p, board_cols);
            defer self.gpa.free(row);
            try w.print("{s}{s}\n", .{ if (filtered == self.selected) "> " else "  ", row });
            filtered += 1;
            emitted += 1;
        }
        if (filtered == 0) try w.writeAll("No teams match filter. Press / to change.\n");
    }

    fn renderTeam(self: *Tui, w: *std.Io.Writer) !void {
        const view = self.team orelse {
            try w.writeAll("TEAM\nNo team loaded. Press r to retry.\n");
            return;
        };
        try w.print("{s} ({s})", .{ view.team.name, view.team.abbrev });
        if (view.team.record_summary) |record| try w.print("  {s}", .{record});
        try w.writeByte('\n');
        if (view.team.standing_summary) |standing| try w.print("{s}\n", .{standing});
        try w.writeAll("LAST\n");
        for (view.last) |row| {
            try w.print("  {s} vs {s} {s}-{s}  {s}\n", .{ row.date, row.opponent_abbrev, row.our_score, row.opp_score, row.status });
        }
        try w.writeAll("NEXT\n");
        for (view.next) |row| {
            try w.print("  {s} vs {s}  {s}\n", .{ row.date, row.opponent_abbrev, row.status });
        }
    }

    fn renderStandings(self: *Tui, w: *std.Io.Writer, scroll: usize, visible: usize) !void {
        try colorize(w, "2", "STANDINGS (enter opens team)", self.color);
        try w.writeByte('\n');
        const table = self.standings orelse {
            try w.writeAll("No standings loaded. Press r to retry.\n");
            return;
        };
        var filtered: usize = 0;
        var emitted: usize = 0;
        for (table.groups) |group| {
            for (group.entries) |entry| {
                if (!matchesFilter(self.filter, &.{ entry.abbrev, entry.name, group.name })) continue;
                if (filtered < scroll) {
                    filtered += 1;
                    continue;
                }
                if (emitted >= visible) return;
                const row = try standingsRowText(self.gpa, group.name, entry);
                defer self.gpa.free(row);
                try w.print("{s}{s}\n", .{ if (filtered == self.selected) "> " else "  ", row });
                filtered += 1;
                emitted += 1;
            }
        }
        if (filtered == 0) try w.writeAll("No teams match filter. Press / to change.\n");
    }
};

fn pickDetailSide(
    parts: []const gen.DetailGameParticipantsItem,
    want: []const u8,
    fallback: usize,
) ?gen.DetailGameParticipantsItem {
    for (parts) |p| {
        if (p.home_away) |ha| if (std.mem.eql(u8, ha, want)) return p;
    }
    if (fallback < parts.len) return parts[fallback];
    return null;
}

/// Interactive entry: initial fetch, raw-mode loop, screen restore on exit.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    transport: sprts_client.HttpTransport,
    base_url: []const u8,
    opts: cli.Options,
    today: ?[]const u8,
) !void {
    var tmp_arena = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena.deinit();
    const resolved = cli.resolveQueryDate(tmp_arena.allocator(), opts.date, today) catch null;

    const root: Frame = if (opts.league) |slug| .{
        .view = .board,
        .league = slug,
        .target = "",
        .date = resolved,
    } else .{
        .view = .leagues,
        .league = "",
        .target = "",
        .date = resolved,
    };
    var tui = try Tui.init(gpa, io, transport, base_url, root);
    defer tui.deinit();
    tui.loadCurrent();

    var raw = RawMode.init();
    defer raw.deinit();
    try writeStdout(io, "\x1b[?1049h\x1b[?25l\x1b[2J");
    defer writeStdout(io, "\x1b[?25h\x1b[0m\x1b[?1049l") catch {};

    var running = true;
    while (running) {
        // Gated paint: full screen only on content change, footer line
        // throttled, silence otherwise (the old unconditional render
        // repainted ~1Hz and flickered on the per-second age ticker).
        _ = try tui.paintIfNeeded();
        const key = readKey(io, tui.timeoutMs()) catch .none;
        switch (key) {
            .none => tui.tick(),
            .quit => running = false,
            .down => tui.selected = moveDown(tui.selected, tui.rowCount(), 1),
            .up => tui.selected = moveUp(tui.selected, 1),
            .page_down => tui.selected = moveDown(tui.selected, tui.rowCount(), visibleRows(bodyRows(terminalSize().rows))),
            .page_up => tui.selected = moveUp(tui.selected, visibleRows(bodyRows(terminalSize().rows))),
            .prev_day => tui.stepDay(-1),
            .next_day => tui.stepDay(1),
            .top => {
                tui.selected = 0;
                tui.scroll = 0;
            },
            .bottom => {
                const count = tui.rowCount();
                if (count > 0) tui.selected = count - 1;
            },
            .enter => tui.openSelected(),
            .back => tui.goBack(),
            .refresh => tui.loadCurrent(),
            .standings => tui.openStandings(),
            .auto => tui.auto_refresh = !tui.auto_refresh,
            .help => tui.show_help = !tui.show_help,
            .filter => {
                const q = try promptFilter(io, gpa, tui.filter);
                defer gpa.free(q);
                tui.setFilter(q);
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Tests (fake transport + fixture JSON only, no network)
// ---------------------------------------------------------------------------

const FakeTransportState = struct {
    seen_url: ?[]const u8 = null,
    body: []const u8 = "",
    status: std.http.Status = .ok,
    fail: ?anyerror = null,

    fn dispatch(
        ptr: *anyopaque,
        arena: Allocator,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) anyerror!sprts_client.FetchResult {
        _ = extra_headers;
        const self: *FakeTransportState = @ptrCast(@alignCast(ptr));
        self.seen_url = try arena.dupe(u8, url);
        if (self.fail) |e| return e;
        return .{ .status = self.status, .body = try arena.dupe(u8, self.body) };
    }

    fn asTransport(self: *FakeTransportState) sprts_client.HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

test "key decoder covers the vim table plus enter back and quit" {
    try std.testing.expectEqual(Key.down, decodeByte('j'));
    try std.testing.expectEqual(Key.up, decodeByte('k'));
    try std.testing.expectEqual(Key.prev_day, decodeByte('h'));
    try std.testing.expectEqual(Key.next_day, decodeByte('l'));
    try std.testing.expectEqual(Key.top, decodeByte('g'));
    try std.testing.expectEqual(Key.bottom, decodeByte('G'));
    try std.testing.expectEqual(Key.page_down, decodeByte('d'));
    try std.testing.expectEqual(Key.page_down, decodeByte(' '));
    try std.testing.expectEqual(Key.page_up, decodeByte('u'));
    try std.testing.expectEqual(Key.enter, decodeByte('\r'));
    try std.testing.expectEqual(Key.enter, decodeByte('\n'));
    try std.testing.expectEqual(Key.back, decodeByte('b'));
    try std.testing.expectEqual(Key.back, decodeByte(27));
    try std.testing.expectEqual(Key.refresh, decodeByte('r'));
    try std.testing.expectEqual(Key.standings, decodeByte('s'));
    try std.testing.expectEqual(Key.auto, decodeByte('a'));
    try std.testing.expectEqual(Key.help, decodeByte('?'));
    try std.testing.expectEqual(Key.filter, decodeByte('/'));
    try std.testing.expectEqual(Key.quit, decodeByte('q'));
    try std.testing.expectEqual(Key.none, decodeByte('x'));
    try std.testing.expectEqual(Key.none, decodeByte('o'));
    try std.testing.expectEqual(Key.none, decodeByte(0));
}

test "key decoder resolves arrow and page escape tails" {
    try std.testing.expectEqual(Key.up, decodeEscapeTail("[A"));
    try std.testing.expectEqual(Key.down, decodeEscapeTail("[B"));
    try std.testing.expectEqual(Key.next_day, decodeEscapeTail("[C"));
    try std.testing.expectEqual(Key.prev_day, decodeEscapeTail("[D"));
    try std.testing.expectEqual(Key.page_up, decodeEscapeTail("[5"));
    try std.testing.expectEqual(Key.page_up, decodeEscapeTail("[5~"));
    try std.testing.expectEqual(Key.page_down, decodeEscapeTail("[6"));
    try std.testing.expectEqual(Key.page_down, decodeEscapeTail("[6~"));
    try std.testing.expectEqual(Key.back, decodeEscapeTail(""));
    try std.testing.expectEqual(Key.back, decodeEscapeTail("["));
    try std.testing.expectEqual(Key.back, decodeEscapeTail("OA"));
    try std.testing.expectEqual(Key.back, decodeEscapeTail("[Z"));
}

test "viewport math clamps scroll windows and selections" {
    try std.testing.expectEqual(@as(usize, 20), bodyRows(24));
    try std.testing.expectEqual(@as(usize, 1), bodyRows(4));
    try std.testing.expectEqual(@as(usize, 19), visibleRows(20));
    try std.testing.expectEqual(@as(usize, 1), visibleRows(1));

    // Selected below the window scrolls just enough to reveal it.
    try std.testing.expectEqual(@as(usize, 0), ensureVisible(0, 0, 10));
    try std.testing.expectEqual(@as(usize, 0), ensureVisible(9, 0, 10));
    try std.testing.expectEqual(@as(usize, 1), ensureVisible(10, 0, 10));
    try std.testing.expectEqual(@as(usize, 5), ensureVisible(14, 5, 10));
    // Selected above the window jumps the window back.
    try std.testing.expectEqual(@as(usize, 3), ensureVisible(3, 8, 10));

    try std.testing.expectEqual(@as(usize, 0), clampSelected(0, 0));
    try std.testing.expectEqual(@as(usize, 0), clampSelected(7, 0));
    try std.testing.expectEqual(@as(usize, 2), clampSelected(2, 3));
    try std.testing.expectEqual(@as(usize, 2), clampSelected(9, 3));

    try std.testing.expectEqual(@as(usize, 3), moveDown(1, 5, 2));
    try std.testing.expectEqual(@as(usize, 4), moveDown(3, 5, 9));
    try std.testing.expectEqual(@as(usize, 0), moveDown(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), moveUp(3, 2));
    try std.testing.expectEqual(@as(usize, 0), moveUp(1, 9));
}

test "filter matches case-insensitively across fields" {
    try std.testing.expect(matchesFilter("", &.{"Anything"}));
    try std.testing.expect(matchesFilter("mlb", &.{"MLB (mlb)"}));
    try std.testing.expect(matchesFilter("yank", &.{ "New York Yankees", "NYY", "Final" }));
    try std.testing.expect(matchesFilter("FINAL", &.{ "NYY 2 @ BOS 5", "Final" }));
    try std.testing.expect(!matchesFilter("nfl", &.{ "MLB", "Final" }));
    try std.testing.expect(!matchesFilter("x", &.{}));
}

test "last-updated age graduates seconds minutes hours" {
    const alloc = std.testing.allocator;
    const now = 1_000_000;

    const secs = try formatAge(alloc, now, now - 12);
    defer alloc.free(secs);
    try std.testing.expectEqualStrings("updated 12s ago", secs);

    const zero = try formatAge(alloc, now, now);
    defer alloc.free(zero);
    try std.testing.expectEqualStrings("updated 0s ago", zero);

    const future = try formatAge(alloc, now, now + 30);
    defer alloc.free(future);
    try std.testing.expectEqualStrings("updated 0s ago", future);

    const edge = try formatAge(alloc, now, now - 59);
    defer alloc.free(edge);
    try std.testing.expectEqualStrings("updated 59s ago", edge);

    const minute = try formatAge(alloc, now, now - 90);
    defer alloc.free(minute);
    try std.testing.expectEqualStrings("updated 1m ago", minute);

    const hour_edge = try formatAge(alloc, now, now - 3599);
    defer alloc.free(hour_edge);
    try std.testing.expectEqualStrings("updated 59m ago", hour_edge);

    const hour = try formatAge(alloc, now, now - 3700);
    defer alloc.free(hour);
    try std.testing.expectEqualStrings("updated 1h ago", hour);

    const hours = try formatAge(alloc, now, now - 9000);
    defer alloc.free(hours);
    try std.testing.expectEqualStrings("updated 2h ago", hours);
}

test "navigator walks league board to game and back" {
    var nav = try Navigator.init(std.testing.allocator, .{ .view = .board, .league = "mlb", .target = "", .date = "2026-09-06" });
    defer nav.deinit();

    try std.testing.expect(nav.current.view == .board);
    try nav.open(.{ .view = .game, .league = "mlb", .target = "1", .date = "2026-09-06" });
    try std.testing.expect(nav.current.view == .game);
    try std.testing.expectEqualStrings("1", nav.current.target);

    try nav.open(.{ .view = .team, .league = "mlb", .target = "AWY", .date = "2026-09-06" });
    try std.testing.expect(nav.current.view == .team);

    try std.testing.expect(nav.back());
    try std.testing.expect(nav.current.view == .game);
    try std.testing.expectEqualStrings("mlb", nav.current.league);
    try std.testing.expect(nav.back());
    try std.testing.expect(nav.current.view == .board);
    try std.testing.expect(!nav.back());
    try std.testing.expect(nav.current.view == .board);
}

test "navigator standings detour returns to the board" {
    var nav = try Navigator.init(std.testing.allocator, .{ .view = .board, .league = "nfl", .target = "", .date = null });
    defer nav.deinit();
    try nav.open(.{ .view = .standings, .league = "nfl", .target = "", .date = null });
    try std.testing.expect(nav.current.view == .standings);
    try std.testing.expect(nav.back());
    try std.testing.expect(nav.current.view == .board);
    try std.testing.expectEqualStrings("nfl", nav.current.league);
}

const canned_board =
    \\{"schema_version":"1","league":"mlb","league_name":"MLB","date":"2026-09-06","source":"test","games":[
    \\{"id":"1","name":"","starts_at":"2026-09-06T17:00Z","state":"post","status":"Final","participants":[
    \\{"id":"a","name":"Away Club","abbreviation":"AWY","score":"2","winner":false,"home_away":"away","record":"10-5"},
    \\{"id":"h","name":"Home Club","abbreviation":"HME","score":"5","winner":true,"home_away":"home","record":"12-3"}]},
    \\{"id":"2","name":"","starts_at":"2026-09-06T19:00Z","state":"in","status":"Top 7th","participants":[
    \\{"id":"b","name":"Bee Club","abbreviation":"BEE","score":"0","winner":false,"home_away":"away","record":null},
    \\{"id":"c","name":"Cee Club","abbreviation":"CEE","score":"3","winner":false,"home_away":"home","record":null}]}]}
;

const canned_game =
    \\{"schema_version":"1","league":"mlb","league_name":"MLB","id":"1","date":"2026-09-06","state":"in","status":"Top 7th",
    \\"venue":"Test Park","series":null,"attendance":null,"situation":null,
    \\"participants":[
    \\{"id":"a","name":"Away Club","abbreviation":"AWY","score":"2","winner":false,"home_away":"away","record":"10-5","probable":null,"hits":null,"errors":null,"lines":[]},
    \\{"id":"h","name":"Home Club","abbreviation":"HME","score":"3","winner":false,"home_away":"home","record":"12-3","probable":null,"hits":null,"errors":null,"lines":[]}],
    \\"scoring_plays":[{"text":"Someone homered","period":"7","home_score":"3","away_score":"2"}],
    \\"decisions":[],"lineups":[],"team_stats":[],"leaders":[]}
;

const canned_team =
    \\{"schema_version":"1","league":"mlb","league_name":"MLB","live":null,
    \\"team":{"abbrev":"AWY","id":"a","name":"Away Club","record_summary":"10-5","standing_summary":"1st AL East"},
    \\"next":[{"opponent_name":"Home Club","result":"","state":"pre","today":false,"our_score":"","status":"Scheduled","date":"2026-09-07","opponent_abbrev":"HME","home_away":"away","id":"9","opp_score":"","probable":""}],
    \\"last":[{"opponent_name":"Home Club","result":"L","state":"post","today":false,"our_score":"2","status":"Final","date":"2026-09-05","opponent_abbrev":"HME","home_away":"home","id":"8","opp_score":"5","probable":""}],
    \\"extra_past":[],"extra_next":[]}
;

const canned_standings =
    \\{"schema_version":"1","league":"mlb","league_name":"MLB","season":"2026","source":"test",
    \\"groups":[{"name":"AL East","entries":[
    \\{"wins":"10","team_id":"a","ties":null,"losses":"5","points":null,"abbrev":"AWY","name":"Away Club"},
    \\{"wins":"8","team_id":"h","ties":null,"losses":"7","points":null,"abbrev":"HME","name":"Home Club"}]}]}
;

const canned_leagues =
    \\{"schema_version":"1","leagues":[
    \\{"name":"MLB","sport":"baseball","slug":"mlb"},
    \\{"name":"NFL","sport":"football","slug":"nfl"}]}
;

test "loaders fetch typed views over the fake transport" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var board_fake = FakeTransportState{ .body = canned_board };
    const board = try loadBoard(arena, board_fake.asTransport(), "https://example.test", "mlb", "2026-09-06");
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb?date=2026-09-06", board_fake.seen_url.?);
    try std.testing.expectEqualStrings("MLB", board.league_name);
    try std.testing.expectEqual(@as(usize, 2), board.games.len);
    try std.testing.expect(boardHasLive(board));

    var game_fake = FakeTransportState{ .body = canned_game };
    const game = try loadGame(arena, game_fake.asTransport(), "https://example.test", "mlb", "1");
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb/1", game_fake.seen_url.?);
    try std.testing.expectEqualStrings("Top 7th", game.status);
    try std.testing.expectEqual(@as(usize, 2), game.participants.len);

    var team_fake = FakeTransportState{ .body = canned_team };
    const team = try loadTeam(arena, team_fake.asTransport(), "https://example.test", "mlb", "AWY");
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb/AWY", team_fake.seen_url.?);
    try std.testing.expectEqualStrings("Away Club", team.team.name);
    try std.testing.expectEqual(@as(usize, 1), team.next.len);

    var standings_fake = FakeTransportState{ .body = canned_standings };
    const table = try loadStandings(arena, standings_fake.asTransport(), "https://example.test", "mlb");
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb/standings", standings_fake.seen_url.?);
    try std.testing.expectEqualStrings("AL East", table.groups[0].name);
    try std.testing.expectEqual(@as(usize, 2), table.groups[0].entries.len);

    var leagues_fake = FakeTransportState{ .body = canned_leagues };
    const list = try loadLeagues(arena, leagues_fake.asTransport(), "https://example.test");
    try std.testing.expectEqualStrings("https://example.test/api/v1/leagues", leagues_fake.seen_url.?);
    try std.testing.expectEqual(@as(usize, 2), list.leagues.len);
}

test "loader failures surface without network" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var refused = FakeTransportState{ .fail = error.ConnectionRefused };
    try std.testing.expectError(error.FetchFailed, loadBoard(arena, refused.asTransport(), "https://example.test", "mlb", null));

    var missing = FakeTransportState{ .body = "nope", .status = .not_found };
    try std.testing.expectError(error.BadStatus, loadGame(arena, missing.asTransport(), "https://example.test", "mlb", "1"));

    var corrupt = FakeTransportState{ .body = "{not json" };
    try std.testing.expectError(error.BadBody, loadStandings(arena, corrupt.asTransport(), "https://example.test", "mlb"));
}

test "settled boards report no live games" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body =
        \\{"schema_version":"1","league":"nfl","league_name":"NFL","date":"2026-09-06","source":"test","games":[
        \\{"id":"1","name":"","starts_at":"2026-09-06T17:00Z","state":"post","status":"Final","participants":[]}]}
    };
    const board = try loadBoard(arena, fake.asTransport(), "https://example.test", "nfl", null);
    try std.testing.expect(!boardHasLive(board));
}

test "board blocks follow the server rhythm with a selected status line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = canned_board };
    const board = try loadBoard(arena, fake.asTransport(), "https://example.test", "mlb", null);

    const first = try participantRow(arena, board.games[0].participants[0], board_cols);
    try std.testing.expectEqualStrings("AWY  Away Club                            2 (10-5)", first);
    const winner = try participantRow(arena, board.games[0].participants[1], board_cols);
    try std.testing.expectEqualStrings("HME  Home Club                            5 (12-3) ✓", winner);

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try renderBoardRows(&out.writer, arena, board.league, board.games, "", 1, 0, 10, .{ .color = false });
    const text = out.written();
    // Selected game carries the gutter on its status line; the settled
    // game keeps a plain gutter. No legacy LIVE text marker remains.
    try std.testing.expect(std.mem.indexOf(u8, text, "> Top 7th") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  Final") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "LIVE") == null);
    // Columnar participant rows plus the separator rule per game.
    try std.testing.expect(std.mem.indexOf(u8, text, "AWY  Away Club") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "BEE  Bee Club") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "─") != null);
}

test "board rows honor filter and scroll windows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = canned_board };
    const board = try loadBoard(arena, fake.asTransport(), "https://example.test", "mlb", null);

    var filtered: std.Io.Writer.Allocating = .init(arena);
    defer filtered.deinit();
    try renderBoardRows(&filtered.writer, arena, board.league, board.games, "bee", 0, 0, 10, .{ .color = false });
    try std.testing.expect(std.mem.indexOf(u8, filtered.written(), "BEE") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.written(), "AWY") == null);

    var scrolled: std.Io.Writer.Allocating = .init(arena);
    defer scrolled.deinit();
    try renderBoardRows(&scrolled.writer, arena, board.league, board.games, "", 1, 1, 1, .{ .color = false });
    try std.testing.expect(std.mem.indexOf(u8, scrolled.written(), "BEE") != null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled.written(), "AWY") == null);

    var empty: std.Io.Writer.Allocating = .init(arena);
    defer empty.deinit();
    try renderBoardRows(&empty.writer, arena, board.league, board.games, "quidditch", 0, 0, 10, .{ .color = false });
    try std.testing.expect(std.mem.indexOf(u8, empty.written(), "No games match filter") != null);
}

test "standings rows carry records and groups" {
    const entry = gen.LeagueStandingsGroupsItemEntriesItem{
        .wins = "10",
        .team_id = "a",
        .ties = null,
        .losses = "5",
        .points = null,
        .abbrev = "AWY",
        .name = "Away Club",
    };
    const row = try standingsRowText(std.testing.allocator, "AL East", entry);
    defer std.testing.allocator.free(row);
    try std.testing.expectEqualStrings("AWY 10-5  Away Club  AL East", row);
}

test "help overlay documents every required key" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderHelp(&out.writer);
    const text = out.written();
    for ([_][]const u8{ "j/down", "k/up", "h/left", "l/right", "enter", "b/esc", "s", "Standings", "/", "Filter", "r", "Refresh", "a", "auto-refresh", "?", "q", "Quit", "SSE" }) |want| {
        try std.testing.expect(std.mem.indexOf(u8, text, want) != null);
    }
}

test "footer carries age auto state and the key line" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderFooter(&out.writer, .{ .age_text = "updated 12s ago", .auto_refresh = true });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "updated 12s ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto:on") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "q quit") != null);

    var off: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer off.deinit();
    try renderFooter(&off.writer, .{ .age_text = "updated 2h ago", .auto_refresh = false, .err = "boom" });
    try std.testing.expect(std.mem.indexOf(u8, off.written(), "auto:off") != null);
    try std.testing.expect(std.mem.indexOf(u8, off.written(), "ERROR: boom") != null);
}

// ---------------------------------------------------------------------------
// Regression + parity tests: pre-game board→enter→game flow, banner,
// footer hints, server-identical rows, marks, and color-off output.
// Fixtures replay the PHI pre-game case (`mlb/401816884`, state `pre`)
// behind a routing fake that 404s anything but the two exact URLs, so a
// wrong id threading or URL shows up as `BadStatus` here, as in the TUI.
// ---------------------------------------------------------------------------

const pregame_board =
    \\{"schema_version":"1","league":"mlb","league_name":"MLB","date":"2026-09-10","source":"test","games":[
    \\{"id":"401816884","name":"Houston Astros at Philadelphia Phillies","starts_at":"2026-09-10T17:05Z","state":"pre","status":"9/10 - 1:05 PM EDT","participants":[
    \\{"id":"18","name":"Houston Astros","abbreviation":"HOU","score":"0","winner":false,"home_away":"away","record":"74-72"},
    \\{"id":"22","name":"Philadelphia Phillies","abbreviation":"PHI","score":"0","winner":false,"home_away":"home","record":"82-64"}]}]}
;

const pregame_game =
    \\{"schema_version":"1","league":"mlb","league_name":"MLB","id":"401816884","date":"2026-09-10","state":"pre","status":"9/10 - 1:05 PM EDT",
    \\"venue":"Citizens Bank Park","series":"tied 1-1 (game 3 of 3)","attendance":null,"situation":null,
    \\"participants":[
    \\{"id":"18","name":"Houston Astros","abbreviation":"HOU","score":"0","winner":false,"home_away":"away","record":"74-72","probable":"Cristian Javier","hits":null,"errors":null,"lines":[]},
    \\{"id":"22","name":"Philadelphia Phillies","abbreviation":"PHI","score":"0","winner":false,"home_away":"home","record":"82-64","probable":"Zack Wheeler","hits":null,"errors":null,"lines":[]}],
    \\"scoring_plays":[],"decisions":[],"lineups":[],"team_stats":[],"leaders":[]}
;

const FlowRouter = struct {
    urls: std.ArrayList([]const u8) = .empty,
    alloc: Allocator,
    fn dispatch(ptr: *anyopaque, arena: Allocator, url: []const u8, extra: []const std.http.Header) anyerror!sprts_client.FetchResult {
        _ = extra;
        const self: *FlowRouter = @ptrCast(@alignCast(ptr));
        try self.urls.append(self.alloc, try self.alloc.dupe(u8, url));
        if (std.mem.eql(u8, url, "https://example.test/api/v1/mlb?date=2026-09-10"))
            return .{ .status = .ok, .body = try arena.dupe(u8, pregame_board) };
        if (std.mem.eql(u8, url, "https://example.test/api/v1/mlb/401816884"))
            return .{ .status = .ok, .body = try arena.dupe(u8, pregame_game) };
        return .{ .status = .not_found, .body = try arena.dupe(u8, "nope") };
    }
    fn asTransport(self: *FlowRouter) sprts_client.HttpTransport {
        return .{ .ptr = self, .fetchFn = dispatch };
    }
};

fn flowIo() std.Io {
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}

test "regression: board enter opens the pre-game PHI detail at its exact URL" {
    // Replays the `No game loaded / ERROR: game failed: BadStatus` report:
    // the pre-game PHI board row must thread its id into exactly
    // `/api/v1/mlb/401816884` (anything else 404s in the routing fake).
    var router = FlowRouter{ .alloc = std.testing.allocator };
    defer {
        for (router.urls.items) |u| std.testing.allocator.free(u);
        router.urls.deinit(std.testing.allocator);
    }
    var tui = try Tui.init(std.testing.allocator, flowIo(), router.asTransport(), "https://example.test", .{ .view = .board, .league = "mlb", .target = "", .date = "2026-09-10" });
    defer tui.deinit();
    tui.loadCurrent();
    try std.testing.expect(tui.board != null);
    try std.testing.expect(tui.last_error == null);
    tui.openSelected();
    try std.testing.expectEqual(@as(usize, 2), router.urls.items.len);
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb?date=2026-09-10", router.urls.items[0]);
    try std.testing.expectEqualStrings("https://example.test/api/v1/mlb/401816884", router.urls.items[1]);
    try std.testing.expect(tui.nav.current.view == .game);
    try std.testing.expectEqualStrings("mlb", tui.nav.current.league);
    try std.testing.expectEqualStrings("401816884", tui.nav.current.target);
    try std.testing.expect(tui.game != null);
    try std.testing.expect(tui.last_error == null);
    try std.testing.expectEqualStrings("PHI", tui.game.?.participants[1].abbreviation);
}

test "banner opens every board screen above the heading" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = canned_board };
    const board = try loadBoard(arena, fake.asTransport(), "https://example.test", "mlb", null);

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try renderBanner(&out.writer);
    try renderHeader(&out.writer, .{
        .league_name = board.league_name,
        .league = board.league,
        .date = board.date,
        .view_label = "scores",
        .color = false,
    });
    try renderBoardRows(&out.writer, arena, board.league, board.games, "", 0, 0, 10, .{ .color = false });
    const text = out.written();
    // Same block wordmark on top, then the heading, then the sections.
    try std.testing.expect(std.mem.startsWith(u8, text, tui_banner));
    try std.testing.expect(std.mem.indexOf(u8, text, "GAMES") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "GAMES").? > tui_banner.len);
    // Five block rows, ragged, never ANSI.
    var rows: usize = 0;
    var lines = std.mem.splitScalar(u8, tui_banner, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        rows += 1;
        try std.testing.expect(std.mem.indexOf(u8, line, "█") != null);
    }
    try std.testing.expectEqual(@as(usize, 5), rows);
    try std.testing.expect(std.mem.indexOf(u8, text[0..tui_banner.len], "\x1b") == null);
}

test "footer hints follow the view" {
    var board_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer board_out.deinit();
    try renderFooter(&board_out.writer, .{ .age_text = "updated 12s ago", .auto_refresh = true });
    try std.testing.expect(std.mem.indexOf(u8, board_out.written(), "q quit") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_out.written(), "enter open") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_out.written(), "b back") == null);

    var game_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer game_out.deinit();
    try renderFooter(&game_out.writer, .{ .age_text = "updated 12s ago", .auto_refresh = true, .view = .game });
    try std.testing.expect(std.mem.indexOf(u8, game_out.written(), "q quit") != null);
    try std.testing.expect(std.mem.indexOf(u8, game_out.written(), "b back") != null);
}

test "participant rows equal the server columnar layout" {
    // Pre-game PHI sample: byte-identical to the production text board
    // (`scoreParticipantLine` in `apps/server/src/render.zig` at 52
    // columns: abbr in 4, padded name, right-aligned score in 4, record).
    const phi = gen.ScoreboardGamesItemParticipantsItem{
        .record = "82-64",
        .abbreviation = "PHI",
        .winner = false,
        .score = "0",
        .home_away = "home",
        .id = "22",
        .name = "Philadelphia Phillies",
    };
    const phi_row = try participantRow(std.testing.allocator, phi, board_cols);
    defer std.testing.allocator.free(phi_row);
    try std.testing.expectEqualStrings("PHI  Philadelphia Phillies               0 (82-64)", phi_row);

    // Winner tick rides the row like the server's.
    const hme = gen.ScoreboardGamesItemParticipantsItem{
        .record = "12-3",
        .abbreviation = "HME",
        .winner = true,
        .score = "5",
        .home_away = "home",
        .id = "h",
        .name = "Home Club",
    };
    const hme_row = try participantRow(std.testing.allocator, hme, board_cols);
    defer std.testing.allocator.free(hme_row);
    try std.testing.expectEqualStrings("HME  Home Club                            5 (12-3) ✓", hme_row);

    // Missing records collapse without shifting the score column.
    const bee = gen.ScoreboardGamesItemParticipantsItem{
        .record = null,
        .abbreviation = "BEE",
        .winner = false,
        .score = "0",
        .home_away = "away",
        .id = "b",
        .name = "Bee Club",
    };
    const bee_row = try participantRow(std.testing.allocator, bee, board_cols);
    defer std.testing.allocator.free(bee_row);
    try std.testing.expectEqualStrings("BEE  Bee Club                                    0", bee_row);
}

test "marks show for known teams and vanish for unknown" {
    for ([2]bool{ false, true }) |color| {
        const marks = try gameMarks(std.testing.allocator, "mlb", "PHI", "HOU", color, board_cols);
        defer {
            for (marks) |line| std.testing.allocator.free(line);
            std.testing.allocator.free(marks);
        }
        // Both xs cards are 4 rows; side by side the card stays 4 tall.
        try std.testing.expectEqual(@as(usize, 4), marks.len);
        for (marks) |line| {
            try std.testing.expect(line.len > 0);
            try std.testing.expect(core.art.countCells(line) > 0);
            try std.testing.expect(std.mem.indexOfScalar(u8, line, 0xE2) != null); // braille glyphs
            try std.testing.expect(std.mem.indexOf(u8, line, "\x1b") == null);
        }
        // One known side still renders its card.
        const one = try gameMarks(std.testing.allocator, "mlb", "PHI", "ZZZ", color, board_cols);
        defer {
            for (one) |line| std.testing.allocator.free(line);
            std.testing.allocator.free(one);
        }
        try std.testing.expectEqual(@as(usize, 4), one.len);
        // Unknown abbrevs yield zero rows, cleanly.
        const none = try gameMarks(std.testing.allocator, "mlb", "ZZZ", "QQQ", color, board_cols);
        defer std.testing.allocator.free(none);
        try std.testing.expectEqual(@as(usize, 0), none.len);
    }
}

test "color off strips every escape and color on keeps server roles" {
    const tri_board =
        \\{"schema_version":"1","league":"mlb","league_name":"MLB","date":"2026-09-10","source":"test","games":[
        \\{"id":"1","name":"","starts_at":"2026-09-10T17:00Z","state":"post","status":"Final","participants":[
        \\{"id":"a","name":"Away Club","abbreviation":"AWY","score":"2","winner":false,"home_away":"away","record":"10-5"},
        \\{"id":"h","name":"Home Club","abbreviation":"HME","score":"5","winner":true,"home_away":"home","record":"12-3"}]},
        \\{"id":"2","name":"","starts_at":"2026-09-10T19:00Z","state":"in","status":"Top 7th","participants":[
        \\{"id":"b","name":"Bee Club","abbreviation":"BEE","score":"0","winner":false,"home_away":"away","record":null},
        \\{"id":"c","name":"Cee Club","abbreviation":"CEE","score":"3","winner":false,"home_away":"home","record":null}]},
        \\{"id":"401816884","name":"Houston Astros at Philadelphia Phillies","starts_at":"2026-09-10T17:05Z","state":"pre","status":"9/10 - 1:05 PM EDT","participants":[
        \\{"id":"18","name":"Houston Astros","abbreviation":"HOU","score":"0","winner":false,"home_away":"away","record":"74-72"},
        \\{"id":"22","name":"Philadelphia Phillies","abbreviation":"PHI","score":"0","winner":false,"home_away":"home","record":"82-64"}]}]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeTransportState{ .body = tri_board };
    const board = try loadBoard(arena, fake.asTransport(), "https://example.test", "mlb", null);

    var plain: std.Io.Writer.Allocating = .init(arena);
    defer plain.deinit();
    try renderBoardRows(&plain.writer, arena, board.league, board.games, "", 0, 0, 10, .{ .color = false });
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "\x1b") == null);
    // Winners still read without color: the tick survives the strip.
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "✓") != null);

    var vivid: std.Io.Writer.Allocating = .init(arena);
    defer vivid.deinit();
    try renderBoardRows(&vivid.writer, arena, board.league, board.games, "", 0, 0, 10, .{ .color = true });
    // Dim heading, red live status, yellow upcoming status, green winner.
    try std.testing.expect(std.mem.indexOf(u8, vivid.written(), "\x1b[2mGAMES\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, vivid.written(), "\x1b[1;31m") != null);
    try std.testing.expect(std.mem.indexOf(u8, vivid.written(), "\x1b[33m") != null);
    try std.testing.expect(std.mem.indexOf(u8, vivid.written(), "\x1b[32m") != null);
}

// ---------------------------------------------------------------------------
// Flicker-gate tests: the counting double observes one content hash per
// tick and counts full-screen vs footer-line writes (fake transport +
// fixtures only, no network, no TTY).
// ---------------------------------------------------------------------------

test "paint gate hashes frames stably" {
    const a = hashFrame("MLB\nrow");
    const b = hashFrame("MLB\nrow");
    const c = hashFrame("MLB\nchanged");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}

test "footer refresh throttles to one line write per window" {
    try std.testing.expect(footerDue(100, null));
    try std.testing.expect(!footerDue(101, 100));
    try std.testing.expect(!footerDue(104, 100));
    try std.testing.expect(footerDue(105, 100));
    try std.testing.expect(footerDue(200, 100));
}

test "sse refetch debounces rapid frames" {
    try std.testing.expect(sseApplyDue(50, null));
    try std.testing.expect(sseShouldApply(50, null, true));
    try std.testing.expect(!sseShouldApply(50, null, false));
    // Burst 1s after the last apply defers; past the window it applies.
    try std.testing.expect(!sseShouldApply(51, 50, true));
    try std.testing.expect(sseShouldApply(52, 50, true));
    // Unchanged hashes never refetch, inside the window or out.
    try std.testing.expect(!sseShouldApply(51, 50, false));
    try std.testing.expect(!sseShouldApply(500, 50, false));
}

test "paint decisions never spend a full repaint on the footer" {
    try std.testing.expectEqual(PaintDecision.full, decidePaint(true, false));
    try std.testing.expectEqual(PaintDecision.full, decidePaint(true, true));
    try std.testing.expectEqual(PaintDecision.footer_only, decidePaint(false, true));
    try std.testing.expectEqual(PaintDecision.none, decidePaint(false, false));
}

test "steady ticks repaint once per K observations" {
    var gate = FrameDeduper{};
    const content = hashFrame("mlb board bytes");
    const ticks: i64 = 30;
    var t: i64 = 1000;
    while (t < 1000 + ticks) : (t += 1) _ = gate.observe(t, content);
    // Exactly one full paint for the whole steady run...
    try std.testing.expectEqual(@as(usize, 1), gate.full_paints);
    // ...with the footer line throttled to its 5s cadence, never full.
    try std.testing.expect(gate.footer_paints <= @divTrunc(@as(usize, @intCast(ticks)), @as(usize, @intCast(footer_throttle_s))) + 1);
    // A real content change earns exactly one more full paint.
    _ = gate.observe(1000 + ticks, hashFrame("mlb board bytes*"));
    try std.testing.expectEqual(@as(usize, 2), gate.full_paints);
}

test "footer tick alone never triggers a full repaint" {
    var gate = FrameDeduper{};
    const content = hashFrame("steady board");
    try std.testing.expectEqual(PaintDecision.full, gate.observe(1000, content));
    var t: i64 = 1001;
    while (t < 1100) : (t += 1) {
        const decision = gate.observe(t, content);
        try std.testing.expect(decision != .full);
    }
    try std.testing.expectEqual(@as(usize, 1), gate.full_paints);
    try std.testing.expect(gate.footer_paints > 0);
}

test "help overlay suppresses the footer line" {
    var gate = FrameDeduper{};
    const help = hashFrame("help overlay");
    try std.testing.expectEqual(PaintDecision.full, gate.observeMasked(1000, help, false));
    // Footer due but masked: silence, no footer write over the overlay.
    try std.testing.expectEqual(PaintDecision.none, gate.observeMasked(1006, help, false));
    try std.testing.expectEqual(@as(usize, 0), gate.footer_paints);
    // Same state unmasked: the footer line fires.
    try std.testing.expectEqual(PaintDecision.footer_only, gate.observeMasked(1006, help, true));
}

test "footer owns the bottom terminal rows" {
    try std.testing.expectEqual(@as(usize, 24), footerRow(24, 0, 1));
    try std.testing.expectEqual(@as(usize, 23), footerRow(24, 0, 2));
    try std.testing.expectEqual(@as(usize, 24), footerRow(24, 1, 2));
    try std.testing.expectEqual(@as(usize, 2), footerRow(2, 1, 2));
}

test "board content bytes ignore the age ticker but move with selection" {
    // Drives the real `Tui` content probe over the fake transport: the
    // per-second footer age must not change the gated hash, while a vim
    // `j` step must (navigation still repaints).
    var fake = FakeTransportState{ .body = canned_board };
    var tui = try Tui.init(std.testing.allocator, flowIo(), fake.asTransport(), "https://example.test", .{ .view = .board, .league = "mlb", .target = "", .date = "2026-09-06" });
    defer tui.deinit();
    tui.loadCurrent();
    try std.testing.expect(tui.board != null);

    const before = try tui.buildContentBytes();
    defer std.testing.allocator.free(before);
    // Thirty seconds of footer ticks: identical content bytes.
    tui.last_update_s = (tui.last_update_s orelse 0) -| 30;
    const after_ticks = try tui.buildContentBytes();
    defer std.testing.allocator.free(after_ticks);
    try std.testing.expectEqualStrings(before, after_ticks);

    var gate = FrameDeduper{};
    _ = gate.observe(1000, hashFrame(before));
    try std.testing.expect(gate.observe(1030, hashFrame(after_ticks)) != .full);
    try std.testing.expectEqual(@as(usize, 1), gate.full_paints);

    // One `j` step moves the gutter: new bytes, full repaint due.
    tui.selected = moveDown(tui.selected, tui.rowCount(), 1);
    const moved = try tui.buildContentBytes();
    defer std.testing.allocator.free(moved);
    try std.testing.expect(!std.mem.eql(u8, before, moved));
    try std.testing.expectEqual(PaintDecision.full, gate.observe(1031, hashFrame(moved)));
}
