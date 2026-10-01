//! x87 stack, transfers and controls. Raw 80-bit data also backs original MMX.
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
    if (byte >= 0xc0) return switch (code) {
        0xd9c0...0xd9cf,
        0xd9d0,
        0xd9e0,
        0xd9e1,
        0xd9e5,
        0xd9e8,
        0xd9ee,
        0xd9f6,
        0xd9f7,
        0xddc0...0xddc7,
        0xddd0...0xdddf,
        0xdbe2,
        0xdbe3,
        0xdfe0,
        => true,
        else => false,
    };
    const group: u3 = @truncate(byte >> 3);
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
fn loadFloat(bits: u64, width: u7, flags: *u16) u80 {
    const fraction_bits: u6 = if (width == 32) 23 else 52;
    const bias: u16 = if (width == 32) 127 else 1023;
    const exp = (bits >> fraction_bits) & (bias * 2 + 1);
    const fraction = bits & ((@as(u64, 1) << fraction_bits) - 1);
    const negative = bits & (@as(u64, 1) << @as(u6, @intCast(width - 1))) != 0;
    if (exp == bias * 2 + 1) {
        var significand = integer | (fraction << @as(u6, 63 - fraction_bits));
        if (fraction != 0 and significand & quiet == 0) {
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
    if (control) {
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
            0xd9e8, 0xd9ee => push(&fp, if (code == 0xd9e8) (@as(u80, 0x3fff) << 64) | integer else 0, 0),
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
                loadFloat(try m.readInt(addr, width, .read), width, &flags)
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
    for ([_][]const u8{ &.{ 0xd8, 0xc0 }, &.{ 0xd9, 0xe9 }, &.{ 0xdd, 0xc8 } }) |bytes| {
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
