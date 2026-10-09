; Test 01: basic register transfers (real x86-32)
;   MOV r32,imm32 (B8+r), MOV r/m32,r32 / r32,r/m32 (89/8B), MOV moffs (A3).
; Expected: EAX=EBX=ECX=0x11223344 ; mem[0x100]=44 33 22 11
bits 32
    mov eax, 0x11223344
    mov ebx, eax
    mov eax, 0
    mov eax, ebx
    mov ecx, eax
    mov eax, 0xFFFFFFFF
    mov eax, ecx
    mov [0x100], eax
    hlt
