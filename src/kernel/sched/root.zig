const std = @import("std");
const hal = @import("hal");
const thread_mod = @import("thread");

// Import internal submodules
const scheduler = @import("scheduler.zig");
const thread_logic = @import("thread.zig");
const cpu_logic = @import("cpu.zig");
const queue_logic = @import("queue.zig");

// Export public API

// Types
pub const Thread = thread_mod.Thread;
pub const ThreadExitCallback = thread_logic.ThreadExitCallbackType;
pub const CpuSchedulerData = cpu_logic.CpuSchedulerData;
pub const WaitQueue = queue_logic.WaitQueue;
pub const SchedulerStats = scheduler.SchedulerStats;
pub const GuardPageInfo = hal.interrupts.GuardPageInfo;

// Constants
pub const MAX_CPUS = cpu_logic.MAX_CPUS;

// Scheduler Control
pub const init = scheduler.init;
pub const initAp = scheduler.initAp;
pub const start = scheduler.start;
pub const startAp = scheduler.startAp;
pub const isRunning = scheduler.isRunning;
pub const getStats = scheduler.getStats;
pub const setTickCallback = scheduler.setTickCallback;
pub const getTickCount = scheduler.getTickCount;

// Thread Management
pub const addThread = thread_logic.addThread;
pub const findThreadByTid = thread_logic.findThreadByTid;
pub const unregisterThread = thread_logic.unregisterThread;
pub const getCurrentThread = thread_logic.getCurrentThread;
pub const setCurrentThread = thread_logic.setCurrentThread;
pub const getIdleThread = thread_logic.getIdleThread; // Maybe internal?
pub const registerExitCallback = thread_logic.registerExitCallback;
pub const checkGuardPage = thread_logic.checkGuardPage;
pub const handleFpuAccess = thread_logic.handleFpuAccess;
pub const setGsData = thread_logic.setGsData; // Deprecated but might be called

// Context Switching / Blocking
pub const yield = scheduler.yield;
pub const block = scheduler.block;
pub const unblock = scheduler.unblock;
pub const waitOn = scheduler.waitOn;
pub const waitOnWithTimeout = scheduler.waitOnWithTimeout;
pub const cancelTimeoutAndWake = scheduler.cancelTimeoutAndWake;
pub const sleepForTicks = scheduler.sleepForTicks;
pub const wakeOnCpu = scheduler.wakeOnCpu;
pub const exit = scheduler.exit;
pub const exitWithStatus = scheduler.exitWithStatus;
pub const timerTick = scheduler.timerTick; // Called by IRQ wrapper

// CPU Logic (needed by syscalls or debug? Maybe)
pub const getCurrentCpuIndex = cpu_logic.getCurrentCpuIndex;

// Exposed internal for other kernel subsystems if needed
pub const process_tree_lock = &thread_logic.process_tree_lock;

// Scheduler Lock (used by WaitQueue.wakeUp which is inline or generic?)
// WaitQueue methods are in queue.zig, they import scheduler.zig correctly.
// External users shouldn't need the lock exposed directly unless they do manual locking.
// But we expose it just in case some weird futex logic needs it?
// sched.zig exposed `scheduler.lock` implicitly via `scheduler` variable access?
// No, `scheduler` var was private to file in original `sched.zig`, 
// but `pub var scheduler = Scheduler{};` ?
// Original `sched.zig`: `pub var process_tree_lock`, `var scheduler`.
// `scheduler` was private var.
// So external users didn't access `scheduler` directly.
// They used public functions.
// Good.

// Re-export process_tree_lock
// It's a var, so we can't `pub const process_tree_lock = thread_logic.process_tree_lock;` if we want pointer identity?
// `thread_logic.process_tree_lock` is `pub var`.
// Zig re-export: `pub usingnamespace thread_logic;` would export everything.
// But we want selective export.
// `pub var` re-export is tricky. 
// We can use a pointer: `pub const process_tree_lock = &thread_logic.process_tree_lock;` 
// But clients expect a struct instance, not a pointer presumably?
// Original: `pub var process_tree_lock: sync.RwLock = .{};`
// If we change it to a pointer, clients must dereference.
// Let's check usages. `process_tree_lock` usually used as `sched.process_tree_lock.acquireWrite()`.
// If it's a pointer, `sched.process_tree_lock.acquireWrite()` works (auto-deref).
// But `sched.process_tree_lock` signature changes from `RwLock` to `*RwLock`.
// Hopefully fine.

// Wait, `WaitQueue.wakeUp` calls `sched.scheduler.lock.acquire()`.
// It uses `queue.zig` which imports `scheduler.zig`.
// `scheduler.zig` has `pub var scheduler`.
// So that's fine inside the package.
