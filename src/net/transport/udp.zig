// UDP Protocol Implementation
//
// Complies with:
// - RFC 768: User Datagram Protocol
//
// Provides connectionless datagram service for applications.
//
// Header Format:
// +-----------+-----------+
// | Source Port | Dest Port |
// +-----------+-----------+
// | Length    | Checksum  |
// +-----------+-----------+
// | Data ...              |
// +-----------------------+

const packet = @import("../core/packet.zig");
const interface = @import("../core/interface.zig");
const checksum = @import("../core/checksum.zig");
const ipv4 = @import("../ipv4/root.zig").ipv4;
const ethernet = @import("../ethernet/ethernet.zig");
const arp = @import("../ipv4/root.zig").arp;
// Reuse TCP's buffer pool to avoid stack overflow
const tcp_state = @import("tcp/state.zig");
// ICMP module for PMTU validation tracking
const icmp = @import("icmp.zig");

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
    // Validate minimum UDP header size
    if (pkt.len < pkt.transport_offset + packet.UDP_HEADER_SIZE) {
        return false;
    }

    const udp_hdr = packet.getUdpHeader(pkt.data, pkt.transport_offset) orelse return false;
    const ip = packet.getIpv4Header(pkt.data, pkt.ip_offset) orelse return false;

    // Get UDP length
    const udp_len = udp_hdr.getLength();
    if (udp_len < packet.UDP_HEADER_SIZE) {
        return false;
    }

    // SECURITY: Validate IP header length does not exceed total length before
    // subtraction to prevent integer underflow. A malformed packet with
    // IHL > total_length would wrap to a large value, bypassing bounds checks.
    // Defense-in-depth per CLAUDE.md integer safety guidelines.
    const ip_total_len = ip.getTotalLength();
    const ip_header_len = ip.getHeaderLength();
    if (ip_total_len < ip_header_len) {
        return false; // Malformed: header claims more bytes than total length
    }
    const ip_payload_len = ip_total_len - ip_header_len;
    if (udp_len > ip_payload_len) {
        return false;
    }

    // Verify UDP checksum
    // RFC 768: Checksum 0 means "no checksum computed" and is valid for IPv4.
    // SECURITY: For security-sensitive protocols (DNS port 53), we require
    // non-zero checksums to prevent cache poisoning attacks where an attacker
    // injects spoofed responses without computing valid checksums.
    const dst_port = udp_hdr.getDstPort();
    const src_port = udp_hdr.getSrcPort();

    // Security-sensitive ports that require UDP checksum validation
    // These protocols are vulnerable to spoofed packet injection if checksums aren't validated:
    // - DNS (53): Cache poisoning attacks
    // - NTP (123): Time-based authentication bypass, amplification attacks
    // - SNMP (161/162): Unauthorized device control, information disclosure
    const DNS_PORT: u16 = 53;
    const NTP_PORT: u16 = 123;
    const SNMP_PORT: u16 = 161;
    const SNMP_TRAP_PORT: u16 = 162;
    const is_security_sensitive = (dst_port == DNS_PORT or src_port == DNS_PORT or
        dst_port == NTP_PORT or src_port == NTP_PORT or
        dst_port == SNMP_PORT or src_port == SNMP_PORT or
        dst_port == SNMP_TRAP_PORT or src_port == SNMP_TRAP_PORT);

    if (udp_hdr.checksum == 0) {
        if (is_security_sensitive) {
            // Reject zero-checksum packets for security-sensitive protocols
            return false;
        }
        // Allow zero checksum for other UDP traffic per RFC 768
    } else {
        // Use safe slice access from packet buffer
        const udp_data = pkt.data[pkt.transport_offset..][0..udp_len];
        // Use stored IPs from packet metadata to support reassembled packets
        const calc_checksum = checksum.udpChecksum(pkt.src_ip, pkt.dst_ip, udp_data);
        if (udp_hdr.checksum != calc_checksum) {
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
    const delivered = socket.deliverUdpPacket(pkt);
    if (!delivered and !pkt.is_broadcast and !pkt.is_multicast) {
        _ = icmp.sendDestUnreachable(iface, pkt, icmp.CODE_PORT_UNREACHABLE);
        return true;
    }
    return delivered;
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
    return sendDatagramWithTos(iface, dst_ip, src_port, dst_port, data, 0);
}

/// Send a UDP datagram with explicit ToS value
/// tos: Type of Service / DSCP value (0 = normal service)
pub fn sendDatagramWithTos(
    iface: *Interface,
    dst_ip: u32,
    src_port: u16,
    dst_port: u16,
    data: []const u8,
    tos: u8,
) bool {
    if (data.len > MAX_UDP_PAYLOAD) {
        return false;
    }

    // Resolve destination MAC
    const next_hop = iface.getGateway(dst_ip);
    const resolved_mac = arp.resolve(next_hop);
    var dst_mac = resolved_mac orelse [_]u8{ 0, 0, 0, 0, 0, 0 };
    const have_mac = resolved_mac != null;

    // Calculate sizes
    const eth_len = packet.ETH_HEADER_SIZE;
    const ip_len = packet.IP_HEADER_SIZE;
    const udp_len = packet.UDP_HEADER_SIZE + data.len;
    const total_len = eth_len + ip_len + udp_len;

    // Use TCP's TX buffer pool to avoid large stack allocation (stack overflow risk)
    const buf = tcp_state.allocTxBuffer() orelse return false;
    defer tcp_state.freeTxBuffer(buf);

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
    ip.tos = tos;
    // SAFETY: Truncation is safe because data.len <= MAX_UDP_PAYLOAD (1472) is validated
    // at function entry. Max ip_len + udp_len = 20 + 8 + 1472 = 1500, fits in u16.
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
    // SAFETY: Truncation is safe because data.len <= MAX_UDP_PAYLOAD (1472) is validated
    // at function entry. Max udp_len = 8 + 1472 = 1480, fits in u16.
    udp_hdr.setLength(@truncate(udp_len));
    udp_hdr.checksum = 0;

    // Copy payload
    if (data.len > 0) {
        @memcpy(buf[eth_len + ip_len + packet.UDP_HEADER_SIZE ..][0..data.len], data);
    }

    // Calculate UDP checksum (with pseudo-header)
    const udp_data = buf[eth_len + ip_len ..][0..udp_len];
    udp_hdr.checksum = checksum.udpChecksum(ip.src_ip, ip.dst_ip, udp_data);

    // Transmit or Queue
    if (have_mac) {
        // Record transmission for ICMP PMTU validation
        icmp.recordUdpTransmit(dst_ip);
        return iface.transmit(buf[0..total_len]);
    } else {
        // Create wrapper packet buffer for queueing
        var pkt = PacketBuffer.init(buf[0..total_len], total_len);
        pkt.eth_offset = 0;
        pkt.ip_offset = eth_len;
        pkt.transport_offset = eth_len + ip_len;
        
        // Try resolve again with packet to queue
        if (arp.resolveOrRequest(iface, next_hop, &pkt)) |mac| {
            // Resolved immediately (race condition or just appeared)
            @memcpy(&eth.dst_mac, &mac);
            // Record transmission for ICMP PMTU validation
            icmp.recordUdpTransmit(dst_ip);
            return iface.transmit(buf[0..total_len]);
        }

        // Queued successfully (ARP copies packet) - record for PMTU validation
        // Packet will be sent once ARP resolves
        icmp.recordUdpTransmit(dst_ip);
        return true;
    }
}

/// Calculate payload length from UDP header
pub fn getPayloadLength(pkt: *const PacketBuffer) usize {
    const udp_hdr = packet.getUdpHeader(pkt.data, pkt.transport_offset) orelse return 0;
    const udp_len = udp_hdr.getLength();
    if (udp_len <= packet.UDP_HEADER_SIZE) {
        return 0;
    }
    return udp_len - packet.UDP_HEADER_SIZE;
}
