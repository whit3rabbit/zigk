//! DHCP Options Parsing and Encoding (RFC 2132)
//!
//! Handles DHCP option fields in the variable-length options area.

const std = @import("std");
const packet = @import("packet.zig");

// DHCP Option Types (RFC 2132)
pub const OPT_PAD: u8 = 0;
pub const OPT_SUBNET_MASK: u8 = 1;
pub const OPT_ROUTER: u8 = 3;
pub const OPT_DNS_SERVER: u8 = 6;
pub const OPT_HOST_NAME: u8 = 12;
pub const OPT_DOMAIN_NAME: u8 = 15;
pub const OPT_REQUESTED_IP: u8 = 50;
pub const OPT_LEASE_TIME: u8 = 51;
pub const OPT_MSG_TYPE: u8 = 53;
pub const OPT_SERVER_ID: u8 = 54;
pub const OPT_PARAM_REQ: u8 = 55;
pub const OPT_RENEWAL_TIME: u8 = 58;
pub const OPT_REBINDING_TIME: u8 = 59;
pub const OPT_END: u8 = 255;

// DHCP Message Types (RFC 2132)
pub const DHCPDISCOVER: u8 = 1;
pub const DHCPOFFER: u8 = 2;
pub const DHCPREQUEST: u8 = 3;
pub const DHCPDECLINE: u8 = 4;
pub const DHCPACK: u8 = 5;
pub const DHCPNAK: u8 = 6;
pub const DHCPRELEASE: u8 = 7;
pub const DHCPINFORM: u8 = 8;

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
pub fn getRenewalTime(pkt: *const packet.DhcpPacket, lease_time: u32) u32 {
    const t1 = getOption(u32, &pkt.options, OPT_RENEWAL_TIME);
    if (t1) |val| {
        return @byteSwap(val);
    }
    // Default T1 = 0.5 * lease time (RFC 2131)
    return lease_time / 2;
}

/// Get T2 (rebinding) time in seconds
pub fn getRebindingTime(pkt: *const packet.DhcpPacket, lease_time: u32) u32 {
    const t2 = getOption(u32, &pkt.options, OPT_REBINDING_TIME);
    if (t2) |val| {
        return @byteSwap(val);
    }
    // Default T2 = 0.875 * lease time (RFC 2131)
    return (lease_time * 7) / 8;
}

/// Generic option getter
/// SECURITY NOTE: Arithmetic safety analysis for `i += 2 + len`:
/// - opts.len is fixed at 312 bytes (compile-time constant)
/// - len is u8, max value 255
/// - Line 98 bounds check ensures i + 2 + len <= 312 before we reach line 105
/// - Therefore i + 2 + len is bounded to [0, 312], cannot overflow on any arch
/// - Each option is O(312) worst case; fixed array bounds total work per packet
fn getOption(comptime T: type, opts: *const [312]u8, opt_type: u8) ?T {
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
pub fn buildDiscoverOptions(opts: *[312]u8) void {
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
pub fn buildRequestOptions(opts: *[312]u8, requested_ip: u32, server_id: u32) void {
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
pub fn buildRenewalOptions(opts: *[312]u8) void {
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
