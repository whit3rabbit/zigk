/* ZigK Kernel Linker Script for x86_64
 * Loads kernel at higher half address (0xFFFFFFFF80000000)
 * Compatible with Limine bootloader protocol
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

/* Limine loads kernel at physical 0x0, maps to higher half */
KERNEL_PHYS_BASE = 0x0;
KERNEL_VIRT_BASE = 0xFFFFFFFF80000000;

SECTIONS
{
    /* Start at 2MB boundary for large page alignment */
    . = KERNEL_VIRT_BASE + 0x200000;

    /* Limine requests section - must be writable for bootloader responses */
    .limine_requests : AT(ADDR(.limine_requests) - KERNEL_VIRT_BASE)
    {
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests_end))
    }

    . = ALIGN(4K);

    /* Executable code */
    .text : AT(ADDR(.text) - KERNEL_VIRT_BASE)
    {
        _text_start = .;
        *(.text .text.*)
        _text_end = .;
    }

    . = ALIGN(4K);

    /* Read-only data */
    .rodata : AT(ADDR(.rodata) - KERNEL_VIRT_BASE)
    {
        _rodata_start = .;
        *(.rodata .rodata.*)
        _rodata_end = .;
    }

    . = ALIGN(4K);

    /* Initialized data */
    .data : AT(ADDR(.data) - KERNEL_VIRT_BASE)
    {
        _data_start = .;
        *(.data .data.*)
        _data_end = .;
    }

    . = ALIGN(4K);

    /* Uninitialized data (BSS) */
    .bss : AT(ADDR(.bss) - KERNEL_VIRT_BASE)
    {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
    }

    . = ALIGN(4K);
    _kernel_end = .;

    /* Calculate kernel size for memory reservation */
    _kernel_size = _kernel_end - KERNEL_VIRT_BASE;
    _kernel_phys_end = _kernel_size;

    /* Discard unnecessary sections */
    /DISCARD/ :
    {
        *(.note .note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
