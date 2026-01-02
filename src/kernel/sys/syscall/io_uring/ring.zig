//! IO Uring Ring Operations
//!
//! Helper functions for manipulating SQ/CQ rings.
//! Designed to be independent of the IoUringInstance struct to avoid cycles.

const std = @import("std");
const builtin = @import("builtin");
const uapi = @import("uapi");
const io_ring = uapi.io_ring;
const types = @import("types.zig");

/// Architecture-independent release barrier (stores visible before subsequent ops)
inline fn releaseBarrier() void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("sfence" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dmb ishst" ::: .{ .memory = true }),
        else => @compileError("Unsupported architecture"),
    }
}

/// Get number of SQEs ready to submit
pub fn sqReady(ring: *volatile types.SqRingHeader) u32 {
    return ring.tail -% ring.head;
}

/// Get number of CQEs ready to consume
pub fn cqReady(ring: *volatile types.CqRingHeader) u32 {
    return ring.tail -% ring.head;
}

/// Check if CQ has space for more completions
pub fn cqHasSpace(ring: *volatile types.CqRingHeader, ring_entries: u32) bool {
    return cqReady(ring) < ring_entries;
}

/// Add a CQE to the completion queue
/// Returns true on success, false if ring is full
/// SECURITY NOTE: Unlike SQ array in submission.zig, ring.tail is kernel-controlled
/// and ring_entries is fixed at setup. The mask operation is safe because:
/// 1. ring_entries is guaranteed power-of-2 by setup validation
/// 2. Any value & (power_of_2 - 1) is always < power_of_2
pub fn addCqe(
    ring: *volatile types.CqRingHeader,
    cqes: [*]volatile io_ring.IoUringCqe,
    ring_entries: u32,
    user_data: u64,
    res: i32,
    cqe_flags: u32,
) bool {
    if (cqReady(ring) >= ring_entries) {
        return false;
    }

    // SAFE: ring.tail is kernel-controlled, mask guarantees idx < ring_entries
    const idx = ring.tail & (ring_entries - 1);

    // Write CQE to shared memory
    cqes[idx] = .{
        .user_data = user_data,
        .res = res,
        .flags = cqe_flags,
    };

    // Release barrier ensures CQE is visible before tail update
    releaseBarrier();

    ring.tail +%= 1;
    return true;
}
