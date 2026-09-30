.global _start
.text
_start:
    mov $1, %eax
    mov $1, %edi
    lea message(%rip), %rsi
    mov $message_end-message, %edx
    syscall
    xor %edi, %edi
    mov $60, %eax
    syscall
.section .rodata
message: .ascii "Hello from x86-64 Linux!\n"
message_end:
