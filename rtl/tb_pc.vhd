--------------------------------------------------------------------------------
-- tb_pc : the teaching PC -- the dual-Pentium (P54C) plus real PC/AT devices.
--
--   BSP ]                RAM (4 KB)  -- CACHED (coherent split-L1, MESI)
--   AP  ]--mem bus--> l1_mesi --mmio--> pc_chipset --+--> VGA text RAM (0xB8000)
--                                                    +--> open bus
--       --I/O bus-----> pc_chipset --+--> 8259 PIC master (0x20) + slave (0xA0)
--                                    +--> 8042 keyboard controller (0x60 / 0x64)
--                                    +--> ATA disk (0x1F0-0x1F7, 0x3F6)
--                                    +--> VGA CRTC cursor (0x3D4 / 0x3D5)
--                                    +--> POST code (0x80), debug console (0xE9)
--       <--INTR/INTA--> PIC master <--IR2-- PIC slave  (device IRQs go to the BSP)
--           IRQ1  = keyboard (master IR1)    IRQ14 = disk (slave IR6)
--
-- RAM is CACHED by the coherent split-L1 (so the CPU bus can wait on a miss);
-- video RAM and device registers are UNCACHEABLE memory-mapped I/O -- they come
-- out of the L1's mmio port and bypass the cache, exactly as on real hardware.
-- Core 0 is the bootstrap processor and runs the program; core 1 is an
-- application processor that boots parked and is started by the BSP via a SIPI
-- (local-APIC ICR at 0x1F0). It takes no device interrupts.
--
-- Two ways to run it (see `make pc`, `make pc-test`, `make pc-replay`):
--   LIVE = 1  an interactive session: scripts/pc_host.c draws the screen in
--             the terminal and turns typed keys into scan codes. Every scan
--             code injected is logged with its cycle number (build/pc_keys.log),
--             so the session can be replayed exactly (with waveforms). RAM, video RAM
--             and the CPU state are also published for the viewer windows
--             (scripts/pc_view.py), which can slow, pause or single-step the run.
--   LIVE = 0  batch: scan codes come from KEYS_FILE ("<cycle> <hex byte>" per
--             line). The run ends when the program executes CLI;HLT, when it
--             has sat idle in HLT for IDLE_CYCLES after the last key, or at
--             MAX_CYCLES. With RUN_TO > 0 it runs to exactly that cycle and
--             stops there (used to rebuild a live session's chronogram up to
--             the moment it was paused).
-- At the end: registers, the 80x25 screen as text, a RAM dump, and the disk
-- image (DISK_OUT).
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity tb_pc is
    generic (
        program_file : string  := "";
        disasm_file  : string  := "";      -- program disassembly (pipeline view)
        disk_file    : string  := "";
        disk_out     : string  := "";
        keys_file    : string  := "";      -- scripted / replayed key input
        LIVE         : integer := 0;
        RUN_TO       : integer := 0;       -- batch: stop at exactly this cycle
        MAX_CYCLES   : integer := 3000000;
        IDLE_CYCLES  : integer := 20000;
        POLL_CYCLES  : integer := 200;     -- live: poll the terminal this often
        -- Machine-configuration knobs (default = the standard Pentium machine;
        -- overridden only when run_sim.sh passes them). Applied to BOTH cores and
        -- the L1. See the README "Machine configuration" section.
        CFG_DUAL     : boolean := true;    -- U/V dual-issue (false = scalar)
        CFG_SERIAL   : boolean := false;   -- drain every instruction (no pipeline)
        CFG_BTB      : boolean := true;    -- branch prediction on
        CFG_CACHE    : boolean := true;    -- L1 on (false = no-cache, every access misses)
        CFG_SETS     : integer := 4;       -- L1 sets (power of two)
        CFG_WAYS     : integer := 2;       -- L1 associativity (power of two)
        CFG_LINE     : integer := 8        -- L1 words per line (line = 4*CFG_LINE bytes)
    );
end tb_pc;

architecture sim of tb_pc is

    ----------------------------------------------------------------------------
    -- Host terminal (scripts/pc_host.c, loaded from build/libpchost.so)
    ----------------------------------------------------------------------------
    impure function host_init(live_mode : integer) return integer is
    begin assert false severity failure; return 0; end function;
    attribute foreign of host_init : function is "VHPIDIRECT ./libpchost.so host_init";
    impure function host_poll_key(halted, cycle : integer) return integer is
    begin assert false severity failure; return 0; end function;
    attribute foreign of host_poll_key : function is "VHPIDIRECT ./libpchost.so host_poll_key";
    procedure host_vga_write(offset, value : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_vga_write : procedure is "VHPIDIRECT ./libpchost.so host_vga_write";
    procedure host_cursor(pos : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_cursor : procedure is "VHPIDIRECT ./libpchost.so host_cursor";
    procedure host_console(ch : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_console : procedure is "VHPIDIRECT ./libpchost.so host_console";
    procedure host_post(code : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_post : procedure is "VHPIDIRECT ./libpchost.so host_post";
    procedure host_mem_write(addr, value : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_mem_write : procedure is "VHPIDIRECT ./libpchost.so host_mem_write";
    impure function host_cpu(cycle, eip, eax, ecx, edx, ebx, esp, ebp, esi, edi,
                             eflags, halted, irqs, ivt, s0, s1, s2, bnd,
                             d1, d2, ex, wb, valid, stl, pq,
                             rd_addr, rd_read, cr3 : integer) return integer is
    begin assert false severity failure; return 0; end function;
    attribute foreign of host_cpu : function is "VHPIDIRECT ./libpchost.so host_cpu";
    procedure host_wave(cycle, eip, addr, data, eax, io_port, io_data, bits, irqs,
                        vector, isr, irr, s0, s1, s2,
                        d1, d2, ex, wb, q1, q2, qe, qw, valid, stl, pq, pfa,
                        v_eip, v_seq, v_valid : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_wave : procedure is "VHPIDIRECT ./libpchost.so host_wave";
    procedure host_sys(v_valid, pairs, ap_pc, ap_halted, ap_stage, ap_vvalid,
                       aps0, aps1, aps2, ichit, icmiss, dchit, dcmiss, inval, wb,
                       c0st, c1st, grant, trans, walks, faults, cr2 : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_sys : procedure is "VHPIDIRECT ./libpchost.so host_sys";
    procedure host_perf(instret, s0, s1, s2, s3, s4, s5, s6, s7,
                        btb_ok, btb_bad, pairs32 : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_perf : procedure is "VHPIDIRECT ./libpchost.so host_perf";
    procedure host_config(dual, serial, btb, cache, sets, ways, line : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_config : procedure is "VHPIDIRECT ./libpchost.so host_config";
    procedure host_wave_ap(cycle, eip, d1, d2, ex, wb, q1, q2, qe, qw,
                           valid, stl, pq, s0, s1, s2,
                           v_eip, v_seq, v_valid : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_wave_ap : procedure is "VHPIDIRECT ./libpchost.so host_wave_ap";
    impure function host_cache_wanted return integer is
    begin assert false severity failure; return 0; end function;
    attribute foreign of host_cache_wanted : function is "VHPIDIRECT ./libpchost.so host_cache_wanted";
    procedure host_cache(off, word : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_cache : procedure is "VHPIDIRECT ./libpchost.so host_cache";
    impure function host_btb_wanted return integer is
    begin assert false severity failure; return 0; end function;
    attribute foreign of host_btb_wanted : function is "VHPIDIRECT ./libpchost.so host_btb_wanted";
    procedure host_btb(off, word : integer) is
    begin assert false severity failure; end procedure;
    attribute foreign of host_btb : procedure is "VHPIDIRECT ./libpchost.so host_btb";
    procedure host_close is
    begin assert false severity failure; end procedure;
    attribute foreign of host_close : procedure is "VHPIDIRECT ./libpchost.so host_close";

    constant CLK_PERIOD : time := 100 ns;
    constant RAM_BITS   : integer := 12;

    signal dbg01_clk : std_logic := '0';
    signal reset     : std_logic := '1';

    -- CPU taps (same names as the other testbenches, so surfer_rows.py works)
    signal dbg02_state        : std_logic_vector(3 downto 0);
    signal dbg03_ir           : std_logic_vector(7 downto 0);
    signal dbg04_operand      : std_logic_vector(31 downto 0);
    signal dbg05_eax, dbg06_ebx, dbg07_ecx, dbg08_esp : std_logic_vector(31 downto 0);
    signal dbg_edx, dbg_esi, dbg_edi, dbg_ebp : std_logic_vector(31 downto 0);
    signal dbg09_flags        : std_logic_vector(2 downto 0);
    signal dbg_eflags         : std_logic_vector(31 downto 0);
    signal dbg10_ivt          : std_logic_vector(31 downto 0);
    signal dbg11_we           : std_logic;
    signal dbg13_xchg_active  : std_logic;
    signal dbg_state_name     : std_logic_vector(8*16-1 downto 0);
    signal dbg_pc             : std_logic_vector(31 downto 0);
    signal dbg_cr3            : std_logic_vector(31 downto 0);
    signal dbg_cr2            : std_logic_vector(31 downto 0);   -- latched #PF address (CR2)
    signal dbg_vector         : std_logic_vector(7 downto 0);
    signal ud_fault           : std_logic;
    -- pipeline view (CORE=pipe; on the multi-cycle core only EX is used)
    signal retire, boundary   : std_logic;
    signal stall              : std_logic_vector(2 downto 0);
    signal pq_cnt             : std_logic_vector(4 downto 0);
    signal pf_addr            : std_logic_vector(31 downto 0);
    signal stage_valid        : std_logic_vector(3 downto 0);
    signal d1_eip, d2_eip, ex_eip, wb_eip : std_logic_vector(31 downto 0);
    signal d1_seq, d2_seq, ex_seq, wb_seq : std_logic_vector(15 downto 0);
    type stall_cnt_t is array (0 to 7) of integer;
    signal stall_cnt          : stall_cnt_t := (others => 0);
    signal instret            : integer := 0;
    signal saw_pipe           : boolean := false;
    signal cpu_lock, cpu_req  : std_logic;
    signal halted             : std_logic;

    -- memory bus (BSP virtual/physical -- the L1 caches RAM, forwards MMIO)
    signal cpu_addr, cpu_dout, cpu_din : std_logic_vector(31 downto 0);
    signal cpu_be   : std_logic_vector(3 downto 0);
    signal cpu_ifetch, cpu_ready : std_logic;
    signal ram_dout, vram_dout : std_logic_vector(31 downto 0);
    signal cs_ram, cs_vram : std_logic;
    signal mem_sel  : std_logic_vector(63 downto 0);   -- ASCII: RAM / VRAM / OPENBUS

    -- Uncacheable MMIO passthrough (l1_mesi -> chipset -> VGA / open bus). RAM is
    -- internal to l1_mesi; only addresses >= 4 KB reach here, so cs_ram is never
    -- set on this path -- VRAM and open bus only.
    signal mmio_addr, mmio_wdata, mmio_rdata : std_logic_vector(31 downto 0);
    signal mmio_we, mmio_req, mmio_ifetch : std_logic;
    signal mmio_be : std_logic_vector(3 downto 0);

    -- AP (core 1): shares RAM through l1_mesi (MESI); boots parked (SIPI).
    signal a1_addr, a1_wr, a1_rd : std_logic_vector(31 downto 0);
    signal a1_we, a1_req, a1_ifetch, a1_lock, a1_ready, halt1 : std_logic;
    signal a1_be : std_logic_vector(3 downto 0);
    signal pc1   : std_logic_vector(31 downto 0);
    signal ap_wake     : std_logic := '0';
    signal ap_wake_eip : std_logic_vector(31 downto 0) := (others => '0');

    -- Per-core MMU (scaled x86 paging): CPU virtual bus -> MMU -> physical bus
    -- into l1_mesi. Transparent when CR0.PG=0 (every current PC program), so the
    -- paging/TLB is present and visible but idle unless a program enables it.
    signal pg_enable, tlb_flush, page_fault : std_logic;
    signal cr3_out, fault_addr : std_logic_vector(31 downto 0);
    signal p0_addr, p0_wr, p0_rd : std_logic_vector(31 downto 0);
    signal p0_we, p0_req, p0_ifetch, p0_ready : std_logic;
    signal p0_be : std_logic_vector(3 downto 0);
    signal p_trans, p_walks, p_flts : std_logic_vector(31 downto 0);
    signal ap_pg, ap_tlbf, ap_pf : std_logic;
    signal ap_cr3, ap_faddr : std_logic_vector(31 downto 0);
    signal p1_addr, p1_wr, p1_rd : std_logic_vector(31 downto 0);
    signal p1_we, p1_req, p1_ifetch, p1_ready : std_logic;
    signal p1_be : std_logic_vector(3 downto 0);

    -- Coherent-L1 statistics taps (BSP core 0) for the report and the viewers.
    signal ic_hits, ic_misses, dc_hits, dc_misses : std_logic_vector(31 downto 0);
    signal cache_inval, cache_wb : std_logic_vector(31 downto 0);
    signal c0_mstate, c1_mstate, cache_grant : std_logic_vector(1 downto 0);
    -- core-0 cache contents (flattened) for the live cache-view window
    signal dcache_dat, icache_dat : std_logic_vector(2047 downto 0);
    signal dcache_meta, icache_meta : std_logic_vector(63 downto 0);
    -- the cache<->RAM bus beat in flight (line fill / writeback) for the RAM view
    signal fill_bus_addr : std_logic_vector(31 downto 0);
    signal fill_bus_kind : std_logic_vector(1 downto 0);
    -- BTB contents (8 entries each) for the per-core BTB windows
    signal bsp_btb_tag, bsp_btb_tgt : std_logic_vector(255 downto 0);
    signal ap_btb_tag,  ap_btb_tgt  : std_logic_vector(255 downto 0);
    signal bsp_btb_meta, ap_btb_meta : std_logic_vector(63 downto 0);

    -- BSP superscalar taps for the live viewers.
    signal bsp_v_valid : std_logic;
    signal bsp_v_seq   : std_logic_vector(15 downto 0);
    signal bsp_v_eip   : std_logic_vector(31 downto 0);
    signal ap_v_seq    : std_logic_vector(15 downto 0);
    signal ap_v_eip    : std_logic_vector(31 downto 0);
    signal bsp_pairs   : std_logic_vector(15 downto 0);
    signal bsp_pairs32 : std_logic_vector(31 downto 0);
    signal bsp_btb_ok, bsp_btb_bad : std_logic_vector(31 downto 0);
    -- AP (core 1) pipeline taps, so the AP gets its own live pipeline chart.
    signal ap_d1_eip, ap_d2_eip, ap_ex_eip, ap_wb_eip : std_logic_vector(31 downto 0);
    signal ap_d1_seq, ap_d2_seq, ap_ex_seq, ap_wb_seq : std_logic_vector(15 downto 0);
    signal ap_stage_valid : std_logic_vector(3 downto 0);
    signal ap_stall       : std_logic_vector(2 downto 0);
    signal ap_pq_cnt      : std_logic_vector(4 downto 0);
    signal ap_state_name  : std_logic_vector(8*16-1 downto 0);
    signal ap_v_valid     : std_logic;

    -- BSP committed a cacheable RAM write this cycle (for the live RAM viewer).
    signal ram_wr_commit : std_logic;
    -- what the chipset sees: the core's own access, for the RAM/VRAM/device label.
    signal view_cs_ram, view_cs_vram : std_logic;

    -- I/O bus
    signal io_addr  : std_logic_vector(15 downto 0);
    signal io_dout, io_din : std_logic_vector(31 downto 0);
    signal io_re, io_we, io_active : std_logic;
    signal io_size  : std_logic_vector(1 downto 0);
    signal io_sel   : std_logic_vector(63 downto 0);   -- ASCII: PIC1 / KBD / ATA ...
    signal cs_pic1, cs_pic2, cs_kbd_data, cs_kbd_cmd : std_logic;
    signal cs_ata, cs_ata_ctl, cs_crtc_idx, cs_crtc_data, cs_post, cs_e9 : std_logic;
    signal pic1_dout, pic2_dout, kbd_dout, crtc_dout : std_logic_vector(7 downto 0);
    signal ata_dout : std_logic_vector(31 downto 0);

    -- interrupts
    signal intr, inta : std_logic;
    signal inta_vec, pic1_vec, pic2_vec : std_logic_vector(7 downto 0);
    signal pic1_sel, pic2_sel : integer range 0 to 7;
    signal pic1_ir, pic2_ir : std_logic_vector(7 downto 0);
    signal pic2_int, pic2_inta : std_logic;
    signal irq1, irq14 : std_logic;
    signal pic1_irr, pic1_isr, pic1_imr : std_logic_vector(7 downto 0);
    signal pic2_irr, pic2_isr, pic2_imr : std_logic_vector(7 downto 0);

    -- keyboard
    signal key_valid : std_logic := '0';
    signal key_code  : std_logic_vector(7 downto 0) := (others => '0');
    signal kbd_full, kbd_idle : std_logic;
    signal kbd_status, kbd_outbuf : std_logic_vector(7 downto 0);

    -- disk
    signal ata_status : std_logic_vector(7 downto 0);
    signal ata_lba    : std_logic_vector(27 downto 0);
    signal ata_word   : std_logic_vector(8 downto 0);
    signal ata_phase  : std_logic_vector(63 downto 0);
    signal disk_dump  : std_logic := '0';

    -- display
    signal cursor      : std_logic_vector(15 downto 0);
    signal screen_text : std_logic_vector(25*80*8 - 1 downto 0);
    signal scr_row00 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row01 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row02 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row03 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row04 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row05 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row06 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row07 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row08 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row09 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row10 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row11 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row12 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row13 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row14 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row15 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row16 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row17 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row18 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row19 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row20 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row21 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row22 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row23 : std_logic_vector(80*8 - 1 downto 0);
    signal scr_row24 : std_logic_vector(80*8 - 1 downto 0);
    signal post_code   : std_logic_vector(7 downto 0) := x"00";

    -- run control
    signal cycles     : integer := 0;
    signal irq_count  : integer := 0;
    signal stop_req   : boolean := false;
    signal stop_why   : integer := 0;     -- 1 cli;hlt  2 idle  3 limit  4 user quit
    signal sim_done   : boolean := false;
    signal dump_addr  : std_logic_vector(31 downto 0) := (others => '0');
    signal dump_data  : std_logic_vector(7 downto 0);

begin

    clk_proc : process
    begin
        while not sim_done loop
            dbg01_clk <= '0';
            wait for CLK_PERIOD / 2;
            dbg01_clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- CPU
    ----------------------------------------------------------------------------
    cpu_inst : entity work.x86_cpu
        generic map (DISASM_FILE => disasm_file,
                     DUAL_ISSUE => CFG_DUAL, SERIALIZE => CFG_SERIAL, BTB_ENABLE => CFG_BTB)
        port map (
            clk => dbg01_clk, reset => reset,
            data_in => cpu_din, ready => cpu_ready,
            addr_out => cpu_addr, data_out => cpu_dout,
            we => dbg11_we, be => cpu_be, mem_req => cpu_req, mem_ifetch => cpu_ifetch, lock => cpu_lock,
            io_addr => io_addr, io_dout => io_dout, io_din => io_din,
            io_re => io_re, io_we => io_we, io_size => io_size,
            intr => intr, inta => inta, inta_vec => inta_vec,
            halted => halted,
            pg_enable => pg_enable, cr3_out => cr3_out, tlb_flush => tlb_flush,
            page_fault => page_fault, fault_addr => fault_addr,
            dbg02_state => dbg02_state, dbg03_ir => dbg03_ir, dbg04_operand => dbg04_operand,
            dbg05_eax => dbg05_eax, dbg06_ebx => dbg06_ebx, dbg07_ecx => dbg07_ecx,
            dbg08_esp => dbg08_esp, dbg_edx => dbg_edx, dbg_ebp => dbg_ebp,
            dbg_esi => dbg_esi, dbg_edi => dbg_edi,
            dbg09_flags => dbg09_flags, dbg_eflags => dbg_eflags, dbg10_ivt => dbg10_ivt,
            dbg13_xchg_active => dbg13_xchg_active,
            dbg_pc => dbg_pc, dbg_cr3 => dbg_cr3, dbg_cr2 => dbg_cr2,
            dbg_ud => ud_fault, dbg_vector => dbg_vector,
            dbg_retire => retire, dbg_boundary => boundary, dbg_stall => stall,
            dbg_pq_cnt => pq_cnt, dbg_pf_addr => pf_addr, dbg_stage_valid => stage_valid,
            dbg_d1_eip => d1_eip, dbg_d2_eip => d2_eip, dbg_ex_eip => ex_eip, dbg_wb_eip => wb_eip,
            dbg_d1_seq => d1_seq, dbg_d2_seq => d2_seq, dbg_ex_seq => ex_seq, dbg_wb_seq => wb_seq,
            dbg_v_valid => bsp_v_valid, dbg_v_seq => bsp_v_seq, dbg_v_eip => bsp_v_eip,
            dbg_pairs => bsp_pairs,
            dbg_state_name => dbg_state_name,
            dbg_btb_tag => bsp_btb_tag, dbg_btb_tgt => bsp_btb_tgt, dbg_btb_meta => bsp_btb_meta,
            dbg_btb_correct => bsp_btb_ok, dbg_btb_wrong => bsp_btb_bad, dbg_pairs32 => bsp_pairs32
        );

    -- BSP MMU: translates the CPU's virtual bus to the physical bus that drives
    -- the coherent L1. Transparent (PA=VA) until the program sets CR0.PG.
    mmu0 : entity work.mmu
        port map (
            clk => dbg01_clk, reset => reset,
            pg_enable => pg_enable, cr3 => cr3_out, tlb_flush => tlb_flush,
            cpu_addr => cpu_addr, cpu_din => cpu_dout, cpu_dout => cpu_din,
            cpu_we => dbg11_we, cpu_be => cpu_be, cpu_req => cpu_req, cpu_ifetch => cpu_ifetch,
            cpu_ready => cpu_ready,
            mem_addr => p0_addr, mem_din => p0_rd, mem_dout => p0_wr,
            mem_we => p0_we, mem_be => p0_be, mem_req => p0_req, mem_ifetch => p0_ifetch,
            mem_ready => p0_ready,
            page_fault => page_fault, fault_addr => fault_addr,
            dbg_translations => p_trans, dbg_walks => p_walks, dbg_faults => p_flts);

    ----------------------------------------------------------------------------
    -- The PC bus command strobes and the 8259's interrupt-acknowledge input as
    -- the chipset drives them on the real hardware: ACTIVE LOW ('0' = asserted),
    -- named with Intel's `#` suffix. VHDL needs extended identifiers (\NAME#\)
    -- for that; the waveform tools show them as MEMR#, IOR#, ... These are for
    -- viewing -- the devices here use the active-high internal signals.
    ----------------------------------------------------------------------------
    isa_bus : block
        signal \MEMR#\, \MEMW#\, \IOR#\, \IOW#\, \INTA#\ : std_logic;
    begin
        \MEMR#\ <= not (cpu_req and not dbg11_we);   -- memory read cycle
        \MEMW#\ <= not (cpu_req and dbg11_we);       -- memory write cycle
        \IOR#\  <= not io_re;                         -- IN
        \IOW#\  <= not io_we;                         -- OUT
        \INTA#\ <= not inta;                          -- interrupt acknowledge
    end block;

    ----------------------------------------------------------------------------
    -- Address decoders
    ----------------------------------------------------------------------------
    io_active <= io_re or io_we;

    -- The chipset's MEMORY side decodes the uncacheable MMIO stream from the L1
    -- (VRAM / open bus); RAM is internal to l1_mesi and never appears here. Its
    -- I/O side is driven by the BSP's I/O bus (below).
    ram_dout <= (others => '0');          -- no external RAM array: l1_mesi holds it
    chipset : entity work.pc_chipset
        generic map (RAM_BITS => RAM_BITS)
        port map (
            mem_addr => mmio_addr, mem_req => mmio_req,
            ram_dout => ram_dout, vram_dout => vram_dout,
            cs_ram => cs_ram, cs_vram => cs_vram,
            mem_rdata => mmio_rdata, mem_name => mem_sel,
            io_addr => io_addr, io_active => io_active,
            pic1_dout => pic1_dout, pic2_dout => pic2_dout,
            kbd_dout => kbd_dout, crtc_dout => crtc_dout, ata_dout => ata_dout,
            cs_pic1 => cs_pic1, cs_pic2 => cs_pic2,
            cs_kbd_data => cs_kbd_data, cs_kbd_cmd => cs_kbd_cmd,
            cs_ata => cs_ata, cs_ata_ctl => cs_ata_ctl,
            cs_crtc_idx => cs_crtc_idx, cs_crtc_data => cs_crtc_data,
            cs_post => cs_post, cs_e9 => cs_e9,
            io_rdata => io_din, io_name => io_sel
        );

    ----------------------------------------------------------------------------
    -- Coherent split-L1 (MESI) memory shared by both cores. RAM (4 KB) is
    -- internal and CACHED; accesses to video RAM / open bus (>= 4 KB) are
    -- uncacheable and come out of the mmio port to the chipset + VGA below.
    ----------------------------------------------------------------------------
    mem : entity work.l1_mesi
        generic map (init_file => program_file, RAM_BITS => RAM_BITS,
                     N_SETS => CFG_SETS, N_WAYS => CFG_WAYS, LINE_WORDS => CFG_LINE,
                     CACHE_ON => CFG_CACHE)
        port map (
            clk => dbg01_clk, reset => reset,
            a0_addr => p0_addr, a0_din => p0_wr, a0_dout => p0_rd,
            a0_we => p0_we, a0_be => p0_be, a0_req => p0_req,
            a0_ifetch => p0_ifetch, a0_lock => cpu_lock, a0_ready => p0_ready,
            a1_addr => p1_addr, a1_din => p1_wr, a1_dout => p1_rd,
            a1_we => p1_we, a1_be => p1_be, a1_req => p1_req,
            a1_ifetch => p1_ifetch, a1_lock => a1_lock, a1_ready => p1_ready,
            mmio_addr => mmio_addr, mmio_wdata => mmio_wdata, mmio_rdata => mmio_rdata,
            mmio_we => mmio_we, mmio_be => mmio_be, mmio_req => mmio_req,
            mmio_ifetch => mmio_ifetch,
            snoop_addr => dump_addr, snoop_byte => dump_data,
            dbg_c0_dhits => dc_hits, dbg_c0_dmiss => dc_misses, dbg_c1_dhits => open, dbg_c1_dmiss => open,
            dbg_c0_ihits => ic_hits, dbg_c0_imiss => ic_misses, dbg_c1_ihits => open, dbg_c1_imiss => open,
            dbg_invalidations => cache_inval, dbg_writebacks => cache_wb, dbg_smc_inval => open,
            dbg_watch_line => "00", dbg_c0_state => c0_mstate, dbg_c1_state => c1_mstate, dbg_grant => cache_grant,
            dbg_dcache => dcache_dat, dbg_icache => icache_dat,
            dbg_dmeta => dcache_meta, dbg_imeta => icache_meta,
            dbg_fill_addr => fill_bus_addr, dbg_fill_kind => fill_bus_kind);

    -- Local APIC: the BSP starts the AP with INIT + STARTUP IPI (ICR at 0x1F0).
    apic0 : entity work.apic
        port map (clk => dbg01_clk, reset => reset,
                  bus_addr => cpu_addr, bus_wdata => cpu_dout,
                  bus_we => dbg11_we, bus_req => cpu_req, bus_ready => cpu_ready,
                  ap_wake => ap_wake, ap_wake_eip => ap_wake_eip, dbg_started => open);

    -- Application processor: boots parked, started by the BSP's SIPI. It has no
    -- device I/O and takes no device interrupts (those go to the BSP).
    ap : entity work.x86_cpu
        generic map (AP_PARK => true,
                     DUAL_ISSUE => CFG_DUAL, SERIALIZE => CFG_SERIAL, BTB_ENABLE => CFG_BTB)
        port map (
            clk => dbg01_clk, reset => reset, wake => ap_wake, wake_eip => ap_wake_eip,
            data_in => a1_rd, ready => a1_ready,
            addr_out => a1_addr, data_out => a1_wr,
            we => a1_we, be => a1_be, mem_req => a1_req, mem_ifetch => a1_ifetch, lock => a1_lock,
            pg_enable => ap_pg, cr3_out => ap_cr3, tlb_flush => ap_tlbf,
            page_fault => ap_pf, fault_addr => ap_faddr,
            halted => halt1, dbg_pc => pc1,
            dbg_stage_valid => ap_stage_valid, dbg_stall => ap_stall, dbg_pq_cnt => ap_pq_cnt,
            dbg_d1_eip => ap_d1_eip, dbg_d2_eip => ap_d2_eip,
            dbg_ex_eip => ap_ex_eip, dbg_wb_eip => ap_wb_eip,
            dbg_d1_seq => ap_d1_seq, dbg_d2_seq => ap_d2_seq,
            dbg_ex_seq => ap_ex_seq, dbg_wb_seq => ap_wb_seq,
            dbg_v_valid => ap_v_valid, dbg_v_seq => ap_v_seq, dbg_v_eip => ap_v_eip,
            dbg_state_name => ap_state_name,
            dbg_btb_tag => ap_btb_tag, dbg_btb_tgt => ap_btb_tgt, dbg_btb_meta => ap_btb_meta);

    -- AP MMU: same translation for core 1's bus into the coherent L1.
    mmu1 : entity work.mmu
        port map (
            clk => dbg01_clk, reset => reset,
            pg_enable => ap_pg, cr3 => ap_cr3, tlb_flush => ap_tlbf,
            cpu_addr => a1_addr, cpu_din => a1_wr, cpu_dout => a1_rd,
            cpu_we => a1_we, cpu_be => a1_be, cpu_req => a1_req, cpu_ifetch => a1_ifetch,
            cpu_ready => a1_ready,
            mem_addr => p1_addr, mem_din => p1_rd, mem_dout => p1_wr,
            mem_we => p1_we, mem_be => p1_be, mem_req => p1_req, mem_ifetch => p1_ifetch,
            mem_ready => p1_ready,
            page_fault => ap_pf, fault_addr => ap_faddr,
            dbg_translations => open, dbg_walks => open, dbg_faults => open);

    -- VGA text video RAM is UNCACHEABLE memory-mapped I/O, driven from the L1's
    -- mmio port (as real video memory is: writes go straight through).
    vga_inst : entity work.vga_text
        port map (
            clk => dbg01_clk, reset => reset,
            mem_cs => cs_vram, mem_we => mmio_we, mem_be => mmio_be,
            mem_addr => mmio_addr(11 downto 0), mem_din => mmio_wdata, mem_dout => vram_dout,
            cs_index => cs_crtc_idx, cs_data => cs_crtc_data,
            io_wr => io_we, io_din => io_dout(7 downto 0), io_dout => crtc_dout,
            cursor => cursor, text => screen_text
        );

    -- For the live RAM viewer: the BSP's own access decides RAM vs device, and a
    -- cacheable write is mirrored when it commits (ready).
    view_cs_ram  <= '1' when cpu_req = '1' and unsigned(cpu_addr(31 downto RAM_BITS)) = 0 else '0';
    view_cs_vram <= cs_vram;
    ram_wr_commit <= '1' when view_cs_ram = '1' and dbg11_we = '1' and cpu_ready = '1' else '0';

    scr_row00 <= screen_text(15999 downto 15360);
    scr_row01 <= screen_text(15359 downto 14720);
    scr_row02 <= screen_text(14719 downto 14080);
    scr_row03 <= screen_text(14079 downto 13440);
    scr_row04 <= screen_text(13439 downto 12800);
    scr_row05 <= screen_text(12799 downto 12160);
    scr_row06 <= screen_text(12159 downto 11520);
    scr_row07 <= screen_text(11519 downto 10880);
    scr_row08 <= screen_text(10879 downto 10240);
    scr_row09 <= screen_text(10239 downto 9600);
    scr_row10 <= screen_text(9599 downto 8960);
    scr_row11 <= screen_text(8959 downto 8320);
    scr_row12 <= screen_text(8319 downto 7680);
    scr_row13 <= screen_text(7679 downto 7040);
    scr_row14 <= screen_text(7039 downto 6400);
    scr_row15 <= screen_text(6399 downto 5760);
    scr_row16 <= screen_text(5759 downto 5120);
    scr_row17 <= screen_text(5119 downto 4480);
    scr_row18 <= screen_text(4479 downto 3840);
    scr_row19 <= screen_text(3839 downto 3200);
    scr_row20 <= screen_text(3199 downto 2560);
    scr_row21 <= screen_text(2559 downto 1920);
    scr_row22 <= screen_text(1919 downto 1280);
    scr_row23 <= screen_text(1279 downto 640);
    scr_row24 <= screen_text(639 downto 0);

    ----------------------------------------------------------------------------
    -- Interrupt controllers: master (IR1 = keyboard, IR2 = cascade from the
    -- slave), slave (IR6 = IRQ14 disk). On an INTA for IR2 the slave supplies
    -- the vector -- the 8259 cascade.
    ----------------------------------------------------------------------------
    pic1_ir   <= "00000" & pic2_int & irq1 & '0';
    pic2_ir   <= '0' & irq14 & "000000";
    pic2_inta <= inta when pic1_sel = 2 else '0';
    inta_vec  <= pic2_vec when pic1_sel = 2 else pic1_vec;

    pic1_inst : entity work.pic_8259
        generic map (RESET_BASE => x"08")
        port map (
            clk => dbg01_clk, reset => reset,
            cs => cs_pic1, a0 => io_addr(0), rd => io_re, wr => io_we,
            din => io_dout(7 downto 0), dout => pic1_dout,
            ir => pic1_ir, int_out => intr, inta => inta,
            vector => pic1_vec, sel_irq => pic1_sel,
            dbg_irr => pic1_irr, dbg_isr => pic1_isr, dbg_imr => pic1_imr
        );

    pic2_inst : entity work.pic_8259
        generic map (RESET_BASE => x"70")
        port map (
            clk => dbg01_clk, reset => reset,
            cs => cs_pic2, a0 => io_addr(0), rd => io_re, wr => io_we,
            din => io_dout(7 downto 0), dout => pic2_dout,
            ir => pic2_ir, int_out => pic2_int, inta => pic2_inta,
            vector => pic2_vec, sel_irq => pic2_sel,
            dbg_irr => pic2_irr, dbg_isr => pic2_isr, dbg_imr => pic2_imr
        );

    ----------------------------------------------------------------------------
    -- Keyboard controller and disk
    ----------------------------------------------------------------------------
    kbd_inst : entity work.kbd_8042
        port map (
            clk => dbg01_clk, reset => reset,
            cs_data => cs_kbd_data, cs_cmd => cs_kbd_cmd, rd => io_re, wr => io_we,
            din => io_dout(7 downto 0), dout => kbd_dout, irq1 => irq1,
            key_valid => key_valid, key_code => key_code,
            fifo_full => kbd_full, idle => kbd_idle,
            dbg_status => kbd_status, dbg_outbuf => kbd_outbuf
        );

    ata_inst : entity work.ata_disk
        generic map (DISK_FILE => disk_file, DISK_OUT => disk_out)
        port map (
            clk => dbg01_clk, reset => reset,
            cs_cmd => cs_ata, cs_ctl => cs_ata_ctl, reg => io_addr(2 downto 0),
            rd => io_re, wr => io_we, size => io_size,
            din => io_dout, dout => ata_dout, intrq => irq14, dump => disk_dump,
            dbg_status => ata_status, dbg_lba => ata_lba,
            dbg_word => ata_word, dbg_phase => ata_phase
        );

    ----------------------------------------------------------------------------
    -- Host side: keys in, screen out, run control. Runs on every clock.
    ----------------------------------------------------------------------------
    host_proc : process(dbg01_clk)
        file     kf          : text;
        variable st          : file_open_status;
        variable l           : line;
        variable started     : boolean := false;
        variable have_kf     : boolean := false;
        variable keys_done   : boolean := true;
        variable next_cyc    : integer := 0;
        variable next_code   : std_logic_vector(7 downto 0);
        variable good        : boolean;
        variable k           : integer;
        variable cyc         : integer := 0;
        variable idle_cnt    : integer := 0;
        variable last_cursor : std_logic_vector(15 downto 0) := (others => '1');
        variable off         : integer;
        variable countdown   : integer := 1;      -- cycles until the next host_cpu call
        variable halted_i    : integer;
        variable wave_on     : boolean := false;  -- chronogram window open: sample every cycle
        variable wbits, wirq : integer;
        variable bus_data    : std_logic_vector(31 downto 0);
        variable io_byte     : integer;

        -- a vector as the integer with the same 32-bit pattern (for C)
        function bits(v : std_logic_vector) return integer is
        begin
            return to_integer(signed(v));
        end function;
        function bit1(b : std_logic) return integer is
        begin
            if b = '1' then return 1; else return 0; end if;
        end function;
        -- metavalue-safe (cache lines are 'U' until filled)
        function bits_x(v : std_logic_vector) return integer is
        begin
            if is_x(v) then return 0; else return to_integer(signed(v)); end if;
        end function;
        procedure read_next_key is
        begin
            keys_done := true;
            while have_kf and not endfile(kf) loop
                readline(kf, l);
                read(l, next_cyc, good);
                if good then
                    hread(l, next_code, good);
                    if good then keys_done := false; exit; end if;
                end if;
            end loop;
        end procedure;
    begin
        if rising_edge(dbg01_clk) then
            key_valid <= '0';
            if not started then
                started := true;
                if keys_file'length > 0 then
                    file_open(st, kf, keys_file, read_mode);
                    have_kf := st = open_ok;
                    if not have_kf then
                        report "tb_pc: cannot open keys file " & keys_file severity warning;
                    end if;
                    read_next_key;
                end if;
            end if;

            if reset = '0' and not stop_req then
                cyc := cyc + 1;
                cycles <= cyc;
                if inta = '1' then irq_count <= irq_count + 1; end if;
                if retire = '1' then instret <= instret + 1; end if;
                stall_cnt(to_integer(unsigned(stall))) <= stall_cnt(to_integer(unsigned(stall))) + 1;
                if stage_valid(2) = '1' then saw_pipe <= true; end if;

                -- ---- CPU state out, keys in ----
                if LIVE = 1 then
                    countdown := countdown - 1;
                end if;
                if LIVE = 1 and countdown <= 0 then
                    if halted = '1' then halted_i := 1; else halted_i := 0; end if;
                    -- Publish the viewer state and the cache / BTB contents BEFORE host_cpu:
                    -- host_cpu busy-waits here while the machine is paused, so anything done
                    -- after it would freeze -- a window opened mid-pause would read stale data
                    -- until the next step. host_*_wanted() also report true while paused so a
                    -- just-opened cache / BTB window still gets the current (frozen) contents.
                    host_sys(bit1(bsp_v_valid), to_integer(unsigned(bsp_pairs)),
                        bits(pc1), bit1(halt1), to_integer(unsigned(ap_stage_valid)), bit1(ap_v_valid),
                        bits(ap_state_name(127 downto 96)), bits(ap_state_name(95 downto 64)),
                        bits(ap_state_name(63 downto 32)),
                        bits(ic_hits), bits(ic_misses), bits(dc_hits), bits(dc_misses),
                        bits(cache_inval), bits(cache_wb),
                        to_integer(unsigned(c0_mstate)), to_integer(unsigned(c1_mstate)),
                        to_integer(unsigned(cache_grant)),
                        bits(p_trans), bits(p_walks), bits(p_flts), bits(dbg_cr2));
                    -- CPI-report counters: retired count, the 8 stall-cause
                    -- cycle buckets, BTB correct/wrong, and the 32-bit pair count.
                    host_perf(instret,
                        stall_cnt(0), stall_cnt(1), stall_cnt(2), stall_cnt(3),
                        stall_cnt(4), stall_cnt(5), stall_cnt(6), stall_cnt(7),
                        bits(bsp_btb_ok), bits(bsp_btb_bad), bits(bsp_pairs32));
                    host_config(boolean'pos(CFG_DUAL), boolean'pos(CFG_SERIAL),
                        boolean'pos(CFG_BTB), boolean'pos(CFG_CACHE),
                        CFG_SETS, CFG_WAYS, CFG_LINE);
                    if host_cache_wanted = 1 then
                        for i in 0 to 63 loop
                            host_cache(i*4,       bits_x(dcache_dat(32*i+31 downto 32*i)));
                            host_cache(256 + i*4, bits_x(icache_dat(32*i+31 downto 32*i)));
                        end loop;
                        host_cache(512, bits_x(dcache_meta(31 downto 0)));
                        host_cache(516, bits_x(dcache_meta(63 downto 32)));
                        host_cache(520, bits_x(icache_meta(31 downto 0)));
                        host_cache(524, bits_x(icache_meta(63 downto 32)));
                    end if;
                    if host_btb_wanted = 1 then
                        for i in 0 to 7 loop
                            host_btb(i*4,       bits_x(bsp_btb_tag(32*i+31 downto 32*i)));
                            host_btb(32 + i*4,  bits_x(bsp_btb_tgt(32*i+31 downto 32*i)));
                            host_btb(72 + i*4,      bits_x(ap_btb_tag(32*i+31 downto 32*i)));
                            host_btb(72 + 32 + i*4, bits_x(ap_btb_tgt(32*i+31 downto 32*i)));
                        end loop;
                        host_btb(64,      bits_x(bsp_btb_meta(31 downto 0)));
                        host_btb(68,      bits_x(bsp_btb_meta(63 downto 32)));
                        host_btb(72 + 64, bits_x(ap_btb_meta(31 downto 0)));
                        host_btb(72 + 68, bits_x(ap_btb_meta(63 downto 32)));
                    end if;
                    countdown := host_cpu(cyc, bits(dbg_pc), bits(dbg05_eax), bits(dbg07_ecx),
                        bits(dbg_edx), bits(dbg06_ebx), bits(dbg08_esp), bits(dbg_ebp),
                        bits(dbg_esi), bits(dbg_edi), bits(dbg_eflags), halted_i, irq_count,
                        bits(dbg10_ivt), bits(dbg_state_name(127 downto 96)),
                        bits(dbg_state_name(95 downto 64)), bits(dbg_state_name(63 downto 32)),
                        bit1(boundary), bits(d1_eip), bits(d2_eip), bits(ex_eip), bits(wb_eip),
                        to_integer(unsigned(stage_valid)), to_integer(unsigned(stall)),
                        to_integer(unsigned(pq_cnt)),
                        -- the RAM bus beat in flight (addr + kind 0 idle/1 data/2 ifetch/3 wb)
                        bits(fill_bus_addr), to_integer(unsigned(fill_bus_kind)),
                        bits(dbg_cr3));
                    wave_on := countdown >= 1000000;
                    countdown := countdown mod 1000000;
                    if countdown > POLL_CYCLES then countdown := POLL_CYCLES; end if;
                    if kbd_full = '0' then
                        k := host_poll_key(halted_i, cyc);
                        if k = -2 then
                            stop_why <= 4; stop_req <= true;
                        elsif k >= 0 then
                            key_valid <= '1';                 -- (pc_host.c logs it)
                            key_code  <= std_logic_vector(to_unsigned(k, 8));
                        end if;
                    end if;
                elsif not keys_done and cyc >= next_cyc and kbd_full = '0' then
                    key_valid <= '1';
                    key_code  <= next_code;
                    read_next_key;
                end if;

                -- ---- one chronogram sample per clock (live, window open) ----
                if LIVE = 1 and wave_on then
                    wbits := 0;
                    if cpu_req   = '1' then wbits := wbits + 1;  end if;
                    if dbg11_we  = '1' then wbits := wbits + 2;  end if;
                    if io_re     = '1' then wbits := wbits + 4;  end if;
                    if io_we     = '1' then wbits := wbits + 8;  end if;
                    if intr      = '1' then wbits := wbits + 16; end if;
                    if inta      = '1' then wbits := wbits + 32; end if;
                    if halted    = '1' then wbits := wbits + 64; end if;
                    wirq := 0;
                    if irq1  = '1' then wirq := wirq + 1; end if;
                    if irq14 = '1' then wirq := wirq + 2; end if;
                    if kbd_status(0) = '1' then wirq := wirq + 4; end if;
                    if dbg11_we = '1' then bus_data := cpu_dout; else bus_data := cpu_din; end if;
                    if io_we = '1' then io_byte := to_integer(unsigned(io_dout(7 downto 0)));
                    else                io_byte := to_integer(unsigned(io_din(7 downto 0))); end if;
                    host_wave(cyc, bits(dbg_pc), bits(cpu_addr), bits(bus_data), bits(dbg05_eax),
                        to_integer(unsigned(io_addr)),
                        io_byte,
                        wbits, wirq, to_integer(unsigned(dbg_vector)),
                        to_integer(unsigned(pic1_isr)), to_integer(unsigned(pic1_irr)),
                        bits(dbg_state_name(127 downto 96)), bits(dbg_state_name(95 downto 64)),
                        bits(dbg_state_name(63 downto 32)),
                        bits(d1_eip), bits(d2_eip), bits(ex_eip), bits(wb_eip),
                        to_integer(unsigned(d1_seq)), to_integer(unsigned(d2_seq)),
                        to_integer(unsigned(ex_seq)), to_integer(unsigned(wb_seq)),
                        to_integer(unsigned(stage_valid)), to_integer(unsigned(stall)),
                        to_integer(unsigned(pq_cnt)), bits(pf_addr),
                        bits(bsp_v_eip), to_integer(unsigned(bsp_v_seq)), bit1(bsp_v_valid));
                    -- the AP's own pipeline chart (its own sample ring)
                    host_wave_ap(cyc, bits(pc1),
                        bits(ap_d1_eip), bits(ap_d2_eip), bits(ap_ex_eip), bits(ap_wb_eip),
                        to_integer(unsigned(ap_d1_seq)), to_integer(unsigned(ap_d2_seq)),
                        to_integer(unsigned(ap_ex_seq)), to_integer(unsigned(ap_wb_seq)),
                        to_integer(unsigned(ap_stage_valid)), to_integer(unsigned(ap_stall)),
                        to_integer(unsigned(ap_pq_cnt)),
                        bits(ap_state_name(127 downto 96)), bits(ap_state_name(95 downto 64)),
                        bits(ap_state_name(63 downto 32)),
                        bits(ap_v_eip), to_integer(unsigned(ap_v_seq)), bit1(ap_v_valid));
                end if;

                -- ---- RAM, screen and console out (live) ----
                if LIVE = 1 then
                    -- RAM is write-back cached, so mirror the BSP's cacheable
                    -- write when it COMMITS (the architectural memory value).
                    if ram_wr_commit = '1' then
                        off := to_integer(unsigned(cpu_addr(RAM_BITS - 1 downto 2))) * 4;
                        for i in 0 to 3 loop
                            if cpu_be(i) = '1' then
                                host_mem_write(off + i, to_integer(unsigned(cpu_dout(8*i+7 downto 8*i))));
                            end if;
                        end loop;
                    end if;
                    -- Video RAM is uncacheable: writes appear on the mmio port.
                    if cs_vram = '1' and mmio_we = '1' then
                        off := to_integer(unsigned(mmio_addr(11 downto 2))) * 4;
                        for i in 0 to 3 loop
                            if mmio_be(i) = '1' then
                                host_vga_write(off + i, to_integer(unsigned(mmio_wdata(8*i+7 downto 8*i))));
                            end if;
                        end loop;
                    end if;
                    if cursor /= last_cursor then
                        last_cursor := cursor;
                        host_cursor(to_integer(unsigned(cursor)));
                    end if;
                    if io_we = '1' and cs_e9 = '1' then
                        host_console(to_integer(unsigned(io_dout(7 downto 0))));
                    end if;
                    if io_we = '1' and cs_post = '1' then
                        host_post(to_integer(unsigned(io_dout(7 downto 0))));
                    end if;
                end if;
                if io_we = '1' and cs_post = '1' then
                    post_code <= io_dout(7 downto 0);
                end if;

                -- ---- run control (batch) ----
                if LIVE = 0 and RUN_TO > 0 then
                    if cyc >= RUN_TO then
                        stop_why <= 3; stop_req <= true;          -- the requested cycle
                    end if;
                elsif LIVE = 0 then
                    if halted = '1' and dbg_eflags(9) = '0' then
                        stop_why <= 1; stop_req <= true;          -- cli ; hlt
                    elsif halted = '1' and keys_done and kbd_idle = '1' then
                        idle_cnt := idle_cnt + 1;
                        if idle_cnt >= IDLE_CYCLES then
                            stop_why <= 2; stop_req <= true;      -- idle, no more input
                        end if;
                    else
                        idle_cnt := 0;
                    end if;
                    if cyc >= MAX_CYCLES then
                        stop_why <= 3; stop_req <= true;
                    end if;
                end if;
            end if;

        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Reset, wait for the end, then report.
    ----------------------------------------------------------------------------
    main_proc : process
        variable l   : line;
        variable r   : integer;
        constant HEX : string := "0123456789ABCDEF";

        procedure write_hex2(b : std_logic_vector(7 downto 0)) is
            variable n : integer;
        begin
            n := to_integer(unsigned(b));
            write(l, HEX(n / 16 + 1));
            write(l, HEX(n mod 16 + 1));
        end procedure;
    begin
        r := host_init(LIVE);
        reset <= '1';
        if LIVE = 1 then                        -- initial RAM image for the viewers
            for i in 0 to 2 ** RAM_BITS - 1 loop
                dump_addr <= std_logic_vector(to_unsigned(i, 32));
                wait for 1 ns;
                host_mem_write(i, to_integer(unsigned(dump_data)));
            end loop;
        end if;
        wait for CLK_PERIOD * 2;
        reset <= '0';

        wait until stop_req;
        -- A bounded (RUN_TO) run is a waveform snapshot: freeze the clock at the
        -- requested cycle right now, so the VCD stops exactly there. The text
        -- report + screen/memory dump below step `dump_addr` with `wait for 1 ns`
        -- for thousands of ns, during which the clock would otherwise keep
        -- ticking and record the rest of the program past the paused cycle.
        if RUN_TO > 0 then
            sim_done <= true;
            wait;
        end if;
        wait for CLK_PERIOD;
        if LIVE = 1 then host_close; end if;

        disk_dump <= '1';                       -- ATA model writes DISK_OUT
        wait for CLK_PERIOD;

        report "=== Simulation finished ===";
        case stop_why is
            when 1 => report "Stopped: CPU executed CLI ; HLT";
            when 2 => report "Stopped: idle in HLT after the last key";
            when 3 =>
                if RUN_TO > 0 then report "Stopped: reached cycle " & integer'image(RUN_TO);
                else report "Stopped: cycle limit reached" severity warning; end if;
            when others => report "Stopped: user quit (Ctrl-])";
        end case;
        report "Final EAX   = 0x" & to_hstring(dbg05_eax);
        report "Final EBX   = 0x" & to_hstring(dbg06_ebx);
        report "Final ECX   = 0x" & to_hstring(dbg07_ecx);
        report "Final EDX   = 0x" & to_hstring(dbg_edx);
        report "Final ESI   = 0x" & to_hstring(dbg_esi);
        report "Final EDI   = 0x" & to_hstring(dbg_edi);
        report "Final ESP   = 0x" & to_hstring(dbg08_esp);
        report "Final PC    = 0x" & to_hstring(dbg_pc);
        report "Zero flag   = " & std_logic'image(dbg09_flags(0));
        report "Carry flag  = " & std_logic'image(dbg09_flags(1));
        report "Int flag    = " & std_logic'image(dbg09_flags(2));
        report "IVT base    = 0x" & to_hstring(dbg10_ivt);
        report "Halted      = " & std_logic'image(halted);
        report "Cycles      = " & integer'image(cycles);
        report "Hardware interrupts acknowledged = " & integer'image(irq_count);
        report "Instructions retired = " & integer'image(instret);
        report "Core: superscalar Pentium (PF D1 D2 EX WB, U/V dual-issue). Stall cycles: microcode=" &
               integer'image(stall_cnt(1)) & " AGI=" & integer'image(stall_cnt(2)) &
               " branch=" & integer'image(stall_cnt(3)) & " queue-empty=" &
               integer'image(stall_cnt(4)) & " mem-wait=" & integer'image(stall_cnt(5)) &
               " bus-busy=" & integer'image(stall_cnt(6)) & " halted=" & integer'image(stall_cnt(7));
        report "L1 cache (BSP): I-cache hits/misses = " & integer'image(to_integer(unsigned(ic_hits))) &
               " / " & integer'image(to_integer(unsigned(ic_misses))) &
               "   D-cache hits/misses = " & integer'image(to_integer(unsigned(dc_hits))) &
               " / " & integer'image(to_integer(unsigned(dc_misses))) &
               "   write-backs = " & integer'image(to_integer(unsigned(cache_wb)));
        report "Superscalar: U/V pairs issued = " & integer'image(to_integer(unsigned(bsp_pairs32))) &
               "   BTB predictions: correct = " & integer'image(to_integer(unsigned(bsp_btb_ok))) &
               " / mispredicted = " & integer'image(to_integer(unsigned(bsp_btb_bad)));
        report "Paging (BSP): TLB translations = " & integer'image(to_integer(unsigned(p_trans))) &
               "   page-table walks = " & integer'image(to_integer(unsigned(p_walks))) &
               "   page faults = " & integer'image(to_integer(unsigned(p_flts)));
        report "PIC1 IMR=0x" & to_hstring(pic1_imr) & " ISR=0x" & to_hstring(pic1_isr) &
               "  PIC2 IMR=0x" & to_hstring(pic2_imr) & " ISR=0x" & to_hstring(pic2_isr);
        report "POST code   = 0x" & to_hstring(post_code) &
               "   cursor = " & integer'image(to_integer(unsigned(cursor)));

        write(l, string'("")); writeline(output, l);
        write(l, string'("=== Screen (80x25) ===")); writeline(output, l);
        for row in 0 to 24 loop
            write(l, string'("screen["));
            if row < 10 then write(l, string'("0")); end if;
            write(l, row);
            write(l, string'("] |"));
            for col in 0 to 79 loop
                write(l, character'val(to_integer(unsigned(
                    screen_text((25*80 - 1 - (row*80 + col)) * 8 + 7 downto
                                (25*80 - 1 - (row*80 + col)) * 8)))));
            end loop;
            write(l, string'("|"));
            writeline(output, l);
        end loop;

        if LIVE = 0 then
            write(l, string'("")); writeline(output, l);
            write(l, string'("=== Memory dump (0x000..0xFFF) ===")); writeline(output, l);
            for row in 0 to 4096 / 32 - 1 loop
                write(l, string'("0x"));
                write(l, HEX((row * 32 / 256) mod 16 + 1));
                write(l, HEX((row * 32 / 16) mod 16 + 1));
                write(l, HEX((row * 32) mod 16 + 1));
                write(l, string'(" "));
                for col in 0 to 31 loop
                    dump_addr <= std_logic_vector(to_unsigned(row * 32 + col, 32));
                    wait for 1 ns;
                    if col = 16 then write(l, string'(" ")); end if;
                    write(l, string'(" "));
                    write_hex2(dump_data);
                end loop;
                writeline(output, l);
            end loop;
        end if;

        sim_done <= true;
        wait;
    end process;

end sim;
