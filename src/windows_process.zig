const std = @import("std");
const Memory = @import("memory.zig").Memory;

// Quote for the Microsoft CRT's argv parser, not a command shell.
pub fn commandLine(a: std.mem.Allocator, args: []const [:0]const u8) ![:0]u8 {
    if (args.len == 0 or std.mem.indexOfScalar(u8, args[0], '"') != null) return error.InvalidWindowsProgramName;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    for (args, 0..) |arg, index| {
        if (arg.len > 131068 or line.items.len > 131068) return error.WindowsCommandLineTooLong;
        if (index != 0) try line.append(a, ' ');
        try line.append(a, '"');
        if (index == 0) {
            try line.appendSlice(a, arg);
        } else {
            var slashes: usize = 0;
            for (arg) |byte| {
                if (byte == '\\') {
                    slashes += 1;
                    continue;
                }
                try line.appendNTimes(a, '\\', if (byte == '"') slashes * 2 + 1 else slashes);
                slashes = 0;
                try line.append(a, byte);
            }
            try line.appendNTimes(a, '\\', slashes * 2);
        }
        try line.append(a, '"');
    }
    const wide = try std.unicode.utf8ToUtf16LeAlloc(a, line.items);
    defer a.free(wide);
    if (wide.len > 32766) return error.WindowsCommandLineTooLong;
    return a.dupeZ(u8, line.items);
}

pub fn wideString(a: std.mem.Allocator, m: *Memory, address: u64) ![:0]u8 {
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(a);
    for (0..32768) |index| {
        const unit: u16 = @intCast(try m.readInt(address +% (index * 2), 16, .read));
        if (unit == 0) return std.unicode.utf16LeToUtf8AllocZ(a, units.items);
        try units.append(a, std.mem.nativeToLittle(u16, unit));
    }
    return error.UnterminatedWindowsString;
}

test "Windows CRT quoting preserves empty arguments, quotes and trailing backslashes" {
    const a = std.testing.allocator;
    const line = try commandLine(a, &.{ "C:\\guest dir\\app.exe", "", "a b", "a\"b", "tail\\", "slash\\\"quote" });
    defer a.free(line);
    try std.testing.expectEqualStrings("\"C:\\guest dir\\app.exe\" \"\" \"a b\" \"a\\\"b\" \"tail\\\\\" \"slash\\\\\\\"quote\"", line);
    try std.testing.expectError(error.InvalidWindowsProgramName, commandLine(a, &.{"bad\"name.exe"}));
    const oversized = try a.allocSentinel(u8, 32767, 0);
    defer a.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectError(error.WindowsCommandLineTooLong, commandLine(a, &.{oversized}));
}

test "UTF-16 guest strings preserve surrogate pairs and reject malformed input" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.write(0x1000, &.{ 0xe9, 0, 0x3d, 0xd8, 0x80, 0xde, 0, 0 });
    const text = try wideString(a, &m, 0x1000);
    defer a.free(text);
    try std.testing.expectEqualStrings("é🚀", text);
    try m.write(0x1000, &.{ 0x3d, 0xd8, 0, 0 });
    try std.testing.expectError(error.DanglingSurrogateHalf, wideString(a, &m, 0x1000));
    try std.testing.expectError(error.UnmappedMemory, wideString(a, &m, 0x2000));
}
