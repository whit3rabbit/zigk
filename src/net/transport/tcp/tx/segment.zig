const c = @import("../constants.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const packet = @import("../../../core/packet.zig");
const interface = @import("../../../core/interface.zig");
const checksum = @import("../../../core/checksum.zig");
const ipv4 = @import("../../../ipv4/root.zig").ipv4;
const ethernet = @import("../../../ethernet/ethernet.zig");
const arp = @import("../../../ipv4/root.zig").arp;

const PacketBuffer = packet.PacketBuffer;
const Ipv4Header = packet.Ipv4Header;
const EthernetHeader = packet.EthernetHeader;
const TcpHeader = types.TcpHeader;
const Tcb = types.Tcb;

/// Send a TCP segment
pub fn sendSegment(
    tcb: *Tcb,
    flags: u16,
    seq: u32,
    ack: u32,
    data: ?[]const u8,
) bool {
    const iface = state.global_iface orelse return false;

    // Resolve destination MAC (single atomic lookup to avoid TOCTOU race)
    const next_hop = iface.getGateway(tcb.remote_ip);
    const resolved_mac = arp.resolve(next_hop);
    const have_mac = resolved_mac != null;
    var dst_mac = resolved_mac orelse [_]u8{ 0, 0, 0, 0, 0, 0 };

    // Calculate sizes with validation
    const tcp_data_len: usize = if (data) |d| blk: {
        if (d.len > c.MAX_TCP_PAYLOAD) return false; // Reject oversized payload
        break :blk d.len;
    } else 0;
    const tcp_len = c.TCP_HEADER_SIZE + tcp_data_len;
    const ip_len = packet.IP_HEADER_SIZE + tcp_len;
    // IP total length must fit in u16 (max 65535)
    if (ip_len > 65535) return false;
    const total_len = packet.ETH_HEADER_SIZE + ip_len;

    // Use static buffer pool to avoid heap pressure
    const buf = state.allocTxBuffer() orelse return false;
    defer state.freeTxBuffer(buf);

    if (total_len > buf.len) return false;

    // Build Ethernet header
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    // Build IP header
    const ip: *Ipv4Header = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    ip.version_ihl = 0x45;
    ip.tos = tcb.tos; // Use socket's ToS/DSCP value
    ip.setTotalLength(@intCast(ip_len)); // Safe: validated ip_len <= 65535 above
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000)); // Don't Fragment
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_TCP;
    ip.checksum = 0;
    ip.setSrcIp(tcb.local_ip);
    ip.setDstIp(tcb.remote_ip);
    ip.checksum = checksum.ipChecksum(buf[packet.ETH_HEADER_SIZE..][0..packet.IP_HEADER_SIZE]);

    // Build TCP header
    const tcp_offset = packet.ETH_HEADER_SIZE + packet.IP_HEADER_SIZE;
    const tcp: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_offset]));
    tcp.setSrcPort(tcb.local_port);
    tcp.setDstPort(tcb.remote_port);
    tcp.setSeqNum(seq);
    tcp.setAckNum(ack);
    tcp.setDataOffsetFlags(5, flags); // 5 words = 20 bytes, no options
    tcp.setWindow(tcb.currentRecvWindow());
    tcp.checksum = 0;
    tcp.urgent_ptr = 0;

    // Copy payload data
    if (data) |d| {
        @memcpy(buf[tcp_offset + c.TCP_HEADER_SIZE ..][0..d.len], d);
    }

    // Calculate TCP checksum
    const tcp_segment = buf[tcp_offset..][0..tcp_len];
    tcp.checksum = checksum.tcpChecksum(ip.src_ip, ip.dst_ip, tcp_segment);

    // Transmit or Queue
    if (have_mac) {
        return iface.transmit(buf[0..total_len]);
    } else {
        var pkt = PacketBuffer.init(buf[0..total_len], total_len);
        pkt.eth_offset = 0;
        pkt.ip_offset = packet.ETH_HEADER_SIZE;
        pkt.transport_offset = tcp_offset;

        if (arp.resolveOrRequest(iface, next_hop, &pkt)) |mac| {
            @memcpy(&eth.dst_mac, &mac);
            _ = iface.transmit(buf[0..total_len]);
            return true;
        }
        return true;
    }
}
