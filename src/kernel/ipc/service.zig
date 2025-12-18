const std = @import("std");
const heap = @import("heap");
const sync = @import("sync");
const process = @import("process");

// Maximum length of a service name
pub const MAX_SERVICE_NAME = 32;

pub const Service = struct {
    name: [MAX_SERVICE_NAME]u8,
    len: usize,
    pid: u32,
    next: ?*Service = null,
};

/// Global list of registered services
var services_head: ?*Service = null;
var services_lock = sync.Spinlock{};

/// Register a service name for the given PID
/// Returns true on success, false if name already taken
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
    @memcpy(node.name[0..name.len], name);
    node.pid = pid;

    // Prepend to list
    node.next = services_head;
    services_head = node;

    return true;
}

/// Lookup a service PID by name
/// Returns PID or null if not found
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

/// Remove all services registered by a PID (on process exit)
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
