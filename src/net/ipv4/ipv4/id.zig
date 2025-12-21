const std = @import("std");
const platform = @import("../../platform.zig");
const clock = @import("../../clock.zig");
const entropy = platform.entropy;

/// Fallback PRNG state for when hardware entropy is unavailable
var fallback_prng_state: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var prng_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Get next IP identification value
pub fn getNextId() u16 {
    const hw_entropy = entropy.getHardwareEntropy();

    if (hw_entropy != 0 and hw_entropy != @as(u64, 0xFFFFFFFFFFFFFFFF)) {
        return @truncate(hw_entropy);
    }

    if (!prng_initialized.load(.acquire)) {
        const tsc = clock.rdtsc();
        const addr_entropy = @intFromPtr(&fallback_prng_state);

        var seed: u64 = tsc;
        seed ^= addr_entropy *% 0x9E3779B97F4A7C15;
        seed ^= 0xDEADBEEFCAFEBABE;

        if (seed == 0) {
            seed = 0x853C49E6748FEA9B;
        }

        _ = fallback_prng_state.cmpxchgStrong(0, seed, .acq_rel, .acquire);
        prng_initialized.store(true, .release);
    }

    const jitter = clock.rdtsc();

    while (true) {
        const old_state = fallback_prng_state.load(.acquire);

        var x = old_state ^ jitter;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;

        if (fallback_prng_state.cmpxchgWeak(old_state, x, .acq_rel, .acquire)) |_| {
            continue;
        } else {
            return @truncate(x *% 0x2545F4914F6CDD1D);
        }
    }
}
