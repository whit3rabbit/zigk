// TCP-facing socket helpers.

const std = @import("std");
const tcp = @import("../tcp.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const tcp_state = @import("../tcp/state.zig");
const errors = @import("errors.zig");
const scheduler = @import("scheduler.zig");
const ipv6_transmit = @import("../../ipv6/ipv6/transmit.zig");
const platform = @import("../../platform.zig");
const clock = @import("../../clock.zig");

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
    // Use interface IP if socket is unbound (local_addr is .none or unspecified v4/v6)
    const local_addr = if (sock.local_addr.isUnspecified())
        @import("../../core/addr.zig").IpAddr{ .v4 = iface.ip_addr }
    else
        sock.local_addr;

    const listen_tcb = tcp.listenIp(local_addr, sock.local_port, sock_fd) catch {
        return errors.SocketError.NoSocketsAvailable;
    };

    sock.tcb = listen_tcb;
    sock.backlog = @intCast(@min(backlog_arg, types.ACCEPT_QUEUE_SIZE));

    // Copy socket options to listening TCB (for inheritance to child connections)
    listen_tcb.tos = sock.tos;
    listen_tcb.nodelay = sock.tcp_nodelay;
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

        // Check accept queue under socket lock
        {
            const held = sock.lock.acquire();
            if (sock.accept_count > 0) {
                const tcb = sock.accept_queue[sock.accept_tail] orelse {
                    held.release();
                    state.releaseSocket(sock);
                    return errors.SocketError.WouldBlock;
                };
                sock.accept_queue[sock.accept_tail] = null;
                sock.accept_tail = (sock.accept_tail + 1) % types.ACCEPT_QUEUE_SIZE;
                sock.accept_count -= 1;

                held.release();
                state.releaseSocket(sock);
                accepted_tcb = tcb;
                break; // Found one!
            }

            // No connections available
            if (!sock.blocking) {
                held.release();
                state.releaseSocket(sock);
                return errors.SocketError.WouldBlock;
            }

            // Blocking: Prepare to sleep
            if (scheduler.blockFn()) |block_fn| {
                const get_current = scheduler.currentThreadFn() orelse {
                    held.release();
                    state.releaseSocket(sock);
                    return errors.SocketError.SystemError;
                };

                sock.blocked_thread = get_current();
                held.release();

                // CRITICAL: Release socket ref before blocking!
                // calling queueAcceptConnection requires this lock.
                // If we hold it while sleeping, we deadlock.
                state.releaseSocket(sock);

                // block_fn() sets state=Blocked then atomically enables
                // interrupts and halts (STI; HLT sequence)
                block_fn();

                // SECURITY FIX: Do NOT access sock.blocked_thread here!
                // After releaseSocket(), another thread may have closed the socket,
                // dropping refcount to 0 and freeing the memory. Accessing sock
                // would be Use-After-Free.
                //
                // The blocked_thread field will be cleared by:
                // 1. queueAcceptConnection() when it wakes us (sets to null after wake)
                // 2. close() which clears the socket state before freeing
                //
                // If we wake spuriously, the next loop iteration re-acquires the
                // socket and will either find data or re-register blocked_thread.
                //
                // Woke up - loop around to re-acquire locks and check queue
                continue;
            } else {
                held.release();
                state.releaseSocket(sock);
                return errors.SocketError.WouldBlock;
            }
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
    new_sock.local_addr = tcb.local_addr;
    new_sock.tcp_nodelay = tcb.nodelay;
    state.retainPort(new_sock.local_port);
    new_sock.tcp_nodelay = tcb.nodelay;

    // Fill peer address if requested
    if (peer_addr) |addr| {
        addr.* = types.SockAddrIn.init(tcb.getRemoteIpV4(), tcb.remote_port);
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
    const IpAddr = @import("../../core/addr.zig").IpAddr;

    // Auto-bind if not bound
    if (sock.local_port == 0) {
        sock.local_port = state.allocateEphemeralPort();
    }

    // Use interface IP if socket is unbound
    const local_addr = if (sock.local_addr.isUnspecified())
        IpAddr{ .v4 = iface.ip_addr }
    else
        sock.local_addr;

    // Destination is IPv4 from SockAddrIn
    const remote_addr = IpAddr{ .v4 = dest_addr.getAddr() };
    const remote_port = dest_addr.getPort();

    // Initiate connection using polymorphic API
    const tcb = tcp.connectIp(local_addr, sock.local_port, remote_addr, remote_port) catch |err| {
        return switch (err) {
            tcp.TcpError.NoResources => errors.SocketError.NoSocketsAvailable,
            tcp.TcpError.AlreadyConnected => errors.SocketError.AlreadyConnected,
            tcp.TcpError.NetworkError => errors.SocketError.NetworkUnreachable,
            else => errors.SocketError.NetworkUnreachable,
        };
    };

    sock.tcb = tcb;
    tcb.nodelay = sock.tcp_nodelay;

    // Store socket index in TCB for async completion lookup
    // This reuses parent_socket field (also used for server-side accept queue)
    tcb.parent_socket = sock_fd;

    // Copy socket options to TCB
    tcb.tos = sock.tos;
    tcb.rcv_buf_size = sock.rcv_buf_size;
    tcb.snd_buf_size = sock.snd_buf_size;

    // Capture generation for race checking
    const tcb_gen = tcb.generation;

    // Connection started - SYN sent
    
    // Handle blocking if requested
    if (sock.blocking) {
        if (scheduler.blockFn()) |block_fn| {
            const get_current = scheduler.currentThreadFn() orelse return errors.SocketError.SystemError;

            // Loop until state changes from SynSent (or error occurs)
            while (true) {
                const connect_held = tcp_state.lock.acquire();
                const still_valid = tcp_state.isTcbValid(tcb) and sock.tcb == tcb and tcb.generation == tcb_gen;
                if (!still_valid) {
                    connect_held.release();
                    return errors.SocketError.ConnectionRefused;
                }

                if (tcb.state != .SynSent) {
                    tcb.blocked_thread = null;
                    connect_held.release();
                    break;
                }

                sock.blocked_thread = get_current();
                // Important: tcb.blocked_thread must also be set for TCP layer to wake us
                // when the handshake completes (SYN-SENT processing in rx.zig wakes this)
                tcb.blocked_thread = sock.blocked_thread;
                connect_held.release();

                block_fn(); // Implies enable interrupts + halt

                sock.blocked_thread = null;
            }
        } else {
             // If no scheduler (e.g. early boot), we can't block safely
             return errors.SocketError.WouldBlock;
        }
    }

    // Check final state - must re-fetch TCB under lock to prevent use-after-free
    const final_state = blk: {
        const final_held = tcp_state.lock.acquire();
        defer final_held.release();
        const final_tcb = sock.tcb;
        if (final_tcb == null) break :blk .Closed;
        if (!tcp_state.isTcbValid(final_tcb.?)) break :blk .Closed;
        break :blk final_tcb.?.state;
    };

    switch (final_state) {
        .Established => return,
        .Closed => return errors.SocketError.ConnectionRefused,
        .SynSent => return errors.SocketError.WouldBlock, // Should not happen if we blocked
        else => return, // Other states might imply connected or closing
    }
}

/// Initiate connection to remote IPv6 address (TCP only)
pub fn connect6(sock_fd: usize, dest_addr: *const types.SockAddrIn6) errors.SocketError!void {
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
    const IpAddr = @import("../../core/addr.zig").IpAddr;

    // Auto-bind if not bound
    if (sock.local_port == 0) {
        sock.local_port = state.allocateEphemeralPort();
    }

    // Select source address using RFC 6724 algorithm from IPv6 transmit module
    const remote_v6 = dest_addr.addr;
    const local_v6 = ipv6_transmit.selectSourceAddress(iface, remote_v6) orelse {
        return errors.SocketError.NetworkUnreachable;
    };

    // Create IpAddr from IPv6 addresses
    const local_addr = IpAddr{ .v6 = local_v6 };
    const remote_addr = IpAddr{ .v6 = remote_v6 };
    const remote_port = dest_addr.getPort();

    // Initiate connection using polymorphic API
    const tcb = tcp.connectIp(local_addr, sock.local_port, remote_addr, remote_port) catch |err| {
        return switch (err) {
            tcp.TcpError.NoResources => errors.SocketError.NoSocketsAvailable,
            tcp.TcpError.AlreadyConnected => errors.SocketError.AlreadyConnected,
            tcp.TcpError.NetworkError => errors.SocketError.NetworkUnreachable,
            else => errors.SocketError.NetworkUnreachable,
        };
    };

    sock.tcb = tcb;
    sock.family = types.AF_INET6;
    sock.local_addr = local_addr;
    tcb.nodelay = sock.tcp_nodelay;

    // Store socket index in TCB for async completion lookup
    tcb.parent_socket = sock_fd;

    // Copy socket options to TCB
    tcb.tos = sock.tos;
    tcb.rcv_buf_size = sock.rcv_buf_size;
    tcb.snd_buf_size = sock.snd_buf_size;

    // Capture generation for race checking
    const tcb_gen = tcb.generation;

    // Connection started - SYN sent

    // Handle blocking if requested
    if (sock.blocking) {
        if (scheduler.blockFn()) |block_fn| {
            const get_current = scheduler.currentThreadFn() orelse return errors.SocketError.SystemError;

            // Loop until state changes from SynSent (or error occurs)
            while (true) {
                const connect_held = tcp_state.lock.acquire();
                const still_valid = tcp_state.isTcbValid(tcb) and sock.tcb == tcb and tcb.generation == tcb_gen;
                if (!still_valid) {
                    connect_held.release();
                    return errors.SocketError.ConnectionRefused;
                }

                if (tcb.state != .SynSent) {
                    tcb.blocked_thread = null;
                    connect_held.release();
                    break;
                }

                sock.blocked_thread = get_current();
                tcb.blocked_thread = sock.blocked_thread;
                connect_held.release();

                block_fn();

                sock.blocked_thread = null;
            }
        } else {
            return errors.SocketError.WouldBlock;
        }
    }

    // Check final state
    const final_state = blk: {
        const final_held = tcp_state.lock.acquire();
        defer final_held.release();
        const final_tcb = sock.tcb;
        if (final_tcb == null) break :blk .Closed;
        if (!tcp_state.isTcbValid(final_tcb.?)) break :blk .Closed;
        break :blk final_tcb.?.state;
    };

    switch (final_state) {
        .Established => return,
        .Closed => return errors.SocketError.ConnectionRefused,
        .SynSent => return errors.SocketError.WouldBlock,
        else => return,
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
    const held = sock.lock.acquire();
    defer held.release();
    if (sock.accept_count >= sock.backlog) return false;

    sock.accept_queue[sock.accept_head] = tcb;
    sock.accept_head = (sock.accept_head + 1) % types.ACCEPT_QUEUE_SIZE;
    sock.accept_count += 1;

    // Wake any waiting thread
    scheduler.wakeThread(sock.blocked_thread);
    sock.blocked_thread = null;

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

/// TCP peek (for connected SOCK_STREAM sockets) - reads without consuming data.
/// Returns data from the receive buffer without advancing recv_tail or sending a
/// window update ACK. A subsequent tcpRecv (or tcpPeek) will return the same data.
pub fn tcpPeek(sock_fd: usize, buf: []u8) errors.SocketError!usize {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    if (sock.sock_type != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }

    const tcb = sock.tcb orelse return errors.SocketError.NotConnected;

    return tcp.peek(tcb, buf) catch |err| {
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

/// TCP receive with MSG_WAITALL semantics (for connected SOCK_STREAM sockets).
///
/// Accumulates bytes into buf until buf.len bytes are received, EOF (FIN), timeout,
/// or signal interruption -- whichever comes first. Returns the number of bytes
/// actually accumulated. Per POSIX MSG_WAITALL semantics:
///   - Returns buf.len if all bytes arrive before EOF/timeout/signal.
///   - Returns partial count on EOF (FIN), SO_RCVTIMEO expiry, or signal if bytes > 0.
///   - Returns TimedOut if no bytes received before SO_RCVTIMEO expiry.
///   - Returns WouldBlock if no bytes received and a signal is pending (caller maps to EINTR).
///
/// Locking: acquires sock once; tcp.recv acquires tcp_state.lock + tcb.mutex internally.
/// Blocking uses sock.lock (level 6), held only briefly to set blocked_thread before
/// releasing and calling block_fn(). This is the same pattern as udp_api.recvfromIp.
pub fn tcpRecvWaitall(sock_fd: usize, buf: []u8) errors.SocketError!usize {
    // Acquire socket reference for the duration of the accumulation loop.
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    if (sock.sock_type != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }

    const tcb = sock.tcb orelse return errors.SocketError.NotConnected;

    // SO_RCVTIMEO: convert ms to us; 0 means block indefinitely.
    const timeout_us: u64 = if (sock.rcv_timeout_ms > 0)
        std.math.mul(u64, sock.rcv_timeout_ms, 1000) catch std.math.maxInt(u64)
    else
        0;
    const start_tsc = clock.rdtsc();

    var offset: usize = 0;

    // Prefer scheduler-based blocking if available.
    if (scheduler.blockFn()) |block_fn| {
        const get_current = scheduler.currentThreadFn() orelse return errors.SocketError.SystemError;

        while (offset < buf.len) {
            // Check SO_RCVTIMEO before attempting receive.
            if (timeout_us > 0 and clock.hasTimedOut(start_tsc, timeout_us)) {
                if (offset > 0) return offset;
                return errors.SocketError.TimedOut;
            }

            // Attempt to receive into the remaining slice.
            const n = tcp.recv(tcb, buf[offset..]) catch |err| switch (err) {
                tcp.TcpError.WouldBlock => {
                    // No data yet. Enter blocking sub-loop.
                    // Disable interrupts, lock sock, register blocked_thread,
                    // then release lock and call block_fn() atomically.
                    const irq_state = platform.cpu.disableInterruptsSaveFlags();
                    {
                        const held = sock.lock.acquire();
                        sock.blocked_thread = get_current();
                        held.release();
                    }
                    block_fn();
                    sock.blocked_thread = null;
                    platform.cpu.restoreInterrupts(irq_state);

                    // Check for pending signal after wakeup.
                    if (scheduler.hasPendingSignal()) {
                        if (offset > 0) return offset;
                        return errors.SocketError.WouldBlock;
                    }

                    // After wakeup: check timeout and continue to retry receive.
                    if (timeout_us > 0 and clock.hasTimedOut(start_tsc, timeout_us)) {
                        if (offset > 0) return offset;
                        return errors.SocketError.TimedOut;
                    }
                    continue;
                },
                tcp.TcpError.NotConnected => {
                    if (offset > 0) return offset;
                    return errors.SocketError.NotConnected;
                },
                else => {
                    if (offset > 0) return offset;
                    return errors.SocketError.NetworkUnreachable;
                },
            };

            if (n == 0) {
                // EOF (FIN received): return whatever we have.
                break;
            }

            offset += n;
        }

        return offset;
    }

    // Fallback: HLT-based polling (no scheduler available).
    // No signal check needed: without a scheduler, hasPendingSignal() always
    // returns false and signal delivery is not operational.
    const timeout_ticks: usize = if (sock.rcv_timeout_ms > 0)
        @intCast(sock.rcv_timeout_ms) // 1 tick = 1ms
    else
        std.math.maxInt(usize);

    var ticks: usize = 0;
    while (offset < buf.len and ticks < timeout_ticks) {
        const n = tcp.recv(tcb, buf[offset..]) catch |err| switch (err) {
            tcp.TcpError.WouldBlock => {
                platform.cpu.enableInterrupts();
                platform.cpu.halt();
                ticks += 1;
                continue;
            },
            tcp.TcpError.NotConnected => {
                if (offset > 0) return offset;
                return errors.SocketError.NotConnected;
            },
            else => {
                if (offset > 0) return offset;
                return errors.SocketError.NetworkUnreachable;
            },
        };

        if (n == 0) {
            break; // EOF
        }
        offset += n;
    }

    if (offset == 0 and ticks >= timeout_ticks and sock.rcv_timeout_ms > 0) {
        return errors.SocketError.TimedOut;
    }

    return offset;
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

    var dequeued_tcb: ?*tcp.Tcb = null;
    {
        const held = sock.lock.acquire();
        defer held.release();

        if (sock.accept_count > 0) {
            // Connection available - dequeue while holding the socket lock
            const tcb = sock.accept_queue[sock.accept_tail] orelse {
                return errors.SocketError.SystemError;
            };
            sock.accept_queue[sock.accept_tail] = null;
            sock.accept_tail = (sock.accept_tail + 1) % types.ACCEPT_QUEUE_SIZE;
            sock.accept_count -= 1;
            dequeued_tcb = tcb;
        } else {
            // No connection available - store pending request
            if (sock.pending_accept != null) {
                // Already have a pending accept
                return errors.SocketError.WouldBlock;
            }
            sock.pending_accept = request;
            request.fd = @intCast(sock_fd);
            return false; // Pending
        }
    }

    const tcb = dequeued_tcb.?;

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
    new_sock.local_addr = tcb.local_addr;
    state.retainPort(new_sock.local_port);
    new_sock.tcp_nodelay = tcb.nodelay;

    // Complete with new fd
    _ = request.complete(.{ .success = new_sock_fd });
    return true;
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
    const IpAddr = @import("../../core/addr.zig").IpAddr;

    // Auto-bind if not bound
    if (sock.local_port == 0) {
        sock.local_port = state.allocateEphemeralPort();
    }

    // Use interface IP if socket is unbound
    const local_addr = if (sock.local_addr.isUnspecified())
        IpAddr{ .v4 = iface.ip_addr }
    else
        sock.local_addr;

    // Destination is IPv4 from SockAddrIn
    const remote_addr = IpAddr{ .v4 = dest_addr.getAddr() };
    const remote_port = dest_addr.getPort();

    // Initiate connection using polymorphic API
    const tcb = tcp.connectIp(local_addr, sock.local_port, remote_addr, remote_port) catch |err| {
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
    tcb.rcv_buf_size = sock.rcv_buf_size;
    tcb.snd_buf_size = sock.snd_buf_size;

    // Store socket index in TCB for async completion lookup
    tcb.parent_socket = sock_fd;

    // Store pending connect request - will be completed when handshake finishes
    sock.pending_connect = request;
    request.fd = @intCast(sock_fd);

    return false; // Pending - handshake in progress
}

/// Async connect to IPv6 address - queue request for connection establishment
/// Returns true if completed synchronously, false if pending
pub fn connectAsync6(sock_fd: usize, request: *IoRequest, dest_addr: *const types.SockAddrIn6) errors.SocketError!bool {
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
    const IpAddr = @import("../../core/addr.zig").IpAddr;

    // Auto-bind if not bound
    if (sock.local_port == 0) {
        sock.local_port = state.allocateEphemeralPort();
    }

    // Select source address using RFC 6724 algorithm from IPv6 transmit module
    const remote_v6 = dest_addr.addr;
    const local_v6 = ipv6_transmit.selectSourceAddress(iface, remote_v6) orelse {
        _ = request.complete(.{ .err = error.ENETUNREACH });
        return true;
    };

    // Create IpAddr from IPv6 addresses
    const local_addr = IpAddr{ .v6 = local_v6 };
    const remote_addr = IpAddr{ .v6 = remote_v6 };
    const remote_port = dest_addr.getPort();

    // Initiate connection using polymorphic API
    const tcb = tcp.connectIp(local_addr, sock.local_port, remote_addr, remote_port) catch |err| {
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
    sock.family = types.AF_INET6;
    sock.local_addr = local_addr;
    tcb.tos = sock.tos;
    tcb.rcv_buf_size = sock.rcv_buf_size;
    tcb.snd_buf_size = sock.snd_buf_size;

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

    const request: *IoRequest = blk: {
        const held = sock.lock.acquire();
        defer held.release();
        const pending = sock.pending_accept orelse return false;
        sock.pending_accept = null;
        break :blk @ptrCast(@alignCast(pending));
    };

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
    new_sock.local_addr = tcb.local_addr;

    _ = request.complete(.{ .success = new_sock_fd });
    return true;
}

/// Complete pending recv request (called from TCP layer when data arrives)
/// Returns true if a pending request was completed
///
/// SECURITY: This function runs in IRQ/softirq context (TCP RX path). We copy data
/// to the kernel bounce buffer here (safe), and finalizeBounceBuffer() copies to
/// user space in syscall context via UserPtr (handles SMAP, page faults, TOCTOU).
pub fn completePendingRecv(socket_idx: usize, data: []const u8) bool {
    const sock = state.acquireSocket(socket_idx) orelse return false;
    defer state.releaseSocket(sock);

    // Access pending_recv under lock to prevent race with recvAsync
    const request: *IoRequest = blk: {
        const held = sock.lock.acquire();
        defer held.release();
        const pending = sock.pending_recv orelse return false;
        sock.pending_recv = null;
        break :blk @ptrCast(@alignCast(pending));
    };

    // Copy to kernel bounce buffer (allocated at io_uring submission in ops.zig).
    // finalizeBounceBuffer() handles the safe copy to user space in syscall context.
    const bounce = request.bounce_buf orelse {
        // No bounce buffer means non-io_uring path or allocation failure at submission.
        _ = request.complete(.{ .err = error.EFAULT });
        return true;
    };

    const copy_len = @min(data.len, bounce.len);
    @memcpy(bounce[0..copy_len], data[0..copy_len]);

    _ = request.complete(.{ .success = copy_len });
    return true;
}

/// Complete pending connect request (called from TCP layer on handshake completion)
/// Returns true if a pending request was completed
pub fn completePendingConnect(socket_idx: usize, success: bool) bool {
    const sock = state.acquireSocket(socket_idx) orelse return false;
    defer state.releaseSocket(sock);

    // Access pending_connect under lock to prevent race with connectAsync/timeout
    const request: *IoRequest = blk: {
        const held = sock.lock.acquire();
        defer held.release();
        const pending = sock.pending_connect orelse return false;
        sock.pending_connect = null;
        break :blk @ptrCast(@alignCast(pending));
    };

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

    // Access pending_send under lock to prevent race with sendAsync/timeout
    const request: *IoRequest = blk: {
        const held = sock.lock.acquire();
        defer held.release();
        const pending = sock.pending_send orelse return false;
        sock.pending_send = null;
        break :blk @ptrCast(@alignCast(pending));
    };

    _ = request.complete(.{ .success = bytes_sent });
    return true;
}
