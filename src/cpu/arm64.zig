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
    if (b == 0xd503201f or b & 0xfffff0ff == 0xd50330bf or b & 0xfffff0ff == 0xd503309f or b & 0xfffff0ff == 0xd50330df) return i;
    if (b & 0xfffff0ff == 0xd503305f) {
        i.op = .clear_exclusive;
        return i;
    }
    if (b == 0xd4000001 or b == 0xd4001001) {
        i.op = .syscall;
        i.src = .{ .imm = (b >> 5) & 65535 };
        return i;
    }
    if (b & 0x3fff7c00 == 0x085f7c00) {
        i.op = .load_exclusive;
        i.source_width = @as(u7, 8) << @as(u2, @intCast(b >> 30));
        i.width = if (i.source_width == 64) 64 else 32;
        i.src = .{ .mem = .{ .base = register(rn, true) } };
    } else if (b & 0x3fe07c00 == 0x08007c00) {
        const status_reg = (b >> 16) & 31;
        if (status_reg == rd or (status_reg == rn and rn != 31)) return error.InvalidInstruction;
        i.op = .store_exclusive;
        i.width = @as(u7, 8) << @as(u2, @intCast(b >> 30));
        i.src = ir.reg(register(rd, false));
        i.dst = .{ .mem = .{ .base = register(rn, true) } };
        i.rhs = ir.reg(register(status_reg, false));
    } else if (b & 0x9fe0fc00 == 0x0e201c00 or b & 0x9fe0fc00 == 0x0ea01c00) {
        const bytes: u5 = if (b & 0x40000000 != 0) 16 else 8;
        i.op = if (b & 0x9fe0fc00 == 0x0ea01c00) .vector_or else if (b & 0x20000000 != 0) .vector_xor else .vector_and;
        i.dst = .{ .vector = @intCast(rd) };
        i.lhs = .{ .vector = @intCast(rn) };
        i.src = .{ .vector = @intCast(rm) };
        i.vector_bytes = bytes;
        i.set_flags = false;
    } else if (b & 0x9f20fc00 == 0x0e208c00 or b & 0x9f20fc00 == 0x0e203400) {
        const size = (b >> 22) & 3;
        const bytes: u5 = if (b & 0x40000000 != 0) 16 else 8;
        if (size == 3 and bytes == 8) return error.InvalidInstruction;
        i.op = if (b & 0x9f20fc00 == 0x0e208c00) .vector_compare_equal else .vector_compare_greater_signed;
        i.dst = .{ .vector = @intCast(rd) };
        i.lhs = .{ .vector = @intCast(rn) };
        i.src = .{ .vector = @intCast(rm) };
        i.vector_element = @as(u4, 1) << @as(u2, @intCast(size));
        i.vector_bytes = bytes;
        i.set_flags = false;
    } else if (b & 0x9f20fc00 == 0x0e208400) {
        const size = (b >> 22) & 3;
        const bytes: u5 = if (b & 0x40000000 != 0) 16 else 8;
        if (size == 3 and bytes == 8) return error.InvalidInstruction;
        i.op = if (b & 0x20000000 != 0) .vector_sub else .vector_add;
        i.dst = .{ .vector = @intCast(rd) };
        i.lhs = .{ .vector = @intCast(rn) };
        i.src = .{ .vector = @intCast(rm) };
        i.vector_element = @as(u4, 1) << @as(u2, @intCast(size));
        i.vector_bytes = bytes;
        i.set_flags = false;
    } else if (b & 0xbfe0fc00 == 0x0e003c00 or b & 0xbfe0fc00 == 0x0e002c00) {
        const imm5 = (b >> 16) & 31;
        const size = @ctz(imm5);
        const full = b & 0x40000000 != 0;
        const signed_move = b & 0x1000 == 0;
        if (size > 3 or (signed_move and (size == 3 or (!full and size == 2))) or (!signed_move and full != (size == 3))) return error.InvalidInstruction;
        i.op = .vector_to_scalar;
        i.source_width = @as(u7, 8) << @as(u2, @intCast(size));
        i.width = if (full) 64 else 32;
        i.sign_result = signed_move;
        i.vector_index = @intCast(imm5 >> @as(u5, @intCast(size + 1)));
        i.src = .{ .vector = @intCast(rn) };
    } else if (b & 0xbfe0fc00 == 0x0e000c00) {
        const size = @ctz((b >> 16) & 31);
        const full = b & 0x40000000 != 0;
        if (size > 3 or (size == 3 and !full)) return error.InvalidInstruction;
        i.op = .vector_duplicate;
        i.width = @as(u7, 8) << @as(u2, @intCast(size));
        i.vector_bytes = if (full) 16 else 8;
        i.dst = .{ .vector = @intCast(rd) };
        i.src = ir.reg(register(rn, false));
    } else if (b & 0x9ff80c00 == 0x0f000400) {
        const cmode = (b >> 12) & 15;
        const invert = b & 0x20000000 != 0;
        const immediate = (((b >> 16) & 7) << 5) | ((b >> 5) & 31);
        var lane: u64 = immediate;
        var bits: u7 = 8;
        if (cmode < 8) {
            bits = 32;
            lane <<= @as(u6, @intCast((cmode >> 1) * 8));
        } else if (cmode < 12) {
            bits = 16;
            lane <<= @as(u6, @intCast(((cmode >> 1) & 1) * 8));
        } else if (cmode < 14) {
            bits = 32;
            const shift: u6 = @intCast((cmode - 11) * 8);
            lane = (lane << shift) | ((@as(u64, 1) << shift) - 1);
        } else if (cmode == 14 and invert) {
            bits = 64;
            lane = 0;
            for (0..8) |n| if (immediate & (@as(u32, 1) << @as(u5, @intCast(n))) != 0) {
                lane |= @as(u64, 255) << @as(u6, @intCast(n * 8));
            };
        } else if (cmode == 15) return error.UnsupportedSIMDImmediate;
        var pattern: u64 = 0;
        var offset: u7 = 0;
        while (offset < 64) : (offset += bits) pattern |= lane << @as(u6, @intCast(offset));
        i.op = if (cmode < 12 and cmode & 1 != 0) (if (invert) .vector_and else .vector_or) else .vector_mov;
        if (i.op == .vector_and or i.op == .vector_or) i.lhs = .{ .vector = @intCast(rd) };
        i.dst = .{ .vector = @intCast(rd) };
        i.src = ir.imm(if (invert and cmode < 14) ~pattern else pattern);
        i.vector_bytes = if (b & 0x40000000 != 0) 16 else 8;
    } else if (b & 0xffffffe0 == 0xd53b00e0) {
        i.op = .mov;
        i.width = 64;
        i.src = ir.imm(4); // DC ZVA is permitted, with a 64-byte block.
    } else if (b & 0xffffffe0 == 0xd50b7420) {
        i.op = .zero_block;
        i.src = ir.reg(register(rd, false));
    } else if (b & 0xffffffe0 == 0xd53bd040 or b & 0xffffffe0 == 0xd51bd040) {
        // Virtual register 33 holds guest TPIDR_EL0; it never uses host TLS.
        i.op = .mov;
        i.width = 64;
        if (b & 0x00200000 != 0) i.src = ir.reg(33) else {
            i.dst = ir.reg(33);
            i.src = ir.reg(register(rd, false));
        }
    } else if (b & 0x7c000000 == 0x14000000) {
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
    } else if (b & 0x1fe00000 == 0x0b200000) {
        const option = (b >> 13) & 7;
        const amount: u6 = @intCast((b >> 10) & 7);
        if (amount > 4) return error.InvalidInstruction;
        i.set_flags = b & 0x20000000 != 0;
        i.op = if (b & 0x40000000 != 0) .sub else .add;
        i.dst = ir.reg(register(rd, !i.set_flags));
        i.lhs = ir.reg(register(rn, true));
        i.src = .{ .shifted = .{ .index = register(rm, false), .width = @min(w, @as(u7, 8) << @as(u2, @intCast(option & 3))), .extend_signed = option >= 4, .amount = amount } };
    } else if (b & 0x1f000000 == 0x0a000000) {
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
    } else if (b & 0x3a000000 == 0x28000000) {
        const opc = b >> 30;
        const load = b & 0x400000 != 0;
        const vector = b & 0x04000000 != 0;
        if (opc == 3 or (!vector and opc == 1 and !load)) return error.InvalidInstruction;
        i.width = if (opc == 2) 64 else 32;
        i.sign_result = !vector and opc == 1;
        if (vector) {
            i.op = if (load) .vector_load_pair else .vector_store_pair;
            i.vector_bytes = @as(u5, 4) << @as(u2, @intCast(opc));
            i.dst = .{ .vector = @intCast(rd) };
            i.src = .{ .vector = @intCast((b >> 10) & 31) };
        } else {
            i.op = if (load) .load_pair else .store_pair;
            i.src = ir.reg(register((b >> 10) & 31, false));
        }
        const mode = (b >> 23) & 3;
        if (mode == 0) return error.UnsupportedInstruction;
        const delta = ir.signed((b >> 15) & 127, 7) * @as(i64, if (vector) i.vector_bytes else i.width / 8);
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
        const vector = b & 0x04000000 != 0;
        const bytes: u7 = if (vector and opc & 2 != 0) 16 else sw / 8;
        if (vector) i.dst = .{ .vector = @intCast(rd) };
        const a = ir.Address{ .base = register(rn, true), .displacement = @as(i64, (b >> 10) & 0xfff) * @as(i64, bytes) };
        try loadStore(&i, opc, sw, a);
    } else if (b & 0x3b200000 == 0x38000000) {
        const sw: u7 = @intCast(@as(u32, 8) << @as(u2, @intCast(b >> 30)));
        const mode = (b >> 10) & 3;
        if (mode == 2) return error.UnsupportedInstruction;
        const delta = ir.signed((b >> 12) & 511, 9);
        const base = register(rn, true);
        if (b & 0x04000000 != 0) i.dst = .{ .vector = @intCast(rd) };
        try loadStore(&i, (b >> 22) & 3, sw, .{ .base = base, .displacement = if (mode == 1) 0 else delta });
        if (mode != 0) {
            i.update_reg = base;
            i.update_delta = delta;
        }
    } else if (b & 0x3b200c00 == 0x38200800) {
        const sw: u7 = @intCast(@as(u32, 8) << @as(u2, @intCast(b >> 30)));
        const option = (b >> 13) & 7;
        if (option != 2 and option != 3 and option != 6 and option != 7) return error.InvalidInstruction;
        const vector = b & 0x04000000 != 0;
        const opc = (b >> 22) & 3;
        if (vector) i.dst = .{ .vector = @intCast(rd) };
        try loadStore(&i, opc, sw, .{ .base = register(rn, true), .index = register(rm, false), .scale = if (b & 0x1000 != 0) (if (vector and opc & 2 != 0) 4 else @as(u3, @intCast(b >> 30))) else 0, .index_width = if (option == 2 or option == 6) 32 else 64, .index_signed = option >= 6 });
    } else if (b & 0x7ffffc00 == 0x5ac00000 or b & 0x7ffffc00 == 0x5ac01000) {
        i.op = if (b & 0x1000 != 0) .count_leading_zeros else .bit_reverse;
        i.src = ir.reg(register(rn, false));
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
    } else if (b & 0xff60fc00 == 0x9b407c00) {
        i.op = if (b & 0x00800000 != 0) .mul_high_unsigned else .mul_high_signed;
    } else if (b & 0xff600000 == 0x9b200000) {
        i.op = if (b & 0x8000 != 0) .msub else .madd;
        i.source_width = 32;
        i.multiply_signed = b & 0x00800000 == 0;
        i.rhs = ir.reg(register((b >> 10) & 31, false));
    } else if (b & 0x7fe00000 == 0x1b000000) {
        i.op = if (b & 0x8000 != 0) .msub else .madd;
        i.rhs = ir.reg(register((b >> 10) & 31, false));
    } else if (b & 0x1fe00410 == 0x1a400000) {
        i.op = if (b & 0x40000000 != 0) .conditional_compare_sub else .conditional_compare_add;
        i.condition = condition(@intCast((b >> 12) & 15));
        i.src = if (b & 0x800 != 0) ir.imm(rm) else ir.reg(register(rm, false));
        i.rhs = ir.imm(b & 15);
    } else if (b & 0x1fe00800 == 0x1a800000) {
        i.op = .select;
        i.condition = condition(@intCast((b >> 12) & 15));
        i.false_op = if (b & 0x40000000 != 0) (if (b & 0x400 != 0) .negate else .invert) else (if (b & 0x400 != 0) .inc else .none);
    } else return error.UnsupportedInstruction;
    return i;
}
fn loadStore(i: *ir.Instruction, opc: u32, width: u7, a: ir.Address) !void {
    if (i.dst == .vector) {
        const wide = opc & 2 != 0;
        if (wide and width != 8) return error.InvalidInstruction;
        i.op = if (wide) .vector_mov else .vector_move_low;
        i.width = if (wide) 64 else width;
        if (opc & 1 != 0) i.src = .{ .mem = a } else {
            i.src = i.dst;
            i.dst = .{ .mem = a };
        }
        return;
    }
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

test "NEON 64-bit lanes require the 128-bit arrangement" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    var bytes: [4]u8 = undefined;
    for ([_]u32{ 0x0e208400, 0x0e208c00, 0x0e203400 }) |base| {
        const invalid = base | (3 << 22) | (2 << 16) | (1 << 5) | 3;
        std.mem.writeInt(u32, &bytes, invalid, .little);
        try m.initialize(0x1000, &bytes);
        try std.testing.expectError(error.InvalidInstruction, decode(&m, 0x1000));
    }
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

test "TPIDR_EL0 is independent guest TLS and respects XZR" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    var s = @import("state.zig").State{ .architecture = .arm64 };
    s.set(0, 0x123456789abcdef0);
    s.set(31, 0x5555);
    s.fs_base = 0x7777;
    s.flags = .{ .carry = true, .zero = true };
    const flags = s.flags.bits();
    const words = [_]u32{ 0xd51bd040, 0xd53bd041, 0xd53bd05f, 0xd51bd05f, 0xd53bd042 };
    for (words, 0..) |word, n| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, word, .little);
        try m.initialize(0x1000, &bytes);
        _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000));
        if (n == 1) try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), s.get(1));
    }
    try std.testing.expectEqual(@as(u64, 0), s.get(2));
    try std.testing.expectEqual(@as(u64, 0), s.get(33));
    try std.testing.expectEqual(@as(u64, 0x5555), s.get(31));
    try std.testing.expectEqual(@as(u64, 0x7777), s.fs_base);
    try std.testing.expectEqual(flags, s.flags.bits());
}

test "extended add/sub handles sign, scale, SP and flags; inverted logical decode" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    var s = @import("state.zig").State{ .architecture = .arm64 };
    for ([_]u7{ 32, 64 }) |width| {
        for (0..8) |option| {
            for ([_]u6{ 0, 4 }) |shift| {
                const word: u32 = 0x0b2003e0 | (if (width == 64) @as(u32, 0x80000000) else 0) | (1 << 16) | (@as(u32, @intCast(option)) << 13) | (@as(u32, shift) << 10);
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, word, .little);
                try m.initialize(0x1000, &bytes);
                const instruction = try decode(&m, 0x1000);
                s.set(1, 0x88776655ffffff80);
                s.set(31, 0x1234);
                s.flags = .{ .carry = true, .zero = true };
                const bits = s.flags.bits();
                const sw: u7 = @min(width, @as(u7, 8) << @as(u2, @intCast(option & 3)));
                const raw = s.get(1) & ir.mask(sw);
                const value = if (option >= 4) @as(u64, @bitCast(ir.signed(raw, sw))) else raw;
                _ = try @import("../interpreter.zig").execute(&s, &m, instruction);
                try std.testing.expectEqual((@as(u64, 0x1234) +% (value << shift)) & ir.mask(width), s.get(0));
                try std.testing.expectEqual(bits, s.flags.bits());
            }
        }
    }
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, 0xeb2143ff, .little); // CMP SP, W1, UXTW
    try m.initialize(0x1000, &bytes);
    s.set(31, 5);
    s.set(1, 7);
    _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000));
    try std.testing.expect(!s.flags.carry and s.flags.sign);
    try std.testing.expectEqual(@as(u64, 5), s.get(31));
    std.mem.writeInt(u32, &bytes, 0x8b211400, .little); // Reserved shift amount 5.
    try m.initialize(0x1000, &bytes);
    try std.testing.expectError(error.InvalidInstruction, decode(&m, 0x1000));
    std.mem.writeInt(u32, &bytes, 0x8a220020, .little); // BIC X0, X1, X2
    try m.initialize(0x1000, &bytes);
    s.set(1, 0xff);
    s.set(2, 0x0f);
    _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u64, 0xf0), s.get(0));
}

test "SIMD immediates, general DUP, all vector registers and checked pair writeback" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.map(0x2000, 4096, .{ .read = true, .write = true });
    var s = @import("state.zig").State{ .architecture = .arm64 };
    s.set(1, 0x123456789abcdef0);
    s.set(31, 0x7777);
    s.flags = .{ .carry = true, .zero = true, .overflow = true };
    const flags = s.flags.bits();
    const cases = [_]struct { word: u32, reg: u5, initial: u64 = 0, low: u64, high: ?u64 = null }{
        .{ .word = 0x4f05e55f, .reg = 31, .low = 0xaaaaaaaaaaaaaaaa }, // MOVI .16B
        .{ .word = 0x0f05e55f, .reg = 31, .low = 0xaaaaaaaaaaaaaaaa, .high = 0 }, // MOVI .8B
        .{ .word = 0x4f004641, .reg = 1, .low = 0x0012000000120000 }, // MOVI .4S, LSL 16
        .{ .word = 0x6f01a442, .reg = 2, .low = 0xddffddffddffddff }, // MVNI .8H, LSL 8
        .{ .word = 0x6f05e543, .reg = 3, .low = 0xff00ff00ff00ff00 }, // MOVI .2D bitmap
        .{ .word = 0x4f00c643, .reg = 3, .low = 0x000012ff000012ff }, // MOVI .4S, MSL 8
        .{ .word = 0x4f003644, .reg = 4, .initial = 0xaa000000aa000000, .low = 0xaa001200aa001200 }, // ORR immediate
        .{ .word = 0x6f019445, .reg = 5, .initial = 0xffffffffffffffff, .low = 0xffddffddffddffdd }, // BIC immediate
        .{ .word = 0x4e010c3f, .reg = 31, .low = 0xf0f0f0f0f0f0f0f0 }, // DUP .16B
        .{ .word = 0x0e020c3e, .reg = 30, .low = 0xdef0def0def0def0, .high = 0 }, // DUP .4H
    };
    for (cases) |case| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, case.word, .little);
        try m.initialize(0x1000, &bytes);
        std.mem.writeInt(u64, s.vectors[case.reg][0..8], case.initial, .little);
        std.mem.writeInt(u64, s.vectors[case.reg][8..16], case.initial, .little);
        _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000));
        try std.testing.expectEqual(case.low, std.mem.readInt(u64, s.vectors[case.reg][0..8], .little));
        try std.testing.expectEqual(case.high orelse case.low, std.mem.readInt(u64, s.vectors[case.reg][8..16], .little));
        try std.testing.expectEqual(flags, s.flags.bits());
    }
    s.vectors[30] = @splat(0xaa);
    s.vectors[31] = @splat(0xbb);
    s.set(0, 0x2003); // Vector memory accesses can be unaligned.
    try m.initialize(0x2003, &.{ 1, 2, 3, 4 });
    for ([_]u32{ 0x3d80041f, 0x3dc0041e, 0xbd40001f, 0xad817c1e, 0xacc1741c }) |word| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, word, .little);
        try m.initialize(0x1000, &bytes);
        _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000));
    }
    try std.testing.expectEqual(@as(u64, 0x2043), s.get(0));
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xbb)), &s.vectors[28]);
    try std.testing.expectEqual(@as(u64, 0x04030201), std.mem.readInt(u64, s.vectors[29][0..8], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, s.vectors[29][8..16], .little));
    try std.testing.expectEqual(@as(u64, 0x7777), s.get(31));
    try std.testing.expectEqual(@as(u64, 0), s.get(28));
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, 0xad817c1e, .little);
    try m.initialize(0x1000, &bytes);
    try m.initialize(0x2ff8, &@as([8]u8, @splat(0xa5)));
    s.set(0, 0x2fd8);
    try std.testing.expectError(error.UnmappedMemory, @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000)));
    try std.testing.expectEqual(@as(u64, 0x2fd8), s.get(0));
    try std.testing.expectEqual(@as(u64, 0xa5a5a5a5a5a5a5a5), try m.readInt(0x2ff8, 64, .read));
    std.mem.writeInt(u32, &bytes, 0xacc1741c, .little);
    try m.initialize(0x1000, &bytes);
    s.set(0, 0x2ff8);
    const before = s.vectors;
    try std.testing.expectError(error.UnmappedMemory, @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000)));
    try std.testing.expectEqual(@as(u64, 0x2ff8), s.get(0));
    try std.testing.expectEqualDeep(before, s.vectors);
}

test "signed and unsigned multiply long and high halves" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    var s = @import("state.zig").State{ .architecture = .arm64 };
    s.set(1, 0xfffffffd);
    s.set(2, 4);
    s.set(3, 10);
    const cases = [_]struct { word: u32, expected: u64 }{
        .{ .word = 0x9b220c20, .expected = @bitCast(@as(i64, -2)) }, // SMADDL X0,W1,W2,X3
        .{ .word = 0x9b228c20, .expected = 22 }, // SMSUBL
        .{ .word = 0x9ba20c20, .expected = 17179869182 }, // UMADDL
        .{ .word = 0x9ba28c20, .expected = @as(u64, 10) -% 17179869172 }, // UMSUBL
    };
    for (cases) |case| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, case.word, .little);
        try m.initialize(0x1000, &bytes);
        _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000));
        try std.testing.expectEqual(case.expected, s.get(0));
    }
    s.set(1, 0xffffffffffffffff);
    s.set(2, 2);
    for ([_]u32{ 0x9b427c20, 0x9bc27c20 }, [_]u64{ 0xffffffffffffffff, 1 }) |word, expected| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, word, .little);
        try m.initialize(0x1000, &bytes);
        _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000));
        try std.testing.expectEqual(expected, s.get(0));
    }
}

test "DCZID describes checked, aligned 64-byte DC ZVA blocks" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.map(0x2000, 4096, .{ .read = true, .write = true });
    var s = @import("state.zig").State{ .architecture = .arm64 };
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, 0xd53b00e5, .little);
    try m.initialize(0x1000, &bytes);
    _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u64, 4), s.get(5));
    std.mem.writeInt(u32, &bytes, 0xd50b7423, .little);
    try m.initialize(0x1000, &bytes);
    try m.initialize(0x2040, &@as([80]u8, @splat(0xaa)));
    s.set(3, 0x207f);
    const instruction = try decode(&m, 0x1000);
    _ = try @import("../interpreter.zig").execute(&s, &m, instruction);
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x2040, 64, .read));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x2078, 64, .read));
    try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try m.readInt(0x2080, 64, .read));
    try std.testing.expectEqual(@as(u64, 0x207f), s.get(3));
    try m.protect(0x2000, 4096, .{ .read = true });
    try std.testing.expectError(error.PermissionDenied, @import("../interpreter.zig").execute(&s, &m, instruction));
    s.set(3, 0x3000);
    try std.testing.expectError(error.UnmappedMemory, @import("../interpreter.zig").execute(&s, &m, instruction));
}

test "RBIT and CLZ use operand width and leave flags unchanged" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    var s = @import("state.zig").State{ .architecture = .arm64 };
    s.flags = .{ .carry = true, .zero = true, .overflow = true };
    const flags = s.flags.bits();
    const cases = [_]struct { word: u32, value: u64, expected: u64 }{
        .{ .word = 0x5ac00020, .value = 0x0123456789abcdef, .expected = 0xf7b3d591 },
        .{ .word = 0xdac00020, .value = 0x0123456789abcdef, .expected = 0xf7b3d591e6a2c480 },
        .{ .word = 0x5ac01020, .value = 0xffff000000000010, .expected = 27 },
        .{ .word = 0xdac01020, .value = 0x10, .expected = 59 },
        .{ .word = 0x5ac01020, .value = 0, .expected = 32 },
        .{ .word = 0xdac01020, .value = 0, .expected = 64 },
    };
    for (cases) |case| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, case.word, .little);
        try m.initialize(0x1000, &bytes);
        s.set(1, case.value);
        _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000));
        try std.testing.expectEqual(case.expected, s.get(0));
        try std.testing.expectEqual(flags, s.flags.bits());
    }
}

test "exclusive stores succeed once, fail after interference and validate alignment" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.map(0x2000, 4096, .{ .read = true, .write = true });
    const words = [_]u32{ 0x885ffc20, 0x8803fc22, 0xc85f7c20, 0xc8037c22, 0x085ffc20, 0x0803fc22, 0xd5033f5f, 0xd5033bbf };
    for (words, 0..) |word, n| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, word, .little);
        try m.initialize(0x1000 + n * 4, &bytes);
    }
    var s = @import("state.zig").State{ .architecture = .arm64 };
    s.set(1, 0x2000);
    s.set(2, 0x123456789abcdef0);
    const load = try decode(&m, 0x1000);
    const store = try decode(&m, 0x1004);
    try m.writeInt(0x2000, 64, 7);
    _ = try @import("../interpreter.zig").execute(&s, &m, load);
    try std.testing.expectEqual(@as(u64, 7), s.get(0));
    _ = try @import("../interpreter.zig").execute(&s, &m, store);
    try std.testing.expectEqual(@as(u64, 0), s.get(3));
    try std.testing.expectEqual(@as(u64, 0x9abcdef0), try m.readInt(0x2000, 64, .read));
    _ = try @import("../interpreter.zig").execute(&s, &m, store);
    try std.testing.expectEqual(@as(u64, 1), s.get(3));
    _ = try @import("../interpreter.zig").execute(&s, &m, load);
    try m.writeInt(0x2000, 32, 9);
    _ = try @import("../interpreter.zig").execute(&s, &m, store);
    try std.testing.expectEqual(@as(u64, 1), s.get(3));
    try std.testing.expectEqual(@as(u64, 9), try m.readInt(0x2000, 32, .read));
    _ = try @import("../interpreter.zig").execute(&s, &m, load);
    _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1018)); // CLREX
    _ = try @import("../interpreter.zig").execute(&s, &m, store);
    try std.testing.expectEqual(@as(u64, 1), s.get(3));
    _ = try @import("../interpreter.zig").execute(&s, &m, load);
    try m.replace(0x2000, 4096, .{ .read = true, .write = true });
    _ = try @import("../interpreter.zig").execute(&s, &m, store);
    try std.testing.expectEqual(@as(u64, 1), s.get(3));
    _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1008)); // LDXR X0
    _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x101c)); // DMB
    _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x100c)); // STXR X2
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), try m.readInt(0x2000, 64, .read));
    s.set(0, 0xffffffffffffffff);
    _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1010)); // LDAXRB W0
    try std.testing.expectEqual(@as(u64, 0xf0), s.get(0));
    s.set(2, 0xaa);
    _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1014)); // STLXRB W2
    try std.testing.expectEqual(@as(u64, 0x123456789abcdeaa), try m.readInt(0x2000, 64, .read));
    s.set(1, 0x2001);
    try std.testing.expectError(error.MisalignedMemory, @import("../interpreter.zig").execute(&s, &m, load));
    try std.testing.expectError(error.MisalignedMemory, @import("../interpreter.zig").execute(&s, &m, store));
    s.set(1, 0x3000);
    try std.testing.expectError(error.UnmappedMemory, @import("../interpreter.zig").execute(&s, &m, load));
    s.set(1, 0x2000);
    try m.protect(0x2000, 4096, .{ .read = true });
    _ = try @import("../interpreter.zig").execute(&s, &m, load);
    s.set(3, 99);
    try std.testing.expectError(error.PermissionDenied, @import("../interpreter.zig").execute(&s, &m, store));
    try std.testing.expectEqual(@as(u64, 99), s.get(3));
}

test "UMOV and SMOV select lanes, extend correctly and keep XZR separate" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    var s = @import("state.zig").State{ .architecture = .arm64 };
    s.vectors[31][0] = 0x80;
    s.vectors[31][1] = 0x7f;
    s.vectors[31][14] = 0xfe;
    s.vectors[31][15] = 0xff;
    const cases = [_]struct { word: u32, expected: u64 }{
        .{ .word = 0x4e183fe0, .expected = 0xfffe000000000000 }, // UMOV X0,V31.D[1]
        .{ .word = 0x0e033fe0, .expected = 0x7f }, // UMOV W0,V31.B[1]
        .{ .word = 0x0e1e2fe0, .expected = 0xfffffffe }, // SMOV W0,V31.H[7]
        .{ .word = 0x4e012fe0, .expected = 0xffffffffffffff80 }, // SMOV X0,V31.B[0]
    };
    for (cases) |case| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, case.word, .little);
        try m.initialize(0x1000, &bytes);
        s.set(0, 0xffffffffffffffff);
        _ = try @import("../interpreter.zig").execute(&s, &m, try decode(&m, 0x1000));
        try std.testing.expectEqual(case.expected, s.get(0));
    }
}
