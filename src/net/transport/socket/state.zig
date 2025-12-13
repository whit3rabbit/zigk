// Socket subsystem shared state.
// Centralizes tables and interfaces so per-protocol modules stay focused.

const std = @import("std");
const types = @import("types.zig");
const sync = @import("../../sync.zig");
const interface = @import("../../core/interface.zig");

pub const Interface = interface.Interface;

/// Global socket table (dynamic array)
/// Stores pointers to sockets. Null entries are free slots.
pub var socket_table: std.ArrayList(?*types.Socket) = undefined;
pub var socket_allocator: std.mem.Allocator = undefined;
/// Socket allocation lock
var lock: sync.Lock = sync.noop_lock;
/// Next ephemeral port for Auto-binding
var next_ephemeral_port: u16 = 49152;
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
    next_ephemeral_port = 49152;
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

/// Allocate an ephemeral port. Returns 0 on failure.
pub fn allocateEphemeralPort() u16 {
    // Find unused port in ephemeral range (49152-65535)
    var attempts: u16 = 0;
    while (attempts < 16384) : (attempts += 1) { // Cover full ephemeral range
        const port = next_ephemeral_port;
        
        // Advance with wrapping logic
        if (next_ephemeral_port == 65535) {
            next_ephemeral_port = 49152;
        } else {
            next_ephemeral_port += 1;
        }

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

    return 0; // No free ports
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
