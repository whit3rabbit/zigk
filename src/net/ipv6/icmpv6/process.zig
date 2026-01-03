// ICMPv6 Packet Processing (RX Path)
//
// Implements RFC 4443 (ICMPv6) receive path handling.
// Validates checksums, handles Echo Request/Reply, and delegates NDP messages.
//
// Security considerations:
// - Checksum validation using IPv6 pseudo-header (RFC 4443 Section 2.3)
// - Rate limiting for error responses (DoS prevention) (RFC 4443 Section 2.4)
// - Hop limit validation for NDP messages (must be 255)
// - No replies to multicast source addresses (RFC 4443 Section 2.4)

const std = @import("std");
const packet = @import("../../core/packet.zig");
const interface = @import("../../core/interface.zig");
const checksum = @import("../../core/checksum.zig");
const types = @import("types.zig");
const transmit = @import("transmit.zig");
const ipv6_types = @import("../ipv6/types.zig");
const ndp = @import("../ndp/root.zig");

const PacketBuffer = packet.PacketBuffer;
const Interface = interface.Interface;

/// Process an incoming ICMPv6 packet (RFC 4443 Section 2).
///
/// Parameters:
///   - iface: Network interface packet was received on
///   - pkt: Packet buffer with ICMPv6 data
///
/// Returns true if packet was handled, false if dropped.
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    // Validate minimum ICMPv6 header size
    if (pkt.len < pkt.transport_offset + types.MIN_ICMPV6_SIZE) {
        return false;
    }

    // Get ICMPv6 header
    const icmpv6 = getIcmpv6Header(pkt.data, pkt.transport_offset) orelse return false;

    // Calculate ICMPv6 message length
    if (pkt.len < pkt.transport_offset) return false;
    const icmpv6_len = pkt.len - pkt.transport_offset;

    // Validate ICMPv6 checksum using IPv6 pseudo-header (RFC 4443 Section 2.3)
    const icmpv6_data = pkt.data[pkt.transport_offset..][0..icmpv6_len];
    if (!verifyIcmpv6Checksum(pkt.src_ipv6, pkt.dst_ipv6, icmpv6_data)) {
        return false;
    }

    // Handle based on message type
    return switch (icmpv6.msg_type) {
        types.TYPE_ECHO_REQUEST => handleEchoRequest(iface, pkt, icmpv6_len),
        types.TYPE_ECHO_REPLY => handleEchoReply(pkt),
        types.TYPE_DEST_UNREACHABLE => handleDestUnreachable(pkt, icmpv6),
        types.TYPE_PACKET_TOO_BIG => handlePacketTooBig(pkt),
        types.TYPE_TIME_EXCEEDED => handleTimeExceeded(pkt, icmpv6),
        types.TYPE_PARAM_PROBLEM => handleParamProblem(pkt, icmpv6),
        // NDP messages - delegate to NDP module (RFC 4861)
        types.TYPE_ROUTER_SOLICITATION,
        types.TYPE_ROUTER_ADVERTISEMENT,
        types.TYPE_NEIGHBOR_SOLICITATION,
        types.TYPE_NEIGHBOR_ADVERTISEMENT,
        types.TYPE_REDIRECT,
        => handleNdpMessage(iface, pkt),
        else => false, // Unknown message type
    };
}

/// Handle ICMPv6 Echo Request (ping6) (RFC 4443 Section 4.1)
fn handleEchoRequest(iface: *Interface, req_pkt: *PacketBuffer, icmpv6_len: usize) bool {
    // Validate Echo header size
    if (icmpv6_len < types.ICMPV6_ECHO_HEADER_SIZE) {
        return false;
    }

    // Security: Don't reply to multicast source addresses (RFC 4443 Section 2.4)
    if (ipv6_types.isMulticast(req_pkt.src_ipv6)) {
        return false;
    }

    // Security: Don't reply to unspecified address (::)
    if (ipv6_types.isUnspecified(req_pkt.src_ipv6)) {
        return false;
    }

    // Get echo header
    const echo_hdr = getIcmpv6EchoHeader(req_pkt.data, req_pkt.transport_offset) orelse return false;

    // Calculate echo data length
    const echo_data_len = icmpv6_len - types.ICMPV6_ECHO_HEADER_SIZE;

    // Security: Limit echo data size
    if (echo_data_len > types.MAX_ECHO_DATA_SIZE) {
        return false;
    }

    // Get echo data (if any)
    var echo_data: []const u8 = &[_]u8{};
    if (echo_data_len > 0) {
        const data_offset = req_pkt.transport_offset + types.ICMPV6_ECHO_HEADER_SIZE;
        if (data_offset + echo_data_len <= req_pkt.len) {
            echo_data = req_pkt.data[data_offset..][0..echo_data_len];
        }
    }

    // Send Echo Reply
    return transmit.sendEchoReply(
        iface,
        req_pkt.src_ipv6, // Reply to source
        echo_hdr.getIdentifier(),
        echo_hdr.getSequence(),
        echo_data,
    );
}

/// Handle ICMPv6 Echo Reply (RFC 4443 Section 4.2)
fn handleEchoReply(pkt: *PacketBuffer) bool {
    const console = @import("console");

    // Extract echo header for logging
    if (pkt.transport_offset + types.ICMPV6_ECHO_HEADER_SIZE <= pkt.len) {
        const echo_hdr = getIcmpv6EchoHeader(pkt.data, pkt.transport_offset) orelse return true;
        console.debug("ICMPv6: Echo reply id={} seq={}", .{ echo_hdr.getIdentifier(), echo_hdr.getSequence() });
    }

    // TODO: Wake blocked ping socket when ping6 socket API is implemented
    // The socket layer would track outstanding pings and match by id/seq
    return true;
}

/// Handle ICMPv6 Destination Unreachable (RFC 4443 Section 3.1)
fn handleDestUnreachable(pkt: *PacketBuffer, icmpv6: *const types.Icmpv6Header) bool {
    const console = @import("console");

    // Log the error code
    const code_desc: []const u8 = switch (icmpv6.code) {
        0 => "no route to destination",
        1 => "communication prohibited",
        2 => "beyond scope of source",
        3 => "address unreachable",
        4 => "port unreachable",
        5 => "source address failed policy",
        6 => "reject route to destination",
        else => "unknown code",
    };
    console.debug("ICMPv6: Dest unreachable ({}): {s}", .{ icmpv6.code, code_desc });

    // Extract original packet from ICMPv6 error payload
    // Format: 4 bytes unused + original IPv6 header + original transport header
    const err_payload_offset = pkt.transport_offset + 8;
    if (err_payload_offset + packet.IPV6_HEADER_SIZE > pkt.len) {
        return true; // Not enough data to extract original packet
    }

    const orig_ip6 = packet.getIpv6Header(pkt.data, err_payload_offset) orelse return true;

    // Notify TCP if the original packet was TCP (next_header == 6)
    if (orig_ip6.next_header == 6) { // IPPROTO_TCP
        // Extract original TCP source/dest ports if present
        const orig_tcp_offset = err_payload_offset + packet.IPV6_HEADER_SIZE;
        if (orig_tcp_offset + 4 <= pkt.len) {
            const src_port = std.mem.readInt(u16, pkt.data[orig_tcp_offset..][0..2], .big);
            const dst_port = std.mem.readInt(u16, pkt.data[orig_tcp_offset + 2 ..][0..4][0..2], .big);

            // TODO: Notify TCP layer to abort connection
            // tcp.handleIcmpError(orig_ip6.src_addr, src_port, orig_ip6.dst_addr, dst_port, .Unreachable);
            console.debug("  Original: TCP {}:{} -> {}:{}", .{
                orig_ip6.src_addr, src_port, orig_ip6.dst_addr, dst_port,
            });
        }
    }

    return true;
}

/// Handle ICMPv6 Packet Too Big (PMTUD) (RFC 4443 Section 3.2, RFC 8201)
fn handlePacketTooBig(pkt: *PacketBuffer) bool {
    const console = @import("console");

    // Extract MTU from message
    const ptb_offset = pkt.transport_offset;
    if (ptb_offset + @sizeOf(types.Icmpv6PacketTooBig) > pkt.len) {
        return false;
    }

    const ptb: *const types.Icmpv6PacketTooBig = @ptrCast(@alignCast(&pkt.data[ptb_offset]));
    const new_mtu = ptb.getMtu();

    // Security: Validate MTU is reasonable
    // IPv6 minimum MTU is 1280 (RFC 8200 Section 5)
    if (new_mtu < 1280) {
        console.warn("ICMPv6: Packet Too Big with invalid MTU {} < 1280", .{new_mtu});
        return false;
    }

    // Extract original destination from embedded IPv6 header
    const orig_ip6_offset = ptb_offset + 8; // After ICMPv6 error header
    if (orig_ip6_offset + packet.IPV6_HEADER_SIZE <= pkt.len) {
        const orig_ip6 = packet.getIpv6Header(pkt.data, orig_ip6_offset) orelse return true;

        console.debug("ICMPv6: Packet Too Big, new MTU={} for dst={any}", .{ new_mtu, orig_ip6.dst_addr });

        // TODO: Update PMTU cache when implemented
        // pmtu.updatePathMtu(orig_ip6.dst_addr, new_mtu);
    }

    return true;
}

/// Handle ICMPv6 Time Exceeded (RFC 4443 Section 3.3)
fn handleTimeExceeded(pkt: *PacketBuffer, icmpv6: *const types.Icmpv6Header) bool {
    const console = @import("console");

    const code_desc: []const u8 = switch (icmpv6.code) {
        0 => "hop limit exceeded in transit",
        1 => "fragment reassembly time exceeded",
        else => "unknown code",
    };
    console.debug("ICMPv6: Time exceeded ({}): {s}", .{ icmpv6.code, code_desc });

    // Extract original packet info for logging
    const err_payload_offset = pkt.transport_offset + 8;
    if (err_payload_offset + packet.IPV6_HEADER_SIZE <= pkt.len) {
        const orig_ip6 = packet.getIpv6Header(pkt.data, err_payload_offset) orelse return true;
        console.debug("  Original dst: {any}", .{orig_ip6.dst_addr});
    }

    // TODO: Notify transport layer (useful for traceroute implementation)
    return true;
}

/// Handle ICMPv6 Parameter Problem (RFC 4443 Section 3.4)
fn handleParamProblem(pkt: *PacketBuffer, icmpv6: *const types.Icmpv6Header) bool {
    const console = @import("console");

    const code_desc: []const u8 = switch (icmpv6.code) {
        0 => "erroneous header field encountered",
        1 => "unrecognized next header type",
        2 => "unrecognized IPv6 option",
        else => "unknown code",
    };
    console.debug("ICMPv6: Parameter problem ({}): {s}", .{ icmpv6.code, code_desc });

    // Extract pointer field (offset into original packet where problem occurred)
    const ptr_offset = pkt.transport_offset + 4;
    if (ptr_offset + 4 <= pkt.len) {
        const pointer = std.mem.readInt(u32, pkt.data[ptr_offset..][0..4], .big);
        console.debug("  Problem at offset: {}", .{pointer});
    }

    // TODO: Notify transport layer
    return true;
}

/// Handle NDP messages (delegated to NDP module)
fn handleNdpMessage(iface: *Interface, pkt: *PacketBuffer) bool {
    // Validate hop limit == 255 for NDP messages (RFC 4861 Section 6.1.1, 7.1.1, 7.1.2)
    const ip6 = packet.getIpv6Header(pkt.data, pkt.ip_offset) orelse return false;
    if (ip6.hop_limit != 255) {
        return false;
    }

    // Get message type from ICMPv6 header
    const icmpv6 = getIcmpv6Header(pkt.data, pkt.transport_offset) orelse return false;

    // Delegate to NDP module
    return ndp.processPacket(iface, pkt, icmpv6.msg_type);
}

/// Verify ICMPv6 checksum using IPv6 pseudo-header
fn verifyIcmpv6Checksum(src: [16]u8, dst: [16]u8, data: []const u8) bool {
    const computed = checksum.icmpv6Checksum(src, dst, data);
    return computed == 0 or computed == 0xFFFF;
}

/// Get ICMPv6 header from packet buffer
fn getIcmpv6Header(data: []const u8, offset: usize) ?*const types.Icmpv6Header {
    if (offset + types.ICMPV6_HEADER_SIZE > data.len) return null;
    return @ptrCast(@alignCast(&data[offset]));
}

/// Get ICMPv6 Echo header from packet buffer
fn getIcmpv6EchoHeader(data: []const u8, offset: usize) ?*const types.Icmpv6EchoHeader {
    if (offset + types.ICMPV6_ECHO_HEADER_SIZE > data.len) return null;
    return @ptrCast(@alignCast(&data[offset]));
}

// =============================================================================
// Tests
// =============================================================================

test "ICMPv6 header access" {
    const testing = std.testing;

    var buf: [64]u8 = undefined;
    buf[0] = types.TYPE_ECHO_REQUEST;
    buf[1] = 0;
    buf[2] = 0x12;
    buf[3] = 0x34;

    const hdr = getIcmpv6Header(&buf, 0).?;
    try testing.expectEqual(types.TYPE_ECHO_REQUEST, hdr.msg_type);
    try testing.expectEqual(@as(u8, 0), hdr.code);
}
