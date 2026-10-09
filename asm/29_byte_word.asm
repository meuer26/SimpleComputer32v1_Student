; Test 29: byte and word data -- the 8/16-bit forms that device drivers and
; text-mode video need. The 32-bit bus carries them with byte enables (BE3..0),
; so a byte store only changes the one byte it names.
; Expected: EAX=0x30 ECX=0xDD Z=1
;   mem 0x100=55 66 22 11 ; 0x104=DD 99 77 AA ; 0x108=00 00 34 12
;   0x10C=EF BE 00 00 ; 0x110=AA 00 00 00 ; 0x114=30 00 00 00
;   0x118=00 11 22 33 44 00 00 00 (misaligned dword) ; 0x120=11 22 33 44
bits 32
    mov eax, 0x11223344
    mov al, 0x55              ; B0 ib        EAX = 0x11223355 (upper bytes kept)
    mov ah, 0x66              ; B4 ib        EAX = 0x11226655
    mov [0x100], eax
    mov ebx, 0xAABBCCDD
    mov [0x104], ebx
    mov byte [0x105], 0x99    ; C6 /0 ib     mem 0x104 = DD 99 BB AA
    mov cl, 0x77
    mov [0x106], cl           ; 88 /r        mem 0x104 = DD 99 77 AA
    mov dword [0x108], 0      ; C7 /0 id
    mov dx, 0x1234            ; 66 BA iw     DX = 0x1234
    mov [0x10A], dx           ; 66 89 /r     mem 0x108 = 00 00 34 12
    mov word [0x10C], 0xBEEF  ; 66 C7 /0 iw  mem 0x10C = EF BE
    mov dl, [0x104]           ; 8A /r        DL = 0xDD
    movzx ecx, dl             ; 0F B6 (reg)  ECX = 0x000000DD
    movzx esi, byte [0x107]   ; 0F B6 (mem)  ESI = 0x000000AA
    mov [0x110], esi
    mov ebx, table
    mov eax, 2
    xlat                      ; D7           AL = [EBX+AL] = table[2] = 0x3C
    and al, 0xF0              ; 24 ib        AL = 0x30
    mov [0x114], eax
    mov dword [0x119], 0x44332211 ; misaligned: straddles the dwords at 0x118 and 0x11C,
    mov edx, [0x119]              ; so the CPU makes two bus cycles (like a 386)
    mov [0x120], edx
    test al, 0x10             ; A8 ib        bit 4 set -> ZF=0
    jz fail
    cmp al, 0x30              ; 3C ib        equal -> ZF=1
    jne fail
    hlt
fail:
    mov eax, 0xBAD
    hlt
table:
    db 0x0A, 0x1B, 0x3C, 0x4D
