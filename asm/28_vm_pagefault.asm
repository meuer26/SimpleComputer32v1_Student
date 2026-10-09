; Test 28: virtual memory -- page fault + demand paging (the payoff).
;   Virtual page 5 (VA 0x140) is deliberately left NOT PRESENT. Touching it
;   raises a real x86 page fault (#PF, vector 14): the MMU asserts the fault, the
;   CPU latches the faulting address into CR2 and vectors through the IDT to the
;   handler, pushing the FAULTING instruction's address (an x86 fault is
;   restartable). The handler "demand-pages" the page in -- it writes a present
;   PTE for VPN5 -- then IRETs, and the faulting store re-executes and succeeds.
;
;   Memory map (64-byte pages, CR3=0x100). VPN 0..4 identity-mapped; VPN5 absent:
;     PTE[0]=0x01 PTE[1]=0x41 PTE[2]=0x81 PTE[3]=0xC1 PTE[4]=0x101
;   The handler installs PTE[5]=0x141 (VPN5 -> frame5 = PA 0x140).
; Expected: eax=0xD00DF00D ebx=0xD00DF00D ; phys mem 0x140 = 0D F0 0D D0
bits 32
    ; --- build the page table (paging OFF): identity-map VPN 0..4 ---
    mov eax, 0x01
    mov [0x100], eax        ; PTE[0]
    mov eax, 0x41
    mov [0x104], eax        ; PTE[1]
    mov eax, 0x81
    mov [0x108], eax        ; PTE[2]
    mov eax, 0xC1
    mov [0x10C], eax        ; PTE[3]
    mov eax, 0x101
    mov [0x110], eax        ; PTE[4] (the page table's own page, identity)

    mov esp, 0xFC           ; stack (VPN3)
    lidt [idt_ptr]          ; install the IDT (points at ivt below)

    mov eax, 0x100
    mov cr3, eax
    mov eax, 0x80000000
    mov cr0, eax            ; paging ON

    ; --- touch the UNMAPPED page: #PF -> handler maps it -> store retried ---
    mov eax, 0xD00DF00D
    mov [0x140], eax        ; VPN5 not present -> page fault
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
    mov eax, 0x141          ; PTE[5] = VPN5 -> frame5 (PA 0x140), present
    mov [0x114], eax        ; page table entry 5 (0x100 + 5*4): VPN5 -> frame5
    pop eax                 ; restore EAX
    iret                    ; return -> the faulting store re-executes
