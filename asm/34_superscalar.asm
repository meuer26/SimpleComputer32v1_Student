; Test 34: superscalar U/V dual-issue -- which instructions pair and co-issue,
; and which must not. The Pentium has TWO integer pipes, U and V. Adjacent
; "simple" instructions issue together (two per clock) when the pair is safe;
; otherwise the V instruction waits a clock. Pairing NEVER changes the result.
;
; Watch the D1/D2/EX/WB rows (Surfer) or the live pipe window's "U/V pairs"
; counter and "<<PAIR CO-ISSUE>>" marker:
;   Section A -- a long run of INDEPENDENT reg/imm ops: they stream through the
;                two pipes two-at-a-time, so the pair counter climbs steadily.
;   Section B -- a read-after-write chain on ECX: each op needs the previous
;                result, so the pair is unsafe and they issue ONE per clock.
;   Section C -- CMP/Jcc: the conditional branch pairs with the flag-setter.
;
; Expected: EAX=0x29 EBX=0x2A ECX=0x37 EDX=0x2C ESI=0x2D EDI=0x2E
;           mem 0x100=37 00 00 00 ; 0x104=29 00 00 00
bits 32
; ---- Section A: independent ops -- these PAIR (U+V, two per clock) ----
    mov eax, 1
    mov ebx, 2
    mov ecx, 3
    mov edx, 4
    mov esi, 5
    mov edi, 6
    add eax, 0x10
    add ebx, 0x10
    add ecx, 0x10
    add edx, 0x10
    add esi, 0x10
    add edi, 0x10
    add eax, 0x18          ; EAX = 1 +0x10+0x18 = 0x29
    add ebx, 0x18          ; EBX = 0x2A
    add edx, 0x18          ; EDX = 0x2C
    add esi, 0x18          ; ESI = 0x2D
    add edi, 0x18          ; EDI = 0x2E

; ---- Section B: RAW dependency chain on ECX -- these do NOT pair ----
    add ecx, eax           ; ECX = 0x13 + 0x29 = 0x3C  (needs EAX)
    sub ecx, ebx           ; ECX = 0x3C - 0x2A = 0x12  (RAW on ECX -> no pair)
    add ecx, edx           ; ECX = 0x12 + 0x2C = 0x3E  (RAW on ECX -> no pair)
    sub ecx, esi           ; ECX = 0x3E - 0x2D = 0x11  (RAW on ECX -> no pair)
    add ecx, edi           ; ECX = 0x11 + 0x2E = 0x3F  (RAW on ECX -> no pair)

; ---- Section C: compare + conditional branch -- these PAIR (flag forward) ----
    cmp ecx, 0x3F          ; equal -> ZF = 1
    jz  taken              ; pairs with the CMP; forwarded ZF=1 -> branch taken
    mov ecx, 0xDEAD        ; skipped iff pairing/forwarding are correct
taken:
    sub ecx, 8             ; ECX = 0x3F - 8 = 0x37
    mov [0x100], ecx       ; expect 0x37
    mov [0x104], eax       ; expect 0x29
    hlt
