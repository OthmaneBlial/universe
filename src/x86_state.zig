//! Checked legacy floating-point state images and MXCSR controls.
const std = @import("std");
const State = @import("cpu/state.zig").State;
const Memory = @import("memory.zig").Memory;
const ir = @import("ir.zig");
const address = @import("operands.zig").address;

fn checkMxcsr(value: u32) !void {
    if (value & ~@as(u32, 0xffff) != 0) return error.InvalidFloatingPointControl;
}

/// Legacy 64-bit signal frames and FXSAVE share the same checked FP/SSE image.
pub fn encodeFxsave(s: *const State, width: u7) [512]u8 {
    var bytes: [512]u8 = @splat(0);
    const fp = s.x86_fp;
    std.mem.writeInt(u16, bytes[0..2], fp.control, .little);
    std.mem.writeInt(u16, bytes[2..4], fp.status, .little);
    bytes[4] = fp.tag;
    std.mem.writeInt(u16, bytes[6..8], fp.opcode, .little);
    if (width == 64) {
        std.mem.writeInt(u64, bytes[8..16], fp.instruction_pointer, .little);
        std.mem.writeInt(u64, bytes[16..24], fp.data_pointer, .little);
    } else {
        std.mem.writeInt(u32, bytes[8..12], @truncate(fp.instruction_pointer), .little);
        std.mem.writeInt(u16, bytes[12..14], fp.code_selector, .little);
        std.mem.writeInt(u32, bytes[16..20], @truncate(fp.data_pointer), .little);
        std.mem.writeInt(u16, bytes[20..22], fp.data_selector, .little);
    }
    std.mem.writeInt(u32, bytes[24..28], fp.mxcsr, .little);
    std.mem.writeInt(u32, bytes[28..32], 0xffff, .little);
    const top: usize = (fp.status >> 11) & 7;
    for (0..8) |slot| @memcpy(bytes[32 + slot * 16 ..][0..10], &fp.registers[(top + slot) & 7]);
    for (0..16) |slot| @memcpy(bytes[160 + slot * 16 ..][0..16], &s.vectors[slot]);
    return bytes;
}
pub fn decodeFxsave(s: *State, bytes: *const [512]u8, width: u7) !void {
    const mxcsr = std.mem.readInt(u32, bytes[24..28], .little);
    try checkMxcsr(mxcsr);
    var fp = s.x86_fp;
    fp.control = (std.mem.readInt(u16, bytes[0..2], .little) & 0x1f3f) | 0x40;
    fp.status = std.mem.readInt(u16, bytes[2..4], .little);
    fp.tag = bytes[4];
    fp.opcode = std.mem.readInt(u16, bytes[6..8], .little) & 0x7ff;
    if (width == 64) {
        fp.instruction_pointer = std.mem.readInt(u64, bytes[8..16], .little);
        fp.data_pointer = std.mem.readInt(u64, bytes[16..24], .little);
    } else {
        fp.instruction_pointer = std.mem.readInt(u32, bytes[8..12], .little);
        fp.code_selector = std.mem.readInt(u16, bytes[12..14], .little);
        fp.data_pointer = std.mem.readInt(u32, bytes[16..20], .little);
        fp.data_selector = std.mem.readInt(u16, bytes[20..22], .little);
    }
    fp.mxcsr = mxcsr;
    const top: usize = (fp.status >> 11) & 7;
    for (0..8) |slot| @memcpy(&fp.registers[(top + slot) & 7], bytes[32 + slot * 16 ..][0..10]);
    for (0..16) |slot| @memcpy(&s.vectors[slot], bytes[160 + slot * 16 ..][0..16]);
    s.x86_fp = fp;
}
pub fn execute(s: *State, m: *Memory, i: ir.Instruction) !void {
    const addr = address(s, i.src.mem, i.next);
    if (i.op == .ldmxcsr) {
        const value: u32 = @truncate(try m.readInt(addr, 32, .read));
        try checkMxcsr(value);
        s.x86_fp.mxcsr = value;
        return;
    }
    if (i.op == .stmxcsr) {
        try m.writeInt(addr, 32, s.x86_fp.mxcsr);
        return;
    }
    if (addr % 16 != 0) return error.MisalignedMemory;
    if (i.op == .fxsave) {
        const bytes = encodeFxsave(s, i.width);
        // Preserve the software-owned tail and unused reserved bytes.
        try m.write(addr, bytes[0..416]);
    } else {
        var bytes: [512]u8 = undefined;
        try m.read(addr, &bytes, .read);
        try decodeFxsave(s, &bytes, i.width);
    }
}

test "FXSAVE and FXRSTOR preserve logical x87 slots, all XMM registers and both pointer layouts" {
    const decoder = @import("cpu/x86_64.zig").decode;
    const interpreter = @import("interpreter.zig");
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    for ([_]u7{ 32, 64 }) |width| {
        var s = State{ .architecture = .x86_64 };
        s.set(7, 0x1200);
        s.flags = .{ .carry = true, .zero = true, .overflow = true };
        s.x86_fp = .{ .control = 0x77f, .status = 0x1800, .tag = 0xa5, .opcode = 0x357, .instruction_pointer = 0xabcdef0123456789, .data_pointer = 0xfedcba9876543210, .code_selector = 0x33, .data_selector = 0x2b, .mxcsr = 0xff7f };
        for (0..8) |reg| s.x86_fp.registers[reg] = @splat(@intCast(reg + 1));
        for (0..32) |reg| s.vectors[reg] = @splat(@intCast(reg + 0x10));
        const original = s;
        try m.write(0x1200, &@as([512]u8, @splat(0xa5)));
        const encoded: []const u8 = if (width == 64) &.{ 0x48, 0x0f, 0xae, 0x07, 0x48, 0x0f, 0xae, 0x0f } else &.{ 0x0f, 0xae, 0x07, 0x0f, 0xae, 0x0f };
        try m.initialize(0x1000, encoded);
        const save = try decoder(&m, 0x1000);
        _ = try interpreter.execute(&s, &m, save);
        try std.testing.expect(std.meta.eql(original.x86_fp, s.x86_fp));
        try std.testing.expectEqual(original.flags.bits(), s.flags.bits());
        var image: [512]u8 = undefined;
        try m.read(0x1200, &image, .read);
        try std.testing.expectEqual(@as(u16, 0x77f), std.mem.readInt(u16, image[0..2], .little));
        try std.testing.expectEqual(@as(u8, 0xa5), image[4]);
        try std.testing.expectEqual(@as(u32, 0xffff), std.mem.readInt(u32, image[28..32], .little));
        for (0..8) |slot| try std.testing.expectEqualSlices(u8, &original.x86_fp.registers[(slot + 3) & 7], image[32 + slot * 16 ..][0..10]);
        for (0..16) |reg| try std.testing.expectEqualSlices(u8, &original.vectors[reg], image[160 + reg * 16 ..][0..16]);
        try std.testing.expectEqualSlices(u8, &@as([96]u8, @splat(0xa5)), image[416..512]);
        s.x86_fp = .{};
        for (0..16) |reg| s.vectors[reg] = @splat(0);
        _ = try interpreter.execute(&s, &m, try decoder(&m, save.next));
        var expected = original.x86_fp;
        if (width == 32) {
            expected.instruction_pointer &= 0xffffffff;
            expected.data_pointer &= 0xffffffff;
        } else {
            expected.code_selector = 0;
            expected.data_selector = 0;
        }
        try std.testing.expect(std.meta.eql(expected, s.x86_fp));
        try std.testing.expect(std.meta.eql(original.vectors, s.vectors));
        try std.testing.expectEqual(original.flags.bits(), s.flags.bits());
    }
}

test "Floating-point state faults are atomic and reserved MXCSR bits fail explicitly" {
    const decoder = @import("cpu/x86_64.zig").decode;
    const interpreter = @import("interpreter.zig");
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.map(0x2000, 4096, .{ .read = true, .write = true });
    try m.map(0x3000, 4096, .{ .read = true });
    try m.initialize(0x1000, &.{ 0x48, 0x0f, 0xae, 0x0f });
    var s = State{ .architecture = .x86_64 };
    s.set(7, 0x2200);
    s.vectors[0] = @splat(0xab);
    s.flags.carry = true;
    const original = s;
    for ([_]u32{ 0x80001f80, 0x11f80 }) |value| {
        try m.writeInt(0x2218, 32, value);
        try std.testing.expectError(error.InvalidFloatingPointControl, interpreter.execute(&s, &m, try decoder(&m, 0x1000)));
        try std.testing.expect(std.meta.eql(original, s));
    }
    s.set(7, 0x3f00);
    const unreadable = s;
    try std.testing.expectError(error.UnmappedMemory, interpreter.execute(&s, &m, try decoder(&m, 0x1000)));
    try std.testing.expect(std.meta.eql(unreadable, s));
    try m.initialize(0x1000, &.{ 0x48, 0x0f, 0xae, 0x07 });
    s.set(7, 0x2f00);
    const writes = m.writes;
    try std.testing.expectError(error.PermissionDenied, interpreter.execute(&s, &m, try decoder(&m, 0x1000)));
    try std.testing.expectEqual(writes, m.writes);
    s.set(7, 0x2201);
    try std.testing.expectError(error.MisalignedMemory, interpreter.execute(&s, &m, try decoder(&m, 0x1000)));
    // MXCSR transfers allow unaligned addresses and exactly four bytes at a page end.
    try m.initialize(0x1000, &.{ 0x0f, 0xae, 0x17, 0x0f, 0xae, 0x1f });
    for ([_]u64{ 0x2503, 0x2ffc }) |addr| {
        try m.writeInt(addr, 32, 0x1f81);
        s.set(7, addr);
        const load = try decoder(&m, 0x1000);
        _ = try interpreter.execute(&s, &m, load);
        try std.testing.expectEqual(@as(u32, 0x1f81), s.x86_fp.mxcsr);
        _ = try interpreter.execute(&s, &m, try decoder(&m, load.next));
        try std.testing.expectEqual(@as(u64, 0x1f81), try m.readInt(addr, 32, .read));
    }
    try m.initialize(0x1000, &.{ 0x0f, 0xae, 0xd0 });
    try std.testing.expectError(error.UnsupportedInstruction, decoder(&m, 0x1000));
}
