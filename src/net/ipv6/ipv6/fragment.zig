// IPv6 Fragment Reassembly
//
// Handles reassembly of fragmented IPv6 packets (RFC 8200 Section 4.5).
// Maintains a cache of partial packets and assembles them into complete datagrams.
//
// Key differences from IPv4:
// - 128-bit addresses in fragment key
// - 32-bit identification field (vs 16-bit in IPv4)
// - Fragment header is an extension header, not part of base header
// - RFC 5722 mandates dropping overlapping fragments (same as modern IPv4)
//
// References:
// - RFC 8200: Internet Protocol, Version 6 (IPv6) Specification
// - RFC 5722: Handling of Overlapping IPv6 Fragments

const std = @import("std");
const packet = @import("../../core/packet.zig");
const net_pool = @import("../../core/pool.zig");
const sync = @import("../../sync.zig");
const types = @import("types.zig");
const PacketBuffer = packet.PacketBuffer;

/// Maximum size of an IPv6 packet payload (64KB - 1, jumbograms not supported)
const MAX_IPV6_PAYLOAD_SIZE: usize = 65535;

/// Maximum time to hold fragments (seconds)
/// RFC 8200 recommends 60 seconds, reduced for DoS protection
const REASSEMBLY_TIMEOUT: u64 = 30;

/// Maximum concurrent reassemblies
const MAX_REASSEMBLIES: usize = 64;

/// Minimum fragment payload size for middle fragments (DoS protection)
/// Prevents fragment bomb attacks with tiny 8-byte fragments
const MIN_FRAGMENT_SIZE: usize = 256;

/// Minimum first fragment size - must contain transport header
/// 8 bytes = ICMPv6 header (smallest transport we handle)
const MIN_FIRST_FRAGMENT_SIZE: usize = 8;

/// Maximum holes per reassembly entry
const MAX_HOLES: usize = 64;

/// Fragment reassembly entry
const ReassemblyEntry = struct {
    used: bool,
    key: FragmentKey,
    timer: u64,

    /// Reassembly buffer (holds unfragmentable part + fragmentable part)
    buffer: []u8,

    /// Total expected length of payload (0 if unknown)
    total_len: usize,

    /// Bytes received so far
    received_len: usize,

    /// Next header value from Fragment header (the actual transport protocol)
    next_header: u8,

    /// Hole descriptor list
    holes: [MAX_HOLES]Hole,
    hole_count: usize,

    const Hole = struct {
        start: usize,
        end: usize, // Exclusive
    };

    fn init(key: FragmentKey, timer: u64, next_header: u8) ReassemblyEntry {
        var e = ReassemblyEntry{
            .used = true,
            .key = key,
            .timer = timer,
            .buffer = &[_]u8{},
            .total_len = 0,
            .received_len = 0,
            .next_header = next_header,
            .holes = undefined,
            .hole_count = 1,
        };
        // Initial hole covers entire theoretical range
        e.holes[0] = Hole{ .start = 0, .end = MAX_IPV6_PAYLOAD_SIZE };
        return e;
    }

    fn deinit(self: *ReassemblyEntry) void {
        if (self.buffer.len > 0) {
            net_pool.freeReassemblyBuffer(self.buffer);
        }
        self.buffer = &[_]u8{};
    }
};

/// Key to identify IPv6 fragments
/// Per RFC 8200: {Source Address, Destination Address, Fragment Identification}
const FragmentKey = struct {
    src_addr: [16]u8,
    dst_addr: [16]u8,
    identification: u32,
};

/// Global reassembly cache
var cache: [MAX_REASSEMBLIES]ReassemblyEntry = undefined;
var cache_initialized: bool = false;

/// IRQ-safe spinlock for concurrent access
var lock: sync.Spinlock = .{};
var current_tick: u64 = 0;

/// Initialize module
pub fn init() void {
    if (!cache_initialized) {
        for (&cache) |*entry| {
            entry.used = false;
            entry.buffer = &[_]u8{};
        }
        cache_initialized = true;
    }
}

/// Update timer tick
pub fn tick() void {
    current_tick +%= 1;
}

/// Result of reassembly
pub const ReassemblyResult = struct {
    /// Owned buffer - caller must free with reassembly allocator
    owned_buffer: []u8,
    /// Actual payload length
    payload_len: usize,
    /// Next header (transport protocol)
    next_header: u8,

    /// Get the payload slice
    pub fn payload(self: *const ReassemblyResult) []u8 {
        return self.owned_buffer[0..self.payload_len];
    }

    /// Free the owned buffer
    pub fn deinit(self: *ReassemblyResult) void {
        if (self.owned_buffer.len > 0) {
            net_pool.freeReassemblyBuffer(self.owned_buffer);
            self.owned_buffer = &[_]u8{};
            self.payload_len = 0;
        }
    }
};

/// Process a fragment of an IPv6 packet
///
/// Parameters:
///   - src_addr: Source IPv6 address
///   - dst_addr: Destination IPv6 address
///   - frag_info: Fragment information from Fragment extension header
///   - payload: Fragment payload (data after Fragment header)
///
/// Returns:
///   - ReassemblyResult if complete (caller owns buffer, must call deinit())
///   - null if incomplete or dropped
pub fn processFragment(
    src_addr: [16]u8,
    dst_addr: [16]u8,
    frag_info: types.FragmentInfo,
    payload: []const u8,
) ?ReassemblyResult {
    const held = lock.acquire();
    defer held.release();

    if (!cache_initialized) return null;

    const key = FragmentKey{
        .src_addr = src_addr,
        .dst_addr = dst_addr,
        .identification = frag_info.identification,
    };

    // Find existing entry or allocate new one
    var entry: ?*ReassemblyEntry = null;

    for (&cache) |*e| {
        if (e.used and std.mem.eql(u8, &e.key.src_addr, &key.src_addr) and
            std.mem.eql(u8, &e.key.dst_addr, &key.dst_addr) and
            e.key.identification == key.identification)
        {
            entry = e;
            break;
        }
    }

    if (entry == null) {
        if (allocateEntry()) |alloc| {
            entry = alloc.ptr;
            entry.?.* = ReassemblyEntry.init(key, current_tick, frag_info.next_header);
        } else {
            return null; // Cache full
        }
    }

    const e = entry.?;

    // Calculate fragment position (offset is in 8-octet units)
    const start = std.math.mul(usize, @as(usize, frag_info.offset), 8) catch return null;

    if (start >= MAX_IPV6_PAYLOAD_SIZE) return null;
    if (payload.len > MAX_IPV6_PAYLOAD_SIZE - start) return null;

    const end = start + payload.len;
    if (end > MAX_IPV6_PAYLOAD_SIZE) return null;

    // Security checks for fragment size
    const is_first_fragment = (frag_info.offset == 0);
    const is_last_fragment = !frag_info.more_fragments;

    // First fragment must contain transport header
    if (is_first_fragment and payload.len < MIN_FIRST_FRAGMENT_SIZE) {
        e.used = false;
        e.deinit();
        return null;
    }

    // Middle fragments must be reasonably sized
    if (!is_first_fragment and !is_last_fragment and payload.len < MIN_FRAGMENT_SIZE) {
        e.used = false;
        e.deinit();
        return null;
    }

    // Ensure buffer is large enough
    if (end > e.buffer.len) {
        var new_len = (end + 2047) & ~@as(usize, 2047);
        if (new_len > MAX_IPV6_PAYLOAD_SIZE) new_len = MAX_IPV6_PAYLOAD_SIZE;

        if (e.buffer.len == 0) {
            e.buffer = net_pool.allocReassemblyBuffer(new_len) orelse {
                e.used = false;
                return null;
            };
            // SECURITY: Zero-initialize for defense-in-depth per CLAUDE.md.
            // Although hole tracking prevents returning incomplete packets,
            // zero-init guards against potential bugs in hole management.
            @memset(e.buffer, 0);
        } else {
            // Reallocation
            const old_len = e.buffer.len;
            const new_buf = net_pool.reallocReassemblyBuffer(e.buffer, new_len) orelse {
                e.used = false;
                e.deinit();
                return null;
            };
            // SECURITY: Zero the newly allocated portion for defense-in-depth.
            @memset(new_buf[old_len..], 0);
            e.buffer = new_buf;
        }
    }

    // Update total length if this is the last fragment
    if (!frag_info.more_fragments) {
        e.total_len = end;
        // Truncate holes beyond total_len
        for (0..e.hole_count) |i| {
            if (e.holes[i].end > e.total_len) {
                e.holes[i].end = e.total_len;
            }
        }
    }

    // RFC 5722: Reject overlapping fragments
    if (isRegionOverlapping(e, start, end)) {
        e.used = false;
        e.deinit();
        return null;
    }

    // Copy data to buffer
    @memcpy(e.buffer[start..end], payload);

    // Update holes
    updateHoles(e, start, end);

    if (!e.used) {
        e.deinit();
        return null;
    }

    // Check completion
    if (isComplete(e)) {
        const owned_buf = net_pool.allocReassemblyBuffer(e.total_len) orelse {
            e.used = false;
            e.deinit();
            return null;
        };

        @memcpy(owned_buf[0..e.total_len], e.buffer[0..e.total_len]);

        const final_payload_len = e.total_len;
        const final_next_header = e.next_header;

        e.used = false;
        e.deinit();

        return ReassemblyResult{
            .owned_buffer = owned_buf,
            .payload_len = final_payload_len,
            .next_header = final_next_header,
        };
    }

    return null;
}

const Allocation = struct {
    ptr: *ReassemblyEntry,
    index: usize,
};

var eviction_counter: usize = 0;

fn allocateEntry() ?Allocation {
    // Find free entry
    for (&cache, 0..) |*e, i| {
        if (!e.used) return Allocation{ .ptr = e, .index = i };
    }

    // Find timed-out or oldest entry
    var oldest_idx: usize = 0;
    var oldest_age: u64 = 0;
    var youngest_age: u64 = std.math.maxInt(u64);

    for (&cache, 0..) |*e, i| {
        const age = current_tick -% e.timer;

        if (age >= REASSEMBLY_TIMEOUT) {
            e.used = false;
            e.deinit();
            return Allocation{ .ptr = e, .index = i };
        }

        if (age > oldest_age) {
            oldest_age = age;
            oldest_idx = i;
        }

        if (age < youngest_age) {
            youngest_age = age;
        }
    }

    // Random eviction if under attack
    const attack_threshold: u64 = 2;
    if (youngest_age < attack_threshold and oldest_age < attack_threshold) {
        eviction_counter +%= 1;
        const random_idx = eviction_counter % MAX_REASSEMBLIES;
        cache[random_idx].used = false;
        cache[random_idx].deinit();
        return Allocation{ .ptr = &cache[random_idx], .index = random_idx };
    }

    // Evict oldest
    cache[oldest_idx].used = false;
    cache[oldest_idx].deinit();
    return Allocation{ .ptr = &cache[oldest_idx], .index = oldest_idx };
}

fn updateHoles(e: *ReassemblyEntry, start: usize, end: usize) void {
    var i: usize = 0;
    while (i < e.hole_count) {
        var h = &e.holes[i];

        // Fragment completely covers hole
        if (start <= h.start and end >= h.end) {
            removeHole(e, i);
            continue;
        }

        // Fragment inside hole - split
        if (start > h.start and end < h.end) {
            if (e.hole_count >= MAX_HOLES) {
                e.used = false;
                e.deinit();
                return;
            }
            const new_hole = ReassemblyEntry.Hole{ .start = end, .end = h.end };
            h.end = start;
            e.holes[e.hole_count] = new_hole;
            e.hole_count += 1;
            i += 1;
            continue;
        }

        // Overlap start of hole
        if (start <= h.start and end > h.start) {
            h.start = end;
        }

        // Overlap end of hole
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

fn isRegionOverlapping(e: *const ReassemblyEntry, start: usize, end: usize) bool {
    for (0..e.hole_count) |i| {
        const h = e.holes[i];
        if (start >= h.start and end <= h.end) {
            return false; // Fits entirely within a hole - not overlapping
        }
    }
    return true; // No hole contains this region - overlaps with existing data
}

fn isComplete(e: *const ReassemblyEntry) bool {
    if (e.total_len == 0) return false;

    for (0..e.hole_count) |i| {
        if (e.holes[i].start < e.total_len) return false;
    }

    return true;
}

// =============================================================================
// Tests
// =============================================================================

test "fragment key comparison" {
    const testing = std.testing;

    const key1 = FragmentKey{
        .src_addr = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .dst_addr = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 },
        .identification = 0x12345678,
    };

    const key2 = FragmentKey{
        .src_addr = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .dst_addr = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 },
        .identification = 0x12345678,
    };

    try testing.expect(std.mem.eql(u8, &key1.src_addr, &key2.src_addr));
    try testing.expect(std.mem.eql(u8, &key1.dst_addr, &key2.dst_addr));
    try testing.expectEqual(key1.identification, key2.identification);
}
