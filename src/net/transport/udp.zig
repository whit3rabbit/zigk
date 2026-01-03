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

const std = @import("std");
const packet = @import("../core/packet.zig");
const interface = @import("../core/interface.zig");
const checksum = @import("../core/checksum.zig");
const ipv4 = @import("../ipv4/root.zig").ipv4;
const ipv6 = @import("../ipv6/root.zig");
const ethernet = @import("../ethernet/ethernet.zig");
const arp = @import("../ipv4/root.zig").arp;
const ndp = @import("../ipv6/ndp/root.zig");
// Reuse TCP's buffer pool to avoid stack overflow
const tcp_state = @import("tcp/state.zig");
// ICMP module for PMTU validation tracking
const icmp = @import("icmp.zig");
// Address abstraction for dual-stack
const addr_mod = @import("../core/addr.zig");
const IpAddr = addr_mod.IpAddr;

const PacketBuffer = packet.PacketBuffer;
const UdpHeader = packet.UdpHeader;
const Ipv4Header = packet.Ipv4Header;
const Ipv6Header = packet.Ipv6Header;
const EthernetHeader = packet.EthernetHeader;
const Interface = interface.Interface;

/// Maximum UDP payload size for IPv4 (MTU - IP header - UDP header)
pub const MAX_UDP_PAYLOAD: usize = 1500 - packet.IP_HEADER_SIZE - packet.UDP_HEADER_SIZE;

/// Maximum UDP payload size for IPv6 (MTU - IPv6 header - UDP header)
/// IPv6 header is 40 bytes vs IPv4's 20 bytes
pub const MAX_UDP6_PAYLOAD: usize = 1500 - packet.IPV6_HEADER_SIZE - packet.UDP_HEADER_SIZE;

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

    // SECURITY: Validate claimed UDP length against actual packet buffer size.
    // The IP header's total_length field could claim more bytes than were actually
    // received (truncated packet or malicious crafting). Without this check,
    // the slice operation at line 98 could cause out-of-bounds access.
    // Defense-in-depth per CLAUDE.md integer safety guidelines.
    if (pkt.transport_offset + udp_len > pkt.len) {
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

/// Process an incoming IPv6 UDP packet
/// Returns true if packet was handled
pub fn processPacket6(iface: *Interface, pkt: *PacketBuffer) bool {
    // Validate minimum UDP header size
    if (pkt.len < pkt.transport_offset + packet.UDP_HEADER_SIZE) {
        return false;
    }

    const udp_hdr = packet.getUdpHeader(pkt.data, pkt.transport_offset) orelse return false;
    const ip6 = packet.getIpv6Header(pkt.data, pkt.ip_offset) orelse return false;

    // Get UDP length
    const udp_len = udp_hdr.getLength();
    if (udp_len < packet.UDP_HEADER_SIZE) {
        return false;
    }

    // SECURITY: Validate IPv6 payload length vs UDP length
    const ipv6_payload_len = ip6.getPayloadLength();
    if (udp_len > ipv6_payload_len) {
        return false;
    }

    // SECURITY: Validate claimed UDP length against actual packet buffer size.
    if (pkt.transport_offset + udp_len > pkt.len) {
        return false;
    }

    // Verify UDP checksum - MANDATORY for IPv6 (RFC 8200)
    // Unlike IPv4, IPv6 UDP checksum cannot be zero
    const dst_port = udp_hdr.getDstPort();
    const src_port = udp_hdr.getSrcPort();

    if (udp_hdr.checksum == 0) {
        // RFC 8200: Zero checksum is invalid for IPv6 UDP
        return false;
    }

    // Use safe slice access from packet buffer
    const udp_data = pkt.data[pkt.transport_offset..][0..udp_len];
    // Use IPv6 pseudo-header for checksum
    const calc_checksum = checksum.udpChecksum6(ip6.src_addr, ip6.dst_addr, udp_data);
    if (udp_hdr.checksum != calc_checksum) {
        // Checksum mismatch
        return false;
    }

    // Record source port and addresses for socket delivery
    pkt.src_port = src_port;
    // Copy IPv6 addresses to packet buffer for socket layer
    pkt.src_ipv6 = ip6.src_addr;
    pkt.dst_ipv6 = ip6.dst_addr;

    // Set payload offset
    pkt.payload_offset = pkt.transport_offset + packet.UDP_HEADER_SIZE;

    // Deliver to socket layer
    const socket = @import("socket.zig");
    const delivered = socket.deliverUdpPacket6(pkt);
    if (!delivered and !pkt.is_broadcast and !pkt.is_multicast) {
        // TODO: Send ICMPv6 Destination Unreachable (Port Unreachable)
        // icmpv6.sendDestUnreachable(iface, pkt, icmpv6.CODE_PORT_UNREACHABLE);
        _ = iface;
        _ = dst_port;
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

/// Send an IPv6 UDP datagram
/// Returns false if packet couldn't be sent
pub fn sendDatagram6(
    iface: *Interface,
    dst_addr: [16]u8,
    src_port: u16,
    dst_port: u16,
    data: []const u8,
) bool {
    return sendDatagram6WithTrafficClass(iface, dst_addr, src_port, dst_port, data, 0);
}

/// Send an IPv6 UDP datagram with explicit Traffic Class value
/// traffic_class: IPv6 Traffic Class (equivalent to IPv4 ToS/DSCP)
pub fn sendDatagram6WithTrafficClass(
    iface: *Interface,
    dst_addr: [16]u8,
    src_port: u16,
    dst_port: u16,
    data: []const u8,
    traffic_class: u8,
) bool {
    if (data.len > MAX_UDP6_PAYLOAD) {
        return false;
    }

    // Select source address for this destination
    const src_addr = ipv6.ipv6.transmit.selectSourceAddress(iface, dst_addr) orelse {
        return false; // No suitable source address
    };

    // Resolve destination MAC via NDP
    var dst_mac: [6]u8 = undefined;
    var have_mac = false;

    if (ipv6.ipv6.types.isMulticast(dst_addr)) {
        // IPv6 multicast to Ethernet multicast (RFC 2464)
        // 33:33:xx:xx:xx:xx (last 32 bits of IPv6 address)
        dst_mac[0] = 0x33;
        dst_mac[1] = 0x33;
        dst_mac[2] = dst_addr[12];
        dst_mac[3] = dst_addr[13];
        dst_mac[4] = dst_addr[14];
        dst_mac[5] = dst_addr[15];
        have_mac = true;
    } else {
        // Unicast: Resolve via NDP
        const next_hop = iface.getIpv6Gateway(dst_addr) orelse dst_addr;
        if (ndp.cache.lookup(next_hop)) |mac| {
            dst_mac = mac;
            have_mac = true;
        } else {
            dst_mac = [_]u8{ 0, 0, 0, 0, 0, 0 };
        }
    }

    // Calculate sizes
    const eth_len = packet.ETH_HEADER_SIZE;
    const ip6_len = packet.IPV6_HEADER_SIZE;
    const udp_len = packet.UDP_HEADER_SIZE + data.len;
    const total_len = eth_len + ip6_len + udp_len;

    // Use TCP's TX buffer pool to avoid large stack allocation
    const buf = tcp_state.allocTxBuffer() orelse return false;
    defer tcp_state.freeTxBuffer(buf);

    if (total_len > buf.len) {
        return false;
    }

    // Build Ethernet header
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[eth_len]));
    ip6.setVersion(6);
    ip6.setTrafficClass(traffic_class);
    ip6.setFlowLabel(0);
    // SAFETY: Truncation is safe because data.len <= MAX_UDP6_PAYLOAD is validated
    // at function entry. Max udp_len = 8 + MAX_UDP6_PAYLOAD fits in u16.
    ip6.setPayloadLength(@truncate(udp_len));
    ip6.next_header = ipv6.ipv6.types.PROTO_UDP;
    ip6.hop_limit = ipv6.ipv6.types.DEFAULT_HOP_LIMIT;
    ip6.src_addr = src_addr;
    ip6.dst_addr = dst_addr;

    // Build UDP header
    const udp_hdr: *UdpHeader = @ptrCast(@alignCast(&buf[eth_len + ip6_len]));
    udp_hdr.setSrcPort(src_port);
    udp_hdr.setDstPort(dst_port);
    // SAFETY: Same as above, udp_len fits in u16
    udp_hdr.setLength(@truncate(udp_len));
    udp_hdr.checksum = 0;

    // Copy payload
    if (data.len > 0) {
        @memcpy(buf[eth_len + ip6_len + packet.UDP_HEADER_SIZE ..][0..data.len], data);
    }

    // Calculate UDP checksum with IPv6 pseudo-header (MANDATORY for IPv6)
    const udp_data = buf[eth_len + ip6_len ..][0..udp_len];
    udp_hdr.checksum = checksum.udpChecksum6(src_addr, dst_addr, udp_data);

    // IPv6 UDP checksum of 0 is invalid, use 0xFFFF instead (RFC 8200)
    if (udp_hdr.checksum == 0) {
        udp_hdr.checksum = 0xFFFF;
    }

    // Transmit or Queue
    if (have_mac) {
        return iface.transmit(buf[0..total_len]);
    } else {
        // Queue packet pending NDP resolution
        // Create wrapper packet buffer for queueing
        var pkt = PacketBuffer.init(buf[0..total_len], total_len);
        pkt.eth_offset = 0;
        pkt.ip_offset = eth_len;
        pkt.transport_offset = eth_len + ip6_len;
        pkt.ethertype = ethernet.ETHERTYPE_IPV6;

        // Try to start NDP resolution
        const next_hop = iface.getIpv6Gateway(dst_addr) orelse dst_addr;

        // Create incomplete entry and queue packet
        const held = ndp.cache.lock.acquire();
        defer held.release();

        const entry = ndp.cache.createIncompleteEntry(next_hop) catch {
            return false;
        };

        if (!ndp.cache.queuePacket(entry, buf[0..total_len])) {
            return false;
        }

        // Send neighbor solicitation (outside lock ideally, but for simplicity)
        // The actual NS transmission would need to be done via ndp.transmit
        // For now, just queue and return success - NS will be sent by timer or event
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
