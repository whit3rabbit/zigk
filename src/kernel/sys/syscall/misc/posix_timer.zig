//! POSIX Timer syscalls (timer_create, timer_settime, timer_gettime, timer_getoverrun, timer_delete)
//!
//! Per-process interval timers with signal delivery on expiration.
//! Each process has up to MAX_POSIX_TIMERS (32) timer slots.
//! Timer expiration is checked in the scheduler's timerTick function
//! (inline in processIntervalTimers -- NOT via a cross-module call).
//!
//! Supported notification types:
//! - SIGEV_SIGNAL: Deliver specified signal on expiration (default)
//! - SIGEV_NONE: No notification, just track overruns
//!
//! Precision: 1ms tick granularity (1000 Hz scheduler tick).

const std = @import("std");
const uapi = @import("uapi");
const base = @import("base.zig");
const sched = @import("sched");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;

const MAX_POSIX_TIMERS = uapi.time.MAX_POSIX_TIMERS;
const TICK_NS: u64 = 1_000_000; // 1ms per tick in nanoseconds
const CLOCK_REALTIME: usize = 0;
const CLOCK_MONOTONIC: usize = 1;

/// Create a POSIX per-process timer
///
/// Arguments:
///   clockid: Clock source (CLOCK_REALTIME or CLOCK_MONOTONIC)
///   sevp_ptr: Pointer to sigevent structure (or 0 for default SIGALRM)
///   timerid_ptr: Pointer to receive timer ID
///
/// Returns:
///   0 on success
///   -EINVAL if clockid invalid or sevp contains unsupported notification type
///   -EFAULT if timerid_ptr is invalid
///   -EAGAIN if all timer slots are full
pub fn sys_timer_create(clockid: usize, sevp_ptr: usize, timerid_ptr: usize) SyscallError!usize {
    // Validate clockid
    if (clockid != CLOCK_REALTIME and clockid != CLOCK_MONOTONIC) {
        return error.EINVAL;
    }

    // Validate timerid_ptr
    if (timerid_ptr == 0) {
        return error.EFAULT;
    }

    const proc = base.getCurrentProcess();

    // Parse sigevent if provided
    var signo: u8 = 14; // Default: SIGALRM
    var notify: i32 = 0; // Default: SIGEV_SIGNAL

    if (sevp_ptr != 0) {
        const sevp_uptr = UserPtr.from(sevp_ptr);
        const sevp = sevp_uptr.readValue(uapi.time.SigEvent) catch return error.EFAULT;

        // Validate notification type
        if (sevp.sigev_notify != 0 and sevp.sigev_notify != 1) {
            // SIGEV_THREAD (2) and SIGEV_THREAD_ID (4) not supported
            return error.EINVAL;
        }

        // Validate signal number for SIGEV_SIGNAL
        if (sevp.sigev_notify == 0) { // SIGEV_SIGNAL
            if (sevp.sigev_signo < 1 or sevp.sigev_signo > 64) {
                return error.EINVAL;
            }
            signo = @intCast(sevp.sigev_signo);
        }

        notify = sevp.sigev_notify;
    }

    // Find first inactive timer slot
    var slot_index: ?usize = null;
    for (&proc.posix_timers, 0..) |*timer, i| {
        if (!timer.active) {
            slot_index = i;
            break;
        }
    }

    if (slot_index == null) {
        return error.EAGAIN; // All slots full
    }

    const idx = slot_index.?;

    // Initialize timer slot
    proc.posix_timers[idx] = .{
        .active = true,
        .clockid = clockid,
        .signo = signo,
        .notify = notify,
        .value_ns = 0,
        .interval_ns = 0,
        .overrun_count = 0,
        .signal_pending = false,
    };
    proc.posix_timer_count +|= 1; // saturating add (defensive)

    // Write timer ID to userspace
    const timerid_uptr = UserPtr.from(timerid_ptr);
    timerid_uptr.writeValue(@as(i32, @intCast(idx))) catch return error.EFAULT;

    return 0;
}

/// Arm or disarm a POSIX timer
///
/// Arguments:
///   timerid: Timer ID (0 to MAX_POSIX_TIMERS-1)
///   flags: TIMER_ABSTIME if new_value is absolute time
///   new_value_ptr: Pointer to new timer value/interval
///   old_value_ptr: Pointer to receive old timer value (or 0)
///
/// Returns:
///   0 on success
///   -EINVAL if timerid invalid or timer not active
///   -EFAULT if new_value_ptr invalid
pub fn sys_timer_settime(timerid: usize, flags: u32, new_value_ptr: usize, old_value_ptr: usize) SyscallError!usize {
    // Validate timerid
    if (timerid >= MAX_POSIX_TIMERS) {
        return error.EINVAL;
    }

    // Validate new_value_ptr
    if (new_value_ptr == 0) {
        return error.EFAULT;
    }

    const proc = base.getCurrentProcess();

    // Check if timer is active
    if (!proc.posix_timers[timerid].active) {
        return error.EINVAL;
    }

    // Read new value from userspace
    const new_value_uptr = UserPtr.from(new_value_ptr);
    const new_value = new_value_uptr.readValue(uapi.time.ITimerspec) catch return error.EFAULT;

    // If old_value_ptr provided, write current timer state
    if (old_value_ptr != 0) {
        const old_value_uptr = UserPtr.from(old_value_ptr);
        const old_spec = uapi.time.ITimerspec{
            .it_interval = .{
                .tv_sec = @intCast(@divTrunc(proc.posix_timers[timerid].interval_ns, 1_000_000_000)),
                .tv_nsec = @intCast(@mod(proc.posix_timers[timerid].interval_ns, 1_000_000_000)),
            },
            .it_value = .{
                .tv_sec = @intCast(@divTrunc(proc.posix_timers[timerid].value_ns, 1_000_000_000)),
                .tv_nsec = @intCast(@mod(proc.posix_timers[timerid].value_ns, 1_000_000_000)),
            },
        };
        old_value_uptr.writeValue(old_spec) catch return error.EFAULT;
    }

    // Convert new value to nanoseconds with overflow checking
    const value_sec_ns = std.math.mul(u64, @as(u64, @intCast(@max(0, new_value.it_value.tv_sec))), 1_000_000_000) catch return error.EINVAL;
    const value_ns = std.math.add(u64, value_sec_ns, @as(u64, @intCast(@max(0, new_value.it_value.tv_nsec)))) catch return error.EINVAL;

    const interval_sec_ns = std.math.mul(u64, @as(u64, @intCast(@max(0, new_value.it_interval.tv_sec))), 1_000_000_000) catch return error.EINVAL;
    const interval_ns = std.math.add(u64, interval_sec_ns, @as(u64, @intCast(@max(0, new_value.it_interval.tv_nsec)))) catch return error.EINVAL;

    // Handle absolute time
    var final_value_ns = value_ns;
    if ((flags & uapi.time.TIMER_ABSTIME) != 0) {
        // Convert absolute time to relative
        const current_time_ns = sched.getTickCount() * TICK_NS;
        if (value_ns <= current_time_ns) {
            // Already past, fire on next tick
            final_value_ns = 1;
        } else {
            final_value_ns = value_ns - current_time_ns;
        }
    }

    // Update timer
    proc.posix_timers[timerid].value_ns = final_value_ns;
    proc.posix_timers[timerid].interval_ns = interval_ns;
    proc.posix_timers[timerid].overrun_count = 0;
    proc.posix_timers[timerid].signal_pending = false;

    return 0;
}

/// Get remaining time on a POSIX timer
///
/// Arguments:
///   timerid: Timer ID (0 to MAX_POSIX_TIMERS-1)
///   curr_value_ptr: Pointer to receive current timer value
///
/// Returns:
///   0 on success
///   -EINVAL if timerid invalid or timer not active
///   -EFAULT if curr_value_ptr invalid
pub fn sys_timer_gettime(timerid: usize, curr_value_ptr: usize) SyscallError!usize {
    // Validate timerid
    if (timerid >= MAX_POSIX_TIMERS) {
        return error.EINVAL;
    }

    // Validate curr_value_ptr
    if (curr_value_ptr == 0) {
        return error.EFAULT;
    }

    const proc = base.getCurrentProcess();

    // Check if timer is active
    if (!proc.posix_timers[timerid].active) {
        return error.EINVAL;
    }

    // Build ITimerspec from current timer state
    const curr_spec = uapi.time.ITimerspec{
        .it_interval = .{
            .tv_sec = @intCast(@divTrunc(proc.posix_timers[timerid].interval_ns, 1_000_000_000)),
            .tv_nsec = @intCast(@mod(proc.posix_timers[timerid].interval_ns, 1_000_000_000)),
        },
        .it_value = .{
            .tv_sec = @intCast(@divTrunc(proc.posix_timers[timerid].value_ns, 1_000_000_000)),
            .tv_nsec = @intCast(@mod(proc.posix_timers[timerid].value_ns, 1_000_000_000)),
        },
    };

    // Write to userspace
    const curr_value_uptr = UserPtr.from(curr_value_ptr);
    curr_value_uptr.writeValue(curr_spec) catch return error.EFAULT;

    return 0;
}

/// Get overrun count for a POSIX timer
///
/// Arguments:
///   timerid: Timer ID (0 to MAX_POSIX_TIMERS-1)
///
/// Returns:
///   Overrun count on success
///   -EINVAL if timerid invalid or timer not active
pub fn sys_timer_getoverrun(timerid: usize) SyscallError!usize {
    // Validate timerid
    if (timerid >= MAX_POSIX_TIMERS) {
        return error.EINVAL;
    }

    const proc = base.getCurrentProcess();

    // Check if timer is active
    if (!proc.posix_timers[timerid].active) {
        return error.EINVAL;
    }

    return proc.posix_timers[timerid].overrun_count;
}

/// Delete a POSIX timer
///
/// Arguments:
///   timerid: Timer ID (0 to MAX_POSIX_TIMERS-1)
///
/// Returns:
///   0 on success
///   -EINVAL if timerid invalid or timer not active
pub fn sys_timer_delete(timerid: usize) SyscallError!usize {
    // Validate timerid
    if (timerid >= MAX_POSIX_TIMERS) {
        return error.EINVAL;
    }

    const proc = base.getCurrentProcess();

    // Check if timer is active
    if (!proc.posix_timers[timerid].active) {
        return error.EINVAL;
    }

    // Mark slot inactive
    proc.posix_timers[timerid].active = false;
    proc.posix_timers[timerid].value_ns = 0;
    proc.posix_timers[timerid].interval_ns = 0;
    proc.posix_timers[timerid].overrun_count = 0;
    proc.posix_timers[timerid].signal_pending = false;
    proc.posix_timer_count -|= 1; // saturating sub (defensive)

    return 0;
}
