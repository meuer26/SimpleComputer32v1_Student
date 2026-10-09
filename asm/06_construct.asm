; Test 06: construct 0xDEADBEEF from bytes using SHL-by-8 + ADD.
; Expected: EAX=0xDEADBEEF ; mem[0x100]=EF BE AD DE
bits 32
    mov eax, 0xDE
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    add eax, 0xAD
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    add eax, 0xBE
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    add eax, 0xEF
    mov [0x100], eax
    hlt
