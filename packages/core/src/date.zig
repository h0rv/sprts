const std = @import("std");

pub fn validate(value: []const u8) bool {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u4, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u5, value[8..10], 10) catch return false;
    if (year < 1970 or month < 1 or month > 12 or day < 1) return false;
    return day <= std.time.epoch.getDaysInMonth(year, @enumFromInt(month));
}

/// Lowercase-exact relative date tokens accepted in `?date=` alongside
/// strict YYYY-MM-DD. Anything else stays strict (no case folding,
/// no whitespace trimming). The router passes the raw token through;
/// the serve path resolves it via `resolveDate`.
pub fn isRelativeToken(value: []const u8) bool {
    return std.mem.eql(u8, value, "today") or
        std.mem.eql(u8, value, "tomorrow") or
        std.mem.eql(u8, value, "yesterday");
}

/// Resolve a raw `?date=` value against a caller-supplied calendar day.
/// `today` is a YYYY-MM-DD day (owned or borrowed, not consumed).
/// Returns an owned YYYY-MM-DD: tokens shift via `shift()`, other
/// strings are validated-and-duped, invalid raises `error.InvalidDate`
/// for the caller's existing `bad_date` mapping. Pure.
pub fn resolveDate(allocator: std.mem.Allocator, raw: []const u8, today_value: []const u8) ![]u8 {
    if (std.mem.eql(u8, raw, "today")) return shift(allocator, today_value, 0);
    if (std.mem.eql(u8, raw, "tomorrow")) return shift(allocator, today_value, 1);
    if (std.mem.eql(u8, raw, "yesterday")) return shift(allocator, today_value, -1);
    if (!validate(raw)) return error.InvalidDate;
    return allocator.dupe(u8, raw);
}

pub fn compact(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (!validate(value)) return error.InvalidDate;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ value[0..4], value[5..7], value[8..10] });
}

pub fn today(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return todayFromEpoch(allocator, std.Io.Clock.real.now(io).toSeconds());
}

pub fn todayFromEpoch(allocator: std.mem.Allocator, epoch_seconds: i64) ![]u8 {
    if (epoch_seconds < 0) return error.InvalidDate;
    return fromEpochDay(allocator, @intCast(@divFloor(epoch_seconds, std.time.s_per_day)));
}

/// US Eastern day derivation (plaintextsports parity).
///
/// ET rule: UTC-5 (EST) outside daylight time, UTC-4 (EDT) inside it.
/// DST rule (US, since 2007): starts 2:00am local on the SECOND Sunday of
/// March, ends 2:00am local on the FIRST Sunday of November. That is
/// 07:00 UTC on that March Sunday and 06:00 UTC on that November Sunday.
/// Pure: year math only, no clock, no locale tables.
pub const et_standard_offset_minutes: i16 = -5 * 60;
pub const et_daylight_offset_minutes: i16 = -4 * 60;

/// Offset in minutes east of UTC for US Eastern at this instant.
/// Returns -300 (EST) or -240 (EDT).
pub fn etOffsetMinutes(epoch_seconds: i64) i16 {
    if (epoch_seconds < 0) return et_standard_offset_minutes;
    const epoch_day: i64 = @divFloor(epoch_seconds, std.time.s_per_day);
    const year = yearOfEpochDay(epoch_day);
    const march_sunday = nthSundayOfMarch(year, 2);
    const nov_sunday = nthSundayOfNovember(year, 1);
    const dst_start = march_sunday * std.time.s_per_day + 7 * std.time.s_per_hour;
    const dst_end = nov_sunday * std.time.s_per_day + 6 * std.time.s_per_hour;
    if (epoch_seconds >= dst_start and epoch_seconds < dst_end) return et_daylight_offset_minutes;
    return et_standard_offset_minutes;
}

/// Derive the calendar day for `epoch_seconds` at a fixed offset east of
/// UTC (minutes; negative west). Pure; inject the epoch in tests.
pub fn todayInTz(allocator: std.mem.Allocator, epoch_seconds: i64, offset_minutes: i16) ![]u8 {
    if (epoch_seconds < 0) return error.InvalidDate;
    const shifted = epoch_seconds + @as(i64, offset_minutes) * std.time.s_per_min;
    if (shifted < 0) return error.InvalidDate;
    return fromEpochDay(allocator, @intCast(@divFloor(shifted, std.time.s_per_day)));
}

/// Derive "today" in US Eastern (EST/EDT by the rule above).
pub fn todayET(allocator: std.mem.Allocator, epoch_seconds: i64) ![]u8 {
    return todayInTz(allocator, epoch_seconds, etOffsetMinutes(epoch_seconds));
}

/// Parse an ESPN-style UTC timestamp (`YYYY-MM-DDTHH:MM`, trailing seconds
/// and `Z` tolerated) to epoch seconds. Returns null on any bad shape so
/// callers can fall back to date-prefix handling. Pure.
pub fn parseTimestampUTC(value: []const u8) ?i64 {
    if (value.len < 16) return null;
    if (value[10] != 'T' or value[13] != ':') return null;
    if (!validate(value[0..10])) return null;
    const epoch_day = toEpochDay(value[0..10]) catch return null;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return null;
    if (hour > 23) return null;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return null;
    if (minute > 59) return null;
    var seconds: i64 = 0;
    if (value.len >= 19 and value[16] == ':') {
        seconds = std.fmt.parseInt(i64, value[17..19], 10) catch return null;
        if (seconds < 0 or seconds > 60) return null;
    }
    return @as(i64, epoch_day) * std.time.s_per_day +
        @as(i64, hour) * std.time.s_per_hour +
        @as(i64, minute) * std.time.s_per_min + seconds;
}

/// Year (e.g. 2026) containing this epoch day (days since 1970-01-01),
/// via `std.time.epoch` (same std math `fromEpochDay` uses below).
fn yearOfEpochDay(epoch_day: i64) u16 {
    return (std.time.epoch.EpochDay{ .day = @intCast(epoch_day) }).calculateYearDay().year;
}

/// Epoch day of the nth Sunday of March (DST start month).
fn nthSundayOfMarch(year: u16, n: u8) i64 {
    return nthSundayOfMonth(year, 3, n);
}

/// Epoch day of the nth Sunday of November (DST end month).
fn nthSundayOfNovember(year: u16, n: u8) i64 {
    return nthSundayOfMonth(year, 11, n);
}

fn nthSundayOfMonth(year: u16, month: u4, n: u8) i64 {
    const first_day = epochDayOfDate(year, month, 1);
    // 1970-01-01 was a Thursday; Sunday is 3 days later mod 7.
    const weekday_of_first: u8 = @intCast(@mod(first_day + 4, 7)); // 0=Sunday..6=Saturday
    const days_to_first_sunday: i64 = @intCast(@mod(7 - weekday_of_first, 7));
    return first_day + days_to_first_sunday + @as(i64, n - 1) * 7;
}

/// Days since 1970-01-01 for a calendar date: Howard Hinnant's
/// days_from_civil (branchless civil-date math, no year/month loops).
/// Callers pass years >= 1970 (`validate` enforces it), so the result
/// is always >= 0.
fn epochDayOfDate(year: u16, month: u4, day: u5) i64 {
    const y: i64 = @as(i64, year) - @as(i64, if (month <= 2) 1 else 0);
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const mp: i64 = @mod(@as(i64, month) + 9, 12); // Mar=0 .. Feb=11
    const doy: i64 = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468; // 719468 = days 0000-03-01 to 1970-01-01
}

pub fn shift(allocator: std.mem.Allocator, value: []const u8, delta: i32) ![]u8 {
    const epoch_day = try toEpochDay(value);
    const shifted = @as(i64, @intCast(epoch_day)) + delta;
    if (shifted < 0) return error.InvalidDate;
    return fromEpochDay(allocator, @intCast(shifted));
}

fn toEpochDay(value: []const u8) !u47 {
    if (!validate(value)) return error.InvalidDate;
    const year = try std.fmt.parseInt(u16, value[0..4], 10);
    const month = try std.fmt.parseInt(u4, value[5..7], 10);
    const day = try std.fmt.parseInt(u5, value[8..10], 10);
    return @intCast(epochDayOfDate(year, month, day));
}

fn fromEpochDay(allocator: std.mem.Allocator, epoch_day: u47) ![]u8 {
    const ed = std.time.epoch.EpochDay{ .day = epoch_day };
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 });
}

test "dates validate and shift across leap day" {
    try std.testing.expect(validate("2024-02-29"));
    try std.testing.expect(!validate("2023-02-29"));
    const next = try shift(std.testing.allocator, "2024-02-29", 1);
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("2024-03-01", next);
}

test "todayFromEpoch maps epoch seconds to UTC date" {
    const at_midnight = try todayFromEpoch(std.testing.allocator, 1788739200);
    defer std.testing.allocator.free(at_midnight);
    try std.testing.expectEqualStrings("2026-09-07", at_midnight);
    const before_midnight = try todayFromEpoch(std.testing.allocator, 1788739200 - 1);
    defer std.testing.allocator.free(before_midnight);
    try std.testing.expectEqualStrings("2026-09-06", before_midnight);
    try std.testing.expectError(error.InvalidDate, todayFromEpoch(std.testing.allocator, -1));
}

test "etOffsetMinutes follows the US DST rule" {
    // EST (-300) in January; EDT (-240) in September.
    try std.testing.expectEqual(@as(i16, -300), etOffsetMinutes(1768453200)); // 2026-01-15T05:00Z
    try std.testing.expectEqual(@as(i16, -240), etOffsetMinutes(1788753600)); // 2026-09-07T04:00Z
    // 2026 spring forward: second Sunday of March, 07:00 UTC.
    try std.testing.expectEqual(@as(i16, -300), etOffsetMinutes(1772953199)); // 06:59:59 UTC
    try std.testing.expectEqual(@as(i16, -240), etOffsetMinutes(1772953200)); // 07:00:00 UTC
    // 2026 fall back: first Sunday of November, 06:00 UTC.
    try std.testing.expectEqual(@as(i16, -240), etOffsetMinutes(1793512799)); // 05:59:59 UTC
    try std.testing.expectEqual(@as(i16, -300), etOffsetMinutes(1793512800)); // 06:00:00 UTC
    // Other years, same rule shape (2nd Sun Mar / 1st Sun Nov).
    try std.testing.expectEqual(@as(i16, -300), etOffsetMinutes(1741503599));
    try std.testing.expectEqual(@as(i16, -240), etOffsetMinutes(1741503600)); // 2025-03-09T07:00Z
    try std.testing.expectEqual(@as(i16, -240), etOffsetMinutes(1762063199));
    try std.testing.expectEqual(@as(i16, -300), etOffsetMinutes(1762063200)); // 2025-11-02T06:00Z
    try std.testing.expectEqual(@as(i16, -300), etOffsetMinutes(1710053999));
    try std.testing.expectEqual(@as(i16, -240), etOffsetMinutes(1710054000)); // 2024-03-10T07:00Z
    try std.testing.expectEqual(@as(i16, -240), etOffsetMinutes(1730613599));
    try std.testing.expectEqual(@as(i16, -300), etOffsetMinutes(1730613600)); // 2024-11-03T06:00Z
}

test "todayET keeps night games on the ET day" {
    // 2026-09-07T03:59:59Z is still Sep 6 in ET (11:59pm EDT).
    const late = try todayET(std.testing.allocator, 1788753599);
    defer std.testing.allocator.free(late);
    try std.testing.expectEqualStrings("2026-09-06", late);
    // 2026-09-07T04:00:00Z is midnight EDT: Sep 7.
    const midnight = try todayET(std.testing.allocator, 1788753600);
    defer std.testing.allocator.free(midnight);
    try std.testing.expectEqualStrings("2026-09-07", midnight);
    // Winter: EST boundary is 05:00 UTC.
    const jan_late = try todayET(std.testing.allocator, 1768453199); // 04:59:59Z
    defer std.testing.allocator.free(jan_late);
    try std.testing.expectEqualStrings("2026-01-14", jan_late);
    const jan_mid = try todayET(std.testing.allocator, 1768453200); // 05:00:00Z
    defer std.testing.allocator.free(jan_mid);
    try std.testing.expectEqualStrings("2026-01-15", jan_mid);
    // Spring-forward day: offset flips at 07:00 UTC, day derivation holds.
    const spring = try todayET(std.testing.allocator, 1772953200); // 2026-03-08T07:00Z
    defer std.testing.allocator.free(spring);
    try std.testing.expectEqualStrings("2026-03-08", spring);
    try std.testing.expectError(error.InvalidDate, todayET(std.testing.allocator, -1));
}

test "parseTimestampUTC reads ESPN timestamps to epoch seconds" {
    // 2026-09-07T00:00Z is 1788739200; +7d +20m lands on 2026-09-14T00:20Z.
    try std.testing.expectEqual(@as(?i64, 1789345200), parseTimestampUTC("2026-09-14T00:20Z"));
    try std.testing.expectEqual(@as(?i64, 1789345245), parseTimestampUTC("2026-09-14T00:20:45Z"));
    // Seconds and the Z marker are tolerated when absent.
    try std.testing.expectEqual(@as(?i64, 1789345200), parseTimestampUTC("2026-09-14T00:20"));
    // Bad shapes yield null, never an error.
    try std.testing.expect(parseTimestampUTC("") == null);
    try std.testing.expect(parseTimestampUTC("2026-09-14") == null);
    try std.testing.expect(parseTimestampUTC("2026-09-14 00:20") == null);
    try std.testing.expect(parseTimestampUTC("2026-13-01T00:00Z") == null);
    try std.testing.expect(parseTimestampUTC("2026-09-14T24:00Z") == null);
    try std.testing.expect(parseTimestampUTC("2026-09-14T00:60Z") == null);
}

test "todayInTz applies a fixed offset" {
    const utc = try todayInTz(std.testing.allocator, 1788739200, 0);
    defer std.testing.allocator.free(utc);
    try std.testing.expectEqualStrings("2026-09-07", utc);
    const et = try todayInTz(std.testing.allocator, 1788739200, -240);
    defer std.testing.allocator.free(et);
    try std.testing.expectEqualStrings("2026-09-06", et);
    const plus = try todayInTz(std.testing.allocator, 1788739200, 60);
    defer std.testing.allocator.free(plus);
    try std.testing.expectEqualStrings("2026-09-07", plus);
    try std.testing.expectError(error.InvalidDate, todayInTz(std.testing.allocator, -1, 0));
}

test "relative tokens are lowercase-exact" {
    try std.testing.expect(isRelativeToken("today"));
    try std.testing.expect(isRelativeToken("tomorrow"));
    try std.testing.expect(isRelativeToken("yesterday"));
    try std.testing.expect(!isRelativeToken("Today"));
    try std.testing.expect(!isRelativeToken("TOMORROW"));
    try std.testing.expect(!isRelativeToken("Yesterday"));
    try std.testing.expect(!isRelativeToken("2026-09-07"));
    try std.testing.expect(!isRelativeToken(""));
    try std.testing.expect(!isRelativeToken(" tomorrow"));
}

test "resolveDate shifts tokens across month and year boundaries" {
    const alloc = std.testing.allocator;
    // Identity token.
    const t0 = try resolveDate(alloc, "today", "2026-09-07");
    defer alloc.free(t0);
    try std.testing.expectEqualStrings("2026-09-07", t0);
    // Month boundary: Jan 31 tomorrow is Feb 1; Mar 1 yesterday is Feb 28/29.
    const feb1 = try resolveDate(alloc, "tomorrow", "2026-01-31");
    defer alloc.free(feb1);
    try std.testing.expectEqualStrings("2026-02-01", feb1);
    const jan31 = try resolveDate(alloc, "yesterday", "2026-02-01");
    defer alloc.free(jan31);
    try std.testing.expectEqualStrings("2026-01-31", jan31);
    // Year boundary: Dec 31 tomorrow is Jan 1; Jan 1 yesterday is Dec 31.
    const jan1 = try resolveDate(alloc, "tomorrow", "2025-12-31");
    defer alloc.free(jan1);
    try std.testing.expectEqualStrings("2026-01-01", jan1);
    const dec31 = try resolveDate(alloc, "yesterday", "2026-01-01");
    defer alloc.free(dec31);
    try std.testing.expectEqualStrings("2025-12-31", dec31);
    // Non-leap February: Feb 28 tomorrow is Mar 1.
    const mar1 = try resolveDate(alloc, "tomorrow", "2026-02-28");
    defer alloc.free(mar1);
    try std.testing.expectEqualStrings("2026-03-01", mar1);
}

test "resolveDate handles leap day" {
    const alloc = std.testing.allocator;
    // Into the leap day from Feb 28.
    const leap = try resolveDate(alloc, "tomorrow", "2024-02-28");
    defer alloc.free(leap);
    try std.testing.expectEqualStrings("2024-02-29", leap);
    // Off the leap day.
    const off = try resolveDate(alloc, "tomorrow", "2024-02-29");
    defer alloc.free(off);
    try std.testing.expectEqualStrings("2024-03-01", off);
    const back = try resolveDate(alloc, "yesterday", "2024-03-01");
    defer alloc.free(back);
    try std.testing.expectEqualStrings("2024-02-29", back);
    const before = try resolveDate(alloc, "yesterday", "2024-02-29");
    defer alloc.free(before);
    try std.testing.expectEqualStrings("2024-02-28", before);
    // Identity on the leap day itself.
    const same = try resolveDate(alloc, "today", "2024-02-29");
    defer alloc.free(same);
    try std.testing.expectEqualStrings("2024-02-29", same);
}

test "resolveDate passes valid dates through and rejects the rest" {
    const alloc = std.testing.allocator;
    const passthrough = try resolveDate(alloc, "2026-09-06", "2026-09-07");
    defer alloc.free(passthrough);
    try std.testing.expectEqualStrings("2026-09-06", passthrough);
    // Passthrough returns an owned copy even when today is junk.
    const junk_today = try resolveDate(alloc, "2026-09-06", "not-a-date");
    defer alloc.free(junk_today);
    try std.testing.expectEqualStrings("2026-09-06", junk_today);
    // Invalid raws raise for the caller's bad_date mapping.
    try std.testing.expectError(error.InvalidDate, resolveDate(alloc, "Tomorrow", "2026-09-07"));
    try std.testing.expectError(error.InvalidDate, resolveDate(alloc, "next-week", "2026-09-07"));
    try std.testing.expectError(error.InvalidDate, resolveDate(alloc, "2026-13-01", "2026-09-07"));
    try std.testing.expectError(error.InvalidDate, resolveDate(alloc, "2023-02-29", "2026-09-07"));
    try std.testing.expectError(error.InvalidDate, resolveDate(alloc, "", "2026-09-07"));
    // A bad caller day poisons token shifts (shift validates today).
    try std.testing.expectError(error.InvalidDate, resolveDate(alloc, "today", "not-a-date"));
    try std.testing.expectError(error.InvalidDate, resolveDate(alloc, "tomorrow", "2026-13-01"));
}
