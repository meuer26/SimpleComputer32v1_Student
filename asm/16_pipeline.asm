; Test 16: 32-bit x86 pipeline hazards demonstration.
;   - independent instructions (no dependency, can overlap)
;   - RAW dependency chain on EAX (each INC needs the previous result)
;   - load-use hazard: store then load the same address, then use it
;   - control hazard: a taken branch must flush the wrongly-fetched HLT
; Expected: EAX=0x1234567B EBX=0xDEADBEEF ECX=0x0000000F
;           EDX=EAX+EBX=0x1234567B+0xDEADBEEF=0xF0E2156A
;           mem 0x100=7B 56 34 12 ; mem 0x104=6A 15 E2 F0
bits 32
    ; --- independent ops (no inter-instruction dependency) ---
    mov eax, 0x12345678
    mov ebx, 0xDEADBEEF
    mov ecx, 0x0000000F
    ; --- RAW dependency chain: each INC depends on the prior EAX ---
    inc eax
    inc eax
    inc eax                 ; EAX = 0x1234567B
    ; --- load-use hazard: produce in memory, consume immediately ---
    mov [0x100], eax        ; store
    mov edx, [0x100]        ; dependent load
    add edx, ebx            ; use of the loaded value
    ; --- control hazard: taken JMP discards the next (wrongly-fetched) op ---
    jmp after
    hlt                     ; mispredicted/flushed path (must NOT run)
after:
    mov [0x104], edx
    hlt
