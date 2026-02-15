const std = @import("std");
const builtin = @import("builtin");
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

    /// Alarm list head (sorted by deadline ascending)
    /// Protected by alarm_lock
    alarm_head: ?*@import("process").Process = null,

    /// Alarm list lock - protects alarm_head and alarm list operations
    alarm_lock: sync.Spinlock = .{},

    /// Is the scheduler running?
    running: bool = false,

    /// Callback function to be called on every timer tick
    tick_callback: ?*const fn () void = null,

    /// Load averages (fixed-point: actual_load * 65536)
    /// Updated every 5 seconds (500 ticks) via exponential moving average
    load_1min: u64 = 0,
    load_5min: u64 = 0,
    load_15min: u64 = 0,
    /// Last tick when load averages were updated
    load_last_update: u64 = 0,
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

// === Alarm List Helpers ===

const Process = @import("process").Process;

/// Insert a process into the sorted alarm list (deadline ascending)
/// CALLER MUST HOLD alarm_lock
fn insertAlarmProcess(proc: *Process) void {
    proc.alarm_next = null;
    proc.alarm_prev = null;

    if (scheduler.alarm_head) |head| {
        if (proc.alarm_deadline <= head.alarm_deadline) {
            proc.alarm_next = head;
            head.alarm_prev = proc;
            scheduler.alarm_head = proc;
            return;
        }

        var cursor = head;
        while (cursor.alarm_next) |next| {
            if (proc.alarm_deadline <= next.alarm_deadline) {
                proc.alarm_next = next;
                proc.alarm_prev = cursor;
                next.alarm_prev = proc;
                cursor.alarm_next = proc;
                return;
            }
            cursor = next;
        }

        cursor.alarm_next = proc;
        proc.alarm_prev = cursor;
    } else {
        scheduler.alarm_head = proc;
    }
}

/// Remove a process from the alarm list
/// CALLER MUST HOLD alarm_lock
pub fn removeFromAlarmList(proc: *Process) void {
    if (proc.alarm_prev) |prev| {
        prev.alarm_next = proc.alarm_next;
    } else if (scheduler.alarm_head == proc) {
        scheduler.alarm_head = proc.alarm_next;
    }

    if (proc.alarm_next) |next| {
        next.alarm_prev = proc.alarm_prev;
    }

    proc.alarm_next = null;
    proc.alarm_prev = null;
    proc.alarm_deadline = 0;
}

/// Set or cancel an alarm for a process
/// Returns remaining seconds from old alarm (0 if none)
/// SECURITY: Clamps seconds to prevent overflow (max_u64 / 100)
pub fn setAlarm(proc: *Process, seconds: u64) u64 {
    const held = scheduler.alarm_lock.acquire();
    defer held.release();

    const current_tick = scheduler.tick_count.load(.monotonic);

    // Calculate remaining seconds from old alarm
    var remaining: u64 = 0;
    if (proc.alarm_deadline > 0 and proc.alarm_deadline > current_tick) {
        const remaining_ticks = proc.alarm_deadline - current_tick;
        // Round up: (ticks + 99) / 100 to convert 100Hz ticks to seconds
        remaining = (remaining_ticks + 99) / 100;
    }

    // Remove from alarm list if currently scheduled
    if (proc.alarm_deadline > 0) {
        removeFromAlarmList(proc);
    }

    // If seconds > 0, schedule new alarm
    if (seconds > 0) {
        // Clamp to prevent overflow (max tick is max_u64, tick freq is 100Hz)
        const max_seconds: u64 = std.math.maxInt(u64) / 100;
        const clamped_seconds = @min(seconds, max_seconds);

        const duration_ticks = clamped_seconds * 100; // 100 ticks per second
        proc.alarm_deadline = current_tick + duration_ticks;

        // Save current thread as alarm target
        proc.alarm_target_thread = thread_logic.getCurrentThread();

        insertAlarmProcess(proc);
    } else {
        // Canceling alarm - clear target thread
        proc.alarm_target_thread = null;
    }

    return remaining;
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

    const gs_data = switch (builtin.cpu.arch) {
        .x86_64 => @as(*hal.syscall.KernelGsData, @ptrFromInt(hal.cpu.readMsr(hal.cpu.IA32_GS_BASE))),
        .aarch64 => @as(*hal.syscall.KernelGsData, @ptrFromInt(asm volatile ("mrs %[ret], tpidr_el1" : [ret] "=r" (-> u64)))),
        else => @compileError("Unsupported architecture"),
    };
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
    const idle_ptr: u64 = switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("movq %%gs:40, %[ret]" : [ret] "=r" (-> u64)),
        .aarch64 => blk: {
            const gs_data_ptr = asm volatile ("mrs %[ret], tpidr_el1" : [ret] "=r" (-> u64));
            const gs_data = @as(*hal.syscall.KernelGsData, @ptrFromInt(gs_data_ptr));
            break :blk gs_data.idle_thread;
        },
        else => @compileError("Unsupported architecture"),
    };

    const idle: *Thread = @ptrFromInt(idle_ptr);

    // Set the idle thread as current
    thread_logic.setCurrentThread(idle);
    idle.state = .Running;

    // Update per-CPU data with idle thread's kernel stack for syscalls
    switch (builtin.cpu.arch) {
        .x86_64 => {
            hal.gdt.setKernelStack(idle.kernel_stack_top);
            const gs_base = hal.cpu.readMsr(hal.cpu.IA32_GS_BASE);
            const gs_data = @as(*hal.syscall.KernelGsData, @ptrFromInt(gs_base));
            gs_data.kernel_stack = idle.kernel_stack_top;
            gs_data.current_thread = @intFromPtr(idle);
        },
        .aarch64 => {
            // On ARM, use TPIDR_EL1 for per-CPU data
            const tpidr = asm volatile ("mrs %[ret], tpidr_el1" : [ret] "=r" (-> u64));
            const gs_data: *hal.syscall.KernelGsData = @ptrFromInt(tpidr);
            gs_data.kernel_stack = idle.kernel_stack_top;
            gs_data.current_thread = @intFromPtr(idle);
        },
        else => @compileError("Unsupported architecture"),
    }

    // Switch to idle thread's stack and enable interrupts
    const idle_stack = idle.kernel_stack_top;

    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\mov %[stack], %%rsp
            \\mov %%rsp, %%rbp
            \\sti
            \\1: hlt
            \\jmp 1b
            :
            : [stack] "r" (idle_stack)
        ),
        .aarch64 => asm volatile (
            \\mov sp, %[stack]
            \\mov x29, xzr
            \\msr daifclr, #2
            \\1: wfi
            \\b 1b
            :
            : [stack] "r" (idle_stack)
        ),
        else => @compileError("Unsupported architecture"),
    }


    unreachable;
}

/// Start scheduler on AP
pub fn startAp() noreturn {
    // Get idle thread pointer directly from GS:40 inline
    const idle_ptr: u64 = switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("movq %%gs:40, %[ret]" : [ret] "=r" (-> u64)),
        .aarch64 => blk: {
            const gs_data_ptr = asm volatile ("mrs %[ret], tpidr_el1" : [ret] "=r" (-> u64));
            const gs_data = @as(*hal.syscall.KernelGsData, @ptrFromInt(gs_data_ptr));
            break :blk gs_data.idle_thread;
        },
        else => @compileError("Unsupported architecture"),
    };

    const idle: *Thread = @ptrFromInt(idle_ptr);

    thread_logic.setCurrentThread(idle);
    idle.state = .Running;

    hal.gdt.setKernelStack(idle.kernel_stack_top);
    const gs_base = hal.cpu.readMsr(hal.cpu.IA32_GS_BASE);
    const gs_data = @as(*hal.syscall.KernelGsData, @ptrFromInt(gs_base));
    gs_data.kernel_stack = idle.kernel_stack_top;
    gs_data.current_thread = @intFromPtr(idle);

    const idle_stack = idle.kernel_stack_top;

    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\mov %[stack], %%rsp
            \\mov %%rsp, %%rbp
            \\sti
            \\1: hlt
            \\jmp 1b
            :
            : [stack] "r" (idle_stack)
        ),
        .aarch64 => asm volatile (
            \\mov sp, %[stack]
            \\mov x29, xzr
            \\msr daifclr, #2
            \\1: wfi
            \\b 1b
            :
            : [stack] "r" (idle_stack)
        ),
        else => @compileError("Unsupported architecture"),
    }


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
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("int $32"),
        .aarch64 => {
            // Pending: Hardware timer will trigger or we can force an exception
            // For now, enable interrupts and wait for the tick
            asm volatile ("msr daifclr, #2");
        },
        else => {},
    }
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

/// Process alarm expirations and deliver SIGALRM
/// CALLER MUST HOLD alarm_lock
fn processAlarmExpirations(now: u64) void {
    const uapi = @import("uapi");

    while (scheduler.alarm_head) |proc| {
        if (proc.alarm_deadline > now) break; // Future alarm

        // Deliver SIGALRM to target thread
        // MVP: Deliver to the thread that called alarm(). If that thread exited,
        // the signal is lost (acceptable for Phase 1).
        if (proc.alarm_target_thread) |thread_ptr| {
            const thread: *Thread = @ptrCast(@alignCast(thread_ptr));

            // Set SIGALRM pending bit (signal number 14)
            // Atomic for SMP safety - signalfd and signal handlers clear bits concurrently
            const sig_bit: u64 = @as(u64, 1) << @intCast(uapi.signal.SIGALRM - 1);
            _ = @atomicRmw(u64, &thread.pending_signals, .Or, sig_bit, .release);

            // Wake thread if blocked so signal handler can run
            if (thread.state == .Blocked) {
                unblock(thread);
            }
        }

        // Remove from alarm list
        removeFromAlarmList(proc);
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

    // Trigger reschedule so the next runnable thread gets picked.
    // currentThread is null, so doPerCpuSchedule will skip saving state
    // and just pick the next thread from the ready queue.
    // The ISR context-switches to the new thread; this code is never reached again.
    schedule_sync();

    // Safety: if schedule_sync somehow returns, halt with interrupts enabled
    // so the periodic timer can still fire and schedule other threads.
    while (true) {
        hal.cpu.enableAndHalt();
    }
}

// === Timer Tick & Scheduling ===

/// Timer tick handler - called from IRQ0 handler
/// On x86_64: returns new InterruptFrame pointer for context switch
/// On AArch64: returns new SP value for context switch (0 if no switch needed)
pub fn timerTick(frame: if (builtin.cpu.arch == .x86_64) *hal.interrupts.InterruptFrame else *const hal.interrupts.InterruptFrame) if (builtin.cpu.arch == .x86_64) *hal.idt.InterruptFrame else u64 {
    const local_tick_count = scheduler.tick_count.fetchAdd(1, .monotonic) + 1;

    // Architecture-specific: Poll XHCI on platforms without MSI-X
    if (builtin.cpu.arch == .aarch64) {
        const usb = @import("usb");
        _ = usb.xhci.interrupts.pollAllControllers();
    }

    // CPU time tracking and interval timer processing
    if (thread_logic.getCurrentThread()) |current_thread| {
        if (current_thread.process) |proc_ptr| {
            const proc = @as(*@import("process").Process, @ptrCast(@alignCast(proc_ptr)));
            accumulateCpuTime(current_thread, frame);
            processIntervalTimers(proc, current_thread, frame);
        }
    }

    // Update load averages every 5 seconds (500 ticks)
    if (local_tick_count - scheduler.load_last_update >= 500) {
        updateLoadAverages(local_tick_count);
    }

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

    // Process alarm expirations
    if (scheduler.alarm_lock.tryAcquire()) |alarm_held| {
        processAlarmExpirations(local_tick_count);
        alarm_held.release();
    }

    if (tick_cb) |cb| cb();

    // Don't do scheduling if scheduler hasn't started yet
    if (!is_running) {
        if (builtin.cpu.arch == .x86_64) {
            return frame;
        }
        return 0; // No context switch
    }

    return doPerCpuSchedule(frame);
}

/// Per-CPU scheduling logic
/// On x86_64: returns new InterruptFrame pointer
/// On AArch64: returns new SP value for context switch
fn doPerCpuSchedule(frame: *const hal.interrupts.InterruptFrame) if (builtin.cpu.arch == .x86_64) *hal.idt.InterruptFrame else u64 {
    const current = thread_logic.getCurrentThread();
    const idle = thread_logic.getIdleThread();

    if (current) |curr| {
        curr.kernel_rsp = @intFromPtr(frame);

        if (curr.fpu_used) {
            fpu.saveState(curr.fpu_state_buffer);
        }

        // Don't add the idle thread to the ready queue - it's the fallback
        // when the queue is empty. Adding it pollutes the queue and delays
        // real threads from being scheduled.
        if (curr.state == .Running and curr != idle) {
            cpu_mod.addToReadyQueue(curr);
        }
    }

    var next_thread = cpu_mod.removeFromReadyQueue();

    // Skip stopped threads (job control)
    // Stopped threads should be Blocked, but check as a safety measure
    while (next_thread) |t| {
        if (!t.stopped) {
            break;
        }
        // Thread is stopped - put it back in blocked state and get another
        t.state = .Blocked;
        next_thread = cpu_mod.removeFromReadyQueue();
    }

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

        // x86_64: Update TSS with new kernel stack
        if (builtin.cpu.arch == .x86_64) {
            gdt.setKernelStack(next.kernel_stack_top);
        }

        // Update per-CPU data with new kernel stack
        if (builtin.cpu.arch == .x86_64) {
            const gs_base = hal.cpu.readMsr(hal.cpu.IA32_GS_BASE);
            const gs_data = @as(*hal.syscall.KernelGsData, @ptrFromInt(gs_base));
            gs_data.kernel_stack = next.kernel_stack_top;
        } else if (builtin.cpu.arch == .aarch64) {
            const tpidr = asm volatile ("mrs %[ret], tpidr_el1" : [ret] "=r" (-> u64));
            const gs_data: *hal.syscall.KernelGsData = @ptrFromInt(tpidr);
            gs_data.kernel_stack = next.kernel_stack_top;
        }

        if (next.cr3 != 0) {
            const current_cr3 = hal.cpu.readCr3();
            if (next.cr3 != current_cr3) {
                // SECURITY: Issue IBPB when switching address spaces to prevent
                // Spectre v2 attacks where an attacker could train the branch
                // predictor in one address space to leak data from another.
                if (builtin.cpu.arch == .x86_64) {
                    hal.cpu.issueIbpbIfNeeded(current_cr3, next.cr3);
                }
                // On AArch64, user processes use TTBR0_EL1 (not TTBR1_EL1)
                if (builtin.cpu.arch == .aarch64) {
                    hal.cpu.writeTtbr0(next.cr3);
                } else {
                    hal.cpu.writeCr3(next.cr3);
                }
            }
        }

        const current_fs = if (current) |c| c.fs_base else 0;
        if (next.fs_base != current_fs) {
            hal.cpu.writeMsr(hal.cpu.IA32_FS_BASE, next.fs_base);
        }

        // FPU context switching strategy:
        // - x86_64: Lazy restore via CR0.TS trap (#NM exception triggers handleFpuAccess)
        // - AArch64: Eager restore (no lazy mechanism available - CPACR_EL1 trap not implemented)
        //
        // SECURITY: We do NOT reset next.fpu_used here. That flag indicates whether
        // the thread has saved FPU state that needs restoring. Resetting it would
        // cause handleFpuAccess to skip restoration, leaking previous thread's FPU data.
        if (builtin.cpu.arch == .aarch64) {
            // Eager FPU restore on AArch64 - prevents info leak between threads
            if (next.fpu_used) {
                fpu.restoreState(next.fpu_state_buffer);
            }
        } else {
            // Lazy FPU on x86_64 - CR0.TS triggers #NM on first FPU access
            fpu.setTaskSwitched();
        }

        // Debug: log context switch on AArch64
        if (builtin.cpu.arch == .aarch64 and config.debug_scheduler) {
            const src_frame: *const hal.interrupts.InterruptFrame = @ptrFromInt(next.kernel_rsp);
            console.debug("AArch64 ctx: new_sp={x}, elr={x}, spsr={x}, sp_el0={x}", .{
                next.kernel_rsp,
                src_frame.elr,
                src_frame.spsr,
                src_frame.sp_el0,
            });
        }
    }

    next.last_cpu = @intCast(cpu_mod.getCurrentCpuIndex());
    next.state = .Running;
    thread_logic.setCurrentThread(next);

    // Return new stack pointer for context switch
    // On AArch64, assembly will switch SP to this value before RESTORE_CONTEXT
    // On x86_64, ISR uses this as new frame pointer
    if (builtin.cpu.arch == .aarch64) {
        return next.kernel_rsp;
    } else {
        return @ptrFromInt(next.kernel_rsp);
    }
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

// === CPU Time Tracking & Interval Timers ===

/// Accumulate CPU time for the current thread
/// Determines if thread is in user or kernel mode and increments appropriate counter
fn accumulateCpuTime(thread: *Thread, frame: *const hal.interrupts.InterruptFrame) void {
    // Determine CPU mode from saved context
    const in_user_mode = if (builtin.cpu.arch == .x86_64)
        (frame.cs & 3) == 3 // RPL bits 0-1, Ring 3 = user mode
    else
        frame.elr >= 0x0000_0000_0000_0000 and frame.elr < 0xFFFF_0000_0000_0000; // aarch64 EL0 address space

    if (in_user_mode) {
        thread.utime += 1;
    } else {
        thread.stime += 1;
    }
}

/// Process interval timers for a process
/// Decrements timer values and delivers signals on expiry
fn processIntervalTimers(proc: *@import("process").Process, thread: *Thread, frame: *const hal.interrupts.InterruptFrame) void {
    const TICK_MICROS: u64 = 10000; // 10ms per tick (100 Hz)
    const uapi = @import("uapi");

    // Determine if thread is in user mode
    const in_user_mode = if (builtin.cpu.arch == .x86_64)
        (frame.cs & 3) == 3
    else
        frame.elr >= 0x0000_0000_0000_0000 and frame.elr < 0xFFFF_0000_0000_0000;

    // ITIMER_REAL (always decrements)
    if (proc.itimer_real_value > 0) {
        if (proc.itimer_real_value <= TICK_MICROS) {
            // Set SIGALRM pending bit (signal number 14)
            const sig_bit: u64 = @as(u64, 1) << @intCast(uapi.signal.SIGALRM - 1);
            _ = @atomicRmw(u64, &thread.pending_signals, .Or, sig_bit, .seq_cst);
            proc.itimer_real_value = proc.itimer_real_interval; // Reload for periodic
        } else {
            proc.itimer_real_value -= TICK_MICROS;
        }
    }

    // ITIMER_VIRTUAL (only user mode)
    if (in_user_mode and proc.itimer_virtual_value > 0) {
        if (proc.itimer_virtual_value <= TICK_MICROS) {
            // Set SIGVTALRM pending bit (signal number 26)
            const sig_bit: u64 = @as(u64, 1) << @intCast(uapi.signal.SIGVTALRM - 1);
            _ = @atomicRmw(u64, &thread.pending_signals, .Or, sig_bit, .seq_cst);
            proc.itimer_virtual_value = proc.itimer_virtual_interval;
        } else {
            proc.itimer_virtual_value -= TICK_MICROS;
        }
    }

    // ITIMER_PROF (both user and kernel)
    if (proc.itimer_prof_value > 0) {
        if (proc.itimer_prof_value <= TICK_MICROS) {
            // Set SIGPROF pending bit (signal number 27)
            const sig_bit: u64 = @as(u64, 1) << @intCast(uapi.signal.SIGPROF - 1);
            _ = @atomicRmw(u64, &thread.pending_signals, .Or, sig_bit, .seq_cst);
            proc.itimer_prof_value = proc.itimer_prof_interval;
        } else {
            proc.itimer_prof_value -= TICK_MICROS;
        }
    }

    // POSIX timers (timer_create/timer_settime)
    for (&proc.posix_timers) |*timer| {
        if (!timer.active or timer.value_ns == 0) continue;

        // Check if previously pending signal was consumed (delivered or cleared)
        if (timer.signal_pending and timer.notify == 0) {
            const sig_bit: u64 = @as(u64, 1) << @intCast(timer.signo - 1);
            const pending = @atomicLoad(u64, &thread.pending_signals, .acquire);
            if ((pending & sig_bit) == 0) {
                // Signal was consumed by the signal handler
                timer.signal_pending = false;
                // Note: overrun_count is NOT reset here. It persists until
                // timer_getoverrun is called or timer is re-armed.
            }
        }

        if (timer.value_ns <= TICK_MICROS * 1000) {
            // Timer expired
            if (timer.notify == 0) { // SIGEV_SIGNAL
                if (timer.signal_pending) {
                    // Overrun: signal not yet consumed, count it
                    timer.overrun_count +|= 1;
                } else {
                    // Deliver signal to thread
                    const sig_bit: u64 = @as(u64, 1) << @intCast(timer.signo - 1);
                    _ = @atomicRmw(u64, &thread.pending_signals, .Or, sig_bit, .release);
                    timer.signal_pending = true;
                }
            } else if (timer.notify == 1) { // SIGEV_NONE
                timer.overrun_count +|= 1;
            }

            // Reload (periodic) or disarm (one-shot)
            timer.value_ns = timer.interval_ns;
        } else {
            timer.value_ns -= TICK_MICROS * 1000;
        }
    }
}

/// Update load averages using exponential moving average
/// Called every 5 seconds (500 ticks)
fn updateLoadAverages(now: u64) void {
    // Count runnable threads across all CPUs
    var n_running: usize = 0;
    const cpu_count = @atomicLoad(u32, &cpu_mod.active_cpu_count, .acquire);

    for (cpu_mod.cpu_sched[0..cpu_count]) |*cpu_data| {
        if (cpu_data.initialized) {
            const held_cpu = cpu_data.lock.acquire();
            defer held_cpu.release();
            n_running += cpu_data.ready_queue.count;
        }
    }

    // Add currently running threads (one per CPU)
    n_running += cpu_count;

    // Fixed-point math: load = n_running * 65536
    const n_running_fp: u64 = @as(u64, n_running) << 16;

    // Exponential decay constants (precomputed e^(-5/T) * 65536)
    // 1 min:  exp(-5/60)  * 65536 = 59460
    // 5 min:  exp(-5/300) * 65536 = 64419
    // 15 min: exp(-5/900) * 65536 = 65172
    const EXP_1:  u64 = 59460;
    const EXP_5:  u64 = 64419;
    const EXP_15: u64 = 65172;

    // Update each load average: load = load * exp + n * (1 - exp)
    scheduler.load_1min = (scheduler.load_1min * EXP_1 + n_running_fp * (65536 - EXP_1)) >> 16;
    scheduler.load_5min = (scheduler.load_5min * EXP_5 + n_running_fp * (65536 - EXP_5)) >> 16;
    scheduler.load_15min = (scheduler.load_15min * EXP_15 + n_running_fp * (65536 - EXP_15)) >> 16;

    scheduler.load_last_update = now;
}

/// Get load averages for sysinfo syscall
pub fn getLoadAverages() [3]usize {
    return [3]usize{
        @intCast(scheduler.load_1min),
        @intCast(scheduler.load_5min),
        @intCast(scheduler.load_15min),
    };
}
