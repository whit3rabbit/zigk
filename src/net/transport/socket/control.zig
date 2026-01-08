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
///
/// SECURITY NOTE: No info leak risk here. Function either errors before touching addr
/// (BadFd at acquireSocket) or fully initializes all 4 fields including zero padding.
/// Syscall layer also zero-initializes addr before calling (defense in depth).
pub fn getsockname(sock_fd: usize, addr: *types.SockAddrIn) errors.SocketError!void {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    const held = sock.lock.acquire();
    defer held.release();

    // Get local address - use interface IP if bound to INADDR_ANY or .none
    const local_ip: u32 = blk: {
        if (sock.local_addr.isUnspecified()) {
            // Return actual interface IP if available
            if (state.getInterface()) |iface| {
                break :blk iface.ip_addr;
            }
            break :blk 0;
        }
        // Extract IPv4 address if bound to one
        break :blk switch (sock.local_addr) {
            .v4 => |ip| ip,
            else => 0, // IPv6 addresses can't be returned via SockAddrIn
        };
    };

    // Fill in address structure
    addr.family = @intCast(types.AF_INET);
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
            addr.addr = types.htonl(tcb.getRemoteIpV4());
            addr.zero = [_]u8{0} ** 8;
            return;
        }
        return errors.SocketError.NotConnected;
    }

    // UDP: connectionless - no peer address
    return errors.SocketError.NotConnected;
}

/// Get local socket address (IPv6)
/// Returns local IPv6 address and port bound to this socket
pub fn getsockname6(sock_fd: usize, addr: *types.SockAddrIn6) errors.SocketError!void {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    const held = sock.lock.acquire();
    defer held.release();

    // Verify this is an IPv6 socket
    if (sock.family != types.AF_INET6) {
        return errors.SocketError.AfNotSupported;
    }

    // Get local address - use interface IPv6 if bound to in6addr_any
    const local_addr: [16]u8 = blk: {
        if (sock.local_addr.isUnspecified()) {
            // Return actual interface IPv6 if available
            if (state.getInterface()) |iface| {
                // Prefer first global address, fall back to link-local
                if (iface.ipv6_addr_count > 0) {
                    break :blk iface.ipv6_addrs[0].addr;
                } else if (iface.has_link_local) {
                    break :blk iface.link_local_addr;
                }
            }
            break :blk [_]u8{0} ** 16;
        }
        // Extract IPv6 address if bound to one
        break :blk switch (sock.local_addr) {
            .v6 => |ip| ip,
            else => [_]u8{0} ** 16,
        };
    };

    // Fill in address structure
    addr.family = @intCast(types.AF_INET6);
    addr.port = types.htons(sock.local_port);
    addr.flowinfo = 0;
    addr.addr = local_addr;
    addr.scope_id = 0; // TODO: Track scope_id for link-local addresses
}

/// Get peer socket address (IPv6, for connected sockets)
/// Returns remote IPv6 address and port of connected peer
pub fn getpeername6(sock_fd: usize, addr: *types.SockAddrIn6) errors.SocketError!void {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    const held = sock.lock.acquire();
    defer held.release();

    // Verify this is an IPv6 socket
    if (sock.family != types.AF_INET6) {
        return errors.SocketError.AfNotSupported;
    }

    // TCP: get peer address from TCB
    if (sock.sock_type == types.SOCK_STREAM) {
        if (sock.tcb) |tcb| {
            // Must be connected (not listening)
            if (tcb.state != .Established and tcb.state != .CloseWait) {
                return errors.SocketError.NotConnected;
            }
            // Extract IPv6 from TCB remote_addr
            const remote_v6 = switch (tcb.remote_addr) {
                .v6 => |ip| ip,
                else => return errors.SocketError.AfNotSupported,
            };
            addr.family = @intCast(types.AF_INET6);
            addr.port = types.htons(tcb.remote_port);
            addr.flowinfo = 0;
            addr.addr = remote_v6;
            addr.scope_id = 0;
            return;
        }
        return errors.SocketError.NotConnected;
    }

    // UDP: connectionless - no peer address
    return errors.SocketError.NotConnected;
}
