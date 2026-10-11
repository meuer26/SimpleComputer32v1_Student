--------------------------------------------------------------------------------
-- x86-32 (IA-32) subset CPU  --  SUPERSCALAR, after the Intel Pentium (P5)
--
-- The one and only core. It runs real x86 machine code and is built to the
-- Pentium as described by Alpert & Avnon, "Architecture of the Pentium
-- Microprocessor" (IEEE Micro, June 1993) -- the paper students read with it:
--
--   * two integer pipelines, U and V, that issue two instructions per clock
--     under the paper's Figure 5 rule (both "simple", I1 not a jump, no RAW or
--     WAW from I1 to I2; the barrel shifter is U-only; cmp+jcc still pairs).
--   * a branch target buffer (BTB) -- {branch addr, target, 2-bit history} --
--     that predicts at decode, so a correctly predicted branch is free and a
--     misprediction flushes and refetches.
--   * separate 2-way, 32-byte-line, write-back MESI instruction and data
--     caches; two of these cores share memory as a dual-Pentium SMP.
--
-- (This build is scaled to the 512 B teaching world: caches ~256 B each, BTB
-- and TLB a handful of entries. Structure is faithful; sizes are not. There is
-- no x87 FPU -- the ISA is SSE2-integer only -- so the paper's FP pipeline is
-- out of scope.)
--
-- The baseline below is still the five-stage integer pipeline (the U-pipe
-- spine); the V pipe, BTB and split caches are layered on in stages. Its five
-- stages, after the 486 the Pentium's integer pipe matches:
--
--   PF  prefetch    fetches aligned dwords into a 16-byte PREFETCH QUEUE,
--                   running ahead of execution (x86 instructions are 1-15
--                   bytes long, so the front end works on a byte stream)
--   D1  decode 1    finds the instruction's length at the queue head (prefixes,
--                   opcode, ModR/M, displacement, immediate) and takes it out
--   D2  decode 2    ADDRESS GENERATION: base register + displacement
--   EX  execute     the ALU operation, or the data access (loads and stores
--                   use the bus in their first EX cycle: 1 cycle on a hit)
--   WB  write back  the instruction retires; its register / flag results were
--                   already forwarded from the end of EX
--
-- Hazards, as on the 486:
--   * data (RAW) between ALU / load results and the next instruction's EX:
--     NO stall -- results are bypassed from the end of EX.
--   * AGI (address generation interlock): an instruction in D2 whose base
--     register (or XLAT's EBX/AL) is written by the instruction in EX must wait
--     one cycle -- the x86-specific data hazard. Reordering removes it.
--   * control: Jcc / JMP are resolved in EX. Not taken costs nothing (the
--     pipeline keeps the sequential path); taken flushes D1/D2 and the queue.
--     Like the 486, the target is fetched while the branch is in EX, so a taken
--     branch costs 2 bubbles. CALL/RET/INT/IRET, CLI/STI/POPFD and MOV CRn
--     drain the pipeline and refetch after them.
--   * structural: PF and EX share the one memory bus; EX goes first, so a run
--     of loads/stores starves the queue. A cache miss stalls the requester.
--   * multi-cycle ("microcoded") instructions -- PUSHAD, INT, IRET, CMPXCHG,
--     SSE 128-bit moves, misaligned accesses -- hold EX for several cycles.
-- Interrupts are taken between instructions; faults are precise (younger
-- instructions are flushed, the faulting one restarts). A page fault on a
-- PREFETCH is only raised if that instruction actually reaches EX.
-- Self-modifying code behaves like on a 486: bytes already in the prefetch
-- queue run even if memory was rewritten (a jump flushes the queue).
--
-- The ISA comments of the multi-cycle core apply unchanged.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.disasm_pkg.all;

-- This is the one and only implementation of the x86_cpu entity.
entity x86_cpu is
    generic (
        -- Width (in chars) of the ASCII EX-state-name debug tap. Sized to fit
        -- the longest state name ("CALL_PUSH" = 9) with room to spare.
        STATE_NAME_CHARS : integer := 16;
        -- Disassembly table (scripts/mkdis.py) for the per-stage text taps.
        DISASM_FILE      : string  := "";
        -- Application processor: this core boots PARKED (halted) and begins
        -- executing only when woken by `wake` at `wake_eip` -- the Pentium SMP
        -- bring-up where the BSP starts the APs (a scaled startup IPI). The
        -- bootstrap processor leaves this false and runs from reset.
        AP_PARK          : boolean := false;
        -- Teaching knobs (all default to the real Pentium behaviour, so the
        -- default machine is unchanged -- see the README). DUAL_ISSUE=false
        -- disables U/V pairing (scalar). SERIALIZE=true drains the pipe after
        -- every instruction (no overlap = "no pipeline"). BTB_ENABLE=false turns
        -- off branch prediction (every taken branch mispredicts).
        DUAL_ISSUE       : boolean := true;
        SERIALIZE        : boolean := false;
        BTB_ENABLE       : boolean := true
    );
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        data_in  : in  std_logic_vector(31 downto 0);
        ready    : in  std_logic := '1';                 -- bus wait-state handshake
        -- AP start-up (ignored unless AP_PARK): a `wake` pulse starts this core
        -- fetching at `wake_eip`.
        wake     : in  std_logic := '0';
        wake_eip : in  std_logic_vector(31 downto 0) := (others => '0');
        addr_out : out std_logic_vector(31 downto 0) := (others => '0');
        data_out : out std_logic_vector(31 downto 0);
        we       : out std_logic;
        be       : out std_logic_vector(3 downto 0);
        mem_req  : out std_logic;                        -- 1 = real bus access this cycle
        mem_ifetch : out std_logic := '0';               -- 1 = this access is an instruction
                                                         --     fetch (routes to the I-cache)
        lock     : out std_logic;                        -- x86 LOCK# (bus lock)

        -- Separate I/O address space (x86 IN/OUT). Distinct from memory: not
        -- cached, addressed by a 16-bit port number. io_re/io_we strobe a read
        -- or write; io_size gives its width (00 byte, 01 word, 10 dword).
        io_addr  : out std_logic_vector(15 downto 0) := (others => '0');
        io_dout  : out std_logic_vector(31 downto 0);
        io_din   : in  std_logic_vector(31 downto 0) := (others => '0');
        io_re    : out std_logic;
        io_we    : out std_logic;
        io_size  : out std_logic_vector(1 downto 0);

        -- Maskable hardware interrupt (from an 8259 PIC).
        intr     : in  std_logic := '0';                 -- INTR request
        inta     : out std_logic;                        -- interrupt acknowledge
        inta_vec : in  std_logic_vector(7 downto 0) := (others => '0'); -- vector from PIC

        halted   : out std_logic;

        -- Paging / MMU interface (x86 CR0.PG, CR3, page-fault delivery). An
        -- external MMU translates virtual->physical and, on a not-present PTE,
        -- pulses page_fault with the faulting linear address on fault_addr. The
        -- inputs default so testbenches without an MMU leave paging off.
        pg_enable  : out std_logic;                       -- CR0.PG (paging on)
        cr3_out    : out std_logic_vector(31 downto 0);   -- CR3 page-table base
        tlb_flush  : out std_logic;                       -- pulse: MOV CR3 (flush TLB)
        page_fault : in  std_logic := '0';                -- MMU: current access faults
        fault_addr : in  std_logic_vector(31 downto 0) := (others => '0');

        -- Debug taps
        dbg02_state    : out std_logic_vector(3 downto 0);
        dbg03_ir       : out std_logic_vector(7 downto 0);
        dbg04_operand  : out std_logic_vector(31 downto 0);
        dbg05_eax      : out std_logic_vector(31 downto 0);
        dbg06_ebx      : out std_logic_vector(31 downto 0);
        dbg07_ecx      : out std_logic_vector(31 downto 0);
        dbg08_esp      : out std_logic_vector(31 downto 0);
        dbg_edx        : out std_logic_vector(31 downto 0);
        dbg_ebp        : out std_logic_vector(31 downto 0);
        dbg_esi        : out std_logic_vector(31 downto 0);
        dbg_edi        : out std_logic_vector(31 downto 0);
        dbg_xmm0       : out std_logic_vector(127 downto 0);
        dbg_xmm1       : out std_logic_vector(127 downto 0);
        dbg_xmm2       : out std_logic_vector(127 downto 0);
        dbg09_flags    : out std_logic_vector(2 downto 0); -- bit2=IF, bit1=CF, bit0=ZF
        dbg_eflags     : out std_logic_vector(31 downto 0);
        dbg10_ivt      : out std_logic_vector(31 downto 0);
        dbg12_bus_lock    : out std_logic;
        dbg13_xchg_active : out std_logic;
        dbg_pc       : out std_logic_vector(31 downto 0);
        dbg_cr2      : out std_logic_vector(31 downto 0);   -- faulting linear address
        dbg_cr3      : out std_logic_vector(31 downto 0);   -- page-table base
        dbg_op_code  : out std_logic_vector(5 downto 0);
        dbg_ud       : out std_logic;                       -- 1 = #UD raised this cycle
        dbg_vector   : out std_logic_vector(7 downto 0);    -- vector being delivered
        -- Pipeline view (the same taps on both cores): which instruction is in
        -- each of the five pipeline stages, plus the superscalar V pipe.
        dbg_retire   : out std_logic;                       -- an instruction completed
        dbg_boundary : out std_logic;                       -- instruction boundary (step point)
        dbg_stall    : out std_logic_vector(2 downto 0);    -- bubble cause, 0 = none
        dbg_stall_name : out std_logic_vector(8*12-1 downto 0);
        dbg_pf_addr  : out std_logic_vector(31 downto 0);   -- prefetch address
        dbg_pq_cnt   : out std_logic_vector(4 downto 0);    -- prefetch-queue bytes
        dbg_stage_valid : out std_logic_vector(3 downto 0); -- D1 D2 EX WB occupied
        dbg_d1_eip, dbg_d2_eip, dbg_ex_eip, dbg_wb_eip : out std_logic_vector(31 downto 0);
        dbg_d1_seq, dbg_d2_seq, dbg_ex_seq, dbg_wb_seq : out std_logic_vector(15 downto 0);
        dbg_d1_txt, dbg_d2_txt, dbg_ex_txt, dbg_wb_txt : out std_logic_vector(8*DIS_CHARS-1 downto 0);
        -- Superscalar V pipe: dbg_v_valid = a second instruction co-issued with the
        -- U-pipe instruction now in EX (the Pentium's dual-issue); dbg_v_txt is that
        -- instruction, dbg_pairs is the running count of co-issued pairs.
        dbg_v_valid  : out std_logic;
        dbg_v_seq    : out std_logic_vector(15 downto 0);
        dbg_v_eip    : out std_logic_vector(31 downto 0);   -- the V instruction's address
        dbg_v_txt    : out std_logic_vector(8*DIS_CHARS-1 downto 0);
        dbg_pairs    : out std_logic_vector(15 downto 0);
        -- FSM state as ASCII text (MSB-first). View as ASCII in Surfer to read
        -- the actual state name, e.g. "FETCH_MODRM".
        dbg_state_name : out std_logic_vector(8*STATE_NAME_CHARS-1 downto 0);
        -- Branch Target Buffer contents for the viewer: 8 entries (2 sets x 4
        -- ways). Per entry i: tag (branch addr) at tag[32i+31:32i], target at
        -- tgt[32i+31:32i], and a meta byte {valid=bit0, ctr=bits[2:1]}.
        dbg_btb_tag  : out std_logic_vector(255 downto 0);
        dbg_btb_tgt  : out std_logic_vector(255 downto 0);
        dbg_btb_meta : out std_logic_vector(63 downto 0);
        -- Performance counters for the CPI report: branches predicted correctly
        -- vs. mispredicted (accuracy = correct/(correct+wrong)), and the running
        -- 32-bit count of co-issued U/V pairs.  (dbg_pairs above is the low 16.)
        dbg_btb_correct : out std_logic_vector(31 downto 0);
        dbg_btb_wrong   : out std_logic_vector(31 downto 0);
        dbg_pairs32     : out std_logic_vector(31 downto 0)
    );
end x86_cpu;

architecture superscalar of x86_cpu is

    type cpu_state_t is (
        S_IDLE,                     -- EX holds no instruction (a pipeline bubble)
        S_EXECUTE,
        S_LOAD, S_STORE, S_PUSH, S_POP, S_CALL_PUSH, S_RET_POP,
        S_PUSHA, S_POPA,
        S_INTA,                     -- interrupt-acknowledge cycle (get vector from PIC)
        S_INT_VEC, S_INT_PUSH,      -- read vector table entry; push EFLAGS, CS, EIP
        S_IRET_POP,                 -- pop EIP, CS, EFLAGS
        S_XCHG_R, S_XCHG_W,
        S_LIDT0, S_LIDT1, S_CMPX_R, S_CMPX_W, S_XMM_LD, S_XMM_ST,
        S_IN, S_OUT,
        S_MULDIV_WAIT,              -- multi-cycle latency hold for MUL/IMUL/DIV/IDIV
        S_HALT
    );
    signal state, next_state : cpu_state_t := S_IDLE;
    signal md_cnt : integer range 0 to 63 := 0;   -- MUL/DIV latency counter

    type regfile_t is array (0 to 7) of unsigned(31 downto 0);
    signal reg : regfile_t := (others => (others => '0'));

    type xmmfile_t is array (0 to 7) of std_logic_vector(127 downto 0);
    signal xmm : xmmfile_t := (others => (others => '0'));

    constant R_EAX : integer := 0;
    constant R_EBX : integer := 3;
    constant R_ESP : integer := 4;
    constant ZERO96 : std_logic_vector(95 downto 0) := (others => '0');
    -- CS selector pushed in an interrupt frame (flat code segment, as an OS sets up).
    constant CS_SEL : std_logic_vector(31 downto 0) := x"00000008";

    signal eip : unsigned(31 downto 0) := (others => '0');

    signal cf, pf, af, zf, sf, of_f : std_logic := '0';
    signal if_f       : std_logic := '0';     -- EFLAGS.IF (maskable interrupts enabled)
    signal sti_shadow : std_logic := '0';     -- 1 = the instruction after STI is running
    signal idtr_base : unsigned(31 downto 0) := (others => '0');

    -- Paging control registers. CR0.PG (bit 31) enables translation; CR3 holds
    -- the page-table base; CR2 latches the faulting linear address on a #PF.
    signal cr0 : unsigned(31 downto 0) := (others => '0');
    signal cr2 : unsigned(31 downto 0) := (others => '0');
    signal cr3 : unsigned(31 downto 0) := (others => '0');
    -- Start EIP of the current instruction (pushed by a fault so IRET restarts
    -- it). new_insn arms the capture: set in EXECUTE, consumed at the next fetch.
    signal ip_start : unsigned(31 downto 0) := (others => '0');
    signal new_insn : std_logic := '1';

    -- Decode latches
    signal ir0         : std_logic_vector(7 downto 0) := (others => '0');
    signal ir_0f       : std_logic := '0';
    signal pfx_lock    : std_logic := '0';
    signal pfx_66      : std_logic := '0';    -- operand-size prefix seen (decode)
    signal opsz16      : std_logic := '0';    -- ... latched for the post-EXECUTE states
    signal modrm       : std_logic_vector(7 downto 0) := (others => '0');
    signal oprnd       : std_logic_vector(31 downto 0) := (others => '0'); -- disp (or imm)
    signal imm_r       : std_logic_vector(31 downto 0) := (others => '0'); -- imm after a disp
    signal disp_n      : integer range 0 to 4 := 0;   -- displacement bytes of this insn
    signal operand_total : integer range 0 to 8 := 0;
    signal operand_idx   : integer range 0 to 8 := 0;
    signal q_idx       : integer range 0 to 8 := 0;   -- step counter for multi-cycle ops

    signal lo_tmp     : std_logic_vector(31 downto 0) := (others => '0'); -- 1st half of a split load
    signal vec_num    : unsigned(7 downto 0) := (others => '0');  -- vector being delivered
    signal exc_fault  : std_logic := '0';     -- 1 = fault: push ip_start, not EIP
    signal vec_target : unsigned(31 downto 0) := (others => '0');
    signal xchg_temp  : unsigned(31 downto 0) := (others => '0');
    signal desc0      : std_logic_vector(31 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- Decode helpers
    ----------------------------------------------------------------------------
    function bytesel(w : std_logic_vector(31 downto 0);
                     sel : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case to_integer(sel) is
            when 0 => return w(7  downto 0);
            when 1 => return w(15 downto 8);
            when 2 => return w(23 downto 16);
            when others => return w(31 downto 24);
        end case;
    end function;

    function is_prefix(op : std_logic_vector(7 downto 0)) return boolean is
    begin
        return op = x"F0" or op = x"66" or op = x"F3" or op = x"F2";
    end function;

    -- One-byte opcodes followed by a ModR/M byte.
    function has_modrm(op : std_logic_vector(7 downto 0)) return boolean is
    begin
        case op is
            when x"89" | x"8B" | x"88" | x"8A" | x"C6" | x"C7" |
                 x"01" | x"03" | x"09" | x"0B" | x"11" | x"13" | x"19" | x"1B" |
                 x"21" | x"23" | x"29" | x"2B" | x"31" | x"33" | x"39" | x"3B" |
                 x"85" | x"87" | x"D1" | x"81" | x"83" |
                 x"69" | x"6B" |                                 -- IMUL r,r/m,imm
                 x"C0" | x"C1" | x"D0" | x"D2" | x"D3" => return true;  -- shift/rotate
            when x"8D" => return true;                           -- LEA
            when x"F7" | x"F6" => return true;                   -- grp3 (TEST/NOT/NEG/MUL/IMUL)
            when x"FF" | x"FE" => return true;                   -- grp5/grp4 (INC/DEC r/m, ...)
            when x"00" | x"02" | x"08" | x"0A" | x"10" | x"12" | x"18" | x"1A" |
                 x"20" | x"22" | x"28" | x"2A" | x"30" | x"32" | x"38" | x"3A" |
                 x"80" | x"84" => return true;                   -- byte ALU / grp1 r/m8 / TEST r/m8
            when others => return false;
        end case;
    end function;

    -- The byte (8-bit operand) ALU opcodes ADD..CMP, both directions: op =
    -- 0x00 + (aluop<<3) + (dir<<1), with the size bit (bit 0) clear. dir (bit 1):
    -- 0 = r/m8 <- r/m8 op r8 (store direction), 1 = r8 <- r8 op r/m8 (load).
    function is_alu8(op : std_logic_vector(7 downto 0)) return boolean is
    begin
        case op is
            when x"00" | x"02" | x"08" | x"0A" | x"10" | x"12" | x"18" | x"1A" |
                 x"20" | x"22" | x"28" | x"2A" | x"30" | x"32" | x"38" | x"3A" =>
                return true;
            when others => return false;
        end case;
    end function;

    -- Immediate bytes of a one-byte opcode without ModR/M (66 shrinks imm32->imm16).
    function imm_len_op(op : std_logic_vector(7 downto 0); p66 : std_logic) return integer is
    begin
        case to_integer(unsigned(op)) is
            when 16#B8# to 16#BF# =>                          -- MOV r32/r16, imm
                if p66 = '1' then return 2; else return 4; end if;
            when 16#05# | 16#0D# | 16#15# | 16#1D# |
                 16#25# | 16#2D# | 16#35# | 16#3D# => return 4;   -- ALU EAX, imm32
            when 16#A0# to 16#A3# => return 4;                -- moffs (disp32)
            when 16#E8# | 16#E9#  => return 4;                -- CALL/JMP rel32
            when 16#68#           => return 4;                -- PUSH imm32
            when 16#B0# to 16#B7# => return 1;                -- MOV r8, imm8
            when 16#04# | 16#0C# | 16#14# | 16#1C# |
                 16#24# | 16#2C# | 16#34# | 16#3C# | 16#A8# => return 1;  -- ALU AL, imm8
            when 16#E4# to 16#E7# => return 1;                -- IN/OUT imm8 port
            when 16#CD# | 16#6A#  => return 1;                -- INT ib / PUSH imm8
            when 16#EB#           => return 1;                -- JMP rel8
            when 16#70# to 16#7F# => return 1;                -- Jcc rel8
            when others => return 0;
        end case;
    end function;

    -- Immediate bytes that follow the ModR/M (+disp) of a group opcode.
    function imm_len_grp(op : std_logic_vector(7 downto 0); is0f : std_logic;
                         p66 : std_logic; m : std_logic_vector(7 downto 0)) return integer is
    begin
        if is0f = '1' then return 0; end if;
        case op is
            when x"81" => return 4;
            when x"83" => return 1;
            when x"80" => return 1;                                           -- grp1 byte [m],imm8
            when x"C6" => return 1;
            when x"C7" => if p66 = '1' then return 2; else return 4; end if;
            when x"69" => if p66 = '1' then return 2; else return 4; end if;  -- IMUL r,r/m,imm32
            when x"6B" => return 1;                                           -- IMUL r,r/m,imm8
            when x"C0" | x"C1" => return 1;                                   -- shift r/m, imm8
            when x"F7" =>                                                     -- grp3: only TEST has imm
                if m(5 downto 3) = "000" or m(5 downto 3) = "001" then return 4; else return 0; end if;
            when x"F6" =>
                if m(5 downto 3) = "000" or m(5 downto 3) = "001" then return 1; else return 0; end if;
            when others => return 0;
        end case;
    end function;

    function disp_len(m : std_logic_vector(7 downto 0)) return integer is
    begin
        if m(7 downto 6) = "00" and m(2 downto 0) = "101" then return 4;
        elsif m(7 downto 6) = "01" then return 1;
        elsif m(7 downto 6) = "10" then return 4;
        else return 0; end if;
    end function;

    -- A SIB byte follows the ModR/M when it is a memory form with rm = 100.
    function has_sib(m : std_logic_vector(7 downto 0)) return boolean is
    begin
        return m(7 downto 6) /= "11" and m(2 downto 0) = "100";
    end function;

    -- Displacement length, SIB-aware: a SIB with mod=00 and base=101 carries a
    -- disp32 (the no-base, index-only form) instead of the plain rm=101 case.
    function disp_len_s(m, sib : std_logic_vector(7 downto 0)) return integer is
    begin
        if m(7 downto 6) = "01" then return 1;
        elsif m(7 downto 6) = "10" then return 4;
        elsif m(7 downto 6) = "00" then
            if has_sib(m) then
                if sib(2 downto 0) = "101" then return 4; else return 0; end if;
            elsif m(2 downto 0) = "101" then return 4;
            else return 0; end if;
        else return 0; end if;
    end function;

    -- Is this 0F opcode an SSE op we implement?
    --   28/29 = MOVAPS (aligned 128-bit move, no 66 prefix)
    --   6E/7E = MOVD, 6F/7F = MOVDQA (66-prefixed), FE = PADDD, EF = PXOR
    function is_sse(op : std_logic_vector(7 downto 0)) return boolean is
    begin
        case op is
            when x"28" | x"29" | x"6E" | x"6F" | x"7E" | x"7F" | x"FE" | x"EF" => return true;
            when others => return false;
        end case;
    end function;

    -- Number of 32-bit transfers for an SSE memory op (MOVD=1, everything
    -- else = a full 128-bit line = 4 dwords: MOVDQA and MOVAPS).
    function sse_words(op : std_logic_vector(7 downto 0)) return integer is
    begin
        if op = x"6E" or op = x"7E" then return 1; else return 4; end if;
    end function;

    -- Is the decoded instruction one this core implements? Anything else
    -- raises #UD (vector 6), exactly what a real x86 does for an opcode it
    -- does not recognise (e.g. UD2 = 0F 0B).
    function insn_valid(op : std_logic_vector(7 downto 0); is0f : std_logic;
                        m : std_logic_vector(7 downto 0); p66 : std_logic) return boolean is
        variable memf, sib, abs32 : boolean;
        variable rg : std_logic_vector(2 downto 0);
    begin
        memf  := m(7 downto 6) /= "11";
        sib   := memf and m(2 downto 0) = "100";
        abs32 := m(7 downto 6) = "00" and m(2 downto 0) = "101";
        rg    := m(5 downto 3);
        if is0f = '1' then
            case op is
                when x"1F" => return true;                           -- multi-byte NOP (0F 1F /0)
                when x"01" => return rg = "011" and abs32;          -- LIDT [disp32]
                when x"B1" => return abs32;                          -- CMPXCHG [disp32],r32
                when x"B6" | x"B7" => return true;                   -- MOVZX r32, r/m8 / r/m16
                when x"BE" | x"BF" => return true;                   -- MOVSX r32, r/m8 / r/m16
                when x"AF" => return true;                           -- IMUL r32, r/m32
                when x"20" | x"22" =>                                -- MOV r32<->CR0/2/3
                    return (not memf) and (rg = "000" or rg = "010" or rg = "011");
                when x"28" | x"29" | x"6E" | x"6F" | x"7E" | x"7F" | x"FE" | x"EF" =>
                    return (not memf) or abs32;                      -- SSE reg or [disp32]
                when others => return op(7 downto 4) = x"8" or op(7 downto 4) = x"9";  -- Jcc / SETcc
            end case;
        end if;
        if p66 = '1' then                -- 16-bit operand size: only these forms
            case to_integer(unsigned(op)) is
                when 16#B8# to 16#BF# | 16#89# | 16#8B# | 16#C7# | 16#A1# | 16#A3# |
                     16#E5# | 16#E7# | 16#ED# | 16#EF# |
                     16#90# => null;    -- 66 90 = xchg ax,ax, gcc's 2-byte NOP pad
                when others => return false;
            end case;
        end if;
        case to_integer(unsigned(op)) is
            when 16#90# | 16#F4# | 16#F8# | 16#F9# | 16#FA# | 16#FB# |
                 16#9C# | 16#9D# | 16#60# | 16#61# | 16#C3# | 16#CF# | 16#D7# |
                 16#E4# to 16#E7# | 16#EC# to 16#EF# |
                 16#B0# to 16#BF# | 16#40# to 16#5F# |
                 16#68# | 16#6A# | 16#E8# | 16#E9# | 16#EB# | 16#70# to 16#7F# |
                 16#CD# | 16#A0# to 16#A3# |
                 16#05# | 16#0D# | 16#25# | 16#2D# | 16#35# | 16#3D# |
                 16#04# | 16#0C# | 16#24# | 16#2C# | 16#34# | 16#3C# | 16#A8# => return true;
            when 16#88# | 16#89# | 16#8A# | 16#8B# => return true;   -- MOV r/m<->r (reg/mem/SIB)
            when 16#C6# | 16#C7# => return rg = "000";              -- MOV r/m, imm (reg/mem/SIB)
            when 16#01# | 16#03# | 16#09# | 16#0B# | 16#11# | 16#13# | 16#19# | 16#1B# |
                 16#21# | 16#23# | 16#29# | 16#2B# | 16#31# | 16#33# | 16#39# | 16#3B# |
                 16#85# | 16#81# | 16#83# => return true;      -- ALU reg + memory (incl SIB)
            when 16#69# | 16#6B# => return true;                    -- IMUL r32,r/m32,imm
            when 16#C1# | 16#D1# | 16#D3# =>                         -- shift/rotate r/m32
                return rg = "000" or rg = "001" or rg = "100" or rg = "101" or rg = "111";
            when 16#8D# => return memf;                             -- LEA r32, m (memory form)
            when 16#C9# => return true;                             -- LEAVE
            when 16#FF# => return rg = "000" or rg = "001";         -- INC/DEC r/m32
            when 16#98# | 16#99# => return true;                    -- CWDE / CDQ
            when 16#F7# => return true;                             -- grp3: TEST/NOT/NEG/MUL/IMUL/DIV/IDIV
            when 16#87# => return abs32 and rg = "000";              -- XCHG [disp32],EAX
            when 16#00# | 16#02# | 16#08# | 16#0A# | 16#10# | 16#12# | 16#18# | 16#1A# |
                 16#20# | 16#22# | 16#28# | 16#2A# | 16#30# | 16#32# | 16#38# | 16#3A# |
                 16#80# | 16#84# => return true;    -- byte ALU reg/mem (incl SIB), grp1 r/m8, TEST
            when others => return false;
        end case;
    end function;

    function parity8(b : std_logic_vector(7 downto 0)) return std_logic is
        variable p : std_logic := '0';
    begin
        for i in 0 to 7 loop p := p xor b(i); end loop;
        return not p;
    end function;

    function cond_true(cc : std_logic_vector(3 downto 0);
                       i_zf, i_cf, i_sf, i_of, i_pf : std_logic) return boolean is
    begin
        case cc is
            when x"0" => return i_of = '1';
            when x"1" => return i_of = '0';
            when x"2" => return i_cf = '1';
            when x"3" => return i_cf = '0';
            when x"4" => return i_zf = '1';
            when x"5" => return i_zf = '0';
            when x"6" => return (i_cf = '1') or (i_zf = '1');
            when x"7" => return (i_cf = '0') and (i_zf = '0');
            when x"8" => return i_sf = '1';
            when x"9" => return i_sf = '0';
            when x"A" => return i_pf = '1';
            when x"B" => return i_pf = '0';
            when x"C" => return i_sf /= i_of;
            when x"D" => return i_sf = i_of;
            when x"E" => return (i_zf = '1') or (i_sf /= i_of);
            when others => return (i_zf = '0') and (i_sf = i_of);
        end case;
    end function;

    function add32(a, b : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin
        return std_logic_vector(unsigned(a) + unsigned(b));
    end function;

    function sext8(v : std_logic_vector(31 downto 0)) return unsigned is
        variable r : unsigned(31 downto 0);
    begin
        r := unsigned(v);
        if v(7) = '1' then r(31 downto 8) := (others => '1');
        else r(31 downto 8) := (others => '0'); end if;
        return r;
    end function;

    -- x86 8-bit register view: 0..3 = AL CL DL BL (low byte), 4..7 = AH CH DH BH.
    function get_r8(rf : regfile_t; n : integer) return std_logic_vector is
    begin
        if n < 4 then return std_logic_vector(rf(n)(7 downto 0));
        else          return std_logic_vector(rf(n - 4)(15 downto 8)); end if;
    end function;

    -- General ModR/M effective address: base register + displacement.
    --   mod=00,rm=101 -> [disp32]      (absolute)
    --   mod=00        -> [reg]
    --   mod=01        -> [reg + disp8] (sign-extended)   e.g. [EBP+8] frames
    --   mod=10        -> [reg + disp32]
    function ea_of(m, sib : std_logic_vector(7 downto 0); opd : std_logic_vector(31 downto 0);
                   rf : regfile_t) return std_logic_vector is
        variable rm, bas, idx, scl : integer;
        variable base_v, index_v, disp_v : unsigned(31 downto 0);
    begin
        rm := to_integer(unsigned(m(2 downto 0)));
        if has_sib(m) then                            -- [base + index*scale + disp]
            bas := to_integer(unsigned(sib(2 downto 0)));
            idx := to_integer(unsigned(sib(5 downto 3)));
            scl := to_integer(unsigned(sib(7 downto 6)));
            if m(7 downto 6) = "00" and sib(2 downto 0) = "101" then
                base_v := (others => '0');            -- no base (disp32 + index)
            else
                base_v := rf(bas);
            end if;
            if sib(5 downto 3) = "100" then
                index_v := (others => '0');           -- no index (esp cannot be an index)
            else
                index_v := shift_left(rf(idx), scl);
            end if;
            if m(7 downto 6) = "01" then disp_v := sext8(opd);
            elsif m(7 downto 6) = "10" then disp_v := unsigned(opd);
            elsif m(7 downto 6) = "00" and sib(2 downto 0) = "101" then disp_v := unsigned(opd);
            else disp_v := (others => '0');
            end if;
            return std_logic_vector(base_v + index_v + disp_v);
        end if;
        if m(7 downto 6) = "00" and m(2 downto 0) = "101" then
            return opd;
        elsif m(7 downto 6) = "00" then
            return std_logic_vector(rf(rm));
        elsif m(7 downto 6) = "01" then
            return std_logic_vector(rf(rm) + sext8(opd));
        else
            return std_logic_vector(rf(rm) + unsigned(opd));
        end if;
    end function;

    ----------------------------------------------------------------------------
    -- Pipeline helpers
    ----------------------------------------------------------------------------
    type flags_t is record
        cf, zf, sf, of_f, pf, af : std_logic;
    end record;

    -- The flags a flag-setting "simple" op WOULD produce, computed without
    -- touching the architectural flag signals. This lets the V pipe's paired
    -- Jcc test the result of the U pipe's compare in the same clock (the
    -- Pentium's cmp+jcc pairing). Ops that leave a flag alone -- MOV/NOP (all),
    -- rotates (SZP), INC/DEC (CF) -- carry the current value through.
    function alu_flags(op : std_logic_vector(7 downto 0); is0f : std_logic;
                       m : std_logic_vector(7 downto 0); opd : std_logic_vector(31 downto 0);
                       rf : regfile_t; cur : flags_t) return flags_t is
        variable f : flags_t := cur;
        variable rmi, rgi : integer range 0 to 7;
        variable a, b, imm, res : unsigned(31 downto 0);
        variable dg : std_logic_vector(2 downto 0);

        procedure szp(v : unsigned(31 downto 0)) is
        begin
            if v = 0 then f.zf := '1'; else f.zf := '0'; end if;
            f.sf := v(31); f.pf := parity8(std_logic_vector(v(7 downto 0)));
        end procedure;
        procedure szp8(v : unsigned(7 downto 0)) is
        begin
            if v = 0 then f.zf := '1'; else f.zf := '0'; end if;
            f.sf := v(7); f.pf := parity8(std_logic_vector(v));
        end procedure;
        procedure fadd(x, y : unsigned(31 downto 0); ci : std_logic) is
            variable w : unsigned(32 downto 0); variable nn : unsigned(4 downto 0);
        begin
            w := ('0'&x)+('0'&y); nn := ('0'&x(3 downto 0))+('0'&y(3 downto 0));
            if ci='1' then w := w+1; nn := nn+1; end if;
            f.cf := w(32); f.of_f := (x(31) xnor y(31)) and (w(31) xor x(31)); f.af := nn(4);
            szp(w(31 downto 0));
        end procedure;
        procedure fsub(x, y : unsigned(31 downto 0); bi : std_logic) is
            variable w : unsigned(32 downto 0); variable nn : unsigned(4 downto 0);
        begin
            w := ('0'&x)-('0'&y); nn := ('0'&x(3 downto 0))-('0'&y(3 downto 0));
            if bi='1' then w := w-1; nn := nn-1; end if;
            f.cf := w(32); f.of_f := (x(31) xor y(31)) and (w(31) xor x(31)); f.af := nn(4);
            szp(w(31 downto 0));
        end procedure;
        procedure flog(v : unsigned(31 downto 0)) is
        begin
            f.cf := '0'; f.of_f := '0'; f.af := '0'; szp(v);
        end procedure;
        procedure fsub8(x, y : unsigned(7 downto 0)) is
            variable w : unsigned(8 downto 0);
        begin
            w := ('0'&x)-('0'&y);
            f.cf := w(8); f.of_f := (x(7) xor y(7)) and (w(7) xor x(7)); szp8(w(7 downto 0));
        end procedure;
        procedure flog8(v : unsigned(7 downto 0)) is
        begin
            f.cf := '0'; f.of_f := '0'; f.af := '0'; szp8(v);
        end procedure;
    begin
        rmi := to_integer(unsigned(m(2 downto 0)));
        rgi := to_integer(unsigned(m(5 downto 3)));
        if is0f = '1' then return f; end if;            -- MOVZX: no flag change
        case to_integer(unsigned(op)) is
            when 16#01# => fadd(rf(rmi), rf(rgi), '0');
            when 16#03# => fadd(rf(rgi), rf(rmi), '0');
            when 16#29# | 16#39# => fsub(rf(rmi), rf(rgi), '0');
            when 16#21# | 16#85# => flog(rf(rmi) and rf(rgi));
            when 16#09# => flog(rf(rmi) or  rf(rgi));
            when 16#31# => flog(rf(rmi) xor rf(rgi));
            when 16#05# => fadd(rf(0), unsigned(opd), '0');
            when 16#2D# | 16#3D# => fsub(rf(0), unsigned(opd), '0');
            when 16#25# => flog(rf(0) and unsigned(opd));
            when 16#0D# => flog(rf(0) or  unsigned(opd));
            when 16#35# => flog(rf(0) xor unsigned(opd));
            when 16#04# =>                                  -- ADD AL, imm8
                a := resize(rf(0)(7 downto 0), 32); b := resize(unsigned(opd(7 downto 0)), 32);
                res := a + b;
                f.cf := '1' when res > 255 else '0';
                f.of_f := (rf(0)(7) xnor opd(7)) and (res(7) xor rf(0)(7));
                f.af := '1' when (a(3 downto 0) + b(3 downto 0)) > 15 else '0';
                szp8(res(7 downto 0));
            when 16#2C# | 16#3C# => fsub8(rf(0)(7 downto 0), unsigned(opd(7 downto 0)));
            when 16#0C# => flog8(rf(0)(7 downto 0) or  unsigned(opd(7 downto 0)));
            when 16#34# => flog8(rf(0)(7 downto 0) xor unsigned(opd(7 downto 0)));
            when 16#24# | 16#A8# => flog8(rf(0)(7 downto 0) and unsigned(opd(7 downto 0)));
            when 16#81# | 16#83# =>
                dg := m(5 downto 3); a := rf(rmi); imm := unsigned(opd);
                if op = x"83" and opd(7) = '1' then imm(31 downto 8) := (others => '1'); end if;
                case dg is
                    when "000" => fadd(a, imm, '0');
                    when "001" => flog(a or imm);
                    when "010" => fadd(a, imm, cur.cf);         -- ADC
                    when "011" => fsub(a, imm, cur.cf);         -- SBB
                    when "100" => flog(a and imm);
                    when "101" => fsub(a, imm, '0');
                    when "110" => flog(a xor imm);
                    when others => fsub(a, imm, '0');           -- CMP
                end case;
            when 16#40# to 16#47# =>                            -- INC (CF preserved)
                fadd(rf(to_integer(unsigned(op(2 downto 0)))), to_unsigned(1, 32), '0');
                f.cf := cur.cf;
            when 16#48# to 16#4F# =>                            -- DEC (CF preserved)
                fsub(rf(to_integer(unsigned(op(2 downto 0)))), to_unsigned(1, 32), '0');
                f.cf := cur.cf;
            when 16#D1# =>
                a := rf(rmi); dg := m(5 downto 3);
                case dg is
                    when "100" => res := a(30 downto 0) & '0';     f.cf := a(31); f.of_f := a(31) xor res(31); szp(res);
                    when "101" => res := '0' & a(31 downto 1);     f.cf := a(0);  f.of_f := a(31);             szp(res);
                    when "111" => res := a(31) & a(31 downto 1);   f.cf := a(0);  f.of_f := '0';               szp(res);
                    when "000" => res := a(30 downto 0) & a(31);   f.cf := a(31); f.of_f := a(31) xor res(31);  -- ROL: no SZP
                    when others => res := a(0) & a(31 downto 1);   f.cf := a(0);  f.of_f := res(31) xor res(30);-- ROR
                end case;
            when others => null;                                -- MOV / NOP: no change
        end case;
        return f;
    end function;

    -- Registers an instruction writes (bit n = register n), for the AGI check.
    function dest_mask(op : std_logic_vector(7 downto 0); is0f : std_logic;
                       m : std_logic_vector(7 downto 0)) return std_logic_vector is
        variable r : std_logic_vector(7 downto 0) := (others => '0');
        variable n, rmi, rgi : integer range 0 to 7;
        variable regf : boolean;
    begin
        n    := to_integer(unsigned(op(2 downto 0)));
        rmi  := to_integer(unsigned(m(2 downto 0)));
        rgi  := to_integer(unsigned(m(5 downto 3)));
        regf := m(7 downto 6) = "11";
        if is0f = '1' then
            case op is
                when x"B6" | x"B7" | x"BE" | x"BF" => r(rgi) := '1';  -- MOVZX / MOVSX
                when x"AF" => r(rgi) := '1';                  -- IMUL r32, r/m32
                when x"20" => r(rmi) := '1';                  -- MOV r32, CRn
                when x"B1" => r(0) := '1';                    -- CMPXCHG may load EAX
                when x"7E" => if regf then r(rmi) := '1'; end if;
                when others =>
                    if op(7 downto 4) = x"9" and regf then r(rmi mod 4) := '1'; end if;  -- SETcc r/m8
            end case;
            return r;
        end if;
        case to_integer(unsigned(op)) is
            when 16#B0# to 16#B7# => r(n mod 4) := '1';
            when 16#B8# to 16#BF# | 16#40# to 16#4F# => r(n) := '1';
            when 16#58# to 16#5F# => r(n) := '1'; r(4) := '1';
            when 16#50# to 16#57# | 16#68# | 16#6A# | 16#9C# | 16#9D# | 16#60# |
                 16#E8# | 16#C3# | 16#CD# | 16#CF# => r(4) := '1';
            when 16#61# => r := (others => '1');
            when 16#88# | 16#C6# => if regf then r(rmi mod 4) := '1'; end if;
            when 16#89# | 16#C7# => if regf then r(rmi) := '1'; end if;
            when 16#8A# => r(rgi mod 4) := '1';
            -- load-direction ALU (r <- r op r/m) and MOV r,r/m write the reg operand
            when 16#8B# | 16#03# | 16#0B# | 16#13# | 16#1B# | 16#23# | 16#2B# | 16#33# |
                 16#69# | 16#6B# | 16#8D# =>                     -- + IMUL r,r/m,imm; LEA
                r(rgi) := '1';
            when 16#C9# => r(4) := '1'; r(5) := '1';            -- LEAVE writes ESP, EBP
            -- store-direction ALU: the register form writes r/m; the memory form
            -- writes memory (no register), so only mark a reg when regf.
            when 16#01# | 16#09# | 16#11# | 16#19# | 16#21# | 16#29# | 16#31# =>
                if regf then r(rmi) := '1'; end if;
            when 16#C0# | 16#C1# | 16#D0# | 16#D1# | 16#D2# | 16#D3# | 16#FF# =>  -- shift/INC/DEC r/m
                if regf then r(rmi) := '1'; end if;
            when 16#81# | 16#83# => if regf and m(5 downto 3) /= "111" then r(rmi) := '1'; end if;
            when 16#F7# =>                                   -- grp3
                case m(5 downto 3) is
                    when "010" | "011" => if regf then r(rmi) := '1'; end if;  -- NOT/NEG write r/m
                    when "100" | "101" | "110" | "111" => r(0) := '1'; r(2) := '1';  -- MUL/DIV -> EDX:EAX
                    when others => null;                                       -- TEST: flags only
                end case;
            when 16#98# => r(0) := '1';                      -- CWDE writes EAX
            when 16#99# => r(2) := '1';                      -- CDQ writes EDX
            when 16#05# | 16#2D# | 16#25# | 16#0D# | 16#35# | 16#04# | 16#0C# |
                 16#24# | 16#2C# | 16#34# | 16#A0# | 16#A1# | 16#D7# |
                 16#E4# | 16#E5# | 16#EC# | 16#ED# | 16#87# => r(0) := '1';
            -- byte ALU writes an 8-bit register: r8 index i touches physical
            -- register (i mod 4) -- AL/AH share EAX, etc. (same as MOV r8 above).
            when 16#02# | 16#0A# | 16#12# | 16#1A# | 16#22# | 16#2A# | 16#32# =>
                r(rgi mod 4) := '1';                             -- load-dir (not CMP 3A)
            when 16#00# | 16#08# | 16#10# | 16#18# | 16#20# | 16#28# | 16#30# =>
                if regf then r(rmi mod 4) := '1'; end if;        -- store-dir (not CMP 38)
            when 16#80# =>
                if regf and m(5 downto 3) /= "111" then r(rmi mod 4) := '1'; end if;  -- grp1 r/m8 (not CMP)
            when others => null;                                 -- 38/3A CMP, 84 TEST: flags only
        end case;
        return r;
    end function;

    -- Registers an instruction needs in D2 for ADDRESS GENERATION.
    function use_mask(op : std_logic_vector(7 downto 0); is0f : std_logic;
                      m, sib : std_logic_vector(7 downto 0)) return std_logic_vector is
        variable r : std_logic_vector(7 downto 0) := (others => '0');
        variable has : boolean;
    begin
        if is0f = '0' and op = x"D7" then                     -- XLAT: [EBX + AL]
            r(3) := '1'; r(0) := '1';
            return r;
        end if;
        has := (is0f = '1' and op(7 downto 4) /= x"8") or (is0f = '0' and has_modrm(op));
        if has and m(7 downto 6) /= "11" then
            if has_sib(m) then                                -- SIB: base + index
                if not (m(7 downto 6) = "00" and sib(2 downto 0) = "101") then
                    r(to_integer(unsigned(sib(2 downto 0)))) := '1';
                end if;
                if sib(5 downto 3) /= "100" then
                    r(to_integer(unsigned(sib(5 downto 3)))) := '1';
                end if;
            elsif not (m(7 downto 6) = "00" and m(2 downto 0) = "101") then
                r(to_integer(unsigned(m(2 downto 0)))) := '1';  -- the base register
            end if;
        end if;
        return r;
    end function;

    -- A memory-form ALU op whose result is written BACK to memory (so it needs
    -- a store after the load): the store-direction ADD..XOR and grp1 (not CMP,
    -- which is flags-only, nor TEST, nor the load-direction forms r <- r op [m]).
    function mem_alu_wb(op, m : std_logic_vector(7 downto 0)) return boolean is
    begin
        if m(7 downto 6) = "11" then return false; end if;
        case op is
            when x"01" | x"09" | x"11" | x"19" | x"21" | x"29" | x"31" => return true;
            -- byte store-direction ALU (r/m8 <- r/m8 op r8), ADD..XOR but not CMP/TEST
            when x"00" | x"08" | x"10" | x"18" | x"20" | x"28" | x"30" => return true;
            when x"81" | x"83" | x"80" => return m(5 downto 3) /= "111";  -- grp1 except CMP
            when x"C1" | x"D1" | x"D3" => return true;                 -- shift r/m, * (RMW)
            when x"FF" => return m(5 downto 3) = "000" or m(5 downto 3) = "001";  -- INC/DEC r/m
            when x"F7" => return m(5 downto 3) = "010" or m(5 downto 3) = "011";  -- NOT/NEG r/m
            when others => return false;
        end case;
    end function;

    -- Extra EX cycles a multiply/divide stalls for, so the pipeline view and the
    -- CPI report show the real Pentium (P54C) latencies instead of 1 cycle. The
    -- result is computed in the first EX/LOAD cycle; these are the hold cycles
    -- that follow (total = this + 1). 0 for everything that is not MUL/IMUL/DIV.
    function muldiv_wait(op : std_logic_vector(7 downto 0); is0f : std_logic;
                         m : std_logic_vector(7 downto 0)) return integer is
    begin
        if is0f = '1' then
            if op = x"AF" then return 9; else return 0; end if;   -- IMUL r,r/m  (~10)
        end if;
        case op is
            when x"69" | x"6B" => return 9;                       -- IMUL r,r/m,imm (~10)
            when x"F7" =>
                case m(5 downto 3) is
                    when "100" => return 10;                      -- MUL  (~11)
                    when "101" => return 9;                       -- IMUL (~10)
                    when "110" => return 40;                      -- DIV  (~41)
                    when "111" => return 45;                      -- IDIV (~46)
                    when others => return 0;                      -- TEST/NOT/NEG
                end case;
            when others => return 0;
        end case;
    end function;

    -- First EX micro-state. Instructions whose first action is a memory access
    -- start their bus cycle at once (1-cycle loads/stores/push/pop, as on the
    -- 486); everything else starts in EXECUTE.
    function ex_entry(op : std_logic_vector(7 downto 0); is0f : std_logic;
                      m : std_logic_vector(7 downto 0); p66 : std_logic) return cpu_state_t is
        variable memf : boolean;
    begin
        if not insn_valid(op, is0f, m, p66) then return S_EXECUTE; end if;   -- -> #UD
        memf := m(7 downto 6) /= "11";
        if is0f = '1' then
            case op is
                when x"01" => return S_LIDT0;
                when x"B1" => return S_CMPX_R;
                when x"B6" | x"B7" | x"BE" | x"BF" => if memf then return S_LOAD; end if;  -- MOVZX/MOVSX
                when x"AF" => if memf then return S_LOAD; end if;    -- IMUL r32,[m]
                when x"28" | x"6E" | x"6F" => if memf then return S_XMM_LD; end if;
                when x"29" | x"7E" | x"7F" => if memf then return S_XMM_ST; end if;
                when others =>
                    if op(7 downto 4) = x"9" and memf then return S_STORE; end if;  -- SETcc [m8]
            end case;
            return S_EXECUTE;
        end if;
        case op is
            when x"A0" | x"A1" | x"D7" => return S_LOAD;
            when x"A2" | x"A3" => return S_STORE;
            when x"8A" | x"8B" => if memf then return S_LOAD; end if;
            when x"88" | x"89" | x"C6" | x"C7" => if memf then return S_STORE; end if;
            -- ALU with a memory operand: a single load (then a store back if RMW).
            -- Routing them here (not S_EXECUTE) also keeps simple_u from pairing them.
            when x"01" | x"03" | x"09" | x"0B" | x"11" | x"13" | x"19" | x"1B" |
                 x"21" | x"23" | x"29" | x"2B" | x"31" | x"33" | x"39" | x"3B" |
                 x"85" | x"81" | x"83" |
                 x"00" | x"02" | x"08" | x"0A" | x"10" | x"12" | x"18" | x"1A" |
                 x"20" | x"22" | x"28" | x"2A" | x"30" | x"32" | x"38" | x"3A" |
                 x"80" | x"84" |                                    -- byte ALU / grp1 r/m8 / TEST r/m8
                 x"69" | x"6B" | x"C1" | x"D1" | x"D3" | x"FF" | x"F7" =>  -- +grp3 (TEST/NOT/NEG/MUL/DIV)
                if memf then return S_LOAD; end if;
            when x"50" | x"51" | x"52" | x"53" | x"54" | x"55" | x"56" | x"57" |
                 x"68" | x"6A" | x"9C" => return S_PUSH;
            when x"58" | x"59" | x"5A" | x"5B" | x"5C" | x"5D" | x"5E" | x"5F" |
                 x"9D" | x"C9" => return S_POP;                 -- POP / POPFD / LEAVE
            when x"60" => return S_PUSHA;
            when x"61" => return S_POPA;
            when x"E8" => return S_CALL_PUSH;
            when x"C3" => return S_RET_POP;
            when x"CF" => return S_IRET_POP;
            when x"87" => return S_XCHG_R;
            when x"E4" | x"E5" | x"EC" | x"ED" => return S_IN;
            when x"E6" | x"E7" | x"EE" | x"EF" => return S_OUT;
            when others => null;
        end case;
        return S_EXECUTE;
    end function;

    -- Instructions after which the pipeline drains and refetches: control
    -- transfers resolved late (CALL RET INT IRET), changes to IF (CLI STI
    -- POPFD: interrupts are re-checked with the new IF) and MOV CRn (paging).
    function drains(op : std_logic_vector(7 downto 0); is0f : std_logic) return std_logic is
    begin
        if is0f = '1' then
            if op = x"22" then return '1'; else return '0'; end if;
        end if;
        case op is
            when x"E8" | x"C3" | x"CD" | x"CF" | x"FA" | x"FB" | x"9D" => return '1';
            when others => return '0';
        end case;
    end function;

    function sname12(s : string) return std_logic_vector is
        variable r : std_logic_vector(95 downto 0);
        variable ch : integer;
    begin
        for i in 0 to 11 loop
            if i < s'length then ch := character'pos(s(s'low + i)); else ch := 32; end if;
            r(95 - 8*i downto 88 - 8*i) := std_logic_vector(to_unsigned(ch, 8));
        end loop;
        return r;
    end function;

    -- Pack a state name into a STATE_NAME_CHARS-char ASCII vector (space padded,
    -- MSB-first) so the FSM state is readable as text in Surfer's ASCII view.
    function sname(s : string) return std_logic_vector is
        variable r  : std_logic_vector(8*STATE_NAME_CHARS-1 downto 0) := (others => '0');
        variable ch : integer;
    begin
        for i in 0 to STATE_NAME_CHARS-1 loop
            if i < s'length then ch := character'pos(s(s'low + i));
            else                 ch := character'pos(' ');
            end if;
            r(8*STATE_NAME_CHARS-1 - i*8 downto 8*(STATE_NAME_CHARS-1) - i*8)
                := std_logic_vector(to_unsigned(ch, 8));
        end loop;
        return r;
    end function;

    signal is_bus    : boolean;   -- current state drives the memory bus
    signal ud        : std_logic; -- decoded instruction is not implemented (#UD)
    signal take_irq  : std_logic; -- accept INTR at this instruction boundary
    signal ea        : std_logic_vector(31 downto 0);  -- data effective address
    signal msize     : std_logic_vector(1 downto 0);   -- data access: 00 b / 01 w / 10 d
    signal ea_k      : integer range 0 to 3;           -- byte offset of ea in its dword
    signal ea_al     : unsigned(31 downto 0);          -- ea rounded down to its dword
    signal split     : std_logic;                      -- access straddles two dwords
    signal ldv       : std_logic_vector(31 downto 0);  -- load value, lanes aligned
    signal rmw_res   : unsigned(31 downto 0) := (others => '0');  -- RMW ALU result to store
    signal immv      : std_logic_vector(31 downto 0);  -- immediate of a ModR/M insn
    signal eflags_v  : std_logic_vector(31 downto 0);  -- architectural EFLAGS image
    signal dis       : dis_table := load_disasm(DISASM_FILE);
    -- Whether a disassembly table was supplied. When it is not (e.g. the SMP
    -- coherency demo), the V-pipe text tap is held constant so it adds no
    -- waveform transitions.
    constant HAVE_DIS : boolean := DISASM_FILE'length > 0;

    ----------------------------------------------------------------------------
    -- Front end: PF (prefetch queue), D1 (length decode), D2 (address gen.)
    ----------------------------------------------------------------------------
    constant PQ_SIZE : integer := 16;                    -- prefetch-queue bytes
    type pq_t is array (0 to PQ_SIZE - 1) of std_logic_vector(7 downto 0);
    signal pq         : pq_t := (others => (others => '0'));
    signal pq_cnt     : integer range 0 to PQ_SIZE := 0;
    signal pq_eip     : unsigned(31 downto 0) := (others => '0');  -- address of pq(0)
    signal fetch_addr : unsigned(31 downto 0) := (others => '0');  -- next byte to prefetch
    signal pf_wait    : std_logic := '0';     -- a prefetch is waiting for `ready`
    signal pf_cur     : unsigned(31 downto 0) := (others => '0');  -- ... at this address
    signal pf_discard : std_logic := '0';     -- ... and was flushed: drop its data
    signal pf_fault   : std_logic := '0';     -- prefetch hit a not-present page
    signal pf_fault_addr : unsigned(31 downto 0) := (others => '0');

    -- A decoded instruction travelling down the pipeline.
    type insn_t is record
        valid  : std_logic;
        eip    : unsigned(31 downto 0);   -- its first byte
        nxt    : unsigned(31 downto 0);   -- the next sequential instruction
        ir0    : std_logic_vector(7 downto 0);
        is0f   : std_logic;
        p66    : std_logic;
        plock  : std_logic;
        modrm  : std_logic_vector(7 downto 0);
        sib    : std_logic_vector(7 downto 0);    -- scale/index/base byte (when rm=100)
        oprnd  : std_logic_vector(31 downto 0);   -- displacement, or immediate
        imm_r  : std_logic_vector(31 downto 0);   -- immediate after a displacement
        disp_n : integer range 0 to 4;
        pfault : std_logic;               -- its bytes could not be fetched (#PF)
        seq    : unsigned(15 downto 0);   -- program-order tag (pipeline chart)
        pred_tk  : std_logic;             -- BTB predicted this branch taken (speculated)
        pred_tgt : unsigned(31 downto 0); -- ... to this target
    end record;
    constant NO_INSN : insn_t := ('0', (others => '0'), (others => '0'), x"00", '0', '0', '0',
                                  x"00", x"00", (others => '0'), (others => '0'), 0, '0', (others => '0'),
                                  '0', (others => '0'));
    signal d1      : insn_t;                  -- decoded at the queue head (combinational)
    signal d1_ok   : std_logic;               -- ... all its bytes are in the queue
    signal d1_len  : integer range 0 to PQ_SIZE;
    signal d2      : insn_t := NO_INSN;       -- D2 stage register
    signal wb      : insn_t := NO_INSN;       -- WB stage register
    signal wb_irq  : std_logic := '0';        -- WB holds an interrupt delivery
    signal seq_ctr : unsigned(15 downto 0) := (others => '0');
    signal ea_d2   : std_logic_vector(31 downto 0);                 -- D2's address
    signal ex_ea   : std_logic_vector(31 downto 0) := (others => '0'); -- ... latched for EX
    signal ex_seq  : unsigned(15 downto 0) := (others => '0');
    signal ex_irq  : std_logic := '0';        -- EX is delivering a hardware interrupt

    ----------------------------------------------------------------------------
    -- Pipeline control
    ----------------------------------------------------------------------------
    type owner_t is (BUS_NONE, BUS_EX, BUS_PF);
    signal owner      : owner_t;              -- who drives the memory bus this cycle
    signal owner_ex   : boolean;
    signal ex_bus_ok  : boolean;              -- EX owns the bus and it is ready
    signal pf_req     : boolean;              -- PF owns the bus this cycle
    signal pf_addr_now : unsigned(31 downto 0);
    signal ex_nxt     : cpu_state_t;          -- EX state after this cycle (S_IDLE = done)
    signal ex_done    : boolean;              -- the EX instruction completes this cycle
    signal ex_drain   : std_logic := '0';     -- ... and must be followed by a refetch
    signal ex_first   : std_logic := '0';     -- first EX cycle of this instruction
    signal redir_pending : std_logic := '0';  -- flush and refetch from EIP this cycle
    signal refill     : std_logic := '0';     -- the front end is refilling after a flush
    signal br_taken   : boolean;              -- Jcc/JMP in EX is taken
    signal br_target  : unsigned(31 downto 0);
    signal flush_now  : boolean;
    signal boundary_ok : boolean;             -- EX can start a new instruction now
    signal take_irq_now : boolean;
    signal ex_accept  : boolean;              -- D2 -> EX this cycle
    signal agi        : boolean;              -- address generation interlock
    signal d2_take    : boolean;              -- D1 -> D2 this cycle
    signal stall_code : std_logic_vector(2 downto 0);
    signal bubble_why : std_logic_vector(2 downto 0) := "100";   -- why EX is empty
    signal ex_addr, ex_dout : std_logic_vector(31 downto 0);
    signal ex_we      : std_logic;
    signal ex_be      : std_logic_vector(3 downto 0);
    signal ex_occ     : std_logic;            -- EX holds an instruction

    ----------------------------------------------------------------------------
    -- Superscalar V pipe (the Pentium's second integer pipe).
    --
    -- Faithful to Alpert & Avnon Figure 5: the front end decodes TWO
    -- consecutive instructions (I1 at the queue head, I2 right behind it) and
    -- co-issues them to the U and V pipes when the issue rule holds:
    --   * both are "simple" (directly executed, single EX cycle);
    --   * I1 is not a jump;
    --   * I1's destination register is neither a source nor the destination
    --     of I2 (no read-after-write or write-after-write);
    --   * the barrel shifter and flag-reading ops (ADC/SBB) run in U only, so
    --     I2 is restricted to the plain register ALU / MOV set.
    -- The pair executes in one clock; the V result is written back in program
    -- order (after U) in the same EX cycle, so pairing changes timing, never
    -- the architectural result.
    ----------------------------------------------------------------------------
    type decoded_t is record
        insn : insn_t;
        len  : integer range 0 to PQ_SIZE;
        ok   : std_logic;
    end record;

    -- Decode the instruction that starts at q(base): the same length/field
    -- decode as D1, parameterised by a start offset so it can also decode the
    -- second instruction of a candidate pair. (The #PF-on-prefetch path lives
    -- only in d1_proc, for the real D1 head.)
    function decode_one(q : pq_t; cnt : integer; base : integer;
                        eip0 : unsigned(31 downto 0); sq : unsigned(15 downto 0))
        return decoded_t is
        variable i, dl, il, n : integer range 0 to 99;
        variable av : integer;          -- bytes available from base (may clamp to 0)
        variable p66, plk, is0f : std_logic;
        variable op, m, sb : std_logic_vector(7 downto 0);
        variable r  : insn_t;
        variable ok, short : boolean;
        variable res : decoded_t;
    begin
        r := NO_INSN; i := 0; p66 := '0'; plk := '0'; is0f := '0';
        op := x"00"; m := x"00"; sb := x"00"; dl := 0; il := 0; short := false;
        av := cnt - base;
        if av < 0 then av := 0; end if;
        if av > 99 then av := 99; end if;
        while i < 4 and i < av and base + i < PQ_SIZE and is_prefix(q(base + i)) loop
            if q(base + i) = x"66" then p66 := '1'; end if;
            if q(base + i) = x"F0" then plk := '1'; end if;
            i := i + 1;
        end loop;
        if i < av and base + i < PQ_SIZE and q(base + i) = x"0F" then
            is0f := '1';
            if i + 1 < av and base + i + 1 < PQ_SIZE then op := q(base + i + 1); else short := true; end if;
            i := i + 2;
        elsif i < av and base + i < PQ_SIZE then
            op := q(base + i);
            i := i + 1;
        else
            short := true;
        end if;
        if not short then
            if (is0f = '1' and op(7 downto 4) /= x"8") or (is0f = '0' and has_modrm(op)) then
                if i < av and base + i < PQ_SIZE then
                    m := q(base + i); i := i + 1;
                    if has_sib(m) then                      -- consume the SIB byte
                        if i < av and base + i < PQ_SIZE then sb := q(base + i); i := i + 1;
                        else short := true; end if;
                    end if;
                    dl := disp_len_s(m, sb); il := imm_len_grp(op, is0f, p66, m);
                else
                    short := true;
                end if;
            elsif is0f = '1' then
                il := 4;
            else
                il := imm_len_op(op, p66);
            end if;
        end if;
        n  := i + dl + il;
        ok := (not short) and n <= av;
        if ok then
            r.valid := '1'; r.eip := eip0; r.nxt := eip0 + n;
            r.ir0 := op; r.is0f := is0f; r.p66 := p66; r.plock := plk;
            r.modrm := m; r.sib := sb; r.disp_n := dl; r.seq := sq;
            for k in 0 to 3 loop
                if dl > 0 then
                    if k < dl and base + i + k < PQ_SIZE then r.oprnd(8*k+7 downto 8*k) := q(base + i + k); end if;
                    if k < il and base + i + dl + k < PQ_SIZE then r.imm_r(8*k+7 downto 8*k) := q(base + i + dl + k); end if;
                else
                    if k < il and base + i + k < PQ_SIZE then r.oprnd(8*k+7 downto 8*k) := q(base + i + k); end if;
                end if;
            end loop;
        end if;
        res.insn := r; res.len := n; res.ok := '1' when ok else '0';
        return res;
    end function;

    -- The registers an instruction READS (a safe over-approximation: both
    -- modrm register fields, and the 8-bit alias of each, plus the embedded /
    -- accumulator operands). OR'd with dest_mask it gives every GP register the
    -- instruction touches, which is what the pairing data-dependency test needs.
    function reads_mask(op : std_logic_vector(7 downto 0); is0f : std_logic;
                        m : std_logic_vector(7 downto 0)) return std_logic_vector is
        variable r : std_logic_vector(7 downto 0) := (others => '0');
        variable rmi, rgi, n : integer range 0 to 7;
    begin
        rmi := to_integer(unsigned(m(2 downto 0)));
        rgi := to_integer(unsigned(m(5 downto 3)));
        n   := to_integer(unsigned(op(2 downto 0)));
        if is0f = '0' then
            case to_integer(unsigned(op)) is
                when 16#40# to 16#4F# => r(n) := '1';                 -- INC/DEC reg
                when 16#04# | 16#05# | 16#0C# | 16#0D# | 16#24# | 16#25# |
                     16#2C# | 16#2D# | 16#34# | 16#35# | 16#3C# | 16#3D# |
                     16#A8# | 16#A9# => r(0) := '1';                  -- AL/EAX forms
                when others => null;
            end case;
        end if;
        if ((is0f = '1' and op = x"B6") or (is0f = '0' and has_modrm(op))) and m(7 downto 6) = "11" then
            r(rmi) := '1'; r(rmi mod 4) := '1';
            r(rgi) := '1'; r(rgi mod 4) := '1';
        end if;
        return r;
    end function;

    -- Is this a "simple" instruction eligible for the U pipe (single EX cycle,
    -- directly executed, register form, not locked)? The pairable set the V
    -- execute block below implements, plus the U-only shift D1.
    function simple_u(op : std_logic_vector(7 downto 0); is0f, p66, plk : std_logic;
                      m : std_logic_vector(7 downto 0)) return boolean is
    begin
        if plk = '1' then return false; end if;
        if not insn_valid(op, is0f, m, p66) then return false; end if;
        if ex_entry(op, is0f, m, p66) /= S_EXECUTE then return false; end if;  -- memory/microcode
        if is0f = '1' then
            return op = x"B6" and m(7 downto 6) = "11";                        -- MOVZX reg
        end if;
        -- Exactly the single-cycle register ops the EX datapath implements
        -- (see insn_valid / the S_EXECUTE arm): MOV, the ALU register forms it
        -- supports, the accumulator-immediate forms, INC/DEC, the barrel shift
        -- D1, and NOP. Memory/microcode forms were already rejected above.
        case to_integer(unsigned(op)) is
            when 16#88# | 16#89# | 16#8A# | 16#8B# | 16#C6# | 16#C7# |         -- MOV r/m<->r, imm
                 16#B0# to 16#BF# => return true;                             -- MOV reg, imm
            when 16#01# | 16#03# | 16#09# | 16#21# | 16#29# | 16#31# |         -- ADD/OR/AND/SUB/XOR
                 16#39# | 16#85# | 16#81# | 16#83# => return true;            -- CMP/TEST, grp1 imm
            when 16#04# | 16#05# | 16#0C# | 16#0D# | 16#24# | 16#25# |         -- acc, imm
                 16#2C# | 16#2D# | 16#34# | 16#35# | 16#3C# | 16#3D# | 16#A8# => return true;
            when 16#40# to 16#4F# => return true;                            -- INC/DEC
            when 16#D1# => return true;                                      -- shift reg,1 (U only)
            when 16#90# => return true;                                      -- NOP
            when others => return false;
        end case;
    end function;

    -- Eligible for the V pipe: the simple_u set MINUS the U-only barrel shifter
    -- and MINUS flag-reading ops (ADC /2, SBB /3), which the V pipe may not run.
    function simple_v(op : std_logic_vector(7 downto 0); is0f, p66, plk : std_logic;
                      m : std_logic_vector(7 downto 0)) return boolean is
    begin
        -- A conditional branch runs in the V pipe, paired with the flag-setter
        -- in U (its flags are forwarded). Jcc rel8 (70-7F) / rel32 (0F 8x).
        if plk = '0' and is0f = '0' and op(7 downto 4) = x"7" then return true; end if;
        if plk = '0' and is0f = '1' and op(7 downto 4) = x"8" then return true; end if;
        if not simple_u(op, is0f, p66, plk, m) then return false; end if;
        if is0f = '0' and op = x"D1" then return false; end if;              -- shifter is U-only
        if is0f = '0' and (op = x"81" or op = x"83") and
           (m(5 downto 3) = "010" or m(5 downto 3) = "011") then return false; end if;  -- ADC/SBB
        return true;
    end function;

    -- The second decode, the V's D2 slot, and the registered V operands.
    signal d1b       : insn_t := NO_INSN;      -- decode of the instruction after d1
    signal d1b_ok    : std_logic := '0';
    signal d1b_len   : integer range 0 to PQ_SIZE := 0;
    signal pair_ok   : boolean;                -- d1 (U) and d1b (V) may co-issue
    signal d2v       : insn_t := NO_INSN;      -- V's D2 slot (I2 of the pair)
    signal v_ir0     : std_logic_vector(7 downto 0) := (others => '0');
    signal v_0f      : std_logic := '0';
    signal v_p66     : std_logic := '0';
    signal v_modrm   : std_logic_vector(7 downto 0) := (others => '0');
    signal v_oprnd   : std_logic_vector(31 downto 0) := (others => '0');
    signal v_imm_r   : std_logic_vector(31 downto 0) := (others => '0');
    signal v_valid   : std_logic := '0';       -- V holds an instruction this EX cycle
    signal v_seq     : unsigned(15 downto 0) := (others => '0');
    signal v_eip     : unsigned(31 downto 0) := (others => '0');  -- V's instruction address (for the pipeline view)
    signal v_nxt     : unsigned(31 downto 0) := (others => '0');  -- addr after V's insn (Jcc base)
    signal v_tk      : boolean;                 -- V holds a taken conditional branch
    signal v_target  : unsigned(31 downto 0);   -- ... its target
    signal pairs_ctr : unsigned(31 downto 0) := (others => '0');  -- # pairs issued

    ----------------------------------------------------------------------------
    -- Branch target buffer (Alpert & Avnon, Fig. 6). An associative memory of
    -- taken branches: {branch address, target, 2-bit saturating history}. It is
    -- searched at decode; on a hit that predicts taken the front end redirects
    -- fetch to the target straight away, so a correctly predicted branch avoids
    -- the taken-branch bubble. The branch still resolves in EX, where a
    -- misprediction flushes and refetches and the history/target are updated.
    -- Scaled to 4-way x 2 sets = 8 entries (the paper's is 4-way x 256).
    ----------------------------------------------------------------------------
    constant BTB_SETS : integer := 2;
    constant BTB_WAYS : integer := 4;
    type btb_entry_t is record
        valid : std_logic;
        tag   : unsigned(31 downto 0);     -- the branch instruction's address
        tgt   : unsigned(31 downto 0);     -- its taken target
        ctr   : unsigned(1 downto 0);      -- 2-bit history: 00/01 not taken, 10/11 taken
    end record;
    type btb_arr_t is array (0 to BTB_SETS*BTB_WAYS - 1) of btb_entry_t;
    constant BTB_INIT : btb_entry_t := ('0', (others => '0'), (others => '0'), "01");
    type btb_rr_t is array (0 to BTB_SETS - 1) of unsigned(1 downto 0);

    type btb_res_t is record
        hit : std_logic;
        tk  : std_logic;                   -- predict taken (history MSB)
        tgt : unsigned(31 downto 0);
    end record;

    -- Branches the BTB tracks (resolved in the U pipe): Jcc rel8/rel32, JMP rel.
    function is_ubranch(op : std_logic_vector(7 downto 0); is0f : std_logic) return boolean is
    begin
        if is0f = '1' then return op(7 downto 4) = x"8"; end if;      -- Jcc rel32 (0F 8x)
        return op = x"EB" or op = x"E9" or op(7 downto 4) = x"7";     -- JMP rel8/32, Jcc rel8
    end function;

    function btb_set(addr : unsigned(31 downto 0)) return integer is
    begin
        return to_integer(addr(2 downto 2));
    end function;

    function btb_lookup(t : btb_arr_t; addr : unsigned(31 downto 0)) return btb_res_t is
        variable s : integer;
        variable r : btb_res_t := ('0', '0', (others => '0'));
    begin
        -- A parked/just-woken core can present a metavalue fetch address before
        -- its pipeline is live; report "no BTB hit" rather than compare it.
        if is_x(std_logic_vector(addr)) then return r; end if;
        s := btb_set(addr);
        for w in 0 to BTB_WAYS - 1 loop
            if t(s*BTB_WAYS + w).valid = '1' and t(s*BTB_WAYS + w).tag = addr then
                r.hit := '1'; r.tk := t(s*BTB_WAYS + w).ctr(1); r.tgt := t(s*BTB_WAYS + w).tgt;
            end if;
        end loop;
        return r;
    end function;

    signal btb      : btb_arr_t := (others => BTB_INIT);
    signal btb_rr   : btb_rr_t  := (others => "00");
    signal d1_pred_tk  : std_logic := '0';          -- BTB predicts d1's branch taken
    signal d1_pred_tgt : unsigned(31 downto 0) := (others => '0');
    signal ex_pred_tk  : std_logic := '0';          -- ... carried to the branch in EX
    signal ex_pred_tgt : unsigned(31 downto 0) := (others => '0');
    signal ex_ubr      : boolean;                   -- EX holds a U-pipe branch
    signal u_act_tgt   : unsigned(31 downto 0);     -- its actual taken target (eip+rel)
    signal btb_seen    : unsigned(31 downto 0) := (others => '0');  -- U-branches resolved
    signal btb_correct : unsigned(31 downto 0) := (others => '0');  -- ... predicted correctly
    signal btb_wrong   : unsigned(31 downto 0) := (others => '0');  -- ... mispredicted
    signal wake_pulse  : std_logic;            -- AP woken this cycle (leave the park)

begin

    -- Memory-bus states stall on `ready`. EXECUTE/HALT, the interrupt
    -- acknowledge and the I/O states (separate I/O bus) are not memory accesses.
    is_bus   <= not (state = S_IDLE or state = S_EXECUTE or state = S_HALT or
                     state = S_INTA or state = S_IN or state = S_OUT);

    ud <= '0' when insn_valid(ir0, ir_0f, modrm, pfx_66) else '1';


    -- The immediate follows the displacement (if any) of a ModR/M instruction.
    immv <= imm_r when disp_n > 0 else oprnd;

    -- Effective address of the data access: generated in D2, latched into EX.
    ea <= ex_ea;
    ea2_proc : process(all)
    begin
        if d2.is0f = '0' and (d2.ir0 = x"A0" or d2.ir0 = x"A1" or d2.ir0 = x"A2" or d2.ir0 = x"A3") then
            ea_d2 <= d2.oprnd;                                         -- moffs
        elsif d2.is0f = '0' and d2.ir0 = x"D7" then
            ea_d2 <= std_logic_vector(reg(R_EBX) + resize(reg(R_EAX)(7 downto 0), 32)); -- XLAT
        else
            ea_d2 <= ea_of(d2.modrm, d2.sib, d2.oprnd, reg);
        end if;
    end process;

    -- Data access size of a load/store.
    msize <= "00" when (ir_0f = '0' and (ir0 = x"88" or ir0 = x"8A" or ir0 = x"C6" or ir0 = x"D7" or
                                         ir0 = x"A0" or ir0 = x"A2"))
                    or (ir_0f = '0' and (is_alu8(ir0) or ir0 = x"80" or ir0 = x"84"))  -- byte ALU/grp1/TEST
                    or (ir_0f = '1' and (ir0 = x"B6" or ir0 = x"BE"))  -- MOVZX/MOVSX r/m8
                    or (ir_0f = '1' and ir0(7 downto 4) = x"9")        -- SETcc [m8]
                    else
             "01" when (opsz16 = '1' and ir_0f = '0' and (ir0 = x"89" or ir0 = x"8B" or ir0 = x"C7" or
                                                          ir0 = x"A1" or ir0 = x"A3"))
                    or (ir_0f = '1' and (ir0 = x"B7" or ir0 = x"BF"))  -- MOVZX/MOVSX r/m16
                    else
             "10";

    -- Misaligned data: the operand starts at byte ea_k of a dword; if it runs
    -- past byte 3 the access takes a second bus cycle at the next dword.
    ea_k  <= to_integer(unsigned(ea(1 downto 0)));
    ea_al <= unsigned(ea(31 downto 2)) & "00";
    split <= '1' when (msize = "10" and ea_k /= 0) or (msize = "01" and ea_k = 3) else '0';
    ld_proc : process(all)
        variable v64 : unsigned(63 downto 0);
    begin
        if q_idx = 1 then v64 := unsigned(std_logic_vector'(data_in & lo_tmp));  -- 2nd half
        else              v64 := resize(unsigned(data_in), 64); end if;
        ldv <= std_logic_vector(resize(shift_right(v64, 8 * ea_k), 32));
    end process;

    eflags_v <= x"00000" & of_f & '0' & if_f & '0' & sf & zf & '0' & af & '0' & pf & '1' & cf;

    ----------------------------------------------------------------------------
    -- State register
    ----------------------------------------------------------------------------
    -- An application processor woken out of its boot-time park this cycle.
    wake_pulse <= '1' when AP_PARK and wake = '1' and state = S_HALT else '0';

    state_reg_proc : process(clk, reset)
    begin
        if reset = '1' then
            -- The AP boots parked (S_HALT); the BSP runs from reset.
            if AP_PARK then state <= S_HALT; else state <= S_IDLE; end if;
        elsif rising_edge(clk) then
            state <= next_state;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- EX micro-sequencer: the state after this cycle (S_IDLE = the instruction
    -- is done). A bus state holds itself until it owns the bus and `ready`.
    ----------------------------------------------------------------------------
    ex_next_proc : process(all)
        variable nxt : cpu_state_t;
    begin
        nxt := S_IDLE;
        case state is

            when S_IDLE => nxt := S_IDLE;

            when S_EXECUTE =>
                if ud = '1' then
                    nxt := S_INT_VEC;                       -- #UD
                elsif ir_0f = '1' then
                    if ir0 = x"01" then
                        nxt := S_LIDT0;
                    elsif ir0 = x"B1" then
                        nxt := S_CMPX_R;                    -- CMPXCHG
                    elsif ir0 = x"B6" then                  -- MOVZX r32, r/m8
                        if modrm(7 downto 6) /= "11" then nxt := S_LOAD; end if;
                    elsif ir0 = x"AF" and modrm(7 downto 6) = "11" then
                        nxt := S_MULDIV_WAIT;               -- IMUL r32,r32 : multi-cycle
                    elsif is_sse(ir0) and modrm(7 downto 6) /= "11" then
                        if ir0 = x"28" or ir0 = x"6E" or ir0 = x"6F" then
                            nxt := S_XMM_LD;                -- MOVAPS/MOVD/MOVDQA load
                        elsif ir0 = x"29" or ir0 = x"7E" or ir0 = x"7F" then
                            nxt := S_XMM_ST;                -- MOVAPS/MOVD/MOVDQA store
                        end if;
                    end if;
                else
                    case ir0 is
                        when x"F4" => nxt := S_HALT;
                        when x"A0" | x"A1" | x"D7" => nxt := S_LOAD;
                        when x"A2" | x"A3" => nxt := S_STORE;
                        when x"8B" | x"8A" =>      -- MOV reg, r/m : memory form -> load
                            if modrm(7 downto 6) /= "11" then nxt := S_LOAD; end if;
                        when x"89" | x"88" | x"C6" | x"C7" =>  -- MOV r/m, reg|imm : store
                            if modrm(7 downto 6) /= "11" then nxt := S_STORE; end if;
                        -- ALU with a memory operand: load it (then store back if RMW)
                        when x"01" | x"03" | x"09" | x"0B" | x"11" | x"13" | x"19" | x"1B" |
                             x"21" | x"23" | x"29" | x"2B" | x"31" | x"33" | x"39" | x"3B" |
                             x"85" | x"81" | x"83" =>
                            if modrm(7 downto 6) /= "11" then nxt := S_LOAD; end if;
                        when x"50" | x"51" | x"52" | x"53" |
                             x"54" | x"55" | x"56" | x"57" |
                             x"68" | x"6A" | x"9C" => nxt := S_PUSH;  -- PUSH r32/imm/PUSHFD
                        when x"58" | x"59" | x"5A" | x"5B" |
                             x"5C" | x"5D" | x"5E" | x"5F" | x"9D" => nxt := S_POP;
                        when x"60" => nxt := S_PUSHA;
                        when x"61" => nxt := S_POPA;
                        when x"E8" => nxt := S_CALL_PUSH;
                        when x"C3" => nxt := S_RET_POP;
                        when x"CD" => nxt := S_INT_VEC;
                        when x"CF" => nxt := S_IRET_POP;
                        when x"87" => nxt := S_XCHG_R;
                        when x"E4" | x"E5" | x"EC" | x"ED" => nxt := S_IN;
                        when x"E6" | x"E7" | x"EE" | x"EF" => nxt := S_OUT;
                        -- register-form MUL/IMUL/DIV (F7) and IMUL r,r/m,imm: hold
                        -- EX for the Pentium latency; NOT/NEG/TEST keep 1 cycle.
                        when x"F7" =>
                            if modrm(7 downto 6) = "11"
                               and muldiv_wait(ir0, '0', modrm) > 0 then nxt := S_MULDIV_WAIT; end if;
                        when x"69" | x"6B" =>
                            if modrm(7 downto 6) = "11" then nxt := S_MULDIV_WAIT; end if;
                        when others => nxt := S_IDLE;
                    end case;
                end if;

            when S_LOAD | S_STORE =>                         -- 2 cycles if misaligned
                if split = '1' and q_idx = 0 then nxt := state;
                elsif state = S_LOAD and mem_alu_wb(ir0, modrm) then nxt := S_STORE;  -- RMW
                elsif state = S_LOAD and muldiv_wait(ir0, ir_0f, modrm) > 0 then
                    nxt := S_MULDIV_WAIT;                    -- MUL/IMUL/DIV from memory
                else nxt := S_IDLE; end if;

            when S_MULDIV_WAIT =>                            -- hold for the P54C latency
                if md_cnt + 1 >= muldiv_wait(ir0, ir_0f, modrm) then nxt := S_IDLE;
                else nxt := S_MULDIV_WAIT; end if;
            when S_PUSH | S_POP | S_CALL_PUSH | S_RET_POP |
                 S_CMPX_W | S_LIDT1 | S_IN | S_OUT =>
                nxt := S_IDLE;
            when S_XCHG_R => nxt := S_XCHG_W;
            when S_XCHG_W => nxt := S_IDLE;
            when S_LIDT0 => nxt := S_LIDT1;

            when S_PUSHA | S_POPA =>                         -- 8 dwords
                if q_idx >= 7 then nxt := S_IDLE; else nxt := state; end if;

            when S_INTA     => nxt := S_INT_VEC;
            when S_INT_VEC  => nxt := S_INT_PUSH;
            when S_INT_PUSH | S_IRET_POP =>                  -- 3 dwords: EFLAGS, CS, EIP
                if q_idx >= 2 then nxt := S_IDLE; else nxt := state; end if;

            when S_CMPX_R =>
                -- Compare EAX with the loaded word. data_in is metavalue until the
                -- read settles (e.g. a just-woken AP mid-spinlock); stay until then
                -- so the comparison never sees an unsettled value.
                if is_x(data_in) then nxt := state;
                elsif reg(R_EAX) = unsigned(data_in) then nxt := S_CMPX_W;
                else nxt := S_IDLE; end if;

            when S_XMM_LD | S_XMM_ST =>
                if q_idx >= sse_words(ir0) - 1 then nxt := S_IDLE;
                else nxt := state; end if;

            when S_HALT =>                                   -- HLT / AP park
                if wake_pulse = '1' then nxt := S_IDLE;       -- AP started by the BSP
                elsif intr = '1' and if_f = '1' then nxt := S_INTA;
                else nxt := S_HALT; end if;
        end case;

        -- A page fault from the MMU aborts the current (stalled) access and
        -- vectors to #PF -- unless an interrupt is already being delivered.
        if page_fault = '1' and owner_ex and state /= S_INT_VEC and state /= S_INT_PUSH
                            and state /= S_INTA and state /= S_HALT then
            ex_nxt <= S_INT_VEC;
        -- Wait-state hold: a bus state waits for the bus and for `ready`.
        elsif is_bus and not ex_bus_ok then
            ex_nxt <= state;
        else
            ex_nxt <= nxt;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Datapath (clocked). Bus-state actions only take effect when ready=1.
    ----------------------------------------------------------------------------
    datapath_proc : process(clk, reset)
        variable rm_i, rg_i, n_i : integer range 0 to 7;
        variable a, res     : unsigned(31 downto 0);
        variable res8       : unsigned(7 downto 0);
        variable imm, rel   : unsigned(31 downto 0);
        variable cc         : std_logic_vector(3 downto 0);
        variable digit      : std_logic_vector(2 downto 0);
        variable old_cf     : std_logic;
        variable bv         : std_logic_vector(7 downto 0);
        variable prod       : signed(63 downto 0);    -- IMUL/MUL product
        variable scnt       : integer range 0 to 255; -- shift / rotate count (pre-mask)
        variable pu64       : unsigned(63 downto 0);   -- MUL / DIV dividend-product (unsigned)
        variable ps64       : signed(63 downto 0);     -- IMUL / IDIV (signed)
        variable qu, ru     : unsigned(63 downto 0);   -- DIV quotient / remainder
        variable qs, rs     : signed(63 downto 0);     -- IDIV quotient / remainder

        procedure set_szp(v : unsigned(31 downto 0)) is
        begin
            if v = 0 then zf <= '1'; else zf <= '0'; end if;
            sf <= v(31);
            pf <= parity8(std_logic_vector(v(7 downto 0)));
        end procedure;

        procedure set_szp8(v : unsigned(7 downto 0)) is
        begin
            if v = 0 then zf <= '1'; else zf <= '0'; end if;
            sf <= v(7);
            pf <= parity8(std_logic_vector(v));
        end procedure;

        procedure flags_add(x, y : unsigned(31 downto 0); ci : std_logic) is
            variable w : unsigned(32 downto 0);
            variable n : unsigned(4 downto 0);
        begin
            w := ('0' & x) + ('0' & y);
            n := ('0' & x(3 downto 0)) + ('0' & y(3 downto 0));
            if ci = '1' then w := w + 1; n := n + 1; end if;
            res := w(31 downto 0);
            cf <= w(32);
            of_f <= (x(31) xnor y(31)) and (w(31) xor x(31));
            af <= n(4);
            set_szp(w(31 downto 0));
        end procedure;

        procedure flags_sub(x, y : unsigned(31 downto 0); bi : std_logic) is
            variable w : unsigned(32 downto 0);
            variable n : unsigned(4 downto 0);
        begin
            w := ('0' & x) - ('0' & y);
            n := ('0' & x(3 downto 0)) - ('0' & y(3 downto 0));
            if bi = '1' then w := w - 1; n := n - 1; end if;
            res := w(31 downto 0);
            cf <= w(32);
            of_f <= (x(31) xor y(31)) and (w(31) xor x(31));
            af <= n(4);
            set_szp(w(31 downto 0));
        end procedure;

        procedure flags_logic(v : unsigned(31 downto 0)) is
        begin
            res := v;                      -- the logical result (AND/OR/XOR)
            cf <= '0'; of_f <= '0'; af <= '0';
            set_szp(v);
        end procedure;

        -- Signed 32x32 multiply (IMUL two/three-operand). res = low 32 bits;
        -- CF=OF=1 iff the full product does not fit in a signed 32-bit value.
        procedure do_imul(x, y : signed(31 downto 0)) is
            variable p : signed(63 downto 0);
        begin
            p := x * y;
            res := unsigned(p(31 downto 0));
            if (p(63 downto 32) = x"00000000" and p(31) = '0') or
               (p(63 downto 32) = x"FFFFFFFF" and p(31) = '1') then
                cf <= '0'; of_f <= '0';
            else
                cf <= '1'; of_f <= '1';
            end if;
            set_szp(res);
        end procedure;

        -- 32-bit shift / rotate (group /0 ROL /1 ROR /4 SHL /5 SHR /7 SAR). The
        -- count is masked to 5 bits (x86); a zero count leaves value and flags
        -- unchanged. OF is defined only for a 1-bit shift. Sets res + CF/OF (+SZP
        -- for the shifts). cnt is the raw operand (imm8 / CL / 1).
        procedure do_shift(dg : std_logic_vector(2 downto 0);
                           val : unsigned(31 downto 0); cnt : integer) is
            variable n : integer range 0 to 31;
            variable r : unsigned(31 downto 0);
        begin
            n := cnt mod 32;
            if n = 0 then res := val; return; end if;       -- no change, flags intact
            case dg is
                when "100" =>                                -- SHL
                    r := shift_left(val, n); cf <= val(32 - n);
                    if cnt = 1 then of_f <= val(32 - n) xor r(31); end if;
                    res := r; set_szp(r);
                when "101" =>                                -- SHR
                    r := shift_right(val, n); cf <= val(n - 1);
                    if cnt = 1 then of_f <= val(31); end if;
                    res := r; set_szp(r);
                when "111" =>                                -- SAR
                    r := unsigned(shift_right(signed(val), n)); cf <= val(n - 1);
                    if cnt = 1 then of_f <= '0'; end if;
                    res := r; set_szp(r);
                when "000" =>                                -- ROL
                    r := rotate_left(val, n); cf <= r(0);
                    if cnt = 1 then of_f <= r(0) xor r(31); end if;
                    res := r;
                when others =>                               -- ROR
                    r := rotate_right(val, n); cf <= r(31);
                    if cnt = 1 then of_f <= r(31) xor r(30); end if;
                    res := r;
            end case;
        end procedure;

        -- grp3 (F7): /0,/1 TEST (flags), /2 NOT, /3 NEG, /4 MUL, /5 IMUL (EDX:EAX),
        -- /6 DIV, /7 IDIV. MUL/DIV write EDX:EAX directly; NOT/NEG set res for the
        -- caller to write back. Divide-by-zero or quotient overflow raises #DE.
        procedure do_grp3(dg : std_logic_vector(2 downto 0); val : unsigned(31 downto 0)) is
            variable pu, dvdu, qq, rr : unsigned(63 downto 0);
            variable pss, dvds, qsg, rsg : signed(63 downto 0);
        begin
            dvdu(63 downto 32) := reg(2);  dvdu(31 downto 0) := reg(R_EAX);   -- EDX:EAX
            dvds := signed(dvdu);
            case dg is
                when "000" | "001" => flags_logic(val and unsigned(immv));    -- TEST r/m, imm
                when "010" => res := not val;                                 -- NOT (no flags)
                when "011" => flags_sub(to_unsigned(0, 32), val, '0');        -- NEG (CF=val/=0)
                when "100" =>                                                 -- MUL (unsigned)
                    pu := reg(R_EAX) * val;
                    reg(R_EAX) <= pu(31 downto 0); reg(2) <= pu(63 downto 32);
                    if pu(63 downto 32) = 0 then cf <= '0'; of_f <= '0';
                    else cf <= '1'; of_f <= '1'; end if;
                when "101" =>                                                 -- IMUL (signed)
                    pss := signed(reg(R_EAX)) * signed(val);
                    reg(R_EAX) <= unsigned(pss(31 downto 0)); reg(2) <= unsigned(pss(63 downto 32));
                    if (pss(63 downto 32) = 0 and pss(31) = '0') or
                       (pss(63 downto 32) = x"FFFFFFFF" and pss(31) = '1') then
                        cf <= '0'; of_f <= '0'; else cf <= '1'; of_f <= '1'; end if;
                when "110" =>                                                 -- DIV (unsigned)
                    if val = 0 then vec_num <= to_unsigned(0, 8); exc_fault <= '1';
                    else
                        qq := dvdu / resize(val, 64);
                        rr := dvdu rem resize(val, 64);
                        if qq(63 downto 32) /= 0 then vec_num <= to_unsigned(0, 8); exc_fault <= '1';
                        else reg(R_EAX) <= qq(31 downto 0); reg(2) <= rr(31 downto 0); end if;
                    end if;
                when others =>                                                -- IDIV (signed)
                    if val = 0 then vec_num <= to_unsigned(0, 8); exc_fault <= '1';
                    else
                        qsg := dvds / resize(signed(val), 64);
                        rsg := dvds rem resize(signed(val), 64);
                        if (qsg(63 downto 32) = 0 and qsg(31) = '0') or
                           (qsg(63 downto 32) = x"FFFFFFFF" and qsg(31) = '1') then
                            reg(R_EAX) <= unsigned(qsg(31 downto 0)); reg(2) <= unsigned(rsg(31 downto 0));
                        else vec_num <= to_unsigned(0, 8); exc_fault <= '1'; end if;
                    end if;
            end case;
        end procedure;

        -- 8-bit forms (AL): same rules, with the sign / carry at bit 7 / bit 8.
        procedure flags_sub8(x, y : unsigned(7 downto 0)) is
            variable w : unsigned(8 downto 0);
            variable n : unsigned(4 downto 0);
        begin
            w := ('0' & x) - ('0' & y);
            n := ('0' & x(3 downto 0)) - ('0' & y(3 downto 0));
            res8 := w(7 downto 0);
            cf <= w(8);
            of_f <= (x(7) xor y(7)) and (w(7) xor x(7));
            af <= n(4);
            set_szp8(w(7 downto 0));
        end procedure;

        procedure flags_logic8(v : unsigned(7 downto 0)) is
        begin
            res8 := v;
            cf <= '0'; of_f <= '0'; af <= '0';
            set_szp8(v);
        end procedure;

        -- 8-bit ALU, selected by aluop (the ModR/M reg field / opcode bits 5..3):
        -- 000 ADD 001 OR 010 ADC 011 SBB 100 AND 101 SUB 110 XOR 111 CMP. Result
        -- in res8; CMP sets flags only (caller suppresses the write-back). ADC/SBB
        -- fold in the incoming carry (the live cf signal).
        procedure do_alu8(aluop : std_logic_vector(2 downto 0); x, y : unsigned(7 downto 0)) is
            variable w  : unsigned(8 downto 0);
            variable nn : unsigned(4 downto 0);
        begin
            case aluop is
                when "001" => flags_logic8(x or  y);
                when "100" => flags_logic8(x and y);
                when "110" => flags_logic8(x xor y);
                when "000" | "010" =>                               -- ADD / ADC
                    w  := ('0' & x) + ('0' & y);
                    nn := ('0' & x(3 downto 0)) + ('0' & y(3 downto 0));
                    if aluop = "010" and cf = '1' then w := w + 1; nn := nn + 1; end if;
                    res8 := w(7 downto 0);
                    cf <= w(8); of_f <= (x(7) xnor y(7)) and (w(7) xor x(7));
                    af <= nn(4); set_szp8(w(7 downto 0));
                when others =>                                       -- SUB / SBB / CMP
                    w  := ('0' & x) - ('0' & y);
                    nn := ('0' & x(3 downto 0)) - ('0' & y(3 downto 0));
                    if aluop = "011" and cf = '1' then w := w - 1; nn := nn - 1; end if;
                    res8 := w(7 downto 0);
                    cf <= w(8); of_f <= (x(7) xor y(7)) and (w(7) xor x(7));
                    af <= nn(4); set_szp8(w(7 downto 0));
            end case;
        end procedure;

        -- Write an x86 8-bit register (AL CL DL BL AH CH DH BH).
        procedure set_r8(n : integer; v : std_logic_vector(7 downto 0)) is
        begin
            if n < 4 then reg(n)(7 downto 0) <= unsigned(v);
            else          reg(n - 4)(15 downto 8) <= unsigned(v); end if;
        end procedure;

        -- Load EFLAGS from a popped image (POPFD / IRET).
        procedure load_flags(d : std_logic_vector(31 downto 0)) is
        begin
            cf <= d(0); pf <= d(2); af <= d(4); zf <= d(6); sf <= d(7);
            if_f <= d(9); of_f <= d(11);
        end procedure;
    begin
        if reset = '1' then
            reg <= (others => (others => '0'));
            xmm <= (others => (others => '0'));
            eip <= (others => '0');
            cf <= '0'; pf <= '0'; af <= '0'; zf <= '0'; sf <= '0'; of_f <= '0';
            if_f <= '0'; sti_shadow <= '0';
            idtr_base <= (others => '0');
            ir0 <= (others => '0'); ir_0f <= '0';
            pfx_lock <= '0'; pfx_66 <= '0'; opsz16 <= '0';
            modrm <= (others => '0'); oprnd <= (others => '0'); imm_r <= (others => '0');
            disp_n <= 0; operand_total <= 0; operand_idx <= 0; q_idx <= 0;
            ex_ea <= (others => '0'); ex_seq <= (others => '0'); ex_irq <= '0';
            ex_drain <= '0'; ex_first <= '0';
            v_valid <= '0'; pairs_ctr <= (others => '0');
            cr0 <= (others => '0'); cr2 <= (others => '0'); cr3 <= (others => '0');
            ip_start <= (others => '0'); new_insn <= '1';
            vec_num <= (others => '0'); exc_fault <= '0';

        elsif rising_edge(clk) then
            -- AP start-up: the BSP woke this core. Begin fetching at wake_eip
            -- (the front end refetches there, driven by redir_pending below).
            if wake_pulse = '1' then
                eip <= unsigned(wake_eip);
                ip_start <= unsigned(wake_eip);
                new_insn <= '1';
            end if;

            -- Ungated: a page fault from the MMU latches CR2 and selects #PF the
            -- instant it is raised (the faulting access itself is stalled, so
            -- the gated logic below would miss it).
            if page_fault = '1' and owner_ex and state /= S_INT_VEC and state /= S_INT_PUSH
                                and state /= S_INTA and state /= S_HALT then
                cr2 <= unsigned(fault_addr);
                vec_num <= to_unsigned(14, 8);
                exc_fault <= '1';
            end if;

            -- Skip the action while stalled on a bus access.
            if (not is_bus) or ex_bus_ok then
            case state is

                when S_IDLE => null;

                when S_EXECUTE =>
                    rm_i := to_integer(unsigned(modrm(2 downto 0)));
                    rg_i := to_integer(unsigned(modrm(5 downto 3)));
                    n_i  := to_integer(unsigned(ir0(2 downto 0)));
                    old_cf := cf;
                    pfx_lock <= '0'; pfx_66 <= '0';   -- consume prefixes
                    opsz16 <= pfx_66;                 -- ... but remember the size
                    new_insn <= '1';                  -- arm ip_start for next fetch
                    sti_shadow <= '0';                -- the STI shadow lasts one insn

                    if ud = '1' then
                        -- #UD: invalid / unimplemented opcode -> vector 6 (a fault)
                        vec_num <= to_unsigned(6, 8);
                        exc_fault <= '1';
                    elsif ir_0f = '1' then
                        if ir0(7 downto 4) = x"8" then            -- Jcc near
                            cc := ir0(3 downto 0);
                            if cond_true(cc, zf, cf, sf, of_f, pf) then
                                eip <= eip + unsigned(oprnd);
                            end if;
                        elsif ir0 = x"B6" then                    -- MOVZX r32, r8
                            if modrm(7 downto 6) = "11" then
                                reg(rg_i) <= resize(unsigned(get_r8(reg, rm_i)), 32);
                            end if;
                        elsif ir0 = x"B7" then                    -- MOVZX r32, r16
                            if modrm(7 downto 6) = "11" then
                                reg(rg_i) <= resize(reg(rm_i)(15 downto 0), 32);
                            end if;
                        elsif ir0 = x"BE" then                    -- MOVSX r32, r8
                            if modrm(7 downto 6) = "11" then
                                reg(rg_i) <= unsigned(resize(signed(get_r8(reg, rm_i)), 32));
                            end if;
                        elsif ir0 = x"BF" then                    -- MOVSX r32, r16
                            if modrm(7 downto 6) = "11" then
                                reg(rg_i) <= unsigned(resize(signed(reg(rm_i)(15 downto 0)), 32));
                            end if;
                        elsif ir0(7 downto 4) = x"9" then         -- SETcc r/m8
                            if modrm(7 downto 6) = "11" then
                                if cond_true(ir0(3 downto 0), zf, cf, sf, of_f, pf) then
                                    set_r8(rm_i, x"01");
                                else set_r8(rm_i, x"00"); end if;
                            end if;
                        elsif ir0 = x"AF" then                    -- IMUL r32, r/m32
                            if modrm(7 downto 6) = "11" then
                                do_imul(signed(reg(rg_i)), signed(reg(rm_i)));
                                reg(rg_i) <= res;
                            end if;
                        elsif is_sse(ir0) and modrm(7 downto 6) = "11" then
                            -- SSE register-direct forms (single cycle)
                            case ir0 is
                                when x"28" => xmm(rg_i) <= xmm(rm_i);          -- MOVAPS xmm,xmm
                                when x"29" => xmm(rm_i) <= xmm(rg_i);          -- MOVAPS xmm,xmm
                                when x"6F" => xmm(rg_i) <= xmm(rm_i);          -- MOVDQA xmm,xmm
                                when x"7F" => xmm(rm_i) <= xmm(rg_i);          -- MOVDQA xmm,xmm
                                when x"6E" =>                                 -- MOVD xmm,r32
                                    xmm(rg_i) <= ZERO96 & std_logic_vector(reg(rm_i));
                                when x"7E" =>                                 -- MOVD r32,xmm
                                    reg(rm_i) <= unsigned(xmm(rg_i)(31 downto 0));
                                when x"EF" => xmm(rg_i) <= xmm(rg_i) xor xmm(rm_i); -- PXOR
                                when x"FE" =>                                 -- PADDD (4 lanes)
                                    xmm(rg_i)(31 downto 0)    <= add32(xmm(rg_i)(31 downto 0),    xmm(rm_i)(31 downto 0));
                                    xmm(rg_i)(63 downto 32)   <= add32(xmm(rg_i)(63 downto 32),   xmm(rm_i)(63 downto 32));
                                    xmm(rg_i)(95 downto 64)   <= add32(xmm(rg_i)(95 downto 64),   xmm(rm_i)(95 downto 64));
                                    xmm(rg_i)(127 downto 96)  <= add32(xmm(rg_i)(127 downto 96),  xmm(rm_i)(127 downto 96));
                                when others => null;
                            end case;
                        elsif ir0 = x"22" then          -- MOV CRn, r32  (0F 22 /r)
                            case modrm(5 downto 3) is
                                when "000" => cr0 <= reg(rm_i);   -- CR0 (PG = bit 31)
                                when "010" => cr2 <= reg(rm_i);   -- CR2
                                when "011" => cr3 <= reg(rm_i);   -- CR3 (write flushes TLB)
                                when others => null;
                            end case;
                        elsif ir0 = x"20" then          -- MOV r32, CRn  (0F 20 /r)
                            case modrm(5 downto 3) is
                                when "000" => reg(rm_i) <= cr0;
                                when "010" => reg(rm_i) <= cr2;
                                when "011" => reg(rm_i) <= cr3;
                                when others => null;
                            end case;
                        end if;
                    else
                        case ir0 is
                            when x"90" => null;
                            when x"F4" => null;
                            when x"F8" => cf <= '0';
                            when x"F9" => cf <= '1';
                            when x"FA" => if_f <= '0';                        -- CLI
                            when x"FB" =>                                     -- STI
                                if if_f = '0' then sti_shadow <= '1'; end if;
                                if_f <= '1';

                            when x"B0" | x"B1" | x"B2" | x"B3" |
                                 x"B4" | x"B5" | x"B6" | x"B7" =>             -- MOV r8, imm8
                                set_r8(n_i, oprnd(7 downto 0));
                            when x"B8" | x"B9" | x"BA" | x"BB" |
                                 x"BC" | x"BD" | x"BE" | x"BF" =>             -- MOV r32/r16, imm
                                if pfx_66 = '1' then reg(n_i)(15 downto 0) <= unsigned(oprnd(15 downto 0));
                                else reg(n_i) <= unsigned(oprnd); end if;

                            -- register forms only; memory forms -> S_LOAD / S_STORE
                            when x"89" =>
                                if modrm(7 downto 6) = "11" then
                                    if pfx_66 = '1' then reg(rm_i)(15 downto 0) <= reg(rg_i)(15 downto 0);
                                    else reg(rm_i) <= reg(rg_i); end if;
                                end if;
                            when x"8B" =>
                                if modrm(7 downto 6) = "11" then
                                    if pfx_66 = '1' then reg(rg_i)(15 downto 0) <= reg(rm_i)(15 downto 0);
                                    else reg(rg_i) <= reg(rm_i); end if;
                                end if;
                            when x"88" =>
                                if modrm(7 downto 6) = "11" then set_r8(rm_i, get_r8(reg, rg_i)); end if;
                            when x"8A" =>
                                if modrm(7 downto 6) = "11" then set_r8(rg_i, get_r8(reg, rm_i)); end if;
                            when x"C6" =>
                                if modrm(7 downto 6) = "11" then set_r8(rm_i, immv(7 downto 0)); end if;
                            when x"C7" =>
                                if modrm(7 downto 6) = "11" then
                                    if pfx_66 = '1' then reg(rm_i)(15 downto 0) <= unsigned(immv(15 downto 0));
                                    else reg(rm_i) <= unsigned(immv); end if;
                                end if;

                            when x"40" | x"41" | x"42" | x"43" |
                                 x"44" | x"45" | x"46" | x"47" =>
                                a := reg(n_i);
                                flags_add(a, to_unsigned(1, 32), '0');
                                cf <= old_cf;
                                reg(n_i) <= res;
                            when x"48" | x"49" | x"4A" | x"4B" |
                                 x"4C" | x"4D" | x"4E" | x"4F" =>
                                a := reg(n_i);
                                flags_sub(a, to_unsigned(1, 32), '0');
                                cf <= old_cf;
                                reg(n_i) <= res;

                            when x"05" => flags_add(reg(R_EAX), unsigned(oprnd), '0'); reg(R_EAX) <= res;
                            when x"2D" => flags_sub(reg(R_EAX), unsigned(oprnd), '0'); reg(R_EAX) <= res;
                            when x"3D" => flags_sub(reg(R_EAX), unsigned(oprnd), '0');
                            when x"25" => flags_logic(reg(R_EAX) and unsigned(oprnd)); reg(R_EAX) <= res;
                            when x"0D" => flags_logic(reg(R_EAX) or  unsigned(oprnd)); reg(R_EAX) <= res;
                            when x"35" => flags_logic(reg(R_EAX) xor unsigned(oprnd)); reg(R_EAX) <= res;

                            -- 8-bit accumulator forms (device status polling)
                            when x"04" =>                                     -- ADD AL, imm8
                                a := resize(reg(R_EAX)(7 downto 0), 32);
                                res8 := reg(R_EAX)(7 downto 0) + unsigned(oprnd(7 downto 0));
                                cf <= '1' when a + unsigned(oprnd(7 downto 0)) > 255 else '0';
                                of_f <= (reg(R_EAX)(7) xnor oprnd(7)) and (res8(7) xor reg(R_EAX)(7));
                                af <= '1' when resize(reg(R_EAX)(3 downto 0), 5) + unsigned(oprnd(3 downto 0)) > 15 else '0';
                                set_szp8(res8);
                                reg(R_EAX)(7 downto 0) <= res8;
                            when x"2C" =>                                     -- SUB AL, imm8
                                flags_sub8(reg(R_EAX)(7 downto 0), unsigned(oprnd(7 downto 0)));
                                reg(R_EAX)(7 downto 0) <= res8;
                            when x"0C" =>                                     -- OR AL, imm8
                                flags_logic8(reg(R_EAX)(7 downto 0) or unsigned(oprnd(7 downto 0)));
                                reg(R_EAX)(7 downto 0) <= res8;
                            when x"34" =>                                     -- XOR AL, imm8
                                flags_logic8(reg(R_EAX)(7 downto 0) xor unsigned(oprnd(7 downto 0)));
                                reg(R_EAX)(7 downto 0) <= res8;
                            when x"24" =>                                     -- AND AL, imm8
                                flags_logic8(reg(R_EAX)(7 downto 0) and unsigned(oprnd(7 downto 0)));
                                reg(R_EAX)(7 downto 0) <= res8;
                            when x"A8" =>                                     -- TEST AL, imm8
                                flags_logic8(reg(R_EAX)(7 downto 0) and unsigned(oprnd(7 downto 0)));
                            when x"3C" =>                                     -- CMP AL, imm8
                                flags_sub8(reg(R_EAX)(7 downto 0), unsigned(oprnd(7 downto 0)));

                            when x"81" | x"83" =>
                                if modrm(7 downto 6) = "11" then      -- reg form (memory -> S_LOAD)
                                    digit := modrm(5 downto 3);
                                    a := reg(rm_i);
                                    imm := unsigned(oprnd);
                                    if ir0 = x"83" and oprnd(7) = '1' then
                                        imm(31 downto 8) := (others => '1');
                                    end if;
                                    case digit is
                                        when "000" => flags_add(a, imm, '0'); reg(rm_i) <= res;
                                        when "001" => flags_logic(a or imm);  reg(rm_i) <= res;
                                        when "010" => flags_add(a, imm, cf);  reg(rm_i) <= res;
                                        when "011" => flags_sub(a, imm, cf);  reg(rm_i) <= res;
                                        when "100" => flags_logic(a and imm); reg(rm_i) <= res;
                                        when "101" => flags_sub(a, imm, '0'); reg(rm_i) <= res;
                                        when "110" => flags_logic(a xor imm); reg(rm_i) <= res;
                                        when others => flags_sub(a, imm, '0');   -- CMP (flags only)
                                    end case;
                                end if;

                            -- ALU register forms, both directions. ir0(5:3) picks the op
                            -- (ADD/OR/ADC/SBB/AND/SUB/XOR/CMP); ir0(1) the direction
                            -- (0 = r/m op= r, 1 = r op= r/m). Memory forms go to S_LOAD.
                            when x"01" | x"03" | x"09" | x"0B" | x"11" | x"13" | x"19" | x"1B" |
                                 x"21" | x"23" | x"29" | x"2B" | x"31" | x"33" | x"39" | x"3B" =>
                                if modrm(7 downto 6) = "11" then
                                    if ir0(1) = '1' then a := reg(rg_i); imm := reg(rm_i);
                                    else                 a := reg(rm_i); imm := reg(rg_i); end if;
                                    digit := ir0(5 downto 3);
                                    case digit is
                                        when "000" => flags_add(a, imm, '0');
                                        when "001" => flags_logic(a or imm);
                                        when "010" => flags_add(a, imm, cf);
                                        when "011" => flags_sub(a, imm, cf);
                                        when "100" => flags_logic(a and imm);
                                        when "101" => flags_sub(a, imm, '0');
                                        when "110" => flags_logic(a xor imm);
                                        when others => flags_sub(a, imm, '0');   -- CMP (flags only)
                                    end case;
                                    if digit /= "111" then                       -- not CMP: write dest
                                        if ir0(1) = '1' then reg(rg_i) <= res;
                                        else                 reg(rm_i) <= res; end if;
                                    end if;
                                end if;
                            when x"85" =>                                         -- TEST r/m, r
                                if modrm(7 downto 6) = "11" then
                                    flags_logic(reg(rm_i) and reg(rg_i));
                                end if;

                            -- byte ALU register forms, both directions (ir0(1)):
                            -- the 8-bit twin of the ADD..CMP block above.
                            when x"00" | x"02" | x"08" | x"0A" | x"10" | x"12" | x"18" | x"1A" |
                                 x"20" | x"22" | x"28" | x"2A" | x"30" | x"32" | x"38" | x"3A" =>
                                if modrm(7 downto 6) = "11" then
                                    if ir0(1) = '1' then        -- load-dir: r8 <- r8 op r/m8
                                        do_alu8(ir0(5 downto 3),
                                                unsigned(get_r8(reg, rg_i)), unsigned(get_r8(reg, rm_i)));
                                        if ir0(5 downto 3) /= "111" then
                                            set_r8(rg_i, std_logic_vector(res8)); end if;
                                    else                        -- store-dir: r/m8 <- r/m8 op r8
                                        do_alu8(ir0(5 downto 3),
                                                unsigned(get_r8(reg, rm_i)), unsigned(get_r8(reg, rg_i)));
                                        if ir0(5 downto 3) /= "111" then
                                            set_r8(rm_i, std_logic_vector(res8)); end if;
                                    end if;
                                end if;
                            when x"80" =>                                         -- grp1 r/m8, imm8
                                if modrm(7 downto 6) = "11" then
                                    do_alu8(modrm(5 downto 3),
                                            unsigned(get_r8(reg, rm_i)), unsigned(oprnd(7 downto 0)));
                                    if modrm(5 downto 3) /= "111" then
                                        set_r8(rm_i, std_logic_vector(res8)); end if;
                                end if;
                            when x"84" =>                                         -- TEST r/m8, r8
                                if modrm(7 downto 6) = "11" then
                                    flags_logic8(unsigned(get_r8(reg, rm_i)) and unsigned(get_r8(reg, rg_i)));
                                end if;

                            -- shift / rotate r/m32: by 1 (D1), by CL (D3) or imm8 (C1)
                            when x"C1" | x"D1" | x"D3" =>
                                if modrm(7 downto 6) = "11" then
                                    if    ir0 = x"D1" then scnt := 1;
                                    elsif ir0 = x"D3" then scnt := to_integer(reg(1)(7 downto 0));  -- CL
                                    else  scnt := to_integer(unsigned(immv(7 downto 0)));  -- C1
                                    end if;
                                    do_shift(modrm(5 downto 3), reg(rm_i), scnt);
                                    reg(rm_i) <= res;
                                end if;

                            when x"69" =>                        -- IMUL r32, r/m32, imm32
                                if modrm(7 downto 6) = "11" then
                                    do_imul(signed(reg(rm_i)), signed(immv));
                                    reg(rg_i) <= res;
                                end if;
                            when x"6B" =>                        -- IMUL r32, r/m32, imm8
                                if modrm(7 downto 6) = "11" then
                                    imm := unsigned(immv);
                                    if immv(7) = '1' then imm(31 downto 8) := (others => '1'); end if;
                                    do_imul(signed(reg(rm_i)), signed(imm));
                                    reg(rg_i) <= res;
                                end if;
                            when x"8D" =>                        -- LEA r32, m (the computed EA)
                                reg(rg_i) <= unsigned(ea);
                            when x"FF" =>                        -- INC/DEC r/m32 (grp5 /0 /1)
                                if modrm(7 downto 6) = "11" then
                                    a := reg(rm_i);
                                    if modrm(5 downto 3) = "000" then
                                        flags_add(a, to_unsigned(1, 32), '0');
                                    else
                                        flags_sub(a, to_unsigned(1, 32), '0');
                                    end if;
                                    cf <= old_cf;                -- INC/DEC leave CF unchanged
                                    reg(rm_i) <= res;
                                end if;
                            when x"F7" =>                        -- grp3: TEST/NOT/NEG/MUL/IMUL/DIV/IDIV
                                if modrm(7 downto 6) = "11" then
                                    do_grp3(modrm(5 downto 3), reg(rm_i));
                                    if modrm(5 downto 3) = "010" or modrm(5 downto 3) = "011" then
                                        reg(rm_i) <= res;        -- NOT / NEG write r/m
                                    end if;
                                end if;
                            when x"99" =>                        -- CDQ: EDX = sign-extend EAX
                                if reg(R_EAX)(31) = '1' then reg(2) <= (others => '1');
                                else reg(2) <= (others => '0'); end if;
                            when x"98" =>                        -- CWDE: EAX = sign-extend AX
                                if reg(R_EAX)(15) = '1' then reg(R_EAX)(31 downto 16) <= (others => '1');
                                else reg(R_EAX)(31 downto 16) <= (others => '0'); end if;

                            when x"EB" =>
                                rel := unsigned(oprnd);
                                if oprnd(7) = '1' then rel(31 downto 8) := (others => '1'); end if;
                                eip <= eip + rel;
                            when x"E9" => eip <= eip + unsigned(oprnd);

                            when x"70" | x"71" | x"72" | x"73" | x"74" | x"75" | x"76" | x"77" |
                                 x"78" | x"79" | x"7A" | x"7B" | x"7C" | x"7D" | x"7E" | x"7F" =>
                                cc := ir0(3 downto 0);
                                rel := unsigned(oprnd);
                                if oprnd(7) = '1' then rel(31 downto 8) := (others => '1'); end if;
                                if cond_true(cc, zf, cf, sf, of_f, pf) then
                                    eip <= eip + rel;
                                end if;

                            when x"CD" =>                                     -- INT n (a trap)
                                vec_num <= unsigned(oprnd(7 downto 0));
                                exc_fault <= '0';

                            when others => null;
                        end case;
                    end if;

                    -- ===== V pipe: the co-issued second instruction =====
                    -- Runs in parallel with the U instruction above. Its
                    -- register / flag writes are scheduled AFTER U's, so in
                    -- program order (I2 is younger) the V result wins on every
                    -- flag it defines; INC/DEC leave CF untouched, so U's CF (or
                    -- the pre-pair CF) stands. Pairing forbids RAW/WAW, so V
                    -- reads the pre-pair register file safely.
                    if v_valid = '1' then
                        rm_i := to_integer(unsigned(v_modrm(2 downto 0)));
                        rg_i := to_integer(unsigned(v_modrm(5 downto 3)));
                        n_i  := to_integer(unsigned(v_ir0(2 downto 0)));
                        if v_0f = '1' then
                            if v_ir0 = x"B6" then                               -- MOVZX r32,r8
                                reg(rg_i) <= resize(unsigned(get_r8(reg, rm_i)), 32);
                            end if;
                        else
                            case v_ir0 is
                                when x"90" => null;                             -- NOP
                                when x"B0" | x"B1" | x"B2" | x"B3" |
                                     x"B4" | x"B5" | x"B6" | x"B7" =>           -- MOV r8, imm8
                                    set_r8(n_i, v_oprnd(7 downto 0));
                                when x"B8" | x"B9" | x"BA" | x"BB" |
                                     x"BC" | x"BD" | x"BE" | x"BF" =>           -- MOV r32/r16, imm
                                    if v_p66 = '1' then reg(n_i)(15 downto 0) <= unsigned(v_oprnd(15 downto 0));
                                    else reg(n_i) <= unsigned(v_oprnd); end if;
                                when x"89" =>                                   -- MOV r/m32,r32 (reg)
                                    if v_p66 = '1' then reg(rm_i)(15 downto 0) <= reg(rg_i)(15 downto 0);
                                    else reg(rm_i) <= reg(rg_i); end if;
                                when x"8B" =>                                   -- MOV r32,r/m32 (reg)
                                    if v_p66 = '1' then reg(rg_i)(15 downto 0) <= reg(rm_i)(15 downto 0);
                                    else reg(rg_i) <= reg(rm_i); end if;
                                when x"88" => set_r8(rm_i, get_r8(reg, rg_i));  -- MOV r/m8,r8 (reg)
                                when x"8A" => set_r8(rg_i, get_r8(reg, rm_i));  -- MOV r8,r/m8 (reg)
                                when x"C6" => set_r8(rm_i, v_oprnd(7 downto 0));
                                when x"C7" =>
                                    if v_p66 = '1' then reg(rm_i)(15 downto 0) <= unsigned(v_oprnd(15 downto 0));
                                    else reg(rm_i) <= unsigned(v_oprnd); end if;

                                when x"40" | x"41" | x"42" | x"43" |           -- INC (CF preserved:
                                     x"44" | x"45" | x"46" | x"47" =>           -- no cf assignment)
                                    flags_add(reg(n_i), to_unsigned(1, 32), '0'); reg(n_i) <= res;
                                when x"48" | x"49" | x"4A" | x"4B" |           -- DEC (CF preserved)
                                     x"4C" | x"4D" | x"4E" | x"4F" =>
                                    flags_sub(reg(n_i), to_unsigned(1, 32), '0'); reg(n_i) <= res;

                                when x"05" => flags_add(reg(R_EAX), unsigned(v_oprnd), '0'); reg(R_EAX) <= res;
                                when x"2D" => flags_sub(reg(R_EAX), unsigned(v_oprnd), '0'); reg(R_EAX) <= res;
                                when x"3D" => flags_sub(reg(R_EAX), unsigned(v_oprnd), '0');
                                when x"25" => flags_logic(reg(R_EAX) and unsigned(v_oprnd)); reg(R_EAX) <= res;
                                when x"0D" => flags_logic(reg(R_EAX) or  unsigned(v_oprnd)); reg(R_EAX) <= res;
                                when x"35" => flags_logic(reg(R_EAX) xor unsigned(v_oprnd)); reg(R_EAX) <= res;

                                when x"04" =>                                  -- ADD AL, imm8
                                    a := resize(reg(R_EAX)(7 downto 0), 32);
                                    res8 := reg(R_EAX)(7 downto 0) + unsigned(v_oprnd(7 downto 0));
                                    cf <= '1' when a + unsigned(v_oprnd(7 downto 0)) > 255 else '0';
                                    of_f <= (reg(R_EAX)(7) xnor v_oprnd(7)) and (res8(7) xor reg(R_EAX)(7));
                                    af <= '1' when resize(reg(R_EAX)(3 downto 0), 5) + unsigned(v_oprnd(3 downto 0)) > 15 else '0';
                                    set_szp8(res8);
                                    reg(R_EAX)(7 downto 0) <= res8;
                                when x"2C" => flags_sub8(reg(R_EAX)(7 downto 0), unsigned(v_oprnd(7 downto 0))); reg(R_EAX)(7 downto 0) <= res8;
                                when x"0C" => flags_logic8(reg(R_EAX)(7 downto 0) or  unsigned(v_oprnd(7 downto 0))); reg(R_EAX)(7 downto 0) <= res8;
                                when x"34" => flags_logic8(reg(R_EAX)(7 downto 0) xor unsigned(v_oprnd(7 downto 0))); reg(R_EAX)(7 downto 0) <= res8;
                                when x"24" => flags_logic8(reg(R_EAX)(7 downto 0) and unsigned(v_oprnd(7 downto 0))); reg(R_EAX)(7 downto 0) <= res8;
                                when x"A8" => flags_logic8(reg(R_EAX)(7 downto 0) and unsigned(v_oprnd(7 downto 0)));
                                when x"3C" => flags_sub8(reg(R_EAX)(7 downto 0), unsigned(v_oprnd(7 downto 0)));

                                when x"81" | x"83" =>
                                    digit := v_modrm(5 downto 3);
                                    a := reg(rm_i);
                                    imm := unsigned(v_oprnd);
                                    if v_ir0 = x"83" and v_oprnd(7) = '1' then imm(31 downto 8) := (others => '1'); end if;
                                    case digit is
                                        when "000" => flags_add(a, imm, '0'); reg(rm_i) <= res;
                                        when "001" => flags_logic(a or imm);  reg(rm_i) <= res;
                                        when "100" => flags_logic(a and imm); reg(rm_i) <= res;
                                        when "101" => flags_sub(a, imm, '0'); reg(rm_i) <= res;
                                        when "110" => flags_logic(a xor imm); reg(rm_i) <= res;
                                        when others => flags_sub(a, imm, '0');          -- 111 = CMP
                                    end case;

                                when x"01" => flags_add(reg(rm_i), reg(rg_i), '0'); reg(rm_i) <= res;
                                when x"03" => flags_add(reg(rg_i), reg(rm_i), '0'); reg(rg_i) <= res;
                                when x"29" => flags_sub(reg(rm_i), reg(rg_i), '0'); reg(rm_i) <= res;
                                when x"39" => flags_sub(reg(rm_i), reg(rg_i), '0');
                                when x"21" => flags_logic(reg(rm_i) and reg(rg_i)); reg(rm_i) <= res;
                                when x"09" => flags_logic(reg(rm_i) or  reg(rg_i)); reg(rm_i) <= res;
                                when x"31" => flags_logic(reg(rm_i) xor reg(rg_i)); reg(rm_i) <= res;
                                when x"85" => flags_logic(reg(rm_i) and reg(rg_i));
                                when others => null;
                            end case;
                        end if;
                    end if;

                -- ===== Memory transactions =====
                when S_LOAD  =>
                    rg_i := to_integer(unsigned(modrm(5 downto 3)));
                    bv := ldv(7 downto 0);
                    if split = '1' and q_idx = 0 then
                        lo_tmp <= data_in;                               -- 1st half of a split load
                        q_idx <= 1;
                    elsif ir_0f = '0' and (ir0 = x"81" or ir0 = x"83") then
                        -- grp1 [mem], imm : compute, flags, latch result for the store
                        digit := modrm(5 downto 3);
                        a := unsigned(ldv);
                        imm := unsigned(immv);
                        if ir0 = x"83" and immv(7) = '1' then imm(31 downto 8) := (others => '1'); end if;
                        case digit is
                            when "000" => flags_add(a, imm, '0');
                            when "001" => flags_logic(a or imm);
                            when "010" => flags_add(a, imm, cf);
                            when "011" => flags_sub(a, imm, cf);
                            when "100" => flags_logic(a and imm);
                            when "101" => flags_sub(a, imm, '0');
                            when "110" => flags_logic(a xor imm);
                            when others => flags_sub(a, imm, '0');       -- CMP (flags only)
                        end case;
                        rmw_res <= res; q_idx <= 0;
                    elsif ir_0f = '0' and ir0 = x"85" then               -- TEST [mem], r (flags only)
                        flags_logic(unsigned(ldv) and reg(rg_i));
                    elsif ir_0f = '0' and (ir0 = x"01" or ir0 = x"03" or ir0 = x"09" or ir0 = x"0B" or
                           ir0 = x"11" or ir0 = x"13" or ir0 = x"19" or ir0 = x"1B" or
                           ir0 = x"21" or ir0 = x"23" or ir0 = x"29" or ir0 = x"2B" or
                           ir0 = x"31" or ir0 = x"33" or ir0 = x"39" or ir0 = x"3B") then
                        -- ADD..CMP with a memory operand. ir0(1): 1 = r <- r op [m] (write
                        -- register), 0 = [m] <- [m] op r (latch result for the RMW store).
                        if ir0(1) = '1' then a := reg(rg_i); imm := unsigned(ldv);
                        else                 a := unsigned(ldv); imm := reg(rg_i); end if;
                        digit := ir0(5 downto 3);
                        case digit is
                            when "000" => flags_add(a, imm, '0');
                            when "001" => flags_logic(a or imm);
                            when "010" => flags_add(a, imm, cf);
                            when "011" => flags_sub(a, imm, cf);
                            when "100" => flags_logic(a and imm);
                            when "101" => flags_sub(a, imm, '0');
                            when "110" => flags_logic(a xor imm);
                            when others => flags_sub(a, imm, '0');       -- CMP (flags only)
                        end case;
                        if ir0(1) = '1' then
                            if digit /= "111" then reg(rg_i) <= res; end if;  -- not CMP
                        else
                            rmw_res <= res; q_idx <= 0;                   -- RMW: store happens next
                        end if;
                    elsif ir_0f = '0' and is_alu8(ir0) then              -- byte ADD..CMP with [m8]
                        if ir0(1) = '1' then                             -- load-dir: r8 <- r8 op [m8]
                            do_alu8(ir0(5 downto 3), unsigned(get_r8(reg, rg_i)), unsigned(bv));
                            if ir0(5 downto 3) /= "111" then set_r8(rg_i, std_logic_vector(res8)); end if;
                        else                                             -- store-dir: [m8] <- [m8] op r8
                            do_alu8(ir0(5 downto 3), unsigned(bv), unsigned(get_r8(reg, rg_i)));
                            if ir0(5 downto 3) /= "111" then             -- CMP (111): flags only
                                rmw_res <= resize(res8, 32); q_idx <= 0;
                            end if;
                        end if;
                    elsif ir_0f = '0' and ir0 = x"80" then               -- grp1 [m8], imm8
                        do_alu8(modrm(5 downto 3), unsigned(bv), unsigned(immv(7 downto 0)));
                        if modrm(5 downto 3) /= "111" then               -- not CMP
                            rmw_res <= resize(res8, 32); q_idx <= 0;
                        end if;
                    elsif ir_0f = '0' and ir0 = x"84" then               -- TEST [m8], r8 (flags only)
                        flags_logic8(unsigned(bv) and unsigned(get_r8(reg, rg_i)));
                    elsif ir_0f = '1' and ir0 = x"AF" then               -- IMUL r32, [m]
                        do_imul(signed(reg(rg_i)), signed(ldv)); reg(rg_i) <= res;
                    elsif ir_0f = '0' and ir0 = x"69" then               -- IMUL r32, [m], imm32
                        do_imul(signed(ldv), signed(immv)); reg(rg_i) <= res;
                    elsif ir_0f = '0' and ir0 = x"6B" then               -- IMUL r32, [m], imm8
                        imm := unsigned(immv);
                        if immv(7) = '1' then imm(31 downto 8) := (others => '1'); end if;
                        do_imul(signed(ldv), signed(imm)); reg(rg_i) <= res;
                    elsif ir_0f = '0' and (ir0 = x"C1" or ir0 = x"D1" or ir0 = x"D3") then  -- shift [m]
                        if    ir0 = x"D1" then scnt := 1;
                        elsif ir0 = x"D3" then scnt := to_integer(reg(1)(7 downto 0));
                        else  scnt := to_integer(unsigned(immv(7 downto 0)));
                        end if;
                        do_shift(modrm(5 downto 3), unsigned(ldv), scnt);
                        rmw_res <= res; q_idx <= 0;
                    elsif ir_0f = '0' and ir0 = x"FF" then               -- INC/DEC [m] (RMW)
                        old_cf := cf;
                        a := unsigned(ldv);
                        if modrm(5 downto 3) = "000" then
                            flags_add(a, to_unsigned(1, 32), '0');
                        else
                            flags_sub(a, to_unsigned(1, 32), '0');
                        end if;
                        cf <= old_cf;
                        rmw_res <= res; q_idx <= 0;
                    elsif ir_0f = '0' and ir0 = x"F7" then               -- grp3 [m] (TEST/NOT/NEG/MUL/DIV)
                        do_grp3(modrm(5 downto 3), unsigned(ldv));
                        if modrm(5 downto 3) = "010" or modrm(5 downto 3) = "011" then
                            rmw_res <= res; q_idx <= 0;                  -- NOT/NEG store back
                        end if;
                    elsif ir_0f = '1' and ir0 = x"B7" then               -- MOVZX r32,[m16]
                        reg(rg_i) <= resize(unsigned(ldv(15 downto 0)), 32);
                    elsif ir_0f = '1' and ir0 = x"BE" then               -- MOVSX r32,[m8]
                        reg(rg_i) <= unsigned(resize(signed(bv), 32));
                    elsif ir_0f = '1' and ir0 = x"BF" then               -- MOVSX r32,[m16]
                        reg(rg_i) <= unsigned(resize(signed(ldv(15 downto 0)), 32));
                    elsif ir_0f = '1' then                               -- MOVZX r32,[m8]
                        reg(rg_i) <= resize(unsigned(bv), 32);
                    elsif ir0 = x"A1" and opsz16 = '0' then
                        reg(R_EAX) <= unsigned(ldv);                     -- MOV EAX,moffs32
                    elsif ir0 = x"D7" then
                        reg(R_EAX)(7 downto 0) <= unsigned(bv);          -- XLAT
                    elsif ir0 = x"8A" or ir0 = x"A0" then
                        set_r8(rg_i, bv);                                -- MOV r8,[m8] / AL,moffs8
                    elsif opsz16 = '1' then                              -- MOV r16,[m16] / AX,moffs
                        reg(rg_i)(15 downto 0) <= unsigned(ldv(15 downto 0));
                    else
                        reg(rg_i) <= unsigned(ldv);                      -- MOV r32,[m32]
                    end if;
                when S_STORE =>
                    if split = '1' and q_idx = 0 then q_idx <= 1; end if;

                when S_PUSH  => reg(R_ESP) <= reg(R_ESP) - 4;
                when S_POP =>
                    if ir0 = x"C9" then                                  -- LEAVE: EBP<-[EBP], ESP<-EBP+4
                        reg(5) <= unsigned(data_in);
                        reg(R_ESP) <= reg(5) + 4;
                    elsif ir0 = x"9D" then                               -- POPFD
                        load_flags(data_in);
                        reg(R_ESP) <= reg(R_ESP) + 4;
                    else
                        rm_i := to_integer(unsigned(ir0(2 downto 0)));
                        reg(rm_i) <= unsigned(data_in);
                        if rm_i /= R_ESP then reg(R_ESP) <= reg(R_ESP) + 4; end if;
                    end if;

                -- PUSHAD: EAX ECX EDX EBX (original)ESP EBP ESI EDI, ESP drops 32.
                when S_PUSHA =>
                    q_idx <= q_idx + 1;
                    if q_idx = 7 then reg(R_ESP) <= reg(R_ESP) - 32; end if;
                -- POPAD: EDI ESI EBP (skip ESP) EBX EDX ECX EAX, ESP rises 32.
                when S_POPA =>
                    n_i := 7 - q_idx;
                    if n_i /= R_ESP then reg(n_i) <= unsigned(data_in); end if;
                    q_idx <= q_idx + 1;
                    if q_idx = 7 then reg(R_ESP) <= reg(R_ESP) + 32; end if;

                when S_CALL_PUSH =>
                    reg(R_ESP) <= reg(R_ESP) - 4;
                    eip <= eip + unsigned(oprnd);
                when S_RET_POP =>
                    eip <= unsigned(data_in);
                    reg(R_ESP) <= reg(R_ESP) + 4;

                -- ===== Interrupts / exceptions =====
                -- INTA: the PIC hands over the vector of the IRQ it is acknowledging.
                when S_INTA =>
                    vec_num <= unsigned(inta_vec);
                    exc_fault <= '0';
                -- Read the handler address from the vector table.
                when S_INT_VEC =>
                    vec_target <= unsigned(data_in);
                    q_idx <= 0;
                    pfx_lock <= '0'; pfx_66 <= '0';
                -- Push EFLAGS, CS, EIP (one dword per cycle); then clear IF and
                -- jump to the handler.
                when S_INT_PUSH =>
                    reg(R_ESP) <= reg(R_ESP) - 4;
                    q_idx <= q_idx + 1;
                    if q_idx = 2 then
                        eip <= vec_target;
                        if_f <= '0';
                        sti_shadow <= '0';
                        new_insn <= '1';
                    end if;
                -- IRET: pop EIP, CS (discarded: flat model), EFLAGS.
                when S_IRET_POP =>
                    reg(R_ESP) <= reg(R_ESP) + 4;
                    q_idx <= q_idx + 1;
                    case q_idx is
                        when 0 => eip <= unsigned(data_in);
                        when 1 => null;
                        when others => load_flags(data_in);
                    end case;

                when S_XCHG_R => xchg_temp <= unsigned(data_in);
                when S_XCHG_W => reg(R_EAX) <= xchg_temp;

                -- IN AL/AX/EAX, port : latch the value the device returns.
                -- Like a real x86, IN AL / IN AX leave the rest of EAX untouched.
                when S_IN  =>
                    if ir0 = x"E4" or ir0 = x"EC" then
                        reg(R_EAX)(7 downto 0) <= unsigned(io_din(7 downto 0));
                    elsif opsz16 = '1' then
                        reg(R_EAX)(15 downto 0) <= unsigned(io_din(15 downto 0));
                    else
                        reg(R_EAX) <= unsigned(io_din);
                    end if;
                when S_OUT => null;   -- OUT drives the I/O bus combinationally

                when S_LIDT0 => desc0 <= data_in;
                when S_LIDT1 =>
                    idtr_base <= unsigned(data_in(15 downto 0)) & unsigned(desc0(31 downto 16));

                -- CMPXCHG [m], r : compare EAX with mem; if equal install r, ZF=1
                when S_CMPX_R =>
                    flags_sub(reg(R_EAX), unsigned(data_in), '0');  -- sets ZF/CF/...
                    if reg(R_EAX) /= unsigned(data_in) then
                        reg(R_EAX) <= unsigned(data_in);            -- not equal: EAX <- mem
                    end if;
                when S_CMPX_W => null;                              -- equal: bus writes r

                -- SSE 128/32-bit memory transfers (q_idx counts the dwords)
                when S_XMM_LD =>
                    rg_i := to_integer(unsigned(modrm(5 downto 3)));
                    if ir0 = x"6E" then            -- MOVD: low dword, zero upper
                        xmm(rg_i) <= ZERO96 & data_in;
                    else                            -- MOVDQA: lane q_idx
                        case q_idx is
                            when 0 => xmm(rg_i)(31 downto 0)    <= data_in;
                            when 1 => xmm(rg_i)(63 downto 32)   <= data_in;
                            when 2 => xmm(rg_i)(95 downto 64)   <= data_in;
                            when others => xmm(rg_i)(127 downto 96) <= data_in;
                        end case;
                    end if;
                    q_idx <= q_idx + 1;
                when S_XMM_ST =>
                    q_idx <= q_idx + 1;

                when S_MULDIV_WAIT => null;   -- result already written; just burning latency
                when S_HALT => null;
            end case;
            end if;

            -- ===== Pipeline: a new instruction enters EX from D2 =====
            -- (a cycle spent waiting for memory does not use up the first EX cycle)
            if (not is_bus) or ex_bus_ok then ex_first <= '0'; end if;
            if ex_accept then
                ir0 <= d2.ir0; ir_0f <= d2.is0f; pfx_66 <= d2.p66; pfx_lock <= d2.plock;
                modrm <= d2.modrm; oprnd <= d2.oprnd; imm_r <= d2.imm_r; disp_n <= d2.disp_n;
                ex_ea <= ea_d2;                       -- the address D2 generated
                -- V pipe: latch the co-issued second instruction (NO_INSN if none)
                v_ir0 <= d2v.ir0; v_0f <= d2v.is0f; v_p66 <= d2v.p66;
                v_modrm <= d2v.modrm; v_oprnd <= d2v.oprnd; v_imm_r <= d2v.imm_r;
                v_valid <= d2v.valid; v_seq <= d2v.seq; v_nxt <= d2v.nxt; v_eip <= d2v.eip;
                ex_pred_tk <= d2.pred_tk; ex_pred_tgt <= d2.pred_tgt;   -- BTB prediction for EX
                if d2v.valid = '1' then pairs_ctr <= pairs_ctr + 1; end if;
                eip <= d2.nxt;                        -- EIP of the next instruction
                ip_start <= d2.eip;                   -- restart point if it faults
                ex_seq <= d2.seq;
                q_idx <= 0;
                opsz16 <= d2.p66;
                ex_first <= '1';
                ex_irq <= '0';
                -- SERIALIZE: drain after every instruction so none overlap in the
                -- pipeline (models a non-pipelined machine).
                if SERIALIZE then ex_drain <= '1';
                else              ex_drain <= drains(d2.ir0, d2.is0f); end if;
                if ex_entry(d2.ir0, d2.is0f, d2.modrm, d2.p66) /= S_EXECUTE then
                    sti_shadow <= '0';                -- (EXECUTE clears it otherwise)
                end if;
                if d2.pfault = '1' then               -- its bytes faulted in PF: #PF now
                    vec_num <= to_unsigned(14, 8);
                    exc_fault <= '1';
                    cr2 <= pf_fault_addr;
                end if;
            end if;
            -- Interrupts and exceptions end in a jump through the vector table:
            -- the pipeline drains and refetches after them.
            if next_state = S_INTA then
                ex_irq <= '1'; ex_first <= '1'; ex_seq <= seq_ctr;
            end if;
            if next_state = S_INTA or next_state = S_INT_VEC then
                ex_drain <= '1';
            end if;
        end if;
    end process;

    -- MUL/IMUL/DIV/IDIV latency counter: counts cycles spent in S_MULDIV_WAIT so
    -- ex_next_proc can hold EX there for the Pentium latency, then drops to 0 so
    -- the next such op starts fresh. Isolated from the datapath for clarity.
    md_cnt_proc : process(clk, reset)
    begin
        if reset = '1' then
            md_cnt <= 0;
        elsif rising_edge(clk) then
            if state = S_MULDIV_WAIT then md_cnt <= md_cnt + 1;
            else                          md_cnt <= 0;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- EX's side of the memory bus (combinational); muxed with PF below.
    ----------------------------------------------------------------------------
    ex_bus_proc : process(all)
        variable rg_i : integer range 0 to 7;
        variable src  : std_logic_vector(31 downto 0);
        variable m4   : std_logic_vector(3 downto 0);
        variable be64 : unsigned(7 downto 0);
        variable d64  : unsigned(63 downto 0);
    begin
        ex_addr <= (others => '0');
        ex_dout <= (others => '0');
        ex_we <= '0';
        ex_be <= "0000";
        rg_i := to_integer(unsigned(modrm(5 downto 3)));

        case state is
            when S_LOAD =>                    -- aligned dword(s) holding the operand
                if q_idx = 1 then ex_addr <= std_logic_vector(ea_al + 4);
                else              ex_addr <= std_logic_vector(ea_al); end if;

            when S_STORE =>
                -- Source operand of the store.
                if mem_alu_wb(ir0, modrm) then
                    src := std_logic_vector(rmw_res);                  -- RMW: computed ALU result
                elsif ir_0f = '1' and ir0(7 downto 4) = x"9" then      -- SETcc [m8]
                    if cond_true(ir0(3 downto 0), zf, cf, sf, of_f, pf) then src := x"00000001";
                    else src := x"00000000"; end if;
                elsif ir0 = x"A3" then
                    src := std_logic_vector(reg(R_EAX));                -- MOV moffs32,EAX
                elsif ir0 = x"88" or ir0 = x"A2" then
                    src := x"000000" & get_r8(reg, rg_i);               -- MOV [m8],r8 / moffs8,AL
                elsif ir0 = x"C6" or ir0 = x"C7" then
                    src := immv;                                        -- MOV [m],imm
                else
                    src := std_logic_vector(reg(rg_i));                 -- MOV [m],r32/r16
                end if;
                -- Shift the operand and its byte enables to byte ea_k of the
                -- dword; whatever spills past byte 3 goes out in a 2nd cycle.
                case msize is
                    when "00"   => m4 := "0001";
                    when "01"   => m4 := "0011";
                    when others => m4 := "1111";
                end case;
                be64 := shift_left(resize(unsigned(m4), 8), ea_k);
                d64  := shift_left(resize(unsigned(src), 64), 8 * ea_k);
                if q_idx = 1 then
                    ex_addr <= std_logic_vector(ea_al + 4);
                    ex_dout <= std_logic_vector(d64(63 downto 32));
                    ex_be       <= std_logic_vector(be64(7 downto 4));
                else
                    ex_addr <= std_logic_vector(ea_al);
                    ex_dout <= std_logic_vector(d64(31 downto 0));
                    ex_be       <= std_logic_vector(be64(3 downto 0));
                end if;
                ex_we <= '1';

            when S_PUSH =>
                ex_addr <= std_logic_vector(reg(R_ESP) - 4);
                if ir0 = x"68" then
                    ex_dout <= oprnd;                           -- PUSH imm32
                elsif ir0 = x"6A" then
                    ex_dout <= std_logic_vector(sext8(oprnd));  -- PUSH imm8 (sign-ext)
                elsif ir0 = x"9C" then
                    ex_dout <= eflags_v;                        -- PUSHFD
                else
                    ex_dout <= std_logic_vector(reg(to_integer(unsigned(ir0(2 downto 0))))); -- PUSH r32
                end if;
                ex_we <= '1'; ex_be <= "1111";
            when S_POP =>
                if ir0 = x"C9" then ex_addr <= std_logic_vector(reg(5));   -- LEAVE reads [EBP]
                else                ex_addr <= std_logic_vector(reg(R_ESP)); end if;

            when S_PUSHA =>
                ex_addr <= std_logic_vector(reg(R_ESP) - to_unsigned(4 * (q_idx + 1), 32));
                ex_dout <= std_logic_vector(reg(q_idx));        -- reg(4) = original ESP
                ex_we <= '1'; ex_be <= "1111";
            when S_POPA =>
                ex_addr <= std_logic_vector(reg(R_ESP) + to_unsigned(4 * q_idx, 32));

            when S_CALL_PUSH =>
                ex_addr <= std_logic_vector(reg(R_ESP) - 4);
                ex_dout <= std_logic_vector(eip);
                ex_we <= '1'; ex_be <= "1111";
            when S_RET_POP =>
                ex_addr <= std_logic_vector(reg(R_ESP));

            when S_INT_VEC =>           -- read vector table entry [IDTR + 4*vector]
                ex_addr <= std_logic_vector(idtr_base + shift_left(resize(vec_num, 32), 2));
            when S_INT_PUSH =>          -- push EFLAGS, CS, return EIP
                ex_addr <= std_logic_vector(reg(R_ESP) - 4);
                case q_idx is
                    when 0 => ex_dout <= eflags_v;
                    when 1 => ex_dout <= CS_SEL;
                    when others =>
                        if exc_fault = '1' then
                            ex_dout <= std_logic_vector(ip_start);  -- fault: restart insn
                        else
                            ex_dout <= std_logic_vector(eip);       -- trap / IRQ: next insn
                        end if;
                end case;
                ex_we <= '1'; ex_be <= "1111";
            when S_IRET_POP =>
                ex_addr <= std_logic_vector(reg(R_ESP));

            when S_XCHG_R =>
                ex_addr <= oprnd;
            when S_XCHG_W =>
                ex_addr <= oprnd;
                ex_dout <= std_logic_vector(reg(R_EAX));
                ex_we <= '1'; ex_be <= "1111";

            when S_LIDT0 =>
                ex_addr <= oprnd;
            when S_LIDT1 =>
                ex_addr <= std_logic_vector(unsigned(oprnd) + 4);

            when S_CMPX_R =>
                ex_addr <= oprnd;
            when S_CMPX_W =>
                ex_addr <= oprnd;
                ex_dout <= std_logic_vector(reg(to_integer(unsigned(modrm(5 downto 3)))));
                ex_we <= '1'; ex_be <= "1111";

            when S_XMM_LD =>
                ex_addr <= std_logic_vector(unsigned(oprnd) + to_unsigned(q_idx * 4, 32));
            when S_XMM_ST =>
                ex_addr <= std_logic_vector(unsigned(oprnd) + to_unsigned(q_idx * 4, 32));
                case q_idx is
                    when 0 => ex_dout <= xmm(rg_i)(31 downto 0);
                    when 1 => ex_dout <= xmm(rg_i)(63 downto 32);
                    when 2 => ex_dout <= xmm(rg_i)(95 downto 64);
                    when others => ex_dout <= xmm(rg_i)(127 downto 96);
                end case;
                ex_we <= '1'; ex_be <= "1111";

            when others => null;
        end case;
    end process;

    ----------------------------------------------------------------------------
    -- I/O bus driver (combinational): the separate x86 I/O address space.
    --   E4-E7 take the port from the imm8; EC-EF take it from DX (EDX[15:0]).
    --   E4/E6/EC/EE are byte (AL) transfers; E5/E7/ED/EF are dword (EAX), or
    --   word (AX) with the 66 operand-size prefix.
    ----------------------------------------------------------------------------
    io_proc : process(all)
        variable port_no : std_logic_vector(15 downto 0);
        variable sz      : std_logic_vector(1 downto 0);
    begin
        io_addr <= (others => '0');
        io_dout <= (others => '0');
        io_re   <= '0';
        io_we   <= '0';
        if ir0 = x"E4" or ir0 = x"E5" or ir0 = x"E6" or ir0 = x"E7" then
            port_no := x"00" & oprnd(7 downto 0);            -- imm8 port
        else
            port_no := std_logic_vector(reg(2)(15 downto 0)); -- DX
        end if;
        if ir0 = x"E4" or ir0 = x"E6" or ir0 = x"EC" or ir0 = x"EE" then
            sz := "00";
        elsif opsz16 = '1' then
            sz := "01";
        else
            sz := "10";
        end if;
        io_size <= sz;
        case state is
            when S_IN =>
                io_addr <= port_no;
                io_re   <= '1';
            when S_OUT =>
                io_addr <= port_no;
                io_we   <= '1';
                case sz is
                    when "00"   => io_dout <= x"000000" & std_logic_vector(reg(R_EAX)(7 downto 0));
                    when "01"   => io_dout <= x"0000" & std_logic_vector(reg(R_EAX)(15 downto 0));
                    when others => io_dout <= std_logic_vector(reg(R_EAX));
                end case;
            when others => null;
        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Status / debug taps
    ----------------------------------------------------------------------------
    halted <= '1' when state = S_HALT else '0';
    inta   <= '1' when state = S_INTA else '0';

    -- Paging interface out to the MMU.
    pg_enable <= cr0(31);
    cr3_out   <= std_logic_vector(cr3);
    -- Writing CR3 (MOV CR3, r32 = 0F 22 /011) flushes the TLB, as on x86.
    tlb_flush <= '1' when (state = S_EXECUTE and ir_0f = '1' and ir0 = x"22"
                          and modrm(5 downto 3) = "011" and ud = '0') else '0';
    dbg_cr2   <= std_logic_vector(cr2);
    dbg_cr3   <= std_logic_vector(cr3);

    -- Assert LOCK# for atomic read-modify-write (XCHG is implicitly locked;
    -- CMPXCHG requires the LOCK prefix on SMP).
    lock <= '1' when state = S_XCHG_R or state = S_XCHG_W or
                     state = S_CMPX_R or state = S_CMPX_W else '0';

    mem_req <= '1' when owner /= BUS_NONE else '0';
    mem_ifetch <= '1' when owner = BUS_PF else '0';   -- prefetch == instruction fetch
    dbg12_bus_lock <= '1' when owner /= BUS_NONE else '0';
    dbg13_xchg_active <= '1' when state = S_XCHG_R or state = S_XCHG_W or
                                  state = S_CMPX_R or state = S_CMPX_W else '0';

    dbg_ud     <= '1' when state = S_EXECUTE and ud = '1' else '0';

    ----------------------------------------------------------------------------
    -- D1: find the length of the instruction at the head of the prefetch queue
    -- (prefixes, 0F, opcode, ModR/M, displacement, immediate) and split out its
    -- fields. It can leave D1 only when ALL of its bytes are in the queue.
    ----------------------------------------------------------------------------
    d1_proc : process(all)
        variable i, dl, il, n : integer range 0 to 99;
        variable p66, plk, is0f : std_logic;
        variable op, m, sb : std_logic_vector(7 downto 0);
        variable r  : insn_t;
        variable ok, short : boolean;
    begin
        r := NO_INSN; i := 0; p66 := '0'; plk := '0'; is0f := '0';
        op := x"00"; m := x"00"; sb := x"00"; dl := 0; il := 0; short := false;
        while i < 4 and i < pq_cnt and is_prefix(pq(i)) loop
            if pq(i) = x"66" then p66 := '1'; end if;
            if pq(i) = x"F0" then plk := '1'; end if;
            i := i + 1;
        end loop;
        if i < pq_cnt and pq(i) = x"0F" then
            is0f := '1';
            if i + 1 < pq_cnt then op := pq(i + 1); else short := true; end if;
            i := i + 2;
        elsif i < pq_cnt then
            op := pq(i);
            i := i + 1;
        else
            short := true;
        end if;
        if not short then
            if (is0f = '1' and op(7 downto 4) /= x"8") or (is0f = '0' and has_modrm(op)) then
                if i < pq_cnt then
                    m := pq(i); i := i + 1;
                    if has_sib(m) then                         -- consume the SIB byte
                        if i < pq_cnt then sb := pq(i); i := i + 1;
                        else short := true; end if;
                    end if;
                    dl := disp_len_s(m, sb); il := imm_len_grp(op, is0f, p66, m);
                else
                    short := true;
                end if;
            elsif is0f = '1' then
                il := 4;                                       -- 0F 8x Jcc rel32
            else
                il := imm_len_op(op, p66);
            end if;
        end if;
        n  := i + dl + il;
        ok := (not short) and n <= pq_cnt;
        if ok then
            r.valid := '1'; r.eip := pq_eip; r.nxt := pq_eip + n;
            r.ir0 := op; r.is0f := is0f; r.p66 := p66; r.plock := plk;
            r.modrm := m; r.sib := sb; r.disp_n := dl; r.seq := seq_ctr;
            -- displacement -> oprnd; an immediate after a displacement -> imm_r;
            -- an immediate on its own -> oprnd (exactly as the multi-cycle core)
            for k in 0 to 3 loop
                if dl > 0 then
                    if k < dl and i + k < PQ_SIZE then r.oprnd(8*k+7 downto 8*k) := pq(i + k); end if;
                    if k < il and i + dl + k < PQ_SIZE then r.imm_r(8*k+7 downto 8*k) := pq(i + dl + k); end if;
                else
                    if k < il and i + k < PQ_SIZE then r.oprnd(8*k+7 downto 8*k) := pq(i + k); end if;
                end if;
            end loop;
            d1_len <= n;
        elsif pf_fault = '1' then
            -- The rest of this instruction lies in a page that is not present:
            -- it goes down the pipe as a #PF that is raised only if it executes.
            r.valid := '1'; r.pfault := '1'; r.eip := pq_eip; r.nxt := pq_eip; r.seq := seq_ctr;
            ok := true;
            d1_len <= 0;
        else
            d1_len <= 0;
        end if;
        d1 <= r;
        if ok then d1_ok <= '1'; else d1_ok <= '0'; end if;
    end process;

    -- D1, second slot: decode the instruction right behind the queue head and
    -- decide whether the two may co-issue to U and V (Alpert & Avnon, Fig. 5).
    d1b_proc : process(all)
        variable b : decoded_t;
    begin
        if d1_ok = '1' and d1.pfault = '0' then
            b := decode_one(pq, pq_cnt, d1_len, pq_eip + d1_len, seq_ctr + 1);
        else
            b := (NO_INSN, 0, '0');
        end if;
        d1b     <= b.insn;
        d1b_ok  <= b.ok;
        d1b_len <= b.len;
        pair_ok <= DUAL_ISSUE and d1_ok = '1' and b.ok = '1'
                   and d1.pfault = '0' and b.insn.pfault = '0'
                   and simple_u(d1.ir0, d1.is0f, d1.p66, d1.plock, d1.modrm)
                   and simple_v(b.insn.ir0, b.insn.is0f, b.insn.p66, b.insn.plock, b.insn.modrm)
                   and (dest_mask(d1.ir0, d1.is0f, d1.modrm)
                        and (dest_mask(b.insn.ir0, b.insn.is0f, b.insn.modrm)
                             or reads_mask(b.insn.ir0, b.insn.is0f, b.insn.modrm))) = x"00";
    end process;

    -- BTB lookup for the branch at the queue head (decode): predict + target.
    btb_pred_proc : process(all)
        variable r : btb_res_t;
    begin
        r := ('0', '0', (others => '0'));
        if BTB_ENABLE and d1.valid = '1' and d1.pfault = '0' and is_ubranch(d1.ir0, d1.is0f) then
            r := btb_lookup(btb, d1.eip);
        end if;
        d1_pred_tk  <= r.hit and r.tk;    -- BTB off -> always predict not-taken
        d1_pred_tgt <= r.tgt;
    end process;

    -- BTB update (clocked): when a U-pipe branch resolves in EX, record whether
    -- the prediction was right and update its 2-bit history / target. First time
    -- a branch is taken it allocates an entry (round-robin within the set).
    btb_proc : process(clk, reset)
        variable s, idx, way, found : integer;
    begin
        if reset = '1' then
            btb <= (others => BTB_INIT);
            btb_rr <= (others => "00");
            btb_seen <= (others => '0'); btb_correct <= (others => '0'); btb_wrong <= (others => '0');
        elsif rising_edge(clk) then
            -- Skip the update if the EX address is still metavalue (a just-woken
            -- AP's first cycle): there is no real branch to learn from yet.
            if ex_ubr and ex_done and not is_x(std_logic_vector(ip_start)) then
                btb_seen <= btb_seen + 1;
                if (br_taken and ex_pred_tk = '1' and u_act_tgt = ex_pred_tgt) or
                   ((not br_taken) and ex_pred_tk = '0') then
                    btb_correct <= btb_correct + 1;
                else
                    btb_wrong <= btb_wrong + 1;
                end if;
                s := btb_set(ip_start);
                found := -1;
                for w in 0 to BTB_WAYS - 1 loop
                    if btb(s*BTB_WAYS + w).valid = '1' and btb(s*BTB_WAYS + w).tag = ip_start then
                        found := w;
                    end if;
                end loop;
                if br_taken then
                    if found >= 0 then
                        idx := s*BTB_WAYS + found;
                        btb(idx).tgt <= u_act_tgt;
                        if btb(idx).ctr /= "11" then btb(idx).ctr <= btb(idx).ctr + 1; end if;
                    else                                        -- allocate (first taken)
                        way := to_integer(btb_rr(s));
                        idx := s*BTB_WAYS + way;
                        btb(idx).valid <= '1';
                        btb(idx).tag   <= ip_start;
                        btb(idx).tgt   <= u_act_tgt;
                        btb(idx).ctr   <= "10";                 -- weakly taken
                        btb_rr(s) <= btb_rr(s) + 1;
                    end if;
                elsif found >= 0 then                           -- not taken: weaken
                    idx := s*BTB_WAYS + found;
                    if btb(idx).ctr /= "00" then btb(idx).ctr <= btb(idx).ctr - 1; end if;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Pipeline control (combinational): branch resolution, bus arbitration,
    -- interlocks, and whether D2 may move into EX this cycle.
    ----------------------------------------------------------------------------
    ctl_proc : process(all)
        variable tk      : boolean;
        variable rel     : unsigned(31 downto 0);
        variable fl      : boolean;
        variable o       : owner_t;
        variable bnd, irq : boolean;
        variable done    : boolean;
        variable vtk     : boolean;
        variable vrel    : unsigned(31 downto 0);
        variable fwd     : flags_t;
        variable umis    : boolean;
        variable tgt_miss : boolean;
        variable agiv, eacc, dtake, sredir : boolean;
    begin
        -- Jcc / JMP resolve in EX (1 cycle). The target is fetched right away.
        tk := false;
        rel := unsigned(oprnd);
        if state = S_EXECUTE and ud = '0' then
            if ir_0f = '1' and ir0(7 downto 4) = x"8" then
                tk := cond_true(ir0(3 downto 0), zf, cf, sf, of_f, pf);          -- Jcc rel32
            elsif ir_0f = '0' and (ir0 = x"EB" or ir0(7 downto 4) = x"7") then
                if oprnd(7) = '1' then rel(31 downto 8) := (others => '1'); end if;
                tk := ir0 = x"EB" or cond_true(ir0(3 downto 0), zf, cf, sf, of_f, pf);
            elsif ir_0f = '0' and ir0 = x"E9" then
                tk := true;                                                       -- JMP rel32
            end if;
        end if;
        br_taken  <= tk;

        -- V pipe branch: a Jcc co-issued with a flag-setter in U. It tests the
        -- flags U produces THIS cycle (forwarded through alu_flags), so cmp+jcc
        -- pairs with no bubble; a taken V branch flushes and refetches like U.
        vtk  := false;
        vrel := unsigned(v_oprnd);
        if state = S_EXECUTE and v_valid = '1' then
            fwd := alu_flags(ir0, ir_0f, modrm, oprnd, reg, (cf, zf, sf, of_f, pf, af));
            if v_0f = '1' and v_ir0(7 downto 4) = x"8" then
                vtk := cond_true(v_ir0(3 downto 0), fwd.zf, fwd.cf, fwd.sf, fwd.of_f, fwd.pf);
            elsif v_0f = '0' and v_ir0(7 downto 4) = x"7" then
                if v_oprnd(7) = '1' then vrel(31 downto 8) := (others => '1'); end if;
                vtk := cond_true(v_ir0(3 downto 0), fwd.zf, fwd.cf, fwd.sf, fwd.of_f, fwd.pf);
            end if;
        end if;
        v_tk     <= vtk;
        v_target <= v_nxt + vrel;

        -- BTB resolution for the U branch in EX. A correctly predicted branch
        -- (direction, and target when taken) does NOT flush -- its path was
        -- already fetched. A misprediction flushes and refetches the right way.
        ex_ubr    <= state = S_EXECUTE and ud = '0' and is_ubranch(ir0, ir_0f);
        u_act_tgt <= eip + rel;
        -- target mismatch, guarded: a parked/just-woken core can present a
        -- metavalue eip/prediction, so only compare when both are settled
        -- (this expression is evaluated every cycle, so it must never warn).
        if is_x(std_logic_vector(eip + rel)) or is_x(std_logic_vector(ex_pred_tgt)) then
            tgt_miss := true;
        else
            tgt_miss := (eip + rel) /= ex_pred_tgt;
        end if;
        umis := (state = S_EXECUTE and ud = '0' and is_ubranch(ir0, ir_0f)) and
                ((tk and (ex_pred_tk = '0' or tgt_miss)) or
                 (not tk and ex_pred_tk = '1'));

        if umis and tk     then br_target <= eip + rel;     -- should have taken
        elsif umis         then br_target <= eip;           -- should have fallen through
        elsif vtk          then br_target <= v_nxt + vrel;
        else                    br_target <= eip + rel; end if;
        fl := redir_pending = '1' or umis or vtk;
        flush_now <= fl;

        -- EX finishes its instruction this cycle?
        done := state /= S_IDLE and state /= S_HALT and ex_nxt = S_IDLE;
        ex_done <= done;
        -- An instruction boundary at which EX may start the next one. A
        -- mispredicted U branch or a taken V branch flushes, so it is not a
        -- boundary; a correctly predicted branch continues into its (already
        -- fetched) path.
        bnd := state = S_IDLE or (done and ex_drain = '0' and not umis and not vtk);
        boundary_ok <= bnd;
        -- INTR between instructions with IF=1 (not right after STI).
        irq := bnd and intr = '1' and if_f = '1' and (sti_shadow = '0' or done);
        take_irq_now <= irq;
        -- AGI: D2 needs, for its address, a register the EX instruction writes.
        agiv := d2.valid = '1' and state /= S_IDLE and
                (dest_mask(ir0, ir_0f, modrm) and use_mask(d2.ir0, d2.is0f, d2.modrm, d2.sib)) /= x"00";
        agi <= agiv;
        eacc := bnd and not irq and d2.valid = '1' and redir_pending = '0'
                and not umis and not vtk and not agiv;
        ex_accept <= eacc;

        -- A predicted-taken branch moving D1 -> D2 redirects fetch to its target
        -- THIS cycle (speculative fetch): the queue flush and the target
        -- prefetch happen together, so a correct prediction loses no cycle.
        dtake  := (not fl) and (d2.valid = '0' or eacc);
        sredir := dtake and d1_ok = '1' and d1_pred_tk = '1';

        -- The one memory bus: a prefetch waiting on `ready` keeps it, then EX
        -- goes first, then PF prefetches if the queue has room (or a flush /
        -- speculative redirect needs the target fetched now).
        if pf_wait = '1' then
            o := BUS_PF;
        elsif is_bus then
            o := BUS_EX;
        elsif (pq_cnt <= PQ_SIZE - 4 or fl or sredir) and (pf_fault = '0' or fl or sredir) then
            o := BUS_PF;
        else
            o := BUS_NONE;
        end if;
        owner     <= o;
        owner_ex  <= o = BUS_EX;
        ex_bus_ok <= o = BUS_EX and ready = '1';
        pf_req    <= o = BUS_PF;
        if pf_wait = '1' then          pf_addr_now <= pf_cur;
        elsif umis and tk then         pf_addr_now <= eip + rel;     -- U mispredict -> target
        elsif umis then                pf_addr_now <= eip;           -- U mispredict -> fall-through
        elsif vtk then                 pf_addr_now <= v_nxt + vrel;  -- V branch target
        elsif sredir then              pf_addr_now <= d1_pred_tgt;   -- speculative target
        elsif redir_pending = '1' then pf_addr_now <= eip;           -- refetch
        else                           pf_addr_now <= fetch_addr;
        end if;
    end process;

    d2_take <= (not flush_now) and (d2.valid = '0' or ex_accept);

    -- Next EX state: an interrupt, the next instruction, or the micro-sequence.
    next_state_proc : process(all)
    begin
        if take_irq_now then
            next_state <= S_INTA;
        elsif ex_accept then
            if d2.pfault = '1' then
                next_state <= S_INT_VEC;
            else
                next_state <= ex_entry(d2.ir0, d2.is0f, d2.modrm, d2.p66);
            end if;
        else
            next_state <= ex_nxt;
        end if;
    end process;

    -- Why a cycle does not start/complete useful work in EX (shown and counted).
    stall_code <= "111" when state = S_HALT else
                  "101" when is_bus and owner_ex and ready = '0' else      -- MEM WAIT
                  "110" when is_bus and not owner_ex else                  -- BUS BUSY
                  bubble_why when state = S_IDLE else                      -- a bubble
                  "001" when ex_first = '0' else                           -- MICROCODE
                  "000";

    ----------------------------------------------------------------------------
    -- Front end (clocked): prefetch queue, D1 -> D2, flushes, WB.
    ----------------------------------------------------------------------------
    frontend_proc : process(clk, reset)
        variable q    : pq_t;
        variable cnt  : integer range 0 to PQ_SIZE;
        variable qe, fa : unsigned(31 downto 0);
        variable v    : unsigned(15 downto 0);
        variable nd2  : insn_t;
        variable nd2v : insn_t;
        variable poplen : integer range 0 to PQ_SIZE;
        variable off  : integer range 0 to 3;
        variable drop : boolean;
    begin
        if reset = '1' then
            pq_cnt <= 0; pq_eip <= (others => '0'); fetch_addr <= (others => '0');
            pf_wait <= '0'; pf_discard <= '0'; pf_fault <= '0';
            d2 <= NO_INSN; d2v <= NO_INSN; wb <= NO_INSN; wb_irq <= '0'; seq_ctr <= (others => '0');
            redir_pending <= '0'; refill <= '0'; bubble_why <= "100";
        elsif rising_edge(clk) then
            q := pq; cnt := pq_cnt; qe := pq_eip; fa := fetch_addr; v := seq_ctr;
            drop := pf_discard = '1';
            if next_state = S_INTA then v := v + 1; end if;     -- the interrupt's tag

            if flush_now then
                -- Wrong-path instructions in D1/D2 and the queue are discarded.
                cnt := 0;
                d2 <= NO_INSN;
                d2v <= NO_INSN;
                if redir_pending = '1' then qe := eip; fa := eip;
                else qe := br_target; fa := br_target; end if;
                pf_fault <= '0';
                if pf_wait = '1' then drop := true; end if;     -- stale prefetch in flight
                refill <= '1';
            elsif d2_take then
                if d1_ok = '1' then                             -- D1 -> D2
                    nd2 := d1; nd2.seq := v; v := v + 1;
                    nd2.pred_tk := d1_pred_tk; nd2.pred_tgt := d1_pred_tgt;
                    d2 <= nd2;
                    if pair_ok then                             -- co-issue I2 to the V pipe
                        nd2v := d1b; nd2v.seq := v; v := v + 1;
                        d2v <= nd2v;
                        poplen := d1_len + d1b_len;
                    else
                        d2v <= NO_INSN;
                        poplen := d1_len;
                    end if;
                    for j in 0 to PQ_SIZE - 1 loop
                        if j + poplen < PQ_SIZE then q(j) := q(j + poplen); end if;
                    end loop;
                    cnt := cnt - poplen;
                    qe := qe + poplen;
                    -- BTB speculative redirect: a branch predicted taken steers
                    -- fetch to the target now, discarding the sequential bytes
                    -- behind it. ctl_proc points pf_addr_now at the target this
                    -- same cycle, so the in-flight prefetch fetches the target
                    -- (kept); only a prefetch still WAITING on the old address
                    -- is dropped. The branch still resolves in EX.
                    if d1_pred_tk = '1' then
                        cnt := 0;
                        qe := d1_pred_tgt; fa := d1_pred_tgt;
                        if pf_wait = '1' then drop := true; end if;
                        refill <= '1';
                    end if;
                else
                    d2 <= NO_INSN;
                    d2v <= NO_INSN;
                end if;
            end if;
            if ex_accept then refill <= '0'; end if;

            -- PF: one aligned dword per bus cycle into the queue.
            if pf_req then
                if page_fault = '1' then                       -- page not present
                    pf_wait <= '0';
                    if not drop then
                        pf_fault <= '1';
                        pf_fault_addr <= pf_addr_now;
                    end if;
                    drop := false;
                elsif ready = '1' then
                    pf_wait <= '0';
                    if drop then
                        drop := false;
                    else
                        off := to_integer(pf_addr_now(1 downto 0));
                        for j in 0 to 3 loop
                            if j >= off and cnt < PQ_SIZE then
                                q(cnt) := data_in(8*j+7 downto 8*j);
                                cnt := cnt + 1;
                            end if;
                        end loop;
                        fa := (pf_addr_now(31 downto 2) & "00") + 4;
                    end if;
                else
                    pf_wait <= '1';                            -- e.g. an I-cache miss
                    pf_cur  <= pf_addr_now;
                end if;
            end if;
            if drop then pf_discard <= '1'; else pf_discard <= '0'; end if;

            pq <= q; pq_cnt <= cnt; pq_eip <= qe; fetch_addr <= fa; seq_ctr <= v;

            -- After a draining instruction completes: flush + refetch next cycle.
            -- An AP woken from park refetches from its new EIP the same way.
            if wake_pulse = '1' then redir_pending <= '1';
            elsif ex_done and ex_drain = '1' then redir_pending <= '1';
            else redir_pending <= '0'; end if;

            -- If EX will be empty next cycle, remember why.
            if next_state = S_IDLE then
                if flush_now or refill = '1' then bubble_why <= "011";        -- BRANCH / refill
                elsif d2.valid = '1' and agi then bubble_why <= "010";        -- AGI
                else bubble_why <= "100";                                     -- QUEUE EMPTY
                end if;
            end if;

            -- WB: the instruction that just completed EX retires.
            if ex_done then
                wb <= NO_INSN;
                wb.valid <= '1'; wb.eip <= ip_start; wb.seq <= ex_seq;
                wb_irq <= ex_irq;
            else
                wb <= NO_INSN;
                wb_irq <= '0';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- The memory bus: EX's access, or a prefetch.
    ----------------------------------------------------------------------------
    bus_mux : process(all)
    begin
        addr_out <= std_logic_vector(fetch_addr(31 downto 2)) & "00";
        data_out <= (others => '0');
        we <= '0';
        be <= "0000";
        if owner = BUS_EX then
            addr_out <= ex_addr; data_out <= ex_dout; we <= ex_we; be <= ex_be;
        elsif owner = BUS_PF then
            addr_out <= std_logic_vector(pf_addr_now(31 downto 2)) & "00";
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Pipeline view
    ----------------------------------------------------------------------------
    dbg_retire   <= wb.valid;
    -- Single-step stops once an instruction has retired (its results visible).
    dbg_boundary <= wb.valid;
    dbg_stall    <= stall_code;
    with stall_code select dbg_stall_name <=
        x"202020202020202020202020"           when "000",
        sname12("MICROCODE")                  when "001",
        sname12("AGI")                        when "010",
        sname12("BRANCH")                     when "011",
        sname12("QUEUE EMPTY")                when "100",
        sname12("MEM WAIT")                   when "101",
        sname12("BUS BUSY")                   when "110",
        sname12("HALT")                       when others;
    dbg_pf_addr  <= std_logic_vector(pf_addr_now);
    dbg_pq_cnt   <= std_logic_vector(to_unsigned(pq_cnt, 5));
    ex_occ <= '1' when state /= S_IDLE and state /= S_HALT else '0';
    dbg_stage_valid <= d1_ok & d2.valid & ex_occ & wb.valid;
    dbg_d1_eip   <= std_logic_vector(pq_eip);
    dbg_d2_eip   <= std_logic_vector(d2.eip);
    dbg_ex_eip   <= std_logic_vector(ip_start);
    dbg_wb_eip   <= std_logic_vector(wb.eip);
    dbg_d1_seq   <= std_logic_vector(seq_ctr);
    dbg_d2_seq   <= std_logic_vector(d2.seq);
    dbg_ex_seq   <= std_logic_vector(ex_seq);
    dbg_wb_seq   <= std_logic_vector(wb.seq);
    dbg_d1_txt   <= dis_ascii(dis_at(dis, pq_eip)) when d1_ok = '1' and d1.pfault = '0' else
                    dis_ascii(dis_str("(fetching bytes)"));
    dbg_d2_txt   <= dis_ascii(dis_str("<#PF on prefetch>")) when d2.valid = '1' and d2.pfault = '1' else
                    dis_ascii(dis_at(dis, d2.eip)) when d2.valid = '1' else
                    dis_ascii(dis_str("(bubble)"));
    dbg_ex_txt   <= dis_ascii(dis_str("(halted)")) when state = S_HALT else
                    dis_ascii(dis_str("(bubble)")) when state = S_IDLE else
                    dis_ascii(dis_str("<hardware interrupt>")) when ex_irq = '1' else
                    dis_ascii(dis_at(dis, ip_start));
    dbg_wb_txt   <= dis_ascii(dis_str("<hardware interrupt>")) when wb.valid = '1' and wb_irq = '1' else
                    dis_ascii(dis_at(dis, wb.eip)) when wb.valid = '1' else
                    dis_ascii(dis_str("(bubble)"));
    -- Superscalar V pipe: the second instruction co-issued with the EX instruction.
    -- Gate on ex_occ: v_valid is latched at ex_accept and would otherwise stay
    -- asserted through a stall tail after the U partner has left EX (phantom
    -- co-issue in the waveform). EX can only re-occupy via ex_accept, which
    -- refreshes v_valid, so ex_occ='1' always means the real partner is present.
    dbg_v_valid  <= v_valid and ex_occ;
    dbg_v_seq    <= std_logic_vector(v_seq);
    dbg_v_eip    <= std_logic_vector(v_eip);
    dbg_pairs    <= std_logic_vector(pairs_ctr(15 downto 0));
    dbg_pairs32     <= std_logic_vector(pairs_ctr);
    dbg_btb_correct <= std_logic_vector(btb_correct);
    dbg_btb_wrong   <= std_logic_vector(btb_wrong);
    -- Disassemble the V instruction only when the pipe is cleanly valid and its
    -- address is settled (a parked/just-woken core can present a metavalue here).
    dbg_v_txt    <= dis_ascii(dis_at(dis, v_eip)) when HAVE_DIS and v_valid = '1' else
                    dis_ascii(dis_str("(no pair)"));

    -- Flatten the BTB for the viewer: entry i = set i/BTB_WAYS, way i mod BTB_WAYS.
    btb_tap : process(all)
    begin
        for i in 0 to BTB_SETS*BTB_WAYS - 1 loop
            dbg_btb_tag(32*i + 31 downto 32*i) <= std_logic_vector(btb(i).tag);
            dbg_btb_tgt(32*i + 31 downto 32*i) <= std_logic_vector(btb(i).tgt);
            dbg_btb_meta(8*i)                  <= btb(i).valid;            -- bit0 = valid
            dbg_btb_meta(8*i + 2 downto 8*i + 1) <= std_logic_vector(btb(i).ctr);  -- 2-bit history
            dbg_btb_meta(8*i + 7 downto 8*i + 3) <= (others => '0');
        end loop;
    end process;

    dbg_pc        <= std_logic_vector(eip);
    dbg05_eax     <= std_logic_vector(reg(0));
    dbg07_ecx     <= std_logic_vector(reg(1));
    dbg_edx       <= std_logic_vector(reg(2));
    dbg06_ebx     <= std_logic_vector(reg(3));
    dbg08_esp     <= std_logic_vector(reg(4));
    dbg_ebp       <= std_logic_vector(reg(5));
    dbg_esi       <= std_logic_vector(reg(6));
    dbg_edi       <= std_logic_vector(reg(7));
    dbg_xmm0      <= xmm(0);
    dbg_xmm1      <= xmm(1);
    dbg_xmm2      <= xmm(2);
    dbg03_ir      <= ir0;
    dbg04_operand <= oprnd;
    dbg09_flags   <= if_f & cf & zf;
    dbg10_ivt     <= std_logic_vector(idtr_base);
    dbg_op_code   <= ir0(5 downto 0);
    dbg_eflags    <= eflags_v;

    with state select
        dbg02_state <=
            "0000" when S_IDLE,
            "0110" when S_EXECUTE | S_MULDIV_WAIT,
            "0111" when S_LOAD | S_XMM_LD | S_IN,
            "1000" when S_STORE | S_XMM_ST | S_OUT,
            "1001" when S_PUSH | S_PUSHA,
            "1010" when S_POP | S_POPA,
            "1011" when S_CALL_PUSH,
            "1100" when S_RET_POP,
            "1101" when S_INTA | S_INT_VEC | S_INT_PUSH,
            "1110" when S_IRET_POP,
            "0100" when S_XCHG_R | S_XCHG_W | S_CMPX_R | S_CMPX_W,
            "0101" when S_LIDT0 | S_LIDT1,
            "1111" when S_HALT;

    -- Readable per-state name (no aliasing) for the waveform viewer.
    with state select
        dbg_state_name <=
            sname("IDLE")          when S_IDLE,
            sname("EXECUTE")       when S_EXECUTE,
            sname("LOAD")          when S_LOAD,
            sname("STORE")         when S_STORE,
            sname("PUSH")          when S_PUSH,
            sname("POP")           when S_POP,
            sname("PUSHA")         when S_PUSHA,
            sname("POPA")          when S_POPA,
            sname("CALL_PUSH")     when S_CALL_PUSH,
            sname("RET_POP")       when S_RET_POP,
            sname("INTA")          when S_INTA,
            sname("INT_VEC")       when S_INT_VEC,
            sname("INT_PUSH")      when S_INT_PUSH,
            sname("IRET_POP")      when S_IRET_POP,
            sname("XCHG_R")        when S_XCHG_R,
            sname("XCHG_W")        when S_XCHG_W,
            sname("LIDT0")         when S_LIDT0,
            sname("LIDT1")         when S_LIDT1,
            sname("CMPX_R")        when S_CMPX_R,
            sname("CMPX_W")        when S_CMPX_W,
            sname("XMM_LD")        when S_XMM_LD,
            sname("XMM_ST")        when S_XMM_ST,
            sname("IN")            when S_IN,
            sname("OUT")           when S_OUT,
            sname("MULDIV")        when S_MULDIV_WAIT,
            sname("HALT")          when S_HALT;

end superscalar;
