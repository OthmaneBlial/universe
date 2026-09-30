#include "guest.h"
long guest_main(long *sp){(void)sp;static const char msg[]="Hello from foreign Linux machine code!\n";return text(msg,sizeof(msg)-1)==sizeof(msg)-1?0:1;}
