; Test 45 (PC): #UD, the invalid-opcode FAULT (vector 6).
;
; UD2 (0F 0B) is the instruction Intel defines to be invalid. Executing it --
; or any opcode this CPU does not implement -- raises #UD. It is a FAULT, so the
; EIP pushed is the address of the offending instruction itself (an IRET would
; simply run it again). The handler here reports it on the screen and then
; "emulates" it by moving the saved EIP past the 2-byte instruction, so the
; program carries on -- exactly what an OS does when it emulates a missing
; instruction.
;
; Expected: row 0 "Executing UD2 ..." ; row 1 "#UD at EIP=0x0000001B"
;   row 2 "Resumed after the #UD handler." ; mem 0x800 = 1B 00 00 00
bits 32
VGA equ 0xB8000

    mov esp, 0xFF0
    lidt [idt_ptr]
    mov edi, VGA
    mov esi, s_before
    call print
    ud2                         ; 0F 0B -> #UD
    mov edi, VGA + 320
    mov esi, s_after
    call print
    cli
    hlt

ud_handler:                     ; stack: EIP, CS, EFLAGS (+ PUSHAD below them)
    pushad
    mov ebp, esp
    mov eax, [ebp + 32]         ; saved EIP = address of the UD2
    mov [0x800], eax
    mov edi, VGA + 160
    mov esi, s_ud
    call print
    mov eax, [0x800]
    call print_hex
    mov eax, [ebp + 32]
    add eax, 2                  ; skip the 2-byte UD2
    mov [ebp + 32], eax
    popad
    iret

ignore_int:
    iret

print_hex:                      ; EAX as 8 hex digits at EDI
    mov ecx, 8
.digit:
    rol eax, 1                  ; bring the top nibble down
    rol eax, 1
    rol eax, 1
    rol eax, 1
    push eax
    and eax, 0x0F
    mov ebx, hexdig
    xlat
    call putch
    pop eax
    dec ecx
    jnz .digit
    ret

print:
    mov al, [esi]
    cmp al, 0
    je .done
    call putch
    inc esi
    jmp print
.done:
    ret

putch:
    mov ah, 0x07
    mov [edi], ax
    add edi, 2
    ret

s_before: db 'Executing UD2 (0F 0B), an invalid opcode...', 0
s_ud:     db '#UD at EIP=0x', 0
s_after:  db 'Resumed after the #UD handler.', 0
hexdig:   db '0123456789ABCDEF'
    align 4
ivt:
    times 6 dd ignore_int
    dd ud_handler               ; vector 6 = #UD
    dd ignore_int
idt_ptr:
    dw 8 * 4 - 1
    dd ivt
