/* Linux syscall-only test support. No libc and no runtime linked into guests. */
#if defined(__aarch64__)
#define O_DIRECTORY 0x4000
#define O_NOFOLLOW 0x8000
#define O_LARGEFILE 0x20000
#else
#define O_DIRECTORY 0x10000
#define O_NOFOLLOW 0x20000
#define O_LARGEFILE 0x8000
#endif
#if defined(__x86_64__)
#define NR_read 0
#define NR_write 1
#define NR_fcntl 72
#define NR_getdents 217
#define NR_close 3
#define NR_fstat 5
#define NR_lseek 8
#define NR_mmap 9
#define NR_mprotect 10
#define NR_munmap 11
#define NR_brk 12
#define NR_clock 228
#define NR_openat 257
#define NR_mkdirat 258
#define NR_unlinkat 263
#define NR_faccessat 269
#define NR_access 21
#define NR_rename 82
#define NR_renameat 264
#define NR_random 318
#define NR_uname 63
#define NR_exit 60
static long sys(long n,long a,long b,long c,long d,long e,long f) {
    register long r10 __asm__("r10")=d, r8 __asm__("r8")=e, r9 __asm__("r9")=f;
    long result; __asm__ volatile("syscall":"=a"(result):"a"(n),"D"(a),"S"(b),"d"(c),"r"(r10),"r"(r8),"r"(r9):"rcx","r11","memory"); return result;
}
__asm__(".global _start\n_start:\nmov %rsp,%rdi\nand $-16,%rsp\ncall guest_main\nmov %rax,%rdi\nmov $60,%eax\nsyscall\n");
#elif defined(__riscv)
#define NR_read 63
#define NR_write 64
#define NR_fcntl 25
#define NR_getdents 61
#define NR_close 57
#define NR_fstat 80
#define NR_lseek 62
#define NR_mmap 222
#define NR_mprotect 226
#define NR_munmap 215
#define NR_brk 214
#define NR_clock 113
#define NR_openat 56
#define NR_mkdirat 34
#define NR_unlinkat 35
#define NR_faccessat 48
#define NR_renameat 38
#define NR_random 278
#define NR_uname 160
#define NR_exit 93
static long sys(long n,long a,long b,long c,long d,long e,long f) {
    register long a0 __asm__("a0")=a,a1 __asm__("a1")=b,a2 __asm__("a2")=c,a3 __asm__("a3")=d,a4 __asm__("a4")=e,a5 __asm__("a5")=f,a7 __asm__("a7")=n;
    __asm__ volatile("ecall":"+r"(a0):"r"(a1),"r"(a2),"r"(a3),"r"(a4),"r"(a5),"r"(a7):"memory");return a0;
}
__asm__(".global _start\n_start:\nmv a0,sp\ncall guest_main\nli a7,93\necall\n");
#elif defined(__aarch64__)
#define NR_read 63
#define NR_write 64
#define NR_fcntl 25
#define NR_getdents 61
#define NR_close 57
#define NR_fstat 80
#define NR_lseek 62
#define NR_mmap 222
#define NR_mprotect 226
#define NR_munmap 215
#define NR_brk 214
#define NR_clock 113
#define NR_openat 56
#define NR_mkdirat 34
#define NR_unlinkat 35
#define NR_faccessat 48
#define NR_renameat 38
#define NR_random 278
#define NR_uname 160
#define NR_exit 93
static long sys(long n,long a,long b,long c,long d,long e,long f) {
    register long x0 __asm__("x0")=a,x1 __asm__("x1")=b,x2 __asm__("x2")=c,x3 __asm__("x3")=d,x4 __asm__("x4")=e,x5 __asm__("x5")=f,x8 __asm__("x8")=n;
    __asm__ volatile("svc #0":"+r"(x0):"r"(x1),"r"(x2),"r"(x3),"r"(x4),"r"(x5),"r"(x8):"memory");return x0;
}
__asm__(".global _start\n_start:\nmov x0,sp\nbl guest_main\nmov x8,#93\nsvc #0\n");
#endif
static long call3(long n,long a,long b,long c){return sys(n,a,b,c,0,0,0);}
static long text(const char *s,long n){return call3(NR_write,1,(long)s,n);}
static long length(const char *s){long n=0;while(s[n])n++;return n;}
