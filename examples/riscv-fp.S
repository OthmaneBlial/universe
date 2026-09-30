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
    fcvt.s.wu ft6, t5, rne
    fmv.x.w t4, ft6
    li t2, 0x4b800000
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
.section .rodata
message:
    .ascii "riscv F/D CSR: ok\n"
message_end:
