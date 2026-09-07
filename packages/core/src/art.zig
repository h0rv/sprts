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
