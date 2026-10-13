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
         31_int_frame 32_pipeline 33_smc 34_superscalar \
         35_sib 36_mem_alu 37_mem_rmw 38_imul_shift 39_lea_inc 47_grp3_misc 48_byte_alu \
         49_pairing

# Teaching-PC programs -- run on tb_pc. Scripted keys come from each program's
# '; KEYS:' line; the disk image is assembled from asm/pc_disk.asm.
PCTESTS := 40_pc_hello 41_pc_kbd_poll 42_pc_kbd_irq 43_pc_ata 44_pc_ata_irq 45_pc_ud \
           46_pc_smp
# gcc-compiled C kernels (c/<name>.c, entry run(), results at 0x800). Each runs
# at -O0 and -O2 in the regression and can be run live with `make pc PROG=c/<name>.c`.
CPROGS  := kernels sort mathops fib
PROG    ?= $(ASM)/42_pc_kbd_irq.asm
OPT     ?= -O2                 # gcc optimization level for `make pc PROG=c/<x>.c`
PCDISK  := $(BUILD)/pc_disk.hex
VIEW    ?= 1
SPEED   ?= 100
PAUSED  ?= $(VIEW)
TERM_APP ?= cosmic-term

# ---- Machine-configuration knobs (override to study their effect in the CPI
# report; the defaults ARE the standard Pentium machine, so plain `make pc` is
# unchanged). See README "Machine configuration".
PIPE    ?= super              # super = U/V dual-issue | scalar = 1 pipe | none = non-pipelined
BTB     ?= 1                  # 1 = branch prediction on | 0 = off (taken branches mispredict)
CACHE   ?= 1                  # 1 = L1 on | 0 = no cache (every access misses to memory)
DSETS   ?= 4                  # L1 sets        (power of two)
DWAYS   ?= 2                  # L1 associativity (power of two)
DLINE   ?= 8                  # L1 words per line (line = 4*DLINE bytes)
# Map the friendly knobs to the tb_pc generics (evaluated by make).
CFG_DUAL   := $(if $(filter super,$(PIPE)),true,false)
CFG_SERIAL := $(if $(filter none,$(PIPE)),true,false)
CFG_BTB    := $(if $(filter 1,$(BTB)),true,false)
CFG_CACHE  := $(if $(filter 1,$(CACHE)),true,false)
CFG_ENV    := CFG_DUAL=$(CFG_DUAL) CFG_SERIAL=$(CFG_SERIAL) CFG_BTB=$(CFG_BTB) \
              CFG_CACHE=$(CFG_CACHE) CFG_SETS=$(DSETS) CFG_WAYS=$(DWAYS) CFG_LINE=$(DLINE)

# Both cores always run. `make pc` opens the console + just the disassembly
# window; its OPEN-WINDOW keys (p/m/v/w/k/t/b/r) spawn the rest on demand, and the
# pipeline/chronogram keep recording in the background so they have scrollback
# when opened. `make pc smp` opens every window (both cores) up front.
ifneq ($(filter smp,$(MAKECMDGOALS)),)
PC_WINDOWS := mem vram code wave pipe cache tlb btb cpi pipe-ap btb-ap
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
	@echo "==== [1/5] ALU + cache suite (superscalar, coherent split-L1 MESI) ===="
	@rm -f $(BUILD)/tests.txt
	@for t in $(TESTS); do \
	    n=$${t%%_*}; \
	    $(SCRIPTS)/asm2hex.sh $(ASM)/$$t.asm $(BUILD)/$${n}_test.hex; \
	    $(SCRIPTS)/run_sim.sh --batch $(BUILD)/$${n}_test.hex >> $(BUILD)/tests.txt; \
	done
	@python3 $(SCRIPTS)/check_tests.py
	@python3 $(SCRIPTS)/verify_cache.py
	@echo "==== [2/5] paging suite (MMU + TLB + #PF) ===="
	@rm -f $(BUILD)/vm_tests.txt
	@for t in $(VMTESTS); do \
	    n=$${t%%_*}; \
	    $(SCRIPTS)/asm2hex.sh $(ASM)/$$t.asm $(BUILD)/$${n}_test.hex; \
	    $(SCRIPTS)/run_sim.sh --vm --batch $(BUILD)/$${n}_test.hex >> $(BUILD)/vm_tests.txt; \
	done
	@python3 $(SCRIPTS)/check_tests.py $(BUILD)/vm_tests.txt
	@echo "==== [3/5] SMP coherency (SIPI + MESI + LOCK CMPXCHG) ===="
	@$(SCRIPTS)/asm2hex.sh $(ASM)/smp_counter.asm $(BUILD)/smp_test.hex >/dev/null
	@$(SCRIPTS)/run_sim.sh --smp --batch $(BUILD)/smp_test.hex > $(BUILD)/smp_test.txt; \
	 grep -E "counter|COHERENCY" $(BUILD)/smp_test.txt; \
	 grep -q "SMP COHERENCY: PASS" $(BUILD)/smp_test.txt || { echo "  SMP COHERENCY FAILED"; exit 1; }
	@echo "==== [4/5] teaching-PC device suite (keyboard, PIC, ATA, VGA) ===="
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
	@echo "==== [5/5] gcc-compiled C (kernels/sort/mathops/fib, -O0 and -O2) ===="
	@printf '' > $(BUILD)/empty_keys.txt
	@fail=0; \
	 for prog in $(CPROGS); do \
	    case $$prog in \
	      kernels) want="1F 00 00 00 1B 00 00 00 78 00 00 00 19 00 00 00  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"; note="sum=31 dot=27 factorial=120 dist_sq=25";; \
	      sort)    want="01 00 00 00 02 00 00 00 03 00 00 00 05 00 00 00  07 00 00 00 09 00 00 00 1B 00 00 00 00 00 00 00"; note="sorted 1 2 3 5 7 9, checksum=27";; \
	      mathops) want="0C 00 00 00 8E 00 00 00 06 00 00 00 DF FF FF FF  FF FF FF FF 40 04 00 00 FB FF FF FF 58 02 00 00"; note="gcd=12 1000/7=142 %7=6 -100/3=-33 %3=-1 shifts=1088 schar=-5 uchar*3=600";; \
	      fib)     want="37 00 00 00 37 00 00 00 62 02 00 00 00 00 00 00  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"; note="fib(10)=55 iter=55 fib(15)=610";; \
	    esac; \
	    for o in O0 O2; do \
	        $(SCRIPTS)/cc2hex.sh c/$$prog.c $(BUILD)/$${prog}_$$o.hex -$$o > $(BUILD)/cc_$${prog}_$$o.txt 2>&1 \
	            || { echo "  $$prog -$$o: COMPILE FAILED"; cat $(BUILD)/cc_$${prog}_$$o.txt; fail=1; continue; }; \
	        $(SCRIPTS)/run_sim.sh --pc --batch --disk=$(PCDISK) --keys=$(BUILD)/empty_keys.txt \
	            $(BUILD)/$${prog}_$$o.hex > $(BUILD)/$${prog}_$${o}_run.txt 2>&1; \
	        if grep -q "^0x800  $$want" $(BUILD)/$${prog}_$${o}_run.txt; then \
	            echo "  $$prog -$$o: OK  ($$note)"; \
	        else echo "  $$prog -$$o: FAILED"; grep '^0x800' $(BUILD)/$${prog}_$${o}_run.txt | head -1; fail=1; fi; \
	    done; \
	 done; \
	 [ $$fail = 0 ] || { echo "  gcc C-kernel suite FAILED"; exit 1; }
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
	@command -v ghdl >/dev/null 2>&1 || { echo "ERROR: ghdl not found"; exit 1; }
	@# A C program (PROG=c/<x>.c) is compiled with gcc at $(OPT); its listing for
	@# the disassembly window comes from objdump. Otherwise it is a NASM .asm.
	@case "$(PROG)" in \
	  *.c) command -v gcc >/dev/null 2>&1 || { echo "ERROR: gcc not found"; exit 1; }; \
	       echo "Compiling $(PROG) with gcc $(OPT) ..."; \
	       $(SCRIPTS)/cc2hex.sh $(PROG) $(BUILD)/pc_prog.hex $(OPT) $(BUILD)/pc_prog.lst > /dev/null ;; \
	  *)   command -v nasm >/dev/null 2>&1 || { echo "ERROR: nasm not found"; exit 1; }; \
	       $(SCRIPTS)/asm2hex.sh $(PROG) $(BUILD)/pc_prog.hex > /dev/null; \
	       nasm -f bin $(PROG) -l $(BUILD)/pc_prog.lst -o /dev/null ;; \
	esac
	@if [ "$(VIEW)" = "1" ]; then \
	    if command -v $(TERM_APP) >/dev/null 2>&1; then \
	        for v in $(PC_WINDOWS); do \
	            pgrep -f "pc_view.py $$v " >/dev/null || \
	            ( setsid env PC_TERM_APP=$(TERM_APP) $(TERM_APP) -e python3 \
	                $(CURDIR)/$(SCRIPTS)/pc_view.py $$v $(CURDIR)/$(BUILD) >/dev/null 2>&1 & ); \
	        done; \
	    else echo "($(TERM_APP) not found: viewer windows skipped -- VIEW=0 silences this)"; fi; \
	fi
	@echo "Machine: PIPE=$(PIPE) BTB=$(BTB) CACHE=$(CACHE) L1=$(DSETS)set x $(DWAYS)way x $(DLINE)word   (press r in the disasm window for the CPI report)"
	@PC_SPEED=$(SPEED) PC_START_PAUSED=$(PAUSED) $(CFG_ENV) $(SCRIPTS)/run_sim.sh --pc --live --disk=$(PCDISK) \
	    --disk-out=$(BUILD)/pc_disk_out.hex \
	    $(BUILD)/pc_prog.hex

# `smp` is a modifier for `make pc smp` (open the AP windows too), not a target
# of its own -- it just needs a rule so make does not complain about the goal.
smp:
	@:

# `make cpi-compare PROG=<asm-or-c>` runs ONE program under several machine
# configurations and prints the measured CPI report for each, side by side --
# the headline teaching artifact (dual-issue vs scalar vs non-pipelined, branch
# prediction on/off, cache on/off/resized). Uses the same counters as the live
# `r` window. PROG may be an .asm or a c/<name>.c (compiled at $(OPT)).
cpi-compare: check-gcc $(PCDISK)
	@printf '' > $(BUILD)/empty_keys.txt
	@case "$(PROG)" in \
	  *.c) $(SCRIPTS)/cc2hex.sh $(PROG) $(BUILD)/pc_prog.hex $(OPT) $(BUILD)/pc_prog.lst > /dev/null ;; \
	  *)   $(SCRIPTS)/asm2hex.sh $(PROG) $(BUILD)/pc_prog.hex > /dev/null ;; \
	esac
	@python3 $(SCRIPTS)/cpi_compare.py $(BUILD)/pc_prog.hex $(PCDISK)

# ----------------------------------------------------------------- dependencies
# Typing `make` installs anything that is missing, so a fresh clone just works:
#   nasm / ghdl-llvm / gcc  -> apt (sudo will prompt for your password)
#   surfer                  -> cargo (rustup is bootstrapped first if absent)
APT := $(shell command -v apt-get 2>/dev/null)

# nasm + ghdl: assemble and simulate. Needed by every build/sim target.
check-tools:
	@missing=""; \
	 command -v nasm >/dev/null 2>&1 || missing="$$missing nasm"; \
	 command -v ghdl-mcode >/dev/null 2>&1 || missing="$$missing ghdl-mcode"; \
	 command -v ghdl >/dev/null 2>&1 || missing="$$missing ghdl-llvm"; \
	 if [ -n "$$missing" ]; then \
	   [ -n "$(APT)" ] || { echo "ERROR: apt-get not found. Install$$missing manually, then re-run make."; exit 1; }; \
	   echo ">> Installing:$$missing   (sudo may prompt for your password)"; \
	   sudo apt-get update && sudo apt-get install -y $$missing || { echo "ERROR: could not install$$missing."; exit 1; }; \
	 fi
	@$(MAKE) --no-print-directory check-llvm     # enable the faster LLVM backend if possible
	@if ghdl-mcode --version >/dev/null 2>&1 || ghdl-llvm --version >/dev/null 2>&1 || ghdl --version >/dev/null 2>&1; then :; else \
	   echo "ERROR: no working GHDL backend. Install the self-contained one:"; \
	   echo "           sudo apt install -y ghdl-mcode"; exit 1; fi

# The scripts prefer the LLVM GHDL backend (faster; prints a VHDL backtrace on an
# assertion). On Ubuntu the ghdl-llvm binary links the *versioned* LLVM soname
# (e.g. libLLVM-18.so.18.1) but the libllvmNN package ships it unversioned
# (libLLVM.so.18.1), so ghdl-llvm fails to load and the `ghdl` wrapper silently
# falls back to mcode. If that is the only gap, symlink it (one-time, sudo).
check-llvm:
	@command -v ghdl-llvm >/dev/null 2>&1 || exit 0; \
	 ghdl-llvm --version >/dev/null 2>&1 && exit 0; \
	 need=$$(ghdl-llvm --version 2>&1 | grep -oE 'libLLVM-[0-9]+\.so\.[0-9.]+' | head -1); \
	 [ -n "$$need" ] || { echo ">> ghdl-llvm cannot load; the build will use the mcode backend."; exit 0; }; \
	 ver=$$(echo "$$need" | sed -E 's/^libLLVM-([0-9]+).*/\1/'); \
	 echo ">> ghdl-llvm needs $$need (LLVM $$ver) -- providing it (sudo may prompt) ..."; \
	 if [ -n "$(APT)" ] && ! ls /usr/lib/llvm-$$ver/lib/libLLVM.so.* >/dev/null 2>&1 \
	    && ! ls /usr/lib/*/libLLVM.so.$$ver.* >/dev/null 2>&1; then \
	   sudo apt-get install -y libllvm$$ver >/dev/null 2>&1 || true; fi; \
	 real=$$(ls /usr/lib/*/libLLVM.so.$$ver.* 2>/dev/null | head -1); \
	 [ -n "$$real" ] || real=$$(ls /usr/lib/llvm-$$ver/lib/libLLVM.so.* 2>/dev/null | head -1); \
	 tgt=/usr/lib/$$(uname -m)-linux-gnu; [ -d "$$tgt" ] || tgt=$$(dirname "$$real" 2>/dev/null); \
	 if [ -n "$$real" ] && [ -n "$$tgt" ]; then \
	   echo ">> linking $$tgt/$$need -> $$real (sudo)"; \
	   sudo ln -sf "$$real" "$$tgt/$$need" && sudo ldconfig; fi; \
	 ghdl-llvm --version >/dev/null 2>&1 && echo ">> ghdl-llvm is now usable (fast backend)." \
	   || echo ">> LLVM backend still unavailable -- the build falls back to the mcode backend (self-contained; a bit slower)."

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

.PHONY: default pc smp cpi-compare clean check-tools check-gcc check-surfer check-llvm
