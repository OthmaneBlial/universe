const Architecture = @import("../loader/elf.zig").Architecture;
pub const Flags = struct {
    carry: bool = false,
    parity: bool = false,
    zero: bool = false,
    sign: bool = false,
    overflow: bool = false,
    direction: bool = false,
    pub fn bits(f: Flags) u64 {
        return 2 | @as(u64, @intFromBool(f.carry)) | (@as(u64, @intFromBool(f.parity)) << 2) | (@as(u64, @intFromBool(f.zero)) << 6) | (@as(u64, @intFromBool(f.sign)) << 7) | (@as(u64, @intFromBool(f.direction)) << 10) | (@as(u64, @intFromBool(f.overflow)) << 11);
    }
};
pub const State = struct {
    architecture: Architecture,
    vectors: [16][16]u8 = @splat(@splat(0)),
    registers: [34]u64 = @splat(0),
    pc: u64 = 0,
    fs_base: u64 = 0,
    gs_base: u64 = 0,
    flags: Flags = .{},
    instructions: u64 = 0,
    pub fn get(s: State, index: u6) u64 {
        if ((s.architecture == .riscv64 and index == 0) or (s.architecture == .arm64 and index == 32)) return 0;
        return s.registers[index];
    }
    pub fn set(s: *State, index: u6, value: u64) void {
        if ((s.architecture == .riscv64 and index == 0) or (s.architecture == .arm64 and index == 32)) return;
        s.registers[index] = value;
    }
    pub fn stackRegister(s: State) u6 {
        return switch (s.architecture) {
            .x86_64 => 4,
            .riscv64 => 2,
            .arm64 => 31,
        };
    }
};
