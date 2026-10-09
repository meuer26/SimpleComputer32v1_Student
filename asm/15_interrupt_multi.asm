; Test 15: multiple IVT vectors; INT 0/2/1 dispatched out of order.
; Expected: EAX=0xBBBB ESP=0xF0 IVT=0x140 I=0
;           mem 0x100=AA AA ; 0x104=CC CC ; 0x108=BB BB
;           0x140=80 01 ; 0x144=90 01 ; 0x148=A0 01
bits 32
    lidt [idt_ptr]
    mov esp, 0xF0
    int 0
    mov [0x100], eax
    int 2
    mov [0x104], eax
    int 1
    mov [0x108], eax
    hlt
    align 4
idt_ptr:
    dw 0x03FF
    dd ivt
    times 0x140-($-$$) db 0
ivt:
    dd handler0, handler1, handler2
    times 0x180-($-$$) db 0
handler0:
    mov eax, 0x0000AAAA
    iret
    times 0x190-($-$$) db 0
handler1:
    mov eax, 0x0000BBBB
    iret
    times 0x1A0-($-$$) db 0
handler2:
    mov eax, 0x0000CCCC
    iret
