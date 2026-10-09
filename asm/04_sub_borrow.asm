; Test 04: SUB + borrow (CF), CLC/STC.
; Expected: EAX=0x50 EBX=0x40 ECX=0xFFFFFFF0 ; C=1 ; mem 0x100=5F 0x104=A1 FF FF FF
bits 32
    mov eax, 0x64
    sub eax, 5
    mov [0x100], eax
    mov eax, 5
    sub eax, 0x64
    mov [0x104], eax
    stc
    clc
    mov eax, 0x50
    mov ebx, eax
    sub ebx, 0x10
    mov ecx, eax
    sub ecx, 0x60
    hlt
