// ICMP Protocol Implementation
//
// RFC 792: Internet Control Message Protocol
//
// Implements Echo Request/Reply (ping) functionality.
// Other ICMP types are parsed but not actively used.

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
            // Could notify transport layer
            return true;
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
    const dst_mac = arp.resolveOrRequest(iface, next_hop) orelse {
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
    const dst_mac = arp.resolveOrRequest(iface, next_hop) orelse {
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
    const dst_mac = arp.resolveOrRequest(iface, next_hop) orelse {
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
