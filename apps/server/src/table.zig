//! Shared box-table primitives: the ONE hardened path for every text
//! table in this binary (scoreboard `render.text`, `detail_view`, `team_view`).
//!
//! Previously each renderer owned a private copy, and the copies disagreed:
//! `render.zig` padded by cells while `detail_view.zig` padded by bytes, so
//! multibyte names aligned in one view and drifted in another. All views now
//! import this module; the duplicates are deleted.
//!
//! Width model: terminal cells, not bytes. East-Asian wide code points count
//! 2, combining marks count 0, everything else (Latin, box rules, braille
//! U+2800-U+28FF, ellipsis, check) counts 1. Invalid UTF-8 bytes render as
//! U+FFFD (1 cell) so output stays valid UTF-8.
//!
//! Sanitization: ESPN strings arrive via JSON, which can legally carry `\n`,
//! `\r`, `\t`, and other C0/C1 controls inside display names, statuses,
//! records, venues, and play text. A raw `\n` would split the row and break
//! the frame, `\t` expands to tab stops (misaligns), and a raw ESC would
//! inject ANSI even when color is off. Every control is therefore rendered
//! as one blank cell (ASCII space). SGR color wraps the fitted bytes only
//! and is never part of the width.
//!
//! Art lines are the exception: colored marks embed SGR runs, which are
//! zero-width and skipped by `countCells` (used only for mark geometry, and
//! by `writeArtRow`/`writeGameMarks` which render trusted embedded marks,
//! never ESPN strings). Interior blank rows inside a mark are preserved as
//! blank cells: dropping them (as the old inline copy did) vertically
//! compresses disconnected logos (e.g. MLS ATX/HOU xs marks); only the
//! single trailing empty from the file's final newline is skipped.

const std = @import("std");
const core = @import("sprts_core");
const domain = core.domain;

pub const Rule = enum { top, mid, bottom };

/// Terminal cells for one code point: 0 for combining marks, 2 for
/// East-Asian wide (musl/mk_wcwidth table), 1 for everything else.
/// Controls are 1: they render as one blank cell (see `writeSanitized`).
fn cellWidth(cp: u21) usize {
    if (isCombining(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

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
        cp == 0x26CE or cp == 0x26D4 or cp == 0x26EA or
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
/// U+FFFD with length 1 so every consumer stays in lockstep.
fn decode(s: []const u8, i: usize) struct { len: usize, cp: u21 } {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .len = 1, .cp = 0xFFFD };
    if (i + len > s.len) return .{ .len = 1, .cp = 0xFFFD };
    const cp = std.unicode.utf8Decode(s[i..][0..len]) catch return .{ .len = 1, .cp = 0xFFFD };
    return .{ .len = len, .cp = cp };
}

fn isControl(cp: u21) bool {
    return cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F);
}

/// Terminal cells in a mark line. Marks may embed SGR color runs, which are
/// zero-width and skipped. Invalid bytes count 1 (rendered as U+FFFD).
/// Text cells (names, statuses) must use `textCells` instead: raw ESC there
/// sanitizes to a visible blank rather than vanishing.
pub fn countCells(line: []const u8) usize {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            var j = i + 2;
            while (j < line.len and line[j] != 'm') : (j += 1) {}
            i = if (j < line.len) j + 1 else line.len;
            continue;
        }
        const d = decode(line, i);
        cells += cellWidth(d.cp);
        i += d.len;
    }
    return cells;
}

/// Terminal cells in a text cell (name, status, record): no SGR skipping —
/// ESC and every other control renders as one blank cell.
pub fn textCells(s: []const u8) usize {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decode(s, i);
        cells += cellWidth(d.cp);
        i += d.len;
    }
    return cells;
}

/// Fits `s` into `width` columns, truncating at a code point boundary
/// with an ellipsis when too long. Unchanged byte-budget truncation
/// (verbatim from the old `render.fit`): only the padding in the callers
/// moved from bytes to cells. Kept byte-identical so existing renders
/// do not shift by even one column.
pub fn fit(s: []const u8, width: usize) struct { usize, bool } {
    if (s.len <= width) return .{ s.len, false };
    if (width < 4) return .{ 0, true };
    var end: usize = width - 3;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return .{ end, true };
}

/// Copy `s[0..end]` with hardening: controls (`\n`, `\r`, `\t`, ESC, and
/// the rest of C0/C1 plus DEL) become one ASCII space each, invalid bytes
/// become U+FFFD. Emitted cells always equal `textCells(s[0..end])`.
fn writeSanitized(w: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const d = decode(s, i);
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

/// Writes `s` fitted to exactly `width` cells, truncating at a code point
/// boundary with an ellipsis when too long. Escape bytes are never part of
/// the width: color wraps the fitted bytes only.
pub fn writeCell(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    const end, const ellipsis = fit(s, width);
    const use_color = color and code != null;
    if (use_color) try w.print("\x1b[{s}m", .{code.?});
    try writeSanitized(w, s[0..end]);
    if (ellipsis) try w.writeAll("…");
    if (use_color) try w.writeAll("\x1b[0m");
    const n_written: usize = textCells(s[0..end]) + (if (ellipsis) @as(usize, 1) else 0);
    var i: usize = n_written;
    while (i < width) : (i += 1) try w.writeByte(' ');
}

pub fn writeCellRight(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    const end, const ellipsis = fit(s, width);
    const use_color = color and code != null;
    const n_written: usize = textCells(s[0..end]) + (if (ellipsis) @as(usize, 1) else 0);
    var spaces: usize = width -| n_written;
    while (spaces > 0) : (spaces -= 1) try w.writeByte(' ');
    if (use_color) try w.print("\x1b[{s}m", .{code.?});
    try writeSanitized(w, s[0..end]);
    if (ellipsis) try w.writeAll("…");
    if (use_color) try w.writeAll("\x1b[0m");
}

pub fn writeRow(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    try w.writeAll("│ ");
    try writeCell(w, s, width, code, color);
    try w.writeAll(" │\n");
}

/// One borderless content line: `s` fitted to `width` cells (truncate at
/// a code-point boundary with an ellipsis when too long, never padded),
/// optional SGR around the fitted bytes only, then a newline. The
/// document-style views (game detail, team) build from these with blank
/// lines between sections instead of rules; the scoreboard keeps the box.
/// Column rows compose `writeCell`/`writeCellRight` in a buffer first
/// (their padding is interior there), trim trailing blanks, and emit the
/// buffer with a plain write plus newline.
pub fn writeLine(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    const end, const ellipsis = fit(s, width);
    const use_color = color and code != null;
    if (use_color) try w.print("\x1b[{s}m", .{code.?});
    try writeSanitized(w, s[0..end]);
    if (ellipsis) try w.writeAll("…");
    if (use_color) try w.writeAll("\x1b[0m");
    try w.writeByte('\n');
}

pub fn writeRule(w: *std.Io.Writer, which: Rule, inner: usize) !void {
    const left: []const u8 = switch (which) {
        .top => "┌",
        .mid => "├",
        .bottom => "└",
    };
    const right: []const u8 = switch (which) {
        .top => "┐\n",
        .mid => "┤\n",
        .bottom => "┘\n",
    };
    try w.writeAll(left);
    var i: usize = 0;
    while (i < inner) : (i += 1) try w.writeAll("─");
    try w.writeAll(right);
}

/// A blank spacer row: `│` borders with nothing between, so sections
/// breathe without breaking the table frame. The home page separates
/// sections with spacers instead of mid rules; other views keep their
/// own rule rhythm. Shared here so every view breathes the same way.
pub fn spacerRow(w: *std.Io.Writer, inner: usize) !void {
    try w.writeAll("│ ");
    var i: usize = 0;
    while (i < inner - 2) : (i += 1) try w.writeByte(' ');
    try w.writeAll(" │\n");
}

pub const Table = struct {
    writer: *std.Io.Writer,
    inner: usize,
    color: bool,

    pub fn rule(self: Table, which: Rule) !void {
        try writeRule(self.writer, which, self.inner);
    }

    pub fn row(self: Table, line: []const u8, code: ?[]const u8) !void {
        try writeRow(self.writer, line, self.inner - 2, code, self.color);
    }

    pub fn participantRow(self: Table, participant: domain.Participant) !void {
        const mark: ?[]const u8 = if (participant.winner) "32" else null;
        const w = self.writer;
        const inner = self.inner;
        const suffix_len: usize = if (participant.record) |record|
            2 + textCells(record) + 1
        else
            0;
        try w.writeAll("│ ");
        // Fixed cells around the name: abbr 4 + spaces 2 + score 4 + check 2.
        var name_width: usize = undefined;
        if (participant.abbreviation.len > 0) {
            try writeCell(w, participant.abbreviation, 4, mark, self.color);
            try w.writeByte(' ');
            name_width = inner - 2 - 12;
        } else {
            // Athlete identities carry no abbreviation: the name absorbs
            // the abbr cell plus its separator.
            name_width = inner - 2 - 7;
        }
        name_width = name_width -| suffix_len;
        try writeCell(w, participant.name, name_width, mark, self.color);
        try w.writeByte(' ');
        try writeCellRight(w, participant.score, 4, mark, self.color);
        if (participant.record) |record| {
            const use_color = self.color and mark != null;
            if (use_color) try w.print("\x1b[{s}m", .{mark.?});
            try w.writeAll(" (");
            try writeSanitized(w, record);
            try w.writeByte(')');
            if (use_color) try w.writeAll("\x1b[0m");
        }
        if (participant.winner) {
            if (self.color) try w.writeAll("\x1b[32m");
            try w.writeAll(" ✓");
            if (self.color) try w.writeAll("\x1b[0m");
        } else {
            try w.writeAll("  ");
        }
        try w.writeAll(" │\n");
    }
};

/// Art rows are braille: 3 bytes per glyph but one terminal cell each, so
/// byte-based slicing would split glyphs and break the rules. Pads by
/// visible cells; the tool guarantees single-cell glyphs.
/// RGB for an xterm-256 index: indices 16-231 are the 6x6x6 cube over
/// (0,95,135,175,215,255), 232-255 the grayscale ramp. Indices 0-15 are
/// terminal-themed; marks never use them, and they read as dark here so
/// they get filtered.
fn xtermRgb(idx: u8) [3]u16 {
    if (idx >= 232) {
        const v: u16 = 8 + 10 * @as(u16, idx - 232);
        return .{ v, v, v };
    }
    if (idx >= 16) {
        const levels = [_]u16{ 0, 95, 135, 175, 215, 255 };
        const k: usize = idx - 16;
        return .{ levels[k / 36], levels[(k / 6) % 6], levels[k % 6] };
    }
    return .{ 0, 0, 0 };
}

/// True when an xterm color is too dark to read on a dark terminal
/// background (gruvbox-dark and friends): near-black logo ink rendered
/// in SGR black is invisible, while the terminal foreground (mono mark)
/// always reads. Threshold is relative luminance below ~48/255.
fn isDarkXterm(idx: u8) bool {
    const rgb = xtermRgb(idx);
    // Rec. 709 luma, integer math: 2126*R + 7152*G + 722*B < 48*10000.
    const luma = 2126 * @as(u32, rgb[0]) + 7152 * @as(u32, rgb[1]) + 722 * @as(u32, rgb[2]);
    return luma < 480000;
}

/// Copy a (possibly colored) mark line, dropping SGR `38;5;N` runs whose
/// palette index is unreadably dark and keeping the glyphs. Other runs
/// (resets) pass through so open spans still close. Keeps logo ink
/// visible on dark terminals without regenerating the data files.
fn writeContrastLine(w: *std.Io.Writer, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            var j = i + 2;
            while (j < line.len and line[j] != 'm') : (j += 1) {}
            if (j >= line.len) return;
            const seq = line[i .. j + 1];
            if (parseXtermIndex(seq)) |idx| {
                if (!isDarkXterm(idx)) try w.writeAll(seq);
            } else {
                try w.writeAll(seq);
            }
            i = j + 1;
            continue;
        }
        try w.writeByte(line[i]);
        i += 1;
    }
}

/// Parse `ESC[38;5;Nm` into N. Null for resets and anything else.
fn parseXtermIndex(seq: []const u8) ?u8 {
    const prefix = "\x1b[38;5;";
    if (seq.len <= prefix.len or !std.mem.startsWith(u8, seq, prefix)) return null;
    if (seq[seq.len - 1] != 'm') return null;
    const digits = seq[prefix.len .. seq.len - 1];
    if (digits.len == 0 or digits.len > 3) return null;
    var n: u16 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    if (n > 255) return null;
    return @intCast(n);
}

/// Copy a colored mark line to HTML: each SGR `38;5;N` run becomes an
/// rgb span, resets close the open span. Glyph bytes escape via `esc`.
/// `esc` escapes one byte (`&<>"'`); the caller supplies render's
/// escapeCellInto-compatible shim. Uncolored lines emit plain glyphs.
pub fn writeArtLineHtml(
    w: *std.Io.Writer,
    line: []const u8,
    esc: *const fn (*std.Io.Writer, u8) anyerror!void,
) !void {
    var buf: [64]u8 = undefined;
    var open = false;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            var j = i + 2;
            while (j < line.len and line[j] != 'm') : (j += 1) {}
            if (j >= line.len) return;
            const seq = line[i .. j + 1];
            if (parseXtermIndex(seq)) |idx| {
                if (open) try w.writeAll("</span>");
                const rgb = xtermRgb(idx);
                const span = std.fmt.bufPrint(&buf, "<span style=\"color:rgb({d},{d},{d})\">", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable;
                try w.writeAll(span);
                open = true;
            } else {
                if (open) {
                    try w.writeAll("</span>");
                    open = false;
                }
            }
            i = j + 1;
            continue;
        }
        try esc(w, line[i]);
        i += 1;
    }
    if (open) try w.writeAll("</span>");
}

pub fn writeArtRow(w: *std.Io.Writer, line: []const u8, inner: usize) !void {
    try w.writeAll("│ ");
    try writeContrastLine(w, line);
    var i: usize = countCells(line);
    while (i < inner - 2) : (i += 1) try w.writeByte(' ');
    try w.writeAll(" │\n");
}

/// One braille art row as HTML: SGR color runs become rgb spans via
/// `writeArtLineHtml`, uncolored glyphs pass through escaped. Padding
/// uses visible cells so the frame aligns with the text renderer.
pub fn writeArtRowHtml(allocator: std.mem.Allocator, w: *std.Io.Writer, line: []const u8, inner: usize) !void {
    var cell: std.Io.Writer.Allocating = .init(allocator);
    defer cell.deinit();
    try writeArtLineHtml(&cell.writer, line, escapeByte);
    const frag = try cell.toOwnedSlice();
    defer allocator.free(frag);
    try w.writeAll("│ ");
    try w.writeAll(frag);
    var i: usize = countCells(line);
    while (i < inner - 2) : (i += 1) try w.writeByte(' ');
    try w.writeAll(" │\n");
}

fn escapeByte(w: *std.Io.Writer, b: u8) !void {
    switch (b) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(b),
    }
}

/// Both teams' marks side by side at `.xs`: a horizontal card instead of
/// a tall stacked block. A side with no mark is skipped; if the pair is
/// wider than the box, the marks stack vertically. When `color` is set and
/// a team has a color sidecar, the colored mark renders; otherwise (or
/// with color=false) the mono mark renders, so `?color=0` strips ALL color.
/// Interior blank rows are preserved as blank cells (only the file's
/// trailing newline is skipped) so disconnected logos keep their shape.
pub fn writeGameMarks(w: *std.Io.Writer, allocator: std.mem.Allocator, league: []const u8, game: *const domain.Game, inner: usize, color: bool) !void {
    var marks: [2][]const u8 = undefined;
    var n: usize = 0;
    for (game.participants) |p| {
        if (n == marks.len) break;
        const mark = if (color)
            core.art.teamArtColor(league, p.abbreviation, .xs) orelse
                core.art.teamArt(league, p.abbreviation, .xs)
        else
            core.art.teamArt(league, p.abbreviation, .xs);
        if (mark) |m| {
            marks[n] = m;
            n += 1;
        }
    }
    if (n == 0) return;

    var rows: [2]std.ArrayList([]const u8) = .{ .empty, .empty };
    defer for (rows[0..n]) |*r| r.deinit(allocator);
    var widths: [2]usize = .{ 0, 0 };
    for (marks[0..n], 0..) |mark, i| {
        var lines = std.mem.splitScalar(u8, mark, '\n');
        // Drop only the trailing empty from the file's final newline;
        // interior blanks are real logo rows.
        var collected: std.ArrayList([]const u8) = .empty;
        defer collected.deinit(allocator);
        while (lines.next()) |line| try collected.append(allocator, line);
        if (collected.items.len > 0 and collected.items[collected.items.len - 1].len == 0)
            _ = collected.pop();
        for (collected.items) |line| {
            widths[i] = @max(widths[i], countCells(line));
            try rows[i].append(allocator, line);
        }
    }

    const gap: usize = 2;
    if (n < 2 or widths[0] + gap + widths[1] > inner - 2) {
        for (rows[0..n]) |list| {
            for (list.items) |line| {
                if (line.len == 0) {
                    try w.writeAll("│ ");
                    var i: usize = 0;
                    while (i < inner - 2) : (i += 1) try w.writeByte(' ');
                    try w.writeAll(" │\n");
                } else {
                    try writeArtRow(w, line, inner);
                }
            }
        }
        return;
    }
    const height = @max(rows[0].items.len, rows[1].items.len);
    for (0..height) |r| {
        try w.writeAll("│ ");
        for (0..2) |i| {
            if (i == 1) {
                var g: usize = 0;
                while (g < gap) : (g += 1) try w.writeByte(' ');
            }
            const line = if (r < rows[i].items.len) rows[i].items[r] else "";
            try w.writeAll(line);
            var pad: usize = widths[i] - countCells(line);
            while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        }
        var fill: usize = inner - 2 - (widths[0] + gap + widths[1]);
        while (fill > 0) : (fill -= 1) try w.writeByte(' ');
        try w.writeAll(" │\n");
    }
}

// --- Hardened-path battery: one frame, aligned, valid UTF-8, zero escapes
// with color off. Helpers mirror the alignment checks in render.zig's tests
// but are ANSI- and wide-aware so they hold for hostile strings too. ---

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

fn frameWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decode(s, i);
        w += cellWidth(d.cp);
        i += d.len;
    }
    return w;
}

fn expectOneFrame(output: []const u8, total_width: usize, color: bool) !void {
    _ = try std.unicode.Utf8View.init(output);
    if (!color) try std.testing.expect(std.mem.indexOf(u8, output, "\x1b") == null);
    var stripped: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stripped.deinit();
    try stripAnsi(&stripped.writer, output);
    const slice = try stripped.toOwnedSlice();
    defer std.testing.allocator.free(slice);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, slice, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Only frame lines participate: rules and rows start with a
        // 3-byte box glyph; nav/hint lines live outside the table.
        if (line[0] != 0xE2) continue;
        try std.testing.expectEqual(total_width, frameWidth(line));
        // No smuggled control bytes inside the frame.
        for (line) |b| try std.testing.expect(b >= 0x20 or b == 0xE2 or (b & 0xC0) == 0x80);
        count += 1;
    }
    try std.testing.expect(count > 0);
}

fn hostileBoard() domain.Scoreboard {
    return .{
        .league = "mlb",
        .league_name = "MLB",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "Away\nat Home",
                .starts_at = "2026-09-06T17:00Z",
                .state = "in",
                .status = "Top 7th\nExtra",
                .participants = &.{
                    .{ .id = "a", .name = "Atlético Madrid Club de Fútbol with an extremely long tail that never ends \x1b[31m", .abbreviation = "AWY", .score = "2", .winner = false, .record = "69-74\r\nx" },
                    .{ .id = "h", .name = "Home\tTeam", .abbreviation = "", .score = "", .winner = true },
                },
            },
            .{
                .id = "2",
                .name = "漢字 Team 日本語の非常に長い名前で枠を超える",
                .starts_at = "2026-09-06T19:00Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{},
            },
        },
    };
}

fn renderBoard(allocator: std.mem.Allocator, board: domain.Scoreboard, color: bool, width: u16) ![]u8 {
    const inner: usize = @min(@max(width, 52), 200) - 2;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const table = Table{ .writer = w, .inner = inner, .color = color };
    try table.rule(.top);
    const heading = try std.fmt.allocPrint(allocator, "{s}  {s}", .{ board.league_name, board.date });
    defer allocator.free(heading);
    try table.row(heading, "2");
    for (board.games) |game| {
        try table.rule(.mid);
        try table.row(game.status, null);
        try writeGameMarks(w, allocator, board.league, &game, inner, color);
        if (game.participants.len == 0) {
            try table.row(game.name, null);
        }
        for (game.participants) |participant| {
            try table.participantRow(participant);
        }
    }
    try table.rule(.bottom);
    return out.toOwnedSlice();
}

test "hardened battery: hostile strings hold one frame at every width" {
    const board = hostileBoard();
    var width: u16 = 52;
    while (width <= 200) : (width += 1) {
        for ([2]bool{ false, true }) |color| {
            const output = try renderBoard(std.testing.allocator, board, color, width);
            defer std.testing.allocator.free(output);
            try expectOneFrame(output, width, color);
            if (!color) try std.testing.expect(std.mem.indexOf(u8, output, "\x1b") == null);
        }
    }
}

test "hardened battery: zero-participant and empty-abbr rows align" {
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
                },
            },
            .{
                .id = "2",
                .name = "Empty Grand Prix",
                .starts_at = "2026-09-06T11:30Z",
                .state = "pre",
                .status = "Scheduled",
                .participants = &.{},
            },
        },
    };
    var width: u16 = 52;
    while (width <= 200) : (width += 7) {
        const output = try renderBoard(std.testing.allocator, board, false, width);
        defer std.testing.allocator.free(output);
        try expectOneFrame(output, width, false);
    }
}

test "hardened battery: fit truncates at a code-point boundary" {
    // Byte-budget truncation, verbatim semantics from the old render.fit:
    // width 5 fits 2 bytes + ellipsis for this 9-byte string.
    const end, const ellipsis = fit("Atlético", 5);
    try std.testing.expect(ellipsis);
    try std.testing.expectEqual(@as(usize, 2), end);
    _ = try std.unicode.Utf8View.init("Atlético"[0..end]);
    const full, const fellipsis = fit("abc", 3);
    try std.testing.expect(!fellipsis);
    try std.testing.expectEqual(@as(usize, 3), full);
    // Controls count one cell each (rendered as blanks).
    try std.testing.expectEqual(@as(usize, 3), textCells("a\nb"));
    try std.testing.expectEqual(@as(usize, 1), textCells("\x1b"));
}

test "hardened battery: checked-in marks render within width" {
    // Spot-checks through the public art API (the same path renderers
    // use); the full-roster audit lives in `core.art`'s tests, extended
    // below this task to cover pair geometry. `countCells` must agree
    // with `core.art.countCells` on audited braille lines.
    const spots = [_]struct { league: []const u8, abbrev: []const u8 }{
        .{ .league = "mlb", .abbrev = "PHI" },
        .{ .league = "mlb", .abbrev = "NYM" },
        .{ .league = "mls", .abbrev = "ATX" },
        .{ .league = "mls", .abbrev = "HOU" },
    };
    for (core.art.all_sizes) |size| {
        for (spots) |spot| {
            const mark = core.art.teamArt(spot.league, spot.abbrev, size).?;
            var lines = std.mem.splitScalar(u8, mark, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                try std.testing.expect(countCells(line) <= 46);
                try std.testing.expectEqual(core.art.countCells(line), countCells(line));
            }
            if (core.art.teamArtColor(spot.league, spot.abbrev, size)) |color_mark| {
                var clines = std.mem.splitScalar(u8, color_mark, '\n');
                while (clines.next()) |line| {
                    if (line.len == 0) continue;
                    try std.testing.expect(countCells(line) <= 46);
                }
            }
        }
    }
    // Pair geometry: two xs marks plus the 2-cell gap fit the narrowest
    // card (inner 50 → 48 usable), so the side-by-side path is reachable.
    var widest: usize = 0;
    for (spots) |spot| {
        const mark = core.art.teamArt(spot.league, spot.abbrev, .xs).?;
        var lines = std.mem.splitScalar(u8, mark, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            widest = @max(widest, countCells(line));
        }
    }
    try std.testing.expect(widest * 2 + 2 <= 48);
}

// --- Byte-parity with the pre-consolidation render.zig (HEAD): OLD copies
// verbatim, asserting identical bytes on sanitization-free inputs. ---
const OldRule = enum { top, mid, bottom };
fn oldWriteRule(w: *std.Io.Writer, which: OldRule, inner: usize) !void {
    const left: []const u8 = switch (which) {
        .top => "┌",
        .mid => "├",
        .bottom => "└",
    };
    const right: []const u8 = switch (which) {
        .top => "┐\n",
        .mid => "┤\n",
        .bottom => "┘\n",
    };
    try w.writeAll(left);
    var i: usize = 0;
    while (i < inner) : (i += 1) try w.writeAll("─");
    try w.writeAll(right);
}
fn oldFit(s: []const u8, width: usize) struct { usize, bool } {
    if (s.len <= width) return .{ s.len, false };
    if (width < 4) return .{ 0, true };
    var end: usize = width - 3;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return .{ end, true };
}
fn oldCountVisibleCells(line: []const u8) usize {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            var j = i + 2;
            while (j < line.len and line[j] != 'm') : (j += 1) {}
            i = if (j < line.len) j + 1 else line.len;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch {
            cells += 1;
            i += 1;
            continue;
        };
        cells += 1;
        i += len;
    }
    return cells;
}
fn oldWriteCell(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    const end, const ellipsis = oldFit(s, width);
    const use_color = color and code != null;
    if (use_color) try w.print("\x1b[{s}m", .{code.?});
    try w.writeAll(s[0..end]);
    if (ellipsis) try w.writeAll("…");
    if (use_color) try w.writeAll("\x1b[0m");
    const n_written: usize = oldCountVisibleCells(s[0..end]) + (if (ellipsis) @as(usize, 1) else 0);
    var i: usize = n_written;
    while (i < width) : (i += 1) try w.writeByte(' ');
}
fn oldWriteCellRight(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    const end, const ellipsis = oldFit(s, width);
    const use_color = color and code != null;
    const n_written: usize = oldCountVisibleCells(s[0..end]) + (if (ellipsis) @as(usize, 1) else 0);
    var spaces: usize = width -| n_written;
    while (spaces > 0) : (spaces -= 1) try w.writeByte(' ');
    if (use_color) try w.print("\x1b[{s}m", .{code.?});
    try w.writeAll(s[0..end]);
    if (ellipsis) try w.writeAll("…");
    if (use_color) try w.writeAll("\x1b[0m");
}
fn oldWriteRow(w: *std.Io.Writer, s: []const u8, width: usize, code: ?[]const u8, color: bool) !void {
    try w.writeAll("│ ");
    try oldWriteCell(w, s, width, code, color);
    try w.writeAll(" │\n");
}

test "parity: rules, cells, rows, fit match pre-consolidation render" {
    const parity_fixtures = [_][]const u8{
        "Final",           "Top 7th",             "MLB  2026-09-06", "Away",     "Philadelphia Phillies",
        "Atlético Madrid Club de Fútbol with extra",
        "Hülkenberg",
        "Nico Hülkenberg",
        "Charles Leclerc", "69-74",               "2",               "5",        "AWY",
        "",                "No games scheduled.", "+1 more",         "LIVE NOW", "TODAY",
        "ALL LEAGUES",
    };
    for ([3]usize{ 50, 78, 198 }) |inner| {
        for ([3]OldRule{ .top, .mid, .bottom }) |r| {
            var a: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer a.deinit();
            try oldWriteRule(&a.writer, r, inner);
            const as = try a.toOwnedSlice();
            defer std.testing.allocator.free(as);
            var b: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer b.deinit();
            try writeRule(&b.writer, @as(Rule, @enumFromInt(@intFromEnum(r))), inner);
            const bs = try b.toOwnedSlice();
            defer std.testing.allocator.free(bs);
            try std.testing.expectEqualStrings(as, bs);
        }
    }
    for (parity_fixtures) |s| {
        for ([_]usize{ 0, 1, 2, 3, 4, 5, 8, 13, 34, 36, 44, 48 }) |w| {
            const oe, const ob = oldFit(s, w);
            const ne, const nb = fit(s, w);
            try std.testing.expectEqual(oe, ne);
            try std.testing.expectEqual(ob, nb);
        }
    }
    for (parity_fixtures) |s| {
        for ([_]usize{ 0, 1, 3, 4, 5, 13, 34, 48 }) |w| {
            for ([2]bool{ false, true }) |color| {
                for ([_]?[]const u8{ null, "2", "32", "1;31" }) |code| {
                    var a: std.Io.Writer.Allocating = .init(std.testing.allocator);
                    defer a.deinit();
                    try oldWriteCell(&a.writer, s, w, code, color);
                    const as = try a.toOwnedSlice();
                    defer std.testing.allocator.free(as);
                    var b: std.Io.Writer.Allocating = .init(std.testing.allocator);
                    defer b.deinit();
                    try writeCell(&b.writer, s, w, code, color);
                    const bs = try b.toOwnedSlice();
                    defer std.testing.allocator.free(bs);
                    try std.testing.expectEqualStrings(as, bs);

                    var c: std.Io.Writer.Allocating = .init(std.testing.allocator);
                    defer c.deinit();
                    try oldWriteCellRight(&c.writer, s, w, code, color);
                    const cs = try c.toOwnedSlice();
                    defer std.testing.allocator.free(cs);
                    var d: std.Io.Writer.Allocating = .init(std.testing.allocator);
                    defer d.deinit();
                    try writeCellRight(&d.writer, s, w, code, color);
                    const ds = try d.toOwnedSlice();
                    defer std.testing.allocator.free(ds);
                    try std.testing.expectEqualStrings(cs, ds);

                    var e: std.Io.Writer.Allocating = .init(std.testing.allocator);
                    defer e.deinit();
                    try oldWriteRow(&e.writer, s, w, code, color);
                    const es = try e.toOwnedSlice();
                    defer std.testing.allocator.free(es);
                    var f: std.Io.Writer.Allocating = .init(std.testing.allocator);
                    defer f.deinit();
                    try writeRow(&f.writer, s, w, code, color);
                    const fs = try f.toOwnedSlice();
                    defer std.testing.allocator.free(fs);
                    try std.testing.expectEqualStrings(es, fs);
                }
            }
        }
    }
    try std.testing.expectEqual(oldCountVisibleCells("⣠⣴⣶"), countCells("⣠⣴⣶"));
    try std.testing.expectEqual(
        oldCountVisibleCells("\x1b[38;5;196m⣠\x1b[0m⣴"),
        countCells("\x1b[38;5;196m⣠\x1b[0m⣴"),
    );
}

test "hardened battery: interior blank mark rows survive the card" { // MLS ATX xs carries interior empty rows (disconnected logo). The old
    // inline copy dropped every empty split line, compressing the logo;
    // the shared path preserves them as blank cells.
    const board: domain.Scoreboard = .{
        .league = "mls",
        .league_name = "MLS",
        .date = "2026-09-06",
        .source = "test",
        .games = &.{
            .{
                .id = "1",
                .name = "ATX at HOU",
                .starts_at = "2026-09-06T17:00Z",
                .state = "post",
                .status = "Final",
                .participants = &.{
                    .{ .id = "1", .name = "Austin FC", .abbreviation = "ATX", .score = "1", .winner = true },
                    .{ .id = "2", .name = "Houston Dynamo", .abbreviation = "HOU", .score = "0", .winner = false },
                },
            },
        },
    };
    const output = try renderBoard(std.testing.allocator, board, false, 52);
    defer std.testing.allocator.free(output);
    try expectOneFrame(output, 52, false);
    // Raw ATX xs rows (minus the file's trailing newline) each surface as
    // one card row: interior blanks included. ATX and HOU both carry 5
    // rows, so the 5-line card contains every row of each mark; counting
    // per-mark matches (blank card rows match both marks' blanks, and
    // padded short rows are substrings of the card line) proves no row
    // was dropped rather than asserting an exact line identity.
    const atx = core.art.teamArt("mls", "ATX", .xs).?;
    const hou = core.art.teamArt("mls", "HOU", .xs).?;
    var atx_rows: usize = 0;
    var split = std.mem.splitScalar(u8, atx, '\n');
    while (split.next()) |line| {
        if (split.index == null and line.len == 0) break; // trailing newline
        atx_rows += 1;
    }
    var hou_rows: usize = 0;
    var hsplit = std.mem.splitScalar(u8, hou, '\n');
    while (hsplit.next()) |line| {
        if (hsplit.index == null and line.len == 0) break;
        hou_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), atx_rows);
    try std.testing.expectEqual(@as(usize, 5), hou_rows);
    // Card height is the taller mark: ATX and HOU both carry 5 rows, so
    // the card has 5 art rows. Row index 2 is blank in BOTH marks (shared
    // gap), so braille rows = 4 and all-blank art rows = 1: the blank must
    // still be present as a padded frame row, proving interior blanks are
    // preserved rather than dropped (the old inline copy dropped them,
    // compressing the logo vertically).
    var card_rows: usize = 0;
    var out_lines = std.mem.splitScalar(u8, output, '\n');
    while (out_lines.next()) |line| {
        if (line.len == 0 or line[0] != 0xE2) continue;
        // Art rows carry braille U+2800-U+28FF (E2 A0 80 .. E2 A3 BF).
        var has_braille = false;
        var bi: usize = 0;
        while (bi + 2 < line.len) : (bi += 1) {
            if (line[bi] == 0xE2 and line[bi + 1] >= 0xA0 and line[bi + 1] <= 0xA3) {
                has_braille = true;
                break;
            }
        }
        if (!has_braille) continue;
        card_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), card_rows);
    // The shared-blank row renders as a frame row with no braille but
    // full frame width (interior to the card, between art rows).
    var seen_art = false;
    var blank_inside = false;
    out_lines = std.mem.splitScalar(u8, output, '\n');
    while (out_lines.next()) |line| {
        if (line.len == 0 or line[0] != 0xE2) continue;
        var has_braille = false;
        var bi: usize = 0;
        while (bi + 2 < line.len) : (bi += 1) {
            if (line[bi] == 0xE2 and line[bi + 1] >= 0xA0 and line[bi + 1] <= 0xA3) {
                has_braille = true;
                break;
            }
        }
        if (has_braille) {
            seen_art = true;
        } else if (seen_art) {
            blank_inside = true;
        }
    }
    try std.testing.expect(blank_inside);
}

test "dark logo ink is filtered for terminal contrast" {
    // Near-black (xterm 16) is dropped, readable red kept, resets pass
    // through so spans still close.
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeContrastLine(&out.writer, "\x1b[38;5;16m██\x1b[0m \x1b[38;5;196m██\x1b[0m");
    const got = try out.toOwnedSlice();
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("██\x1b[0m \x1b[38;5;196m██\x1b[0m", got);
    try std.testing.expect(isDarkXterm(16));
    try std.testing.expect(!isDarkXterm(196));
    try std.testing.expect(!isDarkXterm(226));
    try std.testing.expectEqual(@as(?u8, 196), parseXtermIndex("\x1b[38;5;196m"));
    try std.testing.expect(parseXtermIndex("\x1b[0m") == null);
}
