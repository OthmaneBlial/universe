#include <stdint.h>
#include "guest.h"

typedef float f32x4 __attribute__((vector_size(16)));
typedef double f64x2 __attribute__((vector_size(16)));
typedef union { f32x4 ps; f64x2 pd; } v128;

#define REG_OP(OP, DST, SRC) __asm__ volatile(OP " %1, %0" : "+x"(DST) : "x"(SRC))
#define MEM_OP(OP, DST, SRC) __asm__ volatile(OP " %1, %0" : "+x"(DST) : "m"(SRC))

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
    volatile v128 result[20];
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
    sys(NR_write, 1, (long)result, sizeof(result), 0, 0, 0);
    const char message[] = "SSE scalar and packed floating arithmetic: ok\n";
    text(message, sizeof(message) - 1);
    return 0;
}

#undef REG_OP
#undef MEM_OP
