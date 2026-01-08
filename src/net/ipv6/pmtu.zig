// Path MTU Discovery for IPv6 (RFC 8201)
//
// Maintains cache of discovered Path MTUs by destination IPv6 address.
// Handles PMTU reduction via ICMPv6 Packet Too Big messages.
//
// Security considerations:
// - Fixed-size cache prevents DoS via memory exhaustion
// - Rate limiting on updates prevents ICMP flooding attacks
// - Only decreases MTU (never increases via PTB messages)
// - Time-based rate limiting using tick counter (not operation counter)

const std = @import("std");
const sync = @import("../sync.zig");

/// IPv6 minimum link MTU per RFC 8200 Section 5
pub const MIN_IPV6_MTU: u16 = 1280;

/// Default MTU for Ethernet
pub const DEFAULT_IPV6_MTU: u16 = 1500;

/// Maximum number of PMTU cache entries
/// Larger than IPv4 (16) due to larger address space
const PMTU_CACHE_SIZE: usize = 64;

/// Rate limit for PMTU updates in ticks (100 ticks = ~1 second at 100Hz)
/// Prevents attacker from rapidly reducing MTU via spoofed PTB messages
const PMTU_UPDATE_RATE_LIMIT_TICKS: u64 = 100;

/// Age limit before entry should be considered for probing (RFC 8201)
/// 600 seconds = 10 minutes
const PMTU_PROBE_TIMEOUT_TICKS: u64 = 60_000;

/// Path MTU cache entry
const PmtuEntry = struct {
    /// Destination IPv6 address (all zeros = empty slot)
    destination_ipv6: [16]u8,
    /// Discovered PMTU in bytes
    mtu: u16,
    /// Access counter for LRU-ish aging (not security critical)
    age: u32,
    /// Tick timestamp when entry was last modified (time-based rate limiting)
    last_update_tick: u64,
};

/// Empty entry constant for initialization
const EMPTY_ENTRY: PmtuEntry = .{
    .destination_ipv6 = [_]u8{0} ** 16,
    .mtu = DEFAULT_IPV6_MTU,
    .age = 0,
    .last_update_tick = 0,
};

/// PMTU cache (simple array with LRU-ish replacement)
var pmtu_cache: [PMTU_CACHE_SIZE]PmtuEntry = [_]PmtuEntry{EMPTY_ENTRY} ** PMTU_CACHE_SIZE;

/// Global age counter for cache entries (LRU ordering)
var pmtu_age_counter: u32 = 0;

/// Monotonic tick counter for time-based rate limiting
/// Updated by tick() which should be called from timer interrupt
var current_tick: u64 = 0;

/// IRQ-safe spinlock for concurrent access protection
var pmtu_lock: sync.Spinlock = .{};

/// Update the tick counter (call from timer interrupt)
/// This provides the time base for rate limiting that cannot be
/// accelerated by attacker-controlled traffic.
pub fn tick() void {
    current_tick +%= 1;
}

/// Look up PMTU for an IPv6 destination address
/// Returns DEFAULT_IPV6_MTU if no entry exists
/// Thread-safe: protected by spinlock
pub fn lookupPmtu6(dst_ipv6: [16]u8) u16 {
    const held = pmtu_lock.acquire();
    defer held.release();

    for (&pmtu_cache) |*entry| {
        if (std.mem.eql(u8, &entry.destination_ipv6, &dst_ipv6)) {
            // Update LRU age
            pmtu_age_counter +%= 1;
            entry.age = pmtu_age_counter;
            return entry.mtu;
        }
    }

    return DEFAULT_IPV6_MTU;
}

/// Update PMTU cache when receiving ICMPv6 Packet Too Big
///
/// Security:
/// - Only decreases MTU (never increases via PTB messages per RFC 8201)
/// - Rate-limits updates to prevent flooding attacks
/// - Validates MTU is >= MIN_IPV6_MTU (1280)
///
/// Thread-safe: protected by spinlock
pub fn updatePmtu6(dst_ipv6: [16]u8, new_mtu: u16) void {
    // Validate MTU bounds
    if (new_mtu < MIN_IPV6_MTU) {
        return; // Reject invalid MTU
    }

    const held = pmtu_lock.acquire();
    defer held.release();

    // Search for existing entry
    var oldest_idx: usize = 0;
    var oldest_age: u32 = pmtu_cache[0].age;
    var empty_idx: ?usize = null;

    for (&pmtu_cache, 0..) |*entry, i| {
        // Check for empty slot
        if (entry.destination_ipv6[0] == 0 and entry.destination_ipv6[1] == 0 and
            entry.destination_ipv6[2] == 0 and entry.destination_ipv6[3] == 0)
        {
            if (empty_idx == null) empty_idx = i;
            continue;
        }

        // Check for existing entry
        if (std.mem.eql(u8, &entry.destination_ipv6, &dst_ipv6)) {
            // Rate limit: Check if enough time has passed since last update
            const elapsed = current_tick -% entry.last_update_tick;
            if (elapsed < PMTU_UPDATE_RATE_LIMIT_TICKS) {
                return; // Rate limited
            }

            // Security: Only decrease MTU, never increase via PTB
            const clamped_mtu = @max(new_mtu, MIN_IPV6_MTU);
            if (clamped_mtu < entry.mtu) {
                entry.mtu = clamped_mtu;
                entry.last_update_tick = current_tick;
                pmtu_age_counter +%= 1;
                entry.age = pmtu_age_counter;
            }
            return;
        }

        // Track oldest entry for LRU eviction
        if (entry.age < oldest_age) {
            oldest_age = entry.age;
            oldest_idx = i;
        }
    }

    // No existing entry - create new one
    const target_idx = empty_idx orelse oldest_idx;
    const clamped_mtu = @max(new_mtu, MIN_IPV6_MTU);

    pmtu_cache[target_idx] = .{
        .destination_ipv6 = dst_ipv6,
        .mtu = clamped_mtu,
        .age = pmtu_age_counter,
        .last_update_tick = current_tick,
    };
    pmtu_age_counter +%= 1;
}

/// Get effective MSS for TCP over IPv6 considering PMTU
/// MSS = PMTU - IPv6 header (40) - TCP header (20) = PMTU - 60
pub fn getEffectiveMss6(dst_ipv6: [16]u8) u16 {
    const mtu = lookupPmtu6(dst_ipv6);
    const overhead: u16 = 60; // IPv6 (40) + TCP (20)
    return if (mtu > overhead) mtu - overhead else MIN_IPV6_MTU - overhead;
}

/// Check if a destination should be probed for increased PMTU
/// Returns true if no PTB received in PMTU_PROBE_TIMEOUT_TICKS
pub fn shouldProbe6(dst_ipv6: [16]u8) bool {
    const held = pmtu_lock.acquire();
    defer held.release();

    for (&pmtu_cache) |*entry| {
        if (std.mem.eql(u8, &entry.destination_ipv6, &dst_ipv6)) {
            const elapsed = current_tick -% entry.last_update_tick;
            return elapsed >= PMTU_PROBE_TIMEOUT_TICKS;
        }
    }

    // No entry means we haven't received PTB - can probe
    return true;
}

/// Clear all PMTU cache entries (for testing or reset)
pub fn clearCache() void {
    const held = pmtu_lock.acquire();
    defer held.release();

    pmtu_cache = [_]PmtuEntry{EMPTY_ENTRY} ** PMTU_CACHE_SIZE;
    pmtu_age_counter = 0;
}
