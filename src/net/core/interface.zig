// Network Interface Abstraction
//
// Represents a network interface (NIC) and provides a common API
// for the network stack to send/receive packets.

const packet = @import("packet.zig");
const PacketBuffer = packet.PacketBuffer;

/// Network interface structure
pub const Interface = struct {
    /// Interface name for debugging
    name: [16]u8,

    /// MAC address
    mac_addr: [6]u8,

    /// IPv4 address (host byte order)
    ip_addr: u32,

    /// Subnet mask (host byte order)
    netmask: u32,

    /// Gateway IP (host byte order)
    gateway: u32,

    /// MTU (Maximum Transmission Unit)
    mtu: u16,

    /// Transmit function (driver-specific)
    transmit_fn: ?*const fn ([]const u8) bool,

    /// Interface is up and running
    is_up: bool,

    /// Link is connected
    link_up: bool,

    /// Statistics
    rx_packets: u64,
    tx_packets: u64,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_errors: u64,
    tx_errors: u64,

    const Self = @This();

    /// Initialize a new interface
    pub fn init(name: []const u8, mac: [6]u8) Self {
        var iface = Self{
            .name = [_]u8{0} ** 16,
            .mac_addr = mac,
            .ip_addr = 0,
            .netmask = 0,
            .gateway = 0,
            .mtu = 1500,
            .transmit_fn = null,
            .is_up = false,
            .link_up = false,
            .rx_packets = 0,
            .tx_packets = 0,
            .rx_bytes = 0,
            .tx_bytes = 0,
            .rx_errors = 0,
            .tx_errors = 0,
        };

        const copy_len = @min(name.len, 15);
        @memcpy(iface.name[0..copy_len], name[0..copy_len]);

        return iface;
    }

    /// Set interface IP configuration
    pub fn configure(self: *Self, ip: u32, mask: u32, gw: u32) void {
        self.ip_addr = ip;
        self.netmask = mask;
        self.gateway = gw;
    }

    /// Set transmit function
    pub fn setTransmitFn(self: *Self, func: *const fn ([]const u8) bool) void {
        self.transmit_fn = func;
    }

    /// Bring interface up
    pub fn up(self: *Self) void {
        self.is_up = true;
    }

    /// Bring interface down
    pub fn down(self: *Self) void {
        self.is_up = false;
    }

    /// Transmit a packet
    pub fn transmit(self: *Self, data: []const u8) bool {
        if (!self.is_up) return false;

        if (self.transmit_fn) |tx| {
            if (tx(data)) {
                self.tx_packets += 1;
                self.tx_bytes += data.len;
                return true;
            } else {
                self.tx_errors += 1;
                return false;
            }
        }
        return false;
    }

    /// Check if an IP is on the local subnet
    pub fn isLocalSubnet(self: *const Self, ip: u32) bool {
        return (ip & self.netmask) == (self.ip_addr & self.netmask);
    }

    /// Get gateway for a destination IP
    pub fn getGateway(self: *const Self, dst_ip: u32) u32 {
        if (self.isLocalSubnet(dst_ip)) {
            return dst_ip; // Direct delivery
        }
        return self.gateway; // Route through gateway
    }

    /// Get interface name as slice
    pub fn getName(self: *const Self) []const u8 {
        var len: usize = 0;
        while (len < 16 and self.name[len] != 0) : (len += 1) {}
        return self.name[0..len];
    }
};

/// Convert IP address to dotted-decimal string (for logging)
pub fn ipToString(ip: u32, buf: []u8) []u8 {
    const a: u8 = @truncate(ip >> 24);
    const b: u8 = @truncate(ip >> 16);
    const c: u8 = @truncate(ip >> 8);
    const d: u8 = @truncate(ip);

    var pos: usize = 0;
    pos += writeDecimal(buf[pos..], a);
    buf[pos] = '.';
    pos += 1;
    pos += writeDecimal(buf[pos..], b);
    buf[pos] = '.';
    pos += 1;
    pos += writeDecimal(buf[pos..], c);
    buf[pos] = '.';
    pos += 1;
    pos += writeDecimal(buf[pos..], d);

    return buf[0..pos];
}

fn writeDecimal(buf: []u8, value: u8) usize {
    if (value >= 100) {
        buf[0] = '0' + value / 100;
        buf[1] = '0' + (value / 10) % 10;
        buf[2] = '0' + value % 10;
        return 3;
    } else if (value >= 10) {
        buf[0] = '0' + value / 10;
        buf[1] = '0' + value % 10;
        return 2;
    } else {
        buf[0] = '0' + value;
        return 1;
    }
}

/// Parse dotted-decimal IP string to u32
pub fn parseIp(str: []const u8) ?u32 {
    var ip: u32 = 0;
    var octet: u32 = 0;
    var dot_count: usize = 0;

    for (str) |c| {
        if (c >= '0' and c <= '9') {
            octet = octet * 10 + (c - '0');
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
