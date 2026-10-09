; Test 23: cache SPATIAL locality -- a sequential array sweep.
;   Sum 16 contiguous dwords at 0x100..0x13F. Because the loads march straight
;   through memory, each cache line is missed once and then reused for the rest
;   of its dwords. The L1 line is a Pentium-faithful 32 bytes = 8 dwords, so the
;   array spans two lines: 1 compulsory miss then 7 hits per line (plus one miss
;   for the final store to 0x160) -> D-cache 14 hits / 3 misses, ~95% overall.
;   Run it and read the "Cache statistics": a high hit rate is spatial locality.
;   Contrast with test 24, where colliding addresses thrash the same set.
;   sum(1..16) = 136 = 0x88.
; Expected: eax=0x88 ecx=0 ; mem 0x160 = 88 00 00 00
bits 32
    mov ebx, 0x100          ; array base pointer
    mov ecx, 16             ; element count
    mov eax, 0              ; running sum
sweep:
    mov edx, [ebx]          ; load arr[i]   (the cached access)
    add eax, edx            ; accumulate    (reg-reg)
    add ebx, 4              ; advance to next dword (spatial: same line 3x)
    dec ecx
    jnz sweep
    mov [0x160], eax        ; store the sum
    hlt
    times 0x100-($-$$) db 0
arr:
    dd 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
