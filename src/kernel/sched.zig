// Scheduler - Preemptive Round-Robin Thread Scheduler
//
// Manages thread execution via timer-driven preemption.
// Uses a simple round-robin algorithm with a doubly-linked ready queue.
//
// Design:
//   - Global scheduler state protected by spinlock
//   - Timer IRQ (vector 32) triggers tick() which may switch threads
//   - Context switch saves/restores interrupt frame on kernel stack
//   - Idle thread runs when no other threads are ready
//
// Context Switch Flow:
//   1. Timer IRQ fires, isr_common saves all GPRs
//   2. dispatch_interrupt calls irqHandler
//   3. irqHandler case 0 (timer) calls sched.timerTick(frame)
//   4. timerTick may switch to another thread by returning new frame pointer
//   5. dispatch_interrupt returns new frame pointer to isr_common
//   6. isr_common pops GPRs from new stack and iretq to new thread

const std = @import("std");
const hal = @import("hal");
const thread = @import("thread");
const sync = @import("sync");
const console = @import("console");
const config = @import("config");
const list = @import("list");
const kernel_stack = @import("kernel_stack");

/// Maximum number of CPUs supported (from GDT)
const MAX_CPUS = hal.gdt.MAX_CPUS;

/// Maximum number of threads tracked for TID lookup
const MAX_TRACKED_THREADS: usize = 256;

/// Global thread tracking array for TID lookup
/// Protected by scheduler.lock
var all_threads: [MAX_TRACKED_THREADS]?*Thread = [_]?*Thread{null} ** MAX_TRACKED_THREADS;

/// Per-CPU scheduler data
/// Each CPU has its own ready queue for cache locality and reduced contention.
///
/// SYNCHRONIZATION: All queue operations are protected by the GLOBAL scheduler.lock,
/// not per-CPU locks. This simplifies the design and avoids complex lock ordering.
/// The global lock is already held by all callers (timerTick, addThread, unblock, etc.).
/// Work stealing is safe because only one CPU can hold scheduler.lock at a time.
///
/// LOCK ORDERING (SECURITY CRITICAL - prevents deadlock):
///   1. process_tree_lock (RwLock) - highest level, protects process hierarchy
///   2. futex_bucket_lock / wait_queue_lock - protects futex hash buckets / wait queues
///   3. scheduler.lock (Spinlock) - protects scheduler state, ready queues
///   4. cpu_sched[i].lock (Spinlock) - protects per-CPU ready queue
///
/// IMPORTANT: WaitQueue.wakeUp() acquires scheduler.lock internally.
/// Callers MUST NOT hold scheduler.lock when calling wakeUp().
/// Callers SHOULD hold their wait queue's bucket lock when calling wakeUp().
///
/// Example correct usage:
///   bucket_lock.acquire()
///   wait_queue.wakeUp(1)    // This acquires scheduler.lock internally
///   bucket_lock.release()
///
/// Example INCORRECT (DEADLOCK):
///   scheduler.lock.acquire()
///   bucket_lock.acquire()     // Lock order violation!
///   wait_queue.wakeUp(1)      // Tries to acquire scheduler.lock again
pub const CpuSchedulerData = struct {
    /// Ready queue for this CPU (protected by this struct's lock)
    ready_queue: list.IntrusiveDoublyLinkedList(Thread) = .{},

    /// Lock protecting THIS specific CPU's data (ready_queue)
    /// LOCK ORDER: process_tree_lock -> bucket_lock -> scheduler.lock -> cpu_sched[i].lock
    lock: sync.Spinlock = .{},

    /// CPU ID (APIC ID)
    cpu_id: u32 = 0,

    /// Whether this CPU has been initialized
    initialized: bool = false,
};

/// Per-CPU scheduler data array
var cpu_sched: [MAX_CPUS]CpuSchedulerData = [_]CpuSchedulerData{.{}} ** MAX_CPUS;

/// Number of active CPUs (BSP + booted APs)
var active_cpu_count: u32 = 1; // Start with BSP

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
    // Function moved to sched.waitOn(queue, lock) for better encapsulation
    
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
                    const held = scheduler.lock.acquire();
                    defer held.release();
                    addToReadyQueue(t);
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
    fn append(self: *WaitQueue, t: *Thread) void {
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

/// Thread exit cleanup callback type
/// Called during exitWithStatus to clean up thread resources
pub const ThreadExitCallback = *const fn (*Thread) void;

/// Registered exit cleanup callbacks (set by syscall modules)
var exit_callbacks: [4]?ThreadExitCallback = [_]?ThreadExitCallback{null} ** 4;

/// Register a callback to be called when a thread exits.
/// Used by syscall modules to clean up thread-specific state.
/// SECURITY: Protected by scheduler.lock to prevent race when multiple
/// subsystems register callbacks concurrently during initialization.
pub fn registerExitCallback(cb: ThreadExitCallback) void {
    const held = scheduler.lock.acquire();
    defer held.release();

    for (&exit_callbacks) |*slot| {
        if (slot.* == null) {
            slot.* = cb;
            return;
        }
    }
    // No slots available - should not happen with current usage
}

pub const Thread = thread.Thread;
const ThreadState = thread.ThreadState;
const gdt = hal.gdt;
const fpu = hal.fpu;

/// Scheduler state
/// All fields protected by the scheduler lock
///
/// SECURITY AUDIT: Lock ordering - these locks protect separate data structures
/// and are not typically acquired together. If both are needed, acquire
/// process_tree_lock BEFORE scheduler.lock to prevent deadlock.
///
/// Process tree lock (moved here to avoid circular dep with sync/process)
pub var process_tree_lock: sync.RwLock = .{};

/// Global scheduler instance
var scheduler = Scheduler{};

/// Scheduler internal state structure
/// NOTE: ready_queue is now per-CPU (see CpuSchedulerData above)
const Scheduler = struct {
    // Current thread is now per-CPU, stored in GS data
    // Ready queue is now per-CPU (see cpu_sched array)

    /// Sorted sleep list head (wake_time ascending)
    /// Still global - checked by all CPUs on timer tick
    sleep_head: ?*Thread = null,

    /// System tick counter (incremented on each timer IRQ)
    tick_count: u64 = 0,

    /// Scheduler lock - must be held when modifying scheduler state
    /// SECURITY AUDIT: This lock protects ready_queue, sleep_head, tick_count,
    /// and thread state transitions. Always acquired after process_tree_lock
    /// if both are needed. Safe to acquire from IRQ context.
    lock: sync.Spinlock = .{},

    /// Is the scheduler running? (false until start() is called)
    running: bool = false,

    /// Callback function to be called on every timer tick
    tick_callback: ?*const fn () void = null,
};

/// Set the timer tick callback function
pub fn setTickCallback(callback: *const fn () void) void {
    const held = scheduler.lock.acquire();
    defer held.release();
    scheduler.tick_callback = callback;
}

/// Get current CPU index (clamped to valid range)
fn getCurrentCpuIndex() usize {
    const apic_id = hal.apic.lapic.getId();
    if (apic_id >= MAX_CPUS) return 0;
    return @intCast(apic_id);
}

/// Get per-CPU scheduler data for current CPU
fn getLocalCpuSched() *CpuSchedulerData {
    return &cpu_sched[getCurrentCpuIndex()];
}

/// Get per-CPU scheduler data for a specific CPU
fn getCpuSched(cpu_id: usize) *CpuSchedulerData {
    if (cpu_id >= MAX_CPUS) return &cpu_sched[0];
    return &cpu_sched[cpu_id];
}

/// Cancel a thread's futex timeout and add to ready queue
/// Used by futex.wake() to properly handle threads with pending timeouts
/// Caller MUST hold the futex bucket lock
pub fn cancelTimeoutAndWake(t: *Thread) void {
    const held = scheduler.lock.acquire();
    defer held.release();

    // Check if thread is still blocked (might have been woken by timeout)
    if (t.state != .Blocked) {
        // Thread was already woken (by timeout), don't add again
        return;
    }

    // Cancel pending timeout if set
    if (t.wake_time != 0) {
        removeFromSleepList(t);
    }

    // Clear futex state
    t.futex_bucket = null;
    t.futex_wakeup_reason = .woken;

    addToReadyQueue(t);
}

/// Add a thread to the back of the ready queue (per-CPU)
/// Thread is added to:
/// 1. Its last CPU's queue (for cache locality) if valid
/// 2. Otherwise, the current CPU's queue
fn addToReadyQueue(t: *Thread) void {
    t.state = .Ready;

    // Determine target CPU based on affinity and last_cpu
    var target_cpu: usize = getCurrentCpuIndex();

    // Prefer the CPU this thread last ran on for cache locality
    if (t.last_cpu < MAX_CPUS and cpu_sched[t.last_cpu].initialized) {
        // Check affinity allows this CPU
        if (t.cpu_affinity == 0xFFFFFFFF or (t.cpu_affinity & (@as(u32, 1) << @intCast(t.last_cpu)) != 0)) {
            target_cpu = t.last_cpu;
        }
    }

    // Add to target CPU's queue
    const cpu_data = &cpu_sched[target_cpu];
    
    // Acquire per-CPU lock
    const held = cpu_data.lock.acquire();
    defer held.release();

    cpu_data.ready_queue.append(t);

    if (config.debug_scheduler) {
        console.debug("Sched: Added '{s}' (tid={d}) to CPU {d} queue (count={d})", .{
            t.getName(),
            t.tid,
            target_cpu,
            cpu_data.ready_queue.count,
        });
    }
}

/// Remove and return the thread at the front of the local CPU's ready queue
/// If local queue is empty, attempts work stealing from other CPUs
fn removeFromReadyQueue() ?*Thread {
    const my_cpu = getCurrentCpuIndex();
    const my_data = &cpu_sched[my_cpu];

    // First try local queue
    {
        const held = my_data.lock.acquire();
        defer held.release();

        if (my_data.ready_queue.popFirst()) |t| {
            if (config.debug_scheduler) {
                console.debug("Sched: Removed '{s}' (tid={d}) from CPU {d} queue (count={d})", .{
                    t.getName(),
                    t.tid,
                    my_cpu,
                    my_data.ready_queue.count,
                });
            }
            return t;
        }
    }

    // Local queue empty - try work stealing from other CPUs
    return stealFromOtherCpu(my_cpu);
}

/// Try to steal a thread from another CPU's queue
/// Returns null if no work available on any CPU
fn stealFromOtherCpu(my_cpu: usize) ?*Thread {
    // SECURITY: Atomically load cpu count to avoid tearing if AP is initializing
    const cpu_count = @atomicLoad(u32, &active_cpu_count, .acquire);

    // Simple round-robin stealing starting from next CPU
    var victim = (my_cpu + 1) % cpu_count;
    var attempts: u32 = 0;

    while (attempts < cpu_count) : (attempts += 1) {
        if (victim != my_cpu and cpu_sched[victim].initialized) {
            const victim_data = &cpu_sched[victim];

            // Try to acquire lock - skip if busy to avoid contention/deadlock
            if (victim_data.lock.tryAcquire()) |held| {
                defer held.release();

                // Try to steal from back of queue (LIFO for cache locality)
                if (victim_data.ready_queue.popLast()) |t| {
                    // Check if thread's affinity allows running on our CPU
                    if (t.cpu_affinity == 0xFFFFFFFF or (t.cpu_affinity & (@as(u32, 1) << @intCast(my_cpu)) != 0)) {
                        if (config.debug_scheduler) {
                            console.debug("Sched: Stole '{s}' (tid={d}) from CPU {d} to CPU {d}", .{
                                t.getName(),
                                t.tid,
                                victim,
                                my_cpu,
                            });
                        }
                        return t;
                    } else {
                        // Put it back - we can't run this thread
                        victim_data.ready_queue.append(t);
                    }
                }
            }
        }
        victim = (victim + 1) % MAX_CPUS;
    }

    return null;
}

/// Insert a thread into the sorted sleep list
///
/// The list is sorted by wake_time in ascending order.
/// This allows O(1) checking of the head for expired timers.
///
/// Arguments:
///   t: Thread to insert (must have wake_time set)
fn insertSleepThread(t: *Thread) void {
    t.sleep_next = null;
    t.sleep_prev = null;

    if (scheduler.sleep_head) |head| {
        if (t.wake_time <= head.wake_time) {
            t.sleep_next = head;
            head.sleep_prev = t;
            scheduler.sleep_head = t;
            return;
        }

        var cursor = head;
        while (cursor.sleep_next) |next| {
            if (t.wake_time <= next.wake_time) {
                t.sleep_next = next;
                t.sleep_prev = cursor;
                next.sleep_prev = t;
                cursor.sleep_next = t;
                return;
            }
            cursor = next;
        }

        cursor.sleep_next = t;
        t.sleep_prev = cursor;
    } else {
        scheduler.sleep_head = t;
    }
}

/// Wait on a queue until woken up
///
/// Arguments:
///   queue: The wait queue to sleep on
///   lock_held: The spinlock protecting the condition/queue (already acquired)
///
/// The lock is released Atomically with putting the thread to sleep to prevent missed wakeups.
pub fn waitOn(queue: *WaitQueue, lock_held: sync.Spinlock.Held) void {
    // 1. Get current thread
    const current = getCurrentThread() orelse return;

    // 2. Acquire scheduler lock (to modify state)
    // Lock Order: lock_held (Bucket) -> Scheduler Lock
    const sched_held = scheduler.lock.acquire();

    // 3. Add to wait queue
    queue.append(current);
    current.state = .Blocked;
    
    // 4. Release external lock (Bucket) -> we are now protected by scheduler lock and state=Blocked
    lock_held.release();

    // 5. Release scheduler lock and trigger synchronous switch
    // Note: Interrupts are enabled by release() if they were enabled before acquire()
    sched_held.release();
    schedule_sync();

    // 6. Returned from sleep
}

/// Wait on a queue with timeout support
/// Like waitOn, but also adds thread to sleep list for timeout handling.
///
/// Arguments:
///   queue: Wait queue to sleep on
///   lock_held: The spinlock protecting the condition/queue (already acquired)
///   timeout_ticks: Number of ticks to wait before timeout (0 = no timeout)
///   futex_bucket_ptr: Opaque pointer to futex bucket for timeout handling
pub fn waitOnWithTimeout(
    queue: *WaitQueue,
    lock_held: sync.Spinlock.Held,
    timeout_ticks: u64,
    futex_bucket_ptr: ?*anyopaque,
) void {
    const current = getCurrentThread() orelse return;

    const sched_held = scheduler.lock.acquire();

    // Add to wait queue
    queue.append(current);
    current.state = .Blocked;

    // Setup timeout if specified
    if (timeout_ticks > 0) {
        // Use saturating add to prevent overflow
        current.wake_time = scheduler.tick_count +| timeout_ticks;
        current.futex_bucket = futex_bucket_ptr;
        current.futex_wakeup_reason = .none;
        insertSleepThread(current);
    } else {
        current.wake_time = 0;
        current.futex_bucket = null;
        current.futex_wakeup_reason = .none;
    }

    // Release external lock (bucket lock)
    lock_held.release();

    sched_held.release();
    schedule_sync();

    // Returned from sleep
}

/// Internal schedule function for synchronous switching
fn schedule_sync() void {
    // Trigger scheduler interrupt (vector 32)
    // This pushes valid interrupt frame, calls timerTick/schedule, switches or returns.
    asm volatile ("int $32");
}
/// Remove a thread from the sleep list
/// Public so futex.wake() can cancel pending timeouts
/// MUST be called with scheduler.lock held
pub fn removeFromSleepList(t: *Thread) void {
    if (t.sleep_prev) |prev| {
        prev.sleep_next = t.sleep_next;
    } else if (scheduler.sleep_head == t) {
        scheduler.sleep_head = t.sleep_next;
    }

    if (t.sleep_next) |next| {
        next.sleep_prev = t.sleep_prev;
    }

    t.sleep_next = null;
    t.sleep_prev = null;
    t.wake_time = 0;
}

/// Wake up threads whose sleep timer has expired
///
/// Checks the head of the sorted sleep list against the current tick count.
/// If wake_time <= now, the thread is removed from the list and added to the ready queue.
///
/// For futex waiters (futex_bucket != null), also removes from the wait queue
/// and sets wakeup reason to .timeout
///
/// SECURITY: For futex waiters, we must acquire the bucket lock to safely remove
/// the thread from the wait queue before adding to ready queue. If we cannot
/// acquire the lock (another CPU holds it), we MUST NOT add the thread to the
/// ready queue - this would leave it in both queues, causing list corruption
/// when the thread later calls futex.wait() on a different address.
fn wakeSleepingThreads(now: u64) void {
    const futex = @import("futex");

    while (scheduler.sleep_head) |t| {
        if (t.wake_time > now) break;
        removeFromSleepList(t);

        // Check if this is a futex waiter with timeout
        if (t.futex_bucket) |bucket_ptr| {
            const bucket = futex.getBucketFromOpaque(bucket_ptr);

            // Try to acquire bucket lock to remove from wait queue.
            // LOCK ORDER: We hold scheduler.lock but need bucket.lock.
            // Normal order is bucket.lock -> scheduler.lock (see WaitQueue.wakeUp).
            // Using tryAcquire to avoid deadlock from lock order inversion.
            if (bucket.lock.tryAcquire()) |held| {
                defer held.release();
                // Successfully acquired lock - safe to remove from wait queue
                _ = bucket.queue.removeThread(t);
                t.futex_wakeup_reason = .timeout;
                t.futex_bucket = null;
                // Fall through to add to ready queue below
            } else {
                // SECURITY FIX: Cannot acquire bucket lock - another CPU holds it.
                // We MUST NOT add thread to ready queue while it's still in the
                // wait queue. If we did, the thread would be in both queues:
                //   1. Thread gets scheduled from ready queue, returns from futex.wait()
                //   2. Thread calls futex.wait() on different address
                //   3. New futex.wait() overwrites wait_queue_next/prev pointers
                //   4. Original bucket's WaitQueue is now corrupted
                //
                // Solution: Re-insert into sleep list with a short retry delay.
                // On the next tick, we'll try again to acquire the bucket lock.
                // If futex.wake() runs first, it will remove from wait queue and
                // call cancelTimeoutAndWake() which will remove from sleep list
                // and add to ready queue with .woken reason (correct behavior).
                t.wake_time = now + 1;
                insertSleepThread(t);
                continue; // Skip addToReadyQueue - thread is still in wait queue
            }
        }

        if (t.state == .Blocked) {
            addToReadyQueue(t);
        }
    }
}

/// Idle thread entry point - runs when no other threads are ready
/// Idle thread entry point - runs when no other threads are ready
fn idleThreadEntry(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    // Just enable interrupts and halt loop.
    // We rely on the timer interrupt to preempt us when work is available.
    hal.cpu.enableInterrupts();
    while (true) {
        hal.cpu.halt();
    }
}


/// Set the per-CPU kernel GS data pointer
/// Called by main.zig during initialization before scheduler starts
/// This pointer is used to update kernel_stack on context switch for SYSCALL
/// Deprecated in SMP: GS data is managed per-CPU
pub fn setGsData(_: *hal.syscall.KernelGsData) void {
    // scheduler.gs_data = gs_data; // No longer used globally
}

/// Handle RESCHEDULE IPI from another CPU
/// This handler runs when another CPU sends us a reschedule request
/// (e.g., after unblocking a thread that should run on this CPU).
///
/// The IPI serves two purposes:
/// 1. Wake the CPU if it's halted (idle loop)
/// 2. Signal that a high-priority thread may be waiting
///
/// We don't need to do anything special here - the thread is already
/// in our ready queue. The next timer tick will schedule it. The IPI
/// just ensures we wake up if halted rather than waiting for the timer.
fn handleRescheduleIpi(frame: *hal.idt.InterruptFrame) void {
    _ = frame;
    // No action needed - the IPI wakes the CPU from halt state
    // and the thread is already in our ready queue.
    // The timer tick will handle the actual context switch.
    if (config.debug_scheduler) {
        console.debug("Sched: CPU {d} received RESCHEDULE IPI", .{getCurrentCpuIndex()});
    }
}

/// Initialize the scheduler (BSP)
/// Must be called after memory management is initialized
pub fn init() void {
    console.info("Sched: Initializing scheduler...", .{});

    // Initialize per-CPU scheduler data for BSP (CPU 0)
    const cpu_id = getCurrentCpuIndex();
    cpu_sched[cpu_id].cpu_id = @intCast(cpu_id);
    cpu_sched[cpu_id].initialized = true;
    active_cpu_count = 1;

    // Register timer handler for preemptive scheduling
    hal.interrupts.setTimerHandler(timerTick);

    // Register guard page checker for stack overflow detection
    hal.interrupts.setGuardPageChecker(guardPageCheckerCallback);

    // Register FPU access handler for lazy FPU switching
    hal.interrupts.setFpuAccessHandler(handleFpuAccess);

    // Register RESCHEDULE IPI handler for cross-core wakeups
    hal.apic.ipi.registerHandler(.reschedule, handleRescheduleIpi);

    // Create the idle thread for BSP
    initIdleThread();

    console.info("Sched: Initialized (BSP, CPU {d})", .{cpu_id});
}

/// Initialize idle thread for current CPU
fn initIdleThread() void {
    const idle = thread.createKernelThread(idleThreadEntry, null, .{
        .name = "idle",
        .stack_size = 4096, // Idle thread needs minimal stack
    }) catch |err| {
        console.err("Sched: Failed to create idle thread: {}", .{err});
        hal.cpu.haltForever();
    };

    // Store idle thread in GS data
    // We access GS via MSR or assumption that it's already set up
    // In BSP init, main.zig sets up GS before calling sched.init()
    //
    // SECURITY AUDIT: GS base manipulation requires Ring 0 (CPL=0).
    // Userspace cannot access IA32_GS_BASE MSR. SWAPGS in syscall entry
    // properly separates user/kernel GS, preventing userspace attacks.
    const gs_base = hal.cpu.readMsr(hal.cpu.IA32_GS_BASE);
    const gs_data = @as(*hal.syscall.KernelGsData, @ptrFromInt(gs_base));
    gs_data.idle_thread = @intFromPtr(idle);
    gs_data.current_thread = 0; // No current thread yet

    console.info("Sched: Idle thread created for CPU {d} (tid={d})", .{gs_data.apic_id, idle.tid});
}

/// Initialize Scheduler for AP
pub fn initAp() void {
    // Initialize per-CPU scheduler data for this AP
    const cpu_id = getCurrentCpuIndex();
    cpu_sched[cpu_id].cpu_id = @intCast(cpu_id);
    cpu_sched[cpu_id].initialized = true;

    // Atomically increment active CPU count
    _ = @atomicRmw(u32, &active_cpu_count, .Add, 1, .seq_cst);

    // Initialize idle thread for this AP
    initIdleThread();

    // console.info("Sched: Initialized (AP, CPU {d})", .{cpu_id});
}


/// Callback wrapper for guard page checker
/// This wraps checkGuardPage to match the HAL callback signature
fn guardPageCheckerCallback(fault_addr: u64) ?hal.interrupts.GuardPageInfo {
    // Call our internal checkGuardPage and convert the result
    if (checkGuardPage(fault_addr)) |info| {
        return hal.interrupts.GuardPageInfo{
            .thread_id = info.thread_id,
            .thread_name = info.thread_name,
            .stack_base = info.stack_base,
            .stack_top = info.stack_top,
        };
    }
    return null;
}

/// Add a thread to the scheduler
/// Thread will be added to the ready queue and registered for TID lookup
pub fn addThread(t: *Thread) void {
    const held = scheduler.lock.acquire();
    defer held.release();

    // Register thread in global tracking array for TID lookup
    for (&all_threads) |*slot| {
        if (slot.* == null) {
            slot.* = t;
            break;
        }
    }

    addToReadyQueue(t);
}

/// Find a thread by its TID
/// Returns null if not found or if thread has exited
pub fn findThreadByTid(tid: u32) ?*Thread {
    const held = scheduler.lock.acquire();
    defer held.release();

    for (all_threads) |maybe_t| {
        if (maybe_t) |t| {
            if (t.tid == tid) {
                return t;
            }
        }
    }
    return null;
}

/// Unregister a thread from TID lookup (called when thread is destroyed)
pub fn unregisterThread(t: *Thread) void {
    const held = scheduler.lock.acquire();
    defer held.release();

    for (&all_threads) |*slot| {
        if (slot.* == t) {
            slot.* = null;
            break;
        }
    }
}

/// Start the scheduler (BSP only really, APs just enter loop)
/// This function does not return - it becomes the idle thread
pub fn start() noreturn {
    console.info("Sched: Starting scheduler on CPU {d}...", .{hal.apic.lapic.getId()});

    {
        const held = scheduler.lock.acquire();
        scheduler.running = true;
        held.release();
    }

    // Enable interrupts to allow timer ticks
    hal.cpu.enableInterrupts();

    // This thread becomes idle-like behavior until first preemption
    // The timer interrupt will eventually switch to a ready thread
    while (true) {
        hal.cpu.halt();
    }
}

/// Start scheduler on AP
pub fn startAp() noreturn {
    // Enable interrupts
    hal.cpu.enableInterrupts();
    while (true) {
        hal.cpu.halt();
    }
}

/// Get the currently running thread for the current CPU
pub fn getCurrentThread() ?*Thread {
    // Read from GS:current_thread
    // We use inline asm to read %gs:16 directly for speed
    // GS base points to KernelGsData.
    // 0: kernel_stack
    // 8: user_stack
    // 16: current_thread

    const ptr = asm volatile ("movq %%gs:16, %[ret]"
        : [ret] "=r" (-> u64),
    );

    if (ptr == 0) return null;
    return @ptrFromInt(ptr);
}

/// Set the currently running thread for the current CPU
fn setCurrentThread(t: ?*Thread) void {
    const val = if (t) |thread_ptr| @intFromPtr(thread_ptr) else 0;
    asm volatile ("movq %[val], %%gs:16"
        :
        : [val] "r" (val),
    );
}

/// Get idle thread for current CPU
fn getIdleThread() *Thread {
    // idle_thread is at offset 40 in KernelGsData
    const ptr = asm volatile ("movq %%gs:40, %[ret]"
        : [ret] "=r" (-> u64),
    );
    return @ptrFromInt(ptr);
}

/// Get the current tick count
pub fn getTickCount() u64 {
    return scheduler.tick_count;
}

/// Yield the current thread's remaining time slice
/// The thread remains ready and will be rescheduled
///
/// IMPORTANT: This function atomically enables interrupts and halts.
/// This is required because syscalls run with IF=0 (Big Kernel Lock).
/// Without enabling interrupts, the timer IRQ cannot fire to trigger
/// a context switch, causing a deadlock.
///
/// SAFETY: Calling yield() while holding spinlocks will cause deadlock.
/// In debug builds, this is detected and panics.
pub fn yield() void {
    const current = getCurrentThread();

    // Debug check: detect yield while holding locks (deadlock prevention)
    // Debug check: detect yield while holding locks (deadlock prevention)
    // CRITICAL: Always check this, even in release builds, to prevent silent deadlocks.
    if (current) |t| {
        if (t.lock_depth > 0) {
            console.err("PANIC: yield() called with {d} lock(s) held by thread '{s}' (tid={d})", .{
                t.lock_depth,
                t.getName(),
                t.tid,
            });
            @panic("yield with spinlocks held - deadlock");
        }
    }

    // Atomically enable interrupts and halt (STI; HLT sequence)
    // The timer IRQ will fire, call timerTick(), and potentially
    // switch to another thread. When we're scheduled again,
    // execution resumes after this call.
    hal.cpu.enableAndHalt();
}

/// Block the current thread
/// Thread will not be scheduled until explicitly unblocked via unblock()
///
/// SECURITY AUDIT: This function is designed to be race-free with unblock().
/// The pending_wakeup flag handles the case where unblock() is called before
/// we halt. All state transitions happen under the scheduler lock.
///
/// IMPORTANT: This function sets the thread state to Blocked, then atomically
/// enables interrupts and halts. The next timer tick will context-switch to
/// another thread. Because state is Blocked, this thread will NOT be added
/// to the ready queue. It will only run again after unblock() is called.
///
/// This is required because syscalls run with IF=0 (Big Kernel Lock).
/// Without enabling interrupts and halting, the timer IRQ cannot fire,
/// causing a deadlock.
pub fn block() void {
    const current = getCurrentThread();

    {
        const held = scheduler.lock.acquire();
        defer held.release();

        if (current) |curr| {
            // SECURITY: Check pending_wakeup FIRST under lock.
            // If unblock() was called before we got here, consume the wakeup
            // and return immediately without blocking. This prevents the
            // TOCTOU race where unblock() runs between lock release and halt.
            if (curr.pending_wakeup) {
                curr.pending_wakeup = false;
                if (config.debug_scheduler) {
                    console.debug("Sched: Thread '{s}' (tid={d}) consumed pending wakeup", .{
                        curr.getName(),
                        curr.tid,
                    });
                }
                return; // Don't block - wakeup already arrived
            }

            removeFromSleepList(curr);
            curr.state = .Blocked;
            curr.wake_time = 0;

            if (config.debug_scheduler) {
                console.debug("Sched: Thread '{s}' (tid={d}) blocked", .{
                    curr.getName(),
                    curr.tid,
                });
            }
        }
    }

    // SECURITY: After releasing the lock, we are committed to halting.
    // If unblock() runs now, it will add us to the ready queue and we'll
    // be scheduled on the next timer tick after the halt. The timer IRQ
    // will fire and timerTick() will:
    //   1. Save our context (kernel_rsp)
    //   2. See state == .Blocked, so NOT add us to ready queue
    //   3. Switch to another thread
    // When unblock() is called on us, we're added to ready queue.
    // When scheduled again, execution resumes after this halt.
    hal.cpu.enableAndHalt();
}

/// Determine target CPU for a thread based on affinity and last_cpu
/// Returns the CPU index where the thread should run
fn getTargetCpu(t: *const Thread) usize {
    const current_cpu = getCurrentCpuIndex();

    // Prefer the CPU this thread last ran on for cache locality
    if (t.last_cpu < MAX_CPUS and cpu_sched[t.last_cpu].initialized) {
        // Check affinity allows this CPU
        if (t.cpu_affinity == 0xFFFFFFFF or (t.cpu_affinity & (@as(u32, 1) << @intCast(t.last_cpu)) != 0)) {
            return t.last_cpu;
        }
    }

    return current_cpu;
}

/// Unblock a thread
/// Thread will be added to the ready queue
///
/// SECURITY AUDIT: Safe to call from any context (IRQ, other CPU).
/// If thread is Blocked, it's added to ready queue immediately.
/// If thread hasn't blocked yet (Running), pending_wakeup is set so
/// block() will return immediately without halting.
/// This prevents the TOCTOU race in block()/unblock() synchronization.
///
/// SMP: If the target CPU differs from current CPU, a RESCHEDULE IPI is sent
/// to ensure the target CPU schedules the woken thread promptly.
pub fn unblock(t: *Thread) void {
    const held = scheduler.lock.acquire();
    defer held.release();

    if (t.state == .Blocked) {
        // Thread is blocked - wake it up normally
        removeFromSleepList(t);

        // Determine target CPU before adding to queue
        const target_cpu = getTargetCpu(t);
        const current_cpu = getCurrentCpuIndex();

        addToReadyQueue(t);

        if (config.debug_scheduler) {
            console.debug("Sched: Thread '{s}' (tid={d}) unblocked -> CPU {d}", .{
                t.getName(),
                t.tid,
                target_cpu,
            });
        }

        // Send RESCHEDULE IPI if target is different CPU
        // This ensures the target CPU picks up the thread promptly
        if (target_cpu != current_cpu and cpu_sched[target_cpu].initialized) {
            const target_apic_id = cpu_sched[target_cpu].cpu_id;
            hal.apic.ipi.sendTo(target_apic_id, .reschedule);

            if (config.debug_scheduler) {
                console.debug("Sched: Sent RESCHEDULE IPI to CPU {d}", .{target_cpu});
            }
        }
    } else if (t.state == .Running) {
        // SECURITY: Thread hasn't blocked yet - set pending wakeup flag.
        // block() will check this flag under lock and return immediately
        // instead of halting, preventing missed wakeup race condition.
        t.pending_wakeup = true;
        if (config.debug_scheduler) {
            console.debug("Sched: Thread '{s}' (tid={d}) set pending_wakeup (state=Running)", .{
                t.getName(),
                t.tid,
            });
        }
    }
    // If state is Ready or Zombie, do nothing - thread is already runnable or dead
}

/// Wake up a thread and assign it to a specific CPU
/// This updates the thread's affinity to pin it to the target CPU
pub fn wakeOnCpu(t: *Thread, cpu_id: u32) void {
    if (cpu_id >= MAX_CPUS) return;

    {
        // Lock to ensure state consistency while modifying thread
        const held = scheduler.lock.acquire();
        defer held.release();

        t.cpu_affinity = @as(u32, 1) << @intCast(cpu_id);
        t.last_cpu = cpu_id;
    }

    // Now unblock it - unblock() will use the new affinity/last_cpu
    // to place it on the correct queue and send IPI if needed
    unblock(t);
}

/// Put the current thread to sleep until tick_count reaches the target
pub fn sleepForTicks(ticks: u64) void {
    if (ticks == 0) {
        return;
    }

    const current = getCurrentThread();

    {
        const held = scheduler.lock.acquire();
        defer held.release();

        if (current) |curr| {
            removeFromSleepList(curr);
            curr.state = .Blocked;
            // SECURITY AUDIT: Saturating arithmetic prevents overflow.
            // At 1000Hz tick rate, u64 overflow takes ~584 million years.
            // The saturation check ensures extremely long sleeps clamp to max.
            const max_tick: u64 = std.math.maxInt(u64);
            const wake_tick = if (ticks > max_tick - scheduler.tick_count)
                max_tick
            else
                scheduler.tick_count + ticks;
            curr.wake_time = wake_tick;
            insertSleepThread(curr);
        }
    }

    hal.cpu.enableAndHalt();
}

/// Exit the current thread (default status 0)
/// Thread will be marked as zombie and removed from scheduling
pub fn exit() void {
    exitWithStatus(0);
}

/// Exit the current thread with a specific exit status
/// Thread will be marked as zombie and parent will be woken if waiting
pub fn exitWithStatus(status: i32) void {
    const held = scheduler.lock.acquire();
    const current = getCurrentThread();

    if (current) |curr| {
        // SECURITY: Call registered exit callbacks to clean up thread-specific state.
        // This includes clearing IRQ waiter registrations to prevent use-after-free.
        for (exit_callbacks) |cb_opt| {
            if (cb_opt) |cb| {
                cb(curr);
            }
        }

        // Set exit status
        thread.setExitStatus(curr, status);

        // Handle CLONE_CHILD_CLEARTID
        // If clear_child_tid is set, write 0 to that address and wake up waiters.
        // This is used by pthread_join to detect thread exit.
        if (curr.clear_child_tid != 0) {
            // Need base/UserPtr for safe access
            const base = @import("base.zig");
            // SECURITY: Use isValidUserAccess with .Write mode for full validation.
            // The page might have been unmapped by the process between clone() and exit().
            // Using only bounds checking (isValidUserPtr) would cause a page fault
            // in kernel context if the page is no longer mapped.
            if (base.isValidUserAccess(curr.clear_child_tid, @sizeOf(i32), .Write)) {
                // Write 0 to the address
                base.UserPtr.from(curr.clear_child_tid).writeValue(@as(i32, 0)) catch |err| {
                    console.warn("Sched: Failed to clear TID at {x}: {}", .{ curr.clear_child_tid, err });
                };

                // Wake up any waiters (futex)
                const futex = @import("futex");
                // Wake 1 waiter (usually the joining thread)
                _ = futex.wake(curr.clear_child_tid, 1) catch {};
            } else {
                // Page no longer mapped - silently skip. This is not an error,
                // just means the process unmapped the memory before thread exit.
                if (config.debug_scheduler) {
                    console.debug("Sched: clear_child_tid {x} no longer writable", .{curr.clear_child_tid});
                }
            }
        }

        // Mark as zombie
        curr.state = .Zombie;
        setCurrentThread(null); // Clear current thread

        if (config.debug_scheduler) {
            console.info("Sched: Thread '{s}' (tid={d}) exited with status {d}", .{
                curr.getName(),
                curr.tid,
                status,
            });
        }

        // Wake parent if blocked in wait4
        if (curr.parent) |parent| {
            if (parent.state == .Blocked) {
                // Parent may be waiting for this child
                // Wake parent so it can check for zombies
                addToReadyQueue(parent);
                if (config.debug_scheduler) {
                    console.debug("Sched: Woke parent '{s}' (tid={d})", .{
                        parent.getName(),
                        parent.tid,
                    });
                }
            }
        }
    }

    held.release();

    // Force a reschedule - we can't continue with this thread
    // Wait for timer interrupt to switch us out
    hal.cpu.disableInterrupts();
    while (true) {
        hal.cpu.halt();
    }
}

/// Timer tick handler - called from IRQ0 handler
/// May perform a context switch if preemption is needed
/// Returns the (possibly new) interrupt frame pointer
///
/// frame: Pointer to the current thread's saved interrupt frame
/// Returns: Pointer to the frame to restore (same if no switch, different if switched)
pub fn timerTick(frame: *hal.idt.InterruptFrame) *hal.idt.InterruptFrame {
    // Acquire global scheduler lock
    // In SQMP, this protects the single ready queue.
    const held = scheduler.lock.acquire();
    defer held.release();

    scheduler.tick_count += 1;
    wakeSleepingThreads(scheduler.tick_count);

    if (scheduler.tick_count % 100 == 0) {
        // console.debug("Sched: Tick {d}", .{scheduler.tick_count});
    }

    // Call registered timer callback (e.g. for TCP timers)
    if (scheduler.tick_callback) |cb| {
        cb();
    }

    // Update VDSO time
    if (scheduler.tick_count % 10 == 0) {
        const vdso = @import("vdso");
        vdso.update();
    }

    // Don't schedule if scheduler isn't running yet
    if (!scheduler.running) {
        return frame;
    }

    // Log every 100 ticks to show scheduler is alive
    // if (scheduler.tick_count % 100 == 0) {
    //     console.debug("Tick {d}", .{scheduler.tick_count});
    // }

    const current = getCurrentThread();


    // Save current thread's context
    if (current) |curr| {
        // Save the interrupt frame location
        curr.kernel_rsp = @intFromPtr(frame);

        // SECURITY AUDIT: Lazy FPU provides proper isolation between threads.
        // FPU state is only saved if thread used FPU (fpu_used flag).
        // On switch-in, CR0.TS is set, triggering #NM on first FPU access.
        // The #NM handler restores the thread's saved FPU state.
        // This prevents FPU state leakage between threads.
        if (curr.fpu_used) {
            fpu.fxsave(&curr.fpu_state);
            // Keep fpu_used true so we know to restore on switch back
        }

        // If current thread is still running, put it back in ready queue
        if (curr.state == .Running) {
            addToReadyQueue(curr);
        }
    }

    // Select next thread to run
    // console.info("timerTick: ready_queue count={d}", .{scheduler.ready_queue.count});
    var next_thread = removeFromReadyQueue();

    // If no threads ready, use idle thread for THIS CPU
    if (next_thread == null) {
        // console.info("timerTick: no ready threads, using idle", .{});
        next_thread = getIdleThread();
        // Idle thread doesn't go in ready queue, just runs directly
    } else {
        // console.info("timerTick: got thread from queue '{s}'", .{next_thread.?.getName()});
    }

    // SECURITY AUDIT: Validate next_thread is non-null.
    // If getIdleThread() returned null (GS data corruption or init failure),
    // we must panic rather than dereference null. This catches:
    // - Missing idle thread initialization
    // - Corrupted GS base pointer
    // - Race during early boot before idle thread created
    if (next_thread == null) {
        console.panic("Sched: Failed to select next thread (Idle thread missing?)", .{});
    }

    const next = next_thread.?;
    // console.info("timerTick: next thread '{s}' state={} kernel_rsp={x}", .{
    //     next.getName(), @intFromEnum(next.state), next.kernel_rsp,
    // });

    // If switching to a different thread, update TSS and potentially CR3
    if (current != next) {
        if (config.debug_scheduler) {
            const curr_name = if (current) |c| c.getName() else "none";
            _ = curr_name; // Used when debug logging is enabled
            // console.debug("Sched: Switch {s} -> {s}", .{ curr_name, next.getName() });
        }

        // Update TSS.rsp0 for the new thread's kernel stack
        gdt.setKernelStack(next.kernel_stack_top);

        // Update kernel GS data for SYSCALL instruction
        // The syscall entry stub reads %gs:0 to get kernel stack
        // SECURITY AUDIT: GS base access requires Ring 0 (CPL=0).
        // Userspace cannot manipulate kernel GS. SWAPGS in syscall
        // entry provides proper user/kernel GS separation.
        const gs_base = hal.cpu.readMsr(hal.cpu.IA32_GS_BASE);
        const gs_data = @as(*hal.syscall.KernelGsData, @ptrFromInt(gs_base));
        gs_data.kernel_stack = next.kernel_stack_top;

        // Switch page tables if different (for userland threads)
        if (next.cr3 != 0) {
            const current_cr3 = hal.cpu.readCr3();
            if (next.cr3 != current_cr3) {
                hal.cpu.writeCr3(next.cr3);
            }
        }

        // Restore FS base for TLS (set by arch_prctl ARCH_SET_FS)
        // Optimization: Only write MSR if value actually changed
        // We must check against the PREVIOUS thread's FS base (curr), not 0.
        const current_fs = if (current) |c| c.fs_base else 0;
        if (next.fs_base != current_fs) {
            hal.cpu.writeMsr(hal.cpu.IA32_FS_BASE, next.fs_base);
        }

        // SECURITY AUDIT: Lazy FPU switching for state isolation.
        // Setting CR0.TS causes #NM on first FPU access by new thread.
        // The #NM handler (handleFpuAccess) then:
        //   1. Clears TS flag to allow FPU access
        //   2. Restores saved FPU state if thread previously used FPU
        //   3. Sets fpu_used=true to save state on next switch
        // This ensures FPU state is never leaked between threads.
        fpu.setTaskSwitched();

        // Reset fpu_used flag - will be set by #NM handler if thread uses FPU
        next.fpu_used = false;
    }

    // Track which CPU this thread is running on (for cache-aware scheduling)
    next.last_cpu = @intCast(getCurrentCpuIndex());

    next.state = .Running;
    setCurrentThread(next);

    // Return the new thread's saved interrupt frame
    // isr_common will pop registers from this location and iretq
    return @ptrFromInt(next.kernel_rsp);
}

/// Check if the scheduler is currently running
pub fn isRunning() bool {
    return scheduler.running;
}

/// Get statistics about the scheduler
pub const SchedulerStats = struct {
    tick_count: u64,
    ready_count: usize,
    is_running: bool,
    current_tid: ?u32,
};

pub fn getStats() SchedulerStats {
    const held = scheduler.lock.acquire();
    defer held.release();

    const current = getCurrentThread();

    // Sum all per-CPU ready queue counts
    // SECURITY: Atomic load even though we hold scheduler.lock for consistency
    const cpu_count = @atomicLoad(u32, &active_cpu_count, .acquire);
    var total_ready: usize = 0;
    for (cpu_sched[0..cpu_count]) |*cpu_data| {
        if (cpu_data.initialized) {
            // Acquire lock to ensure consistent count read
            const held_cpu = cpu_data.lock.acquire();
            defer held_cpu.release();
            total_ready += cpu_data.ready_queue.count;
        }
    }

    return .{
        .tick_count = scheduler.tick_count,
        .ready_count = total_ready,
        .is_running = scheduler.running,
        .current_tid = if (current) |c| c.tid else null,
    };
}

/// Guard page info type - matches HAL interrupts.GuardPageInfo
/// Re-exported here to avoid cross-layer imports
pub const GuardPageInfo = struct {
    thread_id: u32,
    thread_name: []const u8,
    stack_base: u64,
    stack_top: u64,
};

/// Check if a fault address is within a thread's guard page
/// Returns guard info if it is, null otherwise
/// This is called from the page fault handler to detect stack overflow
pub fn checkGuardPage(fault_addr: u64) ?GuardPageInfo {
    const current = getCurrentThread();

    // Check current thread first (most likely case)
    if (current) |curr| {
        if (isInGuardPage(fault_addr, curr)) {
            return GuardPageInfo{
                .thread_id = curr.tid,
                .thread_name = curr.getName(),
                .stack_base = curr.kernel_stack_base,
                .stack_top = curr.kernel_stack_top,
            };
        }
    }

    // Check idle thread (THIS CPU)
    // Note: checking other CPUs' idle threads would be complex
    const idle = getIdleThread();
    if (isInGuardPage(fault_addr, idle)) {
         return GuardPageInfo{
            .thread_id = idle.tid,
            .thread_name = idle.getName(),
            .stack_base = idle.kernel_stack_base,
            .stack_top = idle.kernel_stack_top,
        };
    }

    // Check all threads in per-CPU ready queues
    // SECURITY: Use tryAcquire to avoid UAF when another CPU modifies queues.
    // If we can't acquire a lock (contention or held during fault), skip that queue.
    // This is a diagnostic function - missing a thread is acceptable, UAF is not.
    //
    // Note: We use tryAcquire instead of acquire because:
    // 1. This runs in page fault context - blocking could cause deadlock
    // 2. The original thread causing the fault might hold a lock we need
    // 3. Skipping a queue is acceptable for diagnostics; UAF is not
    //
    // SECURITY: Atomic load to avoid tearing during AP initialization
    const cpu_count = @atomicLoad(u32, &active_cpu_count, .acquire);
    for (cpu_sched[0..cpu_count]) |*cpu_data| {
        if (!cpu_data.initialized) continue;

        // SECURITY: Try to acquire lock to prevent UAF from concurrent destroyThread
        // If lock is held, skip this queue - we're in fault context and can't block
        if (cpu_data.lock.tryAcquire()) |held| {
            defer held.release();

            var t = cpu_data.ready_queue.head;
            while (t) |curr_thread| {
                if (isInGuardPage(fault_addr, curr_thread)) {
                    return GuardPageInfo{
                        .thread_id = curr_thread.tid,
                        .thread_name = curr_thread.getName(),
                        .stack_base = curr_thread.kernel_stack_base,
                        .stack_top = curr_thread.kernel_stack_top,
                    };
                }
                t = curr_thread.next;
            }
        }
        // If tryAcquire failed, skip this queue - better than UAF
    }

    // Additional check: if fault is in kernel_stack region guard page
    // (for cases where thread lookup failed but it's still a stack overflow)
    if (kernel_stack.isGuardPage(fault_addr)) {
        if (kernel_stack.getStackInfoForGuardFault(fault_addr)) |info| {
            return GuardPageInfo{
                .thread_id = 0, // Unknown thread
                .thread_name = "<unknown>",
                .stack_base = info.stack_base,
                .stack_top = info.stack_top,
            };
        }
    }

    return null;
}

/// Check if an address is in a thread's guard page
/// Guard page is the page at kernel_stack_base (one page below actual stack)
fn isInGuardPage(addr: u64, t: *const Thread) bool {
    const page_size: u64 = 4096; // Use constant to avoid import
    // Guard page starts at kernel_stack_base and is page_size bytes
    return addr >= t.kernel_stack_base and addr < t.kernel_stack_base + page_size;
}

/// Handle #NM (Device Not Available) exception for lazy FPU
/// Called from the #NM exception handler when a thread tries to use FPU
/// Returns true if handled successfully, false if no current thread
pub fn handleFpuAccess() bool {
    const current = getCurrentThread();

    // No lock needed - we're in exception handler context with interrupts disabled
    if (current) |curr| {
        // Clear TS flag to allow FPU access
        fpu.clearTaskSwitched();

        // If thread previously used FPU, restore its state
        // Otherwise, the thread gets fresh FPU state (already initialized)
        if (curr.fpu_used) {
            // Thread has saved FPU state, restore it
            fpu.fxrstor(&curr.fpu_state);
        } else {
            // First FPU use by this thread since context switch
            // Mark as using FPU so we save state on next switch
            curr.fpu_used = true;
        }
        return true;
    }
    return false;
}
