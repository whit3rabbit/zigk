// Network time source abstraction for deterministic testing.

const platform = @import("platform.zig");

pub const Clock = struct {
    rdtscFn: *const fn () u64,
    hasTimedOutFn: *const fn (start: u64, timeout_us: u64) bool,

    pub fn rdtsc(self: *const Clock) u64 {
        return self.rdtscFn();
    }

    pub fn hasTimedOut(self: *const Clock, start: u64, timeout_us: u64) bool {
        return self.hasTimedOutFn(start, timeout_us);
    }
};

var active_clock: ?Clock = null;

pub fn defaultClock() Clock {
    return .{
        .rdtscFn = platform.timing.rdtsc,
        .hasTimedOutFn = platform.timing.hasTimedOut,
    };
}

pub fn init(clock: Clock) void {
    active_clock = clock;
}

pub fn rdtsc() u64 {
    const clock = active_clock orelse @panic("net clock not initialized");
    return clock.rdtsc();
}

pub fn hasTimedOut(start: u64, timeout_us: u64) bool {
    const clock = active_clock orelse @panic("net clock not initialized");
    return clock.hasTimedOut(start, timeout_us);
}
