// Socket subsystem shared state.
// Centralizes tables and interfaces so per-protocol modules stay focused.

const std = @import("std");
const types = @import("types.zig");
const sync = @import("../../sync.zig");
const interface = @import("../../core/interface.zig");
const hal = @import("hal");

pub const Interface = interface.Interface;

/// Global socket table (dynamic array)
/// Stores pointers to sockets. Null entries are free slots.
pub var socket_table: std.ArrayList(?*types.Socket) = undefined;
pub var socket_allocator: std.mem.Allocator = undefined;
/// Socket allocation lock
var lock: sync.Lock = sync.noop_lock;
/// Global network interface (set during init)
var global_iface: ?*Interface = null;

pub fn setLock(l: sync.Lock) void {
    lock = l;
}

pub fn socketLock() *sync.Lock {
    return &lock;
}

pub fn init(iface: *Interface, allocator: std.mem.Allocator) void {
    global_iface = iface;
    socket_allocator = allocator;
    socket_table = .{};
}

pub fn getInterface() ?*Interface {
    return global_iface;
}

pub fn getSocket(sock_fd: usize) ?*types.Socket {
    if (sock_fd >= socket_table.items.len) return null;
    return socket_table.items[sock_fd];
}

pub fn getSocketTable() []?*types.Socket {
    return socket_table.items;
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
    const EPHEMERAL_START: u16 = 49152;
    const EPHEMERAL_END: u16 = 65535;
    const EPHEMERAL_RANGE: u16 = EPHEMERAL_END - EPHEMERAL_START + 1; // 16384

    // RFC 6056 Algorithm 1: Random starting point using hardware entropy
    const entropy = hal.entropy.getHardwareEntropy();
    const random_offset: u16 = @truncate(entropy % EPHEMERAL_RANGE);
    var port = EPHEMERAL_START + random_offset;

    var attempts: u16 = 0;
    while (attempts < EPHEMERAL_RANGE) : (attempts += 1) {
        // Check if port is in use
        var in_use = false;
        for (socket_table.items) |maybe_socket| {
            if (maybe_socket) |sock| {
                if (sock.allocated and sock.local_port == port) {
                    in_use = true;
                    break;
                }
            }
        }

        if (!in_use) {
            return port;
        }

        // Sequential probe from random start (wrap at range boundary)
        port = if (port == EPHEMERAL_END) EPHEMERAL_START else port + 1;
    }

    return 0; // No free ports
}

/// Allocate an ephemeral port using RFC 6056 Algorithm 3 (Random Port Randomization).
/// Each attempt uses fresh entropy for stronger randomization.
/// Preferred for DNS queries where each query should have independent source port.
/// Security: Provides ~16 bits of port entropy combined with DNS transaction ID
/// for ~32 bits total unpredictability against cache poisoning (RFC 5452).
pub fn allocateRandomEphemeralPort() u16 {
    const EPHEMERAL_START: u16 = 49152;
    const EPHEMERAL_END: u16 = 65535;
    const EPHEMERAL_RANGE: u16 = EPHEMERAL_END - EPHEMERAL_START + 1; // 16384

    // Try random ports with fresh entropy each time (RFC 6056 Algorithm 3)
    // This provides maximum unpredictability for DNS security
    const MAX_RANDOM_ATTEMPTS: u16 = 64; // Limit random probes before fallback

    var attempts: u16 = 0;
    while (attempts < MAX_RANDOM_ATTEMPTS) : (attempts += 1) {
        const entropy = hal.entropy.getHardwareEntropy();
        const random_offset: u16 = @truncate(entropy % EPHEMERAL_RANGE);
        const port = EPHEMERAL_START + random_offset;

        // Check if port is in use
        var in_use = false;
        for (socket_table.items) |maybe_socket| {
            if (maybe_socket) |sock| {
                if (sock.allocated and sock.local_port == port) {
                    in_use = true;
                    break;
                }
            }
        }

        if (!in_use) {
            return port;
        }
    }

    // Fallback to standard Algorithm 1 if random probing fails
    // (indicates high port pressure)
    return allocateEphemeralPort();
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

pub fn reserveSlot() ?usize {
    return findFreeSlot();
}

pub fn installSocket(slot: usize, sock: *types.Socket) bool {
    // Note: We don't check MAX_SOCKETS anymore

    if (slot < socket_table.items.len) {
        // Reuse slot
        if (socket_table.items[slot] != null) return false;
        socket_table.items[slot] = sock;
        return true;
    } else if (slot == socket_table.items.len) {
        // Append - Zig 0.15 requires passing allocator
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
