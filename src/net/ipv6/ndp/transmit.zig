// NDP Packet Transmission (TX Path)
//
// Implements RFC 4861 transmit functions for Neighbor Discovery.
//
// Functions:
// - sendNeighborSolicitation: Address resolution and DAD (RFC 4861 Section 7.2.2)
// - sendNeighborAdvertisement: Response to NS (RFC 4861 Section 7.2.4)
// - sendRouterSolicitation: Request router info (RFC 4861 Section 6.3.7)

const std = @import("std");
const packet = @import("../../core/packet.zig");
const interface = @import("../../core/interface.zig");
const checksum = @import("../../core/checksum.zig");
const ethernet = @import("../../ethernet/ethernet.zig");
const types = @import("types.zig");
const cache = @import("cache.zig");
const ipv6_types = @import("../ipv6/types.zig");
const icmpv6_types = @import("../icmpv6/types.zig");
const net_pool = @import("../../core/pool.zig");

const PacketBuffer = packet.PacketBuffer;
const Ipv6Header = packet.Ipv6Header;
const Interface = interface.Interface;

/// NDP messages require Hop Limit = 255 (link-local only)
const NDP_HOP_LIMIT: u8 = 255;

// =============================================================================
// Neighbor Solicitation
// =============================================================================

/// Send a Neighbor Solicitation for address resolution.
///
/// RFC 4861 Section 7.2.2:
/// - Source: Link-local address of interface (or :: for DAD)
/// - Destination: Solicited-node multicast of target
/// - Target: Address being resolved
/// - Includes Source Link-Layer Address option (unless DAD)
pub fn sendNeighborSolicitation(iface: *Interface, target_addr: [16]u8) bool {
    return sendNs(iface, target_addr, false);
}

/// Send a Neighbor Solicitation for DAD (Duplicate Address Detection).
///
/// RFC 4861 Section 5.4.2:
/// - Source: Unspecified address (::)
/// - Destination: Solicited-node multicast of target
/// - Target: Address being tested
/// - No Source Link-Layer Address option
pub fn sendNeighborSolicitationDad(iface: *Interface, tentative_addr: [16]u8) bool {
    return sendNs(iface, tentative_addr, true);
}

/// Internal NS sender
fn sendNs(iface: *Interface, target_addr: [16]u8, is_dad: bool) bool {
    // Allocate TX buffer
    const buf = net_pool.allocTxBuffer() orelse return false;
    defer net_pool.freeTxBuffer(buf);

    // Calculate sizes
    const eth_len = packet.ETH_HEADER_SIZE;
    const ipv6_len = packet.IPV6_HEADER_SIZE;
    const icmpv6_hdr_len = icmpv6_types.ICMPV6_HEADER_SIZE;
    const ns_hdr_len = @sizeOf(types.NeighborSolicitationHeader);
    const slla_len: usize = if (is_dad) 0 else types.LINK_ADDR_OPTION_SIZE;
    const icmpv6_len = icmpv6_hdr_len + ns_hdr_len + slla_len;
    const total_len = eth_len + ipv6_len + icmpv6_len;

    if (total_len > buf.len) return false;

    // Source address: link-local or unspecified for DAD
    const src_addr: [16]u8 = if (is_dad)
        ipv6_types.UNSPECIFIED_ADDR
    else if (iface.has_link_local)
        iface.link_local_addr
    else
        return false;

    // Destination: solicited-node multicast of target
    const dst_addr = types.computeSolicitedNodeMulticast(target_addr);

    // Destination MAC: multicast mapping (33:33:XX:XX:XX:XX)
    const dst_mac = ipv6_types.multicastToMac(dst_addr);

    // Build Ethernet header
    const eth: *packet.EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[eth_len]));
    ip6.* = std.mem.zeroes(Ipv6Header);
    ip6.setVersionTcFlow(6, 0, 0);
    ip6.setPayloadLength(@intCast(icmpv6_len));
    ip6.next_header = ipv6_types.PROTO_ICMPV6;
    ip6.hop_limit = NDP_HOP_LIMIT;
    ip6.src_addr = src_addr;
    ip6.dst_addr = dst_addr;

    // Build ICMPv6 header
    const icmpv6_offset = eth_len + ipv6_len;
    buf[icmpv6_offset] = types.TYPE_NEIGHBOR_SOLICITATION;
    buf[icmpv6_offset + 1] = 0; // Code
    buf[icmpv6_offset + 2] = 0; // Checksum (computed later)
    buf[icmpv6_offset + 3] = 0;

    // Build NS header
    const ns_offset = icmpv6_offset + icmpv6_hdr_len;
    const ns: *types.NeighborSolicitationHeader = @ptrCast(@alignCast(&buf[ns_offset]));
    ns.reserved = 0;
    ns.target_addr = target_addr;

    // Add Source Link-Layer Address option (unless DAD)
    if (!is_dad) {
        const opt_offset = ns_offset + ns_hdr_len;
        const slla: *types.LinkLayerAddressOption = @ptrCast(@alignCast(&buf[opt_offset]));
        slla.opt_type = types.OPT_SOURCE_LINK_ADDR;
        slla.length = 1; // 8 bytes
        @memcpy(&slla.addr, &iface.mac_addr);
    }

    // Calculate ICMPv6 checksum
    const icmpv6_data = buf[icmpv6_offset..][0..icmpv6_len];
    const cksum = checksum.icmpv6Checksum(src_addr, dst_addr, icmpv6_data);
    buf[icmpv6_offset + 2] = @truncate(cksum >> 8);
    buf[icmpv6_offset + 3] = @truncate(cksum);

    // Transmit
    return iface.transmit(buf[0..total_len]);
}

// =============================================================================
// Neighbor Advertisement
// =============================================================================

/// Send a Neighbor Advertisement in response to a Neighbor Solicitation.
///
/// RFC 4861 Section 7.2.4:
/// - Source: Address being advertised (target from NS)
/// - Destination: Source of NS (or all-nodes multicast for unsolicited)
/// - Flags: Router, Solicited, Override
/// - Includes Target Link-Layer Address option
pub fn sendNeighborAdvertisement(
    iface: *Interface,
    advertised_addr: [16]u8,
    dst_addr: [16]u8,
    solicited: bool,
    override: bool,
) bool {
    // Allocate TX buffer
    const buf = net_pool.allocTxBuffer() orelse return false;
    defer net_pool.freeTxBuffer(buf);

    // Calculate sizes
    const eth_len = packet.ETH_HEADER_SIZE;
    const ipv6_len = packet.IPV6_HEADER_SIZE;
    const icmpv6_hdr_len = icmpv6_types.ICMPV6_HEADER_SIZE;
    const na_hdr_len = @sizeOf(types.NeighborAdvertisementHeader);
    const tlla_len = types.LINK_ADDR_OPTION_SIZE;
    const icmpv6_len = icmpv6_hdr_len + na_hdr_len + tlla_len;
    const total_len = eth_len + ipv6_len + icmpv6_len;

    if (total_len > buf.len) return false;

    // Source address is the address being advertised
    const src_addr = advertised_addr;

    // Determine destination MAC
    var dst_mac: [6]u8 = undefined;
    if (ipv6_types.isMulticast(dst_addr)) {
        dst_mac = ipv6_types.multicastToMac(dst_addr);
    } else {
        // For unicast, need to resolve or use solicited-node multicast
        // In practice, the NS source MAC should be cached
        if (cache.lookup(dst_addr)) |mac| {
            dst_mac = mac;
        } else {
            // Fall back to solicited-node multicast
            const snm = types.computeSolicitedNodeMulticast(dst_addr);
            dst_mac = ipv6_types.multicastToMac(snm);
        }
    }

    // Build Ethernet header
    const eth: *packet.EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[eth_len]));
    ip6.* = std.mem.zeroes(Ipv6Header);
    ip6.setVersionTcFlow(6, 0, 0);
    ip6.setPayloadLength(@intCast(icmpv6_len));
    ip6.next_header = ipv6_types.PROTO_ICMPV6;
    ip6.hop_limit = NDP_HOP_LIMIT;
    ip6.src_addr = src_addr;
    ip6.dst_addr = dst_addr;

    // Build ICMPv6 header
    const icmpv6_offset = eth_len + ipv6_len;
    buf[icmpv6_offset] = types.TYPE_NEIGHBOR_ADVERTISEMENT;
    buf[icmpv6_offset + 1] = 0; // Code
    buf[icmpv6_offset + 2] = 0; // Checksum
    buf[icmpv6_offset + 3] = 0;

    // Build NA header
    const na_offset = icmpv6_offset + icmpv6_hdr_len;
    const na: *types.NeighborAdvertisementHeader = @ptrCast(@alignCast(&buf[na_offset]));
    na.setFlags(false, solicited, override); // Router flag = false (we're not a router)
    na.target_addr = advertised_addr;

    // Add Target Link-Layer Address option
    const opt_offset = na_offset + na_hdr_len;
    const tlla: *types.LinkLayerAddressOption = @ptrCast(@alignCast(&buf[opt_offset]));
    tlla.opt_type = types.OPT_TARGET_LINK_ADDR;
    tlla.length = 1; // 8 bytes
    @memcpy(&tlla.addr, &iface.mac_addr);

    // Calculate ICMPv6 checksum
    const icmpv6_data = buf[icmpv6_offset..][0..icmpv6_len];
    const cksum = checksum.icmpv6Checksum(src_addr, dst_addr, icmpv6_data);
    buf[icmpv6_offset + 2] = @truncate(cksum >> 8);
    buf[icmpv6_offset + 3] = @truncate(cksum);

    // Transmit
    return iface.transmit(buf[0..total_len]);
}

// =============================================================================
// Router Solicitation
// =============================================================================

/// Send a Router Solicitation to discover routers.
///
/// RFC 4861 Section 6.3.7:
/// - Source: Link-local address or unspecified
/// - Destination: All-routers multicast (ff02::2)
/// - Includes Source Link-Layer Address option if source is not unspecified
pub fn sendRouterSolicitation(iface: *Interface) bool {
    // Allocate TX buffer
    const buf = net_pool.allocTxBuffer() orelse return false;
    defer net_pool.freeTxBuffer(buf);

    // Calculate sizes
    const eth_len = packet.ETH_HEADER_SIZE;
    const ipv6_len = packet.IPV6_HEADER_SIZE;
    const icmpv6_hdr_len = icmpv6_types.ICMPV6_HEADER_SIZE;
    const rs_hdr_len = @sizeOf(types.RouterSolicitationHeader);
    const has_link_local = iface.has_link_local;
    const slla_len: usize = if (has_link_local) types.LINK_ADDR_OPTION_SIZE else 0;
    const icmpv6_len = icmpv6_hdr_len + rs_hdr_len + slla_len;
    const total_len = eth_len + ipv6_len + icmpv6_len;

    if (total_len > buf.len) return false;

    // Source: link-local if available, else unspecified
    const src_addr: [16]u8 = if (has_link_local)
        iface.link_local_addr
    else
        ipv6_types.UNSPECIFIED_ADDR;

    // Destination: all-routers multicast (ff02::2)
    const dst_addr = ipv6_types.ALL_ROUTERS_MULTICAST;

    // Destination MAC: multicast mapping
    const dst_mac = ipv6_types.multicastToMac(dst_addr);

    // Build Ethernet header
    const eth: *packet.EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[eth_len]));
    ip6.* = std.mem.zeroes(Ipv6Header);
    ip6.setVersionTcFlow(6, 0, 0);
    ip6.setPayloadLength(@intCast(icmpv6_len));
    ip6.next_header = ipv6_types.PROTO_ICMPV6;
    ip6.hop_limit = NDP_HOP_LIMIT;
    ip6.src_addr = src_addr;
    ip6.dst_addr = dst_addr;

    // Build ICMPv6 header
    const icmpv6_offset = eth_len + ipv6_len;
    buf[icmpv6_offset] = types.TYPE_ROUTER_SOLICITATION;
    buf[icmpv6_offset + 1] = 0; // Code
    buf[icmpv6_offset + 2] = 0; // Checksum
    buf[icmpv6_offset + 3] = 0;

    // Build RS header
    const rs_offset = icmpv6_offset + icmpv6_hdr_len;
    const rs: *types.RouterSolicitationHeader = @ptrCast(@alignCast(&buf[rs_offset]));
    rs.reserved = 0;

    // Add Source Link-Layer Address option if we have a source address
    if (has_link_local) {
        const opt_offset = rs_offset + rs_hdr_len;
        const slla: *types.LinkLayerAddressOption = @ptrCast(@alignCast(&buf[opt_offset]));
        slla.opt_type = types.OPT_SOURCE_LINK_ADDR;
        slla.length = 1; // 8 bytes
        @memcpy(&slla.addr, &iface.mac_addr);
    }

    // Calculate ICMPv6 checksum
    const icmpv6_data = buf[icmpv6_offset..][0..icmpv6_len];
    const cksum = checksum.icmpv6Checksum(src_addr, dst_addr, icmpv6_data);
    buf[icmpv6_offset + 2] = @truncate(cksum >> 8);
    buf[icmpv6_offset + 3] = @truncate(cksum);

    // Transmit
    return iface.transmit(buf[0..total_len]);
}

// =============================================================================
// Address Resolution
// =============================================================================

/// Resolve an IPv6 address to a MAC address.
/// If not in cache, sends Neighbor Solicitation and returns null.
/// Caller should queue the packet for later transmission.
pub fn resolveOrRequest(iface: *Interface, target_addr: [16]u8, pkt_data: ?[]const u8) ?[6]u8 {
    // Check cache first
    if (cache.lookup(target_addr)) |mac| {
        return mac;
    }

    // Multicast addresses map directly to Ethernet multicast
    if (ipv6_types.isMulticast(target_addr)) {
        return ipv6_types.multicastToMac(target_addr);
    }

    // Create incomplete entry and queue packet
    {
        const held = cache.lock.acquire();
        defer held.release();

        const entry = cache.createIncompleteEntry(target_addr) catch return null;

        if (pkt_data) |data| {
            _ = cache.queuePacket(entry, data);
        }
    }

    // Send Neighbor Solicitation
    _ = sendNeighborSolicitation(iface, target_addr);

    return null;
}

/// Perform Duplicate Address Detection for an address.
/// Returns true if NS was sent successfully.
/// Caller should wait for NA or timeout to determine uniqueness.
pub fn performDad(iface: *Interface, addr: [16]u8) bool {
    return sendNeighborSolicitationDad(iface, addr);
}
