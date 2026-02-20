// Raw socket helpers (sendto/recvfrom for SOCK_RAW).
//
// Raw sockets allow userspace to send and receive raw IP protocol payloads.
// Currently supports:
// - IPPROTO_ICMP (IPv4 ICMP for ping)
// - IPPROTO_ICMPV6 (IPv6 ICMPv6 for ping6)
//
// For ICMP, userspace provides the complete ICMP packet (type, code, checksum, data).
// The kernel handles IP header construction and routing.

const std = @import("std");
const icmp = @import("../icmp.zig");
const ipv4 = @import("../../ipv4/root.zig").ipv4;
const ipv6_mod = @import("../../ipv6/root.zig");
const ndp = ipv6_mod.ndp;
const packet = @import("../../core/packet.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const errors = @import("errors.zig");
const checksum_mod = @import("../../core/checksum.zig");
const ethernet = @import("../../ethernet/ethernet.zig");
const arp = @import("../../ipv4/root.zig").arp;
const tcp_state = @import("../tcp/state.zig"); // For TX buffer pool

/// Send raw ICMP packet to IPv4 destination
/// Data should contain the complete ICMP packet (type, code, checksum, payload).
/// If checksum is 0, the kernel will calculate it.
pub fn sendtoRaw(
    sock_fd: usize,
    data: []const u8,
    dest_addr: *const types.SockAddrIn,
) errors.SocketError!usize {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);
    const iface = state.getInterface() orelse return errors.SocketError.NetworkDown;

    // Validate this is a raw ICMP socket
    if (sock.sock_type != types.SOCK_RAW) {
        return errors.SocketError.TypeNotSupported;
    }
    if (sock.protocol != types.IPPROTO_ICMP) {
        return errors.SocketError.ProtoNotSupported;
    }

    // Minimum ICMP header size
    if (data.len < packet.ICMP_HEADER_SIZE) {
        return errors.SocketError.InvalidArg;
    }

    const dst_ip = dest_addr.getAddr();

    // Cannot send to broadcast addresses with raw sockets (security)
    if (dst_ip == 0xFFFFFFFF or ipv4.isBroadcast(dst_ip, iface.netmask)) {
        return errors.SocketError.AccessDenied;
    }

    // Cannot send to multicast (not supported for ICMP raw)
    if (ipv4.isMulticast(dst_ip)) {
        return errors.SocketError.AccessDenied;
    }

    // Resolve destination MAC via ARP
    const next_hop = iface.getGateway(dst_ip);
    const dst_mac = arp.resolveOrRequest(iface, next_hop, null) orelse {
        return errors.SocketError.NetworkUnreachable;
    };

    // Calculate sizes
    const eth_len = packet.ETH_HEADER_SIZE;
    const ip_len = packet.IP_HEADER_SIZE;
    const icmp_len = data.len;
    const total_len = eth_len + ip_len + icmp_len;

    // Use TX buffer pool to avoid large stack allocations
    const buf = tcp_state.allocTxBuffer() orelse return errors.SocketError.NoBuffers;
    defer tcp_state.freeTxBuffer(buf);

    if (total_len > buf.len) {
        return errors.SocketError.MsgSize;
    }

    // Build Ethernet header
    const eth: *packet.EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    // Build IP header
    const ip: *packet.Ipv4Header = @ptrCast(@alignCast(&buf[eth_len]));
    ip.version_ihl = 0x45; // Version 4, IHL 5 (no options)
    ip.tos = sock.tos;
    ip.setTotalLength(@truncate(ip_len + icmp_len));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000)); // Don't Fragment
    ip.ttl = sock.ttl;
    ip.protocol = ipv4.PROTO_ICMP;
    ip.checksum = 0;
    ip.setSrcIp(iface.ip_addr);
    ip.setDstIp(dst_ip);
    ip.checksum = checksum_mod.ipChecksum(buf[eth_len..][0..ip_len]);

    // Copy ICMP data from userspace
    @memcpy(buf[eth_len + ip_len ..][0..icmp_len], data);

    // Calculate ICMP checksum if user provided 0
    const icmp_hdr: *packet.IcmpHeader = @ptrCast(@alignCast(&buf[eth_len + ip_len]));
    if (icmp_hdr.checksum == 0) {
        icmp_hdr.checksum = checksum_mod.icmpChecksum(buf[eth_len + ip_len ..][0..icmp_len]);
    }

    // Transmit
    if (iface.transmit(buf[0..total_len])) {
        return data.len;
    }

    return errors.SocketError.NetworkUnreachable;
}

/// Receive raw packet from socket
/// Returns the ICMP payload (without IP header) in the provided buffer.
/// src_addr is filled with the source IP address.
/// Blocks until a packet arrives if sock.blocking is true.
pub fn recvfromRaw(
    sock_fd: usize,
    buf: []u8,
    src_addr: ?*types.SockAddrIn,
    flags: u32,
) errors.SocketError!usize {
    _ = flags; // TODO: Handle MSG_DONTWAIT, MSG_PEEK

    // Validate type using a quick acquire/release before the loop
    {
        const sock_check = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
        const ok = (sock_check.sock_type == types.SOCK_RAW);
        state.releaseSocket(sock_check);
        if (!ok) return errors.SocketError.TypeNotSupported;
    }

    while (true) {
        const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;

        const held = sock.lock.acquire();

        var ip_addr: types.IpAddr = .none;
        var src_port: u16 = 0;

        if (sock.dequeuePacketIp(buf, &ip_addr, &src_port)) |len| {
            held.release();
            state.releaseSocket(sock);
            if (src_addr) |addr| {
                addr.* = types.SockAddrIn{
                    .family = types.AF_INET,
                    .port = 0, // Raw sockets don't have ports
                    .addr = switch (ip_addr) {
                        .v4 => |v4| v4,
                        else => 0,
                    },
                    .zero = [_]u8{0} ** 8,
                };
            }
            return len;
        }

        if (!sock.blocking) {
            held.release();
            state.releaseSocket(sock);
            return errors.SocketError.WouldBlock;
        }

        // Blocking mode: sleep until packet delivered by network stack.
        // CRITICAL: release locks BEFORE calling block_fn() to prevent deadlock.
        if (types.scheduler.blockFn()) |block_fn| {
            const get_current = types.scheduler.currentThreadFn() orelse {
                held.release();
                state.releaseSocket(sock);
                return errors.SocketError.SystemError;
            };
            sock.blocked_thread = get_current();
            held.release();
            state.releaseSocket(sock);
            block_fn();
            continue; // Re-acquire and re-check
        } else {
            held.release();
            state.releaseSocket(sock);
            return errors.SocketError.WouldBlock;
        }
    }
}

/// Send raw ICMPv6 packet to IPv6 destination
/// Data should contain the complete ICMPv6 packet (type, code, checksum, payload).
/// If checksum is 0, the kernel will calculate it (including pseudo-header).
pub fn sendtoRaw6(
    sock_fd: usize,
    data: []const u8,
    dest_addr: *const types.SockAddrIn6,
) errors.SocketError!usize {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);
    const iface = state.getInterface() orelse return errors.SocketError.NetworkDown;

    // Validate this is a raw ICMPv6 socket
    if (sock.sock_type != types.SOCK_RAW) {
        return errors.SocketError.TypeNotSupported;
    }
    if (sock.protocol != types.IPPROTO_ICMPV6) {
        return errors.SocketError.ProtoNotSupported;
    }

    // Minimum ICMPv6 header size (type + code + checksum + data = 4 bytes min)
    if (data.len < 4) {
        return errors.SocketError.InvalidArg;
    }

    const dst_ipv6 = dest_addr.addr;

    // Cannot send to multicast addresses with raw sockets (security)
    // Note: Unlike IPv4, IPv6 has no broadcast - multicast replaces it
    if (ipv6_mod.ipv6.types.isMulticast(dst_ipv6)) {
        return errors.SocketError.AccessDenied;
    }

    // Resolve destination MAC via NDP
    const dst_mac = ndp.resolveOrRequest(iface, dst_ipv6, null) orelse {
        return errors.SocketError.NetworkUnreachable;
    };

    // Calculate sizes
    const eth_len = packet.ETH_HEADER_SIZE;
    const ip6_len = packet.IPV6_HEADER_SIZE;
    const icmp6_len = data.len;
    const total_len = eth_len + ip6_len + icmp6_len;

    // Use TX buffer pool to avoid large stack allocations
    const buf = tcp_state.allocTxBuffer() orelse return errors.SocketError.NoBuffers;
    defer tcp_state.freeTxBuffer(buf);

    if (total_len > buf.len) {
        return errors.SocketError.MsgSize;
    }

    // Build Ethernet header
    const eth: *packet.EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV6);

    // Build IPv6 header
    const ip6: *packet.Ipv6Header = @ptrCast(@alignCast(&buf[eth_len]));

    // Select source address based on destination scope (RFC 6724)
    const src_ipv6 = ipv6_mod.ipv6.transmit.selectSourceAddress(iface, dst_ipv6) orelse {
        return errors.SocketError.AddrNotAvail;
    };

    // Set version (6), traffic class (0), flow label (0)
    ip6.setVersionTcFlow(6, 0, 0);

    // Set payload length (ICMPv6 packet)
    ip6.setPayloadLength(@intCast(icmp6_len));

    // Next header = ICMPv6 (58)
    ip6.next_header = types.IPPROTO_ICMPV6;

    // Hop limit (use socket's TTL setting, default 64)
    ip6.hop_limit = sock.ttl;

    // Set addresses
    ip6.src_addr = src_ipv6;
    ip6.dst_addr = dst_ipv6;

    // Copy ICMPv6 data from userspace
    @memcpy(buf[eth_len + ip6_len ..][0..icmp6_len], data);

    // Calculate ICMPv6 checksum if user provided 0
    // ICMPv6 checksum includes pseudo-header (src, dst, length, next header)
    const icmp6_hdr: *ipv6_mod.icmpv6.Icmpv6Header = @ptrCast(@alignCast(&buf[eth_len + ip6_len]));
    if (icmp6_hdr.checksum == 0) {
        icmp6_hdr.checksum = checksum_mod.icmpv6Checksum(
            src_ipv6,
            dst_ipv6,
            buf[eth_len + ip6_len ..][0..icmp6_len],
        );
    }

    // Transmit
    if (iface.transmit(buf[0..total_len])) {
        return data.len;
    }

    return errors.SocketError.NetworkUnreachable;
}

/// Receive raw ICMPv6 packet from socket
/// Returns the ICMPv6 payload (without IPv6 header) in the provided buffer.
/// src_addr is filled with the source IPv6 address.
/// Blocks until a packet arrives if sock.blocking is true.
pub fn recvfromRaw6(
    sock_fd: usize,
    buf: []u8,
    src_addr: ?*types.SockAddrIn6,
    flags: u32,
) errors.SocketError!usize {
    _ = flags; // TODO: Handle MSG_DONTWAIT, MSG_PEEK

    // Validate type using a quick acquire/release before the loop
    {
        const sock_check = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
        const ok = (sock_check.sock_type == types.SOCK_RAW);
        state.releaseSocket(sock_check);
        if (!ok) return errors.SocketError.TypeNotSupported;
    }

    while (true) {
        const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;

        const held = sock.lock.acquire();

        var ip_addr: types.IpAddr = .none;
        var src_port: u16 = 0;

        if (sock.dequeuePacketIp(buf, &ip_addr, &src_port)) |len| {
            held.release();
            state.releaseSocket(sock);
            if (src_addr) |addr| {
                addr.* = types.SockAddrIn6{
                    .family = types.AF_INET6,
                    .port = 0, // Raw sockets don't have ports
                    .flowinfo = 0,
                    .addr = switch (ip_addr) {
                        .v6 => |v6| v6,
                        else => [_]u8{0} ** 16,
                    },
                    .scope_id = 0,
                };
            }
            return len;
        }

        if (!sock.blocking) {
            held.release();
            state.releaseSocket(sock);
            return errors.SocketError.WouldBlock;
        }

        // Blocking mode: sleep until packet delivered by network stack.
        // CRITICAL: release locks BEFORE calling block_fn() to prevent deadlock.
        if (types.scheduler.blockFn()) |block_fn| {
            const get_current = types.scheduler.currentThreadFn() orelse {
                held.release();
                state.releaseSocket(sock);
                return errors.SocketError.SystemError;
            };
            sock.blocked_thread = get_current();
            held.release();
            state.releaseSocket(sock);
            block_fn();
            continue; // Re-acquire and re-check
        } else {
            held.release();
            state.releaseSocket(sock);
            return errors.SocketError.WouldBlock;
        }
    }
}
