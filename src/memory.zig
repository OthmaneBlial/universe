const std = @import("std");
pub const Access = enum { read, write, execute };
pub const Permissions = struct {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    pub fn allows(p: Permissions, a: Access) bool {
        return switch (a) {
            .read => p.read,
            .write => p.write,
            .execute => p.execute,
        };
    }
};
pub const Fault = struct { address: u64, size: usize, access: Access };
const Region = struct { address: u64, data: []u8, permissions: Permissions };
pub const Memory = struct {
    allocator: std.mem.Allocator,
    regions: std.ArrayList(Region) = .empty,
    used: usize = 0,
    generation: u64 = 0,
    limit: usize = 256 * 1024 * 1024,
    fault: ?Fault = null,
    pub const page_size = 4096;
    pub fn init(a: std.mem.Allocator) Memory {
        return .{ .allocator = a };
    }
    pub fn deinit(m: *Memory) void {
        for (m.regions.items) |r| m.allocator.free(r.data);
        m.regions.deinit(m.allocator);
    }
    pub fn map(m: *Memory, address: u64, size: usize, permissions: Permissions) !void {
        if (size == 0 or address % page_size != 0 or size % page_size != 0) return error.InvalidMapping;
        const end = std.math.add(u64, address, size) catch return error.AddressOverflow;
        if (address < page_size or end > 0x800000000000) return error.InvalidMapping;
        if (size > m.limit - m.used or m.regions.items.len >= 1024) return error.MemoryLimit;
        for (m.regions.items) |r| if (address < r.address + r.data.len and r.address < end) return error.OverlappingMapping;
        const data = try m.allocator.alloc(u8, size);
        errdefer m.allocator.free(data);
        @memset(data, 0);
        try m.regions.append(m.allocator, .{ .address = address, .data = data, .permissions = permissions });
        m.used += size;
        m.generation +%= 1;
    }
    fn region(m: *Memory, address: u64) ?*Region {
        // ponytail: linear search capped at 1024 mappings; use a page table when profiling warrants it.
        for (m.regions.items) |*r| if (address >= r.address and address - r.address < r.data.len) return r;
        return null;
    }
    pub fn check(m: *Memory, address: u64, size: usize, access: Access) !void {
        m.fault = .{ .address = address, .size = size, .access = access };
        _ = std.math.add(u64, address, size) catch return error.AddressOverflow;
        var done: usize = 0;
        while (done < size) {
            const r = m.region(address + done) orelse return error.UnmappedMemory;
            if (!r.permissions.allows(access)) return error.PermissionDenied;
            done += @min(size - done, r.data.len - @as(usize, @intCast(address + done - r.address)));
        }
        m.fault = null;
    }
    pub fn read(m: *Memory, address: u64, out: []u8, access: Access) !void {
        try m.check(address, out.len, access);
        var done: usize = 0;
        while (done < out.len) {
            const r = m.region(address + done).?;
            const off: usize = @intCast(address + done - r.address);
            const n = @min(out.len - done, r.data.len - off);
            @memcpy(out[done..][0..n], r.data[off..][0..n]);
            done += n;
        }
    }
    pub fn write(m: *Memory, address: u64, data: []const u8) !void {
        try m.check(address, data.len, .write);
        try m.initialize(address, data);
    }
    // Loader-only initialization: mapped pages may already be RX or read-only.
    pub fn initialize(m: *Memory, address: u64, data: []const u8) !void {
        _ = std.math.add(u64, address, data.len) catch return error.AddressOverflow;
        var done: usize = 0;
        while (done < data.len) {
            const r = m.region(address + done) orelse return error.UnmappedMemory;
            const off: usize = @intCast(address + done - r.address);
            const n = @min(data.len - done, r.data.len - off);
            if (r.permissions.execute) m.generation +%= 1;
            @memcpy(r.data[off..][0..n], data[done..][0..n]);
            done += n;
        }
    }
    pub fn readInt(m: *Memory, address: u64, width: u7, access: Access) !u64 {
        var buf: [8]u8 = @splat(0);
        try m.read(address, buf[0 .. width / 8], access);
        return std.mem.readInt(u64, &buf, .little);
    }
    pub fn writeInt(m: *Memory, address: u64, width: u7, value: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        try m.write(address, buf[0 .. width / 8]);
    }
    pub fn cstring(m: *Memory, a: std.mem.Allocator, address: u64, limit: usize) ![:0]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(a);
        for (0..limit) |i| {
            const v: u8 = @intCast(try m.readInt(std.math.add(u64, address, i) catch return error.AddressOverflow, 8, .read));
            if (v == 0) return try a.dupeZ(u8, bytes.items);
            try bytes.append(a, v);
        }
        return error.StringTooLong;
    }
    fn split(m: *Memory, address: u64) !void {
        for (m.regions.items, 0..) |r, i| {
            if (address <= r.address or address >= r.address + r.data.len) continue;
            if (m.regions.items.len >= 1024) return error.MemoryLimit;
            const off: usize = @intCast(address - r.address);
            const left = try m.allocator.dupe(u8, r.data[0..off]);
            errdefer m.allocator.free(left);
            const right = try m.allocator.dupe(u8, r.data[off..]);
            errdefer m.allocator.free(right);
            try m.regions.append(m.allocator, .{ .address = address, .data = right, .permissions = r.permissions });
            m.allocator.free(r.data);
            m.regions.items[i].data = left;
            return;
        }
    }
    fn rangeEnd(address: u64, size: usize) !u64 {
        if (address % page_size != 0 or size == 0 or size % page_size != 0) return error.InvalidMapping;
        return std.math.add(u64, address, size) catch error.AddressOverflow;
    }
    pub fn protect(m: *Memory, address: u64, size: usize, p: Permissions) !void {
        const end = try rangeEnd(address, size);
        var cursor = address;
        while (cursor < end) {
            const r = m.region(cursor) orelse return error.UnmappedMemory;
            cursor = @min(end, r.address + r.data.len);
        }
        m.generation +%= 1;
        try m.split(address);
        try m.split(end);
        for (m.regions.items) |*r| if (r.address >= address and r.address < end) {
            r.permissions = p;
        };
    }
    pub fn unmap(m: *Memory, address: u64, size: usize) !void {
        const end = try rangeEnd(address, size);
        m.generation +%= 1;
        try m.split(address);
        try m.split(end);
        var i: usize = 0;
        while (i < m.regions.items.len) {
            const r = m.regions.items[i];
            if (r.address >= address and r.address < end) {
                m.used -= r.data.len;
                m.allocator.free(r.data);
                _ = m.regions.swapRemove(i);
            } else i += 1;
        }
    }
};
test "guest isolation, BSS, permissions, split protection and unmap" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 8192, .{ .read = true, .write = true });
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1000, 64, .read));
    try m.writeInt(0x1ffc, 64, 0x1234);
    try std.testing.expectEqual(@as(u64, 0x1234), try m.readInt(0x1ffc, 64, .read));
    try std.testing.expectError(error.PermissionDenied, m.readInt(0x1000, 8, .execute));
    try m.protect(0x2000, 4096, .{ .read = true });
    try std.testing.expectError(error.PermissionDenied, m.writeInt(0x1ffc, 64, 0xffff));
    try std.testing.expectEqual(@as(u64, 0x1234), try m.readInt(0x1ffc, 64, .read));
    try m.unmap(0x1000, 4096);
    try std.testing.expectError(error.UnmappedMemory, m.readInt(0x1000, 8, .read));
    try std.testing.expectError(error.AddressOverflow, m.readInt(std.math.maxInt(u64), 64, .read));
    try std.testing.expectError(error.OverlappingMapping, m.map(0x2000, 4096, .{}));
}
