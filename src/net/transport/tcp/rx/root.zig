const std = @import("std");
const c = @import("../constants.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const options = @import("../options.zig");
const tx = @import("../tx/root.zig");
const socket = @import("../../socket.zig");

const packet = @import("../../../core/packet.zig");
const Interface = @import("../../../core/interface.zig").Interface;
const PacketBuffer = packet.PacketBuffer;
const TcpHeader = types.TcpHeader;
const Tcb = types.Tcb;
const RxAction = types.RxAction;

pub const listen = @import("listen.zig");
pub const syn = @import("syn.zig");
pub const established = @import("established.zig");

/// TCP Input Processing Entry Point
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
    const calc_checksum = @import("../../../core/checksum.zig").tcpChecksum(pkt.src_ip, pkt.dst_ip, tcp_segment);

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

        const held = tcb.mutex.acquire();
        const expected_generation = tcb.generation;
        state.lock.release();

        const action = processEstablishedPacket(tcb, pkt, tcp_hdr);
        held.release();

        if (action == .FreeTcb) {
            state.lock.acquire();
            if (state.isTcbValid(tcb) and tcb.generation == expected_generation) {
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

        return listen.processListenPacket(iface, listen_tcb, pkt, tcp_hdr);
    }

    state.lock.release();
    _ = tx.sendRstForPacket(iface, pkt, tcp_hdr);
    return true;
}

/// Process packet for established (non-LISTEN) connections
fn processEstablishedPacket(tcb: *Tcb, pkt: *PacketBuffer, tcp_hdr: *TcpHeader) RxAction {
    const seq = tcp_hdr.getSeqNum();
    const seg_len = tx.calculateSegmentLength(pkt, tcp_hdr);
    const rcv_wnd = tcb.currentRecvWindow();

    var acceptable = false;

    var peer_opts = options.TcpOptions{};
    options.parseOptions(pkt, tcp_hdr, &peer_opts);

    if (tcb.ts_ok and tcp_hdr.hasFlag(TcpHeader.FLAG_ACK) and peer_opts.timestamp_present) {
        if (types.seqLt(peer_opts.ts_val, tcb.ts_recent)) {
             return .Continue;
        }
        if (types.seqLte(seq, tcb.rcv_nxt) and types.seqGt(seq +% seg_len, tcb.rcv_nxt)) {
            tcb.ts_recent = peer_opts.ts_val;
        }
    }

    if (seg_len == 0) {
        if (rcv_wnd == 0) {
            acceptable = (seq == tcb.rcv_nxt);
        } else {
            const dist = seq -% tcb.rcv_nxt;
            acceptable = (dist < @as(u32, rcv_wnd));
        }
    } else {
        if (rcv_wnd == 0) {
            acceptable = false;
        } else {
            const dist_start = seq -% tcb.rcv_nxt;
            const end_seq = seq +% seg_len -% 1;
            const dist_end = end_seq -% tcb.rcv_nxt;
            acceptable = (dist_start < @as(u32, rcv_wnd)) or (dist_end < @as(u32, rcv_wnd));
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
        .SynSent => return syn.processSynSent(tcb, pkt, tcp_hdr),
        .SynReceived => return syn.processSynReceived(tcb, tcp_hdr),
        .Established => return established.processEstablished(tcb, pkt, tcp_hdr),
        .FinWait1 => return established.processFinWait1(tcb, tcp_hdr),
        .FinWait2 => return established.processFinWait2(tcb, tcp_hdr),
        .CloseWait => return established.processCloseWait(tcb, tcp_hdr),
        .Closing => return established.processClosing(tcb, tcp_hdr),
        .LastAck => return established.processLastAck(tcb, tcp_hdr),
        .TimeWait => return established.processTimeWait(tcb, tcp_hdr),
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
