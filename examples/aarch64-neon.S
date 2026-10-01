.text
.global _start
_start:
    adr x0, neon_inputs
    ldr q0, [x0]
    ldr q1, [x0, #16]
    adr x3, neon_output

    add v2.8b, v0.8b, v1.8b
    str q2, [x3], #16
    add v2.16b, v0.16b, v1.16b
    str q2, [x3], #16
    add v2.4h, v0.4h, v1.4h
    str q2, [x3], #16
    add v2.8h, v0.8h, v1.8h
    str q2, [x3], #16
    add v2.2s, v0.2s, v1.2s
    str q2, [x3], #16
    add v2.4s, v0.4s, v1.4s
    str q2, [x3], #16
    add v2.2d, v0.2d, v1.2d
    str q2, [x3], #16

    sub v2.8b, v0.8b, v1.8b
    str q2, [x3], #16
    sub v2.16b, v0.16b, v1.16b
    str q2, [x3], #16
    sub v2.4h, v0.4h, v1.4h
    str q2, [x3], #16
    sub v2.8h, v0.8h, v1.8h
    str q2, [x3], #16
    sub v2.2s, v0.2s, v1.2s
    str q2, [x3], #16
    sub v2.4s, v0.4s, v1.4s
    str q2, [x3], #16
    sub v2.2d, v0.2d, v1.2d
    str q2, [x3], #16

    mov x0, #1
    adr x1, neon_output
    mov x2, #224
    mov x8, #64
    svc #0
    mov x0, #0
    mov x8, #93
    svc #0

.section .rodata
.p2align 4
neon_inputs:
    .byte 0x01,0x7f,0x80,0xff,0x12,0x34,0x56,0x78,0x9a,0xbc,0xde,0xf0,0x55,0xaa,0x33,0xcc
    .byte 0xff,0x01,0x80,0x7f,0x34,0x12,0x78,0x56,0xbc,0x9a,0xf0,0xde,0xaa,0x55,0xcc,0x33
.bss
.p2align 4
neon_output:
    .skip 224
