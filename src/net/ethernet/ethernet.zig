// Ethernet Frame Processing
//
// Handles Ethernet II frame parsing and building.
// Dispatches to IPv4 or ARP based on ethertype.
//
// RFC 894: Standard for transmission of IP datagrams over Ethernet

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

/// Process an incoming Ethernet frame
/// Returns true if frame was handled, false if dropped
pub fn processFrame(iface: *Interface, pkt: *PacketBuffer) bool {
    // Validate minimum frame size (14 byte header + some payload)
    if (pkt.len < packet.ETH_HEADER_SIZE + 1) {
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
pub fn buildFrame(iface: *const Interface, pkt: *PacketBuffer, dst_mac: [6]u8, ethertype: u16) void {
    const eth = pkt.ethHeader();

    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethertype);

    pkt.ethertype = ethertype;
}

/// Send a raw Ethernet frame
pub fn sendFrame(iface: *Interface, pkt: *PacketBuffer) bool {
    if (!iface.is_up) {
        return false;
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
