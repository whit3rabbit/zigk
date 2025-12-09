const c = @import("constants.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const tx = @import("tx.zig");
const errors = @import("errors.zig");

const Tcb = types.Tcb;
const TcpError = errors.TcpError;

/// Create a listening TCB (called from sys_listen)
pub fn listen(local_ip: u32, local_port: u16, socket_idx: usize) TcpError!*Tcb {
    state.lock.acquire();
    defer state.lock.release();

    const tcb = state.allocateTcb() orelse return TcpError.NoResources;

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

    // Send SYN
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

    switch (tcb.state) {
        .Listen => {
            state.removeFromListenTable(tcb);
            state.freeTcb(tcb);
        },
        .SynSent => {
            state.freeTcb(tcb);
        },
        .SynReceived, .Established => {
            // Send FIN
            _ = tx.sendFin(tcb);
            tcb.snd_nxt +%= 1; // FIN consumes one seq
            tcb.state = .LastAck; // Simplified: skip FIN-WAIT states
            tcb.retrans_timer = 1;
        },
        .CloseWait => {
            // Send FIN
            _ = tx.sendFin(tcb);
            tcb.snd_nxt +%= 1;
            tcb.state = .LastAck;
            tcb.retrans_timer = 1;
        },
        .LastAck => {},
        .Closed => {
            state.freeTcb(tcb);
        },
    }
}

/// Send FIN for shutdown(SHUT_WR) - public wrapper
/// Called from socket layer for half-close semantics
/// Note: This is a simplified implementation that doesn't track FIN-WAIT states
pub fn sendFinPacket(tcb: *Tcb) void {
    if (tcb.state == .Established or tcb.state == .CloseWait) {
        _ = tx.sendFin(tcb);
        tcb.snd_nxt +%= 1; // FIN consumes one sequence number
        // Note: Proper implementation would transition to FIN_WAIT_1/LAST_ACK
        // For MVP, we keep the state to allow continued receives
    }
}

/// Send data on a connection
pub fn send(tcb: *Tcb, data: []const u8) TcpError!usize {
    state.lock.acquire();
    defer state.lock.release();

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
    defer state.lock.release();

    if (tcb.state == .Closed) {
        return TcpError.NotConnected;
    }

    const available = tcb.recvBufferAvailable();

    // EOF condition: CloseWait with empty buffer
    if (available == 0 and tcb.state == .CloseWait) {
        return 0; // EOF
    }

    if (available == 0) {
        return TcpError.WouldBlock;
    }

    const copy_len = @min(buf.len, available);

    for (0..copy_len) |i| {
        buf[i] = tcb.recv_buf[tcb.recv_tail];
        tcb.recv_tail = (tcb.recv_tail + 1) % c.BUFFER_SIZE;
    }

    return copy_len;
}
