const std = @import("std");
const host = @import("host.zig");
const elf = @import("loader/elf.zig");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
const Linux = @import("syscall/linux.zig").Linux;
const ir = @import("ir.zig");
pub const Options = struct { allow_files: bool = false, syscalls: bool = false, trace_instructions: bool = false, max_instructions: u64 = 10_000_000, timeout_ms: u64 = 10000 };
pub const Runtime = struct {
    memory: Memory,
    state: State,
    linux: Linux,
    options: Options,
    started: u64,
    pub fn init(a: std.mem.Allocator, image: elf.Image, args: []const [:0]const u8, env: []const []const u8, options: Options) !Runtime {
        var m = Memory.init(a);
        errdefer m.deinit();
        const heap = try image.load(&m);
        try m.map(heap, 16 * 1024 * 1024, .{ .read = true, .write = true });
        var state = State{ .architecture = image.architecture, .pc = image.entry };
        try @import("process.zig").stack(a, &m, &state, image, args, env);
        return .{ .memory = m, .state = state, .linux = .{ .allocator = a, .allow_files = options.allow_files, .trace = options.syscalls, .heap_base = heap, .heap_end = heap, .heap_limit = heap + 16 * 1024 * 1024 }, .options = options, .started = try host.nowNs() };
    }
    pub fn deinit(r: *Runtime) void {
        r.linux.deinit();
        r.memory.deinit();
    }
    pub fn decode(r: *Runtime, pc: u64) !ir.Instruction {
        return switch (r.state.architecture) {
            .x86_64 => @import("cpu/x86_64.zig").decode(&r.memory, pc),
            .riscv64 => @import("cpu/riscv64.zig").decode(&r.memory, pc),
            .arm64 => @import("cpu/arm64.zig").decode(&r.memory, pc),
        };
    }
    pub fn step(r: *Runtime) !void {
        if (r.state.instructions >= r.options.max_instructions) return error.InstructionLimit;
        if (r.state.instructions % 4096 == 0 and r.options.timeout_ms != 0 and (try host.nowNs()) - r.started >= r.options.timeout_ms * 1_000_000) return error.ExecutionTimeout;
        const i = try r.decode(r.state.pc);
        if (r.options.trace_instructions) try @import("format.zig").instruction(2, i);
        if (try @import("interpreter.zig").execute(&r.state, &r.memory, i)) try r.linux.dispatch(&r.state, &r.memory);
    }
    pub fn run(r: *Runtime) !u8 {
        while (r.linux.exit_code == null) try r.step();
        return r.linux.exit_code.?;
    }
    pub fn fault(r: *Runtime, err: anyerror, path: []const u8) !void {
        try host.print(2, "UNIVERSE FAULT: {s}\nBinary: {s}\nGuest architecture: {s}\nGuest PC: 0x{x:0>16}\nInstructions: {d}\n", .{ @errorName(err), path, @tagName(r.state.architecture), r.state.pc, r.state.instructions });
        if (r.memory.fault) |f| try host.print(2, "Invalid guest memory {s}: address=0x{x:0>16} size={d}\n", .{ @tagName(f.access), f.address, f.size });
        if (err == error.UnsupportedSyscall) try host.print(2, "Linux syscall number: {d}\n", .{r.linux.last_number});
        try host.output(2, "Bytes:");
        for (0..15) |n| {
            const b = r.memory.readInt(r.state.pc + n, 8, .execute) catch break;
            try host.print(2, " {x:0>2}", .{b});
        }
        try host.output(2, "\nUse: universe --trace-instructions --syscalls <binary>\n");
    }
    pub fn stats(r: *Runtime) !void {
        const elapsed = (try host.nowNs()) - r.started;
        try host.print(2, "instructions={d} syscalls={d} guest_memory_bytes={d} elapsed_ns={d}\n", .{ r.state.instructions, r.linux.calls, r.memory.used, elapsed });
    }
};
