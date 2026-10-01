const std = @import("std");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
const pe = @import("loader/pe_linker.zig");
const unwind = @import("windows_unwind.zig");

pub const Action = struct { context: State, parent: u64, routine: u64 };
pub const Catch = struct {
    action: Action,
    end: u64,
    begin: u64,
    destination: ?u64,
    reference: bool,
    object_offset: usize,
    size: usize,
    stop: i32,
};
pub const Plan = struct {
    object: []u8,
    actions: std.ArrayList(Action) = .empty,
    caught: ?Catch = null,
    pub fn deinit(p: *Plan, a: std.mem.Allocator) void {
        a.free(p.object);
        p.actions.deinit(a);
    }
};
fn integer(m: *Memory, address: u64) !i32 {
    return @bitCast(@as(u32, @intCast(try m.readInt(address, 32, .read))));
}
fn rva(m: *Memory, module: pe.Module, slot: u64, size: u64) !u64 {
    return module.address(try m.readInt(slot, 32, .read), size);
}
fn executable(m: *Memory, module: pe.Module, slot: u64) !u64 {
    const address = try rva(m, module, slot, 1);
    try m.check(address, 1, .execute);
    return address;
}
fn typeName(m: *Memory, module: pe.Module, descriptor: u64, bytes: *[512]u8) ![]const u8 {
    _ = try module.address(descriptor, 17);
    for (bytes, 0..) |*byte, index| {
        byte.* = @intCast(try m.readInt(try module.address(descriptor + 16 + index, 1), 8, .read));
        if (byte.* == 0) return bytes[0..index];
    }
    return error.WindowsExceptionTypeNameLimit;
}
const Type = struct { properties: u32, descriptor: u32, displacement: i32, virtual_base: i32, size: usize, copy: u32 };
const Throw = struct {
    module: pe.Module,
    attributes: u32,
    types: [64]Type = undefined,
    count: usize,
    fn read(l: *pe.Linker, m: *Memory, info: u64) !Throw {
        const module = l.modules.items[l.containing(info) orelse return error.InvalidWindowsThrowInfo];
        _ = try module.address(info - module.base, 16);
        const attributes: u32 = @intCast(try m.readInt(info, 32, .read));
        if (attributes & ~@as(u32, 7) != 0) return error.WindowsExceptionQualifiersUnsupported;
        if (try m.readInt(info + 4, 32, .read) != 0 or try m.readInt(info + 8, 32, .read) != 0) return error.WindowsExceptionObjectLifetimeUnsupported;
        const array = try rva(m, module, info + 12, 4);
        const count = try integer(m, array);
        // ponytail: 64 catchable types and 4 KiB POD objects; expand for a real failing app.
        if (count < 1 or count > 64) return error.WindowsExceptionTypeLimit;
        _ = try module.address(array - module.base, 4 + @as(u64, @intCast(count)) * 4);
        var result = Throw{ .module = module, .attributes = attributes, .count = @intCast(count) };
        for (result.types[0..result.count], 0..) |*ty, index| {
            const entry = try rva(m, module, array + 4 + index * 4, 28);
            const size = try integer(m, entry + 20);
            if (size < 1 or size > 4096) return error.WindowsExceptionObjectSizeUnsupported;
            ty.* = .{
                .properties = @intCast(try m.readInt(entry, 32, .read)),
                .descriptor = @intCast(try m.readInt(entry + 4, 32, .read)),
                .displacement = try integer(m, entry + 8),
                .virtual_base = try integer(m, entry + 12),
                .size = @intCast(size),
                .copy = @intCast(try m.readInt(entry + 24, 32, .read)),
            };
            var name: [512]u8 = undefined;
            _ = try typeName(m, module, ty.descriptor, &name);
        }
        const primary = result.types[0];
        if (primary.properties & ~@as(u32, 1) != 0 or primary.displacement != 0 or primary.virtual_base != -1 or primary.copy != 0) return error.WindowsExceptionObjectCopyUnsupported;
        return result;
    }
};
fn personalityMatches(m: *Memory, start: u64, expected: u64) !bool {
    var address = start;
    // Compiler import thunks, never execute a vendor exception handler.
    for (0..8) |_| {
        if (address == expected) return true;
        var opcode: [6]u8 = undefined;
        try m.read(address, opcode[0..2], .execute);
        if (opcode[0] == 0xff and opcode[1] == 0x25) {
            try m.read(address, &opcode, .execute);
            const displacement = std.mem.readInt(i32, opcode[2..6], .little);
            address = try m.readInt(try unwind.offset(try unwind.add(address, 6), displacement), 64, .read);
        } else if (opcode[0] == 0xe9) {
            try m.read(address, opcode[0..5], .execute);
            address = try unwind.offset(try unwind.add(address, 5), std.mem.readInt(i32, opcode[1..5], .little));
        } else return false;
    }
    return error.WindowsExceptionPersonalityLimit;
}
const Info = struct {
    module: pe.Module,
    states: i32,
    unwind_map: u64,
    tries: u32,
    try_map: u64,
    state: i32 = -1,
    fn read(m: *Memory, frame: unwind.Frame, pc: u64) !Info {
        const module = frame.module.?;
        const address = try rva(m, module, frame.data.?, 32);
        const magic = try m.readInt(address, 32, .read);
        if (magic != 0x19930520 and magic != 0x19930522) return error.WindowsExceptionInfoVersionUnsupported;
        if (magic == 0x19930522) {
            _ = try module.address(address - module.base, 40);
            if (try m.readInt(address + 32, 32, .read) != 0 or try m.readInt(address + 36, 32, .read) & ~@as(u64, 1) != 0) return error.WindowsExceptionSpecificationUnsupported;
        }
        const states = try integer(m, address + 4);
        const tries = try m.readInt(address + 12, 32, .read);
        const ips = try m.readInt(address + 20, 32, .read);
        // ponytail: bounded live metadata scans; cache only after measured unwind pressure.
        if (states < 0 or states > 4096 or tries > 4096 or ips > 65536) return error.WindowsExceptionMetadataLimit;
        const unwind_map = try rva(m, module, address + 8, @as(u64, @intCast(states)) * 8);
        const try_map = try rva(m, module, address + 16, tries * 20);
        const ip_map = try rva(m, module, address + 24, ips * 8);
        var result = Info{ .module = module, .states = states, .unwind_map = unwind_map, .tries = @intCast(tries), .try_map = try_map };
        for (0..@intCast(states)) |index| {
            const entry = unwind_map + index * 8;
            const next = try integer(m, entry);
            if (next < -1 or next >= index) return error.InvalidWindowsExceptionState;
            if (try m.readInt(entry + 4, 32, .read) != 0) _ = try executable(m, module, entry + 4);
        }
        var previous: u64 = 0;
        for (0..@intCast(ips)) |index| {
            const at = try m.readInt(ip_map + index * 8, 32, .read);
            const state = try integer(m, ip_map + index * 8 + 4);
            if ((index != 0 and at <= previous) or at >= module.size or state < -1 or state >= states) return error.InvalidWindowsExceptionState;
            if (at <= pc - module.base) result.state = state;
            previous = at;
        }
        return result;
    }
    fn caught(info: Info, m: *Memory, thrown: Throw, frame: unwind.Frame, context: State) !?Catch {
        var selected: ?Catch = null;
        var selected_low: i32 = -1;
        var selected_high: i32 = std.math.maxInt(i32);
        for (0..info.tries) |index| {
            const entry = info.try_map + index * 20;
            const low = try integer(m, entry);
            const high = try integer(m, entry + 4);
            const catch_high = try integer(m, entry + 8);
            const count = try m.readInt(entry + 12, 32, .read);
            if (low < 0 or high < low or catch_high < high or catch_high >= info.states or count < 1 or count > 64) return error.InvalidWindowsExceptionTry;
            const handlers = try rva(m, info.module, entry + 16, count * 20);
            var matching: ?Catch = null;
            for (0..@intCast(count)) |n| {
                const handler = handlers + n * 20;
                const adjectives = try m.readInt(handler, 32, .read);
                const descriptor = try m.readInt(handler + 4, 32, .read);
                const displacement = try integer(m, handler + 8);
                const routine = try executable(m, info.module, handler + 12);
                const active = info.state >= low and info.state <= high;
                if (adjectives & ~@as(u64, 0x4b) != 0) {
                    if (active) return error.WindowsExceptionCatchQualifiersUnsupported;
                    continue;
                }
                var ty_match: ?Type = null;
                if (descriptor != 0) {
                    var catch_name: [512]u8 = undefined;
                    const name = try typeName(m, info.module, descriptor, &catch_name);
                    for (thrown.types[0..thrown.count]) |ty| {
                        var throw_name: [512]u8 = undefined;
                        if (std.mem.eql(u8, name, try typeName(m, thrown.module, ty.descriptor, &throw_name))) {
                            ty_match = ty;
                            break;
                        }
                    }
                } else if (adjectives & 0x40 == 0) return error.InvalidWindowsExceptionCatch;
                if (!active or matching != null or (descriptor != 0 and ty_match == null)) continue;
                if (thrown.attributes & 1 != 0 and adjectives & 1 == 0) continue;
                if (thrown.attributes & 2 != 0 and adjectives & 2 == 0) continue;
                const ty = ty_match orelse thrown.types[0];
                if (ty.properties & ~@as(u32, 1) != 0 or ty.virtual_base != -1 or ty.copy != 0 or ty.displacement < 0 or @as(u64, @intCast(ty.displacement)) + ty.size > thrown.types[0].size) return error.WindowsExceptionObjectCopyUnsupported;
                const reference = adjectives & 8 != 0;
                const destination = if (descriptor != 0 and displacement != 0) try unwind.offset(frame.establisher, displacement) else null;
                if (destination) |dest| try m.check(dest, if (reference) 8 else ty.size, .write);
                matching = .{ .action = .{ .context = context, .parent = frame.establisher, .routine = routine }, .begin = frame.begin, .end = frame.end, .destination = destination, .reference = reference, .object_offset = @intCast(ty.displacement), .size = ty.size, .stop = low - 1 };
            }
            if (matching != null and (low > selected_low or (low == selected_low and high < selected_high))) {
                selected = matching;
                selected_low = low;
                selected_high = high;
            }
        }
        return selected;
    }
    fn cleanup(info: Info, a: std.mem.Allocator, m: *Memory, p: *Plan, context: State, parent: u64, stop: i32) !void {
        var state = info.state;
        while (state > stop) {
            const entry = info.unwind_map + @as(u64, @intCast(state)) * 8;
            const next = try integer(m, entry);
            if (next < stop) return error.InvalidWindowsExceptionState;
            if (try m.readInt(entry + 4, 32, .read) != 0) {
                if (p.actions.items.len == 512) return error.WindowsExceptionCleanupLimit;
                try p.actions.append(a, .{ .context = context, .parent = parent, .routine = try executable(m, info.module, entry + 4) });
            }
            state = next;
        }
    }
};
pub fn plan(a: std.mem.Allocator, l: *pe.Linker, m: *Memory, object: u64, throw_info: u64, input: State, personality: u64) !Plan {
    const thrown = try Throw.read(l, m, throw_info);
    var p = Plan{ .object = try a.alloc(u8, thrown.types[0].size) };
    errdefer p.deinit(a);
    try m.read(object, p.object, .read);
    var context = input;
    for (0..64) |_| {
        const frame = try unwind.unwindReturn(l, m, context);
        if (frame.handler) |handler| {
            if (!try personalityMatches(m, handler, personality)) return error.WindowsExceptionPersonalityUnsupported;
            const info = try Info.read(m, frame, context.pc - 1);
            if (try info.caught(m, thrown, frame, context)) |caught| {
                p.caught = caught;
                try info.cleanup(a, m, &p, context, frame.establisher, caught.stop);
                return p;
            }
            try info.cleanup(a, m, &p, context, frame.establisher, -1);
        }
        if (frame.caller.get(4) <= context.get(4)) return error.InvalidWindowsExceptionStack;
        context = frame.caller;
        if (context.pc == 0) return error.WindowsCppExceptionUncaught;
    }
    return error.WindowsExceptionFrameLimit;
}

test "Windows C++ plan matches POD catches and preserves enclosing cleanup state without writes" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 0x5000, .{ .read = true, .write = true, .execute = true });
    var l = pe.Linker{ .allocator = a };
    defer l.deinit();
    try l.modules.append(a, .{ .name = try a.dupe(u8, "exception.exe"), .base = 0x1000, .size = 0x5000, .entry = 0, .imports = .{ .rva = 0, .size = 0 }, .exports = .{ .rva = 0, .size = 0 }, .exceptions = .{ .rva = 0x300, .size = 24 } });
    for ([_]u64{ 0x100, 0x180, 0x500, 0x200, 0x280, 0x600 }, 0..) |v, i| try m.writeInt(0x1300 + i * 4, 32, v);
    for ([_]u64{ 0x1500, 0x1600 }, [_]u64{ 0x700, 0x780 }) |ui, fi| {
        try m.write(ui, &.{ 9, 4, 1, 0, 4, 0x32, 0, 0 });
        try m.writeInt(ui + 8, 32, 0x900);
        try m.writeInt(ui + 12, 32, fi);
    }
    // First frame has one destructor; caller has an outer scope and one active nested scope.
    for ([_]u64{ 0x19930520, 1, 0xa00, 0, 0, 1, 0xa20, 0 }, 0..) |v, i| try m.writeInt(0x1700 + i * 4, 32, v);
    for ([_]u64{ 0x19930522, 4, 0xa40, 1, 0xaa0, 1, 0xa80, 0, 0, 1 }, 0..) |v, i| try m.writeInt(0x1780 + i * 4, 32, v);
    for ([_]u64{ 0xffffffff, 0xd00, 0x100, 0 }, 0..) |v, i| try m.writeInt(0x1a00 + i * 4, 32, v);
    try m.writeInt(0x1a20, 32, 0x100);
    try m.writeInt(0x1a24, 32, 0);
    for ([_]u64{ 0xffffffff, 0xd10, 0, 0, 1, 0xd20, 0, 0 }, 0..) |v, i| try m.writeInt(0x1a40 + i * 4, 32, v);
    try m.writeInt(0x1a80, 32, 0x200);
    try m.writeInt(0x1a84, 32, 2);
    for ([_]u64{ 1, 2, 3, 3, 0xb00 }, 0..) |v, i| try m.writeInt(0x1aa0 + i * 4, 32, v);
    for ([_]u64{ 8, 0xc40, 8, 0xd30, 16, 9, 0xc00, 8, 0xd40, 16, 0x40, 0, 0, 0xd50, 16 }, 0..) |v, i| try m.writeInt(0x1b00 + i * 4, 32, v);
    try m.write(0x1c10, ".?AUPod@@\x00");
    try m.write(0x1c50, ".?AUOther@@\x00");
    for ([_]u64{ 0, 0, 0, 0xcc0 }, 0..) |v, i| try m.writeInt(0x1c80 + i * 4, 32, v);
    for ([_]u64{ 1, 0xce0 }, 0..) |v, i| try m.writeInt(0x1cc0 + i * 4, 32, v);
    for ([_]u64{ 0, 0xc00, 0, 0xffffffff, 0, 4, 0 }, 0..) |v, i| try m.writeInt(0x1ce0 + i * 4, 32, v);
    try m.writeInt(0x4040, 64, 0x1251);
    try m.writeInt(0x4068, 64, 0x1280);
    try m.writeInt(0x4088, 32, 42);
    try m.writeInt(0x4050, 64, 0xaaaaaaaa);
    var s = State{ .architecture = .x86_64, .pc = 0x1151 };
    s.set(4, 0x4020);
    var p = try plan(a, &l, &m, 0x4088, 0x1c80, s, 0x1900);
    defer p.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0 }, p.object);
    try std.testing.expectEqual(@as(usize, 2), p.actions.items.len);
    try std.testing.expectEqual(@as(u64, 0x1d00), p.actions.items[0].routine);
    try std.testing.expectEqual(@as(u64, 0x1d20), p.actions.items[1].routine);
    try std.testing.expectEqual(@as(u64, 0x1d40), p.caught.?.action.routine);
    try std.testing.expectEqual(@as(u64, 0x4050), p.caught.?.destination.?);
    try std.testing.expectEqual(@as(u64, 0xaaaaaaaa), try m.readInt(0x4050, 64, .read));
    try std.testing.expect(p.caught.?.reference);
    // Reject cycles, non-POD copy operations, bad qualifiers and unsupported personalities.
    try m.writeInt(0x1a40 + 16, 32, 2);
    try std.testing.expectError(error.InvalidWindowsExceptionState, plan(a, &l, &m, 0x4088, 0x1c80, s, 0x1900));
    try m.writeInt(0x1a40 + 16, 32, 1);
    try m.writeInt(0x1ce0 + 24, 32, 0xd00);
    try std.testing.expectError(error.WindowsExceptionObjectCopyUnsupported, plan(a, &l, &m, 0x4088, 0x1c80, s, 0x1900));
    try m.writeInt(0x1ce0 + 24, 32, 0);
    try m.writeInt(0x1b00, 32, 0x80);
    try std.testing.expectError(error.WindowsExceptionCatchQualifiersUnsupported, plan(a, &l, &m, 0x4088, 0x1c80, s, 0x1900));
    try m.writeInt(0x1b00, 32, 8);
    try std.testing.expectError(error.WindowsExceptionPersonalityUnsupported, plan(a, &l, &m, 0x4088, 0x1c80, s, 0x1901));
    try std.testing.expectEqual(@as(u64, 0x4020), s.get(4));
    try std.testing.expectEqual(@as(u64, 0xaaaaaaaa), try m.readInt(0x4050, 64, .read));
}
