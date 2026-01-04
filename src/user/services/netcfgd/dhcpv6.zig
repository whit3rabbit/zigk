//! DHCPv6 Client Implementation (RFC 8415)
//!
//! Implements stateful IPv6 address configuration when the M-flag
//! is set in Router Advertisements.
//!
//! State Machine:
//! WAITING -> SOLICIT -> REQUEST -> BOUND -> RENEW -> REBIND
//!
//! Security:
//! - Transaction ID from getrandom() to prevent spoofing
//! - DUID-LL generation from MAC address
//! - Zero-initialized packets

const std = @import("std");
const syscall = @import("syscall");
const net = syscall.net;

const packet = @import("packet.zig");

/// DHCPv6 client states
pub const Dhcpv6State = enum {
    /// Waiting for M-flag in RA
    Waiting,
    /// Sending SOLICIT to discover servers
    Solicit,
    /// Sending REQUEST for address
    Request,
    /// Address configured, monitoring lifetime
    Bound,
    /// T1 expired, unicasting RENEW
    Renew,
    /// T2 expired, broadcasting REBIND
    Rebind,
};

/// DHCPv6 client context
pub const Dhcpv6Client = struct {
    /// Client hardware address (MAC)
    mac_addr: [6]u8,
    /// Current state
    state: Dhcpv6State,
    /// Transaction ID (24 bits)
    xid: u24,
    /// UDP socket for DHCPv6 messages
    socket_fd: i32,
    /// Client DUID
    duid: [10]u8,
    duid_len: usize,
    /// Server DUID (from ADVERTISE)
    server_duid: [128]u8,
    server_duid_len: usize,
    /// Assigned IPv6 address
    assigned_addr: [16]u8,
    prefix_len: u8,
    /// Lease times
    valid_lifetime: u32,
    preferred_lifetime: u32,
    /// Tick when address was assigned
    assign_tick: u64,

    const Self = @This();

    // DHCPv6 ports
    const CLIENT_PORT: u16 = 546;
    const SERVER_PORT: u16 = 547;

    // All DHCP Servers multicast address (ff02::1:2)
    const ALL_DHCP_SERVERS: [16]u8 = .{
        0xFF, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02,
    };

    /// Initialize DHCPv6 client
    /// SECURITY NOTE on undefined fields:
    /// - duid: Immediately fully written by generateDuidLl() before any use - safe
    /// - server_duid: DHCPv6 implementation is incomplete (all TODOs), never used.
    ///   When implementing, zero-init or ensure full write before send.
    pub fn init(mac: [6]u8) Self {
        var client = Self{
            .mac_addr = mac,
            .state = .Waiting,
            .xid = generateXid(),
            .socket_fd = -1,
            // Safe: fully written by generateDuidLl() before any use
            .duid = undefined,
            .duid_len = 0,
            // TODO: Zero-init when DHCPv6 ADVERTISE parsing is implemented
            .server_duid = undefined,
            .server_duid_len = 0,
            .assigned_addr = [_]u8{0} ** 16,
            .prefix_len = 0,
            .valid_lifetime = 0,
            .preferred_lifetime = 0,
            .assign_tick = 0,
        };

        // Generate DUID-LL (RFC 8415 Section 11.4)
        // Fully writes duid[0..10] before any network use
        client.generateDuidLl();

        return client;
    }

    /// Generate DUID-LL from MAC address
    fn generateDuidLl(self: *Self) void {
        // DUID-LL format:
        // 2 bytes: DUID type (3 = DUID-LL)
        // 2 bytes: Hardware type (1 = Ethernet)
        // 6 bytes: Link-layer address (MAC)
        self.duid[0] = 0x00; // Type high byte
        self.duid[1] = 0x03; // Type low byte (DUID-LL)
        self.duid[2] = 0x00; // Hardware type high byte
        self.duid[3] = 0x01; // Hardware type low byte (Ethernet)
        @memcpy(self.duid[4..10], &self.mac_addr);
        self.duid_len = 10;
    }

    /// Get timeout until next action
    pub fn getNextTimeout(self: *const Self) u64 {
        _ = self;
        // TODO: Implement proper timeout calculation
        return 5000; // 5 second default
    }

    /// Main processing function - call periodically
    pub fn process(self: *Self, iface_idx: u32) void {
        switch (self.state) {
            .Waiting => self.checkMFlag(iface_idx),
            .Solicit => self.handleSolicit(),
            .Request => self.handleRequest(),
            .Bound => self.handleBound(),
            .Renew => self.handleRenew(),
            .Rebind => self.handleRebind(),
        }
    }

    fn checkMFlag(self: *Self, iface_idx: u32) void {
        // Check if M-flag is set in RA
        const ra_info = net.getRaInfo(iface_idx) catch {
            return;
        };

        if (ra_info.isManagedFlag()) {
            syscall.print("dhcpv6: M-flag detected, starting SOLICIT\n");
            self.state = .Solicit;
            self.xid = generateXid();
            self.doSolicit();
        }
    }

    fn doSolicit(self: *Self) void {
        syscall.print("dhcpv6: Sending SOLICIT\n");
        // TODO: Implement SOLICIT packet construction and sending
        _ = self;
    }

    fn handleSolicit(self: *Self) void {
        // TODO: Wait for ADVERTISE, then send REQUEST
        _ = self;
    }

    fn handleRequest(self: *Self) void {
        // TODO: Wait for REPLY
        _ = self;
    }

    fn handleBound(self: *Self) void {
        // TODO: Check if T1 has expired
        _ = self;
    }

    fn handleRenew(self: *Self) void {
        // TODO: Unicast RENEW to server
        _ = self;
    }

    fn handleRebind(self: *Self) void {
        // TODO: Multicast REBIND
        _ = self;
    }
};

/// Generate cryptographically random transaction ID.
/// SECURITY: XID must be unpredictable to prevent DHCPv6 spoofing attacks.
/// With only 24 bits, a weak fallback would be trivially brute-forceable.
/// Uses getSecureRandom() which handles partial reads, EINTR, and panics on failure.
fn generateXid() u24 {
    var buf: [3]u8 = undefined;
    syscall.getSecureRandom(&buf);
    // Read 24-bit value (little-endian)
    return @as(u24, buf[0]) | (@as(u24, buf[1]) << 8) | (@as(u24, buf[2]) << 16);
}
