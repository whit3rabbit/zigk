// Kernel PRNG (Pseudo-Random Number Generator)
//
// Implements xoroshiro128+ algorithm for kernel-wide random number generation.
// Used for stack canary seeding, ASLR (future), and sys_getrandom syscall.
//
// Security Note: xoroshiro128+ is NOT cryptographically secure. It is suitable
// for stack canaries and general randomization but should NOT be used for
// cryptographic key generation. For crypto needs, use RDRAND directly.
//
// Thread Safety: All public functions are protected by spinlock.
//
// Spec Reference: Spec 007 FR-RAND-06 through FR-RAND-08

const hal = @import("hal");
const sync = @import("sync");

// PRNG state (128 bits for xoroshiro128+)
var state: [2]u64 = .{ 0, 0 };

// Spinlock for thread-safe access
var prng_lock: sync.Spinlock = .{};

// Initialization flag
var initialized: bool = false;

// SECURITY: Flag indicating predictable fallback seed was used
// Callers should check isUsingFallbackSeed() and log a warning
var using_fallback_seed: bool = false;

/// Initialize the PRNG with hardware entropy
/// MUST be called before scheduler starts to ensure stack canary
/// is randomized before any threads are created (FR-RAND-08)
pub fn init() void {
    const held = prng_lock.acquire();
    defer held.release();

    // Ensure entropy subsystem is initialized (needed for RDRAND detection)
    if (!hal.entropy.isInitialized()) {
        hal.entropy.init();
    }

    // Seed both state words with different hardware entropy values
    // Security: Use getHardwareEntropyWithQuality() to get entropy quality info
    const entropy1 = hal.entropy.getHardwareEntropyWithQuality();
    const entropy2 = hal.entropy.getHardwareEntropyWithQuality();
    state[0] = entropy1.value;
    state[1] = entropy2.value;

    // Security: Track if we're using weak entropy
    // xoroshiro128+ is already not cryptographically secure, but weak seeds
    // make it trivially predictable
    if (entropy1.quality == .low or entropy2.quality == .low) {
        using_fallback_seed = true;
    }

    // Security fix: Check EACH state word independently, not just both
    // xoroshiro128+ degenerates with ANY zero state word (short period,
    // predictable output). Previously only checked if BOTH were zero.
    // Fallback values are chosen from splitmix64 output - still predictable
    // but at least ensures the PRNG doesn't degenerate.
    const fallback_0: u64 = 0x853c49e6748fea9b;
    const fallback_1: u64 = 0xda3e39cb94b95bdb;

    if (state[0] == 0) {
        // Security: Zero state[0] would cause PRNG degeneration
        state[0] = fallback_0;
        using_fallback_seed = true;
    }
    if (state[1] == 0) {
        // Security: Zero state[1] would cause PRNG degeneration
        state[1] = fallback_1;
        using_fallback_seed = true;
    }

    initialized = true;
}

/// Generate 64 bits of pseudo-random data
/// Thread-safe via spinlock protection
pub fn next() u64 {
    const held = prng_lock.acquire();
    defer held.release();

    return nextUnsafe();
}

/// Generate random number without lock (internal use only)
/// Caller must hold prng_lock
fn nextUnsafe() u64 {
    const s0 = state[0];
    var s1 = state[1];
    const result = s0 +% s1; // Wrapping addition

    s1 ^= s0;
    state[0] = rotl(s0, 24) ^ s1 ^ (s1 << 16);
    state[1] = rotl(s1, 37);

    return result;
}

/// Rotate left operation
inline fn rotl(x: u64, comptime k: comptime_int) u64 {
    const shift_left: u6 = @intCast(k);
    const shift_right: u6 = @intCast(64 - k);
    return (x << shift_left) | (x >> shift_right);
}

/// Fill buffer with random bytes
/// Thread-safe, suitable for sys_getrandom implementation
pub fn fill(buf: []u8) void {
    const held = prng_lock.acquire();
    defer held.release();

    var i: usize = 0;
    while (i < buf.len) {
        const rand = nextUnsafe();
        const remaining = buf.len - i;
        const to_copy = @min(remaining, 8);

        // Copy bytes from random value to buffer
        const rand_bytes: [8]u8 = @bitCast(rand);
        for (0..to_copy) |j| {
            buf[i + j] = rand_bytes[j];
        }
        i += to_copy;
    }
}

/// Check if PRNG has been initialized
pub fn isInitialized() bool {
    return initialized;
}

/// SECURITY: Check if predictable fallback seed is in use
/// If true, stack canaries and ASLR may be compromised!
/// Callers (e.g., kernel main) should log a warning when this returns true.
pub fn isUsingFallbackSeed() bool {
    return using_fallback_seed;
}

/// Generate random value in range [0, max)
/// Thread-safe
pub fn range(max: u64) u64 {
    if (max == 0) return 0;
    // Use rejection sampling to avoid modulo bias
    const threshold = (0 -% max) % max;
    while (true) {
        const r = next();
        if (r >= threshold) {
            return r % max;
        }
    }
}

/// Fill buffer with hardware entropy directly (for sys_getrandom)
/// Uses RDRAND when available for cryptographic-quality randomness
/// This bypasses the PRNG and goes straight to hardware
pub fn fillFromHardwareEntropy(buf: []u8) void {
    hal.entropy.fillWithHardwareEntropy(buf);
}

/// Mix additional entropy into PRNG state
/// Call this after initialization to incorporate runtime entropy sources
/// (e.g., MAC address, RTC time, jiffies)
/// Thread-safe
pub fn mixEntropy(additional: u64) void {
    const held = prng_lock.acquire();
    defer held.release();

    // Mix into state using XOR and bit rotation
    state[0] ^= additional;
    state[1] ^= rotl(additional, 23);

    // Run a few rounds to diffuse the new entropy
    _ = nextUnsafe();
    _ = nextUnsafe();
}
