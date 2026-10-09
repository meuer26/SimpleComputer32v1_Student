; Test 20: SSE2 integer SIMD. PADDD adds four 32-bit lanes in parallel.
;   movdqa loads/stores 128-bit vectors; paddd does 4 adds at once.
; Vectors are 16-byte aligned (movdqa requirement).
; result = [1+0x10, 2+0x20, 3+0x30, 4+0x40] = [0x11, 0x22, 0x33, 0x44]
; Expected: mem 0x120 = 11 00 00 00 22 00 00 00 33 00 00 00 44 00 00 00
bits 32
    movdqa xmm0, [0x100]    ; vecA = 1,2,3,4
    movdqa xmm1, [0x110]    ; vecB = 0x10,0x20,0x30,0x40
    paddd  xmm0, xmm1       ; lane-wise add (SIMD)
    movdqa [0x120], xmm0    ; store result
    pxor   xmm2, xmm2       ; xmm2 = 0 (demonstrates PXOR)
    movd   xmm3, ebx        ; GP -> XMM (demonstrates MOVD)
    hlt
    times 0x100-($-$$) db 0
veca:
    dd 1, 2, 3, 4
    times 0x110-($-$$) db 0
vecb:
    dd 0x10, 0x20, 0x30, 0x40
