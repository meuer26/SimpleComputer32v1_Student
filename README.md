# Dual-Pentium (P54C) Teaching Computer — VHDL

An x86-32 (IA-32) machine in VHDL that runs **real x86 machine code**: programs are assembled with `nasm`, or compiled from C with `gcc -m32` at `-O0`/`-O2`, and the hardware executes the actual bytes. The microarchitecture is a faithful, scaled **Intel Pentium (P54C)**, built to Alpert & Avnon's *"Architecture of the Pentium Microprocessor"* (IEEE Micro, 1993) — a two-core SMP machine with caches on by default; a single-threaded program runs on the bootstrap core with the other parked.

- **Superscalar P5 core** — U and V integer pipes issue two instructions per clock, a 2-bit branch-target buffer predicts at decode with speculative fetch, over a five-stage pipe (PF D1 D2 EX WB).
- **Split write-back L1** — separate 2-way, 32-byte-line instruction and data caches; self-/cross-modifying code stays coherent by snooping the I-cache.
- **Dual-core P54C SMP** — snooping **MESI** keeps the data caches coherent, a sticky `LOCK#` makes `LOCK CMPXCHG` atomic, and the application core is started the real way (local-APIC **INIT + STARTUP IPI**).
- **Scaled paging** — each core has its own MMU + TLB with a real x86 **two-level** walk (page directory → page table → page, two memory reads per TLB miss, `#PF` at either level); the physically-tagged L1 translates, then caches.
- **Teaching PC** — real 8259 PICs, an 8042 keyboard, a VGA text screen, and an ATA disk, wired to your terminal as a live screen and keyboard.
- **gcc-ready integer ISA** — real encodings including SIB scaled-index addressing, memory-operand and byte ALU, `IMUL`/`MUL`/`DIV`/`IDIV` (multi-cycle), shifts, `LEA`, `MOVSX`/`MOVZX`, `SETcc`, `IN`/`OUT`, SSE2 `MOVAPS`/`PADDD`; anything unimplemented raises `#UD`.
- **Live CPI report** (press `r`) — measured instructions, CPI, stall breakdown by cause, U/V pairs, BTB accuracy, cache hit rates, and data AMAT, all read from the core's own hardware counters.

`make` builds and machine-checks the whole machine in one command — the ALU/cache suite (with an independent cache cross-check via `verify_cache.py`), paging, SMP coherency, the PC devices, and gcc-compiled C at `-O0`/`-O2`; `check_tests.py` verifies final registers, flags, and memory. `make pc [PROG=asm/x.asm|c/x.c] [OPT=-O0|-O2]` runs one program live with on-demand viewer windows (`p` pipeline, `m` RAM, `k` cache, `b` BTB, `w` chronogram, `r` CPI report, …), and `make pc smp` opens both cores. Append machine-configuration knobs — `PIPE=super|scalar|none`, `BTB=0|1`, `CACHE=0|1`, and `DSETS=`/`DWAYS=`/`DLINE=` for L1 geometry — to change one thing and watch the CPI report move (the defaults *are* the standard machine, so plain `make pc` is unchanged); `make cpi-compare PROG=…` tabulates one program across all of them side by side. Needs Linux with `nasm`, `ghdl`, and `gcc` (`make` installs any that are missing; `surfer` is optional, for waveform snapshots).

---

*Written by Claude (Anthropic) at Dan O'Malley's direction and specifications.*
