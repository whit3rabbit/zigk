//! Scatter/Gather I/O Syscalls (sendmsg/recvmsg)
//!
//! Implements sys_sendmsg and sys_recvmsg for advanced socket I/O.
//! Extracted from net.zig for better maintainability.

const std = @import("std");
const uapi = @import("uapi");
const net = @import("net");
const socket = net.transport.socket;
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const heap = @import("heap");
const base = @import("base.zig");
const fd_mod = @import("fd");

const isValidUserAccess = user_mem.isValidUserAccess;
const AccessMode = user_mem.AccessMode;

const IoVec = uapi.abi.IoVec;
const MsgHdr = uapi.abi.MsgHdr;

/// Maximum number of iovecs to prevent excessive kernel allocations
const MAX_IOV_COUNT: usize = 1024;

/// Maximum total message size for sendmsg/recvmsg
const MAX_MSG_SIZE: usize = 65536;

/// Convert socket layer errors to SyscallError
fn socketErrorToSyscallError(err: socket.SocketError) SyscallError {
    return switch (err) {
        socket.SocketError.BadFd => error.EBADF,
        socket.SocketError.AfNotSupported => error.EAFNOSUPPORT,
        socket.SocketError.TypeNotSupported => error.ESOCKTNOSUPPORT,
        socket.SocketError.ProtoNotSupported => error.EPROTONOSUPPORT,
        socket.SocketError.NoSocketsAvailable => error.EMFILE,
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
        socket.SocketError.NoBuffers => error.ENOBUFS,
        socket.SocketError.MsgSize => error.EMSGSIZE,
        socket.SocketError.SystemError => error.EIO,
    };
}

/// Get socket context for an fd
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

/// sys_sendmsg (46) - Send a message on a socket with scatter/gather I/O
/// (fd, msg_ptr, flags) -> ssize_t
///
/// Gathers data from multiple user buffers (iovecs) and sends as single message.
/// SECURITY: All user data is copied to kernel buffers to prevent TOCTOU.
pub fn sys_sendmsg(fd: usize, msg_ptr: usize, flags: usize, socket_file_ops: *const fd_mod.FileOps) SyscallError!usize {
    _ = flags; // Flags ignored for MVP (MSG_DONTWAIT, MSG_NOSIGNAL, etc.)

    const ctx = getSocketContext(fd, socket_file_ops) orelse {
        return error.ENOTSOCK;
    };

    // Read msghdr from userspace
    const msg = user_mem.copyStructFromUser(MsgHdr, user_mem.UserPtr.from(msg_ptr)) catch {
        return error.EFAULT;
    };

    // Validate iovec count
    if (msg.msg_iovlen == 0) {
        return 0; // Nothing to send
    }
    if (msg.msg_iovlen > MAX_IOV_COUNT) {
        return error.EMSGSIZE;
    }

    // Validate iovec array pointer
    const iov_size = msg.msg_iovlen * @sizeOf(IoVec);
    if (!isValidUserAccess(msg.msg_iov, iov_size, AccessMode.Read)) {
        return error.EFAULT;
    }

    // Copy iovec array to kernel
    const iovecs = heap.allocator().alloc(IoVec, msg.msg_iovlen) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(iovecs);

    const iov_uptr = user_mem.UserPtr.from(msg.msg_iov);
    _ = iov_uptr.copyToKernel(std.mem.sliceAsBytes(iovecs)) catch {
        return error.EFAULT;
    };

    // Calculate total message size and validate
    // SECURITY: Use checked arithmetic to prevent underflow in ReleaseFast (CWE-190)
    var total_len: usize = 0;
    for (iovecs) |iov| {
        total_len = std.math.add(usize, total_len, iov.iov_len) catch return error.EMSGSIZE;
        if (total_len > MAX_MSG_SIZE) {
            return error.EMSGSIZE;
        }
    }

    if (total_len == 0) {
        return 0;
    }

    // Allocate kernel buffer and gather data from iovecs
    const kbuf = heap.allocator().alloc(u8, total_len) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    var offset: usize = 0;
    for (iovecs) |iov| {
        if (iov.iov_len == 0) continue;

        if (!isValidUserAccess(iov.iov_base, iov.iov_len, AccessMode.Read)) {
            return error.EFAULT;
        }

        const iov_uptr_base = user_mem.UserPtr.from(iov.iov_base);
        _ = iov_uptr_base.copyToKernel(kbuf[offset .. offset + iov.iov_len]) catch {
            return error.EFAULT;
        };
        offset += iov.iov_len;
    }

    // Handle optional destination address
    var kdest_addr: ?socket.SockAddrIn = null;
    if (msg.msg_name != 0 and msg.msg_namelen >= @sizeOf(socket.SockAddrIn)) {
        kdest_addr = user_mem.copyStructFromUser(socket.SockAddrIn, user_mem.UserPtr.from(msg.msg_name)) catch {
            return error.EFAULT;
        };
    }

    // Send the message
    if (kdest_addr) |*addr| {
        // UDP-style send with destination address
        const sent = socket.sendto(ctx.socket_idx, kbuf, addr) catch |err| {
            return socketErrorToSyscallError(err);
        };
        return sent;
    } else {
        // TCP-style send (connected socket)
        const sock = socket.getSocket(ctx.socket_idx) orelse {
            return error.EBADF;
        };

        if (sock.sock_type == socket.SOCK_STREAM) {
            const sent = socket.tcpSend(ctx.socket_idx, kbuf) catch |err| {
                return socketErrorToSyscallError(err);
            };
            return sent;
        } else {
            // UDP without destination requires prior connect()
            return error.EDESTADDRREQ;
        }
    }
}

/// sys_recvmsg (47) - Receive a message from a socket with scatter/gather I/O
/// (fd, msg_ptr, flags) -> ssize_t
///
/// Receives data and scatters it into multiple user buffers (iovecs).
/// SECURITY: Data is received into kernel buffer then copied to user to prevent TOCTOU.
pub fn sys_recvmsg(fd: usize, msg_ptr: usize, flags: usize, socket_file_ops: *const fd_mod.FileOps) SyscallError!usize {
    _ = flags; // Flags ignored for MVP (MSG_PEEK, MSG_WAITALL, etc.)

    const ctx = getSocketContext(fd, socket_file_ops) orelse {
        return error.ENOTSOCK;
    };

    // Read msghdr from userspace
    var msg = user_mem.copyStructFromUser(MsgHdr, user_mem.UserPtr.from(msg_ptr)) catch {
        return error.EFAULT;
    };

    // Validate iovec count
    if (msg.msg_iovlen == 0) {
        return 0; // Nothing to receive into
    }
    if (msg.msg_iovlen > MAX_IOV_COUNT) {
        return error.EMSGSIZE;
    }

    // Validate iovec array pointer
    const iov_size = msg.msg_iovlen * @sizeOf(IoVec);
    if (!isValidUserAccess(msg.msg_iov, iov_size, AccessMode.Read)) {
        return error.EFAULT;
    }

    // Copy iovec array to kernel
    const iovecs = heap.allocator().alloc(IoVec, msg.msg_iovlen) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(iovecs);

    const iov_uptr = user_mem.UserPtr.from(msg.msg_iov);
    _ = iov_uptr.copyToKernel(std.mem.sliceAsBytes(iovecs)) catch {
        return error.EFAULT;
    };

    // Calculate total buffer size and validate write access
    // SECURITY: Use checked arithmetic to prevent underflow in ReleaseFast (CWE-190)
    var total_len: usize = 0;
    for (iovecs) |iov| {
        total_len = std.math.add(usize, total_len, iov.iov_len) catch return error.EMSGSIZE;
        if (total_len > MAX_MSG_SIZE) {
            return error.EMSGSIZE;
        }

        // Validate each iovec buffer for write access
        if (iov.iov_len > 0 and !isValidUserAccess(iov.iov_base, iov.iov_len, AccessMode.Write)) {
            return error.EFAULT;
        }
    }

    if (total_len == 0) {
        return 0;
    }

    // Allocate kernel receive buffer
    const recv_len = @min(total_len, MAX_MSG_SIZE);
    const kbuf = heap.allocator().alloc(u8, recv_len) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    // Prepare for source address if requested
    // SECURITY: Zero-init to prevent kernel stack leak if tcpRecv path doesn't fill it
    var ksrc_addr: socket.SockAddrIn = std.mem.zeroes(socket.SockAddrIn);
    const src_addr_arg: ?*socket.SockAddrIn = if (msg.msg_name != 0) &ksrc_addr else null;

    // Receive data
    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    var received: usize = 0;
    if (sock.sock_type == socket.SOCK_STREAM) {
        received = socket.tcpRecv(ctx.socket_idx, kbuf) catch |err| {
            return socketErrorToSyscallError(err);
        };
    } else {
        received = socket.recvfrom(ctx.socket_idx, kbuf, src_addr_arg) catch |err| {
            return socketErrorToSyscallError(err);
        };
    }

    // Scatter received data into user iovecs
    var bytes_remaining = received;
    var iov_idx: usize = 0;
    var buf_offset: usize = 0;

    while (bytes_remaining > 0 and iov_idx < iovecs.len) {
        const iov = iovecs[iov_idx];
        if (iov.iov_len == 0) {
            iov_idx += 1;
            continue;
        }

        const copy_len = @min(bytes_remaining, iov.iov_len);
        const iov_uptr_base = user_mem.UserPtr.from(iov.iov_base);
        _ = iov_uptr_base.copyFromKernel(kbuf[buf_offset .. buf_offset + copy_len]) catch {
            return error.EFAULT;
        };

        buf_offset += copy_len;
        bytes_remaining -= copy_len;
        iov_idx += 1;
    }

    // Copy source address back to user if requested
    if (msg.msg_name != 0 and msg.msg_namelen >= @sizeOf(socket.SockAddrIn) and src_addr_arg != null) {
        user_mem.copyStructToUser(socket.SockAddrIn, user_mem.UserPtr.from(msg.msg_name), ksrc_addr) catch {
            return error.EFAULT;
        };

        // Update msg_namelen in userspace
        msg.msg_namelen = @sizeOf(socket.SockAddrIn);
    } else {
        msg.msg_namelen = 0;
    }

    // Clear msg_controllen (ancillary data not implemented)
    msg.msg_controllen = 0;
    msg.msg_flags = 0;

    // Write updated msghdr back to userspace
    user_mem.copyStructToUser(MsgHdr, user_mem.UserPtr.from(msg_ptr), msg) catch {
        return error.EFAULT;
    };

    return received;
}
