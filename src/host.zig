const std = @import("std");
const builtin = @import("builtin");
pub const Timestamp = struct { sec: i64, nsec: i64 };
pub const CpuTimes = struct { user: u64 = 0, kernel: u64 = 0 };
pub const DiskStat = struct { unit: u64, blocks: u64, free: u64, available: u64 };
pub const FileStat = struct {
    dev: u64,
    ino: u64,
    mode: u32,
    nlink: u64,
    uid: u32,
    gid: u32,
    rdev: u64,
    size: i64,
    blksize: u64,
    blocks: i64,
    atime: Timestamp,
    mtime: Timestamp,
    ctime: Timestamp,
    birthtime: ?Timestamp = null,
};
pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("time.h");
    @cInclude("termios.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/statvfs.h");
    @cInclude("sys/resource.h");
    if (builtin.os.tag == .macos) {
        @cInclude("sys/attr.h");
        @cInclude("sys/mount.h");
    }
    @cInclude("sys/utsname.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("sys/mman.h");
    @cInclude("dirent.h");
    @cInclude("poll.h");
});
pub fn diskStatFd(fd: c_int) !DiskStat {
    if (builtin.os.tag == .macos) {
        // Darwin's POSIX statvfs uses 32-bit block counts; statfs retains 64-bit counts.
        var info: c.struct_statfs = undefined;
        if (c.fstatfs(fd, &info) != 0) return error.HostDiskStatFailed;
        return .{ .unit = info.f_bsize, .blocks = info.f_blocks, .free = info.f_bfree, .available = info.f_bavail };
    } else {
        var info: c.struct_statvfs = undefined;
        if (c.fstatvfs(fd, &info) != 0) return error.HostDiskStatFailed;
        return .{ .unit = info.f_frsize, .blocks = info.f_blocks, .free = info.f_bfree, .available = info.f_bavail };
    }
}
pub fn output(fd: c_int, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = c.write(fd, bytes.ptr + done, bytes.len - done);
        if (n < 0) {
            if (errno() == c.EINTR) continue;
            return error.HostWriteFailed;
        }
        if (n == 0) return error.HostWriteFailed;
        done += @intCast(n);
    }
}
pub fn print(fd: c_int, comptime format: []const u8, args: anytype) !void {
    var buf: [8192]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, format, args);
    try output(fd, text);
}
pub fn errno() c_int {
    return switch (@import("builtin").os.tag) {
        .macos => c.__error().*,
        .linux => c.__errno_location().*,
        else => @compileError("UNIVERSE requires macOS or Linux"),
    };
}
pub fn readFile(a: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_NONBLOCK | c.O_CLOEXEC);
    if (fd < 0) return switch (errno()) {
        c.EACCES, c.EPERM => error.BinaryAccessDenied,
        c.EMFILE, c.ENFILE => error.BinaryFileLimit,
        else => error.CannotOpenBinary,
    };
    defer _ = c.close(fd);
    const info = try statFd(fd);
    if (!isRegular(info.mode)) return error.UnsupportedBinaryFile;
    if (info.size < 0 or info.size > 64 * 1024 * 1024) return error.BinaryTooLarge;
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(a);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            if (errno() == c.EINTR) continue;
            return error.CannotReadBinary;
        }
        if (n == 0) break;
        if (data.items.len + @as(usize, @intCast(n)) > 64 * 1024 * 1024) return error.BinaryTooLarge;
        try data.appendSlice(a, buf[0..@intCast(n)]);
    }
    return data.toOwnedSlice(a);
}
pub fn absolutePath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolutePosix(path)) return a.dupe(u8, path);
    const cwd = c.getcwd(null, 0);
    if (cwd == null) return if (errno() == c.ENOMEM) error.OutOfMemory else error.CannotGetWorkingDirectory;
    defer c.free(cwd);
    // Preserve host symlink/.. traversal rather than normalizing it lexically.
    return std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, std.mem.span(cwd), "/"), path });
}
pub fn nowNs() !u64 {
    const ts = try clock(.monotonic);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn clock(which: enum { realtime, monotonic }) !Timestamp {
    var ts: std.posix.timespec = undefined;
    const id = switch (which) {
        .realtime => std.posix.CLOCK.REALTIME,
        .monotonic => std.posix.CLOCK.MONOTONIC,
    };
    if (std.posix.system.clock_gettime(id, &ts) != 0) return error.HostClockFailed;
    return .{ .sec = @intCast(ts.sec), .nsec = @intCast(ts.nsec) };
}
pub fn localOffset(seconds: i64) !i64 {
    const instant: c.time_t = @intCast(seconds);
    var local: c.struct_tm = undefined;
    if (c.localtime_r(&instant, &local) == null) return error.HostTimezoneFailed;
    return @intCast(local.tm_gmtoff);
}
pub fn cpuTimes() !CpuTimes {
    var usage: c.struct_rusage = undefined;
    if (c.getrusage(c.RUSAGE_SELF, &usage) != 0) return error.HostCpuClockFailed;
    return .{
        .user = @as(u64, @intCast(usage.ru_utime.tv_sec)) * 10_000_000 + @as(u64, @intCast(usage.ru_utime.tv_usec)) * 10,
        .kernel = @as(u64, @intCast(usage.ru_stime.tv_sec)) * 10_000_000 + @as(u64, @intCast(usage.ru_stime.tv_usec)) * 10,
    };
}
pub fn setFileTimes(fd: c_int, creation: ?Timestamp, access: ?Timestamp, write: ?Timestamp) c_int {
    return switch (builtin.os.tag) {
        .macos => blk: {
            var attributes = std.mem.zeroes(c.struct_attrlist);
            attributes.bitmapcount = c.ATTR_BIT_MAP_COUNT;
            var times: [3]c.struct_timespec = undefined;
            var count: usize = 0;
            // Native common attributes are packed in creation/modification/access order.
            for ([_]?Timestamp{ creation, write, access }, [_]u32{ c.ATTR_CMN_CRTIME, c.ATTR_CMN_MODTIME, c.ATTR_CMN_ACCTIME }) |time, bit| if (time) |value| {
                attributes.commonattr |= bit;
                times[count] = .{ .tv_sec = @intCast(value.sec), .tv_nsec = @intCast(value.nsec) };
                count += 1;
            };
            if (count == 0) break :blk 0;
            break :blk c.fsetattrlist(fd, &attributes, &times, count * @sizeOf(c.struct_timespec), 0);
        },
        .linux => blk: {
            if (creation != null) {
                c.__errno_location().* = c.ENOTSUP;
                break :blk -1;
            }
            var times: [2]c.struct_timespec = undefined;
            for (&times, [_]?Timestamp{ access, write }) |*time, value| time.* = if (value) |stamp| .{ .tv_sec = @intCast(stamp.sec), .tv_nsec = @intCast(stamp.nsec) } else .{ .tv_sec = 0, .tv_nsec = c.UTIME_OMIT };
            break :blk c.futimens(fd, &times);
        },
        else => @compileError("UNIVERSE requires macOS or Linux"),
    };
}

pub fn isRegular(mode: u32) bool {
    return switch (builtin.os.tag) {
        .linux => mode & std.os.linux.S.IFMT == std.os.linux.S.IFREG,
        .macos => mode & std.c.S.IFMT == std.c.S.IFREG,
        else => @compileError("UNIVERSE requires macOS or Linux"),
    };
}

// Never emulate no-replace with a stat/rename pair: another host process can win that race.
pub fn renameExclusive(old: [:0]const u8, new: [:0]const u8) c_int {
    return switch (builtin.os.tag) {
        .macos => c.renamex_np(old.ptr, new.ptr, c.RENAME_EXCL),
        .linux => blk: {
            const result = std.os.linux.renameat2(c.AT_FDCWD, old.ptr, c.AT_FDCWD, new.ptr, .{ .NOREPLACE = true });
            const code = std.os.linux.errno(result);
            if (code == .SUCCESS) break :blk 0;
            c.__errno_location().* = @intCast(@intFromEnum(code));
            break :blk -1;
        },
        else => @compileError("UNIVERSE requires macOS or Linux"),
    };
}

pub fn statFd(fd: c_int) !FileStat {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            var info = std.mem.zeroes(linux.Statx);
            var mask = linux.STATX.BASIC_STATS;
            mask.BTIME = true;
            const result = linux.statx(fd, "", linux.AT.EMPTY_PATH, mask, &info);
            checkStatx(result) catch return error.CannotReadBinary;
            if (!info.mask.TYPE or !info.mask.SIZE) return error.CannotReadBinary;
            break :blk fromStatx(info);
        },
        .macos => blk: {
            var info: std.c.Stat = undefined;
            if (std.c.fstat(fd, &info) != 0) return error.CannotReadBinary;
            break :blk fromDarwinStat(info);
        },
        else => @compileError("UNIVERSE requires macOS or Linux"),
    };
}

// Retain the symbolic link itself, including a dangling link, without opening its target.
pub fn openLink(path: [:0]const u8) c_int {
    const flags: c_int = switch (builtin.os.tag) {
        .macos => c.O_RDONLY | c.O_SYMLINK | c.O_CLOEXEC | c.O_NONBLOCK,
        .linux => @bitCast(std.os.linux.O{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }),
        else => @compileError("UNIVERSE requires macOS or Linux"),
    };
    return c.open(path.ptr, flags);
}

pub fn statAt(dirfd: c_int, path: [:0]const u8, nofollow: bool) !FileStat {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            var info = std.mem.zeroes(linux.Statx);
            var mask = linux.STATX.BASIC_STATS;
            mask.BTIME = true;
            const result = linux.statx(dirfd, path.ptr, if (nofollow) linux.AT.SYMLINK_NOFOLLOW else 0, mask, &info);
            checkStatx(result) catch return error.CannotReadBinary;
            if (!info.mask.TYPE or !info.mask.SIZE) return error.CannotReadBinary;
            break :blk fromStatx(info);
        },
        .macos => blk: {
            var info: std.c.Stat = undefined;
            if (std.c.fstatat(dirfd, path.ptr, &info, if (nofollow) std.c.AT.SYMLINK_NOFOLLOW else 0) != 0) return error.CannotReadBinary;
            break :blk fromDarwinStat(info);
        },
        else => @compileError("UNIVERSE requires macOS or Linux"),
    };
}

fn checkStatx(result: usize) !void {
    const err = std.os.linux.errno(result);
    if (err == .SUCCESS) return;
    c.__errno_location().* = @intCast(@intFromEnum(err));
    return error.HostStatFailed;
}

fn fromStatx(s: std.os.linux.Statx) FileStat {
    return .{
        .dev = deviceNumber(s.dev_major, s.dev_minor),
        .ino = s.ino,
        .mode = s.mode,
        .nlink = s.nlink,
        .uid = s.uid,
        .gid = s.gid,
        .rdev = deviceNumber(s.rdev_major, s.rdev_minor),
        .size = @intCast(s.size),
        .blksize = s.blksize,
        .blocks = @intCast(s.blocks),
        .atime = .{ .sec = s.atime.sec, .nsec = s.atime.nsec },
        .mtime = .{ .sec = s.mtime.sec, .nsec = s.mtime.nsec },
        .ctime = .{ .sec = s.ctime.sec, .nsec = s.ctime.nsec },
        .birthtime = if (s.mask.BTIME) .{ .sec = s.btime.sec, .nsec = s.btime.nsec } else null,
    };
}

fn deviceNumber(major: u32, minor: u32) u64 {
    return @as(u64, minor & 0xff) | (@as(u64, major & 0xfff) << 8) | (@as(u64, minor & ~@as(u32, 0xff)) << 12) | (@as(u64, major & ~@as(u32, 0xfff)) << 32);
}

fn fromDarwinStat(s: std.c.Stat) FileStat {
    return .{
        .dev = @bitCast(@as(i64, s.dev)),
        .ino = @intCast(s.ino),
        .mode = s.mode,
        .nlink = s.nlink,
        .uid = s.uid,
        .gid = s.gid,
        .rdev = @bitCast(@as(i64, s.rdev)),
        .size = s.size,
        .blksize = @intCast(s.blksize),
        .blocks = s.blocks,
        .atime = .{ .sec = s.atimespec.sec, .nsec = s.atimespec.nsec },
        .mtime = .{ .sec = s.mtimespec.sec, .nsec = s.mtimespec.nsec },
        .ctime = .{ .sec = s.ctimespec.sec, .nsec = s.ctimespec.nsec },
        .birthtime = .{ .sec = s.birthtimespec.sec, .nsec = s.birthtimespec.nsec },
    };
}

pub fn random(bytes: []u8) !void {
    const fd = c.open("/dev/urandom", c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.HostEntropyFailed;
    defer _ = c.close(fd);
    var done: usize = 0;
    while (done < bytes.len) {
        const n = c.read(fd, bytes.ptr + done, bytes.len - done);
        if (n < 0 and errno() == c.EINTR) continue;
        if (n <= 0) return error.HostEntropyFailed;
        done += @intCast(n);
    }
}

test "Darwin signed device identifiers retain their native widened bit pattern" {
    if (builtin.os.tag == .macos) {
        var info = std.mem.zeroes(std.c.Stat);
        info.dev = -1;
        info.rdev = std.math.minInt(i32);
        const converted = fromDarwinStat(info);
        try std.testing.expectEqual(std.math.maxInt(u64), converted.dev);
        try std.testing.expectEqual(@as(u64, 0xffffffff80000000), converted.rdev);
    }
}

pub fn resetErrno() void {
    if (@import("builtin").os.tag == .macos) c.__error().* = 0 else c.__errno_location().* = 0;
}
