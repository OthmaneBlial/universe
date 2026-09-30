#include "macos-guest.h"
long guest_main(unsigned long *stack) {
    if (stack[0]<2) return 1;
    const char *path=(void *)stack[2];
    long fd=call3(5,(long)path,2|0x200|0x800,0600);
    if (fd==-13) { text("macOS files: denied\n",20);return 0; }
    if (fd<0) return 2;
    const char bytes[]="Darwin file\n";
    if (call3(4,fd,(long)bytes,sizeof(bytes)-1)!=sizeof(bytes)-1) return 3;
    if (call3(199,fd,0,0)) return 4;
    char copy[sizeof(bytes)];
    if (call3(3,fd,(long)copy,sizeof(copy))!=sizeof(bytes)-1) return 5;
    for (long i=0;i<sizeof(bytes)-1;i++) if (copy[i]!=bytes[i]) return 6;
    if (call3(3,fd,(long)copy,sizeof(copy))) return 7;
    long address=sys(197,0,2*PAGE_SIZE,3,2,fd,0);
    if (address<0 || address%PAGE_SIZE) return 8;
    volatile unsigned char *mapped=(void *)address;
    if (mapped[0]!='D' || mapped[PAGE_SIZE-1]) return 9;
    mapped[0]='X';
    if (stack[0]>2) return mapped[PAGE_SIZE]; /* Whole page beyond EOF faults. */
    if (call3(73,address,2*PAGE_SIZE,0) || call3(199,fd,0,0)) return 10;
    if (call3(3,fd,(long)copy,1)!=1 || copy[0]!='D') return 11;
    if (call3(6,fd,0,0) || call3(6,fd,0,0)!=-9) return 12;
    return text("macOS files: ok\n",16)==16 ? 0 : 13;
}
