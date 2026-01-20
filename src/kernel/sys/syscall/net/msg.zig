//! Scatter/Gather I/O Syscalls (sendmsg/recvmsg)
//!
//! Implements sys_sendmsg and sys_recvmsg for advanced socket I/O.
//! Extracted from net.zig for better maintainability.
//!
//! SCM_RIGHTS Support:
//! File descriptors can be passed between processes using UNIX domain sockets
//! via ancillary data (control messages). This module handles:
//! - sendmsg: Extracting FD numbers from cmsg, incrementing refs, queuing for receiver
//! - recvmsg: Dequeuing FDs, allocating new FD numbers in receiver, building cmsg response

const std = @import("std");
const uapi = @import("uapi");
const net = @import("net");
const socket = net.transport.socket;
const unix_socket = socket.unix_socket;
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const heap = @import("heap");
const base = @import("base.zig");
const fd_mod = @import("fd");
const sched = @import("sched");
const thread = @import("thread");
const Thread = thread.Thread;

const isValidUserAccess = user_mem.isValidUserAccess;
const AccessMode = user_mem.AccessMode;

const IoVec = uapi.abi.IoVec;
const MsgHdr = uapi.abi.MsgHdr;
const CmsgHdr = uapi.abi.CmsgHdr;

/// Maximum number of iovecs to prevent excessive kernel allocations
const MAX_IOV_COUNT: usize = 1024;

/// Maximum total message size for sendmsg/recvmsg
const MAX_MSG_SIZE: usize = 65536;

/// Maximum control message buffer size (enough for MAX_SCM_RIGHTS_FDS)
const MAX_CONTROL_SIZE: usize = uapi.abi.CMSG_SPACE(unix_socket.MAX_SCM_RIGHTS_FDS * @sizeOf(i32));

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

// =============================================================================
// SCM_RIGHTS Processing for UNIX Domain Sockets
// =============================================================================

/// Result of processing SCM_RIGHTS control message
const ScmRightsResult = struct {
    fds: [unix_socket.MAX_SCM_RIGHTS_FDS]*fd_mod.FileDescriptor,
    count: usize,
};

/// Process SCM_RIGHTS control message from sendmsg
/// Extracts FD numbers, validates them, and increments refcounts
///
/// SECURITY: This follows TOCTOU-safe pattern:
/// 1. Copy control data to kernel buffer
/// 2. Under FdTable lock: validate each FD, call ref() to increment refcount
/// 3. Return array of FileDescriptor pointers (caller holds refs)
///
/// Lock ordering: FdTable.lock is acquired and released here, BEFORE socket.lock
fn processScmRights(
    msg_control: usize,
    msg_controllen: usize,
    table: *fd_mod.FdTable,
) SyscallError!?ScmRightsResult {
    // No control data
    if (msg_control == 0 or msg_controllen == 0) {
        return null;
    }

    // Validate control buffer size
    if (msg_controllen > MAX_CONTROL_SIZE) {
        return error.EINVAL;
    }

    // Validate user access
    if (!isValidUserAccess(msg_control, msg_controllen, AccessMode.Read)) {
        return error.EFAULT;
    }

    // SECURITY: Zero-init kernel buffer to prevent info leaks
    var kcontrol: [MAX_CONTROL_SIZE]u8 = [_]u8{0} ** MAX_CONTROL_SIZE;

    // Copy control buffer to kernel
    const uptr = user_mem.UserPtr.from(msg_control);
    _ = uptr.copyToKernel(kcontrol[0..msg_controllen]) catch {
        return error.EFAULT;
    };

    // Parse control message header
    if (msg_controllen < @sizeOf(CmsgHdr)) {
        return error.EINVAL;
    }

    const cmsg: *const CmsgHdr = @ptrCast(@alignCast(&kcontrol));

    // Validate header
    if (cmsg.cmsg_level != uapi.abi.SOL_SOCKET or cmsg.cmsg_type != uapi.abi.SCM_RIGHTS) {
        // Not SCM_RIGHTS - ignore (MVP: only support SCM_RIGHTS)
        return null;
    }

    // Calculate data length
    if (cmsg.cmsg_len < @sizeOf(CmsgHdr)) {
        return error.EINVAL;
    }
    const data_len = cmsg.cmsg_len - @sizeOf(CmsgHdr);

    // Validate data is array of i32 FD numbers
    if (data_len == 0 or (data_len % @sizeOf(i32)) != 0) {
        return error.EINVAL;
    }

    const fd_count = data_len / @sizeOf(i32);
    if (fd_count > unix_socket.MAX_SCM_RIGHTS_FDS) {
        return error.EINVAL;
    }

    // Get pointer to FD array in control data
    const fd_array: [*]const i32 = @ptrCast(@alignCast(&kcontrol[@sizeOf(CmsgHdr)]));

    var result = ScmRightsResult{
        .fds = undefined,
        .count = 0,
    };

    // SECURITY: Acquire FdTable lock for the entire validation+ref operation
    // This prevents TOCTOU where an FD could be closed between validation and ref
    const held = table.lock.acquire();
    defer held.release();

    // Validate each FD and increment refcount
    var i: usize = 0;
    while (i < fd_count) : (i += 1) {
        const fd_num = fd_array[i];
        if (fd_num < 0) {
            // Rollback refs already acquired
            for (result.fds[0..result.count]) |fd| {
                _ = fd.unref();
            }
            return error.EBADF;
        }

        const fd_u32: u32 = @intCast(fd_num);
        if (fd_u32 >= fd_mod.MAX_FDS) {
            // Rollback
            for (result.fds[0..result.count]) |fd| {
                _ = fd.unref();
            }
            return error.EBADF;
        }

        const fd = table.fds[fd_u32] orelse {
            // Rollback
            for (result.fds[0..result.count]) |fd_ref| {
                _ = fd_ref.unref();
            }
            return error.EBADF;
        };

        // Increment refcount (sender's ref is preserved, we add a new ref for transport)
        fd.ref();
        result.fds[result.count] = fd;
        result.count += 1;
    }

    return result;
}

/// Result of processing SCM_CREDENTIALS control message
const ScmCredentialsResult = struct {
    pid: u32,
    uid: u32,
    gid: u32,
};

/// Process SCM_CREDENTIALS control message from sendmsg
/// Extracts and validates credentials
///
/// SECURITY: Non-root can only send their own credentials (pid, euid, egid)
/// Root (uid == 0) can send arbitrary credentials
fn processScmCredentials(
    msg_control: usize,
    msg_controllen: usize,
) SyscallError!?ScmCredentialsResult {
    // No control data
    if (msg_control == 0 or msg_controllen == 0) {
        return null;
    }

    // Validate control buffer size
    if (msg_controllen > MAX_CONTROL_SIZE) {
        return error.EINVAL;
    }

    // Validate user access
    if (!isValidUserAccess(msg_control, msg_controllen, AccessMode.Read)) {
        return error.EFAULT;
    }

    // SECURITY: Zero-init kernel buffer to prevent info leaks
    var kcontrol: [MAX_CONTROL_SIZE]u8 = [_]u8{0} ** MAX_CONTROL_SIZE;

    // Copy control buffer to kernel
    const uptr = user_mem.UserPtr.from(msg_control);
    _ = uptr.copyToKernel(kcontrol[0..msg_controllen]) catch {
        return error.EFAULT;
    };

    // Parse control message header
    if (msg_controllen < @sizeOf(CmsgHdr)) {
        return error.EINVAL;
    }

    const cmsg: *const CmsgHdr = @ptrCast(@alignCast(&kcontrol));

    // Check for SCM_CREDENTIALS
    if (cmsg.cmsg_level != uapi.abi.SOL_SOCKET or cmsg.cmsg_type != uapi.abi.SCM_CREDENTIALS) {
        return null;
    }

    // Calculate data length
    if (cmsg.cmsg_len < @sizeOf(CmsgHdr)) {
        return error.EINVAL;
    }
    const data_len = cmsg.cmsg_len - @sizeOf(CmsgHdr);

    // Validate data is a UCred struct (12 bytes: pid + uid + gid)
    if (data_len != @sizeOf(uapi.abi.UCred)) {
        return error.EINVAL;
    }

    // Get pointer to UCred in control data
    const ucred: *const uapi.abi.UCred = @ptrCast(@alignCast(&kcontrol[@sizeOf(CmsgHdr)]));

    // SECURITY: Validate credentials
    const proc = base.getCurrentProcess();

    // Non-root users can only send their own credentials
    if (proc.euid != 0) {
        if (ucred.pid != proc.pid or ucred.uid != proc.euid or ucred.gid != proc.egid) {
            return error.EPERM;
        }
    }
    // Root can send any credentials

    return ScmCredentialsResult{
        .pid = ucred.pid,
        .uid = ucred.uid,
        .gid = ucred.gid,
    };
}

/// Release FD refs acquired by processScmRights on error
fn releaseScmRightsFds(fds: []const *fd_mod.FileDescriptor) void {
    for (fds) |fd| {
        releaseSingleFd(fd);
    }
}

/// Release a single FD ref - used as callback for unix_socket PendingAncillary
fn releaseSingleFd(fd_opaque: *anyopaque) void {
    const fd: *fd_mod.FileDescriptor = @ptrCast(@alignCast(fd_opaque));
    if (fd.unref()) {
        if (fd.ops.close) |close_fn| {
            _ = close_fn(fd);
        }
        heap.allocator().destroy(fd);
    }
}

/// Context for UNIX socket sendmsg operations
const UnixSendContext = struct {
    pair: *unix_socket.UnixSocketPair,
    endpoint: u1,
};

/// Get UNIX socket context from FD (for both socketpair and full sockets)
fn getUnixSocketContext(
    fd_num: usize,
    unix_socket_ops: *const fd_mod.FileOps,
    unix_socket_full_ops: *const fd_mod.FileOps,
) ?UnixSendContext {
    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, fd_num) orelse return null;
    const fd = table.get(fd_u32) orelse return null;

    // Check socketpair-created sockets
    if (fd.ops == unix_socket_ops) {
        const handle: *unix_socket.UnixSocketHandle = @ptrCast(@alignCast(fd.private_data orelse return null));
        return UnixSendContext{
            .pair = handle.pair,
            .endpoint = handle.endpoint,
        };
    }

    // Check socket(AF_UNIX)-created sockets
    if (fd.ops == unix_socket_full_ops) {
        // Full UNIX socket FD data structure
        const UnixSocketFullFdData = struct {
            socket_idx: usize,
            generation: u32,
        };
        const data: *UnixSocketFullFdData = @ptrCast(@alignCast(fd.private_data orelse return null));
        const sock = unix_socket.getSocketByIdx(data.socket_idx) orelse return null;
        if (sock.generation != data.generation) return null;
        if (sock.state != .Connected) return null;
        const pair = sock.pair orelse return null;
        return UnixSendContext{
            .pair = pair,
            .endpoint = sock.endpoint,
        };
    }

    return null;
}

/// sys_sendmsg (46) - Send a message on a socket with scatter/gather I/O
/// (fd, msg_ptr, flags) -> ssize_t
///
/// Gathers data from multiple user buffers (iovecs) and sends as single message.
/// Supports SCM_RIGHTS ancillary data for passing file descriptors over UNIX sockets.
/// SECURITY: All user data is copied to kernel buffers to prevent TOCTOU.
pub fn sys_sendmsg(
    fd: usize,
    msg_ptr: usize,
    flags: usize,
    socket_file_ops: *const fd_mod.FileOps,
    unix_socket_ops: *const fd_mod.FileOps,
    unix_socket_full_ops: *const fd_mod.FileOps,
) SyscallError!usize {
    _ = flags; // Flags ignored for MVP (MSG_DONTWAIT, MSG_NOSIGNAL, etc.)

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

    // Check if this is a UNIX domain socket (for SCM_RIGHTS support)
    if (getUnixSocketContext(fd, unix_socket_ops, unix_socket_full_ops)) |unix_ctx| {
        return sendmsgUnix(unix_ctx, kbuf, msg.msg_control, msg.msg_controllen);
    }

    // Network socket path
    const ctx = getSocketContext(fd, socket_file_ops) orelse {
        return error.ENOTSOCK;
    };

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

/// Send message on UNIX domain socket with SCM_RIGHTS and SCM_CREDENTIALS support
fn sendmsgUnix(
    ctx: UnixSendContext,
    data: []const u8,
    msg_control: usize,
    msg_controllen: usize,
) SyscallError!usize {
    // Process ancillary data BEFORE acquiring socket lock (lock ordering)
    var scm_rights: ?ScmRightsResult = null;
    var scm_creds: ?ScmCredentialsResult = null;

    if (msg_control != 0 and msg_controllen > 0) {
        // Try processing as SCM_RIGHTS first
        const table = base.getGlobalFdTable();
        scm_rights = try processScmRights(msg_control, msg_controllen, table);

        // If not SCM_RIGHTS, try SCM_CREDENTIALS
        if (scm_rights == null) {
            scm_creds = try processScmCredentials(msg_control, msg_controllen);
        }
    }

    // If we got FDs to pass, we need to clean them up on error
    errdefer {
        if (scm_rights) |*rights| {
            releaseScmRightsFds(rights.fds[0..rights.count]);
        }
    }

    // Acquire socket pair lock
    const held = ctx.pair.lock.acquire();

    // Check if peer is closed
    if (ctx.pair.isPeerClosed(ctx.endpoint)) {
        held.release();
        return error.EPIPE;
    }

    // Write data to circular buffer (using appropriate method based on socket type)
    var write_offset: usize = 0;
    var written: usize = 0;

    const is_dgram = (ctx.pair.sock_type & 0xFF) == socket.SOCK_DGRAM;

    if (is_dgram) {
        // SOCK_DGRAM: Use message boundary tracking
        const result = ctx.pair.writeDgram(ctx.endpoint, data) orelse {
            held.release();
            // Check if message ring full vs buffer full for appropriate error
            if (!ctx.pair.canWriteDgram(ctx.endpoint)) {
                return error.EAGAIN; // Message ring full
            }
            return error.EMSGSIZE; // Message too large for buffer
        };
        write_offset = result.offset;
        written = result.written;
    } else {
        // SOCK_STREAM: Stream semantics (partial writes allowed)
        write_offset = if (ctx.endpoint == 0)
            ctx.pair.write_pos_0_to_1
        else
            ctx.pair.write_pos_1_to_0;

        written = ctx.pair.write(ctx.endpoint, data);

        if (written == 0) {
            held.release();
            return error.EAGAIN;
        }
    }

    // Queue SCM_RIGHTS ancillary data if present
    if (scm_rights) |*rights| {
        // Convert FileDescriptor pointers to opaque pointers for the socket layer
        var opaque_fds: [unix_socket.MAX_SCM_RIGHTS_FDS]*anyopaque = undefined;
        for (rights.fds[0..rights.count], 0..) |fd, i| {
            opaque_fds[i] = fd;
        }

        unix_socket.queueAncillary(
            ctx.pair,
            ctx.endpoint,
            opaque_fds[0..rights.count],
            write_offset,
            written,
            &releaseSingleFd,
        ) catch {
            // Queue full - release FD refs and return error
            // Note: Data was already written, but no FDs will be received
            held.release();
            releaseScmRightsFds(rights.fds[0..rights.count]);
            return error.EAGAIN;
        };
        // FDs successfully queued - ownership transferred, don't release refs
        scm_rights = null;
    }

    // Queue SCM_CREDENTIALS ancillary data if present
    if (scm_creds) |creds| {
        unix_socket.queueCredentials(
            ctx.pair,
            ctx.endpoint,
            creds.pid,
            creds.uid,
            creds.gid,
            write_offset,
            written,
        ) catch {
            // Queue full - credentials won't be received, but data still sent
            // This is non-fatal for credentials (unlike FDs)
        };
    }

    // Wake blocked reader on peer endpoint
    if (ctx.endpoint == 0) {
        if (ctx.pair.blocked_reader_1) |t| {
            ctx.pair.reader_1_woken.store(true, .release);
            held.release();
            // Cast from ?*anyopaque back to *Thread for sched.unblock
            const t_ptr: *Thread = @ptrCast(@alignCast(t));
            sched.unblock(t_ptr);
            return written;
        }
    } else {
        if (ctx.pair.blocked_reader_0) |t| {
            ctx.pair.reader_0_woken.store(true, .release);
            held.release();
            const t_ptr: *Thread = @ptrCast(@alignCast(t));
            sched.unblock(t_ptr);
            return written;
        }
    }

    held.release();
    return written;
}

/// sys_recvmsg (47) - Receive a message from a socket with scatter/gather I/O
/// (fd, msg_ptr, flags) -> ssize_t
///
/// Receives data and scatters it into multiple user buffers (iovecs).
/// Supports SCM_RIGHTS ancillary data for receiving file descriptors over UNIX sockets.
/// SECURITY: Data is received into kernel buffer then copied to user to prevent TOCTOU.
pub fn sys_recvmsg(
    fd: usize,
    msg_ptr: usize,
    flags: usize,
    socket_file_ops: *const fd_mod.FileOps,
    unix_socket_ops: *const fd_mod.FileOps,
    unix_socket_full_ops: *const fd_mod.FileOps,
) SyscallError!usize {
    _ = flags; // Flags ignored for MVP (MSG_PEEK, MSG_WAITALL, etc.)

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

    // Check if this is a UNIX domain socket (for SCM_RIGHTS support)
    if (getUnixSocketContext(fd, unix_socket_ops, unix_socket_full_ops)) |unix_ctx| {
        return recvmsgUnix(unix_ctx, iovecs, msg_ptr, msg.msg_control, msg.msg_controllen);
    }

    // Network socket path
    const ctx = getSocketContext(fd, socket_file_ops) orelse {
        return error.ENOTSOCK;
    };

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

    // Clear msg_controllen (ancillary data not supported for network sockets)
    msg.msg_controllen = 0;
    msg.msg_flags = 0;

    // Write updated msghdr back to userspace
    user_mem.copyStructToUser(MsgHdr, user_mem.UserPtr.from(msg_ptr), msg) catch {
        return error.EFAULT;
    };

    return received;
}

/// Receive message from UNIX domain socket with SCM_RIGHTS support
fn recvmsgUnix(
    ctx: UnixSendContext,
    iovecs: []const IoVec,
    msg_ptr: usize,
    msg_control: usize,
    msg_controllen: usize,
) SyscallError!usize {
    // Calculate total buffer size
    var total_len: usize = 0;
    for (iovecs) |iov| {
        total_len = std.math.add(usize, total_len, iov.iov_len) catch return error.EMSGSIZE;
    }

    // Acquire socket pair lock
    const held = ctx.pair.lock.acquire();

    const is_dgram = (ctx.pair.sock_type & 0xFF) == socket.SOCK_DGRAM;

    // Check for data or peer closed (use appropriate check for socket type)
    const has_data = if (is_dgram) ctx.pair.hasDgram(ctx.endpoint) else ctx.pair.hasData(ctx.endpoint);
    const peer_closed = ctx.pair.isPeerClosed(ctx.endpoint);

    if (!has_data) {
        if (peer_closed) {
            held.release();
            return 0; // EOF
        }
        held.release();
        return error.EAGAIN;
    }

    // Read data into temporary buffer (using appropriate method based on socket type)
    const recv_len = @min(total_len, MAX_MSG_SIZE);
    const kbuf = heap.allocator().alloc(u8, recv_len) catch {
        held.release();
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    var read_offset: usize = 0;
    var received: usize = 0;
    var msg_truncated = false;

    if (is_dgram) {
        // SOCK_DGRAM: Read exactly one message, discard remainder if buffer too small
        const result = ctx.pair.readDgram(ctx.endpoint, kbuf) orelse {
            held.release();
            return error.EAGAIN;
        };
        read_offset = result.offset;
        received = result.copied;
        // Check if message was truncated (datagram semantics)
        if (result.msg_len > result.copied) {
            msg_truncated = true;
        }
    } else {
        // SOCK_STREAM: Stream semantics (read as much as available)
        read_offset = if (ctx.endpoint == 0)
            ctx.pair.read_pos_1_to_0
        else
            ctx.pair.read_pos_0_to_1;

        received = ctx.pair.read(ctx.endpoint, kbuf);
    }

    // Check for ancillary data at this read position
    const maybe_anc = unix_socket.dequeueAncillary(ctx.pair, ctx.endpoint, read_offset);
    const maybe_creds = unix_socket.dequeueCredentials(ctx.pair, ctx.endpoint, read_offset);

    held.release();

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
            // If we fail to copy data, we need to release any pending FD refs
            if (maybe_anc) |anc| {
                // Release FD refs using the stored release callback
                const held2 = ctx.pair.lock.acquire();
                anc.releaseAll(); // This uses the callback to properly release refs
                unix_socket.consumeAncillary(ctx.pair, ctx.endpoint, anc);
                held2.release();
            }
            return error.EFAULT;
        };

        buf_offset += copy_len;
        bytes_remaining -= copy_len;
        iov_idx += 1;
    }

    // Process ancillary data if present
    var msg_flags: i32 = 0;
    var actual_controllen: usize = 0;

    // Set MSG_TRUNC if datagram was truncated
    if (msg_truncated) {
        msg_flags |= uapi.abi.MSG_TRUNC;
    }

    // Handle SCM_RIGHTS (FD passing)
    if (maybe_anc) |anc| {
        // Convert opaque pointers back to FileDescriptor pointers
        var fd_ptrs: [unix_socket.MAX_SCM_RIGHTS_FDS]*fd_mod.FileDescriptor = undefined;
        for (anc.fds[0..anc.fd_count], 0..) |opaque_ptr, i| {
            fd_ptrs[i] = @ptrCast(@alignCast(opaque_ptr));
        }

        // Install received FDs in receiver's FD table
        const install_result = installReceivedFds(fd_ptrs[0..anc.fd_count]);

        // Mark ancillary data as consumed (clears release_fn so releaseAll won't double-free)
        const held2 = ctx.pair.lock.acquire();
        unix_socket.consumeAncillary(ctx.pair, ctx.endpoint, anc);
        held2.release();

        if (install_result) |new_fds| {
            // Build control message response
            actual_controllen = try buildScmRightsResponse(
                new_fds.fds[0..new_fds.count],
                msg_control,
                msg_controllen,
                &msg_flags,
            );
        } else |_| {
            // FD installation failed - data was still delivered
            // Set MSG_CTRUNC to indicate control data was lost
            msg_flags |= uapi.abi.MSG_CTRUNC;
        }
    }

    // Handle SCM_CREDENTIALS
    if (maybe_creds) |creds| {
        // Only process credentials if we haven't already filled control buffer with FDs
        if (actual_controllen == 0) {
            actual_controllen = try buildScmCredentialsResponse(
                creds,
                msg_control,
                msg_controllen,
                &msg_flags,
            );
        }

        // Mark credentials as consumed
        const held2 = ctx.pair.lock.acquire();
        unix_socket.consumeCredentials(ctx.pair, ctx.endpoint, creds);
        held2.release();
    }

    // Update msghdr in userspace
    var msg = user_mem.copyStructFromUser(MsgHdr, user_mem.UserPtr.from(msg_ptr)) catch {
        return error.EFAULT;
    };

    msg.msg_namelen = 0; // UNIX sockets don't have source address in recvmsg
    msg.msg_controllen = actual_controllen;
    msg.msg_flags = msg_flags;

    user_mem.copyStructToUser(MsgHdr, user_mem.UserPtr.from(msg_ptr), msg) catch {
        return error.EFAULT;
    };

    return received;
}

/// Result of installing received FDs
const InstallFdsResult = struct {
    fds: [unix_socket.MAX_SCM_RIGHTS_FDS]i32,
    count: usize,
};

/// Install received FDs into the current process's FD table
/// The FDs in received_fds already have their refs incremented by the sender
/// This function transfers ownership - no additional ref needed
fn installReceivedFds(
    received_fds: []const *fd_mod.FileDescriptor,
) error{FdTableFull}!InstallFdsResult {
    const table = base.getGlobalFdTable();
    var result = InstallFdsResult{
        .fds = undefined,
        .count = 0,
    };

    // Acquire FD table lock for atomic allocation
    const held = table.lock.acquire();
    defer held.release();

    // Allocate FD numbers and install
    for (received_fds) |fd| {
        // Find free slot
        var fd_num: ?u32 = null;
        for (table.fds, 0..) |existing, i| {
            if (existing == null) {
                fd_num = @intCast(i);
                break;
            }
        }

        if (fd_num) |num| {
            table.fds[num] = fd;
            table.count += 1;
            result.fds[result.count] = @intCast(num);
            result.count += 1;
        } else {
            // FD table full - rollback already installed FDs
            for (result.fds[0..result.count]) |installed_fd| {
                const installed_u32: u32 = @intCast(installed_fd);
                if (table.fds[installed_u32]) |fd_to_remove| {
                    table.fds[installed_u32] = null;
                    table.count -= 1;
                    // Decrement ref (we held the transport ref)
                    _ = fd_to_remove.unref();
                }
            }
            // Also release refs for FDs we didn't install
            for (received_fds[result.count..]) |remaining_fd| {
                _ = remaining_fd.unref();
            }
            return error.FdTableFull;
        }
    }

    return result;
}

/// Build SCM_RIGHTS control message response for user
/// Returns actual bytes written to control buffer
fn buildScmRightsResponse(
    new_fds: []const i32,
    msg_control: usize,
    msg_controllen: usize,
    msg_flags: *i32,
) SyscallError!usize {
    if (msg_control == 0 or msg_controllen == 0 or new_fds.len == 0) {
        return 0;
    }

    // Calculate required space
    const fd_data_len = new_fds.len * @sizeOf(i32);
    const required_len = uapi.abi.CMSG_SPACE(fd_data_len);

    // Check if user buffer is large enough
    if (msg_controllen < required_len) {
        // Buffer too small - set MSG_CTRUNC flag
        msg_flags.* |= uapi.abi.MSG_CTRUNC;

        // If can't even fit the header, return 0
        if (msg_controllen < @sizeOf(CmsgHdr)) {
            return 0;
        }
    }

    // Validate user buffer access
    const write_len = @min(msg_controllen, required_len);
    if (!isValidUserAccess(msg_control, write_len, AccessMode.Write)) {
        return error.EFAULT;
    }

    // Build control message in kernel buffer
    // SECURITY: Zero-init to prevent kernel stack leak
    var kcontrol: [MAX_CONTROL_SIZE]u8 = [_]u8{0} ** MAX_CONTROL_SIZE;

    const cmsg: *CmsgHdr = @ptrCast(@alignCast(&kcontrol));
    cmsg.cmsg_len = uapi.abi.CMSG_LEN(fd_data_len);
    cmsg.cmsg_level = uapi.abi.SOL_SOCKET;
    cmsg.cmsg_type = uapi.abi.SCM_RIGHTS;

    // Copy FD numbers to data portion
    const fd_data: [*]i32 = @ptrCast(@alignCast(&kcontrol[@sizeOf(CmsgHdr)]));
    for (new_fds, 0..) |fd_num, i| {
        fd_data[i] = fd_num;
    }

    // Copy to user space
    const uptr = user_mem.UserPtr.from(msg_control);
    _ = uptr.copyFromKernel(kcontrol[0..write_len]) catch {
        return error.EFAULT;
    };

    return write_len;
}

/// Build SCM_CREDENTIALS control message response for user
/// Returns actual bytes written to control buffer
fn buildScmCredentialsResponse(
    creds: *const unix_socket.PendingCredentials,
    msg_control: usize,
    msg_controllen: usize,
    msg_flags: *i32,
) SyscallError!usize {
    if (msg_control == 0 or msg_controllen == 0) {
        return 0;
    }

    // Calculate required space (UCred is 12 bytes)
    const cred_data_len = @sizeOf(uapi.abi.UCred);
    const required_len = uapi.abi.CMSG_SPACE(cred_data_len);

    // Check if user buffer is large enough
    if (msg_controllen < required_len) {
        // Buffer too small - set MSG_CTRUNC flag
        msg_flags.* |= uapi.abi.MSG_CTRUNC;

        // If can't even fit the header, return 0
        if (msg_controllen < @sizeOf(CmsgHdr)) {
            return 0;
        }
    }

    // Validate user buffer access
    const write_len = @min(msg_controllen, required_len);
    if (!isValidUserAccess(msg_control, write_len, AccessMode.Write)) {
        return error.EFAULT;
    }

    // Build control message in kernel buffer
    // SECURITY: Zero-init to prevent kernel stack leak
    var kcontrol: [MAX_CONTROL_SIZE]u8 = [_]u8{0} ** MAX_CONTROL_SIZE;

    const cmsg: *CmsgHdr = @ptrCast(@alignCast(&kcontrol));
    cmsg.cmsg_len = uapi.abi.CMSG_LEN(cred_data_len);
    cmsg.cmsg_level = uapi.abi.SOL_SOCKET;
    cmsg.cmsg_type = uapi.abi.SCM_CREDENTIALS;

    // Copy credentials to data portion
    const ucred: *uapi.abi.UCred = @ptrCast(@alignCast(&kcontrol[@sizeOf(CmsgHdr)]));
    ucred.pid = creds.pid;
    ucred.uid = creds.uid;
    ucred.gid = creds.gid;

    // Copy to user space
    const uptr = user_mem.UserPtr.from(msg_control);
    _ = uptr.copyFromKernel(kcontrol[0..write_len]) catch {
        return error.EFAULT;
    };

    return write_len;
}
