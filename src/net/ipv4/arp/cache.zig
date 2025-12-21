const std = @import("std");
const packet = @import("../../core/packet.zig");
const interface = @import("../../core/interface.zig");
const ethernet = @import("../../ethernet/ethernet.zig");
const Interface = interface.Interface;
const EthernetHeader = packet.EthernetHeader;
const sync = @import("../../sync.zig");
const monitor = @import("monitor.zig");

/// ARP cache entry states
pub const ArpState = enum {
    /// Entry is free
    free,
    /// Request sent, awaiting reply
    incomplete,
    /// Valid entry, recently confirmed
    reachable,
    /// Entry is old, may need refresh
    stale,
};

/// ARP cache entry
pub const ArpEntry = struct {
    /// Small fixed-size queue to handle bursts
    pub const QUEUE_SIZE: usize = 4;

    ip_addr: u32,
    mac_addr: [6]u8,
    state: ArpState,
    /// Timestamp for timeout (in ticks or seconds)
    timestamp: u64,
    /// Retry count for incomplete entries
    retries: u8,
    /// Pending packet to send when resolved.
    pending_pkts: [QUEUE_SIZE]?[]u8,
    pending_lens: [QUEUE_SIZE]usize,
    queue_head: u8,
    queue_tail: u8,
    queue_count: u8,

    /// SECURITY: Track expected MAC from our ARP request to detect spoofing.
    expected_reply_mac: [6]u8,
    /// Whether we've received at least one reply (for validation)
    has_received_reply: bool,
    /// SECURITY: Conflict detection for ARP race attacks.
    conflict_detected: bool,
    /// Timestamp when conflict was first detected (for backoff)
    conflict_time: u64,
    /// SECURITY: Count of consecutive conflicts for exponential backoff.
    conflict_count: u8,

    /// SECURITY: Generation counter for TOCTOU detection.
    generation: u32,

    /// SECURITY: Static binding flag - entry cannot be overwritten by ARP.
    is_static: bool,

    /// Hash chain pointer for O(1) lookup by IP address
    hash_next: ?*ArpEntry,
};

/// ARP cache timeout in seconds
pub const ARP_TIMEOUT: u64 = 1200;
/// Max retries for incomplete entries
pub const ARP_MAX_RETRIES: u8 = 3;
/// Minimum interval between ARP cache updates for same IP (ticks)
pub const ARP_UPDATE_RATE_LIMIT: u64 = 100;
/// Maximum incomplete entries allowed (DoS protection).
pub const MAX_INCOMPLETE_ENTRIES: usize = 64;
/// Maximum ARP cache entries (DoS protection)
pub const MAX_ARP_ENTRIES: usize = 256;
/// Hash table size
pub const ARP_HASH_SIZE: usize = 512;

/// Global ARP cache list
pub var arp_cache: std.ArrayListUnmanaged(ArpEntry) = .{};
pub var arp_allocator: std.mem.Allocator = undefined;

/// SECURITY: Track count of incomplete entries for DoS protection.
pub var incomplete_entry_count: usize = 0;

/// Global ARP lock - IRQ-safe spinlock for concurrent access protection
pub var lock: sync.Spinlock = .{};

/// ARP hash table for O(1) lookup by IP address
pub var arp_hash_table: [ARP_HASH_SIZE]?*ArpEntry = [_]?*ArpEntry{null} ** ARP_HASH_SIZE;

/// Broadcast MAC address
pub const BROADCAST_MAC: [6]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
/// Zero MAC address
pub const ZERO_MAC: [6]u8 = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

/// Hash function for IP address
pub fn hashIp(ip: u32) usize {
    const golden_ratio: u32 = 0x9E3779B9;
    const hash = ip *% golden_ratio;
    return @as(usize, hash >> (32 - 9)) & (ARP_HASH_SIZE - 1);
}

/// Find entry by IP using O(1) hash table lookup (Caller must hold lock)
pub fn findEntry(ip: u32) ?*ArpEntry {
    const idx = hashIp(ip);
    var curr = arp_hash_table[idx];

    while (curr) |entry| {
        if (entry.state != .free and entry.ip_addr == ip) {
            return entry;
        }
        curr = entry.hash_next;
    }
    return null;
}

pub fn resetPending(entry: *ArpEntry) void {
    entry.pending_pkts = [_]?[]u8{null} ** ArpEntry.QUEUE_SIZE;
    entry.pending_lens = [_]usize{0} ** ArpEntry.QUEUE_SIZE;
    entry.queue_head = 0;
    entry.queue_tail = 0;
    entry.queue_count = 0;
    entry.expected_reply_mac = [_]u8{0} ** 6;
    entry.has_received_reply = false;
    entry.conflict_detected = false;
    entry.conflict_time = 0;
}

pub fn clearPending(entry: *ArpEntry) void {
    freePending(entry);
}

pub fn freePending(entry: *ArpEntry) void {
    for (&entry.pending_pkts, 0..) |*slot, idx| {
        if (slot.*) |buf| {
            arp_allocator.free(buf);
            slot.* = null;
        }
        entry.pending_lens[idx] = 0;
    }
    entry.queue_head = 0;
    entry.queue_tail = 0;
    entry.queue_count = 0;
}

/// Insert entry into hash table
pub fn hashTableInsert(entry: *ArpEntry) void {
    const idx = hashIp(entry.ip_addr);
    entry.hash_next = arp_hash_table[idx];
    arp_hash_table[idx] = entry;
}

/// Remove entry from hash table
pub fn hashTableRemove(entry: *ArpEntry) void {
    const idx = hashIp(entry.ip_addr);
    var prev: ?*ArpEntry = null;
    var curr = arp_hash_table[idx];

    while (curr) |c| {
        if (c == entry) {
            if (prev) |p| {
                p.hash_next = c.hash_next;
            } else {
                arp_hash_table[idx] = c.hash_next;
            }
            entry.hash_next = null;
            return;
        }
        prev = c;
        curr = c.hash_next;
    }
}

/// Get a slot for a new entry (reusing free/stale or LRU eviction)
pub fn findFreeEntry() !*ArpEntry {
    for (arp_cache.items) |*entry| {
        if (entry.state == .free) {
            clearPending(entry);
            return entry;
        }
    }

    var oldest_stale: ?*ArpEntry = null;
    var oldest_stale_time: u64 = monitor.current_tick;

    for (arp_cache.items) |*entry| {
        if (entry.state == .stale and !entry.is_static and entry.timestamp < oldest_stale_time) {
            oldest_stale = entry;
            oldest_stale_time = entry.timestamp;
        }
    }

    if (oldest_stale) |entry| {
        hashTableRemove(entry);
        clearPending(entry);
        return entry;
    }

    if (arp_cache.items.len >= MAX_ARP_ENTRIES) {
        var oldest_reachable: ?*ArpEntry = null;
        var oldest_reachable_time: u64 = monitor.current_tick;

        for (arp_cache.items) |*entry| {
            if (entry.state == .reachable and !entry.is_static and entry.timestamp < oldest_reachable_time) {
                oldest_reachable = entry;
                oldest_reachable_time = entry.timestamp;
            }
        }

        if (oldest_reachable) |entry| {
            hashTableRemove(entry);
            clearPending(entry);
            return entry;
        }

        var oldest_incomplete: ?*ArpEntry = null;
        var oldest_incomplete_time: u64 = monitor.current_tick;

        for (arp_cache.items) |*entry| {
            if (entry.state == .incomplete and entry.timestamp < oldest_incomplete_time) {
                oldest_incomplete = entry;
                oldest_incomplete_time = entry.timestamp;
            }
        }

        if (oldest_incomplete) |entry| {
            hashTableRemove(entry);
            clearPending(entry);
            return entry;
        }

        return error.OutOfMemory;
    }

    const new_entry = try arp_cache.addOne(arp_allocator);
    new_entry.* = std.mem.zeroes(ArpEntry);
    new_entry.state = .free;
    new_entry.hash_next = null;
    clearPending(new_entry);
    return new_entry;
}

/// Struct to hold packets for deferred transmission (outside lock)
pub const PendingPackets = struct {
    pkts: [ArpEntry.QUEUE_SIZE]?[]u8 = [_]?[]u8{null} ** ArpEntry.QUEUE_SIZE,
    lens: [ArpEntry.QUEUE_SIZE]usize = [_]usize{0} ** ArpEntry.QUEUE_SIZE,
    count: u8 = 0,

    /// Transmit all pending packets and free buffers
    pub fn transmitAndFree(self: *PendingPackets, iface: *Interface) void {
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const len = self.lens[i];
            if (self.pkts[i]) |buf| {
                if (len > 0 and len <= buf.len) {
                    // MAC and Type headers are set in updateCache before
                    // packets are moved to PendingPackets
                    _ = iface.transmit(buf[0..len]);
                }
                if (monitor.VERIFY_SYNC_TRANSMIT) {
                    @memset(buf, 0xDE);
                }
                arp_allocator.free(buf);
            }
        }
    }
};

/// Update or add an entry to the ARP cache
/// Returns PendingPackets that MUST be transmitted by caller AFTER releasing lock
pub fn updateCache(iface: *Interface, ip: u32, mac: [6]u8, state: ArpState) !PendingPackets {
    var pending = PendingPackets{};
    if (std.mem.eql(u8, &mac, &BROADCAST_MAC)) return pending;
    if (std.mem.eql(u8, &mac, &ZERO_MAC)) return pending;
    if ((mac[0] & 0x01) != 0) return pending;

    if (findEntry(ip)) |entry| {
        if (entry.is_static) {
            monitor.logSecurityEvent(.static_entry_protected, ip, entry.mac_addr, mac);
            return pending;
        }

        if (entry.state != .incomplete) {
            const time_since_update = monitor.current_tick -% entry.timestamp;
            if (time_since_update < ARP_UPDATE_RATE_LIMIT) return pending;
        }

        const was_incomplete = entry.state == .incomplete;

        @memcpy(&entry.mac_addr, &mac);
        entry.state = state;
        entry.timestamp = monitor.current_tick;
        entry.retries = 0;
        entry.conflict_count = 0;
        entry.generation +%= 1;

        if (was_incomplete and state == .reachable) {
            if (incomplete_entry_count > 0) incomplete_entry_count -= 1;
        }

        if (entry.queue_count > 0) {
            var i: u8 = 0;
            while (i < entry.queue_count) : (i += 1) {
                const idx = (entry.queue_head +% i) % @as(u8, @intCast(ArpEntry.QUEUE_SIZE));
                const len = entry.pending_lens[idx];
                if (entry.pending_pkts[idx]) |buf| {
                    if (len > 0 and len <= buf.len) {
                        const eth: *align(1) EthernetHeader = @ptrCast(buf.ptr);
                        @memcpy(&eth.dst_mac, &mac);
                        @memcpy(&eth.src_mac, &iface.mac_addr);
                        eth.setEthertype(ethernet.ETHERTYPE_IPV4);
                        
                        // Move to pending struct
                        pending.pkts[pending.count] = buf;
                        pending.lens[pending.count] = len;
                        pending.count += 1;
                    } else {
                         // Should not happen, but free if so
                         arp_allocator.free(buf);
                    }
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

    // Security: Do not create new entries for unsolicited packets.
    // Only update entries that are already tracked (e.g., pending request).
    return pending;
}

/// Initialize ARP subsystem
pub fn init(allocator: std.mem.Allocator, ticks_per_sec: u32) void {
    arp_allocator = allocator;
    arp_cache = .{};
    if (ticks_per_sec > 0 and ticks_per_sec <= 1_000_000) {
        monitor.ticks_per_second = ticks_per_sec;
    }
}

/// Clear the ARP cache
pub fn clearCache() void {
    const held = lock.acquire();
    defer held.release();

    for (arp_cache.items) |*entry| {
        clearPending(entry);
        entry.state = .free;
    }
    arp_cache.clearRetainingCapacity();

    for (&arp_hash_table) |*bucket| {
        bucket.* = null;
    }

    incomplete_entry_count = 0;
}

/// Get cache entry count
pub fn getCacheCount() usize {
    const held = lock.acquire();
    defer held.release();

    var count: usize = 0;
    for (arp_cache.items) |entry| {
        if (entry.state != .free) {
            count += 1;
        }
    }
    return count;
}

/// Add a static ARP entry
pub fn addStaticEntry(ip: u32, mac: [6]u8) !void {
    if (std.mem.eql(u8, &mac, &BROADCAST_MAC)) return error.InvalidAddress;
    if (std.mem.eql(u8, &mac, &ZERO_MAC)) return error.InvalidAddress;
    if ((mac[0] & 0x01) != 0) return error.InvalidAddress;

    const held = lock.acquire();
    defer held.release();

    for (arp_cache.items) |*entry| {
        if (entry.ip_addr == ip and entry.state != .free) {
            @memcpy(&entry.mac_addr, &mac);
            entry.state = .reachable;
            entry.is_static = true;
            entry.timestamp = monitor.current_tick;
            entry.generation +%= 1;
            return;
        }
    }

    const entry = try findFreeEntry();
    entry.ip_addr = ip;
    @memcpy(&entry.mac_addr, &mac);
    entry.state = .reachable;
    entry.timestamp = monitor.current_tick;
    entry.retries = 0;
    entry.queue_head = 0;
    entry.queue_tail = 0;
    entry.queue_count = 0;
    entry.expected_reply_mac = [_]u8{0} ** 6;
    entry.has_received_reply = false;
    entry.conflict_detected = false;
    entry.conflict_time = 0;
    entry.generation +%= 1;
    entry.is_static = true;
    entry.hash_next = null;
    hashTableInsert(entry);
}

/// Remove a static ARP entry
pub fn removeStaticEntry(ip: u32) bool {
    const held = lock.acquire();
    defer held.release();

    for (arp_cache.items) |*entry| {
        if (entry.ip_addr == ip and entry.is_static) {
            hashTableRemove(entry);
            clearPending(entry);
            entry.state = .free;
            entry.is_static = false;
            entry.generation +%= 1;
            return true;
        }
    }
    return false;
}

/// Check if an IP has a static ARP entry
pub fn isStaticEntry(ip: u32) bool {
    const held = lock.acquire();
    defer held.release();

    if (findEntry(ip)) |entry| {
        return entry.is_static;
    }
    return false;
}

/// Get count of static entries in the cache
pub fn getStaticCount() usize {
    const held = lock.acquire();
    defer held.release();

    var count: usize = 0;
    for (arp_cache.items) |entry| {
        if (entry.is_static and entry.state != .free) {
            count += 1;
        }
    }
    return count;
}
