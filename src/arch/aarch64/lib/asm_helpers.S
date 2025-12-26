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
