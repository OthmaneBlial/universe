const std = @import("std");
const host = @import("host.zig");
const epoch = std.time.epoch;
pub const ticks_per_second: u64 = 10_000_000;
const cycle_days: u64 = 146_097;

pub fn fromTimestamp(time: host.Timestamp) !u64 {
    const ticks = (@as(i128, time.sec) - epoch.windows) * ticks_per_second + @divFloor(time.nsec, 100);
    return std.math.cast(u64, ticks) orelse error.WindowsFileTimeOutOfRange;
}
pub fn toTimestamp(ticks: u64) !host.Timestamp {
    if (ticks > std.math.maxInt(i64)) return error.InvalidWindowsTime;
    return .{ .sec = @as(i64, @intCast(ticks / ticks_per_second)) + epoch.windows, .nsec = @intCast(ticks % ticks_per_second * 100) };
}
pub fn shift(ticks: u64, offset: i64) !u64 {
    if (ticks > std.math.maxInt(i64)) return error.InvalidWindowsTime;
    const result = @as(i128, ticks) + @as(i128, offset) * ticks_per_second;
    if (result < 0 or result > std.math.maxInt(i64)) return error.InvalidWindowsTime;
    return @intCast(result);
}
pub fn toSystemTime(ticks: u64) ![8]u16 {
    if (ticks > std.math.maxInt(i64)) return error.InvalidWindowsTime;
    const seconds = ticks / ticks_per_second;
    const days = seconds / epoch.secs_per_day;
    // ponytail: at most 431 stdlib calendar years; use an analytic inverse only if profiling justifies it.
    const shifted = epoch.EpochDay{ .day = @intCast(@as(u64, epoch.ios) / epoch.secs_per_day + days % cycle_days) };
    const year_day = shifted.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const clock = epoch.DaySeconds{ .secs = @intCast(seconds % epoch.secs_per_day) };
    return .{
        @intCast(@as(u64, year_day.year) + days / cycle_days * 400 - 400),
        month_day.month.numeric(),
        @intCast((days + 1) % 7), // 1601-01-01 was Monday; Sunday is zero.
        @as(u16, month_day.day_index) + 1,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),
        @intCast(ticks % ticks_per_second / 10_000),
    };
}
pub fn fromSystemTime(value: [8]u16) !u64 {
    const year = value[0];
    const month = value[1];
    if (year < 1601 or year > 30827 or month < 1 or month > 12 or value[3] == 0 or value[3] > epoch.getDaysInMonth(year, @enumFromInt(month)) or value[4] > 23 or value[5] > 59 or value[6] > 59 or value[7] > 999) return error.InvalidWindowsTime;
    const years = year - 1601;
    var days: u64 = @as(u64, years / 400) * cycle_days;
    for (1601..@as(usize, 1601) + years % 400) |item| days += epoch.getDaysInYear(@intCast(item));
    for (1..month) |item| days += epoch.getDaysInMonth(year, @enumFromInt(item));
    days += value[3] - 1;
    return (days * epoch.secs_per_day + @as(u64, value[4]) * 3600 + @as(u64, value[5]) * 60 + value[6]) * ticks_per_second + @as(u64, value[7]) * 10_000;
}
pub fn toDos(ticks: u64) ![2]u16 {
    const value = try toSystemTime(ticks);
    if (value[0] < 1980 or value[0] > 2107) return error.InvalidWindowsTime;
    return .{ ((value[0] - 1980) << 9) | (value[1] << 5) | value[3], (value[4] << 11) | (value[5] << 5) | (value[6] / 2) };
}
pub fn fromDos(date: u16, time: u16) !u64 {
    return fromSystemTime(.{ (date >> 9) + 1980, (date >> 5) & 15, 0, date & 31, time >> 11, (time >> 5) & 63, (time & 31) * 2, 0 });
}
test "FILETIME Gregorian boundaries and checked range use the same stdlib calendar cycle" {
    try std.testing.expectEqual([8]u16{ 1601, 1, 1, 1, 0, 0, 0, 0 }, try toSystemTime(0));
    try std.testing.expectEqual([8]u16{ 1970, 1, 4, 1, 0, 0, 0, 0 }, try toSystemTime(116444736000000000));
    for ([_]u16{ 1601, 1699, 1700, 1900, 1969, 1970, 1980, 1999, 2000, 2001, 2099, 2100, 2399, 2400, 9999, 10000, 30827 }) |year| {
        for (1..13) |month| {
            const last = epoch.getDaysInMonth(year, @enumFromInt(month));
            for ([_]u16{ 1, last }) |day| {
                const input = [8]u16{ year, @intCast(month), 0xffff, day, 23, 59, 59, 999 };
                const ticks = try fromSystemTime(input);
                var result = try toSystemTime(ticks);
                result[2] = 0xffff; // Input weekday is explicitly ignored.
                try std.testing.expectEqual(input, result);
            }
        }
    }
    try std.testing.expectError(error.InvalidWindowsTime, fromSystemTime(.{ 1900, 2, 0, 29, 0, 0, 0, 0 }));
    try std.testing.expectError(error.InvalidWindowsTime, toSystemTime(0x8000000000000000));
    try std.testing.expectError(error.InvalidWindowsTime, shift(0, -1));
    try std.testing.expectError(error.InvalidWindowsTime, shift(0x7fffffffffffffff, 1));
}
