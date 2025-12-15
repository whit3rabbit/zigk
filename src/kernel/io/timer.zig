// Hierarchical Timer Wheel
//
// Efficient timer management for async I/O timeout support.
// Uses a hierarchical wheel structure for O(1) insertion and
// O(1) amortized expiration processing.
//
// Design:
//   - 3-level hierarchy: L0 (1ms), L1 (256ms), L2 (65536ms)
//   - 256 slots per level
//   - Cascading from higher levels on overflow
//   - Integrates with reactor for IoRequest timeouts
//
// Time Complexity:
//   - Insert: O(1)
//   - Tick: O(1) amortized (occasional cascade)
//   - Cancel: O(n) worst case within slot (could optimize with doubly-linked list)
//
// Constitution Compliance (Principle IX):
//   - No dynamic allocation - fixed-size slot arrays
//   - Bounded memory usage regardless of timer count

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const IoRequest = types.IoRequest;
const IoResult = types.IoResult;

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

// =============================================================================
// Constants
// =============================================================================

/// Number of slots per wheel level
const SLOTS_PER_LEVEL: usize = 256;

/// Bits per level (log2 of SLOTS_PER_LEVEL)
const BITS_PER_LEVEL: u6 = 8;

/// Number of wheel levels
const NUM_LEVELS: usize = 3;

/// Maximum timeout in ticks (256^3 = 16777216 ticks)
pub const MAX_TIMEOUT: u64 = 1 << (BITS_PER_LEVEL * NUM_LEVELS);

/// Tick duration in nanoseconds (assume 1ms tick from scheduler)
pub const TICK_NS: u64 = 1_000_000;

// =============================================================================
// Timer Wheel
// =============================================================================

/// Hierarchical timer wheel for efficient timeout management
pub const TimerWheel = struct {
    /// Wheel slots - each slot is a linked list of timers
    /// L0: 1-255 ticks (1ms granularity)
    /// L1: 256-65535 ticks (256ms granularity)
    /// L2: 65536+ ticks (65536ms granularity)
    slots: [NUM_LEVELS][SLOTS_PER_LEVEL]?*IoRequest,

    /// Current position in each wheel level
    positions: [NUM_LEVELS]u8,

    /// Current absolute tick count
    current_tick: u64,

    /// Lock protecting wheel state
    lock: sync.Spinlock,

    /// Statistics
    stats: TimerStats,

    /// Initialize a timer wheel
    pub fn init() TimerWheel {
        var wheel: TimerWheel = undefined;

        // Initialize all slots to null
        for (&wheel.slots) |*level| {
            for (level) |*slot| {
                slot.* = null;
            }
        }

        wheel.positions = [_]u8{0} ** NUM_LEVELS;
        wheel.current_tick = 0;
        wheel.lock = .{};
        wheel.stats = .{};

        return wheel;
    }

    /// Add a timer to the wheel
    /// timeout: number of ticks until expiry
    pub fn add(self: *TimerWheel, req: *IoRequest, timeout: u64) void {
        const held = self.lock.acquire();
        defer held.release();

        // Clamp timeout to max
        const clamped_timeout = @min(timeout, MAX_TIMEOUT - 1);
        const expiry = self.current_tick +% clamped_timeout;

        // Store expiry in request (reuse timer.timeout_ns field)
        req.op_data.timer.timeout_ns = expiry;

        // Determine which level and slot
        const delta = expiry -% self.current_tick;
        const level_slot = self.calculateSlot(delta);

        // Insert at head of slot list
        req.next = self.slots[level_slot.level][level_slot.slot];
        self.slots[level_slot.level][level_slot.slot] = req;

        self.stats.timers_added += 1;
    }

    /// Cancel a pending timer
    /// Returns true if timer was found and cancelled
    pub fn cancel(self: *TimerWheel, req: *IoRequest) bool {
        const held = self.lock.acquire();
        defer held.release();

        // Search all slots for this request
        // Note: Could optimize with per-request slot tracking
        for (&self.slots) |*level| {
            for (level) |*slot| {
                var prev: ?*IoRequest = null;
                var curr = slot.*;

                while (curr) |c| {
                    if (c == req) {
                        // Found it - remove from list
                        if (prev) |p| {
                            p.next = c.next;
                        } else {
                            slot.* = c.next;
                        }
                        c.next = null;
                        self.stats.timers_cancelled += 1;
                        return true;
                    }
                    prev = c;
                    curr = c.next;
                }
            }
        }

        return false;
    }

    /// Process one tick of the timer wheel
    /// Returns list of expired timers (caller must complete/free them)
    pub fn tick(self: *TimerWheel) ?*IoRequest {
        const held = self.lock.acquire();
        defer held.release();

        self.current_tick +%= 1;

        // Advance L0 position
        self.positions[0] +%= 1;

        // Get expired timers from L0 current slot
        const expired = self.slots[0][self.positions[0]];
        self.slots[0][self.positions[0]] = null;

        // If L0 wrapped, cascade from L1
        if (self.positions[0] == 0) {
            self.cascade(1);
        }

        if (expired != null) {
            self.stats.timers_expired += self.countList(expired);
        }

        return expired;
    }

    /// Process multiple ticks (for catching up after delay)
    pub fn tickMultiple(self: *TimerWheel, count: u64) ?*IoRequest {
        var expired_head: ?*IoRequest = null;
        var expired_tail: ?*IoRequest = null;

        for (0..count) |_| {
            if (self.tick()) |batch| {
                // Append to result list
                if (expired_tail) |tail| {
                    tail.next = batch;
                } else {
                    expired_head = batch;
                }
                // Find new tail
                var curr = batch;
                while (curr) |c| {
                    if (c.next == null) {
                        expired_tail = c;
                        break;
                    }
                    curr = c.next;
                }
            }
        }

        return expired_head;
    }

    /// Get current tick count
    pub fn getCurrentTick(self: *const TimerWheel) u64 {
        return self.current_tick;
    }

    /// Get statistics
    pub fn getStats(self: *const TimerWheel) TimerStats {
        return self.stats;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// Calculate level and slot for a given delta
    fn calculateSlot(self: *const TimerWheel, delta: u64) struct { level: usize, slot: u8 } {
        if (delta < SLOTS_PER_LEVEL) {
            // L0: 0-255 ticks
            const slot = @as(u8, @truncate((self.positions[0] +% @as(u8, @truncate(delta))) & 0xFF));
            return .{ .level = 0, .slot = slot };
        } else if (delta < SLOTS_PER_LEVEL * SLOTS_PER_LEVEL) {
            // L1: 256-65535 ticks
            const l1_delta = delta >> BITS_PER_LEVEL;
            const slot = @as(u8, @truncate((self.positions[1] +% @as(u8, @truncate(l1_delta))) & 0xFF));
            return .{ .level = 1, .slot = slot };
        } else {
            // L2: 65536+ ticks
            const l2_delta = delta >> (BITS_PER_LEVEL * 2);
            const slot = @as(u8, @truncate((self.positions[2] +% @as(u8, @truncate(l2_delta))) & 0xFF));
            return .{ .level = 2, .slot = slot };
        }
    }

    /// Cascade timers from a higher level down
    fn cascade(self: *TimerWheel, level: usize) void {
        if (level >= NUM_LEVELS) return;

        self.positions[level] +%= 1;

        // Get timers from current slot at this level
        const slot_head = self.slots[level][self.positions[level]];
        self.slots[level][self.positions[level]] = null;

        // Re-insert each timer (will go to appropriate lower level)
        var curr = slot_head;
        while (curr) |req| {
            const next = req.next;
            req.next = null;

            // Calculate new delta
            const delta = req.op_data.timer.timeout_ns -% self.current_tick;
            if (delta == 0 or delta > MAX_TIMEOUT) {
                // Expired or invalid - put in L0 current slot for immediate expiry
                req.next = self.slots[0][self.positions[0]];
                self.slots[0][self.positions[0]] = req;
            } else {
                // Re-insert at correct level
                const new_slot = self.calculateSlot(delta);
                req.next = self.slots[new_slot.level][new_slot.slot];
                self.slots[new_slot.level][new_slot.slot] = req;
            }

            curr = next;
        }

        // If this level wrapped, cascade to next level
        if (self.positions[level] == 0 and level + 1 < NUM_LEVELS) {
            self.cascade(level + 1);
        }
    }

    /// Count items in a linked list
    fn countList(self: *const TimerWheel, head: ?*IoRequest) u64 {
        _ = self;
        var count: u64 = 0;
        var curr = head;
        while (curr) |c| {
            count += 1;
            curr = c.next;
        }
        return count;
    }
};

/// Timer statistics
pub const TimerStats = struct {
    timers_added: u64 = 0,
    timers_expired: u64 = 0,
    timers_cancelled: u64 = 0,
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Convert nanoseconds to ticks
pub fn nsToTicks(ns: u64) u64 {
    return ns / TICK_NS;
}

/// Convert milliseconds to ticks
pub fn msToTicks(ms: u64) u64 {
    return ms; // 1ms per tick
}

/// Convert seconds to ticks
pub fn secToTicks(sec: u64) u64 {
    return sec * 1000;
}

/// Complete all timers in a list with success
pub fn completeExpiredTimers(head: ?*IoRequest) void {
    var curr = head;
    while (curr) |req| {
        const next = req.next;
        req.next = null;
        _ = req.complete(.{ .success = 0 });
        curr = next;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "TimerWheel init" {
    const wheel = TimerWheel.init();
    try std.testing.expectEqual(@as(u64, 0), wheel.current_tick);
    try std.testing.expectEqual(@as(u8, 0), wheel.positions[0]);
}

test "TimerWheel add and tick" {
    var wheel = TimerWheel.init();

    // Create a mock request
    var req = IoRequest.init(1, .timer);
    _ = req.compareAndSwapState(.idle, .pending);

    // Add timer for 5 ticks
    wheel.add(&req, 5);

    // Tick 4 times - should not expire
    for (0..4) |_| {
        const expired = wheel.tick();
        try std.testing.expectEqual(@as(?*IoRequest, null), expired);
    }

    // Tick once more - should expire
    const expired = wheel.tick();
    try std.testing.expect(expired != null);
    try std.testing.expectEqual(&req, expired.?);
}

test "TimerWheel cancel" {
    var wheel = TimerWheel.init();

    var req = IoRequest.init(1, .timer);
    _ = req.compareAndSwapState(.idle, .pending);

    wheel.add(&req, 100);

    // Cancel before expiry
    const cancelled = wheel.cancel(&req);
    try std.testing.expect(cancelled);

    // Tick past the original expiry
    for (0..110) |_| {
        const expired = wheel.tick();
        try std.testing.expectEqual(@as(?*IoRequest, null), expired);
    }
}

test "TimerWheel L1 cascade" {
    var wheel = TimerWheel.init();

    var req = IoRequest.init(1, .timer);
    _ = req.compareAndSwapState(.idle, .pending);

    // Add timer for 300 ticks (goes to L1)
    wheel.add(&req, 300);

    // Tick 299 times - should not expire
    for (0..299) |_| {
        const expired = wheel.tick();
        try std.testing.expectEqual(@as(?*IoRequest, null), expired);
    }

    // Tick once more - should expire
    const expired = wheel.tick();
    try std.testing.expect(expired != null);
}

test "nsToTicks conversion" {
    try std.testing.expectEqual(@as(u64, 1), nsToTicks(1_000_000));
    try std.testing.expectEqual(@as(u64, 1000), nsToTicks(1_000_000_000));
}
