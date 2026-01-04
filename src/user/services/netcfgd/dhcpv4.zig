//! DHCPv4 Client Implementation (RFC 2131)
//!
//! Implements the DHCP DORA (Discover, Offer, Request, Acknowledge) flow
//! with full lease management including T1/T2 timers for renewal.
//!
//! Security:
//! - Transaction ID from getrandom() to prevent spoofing
//! - Zero-initialized packets to prevent info leaks
//! - Validated server responses

const std = @import("std");
const syscall = @import("syscall");
const net = syscall.net;

const packet = @import("packet.zig");
const options = @import("options.zig");
const lease = @import("lease.zig");

/// DHCP client states (RFC 2131 Section 4.4)
pub const DhcpState = enum {
    /// Initial state, sending DHCPDISCOVER
    Init,
    /// DISCOVER sent, waiting for OFFER
    Selecting,
    /// REQUEST sent, waiting for ACK
    Requesting,
    /// Lease acquired, address configured
    Bound,
    /// T1 expired, unicasting REQUEST to server
    Renewing,
    /// T2 expired, broadcasting REQUEST
    Rebinding,
};

/// DHCP client context
pub const DhcpClient = struct {
    /// Client hardware address (MAC)
    mac_addr: [6]u8,
    /// Current state
    state: DhcpState,
    /// Transaction ID (must be random)
    xid: u32,
    /// UDP socket for DHCP messages
    socket_fd: i32,
    /// Lease information
    lease_info: lease.LeaseInfo,
    /// Number of retries in current state
    retries: u8,
    /// Last action timestamp (tick count)
    last_action_tick: u64,
    /// Server identifier from OFFER
    server_id: u32,
    /// Offered IP address
    offered_ip: u32,

    const Self = @This();

    // DHCP ports
    const CLIENT_PORT: u16 = 68;
    const SERVER_PORT: u16 = 67;

    // Timeouts (milliseconds)
    const DISCOVER_TIMEOUT_MS: u64 = 4000;
    const REQUEST_TIMEOUT_MS: u64 = 4000;
    const MAX_RETRIES: u8 = 4;

    /// Initialize DHCP client
    pub fn init(mac: [6]u8) Self {
        return Self{
            .mac_addr = mac,
            .state = .Init,
            .xid = generateXid(),
            .socket_fd = -1,
            .lease_info = lease.LeaseInfo.init(),
            .retries = 0,
            .last_action_tick = 0,
            .server_id = 0,
            .offered_ip = 0,
        };
    }

    /// Get timeout until next action
    pub fn getNextTimeout(self: *const Self) u64 {
        return switch (self.state) {
            .Init => 0, // Immediate
            .Selecting, .Requesting => DISCOVER_TIMEOUT_MS,
            .Bound => self.lease_info.getTimeToT1(),
            .Renewing => self.lease_info.getTimeToT2(),
            .Rebinding => self.lease_info.getTimeToExpiry(),
        };
    }

    /// Main processing function - call periodically
    pub fn process(self: *Self, iface_idx: u32) void {
        switch (self.state) {
            .Init => self.doDiscover(),
            .Selecting => self.handleSelecting(),
            .Requesting => self.handleRequesting(),
            .Bound => self.handleBound(iface_idx),
            .Renewing => self.handleRenewing(),
            .Rebinding => self.handleRebinding(),
        }
    }

    /// Send DHCPDISCOVER
    fn doDiscover(self: *Self) void {
        syscall.print("dhcpv4: Sending DISCOVER\n");

        // Create socket if needed
        if (self.socket_fd < 0) {
            self.socket_fd = self.createSocket() catch |err| {
                printError("Failed to create socket", err);
                return;
            };
        }

        // Build DISCOVER packet
        var pkt: packet.DhcpPacket = std.mem.zeroes(packet.DhcpPacket);
        self.buildDiscoverPacket(&pkt);

        // Send broadcast
        self.sendBroadcast(&pkt) catch |err| {
            printError("Failed to send DISCOVER", err);
            return;
        };

        self.state = .Selecting;
        self.last_action_tick = syscall.getTickMs();
        self.retries = 0;
    }

    fn handleSelecting(self: *Self) void {
        // Try to receive OFFER
        // SECURITY: Zero-initialize to prevent info leaks if receivePacket partially fills
        var pkt: packet.DhcpPacket = std.mem.zeroes(packet.DhcpPacket);
        var server_addr: net.SockAddrIn = undefined;

        const received = self.receivePacket(&pkt, &server_addr);
        if (received) {
            if (self.validateOffer(&pkt)) {
                syscall.print("dhcpv4: Received valid OFFER\n");
                self.offered_ip = @byteSwap(pkt.yiaddr);
                self.extractServerInfo(&pkt);
                self.doRequest();
                return;
            }
        }

        // Check timeout
        if (syscall.getTickMs() -% self.last_action_tick > DISCOVER_TIMEOUT_MS) {
            self.retries += 1;
            if (self.retries >= MAX_RETRIES) {
                syscall.print("dhcpv4: DISCOVER timeout, resetting\n");
                self.state = .Init;
                self.xid = generateXid(); // New transaction
            } else {
                syscall.print("dhcpv4: DISCOVER retry\n");
                self.state = .Init; // Re-send DISCOVER
            }
        }
    }

    fn doRequest(self: *Self) void {
        syscall.print("dhcpv4: Sending REQUEST\n");

        var pkt: packet.DhcpPacket = std.mem.zeroes(packet.DhcpPacket);
        self.buildRequestPacket(&pkt);

        self.sendBroadcast(&pkt) catch |err| {
            printError("Failed to send REQUEST", err);
            return;
        };

        self.state = .Requesting;
        self.last_action_tick = syscall.getTickMs();
    }

    fn handleRequesting(self: *Self) void {
        // Try to receive ACK/NAK
        // SECURITY: Zero-initialize to prevent info leaks if receivePacket partially fills
        var pkt: packet.DhcpPacket = std.mem.zeroes(packet.DhcpPacket);
        var server_addr: net.SockAddrIn = undefined;

        const received = self.receivePacket(&pkt, &server_addr);
        if (received) {
            // SECURITY: Validate XID, MAC, magic cookie, and server ID
            if (!self.validateResponse(&pkt)) return;

            const msg_type = options.getMsgType(&pkt);
            if (msg_type == options.DHCPACK) {
                syscall.print("dhcpv4: Received ACK\n");
                self.applyLease(&pkt);
                return;
            } else if (msg_type == options.DHCPNAK) {
                syscall.print("dhcpv4: Received NAK, restarting\n");
                self.state = .Init;
                self.xid = generateXid();
                return;
            }
        }

        // Check timeout
        if (syscall.getTickMs() -% self.last_action_tick > REQUEST_TIMEOUT_MS) {
            self.retries += 1;
            if (self.retries >= MAX_RETRIES) {
                syscall.print("dhcpv4: REQUEST timeout, resetting\n");
                self.state = .Init;
                self.xid = generateXid();
            } else {
                self.doRequest(); // Retry REQUEST
            }
        }
    }

    fn handleBound(self: *Self, iface_idx: u32) void {
        // Check if T1 (renewal) time has been reached
        if (self.lease_info.isT1Expired()) {
            syscall.print("dhcpv4: T1 expired, starting renewal\n");
            self.state = .Renewing;
            self.doRenew(iface_idx);
        }
    }

    fn handleRenewing(self: *Self) void {
        // Try to receive ACK for renewal
        // SECURITY: Zero-initialize to prevent info leaks if receivePacket partially fills
        var pkt: packet.DhcpPacket = std.mem.zeroes(packet.DhcpPacket);
        var server_addr: net.SockAddrIn = undefined;

        const received = self.receivePacket(&pkt, &server_addr);
        if (received) {
            // SECURITY: Validate XID, MAC, magic cookie
            if (!self.validateResponse(&pkt)) return;

            const msg_type = options.getMsgType(&pkt);
            if (msg_type == options.DHCPACK) {
                syscall.print("dhcpv4: Renewal successful\n");
                self.updateLease(&pkt);
                self.state = .Bound;
                return;
            }
        }

        // Check if T2 expired (need to rebind)
        if (self.lease_info.isT2Expired()) {
            syscall.print("dhcpv4: T2 expired, starting rebind\n");
            self.state = .Rebinding;
            self.retries = 0; // Reset retry counter for new state
        }
    }

    fn handleRebinding(self: *Self) void {
        // Broadcast REQUEST
        var pkt: packet.DhcpPacket = std.mem.zeroes(packet.DhcpPacket);
        self.buildRebindPacket(&pkt);

        self.sendBroadcast(&pkt) catch {
            return;
        };

        // Try to receive response
        // SECURITY: Zero-initialize to prevent info leaks if receivePacket partially fills
        var resp: packet.DhcpPacket = std.mem.zeroes(packet.DhcpPacket);
        var server_addr: net.SockAddrIn = undefined;

        const received = self.receivePacket(&resp, &server_addr);
        if (received) {
            // SECURITY: Validate XID, MAC, magic cookie
            if (!self.validateResponse(&resp)) return;

            const msg_type = options.getMsgType(&resp);
            if (msg_type == options.DHCPACK) {
                syscall.print("dhcpv4: Rebind successful\n");
                // Update server_id from new server (rebind may get different server)
                self.server_id = options.getServerId(&resp);
                self.updateLease(&resp);
                self.state = .Bound;
                return;
            }
        }

        // Check if lease expired
        if (self.lease_info.isExpired()) {
            syscall.print("dhcpv4: Lease expired, restarting\n");
            self.state = .Init;
            self.xid = generateXid();
        }
    }

    fn doRenew(self: *Self, iface_idx: u32) void {
        _ = iface_idx;
        syscall.print("dhcpv4: Sending renewal REQUEST\n");

        var pkt: packet.DhcpPacket = std.mem.zeroes(packet.DhcpPacket);
        self.buildRenewalPacket(&pkt);

        // Unicast to server (we're in RENEWING state)
        self.sendUnicast(&pkt, self.server_id) catch |err| {
            printError("Failed to send renewal", err);
        };
    }

    fn applyLease(self: *Self, pkt: *const packet.DhcpPacket) void {
        const ip = @byteSwap(pkt.yiaddr);
        const netmask = options.getSubnetMask(pkt);
        const gateway = options.getRouter(pkt);
        const lease_time = options.getLeaseTime(pkt);

        // Configure interface
        net.setIpv4Config(0, ip, netmask, gateway) catch |err| {
            printError("Failed to configure interface", err);
            return;
        };

        // Update lease info
        self.lease_info.setLease(ip, netmask, gateway, lease_time);
        self.state = .Bound;

        printIpAddress("dhcpv4: Configured IP: ", ip);
    }

    fn updateLease(self: *Self, pkt: *const packet.DhcpPacket) void {
        const lease_time = options.getLeaseTime(pkt);
        self.lease_info.renewLease(lease_time);
    }

    // Packet building helpers
    fn buildDiscoverPacket(self: *Self, pkt: *packet.DhcpPacket) void {
        pkt.op = packet.BOOTREQUEST;
        pkt.htype = 1; // Ethernet
        pkt.hlen = 6;
        pkt.xid = @byteSwap(self.xid);
        pkt.flags = @byteSwap(@as(u16, 0x8000)); // Broadcast flag
        @memcpy(pkt.chaddr[0..6], &self.mac_addr);
        pkt.magic_cookie = @byteSwap(packet.DHCP_MAGIC);

        // Add options
        options.buildDiscoverOptions(&pkt.options);
    }

    fn buildRequestPacket(self: *Self, pkt: *packet.DhcpPacket) void {
        pkt.op = packet.BOOTREQUEST;
        pkt.htype = 1;
        pkt.hlen = 6;
        pkt.xid = @byteSwap(self.xid);
        pkt.flags = @byteSwap(@as(u16, 0x8000));
        @memcpy(pkt.chaddr[0..6], &self.mac_addr);
        pkt.magic_cookie = @byteSwap(packet.DHCP_MAGIC);

        options.buildRequestOptions(&pkt.options, self.offered_ip, self.server_id);
    }

    fn buildRenewalPacket(self: *Self, pkt: *packet.DhcpPacket) void {
        pkt.op = packet.BOOTREQUEST;
        pkt.htype = 1;
        pkt.hlen = 6;
        pkt.xid = @byteSwap(self.xid);
        pkt.ciaddr = @byteSwap(self.lease_info.ip_addr);
        @memcpy(pkt.chaddr[0..6], &self.mac_addr);
        pkt.magic_cookie = @byteSwap(packet.DHCP_MAGIC);

        options.buildRenewalOptions(&pkt.options);
    }

    fn buildRebindPacket(self: *Self, pkt: *packet.DhcpPacket) void {
        pkt.op = packet.BOOTREQUEST;
        pkt.htype = 1;
        pkt.hlen = 6;
        pkt.xid = @byteSwap(self.xid);
        pkt.flags = @byteSwap(@as(u16, 0x8000));
        pkt.ciaddr = @byteSwap(self.lease_info.ip_addr);
        @memcpy(pkt.chaddr[0..6], &self.mac_addr);
        pkt.magic_cookie = @byteSwap(packet.DHCP_MAGIC);

        options.buildRenewalOptions(&pkt.options);
    }

    // Network helpers
    fn createSocket(self: *Self) !i32 {
        _ = self;
        const fd = try net.socket(net.AF_INET, net.SOCK_DGRAM, 0);

        // Bind to DHCP client port
        var addr = net.SockAddrIn.init(0, CLIENT_PORT);
        try net.bind(fd, &addr);

        return fd;
    }

    fn sendBroadcast(self: *Self, pkt: *const packet.DhcpPacket) !void {
        const dest = net.SockAddrIn.init(0xFFFFFFFF, SERVER_PORT);
        const bytes = std.mem.asBytes(pkt);
        _ = try net.sendto(self.socket_fd, bytes, &dest);
    }

    fn sendUnicast(self: *Self, pkt: *const packet.DhcpPacket, server_ip: u32) !void {
        const dest = net.SockAddrIn.init(server_ip, SERVER_PORT);
        const bytes = std.mem.asBytes(pkt);
        _ = try net.sendto(self.socket_fd, bytes, &dest);
    }

    /// Receive DHCP packet from socket.
    /// SECURITY INVARIANT: Callers MUST zero-initialize pkt before calling.
    /// This ensures partial reads (recvfrom returning < full packet) leave
    /// zeros in unwritten bytes, not stack garbage. Options parser treats
    /// zeros as PAD (0x00), which is safe and terminates at OPT_END or bounds.
    fn receivePacket(self: *Self, pkt: *packet.DhcpPacket, src: *net.SockAddrIn) bool {
        const buf = std.mem.asBytes(pkt);
        const n = net.recvfrom(self.socket_fd, buf, src) catch {
            return false;
        };
        return n >= @sizeOf(packet.DhcpPacket) - 312; // At least base header
    }

    fn validateOffer(self: *Self, pkt: *const packet.DhcpPacket) bool {
        // Check it's a reply
        if (pkt.op != packet.BOOTREPLY) return false;

        // Check transaction ID
        if (@byteSwap(pkt.xid) != self.xid) return false;

        // Check magic cookie
        if (@byteSwap(pkt.magic_cookie) != packet.DHCP_MAGIC) return false;

        // Check message type
        const msg_type = options.getMsgType(pkt);
        if (msg_type != options.DHCPOFFER) return false;

        // Check our MAC
        if (!std.mem.eql(u8, pkt.chaddr[0..6], &self.mac_addr)) return false;

        return true;
    }

    /// Validate ACK/NAK response packet.
    /// SECURITY: Must verify XID, MAC, magic cookie, and server ID to prevent
    /// spoofing attacks where attacker races to send fake responses.
    fn validateResponse(self: *Self, pkt: *const packet.DhcpPacket) bool {
        // Check it's a reply
        if (pkt.op != packet.BOOTREPLY) return false;

        // SECURITY: Verify transaction ID matches our request
        if (@byteSwap(pkt.xid) != self.xid) return false;

        // Check magic cookie
        if (@byteSwap(pkt.magic_cookie) != packet.DHCP_MAGIC) return false;

        // SECURITY: Verify our MAC to prevent cross-client attacks
        if (!std.mem.eql(u8, pkt.chaddr[0..6], &self.mac_addr)) return false;

        // SECURITY: In REQUESTING state, verify server ID matches the one from OFFER
        // (RFC 2131 Section 3.1 - client SHOULD verify server identifier)
        if (self.state == .Requesting and self.server_id != 0) {
            const response_server_id = options.getServerId(pkt);
            if (response_server_id != self.server_id) return false;
        }

        return true;
    }

    fn extractServerInfo(self: *Self, pkt: *const packet.DhcpPacket) void {
        self.server_id = options.getServerId(pkt);
    }
};

/// Generate cryptographically random transaction ID.
/// SECURITY: XID must be unpredictable to prevent DHCP spoofing attacks.
/// Per RFC 2131, transaction ID prevents attackers from racing legitimate
/// servers with spoofed responses. A predictable XID allows man-in-the-middle.
/// Uses getSecureRandomU32() which handles partial reads, EINTR, and panics on failure.
fn generateXid() u32 {
    return syscall.getSecureRandomU32();
}

fn printError(msg: []const u8, err: anyerror) void {
    syscall.print("dhcpv4: ");
    syscall.print(msg);
    syscall.print(": ");
    syscall.print(@errorName(err));
    syscall.print("\n");
}

fn printIpAddress(prefix: []const u8, ip: u32) void {
    syscall.print(prefix);
    printDecimal((ip >> 24) & 0xFF);
    syscall.print(".");
    printDecimal((ip >> 16) & 0xFF);
    syscall.print(".");
    printDecimal((ip >> 8) & 0xFF);
    syscall.print(".");
    printDecimal(ip & 0xFF);
    syscall.print("\n");
}

fn printDecimal(val: u32) void {
    if (val == 0) {
        syscall.print("0");
        return;
    }
    var buf: [10]u8 = undefined;
    var i: usize = 0;
    var v = val;
    while (v > 0) : (i += 1) {
        buf[9 - i] = @intCast((v % 10) + '0');
        v /= 10;
    }
    syscall.print(buf[10 - i ..]);
}
