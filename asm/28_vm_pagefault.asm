; Test 28: virtual memory -- page fault + demand paging, TWO-LEVEL (the payoff).
;   Virtual page 5 (VA 0x140) is left NOT PRESENT at the second level: its page
;   directory entry (PDE[1]) IS present and points to page table PT1, but PT1's
;   entry for VPN5 is absent. Touching VA 0x140 walks PDE[1] (present) then the
;   PTE (absent) -> a real x86 #PF (vector 14): the CPU latches CR2, vectors
;   through the IDT, and pushes the FAULTING instruction's address (restartable).
;   The handler demand-pages the page in -- it writes a present PTE into PT1 --
;   then IRETs, and the faulting store re-executes and succeeds.
;
;   64-byte pages (VA[9:8]=dir, VA[7:6]=table, VA[5:0]=offset). Directory @0x100:
;     PDE[0]=0x181 -> PT0 @0x180 (identity-maps VPN0..3: code/IVT/handler/stack)
;     PDE[1]=0x1C1 -> PT1 @0x1C0 (PT1[3]=0x1C1 maps VPN7->frame7 so the handler
;                                 can reach PT1 virtually; PT1[1]/VPN5 absent)
;   The handler installs PT1[1]=0x141 (VPN5 -> frame5 = PA 0x140).
; Expected: eax=0xD00DF00D ebx=0xD00DF00D ; phys mem 0x140 = 0D F0 0D D0
bits 32
    ; --- page directory @ 0x100 ---
    mov eax, 0x181
    mov [0x100], eax        ; PDE[0] -> PT0 @ 0x180
    mov eax, 0x1C1
    mov [0x104], eax        ; PDE[1] -> PT1 @ 0x1C0
    ; --- PT0 @ 0x180: identity-map VPN0..3 (code, IVT, handler, stack) ---
    mov eax, 0x01
    mov [0x180], eax        ; PT0[0] VPN0
    mov eax, 0x41
    mov [0x184], eax        ; PT0[1] VPN1
    mov eax, 0x81
    mov [0x188], eax        ; PT0[2] VPN2 (IVT/handler page)
    mov eax, 0xC1
    mov [0x18C], eax        ; PT0[3] VPN3 (stack)
    ; --- PT1 @ 0x1C0: map VPN7 (so handler can write PT1); VPN5 left absent ---
    mov eax, 0x1C1
    mov [0x1CC], eax        ; PT1[3] VPN7 -> frame7 (PT1's own frame, identity)

    mov esp, 0xFC           ; stack (VPN3)
    lidt [idt_ptr]          ; install the IDT (points at ivt below)

    mov eax, 0x100
    mov cr3, eax            ; CR3 = page-directory base
    mov eax, 0x80000000
    mov cr0, eax            ; paging ON

    ; --- touch the UNMAPPED page: #PF -> handler maps it -> store retried ---
    mov eax, 0xD00DF00D
    mov [0x140], eax        ; VPN5 absent -> page fault
    mov ebx, [0x140]        ; after the handler maps it: reads back 0xD00DF00D
    hlt

    times 0x80-($-$$) db 0
ivt:
    times 14 dd 0           ; vectors 0..13 (unused)
    dd handler              ; vector 14 = #PF handler
idt_ptr:
    dw 0x7F                 ; IDT limit
    dd ivt                  ; IDT base

handler:                    ; #PF: demand-page VPN5 in, then restart the store
    push eax                ; preserve the value being stored
    mov eax, 0x141          ; PT1[1] = VPN5 -> frame5 (PA 0x140), present
    mov [0x1C4], eax        ; write via VPN7 identity -> PA 0x1C4 = PT1 entry 1
    pop eax                 ; restore EAX
    iret                    ; return -> the faulting store re-executes
