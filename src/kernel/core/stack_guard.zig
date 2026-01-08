//! Stack Guard Canary Support
//!
//! Provides the `__stack_chk_guard` symbol and `__stack_chk_fail` handler
//! for compiler-based stack smashing detection.

const hal = @import("hal");
const console = @import("console");
const random = @import("random");

/// Stack canary value
pub export var __stack_chk_guard: usize = 0x00000aff_0a0d_ff00;

/// Called by compiler-inserted code when stack canary mismatch is detected.
pub export fn __stack_chk_fail() noreturn {
    hal.cpu.disableInterrupts();
    console.printUnsafe("\n!!! STACK SMASHING DETECTED !!!\n");
    hal.cpu.haltForever();
}

/// Initialize stack guard with a randomized canary value.
pub fn init() void {
    var random_value: u64 = undefined;

    // Try hardware directly first
    var entropy_buf: [8]u8 = undefined;
    if (hal.entropy.tryFillWithHardwareEntropy(&entropy_buf)) {
        random_value = @bitCast(entropy_buf);
        console.info("Stack guard: Canary seeded from hardware", .{});
    } else {
        // Use the new generic CSPRNG
        random_value = random.getU64();
        console.warn("Stack guard: Hardware RNG unavailable - using CSPRNG", .{});
    }

    // SECURITY NOTE (Vuln 5 - FALSE POSITIVE): Null-byte constraint is INTENTIONAL.
    //
    // This is standard security practice used by Linux, glibc, musl, and other systems.
    // The low byte is zeroed to prevent string operations (strlen, strcpy, strcmp)
    // from inadvertently reading past a buffer and leaking the canary value.
    //
    // Without this: A buffer overflow that stops at a null byte would not overwrite
    // the canary, but a subsequent strlen() on the corrupted buffer could leak the
    // canary through a side channel (timing, memory disclosure).
    //
    // Entropy impact: Reduces from 64 to 56 bits (256x reduction in brute-force space).
    // This is acceptable because:
    //   1. 56 bits = 72 quadrillion possible values - still computationally infeasible
    //   2. Canary changes on each boot - no cross-boot correlation
    //   3. Most exploits require exact match in ONE attempt (no partial matching)
    //   4. Linux kernel uses the same constraint (see include/linux/random.h)
    //
    // Reference: "Smashing the Stack for Fun and Profit" - Aleph One (Phrack #49)
    random_value &= ~@as(u64, 0xFF);
    __stack_chk_guard = @truncate(random_value);
}

/// Re-seed the stack canary with fresh entropy.
pub fn reseed() void {
    // Just use full entropy if available now
    var random_value = random.getU64();
    random_value &= ~@as(u64, 0xFF);
    __stack_chk_guard = @truncate(random_value);
    console.info("Stack guard: Canary re-seeded", .{});
}
