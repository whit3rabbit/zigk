const std = @import("std");
const cache = @import("cache.zig");

/// Security event types for ARP
pub const ArpSecurityEvent = enum {
    /// Conflicting MAC addresses detected for same IP (potential MITM)
    conflict_detected,
    /// Entry blocked after too many conflicts
    entry_blocked,
    /// Incomplete entry limit reached (potential DoS)
    incomplete_limit_reached,
    /// VLAN-tagged packet detected (misconfiguration or attack)
    vlan_tag_detected,
    /// Attempt to overwrite static entry (potential spoofing)
    static_entry_protected,
};

/// Simple tick counter for timers
pub var current_tick: u64 = 0;
/// Ticks per second (configured by init)
pub var ticks_per_second: u64 = 1000;

/// Base backoff time in seconds for conflict detection
pub const ARP_CONFLICT_BASE_BACKOFF: u64 = 5;
/// Maximum exponent for exponential backoff
pub const ARP_MAX_BACKOFF_EXPONENT: u8 = 4;
/// Maximum conflicts before requiring static binding or manual intervention.
pub const ARP_MAX_CONFLICTS: u8 = 10;

/// SECURITY: Enable runtime verification of synchronous transmit in debug builds.
pub const VERIFY_SYNC_TRANSMIT = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// Log a security event.
pub fn logSecurityEvent(event: ArpSecurityEvent, ip: u32, mac1: ?[6]u8, mac2: ?[6]u8) void {
    // TODO: Connect to kernel logging subsystem when available.
    _ = event;
    _ = ip;
    _ = mac1;
    _ = mac2;
}

/// Increment tick counter
pub fn tick() void {
    current_tick +%= 1;
}

/// Age ARP cache entries
pub fn ageCache() void {
    const held = cache.lock.acquire();
    defer held.release();
    var i: usize = 0;
    while (i < cache.arp_cache.items.len) {
        var entry = &cache.arp_cache.items[i];
        if (entry.state == .free) {
            i += 1;
            continue;
        }

        if (entry.is_static) {
            i += 1;
            continue;
        }

        const age = current_tick -% entry.timestamp;

        switch (entry.state) {
            .incomplete => {
                if (age > 3 * ticks_per_second) {
                    cache.hashTableRemove(entry);
                    cache.clearPending(entry);
                    entry.state = .free;
                    entry.generation +%= 1;
                    if (cache.incomplete_entry_count > 0) {
                        cache.incomplete_entry_count -= 1;
                    }
                }
            },
            .reachable => {
                if (age > cache.ARP_TIMEOUT * ticks_per_second) {
                    entry.state = .stale;
                    entry.generation +%= 1;
                }
            },
            .stale => {
                if (age > cache.ARP_TIMEOUT * 2 * ticks_per_second) {
                    cache.hashTableRemove(entry);
                    cache.clearPending(entry);
                    entry.state = .free;
                    entry.generation +%= 1;
                }
            },
            .free => {},
        }
        i += 1;
    }
}
