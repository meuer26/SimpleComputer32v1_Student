; Test 14: single INT through a relocatable IVT, with IRET.
;   LIDT loads the IDT base from a real 6-byte pseudo-descriptor.
;   The vector table holds 4-byte handler offsets; INT 0 -> handler.
; Expected: EAX=0x22222222 ESP=0xF0 I=0 IVT=0x150
;           mem 0x100=EF BE AD DE ; 0x104=22 22 22 22 ; 0x150=80 01 00 00
bits 32
    lidt [idt_ptr]
    mov esp, 0xF0
    mov eax, 0x11111111
    int 0
    mov [0x100], eax
    mov eax, 0x22222222
    mov [0x104], eax
    hlt
    align 4
idt_ptr:
    dw 0x03FF
    dd ivt
    times 0x150-($-$$) db 0
ivt:
    dd handler
    times 0x180-($-$$) db 0
handler:
    mov eax, 0xDEADBEEF
    iret
