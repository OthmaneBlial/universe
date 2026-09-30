const std = @import("std");
const host = @import("../host.zig");
const Memory = @import("../memory.zig").Memory;
const State = @import("../cpu/state.zig").State;
const PE = @import("../loader/pe.zig").Image;
const Api = enum { ExitProcess, GetStdHandle, WriteFile, ReadFile, VirtualAlloc, VirtualFree, GetModuleHandleA, GetLastError };
pub const stub_base: u64 = 0x700000000000;
const Allocation = struct { address: u64, size: usize };
pub const Windows = struct {
    allocator: std.mem.Allocator,
    module_base: u64,
    exit_code: ?u8 = null,
    last_error: u32 = 0,
    trace: bool = false,
    calls: u64 = 0,
    next_map: u64 = 0x200000000,
    allocations: std.ArrayList(Allocation) = .empty,
    pub fn deinit(w: *Windows) void {
        w.allocations.deinit(w.allocator);
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
            .GetModuleHandleA => {
                if (a != 0) return w.fail(126);
                return w.module_base;
            },
            .WriteFile, .ReadFile => {
                if (a < 0x100 or a > 0x102) return w.fail(6);
                if (count > 1024 * 1024) return w.fail(87);
                if (try m.readInt(s.get(4) +% 40, 64, .read) != 0) return w.fail(50);
                try m.check(b, @intCast(count), if (api == .ReadFile) .write else .read);
                if (out != 0) try m.check(out, 4, .write);
                const buf = try w.allocator.alloc(u8, @intCast(count));
                defer w.allocator.free(buf);
                if (api == .WriteFile) try m.read(b, buf, .read);
                const fd: c_int = @intCast(a - 0x100);
                const n = if (api == .WriteFile) host.c.write(fd, buf.ptr, buf.len) else host.c.read(fd, buf.ptr, buf.len);
                if (n < 0) return w.fail(1117);
                if (api == .ReadFile) try m.write(b, buf[0..@intCast(n)]);
                if (out != 0) try m.writeInt(out, 32, @intCast(n));
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
                const size = std.mem.alignForward(usize, @intCast(b), 4096);
                try w.allocations.ensureUnusedCapacity(w.allocator, 1);
                const addr = w.next_map;
                m.map(addr, size, permissions) catch return w.fail(8);
                w.allocations.appendAssumeCapacity(.{ .address = addr, .size = size });
                w.next_map = std.mem.alignForward(u64, addr + size, 65536);
                return addr;
            },
            .VirtualFree => {
                if (b != 0 or count != 0x8000) return w.fail(87);
                for (w.allocations.items, 0..) |allocation, index| if (allocation.address == a) {
                    try m.unmap(a, allocation.size);
                    _ = w.allocations.swapRemove(index);
                    return 1;
                };
                return w.fail(487);
            },
        }
    }
};
test "Windows handles and guest heap lifecycle" {
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
