--------------------------------------------------------------------------------
-- pic_8259 : Intel 8259A Programmable Interrupt Controller (the PC's PIC).
--
-- The IBM PC/AT has two of them: the MASTER at ports 0x20/0x21 and the SLAVE
-- at 0xA0/0xA1, cascaded on master input IR2. Each one:
--   - latches a rising edge on an IR line into the Interrupt Request Register
--     (IRR) -- edge-triggered mode, the PC default;
--   - masks requests with the Interrupt Mask Register (IMR, port base+1);
--   - raises INT to the CPU when the highest-priority unmasked request has a
--     higher priority than everything in service (fully nested: IR0 highest);
--   - on the CPU's interrupt-acknowledge (INTA) moves that request from IRR to
--     the In-Service Register (ISR) and drives the vector = ICW2 base + IR#;
--   - keeps it in service until the handler writes an End Of Interrupt
--     (EOI: OUT 0x20, 0x20 on the master; slave IRQs need an EOI to both).
--
-- Programming model implemented (what real PC software actually uses):
--   port base+0 write, bit4=1  ICW1  start init (bit0 IC4: ICW4 follows,
--                                    bit1 SNGL: no ICW3). Clears IMR and ISR.
--   port base+1 write (in init) ICW2 vector base (bits 7:3), then ICW3
--                                    (cascade wiring) and ICW4 if requested.
--   port base+1 write            OCW1  IMR (1 = masked)
--   port base+0 write, 00x0_0xxx OCW2  001 = non-specific EOI, 011 = specific EOI
--   port base+0 write, 0xx0_1xxx OCW3  10/11 in bits 1:0 = read IRR/ISR next
--   port base+0 read             IRR (default) or ISR (after OCW3)
--   port base+1 read             IMR
--   INTA with nothing pending    spurious IRQ7 (vector base+7, ISR untouched),
--                                exactly like the real chip.
-- Not modelled: level-triggered mode, AEOI, special mask/fully-nested modes,
-- rotating priority, the two-pulse INTA sequence (one acknowledge cycle here).
--
-- Reset state: vector base = the IBM BIOS default (master 0x08, slave 0x70),
-- all inputs MASKED (IMR = 0xFF) until the program initialises the chip.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity pic_8259 is
    generic (
        RESET_BASE : std_logic_vector(7 downto 0) := x"08"   -- BIOS vector base
    );
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        -- CPU I/O bus (8-bit registers)
        cs       : in  std_logic;                       -- one of our two ports
        a0       : in  std_logic;                       -- port bit 0 (base / base+1)
        rd       : in  std_logic;
        wr       : in  std_logic;
        din      : in  std_logic_vector(7 downto 0);
        dout     : out std_logic_vector(7 downto 0);
        -- interrupt lines and the CPU handshake
        ir       : in  std_logic_vector(7 downto 0);    -- IR0..IR7 request inputs
        int_out  : out std_logic;                       -- INT to the CPU (or master IR)
        inta     : in  std_logic;                       -- acknowledge for THIS chip
        vector   : out std_logic_vector(7 downto 0);    -- vector of the IRQ being acked
        sel_irq  : out integer range 0 to 7;            -- IR# an INTA would acknowledge
        -- debug taps
        dbg_irr  : out std_logic_vector(7 downto 0);
        dbg_isr  : out std_logic_vector(7 downto 0);
        dbg_imr  : out std_logic_vector(7 downto 0)
    );
end pic_8259;

architecture behavioral of pic_8259 is
    type init_t is (READY, WAIT_ICW2, WAIT_ICW3, WAIT_ICW4);
    signal init_st  : init_t := READY;
    signal irr, isr : std_logic_vector(7 downto 0) := (others => '0');
    signal imr      : std_logic_vector(7 downto 0) := (others => '1');
    signal base     : std_logic_vector(7 downto 0) := RESET_BASE;
    signal sngl     : std_logic := '0';                 -- ICW1.SNGL (no cascade)
    signal ic4      : std_logic := '0';                 -- ICW1.IC4  (ICW4 needed)
    signal read_isr : std_logic := '0';                 -- OCW3 read select
    signal ir_prev  : std_logic_vector(7 downto 0) := (others => '0');

    signal pend     : std_logic_vector(7 downto 0);
    signal pend_hi  : integer range 0 to 8;             -- highest-priority pending (8 = none)
    signal isr_hi   : integer range 0 to 8;             -- highest-priority in service
    signal pend_ok  : std_logic;                        -- a request may be delivered

    -- Lowest set bit = highest priority (IR0 is the highest). 8 = none.
    function first_set(v : std_logic_vector(7 downto 0)) return integer is
    begin
        for i in 0 to 7 loop
            if v(i) = '1' then return i; end if;
        end loop;
        return 8;
    end function;
begin
    pend    <= irr and not imr;
    pend_hi <= first_set(pend);
    isr_hi  <= first_set(isr);
    pend_ok <= '1' when pend_hi < isr_hi else '0';      -- higher than anything in service

    int_out <= pend_ok;
    sel_irq <= pend_hi when pend_ok = '1' else 7;
    vector  <= base(7 downto 3) & std_logic_vector(to_unsigned(pend_hi, 3)) when pend_ok = '1'
               else base(7 downto 3) & "111";           -- spurious IRQ7

    dout <= imr when a0 = '1' else
            isr when read_isr = '1' else
            irr;

    process(clk, reset)
        variable n : integer range 0 to 8;
    begin
        if reset = '1' then
            init_st <= READY;
            irr <= (others => '0'); isr <= (others => '0'); imr <= (others => '1');
            base <= RESET_BASE; sngl <= '0'; ic4 <= '0'; read_isr <= '0';
            ir_prev <= (others => '0');
        elsif rising_edge(clk) then
            -- Edge-triggered request latch.
            ir_prev <= ir;
            irr <= irr or (ir and not ir_prev);

            -- Interrupt acknowledge: IRR -> ISR for the selected request.
            if inta = '1' and pend_ok = '1' then
                irr(pend_hi) <= '0';
                isr(pend_hi) <= '1';
            end if;

            if cs = '1' and wr = '1' then
                if a0 = '0' and din(4) = '1' then                  -- ICW1
                    sngl <= din(1); ic4 <= din(0);
                    imr <= (others => '0'); isr <= (others => '0');
                    read_isr <= '0';
                    init_st <= WAIT_ICW2;
                elsif a0 = '1' then
                    case init_st is
                        when WAIT_ICW2 =>                          -- vector base
                            base <= din(7 downto 3) & "000";
                            if sngl = '0' then init_st <= WAIT_ICW3;
                            elsif ic4 = '1' then init_st <= WAIT_ICW4;
                            else init_st <= READY; end if;
                        when WAIT_ICW3 =>                          -- cascade wiring
                            if ic4 = '1' then init_st <= WAIT_ICW4;
                            else init_st <= READY; end if;
                        when WAIT_ICW4 =>                          -- 8086 mode etc.
                            init_st <= READY;
                        when READY =>                              -- OCW1 = IMR
                            imr <= din;
                    end case;
                elsif din(3) = '0' then                            -- OCW2
                    if din(7 downto 5) = "001" then                -- non-specific EOI
                        n := first_set(isr);
                        if n < 8 then isr(n) <= '0'; end if;
                    elsif din(7 downto 5) = "011" then             -- specific EOI
                        isr(to_integer(unsigned(din(2 downto 0)))) <= '0';
                    end if;
                else                                               -- OCW3
                    if din(1) = '1' then read_isr <= din(0); end if;
                end if;
            end if;
        end if;
    end process;

    dbg_irr <= irr;
    dbg_isr <= isr;
    dbg_imr <= imr;
end behavioral;
