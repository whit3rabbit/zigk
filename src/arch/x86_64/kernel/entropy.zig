// HAL Entropy Source Module (x86_64)
//
// Provides hardware entropy sources (RDSEED, RDRAND, TSC) for the kernel.
// Architecture-agnostic CSPRNG logic is located in src/kernel/core/random.zig.

const cpu = @import("cpu.zig");
const timing = @import("timing.zig");
const console = @import("console");
const sync = @import("sync");
const atomic = @import("std").atomic;

// External assembly helpers (from asm_helpers.S)
extern fn _asm_rdrand64(success: *u8) u64;
extern fn _asm_rdseed64(success: *u8) u64;
extern fn _asm_rdtsc() u64;

// CPUID feature bits
const CPUID_FEAT_ECX_RDRAND: u32 = 1 << 30; // CPUID.01H:ECX bit 30
const CPUID_FEAT_EBX_RDSEED: u32 = 1 << 18; // CPUID.07H:EBX bit 18

// Module state
var rdrand_available: bool = false;
var rdseed_available: bool = false;
var initialized: atomic.Value(bool) = atomic.Value(bool).init(false);
var state_lock: sync.Spinlock = .{};

// Health monitoring
var rdrand_failure_count: u64 = 0;

/// Initialization quality levels
pub const EntropyQuality = enum(u8) {
    high = 64,
    medium = 32,
    low = 16,
    critical = 0,
};

/// Initialize hardware entropy sources
pub fn init() void {
    const held = state_lock.acquire();
    defer held.release();

    const cpuid1 = cpu.cpuid(1, 0);
    rdrand_available = (cpuid1.ecx & CPUID_FEAT_ECX_RDRAND) != 0;

    const cpuid7 = cpu.cpuid(7, 0);
    rdseed_available = (cpuid7.ebx & CPUID_FEAT_EBX_RDSEED) != 0;

    initialized.store(true, .release);

    if (rdseed_available) console.info("Entropy: RDSEED available", .{});
    if (rdrand_available) console.info("Entropy: RDRAND available", .{});
    if (!rdrand_available and !rdseed_available) {
        console.warn("Entropy: No hardware RNG! Using weak TSC fallback", .{});
    }
}

pub fn hasRdrand() bool { return rdrand_available; }
pub fn hasRdseed() bool { return rdseed_available; }
pub fn isInitialized() bool { return initialized.load(.acquire); }

pub fn rdrand64() ?u64 {
    if (!rdrand_available) return null;
    var success: u8 = 0;
    const value = _asm_rdrand64(&success);
    return if (success != 0) value else null;
}

pub fn rdseed64() ?u64 {
    if (!rdseed_available) return null;
    var success: u8 = 0;
    const value = _asm_rdseed64(&success);
    return if (success != 0) value else null;
}

pub fn rdtsc() u64 { return _asm_rdtsc(); }

pub const EntropyResult = struct {
    value: u64,
    quality: EntropyQuality,
};

pub fn getHardwareEntropyWithQuality() EntropyResult {
    var success: u8 = 0;
    var val: u64 = 0;

    if (rdseed_available) {
        val = _asm_rdseed64(&success);
        if (success != 0) return .{ .value = val, .quality = .high };
    }
    if (rdrand_available) {
        val = _asm_rdrand64(&success);
        if (success != 0) return .{ .value = val, .quality = .high };
        rdrand_failure_count += 1;
    }

    // Fallback
    val = rdtsc() ^ (@as(u64, @intFromPtr(&val)) << 32);
    return .{ .value = val, .quality = .low };
}

pub fn getHardwareEntropy() u64 {
    return getHardwareEntropyWithQuality().value;
}

pub fn fillWithHardwareEntropy(buf: []u8) void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const res = getHardwareEntropyWithQuality();
        const bytes: [8]u8 = @bitCast(res.value);
        const to_copy = @min(buf.len - offset, 8);
        @memcpy(buf[offset..][0..to_copy], bytes[0..to_copy]);
        offset += to_copy;
    }
}

pub fn tryFillWithHardwareEntropy(buf: []u8) bool {
    if (!rdrand_available and !rdseed_available) return false;
    var offset: usize = 0;
    while (offset < buf.len) {
        var success: u8 = 0;
        var val: u64 = 0;
        if (rdseed_available) {
            val = _asm_rdseed64(&success);
        }
        if (success == 0 and rdrand_available) {
            val = _asm_rdrand64(&success);
        }
        if (success == 0) return false;

        const bytes: [8]u8 = @bitCast(val);
        const to_copy = @min(buf.len - offset, 8);
        @memcpy(buf[offset..][0..to_copy], bytes[0..to_copy]);
        offset += to_copy;
    }
    return true;
}
