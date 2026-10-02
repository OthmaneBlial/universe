const std = @import("std");
const host = @import("host.zig");

pub const Device = struct {
    pub const Kind = enum { null, zero, mounts };
    const mount_list = "universe / universe rw 0 0\n";
    // Occupies an existing guest descriptor slot without owning a native FD.
    pub const fd: c_int = std.math.minInt(c_int);
    allocator: std.mem.Allocator,
    kind: Kind,
    status: u64,
    offset: u64 = 0,
    references: usize = 0,

    pub fn retain(d: *Device) void {
        d.references += 1;
    }
    pub fn release(d: *Device) void {
        d.references -= 1;
        if (d.references == 0) d.allocator.destroy(d);
    }
    pub fn readAt(d: Device, offset: u64, buffer: []u8) usize {
        switch (d.kind) {
            .null => return 0,
            .zero => {
                @memset(buffer, 0);
                return buffer.len;
            },
            .mounts => {
                if (offset >= mount_list.len) return 0;
                const start: usize = @intCast(offset);
                const count = @min(buffer.len, mount_list.len - start);
                @memcpy(buffer[0..count], mount_list[start..][0..count]);
                return count;
            },
        }
    }
    pub fn read(d: *Device, buffer: []u8) usize {
        const count = readAt(d.*, d.offset, buffer);
        if (d.kind == .mounts) d.offset += count;
        return count;
    }
    pub fn seek(d: *Device, offset: i64, whence: u64) ?i64 {
        const base: i64 = switch (whence) {
            0 => 0,
            1 => if (d.offset <= std.math.maxInt(i64)) @intCast(d.offset) else return null,
            2 => mount_list.len,
            else => return null,
        };
        const position = std.math.add(i64, base, offset) catch return null;
        if (position < 0) return null;
        d.offset = @intCast(position);
        return position;
    }
    pub fn path(allocator: std.mem.Allocator, name: []const u8) !?Kind {
        if (!std.fs.path.isAbsolutePosix(name)) return null;
        const normalized = try std.fs.path.resolvePosix(allocator, &.{name});
        defer allocator.free(normalized);
        // ponytail: three reserved absolute leaves use lexical matching; directory lookup needs a VFS.
        for ([_][]const u8{ "/dev/null", "/dev/zero", "/proc/mounts" }, [_]Kind{ .null, .zero, .mounts }) |leaf, kind| {
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
        if (kind == .mounts) return .{ .dev = 0, .ino = 6, .mode = 0o100444, .nlink = 1, .uid = 0, .gid = 0, .rdev = 0, .size = mount_list.len, .blksize = 4096, .blocks = 0, .atime = .{ .sec = 0, .nsec = 0 }, .mtime = .{ .sec = 0, .nsec = 0 }, .ctime = .{ .sec = 0, .nsec = 0 } };
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

test "synthetic mount list reads and seeks without exposing host mounts" {
    const allocator = std.testing.allocator;
    const mount_list = Device.mount_list;
    const device = try allocator.create(Device);
    device.* = .{ .allocator = allocator, .kind = .mounts, .status = 0 };
    device.retain();
    defer device.release();
    var bytes: [16]u8 = undefined;
    const first = device.read(&bytes);
    try std.testing.expectEqual(@as(usize, 16), first);
    try std.testing.expectEqualSlices(u8, "universe / unive", bytes[0..first]);
    try std.testing.expectEqual(@as(?i64, 0), device.seek(0, 0));
    var all: [mount_list.len]u8 = undefined;
    try std.testing.expectEqual(all.len, device.readAt(0, &all));
    try std.testing.expectEqualSlices(u8, mount_list, &all);
    try std.testing.expectEqual(@as(?i64, mount_list.len), device.seek(0, 2));
    try std.testing.expectEqual(@as(usize, 0), device.read(&bytes));
    try std.testing.expectEqual(@as(?i64, null), device.seek(-1, 0));
    const info = Device.stat(.mounts);
    try std.testing.expectEqual(@as(u32, 0o100444), info.mode);
    try std.testing.expectEqual(@as(i64, mount_list.len), info.size);
    try std.testing.expectEqual(@as(?Device.Kind, .mounts), try Device.path(allocator, "/proc/mounts"));
    try std.testing.expectError(error.NotDirectory, Device.path(allocator, "/proc/mounts/child"));
}
