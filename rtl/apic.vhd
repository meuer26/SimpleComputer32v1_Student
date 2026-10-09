--------------------------------------------------------------------------------
-- apic : scaled local-APIC SMP start-up (the SIPI mechanism)
--
-- The on-chip local APIC is a P54C addition (the P5 core itself had none); it is
-- what makes a glueless dual-Pentium board possible.
--
-- On a real x86 SMP the bootstrap processor (BSP) starts each application
-- processor (AP) by programming its local APIC's Interrupt Command Register
-- (ICR): an INIT IPI, then a STARTUP IPI (SIPI) carrying an 8-bit vector. The
-- AP, which powered up waiting for a SIPI, then begins executing at the physical
-- address vector << 12 (vector x 4 KB).
--
-- This models that faithfully, scaled to the 512-byte world: the ICR is a
-- memory-mapped register (default 0x1F0). The BSP writes
--      INIT     : delivery mode 101 in bits [10:8]   (0x500)
--      STARTUP  : delivery mode 110 in bits [10:8], vector in [7:0] (0x600 | v)
-- and this unit turns the STARTUP write into the AP's `wake` pulse with
--      wake_eip = vector x PAGE        (PAGE = 64 B here, so vector 1 -> 0x40).
-- The AP ignores further SIPIs once it has started (as real APs do). Until the
-- BSP sends the SIPI, only the BSP runs -- exactly the power-on state.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity apic is
    generic (
        ICR_ADDR : integer := 16#1F0#;   -- memory-mapped ICR address
        PAGE     : integer := 16#40#     -- scaled page (SIPI vector * PAGE = start EIP)
    );
    port (
        clk   : in  std_logic;
        reset : in  std_logic;

        -- the BSP's committed bus writes are snooped here
        bus_addr  : in  std_logic_vector(31 downto 0);
        bus_wdata : in  std_logic_vector(31 downto 0);
        bus_we    : in  std_logic;
        bus_req   : in  std_logic;
        bus_ready : in  std_logic;

        -- SIPI delivered to the AP
        ap_wake     : out std_logic := '0';
        ap_wake_eip : out std_logic_vector(31 downto 0) := (others => '0');
        dbg_started : out std_logic                       -- the AP has been started
    );
end apic;

architecture behavioral of apic is
    constant STARTUP : std_logic_vector(2 downto 0) := "110";
    signal started   : std_logic := '0';
begin

    dbg_started <= started;

    process(clk, reset)
    begin
        if reset = '1' then
            ap_wake <= '0'; ap_wake_eip <= (others => '0'); started <= '0';
        elsif rising_edge(clk) then
            ap_wake <= '0';                                   -- one-cycle pulse
            -- A committed ICR write with the STARTUP delivery mode is a SIPI.
            -- Decode the address only ONCE the write strobes are asserted: VHDL
            -- `and` does not short-circuit, so comparing bus_addr unconditionally
            -- would warn on the metavalue it carries while the bus is idle.
            if bus_req = '1' and bus_we = '1' and bus_ready = '1' then
                if unsigned(bus_addr(8 downto 0)) = to_unsigned(ICR_ADDR, 9)
                   and bus_wdata(10 downto 8) = STARTUP then
                    if started = '0' then                     -- APs ignore later SIPIs
                        ap_wake     <= '1';
                        ap_wake_eip <= std_logic_vector(resize(
                                           unsigned(bus_wdata(7 downto 0)) * to_unsigned(PAGE, 9), 32));
                        started     <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

end behavioral;
