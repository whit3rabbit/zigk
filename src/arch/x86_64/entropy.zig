// HAL Entropy Source Module
//
// Provides hardware entropy sources and a CSPRNG for kernel randomization needs.
// Per Constitution Principle VI (Strict Layering): Only src/arch/ may
// contain inline assembly or direct hardware access.
//
// Security Architecture:
// ----------------------
// This module implements a defense-in-depth entropy system:
//
// 1. Hardware entropy sources (in preference order):
//    - RDSEED: True hardware entropy (preferred for CSPRNG seeding)
//    - RDRAND: DRBG-based hardware RNG (good quality, widely available)
//    - Fallback: TSC + multiple weak sources (last resort)
//
// 2. ChaCha20-based CSPRNG:
//    - Seeded from hardware entropy at boot
//    - Continuously re-seeded from accumulated entropy
//    - Used for security-critical randomness when RDRAND unavailable
//
// 3. Entropy pool:
//    - Accumulates entropy from multiple sources over time
//    - Sources: interrupts, device timing, network packets, disk I/O
//    - Mixed into CSPRNG state periodically
//
// 4. Quality tracking:
//    - Tracks estimated entropy bits available
//    - Callers can check quality before security-critical operations
//    - Warnings logged when using weak entropy
//
// Security Notes:
// - RDSEED/RDRAND provide cryptographic-quality randomness
// - Fallback path is NOT cryptographically secure but provides best-effort
// - Boot-time entropy starvation is mitigated by delayed canary generation
// - All state changes are atomic or protected by spinlock

const cpu = @import("cpu.zig");
const timing = @import("timing.zig");
const console = @import("console");
const sync = @import("sync");

// External assembly helpers (from asm_helpers.S)
extern fn _asm_rdrand64(success: *u8) u64;
extern fn _asm_rdseed64(success: *u8) u64;
extern fn _asm_rdtsc() u64;

// CPUID feature bits
const CPUID_FEAT_ECX_RDRAND: u32 = 1 << 30; // CPUID.01H:ECX bit 30
const CPUID_FEAT_EBX_RDSEED: u32 = 1 << 18; // CPUID.07H:EBX bit 18

// Entropy quality levels (estimated bits of entropy)
pub const EntropyQuality = enum(u8) {
    // Security: Quality levels indicate cryptographic strength
    // HIGH: Suitable for cryptographic keys, nonces, IVs
    // MEDIUM: Suitable for session tokens, ASLR, stack canaries
    // LOW: Best-effort only, NOT suitable for security-critical use
    high = 64, // RDSEED/RDRAND - full entropy
    medium = 32, // CSPRNG with good seed - derived entropy
    low = 16, // Fallback sources - weak entropy, security risk
    critical = 0, // Initialization only - DO NOT USE for security
};

// Entropy source identification for diagnostics
pub const EntropySource = enum {
    rdseed, // True hardware entropy (best)
    rdrand, // DRBG-based hardware entropy (good)
    csprng, // ChaCha20 CSPRNG (derived from hardware seed)
    fallback, // TSC + weak mixing (last resort)
    uninitialized,
};

// Module state
var rdrand_available: bool = false;
var rdseed_available: bool = false;
var initialized: bool = false;
var csprng_seeded: bool = false;
var state_lock: sync.Spinlock = .{};

// Entropy accounting
var estimated_entropy_bits: u32 = 0;
var rdrand_failure_count: u64 = 0;
var fallback_usage_count: u64 = 0;
var last_entropy_source: EntropySource = .uninitialized;

// ChaCha20 CSPRNG state (256-bit key + 96-bit nonce + 32-bit counter)
// Security: This provides cryptographic-quality output when seeded properly
var chacha_state: ChaCha20State = .{};
var chacha_output_index: usize = 64; // Force reseed on first use

// Entropy pool for accumulating runtime entropy
// Security: Mixed sources reduce predictability even if some sources are weak
var entropy_pool: [4]u64 = .{ 0, 0, 0, 0 };
var pool_mix_counter: u64 = 0;

// ChaCha20 implementation (RFC 8439)
const ChaCha20State = struct {
    // 512-bit state: constants (4) + key (8) + counter (1) + nonce (3)
    state: [16]u32 = undefined,

    const CONSTANTS = [4]u32{ 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574 };

    fn init(key: [8]u32, nonce: [3]u32) ChaCha20State {
        var s = ChaCha20State{};
        s.state[0..4].* = CONSTANTS;
        s.state[4..12].* = key;
        s.state[12] = 0; // Counter
        s.state[13..16].* = nonce;
        return s;
    }

    fn quarterRound(a: *u32, b: *u32, c: *u32, d: *u32) void {
        a.* +%= b.*; d.* ^= a.*; d.* = rotl32(d.*, 16);
        c.* +%= d.*; b.* ^= c.*; b.* = rotl32(b.*, 12);
        a.* +%= b.*; d.* ^= a.*; d.* = rotl32(d.*, 8);
        c.* +%= d.*; b.* ^= c.*; b.* = rotl32(b.*, 7);
    }

    fn rotl32(x: u32, comptime n: u5) u32 {
        const right_shift: u5 = 32 - @as(u6, n);
        return (x << n) | (x >> right_shift);
    }

    // Generate 64 bytes of output
    fn block(self: *ChaCha20State, output: *[64]u8) void {
        var working: [16]u32 = self.state;

        // 20 rounds (10 double-rounds)
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            // Column rounds
            quarterRound(&working[0], &working[4], &working[8], &working[12]);
            quarterRound(&working[1], &working[5], &working[9], &working[13]);
            quarterRound(&working[2], &working[6], &working[10], &working[14]);
            quarterRound(&working[3], &working[7], &working[11], &working[15]);
            // Diagonal rounds
            quarterRound(&working[0], &working[5], &working[10], &working[15]);
            quarterRound(&working[1], &working[6], &working[11], &working[12]);
            quarterRound(&working[2], &working[7], &working[8], &working[13]);
            quarterRound(&working[3], &working[4], &working[9], &working[14]);
        }

        // Add original state and serialize to bytes
        for (0..16) |j| {
            const val = working[j] +% self.state[j];
            output[j * 4 + 0] = @truncate(val);
            output[j * 4 + 1] = @truncate(val >> 8);
            output[j * 4 + 2] = @truncate(val >> 16);
            output[j * 4 + 3] = @truncate(val >> 24);
        }

        // Increment counter
        self.state[12] +%= 1;
    }
};

// CSPRNG output buffer (reused between calls)
var csprng_buffer: [64]u8 = undefined;

/// Initialize the entropy subsystem
/// Checks CPU feature flags to determine available entropy sources
/// Must be called before any entropy functions are used
pub fn init() void {
    const held = state_lock.acquire();
    defer held.release();

    // Check RDRAND availability via CPUID leaf 1
    const cpuid1 = cpu.cpuid(1, 0);
    rdrand_available = (cpuid1.ecx & CPUID_FEAT_ECX_RDRAND) != 0;

    // Check RDSEED availability via CPUID leaf 7
    const cpuid7 = cpu.cpuid(7, 0);
    rdseed_available = (cpuid7.ebx & CPUID_FEAT_EBX_RDSEED) != 0;

    // Initialize CSPRNG with best available entropy
    seedCsprngLocked();

    initialized = true;

    // Security: Log entropy source availability for diagnostics
    // This helps identify systems running with weak entropy
    if (rdseed_available) {
        console.info("Entropy: RDSEED available (true hardware entropy)", .{});
    }
    if (rdrand_available) {
        console.info("Entropy: RDRAND available (DRBG-based)", .{});
    }
    if (!rdrand_available and !rdseed_available) {
        // Security warning: System will use weak fallback entropy
        console.warn("Entropy: No hardware RNG! Using weak TSC fallback", .{});
        console.warn("  -> Stack canaries and ASLR may be predictable", .{});
        console.warn("  -> DNS/TCP randomization is weakened", .{});
    }
}

/// Seed CSPRNG from hardware entropy (internal, caller must hold lock)
fn seedCsprngLocked() void {
    var key: [8]u32 = undefined;
    var nonce: [3]u32 = undefined;
    var seed_quality: EntropyQuality = .critical;

    // Try RDSEED first (highest quality)
    if (rdseed_available) {
        if (fillFromRdseed(&key, &nonce)) {
            seed_quality = .high;
            last_entropy_source = .rdseed;
            csprng_seeded = true;
        }
    }

    // Fall back to RDRAND
    if (!csprng_seeded and rdrand_available) {
        if (fillFromRdrand(&key, &nonce)) {
            seed_quality = .high;
            last_entropy_source = .rdrand;
            csprng_seeded = true;
        }
    }

    // Last resort: weak fallback
    if (!csprng_seeded) {
        fillFromFallback(&key, &nonce);
        seed_quality = .low;
        last_entropy_source = .fallback;
        fallback_usage_count += 1;
        csprng_seeded = true;
    }

    chacha_state = ChaCha20State.init(key, nonce);
    chacha_output_index = 64; // Force regeneration on first use
    estimated_entropy_bits = @intFromEnum(seed_quality);
}

/// Fill key/nonce from RDSEED
fn fillFromRdseed(key: *[8]u32, nonce: *[3]u32) bool {
    var success: u8 = 0;

    // Fill key (256 bits)
    for (key) |*k| {
        var attempts: u32 = 0;
        while (attempts < 20) : (attempts += 1) {
            const val = _asm_rdseed64(&success);
            if (success != 0) {
                k.* = @truncate(val);
                break;
            }
            // RDSEED may need more time to gather entropy
            cpu.pause();
        }
        if (success == 0) return false;
    }

    // Fill nonce (96 bits)
    for (nonce) |*n| {
        var attempts: u32 = 0;
        while (attempts < 20) : (attempts += 1) {
            const val = _asm_rdseed64(&success);
            if (success != 0) {
                n.* = @truncate(val);
                break;
            }
            cpu.pause();
        }
        if (success == 0) return false;
    }

    return true;
}

/// Fill key/nonce from RDRAND
fn fillFromRdrand(key: *[8]u32, nonce: *[3]u32) bool {
    var success: u8 = 0;

    for (key) |*k| {
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            const val = _asm_rdrand64(&success);
            if (success != 0) {
                k.* = @truncate(val);
                break;
            }
        }
        if (success == 0) {
            rdrand_failure_count += 1;
            return false;
        }
    }

    for (nonce) |*n| {
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            const val = _asm_rdrand64(&success);
            if (success != 0) {
                n.* = @truncate(val);
                break;
            }
        }
        if (success == 0) {
            rdrand_failure_count += 1;
            return false;
        }
    }

    return true;
}

/// Fill key/nonce from weak fallback sources
/// Security: This is NOT cryptographically secure. It's a best-effort
/// fallback when hardware RNG is unavailable. The output is predictable
/// to attackers who can observe or estimate:
/// - TSC values (correlates with uptime and CPU frequency)
/// - Stack addresses (limited by ASLR, if any)
/// - Boot sequence timing
fn fillFromFallback(key: *[8]u32, nonce: *[3]u32) void {
    // Gather multiple TSC samples with timing variance
    var tsc_samples: [16]u64 = undefined;
    for (&tsc_samples) |*s| {
        s.* = _asm_rdtsc();
        // Add some delay to increase timing variance
        var j: u32 = 0;
        while (j < 100) : (j += 1) {
            cpu.pause();
        }
    }

    // Get stack address entropy (limited by ASLR)
    var stack_addr: usize = undefined;
    const addr_entropy: u64 = @intFromPtr(&stack_addr);

    // Mix samples using a simple hash-like function
    // This doesn't create entropy but spreads what little we have
    var mixed: [11]u64 = undefined;
    for (&mixed, 0..) |*m, i| {
        var val = tsc_samples[i] ^ tsc_samples[i + 1];
        val ^= rotl64(addr_entropy, @truncate(i * 7));
        val ^= entropy_pool[i % 4];

        // Additional mixing rounds
        val ^= val >> 33;
        val *%= 0xff51afd7ed558ccd;
        val ^= val >> 33;
        val *%= 0xc4ceb9fe1a85ec53;
        val ^= val >> 33;

        m.* = val;
    }

    // Fill key
    for (key, 0..) |*k, i| {
        k.* = @truncate(mixed[i]);
    }

    // Fill nonce
    for (nonce, 0..) |*n, i| {
        n.* = @truncate(mixed[8 + i]);
    }
}

fn rotl64(x: u64, k: u6) u64 {
    // Handle k=0 edge case (would result in 64-bit shift which is undefined)
    if (k == 0) return x;
    const right_shift: u6 = @intCast(64 - @as(u7, k));
    return (x << k) | (x >> right_shift);
}

/// Check if RDRAND instruction is available
pub fn hasRdrand() bool {
    return rdrand_available;
}

/// Check if RDSEED instruction is available
pub fn hasRdseed() bool {
    return rdseed_available;
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

/// Try to get 64-bit random seed from RDSEED instruction
/// Returns null if RDSEED fails (may happen frequently as it drains entropy)
pub fn rdseed64() ?u64 {
    if (!rdseed_available) return null;

    var success: u8 = 0;
    const value = _asm_rdseed64(&success);

    return if (success != 0) value else null;
}

/// Read Time Stamp Counter (TSC)
/// Returns 64-bit monotonic cycle counter
/// Provides weak entropy based on timing unpredictability
/// Always available on x86_64 (instruction exists since Pentium)
pub fn rdtsc() u64 {
    return _asm_rdtsc();
}

/// Result of entropy request including quality indicator
pub const EntropyResult = struct {
    value: u64,
    quality: EntropyQuality,
    source: EntropySource,
};

/// Get hardware entropy from best available source with quality info
/// Security: Callers should check quality for security-critical operations
pub fn getHardwareEntropyWithQuality() EntropyResult {
    const held = state_lock.acquire();
    defer held.release();

    // Try RDSEED first (true entropy)
    if (rdseed_available) {
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            if (rdseed64()) |value| {
                last_entropy_source = .rdseed;
                return .{
                    .value = value,
                    .quality = .high,
                    .source = .rdseed,
                };
            }
        }
    }

    // Try RDRAND (DRBG-based)
    if (rdrand_available) {
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            if (rdrand64()) |value| {
                last_entropy_source = .rdrand;
                return .{
                    .value = value,
                    .quality = .high,
                    .source = .rdrand,
                };
            }
        }
        // Security: RDRAND exhausted - this is unusual
        rdrand_failure_count += 1;
    }

    // Fall back to CSPRNG if seeded
    if (csprng_seeded and estimated_entropy_bits >= @intFromEnum(EntropyQuality.medium)) {
        const value = getCsprngU64Locked();
        last_entropy_source = .csprng;
        return .{
            .value = value,
            .quality = .medium,
            .source = .csprng,
        };
    }

    // Last resort: weak fallback
    fallback_usage_count += 1;
    const value = getWeakFallbackLocked();
    last_entropy_source = .fallback;

    // Security: Log warning on first fallback usage
    if (fallback_usage_count == 1) {
        console.warn("Entropy: Using weak fallback - security degraded", .{});
    }

    return .{
        .value = value,
        .quality = .low,
        .source = .fallback,
    };
}

/// Get hardware entropy from best available source (legacy API)
/// Security: This hides quality info - prefer getHardwareEntropyWithQuality()
/// for security-critical operations
pub fn getHardwareEntropy() u64 {
    return getHardwareEntropyWithQuality().value;
}

/// Get 64 bits from CSPRNG (internal, caller must hold lock)
fn getCsprngU64Locked() u64 {
    // Check if we need to generate more output
    if (chacha_output_index >= 64) {
        chacha_state.block(&csprng_buffer);
        chacha_output_index = 0;
    }

    // Extract 8 bytes
    const bytes = csprng_buffer[chacha_output_index..][0..8];
    chacha_output_index += 8;

    return @as(u64, bytes[0]) |
        (@as(u64, bytes[1]) << 8) |
        (@as(u64, bytes[2]) << 16) |
        (@as(u64, bytes[3]) << 24) |
        (@as(u64, bytes[4]) << 32) |
        (@as(u64, bytes[5]) << 40) |
        (@as(u64, bytes[6]) << 48) |
        (@as(u64, bytes[7]) << 56);
}

/// Get weak fallback entropy (internal, caller must hold lock)
fn getWeakFallbackLocked() u64 {
    // Multiple TSC samples with timing variance
    const tsc1 = _asm_rdtsc();
    const tsc2 = _asm_rdtsc();
    const tsc3 = _asm_rdtsc();

    // Stack address
    var stack_addr: usize = undefined;
    const addr_entropy: u64 = @intFromPtr(&stack_addr);

    // Mix with entropy pool
    var result = tsc1 ^ rotl64(tsc2, 7) ^ rotl64(tsc3, 13);
    result ^= rotl64(addr_entropy, 17);
    result ^= entropy_pool[pool_mix_counter % 4];
    pool_mix_counter +%= 1;

    // Additional mixing
    result ^= result >> 33;
    result *%= 0xff51afd7ed558ccd;
    result ^= result >> 33;

    return result;
}

/// Check if entropy subsystem has been initialized
pub fn isInitialized() bool {
    return initialized;
}

/// Get current entropy quality estimate
pub fn getEstimatedQuality() EntropyQuality {
    if (rdseed_available or rdrand_available) return .high;
    if (csprng_seeded and estimated_entropy_bits >= 32) return .medium;
    return .low;
}

/// Get last entropy source used (for diagnostics)
pub fn getLastSource() EntropySource {
    return last_entropy_source;
}

/// Get count of RDRAND exhaustion events (for health monitoring)
pub fn getRdrandFailureCount() u64 {
    return rdrand_failure_count;
}

/// Get count of fallback entropy usages (security metric)
pub fn getFallbackUsageCount() u64 {
    return fallback_usage_count;
}

/// Mix additional entropy into the pool
/// Call this from interrupt handlers, device drivers, etc.
/// Security: More entropy sources = harder to predict output
pub fn mixRuntimeEntropy(value: u64) void {
    const held = state_lock.acquire();
    defer held.release();

    // Mix into pool with rotation to spread bits
    const idx = pool_mix_counter % 4;
    entropy_pool[idx] ^= value ^ rotl64(value, 23);
    pool_mix_counter +%= 1;

    // Periodically re-seed CSPRNG with accumulated entropy
    // Security: Limits damage from potential state compromise
    if (pool_mix_counter % 1024 == 0 and csprng_seeded) {
        reseedCsprngFromPoolLocked();
    }
}

/// Re-seed CSPRNG from entropy pool (internal)
fn reseedCsprngFromPoolLocked() void {
    // Mix pool contents into CSPRNG state
    for (0..4) |i| {
        const pool_val = entropy_pool[i];
        chacha_state.state[4 + i] ^= @truncate(pool_val);
        chacha_state.state[8 + i] ^= @truncate(pool_val >> 32);
    }

    // Force regeneration
    chacha_output_index = 64;
}

/// Fill a buffer with hardware entropy (for sys_getrandom)
/// Uses best available source for cryptographic-quality randomness
pub fn fillWithHardwareEntropy(buf: []u8) void {
    const held = state_lock.acquire();
    defer held.release();

    var offset: usize = 0;

    while (offset < buf.len) {
        // Get 8 bytes of entropy from best source
        var entropy: u64 = 0;
        var success: u8 = 0;
        var got_hardware = false;

        // Try RDSEED first
        if (rdseed_available) {
            var attempts: u32 = 0;
            while (attempts < 10) : (attempts += 1) {
                entropy = _asm_rdseed64(&success);
                if (success != 0) {
                    got_hardware = true;
                    break;
                }
            }
        }

        // Try RDRAND
        if (!got_hardware and rdrand_available) {
            var attempts: u32 = 0;
            while (attempts < 10) : (attempts += 1) {
                entropy = _asm_rdrand64(&success);
                if (success != 0) {
                    got_hardware = true;
                    break;
                }
            }
            if (!got_hardware) {
                rdrand_failure_count += 1;
            }
        }

        // Use CSPRNG if hardware unavailable
        if (!got_hardware) {
            if (csprng_seeded) {
                entropy = getCsprngU64Locked();
            } else {
                entropy = getWeakFallbackLocked();
                fallback_usage_count += 1;
            }
        }

        // Copy bytes to buffer
        const bytes = @as(*const [8]u8, @ptrCast(&entropy));
        const remaining = buf.len - offset;
        const to_copy = @min(remaining, 8);

        for (0..to_copy) |i| {
            buf[offset + i] = bytes[i];
        }
        offset += to_copy;
    }
}

/// Re-seed the CSPRNG from hardware entropy
/// Security: Call this after gathering additional entropy (e.g., after
/// network initialization provides MAC addresses, after disk I/O)
pub fn reseedCsprng() void {
    const held = state_lock.acquire();
    defer held.release();

    // Only re-seed if we can get good entropy
    if (rdseed_available or rdrand_available) {
        seedCsprngLocked();
        console.info("Entropy: CSPRNG re-seeded from hardware", .{});
    }
}

/// Check if CSPRNG has been seeded with good entropy
pub fn isCsprngSeeded() bool {
    return csprng_seeded and (rdseed_available or rdrand_available);
}

/// Try to fill buffer with hardware entropy (RDRAND/RDSEED only)
/// Returns true if hardware entropy was available, false if not.
/// SECURITY: Unlike fillWithHardwareEntropy(), this does NOT fall back to CSPRNG or TSC.
/// Use this for security-critical operations where weak entropy is unacceptable.
pub fn tryFillWithHardwareEntropy(buf: []u8) bool {
    const held = state_lock.acquire();
    defer held.release();

    // Require hardware entropy - no fallbacks
    if (!rdseed_available and !rdrand_available) {
        return false;
    }

    var offset: usize = 0;

    while (offset < buf.len) {
        var entropy: u64 = 0;
        var success: u8 = 0;
        var got_hardware = false;

        // Try RDSEED first (true entropy)
        if (rdseed_available) {
            var attempts: u32 = 0;
            while (attempts < 20) : (attempts += 1) {
                entropy = _asm_rdseed64(&success);
                if (success != 0) {
                    got_hardware = true;
                    break;
                }
                cpu.pause();
            }
        }

        // Try RDRAND (DRBG-based)
        if (!got_hardware and rdrand_available) {
            var attempts: u32 = 0;
            while (attempts < 10) : (attempts += 1) {
                entropy = _asm_rdrand64(&success);
                if (success != 0) {
                    got_hardware = true;
                    break;
                }
            }
        }

        // SECURITY: If hardware failed, abort entirely - no weak fallback
        if (!got_hardware) {
            rdrand_failure_count += 1;
            return false;
        }

        // Copy bytes to buffer
        const bytes = @as(*const [8]u8, @ptrCast(&entropy));
        const remaining = buf.len - offset;
        const to_copy = @min(remaining, 8);

        for (0..to_copy) |i| {
            buf[offset + i] = bytes[i];
        }
        offset += to_copy;
    }

    return true;
}
