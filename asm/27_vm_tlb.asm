; Test 27: virtual memory -- TLB reuse.
;   The TLB caches virtual->physical translations so only the FIRST touch of a
;   page walks the page table; later accesses hit the TLB and translate in a
;   single cycle. This loop hammers one data page (VA 0x80) eight times and runs
;   entirely out of one code page, so despite ~50 translated accesses the
;   "page-table walks" count in the paging stats stays tiny (one per distinct
;   page). Watch the walk count vs. the translation count.
;     PTE[0]=0x01 (code, identity), PTE[2]=0x81 (data, identity)
; Expected: eax=8 ebx=8 ecx=0 ; phys mem 0x80 = 08 00 00 00
bits 32
    mov eax, 0x01
    mov [0x100], eax        ; VPN0 -> frame0 (code)
    mov eax, 0x81
    mov [0x108], eax        ; VPN2 -> frame2 (data, identity)

    mov eax, 0x100
    mov cr3, eax
    mov eax, 0x80000000
    mov cr0, eax            ; paging ON

    mov ecx, 8              ; iteration count  ([0x80] starts at 0)
sweep:
    mov eax, [0x80]         ; load counter   (TLB hit after the 1st walk)
    inc eax
    mov [0x80], eax         ; store counter  (same page, TLB hit)
    dec ecx
    jnz sweep
    mov ebx, [0x80]         ; final value = 8
    hlt
