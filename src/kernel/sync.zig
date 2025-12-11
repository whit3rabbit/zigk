// Kernel Synchronization Primitives
//
// Provides IRQ-safe spinlocks for protecting critical sections in the kernel.
// All locking follows the acquire/release pattern with interrupt state preservation.
//
// Constitution Compliance (Principle IX - Heap Hygiene):
//   - Spinlocks protect shared kernel state from interrupt-driven corruption
//   - Per-subsystem locks enable fine-grained parallelism
//
// Spec Reference: Spec 003 FR-LOCK-01 through FR-LOCK-04

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
/// Usage:
///   const held = lock.acquire();
///   defer held.release();
///   // Critical section here
///
/// Guarantees:
///   - Interrupts are disabled during the critical section
///   - Original interrupt state is restored on release
///   - Atomic compare-and-swap for lock acquisition
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
            if (is_freestanding) {
                if (sched.getCurrentThread()) |t| {
                    if (t.lock_depth > 0) {
                        t.lock_depth -= 1;
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
