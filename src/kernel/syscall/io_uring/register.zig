//! IO Uring Register Syscall

const std = @import("std");
const uapi = @import("uapi");
const io_ring = uapi.io_ring;
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const base = @import("base.zig");
const fd_mod = @import("fd.zig");

/// sys_io_uring_register (427)
///
/// Register resources with an io_uring instance.
///
/// Arguments:
///   ring_fd: File descriptor from io_uring_setup
///   opcode: Registration operation
///   arg: Operation-specific argument
///   nr_args: Number of arguments
///
/// Returns: 0 on success
pub fn sys_io_uring_register(
    ring_fd: usize,
    opcode: usize,
    arg: usize,
    nr_args: usize,
) SyscallError!usize {
    // Get fd and validate
    const fd_table = base.getGlobalFdTable();
    const fd = fd_table.get(ring_fd) orelse return error.EBADF;
    _ = fd_mod.getIoUringData(fd) orelse return error.EBADF;

    // Handle registration operations
    switch (opcode) {
        io_ring.IORING_REGISTER_PROBE => {
            return registerProbe(arg, nr_args);
        },

        // Unsupported operations return ENOSYS
        io_ring.IORING_REGISTER_BUFFERS,
        io_ring.IORING_UNREGISTER_BUFFERS,
        io_ring.IORING_REGISTER_FILES,
        io_ring.IORING_UNREGISTER_FILES,
        => {
            return error.ENOSYS;
        },

        else => {
            return error.EINVAL;
        },
    }
}

/// Handle IORING_REGISTER_PROBE - report supported operations
fn registerProbe(arg: usize, nr_ops: usize) SyscallError!usize {
    if (arg == 0) {
        return error.EFAULT;
    }

    // Validate user buffer for probe header
    if (!user_mem.isValidUserAccess(arg, @sizeOf(io_ring.IoUringProbe), .Write)) {
        return error.EFAULT;
    }

    // Supported opcodes in this implementation
    const supported_ops = [_]u8{
        io_ring.IORING_OP_NOP,
        io_ring.IORING_OP_READ,
        io_ring.IORING_OP_WRITE,
        io_ring.IORING_OP_ACCEPT,
        io_ring.IORING_OP_CONNECT,
        io_ring.IORING_OP_RECV,
        io_ring.IORING_OP_SEND,
        io_ring.IORING_OP_TIMEOUT,
        io_ring.IORING_OP_OPENAT,
        io_ring.IORING_OP_CLOSE,
        io_ring.IORING_OP_ASYNC_CANCEL,
    };

    // Find the last supported opcode
    var last_op: u8 = 0;
    for (supported_ops) |op| {
        if (op > last_op) last_op = op;
    }

    // Create probe header
    const ops_to_report = @min(nr_ops, io_ring.IORING_OP_LAST);
    const probe = io_ring.IoUringProbe{
        .last_op = last_op,
        .ops_len = @intCast(ops_to_report),
        .resv = 0,
        .resv2 = .{ 0, 0, 0 },
    };

    // Write probe header to userspace
    const user_ptr = user_mem.UserPtr.from(arg);
    user_mem.copyStructToUser(io_ring.IoUringProbe, user_ptr, probe) catch {
        return error.EFAULT;
    };

    // Write per-op probe entries if space provided
    if (nr_ops > 0) {
        const ops_ptr = arg + @sizeOf(io_ring.IoUringProbe);
        const ops_size = ops_to_report * @sizeOf(io_ring.IoUringProbeOp);

        if (!user_mem.isValidUserAccess(ops_ptr, ops_size, .Write)) {
            return error.EFAULT;
        }

        // Write each op entry
        for (0..ops_to_report) |i| {
            const op: u8 = @intCast(i);
            var op_entry = io_ring.IoUringProbeOp{
                .op = op,
                .resv = 0,
                .flags = 0,
                .resv2 = 0,
            };

            // Check if this op is supported
            for (supported_ops) |supported| {
                if (supported == op) {
                    op_entry.flags = io_ring.IO_URING_OP_SUPPORTED;
                    break;
                }
            }

            const entry_ptr = user_mem.UserPtr.from(ops_ptr + i * @sizeOf(io_ring.IoUringProbeOp));
            user_mem.copyStructToUser(io_ring.IoUringProbeOp, entry_ptr, op_entry) catch {
                return error.EFAULT;
            };
        }
    }

    return 0;
}
