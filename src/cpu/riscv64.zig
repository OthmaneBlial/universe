const std = @import("std");
const ir = @import("../ir.zig");
const Memory = @import("../memory.zig").Memory;
fn sx(v: u32, bits: u7) u64 {
    return @bitCast(ir.signed(v, bits));
}
pub fn decode(m: *Memory, pc: u64) !ir.Instruction {
    if (pc % 4 != 0) return error.MisalignedInstruction;
    const b: u32 = @intCast(try m.readInt(pc, 32, .execute));
    if (b & 3 != 3) return error.CompressedInstructionsUnsupported;
    const opcode = b & 127;
    const rd: u6 = @intCast((b >> 7) & 31);
    const rs1: u6 = @intCast((b >> 15) & 31);
    const rs2: u6 = @intCast((b >> 20) & 31);
    const f3: u3 = @intCast((b >> 12) & 7);
    const f7 = b >> 25;
    var i = ir.Instruction{ .op = .nop, .pc = pc, .next = pc +% 4, .set_flags = false, .dst = ir.reg(rd), .lhs = ir.reg(rs1), .src = ir.reg(rs2) };
    switch (opcode) {
        0x37 => {
            i.op = .mov;
            i.src = ir.imm(sx(b & 0xfffff000, 32));
        },
        0x17 => {
            i.op = .mov;
            i.src = ir.imm(pc +% sx(b & 0xfffff000, 32));
        },
        0x6f => {
            const d = ((b >> 31) << 20) | (((b >> 12) & 255) << 12) | (((b >> 20) & 1) << 11) | (((b >> 21) & 1023) << 1);
            i.op = .call;
            i.src = ir.imm(pc +% sx(d, 21));
        },
        0x67 => {
            if (f3 != 0) return error.InvalidInstruction;
            i.op = .call;
            i.src = .{ .address = .{ .base = rs1, .displacement = ir.signed(b >> 20, 12) } };
            i.target_mask = ~@as(u64, 1);
        },
        0x63 => {
            const d = ((b >> 31) << 12) | (((b >> 7) & 1) << 11) | (((b >> 25) & 63) << 5) | (((b >> 8) & 15) << 1);
            i.op = .branch;
            i.src = ir.imm(pc +% sx(d, 13));
            i.rhs = ir.reg(rs2);
            i.condition = switch (f3) {
                0 => .eq,
                1 => .ne,
                4 => .lt,
                5 => .ge,
                6 => .below,
                7 => .above_equal,
                else => return error.InvalidInstruction,
            };
        },
        0x03 => {
            const width: u7 = switch (f3) {
                0, 4 => 8,
                1, 5 => 16,
                2, 6 => 32,
                3 => 64,
                else => return error.InvalidInstruction,
            };
            i.op = if (f3 < 3) .movsx else .movzx;
            i.source_width = width;
            i.src = .{ .mem = .{ .base = rs1, .displacement = ir.signed(b >> 20, 12) } };
        },
        0x23 => {
            i.op = .mov;
            i.width = switch (f3) {
                0 => 8,
                1 => 16,
                2 => 32,
                3 => 64,
                else => return error.InvalidInstruction,
            };
            i.dst = .{ .mem = .{ .base = rs1, .displacement = ir.signed(((b >> 25) << 5) | ((b >> 7) & 31), 12) } };
        },
        0x13, 0x1b => {
            if (opcode == 0x1b) {
                i.width = 32;
                i.sign_result = true;
            }
            i.src = ir.imm(sx(b >> 20, 12));
            i.op = switch (f3) {
                0 => .add,
                1 => .shl,
                2 => .set_compare,
                3 => .set_compare,
                4 => .xor,
                5 => if (b & 0x40000000 != 0) .sar else .shr,
                6 => .or_,
                7 => .and_,
            };
            if (opcode == 0x1b and f3 != 0 and f3 != 1 and f3 != 5) return error.InvalidInstruction;
            if (f3 == 1 or f3 == 5) {
                const upper = b >> @as(u5, if (opcode == 0x1b) 25 else 26);
                if (upper != 0 and !(f3 == 5 and upper == (if (opcode == 0x1b) @as(u32, 32) else 16))) return error.InvalidInstruction;
                i.src = ir.imm((b >> 20) & (if (opcode == 0x1b) @as(u32, 31) else 63));
            }
            if (f3 == 2 or f3 == 3) i.condition = if (f3 == 2) .lt else .below;
        },
        0x33, 0x3b => {
            if (opcode == 0x3b) {
                i.width = 32;
                i.sign_result = true;
            }
            if (f7 == 1) {
                i.op = switch (f3) {
                    0 => .imul,
                    1 => .mul_high_signed,
                    2 => .mul_high_mixed,
                    3 => .mul_high_unsigned,
                    4 => .divide_signed,
                    5 => .divide_unsigned,
                    6 => .remainder_signed,
                    7 => .remainder_unsigned,
                };
                if (opcode == 0x3b and f3 >= 1 and f3 <= 3) return error.InvalidInstruction;
            } else {
                if (f7 != 0 and !(f7 == 32 and (f3 == 0 or f3 == 5))) return error.InvalidInstruction;
                i.op = switch (f3) {
                    0 => if (f7 == 32) .sub else .add,
                    1 => .shl,
                    2 => .set_compare,
                    3 => .set_compare,
                    4 => .xor,
                    5 => if (f7 == 32) .sar else .shr,
                    6 => .or_,
                    7 => .and_,
                };
                if (opcode == 0x3b and f3 != 0 and f3 != 1 and f3 != 5) return error.InvalidInstruction;
                if (f3 == 2 or f3 == 3) i.condition = if (f3 == 2) .lt else .below;
            }
        },
        0x0f => {
            if (f3 != 0) return error.UnsupportedInstruction;
            i.dst = .none;
        },
        0x73 => {
            if (b == 0x73) {
                i.op = .syscall;
                i.dst = .none;
            } else return error.UnsupportedInstruction;
        },
        else => return error.UnsupportedInstruction,
    }
    return i;
}
test "RV64 sign extension, branches and invalid encoding" {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.initialize(0x1000, &.{ 0x93, 0x05, 0xf0, 0xff });
    const i = try decode(&m, 0x1000);
    try std.testing.expectEqual(ir.Op.add, i.op);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), i.src.imm);
    try m.initialize(0x1000, &.{ 0, 0, 0, 0 });
    try std.testing.expectError(error.CompressedInstructionsUnsupported, decode(&m, 0x1000));
}
test "RISC-V decoder fuzz" {
    try std.testing.fuzz({}, fuzz, .{});
}
fn fuzz(_: void, smith: *std.testing.Smith) !void {
    var b: [4]u8 = undefined;
    smith.bytes(&b);
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .execute = true });
    try m.initialize(0x1000, &b);
    _ = decode(&m, 0x1000) catch {};
}
