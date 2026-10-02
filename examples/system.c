#include "guest.h"
static char bss[128];
long guest_main(long *sp){for(long i=0;i<128;i++)if(bss[i])return 1;
    int ends[2]={-1,-1};
    if(sp[0]>1){
        char **argv=(char **)(sp+1);
        if(call3(NR_pipe2,(long)ends,0,0))return 20;
#ifdef NR_poll
        if(argv[1][0]=='p'){struct{int fd;short events,revents;} row={ends[0],1,0};return call3(NR_poll,(long)&row,1,-1)!=0;}
#endif
        char byte;return call3(NR_read,ends[0],(long)&byte,1)!=0;
    }
    long base=call3(NR_brk,0,0,0);if(call3(NR_brk,base+4096,0,0)!=base+4096)return 2;*(volatile long *)base=123;
    long p=sys(NR_mmap,0,8192,3,0x22,-1,0);if(p<0)return 3;volatile long *m=(long *)p;for(long i=0;i<1024;i++)m[i]=i;
    if(call3(NR_mprotect,p+4096,4096,1)!=0||m[1000]!=1000)return 4;if(call3(NR_munmap,p,8192,0)!=0)return 5;
    long ts[2];if(call3(NR_clock,1,(long)ts,0)!=0||ts[0]<0||ts[1]<0||ts[1]>=1000000000)return 6;
    long tv[2],tz=-1;if(call3(NR_gettimeofday,(long)tv,(long)&tz,0)!=0||tv[0]<=0||tv[1]<0||tv[1]>=1000000||tz!=0)return 10;
    if(call3(NR_gettimeofday,0,0,0)!=0)return 11;
#if defined(__x86_64__)
    long seconds;long returned=call3(NR_time,(long)&seconds,0,0);if(returned!=seconds||seconds<tv[0]||call3(NR_time,0,0,0)<seconds)return 13;
#endif
    long info[14];if(call3(NR_sysinfo,(long)info,0,0)!=0||info[0]<0||info[4]!=256*1024*1024||info[5]<=0||info[5]>=info[4]||info[10]!=1||info[13]!=1)return 12;
    char random[32];if(call3(NR_random,(long)random,32,0)!=32)return 7;
    char name[390];if(call3(NR_uname,(long)name,0,0)!=0||name[0]!='L')return 8;
    if(call3(NR_write,1,0,4)!=-14)return 9;
    if(call3(NR_pipe2,(long)ends,0x80800,0)||ends[0]!=3||ends[1]!=4)return 14;
    if(call3(NR_fcntl,ends[0],1,0)!=1||call3(NR_fcntl,ends[1],3,0)!=0x801)return 15;
    char output[6]={0};long vectors[2][2]={{(long)"abc",3},{(long)"def",3}};
    if(call3(NR_read,ends[0],(long)output,6)!=-11||call3(NR_writev,ends[1],(long)vectors,2)!=6)return 16;
    int available=-1;if(call3(NR_ioctl,ends[0],0x541b,(long)&available)||available!=6)return 17;
    vectors[0][0]=(long)output;vectors[1][0]=(long)(output+3);
    if(call3(NR_readv,ends[0],(long)vectors,2)!=6)return 18;
    for(int i=0;i<6;i++)if(output[i]!='a'+i)return 19;
    long copy=call3(NR_dup,ends[1],0,0);
    if(copy!=5||call3(NR_close,ends[1],0,0)||call3(NR_read,ends[0],(long)output,1)!=-11||call3(NR_close,copy,0,0)||call3(NR_read,ends[0],(long)output,1)||call3(NR_close,ends[0],0,0))return 21;
    if(call3(NR_pipe2,(long)ends,0,0)||call3(NR_close,ends[0],0,0)||call3(NR_write,ends[1],(long)"x",1)!=-32||call3(NR_close,ends[1],0,0))return 22;
    text("system: ok\n",11);return 0;
}
