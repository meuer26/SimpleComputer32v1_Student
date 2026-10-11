/*
 * pc_host.c -- the "monitor and keyboard" of the teaching PC.
 *
 * GHDL calls these functions directly from tb_pc.vhd (VHPIDIRECT), so a live
 * simulation can be used like a real computer:
 *
 *   - Every byte the CPU stores into VGA text memory (0xB8000) is forwarded
 *     here and drawn in the terminal (code page 437 glyphs, VGA colours).
 *   - The CRTC cursor registers (ports 0x3D4/0x3D5) position the terminal
 *     cursor.
 *   - Keys typed in the terminal are turned into genuine PC scan codes
 *     (set 1: make code on press, make|0x80 on release, 0xE0 prefix for the
 *     extended keys, Shift/Ctrl wrapped around the key) and handed one byte at
 *     a time to the 8042 keyboard controller model. The program in the CPU
 *     sees exactly the bytes a real PC delivers at port 0x60 -- it has to
 *     translate scan codes to ASCII itself.
 *
 * A terminal only reports characters, not key-up events, so each typed
 * character becomes a press immediately followed by its release.
 *
 * Ctrl-] ends the session. Build: gcc -shared -fPIC -o libpchost.so pc_host.c
 *
 * Live state for the viewer windows (scripts/pc_view.py): the simulation also
 * publishes RAM, video RAM, registers and EIP into the shared file
 * build/pc_state.bin (mmap), and reads back the viewers' speed controls
 * (cycles per second, pause, single-step). Layout (little-endian):
 *     0 "PCV1"   4 session   8 running (1 live, 2 ended)   12 seq
 *    16 u64 cycle   24 u32 EAX ECX EDX EBX ESP EBP ESI EDI
 *    56 EIP   60 EFLAGS   64 halted   68 IRQs taken   72 IDT base
 *    76 last RAM write address   80 POST code
 *    84 speed (cycles/s, 0 = full)   88 paused   92 run to a boundary:
 *       1 step, 2 pause                                        [viewer-written]
 *    96 char state[16]   112 chronogram heartbeat (unix time) [viewer-written]
 *   116 u16 D1 D2 EX WB instruction addresses   124 stage valid bits (8 D1
 *       4 D2 2 EX 1 WB)   125 stall cause   126 prefetch-queue bytes
 *   128 RAM[4096]   4224 video RAM[4096]
 *  8320 u32 samples written   8448 ring of WAVE_N per-cycle samples, 64 bytes:
 *        0 cycle  4 EIP  8 bus address  12 bus data  16 EAX  20 u16 I/O port
 *       22 I/O data (low byte)  23 bits: 0 mem_req 1 WE 2 io_re 3 io_we
 *          4 INTR 5 INTA 6 halted  24 bits: 0 IRQ1 1 IRQ14 2 8042 OBF
 *       25 vector  26 PIC1 ISR  27 PIC1 IRR  28 char state[12]
 *       40 u16 D1 D2 EX WB addresses  48 u16 D1 D2 EX WB sequence tags
 *       56 stage valid bits  57 stall cause  58 queue bytes  60 u32 PF address
 *   After the ring: u32 current memory-read bus address, then u32 read class
 *       (0 none, 1 program data read, 2 instruction prefetch/fetch) -- the RAM
 *       viewer lights the whole aligned 32-bit word the data bus carries,
 *       colour-coded by class, matching Surfer -- then u32 CR3 (page-table base).
 * Stall causes: 0 none 1 microcode 2 AGI 3 branch 4 queue empty 5 mem wait
 *               6 bus busy 7 halt
 * The per-cycle samples are only taken while a chronogram window is open
 * (its heartbeat is less than 3 s old).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <termios.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <stdint.h>

#define COLS 80
#define ROWS 25
#define QSIZE 4096

static int live;
static struct termios saved_tio;
static unsigned char vram[COLS * ROWS * 2];
static unsigned char shown[COLS * ROWS * 2];
static int shown_valid;
static int dirty, cursor_pos = 0, cursor_shown = -1;
static unsigned char q[QSIZE];
static int qh, qt;
static int quit_req;
static char console[COLS + 1];
static int console_len;
static int post_code = -1;
static double last_draw, last_status;
static long long last_cycle;

/* ---------------------------------------------- shared state for viewers */
#define ST_RAM  128
#define ST_VRAM 4224
#define ST_WCNT 8320
#define ST_WAVE 8448
#define WAVE_N  4096
#define WAVE_SZ 72          /* 64 B base record + V-pipe (v_eip u16, v_seq u16, v_valid u8) */
#define ST_READ (ST_WAVE + WAVE_N * WAVE_SZ)   /* current memory read: 0 bus addr, 4 class */
#define ST_CR3  (ST_READ + 8)                  /* CR3 (page-table base) */
/* Appended (additive) blocks: a per-cycle "system" block (BSP superscalar pair
 * state, the AP core, the coherent-L1 stats, the paging stats) and a second
 * wave ring for the AP's pipeline chart. All strictly after the original
 * layout, so existing viewer offsets are untouched. */
#define ST_SYS    (ST_CR3 + 4)                  /* 128-byte system/SMP/cache/paging block */
#define SYS_AP_WCNT 88                          /* AP wave-ring sample counter (within ST_SYS) */
#define SYS_CACHE_HB 92                         /* cache-window heartbeat (within ST_SYS) */
#define SYS_BTB_HB   96                         /* BTB-window heartbeat (within ST_SYS) */
#define ST_WAVEAP (ST_SYS + 128)                /* AP pipeline sample ring (same 64-byte records) */
#define ST_CACHE  (ST_WAVEAP + WAVE_N * WAVE_SZ) /* core-0 cache contents: D data 256B, I data 256B, D meta 8B, I meta 8B */
#define ST_BTB    (ST_CACHE + 576)              /* both cores' BTB: 72 B each (8 tags, 8 targets, 8 meta bytes) */
/* Performance counters for the CPI report (12 u32): instructions retired, the
 * eight stall-cause cycle buckets (0 none .. 7 halted), BTB correct/wrong, and
 * the 32-bit U/V pair count.  Appended at the end so no earlier offset moves. */
#define ST_PERF   (ST_BTB + 256)
#define ST_SIZE   (ST_PERF + 128)   /* perf counters (0..44) + machine config (48..) */
static unsigned char *st;                       /* mmap of build/pc_state.bin */
#define PERF32(o) (*(volatile uint32_t *)(st + ST_PERF + (o)))
#define SYS32(o) (*(volatile uint32_t *)(st + ST_SYS + (o)))
#define ST32(off) (*(volatile uint32_t *)(st + (off)))
static double pace_t0;
static long long pace_c0;
static uint32_t pace_speed;
static int was_paused;
static long long step_from = -1;               /* cycle a run-to-boundary began */
static FILE *keylog;                            /* build/pc_keys.log: "<cycle> <scan code>" */

static void st_open(void)
{
    int fd = open("pc_state.bin", O_RDWR | O_CREAT, 0644);   /* cwd = build/ */
    if (fd < 0) return;
    if (ftruncate(fd, ST_SIZE) != 0) { close(fd); return; }
    void *m = mmap(NULL, ST_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return;
    st = m;
    memset(st, 0, ST_SIZE);
    memcpy(st, "PCV1", 4);
    ST32(4) = (uint32_t)time(NULL);
    ST32(8) = 1;
    const char *sp = getenv("PC_SPEED");          /* initial cycles/s (0 = full) */
    if (sp) ST32(84) = (uint32_t)atoi(sp);
    const char *pz = getenv("PC_START_PAUSED");   /* hold before the 1st instruction */
    if (pz && atoi(pz)) ST32(88) = 1;
    for (int i = 0; i < COLS * ROWS; i++) { st[ST_VRAM + 2 * i] = ' '; st[ST_VRAM + 2 * i + 1] = 7; }
}

/* ------------------------------------------------------------ CP437 glyphs */
static const char *cp437[256] = {
    " ", "☺", "☻", "♥", "♦", "♣", "♠", "•", "◘", "○", "◙", "♂", "♀", "♪", "♫", "☼",
    "►", "◄", "↕", "‼", "¶", "§", "▬", "↨", "↑", "↓", "→", "←", "∟", "↔", "▲", "▼",
    " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
    "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
    "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_",
    "`", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
    "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "{", "|", "}", "~", "⌂",
    "Ç", "ü", "é", "â", "ä", "à", "å", "ç", "ê", "ë", "è", "ï", "î", "ì", "Ä", "Å",
    "É", "æ", "Æ", "ô", "ö", "ò", "û", "ù", "ÿ", "Ö", "Ü", "¢", "£", "¥", "₧", "ƒ",
    "á", "í", "ó", "ú", "ñ", "Ñ", "ª", "º", "¿", "⌐", "¬", "½", "¼", "¡", "«", "»",
    "░", "▒", "▓", "│", "┤", "╡", "╢", "╖", "╕", "╣", "║", "╗", "╝", "╜", "╛", "┐",
    "└", "┴", "┬", "├", "─", "┼", "╞", "╟", "╚", "╔", "╩", "╦", "╠", "═", "╬", "╧",
    "╨", "╤", "╥", "╙", "╘", "╒", "╓", "╫", "╪", "┘", "┌", "█", "▄", "▌", "▐", "▀",
    "α", "ß", "Γ", "π", "Σ", "σ", "µ", "τ", "Φ", "Θ", "Ω", "δ", "∞", "φ", "ε", "∩",
    "≡", "±", "≥", "≤", "⌠", "⌡", "÷", "≈", "°", "∙", "·", "√", "ⁿ", "²", "■", " ",
};

/* VGA colour index (0 black 1 blue 2 green 3 cyan 4 red 5 magenta 6 brown 7 grey)
 * -> ANSI colour index (0 black 1 red 2 green 3 yellow 4 blue 5 magenta 6 cyan 7 white) */
static const int vga2ansi[8] = {0, 4, 2, 6, 1, 5, 3, 7};

/* ------------------------------------------------------- scan codes, set 1 */
/* make code of the key that produces this ASCII character, and whether Shift
 * is needed for it (US layout). 0 = no key. */
static unsigned char sc_of[128], shift_of[128];

static void map(const char *keys, const char *shifted, unsigned char first)
{
    for (int i = 0; keys[i]; i++) {
        sc_of[(unsigned char)keys[i]] = first + i;
        if (shifted && shifted[i] != ' ') {
            sc_of[(unsigned char)shifted[i]] = first + i;
            shift_of[(unsigned char)shifted[i]] = 1;
        }
    }
}

static void init_scancodes(void)
{
    map("1234567890-=", "!@#$%^&*()_+", 0x02);
    map("qwertyuiop[]", "QWERTYUIOP{}", 0x10);
    map("asdfghjkl;'`", "ASDFGHJKL:\"~", 0x1E);
    map("\\zxcvbnm,./", "|ZXCVBNM<>?", 0x2B);
    sc_of[' '] = 0x39;
    sc_of['\r'] = 0x1C; sc_of['\n'] = 0x1C;   /* Enter */
    sc_of['\t'] = 0x0F;                       /* Tab */
    sc_of[0x7F] = 0x0E; sc_of[0x08] = 0x0E;   /* Backspace */
    sc_of[0x1B] = 0x01;                       /* Esc */
}

static void push(unsigned char b)
{
    int n = (qt + 1) % QSIZE;
    if (n != qh) { q[qt] = b; qt = n; }
}

static void key(unsigned char make, int shift, int ctrl)
{
    if (ctrl)  push(0x1D);                    /* LCtrl make */
    if (shift) push(0x2A);                    /* LShift make */
    push(make);
    push(make | 0x80);
    if (shift) push(0xAA);                    /* LShift break */
    if (ctrl)  push(0x9D);                    /* LCtrl break */
}

static void ext_key(unsigned char make)       /* E0-prefixed (arrows, Del, ...) */
{
    push(0xE0); push(make);
    push(0xE0); push(make | 0x80);
}

static void translate(const unsigned char *b, int n)
{
    for (int i = 0; i < n; i++) {
        unsigned char c = b[i];
        if (c == 0x1D) { quit_req = 1; return; }            /* Ctrl-] */
        if (c == 0x1B && i + 2 < n + 0 && b[i + 1] == '[') {  /* ESC [ x */
            unsigned char f = b[i + 2];
            int used = 2;
            switch (f) {
            case 'A': ext_key(0x48); break;   /* Up */
            case 'B': ext_key(0x50); break;   /* Down */
            case 'C': ext_key(0x4D); break;   /* Right */
            case 'D': ext_key(0x4B); break;   /* Left */
            case 'H': ext_key(0x47); break;   /* Home */
            case 'F': ext_key(0x4F); break;   /* End */
            case '3':                         /* Delete: ESC [ 3 ~ */
                ext_key(0x53);
                if (i + 3 < n && b[i + 3] == '~') used = 3;
                break;
            default: used = 0; key(0x01, 0, 0); break;      /* lone Esc */
            }
            i += used;
            continue;
        }
        if (c < 128 && sc_of[c]) {
            key(sc_of[c], shift_of[c], 0);
        } else if (c >= 1 && c <= 26) {                      /* Ctrl-letter */
            key(sc_of['a' + c - 1], 0, 1);
        }
    }
}

/* ------------------------------------------------------------- rendering */
static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void draw(int force)
{
    static char out[COLS * ROWS * 40 + 1024];
    int o = 0, last_attr = -1;
    for (int i = 0; i < COLS * ROWS; i++) {
        unsigned char ch = vram[2 * i], at = vram[2 * i + 1];
        if (!force && shown_valid && shown[2 * i] == ch && shown[2 * i + 1] == at)
            continue;
        shown[2 * i] = ch; shown[2 * i + 1] = at;
        int r = i / COLS, c = i % COLS;
        o += sprintf(out + o, "\033[%d;%dH", r + 2, c + 2);
        if (at != last_attr) {
            int fg = at & 7, bright = at & 8, bg = (at >> 4) & 7;
            o += sprintf(out + o, "\033[0;%d;%dm",
                         (bright ? 90 : 30) + vga2ansi[fg], 40 + vga2ansi[bg]);
            last_attr = at;
        }
        o += sprintf(out + o, "%s", cp437[ch]);
        if (o > (int)sizeof(out) - 64) { fwrite(out, 1, o, stdout); o = 0; }
    }
    shown_valid = 1;
    o += sprintf(out + o, "\033[0m");
    if (cursor_pos >= 0 && cursor_pos < COLS * ROWS)
        o += sprintf(out + o, "\033[%d;%dH\033[?25h",
                     cursor_pos / COLS + 2, cursor_pos % COLS + 2);
    else
        o += sprintf(out + o, "\033[?25l");
    fwrite(out, 1, o, stdout);
    fflush(stdout);
    cursor_shown = cursor_pos;
    dirty = 0;
}

static void draw_status(void)
{
    printf("\0337\033[%d;1H\033[0;7m Ctrl-] quits \033[0m\033[K\0338", ROWS + 3);
    fflush(stdout);
}

static void frame(void)
{
    printf("\033[0m\033[2J\033[1;1H┌");
    for (int i = 0; i < COLS; i++) printf("─");
    printf("┐");
    for (int r = 0; r < ROWS; r++)
        printf("\033[%d;1H│\033[%d;%dH│", r + 2, r + 2, COLS + 2);
    printf("\033[%d;1H└", ROWS + 2);
    for (int i = 0; i < COLS; i++) printf("─");
    printf("┘");
}

static void restore(void)
{
    if (!live) return;
    printf("\033[0m\033[?25h\033[?1049l");
    fflush(stdout);
    tcsetattr(0, TCSANOW, &saved_tio);
    live = 0;
}

/* ------------------------------------------------------- VHDL entry points */
int host_init(int live_mode)
{
    init_scancodes();
    for (int i = 0; i < COLS * ROWS; i++) { vram[2 * i] = ' '; vram[2 * i + 1] = 0x07; }
    live = live_mode;
    if (!live) return 0;
    if (!isatty(0) || tcgetattr(0, &saved_tio) != 0) {
        fprintf(stderr, "pc_host: stdin is not a terminal; live mode needs one\n");
        live = 0;
        return -1;
    }
    struct winsize ws;
    if (ioctl(1, TIOCGWINSZ, &ws) == 0 && (ws.ws_col < COLS + 2 || ws.ws_row < ROWS + 3))
        fprintf(stderr, "pc_host: terminal is %dx%d, at least %dx%d is needed\n",
                ws.ws_col, ws.ws_row, COLS + 2, ROWS + 3);
    st_open();
    keylog = fopen("pc_keys.log", "w");         /* cwd = build/ */
    struct termios t = saved_tio;
    t.c_lflag &= ~(ICANON | ECHO | ISIG | IEXTEN);
    t.c_iflag &= ~(IXON | ICRNL | BRKINT | INPCK | ISTRIP);
    t.c_cc[VMIN] = 0;
    t.c_cc[VTIME] = 0;
    tcsetattr(0, TCSANOW, &t);
    atexit(restore);
    printf("\033[?1049h");
    frame();
    draw(1);
    draw_status();
    last_draw = last_status = now();
    return 0;
}

/* Called every few hundred simulated cycles. Returns the next scan-code byte,
 * -1 if none is waiting, -2 if the user asked to quit. */
int host_poll_key(int halted, int cycle)
{
    if (!live) return -1;
    last_cycle = cycle;
    unsigned char b[64];
    int n = read(0, b, sizeof b);
    if (n > 0) translate(b, n);
    double t = now();
    if (dirty && t - last_draw > 0.03) { draw(0); last_draw = t; }
    if (cursor_shown != cursor_pos) draw(0);
    if (t - last_status > 0.25) { draw_status(); last_status = t; }
    if (quit_req) return -2;
    if (qh != qt) {
        unsigned char c = q[qh];
        qh = (qh + 1) % QSIZE;
        /* The simulation injects it at this very cycle. Logged (and flushed at
         * once) so the session can be replayed exactly -- even while it runs. */
        if (keylog) { fprintf(keylog, "%d %02X\n", cycle, c); fflush(keylog); }
        return c;
    }
    /* CPU idle in HLT at full speed: do not burn the host CPU. (When the
     * viewers set a speed, host_cpu's pacing already does the waiting.) */
    if (halted && !(st && ST32(84))) usleep(200);
    return -1;
}

void host_vga_write(int offset, int value)
{
    if (offset >= 0 && offset < COLS * ROWS * 2) {
        vram[offset] = (unsigned char)value;
        dirty = 1;
    }
    if (st && offset >= 0 && offset < 4096) st[ST_VRAM + offset] = (unsigned char)value;
}

/* A byte of RAM changed (and, at start-up, the initial RAM image). */
void host_mem_write(int addr, int value)
{
    if (!st) return;
    st[ST_RAM + (addr & 0xFFF)] = (unsigned char)value;
    ST32(76) = (uint32_t)addr;
}

static void sleep_s(double s)
{
    struct timespec ts = { (time_t)s, (long)((s - (time_t)s) * 1e9) };
    nanosleep(&ts, NULL);
}

/* CPU state, every few cycles. Also applies the viewers' speed controls:
 * pacing to N cycles per second, pause, and single-step (run to the next
 * instruction boundary = the next instruction retiring). Returns how many cycles the
 * simulation may run before calling again. */
int host_cpu(int cycle, int eip, int eax, int ecx, int edx, int ebx, int esp,
             int ebp, int esi, int edi, int eflags, int halted, int irqs,
             int ivt, int s0, int s1, int s2, int boundary,
             int d1, int d2, int ex, int wb, int valid, int stall, int pq,
             int rd_addr, int rd_read, int cr3)
{
    if (!st) return 200;
    last_cycle = cycle;                         /* for the status line */
    int r[8] = {eax, ecx, edx, ebx, esp, ebp, esi, edi};
    *(volatile uint64_t *)(st + 16) = (uint64_t)(uint32_t)cycle;
    for (int i = 0; i < 8; i++) ST32(24 + 4 * i) = (uint32_t)r[i];
    ST32(56) = (uint32_t)eip;  ST32(60) = (uint32_t)eflags;
    ST32(64) = (uint32_t)halted; ST32(68) = (uint32_t)irqs; ST32(72) = (uint32_t)ivt;
    int sw[3] = {s0, s1, s2};
    for (int i = 0; i < 3; i++)
        for (int k = 0; k < 4; k++)
            st[96 + 4 * i + k] = (unsigned char)((uint32_t)sw[i] >> (24 - 8 * k));
    uint16_t sa[4] = {(uint16_t)d1, (uint16_t)d2, (uint16_t)ex, (uint16_t)wb};
    memcpy(st + 116, sa, sizeof sa);
    st[124] = (unsigned char)valid; st[125] = (unsigned char)stall; st[126] = (unsigned char)pq;
    /* The 32-bit memory-read cycle in flight at this sample: the aligned bus
     * address and its class (0 none, 1 data read, 2 instruction fetch). The RAM
     * viewer lights the whole word, coloured by class. */
    ST32(ST_READ)     = (uint32_t)rd_addr;
    ST32(ST_READ + 4) = (uint32_t)rd_read;
    ST32(ST_CR3)      = (uint32_t)cr3;
    ST32(12) = ST32(12) + 1;

    /* Run-to-boundary requests (offset 92), then hold if paused:
     *   1 = single step: run until the NEXT instruction completes
     *   2 = pause: stop at the first instruction boundary, which may be this
     *       very cycle -- or at once if the CPU is asleep in HLT
     * `boundary` comes from the core: the cycle after an instruction retired
     * (its results are visible), for the multi-cycle and pipelined cores alike. */
    uint32_t req = ST32(92);
    if (!req) step_from = -1;
    else if (step_from < 0) step_from = cycle;
    if (req == 1 && boundary && !halted && cycle > step_from) { ST32(92) = 0; step_from = -1; }
    if (req == 2 && (boundary || halted)) { ST32(92) = 0; step_from = -1; }

    /* pause: hold the simulation, but keep the screen and keyboard alive */
    while (ST32(88) && !ST32(92) && !quit_req) {
        was_paused = 1;
        unsigned char b[64];
        int n = read(0, b, sizeof b);
        if (n > 0) translate(b, n);
        if (dirty) draw(0);
        if (now() - last_status > 0.25) { draw_status(); last_status = now(); }
        sleep_s(0.02);
    }
    /* A step requested while paused counts from THIS cycle, so the very next
     * instruction boundary ends it (on the pipeline that can be next cycle). */
    if (ST32(92) && step_from < 0) step_from = cycle;

    /* pacing: hold the simulation to `speed` cycles per wall-clock second */
    uint32_t speed = ST32(84);
    double now_t = now();
    if (speed != pace_speed || was_paused || now_t - pace_t0 > 1e6) {
        pace_speed = speed; pace_t0 = now_t; pace_c0 = cycle; was_paused = 0;
    }
    if (speed && !ST32(92)) {                 /* a single step runs flat out */
        double target = pace_t0 + (double)(cycle - pace_c0) / speed;
        if (target - now_t > 0.002) sleep_s(target - now_t);
        else if (now_t - target > 0.5) { pace_t0 = now_t; pace_c0 = cycle; }
    }
    /* Paused / stepping: check every cycle. Paced: often enough to pace in
     * ~4 ms slices (every cycle at slow speeds). Full speed: every 200. */
    int n = 200;
    if (ST32(88) || ST32(92)) n = 1;
    else if (speed) { n = (int)(speed / 250); n = n < 1 ? 1 : (n > 200 ? 200 : n); }
    /* +1000000: the chronogram window is open, send a sample every cycle */
    int wave = ST32(112) && (uint32_t)time(NULL) - ST32(112) < 3;
    return n + (wave ? 1000000 : 0);
}

/* One clock cycle for the chronogram window. */
void host_wave(int cycle, int eip, int addr, int data, int eax, int io_addr,
               int io_data, int bits, int irqs, int vector, int isr, int irr,
               int s0, int s1, int s2,
               int d1, int d2, int ex, int wb, int q1, int q2, int qe, int qw,
               int valid, int stall, int pq, int pfaddr,
               int v_eip, int v_seq, int v_valid)
{
    if (!st) return;
    uint32_t n = ST32(ST_WCNT);
    unsigned char *r = st + ST_WAVE + (n % WAVE_N) * WAVE_SZ;
    uint32_t v[5] = {(uint32_t)cycle, (uint32_t)eip, (uint32_t)addr, (uint32_t)data, (uint32_t)eax};
    memcpy(r, v, sizeof v);
    r[20] = io_addr & 0xFF; r[21] = (io_addr >> 8) & 0xFF;
    r[22] = io_data; r[23] = bits; r[24] = irqs; r[25] = vector; r[26] = isr; r[27] = irr;
    int sw[3] = {s0, s1, s2};
    for (int i = 0; i < 3; i++)
        for (int k = 0; k < 4; k++)
            r[28 + 4 * i + k] = (unsigned char)((uint32_t)sw[i] >> (24 - 8 * k));
    uint16_t pv[8] = {(uint16_t)d1, (uint16_t)d2, (uint16_t)ex, (uint16_t)wb,
                      (uint16_t)q1, (uint16_t)q2, (uint16_t)qe, (uint16_t)qw};
    memcpy(r + 40, pv, sizeof pv);
    r[56] = (unsigned char)valid; r[57] = (unsigned char)stall; r[58] = (unsigned char)pq;
    uint32_t pa = (uint32_t)pfaddr;
    memcpy(r + 60, &pa, 4);
    uint16_t ve = (uint16_t)v_eip, vs = (uint16_t)v_seq;      /* V-pipe co-issue */
    memcpy(r + 64, &ve, 2); memcpy(r + 66, &vs, 2); r[68] = (unsigned char)v_valid;
    ST32(ST_WCNT) = n + 1;
}

/* Per-cycle "system" state for the SMP / cache / paging viewer windows:
 *   BSP superscalar: v_valid (a U/V pair co-issued this cycle), pairs (running total)
 *   AP core:         pc, halted, pipeline-stage occupancy, its own co-issue, state name
 *   coherent L1:     I/D hits+misses, snoop invalidations, write-backs, MESI line states, bus grant
 *   paging:          TLB translations, page-table walks, faults, CR2 */
void host_sys(int v_valid, int pairs, int ap_pc, int ap_halted, int ap_stage, int ap_vvalid,
              int aps0, int aps1, int aps2, int ichit, int icmiss, int dchit, int dcmiss,
              int inval, int wb, int c0st, int c1st, int grant,
              int trans, int walks, int faults, int cr2)
{
    if (!st) return;
    SYS32(0) = (uint32_t)v_valid; SYS32(4) = (uint32_t)pairs;
    SYS32(8) = (uint32_t)ap_pc;   SYS32(12) = (uint32_t)ap_halted;
    SYS32(16) = (uint32_t)ap_stage; SYS32(20) = (uint32_t)ap_vvalid;
    int sw[3] = {aps0, aps1, aps2};
    for (int i = 0; i < 3; i++)
        for (int k = 0; k < 4; k++)
            st[ST_SYS + 24 + 4 * i + k] = (unsigned char)((uint32_t)sw[i] >> (24 - 8 * k));
    SYS32(36) = (uint32_t)ichit; SYS32(40) = (uint32_t)icmiss;
    SYS32(44) = (uint32_t)dchit; SYS32(48) = (uint32_t)dcmiss;
    SYS32(52) = (uint32_t)inval; SYS32(56) = (uint32_t)wb;
    SYS32(60) = (uint32_t)c0st;  SYS32(64) = (uint32_t)c1st;  SYS32(68) = (uint32_t)grant;
    SYS32(72) = (uint32_t)trans; SYS32(76) = (uint32_t)walks; SYS32(80) = (uint32_t)faults;
    SYS32(84) = (uint32_t)cr2;
}

/* Performance counters for the CPI report window: instructions retired, the
 * eight stall-cause cycle buckets (0 none, 1 microcode, 2 AGI, 3 branch,
 * 4 queue-empty, 5 mem-wait, 6 bus-busy, 7 halted), BTB correct/mispredicted,
 * and the 32-bit U/V pair count. */
void host_perf(int instret, int s0, int s1, int s2, int s3, int s4, int s5,
               int s6, int s7, int btb_ok, int btb_bad, int pairs32)
{
    if (!st) return;
    int v[12] = {instret, s0, s1, s2, s3, s4, s5, s6, s7, btb_ok, btb_bad, pairs32};
    for (int i = 0; i < 12; i++) PERF32(4 * i) = (uint32_t)v[i];
}

/* The active machine configuration (static for a run), so the CPI window can
 * label each report SUPER/SCALAR/NON-PIPELINED, BTB on/off, cache on/off, and
 * the L1 geometry.  dual/serial/btb/cache are 0/1; sets/ways/line are counts. */
void host_config(int dual, int serial, int btb, int cache, int sets, int ways, int line)
{
    if (!st) return;
    int v[7] = {dual, serial, btb, cache, sets, ways, line};
    for (int i = 0; i < 7; i++) PERF32(48 + 4 * i) = (uint32_t)v[i];
}

/* One clock cycle for the AP's pipeline chart -- the same 64-byte record layout
 * host_wave uses (so pc_view's parser is shared), in the AP's own ring. */
void host_wave_ap(int cycle, int eip, int d1, int d2, int ex, int wb,
                  int q1, int q2, int qe, int qw, int valid, int stall, int pq,
                  int s0, int s1, int s2, int v_eip, int v_seq, int v_valid)
{
    if (!st) return;
    uint32_t n = SYS32(SYS_AP_WCNT);
    unsigned char *r = st + ST_WAVEAP + (n % WAVE_N) * WAVE_SZ;
    uint32_t v[5] = {(uint32_t)cycle, (uint32_t)eip, 0, 0, 0};
    memcpy(r, v, sizeof v);
    int sw[3] = {s0, s1, s2};
    for (int i = 0; i < 3; i++)
        for (int k = 0; k < 4; k++)
            r[28 + 4 * i + k] = (unsigned char)((uint32_t)sw[i] >> (24 - 8 * k));
    uint16_t pv[8] = {(uint16_t)d1, (uint16_t)d2, (uint16_t)ex, (uint16_t)wb,
                      (uint16_t)q1, (uint16_t)q2, (uint16_t)qe, (uint16_t)qw};
    memcpy(r + 40, pv, sizeof pv);
    r[56] = (unsigned char)valid; r[57] = (unsigned char)stall; r[58] = (unsigned char)pq;
    uint16_t ve = (uint16_t)v_eip, vs = (uint16_t)v_seq;
    memcpy(r + 64, &ve, 2); memcpy(r + 66, &vs, 2); r[68] = (unsigned char)v_valid;
    SYS32(SYS_AP_WCNT) = n + 1;
}

/* Does the cache-contents viewer window want a fresh dump this cycle? (It beats
 * SYS_CACHE_HB like the chronogram does, so we only copy the cache when open.) */
int host_cache_wanted(void)
{
    if (!st) return 0;
    if (ST32(88)) return 1;                 /* paused: dump so a window opened now shows current data */
    uint32_t hb = SYS32(SYS_CACHE_HB);
    return (hb && (uint32_t)time(NULL) - hb < 3) ? 1 : 0;
}

/* One 32-bit word of the core-0 cache-contents snapshot, at byte offset `off`. */
void host_cache(int off, int word)
{
    if (!st || off < 0 || off + 4 > 576) return;
    *(volatile uint32_t *)(st + ST_CACHE + off) = (uint32_t)word;
}

/* Does a BTB-contents window want a fresh dump this cycle? */
int host_btb_wanted(void)
{
    if (!st) return 0;
    if (ST32(88)) return 1;                 /* paused: dump so a window opened now shows current data */
    uint32_t hb = SYS32(SYS_BTB_HB);
    return (hb && (uint32_t)time(NULL) - hb < 3) ? 1 : 0;
}

/* One 32-bit word of the two-core BTB snapshot, at byte offset `off`. */
void host_btb(int off, int word)
{
    if (!st || off < 0 || off + 4 > 256) return;
    *(volatile uint32_t *)(st + ST_BTB + off) = (uint32_t)word;
}

void host_cursor(int pos)
{
    cursor_pos = pos;
}

void host_console(int ch)
{
    if (ch == '\n' || console_len >= COLS) console_len = 0;
    if (ch >= 32 && ch < 127) console[console_len++] = (char)ch;
    console[console_len] = 0;
}

void host_post(int code)
{
    post_code = code & 0xFF;
    if (st) ST32(80) = (uint32_t)post_code;
}

void host_close(void)
{
    if (live) { draw(0); draw_status(); }
    if (st) { ST32(8) = 2; msync(st, ST_SIZE, MS_ASYNC); }
    if (keylog) { fclose(keylog); keylog = NULL; }
    restore();
}
