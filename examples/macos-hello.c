#include "macos-guest.h"
long guest_main(unsigned long *stack) {
    (void)stack;
    const char message[]="Hello from macOS guest machine code!\n";
    return text(message,sizeof(message)-1)==sizeof(message)-1 ? 0 : 1;
}
