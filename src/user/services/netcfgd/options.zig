//! DHCP Options Parsing and Encoding
//!
//! RFC 2132 - DHCP Options and BOOTP Vendor Extensions
//!
//! Handles DHCP option fields in the variable-length options area
//! following the BOOTP vendor extensions format (RFC 1497).
//!
//! Option Format (RFC 2132 Section 2):
//!   - Code (1 byte): Option type
//!   - Length (1 byte): Length of data (not present for PAD/END)
//!   - Data (variable): Option-specific data
//!
//! Options area starts after the 4-byte magic cookie (0x63825363).

const std = @import("std");
const packet = @import("packet.zig");

// =============================================================================
// DHCP Option Types (RFC 2132)
// =============================================================================

// RFC 2132 Section 3.1: Pad Option - used for alignment
pub const OPT_PAD: u8 = 0;
// RFC 2132 Section 3.3: Subnet Mask - 4 bytes
pub const OPT_SUBNET_MASK: u8 = 1;
// RFC 2132 Section 3.5: Router - list of router addresses
pub const OPT_ROUTER: u8 = 3;
// RFC 2132 Section 3.8: Domain Name Server - list of DNS addresses
pub const OPT_DNS_SERVER: u8 = 6;
// RFC 2132 Section 3.14: Host Name
pub const OPT_HOST_NAME: u8 = 12;
// RFC 2132 Section 3.17: Domain Name
pub const OPT_DOMAIN_NAME: u8 = 15;
// RFC 2132 Section 9.1: Requested IP Address - for SELECTING state
pub const OPT_REQUESTED_IP: u8 = 50;
// RFC 2132 Section 9.2: IP Address Lease Time - in seconds
pub const OPT_LEASE_TIME: u8 = 51;
// RFC 2132 Section 9.6: DHCP Message Type
pub const OPT_MSG_TYPE: u8 = 53;
// RFC 2132 Section 9.7: Server Identifier - server's IP
pub const OPT_SERVER_ID: u8 = 54;
// RFC 2132 Section 9.8: Parameter Request List
pub const OPT_PARAM_REQ: u8 = 55;
// RFC 2132 Section 9.11: Renewal (T1) Time Value
pub const OPT_RENEWAL_TIME: u8 = 58;
// RFC 2132 Section 9.12: Rebinding (T2) Time Value
pub const OPT_REBINDING_TIME: u8 = 59;
// RFC 2132 Section 3.2: End Option - terminates options
pub const OPT_END: u8 = 255;

// =============================================================================
// DHCP Message Types (RFC 2132 Section 9.6)
// =============================================================================

pub const DHCPDISCOVER: u8 = 1; // Client broadcast to locate servers
pub const DHCPOFFER: u8 = 2; // Server response to DISCOVER
pub const DHCPREQUEST: u8 = 3; // Client message to servers
pub const DHCPDECLINE: u8 = 4; // Client indicates address already in use
pub const DHCPACK: u8 = 5; // Server acknowledges REQUEST
pub const DHCPNAK: u8 = 6; // Server refuses REQUEST
pub const DHCPRELEASE: u8 = 7; // Client relinquishes lease
pub const DHCPINFORM: u8 = 8; // Client requests local config only

/// Get message type from DHCP packet options
pub fn getMsgType(pkt: *const packet.DhcpPacket) u8 {
    return getOption(u8, &pkt.options, OPT_MSG_TYPE) orelse 0;
}

/// Get server identifier from options
pub fn getServerId(pkt: *const packet.DhcpPacket) u32 {
    return getOption(u32, &pkt.options, OPT_SERVER_ID) orelse 0;
}

/// Get subnet mask from options
pub fn getSubnetMask(pkt: *const packet.DhcpPacket) u32 {
    const mask = getOption(u32, &pkt.options, OPT_SUBNET_MASK) orelse 0xFFFFFF00;
    return @byteSwap(mask);
}

/// Get router/gateway from options
pub fn getRouter(pkt: *const packet.DhcpPacket) u32 {
    const router = getOption(u32, &pkt.options, OPT_ROUTER) orelse 0;
    return @byteSwap(router);
}

/// Get lease time in seconds
pub fn getLeaseTime(pkt: *const packet.DhcpPacket) u32 {
    const lease = getOption(u32, &pkt.options, OPT_LEASE_TIME) orelse 86400;
    return @byteSwap(lease);
}

/// Get T1 (renewal) time in seconds
///
/// RFC 2131 Section 4.4.5:
/// "T1 defaults to (0.5 * duration_of_lease)"
/// T1 is when the client transitions from BOUND to RENEWING state.
pub fn getRenewalTime(pkt: *const packet.DhcpPacket, lease_time: u32) u32 {
    const t1 = getOption(u32, &pkt.options, OPT_RENEWAL_TIME);
    if (t1) |val| {
        return @byteSwap(val);
    }
    // RFC 2131 Section 4.4.5: Default T1 = 0.5 * lease time
    return lease_time / 2;
}

/// Get T2 (rebinding) time in seconds
///
/// RFC 2131 Section 4.4.5:
/// "T2 defaults to (0.875 * duration_of_lease)"
/// T2 is when the client transitions from RENEWING to REBINDING state.
pub fn getRebindingTime(pkt: *const packet.DhcpPacket, lease_time: u32) u32 {
    const t2 = getOption(u32, &pkt.options, OPT_REBINDING_TIME);
    if (t2) |val| {
        return @byteSwap(val);
    }
    // RFC 2131 Section 4.4.5: Default T2 = 0.875 * lease time (7/8)
    return (lease_time * 7) / 8;
}

/// Generic option getter
/// SECURITY NOTE: Arithmetic safety analysis for `i += 2 + len`:
/// - opts.len is fixed at 308 bytes (compile-time constant)
/// - len is u8, max value 255
/// - Line 98 bounds check ensures i + 2 + len <= 308 before we reach line 105
/// - Therefore i + 2 + len is bounded to [0, 308], cannot overflow on any arch
/// - Each option is O(308) worst case; fixed array bounds total work per packet
fn getOption(comptime T: type, opts: *const [308]u8, opt_type: u8) ?T {
    var i: usize = 0;

    while (i < opts.len) {
        const opt = opts[i];

        if (opt == OPT_END) break;
        if (opt == OPT_PAD) {
            i += 1;
            continue;
        }

        if (i + 1 >= opts.len) break;
        const len = opts[i + 1];

        // SECURITY: Bounds check before advancing - ensures i + 2 + len <= 312
        if (i + 2 + len > opts.len) break;

        if (opt == opt_type and len == @sizeOf(T)) {
            const data = opts[i + 2 .. i + 2 + @sizeOf(T)];
            return std.mem.bytesToValue(T, data[0..@sizeOf(T)]);
        }

        // Safe: bounded by check above
        i += 2 + len;
    }

    return null;
}

// =============================================================================
// Option Building
// =============================================================================

/// Build options for DHCPDISCOVER
pub fn buildDiscoverOptions(opts: *[308]u8) void {
    var i: usize = 0;

    // Message type
    opts[i] = OPT_MSG_TYPE;
    opts[i + 1] = 1;
    opts[i + 2] = DHCPDISCOVER;
    i += 3;

    // Parameter request list
    opts[i] = OPT_PARAM_REQ;
    opts[i + 1] = 4;
    opts[i + 2] = OPT_SUBNET_MASK;
    opts[i + 3] = OPT_ROUTER;
    opts[i + 4] = OPT_DNS_SERVER;
    opts[i + 5] = OPT_DOMAIN_NAME;
    i += 6;

    // End
    opts[i] = OPT_END;
}

/// Build options for DHCPREQUEST
pub fn buildRequestOptions(opts: *[308]u8, requested_ip: u32, server_id: u32) void {
    var i: usize = 0;

    // Message type
    opts[i] = OPT_MSG_TYPE;
    opts[i + 1] = 1;
    opts[i + 2] = DHCPREQUEST;
    i += 3;

    // Server identifier
    opts[i] = OPT_SERVER_ID;
    opts[i + 1] = 4;
    const server_bytes = std.mem.toBytes(@byteSwap(server_id));
    @memcpy(opts[i + 2 .. i + 6], &server_bytes);
    i += 6;

    // Requested IP
    opts[i] = OPT_REQUESTED_IP;
    opts[i + 1] = 4;
    const ip_bytes = std.mem.toBytes(@byteSwap(requested_ip));
    @memcpy(opts[i + 2 .. i + 6], &ip_bytes);
    i += 6;

    // Parameter request list
    opts[i] = OPT_PARAM_REQ;
    opts[i + 1] = 4;
    opts[i + 2] = OPT_SUBNET_MASK;
    opts[i + 3] = OPT_ROUTER;
    opts[i + 4] = OPT_DNS_SERVER;
    opts[i + 5] = OPT_DOMAIN_NAME;
    i += 6;

    // End
    opts[i] = OPT_END;
}

/// Build options for renewal REQUEST
pub fn buildRenewalOptions(opts: *[308]u8) void {
    var i: usize = 0;

    // Message type
    opts[i] = OPT_MSG_TYPE;
    opts[i + 1] = 1;
    opts[i + 2] = DHCPREQUEST;
    i += 3;

    // Parameter request list
    opts[i] = OPT_PARAM_REQ;
    opts[i + 1] = 4;
    opts[i + 2] = OPT_SUBNET_MASK;
    opts[i + 3] = OPT_ROUTER;
    opts[i + 4] = OPT_DNS_SERVER;
    opts[i + 5] = OPT_DOMAIN_NAME;
    i += 6;

    // End
    opts[i] = OPT_END;
}

/// Build options for DHCPDECLINE (RFC 2131 Section 4.4.4)
/// Sent when client detects IP conflict via ARP probe.
pub fn buildDeclineOptions(opts: *[308]u8, declined_ip: u32, server_id: u32) void {
    var i: usize = 0;

    // Message type = DHCPDECLINE
    opts[i] = OPT_MSG_TYPE;
    opts[i + 1] = 1;
    opts[i + 2] = DHCPDECLINE;
    i += 3;

    // Server identifier (required)
    opts[i] = OPT_SERVER_ID;
    opts[i + 1] = 4;
    const server_bytes = @import("std").mem.toBytes(@byteSwap(server_id));
    @memcpy(opts[i + 2 .. i + 6], &server_bytes);
    i += 6;

    // Requested IP (the one we're declining)
    opts[i] = OPT_REQUESTED_IP;
    opts[i + 1] = 4;
    const ip_bytes = @import("std").mem.toBytes(@byteSwap(declined_ip));
    @memcpy(opts[i + 2 .. i + 6], &ip_bytes);
    i += 6;

    // End
    opts[i] = OPT_END;
}

/// Build options for DHCPRELEASE (RFC 2131 Section 4.4.6)
/// Sent when client voluntarily releases its lease.
pub fn buildReleaseOptions(opts: *[308]u8, server_id: u32) void {
    var i: usize = 0;

    // Message type = DHCPRELEASE
    opts[i] = OPT_MSG_TYPE;
    opts[i + 1] = 1;
    opts[i + 2] = DHCPRELEASE;
    i += 3;

    // Server identifier (required)
    opts[i] = OPT_SERVER_ID;
    opts[i + 1] = 4;
    const server_bytes = @import("std").mem.toBytes(@byteSwap(server_id));
    @memcpy(opts[i + 2 .. i + 6], &server_bytes);
    i += 6;

    // End
    opts[i] = OPT_END;
}
