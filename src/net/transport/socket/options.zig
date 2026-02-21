// Socket option plumbing (setsockopt/getsockopt) plus timeout helpers.

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const errors = @import("errors.zig");
const tcp_constants = @import("../tcp/constants.zig");

/// Set socket option
/// level: SOL_SOCKET, IPPROTO_IP, IPPROTO_TCP
/// optname: option to set
/// optval: pointer to option value
/// optlen: length of option value
pub fn setsockopt(sock_fd: usize, level: i32, optname: i32, optval: [*]const u8, optlen: usize) errors.SocketError!void {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    const held = sock.lock.acquire();
    defer held.release();

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
            types.SO_REUSEPORT => {
                if (optlen < 4) return errors.SocketError.InvalidArg;
                const val: *const i32 = @ptrCast(@alignCast(optval));
                sock.so_reuseport = (val.* != 0);
            },
            types.SO_RCVBUF => {
                if (optlen < 4) return errors.SocketError.InvalidArg;
                const val: *const i32 = @ptrCast(@alignCast(optval));
                if (val.* < 0) return errors.SocketError.InvalidArg;
                const requested: u32 = @intCast(@min(@as(u64, @intCast(val.*)), @as(u64, tcp_constants.BUFFER_SIZE)));
                sock.rcv_buf_size = @max(256, requested);
                if (sock.tcb) |tcb| {
                    tcb.rcv_buf_size = sock.rcv_buf_size;
                }
            },
            types.SO_SNDBUF => {
                if (optlen < 4) return errors.SocketError.InvalidArg;
                const val: *const i32 = @ptrCast(@alignCast(optval));
                if (val.* < 0) return errors.SocketError.InvalidArg;
                const requested: u32 = @intCast(@min(@as(u64, @intCast(val.*)), @as(u64, tcp_constants.BUFFER_SIZE)));
                sock.snd_buf_size = @max(256, requested);
                if (sock.tcb) |tcb| {
                    tcb.snd_buf_size = sock.snd_buf_size;
                }
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
                
                // Inform interface to accept this multicast group at MAC layer
                const iface = state.getInterface();
                if (iface) |ifc| {
                     // Map IPv4 multicast to Ethernet multicast: 01:00:5E:xx:xx:xx
                     // Low 23 bits of IP map to low 23 bits of MAC
                     var mac = [_]u8{ 0x01, 0x00, 0x5E, 0, 0, 0 };
                     const trailing = group_ip & 0x7FFFFF; // Mask low 23 bits (host order)
                     mac[3] = @truncate(trailing >> 16);
                     mac[4] = @truncate(trailing >> 8);
                     mac[5] = @truncate(trailing);
                     _ = ifc.joinMulticastMac(mac);
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
                
                // Inform interface to leave (refcounting would be better in a full stack, 
                // but for now we just leave if this socket leaves. NOTE: In a multi-socket 
                // system, this might break other sockets listening to same group. 
                // Keeping simple for MVP.)
                const iface = state.getInterface();
                if (iface) |ifc| {
                     var mac = [_]u8{ 0x01, 0x00, 0x5E, 0, 0, 0 };
                     const trailing = group_ip & 0x7FFFFF; 
                     mac[3] = @truncate(trailing >> 16);
                     mac[4] = @truncate(trailing >> 8);
                     mac[5] = @truncate(trailing);
                     _ = ifc.leaveMulticastMac(mac);
                }
            },
            types.IP_MULTICAST_TTL => {
                if (optlen < 1) return errors.SocketError.InvalidArg;
                sock.multicast_ttl = optval[0];
            },
            types.IP_TTL => {
                // Set unicast IP TTL (1-255, 0 would make packet unroutable)
                if (optlen < 4) return errors.SocketError.InvalidArg;
                const val: *const i32 = @ptrCast(@alignCast(optval));
                if (val.* < 1 or val.* > 255) return errors.SocketError.InvalidArg;
                sock.ttl = @intCast(@as(u32, @bitCast(val.*)));
            },
            else => return errors.SocketError.InvalidArg,
        }
    } else if (level == types.IPPROTO_TCP) {
        switch (optname) {
            types.TCP_NODELAY => {
                if (optlen < 4) return errors.SocketError.InvalidArg;
                const val: *const i32 = @ptrCast(@alignCast(optval));
                sock.tcp_nodelay = (val.* != 0);
                if (sock.tcb) |tcb| {
                    tcb.nodelay = sock.tcp_nodelay;
                }
            },
            types.TCP_CORK => {
                if (optlen < 4) return errors.SocketError.InvalidArg;
                const val: *const i32 = @ptrCast(@alignCast(optval));
                const new_cork = (val.* != 0);
                sock.tcp_cork = new_cork;
                if (sock.tcb) |tcb| {
                    tcb.tcp_cork = new_cork;
                    // When cork is cleared, flush pending data.
                    // Acquire tcb.mutex to match locking pattern of all other
                    // TCB mutation paths (RX processing, timer retransmit, send).
                    // Lock order: sock.lock (level 6) -> tcb.mutex (level 7).
                    if (!new_cork) {
                        const tx_data = @import("../tcp/tx/data.zig");
                        const tcb_held = tcb.mutex.acquire();
                        defer tcb_held.release();
                        _ = tx_data.transmitPendingData(tcb);
                    }
                }
            },
            else => return errors.SocketError.InvalidArg,
        }
    } else if (level == types.IPPROTO_IPV6) {
        switch (optname) {
            types.IPV6_JOIN_GROUP => {
                if (optlen < @sizeOf(types.Ipv6Mreq)) return errors.SocketError.InvalidArg;
                const mreq: *const types.Ipv6Mreq = @ptrCast(@alignCast(optval));
                const group_ip = mreq.getMultiaddr();

                // Validate multicast address (ff00::/8)
                if (group_ip[0] != 0xff) {
                    return errors.SocketError.InvalidArg;
                }

                // Add to socket's multicast group list
                if (!sock.addMulticastGroup6(group_ip)) {
                    return errors.SocketError.NoResources; // No slots available
                }

                // Inform interface to accept this multicast group at MAC layer
                // IPv6 multicast -> Ethernet: 33:33:xx:xx:xx:xx (last 4 bytes of IPv6 addr)
                const iface = state.getInterface();
                if (iface) |ifc| {
                    var mac = [_]u8{ 0x33, 0x33, 0, 0, 0, 0 };
                    mac[2] = group_ip[12];
                    mac[3] = group_ip[13];
                    mac[4] = group_ip[14];
                    mac[5] = group_ip[15];
                    _ = ifc.joinMulticastMac(mac);
                }
            },
            types.IPV6_LEAVE_GROUP => {
                if (optlen < @sizeOf(types.Ipv6Mreq)) return errors.SocketError.InvalidArg;
                const mreq: *const types.Ipv6Mreq = @ptrCast(@alignCast(optval));
                const group_ip = mreq.getMultiaddr();

                // Remove from socket's multicast group list
                if (!sock.dropMulticastGroup6(group_ip)) {
                    return errors.SocketError.AddrNotAvail; // Not a member
                }

                // Inform interface to leave
                const iface = state.getInterface();
                if (iface) |ifc| {
                    var mac = [_]u8{ 0x33, 0x33, 0, 0, 0, 0 };
                    mac[2] = group_ip[12];
                    mac[3] = group_ip[13];
                    mac[4] = group_ip[14];
                    mac[5] = group_ip[15];
                    _ = ifc.leaveMulticastMac(mac);
                }
            },
            types.IPV6_MULTICAST_HOPS => {
                if (optlen < 1) return errors.SocketError.InvalidArg;
                sock.multicast_hops_v6 = optval[0];
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
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    const held = sock.lock.acquire();
    defer held.release();

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
            types.SO_REUSEPORT => {
                if (optlen.* < 4) return errors.SocketError.InvalidArg;
                const val: *i32 = @ptrCast(@alignCast(optval));
                val.* = if (sock.so_reuseport) 1 else 0;
                optlen.* = 4;
            },
            types.SO_RCVBUF => {
                if (optlen.* < 4) return errors.SocketError.InvalidArg;
                const val: *i32 = @ptrCast(@alignCast(optval));
                // Linux ABI: getsockopt returns 2x the stored value
                const stored: u32 = if (sock.rcv_buf_size == 0) @intCast(tcp_constants.BUFFER_SIZE) else sock.rcv_buf_size;
                val.* = @intCast(@min(@as(u64, stored) * 2, @as(u64, std.math.maxInt(i32))));
                optlen.* = 4;
            },
            types.SO_SNDBUF => {
                if (optlen.* < 4) return errors.SocketError.InvalidArg;
                const val: *i32 = @ptrCast(@alignCast(optval));
                // Linux ABI: getsockopt returns 2x the stored value
                const stored: u32 = if (sock.snd_buf_size == 0) @intCast(tcp_constants.BUFFER_SIZE) else sock.snd_buf_size;
                val.* = @intCast(@min(@as(u64, stored) * 2, @as(u64, std.math.maxInt(i32))));
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
            types.IP_TTL => {
                if (optlen.* < 4) return errors.SocketError.InvalidArg;
                const val: *i32 = @ptrCast(@alignCast(optval));
                val.* = @intCast(sock.ttl);
                optlen.* = 4;
            },
            else => return errors.SocketError.InvalidArg,
        }
    } else if (level == types.IPPROTO_TCP) {
        switch (optname) {
            types.TCP_NODELAY => {
                if (optlen.* < 4) return errors.SocketError.InvalidArg;
                const val: *i32 = @ptrCast(@alignCast(optval));
                val.* = if (sock.tcp_nodelay) 1 else 0;
                optlen.* = 4;
            },
            types.TCP_CORK => {
                if (optlen.* < 4) return errors.SocketError.InvalidArg;
                const val: *i32 = @ptrCast(@alignCast(optval));
                val.* = if (sock.tcp_cork) 1 else 0;
                optlen.* = 4;
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
    const sock = state.acquireSocket(sock_fd) orelse return 0;
    defer state.releaseSocket(sock);
    return sock.rcv_timeout_ms;
}

/// Get send timeout for a socket in milliseconds
/// Returns 0 for infinite timeout
pub fn getSendTimeout(sock_fd: usize) u64 {
    const sock = state.acquireSocket(sock_fd) orelse return 0;
    defer state.releaseSocket(sock);
    return sock.snd_timeout_ms;
}
