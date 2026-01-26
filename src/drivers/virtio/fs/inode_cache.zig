// VirtIO-FS Inode Cache
//
// TTL-based cache for FUSE file attributes (nodeid -> FuseAttr).
// Reduces round-trips to virtiofsd for frequently accessed files.
//
// Design:
// - Fixed-size hash table with chaining for collision handling
// - Each entry has a TTL (time-to-live) from FUSE attr_valid response
// - Expired entries are lazily reclaimed during lookup/insert
// - No LRU eviction - TTL-based invalidation is sufficient for FUSE

const std = @import("std");
const hal = @import("hal");
const sync = @import("sync");
const config = @import("config.zig");
const protocol = @import("protocol.zig");

// ============================================================================
// Constants
// ============================================================================

/// Number of hash buckets (power of 2 for fast modulo)
const HASH_BUCKETS: usize = 256;

/// Maximum entries per bucket (prevent unbounded chaining)
const MAX_CHAIN_LENGTH: usize = 8;

// ============================================================================
// Inode Cache Entry
// ============================================================================

/// Cached inode information
pub const InodeEntry = struct {
    /// FUSE node ID (inode number)
    nodeid: u64,
    /// Generation number (for reuse detection)
    generation: u64,
    /// Cached file attributes
    attr: protocol.FuseAttr,
    /// Expiration time (nanoseconds since boot)
    expire_ns: u64,
    /// Number of lookups (for FORGET tracking)
    lookup_count: u64,
    /// Entry is valid
    valid: bool,

    const Self = @This();

    pub fn init() Self {
        return .{
            .nodeid = 0,
            .generation = 0,
            .attr = std.mem.zeroes(protocol.FuseAttr),
            .expire_ns = 0,
            .lookup_count = 0,
            .valid = false,
        };
    }

    pub fn isExpired(self: *const Self) bool {
        if (!self.valid) return true;
        const now = hal.timing.getNanoseconds();
        return now >= self.expire_ns;
    }
};

// ============================================================================
// Hash Bucket
// ============================================================================

/// Single hash bucket with fixed-size entry array
const HashBucket = struct {
    entries: [MAX_CHAIN_LENGTH]InodeEntry,
    count: usize,

    const Self = @This();

    pub fn init() Self {
        var self = Self{
            .entries = undefined,
            .count = 0,
        };
        for (&self.entries) |*e| {
            e.* = InodeEntry.init();
        }
        return self;
    }

    /// Find entry by nodeid
    pub fn find(self: *Self, nodeid: u64) ?*InodeEntry {
        for (&self.entries) |*entry| {
            if (entry.valid and entry.nodeid == nodeid) {
                return entry;
            }
        }
        return null;
    }

    /// Find or allocate a slot for nodeid
    pub fn findOrAlloc(self: *Self, nodeid: u64) ?*InodeEntry {
        // First, look for existing entry
        for (&self.entries) |*entry| {
            if (entry.valid and entry.nodeid == nodeid) {
                return entry;
            }
        }

        // Look for empty slot
        for (&self.entries) |*entry| {
            if (!entry.valid) {
                self.count += 1;
                return entry;
            }
        }

        // Look for expired slot to reclaim
        for (&self.entries) |*entry| {
            if (entry.isExpired()) {
                return entry;
            }
        }

        // Bucket full, no expired entries - evict oldest
        var oldest: ?*InodeEntry = null;
        var oldest_expire: u64 = std.math.maxInt(u64);

        for (&self.entries) |*entry| {
            if (entry.valid and entry.expire_ns < oldest_expire) {
                oldest = entry;
                oldest_expire = entry.expire_ns;
            }
        }

        return oldest;
    }

    /// Remove entry by nodeid
    pub fn remove(self: *Self, nodeid: u64) bool {
        for (&self.entries) |*entry| {
            if (entry.valid and entry.nodeid == nodeid) {
                entry.valid = false;
                if (self.count > 0) self.count -= 1;
                return true;
            }
        }
        return false;
    }

    /// Garbage collect expired entries
    pub fn gc(self: *Self) usize {
        var reclaimed: usize = 0;
        for (&self.entries) |*entry| {
            if (entry.valid and entry.isExpired()) {
                entry.valid = false;
                if (self.count > 0) self.count -= 1;
                reclaimed += 1;
            }
        }
        return reclaimed;
    }
};

// ============================================================================
// Inode Cache
// ============================================================================

/// TTL-based inode cache
pub const InodeCache = struct {
    buckets: [HASH_BUCKETS]HashBucket,
    lock: sync.Spinlock,
    /// Statistics
    hits: u64,
    misses: u64,
    inserts: u64,
    evictions: u64,

    const Self = @This();

    pub fn init() Self {
        var self = Self{
            .buckets = undefined,
            .lock = .{},
            .hits = 0,
            .misses = 0,
            .inserts = 0,
            .evictions = 0,
        };
        for (&self.buckets) |*b| {
            b.* = HashBucket.init();
        }
        return self;
    }

    /// Hash function for nodeid
    fn hash(nodeid: u64) usize {
        // Simple hash - nodeid is already well-distributed in FUSE
        return @intCast(nodeid % HASH_BUCKETS);
    }

    /// Lookup an inode by nodeid
    /// Returns cached entry if valid and not expired, null otherwise
    pub fn lookup(self: *Self, nodeid: u64) ?*const InodeEntry {
        const held = self.lock.acquire();
        defer held.release();

        const bucket_idx = hash(nodeid);
        const bucket = &self.buckets[bucket_idx];

        if (bucket.find(nodeid)) |entry| {
            if (!entry.isExpired()) {
                self.hits += 1;
                return entry;
            }
            // Expired - will be reclaimed lazily
        }

        self.misses += 1;
        return null;
    }

    /// Insert or update an inode entry
    pub fn insert(self: *Self, nodeid: u64, generation: u64, attr: protocol.FuseAttr, ttl_ns: u64) void {
        const held = self.lock.acquire();
        defer held.release();

        const bucket_idx = hash(nodeid);
        const bucket = &self.buckets[bucket_idx];

        const entry = bucket.findOrAlloc(nodeid) orelse {
            // Shouldn't happen with eviction, but be safe
            return;
        };

        const was_valid = entry.valid and entry.nodeid == nodeid;

        entry.nodeid = nodeid;
        entry.generation = generation;
        entry.attr = attr;
        entry.expire_ns = hal.timing.getNanoseconds() + ttl_ns;
        entry.valid = true;

        if (!was_valid) {
            entry.lookup_count = 1;
            self.inserts += 1;
        } else {
            entry.lookup_count += 1;
        }
    }

    /// Update only the attributes for an existing entry
    pub fn updateAttr(self: *Self, nodeid: u64, attr: protocol.FuseAttr, ttl_ns: u64) void {
        const held = self.lock.acquire();
        defer held.release();

        const bucket_idx = hash(nodeid);
        const bucket = &self.buckets[bucket_idx];

        if (bucket.find(nodeid)) |entry| {
            entry.attr = attr;
            entry.expire_ns = hal.timing.getNanoseconds() + ttl_ns;
        }
    }

    /// Invalidate a specific inode
    pub fn invalidate(self: *Self, nodeid: u64) void {
        const held = self.lock.acquire();
        defer held.release();

        const bucket_idx = hash(nodeid);
        const bucket = &self.buckets[bucket_idx];

        if (bucket.find(nodeid)) |entry| {
            entry.valid = false;
            self.evictions += 1;
        }
    }

    /// Decrement lookup count for an inode
    /// Returns the new lookup count (0 means ready for FORGET)
    pub fn decrementLookup(self: *Self, nodeid: u64) u64 {
        const held = self.lock.acquire();
        defer held.release();

        const bucket_idx = hash(nodeid);
        const bucket = &self.buckets[bucket_idx];

        if (bucket.find(nodeid)) |entry| {
            if (entry.lookup_count > 0) {
                entry.lookup_count -= 1;
            }
            return entry.lookup_count;
        }
        return 0;
    }

    /// Get lookup count for an inode
    pub fn getLookupCount(self: *Self, nodeid: u64) u64 {
        const held = self.lock.acquire();
        defer held.release();

        const bucket_idx = hash(nodeid);
        const bucket = &self.buckets[bucket_idx];

        if (bucket.find(nodeid)) |entry| {
            return entry.lookup_count;
        }
        return 0;
    }

    /// Remove an inode completely
    pub fn remove(self: *Self, nodeid: u64) bool {
        const held = self.lock.acquire();
        defer held.release();

        const bucket_idx = hash(nodeid);
        return self.buckets[bucket_idx].remove(nodeid);
    }

    /// Garbage collect expired entries across all buckets
    pub fn garbageCollect(self: *Self) usize {
        const held = self.lock.acquire();
        defer held.release();

        var total: usize = 0;
        for (&self.buckets) |*bucket| {
            total += bucket.gc();
        }
        self.evictions += total;
        return total;
    }

    /// Get cache statistics
    pub fn getStats(self: *Self) struct { hits: u64, misses: u64, inserts: u64, evictions: u64 } {
        const held = self.lock.acquire();
        defer held.release();

        return .{
            .hits = self.hits,
            .misses = self.misses,
            .inserts = self.inserts,
            .evictions = self.evictions,
        };
    }

    /// Get number of valid entries
    pub fn count(self: *Self) usize {
        const held = self.lock.acquire();
        defer held.release();

        var total: usize = 0;
        for (&self.buckets) |*bucket| {
            total += bucket.count;
        }
        return total;
    }
};
