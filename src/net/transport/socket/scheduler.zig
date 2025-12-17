// Scheduler integration glue for sockets.
// Keeps blocking hooks isolated from protocol code so we can stub or replace them.
//
// SECURITY: All function pointer access is protected by a spinlock to prevent
// TOCTOU races between checking if a pointer is set and calling it.

const sync = @import("sync");

pub const ThreadPtr = ?*anyopaque;
pub const WakeFn = *const fn (ThreadPtr) void;
pub const BlockFn = *const fn () void;
pub const GetCurrentThreadFn = *const fn () ThreadPtr;

/// Protects all function pointer reads and writes
var lock: sync.Spinlock = .{};

var wake_thread_fn: ?WakeFn = null;
var block_thread_fn: ?BlockFn = null;
var get_current_thread_fn: ?GetCurrentThreadFn = null;

/// Set the scheduler callback functions.
/// Called once during kernel init before any socket operations.
pub fn setSchedulerFunctions(wake: WakeFn, block: BlockFn, getCurrent: GetCurrentThreadFn) void {
    const held = lock.acquire();
    defer held.release();
    wake_thread_fn = wake;
    block_thread_fn = block;
    get_current_thread_fn = getCurrent;
}

/// Wake a blocked thread. Safe to call from any context.
pub fn wakeThread(thread: ThreadPtr) void {
    const held = lock.acquire();
    defer held.release();
    if (wake_thread_fn) |wake_fn| {
        if (thread != null) {
            wake_fn(thread);
        }
    }
}

/// Get the block function pointer (caller is responsible for null check).
pub fn blockFn() ?BlockFn {
    const held = lock.acquire();
    defer held.release();
    return block_thread_fn;
}

/// Get the current thread function pointer (caller is responsible for null check).
pub fn currentThreadFn() ?GetCurrentThreadFn {
    const held = lock.acquire();
    defer held.release();
    return get_current_thread_fn;
}
