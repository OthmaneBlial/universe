const std = @import("std");
const ir = @import("../ir.zig");
const Memory = @import("../memory.zig").Memory;
const Cursor = struct {
    memory: *Memory,
    pc: u64,
    start: u64,
    rex: u8 = 0,
    word: bool = false,
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
    fn operands(c: *Cursor, width: u7) !struct { rm: ir.Operand, reg: ir.Operand, group: u3 } {
        const b = try c.byte();
        const mode = b >> 6;
        const r = (b >> 3) & 7;
        const rm = b & 7;
        const regop = c.register(r, if (c.rex & 4 != 0) 8 else 0, width);
        if (mode == 3) return .{ .rm = c.register(rm, if (c.rex & 1 != 0) 8 else 0, width), .reg = regop, .group = @intCast(r) };
        var a = ir.Address{ .segment = c.segment };
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
        return .{ .rm = .{ .mem = a }, .reg = regop, .group = @intCast(r) };
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
    var address32 = false;
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
            address32 = true;
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
    if (repeat != 0 and op != 0x0f and !string and op != 0x90) return error.UnsupportedRepeatPrefix;
    if (address32 and !string) return error.UnsupportedAddressSize;
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
        0x90 => {
            if (c.rex & 1 != 0) {
                i.op = .exchange;
                i.dst = ir.reg(0);
                i.src = ir.reg(8);
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
            i.address_width = if (address32) 32 else 64;
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
        0x0f => try decodeExtended(&c, &i, w, repeat),
        else => return error.UnsupportedInstruction,
    }
    if (locked) {
        if (i.dst != .mem) return error.InvalidLockPrefix;
        switch (i.op) {
            .add, .sub, .adc, .sbb, .and_, .or_, .xor, .inc, .dec, .neg, .not_, .cmpxchg, .exchange, .bit_set, .bit_reset, .bit_complement => {},
            else => return error.InvalidLockPrefix,
        }
    }
    i.next = c.pc;
    return i;
}

fn decodeExtended(c: *Cursor, i: *ir.Instruction, w: u7, repeat: u8) !void {
    const ext = try c.byte();
    if (repeat != 0 and ext != 0x1e and ext != 0x38 and ext != 0x6f and ext != 0x7f and ext != 0x70 and ext != 0x7e and !(repeat == 0xf3 and (ext == 0xbc or ext == 0xbd))) return error.UnsupportedRepeatPrefix;
    switch (ext) {
        0x10, 0x11, 0x28, 0x29, 0x54, 0x56, 0x57, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x7e, 0x7f, 0xc4, 0xc5, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe8, 0xe9, 0xea, 0xeb, 0xec, 0xed, 0xee, 0xef, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe => try decodeVector(c, i, ext, repeat),
        0x05 => {
            i.op = .syscall;
            i.width = 64;
        },
        0x38 => try decodeExtended38(c, i, repeat),
        0x3a => try decodeExtended3A(c, i, repeat),
        0x1e => {
            if (repeat != 0xf3 or try c.byte() != 0xfa) return error.UnsupportedInstruction;
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
        0xb0, 0xb1 => {
            i.width = if (ext == 0xb0) 8 else w;
            const o = try c.operands(i.width);
            i.op = .cmpxchg;
            i.dst = o.rm;
            i.src = o.reg;
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
    const element: u4 = switch (ext) {
        0x00, 0x04, 0x08, 0x1c, 0x38, 0x3c => 1,
        0x01, 0x03, 0x05, 0x07, 0x09, 0x0b, 0x1d => 2,
        0x3a, 0x3e => 2,
        0x39, 0x3b, 0x3d, 0x3f, 0x40 => 4,
        0x02, 0x06 => 4,
        0x0a, 0x1e => 4,
        0x28 => 8,
        0x29 => 8,
        0x2b, 0x41 => 2,
        0x20, 0x30 => 2,
        0x21, 0x23, 0x31, 0x33 => 4,
        0x22, 0x24, 0x25, 0x32, 0x34, 0x35 => 8,
        else => return error.UnsupportedInstruction,
    };
    if (!c.word or repeat != 0) return error.UnsupportedInstruction;
    const o = try c.operands(32);
    i.op = switch (ext) {
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
    i.vector_aligned = !(extends or ext == 0x28 or ext == 0x2b or ext == 0x41);
    i.set_flags = false;
}

fn decodeExtended3A(c: *Cursor, i: *ir.Instruction, repeat: u8) !void {
    if (try c.byte() != 0x0f or !c.word or repeat != 0) return error.UnsupportedInstruction;
    const o = try c.operands(32);
    i.op = .vector_align_right;
    i.dst = .{ .vector = @intCast(o.reg.reg.index) };
    i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
    i.shuffle = try c.byte();
    i.vector_aligned = true;
    i.set_flags = false;
}

fn decodeVector(c: *Cursor, i: *ir.Instruction, ext: u8, repeat: u8) !void {
    if (c.word and repeat != 0) return error.UnsupportedRepeatPrefix;
    switch (ext) {
        0xc4 => {
            if (!c.word or repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.op = .vector_insert_word;
            i.dst = .{ .vector = @intCast(o.reg.reg.index) };
            i.src = o.rm;
            i.width = 16;
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
        0x10, 0x11, 0x28, 0x29, 0x54, 0x56, 0x57, 0x6f, 0x7f, 0xdb, 0xdf, 0xeb, 0xef => {
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
