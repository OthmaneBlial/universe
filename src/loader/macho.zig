const std = @import("std");
const integer = @import("elf.zig").integer;
const Architecture = @import("elf.zig").Architecture;
const Memory = @import("../memory.zig").Memory;
const State = @import("../cpu/state.zig").State;
pub const Image = struct {
    bytes: []const u8,
    architecture: Architecture,
    file_type: u32,
    commands: u32,
    command_bytes: u32,
    segments: u32,
    libraries: u32,
    entry: ?u64,
    thread_offset: ?u64 = null,
    pub fn load(image: Image, m: *Memory, state: *State) !void {
        if (image.file_type != 2) return error.MachOExecutableRequired;
        if (image.libraries != 0) return error.MachOLibrariesUnsupported;
        const entry = image.entry orelse return error.MissingMachOEntry;
        var off: u64 = 32;
        for (0..image.commands) |_| {
            const cmd = try integer(u32, image.bytes, off);
            const len = try integer(u32, image.bytes, off + 4);
            switch (cmd) {
                0x19 => {
                    const address = try integer(u64, image.bytes, off + 24);
                    const size = try integer(u64, image.bytes, off + 32);
                    const fileoff = try integer(u64, image.bytes, off + 40);
                    const filesz = try integer(u64, image.bytes, off + 48);
                    const prot = try integer(u32, image.bytes, off + 60);
                    const flags = try integer(u32, image.bytes, off + 68);
                    if (flags & ~@as(u32, 4) != 0) return error.UnsupportedMachOSegmentFlags;
                    const name = std.mem.sliceTo(image.bytes[@intCast(off + 8)..][0..16], 0);
                    if (std.mem.eql(u8, name, "__PAGEZERO")) {
                        if (address != 0 or filesz != 0 or prot != 0 or try integer(u32, image.bytes, off + 56) != 0) return error.InvalidMachOPageZero;
                    } else if (size != 0) {
                        const page: usize = if (image.architecture == .arm64) 16384 else 4096;
                        if (address < page or address % page != 0 or size > m.limit or address > 0x800000000000 - size) return error.InvalidMachOMapping;
                        const mapped = std.mem.alignForward(usize, @intCast(size), page);
                        const maximum = try integer(u32, image.bytes, off + 56);
                        try m.mapWithMaximum(address, mapped, .{ .read = prot & 1 != 0, .write = prot & 2 != 0, .execute = prot & 4 != 0 }, .{ .read = maximum & 1 != 0, .write = maximum & 2 != 0, .execute = maximum & 4 != 0 });
                        try m.initialize(address, image.bytes[@intCast(fileoff)..][0..@intCast(filesz)]);
                    }
                    for (0..try integer(u32, image.bytes, off + 64)) |n| {
                        const section = off + 72 + n * 80;
                        if (try integer(u32, image.bytes, section + 60) != 0) return error.MachORelocationsUnsupported;
                        const kind = (try integer(u32, image.bytes, section + 64)) & 255;
                        if (kind >= 0x11 and kind <= 0x15) return error.MachOTLSUnsupported;
                        if (kind == 9 or kind == 10 or kind == 0x16) return error.MachOInitializersUnsupported;
                    }
                },
                0x80000022, 0x22 => {
                    if (len != 48) return error.InvalidMachOFixups;
                    for (0..4) |n| if (try integer(u32, image.bytes, off + 12 + n * 8) != 0) return error.MachOFixupsUnsupported;
                },
                0x80000034 => {
                    if (len != 16) return error.InvalidMachOFixups;
                    if (try integer(u32, image.bytes, off + 12) != 0) return error.MachOFixupsUnsupported;
                },
                0xe => return error.MachODynamicLinkerUnsupported,
                0x21, 0x2c => {
                    if (len != 24) return error.InvalidMachOEncryption;
                    if (try integer(u32, image.bytes, off + 16) != 0) return error.MachOEncryptionUnsupported;
                },
                0xb => {
                    if (len != 80) return error.InvalidMachOSymbols;
                    if (try integer(u32, image.bytes, off + 28) != 0 or try integer(u32, image.bytes, off + 68) != 0 or try integer(u32, image.bytes, off + 76) != 0) return error.MachORelocationsUnsupported;
                },
                0x5, 0x80000028, 0x2, 0x1b, 0x1d, 0x24, 0x26, 0x29, 0x2a, 0x32, 0x80000033 => {},
                else => return error.UnsupportedMachOCommand,
            }
            off += len;
        }
        try m.check(entry, 1, .execute);
        state.pc = entry;
        if (image.thread_offset) |thread| {
            if (image.architecture == .x86_64) {
                const registers = [_]u6{ 0, 3, 1, 2, 7, 6, 5, 4, 8, 9, 10, 11, 12, 13, 14, 15 };
                for (registers, 0..) |r, n| state.set(r, try integer(u64, image.bytes, thread + n * 8));
                const flags = try integer(u64, image.bytes, thread + 17 * 8);
                state.flags = .{ .carry = flags & 1 != 0, .parity = flags & 4 != 0, .auxiliary = flags & 16 != 0, .zero = flags & 64 != 0, .sign = flags & 128 != 0, .direction = flags & 1024 != 0, .overflow = flags & 2048 != 0 };
            } else {
                for (0..32) |r| state.set(@intCast(r), try integer(u64, image.bytes, thread + r * 8));
                const flags = try integer(u32, image.bytes, thread + 33 * 8);
                state.flags = .{ .sign = flags & (1 << 31) != 0, .zero = flags & (1 << 30) != 0, .carry = flags & (1 << 29) != 0, .overflow = flags & (1 << 28) != 0 };
            }
            if (state.get(state.stackRegister()) != 0) return error.MachOInitialStackUnsupported;
        }
    }
};
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
            const maxprot = try integer(u32, b, off + 56);
            const prot = try integer(u32, b, off + 60);
            if (maxprot & ~@as(u32, 7) != 0 or prot & ~maxprot != 0) return error.InvalidMachOProtection;
            for (0..sections) |index| {
                const section = off + 72 + index * 80;
                const start = try integer(u64, b, section + 32);
                const count = try integer(u64, b, section + 40);
                const offset = try integer(u32, b, section + 48);
                const kind = (try integer(u32, b, section + 64)) & 255;
                if (start < address or start - address > vmsize or count > vmsize - (start - address)) return error.InvalidMachOSection;
                if (kind != 1 and kind != 0xc and kind != 0x12 and (offset < fileoff or offset - fileoff > filesize or count > filesize - (offset - fileoff))) return error.InvalidMachOSection;
            }
            image.segments += 1;
        } else if (cmd == 0x80000028) {
            if (len != 24 or entry_offset != null or image.thread_offset != null) return error.InvalidMachOEntry;
            entry_offset = try integer(u64, b, off + 8);
        } else if (cmd == 5) {
            if (entry_offset != null or image.thread_offset != null or len < 16) return error.InvalidMachOEntry;
            const flavor = try integer(u32, b, off + 8);
            const count = try integer(u32, b, off + 12);
            const x86 = arch == .x86_64;
            if (flavor != (if (x86) @as(u32, 4) else 6) or count != (if (x86) @as(u32, 42) else 68) or len != 16 + count * 4) return error.UnsupportedMachOThreadState;
            image.thread_offset = off + 16;
            image.entry = try integer(u64, b, off + 16 + (if (x86) @as(u64, 16) else 32) * 8);
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
    if (image.thread_offset != null) {
        off = 32;
        var valid = false;
        for (0..n) |_| {
            const cmd = try integer(u32, b, off);
            const len = try integer(u32, b, off + 4);
            if (cmd == 0x19) {
                const address = try integer(u64, b, off + 24);
                const filesz = try integer(u64, b, off + 48);
                if (image.entry.? >= address and image.entry.? - address < filesz and (try integer(u32, b, off + 60)) & 4 != 0) valid = true;
            }
            off += len;
        }
        if (!valid) return error.InvalidMachOEntry;
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

test "Mach-O segments, raw thread state and main entry obey permissions, stack ABI and limits" {
    const a = std.testing.allocator;
    const Runtime = @import("../runtime.zig").Runtime;
    for ([_]Architecture{ .x86_64, .arm64 }) |arch| {
        const page: u64 = if (arch == .arm64) 16384 else 4096;
        for ([_]bool{ false, true }) |thread| {
            var b: [1032]u8 = @splat(0);
            const entry_size: u32 = if (!thread) 24 else if (arch == .x86_64) 184 else 288;
            for ([_]usize{ 0, 4, 12, 16, 20, 32, 36, 88, 92, 104, 108, 160, 164, 176, 180 }, [_]u32{ 0xfeedfacf, if (arch == .x86_64) 0x1000007 else 0x100000c, 2, 3, 144 + entry_size, 0x19, 72, 5, 5, 0x19, 72, 3, 3, if (thread) 5 else 0x80000028, entry_size }) |off, value| setFixture(&b, off, 32, value);
            @memcpy(b[40..46], "__TEXT");
            @memcpy(b[112..118], "__DATA");
            for ([_]usize{ 56, 64, 80, 128, 136, 144, 152 }, [_]u64{ 0x100000000, page, 1024, 0x100000000 + page, page, 1024, 8 }) |off, value| setFixture(&b, off, 64, value);
            setFixture(&b, 1024, 64, 0x1234);
            if (arch == .x86_64) @memcpy(b[512..518], "\xb8\x25\x00\x00\x00\xc3") else {
                setFixture(&b, 512, 32, 0x528004a0); // MOV W0, #37
                setFixture(&b, 516, 32, 0xd65f03c0); // RET
            }
            if (thread) {
                setFixture(&b, 184, 32, if (arch == .x86_64) 4 else 6);
                setFixture(&b, 188, 32, if (arch == .x86_64) 42 else 68);
                setFixture(&b, 192 + (if (arch == .x86_64) @as(usize, 16) else 32) * 8, 64, 0x100000200);
                setFixture(&b, 192 + (if (arch == .x86_64) @as(usize, 1) else 5) * 8, 64, 0xfeed);
                setFixture(&b, 192 + (if (arch == .x86_64) @as(usize, 17) else 33) * 8, if (arch == .x86_64) 64 else 32, if (arch == .x86_64) 0xffffffffffffffff else 0xf0000000);
            } else setFixture(&b, 184, 64, 512);
            const image = try parse(&b);
            var runtime = try Runtime.initMachO(a, image, &.{ "guest", "argument" }, &.{"KEY=value"}, .{});
            defer runtime.deinit();
            try std.testing.expectEqual(@as(u64, 0x1234), try runtime.memory.readInt(0x100000000 + page, 64, .read));
            try std.testing.expectEqual(@as(u64, 0), try runtime.memory.readInt(0x100000008 + page, 64, .read));
            try std.testing.expectError(error.PermissionDenied, runtime.memory.writeInt(0x100000200, 8, 0));
            try std.testing.expectError(error.ProtectionLimit, runtime.memory.protect(0x100000000, @intCast(page), .{ .read = true, .write = true }));
            const sp = runtime.state.get(runtime.state.stackRegister());
            const raw_sp = if (!thread and arch == .x86_64) sp + 8 else sp;
            try std.testing.expectEqual(@as(u64, 0), raw_sp % 16);
            try std.testing.expectEqual(@as(u64, 2), try runtime.memory.readInt(raw_sp, 64, .read));
            const apple_ptr = try runtime.memory.readInt(raw_sp + 48, 64, .read);
            const apple = try runtime.memory.cstring(a, apple_ptr, 100);
            defer a.free(apple);
            try std.testing.expectEqualStrings("executable_path=guest", apple);
            if (thread) {
                try std.testing.expectEqual(@as(u64, 0xfeed), runtime.state.get(if (arch == .x86_64) 3 else 5));
                const flag_image: u64 = if (arch == .x86_64) 0xcd7 else 0x8c3;
                try std.testing.expectEqual(flag_image, runtime.state.flags.bits());
                try std.testing.expectEqual(arch == .x86_64, runtime.state.flags.auxiliary);
                try std.testing.expect(!runtime.macos.?.returns_main);
                try runtime.step();
                try std.testing.expectEqual(@as(u64, 37), runtime.state.get(0));
                try std.testing.expectEqual(flag_image, runtime.state.flags.bits());
            } else {
                try std.testing.expectEqual(@as(u64, 2), runtime.state.get(if (arch == .x86_64) 7 else 0));
                try std.testing.expectEqual(@as(u8, 37), try runtime.run());
                try std.testing.expectEqual(@as(u64, 3), runtime.state.instructions);
                if (@import("builtin").cpu.arch == .aarch64) {
                    var compiled = try Runtime.initMachO(a, image, &.{"guest"}, &.{}, .{ .jit = true });
                    defer compiled.deinit();
                    try std.testing.expectEqual(@as(u8, 37), try compiled.run());
                    try std.testing.expectEqual(@as(u64, 3), compiled.state.instructions);
                }
                var limited = try Runtime.initMachO(a, image, &.{"guest"}, &.{}, .{ .max_instructions = 2 });
                defer limited.deinit();
                try std.testing.expectError(error.InstructionLimit, limited.run());
            }
            setFixture(&b, 92, 32, 7);
            try std.testing.expectError(error.InvalidMachOProtection, parse(&b));
            setFixture(&b, 92, 32, 5);
            setFixture(&b, 64, 64, 512 * 1024 * 1024);
            var invalid_memory = Memory.init(a);
            defer invalid_memory.deinit();
            var state = State{ .architecture = arch };
            try std.testing.expectError(error.InvalidMachOMapping, (try parse(&b)).load(&invalid_memory, &state));
        }
    }
}
fn setFixture(b: []u8, off: usize, width: u7, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    @memcpy(b[off..][0 .. width / 8], bytes[0 .. width / 8]);
}
