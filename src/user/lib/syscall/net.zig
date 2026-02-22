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
pub const AF_INET6: i32 = 10;
pub const AF_UNIX: i32 = 1;
pub const AF_LOCAL: i32 = 1;  // Alias for AF_UNIX

/// Socket option levels
pub const SOL_SOCKET: i32 = 1;
pub const IPPROTO_IP: i32 = 0;
pub const IPPROTO_TCP: i32 = 6;
pub const IPPROTO_IPV6: i32 = 41;

/// IPPROTO_IPV6 options
pub const IPV6_JOIN_GROUP: i32 = 20;
pub const IPV6_LEAVE_GROUP: i32 = 21;
pub const IPV6_MULTICAST_HOPS: i32 = 18;

/// Message flags (for recv/recvfrom flags parameter)
pub const MSG_PEEK: u32 = 0x0002;
pub const MSG_DONTWAIT: u32 = 0x0040;
pub const MSG_WAITALL: u32 = 0x0100;
pub const MSG_NOSIGNAL: u32 = 0x4000;

/// Socket type constants
pub const SOCK_STREAM: i32 = 1; // TCP
pub const SOCK_DGRAM: i32 = 2; // UDP
pub const SOCK_RAW: i32 = 3; // Raw socket
pub const SOCK_NONBLOCK: i32 = 0x800;
pub const SOCK_CLOEXEC: i32 = 0x80000;

/// Protocol constants
pub const IPPROTO_ICMP: i32 = 1;

/// Additional socket options
pub const SO_REUSEPORT: i32 = 15;
pub const SO_RCVTIMEO: i32 = 20;

/// Socket shutdown constants
pub const SHUT_RD: i32 = 0;
pub const SHUT_WR: i32 = 1;
pub const SHUT_RDWR: i32 = 2;

/// Socket options
pub const SO_REUSEADDR: i32 = 2;
pub const SOL_SOCKET_LEVEL: i32 = 1; // Keep existing SOL_SOCKET as alias

/// Ancillary data constants
pub const SCM_RIGHTS: i32 = 1;

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

/// Socket address structure (IPv6)
/// Compatible with Linux sockaddr_in6 (28 bytes)
pub const SockAddrIn6 = extern struct {
    family: u16, // AF_INET6
    port: u16, // Network byte order
    flowinfo: u32, // Flow label
    addr: [16]u8, // IPv6 address (network byte order)
    scope_id: u32, // Scope ID

    /// Create sockaddr from IPv6 address and port (host order)
    pub fn init(ip: [16]u8, port_host: u16) SockAddrIn6 {
        return .{
            .family = @as(u16, @intCast(AF_INET6)),
            .port = @byteSwap(port_host),
            .flowinfo = 0,
            .addr = ip,
            .scope_id = 0,
        };
    }

    /// Get port in host byte order
    pub fn getPort(self: *const SockAddrIn6) u16 {
        return @byteSwap(self.port);
    }

    comptime {
        if (@sizeOf(@This()) != 28) {
            @compileError("SockAddrIn6 must be 28 bytes");
        }
    }
};

/// IPv6 multicast request structure
/// Used with IPV6_JOIN_GROUP/IPV6_LEAVE_GROUP (20 bytes)
pub const Ipv6Mreq = extern struct {
    ipv6mr_multiaddr: [16]u8, // IPv6 multicast address
    ipv6mr_interface: u32, // Interface index

    pub fn init(multiaddr: [16]u8, iface_idx: u32) Ipv6Mreq {
        return .{
            .ipv6mr_multiaddr = multiaddr,
            .ipv6mr_interface = iface_idx,
        };
    }

    comptime {
        if (@sizeOf(@This()) != 20) {
            @compileError("Ipv6Mreq must be 20 bytes");
        }
    }
};

/// Message header for sendmsg/recvmsg (Linux-compatible)
pub const MsgHdr = extern struct {
    msg_name: usize,        // Optional address (sendto/recvfrom dest/src)
    msg_namelen: u32,       // Size of address
    _pad0: u32 = 0,         // Padding for alignment on 64-bit
    msg_iov: usize,         // Scatter/gather array (pointer to Iovec array)
    msg_iovlen: usize,      // Number of iovecs
    msg_control: usize,     // Ancillary data (pointer to cmsghdr)
    msg_controllen: usize,  // Ancillary data buffer length
    msg_flags: i32,         // Flags on received message
    _pad1: u32 = 0,
};

/// Control message header for ancillary data
pub const CmsgHdr = extern struct {
    cmsg_len: usize,   // Data byte count including header
    cmsg_level: i32,    // Originating protocol
    cmsg_type: i32,     // Protocol-specific type
};

/// I/O vector for scatter-gather operations
pub const MsgIovec = extern struct {
    iov_base: usize,   // Starting address
    iov_len: usize,    // Number of bytes
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

/// Send data on socket to destination with explicit flags (e.g., MSG_NOSIGNAL)
/// Returns number of bytes sent
pub fn sendtoFlags(fd: i32, buf: []const u8, flags: u32, dest_addr: *const SockAddrIn) SyscallError!usize {
    const ret = primitive.syscall6(
        syscalls.SYS_SENDTO,
        @bitCast(@as(isize, fd)),
        @intFromPtr(buf.ptr),
        buf.len,
        @as(usize, flags),
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

/// Receive data from socket with explicit flags parameter.
/// Supports MSG_PEEK (inspect without consuming) and MSG_DONTWAIT (non-blocking).
/// Returns number of bytes received.
/// src_addr is filled with sender's address if non-null.
pub fn recvfromFlags(fd: i32, buf: []u8, flags: u32, src_addr: ?*SockAddrIn) SyscallError!usize {
    var addrlen: u32 = @sizeOf(SockAddrIn);
    const src_addr_ptr: usize = if (src_addr) |a| @intFromPtr(a) else 0;
    const addrlen_ptr: usize = if (src_addr != null) @intFromPtr(&addrlen) else 0;

    const ret = primitive.syscall6(
        syscalls.SYS_RECVFROM,
        @bitCast(@as(isize, fd)),
        @intFromPtr(buf.ptr),
        buf.len,
        @as(usize, flags),
        src_addr_ptr,
        addrlen_ptr,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// =============================================================================
// IPv6 Socket Operations
// =============================================================================

/// Bind socket to IPv6 local address
pub fn bind6(fd: i32, addr: *const SockAddrIn6) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_BIND,
        @bitCast(@as(isize, fd)),
        @intFromPtr(addr),
        @sizeOf(SockAddrIn6),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Send data on socket to IPv6 destination
/// Returns number of bytes sent
pub fn sendto6(fd: i32, buf: []const u8, dest_addr: *const SockAddrIn6) SyscallError!usize {
    const ret = primitive.syscall6(
        syscalls.SYS_SENDTO,
        @bitCast(@as(isize, fd)),
        @intFromPtr(buf.ptr),
        buf.len,
        0, // flags
        @intFromPtr(dest_addr),
        @sizeOf(SockAddrIn6),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Receive data from socket with IPv6 source address
/// Returns number of bytes received
/// src_addr is filled with sender's address if non-null
pub fn recvfrom6(fd: i32, buf: []u8, src_addr: ?*SockAddrIn6) SyscallError!usize {
    var addrlen: u32 = @sizeOf(SockAddrIn6);
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

/// Receive data from IPv6 socket with explicit flags parameter.
/// Supports MSG_PEEK (inspect without consuming) and MSG_DONTWAIT (non-blocking).
/// Returns number of bytes received.
pub fn recvfrom6Flags(fd: i32, buf: []u8, flags: u32, src_addr: ?*SockAddrIn6) SyscallError!usize {
    var addrlen: u32 = @sizeOf(SockAddrIn6);
    const src_addr_ptr: usize = if (src_addr) |a| @intFromPtr(a) else 0;
    const addrlen_ptr: usize = if (src_addr != null) @intFromPtr(&addrlen) else 0;

    const ret = primitive.syscall6(
        syscalls.SYS_RECVFROM,
        @bitCast(@as(isize, fd)),
        @intFromPtr(buf.ptr),
        buf.len,
        @as(usize, flags),
        src_addr_ptr,
        addrlen_ptr,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// =============================================================================
// Socket Options
// =============================================================================

/// Set socket option
pub fn setsockopt(fd: i32, level: i32, optname: i32, optval: []const u8) SyscallError!void {
    const ret = primitive.syscall5(
        syscalls.SYS_SETSOCKOPT,
        @bitCast(@as(isize, fd)),
        @bitCast(@as(isize, level)),
        @bitCast(@as(isize, optname)),
        @intFromPtr(optval.ptr),
        optval.len,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get socket option
pub fn getsockopt(fd: i32, level: i32, optname: i32, optval: []u8) SyscallError!usize {
    var optlen: u32 = @truncate(optval.len);
    const ret = primitive.syscall5(
        syscalls.SYS_GETSOCKOPT,
        @bitCast(@as(isize, fd)),
        @bitCast(@as(isize, level)),
        @bitCast(@as(isize, optname)),
        @intFromPtr(optval.ptr),
        @intFromPtr(&optlen),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return optlen;
}

/// Join IPv6 multicast group
/// For DHCPv6: joinMulticastGroup6(fd, ALL_DHCP_SERVERS, 0)
/// ALL_DHCP_SERVERS = ff02::1:2
pub fn joinMulticastGroup6(fd: i32, group_addr: [16]u8, iface_idx: u32) SyscallError!void {
    const mreq = Ipv6Mreq.init(group_addr, iface_idx);
    const mreq_bytes = std.mem.asBytes(&mreq);
    return setsockopt(fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, mreq_bytes);
}

/// Leave IPv6 multicast group
pub fn leaveMulticastGroup6(fd: i32, group_addr: [16]u8, iface_idx: u32) SyscallError!void {
    const mreq = Ipv6Mreq.init(group_addr, iface_idx);
    const mreq_bytes = std.mem.asBytes(&mreq);
    return setsockopt(fd, IPPROTO_IPV6, IPV6_LEAVE_GROUP, mreq_bytes);
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

/// Accept a connection with flags (SOCK_NONBLOCK, SOCK_CLOEXEC)
/// Returns new file descriptor for the connection
pub fn accept4(fd: i32, addr: ?*SockAddrIn, flags: i32) SyscallError!i32 {
    var addrlen: u32 = @sizeOf(SockAddrIn);
    const addr_ptr: usize = if (addr) |a| @intFromPtr(a) else 0;
    const addrlen_ptr: usize = if (addr != null) @intFromPtr(&addrlen) else 0;

    const ret = primitive.syscall4(
        syscalls.SYS_ACCEPT4,
        @bitCast(@as(isize, fd)),
        addr_ptr,
        addrlen_ptr,
        @bitCast(@as(isize, flags)),
    );
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

/// Get socket name (local address)
pub fn getsockname(fd: i32, addr: *SockAddrIn) SyscallError!void {
    var addrlen: u32 = @sizeOf(SockAddrIn);
    const ret = primitive.syscall3(
        syscalls.SYS_GETSOCKNAME,
        @bitCast(@as(isize, fd)),
        @intFromPtr(addr),
        @intFromPtr(&addrlen)
    );
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

// =============================================================================
// Socket Extras (socketpair, sendmsg, recvmsg)
// =============================================================================

/// Create a pair of connected sockets (AF_UNIX only)
/// Returns two file descriptors in sv[0] and sv[1]
pub fn socketpair(domain: i32, sock_type: i32, protocol: i32, sv: *[2]i32) SyscallError!void {
    const ret = primitive.syscall4(
        syscalls.SYS_SOCKETPAIR,
        @bitCast(@as(isize, domain)),
        @bitCast(@as(isize, sock_type)),
        @bitCast(@as(isize, protocol)),
        @intFromPtr(sv),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Send a message on a socket (scatter-gather + ancillary data)
/// Returns number of bytes sent
pub fn sendmsg(fd: i32, msg: *const MsgHdr, flags: i32) SyscallError!usize {
    const ret = primitive.syscall3(
        syscalls.SYS_SENDMSG,
        @bitCast(@as(isize, fd)),
        @intFromPtr(msg),
        @bitCast(@as(isize, flags)),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Receive a message from a socket (scatter-gather + ancillary data)
/// Returns number of bytes received
pub fn recvmsg(fd: i32, msg: *MsgHdr, flags: i32) SyscallError!usize {
    const ret = primitive.syscall3(
        syscalls.SYS_RECVMSG,
        @bitCast(@as(isize, fd)),
        @intFromPtr(msg),
        @bitCast(@as(isize, flags)),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// =============================================================================
// Network Interface Configuration (SYS_NETIF_CONFIG 1060)
// =============================================================================

/// Network interface configuration commands
pub const NetifCmd = enum(u32) {
    GetInfo = 0,
    SetIpv4 = 1,
    SetIpv6Addr = 2,
    SetIpv6Gateway = 3,
    GetRaInfo = 4,
    SetMtu = 5,
    GetLinkState = 6,
};

/// IPv4 configuration structure
pub const Ipv4Config = extern struct {
    ip_addr: u32, // Network byte order
    netmask: u32, // Network byte order
    gateway: u32, // Network byte order
};

/// IPv6 address configuration
pub const Ipv6AddrConfig = extern struct {
    addr: [16]u8,
    prefix_len: u8,
    scope: u8,
    action: u8,
    _pad: u8 = 0,

    pub const ACTION_ADD: u8 = 0;
    pub const ACTION_REMOVE: u8 = 1;
};

/// Router Advertisement info from kernel
pub const RaInfo = extern struct {
    router_addr: [16]u8,
    prefix: [16]u8,
    prefix_len: u8,
    flags: u8,
    _pad: [2]u8,
    valid_lifetime: u32,
    preferred_lifetime: u32,
    mtu: u32,
    timestamp: u64,

    pub fn isManagedFlag(self: RaInfo) bool {
        return (self.flags & 0x80) != 0;
    }

    pub fn isOtherFlag(self: RaInfo) bool {
        return (self.flags & 0x40) != 0;
    }

    pub fn isAutonomousFlag(self: RaInfo) bool {
        return (self.flags & 0x20) != 0;
    }
};

/// Interface information
pub const InterfaceInfo = extern struct {
    name: [16]u8,
    mac_addr: [6]u8,
    is_up: bool,
    link_up: bool,
    mtu: u16,
    _pad: [2]u8,
    ipv4_addr: u32,
    ipv4_netmask: u32,
    ipv4_gateway: u32,
    has_ipv6_gateway: bool,
    _pad2: [3]u8,
    ipv6_gateway: [16]u8,
    ipv6_addr_count: u8,
    _pad3: [7]u8,
};

/// Configure network interface
pub fn netif_config(iface_idx: u32, cmd: NetifCmd, data: []u8) SyscallError!void {
    const ret = primitive.syscall4(
        syscalls.zk.SYS_NETIF_CONFIG,
        @as(usize, iface_idx),
        @as(usize, @intFromEnum(cmd)),
        @intFromPtr(data.ptr),
        data.len,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get interface information
pub fn getInterfaceInfo(iface_idx: u32) SyscallError!InterfaceInfo {
    var info: InterfaceInfo = undefined;
    const ret = primitive.syscall4(
        syscalls.zk.SYS_NETIF_CONFIG,
        @as(usize, iface_idx),
        @as(usize, @intFromEnum(NetifCmd.GetInfo)),
        @intFromPtr(&info),
        @sizeOf(InterfaceInfo),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return info;
}

/// Set IPv4 configuration
pub fn setIpv4Config(iface_idx: u32, ip: u32, netmask: u32, gateway: u32) SyscallError!void {
    var config = Ipv4Config{
        .ip_addr = @byteSwap(ip),
        .netmask = @byteSwap(netmask),
        .gateway = @byteSwap(gateway),
    };
    const ret = primitive.syscall4(
        syscalls.zk.SYS_NETIF_CONFIG,
        @as(usize, iface_idx),
        @as(usize, @intFromEnum(NetifCmd.SetIpv4)),
        @intFromPtr(&config),
        @sizeOf(Ipv4Config),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get Router Advertisement info (for SLAAC)
pub fn getRaInfo(iface_idx: u32) SyscallError!RaInfo {
    var ra_info: RaInfo = undefined;
    const ret = primitive.syscall4(
        syscalls.zk.SYS_NETIF_CONFIG,
        @as(usize, iface_idx),
        @as(usize, @intFromEnum(NetifCmd.GetRaInfo)),
        @intFromPtr(&ra_info),
        @sizeOf(RaInfo),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ra_info;
}

/// Add IPv6 address
pub fn addIpv6Address(iface_idx: u32, addr: [16]u8, prefix_len: u8, scope: u8) SyscallError!void {
    var config = Ipv6AddrConfig{
        .addr = addr,
        .prefix_len = prefix_len,
        .scope = scope,
        .action = Ipv6AddrConfig.ACTION_ADD,
    };
    const ret = primitive.syscall4(
        syscalls.zk.SYS_NETIF_CONFIG,
        @as(usize, iface_idx),
        @as(usize, @intFromEnum(NetifCmd.SetIpv6Addr)),
        @intFromPtr(&config),
        @sizeOf(Ipv6AddrConfig),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set IPv6 default gateway
pub fn setIpv6Gateway(iface_idx: u32, gateway: [16]u8) SyscallError!void {
    var gw = gateway;
    const ret = primitive.syscall4(
        syscalls.zk.SYS_NETIF_CONFIG,
        @as(usize, iface_idx),
        @as(usize, @intFromEnum(NetifCmd.SetIpv6Gateway)),
        @intFromPtr(&gw),
        16,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// ARP Operations (SYS_ARP_PROBE 1061, SYS_ARP_ANNOUNCE 1062)
//
// RFC 5227 - IPv4 Address Conflict Detection
//
// These functions implement the userspace interface for ARP-based IP
// conflict detection, used by DHCP clients before configuring addresses.
// =============================================================================

/// ARP probe result codes (RFC 5227 Section 2.1.1)
pub const ArpProbeResult = enum(u8) {
    /// No conflict detected - safe to use IP
    NoConflict = 0,
    /// Conflict detected - IP is already in use on the network
    Conflict = 1,
    /// Timeout - no response received, IP is safe to use
    Timeout = 2,
};

/// Send ARP probe to detect IP conflicts before configuring address
///
/// RFC 5227 Section 2.1.1:
/// "A host probes to see if an address is already in use by broadcasting
/// an ARP Request for the desired address."
///
/// This SHOULD be called before configuring any IP address obtained via
/// DHCP or manual configuration to prevent address conflicts.
///
/// Arguments:
///   iface_idx: Interface index (currently only 0 supported)
///   ip: Target IP address in host byte order
///   timeout_ms: Maximum time to wait for response in milliseconds
///
/// Returns:
///   .NoConflict or .Timeout: Safe to use the IP address
///   .Conflict: IP is in use - do not configure, send DHCPDECLINE
pub fn arpProbe(iface_idx: u32, ip: u32, timeout_ms: u64) SyscallError!ArpProbeResult {
    const ret = primitive.syscall3(
        syscalls.zk.SYS_ARP_PROBE,
        @as(usize, iface_idx),
        @as(usize, ip),
        @as(usize, @truncate(timeout_ms)),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @enumFromInt(@as(u8, @truncate(ret)));
}

/// Send gratuitous ARP announcement after configuring address
///
/// RFC 5227 Section 2.3:
/// "Having probed to determine that an address is not in use, a host
/// announces its claim to the address."
///
/// RFC 5227 Section 3:
/// "A host SHOULD transmit an ARP Announcement immediately after
/// successfully completing its final ARP Probe."
///
/// This updates neighbor ARP caches with our new MAC/IP binding,
/// preventing stale cache entries from causing connectivity issues.
///
/// Arguments:
///   iface_idx: Interface index (currently only 0 supported)
///   ip: IP address to announce in host byte order
pub fn arpAnnounce(iface_idx: u32, ip: u32) SyscallError!void {
    const ret = primitive.syscall2(
        syscalls.zk.SYS_ARP_ANNOUNCE,
        @as(usize, iface_idx),
        @as(usize, ip),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}
