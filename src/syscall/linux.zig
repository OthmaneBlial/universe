const std = @import("std");
const host = @import("../host.zig");
const c = host.c;
const Memory = @import("../memory.zig").Memory;
const State = @import("../cpu/state.zig").State;
const Threads = @import("../linux_threads.zig").Threads;
const Pipe = @import("../linux_pipe.zig").Pipe;
const Device = @import("../linux_device.zig").Device;
const Signals = @import("../linux_signals.zig");
pub const Operation = enum { kill, rt_sigpending, rt_sigsuspend, rt_sigreturn, execve, fork, wait4, time, sysinfo, gettimeofday, umask, socket, sigaltstack, futex, nanosleep, clock_nanosleep, poll, prlimit64, madvise, rseq, set_robust_list, readv, getcwd, fsync, fdatasync, ftruncate, pread64, pwrite64, readlink, readlinkat, rt_sigaction, rt_sigprocmask, fcntl, dup, dup2, dup3, pipe, pipe2, sendfile, getdents64, stat, lstat, sched_getaffinity, getuid, getgroups, setuid, setgid, arch_prctl, set_tid_address, writev, ioctl, read, write, open, openat, access, faccessat, mkdir, mkdirat, unlink, unlinkat, rmdir, rename, renameat, utimensat, close, lseek, fstat, newfstatat, exit, brk, mmap, munmap, mprotect, clock_gettime, getrandom, uname, getpid, getppid, gettid, clone, clone3, sched_yield, exit_group };
pub fn operation(s: State, n: u64) !Operation {
    if (s.architecture == .x86_64) return switch (n) {
        201 => .time,
        99 => .sysinfo,
        95 => .umask,
        96 => .gettimeofday,
        79 => .getcwd,
        74 => .fsync,
        75 => .fdatasync,
        77 => .ftruncate,
        17 => .pread64,
        18 => .pwrite64,
        89 => .readlink,
        267 => .readlinkat,
        13 => .rt_sigaction,
        15 => .rt_sigreturn,
        127 => .rt_sigpending,
        130 => .rt_sigsuspend,
        62 => .kill,
        131 => .sigaltstack,
        202 => .futex,
        35 => .nanosleep,
        230 => .clock_nanosleep,
        14 => .rt_sigprocmask,
        72 => .fcntl,
        32 => .dup,
        33 => .dup2,
        292 => .dup3,
        22 => .pipe,
        293 => .pipe2,
        40 => .sendfile,
        217 => .getdents64,
        4 => .stat,
        6 => .lstat,
        204 => .sched_getaffinity,
        102, 104, 107, 108 => .getuid,
        115 => .getgroups,
        105 => .setuid,
        106 => .setgid,
        158 => .arch_prctl,
        218 => .set_tid_address,
        273 => .set_robust_list,
        334 => .rseq,
        19 => .readv,
        20 => .writev,
        16 => .ioctl,
        21 => .access,
        0 => .read,
        1 => .write,
        2 => .open,
        3 => .close,
        5 => .fstat,
        8 => .lseek,
        7 => .poll,
        9 => .mmap,
        10 => .mprotect,
        11 => .munmap,
        28 => .madvise,
        302 => .prlimit64,
        12 => .brk,
        39 => .getpid,
        110 => .getppid,
        41 => .socket,
        59 => .execve,
        57 => .fork,
        61 => .wait4,
        56 => .clone,
        435 => .clone3,
        24 => .sched_yield,
        60 => .exit,
        231 => .exit_group,
        63 => .uname,
        83 => .mkdir,
        84 => .rmdir,
        87 => .unlink,
        82 => .rename,
        186 => .gettid,
        228 => .clock_gettime,
        257 => .openat,
        258 => .mkdirat,
        262 => .newfstatat,
        263 => .unlinkat,
        269 => .faccessat,
        264 => .renameat,
        280 => .utimensat,
        318 => .getrandom,
        else => error.UnsupportedSyscall,
    };
    return switch (n) {
        179 => .sysinfo,
        166 => .umask,
        169 => .gettimeofday,
        17 => .getcwd,
        82 => .fsync,
        83 => .fdatasync,
        46 => .ftruncate,
        67 => .pread64,
        68 => .pwrite64,
        78 => .readlinkat,
        134 => .rt_sigaction,
        139 => .rt_sigreturn,
        136 => .rt_sigpending,
        133 => .rt_sigsuspend,
        129 => .kill,
        132 => .sigaltstack,
        98 => .futex,
        101 => .nanosleep,
        115 => .clock_nanosleep,
        135 => .rt_sigprocmask,
        25 => .fcntl,
        23 => .dup,
        24 => .dup3,
        59 => .pipe2,
        71 => .sendfile,
        61 => .getdents64,
        123 => .sched_getaffinity,
        174, 175, 176, 177 => .getuid,
        158 => .getgroups,
        146 => .setuid,
        144 => .setgid,
        96 => .set_tid_address,
        99 => .set_robust_list,
        293 => .rseq,
        65 => .readv,
        66 => .writev,
        29 => .ioctl,
        56 => .openat,
        34 => .mkdirat,
        35 => .unlinkat,
        48 => .faccessat,
        38 => .renameat,
        88 => .utimensat,
        57 => .close,
        62 => .lseek,
        63 => .read,
        64 => .write,
        79 => .newfstatat,
        80 => .fstat,
        260 => .wait4,
        221 => .execve,
        220 => .clone,
        435 => .clone3,
        124 => .sched_yield,
        93 => .exit,
        94 => .exit_group,
        113 => .clock_gettime,
        160 => .uname,
        172 => .getpid,
        173 => .getppid,
        198 => .socket,
        178 => .gettid,
        214 => .brk,
        215 => .munmap,
        233 => .madvise,
        261 => .prlimit64,
        222 => .mmap,
        226 => .mprotect,
        278 => .getrandom,
        else => error.UnsupportedSyscall,
    };
}
pub fn negative(n: u16) u64 {
    return @bitCast(-@as(i64, n));
}
pub fn hostError() u64 {
    const e = host.errno();
    const linux: u16 = if (e == c.EPERM) 1 else if (e == c.ENOENT) 2 else if (e == c.EINTR) 4 else if (e == c.EIO) 5 else if (e == c.EBADF) 9 else if (e == c.EAGAIN) 11 else if (e == c.ENOMEM) 12 else if (e == c.EACCES) 13 else if (e == c.EEXIST) 17 else if (e == c.ENOTDIR) 20 else if (e == c.EISDIR) 21 else if (e == c.EINVAL) 22 else if (e == c.EMFILE) 24 else if (e == c.EFBIG) 27 else if (e == c.ENOSPC) 28 else if (e == c.ESPIPE) 29 else if (e == c.EROFS) 30 else if (e == c.EPIPE) 32 else if (e == c.ERANGE) 34 else if (e == c.ENAMETOOLONG) 36 else if (e == c.ENOLCK) 37 else if (e == c.ENOTEMPTY) 39 else if (e == c.ELOOP) 40 else if (e == c.EOVERFLOW) 75 else 5;
    return negative(linux);
}
pub const Linux = struct {
    allocator: std.mem.Allocator,
    descriptors: [64]?c_int = blk: {
        var f: [64]?c_int = @splat(null);
        f[0] = 0;
        f[1] = 1;
        f[2] = 2;
        break :blk f;
    },
    fd_flags: [64]u32 = @splat(0),
    pipes: [64]?*Pipe = @splat(null),
    open_flags: [64]u64 = blk: {
        var f: [64]u64 = @splat(0);
        f[1] = 1;
        f[2] = 1;
        break :blk f;
    },
    borrowed: [64]bool = blk: {
        var f: [64]bool = @splat(false);
        f[0] = true;
        f[1] = true;
        f[2] = true;
        break :blk f;
    },
    directories: [64]?*c.DIR = @splat(null),
    devices: [64]?*Device = @splat(null),
    allow_files: bool = false,
    sysroot: ?[:0]const u8 = null,
    trace: bool = false,
    exit_code: ?u8 = null,
    exit_signal: u7 = 0,
    auto_reap: bool = false,
    last_number: u64 = 0,
    heap_base: u64 = 0,
    heap_end: u64 = 0,
    heap_limit: u64 = 0,
    next_map: u64 = 0x100000000,
    page_size: u32 = 4096,
    calls: u64 = 0,
    pid: u32 = 1,
    parent_pid: u32 = 0,
    creator_tid: u32 = 1,
    process_count: u16 = 1,
    threads: Threads = .{},
    boot_ns: u64 = 0,
    mask: ?c.mode_t = null,
    signal_actions: [64][32]u8 = @splat(@splat(0)),
    // Standard signals coalesce; real-time queued signals need a separate bounded queue.
    signal_pending: u64 = 0,
    signal_info: [31][128]u8 = @splat(@splat(0)),
    signal_restorer: ?u64 = null,
    pub fn deinit(l: *Linux) void {
        l.threads.deinit(l.allocator);
        for (l.descriptors, 0..) |fd, index| if (fd != null) {
            _ = l.closeDescriptor(index);
        };
    }
    fn creationMask(l: *Linux) c.mode_t {
        if (l.mask == null) {
            const initial = c.umask(0);
            _ = c.umask(initial);
            l.mask = initial;
        }
        return l.mask.?;
    }
    pub fn fork(l: *Linux, pid: u32) !Linux {
        for (l.directories) |dir| if (dir != null) return error.DirectoryForkUnsupported;
        var child = l.*;
        child.pid = pid;
        child.parent_pid = l.pid;
        child.creator_tid = l.threads.id();
        child.calls = 0;
        child.exit_code = null;
        child.exit_signal = 0;
        child.auto_reap = false;
        child.signal_pending = 0;
        child.signal_info = @splat(@splat(0));
        child.descriptors = @splat(null);
        child.borrowed = @splat(false);
        child.pipes = @splat(null);
        child.devices = @splat(null);
        child.directories = @splat(null);
        child.mask = l.creationMask();
        child.threads = .{ .initial_id = pid, .initial = .{ .signal_mask = l.threads.metadata().signal_mask, .alternate_stack = l.threads.metadata().alternate_stack } };
        errdefer child.deinit();
        for (l.descriptors, 0..) |fd, index| if (fd) |original| {
            const copy = try copyDescriptor(original);
            child.descriptors[index] = copy;
            if (l.pipes[index]) |pipe| child.attachPipe(index, pipe);
            if (l.devices[index]) |device| child.attachDevice(index, device);
        };
        return child;
    }
    pub fn afterExec(l: *Linux, heap: u64) void {
        const mask = l.threads.metadata().signal_mask;
        l.threads.deinit(l.allocator);
        l.threads = .{ .initial_id = l.pid, .initial = .{ .signal_mask = mask } };
        for (&l.signal_actions) |*action| {
            const ignored = std.mem.readInt(u64, action[0..8], .little) == 1;
            action.* = @splat(0);
            if (ignored) put(action, 0, 64, 1);
        }
        for (l.fd_flags, 0..) |flags, index| if (flags & 1 != 0 and l.descriptors[index] != null) {
            _ = l.closeDescriptor(index);
        };
        l.heap_base = heap;
        l.heap_end = heap;
        l.heap_limit = heap + 16 * 1024 * 1024;
        l.next_map = 0x100000000;
        l.signal_restorer = null;
    }
    pub fn queueSignal(l: *Linux, sig: u7, info: [128]u8) void {
        std.debug.assert(sig > 0 and sig < 32);
        if (std.mem.readInt(u64, l.signal_actions[sig - 1][0..8], .little) == 1) return;
        const bit = @as(u64, 1) << @as(u6, @intCast(sig - 1));
        if (l.signal_pending & bit == 0) l.signal_info[sig - 1] = info;
        l.signal_pending |= bit;
    }
    pub fn pollSignals(l: *Linux, s: *State, m: *Memory) !void {
        while (l.signal_pending != 0) {
            const index = l.threads.signalCandidate(l.signal_pending) orelse return;
            const data = l.threads.signalMetadata(index);
            const sig: u7 = @intCast(@ctz(l.signal_pending & ~data.signal_mask) + 1);
            const bit = @as(u64, 1) << @as(u6, @intCast(sig - 1));
            const action = l.signal_actions[sig - 1];
            const handler = std.mem.readInt(u64, action[0..8], .little);
            if (handler == 1 or handler == 0 and (sig == 17 or sig == 23 or sig == 28)) {
                l.signal_pending &= ~bit;
                continue;
            }
            if (handler == 0) {
                if (sig >= 18 and sig <= 22) return error.UnsupportedGuestSignalAction;
                l.exit_signal = sig;
                l.exit_code = 128 + @as(u8, sig);
                l.threads.exitGroup(m);
                l.signal_pending &= ~bit;
                return;
            }
            const flags = std.mem.readInt(u64, action[8..16], .little);
            var next = try l.threads.signalContext(s.*, index, m, flags & 0x10000000 != 0);
            const restored_mask = data.saved_signal_mask orelse data.signal_mask;
            const previous_mask = data.signal_mask;
            const stack = data.alternate_stack;
            var restorer = if (s.architecture != .riscv64 and flags & 0x4000000 != 0) std.mem.readInt(u64, action[16..24], .little) else l.signal_restorer orelse 0;
            if (restorer == 0 and s.architecture != .x86_64) {
                restorer = try m.findFree(@import("../process.zig").stack_top + 4096, 4096);
                try m.map(restorer, 4096, .{ .read = true, .execute = true });
                errdefer m.unmap(restorer, 4096) catch {};
                const code: []const u8 = if (s.architecture == .arm64) &.{ 0x68, 0x11, 0x80, 0xd2, 0x01, 0x00, 0x00, 0xd4 } else &.{ 0x93, 0x08, 0xb0, 0x08, 0x73, 0x00, 0x00, 0x00 };
                try m.initialize(restorer, code);
                l.signal_restorer = restorer;
            }
            try Signals.enter(&next, m, sig, &l.signal_info[sig - 1], action, restored_mask, stack, restorer);
            l.threads.activateSignal(s, index, next);
            const mask_offset: usize = if (s.architecture == .riscv64) 16 else 24;
            l.threads.metadata().signal_mask = (previous_mask | std.mem.readInt(u64, action[mask_offset..][0..8], .little) | (if (flags & 0x40000000 == 0) bit else @as(u64, 0))) & ~Signals.unblockable;
            if (std.mem.readInt(u32, stack[8..12], .little) & 0x80000000 != 0) {
                l.threads.metadata().alternate_stack = @splat(0);
                put(&l.threads.metadata().alternate_stack, 8, 32, 2);
            }
            if (flags & 0x80000000 != 0) l.signal_actions[sig - 1] = @splat(0);
            l.signal_pending &= ~bit;
            return;
        }
    }
    fn descriptor(l: *Linux, n: u64) ?c_int {
        return if (n < l.descriptors.len) l.descriptors[@intCast(n)] else null;
    }
    fn atDescriptor(l: *Linux, n: u64) !?c_int {
        const number: u32 = @truncate(n); // Linux dirfd arguments are signed 32-bit ints.
        if (@as(i32, @bitCast(number)) == -100) return c.AT_FDCWD;
        const fd = l.descriptor(number) orelse return null;
        if (fd == Device.fd) return error.NotDirectory;
        return fd;
    }
    fn copyDescriptor(fd: c_int) !c_int {
        if (fd == Device.fd) return fd;
        const copy = c.fcntl(fd, c.F_DUPFD_CLOEXEC, @as(c_int, 0));
        if (copy < 0) return error.HostDescriptorCopyFailed;
        return copy;
    }
    fn register(l: *Linux, fd: c_int, flags: u64, minimum: usize) u64 {
        for (minimum..l.descriptors.len) |i| if (l.descriptors[i] == null) {
            l.descriptors[i] = fd;
            l.borrowed[i] = false;
            l.fd_flags[i] = @intFromBool(flags & 0x80000 != 0);
            l.open_flags[i] = flags;
            return i;
        };
        if (fd != Device.fd) _ = c.close(fd);
        return negative(24);
    }
    fn closeDescriptor(l: *Linux, index: u64) u64 {
        const fd = l.descriptor(index) orelse return negative(9);
        const i: usize = @intCast(index);
        const result = if (fd != Device.fd and !l.borrowed[i] and c.close(fd) < 0) hostError() else 0;
        if (l.directories[i]) |dir| {
            _ = c.closedir(dir);
            l.directories[i] = null;
        }
        l.descriptors[i] = null;
        if (l.devices[i]) |device| {
            l.devices[i] = null;
            device.release();
        }
        if (l.pipes[i]) |pipe| {
            if (l.open_flags[i] & 3 == 1) pipe.writers -= 1 else pipe.readers -= 1;
            l.pipes[i] = null;
            pipe.release();
        }
        return result;
    }
    fn attachPipe(l: *Linux, index: usize, pipe: *Pipe) void {
        l.pipes[index] = pipe;
        pipe.retain();
        if (l.open_flags[index] & 3 == 1) pipe.writers += 1 else pipe.readers += 1;
    }
    fn attachDevice(l: *Linux, index: usize, device: *Device) void {
        l.devices[index] = device;
        device.retain();
    }
    fn streamIO(l: *Linux, s: State, index: u64, buf: []u8, writing: bool) !u64 {
        const fd = l.descriptor(index) orelse return negative(9);
        if (l.devices[@intCast(index)]) |device| {
            if (!device.permitsIO(writing)) return negative(9);
            return if (writing) buf.len else device.read(buf);
        }
        var count = buf.len;
        if (l.pipes[@intCast(index)]) |pipe| {
            if (writing != (l.open_flags[@intCast(index)] & 3 == 1)) return negative(9);
            if (count == 0) return 0;
            if (writing and pipe.readers == 0) {
                l.queueSignal(13, Signals.makeInfo(13, 128, 0, 0, 0));
                return negative(32); // SIGPIPE stays within the guest; never signal the host.
            }
            const minimum = if (writing and count <= Pipe.capacity) count else 1;
            if (!pipe.ready(writing, minimum)) {
                if (pipe.status[@intFromBool(writing)] & 0x800 != 0) return negative(11);
                try l.threads.waitPipe(l.allocator, s, pipe, writing, minimum);
                return error.SyscallPending;
            }
            count = @min(count, if (writing) Pipe.capacity - pipe.used else pipe.used);
        }
        const result = if (writing) c.write(fd, buf.ptr, count) else c.read(fd, buf.ptr, count);
        if (result < 0) return hostError();
        if (l.pipes[@intCast(index)]) |pipe| {
            if (writing) pipe.used += @intCast(result) else pipe.used -= @intCast(result);
        }
        return @intCast(result);
    }
    pub fn arguments(s: State) [6]u64 {
        const regs: [6]u6 = switch (s.architecture) {
            .x86_64 => .{ 7, 6, 2, 10, 8, 9 },
            .riscv64 => .{ 10, 11, 12, 13, 14, 15 },
            .arm64 => .{ 0, 1, 2, 3, 4, 5 },
        };
        var args: [6]u64 = undefined;
        for (regs, 0..) |r, i| args[i] = s.get(r);
        return args;
    }
    pub fn pending(l: *Linux, s: *State, op: Operation) !void {
        // Retry the same trap after readiness; preserve the syscall number and every argument.
        s.pc -= if (s.architecture == .x86_64) @as(u64, 2) else 4;
        l.calls += 1;
        if (l.trace) try host.print(2, "syscall {s}: waiting\n", .{@tagName(op)});
    }
    pub fn complete(l: *Linux, s: *State, op: Operation, args: [6]u64, result: u64) !void {
        s.set(if (s.architecture == .riscv64) 10 else 0, result);
        l.calls += 1;
        if (l.trace) try host.print(2, "syscall {s}({x}, {x}, {x}, {x}, {x}, {x}) = {d}\n", .{ @tagName(op), args[0], args[1], args[2], args[3], args[4], args[5], @as(i64, @bitCast(result)) });
    }
    pub fn dispatch(l: *Linux, s: *State, m: *Memory) !void {
        const nr = if (s.architecture == .x86_64) s.get(0) else if (s.architecture == .riscv64) s.get(17) else s.get(8);
        l.last_number = nr;
        const args = arguments(s.*);
        const op = try operation(s.*, nr);
        const result = l.invoke(s, m, op, args) catch |err| {
            if (err != error.SyscallPending) return err;
            try l.pending(s, op);
            return;
        };
        try l.complete(s, op, args, result);
    }
    pub fn resultForError(err: anyerror) !u64 {
        return switch (err) {
            error.UnmappedMemory, error.PermissionDenied, error.AddressOverflow, error.StringTooLong, error.BusError => negative(14),
            error.ArgumentListTooLong => negative(7),
            error.ProtectionLimit => negative(13),
            error.MemoryLimit, error.OutOfMemory => negative(12),
            error.InvalidMapping, error.OverlappingMapping => negative(22),
            error.DirectoryForkUnsupported, error.SharedMemoryForkUnsupported => negative(38),
            error.HostDescriptorCopyFailed => hostError(),
            error.NotDirectory => negative(20),
            else => return err,
        };
    }
    /// Shared checked POSIX services; arguments and results use canonical Linux encodings.
    pub fn invoke(l: *Linux, s: *State, m: *Memory, op: Operation, args: [6]u64) !u64 {
        const result = l.perform(s, m, op, args) catch |err| blk: {
            if (op == .poll and err != error.SyscallPending) l.threads.metadata().poll_deadline = null;
            break :blk try resultForError(err);
        };
        m.fault = null;
        return result;
    }
    fn perform(l: *Linux, s: *State, m: *Memory, op: Operation, a: [6]u64) !u64 {
        switch (op) {
            .socket => return negative(97), // No supported socket families; use libc file fallbacks.
            .pipe, .pipe2 => {
                const flags: u32 = if (op == .pipe2) @truncate(a[1]) else 0;
                if (flags & ~@as(u32, 0x800 | 0x80000) != 0) return negative(22);
                var slots: [2]usize = undefined;
                var count: usize = 0;
                for (l.descriptors, 0..) |fd, i| if (fd == null) {
                    slots[count] = i;
                    count += 1;
                    if (count == 2) break;
                };
                if (count != 2) return negative(24);
                try m.prepareWrite(a[0], 8);
                var fds: [2]c_int = undefined;
                if (c.pipe(&fds) != 0) return hostError();
                var published = false;
                defer if (!published) {
                    for (fds) |fd| _ = c.close(fd);
                };
                for (fds) |fd| {
                    if (c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0 or c.fcntl(fd, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return hostError();
                }
                const pipe = try l.allocator.create(Pipe);
                errdefer l.allocator.destroy(pipe);
                pipe.* = .{ .allocator = l.allocator, .status = .{ flags & 0x800, flags & 0x800 | 1 } };
                var output: [8]u8 = undefined;
                std.mem.writeInt(u32, output[0..4], @intCast(slots[0]), .little);
                std.mem.writeInt(u32, output[4..8], @intCast(slots[1]), .little);
                try m.write(a[0], &output);
                for (slots, fds, 0..) |slot, fd, end| {
                    l.descriptors[slot] = fd;
                    l.borrowed[slot] = false;
                    l.fd_flags[slot] = @intFromBool(flags & 0x80000 != 0);
                    l.open_flags[slot] = (flags & 0x800) | end;
                    l.attachPipe(slot, pipe);
                }
                published = true;
                return 0;
            },
            .execve => return error.ProcessExec,
            .kill => return error.ProcessSignal,
            .fork => return error.ProcessFork,
            .wait4 => return error.ProcessWait,
            .clone => {
                if (@as(u32, @truncate(a[0])) == 17 and a[1] == 0) return error.ProcessFork;
                return l.threads.clone(l.allocator, s.*, m, a);
            },
            .clone3 => return negative(38),
            .futex => return l.threads.futex(l.allocator, s.*, m, a),
            .nanosleep => return l.threads.sleep(l.allocator, s.*, m, 1, 0, a[0], a[1]),
            .clock_nanosleep => return l.threads.sleep(l.allocator, s.*, m, @truncate(a[0]), @truncate(a[1]), a[2], a[3]),
            .sched_yield => {
                l.threads.yield_pending = true;
                return 0;
            },
            .sigaltstack => {
                var previous = l.threads.metadata().alternate_stack;
                const base = std.mem.readInt(u64, previous[0..8], .little);
                const size = std.mem.readInt(u64, previous[16..24], .little);
                const flags = std.mem.readInt(u32, previous[8..12], .little);
                const sp = s.get(s.stackRegister());
                const active = flags & 0x80000002 == 0 and sp > base and sp - base <= size;
                if (active) put(&previous, 8, 32, flags | 1);
                var next = l.threads.metadata().alternate_stack;
                if (a[0] != 0) {
                    try m.read(a[0], &next, .read);
                    if (active) return negative(1);
                    const new_flags = std.mem.readInt(u32, next[8..12], .little);
                    if (new_flags & ~@as(u32, 0x80000003) != 0 or new_flags & 3 == 3) return negative(22);
                    if (new_flags & 2 != 0) {
                        next = @splat(0);
                        put(&next, 8, 32, 2);
                    } else {
                        if (std.mem.readInt(u64, next[16..24], .little) < (if (s.architecture == .arm64) @as(u64, 5120) else 2048)) return negative(12);
                        put(&next, 8, 32, new_flags & 0x80000000);
                        put(&next, 12, 32, 0);
                    }
                }
                if (a[1] != 0) try m.write(a[1], &previous);
                l.threads.metadata().alternate_stack = next;
                return 0;
            },
            .poll => {
                if (a[1] > l.descriptors.len) return negative(22);
                const count: usize = @intCast(a[1]);
                const bytes = try l.allocator.alloc(u8, count * 8);
                defer l.allocator.free(bytes);
                try m.read(a[0], bytes, .read);
                try m.prepareWrite(a[0], bytes.len);
                const fds = try l.allocator.alloc(c.struct_pollfd, count);
                defer l.allocator.free(fds);
                for (fds, 0..) |*fd, index| {
                    const row = bytes[index * 8 ..][0..8];
                    const guest = std.mem.readInt(i32, row[0..4], .little);
                    const events = std.mem.readInt(u16, row[4..6], .little);
                    fd.fd = if (guest < 0) -1 else l.descriptor(@intCast(guest)) orelse -1;
                    // Translate normal/band bits; Linux POLLRDHUP has no effect on our regular files.
                    fd.events = @intCast(events & 7);
                    if (events & 64 != 0) fd.events |= c.POLLRDNORM;
                    if (events & 128 != 0) fd.events |= c.POLLRDBAND;
                    if (events & 256 != 0) fd.events |= c.POLLWRNORM;
                    if (events & 512 != 0) fd.events |= c.POLLWRBAND;
                    fd.revents = 0;
                    std.mem.writeInt(u16, row[6..8], if (guest >= 0 and fd.fd == -1) 32 else 0, .little);
                    if (guest >= 0 and guest < l.pipes.len) if (l.pipes[@intCast(guest)]) |pipe| {
                        const writing = l.open_flags[@intCast(guest)] & 3 == 1;
                        const ready_events: u16 = if (writing)
                            @as(u16, if (pipe.used < Pipe.capacity) events & 0x104 else 0) | @as(u16, if (pipe.readers == 0) 8 else 0)
                        else
                            @as(u16, if (pipe.used != 0) events & 0x41 else 0) | @as(u16, if (pipe.writers == 0) 16 else 0);
                        std.mem.writeInt(u16, row[6..8], ready_events, .little);
                        fd.fd = -1;
                        continue;
                    };
                    if (guest >= 0 and guest < l.devices.len and l.devices[@intCast(guest)] != null) {
                        std.mem.writeInt(u16, row[6..8], events & 0x145, .little);
                        fd.fd = -1;
                        continue;
                    }
                    // Linux regular files are always ready; Darwin poll may report NVAL for them.
                    if (fd.fd >= 0) {
                        const stat = host.statFd(fd.fd) catch return hostError();
                        if (host.isRegular(stat.mode)) {
                            const ready_events = events & 0x145;
                            std.mem.writeInt(u16, row[6..8], ready_events, .little);
                            fd.fd = -1;
                        }
                    }
                }
                const ready = c.poll(fds.ptr, @intCast(count), 0);
                if (ready < 0) return hostError();
                var result: u64 = 0;
                for (fds, 0..) |fd, index| {
                    const row = bytes[index * 8 ..][0..8];
                    var events = std.mem.readInt(u16, row[6..8], .little) | (@as(u16, @bitCast(fd.revents)) & 63);
                    if (fd.revents & c.POLLRDNORM != 0) events |= 64;
                    if (fd.revents & c.POLLRDBAND != 0) events |= 128;
                    if (fd.revents & c.POLLWRNORM != 0) events |= 256;
                    if (fd.revents & c.POLLWRBAND != 0) events |= 512;
                    events &= std.mem.readInt(u16, row[4..6], .little) | 56;
                    std.mem.writeInt(u16, row[6..8], events, .little);
                    result += @intFromBool(events != 0);
                }
                const timeout: i32 = @bitCast(@as(u32, @truncate(a[2])));
                if (result == 0 and timeout != 0) {
                    const now = try host.nowNs();
                    if (timeout > 0 and l.threads.metadata().poll_deadline == null) l.threads.metadata().poll_deadline = now +| @as(u64, @intCast(timeout)) * 1_000_000;
                    const until = if (timeout < 0) std.math.maxInt(u64) else l.threads.metadata().poll_deadline.?;
                    if (now < until) {
                        // ponytail: poll readiness every millisecond; add event-driven wakeups for measured latency needs.
                        try l.threads.retryAfter(l.allocator, s.*, @min(now +| 1_000_000, until), false);
                        return error.SyscallPending;
                    }
                }
                l.threads.metadata().poll_deadline = null;
                try m.write(a[0], bytes);
                return result;
            },
            .prlimit64 => {
                if (a[1] >= 16) return negative(22);
                const pid: u32 = @truncate(a[0]);
                if (pid != 0 and pid != l.pid) return negative(3);
                if (a[2] != 0) return negative(38); // Limit mutation remains unsupported.
                const limit: u64 = switch (a[1]) {
                    3 => @import("../process.zig").stack_size,
                    7 => l.descriptors.len,
                    9 => m.limit,
                    else => return negative(38),
                };
                if (a[3] != 0) {
                    var bytes: [16]u8 = undefined;
                    std.mem.writeInt(u64, bytes[0..8], limit, .little);
                    std.mem.writeInt(u64, bytes[8..16], limit, .little);
                    try m.write(a[3], &bytes);
                }
                return 0;
            },
            // Optional capabilities remain unavailable; libc can use its error fallbacks.
            .madvise, .set_robust_list, .rseq => return negative(38),
            .sendfile => return negative(38), // No accelerated transfer; guests can fall back to read/write.
            .rt_sigaction => {
                const sig: u32 = @truncate(a[0]);
                if (a[3] != 8 or sig == 0 or sig > 64 or (a[1] != 0 and (sig == 9 or sig == 19))) return negative(22);
                const size: usize = if (s.architecture == .riscv64) 24 else 32;
                const mask_offset: usize = if (s.architecture == .riscv64) 16 else 24;
                const previous = l.signal_actions[sig - 1];
                if (a[1] != 0) {
                    var action: [32]u8 = @splat(0);
                    try m.read(a[1], action[0..size], .read);
                    const flags = std.mem.readInt(u64, action[8..16], .little);
                    const supported: u64 = if (s.architecture == .riscv64) 0xd8000007 else 0xdc000007;
                    put(&action, 8, 64, flags & supported);
                    const mask = std.mem.readInt(u64, action[mask_offset..][0..8], .little);
                    put(&action, mask_offset, 64, mask & ~@as(u64, 0x40100));
                    l.signal_actions[sig - 1] = action;
                    if (std.mem.readInt(u64, action[0..8], .little) == 1) l.signal_pending &= ~(@as(u64, 1) << @as(u6, @intCast(sig - 1)));
                }
                if (a[2] != 0) try m.write(a[2], previous[0..size]);
                return 0;
            },
            .rt_sigpending => {
                if (a[1] != 8) return negative(22);
                try m.writeInt(a[0], 64, l.signal_pending & l.threads.metadata().signal_mask);
                return 0;
            },
            .rt_sigsuspend => {
                if (a[1] != 8) return negative(22);
                const mask = (try m.readInt(a[0], 64, .read)) & ~Signals.unblockable;
                try l.threads.waitSignal(l.allocator, s.*, mask);
                return negative(4); // Visible only after a real caught signal wakes this context.
            },
            .rt_sigreturn => {
                const restored = Signals.restore(s, m) catch return error.InvalidSignalContext;
                l.threads.metadata().signal_mask = restored.mask;
                l.threads.metadata().alternate_stack = restored.alternate_stack;
                l.threads.metadata().poll_deadline = null;
                return s.get(if (s.architecture == .riscv64) 10 else 0);
            },
            .rt_sigprocmask => {
                if (a[3] != 8) return negative(22);
                const previous = l.threads.metadata().signal_mask;
                if (a[1] != 0) {
                    const mask = (try m.readInt(a[1], 64, .read)) & ~@as(u64, 0x40100);
                    l.threads.metadata().signal_mask = switch (@as(u32, @truncate(a[0]))) {
                        0 => previous | mask,
                        1 => previous & ~mask,
                        2 => mask,
                        else => return negative(22),
                    };
                }
                if (a[2] != 0) try m.writeInt(a[2], 64, previous);
                return 0;
            },
            .dup, .dup2, .dup3 => {
                const index: u32 = @truncate(a[0]);
                const target: u32 = @truncate(a[1]);
                const flags: u32 = if (op == .dup3) @truncate(a[2]) else 0;
                if (op == .dup3 and (flags & ~@as(u32, 0x80000) != 0 or index == target)) return negative(22);
                const fd = l.descriptor(index) orelse return negative(9);
                if (op != .dup) {
                    if (target >= l.descriptors.len) return negative(9);
                    if (index == target) return index;
                }
                const copy = try copyDescriptor(fd);
                if (op != .dup) _ = l.closeDescriptor(target);
                const slot = l.register(copy, l.open_flags[index] & ~@as(u64, 0x80000) | flags, if (op != .dup) target else 0);
                if (slot < l.pipes.len) if (l.pipes[index]) |pipe| l.attachPipe(@intCast(slot), pipe);
                if (slot < l.devices.len) if (l.devices[index]) |device| l.attachDevice(@intCast(slot), device);
                return slot;
            },
            .fcntl => {
                const fd = l.descriptor(a[0]) orelse return negative(9);
                const index: usize = @intCast(a[0]);
                switch (a[1]) {
                    0, 1030 => {
                        const minimum: i32 = @bitCast(@as(u32, @truncate(a[2])));
                        if (minimum < 0 or minimum >= l.descriptors.len) return negative(22);
                        // Host descriptors always stay private; guest FD_CLOEXEC is separate metadata.
                        const copy = try copyDescriptor(fd);
                        const flags = (l.open_flags[index] & ~@as(u64, 0x80000)) | @as(u64, if (a[1] == 1030) 0x80000 else 0);
                        const slot = l.register(copy, flags, @intCast(minimum));
                        if (slot < l.pipes.len) if (l.pipes[index]) |pipe| l.attachPipe(@intCast(slot), pipe);
                        if (slot < l.devices.len) if (l.devices[index]) |device| l.attachDevice(@intCast(slot), device);
                        return slot;
                    },
                    1 => return l.fd_flags[index],
                    2 => {
                        l.fd_flags[index] = @truncate(a[2] & 1);
                        return 0;
                    },
                    3 => return if (l.devices[index]) |device| device.status else if (l.pipes[index]) |pipe| pipe.status[@intFromBool(l.open_flags[index] & 3 == 1)] else l.open_flags[index] & ~@as(u64, 64 | 128 | 512 | 0x80000),
                    4 => {
                        const flags: u32 = @truncate(a[2]);
                        if (flags & (0x2000 | 0x4000) != 0) return negative(38); // Asynchronous notification and packet pipes need separate implementations.
                        if (l.devices[index]) |device| {
                            device.status = (device.status & ~@as(u64, 0x400 | 0x800)) | (flags & (0x400 | 0x800));
                            return 0;
                        }
                        const pipe = l.pipes[index] orelse return negative(38);
                        const end = @intFromBool(l.open_flags[index] & 3 == 1);
                        pipe.status[end] = @as(u32, end) | (flags & (0x400 | 0x800));
                        return 0;
                    },
                    5, 6 => {
                        if (fd == Device.fd) return negative(38); // Device record locks are outside the supported profile.
                        var bytes: [32]u8 = undefined;
                        try m.read(a[2], &bytes, .read);
                        if (a[1] == 5) try m.check(a[2], bytes.len, .write);
                        const kind = std.mem.readInt(u16, bytes[0..2], .little);
                        const whence = std.mem.readInt(u16, bytes[2..4], .little);
                        var lock = std.mem.zeroes(c.struct_flock);
                        lock.l_type = switch (kind) {
                            0 => c.F_RDLCK,
                            1 => c.F_WRLCK,
                            2 => c.F_UNLCK,
                            else => return negative(22),
                        };
                        lock.l_whence = switch (whence) {
                            0 => c.SEEK_SET,
                            1 => c.SEEK_CUR,
                            2 => c.SEEK_END,
                            else => return negative(22),
                        };
                        lock.l_start = @bitCast(std.mem.readInt(u64, bytes[8..16], .little));
                        lock.l_len = @bitCast(std.mem.readInt(u64, bytes[16..24], .little));
                        if (c.fcntl(fd, @as(c_int, if (a[1] == 5) c.F_GETLK else c.F_SETLK), &lock) < 0) return hostError();
                        if (a[1] == 5) {
                            put(&bytes, 0, 16, if (lock.l_type == c.F_RDLCK) 0 else if (lock.l_type == c.F_WRLCK) 1 else 2);
                            // Linux leaves the remaining fields unchanged when there is no conflict.
                            if (lock.l_type != c.F_UNLCK) {
                                put(&bytes, 2, 16, if (lock.l_whence == c.SEEK_SET) 0 else if (lock.l_whence == c.SEEK_CUR) 1 else 2);
                                put(&bytes, 8, 64, @bitCast(lock.l_start));
                                put(&bytes, 16, 64, @bitCast(lock.l_len));
                                put(&bytes, 24, 32, @as(u32, @bitCast(lock.l_pid)));
                            }
                            try m.write(a[2], &bytes);
                        }
                        return 0;
                    },
                    else => return negative(22),
                }
            },
            .getdents64 => {
                const fd = l.descriptor(a[0]) orelse return negative(9);
                if (fd == Device.fd) return negative(20);
                if (!l.allow_files) return negative(13);
                if (a[2] == 0 or a[2] > 1024 * 1024) return negative(22);
                try m.check(a[1], @intCast(a[2]), .write);
                const index: usize = @intCast(a[0]);
                if (l.directories[index] == null) {
                    const copy = c.dup(fd);
                    if (copy < 0) return hostError();
                    const dir = c.fdopendir(copy);
                    if (dir == null) {
                        const result = hostError();
                        _ = c.close(copy);
                        return result;
                    }
                    l.directories[index] = dir;
                }
                const dir = l.directories[index].?;
                var done: u64 = 0;
                while (true) {
                    const before = c.telldir(dir);
                    if (before < 0) return hostError();
                    host.resetErrno();
                    const entry = c.readdir(dir);
                    if (entry == null) {
                        if (host.errno() != 0 and done == 0) return hostError();
                        break;
                    }
                    const raw: []const u8 = entry.*.d_name[0..];
                    const name = raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse return error.InvalidHostDirectoryEntry];
                    if (name.len > 255) return error.HostDirectoryEntryTooLong;
                    const size = std.mem.alignForward(usize, 20 + name.len, 8);
                    if (size > a[2] - done) {
                        c.seekdir(dir, before);
                        if (done == 0) return negative(22);
                        break;
                    }
                    var bytes: [280]u8 = @splat(0);
                    put(&bytes, 0, 64, entry.*.d_ino);
                    const after = c.telldir(dir);
                    if (after < 0) {
                        c.seekdir(dir, before);
                        return hostError();
                    }
                    put(&bytes, 8, 64, @intCast(after));
                    put(&bytes, 16, 16, size);
                    bytes[18] = entry.*.d_type;
                    @memcpy(bytes[19..][0..name.len], name);
                    try m.write(a[1] + done, bytes[0..size]);
                    done += size;
                }
                return done;
            },
            .getuid => return 1000,
            .getgroups => {
                // ponytail: no supplementary groups in the fixed identity model; track groups with mutable credentials.
                const size: i32 = @bitCast(@as(u32, @truncate(a[0])));
                return if (size < 0) negative(22) else 0;
            },
            .setuid, .setgid => {
                // ponytail: fixed unprivileged IDs; track credentials when guest identity changes are supported.
                const id: u32 = @truncate(a[0]);
                return if (id == 0xffffffff) negative(22) else if (id == 1000) 0 else negative(1);
            },
            .sched_getaffinity => {
                if (!l.threads.contains(a[0])) return negative(3);
                if (a[1] < 8) return negative(22);
                try m.writeInt(a[2], 64, 1);
                return 8;
            },
            .arch_prctl => {
                if (a[0] == 0x1002 or a[0] == 0x1001) {
                    if (a[1] >= 0x800000000000) return negative(1);
                    if (a[0] == 0x1002) s.fs_base = a[1] else s.gs_base = a[1];
                    return 0;
                }
                if (a[0] == 0x1003 or a[0] == 0x1004) {
                    try m.writeInt(a[1], 64, if (a[0] == 0x1003) s.fs_base else s.gs_base);
                    return 0;
                }
                return negative(22);
            },
            .set_tid_address => {
                l.threads.metadata().clear_tid = a[0];
                return l.threads.id();
            },
            .ioctl => {
                if (l.descriptor(a[0]) == null) return negative(9);
                if (l.pipes[@intCast(a[0])]) |pipe| if (@as(u32, @truncate(a[1])) == 0x541b) {
                    try m.writeInt(a[2], 32, pipe.used);
                    return 0;
                };
                return negative(25);
            },
            .readv, .writev => {
                if (l.descriptor(a[0]) == null) return negative(9);
                if (a[2] > 1024) return negative(22);
                try m.check(a[1], @intCast(a[2] * 16), .read);
                const device = l.devices[@intCast(a[0])];
                const writing = op == .writev;
                if (device) |d| if (!d.permitsIO(writing)) return negative(9);
                const no_copy = if (device) |d| d.noCopy(writing) else false;
                var total: usize = 0;
                var buffers: std.ArrayList(u8) = .empty;
                defer buffers.deinit(l.allocator);
                var entries: [1024]struct { address: u64, size: usize } = undefined;
                for (0..a[2]) |n| {
                    const addr = try m.readInt(a[1] + n * 16, 64, .read);
                    const size = try m.readInt(a[1] + n * 16 + 8, 64, .read);
                    if (size > 1024 * 1024 - total) return negative(22);
                    total += @intCast(size);
                    if (no_copy) {
                        try Device.checkRange(addr, size);
                        continue;
                    }
                    if (op == .readv) try m.prepareWrite(addr, @intCast(size)) else try m.check(addr, @intCast(size), .read);
                    entries[n] = .{ .address = addr, .size = @intCast(size) };
                    const off = buffers.items.len;
                    try buffers.resize(l.allocator, off + @as(usize, @intCast(size)));
                    if (op == .writev) try m.read(addr, buffers.items[off..], .read);
                }
                if (no_copy) return if (writing) total else 0;
                const result = try l.streamIO(s.*, a[0], buffers.items, writing);
                if (@as(i64, @bitCast(result)) < 0) return result;
                if (op == .readv) {
                    var offset: usize = 0;
                    for (entries[0..@intCast(a[2])]) |entry| {
                        const count = @min(entry.size, @as(usize, @intCast(result)) - offset);
                        try m.write(entry.address, buffers.items[offset..][0..count]);
                        offset += count;
                    }
                }
                return @intCast(result);
            },
            .exit => {
                if (l.threads.exit(m)) l.exit_code = @truncate(a[0]);
                return 0;
            },
            .exit_group => {
                l.threads.exitGroup(m);
                l.exit_code = @truncate(a[0]);
                return 0;
            },
            .getpid => return l.pid,
            .getppid => return l.parent_pid,
            .gettid => return l.threads.id(),
            .umask => {
                const previous = l.creationMask();
                l.mask = @intCast(a[0] & 0o777);
                return previous;
            },
            .read, .write, .pread64, .pwrite64 => {
                const fd = l.descriptor(a[0]) orelse return negative(9);
                if (a[2] > 1024 * 1024) return negative(22);
                const reading = op == .read or op == .pread64;
                const positioned = op == .pread64 or op == .pwrite64;
                if (positioned and a[3] > std.math.maxInt(i64)) return negative(22);
                const n: usize = @intCast(a[2]);
                if (l.devices[@intCast(a[0])]) |device| {
                    if (!device.permitsIO(!reading)) return negative(9);
                    if (device.noCopy(!reading)) {
                        try Device.checkRange(a[1], a[2]);
                        return if (reading) 0 else a[2];
                    }
                }
                // ponytail: whole-buffer preflight; Linux partial-fault zero reads need page streaming.
                if (reading) try m.prepareWrite(a[1], n) else try m.check(a[1], n, .read);
                const buf = try l.allocator.alloc(u8, n);
                defer l.allocator.free(buf);
                if (!reading) try m.read(a[1], buf, .read);
                const result = if (positioned and fd != Device.fd) blk: {
                    const value = if (reading) c.pread(fd, buf.ptr, n, @intCast(a[3])) else c.pwrite(fd, buf.ptr, n, @intCast(a[3]));
                    if (value < 0) return hostError();
                    break :blk @as(u64, @intCast(value));
                } else try l.streamIO(s.*, a[0], buf, !reading);
                if (@as(i64, @bitCast(result)) < 0) return result;
                if (reading) try m.write(a[1], buf[0..@intCast(result)]);
                return @intCast(result);
            },
            .getcwd => {
                if (!l.allow_files) return negative(13);
                if (a[1] == 0) return negative(34);
                if (a[1] > 1024 * 1024) return negative(22);
                var buf: [4096]u8 = undefined;
                if (c.getcwd(&buf, buf.len) == null) return hostError();
                var path = buf[0 .. std.mem.indexOfScalar(u8, &buf, 0) orelse return error.InvalidHostPath];
                if (l.sysroot) |root| {
                    const physical = c.realpath(root.ptr, null);
                    if (physical == null) return hostError();
                    defer c.free(physical);
                    const prefix = std.mem.trimEnd(u8, std.mem.span(physical), "/");
                    if (!std.mem.startsWith(u8, path, prefix) or (path.len > prefix.len and path[prefix.len] != '/')) return negative(2);
                    path = if (path.len == prefix.len) buf[0..0] else path[prefix.len..];
                }
                if (path.len == 0) {
                    if (a[1] < 2) return negative(34);
                    try m.write(a[0], "/\x00");
                    return 2;
                }
                if (a[1] < path.len + 1) return negative(34);
                try m.check(a[0], path.len + 1, .write);
                try m.write(a[0], path);
                try m.writeInt(a[0] + path.len, 8, 0);
                return path.len + 1;
            },
            .readlink, .readlinkat => {
                const legacy = op == .readlink;
                const destination = a[if (legacy) 1 else 2];
                const size = a[if (legacy) 2 else 3];
                if (size == 0 or size > 1024 * 1024) return negative(22);
                try m.check(destination, @intCast(size), .write);
                const path = try m.cstring(l.allocator, a[if (legacy) 0 else 1], 4096);
                defer l.allocator.free(path);
                if (try Device.path(l.allocator, path) != null) return negative(22);
                if (!l.allow_files) return negative(13);
                const host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, path);
                defer l.allocator.free(host_path);
                const dir = if (legacy or std.fs.path.isAbsolutePosix(path)) c.AT_FDCWD else (try l.atDescriptor(a[0])) orelse return negative(9);
                const buf = try l.allocator.alloc(u8, @intCast(size));
                defer l.allocator.free(buf);
                const result = c.readlinkat(dir, host_path.ptr, buf.ptr, buf.len);
                if (result < 0) return hostError();
                try m.write(destination, buf[0..@intCast(result)]);
                return @intCast(result);
            },
            .open, .openat => {
                const path_addr = if (op == .open) a[0] else a[1];
                const flags = if (op == .open) a[1] else a[2];
                const mode = if (op == .open) a[2] else a[3];
                const path = m.cstring(l.allocator, path_addr, 4096) catch |err| {
                    // Keep permission-first behavior when no valid virtual-device name can be read.
                    if (!l.allow_files and err != error.OutOfMemory) return negative(13);
                    return err;
                };
                defer l.allocator.free(path);
                const directory: u64 = if (s.architecture == .arm64) 0x4000 else 0x10000;
                const nofollow: u64 = if (s.architecture == .arm64) 0x8000 else 0x20000;
                const largefile: u64 = if (s.architecture == .arm64) 0x20000 else 0x8000;
                const allowed: u64 = 3 | 64 | 128 | 512 | 1024 | 2048 | directory | nofollow | largefile | 0x80000;
                if (flags & ~allowed != 0 or flags & 3 == 3) return negative(22);
                if (try Device.path(l.allocator, path)) |kind| {
                    if (flags & directory != 0) return negative(20);
                    if (flags & (64 | 128) == 64 | 128) return negative(17);
                    const device = try l.allocator.create(Device);
                    device.* = .{ .allocator = l.allocator, .kind = kind, .status = flags & ~@as(u64, 64 | 128 | 512 | 0x80000) };
                    const slot = l.register(Device.fd, flags, 0);
                    if (slot >= l.devices.len) {
                        l.allocator.destroy(device);
                        return slot;
                    }
                    l.attachDevice(@intCast(slot), device);
                    return slot;
                }
                if (!l.allow_files) return negative(13);
                var translated: c_int = switch (flags & 3) {
                    0 => c.O_RDONLY,
                    1 => c.O_WRONLY,
                    2 => c.O_RDWR,
                    else => unreachable,
                };
                if (flags & 64 != 0) translated |= c.O_CREAT;
                if (flags & 128 != 0) translated |= c.O_EXCL;
                if (flags & 512 != 0) translated |= c.O_TRUNC;
                if (flags & 1024 != 0) translated |= c.O_APPEND;
                if (flags & 2048 != 0) translated |= c.O_NONBLOCK;
                if (flags & directory != 0) translated |= c.O_DIRECTORY;
                if (flags & nofollow != 0) translated |= c.O_NOFOLLOW;
                translated |= c.O_CLOEXEC;
                const host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, path);
                defer l.allocator.free(host_path);
                const dir = if (op == .open or std.fs.path.isAbsolutePosix(path)) c.AT_FDCWD else (try l.atDescriptor(a[0])) orelse return negative(9);
                // ponytail: serial native creation; concurrent embedding needs host umask isolation.
                const previous_mask = if (flags & 64 != 0) c.umask(l.creationMask()) else null;
                defer if (previous_mask) |previous| {
                    _ = c.umask(previous);
                };
                const fd = c.openat(dir, host_path.ptr, translated, @as(c.mode_t, @intCast(mode & 0o777)));
                return if (fd < 0) hostError() else l.register(fd, flags, 0);
            },
            .mkdir, .mkdirat, .unlink, .unlinkat, .rmdir => {
                if (!l.allow_files) return negative(13);
                const legacy = op == .mkdir or op == .unlink or op == .rmdir;
                const path = try m.cstring(l.allocator, a[if (legacy) 0 else 1], 4096);
                defer l.allocator.free(path);
                const flags: u64 = if (op == .unlinkat) a[2] else if (op == .rmdir) 0x200 else 0;
                if (flags & ~@as(u64, 0x200) != 0) return negative(22);
                if (try Device.path(l.allocator, path) != null) return negative(30);
                const host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, path);
                defer l.allocator.free(host_path);
                const dir = if (legacy or std.fs.path.isAbsolutePosix(path)) c.AT_FDCWD else (try l.atDescriptor(a[0])) orelse return negative(9);
                if (op == .mkdir or op == .mkdirat) {
                    const mode = if (op == .mkdirat) a[2] else a[1];
                    const previous_mask = c.umask(l.creationMask());
                    defer _ = c.umask(previous_mask);
                    return if (c.mkdirat(dir, host_path.ptr, @intCast(mode & 0o777)) < 0) hostError() else 0;
                }
                const host_flags: c_int = if (flags & 0x200 != 0) c.AT_REMOVEDIR else 0;
                return if (c.unlinkat(dir, host_path.ptr, host_flags) < 0) hostError() else 0;
            },
            .access, .faccessat => {
                const path_index: usize = if (op == .access) 0 else 1;
                const mode = a[if (op == .access) 1 else 2];
                if (mode & ~@as(u64, 7) != 0 or (op == .faccessat and a[3] != 0)) return negative(22);
                const path = try m.cstring(l.allocator, a[path_index], 4096);
                defer l.allocator.free(path);
                if (try Device.path(l.allocator, path) != null) return if (mode & 1 == 0) 0 else negative(13);
                if (!l.allow_files) return negative(13);
                const host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, path);
                defer l.allocator.free(host_path);
                const dir = if (op == .access or std.fs.path.isAbsolutePosix(path)) c.AT_FDCWD else (try l.atDescriptor(a[0])) orelse return negative(9);
                const result = if (op == .access) c.access(host_path.ptr, @intCast(mode)) else c.faccessat(dir, host_path.ptr, @intCast(mode), 0);
                return if (result < 0) hostError() else 0;
            },
            .rename, .renameat => {
                if (!l.allow_files) return negative(13);
                const legacy = op == .rename;
                const old_path = try m.cstring(l.allocator, a[if (legacy) 0 else 1], 4096);
                defer l.allocator.free(old_path);
                const new_path = try m.cstring(l.allocator, a[if (legacy) 1 else 3], 4096);
                defer l.allocator.free(new_path);
                if (try Device.path(l.allocator, old_path) != null or try Device.path(l.allocator, new_path) != null) return negative(30);
                const old_host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, old_path);
                defer l.allocator.free(old_host_path);
                const new_host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, new_path);
                defer l.allocator.free(new_host_path);
                const old_dir = if (legacy or std.fs.path.isAbsolutePosix(old_path)) c.AT_FDCWD else (try l.atDescriptor(a[0])) orelse return negative(9);
                const new_dir_index: usize = if (legacy) 0 else 2;
                const new_dir = if (legacy or std.fs.path.isAbsolutePosix(new_path)) c.AT_FDCWD else (try l.atDescriptor(a[new_dir_index])) orelse return negative(9);
                return if (c.renameat(old_dir, old_host_path.ptr, new_dir, new_host_path.ptr) < 0) hostError() else 0;
            },
            .utimensat => {
                if (!l.allow_files) return negative(13);
                if (a[3] & ~@as(u64, 0x100) != 0) return negative(22);
                var guest_times: [2]std.posix.timespec = undefined;
                if (a[2] != 0) {
                    try m.check(a[2], 32, .read);
                    for (&guest_times, 0..) |*ts, index| {
                        const offset: u64 = @intCast(index * 16);
                        const sec: i64 = @bitCast(try m.readInt(a[2] + offset, 64, .read));
                        const nsec: i64 = @bitCast(try m.readInt(a[2] + offset + 8, 64, .read));
                        if (nsec < 0 or (nsec > 999_999_999 and nsec != 1_073_741_823 and nsec != 1_073_741_822)) return negative(22);
                        ts.sec = @intCast(sec);
                        ts.nsec = @intCast(if (nsec == 1_073_741_823) c.UTIME_NOW else if (nsec == 1_073_741_822) c.UTIME_OMIT else nsec);
                    }
                }
                const times: [*c]const c.struct_timespec = if (a[2] == 0) null else @ptrCast(&guest_times[0]);
                if (a[1] == 0) {
                    if (a[3] != 0) return negative(22);
                    const number: u32 = @truncate(a[0]);
                    if (@as(i32, @bitCast(number)) == -100) return negative(14);
                    const fd = l.descriptor(number) orelse return negative(9);
                    if (fd == Device.fd) return negative(30);
                    return if (c.futimens(fd, times) < 0) hostError() else 0;
                }
                const path = try m.cstring(l.allocator, a[1], 4096);
                defer l.allocator.free(path);
                const host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, path);
                defer l.allocator.free(host_path);
                if (try Device.path(l.allocator, path) != null) return negative(30);
                const dir = if (std.fs.path.isAbsolutePosix(path)) c.AT_FDCWD else (try l.atDescriptor(a[0])) orelse return negative(9);
                const host_flags: c_int = if (a[3] & 0x100 != 0) c.AT_SYMLINK_NOFOLLOW else 0;
                return if (c.utimensat(dir, host_path.ptr, times, host_flags) < 0) hostError() else 0;
            },
            .close => return l.closeDescriptor(a[0]),
            .fsync, .fdatasync, .ftruncate => {
                const fd = l.descriptor(a[0]) orelse return negative(9);
                if (fd == Device.fd) return negative(22);
                if (op == .ftruncate and !l.allow_files) return negative(13);
                if (op == .ftruncate and a[1] > std.math.maxInt(i64)) return negative(22);
                // fsync also covers fdatasync's durability requirements on both hosts.
                const result = if (op == .ftruncate) c.ftruncate(fd, @intCast(a[1])) else c.fsync(fd);
                return if (result < 0) hostError() else 0;
            },
            .lseek => {
                const fd = l.descriptor(a[0]) orelse return negative(9);
                if (fd == Device.fd) return if (a[2] <= 4) 0 else negative(22);
                if (a[2] > 2) return negative(22);
                if (l.directories[@intCast(a[0])]) |dir| {
                    if (a[2] != 0 or a[1] > std.math.maxInt(c_long)) return negative(22);
                    c.seekdir(dir, @intCast(a[1]));
                    return a[1];
                }
                const result = c.lseek(fd, @bitCast(a[1]), @intCast(a[2]));
                return if (result < 0) hostError() else @intCast(result);
            },
            .brk => {
                if (a[0] == 0) return l.heap_end;
                if (a[0] >= l.heap_base and a[0] <= l.heap_limit) l.heap_end = a[0];
                return l.heap_end;
            },
            .mmap => {
                const allowed: u64 = 2 | 0x10 | 0x20 | 0x800 | 0x1000 | 0x20000 | 0x100000;
                if (a[1] == 0 or a[1] > m.limit or a[2] & ~@as(u64, 7) != 0 or a[3] & 3 != 2 or a[3] & ~allowed != 0 or a[5] % l.page_size != 0) return negative(22);
                const size: usize = @intCast(std.mem.alignForward(u64, a[1], l.page_size));
                const anonymous = a[3] & 0x20 != 0;
                const fixed = a[3] & (0x10 | 0x100000) != 0;
                const noreplace = a[3] & 0x100000 != 0;
                if (fixed and (a[0] < l.page_size or a[0] % l.page_size != 0 or a[0] > 0x800000000000 - size)) return negative(22);
                if (noreplace and !m.available(a[0], size)) return negative(17);
                var contents: ?[]u8 = null;
                defer if (contents) |bytes| l.allocator.free(bytes);
                var valid_size = size;
                if (!anonymous) {
                    const fd = l.descriptor(a[4]) orelse return negative(9);
                    if (l.open_flags[@intCast(a[4])] & 3 == 1) return negative(13);
                    if (a[5] > std.math.maxInt(i64) - size) return negative(75);
                    if (l.devices[@intCast(a[4])]) |device| {
                        if (device.kind != .zero) return negative(19);
                    } else {
                        if (!l.allow_files) return negative(13);
                        const stat = host.statFd(fd) catch return hostError();
                        if (!host.isRegular(stat.mode)) return negative(19);
                        if (stat.size < 0) return negative(22);
                        const length: u64 = @intCast(stat.size);
                        const bytes: usize = @intCast(@min(size, length - @min(length, a[5])));
                        valid_size = std.mem.alignForward(usize, bytes, l.page_size);
                        contents = try l.allocator.alloc(u8, bytes);
                        var done: usize = 0;
                        // ponytail: eager private snapshot; shared mappings and file-change coherence need page backing.
                        while (done < bytes) {
                            const n = c.pread(fd, contents.?.ptr + done, bytes - done, @intCast(a[5] + done));
                            if (n < 0) {
                                if (host.errno() == c.EINTR) continue;
                                return hostError();
                            }
                            if (n == 0) return negative(5); // File shrank while being copied; preserve a fixed destination.
                            done += @intCast(n);
                        }
                    }
                }
                const hint = a[0] & ~(@as(u64, l.page_size) - 1);
                const initial = if (m.available(hint, size)) hint else l.next_map;
                var addr = if (fixed) a[0] else try m.findFree(initial, size);
                while (addr % l.page_size != 0) addr = try m.findFree(std.mem.alignForward(u64, addr, l.page_size), size);
                const permissions = @import("../memory.zig").Permissions{ .read = a[2] & 1 != 0, .write = a[2] & 2 != 0, .execute = a[2] & 4 != 0 };
                if (fixed and !noreplace) try m.replace(addr, size, permissions) else try m.map(addr, size, permissions);
                if (contents) |bytes| {
                    try m.initialize(addr, bytes);
                    m.fileEnd(addr, valid_size);
                }
                if (!fixed and initial == l.next_map) l.next_map = addr + size + l.page_size;
                return addr;
            },
            .munmap, .mprotect => {
                if (a[1] == 0 or a[1] > m.limit or a[0] % l.page_size != 0) return negative(22);
                const size: usize = @intCast(std.mem.alignForward(u64, a[1], l.page_size));
                if (op == .munmap) try m.unmap(a[0], size) else {
                    if (a[2] & ~@as(u64, 7) != 0) return negative(22);
                    try m.protect(a[0], size, .{ .read = a[2] & 1 != 0, .write = a[2] & 2 != 0, .execute = a[2] & 4 != 0 });
                }
                return 0;
            },
            .clock_gettime => {
                if (a[0] > 1) return negative(22);
                try m.check(a[1], 16, .write);
                const ts = host.clock(if (a[0] == 0) .realtime else .monotonic) catch return hostError();
                try m.writeInt(a[1], 64, @intCast(ts.sec));
                try m.writeInt(a[1] + 8, 64, @intCast(ts.nsec));
                return 0;
            },
            .sysinfo => {
                try m.check(a[0], 112, .write);
                var bytes: [112]u8 = @splat(0);
                const now = host.nowNs() catch return hostError();
                put(&bytes, 0, 64, (now -| l.boot_ns) / 1_000_000_000);
                // No host process or memory-capacity information is exposed.
                put(&bytes, 32, 64, m.limit);
                put(&bytes, 40, 64, if (m.budget) |b| b.limit - b.used else m.limit - m.used);
                put(&bytes, 80, 16, l.process_count);
                put(&bytes, 104, 32, 1);
                try m.write(a[0], &bytes);
                return 0;
            },
            .time => {
                if (a[0] != 0) try m.check(a[0], 8, .write);
                const ts = host.clock(.realtime) catch return hostError();
                const seconds: u64 = @bitCast(ts.sec);
                if (a[0] != 0) try m.writeInt(a[0], 64, seconds);
                return seconds;
            },
            .gettimeofday => {
                if (a[0] != 0) try m.check(a[0], 16, .write);
                if (a[1] != 0) try m.check(a[1], 8, .write);
                if (a[0] != 0) {
                    const ts = host.clock(.realtime) catch return hostError();
                    try m.writeInt(a[0], 64, @bitCast(ts.sec));
                    try m.writeInt(a[0] + 8, 64, @intCast(@divTrunc(ts.nsec, 1000)));
                }
                // Obsolete kernel timezone metadata is modeled as UTC, without DST.
                if (a[1] != 0) try m.writeInt(a[1], 64, 0);
                return 0;
            },
            .getrandom => {
                if (a[1] > 1024 * 1024 or a[2] & ~@as(u64, 3) != 0) return negative(22);
                try m.check(a[0], @intCast(a[1]), .write);
                const buf = try l.allocator.alloc(u8, @intCast(a[1]));
                defer l.allocator.free(buf);
                try host.random(buf);
                try m.write(a[0], buf);
                return a[1];
            },
            .uname => {
                var buf: [390]u8 = @splat(0);
                const names = [_][]const u8{ "Linux", "universe", "6.0.0-universe", "UNIVERSE experimental ABI", switch (s.architecture) {
                    .x86_64 => "x86_64",
                    .riscv64 => "riscv64",
                    .arm64 => "aarch64",
                }, "localdomain" };
                for (names, 0..) |name, i| @memcpy(buf[i * 65 ..][0..name.len], name);
                try m.write(a[0], &buf);
                return 0;
            },
            .fstat, .newfstatat, .stat, .lstat => {
                var stat = if (op == .fstat) blk: {
                    const fd = l.descriptor(a[0]) orelse return negative(9);
                    break :blk if (l.devices[@intCast(a[0])]) |device| Device.stat(device.kind) else host.statFd(fd) catch return hostError();
                } else if (op == .stat or op == .lstat) blk: {
                    const path = try m.cstring(l.allocator, a[0], 4096);
                    defer l.allocator.free(path);
                    if (try Device.path(l.allocator, path)) |kind| break :blk Device.stat(kind);
                    if (!l.allow_files) return negative(13);
                    const host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, path);
                    defer l.allocator.free(host_path);
                    break :blk host.statAt(c.AT_FDCWD, host_path, op == .lstat) catch return hostError();
                } else blk: {
                    if (a[3] & ~@as(u64, 0x100) != 0) return negative(22);
                    const path = try m.cstring(l.allocator, a[1], 4096);
                    defer l.allocator.free(path);
                    if (try Device.path(l.allocator, path)) |kind| break :blk Device.stat(kind);
                    if (!l.allow_files) return negative(13);
                    const host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, path);
                    defer l.allocator.free(host_path);
                    const dir = if (std.fs.path.isAbsolutePosix(path)) c.AT_FDCWD else (try l.atDescriptor(a[0])) orelse return negative(9);
                    break :blk host.statAt(dir, host_path, a[3] & 0x100 != 0) catch return hostError();
                };
                if (op == .fstat and l.pipes[@intCast(a[0])] != null) {
                    stat.uid = 1000;
                    stat.gid = 1000;
                    stat.size = 0;
                    stat.blksize = Pipe.capacity;
                    stat.blocks = 0;
                }
                const destination = if (op == .newfstatat) a[2] else a[1];
                try packStat(m, destination, stat, s.architecture == .x86_64);
                return 0;
            },
        }
    }
};

test "absolute virtual devices preserve memory guards, file grants, stat layouts and failed opens on every Linux ABI" {
    const allocator = std.testing.allocator;
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var l = Linux{ .allocator = allocator, .sysroot = "/universe-device-root-does-not-exist" };
        defer l.deinit();
        var m = Memory.init(allocator);
        defer m.deinit();
        try m.map(0x1000, 4096, .{ .read = true, .write = true });
        try m.write(0x1000, "/dev/./null\x00/dev/zero\x00/ordinary-file\x00");
        var s = State{ .architecture = arch };
        try std.testing.expectEqual(@as(u64, 3), try l.invoke(&s, &m, .openat, .{ 99, 0x1000, 2, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 4), try l.invoke(&s, &m, .openat, .{ 99, 0x100c, 2, 0, 0, 0 }));
        try std.testing.expectEqual(negative(13), try l.invoke(&s, &m, .openat, .{ 99, 0x1016, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .read, .{ 3, 1, 8, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 8), try l.invoke(&s, &m, .pwrite64, .{ 4, 1, 8, 42, 0, 0 }));
        try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .write, .{ 3, 0xffffffffffffffff, 8, 0, 0, 0 }));
        try m.write(0x1100, "XXXXXXXX");
        try std.testing.expectEqual(@as(u64, 4), try l.invoke(&s, &m, .pread64, .{ 4, 0x1102, 4, 42, 0, 0 }));
        var bytes: [8]u8 = undefined;
        try m.read(0x1100, &bytes, .read);
        try std.testing.expectEqualSlices(u8, "XX\x00\x00\x00\x00XX", &bytes);
        try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .read, .{ 4, 1, 8, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .fstat, .{ 3, 0x1200, 0, 0, 0, 0 }));
        const x86 = arch == .x86_64;
        try std.testing.expectEqual(@as(u64, 0o20666), try m.readInt(0x1200 + @as(u64, if (x86) 24 else 16), 32, .read));
        try std.testing.expectEqual(@as(u64, 0x103), try m.readInt(0x1200 + @as(u64, if (x86) 40 else 32), 64, .read));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .newfstatat, .{ 99, 0x100c, 0x1200, 0x100, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0x105), try m.readInt(0x1200 + @as(u64, if (x86) 40 else 32), 64, .read));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .faccessat, .{ 99, 0x100c, 6, 0, 0, 0 }));
        try std.testing.expectEqual(negative(13), try l.invoke(&s, &m, .faccessat, .{ 99, 0x100c, 1, 0, 0, 0 }));
        try m.writeInt(0x1300, 32, 3);
        try m.writeInt(0x1304, 16, 0x145);
        try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .poll, .{ 0x1300, 1, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0x145), try m.readInt(0x1306, 16, .read));
        const mapped = try l.invoke(&s, &m, .mmap, .{ 0, 4096, 3, 2, 4, 4096 });
        try std.testing.expectEqual(@as(u64, 0), try m.readInt(mapped + 4088, 64, .read));
        try m.writeInt(mapped, 64, 42);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .munmap, .{ mapped, 4096, 0, 0, 0, 0 }));
        try std.testing.expectEqual(negative(19), try l.invoke(&s, &m, .mmap, .{ 0, 4096, 3, 2, 3, 0 }));
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .fsync, .{ 4, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(negative(20), try l.invoke(&s, &m, .getdents64, .{ 4, 0x1100, 8, 0, 0, 0 }));
        l.allow_files = true;
        try std.testing.expectEqual(negative(30), try l.invoke(&s, &m, .unlinkat, .{ 99, 0x1000, 0, 0, 0, 0 }));
        try std.testing.expectEqual(negative(30), try l.invoke(&s, &m, .renameat, .{ 99, 0x1000, 99, 0x1016, 0, 0 }));
        try std.testing.expectEqual(negative(30), try l.invoke(&s, &m, .utimensat, .{ 4, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(negative(17), try l.invoke(&s, &m, .openat, .{ 99, 0x1000, 64 | 128, 0, 0, 0 }));
        try std.testing.expectEqual(negative(20), try l.invoke(&s, &m, .openat, .{ 99, 0x1000, if (arch == .arm64) 0x4000 else 0x10000, 0, 0, 0 }));
        try m.write(0x1400, "/dev/zero/\x00");
        try std.testing.expectEqual(negative(20), try l.invoke(&s, &m, .openat, .{ 99, 0x1400, 0, 0, 0, 0 }));
        for (&l.descriptors, &l.borrowed, 0..) |*fd, *borrowed, i| if (i > 4) {
            fd.* = 1;
            borrowed.* = true;
        };
        const before = l.descriptors;
        try std.testing.expectEqual(negative(24), try l.invoke(&s, &m, .openat, .{ 99, 0x1000, 2, 0, 0, 0 }));
        try std.testing.expectEqualSlices(?c_int, &before, &l.descriptors);
    }
    for (0..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var l = Linux{ .allocator = failing.allocator() };
        defer l.deinit();
        var m = Memory.init(allocator);
        defer m.deinit();
        try m.map(0x1000, 4096, .{ .read = true, .write = true });
        try m.write(0x1000, "/dev/zero\x00");
        var s = State{ .architecture = .x86_64 };
        const result = try l.invoke(&s, &m, .openat, .{ 99, 0x1000, 2, 0, 0, 0 });
        try std.testing.expectEqual(@as(u64, if (failing.has_induced_failure) negative(12) else 3), result);
        if (failing.has_induced_failure) try std.testing.expect(l.descriptors[3] == null and l.devices[3] == null);
    }
}

test "virtual devices share flags through dup and fork, respect CLOEXEC and release every descriptor reference" {
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        const allocator = std.testing.allocator;
        var l = Linux{ .allocator = allocator };
        defer l.deinit();
        var m = Memory.init(allocator);
        defer m.deinit();
        var state = State{ .architecture = arch };
        const device = try allocator.create(Device);
        device.* = .{ .allocator = allocator, .kind = .zero, .status = 2 };
        try std.testing.expectEqual(@as(u64, 3), l.register(Device.fd, 2, 0));
        l.attachDevice(3, device);
        try std.testing.expectEqual(@as(u64, 7), try l.invoke(&state, &m, .dup3, .{ 3, 7, 0x80000, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 8), try l.invoke(&state, &m, .fcntl, .{ 7, 1030, 8, 0, 0, 0 }));
        try std.testing.expectEqual(@as(usize, 3), device.references);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&state, &m, .fcntl, .{ 8, 4, 0x802, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0x802), try l.invoke(&state, &m, .fcntl, .{ 3, 3, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 1), try l.invoke(&state, &m, .fcntl, .{ 7, 1, 0, 0, 0, 0 }));
        var child = try l.fork(2);
        defer child.deinit();
        try std.testing.expectEqual(@as(usize, 6), device.references);
        try std.testing.expectEqual(device, child.devices[3].?);
        try std.testing.expectEqual(@as(u64, 0), try child.invoke(&state, &m, .fcntl, .{ 3, 4, 0x402, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0x402), try l.invoke(&state, &m, .fcntl, .{ 8, 3, 0, 0, 0, 0 }));
        try std.testing.expectError(error.NotDirectory, child.atDescriptor(3));
        l.afterExec(0x10000);
        try std.testing.expect(l.descriptors[7] == null and l.devices[7] == null and l.descriptors[8] == null and l.devices[8] == null);
        try std.testing.expectEqual(@as(usize, 4), device.references);
        try std.testing.expectEqual(@as(u64, 0), l.closeDescriptor(3));
        try std.testing.expectEqual(@as(usize, 3), device.references);
        try std.testing.expectEqual(@as(u64, 0), child.closeDescriptor(3));
        try std.testing.expectEqual(@as(u64, 0), child.closeDescriptor(7));
        try std.testing.expectEqual(@as(u64, 0), child.closeDescriptor(8));
        try std.testing.expect(child.devices[3] == null and child.devices[7] == null and child.devices[8] == null);
    }
}

test "fork inherits descriptor offsets, shared pipe ends, independent masks and calling-thread metadata" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var parent = Linux{ .allocator = a };
    defer parent.deinit();
    var s = State{ .architecture = .x86_64 };
    parent.threads.initial = .{ .clear_tid = 0x1100, .signal_mask = 42, .poll_deadline = 99 };
    try std.testing.expectEqual(@as(u64, 0), try parent.invoke(&s, &m, .pipe2, .{ 0x1000, 0x80000, 0, 0, 0, 0 }));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = c.openat(tmp.dir.handle, "fork-offset", c.O_CREAT | c.O_RDWR | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    try std.testing.expect(file >= 0);
    try std.testing.expectEqual(@as(u64, 5), parent.register(file, 2, 0));
    try m.write(0x1010, "abc");
    try std.testing.expectEqual(@as(u64, 3), try parent.invoke(&s, &m, .write, .{ 5, 0x1010, 3, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try parent.invoke(&s, &m, .lseek, .{ 5, 0, 0, 0, 0, 0 }));
    _ = try parent.invoke(&s, &m, .umask, .{ 0o022, 0, 0, 0, 0, 0 });
    var child = try parent.fork(42);
    defer child.deinit();
    try std.testing.expectEqual(@as(u64, 42), try child.invoke(&s, &m, .getpid, @splat(0)));
    try std.testing.expectEqual(@as(u64, 1), try child.invoke(&s, &m, .getppid, @splat(0)));
    try std.testing.expectEqual(@as(u64, 42), try child.invoke(&s, &m, .gettid, @splat(0)));
    try std.testing.expect(!child.threads.contains(1));
    try std.testing.expectEqual(@as(u64, 0), child.threads.initial.clear_tid);
    try std.testing.expectEqual(@as(u64, 42), child.threads.initial.signal_mask);
    try std.testing.expect(child.threads.initial.poll_deadline == null);
    try std.testing.expectEqual(@as(u64, 0o022), try child.invoke(&s, &m, .umask, .{ 0o077, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(c.mode_t, 0o022), parent.mask.?);
    for (parent.descriptors, 0..) |fd, index| if (fd) |original| try std.testing.expect(original != child.descriptors[index].?);
    try std.testing.expectEqual(@as(u32, 1), child.fd_flags[3]);
    try std.testing.expectEqual(@as(usize, 2), child.pipes[3].?.readers);
    try std.testing.expectEqual(@as(usize, 2), child.pipes[3].?.writers);
    for ([_]*Linux{ &child, &parent, &parent }, 0..) |process, index| {
        try std.testing.expectEqual(@as(u64, 1), try process.invoke(&s, &m, .read, .{ 5, 0x1100, 1, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, "abc"[index]), try m.readInt(0x1100, 8, .read));
    }
    try std.testing.expectEqual(@as(u64, 0), try child.invoke(&s, &m, .close, .{ 4, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 1), try parent.invoke(&s, &m, .write, .{ 4, 0x1010, 1, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 1), try child.invoke(&s, &m, .read, .{ 3, 0x1100, 1, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try parent.invoke(&s, &m, .close, .{ 4, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try child.invoke(&s, &m, .read, .{ 3, 0x1100, 1, 0, 0, 0 }));
}

test "exec resets calling-thread state and caught actions while closing only CLOEXEC guest descriptors" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var l = Linux{ .allocator = a, .pid = 7, .parent_pid = 1, .boot_ns = 99, .mask = 0o022 };
    defer l.deinit();
    var s = State{ .architecture = .x86_64 };
    _ = try l.invoke(&s, &m, .pipe2, .{ 0x1000, 0x80000, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(u64, 5), try l.invoke(&s, &m, .dup, .{ 4, 0, 0, 0, 0, 0 }));
    const pipe = l.pipes[5].?;
    _ = try l.threads.clone(a, s, &m, .{ 0x10f00, 0x1800, 0, 0, 0, 0 });
    try std.testing.expect(try l.threads.schedule(&s));
    l.threads.metadata().signal_mask = 42;
    l.threads.metadata().clear_tid = 0x1100;
    l.threads.metadata().alternate_stack[8] = 0;
    try l.threads.waitPipe(a, s, pipe, false, 1);
    put(&l.signal_actions[0], 0, 64, 0x1234);
    @memset(&l.signal_actions[1], 0xff);
    put(&l.signal_actions[1], 0, 64, 1);
    l.afterExec(0x4000);
    try std.testing.expectEqual(@as(u32, 7), l.threads.id());
    try std.testing.expectEqual(@as(u32, 1), l.parent_pid);
    try std.testing.expectEqual(@as(u64, 99), l.boot_ns);
    try std.testing.expectEqual(@as(c.mode_t, 0o022), l.mask.?);
    try std.testing.expectEqual(@as(usize, 0), l.threads.records.items.len);
    try std.testing.expectEqual(@as(u64, 42), l.threads.metadata().signal_mask);
    try std.testing.expectEqual(@as(u64, 0), l.threads.metadata().clear_tid);
    try std.testing.expectEqual(@as(u8, 2), l.threads.metadata().alternate_stack[8]);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &l.signal_actions[0]);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, l.signal_actions[1][0..8], .little));
    try std.testing.expectEqualSlices(u8, &@as([24]u8, @splat(0)), l.signal_actions[1][8..]);
    try std.testing.expect(l.descriptors[0] != null and l.descriptors[3] == null and l.descriptors[4] == null and l.descriptors[5] != null);
    try std.testing.expectEqual(@as(usize, 0), pipe.readers);
    try std.testing.expectEqual(@as(usize, 1), pipe.writers);
    try std.testing.expectEqual(@as(u64, 0x4000), l.heap_end);
}

test "pipe2 publishes two private guest descriptors across Linux ABIs and preserves failed outputs" {
    const allocator = std.testing.allocator;
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var m = Memory.init(allocator);
        defer m.deinit();
        try m.map(0x1000, 8192, .{ .read = true, .write = true });
        var l = Linux{ .allocator = allocator };
        defer l.deinit();
        var s = State{ .architecture = arch };
        try std.testing.expectEqual(Operation.pipe2, try operation(s, if (arch == .x86_64) 293 else 59));
        if (arch == .x86_64) try std.testing.expectEqual(Operation.pipe, try operation(s, 22));
        try m.write(0x1ffc, "sentinel");
        const before = l.descriptors;
        for ([_]u64{ 1, 0x4000, 0x200000, 0xffffffff }) |flags| {
            try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .pipe2, .{ 0x1ffc, flags, 0, 0, 0, 0 }));
            try std.testing.expectEqualSlices(?c_int, &before, &l.descriptors);
            var output: [8]u8 = undefined;
            try m.read(0x1ffc, &output, .read);
            try std.testing.expectEqualStrings("sentinel", &output);
        }
        try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .pipe2, .{ 0x2ffc, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqualSlices(?c_int, &before, &l.descriptors);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .pipe2, .{ 0x1ffc, 0x100080800, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 3), try m.readInt(0x1ffc, 32, .read));
        try std.testing.expectEqual(@as(u64, 4), try m.readInt(0x2000, 32, .read));
        for ([_]u64{ 3, 4 }, 0..) |fd, end| {
            try std.testing.expect(!l.borrowed[@intCast(fd)]);
            try std.testing.expect(c.fcntl(l.descriptors[@intCast(fd)].?, c.F_GETFD) & c.FD_CLOEXEC != 0);
            try std.testing.expect(c.fcntl(l.descriptors[@intCast(fd)].?, c.F_GETFL) & c.O_NONBLOCK != 0);
            try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .fcntl, .{ fd, 1, 0, 0, 0, 0 }));
            try std.testing.expectEqual(@as(u64, 0x800) | end, try l.invoke(&s, &m, .fcntl, .{ fd, 3, 0, 0, 0, 0 }));
        }
        const pipe = l.pipes[3].?;
        try std.testing.expect(pipe == l.pipes[4].? and pipe.readers == 1 and pipe.writers == 1);
    }
}

test "pipe atomic writes, shared status, vector bytes, EOF and broken ends do not signal the host" {
    const allocator = std.testing.allocator;
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 16384, .{ .read = true, .write = true });
    var l = Linux{ .allocator = allocator };
    defer l.deinit();
    var s = State{ .architecture = .x86_64 };
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .pipe2, .{ 0x1000, 0x800, 0, 0, 0, 0 }));
    const pipe = l.pipes[3].?;
    var bytes: [4096]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i);
    try m.write(0x2000, &bytes);
    try std.testing.expectEqual(@as(u64, 4096), try l.invoke(&s, &m, .write, .{ 4, 0x2000, 4096, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 512), try l.invoke(&s, &m, .read, .{ 3, 0x3000, 512, 0, 0, 0 }));
    // Darwin would publish 512 bytes here; a Linux atomic write must publish none.
    try std.testing.expectEqual(negative(11), try l.invoke(&s, &m, .write, .{ 4, 0x2000, 4096, 0, 0, 0 }));
    try std.testing.expectEqual(@as(usize, 3584), pipe.used);
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .ioctl, .{ 3, 0x541b, 0x1010, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 3584), try m.readInt(0x1010, 32, .read));
    try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .read, .{ 3, 0x4fff, 3584, 0, 0, 0 }));
    try std.testing.expectEqual(@as(usize, 3584), pipe.used);
    for ([_]u64{ 0x1018, 0x1028 }, 0..) |addr, i| {
        try m.writeInt(addr, 64, 0x3200 + i * 1792);
        try m.writeInt(addr + 8, 64, 1792);
    }
    try std.testing.expectEqual(@as(u64, 3584), try l.invoke(&s, &m, .readv, .{ 3, 0x1018, 2, 0, 0, 0 }));
    var output: [4096]u8 = undefined;
    try m.read(0x3000, &output, .read);
    try std.testing.expectEqualSlices(u8, &bytes, &output);
    try std.testing.expectEqual(@as(u64, 4096), try l.invoke(&s, &m, .write, .{ 4, 0x2000, 8192, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 4096), try l.invoke(&s, &m, .read, .{ 3, 0x3000, 4096, 0, 0, 0 }));
    try m.read(0x3000, &output, .read);
    try std.testing.expectEqualSlices(u8, &bytes, &output);
    try std.testing.expectEqual(@as(u64, 5), try l.invoke(&s, &m, .dup, .{ 3, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .fcntl, .{ 5, 4, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .fcntl, .{ 3, 3, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .fcntl, .{ 3, 4, 0x800, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0x800), try l.invoke(&s, &m, .fcntl, .{ 5, 3, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .close, .{ 5, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 5), try l.invoke(&s, &m, .fcntl, .{ 4, 1030, 5, 0, 0, 0 }));
    try std.testing.expectEqual(@as(usize, 2), pipe.writers);
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .close, .{ 4, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(negative(11), try l.invoke(&s, &m, .read, .{ 3, 0x3000, 1, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .close, .{ 5, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .read, .{ 3, 0x3000, 1, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .close, .{ 3, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .pipe, .{ 0x1000, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .close, .{ 3, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(negative(32), try l.invoke(&s, &m, .write, .{ 4, 0x2000, 1, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .write, .{ 4, 0x2000, 0, 0, 0, 0 }));
    try std.testing.expectEqual(negative(9), try l.invoke(&s, &m, .read, .{ 4, 0x3000, 1, 0, 0, 0 }));
}

test "blocked pipe reads retry the trap with unchanged syscall registers on three ABIs" {
    const allocator = std.testing.allocator;
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var m = Memory.init(allocator);
        defer m.deinit();
        try m.map(0x1000, 4096, .{ .read = true, .write = true });
        var l = Linux{ .allocator = allocator };
        defer l.deinit();
        var s = State{ .architecture = arch, .pc = 0x5000, .instructions = 10 };
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .pipe2, .{ 0x1000, 0, 0, 0, 0, 0 }));
        const regs: [4]u6 = if (arch == .x86_64) .{ 0, 7, 6, 2 } else if (arch == .riscv64) .{ 17, 10, 11, 12 } else .{ 8, 0, 1, 2 };
        for (regs, [_]u64{ if (arch == .x86_64) 0 else 63, 3, 0x1100, 1 }) |reg, value| s.set(reg, value);
        s.pc += if (arch == .x86_64) @as(u64, 2) else 4;
        var expected = s;
        expected.pc = 0x5000;
        try l.dispatch(&s, &m);
        try std.testing.expectEqualDeep(expected, s);
        try std.testing.expect(l.threads.blocked());
        try std.testing.expect(!try l.threads.schedule(&s));
        try m.write(0x1200, "x");
        try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .write, .{ 4, 0x1200, 1, 0, 0, 0 }));
        try std.testing.expect(try l.threads.schedule(&s));
        try std.testing.expectEqualDeep(expected, s);
        s.pc += if (arch == .x86_64) @as(u64, 2) else 4;
        try l.dispatch(&s, &m);
        try std.testing.expectEqual(@as(u64, 1), s.get(if (arch == .riscv64) 10 else 0));
        try std.testing.expectEqual(@as(u64, 'x'), try m.readInt(0x1100, 8, .read));
    }
}

test "pipe allocation and descriptor exhaustion leave native handles and guest buffers unchanged" {
    const allocator = std.testing.allocator;
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.write(0x1100, "sentinel");
    var s = State{ .architecture = .x86_64 };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var l = Linux{ .allocator = failing.allocator() };
    defer l.deinit();
    const before = l.descriptors;
    const probe = c.open("/dev/null", c.O_RDONLY | c.O_CLOEXEC);
    try std.testing.expect(probe >= 0);
    _ = c.close(probe);
    try std.testing.expectEqual(negative(12), try l.invoke(&s, &m, .pipe2, .{ 0x1100, 0, 0, 0, 0, 0 }));
    const after = c.open("/dev/null", c.O_RDONLY | c.O_CLOEXEC);
    defer _ = c.close(after);
    try std.testing.expectEqual(probe, after);
    try std.testing.expectEqualSlices(?c_int, &before, &l.descriptors);
    for (&l.descriptors, &l.borrowed, 0..) |*fd, *borrowed, i| if (i >= 3 and i != 63) {
        fd.* = 1;
        borrowed.* = true;
    };
    const full = l.descriptors;
    try std.testing.expectEqual(negative(24), try l.invoke(&s, &m, .pipe2, .{ 0x1100, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqualSlices(?c_int, &full, &l.descriptors);
    var output: [8]u8 = undefined;
    try m.read(0x1100, &output, .read);
    try std.testing.expectEqualStrings("sentinel", &output);
}

test "pipe poll readiness and timeout retries retain one absolute deadline" {
    const allocator = std.testing.allocator;
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var l = Linux{ .allocator = allocator };
    defer l.deinit();
    var s = State{ .architecture = .x86_64 };
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .pipe2, .{ 0x1000, 0, 0, 0, 0, 0 }));
    try m.writeInt(0x1100, 32, 3);
    try m.writeInt(0x1104, 16, 1);
    try m.writeInt(0x1106, 16, 0xffff);
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .poll, .{ 0x1100, 1, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1106, 16, .read));
    try std.testing.expectError(error.SyscallPending, l.invoke(&s, &m, .poll, .{ 0x1100, 1, 1000, 0, 0, 0 }));
    const deadline = l.threads.metadata().poll_deadline.?;
    l.threads.records.items[0].wait.?.deadline = 0;
    try std.testing.expect(try l.threads.schedule(&s));
    try std.testing.expectError(error.SyscallPending, l.invoke(&s, &m, .poll, .{ 0x1100, 1, 1000, 0, 0, 0 }));
    try std.testing.expectEqual(deadline, l.threads.metadata().poll_deadline.?);
    l.threads.records.items[0].wait.?.deadline = 0;
    try std.testing.expect(try l.threads.schedule(&s));
    l.threads.metadata().poll_deadline = 0;
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .poll, .{ 0x1100, 1, 1000, 0, 0, 0 }));
    try std.testing.expect(l.threads.metadata().poll_deadline == null);
    try m.write(0x1200, "data");
    try std.testing.expectEqual(@as(u64, 4), try l.invoke(&s, &m, .write, .{ 4, 0x1200, 4, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .poll, .{ 0x1100, 1, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 1), try m.readInt(0x1106, 16, .read));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .close, .{ 4, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .poll, .{ 0x1100, 1, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 17), try m.readInt(0x1106, 16, .read));
}

test "sysinfo reports the guest memory budget and tracks mapping changes" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true });
    var linux = Linux{ .allocator = std.testing.allocator, .boot_ns = (try host.nowNs()) -| 5_000_000_000 };
    defer linux.deinit();
    var state = State{ .architecture = .x86_64 };
    for (0..3) |iteration| {
        if (iteration == 1) try memory.map(0x4000, 8192, .{ .read = true });
        if (iteration == 2) try memory.unmap(0x4000, 8192);
        try std.testing.expectEqual(@as(u64, 0), try linux.invoke(&state, &memory, .sysinfo, .{ 0x1100, 0, 0, 0, 0, 0 }));
        try std.testing.expect(try memory.readInt(0x1100, 64, .read) >= 5);
        try std.testing.expectEqual(@as(u64, memory.limit), try memory.readInt(0x1120, 64, .read));
        try std.testing.expectEqual(@as(u64, memory.limit - memory.used), try memory.readInt(0x1128, 64, .read));
        try std.testing.expectEqual(@as(u64, 1), try memory.readInt(0x1150, 16, .read));
        try std.testing.expectEqual(@as(u64, 1), try memory.readInt(0x1168, 32, .read));
        var bytes: [112]u8 = undefined;
        try memory.read(0x1100, &bytes, .read);
        @memset(bytes[0..8], 0); // Uptime depends only on elapsed host monotonic time.
        @memset(bytes[32..48], 0);
        bytes[80] = 0;
        bytes[104] = 0;
        try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 112), &bytes);
    }
    const sentinel = [_]u8{0xaa} ** 16;
    try memory.write(0x1ff0, &sentinel);
    try std.testing.expectEqual(negative(14), try linux.invoke(&state, &memory, .sysinfo, .{ 0x1ff0, 0, 0, 0, 0, 0 }));
    var actual: [16]u8 = undefined;
    try memory.read(0x1ff0, &actual, .read);
    try std.testing.expectEqualSlices(u8, &sentinel, &actual);
}

test "guest umask keeps independent permission bits without changing the host mask" {
    const original = c.umask(0o022);
    defer _ = c.umask(original);
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .riscv64, .arm64 }) |architecture| {
        {
            var linux = Linux{ .allocator = std.testing.allocator };
            defer linux.deinit();
            var state = State{ .architecture = architecture };
            try std.testing.expectEqual(@as(u64, 0o022), try linux.invoke(&state, &memory, .umask, .{ std.math.maxInt(u64), 0, 0, 0, 0, 0 }));
            try std.testing.expectEqual(@as(c.mode_t, 0o022), c.umask(0o022));
            try std.testing.expectEqual(@as(u64, 0o777), try linux.invoke(&state, &memory, .umask, .{ 0o077, 0, 0, 0, 0, 0 }));
            var other = Linux{ .allocator = std.testing.allocator };
            defer other.deinit();
            try std.testing.expectEqual(@as(u64, 0o022), try other.invoke(&state, &memory, .umask, .{ 0, 0, 0, 0, 0, 0 }));
            try std.testing.expectEqual(@as(u64, 0o077), try linux.invoke(&state, &memory, .umask, .{ 0, 0, 0, 0, 0, 0 }));
        }
        try std.testing.expectEqual(@as(c.mode_t, 0o022), c.umask(0o022));
    }
}

test "wall clocks handle optional buffers and validate outputs before writing" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true });
    var linux = Linux{ .allocator = std.testing.allocator };
    defer linux.deinit();
    var state = State{ .architecture = .x86_64 };
    const before = try host.clock(.realtime);
    try std.testing.expectEqual(@as(u64, 0), try linux.invoke(&state, &memory, .gettimeofday, .{ 0x1100, 0x1200, 0, 0, 0, 0 }));
    const after = try host.clock(.realtime);
    const sec = try memory.readInt(0x1100, 64, .read);
    const micro = try memory.readInt(0x1108, 64, .read);
    const captured = @as(i128, sec) * 1_000_000 + micro;
    try std.testing.expect(captured >= @as(i128, before.sec) * 1_000_000 + @divTrunc(before.nsec, 1000));
    try std.testing.expect(captured <= @as(i128, after.sec) * 1_000_000 + @divTrunc(after.nsec, 1000));
    try std.testing.expect(micro < 1_000_000);
    try std.testing.expectEqual(@as(u64, 0), try memory.readInt(0x1200, 64, .read));
    for ([_][2]u64{ .{ 0, 0 }, .{ 0, 0x1200 }, .{ 0x1100, 0 } }) |pointers| {
        try std.testing.expectEqual(@as(u64, 0), try linux.invoke(&state, &memory, .gettimeofday, .{ pointers[0], pointers[1], 0, 0, 0, 0 }));
    }
    for ([_][2]u64{ .{ 0x1ff8, 0x1200 }, .{ 0x1100, 0x1ffc } }) |pointers| {
        const bytes = [_]u8{0xaa} ** 24;
        try memory.write(0x1100, &bytes);
        try memory.writeInt(0x1200, 64, 0xaaaaaaaaaaaaaaaa);
        try std.testing.expectEqual(negative(14), try linux.invoke(&state, &memory, .gettimeofday, .{ pointers[0], pointers[1], 0, 0, 0, 0 }));
        var actual: [24]u8 = undefined;
        try memory.read(0x1100, &actual, .read);
        try std.testing.expectEqualSlices(u8, &bytes, &actual);
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try memory.readInt(0x1200, 64, .read));
    }
    const seconds = try linux.invoke(&state, &memory, .time, .{ 0x1100, 0, 0, 0, 0, 0 });
    try std.testing.expect(seconds >= sec);
    try std.testing.expectEqual(seconds, try memory.readInt(0x1100, 64, .read));
    try std.testing.expect(try linux.invoke(&state, &memory, .time, .{ 0, 0, 0, 0, 0, 0 }) >= seconds);
    try std.testing.expectEqual(negative(14), try linux.invoke(&state, &memory, .time, .{ 0x1ffc, 0, 0, 0, 0, 0 }));
}
fn packStat(m: *Memory, address: u64, s: host.FileStat, x86: bool) !void {
    var b: [144]u8 = @splat(0);
    put(&b, 0, 64, s.dev);
    put(&b, 8, 64, s.ino);
    if (x86) {
        put(&b, 16, 64, s.nlink);
        put(&b, 24, 32, s.mode);
        put(&b, 28, 32, s.uid);
        put(&b, 32, 32, s.gid);
        put(&b, 40, 64, s.rdev);
        put(&b, 48, 64, @bitCast(s.size));
        put(&b, 56, 64, s.blksize);
        put(&b, 64, 64, @bitCast(s.blocks));
    } else {
        put(&b, 16, 32, s.mode);
        put(&b, 20, 32, s.nlink);
        put(&b, 24, 32, s.uid);
        put(&b, 28, 32, s.gid);
        put(&b, 32, 64, s.rdev);
        put(&b, 48, 64, @bitCast(s.size));
        put(&b, 56, 32, s.blksize);
        put(&b, 64, 64, @bitCast(s.blocks));
    }
    put(&b, 72, 64, @bitCast(s.atime.sec));
    put(&b, 80, 64, @intCast(s.atime.nsec));
    put(&b, 88, 64, @bitCast(s.mtime.sec));
    put(&b, 96, 64, @intCast(s.mtime.nsec));
    put(&b, 104, 64, @bitCast(s.ctime.sec));
    put(&b, 112, 64, @intCast(s.ctime.nsec));
    try m.write(address, b[0..if (x86) 144 else 128]);
}
fn put(b: []u8, o: usize, w: u7, v: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, v, .little);
    @memcpy(b[o..][0 .. w / 8], bytes[0 .. w / 8]);
}
test "syscall buffers are checked before host reads and default files denied" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    var s = State{ .architecture = .x86_64 };
    var l = Linux{ .allocator = std.testing.allocator };
    defer l.deinit();
    s.set(0, 0);
    s.set(7, 0);
    s.set(6, 0);
    s.set(2, 1);
    try l.dispatch(&s, &m);
    try std.testing.expectEqual(negative(14), s.get(0));
    s.set(0, 257);
    s.set(7, @bitCast(@as(i64, -100)));
    try l.dispatch(&s, &m);
    try std.testing.expectEqual(negative(13), s.get(0));
    s.set(0, 9999);
    try std.testing.expectError(error.UnsupportedSyscall, l.dispatch(&s, &m));
    try std.testing.expectEqual(negative(13), try l.invoke(&s, &m, .ftruncate, .{ 0, 0, 0, 0, 0, 0 }));
}

test "Linux signal metadata checks guest layouts, masks and pointers" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |architecture| {
        var s = State{ .architecture = architecture };
        try std.testing.expectEqual(Operation.rt_sigaction, try operation(s, if (architecture == .x86_64) 13 else 134));
        try std.testing.expectEqual(Operation.rt_sigprocmask, try operation(s, if (architecture == .x86_64) 14 else 135));
        var l = Linux{ .allocator = std.testing.allocator };
        defer l.deinit();
        const offset: u64 = if (architecture == .riscv64) 16 else 24;
        try m.writeInt(0x1000, 64, 0x1234);
        try m.writeInt(0x1008, 64, 0xffffffffffffffff);
        try m.writeInt(0x1010, 64, 0x5678);
        try m.writeInt(0x1000 + offset, 64, 0x40102);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .rt_sigaction, .{ 2, 0x1000, 0, 8, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .rt_sigaction, .{ 2, 0, 0x1100, 8, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0x1234), try m.readInt(0x1100, 64, .read));
        try std.testing.expectEqual(@as(u64, if (architecture == .riscv64) 0xd8000007 else 0xdc000007), try m.readInt(0x1108, 64, .read));
        try std.testing.expectEqual(@as(u64, 2), try m.readInt(0x1100 + offset, 64, .read));
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .rt_sigaction, .{ 9, 0x1000, 0, 8, 0, 0 }));
        try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .rt_sigaction, .{ 2, 0x3000, 0, 8, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0x1234), std.mem.readInt(u64, l.signal_actions[1][0..8], .little));
        // Aliased old/new pointers still return the previous mask.
        try m.writeInt(0x1200, 64, 0x40102);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .rt_sigprocmask, .{ 0, 0x1200, 0x1200, 8, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1200, 64, .read));
        try std.testing.expectEqual(@as(u64, 2), l.threads.metadata().signal_mask);
        try m.writeInt(0x1200, 64, 4);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .rt_sigprocmask, .{ 0, 0x1200, 0, 8, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 6), l.threads.metadata().signal_mask);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .rt_sigprocmask, .{ 1, 0x1200, 0, 8, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 2), l.threads.metadata().signal_mask);
        try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .rt_sigprocmask, .{ 2, 0x1200, 0x3000, 8, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 4), l.threads.metadata().signal_mask);
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .rt_sigprocmask, .{ 3, 0x1200, 0, 8, 0, 0 }));
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .rt_sigprocmask, .{ 2, 0, 0, 16, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .rt_sigprocmask, .{ 99, 0, 0x1200, 8, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 4), try m.readInt(0x1200, 64, .read));
    }
}

test "standard signals coalesce, suspend until caught, restore masks and honor reset and nodefer" {
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var m = Memory.init(std.testing.allocator);
        defer m.deinit();
        try m.map(0x1000, 4096, .{ .read = true, .execute = true });
        try m.map(0x4000, 32768, .{ .read = true, .write = true });
        var l = Linux{ .allocator = std.testing.allocator };
        defer l.deinit();
        var s = State{ .architecture = arch, .pc = 0x1100, .instructions = 123 };
        s.set(s.stackRegister(), 0xb000);
        const mask_offset: u64 = if (arch == .riscv64) 16 else 24;
        try m.writeInt(0x4000, 64, 0x1200);
        try m.writeInt(0x4008, 64, 4 | (if (arch == .x86_64) @as(u64, 0x4000000) else 0));
        try m.writeInt(0x4010, 64, 0x1300);
        try m.writeInt(0x4000 + mask_offset, 64, 0);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .rt_sigaction, .{ 10, 0x4000, 0, 8, 0, 0 }));
        l.threads.metadata().signal_mask = 1 << 9;
        l.queueSignal(10, Signals.makeInfo(10, 0, 40, 1000, 0));
        l.queueSignal(10, Signals.makeInfo(10, 0, 41, 1000, 0));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .rt_sigpending, .{ 0x4100, 8, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 1 << 9), try m.readInt(0x4100, 64, .read));
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .rt_sigpending, .{ 0x4100, 16, 0, 0, 0, 0 }));
        try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .rt_sigsuspend, .{ 0xc000, 8, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(?u64, null), l.threads.metadata().saved_signal_mask);
        try l.pollSignals(&s, &m);
        try std.testing.expectEqual(@as(u64, 0x1100), s.pc);
        try m.writeInt(0x4100, 64, Signals.unblockable);
        const suspended = try l.invoke(&s, &m, .rt_sigsuspend, .{ 0x4100, 8, 0, 0, 0, 0 });
        s.set(if (arch == .riscv64) 10 else 0, suspended);
        try std.testing.expect(l.threads.blocked());
        try std.testing.expectEqual(@as(u64, 0), l.threads.metadata().signal_mask);
        try l.pollSignals(&s, &m);
        try std.testing.expect(!l.threads.blocked());
        try std.testing.expectEqual(@as(u64, 0x1200), s.pc);
        try std.testing.expectEqual(@as(u64, 123), s.instructions);
        try std.testing.expectEqual(@as(u64, 0), l.signal_pending);
        try std.testing.expectEqual(@as(u64, 1 << 9), l.threads.metadata().signal_mask);
        const info_address = s.get(if (arch == .x86_64) 6 else if (arch == .arm64) 1 else 11);
        try std.testing.expectEqual(@as(u64, 40), try m.readInt(info_address + 16, 32, .read));
        if (arch != .x86_64) try m.check(l.signal_restorer.?, 8, .execute);
        if (arch == .x86_64) s.set(4, s.get(4) + 8);
        try std.testing.expectEqual(negative(4), try l.invoke(&s, &m, .rt_sigreturn, @splat(0)));
        try std.testing.expectEqual(@as(u64, 0x1100), s.pc);
        try std.testing.expectEqual(@as(u64, 1 << 9), l.threads.metadata().signal_mask);
        l.threads.metadata().signal_mask = 0;
        try m.writeInt(0x4008, 64, 4 | 0xc0000000 | (if (arch == .x86_64) @as(u64, 0x4000000) else 0));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .rt_sigaction, .{ 10, 0x4000, 0, 8, 0, 0 }));
        l.queueSignal(10, Signals.makeInfo(10, 0, 42, 1000, 0));
        try l.pollSignals(&s, &m);
        try std.testing.expectEqual(@as(u64, 0), l.threads.metadata().signal_mask); // SA_NODEFER.
        try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &l.signal_actions[9]); // SA_RESETHAND.
        if (arch == .x86_64) s.set(4, s.get(4) + 8);
        _ = try l.invoke(&s, &m, .rt_sigreturn, @splat(0));
        l.queueSignal(12, Signals.makeInfo(12, 0, 42, 1000, 0));
        try m.writeInt(0x4000, 64, 1);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .rt_sigaction, .{ 12, 0x4000, 0, 8, 0, 0 }));
        l.queueSignal(12, Signals.makeInfo(12, 0, 42, 1000, 0));
        try std.testing.expectEqual(@as(u64, 0), l.signal_pending); // Ignoring discards pending and future signals.
        l.queueSignal(13, Signals.makeInfo(13, 128, 0, 0, 0));
        try l.pollSignals(&s, &m);
        try std.testing.expectEqual(@as(?u8, 141), l.exit_code);
        try std.testing.expectEqual(@as(u7, 13), l.exit_signal);
    }
}

test "fcntl duplicates use the lowest guest slot, independent flags and shared file offsets" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "duplicate", .{ .read = true });
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(isize, 3), c.write(file.handle, "abc", 3));
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var s = State{ .architecture = arch };
        var l = Linux{ .allocator = std.testing.allocator };
        defer l.deinit();
        // Borrowed stdin can be cloned without owning or closing the host's original fd.
        l.descriptors[0] = file.handle;
        try std.testing.expectEqual(Operation.fcntl, try operation(s, if (arch == .x86_64) 72 else 25));
        try std.testing.expectEqual(@as(i64, 0), c.lseek(file.handle, 0, c.SEEK_SET));
        try std.testing.expectEqual(@as(u64, 5), try l.invoke(&s, &m, .fcntl, .{ 0, 1030, 5, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 6), try l.invoke(&s, &m, .fcntl, .{ 5, 0, 5, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 3), try l.invoke(&s, &m, .fcntl, .{ 0, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .fcntl, .{ 5, 1, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .fcntl, .{ 6, 1, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .fcntl, .{ 5, 3, 0, 0, 0, 0 }));
        for ([_]u64{ 0, 5, 6 }, 0..) |fd, i| {
            try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .read, .{ fd, 0x1000 + i, 1, 0, 0, 0 }));
            try std.testing.expectEqual(@as(u64, 'a' + i), try m.readInt(0x1000 + i, 8, .read));
        }
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .close, .{ 5, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 5), try l.invoke(&s, &m, .fcntl, .{ 6, 0, 5, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .fcntl, .{ 5, 1, 0, 0, 0, 0 }));
        for ([_]u64{ 64, 0xffffffff }) |minimum| try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .fcntl, .{ 0, 0, minimum, 0, 0, 0 }));
        try std.testing.expectEqual(negative(9), try l.invoke(&s, &m, .fcntl, .{ 64, 1030, 3, 0, 0, 0 }));
        // Fill the table with borrowed handles: failure must leave every occupied slot intact.
        for (&l.descriptors, &l.borrowed) |*fd, *borrowed| if (fd.* == null) {
            fd.* = file.handle;
            borrowed.* = true;
        };
        const before = l.descriptors;
        try std.testing.expectEqual(negative(24), try l.invoke(&s, &m, .fcntl, .{ 0, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqualSlices(?c_int, &before, &l.descriptors);
        try std.testing.expect(c.fcntl(file.handle, c.F_GETFD) >= 0);
    }
}

test "dup uses the lowest slot, shares offsets and preserves borrowed host handles" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "dup", .{ .read = true });
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(isize, 3), c.write(file.handle, "abc", 3));
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var s = State{ .architecture = arch };
        var l = Linux{ .allocator = std.testing.allocator };
        defer l.deinit();
        l.descriptors[0] = file.handle;
        l.fd_flags[0] = 1;
        l.open_flags[0] = 2 | 0x80000;
        try std.testing.expectEqual(Operation.dup, try operation(s, if (arch == .x86_64) 32 else 23));
        try std.testing.expectEqual(@as(i64, 0), c.lseek(file.handle, 0, c.SEEK_SET));
        try std.testing.expectEqual(@as(u64, 3), try l.invoke(&s, &m, .dup, .{ 0x100000000, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u32, 0), l.fd_flags[3]);
        try std.testing.expectEqual(@as(u64, 2), l.open_flags[3]);
        try std.testing.expectEqual(@as(u32, 1), l.fd_flags[0]);
        try std.testing.expect(!l.borrowed[3] and l.descriptors[3] != file.handle);
        try std.testing.expect(c.fcntl(l.descriptors[3].?, c.F_GETFD) & c.FD_CLOEXEC != 0);
        for ([_]u64{ 0, 3 }, 0..) |fd, n| {
            try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .read, .{ fd, 0x1000 + n, 1, 0, 0, 0 }));
            try std.testing.expectEqual(@as(u64, 'a' + n), try m.readInt(0x1000 + n, 8, .read));
        }
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .close, .{ 0, 0, 0, 0, 0, 0 }));
        try std.testing.expect(c.fcntl(file.handle, c.F_GETFD) >= 0);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .dup, .{ 3, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .read, .{ 0, 0x1002, 1, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 'c'), try m.readInt(0x1002, 8, .read));
        for ([_]u64{ 64, 0xffffffff }) |bad| try std.testing.expectEqual(negative(9), try l.invoke(&s, &m, .dup, .{ bad, 0, 0, 0, 0, 0 }));
        for (&l.descriptors, &l.borrowed) |*fd, *borrowed| if (fd.* == null) {
            fd.* = file.handle;
            borrowed.* = true;
        };
        const before = l.descriptors;
        try std.testing.expectEqual(negative(24), try l.invoke(&s, &m, .dup, .{ 0, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqualSlices(?c_int, &before, &l.descriptors);
    }
}

test "dup2 replaces exact guest slots without closing borrowed handles or leaking directory streams" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "dup2", .{ .read = true });
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(isize, 3), c.write(file.handle, "abc", 3));
    try std.testing.expectEqual(Operation.dup2, try operation(.{ .architecture = .x86_64 }, 33));
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var s = State{ .architecture = arch };
        var l = Linux{ .allocator = std.testing.allocator };
        defer l.deinit();
        l.descriptors[0] = file.handle;
        l.descriptors[2] = file.handle;
        l.fd_flags[0] = 1;
        l.open_flags[0] = 2 | 0x80000;
        try std.testing.expectEqual(@as(i64, 0), c.lseek(file.handle, 0, c.SEEK_SET));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .dup2, .{ 0x100000000, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u32, 1), l.fd_flags[0]);
        try std.testing.expectEqual(@as(u64, 2), try l.invoke(&s, &m, .dup2, .{ 0, 0x100000002, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u32, 0), l.fd_flags[2]);
        try std.testing.expectEqual(@as(u64, 2), l.open_flags[2]);
        try std.testing.expect(!l.borrowed[2] and l.descriptors[2] != file.handle);
        try std.testing.expect(c.fcntl(file.handle, c.F_GETFD) >= 0);
        for ([_]u64{ 0, 2 }, 0..) |fd, n| {
            try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .read, .{ fd, 0x1000 + n, 1, 0, 0, 0 }));
            try std.testing.expectEqual(@as(u64, 'a' + n), try m.readInt(0x1000 + n, 8, .read));
        }
        // Real cached DIR ownership must be reclaimed when its guest slot is replaced.
        const dir_fd = c.openat(tmp.dir.handle, ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        try std.testing.expect(dir_fd >= 0);
        try std.testing.expectEqual(@as(u64, 3), l.register(dir_fd, 0, 3));
        const stream_fd = c.dup(dir_fd);
        try std.testing.expect(stream_fd >= 0);
        l.directories[3] = c.fdopendir(stream_fd);
        try std.testing.expect(l.directories[3] != null);
        try std.testing.expectEqual(@as(u64, 3), try l.invoke(&s, &m, .dup2, .{ 0, 3, 0, 0, 0, 0 }));
        try std.testing.expect(l.directories[3] == null);
        try std.testing.expect(c.fcntl(dir_fd, c.F_GETFD) < 0 and c.fcntl(stream_fd, c.F_GETFD) < 0);
        for ([_][2]u64{ .{ 64, 2 }, .{ 0, 64 }, .{ 0xffffffff, 2 }, .{ 0, 0xffffffff }, .{ 64, 64 } }) |bad| {
            const before = l.descriptors;
            try std.testing.expectEqual(negative(9), try l.invoke(&s, &m, .dup2, .{ bad[0], bad[1], 0, 0, 0, 0 }));
            try std.testing.expectEqualSlices(?c_int, &before, &l.descriptors);
        }
        for (&l.descriptors, &l.borrowed) |*fd, *borrowed| if (fd.* == null) {
            fd.* = file.handle;
            borrowed.* = true;
        };
        const replaced = l.descriptors[2].?;
        try std.testing.expectEqual(@as(u64, 2), try l.invoke(&s, &m, .dup2, .{ 3, 2, 0, 0, 0, 0 }));
        try std.testing.expect(c.fcntl(replaced, c.F_GETFD) < 0);
        try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .read, .{ 2, 0x1002, 1, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 'c'), try m.readInt(0x1002, 8, .read));
    }
}

test "dup3 maps all Linux ABIs and validates flags before descriptor errors" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var s = State{ .architecture = arch };
        var l = Linux{ .allocator = std.testing.allocator };
        defer l.deinit();
        try std.testing.expectEqual(Operation.dup3, try operation(s, if (arch == .x86_64) 292 else 24));
        for ([_]u64{ 0, 0x80000, 0x100080000 }) |flags| {
            try std.testing.expectEqual(@as(u64, 3), try l.invoke(&s, &m, .dup3, .{ 1, 3, flags, 0, 0, 0 }));
            try std.testing.expectEqual(@as(u32, @intFromBool(flags & 0x80000 != 0)), l.fd_flags[3]);
            try std.testing.expectEqual(@as(u64, 1 | (flags & 0x80000)), l.open_flags[3]);
            try std.testing.expect(c.fcntl(l.descriptors[3].?, c.F_GETFD) & c.FD_CLOEXEC != 0);
            try std.testing.expectEqual(@as(u32, 0), l.fd_flags[1]);
        }
        const before = l.descriptors;
        for ([_][3]u64{ .{ 1, 1, 0 }, .{ 64, 64, 0 }, .{ 1, 3, 1 }, .{ 64, 3, 0xffffffff }, .{ 1, 64, 1 } }) |bad|
            try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .dup3, .{ bad[0], bad[1], bad[2], 0, 0, 0 }));
        for ([_][2]u64{ .{ 64, 3 }, .{ 1, 64 }, .{ 0xffffffff, 3 }, .{ 1, 0xffffffff } }) |bad|
            try std.testing.expectEqual(negative(9), try l.invoke(&s, &m, .dup3, .{ bad[0], bad[1], 0, 0, 0, 0 }));
        try std.testing.expectEqualSlices(?c_int, &before, &l.descriptors);
        try std.testing.expectEqual(@as(u32, 1), l.fd_flags[3]);
    }
}

test "getppid reports the virtual parent across Linux ABIs and shared-process guest threads" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var s = State{ .architecture = arch };
        var l = Linux{ .allocator = std.testing.allocator };
        defer l.deinit();
        const op = try operation(s, if (arch == .x86_64) 110 else 173);
        try std.testing.expectEqual(Operation.getppid, op);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, op, @splat(0xffffffffffffffff)));
        try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .getpid, @splat(0)));
        try l.threads.records.append(l.allocator, .{ .id = 1, .context = s, .data = .{} });
        try l.threads.records.append(l.allocator, .{ .id = 2, .context = s, .data = .{} });
        l.threads.current = 1;
        try std.testing.expectEqual(@as(u64, 2), try l.invoke(&s, &m, .gettid, @splat(0)));
        try std.testing.expectEqual(@as(u64, 1), try l.invoke(&s, &m, .getpid, @splat(0)));
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, op, @splat(0)));
    }
}

test "getgroups exposes only virtual groups, validates signed sizes and leaves buffers untouched" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.writeInt(0x1000, 64, 0x123456789abcdef0);
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var s = State{ .architecture = arch };
        var l = Linux{ .allocator = std.testing.allocator };
        defer l.deinit();
        const op = try operation(s, if (arch == .x86_64) 115 else 158);
        try std.testing.expectEqual(Operation.getgroups, op);
        for ([_]u64{ 0, 1, 65536, 0x7fffffff, 0x100000000, 0xffffffff00000001 }) |size| {
            for ([_]u64{ 0, 1, 0x1000, 0xffffffffffffffff }) |pointer|
                try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, op, .{ size, pointer, 0, 0, 0, 0 }));
        }
        for ([_]u64{ 0xffffffff, 0xffffffffffffffff, 0x80000000 }) |size|
            try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, op, .{ size, 0x1000, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), try m.readInt(0x1000, 64, .read));
        try std.testing.expectEqual(@as(u64, 1000), try l.invoke(&s, &m, .getuid, @splat(0)));
        try std.testing.expect(m.fault == null);
    }
}

test "setuid and setgid retain the guest's unprivileged identity without touching host credentials" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    const host_ids = [_]u32{ c.getuid(), c.geteuid(), c.getgid(), c.getegid() };
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var s = State{ .architecture = arch };
        var l = Linux{ .allocator = std.testing.allocator };
        defer l.deinit();
        for ([_]Operation{ .setuid, .setgid }) |op| {
            const number: u64 = if (op == .setuid) (if (arch == .x86_64) @as(u64, 105) else 146) else (if (arch == .x86_64) @as(u64, 106) else 144);
            try std.testing.expectEqual(op, try operation(s, number));
            for ([_]u64{ 1000, 0x1000003e8 }) |id|
                try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, op, .{ id, 0, 0, 0, 0, 0 }));
            for ([_]u64{ 0, 1001, 0xfffffffe, 0x100000000 }) |id|
                try std.testing.expectEqual(negative(1), try l.invoke(&s, &m, op, .{ id, 0, 0, 0, 0, 0 }));
            for ([_]u64{ 0xffffffff, 0xffffffffffffffff }) |id|
                try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, op, .{ id, 0, 0, 0, 0, 0 }));
        }
        const numbers: [4]u64 = if (arch == .x86_64) .{ 102, 104, 107, 108 } else .{ 174, 175, 176, 177 };
        for (numbers) |number|
            try std.testing.expectEqual(@as(u64, 1000), try l.invoke(&s, &m, try operation(s, number), @splat(0)));
    }
    const after = [_]u32{ c.getuid(), c.geteuid(), c.getgid(), c.getegid() };
    try std.testing.expectEqualSlices(u32, &host_ids, &after);
}

test "unavailable sendfile returns ENOSYS on each Linux ABI without side effects" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.writeInt(0x1000, 64, 123);
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var s = State{ .architecture = arch };
        var l = Linux{ .allocator = std.testing.allocator };
        defer l.deinit();
        const op = try operation(s, if (arch == .x86_64) 40 else 71);
        try std.testing.expectEqual(Operation.sendfile, op);
        const before = l.descriptors;
        for ([_]u64{ 0, 0x1000, 1 }) |offset|
            try std.testing.expectEqual(negative(38), try l.invoke(&s, &m, op, .{ 1, 0, offset, 1024, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 123), try m.readInt(0x1000, 64, .read));
        try std.testing.expectEqualSlices(?c_int, &before, &l.descriptors);
        try std.testing.expect(m.fault == null);
    }
}

test "poll translates guest descriptors and normal events without partial writes" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var l = Linux{ .allocator = std.testing.allocator };
    defer l.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "poll", .{ .read = true });
    defer file.close(std.testing.io);
    const native = c.dup(file.handle);
    try std.testing.expect(native >= 0);
    const fd = l.register(native, 2, 0);
    var s = State{ .architecture = .x86_64 };
    try std.testing.expectEqual(Operation.poll, try operation(s, 7));
    var rows: [24]u8 = @splat(0);
    put(&rows, 0, 32, 64); // Invalid guest fd: ready immediately, even with no requested events.
    put(&rows, 8, 32, 0xffffffff); // Negative guest fd: ignored.
    put(&rows, 16, 32, fd);
    for ([_]u16{ 4, 256 }) |events| {
        put(&rows, 20, 16, events);
        try m.write(0x1fe8, &rows);
        try std.testing.expectEqual(@as(u64, 2), try l.invoke(&s, &m, .poll, .{ 0x1fe8, 3, 10000, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 32), try m.readInt(0x1fee, 16, .read));
        try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1ff6, 16, .read));
        try std.testing.expectEqual(@as(u64, events), try m.readInt(0x1ffe, 16, .read));
    }
    var before: [24]u8 = undefined;
    try m.read(0x1fe8, &before, .read);
    try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .poll, .{ 0x1fe9, 3, 0, 0, 0, 0 }));
    var after: [24]u8 = undefined;
    try m.read(0x1fe8, &after, .read);
    try std.testing.expectEqualSlices(u8, &before, &after);
    try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .poll, .{ 0x1000, 65, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .poll, .{ 0, 0, 0, 0, 0, 0 }));
}

test "alternate signal stack state validates size, active changes and output faults" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var l = Linux{ .allocator = std.testing.allocator };
        defer l.deinit();
        var s = State{ .architecture = arch };
        s.set(s.stackRegister(), 0x9000);
        try std.testing.expectEqual(Operation.sigaltstack, try operation(s, if (arch == .x86_64) 131 else 132));
        var stack_bytes: [24]u8 = @splat(0);
        put(&stack_bytes, 0, 64, 0x2200);
        put(&stack_bytes, 8, 32, 1); // Linux accepts SS_ONSTACK on installation as zero.
        put(&stack_bytes, 16, 64, 8192);
        try m.write(0x1fc0, &stack_bytes);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .sigaltstack, .{ 0x1fc0, 0x1fe8, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 2), try m.readInt(0x1ff0, 32, .read));
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, l.threads.metadata().alternate_stack[8..12], .little));
        s.set(s.stackRegister(), 0x3000);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .sigaltstack, .{ 0, 0x1fe8, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 1), try m.readInt(0x1ff0, 32, .read));
        const old = l.threads.metadata().alternate_stack;
        try std.testing.expectEqual(negative(1), try l.invoke(&s, &m, .sigaltstack, .{ 0x1fc0, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(old, l.threads.metadata().alternate_stack);
        s.set(s.stackRegister(), 0x9000);
        put(&stack_bytes, 8, 32, 0x80000000);
        try m.write(0x1fc0, &stack_bytes);
        try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .sigaltstack, .{ 0x1fc0, 0x1fe9, 0, 0, 0, 0 }));
        try std.testing.expectEqual(old, l.threads.metadata().alternate_stack);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .sigaltstack, .{ 0x1fc0, 0, 0, 0, 0, 0 }));
        put(&stack_bytes, 8, 32, 4);
        try m.write(0x1fc0, &stack_bytes);
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .sigaltstack, .{ 0x1fc0, 0, 0, 0, 0, 0 }));
        put(&stack_bytes, 8, 32, 0);
        put(&stack_bytes, 16, 64, 1);
        try m.write(0x1fc0, &stack_bytes);
        try std.testing.expectEqual(negative(12), try l.invoke(&s, &m, .sigaltstack, .{ 0x1fc0, 0, 0, 0, 0, 0 }));
        put(&stack_bytes, 8, 32, 2);
        try m.write(0x1fc0, &stack_bytes);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .sigaltstack, .{ 0x1fc0, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, l.threads.metadata().alternate_stack[0..8], .little));
        try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, l.threads.metadata().alternate_stack[16..24], .little));
    }
}

test "Linux sleep validates timespecs, preserves outputs and wakes only on its deadline" {
    const a = std.testing.allocator;
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var m = Memory.init(a);
        defer m.deinit();
        try m.map(0x1000, 4096, .{ .read = true, .write = true });
        var l = Linux{ .allocator = a };
        defer l.deinit();
        var s = State{ .architecture = arch, .instructions = 99 };
        try std.testing.expectEqual(Operation.nanosleep, try operation(s, if (arch == .x86_64) 35 else 101));
        try std.testing.expectEqual(Operation.clock_nanosleep, try operation(s, if (arch == .x86_64) 230 else 115));
        try m.writeInt(0x1200, 64, 0xaaaaaaaaaaaaaaaa);
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .nanosleep, .{ 0x1100, 0xffffffffffffffff, 0, 0, 0, 0 }));
        for ([_]u64{ 0, 1 }) |clock|
            try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .clock_nanosleep, .{ clock, 1, 0x1100, 0x1200, 0, 0 }));
        try m.writeInt(0x1108, 64, 1_000_000_000);
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .nanosleep, .{ 0x1100, 0, 0, 0, 0, 0 }));
        try m.writeInt(0x1100, 64, 0xffffffffffffffff);
        try m.writeInt(0x1108, 64, 0);
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .nanosleep, .{ 0x1100, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .nanosleep, .{ 0x1ff8, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .clock_nanosleep, .{ 3, 0, 0x1100, 0, 0, 0 }));
        try std.testing.expectEqual(negative(95), try l.invoke(&s, &m, .clock_nanosleep, .{ 2, 0, 0x1100, 0, 0, 0 }));
        try m.writeInt(0x1100, 64, 0);
        // Linux ignores flag bits other than TIMER_ABSTIME.
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .clock_nanosleep, .{ 1, 2, 0x1100, 0, 0, 0 }));
        try std.testing.expectEqual(@as(usize, 0), l.threads.records.items.len);
        try m.writeInt(0x1100, 64, std.math.maxInt(i64)); // Large valid intervals saturate rather than overflow.
        try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .clock_nanosleep, .{ 0, 0, 0x1100, 0x1200, 0, 0 }));
        try std.testing.expect(l.threads.blocked());
        try std.testing.expect(!l.threads.records.items[0].wait.?.realtime);
        try std.testing.expectEqual(@as(u64, 0), l.threads.wake(0, false, 0xffffffff, 1));
        l.threads.records.items[0].wait.?.deadline = 0;
        s.set(if (arch == .riscv64) 10 else 0, 123);
        try std.testing.expect(try l.threads.schedule(&s));
        try std.testing.expectEqual(@as(u64, 0), s.get(if (arch == .riscv64) 10 else 0));
        try std.testing.expectEqual(@as(u64, 99), s.instructions);
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try m.readInt(0x1200, 64, .read));
    }
}

test "futex wake without waiters and mismatched waits check mapped words" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var l = Linux{ .allocator = std.testing.allocator };
    defer l.deinit();
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var s = State{ .architecture = arch };
        try std.testing.expectEqual(Operation.futex, try operation(s, if (arch == .x86_64) 202 else 98));
        for ([_]u64{ 1, 129, 10, 138 }) |command|
            try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .futex, .{ 0x1ffc, command, 0x7fffffff, 0, 0, 1 }));
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .futex, .{ 0x1ffd, 1, 1, 0, 0, 0 }));
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .futex, .{ 0x1ffc, 9, 1, 0, 0, 0 }));
        try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .futex, .{ 0x2000, 1, 1, 0, 0, 0 }));
        try std.testing.expectEqual(negative(11), try l.invoke(&s, &m, .futex, .{ 0x1ffc, 0, 1, 0, 0, 0 }));
    }
}

test "prlimit64 queries virtual limits and rejects mutation without partial writes" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var l = Linux{ .allocator = std.testing.allocator };
    defer l.deinit();
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var s = State{ .architecture = arch };
        try std.testing.expectEqual(Operation.prlimit64, try operation(s, if (arch == .x86_64) 302 else 261));
        for ([_]u64{ 3, 7, 9 }) |resource| {
            const limit: u64 = if (resource == 3) @import("../process.zig").stack_size else if (resource == 7) l.descriptors.len else m.limit;
            try std.testing.expectEqual(@as(u64, 0), try l.invoke(&s, &m, .prlimit64, .{ 0, resource, 0, 0x1ff0, 0, 0 }));
            try std.testing.expectEqual(limit, try m.readInt(0x1ff0, 64, .read));
            try std.testing.expectEqual(limit, try m.readInt(0x1ff8, 64, .read));
            try std.testing.expectEqual(negative(14), try l.invoke(&s, &m, .prlimit64, .{ 1, resource, 0, 0x1ff1, 0, 0 }));
            try std.testing.expectEqual(limit, try m.readInt(0x1ff0, 64, .read));
            try std.testing.expectEqual(limit, try m.readInt(0x1ff8, 64, .read));
        }
        try std.testing.expectEqual(negative(38), try l.invoke(&s, &m, .prlimit64, .{ 0, 3, 0x1000, 0x1ff0, 0, 0 }));
        try std.testing.expectEqual(negative(3), try l.invoke(&s, &m, .prlimit64, .{ 2, 3, 0, 0x1ff0, 0, 0 }));
        try std.testing.expectEqual(negative(22), try l.invoke(&s, &m, .prlimit64, .{ 0, 16, 0, 0, 0, 0 }));
    }
}

test "Unavailable optional capabilities return ENOSYS for libc fallback on all CPUs" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    var l = Linux{ .allocator = std.testing.allocator };
    defer l.deinit();
    for ([_]@import("../loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var s = State{ .architecture = arch };
        for ([_]u64{ if (arch == .x86_64) 273 else 99, if (arch == .x86_64) 334 else 293, if (arch == .x86_64) 28 else 233 }) |nr| {
            s.set(if (arch == .x86_64) 0 else if (arch == .arm64) 8 else 17, nr);
            try l.dispatch(&s, &m);
            try std.testing.expectEqual(negative(38), s.get(if (arch == .riscv64) 10 else 0));
            try std.testing.expect(m.fault == null);
        }
        try std.testing.expectEqual(Operation.socket, try operation(s, if (arch == .x86_64) 41 else 198));
        try std.testing.expectEqual(negative(97), try l.invoke(&s, &m, .socket, .{ 1, 0x80001, 0, 0, 0, 0 }));
    }
    try std.testing.expectEqual(@as(u64, 9), l.calls);
}
