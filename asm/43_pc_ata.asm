; Test 43 (PC): a POLLED ATA (IDE) disk driver, LBA addressing, PIO transfers.
;
; The drive is programmed through its task-file PORTS and the data is moved
; 16 bits at a time through the data port 0x1F0 (IN AX, DX / OUT DX, AX):
;   0x1F2 sector count   0x1F3/4/5 LBA bits 0-7 / 8-15 / 16-23
;   0x1F6 0xE0 | LBA[27:24]  (bit 6 = LBA mode, bit 4 = 0 master)
;   0x1F7 command (0x20 read, 0x30 write, 0xEC identify, 0xE7 flush) / status
;   status bits: BSY 0x80 (busy: touch nothing else), DRQ 0x08 (data ready to
;   move), ERR 0x01 (look at the error register 0x1F1)
; nIEN = 1 in the device-control register (0x3F6) turns the drive's interrupt
; off, so this driver polls the status register instead (compare test 44).
;
; The drive only speaks LBA: a command sent in CHS mode (bit 6 clear) is
; aborted (status ERR, error register ABRT = 0x04).
;
; Expected: row 0 "IDENTIFY: SimpleComputer32 Teaching Disk"
;   row 1 = sector 0 text ; row 2 = sector 1 text written by this program
;   mem 0x800 = 51 04 (CHS command aborted: status ERR, error ABRT)
;   disk sector 1 (offset 0x200) = "Sector 1: written by the CPU..."
bits 32
VGA      equ 0xB8000
ATA_DATA equ 0x1F0
ATA_ERR  equ 0x1F1
ATA_CNT  equ 0x1F2
ATA_LBA0 equ 0x1F3
ATA_DRV  equ 0x1F6
ATA_CMD  equ 0x1F7              ; command (write) / status (read)
ATA_CTL  equ 0x3F6              ; device control (write) / alternate status (read)
BUF      equ 0xC00              ; 512-byte sector buffer in RAM

    mov esp, 0xFF0
    mov edx, ATA_CTL
    mov al, 0x02                ; nIEN = 1: no interrupts, we poll
    out dx, al

    ; ---------------- IDENTIFY DEVICE ----------------
    call wait_not_busy
    mov edx, ATA_DRV
    mov al, 0xE0                ; master, LBA mode
    out dx, al
    mov edx, ATA_CMD
    mov al, 0xEC                ; IDENTIFY
    out dx, al
    call delay400
    call wait_drq
    call read_sector            ; 256 words -> BUF
    mov edi, VGA
    mov esi, s_ident
    call print
    ; The model name is words 27..46. ATA strings keep the FIRST character in
    ; the HIGH byte of each word, so print byte 1 then byte 0 of every word.
    mov esi, BUF + 27 * 2
    mov ecx, 20
model:
    mov al, [esi + 1]
    call putch
    mov al, [esi]
    call putch
    add esi, 2
    dec ecx
    jnz model

    ; ---------------- READ SECTORS: LBA 0 ----------------
    mov ebx, 0
    mov al, 0x20
    call ata_command
    call wait_drq
    call read_sector
    mov edi, VGA + 160
    mov esi, BUF
    call print

    ; ---------------- WRITE SECTORS: LBA 1 ----------------
    mov ebx, 1
    mov al, 0x30
    call ata_command
    call wait_drq               ; the drive asks for the data
    mov esi, wbuf
    mov ecx, 256
    mov edx, ATA_DATA
write_word:
    mov ax, [esi]
    out dx, ax                  ; 66 EF: one 16-bit word to the drive
    add esi, 2
    dec ecx
    jnz write_word
    call wait_not_busy          ; BSY while the sector is written
    mov edx, ATA_CMD
    mov al, 0xE7                ; FLUSH CACHE
    out dx, al
    call delay400
    call wait_not_busy

    ; ---------------- read LBA 1 back ----------------
    mov ebx, 1
    mov al, 0x20
    call ata_command
    call wait_drq
    call read_sector
    mov edi, VGA + 320
    mov esi, BUF
    call print

    ; ---------------- CHS mode is not supported ----------------
    call wait_not_busy
    mov edx, ATA_DRV
    mov al, 0xA0                ; master, bit 6 = 0: CHS addressing
    out dx, al
    mov edx, ATA_CMD
    mov al, 0x20
    out dx, al
    call delay400
    call wait_not_busy
    in al, dx                   ; status: ERR set
    mov [0x800], al
    mov edx, ATA_ERR
    in al, dx                   ; error register: ABRT
    mov [0x801], al

    mov al, 0xFF
    out 0x80, al
    cli
    hlt

; ---------------------------------------------------------------- routines
ata_command:                    ; EBX = LBA, AL = command; 1 sector
    push eax
    call wait_not_busy
    mov [lba], ebx              ; split the LBA into its four bytes
    mov edx, ATA_DRV
    mov al, [lba + 3]
    and al, 0x0F
    or  al, 0xE0                ; 1 L=1 1 DEV=0 LBA[27:24]
    out dx, al
    mov edx, ATA_CNT
    mov al, 1
    out dx, al                  ; sector count
    inc edx
    mov al, [lba]
    out dx, al                  ; 0x1F3 LBA 7:0
    inc edx
    mov al, [lba + 1]
    out dx, al                  ; 0x1F4 LBA 15:8
    inc edx
    mov al, [lba + 2]
    out dx, al                  ; 0x1F5 LBA 23:16
    pop eax
    mov edx, ATA_CMD
    out dx, al                  ; go
    call delay400
    ret

delay400:                       ; the ATA "400 ns" rule: give the drive time
    mov edx, ATA_CTL            ; to raise BSY before trusting the status --
    in al, dx                   ; read the ALTERNATE status 4 times
    in al, dx
    in al, dx
    in al, dx
    ret

wait_not_busy:
    mov edx, ATA_CMD
.poll:
    in al, dx
    test al, 0x80               ; BSY
    jnz .poll
    ret

wait_drq:                       ; wait for BSY=0 and DRQ=1 (or an error)
    mov edx, ATA_CMD
.poll:
    in al, dx
    test al, 0x80
    jnz .poll
    test al, 0x01               ; ERR
    jnz ata_error
    test al, 0x08               ; DRQ
    jz .poll
    ret

read_sector:                    ; 256 x IN AX, DX -> BUF
    mov edi, BUF
    mov ecx, 256
    mov edx, ATA_DATA
.word:
    in ax, dx                   ; 66 ED
    mov [edi], ax
    add edi, 2
    dec ecx
    jnz .word
    ret

ata_error:
    mov edi, VGA + 480
    mov esi, s_error
    call print
    cli
    hlt

print:                          ; ESI = string, EDI = screen position
    mov al, [esi]
    cmp al, 0
    je .done
    call putch
    inc esi
    jmp print
.done:
    ret

putch:                          ; AL = character at EDI, light grey
    mov ah, 0x07
    mov [edi], ax
    add edi, 2
    ret

s_ident: db 'IDENTIFY: ', 0
s_error: db 'ATA error!', 0
    align 4
lba:     dd 0
wbuf:    db 'Sector 1: written by the CPU with OUT DX, AX (PIO).', 0
    times 512 - ($ - wbuf) db 0
