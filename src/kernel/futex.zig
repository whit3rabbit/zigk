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
/// Uses wrapping multiplication (*%) since MurmurHash mixing intentionally overflows
fn hash(phys_addr: u64) usize {
    // Simple mixing (MurmurHash finalizer)
    var h = phys_addr;
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *%= 0xc4ceb9fe1a85ec53;
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

    // 1. Validate user address has user-accessible permission
    // SECURITY: Prevents kernel memory disclosure via oracle attack.
    // An attacker could pass kernel addresses (e.g., 0xFFFF_8000_...) which are
    // present in CR3 (kernel mappings shared via PML4 entries 256-511) but lack
    // user_accessible bit. Without this check, the kernel would read the value
    // and return EAGAIN or block, allowing binary search to leak kernel memory.
    if (!vmm.isUserPageMapped(current.cr3, uaddr)) return error.Fault;

    // 2. Translate to physical address
    // Physical address uniquely identifies the futex, enabling shared memory futexes
    const phys_addr = vmm.translate(current.cr3, uaddr) orelse return error.Fault;

    // 3. Compute bucket
    const bucket_idx = hash(phys_addr);
    const bucket = &futex_table[bucket_idx];

    // 4. Acquire bucket lock
    // Critical section prevents lost wakeup race
    const held = bucket.lock.acquire();

    // 5. Validate value atomically using the physical address
    // SECURITY: Read through HHDM-mapped physical address, not raw user virtual address.
    // Directly dereferencing `uaddr` in kernel context is unsafe because:
    // (a) The kernel may have different page tables active than the user's CR3.
    // (b) A malicious user could pass a kernel-space address that happens to be
    //     readable, leaking kernel memory contents.
    // By using the translated physical address via HHDM, we ensure we read exactly
    // the memory the user's page tables map, preventing information disclosure.
    const phys_with_offset = phys_addr; // translate() returns phys including page offset
    const kernel_ptr: *const volatile u32 = @ptrCast(@alignCast(hal.paging.physToVirt(phys_with_offset)));
    const current_val = kernel_ptr.*;

    if (current_val != val) {
        held.release();
        return error.Again;
    }

    // 6. Sleep with optional timeout
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

    // 7. Check wakeup reason
    if (current.futex_wakeup_reason == .timeout) {
        return error.TimedOut;
    }

    // Normal wakeup (by FUTEX_WAKE) or spurious wakeup
    return;
}

/// Futex Wake
///
/// 1. Validate user address permissions
/// 2. Translate user address to physical address
/// 3. Compute bucket
/// 4. Wake up to `count` threads from bucket, canceling any pending timeouts
///
/// Returns: Number of threads woken
pub fn wake(uaddr: u64, count: u32) !u32 {
    const current = sched.getCurrentThread() orelse return error.PermDenied;

    // 1. Validate user address has user-accessible permission
    // SECURITY: While wake() doesn't directly leak memory contents, allowing
    // kernel addresses enables KASLR probing via hash bucket correlation.
    if (!vmm.isUserPageMapped(current.cr3, uaddr)) return error.Fault;

    // 2. Translate to physical address
    const phys_addr = vmm.translate(current.cr3, uaddr) orelse return error.Fault;

    // 3. Compute bucket
    const bucket_idx = hash(phys_addr);
    const bucket = &futex_table[bucket_idx];

    // 4. Acquire bucket lock
    const held = bucket.lock.acquire();
    defer held.release();

    // 5. Wake threads, properly canceling any pending timeouts
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
