#include "guest.h"
static char bss[128];
long guest_main(long *sp){(void)sp;for(long i=0;i<128;i++)if(bss[i])return 1;
    long base=call3(NR_brk,0,0,0);if(call3(NR_brk,base+4096,0,0)!=base+4096)return 2;*(volatile long *)base=123;
    long p=sys(NR_mmap,0,8192,3,0x22,-1,0);if(p<0)return 3;volatile long *m=(long *)p;for(long i=0;i<1024;i++)m[i]=i;
    if(call3(NR_mprotect,p+4096,4096,1)!=0||m[1000]!=1000)return 4;if(call3(NR_munmap,p,8192,0)!=0)return 5;
    long ts[2];if(call3(NR_clock,1,(long)ts,0)!=0||ts[0]<0||ts[1]<0||ts[1]>=1000000000)return 6;
    char random[32];if(call3(NR_random,(long)random,32,0)!=32)return 7;
    char name[390];if(call3(NR_uname,(long)name,0,0)!=0||name[0]!='L')return 8;
    if(call3(NR_write,1,0,4)!=-14)return 9;
    text("system: ok\n",11);return 0;
}
