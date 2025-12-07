// IPv4 Protocol Implementation
//
// RFC 791: Internet Protocol
//
// Handles IPv4 packet parsing, validation, and building.
// Dispatches to ICMP, UDP based on protocol field.

const packet = @import("../core/packet.zig");
const interface = @import("../core/interface.zig");
const checksum = @import("../core/checksum.zig");
const ethernet = @import("../ethernet/ethernet.zig");
const arp = @import("arp.zig");
const PacketBuffer = packet.PacketBuffer;
const Ipv4Header = packet.Ipv4Header;
const EthernetHeader = packet.EthernetHeader;
const Interface = interface.Interface;

// Forward declarations for transport protocols
const icmp = @import("../transport/icmp.zig");
const udp = @import("../transport/udp.zig");

/// IP protocol numbers
pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

/// Default TTL for outgoing packets
pub const DEFAULT_TTL: u8 = 64;

/// IP identification counter for fragmentation
var ip_id_counter: u16 = 0;

/// Process an incoming IPv4 packet
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    // Validate minimum IP header size
    if (pkt.len < pkt.ip_offset + packet.IP_HEADER_SIZE) {
        return false;
    }

    const ip = pkt.ipHeader();

    // Validate IP version (must be 4)
    if (ip.getVersion() != 4) {
        return false;
    }

    // Validate IHL (must be at least 5 = 20 bytes)
    const ihl = ip.version_ihl & 0x0F;
    if (ihl < 5) {
        return false;
    }

    const header_len = @as(usize, ihl) * 4;

    // Validate header checksum
    const header_bytes = pkt.data[pkt.ip_offset..][0..header_len];
    if (!checksum.verifyIpChecksum(header_bytes)) {
        return false;
    }

    // Validate total length
    const total_len = ip.getTotalLength();
    if (total_len < header_len or pkt.ip_offset + total_len > pkt.len) {
        return false;
    }

    // Check if packet is for us
    const dst_ip = ip.getDstIp();
    if (dst_ip != iface.ip_addr and dst_ip != 0xFFFFFFFF) {
        // Not for us and not broadcast - drop
        return false;
    }

    // Check for fragmentation - we don't support it in MVP
    // MF (More Fragments) bit or Fragment Offset != 0
    const flags_frag = @byteSwap(ip.flags_fragment);
    const mf_bit = (flags_frag >> 13) & 0x1;
    const frag_offset = flags_frag & 0x1FFF;

    if (mf_bit != 0 or frag_offset != 0) {
        // Fragmented packet - drop for now
        return false;
    }

    // Set transport layer offset
    pkt.transport_offset = pkt.ip_offset + header_len;
    pkt.ip_protocol = ip.protocol;

    // Record source IP
    pkt.src_ip = ip.getSrcIp();

    // Calculate payload offset (after transport header)
    // This will be set by transport layer

    // Dispatch based on protocol
    switch (ip.protocol) {
        PROTO_ICMP => {
            return icmp.processPacket(iface, pkt);
        },
        PROTO_UDP => {
            return udp.processPacket(iface, pkt);
        },
        PROTO_TCP => {
            // TCP not implemented
            return false;
        },
        else => {
            return false;
        },
    }
}

/// Build an IPv4 packet header
/// Assumes Ethernet header is already in place
/// Sets up IP header and returns pointer to payload area
pub fn buildPacket(
    iface: *const Interface,
    pkt: *PacketBuffer,
    dst_ip: u32,
    protocol: u8,
    payload_len: usize,
) bool {
    // IP header starts after Ethernet header
    pkt.ip_offset = packet.ETH_HEADER_SIZE;
    pkt.transport_offset = pkt.ip_offset + packet.IP_HEADER_SIZE;

    const ip: *Ipv4Header = @ptrCast(@alignCast(pkt.data + pkt.ip_offset));

    // Version 4, IHL 5 (20 bytes, no options)
    ip.version_ihl = 0x45;
    ip.tos = 0;
    ip.setTotalLength(@truncate(packet.IP_HEADER_SIZE + payload_len));

    // Increment ID for each packet
    ip_id_counter +%= 1;
    ip.identification = @byteSwap(ip_id_counter);

    // Don't Fragment flag set, no fragmentation offset
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));

    ip.ttl = DEFAULT_TTL;
    ip.protocol = protocol;
    ip.checksum = 0; // Will calculate after filling header

    ip.setSrcIp(iface.ip_addr);
    ip.setDstIp(dst_ip);

    // Calculate and set header checksum
    const header_bytes = pkt.data[pkt.ip_offset..][0..packet.IP_HEADER_SIZE];
    ip.checksum = checksum.ipChecksum(header_bytes);

    return true;
}

/// Send an IP packet
/// Resolves destination MAC via ARP and transmits
pub fn sendPacket(iface: *Interface, pkt: *PacketBuffer, dst_ip: u32) bool {
    // Determine next-hop IP (gateway if not on local subnet)
    const next_hop = iface.getGateway(dst_ip);

    // Resolve MAC address
    const dst_mac = arp.resolveOrRequest(iface, next_hop) orelse {
        // ARP not resolved yet - packet will be dropped
        // A real implementation would queue the packet
        return false;
    };

    // Build Ethernet header
    ethernet.buildFrame(iface, pkt, dst_mac, ethernet.ETHERTYPE_IPV4);

    // Update packet length
    const ip = pkt.ipHeader();
    pkt.len = pkt.ip_offset + ip.getTotalLength();

    // Transmit
    return ethernet.sendFrame(iface, pkt);
}

/// Decrement TTL and update checksum (for routing, if we ever support it)
pub fn decrementTtl(pkt: *PacketBuffer) bool {
    const ip = pkt.ipHeader();

    if (ip.ttl <= 1) {
        return false; // TTL expired
    }

    // Use incremental checksum update
    const old_ttl = ip.ttl;
    ip.ttl -= 1;

    // Update checksum: TTL is in high byte of a 16-bit word with protocol
    const old_value = (@as(u16, old_ttl) << 8) | ip.protocol;
    const new_value = (@as(u16, ip.ttl) << 8) | ip.protocol;
    ip.checksum = checksum.updateChecksum(ip.checksum, old_value, new_value);

    return true;
}

/// Get next IP identification value
pub fn getNextId() u16 {
    ip_id_counter +%= 1;
    return ip_id_counter;
}

/// Check if IP is broadcast (all 1s or directed broadcast)
pub fn isBroadcast(ip: u32, netmask: u32) bool {
    if (ip == 0xFFFFFFFF) {
        return true;
    }
    // Directed broadcast: all host bits are 1
    const host_mask = ~netmask;
    return (ip & host_mask) == host_mask;
}

/// Check if IP is multicast (224.0.0.0 - 239.255.255.255)
pub fn isMulticast(ip: u32) bool {
    return (ip >> 24) >= 224 and (ip >> 24) <= 239;
}

/// Check if IP is loopback (127.x.x.x)
pub fn isLoopback(ip: u32) bool {
    return (ip >> 24) == 127;
}
