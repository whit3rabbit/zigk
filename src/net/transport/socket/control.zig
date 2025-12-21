// Connection control helpers: shutdown(), getsockname(), getpeername().

const types = @import("types.zig");
const state = @import("state.zig");
const errors = @import("errors.zig");
const scheduler = @import("scheduler.zig");
const tcp = @import("../tcp.zig");

/// Shutdown flags for shutdown() syscall
pub const SHUT_RD: i32 = 0; // Disable further receives
pub const SHUT_WR: i32 = 1; // Disable further sends
pub const SHUT_RDWR: i32 = 2; // Disable both

/// Shut down part of a full-duplex connection
/// how: SHUT_RD (0), SHUT_WR (1), or SHUT_RDWR (2)
pub fn shutdown(sock_fd: usize, how: i32) errors.SocketError!void {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    const held = sock.lock.acquire();
    defer held.release();

    // Validate 'how' parameter
    if (how != SHUT_RD and how != SHUT_WR and how != SHUT_RDWR) {
        return errors.SocketError.InvalidArg;
    }

    // Handle read shutdown
    if (how == SHUT_RD or how == SHUT_RDWR) {
        sock.shutdown_read = true;
        // Wake any blocked reader so they get EOF/error
        if (sock.blocked_thread) |t| {
            scheduler.wakeThread(t);
            sock.blocked_thread = null;
        }
    }

    // Handle write shutdown
    if (how == SHUT_WR or how == SHUT_RDWR) {
        sock.shutdown_write = true;
        // For TCP: send FIN to notify peer
        if (sock.sock_type == types.SOCK_STREAM) {
            if (sock.tcb) |tcb| {
                // Only send FIN if connection is established
                tcp.sendFinPacket(tcb);
            }
        }
    }
}

/// Get local socket address
/// Returns local IP and port bound to this socket
pub fn getsockname(sock_fd: usize, addr: *types.SockAddrIn) errors.SocketError!void {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    const held = sock.lock.acquire();
    defer held.release();

    // Get local address - use interface IP if bound to INADDR_ANY
    var local_ip = sock.local_addr;
    if (local_ip == 0) {
        // Return actual interface IP if available
        if (state.getInterface()) |iface| {
            local_ip = iface.ip_addr;
        }
    }

    // Fill in address structure
    addr.family = types.AF_INET;
    addr.port = types.htons(sock.local_port);
    addr.addr = types.htonl(local_ip);
    addr.zero = [_]u8{0} ** 8;
}

/// Get peer socket address (for connected sockets)
/// Returns remote IP and port of connected peer
pub fn getpeername(sock_fd: usize, addr: *types.SockAddrIn) errors.SocketError!void {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    const held = sock.lock.acquire();
    defer held.release();

    // TCP: get peer address from TCB
    if (sock.sock_type == types.SOCK_STREAM) {
        if (sock.tcb) |tcb| {
            // Must be connected (not listening)
            if (tcb.state != .Established and tcb.state != .CloseWait) {
                return errors.SocketError.NotConnected;
            }
            addr.family = types.AF_INET;
            addr.port = types.htons(tcb.remote_port);
            addr.addr = types.htonl(tcb.remote_ip);
            addr.zero = [_]u8{0} ** 8;
            return;
        }
        return errors.SocketError.NotConnected;
    }

    // UDP: connectionless - no peer address
    return errors.SocketError.NotConnected;
}
