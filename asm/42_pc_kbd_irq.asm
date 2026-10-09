; Test 42 (PC): INTERRUPT-DRIVEN keyboard -- a tiny kernel, and the program
; `make pc` runs interactively.
;
; The path of one key press:
;   1. the keyboard sends a scan code; the 8042 latches it, sets OBF and raises IRQ1
;   2. the master 8259 latches IRQ1 in its IRR and, since IRQ1 is unmasked,
;      raises INTR
;   3. the CPU finishes its instruction (or wakes from HLT), sees IF=1 and runs
;      an interrupt-acknowledge (INTA) cycle; the 8259 moves IRQ1 to its ISR and
;      answers with vector 0x21 (the base 0x20 we program below + IRQ 1)
;   4. the CPU pushes EFLAGS, CS, EIP, clears IF and jumps to ivt[0x21] = kbd_isr
;   5. kbd_isr reads port 0x60 (that clears OBF and drops IRQ1), translates
;      the scan code, queues the character, and sends EOI (OUT 0x20, 0x20) so the
;      8259 will deliver the next IRQ1
;   6. IRET pops EIP, CS, EFLAGS -- IF is 1 again -- and the interrupted code
;      continues as if nothing happened
;
; The main loop sleeps in HLT while there is nothing to do. It checks the queue
; with interrupts OFF and then executes "STI ; HLT": the STI takes effect only
; after the HLT has started, so a key arriving in between cannot be missed.
;
; Why remap the 8259? The BIOS default puts IRQ0-7 at vectors 8-15, which are
; also CPU exceptions (#UD = 6 is close, #PF = 14 collides with IRQ6). A
; protected-mode OS therefore moves the IRQs to 0x20-0x2F.
;
; KEYS: Hi there!\n
; Expected: row 0 banner ; row 1 "> Hi there!" ; row 2 "> "
bits 32
VGA      equ 0xB8000
ATTR     equ 0x07                ; light grey on black
PIC1_CMD equ 0x20
PIC1_DAT equ 0x21
PIC2_CMD equ 0xA0
PIC2_DAT equ 0xA1
KBD_DATA equ 0x60
QMASK    equ 15                  ; 16-byte ring buffer

start:
    mov esp, 0xFF0
    lidt [idt_ptr]
    mov al, 0x01
    out 0x80, al                 ; POST 01

    ; ---- program both 8259s: IRQ0-7 -> 0x20-0x27, IRQ8-15 -> 0x28-0x2F ----
    mov al, 0x11                 ; ICW1: initialise, cascade mode, ICW4 follows
    out PIC1_CMD, al
    out PIC2_CMD, al
    mov al, 0x20                 ; ICW2: master vector base
    out PIC1_DAT, al
    mov al, 0x28                 ; ICW2: slave vector base
    out PIC2_DAT, al
    mov al, 0x04                 ; ICW3: master has a slave on IR2
    out PIC1_DAT, al
    mov al, 0x02                 ; ICW3: slave's cascade identity is 2
    out PIC2_DAT, al
    mov al, 0x01                 ; ICW4: 8086 mode
    out PIC1_DAT, al
    out PIC2_DAT, al
    mov al, 0xFD                 ; OCW1: unmask IRQ1 (keyboard) only
    out PIC1_DAT, al
    mov al, 0xFF                 ;       slave: everything masked
    out PIC2_DAT, al
    mov al, 0x02
    out 0x80, al                 ; POST 02: PICs programmed

    mov esi, banner
    call puts
    mov al, 13
    call putc
    mov esi, prompt
    call puts
    call set_cursor
    sti                          ; from here on IRQ1 is delivered

main_loop:
    cli                          ; inspect the queue atomically
    mov eax, [q_head]
    mov ebx, [q_tail]
    cmp eax, ebx
    jne have_char
    sti                          ; nothing queued: sleep until the next interrupt
    hlt                          ; (STI's one-instruction delay makes this race-free)
    jmp main_loop
have_char:
    mov al, [ebx + q_buf]        ; consume at the tail
    inc ebx
    and ebx, QMASK
    mov [q_tail], ebx
    sti
    cmp al, 13
    jne .plain
    call putc                    ; Enter: new line, then a fresh prompt
    mov esi, prompt
    call puts
    jmp .shown
.plain:
    call putc
.shown:
    call set_cursor
    jmp main_loop

; ------------------------------------------------------------------------------
; IRQ1 handler (vector 0x21). Producer: scan code -> ASCII -> queue.
; ------------------------------------------------------------------------------
kbd_isr:
    pushad
    in   al, KBD_DATA            ; the scan code; this also clears OBF / IRQ1
    cmp  al, 0x2A                ; Left Shift pressed
    je   .shift_on
    cmp  al, 0x36                ; Right Shift pressed
    je   .shift_on
    cmp  al, 0xAA                ; Left Shift released
    je   .shift_off
    cmp  al, 0xB6                ; Right Shift released
    je   .shift_off
    test al, 0x80                ; any other release: nothing to do
    jnz  .eoi
    cmp  al, 0x3A
    jae  .eoi                    ; keys beyond our table (F-keys, ...)
    mov  ebx, keymap
    mov  ecx, [shift]
    test ecx, ecx
    jz   .xlat
    mov  ebx, shiftmap
.xlat:
    xlat                         ; AL = table[scan code]
    cmp  al, 0
    je   .eoi
    mov  ebx, [q_head]           ; enqueue at the head (drop if full)
    mov  ecx, ebx
    inc  ecx
    and  ecx, QMASK
    mov  edx, [q_tail]
    cmp  ecx, edx
    je   .eoi
    mov  [ebx + q_buf], al
    mov  [q_head], ecx
    jmp  .eoi
.shift_on:
    mov  dword [shift], 1
    jmp  .eoi
.shift_off:
    mov  dword [shift], 0
.eoi:
    mov  al, 0x20                ; OCW2: non-specific End Of Interrupt
    out  PIC1_CMD, al
    popad
    iret

ignore_int:                      ; every other vector (incl. spurious IRQ7)
    iret

; ------------------------------------------------------------------------------
; Text output: a teletype on the 80x25 screen. pos = cell index, col = column.
; ------------------------------------------------------------------------------
putc:                            ; AL = character (13 = Enter, 8 = Backspace)
    cmp al, 13
    je  newline
    cmp al, 8
    je  backspace
    mov edi, [pos]
    add edi, edi
    add edi, VGA                 ; cell address = 0xB8000 + 2*pos
    mov ah, ATTR
    mov [edi], ax
    mov eax, [pos]
    inc eax
    mov [pos], eax
    mov eax, [col]
    inc eax
    cmp eax, 80
    jne .same_line
    mov eax, 0
.same_line:
    mov [col], eax
    jmp check_scroll
newline:
    mov eax, [pos]
    add eax, 80
    mov ebx, [col]
    sub eax, ebx                 ; start of the next row
    mov [pos], eax
    mov dword [col], 0
check_scroll:
    mov eax, [pos]
    cmp eax, 2000
    jb  .ok
    call scroll
    mov eax, [pos]
    sub eax, 80
    mov [pos], eax
.ok:
    ret
backspace:
    mov eax, [col]
    cmp eax, 2                   ; keep the "> " prompt
    jbe .done
    dec eax
    mov [col], eax
    mov eax, [pos]
    dec eax
    mov [pos], eax
    mov edi, eax
    add edi, edi
    add edi, VGA
    mov word [edi], 0x0720       ; blank the cell
.done:
    ret

scroll:                          ; move rows 1..24 up one row, blank row 24
    mov esi, VGA + 160
    mov edi, VGA
    mov ecx, 24 * 160 / 4
.copy:
    mov eax, [esi]
    mov [edi], eax
    add esi, 4
    add edi, 4
    dec ecx
    jnz .copy
    mov ecx, 160 / 4
.blank:
    mov dword [edi], 0x07200720
    add edi, 4
    dec ecx
    jnz .blank
    ret

puts:                            ; ESI = zero-terminated string
    mov al, [esi]
    cmp al, 0
    je  .done
    push esi
    call putc
    pop esi
    inc esi
    jmp puts
.done:
    ret

set_cursor:                      ; hardware cursor := pos (CRTC regs 0x0F / 0x0E)
    mov ebx, [pos]
    mov edx, 0x3D4
    mov al, 0x0F
    out dx, al
    inc edx
    mov al, bl
    out dx, al
    dec edx
    mov al, 0x0E
    out dx, al
    inc edx
    mov al, bh
    out dx, al
    ret

; ------------------------------------------------------------------------------
; Data
; ------------------------------------------------------------------------------
banner: db 'Simple Computer 32 v1', 0
prompt: db '> ', 0

    align 4
pos:    dd 0
col:    dd 0
shift:  dd 0
q_head: dd 0
q_tail: dd 0
q_buf:  times 16 db 0

; Scan code set 1 -> ASCII (US layout). Index = make code 0x00..0x39.
keymap:
    db 0, 27, '1234567890-=', 8, 9
    db 'qwertyuiop[]', 13, 0
    db "asdfghjkl;'`", 0, '\'
    db 'zxcvbnm,./', 0, '*', 0, ' '
shiftmap:
    db 0, 27, '!@#$%^&*()_+', 8, 9
    db 'QWERTYUIOP{}', 13, 0
    db 'ASDFGHJKL:"~', 0, '|'
    db 'ZXCVBNM<>?', 0, '*', 0, ' '

; Vector table (4-byte handler addresses), vectors 0x00..0x2F.
    align 4
ivt:
    times 0x21 dd ignore_int
    dd kbd_isr                   ; 0x21 = IRQ1 keyboard
    times 0x30 - 0x22 dd ignore_int
idt_ptr:
    dw 0x30 * 4 - 1
    dd ivt
