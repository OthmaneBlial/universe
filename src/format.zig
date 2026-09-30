const std = @import("std");
const ir = @import("ir.zig");
const host = @import("host.zig");
fn operand(buf: []u8, o: ir.Operand) ![]const u8 {
    return switch (o) {
        .none => "_",
        .vector => |r| std.fmt.bufPrint(buf, "xmm{d}", .{r}),
        .shifted => |v| std.fmt.bufPrint(buf, "r{d} {s} {d}", .{ v.index, @tagName(v.kind), v.amount }),
        .imm => |v| std.fmt.bufPrint(buf, "0x{x}", .{v}),
        .reg => |r| std.fmt.bufPrint(buf, "r{d}{s}", .{ r.index, if (r.high) ".high8" else "" }),
        .mem, .address => |a| blk: {
            var base: [32]u8 = undefined;
            var index: [32]u8 = undefined;
            const b = if (a.relative) "next_pc" else if (a.base) |r| try std.fmt.bufPrint(&base, "r{d}", .{r}) else "0";
            const x = if (a.index) |r| try std.fmt.bufPrint(&index, " + r{d}*{d}", .{ r, @as(u8, 1) << a.scale }) else "";
            const segment = switch (a.segment) {
                .none => "",
                .fs => "fs + ",
                .gs => "gs + ",
            };
            break :blk try std.fmt.bufPrint(buf, "guest[{s}{s}{s}{s}{d}]", .{ segment, b, x, if (a.displacement < 0) " - " else " + ", @abs(a.displacement) });
        },
    };
}
pub fn instruction(fd: c_int, i: ir.Instruction) !void {
    var a: [180]u8 = undefined;
    var b: [180]u8 = undefined;
    var l: [180]u8 = undefined;
    var r: [180]u8 = undefined;
    try host.print(fd, "{x:0>16}  {s}.{d} {s}, {s} [{s}]", .{ i.pc, @tagName(i.op), switch (i.op) {
        .vector_mov, .vector_xor, .vector_and, .vector_and_not, .vector_or, .vector_unpack_low, .vector_shuffle, .vector_shl, .vector_shr, .vector_sar, .vector_byte_shl, .vector_byte_shr, .vector_min_unsigned, .vector_max_unsigned, .vector_compare_equal => @as(u16, 128),
        else => @as(u16, i.width),
    }, try operand(&a, i.dst), try operand(&b, i.src), @tagName(i.condition) });
    if (i.lhs) |v| try host.print(fd, " lhs={s}", .{try operand(&l, v)});
    if (i.rhs) |v| try host.print(fd, " rhs={s}", .{try operand(&r, v)});
    try host.output(fd, "\n");
}
