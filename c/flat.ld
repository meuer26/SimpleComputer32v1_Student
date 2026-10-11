/* Lay the program out contiguously from address 0 (reset vector) so code, read-
 * only data and data all fit in the teaching machine's low RAM. */
ENTRY(_start)
SECTIONS {
    . = 0;
    .text   : { *(.text._start) *(.text*) }
    .rodata : { *(.rodata*) }
    .data   : { *(.data*) }
    .bss    : { *(.bss*) *(COMMON) }
    _end = .;
}
