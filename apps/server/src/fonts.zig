//! Self-hosted webfonts: open-licensed woff2 checked into
//! `assets/fonts/` (provenance in `assets/fonts/PROVENANCE.txt`), served
//! same-origin at fingerprinted `/fonts/...` paths with long immutable
//! cache headers. No third-party CDN: the page must not phone home.
//!
//! Three faces, disjoint `unicode-range`s so no codepoint can split
//! across faces (a prior bug had proportional `Noto Sans Symbols 2`
//! mid-stack stealing digits while letters fell through to the terminal
//! monospace). Letters AND digits both live in the Latin1 file; box
//! drawing, blocks, and the winner tick ride the Pi file; team-mark art
//! rows (pure braille U+2800–U+28FF, enforced by the art tests) ride the
//! braille face. All three advances are 600/1000upm, so even mixed rows
//! keep one advance. Wiring is NOT done here: `router.zig` owns the
//! `/fonts/` match, `main.zig`/`worker.zig` own the serve arms (the
//! tour-asset/favicon pattern), and `render.zig` owns the `@font-face`
//! block in `page_style` via `font_face_css` below.

const std = @import("std");

/// Fingerprinted URL paths (sha256 prefix of the file bytes; immutable).
pub const latin_path = "/fonts/plex-mono-latin1-e8993d94.woff2";
pub const pi_path = "/fonts/plex-mono-pi-b8002770.woff2";
pub const braille_path = "/fonts/adwaita-mono-braille-4fa851e7.woff2";

/// IBM Plex Mono Regular, Latin1 subset (verbatim official IBM split
/// build): ASCII letters+digits+punctuation, Latin-1, smart quotes.
pub const latin_woff2 = @embedFile("assets/fonts/plex-mono-latin1-e8993d94.woff2");
/// IBM Plex Mono Regular, Pi subset (verbatim official IBM split build):
/// box drawing, blocks, winner tick, arrows.
pub const pi_woff2 = @embedFile("assets/fonts/plex-mono-pi-b8002770.woff2");
/// Adwaita Mono Regular subset to U+2800–U+28FF (pyftsubset woff2):
/// the designated braille face for team-mark art rows.
pub const braille_woff2 = @embedFile("assets/fonts/adwaita-mono-braille-4fa851e7.woff2");

pub const content_type = "font/woff2";
/// Fingerprinted bytes never change under a URL: cache for a year.
pub const cache_control = "public, max-age=31536000, immutable";

/// Family name shared by the Latin1 + Pi faces: one family, disjoint
/// ranges, so the browser merges them and no char splits across files.
pub const mono_family = "Sprts Mono";
/// Family name of the designated braille face (art rows lead with it).
pub const braille_family = "Sprts Braille";

/// Bare filenames (no `/fonts/` prefix), as carried by the route.
pub const latin_name = "plex-mono-latin1-e8993d94.woff2";
pub const pi_name = "plex-mono-pi-b8002770.woff2";
pub const braille_name = "adwaita-mono-braille-4fa851e7.woff2";

/// Route-name to bytes: null when the name is not a known font (the
/// router answers those as not_found, never as an empty 200).
pub fn find(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, latin_name)) return latin_woff2;
    if (std.mem.eql(u8, name, pi_name)) return pi_woff2;
    if (std.mem.eql(u8, name, braille_name)) return braille_woff2;
    return null;
}

/// `@font-face` block concatenated into the page `<style>` (see
/// `render.page_style`). `unicode-range`s are the files' own coverage:
/// IBM's published split ranges for Latin1/Pi, U+2800–28FF for the
/// braille subset. `font-display:swap` keeps first paint unblocked.
pub const font_face_css =
    \\@font-face{font-family:"Sprts Mono";font-style:normal;font-weight:400;font-display:swap;src:url("/fonts/plex-mono-latin1-e8993d94.woff2") format("woff2");unicode-range:U+0020-007E,U+00A0-00FF,U+0131,U+0152-0153,U+02C6,U+02DA,U+02DC,U+2013-2014,U+2018-201A,U+201C-201E,U+2020-2022,U+2026,U+2030,U+2039-203A,U+2044,U+20AC,U+2122,U+2212,U+FB01-FB02}@font-face{font-family:"Sprts Mono";font-style:normal;font-weight:400;font-display:swap;src:url("/fonts/plex-mono-pi-b8002770.woff2") format("woff2");unicode-range:U+03C0,U+0E3F,U+2000-200D,U+2010-2012,U+2015,U+2028-2029,U+202F,U+2032-2033,U+203E,U+205F,U+2070,U+2074-2079,U+2080-2089,U+2113,U+2116,U+2126,U+212E,U+2150-2151,U+2153-215E,U+2190-2199,U+21A9-21AA,U+21B0-21B3,U+21B6-21B7,U+21BA-21BB,U+21C4,U+21C6,U+2202,U+2206,U+220F,U+2211,U+2215,U+2219-221A,U+221E,U+222B,U+2236,U+2248,U+2260,U+2264-2265,U+2400-2421,U+2500-259F,U+25CA,U+2713,U+274C,U+2B0E-2B11,U+3000,U+FEFF,U+FFFD}@font-face{font-family:"Sprts Braille";font-style:normal;font-weight:400;font-display:swap;src:url("/fonts/adwaita-mono-braille-4fa851e7.woff2") format("woff2");unicode-range:U+2800-28FF}
;

test "vendored font bytes are present with pinned content type" {
    // The page only works when every face ships real bytes: an empty
    // embed (missing asset file) must fail here, not in a browser.
    try std.testing.expect(latin_woff2.len > 10_000);
    try std.testing.expect(pi_woff2.len > 10_000);
    try std.testing.expect(braille_woff2.len > 1_000);
    // woff2 magic: `wOF2`.
    for ([_][]const u8{ latin_woff2, pi_woff2, braille_woff2 }) |blob| {
        try std.testing.expect(std.mem.startsWith(u8, blob, "wOF2"));
    }
    try std.testing.expectEqualStrings("font/woff2", content_type);
    try std.testing.expectEqualStrings("public, max-age=31536000, immutable", cache_control);
}

test "font route names resolve to bytes, unknown names miss" {
    try std.testing.expect(find(latin_name) != null);
    try std.testing.expect(find(pi_name) != null);
    try std.testing.expect(find(braille_name) != null);
    try std.testing.expect(find("xterm.min.js") == null);
    try std.testing.expect(find("") == null);
    try std.testing.expect(find("plex-mono-latin1-e8993d93.woff2") == null);
    // Paths stay in sync with the route names.
    try std.testing.expect(std.mem.endsWith(u8, latin_path, latin_name));
    try std.testing.expect(std.mem.endsWith(u8, pi_path, pi_name));
    try std.testing.expect(std.mem.endsWith(u8, braille_path, braille_name));
}

test "font-face block names every fingerprinted url with swap and ranges" {
    for ([_][]const u8{ latin_path, pi_path, braille_path }) |path| {
        try std.testing.expect(std.mem.indexOf(u8, font_face_css, path) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, font_face_css, "font-display:swap") != null);
    try std.testing.expect(std.mem.indexOf(u8, font_face_css, "unicode-range:U+2800-28FF") != null);
    try std.testing.expect(std.mem.indexOf(u8, font_face_css, "unicode-range:U+0020-007E") != null);
    try std.testing.expect(std.mem.indexOf(u8, font_face_css, "U+2500-259F") != null);
    try std.testing.expect(std.mem.indexOf(u8, font_face_css, "U+2713") != null);
    // No third-party URLs anywhere in the block.
    try std.testing.expect(std.mem.indexOf(u8, font_face_css, "http") == null);
}
