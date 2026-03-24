// NDP Neighbor Cache
//
// Implements RFC 4861 Section 7.3 neighbor cache with states:
// INCOMPLETE -> REACHABLE -> STALE -> DELAY -> PROBE
//
// Security features:
// - DoS protection via entry limits
// - Rate limiting on cache updates
// - Static entry protection
// - Generation counters for TOCTOU prevention

const std = @import("std");
const types = @import("types.zig");
const sync = @import("../../sync.zig");
pub const NeighborEntry = types.NeighborEntry;
pub const NeighborState = types.NeighborState;

// =============================================================================
// Cache Configuration
// =============================================================================

/// Maximum neighbor cache entries (DoS protection)
pub const MAX_NEIGHBOR_ENTRIES: usize = 256;

/// Maximum incomplete entries (DoS protection)
/// SECURITY: Limits neighbor cache exhaustion attacks. An attacker flooding packets
/// to non-existent hosts can only create 64 incomplete entries. After this limit,
/// new resolution requests fail until existing entries timeout (3 seconds).
/// This is a tradeoff: lower = more DoS resistant but may block legitimate resolution.
pub const MAX_INCOMPLETE_ENTRIES: usize = 64;

/// Hash table size (power of 2 for fast modulo)
pub const HASH_TABLE_SIZE: usize = 512;

/// Cache entry timeout in ticks (reachable -> stale)
pub const REACHABLE_TIMEOUT: u64 = 30_000; // ~30 seconds at 1kHz

/// Incomplete entry timeout in ticks
pub const INCOMPLETE_TIMEOUT: u64 = 3_000; // ~3 seconds

/// Rate limit for cache updates (ticks between updates for same address)
pub const UPDATE_RATE_LIMIT: u64 = 100;

// =============================================================================
// Global State
// =============================================================================

/// Neighbor cache storage
pub var neighbor_cache: std.ArrayListUnmanaged(NeighborEntry) = .empty;

/// Allocator for cache operations
pub var cache_allocator: std.mem.Allocator = undefined;

/// Current tick counter (set by timer subsystem)
pub var current_tick: u64 = 0;

/// Count of incomplete entries for DoS protection
pub var incomplete_entry_count: usize = 0;

/// IRQ-safe spinlock for cache access
pub var lock: sync.Spinlock = .{};

/// Hash table for O(1) lookup
pub var hash_table: [HASH_TABLE_SIZE]?*NeighborEntry = [_]?*NeighborEntry{null} ** HASH_TABLE_SIZE;

// =============================================================================
// Hash Functions
// =============================================================================

/// Hash function for IPv6 address
/// Uses last 4 bytes (most variable part) mixed with golden ratio
pub fn hashIpv6(addr: [16]u8) usize {
    const golden_ratio: u32 = 0x9E3779B9;
    const last4 = std.mem.readInt(u32, addr[12..16], .big);
    const hash = last4 *% golden_ratio;
    return @as(usize, hash >> (32 - 9)) & (HASH_TABLE_SIZE - 1);
}

// =============================================================================
// Cache Operations (caller must hold lock)
// =============================================================================

/// Find entry by IPv6 address using hash table
pub fn findEntry(addr: [16]u8) ?*NeighborEntry {
    const idx = hashIpv6(addr);
    var curr = hash_table[idx];

    while (curr) |entry| {
        if (entry.state != .Free and std.mem.eql(u8, &entry.ipv6_addr, &addr)) {
            return entry;
        }
        curr = entry.hash_next;
    }
    return null;
}

/// Insert entry into hash table
fn hashTableInsert(entry: *NeighborEntry) void {
    const idx = hashIpv6(entry.ipv6_addr);
    entry.hash_next = hash_table[idx];
    hash_table[idx] = entry;
}

/// Remove entry from hash table
fn hashTableRemove(entry: *NeighborEntry) void {
    const idx = hashIpv6(entry.ipv6_addr);
    var prev: ?*NeighborEntry = null;
    var curr = hash_table[idx];

    while (curr) |c| {
        if (c == entry) {
            if (prev) |p| {
                p.hash_next = c.hash_next;
            } else {
                hash_table[idx] = c.hash_next;
            }
            entry.hash_next = null;
            return;
        }
        prev = c;
        curr = c.hash_next;
    }
}

/// Clear pending packet queue for an entry
pub fn clearPending(entry: *NeighborEntry) void {
    for (&entry.pending_pkts, 0..) |*slot, idx| {
        if (slot.*) |buf| {
            cache_allocator.free(buf);
            slot.* = null;
        }
        entry.pending_lens[idx] = 0;
    }
    entry.queue_head = 0;
    entry.queue_tail = 0;
    entry.queue_count = 0;
}

/// Find or allocate a free entry
pub fn findFreeEntry() !*NeighborEntry {
    // First pass: look for free entry
    for (neighbor_cache.items) |*entry| {
        if (entry.state == .Free) {
            clearPending(entry);
            return entry;
        }
    }

    // Second pass: evict oldest stale entry
    var oldest_stale: ?*NeighborEntry = null;
    var oldest_stale_time: u64 = current_tick;

    for (neighbor_cache.items) |*entry| {
        if (entry.state == .Stale and !entry.is_static and entry.timestamp < oldest_stale_time) {
            oldest_stale = entry;
            oldest_stale_time = entry.timestamp;
        }
    }

    if (oldest_stale) |entry| {
        hashTableRemove(entry);
        clearPending(entry);
        return entry;
    }

    // Third pass: evict oldest reachable entry
    if (neighbor_cache.items.len >= MAX_NEIGHBOR_ENTRIES) {
        var oldest_reachable: ?*NeighborEntry = null;
        var oldest_reachable_time: u64 = current_tick;

        for (neighbor_cache.items) |*entry| {
            if (entry.state == .Reachable and !entry.is_static and entry.timestamp < oldest_reachable_time) {
                oldest_reachable = entry;
                oldest_reachable_time = entry.timestamp;
            }
        }

        if (oldest_reachable) |entry| {
            hashTableRemove(entry);
            clearPending(entry);
            return entry;
        }

        // Last resort: evict oldest incomplete
        var oldest_incomplete: ?*NeighborEntry = null;
        var oldest_incomplete_time: u64 = current_tick;

        for (neighbor_cache.items) |*entry| {
            if (entry.state == .Incomplete and entry.timestamp < oldest_incomplete_time) {
                oldest_incomplete = entry;
                oldest_incomplete_time = entry.timestamp;
            }
        }

        if (oldest_incomplete) |entry| {
            hashTableRemove(entry);
            clearPending(entry);
            if (incomplete_entry_count > 0) incomplete_entry_count -= 1;
            return entry;
        }

        return error.OutOfMemory;
    }

    // Allocate new entry
    const new_entry = try neighbor_cache.addOne(cache_allocator);
    new_entry.* = NeighborEntry.init();
    return new_entry;
}

// =============================================================================
// Pending Packet Management
// =============================================================================

/// Struct for deferred packet transmission (outside lock)
pub const PendingPackets = struct {
    pkts: [NeighborEntry.QUEUE_SIZE]?[]u8 = [_]?[]u8{null} ** NeighborEntry.QUEUE_SIZE,
    lens: [NeighborEntry.QUEUE_SIZE]usize = [_]usize{0} ** NeighborEntry.QUEUE_SIZE,
    mac: [6]u8 = [_]u8{0} ** 6,
    count: u8 = 0,
};

/// Update cache with new neighbor information
/// Returns pending packets for deferred transmission
pub fn updateCache(addr: [16]u8, mac: [6]u8, state: NeighborState, is_router: bool) !PendingPackets {
    var pending = PendingPackets{};

    // Validate MAC - reject broadcast/multicast/zero
    if (mac[0] == 0xFF and mac[1] == 0xFF) return pending; // Broadcast
    if ((mac[0] & 0x01) != 0) return pending; // Multicast
    if (std.mem.eql(u8, &mac, &[_]u8{0} ** 6)) return pending; // Zero

    if (findEntry(addr)) |entry| {
        // Protect static entries
        if (entry.is_static) return pending;

        // Rate limit updates for non-incomplete entries
        if (entry.state != .Incomplete) {
            const time_since = current_tick -% entry.timestamp;
            if (time_since < UPDATE_RATE_LIMIT) return pending;
        }

        const was_incomplete = entry.state == .Incomplete;

        // Update entry
        @memcpy(&entry.mac_addr, &mac);
        entry.state = state;
        entry.timestamp = current_tick;
        entry.retries = 0;
        entry.is_router = is_router;
        entry.generation +%= 1;

        if (was_incomplete and state == .Reachable) {
            if (incomplete_entry_count > 0) incomplete_entry_count -= 1;
        }

        // Extract pending packets for deferred transmission
        if (entry.queue_count > 0) {
            @memcpy(&pending.mac, &mac);
            var i: u8 = 0;
            while (i < entry.queue_count) : (i += 1) {
                const idx = (entry.queue_head +% i) % @as(u8, @intCast(NeighborEntry.QUEUE_SIZE));
                if (entry.pending_pkts[idx]) |buf| {
                    pending.pkts[pending.count] = buf;
                    pending.lens[pending.count] = entry.pending_lens[idx];
                    pending.count += 1;
                    entry.pending_pkts[idx] = null;
                    entry.pending_lens[idx] = 0;
                }
            }
            entry.queue_count = 0;
            entry.queue_head = 0;
            entry.queue_tail = 0;
        }

        return pending;
    }

    // Don't create entries for unsolicited advertisements (security)
    return pending;
}

/// Create a new incomplete entry for address resolution
pub fn createIncompleteEntry(addr: [16]u8) !*NeighborEntry {
    // Check DoS limit
    if (incomplete_entry_count >= MAX_INCOMPLETE_ENTRIES) {
        return error.TooManyIncomplete;
    }

    // Check if already exists
    if (findEntry(addr)) |entry| {
        return entry;
    }

    const entry = try findFreeEntry();
    entry.* = NeighborEntry.init();
    @memcpy(&entry.ipv6_addr, &addr);
    entry.state = .Incomplete;
    entry.timestamp = current_tick;
    entry.retries = 1;

    hashTableInsert(entry);
    incomplete_entry_count += 1;

    return entry;
}

/// Queue a packet for later transmission after address resolution
pub fn queuePacket(entry: *NeighborEntry, data: []const u8) bool {
    if (entry.queue_count >= NeighborEntry.QUEUE_SIZE) {
        // Drop oldest packet
        const head_idx = @as(usize, entry.queue_head);
        if (entry.pending_pkts[head_idx]) |old_buf| {
            cache_allocator.free(old_buf);
            entry.pending_pkts[head_idx] = null;
        }
        entry.queue_head = (entry.queue_head + 1) % @as(u8, @intCast(NeighborEntry.QUEUE_SIZE));
        entry.queue_count -= 1;
    }

    const buf = cache_allocator.alloc(u8, data.len) catch return false;
    @memcpy(buf, data);

    const tail_idx = @as(usize, entry.queue_tail);
    entry.pending_pkts[tail_idx] = buf;
    entry.pending_lens[tail_idx] = data.len;
    entry.queue_tail = (entry.queue_tail + 1) % @as(u8, @intCast(NeighborEntry.QUEUE_SIZE));
    entry.queue_count += 1;

    return true;
}

// =============================================================================
// Public API
// =============================================================================

/// Initialize the neighbor cache subsystem
pub fn init(allocator: std.mem.Allocator) void {
    cache_allocator = allocator;
    neighbor_cache = .empty;
    incomplete_entry_count = 0;

    for (&hash_table) |*bucket| {
        bucket.* = null;
    }
}

/// Clear all cache entries
pub fn clearCache() void {
    const held = lock.acquire();
    defer held.release();

    for (neighbor_cache.items) |*entry| {
        clearPending(entry);
        entry.state = .Free;
    }
    neighbor_cache.clearRetainingCapacity();

    for (&hash_table) |*bucket| {
        bucket.* = null;
    }

    incomplete_entry_count = 0;
}

/// Get MAC address for IPv6 address (if cached and valid)
pub fn lookup(addr: [16]u8) ?[6]u8 {
    const held = lock.acquire();
    defer held.release();

    if (findEntry(addr)) |entry| {
        if (entry.state == .Reachable or entry.state == .Stale or
            entry.state == .Delay or entry.state == .Probe)
        {
            return entry.mac_addr;
        }
    }
    return null;
}

/// Add a static neighbor entry
pub fn addStaticEntry(addr: [16]u8, mac: [6]u8) !void {
    // Validate MAC
    if ((mac[0] & 0x01) != 0) return error.InvalidAddress;
    if (std.mem.eql(u8, &mac, &[_]u8{0} ** 6)) return error.InvalidAddress;

    const held = lock.acquire();
    defer held.release();

    // Update existing entry if present
    if (findEntry(addr)) |entry| {
        @memcpy(&entry.mac_addr, &mac);
        entry.state = .Reachable;
        entry.is_static = true;
        entry.timestamp = current_tick;
        entry.generation +%= 1;
        return;
    }

    // Create new entry
    const entry = try findFreeEntry();
    entry.* = NeighborEntry.init();
    @memcpy(&entry.ipv6_addr, &addr);
    @memcpy(&entry.mac_addr, &mac);
    entry.state = .Reachable;
    entry.is_static = true;
    entry.timestamp = current_tick;

    hashTableInsert(entry);
}

/// Remove a static entry
pub fn removeStaticEntry(addr: [16]u8) bool {
    const held = lock.acquire();
    defer held.release();

    if (findEntry(addr)) |entry| {
        if (entry.is_static) {
            hashTableRemove(entry);
            clearPending(entry);
            entry.state = .Free;
            entry.is_static = false;
            return true;
        }
    }
    return false;
}

/// Get number of active entries
pub fn getCacheCount() usize {
    const held = lock.acquire();
    defer held.release();

    var count: usize = 0;
    for (neighbor_cache.items) |entry| {
        if (entry.state != .Free) {
            count += 1;
        }
    }
    return count;
}

/// Tick the cache timer (call periodically to expire entries)
pub fn tick() void {
    const held = lock.acquire();
    defer held.release();

    current_tick +%= 1;

    // Transition REACHABLE entries to STALE after timeout
    for (neighbor_cache.items) |*entry| {
        if (entry.is_static) continue;

        switch (entry.state) {
            .Reachable => {
                const age = current_tick -% entry.timestamp;
                if (age > REACHABLE_TIMEOUT) {
                    entry.state = .Stale;
                    entry.timestamp = current_tick;
                }
            },
            .Incomplete => {
                const age = current_tick -% entry.timestamp;
                if (age > INCOMPLETE_TIMEOUT) {
                    // Failed to resolve - clear entry
                    hashTableRemove(entry);
                    clearPending(entry);
                    entry.state = .Free;
                    if (incomplete_entry_count > 0) incomplete_entry_count -= 1;
                }
            },
            else => {},
        }
    }
}
