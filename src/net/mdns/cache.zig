// mDNS Record Cache
// Stores received mDNS records with TTL-based expiration
// Pattern follows src/net/ipv4/arp/cache.zig

const std = @import("std");
const sync = @import("../sync.zig");
const constants = @import("constants.zig");
const dns = @import("../dns/dns.zig");

/// Cache entry state
pub const CacheState = enum {
    /// Entry is free for reuse
    free,
    /// Entry contains valid cached record
    valid,
    /// Entry is expiring soon (TTL < 20% remaining)
    stale,
};

/// mDNS cache entry
pub const CacheEntry = struct {
    /// Record name (e.g., "myhost.local")
    name: [constants.MAX_HOSTNAME_LEN + 16]u8, // Extra for .local suffix
    name_len: usize,

    /// DNS record type (A, AAAA, SRV, TXT, PTR)
    record_type: u16,

    /// DNS record class (normally CLASS_IN, with cache-flush bit masked)
    record_class: u16,

    /// Original TTL from record (seconds)
    original_ttl: u32,

    /// Timestamp when record was received (in ticks)
    timestamp: u64,

    /// Record data (interpretation depends on record_type)
    /// For A: 4 bytes IPv4
    /// For AAAA: 16 bytes IPv6
    /// For SRV: priority(2) + weight(2) + port(2) + target name
    /// For TXT: length-prefixed strings
    /// For PTR: target name
    data: [512]u8,
    data_len: usize,

    /// Entry state
    state: CacheState,

    /// Hash chain pointer for O(1) lookup
    hash_next: ?*CacheEntry,

    /// Check if entry has expired
    pub fn isExpired(self: *const CacheEntry, tick_now: u64, tps: u32) bool {
        if (self.state == .free) return true;

        // Calculate elapsed time in seconds using checked arithmetic
        const elapsed_ticks = tick_now -% self.timestamp;
        const elapsed_secs = elapsed_ticks / tps;

        return elapsed_secs >= self.original_ttl;
    }

    /// Check if entry is stale (TTL < 20% remaining)
    pub fn isStale(self: *const CacheEntry, tick_now: u64, tps: u32) bool {
        if (self.state == .free) return true;
        if (self.original_ttl == 0) return true;

        const elapsed_ticks = tick_now -% self.timestamp;
        const elapsed_secs = elapsed_ticks / tps;

        // Stale if less than 20% TTL remaining
        const threshold = self.original_ttl / 5;
        return elapsed_secs >= (self.original_ttl - threshold);
    }

    /// Get remaining TTL in seconds
    pub fn remainingTtl(self: *const CacheEntry, tick_now: u64, tps: u32) u32 {
        if (self.state == .free) return 0;

        const elapsed_ticks = tick_now -% self.timestamp;
        const elapsed_secs = @as(u32, @truncate(elapsed_ticks / tps));

        if (elapsed_secs >= self.original_ttl) return 0;
        return self.original_ttl - elapsed_secs;
    }
};

/// Cache constants
pub const CACHE_HASH_SIZE: usize = constants.CACHE_HASH_SIZE;
pub const MAX_CACHE_ENTRIES: usize = constants.MAX_CACHE_ENTRIES;

/// Global cache state
var cache_entries: std.ArrayListUnmanaged(CacheEntry) = .{};
var cache_allocator: std.mem.Allocator = undefined;
var cache_lock: sync.Spinlock = .{};
var hash_table: [CACHE_HASH_SIZE]?*CacheEntry = [_]?*CacheEntry{null} ** CACHE_HASH_SIZE;
var ticks_per_second: u32 = 100; // Default, updated in init
var current_tick: u64 = 0;

/// Hash function for name + type combination
fn hashNameType(name: []const u8, record_type: u16) usize {
    var hash: u32 = 0;

    // FNV-1a hash for name (case-insensitive)
    for (name) |c| {
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        hash ^= lower;
        hash *%= 0x01000193;
    }

    // Mix in record type
    hash ^= record_type;
    hash *%= 0x01000193;

    return @as(usize, hash) & (CACHE_HASH_SIZE - 1);
}

/// Case-insensitive name comparison (DNS names are case-insensitive)
fn namesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

/// Find entry by name and type using O(1) hash lookup
/// Caller must hold lock
fn findEntryLocked(name: []const u8, record_type: u16) ?*CacheEntry {
    const idx = hashNameType(name, record_type);
    var curr = hash_table[idx];

    while (curr) |entry| {
        if (entry.state != .free and
            entry.record_type == record_type and
            namesEqual(entry.name[0..entry.name_len], name))
        {
            return entry;
        }
        curr = entry.hash_next;
    }
    return null;
}

/// Insert entry into hash table
fn hashTableInsert(entry: *CacheEntry) void {
    const idx = hashNameType(entry.name[0..entry.name_len], entry.record_type);
    entry.hash_next = hash_table[idx];
    hash_table[idx] = entry;
}

/// Remove entry from hash table
fn hashTableRemove(entry: *CacheEntry) void {
    const idx = hashNameType(entry.name[0..entry.name_len], entry.record_type);
    var prev: ?*CacheEntry = null;
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

/// Find a free entry or evict oldest
fn findFreeEntryLocked() !*CacheEntry {
    // First, look for a free entry
    for (cache_entries.items) |*entry| {
        if (entry.state == .free) {
            return entry;
        }
    }

    // Second, evict oldest expired entry
    var oldest_expired: ?*CacheEntry = null;
    var oldest_expired_time: u64 = current_tick;

    for (cache_entries.items) |*entry| {
        if (entry.state != .free and entry.isExpired(current_tick, ticks_per_second)) {
            if (entry.timestamp < oldest_expired_time) {
                oldest_expired = entry;
                oldest_expired_time = entry.timestamp;
            }
        }
    }

    if (oldest_expired) |entry| {
        hashTableRemove(entry);
        return entry;
    }

    // Third, evict oldest stale entry
    var oldest_stale: ?*CacheEntry = null;
    var oldest_stale_time: u64 = current_tick;

    for (cache_entries.items) |*entry| {
        if (entry.state == .stale and entry.timestamp < oldest_stale_time) {
            oldest_stale = entry;
            oldest_stale_time = entry.timestamp;
        }
    }

    if (oldest_stale) |entry| {
        hashTableRemove(entry);
        return entry;
    }

    // Fourth, if below max, allocate new entry
    if (cache_entries.items.len < MAX_CACHE_ENTRIES) {
        const new_entry = try cache_entries.addOne(cache_allocator);
        new_entry.* = std.mem.zeroes(CacheEntry);
        new_entry.state = .free;
        return new_entry;
    }

    // Fifth, evict oldest valid entry (LRU)
    var oldest_valid: ?*CacheEntry = null;
    var oldest_valid_time: u64 = current_tick;

    for (cache_entries.items) |*entry| {
        if (entry.state == .valid and entry.timestamp < oldest_valid_time) {
            oldest_valid = entry;
            oldest_valid_time = entry.timestamp;
        }
    }

    if (oldest_valid) |entry| {
        hashTableRemove(entry);
        return entry;
    }

    return error.OutOfMemory;
}

/// Initialize the cache
pub fn init(allocator: std.mem.Allocator, ticks_per_sec: u32) void {
    cache_allocator = allocator;
    cache_entries = .{};
    ticks_per_second = if (ticks_per_sec > 0) ticks_per_sec else 100;
    current_tick = 0;

    // Clear hash table
    for (&hash_table) |*bucket| {
        bucket.* = null;
    }
}

/// Deinitialize the cache
pub fn deinit() void {
    const held = cache_lock.acquire();
    defer held.release();

    cache_entries.deinit(cache_allocator);
    for (&hash_table) |*bucket| {
        bucket.* = null;
    }
}

/// Lookup a record in the cache
/// Returns null if not found or expired
pub fn lookup(name: []const u8, record_type: u16) ?*const CacheEntry {
    const held = cache_lock.acquire();
    defer held.release();

    if (findEntryLocked(name, record_type)) |entry| {
        if (!entry.isExpired(current_tick, ticks_per_second)) {
            return entry;
        }
        // Expired, mark as free
        hashTableRemove(entry);
        entry.state = .free;
    }
    return null;
}

/// Insert or update a record in the cache
pub fn insert(name: []const u8, record_type: u16, record_class: u16, ttl: u32, data: []const u8) !void {
    if (name.len == 0 or name.len > constants.MAX_HOSTNAME_LEN + 16) return error.InvalidArgument;
    if (data.len > 512) return error.InvalidArgument;

    const held = cache_lock.acquire();
    defer held.release();

    // TTL=0 means goodbye packet - remove the entry
    if (ttl == 0) {
        if (findEntryLocked(name, record_type)) |entry| {
            hashTableRemove(entry);
            entry.state = .free;
        }
        return;
    }

    // Check if entry already exists
    if (findEntryLocked(name, record_type)) |entry| {
        // Update existing entry
        entry.original_ttl = ttl;
        entry.timestamp = current_tick;
        entry.record_class = record_class & ~dns.MDNS_CACHE_FLUSH_BIT;
        @memcpy(entry.data[0..data.len], data);
        entry.data_len = data.len;
        entry.state = .valid;
        return;
    }

    // Find or allocate new entry
    const entry = try findFreeEntryLocked();

    // Initialize entry
    @memcpy(entry.name[0..name.len], name);
    entry.name_len = name.len;
    entry.record_type = record_type;
    entry.record_class = record_class & ~dns.MDNS_CACHE_FLUSH_BIT;
    entry.original_ttl = ttl;
    entry.timestamp = current_tick;
    @memcpy(entry.data[0..data.len], data);
    entry.data_len = data.len;
    entry.state = .valid;
    entry.hash_next = null;

    hashTableInsert(entry);
}

/// Periodic tick handler - expire old entries and update stale states
pub fn tick() void {
    current_tick +%= 1;

    // Only run cleanup every ~100 ticks (1 second at 100Hz)
    if (current_tick % 100 != 0) return;

    const held = cache_lock.acquire();
    defer held.release();

    for (cache_entries.items) |*entry| {
        if (entry.state == .free) continue;

        if (entry.isExpired(current_tick, ticks_per_second)) {
            hashTableRemove(entry);
            entry.state = .free;
        } else if (entry.state == .valid and entry.isStale(current_tick, ticks_per_second)) {
            entry.state = .stale;
        }
    }
}

/// Get count of valid entries in cache
pub fn getCount() usize {
    const held = cache_lock.acquire();
    defer held.release();

    var count: usize = 0;
    for (cache_entries.items) |entry| {
        if (entry.state != .free) {
            count += 1;
        }
    }
    return count;
}

/// Clear all entries from cache
pub fn clear() void {
    const held = cache_lock.acquire();
    defer held.release();

    for (cache_entries.items) |*entry| {
        entry.state = .free;
    }
    cache_entries.clearRetainingCapacity();

    for (&hash_table) |*bucket| {
        bucket.* = null;
    }
}
