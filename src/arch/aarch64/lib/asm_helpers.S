// AArch64 Assembly Helpers
// These functions cannot be expressed in Zig inline assembly

.text

// =============================================================================
// Safe User Copy
// =============================================================================

// usize _asm_copy_from_user(void* dest, const void* src, usize len)
// Returns number of bytes NOT copied (0 on success)
// x0 = dest, x1 = src, x2 = len
.global _asm_copy_from_user
.type _asm_copy_from_user, @function
_asm_copy_from_user:
    // Save original length for return calculation
    mov x3, x2

    // Check for zero length
    cbz x2, .Lcopy_done

    // Simple byte-by-byte copy (can be optimized later with ldp/stp)
.global _asm_copy_user_start
_asm_copy_user_start:
.Lcopy_loop:
    ldrb w4, [x1], #1       // Load byte from src, post-increment
    strb w4, [x0], #1       // Store byte to dest, post-increment
    subs x2, x2, #1         // Decrement counter
    b.ne .Lcopy_loop
.global _asm_copy_user_end
_asm_copy_user_end:

    // Success: return 0
    mov x0, #0
    ret

.Lcopy_done:
    mov x0, #0
    ret

// Fixup handler for page faults during copy
// Returns remaining bytes that weren't copied (x2 at time of fault)
.global _asm_copy_user_fixup
_asm_copy_user_fixup:
    // x2 contains remaining count at time of fault
    mov x0, x2
    ret

// usize _asm_copy_to_user(void* dest, const void* src, usize len)
// Same implementation - faults on either src or dest
.global _asm_copy_to_user
.type _asm_copy_to_user, @function
_asm_copy_to_user:
    b _asm_copy_from_user
