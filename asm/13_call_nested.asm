; Test 13: cdecl with MULTIPLE arguments and a NESTED call.
;   int times4(int x)        { return x << 2; }
;   int combine(int a,int b) { return times4(a + b) + 1; }
; Args pushed right-to-left; a -> [ebp+8], b -> [ebp+12]; result in EAX.
;   combine(5, 0x10) = ((5 + 0x10) * 4) + 1 = 0x55
; Expected: EAX=0x55 ESP=0xF0 ; mem[0x100]=55
bits 32
    mov esp, 0xF0
    push 0x10                 ; b  (ends up at [ebp+12])
    push 5                    ; a  (ends up at [ebp+8])
    call combine
    add esp, 8                ; pop both arguments
    mov [0x100], eax
    hlt
    times 0x80-($-$$) db 0
combine:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]          ; a
    mov edx, [ebp+12]         ; b
    add eax, edx              ; a + b
    push eax                  ; argument to times4()
    call times4               ; (a + b) * 4
    add esp, 4
    add eax, 1
    mov esp, ebp
    pop ebp
    ret
    times 0xC0-($-$$) db 0
times4:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]
    shl eax, 1
    shl eax, 1
    mov esp, ebp
    pop ebp
    ret
