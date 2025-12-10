/* ZigK Kernel Linker Script for x86_64 with Limine Bootloader
 *
 * Based on official limine-zig-barebones linker script.
 * Kernel loads at higher half (0xffffffff80000000) per Limine protocol.
 *
 * Critical: .limine_requests section needs its own PHDR for bootloader patching.
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)

ENTRY(_start)

PHDRS
{
    limine_requests PT_LOAD;
    text PT_LOAD;
    rodata PT_LOAD;
    data PT_LOAD;
}

SECTIONS
{
    /* Start at higher half (-2GB) as required by Limine */
    . = 0xffffffff80000000;

    /* Limine request structures - separate PHDR for bootloader discovery */
    .limine_requests : ALIGN(CONSTANT(MAXPAGESIZE)) {
        KEEP(*(.limine_requests_start_marker))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end_marker))
    } :limine_requests

    /* Executable code */
    .text : ALIGN(CONSTANT(MAXPAGESIZE)) {
        *(.text .text.*)
    } :text

    /* Read-only data */
    .rodata : ALIGN(CONSTANT(MAXPAGESIZE)) {
        *(.rodata .rodata.*)
    } :rodata

    /* Initialized data */
    .data : ALIGN(CONSTANT(MAXPAGESIZE)) {
        *(.data .data.*)
    } :data

    /* Uninitialized data (BSS) - must be last in data segment */
    .bss : ALIGN(CONSTANT(MAXPAGESIZE)) {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /* Discard unnecessary sections */
    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
        *(.comment)
    }
}
