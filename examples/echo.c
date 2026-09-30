#include "guest.h"
long guest_main(long *sp){(void)sp;char buf[32];long n=call3(NR_read,0,(long)buf,32);if(n<0)return 1;if(call3(NR_write,1,(long)buf,n)!=n)return 2;call3(NR_write,2,(long)"guest stderr\n",13);return 37;}
