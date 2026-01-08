const c = @import("constants.zig");
const state = @import("state.zig");
const tx = @import("tx/root.zig");
const types = @import("types.zig");

const socket = @import("../socket.zig");

/// Check and process timers (called from timer tick, assumed ~1ms per call)
/// Handles retransmission and state-based connection timeouts
pub fn processTimers() void {
    var state_held = state.lock.acquire();
    // List of threads to wake after releasing the lock (to avoid deadlock)
    // Security: Size increased to handle pathological cases where many TCBs timeout simultaneously
    // Must be >= MAX_TCBS to prevent threads being orphaned without waking
    var wake_list: [c.MAX_TCBS]?*anyopaque = undefined;
    var wake_count: usize = 0;

    // Iterate backwards to safely handle swapRemove during iteration.
    // When freeTcb() calls swapRemove(), the last element moves to current index.
    // Backward iteration ensures we don't skip any elements.
    var i: usize = state.tcb_pool.items.len;
    while (i > 0) {
        i -= 1;
        const tcb = state.tcb_pool.items[i];
        if (!tcb.allocated) continue;
        var tcb_held = tcb.mutex.tryAcquire() orelse continue;
        var tcb_released = false;
        defer if (!tcb_released) tcb_held.release();

        // Orphan TCB detection: TCBs without a parent socket (except Listen state)
        // These can occur if a socket is closed while the TCP state machine is
        // still processing (e.g., FIN_WAIT, CLOSING states). Use aggressive timeout.
        if (tcb.parent_socket == null and tcb.state != .Listen) {
            const orphan_timeout: u32 = 30_000; // 30 seconds for orphaned TCBs
            const age = state.connection_timestamp -% tcb.created_at;
            if (age > orphan_timeout) {
                tcb.state = .Closed;
                tcb.closing = true;
                if (tcb.blocked_thread) |thread| {
                    if (wake_count < wake_list.len) {
                        wake_list[wake_count] = thread;
                        wake_count += 1;
                    }
                    tcb.blocked_thread = null;
                }
                tcb_held.release();
                tcb_released = true;
                state.freeTcb(tcb);
                continue;
            }
        }

        // Check state-based timeout (garbage collection)
        const state_timeout = getStateTimeout(tcb.state);
        if (state_timeout > 0) {
            const age = state.connection_timestamp -% tcb.created_at;
            if (age > state_timeout) {
                // Connection timed out in this state - clean up
                tcb.state = .Closed;
                tcb.closing = true;
                // Wake thread blocked on this connection
                if (tcb.blocked_thread) |thread| {
                    if (wake_count < wake_list.len) {
                        wake_list[wake_count] = thread;
                        wake_count += 1;
                    }
                    tcb.blocked_thread = null;
                }
                tcb_held.release();
                tcb_released = true;
                state.freeTcb(tcb);
                continue;
            }
        }

        if (tcb.ack_pending and state.connection_timestamp >= tcb.ack_due) {
            _ = tx.sendAck(tcb);
            tcb.ack_pending = false;
            tcb.ack_due = 0;
        }

        // Process retransmission timer
        if (tcb.retrans_timer == 0) continue;

        // Simplified: retransmit every RTO ticks
        tcb.retrans_timer +%= state.ms_per_tick;

        if (tcb.retrans_timer > tcb.rto_ms) {
            // Retransmit timeout
            tcb.retrans_count += 1;

            if (tcb.retrans_count >= c.MAX_RETRIES) {
                // Too many retries - reset connection
                tcb.state = .Closed;
                tcb.closing = true;
                // Wake thread blocked on this connection (connect/recv timeout)
                if (tcb.blocked_thread) |thread| {
                    if (wake_count < wake_list.len) {
                        wake_list[wake_count] = thread;
                        wake_count += 1;
                    }
                    tcb.blocked_thread = null;
                }
                tcb_held.release();
                tcb_released = true;
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
                    if (tcb.sack_ok and tcb.sack_block_count > 0) {
                        _ = tx.retransmitLoss(tcb);
                    } else {
                        // Retransmit oldest unacked segment (Go-Back-N style simplified)
                        tcb.snd_nxt = tcb.snd_una;
                        _ = tx.transmitPendingData(tcb);
                    }
                },
                .LastAck => _ = tx.sendFin(tcb),
                else => {},
            }
        }
    }

    // Release lock before waking threads to prevent deadlock
    // (Woken thread might immediately try to acquire lock)
    state_held.release();

    // Wake threads outside of lock to avoid deadlock
    var j: usize = 0;
    while (j < wake_count) : (j += 1) {
        if (wake_list[j]) |thread| {
            socket.wakeThread(thread);
        }
    }
}

/// Handle ICMP error for a connection
/// Handle ICMP error for a connection
pub fn handleIcmpError(local_ip: u32, local_port: u16, remote_ip: u32, remote_port: u16, icmp_type: u8, icmp_code: u8, seq_num: ?u32) void {
    const held = state.lock.acquire();
    defer held.release();

    const tcb = state.findTcb(local_ip, local_port, remote_ip, remote_port) orelse return;

    // RFC 5927: Validate sequence number if present
    if (seq_num) |seq| {
        // Must be in range [SND.UNA, SND.NXT]
        // Note: SND.NXT might have advanced since the packet was sent, but the
        // seq number in the error should be what we sent (less than SND.NXT).
        // It must be >= SND.UNA (unacknowledged).
        // We use loose check validation to account for window
        const snd_una = tcb.snd_una;
        const snd_nxt = tcb.snd_nxt;

        // seq < snd_una OR seq > snd_nxt
        if (types.seqLt(seq, snd_una) or types.seqGt(seq, snd_nxt)) {
            return; // Ignore Invalid ICMP error
        }
    }

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

    // Established Phase: RFC 5927 / RFC 1122
    // We MUST NOT abort variables on "hard" errors (Port/Proto Unreach) because they are easily spoofed.
    // We should rely on TCP's own retransmission limits to time out the connection.
    if ((tcb.state == .Established or tcb.state == .CloseWait) and is_hard_error) {
        // Ignore the error.
        // Optionally, we could log it or maybe trigger a faster retransmit check,
        // but strictly aborting is the security vulnerability we are fixing.
        return;
    }
}

/// Handle ICMP error for a connection (dual-stack version using IpAddr)
/// Supports both IPv4 and IPv6 connections via the IpAddr tagged union.
/// Called by ICMPv6 Destination Unreachable handler.
pub fn handleIcmpErrorIp(
    local_addr: state.IpAddr,
    local_port: u16,
    remote_addr: state.IpAddr,
    remote_port: u16,
    icmp_type: u8,
    icmp_code: u8,
    seq_num: ?u32,
) void {
    const held = state.lock.acquire();
    defer held.release();

    const tcb = state.findTcbIp(local_addr, local_port, remote_addr, remote_port) orelse return;

    // RFC 5927: Validate sequence number if present
    if (seq_num) |seq| {
        // Must be in range [SND.UNA, SND.NXT]
        const snd_una = tcb.snd_una;
        const snd_nxt = tcb.snd_nxt;

        // seq < snd_una OR seq > snd_nxt
        if (types.seqLt(seq, snd_una) or types.seqGt(seq, snd_nxt)) {
            return; // Ignore invalid ICMP error
        }
    }

    // Handle Destination Unreachable (type 3 for IPv4, type 1 for ICMPv6)
    // Caller normalizes ICMPv6 type 1 to IPv4 type 3 for compatibility
    if (icmp_type != 3) return;

    const is_hard_error = switch (icmp_code) {
        // Net/Host unreachable are "soft" errors (transient routing issues)
        0, 1 => false,
        // Proto/Port unreachable are "hard" errors (permanent)
        2, 3 => true,
        // Fragmentation needed (IPv4) / Packet Too Big (ICMPv6) - PMTU update, not error
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

    // Established Phase: RFC 5927 / RFC 1122
    // We MUST NOT abort on "hard" errors (Port/Proto Unreach) because they are easily spoofed.
    // Rely on TCP's own retransmission limits to time out the connection.
    if ((tcb.state == .Established or tcb.state == .CloseWait) and is_hard_error) {
        return;
    }
}

/// Get state timeout in milliseconds (0 = no timeout)
pub fn getStateTimeout(tcp_state: @TypeOf(state.tcb_pool.items[0].state)) u64 {
    const timeouts = c.STATE_TIMEOUT_MS{};
    return switch (tcp_state) {
        .Closed => timeouts.closed,
        .Listen => timeouts.listen,
        .SynSent => timeouts.syn_sent,
        .SynReceived => timeouts.syn_recv,
        .Established => timeouts.established,
        .CloseWait => timeouts.close_wait,
        .LastAck => timeouts.last_ack,
        // FIN-related states use a shorter timeout for connection teardown
        .FinWait1, .FinWait2, .Closing => 60_000, // 60 second FIN timeout
        .TimeWait => 120_000, // 2 * MSL (RFC 793)
    };
}
