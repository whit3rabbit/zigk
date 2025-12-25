/* Tell the linker that we want an AArch64 ELF64 output file */
OUTPUT_FORMAT(elf64-littleaarch64)

/* We want the symbol kentry to be our entry point */
ENTRY(kentry)

PHDRS
{
    limine_requests PT_LOAD;
    text PT_LOAD;
    rodata PT_LOAD;
    data PT_LOAD;
}

SECTIONS
{
    /* We want to be placed in the topmost 2GiB of the address space */
    . = 0xffffffff80000000;

    .limine_requests : {
        KEEP(*(.limine_requests_start_marker))
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
        KEEP(*(.limine_requests_end_marker))
    } :limine_requests

    . = ALIGN(65536);

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(65536);

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(65536);

    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }
}
