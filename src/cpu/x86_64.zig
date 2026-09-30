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
    while (true) {
        if (op >= 0x40 and op <= 0x4f) c.rex = op else if (op == 0x64 or op == 0x65) {
            c.segment = if (op == 0x64) .fs else .gs;
            c.rex = 0;
        } else if (op == 0x2e or op == 0x3e or op == 0x26 or op == 0x36) {
            c.rex = 0;
        } else if (op == 0x66) {
            c.word = true;
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
    if (repeat != 0 and op != 0x0f) return error.UnsupportedRepeatPrefix;
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
    if (repeat != 0 and ext != 0x1e and ext != 0x6f and ext != 0x7f and ext != 0x70 and ext != 0x7e) return error.UnsupportedRepeatPrefix;
    switch (ext) {
        0x10, 0x11, 0x28, 0x29, 0x54, 0x56, 0x57, 0x60, 0x61, 0x62, 0x6c, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x7e, 0x7f, 0xd6, 0xd7, 0xda, 0xdb, 0xde, 0xdf, 0xeb, 0xef => try decodeVector(c, i, ext, repeat),
        0x05 => {
            i.op = .syscall;
            i.width = 64;
        },
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
            i.op = if (ext == 0xbc) .bit_scan_forward else .bit_scan_reverse;
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

fn decodeVector(c: *Cursor, i: *ir.Instruction, ext: u8, repeat: u8) !void {
    if (c.word and repeat != 0) return error.UnsupportedRepeatPrefix;
    switch (ext) {
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
        0x74, 0x75, 0x76, 0xd7, 0xda, 0xde => {
            if (!c.word or repeat != 0) return error.UnsupportedInstruction;
            const o = try c.operands(32);
            i.set_flags = false;
            if (ext == 0xda or ext == 0xde) {
                i.op = if (ext == 0xda) .vector_min_unsigned else .vector_max_unsigned;
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
                i.op = .vector_compare_equal;
                i.dst = .{ .vector = @intCast(o.reg.reg.index) };
                i.src = if (o.rm == .reg) .{ .vector = @intCast(o.rm.reg.index) } else o.rm;
                i.vector_element = @as(u4, 1) << @as(u2, @intCast(ext - 0x74));
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
        0x60, 0x61, 0x62, 0x6c, 0x70 => {
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
                i.op = .vector_unpack_low;
                i.vector_element = switch (ext) {
                    0x60 => 1,
                    0x61 => 2,
                    0x62 => 4,
                    0x6c => 8,
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
