; Self-modifying code -- the signature Pentium cache-coherence case.
;
; The instruction at `again` is executed, then its IMMEDIATE byte is rewritten
; by a store, then executed AGAIN on the next loop pass:
;   iter 1:  AL = 0x11,  EBX += 0x11
;            patch the immediate 0x11 -> 0x22  (a store into the code)
;   iter 2:  AL = 0x22  (the modified instruction!),  EBX += 0x22
;   result:  EBX = 0x11 + 0x22 = 0x33   (it would be 0x22 if SMC were broken)
;
; On the Pentium the data write snoops the INSTRUCTION cache and invalidates the
; stale code line; the re-fetch then pulls the new byte from the (dirty) DATA
; cache -- so the second execution sees the modified instruction. With the cache
; off it works via the prefetch-queue flush on the taken branch. Either way the
; architectural result is identical: EBX = 0x33.
bits 32
    xor eax, eax
    xor ebx, ebx
    mov ecx, 2
again:
    db 0xB0, 0x11             ; mov al, 0x11   (the imm byte is self-modified below)
imm equ again + 1
    add ebx, eax             ; accumulate AL into EBX
    mov byte [imm], 0x22     ; rewrite the immediate for the next pass (store into code)
    dec ecx
    jnz again
    mov eax, ebx
    mov [0x100], eax         ; mem[0x100] = 0x33
    hlt
