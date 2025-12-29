// sys_getrandom Syscall Implementation
//
// Linux syscall 318: Get random bytes from kernel entropy pool.
// Spec Reference: Spec 007 FR-RAND-01 through FR-RAND-08
//
// Signature: ssize_t getrandom(void *buf, size_t buflen, unsigned int flags)
//
// Flags:
//   GRND_NONBLOCK (0x1): Return -EAGAIN if entropy pool not ready
//   GRND_RANDOM   (0x2): Use /dev/random (prefer RDSEED over RDRAND)
//
// Returns: Number of bytes written, or negative errno
//
// SECURITY: This implementation properly respects GRND_NONBLOCK to return
// EAGAIN when entropy is not available, rather than silently falling back
// to weak entropy sources.

const uapi = @import("uapi");
const prng = @import("prng");
const user_mem = @import("user_mem");

const SyscallError = uapi.errno.SyscallError;

// getrandom flags (Linux ABI)
pub const GRND_NONBLOCK: u32 = 0x1;
pub const GRND_RANDOM: u32 = 0x2;
pub const GRND_INSECURE: u32 = 0x4; // Linux 5.6+: don't block, may be weak

// Use consolidated user pointer validation with permission checking
const isValidUserAccess = user_mem.isValidUserAccess;
const AccessMode = user_mem.AccessMode;

/// Check if the entropy pool is ready (has sufficient entropy)
/// SECURITY: Returns false if we're using weak fallback entropy
fn isEntropyPoolReady() bool {
    // Check if PRNG is initialized and not using weak fallback
    if (!prng.isInitialized()) return false;

    // Check security level - only accept secure or degraded
    const level = prng.getSecurityLevel();
    return level == .secure or level == .degraded;
}

/// sys_getrandom(buf: [*]u8, buflen: usize, flags: u32) -> SyscallError!usize
///
/// Fill buffer with random bytes from kernel entropy sources.
///
/// Arguments:
///   buf_ptr - Userspace buffer address
///   buflen  - Number of bytes to generate
///   flags   - GRND_NONBLOCK (return EAGAIN if not ready),
///             GRND_RANDOM (prefer hardware entropy),
///             GRND_INSECURE (allow weak entropy, don't block)
///
/// Returns:
///   Number of bytes written on success
///   error.EFAULT if buf_ptr is invalid
///   error.EINVAL if buflen exceeds reasonable limit or invalid flags
///   error.EAGAIN if GRND_NONBLOCK and entropy not ready
pub fn sys_getrandom(buf_ptr: usize, buflen: usize, flags: u32) SyscallError!usize {
    // Validate flags - reject unknown flags
    const valid_flags = GRND_NONBLOCK | GRND_RANDOM | GRND_INSECURE;
    if ((flags & ~valid_flags) != 0) {
        return error.EINVAL;
    }

    // GRND_RANDOM and GRND_INSECURE are mutually exclusive
    if ((flags & GRND_RANDOM) != 0 and (flags & GRND_INSECURE) != 0) {
        return error.EINVAL;
    }

    // Sanity check buffer length (prevent DoS via huge allocation)
    // Linux limits to 256 bytes for GRND_RANDOM, 33554432 for urandom
    const MAX_BUFLEN: usize = if ((flags & GRND_RANDOM) != 0) 256 else 1024 * 1024;
    if (buflen > MAX_BUFLEN) {
        return error.EINVAL;
    }

    // Zero-length request is valid, returns 0
    if (buflen == 0) {
        return 0;
    }

    // SECURITY: Handle GRND_NONBLOCK - return EAGAIN if entropy not ready
    // This prevents applications from unknowingly using weak entropy
    if ((flags & GRND_NONBLOCK) != 0 and (flags & GRND_INSECURE) == 0) {
        if (!isEntropyPoolReady()) {
            return error.EAGAIN;
        }
    }

    // FR-RAND-05: Validate buffer pointer with write permission
    if (!isValidUserAccess(buf_ptr, buflen, AccessMode.Write)) {
        return error.EFAULT;
    }

    // FR-RAND-02: Fill buffer with random data
    const STACK_BUF_SIZE: usize = 256;
    // SECURITY NOTE: Buffer is intentionally undefined here because:
    // 1. fillFromHardwareEntropy() fully overwrites the entire slice before any copy to user
    // 2. tryFillFromHardwareEntropy() returns false on failure, triggering early return BEFORE copy
    // 3. No code path copies uninitialized data to userspace
    // The defer @memset is for stack hygiene only (prevents entropy leakage to future stack frames)
    var stack_buf: [STACK_BUF_SIZE]u8 = undefined;
    defer @memset(&stack_buf, 0);

    const uptr = user_mem.UserPtr.from(buf_ptr);
    var remaining = buflen;
    var offset: usize = 0;

    // GRND_RANDOM: Try to use only hardware entropy (RDSEED/RDRAND)
    // GRND_INSECURE: Use whatever is available, even weak sources
    // Default: Use hardware entropy with CSPRNG fallback
    const require_hardware = (flags & GRND_RANDOM) != 0;
    const allow_weak = (flags & GRND_INSECURE) != 0;

    while (remaining > 0) {
        const chunk_size = @min(remaining, STACK_BUF_SIZE);

        if (require_hardware) {
            // GRND_RANDOM: Only accept hardware entropy
            if (!prng.tryFillFromHardwareEntropy(stack_buf[0..chunk_size])) {
                // Hardware entropy exhausted - return partial or EAGAIN
                if (offset > 0) {
                    return offset; // Return what we got
                }
                return error.EAGAIN;
            }
        } else if (allow_weak) {
            // GRND_INSECURE: Use any available source
            prng.fillFromHardwareEntropy(stack_buf[0..chunk_size]);
        } else {
            // Default: Use hardware entropy with CSPRNG fallback
            // SECURITY FIX: Must check entropy quality before proceeding
            // Per NIST SP 800-90B, cryptographic randomness requires verified entropy
            if (!isEntropyPoolReady()) {
                // Return partial data if we got some, otherwise EAGAIN
                // This prevents silent downgrade to weak entropy
                if (offset > 0) {
                    return offset;
                }
                // SECURITY: Do NOT silently provide weak entropy
                // Applications expect cryptographic quality from getrandom()
                // Return EAGAIN so they can retry or handle appropriately
                return error.EAGAIN;
            }
            prng.fillFromHardwareEntropy(stack_buf[0..chunk_size]);
        }

        _ = uptr.offset(offset).copyFromKernel(stack_buf[0..chunk_size]) catch {
            return error.EFAULT;
        };

        offset += chunk_size;
        remaining -= chunk_size;
    }

    return buflen;
}
