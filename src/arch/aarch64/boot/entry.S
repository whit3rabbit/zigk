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

    /* Current EL with SPx (kernel mode exceptions) */
    .balign 128
    b handle_sync_exception_kernel
    .balign 128
    b handle_irq_kernel
    .balign 128
    b unhandled_fiq
    .balign 128
    b unhandled_serror

    /* Lower EL using AArch64 (user mode exceptions) */
    .balign 128
    b handle_sync_exception_user
    .balign 128
    b handle_irq_user
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
    ldp x0, x1, [sp, #248]      // x0 = ELR, x1 = SPSR

    // Check if returning to EL0 (SPSR.M[3:0] == 0)
    // If returning to EL1 (kernel), skip validation
    and x2, x1, #0xF            // Extract EL bits
    cbnz x2, .Lrestore_no_validate_\@

    // Returning to EL0: validate ELR is in user address space.
    tbnz x0, #63, .Lbad_elr_\@  // If bit 63 set, ELR is in kernel space
    b .Lrestore_validated_\@

.Lbad_elr_\@:
    // SECURITY VIOLATION: Attempt to eret to kernel address from EL0 context
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

// Debug: Output a character to PL011 UART (0x09000000)
// Clobbers x10, x11
.macro DEBUG_CHAR char
    mov x10, #0x09000000        // PL011 base address
    mov x11, #\char
    strb w11, [x10]             // Write character to UART DR
.endm

handle_sync_exception_kernel:
    SAVE_CONTEXT
    dsb ish
    mov x0, sp
    mrs x1, esr_el1
    mrs x2, far_el1
    bl handle_exception_zig
    dsb ish
    RESTORE_CONTEXT

handle_sync_exception_user:
    SAVE_CONTEXT
    dsb ish
    mov x0, sp
    mrs x1, esr_el1
    mrs x2, far_el1
    bl handle_exception_zig
    dsb ish
    RESTORE_CONTEXT

handle_irq_kernel:
    SAVE_CONTEXT
    dsb ish
    mov x0, sp
    bl handle_irq_zig
    dsb ish
    cbz x0, 1f
    mov sp, x0
1:
    RESTORE_CONTEXT

handle_irq_user:
    SAVE_CONTEXT
    dsb ish
    mov x0, sp
    bl handle_irq_zig
    dsb ish
    cbz x0, 1f
    mov sp, x0
1:
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
