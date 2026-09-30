const std = @import("std");
const ir = @import("ir.zig");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
const operands = @import("operands.zig");
const read = operands.read;
const write = operands.write;
const address = operands.address;

pub fn execute(s: *State, m: *Memory, i: ir.Instruction) !void {
    const w = i.width;
    switch (i.op) {
        .vector_shl, .vector_shr, .vector_sar => {
            const src = s.vectors[i.dst.vector];
            var value: [16]u8 = undefined;
            const element: usize = i.vector_element;
            const bits: u7 = @intCast(element * 8);
            const count = i.src.imm;
            for (0..16 / element) |n| {
                var bytes: [8]u8 = @splat(0);
                @memcpy(bytes[0..element], src[n * element ..][0..element]);
                const v = std.mem.readInt(u64, &bytes, .little);
                const result = if (count >= bits) (if (i.op == .vector_sar and ir.signed(v, bits) < 0) ir.mask(bits) else @as(u64, 0)) else switch (i.op) {
                    .vector_shl => (v << @as(u6, @intCast(count))) & ir.mask(bits),
                    .vector_shr => v >> @as(u6, @intCast(count)),
                    .vector_sar => @as(u64, @bitCast(ir.signed(v, bits) >> @as(u6, @intCast(count)))) & ir.mask(bits),
                    else => unreachable,
                };
                std.mem.writeInt(u64, &bytes, result, .little);
                @memcpy(value[n * element ..][0..element], bytes[0..element]);
            }
            s.vectors[i.dst.vector] = value;
        },
        .vector_byte_shl, .vector_byte_shr => {
            const src = s.vectors[i.dst.vector];
            var value: [16]u8 = @splat(0);
            const count = i.src.imm;
            if (count < 16) {
                for (0..16) |n| {
                    if (i.op == .vector_byte_shr and n + count < 16) value[n] = src[@intCast(n + count)];
                    if (i.op == .vector_byte_shl and n >= count) value[n] = src[@intCast(n - count)];
                }
            }
            s.vectors[i.dst.vector] = value;
        },
        .vector_min_unsigned, .vector_max_unsigned => {
            const src = try readVector(s, m, i.src, i);
            const dst = try readVector(s, m, i.dst, i);
            var value: [16]u8 = undefined;
            for (&value, src, dst) |*v, a, b| v.* = if (i.op == .vector_min_unsigned) @min(a, b) else @max(a, b);
            s.vectors[i.dst.vector] = value;
        },
        .vector_mask => {
            const bytes = try readVector(s, m, i.src, i);
            var value: u64 = 0;
            for (bytes, 0..) |b, n| value |= @as(u64, b >> 7) << @as(u6, @intCast(n));
            try write(s, m, i.dst, 32, value, i.next);
        },
        .vector_compare_equal => {
            const src = try readVector(s, m, i.src, i);
            const dst = try readVector(s, m, i.dst, i);
            var value: [16]u8 = undefined;
            const element: usize = i.vector_element;
            for (0..16 / element) |n| @memset(value[n * element ..][0..element], if (std.mem.eql(u8, src[n * element ..][0..element], dst[n * element ..][0..element])) 255 else 0);
            s.vectors[i.dst.vector] = value;
        },
        .scalar_to_vector, .vector_to_scalar, .vector_move_low => {
            const value = if (i.src == .vector) std.mem.readInt(u64, s.vectors[i.src.vector][0..8], .little) & ir.mask(w) else try read(s, m, i.src, w, i.next);
            if (i.dst == .vector) {
                var bytes: [16]u8 = @splat(0);
                std.mem.writeInt(u64, bytes[0..8], value, .little);
                s.vectors[i.dst.vector] = bytes;
            } else try write(s, m, i.dst, w, value, i.next);
        },
        .vector_unpack_low, .vector_shuffle => {
            const src = try readVector(s, m, i.src, i);
            var value = src;
            const element: usize = i.vector_element;
            if (i.op == .vector_unpack_low) {
                const dst = try readVector(s, m, i.dst, i);
                for (0..8 / element) |n| {
                    @memcpy(value[n * 2 * element ..][0..element], dst[n * element ..][0..element]);
                    @memcpy(value[(n * 2 + 1) * element ..][0..element], src[n * element ..][0..element]);
                }
            } else {
                const base: usize = if (i.vector_high) 8 else 0;
                for (0..4) |n| {
                    const index = (i.shuffle >> @as(u3, @intCast(n * 2))) & 3;
                    @memcpy(value[base + n * element ..][0..element], src[base + @as(usize, index) * element ..][0..element]);
                }
            }
            s.vectors[i.dst.vector] = value;
        },
        .vector_mov, .vector_xor, .vector_and, .vector_and_not, .vector_or => {
            const src = try readVector(s, m, i.src, i);
            var value = src;
            if (i.op != .vector_mov) {
                const dst = try readVector(s, m, i.dst, i);
                for (&value, src, dst) |*v, a, b| v.* = switch (i.op) {
                    .vector_xor => a ^ b,
                    .vector_and => a & b,
                    .vector_and_not => (~b) & a,
                    .vector_or => a | b,
                    else => unreachable,
                };
            }
            switch (i.dst) {
                .vector => |r| s.vectors[r] = value,
                .mem => |a| {
                    const addr = address(s, a, i.next);
                    if (i.vector_aligned and addr % 16 != 0) return error.MisalignedMemory;
                    try m.write(addr, &value);
                },
                else => return error.InvalidOperand,
            }
        },
        else => return error.InvalidVectorInstruction,
    }
}

fn readVector(s: *State, m: *Memory, o: ir.Operand, i: ir.Instruction) ![16]u8 {
    return switch (o) {
        .vector => |r| s.vectors[r],
        .mem => |a| blk: {
            const addr = address(s, a, i.next);
            if (i.vector_aligned and addr % 16 != 0) return error.MisalignedMemory;
            var bytes: [16]u8 = undefined;
            try m.read(addr, &bytes, .read);
            break :blk bytes;
        },
        else => error.InvalidOperand,
    };
}
