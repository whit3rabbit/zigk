//! Kernel Synchronization Primitives
//!
//! Provides IRQ-safe spinlocks for protecting critical sections in the kernel.
//! All locking follows the acquire/release pattern with interrupt state preservation.
//!
//! Constitution Compliance (Principle IX - Heap Hygiene):
//!   - Spinlocks protect shared kernel state from interrupt-driven corruption.
//!   - Per-subsystem locks enable fine-grained parallelism.
//!
//! Usage:
//! ```zig
//! var my_lock = Spinlock{};
//! {
//!     const held = my_lock.acquire();
//!     defer held.release();
//!     // Critical section
//! }
//! ```

const std = @import("std");

// HAL layer for interrupt control - only place these operations are permitted
const is_freestanding = @import("builtin").os.tag == .freestanding;

// Scheduler access for lock_depth tracking (yield safety check)
const sched = if (is_freestanding) @import("sched") else null;

// In freestanding mode, use real HAL; in tests, use stubs
const hal_cpu = if (is_freestanding)
    @import("hal").cpu
else
    // Test stubs for host-side testing
    struct {
        var irq_enabled: bool = true;

        pub fn disableInterrupts() void {
            irq_enabled = false;
        }

        pub fn enableInterrupts() void {
            irq_enabled = true;
        }

        pub fn interruptsEnabled() bool {
            return irq_enabled;
        }
    };

/// IRQ-safe spinlock for kernel critical sections
///
/// Guarantees:
///   - Interrupts are disabled during the critical section.
///   - Original interrupt state is restored on release.
///   - Atomic compare-and-swap for lock acquisition.
pub const Spinlock = struct {
    /// Lock state: 0 = unlocked, 1 = locked
    /// Using std.atomic.Value for atomic operations
    locked: std.atomic.Value(u32) = .{ .raw = 0 },

    /// RAII guard returned by acquire() - ensures release() is called
    pub const Held = struct {
        lock: *Spinlock,
        /// Saved interrupt state to restore on release
        irq_state: bool,

        /// Release the lock and restore interrupt state
        /// This MUST be called exactly once per acquire()
        pub fn release(self: Held) void {
            // Decrement lock depth before releasing
            // Only track after scheduler is running (GS base is set)
            if (is_freestanding) {
                if (sched.isRunning()) {
                    if (sched.getCurrentThread()) |t| {
                        if (t.lock_depth > 0) {
                            t.lock_depth -= 1;
                        }
                    }
                }
            }

            // Unlock with release ordering - ensures all writes are visible
            // before the lock is released
            self.lock.locked.store(0, .release);

            // Restore interrupt state (FR-LOCK-02)
            if (self.irq_state) {
                hal_cpu.enableInterrupts();
            }
        }
    };

    /// Acquire the lock, disabling interrupts first (FR-LOCK-01)
    /// Spins until the lock is acquired
    /// Returns a Held guard that must be released
    pub fn acquire(self: *Spinlock) Held {
        // Save current interrupt state before disabling
        const irq_was_enabled = hal_cpu.interruptsEnabled();

        // Disable interrupts BEFORE spinning (FR-LOCK-01)
        // This prevents deadlock if an ISR tries to acquire the same lock
        hal_cpu.disableInterrupts();

        // Spin until we acquire the lock
        // Using test-and-set pattern with atomic cmpxchg
        while (true) {
            // Try to atomically set locked from 0 to 1
            const prev = self.locked.cmpxchgWeak(
                0, // expected
                1, // desired
                .acquire, // success ordering
                .monotonic, // failure ordering
            );

            if (prev == null) {
                // Successfully acquired - prev was 0
                break;
            }

            // Lock is held by someone else, spin
            // Use pause instruction to reduce power and avoid pipeline stalls
            spinHint();
        }

        // cmpxchgWeak with .acquire ordering already provides acquire semantics
        // No additional fence needed

        // Track lock depth for yield safety check
        // Only track after scheduler is running (GS base is set)
        if (is_freestanding) {
            if (sched.isRunning()) {
                if (sched.getCurrentThread()) |t| {
                    t.lock_depth += 1;
                }
            }
        }

        return .{
            .lock = self,
            .irq_state = irq_was_enabled,
        };
    }

    /// Try to acquire the lock without spinning
    /// Returns null if the lock is already held
    pub fn tryAcquire(self: *Spinlock) ?Held {
        const irq_was_enabled = hal_cpu.interruptsEnabled();
        hal_cpu.disableInterrupts();

        const prev = self.locked.cmpxchgStrong(
            0,
            1,
            .acquire,
            .monotonic,
        );

        if (prev == null) {
            // cmpxchgStrong with .acquire ordering already provides acquire semantics
            // Track lock depth for yield safety check
            // Only track after scheduler is running (GS base is set)
            if (is_freestanding) {
                if (sched.isRunning()) {
                    if (sched.getCurrentThread()) |t| {
                        t.lock_depth += 1;
                    }
                }
            }
            return .{
                .lock = self,
                .irq_state = irq_was_enabled,
            };
        }

        // Failed to acquire - restore interrupt state
        if (irq_was_enabled) {
            hal_cpu.enableInterrupts();
        }
        return null;
    }

    /// Check if the lock is currently held (for debugging only)
    /// Note: This is inherently racy and should not be used for synchronization
    pub fn isLocked(self: *const Spinlock) bool {
        return self.locked.load(.monotonic) != 0;
    }
};

/// IRQ-safe Reader-Writer Lock with Writer Preference
///
/// Allows multiple readers to access shared data concurrently while
/// providing exclusive access to writers. Uses IRQ-safe pattern like Spinlock.
///
/// SECURITY: Implements writer preference to prevent writer starvation.
/// When a writer is waiting, new readers must wait, preventing a continuous
/// stream of readers from indefinitely blocking writers. This is important
/// for security-critical operations (e.g., process tree modifications) that
/// require write locks.
///
/// State encoding:
///   - 0: Unlocked (no readers or writers)
///   - > 0: Number of active readers
///   - -1: Writer holds the lock
///
/// Usage:
/// ```zig
/// var rwlock = RwLock{};
///
/// // Read access (multiple threads can hold simultaneously)
/// {
///     const held = rwlock.acquireRead();
///     defer held.release();
///     // Read-only access to shared data
/// }
///
/// // Write access (exclusive)
/// {
///     const held = rwlock.acquireWrite();
///     defer held.release();
///     // Exclusive read-write access
/// }
/// ```
pub const RwLock = struct {
    /// Lock state:
    /// - 0 = unlocked
    /// - > 0 = reader count
    /// - -1 = writer holds lock
    state: std.atomic.Value(i32) = .{ .raw = 0 },

    /// Number of writers waiting for the lock
    /// SECURITY: Used to implement writer preference - new readers wait
    /// when pending_writers > 0 to prevent writer starvation attacks.
    pending_writers: std.atomic.Value(u32) = .{ .raw = 0 },

    /// RAII guard for read access
    pub const ReadHeld = struct {
        lock: *RwLock,
        irq_state: bool,

        pub fn release(self: ReadHeld) void {
            // Decrement lock depth
            if (is_freestanding) {
                if (sched.getCurrentThread()) |t| {
                    if (t.lock_depth > 0) {
                        t.lock_depth -= 1;
                    }
                }
            }

            // Decrement reader count with release ordering
            _ = self.lock.state.fetchSub(1, .release);

            // Restore interrupt state
            if (self.irq_state) {
                hal_cpu.enableInterrupts();
            }
        }
    };

    /// RAII guard for write access
    pub const WriteHeld = struct {
        lock: *RwLock,
        irq_state: bool,

        pub fn release(self: WriteHeld) void {
            // Decrement lock depth
            if (is_freestanding) {
                if (sched.getCurrentThread()) |t| {
                    if (t.lock_depth > 0) {
                        t.lock_depth -= 1;
                    }
                }
            }

            // Set state to 0 (unlocked) with release ordering
            self.lock.state.store(0, .release);

            // Restore interrupt state
            if (self.irq_state) {
                hal_cpu.enableInterrupts();
            }
        }
    };

    /// Acquire the lock for reading
    /// Multiple readers can hold the lock simultaneously
    /// Blocks if a writer holds the lock OR if writers are waiting (writer preference)
    ///
    /// SECURITY: Writer preference prevents starvation attacks where malicious
    /// processes continuously acquire read locks to block security-critical
    /// write operations indefinitely.
    pub fn acquireRead(self: *RwLock) ReadHeld {
        const irq_was_enabled = hal_cpu.interruptsEnabled();
        hal_cpu.disableInterrupts();

        while (true) {
            const current = self.state.load(.acquire);

            // If writer holds lock (state == -1), spin
            if (current < 0) {
                spinHint();
                continue;
            }

            // SECURITY: Writer preference - wait if writers are pending
            // This prevents reader starvation of writers
            if (self.pending_writers.load(.acquire) > 0) {
                spinHint();
                continue;
            }

            // Try to increment reader count
            const prev = self.state.cmpxchgWeak(
                current,
                current + 1,
                .acquire,
                .monotonic,
            );

            if (prev == null) {
                // Successfully acquired read lock
                break;
            }
            // CAS failed, retry
            spinHint();
        }

        // Track lock depth
        if (is_freestanding) {
            if (sched.getCurrentThread()) |t| {
                t.lock_depth += 1;
            }
        }

        return .{
            .lock = self,
            .irq_state = irq_was_enabled,
        };
    }

    /// Acquire the lock for writing
    /// Blocks until all readers and writers release the lock
    ///
    /// SECURITY: Increments pending_writers while waiting, which causes
    /// new readers to wait (writer preference). This prevents writer
    /// starvation attacks.
    pub fn acquireWrite(self: *RwLock) WriteHeld {
        const irq_was_enabled = hal_cpu.interruptsEnabled();
        hal_cpu.disableInterrupts();

        // SECURITY: Increment pending writers count to signal readers to wait
        // This implements writer preference to prevent starvation
        _ = self.pending_writers.fetchAdd(1, .acquire);

        while (true) {
            // Try to atomically set state from 0 to -1
            const prev = self.state.cmpxchgWeak(
                0, // expected: unlocked
                -1, // desired: writer holds
                .acquire,
                .monotonic,
            );

            if (prev == null) {
                // Successfully acquired write lock
                // Decrement pending writers since we're no longer waiting
                _ = self.pending_writers.fetchSub(1, .release);
                break;
            }
            // Lock is held by readers or writer, spin
            spinHint();
        }

        // Track lock depth
        if (is_freestanding) {
            if (sched.getCurrentThread()) |t| {
                t.lock_depth += 1;
            }
        }

        return .{
            .lock = self,
            .irq_state = irq_was_enabled,
        };
    }

    /// Try to acquire read lock without spinning
    /// SECURITY: Also fails if writers are pending (writer preference)
    pub fn tryAcquireRead(self: *RwLock) ?ReadHeld {
        const irq_was_enabled = hal_cpu.interruptsEnabled();
        hal_cpu.disableInterrupts();

        const current = self.state.load(.acquire);

        // Can't acquire if writer holds lock
        if (current < 0) {
            if (irq_was_enabled) hal_cpu.enableInterrupts();
            return null;
        }

        // SECURITY: Writer preference - fail if writers are pending
        if (self.pending_writers.load(.acquire) > 0) {
            if (irq_was_enabled) hal_cpu.enableInterrupts();
            return null;
        }

        const prev = self.state.cmpxchgStrong(
            current,
            current + 1,
            .acquire,
            .monotonic,
        );

        if (prev == null) {
            if (is_freestanding) {
                if (sched.getCurrentThread()) |t| {
                    t.lock_depth += 1;
                }
            }
            return .{
                .lock = self,
                .irq_state = irq_was_enabled,
            };
        }

        if (irq_was_enabled) hal_cpu.enableInterrupts();
        return null;
    }

    /// Try to acquire write lock without spinning
    pub fn tryAcquireWrite(self: *RwLock) ?WriteHeld {
        const irq_was_enabled = hal_cpu.interruptsEnabled();
        hal_cpu.disableInterrupts();

        const prev = self.state.cmpxchgStrong(
            0,
            -1,
            .acquire,
            .monotonic,
        );

        if (prev == null) {
            if (is_freestanding) {
                if (sched.getCurrentThread()) |t| {
                    t.lock_depth += 1;
                }
            }
            return .{
                .lock = self,
                .irq_state = irq_was_enabled,
            };
        }

        if (irq_was_enabled) hal_cpu.enableInterrupts();
        return null;
    }

    /// Check current lock state (for debugging only - inherently racy)
    pub fn getState(self: *const RwLock) i32 {
        return self.state.load(.monotonic);
    }

    /// Check if lock is held by a writer
    pub fn isWriteLocked(self: *const RwLock) bool {
        return self.state.load(.monotonic) < 0;
    }

    /// Check if lock is held by any reader
    pub fn isReadLocked(self: *const RwLock) bool {
        return self.state.load(.monotonic) > 0;
    }
};

/// CPU hint for spin-wait loops
/// On x86, this is the PAUSE instruction which:
///   - Reduces power consumption during spinning
///   - Avoids memory order violation pipeline flushes
///   - Improves performance on hyperthreaded CPUs
inline fn spinHint() void {
    if (is_freestanding) {
        asm volatile ("pause"
            :
            :
            : .{ .memory = true }
        );
    } else {
        // On host for testing, yield to OS scheduler
        std.Thread.yield() catch {};
    }
}

// Unit tests (run with `zig build test`)
test "spinlock basic acquire/release" {
    var lock = Spinlock{};

    // Lock should start unlocked
    try std.testing.expect(!lock.isLocked());

    // Acquire and check locked state
    const held = lock.acquire();
    try std.testing.expect(lock.isLocked());

    // Release and verify unlocked
    held.release();
    try std.testing.expect(!lock.isLocked());
}

test "spinlock try_acquire" {
    var lock = Spinlock{};

    // Should succeed on unlocked lock
    const held1 = lock.tryAcquire();
    try std.testing.expect(held1 != null);
    try std.testing.expect(lock.isLocked());

    // Should fail while lock is held
    const held2 = lock.tryAcquire();
    try std.testing.expect(held2 == null);

    // Release and try again - should succeed
    held1.?.release();
    const held3 = lock.tryAcquire();
    try std.testing.expect(held3 != null);
    held3.?.release();
}

test "rwlock basic read acquire/release" {
    var lock = RwLock{};

    // Lock should start unlocked
    try std.testing.expect(lock.getState() == 0);

    // Acquire read lock
    const held = lock.acquireRead();
    try std.testing.expect(lock.isReadLocked());
    try std.testing.expect(!lock.isWriteLocked());
    try std.testing.expect(lock.getState() == 1);

    // Release and verify unlocked
    held.release();
    try std.testing.expect(lock.getState() == 0);
}

test "rwlock basic write acquire/release" {
    var lock = RwLock{};

    // Acquire write lock
    const held = lock.acquireWrite();
    try std.testing.expect(lock.isWriteLocked());
    try std.testing.expect(!lock.isReadLocked());
    try std.testing.expect(lock.getState() == -1);

    // Release and verify unlocked
    held.release();
    try std.testing.expect(lock.getState() == 0);
}

test "rwlock multiple readers" {
    var lock = RwLock{};

    // Acquire first reader
    const held1 = lock.acquireRead();
    try std.testing.expect(lock.getState() == 1);

    // Acquire second reader - should succeed
    const held2 = lock.acquireRead();
    try std.testing.expect(lock.getState() == 2);

    // Acquire third reader
    const held3 = lock.acquireRead();
    try std.testing.expect(lock.getState() == 3);

    // Release in order
    held3.release();
    try std.testing.expect(lock.getState() == 2);

    held2.release();
    try std.testing.expect(lock.getState() == 1);

    held1.release();
    try std.testing.expect(lock.getState() == 0);
}

test "rwlock try_acquire_read" {
    var lock = RwLock{};

    // Should succeed on unlocked
    const held1 = lock.tryAcquireRead();
    try std.testing.expect(held1 != null);
    try std.testing.expect(lock.getState() == 1);

    // Should also succeed - multiple readers allowed
    const held2 = lock.tryAcquireRead();
    try std.testing.expect(held2 != null);
    try std.testing.expect(lock.getState() == 2);

    held2.?.release();
    held1.?.release();
}

test "rwlock try_acquire_write" {
    var lock = RwLock{};

    // Should succeed on unlocked
    const held1 = lock.tryAcquireWrite();
    try std.testing.expect(held1 != null);
    try std.testing.expect(lock.isWriteLocked());

    // Should fail while writer holds lock
    const held2 = lock.tryAcquireWrite();
    try std.testing.expect(held2 == null);

    // tryAcquireRead should also fail while writer holds
    const held3 = lock.tryAcquireRead();
    try std.testing.expect(held3 == null);

    held1.?.release();

    // Now should succeed
    const held4 = lock.tryAcquireWrite();
    try std.testing.expect(held4 != null);
    held4.?.release();
}

test "rwlock write_blocked_by_readers" {
    var lock = RwLock{};

    // Acquire read lock
    const held_read = lock.acquireRead();
    try std.testing.expect(lock.getState() == 1);

    // tryAcquireWrite should fail while readers hold
    const held_write = lock.tryAcquireWrite();
    try std.testing.expect(held_write == null);

    held_read.release();

    // Now write should succeed
    const held_write2 = lock.tryAcquireWrite();
    try std.testing.expect(held_write2 != null);
    held_write2.?.release();
}
