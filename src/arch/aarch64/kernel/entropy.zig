// AArch64 Entropy Source
//
// Uses RNDR (Random Number Direct Read) register if FEAT_RNG is available.
// Falls back to timing-based entropy if not.
//
// SECURITY CONSIDERATIONS:
// =======================
// 1. RNDR (FEAT_RNG) provides cryptographically secure random numbers when available.
//    This is the preferred entropy source for all security-critical operations.
//
// 2. The timing-based fallback (getTimingEntropy) is DELIBERATELY LOW QUALITY:
//    - CNTPCT_EL0 and CNTVCT_EL0 are userspace-readable counters
//    - An attacker can correlate their own readings with kernel entropy collection
//    - This reduces effective entropy for KASLR, TCP ISNs, and other security uses
//
// 3. CALLERS MUST CHECK EntropyQuality:
//    - For cryptographic keys: REQUIRE .high quality (RNDR), panic if unavailable
//    - For KASLR/stack canaries: Prefer .high, log warning if using .low
//    - For non-security uses: Any quality is acceptable
//
// 4. The kernel should refuse to boot with low-quality entropy for critical
//    security features. See getHardwareEntropyWithQuality().

const std = @import("std");
const cpu = @import("cpu.zig");

/// Whether FEAT_RNG is available (set during init)
var has_rndr: bool = false;
var initialized: bool = false;

pub const EntropyQuality = enum(u8) {
    high = 64,
    medium = 32,
    low = 16,
    critical = 0,
};

pub const EntropyResult = struct {
    value: u64,
    quality: EntropyQuality,
};

/// Initialize entropy subsystem
/// Checks for FEAT_RNG support via ID_AA64ISAR0_EL1
///
/// SECURITY: After calling init(), check hasRdrand() and handle appropriately:
///   - For security-critical deployments: panic if false
///   - For development/emulation: log warning via logEntropyWarning()
pub fn init() void {
    // Check ID_AA64ISAR0_EL1.RNDR (bits 63:60)
    // 0b0001 = RNDR/RNDRRS implemented
    var isar0: u64 = 0;
    asm volatile ("mrs %[ret], id_aa64isar0_el1"
        : [ret] "=r" (isar0),
    );

    const rndr_field = (isar0 >> 60) & 0xF;
    has_rndr = (rndr_field >= 1);
    initialized = true;
}

/// Log a warning if FEAT_RNG is not available.
/// Call this after init() during boot to alert about weak entropy.
///
/// Parameters:
///   log_fn: Function pointer to kernel logging (e.g., console.printf)
///
/// Returns: true if FEAT_RNG is available (no warning needed), false if weak entropy
pub fn logEntropyWarning(log_fn: *const fn ([*:0]const u8) void) bool {
    if (has_rndr) {
        return true;
    }

    log_fn("SECURITY WARNING: FEAT_RNG (RNDR) not available on this CPU\n");
    log_fn("  Falling back to timing-based entropy which is WEAK.\n");
    log_fn("  Timing counters (CNTPCT_EL0/CNTVCT_EL0) are userspace-readable.\n");
    log_fn("  KASLR, TCP ISNs, and other security features may be predictable.\n");
    log_fn("  For production: use hardware with ARMv8.5-RNG or later.\n");
    return false;
}

/// Check if entropy source is secure for cryptographic use.
/// Returns false if only timing-based fallback is available.
///
/// SECURITY: Callers generating cryptographic keys MUST check this
/// and either panic or refuse to proceed if false.
pub fn isSecureForCrypto() bool {
    return has_rndr;
}

/// Require secure entropy or panic.
/// Call this early in boot for security-critical systems that cannot
/// tolerate weak entropy sources.
///
/// SECURITY: This function MUST be called before using entropy for:
///   - KASLR (Kernel Address Space Layout Randomization)
///   - Stack canaries
///   - Cryptographic key generation
///   - TCP Initial Sequence Numbers (ISNs)
///
/// On systems without FEAT_RNG, this will panic with a clear message
/// explaining the security implications.
pub fn requireSecureEntropy() void {
    if (!initialized) {
        @panic("entropy: requireSecureEntropy called before init()");
    }
    if (!has_rndr) {
        @panic(
            \\SECURITY FATAL: Secure entropy source (FEAT_RNG) not available.
            \\
            \\This system lacks hardware RNG support. The timing-based fallback
            \\is NOT secure because CNTPCT_EL0/CNTVCT_EL0 are readable from
            \\userspace, allowing attackers to predict kernel entropy.
            \\
            \\Affected security features:
            \\  - KASLR may be predictable
            \\  - Stack canaries may be guessable
            \\  - TCP ISNs may enable connection hijacking
            \\  - Cryptographic keys may be weak
            \\
            \\To proceed (INSECURE - development only):
            \\  Call entropy.init() without requireSecureEntropy()
            \\
            \\For production: Use hardware with ARMv8.5-RNG or later.
        );
    }
}

/// Get entropy with quality assertion.
/// Panics if only low-quality entropy is available.
/// Use this for security-critical entropy needs.
pub fn getSecureEntropy() u64 {
    if (!has_rndr) {
        @panic("getSecureEntropy: FEAT_RNG required but not available");
    }
    // Try RNDR up to 10 times
    var attempts: u32 = 0;
    while (attempts < 10) : (attempts += 1) {
        if (tryReadRndr()) |value| {
            return value;
        }
        cpu.pause();
    }
    @panic("getSecureEntropy: RNDR consistently failing");
}

/// Check if entropy is initialized
pub fn isInitialized() bool {
    return initialized;
}

/// Check if hardware RNG is available (FEAT_RNG / RNDR)
pub fn hasRdrand() bool {
    return has_rndr;
}

/// Try to read RNDR register
/// Returns null if RNDR fails (retry needed) or not supported
fn tryReadRndr() ?u64 {
    if (!has_rndr) return null;

    // SECURITY NOTE: `undefined` for ASM output operands is safe - the `mrs`
    // instruction immediately overwrites the value before any read occurs.
    var value: u64 = undefined;
    var nzcv: u64 = undefined;

    // MRS with RNDR can fail (NZCV.Z set if retry needed)
    // We use inline asm to read RNDR and check the result
    asm volatile (
        \\mrs %[val], s3_3_c2_c4_0
        \\mrs %[flags], nzcv
        : [val] "=r" (value),
          [flags] "=r" (nzcv),
    );

    // Check if Z flag is set (bit 30 of NZCV) - means retry needed
    if ((nzcv & (1 << 30)) != 0) {
        return null;
    }

    return value;
}

/// Get hardware entropy (best effort)
pub fn getHardwareEntropy() u64 {
    if (has_rndr) {
        // Try RNDR up to 10 times
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            if (tryReadRndr()) |value| {
                return value;
            }
            // Small delay between retries
            cpu.pause();
        }
    }

    // Fallback: timing-based entropy (low quality)
    return getTimingEntropy();
}

/// SplitMix64-style finalization to thoroughly mix bits.
/// This ensures even weak entropy sources have good bit distribution.
fn finalizeMix(h: u64) u64 {
    var x = h;
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    x *%= 0xc4ceb9fe1a85ec53;
    x ^= x >> 33;
    return x;
}

/// Rotate left helper
fn rotl64(x: u64, k: u6) u64 {
    // (64 - k) with proper handling: ~k + 1 for u6 wraps correctly
    // For k in 0..63, (64 - k) mod 64 == (-k) mod 64 == ~k + 1
    // But simpler: just use std.math.rotr or compute in larger type
    const right_shift: u6 = @truncate(64 -% @as(u7, k));
    return (x << k) | (x >> right_shift);
}

/// Read physical counter (CNTPCT_EL0)
fn readCntpct() u64 {
    var value: u64 = undefined;
    asm volatile ("mrs %[ret], cntpct_el0"
        : [ret] "=r" (value),
    );
    return value;
}

/// Read virtual counter (CNTVCT_EL0)
fn readCntvct() u64 {
    var value: u64 = undefined;
    asm volatile ("mrs %[ret], cntvct_el0"
        : [ret] "=r" (value),
    );
    return value;
}

/// Enhanced timing-based entropy (low quality fallback)
/// Collects multiple timing samples with memory barriers for jitter.
///
/// SECURITY NOTE: This fallback is deliberately low quality and should only
/// be used when RNDR is unavailable. The counters (CNTPCT_EL0/CNTVCT_EL0)
/// are readable from userspace, so an attacker with access to the system
/// could potentially predict some bits. We mitigate this by:
///   1. Taking multiple samples with barriers for timing jitter
///   2. Mixing in KASLR-dependent addresses
///   3. Using a strong finalization function (SplitMix64)
///
/// Callers should check EntropyQuality and avoid using low-quality
/// entropy for security-critical operations (e.g., cryptographic keys).
fn getTimingEntropy() u64 {
    var entropy: u64 = 0;

    // Collect multiple timing samples with memory barriers for jitter
    for (0..8) |i| {
        const t1 = readCntpct();
        // ISB introduces instruction synchronization barrier - timing jitter source
        asm volatile ("isb");
        const t2 = readCntvct();
        // DSB SY is a data synchronization barrier
        asm volatile ("dsb sy");
        const t3 = readCntpct();

        // XOR in the deltas, rotated by sample index
        entropy ^= rotl64(t1 ^ t2, @truncate(i * 7));
        entropy ^= rotl64(t2 ^ t3, @truncate(i * 5 + 3));
    }

    // Mix in stack address (varies with call depth and ASLR)
    // SECURITY NOTE: `undefined` here is intentional and safe - we only use
    // @intFromPtr(&stack_addr) to get the ADDRESS, never reading the VALUE.
    // The address provides entropy from stack layout/ASLR.
    var stack_addr: usize = undefined;
    entropy ^= @intFromPtr(&stack_addr);

    // Mix in code address (varies with KASLR)
    entropy ^= @intFromPtr(&getTimingEntropy);

    // Mix in exception vector table address (set during boot, KASLR-dependent)
    entropy ^= readVbarEl1();

    // Mix in SCTLR_EL1 (system control register - varies by boot configuration)
    entropy ^= readSctlrEl1();

    // Mix in MPIDR_EL1 (CPU affinity - provides per-core uniqueness)
    entropy ^= readMpidrEl1();

    // Final mixing pass
    return finalizeMix(entropy);
}

/// Read VBAR_EL1 (Vector Base Address Register)
fn readVbarEl1() u64 {
    var val: u64 = undefined;
    asm volatile ("mrs %[ret], vbar_el1" : [ret] "=r" (val));
    return val;
}

/// Read SCTLR_EL1 (System Control Register)
fn readSctlrEl1() u64 {
    var val: u64 = undefined;
    asm volatile ("mrs %[ret], sctlr_el1" : [ret] "=r" (val));
    return val;
}

/// Read MPIDR_EL1 (Multiprocessor Affinity Register)
fn readMpidrEl1() u64 {
    var val: u64 = undefined;
    asm volatile ("mrs %[ret], mpidr_el1" : [ret] "=r" (val));
    return val;
}

/// Get hardware entropy with quality indicator
pub fn getHardwareEntropyWithQuality() EntropyResult {
    if (has_rndr) {
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            if (tryReadRndr()) |value| {
                return .{ .value = value, .quality = .high };
            }
            cpu.pause();
        }
    }

    // Fallback to timing
    return .{
        .value = getTimingEntropy(),
        .quality = .low,
    };
}

/// Fill buffer with hardware entropy
///
/// WARNING: This function may use low-quality timing entropy as fallback.
/// For security-critical buffers (cryptographic keys, nonces), use
/// tryFillWithHardwareEntropy() and check the return value, or use
/// fillWithHardwareEntropyStrict() which panics on low quality.
pub fn fillWithHardwareEntropy(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const entropy = getHardwareEntropy();
        const bytes = std.mem.asBytes(&entropy);
        const to_copy = @min(bytes.len, buf.len - i);
        @memcpy(buf[i..][0..to_copy], bytes[0..to_copy]);
        i += to_copy;
    }
}

/// Fill buffer with high-quality hardware entropy only.
/// SECURITY: Panics if FEAT_RNG is not available. Use for cryptographic keys.
pub fn fillWithHardwareEntropyStrict(buf: []u8) void {
    if (!has_rndr) {
        @panic("fillWithHardwareEntropyStrict: FEAT_RNG required but not available");
    }

    var i: usize = 0;
    var failures: u32 = 0;
    while (i < buf.len) {
        if (tryReadRndr()) |entropy| {
            const bytes = std.mem.asBytes(&entropy);
            const to_copy = @min(bytes.len, buf.len - i);
            @memcpy(buf[i..][0..to_copy], bytes[0..to_copy]);
            i += to_copy;
            failures = 0;
        } else {
            failures += 1;
            if (failures > 100) {
                @panic("fillWithHardwareEntropyStrict: RNDR consistently failing");
            }
            cpu.pause();
        }
    }
}

/// Try to fill buffer with hardware entropy
/// Returns true if successful (high quality), false if fallback was used
pub fn tryFillWithHardwareEntropy(buf: []u8) bool {
    if (!has_rndr) {
        fillWithHardwareEntropy(buf);
        return false;
    }

    var i: usize = 0;
    while (i < buf.len) {
        if (tryReadRndr()) |entropy| {
            const bytes = std.mem.asBytes(&entropy);
            const to_copy = @min(bytes.len, buf.len - i);
            @memcpy(buf[i..][0..to_copy], bytes[0..to_copy]);
            i += to_copy;
        } else {
            // RNDR failed, use timing fallback for rest
            const entropy = getTimingEntropy();
            const bytes = std.mem.asBytes(&entropy);
            const to_copy = @min(bytes.len, buf.len - i);
            @memcpy(buf[i..][0..to_copy], bytes[0..to_copy]);
            i += to_copy;
            return false;
        }
    }
    return true;
}
