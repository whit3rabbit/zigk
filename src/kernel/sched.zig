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
///
/// SECURITY AUDIT: Lock ordering - these locks protect separate data structures
/// and are not typically acquired together. If both are needed, acquire
/// process_tree_lock BEFORE scheduler.lock to prevent deadlock.
///
/// Process tree lock (moved here to avoid circular dep with sync/process)
pub var process_tree_lock: sync.Spinlock = .{};

/// Global scheduler instance
var scheduler = Scheduler{};

/// Scheduler internal state structure
const Scheduler = struct {
    // Current thread is now per-CPU, stored in GS data

    /// Ready queue using intrusive linked list
    /// Shared by all CPUs for now (SQMP - Single Queue Multi Processor)
    ready_queue: list.IntrusiveDoublyLinkedList(Thread) = .{},

    /// Sorted sleep list head (wake_time ascending)
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

/// Initialize the scheduler (BSP)
/// Must be called after memory management is initialized
pub fn init() void {
    console.info("Sched: Initializing scheduler...", .{});

    // Register timer handler for preemptive scheduling
    hal.interrupts.setTimerHandler(timerTick);

    // Register guard page checker for stack overflow detection
    hal.interrupts.setGuardPageChecker(guardPageCheckerCallback);

    // Register FPU access handler for lazy FPU switching
    hal.interrupts.setFpuAccessHandler(handleFpuAccess);

    // Create the idle thread for BSP
    initIdleThread();

    console.info("Sched: Initialized (BSP)", .{});
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
    // Initialize idle thread for this AP
    initIdleThread();

    // Enable interrupts to allow timer ticks (once we start)
    // But we are not starting yet.
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

/// Unblock a thread
/// Thread will be added to the ready queue
///
/// SECURITY AUDIT: Safe to call from any context (IRQ, other CPU).
/// If thread is Blocked, it's added to ready queue immediately.
/// If thread hasn't blocked yet (Running), pending_wakeup is set so
/// block() will return immediately without halting.
/// This prevents the TOCTOU race in block()/unblock() synchronization.
pub fn unblock(t: *Thread) void {
    const held = scheduler.lock.acquire();
    defer held.release();

    if (t.state == .Blocked) {
        // Thread is blocked - wake it up normally
        removeFromSleepList(t);
        addToReadyQueue(t);
        if (config.debug_scheduler) {
            console.debug("Sched: Thread '{s}' (tid={d}) unblocked", .{
                t.getName(),
                t.tid,
            });
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
        // Set exit status
        thread.setExitStatus(curr, status);

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

    // Don't schedule if scheduler isn't running yet
    if (!scheduler.running) {
        return frame;
    }

    // Log every 100 ticks to show scheduler is alive
    if (scheduler.tick_count % 100 == 0) {
        console.debug("Tick {d}", .{scheduler.tick_count});
    }

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

    return .{
        .tick_count = scheduler.tick_count,
        .ready_count = scheduler.ready_queue.count,
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
