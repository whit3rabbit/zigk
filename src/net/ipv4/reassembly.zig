// IPv4 Reassembly Management
//
// Handles reassembly of fragmented IPv4 packets (RFC 791).
// Maintains a cache of partial packets and assembles them into complete datagrams.

const std = @import("std");
const packet = @import("../core/packet.zig");
const ipv4 = @import("ipv4.zig");
const sync = @import("../sync.zig");
const PacketBuffer = packet.PacketBuffer;

/// Maximum size of an IP packet (64KB)
const MAX_IP_PACKET_SIZE: usize = 65535;

/// Maximum time to hold fragments (seconds)
/// Reduced from RFC 791's 60-120s to mitigate reassembly DoS attacks
const REASSEMBLY_TIMEOUT: u64 = 15;

/// Maximum concurrent reassemblies
/// Increased from 8 to handle more simultaneous fragmented flows
/// while still limiting memory usage (each entry uses ~64KB)
const MAX_REASSEMBLIES: usize = 32;

/// Fragment reassembly entry
const ReassemblyEntry = struct {
    used: bool,
    key: FragmentKey,
    timer: u64, // Creation timestamp (ticks)
    
    /// Reassembly buffer (holds IP payload)
    /// We support full 64KB packets. Static allocation is heavy but simple.
    buffer: [MAX_IP_PACKET_SIZE]u8,
    
    /// Total expected length of IP payload (0 if unknown)
    total_len: usize,
    
    /// Bytes received so far
    received_len: usize,
    
    /// Hole descriptor list (simplified)
    /// Bitmask could work for fixed blocks, but fragments vary in size.
    /// We'll use a simple "holes" list.
    holes: [16]Hole, // Support up to 16 fragments/holes
    hole_count: usize,
    
    const Hole = struct {
        start: usize,
        end: usize, // Exlusive
    };
    
    fn init(key: FragmentKey, timer: u64) ReassemblyEntry {
        var e = ReassemblyEntry{
            .used = true,
            .key = key,
            .timer = timer,
            .buffer = undefined,
            .total_len = 0,
            .received_len = 0,
            .holes = undefined,
            .hole_count = 1,
        };
        // Initial hole covers entire theoretical range until we know total_len
        // We set it to 65535 initially
        e.holes[0] = Hole{ .start = 0, .end = MAX_IP_PACKET_SIZE };
        return e;
    }
};

/// Key to identify IP fragments (src, dst, proto, id)
const FragmentKey = struct {
    src_ip: u32,
    dst_ip: u32,
    protocol: u8,
    id: u16,
};

/// Global reassembly cache
var cache: [MAX_REASSEMBLIES]ReassemblyEntry = undefined;
var cache_initialized: bool = false;
/// IRQ-safe spinlock for concurrent access protection
var lock: sync.Spinlock = .{};
var current_tick: u64 = 0;

/// Initialize module
pub fn init() void {
    if (!cache_initialized) {
        for (&cache) |*entry| {
            entry.used = false;
        }
        cache_initialized = true;
    }
}

/// Update timer tick
pub fn tick() void {
    current_tick +%= 1;
    // Timeout check could be here or lazy
}

/// Result of reassembly
pub const ReassemblyResult = struct {
    slice: []u8,
    entry_id: usize,
};

/// Process a fragment of an IPv4 packet
/// Returns:
///   - ReassemblyResult if complete (caller MUST call freeEntry)
///   - null if incomplete or dropped
pub fn processFragment(
    src_ip: u32,
    dst_ip: u32,
    protocol: u8,
    id: u16,
    frag_offset: u16,
    more_fragments: bool,
    payload: []const u8
) ?ReassemblyResult {
    const held = lock.acquire();
    defer held.release();
    
    if (!cache_initialized) init();

    const key = FragmentKey{
        .src_ip = src_ip,
        .dst_ip = dst_ip,
        .protocol = protocol,
        .id = id,
    };

    // Find existing entry
    var entry: ?*ReassemblyEntry = null;
    var entry_idx: usize = 0;
    
    for (&cache, 0..) |*e, i| {
        if (e.used and std.meta.eql(e.key, key)) {
            entry = e;
            entry_idx = i;
            break;
        }
    }

    // Allocate new entry if not found
    if (entry == null) {
        if (allocateEntry()) |res| {
            entry = res.ptr;
            entry_idx = res.index;
            entry.?.* = ReassemblyEntry.init(key, current_tick);
        } else {
            return null; // Cache full
        }
    }
    
    const e = entry.?;

    // Calculate fragment position with overflow protection
    // frag_offset is in 8-byte units, max value 65535 -> max start = 524,280
    // Use checked arithmetic for defense-in-depth against malformed offset values
    const start = std.math.mul(usize, @as(usize, frag_offset), 8) catch return null;

    // Validate start is within bounds (frag_offset * 8 can exceed MAX_IP_PACKET_SIZE)
    if (start >= MAX_IP_PACKET_SIZE) return null; // Fragment offset too large

    // Check for overflow: start + payload.len must not wrap
    if (payload.len > MAX_IP_PACKET_SIZE - start) return null; // Would exceed max packet size

    const end = start + payload.len;

    // Double-check bounds (redundant but defensive)
    if (end > MAX_IP_PACKET_SIZE) return null; // Too large

    // Update total length if this is the last fragment
    if (!more_fragments) {
        e.total_len = end;
        // Truncate any holes that go beyond total_len
        for (0..e.hole_count) |i| {
            if (e.holes[i].end > e.total_len) {
                e.holes[i].end = e.total_len;
            }
        }
    }

    // Security: Reject overlapping fragments (RFC 5722 recommendation for IPv6,
    // good practice for IPv4 too). Overlapping fragments are used in Teardrop
    // and similar attacks to evade IDS/firewall inspection.
    if (isRegionOverlapping(e, start, end)) {
        // Drop the entire reassembly - attacker may be trying to manipulate data
        e.used = false;
        return null;
    }

    // Copy data to buffer
    @memcpy(e.buffer[start..end], payload);

    // Update holes
    updateHoles(e, start, end);

    // Check if entry was invalidated (e.g., too many holes)
    if (!e.used) {
        return null; // Reassembly failed due to complexity
    }

    // Check completion
    if (isComplete(e)) {
        const payload_slice = e.buffer[0..e.total_len];
        // Caller must free manually
        return ReassemblyResult{
            .slice = payload_slice,
            .entry_id = entry_idx,
        };
    }

    return null;
}

/// Free a reassembly entry after consumption
pub fn freeEntry(id: usize) void {
    const held = lock.acquire();
    defer held.release();

    if (id < MAX_REASSEMBLIES) {
        cache[id].used = false;
    }
}

const Allocation = struct {
    ptr: *ReassemblyEntry,
    index: usize,
};

/// Simple pseudo-random number for eviction (no external dependencies)
var eviction_counter: usize = 0;

/// Allocate a cache entry with improved eviction policy
/// Policy:
///   1. Return any free entry
///   2. Evict any entry that has timed out
///   3. Evict oldest entry (LRU-like)
///   4. If all entries are young (possible DoS), use random eviction
fn allocateEntry() ?Allocation {
    // 1. Find free entry first (fast path)
    for (&cache, 0..) |*e, i| {
        if (!e.used) return Allocation{ .ptr = e, .index = i };
    }

    // 2. Find timed-out entry or track oldest
    var oldest_idx: usize = 0;
    var oldest_age: u64 = 0;
    var youngest_age: u64 = std.math.maxInt(u64);

    for (&cache, 0..) |*e, i| {
        const age = current_tick -% e.timer;

        // Immediately evict timed-out entries
        if (age >= REASSEMBLY_TIMEOUT) {
            return Allocation{ .ptr = e, .index = i };
        }

        // Track oldest for LRU
        if (age > oldest_age) {
            oldest_age = age;
            oldest_idx = i;
        }

        // Track youngest to detect attack scenario
        if (age < youngest_age) {
            youngest_age = age;
        }
    }

    // 3. If all entries are very young (likely attack), use random eviction
    // to prevent attacker from predicting which flows will be evicted
    const attack_threshold: u64 = 2; // All entries less than 2 ticks old
    if (youngest_age < attack_threshold and oldest_age < attack_threshold) {
        // Use simple counter-based pseudo-random index
        eviction_counter +%= 1;
        const random_idx = eviction_counter % MAX_REASSEMBLIES;
        return Allocation{ .ptr = &cache[random_idx], .index = random_idx };
    }

    // 4. Normal case: evict oldest (LRU)
    return Allocation{ .ptr = &cache[oldest_idx], .index = oldest_idx };
}

/// Update holes by removing the covered range [start, end)
fn updateHoles(e: *ReassemblyEntry, start: usize, end: usize) void {
    var i: usize = 0;
    while (i < e.hole_count) {
        var h = &e.holes[i];
        
        // Case 1: Fragment completely covers hole - remove hole
        if (start <= h.start and end >= h.end) {
            removeHole(e, i);
            continue; // Don't increment i
        }
        
        // Case 2: Fragment inside hole - split hole
        if (start > h.start and end < h.end) {
            if (e.hole_count >= 16) {
                // Cannot split hole - too many fragments. Mark entry invalid.
                // This prevents leaving the reassembly in an inconsistent state
                // where data was copied but holes don't reflect actual gaps.
                e.used = false;
                return;
            }
            const new_hole = ReassemblyEntry.Hole{ .start = end, .end = h.end };
            h.end = start;
            e.holes[e.hole_count] = new_hole;
            e.hole_count += 1;
            i += 1;
            continue;
        }
        
        // Case 3: Overlap start of hole
        if (start <= h.start and end > h.start) {
            h.start = end;
        }
        
        // Case 4: Overlap end of hole
        if (start < h.end and end >= h.end) {
            h.end = start;
        }
        
        i += 1;
    }
}

fn removeHole(e: *ReassemblyEntry, idx: usize) void {
    if (idx >= e.hole_count) return;
    const last = e.hole_count - 1;
    if (idx != last) {
        e.holes[idx] = e.holes[last];
    }
    e.hole_count -= 1;
}

/// Check if a fragment region overlaps with already-filled data
/// Returns true if ANY part of [start, end) is NOT within a hole (i.e., overlaps filled data)
fn isRegionOverlapping(e: *const ReassemblyEntry, start: usize, end: usize) bool {
    // A fragment is NOT overlapping if it fits entirely within at least one hole.
    // We need to check if the entire region [start, end) is covered by holes.

    // Simple check: if the region fits completely within a single hole, it's not overlapping
    for (e.holes[0..e.hole_count]) |hole| {
        if (start >= hole.start and end <= hole.end) {
            return false; // Entirely within this hole - no overlap
        }
    }

    // More complex case: region might span multiple adjacent holes
    // For simplicity and security, we require the region to fit in ONE hole.
    // This is stricter than necessary but safer - any partial overlap is rejected.
    return true; // Region overlaps with filled data
}

/// Check if reassembly is complete
fn isComplete(e: *const ReassemblyEntry) bool {
    if (e.total_len == 0) return false; // Haven't seen last fragment yet
    
    // If hole list is empty, we are good?
    // Wait, holes are initialized to [0, MAX].
    // If we have any hole left, we are incomplete.
    // Except holes must be checked against total_len.
    // If we updated holes correctly, any hole with start < total_len means missing data.
    
    for (0..e.hole_count) |i| {
        if (e.holes[i].start < e.total_len) return false;
    }
    
    return true;
}
