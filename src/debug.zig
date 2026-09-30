const std = @import("std");
const host = @import("host.zig");
const Runtime = @import("runtime.zig").Runtime;
fn number(t: ?[]const u8) !u64 {
    return std.fmt.parseInt(u64, t orelse return error.MissingArgument, 0) catch error.InvalidNumber;
}
fn line(buf: []u8) !?[]const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        var b: [1]u8 = undefined;
        const got = host.c.read(0, &b, 1);
        if (got < 0) return error.HostReadFailed;
        if (got == 0) return if (n == 0) null else buf[0..n];
        if (b[0] == '\n') return buf[0..n];
        buf[n] = b[0];
        n += 1;
    }
    return error.CommandTooLong;
}
fn registers(r: *Runtime) !void {
    for (r.state.registers[0..if (r.state.architecture == .x86_64) 16 else 32], 0..) |_, i| try host.print(1, "r{d:0>2}=0x{x:0>16}{s}", .{ i, r.state.get(@intCast(i)), if (i % 4 == 3) "\n" else "  " });
    try host.print(1, "PC=0x{x:0>16} SP=0x{x:0>16} flags=0x{x}\n", .{ r.state.pc, r.state.get(r.state.stackRegister()), r.state.flags.bits() });
}
fn memory(r: *Runtime, address: u64, count: u64) !void {
    for (0..@min(count, 256)) |i| {
        if (i % 16 == 0) try host.print(1, "0x{x:0>16}:", .{address +% i});
        const v = try r.memory.readInt(address +% i, 8, .read);
        try host.print(1, " {x:0>2}{s}", .{ v, if (i % 16 == 15) "\n" else "" });
    }
    try host.output(1, "\n");
}
fn command(r: *Runtime, cmd: []const u8, t: *std.mem.TokenIterator(u8, .any), bp: *?u64) !bool {
    if (std.mem.eql(u8, cmd, "quit")) return false;
    if (std.mem.eql(u8, cmd, "help")) {
        try host.output(1, "run | continue | step [count] | break <address> | clear | registers\nmemory <address> [bytes] | disasm [address] [count] | stack | ir | syscalls | quit\nRegister indices: x86 RAX=0 RCX=1 RDX=2 RBX=3 RSP=4 RBP=5 RSI=6 RDI=7; ARM/RISC-V use architectural numbering.\n");
    } else if (std.mem.eql(u8, cmd, "break")) {
        bp.* = try number(t.next());
        try host.print(1, "Breakpoint at 0x{x}\n", .{bp.*.?});
    } else if (std.mem.eql(u8, cmd, "clear")) bp.* = null else if (std.mem.eql(u8, cmd, "registers")) try registers(r) else if (std.mem.eql(u8, cmd, "syscalls")) {
        const trace = if (r.windows) |*w| &w.trace else if (r.macos) |*mac| &mac.trace else &r.linux.trace;
        trace.* = !trace.*;
        try host.print(1, "Syscall tracing: {s}\n", .{if (trace.*) "on" else "off"});
    } else if (std.mem.eql(u8, cmd, "memory")) {
        const addr = try number(t.next());
        try memory(r, addr, if (t.next()) |v| try number(v) else 64);
    } else if (std.mem.eql(u8, cmd, "stack")) try memory(r, r.state.get(r.state.stackRegister()), 128) else if (std.mem.eql(u8, cmd, "ir")) try @import("format.zig").instruction(1, try r.decode(r.state.pc)) else if (std.mem.eql(u8, cmd, "disasm")) {
        var pc = if (t.next()) |v| try number(v) else r.state.pc;
        const count = if (t.next()) |v| try number(v) else 8;
        for (0..@min(count, 256)) |_| {
            const inst = try r.decode(pc);
            try @import("format.zig").instruction(1, inst);
            pc = inst.next;
        }
    } else if (std.mem.eql(u8, cmd, "step")) {
        const count = if (t.next()) |v| try number(v) else 1;
        for (0..@min(count, 100000)) |_| {
            if (r.exitCode() != null) break;
            try r.step();
        }
        try host.print(1, "PC=0x{x}\n", .{r.state.pc});
    } else if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "continue")) {
        var first = std.mem.eql(u8, cmd, "continue");
        while (r.exitCode() == null) {
            if (!first and bp.* != null and r.state.pc == bp.*.?) {
                try host.print(1, "Breakpoint hit at 0x{x}\n", .{r.state.pc});
                break;
            }
            first = false;
            try r.step();
        }
    } else return error.UnknownCommand;
    return true;
}
pub fn run(r: *Runtime) !u8 {
    var buf: [1024]u8 = undefined;
    var bp: ?u64 = null;
    try host.output(1, "UNIVERSE debugger. Type help for commands.\n");
    while (r.exitCode() == null) {
        try host.output(1, "(universe) ");
        const text = (try line(&buf)) orelse break;
        var t = std.mem.tokenizeAny(u8, text, " \t\r");
        const cmd = t.next() orelse continue;
        const keep = command(r, cmd, &t, &bp) catch |err| switch (err) {
            error.UnknownCommand, error.InvalidNumber, error.MissingArgument => {
                try host.print(1, "Command error: {s}\n", .{@errorName(err)});
                continue;
            },
            else => return err,
        };
        if (!keep) break;
    }
    if (r.exitCode()) |code| try host.print(1, "Guest exited: {d}\n", .{code});
    return r.exitCode() orelse 0;
}
