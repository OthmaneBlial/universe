/* Darwin syscall-only test support. No libc is linked into the guest. */
#if defined(__x86_64__)
#define PAGE_SIZE 4096
static long sys(long n, long a, long b, long c, long d, long e, long f) {
    register long r10 __asm__("r10")=d, r8 __asm__("r8")=e, r9 __asm__("r9")=f;
    long result=n|0x2000000; unsigned char error;
    __asm__ volatile("syscall\n\tsetc %1":"+a"(result),"=qm"(error),"+d"(c):"D"(a),"S"(b),"r"(r10),"r"(r8),"r"(r9):"rcx","r11","cc","memory");
    return error ? -result : result;
}
#ifndef MACOS_NATIVE_REFERENCE
__asm__(".globl _start\n_start:\nmov %rsp,%rdi\nand $-16,%rsp\ncall _guest_main\nmov %rax,%rdi\nmov $0x2000001,%eax\nsyscall\n");
#endif
#elif defined(__aarch64__)
#define PAGE_SIZE 16384
static long sys(long n, long a, long b, long c, long d, long e, long f) {
    register long x0 __asm__("x0")=a, x1 __asm__("x1")=b, x2 __asm__("x2")=c,
        x3 __asm__("x3")=d, x4 __asm__("x4")=e, x5 __asm__("x5")=f, x16 __asm__("x16")=n;
    unsigned error;
    __asm__ volatile("svc #0x80\n\tcset %w2,cs":"+r"(x0),"+r"(x1),"=r"(error):"r"(x2),"r"(x3),"r"(x4),"r"(x5),"r"(x16):"cc","memory");
    return error ? -x0 : x0;
}
#ifndef MACOS_NATIVE_REFERENCE
__asm__(".globl _start\n_start:\nmov x0,sp\nbl _guest_main\nmov x16,#1\nsvc #0x80\n");
#endif
#endif
#ifdef MACOS_NATIVE_REFERENCE
/* Same syscall test code with normal host startup; initial guest stack is tested separately. */
long guest_main(unsigned long *);
int main(int argc,char **argv) {
    if (argc>62) return 125;
    unsigned long stack[64];stack[0]=argc;
    for (int i=0;i<argc;i++) stack[i+1]=(unsigned long)argv[i];
    stack[argc+1]=0;
    return guest_main(stack);
}
#endif
static long call3(long n,long a,long b,long c) { return sys(n,a,b,c,0,0,0); }
static long text(const char *s,long n) { return call3(4,1,(long)s,n); }
static long length(const char *s) { long n=0;while(s[n])n++;return n; }
