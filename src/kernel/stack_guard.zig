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
// NOTE: prng import removed - stack_guard now uses ChaCha20 CSPRNG directly
// via hal.entropy for better security (CSPRNG is not reversible like xoroshiro128+)

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
        // SECURITY FIX: Use ChaCha20 CSPRNG instead of weak xoroshiro128+ PRNG
        // The CSPRNG provides 256-bit security even when seeded from weak sources,
        // making it far harder for attackers to predict canary values.
        // xoroshiro128+ has only 128 bits of state and is reversible from 2 outputs.
        random_value = hal.entropy.getCsprngU64AllowWeak();
        console.warn("Stack guard: RDRAND unavailable - using ChaCha20 CSPRNG", .{});

        // Check if even the CSPRNG is using weak seeding
        if (!hal.entropy.isCsprngSeeded()) {
            console.err("Stack guard: CRITICAL - CSPRNG using weak fallback seed!", .{});
            console.err("  Stack canaries may be predictable to sophisticated attackers.", .{});
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
        // Re-seed the CSPRNG with fresh hardware entropy
        hal.entropy.reseedCsprng();

        // SECURITY FIX: Use CSPRNG instead of weak PRNG
        // Try hardware first, fall back to CSPRNG
        var entropy_buf: [8]u8 = undefined;
        var random_value: u64 = undefined;

        if (hal.entropy.tryFillWithHardwareEntropy(&entropy_buf)) {
            random_value = @bitCast(entropy_buf);
        } else if (hal.entropy.getCsprngU64()) |csprng_val| {
            random_value = csprng_val;
        } else {
            // Should not happen since quality == .high means hardware is available
            return;
        }

        random_value &= ~@as(u64, 0xFF); // Maintain null-byte constraint
        __stack_chk_guard = random_value;

        console.info("Stack guard: Canary re-seeded with high-quality entropy", .{});
    } else if (quality == .medium) {
        // SECURITY FIX: Use CSPRNG even for medium quality
        // CSPRNG provides better mixing than xoroshiro128+
        hal.entropy.reseedCsprng();

        var random_value = hal.entropy.getCsprngU64AllowWeak();
        random_value &= ~@as(u64, 0xFF);

        __stack_chk_guard = random_value;

        console.info("Stack guard: Canary re-seeded with CSPRNG (entropy: medium)", .{});
    }
    // If quality is still low, don't re-seed - we'd just add predictable data
}
