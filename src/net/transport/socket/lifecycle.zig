// Socket allocation, binding, and teardown.
// Keeps creation paths small so UDP/TCP modules can stay focused on protocol flow.

const types = @import("types.zig");
const state = @import("state.zig");
const errors = @import("errors.zig");
const tcp = @import("../tcp.zig");

pub fn socket(family: i32, sock_type: i32, protocol: i32) errors.SocketError!usize {
    // Validate parameters
    if (family != types.AF_INET) {
        return errors.SocketError.AfNotSupported;
    }

    if (sock_type != types.SOCK_DGRAM and sock_type != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }

    const lock = state.socketLock();
    lock.acquire();
    defer lock.release();

    // Check for free slot in existing table
    for (state.socket_table.items, 0..) |maybe_sock, i| {
        if (maybe_sock == null) {
            // Found empty slot, reuse it
            const new_sock = state.socket_allocator.create(types.Socket) catch return errors.SocketError.NoSocketsAvailable;
            new_sock.* = types.Socket.init();
            new_sock.allocated = true;
            new_sock.family = family;
            new_sock.sock_type = sock_type;
            new_sock.protocol = protocol;

            state.socket_table.items[i] = new_sock;
            return i;
        }
    }

    // No free slot, append new one
    const new_sock = state.socket_allocator.create(types.Socket) catch return errors.SocketError.NoSocketsAvailable;
    new_sock.* = types.Socket.init();
    new_sock.allocated = true;
    new_sock.family = family;
    new_sock.sock_type = sock_type;
    new_sock.protocol = protocol;

    state.socket_table.append(state.socket_allocator, new_sock) catch {
        state.socket_allocator.destroy(new_sock);
        return errors.SocketError.NoSocketsAvailable;
    };

    return state.socket_table.items.len - 1;
}

/// Bind socket to local address/port
pub fn bind(sock_fd: usize, addr: *const types.SockAddrIn) errors.SocketError!void {
     const lock = state.socketLock();
     lock.acquire();
     defer lock.release();

    const sock = state.getSocket(sock_fd) orelse return errors.SocketError.BadFd;

    const port = addr.getPort();
    const ip = addr.getAddr();

    // Check port isn't already in use
    if (port != 0) {
        for (state.socket_table.items) |maybe_other| {
            if (maybe_other) |other| {
                if (other.allocated and other.local_port == port) {
                    return errors.SocketError.AddrInUse;
                }
            }
        }
    }

    sock.local_port = if (port == 0) state.allocateEphemeralPort() else port;
    sock.local_addr = ip;
}

/// Close a socket
pub fn close(sock_fd: usize) errors.SocketError!void {
     const lock = state.socketLock();
     lock.acquire();
     defer lock.release();

    const sock = state.getSocket(sock_fd) orelse return errors.SocketError.BadFd;

    // Close TCP connection if present
    if (sock.tcb) |tcb| {
        tcp.closeTcb(tcb); // Assumed to be updated in tcp.zig or re-exported via root
        sock.tcb = null;
    }

    // Free any pending accept queue entries in user-space logic if needed,
    // but TCB destruction should handle TCBs.
    // The Socket struct accept_queue holds pointers to TCBs.
    for (&sock.accept_queue) |*entry| {
        if (entry.*) |tcb| {
             tcp.closeTcb(tcb);
            entry.* = null;
        }
    }

    // Free memory
    state.socket_allocator.destroy(sock);
    state.socket_table.items[sock_fd] = null;
}
