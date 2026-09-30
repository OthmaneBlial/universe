const std = @import("std");
const ir = @import("ir.zig");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
pub fn address(s: *State, a: ir.Address, next: u64) u64 {
    return (if (a.relative) next else if (a.base) |r| s.get(r) else @as(u64, 0)) +% (if (a.index) |r| (if (a.index_signed) @as(u64, @bitCast(ir.signed(s.get(r), a.index_width))) else s.get(r) & ir.mask(a.index_width)) << a.scale else @as(u64, 0)) +% @as(u64, @bitCast(a.displacement));
}
pub fn read(s: *State, m: *Memory, o: ir.Operand, width: u7, next: u64) !u64 {
    return (switch (o) {
        .none => @as(u64, 0),
        .shifted => |r| blk: {
            const v = s.get(r.index) & ir.mask(r.width);
            const shifted = switch (r.kind) {
                .lsl => v << r.amount,
                .lsr => v >> r.amount,
                .asr => @as(u64, @bitCast(ir.signed(v, r.width) >> r.amount)),
                .ror => ir.rotate(v, r.width, r.amount),
            };
            break :blk (if (r.invert) ~shifted else shifted) & r.mask;
        },
        .imm => |v| v,
        .reg => |r| if (r.high) s.get(r.index) >> 8 else s.get(r.index),
        .address => |a| address(s, a, next),
        .mem => |a| try m.readInt(address(s, a, next), width, .read),
    }) & ir.mask(width);
}
pub fn write(s: *State, m: *Memory, o: ir.Operand, width: u7, value: u64, next: u64) !void {
    const v = value & ir.mask(width);
    switch (o) {
        .reg => |r| {
            const old = s.get(r.index);
            s.set(r.index, if (r.high) (old & ~@as(u64, 0xff00)) | (v << 8) else if (width >= 32) v else (old & ~ir.mask(width)) | v);
        },
        .mem => |a| try m.writeInt(address(s, a, next), width, v),
        else => return error.InvalidDestination,
    }
}
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
    const old_carry = s.flags.carry;
    var next = i.next;
    const updated = if (i.update_reg) |r| s.get(r) +% @as(u64, @bitCast(i.update_delta)) else @as(u64, 0);
    switch (i.op) {
        .nop => {},
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
            const a = try read(s, m, i.lhs.?, w, i.next);
            const b = try read(s, m, i.src, w, i.next);
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
            try write(s, m, i.dst, w, address(s, i.src.mem, i.next), i.next);
        },
        .add, .sub, .adc, .sbb, .and_, .or_, .xor, .cmp, .test_, .inc, .dec, .neg, .not_, .shl, .shr, .sar, .ror, .imul => {
            if (i.op == .imul and i.dst == .none) {
                try implicitMultiply(s, m, i, true);
                s.pc = next;
                s.instructions += 1;
                return false;
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
                .shl, .shr, .sar, .ror => {
                    const count: u6 = @intCast(b & (if (w == 64) @as(u64, 63) else 31));
                    if (count == 0) {
                        s.pc = next;
                        s.instructions += 1;
                        return false;
                    }
                    const wide: u128 = a;
                    v = switch (i.op) {
                        .ror => ir.rotate(a, w, count),
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
        },
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
    }
    if (i.update_reg) |r| s.set(r, updated);
    s.pc = next;
    s.instructions += 1;
    return false;
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
