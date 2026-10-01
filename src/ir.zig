const std = @import("std");
pub const Reg = struct { index: u6, high: bool = false };
pub const Address = struct { segment: enum { none, fs, gs } = .none, index_width: u7 = 64, index_signed: bool = false, base: ?u6 = null, index: ?u6 = null, scale: u3 = 0, displacement: i64 = 0, relative: bool = false };
pub const Shifted = struct { index: u6, kind: enum { lsl, lsr, asr, ror } = .lsl, amount: u6 = 0, width: u7 = 64, invert: bool = false, extend_signed: bool = false, mask: u64 = 0xffffffffffffffff };
pub const Operand = union(enum) { none, vector: u5, shifted: Shifted, reg: Reg, imm: u64, mem: Address, address: Address };
pub fn reg(i: u6) Operand {
    return .{ .reg = .{ .index = i } };
}
pub fn imm(i: u64) Operand {
    return .{ .imm = i };
}
pub const Condition = enum { always, eq, ne, lt, ge, le, gt, below, above_equal, below_equal, above, overflow, no_overflow, sign, no_sign, parity, no_parity };
pub const Op = enum { atomic_swap, atomic_add, atomic_xor, atomic_and, atomic_or, atomic_min_signed, atomic_max_signed, atomic_min_unsigned, atomic_max_unsigned, load_exclusive, store_exclusive, clear_exclusive, bit_reverse, zero_block, vector_duplicate, vector_load_pair, vector_store_pair, count_trailing_zeros, count_leading_zeros, direction, string_move, string_store, string_load, string_compare, string_scan, vector_shl, vector_shr, vector_sar, vector_byte_shl, vector_byte_shr, vector_add, vector_sub, vector_add_saturate_signed, vector_add_saturate_unsigned, vector_sub_saturate_signed, vector_sub_saturate_unsigned, vector_mul_low, vector_mul_low_dword, vector_mul_signed_even_dword, vector_extend, vector_mul_high_signed, vector_mul_high_unsigned, vector_mul_high_round, vector_mul_even_unsigned, vector_madd_signed, vector_madd_unsigned_signed_sat, vector_average_unsigned, vector_sum_abs_diff, vector_mpsadbw, vector_pack_signed_byte, vector_pack_signed_word, vector_pack_unsigned_byte, vector_pack_unsigned_word, vector_minpos_unsigned_word, vector_test, vector_blend, vector_blend_variable, vector_insert_lane, vector_insert_ps, vector_round, vector_dot, vector_shuffle_bytes, vector_sign, vector_abs, vector_align_right, vector_horizontal_add, vector_horizontal_add_saturate_signed, vector_horizontal_sub, vector_horizontal_sub_saturate_signed, vector_min_unsigned, vector_max_unsigned, vector_min_signed, vector_max_signed, vector_compare_equal, vector_compare_greater_signed, vector_mask, scalar_to_vector, vector_to_scalar, vector_move_low, vector_unpack_low, vector_unpack_high, vector_shuffle, conditional_compare_add, conditional_compare_sub, bit_test, bit_set, bit_reset, bit_complement, bit_scan_forward, bit_scan_reverse, cmpxchg, vector_mov, vector_xor, vector_and, vector_and_not, vector_or, bitfield_unsigned, bitfield_signed, bitfield_insert, load_pair, store_pair, madd, msub, select, rol, ror, set_compare, mul_high_signed, mul_high_mixed, mul_high_unsigned, divide_signed, divide_unsigned, remainder_signed, remainder_unsigned, riscv_fp, nop, mov, movzx, movsx, lea, add, sub, adc, sbb, and_, or_, xor, cmp, test_, inc, dec, neg, not_, shl, shr, sar, imul, mul, div, idiv, push, pop, branch, call, ret, setcc, cmov, exchange, sign_extend, syscall };
pub const Instruction = struct {
    op: Op,
    repeat: enum { none, count, equal, not_equal } = .none,
    address_width: u7 = 64,
    dst: Operand = .none,
    src: Operand = .none,
    lhs: ?Operand = null,
    rhs: ?Operand = null,
    width: u7 = 64,
    source_width: u7 = 0,
    condition: Condition = .always,
    set_flags: bool = true,
    sign_result: bool = false,
    multiply_signed: bool = false,
    vector_element: u4 = 1,
    vector_bytes: u5 = 16,
    vector_index: u4 = 0,
    vector_high: bool = false,
    shuffle: u8 = 0,
    vector_aligned: bool = false,
    rotate: u6 = 0,
    bit_mask: u64 = 0,
    top_mask: u64 = 0,
    sign_bit: u6 = 0,
    false_op: enum { none, inc, invert, negate } = .none,
    update_reg: ?u6 = null,
    update_delta: i64 = 0,
    target_mask: u64 = 0xffffffffffffffff,
    pc: u64 = 0,
    next: u64 = 0,
    encoding: u32 = 0,
};
pub fn mask(width: u7) u64 {
    return if (width == 64) std.math.maxInt(u64) else (@as(u64, 1) << @as(u6, @intCast(width))) - 1;
}
pub fn signed(value: u64, width: u7) i64 {
    const shift: u6 = @intCast(64 - width);
    return @as(i64, @bitCast(value << shift)) >> shift;
}
test "width masks and sign extension" {
    try std.testing.expectEqual(@as(u64, 0xffffffff), mask(32));
    try std.testing.expectEqual(@as(i64, -128), signed(128, 8));
}

pub fn rotate(value: u64, width: u7, amount: u6) u64 {
    const n = amount & @as(u6, @intCast(width - 1));
    const v = value & mask(width);
    if (n == 0) return v;
    return ((v >> n) | @as(u64, @truncate(@as(u128, v) << @as(u7, @intCast(width - n))))) & mask(width);
}
