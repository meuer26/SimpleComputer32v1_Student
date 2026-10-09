--------------------------------------------------------------------------------
-- pc_chipset : the address decoders of the teaching PC.
--
-- A real x86 has TWO address spaces, told apart by the M/IO# pin:
--
--   MEMORY space (MOV, PUSH, instruction fetch ...)  -- 32-bit addresses
--     0x00000000 .. RAM_SIZE-1   RAM (program, data, stack, vector table)
--     0x000B8000 .. 0x000B8FFF   VGA colour text video RAM (memory-mapped I/O)
--     anything else              nothing answers: reads float to 0xFFFFFFFF,
--                                writes are lost (no aliasing onto RAM)
--
--   I/O space (IN / OUT only)  -- 16-bit port numbers, the IBM PC/AT map:
--     0x0020-0x0021  master 8259 PIC        0x00A0-0x00A1  slave 8259 PIC
--     0x0060         8042 keyboard data     0x0064         8042 status/command
--     0x0080         POST diagnostic code   0x00E9         debug console (Bochs/QEMU)
--     0x01F0-0x01F7  ATA primary task file  0x03F6         ATA alt status/dev control
--     0x03D4-0x03D5  VGA CRTC index/data
--     anything else  no device: reads 0xFF.. (floating ISA bus), writes lost
--
-- 8-bit devices return their byte in bits 7:0 (the rest of the bus floats
-- high), so use the byte forms IN AL / OUT .., AL for them, as real drivers do.
-- The decoders are purely combinational: they only steer chip selects and the
-- read-data multiplexers. The *_name outputs spell out the decision in ASCII
-- for the waveform viewer.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity pc_chipset is
    generic (
        RAM_BITS : integer := 12                         -- RAM size = 2**RAM_BITS
    );
    port (
        -- memory side
        mem_addr   : in  std_logic_vector(31 downto 0);
        mem_req    : in  std_logic;
        ram_dout   : in  std_logic_vector(31 downto 0);
        vram_dout  : in  std_logic_vector(31 downto 0);
        cs_ram     : out std_logic;
        cs_vram    : out std_logic;
        mem_rdata  : out std_logic_vector(31 downto 0);
        mem_name   : out std_logic_vector(8*8 - 1 downto 0);
        -- I/O side
        io_addr    : in  std_logic_vector(15 downto 0);
        io_active  : in  std_logic;                      -- io_re or io_we
        pic1_dout, pic2_dout, kbd_dout, crtc_dout : in std_logic_vector(7 downto 0);
        ata_dout   : in  std_logic_vector(31 downto 0);
        cs_pic1, cs_pic2, cs_kbd_data, cs_kbd_cmd : out std_logic;
        cs_ata, cs_ata_ctl, cs_crtc_idx, cs_crtc_data : out std_logic;
        cs_post, cs_e9 : out std_logic;
        io_rdata   : out std_logic_vector(31 downto 0);
        io_name    : out std_logic_vector(8*8 - 1 downto 0)
    );
end pc_chipset;

architecture rtl of pc_chipset is
    function nm(s : string) return std_logic_vector is
        variable r : std_logic_vector(63 downto 0) := (others => '0');
    begin
        for i in 0 to 7 loop
            if i < s'length then
                r(63 - 8 * i downto 56 - 8 * i) :=
                    std_logic_vector(to_unsigned(character'pos(s(s'low + i)), 8));
            else
                r(63 - 8 * i downto 56 - 8 * i) := x"20";
            end if;
        end loop;
        return r;
    end function;

    signal is_ram, is_vram : boolean;
    signal p : unsigned(15 downto 0);
    signal s_pic1, s_pic2, s_kd, s_kc, s_ata, s_atac, s_ci, s_cd, s_post, s_e9 : boolean;
begin
    ------------------------------------------------------------------ memory
    is_ram  <= unsigned(mem_addr(31 downto RAM_BITS)) = 0;
    is_vram <= mem_addr(31 downto 12) = x"000B8";

    cs_ram    <= '1' when is_ram  else '0';
    cs_vram   <= '1' when is_vram else '0';
    mem_rdata <= ram_dout  when is_ram  else
                 vram_dout when is_vram else
                 (others => '1');                        -- open bus
    mem_name  <= nm("-")    when mem_req = '0' else
                 nm("RAM")  when is_ram  else
                 nm("VRAM") when is_vram else
                 nm("OPENBUS");

    ------------------------------------------------------------------ I/O
    p <= unsigned(io_addr);
    s_pic1 <= p = 16#20# or p = 16#21#;
    s_pic2 <= p = 16#A0# or p = 16#A1#;
    s_kd   <= p = 16#60#;
    s_kc   <= p = 16#64#;
    s_ata  <= p >= 16#1F0# and p <= 16#1F7#;
    s_atac <= p = 16#3F6#;
    s_ci   <= p = 16#3D4#;
    s_cd   <= p = 16#3D5#;
    s_post <= p = 16#80#;
    s_e9   <= p = 16#E9#;

    cs_pic1      <= '1' when s_pic1 else '0';
    cs_pic2      <= '1' when s_pic2 else '0';
    cs_kbd_data  <= '1' when s_kd   else '0';
    cs_kbd_cmd   <= '1' when s_kc   else '0';
    cs_ata       <= '1' when s_ata  else '0';
    cs_ata_ctl   <= '1' when s_atac else '0';
    cs_crtc_idx  <= '1' when s_ci   else '0';
    cs_crtc_data <= '1' when s_cd   else '0';
    cs_post      <= '1' when s_post else '0';
    cs_e9        <= '1' when s_e9   else '0';

    io_rdata <= x"FFFFFF" & pic1_dout when s_pic1 else
                x"FFFFFF" & pic2_dout when s_pic2 else
                x"FFFFFF" & kbd_dout  when s_kd or s_kc else
                x"FFFFFF" & crtc_dout when s_ci or s_cd else
                ata_dout              when s_ata or s_atac else
                x"FFFFFFE9"           when s_e9 else     -- Bochs: port E9 reads back 0xE9
                (others => '1');                         -- no device: floating bus

    io_name <= nm("-")       when io_active = '0' else
               nm("PIC1")    when s_pic1 else
               nm("PIC2")    when s_pic2 else
               nm("KBD")     when s_kd or s_kc else
               nm("ATA")     when s_ata or s_atac else
               nm("CRTC")    when s_ci or s_cd else
               nm("POST")    when s_post else
               nm("DEBUGE9") when s_e9 else
               nm("NONE");
end rtl;
