// AArch64 Assembly Helpers
// These functions cannot be expressed in Zig inline assembly
//
// With PAN (Privileged Access Never) enabled, we must use LDTR/STTR
// instructions to access user memory from kernel mode. These instructions
// perform the access as if from EL0, allowing access to user pages while
// PAN is active.
//
// SECURITY NOTE: Copy functions do NOT validate buffer sizes.
// Callers (via the UserPtr abstraction in Zig) MUST:
//   1. Validate that 'len' does not exceed destination buffer capacity
//   2. Validate that user addresses are in valid user address space
//   3. Validate that kernel addresses are valid kernel memory
// The fixup handlers return the remaining byte count on page faults,
// but do NOT prevent kernel stack buffer overflows if 'len' is wrong.

.text

// =============================================================================
// Safe User Copy (PAN-compatible)
// =============================================================================

// usize _asm_copy_from_user(void* dest, const void* src, usize len)
// Copies from user space (src) to kernel space (dest)
// Returns number of bytes NOT copied (0 on success)
// x0 = dest (kernel), x1 = src (user), x2 = len
.global _asm_copy_from_user
.type _asm_copy_from_user, @function
_asm_copy_from_user:
    // Save original length for return calculation
    mov x3, x2

    // Check for zero length
    cbz x2, .Lcopy_from_done

    // Use LDTRB for user access (PAN-compatible unprivileged load)
.global _asm_copy_from_user_start
_asm_copy_from_user_start:
.Lcopy_from_loop:
    ldtrb w4, [x1]          // Unprivileged load from user space
    strb w4, [x0], #1       // Normal store to kernel space, post-increment
    add x1, x1, #1          // Manual post-increment for LDTR (no auto-inc mode)
    subs x2, x2, #1         // Decrement counter
    b.ne .Lcopy_from_loop
.global _asm_copy_from_user_end
_asm_copy_from_user_end:

    // Success: return 0
    mov x0, #0
    ret

.Lcopy_from_done:
    mov x0, #0
    ret

// Fixup handler for page faults during copy_from_user
.global _asm_copy_from_user_fixup
_asm_copy_from_user_fixup:
    mov x0, x2
    ret

// usize _asm_copy_to_user(void* dest, const void* src, usize len)
// Copies from kernel space (src) to user space (dest)
// Returns number of bytes NOT copied (0 on success)
// x0 = dest (user), x1 = src (kernel), x2 = len
.global _asm_copy_to_user
.type _asm_copy_to_user, @function
_asm_copy_to_user:
    // Save original length for return calculation
    mov x3, x2

    // Check for zero length
    cbz x2, .Lcopy_to_done

    // Use STTRB for user access (PAN-compatible unprivileged store)
.global _asm_copy_to_user_start
_asm_copy_to_user_start:
.Lcopy_to_loop:
    ldrb w4, [x1], #1       // Normal load from kernel space, post-increment
    sttrb w4, [x0]          // Unprivileged store to user space
    add x0, x0, #1          // Manual post-increment for STTR (no auto-inc mode)
    subs x2, x2, #1         // Decrement counter
    b.ne .Lcopy_to_loop
.global _asm_copy_to_user_end
_asm_copy_to_user_end:

    // Success: return 0
    mov x0, #0
    ret

.Lcopy_to_done:
    mov x0, #0
    ret

// Fixup handler for page faults during copy_to_user
.global _asm_copy_to_user_fixup
_asm_copy_to_user_fixup:
    mov x0, x2
    ret

// Legacy symbols for backward compatibility with fixup table
.global _asm_copy_user_start
_asm_copy_user_start = _asm_copy_from_user_start
.global _asm_copy_user_end
_asm_copy_user_end = _asm_copy_to_user_end
.global _asm_copy_user_fixup
_asm_copy_user_fixup = _asm_copy_from_user_fixup

// =============================================================================
// VMware Hypercall (ARM64)
// =============================================================================
//
// VMware on ARM64 uses a different mechanism than x86:
// - x86 uses I/O port 0x5658 with "in eax, dx" instruction
// - ARM64 uses system register trap via "mrs xzr, mdccsr_el0"
//
// The hypervisor traps access to MDCCSR_EL0 (Monitor Debug Configuration
// Status Register) and interprets pre-loaded registers x0-x7 as hypercall
// parameters.
//
// Register convention:
//   x0 = eax equivalent (magic value 0x564D5868 / return value)
//   x1 = ebx equivalent (command or data)
//   x2 = ecx equivalent (command ID)
//   x3 = edx equivalent (flags + port identifier)
//   x4 = esi equivalent (input parameter)
//   x5 = edi equivalent (input parameter)
//   x6 = bp equivalent (base pointer for high-bandwidth)
//   x7 = control word: (0x86 << 32) | flags
//
// Reference: Linux kernel vmwgfx ARM64 patches (drm/vmwgfx)

// void _asm_vmware_hypercall(HypercallRegs* regs)
// HypercallRegs is a struct of 8 consecutive u64 values (x0-x7)
// x0 = pointer to HypercallRegs struct
.global _asm_vmware_hypercall
.type _asm_vmware_hypercall, @function
_asm_vmware_hypercall:
    // Save callee-saved registers we'll use
    stp x19, x20, [sp, #-16]!
    mov x19, x0                  // Save struct pointer in x19

    // Load hypercall parameters from struct
    // Struct layout: [x0, x1, x2, x3, x4, x5, x6, x7] as 8 consecutive u64
    ldp x0, x1, [x19, #0]        // x0 (eax), x1 (ebx)
    ldp x2, x3, [x19, #16]       // x2 (ecx), x3 (edx)
    ldp x4, x5, [x19, #32]       // x4 (esi), x5 (edi)
    ldp x6, x7, [x19, #48]       // x6 (bp), x7 (control)

    // Execute VMware hypercall trap
    // The hypervisor intercepts this system register read
    mrs xzr, mdccsr_el0

    // Store results back to struct
    stp x0, x1, [x19, #0]
    stp x2, x3, [x19, #16]
    stp x4, x5, [x19, #32]
    stp x6, x7, [x19, #48]

    // Restore and return
    ldp x19, x20, [sp], #16
    ret
.size _asm_vmware_hypercall, . - _asm_vmware_hypercall
