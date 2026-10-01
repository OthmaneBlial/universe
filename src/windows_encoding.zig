const std = @import("std");
const Memory = @import("memory.zig").Memory;

const Scalar = struct { value: u21, size: usize, valid: bool = true };
fn next(bytes: []const u8, wide: bool) Scalar {
    if (wide) {
        const first = std.mem.readInt(u16, bytes[0..2], .little);
        if (first < 0xd800 or first > 0xdfff) return .{ .value = first, .size = 2 };
        if (first <= 0xdbff and bytes.len >= 4) {
            const pair = [2]u16{ first, std.mem.readInt(u16, bytes[2..4], .little) };
            if (std.unicode.utf16DecodeSurrogatePair(&pair)) |value| return .{ .value = value, .size = 4 } else |_| {}
        }
        return .{ .value = 0xfffd, .size = 2, .valid = false };
    }
    const first = bytes[0];
    if (first < 0x80) return .{ .value = first, .size = 1 };
    const length: usize = if (first >= 0xc2 and first <= 0xdf) 2 else if (first >= 0xe0 and first <= 0xef) 3 else if (first >= 0xf0 and first <= 0xf4) 4 else return .{ .value = 0xfffd, .size = 1, .valid = false };
    var size: usize = 1;
    while (size < length) : (size += 1) {
        if (size >= bytes.len or bytes[size] < 0x80 or bytes[size] > 0xbf or
            (size == 1 and ((first == 0xe0 and bytes[size] < 0xa0) or (first == 0xed and bytes[size] > 0x9f) or (first == 0xf0 and bytes[size] < 0x90) or (first == 0xf4 and bytes[size] > 0x8f))))
            return .{ .value = 0xfffd, .size = size, .valid = false };
    }
    return .{ .value = std.unicode.utf8Decode(bytes[0..length]) catch unreachable, .size = length };
}
fn encode(value: u21, wide: bool, out: *[4]u8) usize {
    if (!wide) return std.unicode.utf8Encode(value, out) catch unreachable;
    if (value < 0x10000) {
        std.mem.writeInt(u16, out[0..2], @intCast(value), .little);
        return 2;
    }
    std.mem.writeInt(u16, out[0..2], @intCast(0xd800 + ((value - 0x10000) >> 10)), .little);
    std.mem.writeInt(u16, out[2..4], @intCast(0xdc00 + ((value - 0x10000) & 0x3ff)), .little);
    return 4;
}
fn input(allocator: std.mem.Allocator, m: *Memory, source: u64, count: i32, wide: bool) ![]u8 {
    const unit: usize = if (wide) 2 else 1;
    if (count > 0) {
        const size = @as(usize, @intCast(count)) * unit;
        if (size > m.limit) return error.MemoryLimit;
        try m.check(source, size, .read);
        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);
        try m.read(source, bytes, .read);
        return bytes;
    }
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    const limit = @min(m.limit / unit, std.math.maxInt(i32));
    for (0..limit) |index| {
        const address = std.math.add(u64, source, index * unit) catch return error.AddressOverflow;
        const value = try m.readInt(address, if (wide) 16 else 8, .read);
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @intCast(value), .little);
        try bytes.appendSlice(allocator, buf[0..unit]);
        if (value == 0) return bytes.toOwnedSlice(allocator);
    }
    return error.MemoryLimit;
}

// The virtual ANSI/OEM profile is UTF-8; legacy code-page tables are not installed.
pub fn convert(allocator: std.mem.Allocator, m: *Memory, source: u64, count: i32, destination: u64, capacity: i32, wide: bool, strict: bool, used_default: u64) !u64 {
    if (source == 0 or source == destination or count == 0 or count < -1 or capacity < 0) return error.InvalidParameter;
    if (capacity > 0 and destination == 0) return error.InsufficientBuffer;
    const bytes = try input(allocator, m, source, count, wide);
    defer allocator.free(bytes);
    const unit: usize = if (wide) 1 else 2;
    var required: usize = 0;
    var index: usize = 0;
    var buf: [4]u8 = undefined;
    while (index < bytes.len) {
        const scalar = next(bytes[index..], wide);
        if (!scalar.valid and strict) return error.InvalidUnicode;
        required += encode(scalar.value, !wide, &buf);
        if (required > m.limit or required / unit > std.math.maxInt(i32)) return error.MemoryLimit;
        index += scalar.size;
    }
    if (used_default != 0) try m.check(used_default, 4, .write);
    if (capacity == 0) {
        if (used_default != 0) try m.writeInt(used_default, 32, 0);
        return required / unit;
    }
    const size = @min(required, @as(usize, @intCast(capacity)) * unit);
    const output = try allocator.alloc(u8, size);
    defer allocator.free(output);
    index = 0;
    var written: usize = 0;
    while (index < bytes.len) {
        const scalar = next(bytes[index..], wide);
        const length = encode(scalar.value, !wide, &buf);
        if (length > size - written) break;
        @memcpy(output[written..][0..length], buf[0..length]);
        written += length;
        index += scalar.size;
    }
    // Short buffers receive only complete scalar values. Check the whole prefix before mutation.
    if (used_default != 0 and written != 0) {
        const end = std.math.add(u64, destination, written) catch return error.AddressOverflow;
        if (used_default < end and destination < used_default + 4) return error.InvalidParameter;
    }
    if (used_default != 0 and required <= size) {
        try m.prepareWrite(used_default, 4);
        try m.prepareWrite(destination, written);
    }
    try m.write(destination, output[0..written]);
    if (required > size) return error.InsufficientBuffer;
    if (used_default != 0) try m.writeInt(used_default, 32, 0); // UTF-8 represents every valid scalar; no fallback character is used.
    return required / unit;
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.write(0x1000, "é🚀\x00");
    try m.write(0x1800, &@as([16]u8, @splat(0xaa)));
    const result = convert(allocator, &m, 0x1000, -1, 0x1800, 8, false, true, 0) catch |err| {
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try m.readInt(0x1800, 64, .read));
        return err;
    };
    try std.testing.expectEqual(@as(u64, 4), result);
    try std.testing.expectEqual(@as(u64, 0x0000de80d83d00e9), try m.readInt(0x1800, 64, .read));
}
test "encoding allocation failures preserve output and release temporary buffers" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
test "encoding checks complete input and output ranges before writing" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    try m.write(0x1000, "a🚀");
    try m.writeInt(0x1ffe, 16, 0xcafe);
    try std.testing.expectError(error.PermissionDenied, convert(std.testing.allocator, &m, 0x1000, 5, 0x1ffe, 3, false, true, 0));
    try std.testing.expectEqual(@as(u64, 0xcafe), try m.readInt(0x1ffe, 16, .read));
    try m.writeInt(0x1fff, 8, 'a');
    try std.testing.expectError(error.UnmappedMemory, convert(std.testing.allocator, &m, 0x2fff, 2, 0x1800, 8, false, false, 0));
    try std.testing.expectError(error.AddressOverflow, convert(std.testing.allocator, &m, std.math.maxInt(u64), 2, 0x1800, 8, false, false, 0));
    try m.unmap(0x2000, 4096);
    try std.testing.expectError(error.UnmappedMemory, convert(std.testing.allocator, &m, 0x1fff, -1, 0x1800, 8, false, false, 0));
    m.limit = 1;
    try std.testing.expectError(error.MemoryLimit, convert(std.testing.allocator, &m, 0x1000, 5, 0x1800, 8, false, false, 0));
}

fn optionalDefaultProbe(allocator: std.mem.Allocator, cow: bool, query: bool) !void {
    const backing = try std.testing.allocator.alloc(u8, 16384);
    defer std.testing.allocator.free(backing);
    var m = Memory.init(allocator);
    defer m.deinit();
    @memset(backing, 0xaa);
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.write(0x1000, "A\x00\xe9\x00\x3d\xd8\x80\xde\x00\x00");
    try m.borrow(0x3000, backing, .{ .read = true, .write = true }, cow, null);
    const result = convert(allocator, &m, 0x1000, -1, if (query) 1 else 0x3ffe, if (query) 0 else 8, true, true, 0x5ffe) catch |err| {
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try m.readInt(0x3ffe, 64, .read));
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaa), try m.readInt(0x5ffe, 32, .read));
        for (backing) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
        return err;
    };
    try std.testing.expectEqual(@as(u64, 8), result);
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x5ffe, 32, .read));
    try std.testing.expectEqual(if (query) @as(u64, 0xaaaaaaaaaaaaaaaa) else @as(u64, 0x00809a9ff0a9c341), try m.readInt(0x3ffe, 64, .read));
    if (cow) for (backing) |byte| {
        try std.testing.expectEqual(@as(u8, 0xaa), byte);
    };
}
test "optional default flags and converted bytes publish together under allocation and checked faults" {
    for ([_]bool{ false, true }) |cow| for ([_]bool{ false, true }) |query|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, optionalDefaultProbe, .{ cow, query });
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x3000, 16384, .{ .read = true, .write = true });
    try m.write(0x1000, "A\x00\xe9\x00\x3d\xd8\x80\xde\x00\x00");
    try m.writeInt(0x3ffe, 64, 0xaaaaaaaaaaaaaaaa);
    try m.writeInt(0x5ffe, 32, 0xaaaaaaaa);
    for ([_]u64{ 0x4000, 0x6000 }) |page| {
        try m.protect(page, 4096, .{ .read = true });
        try std.testing.expectError(error.PermissionDenied, convert(std.testing.allocator, &m, 0x1000, -1, 0x3ffe, 8, true, true, 0x5ffe));
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try m.readInt(0x3ffe, 64, .read));
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaa), try m.readInt(0x5ffe, 32, .read));
        try m.protect(page, 4096, .{ .read = true, .write = true });
    }
    try std.testing.expectError(error.InvalidParameter, convert(std.testing.allocator, &m, 0x1000, -1, 0x3ffe, 8, true, true, 0x4000));
    try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try m.readInt(0x3ffe, 64, .read));
    try std.testing.expectError(error.InsufficientBuffer, convert(std.testing.allocator, &m, 0x1000, -1, 0x3ffe, 2, true, true, 0x5ffe));
    try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaa41), try m.readInt(0x3ffe, 64, .read));
    try std.testing.expectEqual(@as(u64, 0xaaaaaaaa), try m.readInt(0x5ffe, 32, .read));
    try m.protect(0x6000, 4096, .{ .write = true }); // BOOL output does not require read permission.
    try std.testing.expectEqual(@as(u64, 8), try convert(std.testing.allocator, &m, 0x1000, -1, 0x3ffe, 8, true, true, 0x5ffe));
    try m.protect(0x6000, 4096, .{ .read = true, .write = true });
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x5ffe, 32, .read));
}
