; Test 09: ESP arithmetic via INC ESP / DEC ESP around a PUSH/POP.
; Expected: EAX=0xDEADBEEF ESP=0xF0 ; mem[0x100]=EF BE AD DE ; mem[0xEC]=EF BE AD DE
bits 32
    mov esp, 0xF0
    mov eax, 0xDEADBEEF
    push eax
    inc esp
    inc esp
    inc esp
    inc esp
    dec esp
    dec esp
    dec esp
    dec esp
    mov eax, 0
    pop eax
    mov [0x100], eax
    hlt
