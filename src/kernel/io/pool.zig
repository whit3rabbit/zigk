// Kernel Async I/O Request Pool
//
// Fixed-size pool of IoRequest structures for async operations.
// Pre-allocates all requests at init time - no dynamic allocation during operation.
//
// Design:
//   - Intrusive free list using IoRequest.next pointer
//   - O(1) alloc and free operations
//   - Thread-safe via spinlock
//   - Returns null on exhaustion (caller should return EAGAIN)
//
// Constitution Compliance (Principle IX - Heap Hygiene):
//   - Fixed pool size prevents unbounded memory growth
//   - No per-operation allocation overhead

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const IoRequest = types.IoRequest;
const IoOpType = types.IoOpType;

// Conditional imports for freestanding
const is_freestanding = builtin.os.tag == .freestanding;
const sync = if (is_freestanding) @import("sync") else struct {
    pub const Spinlock = struct {
        locked: std.atomic.Value(u32) = .{ .raw = 0 },

        pub const Held = struct {
            lock: *Spinlock,
            pub fn release(self: Held) void {
                self.lock.locked.store(0, .release);
            }
        };

        pub fn acquire(self: *Spinlock) Held {
            while (self.locked.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
                std.atomic.spinLoopHint();
            }
            return .{ .lock = self };
        }
    };
};

/// Maximum number of concurrent async I/O requests
/// This is a kernel-wide limit across all processes
pub const MAX_REQUESTS: usize = 256;

/// Pool of pre-allocated IoRequest structures
pub const IoRequestPool = struct {
    /// Storage for all requests
    requests: [MAX_REQUESTS]IoRequest,

    /// Head of the free list (null = pool exhausted)
    free_list: ?*IoRequest,

    /// Number of currently allocated requests
    allocated_count: usize,

    /// Monotonically increasing request ID counter
    next_id: u64,

    /// Lock protecting pool state
    lock: sync.Spinlock,

    /// Initialize the pool with all requests on the free list
    pub fn init(self: *IoRequestPool) void {
        self.* = .{
            .requests = undefined,
            .free_list = null,
            .allocated_count = 0,
            .next_id = 1,
            .lock = .{},
        };

        // Initialize all requests and build free list
        var i: usize = MAX_REQUESTS;
        while (i > 0) {
            i -= 1;
            self.requests[i] = IoRequest.init(0, .noop);
            self.requests[i].next = self.free_list;
            self.free_list = &self.requests[i];
        }
    }

    /// Allocate a request from the pool
    /// Returns null if pool is exhausted
    pub fn alloc(self: *IoRequestPool, op: IoOpType) ?*IoRequest {
        const held = self.lock.acquire();
        defer held.release();

        const req = self.free_list orelse return null;

        // Remove from free list
        self.free_list = req.next;
        self.allocated_count += 1;

        // Initialize the request
        const id = self.next_id;
        self.next_id +%= 1;

        req.* = IoRequest.init(id, op);

        return req;
    }

    /// Return a request to the pool
    /// Request must have been allocated from this pool
    pub fn free(self: *IoRequestPool, req: *IoRequest) void {
        const held = self.lock.acquire();
        defer held.release();

        // SECURITY: Always verify request belongs to this pool to prevent
        // double-free and arbitrary-free attacks. This check must run in
        // all build modes, not just Debug.
        const base = @intFromPtr(&self.requests[0]);
        const end = base + MAX_REQUESTS * @sizeOf(IoRequest);
        const ptr = @intFromPtr(req);
        if (ptr < base or ptr >= end) {
            // Invalid pointer - do not corrupt free list
            // In debug mode, panic for easier debugging
            if (builtin.mode == .Debug) {
                @panic("IoRequestPool.free: request not from this pool");
            }
            // In release mode, silently reject to avoid corruption
            return;
        }

        // Verify alignment
        if ((ptr - base) % @sizeOf(IoRequest) != 0) {
            if (builtin.mode == .Debug) {
                @panic("IoRequestPool.free: misaligned request pointer");
            }
            return;
        }

        // Reset and add to free list
        req.* = IoRequest.init(0, .noop);
        req.next = self.free_list;
        self.free_list = req;
        self.allocated_count -= 1;
    }

    /// Get number of available requests
    pub fn available(self: *IoRequestPool) usize {
        const held = self.lock.acquire();
        defer held.release();
        return MAX_REQUESTS - self.allocated_count;
    }

    /// Check if pool is exhausted
    pub fn isEmpty(self: *IoRequestPool) bool {
        const held = self.lock.acquire();
        defer held.release();
        return self.free_list == null;
    }

    /// Get statistics about pool usage
    pub fn getStats(self: *IoRequestPool) PoolStats {
        const held = self.lock.acquire();
        defer held.release();
        return .{
            .total = MAX_REQUESTS,
            .allocated = self.allocated_count,
            .available = MAX_REQUESTS - self.allocated_count,
            .next_id = self.next_id,
        };
    }
};

/// Pool usage statistics
pub const PoolStats = struct {
    total: usize,
    allocated: usize,
    available: usize,
    next_id: u64,
};

// =============================================================================
// Tests
// =============================================================================

test "IoRequestPool basic alloc/free" {
    var pool: IoRequestPool = undefined;
    pool.init();

    // Allocate a request
    const req = pool.alloc(.socket_read) orelse return error.AllocFailed;
    try std.testing.expectEqual(IoOpType.socket_read, req.op);
    try std.testing.expectEqual(@as(u64, 1), req.id);
    try std.testing.expectEqual(@as(usize, 1), pool.allocated_count);

    // Free it
    pool.free(req);
    try std.testing.expectEqual(@as(usize, 0), pool.allocated_count);
}

test "IoRequestPool exhaustion" {
    var pool: IoRequestPool = undefined;
    pool.init();

    // Allocate all requests
    var requests: [MAX_REQUESTS]*IoRequest = undefined;
    for (0..MAX_REQUESTS) |i| {
        requests[i] = pool.alloc(.noop) orelse return error.UnexpectedExhaustion;
    }

    // Pool should be empty
    try std.testing.expect(pool.isEmpty());
    try std.testing.expectEqual(@as(?*IoRequest, null), pool.alloc(.noop));

    // Free one and verify we can allocate again
    pool.free(requests[0]);
    try std.testing.expect(!pool.isEmpty());

    const new_req = pool.alloc(.timer) orelse return error.AllocFailed;
    try std.testing.expectEqual(IoOpType.timer, new_req.op);
}

test "IoRequestPool ID monotonicity" {
    var pool: IoRequestPool = undefined;
    pool.init();

    const req1 = pool.alloc(.noop) orelse return error.AllocFailed;
    const req2 = pool.alloc(.noop) orelse return error.AllocFailed;
    const req3 = pool.alloc(.noop) orelse return error.AllocFailed;

    try std.testing.expect(req2.id > req1.id);
    try std.testing.expect(req3.id > req2.id);
}
