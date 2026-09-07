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
        cells += 1;
        i += len;
    }
    return cells;
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
