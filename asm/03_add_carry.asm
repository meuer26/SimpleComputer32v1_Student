; Test 03: ADD + carry (83 /0 ib, 05 id, MOV+ADD for 3-operand forms).
; Expected: EAX=0x64 EBX=0x74 ECX=0x84 ; mem 0x100=15 0x104=0 0x108=0 ; Z=0 C=0
bits 32
    mov eax, 0x10
    add eax, 5
    mov [0x100], eax
    mov eax, 0xFFFFFFFF
    clc
    add eax, 1
    mov [0x104], eax
    mov eax, 0x80000000
    add eax, 0x80000000
    mov [0x108], eax
    mov eax, 0x64
    mov ebx, eax
    add ebx, 0x10
    mov ecx, eax
    add ecx, 0x20
    hlt
