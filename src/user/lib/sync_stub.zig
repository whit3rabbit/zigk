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
