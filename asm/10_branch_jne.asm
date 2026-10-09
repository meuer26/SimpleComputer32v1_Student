; Test 10: JNE countdown loop + JMP over a trap.
; Expected: EAX=0x99 EBX=5 ; mem[0x100]=0
bits 32
    mov eax, 5
    mov ebx, 0
loop_top:
    inc ebx
    dec eax
    jne loop_top
    jmp done
trap:
    hlt
done:
    mov [0x100], eax
    mov eax, 0x99
    hlt
