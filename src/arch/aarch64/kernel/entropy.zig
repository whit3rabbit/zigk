// AArch64 Entropy Source
//
// Uses RNDR (Random Number Direct Read) register if FEAT_RNG is available.
// Falls back to timing-based entropy if not.

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
pub fn init() void {
    // Check ID_AA64ISAR0_EL1.RNDR (bits 63:60)
    // 0b0001 = RNDR/RNDRRS implemented
    var isar0: u64 = undefined;
    asm volatile ("mrs %[ret], id_aa64isar0_el1"
        : [ret] "=r" (isar0),
    );

    const rndr_field = (isar0 >> 60) & 0xF;
    has_rndr = (rndr_field >= 1);
    initialized = true;
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

/// Get timing-based entropy (low quality fallback)
fn getTimingEntropy() u64 {
    // Read various time sources and mix them
    var cntpct: u64 = undefined;
    asm volatile ("mrs %[ret], cntpct_el0"
        : [ret] "=r" (cntpct),
    );

    var cntvct: u64 = undefined;
    asm volatile ("mrs %[ret], cntvct_el0"
        : [ret] "=r" (cntvct),
    );

    // Mix the values
    return cntpct ^ (cntvct << 13) ^ (cntvct >> 7);
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
