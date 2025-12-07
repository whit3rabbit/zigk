// Network Packet Buffer
//
// Zero-copy packet buffer for network stack processing.
// Packets flow from driver through protocol layers with minimal copying.
//
// Design:
//   - Fixed-size buffers from driver's pre-allocated pool
//   - Layer offsets track header positions for easy access
//   - Reference counting for shared packet handling

/// Maximum packet size (MTU + headers)
pub const MAX_PACKET_SIZE: usize = 2048;

/// Ethernet header size
pub const ETH_HEADER_SIZE: usize = 14;
/// IPv4 header size (minimum, without options)
pub const IP_HEADER_SIZE: usize = 20;
/// UDP header size
pub const UDP_HEADER_SIZE: usize = 8;
/// ICMP header size
pub const ICMP_HEADER_SIZE: usize = 8;

/// Packet buffer for zero-copy networking
pub const PacketBuffer = struct {
    /// Pointer to raw packet data
    data: [*]u8,
    /// Total data length
    len: usize,
    /// Buffer capacity
    capacity: usize,

    /// Layer offsets (set during parsing/building)
    eth_offset: usize,
    ip_offset: usize,
    transport_offset: usize,
    payload_offset: usize,

    /// Source information (set on receive)
    src_mac: [6]u8,
    src_ip: u32,
    src_port: u16,

    /// Protocol info
    ethertype: u16,
    ip_protocol: u8,

    const Self = @This();

    /// Initialize from raw buffer
    pub fn init(data: [*]u8, len: usize, capacity: usize) Self {
        return Self{
            .data = data,
            .len = len,
            .capacity = capacity,
            .eth_offset = 0,
            .ip_offset = 0,
            .transport_offset = 0,
            .payload_offset = 0,
            .src_mac = [_]u8{0} ** 6,
            .src_ip = 0,
            .src_port = 0,
            .ethertype = 0,
            .ip_protocol = 0,
        };
    }

    /// Get Ethernet header pointer
    pub fn ethHeader(self: *const Self) *EthernetHeader {
        return @ptrCast(@alignCast(self.data + self.eth_offset));
    }

    /// Get IPv4 header pointer
    pub fn ipHeader(self: *const Self) *Ipv4Header {
        return @ptrCast(@alignCast(self.data + self.ip_offset));
    }

    /// Get UDP header pointer
    pub fn udpHeader(self: *const Self) *UdpHeader {
        return @ptrCast(@alignCast(self.data + self.transport_offset));
    }

    /// Get ICMP header pointer
    pub fn icmpHeader(self: *const Self) *IcmpHeader {
        return @ptrCast(@alignCast(self.data + self.transport_offset));
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

    /// Get raw data slice
    pub fn getData(self: *const Self) []u8 {
        return self.data[0..self.len];
    }

    /// Prepend space for a header (for building outgoing packets)
    pub fn prependHeader(self: *Self, size: usize) bool {
        if (self.eth_offset < size) {
            return false; // No room
        }
        self.eth_offset -= size;
        self.len += size;
        return true;
    }

    /// Copy data into packet at current position
    pub fn appendData(self: *Self, src: []const u8) bool {
        if (self.len + src.len > self.capacity) {
            return false;
        }
        @memcpy(self.data[self.len..][0..src.len], src);
        self.len += src.len;
        return true;
    }
};

// ============================================================================
// Protocol Header Structures
// ============================================================================

/// Ethernet header (14 bytes)
pub const EthernetHeader = extern struct {
    dst_mac: [6]u8,
    src_mac: [6]u8,
    ethertype: u16, // Network byte order

    pub const ETHERTYPE_IPV4: u16 = 0x0008; // 0x0800 in network order
    pub const ETHERTYPE_ARP: u16 = 0x0608;  // 0x0806 in network order

    /// Get ethertype in host byte order
    pub fn getEthertype(self: *const EthernetHeader) u16 {
        return @byteSwap(self.ethertype);
    }

    /// Set ethertype from host byte order
    pub fn setEthertype(self: *EthernetHeader, value: u16) void {
        self.ethertype = @byteSwap(value);
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
    pub fn getVersion(self: *const Ipv4Header) u4 {
        return @truncate(self.version_ihl >> 4);
    }

    /// Get header length in bytes
    pub fn getHeaderLength(self: *const Ipv4Header) usize {
        return @as(usize, self.version_ihl & 0x0F) * 4;
    }

    /// Get total length in host byte order
    pub fn getTotalLength(self: *const Ipv4Header) u16 {
        return @byteSwap(self.total_length);
    }

    /// Set total length from host byte order
    pub fn setTotalLength(self: *Ipv4Header, value: u16) void {
        self.total_length = @byteSwap(value);
    }

    /// Get source IP in host byte order
    pub fn getSrcIp(self: *const Ipv4Header) u32 {
        return @byteSwap(self.src_ip);
    }

    /// Get destination IP in host byte order
    pub fn getDstIp(self: *const Ipv4Header) u32 {
        return @byteSwap(self.dst_ip);
    }

    /// Set source IP from host byte order
    pub fn setSrcIp(self: *Ipv4Header, value: u32) void {
        self.src_ip = @byteSwap(value);
    }

    /// Set destination IP from host byte order
    pub fn setDstIp(self: *Ipv4Header, value: u32) void {
        self.dst_ip = @byteSwap(value);
    }
};

/// UDP header (8 bytes)
pub const UdpHeader = extern struct {
    src_port: u16,  // Network byte order
    dst_port: u16,
    length: u16,
    checksum: u16,

    /// Get source port in host byte order
    pub fn getSrcPort(self: *const UdpHeader) u16 {
        return @byteSwap(self.src_port);
    }

    /// Get destination port in host byte order
    pub fn getDstPort(self: *const UdpHeader) u16 {
        return @byteSwap(self.dst_port);
    }

    /// Set source port from host byte order
    pub fn setSrcPort(self: *UdpHeader, value: u16) void {
        self.src_port = @byteSwap(value);
    }

    /// Set destination port from host byte order
    pub fn setDstPort(self: *UdpHeader, value: u16) void {
        self.dst_port = @byteSwap(value);
    }

    /// Get length in host byte order
    pub fn getLength(self: *const UdpHeader) u16 {
        return @byteSwap(self.length);
    }

    /// Set length from host byte order
    pub fn setLength(self: *UdpHeader, value: u16) void {
        self.length = @byteSwap(value);
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
    pub fn getIdentifier(self: *const IcmpHeader) u16 {
        return @byteSwap(self.identifier);
    }

    /// Get sequence in host byte order
    pub fn getSequence(self: *const IcmpHeader) u16 {
        return @byteSwap(self.sequence);
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
    sender_ip: u32,
    target_mac: [6]u8,
    target_ip: u32,

    pub const OP_REQUEST: u16 = 0x0100; // 1 in network byte order
    pub const OP_REPLY: u16 = 0x0200;   // 2 in network byte order

    /// Get operation in host byte order
    pub fn getOperation(self: *const ArpHeader) u16 {
        return @byteSwap(self.operation);
    }

    /// Get sender IP in host byte order
    pub fn getSenderIp(self: *const ArpHeader) u32 {
        return @byteSwap(self.sender_ip);
    }

    /// Get target IP in host byte order
    pub fn getTargetIp(self: *const ArpHeader) u32 {
        return @byteSwap(self.target_ip);
    }
};
