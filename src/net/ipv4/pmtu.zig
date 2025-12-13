// Path MTU Discovery (PMTUD)
//
// Complies with:
// - RFC 1191: Path MTU Discovery
//
// Maintains a cache of Path MTUs to avoid IP fragmentation.

const std = @import("std");

/// Default MTU for Ethernet
pub const DEFAULT_MTU: u16 = 1500;

/// Minimum MTU per RFC 791 (all hosts must accept 576-byte datagrams)
pub const MIN_MTU: u16 = 576;

/// Maximum number of PMTU cache entries
const PMTU_CACHE_SIZE: usize = 16;

/// PMTU cache entry timeout (conceptual - no timer in MVP)
/// After this many "accesses" we should refresh the entry
const PMTU_ENTRY_AGE_LIMIT: u32 = 1000;

/// Path MTU cache entry
const PmtuEntry = struct {
    destination_ip: u32, // 0 = empty slot
    mtu: u16, // Discovered MTU
    age: u32, // Access counter for LRU-ish aging
};

/// PMTU cache (simple array with LRU-ish replacement)
var pmtu_cache: [PMTU_CACHE_SIZE]PmtuEntry = [_]PmtuEntry{.{
    .destination_ip = 0,
    .mtu = DEFAULT_MTU,
    .age = 0,
}} ** PMTU_CACHE_SIZE;

/// Global age counter for cache entries
var pmtu_age_counter: u32 = 0;

/// Look up PMTU for a destination IP
/// Returns DEFAULT_MTU if no entry exists
pub fn lookupPmtu(dst_ip: u32) u16 {
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
pub fn updatePmtu(dst_ip: u32, new_mtu: u16) void {
    // Clamp MTU to valid range
    const mtu = if (new_mtu < MIN_MTU) MIN_MTU else new_mtu;

    pmtu_age_counter +%= 1;

    // First, check if entry already exists
    for (&pmtu_cache) |*entry| {
        if (entry.destination_ip == dst_ip) {
            // Only update if new MTU is smaller (PMTUD reduces, never increases)
            // To increase, we'd need explicit "probe" support (RFC 4821)
            if (mtu < entry.mtu) {
                entry.mtu = mtu;
            }
            entry.age = pmtu_age_counter;
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
