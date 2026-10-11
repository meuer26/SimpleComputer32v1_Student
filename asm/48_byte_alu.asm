; 48_byte_alu.asm -- the 8-bit r/m ALU family: store-direction (00/08/.../38)
; and load-direction (02/.../3A) ADD..CMP, the grp1 byte immediate form (80 /r),
; TEST r/m8,r8 (84), on both register and memory operands.  gcc emits these for
; char arithmetic and byte-wide conditions.  Every result converges on 0x3F.
bits 32
        ; --- store-direction ADD r/m8, r8 (00), register operands ---
        mov     eax, 0x15
        mov     ebx, 0x2A
        add     al, bl                  ; 00: AL = 0x3F   -> EAX = 0x3F

        ; --- load-direction ADD r8, r/m8 (02), memory source ---
        mov     dword [0x100], 0x30
        mov     ebx, 0x0F
        add     bl, [0x100]             ; 02: BL = 0x0F + 0x30 = 0x3F  -> EBX = 0x3F

        ; --- grp1 byte immediate (80 /4 AND, /1 OR) ---
        mov     ecx, 0xF3
        and     cl, 0x3C                ; 80 /4: 0x30
        or      cl, 0x0F                ; 80 /1: 0x3F  -> ECX = 0x3F

        ; --- memory read-modify-write ADD [m8], r8 (00 mem), then load back ---
        mov     byte [0x104], 0x20
        mov     dl, 0x1F
        add     [0x104], dl             ; 00 mem: [0x104] = 0x3F
        mov     dl, [0x104]             ; DL = 0x3F  -> EDX = 0x3F

        ; --- byte CMP (38) + SETcc on memory, byte TEST (84) + SETcc ---
        mov     al, 0x3F
        mov     bl, 0x3F
        cmp     al, bl                  ; 38: equal -> ZF = 1
        mov     byte [0x108], 0
        sete    byte [0x108]            ; [0x108] = 1
        test    al, bl                  ; 84: 0x3F & 0x3F = 0x3F -> ZF = 0
        mov     byte [0x10C], 0
        setne   byte [0x10C]            ; [0x10C] = 1
        hlt
