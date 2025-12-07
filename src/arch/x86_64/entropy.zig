// HAL Entropy Source Module
//
// Provides hardware entropy sources for kernel randomization needs.
// Per Constitution Principle VI (Strict Layering): Only src/arch/ may
// contain inline assembly or direct hardware access.
//
// Entropy sources:
// - RDRAND: Intel/AMD hardware random number generator (preferred)
// - RDTSC: Time Stamp Counter (fallback, lower quality)
//
// Security Note: RDRAND provides cryptographic-quality randomness from
// an on-chip DRBG. RDTSC is NOT cryptographically secure but provides
// sufficient entropy for stack canary seeding when RDRAND unavailable.
//
// Note: RDRAND and RDTSC are implemented in asm_helpers.S because Zig's
// inline assembler doesn't have encodings for these instructions.

const cpu = @import("cpu.zig");

// External assembly helpers (from asm_helpers.S)
extern fn _asm_rdrand64(success: *u8) u64;
extern fn _asm_rdtsc() u64;

// CPUID feature bit for RDRAND support (leaf 1, ECX bit 30)
const CPUID_FEAT_ECX_RDRAND: u32 = 1 << 30;

// Module state
var rdrand_available: bool = false;
var initialized: bool = false;

/// Initialize the entropy subsystem
/// Checks CPU feature flags to determine available entropy sources
/// Must be called before any entropy functions are used
pub fn init() void {
    // Check RDRAND availability via CPUID
    const result = cpu.cpuid(1, 0);
    rdrand_available = (result.ecx & CPUID_FEAT_ECX_RDRAND) != 0;
    initialized = true;
}

/// Check if RDRAND instruction is available
pub fn hasRdrand() bool {
    return rdrand_available;
}

/// Try to get 64-bit random value from RDRAND instruction
/// Returns null if RDRAND fails (rare, indicates hardware transient error)
/// Intel recommends retrying up to 10 times on failure before giving up
pub fn rdrand64() ?u64 {
    if (!rdrand_available) return null;

    var success: u8 = 0;
    const value = _asm_rdrand64(&success);

    return if (success != 0) value else null;
}

/// Read Time Stamp Counter (TSC)
/// Returns 64-bit monotonic cycle counter
/// Provides weak entropy based on timing unpredictability
/// Always available on x86_64 (instruction exists since Pentium)
pub fn rdtsc() u64 {
    return _asm_rdtsc();
}

/// Get hardware entropy from best available source
/// Attempts RDRAND first (up to 10 retries), falls back to RDTSC
/// Returns 64 bits of entropy suitable for PRNG seeding
pub fn getHardwareEntropy() u64 {
    if (rdrand_available) {
        // Intel recommends up to 10 retry attempts for RDRAND
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            if (rdrand64()) |value| {
                return value;
            }
        }
        // RDRAND failed 10 times - very unusual, hardware may be faulty
        // Fall through to RDTSC
    }

    // Fallback: use RDTSC
    // Mix multiple samples to increase entropy
    const tsc1 = rdtsc();
    const tsc2 = rdtsc();
    // XOR samples together - timing difference adds entropy
    return tsc1 ^ (tsc2 << 7) ^ (tsc2 >> 5);
}

/// Check if entropy subsystem has been initialized
pub fn isInitialized() bool {
    return initialized;
}
