#!/usr/bin/env python3
"""
Validate the SPLIT instruction/data caches against an independent Python model.

We replay each test's address bus (the ADDR / REQ / IF / WE fields the testbench
prints every cycle) through a software model of the Pentium's two caches -- a
read-only instruction cache and a write-back/write-allocate data cache, each
2-way set-associative with true-LRU -- and confirm the model's per-cache
hit / miss / writeback counts (and self-modifying-code invalidations) match the
counts the VHDL reported. Agreement across all tests cross-checks the RTL
against a known-good reference.

Each access is routed to the I-cache (IF=1, an instruction fetch) or the D-cache
(IF=0, a load/store). A store that hits a line also present in the I-cache
invalidates that I-line -- the SMC (code/data) coherence snoop.

Reads build/tests.txt (produced by `make cache`).
"""

import re
import os

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS_TXT = os.path.join(HERE, "..", "build", "tests.txt")


def clog2(n):
    r, v = 0, 1
    while v < n:
        v *= 2
        r += 1
    return r


class Cache:
    """One cache: SETS x WAYS, WORDS/line, true-LRU, write-back/allocate.

    Mirrors the RTL: each set keeps a per-way age rank (0 = MRU, WAYS-1 = LRU)
    seeded to 0..WAYS-1; on a touch the accessed way becomes MRU and younger
    ways age by one; the victim is the lowest-index invalid way, else the LRU.
    """

    def __init__(self, sets, ways, words):
        self.SETS, self.WAYS, self.WORDS = sets, ways, words
        self.idx_shift = 2 + clog2(words)
        self.tag_shift = 2 + clog2(words) + clog2(sets)
        self.tag   = [[None] * ways for _ in range(sets)]
        self.valid = [[False] * ways for _ in range(sets)]
        self.dirty = [[False] * ways for _ in range(sets)]
        self.age   = [list(range(ways)) for _ in range(sets)]
        self.hits = 0
        self.misses = 0
        self.writebacks = 0

    def _touch(self, idx, w):
        old = self.age[idx][w]
        for k in range(self.WAYS):
            if k == w:
                self.age[idx][k] = 0
            elif self.age[idx][k] < old:
                self.age[idx][k] += 1

    def access(self, addr, we):
        idx = (addr >> self.idx_shift) & (self.SETS - 1)
        tag = addr >> self.tag_shift
        for w in range(self.WAYS):
            if self.valid[idx][w] and self.tag[idx][w] == tag:
                self.hits += 1
                if we:
                    self.dirty[idx][w] = True
                self._touch(idx, w)
                return
        self.misses += 1
        v = None
        for w in range(self.WAYS):
            if not self.valid[idx][w]:
                v = w
                break
        if v is None:
            v = max(range(self.WAYS), key=lambda w: self.age[idx][w])
        if self.valid[idx][v] and self.dirty[idx][v]:
            self.writebacks += 1
        self.tag[idx][v] = tag
        self.valid[idx][v] = True
        self.dirty[idx][v] = we
        self._touch(idx, v)

    def invalidate(self, addr):
        """SMC snoop: drop the line holding `addr` if present. Returns True if hit."""
        idx = (addr >> self.idx_shift) & (self.SETS - 1)
        tag = addr >> self.tag_shift
        for w in range(self.WAYS):
            if self.valid[idx][w] and self.tag[idx][w] == tag:
                self.valid[idx][w] = False
                return True
        return False


TRACE_RE = re.compile(r"ADDR=0x([0-9A-Fa-f]+)\s+REQ='([01])'\s+IF='([01])'.*?\$='([01])'")
WE_RE    = re.compile(r"WE='([01])'")
GEOM_RE  = re.compile(r"split I/D, each sets=(\d+)\s+ways=(\d+)\s+words=(\d+)")


def geometry(section):
    m = GEOM_RE.search(section)
    if m:
        return int(m.group(1)), int(m.group(2)), int(m.group(3))
    return 4, 2, 8      # the fixed Pentium-faithful split geometry


def replay(section):
    sets, ways, words = geometry(section)
    ic = Cache(sets, ways, words)      # instruction cache (read-only)
    dc = Cache(sets, ways, words)      # data cache (write-back)
    smc = 0
    # A CPU access COMPLETES on cycles with REQ=1 and the cache ready ($=1).
    # Replaying only those reproduces the exact completed-access sequence.
    for line in section.splitlines():
        m = TRACE_RE.search(line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        req, iff, hit = m.group(2), m.group(3), m.group(4)
        if req == '1' and hit == '1':
            wem = WE_RE.search(line)
            we = (wem.group(1) == '1') if wem else False
            if iff == '1':
                ic.access(addr, False)
            else:
                dc.access(addr, we)
                if we and ic.invalidate(addr):   # store into cached code -> SMC snoop
                    smc += 1
    return ic, dc, smc


def printed(section):
    def grab(pat):
        m = re.search(pat, section)
        return int(m.group(1)) if m else None
    ih = grab(r'I-cache hits/misses\s*=\s*(\d+)')
    im = grab(r'I-cache hits/misses\s*=\s*\d+\s*/\s*(\d+)')
    dh = grab(r'D-cache hits/misses\s*=\s*(\d+)')
    dm = grab(r'D-cache hits/misses\s*=\s*\d+\s*/\s*(\d+)')
    wb = grab(r'writebacks\s*=\s*(\d+)')
    smc = grab(r'SMC I-invalidations\s*=\s*(\d+)')
    return ih, im, dh, dm, wb, smc


def main():
    with open(TESTS_TXT) as f:
        text = f.read()
    parts = re.split(r'==> Test program: (\d+)_test\.hex', text)
    all_ok = True
    for i in range(1, len(parts), 2):
        n = int(parts[i])
        sec = parts[i + 1]
        if 'split I/D' not in sec:        # not a split-cache run; skip
            continue
        ic, dc, smc = replay(sec)
        pih, pim, pdh, pdm, pwb, psmc = printed(sec)
        ok = (pih == ic.hits and pim == ic.misses and
              pdh == dc.hits and pdm == dc.misses and
              pwb == dc.writebacks and psmc == smc)
        all_ok = all_ok and ok
        print(f"Test {n:2d}: I h={pih}/m={pim}  D h={pdh}/m={pdm} wb={pwb}  SMC={psmc} "
              f"| model I {ic.hits}/{ic.misses} D {dc.hits}/{dc.misses} wb={dc.writebacks} SMC={smc} "
              f" {'OK' if ok else 'MISMATCH'}")
    print()
    print("CACHE MODEL MATCHES RTL" if all_ok else "CACHE MODEL MISMATCH")
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
