; Test 12: CALL/RET with the System V i386 (cdecl) calling convention.
;   int double_a(int x) { return x << 1; }
; Argument passed on the stack, return value in EAX, caller cleans the stack.
; Expected: EAX=0x22 ESP=0xF0 ; mem 0x100=42.. 0x104=22..
bits 32
    mov esp, 0xF0
    push 0x21                 ; argument
    call double_a             ; EAX = 0x42
    add esp, 4                ; caller pops the argument (cdecl)
    mov [0x100], eax
    push 0x11
    call double_a             ; EAX = 0x22
    add esp, 4
    mov [0x104], eax
    hlt
    times 0x80-($-$$) db 0
double_a:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]          ; first argument
    shl eax, 1
    mov esp, ebp
    pop ebp
    ret
