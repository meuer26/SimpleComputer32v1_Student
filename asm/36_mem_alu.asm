; 36_mem_alu.asm -- ALU ops with a memory operand, load direction (r <- r op [m]).
; Every arithmetic/logic op reads one operand straight from memory, as gcc does
; for locals and globals. Ends with a CMP against memory feeding a conditional
; branch, so the flags set by a memory-operand compare are exercised too.
bits 32
        mov     dword [0x80], 0x0F
        mov     eax, 0xF0
        add     eax, [0x80]             ; 0xF0 + 0x0F = 0xFF
        mov     ebx, eax                ; save 0xFF
        sub     eax, [0x80]             ; 0xFF - 0x0F = 0xF0
        and     eax, [0x80]             ; 0xF0 & 0x0F = 0x00
        or      eax, [0x80]             ; 0x00 | 0x0F = 0x0F
        xor     eax, [0x80]             ; 0x0F ^ 0x0F = 0x00  (EAX ends 0)

        mov     ecx, 50
        mov     dword [0x84], 50
        cmp     ecx, [0x84]             ; 50 == 50 -> ZF = 1
        mov     edx, 0
        je      .equal
        mov     edx, 999                ; (skipped if CMP-with-memory set ZF)
.equal:
        mov     [0x100], ebx            ; 0xFF for the memory check
        hlt
