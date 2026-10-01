#include <stdint.h>
#include "guest.h"

typedef float f32x4 __attribute__((vector_size(16)));
typedef double f64x2 __attribute__((vector_size(16)));
typedef int32_t i32x4 __attribute__((vector_size(16)));
typedef union { f32x4 ps; f64x2 pd; } v128;

#define REG_OP(OP, DST, SRC) __asm__ volatile(OP " %1, %0" : "+x"(DST) : "x"(SRC))
#define MEM_OP(OP, DST, SRC) __asm__ volatile(OP " %1, %0" : "+x"(DST) : "m"(SRC))
#define IMM_REG(OP, IMM, DST, SRC) __asm__ volatile(OP " $" #IMM ", %1, %0" : "+x"(DST) : "x"(SRC))
#define IMM_MEM(OP, IMM, DST, SRC) __asm__ volatile(OP " $" #IMM ", %1, %0" : "+x"(DST) : "m"(SRC))
#define FLAGS_REG(OP, DST, SRC, INDEX) __asm__ volatile(OP " %6, %5\n\tsetc %0\n\tsetz %1\n\tsetp %2\n\tseto %3\n\tsets %4" : "=m"(compare_flags[INDEX][0]), "=m"(compare_flags[INDEX][1]), "=m"(compare_flags[INDEX][2]), "=m"(compare_flags[INDEX][3]), "=m"(compare_flags[INDEX][4]) : "x"(DST), "x"(SRC) : "cc")
#define FLAGS_MEM(OP, DST, SRC, INDEX) __asm__ volatile(OP " %6, %5\n\tsetc %0\n\tsetz %1\n\tsetp %2\n\tseto %3\n\tsets %4" : "=m"(compare_flags[INDEX][0]), "=m"(compare_flags[INDEX][1]), "=m"(compare_flags[INDEX][2]), "=m"(compare_flags[INDEX][3]), "=m"(compare_flags[INDEX][4]) : "x"(DST), "m"(SRC) : "cc")
#define CMP8(TYPE, FIELD, OP, DST, SRC, BASE) do { \
    TYPE cmp = (DST); IMM_REG(OP, 0, cmp, SRC); result[(BASE) + 0].FIELD = cmp; \
    cmp = (DST); IMM_MEM(OP, 1, cmp, SRC); result[(BASE) + 1].FIELD = cmp; \
    cmp = (DST); IMM_REG(OP, 2, cmp, SRC); result[(BASE) + 2].FIELD = cmp; \
    cmp = (DST); IMM_MEM(OP, 3, cmp, SRC); result[(BASE) + 3].FIELD = cmp; \
    cmp = (DST); IMM_REG(OP, 4, cmp, SRC); result[(BASE) + 4].FIELD = cmp; \
    cmp = (DST); IMM_MEM(OP, 5, cmp, SRC); result[(BASE) + 5].FIELD = cmp; \
    cmp = (DST); IMM_REG(OP, 6, cmp, SRC); result[(BASE) + 6].FIELD = cmp; \
    cmp = (DST); IMM_MEM(OP, 7, cmp, SRC); result[(BASE) + 7].FIELD = cmp; \
} while (0)

long guest_main(long *sp) {
    (void)sp;
    static const f32x4 ps_left __attribute__((aligned(16))) = {4, 9, 16, 25};
    static const f32x4 ps_right __attribute__((aligned(16))) = {2, 3, 4, 5};
    static const f64x2 pd_left __attribute__((aligned(16))) = {64, 144};
    static const f64x2 pd_right __attribute__((aligned(16))) = {4, 12};
    static const f32x4 ss_destination __attribute__((aligned(16))) = {16, 9, 4, 1};
    static const f32x4 ss_source __attribute__((aligned(16))) = {4, 3, 2, 1};
    static const f64x2 sd_destination __attribute__((aligned(16))) = {64, 144};
    static const f64x2 sd_source __attribute__((aligned(16))) = {4, 12};
    static const f32x4 min_ps_left __attribute__((aligned(16))) = {3, -4, 0, __builtin_nanf("")};
    static const f32x4 min_ps_right __attribute__((aligned(16))) = {__builtin_nanf(""), -5, -0.0f, 7};
    static const f64x2 min_pd_left __attribute__((aligned(16))) = {64, __builtin_nan("")};
    static const f64x2 min_pd_right __attribute__((aligned(16))) = {4, 7};
    static const f32x4 min_ss_left __attribute__((aligned(16))) = {3, 9, 8, 7};
    static const f32x4 min_ss_right __attribute__((aligned(16))) = {__builtin_nanf(""), 4, 5, 6};
    static const f64x2 min_sd_left __attribute__((aligned(16))) = {64, 99};
    static const f64x2 min_sd_right __attribute__((aligned(16))) = {__builtin_nan(""), 33};
    static const f32x4 cmp_ps_left __attribute__((aligned(16))) = {2, 3, __builtin_nanf(""), -0.0f};
    static const f32x4 cmp_ps_right __attribute__((aligned(16))) = {2, 1, 5, 0.0f};
    static const f64x2 cmp_pd_left __attribute__((aligned(16))) = {2, __builtin_nan("")};
    static const f64x2 cmp_pd_right __attribute__((aligned(16))) = {2, 1};
    static const f32x4 cmp_ss_left __attribute__((aligned(16))) = {2, 9, 8, 7};
    static const f32x4 cmp_ss_right __attribute__((aligned(16))) = {2, 3, 4, 5};
    static const f64x2 cmp_sd_left __attribute__((aligned(16))) = {__builtin_nan(""), 99};
    static const f64x2 cmp_sd_right __attribute__((aligned(16))) = {2, 88};
    static const f32x4 flags_equal_left __attribute__((aligned(16))) = {2, 9, 8, 7};
    static const f32x4 flags_equal_right __attribute__((aligned(16))) = {2, 3, 4, 5};
    static const f32x4 flags_less_left __attribute__((aligned(16))) = {1, 9, 8, 7};
    static const f32x4 flags_less_right __attribute__((aligned(16))) = {2, 3, 4, 5};
    static const f64x2 flags_greater_left __attribute__((aligned(16))) = {3, 99};
    static const f64x2 flags_greater_right __attribute__((aligned(16))) = {2, 88};
    static const f64x2 flags_unordered_left __attribute__((aligned(16))) = {__builtin_nan(""), 99};
    static const f64x2 flags_unordered_right __attribute__((aligned(16))) = {2, 88};
    static const float cvt_ss_round = 2.5f;
    static const double cvt_sd_round __attribute__((aligned(16))) = 3.5;
    static const float cvtt_ss_trunc = -2.9f;
    static const double cvtt_sd_trunc = 4.9;
    static const float cvt_ss_nan = __builtin_nanf("");
    static const double cvt_sd_overflow __attribute__((aligned(16))) = 0x1p63;
    static const float cvtt_ss_infinity = __builtin_huge_valf();
    static const double cvtt_sd_infinity = -__builtin_huge_val();
    static const i32x4 packed_ints __attribute__((aligned(16))) = {16777217, -3, INT32_MIN, INT32_MAX};
    static const f32x4 packed_nearest __attribute__((aligned(16))) = {2.5f, -2.5f, 0x1p31f, __builtin_nanf("")};
    static const f32x4 packed_truncate __attribute__((aligned(16))) = {2.9f, -2.9f, __builtin_huge_valf(), -__builtin_huge_valf()};
    const int64_t cvt_i64_register = INT64_C(9007199254740993);
    const int32_t cvt_i32_register = 16777217;
    volatile uint8_t compare_flags[4][5];
    volatile int64_t conversion_results[8];
    volatile v128 packed_conversion[3];
    volatile v128 result[66];
    f32x4 ps = ps_left; REG_OP("addps", ps, ps_right); result[0].ps = ps;
    ps = ps_left; MEM_OP("subps", ps, ps_right); result[1].ps = ps;
    ps = ps_left; REG_OP("mulps", ps, ps_right); result[2].ps = ps;
    ps = ps_left; MEM_OP("divps", ps, ps_right); result[3].ps = ps;
    ps = ps_left; MEM_OP("sqrtps", ps, ps_left); result[4].ps = ps;
    f64x2 pd = pd_left; REG_OP("addpd", pd, pd_right); result[5].pd = pd;
    pd = pd_left; MEM_OP("subpd", pd, pd_right); result[6].pd = pd;
    pd = pd_left; REG_OP("mulpd", pd, pd_right); result[7].pd = pd;
    pd = pd_left; MEM_OP("divpd", pd, pd_right); result[8].pd = pd;
    pd = pd_left; MEM_OP("sqrtpd", pd, pd_left); result[9].pd = pd;
    f32x4 ss = ss_destination; MEM_OP("addss", ss, ss_source); result[10].ps = ss;
    ss = ss_destination; MEM_OP("subss", ss, ss_source); result[11].ps = ss;
    ss = ss_destination; REG_OP("mulss", ss, ss_source); result[12].ps = ss;
    ss = ss_destination; MEM_OP("divss", ss, ss_source); result[13].ps = ss;
    ss = ss_destination; MEM_OP("sqrtss", ss, ss_source); result[14].ps = ss;
    f64x2 sd = sd_destination; MEM_OP("addsd", sd, sd_source); result[15].pd = sd;
    sd = sd_destination; MEM_OP("subsd", sd, sd_source); result[16].pd = sd;
    sd = sd_destination; REG_OP("mulsd", sd, sd_source); result[17].pd = sd;
    sd = sd_destination; MEM_OP("divsd", sd, sd_source); result[18].pd = sd;
    sd = sd_destination; MEM_OP("sqrtsd", sd, sd_source); result[19].pd = sd;
    ps = min_ps_left; REG_OP("minps", ps, min_ps_right); result[20].ps = ps;
    ps = min_ps_left; MEM_OP("maxps", ps, min_ps_right); result[21].ps = ps;
    pd = min_pd_left; REG_OP("minpd", pd, min_pd_right); result[22].pd = pd;
    pd = min_pd_left; MEM_OP("maxpd", pd, min_pd_right); result[23].pd = pd;
    ss = min_ss_left; MEM_OP("minss", ss, min_ss_right); result[24].ps = ss;
    ss = min_ss_left; REG_OP("maxss", ss, min_ss_right); result[25].ps = ss;
    sd = min_sd_left; MEM_OP("minsd", sd, min_sd_right); result[26].pd = sd;
    sd = min_sd_left; REG_OP("maxsd", sd, min_sd_right); result[27].pd = sd;
    CMP8(f32x4, ps, "cmpps", cmp_ps_left, cmp_ps_right, 28);
    CMP8(f64x2, pd, "cmppd", cmp_pd_left, cmp_pd_right, 36);
    CMP8(f32x4, ps, "cmpss", cmp_ss_left, cmp_ss_right, 44);
    CMP8(f64x2, pd, "cmpsd", cmp_sd_left, cmp_sd_right, 52);
    FLAGS_REG("ucomiss", flags_equal_left, flags_equal_right, 0);
    FLAGS_MEM("comiss", flags_less_left, flags_less_right, 1);
    FLAGS_REG("ucomisd", flags_greater_left, flags_greater_right, 2);
    FLAGS_MEM("comisd", flags_unordered_left, flags_unordered_right, 3);
    f32x4 int_to_ss = {0.5f, 9, 8, 7};
    __asm__ volatile("cvtsi2ss %1, %0" : "+x"(int_to_ss) : "r"(cvt_i32_register)); result[60].ps = int_to_ss;
    f64x2 int_to_sd = {0.5, 99};
    __asm__ volatile("cvtsi2sd %1, %0" : "+x"(int_to_sd) : "r"(cvt_i64_register)); result[61].pd = int_to_sd;
    f32x4 move_ss_dst = {0.5f, 12, 13, 14}, move_ss_src = {2.5f, 22, 23, 24};
    __asm__ volatile("movss %1, %0" : "+x"(move_ss_dst) : "x"(move_ss_src)); result[62].ps = move_ss_dst;
    f64x2 move_sd_dst = {0.5, 99}, move_sd_src = {2.5, 88};
    __asm__ volatile("movsd %1, %0" : "+x"(move_sd_dst) : "x"(move_sd_src)); result[63].pd = move_sd_dst;
    f32x4 load_ss = {0.5f, 12, 13, 14};
    __asm__ volatile("movss %1, %0" : "+x"(load_ss) : "m"(cvt_ss_round)); result[64].ps = load_ss;
    f64x2 load_sd = {0.5, 99};
    __asm__ volatile("movsd %1, %0" : "+x"(load_sd) : "m"(cvt_sd_round)); result[65].pd = load_sd;
    int32_t cvt_ss_result; __asm__ volatile("cvtss2si %1, %0" : "=r"(cvt_ss_result) : "x"(cvt_ss_round)); conversion_results[0] = cvt_ss_result;
    int64_t cvt_sd_result; __asm__ volatile("cvtsd2si %1, %0" : "=r"(cvt_sd_result) : "x"(cvt_sd_round)); conversion_results[1] = cvt_sd_result;
    int32_t cvtt_ss_result; __asm__ volatile("cvttss2si %1, %0" : "=r"(cvtt_ss_result) : "x"(cvtt_ss_trunc)); conversion_results[2] = cvtt_ss_result;
    int64_t cvtt_sd_result; __asm__ volatile("cvttsd2si %1, %0" : "=r"(cvtt_sd_result) : "x"(cvtt_sd_trunc)); conversion_results[3] = cvtt_sd_result;
    __asm__ volatile("cvtss2si %1, %0" : "=r"(cvt_ss_result) : "x"(cvt_ss_nan)); conversion_results[4] = cvt_ss_result;
    __asm__ volatile("cvtsd2si %1, %0" : "=r"(cvt_sd_result) : "x"(cvt_sd_overflow)); conversion_results[5] = cvt_sd_result;
    __asm__ volatile("cvttss2si %1, %0" : "=r"(cvtt_ss_result) : "x"(cvtt_ss_infinity)); conversion_results[6] = cvtt_ss_result;
    __asm__ volatile("cvttsd2si %1, %0" : "=r"(cvtt_sd_result) : "x"(cvtt_sd_infinity)); conversion_results[7] = cvtt_sd_result;
    __asm__ volatile("cvtdq2ps %1, %0" : "=x"(packed_conversion[0].ps) : "m"(packed_ints));
    __asm__ volatile("cvtps2dq %1, %0" : "=x"(packed_conversion[1].ps) : "m"(packed_nearest));
    __asm__ volatile("cvttps2dq %1, %0" : "=x"(packed_conversion[2].ps) : "m"(packed_truncate));
    volatile struct { uint32_t ss; uint32_t ss_guard; uint64_t sd; uint64_t sd_guard; } scalar_stores = {0, 0xaabbccdd, 0, UINT64_C(0x1122334455667788)};
    __asm__ volatile("movss %1, %0" : "=m"(scalar_stores.ss) : "x"(move_ss_src));
    __asm__ volatile("movsd %1, %0" : "=m"(scalar_stores.sd) : "x"(move_sd_src));
    sys(NR_write, 1, (long)result, sizeof(result), 0, 0, 0);
    sys(NR_write, 1, (long)packed_conversion, sizeof(packed_conversion), 0, 0, 0);
    sys(NR_write, 1, (long)compare_flags, sizeof(compare_flags), 0, 0, 0);
    sys(NR_write, 1, (long)conversion_results, sizeof(conversion_results), 0, 0, 0);
    sys(NR_write, 1, (long)&scalar_stores, sizeof(scalar_stores), 0, 0, 0);
    const char message[] = "SSE scalar floating arithmetic, moves, comparisons and conversions: ok\n";
    text(message, sizeof(message) - 1);
    return 0;
}

#undef REG_OP
#undef MEM_OP
#undef IMM_REG
#undef IMM_MEM
#undef CMP8
#undef FLAGS_REG
#undef FLAGS_MEM
