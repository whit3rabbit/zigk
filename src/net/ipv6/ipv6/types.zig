// IPv6 Types and Constants
//
// Contains protocol constants, extension header types, and helper structures
// for IPv6 packet processing.

const std = @import("std");
const packet = @import("../../core/packet.zig");

// Re-export header types
pub const Ipv6Header = packet.Ipv6Header;
pub const Ipv6ExtHeader = packet.Ipv6ExtHeader;
pub const Ipv6FragmentHeader = packet.Ipv6FragmentHeader;

// =============================================================================
// Protocol Constants
// =============================================================================

/// Next Header / Protocol values (same as IPv4 protocol field)
pub const PROTO_HOPOPT: u8 = 0; // Hop-by-Hop Options
pub const PROTO_ICMP: u8 = 1; // ICMP (IPv4 only)
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;
pub const PROTO_ENCAP: u8 = 41; // IPv6 Encapsulation
pub const PROTO_ROUTING: u8 = 43; // Routing Header
pub const PROTO_FRAGMENT: u8 = 44; // Fragment Header
pub const PROTO_GRE: u8 = 47; // GRE
pub const PROTO_ESP: u8 = 50; // Encapsulating Security Payload
pub const PROTO_AH: u8 = 51; // Authentication Header
pub const PROTO_ICMPV6: u8 = 58; // ICMPv6
pub const PROTO_NONE: u8 = 59; // No Next Header
pub const PROTO_DSTOPTS: u8 = 60; // Destination Options
pub const PROTO_SCTP: u8 = 132; // SCTP

/// Default hop limit for outgoing packets
pub const DEFAULT_HOP_LIMIT: u8 = 64;

/// Maximum number of extension headers to process (DoS protection)
pub const MAX_EXTENSION_HEADERS: usize = 10;

/// IPv6 header size
pub const HEADER_SIZE: usize = 40;

/// Minimum MTU for IPv6 (RFC 8200)
pub const MIN_MTU: u16 = 1280;

/// Default MTU for Ethernet
pub const DEFAULT_MTU: u16 = 1500;

/// IPv6 unspecified address (::)
pub const UNSPECIFIED_ADDR: [16]u8 = [_]u8{0} ** 16;

/// IPv6 loopback address (::1)
pub const LOOPBACK_ADDR: [16]u8 = [_]u8{0} ** 15 ++ [_]u8{1};

// =============================================================================
// Extension Header Helpers
// =============================================================================

/// Check if a next_header value indicates an extension header
pub fn isExtensionHeader(next_header: u8) bool {
    return switch (next_header) {
        PROTO_HOPOPT,
        PROTO_ROUTING,
        PROTO_FRAGMENT,
        PROTO_DSTOPTS,
        PROTO_AH,
        => true,
        else => false,
    };
}

/// Check if a next_header value is an upper-layer protocol
pub fn isUpperLayerProtocol(next_header: u8) bool {
    return switch (next_header) {
        PROTO_TCP,
        PROTO_UDP,
        PROTO_ICMPV6,
        PROTO_SCTP,
        PROTO_NONE,
        => true,
        else => false,
    };
}

// =============================================================================
// Extension Header Result
// =============================================================================

/// Result of parsing extension headers
pub const ExtensionParseResult = struct {
    /// Final next_header value (upper-layer protocol)
    next_header: u8,
    /// Offset to the upper-layer header
    transport_offset: usize,
    /// Fragment header info (if present)
    fragment: ?FragmentInfo,
    /// Number of extension headers parsed
    extension_count: usize,
};

/// Fragment information extracted from Fragment Header
pub const FragmentInfo = struct {
    /// Offset in 8-octet units
    offset: u13,
    /// More Fragments flag
    more_fragments: bool,
    /// Fragment identification
    identification: u32,
    /// Next header after fragment header
    next_header: u8,
};

// =============================================================================
// Address Scope
// =============================================================================

/// IPv6 address scope (RFC 4007)
pub const AddressScope = enum(u4) {
    InterfaceLocal = 1,
    LinkLocal = 2,
    AdminLocal = 4,
    SiteLocal = 5,
    OrganizationLocal = 8,
    Global = 14,
};

/// Get the scope of an IPv6 address
pub fn getAddressScope(addr: [16]u8) AddressScope {
    // Loopback (::1)
    if (isLoopback(addr)) return .InterfaceLocal;

    // Link-local (fe80::/10)
    if (addr[0] == 0xFE and (addr[1] & 0xC0) == 0x80) return .LinkLocal;

    // Site-local (fec0::/10) - deprecated but still recognized
    if (addr[0] == 0xFE and (addr[1] & 0xC0) == 0xC0) return .SiteLocal;

    // Multicast scope is encoded in the address
    if (addr[0] == 0xFF) {
        return @enumFromInt(addr[1] & 0x0F);
    }

    return .Global;
}

/// Check if address is loopback (::1)
pub fn isLoopback(addr: [16]u8) bool {
    for (addr[0..15]) |b| {
        if (b != 0) return false;
    }
    return addr[15] == 1;
}

/// Check if address is unspecified (::)
pub fn isUnspecified(addr: [16]u8) bool {
    for (addr) |b| {
        if (b != 0) return false;
    }
    return true;
}

/// Check if address is multicast (ff00::/8)
pub fn isMulticast(addr: [16]u8) bool {
    return addr[0] == 0xFF;
}

/// Check if address is link-local (fe80::/10)
pub fn isLinkLocal(addr: [16]u8) bool {
    return addr[0] == 0xFE and (addr[1] & 0xC0) == 0x80;
}

/// Check if two addresses are equal
pub fn addressEqual(a: [16]u8, b: [16]u8) bool {
    return std.mem.eql(u8, &a, &b);
}

// =============================================================================
// Multicast Address Utilities
// =============================================================================

/// All-nodes multicast address (ff02::1)
pub const ALL_NODES_MULTICAST: [16]u8 = .{ 0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

/// All-routers multicast address (ff02::2)
pub const ALL_ROUTERS_MULTICAST: [16]u8 = .{ 0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };

/// Generate solicited-node multicast address for NDP
/// Result is ff02::1:ffXX:XXXX where XX:XXXX are the last 24 bits
pub fn solicitedNodeMulticast(addr: [16]u8) [16]u8 {
    return .{
        0xFF,
        0x02,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0x01,
        0xFF,
        addr[13],
        addr[14],
        addr[15],
    };
}

/// Map IPv6 multicast address to Ethernet multicast MAC
/// Per RFC 2464: 33:33:XX:XX:XX:XX where XX are last 4 bytes of IPv6 address
pub fn multicastToMac(addr: [16]u8) [6]u8 {
    return .{ 0x33, 0x33, addr[12], addr[13], addr[14], addr[15] };
}

// =============================================================================
// Tests
// =============================================================================

test "isExtensionHeader" {
    const testing = std.testing;

    try testing.expect(isExtensionHeader(PROTO_HOPOPT));
    try testing.expect(isExtensionHeader(PROTO_ROUTING));
    try testing.expect(isExtensionHeader(PROTO_FRAGMENT));
    try testing.expect(isExtensionHeader(PROTO_DSTOPTS));
    try testing.expect(isExtensionHeader(PROTO_AH));

    try testing.expect(!isExtensionHeader(PROTO_TCP));
    try testing.expect(!isExtensionHeader(PROTO_UDP));
    try testing.expect(!isExtensionHeader(PROTO_ICMPV6));
}

test "address classification" {
    const testing = std.testing;

    // Loopback
    const loopback = [_]u8{0} ** 15 ++ [_]u8{1};
    try testing.expect(isLoopback(loopback));
    try testing.expectEqual(AddressScope.InterfaceLocal, getAddressScope(loopback));

    // Link-local
    const link_local = [_]u8{ 0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expect(isLinkLocal(link_local));
    try testing.expectEqual(AddressScope.LinkLocal, getAddressScope(link_local));

    // Multicast
    const multicast = [_]u8{ 0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expect(isMulticast(multicast));
    try testing.expectEqual(AddressScope.LinkLocal, getAddressScope(multicast));
}

test "solicited-node multicast" {
    const testing = std.testing;

    const addr = [_]u8{ 0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xAB, 0xCD, 0xEF, 0x12 };
    const snm = solicitedNodeMulticast(addr);

    try testing.expectEqual(@as(u8, 0xFF), snm[0]);
    try testing.expectEqual(@as(u8, 0x02), snm[1]);
    try testing.expectEqual(@as(u8, 0x01), snm[11]);
    try testing.expectEqual(@as(u8, 0xFF), snm[12]);
    try testing.expectEqual(@as(u8, 0xCD), snm[13]);
    try testing.expectEqual(@as(u8, 0xEF), snm[14]);
    try testing.expectEqual(@as(u8, 0x12), snm[15]);
}
