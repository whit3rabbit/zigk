// UDP Protocol Implementation
//
// RFC 768: User Datagram Protocol
//
// Provides connectionless datagram service for applications.
// Will be expanded with socket integration in Phase 6.

const packet = @import("../core/packet.zig");
const interface = @import("../core/interface.zig");
const checksum = @import("../core/checksum.zig");
const ipv4 = @import("../ipv4/ipv4.zig");
const ethernet = @import("../ethernet/ethernet.zig");
const arp = @import("../ipv4/arp.zig");
const PacketBuffer = packet.PacketBuffer;
const UdpHeader = packet.UdpHeader;
const Ipv4Header = packet.Ipv4Header;
const EthernetHeader = packet.EthernetHeader;
const Interface = interface.Interface;

/// Maximum UDP payload size (MTU - IP header - UDP header)
pub const MAX_UDP_PAYLOAD: usize = 1500 - packet.IP_HEADER_SIZE - packet.UDP_HEADER_SIZE;

/// Process an incoming UDP packet
/// Returns true if packet was handled
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    _ = iface;

    // Validate minimum UDP header size
    if (pkt.len < pkt.transport_offset + packet.UDP_HEADER_SIZE) {
        return false;
    }

    const udp_hdr = pkt.udpHeader();
    const ip = pkt.ipHeader();

    // Get UDP length
    const udp_len = udp_hdr.getLength();
    if (udp_len < packet.UDP_HEADER_SIZE) {
        return false;
    }

    // Validate length against IP total length
    const ip_payload_len = ip.getTotalLength() - ip.getHeaderLength();
    if (udp_len > ip_payload_len) {
        return false;
    }

    // Verify UDP checksum (if non-zero)
    if (udp_hdr.checksum != 0) {
        const udp_data = pkt.data[pkt.transport_offset..][0..udp_len];
        const calc_checksum = checksum.udpChecksum(ip.src_ip, ip.dst_ip, udp_data);
        if (calc_checksum != 0 and udp_hdr.checksum != calc_checksum) {
            // Checksum mismatch
            return false;
        }
    }

    // Record source port
    pkt.src_port = udp_hdr.getSrcPort();

    // Set payload offset
    pkt.payload_offset = pkt.transport_offset + packet.UDP_HEADER_SIZE;

    // Deliver to socket layer
    const socket = @import("socket.zig");
    return socket.deliverUdpPacket(pkt);
}

/// Send a UDP datagram
/// Returns false if packet couldn't be sent
pub fn sendDatagram(
    iface: *Interface,
    dst_ip: u32,
    src_port: u16,
    dst_port: u16,
    data: []const u8,
) bool {
    if (data.len > MAX_UDP_PAYLOAD) {
        return false;
    }

    // Resolve destination MAC
    const next_hop = iface.getGateway(dst_ip);
    const dst_mac = arp.resolveOrRequest(iface, next_hop) orelse {
        return false;
    };

    // Calculate sizes
    const eth_len = packet.ETH_HEADER_SIZE;
    const ip_len = packet.IP_HEADER_SIZE;
    const udp_len = packet.UDP_HEADER_SIZE + data.len;
    const total_len = eth_len + ip_len + udp_len;

    var buf: [packet.MAX_PACKET_SIZE]u8 = undefined;
    if (total_len > buf.len) {
        return false;
    }

    // Build Ethernet header
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    // Build IP header
    const ip: *Ipv4Header = @ptrCast(@alignCast(&buf[eth_len]));
    ip.version_ihl = 0x45;
    ip.tos = 0;
    ip.setTotalLength(@truncate(ip_len + udp_len));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_UDP;
    ip.checksum = 0;
    ip.setSrcIp(iface.ip_addr);
    ip.setDstIp(dst_ip);
    ip.checksum = checksum.ipChecksum(buf[eth_len..][0..ip_len]);

    // Build UDP header
    const udp_hdr: *UdpHeader = @ptrCast(@alignCast(&buf[eth_len + ip_len]));
    udp_hdr.setSrcPort(src_port);
    udp_hdr.setDstPort(dst_port);
    udp_hdr.setLength(@truncate(udp_len));
    udp_hdr.checksum = 0;

    // Copy payload
    if (data.len > 0) {
        @memcpy(buf[eth_len + ip_len + packet.UDP_HEADER_SIZE ..][0..data.len], data);
    }

    // Calculate UDP checksum (with pseudo-header)
    const udp_data = buf[eth_len + ip_len ..][0..udp_len];
    udp_hdr.checksum = checksum.udpChecksum(ip.src_ip, ip.dst_ip, udp_data);

    // Transmit
    return iface.transmit(buf[0..total_len]);
}

/// Calculate payload length from UDP header
pub fn getPayloadLength(pkt: *const PacketBuffer) usize {
    const udp_hdr = pkt.udpHeader();
    const udp_len = udp_hdr.getLength();
    if (udp_len <= packet.UDP_HEADER_SIZE) {
        return 0;
    }
    return udp_len - packet.UDP_HEADER_SIZE;
}
