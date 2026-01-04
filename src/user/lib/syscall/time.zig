const std = @import("std");
const primitive = @import("primitive.zig");
const syscalls = primitive.uapi.syscalls;

pub const SyscallError = primitive.SyscallError;

/// Timespec structure for nanosleep and clock_gettime
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// Clock IDs for clock_gettime
pub const ClockId = enum(i32) {
    REALTIME = 0,
    MONOTONIC = 1,
    PROCESS_CPUTIME_ID = 2,
    THREAD_CPUTIME_ID = 3,
    MONOTONIC_RAW = 4,
    REALTIME_COARSE = 5,
    MONOTONIC_COARSE = 6,
    BOOTTIME = 7,
};

/// High-resolution sleep
/// Sleeps for the time specified in `req`
/// If interrupted, remaining time is stored in `rem` (if non-null)
pub fn nanosleep(req: *const Timespec, rem: ?*Timespec) SyscallError!void {
    const rem_ptr: usize = if (rem) |r| @intFromPtr(r) else 0;
    const ret = primitive.syscall2(syscalls.SYS_NANOSLEEP, @intFromPtr(req), rem_ptr);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Sleep for specified number of milliseconds
pub fn sleep_ms(ms: u64) SyscallError!void {
    const req = Timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1_000_000),
    };
    try nanosleep(&req, null);
}

/// Get time from a clock
pub fn clock_gettime(clk_id: ClockId, tp: *Timespec) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_CLOCK_GETTIME, @bitCast(@as(isize, @intFromEnum(clk_id))), @intFromPtr(tp));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get monotonic time in milliseconds (convenience wrapper)
pub fn gettime_ms() SyscallError!u64 {
    // SECURITY: Zero-initialize to prevent reading uninitialized data if
    // syscall has a bug that doesn't fully populate the struct
    var ts: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    try clock_gettime(.MONOTONIC, &ts);
    // Validate non-negative values before casting to u64
    if (ts.tv_sec < 0 or ts.tv_nsec < 0) return error.Unexpected;
    // Use checked arithmetic to prevent overflow on corrupted/malicious timespec
    const sec_ms = std.math.mul(u64, @intCast(ts.tv_sec), 1000) catch return error.Unexpected;
    const nsec_ms = @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
    return std.math.add(u64, sec_ms, nsec_ms) catch return error.Unexpected;
}

/// Alias for gettime_ms (used by netcfgd)
pub fn getTickMs() u64 {
    return gettime_ms() catch 0;
}
