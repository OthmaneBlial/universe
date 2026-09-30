const std = @import("std");
pub const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("time.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/utsname.h");
    @cInclude("stdlib.h");
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
    const fd = c.open(path.ptr, c.O_RDONLY);
    if (fd < 0) return error.CannotOpenBinary;
    defer _ = c.close(fd);
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
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return error.HostClockFailed;
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
