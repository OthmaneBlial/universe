const std = @import("std");
const host = @import("../host.zig");
const Memory = @import("../memory.zig").Memory;
const State = @import("../cpu/state.zig").State;
const PE = @import("../loader/pe.zig").Image;
const Linker = @import("../loader/pe_linker.zig").Linker;
const Operation = struct { kind: enum { startup, load, unload, rollback }, mask: u64, saved: ?Linker.Checkpoint = null, api: ?Api = null };
const Callback = struct { operation: Operation, restore: State, queue: [64]usize = undefined, length: usize = 0, index: usize = 0, sp: u64 = 0 };
const Api = enum { ExitProcess, GetStdHandle, WriteFile, ReadFile, VirtualAlloc, VirtualFree, GetModuleHandleA, GetModuleHandleW, GetLastError, SetLastError, GetCommandLineA, GetCommandLineW, GetACP, GetProcessHeap, HeapAlloc, HeapReAlloc, HeapFree, HeapSize, CreateFileA, CreateFileW, CloseHandle, GetFileSizeEx, SetFilePointerEx, FlushFileBuffers, GetProcAddress, LoadLibraryA, LoadLibraryW, FreeLibrary };
pub const stub_base: u64 = 0x700000000000;
const initializer_return: u64 = stub_base + 0xff0;
pub fn apiAddress(name: []const u8) ?u64 {
    const api = std.meta.stringToEnum(Api, name) orelse return null;
    return stub_base + @as(u64, @intFromEnum(api)) * 16;
}
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
    linker: ?Linker = null,
    callback: ?Callback = null,
    pending: ?Operation = null,
    pub fn deinit(w: *Windows) void {
        if (w.linker) |*l| l.deinit();
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
    fn moduleError(w: *Windows, err: anyerror) !u64 {
        return switch (err) {
            error.WindowsDLLNotFound, error.MissingSysroot => w.fail(126),
            error.CannotOpenBinary => w.fail(126),
            error.BinaryFileLimit => w.fail(4),
            error.CannotReadBinary => w.fail(1117),
            error.BinaryTooLarge, error.UnsupportedBinaryFile => w.fail(193),
            error.FileAccessDenied, error.BinaryAccessDenied => w.fail(5),
            error.UnsupportedWindowsModulePath => w.fail(123),
            error.WindowsExportNotFound, error.UnsupportedWindowsImport, error.OrdinalImportsUnsupported, error.LateWindowsDependencyUnsupported => w.fail(127),
            error.OutOfMemory, error.MemoryLimit, error.WindowsModuleLimit => w.fail(8),
            error.PETLSUnsupported, error.PEDelayImportsUnsupported => w.fail(50),
            error.NotPE, error.TruncatedBinary, error.InvalidPEHeader, error.PE32Unsupported, error.InvalidPEDirectories, error.UnsupportedPEAlignment, error.InvalidPEImageSize, error.InvalidPESection, error.OverlappingPESections, error.InvalidEntryPoint, error.UnsupportedArchitecture, error.ExpectedWindowsDLL, error.PERelocationsMissing, error.InvalidPERelocations, error.UnsupportedPERelocation, error.InvalidPERva, error.InvalidWindowsRva, error.InvalidWindowsExport, error.InvalidWindowsImport, error.UnterminatedWindowsImports, error.InvalidWindowsForwarder, error.WindowsForwarderCycle => w.fail(193),
            else => return err,
        };
    }
    fn loadLibrary(w: *Windows, s: *State, m: *Memory, wide: bool) !u64 {
        if (w.callback != null) return w.fail(1114);
        if (s.get(1) == 0) return w.fail(87);
        const raw = if (wide) try @import("../windows_process.zig").wideString(w.allocator, m, s.get(1)) else try m.cstring(w.allocator, s.get(1), 4096);
        defer w.allocator.free(raw);
        if (raw.len == 0) return w.fail(123);
        const name = if (raw[raw.len - 1] == '.') try w.allocator.dupe(u8, raw[0 .. raw.len - 1]) else if (std.mem.findScalar(u8, raw, '.') == null) try std.fmt.allocPrint(w.allocator, "{s}.dll", .{raw}) else try w.allocator.dupe(u8, raw);
        defer w.allocator.free(name);
        if (@import("../loader/pe_linker.zig").kernel(name)) return stub_base;
        const l = &w.linker.?;
        const saved = l.checkpoint();
        const index = l.load(m, name) catch |err| {
            try l.rollback(m, saved);
            return w.moduleError(err);
        };
        if (l.modules.items[index].references == std.math.maxInt(u32)) return w.fail(8);
        l.modules.items[index].references += 1;
        const mask = l.active() & ~saved.active;
        if (mask != 0) w.pending = .{ .kind = .load, .mask = mask, .saved = saved, .api = if (wide) .LoadLibraryW else .LoadLibraryA };
        return l.modules.items[index].base;
    }
    fn heapFail(w: *Windows, api: Api, code: u32) u64 {
        _ = w.fail(code);
        return if (api == .HeapSize) invalid_handle else 0;
    }
    pub fn bind(w: *Windows, image: PE, m: *Memory, name: []const u8) !void {
        try m.map(stub_base, 4096, .{ .read = true, .execute = true });
        try m.initialize(stub_base, &@as([4096]u8, @splat(0xcc)));
        w.linker = .{ .allocator = w.allocator, .sysroot = w.sysroot, .allow_files = w.allow_files };
        try w.linker.?.addMain(m, image, name);
    }
    pub fn beginInitialization(w: *Windows, s: *State, m: *Memory) !void {
        try w.beginCallback(s, m, .{ .kind = .startup, .mask = w.linker.?.active() });
    }
    fn beginCallback(w: *Windows, s: *State, m: *Memory, operation: Operation) !void {
        if (w.callback != null) return error.WindowsLoaderReentrancyUnsupported;
        const l = &w.linker.?;
        var callback = Callback{ .operation = operation, .restore = s.* };
        const attach = operation.kind == .startup or operation.kind == .load;
        if (attach) {
            for (l.initializers.items) |index| {
                if (operation.mask & Linker.bit(index) == 0 or l.modules.items[index].attached) continue;
                callback.queue[callback.length] = index;
                callback.length += 1;
            }
        } else {
            var order: [64]usize = undefined;
            const length = l.detachOrder(operation.mask, &order);
            for (order[0..length]) |index| if (l.modules.items[index].attach_called) {
                callback.queue[callback.length] = index;
                callback.length += 1;
            };
        }
        w.callback = callback;
        try w.nextCallback(s, m);
    }
    fn nextCallback(w: *Windows, s: *State, m: *Memory) !void {
        const callback = &w.callback.?;
        const l = &w.linker.?;
        if (callback.index == callback.length) {
            const operation = callback.operation;
            w.callback = null;
            switch (operation.kind) {
                .unload => try l.remove(m, operation.mask),
                .rollback => {
                    try l.rollback(m, operation.saved.?);
                    _ = w.fail(1114);
                },
                .startup, .load => {},
            }
            if (w.trace) if (operation.api) |api| try host.print(2, "kernel32!{s} = 0x{x}\n", .{ @tagName(api), s.get(0) });
            return;
        }
        const module = &l.modules.items[callback.queue[callback.index]];
        const sp = std.mem.alignBackward(u64, std.math.sub(u64, callback.restore.get(4), 48) catch return error.AddressOverflow, 16) + 8;
        try m.check(sp, 40, .write);
        try m.writeInt(sp, 64, initializer_return);
        callback.sp = sp;
        const attach = callback.operation.kind == .startup or callback.operation.kind == .load;
        if (attach) module.attach_called = true;
        s.set(4, sp);
        s.set(1, module.base);
        s.set(2, @intFromBool(attach));
        s.set(8, @intFromBool(callback.operation.kind == .startup));
        s.set(9, 0);
        s.pc = module.entry;
        if (w.trace) try host.print(2, "DLL_PROCESS_{s}: {s} base=0x{x} entry=0x{x}\n", .{ if (attach) @as([]const u8, "ATTACH") else "DETACH", module.name, module.base, module.entry });
    }
    fn finishInitializer(w: *Windows, s: *State, m: *Memory) !void {
        const callback = if (w.callback) |*value| value else return error.InvalidWindowsInitializerReturn;
        if (s.get(4) != callback.sp + 8) return error.InvalidWindowsInitializerStack;
        const pass = s.get(0) & 0xffffffff != 0;
        const instructions = s.instructions + 1;
        s.* = callback.restore;
        s.instructions = instructions;
        const l = &w.linker.?;
        const module = &l.modules.items[callback.queue[callback.index]];
        const operation = callback.operation;
        if (operation.kind == .startup or operation.kind == .load) {
            if (!pass) {
                if (operation.kind == .startup) {
                    try host.print(2, "Windows DLL initialization failed: {s}\n", .{module.name});
                    return error.WindowsDLLInitializationFailed;
                }
                w.callback = null;
                s.set(0, w.fail(1114)); // ERROR_DLL_INIT_FAILED; detach attempted initializers before rollback.
                return w.beginCallback(s, m, .{ .kind = .rollback, .mask = operation.mask, .saved = operation.saved, .api = operation.api });
            }
            module.attached = true;
        }
        callback.index += 1;
        try w.nextCallback(s, m);
    }
    pub fn handles(pc: u64) bool {
        return pc == initializer_return or (pc >= stub_base and pc < stub_base + std.meta.fields(Api).len * 16 and (pc - stub_base) % 16 == 0);
    }
    pub fn dispatch(w: *Windows, s: *State, m: *Memory) !void {
        try m.check(s.pc, 1, .execute);
        if (s.pc == initializer_return) return w.finishInitializer(s, m);
        const api: Api = @enumFromInt((s.pc - stub_base) / 16);
        const result = try w.perform(s, m, api);
        s.set(0, result);
        w.calls += 1;
        if (w.trace and w.pending == null) try host.print(2, "kernel32!{s} = 0x{x}\n", .{ @tagName(api), result });
        if (w.exit_code == null) {
            const target = try m.readInt(s.get(4), 64, .read);
            s.set(4, s.get(4) +% 8);
            s.pc = target;
        }
        s.instructions += 1;
        if (w.pending) |operation| {
            w.pending = null;
            try w.beginCallback(s, m, operation);
        }
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
        const info = host.statFd(fd) catch return w.fileFail(hostError());
        if (!host.isRegular(info.mode)) return w.fileFail(50);
        const device = info.dev;
        const inode = info.ino;
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
            .LoadLibraryA, .LoadLibraryW => return w.loadLibrary(s, m, api == .LoadLibraryW),
            .FreeLibrary => {
                if (w.callback != null) return w.fail(1114);
                if (a == stub_base) return 1;
                const l = &w.linker.?;
                const index = l.handle(a) orelse return w.fail(6);
                if (l.modules.items[index].references == 0) return w.fail(6);
                l.modules.items[index].references -= 1;
                const mask = l.unreachableModules();
                if (mask != 0) w.pending = .{ .kind = .unload, .mask = mask, .api = .FreeLibrary };
                return 1;
            },
            .GetModuleHandleA, .GetModuleHandleW => {
                if (a == 0) return w.module_base;
                const name = if (api == .GetModuleHandleW) try @import("../windows_process.zig").wideString(w.allocator, m, a) else try m.cstring(w.allocator, a, 4096);
                defer w.allocator.free(name);
                const leaf = name[(if (std.mem.findLastAny(u8, name, "/\\")) |position| position + 1 else 0)..];
                if (@import("../loader/pe_linker.zig").kernel(leaf)) return stub_base;
                if (w.linker) |l| if (l.find(leaf)) |slot| return l.modules.items[slot].base;
                return w.fail(126);
            },
            .GetProcAddress => {
                var owned: ?[:0]u8 = null;
                defer if (owned) |name| w.allocator.free(name);
                const symbol: @import("../loader/pe_linker.zig").Symbol = if (b <= 0xffff) .{ .ordinal = @intCast(b) } else blk: {
                    owned = try m.cstring(w.allocator, b, 4096);
                    break :blk .{ .name = owned.? };
                };
                if (a == stub_base) return if (symbol == .name) apiAddress(symbol.name) orelse w.fail(127) else w.fail(127);
                if (w.linker) |*l| {
                    const index = l.handle(a) orelse return w.fail(6);
                    const saved = l.checkpoint();
                    const result = l.resolve(m, index, symbol, w.callback == null, 0) catch |err| {
                        try l.rollback(m, saved);
                        return w.moduleError(err);
                    };
                    const mask = l.active() & ~saved.active;
                    if (mask != 0) w.pending = .{ .kind = .load, .mask = mask, .saved = saved, .api = .GetProcAddress };
                    return result;
                }
                return w.fail(6);
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
                const info = host.statFd(entry.fd) catch return w.fail(hostError());
                try m.writeInt(b, 64, @intCast(info.size));
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
    const info = try host.statFd(w.file(truncated).?.fd);
    try std.testing.expectEqual(@as(i64, 0), info.size);
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

test "DLL initialization retains instruction limits, restores startup state and rejects failure" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x3000, 4096, .{ .read = true, .execute = true });
    try m.map(stub_base, 4096, .{ .execute = true });
    var w = Windows{ .allocator = a, .module_base = 0x5000, .linker = .{ .allocator = a } };
    defer w.deinit();
    for ([_][]const u8{ "first.dll", "second.dll" }, 0..) |name, index| {
        try w.linker.?.modules.append(a, .{ .name = try a.dupe(u8, name), .base = 0x3000, .size = 4096, .entry = 0x3100 + index * 16, .imports = .{ .rva = 0, .size = 0 }, .exports = .{ .rva = 0, .size = 0 } });
        try w.linker.?.initializers.append(a, index);
    }
    var s = State{ .architecture = .x86_64, .pc = 0x5000, .instructions = 7, .flags = .{ .carry = true } };
    s.set(4, 0x1ff8);
    s.set(0, 123);
    const original = s;
    try w.beginInitialization(&s, &m);
    try std.testing.expectEqual(@as(u64, 0x3100), s.pc);
    try std.testing.expectEqual(@as(u64, 8), s.get(4) % 16);
    try std.testing.expectEqual(@as(u64, 1), s.get(2));
    try std.testing.expectEqual(initializer_return, try m.readInt(s.get(4), 64, .read));
    s.set(4, s.get(4) + 8);
    s.set(0, 1);
    s.pc = initializer_return;
    s.instructions = 19;
    try w.dispatch(&s, &m);
    try std.testing.expectEqual(@as(u64, 0x3110), s.pc);
    try std.testing.expectEqual(@as(u64, 20), s.instructions);
    s.set(4, s.get(4) + 8);
    s.set(0, 1);
    s.pc = initializer_return;
    s.instructions = 30;
    try w.dispatch(&s, &m);
    try std.testing.expectEqual(original.pc, s.pc);
    try std.testing.expectEqualSlices(u64, &original.registers, &s.registers);
    try std.testing.expectEqual(original.flags.bits(), s.flags.bits());
    try std.testing.expectEqual(@as(u64, 31), s.instructions);
    try std.testing.expect(w.callback == null);
    for (w.linker.?.modules.items) |*module| module.attached = false;
    try w.beginInitialization(&s, &m);
    s.set(4, s.get(4) + 8);
    s.set(0, 0);
    s.pc = initializer_return;
    try std.testing.expectError(error.WindowsDLLInitializationFailed, w.dispatch(&s, &m));
}

test "Dynamic DLL failure detaches attempted callbacks, rolls back and restores caller state" {
    const a = std.testing.allocator;
    var memory = Memory.init(a);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true });
    try memory.map(stub_base, 4096, .{ .execute = true });
    var windows = Windows{ .allocator = a, .module_base = 0x5000, .linker = .{ .allocator = a } };
    defer windows.deinit();
    for ([_][]const u8{ "main.exe", "dependency.dll", "failed.dll" }, 0..) |name, index| {
        const base = 0x5000 + index * 0x1000;
        try memory.map(base, 4096, .{ .read = true, .execute = true });
        try windows.linker.?.modules.append(a, .{ .name = try a.dupe(u8, name), .base = base, .size = 4096, .entry = if (index == 0) 0 else base + 0x100, .imports = .{ .rva = 0, .size = 0 }, .exports = .{ .rva = 0, .size = 0 } });
        if (index != 0) try windows.linker.?.initializers.append(a, index);
    }
    const saved = Linker.Checkpoint{ .active = 1, .dependencies = @splat(0) };
    var state = State{ .architecture = .x86_64, .pc = 0x5100, .instructions = 7, .flags = .{ .carry = true } };
    state.set(4, 0x2000); // API caller stack is aligned differently from process startup.
    state.set(0, 0x7000);
    const original = state;
    try windows.beginCallback(&state, &memory, .{ .kind = .load, .mask = Linker.bit(1) | Linker.bit(2), .saved = saved });
    try std.testing.expectEqual(@as(u64, 0x6100), state.pc);
    try std.testing.expectEqual(@as(u64, 8), state.get(4) % 16);
    try std.testing.expectEqual(@as(u64, 0), state.get(8));
    try std.testing.expectEqual(@as(u64, 0), try windows.perform(&state, &memory, .LoadLibraryA));
    try std.testing.expectEqual(@as(u32, 1114), windows.last_error);
    try std.testing.expectEqual(@as(u64, 0), try windows.perform(&state, &memory, .FreeLibrary));
    state.set(4, state.get(4) + 8);
    state.set(0, 1);
    state.pc = initializer_return;
    state.instructions = 19;
    try windows.dispatch(&state, &memory);
    try std.testing.expectEqual(@as(u64, 0x7100), state.pc);
    state.set(4, state.get(4) + 8);
    state.set(0, 0);
    state.pc = initializer_return;
    state.instructions = 29;
    try windows.dispatch(&state, &memory);
    try std.testing.expectEqual(@as(u64, 0x7100), state.pc); // Failed DLL receives detach, then its dependency.
    for ([_]u64{ 0x7100, 0x6100 }) |pc| {
        try std.testing.expectEqual(pc, state.pc);
        try std.testing.expectEqual(@as(u64, 0), state.get(2));
        try std.testing.expectEqual(@as(u64, 0), state.get(8));
        state.set(4, state.get(4) + 8);
        state.set(0, 0); // Detach return values are ignored.
        state.pc = initializer_return;
        windows.last_error = 999; // DLL API calls must not replace the final loader failure.
        try windows.dispatch(&state, &memory);
    }
    try std.testing.expect(windows.callback == null);
    try std.testing.expectEqual(original.pc, state.pc);
    try std.testing.expectEqual(original.get(4), state.get(4));
    try std.testing.expectEqual(original.flags.bits(), state.flags.bits());
    try std.testing.expectEqual(@as(u64, 0), state.get(0));
    try std.testing.expectEqual(@as(u64, 32), state.instructions);
    try std.testing.expectEqual(@as(u32, 1114), windows.last_error);
    try std.testing.expectEqual(@as(u64, 1), windows.linker.?.active());
    try std.testing.expectEqual(@as(usize, 0), windows.linker.?.initializers.items.len);
    try std.testing.expect(memory.available(0x6000, 8192));
}
