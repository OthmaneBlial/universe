const std = @import("std");
// Lexically prefix absolute guest paths; this does not confine host symlink targets.
pub fn resolve(a: std.mem.Allocator, root: ?[]const u8, path: []const u8) ![:0]u8 {
    if (root == null or !std.fs.path.isAbsolutePosix(path)) return a.dupeZ(u8, path);
    const normalized = try std.fs.path.resolvePosix(a, &.{path});
    defer a.free(normalized);
    // Keep a trailing separator so host lookup still requires a directory.
    return std.fmt.allocPrintSentinel(a, "{s}/{s}{s}", .{ std.mem.trimEnd(u8, root.?, "/"), normalized[1..], if (std.mem.endsWith(u8, path, "/") and normalized.len > 1) "/" else "" }, 0);
}
test "sysroot prefixes absolute guest paths and keeps relative descriptor paths" {
    const a = std.testing.allocator;
    const cases = [_]struct { root: ?[]const u8, path: []const u8, expected: []const u8 }{
        .{ .root = "/guest", .path = "/lib/../lib/libc.so", .expected = "/guest/lib/libc.so" },
        .{ .root = "/guest", .path = "/../../file", .expected = "/guest/file" },
        .{ .root = "/guest", .path = "/directory/../file/", .expected = "/guest/file/" },
        .{ .root = "/", .path = "/file/", .expected = "/file/" },
        .{ .root = "guest", .path = "/", .expected = "guest/" },
        .{ .root = "/", .path = "/lib", .expected = "/lib" },
        .{ .root = "/guest", .path = "../file", .expected = "../file" },
        .{ .root = null, .path = "/lib/libc.so", .expected = "/lib/libc.so" },
    };
    for (cases) |case| {
        const path = try resolve(a, case.root, case.path);
        defer a.free(path);
        try std.testing.expectEqualStrings(case.expected, path);
    }
}
// Linux view of an absolute path under a sysroot, as under chroot: symlink targets are walked here, absolute
// targets restart at the sysroot and `..` stops there. The final component is followed only when `follow` is set.
// This is path translation, not confinement; relative (dirfd) paths are still left to the host.
pub fn chroot(a: std.mem.Allocator, root: ?[]const u8, path: []const u8, follow: bool) ![:0]u8 {
    const base = root orelse return resolve(a, root, path);
    if (!std.fs.path.isAbsolutePosix(path)) return resolve(a, root, path);
    const prefix = std.mem.trimEnd(u8, base, "/");
    var guest: std.ArrayList(u8) = .empty;
    defer guest.deinit(a);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(a);
    try pending.appendSlice(a, path);
    var links: usize = 0;
    var target: [4096]u8 = undefined;
    while (true) {
        const start = std.mem.indexOfNone(u8, pending.items, "/") orelse break;
        const end = std.mem.indexOfScalarPos(u8, pending.items, start, '/') orelse pending.items.len;
        const name = try a.dupe(u8, pending.items[start..end]);
        defer a.free(name);
        const tail = pending.items.len - end;
        std.mem.copyForwards(u8, pending.items[0..tail], pending.items[end..]);
        pending.shrinkRetainingCapacity(tail);
        if (std.mem.eql(u8, name, ".")) continue;
        if (std.mem.eql(u8, name, "..")) {
            guest.shrinkRetainingCapacity(std.mem.lastIndexOfScalar(u8, guest.items, '/') orelse 0);
            continue;
        }
        const parent = guest.items.len;
        try guest.append(a, '/');
        try guest.appendSlice(a, name);
        if (!follow and std.mem.indexOfNone(u8, pending.items, "/") == null) break;
        const host = try std.fmt.allocPrintSentinel(a, "{s}{s}", .{ prefix, guest.items }, 0);
        defer a.free(host);
        const count = @import("host.zig").c.readlink(host.ptr, &target, target.len);
        if (count < 0) continue; // Not a symlink, or missing: the host operation reports the real error.
        if (count == target.len) return error.NameTooLong;
        links += 1;
        if (links > 40) return error.SymbolicLinkLoop;
        const link = target[0..@intCast(count)];
        guest.shrinkRetainingCapacity(if (std.fs.path.isAbsolutePosix(link)) 0 else parent);
        try pending.insertSlice(a, 0, "/");
        try pending.insertSlice(a, 0, link);
    }
    const trailing = std.mem.endsWith(u8, path, "/") and guest.items.len != 0;
    return std.fmt.allocPrintSentinel(a, "{s}{s}{s}", .{ prefix, if (guest.items.len == 0) "/" else guest.items, if (trailing) "/" else "" }, 0);
}
test "chroot walks absolute and relative symlinks inside the sysroot" {
    const a = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const c = @import("host.zig").c;
    const root = try directory.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    for ([_][2][]const u8{ .{ "bin", "" }, .{ "usr", "" }, .{ "usr/lib", "" } }) |entry| {
        const host = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, entry[0] }, 0);
        defer a.free(host);
        _ = c.mkdir(host.ptr, 0o755);
    }
    for ([_][2][]const u8{ .{ "bin/echo", "/bin/busybox" }, .{ "lib", "usr/lib" }, .{ "usr/lib/up", "../../bin" }, .{ "loop", "/loop" } }) |link| {
        const host = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, link[0] }, 0);
        defer a.free(host);
        const target = try a.dupeZ(u8, link[1]);
        defer a.free(target);
        try std.testing.expectEqual(@as(c_int, 0), c.symlink(target.ptr, host.ptr));
    }
    const cases = [_]struct { path: []const u8, follow: bool, expected: []const u8 }{
        .{ .path = "/bin/echo", .follow = true, .expected = "/bin/busybox" },
        .{ .path = "/bin/echo", .follow = false, .expected = "/bin/echo" },
        .{ .path = "/lib/up/echo", .follow = true, .expected = "/bin/busybox" },
        .{ .path = "/../../lib/x/", .follow = true, .expected = "/usr/lib/x/" },
        .{ .path = "/", .follow = true, .expected = "/" },
    };
    for (cases) |case| {
        const path = try chroot(a, root, case.path, case.follow);
        defer a.free(path);
        const expected = try std.fmt.allocPrint(a, "{s}{s}", .{ root, case.expected });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, path);
    }
    try std.testing.expectError(error.SymbolicLinkLoop, chroot(a, root, "/loop", true));
    const relative = try chroot(a, root, "relative/name", true);
    defer a.free(relative);
    try std.testing.expectEqualStrings("relative/name", relative);
}
