// Synchronization Abstractions for Network Stack
//
// Allows the network stack to be used in different environments (kernel, userspace, etc.)
// by injecting lock implementations.

/// Lock interface (Mutex/Spinlock)
pub const Lock = struct {
    /// Opaque pointer to the actual lock instance
    ctx: *anyopaque,
    /// Function to acquire the lock
    acquireFn: *const fn (*anyopaque) void,
    /// Function to release the lock
    releaseFn: *const fn (*anyopaque) void,

    pub fn acquire(self: Lock) void {
        self.acquireFn(self.ctx);
    }

    pub fn release(self: Lock) void {
        self.releaseFn(self.ctx);
    }
};

// No-op implementation for when no locking is configured
fn noop(_: *anyopaque) void {}
var dummy_ctx: u8 = 0;

/// Default no-op lock
pub const noop_lock = Lock{
    .ctx = &dummy_ctx,
    .acquireFn = noop,
    .releaseFn = noop,
};
