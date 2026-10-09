; Test 41 (PC): POLLED keyboard. The CPU spins on the 8042 status port until a
; byte is waiting, then reads the SCAN CODE from the data port and turns it
; into ASCII itself -- the keyboard never sends ASCII.
;
;   port 0x64 (read)  status, bit 0 = OBF "output buffer full": a byte is waiting
;   port 0x60 (read)  the scan code (reading it clears OBF)
;   scan code set 1:  key press = make code, key release = make | 0x80
;
; Enter ends the program. Interrupts stay off (IF=0), so IRQ1 goes nowhere:
; the CPU burns every cycle in the polling loop (compare test 42).
; KEYS: hello\n
; Expected: screen row 0 "> hello" ; mem 0x800 = 05 (keys echoed)
bits 32
VGA equ 0xB8000

    mov esp, 0xFF0
    mov edi, VGA
    mov word [edi], 0x0F3E      ; '>' bright white
    mov word [edi+2], 0x0720    ; ' '
    add edi, 4

wait_key:
    in   al, 0x64               ; 8042 status
    test al, 1                  ; OBF?
    jz   wait_key               ; no: keep polling (this is the busy-wait)
    in   al, 0x60               ; scan code -- this read empties the buffer
    test al, 0x80               ; a key RELEASE?
    jnz  wait_key               ;   ignore it
    cmp  al, 0x1C               ; Enter
    je   finished
    cmp  al, 0x3A               ; outside our table?
    jae  wait_key
    mov  ebx, keymap
    xlat                        ; AL = keymap[AL]  (scan code -> ASCII)
    cmp  al, 0
    je   wait_key               ; a key with no character (Shift, Ctrl, ...)
    mov  ah, 0x07
    mov  [edi], ax              ; echo it
    add  edi, 2
    mov  eax, [count]
    inc  eax
    mov  [count], eax
    jmp  wait_key

finished:
    mov eax, [count]
    mov [0x800], eax
    cli
    hlt

count: dd 0
; Scan code set 1 -> ASCII (US layout, no Shift). Index = make code 0x00..0x39.
keymap:
    db 0, 27, '1234567890-=', 8, 9          ; 00-0F
    db 'qwertyuiop[]', 13, 0                ; 10-1D  (1D = Ctrl)
    db "asdfghjkl;'`", 0, '\'               ; 1E-2B  (2A = LShift)
    db 'zxcvbnm,./', 0, '*', 0, ' '         ; 2C-39  (36 RShift, 38 Alt, 39 Space)
