// Socket option plumbing (setsockopt/getsockopt) plus timeout helpers.

const types = @import("types.zig");
const state = @import("state.zig");
const errors = @import("errors.zig");

/// Set socket option
/// level: SOL_SOCKET, IPPROTO_IP, IPPROTO_TCP
/// optname: option to set
/// optval: pointer to option value
/// optlen: length of option value
pub fn setsockopt(sock_fd: usize, level: i32, optname: i32, optval: [*]const u8, optlen: usize) errors.SocketError!void {
    const sock = state.getSocket(sock_fd) orelse return errors.SocketError.BadFd;

    if (level == types.SOL_SOCKET) {
        switch (optname) {
            types.SO_RCVTIMEO => {
                if (optlen < @sizeOf(types.TimeVal)) return errors.SocketError.InvalidArg;
                const tv: *const types.TimeVal = @ptrCast(@alignCast(optval));
                // Validate microseconds field
                if (tv.tv_usec < 0 or tv.tv_usec >= 1_000_000) {
                    return errors.SocketError.InvalidArg;
                }
                sock.rcv_timeout_ms = tv.toMillis();
            },
            types.SO_SNDTIMEO => {
                if (optlen < @sizeOf(types.TimeVal)) return errors.SocketError.InvalidArg;
                const tv: *const types.TimeVal = @ptrCast(@alignCast(optval));
                if (tv.tv_usec < 0 or tv.tv_usec >= 1_000_000) {
                    return errors.SocketError.InvalidArg;
                }
                sock.snd_timeout_ms = tv.toMillis();
            },
            types.SO_BROADCAST => {
                if (optlen < 4) return errors.SocketError.InvalidArg;
                const val: *const i32 = @ptrCast(@alignCast(optval));
                sock.so_broadcast = (val.* != 0);
            },
            types.SO_REUSEADDR => {
                if (optlen < 4) return errors.SocketError.InvalidArg;
                const val: *const i32 = @ptrCast(@alignCast(optval));
                sock.so_reuseaddr = (val.* != 0);
            },
            else => return errors.SocketError.InvalidArg,
        }
    } else if (level == types.IPPROTO_IP) {
        switch (optname) {
            types.IP_TOS => {
                if (optlen < 1) return errors.SocketError.InvalidArg;
                sock.tos = optval[0];
                // Propagate ToS to TCB if connected (TCP)
                if (sock.tcb) |tcb| {
                    tcb.tos = sock.tos;
                }
            },
            types.IP_ADD_MEMBERSHIP => {
                if (optlen < @sizeOf(types.IpMreq)) return errors.SocketError.InvalidArg;
                const mreq: *const types.IpMreq = @ptrCast(@alignCast(optval));
                const group_ip = mreq.getMultiaddr();

                // Validate multicast address (224.0.0.0 - 239.255.255.255)
                const first_octet = (group_ip >> 24) & 0xFF;
                if (first_octet < 224 or first_octet > 239) {
                    return errors.SocketError.InvalidArg;
                }

                // Add to socket's multicast group list
                if (!sock.addMulticastGroup(group_ip)) {
                    return errors.SocketError.NoResources; // No slots available
                }
            },
            types.IP_DROP_MEMBERSHIP => {
                if (optlen < @sizeOf(types.IpMreq)) return errors.SocketError.InvalidArg;
                const mreq: *const types.IpMreq = @ptrCast(@alignCast(optval));
                const group_ip = mreq.getMultiaddr();

                // Remove from socket's multicast group list
                if (!sock.dropMulticastGroup(group_ip)) {
                    return errors.SocketError.AddrNotAvail; // Not a member
                }
            },
            types.IP_MULTICAST_TTL => {
                if (optlen < 1) return errors.SocketError.InvalidArg;
                sock.multicast_ttl = optval[0];
            },
            else => return errors.SocketError.InvalidArg,
        }
    } else {
        return errors.SocketError.InvalidArg;
    }
}

/// Get socket option
/// level: SOL_SOCKET, IPPROTO_IP, IPPROTO_TCP
/// optname: option to get
/// optval: pointer to store option value
/// optlen: pointer to length (in/out)
pub fn getsockopt(sock_fd: usize, level: i32, optname: i32, optval: [*]u8, optlen: *usize) errors.SocketError!void {
    const sock = state.getSocket(sock_fd) orelse return errors.SocketError.BadFd;

    if (level == types.SOL_SOCKET) {
        switch (optname) {
            types.SO_RCVTIMEO => {
                if (optlen.* < @sizeOf(types.TimeVal)) return errors.SocketError.InvalidArg;
                const tv: *types.TimeVal = @ptrCast(@alignCast(optval));
                tv.* = types.TimeVal.fromMillis(sock.rcv_timeout_ms);
                optlen.* = @sizeOf(types.TimeVal);
            },
            types.SO_SNDTIMEO => {
                if (optlen.* < @sizeOf(types.TimeVal)) return errors.SocketError.InvalidArg;
                const tv: *types.TimeVal = @ptrCast(@alignCast(optval));
                tv.* = types.TimeVal.fromMillis(sock.snd_timeout_ms);
                optlen.* = @sizeOf(types.TimeVal);
            },
            types.SO_BROADCAST => {
                if (optlen.* < 4) return errors.SocketError.InvalidArg;
                const val: *i32 = @ptrCast(@alignCast(optval));
                val.* = if (sock.so_broadcast) 1 else 0;
                optlen.* = 4;
            },
            types.SO_REUSEADDR => {
                if (optlen.* < 4) return errors.SocketError.InvalidArg;
                const val: *i32 = @ptrCast(@alignCast(optval));
                val.* = if (sock.so_reuseaddr) 1 else 0;
                optlen.* = 4;
            },
            else => return errors.SocketError.InvalidArg,
        }
    } else if (level == types.IPPROTO_IP) {
        switch (optname) {
            types.IP_TOS => {
                if (optlen.* < 1) return errors.SocketError.InvalidArg;
                optval[0] = sock.tos;
                optlen.* = 1;
            },
            else => return errors.SocketError.InvalidArg,
        }
    } else {
        return errors.SocketError.InvalidArg;
    }
}

/// Get receive timeout for a socket in milliseconds
/// Returns 0 for infinite timeout
pub fn getRecvTimeout(sock_fd: usize) u64 {
    const sock = state.getSocket(sock_fd) orelse return 0;
    return sock.rcv_timeout_ms;
}

/// Get send timeout for a socket in milliseconds
/// Returns 0 for infinite timeout
pub fn getSendTimeout(sock_fd: usize) u64 {
    const sock = state.getSocket(sock_fd) orelse return 0;
    return sock.snd_timeout_ms;
}
