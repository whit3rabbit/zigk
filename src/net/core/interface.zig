// Network Interface Abstraction
//
// Represents a network interface (NIC) and provides a common API
// for the network stack to send/receive packets.

const std = @import("std");
const packet = @import("packet.zig");
const PacketBuffer = packet.PacketBuffer;

pub const MAX_MULTICAST_ADDRESSES: usize = 32;

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

    /// Whether to accept all multicast frames at L2 (software filter still runs)
    /// RFC 1112 requires delivery of joined multicast groups; this flag is a
    /// permissive default until IGMP joins drive the filter.
    accept_all_multicast: bool,

    /// Multicast MAC subscriptions (software filter)
    multicast_addrs: [MAX_MULTICAST_ADDRESSES][6]u8,
    multicast_count: usize,

    /// Optional callback for driver-specific multicast filter updates
    update_multicast_fn: ?*const fn (*Interface) void,

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
            .accept_all_multicast = true,
            .multicast_addrs = [_][6]u8{[_]u8{0} ** 6} ** MAX_MULTICAST_ADDRESSES,
            .multicast_count = 0,
            .update_multicast_fn = null,
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

    /// Set driver hook for multicast filter programming
    pub fn setMulticastUpdateFn(self: *Self, func: *const fn (*Interface) void) void {
        self.update_multicast_fn = func;
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
        const len = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..len];
    }

    /// Join a multicast MAC address (software filter).
    /// RFC 1112 maps IPv4 multicast to 01:00:5e:xx:xx:xx; caller supplies the MAC.
    pub fn joinMulticastMac(self: *Self, mac: [6]u8) bool {
        if (!isMulticastMac(mac)) return false;
        if (self.acceptsMulticastMac(mac)) return true; // already present
        if (self.multicast_count >= MAX_MULTICAST_ADDRESSES) return false;
        self.multicast_addrs[self.multicast_count] = mac;
        self.multicast_count += 1;
        if (self.update_multicast_fn) |cb| cb(self);
        return true;
    }

    /// Leave a multicast MAC address (software filter)
    pub fn leaveMulticastMac(self: *Self, mac: [6]u8) bool {
        const idx = self.findMulticastIndex(mac) orelse return false;
        // Compact array
        const last = self.multicast_count - 1;
        self.multicast_addrs[idx] = self.multicast_addrs[last];
        self.multicast_addrs[last] = [_]u8{0} ** 6;
        self.multicast_count = last;
        if (self.update_multicast_fn) |cb| cb(self);
        return true;
    }

    /// Check if multicast MAC is subscribed
    pub fn acceptsMulticastMac(self: *const Self, mac: [6]u8) bool {
        if (!isMulticastMac(mac)) return false;
        return self.findMulticastIndex(mac) != null;
    }

    fn findMulticastIndex(self: *const Self, mac: [6]u8) ?usize {
        var i: usize = 0;
        while (i < self.multicast_count) : (i += 1) {
            if (macEqual(self.multicast_addrs[i], mac)) {
                return i;
            }
        }
        return null;
    }

    /// Access subscribed multicast MACs
    pub fn getMulticastMacs(self: *const Self) []const [6]u8 {
        return self.multicast_addrs[0..self.multicast_count];
    }
};

fn isMulticastMac(mac: [6]u8) bool {
    return (mac[0] & 0x01) != 0;
}

fn macEqual(a: [6]u8, b: [6]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and
        a[3] == b[3] and a[4] == b[4] and a[5] == b[5];
}

/// Convert IP address to dotted-decimal string (for logging)
pub fn ipToString(ip: u32, buf: []u8) []const u8 {
    const a: u8 = @truncate(ip >> 24);
    const b: u8 = @truncate(ip >> 16);
    const c: u8 = @truncate(ip >> 8);
    const d: u8 = @truncate(ip);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a, b, c, d }) catch "0.0.0.0";
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
