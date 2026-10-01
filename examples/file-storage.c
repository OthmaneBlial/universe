#include "guest.h"
struct guest_lock {short type,whence;int padding;long start,len;int pid,unused;};
_Static_assert(sizeof(struct guest_lock)==32,"64-bit Linux flock layout");
long guest_main(long *sp){
    char **argv=(char **)(sp+1);if(sp[0]!=3)return 1;
    long fd=sys(NR_openat,-100,(long)argv[1],2,0,0,0);if(fd<0)return 2;
    char cwd[512];long n=call3(NR_getcwd,(long)cwd,sizeof(cwd),0);
    if(n<2||cwd[0]!='/'||n!=length(cwd)+1||call3(NR_getcwd,(long)cwd,1,0)!=-34||call3(NR_getcwd,0,512,0)!=-14)return 19;
    struct guest_lock lock={1,0,0,0,4,0,0};
    if(argv[2][0]=='l'){
        if(call3(NR_fcntl,fd,5,(long)&lock)!=0||lock.type!=1||lock.start!=0||lock.len!=4||lock.pid<=0)return 20;
        long result=call3(NR_fcntl,fd,6,(long)&lock);if(result!=-11&&result!=-13)return 21;
        text("lock conflict: ok\n",18);return 0;
    }
    char scattered[10]={'?','?','?','?','?','?','?','?','?','?'};
    long vectors[4]={(long)scattered,3,0,1};
    if(call3(NR_readv,fd,(long)vectors,2)!=-14||call3(NR_lseek,fd,0,1)!=0)return 22;
    vectors[2]=(long)(scattered+4);vectors[3]=6;
    if(call3(NR_readv,fd,(long)vectors,2)!=8||scattered[0]!='a'||scattered[2]!='c'||scattered[3]!='?'||scattered[4]!='d'||scattered[8]!='h'||scattered[9]!='?')return 23;
    if(call3(NR_lseek,fd,1,0)!=1)return 3;
    if(sys(NR_pwrite,fd,(long)"XYZ",3,2,0,0)!=3||call3(NR_lseek,fd,0,1)!=1)return 4;
    char data[8]={0};if(sys(NR_pread,fd,(long)data,8,0,0,0)!=8||call3(NR_lseek,fd,0,1)!=1)return 5;
    if(data[0]!='a'||data[1]!='b'||data[2]!='X'||data[3]!='Y'||data[4]!='Z'||data[7]!='h')return 6;
    if(sys(NR_pread,fd,(long)data,8,7,0,0)!=1||data[0]!='h'||sys(NR_pread,fd,(long)data,8,8,0,0)!=0)return 7;
    if(sys(NR_pwrite,fd,0,1,0,0,0)!=-14||sys(NR_pread,fd,(long)data,1,-1,0,0)!=-22)return 8;
    if(call3(NR_fcntl,fd,6,0)!=-14||call3(NR_fcntl,fd,6,(long)&lock)!=0)return 9;
    if(call3(NR_fcntl,fd,5,(long)&lock)!=0||lock.type!=2||lock.start!=0||lock.len!=4)return 10;
    lock.type=0;if(call3(NR_fcntl,fd,6,(long)&lock)!=0)return 11;
    lock.type=2;if(call3(NR_fcntl,fd,6,(long)&lock)!=0)return 12;
    if(call3(NR_ftruncate,fd,-1,0)!=-22||call3(NR_ftruncate,fd,5,0)!=0)return 13;
    if(call3(NR_fsync,fd,0,0)!=0||call3(NR_fdatasync,fd,0,0)!=0)return 14;
    long stat[18];if(sys(NR_newfstatat,-100,(long)argv[1],(long)stat,0,0,0)!=0||stat[6]!=5)return 15;
    char link[4]={'?','?','?','?'};
    if(sys(NR_readlinkat,-100,(long)argv[2],(long)link,3,0,0)!=3||link[0]!='s'||link[1]!='t'||link[2]!='o'||link[3]!='?')return 16;
    if(sys(NR_readlinkat,-100,(long)argv[2],0,1,0,0)!=-14||sys(NR_readlinkat,-100,(long)argv[2],(long)link,0,0,0)!=-22)return 17;
    if(call3(NR_close,fd,0,0)!=0)return 18;
    text("file storage: ok\n",17);return 0;
}
