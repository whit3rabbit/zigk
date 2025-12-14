// Network Syscall Handlers
//
// Implements socket-related syscalls for userland networking.
// Uses the kernel's socket layer to provide BSD-style socket API.
// Integrates with scheduler for blocking I/O operations.

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
    const fd = table.get(@intCast(fd_num)) orelse return null;
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

    const sock_idx = socket.socket(
        @intCast(domain),
        @intCast(sock_type),
        @intCast(protocol),
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

    // Validate address pointer
    if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return error.EFAULT;
    }

    if (addrlen < @sizeOf(socket.SockAddrIn)) {
        return error.EINVAL;
    }

    const addr: *const socket.SockAddrIn = @ptrFromInt(addr_ptr);

    socket.bind(ctx.socket_idx, addr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    return 0;
}

/// sys_sendto (44) - Send message on socket
/// (fd, buf, len, flags, dest_addr, addrlen) -> ssize_t
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

    // Validate buffer with read permission (kernel reads from user buffer)
    if (!isValidUserAccess(buf_ptr, len, AccessMode.Read)) {
        return error.EFAULT;
    }

    // Validate destination address (small struct, bounds check sufficient)
    if (!isValidUserPtr(dest_addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return error.EFAULT;
    }

    if (addrlen < @sizeOf(socket.SockAddrIn)) {
        return error.EINVAL;
    }

    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const dest_addr: *const socket.SockAddrIn = @ptrFromInt(dest_addr_ptr);

    const sent = socket.sendto(ctx.socket_idx, buf[0..len], dest_addr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    return sent;
}

/// sys_recvfrom (45) - Receive message from socket
/// (fd, buf, len, flags, src_addr, addrlen_ptr) -> ssize_t
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

    // Validate buffer with write permission (kernel writes to user buffer)
    if (!isValidUserAccess(buf_ptr, len, AccessMode.Write)) {
        return error.EFAULT;
    }

    const buf: [*]u8 = @ptrFromInt(buf_ptr);

    // Source address is optional
    var src_addr: ?*socket.SockAddrIn = null;
    if (src_addr_ptr != 0) {
        if (!isValidUserPtr(src_addr_ptr, @sizeOf(socket.SockAddrIn))) {
            return error.EFAULT;
        }
        src_addr = @ptrFromInt(src_addr_ptr);
    }

    const received = socket.recvfrom(ctx.socket_idx, buf[0..len], src_addr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    // Update addrlen if provided
    // Security: Read input addrlen to kernel stack first (prevents double-fetch TOCTOU)
    // and validate that user buffer is large enough before writing
    if (addrlen_ptr != 0 and src_addr != null) {
        const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
        // Read input addrlen to kernel stack
        const input_len = addrlen_uptr.readValue(u32) catch {
            return error.EFAULT;
        };
        // Validate user buffer is large enough for the address structure
        if (input_len < @sizeOf(socket.SockAddrIn)) {
            return error.EINVAL;
        }
        // Write back actual size used
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

    // Address is optional
    var peer_addr: ?*socket.SockAddrIn = null;
    if (addr_ptr != 0) {
        if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
            return error.EFAULT;
        }
        peer_addr = @ptrFromInt(addr_ptr);
    }

    // Get socket to check blocking mode and set blocked_thread
    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    // Blocking accept loop
    while (true) {
        const result = socket.accept(ctx.socket_idx, peer_addr);

        if (result) |new_sock_fd| {
            // Success - update addrlen and return
            // Security: Read input addrlen to kernel stack first (prevents double-fetch TOCTOU)
            if (addrlen_ptr != 0 and peer_addr != null) {
                const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
                const input_len = addrlen_uptr.readValue(u32) catch {
                    return error.EFAULT;
                };
                if (input_len < @sizeOf(socket.SockAddrIn)) {
                    return error.EINVAL;
                }
                addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
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
                // Woken up - retry accept
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

    // Validate address pointer
    if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return error.EFAULT;
    }

    if (addrlen < @sizeOf(socket.SockAddrIn)) {
        return error.EINVAL;
    }

    const addr: *const socket.SockAddrIn = @ptrFromInt(addr_ptr);

    // Get socket to check blocking mode
    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    // Start connection (sends SYN)
    socket.connect(ctx.socket_idx, addr) catch |err| {
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

    // Validate option value pointer
    if (optlen > 0 and !isValidUserPtr(optval_ptr, optlen)) {
        return error.EFAULT;
    }

    const optval: [*]const u8 = @ptrFromInt(optval_ptr);

    socket.setsockopt(ctx.socket_idx, @intCast(level), @intCast(optname), optval, optlen) catch |err| {
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

    // Validate optlen pointer
    if (!isValidUserPtr(optlen_ptr, @sizeOf(usize))) {
        return error.EFAULT;
    }

    const optlen: *usize = @ptrFromInt(optlen_ptr);

    // Validate option value pointer
    if (optlen.* > 0 and !isValidUserPtr(optval_ptr, optlen.*)) {
        return error.EFAULT;
    }

    const optval: [*]u8 = @ptrFromInt(optval_ptr);

    socket.getsockopt(ctx.socket_idx, @intCast(level), @intCast(optname), optval, optlen) catch |err| {
        return socketErrorToSyscallError(err);
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

    socket.shutdown(ctx.socket_idx, @intCast(how)) catch |err| {
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

    // Validate address pointer
    if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return error.EFAULT;
    }

    // Validate addrlen pointer
    if (!isValidUserPtr(addrlen_ptr, @sizeOf(u32))) {
        return error.EFAULT;
    }

    const addr: *socket.SockAddrIn = @ptrFromInt(addr_ptr);
    const addrlen: *u32 = @ptrFromInt(addrlen_ptr);

    // Check addrlen is large enough
    if (addrlen.* < @sizeOf(socket.SockAddrIn)) {
        return error.EINVAL;
    }

    socket.getsockname(ctx.socket_idx, addr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    // Update addrlen with actual size
    addrlen.* = @sizeOf(socket.SockAddrIn);

    return 0;
}

/// sys_getpeername (52) - Get peer socket address
/// (fd, addr, addrlen_ptr) -> int
pub fn sys_getpeername(fd: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    // Validate address pointer
    if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return error.EFAULT;
    }

    // Validate addrlen pointer
    if (!isValidUserPtr(addrlen_ptr, @sizeOf(u32))) {
        return error.EFAULT;
    }

    const addr: *socket.SockAddrIn = @ptrFromInt(addr_ptr);
    const addrlen: *u32 = @ptrFromInt(addrlen_ptr);

    // Check addrlen is large enough
    if (addrlen.* < @sizeOf(socket.SockAddrIn)) {
        return error.EINVAL;
    }

    socket.getpeername(ctx.socket_idx, addr) catch |err| {
        return socketErrorToSyscallError(err);
    };

    // Update addrlen with actual size
    addrlen.* = @sizeOf(socket.SockAddrIn);

    return 0;
}

/// sys_poll (7) - Wait for some event on a file descriptor
/// (ufds, nfds, timeout) -> int
pub fn sys_poll(ufds: usize, nfds: usize, timeout: isize) SyscallError!usize {
    // Validate pollfd array
    const poll_size = @sizeOf(uapi.poll.PollFd);
    const array_size = nfds * poll_size;
    if (!isValidUserPtr(ufds, array_size)) {
        return error.EFAULT;
    }

    const pollfds: [*]uapi.poll.PollFd = @ptrFromInt(ufds);

    // Polling loop
    var ready_count: usize = 0;

    // Check events immediately (non-blocking pass)
    for (0..nfds) |i| {
        const pfd = &pollfds[i];
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

        const socket_ctx = getSocketContext(@intCast(pfd.fd)) orelse {
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
        return ready_count;
    }

    // Blocking Wait
    // Note: timeout is ms. -1 = infinite.
    const current_thread = getCurrentThread();

    // Register blocked thread on all sockets
    for (0..nfds) |i| {
        const pfd = &pollfds[i];
        if (pfd.fd > 2) {
            if (getSocketContext(@intCast(pfd.fd))) |ctx| {
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
    for (0..nfds) |i| {
        const pfd = &pollfds[i];
        if (pfd.fd > 2) {
            if (getSocketContext(@intCast(pfd.fd))) |ctx| {
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

    // Re-check events
    ready_count = 0;
    for (0..nfds) |i| {
        const pfd = &pollfds[i];
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

        const socket_ctx = getSocketContext(@intCast(pfd.fd)) orelse {
            pfd.revents |= @bitCast(uapi.poll.POLLNVAL);
            continue;
        };
        const events: u16 = @bitCast(pfd.events);
        pfd.revents = @bitCast(socket.checkPollEvents(socket_ctx.socket_idx, events));

        if (pfd.revents != 0) {
            ready_count += 1;
        }
    }

    return ready_count;
}
