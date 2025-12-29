// SECURITY NOTE: This is an intentional NO-OP stub for SINGLE-THREADED userspace only.
// This Spinlock provides NO synchronization. It exists solely to satisfy API compatibility
// requirements for code that references spinlock interfaces but runs single-threaded.
//
// WARNING: Do NOT use this in multi-threaded contexts. For multi-threaded userspace,
// implement proper atomics using @atomicRmw or use kernel futex-based mutexes.
//
// The allocator and other modules using this stub are NOT thread-safe.
pub const Spinlock = struct {
    pub const Held = struct {
        pub fn release(self: Held) void {
            _ = self;
        }
    };

    pub fn acquire(self: *Spinlock) Held {
        _ = self;
        return Held{};
    }

    pub fn tryAcquire(self: *Spinlock) ?Held {
        _ = self;
        return Held{};
    }
};
