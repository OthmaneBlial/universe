const std = @import("std");
const host = @import("host.zig");

pub const Device = struct {
    pub const Kind = enum { null, zero };
    // Occupies an existing guest descriptor slot without owning a native FD.
    pub const fd: c_int = std.math.minInt(c_int);
    allocator: std.mem.Allocator,
    kind: Kind,
    status: u64,
    references: usize = 0,

    pub fn retain(d: *Device) void {
        d.references += 1;
    }
    pub fn release(d: *Device) void {
        d.references -= 1;
        if (d.references == 0) d.allocator.destroy(d);
    }
    pub fn read(d: Device, buffer: []u8) usize {
        if (d.kind == .null) return 0;
        @memset(buffer, 0);
        return buffer.len;
    }
    pub fn path(allocator: std.mem.Allocator, name: []const u8) !?Kind {
        if (!std.fs.path.isAbsolutePosix(name)) return null;
        const normalized = try std.fs.path.resolvePosix(allocator, &.{name});
        defer allocator.free(normalized);
        // ponytail: two absolute leaves, using the existing lexical path profile; a device directory needs a VFS.
        for ([_][]const u8{ "/dev/null", "/dev/zero" }, [_]Kind{ .null, .zero }) |leaf, kind| {
            if (std.mem.startsWith(u8, normalized, leaf) and normalized.len > leaf.len and normalized[leaf.len] == '/') return error.NotDirectory;
            if (std.mem.eql(u8, normalized, leaf)) {
                if (std.mem.endsWith(u8, name, "/") or std.mem.endsWith(u8, name, "/.")) return error.NotDirectory;
                return kind;
            }
        }
        return null;
    }
    pub fn permitsIO(d: Device, writing: bool) bool {
        return d.status & 3 != (if (writing) @as(u64, 0) else 1);
    }
    pub fn noCopy(d: Device, writing: bool) bool {
        return writing or d.kind == .null;
    }
    pub fn checkRange(address: u64, size: u64) !void {
        // Match the guest address ceiling without dereferencing discarded or EOF buffers.
        const limit = 0x800000000000;
        if (address > limit or size > limit - address) return error.AddressOverflow;
    }
    pub fn stat(kind: Kind) host.FileStat {
        const minor: u64 = if (kind == .null) 3 else 5;
        return .{ .dev = 0, .ino = minor, .mode = 0o20666, .nlink = 1, .uid = 0, .gid = 0, .rdev = 0x100 | minor, .size = 0, .blksize = 4096, .blocks = 0, .atime = .{ .sec = 0, .nsec = 0 }, .mtime = .{ .sec = 0, .nsec = 0 }, .ctime = .{ .sec = 0, .nsec = 0 } };
    }
};

test "null and zero devices preserve guards, expose Linux character metadata and share owned open-description flags" {
    const allocator = std.testing.allocator;
    for ([_]Device.Kind{ .null, .zero }) |kind| {
        const device = try allocator.create(Device);
        device.* = .{ .allocator = allocator, .kind = kind, .status = 2 };
        device.retain();
        const duplicate = device;
        duplicate.retain();
        device.status |= 0x800;
        device.release();
        try std.testing.expectEqual(@as(u64, 0x802), duplicate.status);
        var bytes: [8]u8 = @splat(0xa5);
        try std.testing.expectEqual(@as(usize, if (kind == .null) 0 else 4), duplicate.read(bytes[2..6]));
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, bytes[0..2]);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, bytes[6..8]);
        for (bytes[2..6]) |value| try std.testing.expectEqual(@as(u8, if (kind == .null) 0xa5 else 0), value);
        const info = Device.stat(kind);
        try std.testing.expectEqual(@as(u32, 0o20666), info.mode);
        try std.testing.expectEqual(@as(u64, if (kind == .null) 0x103 else 0x105), info.rdev);
        try std.testing.expectEqual(@as(i64, 0), info.size);
        duplicate.release();
    }
}
