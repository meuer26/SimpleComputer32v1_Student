#!/usr/bin/env python3
"""
Program-aware Surfer row selector.

Reads an ndisasm disassembly on stdin and emits a Surfer command file that adds
only the waveform rows relevant to the instructions the program actually uses.
The EX state-name tap is always added first and formatted as ASCII so it reads
as text (EXECUTE, LOAD, STORE, ...) rather than a raw vector.

  usage:  ndisasm -b32 -o0 prog.bin | surfer_rows.py --tb tb_cpu

Signal paths: rows mapped to the testbench top scope <tb> use the dbg* taps the
testbench exposes; everything else is read from the CPU instance (<tb>.cpu_inst)
where every debug port is dumped even when the testbench leaves it unconnected.
"""
import sys
import re
import argparse

ap = argparse.ArgumentParser()
ap.add_argument("--tb", required=True, help="testbench unit, e.g. tb_cpu_nocache")
ap.add_argument("--pipe", action="store_true", help="show the superscalar Pentium pipeline rows")
args = ap.parse_args()
TB = args.tb
# The BSP core instance is labelled differently across testbenches.
CPU = f"{TB}." + {"tb_cpu": "bsp", "tb_cpu_vm": "bsp", "tb_pc": "cpu_inst"}.get(TB, "bsp")

# ---- parse the disassembly into bare, lower-cased instruction text -----------
insns = []
for line in sys.stdin:
    # ndisasm line: "<offset>  <hexbytes>  <mnemonic operands>"
    m = re.match(r"\s*[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(.*)$", line.rstrip("\n"))
    if m:
        insns.append(m.group(1).lower())
text = "\n".join(insns)


def uses(*patterns):
    return any(re.search(p, text) for p in patterns)


# ---- build the ordered, de-duplicated row list -------------------------------
cmds = []
seen = set()


def divider(label):
    cmds.append(f'divider_add {label}')


def row(path):
    if path not in seen:
        seen.add(path)
        cmds.append(f"variable_add {path}")


# ASCII rows first: Surfer names display items a, b, c, ... in the order they
# are added, so text-valued taps are added (and formatted) before anything else.
# The FSM state name is always item "a".
ascii_rows = [f"{TB}.dbg_state_name"]
PC = TB == "tb_pc"
if args.pipe and TB != "tb_smp":
    # The superscalar Pentium pipeline: which instruction is in each stage, as
    # text. Read top to bottom, an instruction moves one row down per clock:
    # D1 -> D2 -> EX -> WB. The V-pipe row shows the *second* instruction that
    # co-issues with the one in EX (the Pentium's U/V dual-issue): when it is not
    # "(no pair)", two instructions executed in the same cycle. dbg_stall_name
    # names why a cycle was a bubble.
    ascii_rows += [f"{CPU}.dbg_d1_txt", f"{CPU}.dbg_d2_txt", f"{CPU}.dbg_ex_txt",
                   f"{CPU}.dbg_v_txt", f"{CPU}.dbg_wb_txt", f"{CPU}.dbg_stall_name"]
ports = lambda *pats: uses(*pats)
pc_kbd = PC and ports(r"0x6[04]\b")
pc_pic = PC and ports(r"0x(20|21|a0|a1)\b", r"\b(sti|hlt|iret)\b")
pc_ata = PC and ports(r"0x1f[0-7]\b", r"0x3f6\b")
if PC:
    ascii_rows += [f"{TB}.mem_sel", f"{TB}.io_sel"]
    if pc_ata:
        ascii_rows.append(f"{TB}.ata_phase")
    ascii_rows += [f"{TB}.scr_row{r:02d}" for r in range(5)]
for i, path in enumerate(ascii_rows):
    cmds.append(f"variable_add {path}")
    cmds.append(f"item_focus {chr(ord('a') + i)}")
    cmds.append("item_set_format ASCII")
    seen.add(path)

# Always-relevant control flow.
divider("control")
row(f"{TB}.dbg01_clk")
row(f"{TB}.dbg_pc")
row(f"{TB}.dbg03_ir")
row(f"{CPU}.modrm")          # ModR/M byte, always shown directly below IR
row(f"{TB}.dbg04_operand")   # decoded operand (disp/imm), always shown
row(f"{TB}.dbg11_we")        # memory write-enable, always shown

# Registers: EAX is always shown; the rest only when the program touches them.
# Stack instructions implicitly use ESP even when it is not named.
divider("registers")
row(f"{TB}.dbg05_eax")
reg_paths = {
    "ebx": f"{TB}.dbg06_ebx",
    "ecx": f"{TB}.dbg07_ecx",
    "edx": f"{CPU}.dbg_edx",
    "esi": f"{CPU}.dbg_esi",
    "edi": f"{CPU}.dbg_edi",
    "ebp": f"{CPU}.dbg_ebp",
    "esp": f"{TB}.dbg08_esp",
}
stack = uses(r"\b(push|pop|call|ret|leave|enter|pusha|popa|pushf|popf)\b")
for name, path in reg_paths.items():
    if uses(rf"\b{name}\b") or (name in ("esp", "ebp") and stack):
        row(path)

# Arithmetic / logic that sets flags.
if uses(r"\b(add|sub|adc|sbb|cmp|test|and|or|xor|inc|dec|neg|"
        r"shl|shr|sar|sal|rol|ror|mul|imul|div|idiv)\b"):
    divider("flags")
    row(f"{TB}.dbg09_flags")

# Memory traffic (any [..] operand, or the moffs MOV forms).
if uses(r"\[", r"\bmov\b.*0x[0-9a-f]+\]"):
    divider("memory_bus")
    row(f"{TB}.cpu_addr")       # WE (dbg11_we) is already shown in the control group
    row(f"{TB}.cpu_dout")
    row(f"{TB}.cpu_din")

# Stack pointer detail when the program is stack-heavy.
if stack:
    row(reg_paths["esp"])

# SSE / XMM.
if uses(r"\bxmm", r"\b(movd|movq|movdqa|movdqu|movaps|movups|"
        r"padd|psub|pand|por|pxor|pmull)"):
    divider("sse_xmm")
    row(f"{CPU}.dbg_xmm0")
    row(f"{CPU}.dbg_xmm1")
    row(f"{CPU}.dbg_xmm2")

# Port I/O (x86 IN/OUT, separate address space). The PC view shows its own,
# real active-low strobes instead (below).
if uses(r"\b(in|out|insb|insd|outsb|outsd)\b") and not PC:
    divider("port_io")
    row(f"{TB}.io_addr")
    row(f"{TB}.io_dout")
    row(f"{TB}.io_din")
    row(f"{TB}.io_re")
    row(f"{TB}.io_we")

# Interrupts / IDT.
if uses(r"\b(int|int3|iret|lidt|sti|cli)\b"):
    divider("interrupts")
    row(f"{TB}.dbg10_ivt")
    row(f"{CPU}.dbg_eflags")

# Atomics / bus lock.
if uses(r"\b(lock|xchg|cmpxchg)\b"):
    divider("atomic_lock")
    row(f"{CPU}.dbg12_bus_lock")
    row(f"{TB}.dbg13_xchg_active")
    row(f"{TB}.cpu_lock")

# Pipeline detail: the prefetch unit, stage addresses, and the superscalar
# V pipe (dbg_v_valid = a pair co-issued this cycle; dbg_pairs = running total).
if args.pipe and TB != "tb_smp":
    divider("pipeline")
    row(f"{CPU}.dbg_pf_addr")
    row(f"{CPU}.dbg_pq_cnt")
    row(f"{CPU}.dbg_stage_valid")
    row(f"{CPU}.dbg_ex_eip")
    row(f"{CPU}.dbg_retire")
    divider("superscalar_uv")
    row(f"{CPU}.dbg_v_valid")
    row(f"{CPU}.dbg_pairs")

# Virtual memory (the VM testbench): CR3/CR2, paging enable, faults, and the TLB.
# Pedagogy: p_walks steps up only on a TLB *miss*, so watching it stay nearly
# flat while p_trans climbs on every access is the TLB doing its job.
if TB == "tb_cpu_vm":
    divider("paging")
    row("tb_cpu_vm.cr3")
    row("tb_cpu_vm.cr2")
    row("tb_cpu_vm.pg_enable")
    row("tb_cpu_vm.page_fault")
    row("tb_cpu_vm.fault_addr")
    divider("tlb")
    row("tb_cpu_vm.p_trans")          # translations: one per paged access
    row("tb_cpu_vm.p_walks")          # page-table walks: only on a TLB miss
    row("tb_cpu_vm.p_flts")           # page faults (#PF)
    row("tb_cpu_vm.tlb_flush")        # pulses when CR3 is written
    row("tb_cpu_vm.mmu0.tlb_valid")   # which of the 4 TLB entries are live
    row("tb_cpu_vm.mmu0.fill_ptr")    # round-robin TLB refill pointer

# Teaching PC: the two decoders, interrupts and the devices the program uses.
if PC:
    # Bus command strobes and INTA# as the chipset drives them: ACTIVE LOW,
    # with Intel's `#` suffix (MEMR# MEMW# IOR# IOW# INTA#). A `#` cannot be
    # written in a Surfer command file (it starts a comment), so the whole
    # tb_pc.isa_bus scope is added; its names come from the waveform itself.
    divider("bus_strobes_active_low")
    cmds.append(f"scope_add {TB}.isa_bus")
    divider("pc_bus")
    row(f"{TB}.cs_ram")
    row(f"{TB}.cs_vram")
    row(f"{TB}.cpu_be")
    row(f"{TB}.io_addr")
    row(f"{TB}.io_size")
    row(f"{TB}.io_dout")
    row(f"{TB}.io_din")
    if pc_pic:
        divider("interrupts_8259")
        row(f"{TB}.intr")
        row(f"{CPU}.dbg_vector")
        row(f"{CPU}.dbg_eflags")
        row(f"{TB}.pic1_irr")
        row(f"{TB}.pic1_isr")
        row(f"{TB}.pic1_imr")
        row(f"{TB}.pic2_irr")
        row(f"{TB}.pic2_isr")
        row(f"{TB}.pic2_imr")
    if pc_kbd:
        divider("keyboard_8042")
        row(f"{TB}.key_valid")
        row(f"{TB}.key_code")
        row(f"{TB}.kbd_status")
        row(f"{TB}.kbd_outbuf")
        row(f"{TB}.irq1")
    if pc_ata:
        divider("ata_disk")
        row(f"{TB}.ata_status")
        row(f"{TB}.ata_lba")
        row(f"{TB}.ata_word")
        row(f"{TB}.irq14")
    divider("vga")
    row(f"{TB}.cursor")
    row(f"{TB}.post_code")
    # Coherent split-L1 (MESI) -- taps come straight off the `mem` instance's
    # (open) debug ports, so the one machine shows its cache in the PC view too.
    divider("cache_MESI")
    row(f"{TB}.mem.dbg_c0_dhits")       # BSP D-cache hits
    row(f"{TB}.mem.dbg_c0_dmiss")       # BSP D-cache misses
    row(f"{TB}.mem.dbg_invalidations")  # snoop invalidations (SMP)
    row(f"{TB}.mem.dbg_writebacks")     # dirty-eviction / snoop write-backs
    row(f"{TB}.mem.dbg_c0_state")       # BSP line MESI state (set 0)
    row(f"{TB}.mem.dbg_c1_state")       # AP  line MESI state (set 0)
    row(f"{TB}.mem.dbg_grant")          # which core owns the bus
    # Application processor (core 1): parked until a SIPI, then its own pipeline.
    divider("AP_core1")
    row(f"{TB}.pc1")                    # AP program counter
    row(f"{TB}.ap.dbg_stage_valid")    # AP D1 D2 EX WB occupancy
    row(f"{TB}.ap.dbg_v_valid")        # AP U/V pair co-issue

# Cache visibility (only the plain cache testbench exposes these top-level taps).
if TB == "tb_cpu":
    divider("cache")
    row(f"{TB}.cache_hits")
    row(f"{TB}.cache_misses")
    row(f"{TB}.cache_hit")

cmds.append("zoom_fit")
print("\n".join(cmds))
