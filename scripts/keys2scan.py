#!/usr/bin/env python3
"""
Turn typed text into a PC keyboard script for tb_pc (batch / test runs).

Each character becomes the genuine scan codes (set 1, as read from port 0x60)
a PC keyboard sends: the make code on press, make|0x80 on release, wrapped in
Left-Shift make (0x2A) / break (0xAA) for shifted characters -- the same
mapping scripts/pc_host.c uses for live typing.

Output: one "<cycle> <hex byte>" line per scan code, GAP cycles apart.

  usage:  keys2scan.py "Hi there!\\n" [--start 3000] [--gap 1500] > keys.txt
          keys2scan.py --from-asm prog.asm ...   (text from a '; KEYS:' line)
          keys2scan.py --squeeze build/pc_keys.log [--max-gap 4000]
              re-time a live session's key log: the same scan codes in the same
              order, but the long idle stretches (a human typing = ~1M cycles
              of HLT between keys) are cut to --max-gap cycles, so a replay
              with waveforms stays small.

Escapes in the text: \\n Enter, \\b Backspace, \\t Tab, \\e Esc, \\\\ backslash.
"""
import argparse
import re
import sys

SC, SHIFT = {}, set()


def _map(keys, shifted, first):
    for i, k in enumerate(keys):
        SC[k] = first + i
        if shifted and shifted[i] != " ":
            SC[shifted[i]] = first + i
            SHIFT.add(shifted[i])


_map("1234567890-=", "!@#$%^&*()_+", 0x02)
_map("qwertyuiop[]", "QWERTYUIOP{}", 0x10)
_map("asdfghjkl;'`", 'ASDFGHJKL:"~', 0x1E)
_map("\\zxcvbnm,./", "|ZXCVBNM<>?", 0x2B)
SC.update({" ": 0x39, "\n": 0x1C, "\t": 0x0F, "\b": 0x0E, "\x1b": 0x01})


def unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            out.append({"n": "\n", "b": "\b", "t": "\t", "e": "\x1b",
                        "\\": "\\"}.get(s[i + 1], s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def scancodes(text):
    codes = []
    for ch in text:
        if ch not in SC:
            sys.exit(f"keys2scan: no key for {ch!r}")
        make = SC[ch]
        if ch in SHIFT:
            codes += [0x2A, make, make | 0x80, 0xAA]
        else:
            codes += [make, make | 0x80]
    return codes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("text", nargs="?", default="")
    ap.add_argument("--from-asm", help="take the text from a '; KEYS:' line")
    ap.add_argument("--start", type=int, default=3000, help="cycle of the first scan code")
    ap.add_argument("--gap", type=int, default=1500, help="cycles between scan codes")
    ap.add_argument("--squeeze", help="live key log to re-time")
    ap.add_argument("--max-gap", type=int, default=4000)
    a = ap.parse_args()
    if a.squeeze:
        prev_old = prev_new = None
        with open(a.squeeze) as f:
            for line in f:
                p = line.split()
                if len(p) != 2:
                    continue
                old = int(p[0])
                if prev_old is None:
                    new = min(old, a.start)
                else:
                    new = prev_new + min(old - prev_old, a.max_gap)
                print(f"{new} {p[1].upper()}")
                prev_old, prev_new = old, new
        return
    text = a.text
    if a.from_asm:
        text = ""
        with open(a.from_asm) as f:
            for line in f:
                m = re.match(r"\s*;\s*KEYS:\s?(.*?)\s*$", line)
                if m:
                    text = m.group(1)
                    break
    for i, c in enumerate(scancodes(unescape(text))):
        print(f"{a.start + i * a.gap} {c:02X}")


if __name__ == "__main__":
    main()
