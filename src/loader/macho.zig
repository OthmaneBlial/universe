const std = @import("std");
const integer = @import("elf.zig").integer;
const Architecture = @import("elf.zig").Architecture;
pub const Image = struct { bytes: []const u8, architecture: Architecture, file_type: u32, commands: u32, command_bytes: u32, segments: u32, libraries: u32, entry: ?u64 };
pub fn parse(b: []const u8) !Image {
    if (b.len < 32) return error.TruncatedBinary;
    if (try integer(u32, b, 0) != 0xfeedfacf) return error.NotMachO;
    const arch: Architecture = switch (try integer(u32, b, 4)) {
        0x1000007 => .x86_64,
        0x100000c => .arm64,
        else => return error.UnsupportedArchitecture,
    };
    const n = try integer(u32, b, 16);
    const size = try integer(u32, b, 20);
    if (n > 4096 or size > b.len - 32) return error.InvalidMachOCommands;
    var image = Image{ .bytes = b, .architecture = arch, .file_type = try integer(u32, b, 12), .commands = n, .command_bytes = size, .segments = 0, .libraries = 0, .entry = null };
    var off: u64 = 32;
    var entry_offset: ?u64 = null;
    for (0..n) |_| {
        if (off > 32 + @as(u64, size) or 8 > 32 + @as(u64, size) - off) return error.InvalidMachOCommands;
        const cmd = try integer(u32, b, off);
        const len = try integer(u32, b, off + 4);
        if (len < 8 or len % 8 != 0 or len > 32 + @as(u64, size) - off) return error.InvalidMachOCommands;
        if (cmd == 0x19) {
            if (len < 72) return error.InvalidMachOSegment;
            const address = try integer(u64, b, off + 24);
            const vmsize = try integer(u64, b, off + 32);
            const fileoff = try integer(u64, b, off + 40);
            const filesize = try integer(u64, b, off + 48);
            const sections = try integer(u32, b, off + 64);
            if (fileoff > b.len or filesize > b.len - fileoff or filesize > vmsize or @as(u64, sections) * 80 > len - 72) return error.InvalidMachOSegment;
            _ = std.math.add(u64, address, vmsize) catch return error.AddressOverflow;
            image.segments += 1;
        } else if (cmd == 0x80000028) {
            if (len != 24 or entry_offset != null) return error.InvalidMachOEntry;
            entry_offset = try integer(u64, b, off + 8);
        } else if (cmd == 0xc or cmd == 0x80000018 or cmd == 0x8000001f or cmd == 0x80000023) {
            if (len < 24) return error.InvalidMachOLibrary;
            const nameoff = try integer(u32, b, off + 8);
            if (nameoff < 24 or nameoff >= len or std.mem.indexOfScalar(u8, b[@intCast(off + nameoff)..@intCast(off + len)], 0) == null) return error.InvalidMachOLibrary;
            image.libraries += 1;
        }
        off += len;
    }
    if (off != 32 + @as(u64, size)) return error.InvalidMachOCommands;
    if (entry_offset) |entry| {
        off = 32;
        for (0..n) |_| {
            const cmd = try integer(u32, b, off);
            const len = try integer(u32, b, off + 4);
            if (cmd == 0x19) {
                const fileoff = try integer(u64, b, off + 40);
                const filesize = try integer(u64, b, off + 48);
                const protection = try integer(u32, b, off + 60);
                if (entry >= fileoff and entry - fileoff < filesize and protection & 4 != 0) {
                    image.entry = (try integer(u64, b, off + 24)) + entry - fileoff;
                    break;
                }
            }
            off += len;
        }
        if (image.entry == null) return error.InvalidMachOEntry;
    }
    return image;
}
test "Mach-O malformed commands and fuzz" {
    try std.testing.expectError(error.TruncatedBinary, parse("\xcf\xfa\xed\xfe"));
    try std.testing.fuzz({}, fuzz, .{});
}
fn fuzz(_: void, smith: *std.testing.Smith) !void {
    var b: [4096]u8 = undefined;
    smith.bytes(&b);
    _ = parse(&b) catch {};
}
