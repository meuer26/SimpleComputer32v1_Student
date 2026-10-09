--------------------------------------------------------------------------------
-- disasm_pkg : instruction text for the waveform viewer.
--
-- A simulation-only helper. The build writes the program's disassembly (from
-- ndisasm) as "<8-hex-digit address> <text>" lines; the CPU loads it at
-- elaboration and shows, for every pipeline stage, the instruction occupying it
-- as ASCII text -- so in Surfer the instructions visibly march through
-- D1 -> D2 -> EX -> WB. It has no effect on what the CPU does.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

package disasm_pkg is
    constant DIS_CHARS : integer := 24;                      -- text width per stage
    constant DIS_SIZE  : integer := 4096;                    -- addresses covered
    subtype dis_text  is string(1 to DIS_CHARS);
    type    dis_table is array (0 to DIS_SIZE - 1) of dis_text;

    impure function load_disasm(fname : string) return dis_table;
    -- text -> ASCII bit vector, first character in the MSBs (Surfer ASCII format)
    function dis_ascii(s : dis_text) return std_logic_vector;
    -- the text of the instruction at `addr` ("" when unknown)
    function dis_at(t : dis_table; addr : unsigned(31 downto 0)) return dis_text;
    function dis_str(s : string) return dis_text;
end package;

package body disasm_pkg is

    function dis_str(s : string) return dis_text is
        variable r : dis_text := (others => ' ');
    begin
        for i in 1 to DIS_CHARS loop
            if i <= s'length then r(i) := s(s'low + i - 1); end if;
        end loop;
        return r;
    end function;

    impure function load_disasm(fname : string) return dis_table is
        variable t    : dis_table := (others => (others => ' '));
        file     f    : text;
        variable st   : file_open_status;
        variable l    : line;
        variable a    : std_logic_vector(31 downto 0);
        variable good : boolean;
        variable c    : character;
        variable k    : integer;
    begin
        if fname'length = 0 then return t; end if;
        file_open(st, f, fname, read_mode);
        if st /= open_ok then return t; end if;
        while not endfile(f) loop
            readline(f, l);
            hread(l, a, good);
            if good and to_integer(unsigned(a(30 downto 0))) < DIS_SIZE and a(31) = '0' then
                read(l, c, good);                            -- the separating space
                k := 1;
                while k <= DIS_CHARS loop
                    read(l, c, good);
                    exit when not good;
                    t(to_integer(unsigned(a)))(k) := c;
                    k := k + 1;
                end loop;
            end if;
        end loop;
        file_close(f);
        return t;
    end function;

    function dis_ascii(s : dis_text) return std_logic_vector is
        variable r : std_logic_vector(8 * DIS_CHARS - 1 downto 0);
    begin
        for i in 0 to DIS_CHARS - 1 loop
            r(8 * DIS_CHARS - 1 - 8 * i downto 8 * DIS_CHARS - 8 - 8 * i) :=
                std_logic_vector(to_unsigned(character'pos(s(i + 1)), 8));
        end loop;
        return r;
    end function;

    function dis_at(t : dis_table; addr : unsigned(31 downto 0)) return dis_text is
    begin
        -- A parked/just-woken core can present a metavalue address before its
        -- pipeline is live; show blanks rather than warn on the comparison.
        if is_x(std_logic_vector(addr)) then return (others => ' ');
        elsif addr < DIS_SIZE then return t(to_integer(addr));
        else return (others => ' '); end if;
    end function;
end package body;
