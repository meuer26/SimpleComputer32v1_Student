; 49_pairing.asm -- a loop whose body is a long run of INDEPENDENT instructions
; (no two adjacent ones share a register), so the U and V pipes co-issue two per
; clock.  It exists to show what the second (V) pipe buys:
;   make cpi-compare PROG=asm/49_pairing.asm
; The CPI report shows CPI ~0.5 superscalar (2 instructions/clock) vs ~1.0 with
; PIPE=scalar -- i.e. the V pipe roughly doubles throughput on pairable code.
bits 32
        mov     ecx, 500
        xor     eax, eax
        xor     ebx, ebx
        xor     esi, esi
        xor     edi, edi
.loop:
        add     eax, 1          ; \ 16 independent adds: adjacent ones use
        add     ebx, 1          ; / different registers, so each pair co-issues
        add     esi, 1
        add     edi, 1
        add     eax, 1
        add     ebx, 1
        add     esi, 1
        add     edi, 1
        add     eax, 1
        add     ebx, 1
        add     esi, 1
        add     edi, 1
        add     eax, 1
        add     ebx, 1
        add     esi, 1
        add     edi, 1
        dec     ecx             ; dec + jnz pair (flags forwarded to the V pipe)
        jnz     .loop
        hlt                     ; eax=ebx=esi=edi=2000 (0x7D0), ecx=0
