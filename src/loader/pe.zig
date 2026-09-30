const std = @import("std");
const integer = @import("elf.zig").integer;
const Memory = @import("../memory.zig").Memory;
pub const Directory = struct { rva: u32, size: u32 };
pub const Section = struct { name: []const u8, rva: u32, virtual_size: u32, offset: u32, file_size: u32, flags: u32 };
pub const Image = struct {
    bytes: []const u8,
    optional: u64,
    section_offset: u64,
    section_count: u16,
    base: u64,
    entry_rva: u32,
    image_size: u32,
    header_size: u32,
    directory_count: u32,
    is_dll: bool = false,
    pub fn section(i: Image, n: usize) !Section {
        const o = i.section_offset + n * 40;
        const name = i.bytes[@intCast(o)..][0..8];
        return .{ .name = name[0 .. std.mem.indexOfScalar(u8, name, 0) orelse 8], .virtual_size = try integer(u32, i.bytes, o + 8), .rva = try integer(u32, i.bytes, o + 12), .file_size = try integer(u32, i.bytes, o + 16), .offset = try integer(u32, i.bytes, o + 20), .flags = try integer(u32, i.bytes, o + 36) };
    }
    pub fn directory(i: Image, n: usize) !Directory {
        if (n >= i.directory_count) return .{ .rva = 0, .size = 0 };
        return .{ .rva = try integer(u32, i.bytes, i.optional + 112 + n * 8), .size = try integer(u32, i.bytes, i.optional + 116 + n * 8) };
    }
    pub fn rvaSlice(i: Image, rva: u32, size: u32) ![]const u8 {
        if (rva < i.header_size and size <= i.header_size - rva) return i.bytes[rva..][0..size];
        for (0..i.section_count) |n| {
            const s = try i.section(n);
            if (rva >= s.rva and rva - s.rva <= s.file_size and size <= s.file_size - (rva - s.rva)) return i.bytes[@as(usize, s.offset) + rva - s.rva ..][0..size];
        }
        return error.InvalidPERva;
    }
    pub fn load(i: Image, m: *Memory, base: u64) !void {
        if (base % 65536 != 0) return error.InvalidPEBase;
        const end = std.math.add(u64, base, i.image_size) catch return error.AddressOverflow;
        if (end > 0x800000000000) return error.AddressOverflow;
        if ((try i.directory(9)).size != 0) return error.PETLSUnsupported;
        if ((try i.directory(13)).size != 0) return error.PEDelayImportsUnsupported;
        if (!m.available(base, i.image_size)) return error.OverlappingMapping;
        try m.map(base, i.image_size, .{});
        errdefer m.unmap(base, i.image_size) catch unreachable;
        try m.protect(base, std.mem.alignForward(usize, i.header_size, 4096), .{ .read = true });
        try m.initialize(base, i.bytes[0..i.header_size]);
        for (0..i.section_count) |n| {
            const s = try i.section(n);
            const len = @max(s.file_size, s.virtual_size);
            if (len == 0) continue;
            try m.protect(base + s.rva, std.mem.alignForward(usize, len, 4096), .{ .read = s.flags & 0x40000000 != 0, .write = s.flags & 0x80000000 != 0, .execute = s.flags & 0x20000000 != 0 });
            try m.initialize(base + s.rva, i.bytes[s.offset..][0..s.file_size]);
        }
        if (base != i.base) try i.relocate(m, base);
        if (i.entry_rva != 0) try m.check(base + i.entry_rva, 1, .execute);
    }
    fn relocate(i: Image, m: *Memory, base: u64) !void {
        const dir = try i.directory(5);
        if (dir.size == 0) return error.PERelocationsMissing;
        const bytes = try i.rvaSlice(dir.rva, dir.size);
        var offset: usize = 0;
        const delta = base -% i.base;
        while (offset < bytes.len) {
            if (bytes.len - offset < 8) return error.InvalidPERelocations;
            const page = try integer(u32, bytes, offset);
            const size = try integer(u32, bytes, offset + 4);
            if (size < 8 or size % 2 != 0 or size > bytes.len - offset) return error.InvalidPERelocations;
            for (0..(size - 8) / 2) |n| {
                const item = try integer(u16, bytes, offset + 8 + n * 2);
                const kind = item >> 12;
                if (kind == 0) continue;
                if (kind != 10) return error.UnsupportedPERelocation;
                const rva = @as(u64, page) + (item & 4095);
                if (rva + 8 > i.image_size) return error.InvalidPERelocations;
                const old = try m.readInt(base + rva, 64, .read);
                var buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &buf, old +% delta, .little);
                try m.initialize(base + rva, &buf);
            }
            offset += size;
        }
    }
};
pub fn parse(b: []const u8) !Image {
    if (b.len < 64) return error.TruncatedBinary;
    if (!std.mem.eql(u8, b[0..2], "MZ")) return error.NotPE;
    const pe = try integer(u32, b, 60);
    if (pe < 64 or try integer(u32, b, pe) != 0x4550) return error.InvalidPEHeader;
    if (try integer(u16, b, @as(u64, pe) + 4) != 0x8664) return error.UnsupportedArchitecture;
    const count = try integer(u16, b, @as(u64, pe) + 6);
    const optional_size = try integer(u16, b, @as(u64, pe) + 20);
    const characteristics = try integer(u16, b, @as(u64, pe) + 22);
    if (count == 0 or count > 96 or optional_size < 112 or characteristics & 2 == 0) return error.InvalidPEHeader;
    const o = @as(u64, pe) + 24;
    if (try integer(u16, b, o) != 0x20b) return error.PE32Unsupported;
    const dirs = try integer(u32, b, o + 108);
    if (dirs > 16 or 112 + @as(u32, dirs) * 8 > optional_size) return error.InvalidPEDirectories;
    const section_offset = o + optional_size;
    if (section_offset > b.len or @as(u64, count) * 40 > b.len - section_offset) return error.TruncatedBinary;
    var i = Image{ .bytes = b, .optional = o, .section_offset = section_offset, .section_count = count, .base = try integer(u64, b, o + 24), .entry_rva = try integer(u32, b, o + 16), .image_size = try integer(u32, b, o + 56), .header_size = try integer(u32, b, o + 60), .directory_count = dirs, .is_dll = characteristics & 0x2000 != 0 };
    const alignment = try integer(u32, b, o + 32);
    const file_alignment = try integer(u32, b, o + 36);
    if (alignment != 4096 or file_alignment < 512 or file_alignment > 65536 or !std.math.isPowerOfTwo(file_alignment)) return error.UnsupportedPEAlignment;
    if (i.image_size == 0 or i.image_size > 256 * 1024 * 1024 or i.image_size % 4096 != 0 or i.header_size > b.len or i.header_size > i.image_size or i.header_size < section_offset + count * 40 or i.base % 65536 != 0 or i.base > @as(u64, 0x800000000000) - i.image_size) return error.InvalidPEImageSize;
    var entry_ok = i.is_dll and i.entry_rva == 0;
    for (0..count) |n| {
        const s = try i.section(n);
        const len = @max(s.file_size, s.virtual_size);
        if (s.offset > b.len or s.file_size > b.len - s.offset or s.rva % 4096 != 0 or s.rva > i.image_size or len > i.image_size - s.rva) return error.InvalidPESection;
        if (len != 0) {
            const end = @as(u64, s.rva) + std.mem.alignForward(u64, len, 4096);
            if (s.rva < std.mem.alignForward(u64, i.header_size, 4096) or end > i.image_size) return error.InvalidPESection;
            for (0..n) |previous| {
                const other = try i.section(previous);
                const other_len = @max(other.file_size, other.virtual_size);
                if (other_len != 0 and s.rva < @as(u64, other.rva) + std.mem.alignForward(u64, other_len, 4096) and other.rva < end) return error.OverlappingPESections;
            }
        }
        if (i.entry_rva >= s.rva and i.entry_rva - s.rva < len and s.flags & 0x20000000 != 0) entry_ok = true;
    }
    if (!entry_ok) return error.InvalidEntryPoint;
    for (0..dirs) |n| {
        const d = try i.directory(n);
        if (d.size == 0) continue;
        if (n == 4) {
            if (d.rva > b.len or d.size > b.len - d.rva) return error.InvalidPEDirectories;
        } else if (d.rva > i.image_size or d.size > i.image_size - d.rva) return error.InvalidPEDirectories;
    }
    return i;
}
test "PE parser fuzz" {
    try std.testing.fuzz({}, fuzz, .{});
}
fn fuzz(_: void, smith: *std.testing.Smith) !void {
    var b: [4096]u8 = undefined;
    smith.bytes(&b);
    _ = parse(&b) catch {};
}
test "PE malformed DOS header" {
    try std.testing.expectError(error.TruncatedBinary, parse("MZ"));
}

test "PE32+ sections, zero fill and DIR64 relocation on RX memory" {
    var bytes: [1536]u8 = @splat(0);
    @memcpy(bytes[0..2], "MZ");
    set(&bytes, 60, 32, 64);
    @memcpy(bytes[64..68], "PE\x00\x00");
    set(&bytes, 68, 16, 0x8664);
    set(&bytes, 70, 16, 2);
    set(&bytes, 84, 16, 240);
    set(&bytes, 86, 16, 2);
    const o = 88;
    set(&bytes, o, 16, 0x20b);
    set(&bytes, o + 16, 32, 0x1000);
    set(&bytes, o + 24, 64, 0x140000000);
    set(&bytes, o + 32, 32, 4096);
    set(&bytes, o + 36, 32, 512);
    set(&bytes, o + 56, 32, 0x4000);
    set(&bytes, o + 60, 32, 512);
    set(&bytes, o + 108, 32, 16);
    set(&bytes, o + 112 + 5 * 8, 32, 0x2000);
    set(&bytes, o + 116 + 5 * 8, 32, 12);
    for (0..2) |n| {
        const s = 328 + n * 40;
        set(&bytes, s + 8, 32, 4096);
        set(&bytes, s + 12, 32, 0x1000 + n * 0x1000);
        set(&bytes, s + 16, 32, 512);
        set(&bytes, s + 20, 32, 512 + n * 512);
        set(&bytes, s + 36, 32, if (n == 0) 0x60000020 else 0x40000040);
    }
    set(&bytes, 520, 64, 0x140001000);
    set(&bytes, 1024, 32, 0x1000);
    set(&bytes, 1028, 32, 12);
    set(&bytes, 1032, 16, 0xa008);
    const image = try parse(&bytes);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadAllocationCheck, .{&bytes});
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try image.load(&m, 0x150000000);
    try std.testing.expectEqual(@as(u64, 0x150001000), try m.readInt(0x150001008, 64, .read));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x150001800, 64, .read));
    try std.testing.expectError(error.PermissionDenied, m.writeInt(0x150001000, 8, 0));
    try std.testing.expectError(error.PermissionDenied, m.readInt(0x150003000, 8, .read));
    try std.testing.expect(!m.available(0x150003000, 4096));
    const used = m.used;
    try std.testing.expectError(error.OverlappingMapping, image.load(&m, 0x150000000));
    try std.testing.expectEqual(used, m.used);
    var invalid = bytes;
    set(&invalid, o + 116 + 5 * 8, 32, 0);
    try std.testing.expectError(error.PERelocationsMissing, (try parse(&invalid)).load(&m, 0x160000000));
    try std.testing.expectEqual(used, m.used);
    try std.testing.expect(m.available(0x160000000, 0x4000));
    set(&invalid, 328 + 40 + 12, 32, 0x1000);
    try std.testing.expectError(error.OverlappingPESections, parse(&invalid));
    set(&bytes, 86, 16, 0x2002);
    set(&bytes, o + 16, 32, 0);
    const dll = try parse(&bytes);
    try std.testing.expect(dll.is_dll and dll.entry_rva == 0);
    var dll_memory = Memory.init(std.testing.allocator);
    defer dll_memory.deinit();
    try dll.load(&dll_memory, 0x160000000);
    try std.testing.expectEqual(@as(u64, 0x160001000), try dll_memory.readInt(0x160001008, 64, .read));
}
fn loadAllocationCheck(a: std.mem.Allocator, bytes: []const u8) !void {
    var memory = Memory.init(a);
    defer memory.deinit();
    const image = try parse(bytes);
    image.load(&memory, 0x150000000) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), memory.used);
        try std.testing.expect(memory.available(0x150000000, image.image_size));
        return err;
    };
    try std.testing.expectEqual(@as(u64, 0x150001000), try memory.readInt(0x150001008, 64, .read));
}
fn set(bytes: []u8, off: usize, width: u7, v: u64) void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    @memcpy(bytes[off..][0 .. width / 8], b[0 .. width / 8]);
}
