#!/usr/bin/env bash
# Rebuild the chronogram of a live `make pc` session up to the cycle where it
# is paused, and open it in Surfer.
#
#   scripts/pc_snapshot.sh <build dir> <cycle>
#
# The simulation is deterministic: the same program, the same disk image and
# the same scan codes at the same cycles (build/pc_keys.log, written by the live
# session as it runs) reproduce the session exactly. So instead of recording a
# huge waveform the whole time, this re-runs the session from reset to <cycle>
# in batch mode -- in a second simulator process, while the live one waits --
# and writes a waveform of just the signals the Surfer view shows.
set -euo pipefail
BUILD="$(cd "$1" && pwd)"
CYCLE="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BUILD"

# Surfer rows chosen from the program's disassembly; dump only those signals.
tr -d '\n \t\r' < pc_prog.hex | xxd -r -p > pc_snapshot.bin
PIPE=()
[ "$(cat pc_core 2>/dev/null)" = "pipe" ] && PIPE=(--pipe)     # which core this session runs
ndisasm -b32 -o0 pc_snapshot.bin | python3 "$ROOT/scripts/surfer_rows.py" --tb tb_pc "${PIPE[@]}" > pc_snapshot.surf.txt
{ echo '$ version 1.1'
  awk '$1=="variable_add"{p=$2} $1=="scope_add"{p=$2".*"} p!=""{gsub(/\./,"/",p); print "/" p; p=""}' pc_snapshot.surf.txt
} > pc_snapshot.wopt

# Replay (the live session's work library is reused as-is: no recompiling).
ghdl -r --std=08 tb_pc -gprogram_file="$BUILD/pc_prog.hex" -gdisk_file="$BUILD/pc_disk.hex" \
    -gkeys_file="$BUILD/pc_keys.log" -gRUN_TO="$CYCLE" -gdisasm_file="$BUILD/pc_prog.dis" \
    --ieee-asserts=disable --read-wave-opt=pc_snapshot.wopt --vcd=pc_snapshot.vcd \
    > pc_snapshot.log 2>&1

# Active-low pins are VHDL extended identifiers (\MEMR#\): drop the backslashes
# so Surfer shows MEMR#, IOR#, ...
sed -i '1,/\$enddefinitions/ s/ \\\([^ ]*#\)\\ / \1 /' pc_snapshot.vcd

exec surfer -c pc_snapshot.surf.txt pc_snapshot.vcd
