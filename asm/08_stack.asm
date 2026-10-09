; Test 08: stack LIFO via PUSH/POP (50+r / 58+r).
; Expected: EAX=0x11111111 ESP=0xE0 ; mem 0x100=33.. 0x104=22.. 0x108=11..
bits 32
    mov esp, 0xE0
    mov eax, 0x11111111
    push eax
    mov eax, 0x22222222
    push eax
    mov eax, 0x33333333
    push eax
    mov eax, 0
    pop eax
    mov [0x100], eax
    pop eax
    mov [0x104], eax
    pop eax
    mov [0x108], eax
    hlt
