--------------------------------------------------------------------------------
-- ata_disk : an IDE/ATA hard disk on the PC's PRIMARY channel, PIO mode.
--
-- Addressing is LBA ONLY (28-bit Logical Block Address = sector number 0..N-1).
-- There is no cylinder/head/sector geometry: IDENTIFY reports none, and a
-- command issued with the L bit of 0x1F6 clear (CHS mode) is aborted (ABRT).
--
-- Task-file registers (the real PC/AT ports):
--   0x1F0  data       16-bit sector data (256 words = one 512-byte sector)
--   0x1F1  error (r)  bit2 ABRT command aborted, bit4 IDNF sector not found
--          features (w)
--   0x1F2  sector count (0 means 256)
--   0x1F3  LBA bits  7:0
--   0x1F4  LBA bits 15:8
--   0x1F5  LBA bits 23:16
--   0x1F6  drive/LBA: 1 L 1 DEV LBA[27:24] -> 0xE0 | LBA[27:24] = master, LBA
--          (L must be 1; DEV 0 = master, the only drive present)
--   0x1F7  status (r): BSY 0x80, DRDY 0x40, DF 0x20, DSC 0x10, DRQ 0x08, ERR 0x01
--          command (w): 0x20 READ SECTORS, 0x30 WRITE SECTORS,
--                       0xEC IDENTIFY DEVICE, 0xE7 FLUSH CACHE
--   0x3F6  alternate status (r: same as status, but does NOT clear INTRQ)
--          device control (w): bit1 nIEN (1 = no interrupts), bit2 SRST
--
-- PIO protocol, as a real drive does it:
--   READ : write the task file, write 0x20 -> BSY for BUSY_CYCLES while the
--          "platters" are read -> DRQ=1 (and INTRQ if nIEN=0) -> the host reads
--          256 words from 0x1F0 -> next sector (BSY again) or done (DRDY).
--   WRITE: write 0x30 -> DRQ=1 almost at once (no interrupt for the first
--          sector) -> host writes 256 words -> BSY while the sector is written
--          -> INTRQ -> next sector's DRQ, or done.
--   Reading 0x1F7 acknowledges (clears) INTRQ; reading 0x3F6 does not.
-- INTRQ is the IRQ14 line (slave 8259, input 6).
--
-- The data port is 16 bits wide (IN AX, DX). A 32-bit access transfers two
-- words at once, like the "32-bit PIO" mode of PCI IDE controllers.
--
-- The disk contents come from DISK_FILE (one hex byte per line, same format as
-- the RAM image; built from a NASM source). When `dump` rises the whole disk
-- is written to DISK_OUT so writes can be checked. Only the master drive
-- exists; with DEV=1 (slave) selected every register reads 0x00.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity ata_disk is
    generic (
        DISK_FILE   : string  := "";
        DISK_OUT    : string  := "";
        SECTORS     : integer := 16;      -- disk size in 512-byte sectors
        BUSY_CYCLES : integer := 60       -- time to read/write one sector
    );
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        cs_cmd   : in  std_logic;                       -- 0x1F0..0x1F7
        cs_ctl   : in  std_logic;                       -- 0x3F6
        reg      : in  std_logic_vector(2 downto 0);    -- port bits 2:0
        rd       : in  std_logic;
        wr       : in  std_logic;
        size     : in  std_logic_vector(1 downto 0);    -- 00 byte, 01 word, 10 dword
        din      : in  std_logic_vector(31 downto 0);
        dout     : out std_logic_vector(31 downto 0);
        intrq    : out std_logic;                       -- IRQ14
        dump     : in  std_logic := '0';                -- write DISK_OUT
        -- debug taps
        dbg_status : out std_logic_vector(7 downto 0);
        dbg_lba    : out std_logic_vector(27 downto 0);
        dbg_word   : out std_logic_vector(8 downto 0);  -- word index in the sector
        dbg_phase  : out std_logic_vector(8*8 - 1 downto 0)  -- ASCII phase name
    );
end ata_disk;

architecture behavioral of ata_disk is
    constant DISK_BYTES : integer := SECTORS * 512;
    type bytes_t is array (natural range <>) of std_logic_vector(7 downto 0);
    subtype sector_t is bytes_t(0 to 511);

    type phase_t is (P_IDLE, P_BUSY_RD, P_DRQ_RD, P_BUSY_PRE, P_DRQ_WR, P_BUSY_WR, P_BUSY_CMD);
    signal phase : phase_t := P_IDLE;

    signal buf      : sector_t := (others => (others => '0'));  -- sector buffer
    signal widx     : integer range 0 to 256 := 0;              -- word index
    signal cnt      : integer range 0 to BUSY_CYCLES := 0;
    signal remain   : integer range 0 to 256 := 0;              -- sectors left
    signal cur_lba  : integer range 0 to 2**28 - 1 := 0;
    signal is_ident : std_logic := '0';

    signal err_r, feat, nsect, lba0, lba1, lba2 : std_logic_vector(7 downto 0) := (others => '0');
    signal devhead  : std_logic_vector(7 downto 0) := x"E0";
    signal nien, srst : std_logic := '0';
    signal bsy, drq, err, irq : std_logic := '0';
    signal status   : std_logic_vector(7 downto 0);
    signal slave    : std_logic;

    function pname(s : string) return std_logic_vector is
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

    -- IDENTIFY DEVICE data. ATA strings put the FIRST character of each pair
    -- in the HIGH byte of the word (so a little-endian dump looks byte-swapped).
    impure function identify_data return sector_t is
        variable d : sector_t := (others => x"00");
        constant MODEL  : string := "SimpleComputer32 Teaching Disk          ";  -- 40 chars
        constant SERIAL : string := "SC32-0001           ";                      -- 20 chars
        constant FW     : string := "1.0     ";                                  -- 8 chars
        procedure word(w : integer; v : integer) is
        begin
            d(2 * w)     := std_logic_vector(to_unsigned(v mod 256, 8));
            d(2 * w + 1) := std_logic_vector(to_unsigned((v / 256) mod 256, 8));
        end procedure;
        procedure str(w0 : integer; s : string) is
        begin
            for i in 0 to s'length / 2 - 1 loop
                d(2 * (w0 + i) + 1) := std_logic_vector(to_unsigned(character'pos(s(s'low + 2 * i)), 8));
                d(2 * (w0 + i))     := std_logic_vector(to_unsigned(character'pos(s(s'low + 2 * i + 1)), 8));
            end loop;
        end procedure;
    begin
        word(0, 16#0040#);            -- fixed (non-removable) ATA device
        -- words 1/3/6 (CHS geometry) stay 0: this drive is LBA-only
        str(10, SERIAL);              -- words 10-19
        str(23, FW);                  -- words 23-26
        str(27, MODEL);               -- words 27-46
        word(47, 16#8001#);           -- READ/WRITE MULTIPLE: 1 sector
        word(49, 16#0200#);           -- LBA supported
        word(53, 16#0001#);
        word(60, SECTORS mod 65536);  -- total LBA28 sectors (low word)
        word(61, SECTORS / 65536);    -- (high word)
        return d;
    end function;

    impure function load_disk(fname : string) return bytes_t is
        variable d    : bytes_t(0 to DISK_BYTES - 1) := (others => x"00");
        file     f    : text;
        variable st   : file_open_status;
        variable l    : line;
        variable b    : std_logic_vector(7 downto 0);
        variable good : boolean;
        variable i    : integer := 0;
    begin
        if fname'length = 0 then return d; end if;
        file_open(st, f, fname, read_mode);
        if st /= open_ok then
            report "ata_disk: could not open '" & fname & "', disk is blank" severity warning;
            return d;
        end if;
        while not endfile(f) and i < DISK_BYTES loop
            readline(f, l);
            hread(l, b, good);
            if good then d(i) := b; i := i + 1; end if;
        end loop;
        file_close(f);
        return d;
    end function;
begin
    slave  <= devhead(4);
    status <= x"00" when slave = '1' else
              bsy & (not bsy) & '0' & (not bsy) & drq & "00" & err;
    intrq  <= irq and not nien;

    -- Register reads (combinational). The data port returns the next word(s).
    read_mux : process(all)
        variable w0, w1 : std_logic_vector(15 downto 0);
    begin
        dout <= (others => '0');
        if widx < 256 then w0 := buf(2 * widx + 1) & buf(2 * widx); else w0 := (others => '0'); end if;
        if widx < 255 then w1 := buf(2 * widx + 3) & buf(2 * widx + 2); else w1 := (others => '0'); end if;
        if cs_ctl = '1' then
            dout(7 downto 0) <= status;                       -- alternate status
        elsif slave = '1' then
            null;                                             -- no slave drive: 0x00
        else
            case reg is
                when "000" =>
                    if size = "10" then dout <= w1 & w0;
                    else dout(15 downto 0) <= w0; end if;
                when "001" => dout(7 downto 0) <= err_r;
                when "010" => dout(7 downto 0) <= nsect;
                when "011" => dout(7 downto 0) <= lba0;
                when "100" => dout(7 downto 0) <= lba1;
                when "101" => dout(7 downto 0) <= lba2;
                when "110" => dout(7 downto 0) <= devhead;
                when others => dout(7 downto 0) <= status;
            end case;
        end if;
    end process;

    main : process(clk)
        variable disk  : bytes_t(0 to DISK_BYTES - 1) := load_disk(DISK_FILE);
        variable lba   : integer;
        variable n     : integer;
        variable step  : integer;
        file     fo    : text;
        variable lo    : line;
        variable st    : file_open_status;
        variable dumped : boolean := false;

        procedure fail(code : std_logic_vector(7 downto 0)) is
        begin
            err <= '1'; err_r <= code; drq <= '0'; bsy <= '0';
            irq <= '1'; phase <= P_IDLE;
        end procedure;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                phase <= P_IDLE; widx <= 0; cnt <= 0; remain <= 0;
                err_r <= x"01"; feat <= x"00"; nsect <= x"01";
                lba0 <= x"00"; lba1 <= x"00"; lba2 <= x"00"; devhead <= x"E0";
                nien <= '0'; srst <= '0'; bsy <= '0'; drq <= '0'; err <= '0'; irq <= '0';
            else
                -- 32-bit data access moves two words.
                if size = "10" then step := 2; else step := 1; end if;

                ---------------- host writes ----------------
                if wr = '1' and cs_ctl = '1' then
                    nien <= din(1);
                    srst <= din(2);
                    if din(2) = '1' then                      -- soft reset asserted
                        phase <= P_IDLE; bsy <= '1'; drq <= '0'; err <= '0';
                    elsif srst = '1' then                     -- ... released
                        bsy <= '0'; err_r <= x"01";           -- diagnostic: no error
                    end if;
                elsif wr = '1' and cs_cmd = '1' and slave = '0' then
                    case reg is
                        when "000" =>                         -- data
                            if phase = P_DRQ_WR then
                                buf(2 * widx)     <= din(7 downto 0);
                                buf(2 * widx + 1) <= din(15 downto 8);
                                if step = 2 and widx < 255 then
                                    buf(2 * widx + 2) <= din(23 downto 16);
                                    buf(2 * widx + 3) <= din(31 downto 24);
                                end if;
                                if widx + step >= 256 then
                                    widx <= 256; drq <= '0'; bsy <= '1';
                                    cnt <= BUSY_CYCLES; phase <= P_BUSY_WR;
                                else
                                    widx <= widx + step;
                                end if;
                            end if;
                        when "001" => feat  <= din(7 downto 0);
                        when "010" => nsect <= din(7 downto 0);
                        when "011" => lba0  <= din(7 downto 0);
                        when "100" => lba1  <= din(7 downto 0);
                        when "101" => lba2  <= din(7 downto 0);
                        when "110" => devhead <= din(7 downto 0);
                        when others =>                        -- command
                            irq <= '0'; err <= '0'; err_r <= x"00";
                            lba := to_integer(unsigned(std_logic_vector'(devhead(3 downto 0) & lba2 & lba1 & lba0)));
                            n := to_integer(unsigned(nsect));
                            if n = 0 then n := 256; end if;
                            is_ident <= '0';
                            case din(7 downto 0) is
                                when x"20" | x"21" =>         -- READ SECTORS
                                    if devhead(6) = '0' then
                                        fail(x"04");          -- CHS addressing: not supported (ABRT)
                                    elsif lba + n > SECTORS then
                                        fail(x"10");          -- beyond the last sector (IDNF)
                                    else
                                        cur_lba <= lba; remain <= n;
                                        bsy <= '1'; drq <= '0';
                                        cnt <= BUSY_CYCLES; phase <= P_BUSY_RD;
                                    end if;
                                when x"30" | x"31" =>         -- WRITE SECTORS
                                    if devhead(6) = '0' then
                                        fail(x"04");          -- CHS addressing: ABRT
                                    elsif lba + n > SECTORS then
                                        fail(x"10");          -- IDNF
                                    else
                                        cur_lba <= lba; remain <= n;
                                        bsy <= '1'; drq <= '0';
                                        cnt <= 4; phase <= P_BUSY_PRE;
                                    end if;
                                when x"EC" =>                 -- IDENTIFY DEVICE
                                    is_ident <= '1'; remain <= 1;
                                    bsy <= '1'; drq <= '0';
                                    cnt <= BUSY_CYCLES; phase <= P_BUSY_RD;
                                when x"E7" =>                 -- FLUSH CACHE
                                    bsy <= '1'; cnt <= BUSY_CYCLES; phase <= P_BUSY_CMD;
                                when others =>
                                    fail(x"04");              -- ABRT
                            end case;
                    end case;
                end if;

                ---------------- host reads ----------------
                if rd = '1' and cs_cmd = '1' and slave = '0' then
                    if reg = "111" then
                        irq <= '0';                           -- status read acks INTRQ
                    elsif reg = "000" and phase = P_DRQ_RD then
                        if widx + step >= 256 then            -- sector drained
                            widx <= 256; drq <= '0';
                            if remain > 1 then
                                remain <= remain - 1; cur_lba <= cur_lba + 1;
                                bsy <= '1'; cnt <= BUSY_CYCLES; phase <= P_BUSY_RD;
                            else
                                remain <= 0; phase <= P_IDLE;
                            end if;
                        else
                            widx <= widx + step;
                        end if;
                    end if;
                end if;

                ---------------- drive timing ----------------
                case phase is
                    when P_BUSY_RD =>
                        if cnt = 0 then
                            if is_ident = '1' then
                                buf <= identify_data;
                            else
                                for i in 0 to 511 loop buf(i) <= disk(cur_lba * 512 + i); end loop;
                            end if;
                            widx <= 0; bsy <= '0'; drq <= '1'; irq <= '1';
                            phase <= P_DRQ_RD;
                        else
                            cnt <= cnt - 1;
                        end if;
                    when P_BUSY_PRE =>                        -- ready for the first sector
                        if cnt = 0 then
                            widx <= 0; bsy <= '0'; drq <= '1'; phase <= P_DRQ_WR;
                        else
                            cnt <= cnt - 1;
                        end if;
                    when P_BUSY_WR =>                         -- commit the sector
                        if cnt = 0 then
                            for i in 0 to 511 loop disk(cur_lba * 512 + i) := buf(i); end loop;
                            bsy <= '0'; irq <= '1';
                            if remain > 1 then
                                remain <= remain - 1; cur_lba <= cur_lba + 1;
                                widx <= 0; drq <= '1'; phase <= P_DRQ_WR;
                            else
                                remain <= 0; phase <= P_IDLE;
                            end if;
                        else
                            cnt <= cnt - 1;
                        end if;
                    when P_BUSY_CMD =>
                        if cnt = 0 then bsy <= '0'; irq <= '1'; phase <= P_IDLE;
                        else cnt <= cnt - 1; end if;
                    when others => null;
                end case;
            end if;

            -- End of simulation: save the disk image.
            if dump = '1' and not dumped and DISK_OUT'length > 0 then
                dumped := true;
                file_open(st, fo, DISK_OUT, write_mode);
                if st = open_ok then
                    for i in 0 to DISK_BYTES - 1 loop
                        hwrite(lo, disk(i));
                        writeline(fo, lo);
                    end loop;
                    file_close(fo);
                end if;
            end if;
        end if;
    end process;

    dbg_status <= status;
    dbg_lba    <= std_logic_vector(to_unsigned(cur_lba, 28));
    dbg_word   <= std_logic_vector(to_unsigned(widx, 9));
    with phase select dbg_phase <=
        pname("IDLE")     when P_IDLE,
        pname("BSY_READ") when P_BUSY_RD,
        pname("DRQ_READ") when P_DRQ_RD,
        pname("BSY_PRE")  when P_BUSY_PRE,
        pname("DRQ_WRIT") when P_DRQ_WR,
        pname("BSY_WRIT") when P_BUSY_WR,
        pname("BSY_CMD")  when P_BUSY_CMD;
end behavioral;
