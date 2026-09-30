//! Bounded, deterministic mutation runner; no guest host syscalls are dispatched.
const std = @import("std");
const host = @import("host.zig");
const elf = @import("loader/elf.zig");
const pe = @import("loader/pe.zig");
const macho = @import("loader/macho.zig");
const Linker = @import("loader/pe_linker.zig").Linker;
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 3) return error.UsageFuzzCountAndCorpusPaths;
    const count = try std.fmt.parseInt(u32, args[1], 10);
    if (count > 1_000_000) return error.TooManyFuzzCases;
    const corpus = try a.alloc([]u8, args.len - 2);
    for (args[2..], 0..) |path, n| {
        corpus[n] = try host.readFile(a, path);
        if (corpus[n].len == 0) return error.EmptyCorpus;
    }
    var rng = std.Random.DefaultPrng.init(0x554e495645525345);
    const random = rng.random();
    var memory = Memory.init(a);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    for (0..count) |_| {
        const bytes = corpus[random.uintLessThan(usize, corpus.len)];
        const n = random.uintLessThan(u8, 8) + 1;
        var positions: [8]usize = undefined;
        var old: [8]u8 = undefined;
        for (0..n) |j| {
            positions[j] = random.uintLessThan(usize, @min(bytes.len, 4096));
            old[j] = bytes[positions[j]];
            bytes[positions[j]] = random.int(u8);
        }
        _ = elf.parse(bytes) catch {};
        if (pe.parse(bytes)) |image| {
            if (image.is_dll) exportLookup(image) catch {};
        } else |_| {}
        if (macho.parse(bytes)) |image| {
            var guest = Memory.init(std.heap.page_allocator);
            defer guest.deinit();
            var state = State{ .architecture = image.architecture };
            image.load(&guest, &state) catch {};
        } else |_| {}
        var j: usize = n;
        while (j > 0) {
            j -= 1;
            bytes[positions[j]] = old[j];
        }
        var code: [32]u8 = undefined;
        random.bytes(&code);
        try memory.initialize(0x1000, &code);
        for ([_]elf.Architecture{ .x86_64, .riscv64, .arm64 }) |arch| {
            const instruction = @import("cpu.zig").decode(&memory, arch, 0x1000) catch continue;
            var state = State{ .architecture = arch };
            for (&state.registers) |*r| r.* = random.int(u64);
            state.set(state.stackRegister(), 0x1800);
            _ = @import("interpreter.zig").execute(&state, &memory, instruction) catch {};
        }
    }
    try host.print(1, "Fuzz smoke passed: {d} corpus mutations (including checked DLL exports and Mach-O loads), {d} random decoder cases (interpreted when decoded); seed=0x554e495645525345\n", .{ count, @as(u64, count) * 3 });
}
fn exportLookup(image: pe.Image) !void {
    const a = std.heap.page_allocator;
    var memory = Memory.init(a);
    defer memory.deinit();
    try image.load(&memory, image.base);
    var linker = Linker{ .allocator = a };
    defer linker.deinit();
    const name = try a.dupe(u8, "fuzz.dll");
    errdefer a.free(name);
    try linker.modules.append(a, .{ .name = name, .base = image.base, .size = image.image_size, .entry = 0, .imports = try image.directory(1), .exports = try image.directory(0) });
    _ = linker.resolve(&memory, 0, .{ .name = "helper_add" }, false, 0) catch {};
    _ = linker.resolve(&memory, 0, .{ .ordinal = 7 }, false, 0) catch {};
}
