#!/usr/bin/env python3
"""
Verify each test's final architectural state against its expected values.

Expectations are derived from each program's documented intent (final register
values, flags, IVT base, and specific memory locations). For the teaching-PC
tests (40+) also the text on the 80x25 screen and bytes of the saved disk image
(build/<n>_disk_out.hex). Actual values are
parsed from build/tests.txt, produced by simulating the real x86-32 machine
code (assembled by nasm) on the VHDL CPU.
"""

import re
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Default log is build/tests.txt; a path may be given as argv[1] (e.g. the
# paging suite writes build/vm_tests.txt).
TESTS_TXT = (sys.argv[1] if len(sys.argv) > 1
             else os.path.join(HERE, "..", "build", "tests.txt"))
BUILD = os.path.dirname(os.path.abspath(TESTS_TXT))


def parse_tests_txt():
    with open(TESTS_TXT) as f:
        text = f.read()
    parts = re.split(r'==> Test program: (\d+)_test\.hex', text)
    out = {}
    for i in range(1, len(parts), 2):
        out[int(parts[i])] = parts[i + 1]
    return out


REG_RE = {
    'eax': re.compile(r'Final EAX\s*=\s*0x([0-9A-Fa-f]+)'),
    'ebx': re.compile(r'Final EBX\s*=\s*0x([0-9A-Fa-f]+)'),
    'ecx': re.compile(r'Final ECX\s*=\s*0x([0-9A-Fa-f]+)'),
    'edx': re.compile(r'Final EDX\s*=\s*0x([0-9A-Fa-f]+)'),
    'esp': re.compile(r'Final ESP\s*=\s*0x([0-9A-Fa-f]+)'),
    'pc':  re.compile(r'Final PC\s*=\s*0x([0-9A-Fa-f]+)'),
    'z':   re.compile(r"Zero flag\s*=\s*'([01])'"),
    'c':   re.compile(r"Carry flag\s*=\s*'([01])'"),
    'i':   re.compile(r"Int flag\s*=\s*'([01])'"),
    'ivt': re.compile(r'IVT base\s*=\s*0x([0-9A-Fa-f]+)'),
}


def extract_final(section):
    out = {}
    for k, r in REG_RE.items():
        m = r.search(section)
        if m:
            out[k] = int(m.group(1)) if k in ('z', 'c', 'i') else int(m.group(1), 16)
    return out


# Pipeline statistics (printed by the testbenches when the core is pipelined).
PIPE_RE = re.compile(r'stall cycles: microcode=(\d+) AGI=(\d+) branch=(\d+) '
                     r'queue-empty=(\d+) mem-wait=(\d+) bus-busy=(\d+)')


def extract_pipe(section):
    m = PIPE_RE.search(section)
    if not m:
        return None
    keys = ('microcode', 'agi', 'branch', 'queue', 'memwait', 'busbusy')
    return dict(zip(keys, map(int, m.groups())))


SCREEN_RE = re.compile(r'^screen\[(\d\d)\] \|(.*)\|$', re.MULTILINE)


def extract_screen(section):
    return {int(m.group(1)): m.group(2).rstrip() for m in SCREEN_RE.finditer(section)}


def read_disk(n):
    path = os.path.join(BUILD, f"{n}_disk_out.hex")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return [int(l, 16) for l in f if l.strip()]


DUMP_ROW_RE = re.compile(r'^0x([0-9A-Fa-f]{3})\s+((?:[0-9A-Fa-f]{2}\s*)+)$', re.MULTILINE)


def extract_memdump(section):
    mem = {}
    for m in DUMP_ROW_RE.finditer(section):
        base = int(m.group(1), 16)
        for i, b in enumerate(m.group(2).split()):
            mem[base + i] = int(b, 16)
    return mem


# Verified expectations (real x86-32 encodings). mem entries are (addr, bytes).
EXPECTED = {
    1:  {'regs': {'eax': 0x11223344, 'ebx': 0x11223344, 'ecx': 0x11223344, 'esp': 0, 'z': 0},
         'mem': [(0x100, [0x44, 0x33, 0x22, 0x11])]},
    2:  {'regs': {'eax': 0x42, 'ebx': 6, 'ecx': 9},
         'mem': [(0x100, [0x42, 0, 0, 0]), (0x110, [0x42, 0, 0, 0])]},
    3:  {'regs': {'eax': 0x64, 'ebx': 0x74, 'ecx': 0x84, 'z': 0, 'c': 0},
         'mem': [(0x100, [0x15, 0, 0, 0]), (0x104, [0, 0, 0, 0]), (0x108, [0, 0, 0, 0])]},
    4:  {'regs': {'eax': 0x50, 'ebx': 0x40, 'ecx': 0xFFFFFFF0, 'c': 1},
         'mem': [(0x100, [0x5F, 0, 0, 0]), (0x104, [0xA1, 0xFF, 0xFF, 0xFF])]},
    5:  {'regs': {'eax': 0x80000001},
         'mem': [(0x100, [0x01, 0, 0, 0x80]), (0x104, [0x02, 0, 0, 0]),
                 (0x108, [0x01, 0, 0, 0]), (0x10C, [0x03, 0, 0, 0]),
                 (0x110, [0x01, 0, 0, 0x80])]},
    6:  {'regs': {'eax': 0xDEADBEEF},
         'mem': [(0x100, [0xEF, 0xBE, 0xAD, 0xDE])]},
    7:  {'regs': {'eax': 7, 'ebx': 7, 'ecx': 0, 'z': 0, 'c': 0},
         'mem': [(0x100, [0x07, 0, 0, 0])]},
    8:  {'regs': {'eax': 0x11111111, 'esp': 0xE0},
         'mem': [(0x100, [0x33, 0x33, 0x33, 0x33]), (0x104, [0x22, 0x22, 0x22, 0x22]),
                 (0x108, [0x11, 0x11, 0x11, 0x11])]},
    9:  {'regs': {'eax': 0xDEADBEEF, 'esp': 0xF0},
         'mem': [(0x100, [0xEF, 0xBE, 0xAD, 0xDE]), (0xEC, [0xEF, 0xBE, 0xAD, 0xDE])]},
    10: {'regs': {'eax': 0x99, 'ebx': 5, 'pc': 0x1C},
         'mem': [(0x100, [0, 0, 0, 0])]},
    11: {'regs': {'eax': 0x4B, 'pc': 0x46},
         'mem': [(0x100, [0x01, 0, 0, 0]), (0x104, [0x02, 0, 0, 0]),
                 (0x108, [0x03, 0, 0, 0]), (0x10C, [0x4B, 0, 0, 0])]},
    12: {'regs': {'eax': 0x22, 'esp': 0xF0},
         'mem': [(0x100, [0x42, 0, 0, 0]), (0x104, [0x22, 0, 0, 0])]},
    13: {'regs': {'eax': 0x55, 'esp': 0xF0},
         'mem': [(0x100, [0x55, 0, 0, 0])]},
    14: {'regs': {'eax': 0x22222222, 'esp': 0xF0, 'i': 0, 'ivt': 0x150},
         'mem': [(0x100, [0xEF, 0xBE, 0xAD, 0xDE]), (0x104, [0x22, 0x22, 0x22, 0x22]),
                 (0x150, [0x80, 0x01, 0, 0])]},
    15: {'regs': {'eax': 0xBBBB, 'esp': 0xF0, 'ivt': 0x140, 'i': 0},
         'mem': [(0x100, [0xAA, 0xAA, 0, 0]), (0x104, [0xCC, 0xCC, 0, 0]),
                 (0x108, [0xBB, 0xBB, 0, 0]), (0x140, [0x80, 0x01, 0, 0]),
                 (0x144, [0x90, 0x01, 0, 0]), (0x148, [0xA0, 0x01, 0, 0])]},
    16: {'regs': {'eax': 0x1234567B, 'ebx': 0xDEADBEEF, 'ecx': 0x0F, 'z': 0, 'c': 0, 'i': 0},
         'mem': [(0x100, [0x7B, 0x56, 0x34, 0x12]), (0x104, [0x6A, 0x15, 0xE2, 0xF0])]},
    17: {'regs': {'eax': 0x42424242, 'ebx': 5, 'ecx': 0xD, 'esp': 0xF0,
                  'z': 0, 'c': 0, 'i': 0, 'ivt': 0x140},
         'mem': [(0x100, [0xAA, 0, 0, 0]), (0x140, [0xC0, 0x01, 0, 0]),
                 (0x150, [0x42, 0, 0, 0]), (0x160, [0x42, 0x42, 0, 0]),
                 (0x164, [0x42, 0x42, 0, 0]), (0x168, [0, 0, 0x42, 0x42]),
                 (0x1F0, [0x42, 0x42, 0x42, 0x42])]},
    18: {'regs': {'eax': 0x11223344, 'ebx': 0, 'ecx': 0, 'esp': 0, 'pc': 0x1B,
                  'z': 0, 'c': 0, 'i': 0},
         'mem': [(0x100, [0xEF, 0xBE, 0xAD, 0xDE]), (0x110, [0x44, 0x33, 0x22, 0x11])]},
    19: {'regs': {'eax': 0, 'ecx': 1, 'esp': 0, 'pc': 0x33, 'z': 1, 'c': 0, 'i': 0},
         'mem': [(0x100, [0, 0, 0, 0]), (0x180, [0xEF, 0xBE, 0xAD, 0xDE])]},
    20: {'regs': {},
         'mem': [(0x120, [0x11, 0, 0, 0]), (0x124, [0x22, 0, 0, 0]),
                 (0x128, [0x33, 0, 0, 0]), (0x12C, [0x44, 0, 0, 0])]},
    21: {'regs': {'eax': 0xC0DE},
         'mem': [(0x100, [0x78, 0x56, 0x34, 0x12]), (0x104, [0xEF, 0xBE, 0xAD, 0xDE])]},
    22: {'regs': {},
         'mem': [(0x120, [0x02, 0, 0, 0, 0x04, 0, 0, 0, 0x06, 0, 0, 0, 0x08, 0, 0, 0]),
                 (0x130, [0x02, 0, 0, 0, 0x04, 0, 0, 0, 0x06, 0, 0, 0, 0x08, 0, 0, 0])]},
    23: {'regs': {'eax': 0x88, 'ecx': 0},
         'mem': [(0x160, [0x88, 0, 0, 0])]},
    24: {'regs': {'eax': 3, 'ecx': 0},
         'mem': [(0x80, [3, 0, 0, 0]), (0x100, [3, 0, 0, 0]),
                 (0x180, [3, 0, 0, 0])]},
    # Byte/word data, I/O widths, the real interrupt frame.
    29: {'regs': {'eax': 0x30, 'ecx': 0xDD, 'z': 1},
         'mem': [(0x100, [0x55, 0x66, 0x22, 0x11]), (0x104, [0xDD, 0x99, 0x77, 0xAA]),
                 (0x108, [0x00, 0x00, 0x34, 0x12]), (0x10C, [0xEF, 0xBE, 0x00, 0x00]),
                 (0x110, [0xAA, 0, 0, 0]), (0x114, [0x30, 0, 0, 0]),
                 (0x118, [0x00, 0x11, 0x22, 0x33, 0x44, 0x00]),
                 (0x120, [0x11, 0x22, 0x33, 0x44])]},
    30: {'regs': {'eax': 0x5A},
         'mem': [(0x100, [0x41, 0x56, 0x34, 0x12]), (0x104, [0xEF, 0xBE, 0x11, 0x11]),
                 (0x108, [0x5A, 0, 0, 0])]},
    31: {'regs': {'eax': 0x203, 'ecx': 2, 'ebx': 4, 'esp': 0xF0, 'c': 1, 'i': 0},
         'mem': [(0x100, [0x0F, 0, 0, 0]), (0x104, [0x08, 0, 0, 0]),
                 (0x108, [0x03, 0, 0, 0]), (0x10C, [0x03, 0, 0, 0]),
                 (0x110, [0x03, 0x02, 0, 0]), (0xDC, [0xF0, 0, 0, 0]),
                 (0xE8, [0x02, 0, 0, 0])]},
    # The pipeline and its hazards. 'pipe' = exact stall-cycle counts, emitted
    # whenever the core has the pipeline taps and checked against them.
    #   branch = 7 on the superscalar Pentium core: unlike the 486 (which never
    #   speculates, so a taken branch costs 2 and a not-taken branch is free ->
    #   3 taken x 2 = 6), the BTB predicts the loop branch taken, fetching the
    #   taken iterations cheaply but MISPREDICTING the loop exit (predicted
    #   taken, actually not taken) on top of the cold-start miss -- the classic
    #   branch-prediction trade-off, cheap in the body, a miss at the exit.
    32: {'regs': {'eax': 0x11111112, 'ecx': 0},
         'mem': [(0x100, [0x08, 0, 0, 0]), (0x104, [0x11] * 4), (0x108, [0x22] * 4),
                 (0x10C, [0x12, 0x11, 0x11, 0x11]), (0x110, [0, 0, 0, 0])],
         'pipe': {'agi': 1, 'branch': 7, 'microcode': 0}},
    # Self-modifying code: an instruction is rewritten by a store, then re-run.
    # iter1 AL=0x11 (EBX+=0x11), patch imm->0x22, iter2 AL=0x22 (EBX+=0x22) => 0x33.
    # If the instruction-cache SMC snoop were broken the re-fetch would see the
    # stale 0x11 and EBX would be 0x22, so this pins the coherence down.
    33: {'regs': {'eax': 0x33, 'ebx': 0x33},
         'mem': [(0x100, [0x33, 0, 0, 0])]},
    # Superscalar U/V correctness: independent ops pair, a RAW dependence blocks
    # pairing (ECX=30, not a stale read), WAW keeps EDX=2, and a cmp/sub + Jcc
    # pair forwards the flags (the 0xDEAD / 0xBAD stores never happen).
    34: {'regs': {'eax': 0x29, 'ebx': 0x2A, 'ecx': 0x37, 'edx': 0x2C},
         'mem': [(0x100, [0x37, 0, 0, 0]), (0x104, [0x29, 0, 0, 0])]},
    # SIB / scaled-index addressing: every form read back equals the stored value.
    35: {'regs': {'eax': 0x11223344, 'ebx': 0x11223344, 'ecx': 0x11223344,
                  'edx': 0x11223344, 'esp': 0x1F0},
         'mem': [(0x100, [0x44, 0x33, 0x22, 0x11]), (0x48, [0x44, 0x33, 0x22, 0x11])]},
    # ALU with a memory operand (load direction) + CMP-with-memory feeding a branch.
    36: {'regs': {'eax': 0, 'ebx': 0xFF, 'ecx': 50, 'edx': 0, 'z': 1},
         'mem': [(0x100, [0xFF, 0, 0, 0])]},
    # Read-modify-write ALU on memory ([m] op= r) and grp1 ([m] op= imm).
    37: {'regs': {'eax': 0x7B, 'ebx': 0x17, 'ecx': 0x9B, 'edx': 0x22},
         'mem': [(0x90, [0x9B, 0, 0, 0]), (0x94, [0x22, 0, 0, 0])]},
    # IMUL (2-/3-operand, memory) and the shift group by imm8/CL + shift-on-memory.
    38: {'regs': {'eax': 0x28, 'ebx': 0x3F4, 'ecx': 0x100, 'edx': 0xFFFFFFF0},
         'mem': [(0x80, [10, 0, 0, 0]), (0x84, [0x28, 0, 0, 0])]},
    # LEA, INC/DEC on a memory counter (grp5), and LEAVE -- the gcc "glue".
    39: {'regs': {'eax': 0x54, 'ebx': 0x90, 'ecx': 0x65, 'edx': 0xABCD, 'esp': 0x1F0},
         'mem': [(0x100, [0x65, 0, 0, 0])]},
    # grp3 (MUL/DIV/IDIV/NEG), MOVSX, SETcc, CDQ -- division + sign-extend + bool.
    47: {'regs': {'eax': 0xFFFFFFFA, 'ebx': 0xFFFFFFF0, 'ecx': 1, 'edx': 0xFFFFFFFE},
         'mem': [(0x100, [0x2A, 0, 0, 0]), (0x104, [0x0E, 0, 0, 0]),
                 (0x108, [2, 0, 0, 0]), (0x10C, [0xFB, 0xFF, 0xFF, 0xFF])]},
    # byte r/m ALU: store/load-direction ADD..CMP, grp1 r/m8,imm8, TEST r/m8,r8,
    # on registers and memory (RMW).  Every result converges on 0x3F.
    48: {'regs': {'eax': 0x3F, 'ebx': 0x3F, 'ecx': 0x3F, 'edx': 0x3F},
         'mem': [(0x100, [0x30, 0, 0, 0]), (0x104, [0x3F, 0, 0, 0]),
                 (0x108, [1, 0, 0, 0]), (0x10C, [1, 0, 0, 0])]},
    # Pairing demo (also `make cpi-compare PROG=asm/49_pairing.asm`): a loop of
    # independent adds; 500 iterations * 4 per register -> 2000 (0x7D0).
    49: {'regs': {'eax': 0x7D0, 'ebx': 0x7D0, 'ecx': 0}, 'mem': []},
    # Teaching PC (run via `make pc-test`): screen rows, RAM, disk image.
    40: {'regs': {'ebx': 0xFFFFFFFF, 'i': 0},
         'mem': [(0x800, [0x48, 0x1F, 0x65, 0x1F, 0xE9])],
         'screen': [(0, 'Hello, world!'), (1, 'OK'), (2, 'Hi')]},
    41: {'regs': {'i': 0},
         'mem': [(0x800, [0x05, 0, 0, 0])],
         'screen': [(0, '> hello'), (1, '')]},
    42: {'regs': {},
         'mem': [],
         'screen': [(0, 'Simple Computer 32 v1'),
                    (1, '> Hi there!'), (2, '>')]},
    43: {'regs': {'i': 0},
         'mem': [(0x800, [0x51, 0x04])],
         'screen': [(0, 'IDENTIFY: SimpleComputer32 Teaching Disk'),
                    (1, 'Hello from sector 0 of the ATA disk (asm/pc_disk.asm).'),
                    (2, 'Sector 1: written by the CPU with OUT DX, AX (PIO).')],
         'disk': [(0x200, list(b'Sector 1: written by the CPU with OUT DX, AX (PIO).\0')),
                  (0x000, list(b'Hello from sector 0'))]},
    44: {'regs': {'i': 0},
         'mem': [(0x800, [0x02, 0, 0, 0])],
         'screen': [(0, 'Sector 2: delivered by an IRQ14 interrupt.'),
                    (1, 'Sector 3: the second sector of a 2-sector read.'),
                    (2, 'IRQ14 interrupts: 2')]},
    45: {'regs': {'i': 0},
         'mem': [(0x800, [0x1B, 0, 0, 0])],
         'screen': [(0, 'Executing UD2 (0F 0B), an invalid opcode...'),
                    (1, '#UD at EIP=0x0000001B'),
                    (2, 'Resumed after the #UD handler.')]},
    # SMP on the PC: BSP SIPIs the AP; both increment a shared counter to 8.
    46: {'regs': {}, 'mem': [(0x110, [8, 0, 0, 0]), (0x800, [8, 0, 0, 0])],
         'screen': [(0, 'SMP: BSP + AP, counter = 8')]},
    # Paging demos (run via `make vm`). Memory addresses are PHYSICAL.
    25: {'regs': {'eax': 0xDEADBEEF, 'ebx': 0xDEADBEEF},
         'mem': [(0x80, [0xEF, 0xBE, 0xAD, 0xDE])]},
    26: {'regs': {'eax': 0x1234ABCD, 'ebx': 0x1234ABCD},
         'mem': [(0x140, [0xCD, 0xAB, 0x34, 0x12]), (0x80, [0, 0, 0, 0])]},
    27: {'regs': {'eax': 8, 'ebx': 8, 'ecx': 0},
         'mem': [(0x80, [8, 0, 0, 0])]},
    28: {'regs': {'eax': 0xD00DF00D, 'ebx': 0xD00DF00D},
         'mem': [(0x140, [0x0D, 0xF0, 0x0D, 0xD0])]},
}


def verify(test_num, section):
    if test_num not in EXPECTED:
        return None
    actual = extract_final(section)
    mem = extract_memdump(section)
    spec = EXPECTED[test_num]
    fails = []
    for k, exp in spec.get('regs', {}).items():
        got = actual.get(k)
        if got is None:
            fails.append(f"{k}: not found")
        elif got != exp:
            if k in ('z', 'c', 'i'):
                fails.append(f"{k} flag: expected {exp}, got {got}")
            else:
                fails.append(f"{k}: expected 0x{exp:08X}, got 0x{got:08X}")
    for addr, ebytes in spec['mem']:
        for i, eb in enumerate(ebytes):
            got = mem.get(addr + i)
            if got is None:
                fails.append(f"mem[0x{addr+i:03X}]: not found")
            elif got != eb:
                fails.append(f"mem[0x{addr+i:03X}]: expected 0x{eb:02X}, got 0x{got:02X}")
    if 'pipe' in spec:
        stats = extract_pipe(section)
        if stats is not None:                       # only on the pipelined core
            for k, exp in spec['pipe'].items():
                if stats[k] != exp:
                    fails.append(f"pipeline {k} stall cycles: expected {exp}, got {stats[k]}")
    if 'screen' in spec:
        screen = extract_screen(section)
        for row, text in spec['screen']:
            got = screen.get(row)
            if got != text:
                fails.append(f"screen row {row}: expected {text!r}, got {got!r}")
    if 'disk' in spec:
        disk = read_disk(test_num)
        if disk is None:
            fails.append("disk image: build/%d_disk_out.hex not found" % test_num)
        else:
            for off, ebytes in spec['disk']:
                if disk[off:off + len(ebytes)] != ebytes:
                    fails.append(f"disk[0x{off:04X}]: expected {bytes(ebytes)!r}, "
                                 f"got {bytes(disk[off:off + len(ebytes)])!r}")
    return fails


def main():
    sections = parse_tests_txt()
    all_pass = True
    for n in sorted(sections):
        fails = verify(n, sections[n])
        if fails is None:
            print(f"Test {n:2d}: SKIP")
            continue
        if fails:
            all_pass = False
            print(f"Test {n:2d}: {len(fails)} FAIL(s)")
            for f in fails:
                print(f"   - {f}")
        else:
            print(f"Test {n:2d}: OK")
    print()
    print("ALL TESTS PASS" if all_pass else "SOME TESTS FAILED")
    return 0 if all_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
