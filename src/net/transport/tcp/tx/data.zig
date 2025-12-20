const std = @import("std");
const c = @import("../constants.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const segment = @import("segment.zig");
const packet = @import("../../../core/packet.zig");
const ipv4 = @import("../../../ipv4/root.zig").ipv4;

const PacketBuffer = packet.PacketBuffer;
const TcpHeader = types.TcpHeader;
const Tcb = types.Tcb;

/// Calculate segment length (data + SYN/FIN each count as 1)
pub fn calculateSegmentLength(pkt: *const PacketBuffer, tcp_hdr: *const TcpHeader) u32 {
    const data_offset = tcp_hdr.getDataOffset();
    const ip_hdr = pkt.ipHeader();
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

    const pmtu_mss = ipv4.getEffectiveMss(tcb.remote_ip);
    const effective_mss = @min(tcb.mss, pmtu_mss);

    const eff_wnd = @min(@as(u32, tcb.snd_wnd), tcb.cwnd);

    const flight_size = tcb.snd_nxt -% tcb.snd_una;
    if (flight_size >= eff_wnd) {
        if (eff_wnd == 0 and buffered > 0) {
            if (tcb.retrans_timer == 0) {
                tcb.retrans_timer = 1; 
            }
            
            if (flight_size == 0) {
                 var data_buf: [1]u8 = undefined;
                 const idx = tcb.send_tail % c.BUFFER_SIZE;
                 data_buf[0] = tcb.send_buf[idx];
                 
                 if (segment.sendSegment(tcb, TcpHeader.FLAG_ACK | TcpHeader.FLAG_PSH, tcb.snd_nxt, tcb.rcv_nxt, &data_buf)) {
                    tcb.snd_nxt +%= 1;
                    return true;
                 }
            }
        }
        
        return true; 
    }

    const available = eff_wnd - flight_size;

    const max_send = @min(available, @as(u32, effective_mss));
    const send_len = @min(buffered, max_send);

    if (send_len == 0) return true;

    var data_buf: [c.MAX_TCP_PAYLOAD]u8 = undefined;
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
