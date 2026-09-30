#include "macos-guest.h"
static volatile unsigned long zeroes[128];
static volatile unsigned long value=21;
static volatile unsigned long *volatile pointer=&value;
long guest_main(unsigned long *stack) {
    for (long i=0;i<128;i++) if (zeroes[i]) return 1;
    *pointer+=3;
    if (value!=24 || call3(20,0,0,0)<=0) return 2;
    long code_page=(long)guest_main & -PAGE_SIZE;
    if (call3(74,code_page,PAGE_SIZE,3)!=-13) return 10;
    if (call3(6,-1,0,0)!=-9 || call3(4,1,0,1)!=-14) return 3;
    long address=sys(197,0,1,3,0x1002,-1,0);
    if (address<0 || address%PAGE_SIZE) return 4;
    volatile unsigned char *memory=(void *)address;
    if (memory[PAGE_SIZE-1]) return 5;
    memory[0]=42;
    if (call3(74,address,1,1) || memory[0]!=42) return 6;
    if (stack[0]>1) memory[0]=1; /* Reproducible protection fault. */
    if (call3(73,address,1,0)) return 7;
    if (sys(197,0,0,3,0x1002,-1,0)!=0 || sys(197,0,0,3,0x41002,-1,0)!=-22) return 8;
    if (call3(74,code_page,0,1)!=0 || call3(73,code_page,0,0)!=-22) return 11;
    return text("macOS system: ok\n",17)==17 ? 0 : 9;
}
