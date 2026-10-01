const std = @import("std");
const host = @import("host.zig");
const elf = @import("loader/elf.zig");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
const Linux = @import("syscall/linux.zig").Linux;
const ir = @import("ir.zig");
pub const Options = struct { jit: bool = false, allow_files: bool = false, sysroot: ?[:0]const u8 = null, syscalls: bool = false, trace_instructions: bool = false, max_instructions: u64 = 10_000_000, timeout_ms: u64 = 10000 };
pub const Runtime = struct {
    memory: Memory,
    state: State,
    linux: Linux,
    windows: ?@import("syscall/windows.zig").Windows = null,
    macos: ?@import("syscall/macos.zig").MacOS = null,
    options: Options,
    started: u64,
    last_clock_check: u64 = 0,
    fault_pc: u64 = 0,
    jit: ?@import("jit.zig").Jit = null,
    pub fn init(a: std.mem.Allocator, input: elf.Image, args: []const [:0]const u8, env: []const []const u8, options: Options) !Runtime {
        var jit = if (options.jit) try @import("jit.zig").Jit.init(a) else null;
        errdefer if (jit) |*j| j.deinit();
        var m = Memory.init(a);
        errdefer m.deinit();
        var image = input;
        image.bias = if (image.kind == 3) 0x40000000 else 0;
        const heap = try image.load(&m);
        try m.map(heap, 16 * 1024 * 1024, .{ .read = true, .write = true });
        var state = State{ .architecture = image.architecture, .pc = try image.entryAddress() };
        var interpreter_base: u64 = 0;
        if (image.interpreter) |name| {
            const root = options.sysroot orelse return error.MissingSysroot;
            if (!options.allow_files) return error.FileAccessDenied;
            if (try image.phAddress() == 0) return error.UnmappedProgramHeaders;
            const path = try @import("filesystem.zig").resolve(a, root, name);
            defer a.free(path);
            const bytes = try host.readFile(a, path);
            defer a.free(bytes);
            var interpreter = try elf.parse(bytes);
            if (interpreter.architecture != image.architecture) return error.ArchitectureMismatch;
            if (interpreter.interpreter != null) return error.RecursiveInterpreterUnsupported;
            interpreter.bias = if (interpreter.kind == 3) 0x700000000000 else 0;
            _ = try interpreter.load(&m);
            interpreter_base = interpreter.bias;
            state.pc = try interpreter.entryAddress();
        }
        try @import("process.zig").stack(a, &m, &state, image, args, env, interpreter_base);
        const started = try host.nowNs();
        return .{ .memory = m, .state = state, .linux = .{ .allocator = a, .allow_files = options.allow_files, .sysroot = options.sysroot, .trace = options.syscalls, .heap_base = heap, .heap_end = heap, .heap_limit = heap + 16 * 1024 * 1024, .boot_ns = started }, .jit = jit, .options = options, .started = started };
    }
    pub fn initPE(a: std.mem.Allocator, image: @import("loader/pe.zig").Image, args: []const [:0]const u8, options: Options) !Runtime {
        if (image.is_dll) return error.WindowsDLLExecutionUnsupported;
        var jit = if (options.jit) try @import("jit.zig").Jit.init(a) else null;
        errdefer if (jit) |*j| j.deinit();
        var m = Memory.init(a);
        errdefer m.deinit();
        try image.load(&m, image.base);
        var windows = @import("syscall/windows.zig").Windows{ .allocator = a, .module_base = image.base, .trace = options.syscalls, .allow_files = options.allow_files, .sysroot = options.sysroot };
        errdefer windows.deinit();
        try windows.bind(image, &m, args[0]);
        try windows.initProcess(&m, args);
        const top = @import("process.zig").stack_top;
        try m.map(top - 1024 * 1024, 1024 * 1024, .{ .read = true, .write = true });
        var state = State{ .architecture = .x86_64, .pc = image.base + image.entry_rva };
        state.set(4, top - 8);
        try m.writeInt(top - 8, 64, 0);
        state.gs_base = windows.teb_address;
        try windows.beginInitialization(&state, &m);
        return .{ .memory = m, .state = state, .linux = .{ .allocator = a }, .windows = windows, .jit = jit, .options = options, .started = try host.nowNs() };
    }
    pub fn initMachO(a: std.mem.Allocator, image: @import("loader/macho.zig").Image, args: []const [:0]const u8, env: []const []const u8, options: Options) !Runtime {
        var jit = if (options.jit) try @import("jit.zig").Jit.init(a) else null;
        errdefer if (jit) |*j| j.deinit();
        var memory = Memory.init(a);
        errdefer memory.deinit();
        var state = State{ .architecture = image.architecture };
        try image.load(&memory, &state);
        try @import("process.zig").macStack(a, &memory, &state, args, env, image.thread_offset == null);
        return .{ .memory = memory, .state = state, .linux = .{ .allocator = a, .allow_files = options.allow_files, .sysroot = options.sysroot, .page_size = if (image.architecture == .arm64) 16384 else 4096 }, .macos = .{ .trace = options.syscalls, .returns_main = image.thread_offset == null }, .jit = jit, .options = options, .started = try host.nowNs() };
    }
    pub fn exitCode(r: *Runtime) ?u8 {
        return if (r.windows) |w| w.exit_code else r.linux.exit_code;
    }
    pub fn deinit(r: *Runtime) void {
        if (r.jit) |*j| j.deinit();
        if (r.windows) |*w| w.deinit();
        r.linux.deinit();
        r.memory.deinit();
    }
    pub fn decode(r: *Runtime, pc: u64) !ir.Instruction {
        return @import("cpu.zig").decode(&r.memory, r.state.architecture, pc);
    }
    fn limits(r: *Runtime) !void {
        if (r.windows) |*w| try w.pollControl(&r.state, &r.memory);
        r.fault_pc = r.state.pc;
        if (r.state.instructions >= r.options.max_instructions) return error.InstructionLimit;
        const waiting = if (r.windows) |w| w.wait != null else false;
        if (waiting or r.state.instructions == 0 or r.state.instructions - r.last_clock_check >= 4096) {
            r.last_clock_check = r.state.instructions;
            if (r.options.timeout_ms != 0 and (try host.nowNs()) - r.started >= r.options.timeout_ms * 1_000_000) return error.ExecutionTimeout;
        }
    }
    pub fn step(r: *Runtime) !void {
        try r.limits();
        if (r.exitCode() != null) return;
        if (r.macos != null and r.macos.?.returns_main and r.state.pc == @import("syscall/macos.zig").main_return) {
            try r.memory.check(r.state.pc, 1, .execute);
            r.linux.exit_code = @truncate(r.state.get(0));
            r.state.instructions += 1;
            return;
        }
        if (r.windows) |*w| {
            if (@import("syscall/windows.zig").Windows.handles(r.state.pc)) {
                try w.dispatch(&r.state, &r.memory);
                return;
            }
        }
        const i = try r.decode(r.state.pc);
        if (i.op == .syscall and r.state.architecture == .arm64 and i.src.imm != (if (r.macos != null) @as(u64, 128) else 0)) return error.UnsupportedSyscallTrap;
        if (r.options.trace_instructions) try @import("format.zig").instruction(2, i);
        if (try @import("interpreter.zig").execute(&r.state, &r.memory, i)) {
            if (r.windows != null) return error.UnsupportedWindowsSyscall;
            if (r.macos) |*mac| try mac.dispatch(&r.linux, &r.state, &r.memory) else try r.linux.dispatch(&r.state, &r.memory);
        }
    }
    pub fn run(r: *Runtime) !u8 {
        while (r.exitCode() == null) {
            try r.limits();
            if (r.exitCode() != null) break;
            if (!r.options.trace_instructions) {
                if (r.jit) |*j| if (try j.run(&r.state, &r.memory, r.options.max_instructions - r.state.instructions)) continue;
            }
            try r.step();
        }
        return r.exitCode().?;
    }
    pub fn fault(r: *Runtime, err: anyerror, path: []const u8) !void {
        try host.print(2, "UNIVERSE FAULT: {s}\nBinary: {s}\nGuest architecture: {s}\nGuest PC: 0x{x:0>16}\nInstructions: {d}\n", .{ @errorName(err), path, @tagName(r.state.architecture), r.fault_pc, r.state.instructions });
        if (r.memory.fault) |f| try host.print(2, "Invalid guest memory {s}: address=0x{x:0>16} size={d}\n", .{ @tagName(f.access), f.address, f.size });
        if (err == error.UnsupportedSyscall) try host.print(2, "Linux syscall number: {d}\n", .{r.linux.last_number});
        if (r.macos) |mac| if (err == error.UnsupportedMacOSSyscall or err == error.UnsupportedMacOSSyscallClass) try host.print(2, "Darwin syscall number: 0x{x}\n", .{mac.last_number});
        try host.output(2, "Bytes:");
        for (0..15) |n| {
            const b = r.memory.readInt(r.fault_pc +% n, 8, .execute) catch break;
            try host.print(2, " {x:0>2}", .{b});
        }
        try host.output(2, "\nUse: universe --trace-instructions --syscalls <binary>\n");
    }
    pub fn stats(r: *Runtime) !void {
        if (r.jit) |j| try host.print(2, "jit_blocks_compiled={d} jit_cache_hits={d} jit_code_bytes={d} jit_compile_ns={d}\n", .{ j.compiled, j.hits, j.blocks.items.len * j.page_size, j.compile_ns });
        const elapsed = (try host.nowNs()) - r.started;
        try host.print(2, "instructions={d} syscalls={d} guest_memory_bytes={d} elapsed_ns={d}\n", .{ r.state.instructions, if (r.windows) |w| w.calls else if (r.macos) |mac| mac.calls else r.linux.calls, r.memory.used, elapsed });
    }
};
