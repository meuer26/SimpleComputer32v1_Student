--------------------------------------------------------------------------------
-- l1_mesi : the dual-Pentium memory system -- two cores, each with its own
--           SPLIT L1 (instruction + data cache), kept coherent by snooping MESI.
--
-- Generation note: the CORE is the P5 (superscalar + BTB + split caches, per
-- Alpert & Avnon). Glueless two-way SMP -- two cached cores snooping one bus --
-- is a P54C feature (the 0.6um die-shrink that added dual-processor support and
-- the on-chip local APIC to the unchanged P5 core). So this is a P5 core in the
-- P54C dual-processor configuration.
--
-- The faithful Pentium cache organisation (Alpert & Avnon) scaled to the
-- 512-byte world and replicated for the 2-core SMP:
--
--   * Per core, TWO caches: a write-back DATA cache and a read-only
--     INSTRUCTION cache, each 2-way set-associative with 32-byte lines
--     (4 sets x 2 ways x 8 words = 256 B each).  bit: 8 7|6 5|4 3 2|1 0
--                                                     tag |idx | word|byte
--   * The data caches are coherent across the two cores by a snooping MESI
--     protocol over a single serialized system bus:
--        read miss  -> BusRd : another cache holding the line Modified writes
--                      back; the line installs Shared (if the other keeps a
--                      copy) or Exclusive (if not).
--        write miss -> BusRdX: the other cache writes back if Modified, then
--                      INVALIDATES its copy; the line installs Modified.
--        write hit on Shared -> BusUpgr: invalidate the other copy, S->M.
--   * Self-modifying / cross-modifying code: any data write snoops BOTH cores'
--     instruction caches and invalidates a matching line; an instruction fill
--     snoops the data caches so the new code is seen even while it is still
--     dirty in a data cache. (The same snoop that keeps the cores coherent.)
--   * LOCK# is STICKY: a core granted the bus while asserting LOCK# owns it
--     until it releases, so LOCK CMPXCHG is an indivisible read-modify-write.
--
-- The core issues at most one access per cycle (its single bus); cpu_ifetch
-- selects the instruction or data cache, so the two caches share one miss/fill
-- FSM and one path to RAM -- no intra-core I/D arbitration is ever needed.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity l1_mesi is
    generic (
        init_file : string  := "";
        RAM_BITS  : integer := 9;      -- cacheable RAM size = 2**RAM_BITS bytes
                                       -- (9 = 512 B default; the PC uses 12 = 4 KB)
        -- Teaching knobs (default = the real Pentium split L1: 2-way, 4 sets,
        -- 32-byte lines; see the README). N_SETS/N_WAYS/LINE_WORDS must be powers
        -- of two. CACHE_ON=false = no-allocate write-through: every access misses
        -- to memory (0% hit rate), so students can contrast "cache vs no cache".
        N_SETS     : integer := 4;
        N_WAYS     : integer := 2;
        LINE_WORDS : integer := 8;     -- 32-bit words per line (line = 4*LINE_WORDS B)
        CACHE_ON   : boolean := true
    );
    port (
        clk   : in  std_logic;
        reset : in  std_logic;

        -- core 0
        a0_addr   : in  std_logic_vector(31 downto 0);
        a0_din    : in  std_logic_vector(31 downto 0);
        a0_dout   : out std_logic_vector(31 downto 0);
        a0_we     : in  std_logic;
        a0_be     : in  std_logic_vector(3 downto 0) := "1111";
        a0_req    : in  std_logic;
        a0_ifetch : in  std_logic := '0';
        a0_lock   : in  std_logic := '0';
        a0_ready  : out std_logic;

        -- core 1
        a1_addr   : in  std_logic_vector(31 downto 0);
        a1_din    : in  std_logic_vector(31 downto 0);
        a1_dout   : out std_logic_vector(31 downto 0);
        a1_we     : in  std_logic;
        a1_be     : in  std_logic_vector(3 downto 0) := "1111";
        a1_req    : in  std_logic;
        a1_ifetch : in  std_logic := '0';
        a1_lock   : in  std_logic := '0';
        a1_ready  : out std_logic;

        -- Uncacheable MMIO passthrough. A memory access to an address OUTSIDE the
        -- cacheable RAM window (>= 2**RAM_BITS) bypasses the caches entirely and
        -- is forwarded here -- video RAM, device registers, etc. (On real x86
        -- this is the UC memory type; reads/writes go straight to the device,
        -- the cache is neither consulted nor updated.) Left unconnected when all
        -- of the address space is cacheable RAM.
        mmio_addr  : out std_logic_vector(31 downto 0) := (others => '0');
        mmio_wdata : out std_logic_vector(31 downto 0) := (others => '0');
        mmio_rdata : in  std_logic_vector(31 downto 0) := (others => '0');
        mmio_we    : out std_logic := '0';
        mmio_be    : out std_logic_vector(3 downto 0) := "0000";
        mmio_req   : out std_logic := '0';
        mmio_ifetch: out std_logic := '0';
        mmio_ready : in  std_logic := '1';

        -- coherent dump snoop (testbench memory dump)
        snoop_addr : in  std_logic_vector(31 downto 0) := (others => '0');
        snoop_byte : out std_logic_vector(7 downto 0);

        -- debug taps
        dbg_c0_dhits : out std_logic_vector(31 downto 0);
        dbg_c0_dmiss : out std_logic_vector(31 downto 0);
        dbg_c1_dhits : out std_logic_vector(31 downto 0);
        dbg_c1_dmiss : out std_logic_vector(31 downto 0);
        dbg_c0_ihits : out std_logic_vector(31 downto 0);
        dbg_c0_imiss : out std_logic_vector(31 downto 0);
        dbg_c1_ihits : out std_logic_vector(31 downto 0);
        dbg_c1_imiss : out std_logic_vector(31 downto 0);
        dbg_invalidations : out std_logic_vector(31 downto 0);
        dbg_writebacks    : out std_logic_vector(31 downto 0);
        dbg_smc_inval     : out std_logic_vector(31 downto 0);
        dbg_watch_line    : in  std_logic_vector(1 downto 0) := "00";
        dbg_c0_state      : out std_logic_vector(1 downto 0);
        dbg_c1_state      : out std_logic_vector(1 downto 0);
        dbg_grant         : out std_logic_vector(1 downto 0);
        -- Core-0 cache CONTENTS for the viewer: each line's 32 data bytes plus a
        -- metadata byte per line ({state[1:0], tag[5:0]}). Line order is
        -- set-major then way (line = set*WAYS + way), word 0..WORDS-1 within a
        -- line. Widths are the fixed geometry: 4 sets x 2 ways x 8 words x 32b =
        -- 2048 data bits; 4 x 2 lines x 8 metadata bits = 64.
        dbg_dcache : out std_logic_vector(2047 downto 0);
        dbg_icache : out std_logic_vector(2047 downto 0);
        dbg_dmeta  : out std_logic_vector(63 downto 0);
        dbg_imeta  : out std_logic_vector(63 downto 0);
        -- The cache<->RAM bus beat in flight, for the RAM viewer: a line fill /
        -- writeback moves one 32-bit word per cycle over the 32-bit data bus.
        -- dbg_fill_kind: 0 idle, 1 data-read fill, 2 ifetch-read fill, 3 writeback.
        dbg_fill_addr : out std_logic_vector(31 downto 0);
        dbg_fill_kind : out std_logic_vector(1 downto 0)
    );
end l1_mesi;

architecture behavioral of l1_mesi is

    constant SETS  : integer := N_SETS;
    constant WAYS  : integer := N_WAYS;
    constant WORDS : integer := LINE_WORDS;

    function clog2(n : integer) return integer is
        variable r : integer := 0;  variable v : integer := 1;
    begin
        while v < n loop v := v * 2; r := r + 1; end loop;
        return r;                        -- 0 for n = 1
    end function;

    -- Address layout (little-endian word addressing), derived from the geometry:
    --   [1:0] byte | [OFFB-1:2] word in line | [IDXB-1:OFFB] set index | [..:IDXB] tag
    -- Default (8 words, 4 sets): word=[4:2], set=[6:5], tag=[RAM_BITS-1:7].
    constant WBITS : integer := clog2(WORDS);
    constant SBITS : integer := clog2(SETS);
    constant OFFB  : integer := 2 + WBITS;           -- first set-index bit
    constant IDXB  : integer := OFFB + SBITS;         -- first tag bit

    -- The cacheable RAM is 2**RAM_BITS bytes (= 2**(RAM_BITS-2) 32-bit words).
    -- Addresses at/above that are uncacheable MMIO.
    constant TAG_BITS : integer := RAM_BITS - IDXB;
    constant RAM_WORDS : integer := 2 ** (RAM_BITS - 2);

    constant ST_I : std_logic_vector(1 downto 0) := "00";
    constant ST_S : std_logic_vector(1 downto 0) := "01";
    constant ST_E : std_logic_vector(1 downto 0) := "10";
    constant ST_M : std_logic_vector(1 downto 0) := "11";

    -- [core][set][way] cache arrays
    type line_t  is array (0 to WORDS - 1) of std_logic_vector(31 downto 0);
    type dat_t   is array (0 to 1, 0 to SETS - 1, 0 to WAYS - 1) of line_t;
    type tag_t   is array (0 to 1, 0 to SETS - 1, 0 to WAYS - 1) of std_logic_vector(TAG_BITS - 1 downto 0);
    type st_t    is array (0 to 1, 0 to SETS - 1, 0 to WAYS - 1) of std_logic_vector(1 downto 0);
    type age_t   is array (0 to 1, 0 to SETS - 1, 0 to WAYS - 1) of integer range 0 to WAYS - 1;

    -- data cache (MESI state in d_st) and instruction cache (valid in i_v)
    signal d_dat : dat_t;
    signal d_tag : tag_t := (others => (others => (others => (others => '0'))));
    signal d_st  : st_t  := (others => (others => (others => ST_I)));
    signal d_age : age_t;
    signal i_dat : dat_t;
    signal i_tag : tag_t := (others => (others => (others => (others => '0'))));
    signal i_v   : st_t  := (others => (others => (others => ST_I)));   -- only I/valid used
    signal i_age : age_t;

    type ram_t is array (0 to RAM_WORDS - 1) of std_logic_vector(31 downto 0);

    function hexd(c : character) return integer is
    begin
        case c is
            when '0' => return 0;  when '1' => return 1;  when '2' => return 2;
            when '3' => return 3;  when '4' => return 4;  when '5' => return 5;
            when '6' => return 6;  when '7' => return 7;  when '8' => return 8;
            when '9' => return 9;  when 'a'|'A' => return 10; when 'b'|'B' => return 11;
            when 'c'|'C' => return 12; when 'd'|'D' => return 13; when 'e'|'E' => return 14;
            when 'f'|'F' => return 15; when others => return -1;
        end case;
    end function;

    impure function load_ram(fn : string) return ram_t is
        variable r   : ram_t := (others => (others => '0'));
        file f       : text;
        variable st  : file_open_status;
        variable l   : line;
        variable s   : string(1 to 256);
        variable ll, i, d1, d2, bval, idx : integer;
    begin
        if fn'length = 0 then return r; end if;
        file_open(st, f, fn, read_mode);
        if st /= open_ok then
            report "l1_mesi: cannot open '" & fn & "'" severity warning;
            return r;
        end if;
        idx := 0;
        while not endfile(f) and idx < 2 ** RAM_BITS loop
            readline(f, l);
            if l = null then next; end if;
            ll := l.all'length; if ll > 256 then ll := 256; end if;
            for k in 1 to ll loop s(k) := l.all(k); end loop;
            deallocate(l);
            i := 1;
            while i <= ll and (s(i) = ' ' or s(i) = HT) loop i := i + 1; end loop;
            if i > ll then next; end if;
            if s(i) = '#' or s(i) = ';' then next; end if;
            if i + 1 <= ll and s(i) = '0' and (s(i+1) = 'x' or s(i+1) = 'X') then i := i + 2; end if;
            if i > ll then next; end if;
            d1 := hexd(s(i)); if d1 < 0 then next; end if;
            i := i + 1;
            if i <= ll then d2 := hexd(s(i)); else d2 := -1; end if;
            if d2 >= 0 then bval := d1 * 16 + d2; else bval := d1; end if;
            r(idx / 4)(8 * (idx mod 4) + 7 downto 8 * (idx mod 4)) :=
                std_logic_vector(to_unsigned(bval, 8));
            idx := idx + 1;
        end loop;
        file_close(f);
        report "l1_mesi: loaded " & integer'image(idx) & " bytes." severity note;
        return r;
    end function;

    signal ram : ram_t := load_ram(init_file);

    signal c0_dh, c0_dm, c1_dh, c1_dm : unsigned(31 downto 0) := (others => '0');
    signal c0_ih, c0_im, c1_ih, c1_im : unsigned(31 downto 0) := (others => '0');
    signal inval_cnt, wb_cnt, smc_cnt : unsigned(31 downto 0) := (others => '0');

    type ctrl_t is (C_ARB, C_WB, C_FILL, C_SERVE);
    signal cstatem     : ctrl_t := C_ARB;
    signal serving     : integer range 0 to 1 := 0;
    signal last_served : integer range 0 to 1 := 1;
    signal locker      : integer range 0 to 2 := 2;    -- sticky LOCK# owner (2 = none)

    -- latched in-flight miss
    signal f_core   : integer range 0 to 1 := 0;
    signal f_ifetch : std_logic := '0';
    signal f_we     : std_logic := '0';
    signal f_addr   : std_logic_vector(31 downto 0) := (others => '0');
    signal f_din    : std_logic_vector(31 downto 0) := (others => '0');
    signal f_be     : std_logic_vector(3 downto 0) := "1111";
    signal f_victim : integer range 0 to WAYS - 1 := 0;
    signal burst_w  : integer range 0 to WORDS - 1 := 0;   -- current line-fill/writeback beat

    -- Null slices (e.g. SETS=1 -> SBITS=0) make to_integer return 0, so these
    -- stay correct at the degenerate geometries used for the "no cache" knob.
    function set_of(a : std_logic_vector(31 downto 0)) return integer is
    begin return to_integer(unsigned(a(IDXB - 1 downto OFFB))); end function;
    function tag_of(a : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin return a(RAM_BITS - 1 downto IDXB); end function;
    function word_of(a : std_logic_vector(31 downto 0)) return integer is
    begin return to_integer(unsigned(a(OFFB - 1 downto 2))); end function;
    function ramword(tg : std_logic_vector(TAG_BITS - 1 downto 0); se : integer; w : integer) return integer is
    begin return to_integer(unsigned(tg)) * (SETS * WORDS) + se * WORDS + w; end function;
    -- Uncacheable: an address outside the cacheable RAM window (>= 2**RAM_BITS).
    function is_uc(a : std_logic_vector(31 downto 0)) return boolean is
    begin return unsigned(a(31 downto RAM_BITS)) /= 0; end function;

    -- combinational per-core hit (on the cache its current access selects)
    signal h0, h1 : std_logic;
    signal w0, w1 : integer range 0 to WAYS - 1;
    signal sv_hit : std_logic;
    signal uc0, uc1 : boolean;       -- each core's current access is uncacheable

    -- combinational hit lookup for a given core on a given (ifetch) cache
    procedure lookup(signal dtag : in tag_t; signal dst : in st_t;
                     signal itag : in tag_t; signal iv : in st_t;
                     core : in integer; a : in std_logic_vector(31 downto 0); ifetch : in std_logic;
                     hit : out std_logic; way : out integer) is
        variable h : std_logic := '0';
        variable wv : integer range 0 to WAYS - 1 := 0;
        variable se : integer;
        variable tg : std_logic_vector(TAG_BITS - 1 downto 0);
    begin
        -- A parked/just-woken core can drive a metavalue address for a cycle;
        -- report "miss" rather than compare metavalue tags (this lookup runs
        -- combinationally every cycle for both cores).
        if is_x(a) then hit := '0'; way := 0; return; end if;
        if not CACHE_ON then hit := '0'; way := 0; return; end if;  -- no-cache: always miss
        se := set_of(a); tg := tag_of(a);
        for k in 0 to WAYS - 1 loop
            if ifetch = '1' then
                if iv(core, se, k) /= ST_I and itag(core, se, k) = tg then h := '1'; wv := k; end if;
            else
                if dst(core, se, k) /= ST_I and dtag(core, se, k) = tg then h := '1'; wv := k; end if;
            end if;
        end loop;
        hit := h; way := wv;
    end procedure;

begin

    ----------------------------------------------------------------------------
    -- Sticky LOCK# ownership (clocked).
    ----------------------------------------------------------------------------
    lock_track : process(clk, reset)
    begin
        if reset = '1' then
            locker <= 2;
        elsif rising_edge(clk) then
            if locker = 0 then
                if a0_lock = '0' then locker <= 2; end if;
            elsif locker = 1 then
                if a1_lock = '0' then locker <= 2; end if;
            else
                if serving = 0 and a0_lock = '1' then locker <= 0;
                elsif serving = 1 and a1_lock = '1' then locker <= 1;
                end if;
            end if;
        end if;
    end process;

    -- Arbitration (combinational): held LOCK# wins, then a new LOCK#, then RR.
    arb : process(a0_req, a1_req, a0_lock, a1_lock, last_served, locker)
    begin
        if locker = 0 then serving <= 0;
        elsif locker = 1 then serving <= 1;
        elsif a0_lock = '1' then serving <= 0;
        elsif a1_lock = '1' then serving <= 1;
        elsif a0_req = '1' and a1_req = '1' then
            if last_served = 0 then serving <= 1; else serving <= 0; end if;
        elsif a0_req = '1' then serving <= 0;
        elsif a1_req = '1' then serving <= 1;
        else serving <= last_served; end if;
    end process;

    -- Per-core hit detection + read data.
    hit_proc : process(all)
        variable hh : std_logic; variable ww : integer range 0 to WAYS - 1;
    begin
        lookup(d_tag, d_st, i_tag, i_v, 0, a0_addr, a0_ifetch, hh, ww); h0 <= hh; w0 <= ww;
        lookup(d_tag, d_st, i_tag, i_v, 1, a1_addr, a1_ifetch, hh, ww); h1 <= hh; w1 <= ww;
    end process;
    sv_hit <= h0 when serving = 0 else h1;
    uc0 <= is_uc(a0_addr);
    uc1 <= is_uc(a1_addr);

    -- Read data: an uncacheable access returns the MMIO device's data; a
    -- cacheable access returns the selected cache's word.
    a0_dout <= mmio_rdata when uc0
          else i_dat(0, set_of(a0_addr), w0)(word_of(a0_addr)) when a0_ifetch = '1'
          else d_dat(0, set_of(a0_addr), w0)(word_of(a0_addr));
    a1_dout <= mmio_rdata when uc1
          else i_dat(1, set_of(a1_addr), w1)(word_of(a1_addr)) when a1_ifetch = '1'
          else d_dat(1, set_of(a1_addr), w1)(word_of(a1_addr));

    -- Ready: a cacheable hit completes in C_ARB, a cacheable miss in C_SERVE,
    -- and an uncacheable access completes in C_ARB when the device is ready.
    a0_ready <= '1' when (a0_req = '0') or
                         (cstatem = C_ARB and serving = 0 and
                            ((uc0 and mmio_ready = '1') or ((not uc0) and h0 = '1'))) or
                         (cstatem = C_SERVE and f_core = 0) else '0';
    a1_ready <= '1' when (a1_req = '0') or
                         (cstatem = C_ARB and serving = 1 and
                            ((uc1 and mmio_ready = '1') or ((not uc1) and h1 = '1'))) or
                         (cstatem = C_SERVE and f_core = 1) else '0';

    -- MMIO passthrough driver: when the served core's current access is
    -- uncacheable, forward it to the external device port (combinational).
    mmio_drv : process(all)
    begin
        mmio_req <= '0'; mmio_we <= '0'; mmio_ifetch <= '0';
        mmio_addr <= (others => '0'); mmio_wdata <= (others => '0'); mmio_be <= "0000";
        if cstatem = C_ARB then
            if serving = 0 and a0_req = '1' and uc0 then
                mmio_req <= '1'; mmio_addr <= a0_addr; mmio_we <= a0_we;
                mmio_wdata <= a0_din; mmio_be <= a0_be; mmio_ifetch <= a0_ifetch;
            elsif serving = 1 and a1_req = '1' and uc1 then
                mmio_req <= '1'; mmio_addr <= a1_addr; mmio_we <= a1_we;
                mmio_wdata <= a1_din; mmio_be <= a1_be; mmio_ifetch <= a1_ifetch;
            end if;
        end if;
    end process;

    dbg_grant <= std_logic_vector(to_unsigned(serving, 2));

    ----------------------------------------------------------------------------
    -- Coherence controller + array updates (clocked).
    ----------------------------------------------------------------------------
    process(clk, reset)
        variable i, j, se, wd, vic : integer;
        variable tg  : std_logic_vector(TAG_BITS - 1 downto 0);
        variable we, ifz : std_logic;
        variable din : std_logic_vector(31 downto 0);
        variable be  : std_logic_vector(3 downto 0);
        variable req : std_logic;
        variable a   : std_logic_vector(31 downto 0);
        variable hit : std_logic;
        variable hw  : integer range 0 to WAYS - 1;
        variable got_inv : boolean;
        variable oa  : integer range 0 to WAYS - 1;
        variable dj_hit, di_hit : std_logic;
        variable dj_way, di_way : integer range 0 to WAYS - 1;
        variable mw  : std_logic_vector(31 downto 0);   -- merged store word (no-cache write-through)

        -- LRU touch (data cache)
        procedure touch_d(c, s2, wy : integer) is
            variable og : integer range 0 to WAYS - 1;
        begin
            og := d_age(c, s2, wy);
            for k in 0 to WAYS - 1 loop
                if k = wy then d_age(c, s2, k) <= 0;
                elsif d_age(c, s2, k) < og then d_age(c, s2, k) <= d_age(c, s2, k) + 1; end if;
            end loop;
        end procedure;
        procedure touch_i(c, s2, wy : integer) is
            variable og : integer range 0 to WAYS - 1;
        begin
            og := i_age(c, s2, wy);
            for k in 0 to WAYS - 1 loop
                if k = wy then i_age(c, s2, k) <= 0;
                elsif i_age(c, s2, k) < og then i_age(c, s2, k) <= i_age(c, s2, k) + 1; end if;
            end loop;
        end procedure;

        -- invalidate a matching instruction-cache line in BOTH cores (SMC)
        procedure smc_snoop(s2 : integer; tgv : std_logic_vector(TAG_BITS - 1 downto 0)) is
            variable did : boolean := false;
        begin
            for c in 0 to 1 loop
                for k in 0 to WAYS - 1 loop
                    if i_v(c, s2, k) /= ST_I and i_tag(c, s2, k) = tgv then
                        i_v(c, s2, k) <= ST_I; did := true;
                    end if;
                end loop;
            end loop;
            if did then smc_cnt <= smc_cnt + 1; end if;
        end procedure;
    begin
        if reset = '1' then
            d_st <= (others => (others => (others => ST_I)));
            i_v  <= (others => (others => (others => ST_I)));
            d_tag <= (others => (others => (others => (others => '0'))));
            i_tag <= (others => (others => (others => (others => '0'))));
            for c in 0 to 1 loop
                for s2 in 0 to SETS - 1 loop
                    for k in 0 to WAYS - 1 loop
                        d_age(c, s2, k) <= k; i_age(c, s2, k) <= k;
                    end loop;
                end loop;
            end loop;
            cstatem <= C_ARB; last_served <= 1;
            c0_dh <= (others=>'0'); c0_dm <= (others=>'0'); c1_dh <= (others=>'0'); c1_dm <= (others=>'0');
            c0_ih <= (others=>'0'); c0_im <= (others=>'0'); c1_ih <= (others=>'0'); c1_im <= (others=>'0');
            inval_cnt <= (others=>'0'); wb_cnt <= (others=>'0'); smc_cnt <= (others=>'0');

        elsif rising_edge(clk) then
            case cstatem is

                when C_ARB =>
                    i := serving;  j := 1 - serving;
                    if i = 0 then
                        req := a0_req; we := a0_we; din := a0_din; a := a0_addr; be := a0_be; ifz := a0_ifetch;
                    else
                        req := a1_req; we := a1_we; din := a1_din; a := a1_addr; be := a1_be; ifz := a1_ifetch;
                    end if;
                    se := set_of(a); tg := tag_of(a); wd := word_of(a);
                    if i = 0 then hit := h0; hw := w0; else hit := h1; hw := w1; end if;

                    if req = '1' then
                        if is_uc(a) then
                            ------------------------------------------ UNCACHEABLE
                            -- The mmio driver forwards this access combinationally;
                            -- nothing in the caches changes. Advance round-robin
                            -- once the device accepts it.
                            if mmio_ready = '1' then last_served <= i; end if;
                        elsif hit = '1' then
                            --------------------------------------------- HIT
                            last_served <= i;
                            if ifz = '1' then
                                if i = 0 then c0_ih <= c0_ih + 1; else c1_ih <= c1_ih + 1; end if;
                                touch_i(i, se, hw);
                            else
                                if i = 0 then c0_dh <= c0_dh + 1; else c1_dh <= c1_dh + 1; end if;
                                if we = '1' then
                                    -- write hit: if Shared, invalidate the other copy (BusUpgr)
                                    if d_st(i, se, hw) = ST_S and d_st(j, se, hw) /= ST_I
                                       and d_tag(j, se, hw) = tg then
                                        d_st(j, se, hw) <= ST_I; inval_cnt <= inval_cnt + 1;
                                    end if;
                                    if be(0) = '1' then d_dat(i, se, hw)(wd)(7 downto 0)   <= din(7 downto 0);   end if;
                                    if be(1) = '1' then d_dat(i, se, hw)(wd)(15 downto 8)  <= din(15 downto 8);  end if;
                                    if be(2) = '1' then d_dat(i, se, hw)(wd)(23 downto 16) <= din(23 downto 16); end if;
                                    if be(3) = '1' then d_dat(i, se, hw)(wd)(31 downto 24) <= din(31 downto 24); end if;
                                    d_st(i, se, hw) <= ST_M;
                                    smc_snoop(se, tg);            -- SMC: a store may hit cached code
                                end if;
                                touch_d(i, se, hw);
                            end if;
                        else
                            --------------------------------------------- MISS: latch + pick victim
                            f_core <= i; f_ifetch <= ifz; f_we <= we; f_addr <= a; f_din <= din; f_be <= be;
                            vic := 0; got_inv := false;
                            if ifz = '1' then
                                for k in 0 to WAYS - 1 loop
                                    if (not got_inv) and i_v(i, se, k) = ST_I then vic := k; got_inv := true; end if;
                                end loop;
                                if not got_inv then
                                    for k in 0 to WAYS - 1 loop
                                        if i_age(i, se, k) = WAYS - 1 then vic := k; end if;
                                    end loop;
                                end if;
                                i_v(i, se, vic) <= ST_I;         -- being refilled
                                f_victim <= vic;
                                cstatem <= C_FILL;
                            else
                                for k in 0 to WAYS - 1 loop
                                    if (not got_inv) and d_st(i, se, k) = ST_I then vic := k; got_inv := true; end if;
                                end loop;
                                if not got_inv then
                                    for k in 0 to WAYS - 1 loop
                                        if d_age(i, se, k) = WAYS - 1 then vic := k; end if;
                                    end loop;
                                end if;
                                f_victim <= vic;
                                if d_st(i, se, vic) = ST_M then
                                    wb_cnt <= wb_cnt + 1; cstatem <= C_WB;
                                else
                                    d_st(i, se, vic) <= ST_I; cstatem <= C_FILL;
                                end if;
                            end if;
                        end if;
                    end if;

                when C_WB =>
                    -- Burst the dirty victim back to RAM: one 32-bit word per
                    -- cycle over the 32-bit data bus (8 beats for a 32-byte line).
                    i := f_core; se := set_of(f_addr);
                    ram(ramword(d_tag(i, se, f_victim), se, burst_w)) <= d_dat(i, se, f_victim)(burst_w);
                    if burst_w = WORDS - 1 then
                        d_st(i, se, f_victim) <= ST_I;
                        burst_w  <= 0;
                        cstatem  <= C_FILL;
                    else
                        burst_w  <= burst_w + 1;
                    end if;

                when C_FILL =>
                    i := f_core;  j := 1 - f_core;
                    se := set_of(f_addr); tg := tag_of(f_addr);
                    -- snoop the OTHER core's data cache for this line (the snooped
                    -- state is stable across the burst; recomputed each beat)
                    dj_hit := '0'; dj_way := 0;
                    for k in 0 to WAYS - 1 loop
                        if d_st(j, se, k) /= ST_I and d_tag(j, se, k) = tg then dj_hit := '1'; dj_way := k; end if;
                    end loop;

                    if f_ifetch = '1' then
                        -- INSTRUCTION fill: the newest bytes come from a data cache
                        -- if either core holds the line (self/cross-modified code),
                        -- otherwise a burst read from RAM. One word per beat.
                        di_hit := '0'; di_way := 0;
                        for k in 0 to WAYS - 1 loop
                            if d_st(i, se, k) /= ST_I and d_tag(i, se, k) = tg then di_hit := '1'; di_way := k; end if;
                        end loop;
                        if di_hit = '1' then
                            i_dat(i, se, f_victim)(burst_w) <= d_dat(i, se, di_way)(burst_w);
                        elsif dj_hit = '1' then
                            i_dat(i, se, f_victim)(burst_w) <= d_dat(j, se, dj_way)(burst_w);
                        else
                            i_dat(i, se, f_victim)(burst_w) <= ram(ramword(tg, se, burst_w));
                        end if;
                        if burst_w = WORDS - 1 then
                            if CACHE_ON then                   -- no-cache: fill but don't retain
                                i_tag(i, se, f_victim) <= tg;
                                i_v(i, se, f_victim)   <= ST_S; -- valid (I-cache uses only I vs non-I)
                            end if;
                            burst_w <= 0;
                            cstatem <= C_SERVE;
                        else
                            burst_w <= burst_w + 1;
                        end if;
                    else
                        -- DATA fill (read-for-ownership on a write miss), bursted.
                        -- If the other core owns it Modified, the owner supplies
                        -- each word and memory snarfs the same beat (writeback).
                        if dj_hit = '1' then
                            d_dat(i, se, f_victim)(burst_w) <= d_dat(j, se, dj_way)(burst_w);
                            if d_st(j, se, dj_way) = ST_M then
                                ram(ramword(tg, se, burst_w)) <= d_dat(j, se, dj_way)(burst_w);
                            end if;
                        else
                            d_dat(i, se, f_victim)(burst_w) <= ram(ramword(tg, se, burst_w));
                        end if;
                        if burst_w = WORDS - 1 then
                            -- coherence bookkeeping, applied once as the fill completes
                            if dj_hit = '1' then
                                if d_st(j, se, dj_way) = ST_M then wb_cnt <= wb_cnt + 1; end if;
                                if f_we = '1' then                 -- BusRdX: invalidate the other copy
                                    d_st(j, se, dj_way) <= ST_I; inval_cnt <= inval_cnt + 1;
                                else                               -- BusRd: downgrade the other copy
                                    d_st(j, se, dj_way) <= ST_S;
                                end if;
                            end if;
                            if CACHE_ON then           -- no-cache: fill but don't retain the line
                                d_tag(i, se, f_victim) <= tg;
                                if f_we = '1' then         d_st(i, se, f_victim) <= ST_M;   -- will write in C_SERVE
                                elsif dj_hit = '1' then    d_st(i, se, f_victim) <= ST_S;   -- shared with other
                                else                       d_st(i, se, f_victim) <= ST_E;   -- exclusive
                                end if;
                            end if;
                            burst_w <= 0;
                            cstatem <= C_SERVE;
                        else
                            burst_w <= burst_w + 1;
                        end if;
                    end if;

                when C_SERVE =>
                    i := f_core;  se := set_of(f_addr);  wd := word_of(f_addr);  tg := tag_of(f_addr);
                    last_served <= i;
                    if f_ifetch = '1' then
                        if i = 0 then c0_im <= c0_im + 1; else c1_im <= c1_im + 1; end if;
                        touch_i(i, se, f_victim);
                    else
                        if i = 0 then c0_dm <= c0_dm + 1; else c1_dm <= c1_dm + 1; end if;
                        if f_we = '1' then                     -- apply the store into the filled line
                            mw := d_dat(i, se, f_victim)(wd);  -- old word (just filled from RAM)
                            if f_be(0) = '1' then mw(7 downto 0)   := f_din(7 downto 0);   end if;
                            if f_be(1) = '1' then mw(15 downto 8)  := f_din(15 downto 8);  end if;
                            if f_be(2) = '1' then mw(23 downto 16) := f_din(23 downto 16); end if;
                            if f_be(3) = '1' then mw(31 downto 24) := f_din(31 downto 24); end if;
                            d_dat(i, se, f_victim)(wd) <= mw;
                            if CACHE_ON then
                                d_st(i, se, f_victim) <= ST_M;
                                smc_snoop(se, tg);             -- SMC: a store may hit cached code
                            else
                                ram(ramword(tg, se, wd)) <= mw;  -- no-cache: write through, no allocate
                            end if;
                        end if;
                        touch_d(i, se, f_victim);
                    end if;
                    cstatem <= C_ARB;
            end case;
        end if;
    end process;

    dbg_c0_dhits <= std_logic_vector(c0_dh);  dbg_c0_dmiss <= std_logic_vector(c0_dm);
    dbg_c1_dhits <= std_logic_vector(c1_dh);  dbg_c1_dmiss <= std_logic_vector(c1_dm);
    dbg_c0_ihits <= std_logic_vector(c0_ih);  dbg_c0_imiss <= std_logic_vector(c0_im);
    dbg_c1_ihits <= std_logic_vector(c1_ih);  dbg_c1_imiss <= std_logic_vector(c1_im);
    dbg_invalidations <= std_logic_vector(inval_cnt);
    dbg_writebacks    <= std_logic_vector(wb_cnt);
    dbg_smc_inval     <= std_logic_vector(smc_cnt);
    dbg_c0_state <= d_st(0, to_integer(unsigned(dbg_watch_line)), 0);
    dbg_c1_state <= d_st(1, to_integer(unsigned(dbg_watch_line)), 0);

    -- Flatten core-0's I/D caches for the live viewer: line = set*WAYS + way.
    cache_view_proc : process(all)
        variable ln : integer;
    begin
        -- The viewer vectors hold the default geometry (64 words / 8 lines); for
        -- a larger configured cache, flatten only what fits (the window shows the
        -- first lines) so we never index past the fixed debug ports.
        for s in 0 to SETS - 1 loop
            for w in 0 to WAYS - 1 loop
                ln := s * WAYS + w;
                for k in 0 to WORDS - 1 loop
                    if ln * WORDS + k < 64 then
                        dbg_dcache(32*(ln*WORDS + k) + 31 downto 32*(ln*WORDS + k)) <= d_dat(0, s, w)(k);
                        dbg_icache(32*(ln*WORDS + k) + 31 downto 32*(ln*WORDS + k)) <= i_dat(0, s, w)(k);
                    end if;
                end loop;
                if ln < 8 then
                    dbg_dmeta(8*ln + 1 downto 8*ln)     <= d_st(0, s, w);            -- MESI state
                    dbg_dmeta(8*ln + 7 downto 8*ln + 2) <= std_logic_vector(resize(unsigned(d_tag(0, s, w)), 6));
                    dbg_imeta(8*ln + 1 downto 8*ln)     <= i_v(0, s, w);             -- valid (ST_I = empty)
                    dbg_imeta(8*ln + 7 downto 8*ln + 2) <= std_logic_vector(resize(unsigned(i_tag(0, s, w)), 6));
                end if;
            end loop;
        end loop;
    end process;

    -- Expose the current cache<->RAM bus beat so the RAM viewer lights exactly
    -- the 32-bit word the data bus is moving this cycle (a line fill reads one
    -- word per beat; a writeback writes one). Cache-to-cache supply touches no
    -- RAM, so it reports idle. See dbg_fill_kind encoding in the entity.
    fill_tap : process(all)
        variable se2 : integer range 0 to SETS - 1;
        variable tg2 : std_logic_vector(TAG_BITS - 1 downto 0);
        variable jh  : std_logic; variable jw : integer range 0 to WAYS - 1;
        variable ih  : std_logic;
    begin
        dbg_fill_addr <= (others => '0');
        dbg_fill_kind <= "00";
        se2 := set_of(f_addr); tg2 := tag_of(f_addr);
        if cstatem = C_WB then
            dbg_fill_addr <= std_logic_vector(to_unsigned(ramword(d_tag(f_core, se2, f_victim), se2, burst_w) * 4, 32));
            dbg_fill_kind <= "11";                       -- victim writeback (RAM write)
        elsif cstatem = C_FILL then
            jh := '0'; jw := 0;
            for k in 0 to WAYS - 1 loop
                if d_st(1 - f_core, se2, k) /= ST_I and d_tag(1 - f_core, se2, k) = tg2 then jh := '1'; jw := k; end if;
            end loop;
            if f_ifetch = '1' then
                ih := '0';
                for k in 0 to WAYS - 1 loop
                    if d_st(f_core, se2, k) /= ST_I and d_tag(f_core, se2, k) = tg2 then ih := '1'; end if;
                end loop;
                if ih = '0' and jh = '0' then            -- genuine RAM read beat
                    dbg_fill_addr <= std_logic_vector(to_unsigned(ramword(tg2, se2, burst_w) * 4, 32));
                    dbg_fill_kind <= "10";               -- instruction-fetch fill
                end if;                                  -- else supplied cache-to-cache: RAM idle
            else
                if jh = '1' then
                    if d_st(1 - f_core, se2, jw) = ST_M then
                        dbg_fill_addr <= std_logic_vector(to_unsigned(ramword(tg2, se2, burst_w) * 4, 32));
                        dbg_fill_kind <= "11";           -- owner's Modified line snarfed to RAM
                    end if;                              -- else shared supply: RAM idle
                else
                    dbg_fill_addr <= std_logic_vector(to_unsigned(ramword(tg2, se2, burst_w) * 4, 32));
                    dbg_fill_kind <= "01";               -- data fill (RAM read)
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Coherent dump snoop: a Modified data line in either core wins over RAM.
    ----------------------------------------------------------------------------
    snoop_proc : process(all)
        variable se, wd, b : integer;
        variable tg : std_logic_vector(TAG_BITS - 1 downto 0);
        variable word : std_logic_vector(31 downto 0);
        variable found : boolean;
    begin
        -- The dump snoop address is metavalue whenever no dump is in progress;
        -- don't decode/compare it then (avoids benign metavalue warnings).
        if is_x(snoop_addr) then
            snoop_byte <= (others => '0');
        else
            se := set_of(snoop_addr); tg := tag_of(snoop_addr); wd := word_of(snoop_addr);
            b  := to_integer(unsigned(snoop_addr(1 downto 0)));
            found := false; word := (others => '0');
            for c in 0 to 1 loop
                for k in 0 to WAYS - 1 loop
                    if d_st(c, se, k) = ST_M and d_tag(c, se, k) = tg then
                        word := d_dat(c, se, k)(wd); found := true;
                    end if;
                end loop;
            end loop;
            if found then snoop_byte <= word(8 * b + 7 downto 8 * b);
            else          snoop_byte <= ram(ramword(tg, se, wd))(8 * b + 7 downto 8 * b);
            end if;
        end if;
    end process;

end behavioral;
