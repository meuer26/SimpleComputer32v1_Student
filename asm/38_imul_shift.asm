; 38_imul_shift.asm -- IMUL and the shift/rotate group, register and memory.
; These are the ops gcc emits for multiplication, array index scaling, and the
; *2^n / /2^n it uses in place of shifts and (via multiply+shift) constant
; division. Covers all three IMUL encodings and SHL/SHR/SAR by imm8, by CL and
; by 1, plus a shift straight on memory (read-modify-write).
bits 32
        ; --- IMUL: two-operand (0F AF), three-operand imm8 (6B), from memory ---
        mov     eax, 7
        imul    eax, eax                ; 0F AF: 7 * 7   = 49
        imul    eax, eax, 2             ; 6B:    49 * 2  = 98
        mov     dword [0x80], 10
        imul    eax, [0x80]             ; 0F AF mem: 98 * 10 = 980 (0x3D4)
        mov     ebx, eax                ; EBX = 980

        ; --- shift by CL, then fold the result into EBX ---
        mov     eax, 1
        mov     ecx, 5
        shl     eax, cl                 ; 1 << 5 = 0x20
        add     ebx, eax                ; EBX = 980 + 0x20 = 0x3F4

        ; --- shift by immediate and arithmetic right ---
        mov     ecx, 0x1000
        shr     ecx, 4                  ; logical >> 4    -> ECX = 0x100
        mov     edx, 0xFFFFFF00
        sar     edx, 4                  ; arithmetic >> 4 -> EDX = 0xFFFFFFF0

        ; --- shift straight on memory (read-modify-write) ---
        mov     dword [0x84], 5
        shl     dword [0x84], 3         ; 5 << 3 = 40 (0x28)
        mov     eax, [0x84]             ; EAX = 40 (0x28)
        hlt
