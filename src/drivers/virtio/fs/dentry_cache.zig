// VirtIO-FS Dentry Cache
//
// TTL-based cache for directory entry lookups (parent_nodeid, name) -> child_nodeid.
// Caches both positive entries (found files) and negative entries (ENOENT results).
//
// Design:
// - Hash table keyed by (parent_nodeid, name_hash) for fast lookup
// - Stores full name for collision resolution
// - Negative entries cache ENOENT to avoid repeated lookups for missing files
// - TTL-based invalidation from FUSE entry_valid response

const std = @import("std");
const hal = @import("hal");
const sync = @import("sync");
const config = @import("config.zig");

// ============================================================================
// Constants
// ============================================================================

/// Number of hash buckets
const HASH_BUCKETS: usize = 512;

/// Maximum entries per bucket
const MAX_CHAIN_LENGTH: usize = 4;

/// Maximum name length to cache
const MAX_NAME_LEN: usize = 128;

// ============================================================================
// Dentry Cache Entry
// ============================================================================

/// Cached directory entry
pub const DentryEntry = struct {
    /// Parent directory node ID
    parent_nodeid: u64,
    /// Child node ID (0 for negative entry)
    nodeid: u64,
    /// Child generation number
    generation: u64,
    /// Name hash for quick comparison
    name_hash: u64,
    /// Expiration time (nanoseconds since boot)
    expire_ns: u64,
    /// Entry is valid
    valid: bool,
    /// Name length
    name_len: u8,
    /// Name (truncated if too long)
    name: [MAX_NAME_LEN]u8,

    const Self = @This();

    pub fn init() Self {
        return .{
            .parent_nodeid = 0,
            .nodeid = 0,
            .generation = 0,
            .name_hash = 0,
            .expire_ns = 0,
            .valid = false,
            .name_len = 0,
            .name = undefined,
        };
    }

    pub fn isExpired(self: *const Self) bool {
        if (!self.valid) return true;
        const now = hal.timing.getNanoseconds();
        return now >= self.expire_ns;
    }

    pub fn isNegative(self: *const Self) bool {
        return self.valid and self.nodeid == 0;
    }

    pub fn getName(self: *const Self) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn matches(self: *const Self, parent: u64, name: []const u8, name_hsh: u64) bool {
        if (!self.valid) return false;
        if (self.parent_nodeid != parent) return false;
        if (self.name_hash != name_hsh) return false;
        if (self.name_len != name.len) return false;
        return std.mem.eql(u8, self.getName(), name);
    }
};

// ============================================================================
// Hash Functions
// ============================================================================

/// FNV-1a hash for name
fn hashName(name: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV offset basis
    for (name) |c| {
        h ^= c;
        h *%= 0x100000001b3; // FNV prime
    }
    return h;
}

/// Combined hash for (parent, name)
fn hashKey(parent_nodeid: u64, name_hash: u64) usize {
    // Mix parent and name hash
    const combined = parent_nodeid ^ (name_hash *% 0x9e3779b97f4a7c15);
    return @intCast(combined % HASH_BUCKETS);
}

// ============================================================================
// Hash Bucket
// ============================================================================

const HashBucket = struct {
    entries: [MAX_CHAIN_LENGTH]DentryEntry,
    count: usize,

    const Self = @This();

    pub fn init() Self {
        var self = Self{
            .entries = undefined,
            .count = 0,
        };
        for (&self.entries) |*e| {
            e.* = DentryEntry.init();
        }
        return self;
    }

    pub fn find(self: *Self, parent: u64, name: []const u8, name_hsh: u64) ?*DentryEntry {
        for (&self.entries) |*entry| {
            if (entry.matches(parent, name, name_hsh)) {
                return entry;
            }
        }
        return null;
    }

    pub fn findOrAlloc(self: *Self, parent: u64, name: []const u8, name_hsh: u64) ?*DentryEntry {
        // Look for existing
        if (self.find(parent, name, name_hsh)) |entry| {
            return entry;
        }

        // Look for empty slot
        for (&self.entries) |*entry| {
            if (!entry.valid) {
                self.count += 1;
                return entry;
            }
        }

        // Look for expired slot
        for (&self.entries) |*entry| {
            if (entry.isExpired()) {
                return entry;
            }
        }

        // Evict oldest
        var oldest: ?*DentryEntry = null;
        var oldest_expire: u64 = std.math.maxInt(u64);

        for (&self.entries) |*entry| {
            if (entry.valid and entry.expire_ns < oldest_expire) {
                oldest = entry;
                oldest_expire = entry.expire_ns;
            }
        }

        return oldest;
    }

    pub fn remove(self: *Self, parent: u64, name: []const u8, name_hsh: u64) bool {
        for (&self.entries) |*entry| {
            if (entry.matches(parent, name, name_hsh)) {
                entry.valid = false;
                if (self.count > 0) self.count -= 1;
                return true;
            }
        }
        return false;
    }

    /// Remove all entries for a parent directory
    pub fn removeByParent(self: *Self, parent: u64) usize {
        var removed: usize = 0;
        for (&self.entries) |*entry| {
            if (entry.valid and entry.parent_nodeid == parent) {
                entry.valid = false;
                if (self.count > 0) self.count -= 1;
                removed += 1;
            }
        }
        return removed;
    }

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
// Dentry Cache
// ============================================================================

pub const DentryCache = struct {
    buckets: [HASH_BUCKETS]HashBucket,
    lock: sync.Spinlock,
    /// Statistics
    hits: u64,
    misses: u64,
    negative_hits: u64,
    inserts: u64,
    evictions: u64,

    const Self = @This();

    pub fn init() Self {
        var self = Self{
            .buckets = undefined,
            .lock = .{},
            .hits = 0,
            .misses = 0,
            .negative_hits = 0,
            .inserts = 0,
            .evictions = 0,
        };
        for (&self.buckets) |*b| {
            b.* = HashBucket.init();
        }
        return self;
    }

    /// Lookup a directory entry
    /// Returns cached entry if valid and not expired, null otherwise
    pub fn lookup(self: *Self, parent_nodeid: u64, name: []const u8) ?*const DentryEntry {
        const held = self.lock.acquire();
        defer held.release();

        const name_hsh = hashName(name);
        const bucket_idx = hashKey(parent_nodeid, name_hsh);
        const bucket = &self.buckets[bucket_idx];

        if (bucket.find(parent_nodeid, name, name_hsh)) |entry| {
            if (!entry.isExpired()) {
                if (entry.isNegative()) {
                    self.negative_hits += 1;
                } else {
                    self.hits += 1;
                }
                return entry;
            }
        }

        self.misses += 1;
        return null;
    }

    /// Insert a positive dentry entry
    pub fn insert(self: *Self, parent_nodeid: u64, name: []const u8, child_nodeid: u64, generation: u64, ttl_ns: u64) void {
        const held = self.lock.acquire();
        defer held.release();

        const name_hsh = hashName(name);
        const bucket_idx = hashKey(parent_nodeid, name_hsh);
        const bucket = &self.buckets[bucket_idx];

        const entry = bucket.findOrAlloc(parent_nodeid, name, name_hsh) orelse return;

        entry.parent_nodeid = parent_nodeid;
        entry.nodeid = child_nodeid;
        entry.generation = generation;
        entry.name_hash = name_hsh;
        entry.expire_ns = hal.timing.getNanoseconds() + ttl_ns;
        entry.valid = true;

        // Copy name (truncate if too long)
        const copy_len = @min(name.len, MAX_NAME_LEN);
        @memcpy(entry.name[0..copy_len], name[0..copy_len]);
        entry.name_len = @intCast(copy_len);

        self.inserts += 1;
    }

    /// Insert a negative dentry entry (for caching ENOENT)
    pub fn insertNegative(self: *Self, parent_nodeid: u64, name: []const u8, ttl_ns: u64) void {
        self.insert(parent_nodeid, name, 0, 0, ttl_ns);
    }

    /// Invalidate a specific dentry
    pub fn invalidate(self: *Self, parent_nodeid: u64, name: []const u8) void {
        const held = self.lock.acquire();
        defer held.release();

        const name_hsh = hashName(name);
        const bucket_idx = hashKey(parent_nodeid, name_hsh);

        if (self.buckets[bucket_idx].remove(parent_nodeid, name, name_hsh)) {
            self.evictions += 1;
        }
    }

    /// Invalidate all entries for a parent directory
    pub fn invalidateParent(self: *Self, parent_nodeid: u64) void {
        const held = self.lock.acquire();
        defer held.release();

        var evicted: usize = 0;
        for (&self.buckets) |*bucket| {
            evicted += bucket.removeByParent(parent_nodeid);
        }
        self.evictions += evicted;
    }

    /// Garbage collect expired entries
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
    pub fn getStats(self: *Self) struct {
        hits: u64,
        misses: u64,
        negative_hits: u64,
        inserts: u64,
        evictions: u64,
    } {
        const held = self.lock.acquire();
        defer held.release();

        return .{
            .hits = self.hits,
            .misses = self.misses,
            .negative_hits = self.negative_hits,
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
