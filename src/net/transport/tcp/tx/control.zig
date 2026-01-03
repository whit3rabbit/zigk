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

// IPv6 imports for dual-stack support
const ipv6_mod = @import("../../../ipv6/root.zig");
const ipv6_types = ipv6_mod.ipv6.types;
const ndp = ipv6_mod.ndp;
const addr_mod = @import("../../../core/addr.zig");

const PacketBuffer = packet.PacketBuffer;
const Ipv4Header = packet.Ipv4Header;
const Ipv6Header = packet.Ipv6Header;
const EthernetHeader = packet.EthernetHeader;
const TcpHeader = types.TcpHeader;
const Tcb = types.Tcb;

/// Send a SYN segment (initiating connection) - legacy without options
pub fn sendSyn(tcb: *Tcb) bool {
    // Branch based on address family
    if (tcb.isIpv6()) {
        return sendSyn6(tcb);
    }

    const iface = state.global_iface orelse return false;

    const next_hop = iface.getGateway(tcb.getRemoteIpV4());
    const resolved_mac = arp.resolve(next_hop);
    const have_mac = resolved_mac != null;
    var dst_mac = resolved_mac orelse [_]u8{ 0, 0, 0, 0, 0, 0 };

    // SECURITY: Zero-initialize options buffer to prevent kernel stack data
    // from leaking into network packets via padding bytes (CLAUDE.md guideline).
    var options_buf: [c.TCP_MAX_OPTIONS_SIZE]u8 = [_]u8{0} ** c.TCP_MAX_OPTIONS_SIZE;
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
    ip.setSrcIp(tcb.getLocalIpV4());
    ip.setDstIp(tcb.getRemoteIpV4());
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
    // Branch based on address family
    if (tcb.isIpv6()) {
        return sendSynAckWithOptions6(tcb, peer_opts);
    }

    const iface = state.global_iface orelse return false;

    const next_hop = iface.getGateway(tcb.getRemoteIpV4());
    const resolved_mac = arp.resolve(next_hop);
    const have_mac = resolved_mac != null;
    var dst_mac = resolved_mac orelse [_]u8{ 0, 0, 0, 0, 0, 0 };

    // SECURITY: Zero-initialize options buffer to prevent kernel stack data
    // from leaking into network packets via padding bytes (CLAUDE.md guideline).
    var options_buf: [c.TCP_MAX_OPTIONS_SIZE]u8 = [_]u8{0} ** c.TCP_MAX_OPTIONS_SIZE;
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
    ip.setSrcIp(tcb.getLocalIpV4());
    ip.setDstIp(tcb.getRemoteIpV4());
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
    tcb.ack_pending = false;
    tcb.ack_due = 0;
    if (tcb.sack_ok and tcb.rcv_sack_block_count > 0) {
        return sendAckWithOptions(tcb);
    }
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
    const ip_hdr = pkt.ipHeaderUnsafe();

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

fn sendAckWithOptions(tcb: *Tcb) bool {
    // Branch based on address family
    if (tcb.isIpv6()) {
        return sendAckWithOptions6(tcb);
    }

    const iface = state.global_iface orelse return false;

    const next_hop = iface.getGateway(tcb.getRemoteIpV4());
    const resolved_mac = arp.resolve(next_hop);
    const have_mac = resolved_mac != null;
    var dst_mac = resolved_mac orelse [_]u8{ 0, 0, 0, 0, 0, 0 };

    // SECURITY: Zero-initialize options buffer to prevent kernel stack data
    // from leaking into network packets via padding bytes (CLAUDE.md guideline).
    var options_buf: [c.TCP_MAX_OPTIONS_SIZE]u8 = [_]u8{0} ** c.TCP_MAX_OPTIONS_SIZE;
    const options_len = options.buildSackOptions(&options_buf, tcb);

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
    ip.setSrcIp(tcb.getLocalIpV4());
    ip.setDstIp(tcb.getRemoteIpV4());
    ip.checksum = checksum.ipChecksum(buf[packet.ETH_HEADER_SIZE..][0..packet.IP_HEADER_SIZE]);

    const tcp_offset = packet.ETH_HEADER_SIZE + packet.IP_HEADER_SIZE;
    const tcp_hdr: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_offset]));
    tcp_hdr.setSrcPort(tcb.local_port);
    tcp_hdr.setDstPort(tcb.remote_port);
    tcp_hdr.setSeqNum(tcb.snd_nxt);
    tcp_hdr.setAckNum(tcb.rcv_nxt);
    const data_offset_words: u4 = @intCast(tcp_header_len / 4);
    tcp_hdr.setDataOffsetFlags(data_offset_words, TcpHeader.FLAG_ACK);
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

// =============================================================================
// IPv6 Control Segment Functions
// =============================================================================

/// Send a SYN segment over IPv6 (initiating connection)
fn sendSyn6(tcb: *Tcb) bool {
    const iface = state.global_iface orelse return false;

    // Extract IPv6 addresses from TCB
    const local_v6 = switch (tcb.local_addr) {
        .v6 => |addr| addr,
        else => return false,
    };
    const remote_v6 = switch (tcb.remote_addr) {
        .v6 => |addr| addr,
        else => return false,
    };

    // Resolve destination MAC via NDP
    var dst_mac: [6]u8 = undefined;

    if (ipv6_types.isMulticast(remote_v6)) {
        dst_mac = addr_mod.ipv6MulticastToMac(remote_v6);
    } else {
        const next_hop = if (ipv6_types.isLinkLocal(remote_v6))
            remote_v6
        else if (iface.getIpv6Gateway(remote_v6)) |gw|
            gw
        else
            remote_v6;

        if (ndp.cache.lookup(next_hop)) |mac| {
            dst_mac = mac;
        } else {
            _ = ndp.sendNeighborSolicitation(iface, next_hop);
            return false;
        }
    }

    // SECURITY: Zero-initialize options buffer
    var options_buf: [c.TCP_MAX_OPTIONS_SIZE]u8 = [_]u8{0} ** c.TCP_MAX_OPTIONS_SIZE;
    const opts_len = options.buildSynOptions(&options_buf, tcb, false, null);

    const tcp_header_len = c.TCP_HEADER_SIZE + opts_len;
    const tcp_len = tcp_header_len;
    if (tcp_len > 65535) return false;
    const ipv6_len = packet.IPV6_HEADER_SIZE + tcp_len;
    const total_len = packet.ETH_HEADER_SIZE + ipv6_len;

    const buf = state.allocTxBuffer() orelse return false;
    defer state.freeTxBuffer(buf);

    if (total_len > buf.len) return false;

    // Build Ethernet header
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    ip6.setVersionTcFlow(6, tcb.tos, 0);
    ip6.setPayloadLength(@intCast(tcp_len));
    ip6.next_header = ipv6_types.PROTO_TCP;
    ip6.hop_limit = ipv6_types.DEFAULT_HOP_LIMIT;
    ip6.src_addr = local_v6;
    ip6.dst_addr = remote_v6;

    // Build TCP header
    const tcp_off = packet.ETH_HEADER_SIZE + packet.IPV6_HEADER_SIZE;
    const tcp_hdr: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_off]));
    tcp_hdr.setSrcPort(tcb.local_port);
    tcp_hdr.setDstPort(tcb.remote_port);
    tcp_hdr.setSeqNum(tcb.iss);
    tcp_hdr.setAckNum(0);
    const data_off_words: u4 = @intCast(tcp_header_len / 4);
    tcp_hdr.setDataOffsetFlags(data_off_words, TcpHeader.FLAG_SYN);
    tcp_hdr.setWindow(tcb.currentRecvWindow());
    tcp_hdr.checksum = 0;
    tcp_hdr.urgent_ptr = 0;

    if (opts_len > 0) {
        @memcpy(buf[tcp_off + c.TCP_HEADER_SIZE ..][0..opts_len], options_buf[0..opts_len]);
    }

    // Calculate TCP checksum with IPv6 pseudo-header
    const tcp_segment = buf[tcp_off..][0..tcp_len];
    tcp_hdr.checksum = checksum.tcpChecksum6(local_v6, remote_v6, tcp_segment);

    return iface.transmit(buf[0..total_len]);
}

/// Send a SYN-ACK segment over IPv6 (responding to connection)
fn sendSynAckWithOptions6(tcb: *Tcb, peer_opts: ?*const options.TcpOptions) bool {
    const iface = state.global_iface orelse return false;

    const local_v6 = switch (tcb.local_addr) {
        .v6 => |addr| addr,
        else => return false,
    };
    const remote_v6 = switch (tcb.remote_addr) {
        .v6 => |addr| addr,
        else => return false,
    };

    // Resolve destination MAC via NDP
    var dst_mac: [6]u8 = undefined;

    if (ipv6_types.isMulticast(remote_v6)) {
        dst_mac = addr_mod.ipv6MulticastToMac(remote_v6);
    } else {
        const next_hop = if (ipv6_types.isLinkLocal(remote_v6))
            remote_v6
        else if (iface.getIpv6Gateway(remote_v6)) |gw|
            gw
        else
            remote_v6;

        if (ndp.cache.lookup(next_hop)) |mac| {
            dst_mac = mac;
        } else {
            _ = ndp.sendNeighborSolicitation(iface, next_hop);
            return false;
        }
    }

    // SECURITY: Zero-initialize options buffer
    var options_buf: [c.TCP_MAX_OPTIONS_SIZE]u8 = [_]u8{0} ** c.TCP_MAX_OPTIONS_SIZE;
    const opts_len = options.buildSynOptions(&options_buf, tcb, true, peer_opts);

    const tcp_header_len = c.TCP_HEADER_SIZE + opts_len;
    const tcp_len = tcp_header_len;
    if (tcp_len > 65535) return false;
    const ipv6_len = packet.IPV6_HEADER_SIZE + tcp_len;
    const total_len = packet.ETH_HEADER_SIZE + ipv6_len;

    const buf = state.allocTxBuffer() orelse return false;
    defer state.freeTxBuffer(buf);

    if (total_len > buf.len) return false;

    // Build Ethernet header
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    ip6.setVersionTcFlow(6, tcb.tos, 0);
    ip6.setPayloadLength(@intCast(tcp_len));
    ip6.next_header = ipv6_types.PROTO_TCP;
    ip6.hop_limit = ipv6_types.DEFAULT_HOP_LIMIT;
    ip6.src_addr = local_v6;
    ip6.dst_addr = remote_v6;

    // Build TCP header
    const tcp_off = packet.ETH_HEADER_SIZE + packet.IPV6_HEADER_SIZE;
    const tcp_hdr: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_off]));
    tcp_hdr.setSrcPort(tcb.local_port);
    tcp_hdr.setDstPort(tcb.remote_port);
    tcp_hdr.setSeqNum(tcb.iss);
    tcp_hdr.setAckNum(tcb.rcv_nxt);
    const data_off_words: u4 = @intCast(tcp_header_len / 4);
    tcp_hdr.setDataOffsetFlags(data_off_words, TcpHeader.FLAG_SYN | TcpHeader.FLAG_ACK);
    tcp_hdr.setWindow(tcb.currentRecvWindow());
    tcp_hdr.checksum = 0;
    tcp_hdr.urgent_ptr = 0;

    if (opts_len > 0) {
        @memcpy(buf[tcp_off + c.TCP_HEADER_SIZE ..][0..opts_len], options_buf[0..opts_len]);
    }

    // Calculate TCP checksum with IPv6 pseudo-header
    const tcp_segment = buf[tcp_off..][0..tcp_len];
    tcp_hdr.checksum = checksum.tcpChecksum6(local_v6, remote_v6, tcp_segment);

    return iface.transmit(buf[0..total_len]);
}

/// Send an ACK with SACK options over IPv6
fn sendAckWithOptions6(tcb: *Tcb) bool {
    const iface = state.global_iface orelse return false;

    const local_v6 = switch (tcb.local_addr) {
        .v6 => |addr| addr,
        else => return false,
    };
    const remote_v6 = switch (tcb.remote_addr) {
        .v6 => |addr| addr,
        else => return false,
    };

    // Resolve destination MAC via NDP
    var dst_mac: [6]u8 = undefined;

    if (ipv6_types.isMulticast(remote_v6)) {
        dst_mac = addr_mod.ipv6MulticastToMac(remote_v6);
    } else {
        const next_hop = if (ipv6_types.isLinkLocal(remote_v6))
            remote_v6
        else if (iface.getIpv6Gateway(remote_v6)) |gw|
            gw
        else
            remote_v6;

        if (ndp.cache.lookup(next_hop)) |mac| {
            dst_mac = mac;
        } else {
            _ = ndp.sendNeighborSolicitation(iface, next_hop);
            return false;
        }
    }

    // SECURITY: Zero-initialize options buffer
    var options_buf: [c.TCP_MAX_OPTIONS_SIZE]u8 = [_]u8{0} ** c.TCP_MAX_OPTIONS_SIZE;
    const opts_len = options.buildSackOptions(&options_buf, tcb);

    const tcp_header_len = c.TCP_HEADER_SIZE + opts_len;
    const tcp_len = tcp_header_len;
    if (tcp_len > 65535) return false;
    const ipv6_len = packet.IPV6_HEADER_SIZE + tcp_len;
    const total_len = packet.ETH_HEADER_SIZE + ipv6_len;

    const buf = state.allocTxBuffer() orelse return false;
    defer state.freeTxBuffer(buf);

    if (total_len > buf.len) return false;

    // Build Ethernet header
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    ip6.setVersionTcFlow(6, tcb.tos, 0);
    ip6.setPayloadLength(@intCast(tcp_len));
    ip6.next_header = ipv6_types.PROTO_TCP;
    ip6.hop_limit = ipv6_types.DEFAULT_HOP_LIMIT;
    ip6.src_addr = local_v6;
    ip6.dst_addr = remote_v6;

    // Build TCP header
    const tcp_off = packet.ETH_HEADER_SIZE + packet.IPV6_HEADER_SIZE;
    const tcp_hdr: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_off]));
    tcp_hdr.setSrcPort(tcb.local_port);
    tcp_hdr.setDstPort(tcb.remote_port);
    tcp_hdr.setSeqNum(tcb.snd_nxt);
    tcp_hdr.setAckNum(tcb.rcv_nxt);
    const data_off_words: u4 = @intCast(tcp_header_len / 4);
    tcp_hdr.setDataOffsetFlags(data_off_words, TcpHeader.FLAG_ACK);
    tcp_hdr.setWindow(tcb.currentRecvWindow());
    tcp_hdr.checksum = 0;
    tcp_hdr.urgent_ptr = 0;

    if (opts_len > 0) {
        @memcpy(buf[tcp_off + c.TCP_HEADER_SIZE ..][0..opts_len], options_buf[0..opts_len]);
    }

    // Calculate TCP checksum with IPv6 pseudo-header
    const tcp_segment = buf[tcp_off..][0..tcp_len];
    tcp_hdr.checksum = checksum.tcpChecksum6(local_v6, remote_v6, tcp_segment);

    return iface.transmit(buf[0..total_len]);
}

/// Send a RST segment for an incoming IPv6 packet (stateless response)
pub fn sendRstForPacket6(iface: *interface.Interface, pkt: *const PacketBuffer, tcp_hdr: *const TcpHeader) bool {
    const ip6_hdr = packet.getIpv6Header(pkt.data, pkt.ip_offset) orelse return false;

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) return true;

    const src_v6 = ip6_hdr.dst_addr;
    const dst_v6 = ip6_hdr.src_addr;

    // Resolve destination MAC via NDP - don't send RST to multicast
    if (ipv6_types.isMulticast(dst_v6)) {
        return true;
    }

    var dst_mac: [6]u8 = undefined;
    const next_hop = if (ipv6_types.isLinkLocal(dst_v6))
        dst_v6
    else if (iface.getIpv6Gateway(dst_v6)) |gw|
        gw
    else
        dst_v6;

    if (ndp.cache.lookup(next_hop)) |mac| {
        dst_mac = mac;
    } else {
        // Can't resolve MAC - drop silently for RST
        return false;
    }

    const buf = state.allocTxBuffer() orelse return false;
    defer state.freeTxBuffer(buf);

    const total_len = packet.ETH_HEADER_SIZE + packet.IPV6_HEADER_SIZE + c.TCP_HEADER_SIZE;

    // Build Ethernet header
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *Ipv6Header = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    ip6.setVersionTcFlow(6, 0, 0);
    ip6.setPayloadLength(c.TCP_HEADER_SIZE);
    ip6.next_header = ipv6_types.PROTO_TCP;
    ip6.hop_limit = ipv6_types.DEFAULT_HOP_LIMIT;
    ip6.src_addr = src_v6;
    ip6.dst_addr = dst_v6;

    // Build TCP header
    const tcp_off = packet.ETH_HEADER_SIZE + packet.IPV6_HEADER_SIZE;
    const tcp: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_off]));
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

    // Calculate TCP checksum with IPv6 pseudo-header
    const tcp_segment = buf[tcp_off..][0..c.TCP_HEADER_SIZE];
    tcp.checksum = checksum.tcpChecksum6(src_v6, dst_v6, tcp_segment);

    return iface.transmit(buf[0..total_len]);
}
