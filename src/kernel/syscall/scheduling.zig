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
};

/// Epoll instance data stored in FD private_data
const EpollInstance = struct {
    entries: [EPOLL_MAX_FDS]EpollEntry,
    count: usize,
    lock: sync.Spinlock,

    fn init() EpollInstance {
        return .{
            .entries = [_]EpollEntry{.{ .fd = -1, .events = 0, .data = 0, .active = false }} ** EPOLL_MAX_FDS,
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

    // Install in FD table
    const table = base.getGlobalFdTable();
    const fd_num = table.allocFdNum() orelse {
        heap.allocator().destroy(fd);
        return error.EMFILE;
    };

    table.install(fd_num, fd);

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
        },
        else => return error.EINVAL,
    }

    return 0;
}

/// sys_epoll_wait (232) - Wait for epoll events
///
/// Wait for events on the epoll instance.
/// Returns number of ready fds, or 0 on timeout.
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

    // Check events (simplified - does one pass)
    var ready_count: usize = 0;
    const timeout_i: isize = @bitCast(timeout);

    // Take a snapshot of entries under lock
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

        // Check if fd has events
        // MVP: Only check stdin (0), stdout (1), stderr (2) for basic events
        var revents: u32 = 0;

        if (entry.fd >= 0 and entry.fd <= 2) {
            // stdout/stderr are always writable
            if (entry.fd > 0 and (entry.events & uapi.epoll.EPOLLOUT) != 0) {
                revents |= uapi.epoll.EPOLLOUT;
            }
            // stdin - check if data available (MVP: assume not unless keyboard has data)
            if (entry.fd == 0 and (entry.events & uapi.epoll.EPOLLIN) != 0) {
                // Would need keyboard buffer check here
            }
        } else {
            // For other fds, check via FD table
            const table = base.getGlobalFdTable();
            const fd_u32 = std.math.cast(u32, @as(usize, @intCast(entry.fd))) orelse continue;
            if (table.get(fd_u32)) |fd_obj| {
                // Check if fd has poll operation
                if (fd_obj.ops.poll) |poll_fn| {
                    const poll_events = poll_fn(fd_obj, @truncate(entry.events));
                    revents = @intCast(poll_events);
                }
            } else {
                // FD no longer valid
                revents = uapi.epoll.EPOLLNVAL;
            }
        }

        if (revents != 0) {
            result_buf[ready_count] = uapi.epoll.EpollEvent.init(revents, entry.data);
            ready_count += 1;
        }
    }

    // If events found or timeout is 0, return immediately
    if (ready_count > 0 or timeout_i == 0) {
        // Copy results to userspace
        const out_slice = result_buf[0..ready_count];
        _ = UserPtr.from(events_ptr).copyFromKernel(std.mem.sliceAsBytes(out_slice)) catch {
            return error.EFAULT;
        };
        return ready_count;
    }

    // If timeout is -1 (infinite) or positive, we would block here
    // MVP: Just return 0 (timeout) since blocking requires more infrastructure
    return 0;
}
