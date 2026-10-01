#include <stdint.h>
#include "guest.h"
struct query { uint32_t operation, control; uint64_t left_sig, left_exp, right_sig, right_exp; uint32_t tag, status; };
struct answer { unsigned char value[10]; uint16_t status; uint32_t control, mxcsr; uint8_t tag, padding[3]; uint64_t flags; } __attribute__((packed));
static _Alignas(16) unsigned char reset[512], image[512];
#define OP(bytes) __asm__ volatile("mov $0x7f,%%eax\n\tadd $1,%%al\n\t.byte " bytes "\n\tsetc %0\n\tsetp %1\n\tsetz %2\n\tsets %3\n\tseto %4" : "=m"(condition[0]), "=m"(condition[1]), "=m"(condition[2]), "=m"(condition[3]), "=m"(condition[4]) : "D"(&q.right_sig) : "rax", "cc", "memory")
#define MOVE(bytes) __asm__ volatile("mov $1,%%eax\n\tsub %5,%%al\n\t.byte " bytes "\n\tsetc %0\n\tsetp %1\n\tsetz %2\n\tsets %3\n\tseto %4" : "=m"(condition[0]), "=m"(condition[1]), "=m"(condition[2]), "=m"(condition[3]), "=m"(condition[4]) : "q"((unsigned char)(q.tag>>8)) : "rax", "cc", "memory")
long guest_main(long *sp) {
    (void)sp;
    for (;;) {
        struct query q;
        unsigned used = 0;
        while (used < sizeof(q)) {
            long n = sys(NR_read, 0, (long)((char *)&q + used), sizeof(q) - used, 0, 0, 0);
            if (n == 0) return used == 0 ? 0 : 90;
            if (n < 0) return 91;
            used += (unsigned)n;
        }
        reset[0]=q.control; reset[1]=q.control>>8;
        reset[2]=q.status; reset[3]=q.status>>8; reset[4]=q.tag;
        reset[24]=0x80; reset[25]=0x1f;
        for(unsigned n=0;n<8;++n) { reset[32+n]=q.left_sig>>(n*8); reset[48+n]=q.right_sig>>(n*8); }
        reset[40]=q.left_exp; reset[41]=q.left_exp>>8;
        reset[56]=q.right_exp; reset[57]=q.right_exp>>8;
        __asm__ volatile("fxrstor64 %0" : : "m"(reset) : "memory");
        struct answer result = { { 0 }, 0, 0, 0, 0, { 0 }, 0 };
        unsigned char condition[5];
        unsigned slot=0;
        switch(q.operation) {
            case 0: OP("0xd8,0xc1"); break;
            case 1: OP("0xd8,0xc9"); break;
            case 2: OP("0xd8,0xe1"); break;
            case 3: OP("0xd8,0xe9"); break;
            case 4: OP("0xd8,0xf1"); break;
            case 5: OP("0xd8,0xf9"); break;
            case 6: OP("0xdc,0xc1"); slot=1; break;
            case 7: OP("0xdc,0xc9"); slot=1; break;
            case 8: OP("0xdc,0xe1"); slot=1; break;
            case 9: OP("0xdc,0xe9"); slot=1; break;
            case 10: OP("0xdc,0xf1"); slot=1; break;
            case 11: OP("0xdc,0xf9"); slot=1; break;
            case 12: OP("0xde,0xc1"); break;
            case 13: OP("0xde,0xc9"); break;
            case 14: OP("0xde,0xe1"); break;
            case 15: OP("0xde,0xe9"); break;
            case 16: OP("0xde,0xf1"); break;
            case 17: OP("0xde,0xf9"); break;
            case 18: OP("0xd8,0x07"); break;
            case 19: OP("0xd8,0x0f"); break;
            case 20: OP("0xd8,0x17"); break;
            case 21: OP("0xd8,0x1f"); break;
            case 22: OP("0xd8,0x27"); break;
            case 23: OP("0xd8,0x2f"); break;
            case 24: OP("0xd8,0x37"); break;
            case 25: OP("0xd8,0x3f"); break;
            case 26: OP("0xdc,0x07"); break;
            case 27: OP("0xdc,0x0f"); break;
            case 28: OP("0xdc,0x17"); break;
            case 29: OP("0xdc,0x1f"); break;
            case 30: OP("0xdc,0x27"); break;
            case 31: OP("0xdc,0x2f"); break;
            case 32: OP("0xdc,0x37"); break;
            case 33: OP("0xdc,0x3f"); break;
            case 34: OP("0xda,0x07"); break;
            case 35: OP("0xda,0x0f"); break;
            case 36: OP("0xda,0x17"); break;
            case 37: OP("0xda,0x1f"); break;
            case 38: OP("0xda,0x27"); break;
            case 39: OP("0xda,0x2f"); break;
            case 40: OP("0xda,0x37"); break;
            case 41: OP("0xda,0x3f"); break;
            case 42: OP("0xde,0x07"); break;
            case 43: OP("0xde,0x0f"); break;
            case 44: OP("0xde,0x17"); break;
            case 45: OP("0xde,0x1f"); break;
            case 46: OP("0xde,0x27"); break;
            case 47: OP("0xde,0x2f"); break;
            case 48: OP("0xde,0x37"); break;
            case 49: OP("0xde,0x3f"); break;
            case 50: OP("0xd8,0xd1"); break;
            case 51: OP("0xd8,0xd9"); break;
            case 52: OP("0xde,0xd9"); break;
            case 53: OP("0xdd,0xe1"); break;
            case 54: OP("0xdd,0xe9"); break;
            case 55: OP("0xda,0xe9"); break;
            case 56: OP("0xdb,0xf1"); break;
            case 57: OP("0xdf,0xf1"); break;
            case 58: OP("0xdb,0xe9"); break;
            case 59: OP("0xdf,0xe9"); break;
            case 60: OP("0xd9,0xe4"); break;
            case 61: OP("0xd9,0xfa"); break;
            case 62: OP("0xd9,0xfc"); break;
            case 63: OP("0xd9,0xe8"); break;
            case 64: OP("0xd9,0xe9"); break;
            case 65: OP("0xd9,0xea"); break;
            case 66: OP("0xd9,0xeb"); break;
            case 67: OP("0xd9,0xec"); break;
            case 68: OP("0xd9,0xed"); break;
            case 69: OP("0xd9,0xee"); break;
            case 70: MOVE("0xda,0xc1"); break;
            case 71: MOVE("0xda,0xc9"); break;
            case 72: MOVE("0xda,0xd1"); break;
            case 73: MOVE("0xda,0xd9"); break;
            case 74: MOVE("0xdb,0xc1"); break;
            case 75: MOVE("0xdb,0xc9"); break;
            case 76: MOVE("0xdb,0xd1"); break;
            case 77: MOVE("0xdb,0xd9"); break;
            case 78: OP("0xd9,0xf4"); break;
            case 79: OP("0xd9,0xf4"); slot=1; break;
            default: return 92;
        }
        __asm__ volatile("fnstsw %0\n\tfnstcw %1\n\tfxsave64 %2" : "=m"(result.status), "=m"(result.control), "=m"(image) : : "memory");
        for(unsigned n=0;n<10;++n) result.value[n]=image[32+slot*16+n];
        result.mxcsr=(uint32_t)image[24]|((uint32_t)image[25]<<8)|((uint32_t)image[26]<<16)|((uint32_t)image[27]<<24);
        result.tag=image[4];
        result.flags=2|(uint64_t)condition[0]|((uint64_t)condition[1]<<2)|((uint64_t)condition[2]<<6)|((uint64_t)condition[3]<<7)|((uint64_t)condition[4]<<11);
        if(sys(NR_write,1,(long)&result,sizeof(result),0,0,0)!=sizeof(result)) return 93;
    }
}
