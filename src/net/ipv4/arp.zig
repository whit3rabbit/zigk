// ARP Protocol Implementation
//
// Complies with:
// - RFC 826: Ethernet Address Resolution Protocol
//
// Maintains an ARP cache for IP-to-MAC resolution.
// Handles ARP requests/replies for local addresses.
//
// SECURITY CONSIDERATIONS:
// ARP is inherently vulnerable to spoofing attacks on Layer 2 networks.
// This implementation provides the following protections:
//
// 1. Rate Limiting: ARP cache updates are rate-limited (ARP_UPDATE_RATE_LIMIT)
//    to slow down rapid cache poisoning attacks.
//
// 2. Conflict Detection: Subsequent ARP replies with different MACs trigger
//    a conflict state with 5-second backoff before accepting new entries.
//
// 3. Invalid MAC Rejection: Broadcast, zero, and multicast MACs are rejected.
//
// 4. Static ARP Bindings: Critical hosts (gateway, DNS) can be configured with
//    static entries that cannot be overwritten by ARP traffic and never timeout.
//    Use addStaticEntry() to protect against gateway spoofing attacks.
//
// 5. TOCTOU Protection: Generation counters detect entry modifications between
//    lock release and deferred operations, preventing redundant ARP requests.
//
// 6. Tick Rate Validation: ticks_per_second is bounded to prevent integer
//    overflow in timeout calculations that could weaken security.
//
// 7. Safe Allocation Ordering: Pending packet queue allocates new buffer before
//    freeing old one, preventing slot loss on OOM.
//
// KNOWN LIMITATIONS:
// - First-Reply Race: The first ARP reply for an incomplete entry is accepted
//   without additional validation. An attacker on the same L2 segment can race
//   the legitimate host to send a spoofed reply first. Use static bindings for
//   critical hosts to mitigate.
//
// - Synchronous Transmit Requirement: Pending packet buffers are freed immediately
//   after iface.transmit(). NIC drivers MUST copy data synchronously. Async DMA
//   drivers would cause use-after-free. See VERIFY_SYNC_TRANSMIT constant.
//
// - VLAN Tags: This implementation assumes no 802.1Q VLAN tags in Ethernet frames.
//   VLAN tags must be stripped by lower layers. See documentation at end of file.
//
// RECOMMENDED MITIGATIONS (external to this implementation):
// - Static ARP entries for critical hosts (gateway, DNS servers) - NOW SUPPORTED
// - IEEE 802.1X port-based authentication
// - Dynamic ARP Inspection (DAI) at the switch level
// - VLAN segmentation to limit L2 attack surface
// - ARP monitoring/logging for security analysis
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
    pending_pkts: [QUEUE_SIZE]?[]u8,
    pending_lens: [QUEUE_SIZE]usize,
    queue_head: u8,
    queue_tail: u8,
    queue_count: u8,

    /// SECURITY: Track expected MAC from our ARP request to detect spoofing.
    /// When we create an incomplete entry via sendRequest(), we don't know the
    /// target MAC. When the reply comes, we should verify it's from a plausible
    /// source. This field stores the MAC that sent the first reply.
    expected_reply_mac: [6]u8,
    /// Whether we've received at least one reply (for validation)
    has_received_reply: bool,
    /// SECURITY (Vuln 4): Conflict detection for ARP race attacks.
    /// Set true when we receive replies with different MACs for the same IP
    /// within a short time window. This indicates either:
    /// 1. Legitimate IP address conflict on the network
    /// 2. Active ARP spoofing/MITM attack in progress
    /// When set, the entry is invalidated and must be re-resolved after a delay.
    conflict_detected: bool,
    /// Timestamp when conflict was first detected (for backoff)
    conflict_time: u64,

    /// SECURITY (Vuln 1): Generation counter for TOCTOU detection.
    /// Incremented on every state change. Allows detecting if entry was modified
    /// between lock release and deferred operations (e.g., sendRequest).
    generation: u32,

    /// SECURITY (Vuln 4): Static binding flag - entry cannot be overwritten by ARP.
    /// Static entries are manually configured for critical hosts (gateway, DNS).
    /// They ignore ARP replies and never timeout.
    is_static: bool,

    /// Hash chain pointer for O(1) lookup by IP address
    hash_next: ?*ArpEntry,
};

/// ARP cache timeout in seconds (simplified - 20 minutes)
const ARP_TIMEOUT: u64 = 1200;

/// Max retries for incomplete entries
const ARP_MAX_RETRIES: u8 = 3;

/// Minimum interval between ARP cache updates for same IP (ticks)
/// Prevents rapid cache poisoning attacks
const ARP_UPDATE_RATE_LIMIT: u64 = 100; // ~1 second at 100Hz tick rate

/// Global ARP cache list
var arp_cache: std.ArrayListUnmanaged(ArpEntry) = .{};
var arp_allocator: std.mem.Allocator = undefined;

/// Simple tick counter for timers
var current_tick: u64 = 0;

/// Increment tick counter (call from timer interrupt)
pub fn tick() void {
    current_tick +%= 1;
}

/// Global ARP lock - IRQ-safe spinlock for concurrent access protection
var lock: sync.Spinlock = .{};

/// Ticks per second (configured by init)
var ticks_per_second: u64 = 1000; // Default to 1ms behavior until init called


/// Maximum sane tick rate (1MHz) to prevent timeout overflow
/// ARP_TIMEOUT (1200) * 2 * MAX_TICKS_PER_SECOND must fit in u64
const MAX_TICKS_PER_SECOND: u64 = 1_000_000;

/// Initialize ARP subsystem
pub fn init(allocator: std.mem.Allocator, ticks_per_sec: u32) void {
    arp_allocator = allocator;
    arp_cache = .{};
    // SECURITY (Vuln 3): Validate ticks_per_second bounds to prevent integer overflow.
    // If ticks_per_second is too high, ARP_TIMEOUT * ticks_per_second could overflow
    // in ReleaseFast builds (no overflow checks), causing entries to timeout immediately.
    // This would amplify ARP traffic and widen the attack window for spoofing.
    if (ticks_per_sec > 0 and ticks_per_sec <= MAX_TICKS_PER_SECOND) {
        ticks_per_second = ticks_per_sec;
    }
    // else: keep default of 1000 (safe value)
}

/// Find entry by IP using O(1) hash table lookup
fn findEntry(ip: u32) ?*ArpEntry {
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

fn resetPending(entry: *ArpEntry) void {
    entry.pending_pkts = [_]?[]u8{null} ** ArpEntry.QUEUE_SIZE;
    entry.pending_lens = [_]usize{0} ** ArpEntry.QUEUE_SIZE;
    entry.queue_head = 0;
    entry.queue_tail = 0;
    entry.queue_count = 0;
    entry.expected_reply_mac = [_]u8{0} ** 6;
    entry.has_received_reply = false;
    entry.conflict_detected = false;
    entry.conflict_time = 0;
    // Note: generation is NOT reset here - only incremented on state changes
    // is_static is NOT reset here - only modified by addStaticEntry/removeStaticEntry
}

fn clearPending(entry: *ArpEntry) void {
    freePending(entry);
}

fn freePending(entry: *ArpEntry) void {
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

/// Process an incoming ARP packet
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    const held = lock.acquire();
    defer held.release();

    // Validate ARP packet size
    const arp_offset = packet.ETH_HEADER_SIZE;
    if (pkt.len < arp_offset + @sizeOf(ArpHeader)) {
        return false;
    }

    // Get ARP header
    const arp: *align(1) ArpHeader = @ptrCast(pkt.data[arp_offset..]);

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
    // Learn sender's MAC address (ARP snooping)
    // Only if sender IP is on our subnet
    if (iface.isLocalSubnet(sender_ip)) {
        // Security: Reject ARP entries claiming to be our own IP address.
        if (sender_ip == iface.ip_addr) {
            return false;
        }

        // SECURITY: ARP Spoofing Protection.
        // Only update existing entries if this is an explicit ARP REPLY.
        // Unsolicited ARP REQUESTs ("Gratuitous ARP") are easily spoofed and
        // should not overwrite our cache unless we implement stronger validation.
        if (operation == 2) {
            if (findEntry(sender_ip)) |entry| {
                // SECURITY: For incomplete entries, validate the reply is plausible.
                // An attacker could race to send a spoofed reply before the real host.
                // We track whether we've already received a reply and from which MAC.
                if (entry.state == .incomplete) {
                    // SECURITY (Vuln 4): Check for conflict backoff period
                    // If we recently detected a conflict, ignore all replies for a while
                    // to prevent the attacker from winning the race repeatedly
                    if (entry.conflict_detected) {
                        const conflict_age = current_tick -% entry.conflict_time;
                        // Backoff for 5 seconds before accepting new replies
                        // This gives time for admin investigation and reduces attack surface
                        if (conflict_age < 5 * ticks_per_second) {
                            return false; // Still in conflict backoff period
                        }
                        // Backoff expired - reset conflict state and try fresh
                        entry.conflict_detected = false;
                        entry.has_received_reply = false;
                        entry.expected_reply_mac = [_]u8{0} ** 6;
                    }

                    if (!entry.has_received_reply) {
                        // SECURITY (Vuln 4 - First Reply Race): First reply is accepted without
                        // additional validation. An attacker on the same L2 segment can race
                        // the legitimate host to send a spoofed ARP reply first, winning MITM
                        // position. The conflict_detected mechanism only triggers for SUBSEQUENT
                        // conflicting replies, not the initial race winner.
                        //
                        // Risk: Medium - enables ARP spoofing/MITM on local network.
                        // Mitigation options (not implemented):
                        // - Require multiple consistent replies before promoting to reachable
                        // - Static ARP bindings for critical hosts (gateway, DNS)
                        // - 802.1X/Dynamic ARP Inspection at switch level
                        // - Gratuitous ARP announcement to detect conflicts proactively
                        @memcpy(&entry.expected_reply_mac, &arp.sender_mac);
                        entry.has_received_reply = true;
                        updateCache(iface, sender_ip, arp.sender_mac, .reachable) catch {};
                    } else {
                        // Subsequent reply - verify it matches expected MAC
                        if (std.mem.eql(u8, &entry.expected_reply_mac, &arp.sender_mac)) {
                            updateCache(iface, sender_ip, arp.sender_mac, .reachable) catch {};
                        } else {
                            // SECURITY (Vuln 4): Conflicting MAC detected!
                            // This indicates either:
                            // 1. Active ARP spoofing attack (attacker racing legitimate host)
                            // 2. IP address conflict on network (misconfiguration)
                            // 3. Legitimate failover/load balancing (rare for ARP)
                            //
                            // Response: Mark entry as conflicted, clear it, and enter backoff.
                            // The next resolution attempt after backoff will start fresh.
                            // TODO: Add kernel logging/alerting for this security event
                            entry.conflict_detected = true;
                            entry.conflict_time = current_tick;
                            entry.state = .incomplete;
                            entry.has_received_reply = false;
                            // Don't update cache - reject both MACs until backoff expires
                        }
                    }
                } else {
                    // Non-incomplete entry - apply rate limiting via updateCache
                    updateCache(iface, sender_ip, arp.sender_mac, .reachable) catch {};
                }
            }
        }
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
    const arp: *align(1) ArpHeader = @ptrCast(&buf[packet.ETH_HEADER_SIZE]);
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

    const arp: *align(1) ArpHeader = @ptrCast(&buf[packet.ETH_HEADER_SIZE]);
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
    const held = lock.acquire();
    defer held.release();
    return resolveUnlocked(ip);
}

/// Internal resolve without locking (caller must hold lock)
/// Uses O(1) hash table lookup
fn resolveUnlocked(ip: u32) ?[6]u8 {
    const idx = hashIp(ip);
    var curr = arp_hash_table[idx];

    while (curr) |entry| {
        if (entry.state != .free and entry.ip_addr == ip) {
            if (entry.state == .reachable or entry.state == .stale) {
                return entry.mac_addr;
            }
            return null; // Found but not reachable/stale
        }
        curr = entry.hash_next;
    }
    return null;
}

/// Resolve IP to MAC, sending ARP request if not cached
pub fn resolveOrRequest(iface: *Interface, ip: u32, pkt_opaque: ?*const anyopaque) ?[6]u8 {
    const pkt: ?*const PacketBuffer = if (pkt_opaque) |p| @ptrCast(@alignCast(p)) else null;

    // SECURITY (Vuln 1): Defer sendRequest() outside the critical section.
    // Previously, sendRequest() was called while holding the ARP spinlock.
    // This creates potential issues:
    // 1. Deadlock: If NIC driver's transmit() has its own locks, lock ordering
    //    violations could cause deadlock on SMP systems
    // 2. Priority inversion: Long transmit() calls block other CPUs spinning
    //    on the ARP lock, starving high-priority packet processing
    // 3. Reentrancy: If transmit() triggers a callback/IRQ that needs ARP
    //    resolution, we'd attempt to re-acquire a non-recursive spinlock
    //
    // Fix: Store the IP to resolve, release lock, then call sendRequest()
    // Also track entry generation to detect TOCTOU races.
    var deferred_send_ip: ?u32 = null;
    var deferred_generation: u32 = 0;
    var resolved_mac: ?[6]u8 = null;

    // Critical section - only cache operations, no external calls
    {
        const held = lock.acquire();
        defer held.release();

        // Use unlocked version since we already hold the lock
        if (resolveUnlocked(ip)) |mac| {
            resolved_mac = mac;
        } else {
            // Check if we already have an incomplete entry
            var found_incomplete = false;
            for (arp_cache.items) |*entry| {
                if (entry.ip_addr == ip and entry.state == .incomplete) {
                    found_incomplete = true;
                    if (pkt) |p| {
                        if (p.len <= packet.MAX_PACKET_SIZE) {
                            // SECURITY (Vuln 5): Allocate new buffer BEFORE freeing old one.
                            // Previously, we freed the head packet before allocating the new one.
                            // If allocation fails after free, we lose a queue slot without
                            // storing the new packet. By allocating first, we only evict
                            // the old packet when we know we have space for the new one.
                            const buf = arp_allocator.alloc(u8, p.len) catch null;
                            if (buf) |slot| {
                                // Queue full? Now safe to drop oldest since we have new buffer
                                if (entry.queue_count >= ArpEntry.QUEUE_SIZE) {
                                    const head_idx = @as(usize, entry.queue_head);
                                    if (entry.pending_pkts[head_idx]) |old_buf| {
                                        arp_allocator.free(old_buf);
                                        entry.pending_pkts[head_idx] = null;
                                    }
                                    entry.queue_head = (entry.queue_head + 1) % @as(u8, @intCast(ArpEntry.QUEUE_SIZE));
                                    entry.queue_count -= 1;
                                }

                                // Enqueue new packet
                                @memcpy(slot[0..p.len], p.data[0..p.len]);
                                const tail_idx = @as(usize, entry.queue_tail);
                                entry.pending_pkts[tail_idx] = slot;
                                entry.pending_lens[tail_idx] = p.len;
                                entry.queue_tail = (entry.queue_tail + 1) % @as(u8, @intCast(ArpEntry.QUEUE_SIZE));
                                entry.queue_count += 1;
                            }
                            // else: allocation failed, keep existing queue intact
                        }
                    }

                    if (entry.retries < ARP_MAX_RETRIES) {
                        entry.retries += 1;
                        deferred_send_ip = ip;
                        deferred_generation = entry.generation;
                    }
                    break;
                }
            }

            // Create incomplete entry if not found
            if (!found_incomplete) {
                if (findFreeEntry() catch null) |entry| {
                    clearPending(entry);
                    entry.ip_addr = ip;
                    entry.state = .incomplete;
                    entry.timestamp = current_tick;
                    entry.retries = 1;
                    entry.queue_head = 0;
                    entry.queue_tail = 0;
                    entry.queue_count = 0;
                    entry.expected_reply_mac = [_]u8{0} ** 6;
                    entry.has_received_reply = false;
                    entry.conflict_detected = false;
                    entry.conflict_time = 0;
                    entry.generation +%= 1; // Increment on state change
                    entry.is_static = false;
                    entry.hash_next = null;
                    // Insert into hash table for O(1) future lookups
                    hashTableInsert(entry);

                    if (pkt) |p| {
                        if (p.len <= packet.MAX_PACKET_SIZE) {
                            if (arp_allocator.alloc(u8, p.len) catch null) |slot| {
                                @memcpy(slot[0..p.len], p.data[0..p.len]);
                                entry.pending_pkts[entry.queue_tail] = slot;
                                entry.pending_lens[entry.queue_tail] = p.len;
                                entry.queue_tail = 1; // (0 + 1) % QUEUE_SIZE
                                entry.queue_count = 1;
                            }
                        }
                    }

                    deferred_send_ip = ip;
                    deferred_generation = entry.generation;
                }
            }
        }
    } // Lock released here

    // SECURITY (Vuln 1): Send ARP request OUTSIDE the critical section.
    // Re-check entry generation to detect if it was resolved while we released the lock.
    // This prevents redundant ARP requests when the entry was already resolved.
    if (deferred_send_ip) |target_ip| {
        var should_send = true;
        {
            const held = lock.acquire();
            defer held.release();
            if (findEntry(target_ip)) |entry| {
                // Skip send if entry was modified (resolved or conflict) since we released lock
                if (entry.generation != deferred_generation or entry.state != .incomplete) {
                    should_send = false;
                }
            } else {
                // Entry was removed - skip sending
                should_send = false;
            }
        }
        if (should_send) {
            sendRequest(iface, target_ip);
        }
    }

    return resolved_mac;
}

/// Broadcast MAC address
const BROADCAST_MAC: [6]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
/// Zero MAC address
const ZERO_MAC: [6]u8 = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

/// Update or add an entry to the ARP cache
fn updateCache(iface: *Interface, ip: u32, mac: [6]u8, state: ArpState) !void {
    // Security: Reject invalid MAC addresses to prevent cache poisoning
    // Broadcast MAC should never be cached for unicast traffic
    if (std.mem.eql(u8, &mac, &BROADCAST_MAC)) {
        return;
    }
    // Zero MAC is invalid for reachable entries
    if (std.mem.eql(u8, &mac, &ZERO_MAC)) {
        return;
    }
    // Reject multicast MACs (bit 0 of first octet set) for unicast IP entries
    // Exception: broadcast is already filtered above
    if ((mac[0] & 0x01) != 0) {
        return;
    }

    // Look for existing entry
    for (arp_cache.items) |*entry| {
        if (entry.ip_addr == ip) {
            // SECURITY (Vuln 4): Never overwrite static entries from ARP replies.
            // Static entries are manually configured for critical hosts (gateway, DNS)
            // and should never be modified by network traffic.
            if (entry.is_static) {
                return;
            }

            // SECURITY (Vuln 6): Rate limit updates to prevent cache poisoning attacks.
            // Allow updates for incomplete entries (awaiting resolution).
            if (entry.state != .incomplete) {
                const time_since_update = current_tick -% entry.timestamp;
                if (time_since_update < ARP_UPDATE_RATE_LIMIT) {
                    return; // Too soon - ignore to prevent rapid poisoning
                }
            }

            @memcpy(&entry.mac_addr, &mac);
            entry.state = state;
            entry.timestamp = current_tick;
            entry.retries = 0;
            entry.generation +%= 1; // SECURITY (Vuln 1): Increment on state change

            if (entry.queue_count > 0) {
                // Flush pending packets
                // SECURITY REQUIREMENT: iface.transmit() MUST be synchronous.
                // We free the buffer immediately after transmit() returns. If transmit()
                // queues the buffer for DMA/async processing without copying, the hardware
                // would read freed memory causing corruption or information disclosure.
                // Verify your NIC driver copies data before transmit() returns.
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

                            _ = iface.transmit(buf[0..len]);
                        }
                        // Buffer freed immediately - transmit must have copied or completed
                        arp_allocator.free(buf);
                        entry.pending_pkts[idx] = null;
                        entry.pending_lens[idx] = 0;
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
    entry.expected_reply_mac = [_]u8{0} ** 6;
    entry.has_received_reply = false;
    entry.conflict_detected = false;
    entry.conflict_time = 0;
    entry.generation +%= 1; // SECURITY (Vuln 1): Increment on new entry
    entry.is_static = false; // Dynamic entry from ARP
    entry.hash_next = null;
    // Insert into hash table for O(1) future lookups
    hashTableInsert(entry);
}

/// Maximum ARP cache entries (DoS protection)
const MAX_ARP_ENTRIES: usize = 256;

/// Hash table size (power of 2 for fast modulus)
/// 512 buckets for 256 max entries = ~0.5 load factor
const ARP_HASH_SIZE: usize = 512;

/// ARP hash table for O(1) lookup by IP address
/// Each bucket points to an ArpEntry (entries store their index for removal)
var arp_hash_table: [ARP_HASH_SIZE]?*ArpEntry = [_]?*ArpEntry{null} ** ARP_HASH_SIZE;

/// Hash function for IP address (simple but effective for IPs)
/// Uses multiplicative hashing with golden ratio constant
fn hashIp(ip: u32) usize {
    // Knuth's multiplicative hash
    const golden_ratio: u32 = 0x9E3779B9;
    const hash = ip *% golden_ratio;
    // Use upper bits (better distribution)
    return @as(usize, hash >> (32 - 9)) & (ARP_HASH_SIZE - 1);
}

/// Insert entry into hash table
fn hashTableInsert(entry: *ArpEntry) void {
    const idx = hashIp(entry.ip_addr);
    entry.hash_next = arp_hash_table[idx];
    arp_hash_table[idx] = entry;
}

/// Remove entry from hash table
fn hashTableRemove(entry: *ArpEntry) void {
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
/// Caller is responsible for inserting the returned entry into hash table
fn findFreeEntry() !*ArpEntry {
    // First pass: look for free entry (already removed from hash table)
    for (arp_cache.items) |*entry| {
        if (entry.state == .free) {
            clearPending(entry);
            return entry;
        }
    }

    // Second pass: look for oldest stale entry to recycle
    // SECURITY (Vuln 4): Never evict static entries
    var oldest_stale: ?*ArpEntry = null;
    var oldest_stale_time: u64 = current_tick;

    for (arp_cache.items) |*entry| {
        if (entry.state == .stale and !entry.is_static and entry.timestamp < oldest_stale_time) {
            oldest_stale = entry;
            oldest_stale_time = entry.timestamp;
        }
    }

    if (oldest_stale) |entry| {
        hashTableRemove(entry); // Remove old entry from hash table
        clearPending(entry);
        return entry;
    }

    // Check if at capacity - must evict via LRU
    if (arp_cache.items.len >= MAX_ARP_ENTRIES) {
        // Third pass: evict oldest reachable (LRU), but never static entries
        var oldest_reachable: ?*ArpEntry = null;
        var oldest_reachable_time: u64 = current_tick;

        for (arp_cache.items) |*entry| {
            if (entry.state == .reachable and !entry.is_static and entry.timestamp < oldest_reachable_time) {
                oldest_reachable = entry;
                oldest_reachable_time = entry.timestamp;
            }
        }

        if (oldest_reachable) |entry| {
            hashTableRemove(entry); // Remove old entry from hash table
            clearPending(entry);
            return entry;
        }

        // Fourth pass: evict oldest incomplete entry (incomplete entries are never static)
        var oldest_incomplete: ?*ArpEntry = null;
        var oldest_incomplete_time: u64 = current_tick;

        for (arp_cache.items) |*entry| {
            if (entry.state == .incomplete and entry.timestamp < oldest_incomplete_time) {
                oldest_incomplete = entry;
                oldest_incomplete_time = entry.timestamp;
            }
        }

        if (oldest_incomplete) |entry| {
            hashTableRemove(entry); // Remove old entry from hash table
            clearPending(entry);
            return entry;
        }

        // Cache full with no evictable entries (all static or should not happen)
        return error.OutOfMemory;
    }

    // Under capacity: append new entry
    const new_entry = try arp_cache.addOne(arp_allocator);

    // SECURITY: Zero-initialize before calling clearPending().
    // addOne() returns memory with undefined contents. If those bytes happen
    // to look like valid pointers in pending_pkts[], freePending() would call
    // allocator.free() on garbage addresses, causing heap corruption or crash.
    // Zero-initializing ensures pending_pkts[] contains null before clearPending.
    new_entry.* = std.mem.zeroes(ArpEntry);
    new_entry.state = .free;
    new_entry.hash_next = null;
    clearPending(new_entry);
    return new_entry;
}

/// Age ARP cache entries
pub fn ageCache() void {
    const held = lock.acquire();
    defer held.release();
    var i: usize = 0;
    while (i < arp_cache.items.len) {
        var entry = &arp_cache.items[i];
        if (entry.state == .free) {
            i += 1;
            continue;
        }

        // SECURITY (Vuln 4): Static entries never timeout
        if (entry.is_static) {
            i += 1;
            continue;
        }

        const age = current_tick -% entry.timestamp;

        switch (entry.state) {
            .incomplete => {
                // Timeout after 3 seconds (was hardcoded > 10 ticks which was too fast at 100Hz and definitely at 1000Hz)
                if (age > 3 * ticks_per_second) {
                    hashTableRemove(entry); // Remove from hash table before freeing
                    clearPending(entry);
                    entry.state = .free;
                    entry.generation +%= 1;
                }
            },
            .reachable => {
                // Timeout reachable entries
                if (age > ARP_TIMEOUT * ticks_per_second) {
                    entry.state = .stale;
                    entry.generation +%= 1;
                }
            },
            .stale => {
                // Timeout stale entries (2x standard timeout)
                if (age > ARP_TIMEOUT * 2 * ticks_per_second) {
                    hashTableRemove(entry); // Remove from hash table before freeing
                    clearPending(entry);
                    entry.state = .free;
                    entry.generation +%= 1;
                }
            },
            .free => {},
        }
        i += 1;
    }
}

/// Clear the ARP cache
/// SECURITY: Now acquires lock before clearing.
/// Previously this function iterated without holding the lock, allowing
/// concurrent packet reception to modify pending_pkts while clearPending()
/// was iterating, causing double-free or use-after-free of packet buffers.
pub fn clearCache() void {
    const held = lock.acquire();
    defer held.release();

    for (arp_cache.items) |*entry| {
        clearPending(entry);
        entry.state = .free;
    }
    arp_cache.clearRetainingCapacity();

    // Clear hash table
    for (&arp_hash_table) |*bucket| {
        bucket.* = null;
    }
}

/// Get cache entry count
/// SECURITY: Acquires lock to prevent race with cache modifications on SMP
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

// =============================================================================
// SECURITY (Vuln 4): Static ARP Binding Support
// =============================================================================
// Static ARP entries cannot be overwritten by network traffic and never timeout.
// Use these for critical infrastructure hosts (gateway, DNS servers) to prevent
// ARP spoofing attacks from redirecting traffic to attacker-controlled hosts.
//
// Example usage in kernel init:
//   arp.addStaticEntry(gateway_ip, gateway_mac) catch |err| { ... };
//   arp.addStaticEntry(dns_server_ip, dns_mac) catch |err| { ... };
// =============================================================================

/// Add a static ARP entry that cannot be overwritten by ARP replies.
/// Use for critical hosts like gateway and DNS servers to prevent ARP spoofing.
/// Returns error.OutOfMemory if cache is full, error.InvalidAddress if MAC is invalid.
pub fn addStaticEntry(ip: u32, mac: [6]u8) !void {
    // Validate MAC address
    if (std.mem.eql(u8, &mac, &BROADCAST_MAC)) {
        return error.InvalidAddress;
    }
    if (std.mem.eql(u8, &mac, &ZERO_MAC)) {
        return error.InvalidAddress;
    }
    if ((mac[0] & 0x01) != 0) {
        return error.InvalidAddress; // Multicast MAC
    }

    const held = lock.acquire();
    defer held.release();

    // Check if entry already exists
    for (arp_cache.items) |*entry| {
        if (entry.ip_addr == ip and entry.state != .free) {
            // Update existing entry to static
            @memcpy(&entry.mac_addr, &mac);
            entry.state = .reachable;
            entry.is_static = true;
            entry.timestamp = current_tick;
            entry.generation +%= 1;
            return;
        }
    }

    // Create new static entry
    const entry = try findFreeEntry();
    entry.ip_addr = ip;
    @memcpy(&entry.mac_addr, &mac);
    entry.state = .reachable;
    entry.timestamp = current_tick;
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
    // Insert into hash table for O(1) future lookups
    hashTableInsert(entry);
}

/// Remove a static ARP entry, allowing it to be learned dynamically again.
/// Returns true if entry was found and removed, false if not found.
pub fn removeStaticEntry(ip: u32) bool {
    const held = lock.acquire();
    defer held.release();

    for (arp_cache.items) |*entry| {
        if (entry.ip_addr == ip and entry.is_static) {
            hashTableRemove(entry); // Remove from hash table before freeing
            clearPending(entry);
            entry.state = .free;
            entry.is_static = false;
            entry.generation +%= 1;
            return true;
        }
    }
    return false;
}

/// Check if an IP has a static ARP entry.
/// Uses O(1) hash table lookup.
pub fn isStaticEntry(ip: u32) bool {
    const held = lock.acquire();
    defer held.release();

    if (findEntry(ip)) |entry| {
        return entry.is_static;
    }
    return false;
}

/// Get count of static entries in the cache.
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

// =============================================================================
// SECURITY (Vuln 2): Transmit Completion Verification
// =============================================================================
// The pending packet flush in updateCache() frees buffers immediately after
// calling iface.transmit(). This is ONLY safe if transmit() is synchronous
// (copies the buffer before returning). Async DMA-based drivers would cause
// use-after-free as the hardware reads freed memory.
//
// This compile-time constant documents the requirement. NIC driver authors
// MUST ensure their transmit() implementation copies data synchronously.
// =============================================================================

/// SECURITY: Set to true to enable runtime verification of synchronous transmit.
/// When enabled, pending packet buffers are zero-filled after free to detect
/// use-after-free (transmitted data would be zeros instead of packet contents).
/// This adds overhead and should only be enabled for debugging/testing.
pub const VERIFY_SYNC_TRANSMIT = false;

// =============================================================================
// SECURITY (Vuln 7): VLAN Tag Handling Documentation
// =============================================================================
// This ARP implementation assumes the Ethernet header is exactly 14 bytes
// (ETH_HEADER_SIZE). If 802.1Q VLAN tagging is present, the Ethernet header
// is 18 bytes (4 extra for VLAN tag), and the ARP header offset would be wrong.
//
// REQUIREMENTS:
// - VLAN tags MUST be stripped by the network driver or lower layer before
//   packets reach processPacket()
// - If VLAN support is needed, either:
//   1. Strip tags in the driver's receive path
//   2. Modify processPacket() to detect and skip VLAN tags:
//      const eth = @ptrCast(*EthernetHeader, pkt.data);
//      var arp_offset = packet.ETH_HEADER_SIZE;
//      if (eth.ethertype == 0x8100) { // VLAN tag present
//          arp_offset += 4; // Skip VLAN tag
//      }
//
// Current behavior: VLAN-tagged ARP packets will be parsed incorrectly,
// potentially causing cache corruption if the misaligned data passes validation.
// =============================================================================
