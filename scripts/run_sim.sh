#!/usr/bin/env bash
# Build and simulate the dual-Pentium (P54C) machine with GHDL.
#
#   scripts/run_sim.sh [--cache] [--smp|--vm|--pc] [--batch] <program.hex>
#
# The machine is always two superscalar cores + coherent split-L1 (MESI) caches;
# the BSP runs the program and the AP boots parked (started by a SIPI).
# Flags:
#   --cache      accepted for back-compat; the cache is always on
#   --smp        the SMP coherency demo (tb_smp)
#   --vm         with paging (each core: CPU -> MMU -> coherent split-L1)
#   --batch      do NOT launch the waveform viewer (used by `make` sweeps)
#   --pc         the teaching PC (tb_pc): CPU + keyboard, PICs, VGA text, ATA disk
#     --live            interactive: the terminal is the screen and keyboard
#     --disk=FILE       disk image (hex, one byte per line)
#     --disk-out=FILE   where the disk image is saved at the end
#     --keys=FILE       scripted key input ("<cycle> <hex scancode>" lines)
#
# For an individual test run the waveform is opened automatically in Surfer
# (https://surfer-project.org). Surfer is the only supported viewer; install it
# with:
#   cargo install --locked --git https://gitlab.com/surfer-project/surfer.git surfer
#
# RTL lives in rtl/, build artifacts (work library, VCD/GHW) go to build/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root (this script lives in scripts/)
RTL="$ROOT/rtl"
BUILD="$ROOT/build"
STD=08
mkdir -p "$BUILD"

# Prefer the LLVM backend: it is faster and prints a VHDL backtrace on an
# assertion (invaluable for pinning metavalue warnings). The `ghdl` wrapper
# silently picks mcode when both backends are installed, so select ghdl-llvm
# explicitly when it is present AND loads (its shared lib can be missing). Set
# GHDL=... to override.
# Pick a backend that can ACTUALLY COMPILE, preferring the fast LLVM one, then
# the self-contained mcode one (no LLVM dependency), then gcc, then the generic
# wrapper. CRITICAL: `ghdl-llvm --version` succeeds even when its shared library
# (libLLVM-NN.so) is missing/mismatched -- the driver only execs the LLVM code
# generator during real analysis/elaboration, so the breakage surfaces there,
# not at --version. We therefore probe each backend by actually analyzing AND
# elaborating a trivial design; this never selects a backend that would die
# mid-build (e.g. Pop!_OS 24.04's libLLVM-18.so soname mismatch). Set GHDL=...
# to force a specific backend. The winning backend is cached in build/ so the
# probe runs only once per clean tree.
ghdl_backend_works() {
    command -v "$1" >/dev/null 2>&1 || return 1
    _gp="$(mktemp -d 2>/dev/null)" || return 1
    printf 'entity ghdl_probe is end;\narchitecture a of ghdl_probe is begin end;\n' \
        > "$_gp/ghdl_probe.vhdl"
    ( cd "$_gp" && "$1" -a --std="$STD" ghdl_probe.vhdl \
                && "$1" -e --std="$STD" ghdl_probe ) >/dev/null 2>&1
    _rc=$?; rm -rf "$_gp"; return $_rc
}
BACKEND_CACHE="$BUILD/.ghdl_backend"
if [ -z "${GHDL:-}" ] && [ -s "$BACKEND_CACHE" ]; then
    _c="$(cat "$BACKEND_CACHE" 2>/dev/null)"
    command -v "$_c" >/dev/null 2>&1 && GHDL="$_c"
fi
if [ -z "${GHDL:-}" ]; then
    for cand in ghdl-llvm ghdl-mcode ghdl-gcc ghdl; do
        if ghdl_backend_works "$cand"; then
            GHDL="$cand"; echo "$cand" > "$BACKEND_CACHE" 2>/dev/null; break
        fi
    done
fi
if [ -z "${GHDL:-}" ]; then
    echo "ERROR: no working GHDL backend found (the LLVM backend's shared library" >&2
    echo "       may be missing/mismatched, e.g. libLLVM-18.so on Pop!_OS 24.04)." >&2
    echo "       Install the self-contained mcode backend -- it has no LLVM dep:" >&2
    echo "           sudo apt install -y ghdl-mcode" >&2
    echo "       then re-run.  (Plain 'make' auto-installs and uses it.)" >&2
    exit 1
fi

PROGRAM=""
OPEN_VIEWER=1          # individual runs auto-launch Surfer
USE_CACHE=1
SMP=0
VM=0
PC=0
PC_LIVE=0
PC_DISK=""
PC_DISK_OUT=""
PC_KEYS=""
abspath() { [ -z "$1" ] && return; echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
for arg in "$@"; do
    case "$arg" in
        --batch)    OPEN_VIEWER=0 ;;
        --cache)    USE_CACHE=1 ;;   # accepted for back-compat; the cache is always on
        --smp)      SMP=1 ;;       # 2-core snoopy-MESI coherency demo
        --vm)       VM=1 ;;        # scaled x86 paging (CPU + MMU + RAM)
        --pc)       PC=1 ;;        # the teaching PC (devices, interrupts)
        --live)     PC_LIVE=1; OPEN_VIEWER=0 ;;
        --disk=*)     PC_DISK="$(abspath "${arg#--disk=}")" ;;
        --disk-out=*) PC_DISK_OUT="$(abspath "${arg#--disk-out=}")" ;;
        --keys=*)     PC_KEYS="$(abspath "${arg#--keys=}")" ;;
        -*)         echo "ERROR: unknown flag '$arg'"; exit 1 ;;
        *)          PROGRAM="$arg" ;;
    esac
done

if [ -z "$PROGRAM" ]; then
    echo "Usage: $0 [--cache] [--smp|--vm|--pc] <program.hex>"
    exit 1
fi

# Resolve the program to an absolute path (search cwd, then build/).
if [ -f "$PROGRAM" ]; then
    PROGRAM="$(cd "$(dirname "$PROGRAM")" && pwd)/$(basename "$PROGRAM")"
elif [ -f "$BUILD/$PROGRAM" ]; then
    PROGRAM="$BUILD/$PROGRAM"
else
    echo "ERROR: could not find program '$PROGRAM'."
    exit 1
fi

if [ "$PC" = "1" ]; then
    TB_UNIT="tb_pc"
    CACHE_MSG="teaching PC (8042 keyboard, 8259 PICs, VGA text, ATA disk)"
elif [ "$SMP" = "1" ]; then
    TB_UNIT="tb_smp"
    CACHE_MSG="2-core SMP with snoopy-MESI coherent memory"
elif [ "$VM" = "1" ]; then
    TB_UNIT="tb_cpu_vm"
    CACHE_MSG="dual-Pentium + paging (each core: CPU -> MMU -> coherent split-L1)"
else
    TB_UNIT="tb_cpu"
    CACHE_MSG="dual-Pentium (2 cores, coherent split-L1 MESI, cache always on)"
fi

cd "$BUILD"
echo "==> Test program: $(basename "$PROGRAM")"
echo "==> Mode:         $CACHE_MSG"
# The one and only core: the superscalar Pentium (U/V dual-issue + BTB).
CPU_SRC="x86_super.vhd"
PIPE_FLAG=(--pipe)
echo "==> Core:         superscalar Pentium (U/V dual-issue, BTB)"
rm -f *.cf work-obj*.cf

# Disassembly table so the waveforms can show each stage's instruction as text.
DIS="$BUILD/$(basename "$PROGRAM" .hex).dis"
python3 "$ROOT/scripts/mkdis.py" "$PROGRAM" "$DIS" 2>/dev/null || : > "$DIS"
DIS_ARGS=(-gdisasm_file="$DIS")

"$GHDL" -a --std=$STD "$RTL/disasm_pkg.vhd"
"$GHDL" -a --std=$STD "$RTL/$CPU_SRC"
if [ "$PC" = "1" ]; then
    # The terminal "monitor + keyboard" is C code GHDL calls directly. The PC is
    # the dual-Pentium too: RAM is the coherent L1 (l1_mesi); VRAM/devices are
    # uncacheable MMIO; the AP is started by the local-APIC SIPI.
    gcc -O2 -Wall -shared -fPIC -o "$BUILD/libpchost.so" "$ROOT/scripts/pc_host.c"
    for u in l1_mesi apic mmu pic_8259 kbd_8042 vga_text ata_disk pc_chipset; do
        "$GHDL" -a --std=$STD "$RTL/$u.vhd"
    done
elif [ "$SMP" = "1" ]; then
    "$GHDL" -a --std=$STD "$RTL/l1_mesi.vhd"
    "$GHDL" -a --std=$STD "$RTL/apic.vhd"
else
    "$GHDL" -a --std=$STD "$RTL/port_io.vhd"
    if [ "$VM" = "1" ]; then
        # The dual-Pentium with paging: two cores, each CPU -> MMU -> coherent
        # split-L1 (MESI) + APIC. RAM is internal to l1_mesi.
        "$GHDL" -a --std=$STD "$RTL/l1_mesi.vhd"
        "$GHDL" -a --std=$STD "$RTL/apic.vhd"
        "$GHDL" -a --std=$STD "$RTL/mmu.vhd"
    else
        # The default machine: two Pentium cores + coherent split-L1 + APIC.
        "$GHDL" -a --std=$STD "$RTL/l1_mesi.vhd"
        "$GHDL" -a --std=$STD "$RTL/apic.vhd"
    fi
fi
"$GHDL" -a --std=$STD "$RTL/$TB_UNIT.vhd"
"$GHDL" -e --std=$STD "$TB_UNIT"

# The caches are a fixed Pentium-faithful geometry (split I/D, 2-way, 32 B
# lines), so there are no cache-geometry generics to pass.
GEOM_ARGS=()

if [ "$PC" = "1" ]; then
    PC_ARGS=(-gLIVE="$PC_LIVE")
    [ -n "$PC_DISK" ]     && PC_ARGS+=(-gdisk_file="$PC_DISK")
    [ -n "$PC_DISK_OUT" ] && PC_ARGS+=(-gdisk_out="$PC_DISK_OUT")
    [ -n "$PC_KEYS" ]     && PC_ARGS+=(-gkeys_file="$PC_KEYS")
    # Machine-configuration knobs: any CFG_* that is set in the environment
    # overrides the tb_pc default (the standard Pentium machine). Unset = default.
    for v in CFG_DUAL CFG_SERIAL CFG_BTB CFG_CACHE CFG_SETS CFG_WAYS CFG_LINE; do
        val="${!v:-}"; [ -n "$val" ] && PC_ARGS+=(-g"$v"="$val")
    done
    if [ "$PC_LIVE" = "1" ]; then
        # Interactive: the terminal belongs to the screen; simulator chatter
        # goes to a log. No waveform (a live session can run for minutes) --
        # replay the logged keys with `make pc-replay` to get one.
        "$GHDL" -r --std=$STD tb_pc -gprogram_file="$PROGRAM" "${PC_ARGS[@]}" "${DIS_ARGS[@]}" \
            --ieee-asserts=disable 2> "$BUILD/pc_live.log"
        exit 0
    fi
    WAVE_ARGS=()
    if [ "$OPEN_VIEWER" = "1" ]; then
        # The PC design is big: dump only the signals the Surfer view shows
        # (chosen from the program's disassembly), which keeps the run fast.
        tr -d '\n \t\r' < "$PROGRAM" | xxd -r -p > "$BUILD/tb_pc.dis.bin" 2>/dev/null || true
        ndisasm -b32 -o0 "$BUILD/tb_pc.dis.bin" 2>/dev/null \
            | python3 "$ROOT/scripts/surfer_rows.py" --tb tb_pc "${PIPE_FLAG[@]}" > "$BUILD/tb_pc.surf.txt"
        { echo '$ version 1.1'
          awk '$1=="variable_add"{p=$2} $1=="scope_add"{p=$2".*"} p!=""{gsub(/\./,"/",p); print "/" p; p=""}' "$BUILD/tb_pc.surf.txt"
        } > "$BUILD/tb_pc.wopt"
        WAVE_ARGS=(--read-wave-opt=tb_pc.wopt --vcd="$TB_UNIT.vcd")
    fi
    "$GHDL" -r --std=$STD tb_pc -gprogram_file="$PROGRAM" "${PC_ARGS[@]}" "${DIS_ARGS[@]}" \
        --ieee-asserts=disable-at-0 "${WAVE_ARGS[@]}"
    if [ "$OPEN_VIEWER" = "0" ]; then exit 0; fi
    # Active-low pins are VHDL extended identifiers (\MEMR#\): drop the
    # backslashes so the viewer shows MEMR#, IOR#, ...
    sed -i '1,/\$enddefinitions/ s/ \\\([^ ]*#\)\\ / \1 /' "$BUILD/$TB_UNIT.vcd"
else
# disable-at-0 silences the benign TO_INTEGER metavalue notes emitted while
# signals are still uninitialized at time 0 (same as the PC path); real
# assertions during the run (t>0) are still reported.
"$GHDL" -r --std=$STD "$TB_UNIT" \
    -gprogram_file="$PROGRAM" \
    "${GEOM_ARGS[@]}" "${DIS_ARGS[@]}" \
    --ieee-asserts=disable-at-0 \
    --vcd="$TB_UNIT.vcd" \
    --wave="$TB_UNIT.ghw"
fi

echo "==> Done. Wave: $BUILD/$TB_UNIT.vcd"

# ---------------------------------------------------------------------------
# Generate a Surfer command file so the default view is populated automatically.
# The FSM state-name tap is always shown as ASCII text (no manual "Format ->
# ASCII"), and for single-core runs the *rest* of the rows are chosen by
# scripts/surfer_rows.py based on what the program actually does -- it
# disassembles the image and adds only the relevant signals (stack, SSE, I/O,
# interrupts, atomics, cache, ...). Commands run after the wave loads.
SURF_CMDS="$BUILD/$TB_UNIT.surf.txt"
if [ "$TB_UNIT" = "tb_smp" ]; then
    # SMP runs one fixed coherency demo: curate a two-core view that shows BOTH
    # superscalar pipelines (each core's FSM state, pipeline-stage occupancy, and
    # U/V pair co-issue) AND the MESI coherency steps (per-core line state,
    # invalidations, write-backs, bus grant) that keep the shared counter correct.
    {
        # ASCII (text) items first -- Surfer names items a,b,c,... in add order.
        echo "variable_add tb_smp.sname0";           echo "item_focus a"; echo "item_set_format ASCII"
        echo "variable_add tb_smp.core0.dbg_ex_txt"; echo "item_focus b"; echo "item_set_format ASCII"
        echo "variable_add tb_smp.core0.dbg_v_txt";  echo "item_focus c"; echo "item_set_format ASCII"
        echo "variable_add tb_smp.sname1";           echo "item_focus d"; echo "item_set_format ASCII"
        echo "variable_add tb_smp.core1.dbg_ex_txt"; echo "item_focus e"; echo "item_set_format ASCII"
        echo "variable_add tb_smp.core1.dbg_v_txt";  echo "item_focus f"; echo "item_set_format ASCII"
        echo "divider_add core0_BSP_pipeline"
        echo "variable_add tb_smp.clk"
        echo "variable_add tb_smp.pc0"
        echo "variable_add tb_smp.core0.dbg_stage_valid"  # D1 D2 EX WB occupancy
        echo "variable_add tb_smp.core0.dbg_v_valid"      # core0 co-issued a U/V pair
        echo "divider_add core1_AP_pipeline"
        echo "variable_add tb_smp.pc1"
        echo "variable_add tb_smp.core1.dbg_ex_txt"
        echo "variable_add tb_smp.core1.dbg_stage_valid"
        echo "variable_add tb_smp.core1.dbg_v_valid"      # core1 co-issued a U/V pair
        echo "divider_add MESI_coherency"
        echo "variable_add tb_smp.c0_st"               # core0 line state M/E/S/I
        echo "variable_add tb_smp.c1_st"               # core1 line state M/E/S/I
        echo "variable_add tb_smp.grant"               # which core owns the bus
        echo "variable_add tb_smp.invs"                # snoop invalidations (step up)
        echo "variable_add tb_smp.wbs"                 # snoop/evict write-backs
        echo "zoom_fit"
    } > "$SURF_CMDS"
else
    # Program-aware rows: reconstruct the binary from the hex image, disassemble
    # it, and let surfer_rows.py decide which signals are relevant.
    DISBIN="$BUILD/$TB_UNIT.dis.bin"
    tr -d '\n \t\r' < "$PROGRAM" | xxd -r -p > "$DISBIN" 2>/dev/null || true
    if ndisasm -b32 -o0 "$DISBIN" 2>/dev/null \
         | python3 "$ROOT/scripts/surfer_rows.py" --tb "$TB_UNIT" "${PIPE_FLAG[@]}" > "$SURF_CMDS"; then
        :
    else
        # Fallback: state name + a safe core set if disassembly/analysis fails.
        {
            echo "variable_add $TB_UNIT.dbg_state_name"; echo "item_focus a"; echo "item_set_format ASCII"
            echo "variable_add $TB_UNIT.dbg01_clk"
            echo "variable_add $TB_UNIT.dbg_pc"
            echo "variable_add $TB_UNIT.dbg03_ir"
            echo "variable_add $TB_UNIT.cpu_inst.modrm"
            echo "variable_add $TB_UNIT.dbg04_operand"
            echo "variable_add $TB_UNIT.dbg11_we"
            echo "variable_add $TB_UNIT.dbg05_eax"
            echo "zoom_fit"
        } > "$SURF_CMDS"
    fi
    rm -f "$DISBIN"
fi

if [ "$OPEN_VIEWER" = "1" ]; then
    if command -v surfer >/dev/null 2>&1; then
        echo "==> Launching Surfer (state name shown as ASCII automatically)..."
        surfer -c "$SURF_CMDS" "$BUILD/$TB_UNIT.vcd" &
    else
        echo "ERROR: 'surfer' not found. Surfer is the supported waveform viewer."
        echo "       Install it with:"
        echo "         cargo install --locked --git https://gitlab.com/surfer-project/surfer.git surfer"
        exit 1
    fi
fi
