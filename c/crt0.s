/* crt0.s -- startup for gcc-compiled C on the teaching CPU.  Linked at address
 * 0 (the reset vector): set up the stack, call the C entry, then halt.        */
    .code32
    .text
    .globl _start
_start:
    mov $0xFF0, %esp          /* stack top (teaching-PC RAM is 4 KiB) */
    call run
1:  hlt
    jmp 1b

/* Mark the stack non-executable so the linker does not warn about an implied
 * executable stack (this flat image never runs code from the stack anyway). */
    .section .note.GNU-stack,"",@progbits
