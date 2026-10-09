; Test 02: load/store round-trip + INC/DEC (40+r / 48+r)
; Expected: EAX=0x42 EBX=6 ECX=9 ; mem[0x100]=42.. mem[0x110]=42..
bits 32
    mov eax, 0x40
    inc eax
    inc eax
    dec eax
    inc eax
    mov [0x100], eax
    mov ebx, 5
    inc ebx
    inc ebx
    dec ebx
    mov ecx, 0x0A
    dec ecx
    dec ecx
    inc ecx
    mov eax, 0xDEADBEEF
    mov eax, [0x100]
    mov [0x110], eax
    hlt
