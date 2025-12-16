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

const RxAction = enum {
    Continue,
    FreeTcb,
};

/// TCP Input Processing
//
//
// Complies with: - RFC 793: SEGMENT ARRIVAL (Section 3.9)
//
// Handles incoming TCP segments, state transitions, and data buffering.
// Implements the "SEGMENT ARRIVAL" event processing logic.
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
    const ip_total_len = ip_hdr.getTotalLength();
    const ip_header_len = ip_hdr.getHeaderLength();

    if (ip_total_len < ip_header_len) return false;

    const tcp_segment_len = ip_total_len - ip_header_len;

    if (pkt.transport_offset + tcp_segment_len > pkt.len) {
        return false;
    }

    const tcp_segment = pkt.data[pkt.transport_offset..][0..tcp_segment_len];
    const calc_checksum = @import("checksum.zig").tcpChecksum(pkt.src_ip, pkt.dst_ip, tcp_segment);

    if (calc_checksum != 0xFFFF) {
        return false; // Bad checksum
    }

    if (pkt.is_broadcast or pkt.is_multicast) {
        return false;
    }

    const local_ip = pkt.dst_ip;
    const local_port = tcp_hdr.getDstPort();
    const remote_ip = ip_hdr.getSrcIp();
    const remote_port = tcp_hdr.getSrcPort();

    state.lock.acquire();

    // Try established connection first
    if (state.findTcb(local_ip, local_port, remote_ip, remote_port)) |tcb| {
        if (tcb.closing) {
            state.lock.release();
            return false;
        }

        // Acquire TCB lock while holding state lock
        const held = tcb.mutex.acquire();
        state.lock.release();

        // Process packet with TCB lock held (state lock released)
        const action = processEstablishedPacket(tcb, pkt, tcp_hdr);
        held.release(); // Release TCB lock

        // Handle deferred cleanup
        if (action == .FreeTcb) {
            state.lock.acquire();
            // Verify TCB is still valid before freeing (prevent double-free)
            // Another thread (e.g. close()) might have beaten us to it
            if (state.isTcbValid(tcb)) {
                state.freeTcb(tcb);
            }
            state.lock.release();
        }

        return true;
    }

    // Try listening socket
    if (state.findListeningTcb(local_port, local_ip)) |listen_tcb| {
        if (listen_tcb.closing) {
            state.lock.release();
            return false;
        }

        const held = listen_tcb.mutex.acquire();
        state.lock.release();
        defer held.release();

        return processListenPacket(iface, listen_tcb, pkt, tcp_hdr);
    }

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

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) {
        return true;
    }

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        return true;
    }

    if (!tcp_hdr.hasFlag(TcpHeader.FLAG_SYN)) {
        return true;
    }

    if (state.countHalfOpen() >= c.MAX_HALF_OPEN) {
         if (!state.evictOldestHalfOpenTcb()) {
             return false;
         }
    }

    // Allocate TCB - MUST acquire state.lock as allocateTcb touches global pool
    state.lock.acquire();
    const new_tcb = state.allocateTcb();
    if (new_tcb == null) {
        state.lock.release();
        return false;
    }
    const tcb = new_tcb.?; // Unwrap
    // We hold state.lock currently. We can initialize TCB safely.
    // However, new_tcb is local until we insert into hash.

    const ip_hdr = pkt.ipHeader();
    tcb.local_ip = ip_hdr.getDstIp();
    tcb.local_port = tcp_hdr.getDstPort();
    tcb.remote_ip = ip_hdr.getSrcIp();
    tcb.remote_port = tcp_hdr.getSrcPort();

    tcb.irs = tcp_hdr.getSeqNum();
    tcb.rcv_nxt = tcb.irs +% 1;
    tcb.iss = state.generateIsn(tcb.local_ip, tcb.local_port, tcb.remote_ip, tcb.remote_port);
    tcb.snd_nxt = tcb.iss +% 1;
    tcb.snd_una = tcb.iss;

    tcb.snd_wnd = tcp_hdr.getWindow();

    var peer_opts = TcpOptions{};
    options.parseOptions(pkt, tcp_hdr, &peer_opts);

    tcb.mss = if (peer_opts.mss_present) peer_opts.mss else c.DEFAULT_MSS;
    if (peer_opts.wscale_present) {
        tcb.snd_wscale = peer_opts.wscale;
        tcb.wscale_ok = true;
    }

    if (peer_opts.sack_permitted) {
        tcb.sack_ok = true;
    }

    if (peer_opts.timestamp_present) {
        tcb.ts_ok = true;
        tcb.ts_recent = peer_opts.ts_val;
    }

    if (tcb.wscale_ok) {
        const scale: u5 = if (tcb.snd_wscale > 14) blk: {
            console.warn("TCP: Illegal window scaling value {} > 14 received, using 14", .{tcb.snd_wscale});
            break :blk 14;
        } else @intCast(tcb.snd_wscale);
        tcb.snd_wnd = @as(u32, tcb.snd_wnd) << scale;
    }

    tcb.parent_socket = listen_tcb.parent_socket;
    tcb.tos = listen_tcb.tos;
    tcb.state = .SynReceived;
    state.half_open_count += 1;

    // Insert into hash table (state.lock is held)
    state.insertTcbIntoHash(tcb);

    // Release state lock now that TCB is consistent and in hash
    state.lock.release();

    if (!tx.sendSynAckWithOptions(tcb, &peer_opts)) {
        // Failed to send. Need to free TCB.
        state.lock.acquire();
        state.freeTcb(tcb);
        state.lock.release();
        return false;
    }

    tcb.retrans_timer = 1;

    return true;
}

/// Process packet for established (non-LISTEN) connections
fn processEstablishedPacket(tcb: *Tcb, pkt: *PacketBuffer, tcp_hdr: *TcpHeader) RxAction {
    const seq = tcp_hdr.getSeqNum();
    const seg_len = tx.calculateSegmentLength(pkt, tcp_hdr);
    const rcv_wnd = tcb.currentRecvWindow();

    var acceptable = false;

    var peer_opts = TcpOptions{};
    options.parseOptions(pkt, tcp_hdr, &peer_opts);

    if (tcb.ts_ok and tcp_hdr.hasFlag(TcpHeader.FLAG_ACK) and peer_opts.timestamp_present) {
        if (seqLt(peer_opts.ts_val, tcb.ts_recent)) {
             return .Continue;
        }
        if (seqLte(seq, tcb.rcv_nxt) and seqGt(seq +% seg_len, tcb.rcv_nxt)) {
            tcb.ts_recent = peer_opts.ts_val;
        }
    }

    if (seg_len == 0) {
        if (rcv_wnd == 0) {
            acceptable = (seq == tcb.rcv_nxt);
        } else {
            const dist = seq -% tcb.rcv_nxt;
            acceptable = (dist < rcv_wnd);
        }
    } else {
        if (rcv_wnd == 0) {
            acceptable = false;
        } else {
            const dist_start = seq -% tcb.rcv_nxt;
            const end_seq = seq +% seg_len -% 1;
            const dist_end = end_seq -% tcb.rcv_nxt;
            acceptable = (dist_start < rcv_wnd) or (dist_end < rcv_wnd);
        }
    }

    if (!acceptable) {
        if (!tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) {
            _ = tx.sendAck(tcb);
        } else {
             if (seq != tcb.rcv_nxt) {
                 _ = tx.sendAck(tcb);
                 return .Continue;
             }
        }
        return .Continue;
    }

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) {
        if (seq == tcb.rcv_nxt) {
            return handleRst(tcb);
        } else {
            _ = tx.sendAck(tcb);
            return .Continue;
        }
    }

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
        else => return .Continue,
    }
}

/// Handle RST segment
fn handleRst(tcb: *Tcb) RxAction {
    tcb.state = .Closed;

    if (tcb.blocked_thread) |thread| {
        socket.wakeThread(thread);
        tcb.blocked_thread = null;
    }

    return .FreeTcb;
}

/// Process packet in SYN-SENT state
fn processSynSent(tcb: *Tcb, pkt: *PacketBuffer, tcp_hdr: *TcpHeader) RxAction {
    if (!tcp_hdr.hasFlag(TcpHeader.FLAG_SYN)) {
        return .Continue;
    }

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (ack != tcb.iss +% 1) {
            _ = tx.sendRst(tcb);
            tcb.state = .Closed;
            if (tcb.parent_socket) |sock_idx| {
                _ = socket.completePendingConnect(sock_idx, false);
            }
            if (tcb.blocked_thread) |thread| {
                socket.wakeThread(thread);
                tcb.blocked_thread = null;
            }
            return .FreeTcb;
        }
        tcb.snd_una = ack;
    }

    tcb.irs = tcp_hdr.getSeqNum();
    tcb.rcv_nxt = tcb.irs +% 1;

    var peer_opts = TcpOptions{};
    options.parseOptions(pkt, tcp_hdr, &peer_opts);

    if (peer_opts.mss_present) {
        tcb.mss = peer_opts.mss;
    }

    if (peer_opts.wscale_present and tcb.rcv_wscale > 0) {
        tcb.snd_wscale = peer_opts.wscale;
        tcb.wscale_ok = true;
    } else {
        tcb.snd_wscale = 0;
        tcb.rcv_wscale = 0;
        tcb.wscale_ok = false;
    }

    if (peer_opts.sack_permitted) {
        tcb.sack_ok = true;
    }

    if (peer_opts.timestamp_present) {
        tcb.ts_ok = true;
        tcb.ts_recent = peer_opts.ts_val;
    }

    const raw_window = tcp_hdr.getWindow();
    tcb.snd_wnd = if (tcb.wscale_ok) blk: {
        const scale: u5 = if (tcb.snd_wscale > 14) inner: {
            console.warn("TCP: Illegal window scaling value {} > 14 received, using 14", .{tcb.snd_wscale});
            break :inner 14;
        } else @intCast(tcb.snd_wscale);
        break :blk @as(u32, raw_window) << scale;
    } else raw_window;

    tcb.state = .Established;
    tcb.retrans_timer = 0;
    tcb.retrans_count = 0;

    if (tcb.parent_socket) |sock_idx| {
        _ = socket.completePendingConnect(sock_idx, true);
    }

    if (tcb.blocked_thread) |thread| {
        socket.wakeThread(thread);
        tcb.blocked_thread = null;
    }

    _ = tx.sendAck(tcb);

    return .Continue;
}

/// Process packet in SYN-RECEIVED state
fn processSynReceived(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
    if (!tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        return .Continue;
    }

    const ack = tcp_hdr.getAckNum();
    if (ack != tcb.iss +% 1) {
        _ = tx.sendRst(tcb);
        return .Continue;
    }

    tcb.snd_una = ack;
    tcb.state = .Established;
    if (state.half_open_count > 0) state.half_open_count -= 1;
    tcb.retrans_timer = 0;
    tcb.retrans_count = 0;

    if (tcb.parent_socket) |parent_idx| {
        if (socket.completePendingAccept(parent_idx, tcb)) {
            return .Continue;
        }

        if (socket.queueAcceptConnection(parent_idx, tcb)) {
            if (socket.acquireSocket(parent_idx)) |parent_sock| {
                defer socket.releaseSocket(parent_sock);
                if (parent_sock.blocked_thread) |thread| {
                    socket.wakeThread(thread);
                    parent_sock.blocked_thread = null;
                }
            }
        } else {
            rejectUnqueuedConnection(tcb);
            return .FreeTcb;
        }
    } else {
        rejectUnqueuedConnection(tcb);
        return .FreeTcb;
    }

    return .Continue;
}

/// Process packet in ESTABLISHED state
fn processEstablished(tcb: *Tcb, pkt: *PacketBuffer, tcp_hdr: *TcpHeader) RxAction {
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (seqGt(ack, tcb.snd_una) and seqLte(ack, tcb.snd_nxt)) {
            if (tcb.rtt_seq != 0 and seqGte(ack, tcb.rtt_seq)) {
                const now = state.connection_timestamp;
                if (now >= tcb.rtt_start) {
                    const rtt_sample: u32 = @intCast(now - tcb.rtt_start);
                    tcb.updateRto(rtt_sample);
                }
                tcb.rtt_seq = 0;
            }

            const max_ackable = tcb.snd_nxt -% tcb.snd_una;
            const acked_bytes = @min(ack -% tcb.snd_una, max_ackable);
            if (tcb.cwnd < tcb.ssthresh) {
                tcb.cwnd = std.math.add(u32, tcb.cwnd, @min(acked_bytes, tcb.mss)) catch std.math.maxInt(u32);
            } else {
                const inc = @max(1, (@as(u64, tcb.mss) * tcb.mss) / tcb.cwnd);
                const inc_clamped: u32 = if (inc > std.math.maxInt(u32)) std.math.maxInt(u32) else @truncate(inc);
                tcb.cwnd = std.math.add(u32, tcb.cwnd, inc_clamped) catch std.math.maxInt(u32);
            }

            const real_acked = ack -% tcb.snd_una;
            tcb.snd_una = ack;
            tcb.send_tail = (tcb.send_tail + real_acked) % c.BUFFER_SIZE;
            if (tcb.snd_una == tcb.snd_nxt) {
                tcb.retrans_timer = 0;
            }
        }
    }

    const seq = tcp_hdr.getSeqNum();
    var update_window = false;

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (seqGt(seq, tcb.snd_wl1) or (seq == tcb.snd_wl1 and seqGte(ack, tcb.snd_wl2))) {
            update_window = true;
            tcb.snd_wl2 = ack;
        }
    }
    
    if (update_window) {
        const raw_window = tcp_hdr.getWindow();
        tcb.snd_wnd = if (tcb.wscale_ok) blk: {
            const scale: u5 = @min(tcb.snd_wscale, 14);
            break :blk @as(u32, raw_window) << scale;
        } else raw_window;
        
        tcb.snd_wl1 = seq;
    }

    const data_offset = tcp_hdr.getDataOffset();
    const ip_hdr = pkt.ipHeader();
    const ip_payload_len = ip_hdr.getTotalLength() - ip_hdr.getHeaderLength();

    if (ip_payload_len > data_offset) {
        const data_len = ip_payload_len - data_offset;
        const data_start = pkt.transport_offset + data_offset;

        if (data_start > pkt.len or data_len > pkt.len - data_start) {
            return .Continue;
        }

        const data = pkt.data[data_start..][0..data_len];

        if (seq == tcb.rcv_nxt) {
            var delivered_async = false;
            if (tcb.parent_socket) |sock_idx| {
                if (socket.completePendingRecv(sock_idx, data)) {
                    delivered_async = true;
                }
            }

            const copy_len = if (delivered_async) data_len else blk: {
                const space = c.BUFFER_SIZE - tcb.recvBufferAvailable();
                const len = @min(data_len, space);

                for (0..len) |i| {
                    tcb.recv_buf[tcb.recv_head] = data[i];
                    tcb.recv_head = (tcb.recv_head + 1) % c.BUFFER_SIZE;
                }
                break :blk len;
            };

            const copy_len_u32: u32 = std.math.cast(u32, copy_len) orelse {
                return .Continue;
            };
            tcb.rcv_nxt +%= copy_len_u32;

            if (copy_len > 0 and !delivered_async) {
                if (tcb.blocked_thread) |thread| {
                    socket.wakeThread(thread);
                    tcb.blocked_thread = null;
                }
            }
        }
    }

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_FIN)) {
        tcb.rcv_nxt +%= 1;
        tcb.state = .CloseWait;

        if (tcb.blocked_thread) |thread| {
            socket.wakeThread(thread);
            tcb.blocked_thread = null;
        }

        _ = tx.sendAck(tcb);
        return .Continue;
    }

    if (ip_payload_len > data_offset or tcp_hdr.hasFlag(TcpHeader.FLAG_SYN)) {
        _ = tx.sendAck(tcb);
    }

    return .Continue;
}

fn processCloseWait(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (seqGt(ack, tcb.snd_una) and seqLte(ack, tcb.snd_nxt)) {
            tcb.snd_una = ack;
        }
    }
    return .Continue;
}

fn processLastAck(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (ack == tcb.snd_nxt) {
            tcb.state = .Closed;
            return .FreeTcb;
        }
    }
    return .Continue;
}

fn processFinWait1(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
    const has_ack = tcp_hdr.hasFlag(TcpHeader.FLAG_ACK);
    const has_fin = tcp_hdr.hasFlag(TcpHeader.FLAG_FIN);

    if (has_ack) {
        const ack = tcp_hdr.getAckNum();
        if (ack == tcb.snd_nxt) {
            if (has_fin) {
                tcb.rcv_nxt +%= 1;
                tcb.state = .TimeWait;
                tcb.retrans_timer = 0;
                tcb.created_at = state.connection_timestamp;
                _ = tx.sendAck(tcb);
            } else {
                tcb.state = .FinWait2;
                tcb.retrans_timer = 0;
            }
            return .Continue;
        }
    }

    if (has_fin) {
        tcb.rcv_nxt +%= 1;
        tcb.state = .Closing;
        _ = tx.sendAck(tcb);
    }

    return .Continue;
}

fn processFinWait2(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_FIN)) {
        tcb.rcv_nxt +%= 1;
        tcb.state = .TimeWait;
        tcb.created_at = state.connection_timestamp;
        _ = tx.sendAck(tcb);
    }
    return .Continue;
}

fn processClosing(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (ack == tcb.snd_nxt) {
            tcb.state = .TimeWait;
            tcb.retrans_timer = 0;
            tcb.created_at = state.connection_timestamp;
        }
    }
    return .Continue;
}

fn processTimeWait(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) {
        const seq = tcp_hdr.getSeqNum();
        if (seq == tcb.rcv_nxt) {
            tcb.state = .Closed;
            return .FreeTcb;
        }
        return .Continue;
    }

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_FIN)) {
        tcb.created_at = state.connection_timestamp;
        _ = tx.sendAck(tcb);
    }
    return .Continue;
}

fn rejectUnqueuedConnection(tcb: *Tcb) void {
    _ = tx.sendRst(tcb);
    // Caller returns .FreeTcb
}
