const c = @import("../constants.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
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

/// Send a TCP segment (dispatches to IPv4 or IPv6 based on TCB address family)
pub fn sendSegment(
    tcb: *Tcb,
    flags: u16,
    seq: u32,
    ack: u32,
    data: ?[]const u8,
) bool {
    // Branch based on address family
    if (tcb.isIpv6()) {
        return sendSegment6(tcb, flags, seq, ack, data);
    }

    const iface = state.global_iface orelse return false;

    // Resolve destination MAC (single atomic lookup to avoid TOCTOU race)
    const next_hop = iface.getGateway(tcb.getRemoteIpV4());
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
    const eth: *align(1) EthernetHeader = @ptrCast(&buf[0]);
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    // Build IP header
    const ip: *align(1) Ipv4Header = @ptrCast(&buf[packet.ETH_HEADER_SIZE]);
    ip.version_ihl = 0x45;
    ip.tos = tcb.tos; // Use socket's ToS/DSCP value
    ip.setTotalLength(@intCast(ip_len)); // Safe: validated ip_len <= 65535 above
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000)); // Don't Fragment
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_TCP;
    ip.checksum = 0;
    ip.setSrcIp(tcb.getLocalIpV4());
    ip.setDstIp(tcb.getRemoteIpV4());
    ip.checksum = @byteSwap(checksum.ipChecksum(buf[packet.ETH_HEADER_SIZE..][0..packet.IP_HEADER_SIZE]));

    // Build TCP header
    const tcp_offset = packet.ETH_HEADER_SIZE + packet.IP_HEADER_SIZE;
    const tcp: *align(1) TcpHeader = @ptrCast(&buf[tcp_offset]);
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
    tcp.checksum = @byteSwap(checksum.tcpChecksum(ip.getSrcIp(), ip.getDstIp(), tcp_segment));

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

/// Send a TCP segment over IPv6
pub fn sendSegment6(
    tcb: *Tcb,
    flags: u16,
    seq: u32,
    ack: u32,
    data: ?[]const u8,
) bool {
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
    var dst_mac: [6]u8 = [_]u8{0} ** 6;
    var have_mac = false;

    if (ipv6_types.isMulticast(remote_v6)) {
        // Multicast to Ethernet mapping (33:33:xx:xx:xx:xx)
        dst_mac = addr_mod.ipv6MulticastToMac(remote_v6);
        have_mac = true;
    } else {
        // Unicast: Resolve via NDP
        // Determine next hop - use gateway if not link-local
        const next_hop = if (ipv6_types.isLinkLocal(remote_v6))
            remote_v6
        else if (iface.getIpv6Gateway(remote_v6)) |gw|
            gw
        else
            remote_v6;

        if (ndp.cache.lookup(next_hop)) |mac| {
            dst_mac = mac;
            have_mac = true;
        } else {
            // Need NDP resolution - trigger NS and let retransmission handle it
            _ = ndp.sendNeighborSolicitation(iface, next_hop);
            return false;
        }
    }

    // Calculate sizes with validation
    const tcp_data_len: usize = if (data) |d| blk: {
        if (d.len > c.MAX_TCP_PAYLOAD) return false;
        break :blk d.len;
    } else 0;
    const tcp_len = c.TCP_HEADER_SIZE + tcp_data_len;
    // IPv6 payload length field is 16-bit (max 65535)
    if (tcp_len > 65535) return false;
    const ipv6_len = packet.IPV6_HEADER_SIZE + tcp_len;
    const total_len = packet.ETH_HEADER_SIZE + ipv6_len;

    // Use static buffer pool
    const buf = state.allocTxBuffer() orelse return false;
    defer state.freeTxBuffer(buf);

    if (total_len > buf.len) return false;

    // Build Ethernet header
    const eth: *align(1) EthernetHeader = @ptrCast(&buf[0]);
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *align(1) Ipv6Header = @ptrCast(&buf[packet.ETH_HEADER_SIZE]);
    ip6.setVersionTcFlow(6, tcb.tos, 0);
    ip6.setPayloadLength(@intCast(tcp_len));
    ip6.next_header = ipv6_types.PROTO_TCP;
    ip6.hop_limit = ipv6_types.DEFAULT_HOP_LIMIT;
    ip6.src_addr = local_v6;
    ip6.dst_addr = remote_v6;

    // Build TCP header
    const tcp_offset = packet.ETH_HEADER_SIZE + packet.IPV6_HEADER_SIZE;
    const tcp: *align(1) TcpHeader = @ptrCast(&buf[tcp_offset]);
    tcp.setSrcPort(tcb.local_port);
    tcp.setDstPort(tcb.remote_port);
    tcp.setSeqNum(seq);
    tcp.setAckNum(ack);
    tcp.setDataOffsetFlags(5, flags);
    tcp.setWindow(tcb.currentRecvWindow());
    tcp.checksum = 0;
    tcp.urgent_ptr = 0;

    // Copy payload data
    if (data) |d| {
        @memcpy(buf[tcp_offset + c.TCP_HEADER_SIZE ..][0..d.len], d);
    }

    // Calculate TCP checksum with IPv6 pseudo-header
    const tcp_segment = buf[tcp_offset..][0..tcp_len];
    tcp.checksum = @byteSwap(checksum.tcpChecksum6(local_v6, remote_v6, tcp_segment));

    // Transmit
    if (have_mac) {
        return iface.transmit(buf[0..total_len]);
    }
    return false;
}
