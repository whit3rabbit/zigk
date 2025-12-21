// Network Packet Buffer
//
// Zero-copy packet buffer for network stack processing.
// Packets flow from driver through protocol layers with minimal copying.
//
// Design:
//   - Fixed-size buffers from driver's pre-allocated pool
//   - Layer offsets track header positions for easy access
//   - Reference counting for shared packet handling
const std = @import("std");

/// Maximum packet size (MTU + headers)
pub const MAX_PACKET_SIZE: usize = 2048;

/// Ethernet header size
pub const ETH_HEADER_SIZE: usize = 14;
/// IPv4 header size (minimum, without options)
pub const IP_HEADER_SIZE: usize = 20;
/// TCP header size (minimum, without options)
pub const TCP_HEADER_SIZE: usize = 20;
/// UDP header size
pub const UDP_HEADER_SIZE: usize = 8;
/// ICMP header size
pub const ICMP_HEADER_SIZE: usize = 8;

/// Packet buffer for zero-copy networking
pub const PacketBuffer = struct {
    /// Slice to raw packet data (covers capacity)
    data: []u8,
    /// Current used length
    len: usize,

    /// Layer offsets (set during parsing/building)
    eth_offset: usize,
    ip_offset: usize,
    transport_offset: usize,
    payload_offset: usize,

    /// Source information (set on receive)
    src_mac: [6]u8,
    src_ip: u32,
    src_port: u16,
    
    /// Destination information (essential for reassembled packets where IP header is stripped)
    dst_ip: u32,

    /// Protocol info
    ethertype: u16,
    ip_protocol: u8,

    /// Packet delivery flags (set during IP processing)
    is_broadcast: bool,
    is_multicast: bool,

    const Self = @This();

    /// Initialize from raw packet buffer
    /// data: The backing storage slice (defines capacity)
    /// len: The initial used length (usually 0 for new packets, or data.len for wrappers)
    pub fn init(data: []u8, len: usize) Self {
        return Self{
            .data = data,
            .len = len,
            // Reserve headroom for outgoing packets (len == 0), otherwise assume received packet (offset 0)
            .eth_offset = if (len == 0) 128 else 0,
            .ip_offset = 0,
            .transport_offset = 0,
            .payload_offset = 0,
            .src_mac = [_]u8{0} ** 6,
            .src_ip = 0,
            .src_port = 0,
            .dst_ip = 0,
            .ethertype = 0,
            .ip_protocol = 0,
            .is_broadcast = false,
            .is_multicast = false,
        };
    }

    // SECURITY: The following header accessor methods (ethHeader, ipHeader, udpHeader,
    // icmpHeader) perform direct pointer casts WITHOUT bounds checking. In ReleaseFast
    // builds where runtime safety is disabled, malformed packets with invalid offsets
    // can cause out-of-bounds memory access.
    //
    // These methods assume callers have already validated packet structure. For untrusted
    // network input, prefer the bounds-checked module-level functions: getEthHeader(),
    // getIpv4Header(), getUdpHeader(), getIcmpHeader() which return null on invalid access.
    //
    // Risk: High in ReleaseFast mode with malformed packets.
    // Mitigation: Use safe accessors or validate offsets before calling these methods.

    /// Get Ethernet header pointer (unchecked - see SECURITY note above)
    pub fn ethHeader(self: *const Self) *align(1) EthernetHeader {
        return @ptrCast(&self.data[self.eth_offset]);
    }

    /// Get IPv4 header pointer (unchecked - see SECURITY note above)
    pub fn ipHeader(self: *const Self) *align(1) Ipv4Header {
        return @ptrCast(&self.data[self.ip_offset]);
    }

    /// Get UDP header pointer (unchecked - see SECURITY note above)
    pub fn udpHeader(self: *const Self) *align(1) UdpHeader {
        return @ptrCast(&self.data[self.transport_offset]);
    }

    /// Get ICMP header pointer (unchecked - see SECURITY note above)
    pub fn icmpHeader(self: *const Self) *align(1) IcmpHeader {
        return @ptrCast(&self.data[self.transport_offset]);
    }

    /// Get payload slice
    pub fn payload(self: *const Self) []u8 {
        if (self.payload_offset >= self.len) {
            return &[_]u8{};
        }
        return self.data[self.payload_offset..self.len];
    }

    /// Get payload length
    pub fn payloadLen(self: *const Self) usize {
        if (self.payload_offset >= self.len) {
            return 0;
        }
        return self.len - self.payload_offset;
    }

    /// Get raw data slice (used portion)
    pub fn getData(self: *const Self) []u8 {
        return self.data[0..self.len];
    }

    /// Prepend space for a header (for building outgoing packets)
    pub fn prependHeader(self: *Self, size: usize) bool {
        if (self.eth_offset < size) {
            return false; // No room
        }
        const new_len = std.math.add(usize, self.len, size) catch return false;
        if (new_len > self.data.len) {
            return false;
        }
        self.eth_offset -= size;
        self.len = new_len;
        return true;
    }

    /// Copy data into packet at current position
    pub fn appendData(self: *Self, src: []const u8) bool {
        const new_len = std.math.add(usize, self.len, src.len) catch return false;
        if (new_len > self.data.len) {
            return false;
        }
        @memcpy(self.data[self.len..][0..src.len], src);
        self.len = new_len;
        return true;
    }
};

// ============================================================================
// Protocol Header Structures
// ============================================================================

/// Ethernet header (14 bytes)
/// Note: align(1) allows casting from unaligned packet buffer offsets
pub const EthernetHeader = extern struct {
    dst_mac: [6]u8,
    src_mac: [6]u8,
    ethertype: u16, // Network byte order, unaligned access safe

    pub const ETHERTYPE_IPV4: u16 = 0x0008; // 0x0800 in network order
    pub const ETHERTYPE_ARP: u16 = 0x0608;  // 0x0806 in network order

    /// Get ethertype in host byte order
    pub fn getEthertype(self: *align(1) const EthernetHeader) u16 {
        return @byteSwap(self.ethertype);
    }

    /// Set ethertype from host byte order
    pub fn setEthertype(self: *align(1) EthernetHeader, value: u16) void {
        self.ethertype = @byteSwap(value);
    }

    comptime {
        if (@sizeOf(EthernetHeader) != 14) @compileError("EthernetHeader must be 14 bytes");
    }
};

/// IPv4 header (20 bytes minimum)
pub const Ipv4Header = extern struct {
    version_ihl: u8,    // Version (4 bits) + IHL (4 bits)
    tos: u8,            // Type of Service
    total_length: u16,  // Network byte order
    identification: u16,
    flags_fragment: u16,
    ttl: u8,
    protocol: u8,
    checksum: u16,
    src_ip: u32,        // Network byte order
    dst_ip: u32,        // Network byte order

    pub const PROTO_ICMP: u8 = 1;
    pub const PROTO_TCP: u8 = 6;
    pub const PROTO_UDP: u8 = 17;

    /// Get IP version
    pub fn getVersion(self: *align(1) const Ipv4Header) u4 {
        return @truncate(self.version_ihl >> 4);
    }

    /// Get header length in bytes
    pub fn getHeaderLength(self: *align(1) const Ipv4Header) usize {
        return @as(usize, self.version_ihl & 0x0F) * 4;
    }

    /// Get total length in host byte order
    pub fn getTotalLength(self: *align(1) const Ipv4Header) u16 {
        return @byteSwap(self.total_length);
    }

    /// Set total length from host byte order
    pub fn setTotalLength(self: *align(1) Ipv4Header, value: u16) void {
        self.total_length = @byteSwap(value);
    }

    /// Get source IP in host byte order
    pub fn getSrcIp(self: *align(1) const Ipv4Header) u32 {
        return @byteSwap(self.src_ip);
    }

    /// Get destination IP in host byte order
    pub fn getDstIp(self: *align(1) const Ipv4Header) u32 {
        return @byteSwap(self.dst_ip);
    }

    /// Set source IP from host byte order
    pub fn setSrcIp(self: *align(1) Ipv4Header, value: u32) void {
        self.src_ip = @byteSwap(value);
    }

    /// Set destination IP from host byte order
    pub fn setDstIp(self: *align(1) Ipv4Header, value: u32) void {
        self.dst_ip = @byteSwap(value);
    }

    comptime {
        if (@sizeOf(Ipv4Header) != 20) @compileError("Ipv4Header must be 20 bytes");
    }
};

/// UDP header (8 bytes)
pub const UdpHeader = extern struct {
    src_port: u16,  // Network byte order
    dst_port: u16,
    length: u16,
    checksum: u16,

    /// Get source port in host byte order
    pub fn getSrcPort(self: *align(1) const UdpHeader) u16 {
        return @byteSwap(self.src_port);
    }

    /// Get destination port in host byte order
    pub fn getDstPort(self: *align(1) const UdpHeader) u16 {
        return @byteSwap(self.dst_port);
    }

    /// Set source port from host byte order
    pub fn setSrcPort(self: *align(1) UdpHeader, value: u16) void {
        self.src_port = @byteSwap(value);
    }

    /// Set destination port from host byte order
    pub fn setDstPort(self: *align(1) UdpHeader, value: u16) void {
        self.dst_port = @byteSwap(value);
    }

    /// Get length in host byte order
    pub fn getLength(self: *align(1) const UdpHeader) u16 {
        return @byteSwap(self.length);
    }

    /// Set length from host byte order
    pub fn setLength(self: *align(1) UdpHeader, value: u16) void {
        self.length = @byteSwap(value);
    }

    comptime {
        if (@sizeOf(UdpHeader) != 8) @compileError("UdpHeader must be 8 bytes");
    }
};

/// ICMP header (8 bytes)
pub const IcmpHeader = extern struct {
    icmp_type: u8,
    code: u8,
    checksum: u16,
    identifier: u16, // Network byte order
    sequence: u16,   // Network byte order

    pub const TYPE_ECHO_REPLY: u8 = 0;
    pub const TYPE_ECHO_REQUEST: u8 = 8;

    /// Get identifier in host byte order
    pub fn getIdentifier(self: *align(1) const IcmpHeader) u16 {
        return @byteSwap(self.identifier);
    }

    /// Get sequence in host byte order
    pub fn getSequence(self: *align(1) const IcmpHeader) u16 {
        return @byteSwap(self.sequence);
    }

    comptime {
        if (@sizeOf(IcmpHeader) != 8) @compileError("IcmpHeader must be 8 bytes");
    }
};

/// ARP header (28 bytes for IPv4 over Ethernet)
pub const ArpHeader = extern struct {
    hw_type: u16,       // Hardware type (1 = Ethernet)
    proto_type: u16,    // Protocol type (0x0800 = IPv4)
    hw_len: u8,         // Hardware address length (6 for Ethernet)
    proto_len: u8,      // Protocol address length (4 for IPv4)
    operation: u16,     // Operation (1 = request, 2 = reply)
    sender_mac: [6]u8,
    sender_ip: u32 align(1),
    target_mac: [6]u8,
    target_ip: u32 align(1),

    pub const OP_REQUEST: u16 = 0x0100; // 1 in network byte order
    pub const OP_REPLY: u16 = 0x0200;   // 2 in network byte order

    /// Get operation in host byte order
    pub fn getOperation(self: *align(1) const ArpHeader) u16 {
        return @byteSwap(self.operation);
    }

    /// Get sender IP in host byte order
    pub fn getSenderIp(self: *align(1) const ArpHeader) u32 {
        return @byteSwap(self.sender_ip);
    }

    /// Get target IP in host byte order
    pub fn getTargetIp(self: *align(1) const ArpHeader) u32 {
        return @byteSwap(self.target_ip);
    }

    comptime {
        if (@sizeOf(ArpHeader) != 28) @compileError("ArpHeader must be 28 bytes");
    }
};

// =============================================================================
// Safe Header Accessors with Bounds Checking
// =============================================================================
// These functions provide safe access to protocol headers from raw byte slices.
// Unlike direct @ptrCast, they verify the buffer has sufficient space before
// returning a pointer, preventing out-of-bounds access.

/// Get Ethernet header from buffer with bounds checking.
/// Returns null if buffer is too small to contain an Ethernet header.
pub fn getEthHeader(buf: []const u8, offset: usize) ?*align(1) const EthernetHeader {
    const end = std.math.add(usize, offset, ETH_HEADER_SIZE) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get mutable Ethernet header from buffer with bounds checking.
pub fn getEthHeaderMut(buf: []u8, offset: usize) ?*align(1) EthernetHeader {
    const end = std.math.add(usize, offset, ETH_HEADER_SIZE) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get IPv4 header from buffer with bounds checking.
/// Returns null if buffer is too small to contain an IPv4 header.
pub fn getIpv4Header(buf: []const u8, offset: usize) ?*align(1) const Ipv4Header {
    const end = std.math.add(usize, offset, IP_HEADER_SIZE) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get mutable IPv4 header from buffer with bounds checking.
pub fn getIpv4HeaderMut(buf: []u8, offset: usize) ?*align(1) Ipv4Header {
    const end = std.math.add(usize, offset, IP_HEADER_SIZE) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get UDP header from buffer with bounds checking.
/// Returns null if buffer is too small to contain a UDP header.
pub fn getUdpHeader(buf: []const u8, offset: usize) ?*align(1) const UdpHeader {
    const end = std.math.add(usize, offset, UDP_HEADER_SIZE) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get mutable UDP header from buffer with bounds checking.
pub fn getUdpHeaderMut(buf: []u8, offset: usize) ?*align(1) UdpHeader {
    const end = std.math.add(usize, offset, UDP_HEADER_SIZE) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get ICMP header from buffer with bounds checking.
/// Returns null if buffer is too small to contain an ICMP header.
pub fn getIcmpHeader(buf: []const u8, offset: usize) ?*align(1) const IcmpHeader {
    const end = std.math.add(usize, offset, ICMP_HEADER_SIZE) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get mutable ICMP header from buffer with bounds checking.
pub fn getIcmpHeaderMut(buf: []u8, offset: usize) ?*align(1) IcmpHeader {
    const end = std.math.add(usize, offset, ICMP_HEADER_SIZE) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get ARP header from buffer with bounds checking.
/// Returns null if buffer is too small to contain an ARP header.
pub fn getArpHeader(buf: []const u8, offset: usize) ?*align(1) const ArpHeader {
    const arp_size = @sizeOf(ArpHeader);
    const end = std.math.add(usize, offset, arp_size) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get mutable ARP header from buffer with bounds checking.
pub fn getArpHeaderMut(buf: []u8, offset: usize) ?*align(1) ArpHeader {
    const arp_size = @sizeOf(ArpHeader);
    const end = std.math.add(usize, offset, arp_size) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Generic header accessor with bounds checking.
/// Use for any fixed-size header type.
pub fn getHeaderAs(comptime T: type, buf: []const u8, offset: usize) ?*align(1) const T {
    if (offset + @sizeOf(T) > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Generic mutable header accessor with bounds checking.
pub fn getHeaderAsMut(comptime T: type, buf: []u8, offset: usize) ?*align(1) T {
    if (offset + @sizeOf(T) > buf.len) return null;
    return @ptrCast(&buf[offset]);
}
