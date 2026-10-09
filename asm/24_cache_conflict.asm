; Test 24: cache CONFLICT misses + write-back traffic.
;   The L1 D-cache is a fixed Pentium-faithful geometry: split I/D, 2-way,
;   32-byte lines, 4 sets. With 32-byte lines the set index is address bits
;   [6:5], so the set stride is 0x80. The three addresses 0x80, 0x100, 0x180 are
;   each a multiple of 0x80 apart, so ALL THREE map to the SAME set 0. That set
;   has only 2 ways but three live lines, so each pass evicts the LRU line -- a
;   CONFLICT miss -- and because every line was just written (dirty), the
;   eviction is a WRITE-BACK. Watch the "misses" and "writebacks" counts climb,
;   in sharp contrast to test 23 (a sequential sweep that fits and barely
;   misses). Each address is incremented once per pass; 3 passes -> each = 3.
; Expected: eax=3 ecx=0 ; mem 0x80=3 0x100=3 0x180=3
bits 32
    mov ecx, 3              ; number of passes
pass:
    mov ebx, 0x80           ; first colliding address (set 0)
    mov edx, 3              ; three lines, all in set 0
inner:
    mov eax, [ebx]          ; load counter        (miss: evicted last pass)
    inc eax                 ; ++
    mov [ebx], eax          ; store back (dirty)  (write-back when evicted)
    add ebx, 0x80           ; stride to the next line in the SAME set
    dec edx
    jnz inner
    dec ecx
    jnz pass
    hlt
