const std = @import("std");
const hal = @import("hal");
const sync = @import("sync");
const console = @import("console");
const config = @import("config");
const kernel_stack = @import("kernel_stack");
const thread_mod = @import("thread"); // src/kernel/thread.zig
const sched_mod = @import("scheduler.zig"); // Circular
const cpu = @import("cpu.zig");

const Thread = thread_mod.Thread;
const ThreadExitCallback = thread_mod.ThreadExitCallback; // Define locally or in kernel/thread.zig?
// sched.zig defined ThreadExitCallback type. 
// "pub const ThreadExitCallback = *const fn (*Thread) void;"
// I'll redefine it or check if thread_mod has it. It wasn't in thread.zig previously.
// I will define it here.

pub const ThreadExitCallbackType = *const fn (*Thread) void;

// Re-export or use local
const gdt = hal.gdt;
const fpu = hal.fpu;

/// Maximum number of threads tracked for TID lookup
const MAX_TRACKED_THREADS: usize = 256;

/// Global thread tracking array for TID lookup
/// Protected by scheduler.lock
var all_threads: [MAX_TRACKED_THREADS]?*Thread = [_]?*Thread{null} ** MAX_TRACKED_THREADS;

/// Registered exit cleanup callbacks (set by syscall modules)
var exit_callbacks: [4]?ThreadExitCallbackType = [_]?ThreadExitCallbackType{null} ** 4;

/// Process tree lock (moved here to avoid circular dep with sync/process)
pub var process_tree_lock: sync.RwLock = .{};

/// Register a callback to be called when a thread exits.
pub fn registerExitCallback(cb: ThreadExitCallbackType) void {
    const held = sched_mod.scheduler.lock.acquire();
    defer held.release();

    for (&exit_callbacks) |*slot| {
        if (slot.* == null) {
            slot.* = cb;
            return;
        }
    }
}

/// Add a thread to the scheduler
/// Thread will be added to the ready queue and registered for TID lookup
pub fn addThread(t: *Thread) void {
    const held = sched_mod.scheduler.lock.acquire();
    defer held.release();

    // Register thread in global tracking array for TID lookup
    for (&all_threads) |*slot| {
        if (slot.* == null) {
            slot.* = t;
            break;
        }
    }

    cpu.addToReadyQueue(t);
}

/// Find a thread by its TID
/// Returns null if not found or if thread has exited
/// WARNING: The returned pointer may become invalid after the lock is released.
/// Caller must ensure thread lifetime or hold appropriate locks during use.
pub fn findThreadByTid(tid: u64) ?*Thread {
    const held = sched_mod.scheduler.lock.acquire();
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
    const held = sched_mod.scheduler.lock.acquire();
    defer held.release();

    for (&all_threads) |*slot| {
        if (slot.* == t) {
            slot.* = null;
            break;
        }
    }
}

/// Get the currently running thread for the current CPU
pub fn getCurrentThread() ?*Thread {
    // Read from GS:current_thread (offset 16)
    const ptr = asm volatile ("movq %%gs:16, %[ret]"
        : [ret] "=r" (-> u64),
    );

    if (ptr == 0) return null;
    return @ptrFromInt(ptr);
}

/// Set the currently running thread for the current CPU
pub fn setCurrentThread(t: ?*Thread) void {
    const val = if (t) |thread_ptr| @intFromPtr(thread_ptr) else 0;
    asm volatile ("movq %[val], %%gs:16"
        :
        : [val] "r" (val),
    );
}

/// Get idle thread for current CPU
pub fn getIdleThread() *Thread {
    // idle_thread is at offset 40 in KernelGsData
    const ptr = asm volatile ("movq %%gs:40, %[ret]"
        : [ret] "=r" (-> u64),
    );
    return @ptrFromInt(ptr);
}

/// Set the per-CPU kernel GS data pointer (Deprecated in SMP)
pub fn setGsData(_: *hal.syscall.KernelGsData) void {
    // No longer used globally
}

// === Guard page helpers ===

/// Check if a fault address is within a thread's guard page
pub fn checkGuardPage(fault_addr: u64) ?hal.interrupts.GuardPageInfo {
    const current = getCurrentThread();

    // Check current thread first
    if (current) |curr| {
        if (isInGuardPage(fault_addr, curr)) {
            return hal.interrupts.GuardPageInfo{
                .thread_id = curr.tid,
                .thread_name = curr.getName(),
                .stack_base = curr.kernel_stack_base,
                .stack_top = curr.kernel_stack_top,
            };
        }
    }

    // Check idle thread (THIS CPU)
    const idle = getIdleThread();
    if (isInGuardPage(fault_addr, idle)) {
         return hal.interrupts.GuardPageInfo{
            .thread_id = idle.tid,
            .thread_name = idle.getName(),
            .stack_base = idle.kernel_stack_base,
            .stack_top = idle.kernel_stack_top,
        };
    }

    // Check all threads in per-CPU ready queues
    const cpu_count = @atomicLoad(u32, &cpu.active_cpu_count, .acquire);
    for (cpu.cpu_sched[0..cpu_count]) |*cpu_data| {
        if (!cpu_data.initialized) continue;

        if (cpu_data.lock.tryAcquire()) |held| {
            defer held.release();

            var t = cpu_data.ready_queue.head;
            while (t) |curr_thread| {
                if (isInGuardPage(fault_addr, curr_thread)) {
                    return hal.interrupts.GuardPageInfo{
                        .thread_id = curr_thread.tid,
                        .thread_name = curr_thread.getName(),
                        .stack_base = curr_thread.kernel_stack_base,
                        .stack_top = curr_thread.kernel_stack_top,
                    };
                }
                t = curr_thread.next;
            }
        }
    }

    // Additional check: if fault is in kernel_stack region guard page
    if (kernel_stack.isGuardPage(fault_addr)) {
        if (kernel_stack.getStackInfoForGuardFault(fault_addr)) |info| {
            return hal.interrupts.GuardPageInfo{
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
fn isInGuardPage(addr: u64, t: *const Thread) bool {
    const page_size: u64 = 4096;
    return addr >= t.kernel_stack_base and addr < t.kernel_stack_base + page_size;
}

/// Handle #NM (Device Not Available) exception for lazy FPU
pub fn handleFpuAccess() bool {
    const current = getCurrentThread();

    // No lock needed - in exception handler context
    if (current) |curr| {
        fpu.clearTaskSwitched();
        if (curr.fpu_used) {
            fpu.fxrstor(&curr.fpu_state);
        } else {
            curr.fpu_used = true;
        }
        return true;
    }
    return false;
}

pub fn getExitCallbacks() []const ?ThreadExitCallbackType {
    return &exit_callbacks;
}
