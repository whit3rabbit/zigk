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
        syscalls.zscapek.SYS_NETIF_CONFIG,
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
        syscalls.zscapek.SYS_NETIF_CONFIG,
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
        syscalls.zscapek.SYS_NETIF_CONFIG,
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
        syscalls.zscapek.SYS_NETIF_CONFIG,
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
        syscalls.zscapek.SYS_NETIF_CONFIG,
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
        syscalls.zscapek.SYS_NETIF_CONFIG,
        @as(usize, iface_idx),
        @as(usize, @intFromEnum(NetifCmd.SetIpv6Gateway)),
        @intFromPtr(&gw),
        16,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// ARP Operations (SYS_ARP_PROBE 1061, SYS_ARP_ANNOUNCE 1062)
// =============================================================================

/// ARP probe result codes
pub const ArpProbeResult = enum(u8) {
    /// No conflict detected - safe to use IP
    NoConflict = 0,
    /// Conflict detected - IP is already in use
    Conflict = 1,
    /// Timeout - no response, safe to use IP
    Timeout = 2,
};

/// Send ARP probe to detect IP conflicts before configuring address (RFC 5227)
///
/// Arguments:
///   iface_idx: Interface index (currently only 0 supported)
///   ip: Target IP address in host byte order
///   timeout_ms: Maximum time to wait for response in milliseconds
///
/// Returns: ArpProbeResult indicating whether IP is safe to use
pub fn arpProbe(iface_idx: u32, ip: u32, timeout_ms: u64) SyscallError!ArpProbeResult {
    const ret = primitive.syscall3(
        syscalls.zscapek.SYS_ARP_PROBE,
        @as(usize, iface_idx),
        @as(usize, ip),
        @as(usize, @truncate(timeout_ms)),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @enumFromInt(@as(u8, @truncate(ret)));
}

/// Send gratuitous ARP announcement after configuring address (RFC 5227)
///
/// Arguments:
///   iface_idx: Interface index (currently only 0 supported)
///   ip: IP address to announce in host byte order
///
/// This updates neighbor ARP caches with our new address.
pub fn arpAnnounce(iface_idx: u32, ip: u32) SyscallError!void {
    const ret = primitive.syscall2(
        syscalls.zscapek.SYS_ARP_ANNOUNCE,
        @as(usize, iface_idx),
        @as(usize, ip),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}
