// mDNS (Multicast DNS) Module
// RFC 6762: Multicast DNS
// RFC 6763: DNS-Based Service Discovery

const std = @import("std");
const Interface = @import("../core/interface.zig").Interface;

pub const constants = @import("constants.zig");
pub const cache = @import("cache.zig");
pub const services = @import("services.zig");
pub const responder = @import("responder.zig");

// Re-export commonly used constants
pub const MDNS_PORT = constants.MDNS_PORT;
pub const MDNS_MULTICAST_IPV4 = constants.MDNS_MULTICAST_IPV4;

/// Global mDNS state
var initialized: bool = false;
var mdns_allocator: ?std.mem.Allocator = null;
var mdns_interface: ?*Interface = null;

/// Initialize the mDNS subsystem
/// Called from net.init() after network stack is ready
pub fn init(iface: *Interface, allocator: std.mem.Allocator) void {
    if (initialized) return;

    mdns_allocator = allocator;
    mdns_interface = iface;

    // Initialize cache with default 100 ticks/sec
    cache.init(allocator, 100);

    // Initialize service registry
    services.init();

    // Initialize responder (creates socket, joins multicast group)
    // Default hostname is "zk" - could be made configurable
    responder.init(iface, "zk") catch {
        // Responder init failed - mDNS won't work but other net stack is fine
        return;
    };

    initialized = true;
}

/// Periodic tick handler for mDNS
/// Called from net.tick() to handle:
/// - Cache TTL expiration
/// - Probe/announce timers
/// - Scheduled responses
pub fn tick() void {
    if (!initialized) return;

    // Expire cache entries
    cache.tick();

    // Handle responder timers (probing, announcing, packet processing)
    responder.tick();
}

/// Deinitialize mDNS subsystem
pub fn deinit() void {
    if (!initialized) return;

    // Stop responder
    responder.deinit();

    // Clear cache
    cache.deinit();

    // Clear services
    services.deinit();

    initialized = false;
    mdns_allocator = null;
    mdns_interface = null;
}

/// Check if mDNS is initialized
pub fn isInitialized() bool {
    return initialized;
}
