; Test 07: register-to-register ALU (01/29/39/21/09/31/85) + Jcc.
; Expected: EAX=7 EBX=7 ECX=0 ; Z=0 C=0 ; mem[0x100]=07 00 00 00
bits 32
    mov eax, 5
    mov ebx, 3
    add eax, ebx        ; 8
    sub eax, ebx        ; 5
    mov eax, ebx        ; 3
    mov eax, 0x0F
    mov ebx, 0xF0
    or  eax, ebx        ; 0xFF
    and eax, ebx        ; 0xF0
    xor eax, ebx        ; 0x00
    mov eax, 7
    mov ebx, 7
    cmp eax, ebx        ; Z=1 (equal)
    jne should_not_branch
    test eax, ebx       ; 7 AND 7 -> Z=0
    mov [0x100], eax
should_not_branch:
    hlt
