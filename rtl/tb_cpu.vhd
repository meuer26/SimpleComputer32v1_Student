--------------------------------------------------------------------------------
-- Testbench: the dual-Pentium (P54C) machine -- two superscalar P5 cores
-- sharing one coherent split-L1 (MESI) memory, with local-APIC SIPI start-up.
-- (The core is the P5; glueless dual-processor + the on-chip APIC are P54C.)
--
-- This is the DEFAULT machine. Core 0 is the bootstrap processor (BSP) and runs
-- the test program from reset; core 1 is an application processor (AP) that
-- boots PARKED (wait-for-SIPI). A single-threaded program (the whole 01-34
-- suite) simply runs on the BSP with the AP idle; a program that writes the
-- APIC ICR (INIT + STARTUP IPI) brings the AP online for real SMP work.
--
-- Because the data caches are write-back, freshly stored values may still be
-- dirty in a cache at HALT, so the memory dump reads through l1_mesi's coherent
-- snoop (a Modified line in either core wins over RAM).
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity tb_cpu is
    generic (
        program_file : string  := "";
        disasm_file  : string  := ""     -- program disassembly, for the pipeline view
    );
end tb_cpu;

architecture sim of tb_cpu is

    signal dbg01_clk : std_logic := '0';
    signal reset     : std_logic := '1';

    -- BSP (core 0) debug taps
    signal dbg02_state       : std_logic_vector(3 downto 0);
    signal dbg03_ir          : std_logic_vector(7 downto 0);
    signal dbg04_operand     : std_logic_vector(31 downto 0);
    signal dbg05_eax         : std_logic_vector(31 downto 0);
    signal dbg06_ebx         : std_logic_vector(31 downto 0);
    signal dbg07_ecx         : std_logic_vector(31 downto 0);
    signal dbg_edx           : std_logic_vector(31 downto 0);
    signal dbg08_esp         : std_logic_vector(31 downto 0);
    signal dbg09_flags       : std_logic_vector(2 downto 0);
    signal dbg10_ivt         : std_logic_vector(31 downto 0);
    signal dbg11_we          : std_logic;
    signal dbg13_xchg_active : std_logic;
    signal dbg_state_name    : std_logic_vector(8*16-1 downto 0);
    signal cpu_lock          : std_logic;
    signal cpu_req           : std_logic;
    signal cpu_ifetch        : std_logic;
    signal cpu_ready         : std_logic;
    signal dbg_pc            : std_logic_vector(31 downto 0);

    -- BSP bus to l1_mesi
    signal cpu_addr : std_logic_vector(31 downto 0);
    signal cpu_dout : std_logic_vector(31 downto 0);   -- BSP writes
    signal cpu_din  : std_logic_vector(31 downto 0);   -- BSP reads
    signal cpu_be   : std_logic_vector(3 downto 0);
    signal halted   : std_logic;                       -- BSP halted
    signal ud_fault : std_logic;

    -- AP (core 1) bus to l1_mesi
    signal a1_addr, a1_wr, a1_rd : std_logic_vector(31 downto 0);
    signal a1_we, a1_req, a1_ifetch, a1_lock, a1_ready, halt1 : std_logic;
    signal a1_be : std_logic_vector(3 downto 0);
    signal pc1   : std_logic_vector(31 downto 0);
    signal ap_wake     : std_logic := '0';
    signal ap_wake_eip : std_logic_vector(31 downto 0) := (others => '0');

    -- separate I/O bus (x86 IN/OUT) on the BSP
    signal io_addr  : std_logic_vector(15 downto 0);
    signal io_dout  : std_logic_vector(31 downto 0);
    signal io_din   : std_logic_vector(31 downto 0);
    signal io_re, io_we : std_logic;
    signal io_last_port : std_logic_vector(15 downto 0);
    signal io_last_data, io_console : std_logic_vector(31 downto 0);

    -- cache statistics (core 0 / BSP)
    signal ic_hits, ic_misses, dc_hits, dc_misses : std_logic_vector(31 downto 0);
    signal cache_writebacks, smc_inval : std_logic_vector(31 downto 0);

    -- performance counters: retired instructions + elapsed cycles -> CPI
    signal cyc_count     : integer := 0;
    signal instret_count : integer := 0;
    signal retire        : std_logic;
    signal stall         : std_logic_vector(2 downto 0);
    signal stage_valid   : std_logic_vector(3 downto 0);
    type stall_cnt_t is array (0 to 7) of integer;
    signal stall_cnt     : stall_cnt_t := (others => 0);
    signal saw_pipe      : boolean := false;

    signal dump_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal dump_data : std_logic_vector(7 downto 0);

    signal sim_done : boolean := false;

    constant CLK_PERIOD : time    := 100 ns;
    constant SIM_CYCLES : integer := 200000;

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

    -- Bootstrap processor: runs the program from reset.
    bsp : entity work.x86_cpu
        generic map (DISASM_FILE => disasm_file)
        port map (
            clk               => dbg01_clk,
            reset             => reset,
            data_in           => cpu_din,
            ready             => cpu_ready,
            addr_out          => cpu_addr,
            data_out          => cpu_dout,
            we                => dbg11_we,
            be                => cpu_be,
            mem_req           => cpu_req,
            mem_ifetch        => cpu_ifetch,
            lock              => cpu_lock,
            io_addr           => io_addr,
            io_dout           => io_dout,
            io_din            => io_din,
            io_re             => io_re,
            io_we             => io_we,
            halted            => halted,
            dbg02_state       => dbg02_state,
            dbg03_ir          => dbg03_ir,
            dbg04_operand     => dbg04_operand,
            dbg05_eax         => dbg05_eax,
            dbg06_ebx         => dbg06_ebx,
            dbg07_ecx         => dbg07_ecx,
            dbg_edx           => dbg_edx,
            dbg08_esp         => dbg08_esp,
            dbg09_flags       => dbg09_flags,
            dbg10_ivt         => dbg10_ivt,
            dbg13_xchg_active => dbg13_xchg_active,
            dbg_state_name    => dbg_state_name,
            dbg_ud            => ud_fault,
            dbg_retire        => retire,
            dbg_stall         => stall,
            dbg_stage_valid   => stage_valid,
            dbg_pc            => dbg_pc
        );

    -- Application processor: boots parked, started by the BSP via SIPI.
    ap : entity work.x86_cpu
        generic map (AP_PARK => true)
        port map (
            clk      => dbg01_clk,
            reset    => reset,
            wake     => ap_wake,
            wake_eip => ap_wake_eip,
            data_in  => a1_rd,
            ready    => a1_ready,
            addr_out => a1_addr,
            data_out => a1_wr,
            we       => a1_we,
            be       => a1_be,
            mem_req  => a1_req,
            mem_ifetch => a1_ifetch,
            lock     => a1_lock,
            halted   => halt1,
            dbg_pc   => pc1
        );

    io_inst : entity work.port_io
        port map (
            clk     => dbg01_clk,
            reset   => reset,
            io_addr => io_addr,
            io_dout => io_dout,
            io_din  => io_din,
            io_re   => io_re,
            io_we   => io_we,
            dbg_last_port => io_last_port,
            dbg_last_data => io_last_data,
            dbg_console   => io_console
        );

    -- Local APIC: the BSP's ICR writes (INIT + STARTUP IPI) start the AP.
    apic0 : entity work.apic
        port map (clk => dbg01_clk, reset => reset,
                  bus_addr => cpu_addr, bus_wdata => cpu_dout,
                  bus_we => dbg11_we, bus_req => cpu_req, bus_ready => cpu_ready,
                  ap_wake => ap_wake, ap_wake_eip => ap_wake_eip, dbg_started => open);

    -- Coherent split-L1 (MESI) memory shared by both cores (RAM is internal).
    mem : entity work.l1_mesi
        generic map (init_file => program_file)
        port map (
            clk => dbg01_clk, reset => reset,
            a0_addr => cpu_addr, a0_din => cpu_dout, a0_dout => cpu_din,
            a0_we => dbg11_we, a0_be => cpu_be, a0_req => cpu_req,
            a0_ifetch => cpu_ifetch, a0_lock => cpu_lock, a0_ready => cpu_ready,
            a1_addr => a1_addr, a1_din => a1_wr, a1_dout => a1_rd,
            a1_we => a1_we, a1_be => a1_be, a1_req => a1_req,
            a1_ifetch => a1_ifetch, a1_lock => a1_lock, a1_ready => a1_ready,
            snoop_addr => dump_addr, snoop_byte => dump_data,
            dbg_c0_dhits => dc_hits, dbg_c0_dmiss => dc_misses,
            dbg_c1_dhits => open,    dbg_c1_dmiss => open,
            dbg_c0_ihits => ic_hits, dbg_c0_imiss => ic_misses,
            dbg_c1_ihits => open,    dbg_c1_imiss => open,
            dbg_invalidations => open, dbg_writebacks => cache_writebacks,
            dbg_smc_inval => smc_inval,
            dbg_watch_line => "00", dbg_c0_state => open, dbg_c1_state => open,
            dbg_grant => open);

    stim_proc : process
        variable l   : line;
        constant HEX : string := "0123456789ABCDEF";
        variable ih, im, dh, dm, hits_int, misses_int, total : integer;

        procedure write_hex2(b : std_logic_vector(7 downto 0)) is
            variable n : integer;
        begin
            n := to_integer(unsigned(b));
            write(l, HEX(n / 16 + 1));
            write(l, HEX(n mod 16 + 1));
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
            exit when halted = '1' and halt1 = '1';    -- BSP done and AP done/parked
            if ud_fault = '1' then
                report "#UD (invalid opcode, vector 6): opcode 0x" & to_hstring(dbg03_ir) &
                       " at EIP=0x" & to_hstring(dbg_pc) &
                       " is not implemented by this CPU -- simulation stopped"
                       severity warning;
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
        report "IO last port= 0x" & to_hstring(io_last_port) &
               "  data=0x" & to_hstring(io_last_data) &
               "  console=0x" & to_hstring(io_console);

        ih := to_integer(unsigned(ic_hits));   im := to_integer(unsigned(ic_misses));
        dh := to_integer(unsigned(dc_hits));   dm := to_integer(unsigned(dc_misses));
        hits_int := ih + dh;  misses_int := im + dm;  total := hits_int + misses_int;

        write(l, string'(""));  writeline(output, l);
        -- Geometry line is machine-parsed by verify_cache.py. The Pentium has
        -- SEPARATE instruction and data caches; each is 4 sets x 2 ways x 8
        -- words (32 B line, 256 B), per core, kept coherent by MESI.
        write(l, string'("=== Cache geometry: split I/D, each sets=4 ways=2 words=8 "));
        write(l, string'("(line=32B, size=256B) ==="));
        writeline(output, l);
        write(l, string'("=== Cache statistics (BSP, core 0) ==="));
        writeline(output, l);
        write(l, string'("  I-cache hits/misses = ")); write(l, ih);
        write(l, string'(" / ")); write(l, im); writeline(output, l);
        write(l, string'("  D-cache hits/misses = ")); write(l, dh);
        write(l, string'(" / ")); write(l, dm); writeline(output, l);
        write(l, string'("  hits       = ")); write(l, hits_int);   writeline(output, l);
        write(l, string'("  misses     = ")); write(l, misses_int); writeline(output, l);
        write(l, string'("  total      = ")); write(l, total);      writeline(output, l);
        write(l, string'("  writebacks = ")); write(l, to_integer(unsigned(cache_writebacks)));
        writeline(output, l);
        write(l, string'("  SMC I-invalidations = ")); write(l, to_integer(unsigned(smc_inval)));
        writeline(output, l);
        if total > 0 then
            write(l, string'("  hit rate (per-mille) = "));
            write(l, (hits_int * 1000) / total);
            writeline(output, l);
        end if;

        write(l, string'(""));  writeline(output, l);
        write(l, string'("=== Performance ==="));
        writeline(output, l);
        write(l, string'("  instructions retired = ")); write(l, instret_count);  writeline(output, l);
        write(l, string'("  cycles               = ")); write(l, cyc_count);      writeline(output, l);
        if instret_count > 0 then
            write(l, string'("  CPI (per-mille)      = "));
            write(l, (cyc_count * 1000) / instret_count);
            writeline(output, l);
        end if;
        if saw_pipe then
            write(l, string'("  core                 = superscalar Pentium (U/V, BTB)"));
            writeline(output, l);
            write(l, string'("  stall cycles: microcode=")); write(l, stall_cnt(1));
            write(l, string'(" AGI="));         write(l, stall_cnt(2));
            write(l, string'(" branch="));      write(l, stall_cnt(3));
            write(l, string'(" queue-empty=")); write(l, stall_cnt(4));
            write(l, string'(" mem-wait="));    write(l, stall_cnt(5));
            write(l, string'(" bus-busy="));    write(l, stall_cnt(6));
            writeline(output, l);
        end if;

        write(l, string'(""));  writeline(output, l);
        write(l, string'("=== Memory dump (0x000..0x1FF) ==="));
        writeline(output, l);
        writeline(output, l);
        write(l, string'("      "));
        for col in 0 to 31 loop
            if col = 16 then write(l, string'(" ")); end if;
            write(l, string'(" "));
            write_hex2(std_logic_vector(to_unsigned(col, 8)));
        end loop;
        writeline(output, l);
        writeline(output, l);

        for row in 0 to 15 loop
            write(l, string'("0x"));
            write_hex3(row * 32);
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
        write(l, string'(""));  writeline(output, l);

        sim_done <= true;
        wait;
    end process;

    -- Performance counters for the BSP: retirements + cycles -> CPI, stall mix.
    count_proc : process(dbg01_clk)
    begin
        if rising_edge(dbg01_clk) and reset = '0' and halted = '0' then
            cyc_count <= cyc_count + 1;
            if retire = '1' then instret_count <= instret_count + 1; end if;
            stall_cnt(to_integer(unsigned(stall))) <= stall_cnt(to_integer(unsigned(stall))) + 1;
            if stage_valid(2) = '1' then saw_pipe <= true; end if;
        end if;
    end process;

    trace_proc : process(dbg01_clk)
    begin
        if falling_edge(dbg01_clk) and reset = '0' and halted = '0' then
            report "t=" & time'image(now) &
                   " st="    & integer'image(to_integer(unsigned(dbg02_state))) &
                   " IR=0x"  & to_hstring(dbg03_ir) &
                   " OP=0x"  & to_hstring(dbg04_operand) &
                   " EAX=0x" & to_hstring(dbg05_eax) &
                   " EBX=0x" & to_hstring(dbg06_ebx) &
                   " ECX=0x" & to_hstring(dbg07_ecx) &
                   " ESP=0x" & to_hstring(dbg08_esp) &
                   " ZCI="   & std_logic'image(dbg09_flags(0)) &
                              std_logic'image(dbg09_flags(1)) &
                              std_logic'image(dbg09_flags(2)) &
                   " PC=0x"  & to_hstring(dbg_pc) &
                   " WE="    & std_logic'image(dbg11_we) &
                   " ADDR=0x" & to_hstring(cpu_addr) &
                   " REQ="   & std_logic'image(cpu_req) &
                   " IF="    & std_logic'image(cpu_ifetch) &
                   " $="     & std_logic'image(cpu_req and cpu_ready);  -- access completes
        end if;
    end process;

end sim;
