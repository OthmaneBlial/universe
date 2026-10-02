//! Linux's little-endian 64-bit signal frames, serialized into checked guest memory.
const std = @import("std");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
const Architecture = @import("loader/elf.zig").Architecture;
const fp = @import("x86_state.zig");
pub const unblockable: u64 = 0x40100;
const x86_regs = [_]u6{ 8, 9, 10, 11, 12, 13, 14, 15, 7, 6, 5, 3, 2, 0, 1, 4 };
pub const Restored = struct { mask: u64, alternate_stack: [24]u8 };
fn put(bytes: []u8, offset: usize, comptime T: type, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}
fn get(bytes: []const u8, offset: usize, comptime T: type) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
pub fn size(arch: Architecture) usize {
    return switch (arch) {
        .x86_64 => 952,
        .arm64 => 4704,
        .riscv64 => 1088,
    };
}
fn ucOffset(arch: Architecture) usize {
    return if (arch == .x86_64) 8 else 128;
}
fn contextOffset(arch: Architecture) usize {
    return if (arch == .x86_64) 48 else 304;
}
fn maskOffset(arch: Architecture) usize {
    return if (arch == .x86_64) 304 else 168;
}
fn onStack(stack: [24]u8, sp: u64) bool {
    const base = get(&stack, 0, u64);
    return get(&stack, 8, u32) & 0x80000002 == 0 and sp > base and sp - base <= get(&stack, 16, u64);
}
/// No CPU changes or partially written frames if preflight/allocation fails.
pub fn enter(s: *State, m: *Memory, sig: u7, info: *const [128]u8, action: [32]u8, mask: u64, stack: [24]u8, restorer: u64) !void {
    const handler = get(&action, 0, u64);
    const flags = get(&action, 8, u64);
    if (s.architecture == .x86_64 and flags & 0x4000000 == 0) return error.UnsupportedSignalRestorer;
    try m.check(handler, 1, .execute);
    try m.check(restorer, 1, .execute);
    var top = s.get(s.stackRegister());
    const active = onStack(stack, top);
    if (flags & 0x8000000 != 0 and !active and get(&stack, 8, u32) & 2 == 0)
        top = std.math.add(u64, get(&stack, 0, u64), get(&stack, 16, u64)) catch return error.AddressOverflow
    else if (s.architecture == .x86_64)
        top = std.math.sub(u64, top, 128) catch return error.AddressOverflow; // Preserve the x86 red zone.
    const length = size(s.architecture);
    var base = std.mem.alignBackward(u64, std.math.sub(u64, top, length) catch return error.AddressOverflow, 16);
    if (s.architecture == .x86_64) base = std.math.sub(u64, base, 8) catch return error.AddressOverflow;
    if ((active or flags & 0x8000000 != 0 and get(&stack, 8, u32) & 2 == 0) and base < get(&stack, 0, u64)) return error.InvalidSignalStack;
    var bytes: [4704]u8 = @splat(0);
    const uc = ucOffset(s.architecture);
    const sc = contextOffset(s.architecture);
    const info_offset: usize = if (s.architecture == .x86_64) 312 else 0;
    @memcpy(bytes[info_offset..][0..128], info);
    @memcpy(bytes[uc + 16 ..][0..24], &stack);
    if (active) put(&bytes, uc + 24, u32, get(&stack, 8, u32) | 1);
    put(&bytes, maskOffset(s.architecture), u64, mask);
    switch (s.architecture) {
        .x86_64 => {
            put(&bytes, 0, u64, restorer);
            put(&bytes, uc, u64, 6); // UC_SIGCONTEXT_SS | UC_STRICT_RESTORE_SS, legacy FP state.
            for (x86_regs, 0..) |reg, index| put(&bytes, sc + index * 8, u64, s.get(reg));
            put(&bytes, sc + 128, u64, s.pc);
            put(&bytes, sc + 136, u64, s.flags.bits());
            put(&bytes, sc + 144, u16, 0x33);
            put(&bytes, sc + 150, u16, 0x2b);
            put(&bytes, sc + 168, u64, mask);
            put(&bytes, sc + 184, u64, base + 440);
            const image = fp.encodeFxsave(s, 64);
            @memcpy(bytes[440..952], &image);
        },
        .arm64 => {
            for (0..31) |reg| put(&bytes, sc + 8 + reg * 8, u64, s.get(@intCast(reg)));
            put(&bytes, sc + 256, u64, s.get(31));
            put(&bytes, sc + 264, u64, s.pc);
            put(&bytes, sc + 272, u64, (@as(u64, @intFromBool(s.flags.sign)) << 31) | (@as(u64, @intFromBool(s.flags.zero)) << 30) | (@as(u64, @intFromBool(s.flags.carry)) << 29) | (@as(u64, @intFromBool(s.flags.overflow)) << 28));
            put(&bytes, 592, u32, 0x46508001);
            put(&bytes, 596, u32, 528);
            put(&bytes, 600, u32, s.arm_fpsr);
            put(&bytes, 604, u32, s.arm_fpcr);
            for (s.vectors, 0..) |vector, reg| @memcpy(bytes[608 + reg * 16 ..][0..16], &vector);
            put(&bytes, 4688, u64, s.get(29));
            put(&bytes, 4696, u64, s.get(30));
        },
        .riscv64 => {
            put(&bytes, sc, u64, s.pc);
            for (1..32) |reg| put(&bytes, sc + reg * 8, u64, s.get(@intCast(reg)));
            for (s.fp_registers, 0..) |value, reg| put(&bytes, sc + 256 + reg * 8, u64, value);
            put(&bytes, sc + 512, u32, @as(u32, s.fp_flags) | (@as(u32, s.fp_rounding_mode) << 5));
        },
    }
    try m.write(base, bytes[0..length]);
    s.pc = handler;
    s.set(s.stackRegister(), base);
    s.exclusive = null;
    switch (s.architecture) {
        .x86_64 => {
            s.set(0, 0);
            s.set(7, sig);
            s.set(6, base + info_offset);
            s.set(2, base + uc);
            s.flags.direction = false;
            s.x86_fp = .{};
            for (s.vectors[0..16]) |*vector| vector.* = @splat(0);
        },
        .arm64 => {
            s.set(0, sig);
            if (flags & 4 != 0) {
                s.set(1, base);
                s.set(2, base + uc);
            }
            s.set(29, base + 4688);
            s.set(30, restorer);
        },
        .riscv64 => {
            s.set(1, restorer);
            s.set(10, sig);
            s.set(11, base);
            s.set(12, base + uc);
        },
    }
}
/// Honor guest edits to ucontext; publish registers and metadata only after all reads validate.
pub fn restore(s: *State, m: *Memory) !Restored {
    const sp = s.get(s.stackRegister());
    const base = if (s.architecture == .x86_64) std.math.sub(u64, sp, 8) catch return error.InvalidSignalStack else sp;
    if (base % 16 != (if (s.architecture == .x86_64) @as(u64, 8) else 0)) return error.InvalidSignalStack;
    var bytes: [4704]u8 = undefined;
    try m.read(base, bytes[0..size(s.architecture)], .read);
    var next = s.*;
    const sc = contextOffset(s.architecture);
    switch (s.architecture) {
        .x86_64 => {
            if (get(&bytes, sc + 144, u16) != 0x33 or get(&bytes, sc + 150, u16) != 0x2b) return error.InvalidSignalContext;
            for (x86_regs, 0..) |reg, index| next.set(reg, get(&bytes, sc + index * 8, u64));
            next.pc = get(&bytes, sc + 128, u64);
            const flags = get(&bytes, sc + 136, u64);
            next.flags = .{ .carry = flags & 1 != 0, .parity = flags & 4 != 0, .auxiliary = flags & 16 != 0, .zero = flags & 64 != 0, .sign = flags & 128 != 0, .direction = flags & 1024 != 0, .overflow = flags & 2048 != 0 };
            const pointer = get(&bytes, sc + 184, u64);
            if (pointer == 0) {
                next.x86_fp = .{};
                for (next.vectors[0..16]) |*vector| vector.* = @splat(0);
            } else {
                var image: [512]u8 = undefined;
                try m.read(pointer, &image, .read);
                if (get(&image, 464, u32) != 0) return error.UnsupportedSignalExtension;
                try fp.decodeFxsave(&next, &image, 64);
            }
        },
        .arm64 => {
            for (0..31) |reg| next.set(@intCast(reg), get(&bytes, sc + 8 + reg * 8, u64));
            next.set(31, get(&bytes, sc + 256, u64));
            next.pc = get(&bytes, sc + 264, u64);
            const flags = get(&bytes, sc + 272, u64);
            if (flags & ~@as(u64, 0xf0000000) != 0 or next.get(31) % 16 != 0 or next.pc % 4 != 0) return error.InvalidSignalContext;
            next.flags = .{ .sign = flags & 0x80000000 != 0, .zero = flags & 0x40000000 != 0, .carry = flags & 0x20000000 != 0, .overflow = flags & 0x10000000 != 0 };
            if (get(&bytes, 592, u32) != 0x46508001 or get(&bytes, 596, u32) != 528 or get(&bytes, 1120, u64) != 0) return error.UnsupportedSignalExtension;
            next.arm_fpsr = get(&bytes, 600, u32);
            next.arm_fpcr = get(&bytes, 604, u32);
            for (0..32) |reg| @memcpy(&next.vectors[reg], bytes[608 + reg * 16 ..][0..16]);
        },
        .riscv64 => {
            next.pc = get(&bytes, sc, u64);
            for (1..32) |reg| next.set(@intCast(reg), get(&bytes, sc + reg * 8, u64));
            if (next.pc % 2 != 0 or get(&bytes, sc + 772, u32) != 0 or get(&bytes, sc + 776, u64) != 0) return error.UnsupportedSignalExtension;
            for (0..32) |reg| next.fp_registers[reg] = get(&bytes, sc + 256 + reg * 8, u64);
            const fcsr = get(&bytes, sc + 512, u32);
            if (fcsr & ~@as(u32, 255) != 0) return error.InvalidSignalContext;
            next.fp_flags = @truncate(fcsr);
            next.fp_rounding_mode = @truncate(fcsr >> 5);
        },
    }
    const uc = ucOffset(s.architecture);
    var stack: [24]u8 = undefined;
    @memcpy(&stack, bytes[uc + 16 ..][0..24]);
    const flags = get(&stack, 8, u32);
    if (flags & ~@as(u32, 0x80000003) != 0 or flags & 3 == 3) return error.InvalidSignalStack;
    if (flags & 2 != 0) {
        stack = @splat(0);
        put(&stack, 8, u32, 2);
    } else {
        if (get(&stack, 16, u64) < (if (s.architecture == .arm64) @as(u64, 5120) else 2048)) return error.InvalidSignalStack;
        put(&stack, 8, u32, flags & 0x80000000);
        put(&stack, 12, u32, 0);
    }
    try m.check(next.pc, 1, .execute);
    next.exclusive = null;
    s.* = next;
    return .{ .mask = get(&bytes, maskOffset(s.architecture), u64) & ~unblockable, .alternate_stack = stack };
}

test "three Linux signal layouts preserve integer, floating, vector and mask state and honor ucontext edits" {
    for ([_]Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var m = Memory.init(std.testing.allocator);
        defer m.deinit();
        try m.map(0x1000, 4096, .{ .read = true, .execute = true });
        try m.map(0x4000, 32768, .{ .read = true, .write = true });
        var s = State{ .architecture = arch, .pc = 0x1100, .instructions = 99 };
        for (0..32) |reg| s.set(@intCast(reg), 1000 + reg);
        s.set(s.stackRegister(), 0x9000);
        if (arch == .x86_64) s.flags = .{ .carry = true, .auxiliary = true, .zero = true, .sign = true, .parity = true, .direction = true, .overflow = true };
        if (arch == .arm64) s.flags = .{ .carry = true, .zero = true, .sign = true, .overflow = true };
        s.arm_fpcr = 0x400000;
        s.arm_fpsr = 0x8000001;
        s.fp_flags = 21;
        s.fp_rounding_mode = 3;
        s.x86_fp.control = 0x77f;
        s.x86_fp.mxcsr = 0x3f81;
        s.x86_fp.status = 0x1800;
        s.x86_fp.tag = 0xa5;
        for (0..8) |reg| s.x86_fp.registers[reg] = @splat(@intCast(reg + 1));
        for (0..32) |reg| {
            s.vectors[reg] = @splat(@intCast(reg + 1));
            s.fp_registers[reg] = 0xabcdef0000000000 + reg;
        }
        const original = s;
        var action: [32]u8 = @splat(0);
        put(&action, 0, u64, 0x1200);
        put(&action, 8, u64, 0xc000004); // SIGINFO, RESTORER, ONSTACK.
        var stack: [24]u8 = @splat(0);
        put(&stack, 0, u64, 0xa000);
        put(&stack, 16, u64, 8192);
        var info: [128]u8 = @splat(0);
        put(&info, 0, u32, 17);
        put(&info, 8, u32, 1);
        put(&info, 16, u32, 7);
        put(&info, 24, u32, 37);
        try enter(&s, &m, 17, &info, action, 0x42, stack, 0x1300);
        const base = s.get(s.stackRegister());
        try std.testing.expect(base >= 0xa000 and base + size(arch) <= 0xc000);
        try std.testing.expectEqual(@as(u64, 0x1200), s.pc);
        try std.testing.expectEqual(@as(u64, 17), s.get(if (arch == .x86_64) 7 else if (arch == .arm64) 0 else 10));
        const info_address = if (arch == .x86_64) s.get(6) else s.get(if (arch == .arm64) 1 else 11);
        var observed: [128]u8 = undefined;
        try m.read(info_address, &observed, .read);
        try std.testing.expectEqualSlices(u8, &info, &observed);
        const uc_address = if (arch == .x86_64) s.get(2) else s.get(if (arch == .arm64) 2 else 12);
        try std.testing.expectEqual(base + ucOffset(arch), uc_address);
        // Independent fixed offsets from the public ABI, including guest changes.
        const pc_address = base + @as(u64, switch (arch) {
            .x86_64 => 176,
            .arm64 => 568,
            .riscv64 => 304,
        });
        try m.writeInt(pc_address, 64, 0x1104);
        try m.writeInt(base + @as(u64, if (arch == .x86_64) 304 else 168), 64, 0xffff);
        s.instructions = 123;
        if (arch == .x86_64) {
            s.set(4, base + 8); // RET consumed the restorer address.
            s.x86_fp = .{};
            for (s.vectors[0..16]) |*vector| vector.* = @splat(0);
        } else if (arch == .arm64) {
            s.arm_fpcr = 0;
            s.arm_fpsr = 0;
            for (&s.vectors) |*vector| vector.* = @splat(0);
        } else {
            s.fp_registers = @splat(0);
            s.fp_flags = 0;
            s.fp_rounding_mode = 0;
        }
        const result = try restore(&s, &m);
        try std.testing.expectEqual(@as(u64, 0xffff & ~unblockable), result.mask);
        try std.testing.expectEqualSlices(u8, &stack, &result.alternate_stack);
        try std.testing.expectEqual(@as(u64, 0x1104), s.pc);
        try std.testing.expectEqual(@as(u64, 123), s.instructions);
        for (0..32) |reg| try std.testing.expectEqual(original.get(@intCast(reg)), s.get(@intCast(reg)));
        try std.testing.expectEqual(original.flags.bits(), s.flags.bits());
        if (arch == .x86_64) {
            try std.testing.expect(std.meta.eql(original.x86_fp, s.x86_fp));
            try std.testing.expect(std.meta.eql(original.vectors, s.vectors));
        } else if (arch == .arm64) {
            try std.testing.expect(std.meta.eql(original.vectors, s.vectors));
            try std.testing.expectEqual(original.arm_fpcr, s.arm_fpcr);
            try std.testing.expectEqual(original.arm_fpsr, s.arm_fpsr);
        } else {
            try std.testing.expect(std.meta.eql(original.fp_registers, s.fp_registers));
            try std.testing.expectEqual(original.fp_flags, s.fp_flags);
            try std.testing.expectEqual(original.fp_rounding_mode, s.fp_rounding_mode);
        }
    }
}

test "bad signal frames and extensions preserve running registers and failed delivery writes no partial frame" {
    for ([_]Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var m = Memory.init(std.testing.allocator);
        defer m.deinit();
        try m.map(0x1000, 4096, .{ .read = true, .execute = true });
        try m.map(0x4000, 16384, .{ .read = true, .write = true });
        var s = State{ .architecture = arch, .pc = 0x1100 };
        s.set(s.stackRegister(), 0x8000);
        var action: [32]u8 = @splat(0);
        put(&action, 0, u64, 0x1200);
        put(&action, 8, u64, 0x4000004);
        var stack: [24]u8 = @splat(0);
        put(&stack, 8, u32, 2);
        try enter(&s, &m, 17, &@as([128]u8, @splat(0)), action, 0, stack, 0x1300);
        const base = s.get(s.stackRegister());
        if (arch == .x86_64) s.set(4, base + 8);
        const old = s;
        const offset: u64 = switch (arch) {
            .x86_64 => 440 + 464,
            .arm64 => 1120,
            .riscv64 => 1080,
        };
        try m.writeInt(base + offset, 32, 1);
        try std.testing.expectError(error.UnsupportedSignalExtension, restore(&s, &m));
        try std.testing.expect(std.meta.eql(old, s));
        try m.writeInt(base + offset, 32, 0);
        s.set(s.stackRegister(), 0x4008);
        const invalid = s;
        const writes = m.writes;
        try std.testing.expectError(error.UnmappedMemory, enter(&s, &m, 17, &@as([128]u8, @splat(0)), action, 0, stack, 0x1300));
        try std.testing.expect(std.meta.eql(invalid, s));
        try std.testing.expectEqual(writes, m.writes);
    }
}
