.option rvc
.text
.globl _start
_start:
    la s0, values
    fld ft0, 0(s0)
    fld ft1, 8(s0)
    fsgnj.d ft2, ft0, ft1
    fclass.d t1, ft2
    li t2, 2
    bne t1, t2, fail
    fmv.x.d t3, ft2

    addi sp, sp, -16
    c.fsdsp ft2, 256(sp)
    c.fldsp ft3, 256(sp)
    addi sp, sp, 16
    fmv.x.d t4, ft3
    bne t3, t4, fail
    c.fld fs0, 0(s0)
    c.fsd fs0, 24(s0)
    ld t4, 24(s0)
    fmv.x.d t5, fs0
    bne t5, t4, fail

    flw ft3, 32(s0)
    fmv.x.d t6, ft3
    li t4, 0xffffffff3f800000
    bne t6, t4, fail
    fclass.s t1, ft3
    li t2, 64
    bne t1, t2, fail
    flw ft3, 36(s0)
    fclass.s t1, ft3
    li t2, 512
    bne t1, t2, fail

    flt.d t1, ft1, ft0
    li t2, 1
    bne t1, t2, fail
    feq.d t1, ft0, ft0
    bne t1, t2, fail

    fadd.d ft4, ft0, ft0, dyn
    fmv.x.d t4, ft4
    li t2, 0x4010000000000000
    bne t4, t2, fail
    fsub.d ft5, ft4, ft0, dyn
    fmv.x.d t4, ft5
    li t2, 0x4000000000000000
    bne t4, t2, fail
    fmul.d ft6, ft0, ft0, dyn
    fmv.x.d t4, ft6
    li t2, 0x4010000000000000
    bne t4, t2, fail
    fdiv.d ft7, ft6, ft4, dyn
    fmv.x.d t4, ft7
    li t2, 0x3ff0000000000000
    bne t4, t2, fail
    fsqrt.d fa0, ft4, dyn
    fmv.x.d t4, fa0
    li t2, 0x4000000000000000
    bne t4, t2, fail
    fmadd.d fa1, ft0, ft0, ft0, dyn
    fmv.x.d t4, fa1
    li t2, 0x4018000000000000
    bne t4, t2, fail
    fmsub.d fa1, ft0, ft0, ft0, dyn
    fmv.x.d t4, fa1
    li t2, 0x4000000000000000
    bne t4, t2, fail
    fnmsub.d fa1, ft0, ft0, ft0, dyn
    fmv.x.d t4, fa1
    li t2, 0xc000000000000000
    bne t4, t2, fail
    fnmadd.d fa1, ft0, ft0, ft0, dyn
    fmv.x.d t4, fa1
    li t2, 0xc018000000000000
    bne t4, t2, fail
    fmin.d ft5, ft0, ft1
    fmv.x.d t4, ft5
    li t2, 0xc008000000000000
    bne t4, t2, fail
    fmax.d ft5, ft0, ft1
    fmv.x.d t4, ft5
    li t2, 0x4000000000000000
    bne t4, t2, fail
    flw ft4, 32(s0)
    fadd.s ft5, ft4, ft4, dyn
    fmv.x.w t4, ft5
    li t2, 0x40000000
    bne t4, t2, fail

    fld ft4, 144(s0)
    fld ft5, 136(s0)
    csrrwi zero, fflags, 0
    fadd.d ft6, ft4, ft5, rup
    fmv.x.d t4, ft6
    li t2, 0x3ff0000000000001
    bne t4, t2, fail
    csrrs t4, fflags, zero
    li t2, 1
    bne t4, t2, fail
    fadd.d ft6, ft4, ft5, rdn
    fmv.x.d t4, ft6
    li t2, 0x3ff0000000000000
    bne t4, t2, fail
    fadd.d ft6, ft4, ft5, rtz
    fmv.x.d t4, ft6
    bne t4, t2, fail
    fld ft4, 16(s0)
    fld ft5, 168(s0)
    fadd.d ft6, ft4, ft5, rdn
    fmv.x.d t4, ft6
    li t2, 0x8000000000000000
    bne t4, t2, fail
    fsub.d ft6, ft0, ft0, rdn
    fmv.x.d t4, ft6
    bne t4, t2, fail
    fld ft4, 144(s0)
    fld ft5, 136(s0)
    fmadd.d fa1, ft4, ft4, ft5, rmm
    fmv.x.d t4, fa1
    li t2, 0x3ff0000000000001
    bne t4, t2, fail

    fld ft6, 152(s0)
    fdiv.d ft7, ft4, ft6, rup
    fmv.x.d t4, ft7
    li t2, 0x3fd5555555555556
    bne t4, t2, fail
    fdiv.d ft7, ft4, ft6, rdn
    fmv.x.d t4, ft7
    li t2, 0x3fd5555555555555
    bne t4, t2, fail
    fsqrt.d fa0, ft0, rdn
    fmv.x.d t4, fa0
    li t2, 0x3ff6a09e667f3bcc
    bne t4, t2, fail
    csrrs t4, fflags, zero
    li t2, 1
    bne t4, t2, fail
    csrrwi zero, fflags, 0

    fld ft4, 160(s0)
    fld ft5, 72(s0)
    fmul.d fa0, ft4, ft5, rdn
    fmv.x.d t4, fa0
    li t2, 0x8000000000000001
    bne t4, t2, fail
    csrrs t4, fflags, zero
    li t2, 3
    bne t4, t2, fail
    csrrwi zero, fflags, 0

    fld ft4, 56(s0)
    fmul.d ft5, ft4, ft0, rup
    fclass.d t1, ft5
    li t2, 128
    bne t1, t2, fail
    csrrs t4, fflags, zero
    li t2, 5
    bne t4, t2, fail
    csrrwi zero, fflags, 0
    fmul.d ft5, ft4, ft0, rdn
    fmv.x.d t4, ft5
    li t2, 0x7fefffffffffffff
    bne t4, t2, fail
    csrrs t4, fflags, zero
    li t2, 5
    bne t4, t2, fail
    csrrwi zero, fflags, 0

    flw ft3, 32(s0)
    fcvt.d.s ft5, ft3, dyn
    fmv.x.d t4, ft5
    li t2, 0x3ff0000000000000
    bne t4, t2, fail
    flw ft3, 36(s0)

    fld ft4, 80(s0)
    csrrwi zero, fflags, 0
    fcvt.s.d ft5, ft4, rne
    fmv.x.w t4, ft5
    li t2, 0x3f800000
    bne t4, t2, fail
    csrrs t4, fflags, zero
    li t2, 1
    bne t4, t2, fail
    fcvt.s.d ft5, ft4, rmm
    fmv.x.w t4, ft5
    li t2, 0x3f800001
    bne t4, t2, fail
    fcvt.s.d ft5, ft4, rup
    fmv.x.w t4, ft5
    bne t4, t2, fail
    fcvt.s.d ft5, ft4, rtz
    fmv.x.w t4, ft5
    li t2, 0x3f800000
    bne t4, t2, fail
    fld ft4, 88(s0)
    fcvt.s.d ft5, ft4, rdn
    fmv.x.w t4, ft5
    li t2, -0x407fffff
    bne t4, t2, fail

    fld ft4, 96(s0)
    csrrwi zero, fflags, 0
    fcvt.s.d ft5, ft4, rdn
    fmv.x.w t4, ft5
    li t2, 0x7f7fffff
    bne t4, t2, fail
    csrrs t4, fflags, zero
    li t2, 5
    bne t4, t2, fail
    csrrwi zero, fflags, 0
    fcvt.s.d ft5, ft4, rup
    fclass.s t1, ft5
    li t2, 128
    bne t1, t2, fail
    csrrs t4, fflags, zero
    li t2, 5
    bne t4, t2, fail
    fld ft4, 104(s0)
    csrrwi zero, fflags, 0
    fcvt.s.d ft5, ft4, rne
    fmv.x.w t4, ft5
    bnez t4, fail
    csrrs t4, fflags, zero
    li t2, 3
    bne t4, t2, fail
    fcvt.s.d ft5, ft4, rmm
    fmv.x.w t4, ft5
    li t2, 1
    bne t4, t2, fail
    fld ft4, 128(s0)
    csrrwi zero, fflags, 0
    fcvt.s.d ft5, ft4, rdn
    fmv.x.w t4, ft5
    li t2, -0x7fffffff
    bne t4, t2, fail
    csrrs t4, fflags, zero
    li t2, 3
    bne t4, t2, fail
    csrrwi zero, fflags, 0

    fld ft4, 112(s0)
    fcvt.s.d ft5, ft4, rne
    fmv.x.w t4, ft5
    li t2, 0x7fc00000
    bne t4, t2, fail
    fld ft4, 120(s0)
    csrrwi zero, fflags, 0
    fcvt.s.d ft5, ft4, rne
    fmv.x.w t4, ft5
    li t2, 0x7fc00000
    bne t4, t2, fail
    csrrs t4, fflags, zero
    li t2, 16
    bne t4, t2, fail
    csrrwi zero, fflags, 0

    fld ft4, 40(s0)
    csrrwi zero, fflags, 0
    fdiv.d ft5, ft4, ft1, dyn
    csrrs t4, fflags, zero
    li t2, 1
    bne t4, t2, fail
    csrrwi zero, fflags, 0
    fcvt.d.w ft6, zero, rne
    fdiv.d ft7, ft4, ft6, dyn
    fclass.d t1, ft7
    li t2, 128
    bne t1, t2, fail
    csrrs t4, fflags, zero
    li t2, 8
    bne t4, t2, fail
    csrrwi zero, fflags, 0
    fdiv.d ft7, ft6, ft6, dyn
    fclass.d t1, ft7
    li t2, 512
    bne t1, t2, fail
    csrrs t4, fflags, zero
    li t2, 16
    bne t4, t2, fail
    csrrwi zero, fflags, 0
    fsqrt.d ft7, ft1, dyn
    fclass.d t1, ft7
    li t2, 512
    bne t1, t2, fail
    csrrs t4, fflags, zero
    li t2, 16
    bne t4, t2, fail
    csrrwi zero, fflags, 0
    fld ft4, 56(s0)
    fmul.d ft5, ft4, ft0, dyn
    fclass.d t1, ft5
    li t2, 128
    bne t1, t2, fail
    csrrs t4, fflags, zero
    li t2, 5
    bne t4, t2, fail
    csrrwi zero, fflags, 0
    fld ft4, 64(s0)
    fld ft5, 72(s0)
    fmul.d ft6, ft4, ft5, dyn
    fclass.d t1, ft6
    li t2, 16
    bne t1, t2, fail
    csrrs t4, fflags, zero
    li t2, 3
    bne t4, t2, fail
    csrrwi zero, fflags, 0

    fld ft4, 40(s0)
    fcvt.w.d t1, ft4, rne
    li t2, 2
    bne t1, t2, fail
    fcvt.w.d t1, ft4, rmm
    li t2, 3
    bne t1, t2, fail
    fcvt.w.d t1, ft4, rdn
    li t2, 2
    bne t1, t2, fail
    fcvt.w.d t1, ft4, rup
    li t2, 3
    bne t1, t2, fail
    fcvt.w.d t1, ft4, rtz
    li t2, 2
    bne t1, t2, fail
    fcvt.w.d t1, ft4, dyn
    li t2, 2
    bne t1, t2, fail
    fcvt.wu.d t1, ft4, rne
    bne t1, t2, fail
    fcvt.l.d t1, ft4, rne
    bne t1, t2, fail
    fcvt.lu.d t1, ft4, rne
    bne t1, t2, fail
    csrrs t4, fflags, zero
    li t2, 1
    bne t4, t2, fail
    csrrwi zero, fflags, 0

    li t5, 16777217
    fcvt.s.w ft6, t5, rne
    fmv.x.w t4, ft6
    li t2, 0x4b800000
    bne t4, t2, fail
    csrrs t4, fflags, zero
    li t2, 1
    bne t4, t2, fail
    csrrwi zero, fflags, 0
    fcvt.s.w ft6, t5, rup
    fmv.x.w t4, ft6
    li t2, 0x4b800001
    bne t4, t2, fail
    fcvt.s.w ft6, t5, rdn
    fmv.x.w t4, ft6
    li t2, 0x4b800000
    bne t4, t2, fail
    fcvt.s.w ft6, t5, rtz
    fmv.x.w t4, ft6
    bne t4, t2, fail
    fcvt.s.w ft6, t5, rmm
    fmv.x.w t4, ft6
    li t2, 0x4b800001
    bne t4, t2, fail
    fcvt.s.wu ft6, t5, rne
    fmv.x.w t4, ft6
    li t2, 0x4b800000
    bne t4, t2, fail
    li t5, 9007199254740993
    fcvt.d.l ft6, t5, rmm
    fmv.x.d t4, ft6
    li t2, 0x4340000000000001
    bne t4, t2, fail
    fcvt.d.l ft6, t5, rdn
    fmv.x.d t4, ft6
    li t2, 0x4340000000000000
    bne t4, t2, fail
    li t5, 0x100000000
    fcvt.d.l ft6, t5, rne
    fmv.x.d t4, ft6
    li t2, 0x41f0000000000000
    bne t4, t2, fail
    fcvt.d.lu ft6, t5, rne
    fmv.x.d t4, ft6
    bne t4, t2, fail
    fcvt.s.l ft6, t5, rne
    fmv.x.w t4, ft6
    li t2, 0x4f800000
    bne t4, t2, fail
    fcvt.s.lu ft6, t5, rne
    fmv.x.w t4, ft6
    bne t4, t2, fail
    fld ft5, 48(s0)
    fcvt.w.d t1, ft5, rmm
    li t2, -3
    bne t1, t2, fail
    fcvt.w.d t1, ft5, dyn
    li t2, -2
    bne t1, t2, fail

    csrrw zero, fflags, zero
    feq.s t1, ft3, ft3
    bnez t1, fail
    csrrs t4, fflags, zero
    bnez t4, fail
    flt.s t1, ft3, ft3
    csrrs t4, fflags, zero
    li t2, 16
    bne t4, t2, fail
    csrrw zero, fflags, zero
    fcvt.w.s t1, ft3, rne
    li t2, 0x7fffffff
    bne t1, t2, fail
    csrrs t4, fflags, zero
    li t2, 16
    bne t4, t2, fail
    csrrw zero, fflags, zero
    fcvt.wu.d t1, ft1, rne
    bnez t1, fail
    csrrs t4, fflags, zero
    li t2, 16
    bne t4, t2, fail

    li t5, 3
    csrrw zero, frm, t5
    csrrs t4, frm, zero
    bne t4, t5, fail
    fld ft4, 144(s0)
    fld ft5, 136(s0)
    fadd.d ft6, ft4, ft5, dyn
    fmv.x.d t4, ft6
    li t2, 0x3ff0000000000001
    bne t4, t2, fail
    li t5, 0x41
    csrrw zero, fcsr, t5
    csrrs t4, fflags, zero
    li t2, 1
    bne t4, t2, fail
    csrrs t4, frm, zero
    li t2, 2
    bne t4, t2, fail
    li t5, 1
    csrrc zero, fflags, t5
    csrrs t4, fflags, zero
    bnez t4, fail
    csrrwi zero, fflags, 0
    csrrsi t4, fflags, 4
    bnez t4, fail
    csrrci t4, fflags, 4
    csrrs t4, fflags, zero
    bnez t4, fail

    li a0, 1
    la a1, message
    li a2, message_end-message
    li a7, 64
    ecall
    li a0, 0
    li a7, 93
    ecall
fail:
    li a0, 1
    li a7, 93
    ecall

.section .data
.align 3
values:
    .dword 0x4000000000000000
    .dword 0xc008000000000000
    .dword 0
    .dword 0
    .word 0x3f800000
    .word 0x7fc00000
    .dword 0x4004000000000000
    .dword 0xc004000000000000
    .dword 0x7fefffffffffffff
    .dword 0x0000000000000001
    .dword 0x3fe0000000000000
    .dword 0x3ff0000010000000
    .dword 0xbff0000010000000
    .dword 0x47f0000000000000
    .dword 0x3690000000000000
    .dword 0x7ff8000000000000
    .dword 0x7ff0000000000001
    .dword 0xb690000000000000
    .dword 0x3ca0000000000000
    .dword 0x3ff0000000000000
    .dword 0x4008000000000000
    .dword 0x8000000000000001
    .dword 0x8000000000000000
.section .rodata
message:
    .ascii "riscv F/D CSR: ok\n"
message_end:
