const Memory = @import("memory.zig").Memory;
const Architecture = @import("loader/elf.zig").Architecture;
const ir = @import("ir.zig");
pub fn decode(m: *Memory, arch: Architecture, pc: u64) !ir.Instruction {
    return switch (arch) {
        .x86_64 => @import("cpu/x86_64.zig").decode(m, pc),
        .riscv64 => @import("cpu/riscv64.zig").decode(m, pc),
        .arm64 => @import("cpu/arm64.zig").decode(m, pc),
    };
}
