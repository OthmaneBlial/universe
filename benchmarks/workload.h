static volatile unsigned long long workload_iterations=100000;
static unsigned long long workload(void){unsigned long long x=0x123456789abcdef0ULL,sum=0;for(unsigned long long i=0;i<workload_iterations;i++){x^=x<<13;x^=x>>7;x^=x<<17;sum+=x;}return sum;}
