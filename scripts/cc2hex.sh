#!/usr/bin/env bash
# Compile a freestanding C file with gcc and turn it into the flat one-byte-per-
# line hex image the simulator loads -- the C counterpart of asm2hex.sh.
#   usage: cc2hex.sh <src.c> <out.hex> [-O0|-O2] [listing.lst]   (crt0 from c/crt0.s)
# If a 4th argument is given, a NASM-style listing is written there so the live
# disassembly window can show the C program's machine code (same columns the
# code viewer parses out of a `nasm -l` listing).
set -euo pipefail
src="$1"; out="$2"; opt="${3:--O2}"; lst="${4:-}"
case "$opt" in -*) ;; *) opt="-$opt" ;; esac   # accept O0/O2 as well as -O0/-O2
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
CFLAGS="-m32 -march=i386 -mno-sse -mno-mmx -msoft-float -ffreestanding -fno-pic \
        -fno-pie -fno-stack-protector -fno-asynchronous-unwind-tables -fcf-protection=none"
gcc $CFLAGS $opt -c "$src"          -o "$tmp/prog.o"
gcc -m32 -c "$here/c/crt0.s"        -o "$tmp/crt0.o"
# --no-warn-rwx-segments: the flat image deliberately has one RWX load segment
# (code+data+stack all in the teaching PC's RAM); that is expected here.
ld -m elf_i386 --no-warn-rwx-segments -T "$here/c/flat.ld" \
   -o "$tmp/prog.elf" "$tmp/crt0.o" "$tmp/prog.o"
objcopy -O binary "$tmp/prog.elf" "$tmp/prog.bin"
xxd -c1 -p "$tmp/prog.bin" > "$out"
echo "  compiled $src ($opt) -> $out ($(wc -c < "$tmp/prog.bin") bytes)"

objdump -d -M intel "$tmp/prog.elf" > "$tmp/dis.txt"

# Optional listing for the live disassembly window. objdump's "addr: bytes  mnem"
# lines become the fixed columns load_listing() reads: line-no[0:6], address[7:15]
# (8 uppercase hex), code bytes concatenated[16:40], source text[40:].
if [ -n "$lst" ]; then
    python3 - "$tmp/dis.txt" "$lst" <<'PY'
import re, sys
dis, out = sys.argv[1], sys.argv[2]
rows, n = [], 0
insn = re.compile(r'^\s*([0-9a-f]+):\t([0-9a-f ]*?)\s*(?:\t(.*))?$')
for line in open(dis, errors="replace"):
    line = line.rstrip("\n")
    m = insn.match(line)
    if not m:
        continue
    addr, byts, src = m.group(1), m.group(2), (m.group(3) or "")
    code = byts.replace(" ", "").upper()
    if src:                                   # a new instruction
        n += 1
        rows.append([int(addr, 16), code, src.replace("\t", " ")])
    elif rows:                                # continuation: more bytes, same insn
        rows[-1][1] += code
with open(out, "w") as f:
    for i, (a, code, src) in enumerate(rows, 1):
        f.write(f"{i:6d} {a:08X} {code:<24}{src}\n")
PY
fi

echo "  --- objdump $src ($opt) ---"
# sed -n '1,60p' (not head -60): it drains the whole stream, so the upstream
# grep never takes a SIGPIPE that `set -o pipefail` would turn into a spurious
# failure when the listing runs longer than 60 lines (e.g. at -O0).
grep -E '^\s+[0-9a-f]+:' "$tmp/dis.txt" | sed -n '1,60{s/^/    /;p}'
