const std = @import("std");
const host = @import("host.zig");
const elf = @import("loader/elf.zig");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
const Linux = @import("syscall/linux.zig").Linux;
const Device = @import("linux_device.zig").Device;
const ir = @import("ir.zig");
const Process = struct { memory: Memory, state: State, linux: Linux };
pub const Options = struct { jit: bool = false, allow_files: bool = false, sysroot: ?[:0]const u8 = null, syscalls: bool = false, trace_instructions: bool = false, max_instructions: u64 = 10_000_000, timeout_ms: u64 = 10000 };
fn loadLinux(a: std.mem.Allocator, input: elf.Image, args: []const [:0]const u8, env: []const []const u8, options: Options, limit: usize, executable: ?[]const u8) !Process {
    var m = Memory.init(a);
    errdefer m.deinit();
    m.limit = limit;
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
        const bytes = try (if (executable != null) host.readExecutable(a, path) else host.readFile(a, path));
        defer a.free(bytes);
        var interpreter = try elf.parse(bytes);
        if (interpreter.architecture != image.architecture) return error.ArchitectureMismatch;
        if (interpreter.interpreter != null) return error.RecursiveInterpreterUnsupported;
        interpreter.bias = if (interpreter.kind == 3) 0x700000000000 else 0;
        _ = try interpreter.load(&m);
        interpreter_base = interpreter.bias;
        state.pc = try interpreter.entryAddress();
    }
    try @import("process.zig").stack(a, &m, &state, image, args, env, interpreter_base, executable orelse if (args.len != 0) args[0] else "");
    var linux = Linux{ .allocator = a, .allow_files = options.allow_files, .sysroot = options.sysroot, .trace = options.syscalls, .heap_base = heap, .heap_end = heap, .heap_limit = heap + 16 * 1024 * 1024 };
    errdefer linux.deinit();
    try linux.setProcessArgs(args, executable orelse if (args.len != 0) args[0] else "");
    return .{ .memory = m, .state = state, .linux = linux };
}
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
    processes: std.ArrayList(?Process) = .empty,
    current_process: usize = 0,
    process_quantum: u64 = 0,
    process_yield: bool = false,
    next_task_id: u32 = 2,
    memory_budget: ?*Memory.Budget = null,
    proc_table: ?*Device.ProcessTable = null,
    syscalls: u64 = 0,
    pub fn init(a: std.mem.Allocator, input: elf.Image, args: []const [:0]const u8, env: []const []const u8, options: Options) !Runtime {
        var jit = if (options.jit) try @import("jit.zig").Jit.init(a) else null;
        errdefer if (jit) |*j| j.deinit();
        var process = try loadLinux(a, input, args, env, options, 256 * 1024 * 1024, null);
        errdefer process.memory.deinit();
        errdefer process.linux.deinit();
        const proc_table = try a.create(Device.ProcessTable);
        errdefer a.destroy(proc_table);
        proc_table.* = .{};
        const started = try host.nowNs();
        process.linux.boot_ns = started;
        process.linux.start_ns = started;
        process.linux.proc_table = proc_table;
        return .{ .memory = process.memory, .state = process.state, .linux = process.linux, .proc_table = proc_table, .jit = jit, .options = options, .started = started };
    }
    pub fn initPE(a: std.mem.Allocator, image: @import("loader/pe.zig").Image, args: []const [:0]const u8, env: []const []const u8, options: Options) !Runtime {
        if (image.is_dll) return error.WindowsDLLExecutionUnsupported;
        var jit = if (options.jit) try @import("jit.zig").Jit.init(a) else null;
        errdefer if (jit) |*j| j.deinit();
        var m = Memory.init(a);
        errdefer m.deinit();
        try image.load(&m, image.base);
        var windows = @import("syscall/windows.zig").Windows{ .allocator = a, .module_base = image.base, .trace = options.syscalls, .allow_files = options.allow_files, .sysroot = options.sysroot };
        errdefer windows.deinit();
        try windows.bind(image, &m, args[0]);
        try windows.initProcess(&m, args, env);
        const top = @import("process.zig").stack_top;
        try m.map(top - 1024 * 1024, 1024 * 1024, .{ .read = true, .write = true });
        var state = State{ .architecture = .x86_64, .pc = image.base + image.entry_rva };
        // Win64 callers reserve four 8-byte home slots even for an argument-free entry point.
        state.set(4, top - 40);
        try m.writeInt(top - 40, 64, 0);
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
        if (r.windows) |w| return w.exit_code;
        if (r.macos == null and r.linux.pid != 1) return null;
        return r.linux.exit_code;
    }
    pub fn deinit(r: *Runtime) void {
        if (r.jit) |*j| j.deinit();
        if (r.windows) |*w| w.deinit();
        r.linux.deinit();
        r.memory.deinit();
        for (r.processes.items) |*saved| if (saved.*) |*process| {
            process.linux.deinit();
            process.memory.deinit();
        };
        r.processes.deinit(r.linux.allocator);
        if (r.proc_table) |table| r.linux.allocator.destroy(table);
        if (r.memory_budget) |budget| r.linux.allocator.destroy(budget);
    }
    fn forkProcess(r: *Runtime) !u64 {
        var slot = r.processes.items.len;
        for (r.processes.items, 0..) |saved, index| if (saved == null and index != r.current_process) {
            slot = index;
            break;
        };
        if (slot >= 64 or r.next_task_id > std.math.maxInt(i32)) return @import("syscall/linux.zig").negative(11);
        const a = r.linux.allocator;
        try r.processes.ensureUnusedCapacity(a, if (r.processes.items.len == 0) 2 else @intFromBool(slot == r.processes.items.len));
        if (r.memory_budget == null) {
            const budget = try a.create(Memory.Budget);
            budget.* = .{ .limit = r.memory.limit, .used = r.memory.used };
            r.memory_budget = budget;
            r.memory.budget = budget;
        }
        var child = Process{ .memory = try r.memory.fork(a), .state = r.state, .linux = undefined };
        errdefer child.memory.deinit();
        child.linux = try r.linux.fork(r.next_task_id);
        child.linux.start_ns = try host.nowNs();
        child.state.set(if (r.state.architecture == .riscv64) 10 else 0, 0);
        child.state.exclusive = null;
        if (r.processes.items.len == 0) {
            r.processes.appendAssumeCapacity(null);
            slot = 1;
        }
        if (slot == r.processes.items.len) r.processes.appendAssumeCapacity(child) else r.processes.items[slot] = child;
        const pid = r.next_task_id;
        r.next_task_id += 1;
        r.process_yield = true;
        return pid;
    }
    fn waitProcess(r: *Runtime, args: [6]u64) !u64 {
        const negative = @import("syscall/linux.zig").negative;
        const pid: i32 = @bitCast(@as(u32, @truncate(args[0])));
        const options: u32 = @truncate(args[2]);
        if (pid == std.math.minInt(i32)) return negative(3);
        if (options & ~@as(u32, 1 | 2 | 8 | 0xe0000000) != 0) return negative(22);
        if (args[3] != 0) return negative(38); // Resource-usage accounting is not implemented.
        var matching = false;
        for (r.processes.items) |*saved| if (saved.*) |*child| {
            if (child.linux.parent_pid != r.linux.pid) continue;
            if (pid > 0 and child.linux.pid != pid or pid < -1) continue; // All processes remain in virtual group 1.
            if (options & 0x80000000 != 0 and options & 0x40000000 == 0) continue;
            if (options & 0x20000000 != 0 and child.linux.creator_tid != r.linux.threads.id()) continue;
            matching = true;
            if (child.linux.exit_code) |code| {
                const child_pid = child.linux.pid;
                const status: u32 = if (child.linux.exit_signal != 0) child.linux.exit_signal else @as(u32, code) << 8;
                child.linux.deinit();
                child.memory.deinit();
                saved.* = null; // Linux reaps before copying the status; an EFAULT still consumes this child.
                if (args[1] != 0) try r.memory.writeInt(args[1], 32, status);
                return child_pid;
            }
        };
        if (!matching) return negative(10);
        if (options & 1 != 0) return 0;
        try r.linux.threads.retryAfter(r.linux.allocator, r.state, (try host.nowNs()) +| 1_000_000, true);
        return error.SyscallPending;
    }
    fn execProcess(r: *Runtime, args: [6]u64) !u64 {
        const negative = @import("syscall/linux.zig").negative;
        if (!r.linux.allow_files) return negative(13);
        const a = r.linux.allocator;
        const path = r.memory.cstring(a, args[0], 4096) catch |err| return if (err == error.StringTooLong) negative(36) else err;
        defer a.free(path);
        const host_path = try @import("filesystem.zig").resolve(a, r.linux.sysroot, path);
        defer a.free(host_path);
        const bytes = host.readExecutable(a, host_path) catch |err| return execLoadError(err);
        defer a.free(bytes);
        const image = elf.parse(bytes) catch return negative(8);
        if (image.architecture != r.state.architecture) return negative(8);
        const process = @import("process.zig");
        var remaining: usize = process.stack_size / 4 - path.len - 1;
        var argv = try process.copyStrings(a, &r.memory, args[1], &remaining);
        defer process.freeStrings(a, &argv);
        if (argv.items.len == 0) {
            if (remaining < 9) return error.ArgumentListTooLong;
            remaining -= 9;
            const empty = try a.dupeZ(u8, "");
            argv.append(a, empty) catch |err| {
                a.free(empty);
                return err;
            };
        }
        var envp = try process.copyStrings(a, &r.memory, args[2], &remaining);
        defer process.freeStrings(a, &envp);
        const env = try a.alloc([]const u8, envp.items.len);
        defer a.free(env);
        for (envp.items, env) |text, *view| view.* = text;
        var options = r.options;
        options.allow_files = r.linux.allow_files;
        options.sysroot = r.linux.sysroot;
        const allowance = if (r.memory_budget) |budget| @min(r.memory.limit, budget.limit - budget.used + r.memory.used) else r.memory.limit;
        // ponytail: stage a bounded full image for rollback; use streaming/COW only for measured exec memory pressure.
        var next = loadLinux(a, image, argv.items, env, options, allowance, path) catch |err| return execLoadError(err);
        defer next.memory.deinit();
        defer next.linux.deinit();
        if (r.options.timeout_ms != 0 and (try host.nowNs()) - r.started >= r.options.timeout_ms * 1_000_000) return error.ExecutionTimeout;
        next.state.instructions = r.state.instructions;
        try r.memory.replaceAll(&next.memory);
        r.state = next.state;
        r.linux.afterExecImage(&next.linux);
        for (r.processes.items) |*saved| if (saved.*) |*child| {
            if (child.linux.parent_pid == r.linux.pid) child.linux.creator_tid = r.linux.pid;
        };
        if (r.jit) |*jit| jit.clear();
        return 0;
    }
    fn execLoadError(err: anyerror) !u64 {
        const negative = @import("syscall/linux.zig").negative;
        return switch (err) {
            error.BinaryAccessDenied, error.UnsupportedBinaryFile, error.FileAccessDenied => negative(13),
            error.BinaryFileLimit => negative(24),
            error.CannotOpenBinary, error.CannotReadBinary => @import("syscall/linux.zig").hostError(),
            error.MissingSysroot => negative(2),
            error.BinaryTooLarge, error.NotELF, error.TruncatedBinary, error.ELF32Unsupported, error.BigEndianUnsupported, error.InvalidELFHeader, error.UnsupportedOSABI, error.UnsupportedArchitecture, error.InvalidProgramHeaders, error.InvalidSections, error.UnsupportedELFType, error.TruncatedSegment, error.InvalidInterpreter, error.InvalidSegmentSize, error.AddressOverflow, error.InvalidSegmentAlignment, error.InvalidSegmentPermissions, error.InvalidEntryPoint, error.InvalidLoadBias, error.ArchitectureMismatch, error.RecursiveInterpreterUnsupported, error.UnmappedProgramHeaders, error.OverlappingMapping, error.UnmappedMemory, error.PermissionDenied => negative(8),
            else => Linux.resultForError(err),
        };
    }
    fn switchProcess(r: *Runtime, index: usize) void {
        const instructions = r.state.instructions;
        const next = r.processes.items[index].?;
        r.processes.items[r.current_process] = if (r.linux.auto_reap) null else .{ .memory = r.memory, .state = r.state, .linux = r.linux };
        r.memory = next.memory;
        r.state = next.state;
        r.state.instructions = instructions;
        r.state.exclusive = null;
        r.linux = next.linux;
        r.processes.items[index] = null;
        r.current_process = index;
        if (r.jit) |*j| j.clear(); // Equal memory generations in different processes never share cached code.
    }
    fn finishProcess(r: *Runtime) void {
        if (r.linux.pid == 1 or r.linux.exit_code == null) return;
        for (r.processes.items) |*saved| if (saved.*) |*parent| {
            if (parent.linux.pid == r.linux.parent_pid and parent.linux.exit_code == null) {
                const action = parent.linux.signal_actions[16];
                const ignored = std.mem.readInt(u64, action[0..8], .little) == 1;
                r.linux.auto_reap = ignored or std.mem.readInt(u64, action[8..16], .little) & 2 != 0;
                parent.linux.queueSignal(17, @import("linux_signals.zig").makeInfo(17, if (r.linux.exit_signal != 0) 2 else 1, r.linux.pid, 1000, if (r.linux.exit_signal != 0) r.linux.exit_signal else r.linux.exit_code.?));
                break;
            }
        };
        r.linux.releaseResources();
        r.linux.threads = .{ .initial_id = r.linux.pid };
        r.memory.deinit();
        r.memory = Memory.init(r.linux.allocator);
        for (r.processes.items) |*saved| if (saved.*) |*child| {
            if (child.linux.parent_pid == r.linux.pid) child.linux.parent_pid = 1;
        };
    }
    fn signalProcess(r: *Runtime, args: [6]u64) !u64 {
        const negative = @import("syscall/linux.zig").negative;
        const pid: i32 = @bitCast(@as(u32, @truncate(args[0])));
        const sig: i32 = @bitCast(@as(u32, @truncate(args[1])));
        if (sig < 0 or sig > 64) return negative(22);
        // ponytail: standard signal coalescing only; implement real-time queues and stop/continue together with checked fixtures.
        if (sig >= 32 or sig >= 18 and sig <= 22) return negative(38);
        var found = false;
        const info = @import("linux_signals.zig").makeInfo(@intCast(sig), 0, r.linux.pid, 1000, 0);
        if (pid == 0 or pid > 0 and (r.linux.pid == pid or r.linux.threads.contains(@intCast(pid)))) {
            found = true;
            if (sig != 0 and r.linux.exit_code == null) r.linux.queueSignal(@intCast(sig), info);
        }
        for (r.processes.items) |*saved| if (saved.*) |*process| {
            if (pid == -1 and process.linux.pid != 1 and process.linux.pid != r.linux.pid or pid == 0 or pid > 0 and (process.linux.pid == pid or process.linux.threads.contains(@intCast(pid)))) {
                found = true;
                if (sig != 0 and process.linux.exit_code == null) process.linux.queueSignal(@intCast(sig), info);
            }
        };
        return if (found) 0 else negative(3);
    }
    fn processReady(r: *Runtime) !bool {
        if (r.linux.exit_code != null) return false;
        try r.linux.pollSignals(&r.state, &r.memory);
        if (r.linux.exit_code != null) {
            r.finishProcess();
            return false;
        }
        return r.linux.threads.schedule(&r.state);
    }
    fn schedule(r: *Runtime) !bool {
        const ready = try r.processReady();
        if (ready and !r.process_yield and r.state.instructions - r.process_quantum < 4096) return true;
        r.process_yield = false;
        const start = r.current_process;
        for (1..r.processes.items.len + 1) |offset| {
            const index = (start + offset) % r.processes.items.len;
            if (index != r.current_process) {
                const next = r.processes.items[index] orelse continue;
                if (next.linux.exit_code != null) continue;
                r.switchProcess(index);
            }
            if (try r.processReady()) {
                r.process_quantum = r.state.instructions;
                return true;
            }
        }
        if (ready) {
            r.process_quantum = r.state.instructions;
            return true;
        }
        // Every guest process/thread is blocked; keep checking the shared execution deadline.
        const delay = host.c.struct_timespec{ .tv_sec = 0, .tv_nsec = 1_000_000 };
        if (host.c.nanosleep(&delay, null) != 0 and host.errno() != host.c.EINTR) return error.HostClockFailed;
        return false;
    }
    fn dispatchLinux(r: *Runtime) !void {
        try r.refreshProcTable();
        r.linux.threads.next_id = r.next_task_id;
        r.linux.process_count = 1;
        for (r.processes.items) |saved| if (saved) |process| {
            if (process.linux.exit_code == null) r.linux.process_count += 1;
        };
        const before = r.linux.calls;
        r.linux.dispatch(&r.state, &r.memory) catch |err| {
            if (err != error.ProcessFork and err != error.ProcessWait and err != error.ProcessExec and err != error.ProcessSignal) return err;
            const args = Linux.arguments(r.state);
            const op = try @import("syscall/linux.zig").operation(r.state, r.linux.last_number);
            const result = (if (err == error.ProcessFork) r.forkProcess() else if (err == error.ProcessExec) r.execProcess(args) else if (err == error.ProcessSignal) r.signalProcess(args) else r.waitProcess(args)) catch |failure| blk: {
                if (failure == error.SyscallPending) {
                    try r.linux.pending(&r.state, op);
                    r.syscalls += r.linux.calls - before;
                    return;
                }
                break :blk try Linux.resultForError(failure);
            };
            r.memory.fault = null;
            try r.linux.complete(&r.state, op, args, result);
        };
        r.next_task_id = @max(r.next_task_id, r.linux.threads.next_id);
        r.syscalls += r.linux.calls - before;
        r.finishProcess();
    }
    fn refreshProcTable(r: *Runtime) !void {
        const table = r.proc_table orelse return;
        table.clear();
        try table.append(procInfo(r.linux, r.memory));
        for (r.processes.items) |saved| if (saved) |process| {
            try table.append(procInfo(process.linux, process.memory));
        };
    }
    fn procInfo(linux: Linux, memory: Memory) Device.Process {
        return .{
            .pid = linux.pid,
            .parent_pid = linux.parent_pid,
            .state = if (linux.exit_code != null) 'Z' else linux.threads.processState(),
            .comm = linux.comm,
            .comm_len = linux.comm_len,
            .cmdline = linux.command_line,
            .memory_bytes = memory.used,
            .threads = linux.threads.processThreadCount(),
            .start_ticks = if (linux.start_ns >= linux.boot_ns) (linux.start_ns - linux.boot_ns) / 10_000_000 else 0,
        };
    }
    pub fn decode(r: *Runtime, pc: u64) !ir.Instruction {
        return @import("cpu.zig").decode(&r.memory, r.state.architecture, pc);
    }
    fn limits(r: *Runtime) !bool {
        if (r.windows) |*w| try w.pollControl(&r.state, &r.memory);
        r.fault_pc = r.state.pc;
        if (r.state.instructions >= r.options.max_instructions) return error.InstructionLimit;
        const waiting = if (r.windows) |w| w.wait != null else if (r.macos == null) r.linux.threads.blocked() or r.linux.exit_code != null else false;
        if (waiting or r.state.instructions == 0 or r.state.instructions - r.last_clock_check >= 4096) {
            r.last_clock_check = r.state.instructions;
            if (r.options.timeout_ms != 0 and (try host.nowNs()) - r.started >= r.options.timeout_ms * 1_000_000) return error.ExecutionTimeout;
        }
        if (r.windows == null and r.macos == null and r.exitCode() == null) {
            const ready = try r.schedule();
            r.fault_pc = r.state.pc;
            return ready;
        }
        return true;
    }
    pub fn step(r: *Runtime) !void {
        if (!try r.limits()) return;
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
            if (r.macos) |*mac| try mac.dispatch(&r.linux, &r.state, &r.memory) else try r.dispatchLinux();
        }
    }
    pub fn run(r: *Runtime) !u8 {
        while (r.exitCode() == null) {
            if (!try r.limits()) continue;
            if (r.exitCode() != null) break;
            if (!r.options.trace_instructions) {
                if (r.jit) |*j| if (try j.run(&r.state, &r.memory, r.options.max_instructions - r.state.instructions)) continue;
            }
            try r.step();
        }
        if (r.windows) |*w| try w.mappings.flushAll();
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
        try host.print(2, "instructions={d} syscalls={d} guest_memory_bytes={d} elapsed_ns={d}\n", .{ r.state.instructions, if (r.windows) |w| w.calls else if (r.macos) |mac| mac.calls else r.syscalls, if (r.memory_budget) |budget| budget.used else r.memory.used, elapsed });
    }
};

test "exec stages a complete image and survives each allocation failure without changing the running process" {
    const a = std.testing.allocator;
    var binary: [192]u8 = @splat(0);
    @memcpy(binary[0..7], "\x7fELF\x02\x01\x01");
    for ([_]struct { offset: usize, value: u64 }{
        .{ .offset = 16, .value = 2 | (243 << 16) | (@as(u64, 1) << 32) },
        .{ .offset = 24, .value = 0x1080 },
        .{ .offset = 32, .value = 64 },
        .{ .offset = 52, .value = 64 | (56 << 16) | (@as(u64, 1) << 32) },
        .{ .offset = 64, .value = 1 | (@as(u64, 7) << 32) },
        .{ .offset = 80, .value = 0x1000 },
        .{ .offset = 96, .value = binary.len },
        .{ .offset = 104, .value = 4096 },
        .{ .offset = 112, .value = 4096 },
        .{ .offset = 128, .value = 0x00200093 }, // ADDI x1,x0,2.
    }) |field| std.mem.writeInt(u64, binary[field.offset..][0..8], field.value, .little);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "exec", .data = &binary });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "exec", a);
    defer a.free(path);
    const fd = host.c.open(path.ptr, host.c.O_RDONLY | host.c.O_CLOEXEC);
    try std.testing.expect(fd >= 0);
    defer _ = host.c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), host.c.fchmod(fd, 0o755));
    var succeeded = false;
    for (0..40) |index| {
        var r = Runtime{ .memory = Memory.init(a), .state = .{ .architecture = .riscv64, .pc = 0x1080, .instructions = 99 }, .linux = .{ .allocator = a, .allow_files = true, .mask = 0o022 }, .options = .{}, .started = try host.nowNs() };
        defer r.deinit();
        try r.memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
        try r.memory.writeInt(0x1080, 32, 0x00100093);
        try r.memory.write(0x1200, path);
        try r.memory.writeInt(0x1200 + path.len, 8, 0);
        try r.memory.writeInt(0x1300, 64, 0x1400);
        try r.memory.write(0x1400, "renamed\x00");
        try r.memory.writeInt(0x1500, 64, 0x1600);
        try r.memory.write(0x1600, "KEY=é🚀\x00");
        r.linux.fd_flags[0] = 1;
        r.linux.threads.metadata().signal_mask = 42;
        r.linux.threads.metadata().clear_tid = 0x1700;
        r.state.set(4, 0xdead);
        try std.testing.expectEqual(@as(u64, 2), try r.forkProcess());
        r.memory_budget.?.limit = 8192;
        const args: [6]u64 = .{ 0x1200, 0x1300, 0x1500, 0, 0, 0 };
        const negative = @import("syscall/linux.zig").negative;
        try std.testing.expectEqual(negative(12), try r.execProcess(args));
        r.memory_budget.?.limit = 17 * 1024 * 1024 + 8192;
        if (@import("builtin").cpu.arch == .aarch64) {
            r.jit = try @import("jit.zig").Jit.init(a);
            try std.testing.expect(try r.jit.?.run(&r.state, &r.memory, 1));
            r.state.pc = 0x1080;
            r.state.instructions = 99;
        }
        const generation = r.memory.generation;
        const writes = r.memory.writes;
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        r.linux.allocator = failing.allocator();
        const result = r.execProcess(args) catch |err| blk: {
            try std.testing.expectEqual(error.OutOfMemory, err);
            break :blk negative(12);
        };
        if (result != 0) {
            try std.testing.expectEqual(negative(12), result);
            try std.testing.expectEqual(generation, r.memory.generation);
            try std.testing.expectEqual(writes, r.memory.writes);
            try std.testing.expectEqual(@as(usize, 8192), r.memory_budget.?.used);
            try std.testing.expectEqual(@as(u64, 0x1080), r.state.pc);
            try std.testing.expectEqual(@as(u64, 99), r.state.instructions);
            try std.testing.expectEqual(@as(u64, 0x1700), r.linux.threads.metadata().clear_tid);
            try std.testing.expect(r.linux.descriptors[0] != null);
            continue;
        }
        try std.testing.expectEqual(@as(u32, 1), r.linux.pid);
        try std.testing.expectEqual(@as(u64, 99), r.state.instructions);
        try std.testing.expectEqual(@as(usize, 17 * 1024 * 1024 + 8192), r.memory_budget.?.used);
        try std.testing.expectEqual(@as(u64, 0), r.state.get(4));
        try std.testing.expectEqual(@as(u64, 0), r.linux.threads.metadata().clear_tid);
        try std.testing.expectEqual(@as(u64, 42), r.linux.threads.metadata().signal_mask);
        try std.testing.expect(r.linux.descriptors[0] == null);
        try std.testing.expectEqual(@as(u64, 0x00100093), try r.processes.items[1].?.memory.readInt(0x1080, 32, .read));
        const sp = r.state.get(r.state.stackRegister());
        try std.testing.expectEqual(@as(u64, 1), try r.memory.readInt(sp, 64, .read));
        const name = try r.memory.cstring(a, try r.memory.readInt(sp + 8, 64, .read), 100);
        defer a.free(name);
        try std.testing.expectEqualStrings("renamed", name);
        if (r.jit) |*jit| {
            try std.testing.expectEqual(@as(usize, 0), jit.blocks.items.len);
            try std.testing.expect(try jit.run(&r.state, &r.memory, 1));
            try std.testing.expectEqual(@as(u64, 2), r.state.get(1));
        }
        succeeded = true;
        break;
    }
    try std.testing.expect(succeeded);
}

test "guest fork publication, private memory, shared budget and reaping survive allocation failures" {
    const a = std.testing.allocator;
    for (0..4) |failure| {
        var allocator = std.testing.FailingAllocator.init(a, .{ .fail_index = failure });
        var r = Runtime{ .memory = Memory.init(a), .state = .{ .architecture = .x86_64, .pc = 0x1000 }, .linux = .{ .allocator = allocator.allocator() }, .options = .{}, .started = try host.nowNs() };
        defer r.deinit();
        try r.memory.map(0x1000, 4096, .{ .read = true, .write = true });
        try r.memory.writeInt(0x1000, 64, 42);
        try std.testing.expectError(error.OutOfMemory, r.forkProcess());
        try std.testing.expectEqual(@as(usize, 0), r.processes.items.len);
        try std.testing.expectEqual(@as(u32, 2), r.next_task_id);
        try std.testing.expectEqual(@as(u64, 42), try r.memory.readInt(0x1000, 64, .read));
        if (r.memory_budget) |budget| try std.testing.expectEqual(@as(usize, 4096), budget.used);
    }
    for ([_]elf.Architecture{ .x86_64, .arm64, .riscv64 }) |architecture| {
        var r = Runtime{ .memory = Memory.init(a), .state = .{ .architecture = architecture, .pc = 0x1000 }, .linux = .{ .allocator = a }, .options = .{}, .started = try host.nowNs() };
        defer r.deinit();
        try r.memory.map(0x1000, 4096, .{ .read = true, .write = true });
        try r.memory.writeInt(0x1000, 64, 42);
        r.memory.limit = 8192;
        try std.testing.expectEqual(@as(u64, 2), try r.forkProcess());
        try std.testing.expectEqual(@as(usize, 8192), r.memory_budget.?.used);
        const negative = @import("syscall/linux.zig").negative;
        try std.testing.expectEqual(@as(u64, 0), try r.waitProcess(.{ 0xffffffffffffffff, 0, 1, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), try r.waitProcess(.{ 0, 0, 1, 0, 0, 0 }));
        try std.testing.expectEqual(negative(10), try r.waitProcess(.{ 1, 0, 1, 0, 0, 0 }));
        try std.testing.expectEqual(negative(10), try r.waitProcess(.{ 2, 0, 0x80000001, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), try r.waitProcess(.{ 2, 0, 0xc0000001, 0, 0, 0 }));
        try std.testing.expectEqual(negative(22), try r.waitProcess(.{ 2, 0, 4, 0, 0, 0 }));
        try std.testing.expectEqual(negative(38), try r.waitProcess(.{ 2, 0, 1, 0x1100, 0, 0 }));
        r.linux.threads.initial_id = 7;
        try std.testing.expectEqual(negative(10), try r.waitProcess(.{ 2, 0, 0x20000001, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), try r.waitProcess(.{ 2, 0, 1, 0, 0, 0 }));
        r.linux.threads.initial_id = 1;
        try std.testing.expectError(error.MemoryLimit, r.forkProcess());
        try std.testing.expectEqual(@as(u32, 3), r.next_task_id);
        r.switchProcess(1);
        try std.testing.expectEqual(@as(u32, 2), r.linux.pid);
        try std.testing.expectEqual(@as(u64, 0), r.state.get(if (architecture == .riscv64) 10 else 0));
        try r.memory.writeInt(0x1000, 64, 99);
        try std.testing.expectEqual(@as(u64, 42), try r.processes.items[0].?.memory.readInt(0x1000, 64, .read));
        r.linux.exit_code = 37;
        r.finishProcess();
        try std.testing.expectEqual(@as(usize, 4096), r.memory_budget.?.used);
        r.switchProcess(0);
        try std.testing.expectEqual(@as(u64, 2), try r.waitProcess(.{ 2, 0x1100, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 37 << 8), try r.memory.readInt(0x1100, 32, .read));
        try std.testing.expectEqual(@import("syscall/linux.zig").negative(10), try r.waitProcess(.{ 2, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 3), try r.forkProcess());
        r.switchProcess(1);
        r.linux.exit_code = 0;
        r.finishProcess();
        r.switchProcess(0);
        try std.testing.expectError(error.UnmappedMemory, r.waitProcess(.{ 3, 1, 0, 0, 0, 0 }));
        try std.testing.expect(r.processes.items[1] == null);
    }
}

test "process switches clear JIT blocks when independent code pages have equal generations" {
    if (@import("builtin").cpu.arch != .aarch64) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = Runtime{ .memory = Memory.init(a), .state = .{ .architecture = .riscv64, .pc = 0x1000 }, .linux = .{ .allocator = a }, .options = .{ .jit = true }, .started = try host.nowNs(), .jit = try @import("jit.zig").Jit.init(a) };
    defer r.deinit();
    try r.memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try r.memory.writeInt(0x1000, 32, 0x00100093); // ADDI x1,x0,1.
    try std.testing.expectEqual(@as(u64, 2), try r.forkProcess());
    try r.memory.writeInt(0x1000, 32, 0x00300093);
    try std.testing.expect(try r.jit.?.run(&r.state, &r.memory, 1));
    try std.testing.expectEqual(@as(u64, 3), r.state.get(1));
    r.switchProcess(1);
    try std.testing.expectEqual(@as(usize, 0), r.jit.?.blocks.items.len);
    try r.memory.writeInt(0x1000, 32, 0x00200093);
    try std.testing.expectEqual(r.memory.generation, r.processes.items[0].?.memory.generation);
    try std.testing.expect(try r.jit.?.run(&r.state, &r.memory, 1));
    try std.testing.expectEqual(@as(u64, 2), r.state.get(1));
    r.switchProcess(0);
    r.state.pc = 0x1000;
    try std.testing.expect(try r.jit.?.run(&r.state, &r.memory, 1));
    try std.testing.expectEqual(@as(u64, 3), r.state.get(1));
}
