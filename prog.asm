; ============================================================================
; Sandbox program  --  edit this freely and run:   make prog
;
; This is NOT part of the numbered regression suite in asm/. It exists purely
; for poking at the CPU. When you run it, Surfer opens with the waveform rows
; auto-selected for whatever instructions you used here (scripts/surfer_rows.py
; inspects the disassembly): use the stack and you get ESP, touch [mem] and you
; get the memory bus, use IN/OUT and you get the I/O rows, and so on.
;
; The example below exercises registers + flags + stack + memory so you can see
; several row groups appear. Replace it with whatever you want to test.
; ============================================================================
bits 32

    mov eax, 0x11223344     ; immediate load            -> EAX
    mov ebx, eax            ; reg-reg move              -> EBX
    add eax, ebx            ; arithmetic (sets flags)   -> flags row
    sub eax, 0x100          ; more flags

    push eax                ; stack push                -> ESP / memory bus
    mov ecx, 7              ;                           -> ECX
    pop edx                 ; stack pop                 -> EDX

    mov [0x200], eax        ; store to memory           -> memory bus
    mov esi, [0x200]        ; load from memory          -> ESI

    hlt
