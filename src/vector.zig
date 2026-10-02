const std = @import("std");
const ir = @import("ir.zig");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
const operands = @import("operands.zig");
const read = operands.read;
const write = operands.write;
const address = operands.address;

pub fn execute(s: *State, m: *Memory, i: ir.Instruction) !void {
    const mmx = s.architecture == .x86_64 and ((i.dst == .vector and i.dst.vector >= 16) or (i.src == .vector and i.src.vector >= 16) or (i.op == .vector_packed_int_to_float and i.vector_bytes == 8));
    if (mmx) try s.x86_fp.checkPending();
    var fp = @import("x86_float.zig").Context{ .control = s.x86_fp.mxcsr };
    const w = i.width;
    switch (i.op) {
        .vector_duplicate => {
            const value = try read(s, m, i.src, w, i.next);
            var lane: [8]u8 = undefined;
            std.mem.writeInt(u64, &lane, value, .little);
            var bytes: [16]u8 = @splat(0);
            const size: usize = w / 8;
            for (0..i.vector_bytes / size) |n| @memcpy(bytes[n * size ..][0..size], lane[0..size]);
            s.setVector(i.dst.vector, bytes);
        },
        .vector_load_pair, .vector_store_pair => {
            const addr = address(s, i.lhs.?.mem, i.next);
            const size: usize = i.vector_bytes;
            var bytes: [32]u8 = @splat(0);
            if (i.op == .vector_load_pair) {
                try m.read(addr, bytes[0 .. size * 2], .read);
                var first: [16]u8 = @splat(0);
                var second: [16]u8 = @splat(0);
                @memcpy(first[0..size], bytes[0..size]);
                @memcpy(second[0..size], bytes[size .. size * 2]);
                s.setVector(i.dst.vector, first);
                s.setVector(i.src.vector, second);
            } else {
                @memcpy(bytes[0..size], s.getVector(i.dst.vector)[0..size]);
                @memcpy(bytes[size .. size * 2], s.getVector(i.src.vector)[0..size]);
                try m.write(addr, bytes[0 .. size * 2]);
            }
        },
        .vector_shl, .vector_shr, .vector_sar => {
            const src = s.getVector(i.dst.vector);
            var value: [16]u8 = @splat(0);
            const element: usize = i.vector_element;
            const bits: u7 = @intCast(element * 8);
            const count: u64 = if (i.src == .imm) i.src.imm else blk: {
                const count_vector = try readVector(s, m, i.src, i);
                break :blk std.mem.readInt(u64, count_vector[0..8], .little);
            };
            for (0..i.vector_bytes / element) |n| {
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
            s.setVector(i.dst.vector, value);
        },
        .vector_byte_shl, .vector_byte_shr => {
            const src = s.getVector(i.dst.vector);
            var value: [16]u8 = @splat(0);
            const count = i.src.imm;
            if (count < 16) {
                for (0..16) |n| {
                    if (i.op == .vector_byte_shr and n + count < 16) value[n] = src[@intCast(n + count)];
                    if (i.op == .vector_byte_shl and n >= count) value[n] = src[@intCast(n - count)];
                }
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_add, .vector_sub, .vector_add_saturate_signed, .vector_add_saturate_unsigned, .vector_sub_saturate_signed, .vector_sub_saturate_unsigned => {
            const src = try readVector(s, m, i.src, i);
            const dst = try readVector(s, m, i.lhs orelse i.dst, i);
            var value: [16]u8 = @splat(0);
            const element: usize = i.vector_element;
            const lane_width: u7 = @intCast(element * 8);
            const lane_mask = ir.mask(lane_width);
            for (0..i.vector_bytes / element) |n| {
                var left_bytes: [8]u8 = @splat(0);
                var right_bytes: [8]u8 = @splat(0);
                @memcpy(left_bytes[0..element], dst[n * element ..][0..element]);
                @memcpy(right_bytes[0..element], src[n * element ..][0..element]);
                const left = std.mem.readInt(u64, &left_bytes, .little);
                const right = std.mem.readInt(u64, &right_bytes, .little);
                const result = switch (i.op) {
                    .vector_add => (left +% right) & lane_mask,
                    .vector_sub => (left -% right) & lane_mask,
                    .vector_add_saturate_unsigned => @min(left + right, lane_mask),
                    .vector_sub_saturate_unsigned => if (left < right) 0 else left - right,
                    .vector_add_saturate_signed, .vector_sub_saturate_signed => blk: {
                        const shift: u6 = @intCast(lane_width - 1);
                        const sign = @as(i64, 1) << shift;
                        const a = ir.signed(left, lane_width);
                        const b = ir.signed(right, lane_width);
                        const raw = if (i.op == .vector_add_saturate_signed) a + b else a - b;
                        const saturated = @max(-sign, @min(sign - 1, raw));
                        break :blk @as(u64, @bitCast(saturated)) & lane_mask;
                    },
                    else => unreachable,
                };
                var result_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &result_bytes, result, .little);
                @memcpy(value[n * element ..][0..element], result_bytes[0..element]);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_mul_low, .vector_mul_high_signed, .vector_mul_high_unsigned, .vector_mul_even_unsigned, .vector_madd_signed => {
            const src = try readVector(s, m, i.src, i);
            const dst = try readVector(s, m, i.lhs orelse i.dst, i);
            var value: [16]u8 = @splat(0);
            switch (i.op) {
                .vector_mul_low => {
                    const element: usize = i.vector_element;
                    const width: u7 = @intCast(element * 8);
                    const lane_mask = ir.mask(width);
                    for (0..i.vector_bytes / element) |n| {
                        var left_bytes: [8]u8 = @splat(0);
                        var right_bytes: [8]u8 = @splat(0);
                        @memcpy(left_bytes[0..element], dst[n * element ..][0..element]);
                        @memcpy(right_bytes[0..element], src[n * element ..][0..element]);
                        const left = std.mem.readInt(u64, &left_bytes, .little);
                        const right = std.mem.readInt(u64, &right_bytes, .little);
                        var result_bytes: [8]u8 = undefined;
                        std.mem.writeInt(u64, &result_bytes, (left *% right) & lane_mask, .little);
                        @memcpy(value[n * element ..][0..element], result_bytes[0..element]);
                    }
                },
                .vector_mul_high_signed, .vector_mul_high_unsigned => for (0..i.vector_bytes / 2) |n| {
                    const a = std.mem.readInt(u16, dst[n * 2 ..][0..2], .little);
                    const b = std.mem.readInt(u16, src[n * 2 ..][0..2], .little);
                    const result: u16 = if (i.op == .vector_mul_high_unsigned) @truncate((@as(u32, a) * @as(u32, b)) >> 16) else blk: {
                        const product: i32 = @intCast(ir.signed(a, 16) * ir.signed(b, 16));
                        break :blk @truncate(@as(u32, @bitCast(product)) >> 16);
                    };
                    std.mem.writeInt(u16, value[n * 2 ..][0..2], result, .little);
                },
                .vector_mul_even_unsigned => for (0..i.vector_bytes / 8) |n| {
                    const a = std.mem.readInt(u32, dst[n * 8 ..][0..4], .little);
                    const b = std.mem.readInt(u32, src[n * 8 ..][0..4], .little);
                    std.mem.writeInt(u64, value[n * 8 ..][0..8], @as(u64, a) * @as(u64, b), .little);
                },
                .vector_madd_signed => for (0..i.vector_bytes / 4) |n| {
                    const offset = n * 4;
                    const a0 = ir.signed(std.mem.readInt(u16, dst[offset..][0..2], .little), 16);
                    const a1 = ir.signed(std.mem.readInt(u16, dst[offset + 2 ..][0..2], .little), 16);
                    const b0 = ir.signed(std.mem.readInt(u16, src[offset..][0..2], .little), 16);
                    const b1 = ir.signed(std.mem.readInt(u16, src[offset + 2 ..][0..2], .little), 16);
                    const sum = a0 * b0 + a1 * b1;
                    const result: u32 = @truncate(@as(u64, @bitCast(sum)));
                    std.mem.writeInt(u32, value[offset..][0..4], result, .little);
                },
                else => unreachable,
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_mul_low_dword => {
            const src = try readVector(s, m, i.src, i);
            const dst = s.getVector(i.dst.vector);
            var value: [16]u8 = @splat(0);
            for (0..4) |lane| {
                const offset = lane * 4;
                const left = std.mem.readInt(u32, dst[offset..][0..4], .little);
                const right = std.mem.readInt(u32, src[offset..][0..4], .little);
                std.mem.writeInt(u32, value[offset..][0..4], @truncate(@as(u64, left) * @as(u64, right)), .little);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_mul_signed_even_dword => {
            const src = try readVector(s, m, i.src, i);
            const dst = s.getVector(i.dst.vector);
            var value: [16]u8 = @splat(0);
            for (0..2) |lane| {
                const offset = lane * 8;
                const a = ir.signed(std.mem.readInt(u32, dst[offset..][0..4], .little), 32);
                const b = ir.signed(std.mem.readInt(u32, src[offset..][0..4], .little), 32);
                std.mem.writeInt(u64, value[offset..][0..8], @bitCast(a * b), .little);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_extend => {
            const source_bytes: usize = i.source_width / 8;
            var source: [16]u8 = @splat(0);
            switch (i.src) {
                .vector => |reg| source = s.getVector(reg),
                .mem => |operand| try m.read(address(s, operand, i.next), source[0..source_bytes], .read),
                else => return error.InvalidOperand,
            }
            const element: usize = i.vector_element;
            const source_element = source_bytes / (16 / element);
            const source_width: u7 = @intCast(source_element * 8);
            var value: [16]u8 = @splat(0);
            for (0..16 / element) |lane| {
                var source_lane: [8]u8 = @splat(0);
                @memcpy(source_lane[0..source_element], source[lane * source_element ..][0..source_element]);
                const raw = std.mem.readInt(u64, &source_lane, .little);
                const extended: u64 = if (i.sign_result) @bitCast(ir.signed(raw, source_width)) else raw;
                var result: [8]u8 = undefined;
                std.mem.writeInt(u64, &result, extended, .little);
                @memcpy(value[lane * element ..][0..element], result[0..element]);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_average_unsigned => {
            const src = try readVector(s, m, i.src, i);
            const dst = try readVector(s, m, i.dst, i);
            var value: [16]u8 = @splat(0);
            const element: usize = i.vector_element;
            for (0..i.vector_bytes / element) |n| {
                const offset = n * element;
                const a = if (element == 1) dst[offset] else std.mem.readInt(u16, dst[offset..][0..2], .little);
                const b = if (element == 1) src[offset] else std.mem.readInt(u16, src[offset..][0..2], .little);
                const average: u16 = @truncate((@as(u32, a) + @as(u32, b) + 1) >> 1);
                var bytes: [2]u8 = undefined;
                std.mem.writeInt(u16, &bytes, average, .little);
                @memcpy(value[offset..][0..element], bytes[0..element]);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_sum_abs_diff => {
            const src = try readVector(s, m, i.src, i);
            const dst = try readVector(s, m, i.dst, i);
            var value: [16]u8 = @splat(0);
            for (0..i.vector_bytes / 8) |group| {
                var sum: u16 = 0;
                for (0..8) |lane| {
                    const offset = group * 8 + lane;
                    const a = dst[offset];
                    const b = src[offset];
                    sum += if (a > b) a - b else b - a;
                }
                std.mem.writeInt(u16, value[group * 8 ..][0..2], sum, .little);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_mpsadbw => {
            const src = try readVector(s, m, i.src, i);
            const dst = s.getVector(i.dst.vector);
            const dst_offset: usize = if (i.shuffle & 4 != 0) 4 else 0;
            const src_offset: usize = @as(usize, i.shuffle & 3) * 4;
            var value: [16]u8 = @splat(0);
            for (0..8) |lane| {
                var sum: u16 = 0;
                for (0..4) |byte| {
                    const a = dst[dst_offset + lane + byte];
                    const b = src[src_offset + byte];
                    sum += if (a > b) a - b else b - a;
                }
                std.mem.writeInt(u16, value[lane * 2 ..][0..2], sum, .little);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_pack_signed_byte, .vector_pack_unsigned_byte, .vector_pack_signed_word, .vector_pack_unsigned_word => {
            const src = try readVector(s, m, i.src, i);
            const dst = try readVector(s, m, i.dst, i);
            var value: [16]u8 = @splat(0);
            if (i.op == .vector_pack_signed_word or i.op == .vector_pack_unsigned_word) {
                for (0..2) |vector| {
                    const input = if (vector == 0) dst else src;
                    for (0..i.vector_bytes / 4) |lane| {
                        const raw = std.mem.readInt(u32, input[lane * 4 ..][0..4], .little);
                        const signed = ir.signed(raw, 32);
                        const saturated = if (i.op == .vector_pack_signed_word) @max(-32768, @min(32767, signed)) else @max(0, @min(65535, signed));
                        const packed_word: u16 = @truncate(@as(u64, @bitCast(saturated)));
                        std.mem.writeInt(u16, value[(vector * (i.vector_bytes / 4) + lane) * 2 ..][0..2], packed_word, .little);
                    }
                }
            } else {
                for (0..2) |vector| {
                    const input = if (vector == 0) dst else src;
                    for (0..i.vector_bytes / 2) |lane| {
                        const raw = std.mem.readInt(u16, input[lane * 2 ..][0..2], .little);
                        const signed = ir.signed(raw, 16);
                        const saturated = if (i.op == .vector_pack_signed_byte) @max(-128, @min(127, signed)) else @max(0, @min(255, signed));
                        value[vector * (i.vector_bytes / 2) + lane] = @truncate(@as(u64, @bitCast(saturated)));
                    }
                }
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_insert_lane => {
            const element: usize = i.vector_element;
            const inserted = if (i.src == .vector) try readElement(s, m, i.src, @intCast(element * 8), if (i.vector_high) element else 0, i.next) else try read(s, m, i.src, @intCast(element * 8), i.next);
            var value = s.getVector(i.dst.vector);
            var bytes: [8]u8 = @splat(0);
            std.mem.writeInt(u64, &bytes, inserted, .little);
            @memcpy(value[@as(usize, i.vector_index) * element ..][0..element], bytes[0..element]);
            s.setVector(i.dst.vector, value);
        },
        .vector_insert_ps => {
            const inserted: u32 = if (i.src == .vector) blk: {
                const source_lane: usize = (i.shuffle >> 6) & 3;
                break :blk std.mem.readInt(u32, s.getVector(i.src.vector)[source_lane * 4 ..][0..4], .little);
            } else @truncate(try read(s, m, i.src, 32, i.next));
            var value = s.getVector(i.dst.vector);
            const destination_lane: usize = (i.shuffle >> 4) & 3;
            std.mem.writeInt(u32, value[destination_lane * 4 ..][0..4], inserted, .little);
            for (0..4) |lane| {
                if (i.shuffle & (@as(u8, 1) << @intCast(lane)) != 0) @memset(value[lane * 4 ..][0..4], 0);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_round => {
            const width: u7 = @as(u7, i.vector_element) * 8;
            var value = s.getVector(i.dst.vector);
            for (0..i.vector_bytes / i.vector_element) |lane| {
                const offset = lane * i.vector_element;
                const bits = try readElement(s, m, i.src, width, offset, i.next);
                const result = fp.round(bits, i.vector_element, i.shuffle);
                if (width == 32) std.mem.writeInt(u32, value[offset..][0..4], @truncate(result), .little) else std.mem.writeInt(u64, value[offset..][0..8], result, .little);
            }
            try fp.finish(s);
            s.setVector(i.dst.vector, value);
        },
        .vector_dot => {
            const src = try readVector(s, m, i.src, i);
            const dst = s.getVector(i.dst.vector);
            const element: usize = i.vector_element;
            var products: [4]u64 = @splat(0);
            for (0..16 / element) |lane| {
                if (i.shuffle & (@as(u8, 1) << @as(u3, @intCast(lane + 4))) != 0) {
                    const a = if (element == 4) std.mem.readInt(u32, dst[lane * element ..][0..4], .little) else std.mem.readInt(u64, dst[lane * element ..][0..8], .little);
                    const b = if (element == 4) std.mem.readInt(u32, src[lane * element ..][0..4], .little) else std.mem.readInt(u64, src[lane * element ..][0..8], .little);
                    products[lane] = fp.arithmetic(.vector_float_mul, a, b, i.vector_element);
                }
            }
            const low = fp.arithmetic(.vector_float_add, products[0], products[1], i.vector_element);
            const dot = if (element == 4) fp.arithmetic(.vector_float_add, low, fp.arithmetic(.vector_float_add, products[2], products[3], 4), 4) else low;
            var value: [16]u8 = @splat(0);
            for (0..16 / element) |lane| {
                if (i.shuffle & (@as(u8, 1) << @as(u3, @intCast(lane))) != 0) {
                    if (element == 4) std.mem.writeInt(u32, value[lane * element ..][0..4], @truncate(dot), .little) else std.mem.writeInt(u64, value[lane * element ..][0..8], dot, .little);
                }
            }
            try fp.finish(s);
            s.setVector(i.dst.vector, value);
        },
        .vector_float_reciprocal, .vector_float_reciprocal_sqrt => {
            const source = try readVector(s, m, i.src, i);
            var value = s.getVector(i.dst.vector);
            for (0..i.vector_bytes / 4) |lane| {
                const offset = lane * 4;
                const bits = std.mem.readInt(u32, source[offset..][0..4], .little);
                std.mem.writeInt(u32, value[offset..][0..4], @import("x86_float.zig").reciprocal(bits, i.op == .vector_float_reciprocal_sqrt), .little);
            }
            // No SIMD exception flags or MXCSR controls apply to RCP/RSQRT.
            s.setVector(i.dst.vector, value);
        },
        .vector_float_add, .vector_float_sub, .vector_float_mul, .vector_float_div, .vector_float_sqrt, .vector_float_min, .vector_float_max, .vector_float_compare => {
            const element: usize = i.vector_element;
            const scalar = i.vector_bytes < 16;
            var source: [16]u8 = @splat(0);
            if (scalar) {
                const bits = try readScalar(s, m, i.src, @intCast(element * 8), i.next);
                if (element == 4) std.mem.writeInt(u32, source[0..4], @truncate(bits), .little) else std.mem.writeInt(u64, source[0..8], bits, .little);
            } else source = try readVector(s, m, i.src, i);
            var value: [16]u8 = if (scalar) s.getVector(i.dst.vector) else @splat(0);
            const destination = s.getVector(i.dst.vector);
            for (0..i.vector_bytes / element) |lane| {
                const offset = lane * element;
                const a = if (element == 4) std.mem.readInt(u32, destination[offset..][0..4], .little) else std.mem.readInt(u64, destination[offset..][0..8], .little);
                const b = if (element == 4) std.mem.readInt(u32, source[offset..][0..4], .little) else std.mem.readInt(u64, source[offset..][0..8], .little);
                const predicate: u3 = @truncate(i.shuffle);
                const result = if (i.op == .vector_float_compare)
                    (if (fp.comparison(a, b, i.vector_element, predicate == 1 or predicate == 2 or predicate == 5 or predicate == 6).predicate(predicate)) ir.mask(@intCast(element * 8)) else 0)
                else
                    fp.arithmetic(i.op, a, b, i.vector_element);
                if (element == 4) std.mem.writeInt(u32, value[offset..][0..4], @truncate(result), .little) else std.mem.writeInt(u64, value[offset..][0..8], result, .little);
            }
            try fp.finish(s);
            s.setVector(i.dst.vector, value);
        },
        .vector_float_horizontal_add, .vector_float_horizontal_sub, .vector_float_add_sub => {
            const src = try readVector(s, m, i.src, i);
            const dst = s.getVector(i.dst.vector);
            const element: usize = i.vector_element;
            const add_sub = i.op == .vector_float_add_sub;
            const halves: usize = if (add_sub) 1 else 2;
            const lanes = if (add_sub) 16 / element else 8 / element;
            var value: [16]u8 = @splat(0);
            for (0..halves) |half| {
                const left = if (add_sub or half == 0) dst else src;
                const right = if (add_sub) src else left;
                for (0..lanes) |pair| {
                    const offset = pair * (if (add_sub) element else 2 * element);
                    const right_offset = offset + (if (add_sub) 0 else element);
                    const result_offset = (half * lanes + pair) * element;
                    const subtract = if (add_sub) pair % 2 == 0 else i.op == .vector_float_horizontal_sub;
                    const a = if (element == 4) std.mem.readInt(u32, left[offset..][0..4], .little) else std.mem.readInt(u64, left[offset..][0..8], .little);
                    const b = if (element == 4) std.mem.readInt(u32, right[right_offset..][0..4], .little) else std.mem.readInt(u64, right[right_offset..][0..8], .little);
                    const result = fp.arithmetic(if (subtract) .vector_float_sub else .vector_float_add, a, b, i.vector_element);
                    if (element == 4) std.mem.writeInt(u32, value[result_offset..][0..4], @truncate(result), .little) else std.mem.writeInt(u64, value[result_offset..][0..8], result, .little);
                }
            }
            try fp.finish(s);
            s.setVector(i.dst.vector, value);
        },
        .vector_float_compare_flags => {
            const width: u7 = @as(u7, i.vector_element) * 8;
            const left = try readScalar(s, m, i.dst, width, i.next);
            const right = try readScalar(s, m, i.src, width, i.next);
            const comparison = fp.comparison(left, right, i.vector_element, i.sign_result);
            try fp.finish(s);
            s.flags.carry = comparison.unordered or comparison.less;
            s.flags.parity = comparison.unordered;
            s.flags.zero = comparison.unordered or comparison.equal;
            s.flags.sign = false;
            s.flags.overflow = false;
            s.flags.auxiliary = false;
        },
        .vector_int_to_float => {
            const integer = ir.signed(try read(s, m, i.src, i.width, i.next), i.width);
            var value = s.getVector(i.dst.vector);
            const result = fp.intToFloat(integer, i.vector_element);
            if (i.vector_element == 4) std.mem.writeInt(u32, value[0..4], @truncate(result), .little) else std.mem.writeInt(u64, value[0..8], result, .little);
            try fp.finish(s);
            s.setVector(i.dst.vector, value);
        },
        .vector_float_to_int, .vector_float_to_int_trunc => {
            const width: u7 = @as(u7, i.vector_element) * 8;
            const bits = try readScalar(s, m, i.src, width, i.next);
            const result = fp.floatToInt(bits, i.vector_element, i.width, i.op == .vector_float_to_int_trunc);
            try fp.finish(s);
            try write(s, m, i.dst, i.width, result, i.next);
        },
        .vector_packed_int_to_float, .vector_packed_int_to_double => {
            const element: u4 = if (i.op == .vector_packed_int_to_float) 4 else 8;
            const lanes = i.vector_bytes / @as(usize, element);
            var source = i;
            source.vector_bytes = @intCast(lanes * 4);
            const src = try readVector(s, m, i.src, source);
            var value: [16]u8 = if (i.vector_bytes == 8) s.getVector(i.dst.vector) else @splat(0);
            for (0..lanes) |lane| {
                const raw = std.mem.readInt(u32, src[lane * 4 ..][0..4], .little);
                const result = fp.intToFloat(@as(i32, @bitCast(raw)), element);
                if (element == 4) std.mem.writeInt(u32, value[lane * 4 ..][0..4], @truncate(result), .little) else std.mem.writeInt(u64, value[lane * 8 ..][0..8], result, .little);
            }
            try fp.finish(s);
            s.setVector(i.dst.vector, value);
        },
        .vector_packed_float_to_int, .vector_packed_float_to_int_trunc, .vector_packed_double_to_int, .vector_packed_double_to_int_trunc => {
            const element: u4 = if (i.op == .vector_packed_double_to_int or i.op == .vector_packed_double_to_int_trunc) 8 else 4;
            const truncate = i.op == .vector_packed_double_to_int_trunc or i.op == .vector_packed_float_to_int_trunc;
            const src = try readVector(s, m, i.src, i);
            var value: [16]u8 = @splat(0);
            for (0..i.vector_bytes / @as(usize, element)) |lane| {
                const bits = if (element == 4) std.mem.readInt(u32, src[lane * 4 ..][0..4], .little) else std.mem.readInt(u64, src[lane * 8 ..][0..8], .little);
                const result = fp.floatToInt(bits, element, 32, truncate);
                std.mem.writeInt(u32, value[lane * 4 ..][0..4], @truncate(result), .little);
            }
            try fp.finish(s);
            s.setVector(i.dst.vector, value);
        },
        .vector_float_to_double, .vector_double_to_float, .vector_float_to_double_scalar, .vector_double_to_float_scalar => {
            const source_element: u4 = if (i.op == .vector_float_to_double or i.op == .vector_float_to_double_scalar) 4 else 8;
            const destination_element: u4 = if (source_element == 4) 8 else 4;
            const scalar = i.op == .vector_float_to_double_scalar or i.op == .vector_double_to_float_scalar;
            var value: [16]u8 = if (scalar) s.getVector(i.dst.vector) else @splat(0);
            for (0..@as(usize, if (scalar) 1 else 2)) |lane| {
                const bits = try readElement(s, m, i.src, @as(u7, source_element) * 8, lane * source_element, i.next);
                const result = fp.convert(bits, source_element, destination_element);
                const offset = lane * destination_element;
                if (destination_element == 4) std.mem.writeInt(u32, value[offset..][0..4], @truncate(result), .little) else std.mem.writeInt(u64, value[offset..][0..8], result, .little);
            }
            try fp.finish(s);
            s.setVector(i.dst.vector, value);
        },
        .vector_duplicate_lanes => {
            const element: usize = i.vector_element;
            const width: u7 = @intCast(element * 8);
            var value: [16]u8 = @splat(0);
            for (0..16 / element) |lane| {
                const source_lane = if (element == 8) 0 else if (i.vector_high) lane | 1 else lane & ~@as(usize, 1);
                const bits = try readElement(s, m, i.src, width, source_lane * element, i.next);
                if (element == 4) std.mem.writeInt(u32, value[lane * element ..][0..4], @truncate(bits), .little) else std.mem.writeInt(u64, value[lane * element ..][0..8], bits, .little);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_move_scalar => {
            const width: u7 = @as(u7, i.vector_element) * 8;
            const bits = try readScalar(s, m, i.src, width, i.next);
            if (i.dst == .vector) {
                var value = s.getVector(i.dst.vector);
                if (i.src != .vector) value = @splat(0);
                if (width == 32) std.mem.writeInt(u32, value[0..4], @truncate(bits), .little) else std.mem.writeInt(u64, value[0..8], bits, .little);
                s.setVector(i.dst.vector, value);
            } else try write(s, m, i.dst, width, bits, i.next);
        },
        .vector_min_unsigned, .vector_max_unsigned, .vector_min_signed, .vector_max_signed => {
            const src = try readVector(s, m, i.src, i);
            const dst = try readVector(s, m, i.dst, i);
            const element: usize = i.vector_element;
            const width: u7 = @intCast(element * 8);
            var value: [16]u8 = @splat(0);
            for (0..16 / element) |lane| {
                const offset = lane * element;
                var left_bytes: [4]u8 = @splat(0);
                var right_bytes: [4]u8 = @splat(0);
                @memcpy(left_bytes[0..element], dst[offset..][0..element]);
                @memcpy(right_bytes[0..element], src[offset..][0..element]);
                const left = std.mem.readInt(u32, &left_bytes, .little);
                const right = std.mem.readInt(u32, &right_bytes, .little);
                const signed = i.op == .vector_min_signed or i.op == .vector_max_signed;
                const less = if (signed) ir.signed(left, width) < ir.signed(right, width) else left < right;
                const result = if ((i.op == .vector_min_signed or i.op == .vector_min_unsigned) == less) left else right;
                var result_bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &result_bytes, result, .little);
                @memcpy(value[offset..][0..element], result_bytes[0..element]);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_minpos_unsigned_word => {
            const src = try readVector(s, m, i.src, i);
            var minimum: u16 = std.math.maxInt(u16);
            var position: u16 = 0;
            for (0..8) |lane| {
                const candidate = std.mem.readInt(u16, src[lane * 2 ..][0..2], .little);
                if (candidate < minimum) {
                    minimum = candidate;
                    position = @intCast(lane);
                }
            }
            var value: [16]u8 = @splat(0);
            std.mem.writeInt(u16, value[0..2], minimum, .little);
            std.mem.writeInt(u16, value[2..4], position, .little);
            s.setVector(i.dst.vector, value);
        },
        .vector_test => {
            const src = try readVector(s, m, i.src, i);
            const dst = s.getVector(i.dst.vector);
            var intersection = false;
            var source_outside_destination = false;
            for (0..16) |byte| {
                intersection = intersection or (src[byte] & dst[byte] != 0);
                source_outside_destination = source_outside_destination or (src[byte] & ~dst[byte] != 0);
            }
            s.flags.zero = !intersection;
            s.flags.carry = !source_outside_destination;
            s.flags.overflow = false;
            s.flags.sign = false;
            s.flags.auxiliary = false;
            s.flags.parity = false;
        },
        .vector_blend => {
            const src = try readVector(s, m, i.src, i);
            var value = s.getVector(i.dst.vector);
            const element: usize = i.vector_element;
            for (0..16 / element) |lane| {
                if (i.shuffle & (@as(u8, 1) << @intCast(lane)) != 0) {
                    @memcpy(value[lane * element ..][0..element], src[lane * element ..][0..element]);
                }
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_blend_variable => {
            const src = try readVector(s, m, i.src, i);
            const dst = s.getVector(i.dst.vector);
            const mask = s.getVector(0);
            var value = dst;
            const element: usize = i.vector_element;
            for (0..16 / element) |lane| {
                if (mask[lane * element + element - 1] & 0x80 != 0) {
                    @memcpy(value[lane * element ..][0..element], src[lane * element ..][0..element]);
                }
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_mask => {
            const bytes = try readVector(s, m, i.src, i);
            var value: u64 = 0;
            const element: usize = i.vector_element;
            for (0..i.vector_bytes / element) |n| value |= @as(u64, bytes[(n + 1) * element - 1] >> 7) << @as(u6, @intCast(n));
            try write(s, m, i.dst, 32, value, i.next);
        },
        .vector_compare_equal, .vector_compare_greater_signed => {
            const src = try readVector(s, m, i.src, i);
            const dst = try readVector(s, m, i.lhs orelse i.dst, i);
            var value: [16]u8 = @splat(0);
            const element: usize = i.vector_element;
            for (0..i.vector_bytes / element) |n| {
                const left = dst[n * element ..][0..element];
                const right = src[n * element ..][0..element];
                const matches = if (i.op == .vector_compare_equal) std.mem.eql(u8, left, right) else blk: {
                    var left_bytes: [8]u8 = @splat(0);
                    var right_bytes: [8]u8 = @splat(0);
                    @memcpy(left_bytes[0..element], left);
                    @memcpy(right_bytes[0..element], right);
                    const width: u7 = @intCast(element * 8);
                    break :blk ir.signed(std.mem.readInt(u64, &left_bytes, .little), width) > ir.signed(std.mem.readInt(u64, &right_bytes, .little), width);
                };
                @memset(value[n * element ..][0..element], if (matches) 255 else 0);
            }
            s.setVector(i.dst.vector, value);
        },
        .scalar_to_vector, .vector_to_scalar, .vector_move_low => {
            const sw = if (i.source_width == 0) w else i.source_width;
            const raw = if (i.src == .vector) blk: {
                var bytes: [8]u8 = @splat(0);
                const size: usize = sw / 8;
                const offset = @as(usize, i.vector_index) * size;
                @memcpy(bytes[0..size], s.getVector(i.src.vector)[offset..][0..size]);
                break :blk std.mem.readInt(u64, &bytes, .little);
            } else try read(s, m, i.src, sw, i.next);
            const value = if (i.sign_result) @as(u64, @bitCast(ir.signed(raw, sw))) else raw;
            if (i.dst == .vector) {
                var bytes: [16]u8 = @splat(0);
                std.mem.writeInt(u64, bytes[0..8], value, .little);
                s.setVector(i.dst.vector, bytes);
            } else try write(s, m, i.dst, w, value, i.next);
        },
        .vector_unpack_low, .vector_unpack_high, .vector_shuffle, .vector_shuffle_pair => {
            const src = try readVector(s, m, i.src, i);
            var value = src;
            const element: usize = i.vector_element;
            if (i.op == .vector_unpack_low or i.op == .vector_unpack_high) {
                const dst = try readVector(s, m, i.dst, i);
                const base: usize = if (i.op == .vector_unpack_high) i.vector_bytes / 2 else 0;
                for (0..i.vector_bytes / 2 / element) |n| {
                    const offset = base + n * element;
                    @memcpy(value[n * 2 * element ..][0..element], dst[offset..][0..element]);
                    @memcpy(value[(n * 2 + 1) * element ..][0..element], src[offset..][0..element]);
                }
            } else if (i.op == .vector_shuffle_pair) {
                const dst = s.getVector(i.dst.vector);
                const lanes = 16 / element;
                const bits: usize = if (element == 8) 1 else 2;
                for (0..lanes) |n| {
                    const index = (i.shuffle >> @as(u3, @intCast(n * bits))) & @as(u8, @intCast(lanes - 1));
                    const data = if (n < lanes / 2) dst else src;
                    @memcpy(value[n * element ..][0..element], data[@as(usize, index) * element ..][0..element]);
                }
            } else {
                const base: usize = if (i.vector_high) 8 else 0;
                for (0..4) |n| {
                    const index = (i.shuffle >> @as(u3, @intCast(n * 2))) & 3;
                    @memcpy(value[base + n * element ..][0..element], src[base + @as(usize, index) * element ..][0..element]);
                }
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_shuffle_bytes => {
            const control = try readVector(s, m, i.src, i);
            const data = s.getVector(i.dst.vector);
            var value: [16]u8 = @splat(0);
            for (0..16) |n| value[n] = if (control[n] & 0x80 != 0) 0 else data[control[n] & 0x0f];
            s.setVector(i.dst.vector, value);
        },
        .vector_align_right => {
            const src = try readVector(s, m, i.src, i);
            const dst = s.getVector(i.dst.vector);
            var value: [16]u8 = @splat(0);
            if (i.shuffle < 32) {
                for (0..16) |lane| {
                    const index = @as(usize, i.shuffle) + lane;
                    if (index < 16) value[lane] = src[index] else if (index < 32) value[lane] = dst[index - 16];
                }
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_sign => {
            const control = try readVector(s, m, i.src, i);
            const data = s.getVector(i.dst.vector);
            const element: usize = i.vector_element;
            const sign_bit = @as(u32, 1) << @as(u5, @intCast(element * 8 - 1));
            const lane_mask: u32 = @intCast(ir.mask(@intCast(element * 8)));
            var value: [16]u8 = @splat(0);
            for (0..16 / element) |lane| {
                const offset = lane * element;
                var source_bytes: [4]u8 = @splat(0);
                var control_bytes: [4]u8 = @splat(0);
                @memcpy(source_bytes[0..element], data[offset..][0..element]);
                @memcpy(control_bytes[0..element], control[offset..][0..element]);
                const source_value = std.mem.readInt(u32, &source_bytes, .little);
                const control_value = std.mem.readInt(u32, &control_bytes, .little);
                const result = if (control_value == 0) 0 else if (control_value & sign_bit != 0) (0 -% source_value) & lane_mask else source_value;
                var result_bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &result_bytes, result, .little);
                @memcpy(value[offset..][0..element], result_bytes[0..element]);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_abs => {
            const src = try readVector(s, m, i.src, i);
            const element: usize = i.vector_element;
            const sign_bit = @as(u32, 1) << @as(u5, @intCast(element * 8 - 1));
            const lane_mask: u32 = @intCast(ir.mask(@intCast(element * 8)));
            var value: [16]u8 = @splat(0);
            for (0..16 / element) |lane| {
                const offset = lane * element;
                var source_bytes: [4]u8 = @splat(0);
                @memcpy(source_bytes[0..element], src[offset..][0..element]);
                const source_value = std.mem.readInt(u32, &source_bytes, .little);
                const result = if (source_value & sign_bit != 0) (0 -% source_value) & lane_mask else source_value;
                var result_bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &result_bytes, result, .little);
                @memcpy(value[offset..][0..element], result_bytes[0..element]);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_mul_high_round => {
            const src = try readVector(s, m, i.src, i);
            const dst = s.getVector(i.dst.vector);
            var value: [16]u8 = @splat(0);
            for (0..8) |lane| {
                const offset = lane * 2;
                const left = ir.signed(std.mem.readInt(u16, dst[offset..][0..2], .little), 16);
                const right = ir.signed(std.mem.readInt(u16, src[offset..][0..2], .little), 16);
                const rounded = (left * right + 0x4000) >> 15;
                std.mem.writeInt(u16, value[offset..][0..2], @truncate(@as(u64, @bitCast(rounded))), .little);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_horizontal_add, .vector_horizontal_add_saturate_signed, .vector_horizontal_sub, .vector_horizontal_sub_saturate_signed => {
            const src = try readVector(s, m, i.src, i);
            const dst = s.getVector(i.dst.vector);
            const element: usize = i.vector_element;
            const width: u7 = @intCast(element * 8);
            const lane_mask = ir.mask(width);
            const pair_count = 8 / element;
            const saturating = i.op == .vector_horizontal_add_saturate_signed or i.op == .vector_horizontal_sub_saturate_signed;
            const subtract = i.op == .vector_horizontal_sub or i.op == .vector_horizontal_sub_saturate_signed;
            var value: [16]u8 = @splat(0);
            for (0..2) |half| {
                const input = if (half == 0) dst else src;
                for (0..pair_count) |pair| {
                    const offset = pair * 2 * element;
                    var left_bytes: [4]u8 = @splat(0);
                    var right_bytes: [4]u8 = @splat(0);
                    @memcpy(left_bytes[0..element], input[offset..][0..element]);
                    @memcpy(right_bytes[0..element], input[offset + element ..][0..element]);
                    const left = std.mem.readInt(u32, &left_bytes, .little);
                    const right = std.mem.readInt(u32, &right_bytes, .little);
                    const result: u64 = if (saturating) blk: {
                        const a = ir.signed(left, width);
                        const b = ir.signed(right, width);
                        const raw = if (subtract) a - b else a + b;
                        break :blk @as(u64, @bitCast(@max(-32768, @min(32767, raw)))) & lane_mask;
                    } else if (subtract) (@as(u64, left) -% @as(u64, right)) & lane_mask else (@as(u64, left) + @as(u64, right)) & lane_mask;
                    const result_offset = (half * pair_count + pair) * element;
                    var result_bytes: [4]u8 = undefined;
                    std.mem.writeInt(u32, &result_bytes, @truncate(result), .little);
                    @memcpy(value[result_offset..][0..element], result_bytes[0..element]);
                }
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_madd_unsigned_signed_sat => {
            const src = try readVector(s, m, i.src, i);
            const dst = s.getVector(i.dst.vector);
            var value: [16]u8 = @splat(0);
            for (0..8) |lane| {
                const offset = lane * 2;
                const sum = @as(i64, dst[offset]) * ir.signed(src[offset], 8) + @as(i64, dst[offset + 1]) * ir.signed(src[offset + 1], 8);
                const saturated = @max(-32768, @min(32767, sum));
                std.mem.writeInt(u16, value[offset..][0..2], @truncate(@as(u64, @bitCast(saturated))), .little);
            }
            s.setVector(i.dst.vector, value);
        },
        .vector_mask_store => {
            const data = s.getVector(i.src.vector);
            const mask = s.getVector(i.lhs.?.vector);
            const base = address(s, i.dst.mem, i.next);
            // Reserve every selected output before writing any byte; masked bytes
            // need no read permission. Our all-zero mask profile does not fault.
            for (mask[0..i.vector_bytes], 0..) |byte, n| if (byte & 0x80 != 0) {
                try m.prepareWrite(try std.math.add(u64, base, n), 1);
            };
            for (mask[0..i.vector_bytes], 0..) |byte, n| if (byte & 0x80 != 0) {
                try m.write(base + n, data[n..][0..1]);
            };
        },
        .vector_mov, .vector_xor, .vector_and, .vector_and_not, .vector_or => {
            const src = try readVector(s, m, i.src, i);
            var value = src;
            if (i.op != .vector_mov) {
                const dst = try readVector(s, m, i.lhs orelse i.dst, i);
                for (&value, src, dst) |*v, a, b| v.* = switch (i.op) {
                    .vector_xor => a ^ b,
                    .vector_and => a & b,
                    .vector_and_not => (~b) & a,
                    .vector_or => a | b,
                    else => unreachable,
                };
            }
            switch (i.dst) {
                .vector => |r| {
                    @memset(value[i.vector_bytes..], 0);
                    s.setVector(r, value);
                },
                .mem => |a| {
                    const addr = address(s, a, i.next);
                    if (i.vector_aligned and addr % 16 != 0) return error.MisalignedMemory;
                    try m.write(addr, value[0..i.vector_bytes]);
                },
                else => return error.InvalidOperand,
            }
        },
        else => return error.InvalidVectorInstruction,
    }
    if (mmx) s.x86_fp.enterMmx();
}

fn readScalar(s: *State, m: *Memory, o: ir.Operand, width: u7, next: u64) !u64 {
    return readElement(s, m, o, width, 0, next);
}

fn readElement(s: *State, m: *Memory, o: ir.Operand, width: u7, offset: usize, next: u64) !u64 {
    return switch (o) {
        .vector => |r| if (width == 32) std.mem.readInt(u32, s.getVector(r)[offset..][0..4], .little) else std.mem.readInt(u64, s.getVector(r)[offset..][0..8], .little),
        .mem => |a| try m.readInt(address(s, a, next) +% @as(u64, @intCast(offset)), width, .read),
        else => error.InvalidOperand,
    };
}

fn readVector(s: *State, m: *Memory, o: ir.Operand, i: ir.Instruction) ![16]u8 {
    return switch (o) {
        .vector => |r| s.getVector(r),
        .imm => |value| blk: {
            var bytes: [16]u8 = @splat(0);
            std.mem.writeInt(u64, bytes[0..8], value, .little);
            if (i.vector_bytes == 16) std.mem.writeInt(u64, bytes[8..16], value, .little);
            break :blk bytes;
        },
        .mem => |a| blk: {
            const addr = address(s, a, i.next);
            if (i.vector_aligned and addr % 16 != 0) return error.MisalignedMemory;
            var bytes: [16]u8 = @splat(0);
            try m.read(addr, bytes[0..i.vector_bytes], .read);
            break :blk bytes;
        },
        else => error.InvalidOperand,
    };
}
