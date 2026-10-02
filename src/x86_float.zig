//! SSE controls and exception staging around the existing RISC-V rounding engine.
const std = @import("std");
const State = @import("cpu/state.zig").State;
const riscv = @import("cpu/riscv64.zig");
const ir = @import("ir.zig");

pub fn reciprocal(bits: u32) u32 {
    const sign = bits & 0x80000000;
    if (nan(bits, 4)) return bits | 0x00400000;
    if (bits & 0x7f800000 == 0) return sign | 0x7f800000;
    if (bits & 0x7fffffff == 0x7f800000) return sign;
    // ponytail: bounded binary64 approximation, not a native CPU's lookup table.
    // RCP ignores MXCSR, treats denormals as zero and flushes tiny results.
    const value = 1 / asFloat(bits, 4);
    return if (@abs(value) < 0x1p-126) sign else @bitCast(@as(f32, @floatCast(value)));
}

pub const Context = struct {
    control: u32,
    pre: u6 = 0,
    post: u6 = 0,

    pub fn finish(c: Context, s: *State) !void {
        const masks: u6 = @truncate(c.control >> 7);
        const flags = if (c.pre & ~masks != 0) c.pre else c.pre | c.post;
        s.x86_fp.mxcsr |= flags;
        if (flags & ~masks != 0) return error.SimdFloatingPointException;
    }

    fn mode(c: Context) u3 {
        return switch (@as(u2, @truncate(c.control >> 13))) {
            0 => 0, // nearest-even
            1 => 2, // down
            2 => 3, // up
            3 => 1, // toward zero
        };
    }

    fn input(c: *Context, bits: u64, element: u4, denormal_exception: bool) u64 {
        if (!subnormal(bits, element)) return bits;
        if (c.control & 0x40 != 0) return bits & signMask(element);
        if (denormal_exception) c.pre |= 2;
        return bits;
    }

    fn result(c: *Context, bits: u64, element: u4, flags: u5, exact: f128) u64 {
        if (flags & 16 != 0) c.pre |= 1;
        if (flags & 8 != 0) c.pre |= 4;
        var post: u6 = 0;
        if (flags & 4 != 0) post |= 8;
        if (flags & 1 != 0) post |= 32;
        var value = bits & ir.mask(@as(u7, element) * 8);
        // Unmasked underflow also reports exact tiny results. FTZ needs masked underflow.
        const is_tiny = subnormal(value, element) or c.tiny(exact, element);
        if (is_tiny and (c.control & 0x800 == 0 or post & 32 != 0)) post |= 16;
        if (post & 8 != 0 and c.control & 0x400 == 0 or post & 16 != 0 and c.control & 0x800 == 0) {
            // Unmasked O/U use destination precision with an unbounded exponent.
            const normalized = std.math.frexp(exact).significand;
            const rounded_value: f128 = if (element == 4) @floatCast(@as(f32, @floatCast(normalized))) else @floatCast(@as(f64, @floatCast(normalized)));
            post = (post & ~@as(u6, 32)) | (if (rounded_value != normalized) @as(u6, 32) else 0);
        }
        if (c.control & 0x8800 == 0x8800 and is_tiny) {
            value &= signMask(element);
            post |= 48;
        }
        c.post |= post;
        return value;
    }

    pub fn tiny(c: Context, exact: f128, element: u4) bool {
        if (exact == 0 or !std.math.isFinite(exact)) return false;
        const scaled = exact * @as(f128, if (element == 4) 0x1p126 else 0x1p1022);
        if (@abs(scaled) >= 1) return false;
        const nearest: u64 = if (element == 4) @as(u32, @bitCast(@as(f32, @floatCast(scaled)))) else @bitCast(@as(f64, @floatCast(scaled)));
        var scratch = State{ .architecture = .riscv64 };
        // x86 detects tininess at destination precision with an unbounded exponent.
        const scaled_bits = riscv.roundResult(&scratch, @intFromBool(element == 8), nearest, scaled, c.mode(), false, 0);
        return @abs(asFloat(scaled_bits, element)) < 1;
    }

    pub fn arithmetic(c: *Context, op: ir.Op, left: u64, right: u64, element: u4) u64 {
        const unary = op == .vector_float_sqrt;
        const a = c.input(if (unary) right else left, element, false);
        const b = c.input(right, element, false);
        const nan_a = nan(a, element);
        const nan_b = !unary and nan(b, element);
        if (op == .vector_float_min or op == .vector_float_max) {
            if (nan_a or nan_b) {
                c.pre |= 1;
                return b; // MIN/MAX forward source 2, including an unchanged signaling NaN.
            }
            _ = c.input(a, element, true);
            _ = c.input(b, element, true);
            const less = asFloat(a, element) < asFloat(b, element);
            const greater = asFloat(a, element) > asFloat(b, element);
            return if (if (op == .vector_float_min) less else greater) a else b;
        }
        if (signalingNan(a, element) or (!unary and signalingNan(b, element))) c.pre |= 1;
        if (nan_a or nan_b) return (if (nan_a) a else b) | quietMask(element);
        var scratch = State{ .architecture = .riscv64 };
        const operation: u32 = switch (op) {
            .vector_float_add => 0,
            .vector_float_sub => 1,
            .vector_float_mul => 2,
            .vector_float_div => 3,
            .vector_float_sqrt => 11,
            else => unreachable,
        };
        const exact = riscv.floatArithmetic(&scratch, 0, @intFromBool(element == 8), operation, c.mode(), a, b) catch unreachable;
        if (scratch.fp_flags & 24 == 0) {
            _ = c.input(a, element, true);
            if (!unary) _ = c.input(b, element, true);
        }
        const bits = if (scratch.fp_flags & 16 != 0) exponentMask(element) | quietMask(element) | signMask(element) else scratch.fp_registers[0];
        return c.result(bits, element, scratch.fp_flags, exact);
    }

    pub fn rounded(c: *Context, exact: f128, element: u4) u64 {
        const nearest: u64 = if (element == 4) @as(u32, @bitCast(@as(f32, @floatCast(exact)))) else @bitCast(@as(f64, @floatCast(exact)));
        var scratch = State{ .architecture = .riscv64 };
        const bits = riscv.roundResult(&scratch, @intFromBool(element == 8), nearest, exact, c.mode(), false, 0);
        return c.result(bits, element, scratch.fp_flags, exact);
    }

    pub fn intToFloat(c: *Context, integer: i64, element: u4) u64 {
        return c.rounded(@floatFromInt(integer), element);
    }

    pub fn floatToInt(c: *Context, bits: u64, element: u4, width: u7, truncate: bool) u64 {
        const input_bits = c.input(bits, element, false); // Float/integer conversions do not report DE.
        const source = asFloat(input_bits, element);
        const rounded_value = roundIntegral(source, if (truncate) 3 else @truncate(c.control >> 13));
        const limit: f64 = if (width == 32) 0x1p31 else 0x1p63;
        if (!std.math.isFinite(source) or rounded_value < -limit or rounded_value >= limit) {
            c.pre |= 1;
            return @as(u64, 1) << @as(u6, @intCast(width - 1));
        }
        if (rounded_value != source) c.post |= 32;
        return @as(u64, @bitCast(@as(i64, @intFromFloat(rounded_value)))) & ir.mask(width);
    }

    pub fn convert(c: *Context, bits: u64, source_element: u4, destination_element: u4) u64 {
        const input_bits = c.input(bits, source_element, false);
        if (nan(input_bits, source_element)) {
            if (signalingNan(input_bits, source_element)) c.pre |= 1;
            const payload = input_bits & ((quietMask(source_element) << 1) - 1);
            const converted = if (destination_element == 8) payload << 29 else payload >> 29;
            return exponentMask(destination_element) | quietMask(destination_element) | converted |
                (if (input_bits & signMask(source_element) != 0) signMask(destination_element) else 0);
        }
        _ = c.input(input_bits, source_element, true);
        return c.rounded(@floatCast(asFloat(input_bits, source_element)), destination_element);
    }

    pub fn round(c: *Context, bits: u64, element: u4, immediate: u8) u64 {
        const input_bits = c.input(bits, element, false); // ROUND does not report DE.
        if (nan(input_bits, element)) {
            if (signalingNan(input_bits, element)) c.pre |= 1;
            return input_bits | quietMask(element);
        }
        const source = asFloat(input_bits, element);
        const rounding: u2 = if (immediate & 4 != 0) @truncate(c.control >> 13) else @truncate(immediate);
        const rounded_value = roundIntegral(source, rounding);
        if (immediate & 8 == 0 and rounded_value != source) c.post |= 32;
        return if (element == 4) @as(u32, @bitCast(@as(f32, @floatCast(rounded_value)))) else @bitCast(rounded_value);
    }

    pub fn comparison(c: *Context, left: u64, right: u64, element: u4, signaling: bool) Comparison {
        const a = c.input(left, element, false);
        const b = c.input(right, element, false);
        const unordered = nan(a, element) or nan(b, element);
        if (signalingNan(a, element) or signalingNan(b, element) or signaling and unordered) c.pre |= 1;
        if (unordered) return .{ .unordered = true, .less = false, .equal = false };
        _ = c.input(a, element, true);
        _ = c.input(b, element, true);
        return .{ .unordered = false, .less = asFloat(a, element) < asFloat(b, element), .equal = asFloat(a, element) == asFloat(b, element) };
    }
};

pub const Comparison = struct {
    unordered: bool,
    less: bool,
    equal: bool,
    pub fn predicate(c: Comparison, p: u3) bool {
        return switch (p) {
            0 => !c.unordered and c.equal,
            1 => !c.unordered and c.less,
            2 => !c.unordered and (c.less or c.equal),
            3 => c.unordered,
            4 => c.unordered or !c.equal,
            5 => c.unordered or !c.less,
            6 => c.unordered or (!c.less and !c.equal),
            7 => !c.unordered,
        };
    }
};

fn signMask(element: u4) u64 {
    return if (element == 4) 0x80000000 else 0x8000000000000000;
}
fn exponentMask(element: u4) u64 {
    return if (element == 4) 0x7f800000 else 0x7ff0000000000000;
}
fn quietMask(element: u4) u64 {
    return if (element == 4) 0x400000 else 0x8000000000000;
}
fn nan(bits: u64, element: u4) bool {
    return bits & exponentMask(element) == exponentMask(element) and bits & ((quietMask(element) << 1) - 1) != 0;
}
fn signalingNan(bits: u64, element: u4) bool {
    return nan(bits, element) and bits & quietMask(element) == 0;
}
fn subnormal(bits: u64, element: u4) bool {
    return bits & exponentMask(element) == 0 and bits & ((quietMask(element) << 1) - 1) != 0;
}
fn asFloat(bits: u64, element: u4) f64 {
    return if (element == 4) @as(f64, @floatCast(@as(f32, @bitCast(@as(u32, @truncate(bits)))))) else @bitCast(bits);
}
pub fn roundIntegral(source: anytype, mode: u2) @TypeOf(source) {
    if (!std.math.isFinite(source)) return source;
    const toward_zero = @trunc(source);
    const fraction = source - toward_zero;
    const magnitude = @abs(fraction);
    if (magnitude == 0) return source;
    const direction: @TypeOf(source) = if (fraction < 0) -1 else 1;
    return switch (mode) {
        0 => if (magnitude < 0.5 or magnitude == 0.5 and @rem(toward_zero, 2) == 0) toward_zero else toward_zero + direction,
        1 => @floor(source),
        2 => @ceil(source),
        3 => toward_zero,
    };
}

test "SSE reciprocal classes and finite approximations stay inside the ISA bound" {
    for ([_]struct { input: u32, expected: u32 }{
        .{ .input = 0, .expected = 0x7f800000 },
        .{ .input = 0x80000000, .expected = 0xff800000 },
        .{ .input = 1, .expected = 0x7f800000 },
        .{ .input = 0x807fffff, .expected = 0xff800000 },
        .{ .input = 0x7f800000, .expected = 0 },
        .{ .input = 0xff800000, .expected = 0x80000000 },
        .{ .input = 0x7f812345, .expected = 0x7fc12345 },
        .{ .input = 0xff812345, .expected = 0xffc12345 },
        .{ .input = 0x7fc12345, .expected = 0x7fc12345 },
        .{ .input = 0xffc12345, .expected = 0xffc12345 },
        .{ .input = 0x3f800000, .expected = 0x3f800000 },
        .{ .input = 0xc0400000, .expected = 0xbeaaaaab },
        .{ .input = 0x7e7fffff, .expected = 0x00800001 },
        .{ .input = 0x7e800000, .expected = 0x00800000 },
        .{ .input = 0x7e800001, .expected = 0 },
        .{ .input = 0xff7fffff, .expected = 0x80000000 },
    }) |case| try std.testing.expectEqual(case.expected, reciprocal(case.input));
    for (1..255) |exponent| for ([_]u32{ 0, 1, 0x12345, 0x3fffff, 0x7ffffe, 0x7fffff }) |fraction| for ([_]u32{ 0, 0x80000000 }) |sign| {
        const bits = sign | (@as(u32, @intCast(exponent)) << 23) | fraction;
        const result = reciprocal(bits);
        if (bits & 0x7fffffff > 0x7e800000) {
            try std.testing.expectEqual(sign, result);
        } else {
            const product = asFloat(bits, 4) * asFloat(result, 4);
            try std.testing.expect(@abs(product - 1) <= 1.5 * 0x1p-12);
            try std.testing.expectEqual(sign, result & 0x80000000);
        }
    };
}

test "SSE rounding controls cover arithmetic and both conversion directions" {
    for (0..4) |mode_index| {
        const mode_bits: u32 = @intCast(mode_index);
        var c = Context{ .control = 0x1f80 | (mode_bits << 13) };
        const positive = [_]u64{ 0x3f800000, 0x3f800000, 0x3f800001, 0x3f800000 };
        const negative = [_]u64{ 0xbff0000000000000, 0xbff0000000000001, 0xbff0000000000000, 0xbff0000000000000 };
        try std.testing.expectEqual(positive[mode_index], c.arithmetic(.vector_float_add, 0x3f800000, 0x33800000, 4));
        try std.testing.expectEqual(negative[mode_index], c.arithmetic(.vector_float_add, 0xbff0000000000000, 0xbca0000000000000, 8));
        const integers = [_]u64{ 2, 2, 3, 2 };
        try std.testing.expectEqual(integers[mode_index], c.floatToInt(0x40200000, 4, 64, false));
        try std.testing.expectEqual(@as(u64, 2), c.floatToInt(0x40200000, 4, 64, true));
        try std.testing.expectEqual(@as(u64, if (mode_index == 2) 0x4b800001 else 0x4b800000), c.intToFloat(16777217, 4));
        try std.testing.expectEqual(@as(u6, 32), c.post);
    }
}

test "SSE denormals, FTZ and tininess before bounded rounding report the right flags" {
    var c = Context{ .control = 0x1f80 };
    try std.testing.expectEqual(@as(u64, 0x00400000), c.arithmetic(.vector_float_mul, 0x00800000, 0x3f000000, 4));
    try std.testing.expectEqual(@as(u6, 0), c.post);
    c.control |= 0x8000;
    try std.testing.expectEqual(@as(u64, 0), c.arithmetic(.vector_float_mul, 0x00800000, 0x3f000000, 4));
    try std.testing.expectEqual(@as(u6, 48), c.post);
    c = .{ .control = 0x1f80 };
    try std.testing.expectEqual(@as(u64, 0x00800000), c.arithmetic(.vector_float_mul, 0x00800000, 0x3f7fffff, 4));
    try std.testing.expectEqual(@as(u6, 48), c.post);
    c = .{ .control = 0x1f80 };
    try std.testing.expectEqual(@as(u64, 0x3f800000), c.arithmetic(.vector_float_add, 1, 0x3f800000, 4));
    try std.testing.expectEqual(@as(u6, 2), c.pre);
    try std.testing.expectEqual(@as(u6, 32), c.post);
    c = .{ .control = 0x1fc0 };
    try std.testing.expectEqual(@as(u64, 0x3f800000), c.arithmetic(.vector_float_add, 1, 0x3f800000, 4));
    try std.testing.expectEqual(@as(u6, 0), c.pre | c.post);
    c = .{ .control = 0x1f80 };
    try std.testing.expectEqual(@as(u64, 0), c.floatToInt(1, 4, 64, true));
    try std.testing.expectEqual(@as(u6, 0), c.pre);
    try std.testing.expectEqual(@as(u6, 32), c.post);
}

test "SSE NaN priority, compare signaling and precision suppression are distinct" {
    var c = Context{ .control = 0x1f80 };
    try std.testing.expectEqual(@as(u64, 0x7fc12345), c.arithmetic(.vector_float_add, 0x7fc12345, 0xff812345, 4));
    try std.testing.expectEqual(@as(u6, 1), c.pre);
    c.pre = 0;
    try std.testing.expectEqual(@as(u64, 0x3f800000), c.arithmetic(.vector_float_min, 0x7fc12345, 0x3f800000, 4));
    try std.testing.expectEqual(@as(u6, 1), c.pre);
    c.pre = 0;
    try std.testing.expectEqual(@as(u64, 0xff812345), c.arithmetic(.vector_float_max, 0x3f800000, 0xff812345, 4));
    c.pre = 0;
    try std.testing.expect(c.comparison(0x7fc12345, 0, 4, false).unordered);
    try std.testing.expectEqual(@as(u6, 0), c.pre);
    try std.testing.expect(c.comparison(0x7fc12345, 0, 4, true).unordered);
    try std.testing.expectEqual(@as(u6, 1), c.pre);
    c = .{ .control = 0xf80 }; // precision unmasked
    try std.testing.expectEqual(@as(u64, 0x40000000), c.round(0x40200000, 4, 8));
    var state = State{ .architecture = .x86_64 };
    state.x86_fp.mxcsr = c.control;
    try c.finish(&state);
    try std.testing.expectEqual(@as(u32, 0xf80), state.x86_fp.mxcsr);
    _ = c.round(0x40200000, 4, 0);
    try std.testing.expectError(error.SimdFloatingPointException, c.finish(&state));
    try std.testing.expectEqual(@as(u32, 0xfa0), state.x86_fp.mxcsr);
}

test "SSE traps preserve destinations and pre-computation exceptions suppress post flags" {
    const Memory = @import("memory.zig").Memory;
    const decoder = @import("cpu/x86_64.zig").decode;
    const execute = @import("interpreter.zig").execute;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.initialize(0x1000, &.{ 0x0f, 0x58, 0xc1 });
    var state = State{ .architecture = .x86_64, .pc = 0x1000, .flags = .{ .carry = true, .zero = true } };
    state.x86_fp.mxcsr = 0x1f00;
    for ([_]u32{ 0x7f812345, 0x7f7fffff, 1, 0x3f800000 }, 0..) |bits, lane| std.mem.writeInt(u32, state.vectors[0][lane * 4 ..][0..4], bits, .little);
    for ([_]u32{ 0x3f800000, 0x7f7fffff, 0x3f800000, 0x33800000 }, 0..) |bits, lane| std.mem.writeInt(u32, state.vectors[1][lane * 4 ..][0..4], bits, .little);
    var expected = state;
    expected.x86_fp.mxcsr |= 3;
    try std.testing.expectError(error.SimdFloatingPointException, execute(&state, &memory, try decoder(&memory, 0x1000)));
    try std.testing.expect(std.meta.eql(expected, state));
    for ([_]struct { opcode: u8, control: u32, a: u32, b: u32, flags: u32 }{
        .{ .opcode = 0x58, .control = 0x1e80, .a = 1, .b = 0x3f800000, .flags = 2 },
        .{ .opcode = 0x5e, .control = 0x1d80, .a = 1, .b = 0, .flags = 4 },
        .{ .opcode = 0x59, .control = 0x1b80, .a = 0x7f7fffff, .b = 0x40000000, .flags = 8 },
        .{ .opcode = 0x59, .control = 0x1b80, .a = 0x7f7fffff, .b = 0x3f800001, .flags = 40 },
        .{ .opcode = 0x59, .control = 0x1780, .a = 0x00800000, .b = 0x3f000000, .flags = 16 },
        .{ .opcode = 0x59, .control = 0x1780, .a = 0x00800000, .b = 0x3f7fffff, .flags = 16 },
        .{ .opcode = 0x58, .control = 0xf80, .a = 0x3f800000, .b = 0x33800000, .flags = 32 },
    }) |case| {
        try memory.initialize(0x1000, &.{ 0xf3, 0x0f, case.opcode, 0xc1 });
        state = .{ .architecture = .x86_64, .pc = 0x1000, .flags = .{ .carry = true } };
        state.x86_fp.mxcsr = case.control;
        std.mem.writeInt(u32, state.vectors[0][0..4], case.a, .little);
        std.mem.writeInt(u32, state.vectors[1][0..4], case.b, .little);
        expected = state;
        expected.x86_fp.mxcsr |= case.flags;
        try std.testing.expectError(error.SimdFloatingPointException, execute(&state, &memory, try decoder(&memory, 0x1000)));
        try std.testing.expect(std.meta.eql(expected, state));
    }
    try memory.initialize(0x1000, &.{ 0x66, 0x0f, 0x5b, 0x07 });
    state.set(7, 0x1ff8);
    try memory.writeInt(0x1ff8, 64, 0x7fc123457fc12345);
    expected = state;
    try std.testing.expectError(error.UnmappedMemory, execute(&state, &memory, try decoder(&memory, 0x1000)));
    try std.testing.expect(std.meta.eql(expected, state));
    // Loading an already-set, unmasked flag does not itself trigger an exception.
    try memory.initialize(0x1000, &.{ 0x0f, 0xae, 0x17 });
    state.set(7, 0x1200);
    try memory.writeInt(0x1200, 32, 0xff7f);
    _ = try execute(&state, &memory, try decoder(&memory, 0x1000));
    try std.testing.expectEqual(@as(u32, 0xff7f), state.x86_fp.mxcsr);
}
