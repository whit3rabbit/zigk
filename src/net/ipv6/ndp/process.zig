// NDP Packet Processing (RX Path)
//
// Implements RFC 4861 receive path for Neighbor Discovery messages.
//
// Security considerations:
// - Hop Limit must be 255 (link-local only)
// - ICMPv6 checksum validation (done by ICMPv6 layer)
// - Source address validation
// - Option length validation

const std = @import("std");
const packet = @import("../../core/packet.zig");
const interface = @import("../../core/interface.zig");
const types = @import("types.zig");
const cache = @import("cache.zig");
const transmit = @import("transmit.zig");
const ipv6_types = @import("../ipv6/types.zig");
const icmpv6_types = @import("../icmpv6/types.zig");

const PacketBuffer = packet.PacketBuffer;
const Interface = interface.Interface;
const NeighborState = types.NeighborState;

// =============================================================================
// Main Entry Point
// =============================================================================

/// Process an incoming NDP message.
/// Called from ICMPv6 layer after checksum validation.
/// Hop limit validation (must be 255) is done by caller.
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer, msg_type: u8) bool {
    return switch (msg_type) {
        types.TYPE_NEIGHBOR_SOLICITATION => handleNeighborSolicitation(iface, pkt),
        types.TYPE_NEIGHBOR_ADVERTISEMENT => handleNeighborAdvertisement(iface, pkt),
        types.TYPE_ROUTER_SOLICITATION => handleRouterSolicitation(iface, pkt),
        types.TYPE_ROUTER_ADVERTISEMENT => handleRouterAdvertisement(iface, pkt),
        types.TYPE_REDIRECT => handleRedirect(iface, pkt),
        else => false,
    };
}

// =============================================================================
// Neighbor Solicitation (Type 135)
// =============================================================================

fn handleNeighborSolicitation(iface: *Interface, pkt: *PacketBuffer) bool {
    // Validate minimum size
    const ns_offset = pkt.transport_offset + icmpv6_types.ICMPV6_HEADER_SIZE;
    if (ns_offset + @sizeOf(types.NeighborSolicitationHeader) > pkt.len) {
        return false;
    }

    const ns: *const types.NeighborSolicitationHeader = @ptrCast(@alignCast(&pkt.data[ns_offset]));
    const target_addr = ns.target_addr;

    // RFC 4861 7.1.1: Target must not be multicast
    if (ipv6_types.isMulticast(target_addr)) {
        return false;
    }

    // RFC 4861 7.1.1: Check if target is our address
    if (!isOurAddress(iface, target_addr)) {
        return false; // Not for us
    }

    // RFC 4861 7.1.1: If source is unspecified (::), this is DAD
    const src_is_unspecified = ipv6_types.isUnspecified(pkt.src_ipv6);

    // Extract source link-layer address option (if present)
    var source_mac: ?[6]u8 = null;
    const options_offset = ns_offset + @sizeOf(types.NeighborSolicitationHeader);
    if (options_offset < pkt.len) {
        source_mac = parseLinkLayerAddressOption(
            pkt.data[options_offset..pkt.len],
            types.OPT_SOURCE_LINK_ADDR,
        );
    }

    // RFC 4861 7.1.1: If source is unspecified, no SLLA option allowed
    if (src_is_unspecified and source_mac != null) {
        return false;
    }

    // Update neighbor cache if source MAC is present
    if (source_mac) |mac| {
        updateNeighborFromNs(iface, pkt.src_ipv6, mac);
    }

    // Send Neighbor Advertisement
    // For DAD (unspecified source): send to all-nodes multicast, not solicited
    // For normal NS: send to source, solicited
    if (src_is_unspecified) {
        // DAD response: Send NA to all-nodes multicast
        return transmit.sendNeighborAdvertisement(
            iface,
            target_addr,
            ipv6_types.ALL_NODES_MULTICAST, // Destination
            false, // Not solicited
            true, // Override
        );
    } else {
        // Normal NS: Send NA to source
        return transmit.sendNeighborAdvertisement(
            iface,
            target_addr,
            pkt.src_ipv6, // Destination is NS source
            true, // Solicited
            true, // Override
        );
    }
}

// =============================================================================
// Neighbor Advertisement (Type 136)
// =============================================================================

fn handleNeighborAdvertisement(iface: *Interface, pkt: *PacketBuffer) bool {
    // Validate minimum size
    const na_offset = pkt.transport_offset + icmpv6_types.ICMPV6_HEADER_SIZE;
    if (na_offset + @sizeOf(types.NeighborAdvertisementHeader) > pkt.len) {
        return false;
    }

    const na: *const types.NeighborAdvertisementHeader = @ptrCast(@alignCast(&pkt.data[na_offset]));
    const target_addr = na.target_addr;

    // RFC 4861 7.1.2: Target must not be multicast
    if (ipv6_types.isMulticast(target_addr)) {
        return false;
    }

    // RFC 4861 7.1.2: If destination is multicast, S flag must be 0
    if (ipv6_types.isMulticast(pkt.dst_ipv6) and na.isSolicited()) {
        return false;
    }

    // Extract target link-layer address option
    var target_mac: ?[6]u8 = null;
    const options_offset = na_offset + @sizeOf(types.NeighborAdvertisementHeader);
    if (options_offset < pkt.len) {
        target_mac = parseLinkLayerAddressOption(
            pkt.data[options_offset..pkt.len],
            types.OPT_TARGET_LINK_ADDR,
        );
    }

    // Update neighbor cache
    const is_router = na.isRouter();
    const is_solicited = na.isSolicited();
    const is_override = na.isOverride();

    return updateNeighborFromNa(iface, target_addr, target_mac, is_router, is_solicited, is_override);
}

// =============================================================================
// Router Solicitation (Type 133)
// =============================================================================

fn handleRouterSolicitation(iface: *Interface, pkt: *PacketBuffer) bool {
    // We're not a router, so just ignore RS
    _ = iface;
    _ = pkt;
    return true;
}

// =============================================================================
// Router Advertisement (Type 134)
// =============================================================================

fn handleRouterAdvertisement(iface: *Interface, pkt: *PacketBuffer) bool {
    // Validate minimum size
    const ra_offset = pkt.transport_offset + icmpv6_types.ICMPV6_HEADER_SIZE;
    if (ra_offset + @sizeOf(types.RouterAdvertisementHeader) > pkt.len) {
        return false;
    }

    // RFC 4861 6.1.2: Source must be link-local
    if (!ipv6_types.isLinkLocal(pkt.src_ipv6)) {
        return false;
    }

    const ra: *const types.RouterAdvertisementHeader = @ptrCast(@alignCast(&pkt.data[ra_offset]));

    // Extract source link-layer address option
    var source_mac: ?[6]u8 = null;
    const options_offset = ra_offset + @sizeOf(types.RouterAdvertisementHeader);
    if (options_offset < pkt.len) {
        source_mac = parseLinkLayerAddressOption(
            pkt.data[options_offset..pkt.len],
            types.OPT_SOURCE_LINK_ADDR,
        );
    }

    // Update default router and neighbor cache
    const router_lifetime = ra.getRouterLifetime();

    if (source_mac) |mac| {
        updateRouterEntry(iface, pkt.src_ipv6, mac, router_lifetime);
    }

    // TODO: Process prefix options for SLAAC
    // TODO: Update interface MTU from MTU option
    // TODO: Update ReachableTime and RetransTimer from RA

    return true;
}

// =============================================================================
// Redirect (Type 137)
// =============================================================================

fn handleRedirect(iface: *Interface, pkt: *PacketBuffer) bool {
    // TODO: Implement redirect processing
    // For now, ignore redirects (security: redirects can be spoofed)
    _ = iface;
    _ = pkt;
    return false;
}

// =============================================================================
// Helper Functions
// =============================================================================

/// Check if an address belongs to this interface
fn isOurAddress(iface: *Interface, addr: [16]u8) bool {
    // Check link-local
    if (iface.has_link_local and std.mem.eql(u8, &iface.link_local_addr, &addr)) {
        return true;
    }

    // Check global addresses
    for (iface.ipv6_addrs[0..iface.ipv6_addr_count]) |entry| {
        if (std.mem.eql(u8, &entry.addr, &addr)) {
            return true;
        }
    }

    return false;
}

/// Parse a link-layer address option from NDP options
fn parseLinkLayerAddressOption(options: []const u8, opt_type: u8) ?[6]u8 {
    var offset: usize = 0;

    while (offset + 2 <= options.len) {
        const opt_t = options[offset];
        const opt_len = options[offset + 1];

        // Length in 8-octet units
        if (opt_len == 0) break; // Invalid length
        const opt_bytes = @as(usize, opt_len) * 8;

        if (offset + opt_bytes > options.len) break;

        if (opt_t == opt_type and opt_len == 1) {
            // Link-layer address option is 8 bytes: type(1) + len(1) + MAC(6)
            if (offset + 8 <= options.len) {
                var mac: [6]u8 = undefined;
                @memcpy(&mac, options[offset + 2 ..][0..6]);
                return mac;
            }
        }

        offset += opt_bytes;
    }

    return null;
}

/// Update neighbor cache from NS (Neighbor Solicitation)
fn updateNeighborFromNs(iface: *Interface, src_addr: [16]u8, mac: [6]u8) void {
    _ = iface;

    const held = cache.lock.acquire();
    defer held.release();

    // If entry exists, update it
    if (cache.findEntry(src_addr)) |entry| {
        if (entry.is_static) return;

        // RFC 4861 7.2.3: Update link-layer address if different
        if (!std.mem.eql(u8, &entry.mac_addr, &mac)) {
            @memcpy(&entry.mac_addr, &mac);
            entry.state = .Stale;
            entry.timestamp = cache.current_tick;
        }
    } else {
        // Create new STALE entry
        const entry = cache.createIncompleteEntry(src_addr) catch return;
        @memcpy(&entry.mac_addr, &mac);
        entry.state = .Stale;
        entry.timestamp = cache.current_tick;
    }
}

/// Update neighbor cache from NA (Neighbor Advertisement)
fn updateNeighborFromNa(
    iface: *Interface,
    target_addr: [16]u8,
    target_mac: ?[6]u8,
    is_router: bool,
    is_solicited: bool,
    is_override: bool,
) bool {
    _ = iface;

    var pending = cache.PendingPackets{};

    {
        const held = cache.lock.acquire();
        defer held.release();

        if (cache.findEntry(target_addr)) |entry| {
            if (entry.is_static) return true;

            const have_mac = target_mac != null;
            const mac_differs = if (target_mac) |mac| !std.mem.eql(u8, &entry.mac_addr, &mac) else false;

            // RFC 4861 7.2.5: State transition rules
            switch (entry.state) {
                .Incomplete => {
                    if (have_mac) {
                        const mac = target_mac.?;
                        @memcpy(&entry.mac_addr, &mac);
                        entry.is_router = is_router;
                        entry.timestamp = cache.current_tick;

                        if (is_solicited) {
                            entry.state = .Reachable;
                        } else {
                            entry.state = .Stale;
                        }

                        if (cache.incomplete_entry_count > 0) {
                            cache.incomplete_entry_count -= 1;
                        }

                        // Collect pending packets
                        if (entry.queue_count > 0) {
                            @memcpy(&pending.mac, &mac);
                            var i: u8 = 0;
                            while (i < entry.queue_count) : (i += 1) {
                                const idx = (entry.queue_head +% i) % @as(u8, @intCast(cache.NeighborEntry.QUEUE_SIZE));
                                if (entry.pending_pkts[idx]) |buf| {
                                    pending.pkts[pending.count] = buf;
                                    pending.lens[pending.count] = entry.pending_lens[idx];
                                    pending.count += 1;
                                    entry.pending_pkts[idx] = null;
                                }
                            }
                            entry.queue_count = 0;
                            entry.queue_head = 0;
                            entry.queue_tail = 0;
                        }
                    }
                },

                .Reachable, .Stale, .Delay, .Probe => {
                    if (is_override or (!mac_differs)) {
                        // Update entry
                        if (target_mac) |mac| {
                            @memcpy(&entry.mac_addr, &mac);
                        }
                        entry.is_router = is_router;

                        if (is_solicited) {
                            entry.state = .Reachable;
                            entry.timestamp = cache.current_tick;
                        } else if (mac_differs) {
                            entry.state = .Stale;
                            entry.timestamp = cache.current_tick;
                        }
                    } else if (mac_differs and !is_override) {
                        // RFC 4861: If not override and different MAC, just go to STALE
                        if (is_solicited) {
                            entry.state = .Stale;
                            entry.timestamp = cache.current_tick;
                        }
                    }
                },

                .Free => {},
            }
        }
    }

    // TODO: Transmit pending packets (need interface reference)
    // For now, just free them
    for (&pending.pkts) |*slot| {
        if (slot.*) |buf| {
            cache.cache_allocator.free(buf);
            slot.* = null;
        }
    }

    return true;
}

/// Update router entry in neighbor cache
fn updateRouterEntry(iface: *Interface, router_addr: [16]u8, mac: [6]u8, lifetime: u16) void {
    const held = cache.lock.acquire();
    defer held.release();

    if (cache.findEntry(router_addr)) |entry| {
        if (!entry.is_static) {
            @memcpy(&entry.mac_addr, &mac);
            entry.is_router = (lifetime > 0);
            entry.state = .Stale;
            entry.timestamp = cache.current_tick;
        }
    } else if (lifetime > 0) {
        // Create new entry for router
        const entry = cache.createIncompleteEntry(router_addr) catch return;
        @memcpy(&entry.mac_addr, &mac);
        entry.is_router = true;
        entry.state = .Stale;
        entry.timestamp = cache.current_tick;
    }

    // Update interface default gateway if this is the first RA
    if (lifetime > 0 and !iface.has_ipv6_gateway) {
        @memcpy(&iface.ipv6_gateway, &router_addr);
        iface.has_ipv6_gateway = true;
    }
}
