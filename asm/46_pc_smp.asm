; Test 46 (PC): SMP -- the BSP starts the AP in software, and BOTH cores run.
;
; At reset only core 0 (the bootstrap processor) runs. It starts core 1 (the
; application processor) the real way: it writes an INIT IPI then a STARTUP IPI
; to the local-APIC ICR mailbox at 0x1F0; the APIC wakes the AP at vector*0x40.
; From then on both cores execute concurrently. They share a counter at 0x110
; and each increments it 4 times under a LOCK CMPXCHG spinlock (lock at 0x100).
; MESI coherency keeps the shared line consistent and LOCK# makes the read-
; modify-write atomic, so no updates are lost: the final counter is exactly 8.
;
; Run it live with `make pc PROG=asm/46_pc_smp.asm` and watch the TWO pipeline
; windows: the BSP chart and the AP chart both show instructions flowing, and
; the cache window shows the MESI line bouncing between the cores.
;
; Expected: screen row 0 "SMP: BSP + AP, counter = 8" ; mem 0x110 = 08 ; 0x800 = 08
bits 32
VGA equ 0xB8000

; ---- bootstrap processor (core 0): runs from reset ----
    mov esp, 0xFF0
    mov eax, 0x500             ; INIT IPI   (ICR delivery mode 101)
    mov [0x1F0], eax
    mov eax, 0x601             ; STARTUP IPI, vector 1 -> AP starts at 1*0x40 = 0x40
    mov [0x1F0], eax
    mov ebp, 0x0B              ; tag this core as the BSP (registers are per core)
    mov esi, 4                 ; this core's iterations
    jmp work

    times 0x40-($-$$) db 0x90  ; pad up to the AP entry point (SIPI vector 1)

; ---- application processor (core 1): woken by the SIPI, starts here at 0x40 ----
    mov esp, 0xF00             ; the AP's own stack (separate from the BSP's)
    mov ebp, 0x0A              ; tag this core as the AP
    mov esi, 4
    ; fall through into the shared critical section

work:
    mov eax, 0                 ; expected: lock free
    mov ecx, 1                 ; install: lock held
    lock cmpxchg [0x100], ecx  ; atomic test-and-set; ZF=1 iff we got the lock
    jnz work                   ; spin while the other core holds it
    mov eax, [0x110]           ; ---- critical section: counter++ ----
    inc eax
    mov [0x110], eax
    mov eax, 0
    mov [0x100], eax           ; ---- release ----
    dec esi
    jnz work

    cmp ebp, 0x0B              ; which core am I?
    jne ap_done                ; the AP just stops once its 4 are done

    ; ---- BSP: wait until BOTH cores have finished (counter == 8), then report ----
bsp_wait:
    mov eax, [0x110]
    cmp eax, 8
    jne bsp_wait
    mov [0x800], eax           ; publish the final count (checker reads mem[0x800])

    mov esi, banner            ; print "SMP: BSP + AP, counter = " on row 0
    mov edi, VGA
.puts:
    mov al, [esi]
    cmp al, 0
    je  .count
    mov ah, 0x1F
    mov [edi], ax
    add edi, 2
    inc esi
    jmp .puts
.count:
    mov eax, [0x110]
    add al, '0'                ; the counter is a single digit (8)
    mov ah, 0x1F
    mov [edi], ax
    cli
    hlt

ap_done:
    hlt

banner: db 'SMP: BSP + AP, counter = ', 0
