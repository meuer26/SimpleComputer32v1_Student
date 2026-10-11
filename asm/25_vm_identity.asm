; Test 25: virtual memory -- identity paging (TWO-LEVEL page tables).
;   Build an x86-style two-level table (paging still OFF, so these writes are
;   physical): a page DIRECTORY at 0x100 whose entry 0 points to a page TABLE
;   (PT0) at 0x180; PT0 identity-maps virtual pages 0..2 to the same physical
;   frames. Load CR3 (= directory base) and set CR0.PG. From then on every
;   address is virtual: a TLB miss walks TWO levels (read the PDE, then the PTE
;   -- two bus reads); hits translate in one cycle. With an identity map VA==PA,
;   so the store below lands at the same physical address.
;
;   64-byte pages. VA[9:8]=dir index, VA[7:6]=table index, VA[5:0]=offset.
;   Entry = (frame<<6) | present.  Directory @ 0x100, PT0 @ 0x180.
; Expected: eax=0xDEADBEEF ebx=0xDEADBEEF ; phys mem 0x80 = EF BE AD DE
bits 32
    ; --- page directory @ 0x100 ---
    mov eax, 0x181
    mov [0x100], eax        ; PDE[0] -> page table PT0 at PA 0x180, present
    ; --- page table PT0 @ 0x180: identity-map VPN0..2 ---
    mov eax, 0x01
    mov [0x180], eax        ; PT0[0]: VPN0 -> frame0 (code), present
    mov eax, 0x41
    mov [0x184], eax        ; PT0[1]: VPN1 -> frame1 (code), present
    mov eax, 0x81
    mov [0x188], eax        ; PT0[2]: VPN2 -> frame2 (data), present

    mov eax, 0x100
    mov cr3, eax            ; CR3 = page-DIRECTORY base
    mov eax, 0x80000000
    mov cr0, eax            ; CR0.PG = 1 -> paging ON (two-level walks from here)

    mov eax, 0xDEADBEEF
    mov [0x80], eax         ; VA 0x80 -> PDE[0] -> PT0[2] -> PA 0x80 (identity)
    mov ebx, [0x80]         ; read it back
    hlt
