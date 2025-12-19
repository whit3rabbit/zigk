//! Stack Guard Canary Support
//!
//! Provides the `__stack_chk_guard` symbol and `__stack_chk_fail` handler
//! for compiler-based stack smashing detection.
//!
//! Stack canary protection works by:
//! 1. Compiler inserts a canary value at function entry (below return address).
//! 2. At function exit, the compiler checks if the canary was corrupted.
//! 3. If corrupted, `__stack_chk_fail` is called, catching buffer overflows.

const hal = @import("hal");
const console = @import("console");
const prng = @import("prng");

/// Stack canary value
/// Randomized at boot via PRNG seeded from RDRAND/RDTSC hardware entropy.
/// Initial value is a compile-time placeholder, replaced by init() before
/// scheduler starts.
///
/// Security: The low byte is forced to 0x00 to catch string overflows (strcpy/strcat
/// will stop at the null byte).
pub export var __stack_chk_guard: usize = 0x00000aff_0a0d_ff00;

/// Called by compiler-inserted code when stack canary mismatch is detected.
/// This indicates a stack buffer overflow - a critical security violation.
/// We immediately halt the system with diagnostic information.
pub export fn __stack_chk_fail() noreturn {
    // Disable interrupts to prevent further corruption
    hal.cpu.disableInterrupts();

    // Print diagnostic
    console.printUnsafe("\n");
    console.printUnsafe("!!! STACK SMASHING DETECTED !!!\n");
    console.printUnsafe("\n");
    console.printUnsafe("A stack buffer overflow has corrupted the stack canary.\n");
    console.printUnsafe("This is a critical security violation.\n");
    console.printUnsafe("\n");
    console.printUnsafe("The system will now halt to prevent potential exploitation.\n");
    console.printUnsafe("\n");

    // In a real kernel, we would:
    // 1. Log the faulting thread/process
    // 2. Dump register state
    // 3. Kill the offending process (if userland)
    // 4. Continue running (if kernel survived)
    // For now, halt the entire system
    hal.cpu.haltForever();
}

/// Initialize stack guard with a randomized canary value.
/// Called during early kernel initialization.
///
/// Security: Uses hardware entropy (RDRAND) directly for canary generation.
/// This bypasses the software PRNG to ensure stack canaries cannot be predicted
/// even if an attacker recovers the PRNG state.
pub fn init() void {
    // SECURITY FIX: Use hardware entropy directly instead of software PRNG
    // The PRNG (xoroshiro128+) has only 128 bits of state and is reversible,
    // making canaries predictable if PRNG output is observed.
    var entropy_buf: [8]u8 = undefined;
    const got_hardware_entropy = hal.entropy.tryFillWithHardwareEntropy(&entropy_buf);

    var random_value: u64 = undefined;
    if (got_hardware_entropy) {
        random_value = @bitCast(entropy_buf);
        console.info("Stack guard: Canary seeded from hardware entropy (RDRAND)", .{});
    } else {
        // Fallback: use PRNG if hardware entropy unavailable
        // This is weaker but still better than a static value
        random_value = prng.next();
        console.warn("Stack guard: RDRAND unavailable - using PRNG (weaker security)", .{});

        if (prng.isUsingFallbackSeed()) {
            console.err("Stack guard: CRITICAL - using predictable fallback seed!", .{});
        }
    }

    // Apply canary constraint for string overflow detection:
    // Low byte = 0x00 catches null-terminated string overflows
    // Security: This reduces entropy by 8 bits but catches common string bugs
    random_value &= ~@as(u64, 0xFF); // Clear low byte only (becomes 0x00)

    __stack_chk_guard = random_value;
}

/// Re-seed the stack canary with fresh entropy.
/// Security: Call this after more entropy is available to mitigate
/// boot-time entropy starvation. The canary is replaced atomically.
///
/// IMPORTANT: This should be called BEFORE any threads are created,
/// or the old canary must be propagated to existing stack frames.
/// In practice, call this after APIC/timer initialization but before
/// the scheduler starts.
pub fn reseed() void {
    // Check if we can get better entropy now
    const quality = hal.entropy.getEstimatedQuality();

    if (quality == .high) {
        // Re-seed PRNG first to incorporate new entropy
        hal.entropy.reseedCsprng();
        prng.mixEntropy(hal.entropy.getHardwareEntropy());

        // Generate new canary
        var random_value = prng.next();
        random_value &= ~@as(u64, 0xFF); // Maintain null-byte constraint

        __stack_chk_guard = random_value;

        console.info("Stack guard: Canary re-seeded with high-quality entropy", .{});
    } else if (quality == .medium and prng.isUsingFallbackSeed()) {
        // Some improvement is better than none
        prng.mixEntropy(hal.entropy.getHardwareEntropy());

        var random_value = prng.next();
        random_value &= ~@as(u64, 0xFF);

        __stack_chk_guard = random_value;

        console.info("Stack guard: Canary re-seeded (entropy: medium)", .{});
    }
    // If quality is still low, don't re-seed - we'd just add predictable data
}
