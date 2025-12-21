const std = @import("std");
const c = @import("../constants.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const options = @import("../options.zig");
const tx = @import("../tx/root.zig");
const socket = @import("../../socket.zig");
const console = @import("console");

const packet = @import("../../../core/packet.zig");
const PacketBuffer = packet.PacketBuffer;
const TcpHeader = types.TcpHeader;
const Tcb = types.Tcb;
const TcpOptions = options.TcpOptions;
const RxAction = types.RxAction;

/// Process packet in SYN-SENT state
pub fn processSynSent(tcb: *Tcb, pkt: *PacketBuffer, tcp_hdr: *TcpHeader) RxAction {
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
/// Caller must hold state.lock and tcb.mutex.
pub fn processSynReceivedLocked(tcb: *Tcb, tcp_hdr: *TcpHeader) bool {
    if (!tcp_hdr.hasFlag(TcpHeader.FLAG_ACK)) {
        return false;
    }

    const ack = tcp_hdr.getAckNum();
    if (ack != tcb.iss +% 1) {
        _ = tx.sendRst(tcb);
        return false;
    }

    tcb.snd_una = ack;
    // Remove from half-open list before transitioning state
    state.halfOpenListRemove(tcb);
    tcb.state = .Established;
    if (state.half_open_count > 0) state.half_open_count -= 1;
    tcb.retrans_timer = 0;
    tcb.retrans_count = 0;
    return true;
}
