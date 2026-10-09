--------------------------------------------------------------------------------
-- kbd_8042 : the PC/AT keyboard controller (Intel 8042) + keyboard.
--
-- Ports (the real PC addresses):
--   0x60 read   data: the next byte from the keyboard (a SCAN CODE, set 1 --
--               what a PC delivers at port 0x60 with translation on). Reading
--               it empties the output buffer (clears OBF).
--   0x60 write  a byte for the keyboard (or the command byte after 0x64<-0x60)
--   0x64 read   status register:
--                 bit0 OBF  output buffer full (a byte is waiting at 0x60)
--                 bit1 IBF  input buffer full (always 0: we accept at once)
--                 bit2 SYS  system flag (from the command byte)
--                 bit3 C/D  last write went to 0x64 (command) not 0x60 (data)
--                 bit4 INH  1 = keyboard NOT inhibited
--   0x64 write  controller command:
--                 0x20 read command byte -> 0x60     0x60 next 0x60 write = command byte
--                 0xAA self test -> 0x55             0xAB keyboard interface test -> 0x00
--                 0xAD disable keyboard              0xAE enable keyboard
--
-- Command byte (reset 0x45, the value a BIOS leaves): bit0 = raise IRQ1 when
-- OBF is set, bit2 = SYS, bit4 = keyboard disabled, bit6 = translate to set 1.
--
-- IRQ1 = OBF and command-byte bit0. It stays high until the CPU reads 0x60,
-- then the next queued byte arrives XFER_CYCLES later (a new rising edge for
-- the edge-triggered 8259).
--
-- Key presses come from the testbench (live terminal or a key script) on
-- key_valid/key_code into a 16-byte FIFO -- the keyboard's own buffer -- and
-- are moved one at a time into the controller's single-byte output buffer.
-- Bytes written to 0x60 are keyboard commands: the keyboard answers 0xFA (ACK);
-- 0xEE (echo) answers 0xEE; 0xFF (reset) answers 0xFA then 0xAA (self-test OK).
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity kbd_8042 is
    generic (
        XFER_CYCLES : integer := 40     -- keyboard -> controller serial transfer time
    );
    port (
        clk       : in  std_logic;
        reset     : in  std_logic;
        -- CPU I/O bus
        cs_data   : in  std_logic;                     -- port 0x60
        cs_cmd    : in  std_logic;                     -- port 0x64
        rd        : in  std_logic;
        wr        : in  std_logic;
        din       : in  std_logic_vector(7 downto 0);
        dout      : out std_logic_vector(7 downto 0);
        irq1      : out std_logic;
        -- key input (from the testbench / host terminal)
        key_valid : in  std_logic;
        key_code  : in  std_logic_vector(7 downto 0);
        fifo_full : out std_logic;
        idle      : out std_logic;                     -- nothing queued or waiting
        -- debug taps
        dbg_status : out std_logic_vector(7 downto 0);
        dbg_outbuf : out std_logic_vector(7 downto 0)
    );
end kbd_8042;

architecture behavioral of kbd_8042 is
    constant DEPTH : integer := 16;
    type fifo_t is array (0 to DEPTH - 1) of std_logic_vector(7 downto 0);
    signal fifo   : fifo_t := (others => (others => '0'));
    signal head, tail : integer range 0 to DEPTH - 1 := 0;
    signal count  : integer range 0 to DEPTH := 0;

    signal outbuf : std_logic_vector(7 downto 0) := (others => '0');
    signal obf    : std_logic := '0';
    signal ccb    : std_logic_vector(7 downto 0) := x"45";   -- command byte
    signal want_ccb : std_logic := '0';                      -- next 0x60 write is the CCB
    signal last_cmd : std_logic := '0';                      -- status bit3 (C/D)
    signal xfer   : integer range 0 to XFER_CYCLES := 0;
    signal status : std_logic_vector(7 downto 0);
begin
    status <= "000" & '1' & last_cmd & ccb(2) & '0' & obf;
    dout   <= status when cs_cmd = '1' else outbuf;
    irq1   <= obf and ccb(0);
    fifo_full <= '1' when count >= DEPTH - 2 else '0';      -- room for a command reply
    idle   <= '1' when count = 0 and obf = '0' else '0';

    process(clk, reset)
        variable c    : integer range 0 to DEPTH;
        variable t    : integer range 0 to DEPTH - 1;
        variable h    : integer range 0 to DEPTH - 1;

        -- queue a byte from the keyboard side
        procedure push(b : std_logic_vector(7 downto 0)) is
        begin
            if c < DEPTH then
                fifo(t) <= b;
                t := (t + 1) mod DEPTH;
                c := c + 1;
            end if;
        end procedure;
    begin
        if reset = '1' then
            head <= 0; tail <= 0; count <= 0;
            outbuf <= (others => '0'); obf <= '0'; ccb <= x"45";
            want_ccb <= '0'; last_cmd <= '0'; xfer <= 0;
        elsif rising_edge(clk) then
            c := count; t := tail; h := head;

            if key_valid = '1' then push(key_code); end if;

            -- CPU reads the data port: the byte is consumed.
            if cs_data = '1' and rd = '1' and obf = '1' then
                obf  <= '0';
                xfer <= XFER_CYCLES;
            elsif xfer > 0 then
                xfer <= xfer - 1;
            end if;

            -- CPU writes.
            if wr = '1' and cs_cmd = '1' then
                last_cmd <= '1';
                case din is
                    when x"20" => outbuf <= ccb;   obf <= '1';
                    when x"60" => want_ccb <= '1';
                    when x"AA" => outbuf <= x"55"; obf <= '1';
                    when x"AB" => outbuf <= x"00"; obf <= '1';
                    when x"AD" => ccb(4) <= '1';
                    when x"AE" => ccb(4) <= '0';
                    when others => null;
                end case;
            elsif wr = '1' and cs_data = '1' then
                last_cmd <= '0';
                if want_ccb = '1' then
                    ccb <= din;
                    want_ccb <= '0';
                elsif din = x"EE" then
                    push(x"EE");                      -- echo
                elsif din = x"FF" then
                    push(x"FA"); push(x"AA");         -- reset: ACK + self-test passed
                else
                    push(x"FA");                      -- ACK (LEDs, typematic, enable...)
                end if;
            end if;

            -- Keyboard -> controller: deliver the next byte once the output
            -- buffer is empty and the previous transfer time has elapsed.
            -- (count, not c: only bytes queued in an earlier cycle are in the FIFO.)
            if obf = '0' and xfer = 0 and count > 0 and ccb(4) = '0'
               and not (cs_data = '1' and rd = '1')
               and not (cs_cmd = '1' and wr = '1') then   -- a controller reply wins
                outbuf <= fifo(h);
                obf <= '1';
                h := (h + 1) mod DEPTH;
                c := c - 1;
            end if;

            head <= h; tail <= t; count <= c;
        end if;
    end process;

    dbg_status <= status;
    dbg_outbuf <= outbuf;
end behavioral;
