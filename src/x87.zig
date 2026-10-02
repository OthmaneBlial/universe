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
        0xd9f0,
        0xd9f1,
        0xd9f2,
        0xd9f3,
        0xd9f4,
        0xd9f5,
        0xd9f6,
        0xd9f7,
        0xd9f8,
        0xd9f9,
        0xd9fa,
        0xd9fb,
        0xd9fc,
        0xd9fd,
        0xd9fe,
        0xd9ff,
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
        0xd9 => group == 0 or group >= 2,
        0xdd => group <= 4 or group >= 6,
        0xdb => group <= 3 or group == 5 or group == 7,
        0xdf => true,
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
fn tagWord(fp: Fp) u16 {
    var tags: u16 = 0;
    for (0..8) |slot| {
        const raw = get(fp, @intCast(slot));
        const tag: u16 = if (fp.tag & (@as(u8, 1) << @intCast(slot)) == 0) 3 else if (exponent(raw) == 0 and @as(u64, @truncate(raw)) == 0) 1 else if (exponent(raw) == 0 or exponent(raw) == 0x7fff or unsupported(raw)) 2 else 0;
        tags |= tag << @as(u4, @intCast(slot * 2));
    }
    return tags;
}
fn environment(fp: *Fp, m: *Memory, i: ir.Instruction, addr: u64) !void {
    const short = i.width == 16;
    const full = i.encoding >> 8 == 0xdd;
    const store = i.encoding & 0x38 == 0x30;
    const header: usize = if (short) 14 else 28;
    const size = header + @as(usize, if (full) 80 else 0);
    var bytes: [108]u8 = @splat(0);
    if (store) {
        std.mem.writeInt(u16, bytes[0..2], fp.control, .little);
        const step: usize = if (short) 2 else 4;
        std.mem.writeInt(u16, bytes[step..][0..2], fp.status, .little);
        std.mem.writeInt(u16, bytes[step * 2 ..][0..2], tagWord(fp.*), .little);
        if (short) {
            std.mem.writeInt(u16, bytes[6..8], @truncate(fp.instruction_pointer), .little);
            std.mem.writeInt(u16, bytes[8..10], fp.code_selector, .little);
            std.mem.writeInt(u16, bytes[10..12], @truncate(fp.data_pointer), .little);
            std.mem.writeInt(u16, bytes[12..14], fp.data_selector, .little);
        } else {
            std.mem.writeInt(u32, bytes[12..16], @truncate(fp.instruction_pointer), .little);
            std.mem.writeInt(u16, bytes[16..18], fp.code_selector, .little);
            std.mem.writeInt(u16, bytes[18..20], fp.opcode & 0x7ff, .little);
            std.mem.writeInt(u32, bytes[20..24], @truncate(fp.data_pointer), .little);
            std.mem.writeInt(u16, bytes[24..26], fp.data_selector, .little);
        }
        if (full) for (0..8) |slot| {
            @memcpy(bytes[header + slot * 10 ..][0..10], &fp.registers[physical(fp.*, @intCast(slot))]);
        };
        // One checked write reserves COW pages before any data or FPU change.
        try m.write(addr, bytes[0..size]);
        if (full) fp.* = .{ .registers = fp.registers, .mxcsr = fp.mxcsr } else {
            fp.control |= 0x3f;
            pending(fp);
        }
    } else {
        try m.read(addr, bytes[0..size], .read);
        fp.control = std.mem.readInt(u16, bytes[0..2], .little);
        const step: usize = if (short) 2 else 4;
        fp.status = std.mem.readInt(u16, bytes[step..][0..2], .little);
        const tags = std.mem.readInt(u16, bytes[step * 2 ..][0..2], .little);
        fp.tag = 0;
        for (0..8) |slot| {
            if (tags >> @as(u4, @intCast(slot * 2)) & 3 != 3) fp.tag |= @as(u8, 1) << @intCast(slot);
        }
        if (short) {
            fp.instruction_pointer = std.mem.readInt(u16, bytes[6..8], .little);
            fp.code_selector = std.mem.readInt(u16, bytes[8..10], .little);
            fp.data_pointer = std.mem.readInt(u16, bytes[10..12], .little);
            fp.data_selector = std.mem.readInt(u16, bytes[12..14], .little);
            // The 16-bit protected-mode image has no last-opcode field.
        } else {
            fp.instruction_pointer = std.mem.readInt(u32, bytes[12..16], .little);
            fp.code_selector = std.mem.readInt(u16, bytes[16..18], .little);
            fp.opcode = std.mem.readInt(u16, bytes[18..20], .little) & 0x7ff;
            fp.data_pointer = std.mem.readInt(u32, bytes[20..24], .little);
            fp.data_selector = std.mem.readInt(u16, bytes[24..26], .little);
        }
        if (full) for (0..8) |slot| {
            @memcpy(&fp.registers[physical(fp.*, @intCast(slot))], bytes[header + slot * 10 ..][0..10]);
        };
        pending(fp);
    }
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
fn loadBcd(bits: u80) u80 {
    var magnitude: u64 = 0;
    // Invalid decimal nibbles have architecturally undefined results, not #IA.
    for (0..18) |digit| magnitude = magnitude * 10 + @as(u4, @truncate(bits >> @as(u7, @intCast((17 - digit) * 4))));
    return extended(@floatFromInt(magnitude)) | (bits & sign);
}
fn storeBcd(fp: *Fp, raw: u80, flags: *u16) u80 {
    const invalid: u80 = 0xffffc000000000000000;
    if (unsupported(raw) or exponent(raw) == 0x7fff) {
        flags.* |= 1;
        return invalid;
    }
    const exact = floating(raw);
    const rounded = simd.roundIntegral(exact, @as(u2, @truncate(fp.control >> 10)));
    if (@abs(rounded) >= 1000000000000000000) {
        flags.* |= 1;
        return invalid;
    }
    if (rounded != exact) {
        flags.* |= 32;
        if (@abs(rounded) > @abs(exact)) fp.status |= 0x200;
    }
    var magnitude: u64 = @intFromFloat(@abs(rounded));
    var bcd: u80 = raw & sign;
    for (0..18) |digit| {
        bcd |= @as(u80, magnitude % 10) << @as(u7, @intCast(digit * 4));
        magnitude /= 10;
    }
    return bcd;
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
        if (e > 16383) {
            _ = raise(fp, flags);
            if (q.up) fp.status |= 0x200;
            return signed | (@as(u80, 0x7fff) << 64) | integer;
        }
    } else if (e < -16382) {
        if (fp.control & 16 == 0) {
            flags |= 16;
            e += 24576;
            if (e < -16382) {
                _ = raise(fp, flags);
                if (q.up) fp.status |= 0x200;
                return signed;
            }
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
fn roundTranscendental(fp: *Fp, approximation: f128, scale: i32, inexact: bool) u80 {
    const bits: u128 = @bitCast(approximation);
    const exp: u15 = @truncate(bits >> 112);
    const magnitude = (bits & ((@as(u128, 1) << 112) - 1)) | (if (exp != 0) @as(u128, 1) << 112 else 0);
    return roundTranscendentalBits(fp, magnitude, @as(i32, @max(exp, 1)) - 16495 + scale, bits >> 127 != 0, inexact);
}
fn roundTranscendentalBits(fp: *Fp, magnitude: u256, scale: i32, negative: bool, inexact: bool) u80 {
    var context = fp.*;
    context.control |= 0x300; // Transcendentals ignore PC, but honor RC.
    const result = roundArithmetic(&context, magnitude, scale, negative);
    fp.status = context.status;
    // An irrational true result stays inexact even when its approximation is
    // exactly representable. A tiny masked result then needs both #P and #U.
    if (inexact) _ = raise(fp, 32 | (if (fp.control & 16 != 0 and exponent(result) == 0) @as(u16, 16) else 0));
    return result;
}
fn exponential(fp: *Fp, raw: u80, initial_flags: u16) ?u80 {
    if (initial_flags & 64 != 0 or unsupported(raw) or nan(raw)) return arithmetic(fp, raw, 0, .add, initial_flags);
    if (raise(fp, initial_flags | (if (denormal(raw)) @as(u16, 2) else 0))) return null;
    const x = floating(raw);
    // Outside [-1, 1] the ISA leaves the result undefined; retain our operand.
    if (@abs(x) > 1 or x == 0) return raw;
    if (x == 1) return extended(1);
    if (x == -1) return extended(-0.5);
    const y = x * std.math.ln2;
    var term: f128 = 1;
    var sum: f128 = 1;
    // expm1(y) / y avoids cancellation. Multiply a normalized input so tiny
    // results retain guard bits even for an unmasked, exponent-biased #U.
    // ponytail: 113-bit approximation; more guard bits if a hard rounding case appears.
    for (2..41) |n| {
        term *= y / @as(f128, @floatFromInt(n));
        const next = sum + term;
        if (next == sum) break;
        sum = next;
    }
    const input = finite(raw);
    const approximation = @as(f128, @floatFromInt(@as(u64, @intCast(input.significand)))) * std.math.ln2 * sum;
    return roundTranscendental(fp, if (x < 0) -approximation else approximation, input.scale, true);
}
fn seriesRatio(square: f128) f128 {
    var term: f128 = 1;
    var sum: f128 = 1;
    // ponytail: 113-bit approximation; more guard bits for hard rounding cases.
    var n: u8 = 3;
    while (n < 129) : (n += 2) {
        term *= square;
        const next = sum + term / @as(f128, @floatFromInt(n));
        if (next == sum) break;
        sum = next;
    }
    return sum;
}
fn tinyOdd(fp: *Fp, quotient: u256, shift: i32, negative: bool, coefficients: [3]i16, denominators: [3]u16, tail: bool) u80 {
    var magnitude = quotient;
    var term: u1536 = quotient;
    const square: u1536 = @as(u1536, quotient) * quotient;
    // ponytail: 192 fractional bits; more if a hard rounding case appears.
    for (denominators, 0..) |denominator, index| {
        term *= square;
        const distance = @as(i32, @intCast(index * 2 + 2)) * (192 - shift);
        const correction: u256 = if (distance >= 1536) 0 else @intCast(((term * @as(u1536, @abs(coefficients[index]))) >> @as(u11, @intCast(distance))) / denominator);
        magnitude = if (coefficients[index] > 0) magnitude + correction else magnitude - correction;
    }
    if (magnitude == quotient) magnitude = if (tail or coefficients[0] > 0) quotient | 1 else quotient - 1;
    return roundTranscendentalBits(fp, magnitude, shift - 192, negative, true);
}
fn tinyCosine(fp: *Fp, quotient: u256, shift: i32, negative: bool) u80 {
    const one: u256 = @as(u256, 1) << 192;
    var magnitude = one;
    var term: u2048 = 1;
    const square: u2048 = @as(u2048, quotient) * quotient;
    // Integer terms keep the correction below one after binary128 would lose it.
    for ([_]u32{ 2, 24, 720, 40320, 3628800 }, 0..) |denominator, index| {
        term *= square;
        const n: i32 = @intCast(index * 2 + 2);
        const distance = (n - 1) * 192 - n * shift;
        const correction: u256 = if (distance >= 2048) 0 else @intCast((term >> @as(u11, @intCast(distance))) / denominator);
        magnitude = if (index & 1 != 0) magnitude + correction else magnitude - correction;
    }
    if (magnitude == one) magnitude -= 1;
    return roundTranscendentalBits(fp, magnitude, -192, negative, true);
}
const pi_half_fixed: u320 = 0x1921fb54442d18469898cc51701b839a252049c1114cf98e804177d4c76273644;
fn reduceAngle(raw: u80) struct { residue: u256, quadrant: u2, above: bool } {
    const input = finite(raw);
    // pi/2 has 256 fractional bits. Integer reduction keeps large arguments
    // from losing their residual before the binary128 series evaluation.
    const argument = @as(u320, @intCast(input.significand)) << @as(u9, @intCast(input.scale + 256));
    const quadrant = (argument + pi_half_fixed / 2) / pi_half_fixed;
    const multiple = quadrant * pi_half_fixed;
    const residue: u256 = @intCast(if (multiple > argument) multiple - argument else argument - multiple);
    return .{ .residue = residue, .quadrant = @truncate(quadrant), .above = multiple > argument };
}
fn sineCosine(fp: *Fp, raw: u80, cosine: bool) u80 {
    const angle = reduceAngle(raw);
    const residue = angle.residue;
    const q = angle.quadrant;
    const even = q & 1 == 0;
    const value_cosine = cosine == even;
    var negative = if (cosine) !even != (q & 2 != 0) else q & 2 != 0;
    if (!value_cosine and angle.above) negative = !negative;
    if (!cosine and raw & sign != 0) negative = !negative;
    const power = -1 - @as(i32, @intCast(@clz(residue)));
    if (residue != 0 and power <= (if (value_cosine) @as(i32, -16) else -32)) {
        const distance = power + 64;
        const quotient = if (distance >= 0) residue >> @as(u8, @intCast(distance)) else residue << @as(u8, @intCast(-distance));
        if (value_cosine) return tinyCosine(fp, quotient, power, negative);
        const tail = distance > 0 and residue & ((@as(u256, 1) << @as(u8, @intCast(distance))) - 1) != 0;
        return tinyOdd(fp, quotient, power, negative, .{ -1, 1, -1 }, .{ 6, 120, 5040 }, tail);
    }
    const approximation = reducedSeries(residue, value_cosine);
    return roundTranscendental(fp, if (negative) -approximation else approximation, 0, true);
}
fn reducedSeries(residue: u256, cosine: bool) f128 {
    // Zig's LLVM backend cannot convert >128-bit integers to floats. Jam the
    // discarded tail before conversion so binary128 rounding keeps its sticky bit.
    const shift: i32 = @max(0, 128 - @as(i32, @intCast(@clz(residue))));
    const reduced: u128 = @intCast(jam(residue, shift));
    const angle = std.math.ldexp(@as(f128, @floatFromInt(reduced)), shift - 256);
    const square = -angle * angle;
    var term: f128 = 1;
    var sum: f128 = 1;
    // ponytail: 113-bit approximation; more guard bits for hard rounding cases.
    for (1..25) |n| {
        term *= square / @as(f128, @floatFromInt(if (cosine) (2 * n - 1) * 2 * n else 2 * n * (2 * n + 1)));
        sum += term;
    }
    return if (cosine) sum else angle * sum;
}
fn tangentResult(fp: *Fp, raw: u80) u80 {
    if (@as(u64, @truncate(raw)) == 0) return raw;
    const input = finite(raw);
    const power = input.scale + 63;
    if (power <= -32) return tinyOdd(fp, input.significand << 129, power, raw & sign != 0, .{ 1, 2, 17 }, .{ 3, 15, 315 }, false);
    const angle = reduceAngle(raw);
    const odd = angle.quadrant & 1 != 0;
    const negative = (angle.above != odd) != (raw & sign != 0);
    const residual_power = -1 - @as(i32, @intCast(@clz(angle.residue)));
    if (!odd and residual_power <= -32) {
        const distance = residual_power + 64;
        const quotient = if (distance >= 0) angle.residue >> @as(u8, @intCast(distance)) else angle.residue << @as(u8, @intCast(-distance));
        return tinyOdd(fp, quotient, residual_power, negative, .{ 1, 2, 17 }, .{ 3, 15, 315 }, true);
    }
    // Divide unrounded 113-bit series, avoiding an intermediate FP80 rounding.
    const sine = reducedSeries(angle.residue, false);
    const cosine = reducedSeries(angle.residue, true);
    const approximation = if (odd) cosine / sine else sine / cosine;
    return roundTranscendental(fp, if (negative) -approximation else approximation, 0, true);
}

fn trigonometricResult(fp: *Fp, raw: u80, cosine: bool) u80 {
    if (@as(u64, @truncate(raw)) == 0) return if (cosine) extended(1) else raw;
    const input = finite(raw);
    const power = input.scale + 63;
    return if (cosine and power <= -16)
        tinyCosine(fp, input.significand << 129, power, false)
    else if (!cosine and power <= -32)
        tinyOdd(fp, input.significand << 129, power, raw & sign != 0, .{ -1, 1, -1 }, .{ 6, 120, 5040 }, false)
    else
        sineCosine(fp, raw, cosine);
}
fn trigonometricPair(fp: *Fp, tangent: bool) void {
    var flags: u16 = 0;
    const raw = stack(fp.*, 0, &flags);
    fp.status &= ~@as(u16, 0x200);
    const destination = top(fp.*) -% 1;
    var sine: u80 = undefined;
    var cosine: u80 = undefined;
    if (flags & 64 != 0 or fp.tag & (@as(u8, 1) << destination) != 0) {
        if (flags & 64 == 0) fp.status |= 0x200;
        if (raise(fp, 65)) return;
        sine = indefinite;
        cosine = indefinite;
    } else if (unsupported(raw) or nan(raw)) {
        sine = arithmetic(fp, raw, 0, .add, 0) orelse return;
        cosine = sine;
    } else if (exponent(raw) == 0x7fff) {
        if (raise(fp, 1)) return;
        sine = indefinite;
        cosine = indefinite;
    } else if (raw & ~sign >= 0x403e8000000000000000) {
        fp.status |= 0x400;
        return;
    } else {
        if (raise(fp, if (denormal(raw)) 2 else 0)) return;
        if (tangent) {
            sine = tangentResult(fp, raw);
            cosine = extended(1);
        } else {
            var cosine_context = fp.*;
            cosine = trigonometricResult(&cosine_context, raw, true);
            sine = trigonometricResult(fp, raw, false);
            // C1 follows sine in our FSINCOS profile; accrue both exception
            // sets without letting the push clear the numerical rounding flag.
            fp.status |= cosine_context.status & 0x3f;
            pending(fp);
        }
    }
    fp.status &= ~@as(u16, 0x400);
    put(fp, top(fp.*), sine);
    setTop(fp, destination);
    put(fp, destination, cosine);
}
fn trigonometric(fp: *Fp, cosine: bool) void {
    var flags: u16 = 0;
    const raw = stack(fp.*, 0, &flags);
    fp.status &= ~@as(u16, 0x200);
    var result: u80 = undefined;
    if (flags & 64 != 0 or unsupported(raw) or nan(raw)) {
        result = arithmetic(fp, raw, 0, .add, flags) orelse return;
    } else if (exponent(raw) == 0x7fff) {
        if (raise(fp, 1)) return;
        result = indefinite;
    } else if (raw & ~sign >= 0x403e8000000000000000) {
        fp.status |= 0x400;
        return;
    } else {
        if (raise(fp, if (denormal(raw)) 2 else 0)) return;
        var context = fp.*;
        // FSIN/FCOS list no #U; FSINCOS retains ordinary underflow behavior.
        context.control |= 16;
        result = trigonometricResult(&context, raw, cosine);
        fp.status = (context.status & ~@as(u16, 16)) | (fp.status & 16);
        pending(fp);
    }
    fp.status &= ~@as(u16, 0x400);
    put(fp, top(fp.*), result);
}
fn log2Extended(raw: u80) f128 {
    const input = finite(raw);
    var mantissa = @as(f128, @floatFromInt(@as(u64, @intCast(input.significand)))) * 0x1p-63;
    var power = input.scale + 63;
    // Center around one, so adjacent inputs on either side do not cancel.
    if (mantissa >= 1.5) {
        mantissa *= 0.5;
        power += 1;
    }
    const z = (mantissa - 1) / (mantissa + 1);
    // Zig 0.16's compiler-rt log2q narrows to f64. Keep our extended inputs.
    return @as(f128, @floatFromInt(power)) + 2 * z * seriesRatio(z * z) / std.math.ln2;
}
fn logarithm(fp: *Fp, plus_one: bool) void {
    var flags: u16 = 0;
    const x = stack(fp.*, 0, &flags);
    const y = stack(fp.*, 1, &flags);
    fp.status &= ~@as(u16, 0x200);
    var result: u80 = undefined;
    if (flags & 64 != 0 or unsupported(x) or unsupported(y) or nan(x) or nan(y)) {
        result = arithmetic(fp, x, y, .add, flags) orelse return;
    } else if (plus_one) {
        const yi = exponent(y) == 0x7fff;
        const xz = @as(u64, @truncate(x)) == 0;
        const signed = (x ^ y) & sign;
        // Largest extended argument inside +/- (1 - sqrt(2)/2).
        // Outside the defined domain our profile retains ST(1) and still pops.
        if (x & ~sign > 0x3ffd95f619980c4336f7) result = y else if (xz and yi) {
            if (raise(fp, 1)) return;
            result = indefinite;
        } else {
            if (raise(fp, if (denormal(x) or denormal(y)) 2 else 0)) return;
            if (yi) result = signed | (@as(u80, 0x7fff) << 64) | integer else if (xz or @as(u64, @truncate(y)) == 0) result = signed else {
                const a = finite(x);
                const b = finite(y);
                const divisor = 2 + floating(x);
                const z = floating(x) / divisor;
                const coefficient = (2 / divisor) * seriesRatio(z * z) / std.math.ln2;
                // Normalize both factors: even two minimum denormals retain
                // full guard bits until gradual or exponent-biased rounding.
                const approximation = @as(f128, @floatFromInt(@as(u64, @intCast(a.significand)))) * @as(f128, @floatFromInt(@as(u64, @intCast(b.significand)))) * coefficient;
                result = roundTranscendental(fp, if (signed != 0) -approximation else approximation, a.scale + b.scale, true);
            }
        }
    } else {
        const xi = exponent(x) == 0x7fff;
        const yi = exponent(y) == 0x7fff;
        const xz = @as(u64, @truncate(x)) == 0;
        const yz = @as(u64, @truncate(y)) == 0;
        const one = x == (@as(u80, 0x3fff) << 64) | integer;
        const negative = (y & sign != 0) != (xz or x < (@as(u80, 0x3fff) << 64) | integer);
        const signed: u80 = if (negative) sign else 0;
        if (x & sign != 0 and !xz or (xz or xi) and yz or one and yi) {
            if (raise(fp, 1)) return;
            result = indefinite;
        } else if (xz) {
            // Table 3-50 does not mark a zero-divide for infinite ST(1).
            if (raise(fp, if (yi) 0 else 4)) return;
            result = signed | (@as(u80, 0x7fff) << 64) | integer;
        } else {
            if (raise(fp, if (denormal(x) or denormal(y)) 2 else 0)) return;
            if (xi or yi) result = signed | (@as(u80, 0x7fff) << 64) | integer else if (one or yz) result = signed else {
                const multiplier = finite(y);
                const approximation = log2Extended(x) * @as(f128, @floatFromInt(@as(u64, @intCast(multiplier.significand))));
                result = roundTranscendental(fp, if (y & sign != 0) -approximation else approximation, multiplier.scale, finite(x).significand != integer);
            }
        }
    }
    put(fp, physical(fp.*, 1), result);
    pop(fp);
}
fn arctangent(fp: *Fp) void {
    var flags: u16 = 0;
    const x = stack(fp.*, 0, &flags);
    const y = stack(fp.*, 1, &flags);
    fp.status &= ~@as(u16, 0x200);
    var result: u80 = undefined;
    if (flags & 64 != 0 or unsupported(x) or unsupported(y) or nan(x) or nan(y)) {
        result = arithmetic(fp, x, y, .add, flags) orelse return;
    } else {
        if (raise(fp, if (denormal(x) or denormal(y)) 2 else 0)) return;
        const xi = exponent(x) == 0x7fff;
        const yi = exponent(y) == 0x7fff;
        const xz = @as(u64, @truncate(x)) == 0;
        const yz = @as(u64, @truncate(y)) == 0;
        const negative = y & sign != 0;
        var angle: f128 = undefined;
        if (xi and yi) angle = std.math.pi * (if (x & sign != 0) @as(f128, 0.75) else 0.25) else if (yz or xi) {
            angle = if (x & sign != 0) std.math.pi else 0;
        } else if (yi or xz) angle = std.math.pi / 2.0 else {
            const a = finite(x);
            const b = finite(y);
            const shift = b.scale - a.scale;
            if (x & sign == 0 and shift <= -32) {
                // atan(r)/r near zero, in normalized fixed point. This also
                // keeps ratios below binary128's exponent range and the tiny
                // negative correction when r itself is exactly representable.
                const numerator = b.significand << 192;
                result = tinyOdd(fp, numerator / a.significand, shift, negative, .{ -1, 1, -1 }, .{ 3, 5, 7 }, numerator % a.significand != 0);
                put(fp, physical(fp.*, 1), result);
                pop(fp);
                return;
            }
            const swap = x & ~sign < y & ~sign;
            const ratio = if (swap) @abs(floating(x) / floating(y)) else @abs(floating(y) / floating(x));
            const reduce = ratio > 0.5;
            const z = if (reduce) (ratio - 1) / (ratio + 1) else ratio;
            angle = z * seriesRatio(-z * z) + (if (reduce) @as(f128, std.math.pi / 4.0) else 0);
            if (swap) angle = std.math.pi / 2.0 - angle;
            if (x & sign != 0) angle = std.math.pi - angle;
        }
        result = if (angle == 0) y & sign else roundTranscendental(fp, if (negative) -angle else angle, 0, true);
    }
    put(fp, physical(fp.*, 1), result);
    pop(fp);
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
fn scalePower(fp: *Fp) void {
    var flags: u16 = 0;
    const a = stack(fp.*, 0, &flags);
    const b = stack(fp.*, 1, &flags);
    fp.status &= ~@as(u16, 0x200);
    if (flags & 64 != 0 or unsupported(a) or unsupported(b) or nan(a) or nan(b)) {
        if (arithmetic(fp, a, b, .add, flags)) |result| put(fp, top(fp.*), result);
        return;
    }
    const ai = exponent(a) == 0x7fff;
    const bi = exponent(b) == 0x7fff;
    const az = @as(u64, @truncate(a)) == 0;
    if (bi and (ai and b & sign != 0 or az and b & sign == 0)) {
        if (!raise(fp, 1)) put(fp, top(fp.*), indefinite);
        return;
    }
    if (denormal(a) or denormal(b)) flags |= 2;
    if (raise(fp, flags)) return;
    if (ai or az) return;
    if (bi) {
        put(fp, top(fp.*), (a & sign) | (if (b & sign != 0) @as(u80, 0) else (@as(u80, 0x7fff) << 64) | integer));
        return;
    }
    const input = finite(a);
    // Beyond +/-65536 every finite operand reaches the same massive O/U
    // case even after bias adjustment; avoid casting an unbounded exponent.
    const adjustment: i32 = @intFromFloat(std.math.clamp(floating(b), -65536, 65536));
    var context = fp.*;
    context.control |= 0x300; // FSCALE ignores precision control, but honors RC.
    const result = roundArithmetic(&context, input.significand, input.scale + adjustment, a & sign != 0);
    fp.status = context.status;
    put(fp, top(fp.*), result);
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
    if (code == 0xd9f0) {
        if (exponential(fp, a, flags)) |result| put(fp, top(fp.*), result);
        return;
    }
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
            s.flags.auxiliary = false;
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
    const no_wait = code == 0xdbe2 or code == 0xdbe3 or code == 0xdfe0 or byte < 0xc0 and group >= 6 and (op == 0xd9 or op == 0xdd);
    if (!no_wait) try s.x86_fp.checkPending();
    var fp = s.x86_fp;
    const legacy_env = byte < 0xc0 and (op == 0xd9 or op == 0xdd) and (group == 4 or group == 6);
    const control = no_wait or legacy_env or byte < 0xc0 and op == 0xd9 and group == 5;
    const memory = byte < 0xc0;
    const addr = if (memory) operands.address(s, i.src.mem, i.next) else 0;
    const calculating = (op == 0xd8 or op == 0xda or op == 0xdc or op == 0xde) or code == 0xd9e4 or code == 0xd9f0 or code == 0xd9fa or code == 0xd9fc or !memory and (op == 0xdd and byte >= 0xe0 or (op == 0xdb or op == 0xdf) and byte >= 0xe8);
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
    } else if (legacy_env) {
        try environment(&fp, m, i, addr);
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
            0xd9f1, 0xd9f9 => logarithm(&fp, code == 0xd9f9),
            0xd9f3 => arctangent(&fp),
            0xd9f2, 0xd9fb => trigonometricPair(&fp, code == 0xd9f2),
            0xd9fe, 0xd9ff => trigonometric(&fp, code == 0xd9ff),
            0xd9f4 => extract(&fp),
            0xd9f5, 0xd9f8 => partialRemainder(&fp, code == 0xd9f5),
            0xd9fd => scalePower(&fp),
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
            0xdf => if (group == 4 or group == 6) 80 else if (group == 5 or group == 7) 64 else 16,
            else => unreachable,
        };
        const load = group == 0 or group == 5 or op == 0xdf and group == 4;
        try m.check(addr, width / 8, if (load) .read else .write);
        if (load) {
            var flags: u16 = 0;
            const raw = if (width == 80) blk: {
                var bytes: [10]u8 = undefined;
                try m.read(addr, &bytes, .read);
                const bits = std.mem.readInt(u80, &bytes, .little);
                break :blk if (op == 0xdf) loadBcd(bits) else bits;
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
                const result = if (op == 0xdf) storeBcd(&fp, raw, &flags) else raw;
                _ = raise(&fp, flags);
                if (flags & ~fp.control & 1 == 0) {
                    var bytes: [10]u8 = undefined;
                    std.mem.writeInt(u80, &bytes, result, .little);
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

test "Packed BCD transfers retain signs, round decimal boundaries and defer faults" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.map(0x2000, 4096, .{ .read = true, .write = true });
    const maximum: u80 = 0x999999999999999999;
    const invalid: u80 = 0xffffc000000000000000;
    try m.initialize(0x1000, &.{ 0xdf, 0x27 });
    for (0..8) |slot| {
        for (0..16) |controls| {
            for ([_]struct { bits: u80, result: u80 }{
                .{ .bits = 0, .result = 0 },
                .{ .bits = sign, .result = sign },
                .{ .bits = @as(u80, 0x7f) << 72, .result = 0 },
                .{ .bits = @as(u80, 0xff) << 72, .result = sign },
                .{ .bits = 1, .result = extended(1) },
                .{ .bits = maximum, .result = extended(999999999999999999) },
                .{ .bits = sign | maximum, .result = sign | extended(999999999999999999) },
                .{ .bits = 0x123456789012345678, .result = extended(123456789012345678) },
            }) |case| {
                var s = State{ .architecture = .x86_64 };
                s.set(7, 0x2201);
                s.x86_fp.control = 0x7f | (@as(u16, @intCast(controls)) << 8);
                s.x86_fp.status = 0x4700;
                setTop(&s.x86_fp, @intCast(slot));
                put(&s.x86_fp, @intCast((slot + 3) & 7), extended(42));
                var bytes: [10]u8 = undefined;
                std.mem.writeInt(u80, &bytes, case.bits, .little);
                try m.write(0x2201, &bytes);
                const before = s;
                _ = try run(&s, &m, try decode(&m, 0x1000));
                const destination: u3 = @as(u3, @intCast(slot)) -% 1;
                try std.testing.expectEqual(case.result, get(s.x86_fp, destination));
                try std.testing.expectEqual(@as(u16, 0x4500) | (@as(u16, destination) << 11), s.x86_fp.status);
                try std.testing.expectEqual(before.x86_fp.tag | (@as(u8, 1) << destination), s.x86_fp.tag);
                try std.testing.expectEqual(before.x86_fp.control, s.x86_fp.control);
                try std.testing.expectEqual(before.x86_fp.mxcsr, s.x86_fp.mxcsr);
                try std.testing.expectEqual(before.flags, s.flags);
            }
        }
    }
    // Malformed digits have undefined numeric results; FBLD has no #IA check.
    for ([_]u80{ 0xa, 0xf, 0xa << 68, 0xffffc000000000000000 }) |bits| {
        var s = State{ .architecture = .x86_64 };
        s.set(7, 0x2201);
        s.x86_fp.control = 0x37e;
        var bytes: [10]u8 = undefined;
        std.mem.writeInt(u80, &bytes, bits, .little);
        try m.write(0x2201, &bytes);
        _ = try run(&s, &m, try decode(&m, 0x1000));
        try std.testing.expectEqual(@as(u16, 0x3800), s.x86_fp.status);
        try std.testing.expectEqual(@as(u8, 0x80), s.x86_fp.tag);
    }
    try m.initialize(0x1000, &.{ 0xdf, 0x37, 0x9b });
    for ([_]struct { raw: u80, result: u80, flags: u16 = 0, control: u16 = 0x37f, commit: bool = true }{
        .{ .raw = 0, .result = 0 },
        .{ .raw = sign, .result = sign },
        .{ .raw = extended(999999999999999999), .result = maximum },
        .{ .raw = sign | extended(999999999999999999), .result = sign | maximum },
        .{ .raw = extended(2.5), .result = 2, .flags = 32 },
        .{ .raw = extended(2.5), .result = 3, .flags = 0x220, .control = 0xb7f },
        .{ .raw = extended(-2.5), .result = sign | 3, .flags = 0x220, .control = 0x77f },
        .{ .raw = extended(-2.5), .result = sign | 2, .flags = 32, .control = 0xb7f },
        .{ .raw = 1, .result = 0, .flags = 32 },
        .{ .raw = sign | 1, .result = sign, .flags = 32 },
        .{ .raw = 1, .result = 0, .flags = 32, .control = 0x37d },
        .{ .raw = extended(2.5), .result = 2, .flags = 0x80a0, .control = 0x35f },
        .{ .raw = extended(999999999999999999.5), .result = invalid, .flags = 1 },
        .{ .raw = extended(999999999999999999.5), .result = maximum, .flags = 32, .control = 0xf7f },
        .{ .raw = extended(1000000000000000000), .result = invalid, .flags = 1 },
        .{ .raw = extended(1000000000000000000), .result = invalid, .flags = 0x8081, .control = 0x37e, .commit = false },
        .{ .raw = (@as(u80, 0x7fff) << 64) | integer, .result = invalid, .flags = 1 },
        .{ .raw = (@as(u80, 0x3fff) << 64) | 3, .result = invalid, .flags = 1 },
        .{ .raw = indefinite, .result = invalid, .flags = 1 },
        .{ .raw = (@as(u80, 0x7fff) << 64) | integer | 3, .result = invalid, .flags = 1 },
        .{ .raw = (@as(u80, 0x7ffe) << 64) | std.math.maxInt(u64), .result = invalid, .flags = 1 },
        .{ .raw = extended(-0.5), .result = sign, .flags = 32 },
    }) |case| {
        for (0..8) |slot| {
            for (0..4) |precision| {
                var s = State{ .architecture = .x86_64 };
                s.set(7, 0x2201);
                s.flags = .{ .carry = true, .overflow = true, .direction = true };
                s.x86_fp.control = (case.control & ~@as(u16, 0x300)) | (@as(u16, @intCast(precision)) << 8);
                s.x86_fp.status = 0x4700;
                s.x86_fp.mxcsr = 0xff7f;
                setTop(&s.x86_fp, @intCast(slot));
                put(&s.x86_fp, @intCast(slot), case.raw);
                put(&s.x86_fp, @intCast((slot + 3) & 7), extended(42));
                const original = s;
                try m.write(0x2200, &@as([12]u8, @splat(0xa5)));
                _ = try run(&s, &m, try decode(&m, 0x1000));
                var bytes: [12]u8 = undefined;
                try m.read(0x2200, &bytes, .read);
                try std.testing.expectEqual(@as(u8, 0xa5), bytes[0]);
                try std.testing.expectEqual(@as(u8, 0xa5), bytes[11]);
                try std.testing.expectEqual(if (case.commit) case.result else @as(u80, 0xa5a5a5a5a5a5a5a5a5a5), std.mem.readInt(u80, bytes[1..11], .little));
                const next_top = (slot + @as(usize, @intFromBool(case.commit))) & 7;
                try std.testing.expectEqual(@as(u16, 0x4500) | (@as(u16, @intCast(next_top)) << 11) | case.flags, s.x86_fp.status);
                try std.testing.expectEqual(if (case.commit) original.x86_fp.tag & ~(@as(u8, 1) << @intCast(slot)) else original.x86_fp.tag, s.x86_fp.tag);
                try std.testing.expectEqual(original.x86_fp.registers, s.x86_fp.registers);
                try std.testing.expectEqual(original.x86_fp.control, s.x86_fp.control);
                try std.testing.expectEqual(original.x86_fp.mxcsr, s.x86_fp.mxcsr);
                try std.testing.expectEqual(original.flags, s.flags);
                if (case.flags & 0x8080 != 0) {
                    const pending_state = s;
                    try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, 0x1002)));
                    try std.testing.expectEqual(pending_state, s);
                }
            }
        }
    }
    // Empty stores and full-stack loads follow the ordinary x87 stack rules.
    for ([_]u8{ 0x27, 0x37 }) |byte| {
        for ([_]u16{ 0x37f, 0x37e }) |control| {
            for (0..8) |slot| {
                var s = State{ .architecture = .x86_64 };
                s.set(7, 0x2201);
                s.x86_fp.control = control;
                s.x86_fp.tag = if (byte == 0x27) 0xff else 0;
                setTop(&s.x86_fp, @intCast(slot));
                try m.initialize(0x1000, &.{ 0xdf, byte });
                try m.write(0x2201, &@as([10]u8, @splat(0)));
                const before = s;
                _ = try run(&s, &m, try decode(&m, 0x1000));
                const committed = control & 1 != 0;
                const position: u3 = if (!committed) @intCast(slot) else if (byte == 0x27) @as(u3, @intCast(slot)) -% 1 else @as(u3, @intCast(slot)) +% 1;
                try std.testing.expectEqual(position, top(s.x86_fp));
                try std.testing.expectEqual(@as(u16, 0x41) | (if (byte == 0x27) @as(u16, 0x200) else 0) | (@as(u16, position) << 11) | (if (!committed) @as(u16, 0x8080) else 0), s.x86_fp.status);
                if (!committed) try std.testing.expectEqual(before.x86_fp.registers, s.x86_fp.registers);
            }
        }
    }
}

test "Packed BCD memory faults preserve state and exactly ten-byte operands" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.map(0x2000, 4096, .{ .read = true, .write = true });
    try m.map(0x3000, 4096, .{ .read = true });
    try m.map(0x4000, 4096, .{ .write = true });
    try m.map(0x5000, 4096, .{ .read = true, .write = true });
    for ([_]u8{ 0x27, 0x37 }) |byte| {
        var s = State{ .architecture = .x86_64 };
        put(&s.x86_fp, 0, extended(3));
        try m.initialize(0x1000, &.{ 0xdf, byte });
        try m.initialize(0x3000, &.{0xa5});
        s.set(7, 0x2ff6);
        _ = try run(&s, &m, try decode(&m, 0x1000));
        try std.testing.expectEqual(@as(u64, 0xa5), try m.readInt(0x3000, 8, .read));
        for ([_]u64{ if (byte == 0x27) 0x4ff7 else 0x2ff7, 0x5ff7 }) |addr| {
            s.set(7, addr);
            const before = s;
            const writes = m.writes;
            try std.testing.expectError(if (addr == 0x5ff7) error.UnmappedMemory else error.PermissionDenied, run(&s, &m, try decode(&m, 0x1000)));
            try std.testing.expectEqual(before, s);
            try std.testing.expectEqual(writes, m.writes);
        }
    }
    var page: [4096]u8 = @splat(0xa5);
    try m.borrow(0x6000, &page, .{ .read = true, .write = true }, true, null);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = m.allocator;
    m.allocator = failing.allocator();
    defer m.allocator = allocator;
    var s = State{ .architecture = .x86_64 };
    s.set(7, 0x6001);
    s.x86_fp.control = 0x35f;
    put(&s.x86_fp, 0, extended(2.5));
    const before = s;
    try m.initialize(0x1000, &.{ 0xdf, 0x37 });
    const writes = m.writes;
    try std.testing.expectError(error.OutOfMemory, run(&s, &m, try decode(&m, 0x1000)));
    try std.testing.expectEqual(before, s);
    try std.testing.expectEqual(writes, m.writes);
    try std.testing.expectEqualSlices(u8, &@as([4096]u8, @splat(0xa5)), &page);
}

test "Legacy x87 images preserve physical tags, logical stack order and deferred state" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.map(0x2000, 4096, .{ .read = true, .write = true });
    const values = [_]u80{ extended(3), sign, 0, 1, (@as(u80, 0x7fff) << 64) | integer, indefinite, (@as(u80, 0x3fff) << 64) | 1, extended(-7) };
    for ([_]bool{ false, true }) |short| {
        for ([_]bool{ false, true }) |full| {
            for (0..8) |slot| {
                var s = State{ .architecture = .x86_64 };
                s.set(7, 0x2201);
                s.flags = .{ .carry = true, .direction = true, .overflow = true };
                s.vectors[0] = @splat(0xab);
                s.x86_fp = .{ .control = 0xb7e, .status = 0xc781, .tag = 0x7f, .opcode = 0x357, .instruction_pointer = 0xabcdef0123456789, .data_pointer = 0xfedcba9876543210, .code_selector = 0x33, .data_selector = 0x2b, .mxcsr = 0xff7f };
                setTop(&s.x86_fp, @intCast(slot));
                for (values, 0..) |raw, index| std.mem.writeInt(u80, &s.x86_fp.registers[index], raw, .little);
                const original = s;
                const header: usize = if (short) 14 else 28;
                const size = header + @as(usize, if (full) 80 else 0);
                var encoded = [_]u8{ if (short) 0x66 else 0x48, if (full) 0xdd else 0xd9, 0x37 };
                try m.write(0x2200, &@as([110]u8, @splat(0xa5)));
                try m.initialize(0x1000, &encoded);
                const save = try decode(&m, 0x1000);
                try std.testing.expectEqual(@as(u7, if (short) 16 else 32), save.width);
                _ = try run(&s, &m, save); // No-wait stores remain usable with pending IE.
                var image: [110]u8 = undefined;
                try m.read(0x2200, &image, .read);
                try std.testing.expectEqual(@as(u8, 0xa5), image[0]);
                try std.testing.expectEqual(@as(u8, 0xa5), image[size + 1]);
                const bytes = image[1..];
                const step: usize = if (short) 2 else 4;
                try std.testing.expectEqual(original.x86_fp.control, std.mem.readInt(u16, bytes[0..2], .little));
                try std.testing.expectEqual(original.x86_fp.status, std.mem.readInt(u16, bytes[step..][0..2], .little));
                try std.testing.expectEqual(@as(u16, 0xea94), std.mem.readInt(u16, bytes[step * 2 ..][0..2], .little));
                if (full) for (0..8) |logical| {
                    try std.testing.expectEqualSlices(u8, &original.x86_fp.registers[(slot + logical) & 7], bytes[header + logical * 10 ..][0..10]);
                };
                var saved = original.x86_fp;
                if (full) saved = .{ .registers = saved.registers, .mxcsr = saved.mxcsr } else {
                    saved.control |= 0x3f;
                    saved.status &= ~@as(u16, 0x8080);
                }
                try std.testing.expectEqual(saved, s.x86_fp);
                try std.testing.expectEqual(original.vectors, s.vectors);
                try std.testing.expectEqual(original.flags, s.flags);
                s.x86_fp.registers = @splat(@splat(0xcc));
                s.x86_fp.opcode = 0x155;
                const retained = s.x86_fp.registers;
                encoded[2] = 0x27;
                try m.initialize(0x1000, &encoded);
                _ = try run(&s, &m, try decode(&m, 0x1000));
                var restored = original.x86_fp;
                restored.instruction_pointer &= if (short) @as(u64, 0xffff) else 0xffffffff;
                restored.data_pointer &= if (short) @as(u64, 0xffff) else 0xffffffff;
                if (short) restored.opcode = 0x155;
                if (!full) restored.registers = retained;
                try std.testing.expectEqual(restored, s.x86_fp);
                try m.initialize(0x1000, &.{0x9b});
                const pending_state = s;
                try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, 0x1000)));
                try std.testing.expectEqual(pending_state, s);
            }
        }
    }
}

test "Legacy x87 image faults preserve state and bytes, and waiting forms check first" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.map(0x2000, 4096, .{ .read = true, .write = true });
    try m.map(0x3000, 4096, .{ .read = true });
    try m.map(0x5000, 4096, .{ .write = true });
    try m.map(0x6000, 4096, .{ .read = true, .write = true });
    for ([_]bool{ false, true }) |short| {
        for ([_]u8{ 0xd9, 0xdd }) |op| {
            for ([_]u8{ 0x27, 0x37 }) |byte| {
                const store = byte == 0x37;
                try m.initialize(0x1000, &.{ if (short) 0x66 else 0x48, op, byte });
                var s = State{ .architecture = .x86_64 };
                const size: u64 = @as(u64, if (short) 14 else 28) + @as(u64, if (op == 0xdd) 80 else 0);
                s.set(7, 0x3000 - size);
                try m.initialize(0x3000, &.{0xa5});
                _ = try run(&s, &m, try decode(&m, 0x1000));
                try std.testing.expectEqual(@as(u64, 0xa5), try m.readInt(0x3000, 8, .read));
                s.x86_fp = .{ .control = 0x37f, .status = 0x4701, .tag = 0xa5, .opcode = 0x357, .mxcsr = 0xff7f };
                put(&s.x86_fp, 0, extended(3));
                for ([_]u64{ if (store) 0x2ffd else 0x5ffd, 0x6ffd }) |addr| {
                    s.set(7, addr);
                    const original = s;
                    const writes = m.writes;
                    const expected = if (addr == 0x6ffd) error.UnmappedMemory else error.PermissionDenied;
                    try std.testing.expectError(expected, run(&s, &m, try decode(&m, 0x1000)));
                    try std.testing.expectEqual(original, s);
                    try std.testing.expectEqual(writes, m.writes);
                }
                s.x86_fp.control &= ~@as(u16, 1);
                s.set(7, 0x9000); // Pending exceptions precede bad operands on loads.
                const original = s;
                if (!store) try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, 0x1000)));
                try m.initialize(0x1000, &.{ 0x9b, op, byte });
                try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, 0x1000)));
                try std.testing.expectEqual(original, s);
            }
        }
    }
    // COW allocation failure cannot mask/reset the FPU or publish a partial image.
    var page: [4096]u8 = @splat(0xa5);
    try m.borrow(0x8000, &page, .{ .read = true, .write = true }, true, null);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = m.allocator;
    m.allocator = failing.allocator();
    defer m.allocator = allocator;
    for ([_]u8{ 0xd9, 0xdd }) |op| {
        var s = State{ .architecture = .x86_64 };
        s.set(7, 0x8001);
        s.x86_fp.control = 0x37e;
        s.x86_fp.status = 0x8081;
        const original = s;
        try m.initialize(0x1000, &.{ op, 0x37 });
        const writes = m.writes;
        try std.testing.expectError(error.OutOfMemory, run(&s, &m, try decode(&m, 0x1000)));
        try std.testing.expectEqual(original, s);
        try std.testing.expectEqual(writes, m.writes);
        try std.testing.expectEqualSlices(u8, &@as([4096]u8, @splat(0xa5)), &page);
    }
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

test "Popping x87 transcendentals retain quadrants, tiny results and stack faults" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0xd9, 0xf1, 0x9b });
    const infinity: u80 = 0x7fff8000000000000000;
    const maximum: u80 = 0x7ffeffffffffffffffff;
    const above: u80 = 0x3fc0b8aa3b295c17f0bb;
    const below: u80 = 0xbfbfb8aa3b295c17f0bc;
    const three: u80 = 0x3fffcae00d1cfdeb43cf;
    const tiny: u80 = 0x5f83b8aa3b295c17f0bb;
    const large: u80 = 0x200cfffbffffffffffff;
    const qnan = infinity | quiet | 17;
    for ([_]struct { x: u80, y: u80, results: [4]u80, flags: [4]u16 = @splat(0), unmask: u16 = 0, biased: [4]u80 = @splat(0), post_flags: [4]u16 = @splat(0), tag: u2 = 3, opcode: u8 = 0xf1 }{
        .{ .x = extended(8), .y = extended(3), .results = @splat(extended(9)) },
        .{ .x = extended(0.5), .y = extended(-7), .results = @splat(extended(7)) },
        .{ .x = extended(1), .y = extended(-7), .results = @splat(sign) },
        .{ .x = extended(0.5), .y = 0, .results = @splat(sign) },
        .{ .x = extended(0.5), .y = sign, .results = @splat(0) },
        .{ .x = extended(1 + 0x1p-63), .y = extended(1), .results = .{ above, above, above + 1, above }, .flags = .{ 32, 32, 0x220, 32 } },
        .{ .x = 0x3ffeffffffffffffffff, .y = extended(1), .results = .{ below, below + 1, below, below }, .flags = .{ 32, 0x220, 32, 32 } },
        .{ .x = extended(3), .y = extended(1), .results = .{ three + 1, three, three + 1, three }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .x = extended(2), .y = 1, .results = @splat(1), .flags = @splat(2), .unmask = 16, .biased = @splat(0x5fc28000000000000000), .post_flags = @splat(18) },
        .{ .x = extended(1 + 0x1p-63), .y = 1, .results = .{ 0, 0, 1, 0 }, .flags = .{ 0x32, 0x32, 0x232, 0x32 }, .unmask = 16, .biased = .{ tiny, tiny, tiny + 1, tiny }, .post_flags = .{ 0x32, 0x32, 0x232, 0x32 } },
        .{ .x = 0x7ffe8000000000000000, .y = maximum, .results = .{ infinity, maximum, infinity, maximum }, .flags = .{ 0x228, 40, 0x228, 40 }, .unmask = 8, .biased = .{ large, large, large + 1, large }, .post_flags = .{ 40, 40, 0x228, 40 } },
        .{ .x = 1, .y = extended(-2), .results = @splat(extended(32890)), .flags = @splat(2) },
        .{ .x = 0, .y = extended(2), .results = @splat(sign | infinity), .flags = @splat(4) },
        .{ .x = sign, .y = extended(-2), .results = @splat(infinity), .flags = @splat(4) },
        .{ .x = 0, .y = 1, .results = @splat(sign | infinity), .flags = @splat(4) },
        .{ .x = sign, .y = sign | infinity, .results = @splat(infinity) },
        .{ .x = extended(-1), .y = 1, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .x = sign | infinity, .y = extended(2), .results = @splat(indefinite), .flags = @splat(1) },
        .{ .x = infinity, .y = 0, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .x = extended(1), .y = infinity, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .x = 0, .y = 0, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .x = extended(0.5), .y = sign | infinity, .results = @splat(infinity) },
        .{ .x = infinity, .y = 1, .results = @splat(infinity), .flags = @splat(2) },
        .{ .x = extended(-1), .y = qnan, .results = @splat(qnan) },
        .{ .x = qnan, .y = infinity | 7, .results = @splat(qnan), .flags = @splat(1) },
        .{ .x = @as(u80, 0x3fff) << 64, .y = qnan, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .x = extended(2), .y = extended(3), .results = @splat(indefinite), .flags = @splat(0x41), .tag = 0 },
        .{ .x = extended(2), .y = extended(3), .results = @splat(indefinite), .flags = @splat(0x41), .tag = 1 },
        .{ .x = extended(2), .y = extended(3), .results = @splat(indefinite), .flags = @splat(0x41), .tag = 2 },
        .{ .opcode = 0xf9, .x = 0, .y = extended(-3), .results = @splat(sign) },
        .{ .opcode = 0xf9, .x = sign, .y = extended(-3), .results = @splat(0) },
        .{ .opcode = 0xf9, .x = extended(-0.25), .y = sign, .results = @splat(0) },
        .{ .opcode = 0xf9, .x = extended(0.25), .y = extended(1), .results = .{ 0x3ffda4d3c25e68dc57f2, 0x3ffda4d3c25e68dc57f2, 0x3ffda4d3c25e68dc57f3, 0x3ffda4d3c25e68dc57f2 }, .flags = .{ 32, 32, 0x220, 32 } },
        .{ .opcode = 0xf9, .x = extended(-0.25), .y = extended(1), .results = .{ 0xbffdd47fcb8c0852f0c1, 0xbffdd47fcb8c0852f0c1, 0xbffdd47fcb8c0852f0c0, 0xbffdd47fcb8c0852f0c0 }, .flags = .{ 0x220, 0x220, 32, 32 } },
        .{ .opcode = 0xf9, .x = 0x3ffd95f619980c4336f7, .y = extended(1), .results = .{ 0x3ffdbdbfb1693cc7e3e5, 0x3ffdbdbfb1693cc7e3e4, 0x3ffdbdbfb1693cc7e3e5, 0x3ffdbdbfb1693cc7e3e4 }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .opcode = 0xf9, .x = 0xbffd95f619980c4336f7, .y = extended(1), .results = .{ 0xbffdffffffffffffffff, 0xbffe8000000000000000, 0xbffdffffffffffffffff, 0xbffdffffffffffffffff }, .flags = .{ 32, 0x220, 32, 32 } },
        .{ .opcode = 0xf9, .x = 1, .y = 1, .results = .{ 0, 0, 1, 0 }, .flags = .{ 0x32, 0x32, 0x232, 0x32 }, .unmask = 16, .biased = .{ 0x1f85b8aa3b295c17f0bc, 0x1f85b8aa3b295c17f0bb, 0x1f85b8aa3b295c17f0bc, 0x1f85b8aa3b295c17f0bb }, .post_flags = .{ 0x232, 0x32, 0x232, 0x32 } },
        .{ .opcode = 0xf9, .x = 1, .y = maximum, .results = .{ 0x3fc2b8aa3b295c17f0bb, 0x3fc2b8aa3b295c17f0bb, 0x3fc2b8aa3b295c17f0bc, 0x3fc2b8aa3b295c17f0bb }, .flags = .{ 0x22, 0x22, 0x222, 0x22 } },
        .{ .opcode = 0xf9, .x = extended(0.25), .y = (@as(u80, 1) << 64) | integer, .results = .{ 0x2934f0979a3715fd, 0x2934f0979a3715fc, 0x2934f0979a3715fd, 0x2934f0979a3715fc }, .flags = .{ 0x230, 0x30, 0x230, 0x30 }, .unmask = 16, .biased = .{ 0x5fffa4d3c25e68dc57f2, 0x5fffa4d3c25e68dc57f2, 0x5fffa4d3c25e68dc57f3, 0x5fffa4d3c25e68dc57f2 }, .post_flags = .{ 0x30, 0x30, 0x230, 0x30 } },
        .{ .opcode = 0xf9, .x = 0, .y = infinity, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .opcode = 0xf9, .x = 1, .y = infinity, .results = @splat(infinity), .flags = @splat(2) },
        .{ .opcode = 0xf9, .x = sign | 1, .y = infinity, .results = @splat(sign | infinity), .flags = @splat(2) },
        .{ .opcode = 0xf9, .x = 0, .y = 1, .results = @splat(0), .flags = @splat(2) },
        .{ .opcode = 0xf9, .x = extended(-0.25), .y = qnan, .results = @splat(qnan) },
        .{ .opcode = 0xf9, .x = infinity | 7, .y = extended(1), .results = @splat(infinity | quiet | 7), .flags = @splat(1) },
        .{ .opcode = 0xf9, .x = @as(u80, 0x3fff) << 64, .y = qnan, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .opcode = 0xf9, .x = extended(0.25), .y = extended(3), .results = @splat(indefinite), .flags = @splat(0x41), .tag = 0 },
        .{ .opcode = 0xf9, .x = extended(0.25), .y = extended(3), .results = @splat(indefinite), .flags = @splat(0x41), .tag = 1 },
        .{ .opcode = 0xf9, .x = extended(0.25), .y = extended(3), .results = @splat(indefinite), .flags = @splat(0x41), .tag = 2 },
        .{ .opcode = 0xf3, .x = extended(1), .y = extended(1), .results = .{ 0x3ffec90fdaa22168c235, 0x3ffec90fdaa22168c234, 0x3ffec90fdaa22168c235, 0x3ffec90fdaa22168c234 }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .opcode = 0xf3, .x = extended(-1), .y = extended(1), .results = .{ 0x400096cbe3f9990e91a8, 0x400096cbe3f9990e91a7, 0x400096cbe3f9990e91a8, 0x400096cbe3f9990e91a7 }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .opcode = 0xf3, .x = extended(1), .y = extended(-1), .results = .{ 0xbffec90fdaa22168c235, 0xbffec90fdaa22168c235, 0xbffec90fdaa22168c234, 0xbffec90fdaa22168c234 }, .flags = .{ 0x220, 0x220, 32, 32 } },
        .{ .opcode = 0xf3, .x = sign, .y = 0, .results = .{ 0x4000c90fdaa22168c235, 0x4000c90fdaa22168c234, 0x4000c90fdaa22168c235, 0x4000c90fdaa22168c234 }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .opcode = 0xf3, .x = sign, .y = sign, .results = .{ 0xc000c90fdaa22168c235, 0xc000c90fdaa22168c235, 0xc000c90fdaa22168c234, 0xc000c90fdaa22168c234 }, .flags = .{ 0x220, 0x220, 32, 32 } },
        .{ .opcode = 0xf3, .x = 0, .y = sign, .results = @splat(sign) },
        .{ .opcode = 0xf3, .x = 0, .y = extended(1), .results = .{ 0x3fffc90fdaa22168c235, 0x3fffc90fdaa22168c234, 0x3fffc90fdaa22168c235, 0x3fffc90fdaa22168c234 }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .opcode = 0xf3, .x = infinity, .y = infinity, .results = .{ 0x3ffec90fdaa22168c235, 0x3ffec90fdaa22168c234, 0x3ffec90fdaa22168c235, 0x3ffec90fdaa22168c234 }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .opcode = 0xf3, .x = infinity, .y = extended(-1), .results = @splat(sign) },
        .{ .opcode = 0xf3, .x = extended(1), .y = 1, .results = .{ 1, 0, 1, 0 }, .flags = .{ 0x232, 0x32, 0x232, 0x32 }, .unmask = 16, .biased = .{ 0x5fc28000000000000000, 0x5fc1ffffffffffffffff, 0x5fc28000000000000000, 0x5fc1ffffffffffffffff }, .post_flags = .{ 0x232, 0x32, 0x232, 0x32 } },
        .{ .opcode = 0xf3, .x = extended(1), .y = (@as(u80, 1) << 64) | integer, .results = .{ 0x18000000000000000, 0x7fffffffffffffff, 0x18000000000000000, 0x7fffffffffffffff }, .flags = .{ 0x220, 0x30, 0x220, 0x30 }, .unmask = 16, .biased = .{ 0x18000000000000000, 0x6000ffffffffffffffff, 0x18000000000000000, 0x6000ffffffffffffffff }, .post_flags = .{ 0x220, 0x30, 0x220, 0x30 } },
        .{ .opcode = 0xf3, .x = maximum, .y = 1, .results = .{ 0, 0, 1, 0 }, .flags = .{ 0x32, 0x32, 0x232, 0x32 }, .unmask = 16, .biased = .{ 0x1fc28000000000000001, 0x1fc28000000000000000, 0x1fc28000000000000001, 0x1fc28000000000000000 }, .post_flags = .{ 0x232, 0x32, 0x232, 0x32 } },
        .{ .opcode = 0xf3, .x = extended(1), .y = 0x3fdf8000000000000000, .results = .{ 0x3fdf8000000000000000, 0x3fdeffffffffffffffff, 0x3fdf8000000000000000, 0x3fdeffffffffffffffff }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .opcode = 0xf3, .x = extended(1), .y = qnan, .results = @splat(qnan) },
        .{ .opcode = 0xf3, .x = infinity | 7, .y = extended(1), .results = @splat(infinity | quiet | 7), .flags = @splat(1) },
        .{ .opcode = 0xf3, .x = @as(u80, 0x3fff) << 64, .y = qnan, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .opcode = 0xf3, .x = extended(1), .y = extended(3), .results = @splat(indefinite), .flags = @splat(0x41), .tag = 0 },
        .{ .opcode = 0xf3, .x = extended(1), .y = extended(3), .results = @splat(indefinite), .flags = @splat(0x41), .tag = 1 },
        .{ .opcode = 0xf3, .x = extended(1), .y = extended(3), .results = @splat(indefinite), .flags = @splat(0x41), .tag = 2 },
    }) |case| {
        try m.initialize(0x1000, &.{ 0xd9, case.opcode, 0x9b });
        for (0..8) |slot| {
            for (0..4) |precision| {
                for (0..4) |mode| {
                    for ([_]u16{ 0, 1, 2, 4, 8, 16, 32, 63 }) |unmask| {
                        var s = State{ .architecture = .x86_64, .pc = 0x1000, .flags = .{ .carry = true, .direction = true } };
                        s.x86_fp.control = (0x7f | (@as(u16, @intCast(precision)) << 8) | (@as(u16, @intCast(mode)) << 10)) & ~unmask;
                        s.x86_fp.status = 0x4700;
                        setTop(&s.x86_fp, @intCast(slot));
                        const destination = physical(s.x86_fp, 1);
                        put(&s.x86_fp, @intCast(slot), case.x);
                        put(&s.x86_fp, destination, case.y);
                        if (case.tag & 1 == 0) s.x86_fp.tag &= ~(@as(u8, 1) << @intCast(slot));
                        if (case.tag & 2 == 0) s.x86_fp.tag &= ~(@as(u8, 1) << destination);
                        s.x86_fp.data_pointer = 0x123456;
                        s.x86_fp.data_selector = 0x789;
                        const before = s;
                        var flags = case.flags[mode];
                        const blocked = flags & unmask & 7 != 0;
                        if (blocked) flags = if (flags & 1 != 0) flags & 0x41 else if (flags & 4 != 0) 4 else 2 else if (unmask & case.unmask != 0) flags = case.post_flags[mode];
                        const result = if (blocked) case.y else if (unmask & case.unmask != 0) case.biased[mode] else case.results[mode];
                        const pending_exception = flags & unmask & 63 != 0;
                        _ = try run(&s, &m, try decode(&m, s.pc));
                        try std.testing.expectEqual(case.x, get(s.x86_fp, @intCast(slot)));
                        try std.testing.expectEqual(result, get(s.x86_fp, destination));
                        try std.testing.expectEqual(@as(u16, 0x4500) | (@as(u16, if (blocked) @as(u3, @intCast(slot)) else destination) << 11) | flags | (if (pending_exception) @as(u16, 0x8080) else 0), s.x86_fp.status);
                        const tags = (before.x86_fp.tag & ~(@as(u8, 1) << @intCast(slot))) | (@as(u8, 1) << destination);
                        try std.testing.expectEqual(if (blocked) before.x86_fp.tag else tags, s.x86_fp.tag);
                        try std.testing.expectEqual(before.x86_fp.control, s.x86_fp.control);
                        try std.testing.expectEqual(before.x86_fp.mxcsr, s.x86_fp.mxcsr);
                        try std.testing.expectEqual(before.x86_fp.data_pointer, s.x86_fp.data_pointer);
                        try std.testing.expectEqual(before.x86_fp.data_selector, s.x86_fp.data_selector);
                        try std.testing.expectEqual(before.flags, s.flags);
                        for (0..8) |index| {
                            if (blocked or index != destination) try std.testing.expectEqual(before.x86_fp.registers[index], s.x86_fp.registers[index]);
                        }
                        if (pending_exception) {
                            const pending_state = s;
                            try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, s.pc)));
                            try std.testing.expectEqual(pending_state, s);
                        }
                    }
                }
            }
        }
    }
    for ([_]u8{ 0xf1, 0xf9, 0xf3 }) |opcode| {
        try m.initialize(0x1000, &.{ 0xf0, 0xd9, opcode });
        try std.testing.expectError(error.InvalidLockPrefix, decode(&m, 0x1000));
    }
}

test "FSIN and FCOS reduce full-range angles and retain exception and C2 behavior" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    const one: u80 = 0x3fff8000000000000000;
    const previous: u80 = 0x3ffeffffffffffffffff;
    const infinity: u80 = 0x7fff8000000000000000;
    for ([_]struct { opcode: u8 = 0xfe, input: u80, results: [4]u80, flags: [4]u16 = @splat(0), empty: bool = false, range: bool = false }{
        .{ .input = 0, .results = @splat(0) },
        .{ .input = sign, .results = @splat(sign) },
        .{ .opcode = 0xff, .input = 0, .results = @splat(one) },
        .{ .opcode = 0xff, .input = sign, .results = @splat(one) },
        .{ .input = one, .results = .{ 0x3ffed76aa47848677021, 0x3ffed76aa47848677020, 0x3ffed76aa47848677021, 0x3ffed76aa47848677020 }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .opcode = 0xff, .input = one, .results = .{ 0x3ffe8a51407da8345c92, 0x3ffe8a51407da8345c91, 0x3ffe8a51407da8345c92, 0x3ffe8a51407da8345c91 }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .input = one | sign, .results = .{ 0xbffed76aa47848677021, 0xbffed76aa47848677021, 0xbffed76aa47848677020, 0xbffed76aa47848677020 }, .flags = .{ 0x220, 0x220, 32, 32 } },
        .{ .input = 0x403d8000000000000000, .results = .{ 0xbffeb3f2b9aaf80a3946, 0xbffeb3f2b9aaf80a3946, 0xbffeb3f2b9aaf80a3945, 0xbffeb3f2b9aaf80a3945 }, .flags = .{ 0x220, 0x220, 32, 32 } },
        .{ .opcode = 0xff, .input = 0x403d8000000000000000, .results = .{ 0xbffeb6158fc106383e05, 0xbffeb6158fc106383e06, 0xbffeb6158fc106383e05, 0xbffeb6158fc106383e05 }, .flags = .{ 32, 0x220, 32, 32 } },
        .{ .input = 0x403dffffffffffffffff, .results = .{ 0x3ffedf327e112abeef8f, 0x3ffedf327e112abeef8f, 0x3ffedf327e112abeef90, 0x3ffedf327e112abeef8f }, .flags = .{ 32, 32, 0x220, 32 } },
        .{ .opcode = 0xff, .input = 0x403dffffffffffffffff, .results = .{ 0x3ffdfac035ec484929c2, 0x3ffdfac035ec484929c1, 0x3ffdfac035ec484929c2, 0x3ffdfac035ec484929c1 }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .input = 1, .results = .{ 1, 0, 1, 0 }, .flags = .{ 0x222, 34, 0x222, 34 } },
        .{ .opcode = 0xff, .input = 1, .results = .{ one, previous, one, previous }, .flags = .{ 0x222, 34, 0x222, 34 } },
        .{ .input = 0x18000000000000000, .results = .{ 0x18000000000000000, 0x7fffffffffffffff, 0x18000000000000000, 0x7fffffffffffffff }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .input = 0x3fe08000000000000000, .results = .{ 0x3fdfffffffffffffffff, 0x3fdfffffffffffffffff, 0x3fe08000000000000000, 0x3fdfffffffffffffffff }, .flags = .{ 32, 32, 0x220, 32 } },
        .{ .opcode = 0xff, .input = 0x3fe08000000000000000, .results = .{ previous - 1, previous - 1, previous, previous - 1 }, .flags = .{ 32, 32, 0x220, 32 } },
        .{ .input = 0x3fef8000000000000000, .results = .{ 0x3feeffffffffd5555555, 0x3feeffffffffd5555555, 0x3feeffffffffd5555556, 0x3feeffffffffd5555555 }, .flags = .{ 32, 32, 0x220, 32 } },
        .{ .opcode = 0xff, .input = 0x3fef8000000000000000, .results = .{ 0x3ffeffffffff80000000, 0x3ffeffffffff80000000, 0x3ffeffffffff80000001, 0x3ffeffffffff80000000 }, .flags = .{ 32, 32, 0x220, 32 } },
        .{ .input = 0x3fffc90fdaa22168c235, .results = .{ one, previous, one, previous }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .opcode = 0xff, .input = 0x3fffc90fdaa22168c235, .results = .{ 0xbfbdece675d1fc8f8cbb, 0xbfbdece675d1fc8f8cbc, 0xbfbdece675d1fc8f8cbb, 0xbfbdece675d1fc8f8cbb }, .flags = .{ 32, 0x220, 32, 32 } },
        .{ .opcode = 0xff, .input = 0x4000c90fdaa22168c235, .results = .{ sign | one, sign | one, sign | previous, sign | previous }, .flags = .{ 0x220, 0x220, 32, 32 } },
        .{ .input = infinity, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .opcode = 0xff, .input = infinity | sign, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .input = infinity | quiet | 17, .results = @splat(infinity | quiet | 17) },
        .{ .opcode = 0xff, .input = infinity | 17, .results = @splat(infinity | quiet | 17), .flags = @splat(1) },
        .{ .input = 0x3fff0000000000000000, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .input = one, .results = @splat(indefinite), .flags = @splat(65), .empty = true },
        .{ .opcode = 0xff, .input = one, .results = @splat(indefinite), .flags = @splat(65), .empty = true },
        .{ .input = 0x403e8000000000000000, .results = @splat(0), .range = true },
        .{ .opcode = 0xff, .input = 0xc03e8000000000000000, .results = @splat(0), .range = true },
        .{ .opcode = 0xff, .input = 0x7ffeffffffffffffffff, .results = @splat(0), .range = true },
    }) |case| {
        try m.initialize(0x1000, &.{ 0xd9, case.opcode, 0x9b });
        for (0..8) |slot| {
            for (0..4) |precision| {
                for (0..4) |mode| {
                    for ([_]u16{ 0, 1, 2, 16, 32, 63 }) |unmask| {
                        for ([_]u16{ 0, 0x400 }) |c2| {
                            var s = State{ .architecture = .x86_64, .pc = 0x1000, .flags = .{ .carry = true, .direction = true } };
                            s.x86_fp.control = (0x7f | (@as(u16, @intCast(precision)) << 8) | (@as(u16, @intCast(mode)) << 10)) & ~unmask;
                            s.x86_fp.status = 0x4300 | c2;
                            setTop(&s.x86_fp, @intCast(slot));
                            put(&s.x86_fp, @intCast(slot), case.input);
                            if (case.empty) s.x86_fp.tag = 0;
                            s.x86_fp.data_pointer = 0x123456;
                            const before = s;
                            var flags = case.flags[mode];
                            const blocked = flags & unmask & 3 != 0;
                            if (blocked) flags = if (flags & 1 != 0) flags & 65 else 2;
                            _ = try run(&s, &m, try decode(&m, s.pc));
                            const pending_exception = flags & unmask & 63 != 0;
                            const result = if (blocked or case.range) case.input else case.results[mode];
                            const condition = if (case.range) @as(u16, 0x400) else if (blocked) c2 else 0;
                            try std.testing.expectEqual(result, get(s.x86_fp, @intCast(slot)));
                            try std.testing.expectEqual(@as(u16, 0x4100) | (@as(u16, @intCast(slot)) << 11) | condition | flags | (if (pending_exception) @as(u16, 0x8080) else 0), s.x86_fp.status);
                            try std.testing.expectEqual(if (blocked or case.range) before.x86_fp.tag else before.x86_fp.tag | (@as(u8, 1) << @intCast(slot)), s.x86_fp.tag);
                            try std.testing.expectEqual(before.x86_fp.control, s.x86_fp.control);
                            try std.testing.expectEqual(before.x86_fp.mxcsr, s.x86_fp.mxcsr);
                            try std.testing.expectEqual(before.x86_fp.data_pointer, s.x86_fp.data_pointer);
                            try std.testing.expectEqual(before.flags, s.flags);
                            for (0..8) |index| {
                                if (blocked or case.range or index != slot) try std.testing.expectEqual(before.x86_fp.registers[index], s.x86_fp.registers[index]);
                            }
                            if (pending_exception) {
                                const pending_state = s;
                                try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, s.pc)));
                                try std.testing.expectEqual(pending_state, s);
                            }
                        }
                    }
                }
            }
        }
    }
    for ([_]u8{ 0xfe, 0xff }) |opcode| {
        try m.initialize(0x1000, &.{ 0xf0, 0xd9, opcode });
        try std.testing.expectError(error.InvalidLockPrefix, decode(&m, 0x1000));
    }
}

test "FSINCOS and FPTAN commit both results and stage stack and numerical faults" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    const one: u80 = 0x3fff8000000000000000;
    const previous: u80 = 0x3ffeffffffffffffffff;
    const infinity: u80 = 0x7fff8000000000000000;
    for ([_]struct { opcode: u8 = 0xfb, input: u80, result: [4]u80, pushed: [4]u80, flags: [4]u16 = @splat(0), biased: ?[4]u80 = null, tag: u8 = 1, range: bool = false }{
        .{ .input = 0, .result = @splat(0), .pushed = @splat(one) },
        .{ .input = sign, .result = @splat(sign), .pushed = @splat(one) },
        .{ .input = one, .result = .{ 0x3ffed76aa47848677021, 0x3ffed76aa47848677020, 0x3ffed76aa47848677021, 0x3ffed76aa47848677020 }, .pushed = .{ 0x3ffe8a51407da8345c92, 0x3ffe8a51407da8345c91, 0x3ffe8a51407da8345c92, 0x3ffe8a51407da8345c91 }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .input = 0x3fffc90fdaa22168c235, .result = .{ one, previous, one, previous }, .pushed = .{ 0xbfbdece675d1fc8f8cbb, 0xbfbdece675d1fc8f8cbc, 0xbfbdece675d1fc8f8cbb, 0xbfbdece675d1fc8f8cbb }, .flags = .{ 0x220, 32, 0x220, 32 } },
        .{ .input = 0x403dffffffffffffffff, .result = .{ 0x3ffedf327e112abeef8f, 0x3ffedf327e112abeef8f, 0x3ffedf327e112abeef90, 0x3ffedf327e112abeef8f }, .pushed = .{ 0x3ffdfac035ec484929c2, 0x3ffdfac035ec484929c1, 0x3ffdfac035ec484929c2, 0x3ffdfac035ec484929c1 }, .flags = .{ 32, 32, 0x220, 32 } },
        .{ .input = 1, .result = .{ 1, 0, 1, 0 }, .pushed = .{ one, previous, one, previous }, .flags = .{ 0x232, 50, 0x232, 50 }, .biased = .{ 0x5fc28000000000000000, 0x5fc1ffffffffffffffff, 0x5fc28000000000000000, 0x5fc1ffffffffffffffff } },
        .{ .input = 0x18000000000000000, .result = .{ 0x18000000000000000, 0x7fffffffffffffff, 0x18000000000000000, 0x7fffffffffffffff }, .pushed = .{ one, previous, one, previous }, .flags = .{ 0x220, 48, 0x220, 48 }, .biased = .{ 0x18000000000000000, 0x6000ffffffffffffffff, 0x18000000000000000, 0x6000ffffffffffffffff } },
        .{ .input = infinity, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(1) },
        .{ .input = infinity | quiet | 17, .result = @splat(infinity | quiet | 17), .pushed = @splat(infinity | quiet | 17) },
        .{ .input = infinity | 17, .result = @splat(infinity | quiet | 17), .pushed = @splat(infinity | quiet | 17), .flags = @splat(1) },
        .{ .input = 0x3fff0000000000000000, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(1) },
        .{ .input = one, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(65), .tag = 0 },
        .{ .input = one, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(65), .tag = 128 },
        .{ .input = one, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(0x241), .tag = 129 },
        .{ .input = 1, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(0x241), .tag = 255 },
        .{ .input = 0x403e8000000000000000, .result = @splat(0), .pushed = @splat(0), .range = true },
        .{ .input = 0xc03e8000000000000000, .result = @splat(0), .pushed = @splat(0), .range = true },
        .{ .input = 0x403e8000000000000000, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(0x241), .tag = 255 },
        .{ .opcode = 0xf2, .input = 0x1, .result = .{ 0x1, 0x1, 0x2, 0x1 }, .pushed = @splat(one), .flags = .{ 0x32, 0x32, 0x232, 0x32 }, .biased = .{ 0x5fc28000000000000000, 0x5fc28000000000000000, 0x5fc28000000000000001, 0x5fc28000000000000000 } },
        .{ .opcode = 0xf2, .input = 0x80000000000000000001, .result = .{ 0x80000000000000000001, 0x80000000000000000002, 0x80000000000000000001, 0x80000000000000000001 }, .pushed = @splat(one), .flags = .{ 0x32, 0x232, 0x32, 0x32 }, .biased = .{ 0xdfc28000000000000000, 0xdfc28000000000000001, 0xdfc28000000000000000, 0xdfc28000000000000000 } },
        .{ .opcode = 0xf2, .input = 0x18000000000000000, .result = .{ 0x18000000000000000, 0x18000000000000000, 0x18000000000000001, 0x18000000000000000 }, .pushed = @splat(one), .flags = .{ 0x20, 0x20, 0x220, 0x20 } },
        .{ .opcode = 0xf2, .input = 0x80018000000000000000, .result = .{ 0x80018000000000000000, 0x80018000000000000001, 0x80018000000000000000, 0x80018000000000000000 }, .pushed = @splat(one), .flags = .{ 0x20, 0x220, 0x20, 0x20 } },
        .{ .opcode = 0xf2, .input = 0x3fdf8000000000000000, .result = .{ 0x3fdf8000000000000000, 0x3fdf8000000000000000, 0x3fdf8000000000000001, 0x3fdf8000000000000000 }, .pushed = @splat(one), .flags = .{ 0x20, 0x20, 0x220, 0x20 } },
        .{ .opcode = 0xf2, .input = 0xbfdf8000000000000000, .result = .{ 0xbfdf8000000000000000, 0xbfdf8000000000000001, 0xbfdf8000000000000000, 0xbfdf8000000000000000 }, .pushed = @splat(one), .flags = .{ 0x20, 0x220, 0x20, 0x20 } },
        .{ .opcode = 0xf2, .input = 0x3fe08000000000000000, .result = .{ 0x3fe08000000000000001, 0x3fe08000000000000000, 0x3fe08000000000000001, 0x3fe08000000000000000 }, .pushed = @splat(one), .flags = .{ 0x220, 0x20, 0x220, 0x20 } },
        .{ .opcode = 0xf2, .input = 0xbfe08000000000000000, .result = .{ 0xbfe08000000000000001, 0xbfe08000000000000001, 0xbfe08000000000000000, 0xbfe08000000000000000 }, .pushed = @splat(one), .flags = .{ 0x220, 0x220, 0x20, 0x20 } },
        .{ .opcode = 0xf2, .input = 0x3fff8000000000000000, .result = .{ 0x3fffc75922e5f71d2dc5, 0x3fffc75922e5f71d2dc5, 0x3fffc75922e5f71d2dc6, 0x3fffc75922e5f71d2dc5 }, .pushed = @splat(one), .flags = .{ 0x20, 0x20, 0x220, 0x20 } },
        .{ .opcode = 0xf2, .input = 0xbfff8000000000000000, .result = .{ 0xbfffc75922e5f71d2dc5, 0xbfffc75922e5f71d2dc6, 0xbfffc75922e5f71d2dc5, 0xbfffc75922e5f71d2dc5 }, .pushed = @splat(one), .flags = .{ 0x20, 0x220, 0x20, 0x20 } },
        .{ .opcode = 0xf2, .input = 0x3fffc90fdaa22168c235, .result = .{ 0xc0408a51e04daabda35f, 0xc0408a51e04daabda35f, 0xc0408a51e04daabda35e, 0xc0408a51e04daabda35e }, .pushed = @splat(one), .flags = .{ 0x220, 0x220, 0x20, 0x20 } },
        .{ .opcode = 0xf2, .input = 0xbfffc90fdaa22168c235, .result = .{ 0x40408a51e04daabda35f, 0x40408a51e04daabda35e, 0x40408a51e04daabda35f, 0x40408a51e04daabda35e }, .pushed = @splat(one), .flags = .{ 0x220, 0x20, 0x220, 0x20 } },
        .{ .opcode = 0xf2, .input = 0x4000c90fdaa22168c235, .result = .{ 0x3fbeece675d1fc8f8cbb, 0x3fbeece675d1fc8f8cbb, 0x3fbeece675d1fc8f8cbc, 0x3fbeece675d1fc8f8cbb }, .pushed = @splat(one), .flags = .{ 0x20, 0x20, 0x220, 0x20 } },
        .{ .opcode = 0xf2, .input = 0xc000c90fdaa22168c235, .result = .{ 0xbfbeece675d1fc8f8cbb, 0xbfbeece675d1fc8f8cbc, 0xbfbeece675d1fc8f8cbb, 0xbfbeece675d1fc8f8cbb }, .pushed = @splat(one), .flags = .{ 0x20, 0x220, 0x20, 0x20 } },
        .{ .opcode = 0xf2, .input = 0x403d8000000000000000, .result = .{ 0x3ffefcff2df3327d3a09, 0x3ffefcff2df3327d3a08, 0x3ffefcff2df3327d3a09, 0x3ffefcff2df3327d3a08 }, .pushed = @splat(one), .flags = .{ 0x220, 0x20, 0x220, 0x20 } },
        .{ .opcode = 0xf2, .input = 0xc03d8000000000000000, .result = .{ 0xbffefcff2df3327d3a09, 0xbffefcff2df3327d3a09, 0xbffefcff2df3327d3a08, 0xbffefcff2df3327d3a08 }, .pushed = @splat(one), .flags = .{ 0x220, 0x220, 0x20, 0x20 } },
        .{ .opcode = 0xf2, .input = 0x403dffffffffffffffff, .result = .{ 0x3fffe3de9ed3992f3138, 0x3fffe3de9ed3992f3137, 0x3fffe3de9ed3992f3138, 0x3fffe3de9ed3992f3137 }, .pushed = @splat(one), .flags = .{ 0x220, 0x20, 0x220, 0x20 } },
        .{ .opcode = 0xf2, .input = 0xc03dffffffffffffffff, .result = .{ 0xbfffe3de9ed3992f3138, 0xbfffe3de9ed3992f3138, 0xbfffe3de9ed3992f3137, 0xbfffe3de9ed3992f3137 }, .pushed = @splat(one), .flags = .{ 0x220, 0x220, 0x20, 0x20 } },
        .{ .opcode = 0xf2, .input = 0, .result = @splat(0), .pushed = @splat(one) },
        .{ .opcode = 0xf2, .input = sign, .result = @splat(sign), .pushed = @splat(one) },
        .{ .opcode = 0xf2, .input = infinity, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(1) },
        .{ .opcode = 0xf2, .input = infinity | quiet | 17, .result = @splat(infinity | quiet | 17), .pushed = @splat(infinity | quiet | 17) },
        .{ .opcode = 0xf2, .input = infinity | 17, .result = @splat(infinity | quiet | 17), .pushed = @splat(infinity | quiet | 17), .flags = @splat(1) },
        .{ .opcode = 0xf2, .input = 0x3fff0000000000000000, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(1) },
        .{ .opcode = 0xf2, .input = one, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(65), .tag = 0 },
        .{ .opcode = 0xf2, .input = one, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(65), .tag = 128 },
        .{ .opcode = 0xf2, .input = one, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(0x241), .tag = 129 },
        .{ .opcode = 0xf2, .input = 1, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(0x241), .tag = 255 },
        .{ .opcode = 0xf2, .input = 0x403e8000000000000000, .result = @splat(0), .pushed = @splat(0), .range = true },
        .{ .opcode = 0xf2, .input = 0xc03e8000000000000000, .result = @splat(0), .pushed = @splat(0), .range = true },
        .{ .opcode = 0xf2, .input = 0x403e8000000000000000, .result = @splat(indefinite), .pushed = @splat(indefinite), .flags = @splat(0x241), .tag = 255 },
    }) |case| {
        try m.initialize(0x1000, &.{ 0xd9, case.opcode, 0x9b });
        for (0..8) |slot| {
            for (0..4) |precision| {
                for (0..4) |mode| {
                    for ([_]u16{ 0, 1, 2, 16, 32, 63 }) |unmask| {
                        for ([_]u16{ 0, 0x400 }) |c2| {
                            var s = State{ .architecture = .x86_64, .pc = 0x1000, .flags = .{ .carry = true, .direction = true } };
                            s.x86_fp.control = (0x7f | (@as(u16, @intCast(precision)) << 8) | (@as(u16, @intCast(mode)) << 10)) & ~unmask;
                            s.x86_fp.status = 0x4300 | c2;
                            setTop(&s.x86_fp, @intCast(slot));
                            for (0..8) |index| put(&s.x86_fp, @intCast(index), extended(@floatFromInt(index + 4)));
                            put(&s.x86_fp, @intCast(slot), case.input);
                            s.x86_fp.tag = std.math.rotl(u8, case.tag, slot);
                            s.x86_fp.data_pointer = 0x123456;
                            const before = s;
                            const destination = top(s.x86_fp) -% 1;
                            var flags = case.flags[mode];
                            const blocked = flags & unmask & 3 != 0;
                            if (blocked) flags = if (flags & 1 != 0) flags & 0x241 else 2;
                            const pending_exception = flags & unmask & 63 != 0;
                            _ = try run(&s, &m, try decode(&m, s.pc));
                            const condition = if (case.range) @as(u16, 0x400) else if (blocked) c2 else 0;
                            const result_top: u3 = if (blocked or case.range) @intCast(slot) else destination;
                            try std.testing.expectEqual(@as(u16, 0x4100) | (@as(u16, result_top) << 11) | condition | flags | (if (pending_exception) @as(u16, 0x8080) else 0), s.x86_fp.status);
                            try std.testing.expectEqual(if (blocked or case.range) before.x86_fp.tag else before.x86_fp.tag | (@as(u8, 1) << @intCast(slot)) | (@as(u8, 1) << destination), s.x86_fp.tag);
                            if (!blocked and !case.range) {
                                const sine = if (unmask & 16 != 0 and case.biased != null) case.biased.?[mode] else case.result[mode];
                                try std.testing.expectEqual(sine, get(s.x86_fp, @intCast(slot)));
                                try std.testing.expectEqual(case.pushed[mode], get(s.x86_fp, destination));
                            }
                            for (0..8) |index| {
                                if (blocked or case.range or index != slot and index != destination) try std.testing.expectEqual(before.x86_fp.registers[index], s.x86_fp.registers[index]);
                            }
                            try std.testing.expectEqual(before.x86_fp.control, s.x86_fp.control);
                            try std.testing.expectEqual(before.x86_fp.mxcsr, s.x86_fp.mxcsr);
                            try std.testing.expectEqual(before.x86_fp.data_pointer, s.x86_fp.data_pointer);
                            try std.testing.expectEqual(before.flags, s.flags);
                            if (pending_exception) {
                                const pending_state = s;
                                try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, s.pc)));
                                try std.testing.expectEqual(pending_state, s);
                            }
                        }
                    }
                }
            }
        }
    }
    for ([_]u8{ 0xf2, 0xfb }) |opcode| {
        try m.initialize(0x1000, &.{ 0xf0, 0xd9, opcode });
        try std.testing.expectError(error.InvalidLockPrefix, decode(&m, 0x1000));
    }
}

test "Odd transcendentals and cosine retain corrections for every denormal leading bit" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    for ([_]u8{ 0xf3, 0xfe, 0xff, 0xfb, 0xf2 }) |opcode| {
        try m.initialize(0x1000, &.{ 0xd9, opcode });
        for (0..64) |bit| {
            const input = @as(u80, 1) << @intCast(bit);
            for (0..4) |precision| {
                for (0..4) |mode| {
                    for ([_]u80{ 0, sign }) |signed| {
                        var s = State{ .architecture = .x86_64, .pc = 0x1000 };
                        s.x86_fp.control = 0x7f | (@as(u16, @intCast(precision)) << 8) | (@as(u16, @intCast(mode)) << 10);
                        const destination: u3 = if (opcode == 0xf3) 1 else 0;
                        if (opcode == 0xf3) put(&s.x86_fp, 0, extended(1));
                        put(&s.x86_fp, destination, input | signed);
                        _ = try run(&s, &m, try decode(&m, s.pc));
                        const up = (mode == 0 and opcode != 0xf2) or mode == (if (signed != 0 and opcode != 0xff) @as(usize, 1) else 2);
                        const result = if (opcode == 0xff) @as(u80, if (up) 0x3fff8000000000000000 else 0x3ffeffffffffffffffff) else if (opcode == 0xf2) signed | ((if (bit == 63) (@as(u80, 1) << 64) | integer else input) + @intFromBool(up)) else signed | (if (!up) input - 1 else if (bit == 63) (@as(u80, 1) << 64) | integer else input);
                        try std.testing.expectEqual(result, get(s.x86_fp, destination));
                        try std.testing.expectEqual(@as(u16, if (opcode == 0xf3) 0x822 else if (opcode == 0xf2 or opcode == 0xfb) 0x3822 else 0x22) | (if (up) @as(u16, 0x200) else 0) | (if ((opcode == 0xf3 or opcode == 0xf2 or opcode == 0xfb) and exponent(result) == 0) @as(u16, 16) else 0), s.x86_fp.status);
                        try std.testing.expectEqual(@as(u8, if (opcode == 0xf3) 2 else if (opcode == 0xf2 or opcode == 0xfb) 129 else 1), s.x86_fp.tag);
                        if (opcode == 0xf2 or opcode == 0xfb) {
                            const pushed: u80 = if (opcode == 0xf2 or mode == 0 or mode == 2) 0x3fff8000000000000000 else 0x3ffeffffffffffffffff;
                            try std.testing.expectEqual(pushed, get(s.x86_fp, 7));
                        }
                    }
                }
            }
        }
    }
}

test "FYL2XP1 out-of-domain inputs have an explicit numeric profile and still pop" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0xd9, 0xf9 });
    for ([_]u80{ 0x3ffd95f619980c4336f8, extended(1), 0x7fff8000000000000000 }) |magnitude| {
        for ([_]u80{ 0, sign }) |signed| {
            var s = State{ .architecture = .x86_64, .pc = 0x1000 };
            put(&s.x86_fp, 0, magnitude | signed);
            put(&s.x86_fp, 1, extended(-3));
            _ = try run(&s, &m, try decode(&m, s.pc));
            try std.testing.expectEqual(extended(-3), get(s.x86_fp, 1));
            try std.testing.expectEqual(@as(u16, 0x800), s.x86_fp.status);
            try std.testing.expectEqual(@as(u8, 2), s.x86_fp.tag);
        }
    }
}

test "An apparently exact transcendental approximation still reports true underflow" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0xd9, 0xf1, 0x9b });
    // p/q is a continued-fraction convergent just below log2(3). The true
    // product is irrational; binary128 rounds it to the integer p before our
    // scale is applied. Its nearest extended result is tiny and inexact.
    const p: u80 = 0x5d526b42ca2e294c;
    const q: u80 = 0x3ae12d1921f03199;
    for (0..8) |slot| {
        for (0..4) |precision| {
            for ([_]u16{ 0, 2, 16, 32, 63 }) |unmask| {
                var s = State{ .architecture = .x86_64, .pc = 0x1000 };
                s.x86_fp.control = (0x7f | (@as(u16, @intCast(precision)) << 8)) & ~unmask;
                setTop(&s.x86_fp, @intCast(slot));
                put(&s.x86_fp, @intCast(slot), extended(3));
                const destination = physical(s.x86_fp, 1);
                put(&s.x86_fp, destination, q);
                const before = s;
                _ = try run(&s, &m, try decode(&m, s.pc));
                const blocked = unmask & 2 != 0;
                const flags: u16 = if (blocked) 2 else 0x32;
                const expected = if (blocked) q else if (unmask & 16 != 0) (@as(u80, 0x6000) << 64) | (p << 1) else p;
                try std.testing.expectEqual(expected, get(s.x86_fp, destination));
                try std.testing.expectEqual((@as(u16, if (blocked) @as(u3, @intCast(slot)) else destination) << 11) | flags | (if (flags & unmask != 0) @as(u16, 0x8080) else 0), s.x86_fp.status);
                if (blocked) try std.testing.expectEqual(before.x86_fp.registers, s.x86_fp.registers);
                if (flags & unmask != 0) {
                    const pending_state = s;
                    try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, s.pc)));
                    try std.testing.expectEqual(pending_state, s);
                }
            }
        }
    }
}

test "F2XM1 preserves full precision, tiny biased results and deferred operand faults" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0xd9, 0xf0, 0x9b });
    const half: u80 = 0x3ffdd413cccfe7799211;
    const negative_half: u80 = 0xbffd95f619980c4336f7;
    const small: u80 = 0x58b90bfbe8e7bcd5;
    const biased: u80 = 0x5fc1b17217f7d1cf79ab;
    const biased_normal: u80 = 0x6000b17217f7d1cf79ab;
    const snan: u80 = 0xffff8000000000000007;
    for ([_]struct { raw: u80, results: [4]u80, flags: [4]u16 = @splat(0), biased_results: [4]u80 = @splat(0), empty: bool = false }{
        .{ .raw = 0, .results = @splat(0) },
        .{ .raw = sign, .results = @splat(sign) },
        .{ .raw = extended(1), .results = @splat(extended(1)) },
        .{ .raw = extended(-1), .results = @splat(extended(-0.5)) },
        .{ .raw = extended(0.5), .results = .{ half, half, half + 1, half }, .flags = .{ 32, 32, 0x220, 32 } },
        .{ .raw = extended(-0.5), .results = .{ negative_half, negative_half + 1, negative_half, negative_half }, .flags = .{ 32, 0x220, 32, 32 } },
        .{ .raw = 1, .results = .{ 1, 0, 1, 0 }, .flags = .{ 0x232, 0x32, 0x232, 0x32 }, .biased_results = .{ biased + 1, biased, biased + 1, biased } },
        .{ .raw = sign | 1, .results = .{ sign | 1, sign | 1, sign, sign }, .flags = .{ 0x232, 0x232, 0x32, 0x32 }, .biased_results = .{ sign | (biased + 1), sign | (biased + 1), sign | biased, sign | biased } },
        .{ .raw = (@as(u80, 1) << 64) | integer, .results = .{ small + 1, small, small + 1, small }, .flags = .{ 0x230, 0x30, 0x230, 0x30 }, .biased_results = .{ biased_normal + 1, biased_normal, biased_normal + 1, biased_normal } },
        .{ .raw = snan, .results = @splat(snan | quiet), .flags = @splat(1) },
        .{ .raw = snan | quiet, .results = @splat(snan | quiet) },
        .{ .raw = @as(u80, 0x3fff) << 64, .results = @splat(indefinite), .flags = @splat(1) },
        .{ .raw = extended(0.5), .results = @splat(indefinite), .flags = @splat(0x41), .empty = true },
    }) |case| {
        for (0..8) |slot| {
            for (0..4) |precision| {
                for (0..4) |mode| {
                    for ([_]u16{ 0, 1, 2, 16, 32, 63 }) |unmask| {
                        var s = State{ .architecture = .x86_64, .pc = 0x1000, .flags = .{ .carry = true, .direction = true } };
                        s.x86_fp.control = (0x7f | (@as(u16, @intCast(precision)) << 8) | (@as(u16, @intCast(mode)) << 10)) & ~unmask;
                        s.x86_fp.status = 0x4700;
                        setTop(&s.x86_fp, @intCast(slot));
                        put(&s.x86_fp, @intCast(slot), case.raw);
                        if (case.empty) s.x86_fp.tag = 0;
                        const neighbor = physical(s.x86_fp, 1);
                        put(&s.x86_fp, neighbor, snan);
                        s.x86_fp.data_pointer = 0x123456;
                        s.x86_fp.data_selector = 0x789;
                        const before = s;
                        var flags = case.flags[mode];
                        const blocked = flags & unmask & 3 != 0;
                        if (blocked) flags = if (flags & 1 != 0) flags & 0x41 else 2;
                        const result = if (blocked) case.raw else if (flags & 16 != 0 and unmask & 16 != 0) case.biased_results[mode] else case.results[mode];
                        const pending_exception = flags & unmask & 63 != 0;
                        _ = try run(&s, &m, try decode(&m, s.pc));
                        try std.testing.expectEqual(result, get(s.x86_fp, @intCast(slot)));
                        try std.testing.expectEqual(@as(u16, 0x4500) | (@as(u16, @intCast(slot)) << 11) | flags | (if (pending_exception) @as(u16, 0x8080) else 0), s.x86_fp.status);
                        try std.testing.expectEqual(before.x86_fp.control, s.x86_fp.control);
                        try std.testing.expectEqual(before.x86_fp.tag | @as(u8, if (blocked) 0 else @as(u8, 1) << @intCast(slot)), s.x86_fp.tag);
                        try std.testing.expectEqual(before.x86_fp.mxcsr, s.x86_fp.mxcsr);
                        try std.testing.expectEqual(before.x86_fp.data_pointer, s.x86_fp.data_pointer);
                        try std.testing.expectEqual(before.x86_fp.data_selector, s.x86_fp.data_selector);
                        try std.testing.expectEqual(before.flags, s.flags);
                        try std.testing.expectEqual(snan, get(s.x86_fp, neighbor));
                        if (blocked) try std.testing.expectEqual(before.x86_fp.registers, s.x86_fp.registers);
                        if (pending_exception) {
                            const pending_state = s;
                            try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, s.pc)));
                            try std.testing.expectEqual(pending_state, s);
                        }
                    }
                }
            }
        }
    }
    try m.initialize(0x1000, &.{ 0xf0, 0xd9, 0xf0 });
    try std.testing.expectError(error.InvalidLockPrefix, decode(&m, 0x1000));
}

test "FSCALE truncates its exponent, preserves full precision and handles massive exceptions" {
    const decode = @import("cpu/x86_64.zig").decode;
    const run = @import("interpreter.zig").execute;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.initialize(0x1000, &.{ 0xd9, 0xfd, 0x9b });
    const infinity = (@as(u80, 0x7fff) << 64) | integer;
    const maximum = (@as(u80, 0x7ffe) << 64) | std.math.maxInt(u64);
    for ([_]struct { a: u80, b: u80, result: u80, status: u16 = 0, control: u16 = 0x37f, commit: bool = true }{
        .{ .a = extended(1.5), .b = extended(3.75), .result = extended(12) },
        .{ .a = extended(1.5), .b = extended(-3.75), .result = extended(0.1875) },
        .{ .a = extended(1 + 0x1p-63), .b = extended(0.75), .result = extended(1 + 0x1p-63) },
        .{ .a = 1, .b = extended(63), .result = (@as(u80, 1) << 64) | integer, .status = 2 },
        .{ .a = maximum, .b = extended(1), .result = infinity, .status = 0x228 },
        .{ .a = maximum, .b = extended(1), .result = (@as(u80, 0x1fff) << 64) | std.math.maxInt(u64), .status = 0x8088, .control = 0x377 },
        .{ .a = 1, .b = extended(-1), .result = 0, .status = 0x32 },
        .{ .a = 1, .b = extended(-1), .result = 1, .status = 0x232, .control = 0xb7f },
        .{ .a = 1, .b = extended(-1), .result = (@as(u80, 0x5fc1) << 64) | integer, .status = 0x8092, .control = 0x36f },
        .{ .a = extended(-1), .b = extended(1e9), .result = sign | infinity, .status = 0x8088, .control = 0x377 },
        .{ .a = extended(-1), .b = extended(1e9), .result = sign | maximum, .status = 0x28, .control = 0xf7f },
        .{ .a = extended(-1), .b = extended(-1e9), .result = sign, .status = 0x8090, .control = 0x36f },
        .{ .a = extended(1), .b = extended(-1e9), .result = 1, .status = 0x230, .control = 0xb7f },
        .{ .a = extended(1), .b = maximum, .result = infinity, .status = 0x8088, .control = 0x377 },
        .{ .a = extended(1), .b = sign | maximum, .result = 0, .status = 0x8090, .control = 0x36f },
        .{ .a = extended(-1), .b = infinity, .result = sign | infinity },
        .{ .a = extended(-1), .b = sign | infinity, .result = sign },
        .{ .a = sign, .b = extended(1e9), .result = sign },
        .{ .a = infinity, .b = infinity, .result = infinity },
        .{ .a = sign, .b = infinity, .result = indefinite, .status = 1 },
        .{ .a = infinity, .b = sign | infinity, .result = indefinite, .status = 1 },
        .{ .a = infinity, .b = sign | infinity, .result = infinity, .status = 0x8081, .control = 0x37e, .commit = false },
        .{ .a = extended(1), .b = infinity | 7, .result = infinity | quiet | 7, .status = 1 },
        .{ .a = extended(1), .b = 1, .result = extended(1), .status = 2 },
        .{ .a = extended(1), .b = 1, .result = extended(1), .status = 0x8082, .control = 0x37d, .commit = false },
    }) |case| {
        for (0..8) |slot| {
            for (0..4) |precision| {
                var s = State{ .architecture = .x86_64, .pc = 0x1000, .flags = .{ .carry = true, .direction = true } };
                s.x86_fp.control = (case.control & ~@as(u16, 0x300)) | (@as(u16, @intCast(precision)) << 8);
                s.x86_fp.status = 0x4700;
                setTop(&s.x86_fp, @intCast(slot));
                put(&s.x86_fp, @intCast(slot), case.a);
                const source = physical(s.x86_fp, 1);
                put(&s.x86_fp, source, case.b);
                const before = s;
                _ = try run(&s, &m, try decode(&m, s.pc));
                try std.testing.expectEqual(case.result, get(s.x86_fp, @intCast(slot)));
                try std.testing.expectEqual(case.b, get(s.x86_fp, source));
                try std.testing.expectEqual(@as(u16, 0x4500) | (@as(u16, @intCast(slot)) << 11) | case.status, s.x86_fp.status);
                try std.testing.expectEqual(before.x86_fp.tag, s.x86_fp.tag);
                try std.testing.expectEqual(before.x86_fp.control, s.x86_fp.control);
                try std.testing.expectEqual(before.x86_fp.mxcsr, s.x86_fp.mxcsr);
                try std.testing.expectEqual(before.flags, s.flags);
                if (!case.commit) try std.testing.expectEqual(before.x86_fp.registers, s.x86_fp.registers);
                if (case.status & 0x8080 != 0) {
                    const pending_state = s;
                    try std.testing.expectError(error.FloatingPointException, run(&s, &m, try decode(&m, s.pc)));
                    try std.testing.expectEqual(pending_state, s);
                }
            }
        }
    }
    try m.initialize(0x1000, &.{ 0xd9, 0xf4, 0xd9, 0xfd, 0xdd, 0xd9 });
    for ([_]u80{ 0, sign, 1, sign | 3, (@as(u80, 1) << 64) | integer, maximum, extended(1 + 0x1p-63), infinity }) |raw| {
        var s = State{ .architecture = .x86_64, .pc = 0x1000 };
        s.x86_fp.control = 0x7f;
        put(&s.x86_fp, 0, raw);
        for (0..3) |_| _ = try run(&s, &m, try decode(&m, s.pc));
        try std.testing.expectEqual(raw, get(s.x86_fp, 0));
        try std.testing.expectEqual(@as(u8, 1), s.x86_fp.tag);
        try std.testing.expectEqual(@as(u3, 0), top(s.x86_fp));
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
