#!/usr/bin/env python3
"""
pc_view.py -- live viewer windows for the teaching PC (`make pc` opens them).

  pc_view.py mem  [BUILD_DIR]   RAM as a live hex dump
  pc_view.py vram [BUILD_DIR]   video RAM at 0xB8000 as a live hex dump
  pc_view.py code [BUILD_DIR]   the program's source listing with the line that
                                is executing, the registers, flags and stack
  pc_view.py wave [BUILD_DIR]   a live chronogram (timing diagram) of the CPU,
                                buses and interrupt lines, one sample per clock
  pc_view.py pipe [BUILD_DIR]   the pipeline chart: one row per instruction,
                                one column per clock, the stage it is in

The running simulation (scripts/pc_host.c) publishes its state in the shared
file BUILD_DIR/pc_state.bin; these windows map it and redraw ~15 times a
second. The code window also drives the simulation's speed: real hardware runs
far too fast to watch, so you can slow it down, pause it, and single-step it
one instruction at a time.

Keys (all windows): s step one instruction (pauses first if running),
  c continue, space pause / continue, + / - (or = / _) speed up / slow down, q quit,
  o  pause the machine and open its chronogram -- every cycle from power-on to
     now -- in Surfer (scripts/pc_snapshot.sh); close Surfer, then space resumes.
  mem : Up/Down PgUp/PgDn scroll, Home top, e jump to EIP, k jump to ESP (stack),
        w follow the latest write
  vram: Up/Down PgUp/PgDn scroll, Home top, w follow the latest write
  wave: z / x zoom in / out, Left/Right scroll back/forth in time (auto-freezes),
        f freeze,
  code: Up/Down PgUp/PgDn Home/End scroll the listing while the machine is
        paused (the registers stay put); it follows EIP whenever the machine
        runs or steps; e jumps back to EIP; Left/Right also slow down / speed up;
        presets 0 full speed, 1 = 10, 2 = 100, 3 = 1k, 4 = 5k, 5 = 20k cycles/s
        (a typed character costs ~1,500 cycles, so 5k/s keeps up with typing)
"""
import curses
import locale
import mmap
import os
import re
import shutil
import struct
import subprocess
import sys
import time

SIZE, RAM, VRAM = 8320, 128, 4224        # header + RAM + video RAM
WCNT, WAVE, WAVE_N, WAVE_SZ = 8320, 8448, 4096, 72   # chronogram sample ring (64 B + V pipe)
STAGES = ("D1", "D2", "EX", "WB")         # valid bits 8, 4, 2, 1
STALLS = ["", "MICROCODE", "AGI", "BRANCH", "QUEUE EMPTY", "MEM WAIT", "BUS BUSY", "HALT"]
RING_END = WAVE + WAVE_N * WAVE_SZ        # end of the chronogram ring
READ = RING_END                           # u32 memory-read bus address, u32 read class
CR3  = READ + 8                           # u32 CR3 (page-table base)
# Appended blocks (see pc_host.c): a system/SMP/cache/paging block and the AP's
# own pipeline sample ring. Strictly after the original layout.
SYS     = CR3 + 4                          # 128-byte system block
AP_WCNT = SYS + 88                         # AP wave-ring sample counter (within SYS)
WAVEAP   = SYS + 128                       # AP pipeline sample ring (same records)
CACHE    = WAVEAP + WAVE_N * WAVE_SZ        # core-0 cache contents: D 256B, I 256B, D meta 8B, I meta 8B
BTB      = CACHE + 576                      # both cores' BTB contents: 72 B each
CACHE_HB = SYS + 92                         # cache-window heartbeat (ask the sim to dump the cache)
BTB_HB   = SYS + 96                         # BTB-window heartbeat
PERF     = BTB + 256                        # CPI-report counters (0..44) + config (48..)
FULL = PERF + 128                           # total mapped size
RAM_SIZE = 4096
FADE = 1.5                      # seconds a fresh write / executed line stays lit
SPEEDS = {ord('0'): 0, ord('1'): 10, ord('2'): 100, ord('3'): 1000,
          ord('4'): 5000, ord('5'): 20000}
# + / - walk this 1-2-5 ladder of cycles per second; 0 = full speed (the top).
LADDER = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000,
          10000, 20000, 50000, 0]
REGS = ["EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI"]
FLAGS = [(0, "CF"), (2, "PF"), (4, "AF"), (6, "ZF"), (7, "SF"), (9, "IF"), (11, "OF")]


def state_name(raw):
    """The CPU FSM state name (12 chars travel in the shared file)."""
    name = raw.split(b"\0")[0].decode("ascii", "replace").strip()
    return "FETCH_OPERAND" if name == "FETCH_OPERAN" else name


class Shared:
    """The simulation's published state (see the layout in scripts/pc_host.c)."""

    def __init__(self, build):
        self.path = os.path.join(build, "pc_state.bin")
        self.mm = None

    def ready(self):
        if self.mm is None:
            try:
                if os.path.getsize(self.path) < FULL:
                    return False
                with open(self.path, "r+b") as f:
                    self.mm = mmap.mmap(f.fileno(), FULL)
            except OSError:
                return False
        return self.mm[:4] == b"PCV1"

    def read(self):
        b = bytes(self.mm[:SIZE])
        u = lambda off: struct.unpack_from("<I", b, off)[0]
        return {
            "session": u(4), "running": u(8),
            "cycle": struct.unpack_from("<Q", b, 16)[0],
            "regs": [u(24 + 4 * i) for i in range(8)],
            "eip": u(56), "eflags": u(60), "halted": u(64), "irqs": u(68),
            "ivt": u(72), "lastw": u(76), "post": u(80),
            "speed": u(84), "paused": u(88), "step": u(92),
            "state": state_name(b[96:112]),
            "stage": dict(zip(STAGES, struct.unpack_from("<4H", b, 116))),
            "valid": b[124], "stall": b[125], "pq": b[126],
            "ram": b[RAM:RAM + RAM_SIZE], "vram": b[VRAM:VRAM + 4096],
            # current 32-bit memory-read cycle (aligned bus address + read class)
            "rd_addr": struct.unpack_from("<I", self.mm, READ)[0],
            "rd_read": struct.unpack_from("<I", self.mm, READ + 4)[0],
            "cr3": struct.unpack_from("<I", self.mm, CR3)[0],
        }

    def write32(self, off, value):
        struct.pack_into("<I", self.mm, off, value)

    def _ring(self, base, cnt_off):
        """A per-cycle sample ring, oldest first (shared by the BSP and AP)."""
        n = struct.unpack_from("<I", self.mm, cnt_off)[0]
        ring = bytes(self.mm[base:base + WAVE_N * WAVE_SZ])
        out = []
        for k in range(max(0, n - WAVE_N), n):
            r = struct.unpack_from("<5IH6B12s8H3BxIHHB", ring, (k % WAVE_N) * WAVE_SZ)
            out.append({"cycle": r[0], "eip": r[1], "addr": r[2], "data": r[3], "eax": r[4],
                        "port": r[5], "iodata": r[6], "bits": r[7], "irq": r[8],
                        "vector": r[9], "isr": r[10], "irr": r[11],
                        "state": state_name(r[12]),
                        "at": dict(zip(STAGES, r[13:17])),    # stage -> instruction address
                        "seq": dict(zip(STAGES, r[17:21])),   # stage -> program-order tag
                        "valid": r[21], "stall": r[22], "pq": r[23], "pf": r[24],
                        # the V-pipe instruction co-issued with EX this cycle (if any)
                        "v_eip": r[25], "v_seq": r[26], "v_valid": r[27]})
        return out

    def samples(self):
        """The BSP's chronogram/pipeline ring."""
        return self._ring(WAVE, WCNT)

    def samples_ap(self):
        """The AP's pipeline ring (second core)."""
        return self._ring(WAVEAP, AP_WCNT)

    def read_sys(self):
        """The appended system block: BSP pairs, the AP core, cache + paging."""
        u = lambda off: struct.unpack_from("<I", self.mm, SYS + off)[0]
        return {
            "v_valid": u(0), "pairs": u(4),
            "ap_pc": u(8), "ap_halted": u(12), "ap_stage": u(16), "ap_vvalid": u(20),
            "ap_state": state_name(bytes(self.mm[SYS + 24:SYS + 36])),
            "ic_hits": u(36), "ic_miss": u(40), "dc_hits": u(44), "dc_miss": u(48),
            "inval": u(52), "wb": u(56), "c0st": u(60), "c1st": u(64), "grant": u(68),
            "trans": u(72), "walks": u(76), "faults": u(80), "cr2": u(84),
        }

    def read_perf(self):
        """CPI-report counters: instructions retired, the eight stall-cause cycle
        buckets, BTB correct/mispredicted, and the running U/V pair count."""
        u = lambda off: struct.unpack_from("<I", self.mm, PERF + off)[0]
        stalls = [u(4 + 4 * i) for i in range(8)]   # 0 none .. 7 halted
        return {
            "instret": u(0),
            "stalls": stalls,
            "btb_ok": u(36), "btb_bad": u(40), "pairs": u(44),
            # active machine configuration (see host_config)
            "dual": u(48), "serial": u(52), "btb_on": u(56), "cache_on": u(60),
            "sets": u(64), "ways": u(68), "line": u(72),
        }


def step_speed(sh, current, direction):
    """Move one rung up (+1, faster) or down (-1, slower) the speed ladder."""
    rungs = LADDER[:-1]                         # the finite speeds
    if current == 0:                            # full speed
        new = 0 if direction > 0 else rungs[-1]
    elif direction > 0:                         # next rung above (or full speed)
        new = next((v for v in rungs if v > current), 0)
    else:                                       # next rung below (floor: 1/s)
        new = next((v for v in reversed(rungs) if v < current), rungs[0])
    sh.write32(84, new)


class Rate:
    """Measured simulation speed (cycles per wall-clock second)."""

    def __init__(self):
        self.t, self.c, self.rate = None, None, 0.0

    def update(self, cycle):
        now = time.time()
        if self.t is None or cycle < self.c:
            self.t, self.c = now, cycle
        elif now - self.t >= 0.5:
            self.rate = (cycle - self.c) / (now - self.t)
            self.t, self.c = now, cycle
        return self.rate


def speed_text(s, rate):
    if s["paused"]:
        return "PAUSED -- s step, c continue"
    want = "full speed" if s["speed"] == 0 else f"{s['speed']:,}/s"
    return f"speed {want} (actual {rate:,.0f} cycles/s)"


def pause(sh):
    """Stop the machine at the next instruction boundary (like a debugger)."""
    sh.write32(92, 2)               # run on to the end of the current instruction...
    sh.write32(88, 1)               # ...and hold there (at once if already at one)


def speed_keys(c, sh, s):
    """Keys every window shares: run control and speed. True if handled."""
    if c == ord('s'):               # step one instruction (a running machine stops first)
        if s["paused"]:
            sh.write32(92, 1)
        else:
            pause(sh)
    elif c == ord('c'):             # continue
        sh.write32(92, 0)
        sh.write32(88, 0)
    elif c == ord(' '):             # pause / continue
        if s["paused"]:
            sh.write32(88, 0)
        else:
            pause(sh)
    elif c in (ord('+'), ord('=')):
        step_speed(sh, s["speed"], +1)
    elif c in (ord('-'), ord('_')):
        step_speed(sh, s["speed"], -1)
    else:
        return False
    return True


class Snapshot:
    """`o`: pause, rebuild the chronogram up to now, open it in Surfer."""

    def __init__(self, build):
        self.build, self.proc, self.cycle, self.t0 = build, None, 0, 0

    def start(self, sh):
        if self.proc is not None and self.proc.poll() is None:
            return                                  # one Surfer at a time
        pause(sh)                                   # stop at an instruction boundary
        last = None
        for _ in range(60):                         # until the cycle count settles
            time.sleep(0.05)
            c = sh.read()["cycle"]
            if c == last:
                break
            last = c
        self.cycle, self.t0 = last, time.time()
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pc_snapshot.sh")
        self.proc = subprocess.Popen([script, self.build, str(last)], stdin=subprocess.DEVNULL,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     start_new_session=True)

    def dismiss(self):
        """Drop the 'Surfer closed' prompt once the user resumes/steps. Only
        after Surfer has actually exited -- while it is still open the banner is
        live status, so a keypress should not clear it."""
        if self.proc is not None and self.proc.poll() is not None:
            self.proc = None

    def status(self):
        if self.proc is None:
            return None
        rc = self.proc.poll()
        if rc is None:
            try:
                ready = os.path.getmtime(os.path.join(self.build, "pc_snapshot.vcd")) >= self.t0
            except OSError:
                ready = False
            what = "Surfer is open" if ready else "rebuilding the chronogram"
            return (f" SURFER: cycles 0..{self.cycle:,} -- {what}. Machine paused: "
                    f"s step, c continue. ")
        if rc != 0:
            return f" SURFER failed (exit {rc}) -- see build/pc_snapshot.log. c continues. "
        return " Surfer closed -- machine paused: s step, c continue. "

    def draw(self, scr):
        msg = self.status()
        if msg:
            h, w = scr.getmaxyx()
            put(scr, h - 2, 0, msg.ljust(w), curses.color_pair(7) | curses.A_REVERSE)


def setup_colors():
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_YELLOW)   # fresh write
    curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_CYAN)     # EIP
    curses.init_pair(3, curses.COLOR_BLACK, curses.COLOR_MAGENTA)  # stack top
    curses.init_pair(4, curses.COLOR_BLACK, curses.COLOR_GREEN)    # current line
    curses.init_pair(5, curses.COLOR_GREEN, -1)                    # recently run
    curses.init_pair(6, curses.COLOR_CYAN, -1)                     # labels
    curses.init_pair(7, curses.COLOR_YELLOW, -1)                   # warnings
    curses.init_pair(8, curses.COLOR_BLUE, -1)                     # comments
    curses.init_pair(9, curses.COLOR_RED, -1)                      # flushed
    curses.init_pair(10, curses.COLOR_BLACK, curses.COLOR_BLUE)    # instruction prefetch/fetch
    curses.init_pair(11, curses.COLOR_BLACK, curses.COLOR_GREEN)   # program data read


def put(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if 0 <= y < h and x < w:
        try:
            win.addnstr(y, x, text, max(0, w - x - 1), attr)
        except curses.error:
            pass


def put_wrapped(win, bottom, text, attr=0):
    """Word-wrap `text` (items separated by runs of 2+ spaces) to the window
    width and draw it so the LAST line sits on row `bottom`, wrapping upward.
    Returns the top row used, so stacked footers don't overlap. This keeps the
    bottom legends readable at any terminal geometry instead of truncating."""
    h, w = win.getmaxyx()
    width = max(1, w - 2)
    lines, cur = [], ""
    for it in re.split(r"\s{2,}", text.strip()):
        cand = it if not cur else cur + "  " + it
        if len(cand) <= width:
            cur = cand
        else:
            if cur:
                lines.append(cur)
            cur = it
    if cur:
        lines.append(cur)
    lines = lines or [""]
    top = max(0, bottom - len(lines) + 1)
    for i, ln in enumerate(lines):
        put(win, top + i, 0, " " + ln, attr)
    return top


def waiting(win, sh):
    win.erase()
    put(win, 1, 2, "Teaching PC viewer -- waiting for a live session...", curses.A_BOLD)
    put(win, 3, 2, f"(start it with `make pc`; state file: {sh.path})")
    put(win, 5, 2, "q quits")
    win.refresh()


def banner(win, s):
    if s["running"] == 2:
        put(win, 0, 0, " SESSION ENDED -- q closes; a new `make pc` is picked up here ".ljust(200),
            curses.color_pair(7) | curses.A_REVERSE)


# ----------------------------------------------------------------- memory view
def mem_view(scr, sh, snap, vmode=False):
    """RAM (vmode False) or the VGA text buffer at 0xB8000 (vmode True)."""
    top, follow = 0, vmode
    prev, lit, session = None, {}, None
    rate = Rate()
    while True:
        if not sh.ready():
            waiting(scr, sh)
            if scr.getch() == ord('q'):
                return
            continue
        s = sh.read()
        if s["session"] != session:                 # a new `make pc` run
            session, prev, lit = s["session"], None, {}
        data = s["vram"][:4000] if vmode else s["ram"]   # 80x25 cells x 2 bytes
        now = time.time()
        if prev is not None and len(prev) == len(data):
            for i in range(len(data)):
                if data[i] != prev[i]:
                    lit[i] = now
        prev = data
        lit = {i: t for i, t in lit.items() if now - t < FADE}

        h, w = scr.getmaxyx()
        rows = max(1, h - 4)
        nrows = len(data) // 16
        newest = max(lit, key=lit.get) if lit else None
        if follow and (newest is not None or not vmode):
            r = (newest if vmode else s["lastw"] & 0xFFF) // 16
            if not top <= r < top + rows:
                top = max(0, r - rows // 2)
        top = max(0, min(top, nrows - rows))
        eip, esp = s["eip"], s["regs"][4]
        # The cache<->RAM bus beat in flight: a line fill / writeback moves one
        # aligned 32-bit word per cycle over the 32-bit data bus, so light that
        # whole word, colour-coded by what the bus is doing. On a cache HIT the
        # bus is idle (nothing reaches RAM). rd_read: 1 data-fill (green),
        # 2 ifetch-fill (blue), 3 writeback (yellow).
        rd_on = (not vmode) and s["rd_read"] and s["rd_addr"] < RAM_SIZE
        rd_lo = s["rd_addr"] & ~3
        rd_pair = {1: 11, 2: 10, 3: 1}.get(s["rd_read"], 11)   # green / blue / yellow

        scr.erase()
        if vmode:
            head = " VIDEO RAM  0xB8000-0xB8F9F  80x25 cells: character byte, attribute byte"
        else:
            head = f" MEMORY  RAM 0x000-0xFFF   last write 0x{s['lastw'] & 0xFFF:03X}"
        put(scr, 0, 0, f"{head}   cycle {s['cycle']:,}{'   [follow]' if follow else ''}   "
                       f"{speed_text(s, rate.update(s['cycle']))} ".ljust(w), curses.A_REVERSE)
        banner(scr, s)
        for r in range(rows):
            row = top + r
            if row >= nrows:
                break
            base = row * 16
            y = r + 1
            put(scr, y, 0, f"{0xB8000 + base:05X}" if vmode else f"0x{base:03X}",
                curses.color_pair(6))
            for i in range(16):
                a = base + i
                attr = 0
                if not vmode and a == eip:
                    attr = curses.color_pair(2)
                elif rd_on and rd_lo <= a < rd_lo + 4:
                    attr = curses.color_pair(rd_pair)
                elif not vmode and esp <= a < esp + 4:
                    attr = curses.color_pair(3)
                elif a in lit:
                    attr = curses.color_pair(1)
                put(scr, y, 7 + 3 * i + (1 if i >= 8 else 0), f"{data[a]:02X}", attr)
            text = "".join(chr(c) if 32 <= c < 127 else "." for c in data[base:base + 16])
            put(scr, y, 7 + 49, "|" + text + "|")
        keys_top = put_wrapped(scr, h - 1,
            "s step  c continue  space pause  o Surfer  +/- speed  "
            "Up/Dn PgUp/PgDn Home" + ("" if vmode else "  e EIP  k ESP") +
            "  w follow  q quit", curses.A_DIM)
        cy = keys_top - 1                       # colour chips on the row above the keys
        put(scr, cy, 1, " write/wb ", curses.color_pair(1))
        if not vmode:
            put(scr, cy, 12, " EIP ", curses.color_pair(2))
            put(scr, cy, 18, " [ESP] ", curses.color_pair(3))
            put(scr, cy, 26, " I-fill ", curses.color_pair(10))
            put(scr, cy, 35, " D-fill ", curses.color_pair(11))
        snap.draw(scr)
        scr.refresh()

        c = scr.getch()
        if c == ord('q'):
            return
        if speed_keys(c, sh, s):
            snap.dismiss()          # a resume/step clears the 'Surfer closed' prompt
        elif c == ord('o'):
            snap.start(sh)
        elif c == curses.KEY_DOWN:
            top += 1
        elif c == curses.KEY_UP:
            top -= 1
        elif c == curses.KEY_NPAGE:
            top += rows
        elif c == curses.KEY_PPAGE:
            top -= rows
        elif c == curses.KEY_HOME:
            top = 0
        elif c == ord('e') and not vmode:
            top, follow = max(0, (eip & 0xFFF) // 16 - rows // 2), False
        elif c == ord('k') and not vmode:
            top, follow = max(0, (esp & 0xFFF) // 16 - rows // 2), False
        elif c == ord('w'):
            follow = not follow


# ------------------------------------------------------------------- code view
def load_listing(path):
    """NASM listing -> [(address or None, instruction bytes, source)].

    A long instruction or data line continues on extra listing lines with the
    same line number (its bytes end in '-'); those are merged into one entry.
    NASM brackets relocated fields ([5C020000]) -- the brackets are dropped, so
    the bytes shown are exactly the bytes in memory."""
    out, last_no = [], None
    try:
        with open(path, errors="replace") as f:
            for raw in f:
                raw = raw.rstrip("\n")
                no = raw[0:6].strip()
                if not no.isdigit():
                    continue
                addr, code, src = raw[7:15], raw[16:40].strip(), raw[40:]
                code = code.rstrip("-").replace("[", "").replace("]", "")
                code = code.replace("(", "").replace(")", "")
                if no == last_no and not src.strip() and out:      # continuation
                    a, b, s0 = out[-1]
                    out[-1] = (a, b + code, s0)
                    continue
                last_no = no
                a = int(addr, 16) if re.fullmatch(r"[0-9A-F]{8}", addr) and code else None
                # NASM lists an `align N` directive on the line carrying the NOP
                # padding it emitted; that byte is not an "align" instruction -- it
                # disassembles to `nop` -- so relabel it, keeping the directive as a
                # comment and the source's own indentation so it lines up with the
                # other mnemonics.
                stripped = src.lstrip()
                first = stripped.split(None, 1)[0].lower() if stripped else ""
                if a is not None and code and first == "align":
                    indent = src[:len(src) - len(stripped)]
                    directive = stripped.split(";", 1)[0].strip()
                    src = f"{indent}nop   ; {directive} padding"
                out.append((a, code, src.expandtabs(8)))
    except OSError:
        pass
    return out


BYTES_W = 29                    # room for 10 bytes "C7 05 5C 02 00 00 01 00 00 00"


def fmt_bytes(code):
    """'C7055C020000' -> 'C7 05 5C 02 00 00'; keeps NASM's <rep n> marker."""
    m = re.match(r"([0-9A-F]*)(.*)", code)
    hexpart, rest = m.group(1), m.group(2)
    text = " ".join(hexpart[i:i + 2] for i in range(0, len(hexpart), 2))
    if rest:
        text = (text + " " + rest).strip()
    if len(text) > BYTES_W:
        text = text[:BYTES_W - 1] + "~"
    return text


def line_of(listing, eip):
    best = None
    for i, (a, _, _) in enumerate(listing):
        if a is not None and a <= eip and (best is None or a >= listing[best][0]):
            best = i
    return best


# Keys in the disassembly window that open the other live windows on demand.
# (lowercase, chosen to avoid the shared controls s/c/o/e/q/space and the digit
# speed presets.) The AP-core windows stay reserved for `make pc smp`.
WINKEYS = {ord('p'): ("pipe", "pipeline"), ord('m'): ("mem", "RAM"),
           ord('v'): ("vram", "video"),    ord('w'): ("wave", "chrono"),
           ord('k'): ("cache", "cache"),   ord('t'): ("tlb", "TLB"),
           ord('b'): ("btb", "BTB"),       ord('r'): ("cpi", "CPI report")}


def open_window(mode, build):
    """Spawn one of the other viewer windows in its own terminal, reusing the
    same terminal app `make pc` used. Skips it if one is already open."""
    term = os.environ.get("PC_TERM_APP", "cosmic-term")
    if shutil.which(term) is None:
        return
    try:                                            # already open? don't duplicate
        if subprocess.run(["pgrep", "-f", f"pc_view.py {mode} "],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            return
    except Exception:
        pass
    try:
        subprocess.Popen(
            [term, "-e", "python3", os.path.abspath(__file__), mode, build],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        pass


def code_view(scr, sh, build, snap):
    lst_path = os.path.join(build, "pc_prog.lst")
    listing, mtime, session, ran = [], None, None, {}
    rate = Rate()
    follow, top = True, 0          # follow EIP, or a scrolled position (first line shown)
    rows, seen_cycle = 1, None
    while True:
        if not sh.ready():
            waiting(scr, sh)
            if scr.getch() == ord('q'):
                return
            continue
        try:
            m = os.path.getmtime(lst_path)
        except OSError:
            m = None
        if m != mtime:
            listing, mtime = load_listing(lst_path), m
        s = sh.read()
        # Hold the sample-ring heartbeat so the pipeline/chronogram keep recording
        # in the background -- opening those windows later shows full scrollback.
        sh.write32(112, int(time.time()))
        if s["session"] != session:
            session, ran = s["session"], {}
        now = time.time()
        # Where each pipeline stage is in the listing (D1 decoding, D2 address
        # generation, EX executing, WB retiring). The listing follows EX.
        tags = {}
        for k, st in enumerate(STAGES):
            if s["valid"] & (8 >> k):
                li = line_of(listing, s["stage"][st])
                if li is not None:
                    tags.setdefault(li, st)
        ex_line = line_of(listing, s["stage"]["EX"]) if s["valid"] & 2 else None
        cur = ex_line if ex_line is not None else line_of(listing, s["eip"])
        if cur is not None:
            ran[cur] = now
        ran = {i: t for i, t in ran.items() if now - t < FADE}

        h, w = scr.getmaxyx()
        scr.erase()
        speed = speed_text(s, rate.update(s["cycle"]))
        if s["step"]:
            speed = ("STEP: CPU is in HLT, the next instruction runs after an interrupt"
                     if s["halted"] else "STEP: running to the next instruction")
        put(scr, 0, 0, f" CODE  cycle {s['cycle']:,}   {speed}   IRQs taken {s['irqs']}   "
                       f"POST {s['post']:02X} ".ljust(w), curses.A_REVERSE)
        banner(scr, s)
        fl = "  ".join(f"{n}={(s['eflags'] >> b) & 1}" for b, n in FLAGS)
        state = s["state"] or "?"
        put(scr, 1, 1, f"EIP {s['eip']:08X}   EFLAGS {s['eflags']:08X}  {fl}", curses.A_BOLD)
        put(scr, 2, 1, "   ".join(f"{REGS[i]} {s['regs'][i]:08X}" for i in range(4)))
        put(scr, 3, 1, "   ".join(f"{REGS[i]} {s['regs'][i]:08X}" for i in range(4, 8)))
        put(scr, 4, 1, f"CR3 {s['cr3']:08X}   IDT {s['ivt']:08X}   CPU state: {state:<14}"
                       + ("  (HLT: sleeping until an interrupt)" if s["halted"] else ""),
            curses.color_pair(7) if s["halted"] else 0)

        # stack panel on the right
        side = 30 if w >= 110 else 0
        if side:
            x0 = w - side
            put(scr, 6, x0, "STACK  (ESP ->)", curses.A_BOLD)
            esp = s["regs"][4]
            for k in range(min(16, h - 9)):
                a = esp + 4 * k
                if a + 4 <= RAM_SIZE:
                    v = struct.unpack_from("<I", s["ram"], a)[0]
                    put(scr, 7 + k, x0, f"{a:04X}: {v:08X}",
                        curses.color_pair(3) if k == 0 else 0)

        # source listing around the executing line
        # (the register pane above stays put; only this listing scrolls)
        # Whenever the machine moves -- running, or a single step -- the listing
        # snaps back to the executing line; scrolling holds only while it is still.
        if s["cycle"] != seen_cycle:
            follow, seen_cycle = True, s["cycle"]
        top_y, rows = 6, max(1, h - 8)
        last_top = max(0, len(listing) - rows)
        if follow:
            top = 0 if cur is None else max(0, min(cur - rows // 3, last_top))
        top = max(0, min(top, last_top))
        start = top
        put(scr, 5, 0, (" listing: following EX   stages: EX executing  D2 address  D1 decoding  WB retired"
                        f"   stall: {STALLS[s['stall']] or '-'}" if follow else
                        " listing: scrolled (while paused) -- e, s or c return to EIP").ljust(w - side),
            curses.A_DIM)
        for r in range(rows):
            i = start + r
            if i >= len(listing):
                break
            a, code, src = listing[i]
            addr = f"{a:04X}" if a is not None else "    "
            tag = tags.get(i, "  ")
            text = f"{tag} {addr}  {fmt_bytes(code):<{BYTES_W}}  {src}"
            if i == cur:
                attr = curses.color_pair(4) | curses.A_BOLD
            elif tag in ("D1", "D2"):
                attr = curses.color_pair(6) | curses.A_BOLD
            elif tag == "WB":
                attr = curses.color_pair(5) | curses.A_BOLD
            elif i in ran:
                attr = curses.color_pair(5)
            elif a is None and src.strip().startswith(";"):
                attr = curses.color_pair(8)
            elif a is None and src.strip().endswith(":"):
                attr = curses.color_pair(6)
            else:
                attr = 0
            put(scr, top_y + r, 0, text[: max(1, w - side - 1)].ljust(max(1, w - side - 1)), attr)
        if not listing:
            put(scr, top_y, 1, f"(no listing at {lst_path})", curses.color_pair(7))
        put_wrapped(scr, h - 1,
            "OPEN WINDOW:  p pipeline  m RAM  v video  w chrono  k cache  t TLB  b BTB"
            "  r CPI report        s step  c continue  space pause  o Surfer  "
            "Up/Dn PgUp/PgDn scroll  e follow EIP  +/- or Left/Right speed  q quit",
            curses.A_DIM)
        snap.draw(scr)
        scr.refresh()

        c = scr.getch()
        if c == ord('q'):
            return
        if c in WINKEYS:
            open_window(WINKEYS[c][0], build)       # spawn that viewer in its own terminal
        elif speed_keys(c, sh, s):
            snap.dismiss()          # a resume/step clears the 'Surfer closed' prompt
        elif c == curses.KEY_RIGHT:
            step_speed(sh, s["speed"], +1)
        elif c == curses.KEY_LEFT:
            step_speed(sh, s["speed"], -1)
        elif c in SPEEDS:
            sh.write32(84, SPEEDS[c])
        elif c == ord('o'):
            snap.start(sh)
        elif c in (curses.KEY_UP, curses.KEY_DOWN, curses.KEY_PPAGE, curses.KEY_NPAGE,
                   curses.KEY_HOME, curses.KEY_END):
            follow = False                  # scroll the listing by hand
            top += {curses.KEY_UP: -1, curses.KEY_DOWN: 1, curses.KEY_PPAGE: -rows,
                    curses.KEY_NPAGE: rows, curses.KEY_HOME: -10 ** 6,
                    curses.KEY_END: 10 ** 6}[c]
        elif c == ord('e'):
            follow = True


# ------------------------------------------------------------------ chronogram
# (label, kind, how to get the value). kind: clk; bit (active HIGH: the value is
# the level); bit# (ACTIVE LOW, Intel's `#` suffix as in INTA#, IOR#: the
# function says whether the signal is ASSERTED, and the wire is LOW then);
# hex<n> (a bus, n digits); text.
#
# The bus command strobes are shown as the PC's chipset drives them on the ISA
# bus -- MEMR#, MEMW#, IOR#, IOW#, all active low -- and the 8259's interrupt
# acknowledge input INTA# is active low too. INTR, the ISA IRQ lines and the
# 8042's OBF status bit really are active high.
LABELS = {}                              # address -> source text (set by load_labels)


def load_labels(build):
    """Instruction address -> its source line (from the NASM listing)."""
    LABELS.clear()
    for a, _code, src in load_listing(os.path.join(build, "pc_prog.lst")):
        if a is not None and a not in LABELS:
            LABELS[a] = " ".join(src.split(";")[0].split())


def stage_val(r, st):
    """(sequence tag, text) of the instruction in stage `st`, or a bubble."""
    if not r["valid"] & (8 >> STAGES.index(st)):
        return (None, "")
    a = r["at"][st]
    return (r["seq"][st], LABELS.get(a, f"{a:04X}"))


WAVE_ROWS = [
    ("clk",        "clk",  None),
    ("CPU state",  "text", lambda r: r["state"]),
    ("D1 decode",  "stg",  lambda r: stage_val(r, "D1")),
    ("D2 address", "stg",  lambda r: stage_val(r, "D2")),
    ("EX execute", "stg",  lambda r: stage_val(r, "EX")),
    ("WB retire",  "stg",  lambda r: stage_val(r, "WB")),
    ("bubble",     "text", lambda r: STALLS[r["stall"]]),
    ("EIP",        "hex8", lambda r: r["eip"]),
    ("MEMR#",      "bit#", lambda r: r["bits"] & 1 and not r["bits"] >> 1 & 1),
    ("MEMW#",      "bit#", lambda r: r["bits"] & 1 and r["bits"] >> 1 & 1),
    ("bus addr",   "hex8", lambda r: r["addr"]),
    ("bus data",   "hex8", lambda r: r["data"]),
    ("IOR#",       "bit#", lambda r: r["bits"] >> 2 & 1),
    ("IOW#",       "bit#", lambda r: r["bits"] >> 3 & 1),
    ("io port",    "hex3", lambda r: r["port"]),
    ("io data",    "hex2", lambda r: r["iodata"]),
    ("IRQ1 (kbd)", "bit",  lambda r: r["irq"] & 1),
    ("8042 OBF",   "bit",  lambda r: r["irq"] >> 2 & 1),
    ("IRQ14 disk", "bit",  lambda r: r["irq"] >> 1 & 1),
    ("PIC1 IRR",   "hex2", lambda r: r["irr"]),
    ("PIC1 ISR",   "hex2", lambda r: r["isr"]),
    ("INTR",       "bit",  lambda r: r["bits"] >> 4 & 1),
    ("INTA#",      "bit#", lambda r: r["bits"] >> 5 & 1),
    ("vector",     "hex2", lambda r: r["vector"]),
    ("EAX",        "hex8", lambda r: r["eax"]),
    ("HLT",        "bit",  lambda r: r["bits"] >> 6 & 1),
]
# zoom levels: (columns per cycle, cycles per column). A wide default gives each
# cycle enough room to read the stage rows' instruction text and the full bus
# address/data; zoom IN (z) up to 20 columns/cycle for the longest mnemonics,
# or OUT (x) to pack many cycles in when scanning history.
ZOOMS = [(20, 1), (16, 1), (12, 1), (10, 1), (8, 1), (6, 1), (4, 1), (2, 1),
         (1, 1), (1, 2), (1, 4), (1, 8), (1, 16), (1, 32)]
LABEL_W = 24                            # signal name + its current value


def wave_view(scr, sh, snap):
    zoom, frozen, back, session, seen_cycle = 3, None, 0, None, None   # ZOOMS[3] = 10 cols/cycle
    load_labels(snap.build)
    rate = Rate()
    while True:
        if not sh.ready():
            waiting(scr, sh)
            if scr.getch() == ord('q'):
                return
            continue
        sh.write32(112, int(time.time()))          # heartbeat: keep the samples coming
        s = sh.read()
        if s["session"] != session:
            session, frozen, back = s["session"], None, 0
            load_labels(snap.build)
        if s["cycle"] != seen_cycle:    # the CPU advanced (step/run): snap back to live
            frozen, back, seen_cycle = None, 0, s["cycle"]
        recs = frozen if frozen is not None else sh.samples()

        h, w = scr.getmaxyx()
        gw = max(4, w - LABEL_W - 1)               # graph columns
        cw, per_col = ZOOMS[zoom]                  # columns per slot, cycles per slot
        ncols = gw // cw                           # slots on screen
        end = len(recs) - back * per_col
        end = max(min(end, len(recs)), 0)
        start = max(0, end - ncols * per_col)
        window = recs[start:end]
        slots = [window[i:i + per_col] for i in range(0, len(window), per_col)]

        scr.erase()
        zt = f"{cw} columns per cycle" if per_col == 1 else f"{per_col} cycles per column"
        put(scr, 0, 0, f" CHRONOGRAM  {speed_text(s, rate.update(s['cycle']))}   {zt}"
                       f"{'   FROZEN (f to resume, Left/Right scroll)' if frozen is not None else ''} ".ljust(w),
            curses.A_REVERSE)
        banner(scr, s)
        if not slots:
            put(scr, 2, 1, "no samples yet -- they are recorded while this window is open")
        # time axis
        axis = [" "] * gw
        for i, sl in enumerate(slots):
            x = i * cw
            if i % (10 if cw == 1 else 5) == 0 and x < gw:
                lab = f"|{sl[0]['cycle']}"
                for k, ch in enumerate(lab):
                    if x + k < gw:
                        axis[x + k] = ch
        put(scr, 1, 0, "cycle".ljust(LABEL_W), curses.color_pair(6))
        put(scr, 1, LABEL_W, "".join(axis), curses.color_pair(6))

        for row, (label, kind, get) in enumerate(WAVE_ROWS):
            y = 2 + row
            if y >= h - 1:
                break
            put(scr, y, 0, label[:12], curses.A_BOLD)
            if kind != "clk" and slots:            # value at the right edge (newest shown)
                v = get(slots[-1][-1])
                if kind == "text":
                    cur = v
                elif kind == "stg":
                    cur = v[1] or "(bubble)"
                elif kind == "bit":
                    cur = str(int(bool(v)))
                elif kind == "bit#":                # the wire level: low while asserted
                    cur = "0 active" if v else "1"
                else:
                    cur = f"{v:0{int(kind[3:])}X}"

                put(scr, y, 12, cur[:LABEL_W - 13].rjust(LABEL_W - 13), curses.color_pair(7))
            line, attrs = [], []
            if kind == "clk":
                for sl in slots:
                    line += ["▔"] * (cw // 2) + ["▁"] * (cw - cw // 2) if cw > 1 else ["┃"]
                put(scr, y, LABEL_W, "".join(line)[:gw], curses.color_pair(6))
                continue
            if kind in ("bit", "bit#"):
                for sl in slots:
                    on = any(get(r) for r in sl)   # asserted (a pulse inside a slot still shows)
                    high = on if kind == "bit" else not on      # active low: asserted = low
                    line += ["▔" if high else "▁"] * cw
                    attrs += [curses.color_pair(5) | curses.A_BOLD if on else curses.A_DIM] * cw
                for x, ch in enumerate(line[:gw]):
                    put(scr, y, LABEL_W + x, ch, attrs[x])
                continue
            # buses / text: one segment per run of equal values
            vals = [get(sl[-1]) for sl in slots]
            fmt = ((lambda v: v) if kind == "text" else
                   (lambda v: v[1]) if kind == "stg" else
                   (lambda v: f"{v:X}"))                    # no leading zeros
            x, i = 0, 0
            while i < len(vals):
                j = i
                while j + 1 < len(vals) and vals[j + 1] == vals[i]:
                    j += 1
                width = (j - i + 1) * cw
                seg = "╳" + fmt(vals[i])
                seg = (seg + "─" * width)[:width]
                put(scr, y, LABEL_W + x, seg[: max(0, gw - x)], curses.color_pair(7))
                x += width
                i = j + 1
        keys_top = put_wrapped(scr, h - 1,
            "s step  c continue  space pause  o Surfer  +/- speed  "
            "z/x zoom  Left/Right scroll  f freeze  q quit", curses.A_DIM)
        put_wrapped(scr, keys_top - 1,
            "NAME# = active low (Intel notation): the line is LOW (▁) while asserted.  "
            "Asserted levels are drawn bright.", curses.color_pair(6))
        snap.draw(scr)
        scr.refresh()

        c = scr.getch()
        if c == ord('q'):
            return                                 # leave the ring recording (code window
                                                   # holds the heartbeat; it goes stale on its own)
        if speed_keys(c, sh, s):
            snap.dismiss()          # a resume/step clears the 'Surfer closed' prompt
        elif c == ord('o'):
            snap.start(sh)
        elif c == ord('z'):
            zoom = max(0, zoom - 1)
        elif c == ord('x'):
            zoom = min(len(ZOOMS) - 1, zoom + 1)
        elif c == ord('f'):
            frozen, back = (None, 0) if frozen is not None else (recs, 0)
        elif c == curses.KEY_LEFT:
            if frozen is None:            # auto-freeze so history holds still while scrolling back
                frozen = recs
            back = min(back + max(1, ncols // 4), max(0, len(frozen) - 1))
        elif c == curses.KEY_RIGHT:
            back = max(0, back - max(1, ncols // 4))
            if back == 0 and frozen is not None:
                frozen = None             # scrolled forward to the live edge -> resume live


# --------------------------------------------------------------- pipeline chart
BUBBLE_ABBR = {1: "MC", 2: "AG", 3: "BR", 4: "QE", 5: "MW", 6: "BB", 7: "HL"}
STAGE_ATTR = {}


def pipe_view(scr, sh, snap, samples_fn=None, title=None):
    """The textbook pipeline diagram, live: one row per instruction (in
    program order), one column per clock, the stage it is in. A stage repeated
    in yellow is a stall; xx marks an instruction flushed after a taken branch.

    samples_fn selects the core's ring (BSP by default, or sh.samples_ap for the
    AP's own window). The header also shows the superscalar U/V pair state."""
    samples_fn = samples_fn or sh.samples
    frozen, back, session, seen_cycle = None, 0, None, None
    load_labels(snap.build)
    rate = Rate()
    STAGE_ATTR.update({"D1": curses.color_pair(6), "D2": curses.color_pair(6) | curses.A_BOLD,
                       "EX": curses.color_pair(4) | curses.A_BOLD,
                       "WB": curses.color_pair(5) | curses.A_BOLD,
                       # the V-pipe EX of a co-issued pair: green EX, reversed
                       "V":  curses.color_pair(4) | curses.A_REVERSE | curses.A_BOLD})
    while True:
        if not sh.ready():
            waiting(scr, sh)
            if scr.getch() == ord('q'):
                return
            continue
        sh.write32(112, int(time.time()))          # heartbeat: keep the samples coming
        s = sh.read()
        if s["session"] != session:
            session, frozen, back = s["session"], None, 0
            load_labels(snap.build)
        if s["cycle"] != seen_cycle:    # the CPU advanced (step/run): snap back to live
            frozen, back, seen_cycle = None, 0, s["cycle"]
        recs = frozen if frozen is not None else samples_fn()

        h, w = scr.getmaxyx()
        lbl = 40
        ncols = max(1, (w - lbl - 1) // 3)
        end = max(0, min(len(recs), len(recs) - back))
        win = recs[max(0, end - ncols):end]

        # rows: (program-order tag, address) -> (address, {column: stage}).
        # An instruction gets its tag when it leaves D1, so an instruction
        # flushed while in D1 shares the tag with the one that replaces it --
        # the address tells them apart.
        rows = {}
        for c, r in enumerate(win):
            for k, st in enumerate(STAGES):
                if r["valid"] & (8 >> k):
                    q = (r["seq"][st], r["at"][st])
                    rows.setdefault(q, [r["at"][st], {}])[1][c] = st
            # the V-pipe instruction co-issued this cycle: it reaches EX in the
            # SAME column as the U instruction -> two instructions, one clock.
            # Gate on the U pipe genuinely being in EX with the seq-1 partner:
            # v_valid alone stays asserted through a stall tail (phantom Ex).
            if r.get("v_valid") and (r["valid"] & (8 >> STAGES.index("EX"))) \
                    and r["seq"]["EX"] == (r["v_seq"] - 1) & 0xFFFF:
                q = (r["v_seq"], r["v_eip"])
                rows.setdefault(q, [r["v_eip"], {}])[1][c] = "V"
        all_order = sorted(rows, key=lambda q: (min(rows[q][1]), q[0]))
        # Split the in-flight instructions into the two integer pipes. Every
        # instruction issues through U; the second instruction of a co-issued
        # pair rides V (its row holds only V-cells until we reconstruct it).
        def is_v(q):
            return all(v in ("V", "vD1", "vD2") for v in rows[q][1].values())
        # A V instruction decodes in lock-step with its U partner (seq-1): it
        # sits in D1/D2 the same cycles the partner does and reaches EX the same
        # cycle. So borrow the partner's D1/D2 columns -> a full V-pipe row.
        u_by_seq = {q[0]: rows[q][1] for q in all_order if not is_v(q)}
        for q in all_order:
            if is_v(q):
                partner = u_by_seq.get(q[0] - 1)
                if partner:
                    for c2, st2 in partner.items():
                        if st2 == "D1":
                            rows[q][1][c2] = "vD1"
                        elif st2 == "D2":
                            rows[q][1][c2] = "vD2"
        u_order = [q for q in all_order if not is_v(q)]
        v_order = [q for q in all_order if is_v(q)]

        scr.erase()
        sysr = sh.read_sys()
        if title and "AP" in title:
            uv = f"  co-issue:{'YES' if sysr['ap_vvalid'] else 'no'}"
        else:
            uv = f"  U/V pairs:{sysr['pairs']}{'  <<PAIR CO-ISSUE>>' if sysr['v_valid'] else ''}"
        hdr = title or "PIPELINE CHART (BSP core 0)"
        put(scr, 0, 0, f" {hdr}  D1 decode D2 addr EX exec WB retire{uv}   "
                       f"{speed_text(s, rate.update(s['cycle']))}"
                       f"{'   FROZEN (f resumes, Left/Right scroll)' if frozen is not None else ''} ".ljust(w),
            curses.A_REVERSE)
        banner(scr, s)
        put(scr, 1, 0, "  #  addr instruction".ljust(lbl), curses.color_pair(6))
        for c, r in enumerate(win):
            if c % 5 == 0:
                put(scr, 1, lbl + 3 * c, f"|{r['cycle']}", curses.color_pair(6))

        VCELL = {"vD1": "D1", "vD2": "D2", "V": "Ex"}            # V-pipe cell -> label
        vattr = curses.color_pair(4) | curses.A_REVERSE | curses.A_BOLD

        def render_row(y, q):
            addr, cells = rows[q]
            text = LABELS.get(addr, "")
            put(scr, y, 0, f"{q[0] % 1000:>3}  {addr:04X} {text}"[:lbl - 1].ljust(lbl - 1))
            last, first = max(cells), min(cells)
            reached_ex = any(v in ("EX", "WB", "V") for v in cells.values())
            for c in range(len(win)):
                st = cells.get(c)
                x = lbl + 3 * c
                if st in VCELL:
                    put(scr, y, x, VCELL[st], vattr)
                elif st:
                    stalled = cells.get(c - 1) == st and st != "EX"
                    attr = curses.color_pair(7) | curses.A_BOLD if stalled else STAGE_ATTR[st]
                    if st == "EX" and cells.get(c - 1) == "EX":
                        attr = curses.color_pair(7) | curses.A_BOLD   # multi-cycle EX
                    put(scr, y, x, st, attr)
                elif c == last + 1 and not reached_ex and last + 1 < len(win):
                    put(scr, y, x, "xx", curses.color_pair(9) | curses.A_BOLD)  # flushed
                elif first < c < last:
                    put(scr, y, x, "..", curses.A_DIM)

        # Two always-present lanes: the V lane gets up to 5 rows, U takes the rest.
        avail = max(3, h - 6)
        vcap = min(len(v_order), 5)
        ucap = max(1, avail - vcap - 2)                          # 2 lane headers
        y = 2
        put(scr, y, 0, " U PIPE  -  every instruction issues here".ljust(w)[:w - 1],
            curses.color_pair(6) | curses.A_BOLD)
        y += 1
        for q in u_order[-ucap:]:
            render_row(y, q); y += 1
        put(scr, y, 0, " V PIPE  -  2nd instruction of a co-issued pair (Ex reversed = dual-issue)".ljust(w)[:w - 1],
            curses.color_pair(6) | curses.A_BOLD)
        y += 1
        if v_order:
            for q in v_order[-vcap:]:
                render_row(y, q); y += 1
        else:
            put(scr, y, 3, "(V pipe idle - no pairs co-issued in view; try 34_superscalar / 46_pc_smp)",
                curses.A_DIM)
            y += 1
        yb = y
        put(scr, yb, 0, "  bubble in EX:".ljust(lbl), curses.color_pair(6))
        for c, r in enumerate(win):
            ab = BUBBLE_ABBR.get(r["stall"], "")
            if ab:
                put(scr, yb, lbl + 3 * c, ab, curses.color_pair(7))
        keys_top = put_wrapped(scr, h - 1,
            "s step  c continue  space pause  o Surfer  +/- speed  "
            "Left/Right scroll  f freeze  q quit", curses.A_DIM)
        put_wrapped(scr, keys_top - 1,
            "Two lanes: U pipe (all instructions) + V pipe (co-issued 2nd); a V row "
            "aligned under its U partner with Ex reversed = dual-issue that clock.  "
            "yellow = stalled  xx = flushed  MC microcode  AG AGI  BR branch  "
            "QE queue empty  MW mem wait  BB bus busy  HL halt", curses.A_DIM)
        snap.draw(scr)
        scr.refresh()

        c = scr.getch()
        if c == ord('q'):
            return                                 # leave the ring recording (code window
                                                   # holds the heartbeat; it goes stale on its own)
        if speed_keys(c, sh, s):
            snap.dismiss()          # a resume/step clears the 'Surfer closed' prompt
        elif c == ord('o'):
            snap.start(sh)
        elif c == ord('f'):
            frozen, back = (None, 0) if frozen is not None else (recs, 0)
        elif c == curses.KEY_LEFT:
            if frozen is None:            # auto-freeze so history holds still while scrolling back
                frozen = recs
            back = min(back + max(1, ncols // 4), max(0, len(frozen) - 1))
        elif c == curses.KEY_RIGHT:
            back = max(0, back - max(1, ncols // 4))
            if back == 0 and frozen is not None:
                frozen = None             # scrolled forward to the live edge -> resume live


def cache_view(scr, sh, snap):
    """The coherent split-L1 (MESI) of core 0, with the ACTUAL CONTENTS of every
    line: its MESI state, tag -> physical base address, and 32 data bytes."""
    rate = Rate()
    SETS, WAYS, WORDS = 4, 2, 8
    MC = {0: "I", 1: "S", 2: "E", 3: "M"}            # MESI (I-cache: I=empty, S=valid)

    def pct(hh, mm):
        t = hh + mm
        return f"{100 * hh // t}%" if t else "--"

    def line_bytes(dbase, ln):                        # 32 bytes of line ln (8 LE dwords)
        bs = []
        for word in range(WORDS):
            dw = struct.unpack_from("<I", sh.mm, dbase + (ln * WORDS + word) * 4)[0]
            bs += [(dw >> (8 * b)) & 0xFF for b in range(4)]
        return bs

    while True:
        if not sh.ready():
            waiting(scr, sh)
            if scr.getch() == ord('q'):
                return
            continue
        sh.write32(CACHE_HB, int(time.time()))        # ask the sim to dump the cache
        s = sh.read(); sy = sh.read_sys()
        h, w = scr.getmaxyx()
        scr.erase()
        put(scr, 0, 0, (" L1 CACHE CONTENTS (core 0)  split I/D, 2-way, 32-byte lines, MESI   "
                        f"{speed_text(s, rate.update(s['cycle']))} ").ljust(w), curses.A_REVERSE)
        put(scr, 1, 2, f"I$ {sy['ic_hits']}/{sy['ic_miss']} ({pct(sy['ic_hits'], sy['ic_miss'])})   "
                       f"D$ {sy['dc_hits']}/{sy['dc_miss']} ({pct(sy['dc_hits'], sy['dc_miss'])})   "
                       f"inval {sy['inval']}  wb {sy['wb']}  grant core{sy['grant']}  U/V pairs {sy['pairs']}",
            curses.color_pair(6))
        y = 3
        # I-cache lines come second in the dumped region (D at CACHE+0, I at CACHE+256).
        for name, dbase, mbase in (("I-CACHE  (instructions)", CACHE + 256, CACHE + 520),
                                   ("D-CACHE  (data)", CACHE + 0, CACHE + 512)):
            put(scr, y, 1, name, curses.color_pair(5) | curses.A_BOLD); y += 1
            for s_ in range(SETS):
                for wy in range(WAYS):
                    ln = s_ * WAYS + wy
                    meta = sh.mm[mbase + ln]
                    st, tag = meta & 3, (meta >> 2) & 0x3F
                    base = (tag << 7) | (s_ << 5)     # physical base address of this line
                    if st == 0:                        # ST_I -> empty
                        put(scr, y, 3, f"set{s_} way{wy}  [-]  (empty line)", curses.A_DIM)
                    else:
                        hexs = " ".join(f"{b:02X}" for b in line_bytes(dbase, ln))
                        attr = curses.color_pair(4) | curses.A_BOLD if st == 3 else 0  # M = bold
                        put(scr, y, 3, f"set{s_} way{wy}  [{MC[st]}] tag{tag:02X} @0x{base:03X}: {hexs}", attr)
                    y += 1
                    if y >= h - 1:
                        break
        put(scr, h - 1, 0, " q quit   +/- speed   s step   c run   (M=modified line, bold) ".ljust(w),
            curses.A_REVERSE)
        scr.refresh()
        c = scr.getch()
        if c == ord('q'):
            return
        speed_keys(c, sh, s)


def tlb_view(scr, sh, snap):
    """The MMU: CR3/CR2 and the TLB. A TLB miss walks TWO levels (page directory
    then page table = two memory reads); walks stay low while translations climb
    -- that gap is the TLB caching those walks (paging is idle until CR0.PG)."""
    rate = Rate()
    while True:
        if not sh.ready():
            waiting(scr, sh)
            if scr.getch() == ord('q'):
                return
            continue
        s = sh.read(); sy = sh.read_sys()
        h, w = scr.getmaxyx()
        scr.erase()
        put(scr, 0, 0, (" MMU / TLB  scaled x86 two-level paging: 64-byte pages, page dir -> page "
                        f"table, 4-entry TLB   {speed_text(s, rate.update(s['cycle']))} ").ljust(w),
            curses.A_REVERSE)
        banner(scr, s)
        put(scr, 2, 2, f"CR3 (page-directory base) : 0x{s['cr3']:08X}")
        put(scr, 3, 2, f"CR2 (last #PF address)    : 0x{sy['cr2']:08X}")
        put(scr, 5, 2, f"TLB translations : {sy['trans']:>9}   (one per paged access)", curses.color_pair(6))
        put(scr, 6, 2, f"page-table walks : {sy['walks']:>9}   (TLB miss; 2 reads each: PDE+PTE)",
            curses.color_pair(4) | curses.A_BOLD)
        put(scr, 7, 2, f"page faults #PF  : {sy['faults']:>9}   (not-present PDE or PTE; see CR2 above)",
            curses.color_pair(9) | curses.A_BOLD)
        put(scr, 9, 2, "Paging is OFF until a program sets CR0.PG. Once on, a miss walks")
        put(scr, 10, 2, "CR3 -> page directory -> page table (two reads); the TLB caches the result.")
        put(scr, h - 1, 0, " q quit   +/- speed   s step   c run ".ljust(w), curses.A_REVERSE)
        scr.refresh()
        c = scr.getch()
        if c == ord('q'):
            return
        speed_keys(c, sh, s)


def btb_view(scr, sh, snap, core=0, title=None):
    """The Branch Target Buffer of one core: 8 entries (2 sets x 4 ways), each
    {branch address -> target, 2-bit saturating history}. A hit that predicts
    taken redirects fetch at decode; the branch still resolves in EX, where a
    misprediction flushes and updates the history/target here."""
    rate = Rate()
    load_labels(snap.build)
    STRENGTH = {0: "strong NT", 1: "weak NT", 2: "weak T", 3: "strong T"}
    base = BTB + core * 72
    while True:
        if not sh.ready():
            waiting(scr, sh)
            if scr.getch() == ord('q'):
                return
            continue
        sh.write32(BTB_HB, int(time.time()))          # ask the sim to dump the BTB
        s = sh.read()
        h, w = scr.getmaxyx()
        scr.erase()
        hdr = title or "BTB (BSP core 0)"
        put(scr, 0, 0, (f" {hdr}  branch target buffer: 2 sets x 4 ways, 2-bit history   "
                        f"{speed_text(s, rate.update(s['cycle']))} ").ljust(w), curses.A_REVERSE)
        banner(scr, s)
        put(scr, 2, 1, "    branch        instruction          -> target        history  prediction",
            curses.color_pair(6))
        y = 3
        for i in range(8):
            st_, way = i // 4, i % 4
            tag = struct.unpack_from("<I", sh.mm, base + i * 4)[0]
            tgt = struct.unpack_from("<I", sh.mm, base + 32 + i * 4)[0]
            meta = sh.mm[base + 64 + i]
            valid, ctr = meta & 1, (meta >> 1) & 3
            if not valid:
                put(scr, y, 2, f"set{st_} way{way}  (empty)", curses.A_DIM)
            else:
                taken = ctr >= 2
                txt = LABELS.get(tag, "")[:18].ljust(18)
                bar = ("#" * (ctr + 1)).ljust(4)
                pred = "TAKEN" if taken else "not taken"
                attr = curses.color_pair(4) | curses.A_BOLD if taken else 0
                put(scr, y, 2,
                    f"set{st_} way{way}  0x{tag:04X}  {txt} -> 0x{tgt:04X}   {ctr:02b} {bar} {pred}",
                    attr)
            y += 1
        put(scr, y + 1, 2, "history: 00 strong-NT  01 weak-NT  10 weak-T  11 strong-T  "
                           "(MSB = predict taken)", curses.A_DIM)
        put(scr, h - 1, 0, " q quit   +/- speed   s step   c run ".ljust(w), curses.A_REVERSE)
        scr.refresh()
        c = scr.getch()
        if c == ord('q'):
            return
        speed_keys(c, sh, s)


# ------------------------------------------------------------------- CPI report
# Pentium (P54C) reference cycle counts per instruction, so students can read a
# program as a cost breakdown.  These are the published P54C integer latencies;
# the *measured* throughput also depends on U/V pairing, cache hits, and branch
# prediction, which the pipeline / cache / BTB windows show live.
def cpi_classify(src):
    """One disassembled Intel-syntax line -> (cycles, pipe, note), or None for a
    label/comment line.  `pipe` is 'U/V' (pairable, issues in either integer
    pipe) or 'U' (complex op: U-pipe only, cannot co-issue)."""
    s = src.split(";")[0].strip()
    if not s:
        return None
    parts = s.split(None, 1)
    mn = parts[0].lower()
    ops = parts[1] if len(parts) > 1 else ""
    first = ops.split(",")[0]
    mem     = "[" in ops and mn != "lea"            # touches memory
    mem_dst = "[" in first and mn != "lea"          # memory is the destination

    if mn == "imul":  return (10, "U", "integer multiply (~10 cycles)")
    if mn == "mul":   return (11, "U", "unsigned multiply -> EDX:EAX (~11)")
    if mn == "div":   return (41, "U", "unsigned divide (~41 cycles!)")
    if mn == "idiv":  return (46, "U", "signed divide (~46 cycles!)")
    if mn in ("movsx", "movzx"): return (3, "U", "sign/zero-extend (~3)")
    if mn == "cdq":   return (2, "U", "sign-extend EAX into EDX:EAX")
    if mn == "cwde":  return (3, "U", "sign-extend AX into EAX")
    if mn in ("shl", "shr", "sar", "sal", "rol", "ror", "rcl", "rcr"):
        return (3, "U", "shift/rotate RMW memory") if mem else (1, "U", "shift/rotate")
    if mn == "lea":   return (1, "U/V", "address calc, no memory access")
    if mn == "call":  return (1, "U", "call (pushes return address)")
    if mn in ("ret", "retn"):  return (1, "U", "return (predicted by BTB)")
    if mn == "jmp":   return (1, "V", "jump")
    if mn == "leave": return (3, "U", "ESP<-EBP, pop EBP")
    if mn == "hlt":   return (1, "U", "halt until interrupt")
    if mn == "nop" or (mn == "xchg" and ops.replace(" ", "") == "ax,ax"):
        return (1, "U/V", "no-op (alignment pad)")
    if mn in ("push", "pop"):  return (1, "U/V", mn + " (stack)")
    if re.fullmatch(r"set[a-z]{1,3}", mn):  return (1, "U", "set byte on condition")
    if mn.startswith("j"):     # jcc
        return (1, "V", "cond jump: 1 if predicted, +3 if mispredicted")
    if mn == "mov":
        return (1, "U/V", "load/store (1 cyc on L1 hit)") if mem else \
               (1, "U/V", "register/immediate move")
    if mn in ("add", "or", "adc", "sbb", "and", "sub", "xor", "cmp", "test",
              "inc", "dec", "neg", "not", "xchg"):
        if mem_dst: return (3, "U", "read-modify-write memory (~3)")
        if mem:     return (2, "U", "ALU, memory source (~2)")
        return (1, "U/V", "ALU register op")
    return (1, "U", "")                              # any other single-cycle op


STALL_ROWS = [("useful work", "a retired instruction, no bubble"),
              ("microcode",   "multi-cycle EX: MUL/IMUL/DIV, string, ..."),
              ("AGI",         "address-generation interlock"),
              ("branch",      "mispredict: flush + refetch"),
              ("queue-empty", "front-end starved (I-fetch miss / drain)"),
              ("mem-wait",    "data cache-miss line fills"),
              ("bus-busy",    "bus owned by the other core"),
              ("halted",      "HLT: waiting for an interrupt")]


def cpi_view(scr, sh, build, snap):
    """Live Pentium (P54C) performance report: measured instructions, cycles and
    CPI; the stall breakdown by cause; U/V pairs issued; BTB accuracy; I/D cache
    hit rates and data AMAT -- then a scrollable per-instruction P54C cost key.
    All numbers are read straight from the core's hardware counters."""
    lst_path = os.path.join(build, "pc_prog.lst")
    listing, mtime, top = [], None, 0
    rate = Rate()

    def pct(n, d):
        return (100.0 * n / d) if d else 0.0

    while True:
        if not sh.ready():
            waiting(scr, sh)
            if scr.getch() == ord('q'):
                return
            continue
        sh.write32(112, int(time.time()))          # heartbeat
        s  = sh.read()
        sy = sh.read_sys()
        pf = sh.read_perf()
        try:
            m = os.path.getmtime(lst_path)
        except OSError:
            m = None
        if m != mtime:
            listing, mtime = load_listing(lst_path), m
        key_rows = [(a, src, cpi_classify(src) if a is not None else None)
                    for a, _c, src in listing]

        stalls  = pf["stalls"]
        halt_c  = stalls[7]                        # cycles idling in HLT
        pairs   = pf["pairs"]
        # True dynamic instruction count = U-pipe retirements + the co-issued
        # V-pipe partners (the single retire pulse per cycle counts a pair once).
        # This makes the count -- and CPI -- identical whether or not the program
        # dual-issues, so comparing PIPE=super vs scalar is apples-to-apples.
        instret = pf["instret"] + pairs
        # CPI and the breakdown use ACTIVE cycles (buckets 0..6) so a machine
        # left spinning in HLT after the program ends does not inflate the CPI.
        active  = sum(stalls[0:7]) or 1
        cycles  = active
        tot_st  = active
        cpi     = active / instret if instret else 0.0
        btot    = pf["btb_ok"] + pf["btb_bad"]
        ic_a    = sy["ic_hits"] + sy["ic_miss"]
        dc_a    = sy["dc_hits"] + sy["dc_miss"]
        memwait = stalls[5]
        amat    = 1.0 + (memwait / dc_a) if dc_a else 1.0
        dmiss_r = pct(sy["dc_miss"], dc_a)
        penalty = (memwait / sy["dc_miss"]) if sy["dc_miss"] else 0.0

        h, w = scr.getmaxyx()
        scr.erase()
        G = curses.color_pair(6) | curses.A_BOLD
        put(scr, 0, 0, (f" CPI REPORT -- live Pentium (P54C) performance    "
                        f"cycle {s['cycle']:,}    "
                        f"{speed_text(s, rate.update(s['cycle']))} ").ljust(w), curses.A_REVERSE)
        y = 1
        # Active machine configuration, so each report is self-labelled when
        # students compare runs (make pc PROG=.. PIPE=.. CACHE=.. ...).
        pipe = ("NON-PIPELINED" if pf["serial"] else
                "SUPERSCALAR (U+V)" if pf["dual"] else "SCALAR (U only)")
        cache_s = (f"L1 {pf['sets']}set x {pf['ways']}way x {pf['line']}w"
                   if pf["cache_on"] else "NO CACHE")
        btb_s = "BTB on" if pf["btb_on"] else "BTB OFF"
        put(scr, y, 1, f"MACHINE: {pipe}   {btb_s}   {cache_s}",
            curses.color_pair(4) | curses.A_BOLD); y += 1
        idle = f"  (+{halt_c:,} idle in HLT)" if halt_c else ""
        put(scr, y, 1, f"Instructions retired {instret:>11,}     "
                       f"Active cycles {cycles:>9,}     CPI {cpi:6.2f}{idle}", curses.A_BOLD); y += 1
        put(scr, y, 1, f"U/V pairs issued     {pairs:>11,}     "
                       f"({pct(2 * pairs, instret):4.1f}% of retired instructions co-issued)"); y += 1
        if btot:
            put(scr, y, 1, f"BTB accuracy           {pct(pf['btb_ok'], btot):5.1f}%     "
                           f"({pf['btb_ok']:,} correct / {pf['btb_bad']:,} mispredicted)")
        else:
            put(scr, y, 1, "BTB accuracy              n/a     (no branches resolved yet)")
        y += 1
        put(scr, y, 1, f"I-cache hit rate       {pct(sy['ic_hits'], ic_a):5.1f}%     "
                       f"({sy['ic_hits']:,} hits / {sy['ic_miss']:,} miss)"); y += 1
        put(scr, y, 1, f"D-cache hit rate       {pct(sy['dc_hits'], dc_a):5.1f}%     "
                       f"({sy['dc_hits']:,} hits / {sy['dc_miss']:,} miss)"); y += 1
        put(scr, y, 1, f"AMAT (data)            {amat:5.2f} cyc  "
                       f"(hit 1 + miss-rate {dmiss_r:.1f}% x penalty {penalty:.1f} cyc)"); y += 1
        # TLB / paging (only meaningful once a program turns paging on). A miss
        # walks the two-level table = two memory reads (PDE then PTE).
        tlb_acc = sy["trans"] + sy["walks"]
        if tlb_acc:
            put(scr, y, 1, f"TLB hit rate           {pct(sy['trans'], tlb_acc):5.1f}%     "
                           f"({sy['trans']:,} hits / {sy['walks']:,} walks x2 reads / "
                           f"{sy['faults']:,} #PF)"); y += 1
        else:
            put(scr, y, 1, "TLB / paging             off     (CR0.PG = 0)"); y += 1

        y += 1
        put(scr, y, 1, "where the active cycles go (measured stall breakdown):", G); y += 1
        for i, (nm, note) in enumerate(STALL_ROWS[:7]):    # buckets 0..6; 7 (HLT) shown above
            if y >= h - 2:
                break
            bar = "#" * int(round(18 * stalls[i] / tot_st))
            put(scr, y, 3, (f"{nm:<12}{stalls[i]:>11,} {pct(stalls[i], tot_st):5.1f}%  "
                            f"{bar:<18} {note}")[:w - 4],
                curses.color_pair(5) if i == 0 else 0)
            y += 1

        y += 1
        if y < h - 2:
            put(scr, y, 1, "per-instruction P54C cost key (Up/Dn scroll):", G); y += 1
        hdr_y = y
        body = max(1, h - hdr_y - 1)
        top = max(0, min(top, max(0, len(key_rows) - body)))
        for r in range(body):
            i = top + r
            if i >= len(key_rows) or hdr_y + r >= h - 1:
                break
            a, src, info = key_rows[i]
            yy = hdr_y + r
            if info is None:
                t = src.split(";")[0].strip()
                if t:
                    put(scr, yy, 3, t[:w - 4], curses.color_pair(8))
                continue
            cyc, pipe, note = info
            txt = " ".join(src.split(";")[0].split())
            line = f"{a:04X} {cyc:>3} {pipe:<3}  {txt}"
            if a == s["eip"]:
                attr = curses.color_pair(4) | curses.A_BOLD        # the EX line
            elif cyc >= 10:
                attr = curses.color_pair(7) | curses.A_BOLD        # expensive op
            elif pipe == "U/V":
                attr = curses.color_pair(5)                        # pairable
            else:
                attr = 0
            put(scr, yy, 3, (line + (f"   {note}" if note else ""))[:w - 4], attr)

        put_wrapped(scr, h - 1,
            "Up/Dn PgUp/PgDn scroll   s step  c continue  space pause  q quit",
            curses.A_DIM)
        scr.refresh()

        c = scr.getch()
        if c == ord('q'):
            return
        if speed_keys(c, sh, s):
            pass
        elif c in (curses.KEY_UP, curses.KEY_DOWN, curses.KEY_PPAGE, curses.KEY_NPAGE,
                   curses.KEY_HOME, curses.KEY_END):
            top += {curses.KEY_UP: -1, curses.KEY_DOWN: 1, curses.KEY_PPAGE: -body,
                    curses.KEY_NPAGE: body, curses.KEY_HOME: -10 ** 6,
                    curses.KEY_END: 10 ** 6}[c]


def main(scr):
    mode = sys.argv[1] if len(sys.argv) > 1 else "mem"
    build = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "build")
    curses.curs_set(0)
    # Repaint changed cells in place: no insert/delete-line or -char tricks,
    # which terminals do not all emulate the same way (stale rows otherwise).
    scr.idlok(False)
    scr.idcok(False)
    setup_colors()
    scr.timeout(66)                                   # ~15 frames per second
    sh = Shared(build)
    snap = Snapshot(os.path.abspath(build))
    if mode == "code":
        code_view(scr, sh, build, snap)
    elif mode == "wave":
        wave_view(scr, sh, snap)
    elif mode == "pipe":
        pipe_view(scr, sh, snap)
    elif mode == "pipe-ap":
        pipe_view(scr, sh, snap, samples_fn=sh.samples_ap,
                  title="PIPELINE CHART (AP core 1)")
    elif mode == "cache":
        cache_view(scr, sh, snap)
    elif mode == "tlb":
        tlb_view(scr, sh, snap)
    elif mode == "btb":
        btb_view(scr, sh, snap)
    elif mode == "btb-ap":
        btb_view(scr, sh, snap, core=1, title="BTB (AP core 1)")
    elif mode == "cpi":
        cpi_view(scr, sh, build, snap)
    elif mode == "vram":
        mem_view(scr, sh, snap, vmode=True)
    else:
        mem_view(scr, sh, snap)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] not in (
            "mem", "vram", "code", "wave", "pipe", "pipe-ap", "cache", "tlb",
            "btb", "btb-ap", "cpi"):
        sys.exit(__doc__)
    locale.setlocale(locale.LC_ALL, "")      # so curses writes the UTF-8 glyphs (▔ ╳ ─)
    curses.wrapper(main)
