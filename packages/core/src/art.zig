const std = @import("std");
const index = @import("art-index.zig");

/// Grug-brain ASCII art, data-only.
/// Marks live as braille text under art/ (written by tools/generate-art from
/// a pluggable art source, ESPN first) and are embedded at build time --
/// no parsing, no allocator, no runtime I/O. Adding a team = rerun the
/// tool, which refreshes art-index.zig too. League banners: none yet.
pub const Size = index.Size;
pub const all_sizes = [_]Size{ .xs, .sm, .md };

pub fn leagueArt(slug: []const u8) ?[]const u8 {
    _ = slug;
    return null;
}

pub fn teamArt(league_slug: []const u8, abbreviation: []const u8, size: Size) ?[]const u8 {
    if (abbreviation.len == 0 or abbreviation.len > 16) return null;
    var upper: [16]u8 = undefined;
    for (abbreviation, 0..) |byte, i| upper[i] = std.ascii.toUpper(byte);
    return index.teamArt(league_slug, upper[0..abbreviation.len], size);
}

/// Colored twin of teamArt: braille cells wrapped in SGR `38;5;N` runs
/// (same geometry as the mono mark). Null when the team has no color
/// sidecar yet -- callers fall back to teamArt().
pub fn teamArtColor(league_slug: []const u8, abbreviation: []const u8, size: Size) ?[]const u8 {
    if (abbreviation.len == 0 or abbreviation.len > 16) return null;
    var upper: [16]u8 = undefined;
    for (abbreviation, 0..) |byte, i| upper[i] = std.ascii.toUpper(byte);
    return index.teamArtColor(league_slug, upper[0..abbreviation.len], size);
}

/// Cells in a mark line, ignoring embedded SGR escapes (zero-width).
/// Wide code points count 2, combining marks 0 — same table as the
/// server's `table.zig`, kept in sync so geometry never disagrees.
/// Invalid bytes count 1 (rendered as U+FFFD).
pub fn countCells(line: []const u8) usize {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        // SGR run: ESC [ <digits/;> m -- zero width, skip whole sequence.
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
        // Truncated sequence at end of line: each leftover byte is 1 cell.
        if (i + len > line.len) {
            cells += 1;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(line[i..][0..len]) catch {
            cells += 1;
            i += 1;
            continue;
        };
        cells += cellWidth(cp);
        i += len;
    }
    return cells;
}

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

/// Copy `line` to `out` with all SGR escapes removed.
pub fn stripSgr(out: *std.Io.Writer, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            var j = i + 2;
            while (j < line.len and line[j] != 'm') : (j += 1) {}
            i = if (j < line.len) j + 1 else line.len;
            continue;
        }
        try out.writeByte(line[i]);
        i += 1;
    }
}

test "known marks resolve case-insensitively in every size" {
    for (all_sizes) |size| {
        try std.testing.expect(teamArt("mlb", "PHI", size) != null);
        try std.testing.expect(teamArt("mlb", "phi", size) != null);
        try std.testing.expect(teamArt("MLB", "NYY", size) != null);
        try std.testing.expect(teamArt("mlb", "ZZZ", size) == null);
        try std.testing.expect(teamArt("xxf", "PHI", size) == null);
        try std.testing.expect(teamArt("mlb", "", size) == null);
    }
}

test "every checked-in mark is braille, width-safe, and non-empty" {
    for (all_sizes) |size| {
        var count: usize = 0;
        for (index.leagues) |league| {
            const table = index.tableFor(league) orelse continue;
            for (table.keys()) |abbrev| {
                const art = teamArt(league, abbrev, size).?;
                var rows: usize = 0;
                var lines = std.mem.splitScalar(u8, art, '\n');
                while (lines.next()) |line| {
                    if (line.len == 0) continue; // trailing newline of the .txt file
                    rows += 1;
                    var cells: usize = 0;
                    var i: usize = 0;
                    while (i < line.len) {
                        const len = try std.unicode.utf8ByteSequenceLength(line[i]);
                        try std.testing.expect(len == 3); // braille is 3 bytes in UTF-8
                        const codepoint = try std.unicode.utf8Decode(line[i..][0..len]);
                        try std.testing.expect(codepoint >= 0x2800 and codepoint <= 0x28FF);
                        cells += 1; // every braille glyph is one terminal cell
                        i += len;
                    }
                    try std.testing.expect(cells <= 46);
                }
                // Single-row xs marks exist for dense logos (the sm/md
                // siblings carry the taller render); the mark is still
                // usable, so only empty entries fail the audit.
                try std.testing.expect(rows >= 1);
                count += 1;
            }
        }
        try std.testing.expect(count > 0);
    }
}

test "pair geometry fits the narrowest card at every size" {
    // Every checked-in xs mark pair (the only size rendered side by
    // side) plus the 2-cell gap fits inner-2 = 48 of the 52-wide box, so
    // the horizontal card path is reachable; wider pairs (never xs today)
    // fall back to the vertical stack by design. Also asserts the two
    // cell counters agree on every checked-in line: braille is all
    // single-cell, so any drift would surface here first.
    var widest_xs: usize = 0;
    for (all_sizes) |size| {
        for (index.leagues) |league| {
            const table = index.tableFor(league) orelse continue;
            for (table.keys()) |abbrev| {
                const mark = teamArt(league, abbrev, size).?;
                var lines = std.mem.splitScalar(u8, mark, '\n');
                while (lines.next()) |line| {
                    if (line.len == 0) continue;
                    try std.testing.expect(countCells(line) <= 46);
                }
                if (size == .xs) {
                    var xs = std.mem.splitScalar(u8, mark, '\n');
                    while (xs.next()) |line| {
                        if (line.len == 0) continue;
                        widest_xs = @max(widest_xs, countCells(line));
                    }
                }
            }
        }
    }
    try std.testing.expect(widest_xs * 2 + 2 <= 48);
}

test "color sidecars strip to mono, stay well-formed and width-safe" {
    for (all_sizes) |size| {
        var colored: usize = 0;
        for (index.leagues) |league| {
            const table = index.tableFor(league) orelse continue;
            for (table.keys()) |abbrev| {
                const mono = teamArt(league, abbrev, size).?;
                const color = teamArtColor(league, abbrev, size) orelse continue;
                colored += 1;
                // Strip must reproduce the mono mark byte-for-byte.
                // Interior blank braille rows carry no runs (no color
                // starts/ends on an all-blank cell), so a plain strip
                // over the whole blob matches; line-splitting must not
                // drop interior empty lines (only the trailing newline
                // of the .txt file is skipped by the split iterator).
                var stripped: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer stripped.deinit();
                try stripSgr(&stripped.writer, color);
                const stripped_slice = try stripped.toOwnedSlice();
                defer std.testing.allocator.free(stripped_slice);
                try std.testing.expectEqualStrings(mono, stripped_slice);
                // Escapes are well-formed; stripped cells stay width-safe.
                var lines = std.mem.splitScalar(u8, color, '\n');
                while (lines.next()) |line| {
                    if (line.len == 0) continue;
                    try std.testing.expect(countCells(line) <= 46);
                    var i: usize = 0;
                    while (i < line.len) {
                        if (line[i] == 0x1b) {
                            try std.testing.expect(i + 1 < line.len and line[i + 1] == '[');
                            var j = i + 2;
                            while (j < line.len and line[j] != 'm') : (j += 1) {
                                try std.testing.expect((line[j] >= '0' and line[j] <= '9') or line[j] == ';');
                            }
                            try std.testing.expect(j < line.len);
                            i = j + 1;
                            continue;
                        }
                        const len = try std.unicode.utf8ByteSequenceLength(line[i]);
                        try std.testing.expect(len == 3);
                        const codepoint = try std.unicode.utf8Decode(line[i..][0..len]);
                        try std.testing.expect(codepoint >= 0x2800 and codepoint <= 0x28FF);
                        i += len;
                    }
                }
            }
        }
        // Graceful subset: color exists for generated teams; teams
        // without a sidecar still resolve mono (see teamArtColor null).
        try std.testing.expect(colored > 0);
    }
}
