//! x87 stack, basic arithmetic, comparisons, transfers and controls.
const std = @import("std");
const ir = @import("ir.zig");
const State = @import("cpu/state.zig").State;
const Fp = @import("cpu/state.zig").X86Fp;
const Memory = @import("memory.zig").Memory;
const operands = @import("operands.zig");
const simd = @import("x86_float.zig");
const sign: u80 = @as(u80, 1) << 79;
const integer: u64 = @as(u64, 1) << 63;
const quiet: u64 = @as(u64, 1) << 62;
const indefinite: u80 = (@as(u80, 0xffff) << 64) | integer | quiet;

pub fn supported(code: u16) bool {
    if (code == 0x9b) return true;
    const op = code >> 8;
    const byte: u8 = @truncate(code);
    const group: u3 = @truncate(byte >> 3);
    if (byte >= 0xc0 and (op == 0xd8 or (op == 0xdc or op == 0xde) and (group <= 1 or group >= 4))) return true;
    if (byte < 0xc0 and (op == 0xd8 or op == 0xda or op == 0xdc or op == 0xde)) return true;
    if (byte >= 0xc0) return switch (code) {
        0xd9c0...0xd9cf,
        0xd9d0,
        0xd9e0,
        0xd9e1,
        0xd9e4,
        0xd9e5,
        0xd9e8...0xd9ee,
        0xd9f4,
        0xd9f5,
        0xd9f6,
        0xd9f7,
        0xd9f8,
        0xd9fa,
        0xd9fc,
        0xddc0...0xddc7,
        0xdac0...0xdadf,
        0xdbc0...0xdbdf,
        0xddd0...0xdddf,
        0xdde0...0xddef,
        0xdbe8...0xdbf7,
        0xdfe8...0xdff7,
        0xdae9,
        0xded9,
        0xdbe2,
        0xdbe3,
        0xdfe0,
        => true,
        else => false,
    };
    return switch (op) {
        0xd9 => group == 0 or group == 2 or group == 3 or group == 5 or group == 7,
        0xdd => group <= 3 or group == 7,
        0xdb, 0xdf => group <= 3 or group == 5 or group == 7,
        else => false,
    };
}

fn top(fp: Fp) u3 {
    return @truncate(fp.status >> 11);
}
fn setTop(fp: *Fp, value: u3) void {
    fp.status = (fp.status & ~@as(u16, 0x3800)) | (@as(u16, value) << 11);
}
fn physical(fp: Fp, logical: u3) u3 {
    return top(fp) +% logical;
}
fn get(fp: Fp, index: u3) u80 {
    return std.mem.readInt(u80, &fp.registers[index], .little);
}
fn put(fp: *Fp, index: u3, value: u80) void {
    std.mem.writeInt(u80, &fp.registers[index], value, .little);
    fp.tag |= @as(u8, 1) << index;
}
fn pop(fp: *Fp) void {
    fp.tag &= ~(@as(u8, 1) << top(fp.*));
    setTop(fp, top(fp.*) +% 1);
}
fn constant(byte: u8, control: u16) u80 {
    if (byte == 0xe8) return (@as(u80, 0x3fff) << 64) | integer;
    if (byte == 0xee) return 0;
    // Lower 64-bit significands of log2(10), log2(e), pi, log10(2), ln(2).
    const lower = [_]u80{ 0x4000d49a784bcd1b8afe, 0x3fffb8aa3b295c17f0bb, 0x4000c90fdaa22168c234, 0x3ffd9a209a84fbcff798, 0x3ffeb17217f7d1cf79ab };
    const mode: u2 = @truncate(control >> 10);
    // Constant loads ignore PC, never accrue precision, and clear C1 via push.
    return lower[byte - 0xe9] + @intFromBool(mode == 2 or mode == 0 and byte != 0xe9);
}
fn pending(fp: *Fp) void {
    fp.status = (fp.status & ~@as(u16, 0x8080)) | (if (fp.status & ~fp.control & 0x3f != 0) @as(u16, 0x8080) else 0);
}
fn raise(fp: *Fp, flags: u16) bool {
    fp.status |= flags;
    pending(fp);
    return flags & ~fp.control & 0x3f != 0;
}
fn stack(fp: Fp, logical: u3, flags: *u16) u80 {
    const index = physical(fp, logical);
    if (fp.tag & (@as(u8, 1) << index) == 0) {
        flags.* |= 0x41;
        return indefinite;
    }
    return get(fp, index);
}
fn push(fp: *Fp, raw: u80, flags: u16) void {
    fp.status &= ~@as(u16, 0x200);
    const index = top(fp.*) -% 1;
    if (fp.tag & (@as(u8, 1) << index) != 0) {
        fp.status |= 0x200;
        if (raise(fp, 0x41)) return;
        setTop(fp, index);
        put(fp, index, indefinite);
        return;
    }
    const unmasked = raise(fp, flags);
    if (unmasked and flags & 1 != 0) return;
    // FLD of a denormal m32/m64 still pushes when DE is unmasked.
    setTop(fp, index);
    put(fp, index, raw);
}
fn exponent(raw: u80) u15 {
    return @truncate(raw >> 64);
}
fn unsupported(raw: u80) bool {
    return exponent(raw) != 0 and raw & integer == 0;
}
fn nan(raw: u80) bool {
    return exponent(raw) == 0x7fff and raw & (integer - 1) != 0;
}
fn floating(raw: u80) f128 {
    const significand: f128 = @floatFromInt(@as(u64, @truncate(raw)));
    const value = std.math.ldexp(significand, @as(i32, @max(exponent(raw), 1)) - 16383 - 63);
    if (exponent(raw) == 0x7fff) return if (raw & sign != 0) -std.math.inf(f128) else std.math.inf(f128);
    return if (raw & sign != 0) -value else value;
}
fn extended(value: f128) u80 {
    if (value == 0) return if (std.math.signbit(value)) sign else 0;
    const normalized = std.math.frexp(@abs(value));
    const significand: u64 = @intFromFloat(normalized.significand * 0x1p64);
    return (@as(u80, @intCast(normalized.exponent + 16382)) << 64) | significand | (if (value < 0) sign else 0);
}
fn loadFloat(bits: u64, width: u7, flags: *u16, quiet_nan: bool) u80 {
    const fraction_bits: u6 = if (width == 32) 23 else 52;
    const bias: u16 = if (width == 32) 127 else 1023;
    const exp = (bits >> fraction_bits) & (bias * 2 + 1);
    const fraction = bits & ((@as(u64, 1) << fraction_bits) - 1);
    const negative = bits & (@as(u64, 1) << @as(u6, @intCast(width - 1))) != 0;
    if (exp == bias * 2 + 1) {
        var significand = integer | (fraction << @as(u6, 63 - fraction_bits));
        if (quiet_nan and fraction != 0 and significand & quiet == 0) {
            flags.* |= 1;
            significand |= quiet;
        }
        return (@as(u80, 0x7fff) << 64) | significand | (if (negative) sign else 0);
    }
    if (exp == 0 and fraction != 0) flags.* |= 2;
    const value: f128 = if (width == 32) @floatCast(@as(f32, @bitCast(@as(u32, @truncate(bits))))) else @floatCast(@as(f64, @bitCast(bits)));
    return extended(value);
}
fn examine(fp: *Fp) void {
    const raw = get(fp.*, top(fp.*));
    const exp = exponent(raw);
    const sig: u64 = @truncate(raw);
    const category: u16 = if (fp.tag & (@as(u8, 1) << top(fp.*)) == 0) 0x4100 else if (unsupported(raw)) 0 else if (nan(raw)) 0x100 else if (exp == 0x7fff) 0x500 else if (exp == 0) (if (sig == 0) @as(u16, 0x4000) else 0x4400) else 0x400;
    fp.status = (fp.status & ~@as(u16, 0x4700)) | category | (if (raw & sign != 0) @as(u16, 0x200) else 0);
}

fn storeFloat(fp: *Fp, raw: u80, width: u7, flags: *u16) u64 {
    const fraction_bits: u6 = if (width == 32) 23 else 52;
    const bias: u16 = if (width == 32) 127 else 1023;
    const exp_mask = @as(u64, bias * 2 + 1) << fraction_bits;
    const sign_mask = @as(u64, 1) << @as(u6, @intCast(width - 1));
    if (unsupported(raw)) {
        flags.* |= 1;
        return sign_mask | exp_mask | (@as(u64, 1) << (fraction_bits - 1));
    }
    if (exponent(raw) == 0x7fff) {
        if (nan(raw) and raw & quiet == 0) flags.* |= 1;
        return (if (raw & sign != 0) sign_mask else 0) | exp_mask |
            ((@as(u64, @truncate(raw)) & (integer - 1)) >> @as(u6, 63 - fraction_bits)) |
            (if (nan(raw)) @as(u64, 1) << (fraction_bits - 1) else 0);
    }
    const exact = floating(raw);
    var context = simd.Context{ .control = 0x1f80 | (@as(u32, fp.control & 0xc00) << 3) };
    const element: u4 = if (width == 32) 4 else 8;
    const bits = context.rounded(exact, element);
    var post: u16 = context.post;
    if (fp.control & 16 == 0 and context.tiny(exact, element)) post |= 16;
    if (post & ~fp.control & 24 != 0) {
        // An unmasked memory-store O/U does not report precision or write a result.
        post &= ~@as(u16, 32);
    } else if (post & 32 != 0) {
        const rounded_value: f128 = if (width == 32) @floatCast(@as(f32, @bitCast(@as(u32, @truncate(bits))))) else @floatCast(@as(f64, @bitCast(bits)));
        if (@abs(rounded_value) > @abs(exact)) fp.status |= 0x200;
    }
    flags.* |= post;
    return bits;
}
fn storeInteger(fp: *Fp, raw: u80, width: u7, truncate: bool, flags: *u16) u64 {
    const invalid_result = @as(u64, 1) << @as(u6, @intCast(width - 1));
    if (unsupported(raw) or exponent(raw) == 0x7fff) {
        flags.* |= 1;
        return invalid_result;
    }
    const exact = floating(raw);
    const rounded = simd.roundIntegral(exact, if (truncate) 3 else @as(u2, @truncate(fp.control >> 10)));
    const limit = std.math.ldexp(@as(f128, 1), @intCast(width - 1));
    if (rounded < -limit or rounded >= limit) {
        flags.* |= 1;
        return invalid_result;
    }
    if (rounded != exact) {
        flags.* |= 32;
        if (@abs(rounded) > @abs(exact)) fp.status |= 0x200;
    }
    return @as(u64, @bitCast(@as(i64, @intFromFloat(rounded)))) & ir.mask(width);
}

const Binary = enum { add, mul, sub, div };
const Finite = struct { significand: u256, scale: i32 };
fn finite(raw: u80) Finite {
    const sig: u64 = @truncate(raw);
    if (sig == 0) return .{ .significand = 0, .scale = 0 };
    const shift = @clz(sig);
    return .{ .significand = @as(u256, sig) << @intCast(shift), .scale = @as(i32, @max(exponent(raw), 1)) - 16446 - @as(i32, shift) };
}
fn jam(value: u256, distance: i32) u256 {
    if (distance >= 256) return @intFromBool(value != 0);
    if (distance == 0) return value;
    const shift: u8 = @intCast(distance);
    return (value >> shift) | @intFromBool(value & ((@as(u256, 1) << shift) - 1) != 0);
}
const Quantized = struct { value: u256, inexact: bool = false, up: bool = false };
fn quantize(magnitude: u256, distance: i32, mode: u2, negative: bool) Quantized {
    if (distance <= 0) return .{ .value = magnitude << @intCast(-distance) };
    var result: Quantized = if (distance >= 256) .{ .value = 0, .inexact = magnitude != 0 } else blk: {
        const shift: u8 = @intCast(distance);
        const remainder = magnitude & ((@as(u256, 1) << shift) - 1);
        const half = @as(u256, 1) << @as(u8, shift - 1);
        const truncated = magnitude >> shift;
        break :blk .{ .value = truncated, .inexact = remainder != 0, .up = mode == 0 and (remainder > half or remainder == half and truncated & 1 != 0) };
    };
    if (mode != 0) result.up = result.inexact and (mode == 1 and negative or mode == 2 and !negative);
    if (result.up) result.value += 1;
    return result;
}
fn roundArithmetic(fp: *Fp, magnitude: u256, scale: i32, negative: bool) u80 {
    const signed: u80 = if (negative) sign else 0;
    if (magnitude == 0) return signed;
    const precision: i32 = switch (@as(u2, @truncate(fp.control >> 8))) {
        0 => 24,
        2 => 53,
        else => 64,
    };
    const mode: u2 = @truncate(fp.control >> 10);
    var e = scale + 255 - @as(i32, @intCast(@clz(magnitude)));
    var q = quantize(magnitude, e - precision + 1 - scale, mode, negative);
    if (q.value >= @as(u256, 1) << @intCast(precision)) {
        q.value >>= 1;
        e += 1;
    }
    var flags: u16 = if (q.inexact) 32 else 0;
    if (e > 16383) {
        flags |= 8;
        if (fp.control & 8 != 0) {
            const infinity = mode == 0 or mode == 1 and negative or mode == 2 and !negative;
            _ = raise(fp, flags | 32);
            if (infinity) fp.status |= 0x200;
            return signed | (if (infinity) (@as(u80, 0x7fff) << 64) | integer else (@as(u80, 0x7ffe) << 64) | ((@as(u80, 1) << @intCast(precision)) - 1) << @intCast(64 - precision));
        }
        e -= 24576;
    } else if (e < -16382) {
        if (fp.control & 16 == 0) {
            flags |= 16;
            e += 24576;
        } else {
            q = quantize(magnitude, -16382 - precision + 1 - scale, mode, negative);
            flags = if (q.inexact) 48 else 0;
            _ = raise(fp, flags);
            if (q.up) fp.status |= 0x200;
            const sig: u64 = @intCast(q.value << @intCast(64 - precision));
            return signed | (if (sig & integer != 0) @as(u80, 1) << 64 else 0) | sig;
        }
    }
    _ = raise(fp, flags);
    if (q.up) fp.status |= 0x200;
    return signed | (@as(u80, @intCast(e + 16383)) << 64) | @as(u80, @intCast(q.value << @intCast(64 - precision)));
}
fn signaling(raw: u80) bool {
    return nan(raw) and raw & quiet == 0;
}
fn denormal(raw: u80) bool {
    return exponent(raw) == 0 and @as(u64, @truncate(raw)) != 0;
}
fn extract(fp: *Fp) void {
    fp.status &= ~@as(u16, 0x200);
    const destination = top(fp.*) -% 1;
    if (fp.tag & (@as(u8, 1) << destination) != 0) {
        fp.status |= 0x200;
        if (raise(fp, 0x41)) return;
        put(fp, top(fp.*), indefinite);
        setTop(fp, destination);
        put(fp, destination, indefinite);
        return;
    }
    var flags: u16 = 0;
    const raw = stack(fp.*, 0, &flags);
    var significand = raw;
    var power: u80 = undefined;
    if (flags & 64 != 0 or unsupported(raw)) {
        flags |= 1;
        significand = indefinite;
        power = indefinite;
    } else if (nan(raw)) {
        if (signaling(raw)) flags |= 1;
        significand |= quiet;
        power = significand;
    } else if (exponent(raw) == 0x7fff) {
        power = (@as(u80, 0x7fff) << 64) | integer;
    } else if (@as(u64, @truncate(raw)) == 0) {
        flags |= 4;
        power = sign | (@as(u80, 0x7fff) << 64) | integer;
    } else {
        if (denormal(raw)) flags |= 2;
        const normalized = finite(raw);
        significand = (raw & sign) | (@as(u80, 0x3fff) << 64) | @as(u80, @intCast(normalized.significand));
        power = extended(@floatFromInt(normalized.scale + 63));
    }
    if (raise(fp, flags)) return;
    put(fp, top(fp.*), power);
    push(fp, significand, 0);
}
fn unary(fp: *Fp, raw: u80, root: bool, initial_flags: u16) ?u80 {
    if (initial_flags & 64 != 0 or unsupported(raw) or nan(raw)) return arithmetic(fp, raw, 0, .add, initial_flags);
    if (root and raw & sign != 0 and @as(u64, @truncate(raw)) != 0) return if (raise(fp, 1)) null else indefinite;
    if (raise(fp, initial_flags | (if (denormal(raw)) @as(u16, 2) else 0))) return null;
    if (exponent(raw) == 0x7fff or @as(u64, @truncate(raw)) == 0) return raw;
    if (!root) {
        const exact = floating(raw);
        const integral = simd.roundIntegral(exact, @as(u2, @truncate(fp.control >> 10)));
        _ = raise(fp, if (integral != exact) 32 else 0);
        if (@abs(integral) > @abs(exact)) fp.status |= 0x200;
        return extended(integral);
    }
    var input = finite(raw);
    if (@mod(input.scale, 2) != 0) {
        input.significand <<= 1;
        input.scale -= 1;
    }
    const radicand = input.significand << 128;
    const lower: u256 = std.math.sqrt(radicand);
    return roundArithmetic(fp, lower | @intFromBool(lower * lower != radicand), @divExact(input.scale, 2) - 64, false);
}
fn arithmetic(fp: *Fp, a: u80, b: u80, operation: Binary, initial_flags: u16) ?u80 {
    var flags = initial_flags;
    if (flags & 0x40 != 0 or unsupported(a) or unsupported(b)) {
        return if (raise(fp, (flags & ~@as(u16, 2)) | 1)) null else indefinite;
    }
    if (nan(a) or nan(b)) {
        if (signaling(a) or signaling(b)) flags |= 1;
        if (raise(fp, flags & ~@as(u16, 2))) return null;
        const selected = if (!nan(a)) b else if (!nan(b)) a else if (signaling(a) != signaling(b))
            (if (signaling(a)) b else a)
        else if (@as(u64, @truncate(a)) != @as(u64, @truncate(b)))
            (if (@as(u64, @truncate(a)) > @as(u64, @truncate(b))) a else b)
        else
            @min(a, b);
        return selected | quiet;
    }
    const ai = exponent(a) == 0x7fff;
    const bi = exponent(b) == 0x7fff;
    const az = @as(u64, @truncate(a)) == 0;
    const bz = @as(u64, @truncate(b)) == 0;
    const an = a & sign != 0;
    const bn = (b & sign != 0) != (operation == .sub);
    const negative = an != (b & sign != 0);
    if ((operation == .add or operation == .sub) and ai and bi and an != bn or
        operation == .mul and (ai and bz or bi and az) or operation == .div and (ai and bi or az and bz))
    {
        return if (raise(fp, (flags & ~@as(u16, 2)) | 1)) null else indefinite;
    }
    if (operation == .div and !ai and !az and bz) {
        return if (raise(fp, (flags & ~@as(u16, 2)) | 4)) null else (if (negative) sign else 0) | (@as(u80, 0x7fff) << 64) | integer;
    }
    if (denormal(a) or denormal(b)) flags |= 2;
    if (raise(fp, flags)) return null;
    if (ai or bi) return switch (operation) {
        .add, .sub => (if (if (ai) an else bn) sign else 0) | (@as(u80, 0x7fff) << 64) | integer,
        .mul => (if (negative) sign else 0) | (@as(u80, 0x7fff) << 64) | integer,
        .div => (if (negative) sign else 0) | (if (ai) (@as(u80, 0x7fff) << 64) | integer else 0),
    };
    const x = finite(a);
    const y = finite(b);
    if (operation == .mul) return roundArithmetic(fp, x.significand * y.significand, x.scale + y.scale, negative);
    if (operation == .div) {
        if (az) return if (negative) sign else 0;
        const numerator = x.significand << 128;
        return roundArithmetic(fp, (numerator / y.significand) | @intFromBool(numerator % y.significand != 0), x.scale - y.scale - 128, negative);
    }
    if (az and bz) return if (an == bn and an or an != bn and fp.control & 0xc00 == 0x400) sign else 0;
    if (az) return roundArithmetic(fp, y.significand, y.scale, bn);
    if (bz) return roundArithmetic(fp, x.significand, x.scale, an);
    // 128 guard bits retain exact cancellation; larger exponent gaps only need a sticky bit.
    const scale = @max(x.scale, y.scale);
    const left = jam(x.significand << 128, scale - x.scale);
    const right = jam(y.significand << 128, scale - y.scale);
    if (an == bn) return roundArithmetic(fp, left + right, scale - 128, an);
    if (left == right) return if (fp.control & 0xc00 == 0x400) sign else 0;
    return roundArithmetic(fp, if (left > right) left - right else right - left, scale - 128, if (left > right) an else bn);
}
fn partialRemainder(fp: *Fp, nearest: bool) void {
    var flags: u16 = 0;
    const a = stack(fp.*, 0, &flags);
    const b = stack(fp.*, 1, &flags);
    fp.status &= ~@as(u16, 0x200);
    if (flags & 64 != 0 or unsupported(a) or unsupported(b) or nan(a) or nan(b)) {
        if (arithmetic(fp, a, b, .add, flags)) |result| {
            put(fp, top(fp.*), result);
            fp.status &= ~@as(u16, 0x400);
        }
        return;
    }
    if (exponent(a) == 0x7fff or @as(u64, @truncate(b)) == 0) {
        if (!raise(fp, 1)) {
            put(fp, top(fp.*), indefinite);
            fp.status &= ~@as(u16, 0x400);
        }
        return;
    }
    if (denormal(a) or denormal(b)) flags |= 2;
    if (raise(fp, flags)) return;
    if (exponent(b) == 0x7fff or @as(u64, @truncate(a)) == 0) {
        fp.status &= ~@as(u16, 0x4700);
        return;
    }
    const x = finite(a);
    var y = finite(b);
    const partial = x.scale - y.scale >= 64;
    // The ISA permits a 32..63-bit reduction. Use 32 consistently for our CPU.
    if (partial) y.scale += x.scale - y.scale - 32;
    const gap = x.scale - y.scale;
    var magnitude = x.significand;
    var scale = x.scale;
    var quotient: u256 = 0;
    var negative = a & sign != 0;
    if (gap >= -1) {
        const numerator = x.significand << @as(u8, @intCast(@max(gap, 0)));
        const divisor = y.significand << @as(u8, @intCast(@max(-gap, 0)));
        quotient = numerator / divisor;
        magnitude = numerator % divisor;
        scale = @min(x.scale, y.scale);
        if (!partial and nearest and (magnitude * 2 > divisor or magnitude * 2 == divisor and quotient & 1 != 0)) {
            quotient += 1;
            magnitude = divisor - magnitude;
            negative = !negative;
        }
    }
    // Remainders are exact at 64 bits and ignore arithmetic precision control.
    var context = fp.*;
    context.control |= 0x300;
    const result = roundArithmetic(&context, magnitude, scale, negative);
    fp.status = context.status;
    if (partial) fp.status |= 0x400 else {
        const bits: u3 = @truncate(if ((a ^ b) & sign != 0) 0 -% quotient else quotient);
        fp.status = (fp.status & ~@as(u16, 0x4700)) | (@as(u16, bits & 4) << 6) | (@as(u16, bits & 2) << 13) | (@as(u16, bits & 1) << 9);
    }
    put(fp, top(fp.*), result);
}
fn calculation(s: *State, fp: *Fp, m: *Memory, code: u16, addr: u64) !void {
    const op = code >> 8;
    const byte: u8 = @truncate(code);
    const group: u3 = @truncate(byte >> 3);
    const memory = byte < 0xc0;
    var flags: u16 = 0;
    var a = stack(fp.*, 0, &flags);
    var b: u80 = undefined;
    if (memory) {
        const width: u7 = if (op == 0xde) 16 else if (op == 0xdc) 64 else 32;
        const bits = try m.readInt(addr, width, .read);
        b = if (op == 0xda or op == 0xde) extended(@floatFromInt(ir.signed(bits, width))) else loadFloat(bits, width, &flags, false);
    } else b = if (op == 0xd9) 0 else stack(fp.*, if (code == 0xdae9 or code == 0xded9) 1 else @truncate(byte), &flags);
    fp.status &= ~@as(u16, 0x200);
    if (code == 0xd9fa or code == 0xd9fc) {
        if (unary(fp, a, code == 0xd9fa, flags)) |result| put(fp, top(fp.*), result);
        return;
    }
    const compare = (memory or op == 0xd8) and (group == 2 or group == 3) or code == 0xd9e4 or code == 0xdae9 or code == 0xded9 or op == 0xdd or op == 0xdb or op == 0xdf;
    if (compare) {
        const eflags = op == 0xdb or op == 0xdf;
        const quiet_compare = op == 0xdd or code == 0xdae9 or eflags and group == 5;
        const unordered = flags & 0x40 != 0 or unsupported(a) or unsupported(b) or nan(a) or nan(b);
        if (unordered) {
            flags &= ~@as(u16, 2);
            if (flags & 0x40 != 0 or unsupported(a) or unsupported(b) or signaling(a) or signaling(b) or !quiet_compare) flags |= 1;
        } else if (denormal(a) or denormal(b)) flags |= 2;
        if (eflags) {
            s.flags.overflow = false;
            s.flags.sign = false;
        }
        if (raise(fp, flags)) return;
        const less = !unordered and floating(a) < floating(b);
        const equal = !unordered and floating(a) == floating(b);
        if (eflags) {
            s.flags.carry = unordered or less;
            s.flags.parity = unordered;
            s.flags.zero = unordered or equal;
        } else fp.status = (fp.status & ~@as(u16, 0x4500)) | (if (unordered) @as(u16, 0x4500) else if (less) @as(u16, 0x100) else if (equal) @as(u16, 0x4000) else 0);
        const pops: u2 = if (code == 0xdae9 or code == 0xded9) 2 else if (code == 0xd9e4) 0 else if (memory or op == 0xd8) @intFromBool(group == 3) else if (op == 0xdd) @intFromBool(group == 5) else @intFromBool(op == 0xdf);
        for (0..pops) |_| pop(fp);
    } else {
        const destination: u3 = if (!memory and op != 0xd8) @truncate(byte) else 0;
        if (destination != 0) {
            const temp = a;
            a = b;
            b = temp;
        }
        const reverse = if (memory or op == 0xd8) group == 5 or group == 7 else group == 4 or group == 6;
        if (reverse) {
            const temp = a;
            a = b;
            b = temp;
        }
        const operation: Binary = switch (group) {
            0 => .add,
            1 => .mul,
            4, 5 => .sub,
            6, 7 => .div,
            else => unreachable,
        };
        if (arithmetic(fp, a, b, operation, flags)) |result| {
            put(fp, physical(fp.*, destination), result);
            if (!memory and op == 0xde) pop(fp);
        }
    }
}

pub fn execute(s: *State, m: *Memory, i: ir.Instruction) !void {
    const code: u16 = @truncate(i.encoding);
    if (!supported(code)) return error.UnsupportedInstruction;
    if (code == 0x9b) return s.x86_fp.checkPending();
    const op = code >> 8;
    const byte: u8 = @truncate(code);
    const group: u3 = @truncate(byte >> 3);
    const no_wait = code == 0xdbe2 or code == 0xdbe3 or code == 0xdfe0 or byte < 0xc0 and group == 7 and (op == 0xd9 or op == 0xdd);
    if (!no_wait) try s.x86_fp.checkPending();
    var fp = s.x86_fp;
    const control = no_wait or byte < 0xc0 and op == 0xd9 and group == 5;
    const memory = byte < 0xc0;
    const addr = if (memory) operands.address(s, i.src.mem, i.next) else 0;
    const calculating = (op == 0xd8 or op == 0xda or op == 0xdc or op == 0xde) or code == 0xd9e4 or code == 0xd9fa or code == 0xd9fc or !memory and (op == 0xdd and byte >= 0xe0 or (op == 0xdb or op == 0xdf) and byte >= 0xe8);
    if (!memory and (op == 0xda or op == 0xdb) and byte < 0xe0) {
        var flags: u16 = 0;
        _ = stack(fp, 0, &flags);
        const source = stack(fp, @truncate(byte), &flags);
        if (flags != 0) fp.status &= ~@as(u16, 0x200);
        if (!raise(&fp, flags)) {
            const test_condition = switch (group) {
                0 => s.flags.carry,
                1 => s.flags.zero,
                2 => s.flags.carry or s.flags.zero,
                3 => s.flags.parity,
                else => unreachable,
            };
            if (flags != 0 or test_condition == (op == 0xda)) put(&fp, top(fp), if (flags != 0) indefinite else source);
        }
    } else if (calculating) {
        try calculation(s, &fp, m, code, addr);
    } else if (control) {
        switch (code) {
            0xdbe2 => fp.status &= ~@as(u16, 0x80ff),
            0xdbe3 => fp = .{ .registers = fp.registers, .mxcsr = fp.mxcsr },
            0xdfe0 => try operands.write(s, m, ir.reg(0), 16, fp.status, i.next),
            else => if (op == 0xd9 and group == 5) {
                fp.control = @intCast(try m.readInt(addr, 16, .read));
                pending(&fp);
            } else try m.writeInt(addr, 16, if (op == 0xd9) fp.control else fp.status),
        }
    } else if (!memory) {
        switch (code) {
            0xd9c0...0xd9c7 => {
                var flags: u16 = 0;
                const raw = stack(fp, @truncate(byte), &flags);
                push(&fp, raw, flags);
            },
            0xd9c8...0xd9cf => {
                var flags: u16 = 0;
                const a = stack(fp, 0, &flags);
                const b = stack(fp, @truncate(byte), &flags);
                fp.status &= ~@as(u16, 0x200);
                if (!raise(&fp, flags)) {
                    put(&fp, top(fp), b);
                    put(&fp, physical(fp, @truncate(byte)), a);
                }
            },
            0xd9d0 => {}, // FNOP still updates FIP and checks pending exceptions.
            0xd9e0, 0xd9e1 => {
                var flags: u16 = 0;
                var raw = stack(fp, 0, &flags);
                fp.status &= ~@as(u16, 0x200);
                if (!raise(&fp, flags)) {
                    if (flags == 0) raw = if (code == 0xd9e0) raw ^ sign else raw & ~sign;
                    put(&fp, top(fp), raw);
                }
            },
            0xd9e5 => examine(&fp),
            0xd9e8...0xd9ee => push(&fp, constant(byte, fp.control), 0),
            0xd9f4 => extract(&fp),
            0xd9f5, 0xd9f8 => partialRemainder(&fp, code == 0xd9f5),
            0xd9f6, 0xd9f7 => {
                fp.status &= ~@as(u16, 0x200);
                setTop(&fp, if (code == 0xd9f6) top(fp) -% 1 else top(fp) +% 1);
            },
            0xddc0...0xddc7 => fp.tag &= ~(@as(u8, 1) << physical(fp, @truncate(byte))),
            0xddd0...0xdddf => {
                var flags: u16 = 0;
                const raw = stack(fp, 0, &flags);
                fp.status &= ~@as(u16, 0x200);
                if (!raise(&fp, flags)) {
                    put(&fp, physical(fp, @truncate(byte)), raw);
                    if (byte >= 0xd8) pop(&fp);
                }
            },
            else => unreachable,
        }
    } else {
        const width: u7 = switch (op) {
            0xd9 => 32,
            0xdd => 64,
            0xdb => if (group == 5 or group == 7) 80 else 32,
            0xdf => if (group == 5 or group == 7) 64 else 16,
            else => unreachable,
        };
        const load = group == 0 or group == 5;
        try m.check(addr, width / 8, if (load) .read else .write);
        if (load) {
            var flags: u16 = 0;
            const raw = if (width == 80) blk: {
                var bytes: [10]u8 = undefined;
                try m.read(addr, &bytes, .read);
                break :blk std.mem.readInt(u80, &bytes, .little);
            } else if (op == 0xd9 or op == 0xdd)
                loadFloat(try m.readInt(addr, width, .read), width, &flags, true)
            else
                extended(@floatFromInt(ir.signed(try m.readInt(addr, width, .read), width)));
            push(&fp, raw, flags);
        } else {
            var flags: u16 = 0;
            const raw = stack(fp, 0, &flags);
            fp.status &= ~@as(u16, 0x200);
            if (width == 80) {
                if (!raise(&fp, flags)) {
                    var bytes: [10]u8 = undefined;
                    std.mem.writeInt(u80, &bytes, raw, .little);
                    try m.write(addr, &bytes);
                    pop(&fp);
                }
            } else {
                const fp_store = (op == 0xd9 or op == 0xdd) and group != 1;
                const bits = if (fp_store) storeFloat(&fp, raw, width, &flags) else storeInteger(&fp, raw, width, group == 1, &flags);
                _ = raise(&fp, flags);
                if (flags & ~fp.control & 25 == 0) {
                    try m.writeInt(addr, width, bits);
                    if (group == 1 or group == 3 or group == 7) pop(&fp);
                }
            }
        }
    }
    if (!control) {
        fp.instruction_pointer = i.pc;
        fp.code_selector = 0;
        if (memory) {
            fp.data_pointer = addr;
            fp.data_selector = 0;
        }
        // Modern Intel FOP is updated only when a non-control instruction faults.
        if (fp.status & ~fp.control & 0x3f != 0) fp.opcode = code & 0x7ff;
    }
    s.x86_fp = fp;
}

test "x87 encodings, exact-width faults and legacy control instructions" {
    const decode = @import("cpu/x86_64.zig").decode;
    const executeInstruction = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    var s = State{ .architecture = .x86_64, .pc = 0x1000 };
    s.set(7, 0x1ff7);
    for ([_][]const u8{ &.{ 0xdb, 0x2f }, &.{ 0xdb, 0x3f } }) |bytes| {
        try m.initialize(0x1000, bytes);
        const old = s;
        try std.testing.expectError(error.UnmappedMemory, executeInstruction(&s, &m, try decode(&m, 0x1000)));
        try std.testing.expect(std.meta.eql(old, s));
    }
    for ([_][]const u8{ &.{ 0xf0, 0xd9, 0xc0 }, &.{ 0xf0, 0xd9, 0x07 } }) |bytes| {
        try m.initialize(0x1000, bytes);
        try std.testing.expectError(error.InvalidLockPrefix, decode(&m, 0x1000));
    }
    for ([_][]const u8{ &.{ 0xdc, 0xd0 }, &.{ 0xd9, 0xef }, &.{ 0xdd, 0xc8 } }) |bytes| {
        try m.initialize(0x1000, bytes);
        try std.testing.expectError(error.UnsupportedInstruction, decode(&m, 0x1000));
    }
    // REX register extensions do not turn ST(0) into a different stack register.
    try m.initialize(0x1000, &.{ 0x45, 0xd9, 0xc0 });
    const duplicate = try decode(&m, 0x1000);
    try std.testing.expectEqual(@as(u32, 0xd9c0), duplicate.encoding);
    s.x86_fp.tag = 1;
    put(&s.x86_fp, 0, sign | (@as(u80, 0x3fff) << 64) | integer);
    _ = try executeInstruction(&s, &m, duplicate);
    try std.testing.expectEqual(@as(u3, 7), top(s.x86_fp));
    try std.testing.expectEqual(@as(u8, 0x81), s.x86_fp.tag);
    try std.testing.expectEqual(get(s.x86_fp, 0), get(s.x86_fp, 7));
    try std.testing.expectEqual(@as(u64, 0x1000), s.x86_fp.instruction_pointer);
    s.x86_fp.mxcsr = 0xff7f;
    const raw = s.x86_fp.registers;
    try m.initialize(0x1000, &.{ 0xdb, 0xe3 });
    _ = try executeInstruction(&s, &m, try decode(&m, 0x1000));
    try std.testing.expect(std.meta.eql(Fp{ .registers = raw, .mxcsr = 0xff7f }, s.x86_fp));
    s.set(7, 0x1ffe);
    try m.writeInt(0x1ffe, 16, 0xf7f);
    s.x86_fp.status = 32;
    try m.initialize(0x1000, &.{ 0xd9, 0x2f });
    _ = try executeInstruction(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u16, 0xf7f), s.x86_fp.control);
    try m.initialize(0x1000, &.{ 0xd9, 0x3f });
    _ = try executeInstruction(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u64, 0xf7f), try m.readInt(0x1ffe, 16, .read));
}

test "x87 stack faults are deferred and no-wait status, clear and init remain usable" {
    const decode = @import("cpu/x86_64.zig").decode;
    const executeInstruction = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0xd9, 0xc0 });
    var s = State{ .architecture = .x86_64, .pc = 0x1000 };
    s.x86_fp.control = 0x37e;
    const raw = s.x86_fp.registers;
    _ = try executeInstruction(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u16, 0x80c1), s.x86_fp.status);
    try std.testing.expectEqual(@as(u16, 0x1c0), s.x86_fp.opcode);
    try std.testing.expectEqual(@as(u8, 0), s.x86_fp.tag);
    try std.testing.expect(std.meta.eql(raw, s.x86_fp.registers));
    try m.initialize(0x1000, &.{ 0x9b, 0xdb, 0xe3 });
    const faulting = s;
    try std.testing.expectError(error.FloatingPointException, executeInstruction(&s, &m, try decode(&m, 0x1000)));
    try std.testing.expect(std.meta.eql(faulting, s));
    // FNSTSW stores AX while preserving the rest of RAX and the pending state.
    try m.initialize(0x1000, &.{ 0xdf, 0xe0 });
    s.set(0, 0x123456789abcdef0);
    _ = try executeInstruction(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u64, 0x123456789abc80c1), s.get(0));
    try std.testing.expectEqual(faulting.x86_fp, s.x86_fp);
    try m.initialize(0x1000, &.{ 0xdb, 0xe2 });
    _ = try executeInstruction(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u16, 0), s.x86_fp.status);
    try std.testing.expectEqual(@as(u16, 0x1c0), s.x86_fp.opcode);
    try m.initialize(0x1000, &.{ 0xd9, 0xe8 });
    s.x86_fp.control = 0x37f;
    for (0..9) |_| _ = try executeInstruction(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u16, 0x3a41), s.x86_fp.status);
    try std.testing.expectEqual(@as(u8, 0xff), s.x86_fp.tag);
    try std.testing.expectEqual(indefinite, get(s.x86_fp, 7));
    s.x86_fp.control = 0x37e;
    try m.initialize(0x1000, &.{ 0xdb, 0xe3 });
    _ = try executeInstruction(&s, &m, try decode(&m, 0x1000));
    try std.testing.expectEqual(@as(u16, 0x37f), s.x86_fp.control);
    try std.testing.expectEqual(@as(u8, 0), s.x86_fp.tag);
}

test "x87 unmasked stores preserve O/U destinations but precision stores commit and pop" {
    const decode = @import("cpu/x86_64.zig").decode;
    const executeInstruction = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0xd9, 0x1f }); // FSTP m32fp.
    for ([_]struct { value: f128, control: u16, status: u16, destination: u32, pop: bool }{
        .{ .value = 0x1p128, .control = 0x377, .status = 0xb888, .destination = 0xabcdef01, .pop = false },
        .{ .value = 0x1p-127, .control = 0x36f, .status = 0xb890, .destination = 0xabcdef01, .pop = false },
        .{ .value = 1 + 0x1p-24, .control = 0x35f, .status = 0x80a0, .destination = 0x3f800000, .pop = true },
    }) |case| {
        var s = State{ .architecture = .x86_64, .pc = 0x1000 };
        s.set(7, 0x1ffc);
        s.x86_fp.control = case.control;
        setTop(&s.x86_fp, 7);
        put(&s.x86_fp, 7, extended(case.value));
        const before = s.x86_fp.registers;
        try m.writeInt(0x1ffc, 32, 0xabcdef01);
        _ = try executeInstruction(&s, &m, try decode(&m, 0x1000));
        try std.testing.expectEqual(case.status, s.x86_fp.status);
        try std.testing.expectEqual(case.destination, @as(u32, @intCast(try m.readInt(0x1ffc, 32, .read))));
        try std.testing.expectEqual(@as(u8, if (case.pop) 0 else 0x80), s.x86_fp.tag);
        try std.testing.expect(std.meta.eql(before, s.x86_fp.registers));
        try std.testing.expectEqual(@as(u16, 0x11f), s.x86_fp.opcode);
        try std.testing.expectEqual(@as(u64, 0x1000), s.x86_fp.instruction_pointer);
        try std.testing.expectEqual(@as(u64, 0x1ffc), s.x86_fp.data_pointer);
        try std.testing.expectEqual(@as(u32, 0x1f80), s.x86_fp.mxcsr);
    }
}

test "x87 pushes and raw stores share physical data with MMX across EMMS" {
    const decode = @import("cpu/x86_64.zig").decode;
    const executeInstruction = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    // FLD1; MOVQ mm0,mm7; EMMS; FLDZ; FXCH ST(1); FNCLEX.
    try m.initialize(0x1000, &.{ 0xd9, 0xe8, 0x0f, 0x6f, 0xc7, 0x0f, 0x77, 0xd9, 0xee, 0xd9, 0xc9, 0xdb, 0xe2 });
    var s = State{ .architecture = .x86_64, .pc = 0x1000 };
    _ = try executeInstruction(&s, &m, try decode(&m, s.pc));
    try std.testing.expectEqual(integer, std.mem.readInt(u64, s.getVector(23)[0..8], .little));
    _ = try executeInstruction(&s, &m, try decode(&m, s.pc));
    try std.testing.expectEqual(@as(u8, 0xff), s.x86_fp.tag);
    try std.testing.expectEqual(@as(u3, 0), top(s.x86_fp));
    try std.testing.expectEqual((@as(u80, 0xffff) << 64) | integer, get(s.x86_fp, 0));
    const before = s.x86_fp.registers;
    _ = try executeInstruction(&s, &m, try decode(&m, s.pc));
    try std.testing.expectEqual(@as(u8, 0), s.x86_fp.tag);
    try std.testing.expect(std.meta.eql(before, s.x86_fp.registers));
    _ = try executeInstruction(&s, &m, try decode(&m, s.pc));
    try std.testing.expectEqual(@as(u8, 0x80), s.x86_fp.tag);
    try std.testing.expectEqual(@as(u80, 0), get(s.x86_fp, 7));
    s.x86_fp.control &= ~@as(u16, 1);
    const unexchanged = s.x86_fp.registers;
    _ = try executeInstruction(&s, &m, try decode(&m, s.pc));
    try std.testing.expectEqual(@as(u16, 0xb8c1), s.x86_fp.status);
    try std.testing.expect(std.meta.eql(unexchanged, s.x86_fp.registers));
    // No-wait clear allows the next data transfer despite a pending exception.
    _ = try executeInstruction(&s, &m, try decode(&m, s.pc));
    try m.initialize(s.pc, &.{ 0xdb, 0x3f }); // FSTP80 [rdi].
    s.set(7, 0x1ff6);
    _ = try executeInstruction(&s, &m, try decode(&m, s.pc));
    var result: [10]u8 = undefined;
    try m.read(0x1ff6, &result, .read);
    try std.testing.expectEqual(@as(u80, 0), std.mem.readInt(u80, &result, .little));
    try std.testing.expectEqual(@as(u8, 0), s.x86_fp.tag);
    try std.testing.expectEqual(@as(u3, 0), top(s.x86_fp));
}

test "x87 arithmetic checks exact source widths and every wrapped stack destination" {
    const decode = @import("cpu/x86_64.zig").decode;
    const executeInstruction = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    for ([_]struct { op: u8, address: u64 }{
        .{ .op = 0xd8, .address = 0x1ffe }, .{ .op = 0xdc, .address = 0x1ffc },
        .{ .op = 0xda, .address = 0x1ffe }, .{ .op = 0xde, .address = 0x1fff },
    }) |case| {
        var s = State{ .architecture = .x86_64, .pc = 0x1000 };
        s.set(7, case.address);
        s.x86_fp.status = 0x4700;
        for ([_]u8{ 0x07, 0x17, 0x1f, 0x37 }) |byte| {
            try m.initialize(0x1000, &.{ case.op, byte });
            const before = s;
            try std.testing.expectError(error.UnmappedMemory, executeInstruction(&s, &m, try decode(&m, s.pc)));
            try std.testing.expect(std.meta.eql(before, s));
            try m.initialize(0x1000, &.{ 0xf0, case.op, byte });
            try std.testing.expectError(error.InvalidLockPrefix, decode(&m, 0x1000));
        }
    }
    for (0..8) |slot| {
        var s = State{ .architecture = .x86_64, .pc = 0x1000 };
        setTop(&s.x86_fp, 3);
        for (0..8) |logical| put(&s.x86_fp, physical(s.x86_fp, @intCast(logical)), extended(@floatFromInt(logical + 1)));
        try m.initialize(0x1000, &.{ 0x45, 0xdc, 0xc0 + @as(u8, @intCast(slot)) });
        _ = try executeInstruction(&s, &m, try decode(&m, s.pc));
        try std.testing.expectEqual(extended(@floatFromInt(slot + 2)), get(s.x86_fp, physical(s.x86_fp, @intCast(slot))));
        try std.testing.expectEqual(@as(u3, 3), top(s.x86_fp));
        try std.testing.expectEqual(@as(u8, 0xff), s.x86_fp.tag);
    }
}

test "x87 unmasked post exceptions store biased results and pop before deferred WAIT" {
    const decode = @import("cpu/x86_64.zig").decode;
    const executeInstruction = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    for ([_]struct { byte: u8, mask: u16, a: u80, b: u80, result: u80, flags: u16 }{
        .{ .byte = 0xc9, .mask = 8, .a = (@as(u80, 0x7ffe) << 64) | integer, .b = (@as(u80, 0x4000) << 64) | integer, .result = (@as(u80, 0x1fff) << 64) | integer, .flags = 8 },
        .{ .byte = 0xc9, .mask = 16, .a = (@as(u80, 1) << 64) | integer, .b = (@as(u80, 0x3ffe) << 64) | integer, .result = (@as(u80, 0x6000) << 64) | integer, .flags = 16 },
        .{ .byte = 0xc1, .mask = 32, .a = (@as(u80, 0x3fbf) << 64) | integer, .b = (@as(u80, 0x3fff) << 64) | integer, .result = (@as(u80, 0x3fff) << 64) | integer, .flags = 32 },
    }) |case| {
        var s = State{ .architecture = .x86_64, .pc = 0x1000 };
        s.x86_fp.control &= ~case.mask;
        put(&s.x86_fp, 0, case.a);
        put(&s.x86_fp, 1, case.b);
        try m.initialize(0x1000, &.{ 0xde, case.byte, 0x9b });
        _ = try executeInstruction(&s, &m, try decode(&m, s.pc));
        try std.testing.expectEqual(case.result, get(s.x86_fp, 1));
        try std.testing.expectEqual(@as(u16, 0x8880) | case.flags, s.x86_fp.status);
        try std.testing.expectEqual(@as(u8, 2), s.x86_fp.tag);
        const before = s;
        try std.testing.expectError(error.FloatingPointException, executeInstruction(&s, &m, try decode(&m, s.pc)));
        try std.testing.expect(std.meta.eql(before, s));
    }
}

test "x87 remainders are exact, expose quotient bits and retain deferred faults" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    const infinity = (@as(u80, 0x7fff) << 64) | integer;
    for ([_]struct { nearest: bool = false, a: u80, b: u80, result: u80, status: u16, control: u16 = 0x37f, commit: bool = true }{
        .{ .a = extended(7), .b = extended(2), .result = extended(1), .status = 0x4200 },
        .{ .nearest = true, .a = extended(7), .b = extended(2), .result = extended(-1), .status = 0x100 },
        .{ .nearest = true, .a = extended(5), .b = extended(2), .result = extended(1), .status = 0x4000 },
        .{ .a = extended(-7), .b = extended(2), .result = extended(-1), .status = 0x300 },
        .{ .nearest = true, .a = extended(-7), .b = extended(2), .result = extended(1), .status = 0x100 },
        .{ .a = extended(-7), .b = extended(-2), .result = extended(-1), .status = 0x4200 },
        .{ .a = sign, .b = extended(2), .result = sign, .status = 0 },
        .{ .a = extended(3), .b = infinity, .result = extended(3), .status = 0 },
        .{ .a = infinity, .b = extended(2), .result = indefinite, .status = 0x4101 },
        .{ .a = extended(3), .b = 0, .result = indefinite, .status = 0x4101 },
        .{ .a = extended(3), .b = 0, .result = extended(3), .status = 0xc581, .control = 0x37e, .commit = false },
        .{ .a = extended(3), .b = infinity | 7, .result = infinity | quiet | 7, .status = 0x4101 },
        .{ .a = (@as(u80, 1) << 64) | integer | 1, .b = (@as(u80, 1) << 64) | integer, .result = 1, .status = 0x200 },
        .{ .a = (@as(u80, 1) << 64) | integer | 1, .b = (@as(u80, 1) << 64) | integer, .result = (@as(u80, 0x5fc2) << 64) | integer, .status = 0x8290, .control = 0x36f },
        .{ .a = 1, .b = extended(2), .result = 1, .status = 2 },
        .{ .a = 1, .b = extended(2), .result = 1, .status = 0xc582, .control = 0x37d, .commit = false },
    }) |case| {
        for (0..8) |slot| {
            var s = State{ .architecture = .x86_64, .pc = 0x1000, .flags = .{ .carry = true, .zero = true, .direction = true } };
            s.x86_fp.control = case.control;
            s.x86_fp.status = 0x4700;
            setTop(&s.x86_fp, @intCast(slot));
            put(&s.x86_fp, @intCast(slot), case.a);
            const divisor = physical(s.x86_fp, 1);
            put(&s.x86_fp, divisor, case.b);
            const before = s;
            try m.initialize(0x1000, &.{ 0xd9, if (case.nearest) 0xf5 else 0xf8, 0x9b });
            _ = try run(&s, &m, try decode(&m, s.pc));
            try std.testing.expectEqual(case.result, get(s.x86_fp, @intCast(slot)));
            try std.testing.expectEqual(case.b, get(s.x86_fp, divisor));
            try std.testing.expectEqual(case.status | (@as(u16, @intCast(slot)) << 11), s.x86_fp.status);
            try std.testing.expectEqual(before.x86_fp.tag, s.x86_fp.tag);
            try std.testing.expectEqual(before.flags, s.flags);
            try std.testing.expectEqual(before.x86_fp.control, s.x86_fp.control);
            try std.testing.expectEqual(before.x86_fp.mxcsr, s.x86_fp.mxcsr);
            if (!case.commit) try std.testing.expectEqual(before.x86_fp.registers, s.x86_fp.registers);
            if (case.status & 0x8080 != 0) {
                const pending_state = s;
                try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, s.pc)));
                try std.testing.expectEqual(pending_state, s);
            }
        }
    }
    for ([_]u8{ 0xf5, 0xf8 }) |byte| {
        try m.initialize(0x1000, &.{ 0xd9, byte });
        var fp = Fp{ .control = 0x7f };
        put(&fp, 0, (@as(u80, 16483) << 64) | integer | 2); // 2^100 + 2^38.
        put(&fp, 1, extended(3));
        var s = State{ .architecture = .x86_64, .pc = 0x1000, .x86_fp = fp };
        _ = try run(&s, &m, try decode(&m, 0x1000));
        try std.testing.expectEqual(extended(0x1p68 + 0x1p38), get(s.x86_fp, 0));
        try std.testing.expectEqual(@as(u16, 0x400), s.x86_fp.status);
        var steps: usize = 1;
        while (s.x86_fp.status & 0x400 != 0 and steps < 5) : (steps += 1) _ = try run(&s, &m, try decode(&m, 0x1000));
        try std.testing.expectEqual(@as(usize, 3), steps);
        try std.testing.expectEqual(extended(if (byte == 0xf5) -1 else 2), get(s.x86_fp, 0));
        try std.testing.expectEqual(@as(u16, if (byte == 0xf5) 0x4200 else 0x4000), s.x86_fp.status);
        try std.testing.expectEqual(@as(u16, 0x7f), s.x86_fp.control);

        // An odd modulus retains a nonzero residue through nearly the full
        // exponent range, rather than collapsing early as powers of two can.
        s = .{ .architecture = .x86_64, .pc = 0x1000 };
        s.x86_fp.control = 0x7f;
        put(&s.x86_fp, 0, (@as(u80, 0x7ffe) << 64) | integer | 1);
        put(&s.x86_fp, 1, 5);
        steps = 0;
        while (steps < 1100) {
            _ = try run(&s, &m, try decode(&m, 0x1000));
            steps += 1;
            if (s.x86_fp.status & 0x400 == 0) break;
        }
        try std.testing.expect(steps > 900 and steps < 1100);
        try std.testing.expectEqual(if (byte == 0xf5) sign | 2 else @as(u80, 3), get(s.x86_fp, 0));
        try std.testing.expectEqual(@as(u16, if (byte == 0xf5) 0x4002 else 0x202), s.x86_fp.status);
        try std.testing.expectEqual(@as(u80, 5), get(s.x86_fp, 1));
        try std.testing.expectEqual(@as(u8, 3), s.x86_fp.tag);
    }
}

test "FXTRACT preserves exact extended significands and defers operand and stack faults" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0xd9, 0xf4, 0x9b });
    const infinity = (@as(u80, 0x7fff) << 64) | integer;
    for ([_]struct { raw: u80, significand: u80, power: u80, flags: u16 = 0, empty: bool = false }{
        .{ .raw = extended(-20), .significand = extended(-1.25), .power = extended(4) },
        .{ .raw = 1, .significand = extended(1), .power = extended(-16445), .flags = 2 },
        .{ .raw = integer, .significand = extended(1), .power = extended(-16382), .flags = 2 },
        .{ .raw = 0, .significand = 0, .power = sign | infinity, .flags = 4 },
        .{ .raw = sign, .significand = sign, .power = sign | infinity, .flags = 4 },
        .{ .raw = sign | infinity, .significand = sign | infinity, .power = infinity },
        .{ .raw = infinity | quiet | 17, .significand = infinity | quiet | 17, .power = infinity | quiet | 17 },
        .{ .raw = sign | infinity | 17, .significand = sign | infinity | quiet | 17, .power = sign | infinity | quiet | 17, .flags = 1 },
        .{ .raw = @as(u80, 0x3fff) << 64, .significand = indefinite, .power = indefinite, .flags = 1 },
        .{ .raw = extended(3), .significand = indefinite, .power = indefinite, .flags = 0x41, .empty = true },
    }) |case| {
        for (0..8) |slot| {
            for ([_]u16{ 0x37f, 0x378 }) |control| {
                var s = State{ .architecture = .x86_64, .pc = 0x1000, .flags = .{ .carry = true, .direction = true } };
                s.x86_fp.control = control;
                s.x86_fp.status = 0x4700;
                setTop(&s.x86_fp, @intCast(slot));
                put(&s.x86_fp, @intCast(slot), case.raw);
                if (case.empty) s.x86_fp.tag = 0;
                const before = s;
                _ = try run(&s, &m, try decode(&m, s.pc));
                const trapped = case.flags & ~control & 63 != 0;
                const next: u3 = @as(u3, @intCast(slot)) -% @as(u3, @intFromBool(!trapped));
                try std.testing.expectEqual(@as(u16, 0x4500) | (@as(u16, next) << 11) | case.flags | (if (trapped) @as(u16, 0x8080) else 0), s.x86_fp.status);
                try std.testing.expectEqual(before.flags, s.flags);
                try std.testing.expectEqual(before.x86_fp.mxcsr, s.x86_fp.mxcsr);
                if (trapped) {
                    try std.testing.expectEqual(before.x86_fp.tag, s.x86_fp.tag);
                    try std.testing.expectEqual(before.x86_fp.registers, s.x86_fp.registers);
                    const pending_state = s;
                    try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, s.pc)));
                    try std.testing.expectEqual(pending_state, s);
                } else {
                    try std.testing.expectEqual(case.significand, get(s.x86_fp, next));
                    try std.testing.expectEqual(case.power, get(s.x86_fp, @intCast(slot)));
                }
            }
        }
    }
    for ([_]u16{ 0x37f, 0x37e }) |control| {
        var s = State{ .architecture = .x86_64, .pc = 0x1000 };
        s.x86_fp.control = control;
        for (0..8) |slot| put(&s.x86_fp, @intCast(slot), extended(3));
        const before = s.x86_fp.registers;
        _ = try run(&s, &m, try decode(&m, s.pc));
        try std.testing.expectEqual(@as(u16, if (control & 1 != 0) 0x3a41 else 0x82c1), s.x86_fp.status);
        try std.testing.expectEqual(@as(u8, 0xff), s.x86_fp.tag);
        if (control & 1 == 0) try std.testing.expectEqual(before, s.x86_fp.registers) else {
            try std.testing.expectEqual(indefinite, get(s.x86_fp, 0));
            try std.testing.expectEqual(indefinite, get(s.x86_fp, 7));
        }
    }
}

test "x87 conditional moves test all flag patterns and check empty operands even when untaken" {
    const decode = @import("cpu/x86_64.zig").decode;
    const executeInstruction = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    const truth = [_]u8{ 0xaa, 0xcc, 0xee, 0xf0, 0x55, 0x33, 0x11, 0x0f };
    for (truth, 0..) |pattern, form| {
        for (0..8) |flags| {
            for (0..8) |slot| {
                var s = State{ .architecture = .x86_64, .pc = 0x1000, .flags = .{ .carry = flags & 1 != 0, .zero = flags & 2 != 0, .parity = flags & 4 != 0, .sign = true, .overflow = true, .direction = true } };
                s.x86_fp.status = 0x4700;
                setTop(&s.x86_fp, 3);
                for (0..8) |logical| put(&s.x86_fp, physical(s.x86_fp, @intCast(logical)), (@as(u80, 0x7fff) << 64) | integer | (logical + 1));
                const before = s;
                try m.initialize(0x1000, &.{ 0x45, if (form < 4) 0xda else 0xdb, 0xc0 + @as(u8, @intCast((form % 4) * 8 + slot)) });
                _ = try executeInstruction(&s, &m, try decode(&m, s.pc));
                const taken = pattern & (@as(u8, 1) << @intCast(flags)) != 0;
                try std.testing.expectEqual(get(before.x86_fp, physical(before.x86_fp, if (taken) @intCast(slot) else 0)), get(s.x86_fp, 3));
                try std.testing.expectEqual(before.x86_fp.status, s.x86_fp.status);
                try std.testing.expectEqual(before.x86_fp.tag, s.x86_fp.tag);
                try std.testing.expectEqual(before.flags.bits(), s.flags.bits());
            }
        }
    }
    for ([_]u16{ 0x37f, 0x37e }) |control| {
        var s = State{ .architecture = .x86_64, .pc = 0x1000 };
        s.x86_fp.control = control;
        s.x86_fp.status = 0x200;
        put(&s.x86_fp, 0, extended(3));
        try m.initialize(0x1000, &.{ 0xda, 0xc1, 0x9b }); // CF=0: FCMOVB is untaken.
        _ = try executeInstruction(&s, &m, try decode(&m, s.pc));
        try std.testing.expectEqual(if (control & 1 != 0) indefinite else extended(3), get(s.x86_fp, 0));
        try std.testing.expectEqual(@as(u16, 0x41) | (if (control & 1 != 0) @as(u16, 0) else 0x8080), s.x86_fp.status);
        if (control & 1 == 0) {
            const before = s;
            try std.testing.expectError(error.FloatingPointException, executeInstruction(&s, &m, try decode(&m, s.pc)));
            try std.testing.expect(std.meta.eql(before, s));
        }
    }
}
