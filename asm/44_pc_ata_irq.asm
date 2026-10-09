; Test 44 (PC): INTERRUPT-DRIVEN disk read through the CASCADED 8259s.
;
; The disk's interrupt is IRQ14 = input 6 of the SLAVE 8259, whose output is
; wired to input 2 of the MASTER. One sector arriving:
;   drive has the data -> DRQ=1 and INTRQ (IRQ14) -> slave IRR bit 6 -> slave
;   INT -> master IR2 -> master INTR -> CPU INTA -> master sees IR2 is the
;   cascade, so the SLAVE supplies the vector: 0x28 + 6 = 0x2E -> ata_isr.
; The handler reads the status register (that acknowledges INTRQ), moves the
; 256 words, then must send an EOI to BOTH controllers: slave first, then master.
;
; Meanwhile the main program just sleeps in HLT -- no polling at all. A 2-sector
; read gives two interrupts, one per sector.
;
; Expected: row 0 = sector 2 text, row 1 = sector 3 text,
;   row 2 "IRQ14 interrupts: 2" ; mem 0x800 = 02
bits 32
VGA      equ 0xB8000
BUF      equ 0xA00                ; room for 2 sectors

start:
    mov esp, 0xFF0
    lidt [idt_ptr]

    ; ---- 8259s: master 0x20-0x27, slave 0x28-0x2F ----
    mov al, 0x11
    out 0x20, al
    out 0xA0, al
    mov al, 0x20
    out 0x21, al
    mov al, 0x28
    out 0xA1, al
    mov al, 0x04
    out 0x21, al
    mov al, 0x02
    out 0xA1, al
    mov al, 0x01
    out 0x21, al
    out 0xA1, al
    mov al, 0xFB                  ; master: only IR2 (the cascade) unmasked
    out 0x21, al
    mov al, 0xBF                  ; slave: only IR6 = IRQ14 unmasked
    out 0xA1, al

    mov edx, 0x3F6
    mov al, 0x00                  ; nIEN = 0: let the drive interrupt
    out dx, al
    sti

    ; ---- READ SECTORS: 2 sectors from LBA 2 ----
    mov edx, 0x1F6
    mov al, 0xE0                  ; master, LBA, LBA[27:24] = 0
    out dx, al
    mov edx, 0x1F2
    mov al, 2                     ; 2 sectors
    out dx, al
    inc edx
    mov al, 2                     ; LBA = 2
    out dx, al
    inc edx
    mov al, 0
    out dx, al
    inc edx
    out dx, al
    mov edx, 0x1F7
    mov al, 0x20                  ; READ SECTORS
    out dx, al

wait_io:                          ; sleep until both sectors have arrived
    cli
    mov eax, [done]
    cmp eax, 2
    je  all_done
    sti
    hlt
    jmp wait_io
all_done:
    sti
    mov [0x800], eax

    mov edi, VGA
    mov esi, BUF
    call print
    mov edi, VGA + 160
    mov esi, BUF + 512
    call print
    mov edi, VGA + 320
    mov esi, s_count
    call print
    mov al, [done]
    add al, '0'
    call putch
    cli
    hlt

; ---- IRQ14 handler (vector 0x2E) ----
ata_isr:
    pushad
    mov edx, 0x1F7
    in al, dx                     ; read STATUS: acknowledges the drive's INTRQ
    mov edi, [dst]
    mov ecx, 256
    mov edx, 0x1F0
.word:
    in ax, dx
    mov [edi], ax
    add edi, 2
    dec ecx
    jnz .word
    mov [dst], edi
    mov eax, [done]
    inc eax
    mov [done], eax
    mov al, 0x20
    out 0xA0, al                  ; EOI to the slave (IRQ14 lives there) ...
    out 0x20, al                  ; ... and to the master (its IR2 cascade input)
    popad
    iret

ignore_int:
    iret

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

s_count: db 'IRQ14 interrupts: ', 0
    align 4
done:   dd 0
dst:    dd BUF
ivt:
    times 0x2E dd ignore_int
    dd ata_isr                    ; 0x2E = IRQ14 (slave IR6)
    dd ignore_int                 ; 0x2F
idt_ptr:
    dw 0x30 * 4 - 1
    dd ivt
