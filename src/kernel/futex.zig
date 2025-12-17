//! Futex (Fast Userspace Mutex) Support
//!
//! Implements a global hash table of wait queues for synchronizing threads
//! on user-space addresses.
//!
//! Key Concepts:
//! - Physical Address Keying: Threads wait on physical addresses, allowing shared memory futexes.
//! - Global Hash Table: Fixed-size table with per-bucket locks.
//! - Atomic Validation: wait() verifies *addr == val atomically before sleeping.
//!
//! Note:
//! - Timeouts are not fully implemented yet (infinite wait).
//! - Only basic FUTEX_WAIT and FUTEX_WAKE implemented for MVP.

const std = @import("std");
const console = @import("console");
const sched = @import("sched");
const sync = @import("sync");
const heap = @import("heap");
const hal = @import("hal");
const vmm = @import("vmm");

const BUCKET_COUNT = 256; // Power of 2 for fast modulus

/// Hash bucket for futex queues
/// Public so wakeSleepingThreads can access when handling timeout
pub const FutexBucket = struct {
    lock: sync.Spinlock = .{},
    queue: sched.WaitQueue = .{},
};

/// Convert an opaque futex_bucket pointer back to FutexBucket
/// Used by scheduler when handling futex timeout expiry
pub fn getBucketFromOpaque(ptr: *anyopaque) *FutexBucket {
    return @ptrCast(@alignCast(ptr));
}

/// Global futex hash table
var futex_table: [BUCKET_COUNT]FutexBucket = undefined;
var initialized = false;

pub fn init() void {
    if (initialized) return;
    for (&futex_table) |*b| {
        b.* = .{};
    }
    initialized = true;
    console.info("Futex subsystem initialized", .{});
}

/// Compute hash for a physical address
fn hash(phys_addr: u64) usize {
    // Simple mixing
    var h = phys_addr;
    h ^= h >> 33;
    h *= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *= 0xc4ceb9fe1a85ec53;
    h ^= h >> 33;
    return h % BUCKET_COUNT;
}

/// Futex Wait
///
/// 1. Translate user address to physical address (identifies the futex)
/// 2. Atomic check: if *uaddr != val, return EAGAIN
/// 3. Sleep on hash bucket queue corresponding to phys_addr
///
/// Returns:
///   success: Thread was woken by FUTEX_WAKE
///   error.Again: *uaddr != val (EWOULDBLOCK/EAGAIN)
///   error.TimedOut: Timeout expired before wakeup
///   error.Fault: Invalid user address
///   error.PermDenied: No current thread
pub fn wait(uaddr: u64, val: u32, timeout_ns: ?u64) !void {
    const current = sched.getCurrentThread() orelse return error.PermDenied;

    // 1. Translate to physical address
    // Physical address uniquely identifies the futex, enabling shared memory futexes
    const phys_addr = vmm.translate(current.cr3, uaddr) orelse return error.Fault;

    // 2. Compute bucket
    const bucket_idx = hash(phys_addr);
    const bucket = &futex_table[bucket_idx];

    // 3. Acquire bucket lock
    // Critical section prevents lost wakeup race
    const held = bucket.lock.acquire();

    // 4. Validate value atomically
    // Note: We assume page is present (verified in sys_futex, no swapping in zscapek)
    const ptr = @as(*const volatile u32, @ptrFromInt(uaddr));
    const current_val = ptr.*;

    if (current_val != val) {
        held.release();
        return error.Again;
    }

    // 5. Sleep with optional timeout
    // Convert timeout from nanoseconds to ticks (1ms per tick)
    var timeout_ticks: u64 = 0;
    if (timeout_ns) |ns| {
        // Round up to ensure we wait at least the requested time
        timeout_ticks = (ns + 999_999) / 1_000_000;
        if (timeout_ticks == 0) timeout_ticks = 1; // Minimum 1 tick
    }

    // waitOnWithTimeout handles:
    // - Adding to wait queue
    // - Adding to sleep list (if timeout > 0)
    // - Setting futex_bucket for timeout handling
    // - Releasing bucket lock atomically with sleep
    sched.waitOnWithTimeout(
        &bucket.queue,
        held,
        timeout_ticks,
        if (timeout_ticks > 0) @ptrCast(bucket) else null,
    );

    // 6. Check wakeup reason
    if (current.futex_wakeup_reason == .timeout) {
        return error.TimedOut;
    }

    // Normal wakeup (by FUTEX_WAKE) or spurious wakeup
    return;
}

/// Futex Wake
///
/// 1. Translate user address to physical address
/// 2. Compute bucket
/// 3. Wake up to `count` threads from bucket, canceling any pending timeouts
///
/// Returns: Number of threads woken
pub fn wake(uaddr: u64, count: u32) !u32 {
    const current = sched.getCurrentThread() orelse return error.PermDenied;

    // 1. Translate to physical address
    const phys_addr = vmm.translate(current.cr3, uaddr) orelse return error.Fault;

    // 2. Compute bucket
    const bucket_idx = hash(phys_addr);
    const bucket = &futex_table[bucket_idx];

    // 3. Acquire bucket lock
    const held = bucket.lock.acquire();
    defer held.release();

    // 4. Wake threads, properly canceling any pending timeouts
    // Note: Hash collisions may cause spurious wakeups - this is acceptable
    // as futex semantics require userspace to re-check the condition in a loop
    var woken: u32 = 0;
    while (woken < count) {
        if (bucket.queue.pop()) |t| {
            // cancelTimeoutAndWake handles:
            // - Removing from sleep list if timeout was set
            // - Setting futex_wakeup_reason to .woken
            // - Adding to ready queue
            sched.cancelTimeoutAndWake(t);
            woken += 1;
        } else {
            break;
        }
    }

    return woken;
}
