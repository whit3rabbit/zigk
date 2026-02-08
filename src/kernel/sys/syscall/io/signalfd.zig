//! Signalfd System Call Implementation
//!
//! Implements signalfd4 and signalfd syscalls for signal notification via file descriptors.
//! Signalfd provides a way to receive signals via read() instead of signal handlers.
//!
//! Features:
//! - Signal mask filtering: only signals in mask are delivered to the fd
//! - Signal consumption: reading from signalfd clears the pending bit
//! - Mask updates: signalfd4 with existing fd updates the mask
//! - SIGKILL/SIGSTOP filtering: silently removed from mask (cannot be caught)
//! - Epoll integration: poll reports EPOLLIN when signals are pending
//!
//! Thread-safety:
//! - Spinlock protects mask updates
//! - Atomic woken flag prevents lost wakeups on SMP

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

// Signal constants
const SIGKILL: u64 = 9;
const SIGSTOP: u64 = 19;

/// Signalfd state
///
/// Lifecycle: ref_count starts at 1 (owned by the FD). Each active read/poll
/// operation holds an additional reference. Close sets the closed flag and drops
/// the FD's reference. The state is freed when the last reference is dropped.
const SignalFdState = struct {
    sigmask: u64,
    lock: sync.Spinlock,
    closed: std.atomic.Value(bool),
    ref_count: std.atomic.Value(u32),
    blocked_readers: ?*sched.Thread,
    reader_woken: std.atomic.Value(bool),

    fn init(sigmask: u64) SignalFdState {
        return SignalFdState{
            .sigmask = sigmask,
            .lock = .{},
            .closed = std.atomic.Value(bool).init(false),
            .ref_count = std.atomic.Value(u32).init(1),
            .blocked_readers = null,
            .reader_woken = std.atomic.Value(bool).init(false),
        };
    }

    fn ref(self: *SignalFdState) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn unref(self: *SignalFdState) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            heap.allocator().destroy(self);
        }
    }
};

/// Filter out SIGKILL and SIGSTOP from mask (cannot be caught)
fn filterMask(mask: u64) u64 {
    const kill_bit = @as(u64, 1) << (SIGKILL - 1);
    const stop_bit = @as(u64, 1) << (SIGSTOP - 1);
    return mask & ~kill_bit & ~stop_bit;
}

fn signalfdRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    if (buf.len < @sizeOf(uapi.signalfd.SignalFdSigInfo)) {
        return Errno.EINVAL.toReturn();
    }

    const state: *SignalFdState = @ptrCast(@alignCast(fd.private_data));
    state.ref();
    defer state.unref();

    const current = sched.getCurrentThread() orelse {
        return Errno.EINVAL.toReturn();
    };

    while (true) {
        if (state.closed.load(.acquire)) return Errno.EBADF.toReturn();

        const held = state.lock.acquire();

        // Check for pending signals in our mask (atomic load for SMP visibility)
        const pending = @atomicLoad(u64, &current.pending_signals, .acquire) & state.sigmask;

        if (pending != 0) {
            // Found a signal - find first set bit
            const sig_bit = @ctz(pending);
            const signum = sig_bit + 1;

            // CRITICAL: Atomically clear the pending bit to consume the signal.
            // Must use atomicRmw because signal delivery sets bits without
            // holding our spinlock - a plain &= would race and lose signals.
            _ = @atomicRmw(u64, &current.pending_signals, .And, ~(@as(u64, 1) << @intCast(sig_bit)), .acq_rel);

            held.release();

            // Build SignalFdSigInfo structure
            var info: uapi.signalfd.SignalFdSigInfo = std.mem.zeroes(uapi.signalfd.SignalFdSigInfo);
            info.ssi_signo = @intCast(signum);
            // For MVP, other fields (ssi_code, ssi_pid, ssi_uid) are zero
            // Full metadata requires signal queue infrastructure (future work)

            // Copy to userspace buffer
            const info_bytes = std.mem.asBytes(&info);
            @memcpy(buf[0..@sizeOf(uapi.signalfd.SignalFdSigInfo)], info_bytes);

            return @intCast(@sizeOf(uapi.signalfd.SignalFdSigInfo));
        }

        // No signals pending - check if we should block
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            held.release();
            return Errno.EAGAIN.toReturn();
        }

        // Block - use yield loop pattern (signal delivery will set pending_signals)
        // We use a simple yield loop because we don't have signal delivery wakeup integration yet
        held.release();

        // Yield to scheduler (signal delivery may occur during another thread's execution)
        sched.yield();

        // Retry loop - will re-check pending_signals
    }
}

fn signalfdPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    _ = requested_events;

    const state: *SignalFdState = @ptrCast(@alignCast(fd.private_data));
    state.ref();
    defer state.unref();

    if (state.closed.load(.acquire)) return 0;

    const current = sched.getCurrentThread() orelse return 0;

    var revents: u32 = 0;

    // Readable if any signals in mask are pending (atomic for SMP visibility)
    const pending = @atomicLoad(u64, &current.pending_signals, .acquire) & state.sigmask;
    if (pending != 0) {
        revents |= uapi.epoll.EPOLLIN;
    }

    return revents;
}

fn signalfdClose(fd: *fd_mod.FileDescriptor) isize {
    const state: *SignalFdState = @ptrCast(@alignCast(fd.private_data));

    // Mark as closed so blocked readers exit with EBADF
    state.closed.store(true, .release);

    // Drop the FD's reference. Last active operation to unref frees the state.
    state.unref();
    return 0;
}

/// File operations for signalfd
const signalfd_file_ops = fd_mod.FileOps{
    .read = signalfdRead,
    .write = null, // signalfd is read-only
    .close = signalfdClose,
    .poll = signalfdPoll,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .truncate = null,
    .getdents = null,
    .chown = null,
};

/// sys_signalfd4 (289) - Create or update signalfd with flags
///
/// Creates a new signalfd instance or updates an existing one.
/// fd: -1 to create new, >= 0 to update existing
/// mask: Pointer to u64 signal mask
/// sizemask: Size of mask in bytes (should be 8)
/// flags:
///   SFD_CLOEXEC (0x80000) - set close-on-exec
///   SFD_NONBLOCK (0x800) - set non-blocking mode
pub fn sys_signalfd4(fd_num_raw: usize, mask_ptr: usize, mask_size: usize, flags: usize) SyscallError!usize {
    _ = mask_size; // Should be @sizeOf(u64) = 8, but we don't strictly validate

    // Validate flags
    const valid_flags = uapi.signalfd.SFD_CLOEXEC | uapi.signalfd.SFD_NONBLOCK;
    if ((flags & ~valid_flags) != 0) return error.EINVAL;

    // Read mask from userspace
    const mask = UserPtr.from(mask_ptr).readValue(u64) catch {
        return error.EFAULT;
    };

    // Apply filtering to strip SIGKILL and SIGSTOP
    const filtered_mask = filterMask(mask);

    // Cast fd_num_raw to isize to check for -1
    const fd_num: isize = @bitCast(fd_num_raw);

    if (fd_num >= 0) {
        // Update existing signalfd
        const table = base.getGlobalFdTable();
        const fd = table.get(@intCast(fd_num)) orelse return error.EBADF;

        // Verify it's actually a signalfd
        if (fd.ops != &signalfd_file_ops) return error.EINVAL;

        const state: *SignalFdState = @ptrCast(@alignCast(fd.private_data));
        // Hold a reference to prevent use-after-free if a concurrent close()
        // drops the FD's reference between table.get() and lock.acquire().
        state.ref();
        defer state.unref();

        const held = state.lock.acquire();
        defer held.release();

        // Check if closed between table.get() and lock acquisition
        if (state.closed.load(.acquire)) return error.EBADF;

        // Update mask under lock
        state.sigmask = filtered_mask;

        return @intCast(fd_num);
    }

    // Create new signalfd (fd_num == -1)
    const state = heap.allocator().create(SignalFdState) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(state);

    state.* = SignalFdState.init(filtered_mask);

    // Allocate file descriptor
    const fd = heap.allocator().create(fd_mod.FileDescriptor) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(fd);

    var fd_flags: u32 = fd_mod.O_RDONLY;
    if ((flags & uapi.signalfd.SFD_NONBLOCK) != 0) {
        fd_flags |= fd_mod.O_NONBLOCK;
    }

    fd.* = fd_mod.FileDescriptor{
        .ops = &signalfd_file_ops,
        .flags = fd_flags,
        .private_data = state,
        .position = 0,
        .refcount = .{ .raw = 1 },
        .lock = .{},
        .cloexec = (flags & uapi.signalfd.SFD_CLOEXEC) != 0,
    };

    // Install in FD table
    const table = base.getGlobalFdTable();
    const new_fd_num = table.allocAndInstall(fd) orelse {
        // errdefer handles cleanup of fd and state
        return error.EMFILE;
    };

    return new_fd_num;
}

/// sys_signalfd (282) - Create or update signalfd without flags
///
/// Equivalent to sys_signalfd4(fd, mask, sizemask, 0)
pub fn sys_signalfd(fd_num_raw: usize, mask_ptr: usize, mask_size: usize) SyscallError!usize {
    return sys_signalfd4(fd_num_raw, mask_ptr, mask_size, 0);
}
