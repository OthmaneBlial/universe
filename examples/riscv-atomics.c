#include "guest.h"
static int word;
static long wide;
long guest_main(long *stack) {
    if (stack[0]>1) {
        long old;
        __asm__ volatile("amoadd.d %0,zero,(%1)":"=r"(old):"r"((char *)&wide+1):"memory");
        return 10; /* The runtime must stop on the misaligned atomic address. */
    }
    __atomic_store_n(&word,5,__ATOMIC_SEQ_CST);
    if (__atomic_fetch_add(&word,3,__ATOMIC_SEQ_CST)!=5) return 1;
    if (__atomic_fetch_xor(&word,10,__ATOMIC_SEQ_CST)!=8) return 2;
    if (__atomic_fetch_and(&word,3,__ATOMIC_SEQ_CST)!=2) return 3;
    if (__atomic_fetch_or(&word,8,__ATOMIC_SEQ_CST)!=2) return 4;
    if (__atomic_exchange_n(&word,-1,__ATOMIC_SEQ_CST)!=10) return 5;
    int expected=-1;
    if (!__atomic_compare_exchange_n(&word,&expected,0x80000000,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST)) return 6;
    expected=0;
    if (__atomic_compare_exchange_n(&word,&expected,7,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST) || expected!=(int)0x80000000) return 7;
    if (__atomic_fetch_add(&word,1,__ATOMIC_SEQ_CST)!=(int)0x80000000 || word!=(int)0x80000001) return 8;
    __atomic_store_n(&wide,-1,__ATOMIC_SEQ_CST);
    long expected_wide=-1;
    if (!__atomic_compare_exchange_n(&wide,&expected_wide,37,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST)) return 9;
    if (__atomic_fetch_add(&wide,5,__ATOMIC_SEQ_CST)!=37 || wide!=42) return 11;
    long old,status;
    __asm__ volatile("lr.d %0,(%2)\nsd %0,0(%2)\nsc.d %1,%3,(%2)":"=&r"(old),"=&r"(status):"r"(&wide),"r"(99L):"memory");
    if (old!=42 || status!=1 || wide!=42) return 12;
    const char message[]="riscv atomics: ok\n";
    return text(message,sizeof(message)-1)==sizeof(message)-1 ? 0 : 13;
}
