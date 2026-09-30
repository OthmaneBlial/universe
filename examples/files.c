#include "guest.h"
long guest_main(long *sp){if(sp[0]!=2)return 1;char **argv=(char **)(sp+1);
    long fd=sys(NR_openat,-100,(long)argv[1],64|2|512,0600,0,0);if(fd<0)return 2;
    if(call3(NR_write,fd,(long)"guest file\n",11)!=11)return 3;
    long stat[18];if(call3(NR_fstat,fd,(long)stat,0)!=0||stat[6]!=11)return 4;
    if(call3(NR_lseek,fd,0,0)!=0)return 5;char buf[11];if(call3(NR_read,fd,(long)buf,11)!=11)return 6;
    if(call3(NR_close,fd,0,0)!=0)return 7;text(buf,11);return 0;
}
