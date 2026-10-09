#!/usr/bin/env bash
# Assemble a real x86-32 NASM source to a flat binary, then to the
# one-byte-per-line hex image the RAM loads.
#   usage: ./asm2hex.sh <src.asm> <out.hex>
set -euo pipefail
src="$1"; out="$2"
bin="$(mktemp /tmp/x86bin.XXXXXX)"
nasm -f bin "$src" -o "$bin"
xxd -c1 -p "$bin" > "$out"
echo "  assembled $src -> $out ($(wc -c < "$bin") bytes)"
# Show the disassembly so students can compare source <-> machine code
echo "  --- ndisasm $src ---"
ndisasm -b32 -o0 "$bin" | sed 's/^/    /'
rm -f "$bin"
