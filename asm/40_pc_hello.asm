; Test 40 (PC): MEMORY-MAPPED video. The VGA text screen is just memory at
; 0xB8000: every cell is 2 bytes (character, attribute), so ordinary MOV
; instructions draw on the screen -- no IN/OUT involved. The hardware cursor,
; on the other hand, lives in the CRT controller and is set through PORTS
; 0x3D4 (index) / 0x3D5 (data). Same device, both kinds of I/O.
;
;   cell (row, col) = 0xB8000 + 2*(80*row + col)
;   attribute byte  = background (bits 6:4) << 4 | foreground (bits 3:0)
;
; Expected: screen row 0 "Hello, world!" (white on blue), row 1 "OK" (green),
;   row 2 "Hi" (yellow) ; EBX=0xFFFFFFFF (nothing answers at 0x200000) ;
;   mem 0x800 = 48 1F 65 1F (video RAM reads back) ; 0x804 = E9 ; cursor = 162
bits 32
VGA equ 0xB8000

    mov esp, 0xFF0
    mov al, 0x01
    out 0x80, al                ; POST code 01: "started" (a diagnostic card shows it)

    ; --- word stores: character + attribute in one 16-bit MOV ---
    mov esi, msg
    mov edi, VGA                ; row 0, column 0
    mov ah, 0x1F                ; attribute: bright white (F) on blue (1)
next:
    mov al, [esi]
    cmp al, 0
    je done
    mov [edi], ax               ; 66 89 07: AL -> char byte, AH -> attribute byte
    inc esi
    add edi, 2
    jmp next
done:
    ; --- byte stores: green "OK" at row 1 (offset 160) ---
    mov byte [VGA + 160], 'O'
    mov byte [VGA + 161], 0x0A  ; light green on black
    mov byte [VGA + 162], 'K'
    mov byte [VGA + 163], 0x0A
    ; --- one dword store fills two cells: yellow "Hi" at row 2 ---
    mov dword [VGA + 320], 0x0E690E48   ; 'H',0x0E,'i',0x0E (little-endian)

    ; --- video RAM is real memory: it reads back ---
    mov eax, [VGA]              ; 'H',1F,'e',1F -> 0x1F651F48
    mov [0x800], eax
    ; --- no device decodes 0x200000: the bus floats, reads all ones ---
    mov ebx, [0x200000]

    ; --- hardware cursor: CRTC registers 0x0E/0x0F = 80*2 + 2 = 162 ---
    mov edx, 0x3D4
    mov al, 0x0E                ; select "cursor location high"
    out dx, al
    inc edx                     ; 0x3D5
    mov al, 0
    out dx, al
    dec edx
    mov al, 0x0F                ; select "cursor location low"
    out dx, al
    inc edx
    mov al, 162
    out dx, al

    in al, 0xE9                 ; Bochs/QEMU debug port reads back 0xE9 ("I'm here")
    mov [0x804], al             ; A2: MOV moffs8, AL
    mov al, 'H'
    out 0xE9, al                ; ... and prints what is written to it
    mov al, 0xFF
    out 0x80, al                ; POST code FF: done
    cli
    hlt                         ; CLI ; HLT = stop for good

msg: db 'Hello, world!', 0
