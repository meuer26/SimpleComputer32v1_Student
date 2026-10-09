; Disk image for the teaching PC's ATA hard disk (16 sectors x 512 bytes = 8 KB).
; It is assembled with nasm -f bin exactly like a program; the ATA disk model
; (rtl/ata_disk.vhd) loads it at power-on. Sector n starts at byte n*512 (LBA n).
bits 32
sector0:
    db 'Hello from sector 0 of the ATA disk (asm/pc_disk.asm).', 0
    times 1*512-($-$$) db 0
sector1:
    db 'Sector 1 still holds its original text.', 0
    times 2*512-($-$$) db 0
sector2:
    db 'Sector 2: delivered by an IRQ14 interrupt.', 0
    times 3*512-($-$$) db 0
sector3:
    db 'Sector 3: the second sector of a 2-sector read.', 0
    times 16*512-($-$$) db 0
