// Alarm Syscall Handler
//
// Implements alarm(2) - schedule SIGALRM delivery after N seconds
//
// POSIX alarm semantics:
// - One alarm per process (not per thread)
// - Returns remaining seconds from previous alarm (0 if none)
// - alarm(0) cancels pending alarm
// - Precision: 1ms tick granularity (1000 ticks/sec)
//
// SECURITY:
// - Integer overflow protection via clamping
// - No memory allocation (uses pre-allocated Process fields)
// - Bounded alarm list (one per process)

const std = @import("std");
const base = @import("base.zig");
const sched = @import("sched");

const SyscallError = base.SyscallError;

/// sys_alarm (37) - Set alarm to deliver SIGALRM after N seconds
///
/// Args:
///   seconds: Number of seconds until SIGALRM is delivered (0 = cancel)
///
/// Returns:
///   Number of seconds remaining from previous alarm (0 if none)
///
/// Example:
///   alarm(5);        // SIGALRM in 5 seconds, returns 0
///   sleep(2);
///   alarm(3);        // Cancel first alarm, returns 3 (remaining from first)
///   alarm(0);        // Cancel alarm, returns 3 (remaining)
pub fn sys_alarm(seconds: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();

    // SECURITY: Cast to u64 to prevent overflow in scheduler calculations
    const seconds_u64: u64 = @intCast(seconds);

    // Set alarm (scheduler handles clamping and list management)
    const remaining = sched.setAlarm(proc, seconds_u64);

    return remaining;
}
