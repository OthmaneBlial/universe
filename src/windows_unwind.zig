const std = @import("std");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
const Module = @import("loader/pe_linker.zig").Module;
const Linker = @import("loader/pe_linker.zig").Linker;

pub const Frame = struct {
    caller: State,
    establisher: u64,
    module: ?Module = null,
    begin: u64 = 0,
    end: u64 = 0,
    handler: ?u64 = null,
    data: ?u64 = null,
};
pub fn add(address: u64, amount: u64) !u64 {
    return std.math.add(u64, address, amount) catch error.AddressOverflow;
}
pub fn offset(address: u64, amount: i32) !u64 {
    return if (amount < 0) std.math.sub(u64, address, @intCast(-@as(i64, amount))) catch error.AddressOverflow else add(address, @intCast(amount));
}
fn nonvolatile(reg: u4) bool {
    return reg == 3 or reg == 5 or reg == 6 or reg == 7 or reg >= 12;
}
fn word(bytes: []const u8, slot: usize) u64 {
    return std.mem.readInt(u16, bytes[slot * 2 ..][0..2], .little);
}

// The control PC is a suspended call's return address minus one. This internal
// C++ walker does not accept arbitrary PCs in epilogs (which need code scanning).
pub fn unwindReturn(l: *Linker, m: *Memory, input: State) !Frame {
    if (input.pc == 0 or input.architecture != .x86_64) return error.InvalidWindowsUnwindContext;
    const pc = input.pc - 1;
    var result = Frame{ .caller = input, .establisher = input.get(4) };
    if (try l.lookupFunction(m, pc)) |found| {
        const module = l.modules.items[l.handle(found.image_base).?];
        result.module = module;
        result.begin = try add(module.base, try m.readInt(found.entry, 32, .read));
        result.end = try add(module.base, try m.readInt(found.entry + 4, 32, .read));
        var info = try m.readInt(found.entry + 8, 32, .read);
        var original_frame: ?u8 = null;
        // ponytail: 32 chained records per frame; raise only for a real compiler fixture.
        var depth: usize = 0;
        while (true) : (depth += 1) {
            if (depth == 32) return error.WindowsUnwindChainLimit;
            if (info == 0 or info & 3 != 0) return error.InvalidWindowsUnwindInfo;
            const header = try module.address(info, 4);
            var bytes: [514]u8 = undefined;
            try m.read(header, bytes[0..4], .read);
            if (bytes[0] & 7 != 1) return error.WindowsUnwindVersionUnsupported;
            const flags = bytes[0] >> 3;
            if (flags > 7 or (flags & 4 != 0 and flags & 3 != 0)) return error.InvalidWindowsUnwindInfo;
            const count: usize = bytes[2];
            const frame_reg: u4 = @truncate(bytes[3]);
            if ((frame_reg == 0 and bytes[3] != 0) or (frame_reg != 0 and !nonvolatile(frame_reg))) return error.InvalidWindowsUnwindInfo;
            if (original_frame) |frame| {
                if (bytes[3] != frame) return error.InvalidWindowsUnwindInfo;
            } else original_frame = bytes[3];
            const codes = try module.address(info + 4, count * 2);
            try m.read(codes, bytes[4 .. 4 + count * 2], .read);
            const slots = bytes[4 .. 4 + count * 2];
            const prolog_offset = if (depth == 0) pc - result.begin else std.math.maxInt(u64);
            const in_prolog = prolog_offset < bytes[1];
            var frame_set = !in_prolog;
            var i: usize = 0;
            var previous: u8 = bytes[1];
            // Validate every slot before consulting stack memory, including skipped prolog operations.
            while (i < count) {
                const at = slots[i * 2];
                const op = slots[i * 2 + 1] & 15;
                const reg: u4 = @truncate(slots[i * 2 + 1] >> 4);
                if (at > previous) return error.InvalidWindowsUnwindInfo;
                previous = at;
                const extra: usize = switch (op) {
                    0 => if (nonvolatile(reg)) 0 else return error.InvalidWindowsUnwindInfo,
                    1 => if (reg < 2) @as(usize, reg) + 1 else return error.InvalidWindowsUnwindInfo,
                    2 => 0,
                    3 => if (reg == 0 and frame_reg != 0) 0 else return error.InvalidWindowsUnwindInfo,
                    4, 5 => if (nonvolatile(reg)) (if (op == 4) @as(usize, 1) else 2) else return error.InvalidWindowsUnwindInfo,
                    8, 9 => if (reg >= 6) (if (op == 8) @as(usize, 1) else 2) else return error.InvalidWindowsUnwindInfo,
                    else => return error.WindowsUnwindOperationUnsupported,
                };
                if (extra >= count - i) return error.InvalidWindowsUnwindInfo;
                if (op == 3 and at <= prolog_offset) frame_set = true;
                i += extra + 1;
            }
            const base = if (frame_reg != 0 and frame_set) std.math.sub(u64, input.get(frame_reg), @as(u64, bytes[3] >> 4) * 16) catch return error.AddressOverflow else input.get(4);
            if (depth == 0) result.establisher = base;
            i = 0;
            while (i < count) {
                const op = slots[i * 2 + 1] & 15;
                const reg: u4 = @truncate(slots[i * 2 + 1] >> 4);
                const extra: usize = switch (op) {
                    1 => @as(usize, reg) + 1,
                    4, 8 => 1,
                    5, 9 => 2,
                    else => 0,
                };
                if (!in_prolog or slots[i * 2] <= prolog_offset) {
                    const amount = if (extra == 0) 0 else if (extra == 1) word(slots, i + 1) else word(slots, i + 1) | word(slots, i + 2) << 16;
                    switch (op) {
                        0 => {
                            result.caller.set(reg, try m.readInt(result.caller.get(4), 64, .read));
                            result.caller.set(4, try add(result.caller.get(4), 8));
                        },
                        1 => {
                            const size = if (reg == 0) amount * 8 else amount;
                            if (size == 0 or size & 7 != 0) return error.InvalidWindowsUnwindInfo;
                            result.caller.set(4, try add(result.caller.get(4), size));
                        },
                        2 => result.caller.set(4, try add(result.caller.get(4), @as(u64, reg) * 8 + 8)),
                        3 => result.caller.set(4, base),
                        4, 5 => result.caller.set(reg, try m.readInt(try add(base, if (op == 4) amount * 8 else amount), 64, .read)),
                        8, 9 => try m.read(try add(base, if (op == 8) amount * 16 else amount), &result.caller.vectors[reg], .read),
                        else => unreachable,
                    }
                }
                i += extra + 1;
            }
            const tail = try module.address(info + 4 + std.mem.alignForward(usize, count, 2) * 2, if (flags & 4 != 0) 12 else if (flags & 3 != 0) 4 else 0);
            if (flags & 4 != 0) {
                const start = try m.readInt(tail, 32, .read);
                const end = try m.readInt(tail + 4, 32, .read);
                if (start >= end) return error.InvalidWindowsUnwindInfo;
                try m.check(try module.address(start, end - start), @intCast(end - start), .execute);
                info = try m.readInt(tail + 8, 32, .read);
                continue;
            }
            if (flags & 3 != 0 and !in_prolog) {
                result.handler = try module.address(try m.readInt(tail, 32, .read), 1);
                try m.check(result.handler.?, 1, .execute);
                result.data = try module.address(tail - module.base + 4, 4);
            }
            break;
        }
    }
    result.caller.pc = try m.readInt(result.caller.get(4), 64, .read);
    result.caller.set(4, try add(result.caller.get(4), 8));
    return result;
}

test "Windows return unwind restores stack, saved registers, XMM, frames and completed prologs" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 0x4000, .{ .read = true, .write = true, .execute = true });
    var l = Linker{ .allocator = a };
    defer l.deinit();
    try l.modules.append(a, .{ .name = try a.dupe(u8, "unwind.exe"), .base = 0x1000, .size = 0x4000, .entry = 0, .imports = .{ .rva = 0, .size = 0 }, .exports = .{ .rva = 0, .size = 0 }, .exceptions = .{ .rva = 0x300, .size = 12 } });
    for ([_]u64{ 0x100, 0x180, 0x500 }, 0..) |v, i| try m.writeInt(0x1300 + i * 4, 32, v);
    // sub rsp,64; save RBX and XMM6. Fixed-base saves must precede stack restoration.
    try m.write(0x1500, &.{ 9, 12, 5, 0, 12, 0x68, 1, 0, 8, 0x34, 3, 0, 4, 0x72, 0, 0 });
    try m.writeInt(0x1510, 32, 0x200);
    try m.writeInt(0x1514, 32, 0x700);
    try m.writeInt(0x4018, 64, 0xabcdef);
    try m.write(0x4010, &@as([16]u8, @splat(0x5a)));
    // RBX overlaps the tail of XMM6 here: the expected bytes reflect live memory.
    try m.writeInt(0x4018, 64, 0xabcdef);
    try m.writeInt(0x4040, 64, 0x1234);
    var s = State{ .architecture = .x86_64, .pc = 0x1151, .instructions = 123 };
    s.set(4, 0x4000);
    const f = try unwindReturn(&l, &m, s);
    try std.testing.expectEqual(@as(u64, 0x1234), f.caller.pc);
    try std.testing.expectEqual(@as(u64, 0x4048), f.caller.get(4));
    try std.testing.expectEqual(@as(u64, 0xabcdef), f.caller.get(3));
    try std.testing.expectEqual(@as(u64, 123), f.caller.instructions);
    try std.testing.expectEqual(@as(u64, 0x1200), f.handler.?);
    try std.testing.expectEqual(@as(u64, 0x1514), f.data.?);
    var xmm: [16]u8 = undefined;
    try m.read(0x4010, &xmm, .read);
    try std.testing.expectEqualSlices(u8, &xmm, &f.caller.vectors[6]);
    s.pc = 0x1105; // Allocation completed, register stores have not.
    s.set(3, 99);
    const prolog = try unwindReturn(&l, &m, s);
    try std.testing.expectEqual(@as(u64, 99), prolog.caller.get(3));
    try std.testing.expect(prolog.handler == null);
    // RBP-based frame plus PUSH_NONVOL, SET_FPREG, ALLOC_SMALL.
    try m.write(0x1500, &.{ 1, 9, 3, 0x25, 9, 3, 5, 0x32, 1, 0x50, 0, 0 });
    s.pc = 0x1151;
    s.set(4, 0x3f00); // A dynamic alloca below the fixed frame.
    s.set(5, 0x4020);
    try m.writeInt(0x4020, 64, 0x5678);
    try m.writeInt(0x4028, 64, 0x1234);
    const framed = try unwindReturn(&l, &m, s);
    try std.testing.expectEqual(@as(u64, 0x4000), framed.establisher);
    try std.testing.expectEqual(@as(u64, 0x5678), framed.caller.get(5));
    try std.testing.expectEqual(@as(u64, 0x4030), framed.caller.get(4));
    s.pc = 0x1281; // Table gap: leaf return.
    s.set(4, 0x4028);
    try std.testing.expectEqual(@as(u64, 0x1234), (try unwindReturn(&l, &m, s)).caller.pc);
}

test "Windows chained unwind rejects malformed metadata without changing CPU or guest bytes" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 0x4000, .{ .read = true, .write = true, .execute = true });
    var l = Linker{ .allocator = a };
    defer l.deinit();
    try l.modules.append(a, .{ .name = try a.dupe(u8, "chain.exe"), .base = 0x1000, .size = 0x4000, .entry = 0, .imports = .{ .rva = 0, .size = 0 }, .exports = .{ .rva = 0, .size = 0 }, .exceptions = .{ .rva = 0x300, .size = 12 } });
    for ([_]u64{ 0x100, 0x180, 0x500 }, 0..) |v, i| try m.writeInt(0x1300 + i * 4, 32, v);
    try m.write(0x1500, &.{ 33, 0, 0, 0 });
    for ([_]u64{ 0x100, 0x180, 0x600 }, 0..) |v, i| try m.writeInt(0x1504 + i * 4, 32, v);
    try m.write(0x1600, &.{ 1, 4, 1, 0, 4, 0x32, 0, 0 });
    try m.writeInt(0x4020, 64, 0x1234);
    var s = State{ .architecture = .x86_64, .pc = 0x1151 };
    s.set(4, 0x4000);
    try std.testing.expectEqual(@as(u64, 0x4028), (try unwindReturn(&l, &m, s)).caller.get(4));
    try m.writeInt(0x150c, 32, 0x500);
    try std.testing.expectError(error.WindowsUnwindChainLimit, unwindReturn(&l, &m, s));
    try m.writeInt(0x150c, 32, 0x600);
    for ([_][]const u8{ &.{ 1, 4, 1, 0, 4, 1 }, &.{ 1, 4, 1, 0, 5, 0x32 }, &.{ 1, 4, 1, 0, 4, 0x40 } }) |bad| {
        try m.write(0x1600, bad);
        try std.testing.expectError(error.InvalidWindowsUnwindInfo, unwindReturn(&l, &m, s));
    }
    try m.write(0x1600, &.{ 1, 4, 1, 0, 4, 0x32 });
    s.set(4, 0x5000);
    try std.testing.expectError(error.UnmappedMemory, unwindReturn(&l, &m, s));
    try std.testing.expectEqual(@as(u64, 0x5000), s.get(4));
    try std.testing.expectEqual(@as(u64, 0x1234), try m.readInt(0x4020, 64, .read));
}
