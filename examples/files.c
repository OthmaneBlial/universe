#include "guest.h"
long guest_main(long *sp){if(sp[0]!=2&&sp[0]!=3)return 1;char **argv=(char **)(sp+1);
    if(sp[0]==3){
        if(sys(NR_openat,-1,(long)argv[1],O_NOFOLLOW|O_LARGEFILE,0,0,0)!=-40)return 10;
        if(sys(NR_openat,-1,(long)argv[1],O_DIRECTORY,0,0,0)!=-20)return 11;
        long fd=sys(NR_openat,-1,(long)argv[1],O_LARGEFILE|2048,0,0,0);if(fd<0)return 12;
        if((call3(NR_fcntl,fd,3,0)&(O_LARGEFILE|2048))!=(O_LARGEFILE|2048))return 13;
        if(call3(NR_close,fd,0,0)!=0)return 14;
        text("open flags: ok\n",15);return 0;
    }
    if(call3(NR_close,0,0,0)!=0)return 9;
    long fd=sys(NR_openat,-100,(long)argv[1],64|2|512,0600,0,0);if(fd!=0)return 2;
    if(call3(NR_fcntl,fd,1,0)!=0||call3(NR_fcntl,fd,2,1)!=0||call3(NR_fcntl,fd,1,0)!=1)return 8;
    if(call3(NR_write,fd,(long)"guest file\n",11)!=11)return 3;
    long stat[18];if(call3(NR_fstat,fd,(long)stat,0)!=0||stat[6]!=11)return 4;
    if(call3(NR_lseek,fd,0,0)!=0)return 5;char buf[11];if(call3(NR_read,fd,(long)buf,11)!=11)return 6;
    if(call3(NR_close,fd,0,0)!=0)return 7;text(buf,11);return 0;
}
