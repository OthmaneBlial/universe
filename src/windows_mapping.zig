const std = @import("std");
const host = @import("host.zig");
const memory = @import("memory.zig");
const Memory = memory.Memory;
pub const Source = struct { fd: c_int, access: u2, device: u64, inode: u64, size: u64 };
const Backing = struct {
    fd: c_int,
    source: ?Source,
    size: u64,
    references: usize = 0,
    loaded: std.AutoHashMapUnmanaged(u64, void) = .empty,
    dirty: std.AutoHashMapUnmanaged(u64, void) = .empty,
    fn deinit(backing: *Backing, allocator: std.mem.Allocator) void {
        _ = host.c.close(backing.fd);
        if (backing.source) |source| _ = host.c.close(source.fd);
        backing.loaded.deinit(allocator);
        backing.dirty.deinit(allocator);
        allocator.destroy(backing);
    }
};
fn allocationProbe(allocator: std.mem.Allocator) !void {
    var m = Memory.init(allocator);
    defer m.deinit();
    var maps: Mappings = .{};
    defer maps.deinit(allocator);
    _ = try maps.create(allocator, 1, null, 8192, 4, "probe");
    const shared = try maps.map(allocator, &m, 1, 2, 0, 8192, 0, 0x10000);
    const copy = try maps.map(allocator, &m, 1, 1, 0, 8192, 0, 0x20000);
    try m.writeInt(shared + 1, 8, 11);
    try m.writeInt(copy + 4094, 64, 0x8877665544332211);
    try std.testing.expectEqual(@as(u64, 11), try m.readInt(copy + 1, 8, .read));
    try maps.unmap(allocator, &m, copy);
    try maps.unmap(allocator, &m, shared);
    try std.testing.expect(maps.close(allocator, 1));
    maps.deinit(allocator);
    try std.testing.expect(maps.objects.items.len == 0 and !maps.holds(1, 1));
}
test "mapping allocation failures release section, view and COW ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
const Object = struct { backing: *Backing, size: u64, protection: u32, name: ?[]const u8, references: usize = 0 };
const Handle = struct { value: u64, object: usize, access: u32 };
const View = struct { address: u64, bytes: []u8, offset: u64, object: usize, copy: bool };
pub const Mappings = struct {
    // ponytail: 1,024 handles/views and linear object lookup; hash names if real workloads warrant it.
    objects: std.ArrayList(?Object) = .empty,
    handles: std.ArrayList(Handle) = .empty,
    views: std.ArrayList(View) = .empty,
    pub fn deinit(maps: *Mappings, allocator: std.mem.Allocator) void {
        maps.flushAll() catch {
            host.output(2, "UNIVERSE: Windows mapping writeback failed during cleanup\n") catch {};
        };
        for (maps.views.items) |view| _ = host.c.munmap(view.bytes.ptr, view.bytes.len);
        for (maps.objects.items) |*entry| if (entry.*) |object| {
            if (object.name) |name| allocator.free(name);
            object.backing.references -= 1;
            if (object.backing.references == 0) object.backing.deinit(allocator);
            entry.* = null;
        };
        maps.objects.deinit(allocator);
        maps.handles.deinit(allocator);
        maps.views.deinit(allocator);
        maps.* = .{}; // Windows still checks pending file deletions after releasing sections.
    }
    pub fn named(maps: Mappings, name: []const u8) ?usize {
        for (maps.objects.items, 0..) |entry, index| if (entry) |object| {
            if (object.name) |existing| if (std.mem.eql(u8, existing, name)) return index;
        };
        return null;
    }
    pub fn holds(maps: Mappings, device: u64, inode: u64) bool {
        for (maps.objects.items) |entry| if (entry) |object| if (object.backing.source) |source| {
            if (source.device == device and source.inode == inode) return true;
        };
        return false;
    }
    pub fn contains(maps: Mappings, handle: u64) bool {
        for (maps.handles.items) |entry| if (entry.value == handle) return true;
        return false;
    }
    pub fn open(maps: *Mappings, allocator: std.mem.Allocator, index: usize, handle: u64, requested: u32) !u64 {
        if (maps.handles.items.len >= 1024) return error.MemoryLimit;
        var access = requested;
        if (access & 1 != 0 and access != 0xf001f) access = (access & ~@as(u32, 1)) | 4; // FILE_MAP_COPY uses read access.
        if (access & ~@as(u32, 0xf003f) != 0) return error.WindowsMappingAccess;
        const object = &maps.objects.items[index].?;
        if ((access & 2 != 0 and !writable(object.protection)) or (access & 0x20 != 0 and !executable(object.protection))) return error.WindowsMappingAccess;
        try maps.handles.append(allocator, .{ .value = handle, .object = index, .access = access });
        object.references += 1;
        return handle;
    }
    fn writable(protection: u32) bool {
        return protection == 4 or protection == 0x40;
    }
    fn executable(protection: u32) bool {
        return protection >= 0x20;
    }
    pub fn create(maps: *Mappings, allocator: std.mem.Allocator, handle: u64, source: ?Source, size: u64, protect: u32, name: ?[]const u8) !u64 {
        const protection = protect & ~@as(u32, 0x8000000); // SEC_COMMIT is the default.
        if (protection != 2 and protection != 4 and protection != 8 and protection != 0x20 and protection != 0x40 and protection != 0x80) return error.WindowsMappingUnsupported;
        if (size == 0) return error.WindowsMappingEmpty;
        if (size > std.math.maxInt(i64) - Memory.page_size) return error.WindowsMappingParameter;
        if (maps.handles.items.len >= 1024) return error.MemoryLimit;
        if (source) |file| {
            if (file.access & 1 == 0 or (writable(protection) and file.access & 2 == 0)) return error.WindowsMappingAccess;
            if (executable(protection)) return error.WindowsMappingUnsupported; // File GENERIC_EXECUTE is not modeled yet.
            if (size > file.size and !writable(protection)) return error.WindowsMappingAccess;
        }
        try maps.handles.ensureUnusedCapacity(allocator, 1);
        const index = for (maps.objects.items, 0..) |entry, index| {
            if (entry == null) break index;
        } else maps.objects.items.len;
        if (index == maps.objects.items.len) try maps.objects.append(allocator, null);
        const owned_name = if (name) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_name) |value| allocator.free(value);
        var existing: ?*Backing = null;
        if (source) |file| for (maps.objects.items) |entry| if (entry) |object| if (object.backing.source) |previous| {
            if (file.device == previous.device and file.inode == previous.inode) {
                existing = object.backing;
                break;
            }
        };
        const backing = existing orelse blk: {
            var template = "/tmp/universe-section-XXXXXX".*;
            const fd = host.c.mkstemp(&template);
            if (fd < 0) return error.HostMappingFailed;
            errdefer _ = host.c.close(fd);
            if (host.c.unlink(&template) != 0) return error.HostMappingFailed;
            if (host.c.fcntl(fd, host.c.F_SETFD, @as(c_int, host.c.FD_CLOEXEC)) < 0) return error.HostMappingFailed;
            const duplicate = if (source) |file| host.c.fcntl(file.fd, host.c.F_DUPFD_CLOEXEC, @as(c_int, 3)) else -1;
            if (source != null and duplicate < 0) return error.HostMappingFailed;
            errdefer if (duplicate >= 0) {
                _ = host.c.close(duplicate);
            };
            const created = try allocator.create(Backing);
            created.* = .{ .fd = fd, .source = source, .size = 0 };
            if (created.source) |*file| file.fd = duplicate;
            break :blk created;
        };
        errdefer if (existing == null) backing.deinit(allocator);
        // Prepare the private backing before extending any user file.
        if (size > backing.size and host.c.ftruncate(backing.fd, @intCast(std.mem.alignForward(u64, size, Memory.page_size))) != 0) return error.HostMappingFailed;
        if (source) |file| {
            var replacement: c_int = -1;
            if (file.access & 2 != 0 and backing.source.?.access & 2 == 0) {
                replacement = host.c.fcntl(file.fd, host.c.F_DUPFD_CLOEXEC, @as(c_int, 3));
                if (replacement < 0) return error.HostMappingFailed;
            }
            errdefer if (replacement >= 0) {
                _ = host.c.close(replacement);
            };
            if (size > file.size and host.c.ftruncate(file.fd, @intCast(size)) != 0) return error.HostMappingFailed;
            if (replacement >= 0) {
                _ = host.c.close(backing.source.?.fd);
                backing.source.?.fd = replacement;
                backing.source.?.access = file.access;
            }
            backing.source.?.size = @max(backing.source.?.size, @max(size, file.size));
        }
        backing.size = @max(backing.size, size);
        backing.references += 1;
        maps.objects.items[index] = .{ .backing = backing, .size = size, .protection = protection, .name = owned_name, .references = 1 };
        maps.handles.appendAssumeCapacity(.{ .value = handle, .object = index, .access = 0xf001f | (if (executable(protection)) @as(u32, 0x20) else 0) });
        return handle;
    }
    fn transfer(fd: c_int, bytes: []u8, offset: u64, read: bool) !void {
        var done: usize = 0;
        while (done < bytes.len) {
            const n = if (read) host.c.pread(fd, bytes.ptr + done, bytes.len - done, @intCast(offset + done)) else host.c.pwrite(fd, bytes.ptr + done, bytes.len - done, @intCast(offset + done));
            if (n < 0) {
                if (host.errno() == host.c.EINTR) continue;
                return error.HostMappingFailed;
            }
            if (n == 0) return error.WindowsMappingReadFault;
            done += @intCast(n);
        }
    }
    fn populate(backing: *Backing, allocator: std.mem.Allocator, offset: u64, size: usize) !void {
        const source = backing.source orelse return; // The sparse private paging file is zero-filled.
        var bytes: [Memory.page_size]u8 = undefined;
        const first = offset / Memory.page_size;
        const last = (offset + size - 1) / Memory.page_size;
        for (first..last + 1) |page| if (!backing.loaded.contains(page)) {
            try backing.loaded.ensureUnusedCapacity(allocator, 1);
            @memset(&bytes, 0);
            const position = page * Memory.page_size;
            const amount: usize = @intCast(@min(Memory.page_size, source.size -| position));
            if (amount != 0) try transfer(source.fd, bytes[0..amount], position, true);
            try transfer(backing.fd, &bytes, position, false);
            backing.loaded.putAssumeCapacity(page, {});
        };
    }
    pub fn map(maps: *Mappings, allocator: std.mem.Allocator, m: *Memory, handle: u64, access: u32, offset: u64, requested: u64, base: u64, next: u64) !u64 {
        const entry = for (maps.handles.items) |entry| {
            if (entry.value == handle) break entry;
        } else return error.WindowsMappingHandle;
        const object = &maps.objects.items[entry.object].?;
        const all = access & ~@as(u32, 0x20) == 0xf001f;
        if (!all and access & ~@as(u32, 0x27) != 0) return error.WindowsMappingUnsupported;
        const write = all or access & 2 != 0;
        const copy = !write and access & 1 != 0;
        const execute = access & 0x20 != 0;
        if ((!write and !copy and access & 4 == 0) or (write and (!writable(object.protection) or entry.access & 2 == 0)) or (!write and entry.access & 6 == 0) or (execute and (!executable(object.protection) or entry.access & 0x20 == 0))) return error.WindowsMappingAccess;
        if (offset % 65536 != 0 or (base != 0 and base % 65536 != 0)) return error.WindowsMappingAlignment;
        if (offset >= object.size or requested > object.size - offset) return error.WindowsMappingParameter;
        const amount = if (requested == 0) object.size - offset else requested;
        if (amount > m.limit or maps.views.items.len >= 1024) return error.MemoryLimit;
        const length: usize = @intCast(std.mem.alignForward(u64, amount, Memory.page_size));
        if (length > m.limit - m.used) return error.MemoryLimit;
        var address = base;
        if (address == 0) {
            address = std.mem.alignForward(u64, next, 65536);
            while (!m.available(address, length)) address = std.mem.alignForward(u64, try m.findFree(address, length), 65536);
        }
        if (!m.available(address, length)) return error.WindowsMappingAddress;
        try maps.views.ensureUnusedCapacity(allocator, 1);
        try populate(object.backing, allocator, offset, length);
        const pointer = host.c.mmap(null, length, host.c.PROT_READ | host.c.PROT_WRITE, host.c.MAP_SHARED, object.backing.fd, @intCast(offset));
        if (pointer == host.c.MAP_FAILED) return error.HostMappingFailed;
        const bytes = @as([*]u8, @ptrCast(pointer.?))[0..length];
        errdefer _ = host.c.munmap(bytes.ptr, bytes.len);
        try m.borrow(address, bytes, .{ .read = true, .write = write or copy, .execute = execute }, copy, if (!copy) .{ .pages = &object.backing.dirty, .offset = offset } else null);
        object.references += 1;
        maps.views.appendAssumeCapacity(.{ .address = address, .bytes = bytes, .offset = offset, .object = entry.object, .copy = copy });
        return address;
    }
    fn flush(backing: *Backing, offset: u64, amount: u64) !void {
        const source = backing.source orelse return;
        if (backing.dirty.count() == 0) return;
        const current = host.statFd(source.fd) catch return error.HostMappingFailed;
        if (current.size < 0 or @as(u64, @intCast(current.size)) < source.size) return error.WindowsMappingChanged;
        var bytes: [Memory.page_size]u8 = undefined;
        var page = offset / Memory.page_size;
        const end = std.mem.alignForward(u64, offset + amount, Memory.page_size) / Memory.page_size;
        while (page < end) : (page += 1) if (backing.dirty.contains(page)) {
            const position = page * Memory.page_size;
            const count: usize = @intCast(@min(Memory.page_size, source.size -| position));
            if (count != 0) {
                try transfer(backing.fd, bytes[0..count], position, true);
                try transfer(source.fd, bytes[0..count], position, false);
            }
            _ = backing.dirty.remove(page);
        };
    }
    pub fn flushView(maps: *Mappings, address: u64, requested: u64) !void {
        const view = for (maps.views.items) |view| {
            if (address >= view.address and address - view.address < view.bytes.len) break view;
        } else return error.WindowsMappingAddress;
        const offset = address - view.address;
        const length = if (requested == 0) view.bytes.len - offset else requested;
        if (length > view.bytes.len - offset) return error.WindowsMappingParameter;
        if (!view.copy) try flush(maps.objects.items[view.object].?.backing, view.offset + offset, length);
    }
    pub fn flushAll(maps: *Mappings) !void {
        for (maps.views.items) |view| if (!view.copy) try flush(maps.objects.items[view.object].?.backing, view.offset, view.bytes.len);
    }
    fn release(maps: *Mappings, allocator: std.mem.Allocator, index: usize) void {
        const object = &maps.objects.items[index].?;
        object.references -= 1;
        if (object.references != 0) return;
        if (object.name) |name| allocator.free(name);
        const backing = object.backing;
        maps.objects.items[index] = null;
        backing.references -= 1;
        if (backing.references == 0) backing.deinit(allocator);
    }
    pub fn close(maps: *Mappings, allocator: std.mem.Allocator, handle: u64) bool {
        for (maps.handles.items, 0..) |entry, index| if (entry.value == handle) {
            maps.release(allocator, entry.object);
            _ = maps.handles.swapRemove(index);
            return true;
        };
        return false;
    }
    pub fn unmap(maps: *Mappings, allocator: std.mem.Allocator, m: *Memory, address: u64) !void {
        for (maps.views.items, 0..) |view, index| if (view.address == address) {
            try maps.flushView(address, 0);
            try m.unmap(view.address, view.bytes.len);
            if (host.c.munmap(view.bytes.ptr, view.bytes.len) != 0) return error.HostMappingFailed;
            maps.release(allocator, view.object);
            _ = maps.views.swapRemove(index);
            return;
        };
        return error.WindowsMappingAddress;
    }
};
