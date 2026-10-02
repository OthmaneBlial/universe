#define _GNU_SOURCE
#include <signal.h>
#include <ucontext.h>
#include "guest.h"
extern void guest_restorer(void);
#if defined(__x86_64__)
__asm__(".global guest_restorer\nguest_restorer:\nmov $15,%eax\nsyscall\n");
#elif defined(__aarch64__)
__asm__(".global guest_restorer\nguest_restorer:\nmov x8,#139\nsvc #0\n");
#else
__asm__(".global guest_restorer\nguest_restorer:\nli a7,139\necall\n");
#endif
static volatile long seen,failed,edit_result,last_pid,last_status,last_code,expect_alt,expect_mask;
static char alternate[8192] __attribute__((aligned(16)));
static void handler(int sig,siginfo_t *info,void *context){
    ucontext_t *uc=context;char local;
    unsigned long mask=0;
    if(sys(NR_sigprocmask,2,0,(long)&mask,8,0,0)||!(mask&(1UL<<(sig-1))))failed=1;
    if(info->si_signo!=sig||info->si_uid!=1000)failed=2;
    if(sig==SIGUSR1&&info->si_pid!=1)failed=3;
    if(expect_alt&&((unsigned long)&local<(unsigned long)alternate||(unsigned long)&local>=(unsigned long)alternate+sizeof alternate))failed=4;
    if(expect_mask&&(*(unsigned long *)&uc->uc_sigmask)!=(1UL<<9))failed=5;
    if(expect_mask)*(unsigned long *)&uc->uc_sigmask=1UL<<11;
    if(edit_result){
#if defined(__x86_64__)
        uc->uc_mcontext.gregs[REG_RAX]=55;
#elif defined(__aarch64__)
        uc->uc_mcontext.regs[0]=55;
#else
        uc->uc_mcontext.__gregs[REG_A0]=55;
#endif
    }
    last_pid=info->si_pid;last_status=info->si_status;last_code=info->si_code;seen++;
}
static long action(int sig,unsigned long target,unsigned long flags,unsigned long mask){
    unsigned long words[4]={target,flags|0x4000000,(unsigned long)guest_restorer,mask};
#if defined(__riscv)
    words[1]=flags;words[2]=mask;
#endif
    return sys(NR_sigaction,sig,(long)words,0,8,0,0);
}
static void delay(void){for(volatile long n=0;n<20000;n++);}
long guest_main(long *sp){
    char **argv=(char **)(sp+1);char mode=sp[0]>1?argv[1][0]:'s';unsigned long mask=0,pending=0;
    if(call3(NR_kill,1,65,0)!=-22||call3(NR_kill,9999,0,0)!=-3||call3(NR_kill,1,0,0)||call3(NR_kill,1,32,0)!=-38)return 1;
    if(sys(NR_sigpending,(long)&pending,16,0,0,0,0)!=-22||sys(NR_sigsuspend,(long)&mask,16,0,0,0,0)!=-22)return 2;
    if(mode=='b'){call3(NR_sigsuspend,(long)&mask,8,0);return 99;}
    if(mode=='s'){
        unsigned long stack[3]={(unsigned long)alternate,0,sizeof alternate};
        if(call3(NR_sigaltstack,(long)stack,0,0)||action(SIGUSR1,(unsigned long)handler,4|0x8000000,0))return 3;
        mask=1UL<<9;if(sys(NR_sigprocmask,0,(long)&mask,0,8,0,0))return 4;
        if(call3(NR_kill,1,SIGUSR1,0)||call3(NR_kill,1,SIGUSR1,0)||seen)return 5;
        if(call3(NR_sigpending,(long)&pending,8,0)||pending!=mask)return 6;
        expect_alt=expect_mask=1;mask=0;
        if(call3(NR_sigsuspend,(long)&mask,8,0)!=-4||seen!=1||failed)return 7;
        if(sys(NR_sigprocmask,2,0,(long)&mask,8,0,0)||mask!=(1UL<<11))return 8;
        expect_mask=0;edit_result=1;
        if(call3(NR_kill,1,SIGUSR1,0)!=55||seen!=2||failed)return 9;
        text("signals: mask, coalescing, siginfo, alternate stack and edited ucontext ok\n",sizeof("signals: mask, coalescing, siginfo, alternate stack and edited ucontext ok\n")-1);return 0;
    }
    if(mode=='i'||mode=='a'){
        if(action(SIGCHLD,mode=='i'?1:(unsigned long)handler,mode=='i'?0:6,0))return 10;
        long pid=guest_fork();if(pid<0)return 11;if(!pid)return 37;
        int status=0;long waited;do{waited=sys(NR_wait4,pid,(long)&status,0,0,0,0);}while(waited==-4);
        if(waited!=-10||mode=='a'&&(!seen||last_code!=CLD_EXITED||last_pid!=pid||last_status!=37||failed))return 12;
        text("signals: automatic child reaping ok\n",sizeof("signals: automatic child reaping ok\n")-1);return 0;
    }
    if(action(SIGCHLD,(unsigned long)handler,4|((mode=='r'||mode=='n'||mode=='f')?0x10000000:0),0))return 13;
    mask=1UL<<16;if(sys(NR_sigprocmask,0,(long)&mask,0,8,0,0))return 14;
    int ends[2];if(call3(NR_pipe2,(long)ends,0,0))return 15;
    long pid=guest_fork();if(pid<0)return 16;
    if(!pid){
        if(mode=='k'){for(;;)delay();}
        if(mode=='q'){call3(NR_close,ends[0],0,0);delay();char byte='x';call3(NR_write,ends[1],(long)&byte,1);return 99;}
        delay();return 37;
    }
    if(call3(NR_close,ends[1],0,0))return 17;
    if(mode=='q'&&call3(NR_close,ends[0],0,0))return 17;
    if(mode=='k'&&call3(NR_kill,pid,9,0))return 18;
    if(sys(NR_sigprocmask,1,(long)&mask,0,8,0,0))return 19;
    if(mode=='n'){
        long request[2]={1,0},remaining[2]={-1,-1};
        long result;
#if defined(__x86_64__)
        result=call3(35,(long)request,(long)remaining,0);
#else
        result=call3(101,(long)request,(long)remaining,0);
#endif
        if(result!=-4||remaining[0]<0||remaining[0]>1||remaining[1]<0||remaining[1]>=1000000000)return 20;
    }else if(mode=='f'){
        int word=0;long timeout[2]={1,0};
        if(sys(NR_futex,(long)&word,128,0,(long)timeout,0,0)!=-4)return 20;
    }else if(mode!='k'&&mode!='q'){
        char byte;long result=call3(NR_read,ends[0],(long)&byte,1);
        if(result!=(mode=='r'?0:-4))return 21;
    }
    int status=0;long waited;do{waited=sys(NR_wait4,pid,(long)&status,0,0,0,0);}while(waited==-4);
    int signal=mode=='q'?13:mode=='k'?9:0;
    if(waited!=pid||status!=(signal?signal:37<<8))return 22;
    if(!seen||failed||last_pid!=pid||last_status!=(signal?signal:37)||last_code!=(signal?CLD_KILLED:CLD_EXITED))return 23;
    text("signals: interrupted wait, child notification and exit status ok\n",sizeof("signals: interrupted wait, child notification and exit status ok\n")-1);return 0;
}
