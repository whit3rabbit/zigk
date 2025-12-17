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
const isValidUserPtr = user_mem.isValidUserPtr;
const isValidUserAccess = user_mem.isValidUserAccess;
const AccessMode = user_mem.AccessMode;

const FileDescriptor = fd_mod.FileDescriptor;

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

    const table = base.getGlobalFdTable();
    const fd_num = table.allocFdNum() orelse {
        return error.EMFILE;
    };
    table.install(fd_num, fd);
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

    socket.bind(ctx.socket_idx, &kaddr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    return 0;
}

/// Maximum send buffer size to prevent excessive kernel allocation
const MAX_SENDTO_BUFFER: usize = 65536;

/// sys_sendto (44) - Send message on socket
/// (fd, buf, len, flags, dest_addr, addrlen) -> ssize_t
///
/// SECURITY: Copies user data to kernel buffer to prevent TOCTOU.
/// A racing userspace thread could modify or unmap the buffer between
/// validation and use by the socket layer.
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

    // Limit buffer size to prevent excessive kernel allocation
    if (len > MAX_SENDTO_BUFFER) {
        return error.EINVAL;
    }

    // Validate buffer with read permission (kernel reads from user buffer)
    if (!isValidUserAccess(buf_ptr, len, AccessMode.Read)) {
        return error.EFAULT;
    }

    // Copy destination address from user memory if provided
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
    // Do NOT create a slice from user memory address.
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
        // UDP without destination not supported in MVP (unless connect used?)
        return error.EDESTADDRREQ;
    }
}

/// Maximum receive buffer size to prevent excessive kernel allocation
const MAX_RECVFROM_BUFFER: usize = 65536;

/// sys_recvfrom (45) - Receive message from socket
/// (fd, buf, len, flags, src_addr, addrlen_ptr) -> ssize_t
///
/// SECURITY: Receives into kernel buffer then copies to user, preventing TOCTOU.
/// A racing userspace thread could unmap the buffer while socket layer writes to it.
pub fn sys_recvfrom(
    fd: usize,
    buf_ptr: usize,
    len: usize,
    flags: usize,
    src_addr_ptr: usize,
    addrlen_ptr: usize,
) SyscallError!usize {
    _ = flags; // Flags ignored for MVP

    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    // Limit buffer size to prevent excessive kernel allocation
    const recv_len = @min(len, MAX_RECVFROM_BUFFER);

    // Validate buffer with write permission (kernel writes to user buffer)
    if (!isValidUserAccess(buf_ptr, recv_len, AccessMode.Write)) {
        return error.EFAULT;
    }

    // SECURITY: Allocate kernel buffer to receive into, preventing TOCTOU.
    // Do NOT create a slice from user memory address.
    const kbuf = heap.allocator().alloc(u8, recv_len) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    // Prepare kernel buffer for source address
    var ksrc_addr: socket.SockAddrIn = undefined;
    const src_addr_arg: ?*socket.SockAddrIn = if (src_addr_ptr != 0) &ksrc_addr else null;

    const received = socket.recvfrom(ctx.socket_idx, kbuf, src_addr_arg) catch |err| {
        return socketErrorToSyscallError(err);
    };

    // Copy received data to userspace
    if (received > 0) {
        const user_ptr = user_mem.UserPtr.from(buf_ptr);
        _ = user_ptr.copyFromKernel(kbuf[0..received]) catch {
            return error.EFAULT;
        };
    }

    // Copy source address back to user if requested and successful
    if (src_addr_ptr != 0 and addrlen_ptr != 0) {
        // Update addrlen first check
        const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
        const input_len = addrlen_uptr.readValue(u32) catch {
            return error.EFAULT;
        };

        if (input_len < @sizeOf(socket.SockAddrIn)) {
            return error.EINVAL;
        }

        // Copy address struct
        user_mem.copyStructToUser(socket.SockAddrIn, user_mem.UserPtr.from(src_addr_ptr), ksrc_addr) catch {
            return error.EFAULT;
        };

        // Update length
        addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
            return error.EFAULT;
        };
    }

    return received;
}

// ============================================================================
// TCP-specific syscalls
// ============================================================================

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
/// Blocks until a connection is available (for blocking sockets)
pub fn sys_accept(fd: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    // Ensure wake function is registered
    init();

    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    // Prepare kernel buffer for peer address
    var kpeer_addr: socket.SockAddrIn = undefined;
    // recvfrom takes ?*SockAddrIn
    const peer_addr_arg: ?*socket.SockAddrIn = if (addr_ptr != 0) &kpeer_addr else null;

    // Get socket to check blocking mode and set blocked_thread
    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    // Blocking accept loop
    while (true) {
        const result = socket.accept(ctx.socket_idx, peer_addr_arg);

        if (result) |new_sock_fd| {
            // Success - copy address back if requested
            if (addr_ptr != 0 and addrlen_ptr != 0) {
                 const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
                 const input_len = addrlen_uptr.readValue(u32) catch {
                    // Cleanup new socket?
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
                // Block until connection arrives
                const current = sched.getCurrentThread() orelse {
                    return error.EAGAIN;
                };
                // Disable interrupts to atomically set blocked_thread before
                // entering Blocked state. This prevents a wake event from
                // occurring between setting blocked_thread and blocking.
                _ = hal.cpu.disableInterrupts();
                sock.blocked_thread = current;
                // block() sets state to Blocked then enables interrupts and
                // halts. When we return, interrupts are enabled.
                sched.block();
                // Woke up - retry accept
                continue;
            }
            // Non-blocking or other error
            return socketErrorToSyscallError(err);
        }
    }
}

/// sys_connect (42) - Connect socket to address
/// (fd, addr, addrlen) -> int
/// Blocks until connection completes (for blocking sockets)
pub fn sys_connect(fd: usize, addr_ptr: usize, addrlen: usize) SyscallError!usize {
    // Ensure wake function is registered
    init();

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

    // Get socket to check blocking mode
    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    // Start connection (sends SYN)
    socket.connect(ctx.socket_idx, &kaddr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    // For blocking socket, wait for connection to complete
    if (sock.blocking) {
        while (true) {
            // Check connection status
            socket.checkConnectStatus(ctx.socket_idx) catch |err| {
                if (err == socket.SocketError.WouldBlock) {
                    // Still connecting - block until TCP layer wakes us
                    const current = sched.getCurrentThread() orelse {
                        return error.EAGAIN;
                    };
                    // Disable interrupts to atomically set blocked_thread before
                    // entering Blocked state. This prevents a wake event from
                    // occurring between setting blocked_thread and blocking.
                    _ = hal.cpu.disableInterrupts();
                    // Set blocked_thread on TCB so TCP layer can wake us
                    if (socket.getTcb(ctx.socket_idx)) |tcb| {
                        tcb.blocked_thread = current;
                    }
                    // block() sets state to Blocked then enables interrupts and
                    // halts. When we return, interrupts are enabled.
                    sched.block();
                    continue;
                }
                // Connection failed
                return socketErrorToSyscallError(err);
            };
            // Connected successfully
            return 0;
        }
    }

    return 0;
}

// ============================================================================
// Socket Options syscalls
// ============================================================================

/// sys_setsockopt (54) - Set socket option
/// (fd, level, optname, optval, optlen) -> int
pub fn sys_setsockopt(fd: usize, level: usize, optname: usize, optval_ptr: usize, optlen: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    // Copy option value to kernel buffer to avoid TOCTOU on async access.
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

    // Validate socket option parameters
    const level_i32 = std.math.cast(i32, level) orelse return error.EINVAL;
    const optname_i32 = std.math.cast(i32, optname) orelse return error.EINVAL;

    socket.setsockopt(ctx.socket_idx, level_i32, optname_i32, optval_slice.ptr, optval_slice.len) catch |err| {
        return socketErrorToSyscallError(err);
    };

    return 0;
}

/// sys_getsockopt (55) - Get socket option
/// (fd, level, optname, optval, optlen_ptr) -> int
pub fn sys_getsockopt(fd: usize, level: usize, optname: usize, optval_ptr: usize, optlen_ptr: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    // Security: Copy optlen to kernel stack first to prevent TOCTOU race
    // A racing userspace thread could modify optlen between validation and use
    const optlen_uptr = user_mem.UserPtr.from(optlen_ptr);
    var koptlen = optlen_uptr.readValue(usize) catch {
        return error.EFAULT;
    };

    // Validate option value pointer using kernel-copied length
    if (koptlen > 0 and !isValidUserPtr(optval_ptr, koptlen)) {
        return error.EFAULT;
    }

    // Cap optlen to prevent excessive kernel buffer allocation
    const max_optlen: usize = 256;
    if (koptlen > max_optlen) {
        koptlen = max_optlen;
    }

    // Validate socket option parameters
    const level_i32 = std.math.cast(i32, level) orelse return error.EINVAL;
    const optname_i32 = std.math.cast(i32, optname) orelse return error.EINVAL;

    // Allocate kernel buffer for option value
    var koptval_buf: [256]u8 = undefined;
    const koptval = koptval_buf[0..koptlen];

    // Call socket layer with kernel buffer
    var result_len = koptlen;
    socket.getsockopt(ctx.socket_idx, level_i32, optname_i32, koptval.ptr, &result_len) catch |err| {
        return socketErrorToSyscallError(err);
    };

    // Copy result back to userspace
    if (result_len > 0) {
        const optval_uptr = user_mem.UserPtr.from(optval_ptr);
        _ = optval_uptr.copyFromKernel(koptval[0..result_len]) catch {
            return error.EFAULT;
        };
    }

    // Write back actual length
    optlen_uptr.writeValue(result_len) catch {
        return error.EFAULT;
    };

    return 0;
}

// ============================================================================
// Shutdown and Address Query syscalls
// ============================================================================

/// sys_shutdown (48) - Shut down part of a full-duplex connection
/// (fd, how) -> int
/// how: 0=SHUT_RD, 1=SHUT_WR, 2=SHUT_RDWR
pub fn sys_shutdown(fd: usize, how: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    // Validate shutdown mode (0, 1, or 2)
    const how_i32 = std.math.cast(i32, how) orelse return error.EINVAL;
    if (how_i32 < 0 or how_i32 > 2) return error.EINVAL;

    socket.shutdown(ctx.socket_idx, how_i32) catch |err| {
        return socketErrorToSyscallError(err);
    };

    return 0;
}

/// sys_getsockname (51) - Get local socket address
/// (fd, addr, addrlen_ptr) -> int
pub fn sys_getsockname(fd: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    // Security: Copy addrlen to kernel stack first to prevent TOCTOU race
    const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
    const kaddrlen = addrlen_uptr.readValue(u32) catch {
        return error.EFAULT;
    };

    // Check addrlen is large enough using kernel-copied value
    if (kaddrlen < @sizeOf(socket.SockAddrIn)) {
        return error.EINVAL;
    }

    // Validate address pointer
    if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return error.EFAULT;
    }

    // Use kernel buffer for the address
    var kaddr: socket.SockAddrIn = undefined;

    socket.getsockname(ctx.socket_idx, &kaddr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    // Copy address to userspace
    const addr_uptr = user_mem.UserPtr.from(addr_ptr);
    addr_uptr.writeValue(kaddr) catch {
        return error.EFAULT;
    };

    // Write back actual size
    addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
        return error.EFAULT;
    };

    return 0;
}

/// sys_getpeername (52) - Get peer socket address
/// (fd, addr, addrlen_ptr) -> int
pub fn sys_getpeername(fd: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    // Security: Copy addrlen to kernel stack first to prevent TOCTOU race
    const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
    const kaddrlen = addrlen_uptr.readValue(u32) catch {
        return error.EFAULT;
    };

    // Check addrlen is large enough using kernel-copied value
    if (kaddrlen < @sizeOf(socket.SockAddrIn)) {
        return error.EINVAL;
    }

    // Validate address pointer
    if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return error.EFAULT;
    }

    // Use kernel buffer for the address
    var kaddr: socket.SockAddrIn = undefined;

    socket.getpeername(ctx.socket_idx, &kaddr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    // Copy address to userspace
    const addr_uptr = user_mem.UserPtr.from(addr_ptr);
    addr_uptr.writeValue(kaddr) catch {
        return error.EFAULT;
    };

    // Write back actual size
    addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
        return error.EFAULT;
    };

    return 0;
}

/// sys_poll (7) - Wait for some event on a file descriptor
/// (ufds, nfds, timeout) -> int
///
/// Security: Copies pollfd array to kernel memory to prevent TOCTOU races.
/// A malicious userspace thread could modify fd values or unmap memory
/// while poll is blocked, causing kernel faults or invalid socket access.
pub fn sys_poll(ufds: usize, nfds: usize, timeout: isize) SyscallError!usize {
    // Limit nfds to prevent excessive kernel allocations (matches Linux RLIMIT_NOFILE default)
    const max_nfds: usize = 1024;
    if (nfds > max_nfds) {
        return error.EINVAL;
    }

    if (nfds == 0) {
        // No fds to poll - if timeout is 0, return immediately; otherwise block
        if (timeout == 0) return 0;
        // For non-zero timeout with no fds, just return 0 (matches Linux behavior)
        return 0;
    }

    // Validate pollfd array pointer
    const poll_size = @sizeOf(uapi.poll.PollFd);
    const array_size = nfds * poll_size;
    if (!isValidUserPtr(ufds, array_size)) {
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
        const socket_ctx = getSocketContext(fd_usize) orelse {
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

    // Register blocked thread on all sockets (using kernel copy of fd values)
    for (kpollfds) |*pfd| {
        // fd > 2 ensures positive value, safe to cast
        if (pfd.fd > 2) {
            const fd_u: usize = @intCast(pfd.fd);
            if (getSocketContext(fd_u)) |ctx| {
                if (socket.getSocket(ctx.socket_idx)) |sock| {
                    if (current_thread) |t| {
                        sock.blocked_thread = t;
                        if (sock.tcb) |tcb| {
                            tcb.blocked_thread = t;
                        }
                    }
                }
            }
        }
    }

    // Block
    blockCurrentThread();

    // Woke up - Clear blocked thread registration
    for (kpollfds) |*pfd| {
        // fd > 2 ensures positive value, safe to cast
        if (pfd.fd > 2) {
            const fd_u: usize = @intCast(pfd.fd);
            if (getSocketContext(fd_u)) |ctx| {
                if (socket.getSocket(ctx.socket_idx)) |sock| {
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
        const socket_ctx = getSocketContext(fd_usize) orelse {
            pfd.revents |= @bitCast(uapi.poll.POLLNVAL);
            continue;
        };
        const events: u16 = @bitCast(pfd.events);
        pfd.revents = @bitCast(socket.checkPollEvents(socket_ctx.socket_idx, events));

        if (pfd.revents != 0) {
            ready_count += 1;
        }
    }

    // Copy results back to userspace
    _ = ufds_uptr.copyFromKernel(std.mem.sliceAsBytes(kpollfds)) catch {
        return error.EFAULT;
    };

    return ready_count;
}

// ============================================================================
// Scatter/Gather I/O Syscalls (sendmsg/recvmsg)
// ============================================================================

const IoVec = uapi.abi.IoVec;
const MsgHdr = uapi.abi.MsgHdr;

/// Maximum number of iovecs to prevent excessive kernel allocations
const MAX_IOV_COUNT: usize = 1024;

/// Maximum total message size for sendmsg/recvmsg
const MAX_MSG_SIZE: usize = 65536;

/// sys_sendmsg (46) - Send a message on a socket with scatter/gather I/O
/// (fd, msg_ptr, flags) -> ssize_t
///
/// Gathers data from multiple user buffers (iovecs) and sends as single message.
/// SECURITY: All user data is copied to kernel buffers to prevent TOCTOU.
pub fn sys_sendmsg(fd: usize, msg_ptr: usize, flags: usize) SyscallError!usize {
    _ = flags; // Flags ignored for MVP (MSG_DONTWAIT, MSG_NOSIGNAL, etc.)

    const ctx = getSocketContext(fd) orelse {
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
    var total_len: usize = 0;
    for (iovecs) |iov| {
        // Check for overflow
        if (total_len > MAX_MSG_SIZE - iov.iov_len) {
            return error.EMSGSIZE;
        }
        total_len += iov.iov_len;
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
pub fn sys_recvmsg(fd: usize, msg_ptr: usize, flags: usize) SyscallError!usize {
    _ = flags; // Flags ignored for MVP (MSG_PEEK, MSG_WAITALL, etc.)

    const ctx = getSocketContext(fd) orelse {
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
    var total_len: usize = 0;
    for (iovecs) |iov| {
        if (total_len > MAX_MSG_SIZE - iov.iov_len) {
            return error.EMSGSIZE;
        }
        total_len += iov.iov_len;

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
    var ksrc_addr: socket.SockAddrIn = undefined;
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
