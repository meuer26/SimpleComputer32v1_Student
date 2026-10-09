; SMP coherency + Pentium BSP/AP bring-up demo.
;
; Core 0 (the BOOTSTRAP processor) runs from reset. Core 1 (the APPLICATION
; processor) boots PARKED; core 0 starts it by writing its entry address to the
; start-up mailbox at 0x1F0 -- a scaled version of the Pentium's startup IPI.
; Both cores then increment a SHARED counter 4 times under a LOCK CMPXCHG
; spinlock. With working MESI coherency + LOCK# atomicity the two cores never
; lose an update, so the final counter == 8 (2 cores x 4).
;
;   APIC ICR = mem[0x1F0]  (write INIT then STARTUP IPI to start the AP)
;   lock     = mem[0x100]  (0 = free, 1 = held)
;   counter  = mem[0x110]  (shared, starts at 0)
;
; ESI is a private per-core iteration count (registers are per core).
bits 32
; ---- bootstrap processor (core 0): boots here at reset ----
    mov eax, 0x500             ; INIT IPI  (ICR delivery mode 101)
    mov [0x1F0], eax
    mov eax, 0x601             ; STARTUP IPI, vector 1 -> AP starts at 1*0x40 = 0x40
    mov [0x1F0], eax           ; SIPI: the local APIC wakes core 1 at 0x40
    mov esi, 4                 ; this core's iterations
    jmp work

    times 0x40-($-$$) db 0x90  ; NOP-pad up to the AP entry point (SIPI vector 1)

; ---- application processor (core 1): woken by the SIPI, starts here at 0x40 ----
ap_entry:
    mov esi, 4                 ; this core's iterations
    ; fall through into the shared critical section

work:
    mov eax, 0                 ; expected: lock free
    mov ecx, 1                 ; install: lock held
    lock cmpxchg [0x100], ecx  ; atomic CAS; ZF=1 iff we acquired the lock
    jnz work                   ; spin while the other core holds it
    ; ---- critical section: counter++ ----
    mov eax, [0x110]
    inc eax
    mov [0x110], eax
    ; ---- release ----
    mov eax, 0
    mov [0x100], eax
    dec esi
    jnz work
    hlt
