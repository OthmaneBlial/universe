const std = @import("std");
const ir = @import("../ir.zig");
const Memory = @import("../memory.zig").Memory;
fn register(n: u32, sp: bool) u6 {
    return if (n == 31 and !sp) 32 else @intCast(n);
}
fn condition(n: u4) ir.Condition {
    return switch (n) {
        0 => .eq,
        1 => .ne,
        2 => .above_equal,
        3 => .below,
        4 => .sign,
        5 => .no_sign,
        6 => .overflow,
        7 => .no_overflow,
        8 => .above,
        9 => .below_equal,
        10 => .ge,
        11 => .lt,
        12 => .gt,
        13 => .le,
        14, 15 => .always,
    };
}
fn shifted(r: u6, kind: u2, amount: u6, width: u7, invert: bool) ir.Operand {
    return .{ .shifted = .{ .index = r, .kind = switch (kind) {
        0 => .lsl,
        1 => .lsr,
        2 => .asr,
        3 => .ror,
    }, .amount = amount, .width = width, .invert = invert } };
}
fn bitmasks(n: u32, imms: u32, immr: u32, immediate: bool) !struct { write: u64, top: u64 } {
    const combined = (n << 6) | ((~imms) & 63);
    if (combined < 2) return error.InvalidInstruction;
    const len: u3 = @intCast(31 - @clz(combined));
    const levels = (@as(u32, 1) << len) - 1;
    const s = imms & levels;
    const r = immr & levels;
    if (immediate and s == levels) return error.InvalidInstruction;
    const width: u7 = @intCast(@as(u32, 1) << len);
    const ones = ir.mask(@intCast(s + 1));
    const top = ir.mask(@intCast(((s -% r) & levels) + 1));
    const pattern = ir.rotate(ones, width, @intCast(r));
    var wm: u64 = 0;
    var tm: u64 = 0;
    var offset: u7 = 0;
    while (offset < 64) : (offset += width) {
        wm |= pattern << @as(u6, @intCast(offset));
        tm |= top << @as(u6, @intCast(offset));
    }
    return .{ .write = wm, .top = tm };
}
pub fn decode(m: *Memory, pc: u64) !ir.Instruction {
    if (pc % 4 != 0) return error.MisalignedInstruction;
    const b: u32 = @intCast(try m.readInt(pc, 32, .execute));
    const w: u7 = if (b >> 31 == 1) 64 else 32;
    const rd = b & 31;
    const rn = (b >> 5) & 31;
    const rm = (b >> 16) & 31;
    var i = ir.Instruction{ .op = .nop, .pc = pc, .next = pc +% 4, .width = w, .set_flags = false, .dst = ir.reg(register(rd, false)), .lhs = ir.reg(register(rn, false)), .src = ir.reg(register(rm, false)) };
    if (b == 0xd503201f) return i;
    if (b == 0xd4000001) {
        i.op = .syscall;
        return i;
    }
    if (b & 0x7c000000 == 0x14000000) {
        i.op = if (b >> 31 == 1) .call else .branch;
        i.dst = ir.reg(30);
        i.src = ir.imm(pc +% @as(u64, @bitCast(ir.signed(b & 0x3ffffff, 26) * 4)));
    } else if (b & 0xff000010 == 0x54000000) {
        i.op = .branch;
        i.lhs = null;
        i.condition = condition(@intCast(b & 15));
        i.src = ir.imm(pc +% @as(u64, @bitCast(ir.signed((b >> 5) & 0x7ffff, 19) * 4)));
    } else if (b & 0x7e000000 == 0x34000000) {
        i.op = .branch;
        i.lhs = ir.reg(register(rd, false));
        i.rhs = ir.imm(0);
        i.condition = if (b & 0x1000000 == 0) .eq else .ne;
        i.src = ir.imm(pc +% @as(u64, @bitCast(ir.signed((b >> 5) & 0x7ffff, 19) * 4)));
    } else if (b & 0x7e000000 == 0x36000000) {
        i.op = .branch;
        i.width = 64;
        i.lhs = .{ .shifted = .{ .index = register(rd, false), .amount = @intCast(((b >> 31) << 5) | ((b >> 19) & 31)), .kind = .lsr, .mask = 1 } };
        i.rhs = ir.imm(0);
        i.condition = if (b & 0x1000000 == 0) .eq else .ne;
        i.src = ir.imm(pc +% @as(u64, @bitCast(ir.signed((b >> 5) & 0x3fff, 14) * 4)));
    } else if (b & 0xfffffc1f == 0xd61f0000 or b & 0xfffffc1f == 0xd63f0000 or b & 0xfffffc1f == 0xd65f0000) {
        i.op = if (b & 0xfffffc1f == 0xd63f0000) .call else .branch;
        i.dst = ir.reg(30);
        i.src = ir.reg(register(rn, false));
        i.lhs = null;
    } else if (b & 0x1f000000 == 0x10000000) {
        const delta = ir.signed((((b >> 5) & 0x7ffff) << 2) | ((b >> 29) & 3), 21);
        i.op = .mov;
        i.width = 64;
        i.src = ir.imm(if (b >> 31 == 1) (pc & ~@as(u64, 4095)) +% @as(u64, @bitCast(delta * 4096)) else pc +% @as(u64, @bitCast(delta)));
    } else if (b & 0x1f800000 == 0x12800000) {
        const opc = (b >> 29) & 3;
        const shift: u6 = @intCast(((b >> 21) & 3) * 16);
        if (w == 32 and shift >= 32) return error.InvalidInstruction;
        const v = @as(u64, (b >> 5) & 0xffff) << shift;
        if (opc == 3) {
            i.op = .bitfield_insert;
            i.src = ir.imm(v);
            i.bit_mask = @as(u64, 0xffff) << shift;
            i.top_mask = i.bit_mask;
        } else if (opc == 0 or opc == 2) {
            i.op = .mov;
            i.src = ir.imm(if (opc == 0) ~v else v);
        } else return error.InvalidInstruction;
    } else if (b & 0x1f000000 == 0x11000000) {
        i.set_flags = b & 0x20000000 != 0;
        i.op = if (b & 0x40000000 != 0) .sub else .add;
        i.dst = ir.reg(register(rd, !i.set_flags));
        i.lhs = ir.reg(register(rn, true));
        i.src = ir.imm(@as(u64, (b >> 10) & 0xfff) << @as(u6, if (b & 0x400000 != 0) 12 else 0));
    } else if (b & 0x1f200000 == 0x0b000000) {
        const kind: u2 = @intCast((b >> 22) & 3);
        const amount: u6 = @intCast((b >> 10) & 63);
        if (kind == 3 or (w == 32 and amount >= 32)) return error.InvalidInstruction;
        i.set_flags = b & 0x20000000 != 0;
        i.op = if (b & 0x40000000 != 0) .sub else .add;
        i.src = shifted(register(rm, false), kind, amount, w, false);
    } else if (b & 0x1f200000 == 0x0a000000) {
        const opc = (b >> 29) & 3;
        const amount: u6 = @intCast((b >> 10) & 63);
        if (w == 32 and amount >= 32) return error.InvalidInstruction;
        i.op = switch (opc) {
            0, 3 => .and_,
            1 => .or_,
            2 => .xor,
            else => unreachable,
        };
        i.set_flags = opc == 3;
        i.src = shifted(register(rm, false), @intCast((b >> 22) & 3), amount, w, b & 0x200000 != 0);
    } else if (b & 0x1f800000 == 0x12000000) {
        const n = (b >> 22) & 1;
        if (w == 32 and n != 0) return error.InvalidInstruction;
        const masks = try bitmasks(n, (b >> 10) & 63, (b >> 16) & 63, true);
        const opc = (b >> 29) & 3;
        i.op = switch (opc) {
            0, 3 => .and_,
            1 => .or_,
            2 => .xor,
            else => unreachable,
        };
        i.set_flags = opc == 3;
        i.dst = ir.reg(register(rd, opc != 3));
        i.src = ir.imm(masks.write);
    } else if (b & 0x1f800000 == 0x13000000) {
        const n = (b >> 22) & 1;
        const r = (b >> 16) & 63;
        const s = (b >> 10) & 63;
        if (n != @intFromBool(w == 64) or r >= w or s >= w) return error.InvalidInstruction;
        const masks = try bitmasks(n, s, r, false);
        i.op = switch ((b >> 29) & 3) {
            0 => .bitfield_signed,
            1 => .bitfield_insert,
            2 => .bitfield_unsigned,
            else => return error.InvalidInstruction,
        };
        i.src = ir.reg(register(rn, false));
        i.rotate = @intCast(r);
        i.sign_bit = @intCast(s);
        i.bit_mask = masks.write;
        i.top_mask = masks.top;
    } else if (b & 0x3a000000 == 0x28000000 and b & 0x04000000 == 0) {
        const opc = b >> 30;
        const load = b & 0x400000 != 0;
        if (opc == 3 or (opc == 1 and !load)) return error.InvalidInstruction;
        i.width = if (opc == 2) 64 else 32;
        i.sign_result = opc == 1;
        i.op = if (load) .load_pair else .store_pair;
        i.src = ir.reg(register((b >> 10) & 31, false));
        const mode = (b >> 23) & 3;
        if (mode == 0) return error.UnsupportedInstruction;
        const delta = ir.signed((b >> 15) & 127, 7) * @as(i64, i.width / 8);
        const base = register(rn, true);
        i.lhs = .{ .mem = .{ .base = base, .displacement = if (mode == 1) 0 else delta } };
        if (mode != 2) {
            i.update_reg = base;
            i.update_delta = delta;
        }
    } else if (b & 0x3b000000 == 0x39000000) {
        const size = b >> 30;
        const opc = (b >> 22) & 3;
        const sw: u7 = @intCast(@as(u32, 8) << @as(u2, @intCast(size)));
        const a = ir.Address{ .base = register(rn, true), .displacement = @as(i64, (b >> 10) & 0xfff) * @as(i64, sw / 8) };
        try loadStore(&i, opc, sw, a);
    } else if (b & 0x3b200000 == 0x38000000) {
        const sw: u7 = @intCast(@as(u32, 8) << @as(u2, @intCast(b >> 30)));
        const mode = (b >> 10) & 3;
        if (mode == 2) return error.UnsupportedInstruction;
        const delta = ir.signed((b >> 12) & 511, 9);
        const base = register(rn, true);
        try loadStore(&i, (b >> 22) & 3, sw, .{ .base = base, .displacement = if (mode == 1) 0 else delta });
        if (mode != 0) {
            i.update_reg = base;
            i.update_delta = delta;
        }
    } else if (b & 0x3b200c00 == 0x38200800) {
        const sw: u7 = @intCast(@as(u32, 8) << @as(u2, @intCast(b >> 30)));
        const option = (b >> 13) & 7;
        if (option != 2 and option != 3 and option != 6 and option != 7) return error.InvalidInstruction;
        try loadStore(&i, (b >> 22) & 3, sw, .{ .base = register(rn, true), .index = register(rm, false), .scale = if (b & 0x1000 != 0) @intCast(b >> 30) else 0, .index_width = if (option == 2 or option == 6) 32 else 64, .index_signed = option >= 6 });
    } else if (b & 0x7fe0fc00 == 0x1ac00800 or b & 0x7fe0fc00 == 0x1ac00c00) {
        i.op = if (b & 0x400 != 0) .divide_signed else .divide_unsigned;
    } else if (b & 0x7fe0f000 == 0x1ac02000) {
        i.op = switch ((b >> 10) & 3) {
            0 => .shl,
            1 => .shr,
            2 => .sar,
            3 => .ror,
            else => unreachable,
        };
    } else if (b & 0x7fe00000 == 0x1b000000) {
        i.op = if (b & 0x8000 != 0) .msub else .madd;
        i.rhs = ir.reg(register((b >> 10) & 31, false));
    } else if (b & 0x1fe00800 == 0x1a800000) {
        i.op = .select;
        i.condition = condition(@intCast((b >> 12) & 15));
        i.false_op = if (b & 0x40000000 != 0) (if (b & 0x400 != 0) .negate else .invert) else (if (b & 0x400 != 0) .inc else .none);
    } else return error.UnsupportedInstruction;
    return i;
}
fn loadStore(i: *ir.Instruction, opc: u32, width: u7, a: ir.Address) !void {
    if (opc == 0) {
        i.op = .mov;
        i.src = i.dst;
        i.dst = .{ .mem = a };
        i.width = width;
    } else if (opc == 1) {
        i.op = .movzx;
        i.source_width = width;
        i.src = .{ .mem = a };
        i.width = if (width == 64) 64 else 32;
    } else {
        if (width == 64 or (width == 32 and opc == 3)) return error.InvalidInstruction;
        i.op = .movsx;
        i.source_width = width;
        i.width = if (opc == 2) 64 else 32;
        i.src = .{ .mem = a };
    }
}
test "AArch64 bitmask and decode validation" {
    const masks = try bitmasks(1, 7, 0, true);
    try std.testing.expectEqual(@as(u64, 255), masks.write);
    try std.testing.expectError(error.InvalidInstruction, bitmasks(1, 63, 0, true));
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.initialize(0x1000, &.{ 0xa8, 0x0b, 0x80, 0xd2 });
    const i = try decode(&m, 0x1000);
    try std.testing.expectEqual(ir.Op.mov, i.op);
    try std.testing.expectEqual(@as(u64, 93), i.src.imm);
}
test "AArch64 decoder fuzz" {
    try std.testing.fuzz({}, fuzz, .{});
}
fn fuzz(_: void, smith: *std.testing.Smith) !void {
    var b: [4]u8 = undefined;
    smith.bytes(&b);
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.initialize(0x1000, &b);
    _ = decode(&m, 0x1000) catch {};
}
