// mDNS Service Registration
// Manages locally registered services for DNS-SD

const std = @import("std");
const sync = @import("../sync.zig");
const constants = @import("constants.zig");
const dns = @import("../dns/dns.zig");

/// Registered service entry
pub const Service = struct {
    /// Service instance name (e.g., "My Web Server")
    name: [constants.MAX_SERVICE_NAME_LEN]u8,
    name_len: usize,

    /// Service type (e.g., "_http._tcp")
    service_type: [constants.MAX_SERVICE_TYPE_LEN]u8,
    type_len: usize,

    /// Port number
    port: u16,

    /// TXT record data (key=value pairs, length-prefixed)
    txt: [constants.MAX_TXT_LEN]u8,
    txt_len: usize,

    /// Record TTL (seconds)
    ttl: u32,

    /// Whether this entry is active
    active: bool,

    /// Check if service matches name and type
    pub fn matches(self: *const Service, name: []const u8, svc_type: []const u8) bool {
        if (!self.active) return false;
        if (self.name_len != name.len) return false;
        if (self.type_len != svc_type.len) return false;

        // Case-insensitive comparison
        for (self.name[0..self.name_len], name) |a, b| {
            const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (la != lb) return false;
        }

        for (self.service_type[0..self.type_len], svc_type) |a, b| {
            const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (la != lb) return false;
        }

        return true;
    }

    /// Build the full service instance name (name.type.local)
    pub fn getFullName(self: *const Service, out: []u8) usize {
        var pos: usize = 0;

        // Copy instance name
        if (pos + self.name_len >= out.len) return 0;
        @memcpy(out[pos..][0..self.name_len], self.name[0..self.name_len]);
        pos += self.name_len;

        // Add dot
        if (pos >= out.len) return 0;
        out[pos] = '.';
        pos += 1;

        // Copy service type
        if (pos + self.type_len >= out.len) return 0;
        @memcpy(out[pos..][0..self.type_len], self.service_type[0..self.type_len]);
        pos += self.type_len;

        // Add .local
        const suffix = ".local";
        if (pos + suffix.len >= out.len) return 0;
        @memcpy(out[pos..][0..suffix.len], suffix);
        pos += suffix.len;

        return pos;
    }

    /// Build the service type name (type.local)
    pub fn getTypeName(self: *const Service, out: []u8) usize {
        var pos: usize = 0;

        // Copy service type
        if (pos + self.type_len >= out.len) return 0;
        @memcpy(out[pos..][0..self.type_len], self.service_type[0..self.type_len]);
        pos += self.type_len;

        // Add .local
        const suffix = ".local";
        if (pos + suffix.len >= out.len) return 0;
        @memcpy(out[pos..][0..suffix.len], suffix);
        pos += suffix.len;

        return pos;
    }
};

/// Service registry
var services: [constants.MAX_SERVICES]Service = undefined;
var service_count: usize = 0;
var registry_lock: sync.Spinlock = .{};
var initialized: bool = false;

/// Initialize the service registry
pub fn init() void {
    const held = registry_lock.acquire();
    defer held.release();

    for (&services) |*svc| {
        svc.active = false;
        svc.name_len = 0;
        svc.type_len = 0;
        svc.txt_len = 0;
        svc.port = 0;
        svc.ttl = constants.MDNS_SERVICE_TTL;
    }
    service_count = 0;
    initialized = true;
}

/// Deinitialize the service registry
pub fn deinit() void {
    const held = registry_lock.acquire();
    defer held.release();

    for (&services) |*svc| {
        svc.active = false;
    }
    service_count = 0;
    initialized = false;
}

/// Register a new service
/// Returns error if registry is full or parameters are invalid
pub fn register(
    name: []const u8,
    service_type: []const u8,
    port: u16,
    txt: []const u8,
) !void {
    if (name.len == 0 or name.len > constants.MAX_SERVICE_NAME_LEN) return error.InvalidArgument;
    if (service_type.len == 0 or service_type.len > constants.MAX_SERVICE_TYPE_LEN) return error.InvalidArgument;
    if (txt.len > constants.MAX_TXT_LEN) return error.InvalidArgument;
    if (port == 0) return error.InvalidArgument;

    const held = registry_lock.acquire();
    defer held.release();

    // Check if service already exists (update it)
    for (&services) |*svc| {
        if (svc.matches(name, service_type)) {
            svc.port = port;
            @memcpy(svc.txt[0..txt.len], txt);
            svc.txt_len = txt.len;
            return;
        }
    }

    // Find free slot
    for (&services) |*svc| {
        if (!svc.active) {
            @memcpy(svc.name[0..name.len], name);
            svc.name_len = name.len;
            @memcpy(svc.service_type[0..service_type.len], service_type);
            svc.type_len = service_type.len;
            svc.port = port;
            @memcpy(svc.txt[0..txt.len], txt);
            svc.txt_len = txt.len;
            svc.ttl = constants.MDNS_SERVICE_TTL;
            svc.active = true;
            service_count += 1;
            return;
        }
    }

    return error.OutOfMemory;
}

/// Unregister a service
/// Returns true if service was found and removed
pub fn unregister(name: []const u8, service_type: []const u8) bool {
    const held = registry_lock.acquire();
    defer held.release();

    for (&services) |*svc| {
        if (svc.matches(name, service_type)) {
            svc.active = false;
            if (service_count > 0) service_count -= 1;
            return true;
        }
    }
    return false;
}

/// Find a service by name and type
pub fn find(name: []const u8, service_type: []const u8) ?*const Service {
    const held = registry_lock.acquire();
    defer held.release();

    for (&services) |*svc| {
        if (svc.matches(name, service_type)) {
            return svc;
        }
    }
    return null;
}

/// Find services by type (returns first match)
/// For iteration, use getServicesByType
pub fn findByType(service_type: []const u8) ?*const Service {
    const held = registry_lock.acquire();
    defer held.release();

    for (&services) |*svc| {
        if (!svc.active) continue;
        if (svc.type_len != service_type.len) continue;

        var match = true;
        for (svc.service_type[0..svc.type_len], service_type) |a, b| {
            const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (la != lb) {
                match = false;
                break;
            }
        }
        if (match) return svc;
    }
    return null;
}

/// Get count of registered services
pub fn getCount() usize {
    const held = registry_lock.acquire();
    defer held.release();
    return service_count;
}

/// Get list of unique service types for DNS-SD browsing
/// Returns count of unique types written to out
pub fn getServiceTypes(out: [][]u8, max_types: usize) usize {
    const held = registry_lock.acquire();
    defer held.release();

    var count: usize = 0;
    outer: for (&services) |*svc| {
        if (!svc.active) continue;
        if (count >= max_types) break;

        // Check if we already have this type
        for (out[0..count]) |existing| {
            if (existing.len == svc.type_len) {
                var same = true;
                for (existing, svc.service_type[0..svc.type_len]) |a, b| {
                    if (a != b) {
                        same = false;
                        break;
                    }
                }
                if (same) continue :outer;
            }
        }

        // Add new type
        if (count < out.len) {
            @memcpy(out[count][0..svc.type_len], svc.service_type[0..svc.type_len]);
            count += 1;
        }
    }
    return count;
}

/// Iterator for services of a given type
pub const ServiceIterator = struct {
    service_type: []const u8,
    index: usize,

    pub fn next(self: *ServiceIterator) ?*const Service {
        while (self.index < constants.MAX_SERVICES) {
            const svc = &services[self.index];
            self.index += 1;

            if (!svc.active) continue;
            if (svc.type_len != self.service_type.len) continue;

            var match = true;
            for (svc.service_type[0..svc.type_len], self.service_type) |a, b| {
                const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
                const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
                if (la != lb) {
                    match = false;
                    break;
                }
            }
            if (match) return svc;
        }
        return null;
    }
};

/// Get iterator for services of a given type
/// Note: Caller must hold lock for thread safety during iteration
pub fn iterateByType(service_type: []const u8) ServiceIterator {
    return .{
        .service_type = service_type,
        .index = 0,
    };
}
