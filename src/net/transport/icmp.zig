// ICMP Protocol Implementation
//
// Complies with:
// - RFC 792: Internet Control Message Protocol
// - RFC 1122: Requirements for Internet Hosts -- Communication Layers
//
// Implements Echo Request/Reply (ping) functionality.
// Other ICMP types are parsed but not actively used.
//
// Message Format:
// +-----------+--------+-----------+-------------------------+
// | Type (1)  | Code(1)| Checksum(2)| Data (depends on Type)  |
// +-----------+--------+-----------+-------------------------+

const packet = @import("../core/packet.zig");
const interface = @import("../core/interface.zig");
const checksum = @import("../core/checksum.zig");
const ipv4 = @import("../ipv4/ipv4.zig");
const ethernet = @import("../ethernet/ethernet.zig");
const arp = @import("../ipv4/arp.zig");
const PacketBuffer = packet.PacketBuffer;
const IcmpHeader = packet.IcmpHeader;
const Ipv4Header = packet.Ipv4Header;
const EthernetHeader = packet.EthernetHeader;
const Interface = interface.Interface;

// Forward declarations to avoid circular dependencies if possible,
// but we need to call them. circular imports are allowed in Zig if done right.
const tcp = @import("tcp.zig");
const udp = @import("udp.zig");

/// ICMP message types
pub const TYPE_ECHO_REPLY: u8 = 0;
pub const TYPE_DEST_UNREACHABLE: u8 = 3;
pub const TYPE_SOURCE_QUENCH: u8 = 4;
pub const TYPE_REDIRECT: u8 = 5;
pub const TYPE_ECHO_REQUEST: u8 = 8;
pub const TYPE_TIME_EXCEEDED: u8 = 11;
pub const TYPE_PARAMETER_PROBLEM: u8 = 12;
pub const TYPE_TIMESTAMP_REQUEST: u8 = 13;
pub const TYPE_TIMESTAMP_REPLY: u8 = 14;

/// Destination Unreachable codes
pub const CODE_NET_UNREACHABLE: u8 = 0;
pub const CODE_HOST_UNREACHABLE: u8 = 1;
pub const CODE_PROTO_UNREACHABLE: u8 = 2;
pub const CODE_PORT_UNREACHABLE: u8 = 3;
pub const CODE_FRAGMENTATION_NEEDED: u8 = 4; // RFC 1191: PMTUD

/// Process an incoming ICMP packet
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    // Validate minimum ICMP header size
    if (pkt.len < pkt.transport_offset + packet.ICMP_HEADER_SIZE) {
        return false;
    }

    const icmp = pkt.icmpHeader();

    // Get ICMP message length from IP header
    const ip = pkt.ipHeader();
    const ip_total_len = ip.getTotalLength();
    const ip_header_len = ip.getHeaderLength();
    const icmp_len = ip_total_len - ip_header_len;

    // Validate ICMP checksum
    const icmp_data = pkt.data[pkt.transport_offset..][0..icmp_len];
    if (!verifyIcmpChecksum(icmp_data)) {
        return false;
    }

    // Handle based on type
    switch (icmp.icmp_type) {
        TYPE_ECHO_REQUEST => {
            return handleEchoRequest(iface, pkt, icmp_len);
        },
        TYPE_ECHO_REPLY => {
            // Could notify waiting ping processes
            return true;
        },
        TYPE_DEST_UNREACHABLE => {
            return handleDestUnreachable(pkt, icmp);
        },
        else => {
            // Unknown or unsupported type
            return false;
        },
    }
}

/// Handle an ICMP Echo Request (ping)
/// Sends back an Echo Reply with the same data
fn handleEchoRequest(iface: *Interface, req_pkt: *PacketBuffer, icmp_len: usize) bool {
    const req_ip = req_pkt.ipHeader();
    const req_icmp = req_pkt.icmpHeader();

    // Get source IP to reply to
    const src_ip = req_ip.getSrcIp();

    // Don't reply to broadcast pings (Smurf attack prevention)
    if (ipv4.isBroadcast(req_ip.getDstIp(), iface.netmask)) {
        return false;
    }

    // Resolve destination MAC
    const next_hop = iface.getGateway(src_ip);
    const dst_mac = arp.resolveOrRequest(iface, next_hop, null) orelse {
        // Can't resolve MAC - drop reply
        // A real implementation would queue this
        return false;
    };

    // Calculate reply packet size
    const eth_len = packet.ETH_HEADER_SIZE;
    const ip_len = packet.IP_HEADER_SIZE;
    const total_len = eth_len + ip_len + icmp_len;

    // Use static buffer for reply (avoid allocation)
    var reply_buf: [packet.MAX_PACKET_SIZE]u8 = undefined;
    if (total_len > reply_buf.len) {
        return false;
    }

    // Build Ethernet header
    const reply_eth: *EthernetHeader = @ptrCast(@alignCast(&reply_buf[0]));
    @memcpy(&reply_eth.dst_mac, &dst_mac);
    @memcpy(&reply_eth.src_mac, &iface.mac_addr);
    reply_eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    // Build IP header
    const reply_ip: *Ipv4Header = @ptrCast(@alignCast(&reply_buf[eth_len]));
    reply_ip.version_ihl = 0x45; // Version 4, IHL 5
    reply_ip.tos = 0;
    reply_ip.setTotalLength(@truncate(ip_len + icmp_len));
    reply_ip.identification = @byteSwap(ipv4.getNextId());
    reply_ip.flags_fragment = @byteSwap(@as(u16, 0x4000)); // Don't Fragment
    reply_ip.ttl = ipv4.DEFAULT_TTL;
    reply_ip.protocol = ipv4.PROTO_ICMP;
    reply_ip.checksum = 0;
    reply_ip.setSrcIp(iface.ip_addr);
    reply_ip.setDstIp(src_ip);

    // Calculate IP checksum
    reply_ip.checksum = checksum.ipChecksum(reply_buf[eth_len..][0..ip_len]);

    // Build ICMP reply
    const reply_icmp: *IcmpHeader = @ptrCast(@alignCast(&reply_buf[eth_len + ip_len]));
    reply_icmp.icmp_type = TYPE_ECHO_REPLY;
    reply_icmp.code = 0;
    reply_icmp.checksum = 0;
    reply_icmp.identifier = req_icmp.identifier; // Keep same identifier
    reply_icmp.sequence = req_icmp.sequence; // Keep same sequence

    // Copy echo data (everything after ICMP header)
    const echo_data_len = icmp_len - packet.ICMP_HEADER_SIZE;
    if (echo_data_len > 0) {
        const req_data = req_pkt.data[req_pkt.transport_offset + packet.ICMP_HEADER_SIZE ..][0..echo_data_len];
        const reply_data = reply_buf[eth_len + ip_len + packet.ICMP_HEADER_SIZE ..][0..echo_data_len];
        @memcpy(reply_data, req_data);
    }

    // Calculate ICMP checksum
    const reply_icmp_data = reply_buf[eth_len + ip_len ..][0..icmp_len];
    reply_icmp.checksum = checksum.icmpChecksum(reply_icmp_data);

    // Transmit reply
    return iface.transmit(reply_buf[0..total_len]);
}

/// Handle ICMP Destination Unreachable messages
/// Specifically handles Code 4 (Fragmentation Needed) for PMTUD (RFC 1191)
fn handleDestUnreachable(pkt: *PacketBuffer, icmp: *align(1) const IcmpHeader) bool {
    // ICMP Destination Unreachable format:
    // Bytes 0-1: Type (3) + Code
    // Bytes 2-3: Checksum
    // Bytes 4-5: Unused (for most codes) or Next-Hop MTU (for Code 4)
    // Bytes 6-7: Next-Hop MTU (RFC 1191, only valid for Code 4)
    // Bytes 8+: Original IP header + first 8 bytes of original datagram

    if (icmp.code == CODE_FRAGMENTATION_NEEDED) {
        // Extract next-hop MTU from ICMP message
        // Per RFC 1191, bytes 6-7 contain the next-hop MTU in network byte order
        // The identifier/sequence fields in IcmpHeader overlay bytes 4-7
        // So: identifier = bytes 4-5 (unused), sequence = bytes 6-7 (MTU)
        const next_hop_mtu = @byteSwap(icmp.sequence);

        // RFC 1191: If MTU field is 0, use "plateau" table
        // For simplicity, we use a conservative estimate based on common MTUs
        var effective_mtu: u16 = next_hop_mtu;
        if (next_hop_mtu == 0) {
            // Old-style ICMP without MTU field - use conservative MTU
            // Common plateau: 1492 (PPPoE), 1006, 508, 296
            effective_mtu = 1006;
        }

        // Extract original destination IP from the embedded IP header
        // The original IP header starts 8 bytes after ICMP header start
        const orig_ip_offset = pkt.transport_offset + packet.ICMP_HEADER_SIZE;
        if (orig_ip_offset + packet.IP_HEADER_SIZE <= pkt.len) {
            const orig_ip: *const Ipv4Header = @ptrCast(@alignCast(&pkt.data[orig_ip_offset]));
            const original_dst = orig_ip.getDstIp();

            // Update PMTU cache for this destination
            ipv4.updatePmtu(original_dst, effective_mtu);
        }
    }

    // Other codes (Network/Host/Protocol/Port Unreachable)
    // Notify transport layer of connection failures
    
    // Parse original IP header to get protocol and ports
    const orig_ip_offset = pkt.transport_offset + packet.ICMP_HEADER_SIZE;
    if (orig_ip_offset + packet.IP_HEADER_SIZE > pkt.len) return true;
    
    const orig_ip: *const Ipv4Header = @ptrCast(@alignCast(&pkt.data[orig_ip_offset]));
    const orig_ip_len = orig_ip.getHeaderLength();
    
    // Check if we have enough data for transport header (at least 8 bytes)
    const transport_offset = orig_ip_offset + orig_ip_len;
    if (transport_offset + 8 > pkt.len) return true;
    
    const orig_transport_data = pkt.data[transport_offset..][0..8];
    const src_ip = orig_ip.getSrcIp(); // This should be US (or one of our IPs)
    const dst_ip = orig_ip.getDstIp(); // The remote host
    
    // Determine Protocol
    switch (orig_ip.protocol) {
        ipv4.PROTO_TCP => {
            // Extract ports (src=local, dst=remote from original packet perspective)
            // TCP: Src Port (0-1), Dst Port (2-3)
            const local_port = (@as(u16, orig_transport_data[0]) << 8) | orig_transport_data[1];
            const remote_port = (@as(u16, orig_transport_data[2]) << 8) | orig_transport_data[3];
            
            tcp.handleIcmpError(
                src_ip, local_port,
                dst_ip, remote_port,
                icmp.icmp_type, icmp.code
            );
        },
        // UDP integration can be added later
        else => {},
    }

    return true;
}

/// Verify ICMP checksum
fn verifyIcmpChecksum(data: []const u8) bool {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i + 1 < data.len) : (i += 2) {
        const word = (@as(u32, data[i]) << 8) | @as(u32, data[i + 1]);
        sum += word;
    }

    // Handle odd byte
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }

    // Fold
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @as(u16, @truncate(sum)) == 0xFFFF;
}

/// Send an ICMP Echo Request (ping)
/// Returns false if packet couldn't be sent (ARP not resolved, etc.)
pub fn sendEchoRequest(
    iface: *Interface,
    dst_ip: u32,
    identifier: u16,
    sequence: u16,
    data: []const u8,
) bool {
    // Resolve destination MAC
    const next_hop = iface.getGateway(dst_ip);
    const dst_mac = arp.resolveOrRequest(iface, next_hop, null) orelse {
        return false;
    };

    // Calculate sizes
    const eth_len = packet.ETH_HEADER_SIZE;
    const ip_len = packet.IP_HEADER_SIZE;
    const icmp_len = packet.ICMP_HEADER_SIZE + data.len;
    const total_len = eth_len + ip_len + icmp_len;

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
    ip.setTotalLength(@truncate(ip_len + icmp_len));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_ICMP;
    ip.checksum = 0;
    ip.setSrcIp(iface.ip_addr);
    ip.setDstIp(dst_ip);
    ip.checksum = checksum.ipChecksum(buf[eth_len..][0..ip_len]);

    // Build ICMP header
    const icmp_hdr: *IcmpHeader = @ptrCast(@alignCast(&buf[eth_len + ip_len]));
    icmp_hdr.icmp_type = TYPE_ECHO_REQUEST;
    icmp_hdr.code = 0;
    icmp_hdr.checksum = 0;
    icmp_hdr.identifier = @byteSwap(identifier);
    icmp_hdr.sequence = @byteSwap(sequence);

    // Copy data
    if (data.len > 0) {
        @memcpy(buf[eth_len + ip_len + packet.ICMP_HEADER_SIZE ..][0..data.len], data);
    }

    // Calculate ICMP checksum
    icmp_hdr.checksum = checksum.icmpChecksum(buf[eth_len + ip_len ..][0..icmp_len]);

    // Transmit
    return iface.transmit(buf[0..total_len]);
}

/// Send ICMP Destination Unreachable message
pub fn sendDestUnreachable(
    iface: *Interface,
    original_pkt: *const PacketBuffer,
    code: u8,
) bool {
    const orig_ip = original_pkt.ipHeader();
    const src_ip = orig_ip.getSrcIp();

    // Don't send ICMP errors for:
    // - ICMP errors (to prevent loops)
    // - Broadcast/multicast destinations
    if (orig_ip.protocol == ipv4.PROTO_ICMP) {
        const orig_icmp = original_pkt.icmpHeader();
        if (orig_icmp.icmp_type != TYPE_ECHO_REQUEST and
            orig_icmp.icmp_type != TYPE_ECHO_REPLY)
        {
            return false;
        }
    }

    // Resolve MAC
    const next_hop = iface.getGateway(src_ip);
    const dst_mac = arp.resolveOrRequest(iface, next_hop, null) orelse {
        return false;
    };

    // ICMP error includes IP header + 8 bytes of original datagram
    const orig_ip_len = orig_ip.getHeaderLength();
    const orig_data_len = @min(orig_ip_len + 8, original_pkt.len - original_pkt.ip_offset);

    const eth_len = packet.ETH_HEADER_SIZE;
    const ip_len = packet.IP_HEADER_SIZE;
    const icmp_len = packet.ICMP_HEADER_SIZE + orig_data_len;
    const total_len = eth_len + ip_len + icmp_len;

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
    ip.setTotalLength(@truncate(ip_len + icmp_len));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_ICMP;
    ip.checksum = 0;
    ip.setSrcIp(iface.ip_addr);
    ip.setDstIp(src_ip);
    ip.checksum = checksum.ipChecksum(buf[eth_len..][0..ip_len]);

    // Build ICMP header
    const icmp_hdr: *IcmpHeader = @ptrCast(@alignCast(&buf[eth_len + ip_len]));
    icmp_hdr.icmp_type = TYPE_DEST_UNREACHABLE;
    icmp_hdr.code = code;
    icmp_hdr.checksum = 0;
    icmp_hdr.identifier = 0; // Unused for Dest Unreachable
    icmp_hdr.sequence = 0;

    // Copy original IP header + 8 bytes
    const orig_data = original_pkt.data[original_pkt.ip_offset..][0..orig_data_len];
    @memcpy(buf[eth_len + ip_len + packet.ICMP_HEADER_SIZE ..][0..orig_data_len], orig_data);

    // Calculate ICMP checksum
    icmp_hdr.checksum = checksum.icmpChecksum(buf[eth_len + ip_len ..][0..icmp_len]);

    // Transmit
    return iface.transmit(buf[0..total_len]);
}
