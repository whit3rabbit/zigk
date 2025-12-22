/*
 * SMP Trampoline Code
 *
 * This code is loaded into low memory (under 1MB) to bootstrap Application Processors (APs).
 * APs start in Real Mode (16-bit) and need to be switched to Long Mode (64-bit).
 *
 * It is position-independent relative to its load address (CS:0).
 */

.code16
.section .text
.global smp_trampoline_start
.global smp_trampoline_end
.global smp_trampoline_pm_jump_operand
.global smp_trampoline_lm_jump_operand

smp_trampoline_start:
    cli

    // Set up data segments
    // CS is set to (trampoline_phys >> 4) by SIPI
    // We set DS = CS to access data easily if needed, but we rely on patched immediates mostly.
    mov %cs, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs

    // Load GDT
    // We need to patch the GDTR limit and base address here
    // Use CS override to ensure we read from trampoline
    lgdtl %cs:(smp_trampoline_gdt_ptr - smp_trampoline_start)

    // Enable Protected Mode
    mov %cr0, %eax
    or $1, %al
    mov %eax, %cr0

    // Jump to 32-bit protected mode
    // We use a manually encoded far jump so we can patch the target address
    // 0x66 prefix for 32-bit operand size in 16-bit mode
    .byte 0x66, 0xEA
smp_trampoline_pm_jump_operand:
    .long 0      // Target offset (Patched by kernel)
    .word 0x18   // Target segment (32-bit Code)

.code32
.global trampoline_protected_mode
trampoline_protected_mode:
    // Set up data segments for 32-bit mode
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs

    // Enable PAE (Physical Address Extension) - required for Long Mode
    mov %cr4, %eax
    or $(1 << 5), %eax
    mov %eax, %cr4

    // Load CR3 (Page Table Pointer)
    // Patched by the kernel before booting AP
    // Since we are flat 32-bit, we need absolute address of variable
    // But code is PIC-ish.
    // Wait, if we use `mov (trampoline_cr3 - smp_trampoline_start), %eax` it uses absolute address 0 based.
    // Because we didn't use `org`.
    // We need to know `trampoline_phys`.
    //
    // Solution: We can use a relative call to get EIP, but that's messy.
    // Better: Patch the instruction that loads CR3 too?
    // Or simpler: We patched the jump to get here.
    // We can just patch the absolute address of `trampoline_cr3` into the instruction?
    // No, `mov symbol, %eax` emits `A1 addr`.
    // We can export `trampoline_cr3_ref` label?
    //
    // Alternative: We patched GDT base.
    // We can assume we can access data relative to an anchor if we have one.
    //
    // Actually, simpler:
    // We can patch the variables `trampoline_cr3` etc. with values.
    // And we can use `mov $ADDR, %ebx; mov (%ebx), %eax`.
    // Where $ADDR is patched.
    //
    // Or just patch the MOV instruction to load IMMEDIATE value of CR3?
    // `mov $CR3_VAL, %eax` -> `mov %cr3, %eax`.
    // CR3 value is constant for all APs (sharing kernel page table).
    // Yes! We can patch CR3 value directly into instruction.

    // Instruction: mov $IMM, %eax (B8 imm32)
    .byte 0xB8
smp_trampoline_cr3_imm:
    .long 0 // Patched with CR3 value
    mov %eax, %cr3

    // Enable Long Mode in EFER MSR
    mov $0xC0000080, %ecx
    rdmsr
    or $(1 << 8), %eax
    or $(1 << 11), %eax  // Enable NXE (No-Execute)
    wrmsr

    // Enable Paging (and Long Mode activation)
    mov %cr0, %eax
    or $(1 << 31), %eax
    mov %eax, %cr0

    // Jump to 64-bit long mode
    // Manually encoded far jump
    .byte 0xEA
smp_trampoline_lm_jump_operand:
    .long 0      // Target offset (Patched by kernel)
    .word 0x08   // Target segment (64-bit Code)

.code64
.global trampoline_long_mode
trampoline_long_mode:
    // We are now in 64-bit mode!

    // Reload data segments with 0 (NULL descriptor) or kernel data
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs

    // Load stack pointer
    // We need per-CPU stack.
    // We patched `trampoline_stack_top` variable in memory?
    // Again, accessing memory is hard without knowing absolute address.
    // But we can patch the instruction `mov $STACK, %rsp`.
    // 64-bit immediate load to RSP?
    // `movq $IMM, %rsp`. Opcode: 48 C7 C4 imm32 (sign extended) or 48 B8 imm64...
    // `movabs $imm64, %rsp` -> 48 BC imm64.

    .byte 0x48, 0xBC
smp_trampoline_rsp_imm:
    .quad 0 // Patched with Stack Top

    // Load AP GDT address into R15 (callee-saved, will be available in apEntry)
    // `movabs $imm64, %r15` -> 49 BF imm64
    .byte 0x49, 0xBF
smp_trampoline_ap_gdt_imm:
    .quad 0 // Patched with AP GDT virtual address

    // Jump to High-Half Kernel Entry Point
    // `movabs $imm64, %rax`; `jmp *%rax`
    .byte 0x48, 0xB8
smp_trampoline_entry_imm:
    .quad 0 // Patched with Entry Point
    jmp *%rax

.align 4
smp_trampoline_gdt_ptr:
    .word 0 // Limit (patched)
    .long 0 // Base (patched)

// Temporary GDT for the transition
.align 4
.global smp_trampoline_gdt
.global smp_trampoline_gdt_end

smp_trampoline_gdt:
    // 0x00: Null descriptor
    .quad 0

    // 0x08: 64-bit Code (L=1, D=0)
    .word 0xFFFF, 0x0000
    .byte 0x00, 0x9A, 0xAF, 0x00

    // 0x10: Data
    .word 0xFFFF, 0x0000
    .byte 0x00, 0x92, 0xCF, 0x00

    // 0x18: 32-bit Code (D=1)
    .word 0xFFFF, 0x0000
    .byte 0x00, 0x9A, 0xCF, 0x00

smp_trampoline_gdt_end:

// Exports for Zig to find patch locations
.global smp_trampoline_cr3_imm
.global smp_trampoline_rsp_imm
.global smp_trampoline_entry_imm
.global smp_trampoline_ap_gdt_imm
// gdt_ptr is still needed for lgdtl
.global smp_trampoline_gdt_ptr

smp_trampoline_end:
