#include "guest.h"
static long replace(long old,long target){
#ifdef NR_dup2
    return call3(NR_dup2,old,target,0);
#else
    return call3(NR_dup3,old,target,0);
#endif
}
long guest_main(long *sp){
    char **argv=(char **)(sp+1);if(sp[0]!=2)return 1;
    long fd=sys(NR_openat,-100,(long)argv[1],0x80000|0x242,0600,0,0);if(fd<0)return 2;
    if(fd!=3||call3(NR_fcntl,fd,1,0)!=1||call3(NR_write,fd,(long)"abc",3)!=3||call3(NR_lseek,fd,0,0)!=0)return 3;
    long copy=call3(NR_dup,fd,0,0);
    if(copy!=4||call3(NR_fcntl,copy,1,0)!=0||call3(NR_dup3,fd,20,0x80000)!=20||call3(NR_fcntl,20,1,0)!=1)return 4;
    char byte=0;long readers[3]={fd,copy,20};
    for(int i=0;i<3;i++)if(call3(NR_read,readers[i],(long)&byte,1)!=1||byte!='a'+i)return 5;
#ifdef NR_dup2
    if(replace(fd,fd)!=fd||call3(NR_fcntl,fd,1,0)!=1||replace(0x100000003L,0x100000004L)!=4)return 6;
#endif
    if(call3(NR_dup3,fd,fd,0)!=-22||call3(NR_dup3,64,64,0)!=-22||call3(NR_dup3,64,20,1)!=-22)return 7;
    if(call3(NR_dup,64,0,0)!=-9||replace(64,20)!=-9||replace(fd,64)!=-9||call3(NR_fcntl,20,1,0)!=1)return 8;
    if(call3(NR_dup3,0x100000003L,0x100000014L,0x100000000L)!=20||call3(NR_fcntl,20,1,0)!=0)return 9;
    long saved=call3(NR_dup,1,0,0);
    if(saved!=5||replace(fd,1)!=1||text("redirected\n",11)!=11||replace(saved,1)!=1||call3(NR_close,saved,0,0)!=0)return 10;
    for(int i=0;i<2;i++){
        long setter=i?NR_setgid:NR_setuid;
        if(call3(setter,1000,0,0)!=0||call3(setter,0x1000003e8L,0,0)!=0||call3(setter,0,0,0)!=-1||call3(setter,1001,0,0)!=-1||call3(setter,-1,0,0)!=-22)return 11;
    }
    if(call3(NR_getpid,0,0,0)!=1||call3(NR_getppid,0,0,0)!=0||call3(NR_gettid,0,0,0)!=1)return 17;
    long groups[2]={123,456};
    if(call3(NR_getgroups,0,0,0)!=0||call3(NR_getgroups,2,(long)groups,0)!=0||groups[0]!=123||groups[1]!=456||call3(NR_getgroups,1,1,0)!=0||call3(NR_getgroups,-1,(long)groups,0)!=-22)return 16;
    long getters[4]={NR_getuid,NR_getgid,NR_geteuid,NR_getegid};
    for(int i=0;i<4;i++)if(call3(getters[i],0,0,0)!=1000)return 12;
    long last=0;int count=0;
    while((last=call3(NR_dup,fd,0,0))>=0){if(last<5||last>=64||count++>=59)return 13;}
    if(last!=-24||count!=58||replace(fd,63)!=63||call3(NR_dup3,fd,62,0x80000)!=62||call3(NR_fcntl,62,1,0)!=1)return 14;
    if(call3(NR_close,4,0,0)!=0||call3(NR_dup,fd,0,0)!=4)return 15;
    text("file duplicate + guest identity: ok\n",36);return 0;
}
