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

pub const Thread = thread.Thread;
const ThreadState = thread.ThreadState;
const gdt = hal.gdt;
const fpu = hal.fpu;

/// Scheduler state
/// All fields protected by the scheduler lock
/// Process tree lock (moved here to avoid circular dep with sync/process)
pub var process_tree_lock: sync.Spinlock = .{};

/// Global scheduler instance
var scheduler = Scheduler{};

/// Scheduler internal state structure
const Scheduler = struct {
    /// Currently executing thread (null before first schedule)
    current: ?*Thread = null,

    /// Ready queue using intrusive linked list
    ready_queue: list.IntrusiveDoublyLinkedList(Thread) = .{},

    /// Sorted sleep list head (wake_time ascending)
    sleep_head: ?*Thread = null,

    /// System tick counter (incremented on each timer IRQ)
    tick_count: u64 = 0,

    /// Scheduler lock - must be held when modifying scheduler state
    lock: sync.Spinlock = .{},

    /// Is the scheduler running? (false until start() is called)
    running: bool = false,

    /// Idle thread - always available as a fallback
    idle_thread: ?*Thread = null,

    /// Per-CPU kernel GS data pointer (for syscall stack switching)
    /// Set by main.zig during initialization
    gs_data: ?*hal.syscall.KernelGsData = null,

    /// Callback function to be called on every timer tick
    tick_callback: ?*const fn () void = null,
};

/// Set the timer tick callback function
pub fn setTickCallback(callback: *const fn () void) void {
    const held = scheduler.lock.acquire();
    defer held.release();
    scheduler.tick_callback = callback;
}

/// Add a thread to the back of the ready queue
fn addToReadyQueue(t: *Thread) void {
    t.state = .Ready;
    scheduler.ready_queue.append(t);

    if (config.debug_scheduler) {
        console.debug("Sched: Added '{s}' (tid={d}) to ready queue (count={d})", .{
            t.getName(),
            t.tid,
            scheduler.ready_queue.count,
        });
    }
}

/// Remove and return the thread at the front of the ready queue
fn removeFromReadyQueue() ?*Thread {
    const thread_ptr = scheduler.ready_queue.popFirst();
    if (thread_ptr) |t| {
        if (config.debug_scheduler) {
            console.debug("Sched: Removed '{s}' (tid={d}) from ready queue (count={d})", .{
                t.getName(),
                t.tid,
                scheduler.ready_queue.count,
            });
        }
    }
    return thread_ptr;
}

/// Remove a specific thread from the ready queue
fn removeThreadFromQueue(t: *Thread) void {
    scheduler.ready_queue.remove(t);
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

/// Remove a thread from the sleep list
fn removeFromSleepList(t: *Thread) void {
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
fn wakeSleepingThreads(now: u64) void {
    while (scheduler.sleep_head) |t| {
        if (t.wake_time > now) break;
        removeFromSleepList(t);
        if (t.state == .Blocked) {
            addToReadyQueue(t);
        }
    }
}

/// Idle thread entry point - runs when no other threads are ready
/// Idle thread entry point - runs when no other threads are ready
fn idleThreadEntry() void {
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
pub fn setGsData(gs_data: *hal.syscall.KernelGsData) void {
    scheduler.gs_data = gs_data;
}

/// Initialize the scheduler
/// Must be called after memory management is initialized
pub fn init() void {
    console.info("Sched: Initializing scheduler...", .{});

    // Register timer handler for preemptive scheduling
    hal.interrupts.setTimerHandler(timerTick);
    console.info("Sched: Timer handler registered", .{});

    // Register guard page checker for stack overflow detection
    hal.interrupts.setGuardPageChecker(guardPageCheckerCallback);
    console.info("Sched: Guard page checker registered", .{});

    // Register FPU access handler for lazy FPU switching
    hal.interrupts.setFpuAccessHandler(handleFpuAccess);
    console.info("Sched: Lazy FPU handler registered", .{});

    // Create the idle thread
    scheduler.idle_thread = thread.createKernelThread(idleThreadEntry, .{
        .name = "idle",
        .stack_size = 4096, // Idle thread needs minimal stack
    }) catch |err| {
        console.err("Sched: Failed to create idle thread: {}", .{err});
        hal.cpu.haltForever();
    };

    console.info("Sched: Idle thread created (tid={d})", .{scheduler.idle_thread.?.tid});
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
/// Thread will be added to the ready queue
pub fn addThread(t: *Thread) void {
    const held = scheduler.lock.acquire();
    defer held.release();

    addToReadyQueue(t);
}

/// Start the scheduler
/// This function does not return - it becomes the idle thread
pub fn start() noreturn {
    console.info("Sched: Starting scheduler...", .{});

    {
        const held = scheduler.lock.acquire();
        scheduler.running = true;
        held.release();
    }

    // Enable interrupts to allow timer ticks
    hal.cpu.enableInterrupts();

    // This main thread becomes idle-like behavior until first preemption
    // The timer interrupt will eventually switch to a ready thread
    while (true) {
        hal.cpu.halt();
    }
}

/// Get the currently running thread
pub fn getCurrentThread() ?*Thread {
    return scheduler.current;
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
    // Debug check: detect yield while holding locks (deadlock prevention)
    // Debug check: detect yield while holding locks (deadlock prevention)
    // CRITICAL: Always check this, even in release builds, to prevent silent deadlocks.
    if (scheduler.current) |t| {
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
/// IMPORTANT: This function sets the thread state to Blocked, then atomically
/// enables interrupts and halts. The next timer tick will context-switch to
/// another thread. Because state is Blocked, this thread will NOT be added
/// to the ready queue. It will only run again after unblock() is called.
///
/// This is required because syscalls run with IF=0 (Big Kernel Lock).
/// Without enabling interrupts and halting, the timer IRQ cannot fire,
/// causing a deadlock.
pub fn block() void {
    {
        const held = scheduler.lock.acquire();
        defer held.release();

        if (scheduler.current) |curr| {
            removeFromSleepList(curr);
            curr.state = .Blocked;
            curr.wake_time = 0;
            // Don't add to ready queue - thread is blocked
            if (config.debug_scheduler) {
                console.debug("Sched: Thread '{s}' (tid={d}) blocked", .{
                    curr.getName(),
                    curr.tid,
                });
            }
        }
    }

    // Mitigation for "Spurious Halt" race:
    // If an interrupt fired immediately after lock release, we might have been
    // preempted, blocked, unblocked, and rescheduled ALREADY.
    // In that case, our state is now Running, and we should NOT halt.
    hal.cpu.disableInterrupts();
    if (scheduler.current) |curr| {
        if (curr.state == .Running) {
            // We were preempted and woken up already
            hal.cpu.enableInterrupts();
            return;
        }
    }

    // After releasing the lock (and verifying state), atomically enable interrupts and halt.
    // The timer IRQ will fire and timerTick() will:
    //   1. Save our context (kernel_rsp)
    //   2. See state == .Blocked, so NOT add us to ready queue
    //   3. Switch to another thread
    // When unblock() is called on us, we're added to ready queue.
    // When scheduled again, execution resumes here.
    hal.cpu.enableAndHalt();
}

/// Unblock a thread
/// Thread will be added to the ready queue
pub fn unblock(t: *Thread) void {
    const held = scheduler.lock.acquire();
    defer held.release();

    if (t.state == .Blocked) {
        removeFromSleepList(t);
        addToReadyQueue(t);
        if (config.debug_scheduler) {
            console.debug("Sched: Thread '{s}' (tid={d}) unblocked", .{
                t.getName(),
                t.tid,
            });
        }
    }
}

/// Put the current thread to sleep until tick_count reaches the target
pub fn sleepForTicks(ticks: u64) void {
    if (ticks == 0) {
        return;
    }

    {
        const held = scheduler.lock.acquire();
        defer held.release();

        if (scheduler.current) |curr| {
            removeFromSleepList(curr);
            curr.state = .Blocked;
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

    if (scheduler.current) |curr| {
        // Set exit status
        thread.setExitStatus(curr, status);

        // Mark as zombie
        curr.state = .Zombie;
        scheduler.current = null;

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
    const held = scheduler.lock.acquire();
    defer held.release();

    scheduler.tick_count += 1;
    wakeSleepingThreads(scheduler.tick_count);

    if (scheduler.tick_count % 100 == 0) {
        console.debug("Sched: Tick {d}", .{scheduler.tick_count});
    }

    // Call registered timer callback (e.g. for TCP timers)
    if (scheduler.tick_callback) |cb| {
        cb();
    }

    // Don't schedule if scheduler isn't running yet
    if (!scheduler.running) {
        return frame;
    }

    // Save current thread's context
    if (scheduler.current) |curr| {
        // Save the interrupt frame location
        curr.kernel_rsp = @intFromPtr(frame);

        // Lazy FPU: Only save FPU state if thread used FPU instructions
        // This avoids expensive FXSAVE for threads that don't use FPU
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
    console.info("timerTick: ready_queue count={d}", .{scheduler.ready_queue.count});
    var next_thread = removeFromReadyQueue();

    // If no threads ready, use idle thread
    if (next_thread == null) {
        console.info("timerTick: no ready threads, using idle", .{});
        next_thread = scheduler.idle_thread;
        // Idle thread doesn't go in ready queue, just runs directly
    } else {
        console.info("timerTick: got thread from queue '{s}'", .{next_thread.?.getName()});
    }

    const next = next_thread.?;
    console.info("timerTick: next thread '{s}' state={} kernel_rsp={x}", .{
        next.getName(), @intFromEnum(next.state), next.kernel_rsp,
    });

    // If switching to a different thread, update TSS and potentially CR3
    if (scheduler.current != next) {
        if (config.debug_scheduler) {
            const curr_name = if (scheduler.current) |c| c.getName() else "none";
            console.debug("Sched: Switch {s} -> {s}", .{ curr_name, next.getName() });
        }

        // Update TSS.rsp0 for the new thread's kernel stack
        gdt.setKernelStack(next.kernel_stack_top);

        // Update kernel GS data for SYSCALL instruction
        // The syscall entry stub reads %gs:0 to get kernel stack
        if (scheduler.gs_data) |gs_data| {
            gs_data.kernel_stack = next.kernel_stack_top;
        }

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
        // This ensures that if we switch from a thread with TLS (fs!=0) to
        // one without (fs=0), we correctly clear the MSR.
        const current_fs = if (scheduler.current) |c| c.fs_base else 0;
        if (next.fs_base != current_fs) {
            hal.cpu.writeMsr(hal.cpu.IA32_FS_BASE, next.fs_base);
        }

        // Lazy FPU: Set CR0.TS to trigger #NM on first FPU access
        // The #NM handler will restore FPU state only when needed
        fpu.setTaskSwitched();

        // Reset fpu_used flag - will be set by #NM handler if thread uses FPU
        next.fpu_used = false;
    }

    next.state = .Running;
    scheduler.current = next;

    // DEBUG: Verify the interrupt frame before context switch
    const frame_ptr: *hal.idt.InterruptFrame = @ptrFromInt(next.kernel_rsp);
    console.debug("timerTick: switch to '{s}' tid={d} kernel_rsp={x}", .{
        next.getName(), next.tid, next.kernel_rsp,
    });
    console.debug("timerTick: frame.cs={x} frame.ss={x} frame.rip={x} rflags={x}", .{
        frame_ptr.cs, frame_ptr.ss, frame_ptr.rip, frame_ptr.rflags,
    });
    console.debug("timerTick: EXIT returning {x}", .{next.kernel_rsp});

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

    return .{
        .tick_count = scheduler.tick_count,
        .ready_count = scheduler.ready_queue.count,
        .is_running = scheduler.running,
        .current_tid = if (scheduler.current) |c| c.tid else null,
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
    // Check current thread first (most likely case)
    if (scheduler.current) |curr| {
        if (isInGuardPage(fault_addr, curr)) {
            return GuardPageInfo{
                .thread_id = curr.tid,
                .thread_name = curr.getName(),
                .stack_base = curr.kernel_stack_base,
                .stack_top = curr.kernel_stack_top,
            };
        }
    }

    // Check idle thread
    if (scheduler.idle_thread) |idle| {
        if (isInGuardPage(fault_addr, idle)) {
            return GuardPageInfo{
                .thread_id = idle.tid,
                .thread_name = idle.getName(),
                .stack_base = idle.kernel_stack_base,
                .stack_top = idle.kernel_stack_top,
            };
        }
    }

    // Check all threads in ready queue
    var t = scheduler.ready_queue.head;
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
    // No lock needed - we're in exception handler context with interrupts disabled
    if (scheduler.current) |curr| {
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
