const std = @import("std");

pub fn validate(value: []const u8) bool {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u4, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u5, value[8..10], 10) catch return false;
    if (year < 1970 or month < 1 or month > 12 or day < 1) return false;
    const max_day: u5 = switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    return day <= max_day;
}

pub fn compact(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (!validate(value)) return error.InvalidDate;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ value[0..4], value[5..7], value[8..10] });
}

pub fn today(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const seconds = std.Io.Clock.real.now(io).toSeconds();
    if (seconds < 0) return error.InvalidDate;
    return fromEpochDay(allocator, @intCast(@divFloor(seconds, std.time.s_per_day)));
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
    var total: u47 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) total += if (isLeap(y)) 366 else 365;
    var m: u4 = 1;
    while (m < month) : (m += 1) total += daysInMonth(year, m);
    total += day - 1;
    return total;
}

fn fromEpochDay(allocator: std.mem.Allocator, epoch_day: u47) ![]u8 {
    const ed = std.time.epoch.EpochDay{ .day = epoch_day };
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 });
}

fn isLeap(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysInMonth(year: u16, month: u4) u5 {
    return switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

test "dates validate and shift across leap day" {
    try std.testing.expect(validate("2024-02-29"));
    try std.testing.expect(!validate("2023-02-29"));
    const next = try shift(std.testing.allocator, "2024-02-29", 1);
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("2024-03-01", next);
}
