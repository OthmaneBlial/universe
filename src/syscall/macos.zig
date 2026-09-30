//! Darwin BSD register, flag and errno conventions around the shared checked POSIX services.
const std = @import("std");
const host = @import("../host.zig");
const posix = @import("linux.zig");
const Memory = @import("../memory.zig").Memory;
const State = @import("../cpu/state.zig").State;
pub const main_return: u64 = 0x700000001000;
pub const MacOS = struct {
    calls: u64 = 0,
    last_number: u64 = 0,
    trace: bool = false,
    returns_main: bool = false,
    pub fn dispatch(mac: *MacOS, backend: *posix.Linux, s: *State, m: *Memory) !void {
        const raw = s.get(if (s.architecture == .x86_64) 0 else 16);
        mac.last_number = raw;
        if (s.architecture == .x86_64 and raw >> 24 != 2) return error.UnsupportedMacOSSyscallClass;
        if (s.architecture == .arm64 and raw > 0xffffff) return error.UnsupportedMacOSSyscallClass;
        const number = raw & 0xffffff;
        const registers: [6]u6 = if (s.architecture == .x86_64) .{ 7, 6, 2, 10, 8, 9 } else .{ 0, 1, 2, 3, 4, 5 };
        var args: [6]u64 = undefined;
        for (registers, 0..) |r, n| args[n] = s.get(r);
        const op: posix.Operation = switch (number) {
            1 => .exit,
            3 => .read,
            4 => .write,
            5 => .open,
            6 => .close,
            20 => .getpid,
            73 => .munmap,
            74 => .mprotect,
            121 => .writev,
            197 => .mmap,
            199 => .lseek,
            else => return error.UnsupportedMacOSSyscall,
        };
        // The service layer's open flag encodings use its supplied architecture.
        var canonical = State{ .architecture = .x86_64 };
        const valid = translate(s.architecture == .arm64, m.limit, op, &args);
        const value = if (!valid) posix.negative(22) else if ((op == .mmap or op == .mprotect) and args[1] == 0)
            zeroMapping(backend, op, args)
        else
            try backend.invoke(&canonical, m, op, args);
        const failed = @as(i64, @bitCast(value)) < 0;
        const result = if (failed) darwinErrno(@intCast(0 -% value)) else value;
        s.flags.carry = failed;
        s.set(0, result);
        if (s.architecture == .arm64 or !failed) s.set(if (s.architecture == .arm64) 1 else 2, 0);
        mac.calls += 1;
        if (mac.trace) try host.print(2, "Darwin syscall {s} = {d} carry={d}\n", .{ @tagName(op), result, @intFromBool(failed) });
    }
};
fn zeroMapping(backend: *posix.Linux, op: posix.Operation, args: [6]u64) u64 {
    if (op == .mprotect or args[3] & 0x20 != 0) return 0;
    if (!backend.allow_files) return posix.negative(13);
    if (args[4] >= backend.descriptors.len) return posix.negative(9);
    const fd = backend.descriptors[@intCast(args[4])] orelse return posix.negative(9);
    if (backend.open_flags[@intCast(args[4])] & 3 == 1) return posix.negative(13);
    var info: host.c.struct_stat = undefined;
    if (host.c.fstat(fd, &info) < 0) return posix.hostError();
    return if (info.st_mode & host.c.S_IFMT == host.c.S_IFREG) 0 else posix.negative(19);
}
fn darwinErrno(linux: u16) u16 {
    return switch (linux) {
        11 => 35, // EAGAIN
        36 => 63, // ENAMETOOLONG
        39 => 66, // ENOTEMPTY
        40 => 62, // ELOOP
        75 => 84, // EOVERFLOW
        else => linux,
    };
}
fn translate(arm: bool, limit: usize, op: posix.Operation, args: *[6]u64) bool {
    if (op == .read or op == .write or op == .writev or op == .close or op == .lseek) args[0] &= 0xffffffff;
    if (op == .lseek or op == .writev) args[2] &= 0xffffffff;
    if (op == .open) {
        const flags = args[1] & 0xffffffff;
        const supported: u64 = 3 | 8 | 0x100 | 0x200 | 0x400 | 0x800 | 0x100000 | 0x1000000;
        if (flags & ~supported != 0 or flags & 3 == 3) return false;
        args[1] = flags & 3;
        for ([_]u64{ 8, 0x100, 0x200, 0x400, 0x800, 0x100000, 0x1000000 }, [_]u64{ 1024, 0x20000, 64, 512, 128, 0x10000, 0x80000 }) |from, to| if (flags & from != 0) {
            args[1] |= to;
        };
    }
    if (op == .mmap or op == .mprotect or op == .munmap) {
        const page: u64 = if (arm) 16384 else 4096;
        if (args[1] > limit or (op == .munmap and args[1] == 0)) return false;
        args[1] = std.mem.alignForward(u64, args[1], page);
        if (op != .munmap) args[2] &= 7;
        if (op == .mmap) {
            const flags = args[3] & 0xffffffff;
            if (flags & 3 != 2 or flags & ~@as(u64, 2 | 0x10 | 0x1000 | 0x40000) != 0 or args[5] % page != 0) return false;
            if (flags & 0x40000 != 0 and args[1] == 0) return false;
            if (flags & 0x1000 != 0 and @as(u32, @truncate(args[4])) != 0xffffffff) return false;
            if (flags & 0x10 != 0 and args[0] % page != 0) return false;
            args[0] &= ~(page - 1);
            args[3] = (flags & (2 | 0x10)) | (if (flags & 0x1000 != 0) @as(u64, 0x20) else 0);
            args[4] &= 0xffffffff;
            if (args[2] & 6 != 0) args[2] |= 1;
        } else if (args[0] % page != 0) return false;
    }
    return true;
}

test "Darwin BSD syscalls return positive errno with carry and preserve checked I/O" {
    const a = std.testing.allocator;
    var memory = Memory.init(a);
    defer memory.deinit();
    var backend = posix.Linux{ .allocator = a };
    defer backend.deinit();
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64 }) |arch| {
        var mac = MacOS{};
        var s = State{ .architecture = arch };
        const nr: u6 = if (arch == .x86_64) 0 else 16;
        s.set(nr, (if (arch == .x86_64) @as(u64, 0x2000000) else 0) + 3);
        s.set(if (arch == .x86_64) 7 else 0, 0);
        s.set(if (arch == .x86_64) 6 else 1, 0);
        s.set(2, 1);
        try mac.dispatch(&backend, &s, &memory);
        try std.testing.expectEqual(@as(u64, 14), s.get(0));
        try std.testing.expect(s.flags.carry and memory.fault == null);
        s.set(nr, (if (arch == .x86_64) @as(u64, 0x2000000) else 0) + 20);
        try mac.dispatch(&backend, &s, &memory);
        try std.testing.expectEqual(@as(u64, 1), s.get(0));
        try std.testing.expect(!s.flags.carry);
        s.set(nr, (if (arch == .x86_64) @as(u64, 0x2000000) else 0) + 197);
        const regs: [6]u6 = if (arch == .x86_64) .{ 7, 6, 2, 10, 8, 9 } else .{ 0, 1, 2, 3, 4, 5 };
        for (regs, [_]u64{ 0, 0, 3, 0x1002, 0xffffffffffffffff, 0 }) |r, value| s.set(r, value);
        const used = memory.used;
        try mac.dispatch(&backend, &s, &memory);
        try std.testing.expectEqual(@as(u64, 0), s.get(0));
        try std.testing.expect(!s.flags.carry and memory.used == used);
    }
    try std.testing.expectEqual(@as(u16, 35), darwinErrno(11));
    var args = [_]u64{ 0x1000, 1, 3, 0x1012, 0xffffffffffffffff, 0 };
    try std.testing.expect(!translate(true, memory.limit, .mmap, &args));
    args[0] = 0x4000;
    try std.testing.expect(translate(true, memory.limit, .mmap, &args));
    try std.testing.expectEqual(@as(u64, 16384), args[1]);
    try std.testing.expectEqual(@as(u64, 0x32), args[3]);
}
