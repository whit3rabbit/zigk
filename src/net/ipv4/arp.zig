// ARP Protocol Implementation
//
// RFC 826: Ethernet Address Resolution Protocol
//
// Maintains an ARP cache for IP-to-MAC resolution.
// Handles ARP requests/replies for local addresses.

const packet = @import("../core/packet.zig");
const interface = @import("../core/interface.zig");
const ethernet = @import("../ethernet/ethernet.zig");
const PacketBuffer = packet.PacketBuffer;
const ArpHeader = packet.ArpHeader;
const EthernetHeader = packet.EthernetHeader;
const Interface = interface.Interface;

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
    ip_addr: u32,
    mac_addr: [6]u8,
    state: ArpState,
    /// Timestamp for timeout (in ticks or seconds)
    timestamp: u64,
    /// Retry count for incomplete entries
    retries: u8,
};

/// Maximum ARP cache entries
const ARP_CACHE_SIZE: usize = 64;

/// ARP cache timeout in seconds (simplified - 20 minutes)
const ARP_TIMEOUT: u64 = 1200;

/// Max retries for incomplete entries
const ARP_MAX_RETRIES: u8 = 3;

/// Global ARP cache
/// In a real implementation, this would be per-interface
var arp_cache: [ARP_CACHE_SIZE]ArpEntry = [_]ArpEntry{.{
    .ip_addr = 0,
    .mac_addr = .{ 0, 0, 0, 0, 0, 0 },
    .state = .free,
    .timestamp = 0,
    .retries = 0,
}} ** ARP_CACHE_SIZE;

/// Simple tick counter for timestamps (incremented by timer)
var current_tick: u64 = 0;

/// Increment tick counter (call from timer interrupt)
pub fn tick() void {
    current_tick +%= 1;
}

/// Process an incoming ARP packet
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    // Validate ARP packet size
    const arp_offset = packet.ETH_HEADER_SIZE;
    if (pkt.len < arp_offset + @sizeOf(ArpHeader)) {
        return false;
    }

    // Get ARP header
    const arp: *ArpHeader = @ptrCast(@alignCast(pkt.data + arp_offset));

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
        updateCache(sender_ip, arp.sender_mac, .reachable);
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
            // Could wake any threads waiting for this resolution
            return true;
        },
        else => {},
    }

    return false;
}

/// Send an ARP reply
fn sendReply(iface: *Interface, target_mac: [6]u8, target_ip: u32) void {
    // Use a static buffer for the reply
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

    // Our MAC and IP as sender
    @memcpy(&arp.sender_mac, &iface.mac_addr);
    arp.sender_ip = @byteSwap(iface.ip_addr);

    // Target info
    @memcpy(&arp.target_mac, &target_mac);
    arp.target_ip = @byteSwap(target_ip);

    // Transmit
    _ = iface.transmit(&buf);
}

/// Send an ARP request
pub fn sendRequest(iface: *Interface, target_ip: u32) void {
    var buf: [packet.ETH_HEADER_SIZE + @sizeOf(ArpHeader)]u8 = undefined;

    // Build Ethernet header - broadcast
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &ethernet.BROADCAST_MAC);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_ARP);

    // Build ARP request
    const arp: *ArpHeader = @ptrCast(@alignCast(&buf[packet.ETH_HEADER_SIZE]));
    arp.hw_type = @byteSwap(@as(u16, 1)); // Ethernet
    arp.proto_type = @byteSwap(@as(u16, 0x0800)); // IPv4
    arp.hw_len = 6;
    arp.proto_len = 4;
    arp.operation = ArpHeader.OP_REQUEST;

    // Our MAC and IP as sender
    @memcpy(&arp.sender_mac, &iface.mac_addr);
    arp.sender_ip = @byteSwap(iface.ip_addr);

    // Target MAC is zero (unknown), target IP is what we want to resolve
    @memcpy(&arp.target_mac, &[_]u8{ 0, 0, 0, 0, 0, 0 });
    arp.target_ip = @byteSwap(target_ip);

    // Transmit
    _ = iface.transmit(&buf);
}

/// Resolve IP to MAC address
/// Returns MAC if cached, null if not found
pub fn resolve(ip: u32) ?[6]u8 {
    for (&arp_cache) |*entry| {
        if (entry.state != .free and entry.ip_addr == ip) {
            if (entry.state == .reachable or entry.state == .stale) {
                return entry.mac_addr;
            }
        }
    }
    return null;
}

/// Resolve IP to MAC, sending ARP request if not cached
/// Returns MAC if available immediately, null if ARP request was sent
pub fn resolveOrRequest(iface: *Interface, ip: u32) ?[6]u8 {
    // Check cache first
    if (resolve(ip)) |mac| {
        return mac;
    }

    // Not in cache - send ARP request
    // Check if we already have an incomplete entry
    for (&arp_cache) |*entry| {
        if (entry.ip_addr == ip and entry.state == .incomplete) {
            // Already waiting for this IP
            if (entry.retries < ARP_MAX_RETRIES) {
                entry.retries += 1;
                sendRequest(iface, ip);
            }
            return null;
        }
    }

    // Create incomplete entry
    if (findFreeEntry()) |entry| {
        entry.ip_addr = ip;
        entry.state = .incomplete;
        entry.timestamp = current_tick;
        entry.retries = 1;
        sendRequest(iface, ip);
    }

    return null;
}

/// Update or add an entry to the ARP cache
fn updateCache(ip: u32, mac: [6]u8, state: ArpState) void {
    // Look for existing entry
    for (&arp_cache) |*entry| {
        if (entry.ip_addr == ip) {
            @memcpy(&entry.mac_addr, &mac);
            entry.state = state;
            entry.timestamp = current_tick;
            entry.retries = 0;
            return;
        }
    }

    // No existing entry - find free slot
    if (findFreeEntry()) |entry| {
        entry.ip_addr = ip;
        @memcpy(&entry.mac_addr, &mac);
        entry.state = state;
        entry.timestamp = current_tick;
        entry.retries = 0;
    }
}

/// Find a free or stale entry in the cache
fn findFreeEntry() ?*ArpEntry {
    // First pass: look for free entry
    for (&arp_cache) |*entry| {
        if (entry.state == .free) {
            return entry;
        }
    }

    // Second pass: look for oldest stale entry
    var oldest: ?*ArpEntry = null;
    var oldest_time: u64 = current_tick;

    for (&arp_cache) |*entry| {
        if (entry.state == .stale and entry.timestamp < oldest_time) {
            oldest = entry;
            oldest_time = entry.timestamp;
        }
    }

    if (oldest) |entry| {
        return entry;
    }

    // Third pass: evict oldest reachable entry (LRU)
    for (&arp_cache) |*entry| {
        if (entry.timestamp < oldest_time) {
            oldest = entry;
            oldest_time = entry.timestamp;
        }
    }

    return oldest;
}

/// Age ARP cache entries (call periodically)
pub fn ageCache() void {
    for (&arp_cache) |*entry| {
        if (entry.state == .free) continue;

        const age = current_tick -% entry.timestamp;

        switch (entry.state) {
            .incomplete => {
                // Timeout incomplete entries quickly
                if (age > 10) {
                    entry.state = .free;
                }
            },
            .reachable => {
                // Move to stale after timeout
                if (age > ARP_TIMEOUT) {
                    entry.state = .stale;
                }
            },
            .stale => {
                // Eventually expire stale entries
                if (age > ARP_TIMEOUT * 2) {
                    entry.state = .free;
                }
            },
            .free => {},
        }
    }
}

/// Clear the ARP cache (for testing or interface down)
pub fn clearCache() void {
    for (&arp_cache) |*entry| {
        entry.state = .free;
    }
}

/// Get cache entry count (for debugging)
pub fn getCacheCount() usize {
    var count: usize = 0;
    for (&arp_cache) |*entry| {
        if (entry.state != .free) {
            count += 1;
        }
    }
    return count;
}
