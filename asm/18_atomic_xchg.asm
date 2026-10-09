; Test 18: XCHG [mem], EAX -- atomic exchange (87 /r). XCHG with memory is
; implicitly LOCKed on x86. Swaps EAX with mem[0x100].
; Expected: EAX=0x11223344 ; mem 0x100=EF BE AD DE ; mem 0x110=44 33 22 11
bits 32
    mov eax, 0x11223344
    mov [0x100], eax
    mov eax, 0xDEADBEEF
    xchg [0x100], eax
    mov [0x110], eax
    hlt
