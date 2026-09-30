//! Bounded ARM64-host code generator. Unsupported UIR remains interpreted.
const std = @import("std");
const builtin = @import("builtin");
const host = @import("host.zig");
const c = host.c;
const ir = @import("ir.zig");
const State = @import("cpu/state.zig").State;
const Memory = @import("memory.zig").Memory;
const Function = *const fn ([*]u64) callconv(.c) void;
const Block = struct { pc: u64, next: u64, count: u64, code: *anyopaque, size: usize, function: Function };
const Emitter = struct {
    words: [512]u32 = undefined,
    len: usize = 0,
    arch: @import("loader/elf.zig").Architecture,
    fn emit(e: *Emitter, word: u32) !void {
        if (e.len == e.words.len) return error.JitBlockTooLarge;
        e.words[e.len] = word;
        e.len += 1;
    }
    fn immediate(e: *Emitter, reg: u5, value: u64) !void {
        try e.emit(0xd2800000 | (@as(u32, @intCast(value & 0xffff)) << 5) | reg);
        for (1..4) |n| {
            const part: u32 = @intCast((value >> @as(u6, @intCast(n * 16))) & 0xffff);
            if (part != 0) try e.emit(0xf2800000 | (@as(u32, @intCast(n)) << 21) | (part << 5) | reg);
        }
    }
    fn zero(e: Emitter, index: u6) bool {
        return (e.arch == .riscv64 and index == 0) or (e.arch == .arm64 and index == 32);
    }
    fn load(e: *Emitter, o: ir.Operand, reg: u5) !bool {
        switch (o) {
            .imm => |v| try e.immediate(reg, v),
            .reg => |r| {
                if (r.high) return false;
                if (e.zero(r.index)) try e.immediate(reg, 0) else try e.emit(0xf9400000 | (@as(u32, r.index) << 10) | reg);
            },
            else => return false,
        }
        return true;
    }
    fn instruction(e: *Emitter, i: ir.Instruction) !bool {
        const begin = e.len;
        if (i.update_reg != null or i.sign_result and i.width != 32) return false;
        if (i.op == .nop) return true;
        if (i.dst != .reg or i.dst.reg.high or (i.width != 32 and i.width != 64)) return false;
        const rd = i.dst.reg.index;
        if (e.zero(rd)) {
            // These accepted operations have no memory accesses, traps or flags.
            if (i.op != .mov and i.op != .add and i.op != .sub and i.op != .xor and i.op != .and_ and i.op != .or_) return false;
            if (i.set_flags and i.op != .mov) return false;
            if ((i.src != .imm and i.src != .reg) or (i.lhs != null and i.lhs.? != .reg and i.lhs.? != .imm)) return false;
            return true;
        }
        const wide: u32 = if (i.width == 64) 0x80000000 else 0;
        if (i.op == .mov) {
            if (!try e.load(i.src, 1)) {
                e.len = begin;
                return false;
            }
            if (i.width == 32) try e.emit(0x2a0103e1);
        } else {
            if (i.set_flags or !try e.load(i.lhs orelse i.dst, 1) or !try e.load(i.src, 2)) {
                e.len = begin;
                return false;
            }
            const operation: u32 = switch (i.op) {
                .add => 0x0b020021,
                .sub => 0x4b020021,
                .and_ => 0x0a020021,
                .or_ => 0x2a020021,
                .xor => 0x4a020021,
                .imul => 0x1b027c21,
                .shl => 0x1ac22021,
                .shr => 0x1ac22421,
                .sar => 0x1ac22821,
                else => {
                    e.len = begin;
                    return false;
                },
            };
            try e.emit(operation | wide);
        }
        if (i.sign_result) try e.emit(0x93407c21); // SXTW x1,w1.
        try e.emit(0xf9000001 | (@as(u32, rd) << 10));
        return true;
    }
};
extern "c" fn sys_icache_invalidate(*anyopaque, usize) void;
fn flush(code: *anyopaque, size: usize) void {
    if (builtin.cpu.arch != .aarch64) return;
    if (builtin.os.tag == .macos) {
        sys_icache_invalidate(code, size);
        return;
    }
    const ctr = asm volatile ("mrs %[value], ctr_el0"
        : [value] "=r" (-> u64),
    );
    const data_line: usize = @as(usize, 4) << @as(u6, @intCast((ctr >> 16) & 15));
    const instruction_line: usize = @as(usize, 4) << @as(u6, @intCast(ctr & 15));
    const end = @intFromPtr(code) + size;
    var p = @intFromPtr(code) & ~(data_line - 1);
    while (p < end) : (p += data_line) asm volatile ("dc cvau, %[addr]"
        :
        : [addr] "r" (p),
        : .{ .memory = true });
    asm volatile ("dsb ish" ::: .{ .memory = true });
    p = @intFromPtr(code) & ~(instruction_line - 1);
    while (p < end) : (p += instruction_line) asm volatile ("ic ivau, %[addr]"
        :
        : [addr] "r" (p),
        : .{ .memory = true });
    asm volatile ("dsb ish\nisb" ::: .{ .memory = true });
}
pub const Jit = struct {
    allocator: std.mem.Allocator,
    page_size: usize,
    blocks: std.ArrayList(Block) = .empty,
    generation: u64 = 0,
    compiled: u64 = 0,
    hits: u64 = 0,
    compile_ns: u64 = 0,
    pub fn init(a: std.mem.Allocator) !Jit {
        if (builtin.cpu.arch != .aarch64) return error.UnsupportedJitHost;
        const page = c.sysconf(c._SC_PAGESIZE);
        if (page < 4096) return error.InvalidHostPageSize;
        return .{ .allocator = a, .page_size = @intCast(page) };
    }
    fn clear(j: *Jit) void {
        for (j.blocks.items) |b| {
            _ = c.munmap(b.code, b.size);
        }
        j.blocks.clearRetainingCapacity();
    }
    pub fn deinit(j: *Jit) void {
        j.clear();
        j.blocks.deinit(j.allocator);
    }
    fn compile(j: *Jit, e: *Emitter, pc: u64, next: u64, count: u64) !Block {
        try e.emit(0xd65f03c0); // RET; x0 is the register-array pointer, x1/x2 are caller-saved.
        const raw = c.mmap(null, j.page_size, c.PROT_READ | c.PROT_WRITE, c.MAP_PRIVATE | c.MAP_ANON, -1, 0);
        if (raw == c.MAP_FAILED or raw == null) return error.JitAllocationFailed;
        const code = raw.?;
        errdefer _ = c.munmap(code, j.page_size);
        const bytes: [*]u8 = @ptrCast(code);
        for (e.words[0..e.len], 0..) |word, n| std.mem.writeInt(u32, bytes[n * 4 ..][0..4], word, .little);
        flush(code, e.len * 4);
        if (c.mprotect(code, j.page_size, c.PROT_READ | c.PROT_EXEC) != 0) return error.JitProtectionFailed;
        j.compiled += 1;
        return .{ .pc = pc, .next = next, .count = count, .code = code, .size = j.page_size, .function = @ptrCast(@alignCast(code)) };
    }
    pub fn run(j: *Jit, s: *State, m: *Memory, remaining: u64) !bool {
        if (j.generation != m.generation) {
            j.clear();
            j.generation = m.generation;
        }
        for (j.blocks.items) |b| if (b.pc == s.pc and b.count <= remaining) {
            try m.check(b.pc, @intCast(b.next - b.pc), .execute);
            b.function(&s.registers);
            s.pc = b.next;
            s.instructions += b.count;
            j.hits += 1;
            return true;
        };
        if (j.blocks.items.len >= 128 or remaining == 0) return false;
        const start = try host.nowNs();
        var emitter = Emitter{ .arch = s.architecture };
        var pc = s.pc;
        var count: u64 = 0;
        while (count < @min(32, remaining)) : (count += 1) {
            const instruction = @import("cpu.zig").decode(m, s.architecture, pc) catch break;
            if (!try emitter.instruction(instruction)) break;
            pc = instruction.next;
        }
        if (count == 0) return false;
        const block = try j.compile(&emitter, s.pc, pc, count);
        errdefer _ = c.munmap(block.code, block.size);
        try j.blocks.append(j.allocator, block);
        j.compile_ns += (try host.nowNs()) - start;
        m.fault = null;
        block.function(&s.registers);
        s.pc = block.next;
        s.instructions += block.count;
        return true;
    }
};
test "ARM64 generated arithmetic matches UIR interpreter and remains W^X" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const instructions = [_]ir.Instruction{
        .{ .op = .mov, .dst = ir.reg(1), .src = ir.imm(0xfffffffffffffff0), .set_flags = false },
        .{ .op = .add, .dst = ir.reg(2), .lhs = ir.reg(1), .src = ir.imm(31), .set_flags = false },
        .{ .op = .shl, .dst = ir.reg(3), .lhs = ir.reg(2), .src = ir.imm(4), .set_flags = false },
        .{ .op = .sar, .dst = ir.reg(4), .lhs = ir.reg(1), .src = ir.imm(2), .set_flags = false },
        .{ .op = .sub, .dst = ir.reg(5), .lhs = ir.reg(2), .src = ir.imm(0x80000020), .width = 32, .sign_result = true, .set_flags = false },
        .{ .op = .imul, .dst = ir.reg(6), .lhs = ir.reg(2), .src = ir.imm(7), .set_flags = false },
    };
    var j = try Jit.init(std.testing.allocator);
    defer j.deinit();
    try std.testing.expectEqual(@as(usize, @intCast(c.sysconf(c._SC_PAGESIZE))), j.page_size);
    var e = Emitter{ .arch = .riscv64 };
    for (instructions) |i| try std.testing.expect(try e.instruction(i));
    const block = try j.compile(&e, 0x1000, 0x1018, instructions.len);
    defer _ = c.munmap(block.code, block.size);
    var actual = State{ .architecture = .riscv64 };
    var expected = actual;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    for (instructions) |i| _ = try @import("interpreter.zig").execute(&expected, &m, i);
    block.function(&actual.registers);
    try std.testing.expectEqualSlices(u64, &expected.registers, &actual.registers);
}

test "JIT invalidates modified code and enforces execute permission" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try m.write(0x1000, &.{ 0x93, 0x00, 0x10, 0x00 });
    var s = State{ .architecture = .riscv64, .pc = 0x1000 };
    var j = try Jit.init(std.testing.allocator);
    defer j.deinit();
    try std.testing.expect(try j.run(&s, &m, 1));
    try std.testing.expectEqual(@as(u64, 1), s.get(1));
    s.pc = 0x1000;
    try m.write(0x1000, &.{ 0x93, 0x00, 0x20, 0x00 });
    try std.testing.expect(try j.run(&s, &m, 1));
    try std.testing.expectEqual(@as(u64, 2), s.get(1));
    try m.protect(0x1000, 4096, .{ .read = true });
    s.pc = 0x1000;
    try std.testing.expect(!try j.run(&s, &m, 1));
}
