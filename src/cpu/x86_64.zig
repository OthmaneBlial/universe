const std = @import("std");
const ir = @import("../ir.zig");
const Memory = @import("../memory.zig").Memory;
const Cursor = struct {
    memory: *Memory,
    pc: u64,
    start: u64,
    rex: u8 = 0,
    word: bool = false,
    address32: bool = false,
    segment: @FieldType(ir.Address, "segment") = .none,
    fn byte(c: *Cursor) !u8 {
        if (c.pc - c.start >= 15) return error.InstructionTooLong;
        const b: u8 = @intCast(try c.memory.readInt(c.pc, 8, .execute));
        c.pc +%= 1;
        return b;
    }
    fn number(c: *Cursor, width: u7) !u64 {
        var v: u64 = 0;
        for (0..width / 8) |i| v |= @as(u64, try c.byte()) << @as(u6, @intCast(i * 8));
        return v;
    }
    fn displacement(c: *Cursor, width: u7) !i64 {
        return ir.signed(try c.number(width), width);
    }
    fn register(c: Cursor, code: u8, extension: u8, width: u7) ir.Operand {
        if (width == 8 and c.rex == 0 and code >= 4 and code <= 7) return .{ .reg = .{ .index = @intCast(code - 4), .high = true } };
        return ir.reg(@intCast(code | extension));
    }
    fn operands(c: *Cursor, width: u7) !struct { rm: ir.Operand, reg: ir.Operand, group: u3, byte: u8 } {
        const b = try c.byte();
        const mode = b >> 6;
        const r = (b >> 3) & 7;
        const rm = b & 7;
        const regop = c.register(r, if (c.rex & 4 != 0) 8 else 0, width);
        if (mode == 3) return .{ .rm = c.register(rm, if (c.rex & 1 != 0) 8 else 0, width), .reg = regop, .group = @intCast(r), .byte = b };
        var a = ir.Address{ .segment = c.segment, .width = if (c.address32) 32 else 64 };
        if (rm == 4) {
            const sib = try c.byte();
            const base = sib & 7;
            const index = (sib >> 3) & 7;
            a.scale = @intCast(sib >> 6);
            if (index != 4 or c.rex & 2 != 0) a.index = @intCast(index | (if (c.rex & 2 != 0) @as(u8, 8) else 0));
            if (base == 5 and mode == 0) a.displacement = try c.displacement(32) else a.base = @intCast(base | (if (c.rex & 1 != 0) @as(u8, 8) else 0));
        } else if (rm == 5 and mode == 0) {
            a.relative = true;
            a.displacement = try c.displacement(32);
        } else a.base = @intCast(rm | (if (c.rex & 1 != 0) @as(u8, 8) else 0));
        if (mode == 1) a.displacement += try c.displacement(8);
        if (mode == 2) a.displacement += try c.displacement(32);
        return .{ .rm = .{ .mem = a }, .reg = regop, .group = @intCast(r), .byte = b };
    }
};
fn condition(code: u4) ir.Condition {
    return switch (code) {
        0 => .overflow,
        1 => .no_overflow,
        2 => .below,
        3 => .above_equal,
        4 => .eq,
        5 => .ne,
        6 => .below_equal,
        7 => .above,
        8 => .sign,
        9 => .no_sign,
        10 => .parity,
        11 => .no_parity,
        12 => .lt,
        13 => .ge,
        14 => .le,
        15 => .gt,
    };
}
fn arithmetic(group: u3) ir.Op {
    return switch (group) {
        0 => .add,
        1 => .or_,
        2 => .adc,
        3 => .sbb,
        4 => .and_,
        5 => .sub,
        6 => .xor,
        7 => .cmp,
    };
}
pub fn decode(m: *Memory, pc: u64) !ir.Instruction {
    var c = Cursor{ .memory = m, .pc = pc, .start = pc };
    var op = try c.byte();
    var repeat: u8 = 0;
    var locked = false;
    while (true) {
        if (op >= 0x40 and op <= 0x4f) c.rex = op else if (op == 0x64 or op == 0x65) {
            c.segment = if (op == 0x64) .fs else .gs;
            c.rex = 0;
        } else if (op == 0x2e or op == 0x3e or op == 0x26 or op == 0x36) {
            c.rex = 0;
        } else if (op == 0x66) {
            c.word = true;
            c.rex = 0;
        } else if (op == 0x67) {
            c.address32 = true;
            c.rex = 0;
        } else if (op == 0xf0) {
            locked = true;
            c.rex = 0;
        } else if (op == 0xf3 or op == 0xf2) {
            repeat = op;
            c.rex = 0;
        } else break;
        op = try c.byte();
    }
    const string = op == 0xa4 or op == 0xa5 or op == 0xa6 or op == 0xa7 or (op >= 0xaa and op <= 0xaf);
    if (repeat != 0 and op != 0x0f and !string and op != 0x90 and !(repeat == 0xf3 and op == 0xc3)) return error.UnsupportedRepeatPrefix;
    const w: u7 = if (c.rex & 8 != 0) 64 else if (c.word) 16 else 32;
    var i = ir.Instruction{ .op = .nop, .width = w, .pc = pc };
    if (op <= 0x3d and op & 7 <= 5) {
        i.op = arithmetic(@intCast(op >> 3));
        if (op & 7 <= 3) {
            i.width = if (op & 1 == 0) 8 else w;
            const operands = try c.operands(i.width);
            i.dst = if (op & 2 == 0) operands.rm else operands.reg;
            i.src = if (op & 2 == 0) operands.reg else operands.rm;
        } else {
            i.width = if (op & 1 == 0) 8 else w;
            i.dst = ir.reg(0);
            const iw: u7 = if (i.width == 64) 32 else i.width;
            const v = try c.number(iw);
            i.src = ir.imm(if (i.width == 64) @bitCast(ir.signed(v, 32)) else v);
        }
    } else switch (op) {
        0x50...0x57 => {
            i.op = .push;
            i.width = if (c.word) 16 else 64;
            i.src = c.register(op - 0x50, if (c.rex & 1 != 0) 8 else 0, i.width);
        },
        0x58...0x5f => {
            i.op = .pop;
            i.width = if (c.word) 16 else 64;
            i.dst = c.register(op - 0x58, if (c.rex & 1 != 0) 8 else 0, i.width);
        },
        0x63 => {
            const o = try c.operands(32);
            i.op = .movsx;
            i.dst = o.reg;
            i.src = o.rm;
            i.source_width = 32;
        },
        0x68, 0x6a => {
            i.op = .push;
            i.width = if (c.word) 16 else 64;
            i.src = ir.imm(@bitCast(try c.displacement(if (op == 0x6a) 8 else if (c.word) 16 else 32)));
        },
        0x69, 0x6b => {
            const o = try c.operands(w);
            i.op = .imul;
            i.dst = o.reg;
            i.lhs = o.rm;
            i.src = ir.imm(@bitCast(try c.displacement(if (op == 0x6b) 8 else if (w == 16) 16 else 32)));
        },
        0x70...0x7f => {
            i.op = .branch;
            i.condition = condition(@intCast(op & 15));
            const d = try c.displacement(8);
            i.src = ir.imm(c.pc +% @as(u64, @bitCast(d)));
        },
        0x80, 0x81, 0x83 => {
            i.width = if (op == 0x80) 8 else w;
            const o = try c.operands(i.width);
            i.op = arithmetic(o.group);
            i.dst = o.rm;
            const iw: u7 = if (op == 0x83) 8 else if (i.width == 64) 32 else i.width;
            const v = try c.number(iw);
            i.src = ir.imm(if (iw < i.width) @bitCast(ir.signed(v, iw)) else v);
        },
        0x84, 0x85 => {
            i.op = .test_;
            i.width = if (op == 0x84) 8 else w;
            const o = try c.operands(i.width);
            i.dst = o.rm;
            i.src = o.reg;
        },
        0x86, 0x87 => {
            i.op = .exchange;
            i.width = if (op == 0x86) 8 else w;
            const o = try c.operands(i.width);
            i.dst = o.rm;
            i.src = o.reg;
        },
        0x88...0x8b => {
            i.op = .mov;
            i.width = if (op & 1 == 0) 8 else w;
            const o = try c.operands(i.width);
            i.dst = if (op & 2 == 0) o.rm else o.reg;
            i.src = if (op & 2 == 0) o.reg else o.rm;
        },
        0x8d => {
            const o = try c.operands(w);
            if (o.rm != .mem) return error.InvalidInstruction;
            i.op = .lea;
            i.dst = o.reg;
            i.src = o.rm;
        },
        0x8f => {
            const o = try c.operands(if (c.word) 16 else 64);
            if (o.group != 0) return error.UnsupportedInstruction;
            i.op = .pop;
            i.width = if (c.word) 16 else 64;
            i.dst = o.rm;
        },
        0x90...0x97 => {
            if (op != 0x90 or c.rex & 1 != 0) {
                i.op = .exchange;
                i.dst = ir.reg(0);
                i.src = c.register(op - 0x90, if (c.rex & 1 != 0) 8 else 0, w);
                i.set_flags = false;
            }
        },
        0x98 => {
            i.op = .movsx;
            i.dst = ir.reg(0);
            i.src = ir.reg(0);
            i.source_width = w / 2;
        },
        0x99 => {
            i.op = .sign_extend;
        },
        0xa4...0xa7, 0xaa...0xaf => {
            i.width = if (op & 1 == 0) 8 else w;
            i.address_width = if (c.address32) 32 else 64;
            const source = ir.Operand{ .mem = .{ .index = 6, .index_width = i.address_width, .segment = c.segment } };
            const destination = ir.Operand{ .mem = .{ .index = 7, .index_width = i.address_width } };
            i.op = switch (op & 0xfe) {
                0xa4 => .string_move,
                0xa6 => .string_compare,
                0xaa => .string_store,
                0xac => .string_load,
                0xae => .string_scan,
                else => unreachable,
            };
            i.dst = if (i.op == .string_load or i.op == .string_scan) ir.reg(0) else if (i.op == .string_compare) source else destination;
            i.src = if (i.op == .string_store) ir.reg(0) else if (i.op == .string_scan or i.op == .string_compare) destination else source;
            if (repeat != 0) i.repeat = if (i.op != .string_compare and i.op != .string_scan) .count else if (repeat == 0xf3) .equal else .not_equal;
        },
        0xa8, 0xa9 => {
            i.op = .test_;
            i.width = if (op == 0xa8) 8 else w;
            i.dst = ir.reg(0);
            const iw: u7 = if (i.width == 64) 32 else i.width;
            i.src = ir.imm(@bitCast(ir.signed(try c.number(iw), iw)));
        },
        0xb0...0xbf => {
            i.op = .mov;
            i.width = if (op < 0xb8) 8 else w;
            i.dst = c.register(op & 7, if (c.rex & 1 != 0) 8 else 0, i.width);
            i.src = ir.imm(try c.number(i.width));
        },
        0xc0, 0xc1, 0xd0...0xd3 => {
            i.width = if (op & 1 == 0) 8 else w;
            const o = try c.operands(i.width);
            i.dst = o.rm;
            i.op = switch (o.group) {
                0 => .rol,
                1 => .ror,
                4, 6 => .shl,
                5 => .shr,
                7 => .sar,
                else => return error.UnsupportedInstruction,
            };
            i.src = if (op == 0xc0 or op == 0xc1) ir.imm(try c.byte()) else if (op == 0xd0 or op == 0xd1) ir.imm(1) else ir.reg(1);
        },
        0xc2, 0xc3 => {
            i.op = .ret;
            i.width = 64;
            i.src = ir.imm(if (op == 0xc2) try c.number(16) else 0);
        },
        0xc6, 0xc7 => {
            i.op = .mov;
            i.width = if (op == 0xc6) 8 else w;
            const o = try c.operands(i.width);
            if (o.group != 0) return error.UnsupportedInstruction;
            i.dst = o.rm;
            const iw: u7 = if (i.width == 64) 32 else i.width;
            const v = try c.number(iw);
            i.src = ir.imm(if (i.width == 64) @bitCast(ir.signed(v, 32)) else v);
        },
        0xc9 => {
            i.op = .pop;
            i.dst = ir.reg(5);
            i.lhs = ir.reg(5);
            i.width = 64;
        },
        0xe8, 0xe9, 0xeb => {
            i.op = if (op == 0xe8) .call else .branch;
            i.width = 64;
            const d = try c.displacement(if (op == 0xeb) 8 else 32);
            i.src = ir.imm(c.pc +% @as(u64, @bitCast(d)));
        },
        0xf6, 0xf7 => {
            i.width = if (op == 0xf6) 8 else w;
            const o = try c.operands(i.width);
            i.dst = o.rm;
            i.op = switch (o.group) {
                0 => .test_,
                2 => .not_,
                3 => .neg,
                4 => .mul,
                5 => .imul,
                6 => .div,
                7 => .idiv,
                else => return error.UnsupportedInstruction,
            };
            if (o.group == 0) {
                const iw: u7 = if (i.width == 64) 32 else i.width;
                i.src = ir.imm(@bitCast(ir.signed(try c.number(iw), iw)));
            } else if (o.group >= 4) {
                i.src = o.rm;
                i.dst = .none;
            }
        },
        0xfc, 0xfd => {
            i.op = .direction;
            i.src = ir.imm(op & 1);
        },
        0xfe, 0xff => {
            i.width = if (op == 0xfe) 8 else w;
            const o = try c.operands(i.width);
            i.dst = o.rm;
            i.op = switch (o.group) {
                0 => .inc,
                1 => .dec,
                2 => .call,
                4 => .branch,
                6 => .push,
                else => return error.UnsupportedInstruction,
            };
            if (o.group >= 2) {
                if (op == 0xfe) return error.UnsupportedInstruction;
                i.src = o.rm;
                i.dst = .none;
                i.width = 64;
            }
        },
        0x9b => {
            i.op = .x87;
            i.width = 64;
            i.encoding = 0x9b;
        },
        0xd8...0xdf => {
            const o = try c.operands(64);
            i.encoding = (@as(u32, op) << 8) | o.byte;
            if (!@import("../x87.zig").supported(@intCast(i.encoding))) return error.UnsupportedInstruction;
            i.op = .x87;
            i.width = 64;
            if (o.rm == .mem and (op == 0xd9 or op == 0xdd) and (o.group == 4 or o.group == 6)) i.width = if (c.word) 16 else 32;
            if (o.rm == .mem) i.src = o.rm;
        },
        0x0f => try decodeExtended(&c, &i, w, repeat),
        else => return error.UnsupportedInstruction,
    }
    if (locked) {
        if (i.dst != .mem) return error.InvalidLockPrefix;
        switch (i.op) {
            .add, .sub, .adc, .sbb, .and_, .or_, .xor, .inc, .dec, .neg, .not_, .xadd, .cmpxchg, .cmpxchg_pair, .exchange, .bit_set, .bit_reset, .bit_complement => {},
            else => return error.InvalidLockPrefix,
        }
    }
    i.next = c.pc;
    return i;
}

fn decodeExtended(c: *Cursor, i: *ir.Instruction, w: u7, repeat: u8) !void {
    const ext = try c.byte();
    const float_arithmetic = ext == 0x51 or ext == 0x58 or ext == 0x59 or ext == 0x5a or ext == 0x5b or ext == 0x5c or ext == 0x5d or ext == 0x5e or ext == 0x5f or ext == 0xc2 or ext == 0x2a or ext == 0x2c or ext == 0x2d or ext == 0xe6;
    const scalar_move = (ext == 0x10 or ext == 0x11) and (repeat == 0xf2 or repeat == 0xf3);
    const sse3_move = (ext == 0x12 and (repeat == 0xf2 or repeat == 0xf3)) or (ext == 0x16 and repeat == 0xf3) or (ext == 0xf0 and repeat == 0xf2);
    const sse3_arithmetic = (ext == 0x7c or ext == 0x7d or ext == 0xd0) and repeat == 0xf2;
    const popcnt = ext == 0xb8 and repeat == 0xf3;
    if (repeat != 0 and ext != 0x1e and ext != 0x38 and ext != 0x6f and ext != 0x7f and ext != 0x70 and ext != 0x7e and !(repeat == 0xf3 and (ext == 0xbc or ext == 0xbd)) and !(float_arithmetic and (repeat == 0xf2 or repeat == 0xf3)) and !scalar_move and !sse3_move and !sse3_arithmetic and !popcnt) return error.UnsupportedRepeatPrefix;
    if (!c.word and repeat == 0) switch (ext) {
        0x60...0x6b, 0x6e, 0x6f, 0x71...0x76, 0x7e, 0x7f, 0xd1, 0xd2, 0xd3, 0xd5, 0xd8, 0xd9, 0xdb, 0xdc, 0xdd, 0xdf, 0xe1, 0xe2, 0xe5, 0xe8, 0xe9, 0xeb, 0xec, 0xed, 0xef, 0xf1, 0xf2, 0xf3, 0xf5, 0xf8, 0xf9, 0xfa, 0xfc, 0xfd, 0xfe => return decodeMmx(c, i, ext),
        else => {},
    };
    switch (ext) {
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x28, 0x29, 0x2a, 0x2c, 0x2d, 0x2e, 0x2f, 0x50, 0x51, 0x54, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x7c, 0x7d, 0x7e, 0x7f, 0xc2, 0xc4, 0xc5, 0xc6, 0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe8, 0xe9, 0xea, 0xeb, 0xec, 0xed, 0xee, 0xef, 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe => try decodeVector(c, i, ext, repeat),
        0x77 => {
            i.op = .emms;
            i.set_flags = false;
        },
        0xae => {
            const o = try c.operands(64);
            if (o.rm == .reg and o.group >= 5 and !c.word and repeat == 0) {
                // Guest memory is synchronous on one thread; LFENCE/MFENCE/SFENCE
                // need no extra ordering until guest concurrency is implemented.
                i.op = .nop;
                return;
            }
            if (o.rm != .mem or o.group > 3) return error.UnsupportedInstruction;
            i.op = switch (o.group) {
                0 => .fxsave,
                1 => .fxrstor,
                2 => .ldmxcsr,
                3 => .stmxcsr,
                else => unreachable,
            };
            i.src = o.rm;
            i.width = if (c.rex & 8 != 0) 64 else 32;
            i.set_flags = false;
        },
        0x05 => {
            i.op = .syscall;
            i.width = 64;
        },
        0xa2 => {
            i.op = .cpuid;
            i.width = 32;
            i.set_flags = false;
        },
        0x31 => {
            i.op = .rdtsc;
            i.width = 32;
            i.set_flags = false;
        },
        0x38 => try decodeExtended38(c, i, repeat),
        0x3a => try decodeExtended3A(c, i, repeat),
        0x18 => {
            const o = try c.operands(64);
            if (o.rm != .mem or o.group > 3) return error.UnsupportedInstruction;
            // Cache prefetch hints do not read guest data or fault on their target.
        },
        0x1e => {
            const b = try c.byte();
            if (repeat != 0xf3 or (b != 0xfa and !(b >= 0xc8 and b <= 0xcf and !c.word))) return error.UnsupportedInstruction;
            // RDSSPD/Q is a NOP while CET shadow stacks are disabled.
        },
        0x1f => {
            const o = try c.operands(w);
            if (o.group != 0) return error.UnsupportedInstruction;
        },
        0x40...0x4f => {
            const o = try c.operands(w);
            i.op = .cmov;
            i.dst = o.reg;
            i.src = o.rm;
            i.condition = condition(@intCast(ext & 15));
        },
        0x80...0x8f => {
            i.op = .branch;
            i.condition = condition(@intCast(ext & 15));
            const d = try c.displacement(32);
            i.src = ir.imm(c.pc +% @as(u64, @bitCast(d)));
        },
        0x90...0x9f => {
            const o = try c.operands(8);
            i.op = .setcc;
            i.dst = o.rm;
            i.width = 8;
            i.condition = condition(@intCast(ext & 15));
        },
        0xa3, 0xab, 0xb3, 0xbb, 0xba => {
            const o = try c.operands(w);
            i.dst = o.rm;
            i.src = if (ext == 0xba) ir.imm(try c.byte()) else o.reg;
            const group = if (ext == 0xba) o.group else switch (ext) {
                0xa3 => @as(u3, 4),
                0xab => 5,
                0xb3 => 6,
                0xbb => 7,
                else => unreachable,
            };
            i.op = switch (group) {
                4 => .bit_test,
                5 => .bit_set,
                6 => .bit_reset,
                7 => .bit_complement,
                else => return error.InvalidInstruction,
            };
        },
        0xbc, 0xbd => {
            const o = try c.operands(w);
            i.op = if (repeat == 0xf3) (if (ext == 0xbc) .count_trailing_zeros else .count_leading_zeros) else if (ext == 0xbc) .bit_scan_forward else .bit_scan_reverse;
            i.dst = o.reg;
            i.src = o.rm;
        },
        0xb0, 0xb1, 0xc0, 0xc1 => {
            i.width = if (ext == 0xb0 or ext == 0xc0) 8 else w;
            const o = try c.operands(i.width);
            i.op = if (ext >= 0xc0) .xadd else .cmpxchg;
            i.dst = o.rm;
            i.src = o.reg;
        },
        0xc7 => {
            const o = try c.operands(64);
            if (o.group != 1 or o.rm != .mem) return error.UnsupportedInstruction;
            i.op = .cmpxchg_pair;
            i.width = 64;
            i.source_width = if (c.rex & 8 != 0) 64 else 32;
            i.dst = o.rm;
        },
        0xb8 => {
            if (repeat != 0xf3) return error.UnsupportedInstruction;
            const o = try c.operands(w);
            i.op = .popcount;
            i.dst = o.reg;
            i.src = o.rm;
        },
        0xc8...0xcf => {
            if (w == 16) return error.UnsupportedInstruction;
            i.op = .byte_swap;
            i.dst = ir.reg(@as(u6, @intCast(ext & 7)) | (if (c.rex & 1 != 0) @as(u6, 8) else 0));
        },
        0xaf => {
            const o = try c.operands(w);
            i.op = .imul;
            i.dst = o.reg;
            i.src = o.rm;
        },
        0xb6, 0xb7, 0xbe, 0xbf => {
            i.source_width = if (ext & 1 == 0) 8 else 16;
            const o = try c.operands(i.source_width);
            i.op = if (ext < 0xbe) .movzx else .movsx;
            i.dst = ir.reg(@as(u6, o.group) | (if (c.rex & 4 != 0) @as(u6, 8) else 0));
            i.src = o.rm;
        },
        else => return error.UnsupportedInstruction,
    }
}

fn decodeExtended38(c: *Cursor, i: *ir.Instruction, repeat: u8) !void {
    const ext = try c.byte();
    if (repeat == 0xf2 and (ext == 0xf0 or ext == 0xf1)) {
        const destination_width: u7 = if (c.rex & 8 != 0) 64 else 32;
        const source_width: u7 = if (ext == 0xf0) 8 else if (c.rex & 8 != 0) 64 else if (c.word) 16 else 32;
        const o = try c.operands(destination_width);
        var source = o.rm;
        if (source_width == 8 and c.rex == 0 and source == .reg and source.reg.index >= 4 and source.reg.index <= 7) {
            source.reg.index -= 4;
            source.reg.high = true;
        }
        i.op = .crc32;
        i.width = destination_width;
        i.source_width = source_width;
        i.dst = o.reg;
        i.src = source;
        i.set_flags = false;
        return;
    }
    const element: u4 = switch (ext) {
        0x10, 0x17, 0x2a => 1,
        0x14 => 4,
        0x15 => 8,
        0x00, 0x04, 0x08, 0x1c, 0x38, 0x3c => 1,
        0x01, 0x03, 0x05, 0x07, 0x09, 0x0b, 0x1d => 2,
        0x3a, 0x3e => 2,
        0x39, 0x3b, 0x3d, 0x3f, 0x40 => 4,
        0x02, 0x06 => 4,
        0x0a, 0x1e => 4,
        0x28, 0x37 => 8,
        0x29 => 8,
        0x2b, 0x41 => 2,
        0x20, 0x30 => 2,
        0x21, 0x23, 0x31, 0x33 => 4,
        0x22, 0x24, 0x25, 0x32, 0x34, 0x35 => 8,
        else => return error.UnsupportedInstruction,
    };
    if (!c.word or repeat != 0) return error.UnsupportedInstruction;
    const o = try c.operands(32);
    if (ext == 0x2a and o.rm == .reg) return error.UnsupportedInstruction;
    i.op = switch (ext) {
        0x2a => .vector_mov,
        0x10, 0x14, 0x15 => .vector_blend_variable,
        0x00 => .vector_shuffle_bytes,
        0x01, 0x02 => .vector_horizontal_add,
        0x03 => .vector_horizontal_add_saturate_signed,
        0x04 => .vector_madd_unsigned_signed_sat,
        0x05, 0x06 => .vector_horizontal_sub,
        0x07 => .vector_horizontal_sub_saturate_signed,
        0x08...0x0a => .vector_sign,
        0x0b => .vector_mul_high_round,
        0x1c...0x1e => .vector_abs,
        0x29 => .vector_compare_equal,
        0x37 => .vector_compare_greater_signed,
        0x38 => .vector_min_signed,
        0x3c => .vector_max_signed,
        0x39 => .vector_min_signed,
        0x3a => .vector_min_unsigned,
        0x3b => .vector_min_unsigned,
        0x3d => .vector_max_signed,
        0x3e => .vector_max_unsigned,
        0x3f => .vector_max_unsigned,
        0x40 => .vector_mul_low_dword,
        0x20...0x25, 0x30...0x35 => .vector_extend,
        0x17 => .vector_test,
        0x28 => .vector_mul_signed_even_dword,
        0x2b => .vector_pack_unsigned_word,
        0x41 => .vector_minpos_unsigned_word,
        else => unreachable,
    };
    const extends = (ext >= 0x20 and ext <= 0x25) or (ext >= 0x30 and ext <= 0x35);
    if (extends) {
        i.source_width = switch (ext & 0x0f) {
            0 => 64,
            1 => 32,
            2 => 16,
            3 => 64,
            4 => 32,
            5 => 64,
            else => unreachable,
        };
        i.sign_result = ext < 0x30;
    }
    i.vector_element = element;
    i.dst = .{ .vector = @intCast(o.reg.reg.index) };
    i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
    i.vector_aligned = !(extends or ext == 0x10 or ext == 0x14 or ext == 0x15 or ext == 0x17 or ext == 0x28 or ext == 0x2b or ext == 0x41);
    i.set_flags = ext == 0x17;
}

fn decodeExtended3A(c: *Cursor, i: *ir.Instruction, repeat: u8) !void {
    const ext = try c.byte();
    if (!c.word or repeat != 0) return error.UnsupportedInstruction;
    switch (ext) {
        0x08...0x0b => {
            const o = try c.operands(32);
            i.op = .vector_round;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = if (ext == 0x09 or ext == 0x0b) 8 else 4;
            i.vector_bytes = if (ext == 0x0a) 4 else if (ext == 0x0b) 8 else 16;
            i.shuffle = try c.byte();
        },
        0x0c...0x0f => {
            const o = try c.operands(32);
            i.op = if (ext == 0x0f) .vector_align_right else .vector_blend;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = switch (ext) {
                0x0c => 4,
                0x0d => 8,
                0x0e => 2,
                else => 1,
            };
            i.shuffle = try c.byte();
            i.vector_aligned = ext == 0x0f;
        },
        0x40, 0x41 => {
            const o = try c.operands(32);
            i.op = .vector_dot;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = if (ext == 0x40) 4 else 8;
            i.shuffle = try c.byte();
        },
        0x14...0x17 => {
            const element: u4 = switch (ext) {
                0x14 => 1,
                0x15 => 2,
                0x16 => if (c.rex & 8 != 0) 8 else 4,
                0x17 => 4,
                else => unreachable,
            };
            const source_width: u7 = @as(u7, element) * 8;
            const o = try c.operands(64);
            i.op = .vector_to_scalar;
            i.dst = o.rm;
            i.src = .{ .vector = @intCast(o.reg.reg.index) };
            i.source_width = source_width;
            i.width = if (o.rm == .reg) (if (element == 8) 64 else 32) else source_width;
            i.vector_index = @intCast((try c.byte()) & (16 / @as(u8, element) - 1));
        },
        0x20, 0x22 => {
            const element: u4 = if (ext == 0x20) 1 else if (c.rex & 8 != 0) 8 else 4;
            const o = try c.operands(if (element == 8) 64 else 32);
            i.op = .vector_insert_lane;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = o.rm;
            i.vector_element = element;
            i.vector_index = @intCast((try c.byte()) & (16 / @as(u8, element) - 1));
            i.vector_aligned = false;
        },
        0x21 => {
            const o = try c.operands(32);
            i.op = .vector_insert_ps;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.shuffle = try c.byte();
            i.vector_aligned = false;
        },
        0x42 => {
            const o = try c.operands(32);
            i.op = .vector_mpsadbw;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.shuffle = try c.byte();
            i.vector_aligned = false;
        },
        else => return error.UnsupportedInstruction,
    }
    i.set_flags = false;
}

fn decodeMmx(c: *Cursor, i: *ir.Instruction, ext: u8) !void {
    // Original MMX operations have the same lane semantics as their 66-prefixed SSE forms.
    c.word = true;
    defer c.word = false;
    try decodeVector(c, i, ext, 0);
    if (i.op == .vector_byte_shl or i.op == .vector_byte_shr) return error.InvalidInstruction;
    i.vector_bytes = 8;
    i.vector_aligned = false;
    if (i.dst == .vector) i.dst.vector = 16 + (i.dst.vector & 7);
    if (i.src == .vector) i.src.vector = 16 + (i.src.vector & 7);
}

fn decodeVector(c: *Cursor, i: *ir.Instruction, ext: u8, repeat: u8) !void {
    const float_arithmetic = ext == 0x51 or ext == 0x58 or ext == 0x59 or ext == 0x5a or ext == 0x5b or ext == 0x5c or ext == 0x5d or ext == 0x5e or ext == 0x5f or ext == 0xc2 or ext == 0x2a or ext == 0x2c or ext == 0x2d or ext == 0xe6;
    const scalar_move = (ext == 0x10 or ext == 0x11) and (repeat == 0xf2 or repeat == 0xf3);
    const sse3_move = (ext == 0x12 and (repeat == 0xf2 or repeat == 0xf3)) or (ext == 0x16 and repeat == 0xf3) or (ext == 0xf0 and repeat == 0xf2);
    if (c.word and repeat != 0 and !float_arithmetic and !scalar_move and !sse3_move) return error.UnsupportedRepeatPrefix;
    switch (ext) {
        0x7c, 0x7d, 0xd0 => {
            if (!(repeat == 0xf2 and !c.word) and !(repeat == 0 and c.word)) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = switch (ext) {
                0x7c => .vector_float_horizontal_add,
                0x7d => .vector_float_horizontal_sub,
                0xd0 => .vector_float_add_sub,
                else => unreachable,
            };
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = if (repeat == 0xf2) 4 else 8;
            i.vector_bytes = 16;
            i.vector_aligned = false;
            i.set_flags = false;
        },
        0x12, 0x13, 0x16, 0x17 => {
            const o = try c.operands(64);
            const regop = ir.Operand{ .vector = @intCast(o.reg.reg.index) };
            const rmop: ir.Operand = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            if (sse3_move) {
                if (c.word) return error.UnsupportedInstruction;
                i.op = .vector_duplicate_lanes;
                i.dst = regop;
                i.src = rmop;
                i.vector_element = if (ext == 0x12 and repeat == 0xf2) 8 else 4;
                i.vector_high = ext == 0x16;
            } else {
                if (repeat != 0 or ((c.word or ext & 1 != 0) and o.rm == .reg)) return error.UnsupportedInstruction;
                i.width = 64;
                i.vector_element = 8;
                if (ext & 1 == 0) {
                    i.op = .vector_insert_lane;
                    i.dst = regop;
                    i.src = rmop;
                    i.vector_index = if (ext == 0x16) 1 else 0;
                    i.vector_high = ext == 0x12 and o.rm == .reg;
                } else {
                    i.op = .vector_to_scalar;
                    i.dst = o.rm;
                    i.src = regop;
                    i.vector_index = if (ext == 0x17) 1 else 0;
                }
            }
            i.set_flags = false;
        },
        0xf0 => {
            if (c.word or repeat != 0xf2) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            if (o.rm != .mem) return error.UnsupportedInstruction;
            i.op = .vector_mov;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = o.rm;
            i.vector_bytes = 16;
            i.vector_aligned = false;
            i.set_flags = false;
        },
        0x10, 0x11 => if (scalar_move) {
            if (c.word) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            const regop = ir.Operand{ .vector = @intCast(o.reg.reg.index) };
            const rmop: ir.Operand = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.op = .vector_move_scalar;
            i.dst = if (ext == 0x10) regop else rmop;
            i.src = if (ext == 0x10) rmop else regop;
            i.vector_element = if (repeat == 0xf3) 4 else 8;
            i.vector_bytes = @intCast(i.vector_element);
            i.set_flags = false;
        } else {
            const o = try c.operands(32);
            const regop = ir.Operand{ .vector = @intCast(o.reg.reg.index) };
            const rmop: ir.Operand = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.op = .vector_mov;
            i.vector_aligned = false;
            i.set_flags = false;
            i.dst = if (ext == 0x11) rmop else regop;
            i.src = if (ext == 0x11) regop else rmop;
        },
        0x2a => {
            if (c.word or repeat != 0xf2 and repeat != 0xf3) return error.UnsupportedInstruction;
            const width: u7 = if (c.rex & 8 != 0) 64 else 32;
            const o = try c.operands(width);
            i.op = .vector_int_to_float;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = o.rm;
            i.width = width;
            i.vector_element = if (repeat == 0xf2) 8 else 4;
            i.vector_bytes = @as(u5, i.vector_element);
            i.set_flags = false;
        },
        0x2c, 0x2d => {
            if (c.word or repeat != 0xf2 and repeat != 0xf3) return error.UnsupportedInstruction;
            const width: u7 = if (c.rex & 8 != 0) 64 else 32;
            const o = try c.operands(width);
            i.op = if (ext == 0x2c) .vector_float_to_int_trunc else .vector_float_to_int;
            i.dst = o.reg;
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.width = width;
            i.vector_element = if (repeat == 0xf2) 8 else 4;
            i.vector_bytes = @as(u5, i.vector_element);
            i.set_flags = false;
        },
        0x5b => {
            if (c.word and repeat != 0 or !c.word and repeat != 0 and repeat != 0xf3) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = if (c.word) .vector_packed_float_to_int else if (repeat == 0xf3) .vector_packed_float_to_int_trunc else .vector_packed_int_to_float;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = 4;
            i.vector_bytes = 16;
            i.set_flags = false;
        },
        0x5a => {
            const op: ir.Op = if (!c.word and repeat == 0) .vector_float_to_double else if (c.word and repeat == 0) .vector_double_to_float else if (!c.word and repeat == 0xf3) .vector_float_to_double_scalar else if (!c.word and repeat == 0xf2) .vector_double_to_float_scalar else return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = op;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = 4;
            i.vector_bytes = 16;
            i.set_flags = false;
        },
        0xe6 => {
            i.op = if (c.word and repeat == 0) .vector_packed_double_to_int_trunc else if (repeat == 0xf2 and !c.word) .vector_packed_double_to_int else if (repeat == 0xf3 and !c.word) .vector_packed_int_to_double else return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_bytes = 16;
            i.set_flags = false;
        },
        0x2e, 0x2f => {
            if (repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = .vector_float_compare_flags;
            i.sign_result = ext == 0x2f; // COMI signals on quiet NaNs; UCOMI only on signaling NaNs.
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = if (c.word) 8 else 4;
            i.vector_bytes = @as(u5, i.vector_element);
            i.set_flags = false;
        },
        0x51, 0x58, 0x59, 0x5c, 0x5d, 0x5e, 0x5f => {
            if (repeat != 0 and repeat != 0xf2 and repeat != 0xf3 or c.word and repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = switch (ext) {
                0x58 => .vector_float_add,
                0x5c => .vector_float_sub,
                0x59 => .vector_float_mul,
                0x5e => .vector_float_div,
                0x51 => .vector_float_sqrt,
                0x5d => .vector_float_min,
                0x5f => .vector_float_max,
                else => unreachable,
            };
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = if (c.word or repeat == 0xf2) 8 else 4;
            i.vector_bytes = if (repeat == 0) 16 else @as(u5, i.vector_element);
            i.set_flags = false;
        },
        0x14, 0x15 => {
            if (repeat != 0) return error.UnsupportedRepeatPrefix;
            const o = try c.operands(32);
            i.op = if (ext == 0x14) .vector_unpack_low else .vector_unpack_high;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = if (c.word) 8 else 4;
            i.vector_aligned = true;
            i.set_flags = false;
        },
        0x50 => {
            if (repeat != 0) return error.UnsupportedRepeatPrefix;
            const o = try c.operands(32);
            if (o.rm != .reg) return error.InvalidInstruction;
            i.op = .vector_mask;
            i.dst = o.reg;
            i.src = .{ .vector = @intCast(o.rm.reg.index) };
            i.vector_element = if (c.word) 8 else 4;
            i.width = 32;
            i.set_flags = false;
        },
        0xc6 => {
            if (repeat != 0) return error.UnsupportedRepeatPrefix;
            const o = try c.operands(32);
            i.op = .vector_shuffle_pair;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = if (c.word) 8 else 4;
            i.shuffle = try c.byte();
            i.vector_aligned = true;
            i.set_flags = false;
        },
        0xc2 => {
            if (repeat != 0 and repeat != 0xf2 and repeat != 0xf3 or c.word and repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = .vector_float_compare;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.shuffle = try c.byte();
            if (i.shuffle & 0xf8 != 0) return error.InvalidInstruction;
            i.vector_element = if (c.word or repeat == 0xf2) 8 else 4;
            i.vector_bytes = if (repeat == 0) 16 else @as(u5, i.vector_element);
            i.set_flags = false;
        },
        0xc4 => {
            if (!c.word or repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = .vector_insert_lane;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = o.rm;
            i.vector_element = 2;
            i.vector_index = @intCast((try c.byte()) & 7);
            i.set_flags = false;
        },
        0x63, 0x67, 0x6b => {
            if (!c.word or repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = switch (ext) {
                0x63 => .vector_pack_signed_byte,
                0x67 => .vector_pack_unsigned_byte,
                0x6b => .vector_pack_signed_word,
                else => unreachable,
            };
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_aligned = true;
            i.set_flags = false;
        },
        0xe0, 0xe3, 0xf6 => {
            if (!c.word or repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = if (ext == 0xf6) .vector_sum_abs_diff else .vector_average_unsigned;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = if (ext == 0xe3) 2 else 1;
            i.vector_aligned = true;
            i.set_flags = false;
        },
        0xd1, 0xd2, 0xd3, 0xe1, 0xe2, 0xf1, 0xf2, 0xf3 => {
            if (!c.word or repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = switch (ext) {
                0xd1, 0xd2, 0xd3 => .vector_shr,
                0xe1, 0xe2 => .vector_sar,
                else => .vector_shl,
            };
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = switch (ext) {
                0xd1, 0xe1, 0xf1 => 2,
                0xd2, 0xe2, 0xf2 => 4,
                0xd3, 0xf3 => 8,
                else => unreachable,
            };
            i.vector_aligned = true;
            i.set_flags = false;
        },
        0xc5 => {
            if (!c.word or repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            if (o.rm != .reg) return error.InvalidInstruction;
            i.op = .vector_to_scalar;
            i.dst = o.reg;
            i.src = .{ .vector = @intCast(o.rm.reg.index) };
            i.width = 32;
            i.source_width = 16;
            i.vector_index = @intCast((try c.byte()) & 7);
            i.set_flags = false;
        },
        0x71, 0x72, 0x73 => {
            if (!c.word or repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            if (o.rm != .reg) return error.InvalidInstruction;
            i.dst = .{ .vector = @intCast(o.rm.reg.index) };
            i.src = ir.imm(try c.byte());
            i.set_flags = false;
            i.vector_element = @as(u4, 2) << @as(u2, @intCast(ext - 0x71));
            i.op = switch (o.group) {
                2 => .vector_shr,
                4 => if (ext == 0x73) return error.InvalidInstruction else .vector_sar,
                6 => .vector_shl,
                3 => if (ext == 0x73) .vector_byte_shr else return error.InvalidInstruction,
                7 => if (ext == 0x73) .vector_byte_shl else return error.InvalidInstruction,
                else => return error.InvalidInstruction,
            };
        },
        0xd4, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xd8, 0xd9, 0xdc, 0xdd, 0xe8, 0xe9, 0xec, 0xed => {
            if (!c.word or repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = switch (ext) {
                0xd4, 0xfc, 0xfd, 0xfe => .vector_add,
                0xdc, 0xdd => .vector_add_saturate_unsigned,
                0xec, 0xed => .vector_add_saturate_signed,
                0xd8, 0xd9 => .vector_sub_saturate_unsigned,
                0xe8, 0xe9 => .vector_sub_saturate_signed,
                else => .vector_sub,
            };
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_element = switch (ext) {
                0xf8, 0xfc, 0xd8, 0xdc, 0xe8, 0xec => 1,
                0xf9, 0xfd, 0xd9, 0xdd, 0xe9, 0xed => 2,
                0xfa, 0xfe => 4,
                0xd4, 0xfb => 8,
                else => unreachable,
            };
            i.set_flags = false;
        },
        0xd5, 0xe4, 0xe5, 0xf4, 0xf5 => {
            if (!c.word or repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = switch (ext) {
                0xd5 => .vector_mul_low,
                0xe4 => .vector_mul_high_unsigned,
                0xe5 => .vector_mul_high_signed,
                0xf4 => .vector_mul_even_unsigned,
                0xf5 => .vector_madd_signed,
                else => unreachable,
            };
            if (ext == 0xd5) i.vector_element = 2;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.vector_aligned = true;
            i.set_flags = false;
        },
        0x64, 0x65, 0x66, 0x74, 0x75, 0x76, 0xd7, 0xda, 0xde, 0xea, 0xee => {
            if (!c.word or repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.set_flags = false;
            if (ext == 0xda or ext == 0xde or ext == 0xea or ext == 0xee) {
                i.op = switch (ext) {
                    0xda => .vector_min_unsigned,
                    0xde => .vector_max_unsigned,
                    0xea => .vector_min_signed,
                    0xee => .vector_max_signed,
                    else => unreachable,
                };
                i.vector_element = if (ext == 0xda or ext == 0xde) 1 else 2;
                i.dst = .{ .vector = @intCast(o.reg.reg.index) };
                i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
                i.vector_aligned = true;
            } else if (ext == 0xd7) {
                if (o.rm != .reg) return error.InvalidInstruction;
                i.op = .vector_mask;
                i.width = 32;
                i.dst = o.reg;
                i.src = .{ .vector = @intCast(o.rm.reg.index) };
            } else {
                i.op = if (ext < 0x74) .vector_compare_greater_signed else .vector_compare_equal;
                i.dst = .{ .vector = @intCast(o.reg.reg.index) };
                i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
                i.vector_element = switch (ext) {
                    0x64, 0x74 => 1,
                    0x65, 0x75 => 2,
                    0x66, 0x76 => 4,
                    else => unreachable,
                };
                i.vector_aligned = true;
            }
        },
        0x6e, 0x7e, 0xd6 => {
            if ((ext == 0x7e and repeat == 0xf3) or (ext == 0xd6 and c.word and repeat == 0)) {
                const o = try c.operands(32);
                const regop = ir.Operand{ .vector = @intCast(o.reg.reg.index) };
                const rmop: ir.Operand = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
                i.op = .vector_move_low;
                i.width = 64;
                i.dst = if (ext == 0xd6) rmop else regop;
                i.src = if (ext == 0xd6) regop else rmop;
            } else {
                if (!c.word or repeat != 0) return error.UnsupportedInstruction;
                i.width = if (c.rex & 8 != 0) 64 else 32;
                const o = try c.operands(i.width);
                const regop = ir.Operand{ .vector = @intCast(o.reg.reg.index) };
                i.op = if (ext == 0x6e) .scalar_to_vector else .vector_to_scalar;
                i.dst = if (ext == 0x6e) regop else o.rm;
                i.src = if (ext == 0x6e) o.rm else regop;
            }
            i.set_flags = false;
        },
        0x60, 0x61, 0x62, 0x68, 0x69, 0x6a, 0x6c, 0x6d, 0x70 => {
            if (ext != 0x70 and (!c.word or repeat != 0)) return error.UnsupportedInstruction;
            if (ext == 0x70 and !c.word and repeat != 0xf2 and repeat != 0xf3) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.set_flags = false;
            i.vector_aligned = true;
            if (ext == 0x70) {
                i.op = .vector_shuffle;
                i.vector_element = if (c.word) 4 else 2;
                i.vector_high = repeat == 0xf3;
                i.shuffle = try c.byte();
            } else {
                i.op = if (ext == 0x68 or ext == 0x69 or ext == 0x6a or ext == 0x6d) .vector_unpack_high else .vector_unpack_low;
                i.vector_element = switch (ext) {
                    0x60, 0x68 => 1,
                    0x61, 0x69 => 2,
                    0x62, 0x6a => 4,
                    0x6c, 0x6d => 8,
                    else => unreachable,
                };
            }
        },
        0x28, 0x29, 0x54, 0x56, 0x57, 0x6f, 0x7f, 0xdb, 0xdf, 0xeb, 0xef => {
            if ((ext == 0xef or ext == 0xdb or ext == 0xdf or ext == 0xeb) and !c.word) return error.UnsupportedInstruction;
            if ((ext == 0x6f or ext == 0x7f) and !c.word and repeat != 0xf3) return error.UnsupportedInstruction;
            if (repeat != 0 and (c.word or repeat != 0xf3)) return error.UnsupportedRepeatPrefix;
            const o = try c.operands(32);
            const regop = ir.Operand{ .vector = @intCast(o.reg.reg.index) };
            const rmop: ir.Operand = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
            i.op = switch (ext) {
                0x54, 0xdb => .vector_and,
                0xdf => .vector_and_not,
                0x56, 0xeb => .vector_or,
                0x57, 0xef => .vector_xor,
                else => .vector_mov,
            };
            i.vector_aligned = ext == 0x54 or ext == 0x56 or ext == 0x57 or ext == 0xef or ext == 0xdb or ext == 0xdf or ext == 0xeb or ext == 0x28 or ext == 0x29 or ((ext == 0x6f or ext == 0x7f) and c.word);
            i.set_flags = false;
            i.dst = if (ext == 0x11 or ext == 0x29 or ext == 0x7f) rmop else regop;
            i.src = if (ext == 0x11 or ext == 0x29 or ext == 0x7f) regop else rmop;
        },
        else => unreachable,
    }
}
test "REX, ModRM SIB, high byte and RIP relative immediate" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .execute = true });
    try m.initialize(0x1000, &.{ 0x48, 0x8b, 0x44, 0x8d, 0xf0, 0xc7, 0x05, 0x10, 0, 0, 0, 0x34, 0x12, 0, 0, 0xb4, 0x7f });
    const a = try decode(&m, 0x1000);
    try std.testing.expectEqual(ir.Op.mov, a.op);
    try std.testing.expectEqual(@as(i64, -16), a.src.mem.displacement);
    try std.testing.expectEqual(@as(?u6, 1), a.src.mem.index);
    const b = try decode(&m, a.next);
    try std.testing.expectEqual(@as(u64, 0x100f), b.next);
    try std.testing.expect(b.dst.mem.relative);
    const d = try decode(&m, b.next);
    try std.testing.expect(d.dst.reg.high);
}
test "REP RET returns once without changing the count or flags" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0xf3, 0xc3, 0xf2, 0xc3, 0xf3, 0x01, 0xc0 });
    try m.writeInt(0x1100, 64, 0x1234);
    const i = try decode(&m, 0x1000);
    try std.testing.expectEqual(ir.Op.ret, i.op);
    try std.testing.expectEqual(@as(u64, 0x1002), i.next);
    for ([_]u64{ 0, 1, 3 }) |count| {
        var state = @import("state.zig").State{ .architecture = .x86_64 };
        state.set(1, count);
        state.set(4, 0x1100);
        state.flags.carry = true;
        state.flags.zero = true;
        const flags = state.flags;
        _ = try @import("../interpreter.zig").execute(&state, &m, i);
        try std.testing.expectEqual(@as(u64, 0x1234), state.pc);
        try std.testing.expectEqual(@as(u64, 0x1108), state.get(4));
        try std.testing.expectEqual(count, state.get(1));
        try std.testing.expectEqualDeep(flags, state.flags);
    }
    try std.testing.expectError(error.UnsupportedRepeatPrefix, decode(&m, 0x1002));
    try std.testing.expectError(error.UnsupportedRepeatPrefix, decode(&m, 0x1004));
}

test "x86 decoder fuzz" {
    try std.testing.fuzz({}, fuzz, .{});
}
fn fuzz(_: void, smith: *std.testing.Smith) !void {
    var b: [32]u8 = undefined;
    smith.bytes(&b);
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.initialize(0x1000, &b);
    _ = decode(&m, 0x1000) catch {};
}

test "SSE2 bitwise vectors, unaligned transfer and alignment faults" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0x66, 0x0f, 0xef, 0xc0, 0x0f, 0x11, 0x4f, 0x03, 0x0f, 0x10, 0x57, 0x03, 0x0f, 0x54, 0xd1, 0x0f, 0x56, 0xd3, 0x0f, 0x29, 0x4f, 0x03 });
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    s.set(7, 0x1100);
    s.vectors[0] = @splat(255);
    s.vectors[1] = @splat(0x5a);
    s.vectors[3] = @splat(0xa5);
    var pc: u64 = 0x1000;
    for (0..5) |_| {
        const i = try decode(&m, pc);
        _ = try @import("../interpreter.zig").execute(&s, &m, i);
        pc = i.next;
    }
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), &s.vectors[0]);
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(255)), &s.vectors[2]);
    const i = try decode(&m, pc);
    try std.testing.expectError(error.MisalignedMemory, @import("../interpreter.zig").execute(&s, &m, i));
}

test "SSE4.1 MOVNTDQA loads aligned memory and rejects a register source" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0x66, 0x0f, 0x38, 0x2a, 0x00, 0x66, 0x0f, 0x38, 0x2a, 0xc1 });
    const expected = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try m.initialize(0x1100, &expected);
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    s.set(0, 0x1100);

    const load = try decode(&m, 0x1000);
    try std.testing.expectEqual(ir.Op.vector_mov, load.op);
    try std.testing.expect(load.vector_aligned);
    _ = try @import("../interpreter.zig").execute(&s, &m, load);
    try std.testing.expectEqualSlices(u8, &expected, &s.vectors[0]);
    try std.testing.expectError(error.UnsupportedInstruction, decode(&m, load.next));
}

test "SSE2 signed word min and max" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0x66, 0x0f, 0xea, 0xd0, 0x66, 0x0f, 0xee, 0xd0 });

    const lhs = [_]i16{ -32768, 32767, -1, 0, 0x1234, -0x1234, 0x4000, -0x4000 };
    const rhs = [_]i16{ 32767, -32768, 0, -1, -0x1234, 0x1234, -0x4000, 0x4000 };
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    for (lhs, rhs, 0..) |a, b, n| {
        std.mem.writeInt(u16, s.vectors[0][n * 2 ..][0..2], @bitCast(a), .little);
        std.mem.writeInt(u16, s.vectors[2][n * 2 ..][0..2], @bitCast(b), .little);
    }

    const min = try decode(&m, 0x1000);
    try std.testing.expectEqual(ir.Op.vector_min_signed, min.op);
    _ = try execute(&s, &m, min);
    for (lhs, rhs, 0..) |a, b, n| {
        const got: i16 = @bitCast(std.mem.readInt(u16, s.vectors[2][n * 2 ..][0..2], .little));
        try std.testing.expectEqual(@min(a, b), got);
        std.mem.writeInt(u16, s.vectors[2][n * 2 ..][0..2], @bitCast(b), .little);
    }

    const max = try decode(&m, min.next);
    try std.testing.expectEqual(ir.Op.vector_max_signed, max.op);
    _ = try execute(&s, &m, max);
    for (lhs, rhs, 0..) |a, b, n| {
        const got: i16 = @bitCast(std.mem.readInt(u16, s.vectors[2][n * 2 ..][0..2], .little));
        try std.testing.expectEqual(@max(a, b), got);
    }

    var memory_words: [16]u8 = undefined;
    for (rhs, 0..) |b, n| std.mem.writeInt(u16, memory_words[n * 2 ..][0..2], @bitCast(b), .little);
    try m.initialize(0x1008, &.{ 0x66, 0x0f, 0xea, 0x10 }); // PMINSW xmm2, [rax]
    try m.initialize(0x1100, &memory_words);
    s.set(0, 0x1100);
    for (lhs, 0..) |a, n| std.mem.writeInt(u16, s.vectors[2][n * 2 ..][0..2], @bitCast(a), .little);
    const memory_min = try decode(&m, 0x1008);
    _ = try execute(&s, &m, memory_min);
    for (lhs, rhs, 0..) |a, b, n| {
        const got: i16 = @bitCast(std.mem.readInt(u16, s.vectors[2][n * 2 ..][0..2], .little));
        try std.testing.expectEqual(@min(a, b), got);
    }
    s.set(0, 0x1101);
    try std.testing.expectError(error.MisalignedMemory, execute(&s, &m, memory_min));
}

test "string operations repeat, direction, segments, address size and restartable faults" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.map(0x2000, 4096, .{ .read = true, .write = true });
    try m.map(0x4000, 4096, .{ .read = true, .write = true });
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    try m.initialize(0x1000, &.{ 0xf3, 0x48, 0xab }); // REP STOSQ
    const store = try decode(&m, 0x1000);
    s.set(0, 0x123456789abcdef0);
    s.set(1, 3);
    s.set(7, 0x2000);
    s.flags.carry = true;
    s.flags.zero = true;
    const flags = s.flags.bits();
    for (0..3) |n| {
        _ = try execute(&s, &m, store);
        try std.testing.expectEqual(@as(u64, if (n == 2) 0x1003 else 0x1000), s.pc);
        try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), try m.readInt(0x2000 + n * 8, 64, .read));
    }
    try std.testing.expectEqual(@as(u64, 0), s.get(1));
    try std.testing.expectEqual(flags, s.flags.bits());
    s.set(7, 0xffffffffffffffff);
    _ = try execute(&s, &m, store); // Zero count does not access memory.
    try std.testing.expectEqual(@as(u64, 0x1003), s.pc);

    try m.initialize(0x1000, &.{ 0xfd, 0xf3, 0xaa, 0xfc }); // STD; REP STOSB; CLD
    _ = try execute(&s, &m, try decode(&m, 0x1000));
    try std.testing.expect(s.flags.bits() & 0x400 != 0);
    s.set(0, 'z');
    s.set(1, 2);
    s.set(7, 0x2011);
    const backwards = try decode(&m, 0x1001);
    _ = try execute(&s, &m, backwards);
    _ = try execute(&s, &m, backwards);
    try std.testing.expectEqual(@as(u64, 0x200f), s.get(7));
    try std.testing.expectEqual(@as(u64, 0x7a7a), try m.readInt(0x2010, 16, .read));
    _ = try execute(&s, &m, try decode(&m, 0x1003));
    try std.testing.expect(!s.flags.direction);

    try m.initialize(0x1000, &.{ 0x64, 0xf3, 0xa4 }); // FS: REP MOVSB
    try m.initialize(0x4100, "abc");
    s.fs_base = 0x4000;
    s.set(6, 0x100);
    s.set(7, 0x2100);
    s.set(1, 3);
    const move = try decode(&m, 0x1000);
    for (0..3) |_| _ = try execute(&s, &m, move);
    try std.testing.expectEqual(@as(u64, 0x636261), try m.readInt(0x2100, 32, .read));
    // Overlapping copies are element ordered, not host memmove.
    try m.initialize(0x1000, &.{ 0xf3, 0xa4 });
    s.set(6, 0x2100);
    s.set(7, 0x2101);
    s.set(1, 3);
    const overlap = try decode(&m, 0x1000);
    for (0..3) |_| _ = try execute(&s, &m, overlap);
    try std.testing.expectEqual(@as(u64, 0x61616161), try m.readInt(0x2100, 32, .read));

    try m.initialize(0x2200, "aab");
    try m.initialize(0x2300, "aac");
    try m.initialize(0x1000, &.{ 0xf3, 0xa6 }); // REPE CMPSB stops at mismatch.
    s.set(6, 0x2200);
    s.set(7, 0x2300);
    s.set(1, 5);
    const cmp = try decode(&m, 0x1000);
    for (0..3) |_| _ = try execute(&s, &m, cmp);
    try std.testing.expectEqual(@as(u64, 2), s.get(1));
    try std.testing.expectEqual(@as(u64, 0x1002), s.pc);
    try std.testing.expect(!s.flags.zero and s.flags.carry);
    try m.initialize(0x1000, &.{ 0xf2, 0xae }); // REPNE SCASB stops at match.
    s.set(0, 'b');
    s.set(7, 0x2200);
    s.set(1, 5);
    const scan = try decode(&m, 0x1000);
    for (0..3) |_| _ = try execute(&s, &m, scan);
    try std.testing.expect(s.flags.zero);
    try std.testing.expectEqual(@as(u64, 2), s.get(1));
    try std.testing.expectEqual(@as(u64, 0x1002), s.pc);

    try m.initialize(0x1000, &.{ 0x67, 0xf3, 0xaa });
    s.set(1, 0xffffffff00000002);
    s.set(7, 0xffffffff00002200);
    const narrow = try decode(&m, 0x1000);
    _ = try execute(&s, &m, narrow);
    try std.testing.expectEqual(@as(u64, 1), s.get(1));
    try std.testing.expectEqual(@as(u64, 0x2201), s.get(7));
    try m.initialize(0x1000, &.{ 0x66, 0xad }); // LODSW keeps upper accumulator bits.
    s.set(0, 0x123456789abc0000);
    s.set(6, 0x2300);
    const load = try decode(&m, 0x1000);
    _ = try execute(&s, &m, load);
    try std.testing.expectEqual(@as(u64, 0x123456789abc6161), s.get(0));
    try std.testing.expectEqual(@as(u64, 0x2302), s.get(6));

    try m.initialize(0x1000, &.{ 0xf3, 0xaa });
    s.set(7, 0x2fff);
    s.set(1, 2);
    const faulting = try decode(&m, 0x1000);
    _ = try execute(&s, &m, faulting);
    const completed = s.instructions;
    try std.testing.expectError(error.UnmappedMemory, execute(&s, &m, faulting));
    try std.testing.expectEqual(completed, s.instructions);
    try std.testing.expectEqual(@as(u64, 0x1000), s.pc);
    try std.testing.expectEqual(@as(u64, 1), s.get(1));
    try std.testing.expectEqual(@as(u64, 0x3000), s.get(7));
}

test "TZCNT and LZCNT zero input, width and result flags" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    for ([_]u8{ 0xbc, 0xbd }) |opcode| {
        for ([_]u7{ 16, 32, 64 }) |width| {
            const bytes: []const u8 = if (width == 16) &.{ 0x66, 0xf3, 0x0f, opcode, 0xc1 } else if (width == 64) &.{ 0xf3, 0x48, 0x0f, opcode, 0xc1 } else &.{ 0xf3, 0x0f, opcode, 0xc1 };
            try m.initialize(0x1000, bytes);
            const instruction = try decode(&m, 0x1000);
            for ([_]u64{ 0, 1, @as(u64, 1) << @as(u6, @intCast(width - 1)) }) |value| {
                s.set(1, value);
                _ = try @import("../interpreter.zig").execute(&s, &m, instruction);
                const expected: u64 = if (value == 0) width else if ((opcode == 0xbc) == (value == 1)) 0 else width - 1;
                try std.testing.expectEqual(expected, s.get(0) & ir.mask(width));
                try std.testing.expectEqual(value == 0, s.flags.carry);
                try std.testing.expectEqual(expected == 0, s.flags.zero);
            }
        }
    }
}

test "ROL and ROR mask counts, preserve status flags and update carry" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    for ([_]u8{ 0xc0, 0xc8 }) |modrm| {
        for ([_]u7{ 8, 16, 32, 64 }) |width| {
            for ([_]u8{ 0, 1, @intCast(width), @intCast(width + 1), 255 }) |count| {
                const bytes: []const u8 = if (width == 8) &.{ 0xc0, modrm, count } else if (width == 16) &.{ 0x66, 0xc1, modrm, count } else if (width == 64) &.{ 0x48, 0xc1, modrm, count } else &.{ 0xc1, modrm, count };
                try m.initialize(0x1000, bytes);
                const instruction = try decode(&m, 0x1000);
                const initial = (@as(u64, 1) << @as(u6, @intCast(width - 1))) | 1;
                var expected = initial;
                const masked = count & (if (width == 64) @as(u8, 63) else 31);
                for (0..masked % width) |_| {
                    expected = if (modrm == 0xc0) ((expected << 1) | (expected >> @as(u6, @intCast(width - 1)))) & ir.mask(width) else (expected >> 1) | ((expected & 1) << @as(u6, @intCast(width - 1)));
                }
                s.set(0, initial);
                s.flags = .{ .carry = false, .zero = true, .sign = true, .parity = true };
                _ = try @import("../interpreter.zig").execute(&s, &m, instruction);
                try std.testing.expectEqual(expected, s.get(0) & ir.mask(width));
                try std.testing.expect(s.flags.zero and s.flags.sign and s.flags.parity);
                try std.testing.expectEqual(masked != 0 and (if (modrm == 0xc0) expected & 1 != 0 else expected >> @as(u6, @intCast(width - 1)) != 0), s.flags.carry);
                if (masked == 1) {
                    const high = expected >> @as(u6, @intCast(width - 1)) != 0;
                    try std.testing.expectEqual(high != (if (modrm == 0xc0) s.flags.carry else (expected >> @as(u6, @intCast(width - 2))) & 1 != 0), s.flags.overflow);
                }
            }
        }
    }
}

test "RDTSC returns a monotonic virtual counter in zero-extended EDX:EAX" {
    const execute = @import("../interpreter.zig").execute;
    const host = @import("../host.zig");
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.initialize(0x1000, &.{ 0x0f, 0x31, 0xf0, 0x0f, 0x31 });
    const i = try decode(&m, 0x1000);
    try std.testing.expectEqual(ir.Op.rdtsc, i.op);
    try std.testing.expectEqual(@as(u64, 0x1002), i.next);
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    s.flags = .{ .carry = true, .parity = true, .zero = true, .sign = true, .overflow = true, .direction = true };
    const flags = s.flags.bits();
    s.set(1, 0x123456789abcdef0);
    var previous: u64 = 0;
    for (0..2) |_| {
        s.set(0, 0xffffffffffffffff);
        s.set(2, 0xffffffffffffffff);
        const before = try host.nowNs();
        _ = try execute(&s, &m, i);
        const after = try host.nowNs();
        try std.testing.expect(s.get(0) <= 0xffffffff and s.get(2) <= 0xffffffff);
        const counter = (s.get(2) << 32) | s.get(0);
        try std.testing.expect(counter >= before and counter <= after and counter >= previous);
        previous = counter;
        try std.testing.expectEqual(flags, s.flags.bits());
        try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), s.get(1));
        try std.testing.expectEqual(i.next, s.pc);
    }
    try std.testing.expectEqual(@as(u64, 2), s.instructions);
    try std.testing.expectError(error.InvalidLockPrefix, decode(&m, i.next));
}

test "SSE half-register transfers preserve lanes and access exactly eight bytes" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    const a: u64 = 0x1122334455667788;
    const b: u64 = 0x99aabbccddeeff00;
    const c: u64 = 0x0102030405060708;
    const d: u64 = 0x1020304050607080;
    const memory: u64 = 0x876543210fedcba9;
    const cases = [_]struct { bytes: []const u8, low: u64, high: u64, stored: u64 = memory }{
        .{ .bytes = &.{ 0x0f, 0x12, 0x07 }, .low = memory, .high = b },
        .{ .bytes = &.{ 0x0f, 0x16, 0x07 }, .low = a, .high = memory },
        .{ .bytes = &.{ 0x66, 0x0f, 0x12, 0x07 }, .low = memory, .high = b },
        .{ .bytes = &.{ 0x66, 0x0f, 0x16, 0x07 }, .low = a, .high = memory },
        .{ .bytes = &.{ 0x0f, 0x13, 0x07 }, .low = a, .high = b, .stored = a },
        .{ .bytes = &.{ 0x0f, 0x17, 0x07 }, .low = a, .high = b, .stored = b },
        .{ .bytes = &.{ 0x66, 0x0f, 0x13, 0x07 }, .low = a, .high = b, .stored = a },
        .{ .bytes = &.{ 0x66, 0x0f, 0x17, 0x07 }, .low = a, .high = b, .stored = b },
        .{ .bytes = &.{ 0x0f, 0x12, 0xc1 }, .low = d, .high = b },
        .{ .bytes = &.{ 0x0f, 0x16, 0xc1 }, .low = a, .high = c },
        .{ .bytes = &.{ 0x0f, 0x12, 0xc0 }, .low = b, .high = b },
        .{ .bytes = &.{ 0x0f, 0x16, 0xc0 }, .low = a, .high = a },
    };
    for (cases) |case| {
        try m.initialize(0x1000, case.bytes);
        for ([_]u64{ 0x1103, 0x1ff8 }) |addr| {
            var s = @import("state.zig").State{ .architecture = .x86_64 };
            s.set(7, addr);
            s.flags = .{ .carry = true, .overflow = true };
            std.mem.writeInt(u64, s.vectors[0][0..8], a, .little);
            std.mem.writeInt(u64, s.vectors[0][8..16], b, .little);
            std.mem.writeInt(u64, s.vectors[1][0..8], c, .little);
            std.mem.writeInt(u64, s.vectors[1][8..16], d, .little);
            try m.writeInt(addr, 64, memory);
            const i = try decode(&m, 0x1000);
            _ = try execute(&s, &m, i);
            try std.testing.expectEqual(case.low, std.mem.readInt(u64, s.vectors[0][0..8], .little));
            try std.testing.expectEqual(case.high, std.mem.readInt(u64, s.vectors[0][8..16], .little));
            try std.testing.expectEqual(case.stored, try m.readInt(addr, 64, .read));
            try std.testing.expectEqual(c, std.mem.readInt(u64, s.vectors[1][0..8], .little));
            try std.testing.expectEqual(d, std.mem.readInt(u64, s.vectors[1][8..16], .little));
            try std.testing.expect(s.flags.carry and s.flags.overflow);
        }
    }
    for ([_][]const u8{ &.{ 0x66, 0x0f, 0x12, 0xc1 }, &.{ 0x66, 0x0f, 0x16, 0xc1 }, &.{ 0x0f, 0x13, 0xc1 }, &.{ 0x0f, 0x17, 0xc1 } }) |bytes| {
        try m.initialize(0x1000, bytes);
        try std.testing.expectError(error.UnsupportedInstruction, decode(&m, 0x1000));
    }
    try m.initialize(0x1000, &.{ 0x0f, 0x16, 0x07 });
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    s.set(7, 0x1ffc);
    s.vectors[0] = @splat(0xab);
    const original = s.vectors[0];
    try std.testing.expectError(error.UnmappedMemory, execute(&s, &m, try decode(&m, 0x1000)));
    try std.testing.expectEqualSlices(u8, &original, &s.vectors[0]);
    try std.testing.expectEqual(@as(u64, 0), s.instructions);
}

test "CPUID exposes a conservative virtual CPU without host feature leakage" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.initialize(0x1000, &.{ 0x0f, 0xa2, 0xf0, 0x0f, 0xa2 });
    const i = try decode(&m, 0x1000);
    try std.testing.expectEqual(ir.Op.cpuid, i.op);
    const cases = [_]struct { leaf: u32, result: [4]u32 }{
        .{ .leaf = 0, .result = .{ 1, 0x56494e55, 0x21555043, 0x45535245 } },
        .{ .leaf = 1, .result = .{ 0, 0x10000, 0x2000, 0x808110 } },
        .{ .leaf = 7, .result = .{ 0, 0, 0, 0 } },
        .{ .leaf = 0x80000000, .result = .{ 0x80000001, 0, 0, 0 } },
        .{ .leaf = 0x80000001, .result = .{ 0, 0, 0, 0x20000800 } },
        .{ .leaf = 0xffffffff, .result = .{ 0, 0, 0, 0 } },
    };
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    s.flags = .{ .carry = true, .zero = true, .overflow = true };
    const flags = s.flags.bits();
    s.set(7, 0xabcdef9876543210);
    for (cases) |case| {
        s.set(0, @as(u64, case.leaf) | 0xffffffff00000000);
        s.set(1, 0xffffffffffffffff); // No supported leaf uses a subleaf.
        s.set(2, 0xffffffffffffffff);
        s.set(3, 0xffffffffffffffff);
        _ = try execute(&s, &m, i);
        for ([_]u6{ 0, 3, 1, 2 }, case.result) |reg, value| try std.testing.expectEqual(@as(u64, value), s.get(reg));
        try std.testing.expectEqual(flags, s.flags.bits());
        try std.testing.expectEqual(@as(u64, 0xabcdef9876543210), s.get(7));
        try std.testing.expectEqual(i.next, s.pc);
    }
    try std.testing.expectError(error.InvalidLockPrefix, decode(&m, i.next));
}

test "Short XCHG accumulator encodings honor operand width and extended registers" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    const cases = [_]struct { bytes: []const u8, reg: u6, width: u7 }{
        .{ .bytes = &.{0x91}, .reg = 1, .width = 32 },
        .{ .bytes = &.{ 0x66, 0x97 }, .reg = 7, .width = 16 },
        .{ .bytes = &.{ 0x48, 0x93 }, .reg = 3, .width = 64 },
        .{ .bytes = &.{ 0x41, 0x90 }, .reg = 8, .width = 32 },
        .{ .bytes = &.{ 0x41, 0x92 }, .reg = 10, .width = 32 },
        .{ .bytes = &.{ 0x49, 0x97 }, .reg = 15, .width = 64 },
        .{ .bytes = &.{ 0x66, 0x41, 0x95 }, .reg = 13, .width = 16 },
    };
    for (cases) |case| {
        try m.initialize(0x1000, case.bytes);
        const i = try decode(&m, 0x1000);
        try std.testing.expectEqual(ir.Op.exchange, i.op);
        try std.testing.expectEqual(case.width, i.width);
        var s = @import("state.zig").State{ .architecture = .x86_64 };
        const a: u64 = 0x1122334455667788;
        const b: u64 = 0x99aabbccddeeff00;
        s.set(0, a);
        s.set(case.reg, b);
        s.flags = .{ .carry = true, .overflow = true, .direction = true };
        const flags = s.flags.bits();
        _ = try execute(&s, &m, i);
        const mask = ir.mask(case.width);
        try std.testing.expectEqual((b & mask) | (if (case.width == 16) a & ~mask else 0), s.get(0));
        try std.testing.expectEqual((a & mask) | (if (case.width == 16) b & ~mask else 0), s.get(case.reg));
        try std.testing.expectEqual(flags, s.flags.bits());
    }
    for ([_][]const u8{ &.{0x90}, &.{ 0xf3, 0x90 } }) |bytes| {
        try m.initialize(0x1000, bytes);
        try std.testing.expectEqual(ir.Op.nop, (try decode(&m, 0x1000)).op);
    }
}

test "CMOV reads untaken memory and zero-extends untaken 32-bit destinations" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    const cases = [_]struct { bytes: []const u8, width: u7 }{
        .{ .bytes = &.{ 0x66, 0x0f, 0x44, 0xc1 }, .width = 16 },
        .{ .bytes = &.{ 0x0f, 0x44, 0xc1 }, .width = 32 },
        .{ .bytes = &.{ 0x48, 0x0f, 0x44, 0xc1 }, .width = 64 },
    };
    for (cases) |case| {
        try m.initialize(0x1000, case.bytes);
        for ([_]bool{ false, true }) |take| {
            var s = @import("state.zig").State{ .architecture = .x86_64 };
            const destination: u64 = 0x1122334455667788;
            const source: u64 = 0x99aabbccddeeff00;
            s.set(0, destination);
            s.set(1, source);
            s.flags = .{ .zero = take, .carry = true, .overflow = true };
            const flags = s.flags.bits();
            _ = try execute(&s, &m, try decode(&m, 0x1000));
            const mask = ir.mask(case.width);
            const expected = if (take) (source & mask) | (if (case.width == 16) destination & ~mask else 0) else if (case.width == 32) destination & mask else destination;
            try std.testing.expectEqual(expected, s.get(0));
            try std.testing.expectEqual(flags, s.flags.bits());
        }
    }
    try m.initialize(0x1000, &.{ 0x0f, 0x44, 0x07 });
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    s.set(0, 0x1122334455667788);
    s.set(7, 0x2000);
    s.flags.zero = false;
    try std.testing.expectError(error.UnmappedMemory, execute(&s, &m, try decode(&m, 0x1000)));
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), s.get(0));
    try std.testing.expectEqual(@as(u64, 0), s.instructions);
}

test "CMPXCHG8B and CMPXCHG16B compare both halves and write on both outcomes" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    const cases = [_]struct { bytes: []const u8, half: u7, base: u6 = 7 }{
        .{ .bytes = &.{ 0x0f, 0xc7, 0x0f }, .half = 32 },
        .{ .bytes = &.{ 0xf0, 0x0f, 0xc7, 0x0f }, .half = 32 },
        .{ .bytes = &.{ 0x66, 0x0f, 0xc7, 0x0f }, .half = 32 },
        .{ .bytes = &.{ 0x48, 0x0f, 0xc7, 0x0f }, .half = 64 },
        .{ .bytes = &.{ 0xf0, 0x48, 0x0f, 0xc7, 0x0f }, .half = 64 },
        .{ .bytes = &.{ 0x49, 0x0f, 0xc7, 0x08 }, .half = 64, .base = 8 },
    };
    for (cases) |case| {
        try m.initialize(0x1000, case.bytes);
        const i = try decode(&m, 0x1000);
        try std.testing.expectEqual(ir.Op.cmpxchg_pair, i.op);
        try std.testing.expectEqual(case.half, i.source_width);
        const addr: u64 = if (case.half == 32) 0x1103 else 0x1100;
        const half_size: u64 = case.half / 8;
        const low = @as(u64, 0x0123456789abcdef) & ir.mask(case.half);
        const high = @as(u64, 0xfedcba9876543210) & ir.mask(case.half);
        for ([_]bool{ false, true }) |equal| {
            var s = @import("state.zig").State{ .architecture = .x86_64 };
            s.set(case.base, addr);
            const a = low ^ @as(u64, @intFromBool(!equal)) | (if (case.half == 32) @as(u64, 0xaabbccdd00000000) else 0);
            const d = high | (if (case.half == 32) @as(u64, 0x1122334400000000) else 0);
            s.set(0, a);
            s.set(2, d);
            s.set(3, 0x8877665544332211);
            s.set(1, 0x1122334455667788);
            s.flags = .{ .carry = true, .parity = true, .sign = true, .overflow = true, .direction = true };
            const unchanged_flags = s.flags.bits();
            try m.writeInt(addr, case.half, low);
            try m.writeInt(addr + half_size, case.half, high);
            const writes = m.writes;
            _ = try execute(&s, &m, i);
            try std.testing.expectEqual(writes + 1, m.writes);
            try std.testing.expectEqual(equal, s.flags.zero);
            try std.testing.expectEqual(unchanged_flags, s.flags.bits() & ~@as(u64, 64));
            try std.testing.expectEqual(if (equal) a else low, s.get(0));
            try std.testing.expectEqual(if (equal) d else high, s.get(2));
            try std.testing.expectEqual(if (equal) s.get(3) & ir.mask(case.half) else low, try m.readInt(addr, case.half, .read));
            try std.testing.expectEqual(if (equal) s.get(1) & ir.mask(case.half) else high, try m.readInt(addr + half_size, case.half, .read));
            try std.testing.expectEqual(@as(u64, 0x8877665544332211), s.get(3));
            try std.testing.expectEqual(@as(u64, 0x1122334455667788), s.get(1));
        }
    }
    for ([_][]const u8{ &.{ 0x0f, 0xc7, 0xc8 }, &.{ 0x48, 0x0f, 0xc7, 0xc8 }, &.{ 0x0f, 0xc7, 0x37 } }) |bytes| {
        try m.initialize(0x1000, bytes);
        try std.testing.expectError(error.UnsupportedInstruction, decode(&m, 0x1000));
    }
}

test "Compare-exchange memory faults preserve flags and registers even on mismatch" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.map(0x2000, 4096, .{ .read = true });
    try m.initialize(0x2000, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    for ([_][]const u8{ &.{ 0x0f, 0xb1, 0x0f }, &.{ 0x0f, 0xc7, 0x0f }, &.{ 0x48, 0x0f, 0xc7, 0x0f } }) |bytes| {
        try m.initialize(0x1000, bytes);
        var s = @import("state.zig").State{ .architecture = .x86_64 };
        s.set(7, 0x2000);
        s.set(0, 0xffffffffffffffff);
        s.flags.zero = true;
        const original = s;
        const writes = m.writes;
        try std.testing.expectError(error.PermissionDenied, execute(&s, &m, try decode(&m, 0x1000)));
        try std.testing.expect(std.meta.eql(original, s));
        try std.testing.expectEqual(writes, m.writes);
    }
    try m.initialize(0x1000, &.{ 0x48, 0x0f, 0xc7, 0x0f });
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    s.set(7, 0x2001);
    try std.testing.expectError(error.MisalignedMemory, execute(&s, &m, try decode(&m, 0x1000)));
    try m.initialize(0x1000, &.{ 0x0f, 0xc7, 0x0f });
    s.set(7, 0x1ffc); // One half writable, the other half read-only.
    const before = try m.readInt(0x1ffc, 64, .read);
    const original = s;
    const writes = m.writes;
    try std.testing.expectError(error.PermissionDenied, execute(&s, &m, try decode(&m, 0x1000)));
    try std.testing.expect(std.meta.eql(original, s));
    try std.testing.expectEqual(before, try m.readInt(0x1ffc, 64, .read));
    try std.testing.expectEqual(writes, m.writes);
}

test "32-bit addresses wrap offsets before FS and keep 64-bit stack and branch targets" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 8192, .{ .read = true, .write = true, .execute = true });
    try m.map(0x100001000, 8192, .{ .read = true, .write = true, .execute = true });
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    s.set(12, 0xdeadbeef00000880);
    s.set(13, 0xcafe1234fffffff8);
    s.fs_base = 0x100000000;
    try m.writeInt(0x100002200, 64, 0x123456789abcdef0);
    try m.initialize(0x1000, &.{ 0x64, 0x67, 0x4b, 0x8b, 0x44, 0xa5, 0x08 });
    const sib = try decode(&m, 0x1000);
    try std.testing.expectEqual(@as(u7, 32), sib.src.mem.width);
    _ = try execute(&s, &m, sib);
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), s.get(0));
    try m.initialize(0x1000, &.{ 0x64, 0x67, 0x4b, 0x8d, 0x44, 0xa5, 0x08 });
    _ = try execute(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u64, 0x2200), s.get(0));
    // EIP-relative offsets truncate the next PC and the signed sum to 32 bits.
    try m.writeInt(0x2200, 32, 0x87654321);
    try m.initialize(0x100001000, &.{ 0x67, 0x8b, 0x05, 0xf9, 0x11, 0, 0 });
    _ = try execute(&s, &m, try decode(&m, 0x100001000));
    try std.testing.expectEqual(@as(u64, 0x87654321), s.get(0));
    // A no-base SIB negative displacement is zero-extended after address wrapping.
    try m.initialize(0x1000, &.{ 0x67, 0x48, 0x8d, 0x04, 0x25, 0xff, 0xff, 0xff, 0xff });
    _ = try execute(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u64, 0xffffffff), s.get(0));
    try m.initialize(0x100001000, &.{ 0x67, 0xe8, 0x10, 0, 0, 0 });
    s.set(4, 0x100002008);
    _ = try execute(&s, &m, try decode(&m, 0x100001000));
    try std.testing.expectEqual(@as(u64, 0x100001016), s.pc);
    try std.testing.expectEqual(@as(u64, 0x100002000), s.get(4));
    try std.testing.expectEqual(@as(u64, 0x100001006), try m.readInt(s.get(4), 64, .read));
}

test "XADD exchanges old operands, stages memory faults and handles aliases" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 8192, .{ .read = true, .write = true, .execute = true });
    for ([_]u7{ 8, 16, 32, 64 }) |width| {
        const bytes: []const u8 = if (width == 8) &.{ 0x0f, 0xc0, 0xc8 } else if (width == 16) &.{ 0x66, 0x0f, 0xc1, 0xc8 } else if (width == 32) &.{ 0x0f, 0xc1, 0xc8 } else &.{ 0x48, 0x0f, 0xc1, 0xc8 };
        try m.initialize(0x1000, bytes);
        var s = @import("state.zig").State{ .architecture = .x86_64 };
        s.set(0, ir.mask(width));
        s.set(1, 1);
        _ = try execute(&s, &m, try decode(&m, 0x1000));
        try std.testing.expectEqual(@as(u64, 0), s.get(0));
        try std.testing.expectEqual(ir.mask(width), s.get(1));
        try std.testing.expect(s.flags.carry and s.flags.zero and s.flags.parity and !s.flags.sign and !s.flags.overflow);
        s.set(0, ir.mask(width) >> 1);
        s.set(1, 1);
        _ = try execute(&s, &m, try decode(&m, 0x1000));
        try std.testing.expect(s.flags.overflow and s.flags.sign and !s.flags.carry);
    }
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    try m.initialize(0x1000, &.{ 0x0f, 0xc0, 0xc4 }); // XADD AH,AL.
    s.set(0, 0xdeadbeef00000102);
    _ = try execute(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u64, 0xdeadbeef00000301), s.get(0));
    try m.initialize(0x1000, &.{ 0x0f, 0xc1, 0xc0 }); // XADD EAX,EAX.
    s.set(0, 0xabcdef0100000003);
    _ = try execute(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u64, 6), s.get(0));
    try m.initialize(0x1000, &.{ 0xf0, 0x48, 0x0f, 0xc1, 0x3f }); // LOCK XADD [rdi],rdi.
    try m.writeInt(0x2ff8, 64, 7);
    s.set(7, 0x2ff8);
    const memory = try decode(&m, 0x1000);
    _ = try execute(&s, &m, memory);
    try std.testing.expectEqual(@as(u64, 0x2fff), try m.readInt(0x2ff8, 64, .read));
    try std.testing.expectEqual(@as(u64, 7), s.get(7));
    s.set(7, 0x2ffc);
    const before = s;
    try std.testing.expectError(error.UnmappedMemory, execute(&s, &m, memory));
    try std.testing.expect(std.meta.eql(before, s));
    s.set(7, 0x2ff8);
    try m.protect(0x2000, 4096, .{ .read = true });
    const protected = s;
    try std.testing.expectError(error.PermissionDenied, execute(&s, &m, memory));
    try std.testing.expect(std.meta.eql(protected, s));
    try m.initialize(0x1000, &.{ 0xf0, 0x0f, 0xc1, 0xc0 });
    try std.testing.expectError(error.InvalidLockPrefix, decode(&m, 0x1000));
}

test "float shuffles and unpacks select both source halves with exact bits and checked memory" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    for (0..16) |n| {
        a[n] = @intCast(n);
        b[n] = @intCast(128 + n);
    }
    try m.write(0x1ff0, &b);
    for ([_]usize{ 4, 8 }) |element| {
        for ([_]bool{ false, true }) |memory| {
            for (0..256) |control| {
                var bytes: [6]u8 = .{ 0x66, 0x45, 0x0f, 0xc6, if (memory) 0x07 else 0xc1, @intCast(control) };
                if (memory) bytes[1] = 0x44;
                const code = if (element == 4) bytes[1..] else bytes[0..];
                try m.initialize(0x1000, code);
                var s = @import("state.zig").State{ .architecture = .x86_64 };
                s.set(7, 0x1ff0);
                s.setVector(8, a);
                s.setVector(9, b);
                s.x86_fp.mxcsr = 0x1fbf;
                s.flags.carry = true;
                var expected: [16]u8 = undefined;
                const lanes = 16 / element;
                for (0..lanes) |lane| {
                    const index = (control >> @as(u6, @intCast(lane * (if (element == 8) @as(usize, 1) else 2)))) & (lanes - 1);
                    const data = if (lane < lanes / 2) a else b;
                    @memcpy(expected[lane * element ..][0..element], data[index * element ..][0..element]);
                }
                _ = try execute(&s, &m, try decode(&m, 0x1000));
                try std.testing.expectEqualSlices(u8, &expected, &s.getVector(8));
                try std.testing.expect(s.flags.carry);
                try std.testing.expectEqual(@as(u32, 0x1fbf), s.x86_fp.mxcsr);
            }
        }
    }
    for ([_]usize{ 4, 8 }) |element| {
        for (0..4) |variant| {
            var bytes: [5]u8 = .{ 0x66, if (variant >= 2) 0x44 else 0x45, 0x0f, @intCast(0x14 + (variant & 1)), if (variant >= 2) 0x07 else 0xc1 };
            try m.initialize(0x1000, if (element == 4) bytes[1..] else &bytes);
            var unpacked = @import("state.zig").State{ .architecture = .x86_64 };
            unpacked.set(7, 0x1ff0);
            unpacked.setVector(8, a);
            unpacked.setVector(9, b);
            const expected = if (element == 4) [2][16]u8{
                .{ 0, 1, 2, 3, 128, 129, 130, 131, 4, 5, 6, 7, 132, 133, 134, 135 },
                .{ 8, 9, 10, 11, 136, 137, 138, 139, 12, 13, 14, 15, 140, 141, 142, 143 },
            } else [2][16]u8{
                .{ 0, 1, 2, 3, 4, 5, 6, 7, 128, 129, 130, 131, 132, 133, 134, 135 },
                .{ 8, 9, 10, 11, 12, 13, 14, 15, 136, 137, 138, 139, 140, 141, 142, 143 },
            };
            _ = try execute(&unpacked, &m, try decode(&m, 0x1000));
            try std.testing.expectEqualSlices(u8, &expected[variant & 1], &unpacked.getVector(8));
        }
    }
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    try m.initialize(0x1000, &.{ 0x66, 0x0f, 0xc6, 0x07, 0 });
    const instruction = try decode(&m, 0x1000);
    s.set(7, 0x2000);
    var before = s;
    try std.testing.expectError(error.UnmappedMemory, execute(&s, &m, instruction));
    try std.testing.expect(std.meta.eql(before, s));
    s.set(7, 0x1ff8);
    before = s;
    try std.testing.expectError(error.MisalignedMemory, execute(&s, &m, instruction));
    try std.testing.expect(std.meta.eql(before, s));
}

test "MOVMSKPS and MOVMSKPD extract raw signs and zero-extend general registers" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    for ([_]usize{ 4, 8 }) |element| {
        var bytes = [_]u8{ 0x66, 0x4d, 0x0f, 0x50, 0xc8 };
        try m.initialize(0x1000, if (element == 4) bytes[1..] else &bytes);
        const instruction = try decode(&m, 0x1000);
        for (0..@as(usize, 1) << @intCast(16 / element)) |mask| {
            var s = @import("state.zig").State{ .architecture = .x86_64 };
            var vector: [16]u8 = @splat(0x7f);
            for (0..16 / element) |lane| vector[(lane + 1) * element - 1] = if (mask & (@as(usize, 1) << @intCast(lane)) != 0) 0xff else 0x7f;
            s.setVector(8, vector);
            s.set(9, 0xffffffffffffffff);
            s.flags.carry = true;
            s.x86_fp.mxcsr = 0x1fbf;
            _ = try execute(&s, &m, instruction);
            try std.testing.expectEqual(@as(u64, mask), s.get(9));
            try std.testing.expectEqualSlices(u8, &vector, &s.getVector(8));
            try std.testing.expect(s.flags.carry);
            try std.testing.expectEqual(@as(u32, 0x1fbf), s.x86_fp.mxcsr);
        }
    }
    try m.initialize(0x1000, &.{ 0x0f, 0x50, 0x07 });
    try std.testing.expectError(error.InvalidInstruction, decode(&m, 0x1000));
}

test "single-thread fences, prefetch hints and disabled CET reads preserve guest state" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    for ([_][]const u8{ &.{ 0x0f, 0xae, 0xe8 }, &.{ 0x0f, 0xae, 0xf0 }, &.{ 0x0f, 0xae, 0xff }, &.{ 0xf3, 0x0f, 0x1e, 0xc8 }, &.{ 0xf3, 0x49, 0x0f, 0x1e, 0xcf }, &.{ 0x41, 0x0f, 0x18, 0x09 }, &.{ 0x0f, 0x18, 0x5f, 0x40 } }) |bytes| {
        try m.initialize(0x1000, bytes);
        var s = @import("state.zig").State{ .architecture = .x86_64, .pc = 0x1000 };
        s.set(0, 0xabcdef0123456789);
        s.set(15, 0x123456789abcdef0);
        s.flags = .{ .carry = true, .zero = true, .sign = true };
        var expected = s;
        expected.pc += bytes.len;
        expected.instructions += 1;
        _ = try execute(&s, &m, try decode(&m, 0x1000));
        try std.testing.expect(std.meta.eql(expected, s));
    }
    try m.initialize(0x1000, &.{ 0xf0, 0x0f, 0xae, 0xf0 });
    try std.testing.expectError(error.InvalidLockPrefix, decode(&m, 0x1000));
}

test "MMX exact-width transfers alias x87 registers and EMMS clears tags and TOP" {
    const execute = @import("../interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0x0f, 0x6f, 0x07, 0x0f, 0x7f, 0x07, 0x0f, 0x77, 0x0f, 0xef, 0xc0 });
    const raw: u64 = 0x8877665544332211;
    try m.writeInt(0x1ff8, 64, raw);
    var s = @import("state.zig").State{ .architecture = .x86_64 };
    s.set(7, 0x1ff8);
    s.x86_fp.status = 0x2800;
    s.flags.carry = true;
    s.vectors[0] = @splat(0x5a);
    const load = try decode(&m, 0x1000);
    try std.testing.expectEqual(@as(u5, 16), load.dst.vector);
    _ = try execute(&s, &m, load);
    try std.testing.expectEqual(raw, std.mem.readInt(u64, s.x86_fp.registers[0][0..8], .little));
    try std.testing.expectEqual(@as(u16, 0xffff), std.mem.readInt(u16, s.x86_fp.registers[0][8..10], .little));
    try std.testing.expectEqual(@as(u8, 0xff), s.x86_fp.tag);
    try std.testing.expectEqual(@as(u16, 0), s.x86_fp.status & 0x3800);
    const store = try decode(&m, load.next);
    _ = try execute(&s, &m, store);
    try std.testing.expectEqual(raw, try m.readInt(0x1ff8, 64, .read));
    const emms = try decode(&m, store.next);
    s.x86_fp.status = 0x6d01;
    const registers = s.x86_fp.registers;
    _ = try execute(&s, &m, emms);
    try std.testing.expectEqual(@as(u8, 0), s.x86_fp.tag);
    try std.testing.expectEqual(@as(u16, 0x4501), s.x86_fp.status);
    try std.testing.expect(std.meta.eql(registers, s.x86_fp.registers));
    try std.testing.expectEqual(raw, std.mem.readInt(u64, s.x86_fp.registers[0][0..8], .little));
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0x5a)), &s.vectors[0]);
    try std.testing.expect(s.flags.carry);
    s.set(7, 0x1ffc);
    const original = s;
    try std.testing.expectError(error.UnmappedMemory, execute(&s, &m, load));
    try std.testing.expect(std.meta.eql(original, s));
    s.x86_fp.control &= ~@as(u16, 1);
    s.x86_fp.status |= 1;
    const pending = s;
    try std.testing.expectError(error.FloatingPointException, execute(&s, &m, try decode(&m, emms.next)));
    try std.testing.expect(std.meta.eql(pending, s));
    try std.testing.expectError(error.FloatingPointException, execute(&s, &m, emms));
    try std.testing.expect(std.meta.eql(pending, s));
    try m.initialize(0x1000, &.{ 0x0f, 0x73, 0xd8, 0x01 });
    try std.testing.expectError(error.InvalidInstruction, decode(&m, 0x1000));
}
