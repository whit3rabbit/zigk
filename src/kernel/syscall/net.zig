// Network Syscall Handlers
//
// Implements socket-related syscalls for userland networking.
// Uses the kernel's socket layer to provide BSD-style socket API.

const uapi = @import("uapi");
const net = @import("net");
const socket = net.transport.socket;
const Errno = uapi.errno.Errno;

/// Userspace address range boundaries (same as handlers.zig)
const USER_SPACE_START: u64 = 0x0000_0000_0040_0000;
const USER_SPACE_END: u64 = 0x0000_7FFF_FFFF_FFFF;

/// Validate user pointer
fn isValidUserPtr(ptr: usize, len: usize) bool {
    if (ptr == 0) return false;
    if (ptr < USER_SPACE_START or ptr > USER_SPACE_END) return false;
    const end_addr = @addWithOverflow(ptr, len);
    if (end_addr[1] != 0) return false;
    if (end_addr[0] > USER_SPACE_END) return false;
    return true;
}

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

    // Validate buffer
    if (!isValidUserPtr(buf_ptr, len)) {
        return Errno.EFAULT.toReturn();
    }

    // Validate destination address
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

    // Validate buffer
    if (!isValidUserPtr(buf_ptr, len)) {
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
