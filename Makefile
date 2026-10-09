# =============================================================================
# x86-32 teaching CPU -- build & test
#
# Programs are REAL x86-32 machine code: assembled with nasm (-f bin) and
# verifiable with ndisasm / objdump -b binary -m i386. There is no custom
# assembler. scripts/asm2hex.sh turns each NASM source into the
# one-byte-per-line hex image the coherent L1 (rtl/l1_mesi.vhd) loads at reset,
# and prints the disassembly.
#
# Layout:
#   rtl/      VHDL sources (CPU, coherent L1 caches, APIC, testbenches)
#   asm/      x86-32 test programs (NASM)
#   scripts/  asm2hex.sh, run_sim.sh, surfer_rows.py + the Python checkers
#   build/    ALL generated artifacts (hex, work library, VCD/GHW, tests.txt)
#
# Tools (required):
#   sudo apt install nasm ghdl-llvm   (the LLVM backend: faster, and prints a
#                                      VHDL backtrace on assertions)
#   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
#   source "$HOME/.cargo/env"
#   cargo install --locked --git https://gitlab.com/surfer-project/surfer.git surfer
#
# There are exactly three targets:
#
#   make        the FULL regression, one command: the ALU/cache suite (+ an
#               independent cache-model cross-check), the paging suite (MMU/TLB/
#               #PF), the SMP coherency demo (SIPI + MESI + LOCK CMPXCHG), and
#               the teaching-PC device suite (PICs, keyboard, VGA, ATA). Batch;
#               everything is checked. (Missing tools are auto-installed.)
#
#   make pc     run the teaching PC live and open its viewer windows: the
#               terminal becomes the PC's screen+keyboard, and COSMIC-terminal
#               windows show live RAM, video RAM, the running code, a chronogram,
#               BOTH cores' pipeline charts (BSP + AP), and the cache (MESI) and
#               TLB windows. The machine's features are present
#               and visible -- superscalar U/V issue, both cores, the coherent
#               MESI cache, and the devices -- used or idle depending on what the
#               program does. (Paging/TLB is exercised + shown by `make`'s paging
#               phase.) Ctrl-] quits.
#               Knobs: PROG=asm/NN.asm (default 42_pc_kbd_irq), VIEW=0 (no
#               windows), SPEED=<cycles/s> (0 = full speed), PAUSED=0 (start
#               running), TERM_APP=<terminal>.
#
#   make clean
#
# The machine is a dual-Pentium (P54C): two superscalar P5 cores (U/V dual-issue
# + BTB), each with split I/D L1 caches (2-way, 32 B lines, write-back), kept
# coherent by MESI; the BSP starts the AP by a local-APIC SIPI.
# =============================================================================

ASM     := asm
BUILD   := build
SCRIPTS := scripts

# Test programs, ordered by sophistication. <num>_<name>.asm -> <num>_test.hex
TESTS := 01_transfers 02_memory 03_add_carry 04_sub_borrow 05_shifts \
         06_construct 07_alu_regreg 08_stack 09_stack_pointer 10_branch_jne \
         11_branch_carry 12_call_ret 13_call_nested 14_interrupt \
         15_interrupt_multi 16_pipeline 17_integration 18_atomic_xchg \
         19_spinlock_cmpxchg 20_simd_sse 21_port_io 22_simd_movaps \
         23_cache_spatial 24_cache_conflict 29_byte_word 30_io_sizes \
         31_int_frame 32_pipeline 33_smc 34_superscalar

# Teaching-PC programs -- run on tb_pc. Scripted keys come from each program's
# '; KEYS:' line; the disk image is assembled from asm/pc_disk.asm.
PCTESTS := 40_pc_hello 41_pc_kbd_poll 42_pc_kbd_irq 43_pc_ata 44_pc_ata_irq 45_pc_ud \
           46_pc_smp
PROG    ?= $(ASM)/42_pc_kbd_irq.asm
PCDISK  := $(BUILD)/pc_disk.hex
VIEW    ?= 1
SPEED   ?= 100
PAUSED  ?= $(VIEW)
TERM_APP ?= cosmic-term

# Both cores always run. `make pc` opens the console + just the disassembly
# window; its OPEN-WINDOW keys (p/m/v/w/k/t/b) spawn the rest on demand, and the
# pipeline/chronogram keep recording in the background so they have scrollback
# when opened. `make pc smp` opens every window (both cores) up front.
ifneq ($(filter smp,$(MAKECMDGOALS)),)
PC_WINDOWS := mem vram code wave pipe cache tlb btb pipe-ap btb-ap
else
PC_WINDOWS := code
endif

# Paging demos (they enable CR0.PG): part [2/4] of `make`, run through the MMU.
VMTESTS := 25_vm_identity 26_vm_remap 27_vm_tlb 28_vm_pagefault

# =============================================================================
# `make` -- the FULL regression on the dual-Pentium (P54C), one command. It runs
# every test category and checks them all:
#   * ALU / cache suite      (superscalar U/V + BTB + coherent split-L1 MESI),
#                            with an independent cache-model cross-check
#   * paging suite           (MMU + TLB + page-table walks + #PF)
#   * SMP coherency demo     (SIPI bring-up + MESI + LOCK CMPXCHG atomicity)
#   * teaching-PC devices    (8259 PICs, 8042 keyboard, VGA text, ATA disk)
# =============================================================================
default: check-tools check-gcc $(PCDISK)
	@mkdir -p $(BUILD)
	@echo "==== [1/4] ALU + cache suite (superscalar, coherent split-L1 MESI) ===="
	@rm -f $(BUILD)/tests.txt
	@for t in $(TESTS); do \
	    n=$${t%%_*}; \
	    $(SCRIPTS)/asm2hex.sh $(ASM)/$$t.asm $(BUILD)/$${n}_test.hex; \
	    $(SCRIPTS)/run_sim.sh --batch $(BUILD)/$${n}_test.hex >> $(BUILD)/tests.txt; \
	done
	@python3 $(SCRIPTS)/check_tests.py
	@python3 $(SCRIPTS)/verify_cache.py
	@echo "==== [2/4] paging suite (MMU + TLB + #PF) ===="
	@rm -f $(BUILD)/vm_tests.txt
	@for t in $(VMTESTS); do \
	    n=$${t%%_*}; \
	    $(SCRIPTS)/asm2hex.sh $(ASM)/$$t.asm $(BUILD)/$${n}_test.hex; \
	    $(SCRIPTS)/run_sim.sh --vm --batch $(BUILD)/$${n}_test.hex >> $(BUILD)/vm_tests.txt; \
	done
	@python3 $(SCRIPTS)/check_tests.py $(BUILD)/vm_tests.txt
	@echo "==== [3/4] SMP coherency (SIPI + MESI + LOCK CMPXCHG) ===="
	@$(SCRIPTS)/asm2hex.sh $(ASM)/smp_counter.asm $(BUILD)/smp_test.hex >/dev/null
	@$(SCRIPTS)/run_sim.sh --smp --batch $(BUILD)/smp_test.hex > $(BUILD)/smp_test.txt; \
	 grep -E "counter|COHERENCY" $(BUILD)/smp_test.txt; \
	 grep -q "SMP COHERENCY: PASS" $(BUILD)/smp_test.txt || { echo "  SMP COHERENCY FAILED"; exit 1; }
	@echo "==== [4/4] teaching-PC device suite (keyboard, PIC, ATA, VGA) ===="
	@rm -f $(BUILD)/pc_tests.txt
	@for t in $(PCTESTS); do \
	    n=$${t%%_*}; \
	    $(SCRIPTS)/asm2hex.sh $(ASM)/$$t.asm $(BUILD)/$${n}_test.hex; \
	    python3 $(SCRIPTS)/keys2scan.py --from-asm $(ASM)/$$t.asm > $(BUILD)/$${n}_keys.txt; \
	    $(SCRIPTS)/run_sim.sh --pc --batch --disk=$(PCDISK) \
	        --disk-out=$(BUILD)/$${n}_disk_out.hex --keys=$(BUILD)/$${n}_keys.txt \
	        $(BUILD)/$${n}_test.hex >> $(BUILD)/pc_tests.txt; \
	done
	@python3 $(SCRIPTS)/check_tests.py $(BUILD)/pc_tests.txt
	@echo "==== ALL SUITES PASSED ===="

$(PCDISK): $(ASM)/pc_disk.asm
	@mkdir -p $(BUILD)
	@$(SCRIPTS)/asm2hex.sh $< $@ > /dev/null

# Interactive session. The screen and the scan codes live in the terminal;
# simulator messages go to build/pc_live.log. The final screen and registers
# are printed when you quit (Ctrl-]).
pc: check-gcc $(PCDISK)
	@if pgrep -f '[t]b_pc.*-gLIVE=1' >/dev/null; then \
	    echo "A 'make pc' session is already running (it owns build/pc_state.bin)."; \
	    echo "Quit it first (Ctrl-] in its window)."; exit 1; fi
	@command -v nasm >/dev/null 2>&1 || { echo "ERROR: nasm not found"; exit 1; }
	@command -v ghdl >/dev/null 2>&1 || { echo "ERROR: ghdl not found"; exit 1; }
	@$(SCRIPTS)/asm2hex.sh $(PROG) $(BUILD)/pc_prog.hex > /dev/null
	@nasm -f bin $(PROG) -l $(BUILD)/pc_prog.lst -o /dev/null
	@if [ "$(VIEW)" = "1" ]; then \
	    if command -v $(TERM_APP) >/dev/null 2>&1; then \
	        for v in $(PC_WINDOWS); do \
	            pgrep -f "pc_view.py $$v " >/dev/null || \
	            ( setsid env PC_TERM_APP=$(TERM_APP) $(TERM_APP) -e python3 \
	                $(CURDIR)/$(SCRIPTS)/pc_view.py $$v $(CURDIR)/$(BUILD) >/dev/null 2>&1 & ); \
	        done; \
	    else echo "($(TERM_APP) not found: viewer windows skipped -- VIEW=0 silences this)"; fi; \
	fi
	@PC_SPEED=$(SPEED) PC_START_PAUSED=$(PAUSED) $(SCRIPTS)/run_sim.sh --pc --live --disk=$(PCDISK) \
	    --disk-out=$(BUILD)/pc_disk_out.hex \
	    $(BUILD)/pc_prog.hex

# `smp` is a modifier for `make pc smp` (open the AP windows too), not a target
# of its own -- it just needs a rule so make does not complain about the goal.
smp:
	@:

# ----------------------------------------------------------------- dependencies
# Typing `make` installs anything that is missing, so a fresh clone just works:
#   nasm / ghdl-llvm / gcc  -> apt (sudo will prompt for your password)
#   surfer                  -> cargo (rustup is bootstrapped first if absent)
APT := $(shell command -v apt-get 2>/dev/null)

# nasm + ghdl: assemble and simulate. Needed by every build/sim target.
check-tools: check-llvm
	@missing=""; \
	 command -v nasm >/dev/null 2>&1 || missing="$$missing nasm"; \
	 command -v ghdl >/dev/null 2>&1 || missing="$$missing ghdl-llvm"; \
	 if [ -n "$$missing" ]; then \
	   [ -n "$(APT)" ] || { echo "ERROR: apt-get not found. Install$$missing manually, then re-run make."; exit 1; }; \
	   echo ">> Installing:$$missing   (sudo may prompt for your password)"; \
	   sudo apt-get update && sudo apt-get install -y $$missing || { echo "ERROR: could not install$$missing."; exit 1; }; \
	 fi

# The scripts prefer the LLVM GHDL backend (faster; prints a VHDL backtrace on an
# assertion). On Ubuntu the ghdl-llvm binary links the *versioned* LLVM soname
# (e.g. libLLVM-18.so.18.1) but the libllvmNN package ships it unversioned
# (libLLVM.so.18.1), so ghdl-llvm fails to load and the `ghdl` wrapper silently
# falls back to mcode. If that is the only gap, symlink it (one-time, sudo).
check-llvm:
	@command -v ghdl-llvm >/dev/null 2>&1 || exit 0; \
	 ghdl-llvm --version >/dev/null 2>&1 && exit 0; \
	 need=$$(ghdl-llvm --version 2>&1 | grep -oE 'libLLVM-[0-9.]+\.so\.[0-9.]+' | head -1); \
	 real=$$(ldconfig -p | grep -oE '/[^ ]*/libLLVM\.so\.[0-9.]+' | head -1); \
	 [ -n "$$need" ] && [ -n "$$real" ] || exit 0; \
	 dir=$$(dirname "$$real"); \
	 echo ">> Enabling the LLVM GHDL backend: linking $$need -> $$real (sudo)"; \
	 sudo ln -sf "$$real" "$$dir/$$need" && sudo ldconfig && \
	   ghdl-llvm --version >/dev/null 2>&1 && echo ">> ghdl-llvm is now usable." \
	   || echo ">> (could not fix ghdl-llvm; the scripts will use the mcode backend)"

# gcc: builds the teaching PC's terminal screen/keyboard (libpchost.so).
check-gcc:
	@command -v gcc >/dev/null 2>&1 || { \
	   [ -n "$(APT)" ] || { echo "ERROR: apt-get not found. Install gcc manually, then re-run make."; exit 1; }; \
	   echo ">> Installing gcc   (sudo may prompt for your password)"; \
	   sudo apt-get update && sudo apt-get install -y gcc || { echo "ERROR: could not install gcc."; exit 1; }; }

# surfer: the waveform viewer. Only the targets that open waveforms depend on it.
check-surfer:
	@command -v surfer >/dev/null 2>&1 || { \
	   echo ">> Installing surfer (waveform viewer) with cargo -- builds from source, can take a few minutes..."; \
	   command -v cargo >/dev/null 2>&1 || { \
	     echo ">> Rust/cargo not found -- bootstrapping rustup (non-interactive)..."; \
	     curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || { echo "ERROR: rustup install failed."; exit 1; }; }; \
	   . "$$HOME/.cargo/env" 2>/dev/null; \
	   cargo install --locked --git https://gitlab.com/surfer-project/surfer.git surfer \
	     || { echo "ERROR: surfer build failed -- see https://surfer-project.org"; exit 1; }; }

clean:
	rm -rf $(BUILD)

.PHONY: default pc smp clean check-tools check-gcc check-surfer check-llvm
