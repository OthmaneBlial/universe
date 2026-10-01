const std = @import("std");
const host = @import("../host.zig");
const Memory = @import("../memory.zig").Memory;
const State = @import("../cpu/state.zig").State;
const PE = @import("../loader/pe.zig").Image;
const Linker = @import("../loader/pe_linker.zig").Linker;
const Operation = struct { kind: enum { startup, load, unload, rollback }, mask: u64, saved: ?Linker.Checkpoint = null, api: ?Api = null };
const Callback = struct { operation: Operation, restore: State, queue: [64]usize = undefined, length: usize = 0, index: usize = 0, sub_index: usize = 0, current_tls: bool = false, sp: u64 = 0 };
const Api = enum { ExitProcess, GetStdHandle, WriteFile, ReadFile, VirtualAlloc, VirtualFree, GetModuleHandleA, GetModuleHandleW, GetLastError, SetLastError, GetCommandLineA, GetCommandLineW, GetACP, GetProcessHeap, HeapAlloc, HeapReAlloc, HeapFree, HeapSize, CreateFileA, CreateFileW, CloseHandle, GetFileSizeEx, SetFilePointerEx, FlushFileBuffers, GetProcAddress, LoadLibraryA, LoadLibraryW, FreeLibrary, TlsAlloc, TlsFree, TlsGetValue, TlsSetValue, SysAllocString, SysAllocStringLen, SysFreeString, SysStringLen, VariantInit, VariantClear, VariantCopy, CharUpperW, CharPrevExA, GetCurrentProcess, OpenProcessToken, SystemFunction036, GetFileSecurityW, SetFileSecurityW, RegOpenKeyExW, AdjustTokenPrivileges, LookupPrivilegeValueW, RegQueryValueExW, RegCloseKey };
pub const stub_base: u64 = 0x700000000000;
const initializer_return: u64 = stub_base + 0xff0;
const last_error_offset: u64 = 0x68;
const tls_slots_offset: u64 = 0x1480;
const tls_slots_count: u32 = 64;
pub fn apiAddress(name: []const u8) ?u64 {
    const api = std.meta.stringToEnum(Api, name) orelse return null;
    return stub_base + @as(u64, @intFromEnum(api)) * 16;
}
pub const Builtin = enum {
    kernel32,
    oleaut32,
    user32,
    advapi32,
    pub fn find(name: []const u8) ?Builtin {
        if (std.ascii.eqlIgnoreCase(name, "kernel32.dll") or std.ascii.eqlIgnoreCase(name, "kernelbase.dll")) return .kernel32;
        if (std.ascii.eqlIgnoreCase(name, "oleaut32.dll")) return .oleaut32;
        if (std.ascii.eqlIgnoreCase(name, "user32.dll")) return .user32;
        if (std.ascii.eqlIgnoreCase(name, "advapi32.dll")) return .advapi32;
        return null;
    }
    pub fn handle(dll: Builtin) u64 {
        return stub_base + @as(u64, @intFromEnum(dll)) * 4096;
    }
    fn fromHandle(value: u64) ?Builtin {
        for (std.enums.values(Builtin)) |dll| if (value == dll.handle()) return dll;
        return null;
    }
    pub fn symbol(dll: Builtin, value: @import("../loader/pe_linker.zig").Symbol) ?u64 {
        const api: Api = switch (value) {
            .name => |name| std.meta.stringToEnum(Api, name) orelse return null,
            .ordinal => |ordinal| if (dll == .oleaut32) switch (ordinal) {
                2 => .SysAllocString,
                4 => .SysAllocStringLen,
                6 => .SysFreeString,
                7 => .SysStringLen,
                8 => .VariantInit,
                9 => .VariantClear,
                10 => .VariantCopy,
                else => return null,
            } else return null,
        };
        if (apiLibrary(api) != dll) return null;
        return apiAddress(@tagName(api));
    }
};
fn apiLibrary(api: Api) Builtin {
    return switch (api) {
        .SysAllocString, .SysAllocStringLen, .SysFreeString, .SysStringLen, .VariantInit, .VariantClear, .VariantCopy => .oleaut32,
        .CharUpperW, .CharPrevExA => .user32,
        .OpenProcessToken, .SystemFunction036, .GetFileSecurityW, .SetFileSecurityW, .RegOpenKeyExW, .AdjustTokenPrivileges, .LookupPrivilegeValueW, .RegQueryValueExW, .RegCloseKey => .advapi32,
        else => .kernel32,
    };
}
const AllocationKind = enum { virtual, heap, bstr };
const Allocation = struct { address: u64, size: usize, requested: usize = 0, kind: AllocationKind = .virtual };
const File = struct { handle: u64, fd: c_int, access: u2, share: u3, device: u64, inode: u64 };
const invalid_handle = std.math.maxInt(u64);
const process_heap: u64 = 0x103;
const Token = struct { handle: u64, access: u32 };
// Winnt.h privilege names; LUIDs are local identifiers, not host privileges.
const privileges = [_][]const u8{
    "SeCreateTokenPrivilege",          "SeAssignPrimaryTokenPrivilege",   "SeLockMemoryPrivilege",
    "SeIncreaseQuotaPrivilege",        "SeUnsolicitedInputPrivilege",     "SeMachineAccountPrivilege",
    "SeTcbPrivilege",                  "SeSecurityPrivilege",             "SeTakeOwnershipPrivilege",
    "SeLoadDriverPrivilege",           "SeSystemProfilePrivilege",        "SeSystemtimePrivilege",
    "SeProfileSingleProcessPrivilege", "SeIncreaseBasePriorityPrivilege", "SeCreatePagefilePrivilege",
    "SeCreatePermanentPrivilege",      "SeBackupPrivilege",               "SeRestorePrivilege",
    "SeShutdownPrivilege",             "SeDebugPrivilege",                "SeAuditPrivilege",
    "SeSystemEnvironmentPrivilege",    "SeChangeNotifyPrivilege",         "SeRemoteShutdownPrivilege",
    "SeUndockPrivilege",               "SeSyncAgentPrivilege",            "SeEnableDelegationPrivilege",
    "SeManageVolumePrivilege",         "SeImpersonatePrivilege",          "SeCreateGlobalPrivilege",
    "SeTrustedCredManAccessPrivilege", "SeRelabelPrivilege",              "SeIncreaseWorkingSetPrivilege",
    "SeTimeZonePrivilege",             "SeCreateSymbolicLinkPrivilege",   "SeDelegateSessionUserImpersonatePrivilege",
};
fn registryStatus(handle: u64) u32 {
    return switch (handle) {
        0xffffffff80000000, 0xffffffff80000001, 0xffffffff80000002, 0xffffffff80000003, 0xffffffff80000005 => 0,
        0xffffffff80000004, 0xffffffff80000006, 0xffffffff80000007, 0xffffffff80000050, 0xffffffff80000060 => 50,
        else => 6,
    };
}
fn upperString(m: *Memory, argument: u64) !u64 {
    const upper = @import("../windows_upper.zig").upper;
    if (argument <= 0xffff) return upper(@intCast(argument));
    var bytes: usize = 0;
    while (bytes < m.limit) : (bytes += 2) {
        const ptr = std.math.add(u64, argument, bytes) catch return error.AddressOverflow;
        if (try m.readInt(ptr, 16, .read) == 0) {
            try m.check(argument, bytes, .write); // Validate the complete destination before mutation.
            var offset: usize = 0;
            while (offset < bytes) : (offset += 2) {
                const value: u16 = @intCast(try m.readInt(argument + offset, 16, .read));
                try m.writeInt(argument + offset, 16, upper(value));
            }
            return argument;
        }
    }
    return error.UnterminatedWindowsString;
}
fn dbcsLead(code_page: u16, byte: u8) bool {
    // Windows lead-byte metadata; trail-byte validity is deliberately not decoded.
    return switch (code_page) {
        932 => (byte >= 0x81 and byte <= 0x9f) or (byte >= 0xe0 and byte <= 0xfc),
        936, 949, 950 => byte >= 0x81 and byte <= 0xfe,
        1361 => (byte >= 0x84 and byte <= 0xd3) or (byte >= 0xd8 and byte <= 0xde) or (byte >= 0xe0 and byte <= 0xf9),
        else => false, // ACP is UTF-8; UTF-8/GB18030 have no DBCS lead-byte ranges.
    };
}
fn previousCharacter(m: *Memory, code_page: u16, start: u64, current: u64) !u64 {
    if (current <= start) return current;
    if (current - start > m.limit) return error.InvalidWindowsStringCursor;
    var ptr = start;
    var previous = start;
    while (ptr < current) {
        const byte: u8 = @intCast(try m.readInt(ptr, 8, .read));
        if (byte == 0) return error.InvalidWindowsStringCursor;
        previous = ptr;
        if (dbcsLead(code_page, byte) and current - ptr > 1 and try m.readInt(ptr + 1, 8, .read) != 0) ptr += 2 else ptr += 1;
    }
    return previous;
}
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
    // ponytail: 64 live token handles; grow the table if real applications need more.
    tokens: [64]?Token = @splat(null),
    closed_standard: [3]bool = @splat(false),
    linker: ?Linker = null,
    callback: ?Callback = null,
    pending: ?Operation = null,
    teb_address: u64 = 0,
    tls_vector: u64 = 0,
    tls_allocated: u64 = 0,
    pub fn deinit(w: *Windows) void {
        if (w.linker) |*l| l.deinit();
        for (w.files.items) |entry| _ = host.c.close(entry.fd);
        w.files.deinit(w.allocator);
        w.allocations.deinit(w.allocator);
    }
    pub fn initProcess(w: *Windows, m: *Memory, args: []const [:0]const u8) !void {
        w.teb_address = try m.findFree(0x5f0000000000, 8192);
        w.tls_vector = w.teb_address + 4096;
        try m.map(w.teb_address, 8192, .{ .read = true, .write = true });
        try m.writeInt(w.teb_address + 0x30, 64, w.teb_address);
        try m.writeInt(w.teb_address + 0x40, 64, 1);
        try m.writeInt(w.teb_address + 0x48, 64, 1);
        try m.writeInt(w.teb_address + 0x58, 64, w.tls_vector);
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
    fn tlsAddress(m: *Memory, size: usize) !u64 {
        var address: u64 = 0x5f0100000000;
        while (true) {
            if (m.available(address, size)) return address;
            address = std.math.add(u64, address, 65536) catch return error.MemoryLimit;
            if (address >= 0x800000000000) return error.MemoryLimit;
        }
    }
    fn installTls(w: *Windows, m: *Memory, mask: u64) !void {
        const l = &w.linker.?;
        for (l.modules.items, 0..) |*module, index| {
            if (!module.active or mask & Linker.bit(index) == 0 or module.tls == null or module.tls.?.block != null) continue;
            const tls = &module.tls.?;
            const contents = std.math.add(usize, tls.template_size, tls.zero_fill) catch return error.MemoryLimit;
            const size = std.mem.alignForward(usize, @max(contents, 1), Memory.page_size);
            const address = try tlsAddress(m, size);
            try m.map(address, size, .{ .read = true, .write = true });
            errdefer m.unmap(address, size) catch unreachable;
            var offset: usize = 0;
            var bytes: [4096]u8 = undefined;
            while (offset < tls.template_size) {
                const amount = @min(bytes.len, tls.template_size - offset);
                try m.read(tls.template_address + @as(u64, @intCast(offset)), bytes[0..amount], .read);
                try m.write(address + offset, bytes[0..amount]);
                offset += amount;
            }
            try m.writeInt(tls.index_address, 32, @intCast(index));
            try m.writeInt(w.tls_vector + @as(u64, @intCast(index * 8)), 64, address);
            tls.block = .{ .address = address, .size = size };
        }
    }
    fn clearTls(w: *Windows, m: *Memory, mask: u64) !void {
        const l = &w.linker.?;
        for (l.modules.items, 0..) |*module, index| if (mask & Linker.bit(index) != 0) {
            if (module.tls) |*tls| if (tls.block) |block| {
                try m.writeInt(w.tls_vector + @as(u64, @intCast(index * 8)), 64, 0);
                try m.unmap(block.address, block.size);
                tls.block = null;
            };
        };
    }
    fn allocate(w: *Windows, m: *Memory, requested: u64, permissions: @import("../memory.zig").Permissions, kind: AllocationKind) !u64 {
        if (requested > m.limit) return error.MemoryLimit;
        const size = std.mem.alignForward(usize, @intCast(@max(requested, 1)), 4096);
        try w.allocations.ensureUnusedCapacity(w.allocator, 1);
        const addr = try m.findFree(w.next_map, size);
        try m.map(addr, size, permissions);
        w.allocations.appendAssumeCapacity(.{ .address = addr, .size = size, .requested = @intCast(requested), .kind = kind });
        w.next_map = std.mem.alignForward(u64, addr + size, 65536);
        return addr;
    }
    fn heap(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        if (s.get(1) != process_heap) return w.heapFail(api, 6);
        const flags = s.get(2) & 0xffffffff;
        const allowed: u64 = if (api == .HeapAlloc) 8 else if (api == .HeapReAlloc) 8 | 16 else 0;
        if (flags & ~allowed != 0) return w.heapFail(api, 87);
        // ponytail: one mapping per heap block; suballocate when small-allocation volume matters.
        if (api == .HeapAlloc) return w.allocate(m, s.get(8), .{ .read = true, .write = true }, .heap) catch 0;
        const ptr = s.get(8);
        for (w.allocations.items, 0..) |old, index| if (old.kind == .heap and old.address == ptr) {
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
            const next = w.allocate(m, requested, .{ .read = true, .write = true }, .heap) catch return 0;
            try m.write(next, bytes);
            try m.unmap(ptr, old.size);
            _ = w.allocations.swapRemove(index);
            return next;
        };
        return w.heapFail(api, 87);
    }
    fn allocBstr(w: *Windows, m: *Memory, source: u64, bytes: u64) !u64 {
        if (bytes > std.math.maxInt(u32) or bytes + 10 > m.limit) return 0;
        if (source != 0) try m.check(source, @intCast(bytes), .read);
        // ponytail: reuse one mapping per allocation; suballocate BSTRs if volume reaches the region limit.
        const base = w.allocate(m, bytes + 10, .{ .read = true, .write = true }, .bstr) catch |err| switch (err) {
            error.OutOfMemory, error.MemoryLimit => return 0,
            else => return err,
        };
        errdefer w.freeBstr(m, base + 8) catch {};
        try m.writeInt(base + 4, 32, bytes);
        // Raw code units, including embedded NULs and unpaired surrogates; no text conversion.
        if (source != 0) {
            var buffer: [4096]u8 = undefined;
            var offset: usize = 0;
            while (offset < bytes) {
                const amount = @min(buffer.len, bytes - offset);
                try m.read(source + offset, buffer[0..amount], .read);
                try m.write(base + 8 + offset, buffer[0..amount]);
                offset += amount;
            }
        }
        return base + 8; // Four-byte byte count immediately before the aligned BSTR pointer.
    }
    fn freeBstr(w: *Windows, m: *Memory, ptr: u64) !void {
        if (ptr == 0) return;
        for (w.allocations.items, 0..) |allocation, index| if (allocation.kind == .bstr and allocation.address + 8 == ptr) {
            try m.unmap(allocation.address, allocation.size);
            _ = w.allocations.swapRemove(index);
            return;
        };
        return error.InvalidWindowsBstr;
    }
    fn bstrBytes(m: *Memory, ptr: u64) !u64 {
        if (ptr == 0) return 0;
        return m.readInt(std.math.sub(u64, ptr, 4) catch return error.AddressOverflow, 32, .read);
    }
    fn variantStatus(vt: u16) u32 {
        const base = vt & 0xfff;
        const flags = vt & 0xf000;
        if (flags & ~@as(u16, 0x6000) != 0) return 0x80020008; // DISP_E_BADVARTYPE
        switch (base) {
            0, 1 => return if (flags == 0) 0 else 0x80020008,
            2...11, 13, 14, 16...23 => {},
            12 => if (flags == 0) return 0x80020008, // VT_VARIANT is indirect or an array element.
            36 => return 0x80004001, // VT_RECORD needs IRecordInfo callbacks.
            else => return 0x80020008,
        }
        if (flags & 0x4000 != 0) return 0; // Borrowed pointers: neither dereference nor release them.
        if (flags & 0x2000 != 0 or base == 9 or base == 13) return 0x80004001; // E_NOTIMPL: SAFEARRAY / owning COM pointers.
        return 0;
    }
    fn clearVariant(w: *Windows, m: *Memory, ptr: u64) !u64 {
        if (ptr == 0) return 0x80070057; // E_INVALIDARG
        try m.check(ptr, 24, .read);
        try m.check(ptr, 24, .write);
        const vt: u16 = @intCast(try m.readInt(ptr, 16, .read));
        const status = variantStatus(vt);
        if (status != 0) return status;
        if (vt == 8) try w.freeBstr(m, try m.readInt(ptr + 8, 64, .read));
        try m.writeInt(ptr, 16, 0); // VariantClear promises VT_EMPTY, not zeroed union storage.
        return 0;
    }
    fn copyVariant(w: *Windows, m: *Memory, dest: u64, source: u64) !u64 {
        if (dest == 0 or source == 0) return 0x80070057;
        var bytes: [24]u8 = undefined; // Windows x64 VARIANT includes two pointers in its record union.
        try m.read(source, &bytes, .read);
        try m.check(dest, bytes.len, .read);
        try m.check(dest, bytes.len, .write);
        const vt = std.mem.readInt(u16, bytes[0..2], .little);
        const status = variantStatus(vt);
        if (status != 0) return status;
        if (dest == source) return 0;
        if (dest < source + bytes.len and source < dest + bytes.len) return 0x80070057;
        const ptr = std.mem.readInt(u64, bytes[8..16], .little);
        const length = if (vt == 8) try bstrBytes(m, ptr) else 0;
        if (vt == 8 and ptr != 0) {
            try m.check(ptr, @intCast(length), .read);
            // Two owning variants cannot share the same BSTR. Reject before freeing the source.
            if (try m.readInt(dest, 16, .read) == 8 and try m.readInt(dest + 8, 64, .read) == ptr) return 0x80070057;
        }
        const cleared = try w.clearVariant(m, dest);
        if (cleared != 0) return cleared;
        var clone: u64 = 0;
        if (vt == 8 and ptr != 0) {
            clone = try w.allocBstr(m, ptr, length);
            if (clone == 0) return 0x8007000e; // E_OUTOFMEMORY; destination has already been cleared.
            std.mem.writeInt(u64, bytes[8..16], clone, .little);
        }
        errdefer if (clone != 0) w.freeBstr(m, clone) catch {};
        try m.write(dest, &bytes);
        return 0;
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
            error.PEDelayImportsUnsupported => w.fail(50),
            error.NotPE, error.TruncatedBinary, error.InvalidPEHeader, error.PE32Unsupported, error.InvalidPEDirectories, error.InvalidPETLS, error.UnsupportedPEAlignment, error.InvalidPEImageSize, error.InvalidPESection, error.OverlappingPESections, error.InvalidEntryPoint, error.UnsupportedArchitecture, error.ExpectedWindowsDLL, error.PERelocationsMissing, error.InvalidPERelocations, error.UnsupportedPERelocation, error.InvalidPERva, error.InvalidWindowsRva, error.InvalidWindowsExport, error.InvalidWindowsImport, error.UnterminatedWindowsImports, error.InvalidWindowsForwarder, error.WindowsForwarderCycle => w.fail(193),
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
        if (Builtin.find(name)) |dll| return dll.handle();
        const l = &w.linker.?;
        const saved = l.checkpoint();
        const index = l.load(m, name) catch |err| {
            try l.rollback(m, saved);
            return w.moduleError(err);
        };
        const mask = l.active() & ~saved.active;
        w.installTls(m, mask) catch |err| {
            try w.clearTls(m, mask);
            try l.rollback(m, saved);
            return w.moduleError(err);
        };
        if (l.modules.items[index].references == std.math.maxInt(u32)) return w.fail(8);
        l.modules.items[index].references += 1;
        if (mask != 0) w.pending = .{ .kind = .load, .mask = mask, .saved = saved, .api = if (wide) .LoadLibraryW else .LoadLibraryA };
        return l.modules.items[index].base;
    }
    fn heapFail(w: *Windows, api: Api, code: u32) u64 {
        _ = w.fail(code);
        return if (api == .HeapSize) invalid_handle else 0;
    }
    pub fn bind(w: *Windows, image: PE, m: *Memory, name: []const u8) !void {
        const size = std.meta.fields(Builtin).len * 4096;
        try m.map(stub_base, size, .{ .read = true, .execute = true });
        try m.initialize(stub_base, &@as([size]u8, @splat(0xcc)));
        w.linker = .{ .allocator = w.allocator, .sysroot = w.sysroot, .allow_files = w.allow_files, .trace = w.trace };
        try w.linker.?.addMain(m, image, name);
    }
    pub fn beginInitialization(w: *Windows, s: *State, m: *Memory) !void {
        try w.installTls(m, w.linker.?.active());
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
                .unload => {
                    try w.clearTls(m, operation.mask);
                    try l.remove(m, operation.mask);
                },
                .rollback => {
                    try w.clearTls(m, operation.mask);
                    try l.rollback(m, operation.saved.?);
                    _ = w.fail(1114);
                },
                .startup, .load => {},
            }
            if (w.trace) if (operation.api) |api| try host.print(2, "{s}!{s} = 0x{x}\n", .{ @tagName(apiLibrary(api)), @tagName(api), s.get(0) });
            return;
        }
        const attach = callback.operation.kind == .startup or callback.operation.kind == .load;
        var address: ?u64 = null;
        while (callback.index < callback.length and address == null) {
            const module = &l.modules.items[callback.queue[callback.index]];
            const tls_count = if (module.tls) |tls| tls.callback_count else 0;
            var is_tls = false;
            if (attach) {
                if (callback.sub_index < tls_count) {
                    address = module.tls.?.callbacks[callback.sub_index];
                    callback.sub_index += 1;
                    is_tls = true;
                } else if (callback.sub_index == tls_count) {
                    callback.sub_index += 1;
                    if (module.entry != 0) address = module.entry else module.attached = true;
                }
            } else {
                if (callback.sub_index == 0) {
                    callback.sub_index = 1;
                    if (module.entry != 0) address = module.entry;
                }
                if (address == null and callback.sub_index - 1 < tls_count) {
                    address = module.tls.?.callbacks[callback.sub_index - 1];
                    callback.sub_index += 1;
                    is_tls = true;
                }
            }
            if (address) |routine| {
                callback.current_tls = is_tls;
                module.attach_called = true;
                const sp = std.mem.alignBackward(u64, std.math.sub(u64, callback.restore.get(4), 48) catch return error.AddressOverflow, 16) + 8;
                try m.check(sp, 40, .write);
                try m.writeInt(sp, 64, initializer_return);
                callback.sp = sp;
                s.set(4, sp);
                s.set(1, module.base);
                s.set(2, @intFromBool(attach));
                s.set(8, @intFromBool(attach and callback.operation.kind == .startup and !is_tls));
                s.set(9, 0);
                s.pc = routine;
                if (w.trace) try host.print(2, "{s}_PROCESS_{s}: {s} base=0x{x} routine=0x{x}\n", .{ if (is_tls) @as([]const u8, "TLS") else "DLL", if (attach) @as([]const u8, "ATTACH") else "DETACH", module.name, module.base, routine });
            } else {
                callback.index += 1;
                callback.sub_index = 0;
            }
        }
        if (address == null) return w.nextCallback(s, m);
        return;
    }
    fn finishInitializer(w: *Windows, s: *State, m: *Memory) !void {
        const callback = if (w.callback) |*value| value else return error.InvalidWindowsInitializerReturn;
        if (s.get(4) != callback.sp + 8) return error.InvalidWindowsInitializerStack;
        const was_tls = callback.current_tls;
        const pass = was_tls or s.get(0) & 0xffffffff != 0;
        const instructions = s.instructions + 1;
        s.* = callback.restore;
        s.instructions = instructions;
        const l = &w.linker.?;
        const module = &l.modules.items[callback.queue[callback.index]];
        const operation = callback.operation;
        if (operation.kind == .startup or operation.kind == .load) {
            if (!was_tls and !pass) {
                if (operation.kind == .startup) {
                    try host.print(2, "Windows DLL initialization failed: {s}\n", .{module.name});
                    return error.WindowsDLLInitializationFailed;
                }
                w.callback = null;
                s.set(0, w.fail(1114)); // ERROR_DLL_INIT_FAILED; detach attempted initializers before rollback.
                return w.beginCallback(s, m, .{ .kind = .rollback, .mask = operation.mask, .saved = operation.saved, .api = operation.api });
            }
            if (!was_tls) module.attached = true;
        }
        if (was_tls and (operation.kind == .startup or operation.kind == .load) and module.entry == 0 and module.tls != null and callback.sub_index == module.tls.?.callback_count) module.attached = true;
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
        try m.writeInt(w.teb_address + last_error_offset, 32, w.last_error);
        s.set(0, result);
        w.calls += 1;
        if (w.trace and w.pending == null) try host.print(2, "{s}!{s} = 0x{x}\n", .{ @tagName(apiLibrary(api)), @tagName(api), result });
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
    fn adjustToken(w: *Windows, s: *State, m: *Memory) !u64 {
        const token: Token = for (w.tokens) |entry| {
            if (entry) |value| if (value.handle == s.get(1)) break value;
        } else return w.fail(6);
        const previous = try stackArg(s, m, 4);
        const length = try stackArg(s, m, 5);
        if (token.access & 0x20 == 0 or (previous != 0 and token.access & 8 == 0)) return w.fail(5);
        var requested: u64 = 0;
        if (s.get(2) & 0xffffffff == 0) {
            const next = s.get(8);
            if (next == 0) return w.fail(87);
            requested = try m.readInt(next, 32, .read);
            if (requested > (m.limit -| 4) / 12) return w.fail(87);
            try m.check(next, @intCast(4 + requested * 12), .read);
        }
        // This virtual process has no assigned Windows privileges. It cannot gain host rights.
        if (previous != 0) {
            if (length == 0) return w.fail(87);
            try m.check(length, 4, .write);
            if (s.get(9) & 0xffffffff < 4) {
                try m.writeInt(length, 32, 4);
                return w.fail(122);
            }
            try m.check(previous, 4, .write);
            try m.writeInt(length, 32, 4);
            try m.writeInt(previous, 32, 0);
        }
        w.last_error = if (requested == 0) 0 else 1300; // ERROR_NOT_ALL_ASSIGNED despite BOOL success.
        return 1;
    }
    fn perform(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        const a = s.get(1);
        const b = s.get(2);
        const count = s.get(8) & 0xffffffff;
        const out = s.get(9);
        switch (api) {
            .GetCurrentProcess => return invalid_handle,
            .OpenProcessToken => {
                if (a != invalid_handle) return w.fail(6);
                var access: u32 = @truncate(b);
                if (access & 0x80000000 != 0) access |= 0x20008;
                if (access & 0x40000000 != 0) access |= 0x200e0;
                if (access & 0x20000000 != 0) access |= 0x20000;
                if (access & 0x12000000 != 0) access |= 0xf01ff; // GENERIC_ALL / MAXIMUM_ALLOWED.
                access &= 0x0dffffff;
                if (access & ~@as(u32, 0xf01ff) != 0) return w.fail(5);
                const result = s.get(8);
                if (result == 0) return w.fail(87);
                try m.check(result, 8, .write);
                for (&w.tokens) |*entry| if (entry.* == null) {
                    const handle = w.next_handle;
                    try m.writeInt(result, 64, handle);
                    entry.* = .{ .handle = handle, .access = access };
                    w.next_handle += 1;
                    return 1;
                };
                return w.fail(8);
            },
            .AdjustTokenPrivileges => return w.adjustToken(s, m),
            .LookupPrivilegeValueW => {
                if (a != 0) {
                    const system = try @import("../windows_process.zig").wideString(w.allocator, m, a);
                    defer w.allocator.free(system);
                    if (system.len != 0) return w.fail(53); // Remote systems are unavailable.
                }
                if (b == 0 or s.get(8) == 0) return w.fail(87);
                const name = try @import("../windows_process.zig").wideString(w.allocator, m, b);
                defer w.allocator.free(name);
                for (privileges, 0..) |value, index| if (std.ascii.eqlIgnoreCase(name, value)) {
                    try m.writeInt(s.get(8), 64, index + 2);
                    return 1;
                };
                return w.fail(1313);
            },
            .SystemFunction036 => {
                const size: usize = @intCast(b & 0xffffffff);
                if (size > m.limit) return 0;
                if (size == 0) return 1;
                try m.check(a, size, .write);
                const bytes = w.allocator.alloc(u8, size) catch return 0;
                defer w.allocator.free(bytes);
                host.random(bytes) catch return 0;
                try m.write(a, bytes);
                return 1;
            },
            .RegOpenKeyExW => {
                const code = registryStatus(a);
                if (code != 0) return code;
                if (count & ~@as(u64, 8) != 0) return 87;
                var access: u32 = @truncate(out);
                if (access & 0xa2000000 != 0) access |= 0x20019; // Generic read/execute or maximum allowed.
                access &= 0x5dffffff;
                if (access & 0x300 == 0x300) return 87;
                if (access & ~@as(u32, 0x20319) != 0) return 5;
                const result = try stackArg(s, m, 4);
                if (result == 0) return 87;
                if (b != 0) {
                    const name = try @import("../windows_process.zig").wideString(w.allocator, m, b);
                    defer w.allocator.free(name);
                    if (name.len != 0) return 2;
                }
                // ponytail: empty read-only registry roots; add stored keys when guest writes are implemented.
                try m.writeInt(result, 64, a);
                return 0;
            },
            .RegQueryValueExW => {
                const code = registryStatus(a);
                if (code != 0) return code;
                if (s.get(8) != 0 or (try stackArg(s, m, 4) != 0 and try stackArg(s, m, 5) == 0)) return 87;
                if (b != 0) {
                    const name = try @import("../windows_process.zig").wideString(w.allocator, m, b);
                    defer w.allocator.free(name);
                }
                return 2; // No default or named values; LSTATUS does not modify LastError.
            },
            .RegCloseKey => return registryStatus(a),
            .GetFileSecurityW, .SetFileSecurityW => {
                if (!w.allow_files) return w.fail(5);
                if (a == 0) return w.fail(87);
                const name = try @import("../windows_process.zig").wideString(w.allocator, m, a);
                defer w.allocator.free(name);
                return w.fail(50); // No Windows ACL translation; never mutate host permissions.
            },
            .CharUpperW => return upperString(m, a),
            .CharPrevExA => {
                if (out & 0xffffffff != 0) return error.UnsupportedWindowsCharPrevFlags;
                return previousCharacter(m, @truncate(a), b, s.get(8));
            },
            .SysAllocString => {
                if (a == 0) return 0;
                var length: u64 = 0;
                while (length < m.limit / 2) : (length += 1) {
                    const address = std.math.add(u64, a, length * 2) catch return error.AddressOverflow;
                    if (try m.readInt(address, 16, .read) == 0) return w.allocBstr(m, a, length * 2);
                }
                return 0;
            },
            .SysAllocStringLen => return w.allocBstr(m, a, (b & 0xffffffff) * 2),
            .SysFreeString => {
                try w.freeBstr(m, a);
                return 0;
            },
            .SysStringLen => return (try bstrBytes(m, a)) / 2,
            .VariantInit => {
                try m.writeInt(a, 16, 0);
                return 0;
            },
            .VariantClear => return w.clearVariant(m, a),
            .VariantCopy => return w.copyVariant(m, a, b),
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
            .TlsAlloc => {
                const available = ~w.tls_allocated;
                if (available == 0) {
                    w.last_error = 8;
                    return 0xffffffff;
                }
                const index: u6 = @intCast(@ctz(available));
                w.tls_allocated |= @as(u64, 1) << index;
                try m.writeInt(w.teb_address + tls_slots_offset + @as(u64, index) * 8, 64, 0);
                return index;
            },
            .TlsFree => {
                const value: u32 = @truncate(a);
                if (value >= tls_slots_count or w.tls_allocated & (@as(u64, 1) << @as(u6, @truncate(value))) == 0) return w.fail(87);
                const index: u6 = @truncate(value);
                w.tls_allocated &= ~(@as(u64, 1) << index);
                try m.writeInt(w.teb_address + tls_slots_offset + @as(u64, index) * 8, 64, 0);
                return 1;
            },
            .TlsGetValue => {
                const slot: u32 = @truncate(a);
                if (slot >= tls_slots_count or w.tls_allocated & (@as(u64, 1) << @as(u6, @truncate(slot))) == 0) return w.fail(87);
                const index: u6 = @truncate(slot);
                const value = try m.readInt(w.teb_address + tls_slots_offset + @as(u64, index) * 8, 64, .read);
                w.last_error = 0;
                return value;
            },
            .TlsSetValue => {
                const value: u32 = @truncate(a);
                if (value >= tls_slots_count or w.tls_allocated & (@as(u64, 1) << @as(u6, @truncate(value))) == 0) return w.fail(87);
                try m.writeInt(w.teb_address + tls_slots_offset + @as(u64, value) * 8, 64, b);
                return 1;
            },
            .GetCommandLineA => return w.command_line_a,
            .GetCommandLineW => return w.command_line_w,
            .GetACP => return 65001,
            .GetProcessHeap => return process_heap,
            .HeapAlloc, .HeapReAlloc, .HeapFree, .HeapSize => return w.heap(s, m, api),
            .LoadLibraryA, .LoadLibraryW => return w.loadLibrary(s, m, api == .LoadLibraryW),
            .FreeLibrary => {
                if (w.callback != null) return w.fail(1114);
                if (Builtin.fromHandle(a) != null) return 1;
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
                if (Builtin.find(leaf)) |dll| return dll.handle();
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
                if (Builtin.fromHandle(a)) |dll| return dll.symbol(symbol) orelse w.fail(127);
                if (w.linker) |*l| {
                    const index = l.handle(a) orelse return w.fail(6);
                    const saved = l.checkpoint();
                    const result = l.resolve(m, index, symbol, w.callback == null, 0) catch |err| {
                        try l.rollback(m, saved);
                        return w.moduleError(err);
                    };
                    const mask = l.active() & ~saved.active;
                    w.installTls(m, mask) catch |err| {
                        try w.clearTls(m, mask);
                        try l.rollback(m, saved);
                        return w.moduleError(err);
                    };
                    if (mask != 0) w.pending = .{ .kind = .load, .mask = mask, .saved = saved, .api = .GetProcAddress };
                    return result;
                }
                return w.fail(6);
            },
            .WriteFile, .ReadFile => return w.fileIO(s, m, api == .ReadFile),
            .CreateFileA, .CreateFileW => return w.openFile(s, m, api == .CreateFileW),
            .CloseHandle => {
                if (a == invalid_handle) return 1; // Closing the current-process pseudo handle has no effect.
                for (&w.tokens) |*entry| if (entry.*) |token| if (token.handle == a) {
                    entry.* = null;
                    return 1;
                };
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
                return w.allocate(m, b, permissions, .virtual) catch w.fail(8);
            },
            .VirtualFree => {
                if (b != 0 or count != 0x8000) return w.fail(87);
                for (w.allocations.items, 0..) |allocation, index| if (allocation.kind == .virtual and allocation.address == a) {
                    try m.unmap(a, allocation.size);
                    _ = w.allocations.swapRemove(index);
                    return 1;
                };
                return w.fail(487);
            },
        }
    }
};
test "ADVAPI token and entropy outputs validate before mutation" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x3000, 4096, .{ .read = true });
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x140000000 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, invalid_handle);
    s.set(2, 0x28);
    s.set(8, 0x3000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .OpenProcessToken));
    try std.testing.expectEqual(@as(u64, 0x10000), w.next_handle);
    try std.testing.expect(w.tokens[0] == null);
    s.set(8, 0x1100);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .OpenProcessToken));
    const token = try m.readInt(0x1100, 64, .read);
    s.set(1, token);
    s.set(2, 0);
    s.set(4, 0x1800);
    s.set(8, 0x1200);
    s.set(9, 4);
    try m.writeInt(0x1200, 32, 1);
    try m.writeInt(0x1828, 64, 0x3000);
    try m.writeInt(0x1830, 64, 0x1300);
    try m.writeInt(0x1300, 32, 99);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .AdjustTokenPrivileges));
    try std.testing.expectEqual(@as(u64, 99), try m.readInt(0x1300, 32, .read));
    s.set(8, 0x1ffc);
    try m.writeInt(0x1ffc, 32, 1);
    try std.testing.expectError(error.UnmappedMemory, w.perform(&s, &m, .AdjustTokenPrivileges));
    try std.testing.expectEqual(@as(u64, 99), try m.readInt(0x1300, 32, .read));
    try m.writeInt(0x1ffc, 32, 0xffffffff);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .AdjustTokenPrivileges));
    try std.testing.expectEqual(@as(u32, 87), w.last_error);
    try m.write(0x1ffc, &.{ 1, 2, 3, 4 });
    s.set(1, 0x1ffc);
    s.set(2, 8);
    try std.testing.expectError(error.UnmappedMemory, w.perform(&s, &m, .SystemFunction036));
    var bytes: [4]u8 = undefined;
    try m.read(0x1ffc, &bytes, .read);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &bytes);
    s.set(1, 0x3000);
    s.set(2, 4);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .SystemFunction036));
}
test "USER32 case conversion validates full strings before writes and cursor scans stay checked" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x10000, 4096, .{ .read = true, .write = true });
    try m.map(0x11000, 4096, .{ .read = true, .write = true });
    try m.write(0x10ffc, &.{ 'a', 0, 'b', 0, 'c', 0, 0, 0 });
    try m.protect(0x11000, 4096, .{ .read = true });
    try std.testing.expectError(error.PermissionDenied, upperString(&m, 0x10ffc));
    try std.testing.expectEqual(@as(u64, 'a'), try m.readInt(0x10ffc, 16, .read));
    try std.testing.expectEqual(@as(u64, 'b'), try m.readInt(0x10ffe, 16, .read));
    try m.protect(0x11000, 4096, .{ .read = true, .write = true });
    try std.testing.expectEqual(@as(u64, 0x10ffc), try upperString(&m, 0x10ffc));
    try std.testing.expectEqual(@as(u64, 'A'), try m.readInt(0x10ffc, 16, .read));
    try std.testing.expectEqual(@as(u64, 'C'), try m.readInt(0x11000, 16, .read));
    try m.writeInt(0x11ffe, 16, 'z');
    try std.testing.expectError(error.UnmappedMemory, upperString(&m, 0x11ffe));
    try std.testing.expectEqual(@as(u64, 'z'), try m.readInt(0x11ffe, 16, .read));
    try std.testing.expectError(error.AddressOverflow, upperString(&m, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 0), try upperString(&m, 0));
    try std.testing.expectEqual(@as(u64, 0xd800), try upperString(&m, 0xd800));
    try std.testing.expectEqual(@as(u64, 0x1f88), try upperString(&m, 0x1f80));
    try m.write(0x10ffe, &.{ 0x81, 0x81, 0x81, 0x40, 'x', 0 });
    try std.testing.expectEqual(@as(u64, 0x11000), try previousCharacter(&m, 932, 0x10ffe, 0x11002));
    try std.testing.expectEqual(@as(u64, 0x11001), try previousCharacter(&m, 65001, 0x10ffe, 0x11002));
    try std.testing.expectEqual(@as(u64, 0x30000), try previousCharacter(&m, 932, 0x30000, 0x30000));
    try std.testing.expectEqual(@as(u64, 0x2ffff), try previousCharacter(&m, 932, 0x30000, 0x2ffff));
    try std.testing.expectError(error.UnmappedMemory, previousCharacter(&m, 932, 0x30000, 0x30001));
    try std.testing.expectError(error.InvalidWindowsStringCursor, previousCharacter(&m, 932, 0x10ffe, 0x11004));
}
test "Automation allocation ownership, faults and variant copy failure cleanup" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x4000, 4096, .{ .read = true });
    var w = Windows{ .allocator = a, .module_base = 0x140000000 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    const raw = [_]u8{ 0xe9, 0, 0, 0, 0, 0xd8, 0, 0 };
    try m.write(0x1ff8, &raw);
    s.set(1, 0x1ff8);
    s.set(2, 3);
    const ptr = try w.perform(&s, &m, .SysAllocStringLen);
    try std.testing.expectEqual(@as(u64, 6), try m.readInt(ptr - 4, 32, .read));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(ptr + 6, 16, .read));
    s.set(1, process_heap);
    s.set(2, 0);
    s.set(8, ptr);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .HeapFree));
    s.set(1, ptr - 8);
    s.set(8, 0x8000);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .VirtualFree));
    const used = m.used;
    s.set(1, 0x1ffe);
    s.set(2, 3);
    try std.testing.expectError(error.UnmappedMemory, w.perform(&s, &m, .SysAllocStringLen));
    try std.testing.expectEqual(used, m.used);
    s.set(1, 0);
    s.set(2, 0xffffffff);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .SysAllocStringLen));
    try std.testing.expectEqual(used, m.used);

    try m.writeInt(0x1100, 16, 8);
    try m.writeInt(0x1108, 64, ptr);
    try m.writeInt(0x1200, 16, 3);
    try m.writeInt(0x1208, 64, 43);
    try std.testing.expectError(error.PermissionDenied, w.copyVariant(&m, 0x4000, 0x1100));
    try std.testing.expectError(error.UnmappedMemory, w.copyVariant(&m, 0x1200, 0x3000));
    try m.writeInt(0x1300, 16, 8);
    try m.writeInt(0x1308, 64, 0x3004);
    try std.testing.expectError(error.UnmappedMemory, w.copyVariant(&m, 0x1100, 0x1300));
    try std.testing.expectEqual(@as(u64, 6), try m.readInt(ptr - 4, 32, .read));
    try std.testing.expectEqual(@as(u64, 3), try m.readInt(0x1200, 16, .read));
    try std.testing.expectEqual(@as(u64, 8), try m.readInt(0x1100, 16, .read));
    m.limit = m.used;
    try std.testing.expectEqual(@as(u64, 0x8007000e), try w.copyVariant(&m, 0x1200, 0x1100));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1200, 16, .read));
    try std.testing.expectEqual(@as(u64, 6), try m.readInt(ptr - 4, 32, .read));
    try std.testing.expectEqual(used, m.used);
    m.limit = 256 * 1024 * 1024;
    try std.testing.expectEqual(@as(u64, 0), try w.copyVariant(&m, 0x1200, 0x1100));
    const clone = try m.readInt(0x1208, 64, .read);
    try std.testing.expect(clone != ptr);
    try std.testing.expectEqual(@as(u64, 0), try w.clearVariant(&m, 0x1100));
    try std.testing.expectError(error.UnmappedMemory, m.readInt(ptr, 16, .read));
    try std.testing.expectEqual(@as(u64, 0xd800), try m.readInt(clone + 4, 16, .read));
    try std.testing.expectEqual(@as(u64, 0), try w.clearVariant(&m, 0x1200));
    try std.testing.expectError(error.UnmappedMemory, m.readInt(clone, 16, .read));
    try std.testing.expectEqual(@as(usize, 0), w.allocations.items.len);
    try std.testing.expectError(error.InvalidWindowsBstr, w.freeBstr(&m, ptr));
}
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
