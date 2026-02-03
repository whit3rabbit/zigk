//! Interval timer syscalls (getitimer/setitimer)
//!
//! Implements three types of interval timers:
//! - ITIMER_REAL: Wall clock time (SIGALRM)
//! - ITIMER_VIRTUAL: User CPU time (SIGVTALRM)
//! - ITIMER_PROF: User + Kernel CPU time (SIGPROF)

const uapi = @import("uapi");
const base = @import("base.zig");
const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;

/// Convert microseconds to ITimerVal structure
fn microsecondsToITimerVal(interval_us: u64, value_us: u64) uapi.time.ITimerVal {
    return .{
        .it_interval = .{
            .tv_sec = @intCast(@divTrunc(interval_us, 1_000_000)),
            .tv_usec = @intCast(@mod(interval_us, 1_000_000)),
        },
        .it_value = .{
            .tv_sec = @intCast(@divTrunc(value_us, 1_000_000)),
            .tv_usec = @intCast(@mod(value_us, 1_000_000)),
        },
    };
}

/// Convert TimeVal to microseconds
fn timevalToMicroseconds(tv: uapi.abi.TimeVal) u64 {
    const sec_us = @as(u64, @intCast(tv.tv_sec)) * 1_000_000;
    const usec = @as(u64, @intCast(tv.tv_usec));
    return sec_us + usec;
}

/// Get interval timer value
///
/// Retrieves the current value and interval of an interval timer.
///
/// Arguments:
///   which: Timer type (ITIMER_REAL, ITIMER_VIRTUAL, ITIMER_PROF)
///   value_ptr: Pointer to userspace ITimerVal structure
///
/// Returns:
///   0 on success
///   -EINVAL if which is invalid
///   -EFAULT if value_ptr is invalid
pub fn sys_getitimer(which: usize, value_ptr: usize) SyscallError!usize {
    // Validate timer type
    if (which > 2) {
        return error.EINVAL;
    }

    if (value_ptr == 0) {
        return error.EFAULT;
    }

    const proc = base.getCurrentProcess();
    var value: uapi.time.ITimerVal = undefined;

    // Get timer values based on type
    switch (which) {
        uapi.time.ITIMER_REAL => {
            value = microsecondsToITimerVal(
                proc.itimer_real_interval,
                proc.itimer_real_value,
            );
        },
        uapi.time.ITIMER_VIRTUAL => {
            value = microsecondsToITimerVal(
                proc.itimer_virtual_interval,
                proc.itimer_virtual_value,
            );
        },
        uapi.time.ITIMER_PROF => {
            value = microsecondsToITimerVal(
                proc.itimer_prof_interval,
                proc.itimer_prof_value,
            );
        },
        else => unreachable,
    }

    // Copy to userspace
    UserPtr.from(value_ptr).writeValue(value) catch {
        return error.EFAULT;
    };

    return 0;
}

/// Set interval timer
///
/// Sets an interval timer to deliver a signal after a specified time.
/// If it_interval is non-zero, the timer reloads automatically (periodic).
///
/// Arguments:
///   which: Timer type (ITIMER_REAL, ITIMER_VIRTUAL, ITIMER_PROF)
///   new_value_ptr: Pointer to new timer value (userspace)
///   old_value_ptr: Pointer to receive old value (optional, can be 0)
///
/// Returns:
///   0 on success
///   -EINVAL if which is invalid or value is negative
///   -EFAULT if pointers are invalid
pub fn sys_setitimer(which: usize, new_value_ptr: usize, old_value_ptr: usize) SyscallError!usize {
    // Validate timer type
    if (which > 2) {
        return error.EINVAL;
    }

    if (new_value_ptr == 0) {
        return error.EFAULT;
    }

    const proc = base.getCurrentProcess();

    // Copy new value from userspace
    const new_value = UserPtr.from(new_value_ptr).readValue(uapi.time.ITimerVal) catch {
        return error.EFAULT;
    };

    // Validate time values (must be non-negative)
    if (new_value.it_interval.tv_sec < 0 or new_value.it_interval.tv_usec < 0 or
        new_value.it_value.tv_sec < 0 or new_value.it_value.tv_usec < 0)
    {
        return error.EINVAL;
    }

    // Validate microseconds (must be < 1,000,000)
    if (new_value.it_interval.tv_usec >= 1_000_000 or new_value.it_value.tv_usec >= 1_000_000) {
        return error.EINVAL;
    }

    // Convert to microseconds
    const interval_us = timevalToMicroseconds(new_value.it_interval);
    const value_us = timevalToMicroseconds(new_value.it_value);

    // Get old value and set new value atomically
    var old_value: uapi.time.ITimerVal = undefined;
    switch (which) {
        uapi.time.ITIMER_REAL => {
            old_value = microsecondsToITimerVal(
                proc.itimer_real_interval,
                proc.itimer_real_value,
            );
            proc.itimer_real_interval = interval_us;
            proc.itimer_real_value = value_us;
        },
        uapi.time.ITIMER_VIRTUAL => {
            old_value = microsecondsToITimerVal(
                proc.itimer_virtual_interval,
                proc.itimer_virtual_value,
            );
            proc.itimer_virtual_interval = interval_us;
            proc.itimer_virtual_value = value_us;
        },
        uapi.time.ITIMER_PROF => {
            old_value = microsecondsToITimerVal(
                proc.itimer_prof_interval,
                proc.itimer_prof_value,
            );
            proc.itimer_prof_interval = interval_us;
            proc.itimer_prof_value = value_us;
        },
        else => unreachable,
    }

    // Copy old value to userspace if requested
    if (old_value_ptr != 0) {
        UserPtr.from(old_value_ptr).writeValue(old_value) catch {
            return error.EFAULT;
        };
    }

    return 0;
}
