--------------------------------------------------------------------------------
-- MMU -- scaled x86 paging (single-level page table + TLB)
--
-- Sits between the CPU and physical RAM and translates the CPU's *virtual*
-- addresses to *physical* ones, exactly like x86 paging, scaled to the 512 B
-- world:
--   - 64-byte pages  (offset = VA[5:0]) -- x86's 4 KB page, scaled.
--   - VA = 10 bits (1 KB, 16 virtual pages); PA = 9 bits (512 B, 8 frames), so
--     the virtual space is larger than physical -> demand paging is possible.
--   - Single-level page table based at CR3 (x86 uses a 2-level directory/table;
--     one level is the faithful simplification for 16 entries). PTE index = VPN.
--   - 4-byte PTEs, x86-style: bit 0 = Present, and the page's physical base is
--     the PTE with its low offset bits cleared -- so, exactly as on x86,
--         PA = (PTE & ~0x3F) | (VA & 0x3F).
--     (R/W, A, D flag bits are defined by convention but not enforced/updated in
--     hardware here -- the faithful-but-simple choice.)
--   - A 4-entry, fully-associative TLB (round-robin refill). A TLB miss triggers
--     a real hardware page-table walk (one physical read of the PTE), visible on
--     the bus. Writing CR3 flushes the TLB (tlb_flush), as on x86.
--   - A not-present PTE raises a page fault (page_fault + fault_addr) that the
--     CPU delivers as #PF (vector 14) through the existing interrupt path.
--
-- With paging disabled (CR0.PG = 0) the MMU is transparent: PA = VA, single
-- cycle -- so every non-paging program behaves exactly as before.
--
-- RAM reads are combinational, so a walk is a single extra (stall) cycle.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mmu is
    generic (
        OFF_BITS : integer := 6;    -- page offset bits (64-byte page)
        VPN_BITS : integer := 4;    -- virtual page number bits (16 pages -> 1 KB VA)
        TLB_N    : integer := 4     -- TLB entries
    );
    port (
        clk       : in  std_logic;
        reset     : in  std_logic;

        -- control from the CPU
        pg_enable : in  std_logic;                       -- CR0.PG
        cr3       : in  std_logic_vector(31 downto 0);   -- page-table base
        tlb_flush : in  std_logic;                       -- pulse: flush whole TLB

        -- CPU side (virtual addresses)
        cpu_addr  : in  std_logic_vector(31 downto 0);
        cpu_din   : in  std_logic_vector(31 downto 0);   -- data CPU writes
        cpu_dout  : out std_logic_vector(31 downto 0);   -- data to CPU
        cpu_we    : in  std_logic;
        cpu_be    : in  std_logic_vector(3 downto 0);
        cpu_req   : in  std_logic;
        cpu_ifetch: in  std_logic := '0';                -- 1 = instruction fetch
        cpu_ready : out std_logic;

        -- memory side (physical addresses). Downstream is the physically-tagged
        -- L1 cache (then RAM); it may stall, so the MMU waits on mem_ready and
        -- passes a request / the ifetch class through to route I vs D.
        mem_addr   : out std_logic_vector(31 downto 0);
        mem_din    : in  std_logic_vector(31 downto 0);
        mem_dout   : out std_logic_vector(31 downto 0);
        mem_we     : out std_logic;
        mem_be     : out std_logic_vector(3 downto 0);
        mem_req    : out std_logic;
        mem_ifetch : out std_logic;
        mem_ready  : in  std_logic := '1';

        -- fault delivery to the CPU
        page_fault : out std_logic;
        fault_addr : out std_logic_vector(31 downto 0);

        -- debug taps
        dbg_translations : out std_logic_vector(31 downto 0);
        dbg_walks        : out std_logic_vector(31 downto 0);
        dbg_faults       : out std_logic_vector(31 downto 0)
    );
end mmu;

architecture behavioral of mmu is

    constant OFF_MASK : unsigned(31 downto 0) :=
        to_unsigned(2 ** OFF_BITS - 1, 32);              -- page-offset mask (0x3F)

    -- current access decomposition
    signal offset : unsigned(OFF_BITS - 1 downto 0);
    signal vpn    : unsigned(VPN_BITS - 1 downto 0);

    -- TLB storage
    type vpn_arr  is array (0 to TLB_N - 1) of unsigned(VPN_BITS - 1 downto 0);
    type base_arr is array (0 to TLB_N - 1) of unsigned(31 downto 0);
    signal tlb_valid : std_logic_vector(0 to TLB_N - 1) := (others => '0');
    signal tlb_vpn   : vpn_arr  := (others => (others => '0'));
    signal tlb_base  : base_arr := (others => (others => '0'));  -- page physical base
    signal fill_ptr  : integer range 0 to TLB_N - 1 := 0;        -- round-robin refill

    signal tlb_hit  : std_logic;
    signal tlb_way  : integer range 0 to TLB_N - 1;
    signal phys     : unsigned(31 downto 0);                     -- translated PA on a hit

    -- controller
    type mstate_t is (M_IDLE, M_WALK);
    signal mstate : mstate_t := M_IDLE;

    -- PTE physical address for the current VPN
    signal pte_addr : unsigned(31 downto 0);

    signal trans_reg : unsigned(31 downto 0) := (others => '0');
    signal walk_reg  : unsigned(31 downto 0) := (others => '0');
    signal fault_reg : unsigned(31 downto 0) := (others => '0');

begin

    ----------------------------------------------------------------------------
    -- Address decode + TLB lookup (combinational)
    ----------------------------------------------------------------------------
    offset <= unsigned(cpu_addr(OFF_BITS - 1 downto 0));
    vpn    <= unsigned(cpu_addr(OFF_BITS + VPN_BITS - 1 downto OFF_BITS));

    -- PTE address = CR3 + VPN*4  (single-level table indexed by VPN)
    pte_addr <= unsigned(cr3) + resize(vpn & "00", 32);

    tlb_lookup : process(vpn, tlb_valid, tlb_vpn)
        variable h : std_logic;
        variable w : integer range 0 to TLB_N - 1;
    begin
        h := '0';
        w := 0;
        for i in 0 to TLB_N - 1 loop
            if tlb_valid(i) = '1' and tlb_vpn(i) = vpn then
                h := '1';
                w := i;
            end if;
        end loop;
        tlb_hit <= h;
        tlb_way <= w;
    end process;

    -- PA on a TLB hit: page base OR the untranslated offset (x86: base | offset).
    phys <= tlb_base(tlb_way) or resize(offset, 32);

    ----------------------------------------------------------------------------
    -- Bus + handshake (combinational)
    ----------------------------------------------------------------------------
    bus_proc : process(pg_enable, mstate, cpu_addr, cpu_din, cpu_we, cpu_be,
                       cpu_req, cpu_ifetch, mem_din, mem_ready, phys, pte_addr, tlb_hit)
    begin
        -- defaults
        mem_addr   <= cpu_addr;
        mem_dout   <= cpu_din;
        mem_we     <= '0';
        mem_be     <= cpu_be;
        mem_req    <= '0';
        mem_ifetch <= cpu_ifetch;
        cpu_dout   <= mem_din;
        cpu_ready  <= '1';
        page_fault <= '0';

        if pg_enable = '0' then
            -- Paging off: transparent address-wise, but the downstream cache
            -- may stall -- so pass the request through and chain its ready.
            mem_addr  <= cpu_addr;
            mem_we    <= cpu_we;
            mem_req   <= cpu_req;
            cpu_ready <= mem_ready;
        else
            case mstate is
                when M_IDLE =>
                    if cpu_req = '1' and tlb_hit = '1' then
                        -- translated access -> physically-tagged cache (may stall)
                        mem_addr  <= std_logic_vector(phys);
                        mem_we    <= cpu_we;
                        mem_req   <= '1';
                        cpu_ready <= mem_ready;
                    elsif cpu_req = '1' then
                        -- TLB miss: stall; the page-table walk starts next cycle
                        cpu_ready <= '0';
                    end if;
                when M_WALK =>
                    -- Read the PTE through the cache (it is data: ifetch=0). Wait
                    -- for the cache (mem_ready) before trusting mem_din. A not-
                    -- present PTE raises #PF once the read has actually returned.
                    mem_addr   <= std_logic_vector(pte_addr);
                    mem_we     <= '0';
                    mem_req    <= '1';
                    mem_ifetch <= '0';
                    cpu_ready  <= '0';
                    if mem_ready = '1' and mem_din(0) = '0' then
                        page_fault <= '1';
                    end if;
            end case;
        end if;
    end process;

    fault_addr <= cpu_addr;

    ----------------------------------------------------------------------------
    -- Controller + TLB refill + counters (clocked)
    ----------------------------------------------------------------------------
    ctrl : process(clk, reset)
    begin
        if reset = '1' then
            mstate    <= M_IDLE;
            tlb_valid <= (others => '0');
            fill_ptr  <= 0;
            trans_reg <= (others => '0');
            walk_reg  <= (others => '0');
            fault_reg <= (others => '0');
        elsif rising_edge(clk) then
            -- Writing CR3 flushes the TLB (x86 semantics).
            if tlb_flush = '1' then
                tlb_valid <= (others => '0');
            end if;

            if pg_enable = '1' then
                case mstate is
                    when M_IDLE =>
                        if cpu_req = '1' and tlb_hit = '1' then
                            if mem_ready = '1' then          -- access served by the cache
                                trans_reg <= trans_reg + 1;
                            end if;
                        elsif cpu_req = '1' then
                            mstate <= M_WALK;                -- begin the page-table walk
                        end if;

                    when M_WALK =>
                        -- Wait until the cache has returned the PTE.
                        if mem_ready = '1' then
                            if mem_din(0) = '1' then         -- Present: refill TLB
                                tlb_valid(fill_ptr) <= '1';
                                tlb_vpn(fill_ptr)   <= vpn;
                                tlb_base(fill_ptr)  <= unsigned(mem_din) and not OFF_MASK;
                                if fill_ptr = TLB_N - 1 then fill_ptr <= 0;
                                else fill_ptr <= fill_ptr + 1; end if;
                                walk_reg <= walk_reg + 1;
                                mstate   <= M_IDLE;          -- retry -> now a TLB hit
                            else                             -- not present: deliver #PF
                                fault_reg <= fault_reg + 1;
                                mstate    <= M_IDLE;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

    dbg_translations <= std_logic_vector(trans_reg);
    dbg_walks        <= std_logic_vector(walk_reg);
    dbg_faults       <= std_logic_vector(fault_reg);

end behavioral;
