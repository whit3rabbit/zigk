// Scheduler integration glue for sockets.
// Keeps blocking hooks isolated from protocol code so we can stub or replace them.

pub const ThreadPtr = ?*anyopaque;
pub const WakeFn = *const fn (ThreadPtr) void;
pub const BlockFn = *const fn () void;
pub const GetCurrentThreadFn = *const fn () ThreadPtr;

var wake_thread_fn: ?WakeFn = null;
var block_thread_fn: ?BlockFn = null;
var get_current_thread_fn: ?GetCurrentThreadFn = null;

pub fn setSchedulerFunctions(wake: WakeFn, block: BlockFn, getCurrent: GetCurrentThreadFn) void {
    wake_thread_fn = wake;
    block_thread_fn = block;
    get_current_thread_fn = getCurrent;
}

pub fn wakeThread(thread: ThreadPtr) void {
    if (wake_thread_fn) |wake_fn| {
        if (thread != null) {
            wake_fn(thread);
        }
    }
}

pub fn blockFn() ?BlockFn {
    return block_thread_fn;
}

pub fn currentThreadFn() ?GetCurrentThreadFn {
    return get_current_thread_fn;
}
