//! IO Uring Opcode Handlers

const std = @import("std");
const uapi = @import("uapi");
const io_ring = uapi.io_ring;
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const io = @import("io");
const net = @import("net");
const socket = net.transport.socket;
const keyboard = @import("keyboard");
const fd_mod = @import("fd.zig");
const syscall_fd = @import("syscall_fd");
const types = @import("types.zig");
const instance = @import("instance.zig");
const heap = @import("heap");

pub fn processSqe(inst: *instance.IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    switch (sqe.opcode) {
        io_ring.IORING_OP_NOP => {
            // NOP completes immediately
            _ = inst.addCqe(sqe.user_data, 0, 0);
        },

        io_ring.IORING_OP_READ => {
            try processReadOp(inst, sqe);
        },

        io_ring.IORING_OP_WRITE => {
            try processWriteOp(inst, sqe);
        },

        io_ring.IORING_OP_ACCEPT => {
            try processAcceptOp(inst, sqe);
        },

        io_ring.IORING_OP_CONNECT => {
            try processConnectOp(inst, sqe);
        },

        io_ring.IORING_OP_RECV => {
            try processRecvOp(inst, sqe);
        },

        io_ring.IORING_OP_SEND => {
            try processSendOp(inst, sqe);
        },

        io_ring.IORING_OP_TIMEOUT => {
            try processTimeoutOp(inst, sqe);
        },

        io_ring.IORING_OP_OPENAT => {
            processOpenatOp(inst, sqe);
        },

        io_ring.IORING_OP_CLOSE => {
            processCloseOp(inst, sqe);
        },

        io_ring.IORING_OP_ASYNC_CANCEL => {
            processAsyncCancelOp(inst, sqe);
        },

        else => {
            return error.EINVAL;
        },
    }
}

fn processReadOp(inst: *instance.IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    // Allocate IoRequest
    const req = io.allocRequest(.keyboard_read) orelse return error.ENOMEM;
    errdefer io.freeRequest(req);

    req.fd = sqe.fd;
    req.user_data = sqe.user_data;

    // SECURITY: Use bounce buffer to prevent TOCTOU race condition.
    // User could unmap/remap the buffer between validation and async completion.
    const buf = try initBounceBuffer(req, sqe.addr, sqe.len, .Write, false);
    req.buf_ptr = @intFromPtr(buf.ptr);
    req.buf_len = buf.len;

    // For now, assume keyboard read for fd -1 or special fd
    // In full implementation, would dispatch based on fd type
    if (keyboard.getCharAsync(req)) {
        // Queued for later - add to pending
        if (!inst.addPendingRequest(req)) {
            instance.IoUringInstance.finalizeBounceBuffer(req);
            io.freeRequest(req);
            return error.EBUSY;
        }
    } else {
        // Completed immediately - finalize bounce buffer and generate CQE
        instance.IoUringInstance.finalizeBounceBuffer(req);
        const res: i32 = switch (req.result) {
            .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.freeRequest(req);
    }
}

fn processWriteOp(inst: *instance.IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    // Validate fd
    if (sqe.fd < 0) {
        _ = inst.addCqe(sqe.user_data, -@as(i32, 9), 0); // EBADF
        return;
    }

    // Validate user buffer
    if (!user_mem.isValidUserAccess(sqe.addr, sqe.len, .Read)) {
        _ = inst.addCqe(sqe.user_data, -@as(i32, 14), 0); // EFAULT
        return;
    }

    // Dispatch to sys_write implementation
    // properties of `io_uring` module allow importing `syscall_io`.
    const io_syscall = @import("syscall_io");
    
    const result = io_syscall.sys_write(@intCast(sqe.fd), sqe.addr, sqe.len);

    const res: i32 = if (result) |n|
        @intCast(@min(n, @as(usize, std.math.maxInt(i32))))
    else |e|
        @intCast(uapi.errno.errorToReturn(e));

    _ = inst.addCqe(sqe.user_data, res, 0);
}

fn processAcceptOp(inst: *instance.IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    // Get socket from fd
    const sock_fd: usize = @intCast(sqe.fd);

    // Allocate IoRequest
    const req = io.allocRequest(.socket_accept) orelse return error.ENOMEM;
    errdefer io.freeRequest(req);

    req.fd = sqe.fd;
    req.user_data = sqe.user_data;
    req.op_data.accept = .{
        .addr_ptr = sqe.addr,
        .addrlen_ptr = sqe.off,
    };

    // Try async accept - returns true if pending, false if completed immediately
    const is_pending = socket.acceptAsync(sock_fd, req) catch |e| {
        io.freeRequest(req);
        return socketErrorToSyscallError(e);
    };

    if (!is_pending) {
        // Completed immediately
        const res: i32 = switch (req.result) {
            .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.freeRequest(req);
    } else {
        // Queued for later
        if (!inst.addPendingRequest(req)) {
            io.freeRequest(req);
            return error.EBUSY;
        }
    }
}

fn processConnectOp(inst: *instance.IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    const sock_fd: usize = @intCast(sqe.fd);

    const req = io.allocRequest(.socket_connect) orelse return error.ENOMEM;
    errdefer io.freeRequest(req);

    req.fd = sqe.fd;
    req.user_data = sqe.user_data;
    req.op_data.connect = .{
        .addr_ptr = sqe.addr,
        .addrlen = @intCast(sqe.len),
    };

    // Copy address from userspace
    if (!user_mem.isValidUserAccess(sqe.addr, @sizeOf(socket.SockAddrIn), .Read)) {
        io.freeRequest(req);
        return error.EFAULT;
    }

    // SECURITY: Zero-initialize to prevent info leak
    var addr: socket.SockAddrIn = std.mem.zeroes(socket.SockAddrIn);
    const addr_bytes = std.mem.asBytes(&addr);
    if (user_mem.copyFromUser(addr_bytes, sqe.addr) != 0) {
        io.freeRequest(req);
        return error.EFAULT;
    }

    const is_pending = socket.connectAsync(sock_fd, req, &addr) catch |e| {
        io.freeRequest(req);
        return socketErrorToSyscallError(e);
    };

    if (!is_pending) {
        const res: i32 = switch (req.result) {
            .success => 0,
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.freeRequest(req);
    } else {
        if (!inst.addPendingRequest(req)) {
            instance.IoUringInstance.finalizeBounceBuffer(req);
            io.freeRequest(req);
            return error.EBUSY;
        }
    }
}

fn initBounceBuffer(
    req: *io.IoRequest,
    user_ptr: usize,
    len: usize,
    mode: user_mem.AccessMode,
    copy_from_user: bool,
) SyscallError![]u8 {
    if (len == 0) {
        req.bounce_buf = null;
        req.user_buf_ptr = user_ptr;
        req.user_buf_len = 0;
        return &[_]u8{};
    }

    if (!user_mem.isValidUserAccess(user_ptr, len, mode)) {
        return error.EFAULT;
    }

    const kbuf = heap.allocator().alloc(u8, len) catch return error.ENOMEM;
    errdefer heap.allocator().free(kbuf);

    if (copy_from_user) {
        const uptr = user_mem.UserPtr.from(user_ptr);
        _ = uptr.copyToKernel(kbuf) catch {
            return error.EFAULT;
        };
    }

    req.bounce_buf = kbuf;
    req.user_buf_ptr = user_ptr;
    req.user_buf_len = len;
    return kbuf;
}

fn processRecvOp(inst: *instance.IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    const sock_fd: usize = @intCast(sqe.fd);

    const req = io.allocRequest(.socket_read) orelse return error.ENOMEM;
    errdefer io.freeRequest(req);

    req.fd = sqe.fd;
    req.user_data = sqe.user_data;

    const buf = try initBounceBuffer(req, sqe.addr, sqe.len, .Write, false);
    req.buf_ptr = @intFromPtr(buf.ptr);
    req.buf_len = buf.len;

    const is_pending = socket.recvAsync(sock_fd, req, buf) catch |e| {
        if (req.bounce_buf) |bounce| {
            heap.allocator().free(bounce);
            req.bounce_buf = null;
        }
        io.freeRequest(req);
        return socketErrorToSyscallError(e);
    };

    if (!is_pending) {
        instance.IoUringInstance.finalizeBounceBuffer(req);
        const res: i32 = switch (req.result) {
            .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.freeRequest(req);
    } else {
        if (!inst.addPendingRequest(req)) {
            instance.IoUringInstance.finalizeBounceBuffer(req);
            io.freeRequest(req);
            return error.EBUSY;
        }
    }
}

fn processSendOp(inst: *instance.IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    const sock_fd: usize = @intCast(sqe.fd);

    const req = io.allocRequest(.socket_write) orelse return error.ENOMEM;
    errdefer io.freeRequest(req);

    req.fd = sqe.fd;
    req.user_data = sqe.user_data;

    const buf = try initBounceBuffer(req, sqe.addr, sqe.len, .Read, true);
    const data: []const u8 = buf;
    req.buf_ptr = @intFromPtr(data.ptr);
    req.buf_len = data.len;

    const is_pending = socket.sendAsync(sock_fd, req, data) catch |e| {
        if (req.bounce_buf) |bounce| {
            heap.allocator().free(bounce);
            req.bounce_buf = null;
        }
        io.freeRequest(req);
        return socketErrorToSyscallError(e);
    };

    if (!is_pending) {
        instance.IoUringInstance.finalizeBounceBuffer(req);
        const res: i32 = switch (req.result) {
            .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.freeRequest(req);
    } else {
        if (!inst.addPendingRequest(req)) {
            io.freeRequest(req);
            return error.EBUSY;
        }
    }
}

/// Kernel timespec structure for timeout operations
const KernelTimespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

fn processTimeoutOp(inst: *instance.IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    // IORING_OP_TIMEOUT uses:
    //   - sqe.addr: pointer to struct __kernel_timespec
    //   - sqe.len: count (number of completions to wait for, 0 = pure timeout)
    //   - sqe.off: flags (IORING_TIMEOUT_ABS for absolute time)

    const req = io.allocRequest(.timer) orelse return error.ENOMEM;
    errdefer io.freeRequest(req);

    req.user_data = sqe.user_data;

    // Read timeout value from userspace
    if (sqe.addr != 0) {
        // SECURITY: Copy timespec to kernel stack to prevent TOCTOU.
        // Do NOT dereference user memory directly via @ptrFromInt.
        const user_ptr = user_mem.UserPtr.from(sqe.addr);
        const ts = user_ptr.readValue(KernelTimespec) catch {
            io.freeRequest(req);
            return error.EFAULT;
        };

        // SECURITY: Clamp values to prevent integer overflow in multiplication.
        // Max timeout of ~1 year prevents overflow when multiplied by 1e9.
        const MAX_TIMEOUT_SEC: i64 = 86400 * 365; // ~1 year
        const MAX_NSEC: i64 = 999_999_999;

        const clamped_sec = @min(@max(0, ts.tv_sec), MAX_TIMEOUT_SEC);
        const clamped_nsec = @min(@max(0, ts.tv_nsec), MAX_NSEC);

        const timeout_ns: u64 = @as(u64, @intCast(clamped_sec)) * 1_000_000_000 +
            @as(u64, @intCast(clamped_nsec));

        // Convert nanoseconds to ticks (1ms per tick)
        const timeout_ticks = io.nsToTicks(timeout_ns);

        // Transition request to pending
        if (!req.compareAndSwapState(.idle, .pending)) {
            io.freeRequest(req);
            return error.EINVAL;
        }

        // Add to reactor timer queue
        const reactor = io.getGlobal();
        reactor.addTimer(req, timeout_ticks);

        // Add to pending list for CQE generation
        if (!inst.addPendingRequest(req)) {
            _ = reactor.cancelTimer(req);
            io.freeRequest(req);
            return error.EBUSY;
        }
    } else {
        // No timeout specified - complete immediately
        _ = req.complete(.{ .success = 0 });
        _ = inst.addCqe(sqe.user_data, 0, 0);
        io.freeRequest(req);
    }
}

fn processOpenatOp(inst: *instance.IoUringInstance, sqe: *const io_ring.IoUringSqe) void {
    // IORING_OP_OPENAT uses:
    //   - sqe.fd: dirfd (AT_FDCWD for cwd)
    //   - sqe.addr: pathname pointer
    //   - sqe.len: flags (O_RDONLY, O_WRONLY, etc.)
    //   - sqe.off: mode (low 32 bits)
    const result = syscall_fd.sys_openat(
        @bitCast(@as(i64, sqe.fd)), // Handle negative dirfd (AT_FDCWD = -100)
        sqe.addr,
        sqe.len,
        @truncate(sqe.off),
    );

    const res: i32 = if (result) |fd|
        @intCast(@min(fd, @as(usize, std.math.maxInt(i32))))
    else |e|
        @intCast(uapi.errno.errorToReturn(e));

    _ = inst.addCqe(sqe.user_data, res, 0);
}

fn processCloseOp(inst: *instance.IoUringInstance, sqe: *const io_ring.IoUringSqe) void {
    // IORING_OP_CLOSE uses:
    //   - sqe.fd: file descriptor to close
    if (sqe.fd < 0) {
        _ = inst.addCqe(sqe.user_data, -@as(i32, 9), 0); // EBADF
        return;
    }

    const result = syscall_fd.sys_close(@intCast(sqe.fd));

    const res: i32 = if (result) |_|
        0
    else |e|
        @intCast(uapi.errno.errorToReturn(e));

    _ = inst.addCqe(sqe.user_data, res, 0);
}

fn processAsyncCancelOp(inst: *instance.IoUringInstance, sqe: *const io_ring.IoUringSqe) void {
    // IORING_OP_ASYNC_CANCEL uses:
    //   - sqe.addr: user_data of request to cancel
    const target_user_data = sqe.addr;

    // Search pending requests for matching user_data
    for (inst.pending_requests[0..inst.pending_count]) |req| {
        if (req.user_data == target_user_data) {
            // Attempt to cancel the request
            if (req.cancel()) {
                // Successfully cancelled - CQE for cancelled request will be
                // generated by processPendingRequests()
                _ = inst.addCqe(sqe.user_data, 0, 0);
                return;
            }
        }
    }

    // No matching request found or cancel failed
    _ = inst.addCqe(sqe.user_data, -@as(i32, 2), 0); // ENOENT
}

fn socketErrorToSyscallError(err: socket.SocketError) SyscallError {
    return switch (err) {
        socket.SocketError.BadFd => error.EBADF,
        socket.SocketError.AfNotSupported => error.EAFNOSUPPORT,
        socket.SocketError.TypeNotSupported => error.ESOCKTNOSUPPORT,
        socket.SocketError.NoSocketsAvailable => error.ENFILE,
        socket.SocketError.AddrInUse => error.EADDRINUSE,
        socket.SocketError.AddrNotAvail => error.EADDRNOTAVAIL,
        socket.SocketError.NetworkDown => error.ENETDOWN,
        socket.SocketError.NetworkUnreachable => error.ENETUNREACH,
        socket.SocketError.WouldBlock => error.EAGAIN,
        socket.SocketError.TimedOut => error.ETIMEDOUT,
        socket.SocketError.InvalidArg => error.EINVAL,
        socket.SocketError.AlreadyConnected => error.EISCONN,
        socket.SocketError.NotConnected => error.ENOTCONN,
        socket.SocketError.ConnectionRefused => error.ECONNREFUSED,
        socket.SocketError.ConnectionReset => error.ECONNRESET,
        socket.SocketError.AccessDenied => error.EACCES,
        socket.SocketError.NoResources => error.ENOMEM,
        socket.SocketError.SystemError => error.ENOSYS,
    };
}
