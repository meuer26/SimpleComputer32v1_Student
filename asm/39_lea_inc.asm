; 39_lea_inc.asm -- the "compiler glue" gcc leans on: LEA for address and cheap
; arithmetic, INC/DEC straight on a memory counter (grp5 /0 /1), and the LEAVE
; that tears down a stack frame. All three appear constantly in gcc -O0 output.
bits 32
        ; --- LEA: full [base + index*scale + disp], and index*scale + disp ---
        mov     ebx, 0x40
        mov     ecx, 3
        lea     eax, [ebx + ecx*4 + 8]  ; 0x40 + 12 + 8    = 0x54
        lea     ebx, [ebx*2 + 0x10]     ; 0x40*2 + 0x10    = 0x90

        ; --- INC/DEC a memory counter (FF /0, FF /1) ---
        mov     dword [0x100], 100
        inc     dword [0x100]           ; 101
        inc     dword [0x100]           ; 102
        dec     dword [0x100]           ; 101
        mov     ecx, [0x100]            ; ECX = 101 (0x65)

        ; --- LEAVE: ESP<-EBP, EBP<-[EBP] ---
        mov     esp, 0x1F0
        mov     ebp, 0xABCD
        push    ebp                     ; save old EBP on the stack
        mov     ebp, esp                ; set the frame pointer
        sub     esp, 8                  ; reserve locals
        leave                           ; restore EBP = 0xABCD, ESP = 0x1F0
        mov     edx, ebp                ; EDX = 0xABCD
        hlt
