// IPv6 Packet Processing (RX Path)
//
// Handles incoming IPv6 packet validation and dispatch to transport protocols.
// Implements RFC 8200 (IPv6 Specification).
//
// Processing Steps:
// 1. Validate version (must be 6) (RFC 8200 Section 3)
// 2. Validate payload length against buffer
// 3. Parse extension header chain (with DoS limits) (RFC 8200 Section 4)
// 4. Handle fragmentation via Fragment extension header (RFC 8200 Section 4.5)
// 5. Dispatch to upper-layer protocol (ICMPv6, TCP, UDP)

const std = @import("std");
const packet = @import("../../core/packet.zig");
const interface = @import("../../core/interface.zig");
const types = @import("types.zig");
const fragment = @import("fragment.zig");
const icmpv6 = @import("../icmpv6/root.zig");

const PacketBuffer = packet.PacketBuffer;
const Ipv6Header = packet.Ipv6Header;
const Interface = interface.Interface;

/// Process an incoming IPv6 packet.
///
/// Performs the following steps:
/// 1. Validation: Version (6), payload length bounds.
/// 2. Extension Headers: Parse chain with MAX_EXTENSION_HEADERS limit (RFC 8200 Section 4).
/// 3. Destination Check: Unicast (to us), or Multicast we subscribed to.
/// 4. Fragmentation: Handle via Fragment extension header (RFC 8200 Section 4.5).
/// 5. Dispatch: Route to appropriate transport protocol (ICMPv6, UDP, TCP).
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    // Get IPv6 header with bounds check
    const ip6 = packet.getIpv6HeaderMut(pkt.data, pkt.ip_offset) orelse return false;

    // 1. Verify Version (Must be 6)
    if (ip6.getVersion() != 6) return false;

    // 2. Verify payload length
    const payload_len = ip6.getPayloadLength();

    // Ensure we have enough data for header + payload
    const total_required = std.math.add(usize, pkt.ip_offset, types.HEADER_SIZE) catch return false;
    const packet_end = std.math.add(usize, total_required, payload_len) catch return false;
    if (packet_end > pkt.len) return false;

    // Truncate packet buffer to actual IPv6 length (ignore Ethernet padding)
    pkt.len = packet_end;

    // 3. Address checks
    const dst_addr = ip6.dst_addr;
    pkt.dst_ipv6 = dst_addr;
    pkt.src_ipv6 = ip6.src_addr;

    // Check if destination is for us
    if (!isDestinationForUs(iface, dst_addr)) {
        return false;
    }

    // Set multicast flag
    pkt.is_multicast = types.isMulticast(dst_addr);
    pkt.is_broadcast = false; // IPv6 has no broadcast, uses multicast

    // 4. Parse extension headers
    const ext_result = parseExtensionHeaders(pkt, ip6.next_header) orelse return false;

    // 5. Handle fragmentation (if Fragment header present)
    if (ext_result.fragment) |frag_info| {
        // Get fragment payload (data after all extension headers including Fragment)
        const payload_start = ext_result.transport_offset;
        if (payload_start >= pkt.len) return false;
        const payload = pkt.data[payload_start..pkt.len];

        // Process fragment
        var result = fragment.processFragment(
            pkt.src_ipv6,
            pkt.dst_ipv6,
            frag_info,
            payload,
        ) orelse {
            // Fragment queued for reassembly, not complete yet
            return true;
        };

        // Reassembly complete - process the reassembled packet
        defer result.deinit();

        // Create a temporary packet buffer for the reassembled data
        // The reassembled payload starts at offset 0 in the owned buffer
        const reassembled = result.payload();

        // Dispatch to transport based on next_header from fragment
        return dispatchReassembled(iface, pkt, reassembled, result.next_header);
    }

    // 6. Set transport offset and protocol
    pkt.transport_offset = ext_result.transport_offset;
    pkt.ip_protocol = ext_result.next_header;

    // 7. Dispatch to upper-layer protocol
    return dispatchToTransport(iface, pkt, ext_result.next_header);
}

/// Check if the destination address is for this interface.
fn isDestinationForUs(iface: *Interface, dst_addr: [16]u8) bool {
    // Check interface-local loopback
    if (types.isLoopback(dst_addr)) {
        return true;
    }

    // Check link-local address (if configured on interface)
    if (types.isLinkLocal(dst_addr)) {
        if (iface.hasIpv6LinkLocal()) {
            if (types.addressEqual(dst_addr, iface.link_local_addr)) {
                return true;
            }
        }
    }

    // Check global addresses configured on interface
    for (iface.ipv6_addrs[0..iface.ipv6_addr_count]) |entry| {
        if (types.addressEqual(dst_addr, entry.addr)) {
            return true;
        }
    }

    // Check multicast subscriptions
    if (types.isMulticast(dst_addr)) {
        // All-nodes multicast (ff02::1) is always accepted
        if (types.addressEqual(dst_addr, types.ALL_NODES_MULTICAST)) {
            return true;
        }

        // Check if we're subscribed to this multicast group
        if (iface.acceptsIpv6Multicast(dst_addr)) {
            return true;
        }

        // Check solicited-node multicast for our addresses
        if (iface.acceptsSolicitedNodeMulticast(dst_addr)) {
            return true;
        }
    }

    return false;
}

/// Parse IPv6 extension header chain.
/// RFC 8200 Section 4: Extension Headers
/// Returns the final next_header (upper-layer protocol) and transport offset.
/// Returns null if parsing fails or DoS limit exceeded.
fn parseExtensionHeaders(pkt: *PacketBuffer, first_next_header: u8) ?types.ExtensionParseResult {
    var next_header = first_next_header;
    var offset = std.math.add(usize, pkt.ip_offset, types.HEADER_SIZE) catch return null;
    var fragment_info: ?types.FragmentInfo = null;
    var extension_count: usize = 0;

    while (types.isExtensionHeader(next_header)) {
        // DoS protection: limit extension header count
        if (extension_count >= types.MAX_EXTENSION_HEADERS) {
            return null;
        }
        extension_count += 1;

        // Get extension header with bounds check
        const ext_hdr = packet.getIpv6ExtHeader(pkt.data, offset) orelse return null;

        if (next_header == types.PROTO_FRAGMENT) {
            // Fragment header is fixed 8 bytes
            const frag_hdr = packet.getIpv6FragmentHeader(pkt.data, offset) orelse return null;

            fragment_info = types.FragmentInfo{
                .offset = frag_hdr.getFragmentOffset(),
                .more_fragments = frag_hdr.hasMoreFragments(),
                .identification = @byteSwap(frag_hdr.identification),
                .next_header = frag_hdr.next_header,
            };

            next_header = frag_hdr.next_header;
            offset = std.math.add(usize, offset, 8) catch return null;
        } else {
            // Standard extension header format
            // Use getTotalLength() which handles the calculation correctly
            const hdr_len = ext_hdr.getTotalLength();

            // Verify we have enough data
            const next_offset = std.math.add(usize, offset, hdr_len) catch return null;
            if (next_offset > pkt.len) return null;

            next_header = ext_hdr.next_header;
            offset = next_offset;
        }
    }

    // Ensure transport header is within bounds
    if (offset > pkt.len) return null;

    return types.ExtensionParseResult{
        .next_header = next_header,
        .transport_offset = offset,
        .fragment = fragment_info,
        .extension_count = extension_count,
    };
}

/// Dispatch packet to upper-layer protocol handler.
fn dispatchToTransport(iface: *Interface, pkt: *PacketBuffer, protocol: u8) bool {
    // Validate minimum transport header size
    const remaining = if (pkt.len > pkt.transport_offset) pkt.len - pkt.transport_offset else 0;

    const min_size: usize = switch (protocol) {
        types.PROTO_ICMPV6 => 4, // ICMPv6 minimum: type + code + checksum
        types.PROTO_UDP => 8, // UDP header
        types.PROTO_TCP => 20, // TCP minimum header
        types.PROTO_NONE => return true, // No payload expected
        else => 0,
    };

    if (remaining < min_size) return false;

    return switch (protocol) {
        types.PROTO_ICMPV6 => icmpv6.processPacket(iface, pkt),
        types.PROTO_UDP => handleUdp6(iface, pkt),
        types.PROTO_TCP => handleTcp6(iface, pkt),
        types.PROTO_NONE => true, // No next header (valid per RFC 8200)
        else => false, // Unknown protocol
    };
}

/// Handle UDP over IPv6
fn handleUdp6(iface: *Interface, pkt: *PacketBuffer) bool {
    const udp = @import("../../transport/udp.zig");
    return udp.processPacket6(iface, pkt);
}

/// Handle TCP over IPv6
fn handleTcp6(iface: *Interface, pkt: *PacketBuffer) bool {
    const tcp_rx = @import("../../transport/tcp/rx/root.zig");
    return tcp_rx.processPacket6(iface, pkt);
}

/// Dispatch reassembled packet to upper-layer protocol handler.
/// Unlike dispatchToTransport, this handles data in a separate reassembled buffer.
fn dispatchReassembled(iface: *Interface, pkt: *PacketBuffer, reassembled: []u8, protocol: u8) bool {
    // Suppress unused parameter warnings for stubs
    _ = iface;
    _ = pkt;
    _ = reassembled;

    const min_size: usize = switch (protocol) {
        types.PROTO_ICMPV6 => 4,
        types.PROTO_UDP => 8,
        types.PROTO_TCP => 20,
        types.PROTO_NONE => return true,
        else => 0,
    };

    // TODO: Phase 4/7 - when implemented, check reassembled.len < min_size here
    _ = min_size;

    // For now, reassembled packets follow the same stub paths
    // When Phase 4/7 are implemented, these will call the appropriate handlers
    // with the reassembled buffer
    return switch (protocol) {
        types.PROTO_ICMPV6 => false, // TODO: Phase 4
        types.PROTO_UDP => false, // TODO: Phase 7
        types.PROTO_TCP => false, // TODO: Phase 7
        types.PROTO_NONE => true,
        else => false,
    };
}

/// Decrement Hop Limit (IPv6 equivalent of TTL).
/// Used when routing packets.
/// Returns false if hop limit drops to 0.
pub fn decrementHopLimit(pkt: *PacketBuffer) bool {
    const ip6 = packet.getIpv6HeaderMut(pkt.data, pkt.ip_offset) orelse return false;

    if (ip6.hop_limit <= 1) return false;

    ip6.hop_limit -= 1;

    // Note: IPv6 has no header checksum to update

    return true;
}

// =============================================================================
// Tests
// =============================================================================

test "parseExtensionHeaders with no extensions" {
    const testing = std.testing;

    var buf: [128]u8 = undefined;
    var pkt = PacketBuffer.init(&buf, 60);
    pkt.ip_offset = 0;

    // Set up minimal IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[0]));
    ip6.* = std.mem.zeroes(Ipv6Header);
    ip6.setVersion(6);
    ip6.setPayloadLength(20);
    ip6.next_header = types.PROTO_TCP;

    const result = parseExtensionHeaders(&pkt, types.PROTO_TCP);
    try testing.expect(result != null);
    try testing.expectEqual(types.PROTO_TCP, result.?.next_header);
    try testing.expectEqual(@as(usize, 40), result.?.transport_offset);
    try testing.expectEqual(@as(usize, 0), result.?.extension_count);
    try testing.expect(result.?.fragment == null);
}

test "extension header DoS limit" {
    const testing = std.testing;

    var buf: [512]u8 = undefined;
    var pkt = PacketBuffer.init(&buf, 512);
    pkt.ip_offset = 0;

    // Set up IPv6 header pointing to chain of Hop-by-Hop options
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[0]));
    ip6.* = std.mem.zeroes(Ipv6Header);
    ip6.setVersion(6);
    ip6.setPayloadLength(400);
    ip6.next_header = types.PROTO_HOPOPT;

    // Create chain of 11 extension headers (exceeds MAX_EXTENSION_HEADERS=10)
    var offset: usize = 40;
    for (0..11) |_| {
        buf[offset] = types.PROTO_HOPOPT; // next_header
        buf[offset + 1] = 0; // hdr_len = 0 means 8 bytes total
        offset += 8;
    }

    const result = parseExtensionHeaders(&pkt, types.PROTO_HOPOPT);
    try testing.expect(result == null); // Should fail due to DoS limit
}
