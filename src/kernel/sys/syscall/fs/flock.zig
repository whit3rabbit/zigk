// flock(2) Syscall Handler
//
// Implements POSIX advisory file locking.
//
// Operations:
// - LOCK_SH: Acquire shared lock (multiple readers allowed)
// - LOCK_EX: Acquire exclusive lock (single writer, no readers)
// - LOCK_UN: Release lock
// - LOCK_NB: Non-blocking mode (combined with LOCK_SH or LOCK_EX)
//
// SECURITY:
// - Validates FD and lock operation
// - Bounded lock table (256 max) prevents DoS
// - Advisory locks only (not enforced by read/write)
// - Lock released automatically on close

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const fd_mod = @import("fd");
const flock_mod = @import("flock");

const SyscallError = base.SyscallError;

/// sys_flock (73) - Apply or remove an advisory lock on an open file
///
/// Args:
///   fd: File descriptor
///   operation: Lock operation (LOCK_SH, LOCK_EX, LOCK_UN, optionally | LOCK_NB)
///
/// Returns:
///   0 on success
///   -EBADF if fd is invalid
///   -EINVAL if operation is invalid
///   -ENOLCK if lock table is full
///   -EWOULDBLOCK if LOCK_NB and lock conflicts
///
/// Examples:
///   flock(fd, LOCK_SH);              // Acquire shared lock (blocking)
///   flock(fd, LOCK_EX | LOCK_NB);    // Try exclusive lock (non-blocking)
///   flock(fd, LOCK_UN);              // Release lock
pub fn sys_flock(fd_num: usize, operation: usize) SyscallError!usize {
    // Get file descriptor
    const fd_table = base.getGlobalFdTable();
    const fd_u32: u32 = std.math.cast(u32, fd_num) orelse return error.EBADF;
    const fd_ptr = fd_table.get(fd_u32) orelse return error.EBADF;

    // Check if file has identifier (0 means no flock support)
    if (fd_ptr.file_identifier == 0) {
        return error.EINVAL; // Can't lock pipes, sockets, etc.
    }

    // Extract operation flags
    const op_u32: u32 = @truncate(operation);
    const nonblock = (op_u32 & uapi.flock.LOCK_NB) != 0;
    const lock_type = op_u32 & uapi.flock.LOCK_MASK;

    // Get current process PID
    const proc = base.getCurrentProcess();
    const owner_pid = proc.pid;

    // Validate and execute operation
    switch (lock_type) {
        uapi.flock.LOCK_SH => {
            // Acquire shared lock
            try flock_mod.acquire(
                fd_ptr.file_identifier,
                uapi.flock.LOCK_SH,
                owner_pid,
                nonblock,
            );
            return 0;
        },
        uapi.flock.LOCK_EX => {
            // Acquire exclusive lock
            try flock_mod.acquire(
                fd_ptr.file_identifier,
                uapi.flock.LOCK_EX,
                owner_pid,
                nonblock,
            );
            return 0;
        },
        uapi.flock.LOCK_UN => {
            // Release lock
            flock_mod.release(fd_ptr.file_identifier, owner_pid);
            return 0;
        },
        else => {
            // Invalid operation
            return error.EINVAL;
        },
    }
}
