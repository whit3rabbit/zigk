// Path MTU Discovery (PMTUD)
//
// Complies with:
// - RFC 1191: Path MTU Discovery
//
// Maintains a cache of Path MTUs to avoid IP fragmentation.

const std = @import("std");
const sync = @import("../sync.zig");

/// Default MTU for Ethernet
pub const DEFAULT_MTU: u16 = 1500;

/// Minimum MTU per RFC 791 (all hosts must accept 576-byte datagrams)
pub const MIN_MTU: u16 = 576;

/// Maximum number of PMTU cache entries
const PMTU_CACHE_SIZE: usize = 16;

/// PMTU cache entry timeout (conceptual - no timer in MVP)
/// After this many "accesses" we should refresh the entry
const PMTU_ENTRY_AGE_LIMIT: u32 = 1000;

/// SECURITY (Vuln 2): Minimum interval between PMTU updates in TICKS (not ops).
/// Previously used operation counter which attacker could accelerate by flooding
/// with ICMP messages. Now uses monotonic tick counter that advances only with
/// real time (timer interrupts), making rate limiting robust against flooding.
/// 100 ticks = ~1 second at typical 100Hz tick rate.
const PMTU_UPDATE_RATE_LIMIT_TICKS: u64 = 100;

/// Path MTU cache entry
const PmtuEntry = struct {
    destination_ip: u32, // 0 = empty slot
    mtu: u16, // Discovered MTU
    age: u32, // Access counter for LRU-ish aging (can still use op counter - not security critical)
    /// SECURITY (Vuln 2): Changed from operation counter to tick timestamp.
    /// Now stores the monotonic tick count when entry was last modified.
    /// This makes rate limiting time-based rather than operation-based,
    /// preventing attackers from accelerating wraparound via flooding.
    last_update_tick: u64,
};

/// PMTU cache (simple array with LRU-ish replacement)
var pmtu_cache: [PMTU_CACHE_SIZE]PmtuEntry = [_]PmtuEntry{.{
    .destination_ip = 0,
    .mtu = DEFAULT_MTU,
    .age = 0,
    .last_update_tick = 0,
}} ** PMTU_CACHE_SIZE;

/// Global age counter for cache entries (LRU ordering - not security critical)
var pmtu_age_counter: u32 = 0;

/// SECURITY (Vuln 2): Monotonic tick counter for time-based rate limiting.
/// Updated by tick() which should be called from timer interrupt.
/// Using u64 ensures wraparound takes ~5 billion years at 100Hz, not hours.
var current_tick: u64 = 0;

/// Update the tick counter (call from timer interrupt)
/// This provides the time base for rate limiting that cannot be
/// accelerated by attacker-controlled traffic.
pub fn tick() void {
    current_tick +%= 1;
}

/// SECURITY: IRQ-safe spinlock for concurrent access protection.
/// Previously the PMTU cache had no synchronization, allowing race conditions
/// on SMP systems where concurrent lookupPmtu/updatePmtu calls could read
/// torn values or corrupt cache entries.
var pmtu_lock: sync.Spinlock = .{};

/// Look up PMTU for a destination IP
/// Returns DEFAULT_MTU if no entry exists
/// Thread-safe: protected by spinlock
pub fn lookupPmtu(dst_ip: u32) u16 {
    const held = pmtu_lock.acquire();
    defer held.release();

    for (&pmtu_cache) |*entry| {
        if (entry.destination_ip == dst_ip) {
            // Update age on access
            pmtu_age_counter +%= 1;
            entry.age = pmtu_age_counter;
            return entry.mtu;
        }
    }
    return DEFAULT_MTU;
}

/// Update PMTU cache with a new (lower) MTU value
/// Called when we receive ICMP Fragmentation Needed (Type 3 Code 4)
///
/// Security considerations (RFC 5927):
/// - Rate-limited to prevent rapid cache poisoning
/// - Only decreases MTU (never increases) per RFC 1191
/// - ICMP handler validates original packet against active TCP connections
///   before calling this function (see icmp.zig:handleDestUnreachable)
/// - UDP PMTU updates are allowed with rate limiting (stateless protocol)
/// Thread-safe: protected by spinlock
pub fn updatePmtu(dst_ip: u32, new_mtu: u16) void {
    const held = pmtu_lock.acquire();
    defer held.release();

    // Clamp MTU to valid range
    const mtu = if (new_mtu < MIN_MTU) MIN_MTU else new_mtu;

    pmtu_age_counter +%= 1;

    // First, check if entry already exists
    for (&pmtu_cache) |*entry| {
        if (entry.destination_ip == dst_ip) {
            // SECURITY (Vuln 2): Use tick-based rate limiting instead of op counter.
            // The op counter could be accelerated by attacker flooding with ICMP messages.
            // Using current_tick (monotonic, timer-driven) makes rate limiting time-based.
            // Wraparound: u64 ticks at 100Hz wraps after ~5 billion years, not hours.
            const ticks_since_update = current_tick -% entry.last_update_tick;
            if (ticks_since_update < PMTU_UPDATE_RATE_LIMIT_TICKS) {
                return; // Too soon since last update - rate limit triggered
            }

            // Only update if new MTU is smaller (PMTUD reduces, never increases)
            // To increase, we'd need explicit "probe" support (RFC 4821)
            if (mtu < entry.mtu) {
                entry.mtu = mtu;
                entry.last_update_tick = current_tick;
            }
            entry.age = pmtu_age_counter; // LRU ordering still uses op counter (not security critical)
            return;
        }
    }

    // Entry doesn't exist - find slot (empty or oldest)
    var oldest_idx: usize = 0;
    var oldest_age: u32 = pmtu_cache[0].age;

    for (pmtu_cache, 0..) |entry, i| {
        // Prefer empty slots
        if (entry.destination_ip == 0) {
            oldest_idx = i;
            break;
        }
        // Track oldest for LRU replacement
        if (entry.age < oldest_age) {
            oldest_age = entry.age;
            oldest_idx = i;
        }
    }

    // Insert new entry
    pmtu_cache[oldest_idx] = .{
        .destination_ip = dst_ip,
        .mtu = mtu,
        .age = pmtu_age_counter,
        .last_update_tick = current_tick, // Use tick-based timestamp
    };
}

/// Get effective MSS for a destination considering PMTU
/// MSS = MTU - IP header - TCP header
pub fn getEffectiveMss(dst_ip: u32) u16 {
    const mtu = lookupPmtu(dst_ip);
    // MSS = MTU - 20 (IP header) - 20 (TCP header minimum)
    const overhead: u16 = 40;
    return if (mtu > overhead) mtu - overhead else MIN_MTU - overhead;
}
