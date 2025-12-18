// Ethernet Frame Processing
//
// Handles Ethernet II frame parsing and building.
// Dispatches to IPv4 or ARP based on ethertype.
//
// Complies with:
// - IEEE 802.3 (Ethernet)
// - RFC 894: Standard for transmission of IP datagrams over Ethernet
//
// Frame Format (Ethernet II):
// +--------------+--------------+-----------+----------------------+
// | Dest MAC (6) | Src MAC (6)  | Type (2)  | Payload (46-1500)    |
// +--------------+--------------+-----------+----------------------+
// | Frame Check Sequence (4) - Handled by Nic Hardware usually     |
// +----------------------------------------------------------------+

const std = @import("std");
const packet = @import("../core/packet.zig");
const interface = @import("../core/interface.zig");
const PacketBuffer = packet.PacketBuffer;
const EthernetHeader = packet.EthernetHeader;
const Interface = interface.Interface;

// Import protocol handlers (will be implemented)
const ipv4 = @import("../ipv4/ipv4.zig");
const arp = @import("../ipv4/arp.zig");

/// Ethertype values in host byte order
pub const ETHERTYPE_IPV4: u16 = 0x0800;
pub const ETHERTYPE_ARP: u16 = 0x0806;
pub const ETHERTYPE_IPV6: u16 = 0x86DD;

/// Broadcast MAC address
pub const BROADCAST_MAC: [6]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

/// Minimum Ethernet frame length (excluding FCS, which NIC strips)
/// 14 byte header + 46 byte payload = 60 bytes per IEEE 802.3 / RFC 894
pub const MIN_FRAME_SIZE_NO_FCS: usize = 60;

// Test helper: captures TX length for padding verification
var test_tx_len: usize = 0;

/// Process an incoming Ethernet frame
/// Returns true if frame was handled, false if dropped
pub fn processFrame(iface: *Interface, pkt: *PacketBuffer) bool {
    // Drop runts (under minimum Ethernet frame size without FCS)
    if (pkt.len < MIN_FRAME_SIZE_NO_FCS) {
        return false;
    }

    // Drop frames that exceed configured MTU (RFC 894: 1500 byte payload)
    const max_frame_len = packet.ETH_HEADER_SIZE + iface.mtu;
    if (pkt.len > max_frame_len) {
        return false;
    }

    const eth = pkt.ethHeader();

    // Check if frame is for us (unicast to our MAC or broadcast)
    if (!isForUs(iface, eth.dst_mac)) {
        return false;
    }

    // Record source MAC for potential ARP learning
    @memcpy(&pkt.src_mac, &eth.src_mac);

    // Set layer offsets
    pkt.eth_offset = 0;
    pkt.ip_offset = packet.ETH_HEADER_SIZE;
    pkt.ethertype = eth.getEthertype();

    // Dispatch based on ethertype
    switch (pkt.ethertype) {
        ETHERTYPE_IPV4 => {
            return ipv4.processPacket(iface, pkt);
        },
        ETHERTYPE_ARP => {
            return arp.processPacket(iface, pkt);
        },
        else => {
            // Unknown ethertype - drop
            return false;
        },
    }
}

/// Check if a frame is destined for this interface
fn isForUs(iface: *const Interface, dst_mac: [6]u8) bool {
    // Accept broadcast
    if (isBroadcast(dst_mac)) {
        return true;
    }

    // Accept multicast if subscribed (RFC 1112 host requirement)
    if (isMulticast(dst_mac)) {
        if (iface.accept_all_multicast) return true;
        if (iface.acceptsMulticastMac(dst_mac)) return true;
    }

    // Accept our unicast MAC
    return macEqual(dst_mac, iface.mac_addr);
}

/// Check if MAC is broadcast address
pub fn isBroadcast(mac: [6]u8) bool {
    return mac[0] == 0xFF and mac[1] == 0xFF and mac[2] == 0xFF and
        mac[3] == 0xFF and mac[4] == 0xFF and mac[5] == 0xFF;
}

/// Check if MAC is multicast (bit 0 of first byte set)
pub fn isMulticast(mac: [6]u8) bool {
    return (mac[0] & 0x01) != 0;
}

/// Compare two MAC addresses
pub fn macEqual(a: [6]u8, b: [6]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and
        a[3] == b[3] and a[4] == b[4] and a[5] == b[5];
}

/// Build an Ethernet frame header
/// Prepends Ethernet header to packet and sets fields
/// Returns false if buffer is too small to hold the header at eth_offset
pub fn buildFrame(iface: *const Interface, pkt: *PacketBuffer, dst_mac: [6]u8, ethertype: u16) bool {
    // Bounds check: ensure buffer can hold 14-byte Ethernet header at specified offset
    if (pkt.eth_offset + packet.ETH_HEADER_SIZE > pkt.data.len) {
        return false;
    }

    const eth = pkt.ethHeader();

    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethertype);

    pkt.ethertype = ethertype;
    return true;
}

/// Send a raw Ethernet frame
pub fn sendFrame(iface: *Interface, pkt: *PacketBuffer) bool {
    if (!iface.is_up) {
        return false;
    }

    // Enforce MTU (payload) limit at L2 (RFC 894)
    const max_frame_len = packet.ETH_HEADER_SIZE + iface.mtu;
    if (pkt.len > max_frame_len) {
        return false;
    }

    // Pad short frames to Ethernet minimum, zeroing padding to avoid data leaks
    if (pkt.len < MIN_FRAME_SIZE_NO_FCS) {
        const pad_len = MIN_FRAME_SIZE_NO_FCS - pkt.len;
        if (pkt.len + pad_len > pkt.data.len) {
            return false;
        }
        // Zero padding bytes per RFC 894; prevents leaking stale buffer data
        std.mem.set(u8, pkt.data[pkt.len..][0..pad_len], 0);
        pkt.len = MIN_FRAME_SIZE_NO_FCS;
    }

    return iface.transmit(pkt.getData());
}

/// Format MAC address to string (for logging)
pub fn macToString(mac: [6]u8, buf: []u8) []u8 {
    if (buf.len < 17) {
        return buf[0..0];
    }

    const hex = "0123456789ABCDEF";
    var pos: usize = 0;

    for (mac, 0..) |byte, i| {
        buf[pos] = hex[byte >> 4];
        buf[pos + 1] = hex[byte & 0x0F];
        pos += 2;

        if (i < 5) {
            buf[pos] = ':';
            pos += 1;
        }
    }

    return buf[0..17];
}

test "ethernet multicast filtering" {
    const testing = std.testing;
    var iface = Interface.init("eth0", .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 });

    const mc = [6]u8{ 0x01, 0x00, 0x5E, 0x00, 0x00, 0x01 }; // RFC 1112 mapped MAC

    // Default: accept all multicast
    try testing.expect(isForUs(&iface, mc));

    // Disable all-multicast; drop until explicitly joined
    iface.accept_all_multicast = false;
    try testing.expect(!isForUs(&iface, mc));

    // Join multicast MAC and accept again
    try testing.expect(iface.joinMulticastMac(mc));
    try testing.expect(isForUs(&iface, mc));
}

test "ethernet runt and oversize drops" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var iface = Interface.init("eth0", .{ 0, 1, 2, 3, 4, 5 });

    // Runt (<60 bytes) is dropped before parsing header
    var pkt = PacketBuffer.init(&buf, MIN_FRAME_SIZE_NO_FCS - 1);
    try testing.expect(!processFrame(&iface, &pkt));

    // Oversize (>MTU + header) dropped before parsing header
    pkt.len = packet.ETH_HEADER_SIZE + iface.mtu + 1;
    try testing.expect(!processFrame(&iface, &pkt));
}

test "ethernet pads short transmit frames" {
    const testing = std.testing;
    test_tx_len = 0;

    var buf: [80]u8 = undefined;
    var iface = Interface.init("eth0", .{ 0, 1, 2, 3, 4, 5 });
    iface.up();
    iface.setTransmitFn(struct {
        fn tx(data: []const u8) bool {
            test_tx_len = data.len;
            return true;
        }
    }.tx);

    // Build minimal frame shorter than Ethernet minimum
    var pkt = PacketBuffer.init(&buf, 0);
    pkt.eth_offset = 0;
    pkt.len = packet.ETH_HEADER_SIZE + 10;
    const eth = pkt.ethHeader();
    eth.dst_mac = .{ 0, 1, 2, 3, 4, 6 };
    eth.src_mac = iface.mac_addr;
    eth.setEthertype(ETHERTYPE_IPV4);

    try testing.expect(sendFrame(&iface, &pkt));
    try testing.expectEqual(@as(usize, MIN_FRAME_SIZE_NO_FCS), test_tx_len);
}
