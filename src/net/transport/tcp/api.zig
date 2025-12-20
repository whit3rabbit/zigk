const c = @import("constants.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const tx = @import("tx/root.zig");
const errors = @import("errors.zig");

const Tcb = types.Tcb;
const TcpError = errors.TcpError;

/// Create a listening TCB (called from sys_listen)
pub fn listen(local_ip: u32, local_port: u16, socket_idx: usize) TcpError!*Tcb {
    state.lock.acquire();
    defer state.lock.release();

    const tcb = state.allocateTcb() orelse return TcpError.NoResources;

    // Initialize TCB (newly allocated, no need for mutex)
    tcb.local_ip = local_ip;
    tcb.local_port = local_port;
    tcb.remote_ip = 0;
    tcb.remote_port = 0;
    tcb.state = .Listen;
    tcb.parent_socket = socket_idx;

    if (!state.addToListenTable(tcb)) {
        state.freeTcb(tcb);
        return TcpError.NoResources;
    }

    return tcb;
}

/// Initiate connection (called from sys_connect)
pub fn connect(local_ip: u32, local_port: u16, remote_ip: u32, remote_port: u16) TcpError!*Tcb {
    state.lock.acquire();
    defer state.lock.release();

    // Check for existing connection
    if (state.findTcb(local_ip, local_port, remote_ip, remote_port) != null) {
        return TcpError.AlreadyConnected;
    }

    const tcb = state.allocateTcb() orelse return TcpError.NoResources;

    // Initialize TCB
    tcb.local_ip = local_ip;
    tcb.local_port = local_port;
    tcb.remote_ip = remote_ip;
    tcb.remote_port = remote_port;

    // Generate ISN and initialize sequence numbers
    tcb.iss = state.generateIsn(tcb.local_ip, tcb.local_port, tcb.remote_ip, tcb.remote_port);
    tcb.snd_nxt = tcb.iss +% 1;
    tcb.snd_una = tcb.iss;

    tcb.state = .SynSent;

    state.insertTcbIntoHash(tcb);

    // Send SYN (requires valid TCB)
    // We hold state.lock, but sendSyn might access TCB fields.
    // It's safe since no one else can see TCB yet (except rx looking up hash, but we hold state.lock)
    if (!tx.sendSyn(tcb)) {
        state.freeTcb(tcb);
        return TcpError.NetworkError;
    }

    tcb.retrans_timer = 1; // Start retransmit timer

    return tcb;
}

/// Close a connection (called from socket close)
pub fn close(tcb: *Tcb) void {
    state.lock.acquire();
    defer state.lock.release();

    // Acquire TCB mutex to drain any active send/recv operations
    const held = tcb.mutex.acquire();

    // Mark as closing to prevent new operations from starting
    tcb.closing = true;

    switch (tcb.state) {
        .SynReceived, .Established => {
            // Active close: send FIN and enter FIN-WAIT-1
            _ = tx.sendFin(tcb);
            tcb.snd_nxt +%= 1; // FIN consumes one seq
        },
        .CloseWait => {
            // Send FIN
            _ = tx.sendFin(tcb);
            tcb.snd_nxt +%= 1;
        },
        .LastAck => {},
        // Connection is already closing - no action needed
        .FinWait1, .FinWait2, .Closing, .TimeWait => {},
        else => {},
    }

    // Always detach from global tables so process teardown can't leave dangling TCBs
    if (tcb.state == .Listen) {
        state.removeFromListenTable(tcb);
    }

    // Drop any scheduler references that could point at torn-down threads
    tcb.blocked_thread = null;
    tcb.parent_socket = null;
    tcb.state = .Closed;

    held.release();

    // Removes from hash + timer pool and frees memory
    // Safe because we hold state.lock and have marked TCB as closing/closed
    state.freeTcb(tcb);
}

/// Send FIN for shutdown(SHUT_WR) - public wrapper
/// Called from socket layer for half-close semantics (RFC 793 compliant)
pub fn sendFinPacket(tcb: *Tcb) void {
    // We don't need state.lock just to send FIN, only tcb.mutex
    // But we need to ensure TCB isn't freed.
    // Ideally caller ensures TCB validity (via socket reference).
    // Acquiring state.lock is safer given current architecture.
    state.lock.acquire();
    const held = tcb.mutex.acquire();
    state.lock.release();
    defer held.release();

    if (tcb.closing) return;

    switch (tcb.state) {
        .Established, .SynReceived => {
            // Active close: ESTABLISHED/SYN-RECEIVED -> FIN-WAIT-1
            _ = tx.sendFin(tcb);
            tcb.snd_nxt +%= 1; // FIN consumes one sequence number
            tcb.state = .FinWait1;
            tcb.retrans_timer = 1; // Start retransmit timer
        },
        .CloseWait => {
            // Passive close completion: CLOSE-WAIT -> LAST-ACK
            _ = tx.sendFin(tcb);
            tcb.snd_nxt +%= 1;
            tcb.state = .LastAck;
            tcb.retrans_timer = 1;
        },
        else => {},
    }
}

/// Send data on a connection
pub fn send(tcb: *Tcb, data: []const u8) TcpError!usize {
    state.lock.acquire();
    // Validate TCB state/validity roughly (optional but good)
    const held = tcb.mutex.acquire();
    state.lock.release();
    defer held.release();

    if (tcb.closing) return TcpError.ConnectionReset;

    if (tcb.state != .Established and tcb.state != .CloseWait) {
        return TcpError.NotConnected;
    }

    if (data.len == 0) return 0;

    // Copy to send buffer
    const space = tcb.sendBufferSpace();
    const copy_len = @min(data.len, space);

    if (copy_len == 0) {
        return TcpError.WouldBlock;
    }

    for (0..copy_len) |i| {
        tcb.send_buf[tcb.send_head] = data[i];
        tcb.send_head = (tcb.send_head + 1) % c.BUFFER_SIZE;
    }

    // Try to send immediately
    _ = tx.transmitPendingData(tcb);

    return copy_len;
}

/// Receive data from a connection
pub fn recv(tcb: *Tcb, buf: []u8) TcpError!usize {
    state.lock.acquire();
    const held = tcb.mutex.acquire();
    state.lock.release();
    defer held.release();

    if (tcb.closing) return TcpError.ConnectionReset;

    // Check availability first logic
    const available = tcb.recvBufferAvailable();

    if (available > 0) {
        const copy_len = @min(buf.len, available);

        for (0..copy_len) |i| {
            buf[i] = tcb.recv_buf[tcb.recv_tail];
            tcb.recv_tail = (tcb.recv_tail + 1) % c.BUFFER_SIZE;
        }

        return copy_len;
    }

    // No data available - check channel state
    switch (tcb.state) {
        // Clean disconnect / EOF
        .CloseWait, .LastAck, .Closing, .TimeWait, .Closed => return 0,
        // Connected but empty - Wait
        .Established, .FinWait1, .FinWait2 => return TcpError.WouldBlock,
        // Not connected logic
        .Listen, .SynSent, .SynReceived => return TcpError.NotConnected,
    }
}
