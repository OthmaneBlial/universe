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
const Region = struct { address: u64, data: []u8, permissions: Permissions, file_end: ?u64 = null };
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
        const end = try mappingEnd(address, size);
        if (size > m.limit - m.used or m.regions.items.len >= 1024) return error.MemoryLimit;
        for (m.regions.items) |r| if (address < r.address + r.data.len and r.address < end) return error.OverlappingMapping;
        const data = try m.allocator.alloc(u8, size);
        errdefer m.allocator.free(data);
        @memset(data, 0);
        try m.regions.append(m.allocator, .{ .address = address, .data = data, .permissions = permissions });
        m.used += size;
        m.generation +%= 1;
    }
    pub fn available(m: *Memory, address: u64, size: usize) bool {
        const end = mappingEnd(address, size) catch return false;
        for (m.regions.items) |r| if (address < r.address + r.data.len and r.address < end) return false;
        return true;
    }
    pub fn findFree(m: *Memory, start: u64, size: usize) !u64 {
        var address = start;
        while (true) {
            const end = try mappingEnd(address, size);
            for (m.regions.items) |r| {
                if (address < r.address + r.data.len and r.address < end) {
                    address = r.address + r.data.len;
                    break;
                }
            } else return address;
        }
    }
    // Allocate all replacement pages and surviving tails before changing a mapping.
    pub fn replace(m: *Memory, address: u64, size: usize, permissions: Permissions) !void {
        const end = try mappingEnd(address, size);
        var used = m.used;
        var count: usize = 1;
        for (m.regions.items) |r| {
            const r_end = r.address + r.data.len;
            if (address < r_end and r.address < end) {
                used -= @intCast(@min(end, r_end) - @max(address, r.address));
                count += @intFromBool(r.address < address) + @as(usize, @intFromBool(r_end > end));
            } else count += 1;
        }
        if (size > m.limit - used or count > 1024) return error.MemoryLimit;
        const data = try m.allocator.alloc(u8, size);
        errdefer m.allocator.free(data);
        @memset(data, 0);
        var next: std.ArrayList(Region) = .empty;
        errdefer next.deinit(m.allocator);
        try next.ensureTotalCapacity(m.allocator, count);
        var tails: [2][]u8 = undefined;
        var tail_count: usize = 0;
        errdefer for (tails[0..tail_count]) |tail| m.allocator.free(tail);
        for (m.regions.items) |r| {
            const r_end = r.address + r.data.len;
            if (address >= r_end or r.address >= end) {
                next.appendAssumeCapacity(r);
                continue;
            }
            if (r.address < address) {
                const tail = try m.allocator.dupe(u8, r.data[0..@intCast(address - r.address)]);
                tails[tail_count] = tail;
                tail_count += 1;
                next.appendAssumeCapacity(.{ .address = r.address, .data = tail, .permissions = r.permissions, .file_end = r.file_end });
            }
            if (r_end > end) {
                const tail = try m.allocator.dupe(u8, r.data[@intCast(end - r.address)..]);
                tails[tail_count] = tail;
                tail_count += 1;
                next.appendAssumeCapacity(.{ .address = end, .data = tail, .permissions = r.permissions, .file_end = r.file_end });
            }
        }
        next.appendAssumeCapacity(.{ .address = address, .data = data, .permissions = permissions });
        for (m.regions.items) |r| if (address < r.address + r.data.len and r.address < end) m.allocator.free(r.data);
        m.regions.deinit(m.allocator);
        m.regions = next;
        m.used = used + size;
        m.generation +%= 1;
    }
    pub fn fileEnd(m: *Memory, address: u64, valid_size: usize) void {
        m.region(address).?.file_end = address + valid_size;
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
            const n = @min(size - done, r.data.len - @as(usize, @intCast(address + done - r.address)));
            if (r.file_end) |end| if (address + done >= end or n > end - (address + done)) return error.BusError;
            done += n;
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
            try m.regions.append(m.allocator, .{ .address = address, .data = right, .permissions = r.permissions, .file_end = r.file_end });
            m.allocator.free(r.data);
            m.regions.items[i].data = left;
            return;
        }
    }
    fn rangeEnd(address: u64, size: usize) !u64 {
        if (address % page_size != 0 or size == 0 or size % page_size != 0) return error.InvalidMapping;
        return std.math.add(u64, address, size) catch error.AddressOverflow;
    }
    fn mappingEnd(address: u64, size: usize) !u64 {
        const end = try rangeEnd(address, size);
        if (address < page_size or end > 0x800000000000) return error.InvalidMapping;
        return end;
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
test "fixed replacement preserves both tails, invalidates code and leaves failed mappings intact" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, replacementAllocationCheck, .{});
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 12288, .{ .read = true, .write = true, .execute = true });
    try m.writeInt(0x1000, 64, 11);
    try m.writeInt(0x3000, 64, 33);
    const generation = m.generation;
    try m.replace(0x2000, 4096, .{ .read = true });
    try std.testing.expect(m.generation > generation);
    try std.testing.expectEqual(@as(u64, 11), try m.readInt(0x1000, 64, .read));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x2000, 64, .read));
    try std.testing.expectEqual(@as(u64, 33), try m.readInt(0x3000, 64, .read));
    try std.testing.expectError(error.PermissionDenied, m.writeInt(0x2000, 64, 1));
    m.limit = m.used;
    try std.testing.expectError(error.MemoryLimit, m.replace(0x1000, 16384, .{}));
    try std.testing.expectEqual(@as(u64, 11), try m.readInt(0x1000, 64, .read));
    try std.testing.expectEqual(@as(u64, 0x4000), try m.findFree(0x1000, 4096));
}
fn replacementAllocationCheck(a: std.mem.Allocator) !void {
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 12288, .{ .read = true, .write = true });
    try m.writeInt(0x2000, 64, 22);
    m.replace(0x2000, 4096, .{ .read = true }) catch |err| {
        try std.testing.expectEqual(@as(u64, 22), try m.readInt(0x2000, 64, .read));
        try std.testing.expectEqual(@as(usize, 12288), m.used);
        return err;
    };
}
test "whole pages beyond file EOF remain faults across permission changes and splits" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 12288, .{ .read = true, .write = true });
    m.fileEnd(0x1000, 4096);
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1fff, 8, .read));
    try std.testing.expectError(error.BusError, m.readInt(0x2000, 8, .read));
    try m.protect(0x2000, 4096, .{ .read = true });
    try std.testing.expectError(error.BusError, m.readInt(0x2000, 8, .read));
    try m.replace(0x2000, 4096, .{ .read = true });
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x2000, 8, .read));
    try std.testing.expectError(error.BusError, m.readInt(0x3000, 8, .read));
}
