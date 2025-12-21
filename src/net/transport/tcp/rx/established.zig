const std = @import("std");
const c = @import("../constants.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const tx = @import("../tx/root.zig");
const options = @import("../options.zig");
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
    var peer_opts = options.TcpOptions{};
    options.parseOptions(pkt, tcp_hdr, &peer_opts);

    if (tcb.sack_ok) {
        if (peer_opts.sack_block_count > 0) {
            updateSackBlocks(tcb, &peer_opts);
        } else if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
            tcb.sack_block_count = 0;
        }
    }

    if (tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        const ack = tcp_hdr.getAckNum();
        if (seqGt(ack, tcb.snd_una) and seqLte(ack, tcb.snd_nxt)) {
            tcb.dup_ack_count = 0;
            tcb.last_ack = ack;

            if (tcb.fast_recovery) {
                if (seqGte(ack, tcb.recover)) {
                    // Full ACK: exit fast recovery
                    tcb.fast_recovery = false;
                    tcb.cwnd = tcb.ssthresh;
                } else {
                    // Partial ACK: retransmit next segment and deflate cwnd
                    _ = tx.retransmitLoss(tcb);
                    tcb.cwnd = tcb.ssthresh + @as(u32, tcb.mss);
                }
            }

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
            trimSackBlocks(tcb);
            _ = tx.transmitPendingData(tcb);
        } else if (ack == tcb.snd_una) {
            const data_offset = tcp_hdr.getDataOffset();
            const ip_hdr = packet.getIpv4Header(pkt.data, pkt.ip_offset) orelse return .Continue;
            const ip_total_len = ip_hdr.getTotalLength();
            const ip_header_len = ip_hdr.getHeaderLength();
            if (ip_total_len < ip_header_len) return .Continue;
            const ip_payload_len = ip_total_len - ip_header_len;
            const has_data = ip_payload_len > data_offset;
            const is_pure_ack = !has_data and !tcp_hdr.hasFlag(TcpHeader.FLAG_SYN) and !tcp_hdr.hasFlag(TcpHeader.FLAG_FIN);

            if (is_pure_ack) {
                tcb.dup_ack_count +%= 1;

                if (tcb.fast_recovery) {
                    tcb.cwnd = std.math.add(u32, tcb.cwnd, tcb.mss) catch std.math.maxInt(u32);
                    _ = tx.transmitPendingData(tcb);
                } else if (tcb.dup_ack_count == 3) {
                    const flight = tcb.snd_nxt -% tcb.snd_una;
                    tcb.ssthresh = @max(flight / 2, @as(u32, tcb.mss) * 2);
                    tcb.cwnd = tcb.ssthresh + (@as(u32, tcb.mss) * 3);
                    tcb.fast_recovery = true;
                    tcb.recover = tcb.snd_nxt;
                    _ = tx.retransmitLoss(tcb);
                    if (tcb.retrans_timer == 0) {
                        tcb.retrans_timer = 1;
                    }
                }
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
    const ip_hdr = packet.getIpv4Header(pkt.data, pkt.ip_offset) orelse return .Continue;
    const ip_total_len = ip_hdr.getTotalLength();
    const ip_header_len = ip_hdr.getHeaderLength();
    if (ip_total_len < ip_header_len) return .Continue;
    const ip_payload_len = ip_total_len - ip_header_len;

    var delivered_data = false;

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
                    delivered_data = copy_len > 0;

                    if (copy_len > 0 and !delivered_async) {
                        if (tcb.blocked_thread) |thread| {
                            socket.wakeThread(thread);
                            tcb.blocked_thread = null;
                        }
                    }
                    if (drainOutOfOrder(tcb)) {
                        delivered_data = true;
                    }
                } else {
                    if (storeOutOfOrder(tcb, seq, data)) {
                        scheduleAck(tcb, true);
                    } else {
                        scheduleAck(tcb, true);
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

        tcb.ack_pending = false;
        tcb.ack_due = 0;
        _ = tx.sendAck(tcb);
        return .Continue;
    }

    if (delivered_data or tcp_hdr.hasFlag(TcpHeader.FLAG_SYN)) {
        scheduleAck(tcb, false);
    }

    return .Continue;
}

fn scheduleAck(tcb: *Tcb, immediate: bool) void {
    if (immediate) {
        tcb.ack_pending = false;
        tcb.ack_due = 0;
        _ = tx.sendAck(tcb);
        return;
    }

    if (!tcb.ack_pending) {
        tcb.ack_pending = true;
        tcb.ack_due = state.connection_timestamp + c.TCP_DELAYED_ACK_MS;
    } else {
        tcb.ack_pending = false;
        tcb.ack_due = 0;
        _ = tx.sendAck(tcb);
    }
}

fn updateSackBlocks(tcb: *Tcb, opts: *const options.TcpOptions) void {
    tcb.sack_block_count = opts.sack_block_count;
    var i: usize = 0;
    while (i < tcb.sack_block_count) : (i += 1) {
        const block = opts.sack_blocks[i];
        if (seqLt(block.start, block.end)) {
            tcb.sack_blocks[i] = block;
        } else {
            tcb.sack_blocks[i] = .{ .start = 0, .end = 0 };
        }
    }
}

fn trimSackBlocks(tcb: *Tcb) void {
    var count: u8 = 0;
    var i: usize = 0;
    while (i < tcb.sack_block_count) : (i += 1) {
        const block = tcb.sack_blocks[i];
        if (seqGte(block.end, tcb.snd_una) and seqLt(block.start, tcb.snd_nxt)) {
            tcb.sack_blocks[count] = block;
            count += 1;
        }
    }
    tcb.sack_block_count = count;
}

fn storeOutOfOrder(tcb: *Tcb, seq: u32, data: []const u8) bool {
    if (data.len == 0 or data.len > c.MAX_TCP_PAYLOAD) return false;
    if (tcb.ooo_count >= tcb.ooo_blocks.len) return false;

    const data_len_u32: u32 = @intCast(data.len);
    const end = seq +% data_len_u32;

    var i: usize = 0;
    while (i < tcb.ooo_count) : (i += 1) {
        const block = tcb.ooo_blocks[i];
        if (block.len == 0) continue;
        const block_end = block.start +% @as(u32, block.len);
        const overlaps = !(seqGte(seq, block_end) or seqGte(block.start, end));
        if (overlaps) {
            return false;
        }
    }

    var new_block = &tcb.ooo_blocks[tcb.ooo_count];
    new_block.start = seq;
    new_block.len = @intCast(data.len);
    @memcpy(new_block.data[0..data.len], data);
    tcb.ooo_count += 1;

    updateRcvSackBlocks(tcb);
    return true;
}

fn drainOutOfOrder(tcb: *Tcb) bool {
    var delivered = false;

    while (true) {
        var match_index: ?usize = null;
        var i: usize = 0;
        while (i < tcb.ooo_count) : (i += 1) {
            if (tcb.ooo_blocks[i].start == tcb.rcv_nxt) {
                match_index = i;
                break;
            }
        }

        if (match_index == null) break;
        const idx = match_index.?;
        const block = tcb.ooo_blocks[idx];
        if (block.len == 0) break;

        const available = tcb.recvBufferAvailable();
        const space = if (available >= c.BUFFER_SIZE) 0 else c.BUFFER_SIZE - available;
        if (block.len > space) break;

        var j: usize = 0;
        while (j < block.len) : (j += 1) {
            tcb.recv_buf[tcb.recv_head] = block.data[j];
            tcb.recv_head = (tcb.recv_head + 1) % c.BUFFER_SIZE;
        }

        tcb.rcv_nxt +%= @as(u32, block.len);
        delivered = true;

        tcb.ooo_blocks[idx] = tcb.ooo_blocks[tcb.ooo_count - 1];
        tcb.ooo_blocks[tcb.ooo_count - 1].len = 0;
        tcb.ooo_count -= 1;
    }

    updateRcvSackBlocks(tcb);
    return delivered;
}

fn updateRcvSackBlocks(tcb: *Tcb) void {
    tcb.rcv_sack_block_count = 0;
    if (!tcb.sack_ok or tcb.ooo_count == 0) return;

    var i: usize = 0;
    while (i < tcb.ooo_count and tcb.rcv_sack_block_count < tcb.rcv_sack_blocks.len) : (i += 1) {
        const block = tcb.ooo_blocks[i];
        if (block.len == 0) continue;
        tcb.rcv_sack_blocks[tcb.rcv_sack_block_count] = .{
            .start = block.start,
            .end = block.start +% @as(u32, block.len),
        };
        tcb.rcv_sack_block_count += 1;
    }
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
