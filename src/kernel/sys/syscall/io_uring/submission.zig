//! IO Uring Submission Handling

const std = @import("std");
const builtin = @import("builtin");
const uapi = @import("uapi");
const io_ring = uapi.io_ring;
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const instance = @import("instance.zig");
const ops = @import("ops.zig");

/// Architecture-independent acquire barrier
inline fn acquireBarrier() void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("lfence" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dmb ishld" ::: .{ .memory = true }),
        else => @compileError("Unsupported architecture"),
    }
}

/// Submit SQEs from shared memory ring
pub fn submitFromSharedMemory(inst: *instance.IoUringInstance, to_submit: usize) SyscallError!usize {
    const sq_ring = inst.getSqRing();
    const sq_array = inst.getSqArray();
    const sqes = inst.getSqes();

    // Memory barrier before reading indices
    acquireBarrier();

    var submitted: usize = 0;
    var head = sq_ring.head;
    const tail = sq_ring.tail;

    while (submitted < to_submit and head != tail) {
        const idx = head & (inst.sq_ring_entries - 1);

        // SQ array contains indices into SQE array
        const sqe_idx = sq_array[idx] & (inst.sq_ring_entries - 1);

        // SECURITY: Explicit bounds check even after masking.
        // Malicious userspace could craft indices that bypass mask if ring size changes.
        if (sqe_idx >= inst.sq_ring_entries) {
            _ = inst.addCqe(0, -@as(i32, 22), 0); // EINVAL
            submitted += 1;
            head +%= 1;
            continue;
        }

        const volatile_sqe = &sqes[sqe_idx];

        // SECURITY: Copy SQE from shared memory to prevent TOCTOU attacks.
        // Userspace could modify the SQE while we're processing it.
        var sqe: io_ring.IoUringSqe = undefined;
        @memcpy(std.mem.asBytes(&sqe), std.mem.asBytes(volatile_sqe));

        // Process the SQE (now in kernel memory)
        const result = ops.processSqe(inst, &sqe);
        if (result) |_| {
            submitted += 1;
        } else |_| {
            // On error, generate immediate CQE with EINVAL
            _ = inst.addCqe(sqe.user_data, -@as(i32, 22), 0);
            submitted += 1;
        }

        head +%= 1;
    }

    // Update SQ head (kernel consumed these entries)
    sq_ring.head = head;

    // Memory barrier after updating head
    asm volatile ("sfence" ::: .{ .memory = true });

    return submitted;
}

/// Copy SQEs from userspace and process them.
/// This is the key fix for the copy-based ring model - SQEs MUST be copied from
/// userspace before processing.
pub fn copySqesAndSubmit(inst: *instance.IoUringInstance, sqes_ptr: usize, count: usize) SyscallError!usize {
    if (sqes_ptr == 0) {
        return error.EFAULT;
    }

    // SECURITY NOTE: copy_count is bounded by sq_ring_entries which is <= MAX_RING_ENTRIES (256).
    // sqe_size is 64 bytes, so copy_count * sqe_size <= 256 * 64 = 16KB.
    // This multiplication cannot overflow. Additionally, isValidUserAccess internally uses
    // @addWithOverflow to safely detect ptr+len overflow.
    const copy_count = @min(count, inst.sq_ring_entries);
    const sqe_size = @sizeOf(io_ring.IoUringSqe);

    // Validate entire user buffer
    if (!user_mem.isValidUserAccess(sqes_ptr, copy_count * sqe_size, .Read)) {
        return error.EFAULT;
    }

    var submitted: usize = 0;

    // Copy and process each SQE
    for (0..copy_count) |i| {
        const src_addr = sqes_ptr + i * sqe_size;
        const user_ptr = user_mem.UserPtr.from(src_addr);

        // Copy SQE from userspace
        const sqe = user_mem.copyStructFromUser(io_ring.IoUringSqe, user_ptr) catch {
            return error.EFAULT;
        };

        // Process the SQE
        const result = ops.processSqe(inst, &sqe);
        if (result) |_| {
            submitted += 1;
        } else |_| {
            // On error, generate immediate CQE with EINVAL
            _ = inst.addCqe(sqe.user_data, -@as(i32, 22), 0);
            submitted += 1;
        }
    }

    return submitted;
}
