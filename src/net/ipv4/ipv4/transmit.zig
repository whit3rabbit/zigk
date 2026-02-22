const std = @import("std");
const packet = @import("../../core/packet.zig");
const interface = @import("../../core/interface.zig");
const checksum = @import("../../core/checksum.zig");
const ethernet = @import("../../ethernet/ethernet.zig");
const arp = @import("../arp/root.zig");
const pmtu = @import("../pmtu.zig");
const loopback = @import("../../drivers/loopback.zig");
const heap = @import("heap");
const types = @import("types.zig");
const utils = @import("utils.zig");
const id = @import("id.zig");

const PacketBuffer = packet.PacketBuffer;
const Ipv4Header = packet.Ipv4Header;
const Interface = interface.Interface;

/// Maximum IP payload size
const MAX_IP_PAYLOAD: usize = 65515;

/// Build an IPv4 packet header.
/// Assumes Ethernet header is already in place.
pub fn buildPacket(
    iface: *const Interface,
    pkt: *PacketBuffer,
    dst_ip: u32,
    protocol: u8,
    payload_len: usize,
) bool {
    return buildPacketWithTos(iface, pkt, dst_ip, protocol, payload_len, 0);
}

/// Build an IPv4 packet header with explicit ToS (Type of Service) value.
///
/// Sets up:
/// - Version (4) and IHL (5)
/// - Total Length
/// - Identification (from global counter)
/// - Flags (sets DF=0, MF=0)
/// - TTL (default 64)
/// - Protocol
/// - Checksum (calculated over header)
/// - Source and Destination IP
pub fn buildPacketWithTos(
    iface: *const Interface,
    pkt: *PacketBuffer,
    dst_ip: u32,
    protocol: u8,
    payload_len: usize,
    tos: u8,
) bool {
    pkt.ip_offset = packet.ETH_HEADER_SIZE;
    pkt.transport_offset = pkt.ip_offset + packet.IP_HEADER_SIZE;

    const ip_hdr = @as(*Ipv4Header, @ptrCast(@alignCast(&pkt.data[pkt.ip_offset])));

    ip_hdr.version_ihl = 0x45;
    ip_hdr.tos = tos;
    const total_len = std.math.add(usize, packet.IP_HEADER_SIZE, payload_len) catch return false;
    if (total_len > std.math.maxInt(u16)) return false;
    ip_hdr.setTotalLength(@intCast(total_len));
    ip_hdr.identification = @byteSwap(id.getNextId());
    ip_hdr.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip_hdr.ttl = types.DEFAULT_TTL;
    ip_hdr.protocol = protocol;
    ip_hdr.checksum = 0;

    ip_hdr.setSrcIp(iface.ip_addr);
    ip_hdr.setDstIp(dst_ip);

    const header_bytes = pkt.data[pkt.ip_offset..][0..packet.IP_HEADER_SIZE];
    ip_hdr.checksum = @byteSwap(checksum.ipChecksum(header_bytes));

    return true;
}

/// Send an IP packet.
///
/// Handles:
/// 1. Loopback routing if destination is 127.x.x.x.
/// 2. Next-hop resolution (Gateway vs Direct).
/// 3. ARP resolution for MAC address.
/// 4. Fragmentation if packet exceeds Interface MTU.
/// 5. Ethernet frame construction and transmission.
pub fn sendPacket(iface: *Interface, pkt: *PacketBuffer, dst_ip: u32) bool {
    // 1. Check for Loopback
    if (utils.isLoopback(dst_ip)) {
        if (loopback.getInterface()) |lo| {
            if (!ethernet.buildFrame(lo, pkt, [_]u8{0} ** 6, ethernet.ETHERTYPE_IPV4)) {
                return false;
            }
            const ip_hdr = pkt.ipHeaderUnsafe();
            pkt.len = pkt.ip_offset + ip_hdr.getTotalLength();
            return lo.transmit(pkt.data[0..pkt.len]);
        }
        return false;
    }

    // 2. Determine Next Hop
    const next_hop = iface.getGateway(dst_ip);
    var dst_mac: [6]u8 = [_]u8{0} ** 6;

    // 3. Resolve MAC Address
    if (utils.isBroadcast(dst_ip, iface.netmask) or dst_ip == 0xFFFFFFFF) {
        dst_mac = ethernet.BROADCAST_MAC;
    } else if (utils.isMulticast(dst_ip)) {
        // Map Multicast IP to Ethernet Multicast MAC (01:00:5E:xx:xx:xx)
        dst_mac[0] = 0x01;
        dst_mac[1] = 0x00;
        dst_mac[2] = 0x5E;
        dst_mac[3] = @truncate((dst_ip >> 16) & 0x7F);
        dst_mac[4] = @truncate((dst_ip >> 8) & 0xFF);
        dst_mac[5] = @truncate(dst_ip & 0xFF);
    } else {
        // Unicast: Resolve via ARP
        dst_mac = arp.resolveOrRequest(iface, next_hop, pkt) orelse {
            // ARP request sent, packet queued or dropped
            return true;
        };
    }

    if (!ethernet.buildFrame(iface, pkt, dst_mac, ethernet.ETHERTYPE_IPV4)) {
        return false;
    }

    const ip_hdr = pkt.ipHeaderUnsafe();
    const ip_total_len = ip_hdr.getTotalLength();
    pkt.len = pkt.ip_offset + ip_total_len;

    // 4. Check MTU and Fragment if needed
    if (ip_total_len > iface.mtu) {
        return sendFragmentedPacket(iface, pkt, dst_mac);
    }

    // 5. Transmit
    return ethernet.sendFrame(iface, pkt);
}

/// Send a packet fragmented into multiple IP datagrams.
///
/// Splits the payload into chunks that fit within the interface MTU.
/// Each fragment copies the original IP header but updates:
/// - Total Length: Size of this fragment (header + chunk).
/// - Flags: Sets MF (More Fragments) bit for all but the last fragment.
/// - Fragment Offset: Offset of this chunk in 8-byte units.
/// - Checksum: Recalculated for the new header.
fn sendFragmentedPacket(iface: *Interface, pkt: *PacketBuffer, dst_mac: [6]u8) bool {
    const orig_ip = pkt.ipHeaderUnsafe();
    const ip_header_len = orig_ip.getHeaderLength();

    if (@as(usize, iface.mtu) <= ip_header_len) return false;

    const payload_start = pkt.ip_offset + ip_header_len;
    const payload = pkt.data[payload_start..pkt.len];

    if (payload.len > MAX_IP_PAYLOAD) return false;
    
    // MTU payload must be multiple of 8 bytes for fragmentation
    const mtu_payload = (@as(usize, iface.mtu) - ip_header_len) & ~@as(usize, 7);

    // SECURITY: If MTU is too small to hold even 8 bytes of payload after
    // alignment, fragmentation is impossible. This prevents infinite loop
    // when mtu_payload rounds down to 0.
    if (mtu_payload == 0) return false;

    const alloc = heap.allocator();
    // Allocate temporary buffer for fragments
    const frag_buf = alloc.alloc(u8, packet.MAX_PACKET_SIZE) catch return false;
    // SECURITY: Zero-init to prevent kernel heap data leakage in network packets.
    // Per CLAUDE.md: "Prefer zero-init for security-sensitive buffers (network packets)."
    @memset(frag_buf, 0);
    // SECURITY NOTE (UAF concern reviewed 2024): This code assumes iface.transmit() is
    // synchronous and copies data before returning. All current drivers (e1000e, virtio-net)
    // satisfy this contract. The defer-free pattern is safe because:
    // 1. transmit() must complete the DMA or copy before returning
    // 2. No driver in this codebase holds buffer references after transmit() returns
    // If async zero-copy drivers are added, this must be refactored to use refcounted buffers.
    defer alloc.free(frag_buf);
    
    var offset: usize = 0;
    while (offset < payload.len) {
        const remaining = payload.len - offset;
        const chunk_len = @min(remaining, mtu_payload);
        const last_frag = (chunk_len == remaining);
        
        var frag_pkt = PacketBuffer.init(frag_buf, 0);

        if (!ethernet.buildFrame(iface, &frag_pkt, dst_mac, ethernet.ETHERTYPE_IPV4)) return false;

        const frag_ip_offset = packet.ETH_HEADER_SIZE;
        frag_pkt.ip_offset = frag_ip_offset;
        frag_pkt.transport_offset = frag_ip_offset + ip_header_len;
        
        // Copy original IP header
        const frag_ip: *align(1) Ipv4Header = @ptrCast(&frag_buf[frag_ip_offset]);
        frag_ip.* = orig_ip.*;
        
        // Update Total Length for this fragment
        const total_len = std.math.add(usize, ip_header_len, chunk_len) catch return false;
        if (total_len > std.math.maxInt(u16)) return false;
        frag_ip.setTotalLength(@intCast(total_len));
        
        // Update Fragment Offset and Flags
        // Offset is in 8-byte blocks
        const frag_off_val = (offset / 8);
        var flags = frag_off_val & 0x1FFF;
        if (!last_frag) flags |= 0x2000; // Set More Fragments (MF) bit
        frag_ip.flags_fragment = @byteSwap(@as(u16, @truncate(flags)));
        
        // Recalculate Checksum
        frag_ip.checksum = 0;
        const header_bytes = frag_buf[frag_ip_offset..][0..ip_header_len];
        frag_ip.checksum = @byteSwap(checksum.ipChecksum(header_bytes));
        
        // Copy Payload Chunk
        const payload_dest = frag_ip_offset + ip_header_len;
        @memcpy(frag_buf[payload_dest..][0..chunk_len], payload[offset..][0..chunk_len]);
        
        frag_pkt.len = payload_dest + chunk_len;
        
        if (!ethernet.sendFrame(iface, &frag_pkt)) return false;
        
        offset += chunk_len;
    }
    
    return true;
}
