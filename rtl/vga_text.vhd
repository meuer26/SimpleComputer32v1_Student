--------------------------------------------------------------------------------
-- vga_text : VGA colour text mode 3 (80 x 25) -- MEMORY-MAPPED video RAM plus
-- the CRTC cursor registers on PORTS.
--
-- Video RAM lives in the MEMORY address space at physical 0xB8000 (the
-- address decoder routes 0xB8000..0xB8FFF here). Each screen cell is 2 bytes:
--     byte 0 = character code (code page 437)
--     byte 1 = attribute: bits 3:0 foreground, 6:4 background, 7 blink
--   cell (row, col) is at 0xB8000 + 2*(80*row + col)
-- so `mov word [0xB8000], 0x1F41` puts a white-on-blue 'A' in the top-left
-- corner. Writes take effect at once (the screen is refreshed from this RAM);
-- this region is uncacheable, as on a real PC.
--
-- The hardware cursor is NOT in video RAM: it is set through the CRT
-- controller's index/data port pair in the I/O space:
--     OUT 0x3D4, 0x0E ; OUT 0x3D5, pos >> 8      (cursor location high)
--     OUT 0x3D4, 0x0F ; OUT 0x3D5, pos & 0xFF    (cursor location low)
-- where pos = 80*row + col. The other CRTC registers are stored and read back.
--
-- At reset the screen is blank (space, attribute 0x07 light grey on black) --
-- the state a BIOS leaves after clearing the screen.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity vga_text is
    port (
        clk       : in  std_logic;
        reset     : in  std_logic;
        -- memory side (video RAM window, 4 KB)
        mem_cs    : in  std_logic;
        mem_we    : in  std_logic;
        mem_be    : in  std_logic_vector(3 downto 0);
        mem_addr  : in  std_logic_vector(11 downto 0);   -- byte offset in the window
        mem_din   : in  std_logic_vector(31 downto 0);
        mem_dout  : out std_logic_vector(31 downto 0);
        -- I/O side: CRTC index (0x3D4) and data (0x3D5)
        cs_index  : in  std_logic;
        cs_data   : in  std_logic;
        io_wr     : in  std_logic;
        io_din    : in  std_logic_vector(7 downto 0);
        io_dout   : out std_logic_vector(7 downto 0);
        -- display outputs
        cursor    : out std_logic_vector(15 downto 0);   -- cursor location (cell index)
        -- the 80x25 characters as ASCII, row 0 first (MSB), for the waveform
        -- viewer and the end-of-run screen dump. Non-printables show as ' '.
        text      : out std_logic_vector(25*80*8 - 1 downto 0)
    );
end vga_text;

architecture behavioral of vga_text is
    constant VRAM_SIZE : integer := 4096;
    type vram_t is array (0 to VRAM_SIZE - 1) of std_logic_vector(7 downto 0);

    function blank_screen return vram_t is
        variable v : vram_t;
    begin
        for i in 0 to VRAM_SIZE / 2 - 1 loop
            v(2 * i)     := x"20";     -- space
            v(2 * i + 1) := x"07";     -- light grey on black
        end loop;
        return v;
    end function;

    signal vram  : vram_t := blank_screen;
    type crtc_t is array (0 to 31) of std_logic_vector(7 downto 0);
    signal crtc  : crtc_t := (16#0A# => x"0D", 16#0B# => x"0E", others => x"00");
    signal index : std_logic_vector(4 downto 0) := (others => '0');
    signal base  : integer range 0 to VRAM_SIZE - 4;
begin
    base <= to_integer(unsigned(mem_addr(11 downto 2))) * 4;

    -- Combinational little-endian dword read (any read is side-effect free).
    mem_dout <= vram(base + 3) & vram(base + 2) & vram(base + 1) & vram(base);

    io_dout <= "000" & index when cs_index = '1' else crtc(to_integer(unsigned(index)));
    cursor  <= crtc(16#0E#) & crtc(16#0F#);

    process(clk)
    begin
        if rising_edge(clk) then
            if mem_cs = '1' and mem_we = '1' then
                for i in 0 to 3 loop
                    if mem_be(i) = '1' then
                        vram(base + i) <= mem_din(8 * i + 7 downto 8 * i);
                    end if;
                end loop;
            end if;
            if reset = '1' then
                index <= (others => '0');
            elsif io_wr = '1' and cs_index = '1' then
                index <= io_din(4 downto 0);
            elsif io_wr = '1' and cs_data = '1' then
                crtc(to_integer(unsigned(index))) <= io_din;
            end if;
        end if;
    end process;

    text_proc : process(vram)
        variable c : std_logic_vector(7 downto 0);
        variable k : integer;
    begin
        for i in 0 to 25 * 80 - 1 loop
            c := vram(2 * i);
            if unsigned(c) < 32 or unsigned(c) > 126 then c := x"20"; end if;
            k := 25 * 80 - 1 - i;
            text(8 * k + 7 downto 8 * k) <= c;
        end loop;
    end process;
end behavioral;
