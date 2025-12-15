const std = @import("std");
const c = @import("constants.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const options = @import("options.zig");
const tx = @import("tx.zig");
const console = @import("console");

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

fn freeTcbWithLock(tcb: *Tcb) void {
    state.lock.acquire();
    defer state.lock.release();
    state.freeTcb(tcb);
}

/// TCP Input Processing
//
//
// Complies with: - RFC 793: SEGMENT ARRIVAL (Section 3.9)
//
// Handles incoming TCP segments, state transitions, and data buffering.
// Implements the "SEGMENT ARRIVAL" event processing logic.f packet was handled
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
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
    const tcp_segment = pkt.data[pkt.transport_offset..pkt.len];

    // Use stored IPs for checksum to support reassembled packets
    const calc_checksum = @import("checksum.zig").tcpChecksum(pkt.src_ip, pkt.dst_ip, tcp_segment);

    // Security: For valid packets, computing checksum over entire segment (including
    // stored checksum) yields sum=0xFFFF. After one's complement, result=0, but
    // tcpChecksum returns 0xFFFF in that case. Any other value means bad checksum.
    if (calc_checksum != 0xFFFF) {
        return false; // Bad checksum
    }

    // Look up connection
    const local_ip = pkt.dst_ip;
    const local_port = tcp_hdr.getDstPort();
    const remote_ip = ip_hdr.getSrcIp();
    const remote_port = tcp_hdr.getSrcPort();

    // Try established connection first
    state.lock.acquire();
    if (state.findTcb(local_ip, local_port, remote_ip, remote_port)) |tcb| {
        // Security: Check closing flag before processing (two-phase deletion protection)
        if (tcb.closing) {
            state.lock.release();
            return false; // TCB is being torn down, ignore packet
        }

        // Acquire TCB lock while holding state lock to prevent race where TCB is freed
        const held = tcb.mutex.acquire();
        state.lock.release();
        defer held.release();

        return processEstablishedPacket(tcb, pkt, tcp_hdr);
    }

    // Try listening socket
    if (state.findListeningTcb(local_port)) |listen_tcb| {
        // Security: Check closing flag before processing (two-phase deletion protection)
        if (listen_tcb.closing) {
            state.lock.release();
            return false; // TCB is being torn down, ignore packet
        }

        // Acquire lock
        const held = listen_tcb.mutex.acquire();
        state.lock.release();
        defer held.release();

        return processListenPacket(iface, listen_tcb, pkt, tcp_hdr);
    }

    // No matching connection - send RST
    // We send RST without TCB lock, but we hold state.lock which protects interface?
    // sendRstForPacket doesn't use TCB.
    state.lock.release();
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
    if (state.countHalfOpen() >= c.MAX_HALF_OPEN) {
         // Try to evict oldest half-open TCB to make room (DoS mitigation)
         if (!state.evictOldestHalfOpenTcb()) {
             return false; // Could not make room, silently drop
         }
    }

    // Note: We should ideally also check listen_tcb backlog here, but we lack
    // direct access to the socket backlog counter from Tcb in this context.
    // Relying on global limit for now.

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
    // RFC 7323: MUST clamp window scale to 14 if greater
    if (new_tcb.wscale_ok) {
        const scale: u5 = if (new_tcb.snd_wscale > 14) blk: {
            console.warn("TCP: Illegal window scaling value {} > 14 received, using 14", .{new_tcb.snd_wscale});
            break :blk 14;
        } else @intCast(new_tcb.snd_wscale);
        new_tcb.snd_wnd = @as(u32, new_tcb.snd_wnd) << scale;
    }

    // Link to parent for accept queue
    new_tcb.parent_socket = listen_tcb.parent_socket;

    // Inherit ToS from listening socket
    new_tcb.tos = listen_tcb.tos;

    // Transition to SYN-RECEIVED
    new_tcb.state = .SynReceived;
    state.half_open_count += 1;

    // Insert into hash table
    state.insertTcbIntoHash(new_tcb);

    // Send SYN-ACK with options (negotiates wscale, sack, timestamps)
    if (!tx.sendSynAckWithOptions(new_tcb, &peer_opts)) {
        freeTcbWithLock(new_tcb);
        return false;
    }

    // Start retransmit timer
    new_tcb.retrans_timer = 1; // Non-zero to indicate active

    return true;
}

/// Process packet for established (non-LISTEN) connections
fn processEstablishedPacket(tcb: *Tcb, pkt: *PacketBuffer, tcp_hdr: *TcpHeader) bool {
    // Security: Check Sequence Number (RFC 793 / RFC 5961)
    // We must validate the sequence number before processing RST or SYN/ACK.
    const seq = tcp_hdr.getSeqNum();
    // const ack = tcp_hdr.getAckNum(); // Unused here
    const seg_len = tx.calculateSegmentLength(pkt, tcp_hdr);
    const rcv_wnd = tcb.currentRecvWindow();

    var acceptable = false;

    // Parse options for PAWS
    var peer_opts = options.TcpOptions{};
    options.parseOptions(pkt, tcp_hdr, &peer_opts);

    // PAWS: Protection Against Wrapped Sequences (RFC 7323)
    if (tcb.ts_ok and tcp_hdr.hasFlag(TcpHeader.FLAG_ACK) and peer_opts.timestamp_present) {
        // Drop packet if timestamp is older than recent
        // Note: RFC 7323 algorithm is more complex (handles pause, etc), simplified here
        // Security: Use seqLt for timestamp comparison to handle wrap-around (RFC 7323)
        // TS values are 32-bit and wrap just like sequence numbers.
        if (seqLt(peer_opts.ts_val, tcb.ts_recent)) {
            // Check if TS.Recent is valid (not too old) - simplified: assumed valid if connection active
             return true; // Drop silently (RFC recommends sending ACK, but silent drop is safer for DoS)
             // Actually RFC says: "If the connection is in a synchronized state ... send an acknowledgement"
             // We return true to indicate processed (dropped).
        }
        // Update TS.Recent
        if (seqLte(seq, tcb.rcv_nxt) and seqGt(seq +% seg_len, tcb.rcv_nxt)) {
            tcb.ts_recent = peer_opts.ts_val;
        }
    }

    if (seg_len == 0) {
        if (rcv_wnd == 0) {
            acceptable = (seq == tcb.rcv_nxt);
        } else {
            // Window > 0
            // RCV.NXT <= SEG.SEQ < RCV.NXT + RCV.WND
            // Handle wrap-around using subtraction
            const dist = seq -% tcb.rcv_nxt;
            acceptable = (dist < rcv_wnd);
        }
    } else {
        // Segment length > 0
        if (rcv_wnd == 0) {
            acceptable = false;
        } else {
            // Accept if beginning or end is in window
            const dist_start = seq -% tcb.rcv_nxt;
            const end_seq = seq +% seg_len -% 1;
            const dist_end = end_seq -% tcb.rcv_nxt;
            acceptable = (dist_start < rcv_wnd) or (dist_end < rcv_wnd);
        }
    }

    if (!acceptable) {
        // If an incoming segment is not acceptable, an acknowledgment should be sent in reply
        // unless the RST bit is set, in which case the segment is dropped
        if (!tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) {
            _ = tx.sendAck(tcb);
        } else {
             // RFC 5961: If RST is in window but not exact match, send challenge ACK
             // acceptable here means it is in window.
             // We need to check exact sequence match.
             if (seq != tcb.rcv_nxt) {
                 // Challenge ACK
                 _ = tx.sendAck(tcb);
                 return true;
             }
        }
        return true; // Packet processed (dropped)
    }

    // Handle RST first
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) {
        // RSI is valid (in window)
        // RFC 5961: Validate exact sequence number
        if (seq == tcb.rcv_nxt) {
            return handleRst(tcb);
        } else {
            // Challenge ACK
            _ = tx.sendAck(tcb);
            return true;
        }
    }

    // Dispatch based on state (RFC 793 state machine)
    switch (tcb.state) {
        .SynSent => return processSynSent(tcb, pkt, tcp_hdr),
        .SynReceived => return processSynReceived(tcb, tcp_hdr),
        .Established => return processEstablished(tcb, pkt, tcp_hdr),
        .FinWait1 => return processFinWait1(tcb, tcp_hdr),
        .FinWait2 => return processFinWait2(tcb, tcp_hdr),
        .CloseWait => return processCloseWait(tcb, tcp_hdr),
        .Closing => return processClosing(tcb, tcp_hdr),
        .LastAck => return processLastAck(tcb, tcp_hdr),
        .TimeWait => return processTimeWait(tcb, tcp_hdr),
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

    freeTcbWithLock(tcb);
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
            freeTcbWithLock(tcb);
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
    // RFC 7323: MUST clamp window scale to 14 if greater
    const raw_window = tcp_hdr.getWindow();
    tcb.snd_wnd = if (tcb.wscale_ok) blk: {
        const scale: u5 = if (tcb.snd_wscale > 14) inner: {
            console.warn("TCP: Illegal window scaling value {} > 14 received, using 14", .{tcb.snd_wscale});
            break :inner 14;
        } else @intCast(tcb.snd_wscale);
        break :blk @as(u32, raw_window) << scale;
    } else raw_window;

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
    // ACK must acknowledge our SYN (RFC 5961: send RST for out-of-window ACK)
    if (ack != tcb.iss +% 1) {
        // Security: Send RST for invalid ACK per RFC 5961 to prevent
        // ISN prediction attacks that use differential response as an oracle.
        _ = tx.sendRst(tcb);
        return true;
    }

    // Connection established
    tcb.snd_una = ack;
    tcb.state = .Established;
    if (state.half_open_count > 0) state.half_open_count -= 1;
    tcb.retrans_timer = 0;
    tcb.retrans_count = 0;

    // Add to parent's accept queue and wake blocked accept thread
    if (tcb.parent_socket) |parent_idx| {
        if (socket.queueAcceptConnection(parent_idx, tcb)) {
            // Successfully queued - wake any thread blocked on accept()
            if (socket.acquireSocket(parent_idx)) |parent_sock| {
                defer socket.releaseSocket(parent_sock);
                if (parent_sock.blocked_thread) |thread| {
                    socket.wakeThread(thread);
                    parent_sock.blocked_thread = null;
                }
            }
        } else {
            // Failed to queue (backlog full) - reject connection to prevent "zombie" TCB leak
            rejectUnqueuedConnection(tcb);
            return true;
        }
    } else {
        // No parent socket - drop the half-open connection and reset the peer
        rejectUnqueuedConnection(tcb);
        return true;
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
            // Security: Clamp acked_bytes to actual unacknowledged data to prevent
            // an attacker from inflating cwnd via crafted ACK numbers.
            // Real acked bytes cannot exceed (snd_nxt - old_snd_una).
            const max_ackable = tcb.snd_nxt -% tcb.snd_una;
            const acked_bytes = @min(ack -% tcb.snd_una, max_ackable);
            if (tcb.cwnd < tcb.ssthresh) {
                // Slow Start: use saturating add to prevent overflow
                tcb.cwnd = std.math.add(u32, tcb.cwnd, @min(acked_bytes, tcb.mss)) catch std.math.maxInt(u32);
            } else {
                // Congestion Avoidance
                // Increment approx 1 MSS per RTT: cwnd += MSS * MSS / cwnd
                // We use max(1, ...) to ensure forward progress
                const inc = @max(1, (@as(u64, tcb.mss) * tcb.mss) / tcb.cwnd);
                // Clamp increment to u32 range before adding (saturating arithmetic)
                const inc_clamped: u32 = if (inc > std.math.maxInt(u32)) std.math.maxInt(u32) else @truncate(inc);
                tcb.cwnd = std.math.add(u32, tcb.cwnd, inc_clamped) catch std.math.maxInt(u32);
            }

            const real_acked = ack -% tcb.snd_una;
            tcb.snd_una = ack;
            // Update send_tail to free up buffer space
            tcb.send_tail = (tcb.send_tail + real_acked) % c.BUFFER_SIZE;
            // Stop retransmit timer if all data acked
            if (tcb.snd_una == tcb.snd_nxt) {
                tcb.retrans_timer = 0;
            }
        }
    }

    // Update send window - apply window scaling if negotiated (RFC 7323)
    // Update send window - RFC 793 Window Update
    // SND.WND is updated if:
    // SND.WL1 < SEG.SEQ  or
    // SND.WL1 = SEG.SEQ and SND.WL2 <= SEG.ACK
    //
    // Fixed: strictly require ACK flag to be present to update window variables
    // derived from ACK field (snd_wl2).
    const seq = tcp_hdr.getSeqNum();
    var update_window = false;

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (seqGt(seq, tcb.snd_wl1) or (seq == tcb.snd_wl1 and seqGte(ack, tcb.snd_wl2))) {
            update_window = true;
            tcb.snd_wl2 = ack; // Update WL2 inside loop
        }
    }
    
    if (update_window) {
        const raw_window = tcp_hdr.getWindow();
        tcb.snd_wnd = if (tcb.wscale_ok) blk: {
            const scale: u5 = @min(tcb.snd_wscale, 14);
            break :blk @as(u32, raw_window) << scale;
        } else raw_window;
        
        tcb.snd_wl1 = seq;
        // tcb.snd_wl2 updated above
    }

    // Process incoming data
    const data_offset = tcp_hdr.getDataOffset();
    const ip_hdr = pkt.ipHeader();
    const ip_payload_len = ip_hdr.getTotalLength() - ip_hdr.getHeaderLength();

    if (ip_payload_len > data_offset) {
        const data_len = ip_payload_len - data_offset;
        const data_start = pkt.transport_offset + data_offset;

        // Validate calculated offsets against actual packet buffer bounds
        // Prevents out-of-bounds access from crafted header length fields
        if (data_start > pkt.len or data_len > pkt.len - data_start) {
            return false; // Malformed packet - header claims more data than buffer contains
        }

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

            // Security: Use checked cast to prevent overflow from large reassembled packets
            const copy_len_u32: u32 = std.math.cast(u32, copy_len) orelse {
                return false; // Reject oversized segment
            };
            tcb.rcv_nxt +%= copy_len_u32;

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
            freeTcbWithLock(tcb);
        }
    }
    return true;
}

/// Process packet in FIN-WAIT-1 state (we sent FIN, waiting for ACK and peer's FIN)
fn processFinWait1(tcb: *Tcb, tcp_hdr: *TcpHeader) bool {
    const has_ack = tcp_hdr.hasFlag(TcpHeader.FLAG_ACK);
    const has_fin = tcp_hdr.hasFlag(TcpHeader.FLAG_FIN);

    // Process ACK of our FIN
    if (has_ack) {
        const ack = tcp_hdr.getAckNum();
        if (ack == tcb.snd_nxt) {
            // Our FIN has been ACKed
            if (has_fin) {
                // Simultaneous close: peer also sent FIN
                // FIN-WAIT-1 + FIN + ACK -> TIME-WAIT
                tcb.rcv_nxt +%= 1; // Peer's FIN consumes one seq
                tcb.state = .TimeWait;
                tcb.retrans_timer = 0;
                // Start 2*MSL timer (simplified: use created_at for timeout tracking)
                tcb.created_at = state.connection_timestamp;
                _ = tx.sendAck(tcb);
            } else {
                // Only our FIN ACKed -> FIN-WAIT-2
                tcb.state = .FinWait2;
                tcb.retrans_timer = 0;
            }
            return true;
        }
    }

    // Process peer's FIN without ACK of our FIN (simultaneous close)
    if (has_fin) {
        tcb.rcv_nxt +%= 1;
        tcb.state = .Closing; // FIN-WAIT-1 + FIN (no ACK) -> CLOSING
        _ = tx.sendAck(tcb);
    }

    return true;
}

/// Process packet in FIN-WAIT-2 state (our FIN ACKed, waiting for peer's FIN)
fn processFinWait2(tcb: *Tcb, tcp_hdr: *TcpHeader) bool {
    // Waiting for peer's FIN
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_FIN)) {
        tcb.rcv_nxt +%= 1;
        tcb.state = .TimeWait;
        tcb.created_at = state.connection_timestamp; // Start 2*MSL timer
        _ = tx.sendAck(tcb);
    }
    return true;
}

/// Process packet in CLOSING state (both sent FIN, waiting for ACK of our FIN)
fn processClosing(tcb: *Tcb, tcp_hdr: *TcpHeader) bool {
    // Waiting for ACK of our FIN
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (ack == tcb.snd_nxt) {
            // Our FIN ACKed -> TIME-WAIT
            tcb.state = .TimeWait;
            tcb.retrans_timer = 0;
            tcb.created_at = state.connection_timestamp; // Start 2*MSL timer
        }
    }
    return true;
}

/// Process packet in TIME-WAIT state (both FINs exchanged, waiting 2*MSL)
fn processTimeWait(tcb: *Tcb, tcp_hdr: *TcpHeader) bool {
    // Security (RFC 5961): In TIME-WAIT, RST is only accepted if SEQ == RCV.NXT exactly.
    // This prevents TIME_WAIT assassination attacks where an attacker sends RST
    // to prematurely close TIME_WAIT, allowing port reuse for connection hijacking.
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) {
        const seq = tcp_hdr.getSeqNum();
        if (seq == tcb.rcv_nxt) {
            // Exact match - accept RST
            tcb.state = .Closed;
            freeTcbWithLock(tcb);
            return true;
        }
        // RST with wrong sequence - silently ignore (don't send challenge ACK in TIME_WAIT)
        return true;
    }

    // In TIME-WAIT, we may receive retransmitted FINs - just ACK them
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_FIN)) {
        // Reset the 2*MSL timer
        tcb.created_at = state.connection_timestamp;
        _ = tx.sendAck(tcb);
    }
    // Note: TIME-WAIT timeout and TCB cleanup is handled by the timer tick function
    return true;
}

/// Reject a connection we cannot queue by sending RST and freeing the TCB
fn rejectUnqueuedConnection(tcb: *Tcb) void {
    _ = tx.sendRst(tcb);
    freeTcbWithLock(tcb);
}
