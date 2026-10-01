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
pub const Dirty = struct { pages: *std.AutoHashMapUnmanaged(u64, void), offset: u64 = 0 };
const Region = struct {
    address: u64,
    data: []u8,
    permissions: Permissions,
    maximum: Permissions = .{ .read = true, .write = true, .execute = true },
    file_end: ?u64 = null,
    owned: bool = true,
    copy: bool = false,
    dirty: ?Dirty = null,
    fn release(r: Region, allocator: std.mem.Allocator) void {
        if (r.owned) allocator.free(r.data);
    }
    fn slice(r: Region, allocator: std.mem.Allocator, start: usize, end: usize) !Region {
        var result = r;
        result.address += start;
        result.data = if (r.owned) try allocator.dupe(u8, r.data[start..end]) else r.data[start..end];
        if (result.dirty) |*dirty| dirty.offset += start;
        return result;
    }
};
pub const Memory = struct {
    allocator: std.mem.Allocator,
    regions: std.ArrayList(Region) = .empty,
    used: usize = 0,
    generation: u64 = 0,
    writes: u64 = 0,
    limit: usize = 256 * 1024 * 1024,
    fault: ?Fault = null,
    pub const page_size = 4096;
    pub fn init(a: std.mem.Allocator) Memory {
        return .{ .allocator = a };
    }
    pub fn deinit(m: *Memory) void {
        for (m.regions.items) |r| r.release(m.allocator);
        m.regions.deinit(m.allocator);
    }
    pub fn map(m: *Memory, address: u64, size: usize, permissions: Permissions) !void {
        return m.mapWithMaximum(address, size, permissions, .{ .read = true, .write = true, .execute = true });
    }
    pub fn mapWithMaximum(m: *Memory, address: u64, size: usize, permissions: Permissions, maximum: Permissions) !void {
        if (!subset(permissions, maximum)) return error.ProtectionLimit;
        const end = try mappingEnd(address, size);
        if (size > m.limit - m.used or m.regions.items.len >= 1024) return error.MemoryLimit;
        for (m.regions.items) |r| if (address < r.address + r.data.len and r.address < end) return error.OverlappingMapping;
        const data = try m.allocator.alloc(u8, size);
        errdefer m.allocator.free(data);
        @memset(data, 0);
        try m.regions.append(m.allocator, .{ .address = address, .data = data, .permissions = permissions, .maximum = maximum });
        m.used += size;
        m.generation +%= 1;
    }
    // The caller retains backing ownership until this complete view is unmapped.
    pub fn borrow(m: *Memory, address: u64, data: []u8, permissions: Permissions, copy: bool, dirty: ?Dirty) !void {
        _ = try mappingEnd(address, data.len);
        if (data.len > m.limit - m.used or m.regions.items.len >= 1024) return error.MemoryLimit;
        if (!m.available(address, data.len)) return error.OverlappingMapping;
        try m.regions.append(m.allocator, .{ .address = address, .data = data, .permissions = permissions, .maximum = permissions, .owned = false, .copy = copy, .dirty = dirty });
        m.used += data.len;
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
        var tails: [2]Region = undefined;
        var tail_count: usize = 0;
        errdefer for (tails[0..tail_count]) |tail| tail.release(m.allocator);
        for (m.regions.items) |r| {
            const r_end = r.address + r.data.len;
            if (address >= r_end or r.address >= end) {
                next.appendAssumeCapacity(r);
                continue;
            }
            if (r.address < address) {
                const tail = try r.slice(m.allocator, 0, @intCast(address - r.address));
                tails[tail_count] = tail;
                tail_count += 1;
                next.appendAssumeCapacity(tail);
            }
            if (r_end > end) {
                const tail = try r.slice(m.allocator, @intCast(end - r.address), r.data.len);
                tails[tail_count] = tail;
                tail_count += 1;
                next.appendAssumeCapacity(tail);
            }
        }
        next.appendAssumeCapacity(.{ .address = address, .data = data, .permissions = permissions });
        for (m.regions.items) |r| if (address < r.address + r.data.len and r.address < end) r.release(m.allocator);
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
    // Reserve COW pages and dirty bookkeeping before publishing separate guest outputs.
    pub fn prepareWrite(m: *Memory, address: u64, size: usize) !void {
        try m.check(address, size, .write);
        try m.prepare(address, size);
    }
    // Loader-only initialization: mapped pages may already be RX or read-only.
    pub fn initialize(m: *Memory, address: u64, data: []const u8) !void {
        try m.prepare(address, data.len);
        var done: usize = 0;
        while (done < data.len) {
            const r = m.region(address + done) orelse return error.UnmappedMemory;
            const off: usize = @intCast(address + done - r.address);
            const n = @min(data.len - done, r.data.len - off);
            if (r.permissions.execute or !r.owned) m.generation +%= 1; // Shared aliases may contain executable guest code.
            m.writes +%= 1;
            @memcpy(r.data[off..][0..n], data[done..][0..n]);
            done += n;
        }
    }
    fn prepare(m: *Memory, address: u64, size: usize) !void {
        _ = std.math.add(u64, address, size) catch return error.AddressOverflow;
        // Detach only written guest pages, independently of the host's larger page size.
        var prepared: usize = 0;
        while (prepared < size) {
            const r = m.region(address + prepared) orelse return error.UnmappedMemory;
            if (r.copy) {
                const page = std.mem.alignBackward(u64, address + prepared, page_size);
                const bytes = try m.allocator.dupe(u8, r.data[@intCast(page - r.address)..][0..page_size]);
                errdefer m.allocator.free(bytes);
                const extra = @as(usize, @intFromBool(page > r.address)) + @as(usize, @intFromBool(page + page_size < r.address + r.data.len));
                if (m.regions.items.len + extra > 1024) return error.MemoryLimit;
                try m.regions.ensureUnusedCapacity(m.allocator, extra);
                try m.split(page);
                try m.split(page + page_size);
                const detached = m.region(page).?;
                detached.data = bytes;
                detached.owned = true;
                detached.copy = false;
                detached.dirty = null;
                continue;
            }
            const off: usize = @intCast(address + prepared - r.address);
            const n = @min(size - prepared, r.data.len - off);
            if (r.dirty) |dirty| {
                const first = (dirty.offset + off) / page_size;
                const last = (dirty.offset + off + n - 1) / page_size;
                for (first..last + 1) |page| try dirty.pages.put(m.allocator, page, {});
            }
            prepared += n;
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
            const left = try r.slice(m.allocator, 0, off);
            errdefer left.release(m.allocator);
            const right = try r.slice(m.allocator, off, r.data.len);
            errdefer right.release(m.allocator);
            try m.regions.append(m.allocator, right);
            r.release(m.allocator);
            m.regions.items[i] = left;
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
            if (!subset(p, r.maximum)) return error.ProtectionLimit;
            cursor = @min(end, r.address + r.data.len);
        }
        m.generation +%= 1;
        try m.split(address);
        try m.split(end);
        for (m.regions.items) |*r| if (r.address >= address and r.address < end) {
            r.permissions = p;
        };
    }
    fn subset(p: Permissions, maximum: Permissions) bool {
        return (!p.read or maximum.read) and (!p.write or maximum.write) and (!p.execute or maximum.execute);
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
                r.release(m.allocator);
                _ = m.regions.swapRemove(i);
            } else i += 1;
        }
    }
};
test "shared views retain aliases through splits and copy only written guest pages" {
    const allocator = std.testing.allocator;
    const backing = try allocator.alloc(u8, 8192);
    defer allocator.free(backing);
    @memset(backing, 0);
    var dirty: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer dirty.deinit(allocator);
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.borrow(0x10000, backing, .{ .read = true, .write = true }, false, .{ .pages = &dirty, .offset = 65536 });
    try m.borrow(0x20000, backing, .{ .read = true }, false, null);
    try m.borrow(0x30000, backing, .{ .read = true, .write = true }, true, null);
    try m.protect(0x11000, 4096, .{ .read = true });
    const generation = m.generation;
    try m.writeInt(0x10001, 8, 11);
    try std.testing.expect(m.generation > generation and dirty.contains(16));
    try std.testing.expectEqual(@as(u64, 11), try m.readInt(0x20001, 8, .read));
    try m.writeInt(0x30002, 8, 22);
    try m.writeInt(0x10001, 8, 33);
    try std.testing.expectEqual(@as(u64, 11), try m.readInt(0x30001, 8, .read));
    try std.testing.expectEqual(@as(u8, 0), backing[2]);
    backing[4097] = 44;
    try std.testing.expectEqual(@as(u64, 44), try m.readInt(0x31001, 8, .read));
    try std.testing.expectError(error.PermissionDenied, m.writeInt(0x21001, 8, 1));
    try std.testing.expectError(error.ProtectionLimit, m.protect(0x20000, 4096, .{ .execute = true }));
    try m.replace(0x10000, 4096, .{ .read = true, .write = true });
    try std.testing.expectEqual(@as(u64, 44), try m.readInt(0x11001, 8, .read));
    try m.unmap(0x10000, 8192);
    try std.testing.expectEqual(@as(u64, 33), try m.readInt(0x20001, 8, .read));
    try std.testing.expectEqual(@as(usize, 1), dirty.count());
}
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
test "maximum protection survives region splits and fixed replacement tails" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.mapWithMaximum(0x1000, 12288, .{ .read = true, .execute = true }, .{ .read = true, .execute = true });
    try memory.protect(0x2000, 4096, .{ .read = true });
    try std.testing.expectError(error.ProtectionLimit, memory.protect(0x2000, 4096, .{ .write = true }));
    try memory.replace(0x1000, 4096, .{ .read = true, .write = true });
    try std.testing.expectError(error.ProtectionLimit, memory.protect(0x3000, 4096, .{ .write = true }));
    try memory.protect(0x2000, 4096, .{ .read = true, .execute = true });
    try std.testing.expectError(error.PermissionDenied, memory.writeInt(0x2000, 8, 1));
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
