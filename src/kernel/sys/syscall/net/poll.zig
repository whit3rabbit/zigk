//! Poll Syscall Implementation
//!
//! Implements sys_poll for waiting on file descriptors.
//! Extracted from net.zig for better maintainability.

const std = @import("std");
const uapi = @import("uapi");
const net = @import("net");
const socket = net.transport.socket;
const SyscallError = uapi.errno.SyscallError;
const sched = @import("sched");
const hal = @import("hal");
const user_mem = @import("user_mem");
const heap = @import("heap");
const base = @import("base.zig");
const fd_mod = @import("fd");

// Re-use helpers from parent module (will be imported by net.zig)
const isValidUserAccess = user_mem.isValidUserAccess;
const AccessMode = user_mem.AccessMode;

/// Check if current thread has pending signals
pub fn hasPendingSignal() bool {
    const current = sched.getCurrentThread() orelse return false;
    const pending = current.pending_signals & ~current.sigmask;
    return pending != 0;
}

/// Convert poll timeout (ms) to scheduler ticks
pub fn pollTimeoutToTicks(timeout_ms: isize) ?u64 {
    if (timeout_ms < 0) return null;
    if (timeout_ms == 0) return 0;

    const tick_ms: u64 = 10;
    const timeout_u64 = std.math.cast(u64, timeout_ms) orelse return null;
    return std.math.divCeil(u64, timeout_u64, tick_ms) catch unreachable;
}

/// Block the current thread
fn blockCurrentThread() void {
    sched.block();
}

/// Get current thread pointer
fn getCurrentThread() ?*anyopaque {
    const t = sched.getCurrentThread() orelse return null;
    return @ptrCast(t);
}

/// Get socket context for an fd (re-implemented to avoid circular import)
fn getSocketContext(fd_num: usize, socket_file_ops: *const fd_mod.FileOps) ?struct { fd: *fd_mod.FileDescriptor, socket_idx: usize } {
    const SocketFdData = struct {
        socket_idx: usize,
    };

    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, fd_num) orelse return null;
    const fd = table.get(fd_u32) orelse return null;

    if (fd.ops != socket_file_ops) {
        return null;
    }
    const data_ptr = fd.private_data orelse return null;
    const ctx: *SocketFdData = @ptrCast(@alignCast(data_ptr));
    return .{ .fd = fd, .socket_idx = ctx.socket_idx };
}

/// sys_poll (7) - Wait for some event on a file descriptor
/// (ufds, nfds, timeout) -> int
///
/// Security: Copies pollfd array to kernel memory to prevent TOCTOU races.
/// A malicious userspace thread could modify fd values or unmap memory
/// while poll is blocked, causing kernel faults or invalid socket access.
pub fn sys_poll(ufds: usize, nfds: usize, timeout: isize, socket_file_ops: *const fd_mod.FileOps) SyscallError!usize {
    if (hasPendingSignal()) {
        return error.EINTR;
    }

    // Limit nfds to prevent excessive kernel allocations (matches Linux RLIMIT_NOFILE default)
    const max_nfds: usize = 1024;
    if (nfds > max_nfds) {
        return error.EINVAL;
    }

    if (nfds == 0) {
        // No fds to poll - if timeout is 0, return immediately; otherwise block
        if (timeout == 0) return 0;
        if (pollTimeoutToTicks(timeout)) |ticks| {
            if (ticks > 0) {
                sched.sleepForTicks(ticks);
            }
            if (hasPendingSignal()) {
                return error.EINTR;
            }
            return 0;
        }

        blockCurrentThread();
        if (hasPendingSignal()) {
            return error.EINTR;
        }
        return 0;
    }

    // Validate pollfd array pointer
    // SECURITY: Use checked arithmetic to prevent integer overflow.
    const poll_size = @sizeOf(uapi.poll.PollFd);
    const array_size = std.math.mul(usize, nfds, poll_size) catch return error.EINVAL;
    if (!isValidUserAccess(ufds, array_size, AccessMode.Read) or
        !isValidUserAccess(ufds, array_size, AccessMode.Write))
    {
        return error.EFAULT;
    }

    // Security: Copy pollfd array to kernel memory to prevent TOCTOU
    // This protects against:
    // 1. Racing userspace modifying fd values between check and use
    // 2. Userspace unmapping the pollfd array while poll is blocked
    const kpollfds = heap.allocator().alloc(uapi.poll.PollFd, nfds) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kpollfds);

    // Copy from userspace
    const ufds_uptr = user_mem.UserPtr.from(ufds);
    _ = ufds_uptr.copyToKernel(std.mem.sliceAsBytes(kpollfds)) catch {
        return error.EFAULT;
    };

    // Polling loop using kernel copy
    var ready_count: usize = 0;

    // Check events immediately (non-blocking pass)
    for (kpollfds) |*pfd| {
        pfd.revents = 0;

        if (pfd.fd < 0) continue;

        // Basic handling for stdin/stdout/stderr
        if (pfd.fd <= 2) {
            const events: u16 = @bitCast(pfd.events);
            if (pfd.fd > 0 and (events & uapi.poll.POLLOUT) != 0) {
                pfd.revents |= @bitCast(uapi.poll.POLLOUT);
            }
            continue;
        }

        // Safe cast: fd is positive after checks above
        const fd_usize: usize = @intCast(pfd.fd);
        const socket_ctx = getSocketContext(fd_usize, socket_file_ops) orelse {
            pfd.revents |= @bitCast(uapi.poll.POLLNVAL);
            continue;
        };
        const events: u16 = @bitCast(pfd.events);
        pfd.revents = @bitCast(socket.checkPollEvents(socket_ctx.socket_idx, events));

        if (pfd.revents != 0) {
            ready_count += 1;
        }
    }

    if (ready_count > 0 or timeout == 0) {
        // Copy results back to userspace
        _ = ufds_uptr.copyFromKernel(std.mem.sliceAsBytes(kpollfds)) catch {
            return error.EFAULT;
        };
        return ready_count;
    }

    // Blocking Wait
    // Note: timeout is ms. -1 = infinite.
    const current_thread = getCurrentThread();

    // SECURITY: Store socket indices we register on to prevent TOCTOU race.
    // If an fd is closed and reused while we're blocked, re-looking up by fd
    // would find the wrong socket. By storing socket_idx at registration time,
    // we ensure we clear the correct sockets even if fds are recycled.
    // Max 1024 sockets (matches max_nfds limit above).
    var registered_sockets: [1024]?usize = [_]?usize{null} ** 1024;

    // Register blocked thread on all sockets (using kernel copy of fd values)
    for (kpollfds, 0..) |*pfd, i| {
        // fd > 2 ensures positive value, safe to cast
        if (pfd.fd > 2) {
            const fd_u: usize = @intCast(pfd.fd);
            if (getSocketContext(fd_u, socket_file_ops)) |ctx| {
                if (socket.getSocket(ctx.socket_idx)) |sock| {
                    if (current_thread) |t| {
                        sock.blocked_thread = t;
                        if (sock.tcb) |tcb| {
                            tcb.blocked_thread = t;
                        }
                        // Store the socket index for cleanup
                        registered_sockets[i] = ctx.socket_idx;
                    }
                }
            }
        }
    }

    // Block
    if (pollTimeoutToTicks(timeout)) |ticks| {
        if (ticks > 0) {
            sched.sleepForTicks(ticks);
        }
    } else {
        blockCurrentThread();
    }

    // Woke up - Clear blocked thread registration using stored socket indices
    for (registered_sockets[0..nfds]) |maybe_idx| {
        if (maybe_idx) |sock_idx| {
            if (socket.getSocket(sock_idx)) |sock| {
                if (current_thread) |t| {
                    if (sock.blocked_thread == t) {
                        sock.blocked_thread = null;
                    }
                    if (sock.tcb) |tcb| {
                        if (tcb.blocked_thread == t) {
                            tcb.blocked_thread = null;
                        }
                    }
                }
            }
        }
    }

    // Re-check events using kernel copy
    ready_count = 0;
    for (kpollfds) |*pfd| {
        // Ensure consistent reporting
        pfd.revents = 0;

        if (pfd.fd < 0) continue;

        if (pfd.fd <= 2) {
            const events: u16 = @bitCast(pfd.events);
            if (pfd.fd > 0 and (events & uapi.poll.POLLOUT) != 0) {
                pfd.revents |= @bitCast(uapi.poll.POLLOUT);
            }
            continue;
        }

        // Safe cast: fd is positive after checks above
        const fd_usize: usize = @intCast(pfd.fd);
        const socket_ctx = getSocketContext(fd_usize, socket_file_ops) orelse {
            pfd.revents |= @bitCast(uapi.poll.POLLNVAL);
            continue;
        };
        const events: u16 = @bitCast(pfd.events);
        pfd.revents = @bitCast(socket.checkPollEvents(socket_ctx.socket_idx, events));

        if (pfd.revents != 0) {
            ready_count += 1;
        }
    }

    if (ready_count == 0 and hasPendingSignal()) {
        return error.EINTR;
    }

    // Copy results back to userspace
    _ = ufds_uptr.copyFromKernel(std.mem.sliceAsBytes(kpollfds)) catch {
        return error.EFAULT;
    };

    return ready_count;
}
