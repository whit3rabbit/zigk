const std = @import("std");
const platform = @import("platform.zig");

/// IRQ-safe spinlock for network stack
pub const Spinlock = struct {
    locked: std.atomic.Value(u32) = .{ .raw = 0 },

    pub const Held = struct {
        lock: *Spinlock,
        irq_state: u64,

        pub fn release(self: Held) void {
            self.lock.locked.store(0, .release);
            platform.cpu.restoreInterrupts(self.irq_state);
        }
    };

    pub fn acquire(self: *Spinlock) Held {
        const irq = platform.cpu.disableInterruptsSaveFlags();
        while (true) {
            const prev = self.locked.cmpxchgWeak(0, 1, .acquire, .monotonic);
            if (prev == null) break;
            std.atomic.spinLoopHint();
        }
        return .{ .lock = self, .irq_state = irq };
    }
    
    pub fn tryAcquire(self: *Spinlock) ?Held {
        const irq = platform.cpu.disableInterruptsSaveFlags();
        const prev = self.locked.cmpxchgStrong(0, 1, .acquire, .monotonic);
        if (prev == null) {
            return .{ .lock = self, .irq_state = irq };
        }
        platform.cpu.restoreInterrupts(irq);
        return null;
    }
};

/// Lock interface (Mutex/Spinlock)
pub const Lock = struct {
    /// Opaque pointer to the actual lock instance
    ctx: *anyopaque,
    /// Function to acquire the lock
    acquireFn: *const fn (*anyopaque) void,
    /// Function to release the lock
    releaseFn: *const fn (*anyopaque) void,

    pub fn acquire(self: Lock) void {
        self.acquireFn(self.ctx);
    }

    pub fn release(self: Lock) void {
        self.releaseFn(self.ctx);
    }
};

// No-op implementation for when no locking is configured
fn noop(_: *anyopaque) void {}
var dummy_ctx: u8 = 0;

/// Default no-op lock
pub const noop_lock = Lock{
    .ctx = &dummy_ctx,
    .acquireFn = noop,
    .releaseFn = noop,
};
