// ARP Protocol Implementation
//
// Complies with:
// - RFC 826: Ethernet Address Resolution Protocol
//
// Maintains an ARP cache for IP-to-MAC resolution.
// Handles ARP requests/replies for local addresses.
//
// Packet Format:
// +-----------+-----------+---------+---------+-----------+
// | HW Type(2)| Pro Type(2)| HW Len(1)| Pro Len(1)| Op(2) |
// +-----------+-----------+---------+---------+-----------+
// | Sender HA (6) | Sender IP (4) | Target HA (6) | Target IP (4) |
// +-------------------------------------------------------+

const std = @import("std");
const packet = @import("../core/packet.zig");
const interface = @import("../core/interface.zig");
const ethernet = @import("../ethernet/ethernet.zig");
const PacketBuffer = packet.PacketBuffer;
const ArpHeader = packet.ArpHeader;
const EthernetHeader = packet.EthernetHeader;
const Interface = interface.Interface;
const sync = @import("../sync.zig");

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
    /// WARNING: Only stores ONE packet per incomplete entry (MVP limitation).
    /// Multiple packets sent to an unresolved IP will cause earlier packets
    /// to be silently dropped. For production use, implement a proper queue.
    pending_pkts: [QUEUE_SIZE][packet.MAX_PACKET_SIZE]u8,
    pending_lens: [QUEUE_SIZE]usize,
    queue_head: u8,
    queue_tail: u8,
    queue_count: u8,
};

/// ARP cache timeout in seconds (simplified - 20 minutes)
const ARP_TIMEOUT: u64 = 1200;

/// Max retries for incomplete entries
const ARP_MAX_RETRIES: u8 = 3;

/// Global ARP cache list
var arp_cache: std.ArrayListUnmanaged(ArpEntry) = .{};
var arp_allocator: std.mem.Allocator = undefined;

/// Simple tick counter for timers
var current_tick: u64 = 0;

/// Increment tick counter (call from timer interrupt)
pub fn tick() void {
    current_tick +%= 1;
}

/// Global ARP lock
var lock: sync.Lock = sync.noop_lock;

/// Set the lock implementation
pub fn setLock(l: sync.Lock) void {
    lock = l;
}

/// Initialize ARP subsystem
pub fn init(allocator: std.mem.Allocator) void {
    arp_allocator = allocator;
    arp_cache = .{};
}

/// Process an incoming ARP packet
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    lock.acquire();
    defer lock.release();

    // Validate ARP packet size
    const arp_offset = packet.ETH_HEADER_SIZE;
    if (pkt.len < arp_offset + @sizeOf(ArpHeader)) {
        return false;
    }

    // Get ARP header
    const arp: *ArpHeader = @ptrCast(@alignCast(&pkt.data[arp_offset]));

    // Validate hardware type (1 = Ethernet)
    if (@byteSwap(arp.hw_type) != 1) {
        return false;
    }

    // Validate protocol type (0x0800 = IPv4)
    if (@byteSwap(arp.proto_type) != 0x0800) {
        return false;
    }

    // Validate lengths
    if (arp.hw_len != 6 or arp.proto_len != 4) {
        return false;
    }

    const operation = arp.getOperation();
    const sender_ip = arp.getSenderIp();
    const target_ip = arp.getTargetIp();

    // Learn sender's MAC address (ARP snooping)
    // Only if sender IP is on our subnet
    if (iface.isLocalSubnet(sender_ip)) {
        // Cache update failure is non-fatal - peer may still be reachable via
        // explicit ARP request. Silently ignore to avoid log spam in high-traffic scenarios.
        updateCache(iface, sender_ip, arp.sender_mac, .reachable) catch {};
    }

    switch (operation) {
        1 => {
            // ARP Request - check if target is our IP
            if (target_ip == iface.ip_addr) {
                sendReply(iface, arp.sender_mac, sender_ip);
                return true;
            }
        },
        2 => {
            // ARP Reply - cache already updated above
            return true;
        },
        else => {},
    }

    return false;
}

/// Send an ARP reply
fn sendReply(iface: *Interface, target_mac: [6]u8, target_ip: u32) void {
    var buf: [packet.ETH_HEADER_SIZE + @sizeOf(ArpHeader)]u8 = undefined;

    // Build Ethernet header
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &target_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_ARP);

    // Build ARP reply
    const arp: *ArpHeader = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    arp.hw_type = @byteSwap(@as(u16, 1)); // Ethernet
    arp.proto_type = @byteSwap(@as(u16, 0x0800)); // IPv4
    arp.hw_len = 6;
    arp.proto_len = 4;
    arp.operation = ArpHeader.OP_REPLY;

    @memcpy(&arp.sender_mac, &iface.mac_addr);
    arp.sender_ip = @byteSwap(iface.ip_addr);

    @memcpy(&arp.target_mac, &target_mac);
    arp.target_ip = @byteSwap(target_ip);

    _ = iface.transmit(&buf);
}

/// Send an ARP request
pub fn sendRequest(iface: *Interface, target_ip: u32) void {
    var buf: [packet.ETH_HEADER_SIZE + @sizeOf(ArpHeader)]u8 = undefined;

    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &ethernet.BROADCAST_MAC);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_ARP);

    const arp: *ArpHeader = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    arp.hw_type = @byteSwap(@as(u16, 1));
    arp.proto_type = @byteSwap(@as(u16, 0x0800));
    arp.hw_len = 6;
    arp.proto_len = 4;
    arp.operation = ArpHeader.OP_REQUEST;

    @memcpy(&arp.sender_mac, &iface.mac_addr);
    arp.sender_ip = @byteSwap(iface.ip_addr);

    @memcpy(&arp.target_mac, &[_]u8{ 0, 0, 0, 0, 0, 0 });
    arp.target_ip = @byteSwap(target_ip);

    _ = iface.transmit(&buf);
}

/// Resolve IP to MAC address
pub fn resolve(ip: u32) ?[6]u8 {
    for (arp_cache.items) |entry| {
        if (entry.state != .free and entry.ip_addr == ip) {
            if (entry.state == .reachable or entry.state == .stale) {
                return entry.mac_addr;
            }
        }
    }
    return null;
}

/// Resolve IP to MAC, sending ARP request if not cached
pub fn resolveOrRequest(iface: *Interface, ip: u32, pkt_opaque: ?*const anyopaque) ?[6]u8 {
    const pkt: ?*const PacketBuffer = if (pkt_opaque) |p| @ptrCast(@alignCast(p)) else null;

    lock.acquire();
    defer lock.release();

    if (resolve(ip)) |mac| {
        return mac;
    }

    // Check if we already have an incomplete entry
    for (arp_cache.items) |*entry| {
        if (entry.ip_addr == ip and entry.state == .incomplete) {
            if (pkt) |p| {
                if (p.len <= packet.MAX_PACKET_SIZE and entry.queue_count < ArpEntry.QUEUE_SIZE) {
                    // Enqueue packet
                    @memcpy(entry.pending_pkts[entry.queue_tail][0..p.len], p.data[0..p.len]);
                    entry.pending_lens[entry.queue_tail] = p.len;
                    entry.queue_tail = (entry.queue_tail + 1) % @as(u8, @intCast(ArpEntry.QUEUE_SIZE));
                    entry.queue_count += 1;
                }
            }

            if (entry.retries < ARP_MAX_RETRIES) {
                entry.retries += 1;
                sendRequest(iface, ip);
            }
            return null;
        }
    }

    // Create incomplete entry
    if (findFreeEntry() catch null) |entry| {
        entry.ip_addr = ip;
        entry.state = .incomplete;
        entry.timestamp = current_tick;
        entry.retries = 1;
        entry.queue_head = 0;
        entry.queue_tail = 0;
        entry.queue_count = 0;

        if (pkt) |p| {
             if (p.len <= packet.MAX_PACKET_SIZE) {
                @memcpy(entry.pending_pkts[entry.queue_tail][0..p.len], p.data[0..p.len]);
                entry.pending_lens[entry.queue_tail] = p.len;
                entry.queue_tail = 1; // (0 + 1) % QUEUE_SIZE
                entry.queue_count = 1;
            }
        }

        sendRequest(iface, ip);
    }

    return null;
}

/// Update or add an entry to the ARP cache
fn updateCache(iface: *Interface, ip: u32, mac: [6]u8, state: ArpState) !void {
    // Look for existing entry
    for (arp_cache.items) |*entry| {
        if (entry.ip_addr == ip) {
            @memcpy(&entry.mac_addr, &mac);
            entry.state = state;
            entry.timestamp = current_tick;
            entry.retries = 0;

            if (entry.queue_count > 0) {
                // Flush pending packets
                var i: u8 = 0;
                while (i < entry.queue_count) : (i += 1) {
                    const idx = (entry.queue_head +% i) % @as(u8, @intCast(ArpEntry.QUEUE_SIZE));
                    const len = entry.pending_lens[idx];
                    
                    if (len > 0) {
                        const eth: *EthernetHeader = @ptrCast(@alignCast(&entry.pending_pkts[idx]));
                        @memcpy(&eth.dst_mac, &mac);
                        @memcpy(&eth.src_mac, &iface.mac_addr);
                        eth.setEthertype(ethernet.ETHERTYPE_IPV4);
                        
                        _ = iface.transmit(entry.pending_pkts[idx][0..len]);
                    }
                }
                // Clear queue
                entry.queue_count = 0;
                entry.queue_head = 0;
                entry.queue_tail = 0;
            }
            return;
        }
    }

    // No existing entry - find free slot or append
    const entry = try findFreeEntry();
    entry.ip_addr = ip;
    @memcpy(&entry.mac_addr, &mac);
    entry.state = state;
    entry.timestamp = current_tick;
    entry.retries = 0;
    entry.queue_head = 0;
    entry.queue_tail = 0;
    entry.queue_count = 0;
}

/// Maximum ARP cache entries (DoS protection)
const MAX_ARP_ENTRIES: usize = 256;

/// Get a slot for a new entry (reusing free/stale or LRU eviction)
fn findFreeEntry() !*ArpEntry {
    // First pass: look for free entry
    for (arp_cache.items) |*entry| {
        if (entry.state == .free) {
            return entry;
        }
    }

    // Second pass: look for oldest stale entry to recycle
    var oldest_stale: ?*ArpEntry = null;
    var oldest_stale_time: u64 = current_tick;

    for (arp_cache.items) |*entry| {
        if (entry.state == .stale and entry.timestamp < oldest_stale_time) {
            oldest_stale = entry;
            oldest_stale_time = entry.timestamp;
        }
    }

    if (oldest_stale) |entry| {
        return entry;
    }

    // Check if at capacity - must evict via LRU
    if (arp_cache.items.len >= MAX_ARP_ENTRIES) {
        // Third pass: evict oldest reachable (LRU)
        var oldest_reachable: ?*ArpEntry = null;
        var oldest_reachable_time: u64 = current_tick;

        for (arp_cache.items) |*entry| {
            if (entry.state == .reachable and entry.timestamp < oldest_reachable_time) {
                oldest_reachable = entry;
                oldest_reachable_time = entry.timestamp;
            }
        }

        if (oldest_reachable) |entry| {
            return entry;
        }

        // Fourth pass: evict oldest incomplete entry
        var oldest_incomplete: ?*ArpEntry = null;
        var oldest_incomplete_time: u64 = current_tick;

        for (arp_cache.items) |*entry| {
            if (entry.state == .incomplete and entry.timestamp < oldest_incomplete_time) {
                oldest_incomplete = entry;
                oldest_incomplete_time = entry.timestamp;
            }
        }

        if (oldest_incomplete) |entry| {
            return entry;
        }

        // Cache full with no evictable entries (should not happen)
        return error.OutOfMemory;
    }

    // Under capacity: append new entry
    const new_entry = try arp_cache.addOne(arp_allocator);
    new_entry.state = .free;
    return new_entry;
}

/// Age ARP cache entries
pub fn ageCache() void {
    lock.acquire();
    defer lock.release();
    var i: usize = 0;
    while (i < arp_cache.items.len) {
        var entry = &arp_cache.items[i];
        if (entry.state == .free) {
            i += 1;
            continue;
        }

        const age = current_tick -% entry.timestamp;

        switch (entry.state) {
            .incomplete => {
                if (age > 10) {
                    entry.state = .free;
                }
            },
            .reachable => {
                if (age > ARP_TIMEOUT) {
                    entry.state = .stale;
                }
            },
            .stale => {
                if (age > ARP_TIMEOUT * 2) {
                    entry.state = .free;
                }
            },
            .free => {},
        }
        i += 1;
    }
}

/// Clear the ARP cache
pub fn clearCache() void {
    arp_cache.clearRetainingCapacity();
}

/// Get cache entry count
pub fn getCacheCount() usize {
    var count: usize = 0;
    for (arp_cache.items) |entry| {
        if (entry.state != .free) {
            count += 1;
        }
    }
    return count;
}
