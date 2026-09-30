const std = @import("std");
const host = @import("../host.zig");
const c = host.c;
const Memory = @import("../memory.zig").Memory;
const State = @import("../cpu/state.zig").State;
pub const Operation = enum { fcntl, getdents64, stat, lstat, sched_getaffinity, getuid, arch_prctl, set_tid_address, writev, ioctl, read, write, open, openat, close, lseek, fstat, newfstatat, exit, brk, mmap, munmap, mprotect, clock_gettime, getrandom, uname, getpid, gettid };
fn operation(s: State, n: u64) !Operation {
    if (s.architecture == .x86_64) return switch (n) {
        72 => .fcntl,
        217 => .getdents64,
        4 => .stat,
        6 => .lstat,
        204 => .sched_getaffinity,
        102, 104, 107, 108 => .getuid,
        158 => .arch_prctl,
        218 => .set_tid_address,
        20 => .writev,
        16 => .ioctl,
        0 => .read,
        1 => .write,
        2 => .open,
        3 => .close,
        5 => .fstat,
        8 => .lseek,
        9 => .mmap,
        10 => .mprotect,
        11 => .munmap,
        12 => .brk,
        39 => .getpid,
        60, 231 => .exit,
        63 => .uname,
        186 => .gettid,
        228 => .clock_gettime,
        257 => .openat,
        262 => .newfstatat,
        318 => .getrandom,
        else => error.UnsupportedSyscall,
    };
    return switch (n) {
        25 => .fcntl,
        61 => .getdents64,
        123 => .sched_getaffinity,
        174, 175, 176, 177 => .getuid,
        96 => .set_tid_address,
        66 => .writev,
        29 => .ioctl,
        56 => .openat,
        57 => .close,
        62 => .lseek,
        63 => .read,
        64 => .write,
        79 => .newfstatat,
        80 => .fstat,
        93, 94 => .exit,
        113 => .clock_gettime,
        160 => .uname,
        172 => .getpid,
        178 => .gettid,
        214 => .brk,
        215 => .munmap,
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
    const linux: u16 = if (e == c.EPERM) 1 else if (e == c.ENOENT) 2 else if (e == c.EINTR) 4 else if (e == c.EIO) 5 else if (e == c.EBADF) 9 else if (e == c.EAGAIN) 11 else if (e == c.ENOMEM) 12 else if (e == c.EACCES) 13 else if (e == c.EEXIST) 17 else if (e == c.ENOTDIR) 20 else if (e == c.EISDIR) 21 else if (e == c.EINVAL) 22 else if (e == c.EMFILE) 24 else if (e == c.ENOSPC) 28 else if (e == c.ESPIPE) 29 else if (e == c.EROFS) 30 else if (e == c.EPIPE) 32 else if (e == c.ENAMETOOLONG) 36 else if (e == c.ENOTEMPTY) 39 else if (e == c.ELOOP) 40 else 5;
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
    allow_files: bool = false,
    sysroot: ?[:0]const u8 = null,
    trace: bool = false,
    exit_code: ?u8 = null,
    last_number: u64 = 0,
    heap_base: u64 = 0,
    heap_end: u64 = 0,
    heap_limit: u64 = 0,
    next_map: u64 = 0x100000000,
    page_size: u32 = 4096,
    calls: u64 = 0,
    clear_tid: u64 = 0,
    pub fn deinit(l: *Linux) void {
        for (l.directories) |dir| if (dir) |d| {
            _ = c.closedir(d);
        };
        for (l.descriptors, 0..) |fd, index| if (fd) |v| {
            if (!l.borrowed[index]) _ = c.close(v);
        };
    }
    fn descriptor(l: *Linux, n: u64) ?c_int {
        return if (n < l.descriptors.len) l.descriptors[@intCast(n)] else null;
    }
    fn register(l: *Linux, fd: c_int, flags: u64) u64 {
        for (0..l.descriptors.len) |i| if (l.descriptors[i] == null) {
            l.descriptors[i] = fd;
            l.borrowed[i] = false;
            l.fd_flags[i] = @intFromBool(flags & 0x80000 != 0);
            l.open_flags[i] = flags;
            return i;
        };
        _ = c.close(fd);
        return negative(24);
    }
    pub fn dispatch(l: *Linux, s: *State, m: *Memory) !void {
        const nr = if (s.architecture == .x86_64) s.get(0) else if (s.architecture == .riscv64) s.get(17) else s.get(8);
        l.last_number = nr;
        const regs: [6]u6 = switch (s.architecture) {
            .x86_64 => .{ 7, 6, 2, 10, 8, 9 },
            .riscv64 => .{ 10, 11, 12, 13, 14, 15 },
            .arm64 => .{ 0, 1, 2, 3, 4, 5 },
        };
        var args: [6]u64 = undefined;
        for (regs, 0..) |r, i| args[i] = s.get(r);
        const op = try operation(s.*, nr);
        const result = try l.invoke(s, m, op, args);
        s.set(if (s.architecture == .riscv64) 10 else 0, result);
        l.calls += 1;
        if (l.trace) try host.print(2, "syscall {s}({x}, {x}, {x}, {x}, {x}, {x}) = {d}\n", .{ @tagName(op), args[0], args[1], args[2], args[3], args[4], args[5], @as(i64, @bitCast(result)) });
    }
    /// Shared checked POSIX services; arguments and results use canonical Linux encodings.
    pub fn invoke(l: *Linux, s: *State, m: *Memory, op: Operation, args: [6]u64) !u64 {
        const result = l.perform(s, m, op, args) catch |err| switch (err) {
            error.UnmappedMemory, error.PermissionDenied, error.AddressOverflow, error.StringTooLong, error.BusError => negative(14),
            error.ProtectionLimit => negative(13),
            error.MemoryLimit, error.OutOfMemory => negative(12),
            error.InvalidMapping, error.OverlappingMapping => negative(22),
            else => return err,
        };
        m.fault = null;
        return result;
    }
    fn perform(l: *Linux, s: *State, m: *Memory, op: Operation, a: [6]u64) !u64 {
        switch (op) {
            .fcntl => {
                if (l.descriptor(a[0]) == null) return negative(9);
                const index: usize = @intCast(a[0]);
                switch (a[1]) {
                    1 => return l.fd_flags[index],
                    2 => {
                        l.fd_flags[index] = @truncate(a[2] & 1);
                        return 0;
                    },
                    3 => return l.open_flags[index] & ~@as(u64, 64 | 128 | 512 | 0x80000),
                    else => return negative(22),
                }
            },
            .getdents64 => {
                if (!l.allow_files) return negative(13);
                const fd = l.descriptor(a[0]) orelse return negative(9);
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
            .sched_getaffinity => {
                if (a[0] > 1) return negative(3);
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
                l.clear_tid = a[0];
                return 1;
            },
            .ioctl => {
                if (l.descriptor(a[0]) == null) return negative(9);
                return negative(25);
            },
            .writev => {
                const fd = l.descriptor(a[0]) orelse return negative(9);
                if (a[2] > 1024) return negative(22);
                try m.check(a[1], @intCast(a[2] * 16), .read);
                var buffers: std.ArrayList(u8) = .empty;
                defer buffers.deinit(l.allocator);
                for (0..a[2]) |n| {
                    const addr = try m.readInt(a[1] + n * 16, 64, .read);
                    const size = try m.readInt(a[1] + n * 16 + 8, 64, .read);
                    if (size > 1024 * 1024 - buffers.items.len) return negative(22);
                    try m.check(addr, @intCast(size), .read);
                    const off = buffers.items.len;
                    try buffers.resize(l.allocator, off + @as(usize, @intCast(size)));
                    try m.read(addr, buffers.items[off..], .read);
                }
                const result = host.c.write(fd, buffers.items.ptr, buffers.items.len);
                return if (result < 0) hostError() else @intCast(result);
            },
            .exit => {
                if (l.clear_tid != 0) {
                    // Linux teardown clears a registered TID best-effort; invalid pointers cannot prevent exit.
                    m.writeInt(l.clear_tid, 32, 0) catch {};
                }
                l.exit_code = @truncate(a[0]);
                return 0;
            },
            .getpid, .gettid => return 1,
            .read, .write => {
                const fd = l.descriptor(a[0]) orelse return negative(9);
                if (a[2] > 1024 * 1024) return negative(22);
                const n: usize = @intCast(a[2]);
                try m.check(a[1], n, if (op == .read) .write else .read);
                const buf = try l.allocator.alloc(u8, n);
                defer l.allocator.free(buf);
                if (op == .write) try m.read(a[1], buf, .read);
                const result = if (op == .read) c.read(fd, buf.ptr, n) else c.write(fd, buf.ptr, n);
                if (result < 0) return hostError();
                if (op == .read) try m.write(a[1], buf[0..@intCast(result)]);
                return @intCast(result);
            },
            .open, .openat => {
                if (!l.allow_files) return negative(13);
                const path_addr = if (op == .open) a[0] else a[1];
                const flags = if (op == .open) a[1] else a[2];
                const mode = if (op == .open) a[2] else a[3];
                const path = try m.cstring(l.allocator, path_addr, 4096);
                defer l.allocator.free(path);
                const directory: u64 = if (s.architecture == .arm64) 0x4000 else 0x10000;
                const nofollow: u64 = if (s.architecture == .arm64) 0x8000 else 0x20000;
                const largefile: u64 = if (s.architecture == .arm64) 0x20000 else 0x8000;
                const allowed: u64 = 3 | 64 | 128 | 512 | 1024 | directory | nofollow | largefile | 0x80000;
                if (flags & ~allowed != 0 or flags & 3 == 3) return negative(22);
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
                if (flags & directory != 0) translated |= c.O_DIRECTORY;
                if (flags & nofollow != 0) translated |= c.O_NOFOLLOW;
                translated |= c.O_CLOEXEC;
                const host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, path);
                defer l.allocator.free(host_path);
                const dir = if (op == .open or std.fs.path.isAbsolutePosix(path) or @as(i64, @bitCast(a[0])) == -100) c.AT_FDCWD else l.descriptor(a[0]) orelse return negative(9);
                const fd = c.openat(dir, host_path.ptr, translated, @as(c.mode_t, @intCast(mode & 0o777)));
                return if (fd < 0) hostError() else l.register(fd, flags);
            },
            .close => {
                const fd = l.descriptor(a[0]) orelse return negative(9);
                if (!l.borrowed[@intCast(a[0])] and c.close(fd) < 0) return hostError();
                if (l.directories[@intCast(a[0])]) |dir| {
                    _ = c.closedir(dir);
                    l.directories[@intCast(a[0])] = null;
                }
                l.descriptors[@intCast(a[0])] = null;
                return 0;
            },
            .lseek => {
                const fd = l.descriptor(a[0]) orelse return negative(9);
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
                    if (!l.allow_files) return negative(13);
                    const fd = l.descriptor(a[4]) orelse return negative(9);
                    if (l.open_flags[@intCast(a[4])] & 3 == 1) return negative(13);
                    if (a[5] > std.math.maxInt(i64) - size) return negative(75);
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
                const stat = if (op == .fstat) blk: {
                    const fd = l.descriptor(a[0]) orelse return negative(9);
                    break :blk host.statFd(fd) catch return hostError();
                } else if (op == .stat or op == .lstat) blk: {
                    if (!l.allow_files) return negative(13);
                    const path = try m.cstring(l.allocator, a[0], 4096);
                    defer l.allocator.free(path);
                    const host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, path);
                    defer l.allocator.free(host_path);
                    break :blk host.statAt(std.os.linux.AT.FDCWD, host_path, op == .lstat) catch return hostError();
                } else blk: {
                    if (!l.allow_files) return negative(13);
                    if (a[3] & ~@as(u64, 0x100) != 0) return negative(22);
                    const path = try m.cstring(l.allocator, a[1], 4096);
                    defer l.allocator.free(path);
                    const host_path = try @import("../filesystem.zig").resolve(l.allocator, l.sysroot, path);
                    defer l.allocator.free(host_path);
                    const dir = if (std.fs.path.isAbsolutePosix(path) or @as(i64, @bitCast(a[0])) == -100) std.os.linux.AT.FDCWD else l.descriptor(a[0]) orelse return negative(9);
                    break :blk host.statAt(dir, host_path, a[3] & 0x100 != 0) catch return hostError();
                };
                const destination = if (op == .newfstatat) a[2] else a[1];
                try packStat(m, destination, stat, s.architecture == .x86_64);
                return 0;
            },
        }
    }
};
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
}
