const std = @import("std");
const host = @import("host.zig");

pub const Device = struct {
    pub const Kind = enum { null, zero, mounts, meminfo, proc_root, proc_pid, proc_self, proc_stat, proc_status, proc_cmdline, proc_comm, missing };
    pub const Path = struct { kind: Kind, pid: u32 = 0 };
    pub const Process = struct {
        pid: u32,
        parent_pid: u32,
        uid: u32 = 1000,
        gid: u32 = 1000,
        state: u8 = 'R',
        comm: [16]u8,
        comm_len: u8,
        cmdline: []const u8,
        memory_bytes: usize = 0,
        threads: u32 = 1,
        start_ticks: u64 = 0,
    };
    pub const ProcessTable = struct {
        entries: [64]Process = undefined,
        len: usize = 0,

        pub fn clear(table: *ProcessTable) void {
            table.len = 0;
        }
        pub fn append(table: *ProcessTable, process: Process) !void {
            if (table.len == table.entries.len) return error.ProcessTableFull;
            table.entries[table.len] = process;
            table.len += 1;
        }
        pub fn find(table: *const ProcessTable, pid: u32) ?Process {
            for (table.entries[0..table.len]) |process| if (process.pid == pid) return process;
            return null;
        }
    };
    pub const DirEntry = struct { name: []const u8, inode: u64, kind: u8, pid: u32 = 0 };
    const mount_list = "universe / universe rw 0 0\n";
    // Occupies an existing guest descriptor slot without owning a native FD.
    pub const fd: c_int = std.math.minInt(c_int);
    allocator: std.mem.Allocator,
    kind: Kind,
    pid: u32 = 0,
    status: u64,
    offset: u64 = 0,
    content: [512]u8 = @splat(0),
    content_len: usize = 0,
    owned_content: ?[]u8 = null,
    proc_pids: [64]u32 = @splat(0),
    proc_pid_count: usize = 0,
    references: usize = 0,

    pub fn create(allocator: std.mem.Allocator, entry: Path, status: u64, table: ?*const ProcessTable) !*Device {
        if (entry.kind == .missing) return error.FileNotFound;
        const d = try allocator.create(Device);
        d.* = .{ .allocator = allocator, .kind = entry.kind, .pid = entry.pid, .status = status, .references = 1 };
        errdefer d.release();
        switch (entry.kind) {
            .proc_root => {
                if (table) |processes| {
                    d.proc_pid_count = processes.len;
                    for (processes.entries[0..processes.len], 0..) |process, i| d.proc_pids[i] = process.pid;
                }
            },
            .proc_stat, .proc_status, .proc_cmdline, .proc_comm => {
                const process = (if (table) |processes| processes.find(entry.pid) else null) orelse return error.FileNotFound;
                try d.populateProcess(process);
            },
            else => {},
        }
        return d;
    }

    pub fn retain(d: *Device) void {
        d.references += 1;
    }
    pub fn release(d: *Device) void {
        d.references -= 1;
        if (d.references == 0) d.destroy();
    }
    fn destroy(d: *Device) void {
        if (d.owned_content) |bytes| d.allocator.free(bytes);
        d.allocator.destroy(d);
    }
    fn populateProcess(d: *Device, process: Process) !void {
        const name = process.comm[0..process.comm_len];
        switch (d.kind) {
            .proc_cmdline => d.owned_content = try d.allocator.dupe(u8, process.cmdline),
            .proc_comm => d.content_len = (try std.fmt.bufPrint(&d.content, "{s}\n", .{name})).len,
            .proc_stat => {
                var fields: [49]i64 = @splat(0);
                fields[0] = process.parent_pid;
                fields[1] = 1; // All current guest processes share the initial process group and session.
                fields[2] = 1;
                fields[4] = -1;
                fields[14] = 20;
                fields[16] = process.threads;
                fields[18] = @intCast(process.start_ticks);
                fields[19] = @intCast(process.memory_bytes);
                fields[20] = @intCast(process.memory_bytes / 4096 + @intFromBool(process.memory_bytes % 4096 != 0));
                var length = (try std.fmt.bufPrint(&d.content, "{d} ({s}) {c}", .{ process.pid, name, process.state })).len;
                for (fields) |value| {
                    d.content[length] = ' ';
                    length += 1;
                    const number = try std.fmt.bufPrint(d.content[length..], "{d}", .{value});
                    length += number.len;
                }
                d.content[length] = '\n';
                d.content_len = length + 1;
            },
            .proc_status => {
                const state_name = switch (process.state) {
                    'R' => "running",
                    'S' => "sleeping",
                    'D' => "disk sleep",
                    'T' => "stopped",
                    'Z' => "zombie",
                    else => "unknown",
                };
                const memory_kb = process.memory_bytes / 1024;
                d.content_len = (try std.fmt.bufPrint(
                    &d.content,
                    "Name:\t{s}\nState:\t{c} ({s})\nTgid:\t{d}\nNgid:\t0\nPid:\t{d}\nPPid:\t{d}\nTracerPid:\t0\nUid:\t{d}\t{d}\t{d}\t{d}\nGid:\t{d}\t{d}\t{d}\t{d}\nFDSize:\t64\nGroups:\nNSpid:\t{d}\nThreads:\t{d}\nVmSize:\t{d} kB\nVmRSS:\t{d} kB\n",
                    .{ name, process.state, state_name, process.pid, process.pid, process.parent_pid, process.uid, process.uid, process.uid, process.uid, process.gid, process.gid, process.gid, process.gid, process.pid, process.threads, memory_kb, memory_kb },
                )).len;
            },
            else => unreachable,
        }
    }
    pub fn readAt(d: Device, offset: u64, buffer: []u8) usize {
        switch (d.kind) {
            .null => return 0,
            .zero => {
                @memset(buffer, 0);
                return buffer.len;
            },
            .mounts, .meminfo, .proc_stat, .proc_status, .proc_cmdline, .proc_comm => {
                const contents = if (d.kind == .mounts) mount_list else if (d.owned_content) |bytes| bytes else d.content[0..d.content_len];
                if (offset >= contents.len) return 0;
                const start: usize = @intCast(offset);
                const count = @min(buffer.len, contents.len - start);
                @memcpy(buffer[0..count], contents[start..][0..count]);
                return count;
            },
            .proc_root, .proc_pid, .proc_self, .missing => return 0,
        }
    }
    pub fn read(d: *Device, buffer: []u8) usize {
        const count = readAt(d.*, d.offset, buffer);
        if (d.readableFile()) d.offset += count;
        return count;
    }
    pub fn populateMeminfo(d: *Device, total: usize, used: usize) void {
        const available = total - used;
        d.content_len = (std.fmt.bufPrint(
            &d.content,
            "MemTotal: {d} kB\nMemFree: {d} kB\nMemAvailable: {d} kB\nBuffers: 0 kB\nCached: 0 kB\nSwapCached: 0 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n",
            .{ total / 1024, available / 1024, available / 1024 },
        ) catch unreachable).len;
    }
    pub fn seek(d: *Device, offset: i64, whence: u64) ?i64 {
        const base: i64 = switch (whence) {
            0 => 0,
            1 => if (d.offset <= std.math.maxInt(i64)) @intCast(d.offset) else return null,
            2 => @intCast(if (d.kind == .mounts) mount_list.len else if (d.owned_content) |bytes| bytes.len else d.content_len),
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
        // ponytail: four reserved absolute leaves use lexical matching; directory lookup needs a VFS.
        for ([_][]const u8{ "/dev/null", "/dev/zero", "/proc/mounts", "/proc/meminfo" }, [_]Kind{ .null, .zero, .mounts, .meminfo }) |leaf, kind| {
            if (std.mem.startsWith(u8, normalized, leaf) and normalized.len > leaf.len and normalized[leaf.len] == '/') return error.NotDirectory;
            if (std.mem.eql(u8, normalized, leaf)) {
                if (std.mem.endsWith(u8, name, "/") or std.mem.endsWith(u8, name, "/.")) return error.NotDirectory;
                return kind;
            }
        }
        return null;
    }
    pub fn procPath(allocator: std.mem.Allocator, name: []const u8, current_pid: u32) !?Path {
        if (!std.fs.path.isAbsolutePosix(name)) return null;
        const normalized = try std.fs.path.resolvePosix(allocator, &.{name});
        defer allocator.free(normalized);
        if (!std.mem.eql(u8, normalized, "/proc") and !std.mem.startsWith(u8, normalized, "/proc/")) return null;
        if (std.mem.eql(u8, normalized, "/proc")) return .{ .kind = .proc_root };
        const rest = normalized[6..];
        const separator = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const process_name = rest[0..separator];
        const self = std.mem.eql(u8, process_name, "self");
        const pid = if (self) current_pid else std.fmt.parseInt(u32, process_name, 10) catch return .{ .kind = .missing };
        if (pid == 0) return .{ .kind = .missing };
        if (separator == rest.len) {
            if (self) return .{ .kind = .proc_self, .pid = pid };
            return .{ .kind = .proc_pid, .pid = pid };
        }
        const leaf = rest[separator + 1 ..];
        if (std.mem.eql(u8, leaf, "stat")) return .{ .kind = .proc_stat, .pid = pid };
        if (std.mem.eql(u8, leaf, "status")) return .{ .kind = .proc_status, .pid = pid };
        if (std.mem.eql(u8, leaf, "cmdline")) return .{ .kind = .proc_cmdline, .pid = pid };
        if (std.mem.eql(u8, leaf, "comm")) return .{ .kind = .proc_comm, .pid = pid };
        if (std.mem.endsWith(u8, name, "/") or std.mem.endsWith(u8, name, "/.")) return error.NotDirectory;
        return .{ .kind = .missing, .pid = pid };
    }
    pub fn isDirectory(d: Device) bool {
        return d.kind == .proc_root or d.kind == .proc_pid or d.kind == .proc_self;
    }
    fn readableFile(d: Device) bool {
        return d.kind == .mounts or d.kind == .meminfo or d.kind == .proc_stat or d.kind == .proc_status or d.kind == .proc_cmdline or d.kind == .proc_comm;
    }
    pub fn dirEntry(d: Device, index: usize) ?DirEntry {
        if (d.kind == .proc_root) {
            const fixed = [_]DirEntry{
                .{ .name = ".", .inode = 2, .kind = 4 },
                .{ .name = "..", .inode = 2, .kind = 4 },
                .{ .name = "self", .inode = 3, .kind = 10 },
                .{ .name = "mounts", .inode = 6, .kind = 8 },
                .{ .name = "meminfo", .inode = 7, .kind = 8 },
            };
            if (index < fixed.len) return fixed[index];
            const process_index = index - fixed.len;
            if (process_index >= d.proc_pid_count) return null;
            const pid = d.proc_pids[process_index];
            return .{ .name = "", .inode = pid, .kind = 4, .pid = pid };
        }
        if (d.kind != .proc_pid) return null;
        const fixed = [_]DirEntry{
            .{ .name = ".", .inode = d.pid, .kind = 4 },
            .{ .name = "..", .inode = 2, .kind = 4 },
            .{ .name = "stat", .inode = 10_000 + @as(u64, d.pid) * 4, .kind = 8 },
            .{ .name = "status", .inode = 10_001 + @as(u64, d.pid) * 4, .kind = 8 },
            .{ .name = "cmdline", .inode = 10_002 + @as(u64, d.pid) * 4, .kind = 8 },
            .{ .name = "comm", .inode = 10_003 + @as(u64, d.pid) * 4, .kind = 8 },
        };
        return if (index < fixed.len) fixed[index] else null;
    }
    pub fn dirEntryCount(d: Device) usize {
        return if (d.kind == .proc_root) 5 + d.proc_pid_count else if (d.kind == .proc_pid) 6 else 0;
    }
    pub fn permitsIO(d: Device, writing: bool) bool {
        return d.status & 3 != (if (writing) @as(u64, 0) else 1);
    }
    pub fn readOnly(kind: Kind) bool {
        return kind == .mounts or kind == .meminfo or kind == .proc_root or kind == .proc_pid or kind == .proc_self or kind == .proc_stat or kind == .proc_status or kind == .proc_cmdline or kind == .proc_comm;
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
        return statPath(.{ .kind = kind });
    }
    pub fn statPath(entry: Path) host.FileStat {
        const kind = entry.kind;
        if (kind == .proc_root or kind == .proc_pid) return .{ .dev = 0, .ino = if (kind == .proc_root) 2 else 100 + @as(u64, entry.pid), .mode = 0o40555, .nlink = 2, .uid = if (kind == .proc_root) 0 else 1000, .gid = if (kind == .proc_root) 0 else 1000, .rdev = 0, .size = 0, .blksize = 4096, .blocks = 0, .atime = .{ .sec = 0, .nsec = 0 }, .mtime = .{ .sec = 0, .nsec = 0 }, .ctime = .{ .sec = 0, .nsec = 0 } };
        if (kind == .proc_self) return .{ .dev = 0, .ino = 3, .mode = 0o120777, .nlink = 1, .uid = 0, .gid = 0, .rdev = 0, .size = @intCast(std.fmt.count("{d}", .{entry.pid})), .blksize = 4096, .blocks = 0, .atime = .{ .sec = 0, .nsec = 0 }, .mtime = .{ .sec = 0, .nsec = 0 }, .ctime = .{ .sec = 0, .nsec = 0 } };
        if (kind == .mounts or kind == .meminfo) return .{ .dev = 0, .ino = if (kind == .mounts) 6 else 7, .mode = 0o100444, .nlink = 1, .uid = 0, .gid = 0, .rdev = 0, .size = if (kind == .mounts) mount_list.len else 0, .blksize = 4096, .blocks = 0, .atime = .{ .sec = 0, .nsec = 0 }, .mtime = .{ .sec = 0, .nsec = 0 }, .ctime = .{ .sec = 0, .nsec = 0 } };
        if (kind == .proc_stat or kind == .proc_status or kind == .proc_cmdline or kind == .proc_comm) return .{ .dev = 0, .ino = 10_000 + @as(u64, entry.pid) * 4 + @as(u64, @intFromEnum(kind) - @intFromEnum(Kind.proc_stat)), .mode = 0o100444, .nlink = 1, .uid = 1000, .gid = 1000, .rdev = 0, .size = 0, .blksize = 4096, .blocks = 0, .atime = .{ .sec = 0, .nsec = 0 }, .mtime = .{ .sec = 0, .nsec = 0 }, .ctime = .{ .sec = 0, .nsec = 0 } };
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
