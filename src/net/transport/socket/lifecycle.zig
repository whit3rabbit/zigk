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

    // Mask off flags like SOCK_NONBLOCK, SOCK_CLOEXEC
    // These valid flags are defined in uapi.socket (or standard Linux ABI)
    // For now we just mask the known type bits
    const SOCK_TYPE_MASK = 0xF; // types.SOCK_DGRAM/STREAM are small integers
    const type_masked = sock_type & SOCK_TYPE_MASK;

    if (type_masked != types.SOCK_DGRAM and type_masked != types.SOCK_STREAM) {
        return errors.SocketError.TypeNotSupported;
    }
    
    // TODO: Handle SOCK_NONBLOCK/CLOEXEC if we support them in the future
    // For now, we accept them but ignore them to allow initialization.

    const lock = state.socketLock();
    lock.acquire();
    defer lock.release();

    const slot = state.reserveSlot() orelse return errors.SocketError.NoSocketsAvailable;
    const new_sock = state.socket_allocator.create(types.Socket) catch return errors.SocketError.NoSocketsAvailable;
    new_sock.* = types.Socket.init();
    new_sock.allocated = true;
    new_sock.family = family;
    new_sock.sock_type = sock_type;
    new_sock.protocol = protocol;
    new_sock.refcount = 1; // Held by socket table entry

    if (!state.installSocket(slot, new_sock)) {
        state.socket_allocator.destroy(new_sock);
        return errors.SocketError.NoSocketsAvailable;
    }

    return slot;
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
        for (state.getSocketTable()) |maybe_other| {
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

    // 1. Remove from table prevent new lookups (UAF protection)
    sock.closing = true;
    state.clearSlot(sock_fd);

    // Close TCP connection if present
    if (sock.tcb) |tcb| {
        tcp.close(tcb);
        sock.tcb = null;
    }

    // Free any pending accept queue entries in user-space logic if needed,
    // but TCB destruction should handle TCBs.
    // The Socket struct accept_queue holds pointers to TCBs.
    for (&sock.accept_queue) |*entry| {
        if (entry.*) |tcb| {
            tcp.close(tcb);
            entry.* = null;
        }
    }

    // Drop table's reference; socket memory will be freed once all users release.
    state.releaseSocketLocked(sock);
}
