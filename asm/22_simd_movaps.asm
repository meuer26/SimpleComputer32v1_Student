; Test 22: SSE MOVAPS -- aligned 128-bit packed move (opcodes 0F 28 / 0F 29).
;   MOVAPS is the aligned move used by packed-single SIMD code; here it moves
;   the same 16-byte vectors MOVDQA does, without the 66 prefix. This mirrors
;   the classic "vectorize a 4-int loop" optimization:
;       load 4 dwords -> PADDD (4 lanes at once) -> store 4 dwords.
;   Doubling {1,2,3,4} with one PADDD yields {2,4,6,8} -- four adds, one op.
; Vectors are 16-byte aligned (MOVAPS requires alignment).
; Expected: mem 0x120 = 02 00 00 00 04 00 00 00 06 00 00 00 08 00 00 00
;           mem 0x130 = 02 00 00 00 04 00 00 00 06 00 00 00 08 00 00 00
bits 32
    movaps xmm0, [0x100]    ; aligned load  {1,2,3,4}
    paddd  xmm0, xmm0       ; SIMD: 4 lane-wise adds -> {2,4,6,8}
    movaps [0x120], xmm0    ; aligned store
    movaps xmm1, xmm0       ; register-to-register aligned move
    movaps [0x130], xmm1    ; store the copy (proves the reg move worked)
    hlt
    times 0x100-($-$$) db 0
vec:
    dd 1, 2, 3, 4
