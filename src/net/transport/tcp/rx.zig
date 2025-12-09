const c = @import("constants.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const options = @import("options.zig");
const tx = @import("tx.zig");

const packet = @import("../../core/packet.zig");
const socket = @import("../socket.zig");
const Interface = @import("../../core/interface.zig").Interface;

const TcpHeader = types.TcpHeader;
const TcpState = types.TcpState;
const Tcb = types.Tcb;
const TcpOptions = options.TcpOptions;
const PacketBuffer = packet.PacketBuffer;

const seqLt = types.seqLt;
const seqLte = types.seqLte;
const seqGt = types.seqGt;
const seqGte = types.seqGte;

/// Process an incoming TCP packet
/// Returns true if packet was handled
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    state.lock.acquire();
    defer state.lock.release();

    // Validate minimum TCP header size
    if (pkt.len < pkt.transport_offset + c.TCP_HEADER_SIZE) {
        return false;
    }

    const tcp_hdr: *TcpHeader = @ptrCast(@alignCast(&pkt.data[pkt.transport_offset]));
    const ip_hdr = pkt.ipHeader();

    // Validate TCP data offset
    const data_offset = tcp_hdr.getDataOffset();
    if (data_offset < c.TCP_HEADER_SIZE) {
        return false;
    }

    // Verify TCP checksum
    const ip_payload_len = ip_hdr.getTotalLength() - ip_hdr.getHeaderLength();
    const tcp_segment = pkt.data[pkt.transport_offset..][0..ip_payload_len];
    const calc_checksum = @import("checksum.zig").tcpChecksum(ip_hdr.src_ip, ip_hdr.dst_ip, tcp_segment);

    if (calc_checksum != 0 and tcp_hdr.checksum != calc_checksum) {
        return false; // Bad checksum
    }

    // Look up connection
    const local_ip = ip_hdr.getDstIp();
    const local_port = tcp_hdr.getDstPort();
    const remote_ip = ip_hdr.getSrcIp();
    const remote_port = tcp_hdr.getSrcPort();

    // Try established connection first
    if (state.findTcb(local_ip, local_port, remote_ip, remote_port)) |tcb| {
        return processEstablishedPacket(tcb, pkt, tcp_hdr);
    }

    // Try listening socket
    if (state.findListeningTcb(local_port)) |listen_tcb| {
        return processListenPacket(iface, listen_tcb, pkt, tcp_hdr);
    }

    // No matching connection - send RST
    _ = tx.sendRstForPacket(iface, pkt, tcp_hdr);
    return true;
}

/// Process packet for LISTEN state
fn processListenPacket(
    iface: *state.Interface,
    listen_tcb: *Tcb,
    pkt: *PacketBuffer,
    tcp_hdr: *TcpHeader,
) bool {
    _ = iface;

    // In LISTEN state, we only accept SYN (no ACK)
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) {
        return true; // Ignore RST in LISTEN
    }

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        // ACK in LISTEN is invalid - ignore (RFC says send RST but we're lenient)
        return true;
    }

    if (!tcp_hdr.hasFlag(TcpHeader.FLAG_SYN)) {
        return true; // Not a SYN - ignore
    }

    // SYN flood protection: limit half-open connections
    // Drop SYN silently if too many connections in SYN-RECEIVED state
    if (state.countHalfOpen() >= c.MAX_HALF_OPEN) {
        return false; // Silently drop - don't send RST to avoid amplification
    }

    // Got SYN - create new TCB for this connection
    const new_tcb = state.allocateTcb() orelse return false;

    const ip_hdr = pkt.ipHeader();
    new_tcb.local_ip = ip_hdr.getDstIp();
    new_tcb.local_port = tcp_hdr.getDstPort();
    new_tcb.remote_ip = ip_hdr.getSrcIp();
    new_tcb.remote_port = tcp_hdr.getSrcPort();

    // Initialize sequence numbers
    new_tcb.irs = tcp_hdr.getSeqNum();
    new_tcb.rcv_nxt = new_tcb.irs +% 1; // SYN consumes one seq
    new_tcb.iss = state.generateIsn(new_tcb.local_ip, new_tcb.local_port, new_tcb.remote_ip, new_tcb.remote_port);
    new_tcb.snd_nxt = new_tcb.iss +% 1; // Our SYN consumes one seq
    new_tcb.snd_una = new_tcb.iss;

    // Record peer's window (will be scaled after options parsed)
    new_tcb.snd_wnd = tcp_hdr.getWindow();

    // Parse all TCP options from incoming SYN
    var peer_opts = TcpOptions{};
    options.parseOptions(pkt, tcp_hdr, &peer_opts);

    // Apply parsed options to TCB
    new_tcb.mss = if (peer_opts.mss_present) peer_opts.mss else c.DEFAULT_MSS;
    if (peer_opts.wscale_present) {
        new_tcb.snd_wscale = peer_opts.wscale;
        new_tcb.wscale_ok = true;
    }

    if (peer_opts.sack_permitted) {
        new_tcb.sack_ok = true;
    }

    if (peer_opts.timestamp_present) {
        new_tcb.ts_ok = true;
        new_tcb.ts_recent = peer_opts.ts_val;
    }

    // Scale peer window if negotiated
    if (new_tcb.wscale_ok) {
        new_tcb.snd_wnd = @as(u32, new_tcb.snd_wnd) << new_tcb.snd_wscale;
    }

    // Link to parent for accept queue
    new_tcb.parent_socket = listen_tcb.parent_socket;

    // Inherit ToS from listening socket
    new_tcb.tos = listen_tcb.tos;

    // Transition to SYN-RECEIVED
    new_tcb.state = .SynReceived;

    // Insert into hash table
    state.insertTcbIntoHash(new_tcb);

    // Send SYN-ACK with options (negotiates wscale, sack, timestamps)
    if (!tx.sendSynAckWithOptions(new_tcb, &peer_opts)) {
        state.freeTcb(new_tcb);
        return false;
    }

    // Start retransmit timer
    new_tcb.retrans_timer = 1; // Non-zero to indicate active

    return true;
}

/// Process packet for established (non-LISTEN) connections
fn processEstablishedPacket(tcb: *Tcb, pkt: *PacketBuffer, tcp_hdr: *TcpHeader) bool {
    // Handle RST first
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) {
        return handleRst(tcb);
    }

    // Dispatch based on state
    switch (tcb.state) {
        .SynSent => return processSynSent(tcb, pkt, tcp_hdr),
        .SynReceived => return processSynReceived(tcb, tcp_hdr),
        .Established => return processEstablished(tcb, pkt, tcp_hdr),
        .CloseWait => return processCloseWait(tcb, tcp_hdr),
        .LastAck => return processLastAck(tcb, tcp_hdr),
        else => return false,
    }
}

/// Handle RST segment
fn handleRst(tcb: *Tcb) bool {
    // Connection reset - close immediately
    tcb.state = .Closed;

    // Wake any thread blocked on this connection
    if (tcb.blocked_thread) |thread| {
        socket.wakeThread(thread);
        tcb.blocked_thread = null;
    }

    state.freeTcb(tcb);
    return true;
}

/// Process packet in SYN-SENT state
fn processSynSent(tcb: *Tcb, pkt: *PacketBuffer, tcp_hdr: *TcpHeader) bool {
    // Expecting SYN-ACK
    if (!tcp_hdr.hasFlag(TcpHeader.FLAG_SYN)) {
        return true;
    }

    // Verify ACK if present
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        // ACK must acknowledge our SYN
        if (ack != tcb.iss +% 1) {
            // Bad ACK - send RST
            _ = tx.sendRst(tcb);
            tcb.state = .Closed;
            // Wake thread blocked on connect() with error
            if (tcb.blocked_thread) |thread| {
                socket.wakeThread(thread);
                tcb.blocked_thread = null;
            }
            state.freeTcb(tcb);
            return true;
        }
        tcb.snd_una = ack;
    }

    // Record peer's ISN
    tcb.irs = tcp_hdr.getSeqNum();
    tcb.rcv_nxt = tcb.irs +% 1;

    // Parse TCP options from SYN-ACK to complete negotiation
    var peer_opts = TcpOptions{};
    options.parseOptions(pkt, tcp_hdr, &peer_opts);

    // Apply negotiated options
    if (peer_opts.mss_present) {
        tcb.mss = peer_opts.mss;
    }

    // Window scaling: only enable if peer also sent wscale in SYN-ACK
    // (We sent wscale in our SYN, peer echoes if it supports)
    if (peer_opts.wscale_present and tcb.rcv_wscale > 0) {
        tcb.snd_wscale = peer_opts.wscale;
        tcb.wscale_ok = true;
    } else {
        // Peer didn't send wscale - disable scaling
        tcb.snd_wscale = 0;
        tcb.rcv_wscale = 0;
        tcb.wscale_ok = false;
    }

    // SACK: enable if peer sent sack_permitted
    if (peer_opts.sack_permitted) {
        tcb.sack_ok = true;
    }

    // Timestamps: enable if peer sent timestamp
    if (peer_opts.timestamp_present) {
        tcb.ts_ok = true;
        tcb.ts_recent = peer_opts.ts_val;
    }

    // Record peer's window (apply scaling if negotiated)
    const raw_window = tcp_hdr.getWindow();
    tcb.snd_wnd = if (tcb.wscale_ok)
        @as(u32, raw_window) << tcb.snd_wscale
    else
        raw_window;

    // Transition to ESTABLISHED
    tcb.state = .Established;
    tcb.retrans_timer = 0;
    tcb.retrans_count = 0;

    // Wake thread blocked on connect()
    if (tcb.blocked_thread) |thread| {
        socket.wakeThread(thread);
        tcb.blocked_thread = null;
    }

    // Send ACK
    _ = tx.sendAck(tcb);

    return true;
}

/// Process packet in SYN-RECEIVED state
fn processSynReceived(tcb: *Tcb, tcp_hdr: *TcpHeader) bool {
    // Expecting ACK of our SYN-ACK
    if (!tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        return true;
    }

    const ack = tcp_hdr.getAckNum();
    // ACK must acknowledge our SYN
    if (ack != tcb.iss +% 1) {
        // Bad ACK
        return true;
    }

    // Connection established
    tcb.snd_una = ack;
    tcb.state = .Established;
    tcb.retrans_timer = 0;
    tcb.retrans_count = 0;

    // Add to parent's accept queue and wake blocked accept thread
    if (tcb.parent_socket) |parent_idx| {
        if (socket.queueAcceptConnection(parent_idx, tcb)) {
            // Successfully queued - wake any thread blocked on accept()
            if (socket.getSocket(parent_idx)) |parent_sock| {
                if (parent_sock.blocked_thread) |thread| {
                    socket.wakeThread(thread);
                    parent_sock.blocked_thread = null;
                }
            }
        }
    }

    return true;
}

/// Process packet in ESTABLISHED state
fn processEstablished(tcb: *Tcb, pkt: *PacketBuffer, tcp_hdr: *TcpHeader) bool {
    // Process ACK
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        // Valid ACK: snd_una < ack <= snd_nxt
        if (seqGt(ack, tcb.snd_una) and seqLte(ack, tcb.snd_nxt)) {
            // RTT Estimation
            if (tcb.rtt_seq != 0 and seqGte(ack, tcb.rtt_seq)) {
                const now = state.connection_timestamp;
                if (now >= tcb.rtt_start) {
                    const rtt_sample: u32 = @intCast(now - tcb.rtt_start);
                    tcb.updateRto(rtt_sample);
                }
                tcb.rtt_seq = 0;
            }

            // Congestion Control (RFC 5681)
            const acked_bytes = ack -% tcb.snd_una;
            if (tcb.cwnd < tcb.ssthresh) {
                // Slow Start
                tcb.cwnd += @min(acked_bytes, tcb.mss);
            } else {
                // Congestion Avoidance
                // Increment approx 1 MSS per RTT: cwnd += MSS * MSS / cwnd
                // We use max(1, ...) to ensure forward progress
                const inc = @max(1, (@as(u64, tcb.mss) * tcb.mss) / tcb.cwnd);
                tcb.cwnd += @as(u32, @truncate(inc));
            }

            tcb.snd_una = ack;
            // Stop retransmit timer if all data acked
            if (tcb.snd_una == tcb.snd_nxt) {
                tcb.retrans_timer = 0;
            }
        }
    }

    // Update send window
    tcb.snd_wnd = tcp_hdr.getWindow();

    // Process incoming data
    const seq = tcp_hdr.getSeqNum();
    const data_offset = tcp_hdr.getDataOffset();
    const ip_hdr = pkt.ipHeader();
    const ip_payload_len = ip_hdr.getTotalLength() - ip_hdr.getHeaderLength();

    if (ip_payload_len > data_offset) {
        const data_len = ip_payload_len - data_offset;
        const data_start = pkt.transport_offset + data_offset;
        const data = pkt.data[data_start..][0..data_len];

        // Only accept in-order data for MVP
        if (seq == tcb.rcv_nxt) {
            // Copy to receive buffer
            const space = c.BUFFER_SIZE - tcb.recvBufferAvailable();
            const copy_len = @min(data_len, space);

            for (0..copy_len) |i| {
                tcb.recv_buf[tcb.recv_head] = data[i];
                tcb.recv_head = (tcb.recv_head + 1) % c.BUFFER_SIZE;
            }

            tcb.rcv_nxt +%= @as(u32, @truncate(copy_len));

            // Wake thread blocked on recv() if data was copied
            if (copy_len > 0) {
                if (tcb.blocked_thread) |thread| {
                    socket.wakeThread(thread);
                    tcb.blocked_thread = null;
                }
            }
        }
    }

    // Handle FIN
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_FIN)) {
        // Peer is closing
        tcb.rcv_nxt +%= 1; // FIN consumes one sequence
        tcb.state = .CloseWait;

        // Wake thread blocked on recv() so it sees EOF
        if (tcb.blocked_thread) |thread| {
            socket.wakeThread(thread);
            tcb.blocked_thread = null;
        }

        _ = tx.sendAck(tcb);
        return true;
    }

    // Send ACK for data received
    if (ip_payload_len > data_offset or tcp_hdr.hasFlag(TcpHeader.FLAG_SYN)) {
        _ = tx.sendAck(tcb);
    }

    return true;
}

/// Process packet in CLOSE-WAIT state
fn processCloseWait(tcb: *Tcb, tcp_hdr: *TcpHeader) bool {
    // Just process ACKs
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (seqGt(ack, tcb.snd_una) and seqLte(ack, tcb.snd_nxt)) {
            tcb.snd_una = ack;
        }
    }
    return true;
}

/// Process packet in LAST-ACK state
fn processLastAck(tcb: *Tcb, tcp_hdr: *TcpHeader) bool {
    // Waiting for ACK of our FIN
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (ack == tcb.snd_nxt) {
            // FIN acknowledged - connection closed
            tcb.state = .Closed;
            state.freeTcb(tcb);
        }
    }
    return true;
}
