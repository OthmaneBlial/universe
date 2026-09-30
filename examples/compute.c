#include "guest.h"
static volatile long values[32];
__attribute__((noinline)) static long fib(long n){if(n<2)return n;return fib(n-1)+fib(n-2);}
__attribute__((noinline)) static long product(long a,long b){return a*b;}
long guest_main(long *sp){(void)sp;long sum=0;for(long i=0;i<32;i++){values[i]=i;sum+=values[i];}if(sum!=496||fib(10)!=55||product(123,37)!=4551)return 2;
    volatile long a=-12345,b=37;if(a/b!=-333||a%b!=-24)return 3;
    unsigned long x=0xfedcba9876543210UL;if((x>>40)!=0xfedcba||((long)x>>60)!=-1)return 4;
    text("compute: ok\n",12);return 0;
}
