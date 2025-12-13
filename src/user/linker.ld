/* Zscapek Userland Linker Script for x86_64
 * Userland programs are loaded at a fixed virtual address in user space
 * The kernel maps this region with Ring 3 permissions
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

/* Userland base address - must be in user-accessible address space
 * Lower half addresses are user space on x86_64
 * Start at 0x400000 (4MB) to leave space for NULL pointer guard pages
 */
USER_BASE = 0x400000;

SECTIONS
{
    . = USER_BASE;

    /* Executable code */
    .text : AT(ADDR(.text))
    {
        _text_start = .;
        *(.text .text.*)
        _text_end = .;
    }

    . = ALIGN(4K);

    /* Read-only data */
    .rodata : AT(ADDR(.rodata))
    {
        _rodata_start = .;
        *(.rodata .rodata.*)
        _rodata_end = .;
    }

    . = ALIGN(4K);

    /* Initialized data */
    .data : AT(ADDR(.data))
    {
        _data_start = .;
        *(.data .data.*)
        _data_end = .;
    }

    . = ALIGN(4K);

    /* Uninitialized data (BSS) */
    .bss : AT(ADDR(.bss))
    {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
    }

    . = ALIGN(4K);
    _end = .;

    /* Initial program break (heap start) is after BSS */
    _heap_start = .;

    /* Discard unnecessary sections */
    /DISCARD/ :
    {
        *(.note .note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
