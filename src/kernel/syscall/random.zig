// sys_getrandom Syscall Implementation
//
// Linux syscall 318: Get random bytes from kernel entropy pool.
// Spec Reference: Spec 007 FR-RAND-01 through FR-RAND-08
//
// Signature: ssize_t getrandom(void *buf, size_t buflen, unsigned int flags)
//
// Flags:
//   GRND_NONBLOCK (0x1): Return -EAGAIN if entropy pool not ready
//   GRND_RANDOM   (0x2): Use /dev/random (more conservative, blocks longer)
//
// Returns: Number of bytes written, or negative errno
//
// Note: This MVP implementation uses a PRNG seeded from RDRAND/RDTSC.
// The entropy pool is always "ready" so GRND_NONBLOCK has no effect.
// For cryptographic needs, use RDRAND directly via hal.entropy.

const uapi = @import("uapi");
const prng = @import("prng");

// getrandom flags (Linux ABI)
pub const GRND_NONBLOCK: u32 = 0x1;
pub const GRND_RANDOM: u32 = 0x2;

// User pointer validation (duplicated from handlers.zig due to module constraints)
const USER_SPACE_START: u64 = 0x0000_0000_0040_0000;
const USER_SPACE_END: u64 = 0x0000_7FFF_FFFF_FFFF;

fn isValidUserPtr(ptr: usize, len: usize) bool {
    if (ptr == 0) return false;
    if (ptr < USER_SPACE_START or ptr > USER_SPACE_END) return false;
    const end_addr = @addWithOverflow(ptr, len);
    if (end_addr[1] != 0) return false;
    if (end_addr[0] > USER_SPACE_END) return false;
    return true;
}

/// sys_getrandom(buf: [*]u8, buflen: usize, flags: u32) -> isize
///
/// Fill buffer with random bytes from kernel PRNG.
///
/// Arguments:
///   buf_ptr - Userspace buffer address
///   buflen  - Number of bytes to generate
///   flags   - GRND_NONBLOCK, GRND_RANDOM (both ignored in MVP)
///
/// Returns:
///   Number of bytes written on success
///   -EFAULT if buf_ptr is null
///   -EINVAL if buflen exceeds reasonable limit
pub fn sys_getrandom(buf_ptr: usize, buflen: usize, flags: u32) isize {
    // Silence unused parameter warning - flags are accepted but MVP ignores them
    _ = flags;

    // Sanity check buffer length (prevent DoS via huge allocation)
    // Linux limits to 256 bytes for GRND_RANDOM, 33554432 for GRND_NONBLOCK
    // We use a conservative 1MB limit for MVP
    const MAX_BUFLEN: usize = 1024 * 1024;
    if (buflen > MAX_BUFLEN) {
        return uapi.errno.EINVAL.toReturn();
    }

    // Zero-length request is valid, returns 0
    if (buflen == 0) {
        return 0;
    }

    // FR-RAND-05: Validate buffer pointer is in userspace
    if (!isValidUserPtr(buf_ptr, buflen)) {
        return uapi.errno.EFAULT.toReturn();
    }

    // FR-RAND-02: Fill buffer with random data from PRNG
    const buf: [*]u8 = @ptrFromInt(buf_ptr);
    prng.fill(buf[0..buflen]);

    return @intCast(buflen);
}
