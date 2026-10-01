const std = @import("std");
const host = @import("../host.zig");
const time_api = @import("../windows_time.zig");
const find_api = @import("../windows_find.zig");
const Console = @import("../windows_console.zig").Console;
const mapping_api = @import("../windows_mapping.zig");
const Memory = @import("../memory.zig").Memory;
const State = @import("../cpu/state.zig").State;
const PE = @import("../loader/pe.zig").Image;
const Linker = @import("../loader/pe_linker.zig").Linker;
const Operation = struct { kind: enum { startup, load, unload, rollback }, mask: u64, saved: ?Linker.Checkpoint = null, api: ?Api = null };
const Callback = struct { operation: Operation, restore: State, queue: [64]usize = undefined, length: usize = 0, index: usize = 0, sub_index: usize = 0, current_tls: bool = false, sp: u64 = 0 };
const CrtOperation = struct { kind: enum { initterm, cexit, exit }, cursor: u64 = 0, end: u64 = 0, code: u8 = 0 };
const CrtFrame = struct { operation: CrtOperation, restore: State, sp: u64 = 0 };
const Api = enum { ExitProcess, GetStdHandle, WriteFile, ReadFile, VirtualAlloc, VirtualFree, GetModuleHandleA, GetModuleHandleW, GetLastError, SetLastError, GetCommandLineA, GetCommandLineW, GetACP, GetProcessHeap, HeapAlloc, HeapReAlloc, HeapFree, HeapSize, CreateFileA, CreateFileW, CloseHandle, GetFileSizeEx, SetFilePointerEx, FlushFileBuffers, GetProcAddress, LoadLibraryA, LoadLibraryW, FreeLibrary, TlsAlloc, TlsFree, TlsGetValue, TlsSetValue, SysAllocString, SysAllocStringLen, SysFreeString, SysStringLen, VariantInit, VariantClear, VariantCopy, CharUpperW, CharPrevExA, GetCurrentProcess, OpenProcessToken, SystemFunction036, GetFileSecurityW, SetFileSecurityW, RegOpenKeyExW, AdjustTokenPrivileges, LookupPrivilegeValueW, RegQueryValueExW, RegCloseKey, malloc, calloc, realloc, free, memcpy, memmove, memset, memcmp, strlen, strcmp, wcscmp, wcsstr, __getmainargs, _errno, __doserrno, __p__fmode, __iob_func, __acrt_iob_func, _get_osfhandle, _isatty, _setmode, _fileno, fflush, fputc, fputs, fgetc, _exit, _c_exit, _beginthreadex, _initterm, _onexit, __dllonexit, _cexit, exit, __set_app_type, __setusermatherr, _XcptFilter, _purecall, __C_specific_handler, __CxxFrameHandler, _CxxThrowException, @"?terminate@@YAXXZ", @"??1type_info@@UEAA@XZ", CreateEventW, OpenEventW, SetEvent, ResetEvent, CreateSemaphoreW, OpenSemaphoreW, ReleaseSemaphore, WaitForSingleObject, WaitForMultipleObjects, InitializeCriticalSection, InitializeCriticalSectionAndSpinCount, SetCriticalSectionSpinCount, EnterCriticalSection, TryEnterCriticalSection, LeaveCriticalSection, DeleteCriticalSection, GetCurrentThread, GetCurrentProcessId, GetCurrentThreadId, ResumeThread, SetThreadAffinityMask, SetProcessAffinityMask, GetProcessAffinityMask, GetTickCount, GetTickCount64, QueryPerformanceCounter, QueryPerformanceFrequency, GetVersion, GetOEMCP, GetLargePageMinimum, MoveFileW, MoveFileExW, MoveFileWithProgressW, CreateDirectoryW, RemoveDirectoryW, DeleteFileW, CreateHardLinkW, GetFileAttributesW, SetFileAttributesW, GetFileInformationByHandle, GetFileSize, SetFilePointer, SetEndOfFile, LocalFileTimeToFileTime, FileTimeToLocalFileTime, FileTimeToSystemTime, SystemTimeToFileTime, FileTimeToDosDateTime, DosDateTimeToFileTime, CompareFileTime, GetSystemTimeAsFileTime, GetSystemTimePreciseAsFileTime, GetSystemTime, GetLocalTime, GetProcessTimes, GetFileTime, SetFileTime, GetConsoleMode, SetConsoleMode, GetConsoleScreenBufferInfo, SetConsoleCtrlHandler, SetFileApisToOEM, SetFileApisToANSI, AreFileApisANSI, GetConsoleCP, GetConsoleOutputCP, SetConsoleCP, SetConsoleOutputCP, GetFileType, CreateFileMappingW, OpenFileMappingW, MapViewOfFile, MapViewOfFileEx, UnmapViewOfFile, FlushViewOfFile, GetSystemInfo, GetNativeSystemInfo, IsProcessorFeaturePresent, GlobalMemoryStatusEx, GetDiskFreeSpaceExW, GetDiskFreeSpaceW, MultiByteToWideChar, WideCharToMultiByte, GetModuleFileNameA, GetModuleFileNameW, LocalAlloc, LocalFree, LocalLock, LocalUnlock, LocalSize, LocalFlags, LocalHandle, LocalReAlloc, FormatMessageW, SetCurrentDirectoryW, GetCurrentDirectoryW, GetTempPathW, FindFirstFileW, FindNextFileW, FindClose, FindFirstStreamW, FindNextStreamW, GetLogicalDriveStringsW, GetLogicalDriveStringsA, GetLogicalDrives, DeviceIoControl };
pub const stub_base: u64 = 0x700000000000;
const initializer_return: u64 = stub_base + 0xff0;
const crt_return: u64 = stub_base + 0xfe0;
const control_return: u64 = stub_base + 0xfd0;
comptime {
    if (std.meta.fields(Api).len * 16 > control_return - stub_base) @compileError("Windows API gateways overlap callback return addresses");
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
const AllocationKind = enum { virtual, heap, bstr, crt, local };
const Allocation = struct {
    address: u64,
    size: usize,
    requested: usize = 0,
    kind: AllocationKind = .virtual,
    local_handle: u64 = 0,
    locks: u8 = 0,
    fn localHandle(allocation: Allocation) u64 {
        return if (allocation.local_handle != 0) allocation.local_handle else allocation.address;
    }
};
const File = struct {
    handle: u64,
    fd: c_int,
    access: u2,
    share: u3,
    device: u64,
    inode: u64,
    metadata_only: bool = false,
    link_target: ?[]u8 = null,
    write_attributes: bool = false,
    preserve_access: bool = false,
    preserve_write: bool = false,
    fn close(entry: File, allocator: std.mem.Allocator) c_int {
        if (entry.link_target) |target| allocator.free(target);
        return host.c.close(entry.fd);
    }
};
const FileSearch = struct { directory: *host.c.DIR, pattern: []u16 };
const Search = struct {
    handle: u64,
    state: union(enum) { files: FileSearch, stream: void },
    fn close(search: Search, allocator: std.mem.Allocator) c_int {
        if (search.state == .files) {
            allocator.free(search.state.files.pattern);
            return host.c.closedir(search.state.files.directory);
        }
        return 0;
    }
};
const Deletion = struct { directory: c_int, name: [:0]u8, device: u64, inode: u64 };
const invalid_handle: u64 = std.math.maxInt(u64);
const process_heap: u64 = 0x103;
const Token = struct { handle: u64, access: u32 };
const SyncState = union(enum) { event: struct { manual: bool, signaled: bool }, semaphore: struct { count: u32, maximum: u32 } };
const SyncObject = struct { state: SyncState, name: ?[]const u8, references: usize = 1 };
const SyncHandle = struct { handle: u64, object: usize, access: u32 };
const Wait = struct { handles: [64]u64 = undefined, length: usize = 1, all: bool = false, timeout: u32 = 0, started: u64 = 0 };
const ControlFrame = struct { restore: State, wait: ?Wait, last_error: u32, event: u32, handlers: [64]u64 = undefined, remaining: usize, sp: u64 = 0 };
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
fn diskValues(info: host.DiskStat, extended: bool) ![4]u64 {
    const unit = info.unit;
    if (unit == 0) return error.UnsupportedDiskGeometry;
    if (info.free > info.blocks or info.available > info.free) return error.InvalidDiskCounts;
    if (extended) return .{
        std.math.mul(u64, info.available, unit) catch return error.DiskSizeOverflow,
        std.math.mul(u64, info.blocks, unit) catch return error.DiskSizeOverflow,
        std.math.mul(u64, info.free, unit) catch return error.DiskSizeOverflow,
        0,
    };
    // Virtual 512-byte sectors; the host allocation unit defines one guest cluster.
    if (unit % 512 != 0 or unit / 512 > std.math.maxInt(u32)) return error.UnsupportedDiskGeometry;
    // ponytail: DWORD counts saturate; coarsen virtual clusters if >16 TiB volumes need full legacy geometry.
    return .{ unit / 512, 512, @min(info.available, std.math.maxInt(u32)), @min(info.blocks, std.math.maxInt(u32)) };
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
    owned_sysroot: ?[:0]u8 = null,
    // ponytail: host cwd is process-wide; serialize embedded runtimes until each guest has directory descriptors.
    restore_directory: ?c_int = null,
    temporary_path: ?[:0]u8 = null,
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
    // ponytail: 1,024 live searches with linear handle lookup; hash only if measured volume requires it.
    searches: std.ArrayList(Search) = .empty,
    // ponytail: at most 1,024 open-file identities; scan pending deletions unless real handle volume needs hashing.
    deletions: std.ArrayList(Deletion) = .empty,
    next_handle: u64 = 0x10000,
    // ponytail: 1,024 live sync handles/critical sections, linear lookup; hash if real contention-free workloads need it.
    sync_objects: std.ArrayList(?SyncObject) = .empty,
    sync_handles: std.ArrayList(SyncHandle) = .empty,
    criticals: std.ArrayList(Critical) = .empty,
    wait: ?Wait = null,
    boot_ns: u64 = 0,
    created_time: u64 = 0,
    cpu_started: host.CpuTimes = .{},
    // ponytail: 64 live token handles; grow the table if real applications need more.
    tokens: [64]?Token = @splat(null),
    closed_standard: [3]bool = @splat(false),
    console: Console = .{},
    file_ansi: bool = true,
    ignore_control_c: bool = false,
    control_handlers: std.ArrayList(u64) = .empty,
    control: ?ControlFrame = null,
    mappings: mapping_api.Mappings = .{},
    linker: ?Linker = null,
    callback: ?Callback = null,
    pending: ?Operation = null,
    teb_address: u64 = 0,
    tls_vector: u64 = 0,
    tls_allocated: u64 = 0,
    pub fn deinit(w: *Windows) void {
        w.console.deinit();
        w.control_handlers.deinit(w.allocator);
        w.mappings.deinit(w.allocator);
        if (w.linker) |*l| l.deinit();
        for (w.files.items) |entry| _ = entry.close(w.allocator);
        for (w.searches.items) |entry| _ = entry.close(w.allocator);
        w.searches.deinit(w.allocator);
        w.files.clearRetainingCapacity();
        while (w.deletions.items.len != 0) {
            const entry = w.deletions.items[0];
            _ = w.finishDelete(entry.device, entry.inode);
        }
        w.files.deinit(w.allocator);
        w.deletions.deinit(w.allocator);
        w.allocations.deinit(w.allocator);
        w.crt_frames.deinit(w.allocator);
        w.crt_exit_routines.deinit(w.allocator);
        for (w.sync_objects.items) |object| if (object) |value| if (value.name) |name| w.allocator.free(name);
        w.sync_objects.deinit(w.allocator);
        w.sync_handles.deinit(w.allocator);
        w.criticals.deinit(w.allocator);
        if (w.restore_directory) |fd| {
            _ = host.c.fchdir(fd);
            _ = host.c.close(fd);
        }
        if (w.owned_sysroot) |path| w.allocator.free(path);
        if (w.temporary_path) |path| w.allocator.free(path);
    }
    fn setTemporaryPath(w: *Windows, env: []const []const u8) !void {
        for (env) |entry| {
            const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidEnvironment;
            const key = entry[0..equals];
            if (!std.ascii.eqlIgnoreCase(key, "TMP") and !std.ascii.eqlIgnoreCase(key, "TEMP") and !std.ascii.eqlIgnoreCase(key, "USERPROFILE")) return error.WindowsEnvironmentUnsupported;
        }
        for ([_][]const u8{ "TMP", "TEMP", "USERPROFILE" }) |key| {
            var value: ?[]const u8 = null;
            for (env) |entry| {
                const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
                if (std.ascii.eqlIgnoreCase(entry[0..equals], key))
                    value = if (entry.len > equals + 1) entry[equals + 1 ..] else null;
            }
            if (value) |path| {
                if (path.len > 131072) return error.WindowsEnvironmentTooLong;
                w.temporary_path = try w.allocator.dupeZ(u8, path);
                return;
            }
        }
    }
    pub fn initProcess(w: *Windows, m: *Memory, args: []const [:0]const u8, env: []const []const u8) !void {
        try w.setTemporaryPath(env);
        w.boot_ns = try host.nowNs();
        w.created_time = try time_api.fromTimestamp(try host.clock(.realtime));
        w.cpu_started = try host.cpuTimes();
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
    fn localAllocate(w: *Windows, m: *Memory, flags: u32, requested: u64) !u64 {
        if (flags & ~@as(u32, 0xf72) != 0) return w.fail(87);
        // Discarded handles have no mapping, but still count toward the allocation limit.
        if (w.allocations.items.len >= 1024) return w.fail(8);
        const movable = flags & 2 != 0;
        if (movable and requested == 0) {
            w.allocations.append(w.allocator, .{ .address = 0, .size = 0, .kind = .local, .local_handle = w.next_handle }) catch return w.fail(8);
        } else {
            _ = w.allocate(m, requested, .{ .read = true, .write = true }, .local) catch |err| switch (err) {
                error.OutOfMemory, error.MemoryLimit => return w.fail(8),
                else => return err,
            };
            if (movable) w.allocations.items[w.allocations.items.len - 1].local_handle = w.next_handle;
        }
        if (movable) w.next_handle += 1;
        return w.allocations.items[w.allocations.items.len - 1].localHandle();
    }
    fn localOperation(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        const value = s.get(1);
        const resize_flags: u32 = @truncate(s.get(8));
        if (api == .LocalReAlloc and (resize_flags & ~@as(u32, 0xff2) != 0 or (resize_flags & 0x80 != 0 and resize_flags & 0x40 != 0))) return w.fail(87);
        if (api == .LocalAlloc) return w.localAllocate(m, @truncate(value), s.get(2));
        if (api == .LocalFree and value == 0) return 0;
        for (w.allocations.items, 0..) |allocation, index| {
            if (allocation.kind != .local) continue;
            if (api == .LocalHandle) {
                if (allocation.address != 0 and allocation.address == value) return allocation.localHandle();
                continue;
            }
            if (allocation.localHandle() != value) continue;
            switch (api) {
                .LocalReAlloc => return w.localResize(m, index, s.get(2), resize_flags),
                .LocalFree => {
                    if (allocation.size != 0) try m.unmap(allocation.address, allocation.size);
                    _ = w.allocations.swapRemove(index);
                    return 0;
                },
                .LocalSize => return allocation.requested,
                .LocalFlags => return @as(u64, allocation.locks) | (if (allocation.size == 0) @as(u64, 0x4000) else 0),
                .LocalLock => {
                    if (allocation.requested == 0) return w.fail(157);
                    if (allocation.local_handle != 0) {
                        // ponytail: a checked 8-bit lock count; widen if a real guest needs deeper nesting.
                        if (allocation.locks == 255) return w.fail(212);
                        w.allocations.items[index].locks += 1;
                    }
                    return allocation.address;
                },
                .LocalUnlock => {
                    if (allocation.locks == 0) return w.fail(158);
                    w.allocations.items[index].locks -= 1;
                    if (allocation.locks == 1) return w.fail(0);
                    return 1;
                },
                else => unreachable,
            }
        }
        _ = w.fail(6);
        return if (api == .LocalFree) value else if (api == .LocalFlags) 0x8000 else 0;
    }
    fn localResize(w: *Windows, m: *Memory, index: usize, requested: u64, flags: u32) !u64 {
        const old = w.allocations.items[index];
        // Legacy discardable/compaction attributes are ignored; MODIFY never changes the allocation form.
        if (flags & 0x80 != 0) return old.localHandle();
        if (requested > m.limit) return w.fail(8);
        if (requested == 0 and old.local_handle != 0) {
            if (old.locks != 0) return w.fail(212);
            if (old.size != 0) try m.unmap(old.address, old.size);
            w.allocations.items[index].address = 0;
            w.allocations.items[index].size = 0;
            w.allocations.items[index].requested = 0;
            return old.localHandle();
        }
        if (requested <= old.size) {
            if (flags & 0x40 != 0 and requested > old.requested) {
                const zero = try w.allocator.alloc(u8, @intCast(requested - old.requested));
                defer w.allocator.free(zero);
                @memset(zero, 0);
                try m.write(old.address + old.requested, zero);
            }
            w.allocations.items[index].requested = @intCast(requested);
            return old.localHandle();
        }
        // ponytail: fixed/locked blocks grow in place only within their reserved page capacity.
        if ((old.local_handle == 0 or old.locks != 0) and flags & 2 == 0) return w.fail(8);
        const copied = @min(old.requested, @as(usize, @intCast(requested)));
        try m.check(old.address, copied, .read);
        const next = try w.allocate(m, requested, .{ .read = true, .write = true }, .local);
        errdefer {
            const pending = w.allocations.pop().?;
            m.unmap(pending.address, pending.size) catch {};
        }
        _ = try crtCopy(m, next, old.address, copied);
        if (old.size != 0) try m.unmap(old.address, old.size);
        const last = w.allocations.items.len - 1;
        w.allocations.items[last].local_handle = old.local_handle;
        w.allocations.items[last].locks = old.locks;
        _ = w.allocations.swapRemove(index);
        return w.allocations.items[index].localHandle();
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
    fn anchorSysroot(w: *Windows) !void {
        const root = w.sysroot orelse return;
        if (std.fs.path.isAbsolutePosix(root)) return;
        const absolute = try host.absolutePath(w.allocator, root);
        defer w.allocator.free(absolute);
        w.owned_sysroot = try w.allocator.dupeZ(u8, absolute);
        w.sysroot = w.owned_sysroot;
        if (w.linker) |*linker| linker.sysroot = w.sysroot;
    }
    pub fn bind(w: *Windows, image: PE, m: *Memory, name: []const u8) !void {
        try w.anchorSysroot();
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
        return pc == initializer_return or pc == crt_return or pc == control_return or (pc >= stub_base and pc < stub_base + std.meta.fields(Api).len * 16 and (pc - stub_base) % 16 == 0);
    }
    pub fn dispatch(w: *Windows, s: *State, m: *Memory) !void {
        try m.check(s.pc, 1, .execute);
        if (s.pc == initializer_return) return w.finishInitializer(s, m);
        if (s.pc == crt_return) return w.finishCrt(s, m);
        if (s.pc == control_return) return w.finishControl(s, m);
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
    pub fn pollControl(w: *Windows, s: *State, m: *Memory) !void {
        if (w.control != null) return; // Serialize control callbacks; Windows uses a separate handler thread.
        const event = w.console.take() orelse return;
        if (event == 0 and w.ignore_control_c) return;
        var frame = ControlFrame{ .restore = s.*, .wait = w.wait, .last_error = w.last_error, .event = event, .remaining = w.control_handlers.items.len };
        @memcpy(frame.handlers[0..frame.remaining], w.control_handlers.items);
        w.control = frame;
        w.wait = null;
        try w.nextControl(s, m);
    }
    fn nextControl(w: *Windows, s: *State, m: *Memory) !void {
        const frame = &w.control.?;
        if (frame.remaining == 0) {
            w.exit_code = 0x3a; // Low byte of Windows STATUS_CONTROL_C_EXIT (0xc000013a).
            w.control = null;
            return;
        }
        frame.remaining -= 1;
        const address = frame.handlers[frame.remaining];
        try m.check(address, 1, .execute);
        const sp = std.mem.alignBackward(u64, std.math.sub(u64, frame.restore.get(4), 48) catch return error.AddressOverflow, 16) + 8;
        try m.check(sp, 40, .write);
        try m.writeInt(sp, 64, control_return);
        frame.sp = sp;
        s.set(4, sp);
        s.set(1, frame.event);
        s.pc = address;
    }
    fn finishControl(w: *Windows, s: *State, m: *Memory) !void {
        const frame = w.control orelse return error.InvalidWindowsControlReturn;
        if (s.get(4) != frame.sp + 8) return error.InvalidWindowsControlStack;
        const handled = s.get(0) & 0xffffffff != 0;
        const instructions = s.instructions + 1;
        s.* = frame.restore;
        s.instructions = instructions;
        if (handled) {
            w.wait = frame.wait;
            w.last_error = frame.last_error;
            try m.writeInt(w.teb_address + last_error_offset, 32, w.last_error);
            w.control = null;
        } else try w.nextControl(s, m);
    }
    fn consoleOperation(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        const a = s.get(1);
        const b = s.get(2);
        if (api == .SetFileApisToOEM or api == .SetFileApisToANSI) {
            w.file_ansi = api == .SetFileApisToANSI;
            return 0;
        }
        if (api == .AreFileApisANSI) return @intFromBool(w.file_ansi);
        if (api == .GetConsoleCP or api == .GetConsoleOutputCP) return 65001;
        if (api == .SetConsoleCP or api == .SetConsoleOutputCP) {
            const page: u32 = @truncate(a);
            if (page == 0) return w.fail(87);
            if (page != 65001) return w.fail(50);
            return 1;
        }
        if (api == .SetConsoleCtrlHandler) {
            const add = b & 0xffffffff != 0;
            if (a != 0 and !add) {
                var index = w.control_handlers.items.len;
                while (index != 0) {
                    index -= 1;
                    if (w.control_handlers.items[index] == a) {
                        _ = w.control_handlers.orderedRemove(index);
                        return 1;
                    }
                }
                return w.fail(87);
            }
            if (a != 0) {
                try m.check(a, 1, .execute);
                // ponytail: 64 control registrations; grow only if an actual guest needs more.
                if (w.control_handlers.items.len == 64) return w.fail(8);
                w.control_handlers.ensureUnusedCapacity(w.allocator, 1) catch return w.fail(8);
            }
            w.console.start() catch |err| return w.fail(if (err == error.WindowsConsoleBusy) 50 else hostError());
            if (a == 0) {
                w.ignore_control_c = add;
                w.console.ignoreC(add);
            } else w.control_handlers.appendAssumeCapacity(a);
            return 1;
        }
        var fd: c_int = undefined;
        if (a >= 0x100 and a <= 0x102) {
            const index: usize = @intCast(a - 0x100);
            if (w.closed_standard[index]) return w.fail(6);
            fd = @intCast(index);
        } else if (w.file(a)) |entry| fd = entry.fd else return w.fail(6);
        if (api == .GetFileType) {
            const info = host.statFd(fd) catch return w.fail(hostError());
            return switch (info.mode & host.c.S_IFMT) {
                host.c.S_IFREG, host.c.S_IFDIR => 1,
                host.c.S_IFCHR => 2,
                host.c.S_IFIFO, host.c.S_IFSOCK => 3,
                else => w.fail(50),
            };
        }
        if (host.c.isatty(fd) == 0) return w.fail(6);
        if (fd != 0 or api == .GetConsoleScreenBufferInfo) return w.fail(50); // Output buffers need a renderer.
        if (api == .GetConsoleMode) {
            try m.check(b, 4, .write);
            const mode = Console.inputMode() catch return w.fail(hostError());
            try m.writeInt(b, 32, mode);
            return 1;
        }
        const mode: u32 = @truncate(b);
        if (mode & ~@as(u32, 0x3ff) != 0 or (mode & 4 != 0 and mode & 2 == 0)) return w.fail(87);
        if (mode & ~@as(u32, 7) != 0) return w.fail(50);
        w.console.start() catch |err| return w.fail(if (err == error.WindowsConsoleBusy) 50 else hostError());
        w.console.setInput(mode) catch return w.fail(hostError());
        return 1;
    }
    fn mappingError(w: *Windows, err: anyerror) !u64 {
        return w.fail(switch (err) {
            error.WindowsMappingHandle => 6,
            error.WindowsMappingAccess => 5,
            error.WindowsMappingParameter, error.WindowsSyncNameTooLong => 87,
            error.WindowsMappingAlignment => 1132,
            error.WindowsMappingAddress, error.InvalidMapping => 487,
            error.WindowsMappingEmpty => 1006,
            error.WindowsMappingUnsupported, error.WindowsSyncNamespaceUnsupported => 50,
            error.WindowsMappingReadFault => 30,
            error.WindowsMappingChanged => 1224,
            error.HostMappingFailed => hostError(),
            error.OutOfMemory, error.MemoryLimit => 8,
            error.DanglingSurrogateHalf, error.ExpectedSecondSurrogateHalf, error.UnexpectedSecondSurrogateHalf => 1113,
            else => return err,
        });
    }
    fn finishMappingDeletes(w: *Windows) ?u32 {
        var index: usize = 0;
        while (index < w.deletions.items.len) {
            const entry = w.deletions.items[index];
            const length = w.deletions.items.len;
            if (w.finishDelete(entry.device, entry.inode)) |code| return code;
            if (length == w.deletions.items.len) index += 1;
        }
        return null;
    }
    fn mappingOperation(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        const a = s.get(1);
        const b = s.get(2);
        if (api == .GetSystemInfo or api == .GetNativeSystemInfo) {
            try m.check(a, 48, .write);
            var bytes: [48]u8 = @splat(0);
            std.mem.writeInt(u16, bytes[0..2], 9, .little); // Virtual AMD64 processor, including "native" for this guest.
            std.mem.writeInt(u32, bytes[4..8], Memory.page_size, .little);
            std.mem.writeInt(u64, bytes[8..16], 65536, .little);
            std.mem.writeInt(u64, bytes[16..24], 0x7fffffffffff, .little);
            std.mem.writeInt(u64, bytes[24..32], 1, .little);
            std.mem.writeInt(u32, bytes[32..36], 1, .little);
            std.mem.writeInt(u32, bytes[36..40], 8664, .little);
            std.mem.writeInt(u32, bytes[40..44], 65536, .little);
            std.mem.writeInt(u16, bytes[44..46], 6, .little);
            try m.write(a, &bytes);
            return 0;
        }
        if (api == .UnmapViewOfFile) {
            w.mappings.unmap(w.allocator, m, a) catch |err| return w.mappingError(err);
            if (w.finishMappingDeletes()) |code| return w.fail(code);
            return 1;
        }
        if (api == .FlushViewOfFile) {
            w.mappings.flushView(a, b) catch |err| return w.mappingError(err);
            return 1;
        }
        if (api == .MapViewOfFile or api == .MapViewOfFileEx) {
            const offset = ((s.get(8) & 0xffffffff) << 32) | (s.get(9) & 0xffffffff);
            const result = w.mappings.map(w.allocator, m, a, @truncate(b), offset, try stackArg(s, m, 4), if (api == .MapViewOfFileEx) try stackArg(s, m, 5) else 0, w.next_map) catch |err| return w.mappingError(err);
            w.next_map = @max(w.next_map, std.mem.alignForward(u64, result + w.mappings.views.items[w.mappings.views.items.len - 1].bytes.len, 65536));
            return result;
        }
        const open = api == .OpenFileMappingW;
        if ((!open and b != 0) or (open and b & 0xffffffff != 0)) return w.fail(50);
        const pointer = if (open) s.get(8) else try stackArg(s, m, 5);
        if (open and pointer == 0) return w.fail(87);
        const name = if (pointer != 0) w.syncName(m, pointer) catch |err| return w.mappingError(err) else null;
        defer if (name) |value| w.allocator.free(value);
        if (name) |value| {
            for (w.sync_objects.items) |entry| if (entry) |object| if (object.name) |existing| {
                if (std.mem.eql(u8, value, existing)) return w.fail(6);
            };
            if (w.mappings.named(value)) |index| {
                const access: u32 = if (open) @truncate(a) else 0xf001f | (if (w.mappings.objects.items[index].?.protection >= 0x20) @as(u32, 0x20) else 0);
                // Creation of an existing read-only section still returns its full object handle.
                const handle = if (open) w.mappings.open(w.allocator, index, w.next_handle, access) catch |err| return w.mappingError(err) else blk: {
                    w.mappings.handles.ensureUnusedCapacity(w.allocator, 1) catch return w.fail(8);
                    if (w.mappings.handles.items.len >= 1024) return w.fail(8);
                    w.mappings.handles.appendAssumeCapacity(.{ .value = w.next_handle, .object = index, .access = access });
                    w.mappings.objects.items[index].?.references += 1;
                    break :blk w.next_handle;
                };
                w.next_handle += 1;
                if (!open) w.last_error = 183;
                return handle;
            }
        }
        if (open) return w.fail(2);
        var size = ((s.get(9) & 0xffffffff) << 32) | ((try stackArg(s, m, 4)) & 0xffffffff);
        var source: ?mapping_api.Source = null;
        if (a != invalid_handle) {
            const entry = w.file(a) orelse return w.fail(6);
            if (!w.allow_files or entry.metadata_only or w.pendingDelete(entry.device, entry.inode)) return w.fail(5);
            const info = host.statFd(entry.fd) catch return w.fail(hostError());
            if (info.size < 0) return w.fail(87);
            if (size == 0) size = @intCast(info.size);
            source = .{ .fd = entry.fd, .access = entry.access, .device = entry.device, .inode = entry.inode, .size = @intCast(info.size) };
        } else if (size == 0) return w.fail(87);
        const handle = w.mappings.create(w.allocator, w.next_handle, source, size, @truncate(s.get(8)), name) catch |err| return w.mappingError(err);
        w.next_handle += 1;
        w.last_error = 0;
        return handle;
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
            host.c.EXDEV => 17,
            host.c.ENOTEMPTY => 145,
            host.c.ELOOP, host.c.ENOSYS, host.c.ENOTSUP => 50,
            host.c.EMLINK => 1142,
            host.c.ENOSPC => 112,
            host.c.ENAMETOOLONG => 206,
            host.c.EINVAL => 87,
            else => 1117,
        };
    }
    fn stackArg(s: *State, m: *Memory, index: u64) !u64 {
        return m.readInt(s.get(4) +% (8 + index * 8), 64, .read);
    }
    fn messageOperation(w: *Windows, s: *State, m: *Memory) !u64 {
        const message = @import("../windows_message.zig");
        const flags: u32 = @truncate(s.get(1));
        const source_kind = flags & 0x1c00;
        if (flags & ~@as(u32, 0x3fff) != 0 or source_kind == 0 or (source_kind & 0x400 != 0 and source_kind != 0x400)) return w.fail(87);
        if (source_kind & 0x800 != 0) return w.fail(50); // Guest message-table resources are not yet implemented.
        const destination = try stackArg(s, m, 4);
        const capacity: u32 = @truncate(try stackArg(s, m, 5));
        if (destination == 0) return w.fail(87);
        const allocated = flags & 0x100 != 0;
        if (!allocated and capacity == 0) return w.fail(122);
        const source = if (source_kind == 0x400) blk: {
            if (s.get(2) == 0) return w.fail(87);
            break :blk try message.read(w.allocator, m, s.get(2), null);
        } else blk: {
            const language: u32 = @truncate(s.get(9));
            if (language != 0 and language != 0x409) return w.fail(1815);
            const text = message.system(@truncate(s.get(8))) orelse return w.fail(317);
            break :blk try std.unicode.utf8ToUtf16LeAlloc(w.allocator, text);
        };
        defer w.allocator.free(source);
        const output = try message.render(w.allocator, source, flags, .{ .memory = m, .pointer = if (flags & 0x200 != 0) 0 else try stackArg(s, m, 6), .array = flags & 0x2000 != 0 });
        defer w.allocator.free(output);
        const bytes = std.mem.sliceAsBytes(output[0 .. output.len + 1]);
        if (allocated) {
            try m.check(destination, 8, .write);
            const size = @max(bytes.len, @as(u64, capacity) * 2);
            const pointer = try w.localAllocate(m, 0, size);
            if (pointer == 0) return 0;
            errdefer {
                const pending = w.allocations.pop().?;
                m.unmap(pending.address, pending.size) catch {};
            }
            try m.write(pointer, bytes);
            try m.writeInt(destination, 64, pointer);
        } else {
            if (output.len >= capacity) return w.fail(122);
            try m.write(destination, bytes);
        }
        return output.len;
    }
    fn moduleFilename(w: *Windows, s: *State, m: *Memory, wide: bool) !u64 {
        const capacity: u32 = @truncate(s.get(8));
        if (capacity == 0) return w.fail(122);
        const destination = s.get(2);
        if (destination == 0) return w.fail(87);
        const handle = if (s.get(1) == 0) w.module_base else s.get(1);
        if (Builtin.fromHandle(handle) != null) return w.fail(50); // Built-in APIs have no loaded file.
        const linker = w.linker orelse return w.fail(126);
        const index = linker.handle(handle) orelse return w.fail(126);
        const path = linker.modules.items[index].path orelse return w.fail(126);
        if (!std.unicode.utf8ValidateSlice(path)) return w.fail(1113);
        var length: usize = undefined;
        if (wide) {
            const output = std.unicode.utf8ToUtf16LeAllocZ(w.allocator, path) catch return w.fail(8);
            defer w.allocator.free(output);
            length = output.len;
            const copied = @min(length, capacity - 1);
            output[copied] = 0;
            try m.write(destination, std.mem.sliceAsBytes(output[0 .. copied + 1]));
        } else {
            length = path.len;
            const copied = @min(length, capacity - 1);
            const output = w.allocator.dupeZ(u8, path[0..copied]) catch return w.fail(8);
            defer w.allocator.free(output);
            try m.write(destination, output[0 .. copied + 1]);
        }
        if (length >= capacity) {
            _ = w.fail(122);
            return capacity;
        }
        return length;
    }
    fn encodingOperation(w: *Windows, s: *State, m: *Memory, wide: bool) !u64 {
        const page: u32 = @truncate(s.get(1));
        if (page != 0 and page != 1 and page != 3 and page != 65001) return w.fail(87);
        const flags: u32 = @truncate(s.get(2));
        const strict: u32 = if (wide) 0x80 else 8;
        if (flags != 0 and flags != strict) return w.fail(1004);
        const destination = try stackArg(s, m, 4);
        const capacity: i32 = @bitCast(@as(u32, @truncate(try stackArg(s, m, 5))));
        var used: u64 = 0;
        if (wide) {
            const default = try stackArg(s, m, 6);
            used = try stackArg(s, m, 7);
            if (page == 65001 and (default != 0 or used != 0)) return w.fail(87);
            // ANSI/OEM aliases use our UTF-8 profile: every scalar fits, so the default byte is never read.
        }
        return @import("../windows_encoding.zig").convert(w.allocator, m, s.get(8), @bitCast(@as(u32, @truncate(s.get(9)))), destination, capacity, wide, flags != 0, used) catch |err| return w.fail(switch (err) {
            error.InvalidParameter => 87,
            error.InvalidUnicode => 1113,
            error.InsufficientBuffer => 122,
            error.OutOfMemory, error.MemoryLimit => 8,
            else => return err,
        });
    }
    fn directoryOperation(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        if (!w.allow_files) return w.fail(5);
        try w.anchorSysroot();
        if (api == .GetLogicalDrives or api == .GetLogicalDriveStringsW or api == .GetLogicalDriveStringsA) {
            // Enumerate our mounted guest drive, not the host's disk layout.
            const fd = host.c.open(if (w.sysroot) |root| root.ptr else "/", host.c.O_RDONLY | host.c.O_DIRECTORY | host.c.O_CLOEXEC);
            if (fd < 0) return w.fail(switch (host.errno()) {
                host.c.ENOENT, host.c.ENOTDIR => 3,
                else => hostError(),
            });
            defer _ = host.c.close(fd);
            if (api == .GetLogicalDrives) return 1 << 2;
            const capacity: u32 = @truncate(s.get(1));
            if (capacity < 5) return 5;
            if (s.get(2) == 0) return w.fail(87);
            try m.write(s.get(2), if (api == .GetLogicalDriveStringsW) "C\x00:\x00\\\x00\x00\x00\x00\x00" else "C:\\\x00\x00");
            return 4;
        }
        if (api == .SetCurrentDirectoryW) {
            const path = w.filePath(m, s.get(1), true, false) catch |err| return w.pathError(err);
            defer w.allocator.free(path);
            const fd = host.c.open(path.ptr, host.c.O_RDONLY | host.c.O_DIRECTORY | host.c.O_CLOEXEC);
            if (fd < 0) return w.fail(switch (host.errno()) {
                host.c.ENOENT => 3,
                host.c.ENOTDIR => 267,
                else => hostError(),
            });
            defer _ = host.c.close(fd);
            const restore = w.restore_directory orelse host.c.open(".", host.c.O_RDONLY | host.c.O_DIRECTORY | host.c.O_CLOEXEC);
            if (restore < 0) return w.fail(hostError());
            if (host.c.fchdir(fd) != 0) {
                const code = hostError();
                if (w.restore_directory == null) _ = host.c.close(restore);
                return w.fail(code);
            }
            w.restore_directory = restore;
            return 1;
        }
        if (api == .GetTempPathW) {
            const path = w.guestPath(if (w.temporary_path) |value| value else "/tmp", false) catch |err| return w.pathError(err);
            defer w.allocator.free(path);
            const current = if (std.fs.path.isAbsolutePosix(path)) null else try w.directoryPath();
            defer if (current) |value| w.allocator.free(value);
            const full = try std.fs.path.resolvePosix(w.allocator, &.{ current orelse "/", path });
            defer w.allocator.free(full);
            const terminated = try std.fmt.allocPrint(w.allocator, "{s}/", .{std.mem.trimEnd(u8, full, "/")});
            defer w.allocator.free(terminated);
            return w.pathOutput(s, m, terminated);
        }
        const path = try w.directoryPath();
        defer w.allocator.free(path);
        return w.pathOutput(s, m, path);
    }
    fn directoryPath(w: *Windows) ![]u8 {
        const cwd = host.c.getcwd(null, 0);
        if (cwd == null) return if (host.errno() == host.c.ENOMEM) error.OutOfMemory else error.CannotGetWorkingDirectory;
        defer host.c.free(cwd);
        return w.guestAbsolutePath(std.mem.span(cwd));
    }
    fn guestAbsolutePath(w: *Windows, absolute: []const u8) ![]u8 {
        var path = absolute;
        if (w.sysroot) |root| {
            const physical = host.c.realpath(root.ptr, null);
            if (physical == null) return if (host.errno() == host.c.ENOMEM) error.OutOfMemory else error.CannotGetWorkingDirectory;
            defer host.c.free(physical);
            const prefix = std.mem.trimEnd(u8, std.mem.span(physical), "/");
            if (!std.mem.startsWith(u8, path, prefix) or (path.len > prefix.len and path[prefix.len] != '/')) return error.DirectoryOutsideSysroot;
            path = if (path.len == prefix.len) "/" else path[prefix.len..];
        }
        return w.allocator.dupe(u8, path);
    }
    fn pathOutput(w: *Windows, s: *State, m: *Memory, path: []const u8) !u64 {
        if (!std.unicode.utf8ValidateSlice(path)) return w.fail(1113);
        const display = try std.fmt.allocPrint(w.allocator, "C:{s}", .{path});
        defer w.allocator.free(display);
        std.mem.replaceScalar(u8, display, '/', '\\');
        const output = try std.unicode.utf8ToUtf16LeAllocZ(w.allocator, display);
        defer w.allocator.free(output);
        if (output.len >= 32768) return w.fail(206);
        const capacity: u32 = @truncate(s.get(1));
        if (capacity <= output.len) return output.len + 1;
        if (s.get(2) == 0) return w.fail(87);
        try m.write(s.get(2), std.mem.sliceAsBytes(output[0 .. output.len + 1]));
        return output.len;
    }
    fn file(w: *Windows, handle: u64) ?File {
        for (w.files.items) |entry| if (entry.handle == handle) return entry;
        return null;
    }
    fn windowsPath(w: *Windows, m: *Memory, address: u64, wide: bool, default_stream: bool) ![:0]u8 {
        if (address == 0) return error.InvalidWindowsPath;
        const raw = if (wide) try @import("../windows_process.zig").wideString(w.allocator, m, address) else try m.cstring(w.allocator, address, 131072);
        defer w.allocator.free(raw);
        return w.guestPath(raw, default_stream);
    }
    fn guestPath(w: *Windows, raw: []const u8, default_stream: bool) ![:0]u8 {
        if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidWindowsPathName;
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
        var text = if (default_stream and std.ascii.endsWithIgnoreCase(raw, "::$DATA")) raw[0 .. raw.len - 7] else raw;
        if (text.len == 0) return error.EmptyWindowsPath;
        if (text.len >= 2 and std.mem.indexOfScalar(u8, "/\\", text[0]) != null and std.mem.indexOfScalar(u8, "/\\", text[1]) != null) return error.UnsupportedWindowsPath;
        const drive = text.len >= 2 and text[1] == ':' and std.ascii.isAlphabetic(text[0]);
        if (drive) {
            // ponytail: one virtual C drive; add explicit mount mappings when multi-drive apps require them.
            if (std.ascii.toUpper(text[0]) != 'C') return error.InvalidWindowsDrive;
            text = text[2..];
        }
        if (std.mem.indexOfScalar(u8, text, ':') != null) return error.UnsupportedWindowsPath;
        const path = try w.allocator.dupeZ(u8, if (text.len == 0) "." else text);
        std.mem.replaceScalar(u8, path, '\\', '/');
        if (drive) {
            defer w.allocator.free(path);
            const current = if (std.fs.path.isAbsolutePosix(path)) null else try w.directoryPath();
            defer if (current) |value| w.allocator.free(value);
            const full = try std.fs.path.resolvePosix(w.allocator, &.{ current orelse "/", path });
            defer w.allocator.free(full);
            return std.fmt.allocPrintSentinel(w.allocator, "{s}{s}", .{ full, if (path[path.len - 1] == '/' and full.len > 1) "/" else "" }, 0);
        }
        return path;
    }
    fn filePath(w: *Windows, m: *Memory, address: u64, wide: bool, default_stream: bool) ![:0]u8 {
        try w.anchorSysroot();
        const path = try w.windowsPath(m, address, wide, default_stream);
        defer w.allocator.free(path);
        return @import("../filesystem.zig").resolve(w.allocator, w.sysroot, path);
    }
    fn pathError(w: *Windows, err: anyerror) !u64 {
        return w.fail(switch (err) {
            error.InvalidWindowsPath => 87,
            error.InvalidWindowsPathName => 123,
            error.InvalidWindowsDrive => 15,
            error.EmptyWindowsPath => 3,
            error.DirectoryOutsideSysroot => 3,
            error.CannotGetWorkingDirectory => hostError(),
            error.HostLinkReadFailed => hostError(),
            error.HostLinkChanged => 32,
            error.HostLinkTooLong => 206,
            error.UnsupportedWindowsPath => 50,
            error.InvalidUtf8, error.DanglingSurrogateHalf, error.ExpectedSecondSurrogateHalf, error.UnexpectedSecondSurrogateHalf => 1113,
            error.OutOfMemory => 8,
            else => return err,
        });
    }
    fn pendingDelete(w: *Windows, device: u64, inode: u64) bool {
        for (w.deletions.items) |entry| if (entry.device == device and entry.inode == inode) return true;
        return false;
    }
    fn sharingDelete(w: *Windows, info: host.FileStat) u32 {
        if (info.mode & host.c.S_IFMT == host.c.S_IFDIR) {
            const current = host.statAt(host.c.AT_FDCWD, ".", false) catch return hostError();
            if (current.dev == info.dev and current.ino == info.ino) return 32;
        }
        if (w.pendingDelete(info.dev, info.ino)) return 5;
        for (w.files.items) |entry| if (entry.device == info.dev and entry.inode == info.ino and entry.share & 4 == 0) return 32;
        return 0;
    }
    fn finishDelete(w: *Windows, device: u64, inode: u64) ?u32 {
        if (w.mappings.holds(device, inode)) return null;
        for (w.files.items) |entry| if (entry.device == device and entry.inode == inode) return null;
        for (w.deletions.items, 0..) |entry, index| if (entry.device == device and entry.inode == inode) {
            _ = w.deletions.swapRemove(index);
            defer _ = host.c.close(entry.directory);
            defer w.allocator.free(entry.name);
            const info = host.statAt(entry.directory, entry.name, true) catch return if (host.errno() == host.c.ENOENT) null else hostError();
            if (info.dev != device or info.ino != inode) return 13; // Never remove a host replacement at the retained name.
            if (host.c.unlinkat(entry.directory, entry.name.ptr, 0) != 0) return hostError();
            return null;
        };
        return null;
    }
    fn fileAttributes(info: host.FileStat) u32 {
        if (info.mode & host.c.S_IFMT == host.c.S_IFDIR) return 0x10;
        if (info.mode & host.c.S_IFMT == host.c.S_IFLNK) return 0x400;
        return if (info.mode & 0o222 == 0) 1 else 0x80;
    }
    fn findNext(w: *Windows, search: FileSearch, m: *Memory, destination: u64) !u64 {
        if (destination == 0) return w.fail(87);
        const before = host.c.telldir(search.directory);
        if (before < 0) return w.fail(hostError());
        var committed = false;
        // Retry the same cursor after checked memory, COW allocation or metadata failure.
        defer if (!committed) host.c.seekdir(search.directory, before);
        while (true) {
            host.resetErrno();
            const entry = host.c.readdir(search.directory) orelse {
                if (host.errno() != 0) return w.fail(hostError());
                committed = true;
                return w.fail(18);
            };
            const raw: []const u8 = entry.*.d_name[0..];
            const name = raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse return error.InvalidHostDirectoryEntry];
            const units = std.unicode.calcUtf16LeLen(name) catch return w.fail(1113);
            if (units >= 260) return w.fail(206);
            var wide: [260]u16 = @splat(0);
            _ = try std.unicode.utf8ToUtf16Le(&wide, name);
            if (!find_api.matches(search.pattern, wide[0..units])) continue;
            const info = host.statAt(host.c.dirfd(search.directory), entry.*.d_name[0..name.len :0], true) catch {
                if (host.errno() == host.c.ENOENT) continue; // A concurrently removed entry has no metadata to return.
                return w.fail(hostError());
            };
            const kind = info.mode & host.c.S_IFMT;
            if (!host.isRegular(info.mode) and kind != host.c.S_IFDIR and kind != host.c.S_IFLNK) return w.fail(50);
            if (info.size < 0) return w.fail(13);
            var bytes: [592]u8 = @splat(0);
            std.mem.writeInt(u32, bytes[0..4], fileAttributes(info), .little);
            std.mem.writeInt(u64, bytes[4..12], if (info.birthtime) |time| try time_api.fromTimestamp(time) else 0, .little);
            std.mem.writeInt(u64, bytes[12..20], try time_api.fromTimestamp(info.atime), .little);
            std.mem.writeInt(u64, bytes[20..28], try time_api.fromTimestamp(info.mtime), .little);
            const size: u64 = if (kind == host.c.S_IFDIR) 0 else @intCast(info.size);
            std.mem.writeInt(u32, bytes[28..32], @truncate(size >> 32), .little);
            std.mem.writeInt(u32, bytes[32..36], @truncate(size), .little);
            if (kind == host.c.S_IFLNK) std.mem.writeInt(u32, bytes[36..40], 0xa000000c, .little);
            @memcpy(bytes[44..][0 .. (units + 1) * 2], std.mem.sliceAsBytes(wide[0 .. units + 1]));
            try m.write(destination, &bytes);
            committed = true;
            return 1;
        }
    }
    fn findOperation(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        const handle = s.get(1);
        if (api == .FindFirstStreamW) return w.findStream(s, m);
        if (api != .FindFirstFileW) {
            if (api != .FindClose and !w.allow_files) return w.fail(5);
            for (w.searches.items, 0..) |search, index| if (search.handle == handle) {
                if (api == .FindNextFileW) return if (search.state == .files) w.findNext(search.state.files, m, s.get(2)) else w.fail(6);
                if (api == .FindNextStreamW) {
                    if (search.state != .stream) return w.fail(6);
                    if (s.get(2) == 0) return w.fail(87);
                    return w.fail(38); // The real file data was the only stream in this virtual filesystem.
                }
                _ = w.searches.swapRemove(index);
                if (search.close(w.allocator) != 0) return w.fail(hostError());
                return 1;
            };
            return w.fail(6);
        }
        if (!w.allow_files) return w.fileFail(5);
        try w.anchorSysroot();
        const path = w.windowsPath(m, handle, true, false) catch |err| {
            _ = try w.pathError(err);
            return invalid_handle;
        };
        defer w.allocator.free(path);
        const split = if (std.mem.lastIndexOfScalar(u8, path, '/')) |index| index + 1 else 0;
        if (split == path.len) return w.fileFail(123);
        if (std.mem.indexOfAny(u8, path[0..split], "*?<>\"|") != null or std.mem.indexOfAny(u8, path[split..], "<>\"|") != null) return w.fileFail(123);
        for (path) |byte| if (byte < 32) return w.fileFail(123);
        if (s.get(2) == 0) return w.fileFail(87);
        if (w.searches.items.len >= 1024) return w.fileFail(4);
        const parent = try @import("../filesystem.zig").resolve(w.allocator, w.sysroot, if (split == 0) "." else path[0..split]);
        defer w.allocator.free(parent);
        const pattern = try std.unicode.utf8ToUtf16LeAlloc(w.allocator, path[split..]);
        var published = false;
        defer if (!published) w.allocator.free(pattern);
        try w.searches.ensureUnusedCapacity(w.allocator, 1);
        const directory = host.c.opendir(parent.ptr) orelse return w.fileFail(switch (host.errno()) {
            host.c.ENOENT, host.c.ENOTDIR => 3,
            else => hostError(),
        });
        defer {
            if (!published) _ = host.c.closedir(directory);
        }
        const search = Search{ .handle = w.next_handle, .state = .{ .files = .{ .directory = directory, .pattern = pattern } } };
        if (try w.findNext(search.state.files, m, s.get(2)) == 0) return w.fileFail(if (w.last_error == 18) 2 else w.last_error);
        w.searches.appendAssumeCapacity(search);
        w.next_handle += 1;
        published = true;
        return search.handle;
    }
    fn findStream(w: *Windows, s: *State, m: *Memory) !u64 {
        if (!w.allow_files) return w.fileFail(5);
        const level: u32 = @truncate(s.get(2));
        const flags: u32 = @truncate(s.get(9));
        if (level != 0 or flags != 0 or s.get(8) == 0) return w.fileFail(87);
        try w.anchorSysroot();
        const input = w.windowsPath(m, s.get(1), true, true) catch |err| {
            _ = try w.pathError(err);
            return invalid_handle;
        };
        defer w.allocator.free(input);
        if (std.mem.indexOfAny(u8, input, "*?<>\"|") != null) return w.fileFail(123);
        for (input) |byte| if (byte < 32) return w.fileFail(123);
        const path = try @import("../filesystem.zig").resolve(w.allocator, w.sysroot, input);
        defer w.allocator.free(path);
        const info = host.statAt(host.c.AT_FDCWD, path, false) catch return w.fileFail(hostError());
        if (w.pendingDelete(info.dev, info.ino)) return w.fileFail(5);
        if (info.mode & host.c.S_IFMT == host.c.S_IFDIR) return w.fileFail(38);
        if (!host.isRegular(info.mode)) return w.fileFail(50);
        if (info.size < 0) return w.fileFail(13);
        if (w.searches.items.len >= 1024) return w.fileFail(4);
        try w.searches.ensureUnusedCapacity(w.allocator, 1);
        // Our virtual filesystem exposes file bytes as the unnamed $DATA stream.
        // ponytail: no named streams; add persistent ADS storage only alongside :name file access.
        var bytes: [600]u8 = @splat(0);
        std.mem.writeInt(u64, bytes[0..8], @intCast(info.size), .little);
        const name = std.unicode.utf8ToUtf16LeStringLiteral("::$DATA");
        @memcpy(bytes[8..][0 .. (name.len + 1) * 2], std.mem.sliceAsBytes(name[0 .. name.len + 1]));
        try m.write(s.get(8), &bytes);
        const handle = w.next_handle;
        w.searches.appendAssumeCapacity(.{ .handle = handle, .state = .stream });
        w.next_handle += 1;
        return handle;
    }
    fn diskOperation(w: *Windows, s: *State, m: *Memory, extended: bool) !u64 {
        if (!w.allow_files) return w.fail(5);
        const outputs = [_]u64{ s.get(2), s.get(8), s.get(9), if (extended) 0 else try stackArg(s, m, 4) };
        const length: usize = if (extended) 3 else 4;
        for (outputs[0..length]) |address| if (!extended or address != 0) try m.check(address, if (extended) 8 else 4, .write);
        const path = (if (s.get(1) == 0) w.allocator.dupeZ(u8, ".") else w.filePath(m, s.get(1), true, false)) catch |err| return w.pathError(err);
        defer w.allocator.free(path);
        const fd = host.c.open(path.ptr, host.c.O_RDONLY | host.c.O_DIRECTORY | host.c.O_CLOEXEC);
        if (fd < 0) return w.fail(switch (host.errno()) {
            host.c.ENOENT => 3,
            host.c.ENOTDIR => 267,
            else => hostError(),
        });
        defer _ = host.c.close(fd);
        const info = host.diskStatFd(fd) catch return w.fail(hostError());
        const values = diskValues(info, extended) catch |err| return w.fail(switch (err) {
            error.DiskSizeOverflow => 534,
            error.InvalidDiskCounts => 13,
            else => 50,
        });
        for (outputs[0..length], values[0..length]) |address, value| if (address != 0) try m.writeInt(address, if (extended) 64 else 32, value);
        return 1;
    }
    fn fileOperation(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        if (!w.allow_files) {
            _ = w.fail(5);
            return if (api == .GetFileAttributesW) 0xffffffff else 0;
        }
        const a = s.get(1);
        const b = s.get(2);
        var flags: u32 = 0;
        if (api == .MoveFileExW or api == .MoveFileWithProgressW) {
            flags = @truncate(if (api == .MoveFileExW) s.get(8) else try stackArg(s, m, 4));
            if (flags & ~@as(u32, 0xb) != 0 or (api == .MoveFileWithProgressW and s.get(8) != 0)) return w.fail(50);
        }
        if ((api == .CreateDirectoryW and b != 0) or (api == .CreateHardLinkW and s.get(8) != 0)) return w.fail(50);
        const path = w.filePath(m, a, true, false) catch |err| {
            const result = try w.pathError(err);
            return if (api == .GetFileAttributesW) 0xffffffff else result;
        };
        defer w.allocator.free(path);
        if (api == .CreateDirectoryW) {
            if (host.c.mkdir(path.ptr, 0o777) != 0) return w.fail(if (host.errno() == host.c.EEXIST) 183 else if (host.errno() == host.c.ENOENT) 3 else hostError());
            return 1; // Only the last component, never implicit parents.
        }
        if (api == .CreateHardLinkW) {
            const source_path = w.filePath(m, b, true, false) catch |err| return w.pathError(err);
            defer w.allocator.free(source_path);
            const source = host.statAt(host.c.AT_FDCWD, source_path, true) catch return w.fail(hostError());
            if (!host.isRegular(source.mode)) return w.fail(50);
            if (w.pendingDelete(source.dev, source.ino)) return w.fail(5);
            for (w.files.items) |entry| if (entry.device == source.dev and entry.inode == source.ino and entry.share & 1 == 0) return w.fail(32);
            if (source.nlink >= 1023) return w.fail(1142);
            if (host.c.link(source_path.ptr, path.ptr) != 0) return w.fail(hostError());
            return 1;
        }
        const info = host.statAt(host.c.AT_FDCWD, path, true) catch {
            _ = w.fail(hostError());
            return if (api == .GetFileAttributesW) 0xffffffff else 0;
        };
        if (!host.isRegular(info.mode) and info.mode & host.c.S_IFMT != host.c.S_IFDIR and info.mode & host.c.S_IFMT != host.c.S_IFLNK) {
            _ = w.fail(50);
            return if (api == .GetFileAttributesW) 0xffffffff else 0;
        }
        if (api == .GetFileAttributesW) return fileAttributes(info);
        if (api == .SetFileAttributesW) {
            const attributes: u32 = @truncate(b);
            if (attributes == 0 or attributes & ~@as(u32, 0x81) != 0 or !host.isRegular(info.mode)) return w.fail(50);
            const fd = host.c.open(path.ptr, host.c.O_RDONLY | host.c.O_CLOEXEC | host.c.O_NONBLOCK | host.c.O_NOFOLLOW);
            if (fd < 0) return w.fail(hostError());
            defer _ = host.c.close(fd);
            const current = host.statFd(fd) catch return w.fail(hostError());
            if (!host.isRegular(current.mode) or current.dev != info.dev or current.ino != info.ino) return w.fail(13);
            const mode = if (attributes & 1 != 0) current.mode & ~@as(u32, 0o222) else current.mode | 0o200;
            if (host.c.fchmod(fd, @intCast(mode & 0o7777)) != 0) return w.fail(hostError());
            return 1;
        }
        if (api == .RemoveDirectoryW) {
            if (info.mode & host.c.S_IFMT != host.c.S_IFDIR) return w.fail(267);
            const shared = w.sharingDelete(info);
            if (shared != 0) return w.fail(shared);
            if (host.c.rmdir(path.ptr) != 0) return w.fail(hostError());
            return 1;
        }
        if (api == .DeleteFileW) {
            if (info.mode & host.c.S_IFMT == host.c.S_IFDIR or (host.isRegular(info.mode) and info.mode & 0o222 == 0)) return w.fail(5);
            const shared = w.sharingDelete(info);
            if (shared != 0) return w.fail(shared);
            const opened = w.mappings.holds(info.dev, info.ino) or for (w.files.items) |entry| {
                if (entry.device == info.dev and entry.inode == info.ino) break true;
            } else false;
            if (opened) {
                // Keep the parent descriptor: a later rename of the directory must not redirect deletion.
                const parent = try w.allocator.dupeZ(u8, std.fs.path.dirnamePosix(path) orelse ".");
                defer w.allocator.free(parent);
                const name = try w.allocator.dupeZ(u8, std.fs.path.basenamePosix(path));
                errdefer w.allocator.free(name);
                const directory = host.c.open(parent.ptr, host.c.O_RDONLY | host.c.O_DIRECTORY | host.c.O_CLOEXEC);
                if (directory < 0) {
                    w.allocator.free(name);
                    return w.fail(hostError());
                }
                errdefer _ = host.c.close(directory);
                try w.deletions.append(w.allocator, .{ .directory = directory, .name = name, .device = info.dev, .inode = info.ino });
            } else if (host.c.unlink(path.ptr) != 0) return w.fail(hostError());
            return 1;
        }
        const other = w.filePath(m, b, true, false) catch |err| return w.pathError(err);
        defer w.allocator.free(other);
        const shared = w.sharingDelete(info);
        if (shared != 0) return w.fail(shared);
        if (flags & 1 != 0) {
            if (!host.isRegular(info.mode)) return w.fail(5);
            if (host.statAt(host.c.AT_FDCWD, other, true)) |destination| {
                if (!host.isRegular(destination.mode) or destination.mode & 0o222 == 0) return w.fail(5);
                const destination_shared = w.sharingDelete(destination);
                if (destination_shared != 0) return w.fail(destination_shared);
            } else |_| if (host.errno() != host.c.ENOENT) return w.fail(hostError());
            if (host.c.rename(path.ptr, other.ptr) != 0) return w.fail(hostError());
        } else if (host.renameExclusive(path, other) != 0) return w.fail(if (host.errno() == host.c.EEXIST) 183 else hostError());
        // Copy-across-volumes is not implemented: EXDEV returned above, even with COPY_ALLOWED.
        // WRITE_THROUGH only matters for that copy/delete path; no copy occurred here.
        return 1;
    }
    fn seekFile(w: *Windows, s: *State, m: *Memory, legacy: bool) !u64 {
        const failure: u64 = if (legacy) 0xffffffff else 0;
        const entry = w.file(s.get(1)) orelse {
            _ = w.fail(6);
            return failure;
        };
        if (entry.access == 0 or entry.metadata_only) {
            _ = w.fail(5);
            return failure;
        }
        const output = s.get(8);
        const origin: u32 = @truncate(s.get(9));
        if (origin > 2) {
            _ = w.fail(87);
            return failure;
        }
        if (output != 0) try m.check(output, if (legacy) 4 else 8, .write);
        const distance: i64 = if (!legacy) @bitCast(s.get(2)) else if (output != 0) @bitCast((try m.readInt(output, 32, .read) << 32) | (s.get(2) & 0xffffffff)) else @as(i32, @bitCast(@as(u32, @truncate(s.get(2)))));
        const base: i64 = switch (origin) {
            0 => 0,
            1 => host.c.lseek(entry.fd, 0, host.c.SEEK_CUR),
            else => (host.statFd(entry.fd) catch {
                _ = w.fail(hostError());
                return failure;
            }).size,
        };
        if (base < 0) {
            _ = w.fail(hostError());
            return failure;
        }
        const position = @as(i128, base) + distance;
        if (position < 0 or position > std.math.maxInt(i64) or (legacy and output == 0 and position > 0xffffffff)) {
            _ = w.fail(if (position < 0) 131 else 87);
            return failure;
        }
        const result = host.c.lseek(entry.fd, @intCast(position), host.c.SEEK_SET);
        if (result < 0) {
            _ = w.fail(hostError());
            return failure;
        }
        if (output != 0) try m.writeInt(output, if (legacy) 32 else 64, if (legacy) @as(u64, @intCast(result)) >> 32 else @intCast(result));
        if (legacy and @as(u32, @truncate(@as(u64, @intCast(result)))) == 0xffffffff) w.last_error = 0;
        return if (legacy) @as(u32, @truncate(@as(u64, @intCast(result)))) else 1;
    }
    fn linkTarget(w: *Windows, fd: c_int, path: [:0]const u8, info: host.FileStat) ![]u8 {
        var buffer: [8192]u8 = undefined;
        // POSIX link contents are immutable for this held inode. A host replacement
        // must acquire a new handle; the saved target survives rename and unlink.
        const length = if (@import("builtin").os.tag == .linux) host.c.readlinkat(fd, "", &buffer, buffer.len) else host.c.readlink(path.ptr, &buffer, buffer.len);
        if (length < 0) return error.HostLinkReadFailed;
        if (length == buffer.len) return error.HostLinkTooLong;
        if (@import("builtin").os.tag == .macos) {
            const after = host.statAt(host.c.AT_FDCWD, path, true) catch return error.HostLinkReadFailed;
            if (after.dev != info.dev or after.ino != info.ino) return error.HostLinkChanged;
        }
        return w.allocator.dupe(u8, buffer[0..@intCast(length)]);
    }
    fn openFile(w: *Windows, s: *State, m: *Memory, wide: bool) !u64 {
        if (!w.allow_files) return w.fileFail(5);
        const desired = s.get(2) & 0xffffffff;
        const share = s.get(8) & 0xffffffff;
        const disposition = (try stackArg(s, m, 4)) & 0xffffffff;
        const attributes = (try stackArg(s, m, 5)) & 0xffffffff;
        if (desired & ~@as(u64, 0xc0000180) != 0 or share > 7 or disposition < 1 or disposition > 5) return w.fileFail(87);
        if (s.get(9) != 0 or attributes & ~@as(u64, 0x02200080) != 0 or try stackArg(s, m, 6) != 0) return w.fileFail(50);
        const open_reparse = attributes & 0x00200000 != 0;
        if (open_reparse and disposition != 3) return w.fileFail(50);
        const access: u2 = @as(u2, @intFromBool(desired & 0x80000000 != 0)) | (@as(u2, @intFromBool(desired & 0x40000000 != 0)) << 1);
        if ((disposition == 2 or disposition == 5) and access & 2 == 0) return w.fileFail(5);
        const resolved = w.filePath(m, s.get(1), wide, true) catch |err| {
            _ = try w.pathError(err);
            return invalid_handle;
        };
        defer w.allocator.free(resolved);
        if (w.files.items.len >= 1024) return w.fileFail(4);
        try w.files.ensureUnusedCapacity(w.allocator, 1);
        const link = if (open_reparse) (host.statAt(host.c.AT_FDCWD, resolved, true) catch return w.fileFail(hostError())).mode & host.c.S_IFMT == host.c.S_IFLNK else false;
        if (link and access & 2 != 0) return w.fileFail(50);
        const flags: c_int = (if (access == 3) host.c.O_RDWR else if (access & 2 != 0) host.c.O_WRONLY else host.c.O_RDONLY) | host.c.O_CLOEXEC | host.c.O_NONBLOCK | (if (open_reparse) @as(c_int, host.c.O_NOFOLLOW) else 0);
        var created = false;
        var fd: c_int = undefined;
        if (disposition == 1 or disposition == 2 or disposition == 4) {
            fd = host.c.open(resolved.ptr, flags | host.c.O_CREAT | host.c.O_EXCL, @as(host.c.mode_t, 0o666));
            if (fd >= 0) created = true else if (host.errno() == host.c.EEXIST and disposition != 1) {
                fd = host.c.open(resolved.ptr, flags);
            }
        } else fd = if (link) host.openLink(resolved) else host.c.open(resolved.ptr, flags);
        if (fd < 0) return w.fileFail(hostError());
        var keep = false;
        defer {
            if (!keep) _ = host.c.close(fd);
        }
        const info = host.statFd(fd) catch return w.fileFail(hostError());
        const directory = info.mode & host.c.S_IFMT == host.c.S_IFDIR;
        if (link and info.mode & host.c.S_IFMT != host.c.S_IFLNK) return w.fileFail(32);
        if (!host.isRegular(info.mode) and !link and !(directory and attributes & 0x02000000 != 0 and disposition == 3 and access & 2 == 0)) return w.fileFail(50);
        const device = info.dev;
        const inode = info.ino;
        if (w.pendingDelete(device, inode) or (access & 2 != 0 and info.mode & 0o222 == 0)) return w.fileFail(5);
        for (w.files.items) |entry| if (entry.device == device and entry.inode == inode and (access & ~entry.share != 0 or entry.access & ~@as(u3, @intCast(share)) != 0)) return w.fileFail(32);
        // Check sharing before truncation, so a rejected open cannot destroy file contents.
        if ((disposition == 2 or disposition == 5) and w.mappings.holds(device, inode)) return w.fileFail(1224);
        if ((disposition == 2 or disposition == 5) and host.c.ftruncate(fd, 0) != 0) return w.fileFail(hostError());
        const target = if (link) w.linkTarget(fd, resolved, info) catch |err| {
            _ = try w.pathError(err);
            return invalid_handle;
        } else null;
        const handle = w.next_handle;
        w.next_handle += 1;
        w.files.appendAssumeCapacity(.{ .handle = handle, .fd = fd, .access = access, .share = @intCast(share), .device = device, .inode = inode, .metadata_only = directory or link, .link_target = target, .write_attributes = desired & 0x40000100 != 0 });
        keep = true;
        if (disposition == 2 or disposition == 4) w.last_error = if (created) 0 else 183;
        return handle;
    }
    fn reparseData(w: *Windows, target: []const u8) ![]u8 {
        if (!std.unicode.utf8ValidateSlice(target)) return error.InvalidUtf8;
        if (target.len == 0 or std.mem.indexOfAny(u8, target, "\\:") != null) return error.UnsupportedWindowsPath;
        const absolute = std.fs.path.isAbsolutePosix(target);
        const path = if (absolute) blk: {
            const canonical = try std.fs.path.resolvePosix(w.allocator, &.{target});
            defer w.allocator.free(canonical);
            // C-qualified paths normalize lexically. Do not misreport a host
            // absolute link containing symlink/.. traversal as an equivalent path.
            if (!std.mem.eql(u8, canonical, if (target.len > 1) std.mem.trimEnd(u8, target, "/") else target)) return error.UnsupportedWindowsPath;
            break :blk try w.guestAbsolutePath(target);
        } else try w.allocator.dupe(u8, target);
        defer w.allocator.free(path);
        const display = if (absolute) try std.fmt.allocPrint(w.allocator, "C:{s}", .{path}) else try w.allocator.dupe(u8, path);
        defer w.allocator.free(display);
        std.mem.replaceScalar(u8, display, '/', '\\');
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(w.allocator, display);
        defer w.allocator.free(wide);
        const name_bytes = wide.len * 2;
        const substitute_bytes = name_bytes + @as(usize, if (absolute) 8 else 0);
        const size = 24 + substitute_bytes + name_bytes;
        if (size > 16384) return error.HostLinkTooLong;
        const bytes = try w.allocator.alloc(u8, size);
        @memset(bytes, 0);
        std.mem.writeInt(u32, bytes[0..4], 0xa000000c, .little); // IO_REPARSE_TAG_SYMLINK
        std.mem.writeInt(u16, bytes[4..6], @intCast(size - 8), .little);
        std.mem.writeInt(u16, bytes[10..12], @intCast(substitute_bytes), .little);
        std.mem.writeInt(u16, bytes[12..14], @intCast(substitute_bytes + 2), .little);
        std.mem.writeInt(u16, bytes[14..16], @intCast(name_bytes), .little);
        std.mem.writeInt(u32, bytes[16..20], @intFromBool(!absolute), .little);
        const prefix = [_]u16{ '\\', '?', '?', '\\' };
        if (absolute) @memcpy(bytes[20..28], std.mem.sliceAsBytes(&prefix));
        @memcpy(bytes[20 + substitute_bytes - name_bytes ..][0..name_bytes], std.mem.sliceAsBytes(wide));
        @memcpy(bytes[22 + substitute_bytes ..][0..name_bytes], std.mem.sliceAsBytes(wide));
        return bytes;
    }
    fn deviceControl(w: *Windows, s: *State, m: *Memory) !u64 {
        if (!w.allow_files) return w.fail(5);
        const entry = w.file(s.get(1)) orelse return w.fail(6);
        const returned = try stackArg(s, m, 6);
        if (returned == 0) return w.fail(87);
        try m.writeInt(returned, 32, 0);
        const code: u32 = @truncate(s.get(2));
        if (code != 0x900a8) return w.fail(50); // FSCTL_GET_REPARSE_POINT only; never pass IOCTLs to the host.
        if (@as(u32, @truncate(s.get(9))) != 0) return w.fail(87);
        const target = entry.link_target orelse return w.fail(4390); // ERROR_NOT_A_REPARSE_POINT
        const bytes = w.reparseData(target) catch |err| return if (err == error.DirectoryOutsideSysroot) w.fail(50) else w.pathError(err);
        defer w.allocator.free(bytes);
        const capacity: u32 = @truncate(try stackArg(s, m, 5));
        // ponytail: whole-record replies; add NTFS partial-buffer replies when an app needs them.
        if (capacity < bytes.len) return w.fail(122);
        const output = try stackArg(s, m, 4);
        if (output == 0) return w.fail(87);
        // All owned files are synchronous; lpOverlapped is ignored, including address 1.
        // Preparing the count destination above prevents a later COW failure after the record write.
        try m.write(output, bytes);
        try m.writeInt(returned, 32, bytes.len);
        return 1;
    }
    fn fileIO(w: *Windows, s: *State, m: *Memory, read_file: bool) !u64 {
        const out = s.get(9);
        if (out == 0) return w.fail(87);
        try m.writeInt(out, 32, 0);
        const handle = s.get(1);
        const regular = w.file(handle);
        var fd: c_int = undefined;
        if (handle >= 0x100 and handle <= 0x102) {
            const index: usize = @intCast(handle - 0x100);
            if (w.closed_standard[index]) return w.fail(6);
            if ((read_file and index != 0) or (!read_file and index == 0)) return w.fail(5);
            fd = @intCast(index);
        } else {
            const entry = regular orelse return w.fail(6);
            if (entry.metadata_only or entry.access & @as(u2, if (read_file) 1 else 2) == 0) return w.fail(5);
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
        const retained = if (regular) |entry| if (entry.preserve_access or entry.preserve_write) host.statFd(fd) catch return w.fail(hostError()) else null else null;
        var n: isize = undefined;
        while (true) {
            n = if (read_file) host.c.read(fd, bytes.ptr, bytes.len) else host.c.write(fd, bytes.ptr, bytes.len);
            if (n >= 0 or host.errno() != host.c.EINTR) break;
            if (w.console.hasEvent()) return w.fail(995);
        }
        if (n < 0) return w.fail(hostError());
        if (read_file) try m.write(buffer, bytes[0..@intCast(n)]);
        try m.writeInt(out, 32, @intCast(n));
        if (retained) |info| if (restoreFileTime(regular.?, info) != 0) return w.fail(hostError());
        return 1;
    }
    fn restoreFileTime(entry: File, info: host.FileStat) c_int {
        return host.setFileTimes(entry.fd, null, if (entry.preserve_access) info.atime else null, if (entry.preserve_write) info.mtime else null);
    }
    fn writeSystemTime(m: *Memory, pointer: u64, fields: [8]u16) !void {
        var bytes: [16]u8 = undefined;
        for (fields, 0..) |field, index| std.mem.writeInt(u16, bytes[index * 2 ..][0..2], field, .little);
        try m.write(pointer, &bytes);
    }
    fn timeOperation(w: *Windows, s: *State, m: *Memory, api: Api) !u64 {
        const a = s.get(1);
        const b = s.get(2);
        if (api == .CompareFileTime) {
            const first: i64 = @bitCast(try m.readInt(a, 64, .read));
            const second: i64 = @bitCast(try m.readInt(b, 64, .read));
            return if (first < second) 0xffffffff else @intFromBool(first > second);
        }
        if (api == .GetSystemTimeAsFileTime or api == .GetSystemTimePreciseAsFileTime or api == .GetSystemTime or api == .GetLocalTime) {
            const scalar = api == .GetSystemTimeAsFileTime or api == .GetSystemTimePreciseAsFileTime;
            try m.check(a, if (scalar) 8 else 16, .write);
            const now = try host.clock(.realtime);
            var ticks = try time_api.fromTimestamp(now);
            if (api == .GetLocalTime) ticks = try time_api.shift(ticks, try host.localOffset(now.sec));
            if (scalar) try m.writeInt(a, 64, ticks) else try writeSystemTime(m, a, try time_api.toSystemTime(ticks));
            return 0; // Void API, not a BOOL.
        }
        if (api == .GetProcessTimes) {
            if (a != invalid_handle) return w.fail(6);
            const pointers = [_]u64{ b, s.get(8), s.get(9), try stackArg(s, m, 4) };
            for (pointers) |pointer| try m.check(pointer, 8, .write);
            const cpu = try host.cpuTimes();
            const kernel = std.math.sub(u64, cpu.kernel, w.cpu_started.kernel) catch return error.HostCpuClockFailed;
            const user = std.math.sub(u64, cpu.user, w.cpu_started.user) catch return error.HostCpuClockFailed;
            for (pointers, [_]u64{ w.created_time, 0, kernel, user }) |pointer, value| try m.writeInt(pointer, 64, value);
            return 1;
        }
        if (api == .GetFileTime or api == .SetFileTime) {
            const entry = w.file(a) orelse return w.fail(6);
            const pointers = [_]u64{ b, s.get(8), s.get(9) };
            if (api == .GetFileTime) {
                for (pointers) |pointer| if (pointer != 0) try m.check(pointer, 8, .write);
                const info = host.statFd(entry.fd) catch return w.fail(hostError());
                const values = [_]u64{ if (info.birthtime) |creation| try time_api.fromTimestamp(creation) else 0, try time_api.fromTimestamp(info.atime), try time_api.fromTimestamp(info.mtime) };
                for (pointers, values) |pointer, value| if (pointer != 0) try m.writeInt(pointer, 64, value);
                return 1;
            }
            if (!w.allow_files or entry.metadata_only or (!entry.write_attributes and entry.access & 2 == 0)) return w.fail(5);
            var times: [3]?host.Timestamp = @splat(null);
            var freeze: [2]bool = @splat(false);
            for (pointers, 0..) |pointer, index| if (pointer != 0) {
                const ticks = try m.readInt(pointer, 64, .read);
                if (ticks == 0) continue;
                if (ticks == invalid_handle and index != 0) freeze[index - 1] = true else times[index] = time_api.toTimestamp(ticks) catch return w.fail(87);
            };
            if (host.setFileTimes(entry.fd, times[0], times[1], times[2]) != 0) return w.fail(hostError());
            for (w.files.items) |*record| if (record.handle == a) {
                record.preserve_access = record.preserve_access or freeze[0];
                record.preserve_write = record.preserve_write or freeze[1];
                break;
            };
            return 1;
        }
        const source: u64 = if (api == .DosDateTimeToFileTime) s.get(8) else b;
        if (api == .FileTimeToDosDateTime) {
            try m.check(b, 2, .write);
            try m.check(s.get(8), 2, .write);
            const dos = time_api.toDos(try m.readInt(a, 64, .read)) catch return w.fail(87);
            try m.writeInt(b, 16, dos[0]);
            try m.writeInt(s.get(8), 16, dos[1]);
        } else if (api == .DosDateTimeToFileTime) {
            try m.check(source, 8, .write);
            const ticks = time_api.fromDos(@truncate(a), @truncate(b)) catch return w.fail(87);
            try m.writeInt(source, 64, ticks);
        } else if (api == .SystemTimeToFileTime) {
            try m.check(a, 16, .read);
            try m.check(b, 8, .write);
            var fields: [8]u16 = undefined;
            for (&fields, 0..) |*field, index| field.* = @intCast(try m.readInt(a + index * 2, 16, .read));
            const ticks = time_api.fromSystemTime(fields) catch return w.fail(87);
            try m.writeInt(b, 64, ticks);
        } else if (api == .FileTimeToSystemTime) {
            try m.check(b, 16, .write);
            const fields = time_api.toSystemTime(try m.readInt(a, 64, .read)) catch return w.fail(87);
            try writeSystemTime(m, b, fields);
        } else {
            if (a == b) return w.fail(87); // The documented legacy local/UTC APIs prohibit identical pointers.
            try m.check(b, 8, .write);
            const ticks = try m.readInt(a, 64, .read);
            const offset = try host.localOffset((try host.clock(.realtime)).sec);
            const result = time_api.shift(ticks, if (api == .LocalFileTimeToFileTime) -offset else offset) catch return w.fail(87);
            try m.writeInt(b, 64, result);
        }
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
            if (amount < 0 and host.errno() == host.c.EINTR) {
                if (!w.console.hasEvent()) continue;
                try crtFlag(m, index, 0x20);
                _ = try crtFail(m, 4, 0);
                return null;
            }
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
        if (name) |value| if (w.mappings.named(value) != null) return w.fail(6);
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
            .FindFirstFileW, .FindNextFileW, .FindClose, .FindFirstStreamW, .FindNextStreamW => return w.findOperation(s, m, api) catch |err| {
                _ = w.fail(switch (err) {
                    error.OutOfMemory, error.MemoryLimit => 8,
                    error.WindowsFileTimeOutOfRange => 87,
                    else => return err,
                });
                return if (api == .FindFirstFileW or api == .FindFirstStreamW) invalid_handle else 0;
            },
            .SetCurrentDirectoryW, .GetCurrentDirectoryW, .GetTempPathW, .GetLogicalDriveStringsW, .GetLogicalDriveStringsA, .GetLogicalDrives => return w.directoryOperation(s, m, api) catch |err| switch (err) {
                error.OutOfMemory, error.MemoryLimit => w.fail(8),
                error.DirectoryOutsideSysroot => w.fail(3),
                error.CannotGetWorkingDirectory => w.fail(hostError()),
                else => return err,
            },
            .FormatMessageW => return w.messageOperation(s, m) catch |err| return w.fail(switch (err) {
                error.InvalidParameter => 87,
                error.UnsupportedMessageFormat => 50,
                error.MessageTooLong => 234,
                error.InvalidMessageEncoding => 1113,
                error.OutOfMemory, error.MemoryLimit => 8,
                else => return err,
            }),
            .LocalAlloc, .LocalFree, .LocalLock, .LocalUnlock, .LocalSize, .LocalFlags, .LocalHandle, .LocalReAlloc => return w.localOperation(s, m, api) catch |err| switch (err) {
                error.OutOfMemory, error.MemoryLimit => blk: {
                    _ = w.fail(8);
                    break :blk if (api == .LocalFree) a else 0;
                },
                else => return err,
            },
            .GetModuleFileNameA, .GetModuleFileNameW => return w.moduleFilename(s, m, api == .GetModuleFileNameW) catch |err| switch (err) {
                error.OutOfMemory, error.MemoryLimit => w.fail(8),
                else => return err,
            },
            .MultiByteToWideChar, .WideCharToMultiByte => return w.encodingOperation(s, m, api == .WideCharToMultiByte),
            .GetDiskFreeSpaceExW, .GetDiskFreeSpaceW => return w.diskOperation(s, m, api == .GetDiskFreeSpaceExW),
            .CreateFileMappingW, .OpenFileMappingW, .MapViewOfFile, .MapViewOfFileEx, .UnmapViewOfFile, .FlushViewOfFile, .GetSystemInfo, .GetNativeSystemInfo => return w.mappingOperation(s, m, api),
            .GetConsoleMode, .SetConsoleMode, .GetConsoleScreenBufferInfo, .SetConsoleCtrlHandler, .SetFileApisToOEM, .SetFileApisToANSI, .AreFileApisANSI, .GetConsoleCP, .GetConsoleOutputCP, .SetConsoleCP, .SetConsoleOutputCP, .GetFileType => return w.consoleOperation(s, m, api),
            .LocalFileTimeToFileTime, .FileTimeToLocalFileTime, .FileTimeToSystemTime, .SystemTimeToFileTime, .FileTimeToDosDateTime, .DosDateTimeToFileTime, .CompareFileTime, .GetSystemTimeAsFileTime, .GetSystemTimePreciseAsFileTime, .GetSystemTime, .GetLocalTime, .GetProcessTimes, .GetFileTime, .SetFileTime => return w.timeOperation(s, m, api),
            .MoveFileW, .MoveFileExW, .MoveFileWithProgressW, .CreateDirectoryW, .RemoveDirectoryW, .DeleteFileW, .CreateHardLinkW, .GetFileAttributesW, .SetFileAttributesW => return w.fileOperation(s, m, api) catch |err| switch (err) {
                error.OutOfMemory => blk: {
                    _ = w.fail(8);
                    break :blk if (api == .GetFileAttributesW) @as(u64, 0xffffffff) else 0;
                },
                else => return err,
            },
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
            .IsProcessorFeaturePresent => return switch (@as(u32, @truncate(a))) {
                2, 3, 8, 14 => 1, // Virtual CPUID: CX8, MMX, TSC and CX16.
                9, 12 => 1, // AMD64 address translation and checked non-executable guest pages.
                else => 0, // Incomplete SIMD/FPU profiles and unknown features are not advertised.
            },
            .GlobalMemoryStatusEx => {
                if (try m.readInt(a, 32, .read) != 64) return w.fail(87);
                try m.check(a, 64, .write);
                const total_virtual: u64 = 0x800000000000 - 65536;
                var occupied: u64 = 0;
                for (m.regions.items) |region| occupied += @min(region.address + region.data.len, 0x800000000000) -| @max(region.address, 65536);
                const available = m.limit -| m.used;
                var bytes: [64]u8 = @splat(0);
                std.mem.writeInt(u32, bytes[0..4], 64, .little);
                std.mem.writeInt(u32, bytes[4..8], if (m.limit == 0) 100 else @intCast(@min(100, @as(u128, m.used) * 100 / m.limit)), .little);
                // Guest backing/commit budget, not native RAM or an invented paging file.
                for ([_]u64{ m.limit, available, m.limit, available, total_virtual, total_virtual - occupied, 0 }, 0..) |value, index| std.mem.writeInt(u64, bytes[8 + index * 8 ..][0..8], value, .little);
                try m.write(a, &bytes);
                return 1;
            },
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
            .DeviceIoControl => return w.deviceControl(s, m),
            .CreateFileA, .CreateFileW => return w.openFile(s, m, api == .CreateFileW),
            .CloseHandle => {
                if (a == invalid_handle or a == current_thread) return 1; // Pseudo handles are borrowed.
                if (w.mappings.close(w.allocator, a)) {
                    if (w.finishMappingDeletes()) |code| return w.fail(code);
                    return 1;
                }
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
                    const result = entry.close(w.allocator);
                    _ = w.files.swapRemove(index);
                    if (result != 0) return w.fail(hostError());
                    if (w.finishDelete(entry.device, entry.inode)) |code| return w.fail(code);
                    return 1;
                };
                return w.fail(6);
            },
            .GetFileSizeEx, .GetFileSize => {
                const failure: u64 = if (api == .GetFileSize) 0xffffffff else 0;
                const entry = w.file(a) orelse {
                    _ = w.fail(6);
                    return failure;
                };
                if (entry.metadata_only) {
                    _ = w.fail(50);
                    return failure;
                }
                if (b != 0 or api == .GetFileSizeEx) try m.check(b, if (api == .GetFileSize) 4 else 8, .write);
                const info = host.statFd(entry.fd) catch {
                    _ = w.fail(hostError());
                    return failure;
                };
                const size: u64 = @intCast(info.size);
                if (b != 0) try m.writeInt(b, if (api == .GetFileSize) 32 else 64, if (api == .GetFileSize) size >> 32 else size);
                if (api == .GetFileSize and @as(u32, @truncate(size)) == 0xffffffff) w.last_error = 0;
                return if (api == .GetFileSize) @as(u32, @truncate(size)) else 1;
            },
            .GetFileInformationByHandle => {
                const entry = w.file(a) orelse return w.fail(6);
                try m.check(b, 52, .write);
                const info = host.statFd(entry.fd) catch return w.fail(hostError());
                var bytes: [52]u8 = @splat(0);
                std.mem.writeInt(u32, bytes[0..4], fileAttributes(info), .little);
                std.mem.writeInt(u64, bytes[4..12], if (info.birthtime) |time| try time_api.fromTimestamp(time) else 0, .little);
                std.mem.writeInt(u64, bytes[12..20], try time_api.fromTimestamp(info.atime), .little);
                std.mem.writeInt(u64, bytes[20..28], try time_api.fromTimestamp(info.mtime), .little);
                std.mem.writeInt(u32, bytes[28..32], @truncate(info.dev ^ (info.dev >> 32)), .little);
                std.mem.writeInt(u32, bytes[32..36], @intCast(@as(u64, @intCast(info.size)) >> 32), .little);
                std.mem.writeInt(u32, bytes[36..40], @truncate(@as(u64, @intCast(info.size))), .little);
                std.mem.writeInt(u32, bytes[40..44], @truncate(info.nlink), .little);
                std.mem.writeInt(u32, bytes[44..48], @truncate(info.ino >> 32), .little);
                std.mem.writeInt(u32, bytes[48..52], @truncate(info.ino), .little);
                try m.write(b, &bytes);
                return 1;
            },
            .SetFilePointerEx, .SetFilePointer => return w.seekFile(s, m, api == .SetFilePointer),
            .SetEndOfFile => {
                const entry = w.file(a) orelse return w.fail(6);
                if (!w.allow_files or entry.metadata_only or entry.access & 2 == 0) return w.fail(5);
                if (w.mappings.holds(entry.device, entry.inode)) return w.fail(1224);
                const retained = if (entry.preserve_access or entry.preserve_write) host.statFd(entry.fd) catch return w.fail(hostError()) else null;
                const position = host.c.lseek(entry.fd, 0, host.c.SEEK_CUR);
                if (position < 0 or host.c.ftruncate(entry.fd, position) != 0) return w.fail(hostError());
                if (retained) |info| if (restoreFileTime(entry, info) != 0) return w.fail(hostError());
                return 1;
            },
            .FlushFileBuffers => {
                const entry = w.file(a) orelse return w.fail(6);
                if (entry.metadata_only or entry.access & 2 == 0) return w.fail(5);
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
fn messageAllocationProbe(allocator: std.mem.Allocator, allocated: bool, cow: bool, inserts: bool, narrow: bool) !void {
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    const backing = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0xaa);
    if (cow) try m.borrow(0x2000, backing, .{ .read = true, .write = true }, true, null);
    const destination: u64 = if (cow) 0x2ffc else 0x1400;
    const initial: u64 = if (cow) 0xaaaaaaaaaaaaaaaa else 0xcafecafecafecafe;
    if (!cow) try m.writeInt(destination, 64, initial);
    const source = if (narrow) std.unicode.utf8ToUtf16LeStringLiteral("abc%1!hs!%0ignored") else std.unicode.utf8ToUtf16LeStringLiteral("abc%1%0ignored");
    try m.write(0x1100, std.mem.sliceAsBytes(source[0 .. source.len + 1]));
    try m.writeInt(0x1828, 64, destination);
    try m.writeInt(0x1830, 64, 256);
    const value = std.unicode.utf8ToUtf16LeStringLiteral("%1");
    try m.write(0x1300, if (narrow) "%1\x00" else std.mem.sliceAsBytes(value[0 .. value.len + 1]));
    try m.writeInt(0x1700, 64, 0x1300);
    try m.writeInt(0x1838, 64, if (inserts) 0x1700 else 0xdead0000); // IGNORE_INSERTS never dereferences arguments.
    var w = Windows{ .allocator = allocator, .module_base = 0x400000, .last_error = 777 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(4, 0x1800);
    s.set(1, @as(u64, 0xffffffff00000000) | @as(u64, if (inserts) 0x2400 else 0x600) | @as(u64, if (allocated) 0x100 else 0));
    s.set(2, 0x1100);
    const used = m.used;
    const result = try w.perform(&s, &m, .FormatMessageW);
    if (result == 0) {
        try std.testing.expectEqual(@as(u32, 8), w.last_error);
        try std.testing.expectEqual(initial, try m.readInt(destination, 64, .read));
        try std.testing.expectEqual(used, m.used);
        try std.testing.expectEqual(@as(usize, 0), w.allocations.items.len);
        if (cow) for (backing) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, 5), result);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    const pointer = if (allocated) try m.readInt(destination, 64, .read) else destination;
    try std.testing.expectEqual(@as(u64, 0x0025006300620061), try m.readInt(pointer, 64, .read));
    try std.testing.expectEqual(@as(u64, 0x0031), try m.readInt(pointer + 8, 32, .read));
    if (allocated) {
        s.set(1, pointer);
        try std.testing.expectEqual(@as(u64, 512), try w.perform(&s, &m, .LocalSize));
        try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalFree));
        try std.testing.expectEqual(used, m.used);
    }
    if (cow) for (backing) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
}
fn reparseAllocationProbe(allocator: std.mem.Allocator, cow: bool) !void {
    var template = "/tmp/universe-reparse-XXXXXX".*;
    const temporary = host.c.mkstemp(&template);
    try std.testing.expect(temporary >= 0);
    _ = host.c.close(temporary);
    _ = host.c.unlink(&template);
    try std.testing.expectEqual(@as(c_int, 0), host.c.symlink("é🚀", &template));
    defer _ = host.c.unlink(&template);
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var backing: [12288]u8 = @splat(0xaa);
    try m.borrow(0x3000, &backing, .{ .read = true, .write = true }, cow, null);
    try m.write(0x1100, &template);
    var w = Windows{ .allocator = allocator, .module_base = 0x400000, .allow_files = true, .last_error = 777 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(4, 0x1800);
    s.set(1, 0x1100);
    s.set(8, 7);
    try m.writeInt(0x1828, 64, 3);
    try m.writeInt(0x1830, 64, 0x02200000);
    const handle = try w.perform(&s, &m, .CreateFileA);
    if (handle == invalid_handle and w.last_error == 8) {
        try std.testing.expectEqual(@as(usize, 0), w.files.items.len);
        try std.testing.expectEqual(@as(u64, 0x10000), w.next_handle);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, 0x10000), handle);
    const fd = w.files.items[0].fd;
    try std.testing.expectEqualSlices(u8, "é🚀", w.files.items[0].link_target.?);
    try std.testing.expectEqual(@as(c_int, 0), host.c.unlink(&template));
    try std.testing.expectEqual(@as(c_int, 0), host.c.symlink("host replacement", &template));
    try std.testing.expect((try host.statFd(fd)).ino != (try host.statAt(host.c.AT_FDCWD, std.mem.sliceTo(&template, 0), true)).ino);
    s.set(1, handle);
    s.set(2, 0x900a8);
    s.set(8, 1); // Unused input pointer is not dereferenced.
    s.set(9, 0xffffffff00000000);
    try m.writeInt(0x1828, 64, 0x4ffe);
    try m.writeInt(0x1830, 64, 0xffffffff00004000);
    try m.writeInt(0x1838, 64, 0x3100);
    try m.writeInt(0x1840, 64, 1); // Synchronous handles ignore OVERLAPPED.
    const result = w.perform(&s, &m, .DeviceIoControl) catch |err| {
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try m.readInt(0x4ffe, 64, .read));
        if (cow) try std.testing.expectEqualSlices(u8, &@as([12288]u8, @splat(0xaa)), &backing);
        return err;
    };
    if (result == 0 and w.last_error == 8) {
        try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x3100, 32, .read));
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try m.readInt(0x4ffe, 64, .read));
        if (cow) try std.testing.expectEqualSlices(u8, &@as([12288]u8, @splat(0xaa)), &backing);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, 1), result);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    try std.testing.expectEqual(@as(u64, 36), try m.readInt(0x3100, 32, .read));
    try std.testing.expectEqual(@as(u64, 0xa000000c), try m.readInt(0x4ffe, 32, .read));
    try std.testing.expectEqual(@as(u64, 1), try m.readInt(0x500e, 32, .read));
    try std.testing.expectEqual(@as(u64, 0xde80d83d00e9), try m.readInt(0x5012, 64, .read));
    if (cow) try std.testing.expectEqualSlices(u8, &@as([12288]u8, @splat(0xaa)), &backing);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .CloseHandle));
    try std.testing.expectEqual(@as(c_int, -1), host.c.fcntl(fd, host.c.F_GETFD));
    try std.testing.expectEqual(@as(usize, 0), w.files.items.len);
}
test "reparse handles and whole records preserve ownership under allocation and COW failure" {
    for ([_]bool{ false, true }) |cow| try std.testing.checkAllAllocationFailures(std.testing.allocator, reparseAllocationProbe, .{cow});
}
test "reparse records bound UTF-16 names and represent absolute root links" {
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000 };
    defer w.deinit();
    const root = try w.reparseData("/");
    defer w.allocator.free(root);
    try std.testing.expectEqual(@as(usize, 44), root.len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, root[16..20], .little));
    try std.testing.expectEqualSlices(u8, "C\x00:\x00\\\x00", root[36..42]);
    var target: [4091]u8 = @splat('a');
    const maximum = try w.reparseData(target[0..4090]);
    defer w.allocator.free(maximum);
    try std.testing.expectEqual(@as(usize, 16384), maximum.len);
    try std.testing.expectError(error.HostLinkTooLong, w.reparseData(&target));
    for ([_][]const u8{ "", "host:stream", "literal\\name", "/directory/../target" }) |invalid| try std.testing.expectError(error.UnsupportedWindowsPath, w.reparseData(invalid));
    try std.testing.expectError(error.InvalidUtf8, w.reparseData("\xff"));
}
test "reparse output and count faults cannot partially overwrite a caller record" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000, .allow_files = true, .last_error = 777 };
    defer w.deinit();
    const fd = host.c.open("/dev/null", host.c.O_RDONLY | host.c.O_CLOEXEC);
    try std.testing.expect(fd >= 0);
    try w.files.append(w.allocator, .{ .handle = 0x10000, .fd = fd, .access = 0, .share = 7, .device = 0, .inode = 0, .metadata_only = true, .link_target = try w.allocator.dupe(u8, "target") });
    var s = State{ .architecture = .x86_64 };
    s.set(4, 0x1800);
    s.set(1, 0x10000);
    s.set(2, 0x900a8);
    try m.writeInt(0x1828, 64, 0x1ffe);
    try m.writeInt(0x1830, 64, 16384);
    try m.writeInt(0x1838, 64, 0x1400);
    try m.writeInt(0x1ffe, 16, 0xbeef);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .DeviceIoControl));
    try std.testing.expectEqual(@as(u64, 0xbeef), try m.readInt(0x1ffe, 16, .read));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1400, 32, .read));
    try m.writeInt(0x1838, 64, 0x1ffe);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .DeviceIoControl));
    try std.testing.expectEqual(@as(u64, 0xbeef), try m.readInt(0x1ffe, 16, .read));
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
}
test "message failures preserve caller buffers and reclaim unpublished local allocations" {
    for ([_]bool{ false, true }) |allocated| for ([_]bool{ false, true }) |cow| for ([_]bool{ false, true }) |inserts| for ([_]bool{ false, true }) |narrow| {
        if (!inserts and narrow) continue;
        try std.testing.checkAllAllocationFailures(std.testing.allocator, messageAllocationProbe, .{ allocated, cow, inserts, narrow });
    };
}
fn filenameAllocationProbe(allocator: std.mem.Allocator) !void {
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    var w = Windows{ .allocator = allocator, .module_base = 0x400000, .last_error = 777, .linker = .{ .allocator = std.testing.allocator } };
    defer w.deinit();
    try w.linker.?.modules.append(std.testing.allocator, .{ .name = try std.testing.allocator.dupe(u8, "é🚀.exe"), .path = try std.testing.allocator.dupe(u8, "/é🚀.exe"), .base = 0x400000, .size = 4096, .entry = 0, .imports = .{ .rva = 0, .size = 0 }, .exports = .{ .rva = 0, .size = 0 } });
    var s = State{ .architecture = .x86_64 };
    s.set(2, 0x1100);
    s.set(8, 0xffffffff00000009);
    try m.writeInt(0x1100, 64, 0xabcdef0123456789);
    const result = try w.perform(&s, &m, .GetModuleFileNameW);
    if (result == 0 and w.last_error == 8) {
        try std.testing.expectEqual(@as(u64, 0xabcdef0123456789), try m.readInt(0x1100, 64, .read));
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, 8), result);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    try std.testing.expectEqual(@as(u64, 0xde80d83d00e9002f), try m.readInt(0x1100, 64, .read));
    try m.writeInt(0x1100, 64, 0xabcdef0123456789);
    s.set(8, 12);
    const ansi = try w.perform(&s, &m, .GetModuleFileNameA);
    if (ansi == 0 and w.last_error == 8) {
        try std.testing.expectEqual(@as(u64, 0xabcdef0123456789), try m.readInt(0x1100, 64, .read));
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, 11), ansi);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    var backing: [8192]u8 = @splat(0xaa);
    try m.borrow(0x3000, &backing, .{ .read = true, .write = true }, true, null);
    s.set(2, 0x3ffe);
    s.set(8, 9);
    const copy = try w.perform(&s, &m, .GetModuleFileNameW);
    try std.testing.expectEqualSlices(u8, &@as([8192]u8, @splat(0xaa)), &backing);
    if (copy == 0 and w.last_error == 8) {
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try m.readInt(0x3ffe, 64, .read));
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, 8), copy);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    try std.testing.expectEqual(@as(u64, 0xde80d83d00e9002f), try m.readInt(0x3ffe, 64, .read));
    w.allocator = std.testing.allocator; // Remaining checks inject memory faults rather than allocation failures.
    s.set(2, 0x1ff8);
    try m.writeInt(0x1ff8, 64, 0xabcdef0123456789);
    for ([_]Api{ .GetModuleFileNameA, .GetModuleFileNameW }) |api| {
        s.set(8, 32);
        try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, api));
        try std.testing.expectEqual(@as(u64, 0xabcdef0123456789), try m.readInt(0x1ff8, 64, .read));
        try std.testing.expectEqual(@as(u32, 777), w.last_error);
    }
    s.set(8, 0);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .GetModuleFileNameW));
    try std.testing.expectEqual(@as(u32, 122), w.last_error);
    s.set(8, 9);
    s.set(2, 0);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .GetModuleFileNameW));
    try std.testing.expectEqual(@as(u32, 87), w.last_error);
    s.set(2, 0x1100);
    s.set(1, 0x1234);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .GetModuleFileNameW));
    try std.testing.expectEqual(@as(u32, 126), w.last_error);
    s.set(1, Builtin.kernel32.handle());
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .GetModuleFileNameW));
    try std.testing.expectEqual(@as(u32, 50), w.last_error);
}
fn streamAllocationProbe(allocator: std.mem.Allocator, cow: bool, suffix: bool, drive: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(path);
    const fd = host.c.open(path.ptr, host.c.O_RDWR | host.c.O_CREAT | host.c.O_EXCL | host.c.O_CLOEXEC, @as(host.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = host.c.close(fd);
    const size = (@as(i64, 1) << 32) + 17;
    try std.testing.expectEqual(@as(c_int, 0), host.c.ftruncate(fd, size));
    const query = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}", .{ if (drive) "C:" else "", path, if (suffix) "::$dAtA" else "" });
    defer std.testing.allocator.free(query);
    const source = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, query);
    defer std.testing.allocator.free(source);
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.write(0x1100, std.mem.sliceAsBytes(source[0 .. source.len + 1]));
    var backing: [8192]u8 = @splat(0xaa);
    try m.borrow(0x3000, &backing, .{ .read = true, .write = true }, cow, null);
    var w = Windows{ .allocator = allocator, .module_base = 0x400000, .last_error = 777, .allow_files = true };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0x1100);
    s.set(2, 0xffffffff00000000); // Both SDK DWORD arguments ignore their high half.
    s.set(8, 0x3ffe);
    s.set(9, 0xffffffff00000000);
    const handle = try w.perform(&s, &m, .FindFirstStreamW);
    var output: [600]u8 = undefined;
    try m.read(0x3ffe, &output, .read);
    if (handle == invalid_handle and w.last_error == 8) {
        try std.testing.expectEqual(@as(usize, 0), w.searches.items.len);
        try std.testing.expectEqual(@as(u64, 0x10000), w.next_handle);
        try std.testing.expectEqualSlices(u8, &@as([600]u8, @splat(0xaa)), &output);
        try std.testing.expectEqualSlices(u8, &@as([8192]u8, @splat(0xaa)), &backing);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, 0x10000), handle);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    var expected: [600]u8 = @splat(0);
    std.mem.writeInt(u64, expected[0..8], size, .little);
    @memcpy(expected[8..24], ":\x00:\x00$\x00D\x00A\x00T\x00A\x00\x00\x00");
    try std.testing.expectEqualSlices(u8, &expected, &output);
    s.set(1, handle);
    s.set(2, 0x3ffe);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .FindNextStreamW));
    try std.testing.expectEqual(@as(u32, 38), w.last_error);
    try m.read(0x3ffe, &output, .read);
    try std.testing.expectEqualSlices(u8, &expected, &output);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .CloseHandle));
    try std.testing.expectEqual(@as(u32, 6), w.last_error);
    w.allow_files = false;
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .FindClose));
    try std.testing.expectEqual(@as(usize, 0), w.searches.items.len);
    if (cow) try std.testing.expectEqualSlices(u8, &@as([8192]u8, @splat(0xaa)), &backing);
}
test "stream snapshots use real sparse sizes and publish atomically under allocation and COW failure" {
    for ([_]bool{ false, true }) |cow| for ([_]bool{ false, true }) |suffix| for ([_]bool{ false, true }) |drive|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, streamAllocationProbe, .{ cow, suffix, drive });
}
test "stream output faults do not publish handles and search kinds cannot consume one another" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    const source = std.unicode.utf8ToUtf16LeStringLiteral("src/syscall/windows.zig");
    try m.write(0x1100, std.mem.sliceAsBytes(source[0 .. source.len + 1]));
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000, .last_error = 777, .allow_files = true };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0x1100);
    s.set(8, 0x1ffe);
    try m.writeInt(0x1ffe, 16, 0xbeef);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .FindFirstStreamW));
    try std.testing.expectEqual(@as(u64, 0xbeef), try m.readInt(0x1ffe, 16, .read));
    try std.testing.expectEqual(@as(usize, 0), w.searches.items.len);
    s.set(8, 0x1400);
    const handle = try w.perform(&s, &m, .FindFirstStreamW);
    try std.testing.expect(handle != invalid_handle);
    s.set(1, handle);
    s.set(2, 1);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .FindNextFileW));
    try std.testing.expectEqual(@as(u32, 6), w.last_error);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .FindNextStreamW));
    try std.testing.expectEqual(@as(u32, 38), w.last_error); // EOF does not dereference the output.
    s.set(2, 0);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .FindNextStreamW));
    try std.testing.expectEqual(@as(u32, 87), w.last_error);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .FindClose));
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .FindNextStreamW));
    try std.testing.expectEqual(@as(u32, 6), w.last_error);
}
fn searchAllocationProbe(allocator: std.mem.Allocator, cow: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/*", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const source = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(source);
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.write(0x1100, std.mem.sliceAsBytes(source[0 .. source.len + 1]));
    var backing: [16384]u8 = @splat(0xaa);
    try m.borrow(0x3000, &backing, .{ .read = true, .write = true }, cow, null);
    var w = Windows{ .allocator = allocator, .module_base = 0x400000, .last_error = 777, .allow_files = true };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0x1100);
    s.set(2, 0x3ffe);
    const handle = try w.perform(&s, &m, .FindFirstFileW);
    if (handle == invalid_handle and w.last_error == 8) {
        try std.testing.expectEqual(@as(usize, 0), w.searches.items.len);
        try std.testing.expectEqual(@as(u64, 0x10000), w.next_handle);
        var output: [592]u8 = undefined;
        try m.read(0x3ffe, &output, .read);
        try std.testing.expectEqualSlices(u8, &@as([592]u8, @splat(0xaa)), &output);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, 0x10000), handle);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    const position = host.c.telldir(w.searches.items[0].state.files.directory);
    s.set(1, handle);
    s.set(2, 0x5ffe);
    const next = try w.perform(&s, &m, .FindNextFileW);
    if (next == 0 and w.last_error == 8) {
        try std.testing.expectEqual(position, host.c.telldir(w.searches.items[0].state.files.directory));
        var output: [592]u8 = undefined;
        try m.read(0x5ffe, &output, .read);
        try std.testing.expectEqualSlices(u8, &@as([592]u8, @splat(0xaa)), &output);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, 1), next);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    const fd = host.c.dirfd(w.searches.items[0].state.files.directory);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .FindClose));
    try std.testing.expectEqual(@as(c_int, -1), host.c.fcntl(fd, host.c.F_GETFD));
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .FindClose));
    try std.testing.expectEqual(@as(u32, 6), w.last_error);
    if (cow) try std.testing.expectEqualSlices(u8, &@as([16384]u8, @splat(0xaa)), &backing);
}
test "search handles publish atomically and roll back cursors on COW and allocation failure" {
    for ([_]bool{ false, true }) |cow|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, searchAllocationProbe, .{cow});
}
test "search output faults preserve cursors and foreign or stale handles cannot close searches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/*", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const source = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(source);
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    try m.write(0x1100, std.mem.sliceAsBytes(source[0 .. source.len + 1]));
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000, .last_error = 777, .allow_files = true };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0x1100);
    s.set(2, 0x1ffe);
    try m.writeInt(0x1ffe, 16, 0xbeef);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .FindFirstFileW));
    try std.testing.expectEqual(@as(u64, 0xbeef), try m.readInt(0x1ffe, 16, .read));
    try std.testing.expectEqual(@as(usize, 0), w.searches.items.len);
    s.set(2, 0x1400);
    const handle = try w.perform(&s, &m, .FindFirstFileW);
    try std.testing.expect(handle != invalid_handle);
    s.set(1, handle);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .FindNextStreamW));
    try std.testing.expectEqual(@as(u32, 6), w.last_error);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .CloseHandle));
    try std.testing.expectEqual(@as(u32, 6), w.last_error);
    const position = host.c.telldir(w.searches.items[0].state.files.directory);
    s.set(2, 0x1ffe);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .FindNextFileW));
    try std.testing.expectEqual(position, host.c.telldir(w.searches.items[0].state.files.directory));
    try std.testing.expectEqual(@as(u64, 0xbeef), try m.readInt(0x1ffe, 16, .read));
    s.set(2, 0x1400);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .FindNextFileW));
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .FindNextFileW));
    try std.testing.expectEqual(@as(u32, 18), w.last_error);
    for ([_]u64{ 0, 0x100, invalid_handle, current_thread, 0xdeadbeef }) |foreign| {
        s.set(1, foreign);
        try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .FindClose));
        try std.testing.expectEqual(@as(u32, 6), w.last_error);
    }
    s.set(1, handle);
    w.allow_files = false;
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .FindNextFileW));
    try std.testing.expectEqual(@as(u32, 5), w.last_error);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .FindClose));
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .FindNextFileW));
}
fn driveAllocationProbe(allocator: std.mem.Allocator, cow: bool, wide: bool) !void {
    var m = Memory.init(allocator);
    defer m.deinit();
    var backing: [8192]u8 = @splat(0xaa);
    try m.borrow(0x3000, &backing, .{ .read = true, .write = true }, cow, null);
    var w = Windows{ .allocator = allocator, .module_base = 0x400000, .allow_files = true, .last_error = 777, .sysroot = "." };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0xffffffff00000005);
    s.set(2, 0x3fff);
    const result = try w.perform(&s, &m, if (wide) .GetLogicalDriveStringsW else .GetLogicalDriveStringsA);
    var output: [12]u8 = undefined;
    try m.read(0x3fff, &output, .read);
    if (result == 0 and w.last_error == 8) {
        try std.testing.expectEqualSlices(u8, &@as([12]u8, @splat(0xaa)), &output);
        try std.testing.expectEqualSlices(u8, &@as([8192]u8, @splat(0xaa)), &backing);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, 4), result);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    const expected: []const u8 = if (wide) "C\x00:\x00\\\x00\x00\x00\x00\x00" else "C:\\\x00\x00";
    try std.testing.expectEqualSlices(u8, expected, output[0..expected.len]);
    for (output[expected.len..]) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
    if (cow) try std.testing.expectEqualSlices(u8, &@as([8192]u8, @splat(0xaa)), &backing);
}
test "drive enumeration preserves atomic output under allocation and COW failures" {
    for ([_]bool{ false, true }) |cow| for ([_]bool{ false, true }) |wide|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, driveAllocationProbe, .{ cow, wide });
}
test "drive enumeration checks capacities, double terminators, grants and output faults" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 5);
    s.set(2, 1);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .GetLogicalDriveStringsW));
    try std.testing.expectEqual(@as(u32, 5), w.last_error);
    w.allow_files = true;
    for ([_]Api{ .GetLogicalDriveStringsW, .GetLogicalDriveStringsA }) |api| for (0..8) |capacity| {
        w.last_error = 777;
        try m.write(0x1100, &@as([16]u8, @splat(0xaa)));
        s.set(1, capacity);
        s.set(2, 0x1100);
        try std.testing.expectEqual(@as(u64, if (capacity < 5) 5 else 4), try w.perform(&s, &m, api));
        try std.testing.expectEqual(@as(u32, 777), w.last_error);
        const written: usize = if (capacity < 5) 0 else if (api == .GetLogicalDriveStringsW) 10 else 5;
        var bytes: [16]u8 = undefined;
        try m.read(0x1100, &bytes, .read);
        for (bytes[written..]) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
    };
    s.set(1, 5);
    s.set(2, 0);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .GetLogicalDriveStringsW));
    try std.testing.expectEqual(@as(u32, 87), w.last_error);
    s.set(2, 0x1ffe);
    try m.writeInt(0x1ffe, 16, 0xbeef);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .GetLogicalDriveStringsW));
    try std.testing.expectEqual(@as(u64, 0xbeef), try m.readInt(0x1ffe, 16, .read));
    try std.testing.expectEqual(@as(u64, 4), try w.perform(&s, &m, .GetLogicalDrives));
}
test "virtual C drive paths share one root and current directory" {
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000 };
    defer w.deinit();
    for ([_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "C:\\", .expected = "/" },
        .{ .input = "c:/a/../é🚀", .expected = "/é🚀" },
        .{ .input = "C:\\..\\..\\file::$dAtA", .expected = "/file" },
        .{ .input = "C://a/./b", .expected = "/a/b" },
        .{ .input = "C:\\a\\..\\directory\\", .expected = "/directory/" },
        .{ .input = "relative\\file", .expected = "relative/file" },
        .{ .input = "\\rooted\\file", .expected = "/rooted/file" },
    }) |case| {
        const path = try w.guestPath(case.input, true);
        defer w.allocator.free(path);
        try std.testing.expectEqualStrings(case.expected, path);
    }
    const current = try w.directoryPath();
    defer w.allocator.free(current);
    const bare = try w.guestPath("c:", false);
    defer w.allocator.free(bare);
    try std.testing.expectEqualStrings(current, bare);
    const expected = try std.fs.path.resolvePosix(w.allocator, &.{ current, "../file" });
    defer w.allocator.free(expected);
    const relative = try w.guestPath("C:..\\file", false);
    defer w.allocator.free(relative);
    try std.testing.expectEqualStrings(expected, relative);
    try std.testing.expectError(error.InvalidWindowsDrive, w.guestPath("D:\\file", false));
    try std.testing.expectError(error.UnsupportedWindowsPath, w.guestPath("C:\\file:named", true));
    try std.testing.expectError(error.UnsupportedWindowsPath, w.guestPath("C:\\file::$DATA", false));
    try std.testing.expectError(error.UnsupportedWindowsPath, w.guestPath("\\\\?\\C:\\file", false));
    try std.testing.expectError(error.UnsupportedWindowsPath, w.guestPath("\\/server/share", false));
}
fn directoryAllocationProbe(allocator: std.mem.Allocator, cow: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = try host.statAt(host.c.AT_FDCWD, ".", false);
    // Registered before w.deinit: verify restoration even on every injected failure.
    defer {
        const restored = host.statAt(host.c.AT_FDCWD, ".", false) catch @panic("directory restoration failed");
        std.debug.assert(restored.dev == original.dev and restored.ino == original.ino);
    }
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const source = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(source);
    var m = Memory.init(allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.write(0x1100, std.mem.sliceAsBytes(source[0 .. source.len + 1]));
    var backing: [8192]u8 = @splat(0xaa);
    try m.borrow(0x3000, &backing, .{ .read = true, .write = true }, cow, null);
    var w = Windows{ .allocator = allocator, .module_base = 0x400000, .last_error = 777, .allow_files = true, .sysroot = "." };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0x1100);
    const changed = try w.perform(&s, &m, .SetCurrentDirectoryW);
    if (changed == 0 and w.last_error == 8) {
        try std.testing.expect(w.restore_directory == null);
        const current = try host.statAt(host.c.AT_FDCWD, ".", false);
        try std.testing.expectEqual(original.ino, current.ino);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, 1), changed);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    try std.testing.expect(std.fs.path.isAbsolutePosix(w.sysroot.?));
    s.set(1, 0xffffffff00000080); // The DWORD capacity ignores its high half.
    s.set(2, 0x3ffe);
    const length = try w.perform(&s, &m, .GetCurrentDirectoryW);
    if (length == 0 and w.last_error == 8) {
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try m.readInt(0x3ffe, 64, .read));
        try std.testing.expectEqualSlices(u8, &@as([8192]u8, @splat(0xaa)), &backing);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(u64, path.len + 3), length);
    try std.testing.expectEqual(@as(u64, 'C'), try m.readInt(0x3ffe, 16, .read));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x3ffe + length * 2, 16, .read));
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    if (cow) try std.testing.expectEqualSlices(u8, &@as([8192]u8, @splat(0xaa)), &backing);
}
test "directory state restores host cwd and validates atomic outputs under allocation failures" {
    for ([_]bool{ false, true }) |cow|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, directoryAllocationProbe, .{cow});
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000, .allow_files = true, .last_error = 777 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 32768);
    s.set(2, 0x1ffe);
    try m.writeInt(0x1ffe, 16, 0xbeef);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .GetCurrentDirectoryW));
    try std.testing.expectEqual(@as(u64, 0xbeef), try m.readInt(0x1ffe, 16, .read));
    s.set(2, 0);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .GetCurrentDirectoryW));
    try std.testing.expectEqual(@as(u32, 87), w.last_error);
    w.last_error = 777;
    s.set(1, 0);
    s.set(2, 1);
    try std.testing.expect(try w.perform(&s, &m, .GetCurrentDirectoryW) > 1);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
}
fn temporaryAllocationProbe(allocator: std.mem.Allocator, cow: bool, relative: bool) !void {
    var m = Memory.init(allocator);
    defer m.deinit();
    var backing: [8192]u8 = @splat(0xaa);
    try m.borrow(0x3000, &backing, .{ .read = true, .write = true }, cow, null);
    var w = Windows{ .allocator = allocator, .module_base = 0x400000, .allow_files = true, .last_error = 777 };
    defer w.deinit();
    try w.setTemporaryPath(&.{ if (relative) "tMp=./é🚀" else "tMp=/é🚀", "TEMP=/ignored" });
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0xffffffff00008000);
    s.set(2, 0x3ffe);
    const length = try w.perform(&s, &m, .GetTempPathW);
    if (length == 0 and w.last_error == 8) {
        try std.testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaaa), try m.readInt(0x3ffe, 64, .read));
        try std.testing.expectEqualSlices(u8, &@as([8192]u8, @splat(0xaa)), &backing);
        return error.OutOfMemory;
    }
    try std.testing.expect(if (relative) length > 7 else length == 7);
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    try std.testing.expectEqual(@as(u64, '\\'), try m.readInt(0x3ffe + (length - 1) * 2, 16, .read));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x3ffe + length * 2, 16, .read));
    if (cow) try std.testing.expectEqualSlices(u8, &@as([8192]u8, @splat(0xaa)), &backing);
}
test "temporary path selection stages Unicode output and preserves backing on allocation failure" {
    for ([_]bool{ false, true }) |cow| for ([_]bool{ false, true }) |relative|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, temporaryAllocationProbe, .{ cow, relative });
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000, .allow_files = true };
    defer w.deinit();
    try w.setTemporaryPath(&.{"TMP=embedded\x00nul"});
    var s = State{ .architecture = .x86_64 };
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .GetTempPathW));
    try std.testing.expectEqual(@as(u32, 123), w.last_error);
    w.allocator.free(w.temporary_path.?);
    w.temporary_path = null;
    s.set(1, 32768);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .GetTempPathW));
    try std.testing.expectEqual(@as(u32, 87), w.last_error);
}
test "module filenames check output ranges, DWORD sizes and allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, filenameAllocationProbe, .{});
}
test "Windows encoding validates DWORD arguments, optional pointers and checked stack arguments" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000, .last_error = 777 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(4, 0x1800);
    s.set(1, 0xffffffff0000fde9); // Ignore the high DWORD of code page, flags and signed lengths.
    s.set(2, 0xffffffff00000008);
    s.set(8, 0x1000);
    s.set(9, 0xffffffff00000005);
    try m.write(0x1000, "A🚀");
    try m.writeInt(0x1828, 64, 0x1100);
    try m.writeInt(0x1830, 64, 0xffffffff00000003);
    try std.testing.expectEqual(@as(u64, 3), try w.perform(&s, &m, .MultiByteToWideChar));
    try std.testing.expectEqual(@as(u64, 0xde80d83d0041), try m.readInt(0x1100, 48, .read));
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    s.set(1, 1252);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .MultiByteToWideChar));
    try std.testing.expectEqual(@as(u32, 87), w.last_error);
    s.set(1, 65001);
    s.set(2, 1);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .MultiByteToWideChar));
    try std.testing.expectEqual(@as(u32, 1004), w.last_error);
    s.set(2, 128);
    s.set(8, 0x1100);
    s.set(9, 3);
    try m.writeInt(0x1828, 64, 0x1200);
    try m.writeInt(0x1830, 64, 5);
    try m.writeInt(0x1838, 64, 0);
    try m.writeInt(0x1840, 64, 0x1300);
    try m.writeInt(0x1300, 32, 0xcafecafe);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .WideCharToMultiByte));
    try std.testing.expectEqual(@as(u32, 87), w.last_error);
    try std.testing.expectEqual(@as(u64, 0xcafecafe), try m.readInt(0x1300, 32, .read));
    for ([_]u32{ 0, 1, 3 }) |page| {
        s.set(1, 0xffffffff00000000 | @as(u64, page));
        try m.writeInt(0x1838, 64, 1); // An unused default byte is not accessed by this UTF-8 profile.
        try m.writeInt(0x1300, 32, 0xcafecafe);
        w.last_error = 777;
        try std.testing.expectEqual(@as(u64, 5), try w.perform(&s, &m, .WideCharToMultiByte));
        try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1300, 32, .read));
        try std.testing.expectEqual(@as(u32, 777), w.last_error);
        try m.writeInt(0x1828, 64, 1); // Length queries still return the optional FALSE flag.
        try m.writeInt(0x1830, 64, 0);
        try m.writeInt(0x1300, 32, 0xcafecafe);
        try std.testing.expectEqual(@as(u64, 5), try w.perform(&s, &m, .WideCharToMultiByte));
        try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1300, 32, .read));
        try m.writeInt(0x1828, 64, 0x1200);
        try m.writeInt(0x1830, 64, 5);
    }
    s.set(1, 65001);
    try m.writeInt(0x1838, 64, 0);
    try m.writeInt(0x1840, 64, 0);
    w.last_error = 777;
    try std.testing.expectEqual(@as(u64, 5), try w.perform(&s, &m, .WideCharToMultiByte));
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    try m.writeInt(0x1100, 16, 0xd800);
    try m.writeInt(0x1200, 64, 0xabcdef0123456789);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .WideCharToMultiByte));
    try std.testing.expectEqual(@as(u32, 1113), w.last_error);
    try std.testing.expectEqual(@as(u64, 0xabcdef0123456789), try m.readInt(0x1200, 64, .read));
    s.set(4, 0x1fc0); // The eighth argument lies in unmapped memory.
    try m.writeInt(0x1fe8, 64, 0x1200);
    try m.writeInt(0x1ff0, 64, 5);
    try m.writeInt(0x1ff8, 64, 0);
    w.last_error = 777;
    try std.testing.expectError(error.UnmappedMemory, w.perform(&s, &m, .WideCharToMultiByte));
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    try std.testing.expectEqual(@as(u64, 0xabcdef0123456789), try m.readInt(0x1200, 64, .read));
}
test "Windows disk queries keep 64-bit totals and validate all outputs before writes" {
    var info = host.DiskStat{ .unit = 4096, .blocks = 0x100000009, .free = 0x100000007, .available = 0x100000005 };
    try std.testing.expectEqual([4]u64{ 0x100000005000, 0x100000009000, 0x100000007000, 0 }, try diskValues(info, true));
    try std.testing.expectEqual([4]u64{ 8, 512, 0xffffffff, 0xffffffff }, try diskValues(info, false));
    info.unit = 1;
    try std.testing.expectError(error.UnsupportedDiskGeometry, diskValues(info, false));
    info.unit = 0;
    try std.testing.expectError(error.UnsupportedDiskGeometry, diskValues(info, true));
    info.unit = std.math.maxInt(u64);
    try std.testing.expectError(error.DiskSizeOverflow, diskValues(info, true));
    info.available = info.free + 1;
    try std.testing.expectError(error.InvalidDiskCounts, diskValues(info, true));
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000, .last_error = 777 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(2, 0x1100);
    s.set(8, 0x1108);
    s.set(9, 0x1ffc);
    try m.writeInt(0x1100, 64, 0x12345678);
    try m.writeInt(0x1108, 64, 0xabcdef01);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .GetDiskFreeSpaceExW));
    try std.testing.expectEqual(@as(u32, 5), w.last_error);
    w.allow_files = true;
    w.last_error = 777;
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .GetDiskFreeSpaceExW));
    s.set(9, 0x1110);
    s.set(4, 0x1800);
    try m.writeInt(0x1828, 64, 0x2000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .GetDiskFreeSpaceW));
    try std.testing.expectEqual(@as(u64, 0x12345678), try m.readInt(0x1100, 64, .read));
    try std.testing.expectEqual(@as(u64, 0xabcdef01), try m.readInt(0x1108, 64, .read));
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    s.set(4, 0x2fe0); // The fifth argument lies in unmapped memory.
    try std.testing.expectError(error.UnmappedMemory, w.perform(&s, &m, .GetDiskFreeSpaceW));
    try std.testing.expectEqual(@as(u64, 0x12345678), try m.readInt(0x1100, 64, .read));
}
test "Windows processor features match virtual CPUID and preserve LastError" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000, .last_error = 777 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    for (0..64) |feature| {
        s.set(1, 0xffffffff00000000 | feature); // DWORD input ignores the high register bits.
        const expected: u64 = switch (feature) {
            2, 3, 8, 9, 12, 14 => 1,
            else => 0,
        };
        try std.testing.expectEqual(expected, try w.perform(&s, &m, .IsProcessorFeaturePresent));
        try std.testing.expectEqual(@as(u32, 777), w.last_error);
    }
    s.set(1, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .IsProcessorFeaturePresent));
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
}
test "Windows memory status tracks the guest budget and validates outputs before writes" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    m.limit = 16384;
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0x1800);
    try m.writeInt(0x1800, 32, 63);
    try m.writeInt(0x1804, 32, 0xabcdef01);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .GlobalMemoryStatusEx));
    try std.testing.expectEqual(@as(u32, 87), w.last_error);
    try std.testing.expectEqual(@as(u64, 0xabcdef01), try m.readInt(0x1804, 32, .read));
    s.set(1, 0x1fe0);
    try m.writeInt(0x1fe0, 32, 64);
    try m.writeInt(0x1fe4, 32, 0xabcdef01);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .GlobalMemoryStatusEx));
    try std.testing.expectEqual(@as(u64, 0xabcdef01), try m.readInt(0x1fe4, 32, .read));
    s.set(1, 0x1800);
    try m.writeInt(0x1800, 32, 64);
    w.last_error = 777;
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .GlobalMemoryStatusEx));
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    try std.testing.expectEqual(@as(u64, 50), try m.readInt(0x1804, 32, .read));
    const total_virtual: u64 = 0x800000000000 - 65536;
    for ([_]u64{ 16384, 8192, 16384, 8192, total_virtual, total_virtual, 0 }, 0..) |value, index| try std.testing.expectEqual(value, try m.readInt(0x1808 + index * 8, 64, .read));
    try m.map(0x10000, 4096, .{ .read = true });
    _ = try w.perform(&s, &m, .GlobalMemoryStatusEx);
    try std.testing.expectEqual(@as(u64, 75), try m.readInt(0x1804, 32, .read));
    try std.testing.expectEqual(@as(u64, 4096), try m.readInt(0x1810, 64, .read));
    try std.testing.expectEqual(total_virtual - 4096, try m.readInt(0x1830, 64, .read));
    try m.unmap(0x10000, 4096);
    m.limit = 0;
    _ = try w.perform(&s, &m, .GlobalMemoryStatusEx);
    try std.testing.expectEqual(@as(u64, 100), try m.readInt(0x1804, 32, .read));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1810, 64, .read));
}
test "system information validates all outputs and mapping failures preserve guest state" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0x1fe0);
    try m.writeInt(0x1fe0, 64, 0x12345678);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .GetSystemInfo));
    try std.testing.expectEqual(@as(u64, 0x12345678), try m.readInt(0x1fe0, 64, .read));
    s.set(4, 0x1800);
    s.set(1, invalid_handle);
    s.set(2, 0);
    s.set(8, 4);
    s.set(9, 0);
    try m.writeInt(0x1828, 64, 8192);
    try m.writeInt(0x1830, 64, 0);
    const handle = try w.perform(&s, &m, .CreateFileMappingW);
    try std.testing.expect(handle != 0);
    s.set(1, handle);
    s.set(2, 2);
    s.set(8, 0);
    s.set(9, 0);
    try m.writeInt(0x1828, 64, 8193);
    const next = w.next_map;
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .MapViewOfFile));
    try std.testing.expectEqual(@as(u32, 87), w.last_error);
    try std.testing.expectEqual(@as(usize, 0), w.mappings.views.items.len);
    try std.testing.expectEqual(next, w.next_map);
    try m.writeInt(0x1828, 64, 8192);
    m.limit = m.used;
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .MapViewOfFile));
    try std.testing.expectEqual(@as(u32, 8), w.last_error);
    try std.testing.expectEqual(@as(usize, 0), w.mappings.views.items.len);
    try std.testing.expectEqual(@as(usize, 1), w.mappings.objects.items[0].?.references);
}
test "File metadata and legacy seek faults validate whole outputs before changing the file" {
    var template = "/tmp/universe-file-output-XXXXXX".*;
    const fd = host.c.mkstemp(&template);
    try std.testing.expect(fd >= 0);
    defer _ = host.c.unlink(&template);
    try std.testing.expectEqual(@as(isize, 5), host.c.write(fd, "alpha", 5));
    const info = try host.statFd(fd);
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x2000, 4096, .{ .read = true });
    try m.writeInt(0x1fe0, 8, 0x5a);
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x140000000, .allow_files = true };
    defer w.deinit();
    try w.files.append(w.allocator, .{ .handle = 0x10000, .fd = fd, .access = 3, .share = 7, .device = info.dev, .inode = info.ino });
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0x10000);
    s.set(2, 7);
    s.set(8, 0x2000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .SetFilePointer));
    try std.testing.expectEqual(@as(i64, 5), host.c.lseek(fd, 0, host.c.SEEK_CUR));
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .SetFilePointerEx));
    try std.testing.expectEqual(@as(i64, 5), host.c.lseek(fd, 0, host.c.SEEK_CUR));
    s.set(2, 0x1fe0);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .GetFileInformationByHandle));
    try std.testing.expectEqual(@as(u64, 0x5a), try m.readInt(0x1fe0, 8, .read));
    s.set(2, 0x2000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .GetFileSize));
    s.set(2, 0x1100);
    try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .GetFileInformationByHandle));
    try std.testing.expectEqual(@as(u64, 5), try m.readInt(0x1100 + 36, 32, .read));
    try std.testing.expectEqual(@as(u64, 116444736000000000), try time_api.fromTimestamp(.{ .sec = 0, .nsec = 0 }));
    try std.testing.expectError(error.WindowsFileTimeOutOfRange, time_api.fromTimestamp(.{ .sec = -11644473601, .nsec = 0 }));
    w.files.items[0].access = 1;
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .SetEndOfFile));
    try std.testing.expectEqual(@as(u32, 5), w.last_error);
    try std.testing.expectEqual(@as(i64, 5), (try host.statFd(fd)).size);
}
test "Pending deletion must preserve a host replacement at the retained name" {
    var template = "/tmp/universe-delete-replacement-XXXXXX".*;
    const fd = host.c.mkstemp(&template);
    try std.testing.expect(fd >= 0);
    const info = try host.statFd(fd);
    _ = host.c.close(fd);
    defer _ = host.c.unlink(&template);
    var moved: [128]u8 = undefined;
    const saved = try std.fmt.bufPrintSentinel(&moved, "{s}-moved", .{std.mem.sliceTo(&template, 0)}, 0);
    defer _ = host.c.unlink(saved.ptr);
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x140000000, .allow_files = true };
    defer w.deinit();
    const directory = host.c.open("/tmp", host.c.O_RDONLY | host.c.O_DIRECTORY | host.c.O_CLOEXEC);
    try std.testing.expect(directory >= 0);
    try w.deletions.append(w.allocator, .{ .directory = directory, .name = try w.allocator.dupeZ(u8, std.fs.path.basenamePosix(std.mem.sliceTo(&template, 0))), .device = info.dev, .inode = info.ino });
    try std.testing.expectEqual(@as(c_int, 0), host.renameExclusive(std.mem.sliceTo(&template, 0), saved));
    const replacement = host.c.open(&template, host.c.O_CREAT | host.c.O_EXCL | host.c.O_RDWR | host.c.O_CLOEXEC, @as(host.c.mode_t, 0o600));
    try std.testing.expect(replacement >= 0);
    defer _ = host.c.close(replacement);
    try std.testing.expectEqual(@as(isize, 4), host.c.write(replacement, "keep", 4));
    try std.testing.expectEqual(@as(?u32, 13), w.finishDelete(info.dev, info.ino));
    try std.testing.expectEqual(@as(usize, 0), w.deletions.items.len);
    const present = try host.statAt(host.c.AT_FDCWD, std.mem.sliceTo(&template, 0), true);
    try std.testing.expectEqual((try host.statFd(replacement)).ino, present.ino);
    try std.testing.expectEqual(@as(i64, 4), present.size);
}
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

fn localAllocationProbe(allocator: std.mem.Allocator) !void {
    var m = Memory.init(allocator);
    defer m.deinit();
    var w = Windows{ .allocator = allocator, .module_base = 0x400000, .last_error = 777 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    for ([_]u32{ 0x40, 0x42, 2 }) |flags| {
        s.set(1, flags);
        s.set(2, if (flags == 2) 0 else 17);
        const used = m.used;
        const count = w.allocations.items.len;
        const next = w.next_handle;
        const result = try w.perform(&s, &m, .LocalAlloc);
        if (result == 0) {
            try std.testing.expectEqual(@as(u32, 8), w.last_error);
            try std.testing.expectEqual(used, m.used);
            try std.testing.expectEqual(count, w.allocations.items.len);
            try std.testing.expectEqual(next, w.next_handle);
            return error.OutOfMemory;
        }
        try std.testing.expectEqual(@as(u32, 777), w.last_error);
    }
}
test "local allocations retain handles, lock counts and ownership across failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, localAllocationProbe, .{});
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000, .last_error = 777 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    for ([_]u32{ 0x40, 0xf72 }) |flags| {
        s.set(1, @as(u64, 0xffffffff00000000) | flags); // UINT flags ignore the upper DWORD.
        s.set(2, 17);
        const handle = try w.perform(&s, &m, .LocalAlloc);
        try std.testing.expect(handle != 0);
        s.set(1, handle);
        const ptr = try w.perform(&s, &m, .LocalLock);
        try std.testing.expect(ptr != 0 and ptr % 16 == 0);
        try std.testing.expectEqual(flags & 2 == 0, ptr == handle);
        try std.testing.expectEqual(@as(u64, 17), try w.perform(&s, &m, .LocalSize));
        try std.testing.expectEqual(@as(u64, 0), try m.readInt(ptr, 64, .read));
        s.set(1, ptr);
        try std.testing.expectEqual(handle, try w.perform(&s, &m, .LocalHandle));
        s.set(1, ptr + 1);
        try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalHandle));
        try std.testing.expectEqual(@as(u32, 6), w.last_error);
        s.set(1, handle);
        w.last_error = 777;
        if (flags & 2 != 0) {
            for (1..255) |_| try std.testing.expectEqual(ptr, try w.perform(&s, &m, .LocalLock));
            try std.testing.expectEqual(@as(u64, 255), try w.perform(&s, &m, .LocalFlags));
            try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalLock));
            try std.testing.expectEqual(@as(u32, 212), w.last_error);
            w.last_error = 777;
            for (1..255) |_| try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .LocalUnlock));
            try std.testing.expectEqual(@as(u32, 777), w.last_error);
            try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalUnlock));
            try std.testing.expectEqual(@as(u32, 0), w.last_error);
        }
        try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalUnlock));
        try std.testing.expectEqual(@as(u32, 158), w.last_error);
        try std.testing.expectEqual(ptr, try w.perform(&s, &m, .LocalLock));
        try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalFree)); // Free while locked.
        try std.testing.expectError(error.UnmappedMemory, m.readInt(ptr, 8, .read));
        try std.testing.expectEqual(handle, try w.perform(&s, &m, .LocalFree));
        try std.testing.expectEqual(@as(u32, 6), w.last_error);
        try std.testing.expectEqual(@as(u64, 0x8000), try w.perform(&s, &m, .LocalFlags));
    }
    s.set(1, 2);
    s.set(2, 0);
    const discarded = try w.perform(&s, &m, .LocalAlloc);
    try std.testing.expect(discarded != 0 and m.used == 0);
    s.set(1, discarded);
    try std.testing.expectEqual(@as(u64, 0x4000), try w.perform(&s, &m, .LocalFlags));
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalSize));
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalLock));
    try std.testing.expectEqual(@as(u32, 157), w.last_error);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalFree));
    s.set(1, 0);
    w.last_error = 777;
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalFree));
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    for ([_]AllocationKind{ .virtual, .heap, .bstr, .crt }) |kind| {
        const foreign = try w.allocate(&m, 17, .{ .read = true, .write = true }, kind);
        s.set(1, foreign);
        try std.testing.expectEqual(foreign, try w.perform(&s, &m, .LocalFree));
        try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalSize));
        try m.check(foreign, 17, .write);
    }
    s.set(1, 0x80);
    s.set(2, 17);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalAlloc));
    try std.testing.expectEqual(@as(u32, 87), w.last_error);
    s.set(1, 0);
    s.set(2, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalAlloc));
    try std.testing.expectEqual(@as(u32, 8), w.last_error);
    m.limit = m.used;
    s.set(2, 17);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalAlloc));
    try std.testing.expectEqual(@as(u32, 8), w.last_error);
    s.set(1, 2);
    s.set(2, 0);
    while (w.allocations.items.len < 1024) try std.testing.expect(try w.perform(&s, &m, .LocalAlloc) != 0);
    try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalAlloc));
    try std.testing.expectEqual(@as(u32, 8), w.last_error);
}

fn localResizeProbe(allocator: std.mem.Allocator, cow: bool, moved: bool) !void {
    var m = Memory.init(allocator);
    defer m.deinit();
    var w = Windows{ .allocator = allocator, .module_base = 0x400000, .last_error = 777 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(1, 0x42);
    s.set(2, 17);
    const handle = try w.perform(&s, &m, .LocalAlloc);
    if (handle == 0) {
        try std.testing.expectEqual(@as(u32, 8), w.last_error);
        try std.testing.expectEqual(@as(usize, 0), m.used);
        try std.testing.expectEqual(@as(usize, 0), w.allocations.items.len);
        return error.OutOfMemory;
    }
    const address = w.allocations.items[0].address;
    try m.writeInt(address, 64, 0x123456789abcdef0);
    const backing = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0xaa);
    std.mem.writeInt(u64, backing[0..8], 0x123456789abcdef0, .little);
    if (cow) {
        try m.unmap(address, 4096);
        try m.borrow(address, backing, .{ .read = true, .write = true }, true, null);
    }
    const used = m.used;
    s.set(1, handle);
    s.set(2, if (moved) 8193 else 100);
    s.set(8, 0x42);
    const result = try w.perform(&s, &m, .LocalReAlloc);
    if (result == 0) {
        try std.testing.expectEqual(@as(u32, 8), w.last_error);
        try std.testing.expectEqual(used, m.used);
        try std.testing.expectEqual(@as(usize, 1), w.allocations.items.len);
        try std.testing.expectEqual(address, w.allocations.items[0].address);
        try std.testing.expectEqual(@as(usize, 17), w.allocations.items[0].requested);
        try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), try m.readInt(address, 64, .read));
        if (cow) try std.testing.expectEqual(@as(u8, 0xaa), backing[17]);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(handle, result);
    const next = w.allocations.items[0].address;
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), try m.readInt(next, 64, .read));
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(next + 17, 64, .read));
    try std.testing.expectEqual(@as(u32, 777), w.last_error);
    if (cow) try std.testing.expectEqual(@as(u8, 0xaa), backing[17]);
}
test "local resizing preserves allocations on failure and movable handles through discard" {
    for ([_]bool{ false, true }) |cow| for ([_]bool{ false, true }) |moved| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, localResizeProbe, .{ cow, moved });
    };
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x400000, .last_error = 777 };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    for ([_]u32{ 0, 2 }) |movable| {
        s.set(1, movable);
        s.set(2, 17);
        const handle = try w.perform(&s, &m, .LocalAlloc);
        s.set(1, handle);
        const address = try w.perform(&s, &m, .LocalLock);
        try m.writeInt(address, 64, 0x123456789abcdef0);
        s.set(2, 8193);
        s.set(8, 0);
        try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalReAlloc));
        try std.testing.expectEqual(@as(u32, 8), w.last_error);
        try std.testing.expectEqual(@as(u64, 17), try w.perform(&s, &m, .LocalSize));
        m.limit = m.used;
        s.set(8, 2);
        try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalReAlloc));
        try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), try m.readInt(address, 64, .read));
        m.limit = 256 * 1024 * 1024;
        s.set(8, 0xffffffff00000042);
        const resized = try w.perform(&s, &m, .LocalReAlloc);
        try std.testing.expectEqual(movable != 0, resized == handle);
        s.set(1, resized);
        try std.testing.expectEqual(@as(u64, if (movable != 0) 1 else 0), try w.perform(&s, &m, .LocalFlags));
        s.set(8, 0x80);
        s.set(2, std.math.maxInt(u64));
        try std.testing.expectEqual(resized, try w.perform(&s, &m, .LocalReAlloc));
        try std.testing.expectEqual(@as(u64, 8193), try w.perform(&s, &m, .LocalSize));
        s.set(8, 0xc0);
        try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalReAlloc));
        try std.testing.expectEqual(@as(u32, 87), w.last_error);
        s.set(8, 2);
        s.set(2, 0);
        if (movable != 0) {
            try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalReAlloc));
            try std.testing.expectEqual(@as(u32, 212), w.last_error);
            _ = try w.perform(&s, &m, .LocalUnlock);
            s.set(2, 16385);
            s.set(8, 0x40); // Unlocked movable growth does not need LMEM_MOVEABLE.
            try std.testing.expectEqual(resized, try w.perform(&s, &m, .LocalReAlloc));
            s.set(2, 0);
            s.set(8, 2);
        }
        try std.testing.expectEqual(resized, try w.perform(&s, &m, .LocalReAlloc));
        try std.testing.expectEqual(@as(u64, if (movable != 0) 0x4000 else 0), try w.perform(&s, &m, .LocalFlags));
        s.set(2, 31);
        s.set(8, 0x42);
        try std.testing.expectEqual(resized, try w.perform(&s, &m, .LocalReAlloc));
        try std.testing.expectEqual(@as(u64, 31), try w.perform(&s, &m, .LocalSize));
        try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .LocalFree));
    }
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

test "Console registration validates targets and restores CPU, wait, LastError and native signals" {
    var old: std.c.Sigaction = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.sigaction(.INT, null, &old));
    {
        var m = Memory.init(std.testing.allocator);
        defer m.deinit();
        try m.map(0x1000, 4096, .{ .read = true, .write = true });
        try m.map(0x4000, 4096, .{ .read = true, .execute = true });
        var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x140000000, .teb_address = 0x1000 };
        defer w.deinit();
        var s = State{ .architecture = .x86_64 };
        s.set(1, 0x1100);
        s.set(2, 1);
        try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .SetConsoleCtrlHandler));
        try std.testing.expect(!w.console.active and w.control_handlers.items.len == 0);
        s.set(1, 0x4000);
        for (0..64) |_| try std.testing.expectEqual(@as(u64, 1), try w.perform(&s, &m, .SetConsoleCtrlHandler));
        try std.testing.expectEqual(@as(u64, 0), try w.perform(&s, &m, .SetConsoleCtrlHandler));
        try std.testing.expectEqual(@as(u32, 8), w.last_error);
        var other = Windows{ .allocator = std.testing.allocator, .module_base = 0x140000000 };
        defer other.deinit();
        try std.testing.expectEqual(@as(u64, 0), try other.perform(&s, &m, .SetConsoleCtrlHandler));
        try std.testing.expectEqual(@as(u32, 50), other.last_error);
        s.set(4, 0x1800);
        s.set(0, 0xabcdef);
        s.pc = 0x400123;
        s.instructions = 77;
        const saved = s;
        w.last_error = 99;
        w.wait = .{ .timeout = 123, .handles = @splat(invalid_handle) };
        try std.testing.expectEqual(@as(c_int, 0), std.c.raise(.INT));
        try w.pollControl(&s, &m);
        try std.testing.expect(w.wait == null and w.control != null);
        try std.testing.expectEqual(@as(u64, 0x4000), s.pc);
        try std.testing.expectEqual(@as(u64, 0), s.get(1));
        const sp = s.get(4);
        try std.testing.expectError(error.InvalidWindowsControlStack, w.finishControl(&s, &m));
        s.set(4, sp + 8);
        s.set(0, 1);
        s.instructions += 17;
        w.last_error = 555;
        try w.finishControl(&s, &m);
        var expected = saved;
        expected.instructions += 18;
        try std.testing.expectEqualDeep(expected, s);
        try std.testing.expect(w.control == null and w.wait.?.timeout == 123);
        try std.testing.expectEqual(@as(u32, 99), w.last_error);
        try std.testing.expectEqual(@as(u64, 99), try m.readInt(0x1068, 32, .read));
    }
    var restored: std.c.Sigaction = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.sigaction(.INT, null, &restored));
    try std.testing.expect(old.handler.handler == restored.handler.handler);
    try std.testing.expectEqual(old.flags, restored.flags);
    try std.testing.expectEqual(old.mask, restored.mask);
}

test "Win32 time outputs and every SetFileTime input validate before mutation" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.map(0x4000, 4096, .{ .read = true });
    var w = Windows{ .allocator = std.testing.allocator, .module_base = 0x140000000, .allow_files = true };
    defer w.deinit();
    var s = State{ .architecture = .x86_64 };
    s.set(4, 0x1800);
    try m.writeInt(0x1828, 64, 0x4000);
    for ([_]u64{ 0x1100, 0x1200, 0x1300 }) |pointer| try m.writeInt(pointer, 64, 99);
    s.set(1, invalid_handle);
    s.set(2, 0x1100);
    s.set(8, 0x1200);
    s.set(9, 0x1300);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .GetProcessTimes));
    for ([_]u64{ 0x1100, 0x1200, 0x1300 }) |pointer| try std.testing.expectEqual(@as(u64, 99), try m.readInt(pointer, 64, .read));
    try m.writeInt(0x1400, 64, 116444736000000000);
    s.set(1, 0x1400);
    s.set(8, 0x4000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .FileTimeToDosDateTime));
    try std.testing.expectEqual(@as(u64, 99), try m.readInt(0x1100, 64, .read));
    var template = "/tmp/universe-windows-time-XXXXXX".*;
    const fd = host.c.mkstemp(&template);
    try std.testing.expect(fd >= 0);
    defer _ = host.c.unlink(&template);
    try w.files.append(w.allocator, .{ .handle = 0x10000, .fd = fd, .access = 3, .share = 3, .device = 0, .inode = 0 });
    s.set(1, 0x10000);
    s.set(8, 0x1200);
    s.set(9, 0x4000);
    try std.testing.expectError(error.PermissionDenied, w.perform(&s, &m, .GetFileTime));
    try std.testing.expectEqual(@as(u64, 99), try m.readInt(0x1100, 64, .read));
    const original = try host.statFd(fd);
    s.set(2, 0);
    s.set(8, 0x1400);
    s.set(9, 0x9000);
    try std.testing.expectError(error.UnmappedMemory, w.perform(&s, &m, .SetFileTime));
    const unchanged = try host.statFd(fd);
    try std.testing.expectEqual(original.atime, unchanged.atime);
    try std.testing.expectEqual(original.mtime, unchanged.mtime);
    try m.writeInt(0x1400, 64, invalid_handle);
    try std.testing.expectError(error.UnmappedMemory, w.perform(&s, &m, .SetFileTime));
    try std.testing.expect(!w.files.items[0].preserve_access and !w.files.items[0].preserve_write);
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
