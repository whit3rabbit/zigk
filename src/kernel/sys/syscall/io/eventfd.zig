//! Eventfd System Call Implementation
//!
//! Implements eventfd2 and eventfd syscalls for event notification via file descriptors.
//! Eventfd provides a lightweight wait/notify mechanism using a 64-bit counter.
//!
//! Features:
//! - Counter semantics: write adds to counter, read drains it
//! - Semaphore mode (EFD_SEMAPHORE): read returns 1 and decrements by 1
//! - Nonblocking mode (EFD_NONBLOCK): EAGAIN instead of blocking
//! - Epoll integration: poll reports EPOLLIN when counter > 0, EPOLLOUT when counter < MAX
//!
//! Thread-safety:
//! - Spinlock protects counter modifications and waiter lists
//! - Atomic flags prevent lost wakeups on SMP

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

const MAX_COUNTER: u64 = 0xfffffffffffffffe;

/// Eventfd state
///
/// Lifecycle: ref_count starts at 1 (owned by the FD). Each active read/write/poll
/// operation holds an additional reference. Close sets the closed flag and drops the
/// FD's reference. The state is freed when the last reference is dropped.
const EventFdState = struct {
    counter: std.atomic.Value(u64),
    semaphore_mode: bool,
    lock: sync.Spinlock,
    closed: std.atomic.Value(bool),
    ref_count: std.atomic.Value(u32),
    blocked_readers: ?*sched.Thread,
    blocked_writers: ?*sched.Thread,
    reader_woken: std.atomic.Value(bool),
    writer_woken: std.atomic.Value(bool),

    fn init(initval: u64, semaphore_mode: bool) EventFdState {
        return EventFdState{
            .counter = std.atomic.Value(u64).init(initval),
            .semaphore_mode = semaphore_mode,
            .lock = .{},
            .closed = std.atomic.Value(bool).init(false),
            .ref_count = std.atomic.Value(u32).init(1),
            .blocked_readers = null,
            .blocked_writers = null,
            .reader_woken = std.atomic.Value(bool).init(false),
            .writer_woken = std.atomic.Value(bool).init(false),
        };
    }

    fn ref(self: *EventFdState) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn unref(self: *EventFdState) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            heap.allocator().destroy(self);
        }
    }
};

fn eventfdRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    if (buf.len < 8) return Errno.EINVAL.toReturn();

    const state: *EventFdState = @ptrCast(@alignCast(fd.private_data));
    state.ref();
    defer state.unref();

    while (true) {
        if (state.closed.load(.acquire)) return Errno.EBADF.toReturn();

        const held = state.lock.acquire();

        const current_counter = state.counter.load(.acquire);

        // If counter > 0, read it
        if (current_counter > 0) {
            const result: u64 = if (state.semaphore_mode) blk: {
                // Semaphore mode: return 1, decrement by 1
                state.counter.store(current_counter - 1, .release);
                break :blk 1;
            } else blk: {
                // Normal mode: return counter, reset to 0
                state.counter.store(0, .release);
                break :blk current_counter;
            };

            // Wake blocked writers if any
            if (state.blocked_writers) |t| {
                state.blocked_writers = null;
                state.writer_woken.store(true, .release);
                sched.unblock(t);
            }

            held.release();

            // Copy result to user buffer
            const result_bytes = std.mem.asBytes(&result);
            @memcpy(buf[0..8], result_bytes);

            return 8;
        }

        // Counter is 0, check if we should block
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            held.release();
            return Errno.EAGAIN.toReturn();
        }

        // Block - SMP-safe lost wakeup prevention
        state.blocked_readers = sched.getCurrentThread();
        state.reader_woken.store(false, .release);

        const interrupt_state = hal.cpu.disableInterruptsSaveFlags();
        held.release();

        // Check woken flag to catch SMP race
        if (!state.reader_woken.load(.acquire)) {
            sched.block();
        }

        hal.cpu.restoreInterrupts(interrupt_state);
        // Retry loop
    }
}

fn eventfdWrite(fd: *fd_mod.FileDescriptor, buf: []const u8) isize {
    if (buf.len < 8) return Errno.EINVAL.toReturn();

    // Read u64 value from buffer
    var value: u64 = undefined;
    const value_bytes = std.mem.asBytes(&value);
    @memcpy(value_bytes, buf[0..8]);

    // Reject maxInt(u64)
    if (value == 0xffffffffffffffff) return Errno.EINVAL.toReturn();

    const state: *EventFdState = @ptrCast(@alignCast(fd.private_data));
    state.ref();
    defer state.unref();

    while (true) {
        if (state.closed.load(.acquire)) return Errno.EBADF.toReturn();

        const held = state.lock.acquire();

        const current_counter = state.counter.load(.acquire);

        // Check for overflow
        const new_counter = std.math.add(u64, current_counter, value) catch {
            // Overflow check failed
            if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
                held.release();
                return Errno.EAGAIN.toReturn();
            }

            // Block until space available
            state.blocked_writers = sched.getCurrentThread();
            state.writer_woken.store(false, .release);

            const interrupt_state = hal.cpu.disableInterruptsSaveFlags();
            held.release();

            if (!state.writer_woken.load(.acquire)) {
                sched.block();
            }

            hal.cpu.restoreInterrupts(interrupt_state);
            continue; // Retry
        };

        // Also check against MAX_COUNTER
        if (new_counter > MAX_COUNTER) {
            if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
                held.release();
                return Errno.EAGAIN.toReturn();
            }

            // Block
            state.blocked_writers = sched.getCurrentThread();
            state.writer_woken.store(false, .release);

            const interrupt_state = hal.cpu.disableInterruptsSaveFlags();
            held.release();

            if (!state.writer_woken.load(.acquire)) {
                sched.block();
            }

            hal.cpu.restoreInterrupts(interrupt_state);
            continue; // Retry
        }

        // Store new counter value
        state.counter.store(new_counter, .release);

        // Wake blocked readers if any
        if (state.blocked_readers) |t| {
            state.blocked_readers = null;
            state.reader_woken.store(true, .release);
            sched.unblock(t);
        }

        held.release();
        return 8;
    }
}

fn eventfdPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    _ = requested_events;

    const state: *EventFdState = @ptrCast(@alignCast(fd.private_data));
    state.ref();
    defer state.unref();

    if (state.closed.load(.acquire)) return 0;

    const current_counter = state.counter.load(.acquire);

    var revents: u32 = 0;

    // EPOLLIN if counter > 0
    if (current_counter > 0) {
        revents |= uapi.epoll.EPOLLIN;
    }

    // EPOLLOUT if counter < MAX
    if (current_counter < MAX_COUNTER) {
        revents |= uapi.epoll.EPOLLOUT;
    }

    return revents;
}

fn eventfdClose(fd: *fd_mod.FileDescriptor) isize {
    const state: *EventFdState = @ptrCast(@alignCast(fd.private_data));

    // Mark as closed and wake any blocked threads so they can exit with EBADF
    const held = state.lock.acquire();
    state.closed.store(true, .release);

    if (state.blocked_readers) |t| {
        state.blocked_readers = null;
        state.reader_woken.store(true, .release);
        sched.unblock(t);
    }
    if (state.blocked_writers) |t| {
        state.blocked_writers = null;
        state.writer_woken.store(true, .release);
        sched.unblock(t);
    }

    held.release();

    // Drop the FD's reference. If no active readers/writers hold a reference,
    // this frees the state. Otherwise, the last active operation frees it.
    state.unref();
    return 0;
}

/// File operations for eventfd
const eventfd_file_ops = fd_mod.FileOps{
    .read = eventfdRead,
    .write = eventfdWrite,
    .close = eventfdClose,
    .poll = eventfdPoll,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .truncate = null,
    .getdents = null,
    .chown = null,
};

/// sys_eventfd2 (290) - Create eventfd with flags
///
/// Creates a new eventfd instance and returns a file descriptor.
/// Flags:
///   EFD_CLOEXEC (0x80000) - set close-on-exec
///   EFD_NONBLOCK (0x800) - set non-blocking mode
///   EFD_SEMAPHORE (0x1) - semaphore semantics (read returns 1)
pub fn sys_eventfd2(initval: usize, flags: usize) SyscallError!usize {
    // Validate flags
    const valid_flags = uapi.eventfd.EFD_CLOEXEC | uapi.eventfd.EFD_NONBLOCK | uapi.eventfd.EFD_SEMAPHORE;
    if ((flags & ~valid_flags) != 0) return error.EINVAL;

    const semaphore_mode = (flags & uapi.eventfd.EFD_SEMAPHORE) != 0;

    // Allocate state
    const state = heap.allocator().create(EventFdState) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(state);

    state.* = EventFdState.init(@as(u64, @intCast(initval)), semaphore_mode);

    // Allocate file descriptor
    const fd = heap.allocator().create(fd_mod.FileDescriptor) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(fd);

    var fd_flags: u32 = fd_mod.O_RDWR;
    if ((flags & uapi.eventfd.EFD_NONBLOCK) != 0) {
        fd_flags |= fd_mod.O_NONBLOCK;
    }

    fd.* = fd_mod.FileDescriptor{
        .ops = &eventfd_file_ops,
        .flags = fd_flags,
        .private_data = state,
        .position = 0,
        .refcount = .{ .raw = 1 },
        .lock = .{},
        .cloexec = (flags & uapi.eventfd.EFD_CLOEXEC) != 0,
    };

    // Install in FD table
    const table = base.getGlobalFdTable();
    const fd_num = table.allocAndInstall(fd) orelse {
        // errdefer handles cleanup of fd and state
        return error.EMFILE;
    };

    return fd_num;
}

/// sys_eventfd (284) - Create eventfd with default flags
///
/// Equivalent to sys_eventfd2(initval, 0)
pub fn sys_eventfd(initval: usize) SyscallError!usize {
    return sys_eventfd2(initval, 0);
}
