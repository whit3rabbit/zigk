//! DHCPv4 Client Implementation
//!
//! RFC 2131 - Dynamic Host Configuration Protocol
//! RFC 2132 - DHCP Options and BOOTP Vendor Extensions
//! RFC 5227 - IPv4 Address Conflict Detection
//!
//! Implements the DHCP DORA (Discover, Offer, Request, Acknowledge) flow
//! with full lease management including T1/T2 timers for renewal.
//!
//! State Machine (RFC 2131 Figure 5):
//!   INIT -> SELECTING -> REQUESTING -> BOUND -> RENEWING -> REBINDING
//!
//! Key RFC Compliance:
//! - Section 4.1: Retransmission with exponential backoff (4s, 8s, 16s, 32s, 64s)
//! - Section 4.4.1: Initial random delay (1-10 seconds) to prevent thundering herd
//! - Section 4.4.1: ARP probe before IP configuration (RFC 5227)
//! - Section 4.4.4: DHCPDECLINE on IP conflict detection
//! - Section 4.4.6: DHCPRELEASE on voluntary shutdown
//!
//! Security:
//! - Transaction ID from CSPRNG to prevent spoofing (Section 3.1)
//! - Zero-initialized packets to prevent kernel info leaks
//! - Server ID verification to prevent rogue server attacks
//! - MAC address validation on responses

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
    /// RFC 2131: Initial random delay (1-10s) done
    initial_delay_done: bool,
    /// Track if rebind request was sent (fix race condition)
    rebind_request_sent: bool,

    const Self = @This();

    // DHCP ports
    const CLIENT_PORT: u16 = 68;
    const SERVER_PORT: u16 = 67;

    // Timeouts (milliseconds)
    // RFC 2131 Section 4.1: "The client SHOULD wait a minimum of four seconds
    // before rebroadcasting... the delay before the first retransmission
    // SHOULD be 4 seconds randomized by the value of a uniform random number
    // chosen from the range -1 to +1"
    const BASE_TIMEOUT_MS: u64 = 4000; // Base 4 seconds
    const MAX_TIMEOUT_MS: u64 = 64000; // Max 64 seconds (4 doublings)
    const MAX_RETRIES: u8 = 4;

    // RFC 5227 Section 2.1.1: "PROBE_WAIT... 1-2 seconds"
    // We use 1 second as a reasonable probe timeout
    const ARP_PROBE_TIMEOUT_MS: u64 = 1000;

    // RFC 2131 Section 4.4.4: After DECLINE, client "SHOULD wait a minimum
    // of ten seconds before restarting the configuration process"
    const DECLINE_WAIT_MS: u64 = 10000;

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
            .initial_delay_done = false,
            .rebind_request_sent = false,
        };
    }

    /// Calculate timeout with exponential backoff and jitter
    ///
    /// RFC 2131 Section 4.1:
    /// "The retransmission delay SHOULD be doubled with subsequent
    /// retransmissions up to a maximum of 64 seconds."
    ///
    /// "The delay before the first retransmission SHOULD be 4 seconds
    /// randomized by the value of a uniform random number chosen from
    /// the range -1 to +1."
    ///
    /// Timeout progression: 4s -> 8s -> 16s -> 32s -> 64s (with +/- 1s jitter)
    fn getRetryTimeout(retry_count: u8) u64 {
        // Exponential backoff: 4s << retry_count, capped at 64s
        const shift: u6 = @min(retry_count, 4);
        const base = BASE_TIMEOUT_MS << shift;
        const capped = @min(base, MAX_TIMEOUT_MS);

        // Add jitter: +/- 1 second (RFC 2131 Section 4.1)
        const random = syscall.getSecureRandomU32();
        const jitter_raw = random % 2001; // 0-2000
        const jitter: i64 = @as(i64, @intCast(jitter_raw)) - 1000; // -1000 to +1000 ms
        const with_jitter = @as(i64, @intCast(capped)) + jitter;

        // Ensure minimum 1 second timeout
        return @intCast(@max(1000, with_jitter));
    }

    /// Get timeout until next action
    pub fn getNextTimeout(self: *const Self) u64 {
        return switch (self.state) {
            .Init => 0, // Immediate
            .Selecting, .Requesting, .Rebinding => getRetryTimeout(self.retries),
            .Bound => self.lease_info.getTimeToT1(),
            .Renewing => self.lease_info.getTimeToT2(),
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
        // RFC 2131 Section 4.4.1: Wait 1-10 seconds on first discover
        // to prevent synchronized startup storms (e.g., power outage recovery)
        if (!self.initial_delay_done) {
            const delay_ms = 1000 + (syscall.getSecureRandomU32() % 9001); // 1000-10000ms
            syscall.print("dhcpv4: Initial delay ");
            printDecimal(delay_ms);
            syscall.print("ms\n");
            syscall.sleep_ms(delay_ms) catch {};
            self.initial_delay_done = true;
        }

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

        // Check timeout with exponential backoff
        const timeout = getRetryTimeout(self.retries);
        if (syscall.getTickMs() -% self.last_action_tick > timeout) {
            self.retries += 1;
            if (self.retries >= MAX_RETRIES) {
                syscall.print("dhcpv4: DISCOVER timeout, resetting\n");
                self.state = .Init;
                self.xid = generateXid(); // New transaction
                self.retries = 0;
            } else {
                syscall.print("dhcpv4: DISCOVER retry ");
                printDecimal(self.retries);
                syscall.print("\n");
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
                self.applyLease(&pkt, 0); // iface_idx 0 for now
                return;
            } else if (msg_type == options.DHCPNAK) {
                syscall.print("dhcpv4: Received NAK, restarting\n");
                self.state = .Init;
                self.xid = generateXid();
                self.retries = 0;
                return;
            }
        }

        // Check timeout with exponential backoff
        const timeout = getRetryTimeout(self.retries);
        if (syscall.getTickMs() -% self.last_action_tick > timeout) {
            self.retries += 1;
            if (self.retries >= MAX_RETRIES) {
                syscall.print("dhcpv4: REQUEST timeout, resetting\n");
                self.state = .Init;
                self.xid = generateXid();
                self.retries = 0;
            } else {
                syscall.print("dhcpv4: REQUEST retry ");
                printDecimal(self.retries);
                syscall.print("\n");
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
        // FIX: Only send request once per timeout period to avoid race condition
        // where we send and immediately try to receive with no time for response
        if (!self.rebind_request_sent) {
            syscall.print("dhcpv4: Sending rebind REQUEST\n");
            var pkt: packet.DhcpPacket = std.mem.zeroes(packet.DhcpPacket);
            self.buildRebindPacket(&pkt);

            self.sendBroadcast(&pkt) catch {
                return;
            };
            self.rebind_request_sent = true;
            self.last_action_tick = syscall.getTickMs();
        }

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
                self.rebind_request_sent = false;
                self.retries = 0;
                return;
            } else if (msg_type == options.DHCPNAK) {
                syscall.print("dhcpv4: Rebind NAK, restarting\n");
                self.state = .Init;
                self.xid = generateXid();
                self.rebind_request_sent = false;
                self.retries = 0;
                return;
            }
        }

        // Check timeout with exponential backoff - allow next send
        const timeout = getRetryTimeout(self.retries);
        if (syscall.getTickMs() -% self.last_action_tick > timeout) {
            self.retries += 1;
            self.rebind_request_sent = false; // Allow next send

            if (self.retries >= MAX_RETRIES) {
                syscall.print("dhcpv4: Rebind timeout after max retries\n");
                // Don't reset yet - check lease expiry below
            } else {
                syscall.print("dhcpv4: Rebind retry ");
                printDecimal(self.retries);
                syscall.print("\n");
            }
        }

        // Check if lease expired
        if (self.lease_info.isExpired()) {
            syscall.print("dhcpv4: Lease expired, restarting\n");
            self.state = .Init;
            self.xid = generateXid();
            self.rebind_request_sent = false;
            self.retries = 0;
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

    /// Apply received DHCP lease after ACK
    ///
    /// RFC 2131 Section 4.4.1:
    /// "The client SHOULD perform a final check on the parameters
    /// (e.g., ARP for allocated network address), and notes the
    /// duration of the lease."
    ///
    /// RFC 5227 Section 2.1.1:
    /// "A host SHOULD perform this check on any IP address it obtains
    /// via any mechanism, as a final sanity check before using an address."
    fn applyLease(self: *Self, pkt: *const packet.DhcpPacket, iface_idx: u32) void {
        const ip = @byteSwap(pkt.yiaddr);
        const netmask = options.getSubnetMask(pkt);
        const gateway = options.getRouter(pkt);
        const lease_time = options.getLeaseTime(pkt);

        // RFC 5227 Section 2.1.1: ARP probe before configuring
        // Send probe with sender IP = 0, target IP = offered IP
        printIpAddress("dhcpv4: Probing for conflicts: ", ip);
        const probe_result = net.arpProbe(iface_idx, ip, ARP_PROBE_TIMEOUT_MS) catch |err| {
            // Best effort - continue on failure
            printError("ARP probe failed", err);
            // Assume no conflict if probe syscall fails
            configureInterface(self, ip, netmask, gateway, lease_time, iface_idx);
            return;
        };

        switch (probe_result) {
            .Conflict => {
                // RFC 2131 Section 4.4.1: "If the network address appears to be
                // in use, the client MUST send a DHCPDECLINE message to the server"
                syscall.print("dhcpv4: IP conflict detected! Sending DECLINE\n");
                self.sendDecline(ip);
                self.state = .Init;
                self.xid = generateXid();
                self.retries = 0;
                // RFC 2131 Section 4.4.4: Wait 10 seconds before restarting
                syscall.sleep_ms(DECLINE_WAIT_MS) catch {};
                return;
            },
            .NoConflict, .Timeout => {
                // Safe to use IP - no response means address is available
                configureInterface(self, ip, netmask, gateway, lease_time, iface_idx);
            },
        }
    }

    fn configureInterface(self: *Self, ip: u32, netmask: u32, gateway: u32, lease_time: u32, iface_idx: u32) void {
        // Configure interface
        net.setIpv4Config(iface_idx, ip, netmask, gateway) catch |err| {
            printError("Failed to configure interface", err);
            return;
        };

        // RFC 5227: Gratuitous ARP announcement to update neighbor caches
        net.arpAnnounce(iface_idx, ip) catch |err| {
            // Best effort - continue on failure
            printError("ARP announce failed", err);
        };

        // Update lease info
        self.lease_info.setLease(ip, netmask, gateway, lease_time);
        self.state = .Bound;
        self.retries = 0;

        printIpAddress("dhcpv4: Configured IP: ", ip);
    }

    /// Send DHCPDECLINE when IP conflict detected (RFC 2131 Section 4.4.4)
    fn sendDecline(self: *Self, declined_ip: u32) void {
        var pkt: packet.DhcpPacket = std.mem.zeroes(packet.DhcpPacket);
        pkt.op = packet.BOOTREQUEST;
        pkt.htype = 1;
        pkt.hlen = 6;
        pkt.xid = @byteSwap(self.xid);
        @memcpy(pkt.chaddr[0..6], &self.mac_addr);
        pkt.magic_cookie = @byteSwap(packet.DHCP_MAGIC);

        options.buildDeclineOptions(&pkt.options, declined_ip, self.server_id);

        self.sendBroadcast(&pkt) catch |err| {
            printError("Failed to send DECLINE", err);
        };
    }

    /// Release DHCP lease voluntarily (RFC 2131 Section 4.4.6)
    /// Call this when shutting down to inform the server.
    pub fn release(self: *Self) void {
        if (self.state != .Bound and self.state != .Renewing and self.state != .Rebinding) {
            return; // No lease to release
        }

        syscall.print("dhcpv4: Sending RELEASE\n");

        var pkt: packet.DhcpPacket = std.mem.zeroes(packet.DhcpPacket);
        pkt.op = packet.BOOTREQUEST;
        pkt.htype = 1;
        pkt.hlen = 6;
        pkt.xid = @byteSwap(self.xid);
        pkt.ciaddr = @byteSwap(self.lease_info.ip_addr); // Must include current IP
        @memcpy(pkt.chaddr[0..6], &self.mac_addr);
        pkt.magic_cookie = @byteSwap(packet.DHCP_MAGIC);

        options.buildReleaseOptions(&pkt.options, self.server_id);

        // Unicast to server
        self.sendUnicast(&pkt, self.server_id) catch |err| {
            printError("Failed to send RELEASE", err);
        };

        self.lease_info.invalidate();
        self.state = .Init;
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
