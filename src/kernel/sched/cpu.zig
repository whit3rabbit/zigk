const std = @import("std");
const hal = @import("hal");
const sync = @import("sync");
const list = @import("list");
const thread_mod = @import("thread"); // src/kernel/thread.zig
const config = @import("config");
const console = @import("console");

const Thread = thread_mod.Thread;

/// Per-CPU scheduler data
/// Each CPU has its own ready queue for cache locality and reduced contention.
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

/// Maximum number of CPUs supported (from GDT)
pub const MAX_CPUS = hal.gdt.MAX_CPUS;

/// Per-CPU scheduler data array
pub var cpu_sched: [MAX_CPUS]CpuSchedulerData = [_]CpuSchedulerData{.{}} ** MAX_CPUS;

/// Number of active CPUs (BSP + booted APs)
pub var active_cpu_count: u32 = 1; // Start with BSP

/// Get current CPU index (clamped to valid range)
pub fn getCurrentCpuIndex() usize {
    const apic_id = hal.apic.lapic.getId();
    if (apic_id >= MAX_CPUS) return 0;
    return @intCast(apic_id);
}

/// Get per-CPU scheduler data for current CPU
pub fn getLocalCpuSched() *CpuSchedulerData {
    return &cpu_sched[getCurrentCpuIndex()];
}

/// Get per-CPU scheduler data for a specific CPU
pub fn getCpuSched(cpu_id: usize) *CpuSchedulerData {
    if (cpu_id >= MAX_CPUS) return &cpu_sched[0];
    return &cpu_sched[cpu_id];
}

/// Helper to check if a CPU is initialized
pub fn isCpuInitialized(cpu_index: usize) bool {
    if (cpu_index >= MAX_CPUS) return false;
    return cpu_sched[cpu_index].initialized;
}

/// Add a thread to the back of the ready queue (per-CPU)
/// Thread is added to:
/// 1. Its last CPU's queue (for cache locality) if valid
/// 2. Otherwise, the current CPU's queue
pub fn addToReadyQueue(t: *Thread) void {
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
pub fn removeFromReadyQueue() ?*Thread {
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

/// Determine target CPU for a thread based on affinity and last_cpu
/// Returns the CPU index where the thread should run
pub fn getTargetCpu(t: *const Thread) usize {
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
