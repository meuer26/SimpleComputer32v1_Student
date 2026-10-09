; Test 19: test-and-set spinlock built on LOCK CMPXCHG (F0 0F B1) -- the
; correct SMP compare-and-swap primitive. lock = mem[0x100] (0 = free).
;   acquire: EAX=0 (expected free), ECX=1 (desired held);
;            LOCK CMPXCHG [lock], ECX  -> if [lock]==EAX install ECX, ZF=1
;            JNZ acquire (retry while another core holds it)
; Expected: EAX=0 ECX=1 ; Z=1 C=0 I=0 ; mem 0x100=0 (released) ; mem 0x180=EF BE AD DE
bits 32
    mov eax, 0
    mov [0x100], eax        ; lock = free
acquire:
    mov eax, 0              ; expected old value
    mov ecx, 1              ; value to install
    lock cmpxchg [0x100], ecx
    jnz acquire
    ; ---- critical section ----
    mov eax, 0xDEADBEEF
    mov [0x180], eax
    ; ---- release ----
    mov eax, 0
    mov [0x100], eax
    hlt
