const std = @import("std");
const core_packet = @import("../../core/packet.zig");
const interface = @import("../../core/interface.zig");
const ethernet = @import("../../ethernet/ethernet.zig");
const Interface = interface.Interface;
const PacketBuffer = core_packet.PacketBuffer;
const ArpHeader = core_packet.ArpHeader;
const EthernetHeader = core_packet.EthernetHeader;
const cache = @import("cache.zig");
const monitor = @import("monitor.zig");

/// 802.1Q VLAN tag ethertype
const ETHERTYPE_VLAN: u16 = 0x8100;
/// 802.1Q VLAN tag size in bytes
const VLAN_TAG_SIZE: usize = 4;

/// Deferred ARP reply to avoid transmitting while holding cache lock.
/// SECURITY: Prevents potential deadlock if transmit() acquires driver lock
/// and driver lock -> cache lock ordering exists elsewhere.
const DeferredReply = struct {
    should_send: bool = false,
    target_mac: [6]u8 = [_]u8{0} ** 6,
    target_ip: u32 = 0,
};

/// Process an incoming ARP packet
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    var pending = cache.PendingPackets{};
    defer pending.transmitAndFree(iface);

    // SECURITY: Defer reply transmission until after releasing cache lock
    // to prevent potential deadlock (CLAUDE.md lock ordering guidelines).
    var deferred_reply = DeferredReply{};
    defer {
        if (deferred_reply.should_send) {
            sendReply(iface, deferred_reply.target_mac, deferred_reply.target_ip);
        }
    }

    const held = cache.lock.acquire();
    defer held.release();

    var arp_offset: usize = core_packet.ETH_HEADER_SIZE;

    if (pkt.len >= 14) {
        const ethertype_offset = 12;
        const ethertype = (@as(u16, pkt.data[ethertype_offset]) << 8) | pkt.data[ethertype_offset + 1];
        if (ethertype == ETHERTYPE_VLAN) {
            arp_offset += VLAN_TAG_SIZE;
            monitor.logSecurityEvent(.vlan_tag_detected, 0, null, null);
        }
    }

    if (pkt.len < arp_offset + @sizeOf(ArpHeader)) {
        return false;
    }

    const arp: *align(1) ArpHeader = @ptrCast(pkt.data[arp_offset..]);

    if (@byteSwap(arp.hw_type) != 1) return false;
    if (@byteSwap(arp.proto_type) != 0x0800) return false;
    if (arp.hw_len != 6 or arp.proto_len != 4) return false;

    const operation = arp.getOperation();
    const sender_ip = arp.getSenderIp();
    const target_ip = arp.getTargetIp();

    if (iface.isLocalSubnet(sender_ip)) {
        if (sender_ip == iface.ip_addr) return false;
        // SECURITY: Reject invalid sender IPs before cache operations.
        // IP 0 (0.0.0.0) has special meaning per RFC 5227 (ARP probe) and should
        // not create cache entries. IP 0xFFFFFFFF (broadcast) is never a valid host.
        if (sender_ip == 0 or sender_ip == 0xFFFFFFFF) return false;

        if (operation == 2) {
            if (cache.findEntry(sender_ip)) |entry| {
                if (entry.state == .incomplete) {
                    if (entry.conflict_detected) {
                        if (entry.conflict_count >= monitor.ARP_MAX_CONFLICTS) {
                            monitor.logSecurityEvent(.entry_blocked, sender_ip, null, null);
                            return false;
                        }

                        const exponent = @min(entry.conflict_count, monitor.ARP_MAX_BACKOFF_EXPONENT);
                        const backoff_multiplier = @as(u64, 1) << exponent;
                        const base_backoff = monitor.ARP_CONFLICT_BASE_BACKOFF * backoff_multiplier * monitor.ticks_per_second;
                        const jitter = (monitor.current_tick & 0xFF) * base_backoff / 1024;
                        const total_backoff = base_backoff + jitter;

                        const conflict_age = monitor.current_tick -% entry.conflict_time;
                        if (conflict_age < total_backoff) return false;

                        entry.conflict_detected = false;
                        entry.has_received_reply = false;
                        entry.expected_reply_mac = [_]u8{0} ** 6;
                    }

                    if (!entry.has_received_reply) {
                        @memcpy(&entry.expected_reply_mac, &arp.sender_mac);
                        entry.has_received_reply = true;
                        pending = cache.updateCache(iface, sender_ip, arp.sender_mac, .reachable) catch cache.PendingPackets{};
                    } else {
                        if (std.mem.eql(u8, &entry.expected_reply_mac, &arp.sender_mac)) {
                            pending = cache.updateCache(iface, sender_ip, arp.sender_mac, .reachable) catch cache.PendingPackets{};
                        } else {
                            entry.conflict_detected = true;
                            entry.conflict_time = monitor.current_tick;
                            entry.conflict_count +|= 1;
                            entry.state = .incomplete;
                            entry.has_received_reply = false;
                            monitor.logSecurityEvent(.conflict_detected, sender_ip, entry.expected_reply_mac, arp.sender_mac);
                        }
                    }
                } else {
                    pending = cache.updateCache(iface, sender_ip, arp.sender_mac, .reachable) catch cache.PendingPackets{};
                }
            }
        }
    }

    switch (operation) {
        1 => {
            if (target_ip == iface.ip_addr) {
                // SECURITY: Record reply parameters for deferred transmission
                // after releasing cache lock. This prevents potential deadlock
                // if transmit() -> driver lock and driver lock -> cache lock
                // ordering exists elsewhere in the codebase.
                deferred_reply.should_send = true;
                @memcpy(&deferred_reply.target_mac, &arp.sender_mac);
                deferred_reply.target_ip = sender_ip;
                return true;
            }
        },
        2 => return true,
        else => {},
    }

    return false;
}

/// Send an ARP reply
pub fn sendReply(iface: *Interface, target_mac: [6]u8, target_ip: u32) void {
    // SECURITY: Zero-init outgoing packet buffer to prevent kernel stack leaks in ReleaseFast
    var buf: [core_packet.ETH_HEADER_SIZE + @sizeOf(ArpHeader)]u8 = [_]u8{0} ** (core_packet.ETH_HEADER_SIZE + @sizeOf(ArpHeader));

    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &target_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_ARP);

    const arp: *align(1) ArpHeader = @ptrCast(&buf[core_packet.ETH_HEADER_SIZE]);
    arp.hw_type = @byteSwap(@as(u16, 1));
    arp.proto_type = @byteSwap(@as(u16, 0x0800));
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
    // SECURITY: Zero-init outgoing packet buffer to prevent kernel stack leaks in ReleaseFast
    var buf: [core_packet.ETH_HEADER_SIZE + @sizeOf(ArpHeader)]u8 = [_]u8{0} ** (core_packet.ETH_HEADER_SIZE + @sizeOf(ArpHeader));

    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &ethernet.BROADCAST_MAC);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_ARP);

    const arp: *align(1) ArpHeader = @ptrCast(&buf[core_packet.ETH_HEADER_SIZE]);
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
    const held = cache.lock.acquire();
    defer held.release();
    return resolveUnlocked(ip);
}

/// Internal resolve without locking
pub fn resolveUnlocked(ip: u32) ?[6]u8 {
    if (cache.findEntry(ip)) |entry| {
        if (entry.state == .reachable or entry.state == .stale) {
            return entry.mac_addr;
        }
    }
    return null;
}

/// Resolve IP to MAC, sending ARP request if not cached
pub fn resolveOrRequest(iface: *Interface, ip: u32, pkt_opaque: ?*const anyopaque) ?[6]u8 {
    const pkt: ?*const PacketBuffer = if (pkt_opaque) |p| @ptrCast(@alignCast(p)) else null;

    var deferred_send_ip: ?u32 = null;
    var deferred_generation: u32 = 0;
    var resolved_mac: ?[6]u8 = null;

    {
        const held = cache.lock.acquire();
        defer held.release();

        if (resolveUnlocked(ip)) |mac| {
            resolved_mac = mac;
        } else {
            var found_incomplete = false;
            for (cache.arp_cache.items) |*entry| {
                if (entry.ip_addr == ip and entry.state == .incomplete) {
                    found_incomplete = true;
                    if (pkt) |p| {
                        if (p.len <= core_packet.MAX_PACKET_SIZE) {
                            const buf = cache.arp_allocator.alloc(u8, p.len) catch null;
                            if (buf) |slot| {
                                if (entry.queue_count >= cache.ArpEntry.QUEUE_SIZE) {
                                    const head_idx = @as(usize, entry.queue_head);
                                    if (entry.pending_pkts[head_idx]) |old_buf| {
                                        cache.arp_allocator.free(old_buf);
                                        entry.pending_pkts[head_idx] = null;
                                    }
                                    entry.queue_head = (entry.queue_head + 1) % @as(u8, @intCast(cache.ArpEntry.QUEUE_SIZE));
                                    entry.queue_count -= 1;
                                }

                                @memcpy(slot[0..p.len], p.data[0..p.len]);
                                const tail_idx = @as(usize, entry.queue_tail);
                                entry.pending_pkts[tail_idx] = slot;
                                entry.pending_lens[tail_idx] = p.len;
                                entry.queue_tail = (entry.queue_tail + 1) % @as(u8, @intCast(cache.ArpEntry.QUEUE_SIZE));
                                entry.queue_count += 1;
                            }
                        }
                    }

                    if (entry.retries < cache.ARP_MAX_RETRIES) {
                        entry.retries += 1;
                        deferred_send_ip = ip;
                        deferred_generation = entry.generation;
                    }
                    break;
                }
            }

            if (!found_incomplete) {
                if (cache.incomplete_entry_count < cache.MAX_INCOMPLETE_ENTRIES) {
                    if (cache.findFreeEntry() catch null) |entry| {
                        cache.clearPending(entry);
                        entry.ip_addr = ip;
                        entry.state = .incomplete;
                        entry.timestamp = monitor.current_tick;
                        entry.retries = 1;
                        entry.queue_head = 0;
                        entry.queue_tail = 0;
                        entry.queue_count = 0;
                        entry.expected_reply_mac = [_]u8{0} ** 6;
                        entry.has_received_reply = false;
                        entry.conflict_detected = false;
                        entry.conflict_time = 0;
                        entry.conflict_count = 0;
                        entry.generation +%= 1;
                        entry.is_static = false;
                        entry.hash_next = null;
                        cache.hashTableInsert(entry);
                        cache.incomplete_entry_count += 1;

                        if (pkt) |p| {
                            if (p.len <= core_packet.MAX_PACKET_SIZE) {
                                if (cache.arp_allocator.alloc(u8, p.len) catch null) |slot| {
                                    @memcpy(slot[0..p.len], p.data[0..p.len]);
                                    entry.pending_pkts[entry.queue_tail] = slot;
                                    entry.pending_lens[entry.queue_tail] = p.len;
                                    entry.queue_tail = 1;
                                    entry.queue_count = 1;
                                }
                            }
                        }

                        deferred_send_ip = ip;
                        deferred_generation = entry.generation;
                    }
                } else {
                    monitor.logSecurityEvent(.incomplete_limit_reached, ip, null, null);
                }
            }
        }
    }

    if (deferred_send_ip) |target_ip| {
        var should_send = true;
        {
            const held = cache.lock.acquire();
            defer held.release();
            if (cache.findEntry(target_ip)) |entry| {
                if (entry.generation != deferred_generation or entry.state != .incomplete) {
                    should_send = false;
                }
            } else {
                should_send = false;
            }
        }
        if (should_send) {
            sendRequest(iface, target_ip);
        }
    }

    return resolved_mac;
}
