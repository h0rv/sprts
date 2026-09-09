//! Timezone selection for "today" day derivation + zone labels.
//!
//! Default is US Eastern (like plaintextsports/ESPN): a missing `?date`
//! resolves to the ET calendar day, so US night games never flip a day
//! early vs ESPN. Explicit `?date` always wins and is used verbatim.
//!
//! `?tz=` override (strict; invalid values are ignored, never a 400):
//!   `ET`, `EST`, `EDT`, `America/New_York` -> Eastern (EST/EDT by the US
//!       DST rule in `core.date`)
//!   `UTC`, `GMT`, `Z`, `Etc/UTC`          -> UTC
//!   `-5`, `+5:30`, `-04:00`               -> fixed offset east of UTC in
//!       hours (1-2 digits, optional `:MM`); fixed offsets ignore DST
//!   anything else (or bare `?tz=`)        -> ignored, ET default stands
//!
//! Source guess (worker only): `request.cf.timezone` (workers-zig
//! `request.cf()`, IANA name) or a `CF-Timezone` header when a proxy sends
//! one. Only ET/UTC names map; any other zone (or absent signal) falls back
//! to the ET default. Explicit `?tz=` always beats the guess. The native
//! server has no client-TZ signal, so it is ET default + `?tz=` override.
//! No geo-IP databases are consulted anywhere.
//!
//! Display: `labelFor` renders `M/D ZONE` (e.g. `9/6 ET`) so date labels
//! name their zone instead of silently disagreeing with ESPN.

const std = @import("std");
const core = @import("sprts_core");

pub const Zone = union(enum) {
    et,
    utc,
    fixed: i16, // minutes east of UTC
};

/// Default zone: US Eastern.
pub const default_zone: Zone = .et;

/// Parse `?tz=` from a raw request target (`/mlb?tz=utc`). Returns null
/// when absent or invalid; the caller falls back to `default_zone`.
/// Never errors, never 400s: strict validation, invalid is ignored.
pub fn parseTz(target: []const u8) ?Zone {
    const value = queryValue(queryOf(target), "tz") orelse return null;
    if (value.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(value, "et")) return .et;
    if (std.ascii.eqlIgnoreCase(value, "est")) return .et;
    if (std.ascii.eqlIgnoreCase(value, "edt")) return .et;
    if (std.ascii.eqlIgnoreCase(value, "america/new_york")) return .et;
    if (std.ascii.eqlIgnoreCase(value, "utc")) return .utc;
    if (std.ascii.eqlIgnoreCase(value, "gmt")) return .utc;
    if (std.ascii.eqlIgnoreCase(value, "z")) return .utc;
    if (std.ascii.eqlIgnoreCase(value, "etc/utc")) return .utc;
    return parseFixedOffset(value);
}

/// Native path: explicit `?tz=` or the ET default (no client-TZ signal).
pub fn zoneFromTarget(target: []const u8) Zone {
    return parseTz(target) orelse default_zone;
}

/// Guess the zone from worker request signals. `cf_timezone` is
/// `request.cf.timezone` (IANA name); `cf_tz_header` is the `CF-Timezone`
/// header value when present. Only ET/UTC names map; anything else or
/// absent falls back to the ET default.
pub fn guessFromCfSource(cf_timezone: ?[]const u8, cf_tz_header: ?[]const u8) Zone {
    if (cf_tz_header) |h| if (nameToKnown(h)) |known| return known;
    if (cf_timezone) |t| if (nameToKnown(t)) |known| return known;
    return default_zone;
}

/// Worker path: explicit `?tz=` beats the CF source guess beats ET default.
pub fn zoneFromWorkerRequest(target: []const u8, cf_timezone: ?[]const u8, cf_tz_header: ?[]const u8) Zone {
    if (parseTz(target)) |explicit| return explicit;
    return guessFromCfSource(cf_timezone, cf_tz_header);
}

/// Resolve the board day: explicit `?date` verbatim, else "today" in `zone`.
pub fn resolveDay(arena: std.mem.Allocator, date: ?[]const u8, epoch_s: i64, zone: Zone) ![]u8 {
    // Today's calendar day in the request zone, then through the relative
    // resolver: ?date=tomorrow/yesterday ride the same zone as headings so
    // output never disagrees with itself by a day. Router validation gates
    // junk first, so resolveDate cannot fail here (tokens + strict dates).
    const today = switch (zone) {
        .et => try core.date.todayET(arena, epoch_s),
        .utc => try core.date.todayFromEpoch(arena, epoch_s),
        .fixed => |offset| try core.date.todayInTz(arena, epoch_s, offset),
    };
    if (date) |raw| {
        defer arena.free(today);
        return core.date.resolveDate(arena, raw, today);
    }
    return today;
}

/// `M/D ZONE` label for a `YYYY-MM-DD` day, e.g. `9/6 ET`.
pub fn labelFor(arena: std.mem.Allocator, day: []const u8, zone: Zone) ![]u8 {
    if (day.len != 10 or day[4] != '-' or day[7] != '-') return arena.dupe(u8, day);
    const month = std.fmt.parseInt(u16, day[5..7], 10) catch return arena.dupe(u8, day);
    const dom = std.fmt.parseInt(u16, day[8..10], 10) catch return arena.dupe(u8, day);
    return switch (zone) {
        .et => std.fmt.allocPrint(arena, "{d}/{d} ET", .{ month, dom }),
        .utc => std.fmt.allocPrint(arena, "{d}/{d} UTC", .{ month, dom }),
        .fixed => |offset| {
            const tag = try fixedTag(arena, offset);
            defer arena.free(tag);
            return std.fmt.allocPrint(arena, "{d}/{d} {s}", .{ month, dom, tag });
        },
    };
}

/// Short zone tag for headings (`ET`, `UTC`, `UTC-5`, `UTC+5:30`).
/// Backs the `M/D ZONE` display in `labelFor` and the scoreboard/home
/// headings that append the zone so output never silently disagrees
/// with ESPN by a day.
pub fn zoneTag(arena: std.mem.Allocator, zone: Zone) ![]u8 {
    return switch (zone) {
        .et => arena.dupe(u8, "ET"),
        .utc => arena.dupe(u8, "UTC"),
        .fixed => |offset| fixedTag(arena, offset),
    };
}

fn fixedTag(arena: std.mem.Allocator, offset_minutes: i16) ![]u8 {
    if (offset_minutes == 0) return arena.dupe(u8, "UTC");
    const sign: u8 = if (offset_minutes < 0) '-' else '+';
    const total: u16 = @intCast(@abs(@as(i32, offset_minutes)));
    const hours = total / 60;
    const mins = total % 60;
    if (mins == 0) return std.fmt.allocPrint(arena, "UTC{c}{d}", .{ sign, hours });
    return std.fmt.allocPrint(arena, "UTC{c}{d}:{d:0>2}", .{ sign, hours, mins });
}

/// Known IANA/shorthand names to zones; null means "not ET/UTC, use default".
fn nameToKnown(value: []const u8) ?Zone {
    if (std.ascii.eqlIgnoreCase(value, "america/new_york")) return .et;
    if (std.ascii.eqlIgnoreCase(value, "et")) return .et;
    if (std.ascii.eqlIgnoreCase(value, "est")) return .et;
    if (std.ascii.eqlIgnoreCase(value, "edt")) return .et;
    if (std.ascii.eqlIgnoreCase(value, "utc")) return .utc;
    if (std.ascii.eqlIgnoreCase(value, "gmt")) return .utc;
    if (std.ascii.eqlIgnoreCase(value, "etc/utc")) return .utc;
    return null;
}

/// Fixed numeric offset: `[+-]?H[H][:MM]`, hours 0-18, minutes 00-59.
/// Null on anything else.
fn parseFixedOffset(value: []const u8) ?Zone {
    var rest = value;
    var negative = false;
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
        negative = rest[0] == '-';
        rest = rest[1..];
    }
    const colon = std.mem.indexOfScalar(u8, rest, ':');
    const hour_text = if (colon) |c| rest[0..c] else rest;
    const min_text: []const u8 = if (colon) |c| rest[c + 1 ..] else "0";
    if (hour_text.len == 0 or hour_text.len > 2) return null;
    if (colon != null and min_text.len != 2) return null;
    var hours: i16 = 0;
    for (hour_text) |c| {
        if (c < '0' or c > '9') return null;
        hours = hours * 10 + (c - '0');
    }
    var mins: i16 = 0;
    for (min_text) |c| {
        if (c < '0' or c > '9') return null;
        mins = mins * 10 + (c - '0');
    }
    if (hours > 18 or mins > 59) return null;
    if (hours == 0 and mins == 0) return .utc;
    const total = hours * 60 + mins;
    return .{ .fixed = if (negative) -total else total };
}

fn queryOf(target: []const u8) []const u8 {
    const query_at = std.mem.indexOfScalar(u8, target, '?');
    return if (query_at) |at| target[at + 1 ..] else "";
}

// Copied from router.zig `queryValue` (private there; router.zig is owned
// by other agents, so the ~6 lines are duplicated here instead of modified).
fn queryValue(query: []const u8, wanted: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..equals], wanted)) return field[equals + 1 ..];
    }
    return null;
}

test "?tz= parses names, offsets, and rejects garbage" {
    try std.testing.expect(parseTz("/mlb") == null);
    try std.testing.expect(parseTz("/mlb?tz=") == null);
    try std.testing.expect(parseTz("/mlb?tz") == null);
    try std.testing.expect(parseTz("/mlb?tz=ET").? == .et);
    try std.testing.expect(parseTz("/mlb?tz=et").? == .et);
    try std.testing.expect(parseTz("/mlb?tz=America/New_York").? == .et);
    try std.testing.expect(parseTz("/mlb?tz=america/new_york").? == .et);
    try std.testing.expect(parseTz("/mlb?tz=UTC").? == .utc);
    try std.testing.expect(parseTz("/mlb?tz=utc").? == .utc);
    try std.testing.expect(parseTz("/mlb?tz=GMT").? == .utc);
    try std.testing.expect(parseTz("/mlb?tz=Z").? == .utc);
    try std.testing.expectEqual(@as(i16, -300), parseTz("/mlb?tz=-5").?.fixed);
    try std.testing.expectEqual(@as(i16, -240), parseTz("/mlb?tz=-4").?.fixed);
    try std.testing.expectEqual(@as(i16, 330), parseTz("/mlb?tz=+5:30").?.fixed);
    try std.testing.expect(parseTz("/mlb?tz=0").? == .utc);
    // Invalid: ignored (null), never an error.
    try std.testing.expect(parseTz("/mlb?tz=Mars") == null);
    try std.testing.expect(parseTz("/mlb?tz=abc") == null);
    try std.testing.expect(parseTz("/mlb?tz=--5") == null);
    try std.testing.expect(parseTz("/mlb?tz=5:99") == null);
    try std.testing.expect(parseTz("/mlb?tz=19") == null);
    try std.testing.expect(parseTz("/mlb?tz=123") == null);
    try std.testing.expect(parseTz("/mlb?tz=5:5") == null);
    try std.testing.expect(parseTz("/mlb?tz=Europe/Paris") == null);
    // Composes with other query params.
    try std.testing.expect(parseTz("/mlb?date=2026-09-06&tz=utc").? == .utc);
}

test "zoneFromTarget defaults ET, honors ?tz=" {
    try std.testing.expect(zoneFromTarget("/mlb") == .et);
    try std.testing.expect(zoneFromTarget("/mlb?tz=bogus") == .et);
    try std.testing.expect(zoneFromTarget("/mlb?tz=utc") == .utc);
}

test "CF source guess maps ET/UTC names, defaults ET" {
    try std.testing.expect(guessFromCfSource(null, null) == .et);
    try std.testing.expect(guessFromCfSource("America/New_York", null) == .et);
    try std.testing.expect(guessFromCfSource("Europe/Paris", null) == .et);
    try std.testing.expect(guessFromCfSource("America/Chicago", null) == .et);
    try std.testing.expect(guessFromCfSource("UTC", null) == .utc);
    try std.testing.expect(guessFromCfSource(null, "America/New_York") == .et);
    try std.testing.expect(guessFromCfSource(null, "UTC") == .utc);
    // Header beats cf.timezone.
    try std.testing.expect(guessFromCfSource("UTC", "America/New_York") == .et);
    // ?tz= beats the guess.
    try std.testing.expect(zoneFromWorkerRequest("/mlb?tz=utc", "America/New_York", null) == .utc);
    try std.testing.expect(zoneFromWorkerRequest("/mlb", "America/New_York", null) == .et);
}

test "resolveDay passes ?date through, derives ET by default" {
    const arena = std.testing.allocator;
    const explicit = try resolveDay(arena, "2026-09-06", 1788753600, .et);
    defer arena.free(explicit);
    try std.testing.expectEqualStrings("2026-09-06", explicit);
    // 2026-09-07T00:00Z is still Sep 6 in ET.
    const et_day = try resolveDay(arena, null, 1788739200, .et);
    defer arena.free(et_day);
    try std.testing.expectEqualStrings("2026-09-06", et_day);
    const utc_day = try resolveDay(arena, null, 1788739200, .utc);
    defer arena.free(utc_day);
    try std.testing.expectEqualStrings("2026-09-07", utc_day);
    const fixed = try resolveDay(arena, null, 1788739200, .{ .fixed = -300 });
    defer arena.free(fixed);
    try std.testing.expectEqualStrings("2026-09-06", fixed);
}

test "resolveDay honors relative tokens against the request zone" {
    const arena = std.testing.allocator;
    // Noon UTC Sep 8: ET morning of Sep 8, UTC midday of Sep 8.
    const noon = try resolveDay(arena, "tomorrow", 1788825600 + 43200, .et);
    defer arena.free(noon);
    try std.testing.expectEqualStrings("2026-09-09", noon);
    const yest = try resolveDay(arena, "yesterday", 1788825600 + 43200, .utc);
    defer arena.free(yest);
    try std.testing.expectEqualStrings("2026-09-07", yest);
    const today = try resolveDay(arena, "today", 1788825600 + 43200, .et);
    defer arena.free(today);
    try std.testing.expectEqualStrings("2026-09-08", today);
}

test "zoneTag names ET/UTC/fixed offsets" {
    const arena = std.testing.allocator;
    const et = try zoneTag(arena, .et);
    defer arena.free(et);
    try std.testing.expectEqualStrings("ET", et);
    const utc = try zoneTag(arena, .utc);
    defer arena.free(utc);
    try std.testing.expectEqualStrings("UTC", utc);
    const fixed = try zoneTag(arena, .{ .fixed = -300 });
    defer arena.free(fixed);
    try std.testing.expectEqualStrings("UTC-5", fixed);
    const half = try zoneTag(arena, .{ .fixed = 330 });
    defer arena.free(half);
    try std.testing.expectEqualStrings("UTC+5:30", half);
}

test "labelFor names the zone" {
    const arena = std.testing.allocator;
    const et = try labelFor(arena, "2026-09-06", .et);
    defer arena.free(et);
    try std.testing.expectEqualStrings("9/6 ET", et);
    const utc = try labelFor(arena, "2026-09-06", .utc);
    defer arena.free(utc);
    try std.testing.expectEqualStrings("9/6 UTC", utc);
    const fixed = try labelFor(arena, "2026-12-25", .{ .fixed = -300 });
    defer arena.free(fixed);
    try std.testing.expectEqualStrings("12/25 UTC-5", fixed);
    const half = try labelFor(arena, "2026-09-06", .{ .fixed = 330 });
    defer arena.free(half);
    try std.testing.expectEqualStrings("9/6 UTC+5:30", half);
}
