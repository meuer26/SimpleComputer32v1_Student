; Test 32: the PIPELINE and its hazards -- the Pentium core is always pipelined;
; watch each section in Surfer:
;
;     make run TEST=32
;
; The rows D1 / D2 / EX / WB show, as text, which instruction is in each stage:
; read down a column and the instructions step one row down per clock. The row
; under them names every bubble (AGI, BRANCH, QUEUE EMPTY, ...).
;
;   PF  prefetch   -- fills the prefetch queue from 32-byte I-cache lines
;   D1  decode 1   -- finds the instruction's length at the queue head
;   D2  decode 2   -- ADDRESS GENERATION (base register + displacement)
;   EX  execute    -- ALU, or the data access of a load/store (U and V pipes)
;   WB  write back -- retire
;
; Measured pipeline counts for this program (printed in the Performance block):
;   AGI stalls          = 1   (section 2, and none in the reordered 2b)
;   branch stall cycles = 7   (section 4: the taken loop jumps)
;   no stall at all      in sections 1 and 3 (results are forwarded)
;   25 instructions retired in 60 cycles -> CPI ~= 2.4.
;
; Expected: EAX=0x11111112 ECX=0 ; mem 0x100 = 08 ; 0x104 = 11 11 11 11 ;
;   0x108 = 22 22 22 22 ; 0x10C = 12 11 11 11 ; 0x110 = 00
bits 32
    mov esp, 0xF0

; --- (1) RAW dependency chain: each ADD needs the previous result. ---------
;     No stall: the result is FORWARDED from the end of EX to the next EX.
    mov eax, 1
    add eax, eax
    add eax, eax
    add eax, eax              ; EAX = 8
    mov [0x100], eax

; --- (2) AGI -- Address Generation Interlock (the x86-specific hazard). ----
;     D2 must add EBX + displacement while `mov ebx` is still in EX:
;     the load waits ONE cycle in D2 -> one bubble in EX.
    mov ebx, table
    mov ecx, [ebx]            ; <-- AGI
    mov [0x104], ecx          ; (ECX is DATA here, not an address: no stall)

; --- (2b) The same kind of work, scheduled by a compiler: one independent
;     instruction between the producer and the address use. No stall.
    mov esi, table
    mov edi, 0x55             ; independent
    mov edx, [esi+4]          ; ESI was written 2 instructions ago: no AGI
    mov [0x108], edx

; --- (3) Load-use: the loaded value is used by the very next instruction. --
;     No stall on the Pentium: the load reads the cache in EX and forwards it.
    mov eax, [table]
    add eax, 1
    mov [0x10C], eax

; --- (4) Control hazard: a loop. Each TAKEN jnz flushes D1/D2 and the
;     prefetch queue; the target is fetched while jnz is in EX, so the
;     penalty is 2 bubbles. The last, NOT-taken jnz costs nothing.
    mov ecx, 4
again:
    dec ecx
    jnz again                 ; taken 3 times, falls through once
    mov [0x110], ecx
    hlt

    align 4
table:
    dd 0x11111111, 0x22222222
