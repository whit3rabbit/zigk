// UDP-facing socket helpers (sendto/recvfrom and delivery path).

const udp = @import("../udp.zig");
const ipv4 = @import("../../ipv4/ipv4.zig");
const packet = @import("../../core/packet.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const errors = @import("errors.zig");
const scheduler = @import("scheduler.zig");

pub fn sendto(
    sock_fd: usize,
    data: []const u8,
    dest_addr: *const types.SockAddrIn,
) errors.SocketError!usize {
    const sock = state.getSocket(sock_fd) orelse return errors.SocketError.BadFd;
    const iface = state.getInterface() orelse return errors.SocketError.NetworkDown;

    // Auto-bind if not bound
    if (sock.local_port == 0) {
        sock.local_port = state.allocateEphemeralPort();
    }

    const dst_ip = dest_addr.getAddr();
    const dst_port = dest_addr.getPort();

    // Check if destination is broadcast
    // SO_BROADCAST must be set to send to broadcast addresses
    if (dst_ip == 0xFFFFFFFF or ipv4.isBroadcast(dst_ip, iface.netmask)) {
        if (!sock.so_broadcast) {
            return errors.SocketError.AccessDenied; // EACCES - broadcast not permitted
        }
    }

    // Use socket's ToS value for IP header
    if (udp.sendDatagramWithTos(iface, dst_ip, sock.local_port, dst_port, data, sock.tos)) {
        return data.len;
    }

    return errors.SocketError.NetworkUnreachable;
}

pub fn recvfrom(
    sock_fd: usize,
    buf: []u8,
    src_addr: ?*types.SockAddrIn,
) errors.SocketError!usize {
    const sock = state.getSocket(sock_fd) orelse return errors.SocketError.BadFd;

    var src_ip: u32 = 0;
    var src_port: u16 = 0;

    // Non-blocking: check queue and return immediately
    if (!sock.blocking) {
        if (sock.dequeuePacket(buf, &src_ip, &src_port)) |len| {
            if (src_addr) |addr| {
                addr.* = types.SockAddrIn.init(src_ip, src_port);
            }
            return len;
        }
        return errors.SocketError.WouldBlock;
    }

    // Blocking path uses scheduler if available
    if (scheduler.blockFn()) |block_fn| {
        const get_current = scheduler.currentThreadFn() orelse return errors.SocketError.SystemError;
        sock.blocked_thread = get_current();

        while (!sock.hasData()) {
            block_fn();
        }

        sock.blocked_thread = null;

        if (sock.dequeuePacket(buf, &src_ip, &src_port)) |len| {
            if (src_addr) |addr| {
                addr.* = types.SockAddrIn.init(src_ip, src_port);
            }
            return len;
        }
        return errors.SocketError.SystemError;
    }

    // Fallback: spin-wait for data (no scheduler)
    var spin_count: usize = 0;
    while (spin_count < 1000000) : (spin_count += 1) {
        if (sock.dequeuePacket(buf, &src_ip, &src_port)) |len| {
            if (src_addr) |addr| {
                addr.* = types.SockAddrIn.init(src_ip, src_port);
            }
            return len;
        }
        // Yield CPU (basic spin)
        asm volatile ("pause");
    }

    return errors.SocketError.TimedOut;
}

/// Deliver a received UDP packet to the appropriate socket(s)
/// For broadcast/multicast packets, delivers to ALL matching sockets
pub fn deliverUdpPacket(pkt: *packet.PacketBuffer) bool {
    const udp_hdr = pkt.udpHeader();
    const dst_port = udp_hdr.getDstPort();
    const ip_hdr = pkt.ipHeader();
    const dst_ip = ip_hdr.getDstIp();

    // Extract payload once
    const payload_offset = pkt.transport_offset + packet.UDP_HEADER_SIZE;
    const udp_len = udp_hdr.getLength();
    if (udp_len <= packet.UDP_HEADER_SIZE) {
        return false;
    }
    const payload_len = udp_len - packet.UDP_HEADER_SIZE;

    if (payload_offset + payload_len > pkt.len) {
        return false;
    }

    const payload = pkt.data[payload_offset..][0..payload_len];

    // For broadcast/multicast, deliver to ALL matching sockets
    // For unicast, deliver to first matching socket only
    if (pkt.is_broadcast or pkt.is_multicast) {
        var delivered = false;

        for (state.getSocketTable()) |maybe_sock| {
            const sock = maybe_sock orelse continue;
            if (!sock.allocated) continue;
            if (sock.sock_type != types.SOCK_DGRAM) continue;
            if (sock.local_port != dst_port) continue;

            // Check address binding
            // Socket must be bound to INADDR_ANY or the specific destination
            if (sock.local_addr != 0 and sock.local_addr != dst_ip) continue;

            // For multicast, also check group membership
            if (pkt.is_multicast) {
                if (!sock.isMulticastMember(dst_ip)) continue;
            }

            // Deliver to this socket
            if (sock.enqueuePacket(payload, pkt.src_ip, pkt.src_port)) {
                delivered = true;
                // Wake blocked thread if any
                if (sock.blocked_thread) |thread| {
                    scheduler.wakeThread(thread);
                    sock.blocked_thread = null;
                }
            }
        }

        return delivered;
    }

    // Unicast delivery - find single matching socket
    const sock = state.findByPort(dst_port) orelse {
        return false; // No socket listening on this port
    };

    // Enqueue packet with source info
    if (sock.enqueuePacket(payload, pkt.src_ip, pkt.src_port)) {
        // Wake blocked thread if any
        if (sock.blocked_thread) |thread| {
            scheduler.wakeThread(thread);
            sock.blocked_thread = null;
        }
        return true;
    }
    return false;
}
