// Socket API Implementation
//
// Provides BSD-style socket interface for userland networking.
// Currently supports AF_INET + SOCK_DGRAM (UDP) only.
//
// This is a minimal implementation for the MVP - no TCP, no advanced options.

const packet = @import("../core/packet.zig");
const interface = @import("../core/interface.zig");
const udp = @import("udp.zig");
const PacketBuffer = packet.PacketBuffer;
const Interface = interface.Interface;

/// Socket address family
pub const AF_INET: i32 = 2;

/// Socket types
pub const SOCK_STREAM: i32 = 1; // TCP (not implemented)
pub const SOCK_DGRAM: i32 = 2; // UDP

/// Socket address structure (IPv4)
/// Compatible with Linux sockaddr_in
pub const SockAddrIn = extern struct {
    family: u16, // AF_INET
    port: u16, // Network byte order
    addr: u32, // Network byte order
    zero: [8]u8, // Padding

    pub fn init(ip: u32, port_host: u16) SockAddrIn {
        return .{
            .family = @as(u16, @intCast(AF_INET)),
            .port = @byteSwap(port_host),
            .addr = @byteSwap(ip),
            .zero = [_]u8{0} ** 8,
        };
    }

    pub fn getPort(self: *const SockAddrIn) u16 {
        return @byteSwap(self.port);
    }

    pub fn getAddr(self: *const SockAddrIn) u32 {
        return @byteSwap(self.addr);
    }
};

/// Generic socket address (for API compatibility)
pub const SockAddr = extern struct {
    family: u16,
    data: [14]u8,
};

/// Maximum sockets in the system
const MAX_SOCKETS: usize = 32;

/// Maximum packets in socket receive queue
const SOCKET_RX_QUEUE_SIZE: usize = 16;

/// Received packet entry in queue
const RxQueueEntry = struct {
    data: [packet.MAX_PACKET_SIZE]u8,
    len: usize,
    src_addr: u32, // Source IP (host byte order)
    src_port: u16, // Source port (host byte order)
    valid: bool,
};

/// Socket structure
pub const Socket = struct {
    /// Socket is allocated
    allocated: bool,
    /// Address family (AF_INET)
    family: i32,
    /// Socket type (SOCK_DGRAM)
    sock_type: i32,
    /// Protocol (0 = default for type)
    protocol: i32,
    /// Local port (host byte order, 0 = not bound)
    local_port: u16,
    /// Local address (host byte order, 0 = INADDR_ANY)
    local_addr: u32,
    /// Receive queue (circular buffer of received packets)
    rx_queue: [SOCKET_RX_QUEUE_SIZE]RxQueueEntry,
    rx_head: usize, // Next slot to write
    rx_tail: usize, // Next slot to read
    rx_count: usize, // Number of packets in queue
    /// Blocking mode (true = blocking, false = non-blocking)
    blocking: bool,

    const Self = @This();

    fn init() Self {
        return .{
            .allocated = false,
            .family = 0,
            .sock_type = 0,
            .protocol = 0,
            .local_port = 0,
            .local_addr = 0,
            .rx_queue = [_]RxQueueEntry{.{
                .data = undefined,
                .len = 0,
                .src_addr = 0,
                .src_port = 0,
                .valid = false,
            }} ** SOCKET_RX_QUEUE_SIZE,
            .rx_head = 0,
            .rx_tail = 0,
            .rx_count = 0,
            .blocking = true,
        };
    }

    /// Enqueue a received packet
    pub fn enqueuePacket(self: *Self, data: []const u8, src_addr: u32, src_port: u16) bool {
        if (self.rx_count >= SOCKET_RX_QUEUE_SIZE) {
            // Queue full - drop packet
            return false;
        }

        const entry = &self.rx_queue[self.rx_head];
        const copy_len = @min(data.len, entry.data.len);
        @memcpy(entry.data[0..copy_len], data[0..copy_len]);
        entry.len = copy_len;
        entry.src_addr = src_addr;
        entry.src_port = src_port;
        entry.valid = true;

        self.rx_head = (self.rx_head + 1) % SOCKET_RX_QUEUE_SIZE;
        self.rx_count += 1;

        return true;
    }

    /// Dequeue a received packet
    pub fn dequeuePacket(self: *Self, buf: []u8, src_addr: ?*u32, src_port: ?*u16) ?usize {
        if (self.rx_count == 0) {
            return null;
        }

        const entry = &self.rx_queue[self.rx_tail];
        if (!entry.valid) {
            return null;
        }

        const copy_len = @min(entry.len, buf.len);
        @memcpy(buf[0..copy_len], entry.data[0..copy_len]);

        if (src_addr) |addr| {
            addr.* = entry.src_addr;
        }
        if (src_port) |port| {
            port.* = entry.src_port;
        }

        entry.valid = false;
        self.rx_tail = (self.rx_tail + 1) % SOCKET_RX_QUEUE_SIZE;
        self.rx_count -= 1;

        return copy_len;
    }

    /// Check if there are packets waiting
    pub fn hasData(self: *const Self) bool {
        return self.rx_count > 0;
    }
};

/// Global socket table
var socket_table: [MAX_SOCKETS]Socket = [_]Socket{Socket.init()} ** MAX_SOCKETS;

/// Next ephemeral port for auto-binding
var next_ephemeral_port: u16 = 49152;

/// Global network interface (set during init)
var global_iface: ?*Interface = null;

/// Initialize socket subsystem
pub fn init(iface: *Interface) void {
    global_iface = iface;
    for (&socket_table) |*sock| {
        sock.* = Socket.init();
    }
}

/// Allocate a new socket
/// Returns socket index (fd) or error
pub fn socket(family: i32, sock_type: i32, protocol: i32) SocketError!usize {
    // Validate parameters
    if (family != AF_INET) {
        return SocketError.AfNotSupported;
    }

    if (sock_type != SOCK_DGRAM) {
        return SocketError.TypeNotSupported;
    }

    // Find free socket slot
    for (&socket_table, 0..) |*sock, i| {
        if (!sock.allocated) {
            sock.* = Socket.init();
            sock.allocated = true;
            sock.family = family;
            sock.sock_type = sock_type;
            sock.protocol = protocol;
            return i;
        }
    }

    return SocketError.NoSocketsAvailable;
}

/// Bind socket to local address/port
pub fn bind(sock_fd: usize, addr: *const SockAddrIn) SocketError!void {
    if (sock_fd >= MAX_SOCKETS) {
        return SocketError.BadFd;
    }

    const sock = &socket_table[sock_fd];
    if (!sock.allocated) {
        return SocketError.BadFd;
    }

    const port = addr.getPort();
    const ip = addr.getAddr();

    // Check port isn't already in use
    if (port != 0) {
        for (&socket_table) |*other| {
            if (other.allocated and other.local_port == port) {
                return SocketError.AddrInUse;
            }
        }
    }

    sock.local_port = if (port == 0) allocateEphemeralPort() else port;
    sock.local_addr = ip;
}

/// Send data to a destination
pub fn sendto(
    sock_fd: usize,
    data: []const u8,
    dest_addr: *const SockAddrIn,
) SocketError!usize {
    if (sock_fd >= MAX_SOCKETS) {
        return SocketError.BadFd;
    }

    const sock = &socket_table[sock_fd];
    if (!sock.allocated) {
        return SocketError.BadFd;
    }

    const iface = global_iface orelse return SocketError.NetworkDown;

    // Auto-bind if not bound
    if (sock.local_port == 0) {
        sock.local_port = allocateEphemeralPort();
    }

    const dst_ip = dest_addr.getAddr();
    const dst_port = dest_addr.getPort();

    if (udp.sendDatagram(iface, dst_ip, sock.local_port, dst_port, data)) {
        return data.len;
    }

    return SocketError.NetworkUnreachable;
}

/// Receive data from socket
pub fn recvfrom(
    sock_fd: usize,
    buf: []u8,
    src_addr: ?*SockAddrIn,
) SocketError!usize {
    if (sock_fd >= MAX_SOCKETS) {
        return SocketError.BadFd;
    }

    const sock = &socket_table[sock_fd];
    if (!sock.allocated) {
        return SocketError.BadFd;
    }

    var src_ip: u32 = 0;
    var src_port: u16 = 0;

    // Non-blocking: check queue and return immediately
    if (!sock.blocking) {
        if (sock.dequeuePacket(buf, &src_ip, &src_port)) |len| {
            if (src_addr) |addr| {
                addr.* = SockAddrIn.init(src_ip, src_port);
            }
            return len;
        }
        return SocketError.WouldBlock;
    }

    // Blocking: spin-wait for data (no proper blocking in MVP)
    // In a real implementation, this would use thread blocking
    var spin_count: usize = 0;
    while (spin_count < 1000000) : (spin_count += 1) {
        if (sock.dequeuePacket(buf, &src_ip, &src_port)) |len| {
            if (src_addr) |addr| {
                addr.* = SockAddrIn.init(src_ip, src_port);
            }
            return len;
        }
        // Yield CPU (basic spin)
        asm volatile ("pause");
    }

    return SocketError.TimedOut;
}

/// Close a socket
pub fn close(sock_fd: usize) SocketError!void {
    if (sock_fd >= MAX_SOCKETS) {
        return SocketError.BadFd;
    }

    const sock = &socket_table[sock_fd];
    if (!sock.allocated) {
        return SocketError.BadFd;
    }

    sock.* = Socket.init();
}

/// Find socket by local port (for UDP dispatch)
pub fn findByPort(port: u16) ?*Socket {
    for (&socket_table) |*sock| {
        if (sock.allocated and sock.local_port == port) {
            return sock;
        }
    }
    return null;
}

/// Deliver a received UDP packet to the appropriate socket
pub fn deliverUdpPacket(pkt: *PacketBuffer) bool {
    const udp_hdr = pkt.udpHeader();
    const dst_port = udp_hdr.getDstPort();

    const sock = findByPort(dst_port) orelse {
        return false; // No socket listening on this port
    };

    // Extract payload
    const payload_offset = pkt.transport_offset + packet.UDP_HEADER_SIZE;
    const udp_len = udp_hdr.getLength();
    if (udp_len <= packet.UDP_HEADER_SIZE) {
        return false;
    }
    const payload_len = udp_len - packet.UDP_HEADER_SIZE;

    if (payload_offset + payload_len > pkt.len) {
        return false;
    }

    const payload = pkt.data[payload_offset..][0..payload_len];

    // Enqueue packet with source info
    return sock.enqueuePacket(payload, pkt.src_ip, pkt.src_port);
}

/// Allocate an ephemeral port
fn allocateEphemeralPort() u16 {
    // Find unused port in ephemeral range (49152-65535)
    var attempts: u16 = 0;
    while (attempts < 1000) : (attempts += 1) {
        const port = next_ephemeral_port;
        next_ephemeral_port +%= 1;
        if (next_ephemeral_port < 49152) {
            next_ephemeral_port = 49152;
        }

        // Check if port is in use
        var in_use = false;
        for (&socket_table) |*sock| {
            if (sock.allocated and sock.local_port == port) {
                in_use = true;
                break;
            }
        }

        if (!in_use) {
            return port;
        }
    }

    // Fallback - return next port anyway
    const port = next_ephemeral_port;
    next_ephemeral_port +%= 1;
    return port;
}

/// Socket errors
pub const SocketError = error{
    BadFd,
    AfNotSupported,
    TypeNotSupported,
    NoSocketsAvailable,
    AddrInUse,
    NetworkDown,
    NetworkUnreachable,
    WouldBlock,
    TimedOut,
    InvalidArg,
};

/// Convert SocketError to Linux errno (negative value)
pub fn errorToErrno(err: SocketError) isize {
    return switch (err) {
        SocketError.BadFd => -9, // EBADF
        SocketError.AfNotSupported => -97, // EAFNOSUPPORT
        SocketError.TypeNotSupported => -94, // ESOCKTNOSUPPORT
        SocketError.NoSocketsAvailable => -23, // ENFILE
        SocketError.AddrInUse => -98, // EADDRINUSE
        SocketError.NetworkDown => -100, // ENETDOWN
        SocketError.NetworkUnreachable => -101, // ENETUNREACH
        SocketError.WouldBlock => -11, // EAGAIN/EWOULDBLOCK
        SocketError.TimedOut => -110, // ETIMEDOUT
        SocketError.InvalidArg => -22, // EINVAL
    };
}
