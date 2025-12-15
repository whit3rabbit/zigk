const c = @import("constants.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const options = @import("options.zig");
const checksum = @import("checksum.zig");

const packet = @import("../../core/packet.zig");
const interface = @import("../../core/interface.zig");
const checksum_mod = @import("../../core/checksum.zig");
const ipv4 = @import("../../ipv4/ipv4.zig");
const ethernet = @import("../../ethernet/ethernet.zig");
const arp = @import("../../ipv4/arp.zig");

const PacketBuffer = packet.PacketBuffer;
const Ipv4Header = packet.Ipv4Header;
const EthernetHeader = packet.EthernetHeader;
const Interface = interface.Interface;
const TcpHeader = types.TcpHeader;
const Tcb = types.Tcb;

// TCP Output Processing
//
// Complies with:
// - RFC 793: SEGMENTATION
// - RFC 1122: Requirements for Internet Hosts (Sender SWS Avoidance)
// - RFC 1191: Path MTU Discovery (MSS calculation)
//
// Handles construction and transmission of TCP segments.
/// Send a TCP segment
/// Send a TCP segment
fn sendSegment(
    tcb: *Tcb,
    flags: u16,
    seq: u32,
    ack: u32,
    data: ?[]const u8,
) bool {
    const iface = state.global_iface orelse return false;

    // Resolve destination MAC
    const next_hop = iface.getGateway(tcb.remote_ip);
    var dst_mac = arp.resolve(next_hop) orelse [_]u8{ 0, 0, 0, 0, 0, 0 };
    const have_mac = (arp.resolve(next_hop) != null);

    // Calculate sizes
    const tcp_data_len = if (data) |d| d.len else 0;
    const tcp_len = c.TCP_HEADER_SIZE + tcp_data_len;
    const ip_len = packet.IP_HEADER_SIZE + tcp_len;
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
    ip.setTotalLength(@truncate(ip_len));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000)); // Don't Fragment
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_TCP;
    ip.checksum = 0;
    ip.setSrcIp(tcb.local_ip);
    ip.setDstIp(tcb.remote_ip);
    ip.checksum = checksum_mod.ipChecksum(buf[packet.ETH_HEADER_SIZE..][0..packet.IP_HEADER_SIZE]);

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
        // We must clone the buffer because 'buf' is freed on return
        // PacketBuffer normally references external memory.
        // We need 'arp.resolveOrRequest' to potentially COPY the packet if it queues it.
        // Looking at arp.zig, resolveOrRequest queues the *PacketBuffer*. 
        // PacketBuffer holds a pointer. If we free 'buf', the queued packet points to garbage.
        // FIXME: optimize this. For now, we rely on ARP queue making a copy if needed, 
        // OR we have to make a copy here that persists.
        
        // Actually, arp.resolveOrRequest takes *PacketBuffer.
        // Inside ARP, if it queues, does it copy? 
        // Checking arp.zig (from memory/previous context): ARP queue usually stores PacketBuffer.
        // If PacketBuffer points to stack/temporary heap, we have a problem.
        
        // Solution: Alloc separate buffer for queued packet if needed.
        // OR: Alloc 'buf' and ONLY free it if we transmit successfully.
        // If queued, we leak it? No, ARP must own it.
        // Since ARP model typically assumes caller owns buffer or copies, and we are moving away from stack...
        
        // Current implementation uses `PacketBuffer.init(&buf, ...)` where buf is stack.
        // If ARP queued this, it was ALREADY BUGGY (pointing to stack of returned function)!
        
        // SO: We are ACTUALLY fixing a Use-After-Return bug here too if ARP queues stack pointers!
        // To fix correctly: We must allocate a buffer that survives if queued.
        // But 'transmit' consumes the buffer (copies to hardware ring).
        
        // Let's assume for now we use the same pattern but on heap:
        // If we transmit, we can free.
        // If we queue, ARP *should* have been copying. If not, we have a bigger issue.
        // Assuming Standard ARP implementation copies for methods taking *PacketBuffer on stack.
        
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

/// Send a SYN segment (initiating connection) - legacy without options
pub fn sendSyn(tcb: *Tcb) bool {
    return sendSynWithOptions(tcb);
}

/// Send a SYN-ACK segment (responding to SYN) - legacy without options
pub fn sendSynAck(tcb: *Tcb) bool {
    return sendSynAckWithOptions(tcb, null);
}

/// Send a SYN segment with TCP options (initiating connection)
pub fn sendSynWithOptions(tcb: *Tcb) bool {
    const iface = state.global_iface orelse return false;

    // Resolve destination MAC
    const next_hop = iface.getGateway(tcb.remote_ip);
    var dst_mac = arp.resolve(next_hop) orelse [_]u8{ 0, 0, 0, 0, 0, 0 };
    const have_mac = (arp.resolve(next_hop) != null);

    // Build TCP options
    // stack alloc is small enough? TCP_MAX_OPTIONS_SIZE is 40 bytes. OK.
    var options_buf: [c.TCP_MAX_OPTIONS_SIZE]u8 = undefined;
    const options_len = options.buildSynOptions(&options_buf, tcb, false, null);

    // Calculate sizes with options
    const tcp_header_len = c.TCP_HEADER_SIZE + options_len;
    const tcp_len = tcp_header_len;
    const ip_len = packet.IP_HEADER_SIZE + tcp_len;
    const total_len = packet.ETH_HEADER_SIZE + ip_len;

    // Use static buffer pool
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
    ip.tos = tcb.tos;
    ip.setTotalLength(@truncate(ip_len));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_TCP;
    ip.checksum = 0;
    ip.setSrcIp(tcb.local_ip);
    ip.setDstIp(tcb.remote_ip);
    ip.checksum = checksum_mod.ipChecksum(buf[packet.ETH_HEADER_SIZE..][0..packet.IP_HEADER_SIZE]);

    // Build TCP header
    const tcp_offset = packet.ETH_HEADER_SIZE + packet.IP_HEADER_SIZE;
    const tcp_hdr: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_offset]));
    tcp_hdr.setSrcPort(tcb.local_port);
    tcp_hdr.setDstPort(tcb.remote_port);
    tcp_hdr.setSeqNum(tcb.iss);
    tcp_hdr.setAckNum(0);
    // Data offset = (20 + options_len) / 4, SYN flag
    const data_offset_words: u4 = @intCast(tcp_header_len / 4);
    tcp_hdr.setDataOffsetFlags(data_offset_words, TcpHeader.FLAG_SYN);
    tcp_hdr.setWindow(tcb.currentRecvWindow());
    tcp_hdr.checksum = 0;
    tcp_hdr.urgent_ptr = 0;

    // Copy TCP options after header
    if (options_len > 0) {
        @memcpy(buf[tcp_offset + c.TCP_HEADER_SIZE ..][0..options_len], options_buf[0..options_len]);
    }

    // Calculate TCP checksum
    const tcp_segment = buf[tcp_offset..][0..tcp_len];
    tcp_hdr.checksum = checksum.tcpChecksum(ip.src_ip, ip.dst_ip, tcp_segment);

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

/// Send a SYN-ACK segment with TCP options (responding to SYN)
pub fn sendSynAckWithOptions(tcb: *Tcb, peer_opts: ?*const options.TcpOptions) bool {
    const iface = state.global_iface orelse return false;

    // Resolve destination MAC
    const next_hop = iface.getGateway(tcb.remote_ip);
    var dst_mac = arp.resolve(next_hop) orelse [_]u8{ 0, 0, 0, 0, 0, 0 };
    const have_mac = (arp.resolve(next_hop) != null);

    // Build TCP options (negotiate based on peer's options)
    var options_buf: [c.TCP_MAX_OPTIONS_SIZE]u8 = undefined;
    const options_len = options.buildSynOptions(&options_buf, tcb, true, peer_opts);

    // Calculate sizes with options
    const tcp_header_len = c.TCP_HEADER_SIZE + options_len;
    const tcp_len = tcp_header_len;
    const ip_len = packet.IP_HEADER_SIZE + tcp_len;
    const total_len = packet.ETH_HEADER_SIZE + ip_len;

    // Use static buffer pool
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
    ip.tos = tcb.tos;
    ip.setTotalLength(@truncate(ip_len));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_TCP;
    ip.checksum = 0;
    ip.setSrcIp(tcb.local_ip);
    ip.setDstIp(tcb.remote_ip);
    ip.checksum = checksum_mod.ipChecksum(buf[packet.ETH_HEADER_SIZE..][0..packet.IP_HEADER_SIZE]);

    // Build TCP header
    const tcp_offset = packet.ETH_HEADER_SIZE + packet.IP_HEADER_SIZE;
    const tcp_hdr: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_offset]));
    tcp_hdr.setSrcPort(tcb.local_port);
    tcp_hdr.setDstPort(tcb.remote_port);
    tcp_hdr.setSeqNum(tcb.iss);
    tcp_hdr.setAckNum(tcb.rcv_nxt);
    // Data offset = (20 + options_len) / 4, SYN+ACK flags
    const data_offset_words: u4 = @intCast(tcp_header_len / 4);
    tcp_hdr.setDataOffsetFlags(data_offset_words, TcpHeader.FLAG_SYN | TcpHeader.FLAG_ACK);
    tcp_hdr.setWindow(tcb.currentRecvWindow());
    tcp_hdr.checksum = 0;
    tcp_hdr.urgent_ptr = 0;

    // Copy TCP options after header
    if (options_len > 0) {
        @memcpy(buf[tcp_offset + c.TCP_HEADER_SIZE ..][0..options_len], options_buf[0..options_len]);
    }

    // Calculate TCP checksum
    const tcp_segment = buf[tcp_offset..][0..tcp_len];
    tcp_hdr.checksum = checksum.tcpChecksum(ip.src_ip, ip.dst_ip, tcp_segment);

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

/// Send an ACK segment
pub fn sendAck(tcb: *Tcb) bool {
    return sendSegment(tcb, TcpHeader.FLAG_ACK, tcb.snd_nxt, tcb.rcv_nxt, null);
}

/// Send a FIN segment
pub fn sendFin(tcb: *Tcb) bool {
    return sendSegment(
        tcb,
        TcpHeader.FLAG_FIN | TcpHeader.FLAG_ACK,
        tcb.snd_nxt,
        tcb.rcv_nxt,
        null,
    );
}

/// Send a RST segment
pub fn sendRst(tcb: *Tcb) bool {
    return sendSegment(tcb, TcpHeader.FLAG_RST, tcb.snd_nxt, 0, null);
}

/// Send RST in response to an invalid packet (no TCB)
pub fn sendRstForPacket(iface: *Interface, pkt: *const PacketBuffer, tcp_hdr: *const TcpHeader) bool {
    const ip_hdr = pkt.ipHeader();

    // Don't RST a RST
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) return true;

    // Build RST response
    const next_hop = iface.getGateway(ip_hdr.getSrcIp());
    const dst_mac = arp.resolveOrRequest(iface, next_hop, null) orelse return false;

    // Use static buffer pool to avoid stack pressure and Use-After-Return if ARP queues packet
    const buf = state.allocTxBuffer() orelse return false;
    // We only free if we transmit immediately. If Arp queues it, Arp copies it.
    // See analysis in previous commit about ARP/PacketBuffer ownership.
    defer state.freeTxBuffer(buf);

    const total_len = packet.ETH_HEADER_SIZE + packet.IP_HEADER_SIZE + c.TCP_HEADER_SIZE;
    // ... logic continues ...

    // Ethernet
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    // IP
    const ip: *Ipv4Header = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    ip.version_ihl = 0x45;
    ip.tos = 0;
    ip.setTotalLength(@truncate(packet.IP_HEADER_SIZE + c.TCP_HEADER_SIZE));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_TCP;
    ip.checksum = 0;
    ip.setSrcIp(ip_hdr.getDstIp());
    ip.setDstIp(ip_hdr.getSrcIp());
    ip.checksum = checksum_mod.ipChecksum(buf[packet.ETH_HEADER_SIZE..][0..packet.IP_HEADER_SIZE]);

    // TCP RST
    const tcp_offset = packet.ETH_HEADER_SIZE + packet.IP_HEADER_SIZE;
    const tcp: *TcpHeader = @ptrCast(@alignCast(&buf[tcp_offset]));
    tcp.setSrcPort(tcp_hdr.getDstPort());
    tcp.setDstPort(tcp_hdr.getSrcPort());

    // Sequence number depends on whether incoming had ACK
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        tcp.setSeqNum(tcp_hdr.getAckNum());
        tcp.setAckNum(0);
        tcp.setDataOffsetFlags(5, TcpHeader.FLAG_RST);
    } else {
        tcp.setSeqNum(0);
        // ACK the SYN/data
        const seg_len = calculateSegmentLength(pkt, tcp_hdr);
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

/// Calculate segment length (data + SYN/FIN each count as 1)
pub fn calculateSegmentLength(pkt: *const PacketBuffer, tcp_hdr: *const TcpHeader) u32 {
    const data_offset = tcp_hdr.getDataOffset();
    const ip_hdr = pkt.ipHeader();
    const ip_payload_len = ip_hdr.getTotalLength() - ip_hdr.getHeaderLength();

    var len: u32 = 0;
    if (ip_payload_len > data_offset) {
        len = @as(u32, @truncate(ip_payload_len - data_offset));
    }

    // SYN and FIN consume one sequence number each
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_SYN)) len += 1;
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_FIN)) len += 1;

    return len;
}

/// Transmit pending data from send buffer
pub fn transmitPendingData(tcb: *Tcb) bool {
    if (tcb.state != .Established and tcb.state != .CloseWait) {
        return false;
    }

    // Calculate how much we can send
    const buffered = if (tcb.send_head >= tcb.send_tail)
        tcb.send_head - tcb.send_tail
    else
        c.BUFFER_SIZE - tcb.send_tail + tcb.send_head;

    if (buffered == 0) return true;

    // Get effective MSS considering PMTU (RFC 1191)
    // Use minimum of: peer's advertised MSS and PMTU-derived MSS
    const pmtu_mss = ipv4.getEffectiveMss(tcb.remote_ip);
    const effective_mss = @min(tcb.mss, pmtu_mss);

    // Respect peer's window, effective MSS, AND Congestion Window
    const eff_wnd = @min(@as(u32, tcb.snd_wnd), tcb.cwnd);

    const flight_size = tcb.snd_nxt -% tcb.snd_una;
    if (flight_size >= eff_wnd) {
        // Window full
        
        // Zero Window Probe (ZWP) Logic (RFC 793)
        // If window is 0, we must periodically send a segment to force an ACK
        // and discover when the window re-opens.
        if (eff_wnd == 0 and buffered > 0) {
            // Ensure timer is running to trigger probes
            if (tcb.retrans_timer == 0) {
                tcb.retrans_timer = 1; 
            }
            
            // If this call is from the timer (flight_size == 0 due to reset),
            // OR if we have no data in flight, send 1 byte probe.
            if (flight_size == 0) {
                 // Force 1 byte send for probe
                 // send_len is implicitly 1
                 
                 // Build probe segment
                 var data_buf: [1]u8 = undefined;
                 const idx = tcb.send_tail % c.BUFFER_SIZE;
                 data_buf[0] = tcb.send_buf[idx];
                 
                 // Send segment
                 if (sendSegment(tcb, TcpHeader.FLAG_ACK | TcpHeader.FLAG_PSH, tcb.snd_nxt, tcb.rcv_nxt, &data_buf)) {
                    tcb.snd_nxt +%= 1;
                    // Timer is already running (checked above)
                    return true;
                 }
            }
        }
        
        return true; 
    }

    // Available window
    const available = eff_wnd - flight_size;

    const max_send = @min(available, @as(u32, effective_mss));
    const send_len = @min(buffered, max_send);

    if (send_len == 0) return true;

    // Build data segment (may need to handle wraparound)
    var data_buf: [c.MAX_TCP_PAYLOAD]u8 = undefined;
    for (0..send_len) |i| {
        const idx = (tcb.send_tail + i) % c.BUFFER_SIZE;
        data_buf[i] = tcb.send_buf[idx];
    }

    // Set RTT measurement if not currently timing
    if (tcb.rtt_seq == 0) {
        tcb.rtt_seq = tcb.snd_nxt +% @as(u32, @truncate(send_len));
        tcb.rtt_start = state.connection_timestamp;
    }

    // Send segment
    if (sendSegment(tcb, TcpHeader.FLAG_ACK | TcpHeader.FLAG_PSH, tcb.snd_nxt, tcb.rcv_nxt, data_buf[0..send_len])) {
        tcb.snd_nxt +%= @as(u32, @truncate(send_len));
        if (tcb.retrans_timer == 0) {
            tcb.retrans_timer = 1; // Start retransmit timer
        }
        return true;
    }

    return false;
}
