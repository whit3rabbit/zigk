// Scheduling Syscall Handlers
//
// Implements scheduling and timing syscalls:
// - sys_sched_yield: Yield processor to other threads
// - sys_nanosleep: High-resolution sleep
// - sys_select: I/O multiplexing (stub)
// - sys_clock_gettime: Get time from a clock

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const hal = @import("hal");
const sched = @import("sched");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;

/// Timespec structure (Linux compatible)
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

// =============================================================================
// Scheduling
// =============================================================================

/// sys_sched_yield (24) - Yield processor to other threads
pub fn sys_sched_yield() SyscallError!usize {
    sched.yield();
    return 0;
}

/// sys_nanosleep (35) - High-resolution sleep
///
/// Args:
///   req_ptr: Pointer to timespec with requested sleep duration
///   rem_ptr: Pointer to timespec for remaining time (if interrupted)
///
/// MVP: Busy-waits for the duration. Full implementation would
/// block the thread and use a timer to wake it.
pub fn sys_nanosleep(req_ptr: usize, rem_ptr: usize) SyscallError!usize {
    // Read timespec from userspace
    const req = UserPtr.from(req_ptr).readValue(Timespec) catch {
        return error.EFAULT;
    };

    // Validate timespec values
    if (req.tv_sec < 0 or req.tv_nsec < 0 or req.tv_nsec >= 1_000_000_000) {
        return error.EINVAL;
    }

    const sec_u: u64 = @intCast(req.tv_sec);
    if (sec_u > std.math.maxInt(u64) / 1_000_000_000) {
        return error.EINVAL;
    }

    const sec_ns: u64 = sec_u * 1_000_000_000;
    const nsec_u: u64 = @intCast(req.tv_nsec);
    if (sec_ns > std.math.maxInt(u64) - nsec_u) {
        return error.EINVAL;
    }

    const total_ns = sec_ns + nsec_u;
    if (total_ns == 0) {
        if (rem_ptr != 0) {
            const rem: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
            UserPtr.from(rem_ptr).writeValue(rem) catch {
                return error.EFAULT;
            };
        }
        return 0;
    }

    const tick_ns: u64 = 10_000_000;
    const duration_ticks = std.math.divCeil(u64, total_ns, tick_ns) catch unreachable;

    sched.sleepForTicks(duration_ticks);

    // On success, set remaining time to 0 if pointer provided
    if (rem_ptr != 0) {
        const rem: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
        UserPtr.from(rem_ptr).writeValue(rem) catch {
            return error.EFAULT;
        };
    }

    return 0;
}

/// sys_select (23) - Synchronous I/O multiplexing
///
/// Args:
///   nfds: Highest-numbered file descriptor + 1
///   readfds: FD set to watch for read readiness
///   writefds: FD set to watch for write readiness
///   exceptfds: FD set to watch for exceptions
///   timeout: Maximum wait time
///
/// MVP: Returns -ENOSYS (not implemented)
pub fn sys_select(nfds: usize, readfds: usize, writefds: usize, exceptfds: usize, timeout: usize) SyscallError!usize {
    _ = nfds;
    _ = readfds;
    _ = writefds;
    _ = exceptfds;
    _ = timeout;
    return error.ENOSYS;
}

/// sys_clock_gettime (228) - Get time from a clock
///
/// MVP: Returns tick count converted to timespec.
pub fn sys_clock_gettime(clk_id: usize, tp_ptr: usize) SyscallError!usize {
    _ = clk_id; // Ignore clock ID for MVP (all clocks return same value)

    if (tp_ptr == 0) {
        return error.EFAULT;
    }

    var tp: Timespec = undefined;

    // Try to use TSC-based high resolution timing
    const freq = hal.timing.getTscFrequency();
    if (freq > 0) {
        const tsc = hal.timing.rdtsc();
        // Convert TSC ticks to nanoseconds
        // ns = (tsc * 1_000_000_000) / freq
        // We use 128-bit math implicitly or carefully to avoid overflow
        // u64 * u64 -> u128 isn't directly supported in all simple expressions
        // but Zig has mulWide.
        const tsc_u128 = @as(u128, tsc);
        const ns_u128 = (tsc_u128 * 1_000_000_000) / freq;
        const total_ns: u64 = @truncate(ns_u128);

        // Clamp to i64 max to prevent overflow
        const max_sec: u64 = @intCast(std.math.maxInt(i64));
        const sec_val = total_ns / 1_000_000_000;
        tp = Timespec{
            .tv_sec = if (sec_val > max_sec) std.math.maxInt(i64) else @intCast(sec_val),
            .tv_nsec = @intCast(total_ns % 1_000_000_000),
        };
    } else {
        // Fallback to tick count (10ms resolution)
        const ticks = sched.getTickCount();
        const ms = ticks *| 10; // saturating mul to prevent overflow
        const max_sec_ms: u64 = @intCast(std.math.maxInt(i64));
        const sec_ms = ms / 1000;
        tp = Timespec{
            .tv_sec = if (sec_ms > max_sec_ms) std.math.maxInt(i64) else @intCast(sec_ms),
            .tv_nsec = @intCast((ms % 1000) * 1_000_000),
        };
    }

    UserPtr.from(tp_ptr).writeValue(tp) catch {
        return error.EFAULT;
    };

    return 0;
}

/// sys_clock_getres (229) - Get clock resolution
///
/// MVP: Returns 10ms resolution (tick-based timing)
pub fn sys_clock_getres(clk_id: usize, res_ptr: usize) SyscallError!usize {
    _ = clk_id;

    if (res_ptr == 0) {
        return 0; // NULL res is valid per POSIX
    }

    // Report 10ms resolution (our tick interval)
    const res = Timespec{
        .tv_sec = 0,
        .tv_nsec = 10_000_000, // 10ms in nanoseconds
    };

    UserPtr.from(res_ptr).writeValue(res) catch {
        return error.EFAULT;
    };

    return 0;
}

/// Timeval structure (for gettimeofday)
pub const Timeval = extern struct {
    tv_sec: i64,
    tv_usec: i64,
};

/// sys_gettimeofday (96) - Get time of day (legacy)
///
/// MVP: Returns tick count converted to timeval
pub fn sys_gettimeofday(tv_ptr: usize, tz_ptr: usize) SyscallError!usize {
    _ = tz_ptr; // Timezone not supported

    if (tv_ptr == 0) {
        return 0; // NULL tv is valid
    }

    var tv: Timeval = undefined;

    // Try to use TSC-based high resolution timing
    const freq = hal.timing.getTscFrequency();
    if (freq > 0) {
        const tsc = hal.timing.rdtsc();
        const tsc_u128 = @as(u128, tsc);
        const us_u128 = (tsc_u128 * 1_000_000) / freq;
        const total_us: u64 = @truncate(us_u128);

        // Clamp to i64 max to prevent overflow
        const max_sec_tv: u64 = @intCast(std.math.maxInt(i64));
        const sec_us = total_us / 1_000_000;
        tv = Timeval{
            .tv_sec = if (sec_us > max_sec_tv) std.math.maxInt(i64) else @intCast(sec_us),
            .tv_usec = @intCast(total_us % 1_000_000),
        };
    } else {
        // Fallback to tick count
        const ticks = sched.getTickCount();
        const ms = ticks *| 10; // saturating mul
        const max_sec_tv2: u64 = @intCast(std.math.maxInt(i64));
        const sec_ms2 = ms / 1000;
        tv = Timeval{
            .tv_sec = if (sec_ms2 > max_sec_tv2) std.math.maxInt(i64) else @intCast(sec_ms2),
            .tv_usec = @intCast((ms % 1000) * 1000),
        };
    }

    UserPtr.from(tv_ptr).writeValue(tv) catch {
        return error.EFAULT;
    };

    return 0;
}

// =============================================================================
// Threading Primitives (Stubs)
// =============================================================================

/// sys_futex (202) - Fast userspace locking
///
/// MVP: Stub - returns ENOSYS (threading not fully implemented)
const futex = @import("futex");

/// sys_futex (202) - Fast userspace locking
///
/// Implemented Operations:
/// - FUTEX_WAIT: Wait atomically on a value
/// - FUTEX_WAKE: Wake up waiting threads
///
/// Stubbed Operations:
/// - FUTEX_REQUEUE, FUTEX_LOCK_PI, etc.
pub fn sys_futex(uaddr: usize, op: usize, val: usize, timeout: usize, uaddr2: usize, val3: usize) SyscallError!usize {
    _ = uaddr2;
    _ = val3;

    // Mask out private/clock flags
    const cmd = @as(u32, @truncate(op)) & uapi.futex.FUTEX_CMD_MASK;

    // Validate alignment (must be 4-byte aligned)
    if (uaddr % 4 != 0) {
        return error.EINVAL;
    }

    switch (cmd) {
        uapi.futex.FUTEX_WAIT => {
            // Wait for value at uaddr to be val
            // timeout interpretation: pointer to timespec (absolute or relative?)
            // Linux: relative unless FUTEX_CLOCK_REALTIME is set.
            // For MVP: ignore timeout (infinite wait)
            // Ensure timeout pointer handling if implemented later.
            
            // Cast val to u32
            const val_u32 = @as(u32, @truncate(val));

            // Wait (may return error.Again if value changed, or success if woken)
            futex.wait(uaddr, val_u32, if (timeout != 0) @as(u64, @intCast(timeout)) else null) catch |err| {
                switch (err) {
                    error.Again => return error.EAGAIN, // User value changed
                    error.Fault => return error.EFAULT, // Bad address
                    error.PermDenied => return error.EPERM,
                }
            };
            return 0;
        },
        uapi.futex.FUTEX_WAKE => {
            // Wake up val threads waiting on uaddr
            const val_u32 = @as(u32, @truncate(val));
            const woken = futex.wake(uaddr, val_u32) catch |err| {
                switch (err) {
                     error.Fault => return error.EFAULT,
                     error.PermDenied => return error.EPERM,
                }
            };
            return @as(usize, woken);
        },
        else => {
            return error.ENOSYS;
        },
    }
}

// =============================================================================
// epoll (Stubs)
// =============================================================================

/// sys_epoll_create1 (291) - Create epoll instance
///
/// MVP: Stub - returns ENOSYS
pub fn sys_epoll_create1(flags: usize) SyscallError!usize {
    _ = flags;
    return error.ENOSYS;
}

/// sys_epoll_ctl (233) - Control epoll instance
///
/// MVP: Stub - returns ENOSYS
pub fn sys_epoll_ctl(epfd: usize, op: usize, fd: usize, event: usize) SyscallError!usize {
    _ = epfd;
    _ = op;
    _ = fd;
    _ = event;
    return error.ENOSYS;
}

/// sys_epoll_wait (232) - Wait for epoll events
///
/// MVP: Stub - returns ENOSYS
pub fn sys_epoll_wait(epfd: usize, events: usize, maxevents: usize, timeout: usize) SyscallError!usize {
    _ = epfd;
    _ = events;
    _ = maxevents;
    _ = timeout;
    return error.ENOSYS;
}
