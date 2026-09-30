const ir = @import("ir.zig");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
pub fn address(s: *State, a: ir.Address, next: u64) u64 {
    return (switch (a.segment) {
        .none => @as(u64, 0),
        .fs => s.fs_base,
        .gs => s.gs_base,
    }) +% (if (a.relative) next else if (a.base) |r| s.get(r) else @as(u64, 0)) +% (if (a.index) |r| (if (a.index_signed) @as(u64, @bitCast(ir.signed(s.get(r), a.index_width))) else s.get(r) & ir.mask(a.index_width)) << a.scale else @as(u64, 0)) +% @as(u64, @bitCast(a.displacement));
}
pub fn read(s: *State, m: *Memory, o: ir.Operand, width: u7, next: u64) !u64 {
    return (switch (o) {
        .vector => return error.InvalidOperand,
        .none => @as(u64, 0),
        .shifted => |r| blk: {
            const raw = s.get(r.index) & ir.mask(r.width);
            const v = if (r.extend_signed) @as(u64, @bitCast(ir.signed(raw, r.width))) else raw;
            const shifted = switch (r.kind) {
                .lsl => v << r.amount,
                .lsr => v >> r.amount,
                .asr => @as(u64, @bitCast(ir.signed(v, r.width) >> r.amount)),
                .ror => ir.rotate(v, r.width, r.amount),
            };
            break :blk (if (r.invert) ~shifted else shifted) & r.mask;
        },
        .imm => |v| v,
        .reg => |r| if (r.high) s.get(r.index) >> 8 else s.get(r.index),
        .address => |a| address(s, a, next),
        .mem => |a| try m.readInt(address(s, a, next), width, .read),
    }) & ir.mask(width);
}
pub fn write(s: *State, m: *Memory, o: ir.Operand, width: u7, value: u64, next: u64) !void {
    const v = value & ir.mask(width);
    switch (o) {
        .reg => |r| {
            const old = s.get(r.index);
            s.set(r.index, if (r.high) (old & ~@as(u64, 0xff00)) | (v << 8) else if (width >= 32) v else (old & ~ir.mask(width)) | v);
        },
        .mem => |a| try m.writeInt(address(s, a, next), width, v),
        else => return error.InvalidDestination,
    }
}
