; Test 25: virtual memory -- identity paging.
;   Build a single-level page table (paging still OFF, so these writes are
;   physical), map virtual pages 0..2 to the identical physical frames, load
;   CR3, then set CR0.PG to turn paging ON. From that point every address the
;   CPU emits is virtual and the MMU translates it through the page table (a TLB
;   miss walks the table; hits are single-cycle). With an identity map VA == PA,
;   so the store below lands at the same physical address -- proving the
;   translation path works end to end.
;
;   64-byte pages: PTE = (frame << 6) | present.  Page table base (CR3) = 0x100.
;     PTE[0]=0x01 (frame0), PTE[1]=0x41 (frame1), PTE[2]=0x81 (frame2)
; Expected: eax=0xDEADBEEF ebx=0xDEADBEEF ; phys mem 0x80 = EF BE AD DE
bits 32
    ; --- build the page table at physical 0x100 (paging OFF) ---
    mov eax, 0x01
    mov [0x100], eax        ; PTE[0]: VPN0 -> frame0, present
    mov eax, 0x41
    mov [0x104], eax        ; PTE[1]: VPN1 -> frame1, present
    mov eax, 0x81
    mov [0x108], eax        ; PTE[2]: VPN2 -> frame2, present

    ; --- turn paging on ---
    mov eax, 0x100
    mov cr3, eax            ; CR3 = page-table base
    mov eax, 0x80000000
    mov cr0, eax            ; CR0.PG = 1  -> paging ON

    ; --- now virtual; identity map means VA 0x80 -> PA 0x80 ---
    mov eax, 0xDEADBEEF
    mov [0x80], eax         ; store through the MMU
    mov ebx, [0x80]         ; read it back
    hlt
