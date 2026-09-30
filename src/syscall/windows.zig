const std = @import("std");
const host = @import("../host.zig");
const Memory = @import("../memory.zig").Memory;
const State = @import("../cpu/state.zig").State;
const PE = @import("../loader/pe.zig").Image;
const Api = enum { ExitProcess, GetStdHandle, WriteFile, ReadFile, VirtualAlloc, VirtualFree, GetModuleHandleA, GetModuleHandleW, GetLastError, SetLastError, GetCommandLineA, GetCommandLineW, GetACP, GetProcessHeap, HeapAlloc, HeapReAlloc, HeapFree, HeapSize, CreateFileA, CreateFileW, CloseHandle, GetFileSizeEx, SetFilePointerEx, FlushFileBuffers };
pub const stub_base: u64 = 0x700000000000;
const Allocation = struct { address: u64, size: usize, requested: usize = 0, heap: bool = false };
const File = struct { handle: u64, fd: c_int, access: u2, share: u3, device: u64, inode: u64 };
const invalid_handle = std.math.maxInt(u64);
const process_heap: u64 = 0x103;
pub const Windows = struct {
    allocator: std.mem.Allocator,
    module_base: u64,
    exit_code: ?u8 = null,
    last_error: u32 = 0,
    trace: bool = false,
    allow_files: bool = false,
    sysroot: ?[:0]const u8 = null,
    command_line_a: u64 = 0,
    command_line_w: u64 = 0,
    calls: u64 = 0,
    next_map: u64 = 0x200000000,
    allocations: std.ArrayList(Allocation) = .empty,
    files: std.ArrayList(File) = .empty,
    next_handle: u64 = 0x10000,
    closed_standard: [3]bool = @splat(false),
    pub fn deinit(w: *Windows) void {
        for (w.files.items) |entry| _ = host.c.close(entry.fd);
        w.files.deinit(w.allocator);
        w.allocations.deinit(w.allocator);
    }
    pub fn initProcess(w: *Windows, m: *Memory, args: []const [:0]const u8) !void {
        const line = try @import("../windows_process.zig").commandLine(w.allocator, args);
        defer w.allocator.free(line);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(w.allocator, line);
        defer w.allocator.free(wide);
        const offset = std.mem.alignForward(usize, line.len + 1, 16);
        const bytes = std.mem.sliceAsBytes(wide[0 .. wide.len + 1]);
        const size = std.mem.alignForward(usize, offset + bytes.len, 4096);
        const base = try m.findFree(0x600000000000, size);
        try m.map(base, size, .{ .read = true });
        try m.initialize(base, line[0 .. line.len + 1]);
        try m.initialize(base + offset, bytes);
        w.command_line_a = base;
        w.command_line_w = base + offset;
    }
    fn allocate(w: *Windows, m: *Memory, requested: u64, permissions: @import("../memory.zig").Permissions, is_heap: bool) !u64 {
        if (requested > m.limit) return error.MemoryLimit;
        const size = std.mem.alignForward(usize, @intCast(@max(requested, 1)), 4096);
        try w.allocations.ensureUnusedCapacity(w.allocator, 1);
        const addr = try m.findFree(w.next_map, size);
        try m.map(addr, size, permissions);
        w.allocations.appendAssumeCapacity(.{ .address = addr, .size = size, .requested = @intCast(requested), .heap = is_heap });
        w.next_map = std.mem.alignForward(u64, addr + size, 65536);
        return addr;
    }
    fn heap(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        if (s.get(1) != process_heap) return w.heapFail(api, 6);
        const flags = s.get(2) & 0xffffffff;
        const allowed: u64 = if (api == .HeapAlloc) 8 else if (api == .HeapReAlloc) 8 | 16 else 0;
        if (flags & ~allowed != 0) return w.heapFail(api, 87);
        // ponytail: one mapping per heap block; suballocate when small-allocation volume matters.
        if (api == .HeapAlloc) return w.allocate(m, s.get(8), .{ .read = true, .write = true }, true) catch 0;
        const ptr = s.get(8);
        for (w.allocations.items, 0..) |old, index| if (old.heap and old.address == ptr) {
            if (api == .HeapSize) return old.requested;
            if (api == .HeapFree) {
                try m.unmap(ptr, old.size);
                _ = w.allocations.swapRemove(index);
                return 1;
            }
            const requested = s.get(9);
            if (requested > m.limit) return 0;
            if (requested <= old.size) {
                if (flags & 8 != 0 and requested > old.requested) {
                    const zero = w.allocator.alloc(u8, @intCast(requested - old.requested)) catch return 0;
                    defer w.allocator.free(zero);
                    @memset(zero, 0);
                    try m.write(ptr + old.requested, zero);
                }
                w.allocations.items[index].requested = @intCast(requested);
                return ptr;
            }
            if (flags & 16 != 0) return 0;
            const bytes = w.allocator.alloc(u8, @min(old.requested, @as(usize, @intCast(requested)))) catch return 0;
            defer w.allocator.free(bytes);
            try m.read(ptr, bytes, .read);
            const next = w.allocate(m, requested, .{ .read = true, .write = true }, true) catch return 0;
            try m.write(next, bytes);
            try m.unmap(ptr, old.size);
            _ = w.allocations.swapRemove(index);
            return next;
        };
        return w.heapFail(api, 87);
    }
    fn heapFail(w: *Windows, api: Api, code: u32) u64 {
        _ = w.fail(code);
        return if (api == .HeapSize) invalid_handle else 0;
    }
    fn rva(image: PE, value: u64, size: u64) !u64 {
        if (value >= image.image_size or size > image.image_size - value) return error.InvalidWindowsImport;
        return image.base + value;
    }
    pub fn bind(w: *Windows, image: PE, m: *Memory) !void {
        try m.map(stub_base, 4096, .{ .read = true, .execute = true });
        const poison: [4096]u8 = @splat(0xcc);
        try m.initialize(stub_base, &poison);
        const dir = try image.directory(1);
        if (dir.size == 0) return;
        var offset: u64 = 0;
        var terminated = false;
        while (offset + 20 <= dir.size and offset < 65536) : (offset += 20) {
            const d = try rva(image, @as(u64, dir.rva) + offset, 20);
            const lookup = try m.readInt(d, 32, .read);
            const name_rva = try m.readInt(d + 12, 32, .read);
            const iat = try m.readInt(d + 16, 32, .read);
            if (lookup == 0 and name_rva == 0 and iat == 0) {
                terminated = true;
                break;
            }
            const name_addr = try rva(image, name_rva, 1);
            const dll = try m.cstring(w.allocator, name_addr, @intCast(@min(4096, image.image_size - name_rva)));
            defer w.allocator.free(dll);
            if (!std.ascii.eqlIgnoreCase(dll, "kernel32.dll") and !std.ascii.eqlIgnoreCase(dll, "kernelbase.dll")) {
                try host.print(2, "Unsupported Windows DLL: {s}\n", .{dll});
                return error.UnsupportedWindowsDLL;
            }
            const table = if (lookup == 0) iat else lookup;
            var end = false;
            for (0..4096) |n| {
                const ptr = try rva(image, table + n * 8, 8);
                const item = try m.readInt(ptr, 64, .read);
                if (item == 0) {
                    end = true;
                    break;
                }
                if (item >> 63 != 0) return error.OrdinalImportsUnsupported;
                if (item >= image.image_size or image.image_size - item < 3) return error.InvalidWindowsImport;
                const import_name = try m.cstring(w.allocator, try rva(image, item + 2, 1), @intCast(@min(4096, image.image_size - item - 2)));
                defer w.allocator.free(import_name);
                const api = std.meta.stringToEnum(Api, import_name) orelse {
                    try host.print(2, "Unsupported Windows API: {s}!{s}\n", .{ dll, import_name });
                    return error.UnsupportedWindowsImport;
                };
                const destination = try rva(image, iat + n * 8, 8);
                var buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &buf, stub_base + @as(u64, @intFromEnum(api)) * 16, .little);
                try m.initialize(destination, &buf);
            }
            if (!end) return error.UnterminatedWindowsImports;
        }
        if (!terminated) return error.UnterminatedWindowsImports;
    }
    pub fn handles(pc: u64) bool {
        return pc >= stub_base and pc < stub_base + std.meta.fields(Api).len * 16 and (pc - stub_base) % 16 == 0;
    }
    pub fn dispatch(w: *Windows, s: *State, m: *Memory) !void {
        try m.check(s.pc, 1, .execute);
        const api: Api = @enumFromInt((s.pc - stub_base) / 16);
        const result = try w.perform(s, m, api);
        s.set(0, result);
        w.calls += 1;
        if (w.trace) try host.print(2, "kernel32!{s} = 0x{x}\n", .{ @tagName(api), result });
        if (w.exit_code == null) {
            const target = try m.readInt(s.get(4), 64, .read);
            s.set(4, s.get(4) +% 8);
            s.pc = target;
        }
        s.instructions += 1;
    }
    fn fail(w: *Windows, code: u32) u64 {
        w.last_error = code;
        return 0;
    }
    fn fileFail(w: *Windows, code: u32) u64 {
        _ = w.fail(code);
        return invalid_handle;
    }
    fn hostError() u32 {
        return switch (host.errno()) {
            host.c.ENOENT => 2,
            host.c.ENOTDIR => 3,
            host.c.EACCES, host.c.EPERM, host.c.EISDIR, host.c.EROFS => 5,
            host.c.EBADF => 6,
            host.c.EMFILE, host.c.ENFILE => 4,
            host.c.ENOMEM => 8,
            host.c.EEXIST => 80,
            host.c.ENOSPC => 112,
            host.c.ENAMETOOLONG => 206,
            host.c.EINVAL => 87,
            else => 1117,
        };
    }
    fn stackArg(s: *State, m: *Memory, index: u64) !u64 {
        return m.readInt(s.get(4) +% (8 + index * 8), 64, .read);
    }
    fn file(w: *Windows, handle: u64) ?File {
        for (w.files.items) |entry| if (entry.handle == handle) return entry;
        return null;
    }
    fn openFile(w: *Windows, s: *State, m: *Memory, wide: bool) !u64 {
        if (!w.allow_files) return w.fileFail(5);
        const desired = s.get(2) & 0xffffffff;
        const share = s.get(8) & 0xffffffff;
        const disposition = (try stackArg(s, m, 4)) & 0xffffffff;
        const attributes = (try stackArg(s, m, 5)) & 0xffffffff;
        if (desired & ~@as(u64, 0xc0000000) != 0 or share > 7 or disposition < 1 or disposition > 5) return w.fileFail(87);
        if (s.get(9) != 0 or (attributes != 0 and attributes != 0x80) or try stackArg(s, m, 6) != 0) return w.fileFail(50);
        const access: u2 = @as(u2, @intFromBool(desired & 0x80000000 != 0)) | (@as(u2, @intFromBool(desired & 0x40000000 != 0)) << 1);
        if ((disposition == 2 or disposition == 5) and access & 2 == 0) return w.fileFail(5);
        const path = if (wide) @import("../windows_process.zig").wideString(w.allocator, m, s.get(1)) catch |err| switch (err) {
            error.DanglingSurrogateHalf, error.ExpectedSecondSurrogateHalf, error.UnexpectedSecondSurrogateHalf => return w.fileFail(1113),
            else => return err,
        } else try m.cstring(w.allocator, s.get(1), 131072);
        defer w.allocator.free(path);
        if (!std.unicode.utf8ValidateSlice(path)) return w.fileFail(1113);
        if (path.len == 0) return w.fileFail(3);
        // Host-style paths only; reject DOS drives, streams and device/UNC namespaces.
        if (std.mem.indexOfScalar(u8, path, ':') != null or std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//")) return w.fileFail(50);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const resolved = try @import("../filesystem.zig").resolve(w.allocator, w.sysroot, path);
        defer w.allocator.free(resolved);
        if (w.files.items.len >= 1024) return w.fileFail(4);
        try w.files.ensureUnusedCapacity(w.allocator, 1);
        const flags: c_int = (if (access == 3) host.c.O_RDWR else if (access & 2 != 0) host.c.O_WRONLY else host.c.O_RDONLY) | host.c.O_CLOEXEC | host.c.O_NONBLOCK;
        var created = false;
        var fd: c_int = undefined;
        if (disposition == 1 or disposition == 2 or disposition == 4) {
            fd = host.c.open(resolved.ptr, flags | host.c.O_CREAT | host.c.O_EXCL, @as(host.c.mode_t, 0o666));
            if (fd >= 0) created = true else if (host.errno() == host.c.EEXIST and disposition != 1) {
                fd = host.c.open(resolved.ptr, flags);
            }
        } else fd = host.c.open(resolved.ptr, flags);
        if (fd < 0) return w.fileFail(hostError());
        var keep = false;
        defer {
            if (!keep) _ = host.c.close(fd);
        }
        var info: host.c.struct_stat = undefined;
        if (host.c.fstat(fd, &info) != 0) return w.fileFail(hostError());
        if (info.st_mode & host.c.S_IFMT != host.c.S_IFREG) return w.fileFail(50);
        const device: u64 = @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(info.st_dev))), @bitCast(info.st_dev));
        const inode: u64 = @intCast(info.st_ino);
        for (w.files.items) |entry| if (entry.device == device and entry.inode == inode and (access & ~entry.share != 0 or entry.access & ~@as(u3, @intCast(share)) != 0)) return w.fileFail(32);
        // Check sharing before truncation, so a rejected open cannot destroy file contents.
        if ((disposition == 2 or disposition == 5) and host.c.ftruncate(fd, 0) != 0) return w.fileFail(hostError());
        const handle = w.next_handle;
        w.next_handle += 1;
        w.files.appendAssumeCapacity(.{ .handle = handle, .fd = fd, .access = access, .share = @intCast(share), .device = device, .inode = inode });
        keep = true;
        if (disposition == 2 or disposition == 4) w.last_error = if (created) 0 else 183;
        return handle;
    }
    fn fileIO(w: *Windows, s: *State, m: *Memory, read_file: bool) !u64 {
        const out = s.get(9);
        if (out == 0) return w.fail(87);
        try m.writeInt(out, 32, 0);
        const handle = s.get(1);
        var fd: c_int = undefined;
        if (handle >= 0x100 and handle <= 0x102) {
            const index: usize = @intCast(handle - 0x100);
            if (w.closed_standard[index]) return w.fail(6);
            if ((read_file and index != 0) or (!read_file and index == 0)) return w.fail(5);
            fd = @intCast(index);
        } else {
            const entry = w.file(handle) orelse return w.fail(6);
            if (entry.access & @as(u2, if (read_file) 1 else 2) == 0) return w.fail(5);
            fd = entry.fd;
        }
        const count = s.get(8) & 0xffffffff;
        if (count > 1024 * 1024) return w.fail(87);
        if (try stackArg(s, m, 4) != 0) return w.fail(50);
        const buffer = s.get(2);
        try m.check(buffer, @intCast(count), if (read_file) .write else .read);
        const bytes = try w.allocator.alloc(u8, @intCast(count));
        defer w.allocator.free(bytes);
        if (!read_file) try m.read(buffer, bytes, .read);
        var n: isize = undefined;
        while (true) {
            n = if (read_file) host.c.read(fd, bytes.ptr, bytes.len) else host.c.write(fd, bytes.ptr, bytes.len);
            if (n >= 0 or host.errno() != host.c.EINTR) break;
        }
        if (n < 0) return w.fail(hostError());
        if (read_file) try m.write(buffer, bytes[0..@intCast(n)]);
        try m.writeInt(out, 32, @intCast(n));
        return 1;
    }
    fn perform(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        const a = s.get(1);
        const b = s.get(2);
        const count = s.get(8) & 0xffffffff;
        const out = s.get(9);
        switch (api) {
            .ExitProcess => {
                w.exit_code = @truncate(a);
                return 0;
            },
            .GetStdHandle => return switch (@as(u32, @truncate(a))) {
                0xfffffff6 => 0x100,
                0xfffffff5 => 0x101,
                0xfffffff4 => 0x102,
                else => blk: {
                    w.last_error = 87;
                    break :blk std.math.maxInt(u64);
                },
            },
            .GetLastError => return w.last_error,
            .SetLastError => {
                w.last_error = @truncate(a);
                return 0;
            },
            .GetCommandLineA => return w.command_line_a,
            .GetCommandLineW => return w.command_line_w,
            .GetACP => return 65001,
            .GetProcessHeap => return process_heap,
            .HeapAlloc, .HeapReAlloc, .HeapFree, .HeapSize => return w.heap(s, m, api),
            .GetModuleHandleA, .GetModuleHandleW => {
                if (a != 0) return w.fail(126);
                return w.module_base;
            },
            .WriteFile, .ReadFile => return w.fileIO(s, m, api == .ReadFile),
            .CreateFileA, .CreateFileW => return w.openFile(s, m, api == .CreateFileW),
            .CloseHandle => {
                if (a >= 0x100 and a <= 0x102) {
                    const index: usize = @intCast(a - 0x100);
                    if (w.closed_standard[index]) return w.fail(6);
                    w.closed_standard[index] = true;
                    return 1;
                }
                for (w.files.items, 0..) |entry, index| if (entry.handle == a) {
                    const result = host.c.close(entry.fd);
                    _ = w.files.swapRemove(index);
                    if (result != 0) return w.fail(hostError());
                    return 1;
                };
                return w.fail(6);
            },
            .GetFileSizeEx => {
                const entry = w.file(a) orelse return w.fail(6);
                try m.check(b, 8, .write);
                var info: host.c.struct_stat = undefined;
                if (host.c.fstat(entry.fd, &info) != 0) return w.fail(hostError());
                try m.writeInt(b, 64, @intCast(info.st_size));
                return 1;
            },
            .SetFilePointerEx => {
                const entry = w.file(a) orelse return w.fail(6);
                const result_ptr = s.get(8);
                if (result_ptr != 0) try m.check(result_ptr, 8, .write);
                const origin = out & 0xffffffff;
                if (origin > 2) return w.fail(87);
                const position = host.c.lseek(entry.fd, @bitCast(b), @intCast(origin));
                if (position < 0) return w.fail(if (host.errno() == host.c.EINVAL) 131 else hostError());
                if (result_ptr != 0) try m.writeInt(result_ptr, 64, @intCast(position));
                return 1;
            },
            .FlushFileBuffers => {
                const entry = w.file(a) orelse return w.fail(6);
                if (entry.access & 2 == 0) return w.fail(5);
                if (host.c.fsync(entry.fd) != 0) return w.fail(hostError());
                return 1;
            },
            .VirtualAlloc => {
                if (a != 0 or b == 0 or b > m.limit or count & ~@as(u64, 0x3000) != 0 or count == 0) return w.fail(87);
                const p = @import("../memory.zig").Permissions;
                const permissions: p = switch (out & 0xffffffff) {
                    1 => .{},
                    2 => .{ .read = true },
                    4 => .{ .read = true, .write = true },
                    0x10 => .{ .execute = true },
                    0x20 => .{ .read = true, .execute = true },
                    0x40 => .{ .read = true, .write = true, .execute = true },
                    else => return w.fail(87),
                };
                return w.allocate(m, b, permissions, false) catch w.fail(8);
            },
            .VirtualFree => {
                if (b != 0 or count != 0x8000) return w.fail(87);
                for (w.allocations.items, 0..) |allocation, index| if (!allocation.heap and allocation.address == a) {
                    try m.unmap(a, allocation.size);
                    _ = w.allocations.swapRemove(index);
                    return 1;
                };
                return w.fail(487);
            },
        }
    }
};
test "Windows standard handles and virtual memory lifecycle" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    var s = State{ .architecture = .x86_64 };
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x140000000 };
    defer w.deinit();
    s.set(1, 0xfffffff5);
    try std.testing.expectEqual(@as(u64, 0x101), try w.perform(&s, &m, .GetStdHandle));
    s.set(1, 0);
    s.set(2, 4096);
    s.set(8, 0x3000);
    s.set(9, 4);
    const address = try w.perform(&s, &m, .VirtualAlloc);
    try m.writeInt(address, 64, 123);
    const second = try w.perform(&s, &m, .VirtualAlloc);
    try std.testing.expect(second != address and second % 65536 == 0);
    s.set(1, second);
    s.set(2, 0);
    s.set(8, 0x8000);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .VirtualFree));
    s.set(1, address);
    s.set(2, 0);
    s.set(8, 0x8000);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .VirtualFree));
    try std.testing.expectError(error.UnmappedMemory, m.readInt(address, 8, .read));
}

test "process heap preserves data on failed growth and separates virtual allocations" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x140000000 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, process_heap);
    s.set(2, 8);
    s.set(8, 17);
    w.last_error = 123;
    const ptr = try w.perform(&s, &m, .HeapAlloc);
    try std.testing.expect(ptr != 0 and ptr % 16 == 0);
    try std.testing.expectEqual(@as(u32, 123), w.last_error);
    try m.writeInt(ptr, 64, 0x123456789abcdef0);
    s.set(8, ptr);
    s.set(9, 8193);
    m.limit = m.used;
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .HeapReAlloc));
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), try m.readInt(ptr, 64, .read));
    m.limit = 256 * 1024 * 1024;
    const grown = try w.perform(&s, &m, .HeapReAlloc);
    try std.testing.expect(grown != 0);
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), try m.readInt(grown, 64, .read));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(grown + 17, 64, .read));
    try std.testing.expectError(error.UnmappedMemory, m.readInt(ptr, 8, .read));
    s.set(2, 0);
    s.set(8, grown);
    try std.testing.expectEqual(@as(u64, 8193), try w.perform(&s, &m, .HeapSize));
    s.set(1, grown);
    s.set(8, 0x8000);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .VirtualFree));
    s.set(1, process_heap);
    s.set(8, grown);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .HeapFree));
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .HeapFree));
    try std.testing.expectEqual(invalid_handle, try w.perform(&s, &m, .HeapSize));
    s.set(1, 0);
    try std.testing.expectEqual(invalid_handle, try w.perform(&s, &m, .HeapSize));
    s.set(1, process_heap);
    s.set(2, 1);
    try std.testing.expectEqual(invalid_handle, try w.perform(&s, &m, .HeapSize));
}

test "Windows creation dispositions distinguish collisions, existing files and truncation" {
    var template = "/tmp/universe-create-XXXXXX".*;
    const fd = host.c.mkstemp(&template);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(isize, 3), host.c.write(fd, "abc", 3));
    _ = host.c.close(fd);
    defer _ = host.c.unlink(&template);
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.write(0x1100, &template);
    try m.writeInt(0x1030, 64, 0x80);
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x140000000, .allow_files = true };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(4, 0x1000);
    s.set(1, 0x1100);
    s.set(2, 0xc0000000);
    s.set(8, 3);
    try m.writeInt(0x1028, 64, 1);
    try std.testing.expectEqual(invalid_handle, try w.perform(&s, &m, .CreateFileA));
    try std.testing.expectEqual(@as(u32, 80), w.last_error);
    try m.writeInt(0x1028, 64, 4);
    const existing = try w.perform(&s, &m, .CreateFileA);
    try std.testing.expect(existing != invalid_handle);
    try std.testing.expectEqual(@as(u32, 183), w.last_error);
    s.set(1, existing);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .CloseHandle));
    s.set(1, 0x1100);
    try m.writeInt(0x1028, 64, 5);
    const truncated = try w.perform(&s, &m, .CreateFileA);
    try std.testing.expect(truncated != invalid_handle);
    var info: host.c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), host.c.fstat(w.file(truncated).?.fd, &info));
    try std.testing.expectEqual(@as(host.c.off_t, 0), info.st_size);
    s.set(1, truncated);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .CloseHandle));
    try std.testing.expectEqual(@as(c_int, 0), host.c.unlink(&template));
    s.set(1, 0x1100);
    try m.writeInt(0x1028, 64, 3);
    try std.testing.expectEqual(invalid_handle, try w.perform(&s, &m, .CreateFileA));
    try std.testing.expectEqual(@as(u32, 2), w.last_error);
    try m.writeInt(0x1028, 64, 4);
    const created = try w.perform(&s, &m, .CreateFileA);
    try std.testing.expect(created != invalid_handle);
    try std.testing.expectEqual(@as(u32, 0), w.last_error);
}

test "Windows file I/O validates output pointers before changing host data or offsets" {
    var template = "/tmp/universe-windows-XXXXXX".*;
    const fd = host.c.mkstemp(&template);
    try std.testing.expect(fd >= 0);
    defer _ = host.c.unlink(&template);
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x140000000 };
    defer w.deinit();
    try w.files.append(w.allocator, .{ .handle = 0x10000, .fd = fd, .access = 3, .share = 3, .device = 0, .inode = 0 });
    try std.testing.expectEqual(@as(isize, 3), host.c.write(fd, "abc", 3));
    try std.testing.expectEqual(@as(host.c.off_t, 0), host.c.lseek(fd, 0, host.c.SEEK_SET));
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var s = State{ .architecture = .x86_64 };
    s.set(4, 0x1000);
    s.set(1, 0x10000);
    s.set(2, 0x1100);
    s.set(8, 3);
    s.set(9, 0x3000);
    try std.testing.expectError(error.UnmappedMemory, w.perform(&s, &m, .ReadFile));
    try std.testing.expectEqual(@as(host.c.off_t, 0), host.c.lseek(fd, 0, host.c.SEEK_CUR));
    try m.write(0x1100, "xyz");
    try std.testing.expectError(error.UnmappedMemory, w.perform(&s, &m, .WriteFile));
    s.set(9, 0x1200);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .ReadFile));
    var bytes: [3]u8 = undefined;
    try m.read(0x1100, &bytes, .read);
    try std.testing.expectEqualStrings("abc", &bytes);
    try std.testing.expectEqual(@as(u64, 3), try m.readInt(0x1200, 32, .read));
}
