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

/// IRQ-safe lock wrapper that properly tracks interrupt state.
/// This is the ONLY lock interface that should be used for network stack state.
///
/// SECURITY: Unlike the old Lock interface, this wrapper:
/// 1. Always saves/restores IRQ state correctly
/// 2. Uses a Held token pattern to ensure release is paired with acquire
/// 3. Has mandatory initialization - panics if used uninitialized
pub const IrqLock = struct {
    spinlock: Spinlock = .{},
    initialized: bool = false,

    pub const Held = struct {
        lock: *IrqLock,
        irq_state: u64,

        pub fn release(self: Held) void {
            self.lock.spinlock.locked.store(0, .release);
            platform.cpu.restoreInterrupts(self.irq_state);
        }
    };

    /// Initialize the lock. MUST be called before any acquire/release.
    pub fn init(self: *IrqLock) void {
        self.spinlock = .{};
        self.initialized = true;
    }

    /// Acquire the lock, disabling interrupts.
    /// SECURITY: Panics if lock is not initialized to prevent silent failures.
    pub fn acquire(self: *IrqLock) Held {
        if (!self.initialized) {
            @panic("IrqLock used before initialization - security violation");
        }
        const irq = platform.cpu.disableInterruptsSaveFlags();
        while (true) {
            const prev = self.spinlock.locked.cmpxchgWeak(0, 1, .acquire, .monotonic);
            if (prev == null) break;
            std.atomic.spinLoopHint();
        }
        return .{ .lock = self, .irq_state = irq };
    }

    /// Try to acquire the lock without blocking.
    /// Returns null if lock is held by another context.
    /// SECURITY: Panics if lock is not initialized.
    pub fn tryAcquire(self: *IrqLock) ?Held {
        if (!self.initialized) {
            @panic("IrqLock used before initialization - security violation");
        }
        const irq = platform.cpu.disableInterruptsSaveFlags();
        const prev = self.spinlock.locked.cmpxchgStrong(0, 1, .acquire, .monotonic);
        if (prev == null) {
            return .{ .lock = self, .irq_state = irq };
        }
        platform.cpu.restoreInterrupts(irq);
        return null;
    }

    /// Check if the lock is initialized.
    pub fn isInitialized(self: *const IrqLock) bool {
        return self.initialized;
    }
};

/// Atomic reference counter for safe object lifetime management.
/// SECURITY: Prevents TOCTOU races in refcount operations.
pub const AtomicRefcount = struct {
    count: std.atomic.Value(u32) = .{ .raw = 1 },

    /// Increment reference count. Returns previous value.
    /// SECURITY: Uses acquire ordering to ensure visibility of object state.
    pub fn retain(self: *AtomicRefcount) u32 {
        return self.count.fetchAdd(1, .acquire);
    }

    /// Decrement reference count. Returns true if this was the last reference.
    /// SECURITY: Uses release ordering to ensure all modifications are visible
    /// before the object is freed.
    pub fn release(self: *AtomicRefcount) bool {
        const prev = self.count.fetchSub(1, .release);
        if (prev == 1) {
            // Ensure all prior writes are visible before returning true.
            // Use acq_rel fetchAdd(0) as a full fence since std.atomic.fence
            // doesn't exist in this Zig version.
            _ = self.count.fetchAdd(0, .acq_rel);
            return true;
        }
        return false;
    }

    /// Get current count (for debugging/assertions only).
    pub fn get(self: *const AtomicRefcount) u32 {
        return self.count.load(.acquire);
    }

    /// Try to increment only if count > 0 (not being destroyed).
    /// Returns true if successfully incremented.
    /// SECURITY: Prevents resurrection of dying objects.
    pub fn tryRetain(self: *AtomicRefcount) bool {
        var current = self.count.load(.acquire);
        while (current > 0) {
            const result = self.count.cmpxchgWeak(
                current,
                current + 1,
                .acquire,
                .monotonic,
            );
            if (result == null) {
                return true; // Successfully incremented
            }
            current = result.?;
        }
        return false; // Count was 0, object is being destroyed
    }
};

// REMOVED: noop_lock - This was a dangerous default that provided zero
// synchronization. All code must now use properly initialized IrqLock.
// If you see a compilation error pointing here, update your code to use
// IrqLock with explicit initialization.
