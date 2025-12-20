const std = @import("std");
const c = @import("../constants.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const options = @import("../options.zig");
const tx = @import("../tx/root.zig");
const console = @import("console");

const packet = @import("../../../core/packet.zig");
const PacketBuffer = packet.PacketBuffer;
const TcpHeader = types.TcpHeader;
const Tcb = types.Tcb;
const TcpOptions = options.TcpOptions;

/// Process packet for LISTEN state
pub fn processListenPacket(
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

    // SECURITY: Acquire state.lock BEFORE checking half-open count to prevent
    // race where multiple threads bypass the limit check simultaneously.
    // This ensures atomic check-and-allocate for SYN flood mitigation.
    var state_held = state.lock.acquire();

    if (state.countHalfOpen() >= c.MAX_HALF_OPEN) {
        if (!state.evictOldestHalfOpenTcbUnlocked()) {
            state_held.release();
            return false;
        }
    }

    // Allocate TCB (state.lock already held)
    const new_tcb = state.allocateTcb();
    if (new_tcb == null) {
        state_held.release();
        return false;
    }
    const tcb = new_tcb.?; // Unwrap
    // We hold state.lock currently. We can initialize TCB safely.

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
    // Insert into half-open list for O(1) SYN flood eviction
    state.halfOpenListInsert(tcb);

    // Insert into hash table (state.lock is held)
    state.insertTcbIntoHash(tcb);

    // Release state lock now that TCB is consistent and in hash
    state_held.release();

    if (!tx.sendSynAckWithOptions(tcb, &peer_opts)) {
        // Failed to send. Need to free TCB.
        const state_held_retry = state.lock.acquire();
        state.freeTcb(tcb);
        state_held_retry.release();
        return false;
    }

    tcb.retrans_timer = 1;

    return true;
}
