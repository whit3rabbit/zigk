//! IO Uring Request Processing

const std = @import("std");
const io = @import("io");
const sched = @import("sched");
const instance = @import("instance.zig");

/// Process pending requests and generate CQEs for completed ones
pub fn processPendingRequests(inst: *instance.IoUringInstance) u32 {
    var completed: u32 = 0;
    var i: u32 = 0;

    while (i < inst.pending_count) {
        const req = inst.pending_requests[i];
        const state = req.getState();

        if (state == .completed or state == .cancelled) {
            instance.IoUringInstance.finalizeBounceBuffer(req);

            // Generate CQE
            const res: i32 = switch (req.result) {
                .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
                .err => @intCast(req.result.toSyscallReturn()),
                .cancelled => -@as(i32, 125), // ECANCELED
                .pending => 0,
            };

            if (inst.addCqe(req.user_data, res, 0)) {
                completed += 1;
            }

            // Free the request
            io.freeRequest(req);

            // Remove from pending list (swap with last)
            inst.pending_count -= 1;
            if (i < inst.pending_count) {
                inst.pending_requests[i] = inst.pending_requests[inst.pending_count];
            }
            // Don't increment i - we swapped in a new element
        } else {
            i += 1;
        }
    }

    // Wake waiting thread if we have enough completions
    if (completed > 0) {
        if (inst.waiting_thread) |thread| {
            if (inst.cqReady() >= inst.min_complete) {
                sched.unblock(thread);
            }
        }
    }

    return completed;
}
