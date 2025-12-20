const std = @import("std");
const c = @import("../constants.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const tx = @import("../tx/root.zig");
const socket = @import("../../socket.zig");

const packet = @import("../../../core/packet.zig");
const PacketBuffer = packet.PacketBuffer;
const TcpHeader = types.TcpHeader;
const Tcb = types.Tcb;
const RxAction = types.RxAction;

const seqLt = types.seqLt;
const seqLte = types.seqLte;
const seqGt = types.seqGt;
const seqGte = types.seqGte;

/// Process packet in ESTABLISHED state
pub fn processEstablished(tcb: *Tcb, pkt: *PacketBuffer, tcp_hdr: *TcpHeader) RxAction {
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
        const data_start = pkt.transport_offset + data_offset;

        if (data_start < pkt.len) {
            const max_available = pkt.len - data_start;
            const claimed_len = ip_payload_len - data_offset;
            const data_len = @min(claimed_len, max_available);

            if (data_len > 0) {
                const data = pkt.data[data_start..][0..data_len];

                if (seq == tcb.rcv_nxt) {
                    var delivered_async = false;
                    if (tcb.parent_socket) |sock_idx| {
                        if (socket.completePendingRecv(sock_idx, data)) {
                            delivered_async = true;
                        }
                    }

                    const copy_len = if (delivered_async) data_len else blk: {
                        const available = tcb.recvBufferAvailable();
                        const space = if (available >= c.BUFFER_SIZE) 0 else c.BUFFER_SIZE - available;
                        const len = @min(data_len, space);

                        for (0..len) |i| {
                            tcb.recv_buf[tcb.recv_head] = data[i];
                            tcb.recv_head = (tcb.recv_head + 1) % c.BUFFER_SIZE;
                        }
                        break :blk len;
                    };

                    const copy_len_u32: u32 = std.math.cast(u32, copy_len) orelse 0;
                    tcb.rcv_nxt +%= copy_len_u32;

                    if (copy_len > 0 and !delivered_async) {
                        if (tcb.blocked_thread) |thread| {
                            socket.wakeThread(thread);
                            tcb.blocked_thread = null;
                        }
                    }
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

pub fn processCloseWait(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (seqGt(ack, tcb.snd_una) and seqLte(ack, tcb.snd_nxt)) {
            tcb.snd_una = ack;
        }
    }
    return .Continue;
}

pub fn processLastAck(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (ack == tcb.snd_nxt) {
            tcb.state = .Closed;
            return .FreeTcb;
        }
    }
    return .Continue;
}

pub fn processFinWait1(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
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

pub fn processFinWait2(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_FIN)) {
        tcb.rcv_nxt +%= 1;
        tcb.state = .TimeWait;
        tcb.created_at = state.connection_timestamp;
        _ = tx.sendAck(tcb);
    }
    return .Continue;
}

pub fn processClosing(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
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

pub fn processTimeWait(tcb: *Tcb, tcp_hdr: *TcpHeader) RxAction {
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_RST)) {
        return .Continue;
    }

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_FIN)) {
        tcb.created_at = state.connection_timestamp;
        _ = tx.sendAck(tcb);
    }
    return .Continue;
}
