# Dual-Pentium (P54C) Teaching Computer — VHDL

A genuinely **x86-32 (IA-32)** machine in VHDL that executes **real x86 machine code** — every program is assembled with `nasm` and disassembles with `ndisasm` / `objdump -b binary -m i386`, so you write real x86, see the real bytes, and the hardware runs them. The microarchitecture is a faithful (scaled) **Intel Pentium**, built to Alpert & Avnon's *"Architecture of the Pentium Microprocessor"* (IEEE Micro, 1993) — the paper students read alongside it.

- **Superscalar P5 core** — two integer pipelines (**U** and **V**) that issue two instructions per clock under the paper's Figure-5 rule, a **branch target buffer** (2-bit predictor, predict-at-decode with speculative fetch), and the five-stage integer pipe. `cmp`/`dec` + `Jcc` pair with same-cycle flag forwarding.
- **Separate instruction and data caches** — each 2-way set-associative, 32-byte lines, write-back; **self-/cross-modifying code** is kept coherent by snooping the instruction cache.
- **Dual processor (P54C)** — two cores sharing one bus, their data caches kept coherent by **snooping MESI**, with a sticky `LOCK#` for atomic `LOCK CMPXCHG`. The core is the P5; glueless two-way SMP and the on-chip local APIC are the P54C additions.
- **APIC / SIPI bring-up** — the bootstrap processor (BSP) runs from reset; the application processor (AP) boots parked and is started the real way: the BSP writes the local-APIC ICR with an **INIT** then a **STARTUP IPI** carrying a start vector.
- **Scaled x86 paging** — each core has its own **MMU + TLB** (single-level page table, `#PF`); the L1 is **physically tagged** (translate, then cache).
- **Teaching PC** (`make pc`) — the machine in an IBM PC/AT: real 8259 PICs, an 8042 keyboard, a VGA text screen (uncacheable video RAM, as on real hardware), and an ATA disk, wired to your terminal as a live screen and keyboard.
- Correctness is machine-checked: `check_tests.py` verifies final registers/flags/memory, and `verify_cache.py` cross-checks the cache against an independent reference model.

Everything is **one core design** (the Pentium) in a **two-CPU SMP configuration with caches on by default**; a single-threaded program simply runs on the BSP with the AP parked. The ISA covers the real encodings of MOV/ALU/shifts/stack/branches/`CALL`/`INT`/`IRET`, `IN`/`OUT`, SSE2 (`MOVAPS`/`PADDD`), `LOCK CMPXCHG`, and the paging control-register moves — anything else raises `#UD`.

## Requirements

Linux with `nasm`, `ghdl`, `gcc`, and `surfer` — `make` installs whatever is missing.

## Usage

```
make                 # assemble + simulate every test on the dual-Pentium, then
                     #   check results and cross-check the cache
make run TEST=07     # build one test and open its waveform in Surfer
make smp             # SMP demo: the BSP starts the AP by SIPI; both contend on
                     #   a LOCK CMPXCHG spinlock (MESI coherency, no lost updates)
make vm              # scaled x86 paging suite (TLB, demand paging, #PF)
make pc              # LIVE teaching PC: type at the keyboard, see the screen
```

---

*Written by Claude (Anthropic) at Dan O'Malley's direction and specifications.*
