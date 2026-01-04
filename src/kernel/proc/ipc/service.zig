//! IPC Service Registry
//!
//! This module implements a simple name service for IPC endpoints. Processes can register
//! a human-readable string name (e.g., "vfs", "audio") which maps to their PID.
//! Other processes can then look up these names to discover the PID of a service
//! they wish to communicate with.
//!
//! The registry is a global singly-linked list protected by a spinlock.

const std = @import("std");
const heap = @import("heap");
const sync = @import("sync");
const process = @import("process");
const hal = @import("hal");

/// Maximum length of a service name in bytes.
pub const MAX_SERVICE_NAME = 32;

/// A registered service entry.
pub const Service = struct {
    /// Service name (not null-terminated, length defined by `len`)
    name: [MAX_SERVICE_NAME]u8,
    /// Actual length of the service name
    len: usize,
    /// Process ID providing this service
    pid: u32,
    /// Next service in the linked list
    next: ?*Service = null,
};

/// Global list of registered services head pointer.
var services_head: ?*Service = null;
/// Spinlock protecting the global services list.
var services_lock = sync.Spinlock{};

/// Register a service name for the given PID.
///
/// Allocates a new `Service` node and prepends it to the global list.
/// Fails if the name is already registered or if memory allocation fails.
///
/// Arguments:
///   name: The service name to register.
///   pid: The PID of the process providing the service.
///
/// Returns:
///   true on success.
///   false if the name is already taken.
///   Error if name is too long or memory allocation fails.
pub fn register(name: []const u8, pid: u32) !bool {
    if (name.len > MAX_SERVICE_NAME) return error.NameTooLong;

    const held = services_lock.acquire();
    defer held.release();

    // Check if name already exists
    var curr = services_head;
    while (curr) |s| {
        if (std.mem.eql(u8, s.name[0..s.len], name)) {
            // Name taken
            return false;
        }
        curr = s.next;
    }

    // Allocate new service node
    const node = try heap.allocator().create(Service);
    node.len = name.len;
    hal.mem.copy(node.name[0..name.len].ptr, name.ptr, name.len);
    node.pid = pid;

    // Prepend to list
    node.next = services_head;
    services_head = node;

    return true;
}

/// Lookup a service PID by name.
///
/// Iterates through the registered services to find a match.
///
/// Arguments:
///   name: The service name to search for.
///
/// Returns:
///   The PID of the service if found, or null otherwise.
pub fn lookup(name: []const u8) ?u32 {
    const held = services_lock.acquire();
    defer held.release();

    var curr = services_head;
    while (curr) |s| {
        if (std.mem.eql(u8, s.name[0..s.len], name)) {
            return s.pid;
        }
        curr = s.next;
    }

    return null;
}

/// Remove all services registered by a specific PID.
///
/// This function is typically called when a process exits to clean up
/// any stale service registrations.
///
/// Arguments:
///   pid: The PID of the process whose services should be removed.
pub fn unregisterByPid(pid: u32) void {
    const held = services_lock.acquire();
    defer held.release();

    var curr = services_head;
    var prev: ?*Service = null;

    while (curr) |s| {
        if (s.pid == pid) {
            // Remove node
            if (prev) |p| {
                p.next = s.next;
            } else {
                services_head = s.next;
            }
            
            // Advance first, then free
            const next = s.next;
            heap.allocator().destroy(s);
            curr = next;
        } else {
            prev = s;
            curr = s.next;
        }
    }
}
