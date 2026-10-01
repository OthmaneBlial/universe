const std = @import("std");
const ir = @import("../ir.zig");
const Memory = @import("../memory.zig").Memory;
const CpuState = @import("state.zig").State;
fn sx(v: u32, bits: u7) u64 {
    return @bitCast(ir.signed(v, bits));
}
pub fn decode(m: *Memory, pc: u64) !ir.Instruction {
    if (pc % 2 != 0) return error.MisalignedInstruction;
    const half: u16 = @intCast(try m.readInt(pc, 16, .execute));
    if (half & 3 != 3) return word(try expand(half), pc, pc +% 2);
    if (half & 31 == 31) return error.UnsupportedInstruction;
    const b: u32 = @intCast(try m.readInt(pc, 32, .execute));
    return word(b, pc, pc +% 4);
}
// RVC integer operations expand to the existing RV64 decoder, retaining PC+2.
fn immediate(op: u32, rd: u32, rs1: u32, value: u32) u32 {
    return op | (rd << 7) | (rs1 << 15) | ((value & 4095) << 20);
}
fn registers(op: u32, rd: u32, rs1: u32, rs2: u32) u32 {
    return op | (rd << 7) | (rs1 << 15) | (rs2 << 20);
}
fn store(op: u32, rs1: u32, rs2: u32, offset: u32) u32 {
    return op | ((offset & 31) << 7) | (rs1 << 15) | (rs2 << 20) | ((offset >> 5) << 25);
}
fn expand(half: u16) !u32 {
    const b: u32 = half;
    const f = b >> 13;
    const rd = (b >> 7) & 31;
    const rs2 = (b >> 2) & 31;
    const r1 = 8 + ((b >> 7) & 7);
    const r2 = 8 + ((b >> 2) & 7);
    const six = ((b >> 7) & 32) | ((b >> 2) & 31);
    const signed_six: u32 = @truncate(sx(six, 6));
    switch (b & 3) {
        0 => switch (f) {
            0 => {
                const offset = ((b >> 7) & 15) << 6 | ((b >> 11) & 3) << 4 | ((b >> 5) & 1) << 3 | ((b >> 6) & 1) << 2;
                if (offset == 0) return error.InvalidInstruction;
                return immediate(0x13, r2, 2, offset);
            },
            1, 2, 3, 5, 6, 7 => {
                const offset = ((b >> 10) & 7) << 3 | (if (f & 1 != 0) ((b >> 5) & 3) << 6 else ((b >> 5) & 1) << 6 | ((b >> 6) & 1) << 2);
                if (f == 1) return immediate(0x3007, r2, r1, offset); // C.FLD
                if (f == 5) return store(0x3027, r1, r2, offset); // C.FSD
                const op = (f & 3) << 12;
                return if (f < 4) immediate(op | 3, r2, r1, offset) else store(op | 0x23, r1, r2, offset);
            },
            else => return error.InvalidInstruction,
        },
        1 => switch (f) {
            0 => return immediate(0x13, rd, rd, signed_six),
            1 => {
                if (rd == 0) return error.InvalidInstruction;
                return immediate(0x1b, rd, rd, signed_six);
            },
            2 => return immediate(0x13, rd, 0, signed_six),
            3 => {
                if (rd == 2) {
                    const offset = ((b >> 12) & 1) << 9 | ((b >> 6) & 1) << 4 | ((b >> 5) & 1) << 6 | ((b >> 3) & 3) << 7 | ((b >> 2) & 1) << 5;
                    if (offset == 0) return error.InvalidInstruction;
                    return immediate(0x13, 2, 2, @truncate(sx(offset, 10)));
                }
                if (six == 0) return error.InvalidInstruction;
                return 0x37 | (rd << 7) | (signed_six << 12);
            },
            4 => {
                const kind = (b >> 10) & 3;
                if (kind < 2) return immediate(0x5013, r1, r1, six | (if (kind == 1) @as(u32, 0x400) else 0));
                if (kind == 2) return immediate(0x7013, r1, r1, signed_six);
                const sub = (b >> 5) & 3;
                const op: u32 = if (b & 4096 == 0) switch (sub) {
                    0 => 0x40000033,
                    1 => 0x4033,
                    2 => 0x6033,
                    3 => 0x7033,
                    else => unreachable,
                } else switch (sub) {
                    0 => 0x4000003b,
                    1 => 0x3b,
                    else => return error.InvalidInstruction,
                };
                return registers(op, r1, r1, r2);
            },
            5 => {
                const offset: u32 = @truncate(sx(((b >> 12) & 1) << 11 | ((b >> 11) & 1) << 4 | ((b >> 9) & 3) << 8 | ((b >> 8) & 1) << 10 | ((b >> 7) & 1) << 6 | ((b >> 6) & 1) << 7 | ((b >> 3) & 7) << 1 | ((b >> 2) & 1) << 5, 12));
                return 0x6f | ((offset & 0x100000) << 11) | ((offset & 0x7fe) << 20) | ((offset & 0x800) << 9) | (offset & 0xff000);
            },
            6, 7 => {
                const offset: u32 = @truncate(sx(((b >> 12) & 1) << 8 | ((b >> 10) & 3) << 3 | ((b >> 5) & 3) << 6 | ((b >> 3) & 3) << 1 | ((b >> 2) & 1) << 5, 9));
                return 0x63 | ((f - 6) << 12) | (r1 << 15) | ((offset & 0x1000) << 19) | ((offset & 0x7e0) << 20) | ((offset & 0x1e) << 7) | ((offset & 0x800) >> 4);
            },
            else => unreachable,
        },
        2 => switch (f) {
            0 => return immediate(0x1013, rd, rd, six),
            1, 2, 3 => {
                if (rd == 0 and f != 1) return error.InvalidInstruction;
                const offset = ((b >> 12) & 1) << 5 | (if (f == 2) ((b >> 4) & 7) << 2 | ((b >> 2) & 3) << 6 else ((b >> 5) & 3) << 3 | ((b >> 2) & 7) << 6);
                if (f == 1) return immediate(0x3007, rd, 2, offset); // C.FLDSP
                return immediate(3 | (f << 12), rd, 2, offset);
            },
            5 => {
                const offset = ((b >> 12) & 1) << 5 | ((b >> 10) & 3) << 3 | ((b >> 7) & 7) << 6;
                return store(0x3027, 2, rs2, offset); // C.FSDSP
            },
            4 => {
                if (rs2 != 0) return registers(0x33, rd, if (b & 4096 != 0) rd else 0, rs2);
                if (rd == 0) return if (b & 4096 != 0) @as(u32, 0x100073) else error.InvalidInstruction;
                return immediate(0x67, if (b & 4096 != 0) 1 else 0, rd, 0);
            },
            6, 7 => {
                const offset = if (f == 6) ((b >> 9) & 15) << 2 | ((b >> 7) & 3) << 6 else ((b >> 10) & 7) << 3 | ((b >> 7) & 7) << 6;
                return store(0x23 | ((f & 3) << 12), 2, rs2, offset);
            },
            else => return error.InvalidInstruction,
        },
        else => unreachable,
    }
}
fn word(b: u32, pc: u64, next: u64) !ir.Instruction {
    const opcode = b & 127;
    const rd: u6 = @intCast((b >> 7) & 31);
    const rs1: u6 = @intCast((b >> 15) & 31);
    const rs2: u6 = @intCast((b >> 20) & 31);
    const f3: u3 = @intCast((b >> 12) & 7);
    const f7 = b >> 25;
    var i = ir.Instruction{ .op = .nop, .pc = pc, .next = next, .set_flags = false, .dst = ir.reg(rd), .lhs = ir.reg(rs1), .src = ir.reg(rs2) };
    switch (opcode) {
        0x37 => {
            i.op = .mov;
            i.src = ir.imm(sx(b & 0xfffff000, 32));
        },
        0x17 => {
            i.op = .mov;
            i.src = ir.imm(pc +% sx(b & 0xfffff000, 32));
        },
        0x6f => {
            const d = ((b >> 31) << 20) | (((b >> 12) & 255) << 12) | (((b >> 20) & 1) << 11) | (((b >> 21) & 1023) << 1);
            i.op = .call;
            i.src = ir.imm(pc +% sx(d, 21));
        },
        0x67 => {
            if (f3 != 0) return error.InvalidInstruction;
            i.op = .call;
            i.src = .{ .address = .{ .base = rs1, .displacement = ir.signed(b >> 20, 12) } };
            i.target_mask = ~@as(u64, 1);
        },
        0x63 => {
            const d = ((b >> 31) << 12) | (((b >> 7) & 1) << 11) | (((b >> 25) & 63) << 5) | (((b >> 8) & 15) << 1);
            i.op = .branch;
            i.src = ir.imm(pc +% sx(d, 13));
            i.rhs = ir.reg(rs2);
            i.condition = switch (f3) {
                0 => .eq,
                1 => .ne,
                4 => .lt,
                5 => .ge,
                6 => .below,
                7 => .above_equal,
                else => return error.InvalidInstruction,
            };
        },
        0x07, 0x27 => {
            if (f3 != 2 and f3 != 3) return error.UnsupportedInstruction;
            i.op = .riscv_fp;
            i.encoding = b;
        },
        0x03 => {
            const width: u7 = switch (f3) {
                0, 4 => 8,
                1, 5 => 16,
                2, 6 => 32,
                3 => 64,
                else => return error.InvalidInstruction,
            };
            i.op = if (f3 < 3) .movsx else .movzx;
            i.source_width = width;
            i.src = .{ .mem = .{ .base = rs1, .displacement = ir.signed(b >> 20, 12) } };
        },
        0x23 => {
            i.op = .mov;
            i.width = switch (f3) {
                0 => 8,
                1 => 16,
                2 => 32,
                3 => 64,
                else => return error.InvalidInstruction,
            };
            i.dst = .{ .mem = .{ .base = rs1, .displacement = ir.signed(((b >> 25) << 5) | ((b >> 7) & 31), 12) } };
        },
        0x13, 0x1b => {
            if (opcode == 0x1b) {
                i.width = 32;
                i.sign_result = true;
            }
            i.src = ir.imm(sx(b >> 20, 12));
            i.op = switch (f3) {
                0 => .add,
                1 => .shl,
                2 => .set_compare,
                3 => .set_compare,
                4 => .xor,
                5 => if (b & 0x40000000 != 0) .sar else .shr,
                6 => .or_,
                7 => .and_,
            };
            if (opcode == 0x1b and f3 != 0 and f3 != 1 and f3 != 5) return error.InvalidInstruction;
            if (f3 == 1 or f3 == 5) {
                const upper = b >> @as(u5, if (opcode == 0x1b) 25 else 26);
                if (upper != 0 and !(f3 == 5 and upper == (if (opcode == 0x1b) @as(u32, 32) else 16))) return error.InvalidInstruction;
                i.src = ir.imm((b >> 20) & (if (opcode == 0x1b) @as(u32, 31) else 63));
            }
            if (f3 == 2 or f3 == 3) i.condition = if (f3 == 2) .lt else .below;
        },
        0x33, 0x3b => {
            if (opcode == 0x3b) {
                i.width = 32;
                i.sign_result = true;
            }
            if (f7 == 1) {
                i.op = switch (f3) {
                    0 => .imul,
                    1 => .mul_high_signed,
                    2 => .mul_high_mixed,
                    3 => .mul_high_unsigned,
                    4 => .divide_signed,
                    5 => .divide_unsigned,
                    6 => .remainder_signed,
                    7 => .remainder_unsigned,
                };
                if (opcode == 0x3b and f3 >= 1 and f3 <= 3) return error.InvalidInstruction;
            } else {
                if (f7 != 0 and !(f7 == 32 and (f3 == 0 or f3 == 5))) return error.InvalidInstruction;
                i.op = switch (f3) {
                    0 => if (f7 == 32) .sub else .add,
                    1 => .shl,
                    2 => .set_compare,
                    3 => .set_compare,
                    4 => .xor,
                    5 => if (f7 == 32) .sar else .shr,
                    6 => .or_,
                    7 => .and_,
                };
                if (opcode == 0x3b and f3 != 0 and f3 != 1 and f3 != 5) return error.InvalidInstruction;
                if (f3 == 2 or f3 == 3) i.condition = if (f3 == 2) .lt else .below;
            }
        },
        0x2f => {
            if (f3 != 2 and f3 != 3) return error.InvalidInstruction;
            const width: u7 = if (f3 == 2) 32 else 64;
            const kind = b >> 27;
            if (kind == 2) {
                if (rs2 != 0) return error.InvalidInstruction;
                i.op = .load_exclusive;
                i.source_width = width;
                i.sign_result = width == 32;
                i.src = .{ .mem = .{ .base = rs1 } };
            } else {
                i.width = width;
                i.sign_result = width == 32;
                i.dst = .{ .mem = .{ .base = rs1 } };
                i.rhs = ir.reg(rd);
                i.op = switch (kind) {
                    0 => .atomic_add,
                    1 => .atomic_swap,
                    3 => .store_exclusive,
                    4 => .atomic_xor,
                    8 => .atomic_or,
                    12 => .atomic_and,
                    16 => .atomic_min_signed,
                    20 => .atomic_max_signed,
                    24 => .atomic_min_unsigned,
                    28 => .atomic_max_unsigned,
                    else => return error.UnsupportedInstruction,
                };
            }
        },
        0x0f => {
            if (f3 != 0) return error.UnsupportedInstruction;
            i.dst = .none;
        },
        0x73 => {
            if (b == 0x73) {
                i.op = .syscall;
                i.dst = .none;
            } else if (f3 == 1 or f3 == 2 or f3 == 3 or f3 == 5 or f3 == 6 or f3 == 7) {
                i.op = .riscv_fp;
                i.encoding = b;
            } else return error.UnsupportedInstruction;
        },
        0x53 => {
            const fmt = (b >> 25) & 3;
            const funct5 = b >> 27;
            const rounding_mode = f3 <= 4 or f3 == 7;
            if (fmt > 1 or !((funct5 <= 3 and rounding_mode) or (funct5 == 4 and f3 <= 2) or (funct5 == 5 and f3 <= 1) or (funct5 == 8 and rs2 <= 1 and rs2 != fmt and rounding_mode) or (funct5 == 11 and rs2 == 0 and rounding_mode) or (funct5 == 20 and f3 <= 2) or (funct5 == 24 and rs2 <= 3 and rounding_mode) or (funct5 == 26 and rs2 <= 3 and rounding_mode) or (funct5 == 28 and rs2 == 0 and (f3 == 0 or f3 == 1)) or (funct5 == 30 and rs2 == 0 and f3 == 0))) return error.UnsupportedInstruction;
            i.op = .riscv_fp;
            i.encoding = b;
        },
        0x43, 0x47, 0x4b, 0x4f => {
            const fmt = (b >> 25) & 3;
            if (fmt > 1 or !(f3 <= 4 or f3 == 7)) return error.UnsupportedInstruction;
            i.op = .riscv_fp;
            i.encoding = b;
        },
        else => return error.UnsupportedInstruction,
    }
    return i;
}

pub fn executeFp(s: *CpuState, m: *Memory, b: u32) !void {
    const opcode = b & 127;
    const rd: u6 = @intCast((b >> 7) & 31);
    const rs1: u6 = @intCast((b >> 15) & 31);
    const rs2: u6 = @intCast((b >> 20) & 31);
    const f3 = (b >> 12) & 7;
    if (opcode == 0x07 or opcode == 0x27) {
        const width: u7 = if (f3 == 2) 32 else if (f3 == 3) 64 else return error.UnsupportedInstruction;
        const offset = if (opcode == 0x07) ir.signed(b >> 20, 12) else ir.signed(((b >> 25) << 5) | ((b >> 7) & 31), 12);
        const addr = s.get(rs1) +% @as(u64, @bitCast(offset));
        if (addr % (width / 8) != 0) return error.MisalignedMemory;
        if (opcode == 0x07) {
            const value = try m.readInt(addr, width, .read);
            fpWrite(s, rd, if (width == 32) 0 else 1, value);
        } else try m.writeInt(addr, width, s.fp_registers[rs2]);
        return;
    }
    if (opcode == 0x73) {
        const csr: u12 = @truncate(b >> 20);
        const immediate_form = f3 >= 5;
        const operation = f3 % 4;
        const source = if (immediate_form) @as(u64, rs1) else s.get(rs1);
        const old = switch (csr) {
            1 => @as(u64, s.fp_flags),
            2 => @as(u64, s.fp_rounding_mode),
            3 => @as(u64, s.fp_flags) | (@as(u64, s.fp_rounding_mode) << 5),
            else => return error.UnsupportedInstruction,
        };
        if (rd != 0) s.set(rd, old);
        if (operation == 1 or source != 0) {
            const value = switch (operation) {
                1 => source,
                2 => old | source,
                3 => old & ~source,
                else => return error.InvalidInstruction,
            };
            switch (csr) {
                1 => s.fp_flags = @truncate(value & 31),
                2 => s.fp_rounding_mode = @truncate(value & 7),
                3 => {
                    s.fp_flags = @truncate(value & 31);
                    s.fp_rounding_mode = @truncate((value >> 5) & 7);
                },
                else => unreachable,
            }
        }
        return;
    }

    if (opcode == 0x43 or opcode == 0x47 or opcode == 0x4b or opcode == 0x4f) {
        const fmt = (b >> 25) & 3;
        if (fmt > 1) return error.UnsupportedInstruction;
        const a = fpRead(s, rs1, fmt);
        const c_reg: u6 = @intCast((b >> 27) & 31);
        try fusedMultiplyAdd(s, rd, fmt, opcode, a, fpRead(s, rs2, fmt), fpRead(s, c_reg, fmt), try roundingMode(s, f3));
        return;
    }

    const fmt = (b >> 25) & 3;
    if (fmt > 1) return error.UnsupportedInstruction;
    const a_bits = fpRead(s, rs1, fmt);
    const sign_mask: u64 = if (fmt == 0) 0x80000000 else 0x8000000000000000;
    switch (b >> 27) {
        0, 1, 2, 3, 11 => try floatArithmetic(s, rd, fmt, b >> 27, f3, a_bits, fpRead(s, rs2, fmt)),
        5 => try floatMinMax(s, rd, fmt, f3, a_bits, fpRead(s, rs2, fmt)),
        8 => try floatConvert(s, rd, fmt, rs2, fpRead(s, rs1, rs2), try roundingMode(s, f3)),
        4 => {
            const b_bits = fpRead(s, rs2, fmt);
            const sign = switch (f3) {
                0 => b_bits & sign_mask,
                1 => (b_bits ^ sign_mask) & sign_mask,
                2 => (a_bits ^ b_bits) & sign_mask,
                else => return error.InvalidInstruction,
            };
            fpWrite(s, rd, fmt, (a_bits & ~sign_mask) | sign);
        },
        20 => {
            const b_bits = fpRead(s, rs2, fmt);
            const nan_a = isNan(a_bits, fmt);
            const nan_b = isNan(b_bits, fmt);
            if ((f3 != 2 and (nan_a or nan_b) or isSignalingNan(a_bits, fmt) or isSignalingNan(b_bits, fmt))) s.fp_flags |= 16;
            const result = if (nan_a or nan_b) false else switch (f3) {
                0 => fpLess(fmt, a_bits, b_bits) or fpEqual(fmt, a_bits, b_bits), // FLE
                1 => fpLess(fmt, a_bits, b_bits),
                2 => fpEqual(fmt, a_bits, b_bits),
                else => return error.InvalidInstruction,
            };
            s.set(rd, @intFromBool(result));
        },
        24 => try floatToInt(s, rd, a_bits, fmt, rs2, try roundingMode(s, f3)),
        26 => try intToFloat(s, rd, s.get(rs1), rs2, fmt, try roundingMode(s, f3)),
        28 => {
            if (f3 == 1) {
                s.set(rd, fpClass(a_bits, fmt));
            } else if (f3 == 0) {
                const bits = s.fp_registers[rs1];
                s.set(rd, if (fmt == 0) @bitCast(ir.signed(bits, 32)) else bits);
            } else return error.InvalidInstruction;
        },
        30 => fpWrite(s, rd, fmt, s.get(rs1)),
        else => return error.UnsupportedInstruction,
    }
}

fn roundingMode(s: *const CpuState, encoded: u32) !u3 {
    const mode: u3 = if (encoded == 7) s.fp_rounding_mode else @intCast(encoded);
    if (mode > 4) return error.UnsupportedRoundingMode;
    return mode;
}
fn roundFloat(value: f64, mode: u3) f64 {
    const toward_zero = @trunc(value);
    const fraction = value - toward_zero;
    const magnitude = @abs(fraction);
    if (magnitude == 0) return value;
    const direction: f64 = if (fraction < 0) -1 else 1;
    return switch (mode) {
        0 => if (magnitude < 0.5 or magnitude == 0.5 and @rem(toward_zero, 2) == 0) toward_zero else toward_zero + direction,
        1 => toward_zero,
        2 => @floor(value),
        3 => @ceil(value),
        4 => if (magnitude < 0.5) toward_zero else toward_zero + direction,
        else => unreachable,
    };
}
fn toFloat(fmt: u32, bits: u64) f64 {
    if (fmt == 0) return @as(f64, @floatCast(@as(f32, @bitCast(@as(u32, @truncate(bits))))));
    return @bitCast(bits);
}
fn floatToInt(s: *CpuState, rd: u6, bits: u64, fmt: u32, kind: u6, mode: u3) !void {
    const source = toFloat(fmt, bits);
    const signed_kind = kind == 0 or kind == 2;
    const width: u7 = if (kind <= 1) 32 else 64;
    const lower: f64 = if (signed_kind) (if (width == 32) -2147483648.0 else -9223372036854775808.0) else 0;
    const upper: f64 = if (signed_kind) (if (width == 32) 2147483648.0 else 9223372036854775808.0) else if (width == 32) 4294967296.0 else 18446744073709551616.0;
    const invalid = isNan(bits, fmt) or !std.math.isFinite(source);
    const rounded = if (invalid) source else roundFloat(source, mode);
    if (invalid or rounded < lower or rounded >= upper) {
        s.fp_flags |= 16;
        const negative = source < 0;
        const result: u64 = switch (kind) {
            0 => if (negative) 0xffffffff80000000 else 0x7fffffff,
            1 => if (negative) 0 else 0xffffffff,
            2 => if (negative) 0x8000000000000000 else 0x7fffffffffffffff,
            3 => if (negative) 0 else std.math.maxInt(u64),
            else => return error.InvalidInstruction,
        };
        s.set(rd, result);
        return;
    }
    const result: u64 = switch (kind) {
        0 => @bitCast(@as(i64, @intFromFloat(rounded))),
        1 => @intFromFloat(rounded),
        2 => @bitCast(@as(i64, @intFromFloat(rounded))),
        3 => @intFromFloat(rounded),
        else => return error.InvalidInstruction,
    };
    if (rounded != source) s.fp_flags |= 1;
    s.set(rd, result);
}
fn intToFloat(s: *CpuState, rd: u6, bits: u64, kind: u6, fmt: u32, mode: u3) !void {
    const integer: i128 = switch (kind) {
        0 => ir.signed(bits, 32),
        1 => @as(u32, @truncate(bits)),
        2 => ir.signed(bits, 64),
        3 => @as(i128, bits),
        else => return error.InvalidInstruction,
    };
    const exact: f128 = @floatFromInt(integer);
    const nearest_bits = if (fmt == 0)
        @as(u64, @as(u32, @bitCast(@as(f32, @floatFromInt(integer)))))
    else
        @as(u64, @bitCast(@as(f64, @floatFromInt(integer))));
    fpWrite(s, rd, fmt, roundResult(s, fmt, nearest_bits, exact, mode, false, 0));
}

fn fpSign(bits: u64, fmt: u32) bool {
    return bits & (if (fmt == 0) @as(u64, 0x80000000) else @as(u64, 0x8000000000000000)) != 0;
}
fn fpIsZero(bits: u64, fmt: u32) bool {
    return bits & (if (fmt == 0) @as(u64, 0x7fffffff) else @as(u64, 0x7fffffffffffffff)) == 0;
}
fn fpIsInf(bits: u64, fmt: u32) bool {
    const exp_mask: u64 = if (fmt == 0) 0x7f800000 else 0x7ff0000000000000;
    const fraction_mask: u64 = if (fmt == 0) 0x007fffff else 0x000fffffffffffff;
    return bits & exp_mask == exp_mask and bits & fraction_mask == 0;
}
fn fpInfinity(fmt: u32, negative: bool) u64 {
    return (if (fmt == 0) @as(u64, 0x7f800000) else @as(u64, 0x7ff0000000000000)) |
        (if (negative) (if (fmt == 0) @as(u64, 0x80000000) else @as(u64, 0x8000000000000000)) else 0);
}
fn canonicalNan(fmt: u32) u64 {
    return if (fmt == 0) 0x7fc00000 else 0x7ff8000000000000;
}
fn fpExtended(bits: u64, fmt: u32) f128 {
    return @floatCast(toFloat(fmt, bits));
}
fn roundedFlags(s: *CpuState, fmt: u32, bits: u64, exact: f128, force_inexact: bool) void {
    if (fpIsInf(bits, fmt) and !std.math.isInf(exact)) {
        s.fp_flags |= 5; // Overflow always implies inexact.
        return;
    }
    const result = fpExtended(bits, fmt);
    const exp_mask: u64 = if (fmt == 0) 0x7f800000 else 0x7ff0000000000000;
    const inexact = force_inexact or result != exact;
    if (!inexact) return;
    s.fp_flags |= 1;
    if (bits & exp_mask == 0 and exact != 0) s.fp_flags |= 2;
}
fn nextFloat(fmt: u32, bits: u64, up: bool) u64 {
    const sign: u64 = if (fmt == 0) 0x80000000 else 0x8000000000000000;
    const positive_inf = if (fmt == 0) @as(u64, 0x7f800000) else 0x7ff0000000000000;
    const negative_inf = positive_inf | sign;
    if (isNan(bits, fmt)) return bits;
    if (up) {
        if (bits == positive_inf) return bits;
        if (bits == sign) return 1;
        return if (fpSign(bits, fmt)) bits - 1 else bits + 1;
    }
    if (bits == negative_inf) return bits;
    if (fpIsZero(bits, fmt)) return sign | 1;
    return if (fpSign(bits, fmt)) bits + 1 else bits - 1;
}
fn roundResult(s: *CpuState, fmt: u32, nearest_bits: u64, exact: f128, mode: u3, force_inexact: bool, absorbed_direction: i8) u64 {
    const max_finite: f128 = if (fmt == 0) 0x1.fffffep127 else 0x1.fffffffffffffp1023;
    const overflow_limit: f128 = if (fmt == 0) 0x1p128 else 0x1p1024;
    const magnitude = @abs(exact);
    const negative = exact < 0;
    const rounded_past_max = force_inexact and magnitude == max_finite and
        ((mode == 2 and negative and absorbed_direction < 0) or (mode == 3 and !negative and absorbed_direction > 0));
    const overflow = std.math.isFinite(exact) and switch (mode) {
        0, 4 => fpIsInf(nearest_bits, fmt),
        1 => magnitude >= overflow_limit,
        2 => if (negative) magnitude > max_finite or rounded_past_max else magnitude >= overflow_limit,
        3 => if (!negative) magnitude > max_finite or rounded_past_max else magnitude >= overflow_limit,
        else => unreachable,
    };
    if (overflow) {
        const to_infinity = switch (mode) {
            0, 4 => fpIsInf(nearest_bits, fmt),
            1 => false,
            2 => negative,
            3 => !negative,
            else => unreachable,
        };
        s.fp_flags |= 5;
        return if (to_infinity) fpInfinity(fmt, negative) else if (fmt == 0)
            @as(u64, if (negative) 0xff7fffff else 0x7f7fffff)
        else if (negative) 0xffefffffffffffff else 0x7fefffffffffffff;
    }
    const nearest = fpExtended(nearest_bits, fmt);
    const relation: i8 = if (exact < nearest) -1 else if (exact > nearest) 1 else if (force_inexact) absorbed_direction else 0;
    var result = nearest_bits;
    if (mode == 1 and ((exact > 0 and relation < 0) or (exact < 0 and relation > 0))) {
        result = nextFloat(fmt, result, exact < 0);
    } else if (mode == 2 and relation < 0) {
        result = nextFloat(fmt, result, false);
    } else if (mode == 3 and relation > 0) {
        result = nextFloat(fmt, result, true);
    } else if (mode == 4 and exact != nearest and relation != 0) {
        const away = nextFloat(fmt, nearest_bits, relation > 0);
        const midpoint = (nearest + fpExtended(away, fmt)) / 2;
        if (exact == midpoint and @abs(fpExtended(away, fmt)) > @abs(nearest)) result = away;
    }
    roundedFlags(s, fmt, result, exact, force_inexact);
    return result;
}
fn floatArithmetic(s: *CpuState, rd: u6, fmt: u32, operation: u32, rm: u32, a_bits: u64, b_bits: u64) !void {
    const mode = try roundingMode(s, rm);
    const sign_mask: u64 = if (fmt == 0) 0x80000000 else 0x8000000000000000;
    const nan_a = isNan(a_bits, fmt);
    const nan_b = isNan(b_bits, fmt);
    const inf_a = fpIsInf(a_bits, fmt);
    const inf_b = fpIsInf(b_bits, fmt);
    const zero_a = fpIsZero(a_bits, fmt);
    const zero_b = fpIsZero(b_bits, fmt);
    var invalid = false;
    if (isSignalingNan(a_bits, fmt) or isSignalingNan(b_bits, fmt)) s.fp_flags |= 16;
    switch (operation) {
        0 => invalid = inf_a and inf_b and fpSign(a_bits, fmt) != fpSign(b_bits, fmt),
        1 => invalid = inf_a and inf_b and fpSign(a_bits, fmt) == fpSign(b_bits, fmt),
        2 => invalid = (inf_a and zero_b) or (zero_a and inf_b),
        3 => {
            invalid = (zero_a and zero_b) or (inf_a and inf_b);
            if (!invalid and !nan_a and !nan_b and !inf_a and zero_b) {
                s.fp_flags |= 8;
                fpWrite(s, rd, fmt, fpInfinity(fmt, fpSign(a_bits, fmt) != fpSign(b_bits, fmt)));
                return;
            }
        },
        11 => invalid = fpSign(a_bits, fmt) and !zero_a and !nan_a,
        else => return error.InvalidInstruction,
    }
    if (nan_a or nan_b or invalid) {
        if (invalid) s.fp_flags |= 16;
        fpWrite(s, rd, fmt, canonicalNan(fmt));
        return;
    }

    var result_bits: u64 = 0;
    var exact: f128 = 0;
    var force_inexact = false;
    const a = fpExtended(a_bits, fmt);
    const b = fpExtended(b_bits, fmt);
    if (operation == 11) {
        if (fmt == 0) {
            const av: f32 = @bitCast(@as(u32, @truncate(a_bits)));
            const result: f32 = @sqrt(av);
            result_bits = @as(u32, @bitCast(result));
        } else {
            const av: f64 = @bitCast(a_bits);
            const result: f64 = @sqrt(av);
            result_bits = @bitCast(result);
        }
        const result = fpExtended(result_bits, fmt);
        force_inexact = result * result != a;
        const root: f128 = @sqrt(a);
        const bias: i8 = if (result * result < a) 1 else -1;
        fpWrite(s, rd, fmt, roundResult(s, fmt, result_bits, root, mode, force_inexact, bias));
        return;
    }
    if (fmt == 0) {
        const av: f32 = @bitCast(@as(u32, @truncate(a_bits)));
        const bv: f32 = @bitCast(@as(u32, @truncate(b_bits)));
        const result: f32 = switch (operation) {
            0 => av + bv,
            1 => av - bv,
            2 => av * bv,
            3 => av / bv,
            else => unreachable,
        };
        result_bits = @as(u32, @bitCast(result));
    } else {
        const av: f64 = @bitCast(a_bits);
        const bv: f64 = @bitCast(b_bits);
        const result: f64 = switch (operation) {
            0 => av + bv,
            1 => av - bv,
            2 => av * bv,
            3 => av / bv,
            else => unreachable,
        };
        result_bits = @bitCast(result);
    }
    exact = switch (operation) {
        0 => a + b,
        1 => a - b,
        2 => a * b,
        3 => a / b,
        else => unreachable,
    };
    const result_ext = fpExtended(result_bits, fmt);
    if (operation == 0 and (result_ext == a or result_ext == b) and !zero_a and !zero_b) force_inexact = true;
    if (operation == 1 and (result_ext == a or result_ext == -b) and !zero_a and !zero_b) force_inexact = true;
    if (exact == 0 and operation <= 1) {
        const negative_a = fpSign(a_bits, fmt);
        const negative_b = fpSign(b_bits, fmt) != (operation == 1);
        const negative_zero = if (zero_a and zero_b)
            (negative_a and negative_b) or (mode == 2 and negative_a != negative_b)
        else
            mode == 2;
        result_bits = if (negative_zero) sign_mask else 0;
    }
    var bias: i8 = 0;
    if (force_inexact and operation <= 1) {
        const other = if (operation == 0)
            (if (result_ext == a) b else a)
        else if (result_ext == a) -b else a;
        bias = if (other > 0) 1 else -1;
    }
    fpWrite(s, rd, fmt, roundResult(s, fmt, result_bits, exact, mode, force_inexact, bias));
}
fn floatMinMax(s: *CpuState, rd: u6, fmt: u32, operation: u32, a: u64, b: u64) !void {
    if (operation > 1) return error.InvalidInstruction;
    const nan_a = isNan(a, fmt);
    const nan_b = isNan(b, fmt);
    if (isSignalingNan(a, fmt) or isSignalingNan(b, fmt)) s.fp_flags |= 16;
    if (nan_a or nan_b) {
        fpWrite(s, rd, fmt, if (nan_a and nan_b) canonicalNan(fmt) else if (nan_a) b else a);
        return;
    }
    if (fpIsZero(a, fmt) and fpIsZero(b, fmt)) {
        const negative = if (operation == 0) fpSign(a, fmt) or fpSign(b, fmt) else fpSign(a, fmt) and fpSign(b, fmt);
        fpWrite(s, rd, fmt, if (negative) (a | (if (fmt == 0) @as(u64, 0x80000000) else @as(u64, 0x8000000000000000))) else a & ~(if (fmt == 0) @as(u64, 0x80000000) else @as(u64, 0x8000000000000000)));
        return;
    }
    const less = fpLess(fmt, a, b);
    fpWrite(s, rd, fmt, if ((operation == 0 and (less or fpEqual(fmt, a, b))) or (operation == 1 and !less)) a else b);
}
fn nextUpF32(value: f32) f32 {
    const bits: u32 = @bitCast(value);
    if (std.math.isNan(value) or bits == 0x7f800000) return value;
    if (bits == 0x80000000) return @bitCast(@as(u32, 1));
    return @bitCast(if (value < 0) bits - 1 else bits + 1);
}
fn nextDownF32(value: f32) f32 {
    const bits: u32 = @bitCast(value);
    if (std.math.isNan(value) or bits == 0xff800000) return value;
    if (bits == 0 or bits == 0x80000000) return @bitCast(@as(u32, 0x80000001));
    return @bitCast(if (value < 0) bits + 1 else bits - 1);
}
fn floatConvert(s: *CpuState, rd: u6, dst_fmt: u32, src_fmt: u6, source_bits: u64, mode: u3) !void {
    if (dst_fmt == 1) {
        if (isNan(source_bits, src_fmt)) {
            if (isSignalingNan(source_bits, src_fmt)) s.fp_flags |= 16;
            fpWrite(s, rd, dst_fmt, canonicalNan(dst_fmt));
        } else fpWrite(s, rd, dst_fmt, @bitCast(@as(f64, @floatCast(toFloat(src_fmt, source_bits)))));
        return;
    }
    if (isNan(source_bits, src_fmt)) {
        if (isSignalingNan(source_bits, src_fmt)) s.fp_flags |= 16;
        fpWrite(s, rd, dst_fmt, canonicalNan(dst_fmt));
        return;
    }
    const source: f64 = @bitCast(source_bits);
    if (!std.math.isFinite(source)) {
        fpWrite(s, rd, dst_fmt, fpInfinity(dst_fmt, fpSign(source_bits, src_fmt)));
        return;
    }
    const result_bits: u32 = @bitCast(@as(f32, @floatCast(source)));
    const exact: f128 = @floatCast(source);
    fpWrite(s, rd, dst_fmt, roundResult(s, dst_fmt, result_bits, exact, mode, false, 0));
}
fn fusedMultiplyAdd(s: *CpuState, rd: u6, fmt: u32, opcode: u32, a_bits: u64, b_bits: u64, c_bits: u64, rm: u3) !void {
    const nan_a = isNan(a_bits, fmt);
    const nan_b = isNan(b_bits, fmt);
    const nan_c = isNan(c_bits, fmt);
    if (isSignalingNan(a_bits, fmt) or isSignalingNan(b_bits, fmt) or isSignalingNan(c_bits, fmt)) s.fp_flags |= 16;
    const zero_inf = (fpIsZero(a_bits, fmt) and fpIsInf(b_bits, fmt)) or (fpIsInf(a_bits, fmt) and fpIsZero(b_bits, fmt));
    const negate_product = opcode == 0x4b or opcode == 0x4f;
    const negate_addend = opcode == 0x47 or opcode == 0x4f;
    const product_infinite = !nan_a and !nan_b and (fpIsInf(a_bits, fmt) or fpIsInf(b_bits, fmt));
    const product_sign = (fpSign(a_bits, fmt) != fpSign(b_bits, fmt)) != negate_product;
    const addend_sign = fpSign(c_bits, fmt) != negate_addend;
    const opposite_infinities = product_infinite and !nan_c and fpIsInf(c_bits, fmt) and product_sign != addend_sign;
    if (zero_inf or opposite_infinities) s.fp_flags |= 16;
    if (nan_a or nan_b or nan_c or zero_inf or opposite_infinities) {
        fpWrite(s, rd, fmt, canonicalNan(fmt));
        return;
    }
    const sign_mask: u64 = if (fmt == 0) 0x80000000 else 0x8000000000000000;
    const a = if (negate_product) a_bits ^ sign_mask else a_bits;
    const c = if (negate_addend) c_bits ^ sign_mask else c_bits;
    var result_bits: u64 = 0;
    if (fmt == 0) {
        const av: f32 = @bitCast(@as(u32, @truncate(a)));
        const bv: f32 = @bitCast(@as(u32, @truncate(b_bits)));
        const cv: f32 = @bitCast(@as(u32, @truncate(c)));
        result_bits = @as(u32, @bitCast(@mulAdd(f32, av, bv, cv)));
    } else {
        const av: f64 = @bitCast(a);
        const bv: f64 = @bitCast(b_bits);
        const cv: f64 = @bitCast(c);
        result_bits = @bitCast(@mulAdd(f64, av, bv, cv));
    }
    const exact = fpExtended(a, fmt) * fpExtended(b_bits, fmt) + fpExtended(c, fmt);
    const product = fpExtended(a, fmt) * fpExtended(b_bits, fmt);
    if (exact == 0) {
        const addend = fpExtended(c, fmt);
        const negative_zero = if (product == 0 and addend == 0)
            (product_sign and addend_sign) or (rm == 2 and product_sign != addend_sign)
        else
            rm == 2;
        result_bits = if (negative_zero) (if (fmt == 0) @as(u64, 0x80000000) else 0x8000000000000000) else 0;
    }
    const result_ext = fpExtended(result_bits, fmt);
    const absorbed = (result_ext == product and fpExtended(c, fmt) != 0) or (result_ext == fpExtended(c, fmt) and product != 0);
    const bias: i8 = if (!absorbed) 0 else if (result_ext == product)
        (if (fpExtended(c, fmt) > 0) @as(i8, 1) else -1)
    else if (product > 0) 1 else -1;
    fpWrite(s, rd, fmt, roundResult(s, fmt, result_bits, exact, rm, absorbed, bias));
}

fn fpRead(s: *const CpuState, index: u6, fmt: u32) u64 {
    const bits = s.fp_registers[index];
    if (fmt == 0) return if (bits >> 32 == 0xffffffff) bits & 0xffffffff else 0x7fc00000;
    return bits;
}
fn fpWrite(s: *CpuState, index: u6, fmt: u32, bits: u64) void {
    s.fp_registers[index] = if (fmt == 0) @as(u64, @truncate(bits)) | 0xffffffff00000000 else bits;
}
fn isNan(bits: u64, fmt: u32) bool {
    const exp_mask: u64 = if (fmt == 0) 0x7f800000 else 0x7ff0000000000000;
    const fraction_mask: u64 = if (fmt == 0) 0x007fffff else 0x000fffffffffffff;
    return bits & exp_mask == exp_mask and bits & fraction_mask != 0;
}
fn isSignalingNan(bits: u64, fmt: u32) bool {
    const quiet_bit: u64 = if (fmt == 0) 0x00400000 else 0x0008000000000000;
    return isNan(bits, fmt) and bits & quiet_bit == 0;
}
fn fpClass(bits: u64, fmt: u32) u64 {
    const sign_mask: u64 = if (fmt == 0) 0x80000000 else 0x8000000000000000;
    const exp_mask: u64 = if (fmt == 0) 0x7f800000 else 0x7ff0000000000000;
    const fraction_mask: u64 = if (fmt == 0) 0x007fffff else 0x000fffffffffffff;
    const exponent = bits & exp_mask;
    const fraction = bits & fraction_mask;
    const negative = bits & sign_mask != 0;
    const category: u6 = if (exponent == exp_mask) blk: {
        if (fraction == 0) break :blk if (negative) 0 else 7;
        break :blk if (isSignalingNan(bits, fmt)) 8 else 9;
    } else if (exponent == 0) blk: {
        if (fraction == 0) break :blk if (negative) 3 else 4;
        break :blk if (negative) 2 else 5;
    } else if (negative) 1 else 6;
    return @as(u64, 1) << category;
}
fn fpLess(fmt: u32, a: u64, b: u64) bool {
    if (fmt == 0) return @as(f32, @bitCast(@as(u32, @truncate(a)))) < @as(f32, @bitCast(@as(u32, @truncate(b))));
    return @as(f64, @bitCast(a)) < @as(f64, @bitCast(b));
}
fn fpEqual(fmt: u32, a: u64, b: u64) bool {
    if (fmt == 0) return @as(f32, @bitCast(@as(u32, @truncate(a)))) == @as(f32, @bitCast(@as(u32, @truncate(b))));
    return @as(f64, @bitCast(a)) == @as(f64, @bitCast(b));
}

test "RV64 sign extension, branches and invalid encoding" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.initialize(0x1000, &.{ 0x93, 0x05, 0xf0, 0xff });
    const i = try decode(&m, 0x1000);
    try std.testing.expectEqual(ir.Op.add, i.op);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), i.src.imm);
    try m.initialize(0x1000, &.{ 0, 0, 0, 0 });
    try std.testing.expectError(error.InvalidInstruction, decode(&m, 0x1000));
}
test "RISC-V decoder fuzz" {
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

test "RV64C expands like independently assembled RV64 instructions" {
    // LLVM assembler references: each RVC mnemonic followed by its .option norvc equivalent.
    const pairs = [_][2]u32{
        .{ 0x2000, 0x00043407 }, // c.fld fs0,0(s0)
        .{ 0xa000, 0x00843027 }, // c.fsd fs0,0(s0)
        .{ 0x2002, 0x00013007 }, // c.fldsp ft0,0(sp)
        .{ 0xa002, 0x00013027 }, // c.fsdsp ft0,0(sp)
        .{ 0xa20a, 0x10213027 }, // c.fsdsp ft2,256(sp)
        .{ 0x1fe8, 0x3fc10513 }, // c.addi4spn a0,sp,1020
        .{ 0x5fe8, 0x07c7a503 }, // c.lw a0,124(a5)
        .{ 0x7fe8, 0x0f87b503 }, // c.ld a0,248(a5)
        .{ 0xdfe8, 0x06a7ae23 }, // c.sw a0,124(a5)
        .{ 0xffe8, 0x0ea7bc23 }, // c.sd a0,248(a5)
        .{ 0x1501, 0xfe050513 }, // c.addi a0,-32
        .{ 0x057d, 0x01f50513 }, // c.addi a0,31
        .{ 0x0001, 0x00000013 }, // c.nop
        .{ 0x3501, 0xfe05051b }, // c.addiw a0,-32
        .{ 0x2501, 0x0005051b }, // c.addiw a0,0
        .{ 0x5501, 0xfe000513 }, // c.li a0,-32
        .{ 0x7101, 0xe0010113 }, // c.addi16sp sp,-512
        .{ 0x617d, 0x1f010113 }, // c.addi16sp sp,496
        .{ 0x7501, 0xfffe0537 }, // c.lui a0,0xfffe0
        .{ 0x657d, 0x0001f537 }, // c.lui a0,31
        .{ 0x93fd, 0x03f7d793 }, // c.srli a5,63
        .{ 0x97fd, 0x43f7d793 }, // c.srai a5,63
        .{ 0x9b81, 0xfe07f793 }, // c.andi a5,-32
        .{ 0x8f89, 0x40a787b3 }, // c.sub a5,a0
        .{ 0x8fa9, 0x00a7c7b3 }, // c.xor a5,a0
        .{ 0x8fc9, 0x00a7e7b3 }, // c.or a5,a0
        .{ 0x8fe9, 0x00a7f7b3 }, // c.and a5,a0
        .{ 0x9f89, 0x40a787bb }, // c.subw a5,a0
        .{ 0x9fa9, 0x00a787bb }, // c.addw a5,a0
        .{ 0xb001, 0x801ff06f }, // c.j .-2048
        .{ 0xaffd, 0x7fe0006f }, // c.j .+2046
        .{ 0xd381, 0xf00780e3 }, // c.beqz a5,.-256
        .{ 0xeffd, 0x0e079f63 }, // c.bnez a5,.+254
        .{ 0x1ffe, 0x03ff9f93 }, // c.slli t6,63
        .{ 0x5ffe, 0x0fc12f83 }, // c.lwsp t6,252(sp)
        .{ 0x7ffe, 0x1f813f83 }, // c.ldsp t6,504(sp)
        .{ 0x8082, 0x00008067 }, // c.jr ra
        .{ 0x9082, 0x000080e7 }, // c.jalr ra
        .{ 0x8ffa, 0x01e00fb3 }, // c.mv t6,t5
        .{ 0x9ffa, 0x01ef8fb3 }, // c.add t6,t5
        .{ 0xdffe, 0x0ff12e23 }, // c.swsp t6,252(sp)
        .{ 0xfffe, 0x1ff13c23 }, // c.sdsp t6,504(sp)
        // One-bit offsets check the scrambled immediate fields independently.
        .{ 0x004c, 0x00410593 }, // c.addi4spn a1,sp,4
        .{ 0x002c, 0x00810593 }, // c.addi4spn a1,sp,8
        .{ 0x080c, 0x01010593 }, // c.addi4spn a1,sp,16
        .{ 0x100c, 0x02010593 }, // c.addi4spn a1,sp,32
        .{ 0x008c, 0x04010593 }, // c.addi4spn a1,sp,64
        .{ 0x010c, 0x08010593 }, // c.addi4spn a1,sp,128
        .{ 0x020c, 0x10010593 }, // c.addi4spn a1,sp,256
        .{ 0x040c, 0x20010593 }, // c.addi4spn a1,sp,512
        .{ 0x6141, 0x01010113 }, // c.addi16sp sp,16
        .{ 0x6105, 0x02010113 }, // c.addi16sp sp,32
        .{ 0x6121, 0x04010113 }, // c.addi16sp sp,64
        .{ 0x6109, 0x08010113 }, // c.addi16sp sp,128
        .{ 0x6111, 0x10010113 }, // c.addi16sp sp,256
        .{ 0xa009, 0x0020006f }, // c.j .+2
        .{ 0xa011, 0x0040006f }, // c.j .+4
        .{ 0xa021, 0x0080006f }, // c.j .+8
        .{ 0xa801, 0x0100006f }, // c.j .+16
        .{ 0xa005, 0x0200006f }, // c.j .+32
        .{ 0xa081, 0x0400006f }, // c.j .+64
        .{ 0xa041, 0x0800006f }, // c.j .+128
        .{ 0xa201, 0x1000006f }, // c.j .+256
        .{ 0xa401, 0x2000006f }, // c.j .+512
        .{ 0xa101, 0x4000006f }, // c.j .+1024
        .{ 0xc209, 0x00060163 }, // c.beqz a2,.+2
        .{ 0xc211, 0x00060263 }, // c.beqz a2,.+4
        .{ 0xc601, 0x00060463 }, // c.beqz a2,.+8
        .{ 0xca01, 0x00060863 }, // c.beqz a2,.+16
        .{ 0xc205, 0x02060063 }, // c.beqz a2,.+32
        .{ 0xc221, 0x04060063 }, // c.beqz a2,.+64
        .{ 0xc241, 0x08060063 }, // c.beqz a2,.+128
        .{ 0x424c, 0x00462583 }, // c.lw a1,4(a2)
        .{ 0x460c, 0x00862583 }, // c.lw a1,8(a2)
        .{ 0x4a0c, 0x01062583 }, // c.lw a1,16(a2)
        .{ 0x520c, 0x02062583 }, // c.lw a1,32(a2)
        .{ 0x422c, 0x04062583 }, // c.lw a1,64(a2)
        .{ 0x660c, 0x00863583 }, // c.ld a1,8(a2)
        .{ 0x6a0c, 0x01063583 }, // c.ld a1,16(a2)
        .{ 0x720c, 0x02063583 }, // c.ld a1,32(a2)
        .{ 0x622c, 0x04063583 }, // c.ld a1,64(a2)
        .{ 0x624c, 0x08063583 }, // c.ld a1,128(a2)
        .{ 0x4592, 0x00412583 }, // c.lwsp a1,4(sp)
        .{ 0x45a2, 0x00812583 }, // c.lwsp a1,8(sp)
        .{ 0x45c2, 0x01012583 }, // c.lwsp a1,16(sp)
        .{ 0x5582, 0x02012583 }, // c.lwsp a1,32(sp)
        .{ 0x4586, 0x04012583 }, // c.lwsp a1,64(sp)
        .{ 0x458a, 0x08012583 }, // c.lwsp a1,128(sp)
        .{ 0x65a2, 0x00813583 }, // c.ldsp a1,8(sp)
        .{ 0x65c2, 0x01013583 }, // c.ldsp a1,16(sp)
        .{ 0x7582, 0x02013583 }, // c.ldsp a1,32(sp)
        .{ 0x6586, 0x04013583 }, // c.ldsp a1,64(sp)
        .{ 0x658a, 0x08013583 }, // c.ldsp a1,128(sp)
        .{ 0x6592, 0x10013583 }, // c.ldsp a1,256(sp)
        .{ 0xc22e, 0x00b12223 }, // c.swsp a1,4(sp)
        .{ 0xc42e, 0x00b12423 }, // c.swsp a1,8(sp)
        .{ 0xc82e, 0x00b12823 }, // c.swsp a1,16(sp)
        .{ 0xd02e, 0x02b12023 }, // c.swsp a1,32(sp)
        .{ 0xc0ae, 0x04b12023 }, // c.swsp a1,64(sp)
        .{ 0xc12e, 0x08b12023 }, // c.swsp a1,128(sp)
        .{ 0xe42e, 0x00b13423 }, // c.sdsp a1,8(sp)
        .{ 0xe82e, 0x00b13823 }, // c.sdsp a1,16(sp)
        .{ 0xf02e, 0x02b13023 }, // c.sdsp a1,32(sp)
        .{ 0xe0ae, 0x04b13023 }, // c.sdsp a1,64(sp)
        .{ 0xe12e, 0x08b13023 }, // c.sdsp a1,128(sp)
        .{ 0xe22e, 0x10b13023 }, // c.sdsp a1,256(sp)
    };
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    for (pairs) |pair| {
        try std.testing.expectEqual(pair[1], try expand(@intCast(pair[0])));
        try memory.writeInt(0x1000, 16, pair[0]);
        const actual = try decode(&memory, 0x1000);
        const expected = try word(pair[1], 0x1000, 0x1002);
        try std.testing.expect(std.meta.eql(expected, actual));
        var state = @import("state.zig").State{ .architecture = .riscv64 };
        for (1..32) |r| state.set(@intCast(r), 0x1800);
        state.set(1, 0x1801); // JALR reads the old RA before writing its PC+2 link.
        state.set(2, 0x1700);
        var reference = state;
        _ = try @import("../interpreter.zig").execute(&state, &memory, actual);
        _ = try @import("../interpreter.zig").execute(&reference, &memory, expected);
        try std.testing.expect(std.meta.eql(reference, state));
    }
}

test "RV64C hints, reserved encodings and instruction fetch boundaries" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    for ([_]u16{ 0, 0x2001, 0x6001, 0x6101, 0x4002, 0x6002, 0x8002, 0x8000, 0x9c41, 0x9c61 }) |b| {
        try memory.writeInt(0x1000, 16, b);
        try std.testing.expectError(error.InvalidInstruction, decode(&memory, 0x1000));
    }
    for ([_]u16{ 0x9002, 0x001f }) |b| {
        try memory.writeInt(0x1000, 16, b);
        try std.testing.expectError(error.UnsupportedInstruction, decode(&memory, 0x1000));
    }
    for ([_]u16{ 0x0001, 0x0005, 0x0501, 0x4001, 0x6005, 0x0002, 0x0502, 0x800a, 0x900a, 0x8001, 0x8401 }) |b| {
        try memory.writeInt(0x1000, 16, b);
        var state = @import("state.zig").State{ .architecture = .riscv64, .flags = .{ .carry = true, .zero = true, .overflow = true } };
        for (1..32) |r| state.set(@intCast(r), 0xfeedface);
        const saved = state;
        _ = try @import("../interpreter.zig").execute(&state, &memory, try decode(&memory, 0x1000));
        try std.testing.expectEqualSlices(u64, &saved.registers, &state.registers);
        try std.testing.expect(std.meta.eql(saved.flags, state.flags));
        try std.testing.expectEqual(@as(u64, 0x1002), state.pc);
        try std.testing.expectEqual(@as(u64, 1), state.instructions);
    }
    try memory.writeInt(0x1ffe, 16, 1); // C.NOP fits at the end of an executable page.
    try std.testing.expectEqual(@as(u64, 0x2000), (try decode(&memory, 0x1ffe)).next);
    try memory.writeInt(0x1002, 32, 0xfff00593);
    try std.testing.expectEqual(@as(u64, 0x1006), (try decode(&memory, 0x1002)).next);
    try std.testing.expectError(error.MisalignedInstruction, decode(&memory, 0x1001));
    try memory.writeInt(0x1ffe, 16, 0x13); // A 32-bit instruction needs its second half.
    try std.testing.expectError(error.UnmappedMemory, decode(&memory, 0x1ffe));
    try memory.map(0x2000, 4096, .{ .read = true });
    try std.testing.expectError(error.PermissionDenied, decode(&memory, 0x1ffe));
}

fn atomicCode(kind: u5, width: u7, order: u2, rd: u6, rs1: u6, rs2: u6) u32 {
    return registers((@as(u32, kind) << 27) | (@as(u32, order) << 25) | (if (width == 32) @as(u32, 0x202f) else 0x302f), rd, rs1, rs2);
}
test "RISC-V word/doubleword AMOs preserve signed returns, aliases and flags" {
    const State = @import("state.zig").State;
    const execute = @import("../interpreter.zig").execute;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.map(0x2000, 4096, .{ .read = true, .write = true });
    for ([_]u7{ 32, 64 }) |width| {
        const sign: u64 = @as(u64, 1) << @as(u6, @intCast(width - 1));
        const old = sign | 3;
        const returns: u64 = @bitCast(ir.signed(old, width));
        for ([_][2]u64{ .{ 1, 5 }, .{ 0, sign | 8 }, .{ 4, sign | 6 }, .{ 12, 1 }, .{ 8, sign | 7 }, .{ 16, old }, .{ 20, 5 }, .{ 24, 5 }, .{ 28, old } }) |case| {
            for (0..4) |order| {
                try memory.writeInt(0x1000, 32, atomicCode(@intCast(case[0]), width, @intCast(order), 9, 12, 15));
                try memory.writeInt(0x2000, 64, if (width == 32) 0xbad00bad80000003 else old);
                var state = State{ .architecture = .riscv64, .pc = 0x1000, .flags = .{ .carry = true, .zero = true, .overflow = true } };
                state.set(12, 0x2000);
                state.set(15, if (width == 32) 0xdeadbeef00000005 else 5);
                const flags = state.flags;
                _ = try execute(&state, &memory, try decode(&memory, 0x1000));
                try std.testing.expectEqual(case[1], try memory.readInt(0x2000, width, .read));
                try std.testing.expectEqual(returns, state.get(9));
                try std.testing.expect(std.meta.eql(flags, state.flags));
                if (width == 32) try std.testing.expectEqual(@as(u64, 0xbad00bad), try memory.readInt(0x2004, 32, .read));
            }
        }
    }
    for ([_]u6{ 0, 12, 15 }) |rd| {
        try memory.writeInt(0x1000, 32, atomicCode(1, 64, 3, rd, 12, 15));
        try memory.writeInt(0x2000, 64, 37);
        var state = State{ .architecture = .riscv64 };
        state.set(12, 0x2000);
        state.set(15, 99);
        _ = try execute(&state, &memory, try decode(&memory, 0x1000));
        try std.testing.expectEqual(@as(u64, 99), try memory.readInt(0x2000, 64, .read));
        try std.testing.expectEqual(@as(u64, if (rd == 0) 0 else 37), state.get(rd));
    }
}

test "RISC-V LR/SC validates reservations, permissions, alignment and encodings" {
    const State = @import("state.zig").State;
    const execute = @import("../interpreter.zig").execute;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.map(0x2000, 4096, .{ .read = true, .write = true });
    try std.testing.expectEqual(@as(u32, 0x160624af), atomicCode(2, 32, 3, 9, 12, 0)); // First previously failing musl instruction.
    for ([_]u7{ 32, 64 }) |width| {
        for (0..4) |order| {
            try memory.writeInt(0x1000, 32, atomicCode(2, width, @intCast(order), 9, 12, 0));
            try memory.writeInt(0x1004, 32, atomicCode(3, width, @intCast(order), 8, 12, 15));
            const load = try decode(&memory, 0x1000);
            const conditional = try decode(&memory, 0x1004);
            const value: u64 = if (width == 32) 0x80000000 else 0x8000000000000000;
            try memory.writeInt(0x2000, width, value);
            var state = State{ .architecture = .riscv64 };
            state.set(12, 0x2000);
            state.set(15, 0xabcdef00000009);
            _ = try execute(&state, &memory, load);
            try std.testing.expectEqual(@as(u64, @bitCast(ir.signed(value, width))), state.get(9));
            _ = try execute(&state, &memory, conditional);
            try std.testing.expectEqual(@as(u64, 0), state.get(8));
            try std.testing.expectEqual(state.get(15) & ir.mask(width), try memory.readInt(0x2000, width, .read));
            try std.testing.expect(state.exclusive == null);
            _ = try execute(&state, &memory, conditional);
            try std.testing.expectEqual(@as(u64, 1), state.get(8));
            _ = try execute(&state, &memory, load);
            try memory.writeInt(0x2010, 8, 1);
            _ = try execute(&state, &memory, conditional);
            try std.testing.expectEqual(@as(u64, 1), state.get(8));
            _ = try execute(&state, &memory, load);
            try memory.protect(0x2000, 4096, .{ .read = true, .write = true });
            _ = try execute(&state, &memory, conditional);
            try std.testing.expectEqual(@as(u64, 1), state.get(8));
        }
    }
    for ([_]u5{ 0, 2, 3 }) |kind| {
        try memory.writeInt(0x1000, 32, atomicCode(kind, 32, 3, 9, 12, if (kind == 2) 0 else 15));
        const instruction = try decode(&memory, 0x1000);
        var state = State{ .architecture = .riscv64, .pc = 0x1000 };
        state.set(9, 0xfeed);
        state.set(12, 0x2001);
        const saved = state;
        try std.testing.expectError(error.MisalignedMemory, execute(&state, &memory, instruction));
        try std.testing.expect(std.meta.eql(saved, state));
        state.set(12, 0x2000);
        try memory.protect(0x2000, 4096, .{ .read = true });
        if (kind == 2) {
            _ = try execute(&state, &memory, instruction);
        } else {
            const before = state;
            try std.testing.expectError(error.PermissionDenied, execute(&state, &memory, instruction));
            try std.testing.expect(std.meta.eql(before, state));
        }
        try memory.protect(0x2000, 4096, .{ .read = true, .write = true });
    }
    for ([_]u32{ 0x2f, atomicCode(2, 32, 0, 9, 12, 15) }) |invalid| {
        try memory.writeInt(0x1000, 32, invalid);
        try std.testing.expectError(error.InvalidInstruction, decode(&memory, 0x1000));
    }
    try memory.writeInt(0x1000, 32, atomicCode(5, 32, 0, 9, 12, 15));
    try std.testing.expectError(error.UnsupportedInstruction, decode(&memory, 0x1000));
}
