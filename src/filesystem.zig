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
