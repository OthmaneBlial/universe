/* Raw Linux syscalls; libc declarations check the stat/iovec ABI independently. */
#include "guest.h"
#include <sys/stat.h>
#include <sys/uio.h>
static unsigned char bytes[32];
static int zeros(unsigned start,unsigned end){for(unsigned i=start;i<end;i++)if(bytes[i])return 0;return 1;}
long guest_main(long *sp){
    (void)sp;
    long n=sys(NR_openat,99,(long)"/dev/null",2|0x80000,0,0,0);
    long z=sys(NR_openat,99,(long)"/dev/./zero",2,0,0,0);
    long ro=sys(NR_openat,99,(long)"/dev/zero",0,0,0,0);
    long wo=sys(NR_openat,99,(long)"/dev/null",1,0,0,0);
    if(n!=3||z!=4||ro!=5||wo!=6)return 1;
    for(unsigned i=0;i<sizeof bytes;i++)bytes[i]=0xa5;
    if(call3(NR_read,n,1,16)||call3(NR_write,n,1,16)!=16||sys(NR_pwrite,z,1,16,123,0,0)!=16)return 2;
    if(call3(NR_read,wo,(long)bytes,1)!=-9||call3(NR_write,ro,(long)bytes,1)!=-9)return 3;
    if(sys(NR_pread,z,(long)(bytes+3),17,123,0,0)!=17||!zeros(3,20)||bytes[2]!=0xa5||bytes[20]!=0xa5)return 4;
    if(call3(NR_read,z,1,1)!=-14||call3(NR_write,n,-1,1)!=-14||sys(NR_pread,z,(long)bytes,1,-1,0,0)!=-22)return 5;
    struct iovec no_copy[2]={{(void *)1,7},{(void *)2,11}};
    if(call3(NR_readv,n,(long)no_copy,2)||call3(NR_writev,z,(long)no_copy,2)!=18)return 6;
    struct iovec data[2]={{bytes+21,3},{bytes+27,4}};
    if(call3(NR_readv,z,(long)data,2)!=7||!zeros(21,24)||!zeros(27,31)||bytes[24]!=0xa5||bytes[31]!=0xa5)return 7;
    if(call3(NR_writev,z,1,2)!=-14||call3(NR_readv,z,(long)no_copy,2)!=-14)return 8;
    struct stat info;
    if(call3(NR_fstat,n,(long)&info,0)||!S_ISCHR(info.st_mode)||(info.st_mode&0777)!=0666||info.st_rdev!=0x103||info.st_size||info.st_uid||info.st_gid)return 9;
    if(sys(NR_newfstatat,99,(long)"/dev/zero",(long)&info,0x100,0,0)||!S_ISCHR(info.st_mode)||info.st_rdev!=0x105)return 10;
    if(call3(NR_faccessat,99,(long)"/dev/null",6)||call3(NR_faccessat,99,(long)"/dev/zero",1)!=-13)return 11;
    if(sys(NR_openat,99,(long)"/dev/zero/",0,0,0,0)!=-20||sys(NR_openat,99,(long)"/dev/null",O_DIRECTORY,0,0,0)!=-20||sys(NR_openat,99,(long)"/dev/zero",64|128,0600,0,0)!=-17)return 12;
    if(call3(NR_lseek,z,-1,2)||call3(NR_lseek,n,12,4)||call3(NR_lseek,n,0,5)!=-22)return 13;
    if(call3(NR_fsync,z,0,0)!=-22||call3(NR_ftruncate,n,0,0)!=-22||call3(NR_ioctl,n,0x541b,(long)bytes)!=-25||call3(NR_getdents,z,(long)bytes,sizeof bytes)!=-20)return 14;
    long a=sys(NR_mmap,0,4096,3,2,z,4096);
    long b=sys(NR_mmap,0,4096,3,2,z,0);
    if(a<0||b<0||a==b)return 15;
    unsigned char *first=(void *)a,*second=(void *)b;
    for(unsigned i=0;i<4096;i++)if(first[i]||second[i])return 16;
    first[0]=42;if(second[0])return 17;
    long pid=guest_fork();if(pid<0)return 18;
    if(!pid){
        first[0]=99;
        if(call3(NR_fcntl,z,4,0x802)||call3(NR_read,n,1,16)||call3(NR_fcntl,n,1,0)!=1)return 19;
        return 37;
    }
    int status=0;
    if(sys(NR_wait4,pid,(long)&status,0,0,0,0)!=pid||status!=(37<<8)||first[0]!=42||call3(NR_fcntl,z,3,0)!=0x802)return 20;
    if(sys(NR_mmap,0,4096,3,2,n,0)!=-19||sys(NR_mmap,0,4096,3,2,wo,0)!=-13||sys(NR_mmap,0,4096,3,1,z,0)!=-22)return 21;
    if(call3(NR_munmap,a,4096,0)||call3(NR_munmap,b,4096,0))return 22;
    long copy=call3(NR_dup,z,0,0);if(copy!=7)return 23;
    if(call3(NR_fcntl,copy,4,0x402)||call3(NR_fcntl,z,3,0)!=0x402||call3(NR_fcntl,copy,1,0))return 24;
    if(call3(NR_close,z,0,0)||call3(NR_read,copy,(long)bytes,sizeof bytes)!=sizeof bytes||!zeros(0,sizeof bytes))return 25;
#ifdef NR_poll
    struct {int fd;short events,revents;} pollfd[2]={{(int)n,0x145,0},{(int)copy,0x145,0}};
    if(call3(NR_poll,(long)pollfd,2,0)!=2||pollfd[0].revents!=0x145||pollfd[1].revents!=0x145)return 26;
#endif
    if(call3(NR_close,n,0,0)||call3(NR_close,ro,0,0)||call3(NR_close,wo,0,0)||call3(NR_close,copy,0,0))return 27;
    text("devices: null, zero, stat, vectors, flags, private maps and fork ok\n",sizeof("devices: null, zero, stat, vectors, flags, private maps and fork ok\n")-1);
    return 0;
}
