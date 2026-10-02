const Architecture = @import("../loader/elf.zig").Architecture;
pub const Flags = struct {
    carry: bool = false,
    auxiliary: bool = false,
    parity: bool = false,
    zero: bool = false,
    sign: bool = false,
    overflow: bool = false,
    direction: bool = false,
    pub fn bits(f: Flags) u64 {
        return 2 | @as(u64, @intFromBool(f.carry)) | (@as(u64, @intFromBool(f.parity)) << 2) | (@as(u64, @intFromBool(f.auxiliary)) << 4) | (@as(u64, @intFromBool(f.zero)) << 6) | (@as(u64, @intFromBool(f.sign)) << 7) | (@as(u64, @intFromBool(f.direction)) << 10) | (@as(u64, @intFromBool(f.overflow)) << 11);
    }
};
pub const X86Fp = struct {
    control: u16 = 0x37f,
    status: u16 = 0,
    tag: u8 = 0,
    opcode: u16 = 0,
    instruction_pointer: u64 = 0,
    data_pointer: u64 = 0,
    code_selector: u16 = 0,
    data_selector: u16 = 0,
    registers: [8][10]u8 = @splat(@splat(0)),
    mxcsr: u32 = 0x1f80,
    pub fn checkPending(f: X86Fp) !void {
        if (f.status & ~f.control & 0x3f != 0) return error.FloatingPointException;
    }
    pub fn enterMmx(f: *X86Fp) void {
        f.tag = 0xff;
        f.status &= ~@as(u16, 0x3800);
    }
};
pub const State = struct {
    architecture: Architecture,
    vectors: [32][16]u8 = @splat(@splat(0)),
    fp_registers: [32]u64 = @splat(0),
    fp_flags: u5 = 0,
    fp_rounding_mode: u3 = 0,
    arm_fpsr: u32 = 0,
    arm_fpcr: u32 = 0,
    x86_fp: X86Fp = .{},
    registers: [34]u64 = @splat(0),
    pc: u64 = 0,
    fs_base: u64 = 0,
    gs_base: u64 = 0,
    flags: Flags = .{},
    instructions: u64 = 0,
    exclusive: ?struct { address: u64, width: u7, writes: u64, generation: u64 } = null,
    pub fn get(s: State, index: u6) u64 {
        if ((s.architecture == .riscv64 and index == 0) or (s.architecture == .arm64 and index == 32)) return 0;
        return s.registers[index];
    }
    pub fn set(s: *State, index: u6, value: u64) void {
        if ((s.architecture == .riscv64 and index == 0) or (s.architecture == .arm64 and index == 32)) return;
        s.registers[index] = value;
    }
    pub fn getVector(s: *const State, index: u5) [16]u8 {
        if (s.architecture == .x86_64 and index >= 16 and index < 24) {
            var bytes: [16]u8 = @splat(0);
            @memcpy(bytes[0..8], s.x86_fp.registers[index - 16][0..8]);
            return bytes;
        }
        return s.vectors[index];
    }
    pub fn setVector(s: *State, index: u5, bytes: [16]u8) void {
        if (s.architecture == .x86_64 and index >= 16 and index < 24) {
            @memcpy(s.x86_fp.registers[index - 16][0..8], bytes[0..8]);
            s.x86_fp.registers[index - 16][8] = 0xff;
            s.x86_fp.registers[index - 16][9] = 0xff;
            s.x86_fp.enterMmx();
        } else s.vectors[index] = bytes;
    }
    pub fn stackRegister(s: State) u6 {
        return switch (s.architecture) {
            .x86_64 => 4,
            .riscv64 => 2,
            .arm64 => 31,
        };
    }
};
