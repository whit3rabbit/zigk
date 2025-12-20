//! IO Uring File Descriptor Operations

const std = @import("std");
const fd = @import("fd");
const heap = @import("heap");
const uapi = @import("uapi");
const io_ring = uapi.io_ring;
const instance = @import("instance.zig");
const types = @import("types.zig");

pub const io_uring_file_ops = fd.FileOps{
    .read = null,
    .write = null,
    .close = ioUringClose,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = ioUringMmap,
    .poll = null,
};

fn ioUringClose(file_desc: *fd.FileDescriptor) isize {
    const data = getIoUringData(file_desc) orelse return 0;
    instance.freeInstance(data.instance_idx);

    // Free the fd data
    if (file_desc.private_data) |ptr| {
        const allocator = heap.getKernelAllocator();
        const data_ptr: *types.IoUringFdData = @ptrCast(@alignCast(ptr));
        allocator.destroy(data_ptr);
    }
    return 0;
}

/// mmap handler for io_uring - returns physical address of ring region
/// offset determines which ring to map:
///   IORING_OFF_SQ_RING (0x0) - SQ ring header and index array
///   IORING_OFF_CQ_RING (0x8000000) - CQ ring header and CQE array
///   IORING_OFF_SQES (0x10000000) - SQE array
fn ioUringMmap(file_desc: *fd.FileDescriptor, offset: u64, size: *usize) u64 {
    const data = getIoUringData(file_desc) orelse return 0;
    const inst = instance.getInstance(data.instance_idx) orelse return 0;

    switch (offset) {
        io_ring.IORING_OFF_SQ_RING => {
            size.* = inst.sq_ring_size;
            return inst.sq_ring_phys;
        },
        io_ring.IORING_OFF_CQ_RING => {
            size.* = inst.cq_ring_size;
            return inst.cq_ring_phys;
        },
        io_ring.IORING_OFF_SQES => {
            size.* = inst.sqes_size;
            return inst.sqes_phys;
        },
        else => return 0,
    }
}

pub fn getIoUringData(file_desc: *fd.FileDescriptor) ?*types.IoUringFdData {
    if (file_desc.ops != &io_uring_file_ops) {
        return null;
    }
    const data_ptr = file_desc.private_data orelse return null;
    return @ptrCast(@alignCast(data_ptr));
}
