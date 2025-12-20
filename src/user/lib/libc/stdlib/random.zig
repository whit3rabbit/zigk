// Random number generation (stdlib.h)
//
// Simple LCG-based random number generator.
// SECURITY: rand_seed is threadlocal to prevent data races in multi-threaded
// userspace programs. Each thread gets independent PRNG state.

/// Random number generator state (per-thread to avoid data races)
threadlocal var rand_seed: c_uint = 1;

/// Generate random number in range [0, RAND_MAX]
/// SECURITY WARNING: This is NOT cryptographically secure. Uses a simple
/// Linear Congruential Generator (LCG) that is trivially predictable.
/// DO NOT use for: session tokens, passwords, cryptographic keys, nonces.
/// Use getRandomBytes() for security-sensitive applications.
pub export fn rand() c_int {
    // LCG parameters from glibc - fast but predictable
    rand_seed = rand_seed *% 1103515245 +% 12345;
    return @bitCast(@as(c_uint, (rand_seed >> 16) & 0x7fff));
}

/// Seed the random number generator
pub export fn srand(seed: c_uint) void {
    rand_seed = seed;
}

/// Maximum value returned by rand()
pub const RAND_MAX: c_int = 0x7fff;

/// Generate cryptographically secure random bytes via kernel getrandom
/// SECURITY: Returns false if kernel getrandom fails - never falls back to weak PRNG
/// Callers MUST check the return value and handle failure appropriately
pub fn getRandomBytes(buf: [*]u8, len: usize) bool {
    const syscall = @import("syscall");

    var offset: usize = 0;

    // Use kernel getrandom syscall for cryptographic randomness
    while (offset < len) {
        const read = syscall.getrandom(buf + offset, len - offset, 0) catch {
            // SECURITY: Do NOT fall back to weak PRNG - that would silently
            // downgrade security guarantees. Caller must handle failure.
            return false;
        };
        
        if (read == 0) {
             // Should not happen for getrandom unless blocked/interrupted indefinitely
             return false; 
        }
        
        offset += read;
    }
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
