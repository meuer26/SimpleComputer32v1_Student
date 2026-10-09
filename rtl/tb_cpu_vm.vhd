--------------------------------------------------------------------------------
-- Testbench: the dual-Pentium (P54C) machine WITH PAGING.
--
-- Each core has its own MMU (scaled x86 paging: single-level page table + TLB);
-- the translated PHYSICAL accesses go to the shared coherent split-L1 (MESI)
-- memory. So the address path per core is CPU -> MMU -> l1_mesi, and the L1 is
-- physically tagged (PTE walks go through it too, so page-table edits stay
-- coherent). Core 0 (BSP) runs the program; core 1 (AP) boots parked.
--
-- With paging off (CR0.PG=0) the MMU is transparent, so ordinary programs run
-- unchanged; the memory dump below shows PHYSICAL memory via the coherent snoop.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity tb_cpu_vm is
    generic (
        program_file : string := "";
        disasm_file  : string := ""
    );
end tb_cpu_vm;

architecture sim of tb_cpu_vm is

    signal dbg01_clk : std_logic := '0';
    signal reset     : std_logic := '1';

    -- BSP (core 0) debug taps
    signal dbg02_state   : std_logic_vector(3 downto 0);
    signal dbg03_ir      : std_logic_vector(7 downto 0);
    signal dbg05_eax, dbg06_ebx, dbg07_ecx, dbg_edx, dbg08_esp : std_logic_vector(31 downto 0);
    signal dbg09_flags   : std_logic_vector(2 downto 0);
    signal dbg10_ivt     : std_logic_vector(31 downto 0);
    signal dbg11_we      : std_logic;
    signal cpu_lock      : std_logic;
    signal cpu_req, cpu_ifetch, cpu_ready : std_logic;
    signal dbg_pc, cr2, cr3 : std_logic_vector(31 downto 0);
    signal ud_fault : std_logic;

    -- BSP virtual bus (CPU <-> MMU0)
    signal cpu_addr, cpu_dout, cpu_din : std_logic_vector(31 downto 0);
    signal cpu_be : std_logic_vector(3 downto 0);
    signal halted : std_logic;

    -- BSP paging control / fault
    signal pg_enable, tlb_flush, page_fault : std_logic;
    signal cr3_out, fault_addr : std_logic_vector(31 downto 0);

    -- BSP physical bus (MMU0 <-> l1_mesi.a0)
    signal p0_addr, p0_wr, p0_rd : std_logic_vector(31 downto 0);
    signal p0_we, p0_req, p0_ifetch, p0_ready : std_logic;
    signal p0_be : std_logic_vector(3 downto 0);

    -- paging stats (BSP)
    signal p_trans, p_walks, p_flts : std_logic_vector(31 downto 0);

    -- AP (core 1): bus -> MMU1 -> l1_mesi.a1 (parked unless SIPI'd)
    signal a1_addr, a1_wr, a1_rd : std_logic_vector(31 downto 0);
    signal a1_we, a1_req, a1_ifetch, a1_lock, a1_ready, halt1 : std_logic;
    signal a1_be : std_logic_vector(3 downto 0);
    signal ap_pg, ap_tlbf, ap_pf : std_logic;
    signal ap_cr3, ap_faddr : std_logic_vector(31 downto 0);
    signal p1_addr, p1_wr, p1_rd : std_logic_vector(31 downto 0);
    signal p1_we, p1_req, p1_ifetch, p1_ready : std_logic;
    signal p1_be : std_logic_vector(3 downto 0);
    signal ap_wake     : std_logic := '0';
    signal ap_wake_eip : std_logic_vector(31 downto 0) := (others => '0');

    -- I/O (BSP)
    signal io_addr  : std_logic_vector(15 downto 0);
    signal io_dout, io_din : std_logic_vector(31 downto 0);
    signal io_re, io_we : std_logic;

    -- L1 stats (BSP)
    signal ic_hits, ic_misses, dc_hits, dc_misses, cache_wb : std_logic_vector(31 downto 0);

    signal dump_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal dump_data : std_logic_vector(7 downto 0);

    signal sim_done : boolean := false;
    constant CLK_PERIOD : time    := 100 ns;
    constant SIM_CYCLES : integer := 200000;

begin

    clk_proc : process
    begin
        while not sim_done loop
            dbg01_clk <= '0'; wait for CLK_PERIOD / 2;
            dbg01_clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    bsp : entity work.x86_cpu
        generic map (DISASM_FILE => disasm_file)
        port map (
            clk => dbg01_clk, reset => reset,
            data_in => cpu_din, ready => cpu_ready,
            addr_out => cpu_addr, data_out => cpu_dout,
            we => dbg11_we, be => cpu_be, mem_req => cpu_req, mem_ifetch => cpu_ifetch,
            lock => cpu_lock,
            io_addr => io_addr, io_dout => io_dout, io_din => io_din, io_re => io_re, io_we => io_we,
            halted => halted,
            pg_enable => pg_enable, cr3_out => cr3_out, tlb_flush => tlb_flush,
            page_fault => page_fault, fault_addr => fault_addr,
            dbg02_state => dbg02_state, dbg03_ir => dbg03_ir,
            dbg05_eax => dbg05_eax, dbg06_ebx => dbg06_ebx, dbg07_ecx => dbg07_ecx,
            dbg_edx => dbg_edx, dbg08_esp => dbg08_esp, dbg09_flags => dbg09_flags,
            dbg10_ivt => dbg10_ivt, dbg_ud => ud_fault, dbg_pc => dbg_pc,
            dbg_cr2 => cr2, dbg_cr3 => cr3);

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

    ap : entity work.x86_cpu
        generic map (AP_PARK => true)
        port map (
            clk => dbg01_clk, reset => reset, wake => ap_wake, wake_eip => ap_wake_eip,
            data_in => a1_rd, ready => a1_ready,
            addr_out => a1_addr, data_out => a1_wr,
            we => a1_we, be => a1_be, mem_req => a1_req, mem_ifetch => a1_ifetch, lock => a1_lock,
            halted => halt1,
            pg_enable => ap_pg, cr3_out => ap_cr3, tlb_flush => ap_tlbf,
            page_fault => ap_pf, fault_addr => ap_faddr);

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

    io_inst : entity work.port_io
        port map (clk => dbg01_clk, reset => reset,
                  io_addr => io_addr, io_dout => io_dout, io_din => io_din,
                  io_re => io_re, io_we => io_we,
                  dbg_last_port => open, dbg_last_data => open, dbg_console => open);

    apic0 : entity work.apic
        port map (clk => dbg01_clk, reset => reset,
                  bus_addr => cpu_addr, bus_wdata => cpu_dout,
                  bus_we => dbg11_we, bus_req => cpu_req, bus_ready => cpu_ready,
                  ap_wake => ap_wake, ap_wake_eip => ap_wake_eip, dbg_started => open);

    mem : entity work.l1_mesi
        generic map (init_file => program_file)
        port map (
            clk => dbg01_clk, reset => reset,
            a0_addr => p0_addr, a0_din => p0_wr, a0_dout => p0_rd,
            a0_we => p0_we, a0_be => p0_be, a0_req => p0_req, a0_ifetch => p0_ifetch,
            a0_lock => cpu_lock, a0_ready => p0_ready,
            a1_addr => p1_addr, a1_din => p1_wr, a1_dout => p1_rd,
            a1_we => p1_we, a1_be => p1_be, a1_req => p1_req, a1_ifetch => p1_ifetch,
            a1_lock => a1_lock, a1_ready => p1_ready,
            snoop_addr => dump_addr, snoop_byte => dump_data,
            dbg_c0_dhits => dc_hits, dbg_c0_dmiss => dc_misses,
            dbg_c1_dhits => open, dbg_c1_dmiss => open,
            dbg_c0_ihits => ic_hits, dbg_c0_imiss => ic_misses,
            dbg_c1_ihits => open, dbg_c1_imiss => open,
            dbg_invalidations => open, dbg_writebacks => cache_wb, dbg_smc_inval => open,
            dbg_watch_line => "00", dbg_c0_state => open, dbg_c1_state => open, dbg_grant => open);

    stim_proc : process
        variable l   : line;
        constant HEX : string := "0123456789ABCDEF";
        procedure write_hex2(b : std_logic_vector(7 downto 0)) is
            variable n : integer;
        begin
            n := to_integer(unsigned(b));
            write(l, HEX(n / 16 + 1)); write(l, HEX(n mod 16 + 1));
        end procedure;
        procedure write_hex3(v : integer) is
        begin
            write(l, HEX((v / 256) mod 16 + 1));
            write(l, HEX((v / 16) mod 16 + 1));
            write(l, HEX(v mod 16 + 1));
        end procedure;
    begin
        reset <= '1';
        wait for CLK_PERIOD * 2;
        reset <= '0';

        for i in 1 to SIM_CYCLES loop
            wait for CLK_PERIOD;
            exit when halted = '1' and halt1 = '1';
            if ud_fault = '1' then
                report "#UD (invalid opcode) at EIP=0x" & to_hstring(dbg_pc) &
                       " -- simulation stopped" severity warning;
                exit;
            end if;
        end loop;

        report "=== Simulation finished ===";
        report "Final EAX   = 0x" & to_hstring(dbg05_eax);
        report "Final EBX   = 0x" & to_hstring(dbg06_ebx);
        report "Final ECX   = 0x" & to_hstring(dbg07_ecx);
        report "Final EDX   = 0x" & to_hstring(dbg_edx);
        report "Final ESP   = 0x" & to_hstring(dbg08_esp);
        report "Final PC    = 0x" & to_hstring(dbg_pc);
        report "Zero flag   = " & std_logic'image(dbg09_flags(0));
        report "Carry flag  = " & std_logic'image(dbg09_flags(1));
        report "Int flag    = " & std_logic'image(dbg09_flags(2));
        report "IVT base    = 0x" & to_hstring(dbg10_ivt);
        report "Halted      = "   & std_logic'image(halted);

        write(l, string'(""));  writeline(output, l);
        write(l, string'("=== Paging (scaled x86: 64B pages, single-level PT) ==="));
        writeline(output, l);
        write(l, string'("  CR0.PG            = "));
        write(l, integer'image(to_integer(unsigned'("" & pg_enable))));
        writeline(output, l);
        write(l, string'("  CR3 (PT base)     = 0x" & to_hstring(cr3)));  writeline(output, l);
        write(l, string'("  CR2 (last fault)  = 0x" & to_hstring(cr2)));  writeline(output, l);
        write(l, string'("  TLB translations  = ")); write(l, to_integer(unsigned(p_trans)));  writeline(output, l);
        write(l, string'("  page-table walks  = ")); write(l, to_integer(unsigned(p_walks)));  writeline(output, l);
        write(l, string'("  page faults (#PF) = ")); write(l, to_integer(unsigned(p_flts)));   writeline(output, l);
        write(l, string'("  L1 (BSP) I h/m = ")); write(l, to_integer(unsigned(ic_hits)));
        write(l, string'("/")); write(l, to_integer(unsigned(ic_misses)));
        write(l, string'("  D h/m = ")); write(l, to_integer(unsigned(dc_hits)));
        write(l, string'("/")); write(l, to_integer(unsigned(dc_misses))); writeline(output, l);

        write(l, string'(""));  writeline(output, l);
        write(l, string'("=== Memory dump (physical 0x000..0x1FF) ==="));
        writeline(output, l);  writeline(output, l);
        write(l, string'("      "));
        for col in 0 to 31 loop
            if col = 16 then write(l, string'(" ")); end if;
            write(l, string'(" ")); write_hex2(std_logic_vector(to_unsigned(col, 8)));
        end loop;
        writeline(output, l);  writeline(output, l);
        for row in 0 to 15 loop
            write(l, string'("0x")); write_hex3(row * 32); write(l, string'(" "));
            for col in 0 to 31 loop
                dump_addr <= std_logic_vector(to_unsigned(row * 32 + col, 32));
                wait for 1 ns;
                if col = 16 then write(l, string'(" ")); end if;
                write(l, string'(" ")); write_hex2(dump_data);
            end loop;
            writeline(output, l);
        end loop;
        write(l, string'(""));  writeline(output, l);

        sim_done <= true;
        wait;
    end process;

end sim;
