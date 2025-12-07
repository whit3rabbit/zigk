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

const Thread = thread.Thread;
const ThreadState = thread.ThreadState;
const gdt = hal.gdt;
const fpu = hal.fpu;

/// Scheduler state
/// All fields protected by the scheduler lock
var scheduler = Scheduler{};

const Scheduler = struct {
    /// Currently executing thread (null before first schedule)
    current: ?*Thread = null,

    /// Ready queue head (oldest waiting thread)
    ready_head: ?*Thread = null,

    /// Ready queue tail (newest waiting thread)
    ready_tail: ?*Thread = null,

    /// Number of threads in ready queue
    ready_count: usize = 0,

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
};

/// Add a thread to the back of the ready queue
fn addToReadyQueue(t: *Thread) void {
    t.state = .Ready;
    t.next = null;
    t.prev = scheduler.ready_tail;

    if (scheduler.ready_tail) |tail| {
        tail.next = t;
    } else {
        scheduler.ready_head = t;
    }
    scheduler.ready_tail = t;
    scheduler.ready_count += 1;

    if (config.debug_scheduler) {
        console.debug("Sched: Added '{s}' (tid={d}) to ready queue (count={d})", .{
            t.getName(),
            t.tid,
            scheduler.ready_count,
        });
    }
}

/// Remove and return the thread at the front of the ready queue
fn removeFromReadyQueue() ?*Thread {
    const head = scheduler.ready_head orelse return null;

    scheduler.ready_head = head.next;
    if (scheduler.ready_head) |new_head| {
        new_head.prev = null;
    } else {
        scheduler.ready_tail = null;
    }

    head.next = null;
    head.prev = null;
    scheduler.ready_count -= 1;

    if (config.debug_scheduler) {
        console.debug("Sched: Removed '{s}' (tid={d}) from ready queue (count={d})", .{
            head.getName(),
            head.tid,
            scheduler.ready_count,
        });
    }

    return head;
}

/// Remove a specific thread from the ready queue
fn removeThreadFromQueue(t: *Thread) void {
    if (t.prev) |prev| {
        prev.next = t.next;
    } else {
        scheduler.ready_head = t.next;
    }

    if (t.next) |next| {
        next.prev = t.prev;
    } else {
        scheduler.ready_tail = t.prev;
    }

    t.next = null;
    t.prev = null;
    scheduler.ready_count -= 1;
}

/// Idle thread entry point - runs when no other threads are ready
fn idleThreadEntry() void {
    while (true) {
        // HLT waits for the next interrupt (timer, keyboard, etc.)
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
pub fn yield() void {
    // Trigger a software interrupt to force a context switch
    // For now, we just wait for the next timer tick
    // TODO: Implement software interrupt for immediate yield
    hal.cpu.halt();
}

/// Block the current thread
/// Thread will not be scheduled until unblocked
pub fn block() void {
    const held = scheduler.lock.acquire();
    defer held.release();

    if (scheduler.current) |curr| {
        curr.state = .Blocked;
        // Don't add to ready queue - thread is blocked
        if (config.debug_scheduler) {
            console.debug("Sched: Thread '{s}' (tid={d}) blocked", .{
                curr.getName(),
                curr.tid,
            });
        }
    }
}

/// Unblock a thread
/// Thread will be added to the ready queue
pub fn unblock(t: *Thread) void {
    const held = scheduler.lock.acquire();
    defer held.release();

    if (t.state == .Blocked) {
        addToReadyQueue(t);
        if (config.debug_scheduler) {
            console.debug("Sched: Thread '{s}' (tid={d}) unblocked", .{
                t.getName(),
                t.tid,
            });
        }
    }
}

/// Exit the current thread
/// Thread will be marked as zombie and removed from scheduling
pub fn exit() void {
    const held = scheduler.lock.acquire();

    if (scheduler.current) |curr| {
        curr.state = .Zombie;
        scheduler.current = null;

        if (config.debug_scheduler) {
            console.info("Sched: Thread '{s}' (tid={d}) exited", .{
                curr.getName(),
                curr.tid,
            });
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
    var next_thread = removeFromReadyQueue();

    // If no threads ready, use idle thread
    if (next_thread == null) {
        next_thread = scheduler.idle_thread;
        // Idle thread doesn't go in ready queue, just runs directly
    }

    const next = next_thread.?;

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

        // Lazy FPU: Set CR0.TS to trigger #NM on first FPU access
        // The #NM handler will restore FPU state only when needed
        fpu.setTaskSwitched();

        // Reset fpu_used flag - will be set by #NM handler if thread uses FPU
        next.fpu_used = false;
    }

    next.state = .Running;
    scheduler.current = next;

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
        .ready_count = scheduler.ready_count,
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
    var t = scheduler.ready_head;
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
