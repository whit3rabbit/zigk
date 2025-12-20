const std = @import("std");
const primitive = @import("primitive.zig");
const uapi = primitive.uapi;
const syscalls = uapi.syscalls;

pub const SyscallError = primitive.SyscallError;

// =============================================================================
// Socket Operations (sys_socket, sys_bind, sys_sendto, sys_recvfrom)
// =============================================================================

/// Address family constants
pub const AF_INET: i32 = 2;

/// Socket type constants
pub const SOCK_STREAM: i32 = 1; // TCP
pub const SOCK_DGRAM: i32 = 2; // UDP

/// Socket address structure (IPv4)
/// Compatible with Linux sockaddr_in
pub const SockAddrIn = extern struct {
    family: u16, // AF_INET
    port: u16, // Network byte order
    addr: u32, // Network byte order
    zero: [8]u8, // Padding

    /// Create sockaddr from IP (host order) and port (host order)
    pub fn init(ip: u32, port_host: u16) SockAddrIn {
        return .{
            .family = @as(u16, @intCast(AF_INET)),
            .port = @byteSwap(port_host),
            .addr = @byteSwap(ip),
            .zero = [_]u8{0} ** 8,
        };
    }

    /// Get port in host byte order
    pub fn getPort(self: *const SockAddrIn) u16 {
        return @byteSwap(self.port);
    }

    /// Get address in host byte order
    pub fn getAddr(self: *const SockAddrIn) u32 {
        return @byteSwap(self.addr);
    }
};

/// Create a socket
/// Returns socket file descriptor (>= 3) or error
pub fn socket(domain: i32, sock_type: i32, protocol: i32) SyscallError!i32 {
    const ret = primitive.syscall3(
        syscalls.SYS_SOCKET,
        @bitCast(@as(isize, domain)),
        @bitCast(@as(isize, sock_type)),
        @bitCast(@as(isize, protocol)),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Bind socket to local address
pub fn bind(fd: i32, addr: *const SockAddrIn) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_BIND,
        @bitCast(@as(isize, fd)),
        @intFromPtr(addr),
        @sizeOf(SockAddrIn),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Send data on socket to destination
/// Returns number of bytes sent
pub fn sendto(fd: i32, buf: []const u8, dest_addr: *const SockAddrIn) SyscallError!usize {
    const ret = primitive.syscall6(
        syscalls.SYS_SENDTO,
        @bitCast(@as(isize, fd)),
        @intFromPtr(buf.ptr),
        buf.len,
        0, // flags
        @intFromPtr(dest_addr),
        @sizeOf(SockAddrIn),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Receive data from socket
/// Returns number of bytes received
/// src_addr is filled with sender's address if non-null
pub fn recvfrom(fd: i32, buf: []u8, src_addr: ?*SockAddrIn) SyscallError!usize {
    var addrlen: u32 = @sizeOf(SockAddrIn);
    const src_addr_ptr: usize = if (src_addr) |a| @intFromPtr(a) else 0;
    const addrlen_ptr: usize = if (src_addr != null) @intFromPtr(&addrlen) else 0;

    const ret = primitive.syscall6(
        syscalls.SYS_RECVFROM,
        @bitCast(@as(isize, fd)),
        @intFromPtr(buf.ptr),
        buf.len,
        0, // flags
        src_addr_ptr,
        addrlen_ptr,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Listen for connections on a socket
pub fn listen(fd: i32, backlog: i32) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_LISTEN, @bitCast(@as(isize, fd)), @bitCast(@as(isize, backlog)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Accept a connection on a socket
/// Returns new file descriptor for the connection
pub fn accept(fd: i32, addr: ?*SockAddrIn) SyscallError!i32 {
    var addrlen: u32 = @sizeOf(SockAddrIn);
    const addr_ptr: usize = if (addr) |a| @intFromPtr(a) else 0;
    const addrlen_ptr: usize = if (addr != null) @intFromPtr(&addrlen) else 0;
    
    const ret = primitive.syscall3(syscalls.SYS_ACCEPT, @bitCast(@as(isize, fd)), addr_ptr, addrlen_ptr);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Initiate a connection on a socket
pub fn connect(fd: i32, addr: *const SockAddrIn) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_CONNECT, 
        @bitCast(@as(isize, fd)), 
        @intFromPtr(addr), 
        @sizeOf(SockAddrIn)
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Shut down part of a full-duplex connection
/// how: 0=SHUT_RD, 1=SHUT_WR, 2=SHUT_RDWR
pub fn shutdown(fd: i32, how: i32) SyscallError!void {
     const ret = primitive.syscall2(syscalls.SYS_SHUTDOWN, @bitCast(@as(isize, fd)), @bitCast(@as(isize, how)));
     if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Parse dotted-decimal IP string to u32 (host byte order)
pub fn parseIp(str: []const u8) ?u32 {
    var ip: u32 = 0;
    var octet: u32 = 0;
    var dot_count: usize = 0;

    for (str) |c| {
        if (c >= '0' and c <= '9') {
            // Use overflow-detecting arithmetic to prevent wrap-around
            const mul_result = @mulWithOverflow(octet, 10);
            if (mul_result[1] != 0) return null;
            const add_result = @addWithOverflow(mul_result[0], c - '0');
            if (add_result[1] != 0) return null;
            octet = add_result[0];
            if (octet > 255) return null;
        } else if (c == '.') {
            ip = (ip << 8) | octet;
            octet = 0;
            dot_count += 1;
            if (dot_count > 3) return null;
        } else {
            return null;
        }
    }

    if (dot_count != 3) return null;
    ip = (ip << 8) | octet;
    return ip;
}
