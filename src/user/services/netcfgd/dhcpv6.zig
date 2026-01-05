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
const options = @import("dhcpv6_options.zig");
const lease6 = @import("lease6.zig");

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
    /// IPv6 lease info
    lease: lease6.Lease6Info,
    /// Interface index
    iface_idx: u32,
    /// IAID (Identity Association ID) - derived from interface
    iaid: u32,
    /// Retransmit counter
    retransmit_count: u8,
    /// Last send tick (for retransmit timing)
    last_send_tick: u64,
    /// Elapsed time since start of exchange (centiseconds)
    elapsed_cs: u16,
    /// Start tick for elapsed time calculation
    exchange_start_tick: u64,
    /// Rapid Commit supported (2-message exchange)
    rapid_commit: bool,
    /// Receive buffer
    rx_buf: [1024]u8,

    const Self = @This();

    // DHCPv6 ports
    pub const CLIENT_PORT: u16 = 546;
    pub const SERVER_PORT: u16 = 547;

    // All DHCP Servers multicast address (ff02::1:2)
    pub const ALL_DHCP_SERVERS: [16]u8 = .{
        0xFF, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02,
    };

    // RFC 8415 retransmit timers (milliseconds)
    const SOL_MAX_DELAY: u64 = 1000; // 1s random delay
    const SOL_TIMEOUT: u64 = 1000; // 1s initial
    const SOL_MAX_RT: u64 = 3600000; // 1 hour max
    const REQ_TIMEOUT: u64 = 1000;
    const REQ_MAX_RC: u8 = 10; // Max retransmit count
    const REN_TIMEOUT: u64 = 10000; // 10s
    const REB_TIMEOUT: u64 = 10000; // 10s

    /// Initialize DHCPv6 client
    pub fn init(mac: [6]u8, iface_idx: u32) Self {
        var client = Self{
            .mac_addr = mac,
            .state = .Waiting,
            .xid = generateXid(),
            .socket_fd = -1,
            .duid = undefined,
            .duid_len = 0,
            .lease = lease6.Lease6Info.init(),
            .iface_idx = iface_idx,
            .iaid = deriveIaid(mac),
            .retransmit_count = 0,
            .last_send_tick = 0,
            .elapsed_cs = 0,
            .exchange_start_tick = 0,
            .rapid_commit = true, // Request Rapid Commit by default
            .rx_buf = [_]u8{0} ** 1024,
        };

        // Generate DUID-LL (RFC 8415 Section 11.4)
        client.generateDuidLl();

        return client;
    }

    /// Derive IAID from MAC address (use last 4 bytes)
    fn deriveIaid(mac: [6]u8) u32 {
        return @as(u32, mac[2]) << 24 |
            @as(u32, mac[3]) << 16 |
            @as(u32, mac[4]) << 8 |
            @as(u32, mac[5]);
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

    /// Create and bind DHCPv6 socket
    pub fn createSocket(self: *Self) !void {
        if (self.socket_fd >= 0) return; // Already created

        const fd = try net.socket(net.AF_INET6, net.SOCK_DGRAM, 0);
        errdefer syscall.close(fd) catch {};

        // Bind to client port (546)
        const bind_addr = net.SockAddrIn6.init([_]u8{0} ** 16, CLIENT_PORT);
        try net.bind6(fd, &bind_addr);

        // Join All_DHCP_Servers multicast group (ff02::1:2)
        try net.joinMulticastGroup6(fd, ALL_DHCP_SERVERS, self.iface_idx);

        self.socket_fd = fd;
    }

    /// Close socket
    pub fn closeSocket(self: *Self) void {
        if (self.socket_fd >= 0) {
            syscall.close(self.socket_fd) catch {};
            self.socket_fd = -1;
        }
    }

    /// Get timeout until next action (milliseconds)
    pub fn getNextTimeout(self: *const Self) u64 {
        return switch (self.state) {
            .Waiting => 1000,
            .Solicit => SOL_TIMEOUT,
            .Request => REQ_TIMEOUT,
            .Bound => 60000, // Check every minute
            .Renew => REN_TIMEOUT,
            .Rebind => REB_TIMEOUT,
        };
    }

    /// Main processing function - call periodically
    pub fn process(self: *Self, current_tick: u64) void {
        switch (self.state) {
            .Waiting => self.checkMFlag(),
            .Solicit => self.handleSolicit(current_tick),
            .Request => self.handleRequest(current_tick),
            .Bound => self.handleBound(current_tick),
            .Renew => self.handleRenew(current_tick),
            .Rebind => self.handleRebind(current_tick),
        }
    }

    fn checkMFlag(self: *Self) void {
        // Check if M-flag is set in RA
        const ra_info = net.getRaInfo(self.iface_idx) catch {
            return;
        };

        if (ra_info.isManagedFlag()) {
            syscall.print("dhcpv6: M-flag detected, starting SOLICIT\n");
            self.startSolicit();
        }
    }

    /// Start SOLICIT exchange
    pub fn startSolicit(self: *Self) void {
        self.state = .Solicit;
        self.xid = generateXid();
        self.retransmit_count = 0;
        self.exchange_start_tick = 0; // Will be set on first send
        self.elapsed_cs = 0;

        // Create socket if needed
        self.createSocket() catch {
            syscall.print("dhcpv6: Failed to create socket\n");
            self.state = .Waiting;
            return;
        };

        self.sendSolicit();
    }

    fn sendSolicit(self: *Self) void {
        var tx_buf: [512]u8 = [_]u8{0} ** 512;
        var pos: usize = 0;

        // DHCPv6 header (4 bytes)
        const hdr = packet.Dhcpv6Header.init(.Solicit, self.xid);
        @memcpy(tx_buf[pos..][0..4], std.mem.asBytes(&hdr));
        pos += 4;

        // Client ID option
        pos += options.writeClientId(tx_buf[pos..], self.mac_addr);

        // IA_NA option
        pos += options.writeIaNa(tx_buf[pos..], self.iaid);

        // Elapsed Time option
        pos += options.writeElapsedTime(tx_buf[pos..], self.elapsed_cs);

        // Option Request Option (request DNS servers)
        const requested = [_]u16{ options.OPT_DNS_SERVERS, options.OPT_DOMAIN_LIST };
        pos += options.writeOro(tx_buf[pos..], &requested);

        // Rapid Commit option (if enabled)
        if (self.rapid_commit) {
            pos += options.writeRapidCommit(tx_buf[pos..]);
        }

        // Send to All_DHCP_Servers
        const dest = net.SockAddrIn6.init(ALL_DHCP_SERVERS, SERVER_PORT);
        _ = net.sendto6(self.socket_fd, tx_buf[0..pos], &dest) catch {
            syscall.print("dhcpv6: Failed to send SOLICIT\n");
            return;
        };

        self.retransmit_count += 1;
    }

    fn handleSolicit(self: *Self, current_tick: u64) void {
        // Try to receive ADVERTISE or REPLY (Rapid Commit)
        var src_addr: net.SockAddrIn6 = undefined;
        const rx_len = net.recvfrom6(self.socket_fd, &self.rx_buf, &src_addr) catch {
            // No packet, check retransmit
            if (self.retransmit_count < 3) {
                self.sendSolicit();
            }
            return;
        };

        if (rx_len < 4) return; // Too short

        // Parse header
        const hdr: *const packet.Dhcpv6Header = @ptrCast(@alignCast(&self.rx_buf));
        const msg_type = hdr.getMsgType();
        const rx_xid = hdr.getTransactionId();

        // Validate XID
        if (rx_xid != self.xid) return;

        if (msg_type == @intFromEnum(packet.Dhcpv6MsgType.Reply)) {
            // Rapid Commit - got REPLY directly
            if (self.processReply(self.rx_buf[4..rx_len], current_tick)) {
                syscall.print("dhcpv6: Rapid Commit successful\n");
            }
        } else if (msg_type == @intFromEnum(packet.Dhcpv6MsgType.Advertise)) {
            // Normal flow - got ADVERTISE, send REQUEST
            if (self.processAdvertise(self.rx_buf[4..rx_len])) {
                self.state = .Request;
                self.xid = generateXid();
                self.retransmit_count = 0;
                self.sendRequest();
            }
        }
    }

    fn processAdvertise(self: *Self, opts_data: []const u8) bool {
        var iter = options.OptionsIterator.init(opts_data);

        // Extract Server ID
        if (iter.find(options.OPT_SERVERID)) |server_id| {
            self.lease.setServerDuid(server_id.data);
        } else {
            return false; // No Server ID
        }

        iter.reset();

        // Extract IA_NA with IA_ADDR
        if (iter.find(options.OPT_IA_NA)) |ia_na_opt| {
            if (options.parseIaNa(ia_na_opt.data)) |ia_na| {
                // Check for status code error
                if (options.checkStatusCode(ia_na.options_data)) |status| {
                    syscall.print("dhcpv6: ADVERTISE status error\n");
                    _ = status;
                    return false;
                }

                // Extract IA_ADDR
                if (options.extractIaAddrFromIaNa(ia_na)) |ia_addr| {
                    self.lease.addr = ia_addr.addr;
                    self.lease.preferred_lifetime = ia_addr.preferred_lifetime;
                    self.lease.valid_lifetime = ia_addr.valid_lifetime;
                    self.lease.t1 = ia_na.t1;
                    self.lease.t2 = ia_na.t2;
                    self.lease.iaid = ia_na.iaid;
                    return true;
                }
            }
        }

        return false;
    }

    fn sendRequest(self: *Self) void {
        var tx_buf: [512]u8 = [_]u8{0} ** 512;
        var pos: usize = 0;

        // DHCPv6 header
        const hdr = packet.Dhcpv6Header.init(.Request, self.xid);
        @memcpy(tx_buf[pos..][0..4], std.mem.asBytes(&hdr));
        pos += 4;

        // Client ID option
        pos += options.writeClientId(tx_buf[pos..], self.mac_addr);

        // Server ID option (from ADVERTISE)
        pos += options.writeServerId(tx_buf[pos..], self.lease.getServerDuid());

        // IA_NA with the address we want
        pos += options.writeIaNaWithAddr(
            tx_buf[pos..],
            self.iaid,
            self.lease.addr,
            self.lease.preferred_lifetime,
            self.lease.valid_lifetime,
        );

        // Elapsed Time
        pos += options.writeElapsedTime(tx_buf[pos..], self.elapsed_cs);

        // Option Request
        const requested = [_]u16{ options.OPT_DNS_SERVERS, options.OPT_DOMAIN_LIST };
        pos += options.writeOro(tx_buf[pos..], &requested);

        // Send to All_DHCP_Servers
        const dest = net.SockAddrIn6.init(ALL_DHCP_SERVERS, SERVER_PORT);
        _ = net.sendto6(self.socket_fd, tx_buf[0..pos], &dest) catch {
            syscall.print("dhcpv6: Failed to send REQUEST\n");
            return;
        };

        self.retransmit_count += 1;
    }

    fn handleRequest(self: *Self, current_tick: u64) void {
        // Try to receive REPLY
        var src_addr: net.SockAddrIn6 = undefined;
        const rx_len = net.recvfrom6(self.socket_fd, &self.rx_buf, &src_addr) catch {
            // No packet, check retransmit
            if (self.retransmit_count < REQ_MAX_RC) {
                self.sendRequest();
            } else {
                // Max retries, restart
                syscall.print("dhcpv6: REQUEST timeout, restarting\n");
                self.state = .Solicit;
            }
            return;
        };

        if (rx_len < 4) return;

        const hdr: *const packet.Dhcpv6Header = @ptrCast(@alignCast(&self.rx_buf));
        if (hdr.getMsgType() != @intFromEnum(packet.Dhcpv6MsgType.Reply)) return;
        if (hdr.getTransactionId() != self.xid) return;

        _ = self.processReply(self.rx_buf[4..rx_len], current_tick);
    }

    fn processReply(self: *Self, opts_data: []const u8, current_tick: u64) bool {
        var iter = options.OptionsIterator.init(opts_data);

        // Extract Server ID
        if (iter.find(options.OPT_SERVERID)) |server_id| {
            self.lease.setServerDuid(server_id.data);
        }

        iter.reset();

        // Extract IA_NA with IA_ADDR
        if (iter.find(options.OPT_IA_NA)) |ia_na_opt| {
            if (options.parseIaNa(ia_na_opt.data)) |ia_na| {
                // Check for status code error
                if (options.checkStatusCode(ia_na.options_data)) |status| {
                    syscall.print("dhcpv6: REPLY status error\n");
                    _ = status;
                    return false;
                }

                // Extract IA_ADDR
                if (options.extractIaAddrFromIaNa(ia_na)) |ia_addr| {
                    // Calculate T1/T2 defaults if server sent 0
                    var t1 = ia_na.t1;
                    var t2 = ia_na.t2;
                    if (t1 == 0 or t2 == 0) {
                        const defaults = lease6.calculateDefaultTimers(ia_addr.preferred_lifetime);
                        if (t1 == 0) t1 = defaults.t1;
                        if (t2 == 0) t2 = defaults.t2;
                    }

                    // Record lease
                    self.lease.recordLease(
                        ia_addr.addr,
                        ia_na.iaid,
                        t1,
                        t2,
                        ia_addr.preferred_lifetime,
                        ia_addr.valid_lifetime,
                        current_tick,
                    );

                    // Configure address on interface
                    self.configureAddress();

                    self.state = .Bound;
                    syscall.print("dhcpv6: Address configured, BOUND\n");
                    return true;
                }
            }
        }

        return false;
    }

    fn configureAddress(self: *Self) void {
        // Add IPv6 address to interface
        net.addIpv6Address(
            self.iface_idx,
            self.lease.addr,
            128, // /128 for single address
            0, // global scope
        ) catch {
            syscall.print("dhcpv6: Failed to configure address\n");
        };
    }

    fn handleBound(self: *Self, current_tick: u64) void {
        // Update lease state
        self.lease.updateState(current_tick, 1000); // 1000 ticks/sec

        switch (self.lease.state) {
            .Renewing => {
                syscall.print("dhcpv6: T1 expired, starting RENEW\n");
                self.state = .Renew;
                self.xid = generateXid();
                self.retransmit_count = 0;
                self.sendRenew();
            },
            .Rebinding => {
                syscall.print("dhcpv6: T2 expired, starting REBIND\n");
                self.state = .Rebind;
                self.xid = generateXid();
                self.retransmit_count = 0;
                self.sendRebind();
            },
            .Expired => {
                syscall.print("dhcpv6: Lease expired, restarting\n");
                self.lease.clear();
                self.state = .Waiting;
            },
            else => {},
        }
    }

    fn sendRenew(self: *Self) void {
        var tx_buf: [512]u8 = [_]u8{0} ** 512;
        var pos: usize = 0;

        const hdr = packet.Dhcpv6Header.init(.Renew, self.xid);
        @memcpy(tx_buf[pos..][0..4], std.mem.asBytes(&hdr));
        pos += 4;

        pos += options.writeClientId(tx_buf[pos..], self.mac_addr);
        pos += options.writeServerId(tx_buf[pos..], self.lease.getServerDuid());
        pos += options.writeIaNaWithAddr(
            tx_buf[pos..],
            self.iaid,
            self.lease.addr,
            self.lease.preferred_lifetime,
            self.lease.valid_lifetime,
        );
        pos += options.writeElapsedTime(tx_buf[pos..], self.elapsed_cs);

        // RENEW is unicast to server (if we have server address)
        // For simplicity, multicast for now
        const dest = net.SockAddrIn6.init(ALL_DHCP_SERVERS, SERVER_PORT);
        _ = net.sendto6(self.socket_fd, tx_buf[0..pos], &dest) catch {};

        self.retransmit_count += 1;
    }

    fn handleRenew(self: *Self, current_tick: u64) void {
        // Try to receive REPLY
        var src_addr: net.SockAddrIn6 = undefined;
        const rx_len = net.recvfrom6(self.socket_fd, &self.rx_buf, &src_addr) catch {
            // Check if T2 expired (switch to REBIND)
            self.lease.updateState(current_tick, 1000);
            if (self.lease.state == .Rebinding or self.lease.state == .Expired) {
                self.state = if (self.lease.state == .Expired) .Waiting else .Rebind;
                return;
            }
            // Retransmit
            self.sendRenew();
            return;
        };

        if (rx_len < 4) return;

        const hdr: *const packet.Dhcpv6Header = @ptrCast(@alignCast(&self.rx_buf));
        if (hdr.getMsgType() != @intFromEnum(packet.Dhcpv6MsgType.Reply)) return;
        if (hdr.getTransactionId() != self.xid) return;

        if (self.processRenewalReply(self.rx_buf[4..rx_len], current_tick)) {
            self.state = .Bound;
            syscall.print("dhcpv6: RENEW successful\n");
        }
    }

    fn sendRebind(self: *Self) void {
        var tx_buf: [512]u8 = [_]u8{0} ** 512;
        var pos: usize = 0;

        const hdr = packet.Dhcpv6Header.init(.Rebind, self.xid);
        @memcpy(tx_buf[pos..][0..4], std.mem.asBytes(&hdr));
        pos += 4;

        pos += options.writeClientId(tx_buf[pos..], self.mac_addr);
        // No Server ID for REBIND (multicast)
        pos += options.writeIaNaWithAddr(
            tx_buf[pos..],
            self.iaid,
            self.lease.addr,
            self.lease.preferred_lifetime,
            self.lease.valid_lifetime,
        );
        pos += options.writeElapsedTime(tx_buf[pos..], self.elapsed_cs);

        const dest = net.SockAddrIn6.init(ALL_DHCP_SERVERS, SERVER_PORT);
        _ = net.sendto6(self.socket_fd, tx_buf[0..pos], &dest) catch {};

        self.retransmit_count += 1;
    }

    fn handleRebind(self: *Self, current_tick: u64) void {
        var src_addr: net.SockAddrIn6 = undefined;
        const rx_len = net.recvfrom6(self.socket_fd, &self.rx_buf, &src_addr) catch {
            // Check if lease expired
            self.lease.updateState(current_tick, 1000);
            if (self.lease.state == .Expired) {
                syscall.print("dhcpv6: REBIND failed, lease expired\n");
                self.lease.clear();
                self.state = .Waiting;
                return;
            }
            self.sendRebind();
            return;
        };

        if (rx_len < 4) return;

        const hdr: *const packet.Dhcpv6Header = @ptrCast(@alignCast(&self.rx_buf));
        if (hdr.getMsgType() != @intFromEnum(packet.Dhcpv6MsgType.Reply)) return;
        if (hdr.getTransactionId() != self.xid) return;

        if (self.processRenewalReply(self.rx_buf[4..rx_len], current_tick)) {
            self.state = .Bound;
            syscall.print("dhcpv6: REBIND successful\n");
        }
    }

    fn processRenewalReply(self: *Self, opts_data: []const u8, current_tick: u64) bool {
        var iter = options.OptionsIterator.init(opts_data);

        if (iter.find(options.OPT_IA_NA)) |ia_na_opt| {
            if (options.parseIaNa(ia_na_opt.data)) |ia_na| {
                if (options.checkStatusCode(ia_na.options_data)) |_| {
                    return false;
                }

                if (options.extractIaAddrFromIaNa(ia_na)) |ia_addr| {
                    var t1 = ia_na.t1;
                    var t2 = ia_na.t2;
                    if (t1 == 0 or t2 == 0) {
                        const defaults = lease6.calculateDefaultTimers(ia_addr.preferred_lifetime);
                        if (t1 == 0) t1 = defaults.t1;
                        if (t2 == 0) t2 = defaults.t2;
                    }

                    self.lease.recordRenewal(
                        t1,
                        t2,
                        ia_addr.preferred_lifetime,
                        ia_addr.valid_lifetime,
                        current_tick,
                    );
                    return true;
                }
            }
        }

        return false;
    }

    /// Check if we have an active address
    pub fn hasAddress(self: *const Self) bool {
        return self.lease.hasAddress() and self.state == .Bound;
    }

    /// Get assigned address (if any)
    pub fn getAddress(self: *const Self) ?[16]u8 {
        if (self.hasAddress()) {
            return self.lease.addr;
        }
        return null;
    }
};

/// Generate cryptographically random transaction ID.
fn generateXid() u24 {
    var buf: [3]u8 = undefined;
    syscall.getSecureRandom(&buf);
    return @as(u24, buf[0]) | (@as(u24, buf[1]) << 8) | (@as(u24, buf[2]) << 16);
}
