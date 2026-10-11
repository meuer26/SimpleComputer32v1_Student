#!/usr/bin/env python3
"""Run ONE program on the teaching PC under several machine configurations and
tabulate the measured CPI report for each, so students can see -- side by side --
how dual-issue, branch prediction, and the cache change performance.

    usage: cpi_compare.py <program.hex> [disk.hex]

Each row is produced by a real batch simulation (scripts/run_sim.sh --pc --batch);
the numbers are the core's own hardware counters, identical to the live CPI
report window.  Instructions = retire pulses + co-issued U/V pairs (the true
dynamic count, so rows are comparable whether or not the program dual-issues).
"""
import os, re, sys, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEX  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "sort_O0.hex")
DISK = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "build", "pc_disk.hex")
BUILD = os.path.join(ROOT, "build")
KEYS = os.path.join(BUILD, "empty_keys.txt")
open(KEYS, "w").close()

# (label, extra CFG_* env).  The first row is the default machine.
CONFIGS = [
    ("default (super, BTB, L1 4x2x8)", {}),
    ("scalar (no dual-issue)",         {"CFG_DUAL": "false"}),
    ("non-pipelined",                  {"CFG_DUAL": "false", "CFG_SERIAL": "true"}),
    ("no branch prediction",           {"CFG_BTB": "false"}),
    ("no cache",                       {"CFG_CACHE": "false"}),
    ("tiny L1 (1 set,1 way,1 word)",   {"CFG_SETS": "1", "CFG_WAYS": "1", "CFG_LINE": "1"}),
    ("big L1 (8 sets,4 way,16 word)",  {"CFG_SETS": "8", "CFG_WAYS": "4", "CFG_LINE": "16"}),
]

NUM = lambda p, t, d=0: (lambda m: int(m.group(1)) if m else d)(re.search(p, t))


def run(env_extra):
    env = dict(os.environ, **env_extra)
    subprocess.run([os.path.join(ROOT, "scripts", "run_sim.sh"), "--pc", "--batch",
                    "--disk=" + DISK, "--keys=" + KEYS, HEX],
                   cwd=ROOT, env=env, stdout=open(BUILD + "/cmp.txt", "w"),
                   stderr=subprocess.STDOUT)
    t = open(BUILD + "/cmp.txt").read()
    cyc   = NUM(r"Cycles\s*=\s*(\d+)", t)
    instr = NUM(r"Instructions retired\s*=\s*(\d+)", t)
    pairs = NUM(r"U/V pairs issued\s*=\s*(\d+)", t)
    halt  = NUM(r"halted=(\d+)", t)
    micro = NUM(r"microcode=(\d+)", t); agi = NUM(r"AGI=(\d+)", t)
    br    = NUM(r"branch=(\d+)", t);    qe = NUM(r"queue-empty=(\d+)", t)
    mw    = NUM(r"mem-wait=(\d+)", t);  bb = NUM(r"bus-busy=(\d+)", t)
    ich   = NUM(r"I-cache hits/misses = (\d+)", t); icm = NUM(r"misses = \d+ / (\d+)", t)
    m = re.search(r"D-cache hits/misses = (\d+) / (\d+)", t)
    dch, dcm = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    ninsn = instr + pairs
    active = max(1, cyc - halt)
    cpi = active / ninsn if ninsn else 0
    dacc = dch + dcm
    amat = 1 + mw / dacc if dacc else 1
    iacc = ich + icm
    btot = NUM(r"correct = (\d+)", t) + NUM(r"mispredicted = (\d+)", t)
    btbok = NUM(r"correct = (\d+)", t)
    pct = lambda n, d: (100.0 * n / d) if d else 0.0
    return dict(ninsn=ninsn, active=active, cpi=cpi, pairs=pairs,
                i_hit=pct(ich, iacc), d_hit=pct(dch, dacc), amat=amat,
                btb=pct(btbok, btot),
                stalls=dict(microcode=micro, AGI=agi, branch=br,
                            qempty=qe, memwait=mw, busbusy=bb))


def main():
    print(f"\nProgram: {os.path.basename(HEX)}   (same binary, varied machine)\n")
    hdr = f"{'configuration':<32}{'instrs':>7}{'cycles':>8}{'CPI':>7}{'pairs':>6}" \
          f"{'I$hit':>7}{'D$hit':>7}{'AMAT':>6}{'BTB':>6}   dominant stall"
    print(hdr); print("-" * len(hdr))
    for label, env in CONFIGS:
        r = run(env)
        dom = max(r["stalls"].items(), key=lambda kv: kv[1])
        dom_s = f"{dom[0]} ({dom[1]})" if dom[1] else "-"
        print(f"{label:<32}{r['ninsn']:>7}{r['active']:>8}{r['cpi']:>7.2f}{r['pairs']:>6}"
              f"{r['i_hit']:>6.1f}%{r['d_hit']:>6.1f}%{r['amat']:>6.2f}{r['btb']:>5.0f}%   {dom_s}")
    print()


if __name__ == "__main__":
    main()
