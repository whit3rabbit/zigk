// Advisory File Locking (flock)
//
// Implements POSIX flock(2) advisory file locking with a global lock table.
//
// Design:
// - Global lock table with 256 locks maximum (bounded to prevent DoS)
// - 16 hash buckets for lock distribution
// - Locks identified by (mount_idx, file_id) composite key
// - Shared (LOCK_SH) and exclusive (LOCK_EX) locks supported
// - Non-blocking mode (LOCK_NB) returns EWOULDBLOCK instead of sleeping
//
// SECURITY:
// - Bounded lock table (256 max) prevents DoS via lock exhaustion
// - Per-bucket spinlocks for concurrent access
// - TOCTOU prevention: lock acquired/released under bucket_lock
// - Cleanup on close: releaseOnClose() prevents leaked locks

const std = @import("std");
const sync = @import("sync");
const sched = @import("sched");
const uapi = @import("uapi");
const console = @import("console");

const Spinlock = sync.Spinlock;
const WaitQueue = sched.WaitQueue;

/// Maximum number of concurrent file locks
const MAX_LOCKS: usize = 256;

/// Number of hash buckets for lock distribution
const NUM_BUCKETS: usize = 16;

/// Locks per bucket
const LOCKS_PER_BUCKET: usize = MAX_LOCKS / NUM_BUCKETS;

/// File lock entry
const FileLock = struct {
    /// File identifier: (mount_idx << 32) | file_id
    file_key: u64,

    /// Lock type: LOCK_SH or LOCK_EX
    lock_type: u8,

    /// Process ID holding the lock
    owner_pid: u32,

    /// Reference count (for shared locks: multiple LOCK_SH holders)
    refcount: u32,

    /// Wait queue for blocked lock attempts
    wait_queue: WaitQueue,

    /// Is this slot active?
    active: bool,

    fn init() FileLock {
        return .{
            .file_key = 0,
            .lock_type = 0,
            .owner_pid = 0,
            .refcount = 0,
            .wait_queue = .{}, // WaitQueue with default values
            .active = false,
        };
    }
};

/// Global flock manager
pub const FlockManager = struct {
    /// Lock table: 16 buckets, 16 locks per bucket
    buckets: [NUM_BUCKETS][LOCKS_PER_BUCKET]FileLock,

    /// Per-bucket spinlocks
    bucket_locks: [NUM_BUCKETS]Spinlock,

    pub fn init() FlockManager {
        var mgr: FlockManager = undefined;
        for (&mgr.buckets) |*bucket| {
            for (bucket) |*lock| {
                lock.* = FileLock.init();
            }
        }
        for (&mgr.bucket_locks) |*lock| {
            lock.* = Spinlock{};
        }
        return mgr;
    }

    /// Hash file_key to bucket index
    fn getBucketIndex(file_key: u64) usize {
        // Simple hash: XOR fold upper and lower 32 bits
        const upper: u32 = @truncate(file_key >> 32);
        const lower: u32 = @truncate(file_key);
        const hash = upper ^ lower;
        return hash % NUM_BUCKETS;
    }

    /// Find existing lock for file
    /// CALLER MUST HOLD bucket_lock
    fn findLock(self: *FlockManager, bucket_idx: usize, file_key: u64) ?*FileLock {
        for (&self.buckets[bucket_idx]) |*lock| {
            if (lock.active and lock.file_key == file_key) {
                return lock;
            }
        }
        return null;
    }

    /// Find free lock slot in bucket
    /// CALLER MUST HOLD bucket_lock
    fn findFreeSlot(self: *FlockManager, bucket_idx: usize) ?*FileLock {
        for (&self.buckets[bucket_idx]) |*lock| {
            if (!lock.active) {
                return lock;
            }
        }
        return null;
    }

    /// Check if lock can be acquired
    /// CALLER MUST HOLD bucket_lock
    fn canAcquire(existing: ?*FileLock, lock_type: u8, owner_pid: u32) bool {
        const lock = existing orelse return true; // No existing lock

        // Same process can upgrade/downgrade
        if (lock.owner_pid == owner_pid) return true;

        // Shared + Shared = compatible
        if (lock.lock_type == uapi.flock.LOCK_SH and lock_type == uapi.flock.LOCK_SH) {
            return true;
        }

        // All other combinations conflict
        return false;
    }

    /// Acquire a file lock (blocking or non-blocking)
    pub fn acquire(self: *FlockManager, file_key: u64, lock_type: u8, owner_pid: u32, nonblock: bool) !void {
        const bucket_idx = getBucketIndex(file_key);

        while (true) {
            const held = self.bucket_locks[bucket_idx].acquire();

            const existing = self.findLock(bucket_idx, file_key);

            if (canAcquire(existing, lock_type, owner_pid)) {
                if (existing) |lock| {
                    // Upgrade/downgrade same process or add shared lock
                    if (lock.owner_pid == owner_pid) {
                        // Same process: change lock type
                        lock.lock_type = lock_type;
                    } else {
                        // Shared lock: increment refcount
                        lock.refcount += 1;
                    }
                } else {
                    // New lock: allocate slot
                    const slot = self.findFreeSlot(bucket_idx) orelse {
                        held.release();
                        return error.ENOLCK; // Lock table full
                    };
                    slot.* = .{
                        .file_key = file_key,
                        .lock_type = lock_type,
                        .owner_pid = owner_pid,
                        .refcount = 1,
                        .wait_queue = .{},
                        .active = true,
                    };
                }
                held.release();
                return;
            }

            // Lock conflict - must wait or return
            if (nonblock) {
                held.release();
                return error.EAGAIN;
            }

            // Block on wait queue
            // SECURITY: Must release bucket_lock BEFORE blocking to avoid deadlock
            const wait_queue = &existing.?.wait_queue;
            sched.waitOn(wait_queue, held); // Releases lock, then blocks
            // Loop retries after wakeup
        }
    }

    /// Release a file lock
    pub fn release(self: *FlockManager, file_key: u64, owner_pid: u32) void {
        const bucket_idx = getBucketIndex(file_key);
        const held = self.bucket_locks[bucket_idx].acquire();
        defer held.release();

        const lock = self.findLock(bucket_idx, file_key) orelse return;

        // Only owner can release
        if (lock.owner_pid != owner_pid and lock.refcount > 1) {
            // Shared lock: decrement refcount
            lock.refcount -= 1;
            return;
        }

        // Remove lock
        lock.active = false;
        lock.file_key = 0;
        lock.refcount = 0;

        // Wake all waiters (they'll retry acquisition)
        _ = lock.wait_queue.wakeUp(std.math.maxInt(usize));
    }

    /// Release lock on file close (called by FD.unref)
    pub fn releaseOnClose(self: *FlockManager, file_key: u64) void {
        const bucket_idx = getBucketIndex(file_key);
        const held = self.bucket_locks[bucket_idx].acquire();
        defer held.release();

        const lock = self.findLock(bucket_idx, file_key) orelse return;

        // Decrement refcount (close releases one reference)
        if (lock.refcount > 1) {
            lock.refcount -= 1;
            return;
        }

        // Last reference: remove lock
        lock.active = false;
        lock.file_key = 0;
        lock.refcount = 0;

        // Wake all waiters
        _ = lock.wait_queue.wakeUp(std.math.maxInt(usize));
    }
};

/// Global flock manager instance
var g_flock_manager: FlockManager = undefined;

/// Initialize flock manager
pub fn init() void {
    g_flock_manager = FlockManager.init();
    console.info("Flock: Initialized ({} locks, {} buckets)", .{ MAX_LOCKS, NUM_BUCKETS });
}

/// Acquire lock (public API)
pub fn acquire(file_key: u64, lock_type: u8, owner_pid: u32, nonblock: bool) !void {
    return g_flock_manager.acquire(file_key, lock_type, owner_pid, nonblock);
}

/// Release lock (public API)
pub fn release(file_key: u64, owner_pid: u32) void {
    g_flock_manager.release(file_key, owner_pid);
}

/// Release on close (public API)
pub fn releaseOnClose(file_key: u64) void {
    g_flock_manager.releaseOnClose(file_key);
}
