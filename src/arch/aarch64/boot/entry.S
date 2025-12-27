/* AArch64 Kernel Entry Point and Exception Vectors */

.section .text

.global kentry
kentry:
    /* x0 contains the BootInfo pointer from Limine */
    /* Verify 16-byte stack alignment (AArch64 ABI requirement) */
    /* Note: SP cannot be used directly with TST, must copy to a GPR first */
    mov x9, sp
    tst x9, #0xF
    b.ne .Lstack_error
    /* Set up a stack if needed, but Limine provides one */
    b _start

.Lstack_error:
    /* Stack misaligned - halt with interrupts disabled */
    msr daifset, #0xf
1:  wfe
    b 1b

.balign 2048
.global exception_vector_table
exception_vector_table:
    /* Current EL with SP0 (should never happen - we use SPx) */
    .balign 128
    b unhandled_sp0_sync
    .balign 128
    b unhandled_sp0_irq
    .balign 128
    b unhandled_sp0_fiq
    .balign 128
    b unhandled_sp0_serror

    /* Current EL with SPx */
    .balign 128
    b handle_sync_exception
    .balign 128
    b handle_irq
    .balign 128
    b unhandled_fiq
    .balign 128
    b unhandled_serror

    /* Lower EL using AArch64 */
    .balign 128
    b handle_sync_exception
    .balign 128
    b handle_irq
    .balign 128
    b unhandled_fiq
    .balign 128
    b unhandled_serror

    /* Lower EL using AArch32 (not supported) */
    .balign 128
    b unhandled_aarch32
    .balign 128
    b unhandled_aarch32
    .balign 128
    b unhandled_aarch32
    .balign 128
    b unhandled_aarch32

// SECURITY NOTE: Nested Exception Stack Usage
// Each exception allocates 288 bytes on the kernel stack for SyscallFrame.
// If an exception occurs while handling another exception (e.g., page fault
// during interrupt handling), the nested exception will allocate another frame.
//
// Mitigations for stack exhaustion:
//   1. Exception handlers are designed to avoid triggering nested faults
//   2. Kernel stack is sized to accommodate reasonable nesting depth
//   3. Page fault handler avoids complex operations that could fault again
//
// Future improvements could include:
//   - Per-CPU exception stacks (separate from thread kernel stacks)
//   - Nesting depth counter with panic on excessive depth
//   - Double-fault detection via separate minimal stack
.macro SAVE_CONTEXT
    sub sp, sp, #288 // Size of SyscallFrame struct (36 fields * 8)
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]

    mrs x0, elr_el1
    mrs x1, spsr_el1
    stp x0, x1, [sp, #248]

    // Save SP_EL0 (user stack pointer) for syscall handling
    mrs x0, sp_el0
    str x0, [sp, #264]
.endm

.macro RESTORE_CONTEXT
    // Restore SP_EL0 (may have been modified by syscall)
    ldr x0, [sp, #264]
    msr sp_el0, x0

    // SECURITY: Validate ELR and SPSR before eret (defense-in-depth).
    // If kernel memory is corrupted, an attacker could:
    //   1. Set SPSR.EL to 1 to return to EL1 (kernel mode)
    //   2. Set ELR to a kernel address for ROP/code execution
    // We validate these values when returning to EL0 (userspace).
    ldp x0, x1, [sp, #248]      // x0 = ELR, x1 = SPSR

    // Check if returning to EL0 (SPSR.M[3:0] == 0)
    // If returning to EL1 (kernel), skip validation
    and x2, x1, #0xF            // Extract EL bits
    cbnz x2, .Lrestore_no_validate_\@

    // Returning to EL0: validate SPSR.EL is exactly 0 (not just low 4 bits)
    // and ELR is in user address space.
    //
    // SECURITY: Check bit 63 (sign bit) rather than bit 55 for robustness.
    // This works regardless of VA size configuration (48-bit or 52-bit LPA2):
    //   - User addresses (canonical lower half): bits 63:VA_SIZE-1 all 0, so bit 63 = 0
    //   - Kernel addresses (canonical upper half): bits 63:VA_SIZE-1 all 1, so bit 63 = 1
    // Bit 63 check is universal and future-proof for any VA size.
    tbnz x0, #63, .Lbad_elr_\@  // If bit 63 set, ELR is in kernel space

    // Validation passed, proceed with restore
    b .Lrestore_validated_\@

.Lbad_elr_\@:
    // SECURITY VIOLATION: Attempt to eret to kernel address from EL0 context
    // This indicates kernel memory corruption or exploitation attempt.
    // Halt immediately - do NOT proceed with eret.
    msr daifset, #0xf           // Disable all interrupts
    mov x0, #0xBAD0             // Panic code: bad ELR
    movk x0, #0xE12, lsl #16    // 0xE120BAD0
1:  wfi
    b 1b

.Lrestore_no_validate_\@:
.Lrestore_validated_\@:
    msr elr_el1, x0
    msr spsr_el1, x1

    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    add sp, sp, #288
    eret
.endm

handle_sync_exception:
    SAVE_CONTEXT
    dsb ish                 // Ensure context fully saved before reading system regs
    mov x0, sp              // Pass frame pointer as first argument
    mrs x1, esr_el1         // Exception syndrome as second argument
    mrs x2, far_el1         // Fault address as third argument
    bl handle_exception_zig
    dsb ish                 // Ensure handler writes visible before restore
    RESTORE_CONTEXT

handle_irq:
    SAVE_CONTEXT
    dsb ish                 // Ensure context fully saved
    mov x0, sp              // Pass frame pointer as first argument
    bl handle_irq_zig
    dsb ish                 // Ensure handler writes visible before restore
    RESTORE_CONTEXT

// Unhandled exception handlers - these call Zig with exception type code
// x0 = exception type (for Zig handler)
// x1 = ESR_EL1, x2 = ELR_EL1, x3 = FAR_EL1

unhandled_sp0_sync:
    mov x0, #0              // Type: SP0 Sync
    b unhandled_common

unhandled_sp0_irq:
    mov x0, #1              // Type: SP0 IRQ
    b unhandled_common

unhandled_sp0_fiq:
    mov x0, #2              // Type: SP0 FIQ
    b unhandled_common

unhandled_sp0_serror:
    mov x0, #3              // Type: SP0 SError
    b unhandled_common

unhandled_fiq:
    mov x0, #4              // Type: FIQ
    b unhandled_common

unhandled_serror:
    mov x0, #5              // Type: SError
    b unhandled_common

unhandled_aarch32:
    mov x0, #6              // Type: AArch32 (unsupported)
    b unhandled_common

unhandled_common:
    // Save minimal context and read system registers
    mrs x1, esr_el1         // Exception syndrome
    mrs x2, elr_el1         // Return address
    mrs x3, far_el1         // Fault address
    bl unhandled_exception_zig
    // Should not return, but if it does, halt
    msr daifset, #0xf       // Disable all interrupts
1:  wfi
    b 1b
