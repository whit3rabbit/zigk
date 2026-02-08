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

fn socketPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    const data = getSocketData(fd) orelse return 0; // Invalid socket fd

    // Delegate to socket layer's checkPollEvents (returns u16)
    // Convert u32 -> u16 for call, u16 -> u32 for return
    const events_u16: u16 = @truncate(requested_events);
    const result = socket.checkPollEvents(data.socket_idx, events_u16);
    return @as(u32, result);
}

const socket_file_ops = fd_mod.FileOps{
    .read = socketRead,
    .write = socketWrite,
    .close = socketClose,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = socketPoll,
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

fn installSocketFd(socket_idx: usize, cloexec: bool) SyscallError!usize {
    const ctx = heap.allocator().create(SocketFdData) catch {
        return error.ENOMEM;
    };
    ctx.* = .{ .socket_idx = socket_idx };
    errdefer heap.allocator().destroy(ctx);

    const fd = fd_mod.createFd(&socket_file_ops, fd_mod.O_RDWR, ctx) catch {
        return error.ENOMEM;
    };
    fd.cloexec = cloexec;
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
///
/// SECURITY: Raw sockets (SOCK_RAW) require root (euid == 0) or CAP_NET_RAW.
/// This prevents unprivileged processes from crafting arbitrary packets,
/// performing network scanning, ICMP tunneling, or source address spoofing.
pub fn sys_socket(domain: usize, sock_type: usize, protocol: usize) SyscallError!usize {
    init();

    // Validate socket parameters fit target types
    const domain_u16 = std.math.cast(u16, domain) orelse return error.EINVAL;
    const protocol_u16 = std.math.cast(u16, protocol) orelse return error.EINVAL;

    // Extract flags from sock_type (SOCK_NONBLOCK, SOCK_CLOEXEC are ORed with type)
    // Use u32 because SOCK_CLOEXEC (0x80000) doesn't fit in u16
    const sock_type_u32 = std.math.cast(u32, sock_type) orelse return error.EINVAL;
    const SOCK_TYPE_MASK: u32 = 0xF;
    const type_masked: i32 = @intCast(sock_type_u32 & SOCK_TYPE_MASK);
    const is_nonblock = (sock_type_u32 & @as(u32, @intCast(socket.SOCK_NONBLOCK))) != 0;
    const is_cloexec = (sock_type_u32 & @as(u32, @intCast(socket.SOCK_CLOEXEC))) != 0;

    // Handle AF_UNIX domain sockets
    if (domain_u16 == socket.AF_UNIX or domain_u16 == socket.AF_LOCAL) {
        // Protocol must be 0 for AF_UNIX
        if (protocol_u16 != 0) {
            return error.EPROTONOSUPPORT;
        }

        // Only SOCK_STREAM and SOCK_DGRAM are supported
        if (type_masked != socket.SOCK_STREAM and type_masked != socket.SOCK_DGRAM) {
            return error.ESOCKTNOSUPPORT;
        }

        // Allocate a full UNIX socket
        const result = unix_socket.allocateSocket(type_masked) orelse {
            return error.ENOMEM;
        };

        // Handle SOCK_NONBLOCK flag
        if (is_nonblock) {
            result.sock.blocking = false;
        }

        const fd_num = installUnixSocketFullFd(result.idx, result.sock.generation, is_cloexec) catch |err| {
            unix_socket.releaseSocket(result.sock);
            return err;
        };

        return fd_num;
    }

    // SECURITY: Raw sockets require CAP_NET_RAW or root privileges.
    if (type_masked == socket.SOCK_RAW) {
        const proc = base.getCurrentProcess();
        if (proc.euid != 0 and !proc.hasNetRawCapability()) {
            return error.EPERM;
        }
    }

    // For network sockets, pass the masked type to the socket layer
    const sock_idx = socket.socket(
        domain_u16,
        @intCast(sock_type_u32 & 0xFFFF), // Lower 16 bits include type + NONBLOCK flag
        protocol_u16,
    ) catch |err| {
        return socketErrorToSyscallError(err);
    };

    const fd_num = installSocketFd(sock_idx, is_cloexec) catch |err| {
        _ = socket.close(sock_idx) catch {};
        return err;
    };

    return fd_num;
}

/// sys_bind (49) - Bind socket to address (dual-stack: IPv4, IPv6, and AF_UNIX)
/// (fd, addr, addrlen) -> int
///
/// SECURITY: Binding to privileged ports (< 1024) requires root (euid == 0).
pub fn sys_bind(fd: usize, addr_ptr: usize, addrlen: usize) SyscallError!usize {
    // Read address family first (offset 0, 2 bytes in all sockaddr types)
    if (addrlen < 2) {
        return error.EINVAL;
    }

    const family = user_mem.UserPtr.from(addr_ptr).readValue(u16) catch {
        return error.EFAULT;
    };

    // Handle AF_UNIX bind
    if (family == socket.AF_UNIX or family == socket.AF_LOCAL) {
        const unix_ctx = getUnixSocketFullContext(fd) orelse {
            return error.ENOTSOCK;
        };

        const sock = unix_socket.getSocketByIdx(unix_ctx.data.socket_idx) orelse {
            return error.EBADF;
        };

        if (sock.generation != unix_ctx.data.generation) {
            return error.EBADF;
        }

        // Read the sockaddr_un structure
        if (addrlen < 3) { // Need at least family + 1 byte of path
            return error.EINVAL;
        }

        const SockAddrUn = uapi.abi.SockAddrUn;
        const max_addr_len = @min(addrlen, @sizeOf(SockAddrUn));
        var kaddr: SockAddrUn = SockAddrUn.init();

        // Copy the address from user space
        const addr_bytes = std.mem.asBytes(&kaddr);
        const uptr = user_mem.UserPtr.from(addr_ptr);
        _ = uptr.copyToKernel(addr_bytes[0..max_addr_len]) catch {
            return error.EFAULT;
        };

        // Determine path and type
        const is_abstract = kaddr.isAbstract();
        const path_len = kaddr.pathLen(addrlen);

        if (path_len == 0) {
            return error.EINVAL;
        }

        // Get path slice (for abstract sockets, skip the leading null)
        const path: []const u8 = if (is_abstract)
            kaddr.sun_path[1..path_len]
        else
            kaddr.sun_path[0..path_len];

        unix_socket.bindSocket(sock, path, is_abstract, unix_ctx.data.socket_idx) catch |err| {
            return unixSocketErrorToSyscallError(err);
        };

        return 0;
    }

    // For network sockets, get the socket context
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    if (family == socket.AF_INET) {
        // IPv4 path
        if (addrlen < @sizeOf(socket.SockAddrIn)) {
            return error.EINVAL;
        }

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
    } else if (family == socket.AF_INET6) {
        // IPv6 path
        if (addrlen < @sizeOf(socket.SockAddrIn6)) {
            return error.EINVAL;
        }

        const kaddr6 = user_mem.copyStructFromUser(socket.SockAddrIn6, user_mem.UserPtr.from(addr_ptr)) catch {
            return error.EFAULT;
        };

        // SECURITY: Check privileged port binding (ports < 1024)
        const host_port = @byteSwap(kaddr6.port);
        if (host_port < 1024 and host_port != 0) {
            const proc = base.getCurrentProcess();
            if (proc.euid != 0) {
                return error.EACCES;
            }
        }

        socket.bind6(ctx.socket_idx, &kaddr6) catch |err| {
            return socketErrorToSyscallError(err);
        };
    } else {
        return error.EAFNOSUPPORT;
    }

    return 0;
}

// =============================================================================
// Data Transfer Syscalls
// =============================================================================

/// Maximum send buffer size to prevent excessive kernel allocation
const MAX_SENDTO_BUFFER: usize = 65536;

/// sys_sendto (44) - Send message on socket (dual-stack: IPv4 and IPv6)
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

    if (dest_addr_ptr == 0) {
        return error.EDESTADDRREQ;
    }

    // Read address family first
    if (addrlen < 2) {
        return error.EINVAL;
    }

    const family = user_mem.UserPtr.from(dest_addr_ptr).readValue(u16) catch {
        return error.EFAULT;
    };

    // SECURITY: Copy user data to kernel buffer to prevent TOCTOU.
    const kbuf = heap.allocator().alloc(u8, len) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    const user_ptr = user_mem.UserPtr.from(buf_ptr);
    _ = user_ptr.copyToKernel(kbuf) catch {
        return error.EFAULT;
    };

    // Get socket to check type/protocol for raw socket dispatch
    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    if (family == socket.AF_INET) {
        // IPv4 path
        if (addrlen < @sizeOf(socket.SockAddrIn)) {
            return error.EINVAL;
        }
        const kdest_addr = user_mem.copyStructFromUser(socket.SockAddrIn, user_mem.UserPtr.from(dest_addr_ptr)) catch {
            return error.EFAULT;
        };

        // Check for raw ICMP socket (for ping)
        if (sock.sock_type == socket.SOCK_RAW and sock.protocol == socket.IPPROTO_ICMP) {
            const sent = socket.sendtoRaw(ctx.socket_idx, kbuf, &kdest_addr) catch |err| {
                return socketErrorToSyscallError(err);
            };
            return sent;
        }

        const sent = socket.sendto(ctx.socket_idx, kbuf, &kdest_addr) catch |err| {
            return socketErrorToSyscallError(err);
        };
        return sent;
    } else if (family == socket.AF_INET6) {
        // IPv6 path
        if (addrlen < @sizeOf(socket.SockAddrIn6)) {
            return error.EINVAL;
        }
        const kdest_addr6 = user_mem.copyStructFromUser(socket.SockAddrIn6, user_mem.UserPtr.from(dest_addr_ptr)) catch {
            return error.EFAULT;
        };

        // Check for raw ICMPv6 socket (for ping6)
        if (sock.sock_type == socket.SOCK_RAW and sock.protocol == socket.IPPROTO_ICMPV6) {
            const sent = socket.sendtoRaw6(ctx.socket_idx, kbuf, &kdest_addr6) catch |err| {
                return socketErrorToSyscallError(err);
            };
            return sent;
        }

        const sent = socket.sendto6(ctx.socket_idx, kbuf, &kdest_addr6) catch |err| {
            return socketErrorToSyscallError(err);
        };
        return sent;
    } else {
        return error.EAFNOSUPPORT;
    }
}

/// Maximum receive buffer size to prevent excessive kernel allocation
const MAX_RECVFROM_BUFFER: usize = 65536;

/// sys_recvfrom (45) - Receive message from socket (dual-stack: IPv4 and IPv6)
/// (fd, buf, len, flags, src_addr, addrlen_ptr) -> ssize_t
///
/// SECURITY: Receives into kernel buffer then copies to user, preventing TOCTOU.
/// Returns source address as SockAddrIn for IPv4 sources, SockAddrIn6 for IPv6.
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

    // Use dual-stack receive function
    var src_ip: socket.IpAddr = .none;
    var src_port: u16 = 0;

    const received = socket.recvfromIp(ctx.socket_idx, kbuf, &src_ip, &src_port) catch |err| {
        return socketErrorToSyscallError(err);
    };

    if (received > 0) {
        const user_ptr = user_mem.UserPtr.from(buf_ptr);
        _ = user_ptr.copyFromKernel(kbuf[0..received]) catch {
            return error.EFAULT;
        };
    }

    // Return source address based on IP version
    if (src_addr_ptr != 0 and addrlen_ptr != 0) {
        const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
        const input_len = addrlen_uptr.readValue(u32) catch {
            return error.EFAULT;
        };

        switch (src_ip) {
            .v4 => |v4| {
                if (input_len < @sizeOf(socket.SockAddrIn)) {
                    return error.EINVAL;
                }
                const ksrc_addr = socket.SockAddrIn.init(v4, src_port);
                user_mem.copyStructToUser(socket.SockAddrIn, user_mem.UserPtr.from(src_addr_ptr), ksrc_addr) catch {
                    return error.EFAULT;
                };
                addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
                    return error.EFAULT;
                };
            },
            .v6 => |v6| {
                if (input_len < @sizeOf(socket.SockAddrIn6)) {
                    return error.EINVAL;
                }
                const ksrc_addr6 = socket.SockAddrIn6.init(v6, src_port);
                user_mem.copyStructToUser(socket.SockAddrIn6, user_mem.UserPtr.from(src_addr_ptr), ksrc_addr6) catch {
                    return error.EFAULT;
                };
                addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn6))) catch {
                    return error.EFAULT;
                };
            },
            .none => {
                // No source address available, write zeros
                const ksrc_addr = std.mem.zeroes(socket.SockAddrIn);
                user_mem.copyStructToUser(socket.SockAddrIn, user_mem.UserPtr.from(src_addr_ptr), ksrc_addr) catch {
                    return error.EFAULT;
                };
                addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
                    return error.EFAULT;
                };
            },
        }
    }

    return received;
}

// =============================================================================
// TCP Connection Syscalls
// =============================================================================

/// sys_listen (50) - Listen for connections on socket
/// (fd, backlog) -> int
pub fn sys_listen(fd: usize, backlog: usize) SyscallError!usize {
    // Check for UNIX socket first
    if (getUnixSocketFullContext(fd)) |unix_ctx| {
        const sock = unix_socket.getSocketByIdx(unix_ctx.data.socket_idx) orelse {
            return error.EBADF;
        };

        if (sock.generation != unix_ctx.data.generation) {
            return error.EBADF;
        }

        unix_socket.listenSocket(sock, backlog) catch |err| {
            return unixSocketErrorToSyscallError(err);
        };

        return 0;
    }

    // Network socket path
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
/// Supports AF_INET (IPv4), AF_INET6 (IPv6), and AF_UNIX return addresses
pub fn sys_accept(fd: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    init();

    // Check for UNIX socket first
    if (getUnixSocketFullContext(fd)) |unix_ctx| {
        const listen_sock = unix_socket.getSocketByIdx(unix_ctx.data.socket_idx) orelse {
            return error.EBADF;
        };

        if (listen_sock.generation != unix_ctx.data.generation) {
            return error.EBADF;
        }

        // Get current process credentials for SO_PEERCRED
        const proc = base.getCurrentProcess();
        const result = unix_socket.acceptSocket(listen_sock, proc.pid, proc.euid, proc.egid) catch |err| {
            return unixSocketErrorToSyscallError(err);
        };

        // Install FD for the new connected socket (no cloexec - use accept4 for that)
        const new_fd_num = installUnixSocketFullFd(result.new_idx, result.new_sock.generation, false) catch |err| {
            unix_socket.closeSocket(result.new_sock);
            return err;
        };

        // Fill in peer address if requested (AF_UNIX returns unnamed address)
        if (addr_ptr != 0 and addrlen_ptr != 0) {
            const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
            const input_len = addrlen_uptr.readValue(u32) catch {
                // Don't fail the accept, just skip address fill
                return new_fd_num;
            };

            if (input_len >= 2) {
                // Write minimal sockaddr_un (just family, unnamed socket)
                const SockAddrUn = uapi.abi.SockAddrUn;
                var kaddr = SockAddrUn.init();
                const addr_uptr = user_mem.UserPtr.from(addr_ptr);
                const write_len = @min(input_len, @sizeOf(SockAddrUn));
                _ = addr_uptr.copyFromKernel(std.mem.asBytes(&kaddr)[0..write_len]) catch {};
                addrlen_uptr.writeValue(@as(u32, 2)) catch {}; // Just family field
            }
        }

        return new_fd_num;
    }

    // Network socket path
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    while (true) {
        // Accept without filling peer_addr - we'll determine family from TCB
        const result = socket.accept(ctx.socket_idx, null);

        if (result) |new_sock_fd| {
            // Fill in peer address if requested
            if (addr_ptr != 0 and addrlen_ptr != 0) {
                const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
                const input_len = addrlen_uptr.readValue(u32) catch {
                    _ = socket.close(new_sock_fd) catch {};
                    return error.EFAULT;
                };

                // Get the new socket's TCB to check remote address family
                const new_sock = socket.getSocket(new_sock_fd) orelse {
                    _ = socket.close(new_sock_fd) catch {};
                    return error.EBADF;
                };
                const tcb = new_sock.tcb orelse {
                    _ = socket.close(new_sock_fd) catch {};
                    return error.ENOTCONN;
                };

                // Determine family from TCB's remote_addr and fill appropriate structure
                switch (tcb.remote_addr) {
                    .v4 => |v4| {
                        // IPv4 connection
                        if (input_len < @sizeOf(socket.SockAddrIn)) {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EINVAL;
                        }

                        const kpeer_addr = socket.SockAddrIn.init(v4, tcb.remote_port);
                        user_mem.copyStructToUser(socket.SockAddrIn, user_mem.UserPtr.from(addr_ptr), kpeer_addr) catch {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EFAULT;
                        };

                        addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EFAULT;
                        };
                    },
                    .v6 => |v6| {
                        // IPv6 connection
                        if (input_len < @sizeOf(socket.SockAddrIn6)) {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EINVAL;
                        }

                        const kpeer_addr6 = socket.SockAddrIn6.init(v6, tcb.remote_port);
                        user_mem.copyStructToUser(socket.SockAddrIn6, user_mem.UserPtr.from(addr_ptr), kpeer_addr6) catch {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EFAULT;
                        };

                        addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn6))) catch {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EFAULT;
                        };
                    },
                    .none => {
                        // Should not happen for connected socket
                        _ = socket.close(new_sock_fd) catch {};
                        return error.ENOTCONN;
                    },
                }
            }

            const new_fd_num = installSocketFd(new_sock_fd, false) catch |err| {
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

/// sys_accept4 (288 on x86_64, 242 on aarch64) - Accept connection with flags
/// (fd, addr, addrlen_ptr, flags) -> fd
/// Like accept() but with a flags parameter for SOCK_CLOEXEC and SOCK_NONBLOCK.
pub fn sys_accept4(fd: usize, addr_ptr: usize, addrlen_ptr: usize, flags: usize) SyscallError!usize {
    init();

    // Extract flags
    const flags_u32 = std.math.cast(u32, flags) orelse return error.EINVAL;
    const is_cloexec = (flags_u32 & @as(u32, @intCast(socket.SOCK_CLOEXEC))) != 0;
    const is_nonblock = (flags_u32 & @as(u32, @intCast(socket.SOCK_NONBLOCK))) != 0;

    // Check for UNIX socket first
    if (getUnixSocketFullContext(fd)) |unix_ctx| {
        const listen_sock = unix_socket.getSocketByIdx(unix_ctx.data.socket_idx) orelse {
            return error.EBADF;
        };

        if (listen_sock.generation != unix_ctx.data.generation) {
            return error.EBADF;
        }

        // Get current process credentials for SO_PEERCRED
        const proc = base.getCurrentProcess();
        const result = unix_socket.acceptSocket(listen_sock, proc.pid, proc.euid, proc.egid) catch |err| {
            return unixSocketErrorToSyscallError(err);
        };

        // Handle SOCK_NONBLOCK on the new socket
        if (is_nonblock) {
            result.new_sock.blocking = false;
        }

        // Install FD for the new connected socket with cloexec flag
        const new_fd_num = installUnixSocketFullFd(result.new_idx, result.new_sock.generation, is_cloexec) catch |err| {
            unix_socket.closeSocket(result.new_sock);
            return err;
        };

        // Fill in peer address if requested (AF_UNIX returns unnamed address)
        if (addr_ptr != 0 and addrlen_ptr != 0) {
            const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
            const input_len = addrlen_uptr.readValue(u32) catch {
                return new_fd_num;
            };

            if (input_len >= 2) {
                const SockAddrUn = uapi.abi.SockAddrUn;
                var kaddr = SockAddrUn.init();
                const addr_uptr = user_mem.UserPtr.from(addr_ptr);
                const write_len = @min(input_len, @sizeOf(SockAddrUn));
                _ = addr_uptr.copyFromKernel(std.mem.asBytes(&kaddr)[0..write_len]) catch {};
                addrlen_uptr.writeValue(@as(u32, 2)) catch {};
            }
        }

        return new_fd_num;
    }

    // Network socket path
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    while (true) {
        const result = socket.accept(ctx.socket_idx, null);

        if (result) |new_sock_fd| {
            // Handle SOCK_NONBLOCK on the new socket
            if (is_nonblock) {
                if (socket.getSocket(new_sock_fd)) |new_sock| {
                    new_sock.blocking = false;
                }
            }

            // Fill in peer address if requested
            if (addr_ptr != 0 and addrlen_ptr != 0) {
                const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
                const input_len = addrlen_uptr.readValue(u32) catch {
                    _ = socket.close(new_sock_fd) catch {};
                    return error.EFAULT;
                };

                const new_sock = socket.getSocket(new_sock_fd) orelse {
                    _ = socket.close(new_sock_fd) catch {};
                    return error.EBADF;
                };
                const tcb = new_sock.tcb orelse {
                    _ = socket.close(new_sock_fd) catch {};
                    return error.ENOTCONN;
                };

                switch (tcb.remote_addr) {
                    .v4 => |v4| {
                        if (input_len < @sizeOf(socket.SockAddrIn)) {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EINVAL;
                        }
                        const kpeer_addr = socket.SockAddrIn.init(v4, tcb.remote_port);
                        user_mem.copyStructToUser(socket.SockAddrIn, user_mem.UserPtr.from(addr_ptr), kpeer_addr) catch {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EFAULT;
                        };
                        addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn))) catch {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EFAULT;
                        };
                    },
                    .v6 => |v6| {
                        if (input_len < @sizeOf(socket.SockAddrIn6)) {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EINVAL;
                        }
                        const kpeer_addr6 = socket.SockAddrIn6.init(v6, tcb.remote_port);
                        user_mem.copyStructToUser(socket.SockAddrIn6, user_mem.UserPtr.from(addr_ptr), kpeer_addr6) catch {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EFAULT;
                        };
                        addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn6))) catch {
                            _ = socket.close(new_sock_fd) catch {};
                            return error.EFAULT;
                        };
                    },
                    .none => {
                        _ = socket.close(new_sock_fd) catch {};
                        return error.ENOTCONN;
                    },
                }
            }

            const new_fd_num = installSocketFd(new_sock_fd, is_cloexec) catch |err| {
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
/// Supports AF_INET (IPv4), AF_INET6 (IPv6), and AF_UNIX
pub fn sys_connect(fd: usize, addr_ptr: usize, addrlen: usize) SyscallError!usize {
    init();

    // Need at least 2 bytes for address family
    if (addrlen < 2) {
        return error.EINVAL;
    }

    // Read address family first
    const family = user_mem.UserPtr.from(addr_ptr).readValue(u16) catch {
        return error.EFAULT;
    };

    // Handle AF_UNIX connect
    if (family == socket.AF_UNIX or family == socket.AF_LOCAL) {
        const unix_ctx = getUnixSocketFullContext(fd) orelse {
            return error.ENOTSOCK;
        };

        const sock = unix_socket.getSocketByIdx(unix_ctx.data.socket_idx) orelse {
            return error.EBADF;
        };

        if (sock.generation != unix_ctx.data.generation) {
            return error.EBADF;
        }

        // Read the sockaddr_un structure
        if (addrlen < 3) { // Need at least family + 1 byte of path
            return error.EINVAL;
        }

        const SockAddrUn = uapi.abi.SockAddrUn;
        const max_addr_len = @min(addrlen, @sizeOf(SockAddrUn));
        var kaddr: SockAddrUn = SockAddrUn.init();

        // Copy the address from user space
        const addr_bytes = std.mem.asBytes(&kaddr);
        const uptr = user_mem.UserPtr.from(addr_ptr);
        _ = uptr.copyToKernel(addr_bytes[0..max_addr_len]) catch {
            return error.EFAULT;
        };

        // Determine path and type
        const is_abstract = kaddr.isAbstract();
        const path_len = kaddr.pathLen(addrlen);

        if (path_len == 0) {
            return error.EINVAL;
        }

        // Get path slice (for abstract sockets, skip the leading null)
        const path: []const u8 = if (is_abstract)
            kaddr.sun_path[1..path_len]
        else
            kaddr.sun_path[0..path_len];

        // Get current process credentials for SO_PEERCRED
        const proc = base.getCurrentProcess();
        unix_socket.connectSocket(sock, path, is_abstract, proc.pid, proc.euid, proc.egid) catch |err| {
            return unixSocketErrorToSyscallError(err);
        };

        return 0;
    }

    // Network socket path
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    const net_sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    // Dispatch based on address family
    if (family == socket.AF_INET) {
        // IPv4 connect
        if (addrlen < @sizeOf(socket.SockAddrIn)) {
            return error.EINVAL;
        }

        const kaddr = user_mem.copyStructFromUser(socket.SockAddrIn, user_mem.UserPtr.from(addr_ptr)) catch {
            return error.EFAULT;
        };

        socket.connect(ctx.socket_idx, &kaddr) catch |err| {
            return socketErrorToSyscallError(err);
        };
    } else if (family == socket.AF_INET6) {
        // IPv6 connect
        if (addrlen < @sizeOf(socket.SockAddrIn6)) {
            return error.EINVAL;
        }

        const kaddr6 = user_mem.copyStructFromUser(socket.SockAddrIn6, user_mem.UserPtr.from(addr_ptr)) catch {
            return error.EFAULT;
        };

        socket.connect6(ctx.socket_idx, &kaddr6) catch |err| {
            return socketErrorToSyscallError(err);
        };
    } else {
        return error.EAFNOSUPPORT;
    }

    // Handle blocking for both IPv4 and IPv6
    if (net_sock.blocking) {
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
    const level_i32 = std.math.cast(i32, level) orelse return error.EINVAL;
    const optname_i32 = std.math.cast(i32, optname) orelse return error.EINVAL;

    // Check for UNIX socket SO_PEERCRED first
    if (level_i32 == socket.SOL_SOCKET and optname_i32 == socket.SO_PEERCRED) {
        if (getUnixSocketFullContext(fd)) |unix_ctx| {
            const sock = unix_socket.getSocketByIdx(unix_ctx.data.socket_idx) orelse {
                return error.EBADF;
            };

            if (sock.generation != unix_ctx.data.generation) {
                return error.EBADF;
            }

            // Get peer credentials
            const creds = unix_socket.getPeerCredentials(sock) catch |err| {
                return unixSocketErrorToSyscallError(err);
            };

            // Verify buffer size (socklen_t is u32 per Linux ABI)
            const optlen_uptr = user_mem.UserPtr.from(optlen_ptr);
            const koptlen: usize = optlen_uptr.readValue(u32) catch {
                return error.EFAULT;
            };

            const UCred = uapi.abi.UCred;
            if (koptlen < @sizeOf(UCred)) {
                return error.EINVAL;
            }

            if (!isValidUserAccess(optval_ptr, @sizeOf(UCred), AccessMode.Write)) {
                return error.EFAULT;
            }

            // Write UCred to user buffer
            const ucred = UCred{
                .pid = creds.pid,
                .uid = creds.uid,
                .gid = creds.gid,
            };

            const optval_uptr = user_mem.UserPtr.from(optval_ptr);
            optval_uptr.writeValue(ucred) catch {
                return error.EFAULT;
            };

            optlen_uptr.writeValue(@as(u32, @sizeOf(UCred))) catch {
                return error.EFAULT;
            };

            return 0;
        }
        // SO_PEERCRED only valid for AF_UNIX sockets
        return error.EINVAL;
    }

    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    // Linux ABI: optlen is socklen_t* (u32*), not usize*
    const optlen_uptr = user_mem.UserPtr.from(optlen_ptr);
    const koptlen_u32 = optlen_uptr.readValue(u32) catch {
        return error.EFAULT;
    };
    var koptlen: usize = koptlen_u32;

    if (koptlen > 0 and !isValidUserAccess(optval_ptr, koptlen, AccessMode.Write)) {
        return error.EFAULT;
    }

    const max_optlen: usize = 256;
    if (koptlen > max_optlen) {
        koptlen = max_optlen;
    }

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

    // Write back as u32 to match socklen_t ABI
    optlen_uptr.writeValue(@as(u32, @truncate(result_len))) catch {
        return error.EFAULT;
    };

    return 0;
}

// =============================================================================
// Shutdown and Address Query Syscalls
// =============================================================================

/// sys_shutdown (48) - Shut down part of a full-duplex connection
pub fn sys_shutdown(fd: usize, how: usize) SyscallError!usize {
    const how_i32 = std.math.cast(i32, how) orelse return error.EINVAL;
    if (how_i32 < 0 or how_i32 > 2) return error.EINVAL;

    // Check for socketpair handle (uses unix_socket_file_ops, not full_file_ops)
    if (getSocketpairHandle(fd)) |handle| {
        const pair = handle.pair;
        const held = pair.lock.acquire();
        if (handle.endpoint == 0) {
            if (how_i32 == unix_socket.SHUT_RD or how_i32 == unix_socket.SHUT_RDWR) {
                pair.read_shutdown_0 = true;
            }
            if (how_i32 == unix_socket.SHUT_WR or how_i32 == unix_socket.SHUT_RDWR) {
                pair.shutdown_0 = true;
                if (pair.blocked_reader_1) |t| {
                    pair.reader_1_woken.store(true, .release);
                    held.release();
                    sched.unblock(@ptrCast(@alignCast(t)));
                    return 0;
                }
            }
        } else {
            if (how_i32 == unix_socket.SHUT_RD or how_i32 == unix_socket.SHUT_RDWR) {
                pair.read_shutdown_1 = true;
            }
            if (how_i32 == unix_socket.SHUT_WR or how_i32 == unix_socket.SHUT_RDWR) {
                pair.shutdown_1 = true;
                if (pair.blocked_reader_0) |t| {
                    pair.reader_0_woken.store(true, .release);
                    held.release();
                    sched.unblock(@ptrCast(@alignCast(t)));
                    return 0;
                }
            }
        }
        held.release();
        return 0;
    }

    // Check for UNIX socket (full socket from socket() + connect())
    if (getUnixSocketFullContext(fd)) |unix_ctx| {
        const sock = unix_socket.getSocketByIdx(unix_ctx.data.socket_idx) orelse {
            return error.EBADF;
        };

        if (sock.generation != unix_ctx.data.generation) {
            return error.EBADF;
        }

        unix_socket.shutdownSocket(sock, how_i32) catch |err| {
            return unixSocketErrorToSyscallError(err);
        };

        return 0;
    }

    // Network socket path
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    socket.shutdown(ctx.socket_idx, how_i32) catch |err| {
        return socketErrorToSyscallError(err);
    };

    return 0;
}

/// sys_getsockname (51) - Get local socket address (dual-stack: IPv4, IPv6, and AF_UNIX)
pub fn sys_getsockname(fd: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
    const kaddrlen = addrlen_uptr.readValue(u32) catch {
        return error.EFAULT;
    };

    // Check for UNIX socket first
    if (getUnixSocketFullContext(fd)) |unix_ctx| {
        const sock = unix_socket.getSocketByIdx(unix_ctx.data.socket_idx) orelse {
            return error.EBADF;
        };

        if (sock.generation != unix_ctx.data.generation) {
            return error.EBADF;
        }

        const SockAddrUn = uapi.abi.SockAddrUn;
        if (kaddrlen < 2) {
            return error.EINVAL;
        }

        if (!isValidUserAccess(addr_ptr, @min(kaddrlen, @sizeOf(SockAddrUn)), AccessMode.Write)) {
            return error.EFAULT;
        }

        var kaddr: SockAddrUn = undefined;
        const actual_len = unix_socket.getsocknameSocket(sock, &kaddr);

        // Copy to user space (only as much as fits)
        const copy_len = @min(kaddrlen, actual_len);
        const addr_uptr = user_mem.UserPtr.from(addr_ptr);
        _ = addr_uptr.copyFromKernel(std.mem.asBytes(&kaddr)[0..copy_len]) catch {
            return error.EFAULT;
        };

        addrlen_uptr.writeValue(@as(u32, @intCast(actual_len))) catch {
            return error.EFAULT;
        };

        return 0;
    }

    // Network socket path
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    // Get socket to check address family
    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    if (sock.family == socket.AF_INET6) {
        // IPv6 path
        if (kaddrlen < @sizeOf(socket.SockAddrIn6)) {
            return error.EINVAL;
        }

        if (!isValidUserAccess(addr_ptr, @sizeOf(socket.SockAddrIn6), AccessMode.Write)) {
            return error.EFAULT;
        }

        var kaddr6: socket.SockAddrIn6 = std.mem.zeroes(socket.SockAddrIn6);

        socket.getsockname6(ctx.socket_idx, &kaddr6) catch |err| {
            return socketErrorToSyscallError(err);
        };

        const addr_uptr = user_mem.UserPtr.from(addr_ptr);
        addr_uptr.writeValue(kaddr6) catch {
            return error.EFAULT;
        };

        addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn6))) catch {
            return error.EFAULT;
        };
    } else {
        // IPv4 path (default)
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
    }

    return 0;
}

/// sys_getpeername (52) - Get peer socket address (dual-stack: IPv4, IPv6, and AF_UNIX)
pub fn sys_getpeername(fd: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    const addrlen_uptr = user_mem.UserPtr.from(addrlen_ptr);
    const kaddrlen = addrlen_uptr.readValue(u32) catch {
        return error.EFAULT;
    };

    // Check for UNIX socket first
    if (getUnixSocketFullContext(fd)) |unix_ctx| {
        const sock = unix_socket.getSocketByIdx(unix_ctx.data.socket_idx) orelse {
            return error.EBADF;
        };

        if (sock.generation != unix_ctx.data.generation) {
            return error.EBADF;
        }

        const SockAddrUn = uapi.abi.SockAddrUn;
        if (kaddrlen < 2) {
            return error.EINVAL;
        }

        if (!isValidUserAccess(addr_ptr, @min(kaddrlen, @sizeOf(SockAddrUn)), AccessMode.Write)) {
            return error.EFAULT;
        }

        var kaddr: SockAddrUn = undefined;
        const actual_len = unix_socket.getpeernameSocket(sock, &kaddr) catch |err| {
            return unixSocketErrorToSyscallError(err);
        };

        // Copy to user space (only as much as fits)
        const copy_len = @min(kaddrlen, actual_len);
        const addr_uptr = user_mem.UserPtr.from(addr_ptr);
        _ = addr_uptr.copyFromKernel(std.mem.asBytes(&kaddr)[0..copy_len]) catch {
            return error.EFAULT;
        };

        addrlen_uptr.writeValue(@as(u32, @intCast(actual_len))) catch {
            return error.EFAULT;
        };

        return 0;
    }

    // Network socket path
    const ctx = getSocketContext(fd) orelse {
        return error.ENOTSOCK;
    };

    // Get socket to check address family
    const sock = socket.getSocket(ctx.socket_idx) orelse {
        return error.EBADF;
    };

    if (sock.family == socket.AF_INET6) {
        // IPv6 path
        if (kaddrlen < @sizeOf(socket.SockAddrIn6)) {
            return error.EINVAL;
        }

        if (!isValidUserAccess(addr_ptr, @sizeOf(socket.SockAddrIn6), AccessMode.Write)) {
            return error.EFAULT;
        }

        var kaddr6: socket.SockAddrIn6 = std.mem.zeroes(socket.SockAddrIn6);

        socket.getpeername6(ctx.socket_idx, &kaddr6) catch |err| {
            return socketErrorToSyscallError(err);
        };

        const addr_uptr = user_mem.UserPtr.from(addr_ptr);
        addr_uptr.writeValue(kaddr6) catch {
            return error.EFAULT;
        };

        addrlen_uptr.writeValue(@as(u32, @sizeOf(socket.SockAddrIn6))) catch {
            return error.EFAULT;
        };
    } else {
        // IPv4 path (default)
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
    }

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
/// Supports SCM_RIGHTS ancillary data for passing FDs over UNIX sockets
pub fn sys_sendmsg(fd: usize, msg_ptr: usize, flags: usize) SyscallError!usize {
    return msg_mod.sys_sendmsg(
        fd,
        msg_ptr,
        flags,
        &socket_file_ops,
        &unix_socket_file_ops,
        &unix_socket_full_file_ops,
    );
}

/// sys_recvmsg (47) - Receive a message from a socket with scatter/gather I/O
/// Supports SCM_RIGHTS ancillary data for receiving FDs over UNIX sockets
pub fn sys_recvmsg(fd: usize, msg_ptr: usize, flags: usize) SyscallError!usize {
    return msg_mod.sys_recvmsg(
        fd,
        msg_ptr,
        flags,
        &socket_file_ops,
        &unix_socket_file_ops,
        &unix_socket_full_file_ops,
    );
}

// =============================================================================
// Network Interface Configuration (delegated to netif.zig)
// =============================================================================

const netif_mod = @import("netif.zig");

/// sys_netif_config (1060) - Configure network interface
/// See netif.zig for implementation details
pub const sys_netif_config = netif_mod.sys_netif_config;

// =============================================================================
// ARP Syscalls (delegated to arp.zig)
// =============================================================================

const arp_mod = @import("arp.zig");

/// sys_arp_probe (1061) - ARP probe for IP conflict detection (RFC 5227)
/// See arp.zig for implementation details
pub const sys_arp_probe = arp_mod.sys_arp_probe;

/// sys_arp_announce (1062) - Gratuitous ARP announcement (RFC 5227)
/// See arp.zig for implementation details
pub const sys_arp_announce = arp_mod.sys_arp_announce;

// =============================================================================
// UNIX Domain Socket Syscalls
// =============================================================================

const unix_socket = socket.unix_socket;

// =============================================================================
// Full UNIX Domain Socket Support (bind/listen/accept/connect)
// =============================================================================

/// FD private data for full UNIX sockets (created via socket(AF_UNIX))
const UnixSocketFullFdData = struct {
    socket_idx: usize,
    generation: u32,
};

/// File operations for full UNIX sockets
const unix_socket_full_file_ops = fd_mod.FileOps{
    .read = unixSocketFullRead,
    .write = unixSocketFullWrite,
    .close = unixSocketFullClose,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = unixSocketFullPoll,
    .truncate = null,
};

/// Get full UNIX socket data from FD
fn getUnixSocketFullData(fd: *fd_mod.FileDescriptor) ?*UnixSocketFullFdData {
    if (fd.ops != &unix_socket_full_file_ops) {
        return null;
    }
    const data_ptr = fd.private_data orelse return null;
    return @ptrCast(@alignCast(data_ptr));
}

/// Get full UNIX socket context from FD number
fn getUnixSocketFullContext(fd_num: usize) ?struct { fd: *fd_mod.FileDescriptor, data: *UnixSocketFullFdData } {
    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, fd_num) orelse return null;
    const fd = table.get(fd_u32) orelse return null;
    const data = getUnixSocketFullData(fd) orelse return null;
    return .{ .fd = fd, .data = data };
}

/// Get socketpair handle from FD number (socketpair FDs use unix_socket_file_ops)
fn getSocketpairHandle(fd_num: usize) ?*unix_socket.UnixSocketHandle {
    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, fd_num) orelse return null;
    const fd = table.get(fd_u32) orelse return null;
    if (fd.ops != &unix_socket_file_ops) return null;
    const data_ptr = fd.private_data orelse return null;
    return @ptrCast(@alignCast(data_ptr));
}

/// Check if FD is a full UNIX socket
fn isUnixSocketFullFd(fd_num: usize) bool {
    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, fd_num) orelse return false;
    const fd = table.get(fd_u32) orelse return false;
    return fd.ops == &unix_socket_full_file_ops;
}

/// Install a full UNIX socket FD
fn installUnixSocketFullFd(socket_idx: usize, generation: u32, cloexec: bool) SyscallError!usize {
    const data = heap.allocator().create(UnixSocketFullFdData) catch {
        return error.ENOMEM;
    };
    data.* = .{ .socket_idx = socket_idx, .generation = generation };
    errdefer heap.allocator().destroy(data);

    const fd = fd_mod.createFd(&unix_socket_full_file_ops, fd_mod.O_RDWR, data) catch {
        return error.ENOMEM;
    };
    fd.cloexec = cloexec;
    errdefer heap.allocator().destroy(fd);

    const table = base.getGlobalFdTable();
    const fd_num = table.allocAndInstall(fd) orelse {
        return error.EMFILE;
    };
    return fd_num;
}

/// Read from full UNIX socket
fn unixSocketFullRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    const data = getUnixSocketFullData(fd) orelse {
        return Errno.EBADF.toReturn();
    };

    const sock = unix_socket.getSocketByIdx(data.socket_idx) orelse {
        return Errno.EBADF.toReturn();
    };

    // Verify generation to prevent stale access
    if (sock.generation != data.generation) {
        return Errno.EBADF.toReturn();
    }

    return unix_socket.readSocket(sock, buf);
}

/// Write to full UNIX socket
fn unixSocketFullWrite(fd: *fd_mod.FileDescriptor, data_buf: []const u8) isize {
    const data = getUnixSocketFullData(fd) orelse {
        return Errno.EBADF.toReturn();
    };

    const sock = unix_socket.getSocketByIdx(data.socket_idx) orelse {
        return Errno.EBADF.toReturn();
    };

    if (sock.generation != data.generation) {
        return Errno.EBADF.toReturn();
    }

    return unix_socket.writeSocket(sock, data_buf);
}

/// Close full UNIX socket
fn unixSocketFullClose(fd: *fd_mod.FileDescriptor) isize {
    const data = getUnixSocketFullData(fd) orelse {
        return Errno.EBADF.toReturn();
    };

    const sock = unix_socket.getSocketByIdx(data.socket_idx) orelse {
        heap.allocator().destroy(data);
        return 0;
    };

    if (sock.generation == data.generation) {
        unix_socket.closeSocket(sock);
    }

    heap.allocator().destroy(data);
    return 0;
}

/// Poll full UNIX socket
fn unixSocketFullPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    const data = getUnixSocketFullData(fd) orelse return 0;
    const sock = unix_socket.getSocketByIdx(data.socket_idx) orelse return 0;

    if (sock.generation != data.generation) return 0;

    return unix_socket.pollSocket(sock, requested_events);
}

/// Convert UnixSocketError to SyscallError
fn unixSocketErrorToSyscallError(err: unix_socket.UnixSocketError) SyscallError {
    return switch (err) {
        unix_socket.UnixSocketError.InvalidArg => error.EINVAL,
        unix_socket.UnixSocketError.AddressInUse => error.EADDRINUSE,
        unix_socket.UnixSocketError.NoMemory => error.ENOMEM,
        unix_socket.UnixSocketError.NoSpace => error.ENOSPC,
        unix_socket.UnixSocketError.NotSupported => error.ENOTSOCK, // EOPNOTSUPP not in SyscallError
        unix_socket.UnixSocketError.WouldBlock => error.EAGAIN,
        unix_socket.UnixSocketError.ConnectionRefused => error.ECONNREFUSED,
        unix_socket.UnixSocketError.AlreadyConnected => error.EISCONN,
        unix_socket.UnixSocketError.NotConnected => error.ENOTCONN,
        unix_socket.UnixSocketError.BadState => error.EINVAL,
    };
}

// =============================================================================
// Socketpair UNIX Socket Support (existing)
// =============================================================================

/// Unix socket file operations
const unix_socket_file_ops = fd_mod.FileOps{
    .read = unixSocketRead,
    .write = unixSocketWrite,
    .close = unixSocketClose,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = unixSocketPoll,
    .truncate = null,
};

/// Read from unix socket
fn unixSocketRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    const handle: *unix_socket.UnixSocketHandle = @ptrCast(@alignCast(fd.private_data));
    const pair = handle.pair;

    while (true) {
        const held = pair.lock.acquire();

        // Check for data
        const bytes_read = pair.read(handle.endpoint, buf);
        if (bytes_read > 0) {
            held.release();
            return @intCast(bytes_read);
        }

        // No data - check if peer is closed or our read side is shut down
        if (pair.isPeerClosed(handle.endpoint) or pair.isReadShutdown(handle.endpoint)) {
            held.release();
            return 0; // EOF
        }

        // Non-blocking mode
        if (!handle.blocking or (fd.flags & fd_mod.O_NONBLOCK) != 0) {
            held.release();
            return Errno.EAGAIN.toReturn();
        }

        // Block waiting for data
        const current = sched.getCurrentThread() orelse {
            held.release();
            return Errno.EAGAIN.toReturn();
        };

        // Set up blocking (cast to *anyopaque for storage in unix_socket)
        if (handle.endpoint == 0) {
            pair.blocked_reader_0 = @ptrCast(current);
            pair.reader_0_woken.store(false, .release);
        } else {
            pair.blocked_reader_1 = @ptrCast(current);
            pair.reader_1_woken.store(false, .release);
        }

        held.release();

        // Check woken flag before blocking (SMP race prevention)
        const woken = if (handle.endpoint == 0)
            pair.reader_0_woken.load(.acquire)
        else
            pair.reader_1_woken.load(.acquire);

        if (!woken) {
            sched.block();
        }

        // Clear blocked thread pointer
        const held2 = pair.lock.acquire();
        if (handle.endpoint == 0) {
            pair.blocked_reader_0 = null;
        } else {
            pair.blocked_reader_1 = null;
        }
        held2.release();

        // Loop back to try reading again
    }
}

/// Write to unix socket
fn unixSocketWrite(fd: *fd_mod.FileDescriptor, data: []const u8) isize {
    const handle: *unix_socket.UnixSocketHandle = @ptrCast(@alignCast(fd.private_data));
    const pair = handle.pair;

    const held = pair.lock.acquire();
    defer held.release();

    // Check if peer is closed
    if (pair.isPeerClosed(handle.endpoint)) {
        return Errno.EPIPE.toReturn();
    }

    // Write data
    const written = pair.write(handle.endpoint, data);

    // Wake peer if blocked (cast back from *anyopaque to *Thread)
    if (handle.endpoint == 0) {
        if (pair.blocked_reader_1) |t| {
            pair.reader_1_woken.store(true, .release);
            sched.unblock(@ptrCast(@alignCast(t)));
        }
    } else {
        if (pair.blocked_reader_0) |t| {
            pair.reader_0_woken.store(true, .release);
            sched.unblock(@ptrCast(@alignCast(t)));
        }
    }

    if (written == 0 and (!handle.blocking or (fd.flags & fd_mod.O_NONBLOCK) != 0)) {
        return Errno.EAGAIN.toReturn();
    }

    return @intCast(written);
}

/// Close unix socket endpoint
fn unixSocketClose(fd: *fd_mod.FileDescriptor) isize {
    const handle: *unix_socket.UnixSocketHandle = @ptrCast(@alignCast(fd.private_data));
    unix_socket.releasePair(handle.pair, handle.endpoint);

    // Free the handle
    heap.allocator().destroy(handle);
    return 0;
}

/// Poll unix socket for events
fn unixSocketPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    const handle: *unix_socket.UnixSocketHandle = @ptrCast(@alignCast(fd.private_data));
    const pair = handle.pair;
    _ = requested_events; // We report all relevant events

    var events: u32 = 0;

    const held = pair.lock.acquire();
    defer held.release();

    // Check if readable
    if (pair.hasData(handle.endpoint) or pair.isPeerClosed(handle.endpoint)) {
        events |= 0x0001; // POLLIN
    }

    // Check if writable
    if (pair.writeSpace(handle.endpoint) > 0 and !pair.isPeerClosed(handle.endpoint)) {
        events |= 0x0004; // POLLOUT
    }

    // Check for hangup (peer closed)
    if (pair.isPeerClosed(handle.endpoint)) {
        events |= 0x0010; // POLLHUP
    }

    return events;
}

/// sys_socketpair (53 on x86_64, 199 on aarch64) - Create a pair of connected sockets
/// (domain, type, protocol, sv) -> int
///
/// Creates two connected anonymous sockets for local IPC.
/// Only AF_UNIX domain is supported. Protocol must be 0.
/// sv is a pointer to an array of two integers that will receive the file descriptors.
/// Supports SOCK_NONBLOCK and SOCK_CLOEXEC flags ORed with the type.
pub fn sys_socketpair(domain: usize, sock_type: usize, protocol: usize, sv_ptr: usize) SyscallError!usize {
    // Validate domain is AF_UNIX
    if (domain != socket.AF_UNIX and domain != socket.AF_LOCAL) {
        return error.EAFNOSUPPORT;
    }

    // Protocol must be 0 for AF_UNIX
    if (protocol != 0) {
        return error.EPROTONOSUPPORT;
    }

    // Validate sv_ptr points to writable memory for 2 i32s
    const sv_size = 2 * @sizeOf(i32);
    if (!isValidUserAccess(sv_ptr, sv_size, AccessMode.Write)) {
        return error.EFAULT;
    }

    // Extract flags from sock_type (use u32 because SOCK_CLOEXEC is 0x80000)
    const sock_type_u32 = std.math.cast(u32, sock_type) orelse return error.EINVAL;
    const sock_type_i32: i32 = @intCast(sock_type_u32 & 0xFFFF); // Lower bits for type + NONBLOCK
    const is_cloexec = (sock_type_u32 & @as(u32, @intCast(socket.SOCK_CLOEXEC))) != 0;

    // Validate socket type
    if (!unix_socket.validateSocketType(sock_type_i32)) {
        return error.EINVAL;
    }

    // Allocate the socket pair
    const pair = unix_socket.allocatePair(sock_type_i32 & 0xFF) orelse return error.ENOMEM;
    errdefer {
        pair.allocated = false;
    }

    // Allocate handles for both endpoints
    const handle0 = heap.allocator().create(unix_socket.UnixSocketHandle) catch return error.ENOMEM;
    errdefer heap.allocator().destroy(handle0);

    const handle1 = heap.allocator().create(unix_socket.UnixSocketHandle) catch return error.ENOMEM;
    errdefer heap.allocator().destroy(handle1);

    // Set up handles
    const is_nonblocking = unix_socket.isNonBlocking(sock_type_i32);
    handle0.* = .{
        .pair = pair,
        .endpoint = 0,
        .blocking = !is_nonblocking,
    };

    handle1.* = .{
        .pair = pair,
        .endpoint = 1,
        .blocking = !is_nonblocking,
    };

    // Get the FD table for the current process
    const table = base.getGlobalFdTable();

    // Create file descriptors for both endpoints
    const fd0 = fd_mod.createFd(&unix_socket_file_ops, fd_mod.O_RDWR, handle0) catch {
        heap.allocator().destroy(handle0);
        heap.allocator().destroy(handle1);
        pair.allocated = false;
        return error.ENOMEM;
    };
    fd0.cloexec = is_cloexec;
    errdefer heap.allocator().destroy(fd0);

    const fd0_num = table.allocAndInstall(fd0) orelse {
        heap.allocator().destroy(fd0);
        heap.allocator().destroy(handle0);
        heap.allocator().destroy(handle1);
        pair.allocated = false;
        return error.EMFILE;
    };
    errdefer {
        _ = table.close(fd0_num);
    }

    const fd1 = fd_mod.createFd(&unix_socket_file_ops, fd_mod.O_RDWR, handle1) catch {
        _ = table.close(fd0_num);
        heap.allocator().destroy(handle1);
        pair.allocated = false;
        return error.ENOMEM;
    };
    fd1.cloexec = is_cloexec;

    const fd1_num = table.allocAndInstall(fd1) orelse {
        heap.allocator().destroy(fd1);
        _ = table.close(fd0_num);
        heap.allocator().destroy(handle1);
        pair.allocated = false;
        return error.EMFILE;
    };

    // Copy the file descriptors to user space
    var fds: [2]i32 = .{ @intCast(fd0_num), @intCast(fd1_num) };
    const sv_uptr = user_mem.UserPtr.from(sv_ptr);
    _ = sv_uptr.copyFromKernel(std.mem.sliceAsBytes(&fds)) catch {
        // Clean up on failure
        _ = table.close(fd1_num);
        _ = table.close(fd0_num);
        return error.EFAULT;
    };

    return 0;
}
