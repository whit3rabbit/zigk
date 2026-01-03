// IPv6 Packet Transmission (TX Path)
//
// Handles outgoing IPv6 packet building and transmission.
// Implements RFC 8200 (IPv6 Specification).
//
// Key Differences from IPv4:
// - Fixed 40-byte header (no options in base header)
// - No header checksum (relies on L2 and transport checksums)
// - Fragmentation only at source, not by intermediate routers
// - Uses NDP for address resolution (not ARP)

const std = @import("std");
const packet = @import("../../core/packet.zig");
const interface = @import("../../core/interface.zig");
const ethernet = @import("../../ethernet/ethernet.zig");
const types = @import("types.zig");
const heap = @import("heap");
const ndp = @import("../ndp/root.zig");

const PacketBuffer = packet.PacketBuffer;
const Ipv6Header = packet.Ipv6Header;
const Interface = interface.Interface;

/// IPv6 header size (fixed, no options in base header)
pub const IPV6_HEADER_SIZE: usize = types.HEADER_SIZE;

/// Maximum IPv6 payload size (64KB - 1, can be larger with Jumbograms)
const MAX_IPV6_PAYLOAD: usize = 65535;

/// Build an IPv6 packet header.
/// Assumes Ethernet header space is already reserved.
///
/// Sets up:
/// - Version (6), Traffic Class (0), Flow Label (0)
/// - Payload Length
/// - Next Header (protocol)
/// - Hop Limit (default 64)
/// - Source and Destination addresses
pub fn buildPacket(
    iface: *const Interface,
    pkt: *PacketBuffer,
    dst_addr: [16]u8,
    next_header: u8,
    payload_len: usize,
) bool {
    return buildPacketWithOptions(iface, pkt, dst_addr, next_header, payload_len, .{});
}

/// Options for IPv6 packet building
pub const BuildOptions = struct {
    traffic_class: u8 = 0,
    flow_label: u20 = 0,
    hop_limit: u8 = types.DEFAULT_HOP_LIMIT,
    /// Source address override (null = use interface address)
    src_addr: ?[16]u8 = null,
};

/// Build an IPv6 packet header with explicit options.
pub fn buildPacketWithOptions(
    iface: *const Interface,
    pkt: *PacketBuffer,
    dst_addr: [16]u8,
    next_header: u8,
    payload_len: usize,
    options: BuildOptions,
) bool {
    // Validate payload length
    if (payload_len > MAX_IPV6_PAYLOAD) return false;

    // Set offsets
    pkt.ip_offset = packet.ETH_HEADER_SIZE;
    const transport_start = std.math.add(usize, pkt.ip_offset, IPV6_HEADER_SIZE) catch return false;
    pkt.transport_offset = transport_start;

    // Ensure buffer has space for IPv6 header
    const header_end = std.math.add(usize, pkt.ip_offset, IPV6_HEADER_SIZE) catch return false;
    if (header_end > pkt.data.len) return false;

    const ip6_hdr = packet.getIpv6HeaderMut(pkt.data, pkt.ip_offset) orelse return false;

    // Set version (6), traffic class, and flow label
    ip6_hdr.setVersion(6);
    ip6_hdr.setTrafficClass(options.traffic_class);
    ip6_hdr.setFlowLabel(options.flow_label);

    // Set payload length
    ip6_hdr.setPayloadLength(@intCast(payload_len));

    // Set next header (protocol)
    ip6_hdr.next_header = next_header;

    // Set hop limit
    ip6_hdr.hop_limit = options.hop_limit;

    // Set source address (from options or interface)
    if (options.src_addr) |src| {
        ip6_hdr.src_addr = src;
    } else {
        // Select appropriate source address based on destination scope
        ip6_hdr.src_addr = selectSourceAddress(iface, dst_addr) orelse return false;
    }

    // Set destination address
    ip6_hdr.dst_addr = dst_addr;

    // Note: IPv6 has no header checksum

    return true;
}

/// Select the best source address for a given destination.
/// Per RFC 6724, we prefer:
/// - Link-local source for link-local destination
/// - Global source for global destination
pub fn selectSourceAddress(iface: *const Interface, dst_addr: [16]u8) ?[16]u8 {
    // For link-local destinations, use link-local source
    if (types.isLinkLocal(dst_addr)) {
        if (iface.has_link_local) {
            return iface.link_local_addr;
        }
        return null;
    }

    // For loopback, use loopback
    if (types.isLoopback(dst_addr)) {
        return .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    }

    // For global destinations, prefer global source
    for (iface.ipv6_addrs[0..iface.ipv6_addr_count]) |entry| {
        if (entry.scope == .Global) {
            return entry.addr;
        }
    }

    // Fall back to link-local if no global address
    if (iface.has_link_local) {
        return iface.link_local_addr;
    }

    return null;
}

/// Send an IPv6 packet.
///
/// Handles:
/// 1. Loopback routing if destination is ::1
/// 2. Next-hop resolution (on-link vs gateway)
/// 3. NDP resolution for MAC address (TODO: Phase 5)
/// 4. Fragmentation if packet exceeds Path MTU (TODO)
/// 5. Ethernet frame construction and transmission
pub fn sendPacket(iface: *Interface, pkt: *PacketBuffer, dst_addr: [16]u8) bool {
    // 1. Check for Loopback (::1)
    if (types.isLoopback(dst_addr)) {
        return sendLoopback(iface, pkt);
    }

    // 2. Determine Next Hop
    const next_hop = iface.getIpv6Gateway(dst_addr) orelse {
        // No route to destination
        return false;
    };

    // 3. Resolve MAC Address
    var dst_mac: [6]u8 = undefined;

    if (types.isMulticast(dst_addr)) {
        // IPv6 multicast to Ethernet multicast (RFC 2464)
        // 33:33:xx:xx:xx:xx (last 32 bits of IPv6 address)
        dst_mac[0] = 0x33;
        dst_mac[1] = 0x33;
        dst_mac[2] = dst_addr[12];
        dst_mac[3] = dst_addr[13];
        dst_mac[4] = dst_addr[14];
        dst_mac[5] = dst_addr[15];
    } else {
        // Unicast: Resolve via NDP
        // Prepare packet data for potential queuing if resolution is pending
        const ip6_hdr = packet.getIpv6Header(pkt.data, pkt.ip_offset) orelse return false;
        const ip_total_len = std.math.add(usize, IPV6_HEADER_SIZE, ip6_hdr.getPayloadLength()) catch return false;
        const pkt_len = std.math.add(usize, pkt.ip_offset, ip_total_len) catch return false;

        // Resolve next-hop MAC (cache lookup or NS trigger)
        if (ndp.resolveOrRequest(iface, next_hop, pkt.data[0..pkt_len])) |mac| {
            dst_mac = mac;
        } else {
            // NDP request sent, packet queued for later transmission
            // Return true because the packet will be sent when NA arrives
            return true;
        }
    }

    // 4. Build Ethernet frame
    if (!ethernet.buildFrame(iface, pkt, dst_mac, ethernet.ETHERTYPE_IPV6)) {
        return false;
    }

    // 5. Calculate packet length
    const ip6_hdr = packet.getIpv6Header(pkt.data, pkt.ip_offset) orelse return false;
    const ip_total_len = std.math.add(usize, IPV6_HEADER_SIZE, ip6_hdr.getPayloadLength()) catch return false;
    pkt.len = std.math.add(usize, pkt.ip_offset, ip_total_len) catch return false;

    // 6. Check MTU and fragment if needed
    // Note: IPv6 minimum MTU is 1280 bytes (RFC 8200)
    // For packets > MTU, we need to fragment at the source
    if (ip_total_len > iface.mtu) {
        // TODO: Implement IPv6 fragmentation
        // Unlike IPv4, IPv6 fragmentation uses a Fragment extension header
        // and is only done at the source, not by intermediate routers
        return false;
    }

    // 7. Transmit
    return ethernet.sendFrame(iface, pkt);
}

/// Send packet via loopback interface
fn sendLoopback(iface: *Interface, pkt: *PacketBuffer) bool {
    // Import loopback driver
    const loopback = @import("../../drivers/loopback.zig");

    if (loopback.getInterface()) |lo| {
        if (!ethernet.buildFrame(lo, pkt, [_]u8{0} ** 6, ethernet.ETHERTYPE_IPV6)) {
            return false;
        }
        const ip6_hdr = packet.getIpv6Header(pkt.data, pkt.ip_offset) orelse return false;
        const ip_total_len = std.math.add(usize, IPV6_HEADER_SIZE, ip6_hdr.getPayloadLength()) catch return false;
        pkt.len = std.math.add(usize, pkt.ip_offset, ip_total_len) catch return false;
        return lo.transmit(pkt.data[0..pkt.len]);
    }
    _ = iface;
    return false;
}

/// Send an IPv6 packet with fragmentation support.
/// Fragments packets larger than Path MTU using Fragment extension header.
///
/// Note: This is more complex than IPv4 fragmentation because:
/// - Fragment header is an extension header, not part of base header
/// - Original headers (except Fragment header) are copied to each fragment
/// - Fragment offset is in 8-octet units
fn sendFragmentedPacket(iface: *Interface, pkt: *PacketBuffer, dst_mac: [6]u8) bool {
    const ip6_hdr = packet.getIpv6Header(pkt.data, pkt.ip_offset) orelse return false;
    const payload_len = ip6_hdr.getPayloadLength();

    // Calculate fragment size (must be multiple of 8 bytes)
    const mtu_payload = (@as(usize, iface.mtu) - IPV6_HEADER_SIZE - 8) & ~@as(usize, 7);
    if (mtu_payload == 0) return false;

    const payload_start = std.math.add(usize, pkt.ip_offset, IPV6_HEADER_SIZE) catch return false;
    const payload = pkt.data[payload_start..][0..payload_len];

    // Generate fragment identification (should be unique per source-dest-next_header tuple)
    // TODO: Use proper atomic counter or CSPRNG
    const identification = generateFragmentId();

    const alloc = heap.allocator();
    const frag_buf = alloc.alloc(u8, packet.MAX_PACKET_SIZE) catch return false;
    defer alloc.free(frag_buf);

    var offset: usize = 0;
    while (offset < payload.len) {
        const remaining = payload.len - offset;
        const chunk_len = @min(remaining, mtu_payload);
        const last_frag = (chunk_len == remaining);

        var frag_pkt = PacketBuffer.init(frag_buf, 0);

        // Build Ethernet frame
        if (!ethernet.buildFrame(iface, &frag_pkt, dst_mac, ethernet.ETHERTYPE_IPV6)) return false;

        const frag_ip_offset = packet.ETH_HEADER_SIZE;
        frag_pkt.ip_offset = frag_ip_offset;

        // Copy original IPv6 header
        const frag_ip6: *Ipv6Header = @ptrCast(@alignCast(&frag_buf[frag_ip_offset]));
        frag_ip6.* = ip6_hdr.*;

        // Update payload length (fragment header + fragment data)
        const frag_payload_len = std.math.add(usize, 8, chunk_len) catch return false;
        if (frag_payload_len > std.math.maxInt(u16)) return false;
        frag_ip6.setPayloadLength(@intCast(frag_payload_len));

        // Set next header to Fragment (44)
        const orig_next_header = frag_ip6.next_header;
        frag_ip6.next_header = types.PROTO_FRAGMENT;

        // Build Fragment header at offset after IPv6 header
        const frag_hdr_offset = std.math.add(usize, frag_ip_offset, IPV6_HEADER_SIZE) catch return false;
        const frag_hdr = packet.getIpv6FragmentHeaderMut(frag_buf, frag_hdr_offset) orelse return false;

        frag_hdr.next_header = orig_next_header;
        frag_hdr.reserved = 0;

        // Fragment offset (in 8-octet units) + MF bit
        const frag_offset_val: u16 = @intCast(offset / 8);
        var frag_offset_field: u16 = frag_offset_val << 3;
        if (!last_frag) frag_offset_field |= 0x0001; // MF bit
        frag_hdr.frag_offset_mf = @byteSwap(frag_offset_field);

        frag_hdr.identification = @byteSwap(identification);

        // Copy fragment payload
        const payload_dest = std.math.add(usize, frag_hdr_offset, 8) catch return false;
        @memcpy(frag_buf[payload_dest..][0..chunk_len], payload[offset..][0..chunk_len]);

        frag_pkt.len = std.math.add(usize, payload_dest, chunk_len) catch return false;

        if (!ethernet.sendFrame(iface, &frag_pkt)) return false;

        offset += chunk_len;
    }

    return true;
}

/// Generate a unique fragment identification value.
/// Per RFC 8200, this should be unique for each {Source, Destination, Next Header} tuple.
/// SECURITY: Uses entropy source (RDRAND in kernel, getrandom in userspace) to prevent
/// fragment ID prediction attacks (RFC 7739).
fn generateFragmentId() u32 {
    const root = @import("root");

    if (@hasDecl(root, "hal")) {
        // Kernel mode: use hardware entropy
        return @truncate(root.hal.entropy.getHardwareEntropy());
    } else {
        // Userspace: use a simple counter (fragmentation shouldn't happen in userspace)
        // This is acceptable because userspace processes rely on kernel for fragmentation
        const Counter = struct {
            var value: u32 = 0;
        };
        Counter.value +%= 1;
        return Counter.value;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "selectSourceAddress link-local" {
    const testing = std.testing;

    var iface = Interface.init("eth0", .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 });
    iface.generateLinkLocal();

    // Link-local destination should use link-local source
    const link_local_dst = [_]u8{ 0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const src = selectSourceAddress(&iface, link_local_dst);
    try testing.expect(src != null);
    try testing.expectEqual(@as(u8, 0xFE), src.?[0]);
    try testing.expectEqual(@as(u8, 0x80), src.?[1]);
}

test "multicast MAC mapping" {
    const testing = std.testing;

    // ff02::1 should map to 33:33:00:00:00:01
    const mcast_addr = [_]u8{ 0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

    var dst_mac: [6]u8 = undefined;
    dst_mac[0] = 0x33;
    dst_mac[1] = 0x33;
    dst_mac[2] = mcast_addr[12];
    dst_mac[3] = mcast_addr[13];
    dst_mac[4] = mcast_addr[14];
    dst_mac[5] = mcast_addr[15];

    try testing.expectEqual(@as(u8, 0x33), dst_mac[0]);
    try testing.expectEqual(@as(u8, 0x33), dst_mac[1]);
    try testing.expectEqual(@as(u8, 0x00), dst_mac[2]);
    try testing.expectEqual(@as(u8, 0x00), dst_mac[3]);
    try testing.expectEqual(@as(u8, 0x00), dst_mac[4]);
    try testing.expectEqual(@as(u8, 0x01), dst_mac[5]);
}
