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
//! - No TimerWheel dependency - simpler implementation, 1ms granularity

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
///
/// Lifecycle: ref_count starts at 1 (owned by the FD). Each active read/poll
/// operation holds an additional reference. Close sets the closed flag and drops
/// the FD's reference. The state is freed when the last reference is dropped.
const TimerFdState = struct {
    clockid: i32,
    lock: sync.Spinlock,
    closed: std.atomic.Value(bool),
    ref_count: std.atomic.Value(u32),
    armed: bool,
    next_expiry_ns: u64,
    interval_ns: u64,
    expiry_count: u64,
    wait_queue: sched.WaitQueue,

    fn init(clockid: i32) TimerFdState {
        return TimerFdState{
            .clockid = clockid,
            .lock = .{},
            .closed = std.atomic.Value(bool).init(false),
            .ref_count = std.atomic.Value(u32).init(1),
            .armed = false,
            .next_expiry_ns = 0,
            .interval_ns = 0,
            .expiry_count = 0,
            .wait_queue = .{},
        };
    }

    fn ref(self: *TimerFdState) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn unref(self: *TimerFdState) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            heap.allocator().destroy(self);
        }
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
            // Fallback to tick count (1ms resolution, 1 tick = 1ms)
            const ticks = sched.getTickCount();
            const ms = ticks; // 1 tick = 1ms
            return ms * 1_000_000; // ms to ns
        }
    }

    // Unknown clock - return 0
    return 0;
}

/// Convert timespec to nanoseconds, returning null on overflow
fn timespecToNanoseconds(ts: uapi.abi.Timespec) ?u64 {
    const secs = @as(u64, @intCast(@max(0, ts.tv_sec)));
    const sec_ns = std.math.mul(u64, secs, 1_000_000_000) catch return null;
    const nsec = @as(u64, @intCast(@max(0, ts.tv_nsec)));
    return std.math.add(u64, sec_ns, nsec) catch null;
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
            state.expiry_count = state.expiry_count +| count; // saturating add

            // Advance next_expiry_ns by count intervals (saturating)
            const advance = count *| state.interval_ns; // saturating mul
            state.next_expiry_ns = state.next_expiry_ns +| advance; // saturating add
        } else {
            // One-shot timer - disarm after single expiration
            state.expiry_count = state.expiry_count +| 1; // saturating add
            state.armed = false;
        }
    }
}

fn timerfdRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    if (buf.len < 8) return Errno.EINVAL.toReturn();

    const state: *TimerFdState = @ptrCast(@alignCast(fd.private_data));
    state.ref();
    defer state.unref();

    while (true) {
        if (state.closed.load(.acquire)) return Errno.EBADF.toReturn();

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

        // Block using WaitQueue with timeout until next expiry
        if (!state.armed) {
            // Timer not armed - would block forever, return EAGAIN
            held.release();
            return Errno.EAGAIN.toReturn();
        }

        // Calculate timeout in ticks (1 tick = ~1ms)
        const now_ns = getClockNanoseconds(state.clockid);
        const timeout_ns = if (state.next_expiry_ns > now_ns)
            state.next_expiry_ns - now_ns
        else
            1_000_000; // 1ms minimum if expiry is imminent

        // Convert ns to ticks, round up to ensure we wait at least the requested time
        const timeout_ticks = (timeout_ns + 999_999) / 1_000_000;

        // waitOnWithTimeout atomically releases the lock and blocks
        // No futex_bucket_ptr needed since this is not a futex operation
        sched.waitOnWithTimeout(&state.wait_queue, held, timeout_ticks, null);

        // After wakeup, loop will re-acquire lock and re-check expiry_count
    }
}

fn timerfdPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    _ = requested_events;

    const state: *TimerFdState = @ptrCast(@alignCast(fd.private_data));
    state.ref();
    defer state.unref();

    if (state.closed.load(.acquire)) return 0;

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

    // Mark as closed and wake all blocked readers so they can exit with EBADF
    const held = state.lock.acquire();
    state.closed.store(true, .release);

    // Wake all blocked readers (WaitQueue.wakeUp handles empty queue)
    _ = state.wait_queue.wakeUp(std.math.maxInt(usize));

    held.release();

    // Drop the FD's reference. Last active operation to unref frees the state.
    state.unref();
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
        // errdefer handles cleanup of fd and state
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
    // Hold a reference to prevent use-after-free if a concurrent close()
    // drops the FD's reference between table.get() and lock.acquire().
    state.ref();
    defer state.unref();

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

    // Validate new timespec values can be converted before taking the lock
    const it_value_ns = timespecToNanoseconds(new_value.it_value) orelse {
        return error.EINVAL;
    };
    const it_interval_ns = timespecToNanoseconds(new_value.it_interval) orelse {
        return error.EINVAL;
    };

    // Hold the lock for the entire read-modify cycle (no release/re-acquire gap).
    // Compute old_value under the lock, modify timer state, then release.
    // Write old_value to userspace AFTER releasing the lock to avoid holding
    // a spinlock during a potentially-faulting user memory access.
    const held = state.lock.acquire();

    // Check if closed between table.get() and lock acquisition
    if (state.closed.load(.acquire)) {
        held.release();
        return error.EBADF;
    }

    // Update expiry count first for accurate old_value
    updateExpiryCount(state);

    // Capture old value under lock if requested
    var old_value_local: ?uapi.timerfd.ITimerSpec = null;
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
            old_value.it_value = .{ .tv_sec = 0, .tv_nsec = 0 };
            old_value.it_interval = .{ .tv_sec = 0, .tv_nsec = 0 };
        }

        old_value_local = old_value;
    }

    // Modify timer state (still under lock)
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
            state.next_expiry_ns = it_value_ns;
        } else {
            // Checked add to prevent overflow
            state.next_expiry_ns = std.math.add(u64, now_ns, it_value_ns) catch {
                held.release();
                return error.EINVAL;
            };
        }

        state.interval_ns = it_interval_ns;
        state.armed = true;
        state.expiry_count = 0;

        // Wake blocked readers (timer settings changed, should re-check)
        _ = state.wait_queue.wakeUp(1);
    }

    held.release();

    // Write old_value to userspace AFTER releasing the lock
    if (old_value_local) |ov| {
        UserPtr.from(old_value_ptr).writeValue(ov) catch {
            return error.EFAULT;
        };
    }

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
    // Hold a reference to prevent use-after-free if a concurrent close()
    // drops the FD's reference between table.get() and lock.acquire().
    state.ref();
    defer state.unref();

    const held = state.lock.acquire();

    // Check if closed between table.get() and lock acquisition
    if (state.closed.load(.acquire)) {
        held.release();
        return error.EBADF;
    }

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
