; Test 05: SHL/SHR/ROL/ROR by 1 (D1 /n).
; Expected: EAX=0x80000001 ; mem 0x100=..80 0x104=02 0x108=01 0x10C=03 0x110=..80
bits 32
    mov eax, 0x80000001
    mov [0x100], eax
    shl eax, 1
    mov [0x104], eax
    shr eax, 1
    mov [0x108], eax
    mov eax, 0x80000001
    rol eax, 1
    mov [0x10C], eax
    ror eax, 1
    mov [0x110], eax
    hlt
