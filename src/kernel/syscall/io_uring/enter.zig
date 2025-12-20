//! IO Uring Enter Syscall

const std = @import("std");
const uapi = @import("uapi");
const io_ring = uapi.io_ring;
const SyscallError = uapi.errno.SyscallError;
const base = @import("base.zig");
const fd_mod = @import("fd.zig");
const instance = @import("instance.zig");
const submission = @import("submission.zig");
const completion = @import("completion.zig");

/// sys_io_uring_enter (426)
///
/// Submit SQEs and/or wait for CQEs.
///
/// Two modes of operation:
///   1. Shared memory mode (Linux compatible): sqes_ptr=0, cqes_ptr=0
///      - Reads SQEs from mmap'd shared memory
///      - CQEs are available in mmap'd shared memory after return
///   2. Copy mode (legacy): sqes_ptr/cqes_ptr provided
///      - Copies SQEs from userspace pointer
///      - Copies CQEs to userspace pointer
///
/// Arguments:
///   ring_fd: File descriptor from io_uring_setup
///   to_submit: Number of SQEs to submit
///   min_complete: Minimum CQEs to wait for (if GETEVENTS)
///   flags: IORING_ENTER_* flags
///   sqes_ptr: Pointer to userspace SQE array (0 for shared memory mode)
///   cqes_ptr: Pointer to userspace CQE array (0 for shared memory mode)
///
/// Returns: Number of SQEs submitted (or CQEs ready if only GETEVENTS in shared mode)
pub fn sys_io_uring_enter(
    ring_fd: usize,
    to_submit: usize,
    min_complete: usize,
    flags: usize,
    sqes_ptr: usize,
    cqes_ptr: usize,
) SyscallError!usize {
    // Get fd and validate
    const fd_table = base.getGlobalFdTable();
    const fd = fd_table.get(ring_fd) orelse return error.EBADF;
    const data = fd_mod.getIoUringData(fd) orelse return error.EBADF;
    const inst = instance.getInstance(data.instance_idx) orelse return error.EBADF;

    var submitted: usize = 0;

    // Submit SQEs
    if (to_submit > 0) {
        if (sqes_ptr != 0) {
            // Legacy copy mode: copy SQEs from userspace
            submitted = try submission.copySqesAndSubmit(inst, sqes_ptr, to_submit);
        } else {
            // Shared memory mode: read SQEs from mmap'd ring
            submitted = try submission.submitFromSharedMemory(inst, to_submit);
        }
    }

    // Wait for completions if requested
    if (flags & io_ring.IORING_ENTER_GETEVENTS != 0) {
        completion.waitForCompletions(inst, @intCast(min_complete));

        if (cqes_ptr != 0 and min_complete > 0) {
            // Legacy mode: copy CQEs to userspace
            const copied = try completion.copyCompletionsToUser(inst, cqes_ptr, min_complete);
            if (to_submit == 0) {
                return copied;
            }
        } else {
            // Shared memory mode: CQEs already in shared memory
            // Return count of ready CQEs
            if (to_submit == 0) {
                return inst.cqReady();
            }
        }
    }

    return submitted;
}
