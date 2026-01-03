// NDP (Neighbor Discovery Protocol) Types
//
// Implements RFC 4861 packet structures and constants.
//
// References:
// - RFC 4861: Neighbor Discovery for IP version 6 (IPv6)
//
// NDP message types (ICMPv6):
// - Router Solicitation (133)
// - Router Advertisement (134)
// - Neighbor Solicitation (135)
// - Neighbor Advertisement (136)
// - Redirect (137)

const std = @import("std");

// =============================================================================
// ICMPv6 Type Constants for NDP
// =============================================================================

pub const TYPE_ROUTER_SOLICITATION: u8 = 133;
pub const TYPE_ROUTER_ADVERTISEMENT: u8 = 134;
pub const TYPE_NEIGHBOR_SOLICITATION: u8 = 135;
pub const TYPE_NEIGHBOR_ADVERTISEMENT: u8 = 136;
pub const TYPE_REDIRECT: u8 = 137;

// =============================================================================
// NDP Option Types (RFC 4861 Section 4.6)
// =============================================================================

pub const OPT_SOURCE_LINK_ADDR: u8 = 1; // RFC 4861 4.6.1
pub const OPT_TARGET_LINK_ADDR: u8 = 2; // RFC 4861 4.6.1
pub const OPT_PREFIX_INFO: u8 = 3; // RFC 4861 4.6.2
pub const OPT_REDIRECTED_HEADER: u8 = 4; // RFC 4861 4.6.3
pub const OPT_MTU: u8 = 5; // RFC 4861 4.6.4

// =============================================================================
// NDP Constants
// =============================================================================

/// Minimum NDP message size (ICMPv6 header + type-specific header)
pub const MIN_NS_SIZE: usize = 24; // 8 byte ICMPv6 + 16 byte target
pub const MIN_NA_SIZE: usize = 24; // 8 byte ICMPv6 + 16 byte target
pub const MIN_RS_SIZE: usize = 8; // Just ICMPv6 header with reserved
pub const MIN_RA_SIZE: usize = 16; // ICMPv6 + cur_hop + flags + lifetime + timers

/// Link-layer address option size (Ethernet)
pub const LINK_ADDR_OPTION_SIZE: usize = 8; // 1 type + 1 len + 6 MAC

/// Solicited-node multicast prefix (ff02::1:ff00:0/104)
pub const SOLICITED_NODE_PREFIX: [13]u8 = .{
    0xFF, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0xFF,
};

// =============================================================================
// Neighbor Cache States (RFC 4861 Section 7.3.2)
// =============================================================================

pub const NeighborState = enum(u8) {
    /// Entry is free/unused
    Free = 0,
    /// Address resolution in progress, waiting for NA
    Incomplete = 1,
    /// Recently confirmed reachability
    Reachable = 2,
    /// More than ReachableTime since last confirmation
    Stale = 3,
    /// Waiting for upper-layer reachability hint (before probing)
    Delay = 4,
    /// Actively probing with unicast NS
    Probe = 5,
};

// =============================================================================
// NDP Timers (RFC 4861 Section 10)
// =============================================================================

/// Base reachable time (ms) - can be overridden by RA
pub const REACHABLE_TIME_MS: u64 = 30_000;

/// Retransmit timer for NS (ms)
pub const RETRANS_TIMER_MS: u64 = 1_000;

/// Delay before entering PROBE state (ms)
pub const DELAY_FIRST_PROBE_MS: u64 = 5_000;

/// Maximum unicast solicitations before giving up
pub const MAX_UNICAST_SOLICIT: u8 = 3;

/// Maximum multicast solicitations for initial resolution
pub const MAX_MULTICAST_SOLICIT: u8 = 3;

/// DAD transmits before declaring address unique
pub const DUP_ADDR_DETECT_TRANSMITS: u8 = 1;

// =============================================================================
// Neighbor Cache Entry
// =============================================================================

pub const NeighborEntry = struct {
    /// Pending packets queue size
    pub const QUEUE_SIZE: usize = 4;

    /// IPv6 address of neighbor
    ipv6_addr: [16]u8,
    /// Link-layer address (MAC)
    mac_addr: [6]u8,
    /// Current state
    state: NeighborState,
    /// Is this neighbor a router?
    is_router: bool,
    /// Timestamp of last state change (ticks)
    timestamp: u64,
    /// Number of NS retransmissions
    retries: u8,
    /// Generation counter for TOCTOU detection
    generation: u32,
    /// Static entry (cannot be overwritten by NDP)
    is_static: bool,
    /// Hash chain pointer
    hash_next: ?*NeighborEntry,
    /// Pending packets
    pending_pkts: [QUEUE_SIZE]?[]u8,
    pending_lens: [QUEUE_SIZE]usize,
    queue_head: u8,
    queue_tail: u8,
    queue_count: u8,

    pub fn init() NeighborEntry {
        return .{
            .ipv6_addr = [_]u8{0} ** 16,
            .mac_addr = [_]u8{0} ** 6,
            .state = .Free,
            .is_router = false,
            .timestamp = 0,
            .retries = 0,
            .generation = 0,
            .is_static = false,
            .hash_next = null,
            .pending_pkts = [_]?[]u8{null} ** QUEUE_SIZE,
            .pending_lens = [_]usize{0} ** QUEUE_SIZE,
            .queue_head = 0,
            .queue_tail = 0,
            .queue_count = 0,
        };
    }
};

// =============================================================================
// NDP Message Headers (packed for network parsing)
// =============================================================================

/// Neighbor Solicitation header (after ICMPv6 type/code/checksum)
/// RFC 4861 Section 4.3
pub const NeighborSolicitationHeader = extern struct {
    reserved: u32,
    target_addr: [16]u8,

    comptime {
        if (@sizeOf(@This()) != 20) @compileError("NeighborSolicitationHeader must be 20 bytes");
    }
};

/// Neighbor Advertisement header (after ICMPv6 type/code/checksum)
/// RFC 4861 Section 4.4
pub const NeighborAdvertisementHeader = extern struct {
    /// Flags and reserved (R|S|O|0...0)
    flags_reserved: u32,
    target_addr: [16]u8,

    /// R (Router) flag
    pub fn isRouter(self: *const NeighborAdvertisementHeader) bool {
        return (@byteSwap(self.flags_reserved) & 0x80000000) != 0;
    }

    /// S (Solicited) flag
    pub fn isSolicited(self: *const NeighborAdvertisementHeader) bool {
        return (@byteSwap(self.flags_reserved) & 0x40000000) != 0;
    }

    /// O (Override) flag
    pub fn isOverride(self: *const NeighborAdvertisementHeader) bool {
        return (@byteSwap(self.flags_reserved) & 0x20000000) != 0;
    }

    pub fn setFlags(self: *NeighborAdvertisementHeader, router: bool, solicited: bool, override: bool) void {
        var flags: u32 = 0;
        if (router) flags |= 0x80000000;
        if (solicited) flags |= 0x40000000;
        if (override) flags |= 0x20000000;
        self.flags_reserved = @byteSwap(flags);
    }

    comptime {
        if (@sizeOf(@This()) != 20) @compileError("NeighborAdvertisementHeader must be 20 bytes");
    }
};

/// Router Solicitation header (after ICMPv6 type/code/checksum)
/// RFC 4861 Section 4.1
pub const RouterSolicitationHeader = extern struct {
    reserved: u32,

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("RouterSolicitationHeader must be 4 bytes");
    }
};

/// Router Advertisement header (after ICMPv6 type/code/checksum)
/// RFC 4861 Section 4.2
pub const RouterAdvertisementHeader = extern struct {
    cur_hop_limit: u8,
    flags: u8,
    router_lifetime: u16,
    reachable_time: u32,
    retrans_timer: u32,

    /// M (Managed address configuration) flag
    pub fn isManagedFlag(self: *const RouterAdvertisementHeader) bool {
        return (self.flags & 0x80) != 0;
    }

    /// O (Other configuration) flag
    pub fn isOtherFlag(self: *const RouterAdvertisementHeader) bool {
        return (self.flags & 0x40) != 0;
    }

    pub fn getRouterLifetime(self: *const RouterAdvertisementHeader) u16 {
        return @byteSwap(self.router_lifetime);
    }

    pub fn getReachableTime(self: *const RouterAdvertisementHeader) u32 {
        return @byteSwap(self.reachable_time);
    }

    pub fn getRetransTimer(self: *const RouterAdvertisementHeader) u32 {
        return @byteSwap(self.retrans_timer);
    }

    comptime {
        if (@sizeOf(@This()) != 12) @compileError("RouterAdvertisementHeader must be 12 bytes");
    }
};

// =============================================================================
// NDP Options
// =============================================================================

/// Generic NDP option header
pub const NdpOptionHeader = extern struct {
    opt_type: u8,
    /// Length in 8-octet units
    length: u8,

    /// Get option length in bytes
    pub fn getLengthBytes(self: *const NdpOptionHeader) usize {
        return @as(usize, self.length) * 8;
    }
};

/// Source/Target Link-Layer Address Option (Type 1 or 2)
/// RFC 4861 Section 4.6.1
pub const LinkLayerAddressOption = extern struct {
    opt_type: u8,
    length: u8,
    addr: [6]u8,

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("LinkLayerAddressOption must be 8 bytes");
    }
};

/// Prefix Information Option (Type 3)
/// RFC 4861 Section 4.6.2
pub const PrefixInfoOption = extern struct {
    opt_type: u8,
    length: u8,
    prefix_length: u8,
    flags: u8,
    valid_lifetime: u32,
    preferred_lifetime: u32,
    reserved2: u32,
    prefix: [16]u8,

    /// L (On-link) flag
    pub fn isOnLink(self: *const PrefixInfoOption) bool {
        return (self.flags & 0x80) != 0;
    }

    /// A (Autonomous address-configuration) flag
    pub fn isAutonomous(self: *const PrefixInfoOption) bool {
        return (self.flags & 0x40) != 0;
    }

    pub fn getValidLifetime(self: *const PrefixInfoOption) u32 {
        return @byteSwap(self.valid_lifetime);
    }

    pub fn getPreferredLifetime(self: *const PrefixInfoOption) u32 {
        return @byteSwap(self.preferred_lifetime);
    }

    comptime {
        if (@sizeOf(@This()) != 32) @compileError("PrefixInfoOption must be 32 bytes");
    }
};

/// MTU Option (Type 5)
/// RFC 4861 Section 4.6.4
pub const MtuOption = extern struct {
    opt_type: u8,
    length: u8,
    reserved: u16,
    mtu: u32,

    pub fn getMtu(self: *const MtuOption) u32 {
        return @byteSwap(self.mtu);
    }

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("MtuOption must be 8 bytes");
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Compute solicited-node multicast address from unicast address
/// Result: ff02::1:ffXX:XXXX where XX:XXXX is last 24 bits of unicast addr
pub fn computeSolicitedNodeMulticast(unicast_addr: [16]u8) [16]u8 {
    return .{
        0xFF, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0xFF,
        unicast_addr[13],
        unicast_addr[14],
        unicast_addr[15],
    };
}

/// Check if address is a solicited-node multicast address
pub fn isSolicitedNodeMulticast(addr: [16]u8) bool {
    return std.mem.eql(u8, addr[0..13], &SOLICITED_NODE_PREFIX);
}

/// Check if NDP message type requires hop limit == 255
pub fn requiresHopLimit255(msg_type: u8) bool {
    return switch (msg_type) {
        TYPE_ROUTER_SOLICITATION,
        TYPE_ROUTER_ADVERTISEMENT,
        TYPE_NEIGHBOR_SOLICITATION,
        TYPE_NEIGHBOR_ADVERTISEMENT,
        TYPE_REDIRECT,
        => true,
        else => false,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "solicited-node multicast computation" {
    const testing = std.testing;

    // Example: 2001:db8::1 -> ff02::1:ff00:0001
    const unicast = [_]u8{
        0x20, 0x01, 0x0D, 0xB8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    };
    const snm = computeSolicitedNodeMulticast(unicast);

    try testing.expectEqual(@as(u8, 0xFF), snm[0]);
    try testing.expectEqual(@as(u8, 0x02), snm[1]);
    try testing.expectEqual(@as(u8, 0xFF), snm[12]);
    try testing.expectEqual(@as(u8, 0x00), snm[13]);
    try testing.expectEqual(@as(u8, 0x00), snm[14]);
    try testing.expectEqual(@as(u8, 0x01), snm[15]);

    try testing.expect(isSolicitedNodeMulticast(snm));
}

test "NeighborAdvertisement flags" {
    const testing = std.testing;

    var na: NeighborAdvertisementHeader = undefined;
    na.setFlags(true, true, true);

    try testing.expect(na.isRouter());
    try testing.expect(na.isSolicited());
    try testing.expect(na.isOverride());

    na.setFlags(false, true, false);
    try testing.expect(!na.isRouter());
    try testing.expect(na.isSolicited());
    try testing.expect(!na.isOverride());
}
