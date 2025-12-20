const c = @import("../constants.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const options = @import("../options.zig");
const segment = @import("segment.zig");
const data_mod = @import("data.zig");
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

/// Send a SYN segment (initiating connection) - legacy without options
pub fn sendSyn(tcb: *Tcb) bool {
    const iface = state.global_iface orelse return false;

    const next_hop = iface.getGateway(tcb.remote_ip);
    const resolved_mac = arp.resolve(next_hop);
    const have_mac = resolved_mac != null;
    var dst_mac = resolved_mac orelse [_]u8{ 0, 0, 0, 0, 0, 0 };

    var options_buf: [c.TCP_MAX_OPTIONS_SIZE]u8 = undefined;
    const options_len = options.buildSynOptions(&options_buf, tcb, false, null);

    const tcp_header_len = c.TCP_HEADER_SIZE + options_len;
    const tcp_len = tcp_header_len;
    const ip_len = packet.IP_HEADER_SIZE + tcp_len;
    if (ip_len > 65535) return false;
    const total_len = packet.ETH_HEADER_SIZE + ip_len;

    const buf = state.allocTxBuffer() orelse return false;
    defer state.freeTxBuffer(buf);

    if (total_len > buf.len) return false;

    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    const ip: *Ipv4Header = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    ip.version_ihl = 0x45;
    ip.tos = tcb.tos;
    ip.setTotalLength(@intCast(ip_len));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_TCP;
    ip.checksum = 0;
    ip.setSrcIp(tcb.local_ip);
    ip.setDstIp(tcb.remote_ip);
    ip.checksum = checksum.ipChecksum(buf[packet.ETH_HEADER_SIZE..][0..packet.IP_HEADER_SIZE]);

    const tcp_offset = packet.ETH_HEADER_SIZE + packet.IP_HEADER_SIZE;
    const tcp_hdr: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_offset]));
    tcp_hdr.setSrcPort(tcb.local_port);
    tcp_hdr.setDstPort(tcb.remote_port);
    tcp_hdr.setSeqNum(tcb.iss);
    tcp_hdr.setAckNum(0);
    const data_offset_words: u4 = @intCast(tcp_header_len / 4);
    tcp_hdr.setDataOffsetFlags(data_offset_words, TcpHeader.FLAG_SYN);
    tcp_hdr.setWindow(tcb.currentRecvWindow());
    tcp_hdr.checksum = 0;
    tcp_hdr.urgent_ptr = 0;

    if (options_len > 0) {
        @memcpy(buf[tcp_offset + c.TCP_HEADER_SIZE ..][0..options_len], options_buf[0..options_len]);
    }

    const tcp_segment = buf[tcp_offset..][0..tcp_len];
    tcp_hdr.checksum = checksum.tcpChecksum(ip.src_ip, ip.dst_ip, tcp_segment);

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

pub fn sendSynAckWithOptions(tcb: *Tcb, peer_opts: ?*const options.TcpOptions) bool {
    const iface = state.global_iface orelse return false;

    const next_hop = iface.getGateway(tcb.remote_ip);
    const resolved_mac = arp.resolve(next_hop);
    const have_mac = resolved_mac != null;
    var dst_mac = resolved_mac orelse [_]u8{ 0, 0, 0, 0, 0, 0 };

    var options_buf: [c.TCP_MAX_OPTIONS_SIZE]u8 = undefined;
    const options_len = options.buildSynOptions(&options_buf, tcb, true, peer_opts);

    const tcp_header_len = c.TCP_HEADER_SIZE + options_len;
    const tcp_len = tcp_header_len;
    const ip_len = packet.IP_HEADER_SIZE + tcp_len;
    if (ip_len > 65535) return false;
    const total_len = packet.ETH_HEADER_SIZE + ip_len;

    const buf = state.allocTxBuffer() orelse return false;
    defer state.freeTxBuffer(buf);

    if (total_len > buf.len) return false;

    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    const ip: *Ipv4Header = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    ip.version_ihl = 0x45;
    ip.tos = tcb.tos;
    ip.setTotalLength(@intCast(ip_len));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_TCP;
    ip.checksum = 0;
    ip.setSrcIp(tcb.local_ip);
    ip.setDstIp(tcb.remote_ip);
    ip.checksum = checksum.ipChecksum(buf[packet.ETH_HEADER_SIZE..][0..packet.IP_HEADER_SIZE]);

    const tcp_offset = packet.ETH_HEADER_SIZE + packet.IP_HEADER_SIZE;
    const tcp_hdr: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_offset]));
    tcp_hdr.setSrcPort(tcb.local_port);
    tcp_hdr.setDstPort(tcb.remote_port);
    tcp_hdr.setSeqNum(tcb.iss);
    tcp_hdr.setAckNum(tcb.rcv_nxt);
    const data_offset_words: u4 = @intCast(tcp_header_len / 4);
    tcp_hdr.setDataOffsetFlags(data_offset_words, TcpHeader.FLAG_SYN | TcpHeader.FLAG_ACK);
    tcp_hdr.setWindow(tcb.currentRecvWindow());
    tcp_hdr.checksum = 0;
    tcp_hdr.urgent_ptr = 0;

    if (options_len > 0) {
        @memcpy(buf[tcp_offset + c.TCP_HEADER_SIZE ..][0..options_len], options_buf[0..options_len]);
    }

    const tcp_segment = buf[tcp_offset..][0..tcp_len];
    tcp_hdr.checksum = checksum.tcpChecksum(ip.src_ip, ip.dst_ip, tcp_segment);

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

pub fn sendAck(tcb: *Tcb) bool {
    return segment.sendSegment(tcb, TcpHeader.FLAG_ACK, tcb.snd_nxt, tcb.rcv_nxt, null);
}

pub fn sendFin(tcb: *Tcb) bool {
    return segment.sendSegment(
        tcb,
        TcpHeader.FLAG_FIN | TcpHeader.FLAG_ACK,
        tcb.snd_nxt,
        tcb.rcv_nxt,
        null,
    );
}

pub fn sendRst(tcb: *Tcb) bool {
    return segment.sendSegment(tcb, TcpHeader.FLAG_RST, tcb.snd_nxt, 0, null);
}

pub fn sendRstForPacket(iface: *interface.Interface, pkt: *const PacketBuffer, tcp_hdr: *const TcpHeader) bool {
    const ip_hdr = pkt.ipHeader();

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) return true;

    const next_hop = iface.getGateway(ip_hdr.getSrcIp());
    const dst_mac = arp.resolveOrRequest(iface, next_hop, null) orelse return false;

    const buf = state.allocTxBuffer() orelse return false;
    defer state.freeTxBuffer(buf);

    const total_len = packet.ETH_HEADER_SIZE + packet.IP_HEADER_SIZE + c.TCP_HEADER_SIZE;

    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    const ip: *Ipv4Header = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    ip.version_ihl = 0x45;
    ip.tos = 0;
    ip.setTotalLength(@intCast(packet.IP_HEADER_SIZE + c.TCP_HEADER_SIZE));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_TCP;
    ip.checksum = 0;
    ip.setSrcIp(ip_hdr.getDstIp());
    ip.setDstIp(ip_hdr.getSrcIp());
    ip.checksum = checksum.ipChecksum(buf[packet.ETH_HEADER_SIZE..][0..packet.IP_HEADER_SIZE]);

    const tcp_offset = packet.ETH_HEADER_SIZE + packet.IP_HEADER_SIZE;
    const tcp: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_offset]));
    tcp.setSrcPort(tcp_hdr.getDstPort());
    tcp.setDstPort(tcp_hdr.getSrcPort());

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        tcp.setSeqNum(tcp_hdr.getAckNum());
        tcp.setAckNum(0);
        tcp.setDataOffsetFlags(5, TcpHeader.FLAG_RST);
    } else {
        tcp.setSeqNum(0);
        const seg_len = data_mod.calculateSegmentLength(pkt, tcp_hdr);
        tcp.setAckNum(tcp_hdr.getSeqNum() +% seg_len);
        tcp.setDataOffsetFlags(5, TcpHeader.FLAG_RST | TcpHeader.FLAG_ACK);
    }

    tcp.setWindow(0);
    tcp.checksum = 0;
    tcp.urgent_ptr = 0;

    const tcp_segment = buf[tcp_offset..][0..c.TCP_HEADER_SIZE];
    tcp.checksum = checksum.tcpChecksum(ip.src_ip, ip.dst_ip, tcp_segment);

    return iface.transmit(buf[0..total_len]);
}
