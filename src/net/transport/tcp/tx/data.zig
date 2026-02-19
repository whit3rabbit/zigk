const std = @import("std");
const c = @import("../constants.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const segment = @import("segment.zig");
const packet = @import("../../../core/packet.zig");
const ipv4 = @import("../../../ipv4/root.zig").ipv4;
const pmtu6 = @import("../../../ipv6/pmtu.zig");

const PacketBuffer = packet.PacketBuffer;
const TcpHeader = types.TcpHeader;
const Tcb = types.Tcb;
const seqLt = types.seqLt;
const seqBetween = types.seqBetween;

/// Calculate segment length (data + SYN/FIN each count as 1)
pub fn calculateSegmentLength(pkt: *const PacketBuffer, tcp_hdr: *const TcpHeader) u32 {
    const data_offset = tcp_hdr.getDataOffset();
    const ip_hdr = pkt.ipHeaderUnsafe();
    const total_len = ip_hdr.getTotalLength();
    const hdr_len = ip_hdr.getHeaderLength();
    const ip_payload_len = if (total_len >= hdr_len) total_len - hdr_len else 0;

    var len: u32 = 0;
    if (ip_payload_len > data_offset) {
        len = @as(u32, @truncate(ip_payload_len - data_offset));
    }

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_SYN)) len += 1;
    if (tcp_hdr.hasFlag(TcpHeader.FLAG_FIN)) len += 1;

    return len;
}

/// Transmit pending data from send buffer
pub fn transmitPendingData(tcb: *Tcb) bool {
    if (tcb.state != .Established and tcb.state != .CloseWait) {
        return false;
    }

    const buffered = if (tcb.send_head >= tcb.send_tail)
        tcb.send_head - tcb.send_tail
    else
        c.BUFFER_SIZE - tcb.send_tail + tcb.send_head;

    if (buffered == 0) return true;

    // Get effective MSS based on PMTU for the connection's address family
    const pmtu_mss = if (tcb.isIpv6())
        pmtu6.getEffectiveMss6(tcb.remote_addr.v6)
    else
        ipv4.getEffectiveMss(tcb.getRemoteIpV4());
    const effective_mss = @min(tcb.mss, pmtu_mss);

    const eff_wnd = @min(@as(u32, tcb.snd_wnd), tcb.cwnd);

    const flight_size = tcb.snd_nxt -% tcb.snd_una;
    if (flight_size >= eff_wnd) {
        // Window full or zero -- persist timer in processTimers() handles zero-window probes.
        return true;
    }

    const available = eff_wnd - flight_size;

    const max_send = @min(available, @as(u32, effective_mss));
    const send_len = @min(buffered, max_send);

    // Nagle's algorithm (RFC 896): coalesce small writes when data is in flight.
    if (!tcb.nodelay and flight_size > 0 and send_len < effective_mss) {
        return true;
    }

    // RFC 1122 S4.2.3.4 Sender SWS avoidance:
    // Do not send a segment unless it is a full MSS, covers at least half the
    // peer's advertised window, or exhausts all remaining data in the send buffer.
    // This is additive to Nagle -- Nagle gates on flight_size, SWS gates on segment size.
    const is_full_segment = send_len >= @as(usize, effective_mss);
    const half_wnd: usize = if (tcb.snd_wnd > 1) @as(usize, tcb.snd_wnd / 2) else 1;
    const is_half_window = send_len >= half_wnd;
    const is_last_data = send_len == buffered;
    if (!is_full_segment and !is_half_window and !is_last_data) {
        return true; // Hold back: sender SWS avoidance
    }

    if (send_len == 0) return true;

    var data_buf: [c.MAX_TCP_PAYLOAD]u8 = [_]u8{0} ** c.MAX_TCP_PAYLOAD;
    for (0..send_len) |i| {
        const idx = (tcb.send_tail + i) % c.BUFFER_SIZE;
        data_buf[i] = tcb.send_buf[idx];
    }

    if (tcb.rtt_seq == 0) {
        tcb.rtt_seq = tcb.snd_nxt +% @as(u32, @truncate(send_len));
        tcb.rtt_start = state.connection_timestamp;
    }

    if (segment.sendSegment(tcb, TcpHeader.FLAG_ACK | TcpHeader.FLAG_PSH, tcb.snd_nxt, tcb.rcv_nxt, data_buf[0..send_len])) {
        tcb.snd_nxt +%= @as(u32, @truncate(send_len));
        if (tcb.retrans_timer == 0) {
            tcb.retrans_timer = 1;
        }
        return true;
    }

    return false;
}

pub fn retransmitLoss(tcb: *Tcb) bool {
    const seq = selectRetransmitSeq(tcb);
    return retransmitFromSeq(tcb, seq);
}

pub fn retransmitFromSeq(tcb: *Tcb, seq: u32) bool {
    // RFC 6298 S5: Karn's Algorithm -- do not sample RTT on retransmitted segments
    tcb.rtt_seq = 0;

    const buffered = bufferedBytes(tcb);
    if (buffered == 0) return false;

    const offset: usize = @as(usize, seq -% tcb.snd_una);
    if (offset >= buffered) return false;

    const pmtu_mss = ipv4.getEffectiveMss(tcb.getRemoteIpV4());
    const effective_mss = @min(tcb.mss, pmtu_mss);
    const remaining = buffered - offset;
    const send_len = @min(remaining, @as(usize, effective_mss));
    if (send_len == 0) return false;

    var data_buf: [c.MAX_TCP_PAYLOAD]u8 = [_]u8{0} ** c.MAX_TCP_PAYLOAD;
    for (0..send_len) |i| {
        const idx = (tcb.send_tail + @as(usize, offset) + i) % c.BUFFER_SIZE;
        data_buf[i] = tcb.send_buf[idx];
    }

    if (segment.sendSegment(tcb, TcpHeader.FLAG_ACK, seq, tcb.rcv_nxt, data_buf[0..send_len])) {
        if (tcb.retrans_timer == 0) {
            tcb.retrans_timer = 1;
        }
        return true;
    }
    return false;
}

pub fn selectRetransmitSeq(tcb: *Tcb) u32 {
    if (!tcb.sack_ok or tcb.sack_block_count == 0) {
        return tcb.snd_una;
    }

    const pmtu_mss = ipv4.getEffectiveMss(tcb.getRemoteIpV4());
    const effective_mss = @min(tcb.mss, pmtu_mss);
    var seq = tcb.snd_una;

    while (seqLt(seq, tcb.snd_nxt)) {
        if (!seqCoveredBySack(tcb, seq)) {
            return seq;
        }
        seq +%= @as(u32, effective_mss);
    }

    return tcb.snd_una;
}

fn seqCoveredBySack(tcb: *const Tcb, seq: u32) bool {
    var i: usize = 0;
    while (i < tcb.sack_block_count) : (i += 1) {
        const block = tcb.sack_blocks[i];
        if (seqBetween(seq, block.start, block.end)) {
            return true;
        }
    }
    return false;
}

fn bufferedBytes(tcb: *const Tcb) usize {
    if (tcb.send_head >= tcb.send_tail) {
        return tcb.send_head - tcb.send_tail;
    }
    return c.BUFFER_SIZE - tcb.send_tail + tcb.send_head;
}
