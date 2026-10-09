; Test 31: the real x86 interrupt frame, EFLAGS on the stack, PUSHAD/POPAD.
;   INT n pushes EFLAGS, CS, EIP (12 bytes) and clears IF; IRET pops all three,
;   so flags the handler changes (CLC below) do NOT leak into the interrupted
;   code. PUSHFD/POPFD, STI/CLI and PUSHAD/POPAD round it out.
; Expected: EAX=0x203 ECX=2 EBX=4 ESP=0xF0 C=1 I=0
;   mem 0x100 = return EIP (ret_here) ; 0x104 = 08 00 00 00 (CS)
;   0x108 = 03 00 00 00 (EFLAGS at INT: CF=1, bit1=1, IF=0)
;   0x10C = 03 00 00 00 (CF restored by IRET)
;   0x110 = 03 02 00 00 (after STI: IF=1)
;   0xDC  = F0 00 00 00 (PUSHAD saved the ORIGINAL ESP) ; 0xE8 = 02 00 00 00 (ECX)
bits 32
    lidt [idt_ptr]
    mov esp, 0xF0
    stc                       ; CF=1 going into the interrupt
    int 1
ret_here:
    pushfd
    pop eax                   ; EFLAGS after IRET
    mov [0x10C], eax

    mov eax, 1
    mov ecx, 2
    mov edx, 3
    mov ebx, 4
    mov ebp, 6
    mov esi, 7
    mov edi, 8
    pushad                    ; 60: EAX ECX EDX EBX ESP EBP ESI EDI
    mov eax, 0
    mov ecx, 0
    mov ebx, 0
    popad                     ; 61: all restored (ESP slot skipped)

    sti                       ; FB
    pushfd                    ; 9C
    pop eax                   ; EAX = 0x203
    mov [0x110], eax
    cli                       ; FA
    hlt

    align 4
idt_ptr:
    dw 0x03FF
    dd ivt
    times 0x140-($-$$) db 0
ivt:
    dd 0, handler1
    times 0x180-($-$$) db 0
handler1:
    clc                       ; changes CF only inside the handler
    mov ebp, esp
    mov eax, [ebp]            ; frame: [ESP] = EIP
    mov [0x100], eax
    mov eax, [ebp+4]          ;        [ESP+4] = CS
    mov [0x104], eax
    mov eax, [ebp+8]          ;        [ESP+8] = EFLAGS
    mov [0x108], eax
    iret
