/* ZigK Multiboot2 Bootstrap
 *
 * This file handles the transition from 32-bit protected mode (as entered by GRUB)
 * to 64-bit long mode, setting up initial page tables along the way.
 *
 * Entry conditions (Multiboot2 spec):
 *   - EAX = Multiboot2 magic (0x36D76289)
 *   - EBX = Physical address of Multiboot2 information structure
 *   - Protected mode enabled, paging disabled
 *   - A20 gate enabled
 *   - Interrupts disabled
 *
 * Memory layout after boot:
 *   - Identity mapping: 0x00000000 -> 0x00000000 (first 4GB)
 *   - Higher-half:      0xFFFFFFFF80000000 -> 0x00000000 (kernel -2GB)
 *   - HHDM:             0xFFFF800000000000 -> 0x00000000 (physical access)
 */

.set MULTIBOOT2_MAGIC,      0xE85250D6
.set MULTIBOOT2_ARCH_I386,  0
.set MULTIBOOT2_HEADER_LEN, (multiboot2_header_end - multiboot2_header_start)
.set MULTIBOOT2_CHECKSUM,   -(MULTIBOOT2_MAGIC + MULTIBOOT2_ARCH_I386 + MULTIBOOT2_HEADER_LEN)

.set MULTIBOOT2_BOOTLOADER_MAGIC, 0x36D76289

/* Page table constants */
.set PAGE_PRESENT,    (1 << 0)
.set PAGE_WRITE,      (1 << 1)
.set PAGE_SIZE,       (1 << 7)    /* 2MB pages */
.set PAGE_FLAGS,      (PAGE_PRESENT | PAGE_WRITE)
.set PAGE_FLAGS_HUGE, (PAGE_PRESENT | PAGE_WRITE | PAGE_SIZE)

/* CR0/CR4/MSR constants */
.set CR0_PE,          (1 << 0)    /* Protection Enable */
.set CR0_PG,          (1 << 31)   /* Paging Enable */
.set CR4_PAE,         (1 << 5)    /* Physical Address Extension */
.set EFER_MSR,        0xC0000080
.set EFER_LME,        (1 << 8)    /* Long Mode Enable */

/* Higher-half kernel offset */
.set KERNEL_VMA,      0xFFFFFFFF80000000
.set HHDM_VMA,        0xFFFF800000000000

/* ============================================================================
 * Multiboot2 Header - must be in first 32KB of kernel image
 * ============================================================================ */
.section .multiboot2, "a"
.align 8

multiboot2_header_start:
    .long MULTIBOOT2_MAGIC
    .long MULTIBOOT2_ARCH_I386
    .long MULTIBOOT2_HEADER_LEN
    .long MULTIBOOT2_CHECKSUM

    /* Information request tag - ask for memory map */
    .align 8
    /* Address tag - required for flat binary loading */
    .align 8
address_tag:
    .short 2                    /* type: address */
    .short 1                    /* flags: must be processed */
    .long 24                    /* size */
    .long 0x01000000            /* header_addr (16MB) */
    .long 0x01000000            /* load_addr (16MB) */
    .long 0                     /* load_end_addr (0 = entire file) */
    .long 0x01500000            /* bss_end_addr (End at 21MB) */
address_tag_end:

    /* Information request tag - ask for memory map */

    /* Framebuffer tag - optional, request text mode */
    .align 8
framebuffer_tag:
    .short 5                    /* type: framebuffer */
    .short 1                    /* flags: optional */
    .long 20                    /* size */
    .long 0                     /* width (0 = no preference) */
    .long 0                     /* height */
    .long 0                     /* depth */
framebuffer_tag_end:

    /* Entry address tag - specify our entry point */
    .align 8
entry_tag:
    .short 3                    /* type: entry address */
    .short 0                    /* flags: not optional */
    .long 12                    /* size */
    .long _start32              /* entry point */
entry_tag_end:

    /* End tag */
    .align 8
    .short 0                    /* type: end */
    .short 0                    /* flags */
    .long 8                     /* size */
multiboot2_header_end:

/* ============================================================================
 * 32-bit Bootstrap Code
 * ============================================================================ */
.section .boot32, "ax"
.code32

.global _start32
_start32:
    /* Disable interrupts */
    cli

    /* Save Multiboot2 info pointer (EBX) and magic (EAX) */
    movl %ebx, (multiboot2_info_ptr)
    movl %eax, (multiboot2_magic)

    /* Verify Multiboot2 magic */
    cmpl $MULTIBOOT2_BOOTLOADER_MAGIC, %eax
    jne .halt32

    /* Set up a small stack for 32-bit code */
    movl $boot_stack_top, %esp

    /* Clear page tables */
    call clear_page_tables

    /* Set up initial page tables:
     * PML4[0]   -> PDPT for identity mapping (0-512GB)
     * PML4[256] -> PDPT for HHDM (0xFFFF800000000000)
     * PML4[511] -> PDPT for higher-half kernel (0xFFFFFFFF80000000)
     */

    /* PML4[0] = &pml3_identity | PAGE_FLAGS */
    movl $pml3_identity, %eax
    orl $PAGE_FLAGS, %eax
    movl %eax, (pml4)

    /* PML4[256] = &pml3_hhdm | PAGE_FLAGS (for HHDM at 0xFFFF800000000000) */
    movl $pml3_hhdm, %eax
    orl $PAGE_FLAGS, %eax
    movl %eax, (pml4 + 256 * 8)

    /* PML4[511] = &pml3_kernel | PAGE_FLAGS (for kernel at 0xFFFFFFFF80000000) */
    movl $pml3_kernel, %eax
    orl $PAGE_FLAGS, %eax
    movl %eax, (pml4 + 511 * 8)

    /* Set up PDPT for identity mapping - map first 4GB using 1GB pages */
    /* pml3_identity[0] = 0GB | PAGE_FLAGS_HUGE */
    movl $(0x00000000 | PAGE_FLAGS_HUGE), (pml3_identity + 0 * 8)
    movl $0, (pml3_identity + 0 * 8 + 4)
    /* pml3_identity[1] = 1GB | PAGE_FLAGS_HUGE */
    movl $(0x40000000 | PAGE_FLAGS_HUGE), (pml3_identity + 1 * 8)
    movl $0, (pml3_identity + 1 * 8 + 4)
    /* pml3_identity[2] = 2GB | PAGE_FLAGS_HUGE */
    movl $(0x80000000 | PAGE_FLAGS_HUGE), (pml3_identity + 2 * 8)
    movl $0, (pml3_identity + 2 * 8 + 4)
    /* pml3_identity[3] = 3GB | PAGE_FLAGS_HUGE */
    movl $(0xC0000000 | PAGE_FLAGS_HUGE), (pml3_identity + 3 * 8)
    movl $0, (pml3_identity + 3 * 8 + 4)

    /* Set up PDPT for HHDM - also map first 4GB */
    movl $(0x00000000 | PAGE_FLAGS_HUGE), (pml3_hhdm + 0 * 8)
    movl $0, (pml3_hhdm + 0 * 8 + 4)
    movl $(0x40000000 | PAGE_FLAGS_HUGE), (pml3_hhdm + 1 * 8)
    movl $0, (pml3_hhdm + 1 * 8 + 4)
    movl $(0x80000000 | PAGE_FLAGS_HUGE), (pml3_hhdm + 2 * 8)
    movl $0, (pml3_hhdm + 2 * 8 + 4)
    movl $(0xC0000000 | PAGE_FLAGS_HUGE), (pml3_hhdm + 3 * 8)
    movl $0, (pml3_hhdm + 3 * 8 + 4)

    /* Set up PDPT for kernel higher-half
     * pml3_kernel[510] = &pml2_kernel | PAGE_FLAGS
     * This maps 0xFFFFFFFF80000000 (entry 510 in PML3 covers -2GB to -1GB)
     */
    movl $pml2_kernel, %eax
    orl $PAGE_FLAGS, %eax
    movl %eax, (pml3_kernel + 510 * 8)

    /* Set up PD for kernel - map first 1GB of physical memory
     * Using 2MB pages for kernel mapping
     */
    movl $0, %ecx                   /* Counter */
    movl $pml2_kernel, %edi         /* Destination */
.fill_pml2:
    movl %ecx, %eax
    shll $21, %eax                  /* Multiply by 2MB */
    orl $PAGE_FLAGS_HUGE, %eax
    movl %eax, (%edi)
    movl $0, 4(%edi)
    addl $8, %edi
    incl %ecx
    cmpl $512, %ecx
    jl .fill_pml2

    /* Load PML4 address into CR3 */
    movl $pml4, %eax
    movl %eax, %cr3

    /* Enable PAE in CR4 */
    movl %cr4, %eax
    orl $CR4_PAE, %eax
    movl %eax, %cr4

    /* Enable Long Mode in EFER MSR */
    movl $EFER_MSR, %ecx
    rdmsr
    orl $EFER_LME, %eax
    wrmsr

    /* Enable paging in CR0 - this activates long mode */
    movl %cr0, %eax
    orl $CR0_PG, %eax
    movl %eax, %cr0

    /* Load 64-bit GDT */
    lgdt (gdt64_ptr)

    /* Far jump to 64-bit code - this switches to long mode */
    ljmp $0x08, $_start64

.halt32:
    hlt
    jmp .halt32

/* Clear all page table entries to zero */
clear_page_tables:
    movl $pml4, %edi
    movl $(4096 * 5 / 4), %ecx   /* 5 page tables, 4096 bytes each, 4 bytes per iteration */
    xorl %eax, %eax
    rep stosl
    ret

/* ============================================================================
 * 64-bit Code
 * ============================================================================ */
.code64

.global _start64
_start64:
    /* Reload segment registers with 64-bit data segment */
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    /* Set up 64-bit stack in higher-half */
    movabsq $boot_stack_top, %rsp

    /* Load Multiboot2 info pointer into RDI (first argument) */
    movl (multiboot2_info_ptr), %edi

    /* Clear upper 32 bits and convert to physical address */
    movl %edi, %edi

    /* Jump to kernel entry point in higher half
     * The kernel _start function expects:
     *   RDI = Multiboot2 info physical address
     */
    movabsq $_start, %rax
    jmp *%rax

/* ============================================================================
 * Data Section - Page Tables and GDT
 * ============================================================================ */
.section .boot_data, "aw"

/* Saved Multiboot2 info */
.global multiboot2_info_ptr
multiboot2_info_ptr:
    .long 0

.global multiboot2_magic
multiboot2_magic:
    .long 0

/* 64-bit GDT */
.align 16
gdt64:
    .quad 0                         /* Null descriptor */
gdt64_code:
    .quad 0x00AF9A000000FFFF        /* 64-bit code: base=0, limit=0xFFFFF, G=1, L=1, P=1, DPL=0, S=1, E=1, R=1 */
gdt64_data:
    .quad 0x00CF92000000FFFF        /* 64-bit data: base=0, limit=0xFFFFF, G=1, B=1, P=1, DPL=0, S=1, W=1 */
gdt64_end:

gdt64_ptr:
    .word gdt64_end - gdt64 - 1     /* Limit */
    .quad gdt64                     /* Base */

/* ============================================================================
 * BSS Section - Page Tables (must be page-aligned)
 * ============================================================================ */
.section .boot_bss, "aw", @nobits
.align 4096

/* PML4 - Page Map Level 4 (512 entries, 4KB) */
pml4:
    .space 4096

/* PDPT for identity mapping (0-512GB) */
pml3_identity:
    .space 4096

/* PDPT for HHDM (0xFFFF800000000000) */
pml3_hhdm:
    .space 4096

/* PDPT for higher-half kernel (0xFFFFFFFF80000000) */
pml3_kernel:
    .space 4096

/* PD for kernel (2MB pages, covers 1GB) */
pml2_kernel:
    .space 4096

/* Bootstrap stack */
.align 16
boot_stack_bottom:
    .space 16384                    /* 16KB stack for bootstrap */
boot_stack_top:
