; 35_sib.asm -- SIB / scaled-index addressing [base + index*scale + disp].
; Exercises every SIB form gcc emits for arrays, structs and the stack:
;   * base + index*scale, for scale 1, 2, 4 and 8
;   * ESP as a base (which *requires* a SIB byte)
;   * disp32 + index*scale with no base register
; Each value written is read back a different way and left in a register and in
; memory so the checker can confirm the effective address was computed right.
bits 32
        mov     esi, 0x40               ; array base
        mov     ecx, 2                  ; index

        mov     eax, 0x11223344
        mov     [esi + ecx*1], eax      ; -> [0x42]  (scale 1)
        mov     [esi + ecx*2], eax      ; -> [0x44]  (scale 2)
        mov     [esi + ecx*4], eax      ; -> [0x48]  (scale 4)
        mov     [esi + ecx*8], eax      ; -> [0x50]  (scale 8)

        mov     ebx, [esi + ecx*4]      ; base + index*4 load  -> 0x11223344
        mov     edx, [0x40 + ecx*4]     ; disp32 + index*4, no base -> [0x48]

        mov     esp, 0x1F0
        mov     [esp - 8], eax          ; ESP-relative store (SIB) -> [0x1E8]
        mov     ecx, [esp - 8]          ; ESP-relative load

        mov     [0x100], eax            ; a plain copy for the memory check
        hlt
