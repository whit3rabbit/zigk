// Network Syscall Handlers
//
// Implements socket-related syscalls for userland networking.
// Uses the kernel's socket layer to provide BSD-style socket API.
// Integrates with scheduler for blocking I/O operations.

const std = @import("std");
const uapi = @import("uapi");
const net = @import("net");
const socket = net.transport.socket;
const Errno = uapi.errno.Errno;
const SyscallError = uapi.errno.SyscallError;
const sched = @import("sched");
const hal = @import("hal");
const thread = @import("thread");
const Thread = thread.Thread;
const user_mem = @import("user_mem");
const fd_mod = @import("fd");
const heap = @import("heap");
const base = @import("base.zig");

// Import extracted modules
const poll_mod = @import("poll.zig");
const msg_mod = @import("msg.zig");

// Re-export helper functions for external use
pub const hasPendingSignal = poll_mod.hasPendingSignal;
pub const pollTimeoutToTicks = poll_mod.pollTimeoutToTicks;

/// Wake function for blocked threads - called from TCP/socket layer
fn wakeBlockedThread(opaque_thread: ?*anyopaque) void {
    if (opaque_thread) |ptr| {
        const t: *Thread = @ptrCast(@alignCast(ptr));
        sched.unblock(t);
    }
}

/// Block the current thread - called from socket layer for blocking I/O
fn blockCurrentThread() void {
    sched.block();
}

/// Get current thread pointer - called from socket layer
fn getCurrentThread() ?*anyopaque {
    const t = sched.getCurrentThread() orelse return null;
    return @ptrCast(t);
}

/// Initialize network syscall layer (called once at boot)
/// Sets up scheduler integration for blocking socket I/O
var initialized: bool = false;

pub fn init() void {
    if (!initialized) {
        socket.setSchedulerFunctions(wakeBlockedThread, blockCurrentThread, getCurrentThread);
        initialized = true;
    }
}

// Use consolidated user pointer validation with permission checking
const isValidUserAccess = user_mem.isValidUserAccess;
const AccessMode = user_mem.AccessMode;

const FileDescriptor = fd_mod.FileDescriptor;

// =============================================================================
// Socket FD Management
// =============================================================================

const SocketFdData = struct {
    socket_idx: usize,
};

const socket_file_ops = fd_mod.FileOps{
    .read = socketRead,
    .write = socketWrite,
    .close = socketClose,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

fn getSocketData(fd: *FileDescriptor) ?*SocketFdData {
    if (fd.ops != &socket_file_ops) {
        return null;
    }
    const data_ptr = fd.private_data orelse return null;
    return @ptrCast(@alignCast(data_ptr));
}

fn getSocketContext(fd_num: usize) ?struct { fd: *FileDescriptor, socket_idx: usize } {
    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, fd_num) orelse return null;
    const fd = table.get(fd_u32) orelse return null;
    const ctx = getSocketData(fd) orelse return null;
    return .{ .fd = fd, .socket_idx = ctx.socket_idx };
}

fn installSocketFd(socket_idx: usize) SyscallError!usize {
    const ctx = heap.allocator().create(SocketFdData) catch {
        return error.ENOMEM;
    };
    ctx.* = .{ .socket_idx = socket_idx };
    errdefer heap.allocator().destroy(ctx);

    const fd = fd_mod.createFd(&socket_file_ops, fd_mod.O_RDWR, ctx) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(fd);

    // SECURITY: Use atomic allocAndInstall to prevent race between
    // allocFdNum and install where two threads could get the same fd_num
    const table = base.getGlobalFdTable();
    const fd_num = table.allocAndInstall(fd) orelse {
        return error.EMFILE;
    };
    return fd_num;
}

/// Convert socket layer errors to SyscallError
fn socketErrorToSyscallError(err: socket.SocketError) SyscallError {
    return switch (err) {
        socket.SocketError.BadFd => error.EBADF,
        socket.SocketError.AfNotSupported => error.EAFNOSUPPORT,
        socket.SocketError.TypeNotSupported => error.ESOCKTNOSUPPORT,
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
        socket.SocketError.SystemError => error.EIO,
    };
}

// =============================================================================
// Socket File Operations
// =============================================================================

fn socketRead(fd: *FileDescriptor, buf: []u8) isize {
    const ctx = getSocketData(fd) orelse {
        return Errno.ENOTSOCK.toReturn();
    };

    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return Errno.EBADF.toReturn();
    };

    if (sock.sock_type == socket.SOCK_STREAM) {
        const bytes = socket.tcpRecv(ctx.socket_idx, buf) catch |err| {
            return socket.errorToErrno(err);
        };
        return @intCast(bytes);
    }

    const bytes = socket.recvfrom(ctx.socket_idx, buf, null) catch |err| {
        return socket.errorToErrno(err);
    };
    return @intCast(bytes);
}

fn socketWrite(fd: *FileDescriptor, buf: []const u8) isize {
    const ctx = getSocketData(fd) orelse {
        return Errno.ENOTSOCK.toReturn();
    };

    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return Errno.EBADF.toReturn();
    };

    if (sock.sock_type == socket.SOCK_STREAM) {
        const bytes = socket.tcpSend(ctx.socket_idx, buf) catch |err| {
            return socket.errorToErrno(err);
        };
        return @intCast(bytes);
    }

    // UDP send without destination is not supported in MVP
    return Errno.ENOTCONN.toReturn();
}

fn socketClose(fd: *FileDescriptor) isize {
    const ctx = getSocketData(fd) orelse {
        return Errno.ENOTSOCK.toReturn();
    };

    const result = socket.close(ctx.socket_idx) catch |err| {
        return socket.errorToErrno(err);
    };
    _ = result;

    heap.allocator().destroy(ctx);
    return 0;
}

// =============================================================================
// Basic Socket Syscalls
// =============================================================================

/// sys_socket (41) - Create a socket
/// (domain, type, protocol) -> fd
pub fn sys_socket(domain: usize, sock_type: usize, protocol: usize) SyscallError!usize {
    init();

    // Validate socket parameters fit target types
    const domain_u16 = std.math.cast(u16, domain) orelse return error.EINVAL;
    const sock_type_u16 = std.math.cast(u16, sock_type) orelse return error.EINVAL;
    const protocol_u16 = std.math.cast(u16, protocol) orelse return error.EINVAL;

    const sock_idx = socket.socket(
        domain_u16,
        sock_type_u16,
        protocol_u16,
    ) catch |err| {
        return socketErrorToSyscallError(err);
    };

    const fd_num = installSocketFd(sock_idx) catch |err| {
        _ = socket.close(sock_idx) catch {};
        return err;
    };

    return fd_num;
}

/// sys_bind (49) - Bind socket to address
/// (fd, addr, addrlen) -> int
///
/// SECURITY: Binding to privileged ports (< 1024) requires root (euid == 0).
pub fn sys_bind(fd: usize, addr_ptr: usize, addrlen: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    if (addrlen < @sizeOf(socket.SockAddrIn)) {
        return error.EINVAL;
    }

    // Safely copy address from user memory
    const kaddr = user_mem.copyStructFromUser(socket.SockAddrIn, user_mem.UserPtr.from(addr_ptr)) catch {
        return error.EFAULT;
    };

    // SECURITY: Check privileged port binding (ports < 1024)
    const host_port = @byteSwap(kaddr.port);
    if (host_port < 1024 and host_port != 0) {
        const proc = base.getCurrentProcess();
        if (proc.euid != 0) {
            return error.EACCES;
        }
    }

    socket.bind(ctx.socket_idx, &kaddr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    return 0;
}

// =============================================================================
// Data Transfer Syscalls
// =============================================================================

/// Maximum send buffer size to prevent excessive kernel allocation
const MAX_SENDTO_BUFFER: usize = 65536;

/// sys_sendto (44) - Send message on socket
/// (fd, buf, len, flags, dest_addr, addrlen) -> ssize_t
///
/// SECURITY: Copies user data to kernel buffer to prevent TOCTOU.
pub fn sys_sendto(
    fd: usize,
    buf_ptr: usize,
    len: usize,
    flags: usize,
    dest_addr_ptr: usize,
    addrlen: usize,
) SyscallError!usize {
    _ = flags; // Flags ignored for MVP

    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    if (len > MAX_SENDTO_BUFFER) {
        return error.EINVAL;
    }

    if (!isValidUserAccess(buf_ptr, len, AccessMode.Read)) {
        return error.EFAULT;
    }

    var kdest_addr: ?socket.SockAddrIn = null;

    if (dest_addr_ptr != 0) {
        if (addrlen < @sizeOf(socket.SockAddrIn)) {
            return error.EINVAL;
        }
        kdest_addr = user_mem.copyStructFromUser(socket.SockAddrIn, user_mem.UserPtr.from(dest_addr_ptr)) catch {
            return error.EFAULT;
        };
    }

    // SECURITY: Copy user data to kernel buffer to prevent TOCTOU.
    const kbuf = heap.allocator().alloc(u8, len) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    const user_ptr = user_mem.UserPtr.from(buf_ptr);
    _ = user_ptr.copyToKernel(kbuf) catch {
        return error.EFAULT;
    };

    if (kdest_addr) |*addr| {
        const sent = socket.sendto(ctx.socket_idx, kbuf, addr) catch |err| {
            return socketErrorToSyscallError(err);
        };
        return sent;
    } else {
        return error.EDESTADDRREQ;
    }
}

/// Maximum receive buffer size to prevent excessive kernel allocation
const MAX_RECVFROM_BUFFER: usize = 65536;

/// sys_recvfrom (45) - Receive message from socket
/// (fd, buf, len, flags, src_addr, addrlen_ptr) -> ssize_t
///
/// SECURITY: Receives into kernel buffer then copies to user, preventing TOCTOU.
pub fn sys_recvfrom(
    fd: usize,
    buf_ptr: usize,
    len: usize,
    flags: usize,
    src_addr_ptr: usize,
    addrlen_ptr: usize,
) SyscallError!usize {
    _ = flags;

    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    const recv_len = @min(len, MAX_RECVFROM_BUFFER);

    if (!isValidUserAccess(buf_ptr, recv_len, AccessMode.Write)) {
        return error.EFAULT;
    }

    const kbuf = heap.allocator().alloc(u8, recv_len) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    var ksrc_addr: socket.SockAddrIn = std.mem.zeroes(socket.SockAddrIn);
    const src_addr_arg: ?*socket.SockAddrIn = if (src_addr_ptr != 0) &ksrc_addr else null;

    const received = socket.recvfrom(ctx.socket_idx, kbuf, src_addr_arg) catch |err| {
        return socketErrorToSyscallError(err);
    };

    if (received > 0) {
        const user_ptr = user_mem.UserPtr.from(buf_ptr);
        _ = user_ptr.copyFromKernel(kbuf[0..received]) catch {
            return error.EFAULT;
        };
    }

    if (src_addr_ptr != 0 and addrlen_ptr != 0) {
        const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
        const input_len = addrlen_uptr.readValue(u32) catch {
            return error.EFAULT;
        };

        if (input_len < @sizeOf(socket.SockAddrIn)) {
            return error.EINVAL;
        }

        user_mem.copyStructToUser(socket.SockAddrIn, user_mem.UserPtr.from(src_addr_ptr), ksrc_addr) catch {
            return error.EFAULT;
        };

        addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
            return error.EFAULT;
        };
    }

    return received;
}

// =============================================================================
// TCP Connection Syscalls
// =============================================================================

/// sys_listen (50) - Listen for connections on socket
/// (fd, backlog) -> int
pub fn sys_listen(fd: usize, backlog: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    socket.listen(ctx.socket_idx, backlog) catch |err| {
        return socketErrorToSyscallError(err);
    };

    return 0;
}

/// sys_accept (43) - Accept connection on socket
/// (fd, addr, addrlen_ptr) -> fd
pub fn sys_accept(fd: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    init();

    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    var kpeer_addr: socket.SockAddrIn = std.mem.zeroes(socket.SockAddrIn);
    const peer_addr_arg: ?*socket.SockAddrIn = if (addr_ptr != 0) &kpeer_addr else null;

    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    while (true) {
        const result = socket.accept(ctx.socket_idx, peer_addr_arg);

        if (result) |new_sock_fd| {
            if (addr_ptr != 0 and addrlen_ptr != 0) {
                const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
                const input_len = addrlen_uptr.readValue(u32) catch {
                    _ = socket.close(new_sock_fd) catch {};
                    return error.EFAULT;
                };

                if (input_len < @sizeOf(socket.SockAddrIn)) {
                    _ = socket.close(new_sock_fd) catch {};
                    return error.EINVAL;
                }

                user_mem.copyStructToUser(socket.SockAddrIn, user_mem.UserPtr.from(addr_ptr), kpeer_addr) catch {
                    _ = socket.close(new_sock_fd) catch {};
                    return error.EFAULT;
                };

                addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
                    _ = socket.close(new_sock_fd) catch {};
                    return error.EFAULT;
                };
            }

            const new_fd_num = installSocketFd(new_sock_fd) catch |err| {
                _ = socket.close(new_sock_fd) catch {};
                return err;
            };
            return new_fd_num;
        } else |err| {
            if (err == socket.SocketError.WouldBlock and sock.blocking) {
                const current = sched.getCurrentThread() orelse {
                    return error.EAGAIN;
                };
                _ = hal.cpu.disableInterrupts();
                sock.blocked_thread = current;
                sched.block();
                continue;
            }
            return socketErrorToSyscallError(err);
        }
    }
}

/// sys_connect (42) - Connect socket to address
/// (fd, addr, addrlen) -> int
pub fn sys_connect(fd: usize, addr_ptr: usize, addrlen: usize) SyscallError!usize {
    init();

    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    if (addrlen < @sizeOf(socket.SockAddrIn)) {
        return error.EINVAL;
    }

    const kaddr = user_mem.copyStructFromUser(socket.SockAddrIn, user_mem.UserPtr.from(addr_ptr)) catch {
        return error.EFAULT;
    };

    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    socket.connect(ctx.socket_idx, &kaddr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    if (sock.blocking) {
        while (true) {
            socket.checkConnectStatus(ctx.socket_idx) catch |err| {
                if (err == socket.SocketError.WouldBlock) {
                    const current = sched.getCurrentThread() orelse {
                        return error.EAGAIN;
                    };
                    _ = hal.cpu.disableInterrupts();
                    if (socket.getTcb(ctx.socket_idx)) |tcb| {
                        tcb.blocked_thread = current;
                    }
                    sched.block();
                    continue;
                }
                return socketErrorToSyscallError(err);
            };
            return 0;
        }
    }

    return 0;
}

// =============================================================================
// Socket Options Syscalls
// =============================================================================

/// sys_setsockopt (54) - Set socket option
pub fn sys_setsockopt(fd: usize, level: usize, optname: usize, optval_ptr: usize, optlen: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    const max_optlen: usize = 256;
    if (optlen > max_optlen) {
        return error.EINVAL;
    }

    var optval_buf: [256]u8 = undefined;
    const optval_slice: []const u8 = if (optlen == 0) &[_]u8{} else optval_buf[0..optlen];

    if (optlen > 0) {
        if (!isValidUserAccess(optval_ptr, optlen, AccessMode.Read)) {
            return error.EFAULT;
        }
        const optval_uptr = user_mem.UserPtr.from(optval_ptr);
        _ = optval_uptr.copyToKernel(optval_buf[0..optlen]) catch {
            return error.EFAULT;
        };
    }

    const level_i32 = std.math.cast(i32, level) orelse return error.EINVAL;
    const optname_i32 = std.math.cast(i32, optname) orelse return error.EINVAL;

    socket.setsockopt(ctx.socket_idx, level_i32, optname_i32, optval_slice.ptr, optval_slice.len) catch |err| {
        return socketErrorToSyscallError(err);
    };

    return 0;
}

/// sys_getsockopt (55) - Get socket option
pub fn sys_getsockopt(fd: usize, level: usize, optname: usize, optval_ptr: usize, optlen_ptr: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    const optlen_uptr = user_mem.UserPtr.from(optlen_ptr);
    var koptlen = optlen_uptr.readValue(usize) catch {
        return error.EFAULT;
    };

    if (koptlen > 0 and !isValidUserAccess(optval_ptr, koptlen, AccessMode.Write)) {
        return error.EFAULT;
    }

    const max_optlen: usize = 256;
    if (koptlen > max_optlen) {
        koptlen = max_optlen;
    }

    const level_i32 = std.math.cast(i32, level) orelse return error.EINVAL;
    const optname_i32 = std.math.cast(i32, optname) orelse return error.EINVAL;

    var koptval_buf: [256]u8 = undefined;
    const koptval = koptval_buf[0..koptlen];

    var result_len = koptlen;
    socket.getsockopt(ctx.socket_idx, level_i32, optname_i32, koptval.ptr, &result_len) catch |err| {
        return socketErrorToSyscallError(err);
    };

    if (result_len > 0) {
        const optval_uptr = user_mem.UserPtr.from(optval_ptr);
        _ = optval_uptr.copyFromKernel(koptval[0..result_len]) catch {
            return error.EFAULT;
        };
    }

    optlen_uptr.writeValue(result_len) catch {
        return error.EFAULT;
    };

    return 0;
}

// =============================================================================
// Shutdown and Address Query Syscalls
// =============================================================================

/// sys_shutdown (48) - Shut down part of a full-duplex connection
pub fn sys_shutdown(fd: usize, how: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    const how_i32 = std.math.cast(i32, how) orelse return error.EINVAL;
    if (how_i32 < 0 or how_i32 > 2) return error.EINVAL;

    socket.shutdown(ctx.socket_idx, how_i32) catch |err| {
        return socketErrorToSyscallError(err);
    };

    return 0;
}

/// sys_getsockname (51) - Get local socket address
pub fn sys_getsockname(fd: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
    const kaddrlen = addrlen_uptr.readValue(u32) catch {
        return error.EFAULT;
    };

    if (kaddrlen < @sizeOf(socket.SockAddrIn)) {
        return error.EINVAL;
    }

    if (!isValidUserAccess(addr_ptr, @sizeOf(socket.SockAddrIn), AccessMode.Write)) {
        return error.EFAULT;
    }

    var kaddr: socket.SockAddrIn = std.mem.zeroes(socket.SockAddrIn);

    socket.getsockname(ctx.socket_idx, &kaddr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    const addr_uptr = user_mem.UserPtr.from(addr_ptr);
    addr_uptr.writeValue(kaddr) catch {
        return error.EFAULT;
    };

    addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
        return error.EFAULT;
    };

    return 0;
}

/// sys_getpeername (52) - Get peer socket address
pub fn sys_getpeername(fd: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
    const kaddrlen = addrlen_uptr.readValue(u32) catch {
        return error.EFAULT;
    };

    if (kaddrlen < @sizeOf(socket.SockAddrIn)) {
        return error.EINVAL;
    }

    if (!isValidUserAccess(addr_ptr, @sizeOf(socket.SockAddrIn), AccessMode.Write)) {
        return error.EFAULT;
    }

    var kaddr: socket.SockAddrIn = std.mem.zeroes(socket.SockAddrIn);

    socket.getpeername(ctx.socket_idx, &kaddr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    const addr_uptr = user_mem.UserPtr.from(addr_ptr);
    addr_uptr.writeValue(kaddr) catch {
        return error.EFAULT;
    };

    addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
        return error.EFAULT;
    };

    return 0;
}

// =============================================================================
// Poll Syscall (delegated to poll.zig)
// =============================================================================

/// sys_poll (7) - Wait for some event on a file descriptor
/// (ufds, nfds, timeout) -> int
pub fn sys_poll(ufds: usize, nfds: usize, timeout: isize) SyscallError!usize {
    return poll_mod.sys_poll(ufds, nfds, timeout, &socket_file_ops);
}

// =============================================================================
// Scatter/Gather I/O Syscalls (delegated to msg.zig)
// =============================================================================

/// sys_sendmsg (46) - Send a message on a socket with scatter/gather I/O
pub fn sys_sendmsg(fd: usize, msg_ptr: usize, flags: usize) SyscallError!usize {
    return msg_mod.sys_sendmsg(fd, msg_ptr, flags, &socket_file_ops);
}

/// sys_recvmsg (47) - Receive a message from a socket with scatter/gather I/O
pub fn sys_recvmsg(fd: usize, msg_ptr: usize, flags: usize) SyscallError!usize {
    return msg_mod.sys_recvmsg(fd, msg_ptr, flags, &socket_file_ops);
}
