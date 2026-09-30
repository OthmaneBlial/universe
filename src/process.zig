const std = @import("std");
const Memory = @import("memory.zig").Memory;
const Image = @import("loader/elf.zig").Image;
const State = @import("cpu/state.zig").State;
pub const stack_top: u64 = 0x7ffffff00000;
pub fn stack(a: std.mem.Allocator, m: *Memory, s: *State, image: Image, args: []const [:0]const u8, env: []const []const u8) !void {
    try m.map(stack_top - 1024 * 1024, 1024 * 1024, .{ .read = true, .write = true });
    var sp: u64 = stack_top;
    const argv = try a.alloc(u64, args.len);
    defer a.free(argv);
    const envp = try a.alloc(u64, env.len);
    defer a.free(envp);
    for (args, 0..) |arg, i| {
        sp -= arg.len + 1;
        try m.write(sp, arg);
        try m.writeInt(sp + arg.len, 8, 0);
        argv[i] = sp;
    }
    for (env, 0..) |v, i| {
        sp -= v.len + 1;
        try m.write(sp, v);
        try m.writeInt(sp + v.len, 8, 0);
        envp[i] = sp;
    }
    sp -= 16;
    const random = sp; // Filled by the runtime from the host entropy source.
    const aux = [_]u64{ 3, image.phAddress(), 4, 56, 5, image.phnum, 6, 4096, 7, 0, 9, image.entry, 11, 1000, 12, 1000, 13, 1000, 14, 1000, 23, 0, 25, random, 31, if (argv.len > 0) argv[0] else 0, 0, 0 };
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
    @import("host.zig").c.arc4random_buf(&entropy, entropy.len);
    try m.write(random, &entropy);
}
test "Linux initial stack includes argc, argv, environment, auxv and alignment" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    var s = State{ .architecture = .x86_64 };
    const image = Image{ .bytes = &.{}, .architecture = .x86_64, .entry = 0x1000, .kind = 2, .phoff = 0, .phnum = 0, .shnum = 0 };
    try stack(a, &m, &s, image, &.{ "guest", "arg" }, &.{"KEY=value"});
    const sp = s.get(4);
    try std.testing.expectEqual(@as(u64, 0), sp % 16);
    try std.testing.expectEqual(@as(u64, 2), try m.readInt(sp, 64, .read));
    const ptr = try m.readInt(sp + 8, 64, .read);
    const name = try m.cstring(a, ptr, 100);
    defer a.free(name);
    try std.testing.expectEqualStrings("guest", name);
    try std.testing.expectEqual(@as(u64, 0), try m.readInt(sp + 24, 64, .read));
}
