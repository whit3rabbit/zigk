// TCP-facing socket helpers.

const tcp = @import("../tcp.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const tcp_state = @import("../tcp/state.zig");
const errors = @import("errors.zig");
const scheduler = @import("scheduler.zig");
const hal = @import("hal");

/// Mark socket as listening for connections (TCP only)
pub fn listen(sock_fd: usize, backlog_arg: usize) errors.SocketError!void {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    // Must be SOCK_STREAM (TCP)
    if (sock.sock_type != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }

    // Must be bound
    if (sock.local_port == 0) {
        return errors.SocketError.InvalidArg;
    }

    // Create listening TCB
    const iface = state.getInterface() orelse return errors.SocketError.NetworkDown;
    const local_ip = if (sock.local_addr == 0) iface.ip_addr else sock.local_addr;

    const listen_tcb = tcp.listen(local_ip, sock.local_port, sock_fd) catch {
        return errors.SocketError.NoSocketsAvailable;
    };

    sock.tcb = listen_tcb;
    sock.backlog = @intCast(@min(backlog_arg, types.ACCEPT_QUEUE_SIZE));

    // Copy socket options to listening TCB (for inheritance to child connections)
    listen_tcb.tos = sock.tos;
}

/// Accept an incoming connection (TCP only)
/// Returns new socket index for the accepted connection
pub fn accept(sock_fd: usize, peer_addr: ?*types.SockAddrIn) errors.SocketError!usize {
    // Socket acquisition is now handled inside the loop to support re-acquisition
    // after blocking.




    var accepted_tcb: ?*tcp.Tcb = null;

    // Loop until we get a connection or error
    while (true) {
        // Re-acquire socket on each iteration to ensure pointer validity
        // (socket table might have resized while we were unlocked)
        const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
        
        // Must be SOCK_STREAM and listening (check again in case state changed)
        if (sock.sock_type != types.SOCK_STREAM) {
            state.releaseSocket(sock);
            return errors.SocketError.TypeNotSupported;
        }
        if (sock.tcb == null or sock.tcb.?.state != .Listen) {
            state.releaseSocket(sock);
            return errors.SocketError.InvalidArg;
        }

        // Disable interrupts to close race window between check and block
        hal.cpu.disableInterrupts();
        tcp_state.lock.acquire();

        // Check accept queue
        if (sock.accept_count > 0) {
            // Dequeue connection under TCP lock
            const tcb = sock.accept_queue[sock.accept_tail] orelse {
                tcp_state.lock.release();
                 hal.cpu.enableInterrupts(); // Safe to enable here
                state.releaseSocket(sock);
                return errors.SocketError.WouldBlock;
            };
            sock.accept_queue[sock.accept_tail] = null;
            sock.accept_tail = (sock.accept_tail + 1) % types.ACCEPT_QUEUE_SIZE;
            sock.accept_count -= 1;
            
            tcp_state.lock.release();
            hal.cpu.enableInterrupts(); // Safe to enable here
            
            // Drop socket lock now that we have the TCB
            state.releaseSocket(sock);
            
            accepted_tcb = tcb;
            break; // Found one!
        }

        // No connections available
        if (!sock.blocking) {
            tcp_state.lock.release();
            hal.cpu.enableInterrupts();
            state.releaseSocket(sock);
            return errors.SocketError.WouldBlock;
        }

        // Blocking: Prepare to sleep
        if (scheduler.blockFn()) |block_fn| {
            const get_current = scheduler.currentThreadFn() orelse {
                tcp_state.lock.release();
                hal.cpu.enableInterrupts();
                state.releaseSocket(sock);
                return errors.SocketError.SystemError;
            };

            sock.blocked_thread = get_current();
            
            tcp_state.lock.release(); // TCP lock released, IRQs disabled
            
            // CRITICAL: Release socket lock before blocking!
            // calling queueAcceptConnection requires this lock.
            // If we hold it while sleeping, we deadock.
            state.releaseSocket(sock); 

            // block_fn() sets state=Blocked then atomically enables
            // interrupts and halts (STI; HLT sequence)
            block_fn();
            
            // Woke up - loop around to re-acquire locks and check queue
            continue;
        } else {
            tcp_state.lock.release();
            hal.cpu.enableInterrupts();
            state.releaseSocket(sock);
            return errors.SocketError.WouldBlock;
        }
    }
    const tcb = accepted_tcb.?;

    // Allocate new socket for this connection
    const new_sock_fd = @import("lifecycle.zig").socket(types.AF_INET, types.SOCK_STREAM, 0) catch {
        tcp.close(tcb);
        return errors.SocketError.NoSocketsAvailable;
    };

    const new_sock = state.getSocket(new_sock_fd) orelse {
        tcp.close(tcb);
        return errors.SocketError.SystemError;
    };
    new_sock.tcb = tcb;
    new_sock.local_port = tcb.local_port;
    new_sock.local_addr = tcb.local_ip;

    // Fill peer address if requested
    if (peer_addr) |addr| {
        addr.* = types.SockAddrIn.init(tcb.remote_ip, tcb.remote_port);
    }

    return new_sock_fd;
}

/// Initiate connection to remote address (TCP only)
pub fn connect(sock_fd: usize, dest_addr: *const types.SockAddrIn) errors.SocketError!void {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    // Must be SOCK_STREAM (TCP)
    if (sock.sock_type != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }

    // Already connected?
    if (sock.tcb != null) {
        return errors.SocketError.AlreadyConnected;
    }

    const iface = state.getInterface() orelse return errors.SocketError.NetworkDown;

    // Auto-bind if not bound
    if (sock.local_port == 0) {
        sock.local_port = state.allocateEphemeralPort();
    }

    const local_ip = if (sock.local_addr == 0) iface.ip_addr else sock.local_addr;
    const remote_ip = dest_addr.getAddr();
    const remote_port = dest_addr.getPort();

    // Initiate connection
    const tcb = tcp.connect(local_ip, sock.local_port, remote_ip, remote_port) catch |err| {
        return switch (err) {
            tcp.TcpError.NoResources => errors.SocketError.NoSocketsAvailable,
            tcp.TcpError.AlreadyConnected => errors.SocketError.AlreadyConnected,
            tcp.TcpError.NetworkError => errors.SocketError.NetworkUnreachable,
            else => errors.SocketError.NetworkUnreachable,
        };
    };

    sock.tcb = tcb;

    // Copy socket options to TCB
    tcb.tos = sock.tos;

    // Capture generation for race checking
    const tcb_gen = tcb.generation;

    // Connection started - SYN sent
    
    // Handle blocking if requested
    if (sock.blocking) {
        if (scheduler.blockFn()) |block_fn| {
            const get_current = scheduler.currentThreadFn() orelse return errors.SocketError.SystemError;
            
            // Loop until state changes from SynSent (or error occurs)
            while (tcb.state == .SynSent) {
                 // Disable interrupts to close race window
                 _ = hal.cpu.disableInterrupts();
                 
                 // Check state again after locking
                 if (tcb.state != .SynSent) {
                     hal.cpu.enableInterrupts();
                     break;
                 }
                 
                 sock.blocked_thread = get_current();
                 // Important: tcb.blocked_thread must also be set for TCP layer to wake us
                 // when the handshake completes (SYN-SENT processing in rx.zig wakes this)
                 tcb.blocked_thread = sock.blocked_thread; 
                 
                 block_fn(); // Implies enable interrupts + halt

                 sock.blocked_thread = null;
                 // Security: Acquire lock before accessing TCB to prevent use-after-free.
                 // TCB may have been freed by timer while we were blocked.
                 tcp_state.lock.acquire();
                 // Re-verify TCB is still attached to socket and valid
                 // Security: Check generation to ensure TCB wasn't freed and re-allocated for a different connection
                 // while we were sleeping.
                 if (sock.tcb == tcb and tcb.allocated and tcb.state != .Closed and tcb.generation == tcb_gen) {
                     tcb.blocked_thread = null;
                 }
                 tcp_state.lock.release();
            }
        } else {
             // If no scheduler (e.g. early boot), we can't block safely
             return errors.SocketError.WouldBlock;
        }
    }

    // Check final state - must re-fetch TCB under lock to prevent use-after-free
    tcp_state.lock.acquire();
    const final_tcb = sock.tcb;
    const final_state = if (final_tcb) |t| t.state else .Closed;
    tcp_state.lock.release();

    switch (final_state) {
        .Established => return,
        .Closed => return errors.SocketError.ConnectionRefused,
        .SynSent => return errors.SocketError.WouldBlock, // Should not happen if we blocked
        else => return, // Other states might imply connected or closing
    }
}

/// Get TCB for a socket (for syscall layer to set blocked_thread)
pub fn getTcb(sock_fd: usize) ?*tcp.Tcb {
    const sock = state.acquireSocket(sock_fd) orelse return null;
    defer state.releaseSocket(sock);
    return sock.tcb;
}

/// Check connection status (for syscall layer to poll/block on)
pub fn checkConnectStatus(sock_fd: usize) errors.SocketError!void {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);
    const tcb = sock.tcb orelse return errors.SocketError.NotConnected;

    switch (tcb.state) {
        .Established => return, // Success
        .Closed => {
            sock.tcb = null;
            return errors.SocketError.ConnectionRefused;
        },
        .SynSent => return errors.SocketError.WouldBlock, // Still connecting
        else => return errors.SocketError.WouldBlock,
    }
}

/// Queue a completed connection for accept (called from TCP layer)
pub fn queueAcceptConnection(socket_idx: usize, tcb: *tcp.Tcb) bool {
    const sock = state.acquireSocket(socket_idx) orelse return false;
    defer state.releaseSocket(sock);
    if (sock.accept_count >= sock.backlog) return false;

    sock.accept_queue[sock.accept_head] = tcb;
    sock.accept_head = (sock.accept_head + 1) % types.ACCEPT_QUEUE_SIZE;
    sock.accept_count += 1;

    // Wake any waiting thread
    scheduler.wakeThread(sock.blocked_thread);

    return true;
}

/// TCP send (for connected SOCK_STREAM sockets)
pub fn tcpSend(sock_fd: usize, data: []const u8) errors.SocketError!usize {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    if (sock.sock_type != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }

    const tcb = sock.tcb orelse return errors.SocketError.NotConnected;

    return tcp.send(tcb, data) catch |err| {
        return switch (err) {
            tcp.TcpError.NotConnected => errors.SocketError.NotConnected,
            tcp.TcpError.WouldBlock => errors.SocketError.WouldBlock,
            else => errors.SocketError.NetworkUnreachable,
        };
    };
}

/// TCP receive (for connected SOCK_STREAM sockets)
pub fn tcpRecv(sock_fd: usize, buf: []u8) errors.SocketError!usize {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    if (sock.sock_type != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }

    const tcb = sock.tcb orelse return errors.SocketError.NotConnected;

    // Try to receive - syscall layer handles blocking if WouldBlock
    // tcp.recv returns 0 for EOF (FIN received in CloseWait state)
    return tcp.recv(tcb, buf) catch |err| {
        return switch (err) {
            tcp.TcpError.NotConnected => errors.SocketError.NotConnected,
            tcp.TcpError.WouldBlock => errors.SocketError.WouldBlock,
            else => errors.SocketError.NetworkUnreachable,
        };
    };
}
