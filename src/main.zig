const std = @import("std");
const host = @import("host.zig");
const elf = @import("loader/elf.zig");
const Runtime = @import("runtime.zig").Runtime;
const help =
    \\UNIVERSE 0.1.0 — Run software that was never built for your computer.
    \\Usage: universe [run|inspect|disasm|trace|debug] [options] <binary> [guest args...]
    \\  --help, --version          Show help or version
    \\  --ir                      Dump decoded UIR (inspect or disasm)
    \\  --arch NAME               Require x86_64, riscv64 or arm64
    \\  --syscalls                Trace Linux syscalls to stderr
    \\  --trace-instructions      Trace decoded instructions to stderr
    \\  --jit                     ARM64-host native register-block translation
    \\  --stats                   Report instructions, memory and elapsed time
    \\  --max-instructions N      Execution limit (default 10000000)
    \\  --timeout-ms N            Execution time limit (default 10000; 0 disables)
    \\  --count N                 Disassembly limit (default 64)
    \\  --env KEY=VALUE           Add an explicit guest environment variable
    \\  --allow-files             Allow host file access with host user privileges
    \\  --sysroot DIR             Prefix absolute Linux paths (not a sandbox)
    \\Guest environment is empty by default. This runtime is not a security sandbox.
    \\
;
pub fn main(init: std.process.Init) void {
    const a = init.arena.allocator();
    const args = init.minimal.args.toSlice(a) catch {
        std.process.exit(125);
    };
    const code = cli(a, args[1..]) catch |err| {
        host.print(2, "UNIVERSE: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(125);
    };
    std.process.exit(code);
}
fn cli(a: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        try host.output(1, help);
        return 0;
    }
    var command: []const u8 = "run";
    var i: usize = 0;
    for ([_][]const u8{ "run", "inspect", "disasm", "trace", "debug" }) |name| if (std.mem.eql(u8, args[0], name)) {
        command = name;
        i = 1;
        break;
    };
    var options = @import("runtime.zig").Options{};
    var stats = false;
    var dump = false;
    var count: u64 = 64;
    var arch: ?[]const u8 = null;
    var env: std.ArrayList([]const u8) = .empty;
    defer env.deinit(a);
    if (std.mem.eql(u8, command, "trace")) options.syscalls = true;
    while (i < args.len and std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, flag, "--help")) {
            try host.output(1, help);
            return 0;
        }
        if (std.mem.eql(u8, flag, "--version")) {
            try host.output(1, "UNIVERSE 0.1.0\n");
            return 0;
        }
        if (std.mem.eql(u8, flag, "--jit")) options.jit = true else if (std.mem.eql(u8, flag, "--stats")) stats = true else if (std.mem.eql(u8, flag, "--syscalls")) options.syscalls = true else if (std.mem.eql(u8, flag, "--trace-instructions")) options.trace_instructions = true else if (std.mem.eql(u8, flag, "--allow-files")) options.allow_files = true else if (std.mem.eql(u8, flag, "--ir")) dump = true else if (std.mem.eql(u8, flag, "--env")) {
            i += 1;
            if (i >= args.len or std.mem.indexOfScalar(u8, args[i], '=') == null) return error.InvalidEnvironment;
            try env.append(a, args[i]);
        } else if (std.mem.eql(u8, flag, "--sysroot")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingOptionValue;
            options.sysroot = args[i];
        } else if (std.mem.eql(u8, flag, "--arch")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            arch = args[i];
        } else if (std.mem.eql(u8, flag, "--max-instructions") or std.mem.eql(u8, flag, "--timeout-ms") or std.mem.eql(u8, flag, "--count")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            const n = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidOptionValue;
            if (std.mem.eql(u8, flag, "--max-instructions")) options.max_instructions = n else if (std.mem.eql(u8, flag, "--timeout-ms")) {
                if (n > 86_400_000) return error.InvalidOptionValue;
                options.timeout_ms = n;
            } else count = @min(n, 100000);
        } else return error.UnknownOption;
    }
    if (i >= args.len) return error.MissingBinary;
    const path = args[i];
    const bytes = try host.readFile(a, path);
    defer a.free(bytes);
    if (std.mem.startsWith(u8, bytes, "MZ")) {
        const image = try @import("loader/pe.zig").parse(bytes);
        if (arch) |name| if (!std.mem.eql(u8, name, "x86_64")) return error.ArchitectureMismatch;
        if (std.mem.eql(u8, command, "inspect")) {
            try host.print(1, "Format: PE32+\nArchitecture: x86_64\nImage kind: {s}\nEntry point: {?x}\nImage base: 0x{x}\nSections: {d}\nRequired OS: Windows\n", .{ if (image.is_dll) "DLL" else "executable", if (image.entry_rva == 0) @as(?u64, null) else image.base + image.entry_rva, image.base, image.section_count });
            if (!dump) return 0;
        }
        if (env.items.len != 0) return error.WindowsEnvironmentUnsupported;
        var runtime = try Runtime.initPE(a, image, args[i..], options);
        defer runtime.deinit();
        return execute(&runtime, command, dump, count, stats, path);
    }
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\xcf\xfa\xed\xfe")) {
        const image = try @import("loader/macho.zig").parse(bytes);
        if (!std.mem.eql(u8, command, "inspect") or dump) return error.MachOExecutionUnsupported;
        if (arch) |name| if (!std.mem.eql(u8, name, @tagName(image.architecture))) return error.ArchitectureMismatch;
        try host.print(1, "Format: Mach-O64\nArchitecture: {s}\nLoad commands: {d}\nSegments: {d}\nLibraries: {d}\nEntry point: {?x}\nExecution: unsupported\n", .{ @tagName(image.architecture), image.commands, image.segments, image.libraries, image.entry });
        return 0;
    }
    const image = try elf.parse(bytes);
    if (arch) |name| if (!std.mem.eql(u8, name, @tagName(image.architecture))) return error.ArchitectureMismatch;
    if (std.mem.eql(u8, command, "inspect")) {
        try host.print(1, "Format: ELF64 little-endian\nArchitecture: {s}\nEntry point: 0x{x}\nInterpreter: {s}\nSections: {d}\nProgram headers: {d}\nRequired OS ABI: Linux (execution subset)\n", .{ @tagName(image.architecture), image.entry, image.interpreter orelse "none", image.shnum, image.phnum });
        for (0..image.phnum) |n| {
            const seg = try image.segment(n);
            if (seg.kind == 1) try host.print(1, "LOAD 0x{x} filesz={d} memsz={d} permissions={s}{s}{s}\n", .{ seg.address, seg.filesz, seg.memsz, if (seg.flags & 4 != 0) "r" else "-", if (seg.flags & 2 != 0) "w" else "-", if (seg.flags & 1 != 0) "x" else "-" });
        }
        if (!dump) return 0;
    }
    var runtime = try Runtime.init(a, image, args[i..], env.items, options);
    defer runtime.deinit();
    return execute(&runtime, command, dump, count, stats, path);
}
fn execute(runtime: *Runtime, command: []const u8, dump: bool, count: u64, stats: bool, path: []const u8) !u8 {
    if (dump or std.mem.eql(u8, command, "disasm")) {
        var pc = runtime.state.pc;
        for (0..count) |_| {
            const inst = runtime.decode(pc) catch |err| {
                try host.print(2, "Disassembly stopped at 0x{x}: {s}\n", .{ pc, @errorName(err) });
                break;
            };
            try @import("format.zig").instruction(1, inst);
            pc = inst.next;
        }
        return 0;
    }
    const code = (if (std.mem.eql(u8, command, "debug")) @import("debug.zig").run(runtime) else runtime.run()) catch |err| {
        try runtime.fault(err, path);
        return 125;
    };
    if (stats) try runtime.stats();
    return code;
}
test {
    _ = @import("loader/elf.zig");
    _ = @import("loader/pe.zig");
    _ = @import("loader/macho.zig");
    _ = @import("syscall/windows.zig");
    _ = @import("memory.zig");
    _ = @import("cpu/x86_64.zig");
    _ = @import("cpu/riscv64.zig");
    _ = @import("cpu/arm64.zig");
    _ = @import("interpreter.zig");
    _ = @import("jit.zig");
    _ = @import("process.zig");
    _ = @import("syscall/linux.zig");
}
