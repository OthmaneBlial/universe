#include "guest.h"
long guest_main(long *sp){if(sp[0]!=2)return 1;char **argv=(char **)(sp+1);long fd=sys(NR_openat,-100,(long)argv[1],65536,0,0,0);if(fd<0)return 2;
    char b[32];long total=0;for(;;){long n=call3(NR_getdents,fd,(long)b,sizeof(b));if(n<0)return 3;if(n==0)break;for(long off=0;off<n;){unsigned long len=(unsigned char)b[off+16]|((unsigned long)(unsigned char)b[off+17]<<8);if(len<24||len>n-off||len%8)return 4;char *name=b+off+19;text(name,length(name));text("\n",1);total++;off+=len;}}
    if(call3(NR_lseek,fd,0,0)!=0)return 5;long n=call3(NR_getdents,fd,(long)b,sizeof(b));if(n<24)return 6;call3(NR_close,fd,0,0);return total>=4?0:7;
}
