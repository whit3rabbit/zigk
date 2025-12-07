/* ZigK Kernel Linker Script for x86_64 with Multiboot2
 *
 * Memory Layout:
 *   Physical 0x00100000 (1MB): Multiboot2 header + 32-bit bootstrap
 *   Physical 0x00101000+:      Kernel code and data
 *   Virtual  0xFFFFFFFF80100000: Kernel mapped at higher half
 *
 * The bootstrap code sets up page tables to map:
 *   - Identity: 0x00000000 -> 0x00000000 (first 4GB)
 *   - Kernel:   0xFFFFFFFF80000000 -> 0x00000000 (higher half -2GB)
 *   - HHDM:     0xFFFF800000000000 -> 0x00000000 (physical memory access)
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start32)

/* Physical and virtual base addresses */
KERNEL_PHYS_BASE = 0x1000000;
KERNEL_VIRT_BASE = 0xFFFFFFFF80100000;
KERNEL_VIRT_OFFSET = KERNEL_VIRT_BASE - KERNEL_PHYS_BASE;

PHDRS
{
    boot PT_LOAD FLAGS(7);      /* RWX for bootstrap */
    text PT_LOAD FLAGS(5);      /* R-X for code */
    rodata PT_LOAD FLAGS(4);    /* R-- for read-only data */
    data PT_LOAD FLAGS(6);      /* RW- for data */
}

SECTIONS
{
    /* =======================================================================
     * Bootstrap Section - loaded at physical 1MB, runs in 32-bit mode
     * Must be in first 32KB for Multiboot2 header requirement
     * ======================================================================= */
    . = KERNEL_PHYS_BASE;
    _boot_start = .;

    /* Multiboot2 header - must be within first 32KB of kernel image */
    .multiboot2 : {
        KEEP(*(.multiboot2))
    } :boot

    /* 32-bit bootstrap code */
    .boot32 : {
        *(.boot32)
    } :boot

    /* Bootstrap data (GDT, saved registers) */
    .boot_data : {
        *(.boot_data)
    } :boot

    . = ALIGN(4096);

    /* Bootstrap BSS (page tables) */
    .boot_bss (NOLOAD) : {
        *(.boot_bss)
    } :boot

    . = ALIGN(4096);
    _boot_end = .;

    /* Calculate physical address for kernel sections */
    _kernel_phys_start = .;

    /* =======================================================================
     * Kernel Sections - virtual addresses in higher half
     * Physical addresses continue from bootstrap end
     * ======================================================================= */

    /* Switch to virtual addresses for kernel code */
    . = KERNEL_VIRT_BASE + (_kernel_phys_start - KERNEL_PHYS_BASE);
    _kernel_virt_start = .;

    /* Executable code */
    .text : AT(_kernel_phys_start) {
        _text_start = .;
        *(.text .text.*)
        _text_end = .;
    } :text

    . = ALIGN(4096);
    _text_phys_end = _kernel_phys_start + (_text_end - _kernel_virt_start);

    /* Read-only data */
    .rodata : AT(_text_phys_end) {
        _rodata_start = .;
        *(.rodata .rodata.*)
        _rodata_end = .;
    } :rodata

    . = ALIGN(4096);
    _rodata_phys_end = _text_phys_end + (_rodata_end - _rodata_start);

    /* Initialized data */
    .data : AT(_rodata_phys_end) {
        _data_start = .;
        *(.data .data.*)
        _data_end = .;
    } :data

    . = ALIGN(4096);
    _data_phys_end = _rodata_phys_end + (. - _data_start);

    /* Uninitialized data (BSS) */
    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
    } :data

    . = ALIGN(4096);
    _kernel_end = .;
    _kernel_phys_end = _data_phys_end + (_kernel_end - _bss_start);

    /* Provide symbols for kernel */
    PROVIDE(_kernel_size = _kernel_end - _kernel_virt_start);
    PROVIDE(_kernel_phys_size = _kernel_phys_end - _kernel_phys_start);

    /* Discard unnecessary sections */
    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
        *(.comment)
    }
}
