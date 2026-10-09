; Test 21: x86 port I/O. The I/O space is SEPARATE from memory (the M/IO#
; distinction) and is reached only by IN/OUT -- it is not cached.
;   OUT writes a device port; IN reads it back.
;   imm8-addressed forms (E7/E5) and DX-addressed forms (EF/ED) are shown,
;   plus a write to the debug "console" port 0xE9.
; Expected: EAX=0xC0DE ; mem 0x100=78 56 34 12 ; mem 0x104=EF BE AD DE
bits 32
    mov eax, 0x12345678
    out 0x10, eax          ; OUT port 0x10, EAX   (imm8 port)
    mov eax, 0             ; clobber to prove IN really reads the device
    in  eax, 0x10          ; IN  EAX, port 0x10   -> 0x12345678
    mov [0x100], eax

    mov edx, 0x20
    mov eax, 0xDEADBEEF
    out dx, eax            ; OUT port [DX], EAX    (DX-addressed)
    mov eax, 0
    in  eax, dx            ; IN  EAX, port [DX]    -> 0xDEADBEEF
    mov [0x104], eax

    mov eax, 0x0000C0DE
    out 0xE9, eax          ; debug console port
    hlt
