; 47_grp3_misc.asm -- the grp3 unit (MUL/IMUL/DIV/IDIV/NEG/NOT/TEST), the
; sign/zero extends (MOVSX/MOVZX), SETcc, and CDQ. These are what gcc emits for
; multiplication, division (incl. signed, with CDQ first), boolean results, and
; promoting char/short to int. Results land in registers and memory.
bits 32
        mov     eax, 7
        mov     ebx, 6
        mul     ebx                 ; unsigned 7*6 -> EDX:EAX = 42
        mov     [0x100], eax        ; mem[0x100] = 42

        mov     eax, 100
        xor     edx, edx
        mov     ebx, 7
        div     ebx                 ; 100 / 7 -> EAX = 14, EDX = 2
        mov     [0x104], eax        ; 14
        mov     [0x108], edx        ; 2

        mov     eax, 5
        neg     eax                 ; -5
        mov     [0x10C], eax        ; 0xFFFFFFFB

        mov     ecx, 0xF0
        movsx   ebx, cl             ; sign-extend 0xF0 -> EBX = 0xFFFFFFF0

        mov     eax, 10
        cmp     eax, 10
        mov     ecx, 0
        sete    cl                  ; equal -> ECX = 1

        mov     eax, -20
        cdq                         ; sign-extend into EDX:EAX
        mov     esi, 3
        idiv    esi                 ; -20 / 3 -> EAX = -6, EDX = -2
        hlt
