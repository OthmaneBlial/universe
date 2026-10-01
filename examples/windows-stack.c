/* The caller must provide all four Win64 home slots before entry executes. */
#include <windows.h>
__attribute__((used,noinline)) void stack_checked(void) {
    const char text[]="windows entry: aligned stack and all four home slots ok\n";DWORD count=0;
    BOOL ok=WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,sizeof(text)-1,&count,0);
    ExitProcess(ok&&count==sizeof(text)-1?0:201);
}
__attribute__((naked)) void mainCRTStartup(void) {
    __asm__(
        "movq %rsp,%rax\n"
        "andl $15,%eax\n"
        "cmpl $8,%eax\n"
        "jne 1f\n"
        "movq %rcx,8(%rsp)\n"
        "movq %rdx,16(%rsp)\n"
        "movq %r8,24(%rsp)\n"
        "movq %r9,32(%rsp)\n"
        "subq $40,%rsp\n"
        "call stack_checked\n"
        "1: movl $202,%ecx\n"
        "subq $40,%rsp\n"
        "call ExitProcess\n"
        "ud2\n");
}
