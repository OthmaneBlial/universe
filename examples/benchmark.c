#include "guest.h"
#include "../benchmarks/workload.h"
long guest_main(long *sp){(void)sp;unsigned long long sum=workload();char out[17];for(long i=0;i<16;i++){unsigned long nibble=(sum>>((15-i)*4))&15;out[i]=nibble<10?'0'+nibble:'a'+nibble-10;}out[16]='\n';text(out,17);return 0;}
