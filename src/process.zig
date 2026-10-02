const std = @import("std");
const Memory = @import("memory.zig").Memory;
const Image = @import("loader/elf.zig").Image;
const State = @import("cpu/state.zig").State;
pub const stack_top: u64 = 0x7ffffff00000;
pub const stack_size: usize = 1024 * 1024;
pub fn copyStrings(a: std.mem.Allocator, m: *Memory, address: u64, remaining: *usize) !std.ArrayList([:0]const u8) {
    var strings: std.ArrayList([:0]const u8) = .empty;
    errdefer freeStrings(a, &strings);
    if (address == 0) return strings;
    var cursor = address;
    while (true) {
        const pointer = try m.readInt(cursor, 64, .read);
        if (pointer == 0) return strings;
        if (remaining.* <= 8) return error.ArgumentListTooLong;
        const text = m.cstring(a, pointer, @min(128 * 1024, remaining.* - 8)) catch |err| return if (err == error.StringTooLong) error.ArgumentListTooLong else err;
        strings.append(a, text) catch |err| {
            a.free(text);
            return err;
        };
        remaining.* -= text.len + 1 + 8;
        cursor = std.math.add(u64, cursor, 8) catch return error.AddressOverflow;
    }
}
pub fn freeStrings(a: std.mem.Allocator, strings: *std.ArrayList([:0]const u8)) void {
    for (strings.items) |text| a.free(text);
    strings.deinit(a);
}
pub fn stack(a: std.mem.Allocator, m: *Memory, s: *State, image: Image, args: []const [:0]const u8, env: []const []const u8, interpreter_base: u64, executable: []const u8) !void {
    try m.map(stack_top - stack_size, stack_size, .{ .read = true, .write = true });
    var sp: u64 = stack_top;
    const argv = try a.alloc(u64, args.len);
    defer a.free(argv);
    const envp = try a.alloc(u64, env.len);
    defer a.free(envp);
    const execfn = try pushString(m, &sp, executable);
    for (args, 0..) |arg, i| {
        argv[i] = try pushString(m, &sp, arg);
    }
    for (env, 0..) |v, i| {
        envp[i] = try pushString(m, &sp, v);
    }
    sp -= 16;
    const random = sp; // Filled by the runtime from the host entropy source.
    const aux = [_]u64{ 3, try image.phAddress(), 4, 56, 5, image.phnum, 6, 4096, 7, interpreter_base, 9, try image.entryAddress(), 11, 1000, 12, 1000, 13, 1000, 14, 1000, 23, 0, 25, random, 31, execfn, 0, 0 };
    const words = 1 + argv.len + 1 + envp.len + 1 + aux.len;
    sp = (sp - words * 8) & ~@as(u64, 15);
    var cursor = sp;
    try m.writeInt(cursor, 64, args.len);
    cursor += 8;
    for (argv) |v| {
        try m.writeInt(cursor, 64, v);
        cursor += 8;
    }
    try m.writeInt(cursor, 64, 0);
    cursor += 8;
    for (envp) |v| {
        try m.writeInt(cursor, 64, v);
        cursor += 8;
    }
    try m.writeInt(cursor, 64, 0);
    cursor += 8;
    for (aux) |v| {
        try m.writeInt(cursor, 64, v);
        cursor += 8;
    }
    s.set(s.stackRegister(), sp);
    var entropy: [16]u8 = undefined;
    try @import("host.zig").random(&entropy);
    try m.write(random, &entropy);
}
fn pushString(m: *Memory, sp: *u64, text: []const u8) !u64 {
    sp.* = std.math.sub(u64, sp.*, text.len + 1) catch return error.AddressOverflow;
    try m.write(sp.*, text);
    try m.writeInt(sp.* + text.len, 8, 0);
    return sp.*;
}
pub fn macStack(a: std.mem.Allocator, m: *Memory, s: *State, args: []const [:0]const u8, env: []const []const u8, main: bool) !void {
    try m.map(stack_top - 1024 * 1024, 1024 * 1024, .{ .read = true, .write = true });
    var sp: u64 = stack_top;
    var words: std.ArrayList(u64) = .empty;
    defer words.deinit(a);
    try words.append(a, args.len);
    for (args) |arg| try words.append(a, try pushString(m, &sp, arg));
    try words.append(a, 0);
    for (env) |entry| try words.append(a, try pushString(m, &sp, entry));
    try words.append(a, 0);
    const path = try std.fmt.allocPrint(a, "executable_path={s}", .{if (args.len != 0) args[0] else ""});
    defer a.free(path);
    try words.append(a, try pushString(m, &sp, path));
    try words.append(a, 0);
    sp = (std.math.sub(u64, sp, words.items.len * 8) catch return error.AddressOverflow) & ~@as(u64, 15);
    for (words.items, 0..) |word, n| try m.writeInt(sp + n * 8, 64, word);
    s.set(s.stackRegister(), sp);
    if (main) {
        const argv = sp + 8;
        const envp = argv + (args.len + 1) * 8;
        const apple = envp + (env.len + 1) * 8;
        const regs: [4]u6 = if (s.architecture == .x86_64) .{ 7, 6, 2, 1 } else .{ 0, 1, 2, 3 };
        for (regs, [_]u64{ args.len, argv, envp, apple }) |r, value| s.set(r, value);
        const return_address = @import("syscall/macos.zig").main_return;
        try m.map(return_address, 4096, .{ .execute = true });
        if (s.architecture == .x86_64) {
            s.set(4, sp - 8);
            try m.writeInt(sp - 8, 64, return_address);
        } else s.set(30, return_address);
    }
}
test "Linux initial stack includes argc, argv, environment, auxv and alignment" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    var s = State{ .architecture = .x86_64 };
    const image = Image{ .bytes = &.{}, .architecture = .x86_64, .entry = 0x1000, .kind = 3, .bias = 0x40000000, .phoff = 0, .phnum = 0, .shnum = 0 };
    try stack(a, &m, &s, image, &.{ "guest", "arg" }, &.{"KEY=value"}, 0x700000000000, "/bin/actual");
    const sp = s.get(4);
    try std.testing.expectEqual(@as(u64, 0), sp % 16);
    try std.testing.expectEqual(@as(u64, 2), try m.readInt(sp, 64, .read));
    const ptr = try m.readInt(sp + 8, 64, .read);
    const name = try m.cstring(a, ptr, 100);
    defer a.free(name);
    try std.testing.expectEqualStrings("guest", name);
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(sp + 24, 64, .read));
    try std.testing.expectEqual(@as(u64, 0x700000000000), try m.readInt(sp + (6 + 9) * 8, 64, .read));
    try std.testing.expectEqual(@as(u64, 0x40001000), try m.readInt(sp + (6 + 11) * 8, 64, .read));
    const execfn = try m.cstring(a, try m.readInt(sp + (6 + 25) * 8, 64, .read), 100);
    defer a.free(execfn);
    try std.testing.expectEqualStrings("/bin/actual", execfn);
}

test "exec string vectors check pointers, combined sizes and allocation failures without changing guest bytes" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.write(0x1100, "a b\x00\xc3\xa9\xf0\x9f\x9a\x80\x00");
    try m.writeInt(0x1000, 64, 0x1100);
    try m.writeInt(0x1008, 64, 0x1104);
    const writes = m.writes;
    for (0..12) |index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        var remaining: usize = 100;
        var strings = copyStrings(failing.allocator(), &m, 0x1000, &remaining) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer freeStrings(failing.allocator(), &strings);
        try std.testing.expectEqual(@as(usize, 2), strings.items.len);
        try std.testing.expectEqualStrings("a b", strings.items[0]);
        try std.testing.expectEqualStrings("é🚀", strings.items[1]);
        try std.testing.expectEqual(@as(usize, 73), remaining);
    }
    var remaining: usize = 10;
    try std.testing.expectError(error.ArgumentListTooLong, copyStrings(a, &m, 0x1000, &remaining));
    remaining = 100;
    try std.testing.expectError(error.UnmappedMemory, copyStrings(a, &m, 0x2000, &remaining));
    try m.writeInt(0x1008, 64, 0x2000);
    try std.testing.expectError(error.UnmappedMemory, copyStrings(a, &m, 0x1000, &remaining));
    try std.testing.expectEqual(writes + 1, m.writes);
}
