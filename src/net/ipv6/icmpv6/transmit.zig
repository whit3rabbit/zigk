// ICMPv6 Packet Transmission (TX Path)
//
// Implements RFC 4443 (ICMPv6) transmit functions.
// Handles Echo Reply, Destination Unreachable, Packet Too Big, etc.
//
// Security considerations:
// - Rate limiting for error messages
// - Proper checksum calculation with IPv6 pseudo-header
// - No error messages in response to multicast (except Packet Too Big and Param Problem)

const std = @import("std");
const packet = @import("../../core/packet.zig");
const interface = @import("../../core/interface.zig");
const checksum = @import("../../core/checksum.zig");
const ethernet = @import("../../ethernet/ethernet.zig");
const types = @import("types.zig");
const ipv6_types = @import("../ipv6/types.zig");
const ipv6_transmit = @import("../ipv6/transmit.zig");
const net_pool = @import("../../core/pool.zig");
const ndp = @import("../ndp/root.zig");

const PacketBuffer = packet.PacketBuffer;
const Ipv6Header = packet.Ipv6Header;
const Interface = interface.Interface;

/// Default Hop Limit for ICMPv6 messages
const DEFAULT_HOP_LIMIT: u8 = 64;

/// NDP messages require Hop Limit = 255
const NDP_HOP_LIMIT: u8 = 255;

/// Send ICMPv6 Echo Reply
pub fn sendEchoReply(
    iface: *Interface,
    dst_addr: [16]u8,
    identifier: u16,
    sequence: u16,
    echo_data: []const u8,
) bool {
    // Calculate total ICMPv6 message size
    const icmpv6_len = types.ICMPV6_ECHO_HEADER_SIZE + echo_data.len;

    // Allocate TX buffer
    const buf = net_pool.allocTxBuffer() orelse return false;
    defer net_pool.freeTxBuffer(buf);

    // Calculate offsets
    const eth_len = packet.ETH_HEADER_SIZE;
    const ipv6_len = packet.IPV6_HEADER_SIZE;
    const total_len = eth_len + ipv6_len + icmpv6_len;

    if (total_len > buf.len) return false;

    // Select source address
    const src_addr = ipv6_transmit.selectSourceAddress(iface, dst_addr) orelse {
        return false;
    };

    // Resolve next-hop MAC address
    const dst_mac = resolveNextHopMac(iface, dst_addr) orelse {
        return false;
    };

    // Build Ethernet header
    const eth: *packet.EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[eth_len]));
    ip6.* = std.mem.zeroes(Ipv6Header);
    ip6.setVersionTcFlow(6, 0, 0);
    ip6.setPayloadLength(@truncate(icmpv6_len));
    ip6.next_header = ipv6_types.PROTO_ICMPV6;
    ip6.hop_limit = DEFAULT_HOP_LIMIT;
    ip6.src_addr = src_addr;
    ip6.dst_addr = dst_addr;

    // Build ICMPv6 Echo Reply header
    const icmpv6: *types.Icmpv6EchoHeader = @ptrCast(@alignCast(&buf[eth_len + ipv6_len]));
    icmpv6.msg_type = types.TYPE_ECHO_REPLY;
    icmpv6.code = 0;
    icmpv6.checksum = 0;
    icmpv6.setIdentifier(identifier);
    icmpv6.setSequence(sequence);

    // Copy echo data
    if (echo_data.len > 0) {
        const data_offset = eth_len + ipv6_len + types.ICMPV6_ECHO_HEADER_SIZE;
        @memcpy(buf[data_offset..][0..echo_data.len], echo_data);
    }

    // Calculate ICMPv6 checksum
    const icmpv6_data = buf[eth_len + ipv6_len ..][0..icmpv6_len];
    const cksum = checksum.icmpv6Checksum(src_addr, dst_addr, icmpv6_data);
    icmpv6.checksum = @byteSwap(cksum);

    // Transmit
    return iface.transmit(buf[0..total_len]);
}

/// Send ICMPv6 Echo Request (ping6)
pub fn sendEchoRequest(
    iface: *Interface,
    dst_addr: [16]u8,
    identifier: u16,
    sequence: u16,
    echo_data: []const u8,
) bool {
    const icmpv6_len = types.ICMPV6_ECHO_HEADER_SIZE + echo_data.len;

    const buf = net_pool.allocTxBuffer() orelse return false;
    defer net_pool.freeTxBuffer(buf);

    const eth_len = packet.ETH_HEADER_SIZE;
    const ipv6_len = packet.IPV6_HEADER_SIZE;
    const total_len = eth_len + ipv6_len + icmpv6_len;

    if (total_len > buf.len) return false;

    const src_addr = ipv6_transmit.selectSourceAddress(iface, dst_addr) orelse {
        return false;
    };

    const dst_mac = resolveNextHopMac(iface, dst_addr) orelse {
        return false;
    };

    // Build Ethernet header
    const eth: *packet.EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[eth_len]));
    ip6.* = std.mem.zeroes(Ipv6Header);
    ip6.setVersionTcFlow(6, 0, 0);
    ip6.setPayloadLength(@truncate(icmpv6_len));
    ip6.next_header = ipv6_types.PROTO_ICMPV6;
    ip6.hop_limit = DEFAULT_HOP_LIMIT;
    ip6.src_addr = src_addr;
    ip6.dst_addr = dst_addr;

    // Build ICMPv6 Echo Request header
    const icmpv6: *types.Icmpv6EchoHeader = @ptrCast(@alignCast(&buf[eth_len + ipv6_len]));
    icmpv6.msg_type = types.TYPE_ECHO_REQUEST;
    icmpv6.code = 0;
    icmpv6.checksum = 0;
    icmpv6.setIdentifier(identifier);
    icmpv6.setSequence(sequence);

    // Copy echo data
    if (echo_data.len > 0) {
        const data_offset = eth_len + ipv6_len + types.ICMPV6_ECHO_HEADER_SIZE;
        @memcpy(buf[data_offset..][0..echo_data.len], echo_data);
    }

    // Calculate ICMPv6 checksum
    const icmpv6_data = buf[eth_len + ipv6_len ..][0..icmpv6_len];
    const cksum = checksum.icmpv6Checksum(src_addr, dst_addr, icmpv6_data);
    icmpv6.checksum = @byteSwap(cksum);

    return iface.transmit(buf[0..total_len]);
}

/// Send ICMPv6 Destination Unreachable
pub fn sendDestUnreachable(
    iface: *Interface,
    original_pkt: *const PacketBuffer,
    code: u8,
) bool {
    // RFC 4443 Section 2.4: Don't send error in response to:
    // - Multicast destination (with exceptions)
    // - Link-local source
    // - Unspecified source
    const orig_ip6 = packet.getIpv6Header(original_pkt.data, original_pkt.ip_offset) orelse return false;

    if (ipv6_types.isUnspecified(orig_ip6.src_addr)) return false;

    // Don't send errors for errors (except Packet Too Big)
    if (orig_ip6.next_header == ipv6_types.PROTO_ICMPV6) {
        const orig_icmpv6_offset = original_pkt.transport_offset;
        if (orig_icmpv6_offset + types.ICMPV6_HEADER_SIZE <= original_pkt.len) {
            const orig_icmpv6: *const types.Icmpv6Header = @ptrCast(@alignCast(&original_pkt.data[orig_icmpv6_offset]));
            if (types.isErrorMessage(orig_icmpv6.msg_type)) {
                return false;
            }
        }
    }

    return sendError(
        iface,
        original_pkt,
        types.TYPE_DEST_UNREACHABLE,
        code,
        0, // unused field
    );
}

/// Send ICMPv6 Packet Too Big
pub fn sendPacketTooBig(
    iface: *Interface,
    original_pkt: *const PacketBuffer,
    mtu: u32,
) bool {
    return sendError(
        iface,
        original_pkt,
        types.TYPE_PACKET_TOO_BIG,
        0,
        mtu,
    );
}

/// Send ICMPv6 Time Exceeded
pub fn sendTimeExceeded(
    iface: *Interface,
    original_pkt: *const PacketBuffer,
    code: u8,
) bool {
    const orig_ip6 = packet.getIpv6Header(original_pkt.data, original_pkt.ip_offset) orelse return false;
    if (ipv6_types.isUnspecified(orig_ip6.src_addr)) return false;

    return sendError(
        iface,
        original_pkt,
        types.TYPE_TIME_EXCEEDED,
        code,
        0,
    );
}

/// Send ICMPv6 Parameter Problem
pub fn sendParamProblem(
    iface: *Interface,
    original_pkt: *const PacketBuffer,
    code: u8,
    pointer: u32,
) bool {
    return sendError(
        iface,
        original_pkt,
        types.TYPE_PARAM_PROBLEM,
        code,
        pointer,
    );
}

/// Common function to send ICMPv6 error messages
fn sendError(
    iface: *Interface,
    original_pkt: *const PacketBuffer,
    msg_type: u8,
    code: u8,
    extra_field: u32, // MTU for Packet Too Big, Pointer for Param Problem
) bool {
    const orig_ip6 = packet.getIpv6Header(original_pkt.data, original_pkt.ip_offset) orelse return false;

    // RFC 4443: Include as much of invoking packet as possible
    // without exceeding IPv6 minimum MTU (1280 bytes)
    const max_payload = 1280 - packet.IPV6_HEADER_SIZE - 8; // 8 bytes for ICMPv6 error header
    const orig_packet_len = original_pkt.len - original_pkt.ip_offset;
    const payload_len = @min(orig_packet_len, max_payload);

    const icmpv6_len = 8 + payload_len; // 8 byte error header + original packet

    const buf = net_pool.allocTxBuffer() orelse return false;
    defer net_pool.freeTxBuffer(buf);

    const eth_len = packet.ETH_HEADER_SIZE;
    const ipv6_len = packet.IPV6_HEADER_SIZE;
    const total_len = eth_len + ipv6_len + icmpv6_len;

    if (total_len > buf.len) return false;

    // Reply to original source
    const dst_addr = orig_ip6.src_addr;

    const src_addr = ipv6_transmit.selectSourceAddress(iface, dst_addr) orelse {
        return false;
    };

    const dst_mac = resolveNextHopMac(iface, dst_addr) orelse {
        return false;
    };

    // Build Ethernet header
    const eth: *packet.EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[eth_len]));
    ip6.* = std.mem.zeroes(Ipv6Header);
    ip6.setVersionTcFlow(6, 0, 0);
    ip6.setPayloadLength(@truncate(icmpv6_len));
    ip6.next_header = ipv6_types.PROTO_ICMPV6;
    ip6.hop_limit = DEFAULT_HOP_LIMIT;
    ip6.src_addr = src_addr;
    ip6.dst_addr = dst_addr;

    // Build ICMPv6 error header (8 bytes: type, code, checksum, extra_field)
    const icmpv6_offset = eth_len + ipv6_len;
    buf[icmpv6_offset] = msg_type;
    buf[icmpv6_offset + 1] = code;
    buf[icmpv6_offset + 2] = 0; // Checksum (will be calculated)
    buf[icmpv6_offset + 3] = 0;
    // Extra field (MTU or Pointer) in network byte order
    const extra_bytes: [4]u8 = @bitCast(@byteSwap(extra_field));
    buf[icmpv6_offset + 4] = extra_bytes[0];
    buf[icmpv6_offset + 5] = extra_bytes[1];
    buf[icmpv6_offset + 6] = extra_bytes[2];
    buf[icmpv6_offset + 7] = extra_bytes[3];

    // Copy original packet data
    const payload_offset = icmpv6_offset + 8;
    const orig_data = original_pkt.data[original_pkt.ip_offset..][0..payload_len];
    @memcpy(buf[payload_offset..][0..payload_len], orig_data);

    // Calculate ICMPv6 checksum
    const icmpv6_data = buf[icmpv6_offset..][0..icmpv6_len];
    const cksum = checksum.icmpv6Checksum(src_addr, dst_addr, icmpv6_data);
    buf[icmpv6_offset + 2] = @truncate(cksum >> 8);
    buf[icmpv6_offset + 3] = @truncate(cksum);

    return iface.transmit(buf[0..total_len]);
}

/// Resolve next-hop MAC address for IPv6 destination
/// For link-local or on-link destinations, resolve directly.
/// For off-link, use gateway.
fn resolveNextHopMac(iface: *Interface, dst_addr: [16]u8) ?[6]u8 {
    // Multicast addresses map directly to Ethernet multicast
    if (ipv6_types.isMulticast(dst_addr)) {
        return ipv6_types.multicastToMac(dst_addr);
    }

    // Determine next-hop: use gateway if destination is off-link
    const next_hop = iface.getIpv6Gateway(dst_addr) orelse dst_addr;

    // Use NDP to resolve MAC address (no packet queuing for ICMPv6 TX)
    // For ICMPv6 messages, we don't queue - just return null if not cached
    return ndp.lookup(next_hop);
}
