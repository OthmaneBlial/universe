#include "macos-guest.h"
long guest_main(unsigned long *stack) {
    (void)stack;
    char buffer[128];
    long n=call3(3,0,(long)buffer,sizeof(buffer));
    if (n<0 || text(buffer,n)!=n) return 1;
    call3(4,2,(long)"Darwin guest stderr\n",20);
    return 37;
}
