const std = @import("std");
const builtin = @import("builtin");
pub const Timestamp = struct { sec: i64, nsec: i64 };
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
};
pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("time.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/utsname.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("sys/mman.h");
    @cInclude("dirent.h");
});
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

pub fn isRegular(mode: u32) bool {
    return switch (builtin.os.tag) {
        .linux => mode & std.os.linux.S.IFMT == std.os.linux.S.IFREG,
        .macos => mode & std.c.S.IFMT == std.c.S.IFREG,
        else => @compileError("UNIVERSE requires macOS or Linux"),
    };
}

pub fn statFd(fd: c_int) !FileStat {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            var info = std.mem.zeroes(linux.Statx);
            const result = linux.statx(fd, "", linux.AT.EMPTY_PATH, .BASIC_STATS, &info);
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

pub fn statAt(dirfd: c_int, path: [:0]const u8, nofollow: bool) !FileStat {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            var info = std.mem.zeroes(linux.Statx);
            const result = linux.statx(dirfd, path.ptr, if (nofollow) linux.AT.SYMLINK_NOFOLLOW else 0, .BASIC_STATS, &info);
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
    };
}

fn deviceNumber(major: u32, minor: u32) u64 {
    return @as(u64, minor & 0xff) | (@as(u64, major & 0xfff) << 8) | (@as(u64, minor & ~@as(u32, 0xff)) << 12) | (@as(u64, major & ~@as(u32, 0xfff)) << 32);
}

fn fromDarwinStat(s: std.c.Stat) FileStat {
    return .{
        .dev = @intCast(s.dev),
        .ino = @intCast(s.ino),
        .mode = s.mode,
        .nlink = s.nlink,
        .uid = s.uid,
        .gid = s.gid,
        .rdev = @intCast(s.rdev),
        .size = s.size,
        .blksize = @intCast(s.blksize),
        .blocks = s.blocks,
        .atime = .{ .sec = s.atimespec.sec, .nsec = s.atimespec.nsec },
        .mtime = .{ .sec = s.mtimespec.sec, .nsec = s.mtimespec.nsec },
        .ctime = .{ .sec = s.ctimespec.sec, .nsec = s.ctimespec.nsec },
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

pub fn resetErrno() void {
    if (@import("builtin").os.tag == .macos) c.__error().* = 0 else c.__errno_location().* = 0;
}
