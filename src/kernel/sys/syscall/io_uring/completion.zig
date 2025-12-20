//! IO Uring Completion Handling

const std = @import("std");
const sched = @import("sched");
const hal = @import("hal");
const uapi = @import("uapi");
const io_ring = uapi.io_ring;
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const instance = @import("instance.zig");
const types = @import("types.zig");
const request = @import("request.zig");

pub fn waitForCompletions(inst: *instance.IoUringInstance, min_complete: u32) void {
    // Process any already-completed requests
    _ = request.processPendingRequests(inst);

    // If we have enough completions, return immediately
    if (inst.cqReady() >= min_complete) {
        return;
    }

    // Need to wait for more completions using proper blocking
    // Get current thread for wakeup registration
    const current_thread = sched.getCurrentThread() orelse {
        // No current thread context - fall back to limited spinning
        var spins: u32 = 0;
        while (inst.cqReady() < min_complete and spins < 1000) : (spins += 1) {
            _ = request.processPendingRequests(inst);
            hal.cpu.pause();
        }
        return;
    };

    // Register ourselves for wakeup when completions arrive
    inst.waiting_thread = current_thread;
    inst.min_complete = min_complete;

    // Block until we have enough completions
    // The completion path (processPendingRequests or IRQ handler) will wake us
    while (inst.cqReady() < min_complete) {
        // Double-check before blocking (race condition avoidance)
        _ = request.processPendingRequests(inst);
        if (inst.cqReady() >= min_complete) {
            break;
        }

        // Block the thread - scheduler will context switch
        // We will be woken by sched.unblock() when completions arrive
        sched.block();

        // After wakeup, process any newly completed requests
        _ = request.processPendingRequests(inst);
    }

    // Clear the waiting state
    inst.waiting_thread = null;
    inst.min_complete = 0;
}

/// Copy CQEs to userspace after completions.
/// This is the key fix - CQEs MUST be copied back to userspace for the user to read them.
pub fn copyCompletionsToUser(inst: *instance.IoUringInstance, cqes_ptr: usize, max_cqes: usize) SyscallError!usize {
    if (cqes_ptr == 0) {
        return 0;
    }

    const ready = inst.cqReady();
    const copy_count = @min(ready, max_cqes);
    const cqe_size = @sizeOf(io_ring.IoUringCqe);

    if (copy_count == 0) {
        return 0;
    }

    // Validate entire user buffer
    if (!user_mem.isValidUserAccess(cqes_ptr, copy_count * cqe_size, .Write)) {
        return error.EFAULT;
    }

    // Access CQ via shared memory getters (not non-existent instance fields)
    const cq_ring = inst.getCqRing();
    const cqes = inst.getCqes();

    // Copy each CQE to userspace
    for (0..copy_count) |i| {
        const idx = cq_ring.head & (inst.cq_ring_entries - 1);
        const cqe = cqes[idx];
        const dest_addr = cqes_ptr + i * cqe_size;
        const user_ptr = user_mem.UserPtr.from(dest_addr);

        user_mem.copyStructToUser(io_ring.IoUringCqe, user_ptr, cqe) catch {
            return error.EFAULT;
        };

        cq_ring.head +%= 1;
    }

    return copy_count;
}
