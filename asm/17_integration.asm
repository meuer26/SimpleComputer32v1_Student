; Test 17: integration -- exercises most instruction classes.
; Builds EAX = 0x42 -> 0x4242 -> 0x42420000 -> 0x42424242.
; The 0x42420000 step calls shift_left_16() using the cdecl convention.
; Expected: EAX=0x42424242 EBX=5 ECX=0xD ESP=0xF0 ; Z=0 C=0 I=0 IVT=0x140
;   mem 0x100=AA ; 0x140=C0 01 ; 0x150=42 ; 0x160=42 42 ; 0x164=42 42
;       0x168=00 00 42 42 ; 0x1F0=42 42 42 42
bits 32
    lidt [idt_ptr]
    mov esp, 0xF0

    mov eax, 0x40
    inc eax
    inc eax
    dec eax
    inc eax                 ; EAX = 0x42
    mov ebx, eax
    mov ecx, eax
    mov eax, 0
    mov eax, ebx
    mov [0x150], eax        ; save 0x42
    mov eax, ecx

    mov ebx, 5
    mov ecx, 3
    inc ebx
    inc ebx
    dec ebx                 ; EBX = 6
    inc ecx
    dec ecx
    inc ecx                 ; ECX = 4

    mov eax, 0x10
    add eax, 5
    sub eax, 3              ; EAX = 0x12
    mov ebx, eax
    add ebx, 0x20           ; ADDB EBX = 0x32 (overwritten later)
    mov ecx, eax
    sub ecx, 5              ; SUBC ECX = 0xD

    mov eax, 0xFFFFFFFF
    clc
    add eax, 1             ; carry
    jc jc_ok
    hlt
jc_ok:
    mov eax, 0xAA
    mov [0x100], eax

    mov eax, [0x150]        ; 0x42
    shl eax, 1
    shl eax, 1
    shl eax, 1
    shl eax, 1
    shl eax, 1
    shl eax, 1
    shl eax, 1
    shl eax, 1
    add eax, 0x42          ; 0x4242
    mov [0x160], eax

    rol eax, 1
    ror eax, 1             ; back to 0x4242

    push eax
    mov eax, 0xDEADBEEF
    pop eax               ; 0x4242

    mov ebx, 0
    mov [0x164], eax
    mov eax, 5
loop_acc:
    inc ebx
    dec eax
    jne loop_acc          ; EBX = 5
    mov eax, [0x164]      ; 0x4242

    push eax              ; cdecl arg
    call shift_left_16    ; 0x42420000
    add esp, 4
    mov [0x168], eax

    int 0                 ; handler: ADD EAX,0x4242 -> 0x42424242
    mov [0x1F0], eax

    hlt

    align 4
idt_ptr:
    dw 0x03FF
    dd ivt
    times 0x140-($-$$) db 0
ivt:
    dd handler
    times 0x180-($-$$) db 0
shift_left_16:             ; int shift_left_16(int x) { return x << 16; }
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    shl eax,1
    mov esp, ebp
    pop ebp
    ret
    times 0x1C0-($-$$) db 0
handler:
    add eax, 0x4242
    iret
