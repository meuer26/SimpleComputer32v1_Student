#!/usr/bin/env python3
"""
Disassembly table for the waveform view: program image (.hex) -> .dis file.

  usage: mkdis.py <program.hex> <out.dis>

Runs ndisasm on the image and writes one "<8-hex-digit address> <text>" line per
instruction. The CPU (rtl/disasm_pkg.vhd) loads it so that Surfer can show the
instruction in each pipeline stage as text. Simulation display only.
"""
import os
import re
import subprocess
import sys
import tempfile

src, out = sys.argv[1], sys.argv[2]
data = bytes(int(l, 16) for l in open(src) if l.strip())
with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
    f.write(data)
    tmp = f.name
try:
    dis = subprocess.run(["ndisasm", "-b32", "-o0", tmp], capture_output=True, text=True).stdout
finally:
    os.unlink(tmp)
with open(out, "w") as o:
    for line in dis.splitlines():
        m = re.match(r"([0-9A-Fa-f]{8})\s+[0-9A-Fa-f]+\s+(.*)$", line)
        if m:
            o.write(f"{int(m.group(1), 16):08X} {m.group(2).strip()}\n")
