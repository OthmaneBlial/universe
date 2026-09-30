const std = @import("std");
const ir = @import("ir.zig");
const host = @import("host.zig");
fn operand(buf: []u8, o: ir.Operand) ![]const u8 {
    return switch (o) {
        .none => "_",
        .shifted => |v| std.fmt.bufPrint(buf, "r{d} {s} {d}", .{ v.index, @tagName(v.kind), v.amount }),
        .imm => |v| std.fmt.bufPrint(buf, "0x{x}", .{v}),
        .reg => |r| std.fmt.bufPrint(buf, "r{d}{s}", .{ r.index, if (r.high) ".high8" else "" }),
        .mem, .address => |a| std.fmt.bufPrint(buf, "guest[{s}{?d} + r{?d}*{d} + {d}]", .{ if (a.relative) "next_pc + " else "r", a.base, a.index, @as(u8, 1) << a.scale, a.displacement }),
    };
}
pub fn instruction(fd: c_int, i: ir.Instruction) !void {
    var a: [180]u8 = undefined;
    var b: [180]u8 = undefined;
    var l: [180]u8 = undefined;
    var r: [180]u8 = undefined;
    try host.print(fd, "{x:0>16}  {s}.{d} {s}, {s} [{s}]", .{ i.pc, @tagName(i.op), i.width, try operand(&a, i.dst), try operand(&b, i.src), @tagName(i.condition) });
    if (i.lhs) |v| try host.print(fd, " lhs={s}", .{try operand(&l, v)});
    if (i.rhs) |v| try host.print(fd, " rhs={s}", .{try operand(&r, v)});
    try host.output(fd, "\n");
}
