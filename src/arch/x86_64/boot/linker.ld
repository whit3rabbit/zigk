/* ZigK Kernel Linker Script for x86_64 with Limine Bootloader
 *
 * Memory Layout (set up by Limine):
 *   Virtual  0xFFFFFFFF80000000: Kernel mapped at higher half (-2GB)
 *   HHDM:    Provided by Limine (typically 0xFFFF800000000000)
 *
 * Limine handles:
 *   - 64-bit long mode transition
 *   - Page table setup (identity + HHDM + higher-half)
 *   - GDT/IDT setup (flat segments)
 *   - Stack allocation
 *
 * Critical: .limine_requests section must be writable for bootloader patching.
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

/* Virtual base address for kernel (higher half) */
KERNEL_VIRT_BASE = 0xFFFFFFFF80000000;

PHDRS
{
    text PT_LOAD FLAGS(5);      /* R-X for code */
    rodata PT_LOAD FLAGS(4);    /* R-- for read-only data */
    data PT_LOAD FLAGS(6);      /* RW- for data and limine_requests */
}

SECTIONS
{
    /* =======================================================================
     * Kernel Sections - virtual addresses in higher half
     * Limine loads the ELF and sets up page tables automatically
     * ======================================================================= */
    . = KERNEL_VIRT_BASE;
    _kernel_start = .;

    /* Executable code */
    .text : {
        _text_start = .;
        *(.text .text.*)
        _text_end = .;
    } :text

    . = ALIGN(4096);

    /* Read-only data */
    .rodata : {
        _rodata_start = .;
        *(.rodata .rodata.*)
        _rodata_end = .;
    } :rodata

    . = ALIGN(4096);

    /* Limine request structures - MUST be writable for bootloader patching
     * Limine scans for magic IDs in this section and patches response pointers
     */
    .limine_requests : {
        _limine_requests_start = .;
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests.*))
        _limine_requests_end = .;
    } :data

    /* Initialized data */
    .data : {
        _data_start = .;
        *(.data .data.*)
        _data_end = .;
    } :data

    . = ALIGN(4096);

    /* Uninitialized data (BSS) */
    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
    } :data

    . = ALIGN(4096);
    _kernel_end = .;

    /* Provide symbols for kernel */
    PROVIDE(_kernel_size = _kernel_end - _kernel_start);

    /* Discard unnecessary sections */
    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
        *(.comment)
        /* Discard old multiboot2 and boot32 sections if present */
        *(.multiboot2)
        *(.boot32)
        *(.boot_data)
        *(.boot_bss)
    }
}
