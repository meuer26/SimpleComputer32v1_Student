; 37_mem_rmw.asm -- read-modify-write ALU on memory: [m] <- [m] op r, and the
; grp1 form [m] <- [m] op imm. These load the operand, compute, and store the
; result back in one instruction -- what gcc emits for `*p += x`, `a[i] &= m`,
; counters, and flag/bit twiddling.
bits 32
        mov     dword [0x90], 100
        mov     ebx, 23
        add     [0x90], ebx             ; RMW store-dir: 100 + 23 = 123
        mov     eax, [0x90]             ; EAX = 123 (0x7B)
        sub     [0x90], ebx             ; 123 - 23 = 100
        xor     dword [0x90], 0xFF      ; grp1 RMW imm8: 0x64 ^ 0xFF = 0x9B
        mov     ecx, [0x90]             ; ECX = 0x9B

        mov     dword [0x94], 0xF0
        and     dword [0x94], 0x0F      ; grp1 RMW: 0xF0 & 0x0F = 0x00
        or      dword [0x94], 0x22      ; 0x00 | 0x22 = 0x22
        mov     edx, [0x94]             ; EDX = 0x22
        hlt
