//! Timerfd System Call Implementation
//!
//! Implements timerfd_create, timerfd_settime, and timerfd_gettime syscalls
//! for timer notifications via file descriptors.
//!
//! Timerfd provides a file descriptor-based timer notification mechanism
//! that integrates with epoll for event-driven architectures.
//!
//! Features:
//! - One-shot and periodic timers
//! - Relative and absolute time modes (TFD_TIMER_ABSTIME)
//! - CLOCK_REALTIME and CLOCK_MONOTONIC support
//! - Nonblocking mode (TFD_NONBLOCK)
//! - Epoll integration via poll()
//!
//! Design: Polling-based expiration
//! - TimerFdState stores absolute expiration time
//! - read() checks current time vs expiration, calculates elapsed intervals
//! - No TimerWheel dependency - simpler implementation, 10ms granularity

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const heap = @import("heap");
const fd_mod = @import("fd");
const sched = @import("sched");
const sync = @import("sync");
const hal = @import("hal");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;
const Errno = uapi.errno.Errno;

/// Timerfd state
const TimerFdState = struct {
    clockid: i32,
    lock: sync.Spinlock,
    armed: bool,
    next_expiry_ns: u64,
    interval_ns: u64,
    expiry_count: u64,
    blocked_readers: ?*sched.Thread,
    reader_woken: std.atomic.Value(bool),

    fn init(clockid: i32) TimerFdState {
        return TimerFdState{
            .clockid = clockid,
            .lock = .{},
            .armed = false,
            .next_expiry_ns = 0,
            .interval_ns = 0,
            .expiry_count = 0,
            .blocked_readers = null,
            .reader_woken = std.atomic.Value(bool).init(false),
        };
    }
};

/// Get current time in nanoseconds for a given clock ID
fn getClockNanoseconds(clockid: i32) u64 {
    // Reuse the logic from sys_clock_gettime in scheduling.zig
    // For CLOCK_MONOTONIC: use TSC or tick count
    // For CLOCK_REALTIME: use RTC or fall back to monotonic

    const CLOCK_REALTIME: i32 = 0;
    const CLOCK_MONOTONIC: i32 = 1;
    const CLOCK_BOOTTIME: i32 = 7;

    if (clockid == CLOCK_REALTIME) {
        // Try RTC first, fall back to monotonic
        if (hal.rtc.isInitialized()) {
            const timestamp = hal.rtc.getUnixTimestamp();
            return @as(u64, @intCast(timestamp)) * 1_000_000_000;
        }
    }

    // CLOCK_MONOTONIC or CLOCK_BOOTTIME or REALTIME fallback
    if (clockid == CLOCK_MONOTONIC or clockid == CLOCK_BOOTTIME or clockid == CLOCK_REALTIME) {
        const freq = hal.timing.getTscFrequency();
        if (freq > 0) {
            const tsc = hal.timing.rdtsc();
            const tsc_u128 = @as(u128, tsc);
            const ns_u128 = (tsc_u128 * 1_000_000_000) / freq;
            return @truncate(ns_u128);
        } else {
            // Fallback to tick count (10ms resolution)
            const ticks = sched.getTickCount();
            const ms = ticks *| 10; // saturating mul
            return ms * 1_000_000; // ms to ns
        }
    }

    // Unknown clock - return 0
    return 0;
}

/// Convert timespec to nanoseconds
fn timespecToNanoseconds(ts: uapi.abi.Timespec) u64 {
    const sec_ns: u64 = @as(u64, @intCast(@max(0, ts.tv_sec))) * 1_000_000_000;
    const nsec: u64 = @as(u64, @intCast(@max(0, ts.tv_nsec)));
    return sec_ns + nsec;
}

/// Convert nanoseconds to timespec
fn nanosecondsToTimespec(ns: u64) uapi.abi.Timespec {
    return .{
        .tv_sec = @intCast(ns / 1_000_000_000),
        .tv_nsec = @intCast(ns % 1_000_000_000),
    };
}

/// Update expiry count by checking if timer has expired
/// Must be called with lock held
fn updateExpiryCount(state: *TimerFdState) void {
    if (!state.armed) return;

    const now_ns = getClockNanoseconds(state.clockid);

    if (now_ns >= state.next_expiry_ns) {
        if (state.interval_ns > 0) {
            // Periodic timer - calculate how many intervals elapsed
            const elapsed = now_ns - state.next_expiry_ns;
            const count: u64 = (elapsed / state.interval_ns) + 1;
            state.expiry_count += count;

            // Advance next_expiry_ns by count intervals
            state.next_expiry_ns += count * state.interval_ns;
        } else {
            // One-shot timer - disarm after single expiration
            state.expiry_count += 1;
            state.armed = false;
        }
    }
}

fn timerfdRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    if (buf.len < 8) return Errno.EINVAL.toReturn();

    const state: *TimerFdState = @ptrCast(@alignCast(fd.private_data));

    while (true) {
        const held = state.lock.acquire();

        // Update expiry count based on current time
        updateExpiryCount(state);

        // If count > 0, return it
        if (state.expiry_count > 0) {
            const count = state.expiry_count;
            state.expiry_count = 0;
            held.release();

            // Copy u64 to user buffer
            const count_bytes = std.mem.asBytes(&count);
            @memcpy(buf[0..8], count_bytes);

            return 8;
        }

        // Count is 0 - check if we should block
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            held.release();
            return Errno.EAGAIN.toReturn();
        }

        // Block using yield loop (similar to epoll_wait pattern)
        // Calculate time until next expiry
        if (!state.armed) {
            // Timer not armed - would block forever
            // For now, return EAGAIN (could also block indefinitely)
            held.release();
            return Errno.EAGAIN.toReturn();
        }

        held.release();

        // Yield to scheduler - timer tick will wake us
        sched.yield();

        // Retry - check expiry again
    }
}

fn timerfdPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    _ = requested_events;

    const state: *TimerFdState = @ptrCast(@alignCast(fd.private_data));

    const held = state.lock.acquire();
    defer held.release();

    // Update expiry count
    updateExpiryCount(state);

    var revents: u32 = 0;

    // EPOLLIN if expiry count > 0
    if (state.expiry_count > 0) {
        revents |= uapi.epoll.EPOLLIN;
    }

    return revents;
}

fn timerfdClose(fd: *fd_mod.FileDescriptor) isize {
    const state: *TimerFdState = @ptrCast(@alignCast(fd.private_data));
    heap.allocator().destroy(state);
    return 0;
}

/// File operations for timerfd
const timerfd_file_ops = fd_mod.FileOps{
    .read = timerfdRead,
    .write = null, // Timerfds are not writable
    .close = timerfdClose,
    .poll = timerfdPoll,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .truncate = null,
    .getdents = null,
    .chown = null,
};

/// sys_timerfd_create (283) - Create a timerfd
///
/// Args:
///   clockid: CLOCK_REALTIME (0), CLOCK_MONOTONIC (1), or CLOCK_BOOTTIME (7)
///   flags: TFD_CLOEXEC, TFD_NONBLOCK
///
/// Returns: New file descriptor, or -errno on error
pub fn sys_timerfd_create(clockid: usize, flags: usize) SyscallError!usize {
    const clockid_i32 = @as(i32, @bitCast(@as(u32, @truncate(clockid))));

    // Validate clockid
    const CLOCK_REALTIME: i32 = 0;
    const CLOCK_MONOTONIC: i32 = 1;
    const CLOCK_BOOTTIME: i32 = 7;

    const valid_clockid = switch (clockid_i32) {
        CLOCK_REALTIME, CLOCK_MONOTONIC => clockid_i32,
        CLOCK_BOOTTIME => CLOCK_MONOTONIC, // Map BOOTTIME to MONOTONIC
        else => return error.EINVAL,
    };

    // Validate flags
    const valid_flags = uapi.timerfd.TFD_CLOEXEC | uapi.timerfd.TFD_NONBLOCK;
    if ((flags & ~valid_flags) != 0) return error.EINVAL;

    // Allocate state
    const state = heap.allocator().create(TimerFdState) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(state);

    state.* = TimerFdState.init(valid_clockid);

    // Allocate file descriptor
    const fd = heap.allocator().create(fd_mod.FileDescriptor) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(fd);

    var fd_flags: u32 = fd_mod.O_RDONLY;
    if ((flags & uapi.timerfd.TFD_NONBLOCK) != 0) {
        fd_flags |= fd_mod.O_NONBLOCK;
    }

    fd.* = fd_mod.FileDescriptor{
        .ops = &timerfd_file_ops,
        .flags = fd_flags,
        .private_data = state,
        .position = 0,
        .refcount = .{ .raw = 1 },
        .lock = .{},
        .cloexec = (flags & uapi.timerfd.TFD_CLOEXEC) != 0,
    };

    // Install in FD table
    const table = base.getGlobalFdTable();
    const fd_num = table.allocAndInstall(fd) orelse {
        heap.allocator().destroy(fd);
        return error.EMFILE;
    };

    return fd_num;
}

/// sys_timerfd_settime (286) - Arm or disarm a timerfd
///
/// Args:
///   fd_num: File descriptor from timerfd_create
///   flags: TFD_TIMER_ABSTIME for absolute time, 0 for relative
///   new_value_ptr: Pointer to ITimerSpec with new settings
///   old_value_ptr: Pointer to ITimerSpec to receive old settings (or 0)
///
/// Returns: 0 on success, -errno on error
pub fn sys_timerfd_settime(fd_num: usize, flags: usize, new_value_ptr: usize, old_value_ptr: usize) SyscallError!usize {
    // Get FD from table
    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    // Verify this is a timerfd
    if (fd.ops.read != timerfdRead) return error.EINVAL;

    const state: *TimerFdState = @ptrCast(@alignCast(fd.private_data));

    // Read new_value from userspace
    const new_value = UserPtr.from(new_value_ptr).readValue(uapi.timerfd.ITimerSpec) catch {
        return error.EFAULT;
    };

    // Validate timespec values
    if (new_value.it_value.tv_sec < 0 or new_value.it_value.tv_nsec < 0 or new_value.it_value.tv_nsec >= 1_000_000_000) {
        return error.EINVAL;
    }
    if (new_value.it_interval.tv_sec < 0 or new_value.it_interval.tv_nsec < 0 or new_value.it_interval.tv_nsec >= 1_000_000_000) {
        return error.EINVAL;
    }

    // Validate flags
    const valid_flags = uapi.timerfd.TFD_TIMER_ABSTIME;
    if ((flags & ~valid_flags) != 0) return error.EINVAL;

    const held = state.lock.acquire();

    // Update expiry count first for accurate old_value
    updateExpiryCount(state);

    // Save old value if requested
    if (old_value_ptr != 0) {
        var old_value: uapi.timerfd.ITimerSpec = undefined;

        if (state.armed) {
            const now_ns = getClockNanoseconds(state.clockid);
            const remaining_ns = if (state.next_expiry_ns > now_ns)
                state.next_expiry_ns - now_ns
            else
                0;

            old_value.it_value = nanosecondsToTimespec(remaining_ns);
            old_value.it_interval = nanosecondsToTimespec(state.interval_ns);
        } else {
            // Disarmed - both zero
            old_value.it_value = .{ .tv_sec = 0, .tv_nsec = 0 };
            old_value.it_interval = .{ .tv_sec = 0, .tv_nsec = 0 };
        }

        held.release();

        UserPtr.from(old_value_ptr).writeValue(old_value) catch {
            return error.EFAULT;
        };

        // Re-acquire lock
        _ = state.lock.acquire();
    }

    // Process new value
    const it_value_ns = timespecToNanoseconds(new_value.it_value);

    if (it_value_ns == 0) {
        // Disarm timer
        state.armed = false;
        state.expiry_count = 0;
        state.next_expiry_ns = 0;
        state.interval_ns = 0;
    } else {
        // Arm timer
        const now_ns = getClockNanoseconds(state.clockid);

        if ((flags & uapi.timerfd.TFD_TIMER_ABSTIME) != 0) {
            // Absolute time
            state.next_expiry_ns = it_value_ns;
        } else {
            // Relative time - add to current time
            state.next_expiry_ns = now_ns + it_value_ns;
        }

        state.interval_ns = timespecToNanoseconds(new_value.it_interval);
        state.armed = true;
        state.expiry_count = 0;

        // Wake blocked readers (timer settings changed)
        if (state.blocked_readers) |t| {
            state.blocked_readers = null;
            state.reader_woken.store(true, .release);
            sched.unblock(t);
        }
    }

    held.release();

    return 0;
}

/// sys_timerfd_gettime (287) - Get current timer settings
///
/// Args:
///   fd_num: File descriptor from timerfd_create
///   curr_value_ptr: Pointer to ITimerSpec to receive current settings
///
/// Returns: 0 on success, -errno on error
pub fn sys_timerfd_gettime(fd_num: usize, curr_value_ptr: usize) SyscallError!usize {
    // Get FD from table
    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    // Verify this is a timerfd
    if (fd.ops.read != timerfdRead) return error.EINVAL;

    const state: *TimerFdState = @ptrCast(@alignCast(fd.private_data));

    const held = state.lock.acquire();

    // Update expiry count
    updateExpiryCount(state);

    var curr_value: uapi.timerfd.ITimerSpec = undefined;

    if (state.armed) {
        const now_ns = getClockNanoseconds(state.clockid);
        const remaining_ns = if (state.next_expiry_ns > now_ns)
            state.next_expiry_ns - now_ns
        else
            0;

        curr_value.it_value = nanosecondsToTimespec(remaining_ns);
        curr_value.it_interval = nanosecondsToTimespec(state.interval_ns);
    } else {
        // Disarmed - both zero
        curr_value.it_value = .{ .tv_sec = 0, .tv_nsec = 0 };
        curr_value.it_interval = .{ .tv_sec = 0, .tv_nsec = 0 };
    }

    held.release();

    UserPtr.from(curr_value_ptr).writeValue(curr_value) catch {
        return error.EFAULT;
    };

    return 0;
}
