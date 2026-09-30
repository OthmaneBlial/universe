const std = @import("std");
const Memory = @import("../memory.zig").Memory;
pub const Architecture = enum { x86_64, riscv64, arm64 };
pub fn integer(comptime T: type, bytes: []const u8, offset: u64) !T {
    if (offset > bytes.len or @sizeOf(T) > bytes.len - offset) return error.TruncatedBinary;
    return std.mem.readInt(T, bytes[@intCast(offset)..][0..@sizeOf(T)], .little);
}
pub const Segment = struct { kind: u32, flags: u32, offset: u64, address: u64, filesz: u64, memsz: u64, alignment: u64 };
pub const Image = struct {
    bytes: []const u8,
    architecture: Architecture,
    entry: u64,
    kind: u16,
    phoff: u64,
    phnum: u16,
    shnum: u16,
    interpreter: ?[]const u8 = null,
    dynamic: bool = false,
    pub fn segment(i: Image, n: usize) !Segment {
        const o = i.phoff + n * 56;
        return .{ .kind = try integer(u32, i.bytes, o), .flags = try integer(u32, i.bytes, o + 4), .offset = try integer(u64, i.bytes, o + 8), .address = try integer(u64, i.bytes, o + 16), .filesz = try integer(u64, i.bytes, o + 32), .memsz = try integer(u64, i.bytes, o + 40), .alignment = try integer(u64, i.bytes, o + 48) };
    }
    pub fn load(i: Image, m: *Memory) !u64 {
        if (i.kind != 2) return error.PositionIndependentExecutableUnsupported;
        if (i.interpreter != null or i.dynamic) return error.DynamicLinkingUnsupported;
        var heap: u64 = 0;
        for (0..i.phnum) |n| {
            const s = try i.segment(n);
            if (s.kind != 1 or s.memsz == 0) continue;
            const base = s.address & ~@as(u64, 4095);
            const end = std.mem.alignForward(u64, s.address + s.memsz, 4096);
            try m.map(base, @intCast(end - base), .{ .read = s.flags & 4 != 0, .write = s.flags & 2 != 0, .execute = s.flags & 1 != 0 });
            try m.initialize(s.address, i.bytes[@intCast(s.offset)..][0..@intCast(s.filesz)]);
            heap = @max(heap, end);
        }
        try m.check(i.entry, 1, .execute);
        return heap;
    }
    pub fn phAddress(i: Image) u64 {
        for (0..i.phnum) |n| {
            const s = i.segment(n) catch return 0;
            if (s.kind == 1 and i.phoff >= s.offset and i.phoff + @as(u64, i.phnum) * 56 <= s.offset + s.filesz) return s.address + i.phoff - s.offset;
        }
        return 0;
    }
};
pub fn parse(b: []const u8) !Image {
    if (b.len < 64) return error.TruncatedBinary;
    if (!std.mem.eql(u8, b[0..4], "\x7fELF")) return error.NotELF;
    if (b[4] != 2) return error.ELF32Unsupported;
    if (b[5] != 1) return error.BigEndianUnsupported;
    if (b[6] != 1 or try integer(u32, b, 20) != 1 or try integer(u16, b, 52) != 64) return error.InvalidELFHeader;
    if (b[7] != 0 and b[7] != 3) return error.UnsupportedOSABI;
    const arch: Architecture = switch (try integer(u16, b, 18)) {
        62 => .x86_64,
        183 => .arm64,
        243 => .riscv64,
        else => return error.UnsupportedArchitecture,
    };
    const phoff = try integer(u64, b, 32);
    const phnum = try integer(u16, b, 56);
    const shoff = try integer(u64, b, 40);
    const shnum = try integer(u16, b, 60);
    if (phnum == 0 or phnum > 128 or try integer(u16, b, 54) != 56) return error.InvalidProgramHeaders;
    if (phoff < 64 or phoff > b.len or @as(u64, phnum) * 56 > b.len - phoff) return error.TruncatedBinary;
    if (shnum != 0 and (try integer(u16, b, 58) != 64 or shoff > b.len or @as(u64, shnum) * 64 > b.len - shoff)) return error.InvalidSections;
    var i = Image{ .bytes = b, .architecture = arch, .entry = try integer(u64, b, 24), .kind = try integer(u16, b, 16), .phoff = phoff, .phnum = phnum, .shnum = shnum };
    if (i.kind != 2 and i.kind != 3) return error.UnsupportedELFType;
    var executable_entry = false;
    for (0..phnum) |n| {
        const s = try i.segment(n);
        if (s.offset > b.len or s.filesz > b.len - s.offset) return error.TruncatedSegment;
        if (s.kind == 3) {
            if (i.interpreter != null or s.filesz < 2 or s.filesz > 4096) return error.InvalidInterpreter;
            const name = b[@intCast(s.offset)..][0..@intCast(s.filesz)];
            if (name[name.len - 1] != 0) return error.InvalidInterpreter;
            i.interpreter = name[0 .. name.len - 1];
        }
        if (s.kind == 2) i.dynamic = true;
        if (s.kind != 1) continue;
        if (s.filesz > s.memsz or s.memsz > 256 * 1024 * 1024) return error.InvalidSegmentSize;
        const end = std.math.add(u64, s.address, s.memsz) catch return error.AddressOverflow;
        if (end > 0x800000000000) return error.AddressOverflow;
        if (s.alignment > 1 and (!std.math.isPowerOfTwo(s.alignment) or s.address % s.alignment != s.offset % s.alignment)) return error.InvalidSegmentAlignment;
        if (s.flags & ~@as(u32, 7) != 0) return error.InvalidSegmentPermissions;
        if (i.entry >= s.address and i.entry < end and s.flags & 1 != 0) executable_entry = true;
    }
    if (!executable_entry) return error.InvalidEntryPoint;
    return i;
}
test "ELF parser rejects truncated, wrong class and overflowing headers" {
    try std.testing.expectError(error.TruncatedBinary, parse("\x7fELF"));
    var b: [120]u8 = @splat(0);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = 1;
    try std.testing.expectError(error.ELF32Unsupported, parse(&b));
}
test "ELF parser fuzz" {
    try std.testing.fuzz({}, fuzz, .{});
}
fn fuzz(_: void, smith: *std.testing.Smith) !void {
    var b: [4096]u8 = undefined;
    const n = smith.valueRangeAtMost(u16, 0, b.len);
    smith.bytes(b[0..n]);
    _ = parse(b[0..n]) catch {};
}

test "validated ELF load zero-fills BSS and rejects segment overflow" {
    var b: [192]u8 = @splat(0);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = 2;
    b[5] = 1;
    b[6] = 1;
    set(&b, 16, 16, 2);
    set(&b, 18, 16, 62);
    set(&b, 20, 32, 1);
    set(&b, 24, 64, 0x1080);
    set(&b, 32, 64, 64);
    set(&b, 52, 16, 64);
    set(&b, 54, 16, 56);
    set(&b, 56, 16, 1);
    set(&b, 64, 32, 1);
    set(&b, 68, 32, 5);
    set(&b, 80, 64, 0x1000);
    set(&b, 96, 64, b.len);
    set(&b, 104, 64, 4096);
    set(&b, 112, 64, 4096);
    const image = try parse(&b);
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(@as(u64, 0x2000), try image.load(&m));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1800, 64, .read));
    try std.testing.expectError(error.PermissionDenied, m.writeInt(0x1800, 64, 1));
    set(&b, 80, 64, std.math.maxInt(u64));
    try std.testing.expectError(error.AddressOverflow, parse(&b));
}
fn set(bytes: []u8, off: usize, width: u7, v: u64) void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    @memcpy(bytes[off..][0 .. width / 8], b[0 .. width / 8]);
}
