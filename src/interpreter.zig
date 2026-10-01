const std = @import("std");
const ir = @import("ir.zig");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
const operands = @import("operands.zig");
pub const address = operands.address;
pub const read = operands.read;
pub const write = operands.write;
fn status(s: *State, v: u64, width: u7) void {
    s.flags.zero = v == 0;
    s.flags.sign = v & (@as(u64, 1) << @as(u6, @intCast(width - 1))) != 0;
    s.flags.parity = @popCount(@as(u8, @truncate(v))) % 2 == 0;
}
pub fn condition(s: *State, c: ir.Condition) bool {
    const f = s.flags;
    return switch (c) {
        .always => true,
        .eq => f.zero,
        .ne => !f.zero,
        .lt => f.sign != f.overflow,
        .ge => f.sign == f.overflow,
        .le => f.zero or f.sign != f.overflow,
        .gt => !f.zero and f.sign == f.overflow,
        .below => if (s.architecture == .arm64) !f.carry else f.carry,
        .above_equal => if (s.architecture == .arm64) f.carry else !f.carry,
        .below_equal => (if (s.architecture == .arm64) !f.carry else f.carry) or f.zero,
        .above => (if (s.architecture == .arm64) f.carry else !f.carry) and !f.zero,
        .overflow => f.overflow,
        .no_overflow => !f.overflow,
        .sign => f.sign,
        .no_sign => !f.sign,
        .parity => f.parity,
        .no_parity => !f.parity,
    };
}
fn compare(c: ir.Condition, a: u64, b: u64, width: u7) !bool {
    return switch (c) {
        .always => true,
        .eq => a == b,
        .ne => a != b,
        .lt => ir.signed(a, width) < ir.signed(b, width),
        .ge => ir.signed(a, width) >= ir.signed(b, width),
        .le => ir.signed(a, width) <= ir.signed(b, width),
        .gt => ir.signed(a, width) > ir.signed(b, width),
        .below => a < b,
        .above_equal => a >= b,
        .below_equal => a <= b,
        .above => a > b,
        else => error.InvalidCondition,
    };
}
fn push(s: *State, m: *Memory, value: u64, width: u7) !void {
    const sp = s.stackRegister();
    const addr = s.get(sp) -% (width / 8);
    try m.writeInt(addr, width, value);
    s.set(sp, addr);
}
fn pop(s: *State, m: *Memory, width: u7) !u64 {
    const sp = s.stackRegister();
    const value = try m.readInt(s.get(sp), width, .read);
    s.set(sp, s.get(sp) +% (width / 8));
    return value;
}
pub fn execute(s: *State, m: *Memory, i: ir.Instruction) !bool {
    const w = i.width;
    const mask = ir.mask(w);
    var next = i.next;
    const updated = if (i.update_reg) |r| s.get(r) +% @as(u64, @bitCast(i.update_delta)) else @as(u64, 0);
    switch (i.op) {
        .nop => {},
        .clear_exclusive => s.exclusive = null,
        .load_exclusive => {
            const sw = i.source_width;
            const addr = address(s, i.src.mem, i.next);
            if (addr % (sw / 8) != 0) return error.MisalignedMemory;
            const value = try m.readInt(addr, sw, .read);
            try write(s, m, i.dst, w, if (i.sign_result) @bitCast(ir.signed(value, sw)) else value, i.next);
            s.exclusive = .{ .address = addr, .width = sw, .writes = m.writes, .generation = m.generation };
        },
        .store_exclusive => {
            const addr = address(s, i.dst.mem, i.next);
            if (addr % (w / 8) != 0) return error.MisalignedMemory;
            if (s.architecture == .riscv64) try m.check(addr, w / 8, .write);
            const saved = s.exclusive;
            s.exclusive = null;
            // ponytail: any write invalidates the reservation; track granules when guest threads exist.
            const pass = if (saved) |e| e.address == addr and e.width == w and e.writes == m.writes and e.generation == m.generation else false;
            if (pass) try m.writeInt(addr, w, try read(s, m, i.src, w, i.next));
            try write(s, m, i.rhs.?, 32, @intFromBool(!pass), i.next);
        },
        .atomic_swap, .atomic_add, .atomic_xor, .atomic_and, .atomic_or, .atomic_min_signed, .atomic_max_signed, .atomic_min_unsigned, .atomic_max_unsigned => {
            const addr = address(s, i.dst.mem, i.next);
            if (addr % (w / 8) != 0) return error.MisalignedMemory;
            const old = try m.readInt(addr, w, .read);
            const argument = try read(s, m, i.src, w, i.next);
            const value = switch (i.op) {
                .atomic_swap => argument,
                .atomic_add => old +% argument,
                .atomic_xor => old ^ argument,
                .atomic_and => old & argument,
                .atomic_or => old | argument,
                .atomic_min_signed => if (ir.signed(old, w) < ir.signed(argument, w)) old else argument,
                .atomic_max_signed => if (ir.signed(old, w) > ir.signed(argument, w)) old else argument,
                .atomic_min_unsigned => @min(old, argument),
                .atomic_max_unsigned => @max(old, argument),
                else => unreachable,
            };
            try m.writeInt(addr, w, value);
            try write(s, m, i.rhs.?, 64, if (i.sign_result) @bitCast(ir.signed(old, w)) else old, i.next);
        },
        .zero_block => {
            const addr = (try read(s, m, i.src, 64, i.next)) & ~@as(u64, 63);
            try m.write(addr, &@as([64]u8, @splat(0)));
        },
        .direction => s.flags.direction = i.src.imm != 0,
        .string_move, .string_store, .string_load, .string_compare, .string_scan => {
            const address_mask = ir.mask(i.address_width);
            const count = s.get(1) & address_mask;
            if (i.repeat == .none or count != 0) {
                if (i.op == .string_compare or i.op == .string_scan) {
                    var cmp = i;
                    cmp.op = .cmp;
                    try arithmetic(s, m, cmp);
                } else try write(s, m, i.dst, w, try read(s, m, i.src, w, i.next), i.next);
                const delta: u64 = if (s.flags.direction) 0 -% @as(u64, w / 8) else w / 8;
                for ([_]ir.Operand{ i.src, i.dst }) |operand| {
                    if (operand == .mem) {
                        const reg = operand.mem.index.?;
                        s.set(reg, (s.get(reg) +% delta) & address_mask);
                    }
                }
                if (i.repeat != .none) {
                    s.set(1, count - 1);
                    // One element per step keeps REP bounded by runtime limits.
                    if (count > 1 and switch (i.repeat) {
                        .count => true,
                        .equal => s.flags.zero,
                        .not_equal => !s.flags.zero,
                        .none => unreachable,
                    }) next = i.pc;
                }
            }
        },
        .vector_duplicate, .vector_load_pair, .vector_store_pair, .vector_shl, .vector_shr, .vector_sar, .vector_byte_shl, .vector_byte_shr, .vector_add, .vector_sub, .vector_add_saturate_signed, .vector_add_saturate_unsigned, .vector_sub_saturate_signed, .vector_sub_saturate_unsigned, .vector_mul_low, .vector_mul_low_dword, .vector_mul_high_signed, .vector_mul_high_unsigned, .vector_mul_high_round, .vector_mul_even_unsigned, .vector_madd_signed, .vector_madd_unsigned_signed_sat, .vector_average_unsigned, .vector_sum_abs_diff, .vector_pack_signed_byte, .vector_pack_signed_word, .vector_pack_unsigned_byte, .vector_insert_word, .vector_shuffle_bytes, .vector_align_right, .vector_sign, .vector_abs, .vector_horizontal_add, .vector_horizontal_add_saturate_signed, .vector_horizontal_sub, .vector_horizontal_sub_saturate_signed, .vector_min_unsigned, .vector_max_unsigned, .vector_min_signed, .vector_max_signed, .vector_mask, .vector_compare_equal, .vector_compare_greater_signed, .scalar_to_vector, .vector_to_scalar, .vector_move_low, .vector_unpack_low, .vector_unpack_high, .vector_shuffle, .vector_mov, .vector_xor, .vector_and, .vector_and_not, .vector_or => try @import("vector.zig").execute(s, m, i),
        .conditional_compare_add, .conditional_compare_sub => {
            if (condition(s, i.condition)) {
                const a = try read(s, m, i.lhs.?, w, i.next);
                const b = try read(s, m, i.src, w, i.next);
                const subtract = i.op == .conditional_compare_sub;
                const value = (if (subtract) a -% b else a +% b) & mask;
                status(s, value, w);
                s.flags.carry = if (subtract) a >= b else @as(u128, a) + b > mask;
                const signed_full = if (subtract) @as(i128, ir.signed(a, w)) - ir.signed(b, w) else @as(i128, ir.signed(a, w)) + ir.signed(b, w);
                s.flags.overflow = signed_full != ir.signed(value, w);
            } else {
                const nzcv = i.rhs.?.imm;
                s.flags.sign = nzcv & 8 != 0;
                s.flags.zero = nzcv & 4 != 0;
                s.flags.carry = nzcv & 2 != 0;
                s.flags.overflow = nzcv & 1 != 0;
            }
        },
        .bit_test, .bit_set, .bit_reset, .bit_complement => {
            const index = try read(s, m, i.src, w, i.next);
            var dst = i.dst;
            if (dst == .mem and i.src == .reg) {
                const offset = @divFloor(ir.signed(index, w), @as(i64, w)) * @as(i64, w / 8);
                dst = .{ .mem = .{ .displacement = @bitCast(address(s, dst.mem, i.next) +% @as(u64, @bitCast(offset))) } };
            }
            const value = try read(s, m, dst, w, i.next);
            const bit = @as(u64, 1) << @as(u6, @intCast(index & (w - 1)));
            s.flags.carry = value & bit != 0;
            if (i.op != .bit_test) try write(s, m, dst, w, switch (i.op) {
                .bit_set => value | bit,
                .bit_reset => value & ~bit,
                .bit_complement => value ^ bit,
                else => unreachable,
            }, i.next);
        },
        .bit_scan_forward, .bit_scan_reverse => {
            const v = try read(s, m, i.src, w, i.next);
            s.flags.zero = v == 0;
            if (v != 0) try write(s, m, i.dst, w, if (i.op == .bit_scan_forward) @as(u64, @ctz(v)) else 63 - @as(u64, @clz(v)), i.next);
        },
        .bit_reverse => {
            const value = try read(s, m, i.src, w, i.next);
            try write(s, m, i.dst, w, @bitReverse(value) >> @as(u6, @intCast(64 - w)), i.next);
        },
        .count_trailing_zeros, .count_leading_zeros => {
            const value = try read(s, m, i.src, w, i.next);
            const count: u64 = if (value == 0) w else if (i.op == .count_trailing_zeros) @ctz(value) else @clz(value) - (64 - @as(u64, w));
            if (i.set_flags) {
                s.flags.carry = value == 0;
                s.flags.zero = count == 0;
            }
            try write(s, m, i.dst, w, count, i.next);
        },
        .cmpxchg => {
            const dst = try read(s, m, i.dst, w, i.next);
            const acc = try read(s, m, ir.reg(0), w, i.next);
            const value = (acc -% dst) & mask;
            status(s, value, w);
            s.flags.carry = acc < dst;
            s.flags.overflow = @as(i128, ir.signed(acc, w)) - ir.signed(dst, w) != ir.signed(value, w);
            if (acc == dst) try write(s, m, i.dst, w, try read(s, m, i.src, w, i.next), i.next) else try write(s, m, ir.reg(0), w, dst, i.next);
        },
        .bitfield_unsigned, .bitfield_signed, .bitfield_insert => {
            const src = try read(s, m, i.src, w, i.next);
            const dst = try read(s, m, i.dst, w, i.next);
            const rotated = ir.rotate(src, w, i.rotate);
            const bot = (if (i.op == .bitfield_insert) dst & ~i.bit_mask else @as(u64, 0)) | (rotated & i.bit_mask);
            const top = if (i.op == .bitfield_insert) dst else if (i.op == .bitfield_signed and (src >> i.sign_bit) & 1 != 0) ir.mask(w) else @as(u64, 0);
            try write(s, m, i.dst, w, (top & ~i.top_mask) | (bot & i.top_mask), i.next);
        },
        .load_pair, .store_pair => {
            const addr = address(s, i.lhs.?.mem, i.next);
            const size: u64 = w / 8;
            try m.check(addr, @as(usize, w / 8) * 2, if (i.op == .load_pair) .read else .write);
            if (i.op == .load_pair) {
                const a = try m.readInt(addr, w, .read);
                const b = try m.readInt(addr + size, w, .read);
                const dw: u7 = if (i.sign_result) 64 else w;
                try write(s, m, i.dst, dw, if (i.sign_result) @bitCast(ir.signed(a, w)) else a, i.next);
                try write(s, m, i.src, dw, if (i.sign_result) @bitCast(ir.signed(b, w)) else b, i.next);
            } else {
                const a = try read(s, m, i.dst, w, i.next);
                const b = try read(s, m, i.src, w, i.next);
                try m.writeInt(addr, w, a);
                try m.writeInt(addr + size, w, b);
            }
        },
        .madd, .msub => {
            const sw = if (i.source_width == 0) w else i.source_width;
            const raw_a = try read(s, m, i.lhs.?, sw, i.next);
            const raw_b = try read(s, m, i.src, sw, i.next);
            const a = if (i.multiply_signed) @as(u64, @bitCast(ir.signed(raw_a, sw))) else raw_a;
            const b = if (i.multiply_signed) @as(u64, @bitCast(ir.signed(raw_b, sw))) else raw_b;
            const accumulator = try read(s, m, i.rhs.?, w, i.next);
            try write(s, m, i.dst, w, if (i.op == .madd) accumulator +% (a *% b) else accumulator -% (a *% b), i.next);
        },
        .select => {
            var value = try read(s, m, if (condition(s, i.condition)) i.lhs.? else i.src, w, i.next);
            if (!condition(s, i.condition)) value = switch (i.false_op) {
                .none => value,
                .inc => value +% 1,
                .invert => ~value,
                .negate => 0 -% value,
            };
            try write(s, m, i.dst, w, value, i.next);
        },
        .mov, .movzx, .movsx => {
            const sw = if (i.source_width == 0) w else i.source_width;
            const value = try read(s, m, i.src, sw, i.next);
            try write(s, m, i.dst, w, if (i.op == .movsx) @bitCast(ir.signed(value, sw)) else value, i.next);
        },
        .lea => {
            if (i.src != .mem) return error.InvalidInstruction;
            var a = i.src.mem;
            a.segment = .none;
            try write(s, m, i.dst, w, address(s, a, i.next), i.next);
        },
        .add, .sub, .adc, .sbb, .and_, .or_, .xor, .cmp, .test_, .inc, .dec, .neg, .not_, .shl, .shr, .sar, .rol, .ror, .imul => try arithmetic(s, m, i),
        .set_compare => {
            const a = try read(s, m, i.lhs orelse i.dst, w, i.next);
            const b = try read(s, m, i.src, w, i.next);
            try write(s, m, i.dst, w, @intFromBool(try compare(i.condition, a, b, w)), i.next);
        },
        .mul_high_signed, .mul_high_mixed, .mul_high_unsigned, .divide_signed, .divide_unsigned, .remainder_signed, .remainder_unsigned => {
            const a = try read(s, m, i.lhs orelse i.dst, w, i.next);
            const b = try read(s, m, i.src, w, i.next);
            var value: u64 = 0;
            switch (i.op) {
                .mul_high_unsigned => {
                    value = @truncate((@as(u128, a) * b) >> 64);
                },
                .mul_high_signed, .mul_high_mixed => {
                    const product = @as(i128, ir.signed(a, 64)) * (if (i.op == .mul_high_signed) @as(i128, ir.signed(b, 64)) else @as(i128, b));
                    value = @truncate(@as(u128, @bitCast(product)) >> 64);
                },
                .divide_unsigned => {
                    value = if (b == 0) (if (s.architecture == .arm64) @as(u64, 0) else ir.mask(w)) else a / b;
                },
                .remainder_unsigned => {
                    value = if (b == 0) a else a % b;
                },
                .divide_signed, .remainder_signed => {
                    const sa = ir.signed(a, w);
                    const sb = ir.signed(b, w);
                    const minimum = -(@as(i128, 1) << @as(u7, @intCast(w - 1)));
                    value = if (sb == 0) (if (i.op == .divide_signed) (if (s.architecture == .arm64) @as(u64, 0) else ir.mask(w)) else a) else if (sa == minimum and sb == -1) (if (i.op == .divide_signed) a else 0) else @bitCast(if (i.op == .divide_signed) @divTrunc(sa, sb) else @rem(sa, sb));
                },
                else => unreachable,
            }
            try write(s, m, i.dst, w, value, i.next);
            if (i.sign_result and i.dst == .reg) s.set(i.dst.reg.index, @bitCast(ir.signed(value, w)));
        },
        .mul => try implicitMultiply(s, m, i, false),
        .div, .idiv => try divide(s, m, i),
        .push => try push(s, m, try read(s, m, i.src, w, i.next), w),
        .pop => {
            if (i.lhs) |o| s.set(s.stackRegister(), try read(s, m, o, 64, i.next));
            const v = try pop(s, m, w);
            try write(s, m, i.dst, w, v, i.next);
        },
        .branch => {
            const take = if (i.lhs) |lhs| try compare(i.condition, try read(s, m, lhs, w, i.next), try read(s, m, i.rhs orelse .none, w, i.next), w) else condition(s, i.condition);
            if (take) next = (try read(s, m, i.src, 64, i.next)) & i.target_mask;
        },
        .call => {
            const target = (try read(s, m, i.src, 64, i.next)) & i.target_mask;
            if (s.architecture == .x86_64) try push(s, m, i.next, 64) else try write(s, m, i.dst, 64, i.next, i.next);
            next = target;
        },
        .ret => {
            next = try pop(s, m, 64);
            s.set(s.stackRegister(), s.get(s.stackRegister()) +% (try read(s, m, i.src, 64, i.next)));
        },
        .setcc => try write(s, m, i.dst, 8, @intFromBool(condition(s, i.condition)), i.next),
        .cmov => {
            const v = try read(s, m, i.src, w, i.next);
            if (condition(s, i.condition)) try write(s, m, i.dst, w, v, i.next);
        },
        .exchange => {
            const a = try read(s, m, i.dst, w, i.next);
            const b = try read(s, m, i.src, w, i.next);
            try write(s, m, i.dst, w, b, i.next);
            try write(s, m, i.src, w, a, i.next);
        },
        .sign_extend => {
            const a = s.get(0) & mask;
            try write(s, m, ir.reg(2), w, if (ir.signed(a, w) < 0) mask else 0, i.next);
        },
        .syscall => {
            if (s.architecture == .x86_64) {
                s.set(1, i.next);
                s.set(11, s.flags.bits());
            }
            s.pc = next;
            s.instructions += 1;
            return true;
        },
        .riscv_fp => try @import("cpu/riscv64.zig").executeFp(s, m, i.encoding),
    }
    if (i.update_reg) |r| s.set(r, updated);
    s.pc = next;
    s.instructions += 1;
    return false;
}
fn arithmetic(s: *State, m: *Memory, i: ir.Instruction) !void {
    const w = i.width;
    const mask = ir.mask(w);
    const old_carry = s.flags.carry;
    if (i.op == .imul and i.dst == .none) {
        try implicitMultiply(s, m, i, true);
        return;
    }
    const a = try read(s, m, i.lhs orelse i.dst, w, i.next);
    const b = if (i.op == .inc or i.op == .dec) @as(u64, 1) else try read(s, m, i.src, w, i.next);
    var v: u64 = 0;
    var cf = false;
    var of = false;
    var update = i.set_flags;
    switch (i.op) {
        .add, .adc, .inc => {
            const carry: u64 = if (i.op == .adc and old_carry) 1 else 0;
            const full = @as(u128, a) + b + carry;
            v = @truncate(full & mask);
            cf = full > mask;
            const signed_full = @as(i128, ir.signed(a, w)) + ir.signed(b, w) + carry;
            of = signed_full != ir.signed(v, w);
        },
        .sub, .sbb, .cmp, .dec => {
            const carry: u64 = if (i.op == .sbb and (if (s.architecture == .arm64) !old_carry else old_carry)) 1 else 0;
            v = (a -% b -% carry) & mask;
            cf = @as(u128, a) < @as(u128, b) + carry;
            const full = @as(i128, ir.signed(a, w)) - ir.signed(b, w) - carry;
            of = full != ir.signed(v, w);
        },
        .neg => {
            v = (0 -% a) & mask;
            cf = a != 0;
            of = a == (@as(u64, 1) << @as(u6, @intCast(w - 1)));
        },
        .not_ => {
            v = (~a) & mask;
            update = false;
        },
        .and_, .test_ => {
            v = a & b;
        },
        .or_ => {
            v = a | b;
        },
        .xor => {
            v = a ^ b;
        },
        .rol, .ror => {
            const count: u6 = @intCast(b & (if (w == 64) @as(u64, 63) else 31));
            v = ir.rotate(a, w, if (i.op == .rol) 0 -% count else count);
            if (i.set_flags and count != 0) {
                const high = v >> @as(u6, @intCast(w - 1)) != 0;
                s.flags.carry = if (i.op == .rol) v & 1 != 0 else high;
                if (count == 1) s.flags.overflow = high != (if (i.op == .rol) s.flags.carry else (v >> @as(u6, @intCast(w - 2))) & 1 != 0);
            }
            update = false;
        },
        .shl, .shr, .sar => {
            const count: u6 = @intCast(b & (if (w == 64) @as(u64, 63) else 31));
            if (count == 0) {
                try write(s, m, i.dst, w, a, i.next);
                if (i.sign_result and i.dst == .reg) s.set(i.dst.reg.index, @bitCast(ir.signed(a, w)));
                return;
            }
            const wide: u128 = a;
            v = switch (i.op) {
                .shl => @truncate((wide << count) & mask),
                .shr => @intCast(wide >> count),
                .sar => @as(u64, @bitCast(ir.signed(a, w) >> count)) & mask,
                else => unreachable,
            };
            cf = if (count > w) false else if (i.op == .shl) (wide >> @as(u7, @intCast(w - count))) & 1 != 0 else (wide >> @as(u7, @intCast(count - 1))) & 1 != 0;
            of = if (count != 1) s.flags.overflow else if (i.op == .shl) ((v >> @as(u6, @intCast(w - 1))) & 1 != @intFromBool(cf)) else if (i.op == .shr) a >> @as(u6, @intCast(w - 1)) != 0 else false;
        },
        .imul => {
            const full = @as(i128, ir.signed(a, w)) * ir.signed(b, w);
            v = @as(u64, @truncate(@as(u128, @bitCast(full)))) & mask;
            cf = full != ir.signed(v, w);
            of = cf;
        },
        else => unreachable,
    }
    if (update) {
        status(s, v, w);
        s.flags.carry = if (i.op == .inc or i.op == .dec) old_carry else cf;
        if (s.architecture == .arm64 and (i.op == .sub or i.op == .sbb or i.op == .cmp)) s.flags.carry = !cf;
        s.flags.overflow = of;
    }
    if (i.op != .cmp and i.op != .test_) {
        try write(s, m, i.dst, w, v, i.next);
        if (i.sign_result and i.dst == .reg) s.set(i.dst.reg.index, @bitCast(ir.signed(v, w)));
    }
}
fn implicitMultiply(s: *State, m: *Memory, i: ir.Instruction, is_signed: bool) !void {
    const w = i.width;
    const a = s.get(0) & ir.mask(w);
    const b = try read(s, m, i.src, w, i.next);
    const product: u128 = if (is_signed) @bitCast(@as(i128, ir.signed(a, w)) * ir.signed(b, w)) else @as(u128, a) * b;
    const low = @as(u64, @truncate(product)) & ir.mask(w);
    const high = @as(u64, @truncate(product >> w)) & ir.mask(w);
    if (w == 8) try write(s, m, ir.reg(0), 16, @truncate(product), i.next) else {
        try write(s, m, ir.reg(0), w, low, i.next);
        try write(s, m, ir.reg(2), w, high, i.next);
    }
    s.flags.carry = if (is_signed) @as(i128, @bitCast(product)) != ir.signed(low, w) else high != 0;
    s.flags.overflow = s.flags.carry;
}
fn divide(s: *State, m: *Memory, i: ir.Instruction) !void {
    const w = i.width;
    const b = try read(s, m, i.src, w, i.next);
    if (b == 0) return error.DivisionByZero;
    const numerator: u128 = if (w == 8) s.get(0) & 0xffff else (@as(u128, s.get(2) & ir.mask(w)) << w) | (s.get(0) & ir.mask(w));
    var quotient: u64 = 0;
    var remainder: u64 = 0;
    if (i.op == .div) {
        const q = numerator / b;
        if (q > ir.mask(w)) return error.DivisionOverflow;
        quotient = @intCast(q);
        remainder = @intCast(numerator % b);
    } else {
        const shift: u7 = @intCast(128 - @as(u8, w) * 2);
        const a = @as(i128, @bitCast(numerator << shift)) >> shift;
        const divisor = @as(i128, ir.signed(b, w));
        if (a == std.math.minInt(i128) and divisor == -1) return error.DivisionOverflow;
        const q = @divTrunc(a, divisor);
        if (q < -(@as(i128, 1) << @as(u7, @intCast(w - 1))) or q >= (@as(i128, 1) << @as(u7, @intCast(w - 1)))) return error.DivisionOverflow;
        quotient = @truncate(@as(u128, @bitCast(q)));
        remainder = @truncate(@as(u128, @bitCast(@rem(a, divisor))));
    }
    if (w == 8) try write(s, m, ir.reg(0), 16, ((remainder & 255) << 8) | (quotient & 255), i.next) else {
        try write(s, m, ir.reg(0), w, quotient, i.next);
        try write(s, m, ir.reg(2), w, remainder, i.next);
    }
}
test "flags, high bytes, zero extension, and carry overflow" {
    var s = State{ .architecture = .x86_64 };
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    s.set(0, 0x7fffffff);
    _ = try execute(&s, &m, .{ .op = .add, .dst = ir.reg(0), .src = ir.imm(1), .width = 32 });
    try std.testing.expect(s.flags.overflow and s.flags.sign);
    s.set(0, 0xffffffffffffffff);
    _ = try execute(&s, &m, .{ .op = .mov, .dst = ir.reg(0), .src = ir.imm(1), .width = 32 });
    try std.testing.expectEqual(@as(u64, 1), s.get(0));
    try write(&s, &m, .{ .reg = .{ .index = 0, .high = true } }, 8, 0xab, 0);
    try std.testing.expectEqual(@as(u64, 0xab01), s.get(0));
    s.set(0, 255);
    s.flags.carry = true;
    _ = try execute(&s, &m, .{ .op = .adc, .dst = ir.reg(0), .src = ir.imm(127), .width = 8 });
    try std.testing.expect(s.flags.carry and !s.flags.overflow);
}

test "zero-count three-operand shift still writes destination without changing flags" {
    var s = State{ .architecture = .riscv64 };
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    s.set(1, 0xffffffffffffffff);
    s.set(2, 123);
    s.flags.carry = true;
    _ = try execute(&s, &m, .{ .op = .shr, .dst = ir.reg(2), .lhs = ir.reg(1), .src = ir.imm(0), .set_flags = false });
    try std.testing.expectEqual(s.get(1), s.get(2));
    try std.testing.expect(s.flags.carry);
    _ = try execute(&s, &m, .{ .op = .shl, .dst = ir.reg(2), .lhs = ir.reg(1), .src = ir.imm(0), .width = 32, .sign_result = true, .set_flags = false });
    try std.testing.expectEqual(@as(u64, 0xffffffffffffffff), s.get(2));
}

test "FS-based loads and LEA address calculation have distinct semantics" {
    var s = State{ .architecture = .x86_64, .fs_base = 0x1000 };
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.writeInt(0x1008, 64, 42);
    const source = ir.Operand{ .mem = .{ .segment = .fs, .displacement = 8 } };
    _ = try execute(&s, &m, .{ .op = .mov, .dst = ir.reg(0), .src = source });
    try std.testing.expectEqual(@as(u64, 42), s.get(0));
    _ = try execute(&s, &m, .{ .op = .lea, .dst = ir.reg(0), .src = source });
    try std.testing.expectEqual(@as(u64, 8), s.get(0));
}

test "bit scans and compare exchange update the architectural result" {
    var s = State{ .architecture = .x86_64 };
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    s.set(1, 0x80000000);
    _ = try execute(&s, &m, .{ .op = .bit_scan_reverse, .dst = ir.reg(2), .src = ir.reg(1), .width = 32 });
    try std.testing.expectEqual(@as(u64, 31), s.get(2));
    s.set(0, 4);
    s.set(1, 4);
    s.set(2, 7);
    _ = try execute(&s, &m, .{ .op = .cmpxchg, .dst = ir.reg(1), .src = ir.reg(2) });
    try std.testing.expect(s.flags.zero);
    try std.testing.expectEqual(@as(u64, 7), s.get(1));
    _ = try execute(&s, &m, .{ .op = .cmpxchg, .dst = ir.reg(1), .src = ir.reg(2) });
    try std.testing.expect(!s.flags.zero);
    try std.testing.expectEqual(@as(u64, 7), s.get(0));
}

test "conditional ARM compares use explicit NZCV on the false path" {
    var s = State{ .architecture = .arm64 };
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    _ = try execute(&s, &m, .{ .op = .conditional_compare_sub, .lhs = ir.imm(1), .src = ir.imm(1), .rhs = ir.imm(4), .condition = .eq });
    try std.testing.expect(s.flags.zero and !s.flags.carry);
    _ = try execute(&s, &m, .{ .op = .conditional_compare_sub, .lhs = ir.imm(1), .src = ir.imm(1), .rhs = ir.imm(0), .condition = .eq });
    try std.testing.expect(s.flags.zero and s.flags.carry);
}

test "SIMD byte comparison and movemask preserve flags" {
    var s = State{ .architecture = .x86_64 };
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    s.vectors[1][0] = 1;
    s.flags.carry = true;
    _ = try execute(&s, &m, .{ .op = .vector_compare_equal, .dst = .{ .vector = 0 }, .src = .{ .vector = 1 }, .vector_element = 1 });
    _ = try execute(&s, &m, .{ .op = .vector_mask, .dst = ir.reg(8), .src = .{ .vector = 0 }, .width = 32 });
    try std.testing.expectEqual(@as(u64, 0xfffe), s.get(8));
    try std.testing.expect(s.flags.carry);
}

test "bit operations address memory bit strings across words" {
    var s = State{ .architecture = .x86_64 };
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    s.set(1, 70);
    const operand = ir.Operand{ .mem = .{ .displacement = 0x1000 } };
    _ = try execute(&s, &m, .{ .op = .bit_set, .dst = operand, .src = ir.reg(1) });
    try std.testing.expect(!s.flags.carry);
    try std.testing.expectEqual(@as(u64, 64), try m.readInt(0x1008, 64, .read));
    _ = try execute(&s, &m, .{ .op = .bit_reset, .dst = operand, .src = ir.reg(1) });
    try std.testing.expect(s.flags.carry);
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1008, 64, .read));
}

test "packed shifts saturate the count rather than masking it" {
    var s = State{ .architecture = .x86_64 };
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    s.vectors[0] = @splat(255);
    _ = try execute(&s, &m, .{ .op = .vector_shr, .dst = .{ .vector = 0 }, .src = ir.imm(32), .vector_element = 4 });
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), &s.vectors[0]);
    s.vectors[0] = @splat(255);
    _ = try execute(&s, &m, .{ .op = .vector_sar, .dst = .{ .vector = 0 }, .src = ir.imm(32), .vector_element = 4 });
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(255)), &s.vectors[0]);
}
