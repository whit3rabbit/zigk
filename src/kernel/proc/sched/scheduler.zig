const std = @import("std");
const hal = @import("hal");
const sync = @import("sync");
const console = @import("console");
const config = @import("config");
const thread_mod = @import("thread"); // src/kernel/thread.zig
const queue_mod = @import("queue.zig");
const cpu_mod = @import("cpu.zig");
const thread_logic = @import("thread.zig");
const futex = @import("futex"); // For wakeSleepingThreads timeout handling
const base = @import("base.zig"); // For exitWithStatus address check

const Thread = thread_mod.Thread;
const WaitQueue = queue_mod.WaitQueue;

// Re-exports
const gdt = hal.gdt;
const fpu = hal.fpu;


/// Scheduler internal state structure
pub const Scheduler = struct {
    /// Sorted sleep list head (wake_time ascending)
    /// Protected by sleep_lock (separate from main scheduler lock)
    sleep_head: ?*Thread = null,

    /// System tick counter (incremented on each timer IRQ)
    /// Atomic to allow lock-free reads and increment from timerTick
    tick_count: std.atomic.Value(u64) = .{ .raw = 0 },

    /// Scheduler lock - protects running state and thread state transitions
    /// SECURITY AUDIT: Always acquired after process_tree_lock if both needed.
    lock: sync.Spinlock = .{},

    /// Sleep list lock - protects sleep_head and sleep list operations
    sleep_lock: sync.Spinlock = .{},

    /// Is the scheduler running?
    running: bool = false,

    /// Callback function to be called on every timer tick
    tick_callback: ?*const fn () void = null,
};

/// Global scheduler instance
pub var scheduler = Scheduler{};

/// Set the timer tick callback function
pub fn setTickCallback(callback: *const fn () void) void {
    const held = scheduler.lock.acquire();
    defer held.release();
    scheduler.tick_callback = callback;
}

// === Sleep List Helpers ===

/// Insert a thread into the sorted sleep list
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

// === Public API ===

/// Cancel a thread's futex timeout and add to ready queue
pub fn cancelTimeoutAndWake(t: *Thread) void {
    const held = scheduler.lock.acquire();
    defer held.release();

    if (t.state != .Blocked) {
        return;
    }

    if (t.wake_time != 0) {
        const sleep_held = scheduler.sleep_lock.acquire();
        removeFromSleepList(t);
        sleep_held.release();
    }

    t.futex_bucket = null;
    t.futex_wakeup_reason = .woken;

    cpu_mod.addToReadyQueue(t);
}

/// Initialize idle thread for current CPU
fn initIdleThread() void {
    const idle = thread_mod.createKernelThread(idleThreadEntry, null, .{
        .name = "idle",
        .stack_size = 4096, // Idle thread needs minimal stack
    }) catch |err| {
        console.err("Sched: Failed to create idle thread: {}", .{err});
        hal.cpu.haltForever();
    };

    const gs_base = hal.cpu.readMsr(hal.cpu.IA32_GS_BASE);
    const gs_data = @as(*hal.syscall.KernelGsData, @ptrFromInt(gs_base));
    gs_data.idle_thread = @intFromPtr(idle);
    gs_data.current_thread = 0; // No current thread yet

    console.info("Sched: Idle thread created for CPU {d} (tid={d})", .{gs_data.apic_id, idle.tid});
}

/// Idle thread entry point
fn idleThreadEntry(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    hal.cpu.enableInterrupts();
    while (true) {
        hal.cpu.halt();
    }
}

/// Handle RESCHEDULE IPI from another CPU
fn handleRescheduleIpi(frame: *hal.idt.InterruptFrame) void {
    _ = frame;
    // No action needed - the IPI wakes the CPU from halt state
    if (config.debug_scheduler) {
        console.debug("Sched: CPU {d} received RESCHEDULE IPI", .{cpu_mod.getCurrentCpuIndex()});
    }
}

/// Initialize the scheduler (BSP)
pub fn init() void {
    console.info("Sched: Initializing scheduler...", .{});

    const cpu_id = cpu_mod.getCurrentCpuIndex();
    cpu_mod.cpu_sched[cpu_id].cpu_id = @intCast(cpu_id);
    cpu_mod.cpu_sched[cpu_id].initialized = true;
    cpu_mod.active_cpu_count = 1;

    hal.interrupts.setTimerHandler(timerTick);
    // guardPageCheckerCallback is in thread.zig, how do we register it?
    // We should expose it from thread.zig or define callback here calling thread.zig
    hal.interrupts.setGuardPageChecker(guardPageCheckerCallbackWrapper);
    hal.interrupts.setFpuAccessHandler(thread_logic.handleFpuAccess);
    hal.apic.ipi.registerHandler(.reschedule, handleRescheduleIpi);

    initIdleThread();

    console.info("Sched: Initialized (BSP, CPU {d})", .{cpu_id});
}

fn guardPageCheckerCallbackWrapper(fault_addr: u64) ?hal.interrupts.GuardPageInfo {
    return thread_logic.checkGuardPage(fault_addr);
}

/// Initialize Scheduler for AP
pub fn initAp() void {
    const cpu_id = cpu_mod.getCurrentCpuIndex();
    cpu_mod.cpu_sched[cpu_id].cpu_id = @intCast(cpu_id);
    cpu_mod.cpu_sched[cpu_id].initialized = true;

    _ = @atomicRmw(u32, &cpu_mod.active_cpu_count, .Add, 1, .seq_cst);

    initIdleThread();
}

/// Start the scheduler (BSP)
pub fn start() noreturn {
    console.info("Sched: Starting scheduler on CPU {d}...", .{hal.apic.lapic.getId()});

    {
        const held = scheduler.lock.acquire();
        scheduler.running = true;
        held.release();
    }

    // Get idle thread pointer directly from GS:40 inline to minimize stack usage
    // This avoids potential stack overflow on the boot stack
    const idle_ptr: u64 = asm volatile ("movq %%gs:40, %[ret]"
        : [ret] "=r" (-> u64),
    );
    const idle: *Thread = @ptrFromInt(idle_ptr);

    // Set the idle thread as current
    thread_logic.setCurrentThread(idle);
    idle.state = .Running;

    // Update GDT/TSS with idle thread's kernel stack for syscalls
    hal.gdt.setKernelStack(idle.kernel_stack_top);
    const gs_base = hal.cpu.readMsr(hal.cpu.IA32_GS_BASE);
    const gs_data = @as(*hal.syscall.KernelGsData, @ptrFromInt(gs_base));
    gs_data.kernel_stack = idle.kernel_stack_top;
    gs_data.current_thread = @intFromPtr(idle);

    // Switch to idle thread's stack and enable interrupts
    const idle_stack = idle.kernel_stack_top;

    asm volatile (
        \\mov %[stack], %%rsp
        \\mov %%rsp, %%rbp
        \\sti
        \\1: hlt
        \\jmp 1b
        :
        : [stack] "r" (idle_stack),
        : .{ .rsp = true, .rbp = true, .memory = true }
    );

    unreachable;
}

/// Start scheduler on AP
pub fn startAp() noreturn {
    // Get idle thread pointer directly from GS:40 inline
    const idle_ptr: u64 = asm volatile ("movq %%gs:40, %[ret]"
        : [ret] "=r" (-> u64),
    );
    const idle: *Thread = @ptrFromInt(idle_ptr);

    thread_logic.setCurrentThread(idle);
    idle.state = .Running;

    hal.gdt.setKernelStack(idle.kernel_stack_top);
    const gs_base = hal.cpu.readMsr(hal.cpu.IA32_GS_BASE);
    const gs_data = @as(*hal.syscall.KernelGsData, @ptrFromInt(gs_base));
    gs_data.kernel_stack = idle.kernel_stack_top;
    gs_data.current_thread = @intFromPtr(idle);

    const idle_stack = idle.kernel_stack_top;

    asm volatile (
        \\mov %[stack], %%rsp
        \\mov %%rsp, %%rbp
        \\sti
        \\1: hlt
        \\jmp 1b
        :
        : [stack] "r" (idle_stack),
        : .{ .rsp = true, .rbp = true, .memory = true }
    );

    unreachable;
}

/// Get the current tick count (lock-free)
pub fn getTickCount() u64 {
    return scheduler.tick_count.load(.monotonic);
}

/// Yield the current thread's remaining time slice
pub fn yield() void {
    const current = thread_logic.getCurrentThread();

    if (current) |t| {
        if (t.lock_depth > 0) {
            console.err("PANIC: yield() called with {d} lock(s) held by thread '{s}' (tid={d})", .{
                t.lock_depth, t.getName(), t.tid,
            });
            @panic("yield with spinlocks held - deadlock");
        }
    }

    hal.cpu.enableAndHalt();
}

/// Block the current thread
pub fn block() void {
    const current = thread_logic.getCurrentThread();

    {
        const held = scheduler.lock.acquire();
        defer held.release();

        if (current) |curr| {
            if (curr.pending_wakeup.load(.acquire)) {
                curr.pending_wakeup.store(false, .release);
                if (config.debug_scheduler) {
                    console.debug("Sched: Thread '{s}' (tid={d}) consumed pending wakeup", .{
                        curr.getName(), curr.tid,
                    });
                }
                return;
            }

            {
                const sleep_held = scheduler.sleep_lock.acquire();
                removeFromSleepList(curr);
                sleep_held.release();
            }
            curr.state = .Blocked;
            curr.wake_time = 0;

            if (config.debug_scheduler) {
                console.debug("Sched: Thread '{s}' (tid={d}) blocked", .{
                    curr.getName(), curr.tid,
                });
            }
        }
    }

    hal.cpu.enableAndHalt();
}

/// Unblock a thread
pub fn unblock(t: *Thread) void {
    const held = scheduler.lock.acquire();
    defer held.release();

    if (t.state == .Blocked) {
        {
            const sleep_held = scheduler.sleep_lock.acquire();
            removeFromSleepList(t);
            sleep_held.release();
        }

        const target_cpu = cpu_mod.getTargetCpu(t);
        const current_cpu = cpu_mod.getCurrentCpuIndex();

        cpu_mod.addToReadyQueue(t);

        if (config.debug_scheduler) {
            console.debug("Sched: Thread '{s}' (tid={d}) unblocked -> CPU {d}", .{
                t.getName(), t.tid, target_cpu,
            });
        }

        if (target_cpu != current_cpu and cpu_mod.isCpuInitialized(target_cpu)) {
            const target_apic_id = cpu_mod.getCpuSched(target_cpu).cpu_id;
            hal.apic.ipi.sendTo(target_apic_id, .reschedule);
        }
    } else if (t.state == .Running) {
        t.pending_wakeup.store(true, .release);
        if (config.debug_scheduler) {
            console.debug("Sched: Thread '{s}' (tid={d}) set pending_wakeup", .{
                t.getName(), t.tid,
            });
        }
    }
}

/// Wake up a thread and assign it to a specific CPU
pub fn wakeOnCpu(t: *Thread, cpu_id: u32) void {
    if (cpu_id >= cpu_mod.MAX_CPUS) return;

    {
        const held = scheduler.lock.acquire();
        defer held.release();
        t.cpu_affinity = @as(u32, 1) << @intCast(cpu_id);
        t.last_cpu = cpu_id;
    }

    unblock(t);
}

/// Wait on a queue until woken up
pub fn waitOn(queue: *WaitQueue, lock_held: sync.Spinlock.Held) void {
    const current = thread_logic.getCurrentThread() orelse return;
    const sched_held = scheduler.lock.acquire();

    queue.append(current);
    current.state = .Blocked;
    
    lock_held.release();
    sched_held.release();
    schedule_sync();
}

/// Wait on a queue with timeout support
pub fn waitOnWithTimeout(
    queue: *WaitQueue,
    lock_held: sync.Spinlock.Held,
    timeout_ticks: u64,
    futex_bucket_ptr: ?*anyopaque,
) void {
    const current = thread_logic.getCurrentThread() orelse return;
    const sched_held = scheduler.lock.acquire();

    queue.append(current);
    current.state = .Blocked;

    if (timeout_ticks > 0) {
        current.wake_time = scheduler.tick_count.load(.monotonic) +| timeout_ticks;
        current.futex_bucket = futex_bucket_ptr;
        current.futex_wakeup_reason = .none;

        const sleep_held = scheduler.sleep_lock.acquire();
        insertSleepThread(current);
        sleep_held.release();
    } else {
        current.wake_time = 0;
        current.futex_bucket = null;
        current.futex_wakeup_reason = .none;
    }

    lock_held.release();
    sched_held.release();
    schedule_sync();
}

/// Put the current thread to sleep until tick_count reaches the target
pub fn sleepForTicks(ticks: u64) void {
    if (ticks == 0) return;

    const current = thread_logic.getCurrentThread();
    const current_tick = scheduler.tick_count.load(.monotonic);

    {
        const sleep_held = scheduler.sleep_lock.acquire();
        defer sleep_held.release();

        if (current) |curr| {
            removeFromSleepList(curr);
            curr.state = .Blocked;
            const max_tick: u64 = std.math.maxInt(u64);
            const wake_tick = if (ticks > max_tick - current_tick)
                max_tick
            else
                current_tick + ticks;
            curr.wake_time = wake_tick;
            insertSleepThread(curr);
        }
    }

    hal.cpu.enableAndHalt();
}

/// Internal schedule function for synchronous switching
fn schedule_sync() void {
    asm volatile ("int $32");
}

/// Wake up threads whose sleep timer has expired
fn wakeSleepingThreads(now: u64) void {
    while (scheduler.sleep_head) |t| {
        if (t.wake_time > now) break;
        removeFromSleepList(t);

        if (t.futex_bucket) |bucket_ptr| {
            const bucket = futex.getBucketFromOpaque(bucket_ptr);
            if (bucket.lock.tryAcquire()) |held| {
                defer held.release();
                _ = bucket.queue.removeThread(t);
                t.futex_wakeup_reason = .timeout;
                t.futex_bucket = null;
            } else {
                t.wake_time = now + 1;
                insertSleepThread(t);
                continue;
            }
        }

        if (t.state == .Blocked) {
            cpu_mod.addToReadyQueue(t);
        }
    }
}

/// Exit the current thread
pub fn exit() void {
    exitWithStatus(0);
}

/// Exit the current thread with a specific exit status
pub fn exitWithStatus(status: i32) void {
    const held = scheduler.lock.acquire();
    const current = thread_logic.getCurrentThread();

    if (current) |curr| {
        for (thread_logic.getExitCallbacks()) |cb_opt| {
            if (cb_opt) |cb| cb(curr);
        }

        thread_mod.setExitStatus(curr, status);

        if (curr.clear_child_tid != 0) {
            if (base.isValidUserAccess(curr.clear_child_tid, @sizeOf(i32), .Write)) {
                base.UserPtr.from(curr.clear_child_tid).writeValue(@as(i32, 0)) catch |err| {
                    console.warn("Sched: Failed to clear TID at {x}: {}", .{ curr.clear_child_tid, err });
                };
                _ = futex.wake(curr.clear_child_tid, 1) catch {};
            }
        }

        curr.state = .Zombie;
        thread_logic.setCurrentThread(null);

        if (config.debug_scheduler) {
            console.info("Sched: Thread '{s}' (tid={d}) exited with status {d}", .{
                curr.getName(), curr.tid, status,
            });
        }

        if (curr.parent) |parent| {
            if (parent.state == .Blocked) {
                cpu_mod.addToReadyQueue(parent);
                if (config.debug_scheduler) {
                    console.debug("Sched: Woke parent '{s}' (tid={d})", .{
                        parent.getName(), parent.tid,
                    });
                }
            } else if (parent.state == .Running and parent.wait4_waiting.load(.acquire)) {
                parent.pending_wakeup.store(true, .release);
                if (config.debug_scheduler) {
                    console.debug("Sched: Deferred wake for parent '{s}' (tid={d})", .{
                        parent.getName(), parent.tid,
                    });
                }
            }
        }
    }

    held.release();

    hal.cpu.disableInterrupts();
    while (true) {
        hal.cpu.halt();
    }
}

// === Timer Tick & Scheduling ===

/// Timer tick handler - called from IRQ0 handler
pub fn timerTick(frame: *hal.idt.InterruptFrame) *hal.idt.InterruptFrame {
    const local_tick_count = scheduler.tick_count.fetchAdd(1, .monotonic) + 1;

    var tick_cb: ?*const fn () void = null;
    var is_running: bool = false;

    {
        const held = scheduler.lock.acquire();
        defer held.release();
        tick_cb = scheduler.tick_callback;
        is_running = scheduler.running;
    }

    if (scheduler.sleep_lock.tryAcquire()) |sleep_held| {
        wakeSleepingThreads(local_tick_count);
        sleep_held.release();
    }

    if (tick_cb) |cb| cb();

    if (local_tick_count % 10 == 0) {
        const vdso = @import("vdso");
        vdso.update();
    }

    if (!is_running) {
        return frame;
    }

    return doPerCpuSchedule(frame);
}

/// Per-CPU scheduling logic
fn doPerCpuSchedule(frame: *hal.idt.InterruptFrame) *hal.idt.InterruptFrame {
    const current = thread_logic.getCurrentThread();

    if (current) |curr| {
        curr.kernel_rsp = @intFromPtr(frame);

        if (curr.fpu_used) {
            fpu.fxsave(&curr.fpu_state);
        }

        if (curr.state == .Running) {
            cpu_mod.addToReadyQueue(curr);
        }
    }

    var next_thread = cpu_mod.removeFromReadyQueue();

    if (next_thread == null) {
        next_thread = thread_logic.getIdleThread();
    }

    if (next_thread == null) {
        console.panic("Sched: Failed to select next thread (Idle thread missing?)", .{});
    }

    const next = next_thread.?;

    if (current != next) {
        if (config.debug_scheduler) {
            // const curr_name = if (current) |c| c.getName() else "none";
            // console.debug("Sched: Switch {s} -> {s}", .{ curr_name, next.getName() });
        }

        gdt.setKernelStack(next.kernel_stack_top);

        const gs_base = hal.cpu.readMsr(hal.cpu.IA32_GS_BASE);
        const gs_data = @as(*hal.syscall.KernelGsData, @ptrFromInt(gs_base));
        gs_data.kernel_stack = next.kernel_stack_top;

        if (next.cr3 != 0) {
            const current_cr3 = hal.cpu.readCr3();
            if (next.cr3 != current_cr3) {
                hal.cpu.writeCr3(next.cr3);
            }
        }

        const current_fs = if (current) |c| c.fs_base else 0;
        if (next.fs_base != current_fs) {
            hal.cpu.writeMsr(hal.cpu.IA32_FS_BASE, next.fs_base);
        }

        fpu.setTaskSwitched();
        next.fpu_used = false;
    }

    next.last_cpu = @intCast(cpu_mod.getCurrentCpuIndex());
    next.state = .Running;
    thread_logic.setCurrentThread(next);

    return @ptrFromInt(next.kernel_rsp);
}

/// Check if the scheduler is currently running
pub fn isRunning() bool {
    return scheduler.running;
}

pub const SchedulerStats = struct {
    tick_count: u64,
    ready_count: usize,
    is_running: bool,
    current_tid: ?u32,
};

pub fn getStats() SchedulerStats {
    const held = scheduler.lock.acquire();
    defer held.release();

    const current = thread_logic.getCurrentThread();
    const cpu_count = @atomicLoad(u32, &cpu_mod.active_cpu_count, .acquire);
    var total_ready: usize = 0;
    
    for (cpu_mod.cpu_sched[0..cpu_count]) |*cpu_data| {
        if (cpu_data.initialized) {
            const held_cpu = cpu_data.lock.acquire();
            defer held_cpu.release();
            total_ready += cpu_data.ready_queue.count;
        }
    }

    return .{
        .tick_count = scheduler.tick_count.load(.monotonic),
        .ready_count = total_ready,
        .is_running = scheduler.running,
        .current_tid = if (current) |c| c.tid else null,
    };
}
