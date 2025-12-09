// Socket subsystem shared state.
// Centralizes tables and interfaces so per-protocol modules stay focused.

const std = @import("std");
const types = @import("types.zig");
const sync = @import("../../sync.zig");
const interface = @import("../../core/interface.zig");

pub const Interface = interface.Interface;

/// Global socket table (dynamic list of pointers to sockets)
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
    socket_table = std.ArrayList(?*types.Socket).init(allocator);
}

pub fn getInterface() ?*Interface {
    return global_iface;
}

pub fn getSocket(sock_fd: usize) ?*types.Socket {
    if (sock_fd >= socket_table.items.len) return null;
    return socket_table.items[sock_fd];
}

/// Allocate an ephemeral port
pub fn allocateEphemeralPort() u16 {
    // Find unused port in ephemeral range (49152-65535)
    var attempts: u16 = 0;
    while (attempts < 1000) : (attempts += 1) {
        const port = next_ephemeral_port;
        next_ephemeral_port += 1;
        if (next_ephemeral_port > 65535) { // u16 wrap implies this check is technically redundant if using +%= but explicit is clearer
            next_ephemeral_port = 49152;
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

    // Fallback - return next port anyway
    const port = next_ephemeral_port;
    if (next_ephemeral_port < 65535) next_ephemeral_port += 1 else next_ephemeral_port = 49152;
    return port;
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
