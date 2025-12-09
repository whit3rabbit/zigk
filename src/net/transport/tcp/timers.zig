const c = @import("constants.zig");
const state = @import("state.zig");
const tx = @import("tx.zig");

const socket = @import("../socket.zig");

/// Check and process timers (called from timer tick, assumed ~1ms per call)
/// Handles retransmission and state-based connection timeouts
pub fn processTimers() void {
    state.lock.acquire();
    defer state.lock.release();

    // Advance timestamp counter (assumes ~1ms per tick)
    state.connection_timestamp +%= 1;

    for (&state.tcb_pool) |*tcb| {
        if (!tcb.allocated) continue;

        // Check state-based timeout (garbage collection)
        const state_timeout = getStateTimeout(tcb.state);
        if (state_timeout > 0) {
            const age = state.connection_timestamp -% tcb.created_at;
            if (age > state_timeout) {
                // Connection timed out in this state - clean up
                tcb.state = .Closed;
                // Wake thread blocked on this connection
                if (tcb.blocked_thread) |thread| {
                    socket.wakeThread(thread);
                    tcb.blocked_thread = null;
                }
                state.freeTcb(tcb);
                continue;
            }
        }

        // Process retransmission timer
        if (tcb.retrans_timer == 0) continue;

        // Simplified: retransmit every RTO ticks
        tcb.retrans_timer +%= 1;

        if (tcb.retrans_timer > tcb.rto_ms) {
            // Retransmit timeout
            tcb.retrans_count += 1;

            if (tcb.retrans_count >= c.MAX_RETRIES) {
                // Too many retries - reset connection
                tcb.state = .Closed;
                // Wake thread blocked on this connection (connect/recv timeout)
                if (tcb.blocked_thread) |thread| {
                    socket.wakeThread(thread);
                    tcb.blocked_thread = null;
                }
                state.freeTcb(tcb);
                continue;
            }

            // Exponential backoff
            tcb.rto_ms = @min(tcb.rto_ms * 2, c.MAX_RTO_MS);
            tcb.retrans_timer = 1;

            // Congestion Control: Loss detected -> Collapse cwnd
            const flight_size = tcb.snd_nxt -% tcb.snd_una;
            tcb.ssthresh = @max(flight_size / 2, @as(u32, tcb.mss) * 2);
            tcb.cwnd = tcb.mss;

            // Retransmit based on state
            switch (tcb.state) {
                .SynSent => _ = tx.sendSyn(tcb),
                .SynReceived => _ = tx.sendSynAck(tcb),
                .Established, .CloseWait => {
                    // Retransmit oldest unacked segment (Go-Back-N style simplified)
                    tcb.snd_nxt = tcb.snd_una;
                    _ = tx.transmitPendingData(tcb);
                },
                .LastAck => _ = tx.sendFin(tcb),
                else => {},
            }
        }
    }
}

/// Handle ICMP error for a connection
pub fn handleIcmpError(local_ip: u32, local_port: u16, remote_ip: u32, remote_port: u16, icmp_type: u8, icmp_code: u8) void {
    state.lock.acquire();
    defer state.lock.release();

    const tcb = state.findTcb(local_ip, local_port, remote_ip, remote_port) orelse return;

    // Only handle Destination Unreachable for now
    if (icmp_type != 3) return;

    const is_hard_error = switch (icmp_code) {
        // Net/Host unreachable are "soft" errors (transient routing issues)
        0, 1 => false,
        // Proto/Port unreachable are "hard" errors (permanent)
        2, 3 => true,
        // Fragmentation needed - PMTU cache updated, not a connection error
        4 => false,
        else => false,
    };

    // Connection Setup Phase: All Unreachables are hard errors
    if (tcb.state == .SynSent or tcb.state == .SynReceived) {
        // Abort connection
        tcb.state = .Closed;
        // Wake blocked connect()
        if (tcb.blocked_thread) |thread| {
            socket.wakeThread(thread);
            tcb.blocked_thread = null;
        }
        state.freeTcb(tcb);
        return;
    }

    // Established Phase: Only hard errors reset connection
    if ((tcb.state == .Established or tcb.state == .CloseWait) and is_hard_error) {
        // Abort connection
        tcb.state = .Closed;
        if (tcb.blocked_thread) |thread| {
            socket.wakeThread(thread);
            tcb.blocked_thread = null;
        }
        state.freeTcb(tcb);
        return;
    }
}

/// Get state timeout in milliseconds (0 = no timeout)
pub fn getStateTimeout(tcp_state: @TypeOf(state.tcb_pool[0].state)) u64 {
    const timeouts = c.STATE_TIMEOUT_MS{};
    return switch (tcp_state) {
        .Closed => timeouts.closed,
        .Listen => timeouts.listen,
        .SynSent => timeouts.syn_sent,
        .SynReceived => timeouts.syn_recv,
        .Established => timeouts.established,
        .CloseWait => timeouts.close_wait,
        .LastAck => timeouts.last_ack,
    };
}
