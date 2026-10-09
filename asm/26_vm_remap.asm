; Test 26: virtual memory -- non-identity mapping (relocation).
;   Same idea as test 25, but virtual page 2 is mapped to a DIFFERENT physical
;   frame, proving the MMU really relocates: a store to VA 0x80 lands at a
;   different physical address, and the original PA 0x80 is untouched.
;     PTE[0] = 0x01  -> VPN0 -> frame0  (code, identity)
;     PTE[2] = 0x141 -> VPN2 -> frame5  (VA 0x80..0xBF -> PA 0x140..0x17F)
; Expected: eax=0x1234ABCD ebx=0x1234ABCD
;           phys mem 0x140 = CD AB 34 12 ; phys mem 0x80 = 00 00 00 00
bits 32
    mov eax, 0x01
    mov [0x100], eax        ; PTE[0]: VPN0 -> frame0 (code, identity)
    mov eax, 0x141
    mov [0x108], eax        ; PTE[2]: VPN2 -> frame5 (RELOCATED to PA 0x140)

    mov eax, 0x100
    mov cr3, eax
    mov eax, 0x80000000
    mov cr0, eax            ; paging ON

    mov eax, 0x1234ABCD
    mov [0x80], eax         ; VA 0x80 -> PA 0x140 (not 0x80!)
    mov ebx, [0x80]         ; read back through the same translation
    hlt
