// Time functions (time.h)
//
// Provides POSIX time functions for getting the current time.

const syscall = @import("syscall.zig");

/// Time type - seconds since Unix epoch
pub const time_t = i64;

/// Get current time in seconds since Unix epoch
/// If t is non-null, also stores result in *t
pub export fn time(t: ?*time_t) time_t {
    var ts: syscall.Timespec = undefined;
    syscall.clock_gettime(.REALTIME, &ts) catch {
        if (t) |ptr| ptr.* = -1;
        return -1;
    };
    const result = ts.tv_sec;
    if (t) |ptr| ptr.* = result;
    return result;
}

/// Clock types for clock_gettime
pub const CLOCK_REALTIME: c_int = 0;
pub const CLOCK_MONOTONIC: c_int = 1;
pub const CLOCK_PROCESS_CPUTIME_ID: c_int = 2;
pub const CLOCK_THREAD_CPUTIME_ID: c_int = 3;

/// Timespec structure (matching POSIX)
pub const timespec = extern struct {
    tv_sec: time_t,
    tv_nsec: c_long,
};

/// Get time from specified clock
pub export fn clock_gettime(clk_id: c_int, tp: ?*timespec) c_int {
    if (tp == null) return -1;

    const clock_id: syscall.ClockId = switch (clk_id) {
        0 => .REALTIME,
        1 => .MONOTONIC,
        2 => .PROCESS_CPUTIME_ID,
        3 => .THREAD_CPUTIME_ID,
        else => return -1,
    };

    var ts: syscall.Timespec = undefined;
    syscall.clock_gettime(clock_id, &ts) catch return -1;

    const out = tp.?;
    out.tv_sec = ts.tv_sec;
    out.tv_nsec = ts.tv_nsec;
    return 0;
}

/// Sleep for specified duration
pub export fn nanosleep(req: ?*const timespec, rem: ?*timespec) c_int {
    if (req == null) return -1;

    const r = req.?;
    var ts = syscall.Timespec{
        .tv_sec = r.tv_sec,
        .tv_nsec = r.tv_nsec,
    };

    var rmt: syscall.Timespec = undefined;
    const rmt_ptr = if (rem != null) &rmt else null;

    syscall.nanosleep(&ts, rmt_ptr) catch {
        // If interrupted, store remaining time
        if (rem) |remaining| {
            remaining.tv_sec = rmt.tv_sec;
            remaining.tv_nsec = rmt.tv_nsec;
        }
        return -1;
    };

    return 0;
}

/// Sleep for specified number of seconds
pub export fn sleep(seconds: c_uint) c_uint {
    const req = timespec{
        .tv_sec = @intCast(seconds),
        .tv_nsec = 0,
    };
    var rem: timespec = undefined;

    if (nanosleep(&req, &rem) < 0) {
        // Return remaining seconds (rounded up)
        if (rem.tv_nsec > 0) {
            return @intCast(rem.tv_sec + 1);
        }
        return @intCast(rem.tv_sec);
    }
    return 0;
}

/// Sleep for specified number of microseconds
pub export fn usleep(usec: c_uint) c_int {
    const req = timespec{
        .tv_sec = @intCast(usec / 1_000_000),
        .tv_nsec = @intCast((usec % 1_000_000) * 1000),
    };

    return nanosleep(&req, null);
}
