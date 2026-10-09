--------------------------------------------------------------------------------
-- port_io : a simple peripheral living in the x86 I/O address space.
--
-- This is NOT memory -- it sits on the CPU's separate I/O bus (driven only by
-- IN/OUT) and is not cached. It models a small bank of device registers: an
-- OUT writes the addressed 32-bit port register, an IN reads it back. That is
-- enough to show the I/O space round-tripping independently of RAM.
--
-- Port 0xE9 additionally latches whatever is written to it into a debug tap
-- (the classic "debug console" port), so a testbench can observe device output.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity port_io is
    port (
        clk     : in  std_logic;
        reset   : in  std_logic;
        io_addr : in  std_logic_vector(15 downto 0);
        io_dout : in  std_logic_vector(31 downto 0);   -- data from CPU (OUT)
        io_din  : out std_logic_vector(31 downto 0);   -- data to CPU   (IN)
        io_re   : in  std_logic;
        io_we   : in  std_logic;
        -- debug taps
        dbg_last_port : out std_logic_vector(15 downto 0);
        dbg_last_data : out std_logic_vector(31 downto 0);
        dbg_console   : out std_logic_vector(31 downto 0)
    );
end port_io;

architecture behavioral of port_io is
    -- 256 device registers (indexed by the low byte of the port number)
    type ports_t is array (0 to 255) of std_logic_vector(31 downto 0);
    signal regs : ports_t := (others => (others => '0'));

    signal last_port : std_logic_vector(15 downto 0) := (others => '0');
    signal last_data : std_logic_vector(31 downto 0) := (others => '0');
    signal console   : std_logic_vector(31 downto 0) := (others => '0');
begin

    -- Combinational read (IN): present the addressed register.
    io_din <= regs(to_integer(unsigned(io_addr(7 downto 0))));

    -- Synchronous write (OUT).
    process(clk, reset)
    begin
        if reset = '1' then
            regs <= (others => (others => '0'));
            last_port <= (others => '0');
            last_data <= (others => '0');
            console   <= (others => '0');
        elsif rising_edge(clk) then
            if io_we = '1' then
                regs(to_integer(unsigned(io_addr(7 downto 0)))) <= io_dout;
                last_port <= io_addr;
                last_data <= io_dout;
                if io_addr = x"00E9" then
                    console <= io_dout;
                end if;
            end if;
        end if;
    end process;

    dbg_last_port <= last_port;
    dbg_last_data <= last_data;
    dbg_console   <= console;

end behavioral;
