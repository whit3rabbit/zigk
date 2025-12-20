const std = @import("std");
const packet = @import("../../core/packet.zig");
const interface = @import("../../core/interface.zig");
const checksum = @import("../../core/checksum.zig");
const ethernet = @import("../../ethernet/ethernet.zig");
const arp = @import("../arp/root.zig");
const pmtu = @import("../pmtu.zig");
const reassembly = @import("../reassembly.zig");
const platform = @import("platform");
const types = @import("types.zig");
const validation = @import("validation.zig");
const utils = @import("utils.zig");

// Forward declarations for transport protocols
const icmp = @import("../../transport/icmp.zig");
const udp = @import("../../transport/udp.zig");
const tcp = @import("../../transport/tcp.zig");

const PacketBuffer = packet.PacketBuffer;
const Ipv4Header = packet.Ipv4Header;
const Interface = interface.Interface;

/// Process an incoming IPv4 packet
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    const ip = packet.getIpv4HeaderMut(pkt.data, pkt.ip_offset) orelse return false;

    if (ip.getVersion() != 4) return false;

    const ihl = ip.version_ihl & 0x0F;
    if (ihl < 5) return false;

    const header_len = @as(usize, ihl) * 4;

    if (pkt.ip_offset + header_len > pkt.len) return false;

    if (!validation.validateOptions(pkt, header_len)) return false;

    const header_bytes = pkt.data[pkt.ip_offset..][0..header_len];
    if (!checksum.verifyIpChecksum(header_bytes)) return false;

    const total_len = ip.getTotalLength();
    if (total_len < header_len or pkt.ip_offset + total_len > pkt.len) return false;

    const payload_len = total_len - header_len;
    if (payload_len == 0) return false;

    pkt.len = pkt.ip_offset + total_len;

    const dst_ip = ip.getDstIp();
    pkt.dst_ip = dst_ip;
    pkt.src_ip = ip.getSrcIp();

    if (dst_ip == iface.ip_addr) {
        pkt.is_broadcast = false;
        pkt.is_multicast = false;
    } else if (dst_ip == 0xFFFFFFFF) {
        pkt.is_broadcast = true;
        pkt.is_multicast = false;
    } else if (utils.isBroadcast(dst_ip, iface.netmask)) {
        pkt.is_broadcast = true;
        pkt.is_multicast = false;
    } else if (utils.isMulticast(dst_ip)) {
        pkt.is_broadcast = false;
        pkt.is_multicast = true;
    } else {
        return false;
    }

    const flags_frag = @byteSwap(ip.flags_fragment);
    const mf_bit = (flags_frag >> 13) & 0x1;
    const frag_offset = flags_frag & 0x1FFF;

    var payload_slice: []u8 = &[_]u8{};
    var is_reassembled = false;
    var reassembly_result: ?reassembly.ReassemblyResult = null;

    if (mf_bit != 0 or frag_offset != 0) {
        const current_payload = pkt.data[pkt.ip_offset + header_len..][0..payload_len];

        if (reassembly.processFragment(
            ip.getSrcIp(),
            ip.getDstIp(),
            ip.protocol,
            @byteSwap(ip.identification),
            frag_offset,
            mf_bit != 0,
            current_payload
        )) |res| {
            reassembly_result = res;
            payload_slice = res.payload();
            is_reassembled = true;
        } else {
            return true;
        }
    } else {
        payload_slice = pkt.data[pkt.ip_offset + header_len..][0..payload_len];
    }

    if (is_reassembled) {
        var result = reassembly_result.?;
        defer result.deinit();

        var virt_pkt = PacketBuffer.init(result.owned_buffer, result.payload_len);

        virt_pkt.src_ip = pkt.src_ip;
        virt_pkt.dst_ip = pkt.dst_ip;
        virt_pkt.src_port = pkt.src_port;
        virt_pkt.ip_protocol = ip.protocol;

        virt_pkt.eth_offset = 0;
        virt_pkt.ip_offset = 0;
        virt_pkt.transport_offset = 0;

        const min_size: usize = switch (ip.protocol) {
            types.PROTO_ICMP => types.ICMP_HEADER_MIN,
            types.PROTO_UDP => types.UDP_HEADER_MIN,
            types.PROTO_TCP => types.TCP_HEADER_MIN,
            else => 0,
        };

        if (result.payload_len < min_size) return false;

        return switch (ip.protocol) {
            types.PROTO_ICMP => icmp.processPacket(iface, &virt_pkt),
            types.PROTO_UDP => udp.processPacket(iface, &virt_pkt),
            types.PROTO_TCP => tcp.processPacket(iface, &virt_pkt),
            else => false,
        };
    }

    pkt.transport_offset = pkt.ip_offset + header_len;
    pkt.ip_protocol = ip.protocol;
    
    switch (ip.protocol) {
        types.PROTO_ICMP => return icmp.processPacket(iface, pkt),
        types.PROTO_UDP => return udp.processPacket(iface, pkt),
        types.PROTO_TCP => return tcp.processPacket(iface, pkt),
        else => return false,
    }
}

/// Decrement TTL and update checksum
pub fn decrementTtl(pkt: *PacketBuffer) bool {
    const ip = packet.getIpv4HeaderMut(pkt.data, pkt.ip_offset) orelse return false;

    if (ip.ttl <= 1) return false;

    const old_ttl = ip.ttl;
    ip.ttl -= 1;

    const old_value = (@as(u16, old_ttl) << 8) | ip.protocol;
    const new_value = (@as(u16, ip.ttl) << 8) | ip.protocol;
    ip.checksum = checksum.updateChecksum(ip.checksum, old_value, new_value);

    return true;
}
