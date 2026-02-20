// Socket allocation, binding, and teardown.
// Keeps creation paths small so UDP/TCP modules can stay focused on protocol flow.

const types = @import("types.zig");
const state = @import("state.zig");
const errors = @import("errors.zig");
const tcp = @import("../tcp.zig");

pub fn socket(family: i32, sock_type: i32, protocol: i32) errors.SocketError!usize {
    // Validate parameters - support both IPv4 and IPv6
    if (family != types.AF_INET and family != types.AF_INET6) {
        return errors.SocketError.AfNotSupported;
    }

    // Mask off flags like SOCK_NONBLOCK, SOCK_CLOEXEC
    // These valid flags are defined in uapi.socket (or standard Linux ABI)
    // For now we just mask the known type bits
    const SOCK_TYPE_MASK = 0xF; // types.SOCK_DGRAM/STREAM are small integers
    const type_masked = sock_type & SOCK_TYPE_MASK;

    if (type_masked != types.SOCK_DGRAM and type_masked != types.SOCK_STREAM and type_masked != types.SOCK_RAW) {
        return errors.SocketError.TypeNotSupported;
    }

    // SOCK_RAW requires explicit protocol specification
    if (type_masked == types.SOCK_RAW) {
        // Support IPPROTO_ICMP (IPv4 ping) and IPPROTO_ICMPV6 (IPv6 ping6)
        if (protocol == types.IPPROTO_ICMPV6) {
            // Raw ICMPv6 sockets require IPv6 family
            if (family != types.AF_INET6) {
                return errors.SocketError.AfNotSupported;
            }
        } else if (protocol == types.IPPROTO_ICMP) {
            // Raw ICMP sockets require IPv4 family
            if (family != types.AF_INET) {
                return errors.SocketError.AfNotSupported;
            }
        } else {
            return errors.SocketError.ProtoNotSupported;
        }
    }
    
    // TODO: Handle SOCK_NONBLOCK/CLOEXEC if we support them in the future
    // For now, we accept them but ignore them to allow initialization.

    const held = state.lock.acquire();
    defer held.release();

    const slot = state.reserveSlot() orelse return errors.SocketError.NoSocketsAvailable;
    const new_sock = state.socket_allocator.create(types.Socket) catch return errors.SocketError.NoSocketsAvailable;
    new_sock.* = types.Socket.init();
    new_sock.allocated = true;
    new_sock.family = family;
    new_sock.sock_type = sock_type;
    new_sock.protocol = protocol;
    // refcount is initialized to 1 by Socket.init()

    if (!state.installSocket(slot, new_sock)) {
        state.socket_allocator.destroy(new_sock);
        return errors.SocketError.NoSocketsAvailable;
    }

    return slot;
}

/// Bind socket to local IPv4 address/port
pub fn bind(sock_fd: usize, addr: *const types.SockAddrIn) errors.SocketError!void {
    const ip = types.IpAddr{ .v4 = addr.getAddr() };
    return bindInternal(sock_fd, addr.getPort(), ip);
}

/// Bind socket to local IPv6 address/port
pub fn bind6(sock_fd: usize, addr: *const types.SockAddrIn6) errors.SocketError!void {
    const ip = types.IpAddr{ .v6 = addr.addr };
    return bindInternal(sock_fd, addr.getPort(), ip);
}

/// Internal bind implementation for both address families
fn bindInternal(sock_fd: usize, port: u16, ip: types.IpAddr) errors.SocketError!void {
    const held = state.lock.acquire();
    defer held.release();

    const sock = state.getSocketLocked(sock_fd) orelse return errors.SocketError.BadFd;

    // Check for port conflicts with SO_REUSEADDR logic (POSIX compliant)
    if (port != 0) {
        for (state.getSocketTable()) |maybe_other| {
            if (maybe_other) |other| {
                // Skip self and unallocated slots
                if (other == sock or !other.allocated) continue;
                // Skip if different port
                if (other.local_port != port) continue;

                // Check address overlap:
                // - Unspecified (0.0.0.0 / :: / .none) conflicts with any address
                // - Specific addresses conflict only with same address or unspecified
                const addrs_conflict = ip.isUnspecified() or
                    other.local_addr.isUnspecified() or
                    ip.eql(other.local_addr);

                if (!addrs_conflict) continue;

                // Addresses and port conflict - check SO_REUSEADDR rules
                if (!canReuseAddress(sock, other)) {
                    return errors.SocketError.AddrInUse;
                }
            }
        }
    }

    if (port == 0) {
        sock.local_port = state.allocateEphemeralPortLocked();
    } else {
        sock.local_port = port;
        state.retainPortLocked(sock.local_port);
    }
    sock.local_addr = ip;

    // Register in lookup table if UDP
    if (sock.sock_type == types.SOCK_DGRAM) {
        state.registerUdpSocket(sock);
    }
}

/// Check if this socket can reuse the address of another socket.
/// Implements POSIX SO_REUSEADDR and SO_REUSEPORT semantics:
/// 1. SO_REUSEPORT: if both sockets have it set, always allow (even two LISTENs)
/// 2. SO_REUSEADDR: both must have it; TIME_WAIT allows reuse; no two LISTENs
/// 3. For UDP: just require both SO_REUSEADDR (load balancing use case)
fn canReuseAddress(new_sock: *types.Socket, existing: *types.Socket) bool {
    // SO_REUSEPORT: if both sockets have it set, always allow (even two LISTENs on same port).
    // This is the primary mechanism for multi-process/multi-thread load balancing.
    // SO_REUSEPORT check is first and is a blanket allow, bypassing TCP-specific restrictions.
    if (new_sock.so_reuseport and existing.so_reuseport) {
        return true;
    }

    // SO_REUSEADDR path: both sockets must have it set
    if (!new_sock.so_reuseaddr or !existing.so_reuseaddr) {
        return false;
    }

    // TCP-specific rules (SO_REUSEADDR path only)
    if (new_sock.sock_type == types.SOCK_STREAM and existing.sock_type == types.SOCK_STREAM) {
        // TIME_WAIT always allows reuse - this is the primary use case for
        // SO_REUSEADDR: allowing a server to restart and rebind immediately
        if (existing.tcb) |tcb| {
            if (tcb.state == tcp.TcpState.TimeWait) {
                return true;
            }
        }

        // CRITICAL: Prevent two LISTEN sockets on same addr:port with only SO_REUSEADDR.
        // (SO_REUSEPORT case is handled above -- it allows two LISTENs explicitly.)
        // Note: At bind() time, sockets typically don't have a TCB yet - the TCB and
        // Listen state are set later via listen() syscall. So most binds succeed here.
        const new_is_listen = if (new_sock.tcb) |tcb| tcb.state == tcp.TcpState.Listen else false;
        const existing_is_listen = if (existing.tcb) |tcb| tcb.state == tcp.TcpState.Listen else false;

        if (new_is_listen and existing_is_listen) {
            return false;
        }

        return true;
    }

    // UDP: allow with SO_REUSEADDR (multiple receivers on same port for load balancing)
    if (new_sock.sock_type == types.SOCK_DGRAM) {
        return true;
    }

    // Mixed types or unknown - disallow
    return false;
}

/// Close a socket
pub fn close(sock_fd: usize) errors.SocketError!void {
    var tcb_list: [types.ACCEPT_QUEUE_SIZE + 1]*tcp.Tcb = undefined;
    var tcb_count: usize = 0;

    {
        const held = state.lock.acquire();
        defer held.release();

        const sock = state.getSocketLocked(sock_fd) orelse return errors.SocketError.BadFd;

        // 1. Remove from table prevent new lookups (UAF protection)
        // SECURITY: Use atomic store for closing flag
        sock.closing.store(true, .release);
        state.releasePortLocked(sock.local_port);
        state.clearSlot(sock_fd);
        state.unregisterUdpSocket(sock);

        if (sock.tcb) |tcb| {
            tcb_list[tcb_count] = tcb;
            tcb_count += 1;
            sock.tcb = null;
        }

        // Free any pending accept queue entries in user-space logic if needed,
        // but TCB destruction should handle TCBs.
        // The Socket struct accept_queue holds pointers to TCBs.
        for (&sock.accept_queue) |*entry| {
            if (entry.*) |tcb| {
                if (tcb_count < tcb_list.len) {
                    tcb_list[tcb_count] = tcb;
                    tcb_count += 1;
                }
                entry.* = null;
            }
        }

        // Drop table's reference; socket memory will be freed once all users release.
        state.releaseSocketLocked(sock);
    }

    var i: usize = 0;
    while (i < tcb_count) : (i += 1) {
        tcp.close(tcb_list[i]);
    }
}
