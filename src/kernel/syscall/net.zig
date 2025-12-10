// Network Syscall Handlers
//
// Implements socket-related syscalls for userland networking.
// Uses the kernel's socket layer to provide BSD-style socket API.
// Integrates with scheduler for blocking I/O operations.

const uapi = @import("uapi");
const net = @import("net");
const socket = net.transport.socket;
const tcp = net.transport.tcp;
const Errno = uapi.errno.Errno;
const sched = @import("sched");
const hal = @import("hal");
const thread = @import("thread");
const Thread = thread.Thread;
const user_mem = @import("user_mem");

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

/// sys_socket (41) - Create a socket
/// (domain, type, protocol) -> fd
pub fn sys_socket(domain: usize, sock_type: usize, protocol: usize) isize {
    const fd = socket.socket(
        @intCast(domain),
        @intCast(sock_type),
        @intCast(protocol),
    ) catch |err| {
        return socket.errorToErrno(err);
    };

    // Socket FDs start at 3 (after stdin/stdout/stderr)
    // For simplicity, socket index = fd - 3
    return @intCast(fd + 3);
}

/// sys_bind (49) - Bind socket to address
/// (fd, addr, addrlen) -> int
pub fn sys_bind(fd: usize, addr_ptr: usize, addrlen: usize) isize {
    // Validate FD is a socket (fd >= 3)
    if (fd < 3) {
        return Errno.ENOTSOCK.toReturn();
    }

    // Validate address pointer
    if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return Errno.EFAULT.toReturn();
    }

    if (addrlen < @sizeOf(socket.SockAddrIn)) {
        return Errno.EINVAL.toReturn();
    }

    const addr: *const socket.SockAddrIn = @ptrFromInt(addr_ptr);

    socket.bind(fd - 3, addr) catch |err| {
        return socket.errorToErrno(err);
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
) isize {
    _ = flags; // Flags ignored for MVP

    // Validate FD
    if (fd < 3) {
        return Errno.ENOTSOCK.toReturn();
    }

    // Validate buffer with read permission (kernel reads from user buffer)
    if (!isValidUserAccess(buf_ptr, len, AccessMode.Read)) {
        return Errno.EFAULT.toReturn();
    }

    // Validate destination address (small struct, bounds check sufficient)
    if (!isValidUserPtr(dest_addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return Errno.EFAULT.toReturn();
    }

    if (addrlen < @sizeOf(socket.SockAddrIn)) {
        return Errno.EINVAL.toReturn();
    }

    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const dest_addr: *const socket.SockAddrIn = @ptrFromInt(dest_addr_ptr);

    const sent = socket.sendto(fd - 3, buf[0..len], dest_addr) catch |err| {
        return socket.errorToErrno(err);
    };

    return @intCast(sent);
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
) isize {
    _ = flags; // Flags ignored for MVP

    // Validate FD
    if (fd < 3) {
        return Errno.ENOTSOCK.toReturn();
    }

    // Validate buffer with write permission (kernel writes to user buffer)
    if (!isValidUserAccess(buf_ptr, len, AccessMode.Write)) {
        return Errno.EFAULT.toReturn();
    }

    const buf: [*]u8 = @ptrFromInt(buf_ptr);

    // Source address is optional
    var src_addr: ?*socket.SockAddrIn = null;
    if (src_addr_ptr != 0) {
        if (!isValidUserPtr(src_addr_ptr, @sizeOf(socket.SockAddrIn))) {
            return Errno.EFAULT.toReturn();
        }
        src_addr = @ptrFromInt(src_addr_ptr);
    }

    const received = socket.recvfrom(fd - 3, buf[0..len], src_addr) catch |err| {
        return socket.errorToErrno(err);
    };

    // Update addrlen if provided
    if (addrlen_ptr != 0 and src_addr != null) {
        if (isValidUserPtr(addrlen_ptr, @sizeOf(u32))) {
            const addrlen: *u32 = @ptrFromInt(addrlen_ptr);
            addrlen.* = @sizeOf(socket.SockAddrIn);
        }
    }

    return @intCast(received);
}

// ============================================================================
// TCP-specific syscalls
// ============================================================================

/// sys_listen (50) - Listen for connections on socket
/// (fd, backlog) -> int
pub fn sys_listen(fd: usize, backlog: usize) isize {
    // Validate FD is a socket (fd >= 3)
    if (fd < 3) {
        return Errno.ENOTSOCK.toReturn();
    }

    socket.listen(fd - 3, backlog) catch |err| {
        return socket.errorToErrno(err);
    };

    return 0;
}

/// sys_accept (43) - Accept connection on socket
/// (fd, addr, addrlen_ptr) -> fd
/// Blocks until a connection is available (for blocking sockets)
pub fn sys_accept(fd: usize, addr_ptr: usize, addrlen_ptr: usize) isize {
    // Ensure wake function is registered
    init();

    // Validate FD is a socket (fd >= 3)
    if (fd < 3) {
        return Errno.ENOTSOCK.toReturn();
    }

    // Address is optional
    var peer_addr: ?*socket.SockAddrIn = null;
    if (addr_ptr != 0) {
        if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
            return Errno.EFAULT.toReturn();
        }
        peer_addr = @ptrFromInt(addr_ptr);
    }

    const sock_idx = fd - 3;

    // Get socket to check blocking mode and set blocked_thread
    const sock = socket.getSocket(sock_idx) orelse {
        return Errno.EBADF.toReturn();
    };

    // Blocking accept loop
    while (true) {
        const result = socket.accept(sock_idx, peer_addr);

        if (result) |new_sock_fd| {
            // Success - update addrlen and return
            if (addrlen_ptr != 0 and peer_addr != null) {
                if (isValidUserPtr(addrlen_ptr, @sizeOf(u32))) {
                    const addrlen: *u32 = @ptrFromInt(addrlen_ptr);
                    addrlen.* = @sizeOf(socket.SockAddrIn);
                }
            }
            return @intCast(new_sock_fd + 3);
        } else |err| {
            if (err == socket.SocketError.WouldBlock and sock.blocking) {
                // Block until connection arrives
                const current = sched.getCurrentThread() orelse {
                    return Errno.EAGAIN.toReturn();
                };
                const irq_state = hal.cpu.interruptsEnabled();
                hal.cpu.disableInterrupts();
                sock.blocked_thread = current;
                sched.block();
                if (irq_state) {
                    hal.cpu.enableInterrupts();
                }
                // Woken up - retry accept
                continue;
            }
            // Non-blocking or other error
            return socket.errorToErrno(err);
        }
    }
}

/// sys_connect (42) - Connect socket to address
/// (fd, addr, addrlen) -> int
/// Blocks until connection completes (for blocking sockets)
pub fn sys_connect(fd: usize, addr_ptr: usize, addrlen: usize) isize {
    // Ensure wake function is registered
    init();

    // Validate FD is a socket (fd >= 3)
    if (fd < 3) {
        return Errno.ENOTSOCK.toReturn();
    }

    // Validate address pointer
    if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return Errno.EFAULT.toReturn();
    }

    if (addrlen < @sizeOf(socket.SockAddrIn)) {
        return Errno.EINVAL.toReturn();
    }

    const sock_idx = fd - 3;
    const addr: *const socket.SockAddrIn = @ptrFromInt(addr_ptr);

    // Get socket to check blocking mode
    const sock = socket.getSocket(sock_idx) orelse {
        return Errno.EBADF.toReturn();
    };

    // Start connection (sends SYN)
    socket.connect(sock_idx, addr) catch |err| {
        return socket.errorToErrno(err);
    };

    // For blocking socket, wait for connection to complete
    if (sock.blocking) {
        while (true) {
            // Check connection status
            socket.checkConnectStatus(sock_idx) catch |err| {
                if (err == socket.SocketError.WouldBlock) {
                    // Still connecting - block until TCP layer wakes us
                    const current = sched.getCurrentThread() orelse {
                        return Errno.EAGAIN.toReturn();
                    };
                    const irq_state = hal.cpu.interruptsEnabled();
                    hal.cpu.disableInterrupts();
                    // Set blocked_thread on TCB so TCP layer can wake us
                    if (socket.getTcb(sock_idx)) |tcb| {
                        tcb.blocked_thread = current;
                    }
                    sched.block();
                    if (irq_state) {
                        hal.cpu.enableInterrupts();
                    }
                    continue;
                }
                // Connection failed
                return socket.errorToErrno(err);
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
pub fn sys_setsockopt(fd: usize, level: usize, optname: usize, optval_ptr: usize, optlen: usize) isize {
    // Validate FD is a socket (fd >= 3)
    if (fd < 3) {
        return Errno.ENOTSOCK.toReturn();
    }

    // Validate option value pointer
    if (optlen > 0 and !isValidUserPtr(optval_ptr, optlen)) {
        return Errno.EFAULT.toReturn();
    }

    const sock_idx = fd - 3;
    const optval: [*]const u8 = @ptrFromInt(optval_ptr);

    socket.setsockopt(sock_idx, @intCast(level), @intCast(optname), optval, optlen) catch |err| {
        return socket.errorToErrno(err);
    };

    return 0;
}

/// sys_getsockopt (55) - Get socket option
/// (fd, level, optname, optval, optlen_ptr) -> int
pub fn sys_getsockopt(fd: usize, level: usize, optname: usize, optval_ptr: usize, optlen_ptr: usize) isize {
    // Validate FD is a socket (fd >= 3)
    if (fd < 3) {
        return Errno.ENOTSOCK.toReturn();
    }

    // Validate optlen pointer
    if (!isValidUserPtr(optlen_ptr, @sizeOf(usize))) {
        return Errno.EFAULT.toReturn();
    }

    const optlen: *usize = @ptrFromInt(optlen_ptr);

    // Validate option value pointer
    if (optlen.* > 0 and !isValidUserPtr(optval_ptr, optlen.*)) {
        return Errno.EFAULT.toReturn();
    }

    const sock_idx = fd - 3;
    const optval: [*]u8 = @ptrFromInt(optval_ptr);

    socket.getsockopt(sock_idx, @intCast(level), @intCast(optname), optval, optlen) catch |err| {
        return socket.errorToErrno(err);
    };

    return 0;
}

// ============================================================================
// Shutdown and Address Query syscalls
// ============================================================================

/// sys_shutdown (48) - Shut down part of a full-duplex connection
/// (fd, how) -> int
/// how: 0=SHUT_RD, 1=SHUT_WR, 2=SHUT_RDWR
pub fn sys_shutdown(fd: usize, how: usize) isize {
    // Validate FD is a socket (fd >= 3)
    if (fd < 3) {
        return Errno.ENOTSOCK.toReturn();
    }

    const sock_idx = fd - 3;

    socket.shutdown(sock_idx, @intCast(how)) catch |err| {
        return socket.errorToErrno(err);
    };

    return 0;
}

/// sys_getsockname (51) - Get local socket address
/// (fd, addr, addrlen_ptr) -> int
pub fn sys_getsockname(fd: usize, addr_ptr: usize, addrlen_ptr: usize) isize {
    // Validate FD is a socket (fd >= 3)
    if (fd < 3) {
        return Errno.ENOTSOCK.toReturn();
    }

    // Validate address pointer
    if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return Errno.EFAULT.toReturn();
    }

    // Validate addrlen pointer
    if (!isValidUserPtr(addrlen_ptr, @sizeOf(u32))) {
        return Errno.EFAULT.toReturn();
    }

    const sock_idx = fd - 3;
    const addr: *socket.SockAddrIn = @ptrFromInt(addr_ptr);
    const addrlen: *u32 = @ptrFromInt(addrlen_ptr);

    // Check addrlen is large enough
    if (addrlen.* < @sizeOf(socket.SockAddrIn)) {
        return Errno.EINVAL.toReturn();
    }

    socket.getsockname(sock_idx, addr) catch |err| {
        return socket.errorToErrno(err);
    };

    // Update addrlen with actual size
    addrlen.* = @sizeOf(socket.SockAddrIn);

    return 0;
}

/// sys_getpeername (52) - Get peer socket address
/// (fd, addr, addrlen_ptr) -> int
pub fn sys_getpeername(fd: usize, addr_ptr: usize, addrlen_ptr: usize) isize {
    // Validate FD is a socket (fd >= 3)
    if (fd < 3) {
        return Errno.ENOTSOCK.toReturn();
    }

    // Validate address pointer
    if (!isValidUserPtr(addr_ptr, @sizeOf(socket.SockAddrIn))) {
        return Errno.EFAULT.toReturn();
    }

    // Validate addrlen pointer
    if (!isValidUserPtr(addrlen_ptr, @sizeOf(u32))) {
        return Errno.EFAULT.toReturn();
    }

    const sock_idx = fd - 3;
    const addr: *socket.SockAddrIn = @ptrFromInt(addr_ptr);
    const addrlen: *u32 = @ptrFromInt(addrlen_ptr);

    // Check addrlen is large enough
    if (addrlen.* < @sizeOf(socket.SockAddrIn)) {
        return Errno.EINVAL.toReturn();
    }

    socket.getpeername(sock_idx, addr) catch |err| {
        return socket.errorToErrno(err);
    };

    // Update addrlen with actual size
    addrlen.* = @sizeOf(socket.SockAddrIn);

    return 0;
}

/// sys_poll (7) - Wait for some event on a file descriptor
/// (ufds, nfds, timeout) -> int
pub fn sys_poll(ufds: usize, nfds: usize, timeout: isize) isize {
    // Validate pollfd array
    const poll_size = @sizeOf(uapi.poll.PollFd);
    const array_size = nfds * poll_size;
    if (!isValidUserPtr(ufds, array_size)) {
        return Errno.EFAULT.toReturn();
    }

    const pollfds: [*]uapi.poll.PollFd = @ptrFromInt(ufds);
    
    // Polling loop
    var ready_count: usize = 0;
    
    // Check events immediately (non-blocking pass)
    for (0..nfds) |i| {
        const pfd = &pollfds[i];
        pfd.revents = 0;
        
        if (pfd.fd < 0) continue;
        
        if (pfd.fd < 3) {
            // Stdin/stdout always ready for read/write?
            // stdin (0): POLLIN if keyboard has data?
            // stdout (1/2): POLLOUT always
            if (pfd.fd > 0 and (pfd.events & uapi.poll.POLLOUT) != 0) {
                pfd.revents |= uapi.poll.POLLOUT;
            }
        } else {
            // Socket
            const sock_idx = @as(usize, @intCast(pfd.fd - 3));
            pfd.revents = socket.checkPollEvents(sock_idx, pfd.events);
        }
        
        if (pfd.revents != 0) {
            ready_count += 1;
        }
    }
    
    if (ready_count > 0 or timeout == 0) {
        return @intCast(ready_count);
    }
    
    // Blocking Wait
    // Note: timeout is ms. -1 = infinite.
    const current_thread = getCurrentThread();
    
    // Register blocked thread on all sockets
    for (0..nfds) |i| {
        const pfd = &pollfds[i];
        if (pfd.fd >= 3) {
             const sock_idx = @as(usize, @intCast(pfd.fd - 3));
             if (socket.getSocket(sock_idx)) |sock| {
                 // Overwrite generic blocked_thread logic.
                 // NOTE: This breaks accept/connect threads if mixed!
                 if (current_thread) |t| {
                    sock.blocked_thread = t;
                    if (sock.tcb) |tcb| {
                        tcb.blocked_thread = t;
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
        if (pfd.fd >= 3) {
             const sock_idx = @as(usize, @intCast(pfd.fd - 3));
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
    
    // Re-check events
    ready_count = 0;
    for (0..nfds) |i| {
        const pfd = &pollfds[i];
        // Ensure consistent reporting
        pfd.revents = 0;
        
        if (pfd.fd < 3) {
             if (pfd.fd > 0 and (pfd.events & uapi.poll.POLLOUT) != 0) {
                pfd.revents |= uapi.poll.POLLOUT;
            }
        } else {
            const sock_idx = @as(usize, @intCast(pfd.fd - 3));
            pfd.revents = socket.checkPollEvents(sock_idx, pfd.events);
        }
        
        if (pfd.revents != 0) {
            ready_count += 1;
        }
    }
    
    return @intCast(ready_count);
}
