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
// Note: This implementation uses RDRAND directly for cryptographic-quality
// randomness when available. The entropy pool is always "ready" so
// GRND_NONBLOCK has no effect.

const uapi = @import("uapi");
const prng = @import("prng");
const user_mem = @import("user_mem");

const SyscallError = uapi.errno.SyscallError;

// getrandom flags (Linux ABI)
pub const GRND_NONBLOCK: u32 = 0x1;
pub const GRND_RANDOM: u32 = 0x2;

// Use consolidated user pointer validation with permission checking
const isValidUserAccess = user_mem.isValidUserAccess;
const AccessMode = user_mem.AccessMode;

/// sys_getrandom(buf: [*]u8, buflen: usize, flags: u32) -> SyscallError!usize
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
///   error.EFAULT if buf_ptr is invalid
///   error.EINVAL if buflen exceeds reasonable limit
pub fn sys_getrandom(buf_ptr: usize, buflen: usize, flags: u32) SyscallError!usize {
    // Silence unused parameter warning - flags are accepted but MVP ignores them
    _ = flags;

    // Sanity check buffer length (prevent DoS via huge allocation)
    // Linux limits to 256 bytes for GRND_RANDOM, 33554432 for GRND_NONBLOCK
    // We use a conservative 1MB limit for MVP
    const MAX_BUFLEN: usize = 1024 * 1024;
    if (buflen > MAX_BUFLEN) {
        return error.EINVAL;
    }

    // Zero-length request is valid, returns 0
    if (buflen == 0) {
        return 0;
    }

    // FR-RAND-05: Validate buffer pointer with write permission
    // (kernel writes random bytes to user buffer)
    if (!isValidUserAccess(buf_ptr, buflen, AccessMode.Write)) {
        return error.EFAULT;
    }

    // FR-RAND-02: Fill buffer with random data from hardware entropy (RDRAND)
    // Use safe copy: generate in kernel buffer, then copy to user
    // For small buffers use stack, for larger use chunked approach
    const STACK_BUF_SIZE: usize = 256;
    var stack_buf: [STACK_BUF_SIZE]u8 = undefined;

    const uptr = user_mem.UserPtr.from(buf_ptr);
    var remaining = buflen;
    var offset: usize = 0;

    while (remaining > 0) {
        const chunk_size = @min(remaining, STACK_BUF_SIZE);
        prng.fillFromHardwareEntropy(stack_buf[0..chunk_size]);

        _ = uptr.offset(offset).copyFromKernel(stack_buf[0..chunk_size]) catch {
            return error.EFAULT;
        };

        offset += chunk_size;
        remaining -= chunk_size;
    }

    return buflen;
}
