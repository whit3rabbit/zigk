// IP Address Abstraction for Dual-Stack (IPv4/IPv6) Support
//
// Provides a tagged union type for representing both IPv4 and IPv6 addresses
// in a type-safe manner. This is the foundation for dual-stack networking.
//
// Design:
//   - Tagged union allows compile-time exhaustive matching
//   - Helper methods for common address classifications
//   - Parsing and formatting utilities for both address families
//   - Zero-copy operations where possible

const std = @import("std");

/// Tagged union representing either an IPv4 or IPv6 address.
/// IPv4 addresses are stored as host byte order u32.
/// IPv6 addresses are stored as 16 bytes in network byte order.
pub const IpAddr = union(enum) {
    /// Not bound / unspecified (use before bind or for INADDR_ANY)
    none,
    v4: u32,
    v6: [16]u8,

    // =========================================================================
    // Well-Known Addresses
    // =========================================================================

    /// IPv4 unspecified address (0.0.0.0)
    pub const UNSPECIFIED_V4: IpAddr = .{ .v4 = 0 };

    /// IPv6 unspecified address (::)
    pub const UNSPECIFIED_V6: IpAddr = .{ .v6 = [_]u8{0} ** 16 };

    /// IPv4 loopback address (127.0.0.1)
    pub const LOOPBACK_V4: IpAddr = .{ .v4 = 0x7F000001 };

    /// IPv6 loopback address (::1)
    pub const LOOPBACK_V6: IpAddr = .{ .v6 = [_]u8{0} ** 15 ++ [_]u8{1} };

    /// IPv4 broadcast address (255.255.255.255)
    pub const BROADCAST_V4: IpAddr = .{ .v4 = 0xFFFFFFFF };

    // =========================================================================
    // Address Family Queries
    // =========================================================================

    /// Returns true if this is an IPv4 address
    pub fn isV4(self: IpAddr) bool {
        return self == .v4;
    }

    /// Returns true if this is an IPv6 address
    pub fn isV6(self: IpAddr) bool {
        return self == .v6;
    }

    /// Returns true if this is the none/unbound state
    pub fn isNone(self: IpAddr) bool {
        return self == .none;
    }

    /// Returns the address family constant (AF_INET=2 or AF_INET6=10)
    /// Returns 0 for .none
    pub fn family(self: IpAddr) u16 {
        return switch (self) {
            .none => 0,
            .v4 => AF_INET,
            .v6 => AF_INET6,
        };
    }

    // =========================================================================
    // Address Classification
    // =========================================================================

    /// Returns true if this is a multicast address.
    /// IPv4: 224.0.0.0/4 (first nibble = 0xE)
    /// IPv6: ff00::/8 (first byte = 0xFF)
    pub fn isMulticast(self: IpAddr) bool {
        return switch (self) {
            .none => false,
            .v4 => |ip| (ip >> 28) == 0xE,
            .v6 => |ip| ip[0] == 0xFF,
        };
    }

    /// Returns true if this is a loopback address.
    /// IPv4: 127.0.0.0/8
    /// IPv6: ::1
    pub fn isLoopback(self: IpAddr) bool {
        return switch (self) {
            .none => false,
            .v4 => |ip| (ip >> 24) == 127,
            .v6 => |ip| {
                // Check if all bytes except last are zero, and last is 1
                for (ip[0..15]) |b| {
                    if (b != 0) return false;
                }
                return ip[15] == 1;
            },
        };
    }

    /// Returns true if this is a link-local address.
    /// IPv4: 169.254.0.0/16
    /// IPv6: fe80::/10
    pub fn isLinkLocal(self: IpAddr) bool {
        return switch (self) {
            .none => false,
            .v4 => |ip| (ip >> 16) == 0xA9FE,
            .v6 => |ip| ip[0] == 0xFE and (ip[1] & 0xC0) == 0x80,
        };
    }

    /// Returns true if this is the unspecified address (0.0.0.0 or ::) or .none
    pub fn isUnspecified(self: IpAddr) bool {
        return switch (self) {
            .none => true,
            .v4 => |ip| ip == 0,
            .v6 => |ip| {
                for (ip) |b| {
                    if (b != 0) return false;
                }
                return true;
            },
        };
    }

    /// Returns true if this is a broadcast address (IPv4 only).
    /// IPv6 does not have broadcast - uses multicast instead.
    pub fn isBroadcast(self: IpAddr) bool {
        return switch (self) {
            .none => false,
            .v4 => |ip| ip == 0xFFFFFFFF,
            .v6 => false,
        };
    }

    /// Returns true if this is a global unicast address.
    /// Excludes loopback, link-local, multicast, unspecified, and broadcast.
    pub fn isGlobalUnicast(self: IpAddr) bool {
        if (self.isLoopback()) return false;
        if (self.isLinkLocal()) return false;
        if (self.isMulticast()) return false;
        if (self.isUnspecified()) return false;
        if (self.isBroadcast()) return false;
        return true;
    }

    /// For IPv6: Returns the scope of the address.
    /// Returns null for IPv4 or .none.
    pub fn getIpv6Scope(self: IpAddr) ?Ipv6Scope {
        return switch (self) {
            .none => null,
            .v4 => null,
            .v6 => |ip| {
                if (self.isLoopback()) return .InterfaceLocal;
                if (self.isLinkLocal()) return .LinkLocal;
                if (self.isMulticast()) {
                    // Multicast scope is in bits 0-3 of second byte
                    return @enumFromInt(ip[1] & 0x0F);
                }
                // Site-local (deprecated but still recognized): fec0::/10
                if (ip[0] == 0xFE and (ip[1] & 0xC0) == 0xC0) return .SiteLocal;
                return .Global;
            },
        };
    }

    // =========================================================================
    // Comparison
    // =========================================================================

    /// Compare two addresses for equality.
    /// Addresses of different families are never equal.
    /// Two .none values are equal.
    pub fn eql(a: IpAddr, b: IpAddr) bool {
        return switch (a) {
            .none => b == .none,
            .v4 => |av4| switch (b) {
                .none => false,
                .v4 => |bv4| av4 == bv4,
                .v6 => false,
            },
            .v6 => |av6| switch (b) {
                .none => false,
                .v4 => false,
                .v6 => |bv6| std.mem.eql(u8, &av6, &bv6),
            },
        };
    }

    // =========================================================================
    // Conversion
    // =========================================================================

    /// Convert IPv4 address to bytes in network byte order
    pub fn toV4Bytes(self: IpAddr) ?[4]u8 {
        return switch (self) {
            .none => null,
            .v4 => |ip| .{
                @truncate(ip >> 24),
                @truncate(ip >> 16),
                @truncate(ip >> 8),
                @truncate(ip),
            },
            .v6 => null,
        };
    }

    /// Create IpAddr from IPv4 bytes in network byte order
    pub fn fromV4Bytes(bytes: [4]u8) IpAddr {
        const ip: u32 = (@as(u32, bytes[0]) << 24) |
            (@as(u32, bytes[1]) << 16) |
            (@as(u32, bytes[2]) << 8) |
            @as(u32, bytes[3]);
        return .{ .v4 = ip };
    }

    /// Create IpAddr from IPv6 bytes (network byte order)
    pub fn fromV6Bytes(bytes: [16]u8) IpAddr {
        return .{ .v6 = bytes };
    }

    // =========================================================================
    // Formatting
    // =========================================================================

    /// Format IPv4 address to dotted-decimal string.
    /// Returns slice into provided buffer, or null if buffer too small.
    pub fn formatV4(ip: u32, buf: []u8) ?[]u8 {
        if (buf.len < 15) return null; // "255.255.255.255"

        const a: u8 = @truncate(ip >> 24);
        const b: u8 = @truncate(ip >> 16);
        const c: u8 = @truncate(ip >> 8);
        const d: u8 = @truncate(ip);

        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a, b, c, d }) catch null;
    }

    /// Format IPv6 address to colon-hex string.
    /// Does NOT perform :: compression (full format).
    /// Returns slice into provided buffer, or null if buffer too small.
    pub fn formatV6(addr: [16]u8, buf: []u8) ?[]u8 {
        if (buf.len < 39) return null; // "xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx"

        var pos: usize = 0;
        var i: usize = 0;
        while (i < 16) : (i += 2) {
            if (i > 0) {
                buf[pos] = ':';
                pos += 1;
            }
            const word = (@as(u16, addr[i]) << 8) | @as(u16, addr[i + 1]);
            const formatted = std.fmt.bufPrint(buf[pos..], "{x}", .{word}) catch return null;
            pos += formatted.len;
        }
        return buf[0..pos];
    }

    /// Format IPv6 address with :: compression (RFC 5952).
    /// Returns slice into provided buffer, or null if buffer too small.
    pub fn formatV6Compressed(addr: [16]u8, buf: []u8) ?[]u8 {
        if (buf.len < 39) return null;

        // Find longest run of zeros for :: compression
        var words: [8]u16 = undefined;
        for (0..8) |i| {
            words[i] = (@as(u16, addr[i * 2]) << 8) | @as(u16, addr[i * 2 + 1]);
        }

        // Find longest zero run
        var best_start: usize = 8;
        var best_len: usize = 0;
        var current_start: usize = 0;
        var current_len: usize = 0;

        for (0..8) |i| {
            if (words[i] == 0) {
                if (current_len == 0) current_start = i;
                current_len += 1;
            } else {
                if (current_len > best_len and current_len >= 2) {
                    best_start = current_start;
                    best_len = current_len;
                }
                current_len = 0;
            }
        }
        // Check final run
        if (current_len > best_len and current_len >= 2) {
            best_start = current_start;
            best_len = current_len;
        }

        var pos: usize = 0;
        var i: usize = 0;
        while (i < 8) {
            if (i == best_start and best_len > 0) {
                buf[pos] = ':';
                pos += 1;
                if (i == 0) {
                    buf[pos] = ':';
                    pos += 1;
                }
                i += best_len;
                continue;
            }

            if (i > 0 and !(i == best_start + best_len and best_len > 0)) {
                buf[pos] = ':';
                pos += 1;
            }

            const formatted = std.fmt.bufPrint(buf[pos..], "{x}", .{words[i]}) catch return null;
            pos += formatted.len;
            i += 1;
        }

        // Handle trailing ::
        if (best_start + best_len == 8 and best_len > 0) {
            buf[pos] = ':';
            pos += 1;
        }

        return buf[0..pos];
    }

    /// Format this address to a string buffer.
    /// Uses dotted-decimal for IPv4, compressed colon-hex for IPv6.
    /// Returns "*" for .none (unbound).
    pub fn format(self: IpAddr, buf: []u8) ?[]u8 {
        return switch (self) {
            .none => if (buf.len >= 1) blk: {
                buf[0] = '*';
                break :blk buf[0..1];
            } else null,
            .v4 => |ip| formatV4(ip, buf),
            .v6 => |ip| formatV6Compressed(ip, buf),
        };
    }

    // =========================================================================
    // Parsing
    // =========================================================================

    /// Parse dotted-decimal IPv4 address string.
    /// Returns null on invalid input.
    pub fn parseV4(str: []const u8) ?IpAddr {
        var ip: u32 = 0;
        var octet: u32 = 0;
        var dot_count: usize = 0;
        var digit_count: usize = 0;

        for (str) |c| {
            if (c >= '0' and c <= '9') {
                octet = octet * 10 + (c - '0');
                if (octet > 255) return null;
                digit_count += 1;
                if (digit_count > 3) return null;
            } else if (c == '.') {
                if (digit_count == 0) return null; // No digits before dot
                ip = (ip << 8) | octet;
                octet = 0;
                digit_count = 0;
                dot_count += 1;
                if (dot_count > 3) return null;
            } else {
                return null; // Invalid character
            }
        }

        if (dot_count != 3 or digit_count == 0) return null;
        ip = (ip << 8) | octet;
        return .{ .v4 = ip };
    }

    /// Parse colon-hex IPv6 address string.
    /// Supports :: compression and mixed notation (::ffff:192.0.2.1).
    /// Returns null on invalid input.
    pub fn parseV6(str: []const u8) ?IpAddr {
        var result: [16]u8 = [_]u8{0} ** 16;
        var word_idx: usize = 0;
        var double_colon_idx: ?usize = null;
        var current_word: u16 = 0;
        var digit_count: usize = 0;
        var i: usize = 0;

        while (i < str.len) {
            const c = str[i];

            if (c == ':') {
                if (i + 1 < str.len and str[i + 1] == ':') {
                    // Double colon
                    if (double_colon_idx != null) return null; // Only one :: allowed
                    if (digit_count > 0) {
                        if (word_idx >= 8) return null;
                        result[word_idx * 2] = @truncate(current_word >> 8);
                        result[word_idx * 2 + 1] = @truncate(current_word);
                        word_idx += 1;
                    }
                    double_colon_idx = word_idx;
                    current_word = 0;
                    digit_count = 0;
                    i += 2;
                    continue;
                } else {
                    // Single colon
                    if (digit_count == 0 and double_colon_idx == null) return null;
                    if (digit_count > 0) {
                        if (word_idx >= 8) return null;
                        result[word_idx * 2] = @truncate(current_word >> 8);
                        result[word_idx * 2 + 1] = @truncate(current_word);
                        word_idx += 1;
                    }
                    current_word = 0;
                    digit_count = 0;
                    i += 1;
                    continue;
                }
            }

            // Hex digit
            const hex_val: ?u4 = if (c >= '0' and c <= '9')
                @truncate(c - '0')
            else if (c >= 'a' and c <= 'f')
                @truncate(c - 'a' + 10)
            else if (c >= 'A' and c <= 'F')
                @truncate(c - 'A' + 10)
            else
                null;

            if (hex_val) |h| {
                current_word = (current_word << 4) | @as(u16, h);
                digit_count += 1;
                if (digit_count > 4) return null;
                i += 1;
            } else {
                return null; // Invalid character
            }
        }

        // Store final word
        if (digit_count > 0) {
            if (word_idx >= 8) return null;
            result[word_idx * 2] = @truncate(current_word >> 8);
            result[word_idx * 2 + 1] = @truncate(current_word);
            word_idx += 1;
        }

        // Expand :: if present
        if (double_colon_idx) |dci| {
            const words_after = word_idx - dci;
            const words_to_insert = 8 - word_idx;

            // Shift words after :: to their final position
            var j: usize = 7;
            while (j >= dci + words_to_insert) : (j -= 1) {
                const src_idx = j - words_to_insert;
                result[j * 2] = result[src_idx * 2];
                result[j * 2 + 1] = result[src_idx * 2 + 1];
                if (j == dci + words_to_insert) break;
            }

            // Zero the :: region
            for (dci..(dci + words_to_insert)) |k| {
                result[k * 2] = 0;
                result[k * 2 + 1] = 0;
            }
            _ = words_after;
        } else if (word_idx != 8) {
            return null; // Must have exactly 8 words without ::
        }

        return .{ .v6 = result };
    }

    /// Parse an IP address string (auto-detect IPv4 or IPv6).
    /// Returns null on invalid input.
    pub fn parse(str: []const u8) ?IpAddr {
        // Check for IPv6 by looking for ':'
        for (str) |c| {
            if (c == ':') return parseV6(str);
        }
        return parseV4(str);
    }
};

// =============================================================================
// Address Family Constants
// =============================================================================

pub const AF_INET: u16 = 2;
pub const AF_INET6: u16 = 10;

// =============================================================================
// IPv6 Scope (RFC 4007)
// =============================================================================

pub const Ipv6Scope = enum(u4) {
    Reserved0 = 0,
    InterfaceLocal = 1,
    LinkLocal = 2,
    Reserved3 = 3,
    AdminLocal = 4,
    SiteLocal = 5,
    Unassigned6 = 6,
    Unassigned7 = 7,
    OrganizationLocal = 8,
    Unassigned9 = 9,
    Unassigned10 = 10,
    Unassigned11 = 11,
    Unassigned12 = 12,
    Unassigned13 = 13,
    Global = 14,
    Reserved15 = 15,
};

// =============================================================================
// EUI-64 Link-Local Address Generation
// =============================================================================

/// Generate IPv6 link-local address from MAC address using EUI-64.
/// The result is fe80::xxxx:xxff:fexx:xxxx where x comes from the MAC.
pub fn generateLinkLocalFromMac(mac: [6]u8) IpAddr {
    var addr: [16]u8 = [_]u8{0} ** 16;

    // fe80::/10 prefix
    addr[0] = 0xFE;
    addr[1] = 0x80;
    // bytes 2-7 are zero

    // EUI-64: insert FF:FE in middle, flip U/L bit (bit 6 of first byte)
    addr[8] = mac[0] ^ 0x02; // Flip universal/local bit
    addr[9] = mac[1];
    addr[10] = mac[2];
    addr[11] = 0xFF;
    addr[12] = 0xFE;
    addr[13] = mac[3];
    addr[14] = mac[4];
    addr[15] = mac[5];

    return .{ .v6 = addr };
}

/// Generate solicited-node multicast address for NDP.
/// Result is ff02::1:ffXX:XXXX where XX:XXXX are the last 24 bits of the IPv6 address.
pub fn generateSolicitedNodeMulticast(addr: [16]u8) IpAddr {
    var result: [16]u8 = [_]u8{0} ** 16;

    result[0] = 0xFF; // Multicast prefix
    result[1] = 0x02; // Link-local scope
    // bytes 2-10 are zero
    result[11] = 0x01;
    result[12] = 0xFF;
    result[13] = addr[13];
    result[14] = addr[14];
    result[15] = addr[15];

    return .{ .v6 = result };
}

/// Map IPv4 multicast address to Ethernet MAC address.
/// Result is 01:00:5e:XX:XX:XX where XX:XX:XX are the low 23 bits of the IP.
pub fn ipv4MulticastToMac(ip: u32) [6]u8 {
    return .{
        0x01,
        0x00,
        0x5E,
        @truncate((ip >> 16) & 0x7F), // Low 23 bits only
        @truncate(ip >> 8),
        @truncate(ip),
    };
}

/// Map IPv6 multicast address to Ethernet MAC address.
/// Result is 33:33:XX:XX:XX:XX where XX:XX:XX:XX are the last 32 bits of the IPv6 address.
pub fn ipv6MulticastToMac(addr: [16]u8) [6]u8 {
    return .{
        0x33,
        0x33,
        addr[12],
        addr[13],
        addr[14],
        addr[15],
    };
}

// =============================================================================
// Tests
// =============================================================================

test "IpAddr IPv4 classification" {
    const testing = std.testing;

    // Loopback
    try testing.expect(IpAddr.LOOPBACK_V4.isLoopback());
    try testing.expect((IpAddr{ .v4 = 0x7F000001 }).isLoopback());
    try testing.expect((IpAddr{ .v4 = 0x7FFFFFFF }).isLoopback());

    // Multicast
    try testing.expect((IpAddr{ .v4 = 0xE0000001 }).isMulticast()); // 224.0.0.1
    try testing.expect((IpAddr{ .v4 = 0xEFFFFFFF }).isMulticast()); // 239.255.255.255
    try testing.expect(!(IpAddr{ .v4 = 0xF0000000 }).isMulticast()); // 240.0.0.0

    // Link-local
    try testing.expect((IpAddr{ .v4 = 0xA9FE0001 }).isLinkLocal()); // 169.254.0.1
    try testing.expect(!(IpAddr{ .v4 = 0xA9FF0001 }).isLinkLocal()); // 169.255.0.1

    // Broadcast
    try testing.expect(IpAddr.BROADCAST_V4.isBroadcast());
}

test "IpAddr IPv6 classification" {
    const testing = std.testing;

    // Loopback
    try testing.expect(IpAddr.LOOPBACK_V6.isLoopback());

    // Link-local (fe80::/10)
    const link_local = IpAddr{ .v6 = [_]u8{ 0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };
    try testing.expect(link_local.isLinkLocal());

    // Multicast (ff00::/8)
    const multicast = IpAddr{ .v6 = [_]u8{ 0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };
    try testing.expect(multicast.isMulticast());

    // Unspecified
    try testing.expect(IpAddr.UNSPECIFIED_V6.isUnspecified());
}

test "IpAddr parsing" {
    const testing = std.testing;

    // IPv4
    const v4 = IpAddr.parseV4("192.168.1.1");
    try testing.expect(v4 != null);
    try testing.expectEqual(@as(u32, 0xC0A80101), v4.?.v4);

    // IPv4 invalid
    try testing.expect(IpAddr.parseV4("256.1.1.1") == null);
    try testing.expect(IpAddr.parseV4("1.1.1") == null);
    try testing.expect(IpAddr.parseV4("1.1.1.1.1") == null);

    // IPv6
    const v6 = IpAddr.parseV6("2001:db8::1");
    try testing.expect(v6 != null);
    try testing.expectEqual(@as(u8, 0x20), v6.?.v6[0]);
    try testing.expectEqual(@as(u8, 0x01), v6.?.v6[1]);
    try testing.expectEqual(@as(u8, 0x0d), v6.?.v6[2]);
    try testing.expectEqual(@as(u8, 0xb8), v6.?.v6[3]);
    try testing.expectEqual(@as(u8, 0x01), v6.?.v6[15]);

    // Loopback
    const loopback = IpAddr.parseV6("::1");
    try testing.expect(loopback != null);
    try testing.expect(loopback.?.isLoopback());
}

test "IpAddr formatting" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    // IPv4
    const v4 = IpAddr{ .v4 = 0xC0A80101 }; // 192.168.1.1
    const v4_str = v4.format(&buf);
    try testing.expect(v4_str != null);
    try testing.expectEqualStrings("192.168.1.1", v4_str.?);

    // IPv6 loopback
    const v6_str = IpAddr.LOOPBACK_V6.format(&buf);
    try testing.expect(v6_str != null);
    try testing.expectEqualStrings("::1", v6_str.?);
}

test "EUI-64 link-local generation" {
    const testing = std.testing;

    const mac = [6]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    const link_local = generateLinkLocalFromMac(mac);

    try testing.expect(link_local.isV6());
    try testing.expect(link_local.isLinkLocal());

    // Verify EUI-64 structure
    const addr = link_local.v6;
    try testing.expectEqual(@as(u8, 0xFE), addr[0]);
    try testing.expectEqual(@as(u8, 0x80), addr[1]);
    try testing.expectEqual(@as(u8, 0x02), addr[8]); // 0x00 XOR 0x02
    try testing.expectEqual(@as(u8, 0x11), addr[9]);
    try testing.expectEqual(@as(u8, 0x22), addr[10]);
    try testing.expectEqual(@as(u8, 0xFF), addr[11]);
    try testing.expectEqual(@as(u8, 0xFE), addr[12]);
    try testing.expectEqual(@as(u8, 0x33), addr[13]);
    try testing.expectEqual(@as(u8, 0x44), addr[14]);
    try testing.expectEqual(@as(u8, 0x55), addr[15]);
}
