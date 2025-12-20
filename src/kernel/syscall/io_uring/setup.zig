//! IO Uring Setup Syscall

const std = @import("std");
const uapi = @import("uapi");
const io_ring = uapi.io_ring;
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const base = @import("base.zig");
const heap = @import("heap");
const types = @import("types.zig");
const instance = @import("instance.zig");
const fd_mod = @import("fd.zig");

/// sys_io_uring_setup (425)
///
/// Create a new io_uring instance.
///
/// Arguments:
///   entries: Number of SQ entries (must be power of 2, 1-256)
///   params_ptr: Pointer to IoUringParams structure (in/out)
///
/// Returns: File descriptor for the io_uring on success
pub fn sys_io_uring_setup(entries: usize, params_ptr: usize) SyscallError!usize {
    // Validate entries count
    if (entries < types.MIN_RING_ENTRIES or entries > types.MAX_RING_ENTRIES) {
        return error.EINVAL;
    }

    // Must be power of 2
    const entries_u32: u32 = @intCast(entries);
    if (entries_u32 & (entries_u32 - 1) != 0) {
        return error.EINVAL;
    }

    // Validate and read params
    if (!user_mem.isValidUserAccess(params_ptr, @sizeOf(io_ring.IoUringParams), .write)) {
        return error.EFAULT;
    }

    var params: io_ring.IoUringParams = undefined;
    user_mem.copyFromUser(io_ring.IoUringParams, params_ptr) catch return error.EFAULT;

    // Check for unsupported flags
    const supported_flags = io_ring.IORING_SETUP_CQSIZE | io_ring.IORING_SETUP_CLAMP;
    if (params.flags & ~supported_flags != 0) {
        return error.EINVAL;
    }

    // Allocate instance
    const alloc_result = instance.allocInstance(entries_u32) orelse return error.ENOMEM;

    // Set up params output
    params.sq_entries = entries_u32;
    params.cq_entries = entries_u32 * 2;
    params.features = io_ring.IORING_FEAT_NODROP;

    // SQ offsets (simplified - in real Linux these point into mmap region)
    params.sq_off = .{
        .head = 0,
        .tail = 4,
        .ring_mask = 8,
        .ring_entries = 12,
        .flags = 16,
        .dropped = 20,
        .array = 24,
        ._resv1 = 0,
        ._resv2 = 0,
    };

    // CQ offsets
    params.cq_off = .{
        .head = 0,
        .tail = 4,
        .ring_mask = 8,
        .ring_entries = 12,
        .overflow = 16,
        .cqes = 20,
        .flags = 24,
        ._resv1 = 0,
        ._resv2 = 0,
    };

    // Copy params back to user
    user_mem.copyToUser(io_ring.IoUringParams, params_ptr, params) catch {
        instance.freeInstance(alloc_result.idx);
        return error.EFAULT;
    };

    // Create file descriptor
    const fd_table = base.getGlobalFdTable();

    const allocator = heap.getKernelAllocator();
    const fd_data = allocator.create(types.IoUringFdData) catch {
        instance.freeInstance(alloc_result.idx);
        return error.ENOMEM;
    };
    fd_data.instance_idx = alloc_result.idx;

    const fd_num = fd_table.allocate() orelse {
        allocator.destroy(fd_data);
        instance.freeInstance(alloc_result.idx);
        return error.EMFILE;
    };

    const fd = fd_table.get(fd_num) orelse {
        fd_table.free(fd_num);
        allocator.destroy(fd_data);
        instance.freeInstance(alloc_result.idx);
        return error.EBADF;
    };

    fd.ops = &fd_mod.io_uring_file_ops;
    fd.private_data = fd_data;
    fd.flags = 0;

    return fd_num;
}
