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
const heap = @import("heap");
const fd_mod = @import("fd");
const sync = @import("sync");
const futex = @import("futex");
const user_mem = @import("user_mem");
const process_mod = @import("process");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;

/// Timespec structure (Linux compatible)
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

// Clock IDs (Linux compatible)
const CLOCK_REALTIME: usize = 0;
const CLOCK_MONOTONIC: usize = 1;
const CLOCK_PROCESS_CPUTIME_ID: usize = 2;
const CLOCK_THREAD_CPUTIME_ID: usize = 3;
const CLOCK_MONOTONIC_RAW: usize = 4;
const CLOCK_REALTIME_COARSE: usize = 5;
const CLOCK_MONOTONIC_COARSE: usize = 6;
const CLOCK_BOOTTIME: usize = 7;

// =============================================================================
// Scheduling
// =============================================================================

/// sys_sched_yield (24) - Yield processor to other threads
pub fn sys_sched_yield() SyscallError!usize {
    sched.yield();
    return 0;
}

/// sys_pause (34) - Wait for signal
///
/// Blocks the calling thread until a signal is received and handled.
/// Always returns -EINTR when interrupted by a signal.
///
/// SECURITY: Uses existing signal infrastructure (checkSignalsOnSyscallExit)
/// to deliver pending signals. The Thread.pending_wakeup atomic flag prevents
/// lost wakeups if signal arrives before block() is called.
pub fn sys_pause() SyscallError!usize {
    sched.block();
    // When woken by a signal, the signal handler runs first, then
    // checkSignalsOnSyscallExit() sets the return value to -EINTR.
    return error.EINTR;
}

// =============================================================================
// Scheduling Policy Queries/Sets
// =============================================================================

// POSIX scheduling policies
const SCHED_OTHER: usize = 0;
const SCHED_FIFO: usize = 1;
const SCHED_RR: usize = 2;
const SCHED_BATCH: usize = 3;
const SCHED_IDLE: usize = 5;

const SchedParam = extern struct {
    sched_priority: i32,
};

/// sys_sched_get_priority_max (146) - Get maximum priority for a policy
pub fn sys_sched_get_priority_max(policy: usize) SyscallError!usize {
    return switch (policy) {
        SCHED_FIFO, SCHED_RR => 99,
        SCHED_OTHER, SCHED_BATCH, SCHED_IDLE => 0,
        else => error.EINVAL,
    };
}

/// sys_sched_get_priority_min (147) - Get minimum priority for a policy
pub fn sys_sched_get_priority_min(policy: usize) SyscallError!usize {
    return switch (policy) {
        SCHED_FIFO, SCHED_RR => 1,
        SCHED_OTHER, SCHED_BATCH, SCHED_IDLE => 0,
        else => error.EINVAL,
    };
}

/// sys_sched_getscheduler (145) - Get scheduling policy
pub fn sys_sched_getscheduler(pid: usize) SyscallError!usize {
    const target_pid: u32 = @truncate(pid);

    const proc = if (target_pid == 0)
        base.getCurrentProcess()
    else
        process_mod.findProcessByPid(target_pid) orelse return error.ESRCH;

    return proc.sched_policy;
}

/// sys_sched_getparam (143) - Get scheduling parameters
pub fn sys_sched_getparam(pid: usize, param_ptr: usize) SyscallError!usize {
    if (param_ptr == 0) return error.EFAULT;

    const target_pid: u32 = @truncate(pid);

    const proc = if (target_pid == 0)
        base.getCurrentProcess()
    else
        process_mod.findProcessByPid(target_pid) orelse return error.ESRCH;

    const param = SchedParam{
        .sched_priority = proc.sched_priority,
    };

    UserPtr.from(param_ptr).writeValue(param) catch {
        return error.EFAULT;
    };

    return 0;
}

/// sys_sched_setscheduler (144) - Set scheduling policy and parameters
pub fn sys_sched_setscheduler(pid: usize, policy: usize, param_ptr: usize) SyscallError!usize {
    if (param_ptr == 0) return error.EFAULT;

    const target_pid: u32 = @truncate(pid);

    const proc = if (target_pid == 0)
        base.getCurrentProcess()
    else
        process_mod.findProcessByPid(target_pid) orelse return error.ESRCH;

    // Validate policy
    switch (policy) {
        SCHED_OTHER, SCHED_FIFO, SCHED_RR, SCHED_BATCH, SCHED_IDLE => {},
        else => return error.EINVAL,
    }

    // Read parameters from userspace
    const param = UserPtr.from(param_ptr).readValue(SchedParam) catch {
        return error.EFAULT;
    };

    // Validate priority range for the policy
    switch (policy) {
        SCHED_FIFO, SCHED_RR => {
            if (param.sched_priority < 1 or param.sched_priority > 99) {
                return error.EINVAL;
            }
        },
        SCHED_OTHER, SCHED_BATCH, SCHED_IDLE => {
            if (param.sched_priority != 0) {
                return error.EINVAL;
            }
        },
        else => unreachable,
    }

    // Store policy and priority
    proc.sched_policy = @truncate(policy);
    proc.sched_priority = param.sched_priority;

    return 0;
}

/// sys_sched_setparam (142) - Set scheduling parameters
pub fn sys_sched_setparam(pid: usize, param_ptr: usize) SyscallError!usize {
    if (param_ptr == 0) return error.EFAULT;

    const target_pid: u32 = @truncate(pid);

    const proc = if (target_pid == 0)
        base.getCurrentProcess()
    else
        process_mod.findProcessByPid(target_pid) orelse return error.ESRCH;

    // Read parameters from userspace
    const param = UserPtr.from(param_ptr).readValue(SchedParam) catch {
        return error.EFAULT;
    };

    // Validate priority range based on current policy
    switch (proc.sched_policy) {
        SCHED_FIFO, SCHED_RR => {
            if (param.sched_priority < 1 or param.sched_priority > 99) {
                return error.EINVAL;
            }
        },
        SCHED_OTHER, SCHED_BATCH, SCHED_IDLE => {
            if (param.sched_priority != 0) {
                return error.EINVAL;
            }
        },
        else => {},
    }

    // Store priority
    proc.sched_priority = param.sched_priority;

    return 0;
}

/// sys_sched_rr_get_interval (148) - Get the SCHED_RR time quantum
pub fn sys_sched_rr_get_interval(pid: usize, interval_ptr: usize) SyscallError!usize {
    if (interval_ptr == 0) return error.EFAULT;

    const target_pid: u32 = @truncate(pid);

    // Verify process exists
    const proc = if (target_pid == 0)
        base.getCurrentProcess()
    else
        process_mod.findProcessByPid(target_pid) orelse return error.ESRCH;

    _ = proc; // Process exists, not used otherwise

    // Return 100ms RR quantum (Linux default)
    const interval = Timespec{
        .tv_sec = 0,
        .tv_nsec = 100_000_000,
    };

    UserPtr.from(interval_ptr).writeValue(interval) catch {
        return error.EFAULT;
    };

    return 0;
}

/// sys_ppoll (271) - Poll file descriptors with signal mask and timespec timeout
///
/// Args:
///   fds_ptr: Pointer to array of pollfd structures
///   nfds: Number of file descriptors
///   timeout_ptr: Pointer to timespec timeout (NULL = infinite wait)
///   sigmask_ptr: Pointer to signal mask
///   sigsetsize: Size of signal mask (must be 8 for u64 SigSet)
pub fn sys_ppoll(fds_ptr: usize, nfds: usize, timeout_ptr: usize, sigmask_ptr: usize, sigsetsize: usize) SyscallError!usize {
    const thread = sched.getCurrentThread() orelse return error.ESRCH;

    // Validate sigmask size if provided
    if (sigmask_ptr != 0 and sigsetsize != 8) {
        return error.EINVAL;
    }

    // Apply signal mask if provided
    var old_mask: u64 = 0;
    var mask_applied = false;
    if (sigmask_ptr != 0) {
        const new_mask = UserPtr.from(sigmask_ptr).readValue(u64) catch {
            return error.EFAULT;
        };
        old_mask = thread.sigmask;
        thread.sigmask = new_mask;
        mask_applied = true;
    }
    defer if (mask_applied) {
        thread.sigmask = old_mask;
    };

    // Parse timeout
    var timeout_us: ?u64 = null;
    if (timeout_ptr != 0) {
        const ts = UserPtr.from(timeout_ptr).readValue(Timespec) catch {
            return error.EFAULT;
        };

        // Validate timespec values
        if (ts.tv_sec < 0 or ts.tv_nsec < 0 or ts.tv_nsec >= 1_000_000_000) {
            return error.EINVAL;
        }

        // Convert to microseconds
        const sec_us: u64 = @as(u64, @intCast(ts.tv_sec)) * 1_000_000;
        const nsec_us: u64 = @as(u64, @intCast(ts.tv_nsec)) / 1_000;
        timeout_us = sec_us + nsec_us;
    }

    // Handle nfds=0 case (pure timeout)
    if (nfds == 0) {
        if (timeout_us) |us| {
            if (us == 0) {
                // Zero timeout - return immediately
                return 0;
            }
            // Sleep for timeout duration
            const ticks = us / 1_000; // 1ms per tick, us to ticks
            if (ticks > 0) {
                sched.sleepForTicks(ticks);
            }
        } else {
            // NULL timeout (infinite wait) - block forever
            sched.block();
        }
        return 0;
    }

    // Validate fds_ptr
    const poll_size = @sizeOf(uapi.poll.PollFd);
    const array_size = std.math.mul(usize, nfds, poll_size) catch return error.EINVAL;
    if (!user_mem.isValidUserAccess(fds_ptr, array_size, .Read) or
        !user_mem.isValidUserAccess(fds_ptr, array_size, .Write))
    {
        return error.EFAULT;
    }

    // Copy pollfd array to kernel memory
    const kpollfds = heap.allocator().alloc(uapi.poll.PollFd, nfds) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kpollfds);

    const ufds_uptr = user_mem.UserPtr.from(fds_ptr);
    _ = ufds_uptr.copyToKernel(std.mem.sliceAsBytes(kpollfds)) catch {
        return error.EFAULT;
    };

    const fd_table = base.getGlobalFdTable();
    const start_tsc = hal.timing.rdtsc();

    // Poll loop
    while (true) {
        var ready_count: usize = 0;

        // Check each pollfd
        for (kpollfds) |*pfd| {
            pfd.revents = 0;

            if (pfd.fd < 0) continue;

            const fd_u32 = std.math.cast(u32, @as(usize, @intCast(pfd.fd))) orelse {
                pfd.revents = @bitCast(uapi.poll.POLLNVAL);
                ready_count += 1;
                continue;
            };

            if (fd_table.get(fd_u32)) |fd_obj| {
                // Call poll if available
                var revents: u32 = 0;
                if (fd_obj.ops.poll) |poll_fn| {
                    const events_u32: u32 = @as(u16, @bitCast(pfd.events));
                    revents = poll_fn(fd_obj, events_u32);
                } else {
                    // No poll - assume always ready for the modes the FD supports
                    const events: u16 = @bitCast(pfd.events);
                    if ((events & uapi.poll.POLLIN) != 0 and fd_obj.isReadable()) {
                        revents |= uapi.poll.POLLIN;
                    }
                    if ((events & uapi.poll.POLLOUT) != 0 and fd_obj.isWritable()) {
                        revents |= uapi.poll.POLLOUT;
                    }
                }
                const revents_i16: i16 = @bitCast(@as(u16, @truncate(revents)));
                pfd.revents = revents_i16;
            } else {
                // FD no longer valid
                pfd.revents = @bitCast(uapi.poll.POLLNVAL);
            }

            if (pfd.revents != 0) {
                ready_count += 1;
            }
        }

        // If any FDs ready, return
        if (ready_count > 0) break;

        // Check timeout
        if (timeout_us) |us| {
            if (us == 0) break; // Immediate return (timeout=0)
            if (hal.timing.hasTimedOut(start_tsc, us)) break; // Timeout expired
        }
        // else: null timeout means infinite wait, keep looping

        // No FDs ready and not timed out - yield and retry
        sched.yield();
    }

    // Copy results back to userspace
    _ = ufds_uptr.copyFromKernel(std.mem.sliceAsBytes(kpollfds)) catch {
        return error.EFAULT;
    };

    // Count ready fds
    var final_count: usize = 0;
    for (kpollfds) |pfd| {
        if (pfd.revents != 0) {
            final_count += 1;
        }
    }

    return final_count;
}

/// sys_nanosleep (35) - High-resolution sleep
///
/// Args:
///   req_ptr: Pointer to timespec with requested sleep duration
///   rem_ptr: Pointer to timespec for remaining time (if interrupted)
///
/// MVP: Busy-waits for the duration. Full implementation would
/// block the thread and use a timer to wake it.
/// Internal implementation for clock_nanosleep, shared by sys_nanosleep and sys_clock_nanosleep.
///
/// Per user decision: supports CLOCK_REALTIME and CLOCK_MONOTONIC only.
/// Per user decision: TIMER_ABSTIME uses absolute deadline comparison, not delta computation.
/// Per user decision: on EINTR, writes remaining time to rmtp for relative sleeps.
fn clock_nanosleep_internal(clockid: usize, flags: usize, req_ptr: usize, rem_ptr: usize) SyscallError!usize {
    // Validate clock id
    switch (clockid) {
        CLOCK_REALTIME, CLOCK_MONOTONIC => {},
        else => return error.EINVAL,
    }

    const TIMER_ABSTIME: u32 = 1;
    const is_abstime = (flags & TIMER_ABSTIME) != 0;

    // Read timespec from userspace
    const req = UserPtr.from(req_ptr).readValue(Timespec) catch return error.EFAULT;

    // Validate timespec values
    if (req.tv_sec < 0 or req.tv_nsec < 0 or req.tv_nsec >= 1_000_000_000) {
        return error.EINVAL;
    }

    const req_sec_u: u64 = @intCast(req.tv_sec);
    const req_nsec_u: u64 = @intCast(req.tv_nsec);
    const req_total_ns = std.math.add(u64, std.math.mul(u64, req_sec_u, 1_000_000_000) catch return error.EINVAL, req_nsec_u) catch return error.EINVAL;

    if (is_abstime) {
        // Absolute time: sleep until the specified time is reached
        // Get current time for the specified clock
        const now_ns = getCurrentTimeNs(clockid);

        if (req_total_ns <= now_ns) {
            // Already past the deadline
            return 0;
        }

        const delta_ns = req_total_ns - now_ns;
        const tick_ns: u64 = 1_000_000;
        const duration_ticks = std.math.divCeil(u64, delta_ns, tick_ns) catch 1;

        sched.sleepForTicks(duration_ticks);

        // TIMER_ABSTIME: no remaining time writeback per POSIX
        return 0;
    } else {
        // Relative sleep
        if (req_total_ns == 0) {
            if (rem_ptr != 0) {
                const rem: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
                UserPtr.from(rem_ptr).writeValue(rem) catch return error.EFAULT;
            }
            return 0;
        }

        const tick_ns: u64 = 1_000_000;
        const duration_ticks = std.math.divCeil(u64, req_total_ns, tick_ns) catch unreachable;

        sched.sleepForTicks(duration_ticks);

        // On success, set remaining time to 0
        if (rem_ptr != 0) {
            const rem: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
            UserPtr.from(rem_ptr).writeValue(rem) catch return error.EFAULT;
        }
        return 0;
    }
}

/// Get current time in nanoseconds for a given clock
fn getCurrentTimeNs(clockid: usize) u64 {
    _ = clockid; // Both CLOCK_REALTIME and CLOCK_MONOTONIC use the same source in zk
    // (no RTC or wall clock adjustment -- monotonic counter only)
    const ticks = sched.getTickCount();
    return ticks * 1_000_000; // 1ms per tick
}

/// sys_clock_nanosleep (230) - High-resolution sleep with clock selection
///
/// Per user decision: CLOCK_REALTIME and CLOCK_MONOTONIC only.
/// Per user decision: TIMER_ABSTIME uses absolute deadline comparison.
/// Per user decision: On EINTR for relative sleeps, remaining time written to rmtp.
///
/// Args:
///   clockid: Clock source (CLOCK_REALTIME=0 or CLOCK_MONOTONIC=1)
///   flags: Flags (TIMER_ABSTIME=1 for absolute time)
///   req_ptr: Pointer to timespec with requested time
///   rem_ptr: Pointer to timespec for remaining time (relative mode only)
///
/// Returns: 0 on success
pub fn sys_clock_nanosleep(clockid: usize, flags: usize, req_ptr: usize, rem_ptr: usize) SyscallError!usize {
    if (req_ptr == 0) return error.EFAULT;
    return clock_nanosleep_internal(clockid, flags, req_ptr, rem_ptr);
}

pub fn sys_nanosleep(req_ptr: usize, rem_ptr: usize) SyscallError!usize {
    // Per user decision: nanosleep is a thin wrapper around clock_nanosleep(CLOCK_MONOTONIC, 0, ...)
    return clock_nanosleep_internal(CLOCK_MONOTONIC, 0, req_ptr, rem_ptr);
}

/// Internal select implementation shared by sys_select and sys_pselect6
fn selectInternal(nfds: usize, readfds: usize, writefds: usize, exceptfds: usize, timeout_us: ?u64) SyscallError!usize {
    // fd_set is 128 bytes (1024 bits) on Linux x86_64
    const FD_SET_SIZE = 128;
    const FD_SET_BITS = FD_SET_SIZE * 8;

    // Cap nfds to max supported
    const max_fd = @min(nfds, fd_mod.MAX_FDS);
    if (max_fd > FD_SET_BITS) return error.EINVAL;

    // Get current FD table
    const fd_table = base.getGlobalFdTable();

    // Local buffers for fd_sets
    var read_set: [FD_SET_SIZE]u8 = [_]u8{0} ** FD_SET_SIZE;
    var write_set: [FD_SET_SIZE]u8 = [_]u8{0} ** FD_SET_SIZE;
    var except_set: [FD_SET_SIZE]u8 = [_]u8{0} ** FD_SET_SIZE;

    // Copy sets from userspace
    // SECURITY: copyFromUser returns bytes NOT copied (0 on success)
    if (readfds != 0) {
        if (user_mem.copyFromUser(&read_set, readfds) != 0) {
            return error.EFAULT;
        }
    }
    if (writefds != 0) {
        if (user_mem.copyFromUser(&write_set, writefds) != 0) {
            return error.EFAULT;
        }
    }
    if (exceptfds != 0) {
        if (user_mem.copyFromUser(&except_set, exceptfds) != 0) {
            return error.EFAULT;
        }
    }

    // Output sets (what's ready)
    var read_out: [FD_SET_SIZE]u8 = [_]u8{0} ** FD_SET_SIZE;
    var write_out: [FD_SET_SIZE]u8 = [_]u8{0} ** FD_SET_SIZE;
    var except_out: [FD_SET_SIZE]u8 = [_]u8{0} ** FD_SET_SIZE;

    var ready_count: usize = 0;
    const start_tsc = hal.timing.rdtsc();

    // Poll loop - check FDs until ready or timeout
    while (true) {
        ready_count = 0;
        @memset(&read_out, 0);
        @memset(&write_out, 0);
        @memset(&except_out, 0);

        // Check each FD in range
        var fd_num: usize = 0;
        while (fd_num < max_fd) : (fd_num += 1) {
            const byte_idx = fd_num / 8;
            const bit_idx: u3 = @truncate(fd_num % 8);
            const mask: u8 = @as(u8, 1) << bit_idx;

            const want_read = (read_set[byte_idx] & mask) != 0;
            const want_write = (write_set[byte_idx] & mask) != 0;
            const want_except = (except_set[byte_idx] & mask) != 0;

            if (!want_read and !want_write and !want_except) continue;

            // Get the FD
            const fd_ptr = fd_table.get(@truncate(fd_num)) orelse continue;

            // Build poll request
            var poll_events: u32 = 0;
            if (want_read) poll_events |= uapi.epoll.EPOLLIN;
            if (want_write) poll_events |= uapi.epoll.EPOLLOUT;
            if (want_except) poll_events |= uapi.epoll.EPOLLERR | uapi.epoll.EPOLLPRI;

            // Call poll if available
            // SECURITY: Mask out epoll high bits (EPOLLET, EPOLLONESHOT, etc.)
            // that cannot be represented in select semantics. These bits could
            // cause unexpected behavior if poll implementations return them.
            const EPOLL_EVENT_MASK: u32 = 0x0000FFFF;
            var revents: u32 = 0;
            if (fd_ptr.ops.poll) |poll_fn| {
                revents = poll_fn(fd_ptr, poll_events) & EPOLL_EVENT_MASK;
            } else {
                // No poll - assume always ready for the modes the FD supports
                if (want_read and fd_ptr.isReadable()) revents |= uapi.epoll.EPOLLIN;
                if (want_write and fd_ptr.isWritable()) revents |= uapi.epoll.EPOLLOUT;
            }

            // Set output bits
            if ((revents & uapi.epoll.EPOLLIN) != 0 and want_read) {
                read_out[byte_idx] |= mask;
                ready_count += 1;
            }
            if ((revents & uapi.epoll.EPOLLOUT) != 0 and want_write) {
                write_out[byte_idx] |= mask;
                ready_count += 1;
            }
            if ((revents & (uapi.epoll.EPOLLERR | uapi.epoll.EPOLLPRI)) != 0 and want_except) {
                except_out[byte_idx] |= mask;
                ready_count += 1;
            }
        }

        // If any FDs ready, return
        if (ready_count > 0) break;

        // Check timeout
        if (timeout_us) |us| {
            if (us == 0) break; // Immediate return (timeout=0)
            if (hal.timing.hasTimedOut(start_tsc, us)) break; // Timeout expired
        }
        // else: null timeout means infinite wait, keep looping

        // No FDs ready and not timed out - yield and retry
        sched.yield();
    }

    // Copy output sets back to userspace
    // SECURITY: Check copyToUser return values. If user unmapped the memory
    // after initial validation (TOCTOU), the copy fails silently and we must
    // return EFAULT rather than a stale ready_count that doesn't match reality.
    if (readfds != 0) {
        if (user_mem.copyToUser(readfds, &read_out) != 0) {
            return error.EFAULT;
        }
    }
    if (writefds != 0) {
        if (user_mem.copyToUser(writefds, &write_out) != 0) {
            return error.EFAULT;
        }
    }
    if (exceptfds != 0) {
        if (user_mem.copyToUser(exceptfds, &except_out) != 0) {
            return error.EFAULT;
        }
    }

    return ready_count;
}

/// sys_select (23) - Synchronous I/O multiplexing
///
/// Args:
///   nfds: Highest-numbered file descriptor + 1
///   readfds: FD set to watch for read readiness
///   writefds: FD set to watch for write readiness
///   exceptfds: FD set to watch for exceptions
///   timeout: Pointer to struct timeval with maximum wait time
///
/// Implements basic non-blocking poll of FD sets.
/// Blocking with timeout is supported via scheduler.
pub fn sys_select(nfds: usize, readfds: usize, writefds: usize, exceptfds: usize, timeout: usize) SyscallError!usize {
    // Parse timeout (struct timeval)
    var timeout_us: ?u64 = null;
    if (timeout != 0) {
        var tv: extern struct { tv_sec: i64, tv_usec: i64 } = undefined;
        const tv_bytes = std.mem.asBytes(&tv);
        // SECURITY: copyFromUser returns bytes NOT copied (0 on success)
        if (user_mem.copyFromUser(tv_bytes, timeout) != 0) {
            return error.EFAULT;
        }
        // Convert to microseconds
        const sec_us = @as(u64, @intCast(@max(0, tv.tv_sec))) * 1_000_000;
        const usec = @as(u64, @intCast(@max(0, tv.tv_usec)));
        timeout_us = sec_us + usec;
    }
    return selectInternal(nfds, readfds, writefds, exceptfds, timeout_us);
}

/// sys_pselect6 (270) - Synchronous I/O multiplexing with signal mask
///
/// Args:
///   nfds: Highest-numbered file descriptor + 1
///   readfds: FD set to watch for read readiness
///   writefds: FD set to watch for write readiness
///   exceptfds: FD set to watch for exceptions
///   timeout_ptr: Pointer to struct timespec with maximum wait time
///   sigmask_ptr: Pointer to sigmask_arg struct { sigset_t *ss; size_t ss_len; }
///
/// Like select, but with nanosecond-resolution timeout and atomic signal mask swap.
pub fn sys_pselect6(nfds: usize, readfds: usize, writefds: usize, exceptfds: usize, timeout_ptr: usize, sigmask_ptr: usize) SyscallError!usize {
    const thread = sched.getCurrentThread() orelse return error.ESRCH;

    // Apply signal mask if provided
    var old_mask: u64 = 0;
    var mask_applied = false;
    if (sigmask_ptr != 0) {
        // Read the pselect6 sigmask argument struct
        const SigmaskArg = extern struct {
            ss: usize,
            ss_len: usize,
        };
        const arg = UserPtr.from(sigmask_ptr).readValue(SigmaskArg) catch {
            return error.EFAULT;
        };

        // Validate ss_len == 8 (size of u64 sigset)
        if (arg.ss_len != 8) {
            return error.EINVAL;
        }

        // Read the signal mask
        if (arg.ss != 0) {
            const new_mask = UserPtr.from(arg.ss).readValue(u64) catch {
                return error.EFAULT;
            };
            old_mask = thread.sigmask;
            thread.sigmask = new_mask;
            mask_applied = true;
        }
    }
    defer if (mask_applied) {
        thread.sigmask = old_mask;
    };

    // Parse timeout (struct timespec)
    var timeout_us: ?u64 = null;
    if (timeout_ptr != 0) {
        const ts = UserPtr.from(timeout_ptr).readValue(Timespec) catch {
            return error.EFAULT;
        };

        // Validate timespec values
        if (ts.tv_sec < 0 or ts.tv_nsec < 0 or ts.tv_nsec >= 1_000_000_000) {
            return error.EINVAL;
        }

        // Convert to microseconds
        const sec_us = @as(u64, @intCast(ts.tv_sec)) * 1_000_000;
        const nsec_us = @as(u64, @intCast(ts.tv_nsec)) / 1_000;
        timeout_us = sec_us + nsec_us;
    }

    return selectInternal(nfds, readfds, writefds, exceptfds, timeout_us);
}

/// Get monotonic time (time since boot) using TSC or tick count
fn getMonotonicTime() Timespec {
    const freq = hal.timing.getTscFrequency();
    if (freq > 0) {
        const tsc = hal.timing.rdtsc();
        const tsc_u128 = @as(u128, tsc);
        const ns_u128 = (tsc_u128 * 1_000_000_000) / freq;
        const total_ns: u64 = @truncate(ns_u128);
        const max_sec: u64 = @intCast(std.math.maxInt(i64));
        const sec_val = total_ns / 1_000_000_000;
        return .{
            .tv_sec = if (sec_val > max_sec) std.math.maxInt(i64) else @intCast(sec_val),
            .tv_nsec = @intCast(total_ns % 1_000_000_000),
        };
    } else {
        // Fallback to tick count (1ms resolution, 1 tick = 1ms)
        const ticks = sched.getTickCount();
        const ms = ticks; // 1 tick = 1ms
        const max_sec_ms: u64 = @intCast(std.math.maxInt(i64));
        const sec_ms = ms / 1000;
        return .{
            .tv_sec = if (sec_ms > max_sec_ms) std.math.maxInt(i64) else @intCast(sec_ms),
            .tv_nsec = @intCast((ms % 1000) * 1_000_000),
        };
    }
}

/// sys_clock_gettime (228) - Get time from a clock
///
/// CLOCK_REALTIME: Wall-clock time from RTC
/// CLOCK_MONOTONIC: Time since boot (TSC or tick-based)
pub fn sys_clock_gettime(clk_id: usize, tp_ptr: usize) SyscallError!usize {
    if (tp_ptr == 0) {
        return error.EFAULT;
    }

    var tp: Timespec = undefined;

    switch (clk_id) {
        CLOCK_REALTIME, CLOCK_REALTIME_COARSE => {
            // Wall-clock time from RTC
            if (hal.rtc.isInitialized()) {
                const timestamp = hal.rtc.getUnixTimestamp();
                tp = .{
                    .tv_sec = timestamp,
                    .tv_nsec = 0, // RTC has second granularity
                };
            } else {
                // Fallback to monotonic time if RTC not initialized
                tp = getMonotonicTime();
            }
        },
        CLOCK_MONOTONIC, CLOCK_MONOTONIC_RAW, CLOCK_MONOTONIC_COARSE, CLOCK_BOOTTIME => {
            // Monotonic time since boot
            tp = getMonotonicTime();
        },
        else => return error.EINVAL,
    }

    UserPtr.from(tp_ptr).writeValue(tp) catch {
        return error.EFAULT;
    };

    return 0;
}

/// sys_clock_getres (229) - Get clock resolution
///
/// MVP: Returns 1ms resolution (tick-based timing)
pub fn sys_clock_getres(clk_id: usize, res_ptr: usize) SyscallError!usize {
    _ = clk_id;

    if (res_ptr == 0) {
        return 0; // NULL res is valid per POSIX
    }

    // Report 1ms resolution (our tick interval)
    const res = Timespec{
        .tv_sec = 0,
        .tv_nsec = 1_000_000, // 1ms in nanoseconds
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
/// Returns wall-clock time from RTC, or fallback to monotonic time.
pub fn sys_gettimeofday(tv_ptr: usize, tz_ptr: usize) SyscallError!usize {
    _ = tz_ptr; // Timezone not supported

    if (tv_ptr == 0) {
        return 0; // NULL tv is valid
    }

    var tv: Timeval = undefined;

    // Use RTC for wall-clock time if initialized
    if (hal.rtc.isInitialized()) {
        const timestamp = hal.rtc.getUnixTimestamp();
        tv = .{
            .tv_sec = timestamp,
            .tv_usec = 0, // RTC has second granularity
        };
    } else {
        // Fallback to TSC-based timing
        const freq = hal.timing.getTscFrequency();
        if (freq > 0) {
            const tsc = hal.timing.rdtsc();
            const tsc_u128 = @as(u128, tsc);
            const us_u128 = (tsc_u128 * 1_000_000) / freq;
            const total_us: u64 = @truncate(us_u128);
            const max_sec_tv: u64 = @intCast(std.math.maxInt(i64));
            const sec_us = total_us / 1_000_000;
            tv = .{
                .tv_sec = if (sec_us > max_sec_tv) std.math.maxInt(i64) else @intCast(sec_us),
                .tv_usec = @intCast(total_us % 1_000_000),
            };
        } else {
            // Fallback to tick count (1 tick = 1ms)
            const ticks = sched.getTickCount();
            const ms = ticks; // 1 tick = 1ms
            const max_sec_tv2: u64 = @intCast(std.math.maxInt(i64));
            const sec_ms2 = ms / 1000;
            tv = .{
                .tv_sec = if (sec_ms2 > max_sec_tv2) std.math.maxInt(i64) else @intCast(sec_ms2),
                .tv_usec = @intCast((ms % 1000) * 1000),
            };
        }
    }

    UserPtr.from(tv_ptr).writeValue(tv) catch {
        return error.EFAULT;
    };

    return 0;
}

/// sys_settimeofday (164) - Set time of day
///
/// SECURITY: Requires root (euid == 0) per POSIX.
/// Writing system time is a privileged operation.
pub fn sys_settimeofday(tv_ptr: usize, tz_ptr: usize) SyscallError!usize {
    _ = tz_ptr; // Timezone not supported

    // SECURITY: Check root permission (POSIX-style)
    const proc = base.getCurrentProcess();
    if (proc.euid != 0) return error.EPERM;

    if (tv_ptr == 0) return error.EINVAL;

    // Read timeval from userspace
    const tv = UserPtr.from(tv_ptr).readValue(Timeval) catch {
        return error.EFAULT;
    };

    // Validate values
    if (tv.tv_sec < 0 or tv.tv_usec < 0 or tv.tv_usec >= 1_000_000) {
        return error.EINVAL;
    }

    // Convert to DateTime and write to RTC
    const timestamp = tv.tv_sec;
    const dt = hal.rtc.DateTime.fromUnixTimestamp(timestamp);
    hal.rtc.writeDateTime(&dt);

    return 0;
}

// =============================================================================
// Threading Primitives (Stubs)
// =============================================================================

/// sys_futex (202) - Fast userspace locking
///
/// Implemented Operations:
/// - FUTEX_WAIT: Wait atomically on a value
/// - FUTEX_WAKE: Wake up waiting threads
///
/// Stubbed Operations:
/// - FUTEX_REQUEUE, FUTEX_LOCK_PI, etc.
pub fn sys_futex(uaddr: usize, op: usize, val: usize, timeout_ptr: usize, uaddr2: usize, val3: usize) SyscallError!usize {
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
            // Parse timeout if provided (pointer to struct timespec)
            // Linux: relative timeout unless FUTEX_CLOCK_REALTIME is set
            var timeout_ns: ?u64 = null;
            if (timeout_ptr != 0) {
                const ts = UserPtr.from(timeout_ptr).readValue(Timespec) catch {
                    return error.EFAULT;
                };
                // Validate timespec values
                if (ts.tv_sec < 0 or ts.tv_nsec < 0 or ts.tv_nsec >= 1_000_000_000) {
                    return error.EINVAL;
                }
                // Convert to nanoseconds (saturating to prevent overflow)
                const sec_ns: u64 = @as(u64, @intCast(ts.tv_sec)) *| 1_000_000_000;
                timeout_ns = sec_ns +| @as(u64, @intCast(ts.tv_nsec));
            }

            const val_u32 = @as(u32, @truncate(val));

            futex.wait(uaddr, val_u32, timeout_ns) catch |err| {
                switch (err) {
                    error.Again => return error.EAGAIN,
                    error.TimedOut => return error.ETIMEDOUT,
                    error.Fault => return error.EFAULT,
                    error.PermDenied => return error.EPERM,
                }
            };
            return 0;
        },
        uapi.futex.FUTEX_WAKE => {
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
// epoll Implementation
// =============================================================================

/// Maximum number of fds per epoll instance
const EPOLL_MAX_FDS: usize = 64;

/// Entry in epoll watch list
const EpollEntry = struct {
    fd: i32,
    events: u32,
    data: u64,
    active: bool,
    last_revents: u32, // Previous poll result for edge-triggered detection
};

/// Epoll instance data stored in FD private_data
const EpollInstance = struct {
    entries: [EPOLL_MAX_FDS]EpollEntry,
    count: usize,
    lock: sync.Spinlock,

    fn init() EpollInstance {
        return .{
            .entries = [_]EpollEntry{.{ .fd = -1, .events = 0, .data = 0, .active = false, .last_revents = 0 }} ** EPOLL_MAX_FDS,
            .count = 0,
            .lock = .{},
        };
    }

    fn findEntry(self: *EpollInstance, fd: i32) ?*EpollEntry {
        for (&self.entries) |*e| {
            if (e.active and e.fd == fd) return e;
        }
        return null;
    }

    fn findFreeSlot(self: *EpollInstance) ?*EpollEntry {
        for (&self.entries) |*e| {
            if (!e.active) return e;
        }
        return null;
    }
};

/// File operations for epoll fds
const epoll_file_ops = fd_mod.FileOps{
    .read = null,
    .write = null,
    .close = epollClose,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

fn epollClose(fd: *fd_mod.FileDescriptor) isize {
    if (fd.private_data) |ptr| {
        const instance: *EpollInstance = @ptrCast(@alignCast(ptr));
        heap.allocator().destroy(instance);
    }
    return 0;
}

/// Get epoll instance from fd number
fn getEpollInstance(epfd: usize) ?*EpollInstance {
    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, epfd) orelse return null;
    const fd = table.get(fd_u32) orelse return null;

    // Verify this is an epoll fd by checking ops
    if (fd.ops.close != epollClose) return null;

    if (fd.private_data) |ptr| {
        return @ptrCast(@alignCast(ptr));
    }
    return null;
}

/// sys_epoll_create1 (291) - Create epoll instance
///
/// Creates a new epoll instance and returns a file descriptor.
/// Flags: EPOLL_CLOEXEC (0x80000) - set close-on-exec
pub fn sys_epoll_create1(flags: usize) SyscallError!usize {
    _ = flags; // EPOLL_CLOEXEC handled at FD level if needed

    // Allocate epoll instance
    const instance = heap.allocator().create(EpollInstance) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(instance);

    instance.* = EpollInstance.init();

    // Allocate FD
    const fd = heap.allocator().create(fd_mod.FileDescriptor) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(fd);

    fd.* = fd_mod.FileDescriptor{
        .ops = &epoll_file_ops,
        .flags = fd_mod.O_RDWR,
        .private_data = instance,
        .position = 0,
        .refcount = .{ .raw = 1 },
        .lock = .{},
    };

    // SECURITY: Use atomic allocAndInstall to prevent race between
    // allocFdNum and install where two threads could get the same fd_num
    const table = base.getGlobalFdTable();
    const fd_num = table.allocAndInstall(fd) orelse {
        heap.allocator().destroy(fd);
        return error.EMFILE;
    };

    return fd_num;
}

/// sys_epoll_ctl (233) - Control epoll instance
///
/// Add, modify, or remove entries in the interest list.
/// op: EPOLL_CTL_ADD (1), EPOLL_CTL_DEL (2), EPOLL_CTL_MOD (3)
pub fn sys_epoll_ctl(epfd: usize, op: usize, fd: usize, event_ptr: usize) SyscallError!usize {
    const instance = getEpollInstance(epfd) orelse return error.EBADF;

    const fd_i32: i32 = std.math.cast(i32, fd) orelse return error.EBADF;

    const held = instance.lock.acquire();
    defer held.release();

    switch (op) {
        uapi.epoll.EPOLL_CTL_ADD => {
            // Check if already exists
            if (instance.findEntry(fd_i32) != null) {
                return error.EEXIST;
            }

            // Find free slot
            const slot = instance.findFreeSlot() orelse {
                return error.ENOSPC; // Too many fds
            };

            // Read event from user
            if (event_ptr == 0) return error.EFAULT;
            const ev = UserPtr.from(event_ptr).readValue(uapi.epoll.EpollEvent) catch {
                return error.EFAULT;
            };

            slot.* = .{
                .fd = fd_i32,
                .events = ev.events,
                .data = ev.getData(),
                .active = true,
                .last_revents = 0,
            };
            instance.count += 1;
        },
        uapi.epoll.EPOLL_CTL_DEL => {
            const entry = instance.findEntry(fd_i32) orelse {
                return error.ENOENT;
            };
            entry.active = false;
            entry.fd = -1;
            instance.count -|= 1;
        },
        uapi.epoll.EPOLL_CTL_MOD => {
            const entry = instance.findEntry(fd_i32) orelse {
                return error.ENOENT;
            };

            // Read event from user
            if (event_ptr == 0) return error.EFAULT;
            const ev = UserPtr.from(event_ptr).readValue(uapi.epoll.EpollEvent) catch {
                return error.EFAULT;
            };

            entry.events = ev.events;
            entry.data = ev.getData();
            entry.last_revents = 0; // Reset edge state on modify
        },
        else => return error.EINVAL,
    }

    return 0;
}

/// sys_epoll_wait (232) - Wait for epoll events
///
/// Wait for events on the epoll instance.
/// Returns number of ready fds, or 0 on timeout.
///
/// Supports:
/// - Level-triggered (default): report events as long as condition is true
/// - Edge-triggered (EPOLLET): report only when state transitions from not-ready to ready
/// - One-shot (EPOLLONESHOT): disable entry after one event until re-armed via EPOLL_CTL_MOD
/// - Blocking with timeout: -1 = infinite, 0 = immediate, >0 = milliseconds
pub fn sys_epoll_wait(epfd: usize, events_ptr: usize, maxevents: usize, timeout: usize) SyscallError!usize {
    if (maxevents == 0 or maxevents > 1024) {
        return error.EINVAL;
    }

    const instance = getEpollInstance(epfd) orelse return error.EBADF;

    // Validate output buffer
    const ev_size = @sizeOf(uapi.epoll.EpollEvent);
    if (!base.isValidUserAccess(events_ptr, maxevents * ev_size, base.AccessMode.Write)) {
        return error.EFAULT;
    }

    // Allocate kernel buffer for results
    const result_buf = heap.allocator().alloc(uapi.epoll.EpollEvent, maxevents) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(result_buf);

    // Parse timeout: -1 = infinite, 0 = immediate, >0 = milliseconds
    const timeout_i: isize = @bitCast(timeout);
    const start_tsc = hal.timing.rdtsc();
    const timeout_us: ?u64 = if (timeout_i < 0)
        null // Infinite
    else if (timeout_i == 0)
        0 // Immediate
    else
        @as(u64, @intCast(timeout_i)) * 1000; // Convert ms to us

    const fd_table = base.getGlobalFdTable();

    // Poll loop - check FDs until ready or timeout
    while (true) {
        var ready_count: usize = 0;

        // Snapshot entries under lock
        var entries_copy: [EPOLL_MAX_FDS]EpollEntry = undefined;
        {
            const held = instance.lock.acquire();
            entries_copy = instance.entries;
            held.release();
        }

        // Check each watched fd
        for (&entries_copy) |*entry| {
            if (!entry.active) continue;
            if (ready_count >= maxevents) break;

            const entry_fd = entry.fd;
            const entry_events = entry.events;
            const entry_data = entry.data;
            const entry_last_revents = entry.last_revents;

            // Look up fd in FdTable
            var revents: u32 = 0;
            const fd_u32 = std.math.cast(u32, @as(usize, @intCast(entry_fd))) orelse {
                revents = uapi.epoll.EPOLLNVAL;
                // Invalid fd - skip to reporting
                if (revents != 0) {
                    result_buf[ready_count] = uapi.epoll.EpollEvent.init(revents, entry_data);
                    ready_count += 1;
                }
                continue;
            };

            if (fd_table.get(fd_u32)) |fd_obj| {
                // Call poll if available
                if (fd_obj.ops.poll) |poll_fn| {
                    revents = poll_fn(fd_obj, entry_events);
                } else {
                    // No poll - assume always ready for the modes the FD supports
                    if ((entry_events & uapi.epoll.EPOLLIN) != 0 and fd_obj.isReadable()) {
                        revents |= uapi.epoll.EPOLLIN;
                    }
                    if ((entry_events & uapi.epoll.EPOLLOUT) != 0 and fd_obj.isWritable()) {
                        revents |= uapi.epoll.EPOLLOUT;
                    }
                }
            } else {
                // FD no longer valid
                revents = uapi.epoll.EPOLLNVAL;
            }

            // Always OR in EPOLLERR and EPOLLHUP even if not in requested events
            // (Linux behavior - these are always reported)
            revents = revents & (entry_events | uapi.epoll.EPOLLERR | uapi.epoll.EPOLLHUP | uapi.epoll.EPOLLNVAL);

            // Edge-triggered check
            if ((entry_events & uapi.epoll.EPOLLET) != 0) {
                // Only report newly set bits (state transition)
                const new_events = revents & ~entry_last_revents;
                if (new_events == 0) {
                    continue; // No state transition, skip this entry
                }
                // Report only the new events
                revents = new_events;
            }

            // Update last_revents in the instance (before edge masking for next iteration)
            {
                const held = instance.lock.acquire();
                if (instance.findEntry(entry_fd)) |e| {
                    // Store the full revents (before edge filtering) for next comparison
                    e.last_revents = revents | entry_last_revents;
                }
                held.release();
            }

            // EPOLLONESHOT check
            if ((entry_events & uapi.epoll.EPOLLONESHOT) != 0 and revents != 0) {
                // Disable entry after one event delivery
                const held = instance.lock.acquire();
                if (instance.findEntry(entry_fd)) |e| {
                    e.events = 0; // Disabled until EPOLL_CTL_MOD
                }
                held.release();
            }

            // Add to result buffer if events are ready
            if (revents != 0) {
                result_buf[ready_count] = uapi.epoll.EpollEvent.init(revents, entry_data);
                ready_count += 1;
            }
        }

        // If any FDs ready, return immediately
        if (ready_count > 0) {
            const out_slice = result_buf[0..ready_count];
            _ = UserPtr.from(events_ptr).copyFromKernel(std.mem.sliceAsBytes(out_slice)) catch {
                return error.EFAULT;
            };
            return ready_count;
        }

        // Check timeout
        if (timeout_us) |us| {
            if (us == 0) break; // Immediate return (timeout=0)
            if (hal.timing.hasTimedOut(start_tsc, us)) break; // Timeout expired
        } else {
            // timeout_i == -1 (infinite) - will loop forever until events ready
        }

        // No FDs ready and not timed out - yield and retry
        if (timeout_i == 0) break; // Zero timeout means poll once
        sched.yield();
    }

    // Timeout or immediate return with no events
    return 0;
}

/// sys_epoll_pwait (281/22) - Wait for epoll events with signal mask
///
/// Like epoll_wait, but atomically sets the signal mask before checking events
/// and restores it after return. This prevents TOCTOU races where a signal
/// arrives between sigprocmask and epoll_wait.
///
/// When sigmask_ptr is NULL, behaves identically to epoll_wait.
///
/// Args:
///   epfd: epoll file descriptor
///   events_ptr: Pointer to array of epoll_event structures for output
///   maxevents: Maximum number of events to return (1-1024)
///   timeout: Timeout in milliseconds (-1=infinite, 0=immediate, >0=ms)
///   sigmask_ptr: Pointer to signal mask (NULL = no mask change)
///   sigsetsize: Size of signal mask (must be 8 for u64 SigSet)
///
/// Returns: Number of ready file descriptors, 0 on timeout
pub fn sys_epoll_pwait(epfd: usize, events_ptr: usize, maxevents: usize, timeout: usize, sigmask_ptr: usize, sigsetsize: usize) SyscallError!usize {
    const thread = sched.getCurrentThread() orelse return error.ESRCH;

    // Validate sigmask size if provided
    if (sigmask_ptr != 0 and sigsetsize != 8) {
        return error.EINVAL;
    }

    // Apply signal mask if provided (save old mask, set new mask)
    var old_mask: u64 = 0;
    var mask_applied = false;
    if (sigmask_ptr != 0) {
        const new_mask = UserPtr.from(sigmask_ptr).readValue(u64) catch {
            return error.EFAULT;
        };
        old_mask = thread.sigmask;
        thread.sigmask = new_mask;
        mask_applied = true;
    }
    defer if (mask_applied) {
        thread.sigmask = old_mask;
    };

    // Delegate to epoll_wait for the actual event waiting
    return sys_epoll_wait(epfd, events_ptr, maxevents, timeout);
}

// =============================================================================
// Process Control (prctl, CPU affinity) - separate module for organization
// =============================================================================

const control = @import("control.zig");
pub const sys_prctl = control.sys_prctl;
pub const sys_sched_setaffinity = control.sys_sched_setaffinity;
pub const sys_sched_getaffinity = control.sys_sched_getaffinity;
