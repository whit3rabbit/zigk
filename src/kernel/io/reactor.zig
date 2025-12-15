// Kernel Async I/O Reactor
//
// Central coordinator for all async I/O operations. Manages the request pool,
// dispatches operations to subsystems, and handles completions from IRQ context.
//
// Design:
//   - Singleton pattern - one reactor per kernel
//   - Tick-based polling for timeout handling
//   - IRQ-safe completion path (no blocking)
//   - Subsystems register completion hooks
//
// Integration:
//   - Called from kernel main to initialize
//   - Tick callback registered with scheduler
//   - IRQ handlers call completeRequest() directly

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const pool_mod = @import("pool.zig");

const IoRequest = types.IoRequest;
const IoResult = types.IoResult;
const IoOpType = types.IoOpType;
const Future = types.Future;
const IoRequestPool = pool_mod.IoRequestPool;

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

        pub fn tryAcquire(self: *Spinlock) ?Held {
            if (self.locked.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
                return .{ .lock = self };
            }
            return null;
        }
    };
};

/// Global reactor instance
var global_reactor: Reactor = undefined;
var reactor_initialized: bool = false;

/// Completion callback type
/// Called when an operation completes - must be IRQ-safe
pub const CompletionCallback = *const fn (*IoRequest) void;

/// Reactor - central async I/O coordinator
pub const Reactor = struct {
    /// Request pool for all async operations
    pool: IoRequestPool,

    /// Lock protecting reactor state
    lock: sync.Spinlock,

    /// Current tick count (from scheduler)
    current_tick: u64,

    /// Pending timer operations (sorted by expiry)
    timer_head: ?*IoRequest,

    /// Statistics
    stats: ReactorStats,

    /// Initialize the reactor
    pub fn init() Reactor {
        return .{
            .pool = IoRequestPool.init(),
            .lock = .{},
            .current_tick = 0,
            .timer_head = null,
            .stats = .{},
        };
    }

    /// Allocate a request for an async operation
    /// Returns null if pool exhausted (caller should return EAGAIN)
    pub fn allocRequest(self: *Reactor, op: IoOpType) ?*IoRequest {
        const req = self.pool.alloc(op);
        if (req != null) {
            self.stats.requests_allocated += 1;
        }
        return req;
    }

    /// Free a completed request back to the pool
    pub fn freeRequest(self: *Reactor, req: *IoRequest) void {
        self.pool.free(req);
        self.stats.requests_freed += 1;
    }

    /// Submit an async operation and get a Future handle
    /// The operation is dispatched based on its type
    pub fn submit(self: *Reactor, req: *IoRequest) Future {
        // Mark as pending
        _ = req.compareAndSwapState(.idle, .pending);

        self.stats.requests_submitted += 1;

        return Future{ .request = req };
    }

    /// Add a timer operation to the timer queue
    pub fn addTimer(self: *Reactor, req: *IoRequest, timeout_ticks: u64) void {
        const held = self.lock.acquire();
        defer held.release();

        const expiry = self.current_tick + timeout_ticks;
        req.op_data.timer.timeout_ns = expiry; // Reuse as expiry tick

        // Insert sorted by expiry time
        var prev: ?*IoRequest = null;
        var curr = self.timer_head;

        while (curr) |c| {
            if (c.op_data.timer.timeout_ns > expiry) {
                break;
            }
            prev = c;
            curr = c.next;
        }

        req.next = curr;
        if (prev) |p| {
            p.next = req;
        } else {
            self.timer_head = req;
        }
    }

    /// Cancel a pending timer
    pub fn cancelTimer(self: *Reactor, req: *IoRequest) bool {
        const held = self.lock.acquire();
        defer held.release();

        // Remove from timer list
        var prev: ?*IoRequest = null;
        var curr = self.timer_head;

        while (curr) |c| {
            if (c == req) {
                if (prev) |p| {
                    p.next = c.next;
                } else {
                    self.timer_head = c.next;
                }
                return req.cancel();
            }
            prev = c;
            curr = c.next;
        }

        return false;
    }

    /// Timer tick - called from scheduler timer interrupt
    /// Must be IRQ-safe (no blocking)
    pub fn tick(self: *Reactor) void {
        // Try to acquire lock - skip tick if contended
        const held = self.lock.tryAcquire() orelse return;
        defer held.release();

        self.current_tick += 1;

        // Process expired timers
        while (self.timer_head) |req| {
            if (req.op_data.timer.timeout_ns > self.current_tick) {
                break; // No more expired timers
            }

            // Remove from list
            self.timer_head = req.next;
            req.next = null;

            // Complete the timer
            _ = req.complete(.{ .success = 0 });
            self.stats.timers_expired += 1;
        }
    }

    /// Get reactor statistics
    pub fn getStats(self: *Reactor) ReactorStats {
        return self.stats;
    }

    /// Get pool statistics
    pub fn getPoolStats(self: *Reactor) pool_mod.PoolStats {
        return self.pool.getStats();
    }
};

/// Reactor statistics
pub const ReactorStats = struct {
    requests_allocated: u64 = 0,
    requests_freed: u64 = 0,
    requests_submitted: u64 = 0,
    requests_completed: u64 = 0,
    timers_expired: u64 = 0,
};

// =============================================================================
// Global API
// =============================================================================

/// Initialize the global reactor
/// Called once from kernel main
pub fn initGlobal() void {
    global_reactor = Reactor.init();
    reactor_initialized = true;
}

/// Get the global reactor instance
pub fn getGlobal() *Reactor {
    if (!reactor_initialized) {
        @panic("Reactor not initialized");
    }
    return &global_reactor;
}

/// Convenience: allocate a request from the global reactor
pub fn allocRequest(op: IoOpType) ?*IoRequest {
    return getGlobal().allocRequest(op);
}

/// Convenience: free a request to the global reactor
pub fn freeRequest(req: *IoRequest) void {
    getGlobal().freeRequest(req);
}

/// Convenience: submit to the global reactor
pub fn submit(req: *IoRequest) Future {
    return getGlobal().submit(req);
}

/// Timer tick callback - register with scheduler
pub fn timerTick() void {
    if (reactor_initialized) {
        global_reactor.tick();
    }
}

// =============================================================================
// Tests
// =============================================================================

test "Reactor basic init" {
    var reactor = Reactor.init();

    const stats = reactor.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.requests_allocated);
}

test "Reactor alloc and free" {
    var reactor = Reactor.init();

    const req = reactor.allocRequest(.socket_read) orelse return error.AllocFailed;
    try std.testing.expectEqual(IoOpType.socket_read, req.op);

    reactor.freeRequest(req);

    const stats = reactor.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.requests_allocated);
    try std.testing.expectEqual(@as(u64, 1), stats.requests_freed);
}

test "Reactor timer expiry" {
    var reactor = Reactor.init();

    const req = reactor.allocRequest(.timer) orelse return error.AllocFailed;
    _ = req.compareAndSwapState(.idle, .pending);

    // Add timer for 5 ticks from now
    reactor.addTimer(req, 5);

    // Tick 4 times - timer should not expire
    for (0..4) |_| {
        reactor.tick();
    }
    try std.testing.expectEqual(types.IoRequestState.pending, req.getState());

    // Tick once more - timer should expire
    reactor.tick();
    try std.testing.expectEqual(types.IoRequestState.completed, req.getState());
    try std.testing.expectEqual(IoResult{ .success = 0 }, req.result);
}
