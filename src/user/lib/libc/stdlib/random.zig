// Random number generation (stdlib.h)
//
// Simple LCG-based random number generator.

/// Random number generator state
var rand_seed: c_uint = 1;

/// Generate random number in range [0, RAND_MAX]
pub export fn rand() c_int {
    // LCG parameters from glibc
    rand_seed = rand_seed *% 1103515245 +% 12345;
    return @bitCast(@as(c_uint, (rand_seed >> 16) & 0x7fff));
}

/// Seed the random number generator
pub export fn srand(seed: c_uint) void {
    rand_seed = seed;
}

/// Maximum value returned by rand()
pub const RAND_MAX: c_int = 0x7fff;

/// Generate random bytes (uses kernel getrandom if available)
pub fn getRandomBytes(buf: [*]u8, len: usize) bool {
    const syscall = @import("syscall.zig");

    // Try kernel getrandom syscall
    _ = syscall.getrandom(buf, len, 0) catch {
        // Fall back to rand() if syscall not available
        var i: usize = 0;
        while (i < len) : (i += 1) {
            buf[i] = @truncate(@as(c_uint, @bitCast(rand())));
        }
        return true;
    };
    return true;
}

/// POSIX random() - returns larger range than rand()
pub export fn random() c_long {
    // Use two rand() calls for more bits
    const high: c_long = @as(c_long, rand()) << 15;
    const low: c_long = @as(c_long, rand());
    return high | low;
}

/// POSIX srandom()
pub export fn srandom(seed: c_uint) void {
    srand(seed);
}
