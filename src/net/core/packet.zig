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
const constants = @import("../constants.zig");

/// Maximum packet size (MTU + headers)
pub const MAX_PACKET_SIZE: usize = constants.MAX_PACKET_SIZE;

/// Ethernet header size
pub const ETH_HEADER_SIZE: usize = constants.ETH_HEADER_SIZE;
/// IPv4 header size (minimum, without options)
pub const IP_HEADER_SIZE: usize = constants.IP_HEADER_SIZE;
/// TCP header size (minimum, without options)
pub const TCP_HEADER_SIZE: usize = constants.TCP_HEADER_SIZE;
/// UDP header size
pub const UDP_HEADER_SIZE: usize = constants.UDP_HEADER_SIZE;
/// ICMP header size
pub const ICMP_HEADER_SIZE: usize = constants.ICMP_HEADER_SIZE;

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

    /// IPv6 source and destination addresses
    src_ipv6: [16]u8,
    dst_ipv6: [16]u8,

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
            .src_ipv6 = [_]u8{0} ** 16,
            .dst_ipv6 = [_]u8{0} ** 16,
            .ethertype = 0,
            .ip_protocol = 0,
            .is_broadcast = false,
            .is_multicast = false,
        };
    }

    // SECURITY: The following header accessor methods (ethHeaderUnsafe, ipHeaderUnsafe,
    // udpHeaderUnsafe, icmpHeaderUnsafe) perform direct pointer casts WITHOUT bounds checking. In ReleaseFast
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
    pub fn ethHeaderUnsafe(self: *const Self) *align(1) EthernetHeader {
        @setRuntimeSafety(true);
        const end = std.math.add(usize, self.eth_offset, ETH_HEADER_SIZE) catch @panic("ethHeader overflow");
        const limit = if (self.len == 0) self.data.len else self.len;
        if (end > limit) @panic("ethHeader out of bounds");
        return @ptrCast(&self.data[self.eth_offset]);
    }

    /// Get IPv4 header pointer (unchecked - see SECURITY note above)
    pub fn ipHeaderUnsafe(self: *const Self) *align(1) Ipv4Header {
        @setRuntimeSafety(true);
        const end = std.math.add(usize, self.ip_offset, IP_HEADER_SIZE) catch @panic("ipHeader overflow");
        const limit = if (self.len == 0) self.data.len else self.len;
        if (end > limit) @panic("ipHeader out of bounds");
        return @ptrCast(&self.data[self.ip_offset]);
    }

    /// Get UDP header pointer (unchecked - see SECURITY note above)
    pub fn udpHeaderUnsafe(self: *const Self) *align(1) UdpHeader {
        @setRuntimeSafety(true);
        const end = std.math.add(usize, self.transport_offset, UDP_HEADER_SIZE) catch @panic("udpHeader overflow");
        const limit = if (self.len == 0) self.data.len else self.len;
        if (end > limit) @panic("udpHeader out of bounds");
        return @ptrCast(&self.data[self.transport_offset]);
    }

    /// Get ICMP header pointer (unchecked - see SECURITY note above)
    pub fn icmpHeaderUnsafe(self: *const Self) *align(1) IcmpHeader {
        @setRuntimeSafety(true);
        const end = std.math.add(usize, self.transport_offset, ICMP_HEADER_SIZE) catch @panic("icmpHeader overflow");
        const limit = if (self.len == 0) self.data.len else self.len;
        if (end > limit) @panic("icmpHeader out of bounds");
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

    pub const ETHERTYPE_IPV4: u16 = constants.ETHERTYPE_IPV4; // 0x0800 in network order
    pub const ETHERTYPE_ARP: u16 = constants.ETHERTYPE_ARP;  // 0x0806 in network order

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

    pub const PROTO_ICMP: u8 = constants.PROTO_ICMP;
    pub const PROTO_TCP: u8 = constants.PROTO_TCP;
    pub const PROTO_UDP: u8 = constants.PROTO_UDP;

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

/// IPv6 header size (fixed, no variable-length like IPv4 options)
pub const IPV6_HEADER_SIZE: usize = 40;

/// IPv6 header (40 bytes, fixed size per RFC 8200)
/// Extension headers follow after the base header if present.
pub const Ipv6Header = extern struct {
    /// Version (4 bits) + Traffic Class (8 bits) + Flow Label (20 bits)
    /// In network byte order: [ver:4][tc:8][flow:20]
    version_tc_flow: u32,
    /// Payload length (excludes this header, includes extension headers)
    payload_length: u16,
    /// Next header type (protocol number or extension header type)
    next_header: u8,
    /// Hop limit (equivalent to TTL in IPv4)
    hop_limit: u8,
    /// Source address (128 bits, network byte order)
    src_addr: [16]u8,
    /// Destination address (128 bits, network byte order)
    dst_addr: [16]u8,

    // Next Header / Protocol values
    pub const PROTO_HOPOPT: u8 = 0; // Hop-by-Hop Options
    pub const PROTO_ICMP: u8 = 1; // ICMP (IPv4, not used in IPv6)
    pub const PROTO_TCP: u8 = 6;
    pub const PROTO_UDP: u8 = 17;
    pub const PROTO_ROUTING: u8 = 43; // Routing Header
    pub const PROTO_FRAGMENT: u8 = 44; // Fragment Header
    pub const PROTO_ESP: u8 = 50; // Encapsulating Security Payload
    pub const PROTO_AH: u8 = 51; // Authentication Header
    pub const PROTO_ICMPV6: u8 = 58; // ICMPv6
    pub const PROTO_NONE: u8 = 59; // No Next Header
    pub const PROTO_DSTOPTS: u8 = 60; // Destination Options

    /// Default hop limit for outgoing packets
    pub const DEFAULT_HOP_LIMIT: u8 = 64;

    /// Get IP version (should always be 6)
    pub fn getVersion(self: *align(1) const Ipv6Header) u4 {
        return @truncate(@byteSwap(self.version_tc_flow) >> 28);
    }

    /// Get traffic class (8 bits, similar to IPv4 TOS/DSCP)
    pub fn getTrafficClass(self: *align(1) const Ipv6Header) u8 {
        return @truncate((@byteSwap(self.version_tc_flow) >> 20) & 0xFF);
    }

    /// Get flow label (20 bits, for QoS and traffic management)
    pub fn getFlowLabel(self: *align(1) const Ipv6Header) u20 {
        return @truncate(@byteSwap(self.version_tc_flow) & 0xFFFFF);
    }

    /// Set version, traffic class, and flow label
    pub fn setVersionTcFlow(self: *align(1) Ipv6Header, version: u4, tc: u8, flow: u20) void {
        const val: u32 = (@as(u32, version) << 28) |
            (@as(u32, tc) << 20) |
            @as(u32, flow);
        self.version_tc_flow = @byteSwap(val);
    }

    /// Get payload length in host byte order
    pub fn getPayloadLength(self: *align(1) const Ipv6Header) u16 {
        return @byteSwap(self.payload_length);
    }

    /// Set payload length from host byte order
    pub fn setPayloadLength(self: *align(1) Ipv6Header, len: u16) void {
        self.payload_length = @byteSwap(len);
    }

    /// Check if next_header is an extension header type
    pub fn isExtensionHeader(next_hdr: u8) bool {
        return next_hdr == PROTO_HOPOPT or
            next_hdr == PROTO_ROUTING or
            next_hdr == PROTO_FRAGMENT or
            next_hdr == PROTO_DSTOPTS or
            next_hdr == PROTO_AH;
        // Note: ESP (50) is special - it encrypts the rest
    }

    comptime {
        if (@sizeOf(Ipv6Header) != 40) @compileError("Ipv6Header must be 40 bytes");
    }
};

/// IPv6 Extension Header common format (first 2 bytes)
/// Used for Hop-by-Hop, Routing, and Destination Options headers.
/// Fragment header has a different format.
pub const Ipv6ExtHeader = extern struct {
    next_header: u8,
    /// Length in 8-octet units, NOT counting the first 8 octets
    hdr_ext_len: u8,

    /// Get total header length in bytes
    pub fn getTotalLength(self: *align(1) const Ipv6ExtHeader) usize {
        return (@as(usize, self.hdr_ext_len) + 1) * 8;
    }
};

/// IPv6 Fragment Header (8 bytes)
pub const Ipv6FragmentHeader = extern struct {
    next_header: u8,
    reserved: u8,
    /// Fragment offset (13 bits) + reserved (2 bits) + M flag (1 bit)
    frag_offset_m: u16,
    /// Identification (for reassembly)
    identification: u32,

    /// Get fragment offset in 8-octet units (0-8191)
    pub fn getFragmentOffset(self: *align(1) const Ipv6FragmentHeader) u13 {
        return @truncate(@byteSwap(self.frag_offset_m) >> 3);
    }

    /// Get fragment offset in bytes
    pub fn getFragmentOffsetBytes(self: *align(1) const Ipv6FragmentHeader) usize {
        return @as(usize, self.getFragmentOffset()) * 8;
    }

    /// Check if More Fragments flag is set
    pub fn hasMoreFragments(self: *align(1) const Ipv6FragmentHeader) bool {
        return (@byteSwap(self.frag_offset_m) & 1) != 0;
    }

    /// Check if this is the first fragment (offset == 0)
    pub fn isFirstFragment(self: *align(1) const Ipv6FragmentHeader) bool {
        return self.getFragmentOffset() == 0;
    }

    /// Check if this is the last fragment (M flag == 0)
    pub fn isLastFragment(self: *align(1) const Ipv6FragmentHeader) bool {
        return !self.hasMoreFragments();
    }

    /// Set fragment offset and M flag
    pub fn setFragmentOffsetM(self: *align(1) Ipv6FragmentHeader, offset: u13, more: bool) void {
        const val: u16 = (@as(u16, offset) << 3) | @as(u16, if (more) 1 else 0);
        self.frag_offset_m = @byteSwap(val);
    }

    comptime {
        if (@sizeOf(Ipv6FragmentHeader) != 8) @compileError("Ipv6FragmentHeader must be 8 bytes");
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

/// Get IPv6 header from buffer with bounds checking.
/// Returns null if buffer is too small to contain an IPv6 header.
pub fn getIpv6Header(buf: []const u8, offset: usize) ?*align(1) const Ipv6Header {
    const end = std.math.add(usize, offset, IPV6_HEADER_SIZE) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get mutable IPv6 header from buffer with bounds checking.
pub fn getIpv6HeaderMut(buf: []u8, offset: usize) ?*align(1) Ipv6Header {
    const end = std.math.add(usize, offset, IPV6_HEADER_SIZE) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get IPv6 extension header from buffer with bounds checking.
pub fn getIpv6ExtHeader(buf: []const u8, offset: usize) ?*align(1) const Ipv6ExtHeader {
    const end = std.math.add(usize, offset, 2) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get IPv6 fragment header from buffer with bounds checking.
pub fn getIpv6FragmentHeader(buf: []const u8, offset: usize) ?*align(1) const Ipv6FragmentHeader {
    const end = std.math.add(usize, offset, 8) catch return null;
    if (end > buf.len) return null;
    return @ptrCast(&buf[offset]);
}

/// Get mutable IPv6 fragment header from buffer with bounds checking.
pub fn getIpv6FragmentHeaderMut(buf: []u8, offset: usize) ?*align(1) Ipv6FragmentHeader {
    const end = std.math.add(usize, offset, 8) catch return null;
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
