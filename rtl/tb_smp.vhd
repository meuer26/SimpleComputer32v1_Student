--------------------------------------------------------------------------------
-- Testbench: dual-Pentium SMP -- two superscalar cores sharing one snoopy MESI
-- memory, with faithful BSP/AP bring-up.
--
-- Core 0 is the BOOTSTRAP processor: it runs from reset. Core 1 is an
-- APPLICATION processor (AP_PARK): it boots PARKED and begins executing only
-- when core 0 writes its entry address to the start-up mailbox at 0x1F0 -- a
-- scaled Pentium startup IPI (the ap_boot process below turns that write into
-- the AP's `wake` pulse + start vector). A single-threaded program that never
-- writes the mailbox simply runs on core 0 with core 1 parked.
--
-- The demo image has both cores increment a shared counter 4 times under a
-- LOCK CMPXCHG spinlock; MESI coherency + sticky-LOCK# atomicity make the
-- result exactly 8 -- no lost updates -- and you can watch the invalidations /
-- write-backs / MESI line states that make it work.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity tb_smp is
    generic (
        program_file : string := "";
        disasm_file  : string := ""     -- per-stage instruction text for both cores
    );
end tb_smp;

architecture sim of tb_smp is
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- core 0
    signal a0_addr, a0_din, a0_dout : std_logic_vector(31 downto 0);
    signal a0_we, a0_req, a0_lock, a0_ready, halt0 : std_logic;
    signal pc0 : std_logic_vector(31 downto 0);
    signal sname0 : std_logic_vector(8*16-1 downto 0);
    signal be0 : std_logic_vector(3 downto 0);
    -- core 1
    signal a1_addr, a1_din, a1_dout : std_logic_vector(31 downto 0);
    signal a1_we, a1_req, a1_lock, a1_ready, halt1 : std_logic;
    signal pc1 : std_logic_vector(31 downto 0);
    signal sname1 : std_logic_vector(8*16-1 downto 0);
    signal be1 : std_logic_vector(3 downto 0);

    signal if0, if1 : std_logic;         -- instruction-fetch class to the caches

    -- AP (core 1) start-up via the local APIC (SIPI).
    signal ap_wake     : std_logic := '0';
    signal ap_wake_eip : std_logic_vector(31 downto 0) := (others => '0');

    -- coherent memory debug
    signal c0_h, c0_m, c1_h, c1_m, invs, wbs : std_logic_vector(31 downto 0);
    signal c0_st, c1_st, grant : std_logic_vector(1 downto 0);

    signal dump_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal dump_byte : std_logic_vector(7 downto 0);

    signal sim_done : boolean := false;
    constant CLK_PERIOD : time := 100 ns;
    constant SIM_CYCLES : integer := 100000;
begin

    clk_proc : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    core0 : entity work.x86_cpu
        generic map (DISASM_FILE => disasm_file)
        port map (clk => clk, reset => reset,
                  data_in => a0_dout, ready => a0_ready,
                  addr_out => a0_addr, data_out => a0_din,
                  we => a0_we, be => be0, mem_req => a0_req, mem_ifetch => if0, lock => a0_lock,
                  halted => halt0, dbg_pc => pc0, dbg_state_name => sname0,
                  dbg02_state => open, dbg03_ir => open, dbg04_operand => open,
                  dbg05_eax => open, dbg06_ebx => open, dbg07_ecx => open,
                  dbg08_esp => open, dbg09_flags => open, dbg10_ivt => open);

    core1 : entity work.x86_cpu
        generic map (AP_PARK => true, DISASM_FILE => disasm_file)  -- the application processor: boots parked
        port map (clk => clk, reset => reset,
                  wake => ap_wake, wake_eip => ap_wake_eip,
                  data_in => a1_dout, ready => a1_ready,
                  addr_out => a1_addr, data_out => a1_din,
                  we => a1_we, be => be1, mem_req => a1_req, mem_ifetch => if1, lock => a1_lock,
                  halted => halt1, dbg_pc => pc1, dbg_state_name => sname1,
                  dbg02_state => open, dbg03_ir => open, dbg04_operand => open,
                  dbg05_eax => open, dbg06_ebx => open, dbg07_ecx => open,
                  dbg08_esp => open, dbg09_flags => open, dbg10_ivt => open);

    -- Local APIC: the BSP's ICR writes (INIT, then STARTUP IPI) start the AP.
    apic0 : entity work.apic
        port map (clk => clk, reset => reset,
                  bus_addr => a0_addr, bus_wdata => a0_din,
                  bus_we => a0_we, bus_req => a0_req, bus_ready => a0_ready,
                  ap_wake => ap_wake, ap_wake_eip => ap_wake_eip, dbg_started => open);

    mem : entity work.l1_mesi
        generic map (init_file => program_file)
        port map (
            clk => clk, reset => reset,
            a0_addr => a0_addr, a0_din => a0_din, a0_dout => a0_dout,
            a0_we => a0_we, a0_be => be0, a0_req => a0_req, a0_ifetch => if0,
            a0_lock => a0_lock, a0_ready => a0_ready,
            a1_addr => a1_addr, a1_din => a1_din, a1_dout => a1_dout,
            a1_we => a1_we, a1_be => be1, a1_req => a1_req, a1_ifetch => if1,
            a1_lock => a1_lock, a1_ready => a1_ready,
            snoop_addr => dump_addr, snoop_byte => dump_byte,
            dbg_c0_dhits => c0_h, dbg_c0_dmiss => c0_m,
            dbg_c1_dhits => c1_h, dbg_c1_dmiss => c1_m,
            dbg_c0_ihits => open, dbg_c0_imiss => open,
            dbg_c1_ihits => open, dbg_c1_imiss => open,
            dbg_invalidations => invs, dbg_writebacks => wbs, dbg_smc_inval => open,
            dbg_watch_line => "00",             -- counter (0x110) is in set 0
            dbg_c0_state => c0_st, dbg_c1_state => c1_st, dbg_grant => grant);

    stim : process
        variable l : line;
        variable counter : integer;
    begin
        reset <= '1';
        wait for CLK_PERIOD*2;
        reset <= '0';

        for i in 1 to SIM_CYCLES loop
            wait for CLK_PERIOD;
            exit when halt0 = '1' and halt1 = '1';
        end loop;

        report "=== SMP simulation finished ===";
        report "core0 halted=" & std_logic'image(halt0) & " PC=0x" & to_hstring(pc0);
        report "core1 halted=" & std_logic'image(halt1) & " PC=0x" & to_hstring(pc1);

        -- read the shared counter at 0x110 (coherent snoop, little-endian dword)
        counter := 0;
        for k in 0 to 3 loop
            dump_addr <= std_logic_vector(to_unsigned(16#110# + k, 32));
            wait for 1 ns;
            counter := counter + to_integer(unsigned(dump_byte)) * (256 ** k);
        end loop;
        dump_addr <= std_logic_vector(to_unsigned(16#100#, 32));
        wait for 1 ns;

        write(l, string'("")); writeline(output, l);
        write(l, string'("Shared counter mem[0x110] = ")); write(l, counter);
        write(l, string'("  (expected 8 = 2 cores x 4 increments)")); writeline(output, l);
        write(l, string'("lock mem[0x100] = ")); write(l, to_integer(unsigned(dump_byte)));
        writeline(output, l);
        write(l, string'("core0 cache: hits=")); write(l, to_integer(unsigned(c0_h)));
        write(l, string'(" misses=")); write(l, to_integer(unsigned(c0_m))); writeline(output, l);
        write(l, string'("core1 cache: hits=")); write(l, to_integer(unsigned(c1_h)));
        write(l, string'(" misses=")); write(l, to_integer(unsigned(c1_m))); writeline(output, l);
        write(l, string'("snoop invalidations = ")); write(l, to_integer(unsigned(invs)));
        writeline(output, l);
        write(l, string'("snoop/evict writebacks = ")); write(l, to_integer(unsigned(wbs)));
        writeline(output, l);

        if counter = 8 then
            write(l, string'("SMP COHERENCY: PASS"));
        else
            write(l, string'("SMP COHERENCY: FAIL"));
        end if;
        writeline(output, l);

        sim_done <= true;
        wait;
    end process;

end sim;
