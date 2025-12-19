const std = @import("std");
const thread_mod = @import("thread"); // src/kernel/thread.zig
const cpu = @import("cpu.zig");
const sched_mod = @import("scheduler.zig"); // Circular, needed for lock

const Thread = thread_mod.Thread;

/// Generic Wait Queue for sleep/wakeup
/// Used by futexes, semaphores, helper threads, etc.
pub const WaitQueue = struct {
    head: ?*Thread = null,
    tail: ?*Thread = null,
    count: usize = 0,

    /// Add current thread to queue and sleep
    /// Must be called with a spinlock held (passed via lock_guard)
    /// The lock is released AFTER thread state is set to Blocking but BEFORE scheduling.
    /// Returns: 0 on wakeup, EINTR if interrupted
    // Function exists in sched (waitOn) for better encapsulation of halting logic

    /// Thread-safe wakeup of N threads
    /// Returns: number of threads woken
    ///
    /// LOCK ORDERING (SECURITY CRITICAL):
    ///   - Caller MUST hold the queue's protecting lock (e.g., futex bucket lock)
    ///   - Caller MUST NOT hold scheduler.lock (this function acquires it internally)
    ///   - Lock order: bucket_lock -> scheduler.lock (enforced by this function)
    ///
    /// This function acquires scheduler.lock internally for each thread woken,
    /// following the documented lock ordering to prevent deadlocks.
    pub fn wakeUp(self: *WaitQueue, count: usize) u32 {
        // SECURITY: This function must be called with the queue's lock held
        // (usually the futex bucket lock) but WITHOUT scheduler.lock held.
        // We acquire scheduler.lock for each wakeup to maintain lock order.
        var woken: u32 = 0;
        while (woken < count) {
            if (self.pop()) |t| {
                // Add to ready queue (requires global scheduler lock)
                // SECURITY: Acquire scheduler.lock AFTER bucket lock per lock order
                {
                    const held = sched_mod.scheduler.lock.acquire();
                    defer held.release();
                    cpu.addToReadyQueue(t);
                }
                woken += 1;
            } else {
                break;
            }
        }
        return woken;
    }

    /// Append thread to queue (internal)
    /// Uses wait_queue_next/prev for doubly-linked list (separate from sleep list)
    pub fn append(self: *WaitQueue, t: *Thread) void {
        t.wait_queue_next = null;
        t.wait_queue_prev = self.tail;
        if (self.tail) |tail| {
            tail.wait_queue_next = t;
        } else {
            self.head = t;
        }
        self.tail = t;
        self.count += 1;
    }

    /// Pop thread from head
    /// Public so futex.wake() can directly pop threads
    pub fn pop(self: *WaitQueue) ?*Thread {
        if (self.head) |h| {
            self.head = h.wait_queue_next;
            if (self.head) |new_head| {
                new_head.wait_queue_prev = null;
            } else {
                self.tail = null;
            }
            h.wait_queue_next = null;
            h.wait_queue_prev = null;
            self.count -= 1;
            return h;
        }
        return null;
    }

    /// Remove a specific thread from the queue (for timeout cancellation)
    /// Returns true if thread was found and removed, false otherwise
    pub fn removeThread(self: *WaitQueue, target: *Thread) bool {
        // Verify thread is actually in this queue by checking if it's the head
        // or has a prev pointer set
        if (target.wait_queue_prev == null and self.head != target) {
            return false; // Not in queue
        }

        // Unlink from prev
        if (target.wait_queue_prev) |prev| {
            prev.wait_queue_next = target.wait_queue_next;
        } else {
            self.head = target.wait_queue_next;
        }

        // Unlink from next
        if (target.wait_queue_next) |next| {
            next.wait_queue_prev = target.wait_queue_prev;
        } else {
            self.tail = target.wait_queue_prev;
        }

        target.wait_queue_next = null;
        target.wait_queue_prev = null;
        self.count -= 1;
        return true;
    }
};
