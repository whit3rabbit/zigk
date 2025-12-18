// TCP-facing socket helpers.

const tcp = @import("../tcp.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const tcp_state = @import("../tcp/state.zig");
const errors = @import("errors.zig");
const scheduler = @import("scheduler.zig");
const platform = @import("../../platform.zig");

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
        platform.cpu.disableInterrupts();
        tcp_state.lock.acquire();

        // Check accept queue
        if (sock.accept_count > 0) {
            // Dequeue connection under TCP lock
            const tcb = sock.accept_queue[sock.accept_tail] orelse {
                tcp_state.lock.release();
                 platform.cpu.enableInterrupts(); // Safe to enable here
                state.releaseSocket(sock);
                return errors.SocketError.WouldBlock;
            };
            sock.accept_queue[sock.accept_tail] = null;
            sock.accept_tail = (sock.accept_tail + 1) % types.ACCEPT_QUEUE_SIZE;
            sock.accept_count -= 1;
            
            tcp_state.lock.release();
            platform.cpu.enableInterrupts(); // Safe to enable here
            
            // Drop socket lock now that we have the TCB
            state.releaseSocket(sock);
            
            accepted_tcb = tcb;
            break; // Found one!
        }

        // No connections available
        if (!sock.blocking) {
            tcp_state.lock.release();
            platform.cpu.enableInterrupts();
            state.releaseSocket(sock);
            return errors.SocketError.WouldBlock;
        }

        // Blocking: Prepare to sleep
        if (scheduler.blockFn()) |block_fn| {
            const get_current = scheduler.currentThreadFn() orelse {
                tcp_state.lock.release();
                platform.cpu.enableInterrupts();
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
            platform.cpu.enableInterrupts();
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

    // Store socket index in TCB for async completion lookup
    // This reuses parent_socket field (also used for server-side accept queue)
    tcb.parent_socket = sock_fd;

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
                 _ = platform.cpu.disableInterrupts();
                 
                 // Check state again after locking
                 if (tcb.state != .SynSent) {
                     platform.cpu.enableInterrupts();
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

// =============================================================================
// Async API (Phase 2)
// =============================================================================
// These functions integrate with the KernelIo reactor for async operations.
// Instead of blocking, they set pending_* fields on the socket and return
// immediately. The request is completed by IRQ handlers when data arrives.
//
// Pattern:
//   1. Check if operation can complete synchronously (data available)
//   2. If yes: complete request immediately, return true
//   3. If no: store request pointer in socket, return false (pending)
//   4. IRQ handler checks pending_* and completes when data arrives

const io = @import("io");
const IoRequest = io.IoRequest;
const IoResult = io.IoResult;

/// Async accept - queue request for incoming connection
/// Returns true if completed synchronously, false if pending
pub fn acceptAsync(sock_fd: usize, request: *IoRequest) errors.SocketError!bool {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    // Must be SOCK_STREAM and listening
    if (sock.sock_type != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }
    if (sock.tcb == null or sock.tcb.?.state != .Listen) {
        return errors.SocketError.InvalidArg;
    }

    // Check if connection already available
    tcp_state.lock.acquire();
    defer tcp_state.lock.release();

    if (sock.accept_count > 0) {
        // Connection available - complete synchronously
        const tcb = sock.accept_queue[sock.accept_tail] orelse {
            return errors.SocketError.SystemError;
        };
        sock.accept_queue[sock.accept_tail] = null;
        sock.accept_tail = (sock.accept_tail + 1) % types.ACCEPT_QUEUE_SIZE;
        sock.accept_count -= 1;

        // Allocate new socket for connection
        const new_sock_fd = @import("lifecycle.zig").socket(types.AF_INET, types.SOCK_STREAM, 0) catch {
            tcp.close(tcb);
            _ = request.complete(.{ .err = error.ENOMEM });
            return true; // Completed (with error)
        };

        const new_sock = state.getSocket(new_sock_fd) orelse {
            tcp.close(tcb);
            _ = request.complete(.{ .err = error.EFAULT });
            return true;
        };
        new_sock.tcb = tcb;
        new_sock.local_port = tcb.local_port;
        new_sock.local_addr = tcb.local_ip;

        // Complete with new fd
        _ = request.complete(.{ .success = new_sock_fd });
        return true;
    }

    // No connection available - store pending request
    if (sock.pending_accept != null) {
        // Already have a pending accept
        return errors.SocketError.WouldBlock;
    }

    sock.pending_accept = request;
    request.fd = @intCast(sock_fd);
    return false; // Pending
}

/// Async recv - queue request for incoming data
/// Returns true if completed synchronously, false if pending
pub fn recvAsync(sock_fd: usize, request: *IoRequest, buf: []u8) errors.SocketError!bool {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    if (sock.sock_type != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }

    const tcb = sock.tcb orelse return errors.SocketError.NotConnected;

    // Try to receive immediately
    const result = tcp.recv(tcb, buf) catch |err| {
        return switch (err) {
            tcp.TcpError.NotConnected => {
                _ = request.complete(.{ .err = error.ENOTCONN });
                return true;
            },
            tcp.TcpError.WouldBlock => {
                // No data available - queue request
                if (sock.pending_recv != null) {
                    return errors.SocketError.WouldBlock;
                }
                sock.pending_recv = request;
                request.fd = @intCast(sock_fd);
                request.buf_ptr = @intFromPtr(buf.ptr);
                request.buf_len = buf.len;
                return false; // Pending
            },
            else => {
                _ = request.complete(.{ .err = error.EIO });
                return true;
            },
        };
    };

    // Data received synchronously
    _ = request.complete(.{ .success = result });
    return true;
}

/// Async send - queue request for outgoing data
/// Returns true if completed synchronously, false if pending
pub fn sendAsync(sock_fd: usize, request: *IoRequest, data: []const u8) errors.SocketError!bool {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    if (sock.sock_type != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }

    const tcb = sock.tcb orelse return errors.SocketError.NotConnected;

    // Try to send immediately
    const sent = tcp.send(tcb, data) catch |err| {
        return switch (err) {
            tcp.TcpError.NotConnected => {
                _ = request.complete(.{ .err = error.ENOTCONN });
                return true;
            },
            tcp.TcpError.WouldBlock => {
                // Buffer full - queue request
                if (sock.pending_send != null) {
                    return errors.SocketError.WouldBlock;
                }
                sock.pending_send = request;
                request.fd = @intCast(sock_fd);
                request.buf_ptr = @intFromPtr(data.ptr);
                request.buf_len = data.len;
                return false; // Pending
            },
            else => {
                _ = request.complete(.{ .err = error.EIO });
                return true;
            },
        };
    };

    // Data sent synchronously
    _ = request.complete(.{ .success = sent });
    return true;
}

/// Async connect - queue request for connection establishment
/// Returns true if completed synchronously, false if pending
pub fn connectAsync(sock_fd: usize, request: *IoRequest, dest_addr: *const types.SockAddrIn) errors.SocketError!bool {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    // Must be SOCK_STREAM (TCP)
    if (sock.sock_type != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }

    // Already connected?
    if (sock.tcb != null) {
        _ = request.complete(.{ .err = error.EISCONN });
        return true;
    }

    const iface = state.getInterface() orelse {
        _ = request.complete(.{ .err = error.ENETDOWN });
        return true;
    };

    // Auto-bind if not bound
    if (sock.local_port == 0) {
        sock.local_port = state.allocateEphemeralPort();
    }

    const local_ip = if (sock.local_addr == 0) iface.ip_addr else sock.local_addr;
    const remote_ip = dest_addr.getAddr();
    const remote_port = dest_addr.getPort();

    // Initiate connection
    const tcb = tcp.connect(local_ip, sock.local_port, remote_ip, remote_port) catch |err| {
        const syscall_err = switch (err) {
            tcp.TcpError.NoResources => error.ENOMEM,
            tcp.TcpError.AlreadyConnected => error.EISCONN,
            tcp.TcpError.NetworkError => error.ENETUNREACH,
            else => error.ENETUNREACH,
        };
        _ = request.complete(.{ .err = syscall_err });
        return true;
    };

    sock.tcb = tcb;
    tcb.tos = sock.tos;

    // Store socket index in TCB for async completion lookup
    tcb.parent_socket = sock_fd;

    // Store pending connect request - will be completed when handshake finishes
    sock.pending_connect = request;
    request.fd = @intCast(sock_fd);

    return false; // Pending - handshake in progress
}

/// Complete pending accept request (called from TCP layer when connection arrives)
/// Returns true if a pending request was completed
pub fn completePendingAccept(socket_idx: usize, tcb: *tcp.Tcb) bool {
    const sock = state.acquireSocket(socket_idx) orelse return false;
    defer state.releaseSocket(sock);

    const pending = sock.pending_accept orelse return false;
    const request: *IoRequest = @ptrCast(@alignCast(pending));
    sock.pending_accept = null;

    // Allocate new socket for connection
    const new_sock_fd = @import("lifecycle.zig").socket(types.AF_INET, types.SOCK_STREAM, 0) catch {
        tcp.close(tcb);
        _ = request.complete(.{ .err = error.ENOMEM });
        return true;
    };

    const new_sock = state.getSocket(new_sock_fd) orelse {
        tcp.close(tcb);
        _ = request.complete(.{ .err = error.EFAULT });
        return true;
    };
    new_sock.tcb = tcb;
    new_sock.local_port = tcb.local_port;
    new_sock.local_addr = tcb.local_ip;

    _ = request.complete(.{ .success = new_sock_fd });
    return true;
}

/// Complete pending recv request (called from TCP layer when data arrives)
/// Returns true if a pending request was completed
pub fn completePendingRecv(socket_idx: usize, data: []const u8) bool {
    const sock = state.acquireSocket(socket_idx) orelse return false;
    defer state.releaseSocket(sock);

    const pending = sock.pending_recv orelse return false;
    const request: *IoRequest = @ptrCast(@alignCast(pending));
    sock.pending_recv = null;

    // Copy data to request buffer
    const buf_ptr: [*]u8 = @ptrFromInt(request.buf_ptr);
    const copy_len = @min(data.len, request.buf_len);
    @memcpy(buf_ptr[0..copy_len], data[0..copy_len]);

    _ = request.complete(.{ .success = copy_len });
    return true;
}

/// Complete pending connect request (called from TCP layer on handshake completion)
/// Returns true if a pending request was completed
pub fn completePendingConnect(socket_idx: usize, success: bool) bool {
    const sock = state.acquireSocket(socket_idx) orelse return false;
    defer state.releaseSocket(sock);

    const pending = sock.pending_connect orelse return false;
    const request: *IoRequest = @ptrCast(@alignCast(pending));
    sock.pending_connect = null;

    if (success) {
        _ = request.complete(.{ .success = 0 });
    } else {
        _ = request.complete(.{ .err = error.ECONNREFUSED });
    }
    return true;
}

/// Complete pending send request (called from TCP layer when buffer space available)
/// Returns true if a pending request was completed
pub fn completePendingSend(socket_idx: usize, bytes_sent: usize) bool {
    const sock = state.acquireSocket(socket_idx) orelse return false;
    defer state.releaseSocket(sock);

    const pending = sock.pending_send orelse return false;
    const request: *IoRequest = @ptrCast(@alignCast(pending));
    sock.pending_send = null;

    _ = request.complete(.{ .success = bytes_sent });
    return true;
}
