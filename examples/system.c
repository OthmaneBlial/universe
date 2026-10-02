#include "guest.h"
static char bss[128];
static volatile long fork_value=7;
static char exec_long[128*1024+1];
static int same(const char *a,const char *b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
static const char exec_output[]="exec: identity, argv, environment, auxiliary filename and descriptor state ok\n";
static long images(long *sp){
    char **argv=(char **)(sp+1);
    if(same(argv[1],"replaced")){
        char **env=argv+sp[0]+1;
        if(sp[0]!=3||!same(argv[0],"renamed")||!same(env[0],"KEY=é🚀")||env[1]||fork_value!=7)return 60;
        if(call3(NR_getpid,0,0,0)!=2||call3(NR_gettid,0,0,0)!=2||call3(NR_getppid,0,0,0)!=1||call3(NR_umask,0077,0,0)!=0077)return 61;
        if(call3(NR_fcntl,3,1,0)!=-9||call3(NR_fcntl,4,1,0)!=-9||call3(NR_fcntl,1,1,0)!=0)return 62;
        unsigned long action[4]={0},mask=0,alt[3]={0};
        if(sys(NR_sigaction,10,0,(long)action,8,0,0)||action[0]||sys(NR_sigaction,12,0,(long)action,8,0,0)||action[0]!=1)return 63;
        if(sys(NR_sigprocmask,2,0,(long)&mask,8,0,0)||mask!=(1UL<<9)||call3(NR_sigaltstack,0,(long)alt,0)||alt[0]||alt[1]!=2||alt[2])return 64;
        unsigned long *aux=(unsigned long *)(env+2);char *execfn=0;
        while(aux[0]){if(aux[0]==31)execfn=(char *)aux[1];aux+=2;}
        if(!execfn||!same(execfn,argv[2]))return 65;
        text(exec_output,sizeof exec_output-1);return 37;
    }
    if(sp[0]<3)return 66;
    char *args[5]={"renamed","replaced",argv[2],0,0};char *env[]={"KEY=é🚀",0};
    if(same(argv[1],"exec-direct"))return call3(NR_execve,(long)argv[2],(long)(argv+2),(long)(argv+sp[0]+1));
    if(same(argv[1],"exec-null"))return call3(NR_execve,(long)argv[2],0,0);
    if(same(argv[1],"exec-loop")){
        char *loop[]={argv[2],"exec-loop",argv[2],0};
        call3(NR_execve,(long)argv[2],(long)loop,(long)env);return 83;
    }
    if(same(argv[1],"exec-denied")){
        if(call3(NR_execve,(long)argv[2],(long)args,(long)env)!=-13)return 67;
        text("exec denied: ok\n",16);return 0;
    }
    if(same(argv[1],"exec-error")){
        if(sp[0]<4)return 68;
        long expected=0;for(char *p=argv[3];*p;p++)expected=expected*10+*p-'0';
        int ends[2];if(call3(NR_pipe2,(long)ends,0x80000,0))return 69;
        fork_value=99;long path=(long)argv[2],arguments=(long)args,environment=(long)env;
        if(sp[0]>4){
            if(same(argv[4],"argv-fault"))arguments=1;
            if(same(argv[4],"env-fault"))environment=1;
            if(same(argv[4],"path-fault"))path=1;
            if(same(argv[4],"long-arg")||same(argv[4],"many-args")){
                long n=same(argv[4],"long-arg")?128*1024:100*1024;
                for(long i=0;i<n;i++)exec_long[i]='x';
                args[1]=exec_long;args[2]=exec_long;args[3]=exec_long;
            }
        }
        if(call3(NR_execve,path,arguments,environment)!=-expected||fork_value!=99||call3(NR_getpid,0,0,0)!=1||call3(NR_gettid,0,0,0)!=1)return 70;
        if(call3(NR_fcntl,ends[0],1,0)!=1||call3(NR_fcntl,ends[1],1,0)!=1)return 71;
        text("exec failure: rollback ok\n",26);return 0;
    }
    int ends[2];if(call3(NR_pipe2,(long)ends,0x80000,0))return 72;
    fork_value=99;call3(NR_umask,0022,0,0);long pid=guest_fork();if(pid<0)return 73;
    if(!pid){
        unsigned long action[4]={0x1234,0,0,0},mask=1UL<<9;char stack[8192];unsigned long alt[3]={(unsigned long)stack,0,sizeof stack};
        if(sys(NR_sigaction,10,(long)action,0,8,0,0))return 74;action[0]=1;
        if(sys(NR_sigaction,12,(long)action,0,8,0,0)||sys(NR_sigprocmask,2,(long)&mask,0,8,0,0)||call3(NR_sigaltstack,(long)alt,0,0))return 75;
        if(call3(NR_set_tid_address,(long)&fork_value,0,0)!=2||call3(NR_umask,0077,0,0)!=0022)return 76;
#ifdef NR_dup2
        if(call3(NR_dup2,ends[1],1,0)!=1)return 77;
#else
        if(call3(NR_dup3,ends[1],1,0)!=1)return 77;
#endif
        call3(NR_execve,(long)argv[2],(long)args,(long)env);return 78;
    }
    if(call3(NR_close,ends[1],0,0))return 79;
    char bytes[sizeof exec_output];long received=0;
    for(;;){char part[17];long n=call3(NR_read,ends[0],(long)part,sizeof part);if(n<0)return 80;if(!n)break;
        for(long i=0;i<n;i++){if(received>=sizeof exec_output-1||part[i]!=exec_output[received])return 81;bytes[received++]=part[i];}}
    int status=0;
    if(received!=sizeof exec_output-1||sys(NR_wait4,pid,(long)&status,0,0,0,0)!=pid||status!=(37<<8)||fork_value!=99||call3(NR_umask,0022,0,0)!=0022)return 82;
    text(bytes,received);text("exec parent: reaped child and preserved private state ok\n",sizeof("exec parent: reaped child and preserved private state ok\n")-1);return 0;
}
static long processes(int blocked){
    int ends[2];
    if(call3(NR_pipe2,(long)ends,0,0))return 30;
    call3(NR_umask,0022,0,0);
    long pid=guest_fork();
    if(pid<0)return 31;
    if(!pid){
        if(blocked)for(volatile unsigned spin=0;;++spin){}
        if(call3(NR_getpid,0,0,0)<=1||call3(NR_getpid,0,0,0)!=call3(NR_gettid,0,0,0)||call3(NR_getppid,0,0,0)!=1||fork_value!=7)return 32;
        fork_value=99;
        if(call3(NR_umask,0077,0,0)!=0022||call3(NR_close,ends[0],0,0))return 33;
        unsigned char bytes[4097];for(unsigned i=0;i<sizeof bytes;i++)bytes[i]=(unsigned char)(i*29+7);
        unsigned sent=0;while(sent<sizeof bytes){long n=call3(NR_write,ends[1],(long)(bytes+sent),sizeof bytes-sent);if(n<=0)return 34;sent+=(unsigned)n;}
        call3(NR_exit,37,0,0);return 35;
    }
    int status=-1;
    if(blocked)return sys(NR_wait4,pid,(long)&status,0,0,0,0)!=pid;
    if(call3(NR_getpid,0,0,0)!=1||call3(NR_getppid,0,0,0)!=0||fork_value!=7||call3(NR_umask,0022,0,0)!=0022)return 36;
    if(sys(NR_wait4,pid,(long)&status,1,0,0,0)!=0||status!=-1||call3(NR_close,ends[1],0,0))return 37;
    unsigned received=0;unsigned char bytes[513];
    for(;;){long n=call3(NR_read,ends[0],(long)bytes,sizeof bytes);if(n<0)return 38;if(!n)break;
        for(long i=0;i<n;i++)if(bytes[i]!=(unsigned char)((received+(unsigned)i)*29+7))return 39;received+=(unsigned)n;}
    if(received!=4097||fork_value!=7||sys(NR_wait4,pid,(long)&status,0,0,0,0)!=pid||status!=(37<<8)||sys(NR_wait4,pid,(long)&status,0,0,0,0)!=-10||call3(NR_close,ends[0],0,0))return 40;
    pid=guest_fork();if(pid<0)return 41;if(!pid){call3(NR_exit,7,0,0);return 42;}
    if(sys(NR_wait4,pid,1,0,0,0,0)!=-14||sys(NR_wait4,pid,(long)&status,0,0,0,0)!=-10)return 43;
    text("process: private memory, identity, masks, pipe bytes, EOF and wait status ok\n",77);return 0;
}
long guest_main(long *sp){for(long i=0;i<128;i++)if(bss[i])return 1;
    int ends[2]={-1,-1};
    if(sp[0]>1){
        char **argv=(char **)(sp+1);
        if(argv[1][0]=='e'||argv[1][0]=='r')return images(sp);
        if(argv[1][0]=='f')return processes(argv[1][4]=='-'&&argv[1][5]=='b');
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
    unsigned long ignored_pipe[4]={1,0,0,0};
    if(sys(NR_sigaction,13,(long)ignored_pipe,0,8,0,0)||call3(NR_pipe2,(long)ends,0,0)||call3(NR_close,ends[0],0,0)||call3(NR_write,ends[1],(long)"x",1)!=-32||call3(NR_close,ends[1],0,0))return 22;
    text("system: ok\n",11);return 0;
}
