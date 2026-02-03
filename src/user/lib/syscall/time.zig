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

// =============================================================================
// System Information & Process Times (99-100)
// =============================================================================

/// System information structure (from sysinfo syscall)
pub const SysInfo = extern struct {
    uptime: i64,
    loads: [3]usize,
    totalram: usize,
    freeram: usize,
    sharedram: usize,
    bufferram: usize,
    totalswap: usize,
    freeswap: usize,
    procs: u16,
    pad: u16,
    totalhigh: usize,
    freehigh: usize,
    mem_unit: u32,
    _reserved: [20]u8,
};

/// Process times structure (from times syscall)
pub const Tms = extern struct {
    tms_utime: i64,
    tms_stime: i64,
    tms_cutime: i64,
    tms_cstime: i64,
};

/// Get system information (uptime, memory, load averages)
pub fn sysinfo(info: *SysInfo) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_SYSINFO, @intFromPtr(info));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get process CPU times
/// Returns current tick count
pub fn times(buf: *Tms) SyscallError!usize {
    const ret = primitive.syscall1(syscalls.SYS_TIMES, @intFromPtr(buf));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// =============================================================================
// Interval Timers (36, 38)
// =============================================================================

/// Timeval structure for interval timers
pub const Timeval = extern struct {
    tv_sec: i64,
    tv_usec: i64,
};

/// Interval timer value structure
pub const ITimerVal = extern struct {
    it_interval: Timeval,
    it_value: Timeval,
};

/// Interval timer types
pub const ITIMER_REAL: u32 = 0; // Wall clock time (SIGALRM)
pub const ITIMER_VIRTUAL: u32 = 1; // User CPU time (SIGVTALRM)
pub const ITIMER_PROF: u32 = 2; // User + Kernel CPU time (SIGPROF)

/// Get interval timer value
pub fn getitimer(which: u32, value: *ITimerVal) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_GETITIMER, which, @intFromPtr(value));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set interval timer
/// If old_value is null, previous value is not returned
pub fn setitimer(which: u32, new_value: *const ITimerVal, old_value: ?*ITimerVal) SyscallError!void {
    const old_ptr: usize = if (old_value) |v| @intFromPtr(v) else 0;
    const ret = primitive.syscall3(syscalls.SYS_SETITIMER, which, @intFromPtr(new_value), old_ptr);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}
