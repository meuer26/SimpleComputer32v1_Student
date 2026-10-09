; Test 30: port I/O widths. Real PC devices are mostly 8-bit (keyboard, PIC,
; CRTC) and the ATA data port is 16-bit, so IN/OUT come in byte, word and dword
; forms. IN AL / IN AX replace only the low byte / word of EAX.
;   E6/E4 = OUT/IN imm8, AL      EE/EC = OUT/IN DX, AL
;   66 EF / 66 ED = OUT/IN DX, AX
; Expected: EAX=0x5A ; mem 0x100=41 56 34 12 ; 0x104=EF BE 11 11 ; 0x108=5A 00 00 00
bits 32
    mov eax, 0xFFFFFF41
    out 0x40, al              ; E6 ib     byte to port 0x40
    mov eax, 0x12345678
    in  al, 0x40              ; E4 ib     AL = 0x41, EAX = 0x12345641
    mov [0x100], eax

    mov edx, 0x50
    mov eax, 0xAAAABEEF
    out dx, ax                ; 66 EF     word to port 0x50
    mov eax, 0x11111111
    in  ax, dx                ; 66 ED     AX = 0xBEEF, EAX = 0x1111BEEF
    mov [0x104], eax

    mov al, 0x5A
    out dx, al                ; EE
    mov eax, 0
    in  al, dx                ; EC        EAX = 0x5A
    mov [0x108], eax
    hlt
