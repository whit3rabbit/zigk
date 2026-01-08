// Socket subsystem shared state.
// Centralizes tables and interfaces so per-protocol modules stay focused.

const std = @import("std");
const types = @import("types.zig");
const sync = @import("../../sync.zig");
const interface = @import("../../core/interface.zig");
const platform = @import("../../platform.zig");

pub const Interface = interface.Interface;

/// Maximum number of sockets allowed system-wide.
/// Prevents resource exhaustion from malicious or buggy processes
/// repeatedly calling socket() without closing.
/// Value chosen to balance resource availability with DoS protection.
pub const MAX_SOCKETS: usize = 4096;

/// Ephemeral port range (RFC 6335)
const EPHEMERAL_START: u16 = 49152;
const EPHEMERAL_END: u16 = 65535;
const EPHEMERAL_RANGE_U16: u16 = EPHEMERAL_END - EPHEMERAL_START + 1; // 16384
const EPHEMERAL_RANGE: usize = @as(usize, EPHEMERAL_RANGE_U16);

/// Global socket table (dynamic array)
/// Stores pointers to sockets. Null entries are free slots.
pub var socket_table: std.ArrayListUnmanaged(?*types.Socket) = .{};
pub var socket_allocator: std.mem.Allocator = undefined;
/// UDP lookup table (Port -> Socket) for O(1) delivery
pub var udp_sockets: [65536]?*types.Socket = [_]?*types.Socket{null} ** 65536;
/// Ephemeral port usage counts (O(1) allocation)
var ephemeral_port_counts: [EPHEMERAL_RANGE]u16 = [_]u16{0} ** EPHEMERAL_RANGE;

/// Socket allocation lock - MUST be initialized before use
/// SECURITY: Uses IrqLock to ensure proper interrupt state management
pub var lock: sync.IrqLock = .{};

/// Global network interface (set during init)
var global_iface: ?*Interface = null;

/// Initialize socket subsystem.
/// SECURITY: This MUST be called before any socket operations.
pub fn init(iface: *Interface, allocator: std.mem.Allocator) void {
    // SECURITY: Initialize lock before first use
    lock.init();

    global_iface = iface;
    socket_allocator = allocator;
    socket_table = .{};
    udp_sockets = [_]?*types.Socket{null} ** 65536;
    ephemeral_port_counts = [_]u16{0} ** EPHEMERAL_RANGE;
}

pub fn getInterface() ?*Interface {
    return global_iface;
}

/// Acquire a socket with a reference count increment.
/// Returns null if the descriptor is invalid or closing.
/// SECURITY: Uses atomic tryRetain to prevent TOCTOU races.
pub fn acquireSocket(sock_fd: usize) ?*types.Socket {
    const held = lock.acquire();
    defer held.release();
    return acquireSocketLocked(sock_fd);
}

/// Internal: acquire socket while already holding lock.
/// SECURITY: Uses atomic tryRetain to atomically check closing and increment refcount.
fn acquireSocketLocked(sock_fd: usize) ?*types.Socket {
    if (sock_fd >= socket_table.items.len) return null;
    const sock = socket_table.items[sock_fd] orelse return null;
    if (!sock.allocated) return null;

    // SECURITY FIX: Atomically check closing and increment refcount.
    // This prevents TOCTOU race where another thread could set closing=true
    // between our check and refcount increment.
    if (sock.closing.load(.acquire)) return null;
    if (!sock.refcount.tryRetain()) return null;

    return sock;
}

/// Get socket without incrementing refcount (for internal lookups).
/// Caller must ensure socket lifetime through other means.
pub fn getSocket(sock_fd: usize) ?*types.Socket {
    const held = lock.acquire();
    defer held.release();
    if (sock_fd >= socket_table.items.len) return null;
    return socket_table.items[sock_fd];
}

/// Get socket without incrementing refcount - caller MUST hold lock.
pub fn getSocketLocked(sock_fd: usize) ?*types.Socket {
    if (sock_fd >= socket_table.items.len) return null;
    return socket_table.items[sock_fd];
}

pub fn getSocketTable() []?*types.Socket {
    return socket_table.items;
}

/// Release a socket reference.
/// SECURITY: Uses atomic release to ensure memory ordering.
pub fn releaseSocket(sock: *types.Socket) void {
    const held = lock.acquire();
    defer held.release();
    releaseSocketLocked(sock);
}

/// Internal: release socket while already holding lock.
/// SECURITY: Atomic refcount decrement prevents double-free races.
pub fn releaseSocketLocked(sock: *types.Socket) void {
    if (sock.refcount.release()) {
        // Last reference - safe to destroy
        socket_allocator.destroy(sock);
    }
}

fn findFreeSlot() ?usize {
    // Try to find an existing empty slot (reuse index)
    for (socket_table.items, 0..) |entry, idx| {
        if (entry == null) {
            return idx;
        }
    }
    // No free slots, append new one
    // We return the index of the new element (current len)
    return socket_table.items.len;
}

/// Allocate an ephemeral port using RFC 6056 Algorithm 1 (Simple Port Randomization).
/// Uses hardware entropy for random starting point to prevent port prediction attacks.
pub fn allocateEphemeralPort() u16 {
    const held = lock.acquire();
    defer held.release();
    return allocateEphemeralPortLocked();
}

/// Allocate an ephemeral port using RFC 6056 Algorithm 3 (Random Port Randomization).
/// Each attempt uses fresh entropy for stronger randomization.
/// Preferred for DNS queries where each query should have independent source port.
/// Security: Provides ~16 bits of port entropy combined with DNS transaction ID
/// for ~32 bits total unpredictability against cache poisoning (RFC 5452).
pub fn allocateRandomEphemeralPort() u16 {
    const held = lock.acquire();
    defer held.release();

    // Try random ports with fresh entropy each time (RFC 6056 Algorithm 3)
    // This provides maximum unpredictability for DNS security
    const MAX_RANDOM_ATTEMPTS: u16 = 64; // Limit random probes before fallback

    var attempts: u16 = 0;
    while (attempts < MAX_RANDOM_ATTEMPTS) : (attempts += 1) {
        const entropy = platform.entropy.getHardwareEntropy();
        const random_offset: u16 = @truncate(entropy % EPHEMERAL_RANGE_U16);
        const port = EPHEMERAL_START + random_offset;

        if (isEphemeralPortFreeLocked(port)) {
            return port;
        }
    }

    // Fallback to standard Algorithm 1 if random probing fails
    // (indicates high port pressure)
    return findEphemeralPortLocked();
}

/// Allocate an ephemeral port while holding state.lock.
pub fn allocateEphemeralPortLocked() u16 {
    // RFC 6056 Algorithm 1: Random starting point using hardware entropy
    const entropy = platform.entropy.getHardwareEntropy();
    const random_offset: u16 = @truncate(entropy % EPHEMERAL_RANGE_U16);
    var offset = random_offset;

    var attempts: u16 = 0;
    while (attempts < EPHEMERAL_RANGE_U16) : (attempts += 1) {
        const port = EPHEMERAL_START + offset;
        if (tryReserveEphemeralPortLocked(port)) {
            return port;
        }
        // Sequential probe from random start (wrap at range boundary)
        offset = if (offset + 1 == EPHEMERAL_RANGE_U16) 0 else offset + 1;
    }

    return 0; // No free ports
}

pub fn retainPort(port: u16) void {
    const held = lock.acquire();
    defer held.release();
    retainPortLocked(port);
}

pub fn releasePort(port: u16) void {
    const held = lock.acquire();
    defer held.release();
    releasePortLocked(port);
}

/// SECURITY NOTE: Saturation at maxInt(u16) is theoretical only. MAX_SOCKETS=4096
/// prevents reaching 65535 binds to same port. Saturation check prevents overflow.
pub fn retainPortLocked(port: u16) void {
    if (ephemeralIndex(port)) |idx| {
        if (ephemeral_port_counts[idx] != std.math.maxInt(u16)) {
            ephemeral_port_counts[idx] += 1;
        }
    }
}

pub fn releasePortLocked(port: u16) void {
    if (ephemeralIndex(port)) |idx| {
        if (ephemeral_port_counts[idx] > 0) {
            ephemeral_port_counts[idx] -= 1;
        } else {
            std.log.warn("ephemeral port underflow: port={}", .{port});
        }
    }
}

fn tryReserveEphemeralPortLocked(port: u16) bool {
    if (ephemeralIndex(port)) |idx| {
        if (ephemeral_port_counts[idx] == 0) {
            ephemeral_port_counts[idx] = 1;
            return true;
        }
    }
    return false;
}

fn isEphemeralPortFreeLocked(port: u16) bool {
    if (ephemeralIndex(port)) |idx| {
        return ephemeral_port_counts[idx] == 0;
    }
    return false;
}

fn findEphemeralPortLocked() u16 {
    // RFC 6056 Algorithm 1 without reservation (caller will bind later).
    const entropy = platform.entropy.getHardwareEntropy();
    const random_offset: u16 = @truncate(entropy % EPHEMERAL_RANGE_U16);
    var offset = random_offset;

    var attempts: u16 = 0;
    while (attempts < EPHEMERAL_RANGE_U16) : (attempts += 1) {
        const port = EPHEMERAL_START + offset;
        if (isEphemeralPortFreeLocked(port)) {
            return port;
        }
        offset = if (offset + 1 == EPHEMERAL_RANGE_U16) 0 else offset + 1;
    }

    return 0;
}

fn ephemeralIndex(port: u16) ?usize {
    if (port < EPHEMERAL_START or port > EPHEMERAL_END) return null;
    return @as(usize, port - EPHEMERAL_START);
}

pub fn findByPort(port: u16) ?*types.Socket {
    for (socket_table.items) |maybe_socket| {
        if (maybe_socket) |sock| {
            if (sock.allocated and sock.local_port == port) {
                return sock;
            }
        }
    }
    return null;
}

/// Find UDP socket by port (O(1) lookup)
pub fn findUdpSocket(port: u16) ?*types.Socket {
    return udp_sockets[port];
}

/// Find an IPv6 UDP socket matching port and optionally address
/// Uses O(n) scan since IPv6 sockets aren't port-indexed
pub fn findUdpSocket6(port: u16, dst_addr: [16]u8) ?*types.Socket {
    var wildcard_match: ?*types.Socket = null;

    // Search through socket table for AF_INET6 UDP sockets
    for (socket_table.items) |maybe_sock| {
        const sock = maybe_sock orelse continue;
        if (!sock.allocated) continue;
        if (sock.family != types.AF_INET6) continue;
        if (sock.sock_type != types.SOCK_DGRAM) continue;
        if (sock.local_port != port) continue;

        // Check address match
        switch (sock.local_addr) {
            .none => {
                // in6addr_any equivalent - matches any address
                wildcard_match = sock;
            },
            .v6 => |bound_addr| {
                if (std.mem.eql(u8, &bound_addr, &dst_addr)) {
                    return sock; // Exact match takes priority
                }
            },
            else => {}, // v4 won't match IPv6 packets
        }
    }

    return wildcard_match;
}

/// Find a raw socket matching protocol (e.g., IPPROTO_ICMPV6)
/// Used for delivering ICMPv6 echo replies to ping6 sockets.
/// Returns the first matching raw socket (raw sockets receive all matching packets).
pub fn findRawSocket6(protocol: i32) ?*types.Socket {
    // Search through socket table for AF_INET6 SOCK_RAW sockets
    for (socket_table.items) |maybe_sock| {
        const sock = maybe_sock orelse continue;
        if (!sock.allocated) continue;
        if (sock.family != types.AF_INET6) continue;
        if (sock.sock_type != types.SOCK_RAW) continue;
        if (sock.protocol != protocol) continue;

        return sock;
    }

    return null;
}

/// Find all raw sockets matching protocol and deliver packet to each.
/// Raw sockets receive a copy of matching packets (unlike TCP/UDP which are exclusive).
/// Returns number of sockets the packet was delivered to.
pub fn deliverToRawSockets6(protocol: i32, pkt_data: []const u8, src_ipv6: [16]u8) usize {
    var delivered: usize = 0;

    // Iterate through all sockets
    for (socket_table.items) |maybe_sock| {
        const sock = maybe_sock orelse continue;
        if (!sock.allocated) continue;
        if (sock.family != types.AF_INET6) continue;
        if (sock.sock_type != types.SOCK_RAW) continue;
        if (sock.protocol != protocol) continue;

        // Acquire socket lock to enqueue packet
        const sock_held = sock.lock.acquire();
        defer sock_held.release();

        // Check if there's room in the RX queue
        if (sock.rx_count < types.SOCKET_RX_QUEUE_SIZE) {
            // Copy packet to RX queue entry
            const entry = &sock.rx_queue[sock.rx_head];
            const copy_len = @min(pkt_data.len, types.MAX_PACKET_SIZE);
            @memcpy(entry.data[0..copy_len], pkt_data[0..copy_len]);
            entry.len = copy_len;
            entry.src_addr = .{ .v6 = src_ipv6 };
            entry.src_port = 0; // Raw sockets don't have ports

            sock.rx_head = (sock.rx_head + 1) % types.SOCKET_RX_QUEUE_SIZE;
            sock.rx_count += 1;

            delivered += 1;

            // Wake blocked thread if any
            if (sock.blocked_thread) |thread| {
                types.scheduler.wakeThread(thread);
                sock.blocked_thread = null;
            }
        }
    }

    return delivered;
}

/// Find all IPv4 raw sockets matching protocol and deliver packet to each.
/// Raw sockets receive a copy of matching packets (unlike TCP/UDP which are exclusive).
/// Used for delivering ICMP echo replies to ping sockets.
/// Returns number of sockets the packet was delivered to.
pub fn deliverToRawSockets4(protocol: i32, pkt_data: []const u8, src_ipv4: u32) usize {
    var delivered: usize = 0;

    // Iterate through all sockets
    for (socket_table.items) |maybe_sock| {
        const sock = maybe_sock orelse continue;
        if (!sock.allocated) continue;
        if (sock.family != types.AF_INET) continue;
        if (sock.sock_type != types.SOCK_RAW) continue;
        if (sock.protocol != protocol) continue;

        // Acquire socket lock to enqueue packet
        const sock_held = sock.lock.acquire();
        defer sock_held.release();

        // Check if there's room in the RX queue
        if (sock.rx_count < types.SOCKET_RX_QUEUE_SIZE) {
            // Copy packet to RX queue entry
            const entry = &sock.rx_queue[sock.rx_head];
            const copy_len = @min(pkt_data.len, types.MAX_PACKET_SIZE);
            @memcpy(entry.data[0..copy_len], pkt_data[0..copy_len]);
            entry.len = copy_len;
            entry.src_addr = .{ .v4 = src_ipv4 };
            entry.src_port = 0; // Raw sockets don't have ports
            entry.valid = true;

            sock.rx_head = (sock.rx_head + 1) % types.SOCKET_RX_QUEUE_SIZE;
            sock.rx_count += 1;

            delivered += 1;

            // Wake blocked thread if any
            if (sock.blocked_thread) |thread| {
                types.scheduler.wakeThread(thread);
                sock.blocked_thread = null;
            }
        }
    }

    return delivered;
}

pub fn registerUdpSocket(sock: *types.Socket) void {
    if (sock.local_port != 0 and sock.sock_type == types.SOCK_DGRAM) {
        udp_sockets[sock.local_port] = sock;
    }
}

pub fn unregisterUdpSocket(sock: *types.Socket) void {
    if (sock.local_port != 0 and sock.sock_type == types.SOCK_DGRAM) {
        if (udp_sockets[sock.local_port] == sock) {
            udp_sockets[sock.local_port] = null;
        }
    }
}

pub fn reserveSlot() ?usize {
    const slot = findFreeSlot() orelse return null;
    // SECURITY: Enforce MAX_SOCKETS limit to prevent resource exhaustion.
    // A malicious process could repeatedly call socket() to exhaust kernel heap.
    if (slot >= MAX_SOCKETS) {
        return null;
    }
    return slot;
}

pub fn installSocket(slot: usize, sock: *types.Socket) bool {
    // MAX_SOCKETS is enforced in reserveSlot() - no need to check here

    if (slot < socket_table.items.len) {
        // Reuse slot
        if (socket_table.items[slot] != null) return false;
        socket_table.items[slot] = sock;
        return true;
    } else if (slot == socket_table.items.len) {
        // Append - Zig 0.15+ requires passing allocator
        socket_table.append(socket_allocator, sock) catch return false;
        return true;
    }
    return false; // Slot gap (should not happen with findFreeSlot)
}

pub fn clearSlot(slot: usize) void {
    if (slot < socket_table.items.len) {
        socket_table.items[slot] = null;
    }
}
