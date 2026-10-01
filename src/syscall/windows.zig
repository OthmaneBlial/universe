const std = @import("std");
const host = @import("../host.zig");
const Memory = @import("../memory.zig").Memory;
const State = @import("../cpu/state.zig").State;
const PE = @import("../loader/pe.zig").Image;
const Linker = @import("../loader/pe_linker.zig").Linker;
const Operation = struct { kind: enum { startup, load, unload, rollback }, mask: u64, saved: ?Linker.Checkpoint = null, api: ?Api = null };
const Callback = struct { operation: Operation, restore: State, queue: [64]usize = undefined, length: usize = 0, index: usize = 0, sub_index: usize = 0, current_tls: bool = false, sp: u64 = 0 };
const CrtOperation = struct { kind: enum { initterm, cexit, exit }, cursor: u64 = 0, end: u64 = 0, code: u8 = 0 };
const CrtFrame = struct { operation: CrtOperation, restore: State, sp: u64 = 0 };
const Api = enum { ExitProcess, GetStdHandle, WriteFile, ReadFile, VirtualAlloc, VirtualFree, GetModuleHandleA, GetModuleHandleW, GetLastError, SetLastError, GetCommandLineA, GetCommandLineW, GetACP, GetProcessHeap, HeapAlloc, HeapReAlloc, HeapFree, HeapSize, CreateFileA, CreateFileW, CloseHandle, GetFileSizeEx, SetFilePointerEx, FlushFileBuffers, GetProcAddress, LoadLibraryA, LoadLibraryW, FreeLibrary, TlsAlloc, TlsFree, TlsGetValue, TlsSetValue, SysAllocString, SysAllocStringLen, SysFreeString, SysStringLen, VariantInit, VariantClear, VariantCopy, CharUpperW, CharPrevExA, GetCurrentProcess, OpenProcessToken, SystemFunction036, GetFileSecurityW, SetFileSecurityW, RegOpenKeyExW, AdjustTokenPrivileges, LookupPrivilegeValueW, RegQueryValueExW, RegCloseKey, malloc, calloc, realloc, free, memcpy, memmove, memset, memcmp, strlen, strcmp, wcscmp, wcsstr, __getmainargs, _errno, __doserrno, __p__fmode, __iob_func, __acrt_iob_func, _get_osfhandle, _isatty, _setmode, _fileno, fflush, fputc, fputs, fgetc, _exit, _c_exit, _beginthreadex, _initterm, _onexit, __dllonexit, _cexit, exit, __set_app_type, __setusermatherr, _XcptFilter, _purecall, __C_specific_handler, __CxxFrameHandler, _CxxThrowException, @"?terminate@@YAXXZ", @"??1type_info@@UEAA@XZ", CreateEventW, OpenEventW, SetEvent, ResetEvent, CreateSemaphoreW, OpenSemaphoreW, ReleaseSemaphore, WaitForSingleObject, WaitForMultipleObjects, InitializeCriticalSection, InitializeCriticalSectionAndSpinCount, SetCriticalSectionSpinCount, EnterCriticalSection, TryEnterCriticalSection, LeaveCriticalSection, DeleteCriticalSection, GetCurrentThread, GetCurrentProcessId, GetCurrentThreadId, ResumeThread, SetThreadAffinityMask, SetProcessAffinityMask, GetProcessAffinityMask, GetTickCount, GetTickCount64, QueryPerformanceCounter, QueryPerformanceFrequency, GetVersion, GetOEMCP, GetLargePageMinimum };
pub const stub_base: u64 = 0x700000000000;
const initializer_return: u64 = stub_base + 0xff0;
const crt_return: u64 = stub_base + 0xfe0;
comptime {
    if (std.meta.fields(Api).len * 16 > crt_return - stub_base) @compileError("Windows API gateways overlap callback return addresses");
}
const last_error_offset: u64 = 0x68;
const tls_slots_offset: u64 = 0x1480;
const tls_slots_count: u32 = 64;
const crt_base: u64 = 0x610000000000;
const crt_errno = crt_base;
const crt_doserrno = crt_base + 4;
const crt_fmode = crt_base + 8;
const crt_commode = crt_base + 12;
const crt_initenv = crt_base + 16;
const crt_environment = crt_base + 32;
const crt_streams = crt_base + 256;
const crt_file_size: u64 = 48; // Legacy Windows x64 _iobuf, not the UCRT opaque FILE.
fn crtData(name: []const u8) ?u64 {
    if (std.mem.eql(u8, name, "_iob")) return crt_streams;
    if (std.mem.eql(u8, name, "_fmode")) return crt_fmode;
    if (std.mem.eql(u8, name, "_commode")) return crt_commode;
    if (std.mem.eql(u8, name, "__initenv")) return crt_initenv;
    return null;
}
pub fn apiAddress(name: []const u8) ?u64 {
    const api = std.meta.stringToEnum(Api, name) orelse return null;
    return stub_base + @as(u64, @intFromEnum(api)) * 16;
}
pub const Builtin = enum {
    kernel32,
    oleaut32,
    user32,
    advapi32,
    msvcrt,
    pub fn find(name: []const u8) ?Builtin {
        if (std.ascii.eqlIgnoreCase(name, "kernel32.dll") or std.ascii.eqlIgnoreCase(name, "kernelbase.dll")) return .kernel32;
        if (std.ascii.eqlIgnoreCase(name, "oleaut32.dll")) return .oleaut32;
        if (std.ascii.eqlIgnoreCase(name, "user32.dll")) return .user32;
        if (std.ascii.eqlIgnoreCase(name, "advapi32.dll")) return .advapi32;
        if (std.ascii.eqlIgnoreCase(name, "msvcrt.dll")) return .msvcrt;
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
        if (dll == .msvcrt and value == .name) if (crtData(value.name)) |address| return address;
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
        .malloc, .calloc, .realloc, .free, .memcpy, .memmove, .memset, .memcmp, .strlen, .strcmp, .wcscmp, .wcsstr, .__getmainargs, ._errno, .__doserrno, .__p__fmode, .__iob_func, .__acrt_iob_func, ._get_osfhandle, ._isatty, ._setmode, ._fileno, .fflush, .fputc, .fputs, .fgetc, ._exit, ._c_exit, ._beginthreadex, ._initterm, ._onexit, .__dllonexit, ._cexit, .exit, .__set_app_type, .__setusermatherr, ._XcptFilter, ._purecall, .__C_specific_handler, .__CxxFrameHandler, ._CxxThrowException, .@"?terminate@@YAXXZ", .@"??1type_info@@UEAA@XZ" => .msvcrt,
        else => .kernel32,
    };
}
const AllocationKind = enum { virtual, heap, bstr, crt };
const Allocation = struct { address: u64, size: usize, requested: usize = 0, kind: AllocationKind = .virtual };
const File = struct { handle: u64, fd: c_int, access: u2, share: u3, device: u64, inode: u64 };
const invalid_handle: u64 = std.math.maxInt(u64);
const process_heap: u64 = 0x103;
const Token = struct { handle: u64, access: u32 };
const SyncState = union(enum) { event: struct { manual: bool, signaled: bool }, semaphore: struct { count: u32, maximum: u32 } };
const SyncObject = struct { state: SyncState, name: ?[]const u8, references: usize = 1 };
const SyncHandle = struct { handle: u64, object: usize, access: u32 };
const Wait = struct { handles: [64]u64 = undefined, length: usize = 1, all: bool = false, timeout: u32 = 0, started: u64 = 0 };
const Critical = struct { address: u64, depth: u32 = 0 };
const current_thread = invalid_handle - 1;
const sync_all_access: u32 = 0x1f0003;
const wait_failed: u64 = 0xffffffff;
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
fn crtUnit(m: *Memory, address: u64, index: usize, wide: bool) !u64 {
    const offset = std.math.mul(u64, index, if (wide) 2 else 1) catch return error.AddressOverflow;
    return m.readInt(std.math.add(u64, address, offset) catch return error.AddressOverflow, if (wide) 16 else 8, .read);
}
fn crtLength(m: *Memory, address: u64, wide: bool) !usize {
    for (0..m.limit / @as(usize, if (wide) 2 else 1)) |index| if (try crtUnit(m, address, index, wide) == 0) return index;
    return error.UnterminatedWindowsCrtString;
}
fn crtCompare(m: *Memory, left: u64, right: u64, wide: bool) !u64 {
    for (0..m.limit / @as(usize, if (wide) 2 else 1)) |index| {
        const a = try crtUnit(m, left, index, wide);
        const b = try crtUnit(m, right, index, wide);
        if (a != b) return if (a < b) std.math.maxInt(u64) else 1;
        if (a == 0) return 0;
    }
    return error.UnterminatedWindowsCrtString;
}
fn crtCopy(m: *Memory, destination: u64, source: u64, count: u64) !u64 {
    try m.check(source, @intCast(count), .read);
    try m.check(destination, @intCast(count), .write);
    var buffer: [4096]u8 = undefined;
    const backwards = destination > source and destination - source < count;
    var done: usize = 0;
    while (done < count) {
        const amount = @min(buffer.len, count - done);
        const offset = if (backwards) count - done - amount else done;
        try m.read(source + offset, buffer[0..amount], .read);
        try m.write(destination + offset, buffer[0..amount]);
        done += amount;
    }
    return destination;
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
    crt_argc: u32 = 0,
    crt_argv: u64 = 0,
    crt_modes: [3]u32 = @splat(0x4000), // _O_TEXT; this legacy CRT uses unbuffered standard streams.
    crt_lookahead: [3]?u8 = @splat(null),
    crt_closed: [3]bool = @splat(false),
    crt_app_type: u32 = 0,
    crt_pending: ?CrtOperation = null,
    crt_frames: std.ArrayList(CrtFrame) = .empty,
    crt_exit_routines: std.ArrayList(u64) = .empty,
    calls: u64 = 0,
    next_map: u64 = 0x200000000,
    allocations: std.ArrayList(Allocation) = .empty,
    files: std.ArrayList(File) = .empty,
    next_handle: u64 = 0x10000,
    // ponytail: 1,024 live sync handles/critical sections, linear lookup; hash if real contention-free workloads need it.
    sync_objects: std.ArrayList(?SyncObject) = .empty,
    sync_handles: std.ArrayList(SyncHandle) = .empty,
    criticals: std.ArrayList(Critical) = .empty,
    wait: ?Wait = null,
    boot_ns: u64 = 0,
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
        w.crt_frames.deinit(w.allocator);
        w.crt_exit_routines.deinit(w.allocator);
        for (w.sync_objects.items) |object| if (object) |value| if (value.name) |name| w.allocator.free(name);
        w.sync_objects.deinit(w.allocator);
        w.sync_handles.deinit(w.allocator);
        w.criticals.deinit(w.allocator);
    }
    pub fn initProcess(w: *Windows, m: *Memory, args: []const [:0]const u8) !void {
        w.boot_ns = try host.nowNs();
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
        var argument_bytes: usize = (args.len + 1) * 8;
        for (args) |arg| argument_bytes = std.math.add(usize, argument_bytes, arg.len + 1) catch return error.MemoryLimit;
        if (argument_bytes > m.limit or args.len > std.math.maxInt(u32)) return error.MemoryLimit;
        const argument_size = std.mem.alignForward(usize, argument_bytes, 4096);
        const arguments = try m.findFree(crt_base + 4096, argument_size);
        try m.map(arguments, argument_size, .{ .read = true, .write = true });
        var string_offset = (args.len + 1) * 8;
        for (args, 0..) |arg, index| {
            try m.writeInt(arguments + index * 8, 64, arguments + string_offset);
            try m.write(arguments + string_offset, arg[0 .. arg.len + 1]);
            string_offset += arg.len + 1;
        }
        w.crt_argc = @intCast(args.len);
        w.crt_argv = arguments;
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
        try m.map(crt_base, 4096, .{ .read = true, .write = true });
        try m.writeInt(crt_fmode, 32, 0x4000);
        try m.writeInt(crt_initenv, 64, crt_environment);
        for (0..20) |index| {
            try m.writeInt(crt_streams + index * crt_file_size + 24, 32, if (index < 3) @as(u32, if (index == 0) 1 else 2) | 4 else 0);
            try m.writeInt(crt_streams + index * crt_file_size + 28, 32, if (index < 3) index else 0xffffffff);
        }
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
        return pc == initializer_return or pc == crt_return or (pc >= stub_base and pc < stub_base + std.meta.fields(Api).len * 16 and (pc - stub_base) % 16 == 0);
    }
    pub fn dispatch(w: *Windows, s: *State, m: *Memory) !void {
        try m.check(s.pc, 1, .execute);
        if (s.pc == initializer_return) return w.finishInitializer(s, m);
        if (s.pc == crt_return) return w.finishCrt(s, m);
        const api: Api = @enumFromInt((s.pc - stub_base) / 16);
        const result = if (w.wait) |operation| blk: {
            const ready = try w.tryWait(operation);
            const elapsed = (try host.nowNs()) - operation.started;
            if (ready == null and (operation.timeout == 0xffffffff or elapsed < @as(u64, operation.timeout) * 1_000_000)) {
                const remaining = if (operation.timeout == 0xffffffff) 1_000_000 else @as(u64, operation.timeout) * 1_000_000 - elapsed;
                const delay = host.c.struct_timespec{ .tv_sec = 0, .tv_nsec = @intCast(@min(remaining, 1_000_000)) };
                if (host.c.nanosleep(&delay, null) != 0 and host.errno() != host.c.EINTR) return error.WindowsWaitClockFailed;
                return; // Keep the guest call pending; runtime limits still poll the clock.
            }
            w.wait = null;
            break :blk ready orelse 258;
        } else try w.perform(s, m, api);
        if (w.wait != null) return;
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
        if (w.crt_pending) |operation| {
            w.crt_pending = null;
            // ponytail: cap nested guest initializer/exit invocations at 64; raise if a real CRT needs more.
            if (w.crt_frames.items.len >= 64) return error.WindowsCrtCallbackLimit;
            try w.crt_frames.append(w.allocator, .{ .operation = operation, .restore = s.* });
            try w.nextCrt(s, m);
        }
    }
    fn nextCrt(w: *Windows, s: *State, m: *Memory) !void {
        const frame = &w.crt_frames.items[w.crt_frames.items.len - 1];
        var routine: ?u64 = null;
        if (frame.operation.kind == .initterm) {
            while (frame.operation.cursor < frame.operation.end) {
                const value = try m.readInt(frame.operation.cursor, 64, .read);
                frame.operation.cursor += 8;
                if (value != 0) {
                    routine = value;
                    break;
                }
            }
        } else routine = w.crt_exit_routines.pop();
        if (routine) |address| {
            try m.check(address, 1, .execute);
            const sp = std.mem.alignBackward(u64, std.math.sub(u64, frame.restore.get(4), 48) catch return error.AddressOverflow, 16) + 8;
            try m.check(sp, 40, .write);
            try m.writeInt(sp, 64, crt_return);
            frame.sp = sp;
            s.set(4, sp);
            s.pc = address;
        } else {
            const operation = frame.operation;
            _ = w.crt_frames.pop();
            if (operation.kind != .initterm) {
                for (0..3) |index| {
                    try m.writeInt(crt_streams + index * crt_file_size + 24, 32, 0);
                    try m.writeInt(crt_streams + index * crt_file_size + 28, 32, 0xffffffff);
                }
                w.crt_closed = @splat(true); // Close guest CRT streams, never the host process descriptors.
                w.crt_lookahead = @splat(null);
                if (operation.kind == .exit) w.exit_code = operation.code;
            }
        }
    }
    fn finishCrt(w: *Windows, s: *State, m: *Memory) !void {
        if (w.crt_frames.items.len == 0) return error.InvalidWindowsCrtReturn;
        const frame = w.crt_frames.items[w.crt_frames.items.len - 1];
        if (s.get(4) != frame.sp + 8) return error.InvalidWindowsCrtStack;
        const instructions = s.instructions + 1;
        s.* = frame.restore;
        s.instructions = instructions;
        try w.nextCrt(s, m);
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
    fn crtFail(m: *Memory, code: u32, result: u64) !u64 {
        try m.writeInt(crt_errno, 32, code);
        return result;
    }
    fn crtFree(w: *Windows, m: *Memory, ptr: u64) !void {
        if (ptr == 0) return;
        for (w.allocations.items, 0..) |allocation, index| if (allocation.kind == .crt and allocation.address == ptr) {
            try m.unmap(ptr, allocation.size);
            _ = w.allocations.swapRemove(index);
            return;
        };
        return error.InvalidWindowsCrtAllocation;
    }
    fn crtMalloc(w: *Windows, m: *Memory, size: u64) !u64 {
        // ponytail: reuse checked page allocations; suballocate if real CRT workloads reach the mapping limit.
        return w.allocate(m, size, .{ .read = true, .write = true }, .crt) catch |err| switch (err) {
            error.OutOfMemory, error.MemoryLimit => crtFail(m, 12, 0),
            else => return err,
        };
    }
    fn crtRealloc(w: *Windows, m: *Memory, ptr: u64, size: u64) !u64 {
        if (ptr == 0) return w.crtMalloc(m, size);
        for (w.allocations.items, 0..) |old, index| if (old.kind == .crt and old.address == ptr) {
            if (size == 0) {
                try w.crtFree(m, ptr);
                return 0;
            }
            if (size > m.limit) return crtFail(m, 12, 0);
            if (size <= old.size) {
                w.allocations.items[index].requested = @intCast(size);
                return ptr;
            }
            const next = try w.crtMalloc(m, size);
            if (next == 0) return 0;
            errdefer w.crtFree(m, next) catch {};
            _ = try crtCopy(m, next, ptr, old.requested);
            try w.crtFree(m, ptr);
            return next;
        };
        return error.InvalidWindowsCrtAllocation;
    }
    fn crtDescriptor(w: *Windows, number: u64) ?usize {
        const value: u32 = @truncate(number);
        if (value > 2 or w.crt_closed[value] or w.closed_standard[value]) return null;
        return @intCast(value);
    }
    fn crtStream(w: *Windows, m: *Memory, pointer: u64) !?usize {
        if (pointer < crt_streams or pointer - crt_streams >= crt_file_size * 3 or (pointer - crt_streams) % crt_file_size != 0) return null;
        const index: usize = @intCast((pointer - crt_streams) / crt_file_size);
        if (w.crtDescriptor(index) == null or try m.readInt(pointer + 28, 32, .read) != index) return null;
        return index;
    }
    fn crtFlag(m: *Memory, index: usize, flag: u32) !void {
        const address = crt_streams + index * crt_file_size + 24;
        try m.writeInt(address, 32, (try m.readInt(address, 32, .read)) | flag);
    }
    fn crtHostErrno() u32 {
        return switch (host.errno()) {
            host.c.EBADF => 9,
            host.c.EAGAIN => 11,
            host.c.ENOMEM => 12,
            host.c.EACCES, host.c.EPERM => 13,
            host.c.EINVAL => 22,
            host.c.ENOSPC => 28,
            host.c.EPIPE => 32,
            else => 5,
        };
    }
    fn crtPut(w: *Windows, m: *Memory, index: usize, bytes: []const u8) !bool {
        try m.check(crt_streams + index * crt_file_size + 24, 4, .write);
        if (index == 0) {
            try crtFlag(m, index, 0x20);
            _ = try crtFail(m, 9, 0);
            return false;
        }
        var buffer: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < bytes.len) {
            var used: usize = 0;
            while (offset < bytes.len and used < buffer.len - 1) : (offset += 1) {
                if (bytes[offset] == '\n' and w.crt_modes[index] == 0x4000) {
                    buffer[used] = '\r';
                    used += 1;
                }
                buffer[used] = bytes[offset];
                used += 1;
            }
            host.output(@intCast(index), buffer[0..used]) catch {
                try crtFlag(m, index, 0x20);
                _ = try crtFail(m, crtHostErrno(), 0);
                return false;
            };
        }
        return true;
    }
    fn crtRead(w: *Windows, m: *Memory, index: usize) !?u8 {
        if (w.crt_lookahead[index]) |byte| {
            w.crt_lookahead[index] = null;
            return byte;
        }
        var byte: [1]u8 = undefined;
        while (true) {
            const amount = host.c.read(@intCast(index), &byte, 1);
            if (amount < 0 and host.errno() == host.c.EINTR) continue;
            if (amount < 0) {
                try crtFlag(m, index, 0x20);
                _ = try crtFail(m, crtHostErrno(), 0);
            } else if (amount == 0) try crtFlag(m, index, 0x10) else return byte[0];
            return null;
        }
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
    fn syncHandle(w: *Windows, handle: u64) ?SyncHandle {
        for (w.sync_handles.items) |entry| if (entry.handle == handle) return entry;
        return null;
    }
    fn syncName(w: *Windows, m: *Memory, address: u64) ![]const u8 {
        for (0..261) |index| {
            if (try crtUnit(m, address, index, true) == 0) break;
        } else return error.WindowsSyncNameTooLong;
        const name = try @import("../windows_process.zig").wideString(w.allocator, m, address);
        defer w.allocator.free(name);
        const local = if (std.mem.startsWith(u8, name, "Local\\")) name[6..] else name;
        if (local.len == 0 or std.mem.indexOfScalar(u8, local, '\\') != null) return error.WindowsSyncNamespaceUnsupported;
        return w.allocator.dupe(u8, local);
    }
    fn openSync(w: *Windows, object: usize, access: u32) !u64 {
        if (w.sync_handles.items.len >= 1024) return w.fail(8);
        try w.sync_handles.append(w.allocator, .{ .handle = w.next_handle, .object = object, .access = access });
        w.sync_objects.items[object].?.references += 1;
        w.next_handle += 1;
        return w.next_handle - 1;
    }
    fn makeSync(w: *Windows, m: *Memory, s: *State, semaphore: bool, open: bool) !u64 {
        if ((!open and s.get(1) != 0) or (open and s.get(2) & 0xffffffff != 0)) return w.fail(50); // Security attributes and inheritance are not modeled.
        const pointer = if (open) s.get(8) else s.get(9);
        if (open and pointer == 0) return w.fail(87);
        var name: ?[]const u8 = if (pointer != 0) w.syncName(m, pointer) catch |err| switch (err) {
            error.WindowsSyncNamespaceUnsupported => return w.fail(50),
            error.WindowsSyncNameTooLong => return w.fail(87),
            error.DanglingSurrogateHalf, error.ExpectedSecondSurrogateHalf, error.UnexpectedSecondSurrogateHalf => return w.fail(1113),
            else => return err,
        } else null;
        defer if (name) |value| w.allocator.free(value);
        var access = sync_all_access;
        if (open) {
            access = @truncate(s.get(1));
            if (access & 0x0f000000 != 0) return w.fail(5); // No security/system/maximum-allowed rights.
            if (access & 0xf0000000 != 0) return w.fail(50); // Generic mappings require a broader security model.
            if (access & ~sync_all_access != 0) return w.fail(5);
        }
        if (name) |value| for (w.sync_objects.items, 0..) |entry, index| if (entry) |object| {
            if (object.name) |existing| if (std.mem.eql(u8, value, existing)) {
                if ((object.state == .semaphore) != semaphore) return w.fail(6);
                const handle = try w.openSync(index, access);
                if (handle != 0 and !open) w.last_error = 183;
                return handle;
            };
        };
        if (open) return w.fail(2);
        const initial: u32 = @truncate(s.get(2));
        const maximum: u32 = @truncate(s.get(8));
        if (semaphore and (initial > 0x7fffffff or maximum == 0 or maximum > 0x7fffffff or initial > maximum)) return w.fail(87);
        if (w.sync_handles.items.len >= 1024) return w.fail(8);
        const index = for (w.sync_objects.items, 0..) |entry, index| {
            if (entry == null) break index;
        } else w.sync_objects.items.len;
        try w.sync_handles.ensureUnusedCapacity(w.allocator, 1);
        if (index == w.sync_objects.items.len) try w.sync_objects.append(w.allocator, null);
        w.sync_objects.items[index] = .{ .name = name, .state = if (semaphore) .{ .semaphore = .{ .count = initial, .maximum = maximum } } else .{ .event = .{ .manual = initial != 0, .signaled = maximum != 0 } } };
        name = null;
        w.sync_handles.appendAssumeCapacity(.{ .handle = w.next_handle, .object = index, .access = sync_all_access });
        w.next_handle += 1;
        w.last_error = 0;
        return w.next_handle - 1;
    }
    fn tryWait(w: *Windows, operation: Wait) !?u64 {
        var objects: [64]?usize = @splat(null);
        for (operation.handles[0..operation.length], 0..) |handle, index| {
            for (operation.handles[0..index]) |earlier| if (handle == earlier) {
                _ = w.fail(87);
                return wait_failed;
            };
            if (handle == invalid_handle or handle == current_thread) continue; // The current process/thread has not terminated.
            const entry = w.syncHandle(handle) orelse {
                _ = w.fail(if (w.file(handle) != null or (handle >= 0x100 and handle <= 0x102 and !w.closed_standard[@intCast(handle - 0x100)])) @as(u32, 50) else 6);
                return wait_failed;
            };
            if (entry.access & 0x100000 == 0) {
                _ = w.fail(5);
                return wait_failed;
            }
            if (operation.all) for (objects[0..index]) |earlier| if (earlier == entry.object) {
                _ = w.fail(50); // Distinct handles aliasing one object in wait-all need native differential evidence.
                return wait_failed;
            };
            objects[index] = entry.object;
        }
        var first: ?usize = null;
        for (objects[0..operation.length], 0..) |object, index| {
            const ready = if (object) |item| switch (w.sync_objects.items[item].?.state) {
                .event => |event| event.signaled,
                .semaphore => |semaphore| semaphore.count != 0,
            } else false;
            if (ready and first == null) first = index;
            if (!ready and operation.all) return null;
        }
        const selected = first orelse return null;
        for (objects[0..operation.length], 0..) |object, index| {
            if (!operation.all and index != selected) continue;
            switch (w.sync_objects.items[object.?].?.state) {
                .event => |*event| if (!event.manual) {
                    event.signaled = false;
                },
                .semaphore => |*semaphore| semaphore.count -= 1,
            }
        }
        return if (operation.all) 0 else selected;
    }
    fn criticalBytes(m: *Memory, value: Critical) !void {
        var bytes: [40]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[8..12], if (value.depth == 0) 0xffffffff else value.depth - 1, .little);
        std.mem.writeInt(u32, bytes[12..16], value.depth, .little);
        std.mem.writeInt(u64, bytes[16..24], @intFromBool(value.depth != 0), .little);
        try m.write(value.address, &bytes); // One virtual CPU: no wait semaphore, debugger block or spin count.
    }
    fn critical(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        const address = s.get(1);
        const initialize = api == .InitializeCriticalSection or api == .InitializeCriticalSectionAndSpinCount;
        for (w.criticals.items, 0..) |*value, index| if (value.address == address) {
            if (initialize) return error.WindowsCriticalSectionAlreadyInitialized;
            if (api == .SetCriticalSectionSpinCount) {
                try m.check(address, 40, .write);
                return 0;
            }
            var next = value.*;
            if (api == .DeleteCriticalSection) {
                if (next.depth != 0) return error.WindowsCriticalSectionBusy;
                try m.write(address, &@as([40]u8, @splat(0)));
                _ = w.criticals.swapRemove(index);
                return 0;
            }
            if (api == .LeaveCriticalSection) {
                if (next.depth == 0) return error.WindowsCriticalSectionNotOwned;
                next.depth -= 1;
            } else {
                if (next.depth == 0x7fffffff) return error.WindowsCriticalSectionRecursionOverflow;
                next.depth += 1;
            }
            try criticalBytes(m, next);
            value.* = next;
            return @intFromBool(api == .TryEnterCriticalSection);
        };
        if (!initialize) return error.WindowsCriticalSectionNotInitialized;
        try m.check(address, 40, .write);
        if (w.criticals.items.len >= 1024) return error.WindowsCriticalSectionLimit;
        try w.criticals.ensureUnusedCapacity(w.allocator, 1);
        try criticalBytes(m, .{ .address = address });
        w.criticals.appendAssumeCapacity(.{ .address = address });
        return @intFromBool(api == .InitializeCriticalSectionAndSpinCount);
    }
    fn perform(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        const a = s.get(1);
        const b = s.get(2);
        const count = s.get(8) & 0xffffffff;
        const out = s.get(9);
        switch (api) {
            .CreateEventW, .OpenEventW, .CreateSemaphoreW, .OpenSemaphoreW => return w.makeSync(m, s, api == .CreateSemaphoreW or api == .OpenSemaphoreW, api == .OpenEventW or api == .OpenSemaphoreW) catch |err| switch (err) {
                error.OutOfMemory => w.fail(8),
                else => return err,
            },
            .SetEvent, .ResetEvent, .ReleaseSemaphore => {
                const handle = w.syncHandle(a) orelse return w.fail(6);
                const object = &w.sync_objects.items[handle.object].?;
                if ((object.state == .semaphore) != (api == .ReleaseSemaphore)) return w.fail(6);
                if (handle.access & 2 == 0) return w.fail(5);
                if (api == .ReleaseSemaphore) {
                    const release: u32 = @truncate(b);
                    if (release == 0 or release > 0x7fffffff) return w.fail(87);
                    const previous = s.get(8);
                    if (previous != 0) try m.check(previous, 4, .write);
                    if (release > object.state.semaphore.maximum - object.state.semaphore.count) return w.fail(298);
                    if (previous != 0) try m.writeInt(previous, 32, object.state.semaphore.count);
                    object.state.semaphore.count += release;
                } else object.state.event.signaled = api == .SetEvent;
                return 1;
            },
            .WaitForSingleObject, .WaitForMultipleObjects => {
                var operation = Wait{ .started = try host.nowNs() };
                if (api == .WaitForSingleObject) {
                    operation.handles[0] = a;
                    operation.timeout = @truncate(b);
                } else {
                    const length: u32 = @truncate(a);
                    if (length == 0 or length > 64) {
                        _ = w.fail(87);
                        return wait_failed;
                    }
                    operation.length = length;
                    operation.all = count != 0;
                    operation.timeout = @truncate(out);
                    try m.check(b, length * 8, .read);
                    for (operation.handles[0..length], 0..) |*handle, index| handle.* = try m.readInt(b + index * 8, 64, .read);
                }
                if (try w.tryWait(operation)) |ready| return ready;
                if (operation.timeout == 0) return 258;
                w.wait = operation;
                return 0; // dispatch keeps the call pending until readiness, timeout or runtime limits.
            },
            .InitializeCriticalSection, .InitializeCriticalSectionAndSpinCount, .SetCriticalSectionSpinCount, .EnterCriticalSection, .TryEnterCriticalSection, .LeaveCriticalSection, .DeleteCriticalSection => return w.critical(s, m, api),
            .GetCurrentThread => return current_thread,
            .GetCurrentProcessId, .GetCurrentThreadId => return 1,
            .ResumeThread => {
                if (a == current_thread) return 0; // Existing current thread, never suspended; no new thread is invented.
                _ = w.fail(6);
                return 0xffffffff;
            },
            .SetThreadAffinityMask, .SetProcessAffinityMask => {
                if (a != (if (api == .SetThreadAffinityMask) current_thread else invalid_handle)) return w.fail(6);
                if (b != 1) return w.fail(87);
                return 1; // The virtual initial thread/process already has this one-CPU affinity.
            },
            .GetProcessAffinityMask => {
                if (a != invalid_handle) return w.fail(6);
                try m.check(b, 8, .write);
                try m.check(s.get(8), 8, .write);
                try m.writeInt(b, 64, 1);
                try m.writeInt(s.get(8), 64, 1);
                return 1;
            },
            .GetTickCount, .GetTickCount64 => {
                const ticks = ((try host.nowNs()) - w.boot_ns) / 1_000_000;
                return if (api == .GetTickCount) @as(u32, @truncate(ticks)) else ticks;
            },
            .QueryPerformanceCounter, .QueryPerformanceFrequency => {
                try m.check(a, 8, .write);
                try m.writeInt(a, 64, if (api == .QueryPerformanceFrequency) 1_000_000_000 else try host.nowNs());
                return 1;
            },
            .GetVersion => return 0x23f00206, // Virtual NT 6.2 / build 9200 metadata; not the host OS or a full Windows claim.
            .GetOEMCP => return 65001, // Same explicit UTF-8 guest policy as GetACP.
            .GetLargePageMinimum => return 0, // Large-page guest allocations are unavailable.
            ._initterm => {
                if (b < a or (b - a) % 8 != 0 or b - a > m.limit) return error.InvalidWindowsCrtInitializers;
                try m.check(a, @intCast(b - a), .read);
                w.crt_pending = .{ .kind = .initterm, .cursor = a, .end = b };
                return 0;
            },
            ._onexit => {
                // DLLs must use their own __dllonexit table until per-module onexit ownership is supported.
                if (w.callback) |callback| if (callback.queue[callback.index] != 0) return error.WindowsDllOnexitScopeUnsupported;
                if (a == 0) return crtFail(m, 22, 0);
                try m.check(a, 1, .execute);
                if (w.linker) |l| {
                    const caller = try m.readInt(s.get(4), 64, .read);
                    for (l.modules.items[1..]) |module| if (module.active and caller >= module.base and caller - module.base < module.size) return error.WindowsDllOnexitScopeUnsupported;
                }
                w.crt_exit_routines.append(w.allocator, a) catch return crtFail(m, 12, 0);
                return a;
            },
            .__dllonexit => {
                if (a == 0 or b == 0 or s.get(8) == 0) return crtFail(m, 22, 0);
                try m.check(a, 1, .execute);
                try m.check(b, 8, .write);
                try m.check(s.get(8), 8, .write);
                const start = try m.readInt(b, 64, .read);
                const end = try m.readInt(s.get(8), 64, .read);
                if (end < start or (end - start) % 8 != 0 or end - start > m.limit -| 8 or (start == 0 and end != 0)) return crtFail(m, 22, 0);
                const length = end - start;
                if (start != 0) {
                    const allocation: Allocation = for (w.allocations.items) |value| {
                        if (value.kind == .crt and value.address == start) break value;
                    } else return error.InvalidWindowsCrtAllocation;
                    if (length > allocation.requested) return error.InvalidWindowsCrtAllocation;
                    try m.check(start, @intCast(length), .read);
                    try m.check(start, @intCast(@min(length + 8, allocation.size)), .write);
                }
                const next = try w.crtRealloc(m, start, length + 8);
                if (next == 0) return 0;
                try m.writeInt(next + length, 64, a);
                try m.writeInt(b, 64, next);
                try m.writeInt(s.get(8), 64, next + length + 8);
                return a;
            },
            ._cexit, .exit => {
                for (0..3) |index| try m.check(crt_streams + index * crt_file_size + 24, 8, .write);
                w.crt_pending = .{ .kind = if (api == .exit) .exit else .cexit, .code = @truncate(a) };
                return 0;
            },
            .__set_app_type => {
                const value: u32 = @truncate(a);
                if (value > 2) return error.InvalidWindowsCrtAppType;
                w.crt_app_type = value;
                return 0;
            },
            .__setusermatherr => {
                if (a != 0) return error.WindowsCrtMathHandlerUnsupported;
                return 0; // No custom handler; math entry points are not supplied by this CRT profile.
            },
            ._XcptFilter, .__C_specific_handler, .__CxxFrameHandler, ._CxxThrowException => return error.WindowsExceptionHandlingUnsupported,
            .@"??1type_info@@UEAA@XZ" => return error.WindowsCrtRttiUnsupported,
            ._purecall, .@"?terminate@@YAXXZ" => {
                w.exit_code = 3;
                return 0;
            },
            .malloc => return w.crtMalloc(m, a),
            .calloc => return w.crtMalloc(m, std.math.mul(u64, a, b) catch return crtFail(m, 12, 0)), // Mappings start zeroed.
            .realloc => return w.crtRealloc(m, a, b),
            .free => {
                try w.crtFree(m, a);
                return 0;
            },
            .memcpy, .memmove => return crtCopy(m, a, b, s.get(8)),
            .memset => {
                const length = s.get(8);
                try m.check(a, @intCast(length), .write);
                const bytes: [4096]u8 = @splat(@truncate(b));
                var offset: usize = 0;
                while (offset < length) {
                    const amount = @min(bytes.len, length - offset);
                    try m.write(a + offset, bytes[0..amount]);
                    offset += amount;
                }
                return a;
            },
            .memcmp => {
                const length = s.get(8);
                try m.check(a, @intCast(length), .read);
                try m.check(b, @intCast(length), .read);
                var left: [4096]u8 = undefined;
                var right: [4096]u8 = undefined;
                var offset: usize = 0;
                while (offset < length) {
                    const amount = @min(left.len, length - offset);
                    try m.read(a + offset, left[0..amount], .read);
                    try m.read(b + offset, right[0..amount], .read);
                    switch (std.mem.order(u8, left[0..amount], right[0..amount])) {
                        .lt => return invalid_handle,
                        .gt => return 1,
                        .eq => {},
                    }
                    offset += amount;
                }
                return 0;
            },
            .strlen => return crtLength(m, a, false),
            .strcmp, .wcscmp => return crtCompare(m, a, b, api == .wcscmp),
            .wcsstr => {
                const needle_length = try crtLength(m, b, true);
                if (needle_length == 0) return a;
                const length = try crtLength(m, a, true);
                if (needle_length > length) return 0;
                const haystack = try w.allocator.alloc(u16, length);
                defer w.allocator.free(haystack);
                const needle = try w.allocator.alloc(u16, needle_length);
                defer w.allocator.free(needle);
                try m.read(a, std.mem.sliceAsBytes(haystack), .read);
                try m.read(b, std.mem.sliceAsBytes(needle), .read);
                // Both arrays retain little-endian units; equality needs no Unicode conversion.
                return if (std.mem.indexOf(u16, haystack, needle)) |index| a + index * 2 else 0;
            },
            .__getmainargs => {
                if (out & 0xffffffff != 0) return error.WindowsCrtWildcardExpansionUnsupported;
                const info = try stackArg(s, m, 4);
                if (info != 0 and try m.readInt(info, 32, .read) != 0) return error.WindowsCrtNewHandlerUnsupported;
                try m.check(a, 4, .write);
                try m.check(b, 8, .write);
                try m.check(s.get(8), 8, .write);
                try m.writeInt(a, 32, w.crt_argc);
                try m.writeInt(b, 64, w.crt_argv);
                try m.writeInt(s.get(8), 64, crt_environment);
                return 0;
            },
            ._errno => return crt_errno,
            .__doserrno => return crt_doserrno,
            .__p__fmode => return crt_fmode,
            .__iob_func => return crt_streams,
            .__acrt_iob_func => return if (a & 0xffffffff < 3) crt_streams + (a & 0xffffffff) * crt_file_size else crtFail(m, 22, 0),
            ._get_osfhandle => return if (w.crtDescriptor(a)) |index| 0x100 + index else crtFail(m, 9, invalid_handle),
            ._isatty => return if (w.crtDescriptor(a)) |index| @intFromBool(host.c.isatty(@intCast(index)) != 0) else crtFail(m, 9, 0),
            ._fileno => return if (try w.crtStream(m, a)) |index| index else crtFail(m, 9, invalid_handle),
            ._setmode => {
                const index = w.crtDescriptor(a) orelse return crtFail(m, 9, invalid_handle);
                const mode: u32 = @truncate(b);
                if (mode != 0x4000 and mode != 0x8000) return crtFail(m, 22, invalid_handle);
                const previous = w.crt_modes[index];
                w.crt_modes[index] = mode;
                return previous;
            },
            .fflush => {
                if (a == 0) return 0; // Unbuffered streams have no pending output to flush.
                const index = try w.crtStream(m, a) orelse return crtFail(m, 9, invalid_handle);
                w.crt_lookahead[index] = null;
                return 0;
            },
            .fputc => {
                const index = try w.crtStream(m, b) orelse return crtFail(m, 9, invalid_handle);
                const byte: u8 = @truncate(a);
                return if (try w.crtPut(m, index, &.{byte})) byte else invalid_handle;
            },
            .fputs => {
                const index = try w.crtStream(m, b) orelse return crtFail(m, 9, invalid_handle);
                const length = try crtLength(m, a, false);
                const bytes = try w.allocator.alloc(u8, length);
                defer w.allocator.free(bytes);
                try m.read(a, bytes, .read);
                return if (try w.crtPut(m, index, bytes)) 0 else invalid_handle;
            },
            .fgetc => {
                const index = try w.crtStream(m, a) orelse return crtFail(m, 9, invalid_handle);
                const flag = crt_streams + index * crt_file_size + 24;
                try m.check(flag, 4, .write);
                if (index != 0) {
                    try crtFlag(m, index, 0x20);
                    return crtFail(m, 9, invalid_handle);
                }
                if (try m.readInt(flag, 32, .read) & 0x10 != 0) return invalid_handle;
                const byte = try w.crtRead(m, index) orelse return invalid_handle;
                if (w.crt_modes[index] == 0x8000) return byte;
                if (byte == 0x1a) {
                    try crtFlag(m, index, 0x10);
                    return invalid_handle;
                }
                if (byte == '\r') {
                    if (try w.crtRead(m, index)) |next| {
                        if (next == '\n') return '\n';
                        w.crt_lookahead[index] = next;
                    }
                }
                return byte;
            },
            ._exit => {
                w.exit_code = @truncate(a);
                return 0;
            },
            ._c_exit => return 0, // Quick cleanup returns without callbacks or buffered I/O.
            ._beginthreadex => {
                if (s.get(8) == 0 or (try stackArg(s, m, 4)) & 0xffffffff & ~@as(u64, 4) != 0) {
                    try m.writeInt(crt_doserrno, 32, 87);
                    return crtFail(m, 22, 0);
                }
                try m.writeInt(crt_doserrno, 32, 50); // ERROR_NOT_SUPPORTED; no guest thread is created.
                return crtFail(m, 11, 0);
            },
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
                if (a == invalid_handle or a == current_thread) return 1; // Pseudo handles are borrowed.
                for (w.sync_handles.items, 0..) |entry, index| if (entry.handle == a) {
                    const object = &w.sync_objects.items[entry.object].?;
                    object.references -= 1;
                    if (object.references == 0) {
                        if (object.name) |name| w.allocator.free(name);
                        w.sync_objects.items[entry.object] = null;
                    }
                    _ = w.sync_handles.swapRemove(index);
                    return 1;
                };
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
test "Win32 waits and semaphore outputs validate before consuming state" {
    const allocator = std.testing.allocator;
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x3000, 4096, .{ .read = true });
    var w = Windows{ .allocator = allocator, .module_base = 0x140000000 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(2, 1);
    s.set(8, 2);
    const handle = try w.perform(&s, &m, .CreateSemaphoreW);
    s.set(1, handle);
    s.set(8, 0x3000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .ReleaseSemaphore));
    try std.testing.expectEqual(@as(u32, 1), w.sync_objects.items[0].?.state.semaphore.count);
    try m.writeInt(0x1ff8, 64, handle);
    s.set(1, 2);
    s.set(2, 0x1ff8);
    s.set(8, 0);
    try std.testing.expectError(error.UnmappedMemory, w.perform(&s, &m, .WaitForMultipleObjects));
    try std.testing.expectEqual(@as(u32, 1), w.sync_objects.items[0].?.state.semaphore.count);
    try m.writeInt(0x1100, 64, handle);
    try m.writeInt(0x1108, 64, 123);
    s.set(2, 0x1100);
    try std.testing.expectEqual(wait_failed, try w.perform(&s, &m, .WaitForMultipleObjects));
    try std.testing.expectEqual(@as(u32, 1), w.sync_objects.items[0].?.state.semaphore.count);
    s.set(1, handle);
    s.set(2, 0);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .WaitForSingleObject));
    try std.testing.expectEqual(@as(u32, 0), w.sync_objects.items[0].?.state.semaphore.count);
    s.set(2, 1000);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .WaitForSingleObject));
    try std.testing.expect(w.wait != null);
    s.set(2, 1);
    s.set(8, 0x1200);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .ReleaseSemaphore));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1200, 32, .read));
    try std.testing.expectEqual(@as(?u64, 0), try w.tryWait(w.wait.?));
    try std.testing.expectEqual(@as(u32, 0), w.sync_objects.items[0].?.state.semaphore.count);
}
test "Critical-section and affinity output faults preserve state" {
    const allocator = std.testing.allocator;
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    var w = Windows{ .allocator = allocator, .module_base = 0x140000000 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0x1ff0);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .InitializeCriticalSection));
    try std.testing.expectEqual(@as(usize, 0), w.criticals.items.len);
    s.set(1, 0x1100);
    _ = try w.perform(&s, &m, .InitializeCriticalSection);
    try m.protect(0x1000, 4096, .{ .read = true });
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .EnterCriticalSection));
    try std.testing.expectEqual(@as(u32, 0), w.criticals.items[0].depth);
    try m.protect(0x1000, 4096, .{ .read = true, .write = true });
    _ = try w.perform(&s, &m, .EnterCriticalSection);
    try std.testing.expectError(error.WindowsCriticalSectionBusy, w.perform(&s, &m, .DeleteCriticalSection));
    try std.testing.expectEqual(@as(u32, 1), w.criticals.items[0].depth);
    _ = try w.perform(&s, &m, .LeaveCriticalSection);
    try std.testing.expectError(error.WindowsCriticalSectionNotOwned, w.perform(&s, &m, .LeaveCriticalSection));
    try m.writeInt(0x1300, 64, 99);
    s.set(1, invalid_handle);
    s.set(2, 0x1300);
    s.set(8, 0x2000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .GetProcessAffinityMask));
    try std.testing.expectEqual(@as(u64, 99), try m.readInt(0x1300, 64, .read));
    s.set(1, 0x2000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .QueryPerformanceCounter));
}
test "Synchronization handle exhaustion, shared references and token handles remain distinct" {
    const allocator = std.testing.allocator;
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.write(0x1800, "k\x00e\x00e\x00p\x00\x00\x00");
    var w = Windows{ .allocator = allocator, .module_base = 0x140000000 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    var handles: [1024]u64 = undefined;
    s.set(9, 0x1800);
    for (&handles, 0..) |*handle, index| {
        handle.* = try w.perform(&s, &m, .CreateEventW);
        try std.testing.expect(handle.* != 0);
        if (index == 0) s.set(9, 0);
    }
    const next = w.next_handle;
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .CreateEventW));
    try std.testing.expectEqual(@as(u32, 8), w.last_error);
    s.set(1, 0x100000);
    s.set(8, 0x1800);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .OpenEventW));
    try std.testing.expectEqual(next, w.next_handle);
    try std.testing.expectEqual(@as(usize, 1), w.sync_objects.items[0].?.references);
    s.set(1, invalid_handle);
    s.set(2, 8);
    s.set(8, 0x1100);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .OpenProcessToken));
    try std.testing.expectEqual(next, try m.readInt(0x1100, 64, .read));
    s.set(1, next);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .CloseHandle));
    for (handles) |handle| {
        s.set(1, handle);
        try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .CloseHandle));
    }
    try std.testing.expectEqual(@as(usize, 0), w.sync_handles.items.len);
    s.set(1, 0);
    s.set(2, 0);
    s.set(8, 0);
    s.set(9, 0x1800);
    const recreated = try w.perform(&s, &m, .CreateEventW);
    try std.testing.expect(recreated > next);
    try std.testing.expectEqual(@as(usize, 1024), w.sync_objects.items.len);
    s.set(1, handles[0]);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .SetEvent));
    try std.testing.expectEqual(@as(u32, 6), w.last_error);
}
test "CRT bulk writes validate whole ranges and preserve allocation ownership on failure" {
    const allocator = std.testing.allocator;
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(crt_base, 4096, .{ .read = true, .write = true });
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    try m.write(0x1ffc, "abcd");
    var w = Windows{ .allocator = allocator, .module_base = 0x140000000 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0x1ffc);
    s.set(2, 'z');
    s.set(8, 8);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .memset));
    var bytes: [4]u8 = undefined;
    try m.read(0x1ffc, &bytes, .read);
    try std.testing.expectEqualSlices(u8, "abcd", &bytes);
    s.set(2, 0x1000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .memcpy));
    s.set(1, 0x1000);
    s.set(2, 0x2ffc);
    try std.testing.expectError(error.UnmappedMemory, w.perform(&s, &m, .memmove));
    s.set(1, 0);
    s.set(2, std.math.maxInt(u64));
    s.set(8, 0);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .memmove));
    try std.testing.expectError(error.AddressOverflow, crtLength(&m, std.math.maxInt(u64), true));
    const ptr = try w.crtMalloc(&m, 4096);
    try m.writeInt(ptr, 64, 0x12345678);
    const old_used = m.used;
    m.limit = m.used;
    try std.testing.expectEqual(@as(u64, 0), try w.crtRealloc(&m, ptr, 8192));
    try std.testing.expectEqual(@as(u64, 12), try m.readInt(crt_errno, 32, .read));
    try std.testing.expectEqual(@as(u64, 0x12345678), try m.readInt(ptr, 64, .read));
    try std.testing.expectEqual(old_used, m.used);
    try std.testing.expectEqual(@as(usize, 4096), w.allocations.items[0].requested);
    try std.testing.expectError(error.InvalidWindowsCrtAllocation, w.crtFree(&m, ptr + 1));
    m.limit = 256 * 1024 * 1024;
    const borrowed = try w.allocate(&m, 0, .{ .read = true, .write = true }, .heap);
    try std.testing.expectError(error.InvalidWindowsCrtAllocation, w.crtFree(&m, borrowed));
    try w.crtFree(&m, ptr);
    try std.testing.expectError(error.InvalidWindowsCrtAllocation, w.crtFree(&m, ptr));
}
test "CRT startup and exit table outputs validate before allocation or partial writes" {
    const allocator = std.testing.allocator;
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(crt_base, 4096, .{ .read = true, .write = true });
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x4000, 4096, .{ .read = true, .execute = true });
    var w = Windows{ .allocator = allocator, .module_base = 0x140000000, .crt_argc = 7, .crt_argv = 0x1234 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(4, 0x1800);
    try m.writeInt(0x1828, 64, 0);
    try m.writeInt(0x1100, 32, 99);
    s.set(1, 0x1100);
    s.set(2, 0x1200);
    s.set(8, 0x4000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .__getmainargs));
    try std.testing.expectEqual(@as(u64, 99), try m.readInt(0x1100, 32, .read));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1200, 64, .read));
    s.set(1, 0x4000);
    const old_used = m.used;
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .__dllonexit));
    try std.testing.expectEqual(old_used, m.used);
    try std.testing.expectEqual(@as(usize, 0), w.allocations.items.len);
    s.set(8, 0x1300);
    try std.testing.expectEqual(@as(u64, 0x4000), try w.perform(&s, &m, .__dllonexit));
    const table = try m.readInt(0x1200, 64, .read);
    try std.testing.expectEqual(table + 8, try m.readInt(0x1300, 64, .read));
    try std.testing.expectEqual(@as(u64, 0x4000), try m.readInt(table, 64, .read));
    try m.protect(table, 4096, .{ .read = true });
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .__dllonexit));
    try std.testing.expectEqual(table + 8, try m.readInt(0x1300, 64, .read));
    try std.testing.expectEqual(@as(usize, 8), w.allocations.items[0].requested);
    s.set(1, 0x1000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, ._onexit));
    try std.testing.expectEqual(@as(usize, 0), w.crt_exit_routines.items.len);
    w.linker = .{ .allocator = allocator };
    for ([_]u64{ 0x140000000, 0x4000 }, [_][]const u8{ "main.exe", "scope.dll" }) |base, name| try w.linker.?.modules.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .base = base,
        .size = 4096,
        .entry = 0,
        .imports = .{ .rva = 0, .size = 0 },
        .exports = .{ .rva = 0, .size = 0 },
    });
    s.set(1, 0x4000);
    try m.writeInt(0x1800, 64, 0x4010);
    try std.testing.expectError(error.WindowsDllOnexitScopeUnsupported, w.perform(&s, &m, ._onexit));
    try std.testing.expectEqual(@as(usize, 0), w.crt_exit_routines.items.len);
    try m.writeInt(0x1800, 64, 0x140000010);
    try std.testing.expectEqual(@as(u64, 0x4000), try w.perform(&s, &m, ._onexit));
    try std.testing.expectEqual(@as(usize, 1), w.crt_exit_routines.items.len);
}
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
