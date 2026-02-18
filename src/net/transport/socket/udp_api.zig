// UDP-facing socket helpers (sendto/recvfrom and delivery path).

const std = @import("std");
const udp = @import("../udp.zig");
const ipv4 = @import("../../ipv4/root.zig").ipv4;
const ipv6_mod = @import("../../ipv6/root.zig");
const packet = @import("../../core/packet.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const errors = @import("errors.zig");
const scheduler = @import("scheduler.zig");
const platform = @import("../../platform.zig");
const clock = @import("../../clock.zig");
const addr_mod = @import("../../core/addr.zig");
const IpAddr = addr_mod.IpAddr;

pub fn sendto(
    sock_fd: usize,
    data: []const u8,
    dest_addr: *const types.SockAddrIn,
) errors.SocketError!usize {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);
    const iface = state.getInterface() orelse return errors.SocketError.NetworkDown;

    // Auto-bind if not bound
    if (sock.local_port == 0) {
        sock.local_port = state.allocateEphemeralPort();
        if (sock.local_port == 0) {
            return errors.SocketError.AddrNotAvail;
        }
        state.registerUdpSocket(sock);
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
        // Multicast Loopback
        // If sending to a multicast group, deliver a copy to local sockets that are members
        if (ipv4.isMulticast(dst_ip)) {
            const sock_held = state.lock.acquire();
            defer sock_held.release();
            
            // Iterate all sockets to find matching subscribers
            for (state.getSocketTable()) |maybe_s| {
                const s = maybe_s orelse continue;
                if (!s.allocated) continue;
                if (s.sock_type != types.SOCK_DGRAM) continue;
                
                // Must match destination port (and be bound to the group or INADDR_ANY)
                if (s.local_port != dst_port) continue;
                // For multicast, we don't strictly enforce local_addr match if it's a specific IP,
                // passing 0 (INADDR_ANY) matches, but also if s.local_addr is set, the socket
                // should still receive multicast if it joined the group.
                // Standard behavior: if bound to specific IP, only receive if dest IP matches limit
                // OR if it's multicast.
                
                // Check multicast membership
                if (!s.isMulticastMember(dst_ip)) continue;
                
                // Enqueue packet with per-socket lock
                {
                    const held = s.lock.acquire();
                    defer held.release();
                    if (s.enqueuePacket(data, iface.ip_addr, sock.local_port)) {
                        // Wake if blocked
                        if (s.blocked_thread) |thread| {
                            scheduler.wakeThread(thread);
                            s.blocked_thread = null;
                        }
                    }
                }
            }
        }
        return data.len;
    }

    return errors.SocketError.NetworkUnreachable;
}

/// Send UDP datagram to IPv6 destination
pub fn sendto6(
    sock_fd: usize,
    data: []const u8,
    dest_addr: *const types.SockAddrIn6,
) errors.SocketError!usize {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);
    const iface = state.getInterface() orelse return errors.SocketError.NetworkDown;

    // Auto-bind if not bound
    if (sock.local_port == 0) {
        sock.local_port = state.allocateEphemeralPort();
        if (sock.local_port == 0) {
            return errors.SocketError.AddrNotAvail;
        }
        state.registerUdpSocket(sock);
    }

    const dst_port = dest_addr.getPort();

    // Use socket's ToS value for Traffic Class
    if (udp.sendDatagram6WithTrafficClass(iface, dest_addr.addr, sock.local_port, dst_port, data, sock.tos)) {
        return data.len;
    }

    return errors.SocketError.NetworkUnreachable;
}

/// Receive UDP datagram with dual-stack support (returns IpAddr)
pub fn recvfromIp(
    sock_fd: usize,
    buf: []u8,
    src_addr: ?*IpAddr,
    src_port: ?*u16,
) errors.SocketError!usize {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    var ip_addr: IpAddr = .none;
    var port: u16 = 0;

    // Non-blocking: check queue and return immediately
    if (!sock.blocking) {
        const held = sock.lock.acquire();
        defer held.release();

        if (sock.dequeuePacketIp(buf, &ip_addr, &port)) |len| {
            if (src_addr) |addr| addr.* = ip_addr;
            if (src_port) |p| p.* = port;
            return len;
        }
        return errors.SocketError.WouldBlock;
    }

    // Blocking path uses scheduler if available
    if (scheduler.blockFn()) |block_fn| {
        const get_current = scheduler.currentThreadFn() orelse return errors.SocketError.SystemError;

        const timeout_us: u64 = if (sock.rcv_timeout_ms > 0)
            std.math.mul(u64, sock.rcv_timeout_ms, 1000) catch std.math.maxInt(u64)
        else
            0;
        const start_tsc = clock.rdtsc();

        while (true) {
            if (timeout_us > 0 and clock.hasTimedOut(start_tsc, timeout_us)) {
                return errors.SocketError.TimedOut;
            }

            const irq_state = platform.cpu.disableInterruptsSaveFlags();
            {
                const held = sock.lock.acquire();
                sock.blocked_thread = get_current();
                if (sock.dequeuePacketIp(buf, &ip_addr, &port)) |len| {
                    sock.blocked_thread = null;
                    held.release();
                    platform.cpu.restoreInterrupts(irq_state);
                    if (src_addr) |addr| addr.* = ip_addr;
                    if (src_port) |p| p.* = port;
                    return len;
                }
                held.release();
            }

            block_fn();
            sock.blocked_thread = null;
            platform.cpu.restoreInterrupts(irq_state);
        }
    }

    // Fallback: poll with HLT
    const timeout_ticks: usize = if (sock.rcv_timeout_ms > 0)
        @intCast(sock.rcv_timeout_ms) // 1 tick = 1ms
    else
        std.math.maxInt(usize); // Infinite timeout (0 means block forever)

    var ticks: usize = 0;
    while (ticks < timeout_ticks) : (ticks += 1) {
        {
            const held = sock.lock.acquire();
            if (sock.dequeuePacketIp(buf, &ip_addr, &port)) |len| {
                held.release();
                if (src_addr) |addr| addr.* = ip_addr;
                if (src_port) |p| p.* = port;
                return len;
            }
            held.release();
        }
        platform.cpu.enableInterrupts();
        platform.cpu.halt();
    }

    return errors.SocketError.TimedOut;
}

pub fn recvfrom(
    sock_fd: usize,
    buf: []u8,
    src_addr: ?*types.SockAddrIn,
) errors.SocketError!usize {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    var src_ip: u32 = 0;
    var src_port: u16 = 0;

    // Non-blocking: check queue and return immediately
    if (!sock.blocking) {
        const held = sock.lock.acquire();
        defer held.release();

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

        // Security: Track deadline for timeout enforcement.
        // Previously, this path ignored rcv_timeout_ms entirely, causing indefinite
        // blocking if no data arrived. An attacker who can prevent packets from
        // reaching the socket (e.g., network partition, or by keeping the sender
        // busy) could cause permanent thread starvation in the kernel.
        // Fix: Convert timeout_ms to TSC-based deadline and check it each iteration.
        const timeout_us: u64 = if (sock.rcv_timeout_ms > 0)
            std.math.mul(u64, sock.rcv_timeout_ms, 1000) catch std.math.maxInt(u64)
        else
            0; // 0 means block forever (no deadline)
        const start_tsc = clock.rdtsc();

        while (true) {
            // Security: Check timeout BEFORE blocking to bound total wait time.
            // This prevents indefinite hangs when no packets arrive.
            if (timeout_us > 0 and clock.hasTimedOut(start_tsc, timeout_us)) {
                return errors.SocketError.TimedOut;
            }

            // No data available - block atomically.
            // Disable interrupts before registering blocked_thread, then re-check
            // under the socket lock to prevent a lost wakeup.
            const irq_state = platform.cpu.disableInterruptsSaveFlags();
            {
                const held = sock.lock.acquire();
                sock.blocked_thread = get_current();
                if (sock.dequeuePacket(buf, &src_ip, &src_port)) |len| {
                    sock.blocked_thread = null;
                    held.release();
                    platform.cpu.restoreInterrupts(irq_state);
                    if (src_addr) |addr| {
                        addr.* = types.SockAddrIn.init(src_ip, src_port);
                    }
                    return len;
                }
                held.release();
            }

            // block_fn() sets state=Blocked then atomically enables
            // interrupts and halts (STI; HLT sequence)
            block_fn();
            sock.blocked_thread = null;
            platform.cpu.restoreInterrupts(irq_state);
            // Loop back to check for data (and re-check timeout)
        }
    }

    // Fallback: poll with HLT (no scheduler available)
    // This saves power compared to busy-spinning and respects socket timeout
    const timeout_ticks: usize = if (sock.rcv_timeout_ms > 0)
        @intCast(sock.rcv_timeout_ms) // 1 tick = 1ms
    else
        std.math.maxInt(usize); // Infinite timeout (0 means block forever)

    var ticks: usize = 0;
    while (ticks < timeout_ticks) : (ticks += 1) {
        // Check for data with lock held
        {
            const held = sock.lock.acquire();
            if (sock.dequeuePacket(buf, &src_ip, &src_port)) |len| {
                held.release();
                if (src_addr) |addr| {
                    addr.* = types.SockAddrIn.init(src_ip, src_port);
                }
                return len;
            }
            held.release();
        }
        // HLT atomically enables interrupts and halts until next interrupt
        // This is much more power-efficient than busy-spinning with pause
        platform.cpu.enableInterrupts();
        platform.cpu.halt();
    }

    return errors.SocketError.TimedOut;
}

/// Deliver a received UDP packet to the appropriate socket(s)
/// For broadcast/multicast packets, delivers to ALL matching sockets
pub fn deliverUdpPacket(pkt: *packet.PacketBuffer) bool {
    // Acquire global socket lock to prevent UAF (Use-After-Free)
    // if a socket is closed (freed) while we are iterating.
    const held = state.lock.acquire();
    defer held.release();

    const udp_hdr = packet.getUdpHeader(pkt.data, pkt.transport_offset) orelse return false;
    const dst_port = udp_hdr.getDstPort();
    const ip_hdr = packet.getIpv4Header(pkt.data, pkt.ip_offset) orelse return false;
    const dst_ip = ip_hdr.getDstIp();

    // Extract payload once
    const payload_offset = pkt.transport_offset + packet.UDP_HEADER_SIZE;
    const udp_len = udp_hdr.getLength();
    // SECURITY AUDIT 2026-01-06: This subtraction is safe because:
    // 1. udp_len is u16, UDP_HEADER_SIZE is comptime 8
    // 2. The check below guarantees udp_len > UDP_HEADER_SIZE before subtraction
    // 3. Therefore payload_len >= 1 and no underflow can occur
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
            // Check if bound to specific IP (and not broadcast)
            // RFC Compliance: If socket is bound to a specific IP, it should STILL accept broadcast
            // packets arriving on that interface, provided it's bound to INADDR_ANY or the specific IP.
            // The check below was too strict.
            // Use isUnspecified() to check if bound to any address
            if (!sock.local_addr.isUnspecified()) {
                // Socket is bound to a specific address, check if it matches
                const matches = switch (sock.local_addr) {
                    .v4 => |ip| ip == dst_ip,
                    else => false, // IPv6 addresses won't match IPv4 dst_ip
                };
                if (!matches and !pkt.is_broadcast and !pkt.is_multicast) continue;
            }

            // For multicast, also check group membership
            if (pkt.is_multicast) {
                if (!sock.isMulticastMember(dst_ip)) continue;
                // Note: we skip local_addr check for multicast so sockets bound to
                // specific interfaces can still receive multicast if they joined
            }

            // Deliver to this socket
            {
                const inner_sock_held = sock.lock.acquire();
                defer inner_sock_held.release();
                if (sock.enqueuePacket(payload, pkt.src_ip, pkt.src_port)) {
                    delivered = true;
                    // Wake blocked thread if any
                    if (sock.blocked_thread) |thread| {
                        scheduler.wakeThread(thread);
                        sock.blocked_thread = null;
                    }
                }
            }
        }

        return delivered;
    }

    // Unicast delivery - find single matching socket
    const sock = state.findUdpSocket(dst_port) orelse {
        return false; // No socket listening on this port
    };

    // Enqueue packet with source info
    {
        const unicast_sock_held = sock.lock.acquire();
        defer unicast_sock_held.release();
        if (sock.enqueuePacket(payload, pkt.src_ip, pkt.src_port)) {
            // Wake blocked thread if any
            if (sock.blocked_thread) |thread| {
                scheduler.wakeThread(thread);
                sock.blocked_thread = null;
            }
            return true;
        }
    }
    return false;
}

/// Deliver a received IPv6 UDP packet to the appropriate socket(s)
/// For multicast packets, delivers to ALL matching sockets
pub fn deliverUdpPacket6(pkt: *packet.PacketBuffer) bool {
    // Acquire global socket lock to prevent UAF
    const held = state.lock.acquire();
    defer held.release();

    const udp_hdr = packet.getUdpHeader(pkt.data, pkt.transport_offset) orelse return false;
    const dst_port = udp_hdr.getDstPort();

    // Extract payload once
    const payload_offset = pkt.transport_offset + packet.UDP_HEADER_SIZE;
    const udp_len = udp_hdr.getLength();
    // SECURITY AUDIT 2026-01-06: Same safety analysis as deliverUdpPacket (IPv4).
    // The <= check guarantees udp_len > UDP_HEADER_SIZE before subtraction.
    if (udp_len <= packet.UDP_HEADER_SIZE) {
        return false;
    }
    const payload_len = udp_len - packet.UDP_HEADER_SIZE;

    if (payload_offset + payload_len > pkt.len) {
        return false;
    }

    const payload = pkt.data[payload_offset..][0..payload_len];

    // Check if multicast
    const is_multicast = ipv6_mod.ipv6.types.isMulticast(pkt.dst_ipv6);

    // For multicast, deliver to ALL matching sockets
    if (is_multicast) {
        var delivered = false;

        for (state.getSocketTable()) |maybe_sock| {
            const sock = maybe_sock orelse continue;
            if (!sock.allocated) continue;
            if (sock.sock_type != types.SOCK_DGRAM) continue;
            if (sock.family != types.AF_INET6) continue;
            if (sock.local_port != dst_port) continue;

            // Check address binding
            if (!sock.local_addr.isUnspecified()) {
                const matches = switch (sock.local_addr) {
                    .v6 => |v6| std.mem.eql(u8, &v6, &pkt.dst_ipv6),
                    else => false,
                };
                if (!matches and !is_multicast) continue;
            }

            // Check IPv6 multicast group membership
            // Socket must have joined this multicast group via IPV6_JOIN_GROUP
            if (!sock.isMulticastMember6(pkt.dst_ipv6)) continue;

            // Deliver to this socket using IPv6 source address
            {
                const inner_sock_held = sock.lock.acquire();
                defer inner_sock_held.release();
                if (sock.enqueuePacketIp(payload, IpAddr{ .v6 = pkt.src_ipv6 }, pkt.src_port)) {
                    delivered = true;
                    // Wake blocked thread if any
                    if (sock.blocked_thread) |thread| {
                        scheduler.wakeThread(thread);
                        sock.blocked_thread = null;
                    }
                }
            }
        }

        return delivered;
    }

    // Unicast delivery - find single matching socket
    const sock = state.findUdpSocket6(dst_port, pkt.dst_ipv6) orelse {
        return false; // No socket listening on this port
    };

    // Enqueue packet with IPv6 source info
    {
        const unicast_sock_held = sock.lock.acquire();
        defer unicast_sock_held.release();
        if (sock.enqueuePacketIp(payload, IpAddr{ .v6 = pkt.src_ipv6 }, pkt.src_port)) {
            // Wake blocked thread if any
            if (sock.blocked_thread) |thread| {
                scheduler.wakeThread(thread);
                sock.blocked_thread = null;
            }
            return true;
        }
    }
    return false;
}
