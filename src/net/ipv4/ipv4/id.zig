const std = @import("std");
const platform = @import("../../platform.zig");
const clock = @import("../../clock.zig");
const entropy = platform.entropy;

/// Fallback PRNG state for when hardware entropy is unavailable
var fallback_prng_state: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var prng_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Get next IP identification value
pub fn getNextId() u16 {
    return @truncate(entropy.getRandomU64());
}
