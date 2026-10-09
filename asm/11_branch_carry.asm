; Test 11: JC based on carry flag; CLC/STC and ADD carry-out.
; Expected: EAX=0x4B ; mem 0x100=01 0x104=02 0x108=03 0x10C=4B
bits 32
    clc
    jc trap
    mov eax, 1
    mov [0x100], eax
    stc
    jc branch1
    hlt                 ; trap2 (must be skipped)
branch1:
    mov eax, 2
    mov [0x104], eax
    clc
    mov eax, 0x10
    add eax, 5
    jc trap
    mov eax, 3
    mov [0x108], eax
    mov eax, 0xFFFFFFFF
    add eax, 1
    jc success
    hlt                 ; trap4 (must be skipped)
success:
    mov eax, 0x4B
    mov [0x10C], eax
    hlt
trap:
    hlt
