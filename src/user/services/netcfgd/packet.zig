//! DHCP Packet Structures (RFC 2131)
//!
//! Defines the DHCP message format used in both DHCPv4
//! and BOOTP communications.

/// DHCP operation codes
pub const BOOTREQUEST: u8 = 1;
pub const BOOTREPLY: u8 = 2;

/// DHCP magic cookie (RFC 2131)
pub const DHCP_MAGIC: u32 = 0x63825363;

/// DHCP packet structure (548 bytes fixed + variable options)
/// Based on RFC 2131 Section 2
pub const DhcpPacket = extern struct {
    /// Message op code: 1 = BOOTREQUEST, 2 = BOOTREPLY
    op: u8,
    /// Hardware address type: 1 = Ethernet
    htype: u8,
    /// Hardware address length: 6 for Ethernet
    hlen: u8,
    /// Client sets to zero, optionally used by relay agents
    hops: u8,
    /// Transaction ID, random number chosen by client
    xid: u32,
    /// Seconds elapsed since client began address acquisition
    secs: u16,
    /// Flags (bit 0 = broadcast flag)
    flags: u16,
    /// Client IP address (only if client is bound/renewing)
    ciaddr: u32,
    /// 'Your' (client) IP address - filled by server
    yiaddr: u32,
    /// Server IP address
    siaddr: u32,
    /// Relay agent IP address
    giaddr: u32,
    /// Client hardware address (MAC)
    chaddr: [16]u8,
    /// Server host name (null terminated)
    sname: [64]u8,
    /// Boot file name (null terminated)
    file: [128]u8,
    /// DHCP magic cookie
    magic_cookie: u32,
    /// Options (variable, up to 308 bytes - magic cookie is separate field)
    options: [308]u8,

    comptime {
        // Verify structure size matches RFC 2131
        if (@sizeOf(@This()) != 548) {
            @compileError("DhcpPacket must be 548 bytes");
        }
    }
};

/// DHCPv6 Message Types (RFC 8415)
pub const Dhcpv6MsgType = enum(u8) {
    Solicit = 1,
    Advertise = 2,
    Request = 3,
    Confirm = 4,
    Renew = 5,
    Rebind = 6,
    Reply = 7,
    Release = 8,
    Decline = 9,
    Reconfigure = 10,
    InformationRequest = 11,
    RelayForw = 12,
    RelayRepl = 13,
};

/// DHCPv6 option types (RFC 8415)
pub const Dhcpv6Option = enum(u16) {
    ClientId = 1,
    ServerId = 2,
    IaNa = 3,
    IaTa = 4,
    IaAddr = 5,
    OptionRequest = 6,
    Preference = 7,
    ElapsedTime = 8,
    StatusCode = 13,
    RapidCommit = 14,
    DnsServers = 23,
    DomainList = 24,
};

/// DHCPv6 DUID types (RFC 8415)
pub const DuidType = enum(u16) {
    /// Link-layer address plus time (DUID-LLT)
    Llt = 1,
    /// Vendor-assigned unique ID (DUID-EN)
    En = 2,
    /// Link-layer address (DUID-LL)
    Ll = 3,
    /// UUID-based DUID (DUID-UUID)
    Uuid = 4,
};

/// DHCPv6 message header
pub const Dhcpv6Header = extern struct {
    /// Message type (upper byte) and transaction ID (lower 3 bytes)
    msg_type_and_xid: u32,

    pub fn getMsgType(self: *const Dhcpv6Header) u8 {
        return @truncate(@byteSwap(self.msg_type_and_xid) >> 24);
    }

    pub fn getTransactionId(self: *const Dhcpv6Header) u24 {
        return @truncate(@byteSwap(self.msg_type_and_xid) & 0xFFFFFF);
    }

    pub fn init(msg_type: Dhcpv6MsgType, xid: u24) Dhcpv6Header {
        const val = (@as(u32, @intFromEnum(msg_type)) << 24) | @as(u32, xid);
        return .{ .msg_type_and_xid = @byteSwap(val) };
    }
};
