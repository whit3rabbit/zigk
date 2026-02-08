// Process Control Syscall Handlers
//
// Implements process control syscalls:
// - sys_prctl: Process control operations (PR_SET_NAME, PR_GET_NAME)
// - sys_sched_setaffinity: Set CPU affinity mask
// - sys_sched_getaffinity: Get CPU affinity mask

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const sched = @import("sched");
const user_mem = @import("user_mem");
const process_mod = @import("process");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;

// =============================================================================
// Process Control (prctl)
// =============================================================================

/// sys_prctl (157 on x86_64, 167 on aarch64) - Process control operations
///
/// Handles thread/process attribute manipulation.
/// Currently supports:
/// - PR_SET_NAME: Set thread name (arg2 = name pointer, truncated to 15 chars + null)
/// - PR_GET_NAME: Get thread name (arg2 = buffer pointer, copies 16 bytes)
///
/// Returns: 0 on success, error on failure
pub fn sys_prctl(option: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) SyscallError!usize {
    _ = arg3;
    _ = arg4;
    _ = arg5;

    const thread = sched.getCurrentThread() orelse return error.ESRCH;

    switch (option) {
        uapi.prctl.PR_SET_NAME => {
            // arg2 is pointer to name string in userspace
            if (arg2 == 0) return error.EFAULT;

            // Copy name from userspace (Linux: 16 bytes including null terminator)
            var kernel_buf: [16]u8 = undefined;
            const copied = user_mem.copyStringFromUser(&kernel_buf, arg2) catch return error.EFAULT;

            // Truncate to 15 chars + null (Linux semantics)
            const copy_len = @min(copied.len, 15);

            // Copy into thread.name and ensure null termination
            @memcpy(thread.name[0..copy_len], kernel_buf[0..copy_len]);
            thread.name[copy_len] = 0;

            // Zero remaining bytes for clean reads
            if (copy_len + 1 < thread.name.len) {
                @memset(thread.name[copy_len + 1 ..], 0);
            }

            return 0;
        },

        uapi.prctl.PR_GET_NAME => {
            // arg2 is pointer to buffer in userspace (must be at least 16 bytes)
            if (arg2 == 0) return error.EFAULT;

            // Copy 16 bytes to userspace (includes null terminator)
            const uptr = UserPtr.from(arg2);
            _ = uptr.copyFromKernel(thread.name[0..16]) catch return error.EFAULT;

            return 0;
        },

        else => return error.EINVAL,
    }
}

// =============================================================================
// CPU Affinity
// =============================================================================

/// sys_sched_setaffinity (203 on x86_64, 122 on aarch64) - Set CPU affinity mask
///
/// In a single-CPU kernel, this validates that CPU 0 is in the mask.
/// Multi-CPU support would store the mask in the process/thread structure.
///
/// Args:
/// - pid: Target process ID (0 = current process)
/// - cpusetsize: Size of the cpu_set_t mask (must be >= 8 for u64)
/// - mask: Pointer to CPU bitmask in userspace
///
/// Returns: 0 on success
pub fn sys_sched_setaffinity(pid: usize, cpusetsize: usize, mask_ptr: usize) SyscallError!usize {
    // Validate mask size (minimum 8 bytes for a u64)
    if (cpusetsize < 8) return error.EINVAL;

    // Resolve target process
    const target_proc = if (pid == 0)
        base.getCurrentProcess()
    else
        process_mod.findProcessByPid(@intCast(pid)) orelse return error.ESRCH;

    _ = target_proc; // Will be used when storing affinity state

    // Read first u64 from user mask
    const uptr = UserPtr.from(mask_ptr);
    const mask = uptr.readValue(u64) catch return error.EFAULT;

    // Validate that CPU 0 is set (single-CPU kernel requirement)
    if ((mask & 1) == 0) return error.EINVAL;

    // Single-CPU kernel: no state to store, just validate and succeed
    // TODO: Store affinity mask in Process struct for multi-CPU support

    return 0;
}

/// sys_sched_getaffinity (204 on x86_64, 123 on aarch64) - Get CPU affinity mask
///
/// Returns the CPU affinity mask for a process. In a single-CPU kernel,
/// this always returns a mask with only CPU 0 set.
///
/// Args:
/// - pid: Target process ID (0 = current process)
/// - cpusetsize: Size of the cpu_set_t mask buffer
/// - mask: Pointer to buffer in userspace
///
/// Returns: Size of the kernel's cpuset (number of bytes copied)
pub fn sys_sched_getaffinity(pid: usize, cpusetsize: usize, mask_ptr: usize) SyscallError!usize {
    // Validate mask size
    if (cpusetsize < 8) return error.EINVAL;

    // Resolve target process
    const target_proc = if (pid == 0)
        base.getCurrentProcess()
    else
        process_mod.findProcessByPid(@intCast(pid)) orelse return error.ESRCH;

    _ = target_proc; // Will be used when reading affinity state

    // Build 128-byte zero buffer (enough for 1024 CPUs)
    var mask_buf: [128]u8 = [_]u8{0} ** 128;
    mask_buf[0] = 1; // Set CPU 0 bit

    // Copy min(cpusetsize, 128) bytes to userspace
    const copy_size = @min(cpusetsize, 128);
    const uptr = UserPtr.from(mask_ptr);
    _ = uptr.copyFromKernel(mask_buf[0..copy_size]) catch return error.EFAULT;

    // Return the size we copied (Linux returns kernel's cpuset size)
    return copy_size;
}
