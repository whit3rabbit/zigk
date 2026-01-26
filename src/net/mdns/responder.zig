// mDNS Responder
// Handles incoming mDNS queries and generates responses
// RFC 6762: Multicast DNS

const std = @import("std");
const sync = @import("../sync.zig");
const constants = @import("constants.zig");
const cache = @import("cache.zig");
const services = @import("services.zig");
const dns = @import("../dns/dns.zig");
const Interface = @import("../core/interface.zig").Interface;
const lifecycle = @import("../transport/socket/lifecycle.zig");
const socket_types = @import("../transport/socket/types.zig");
const socket_options = @import("../transport/socket/options.zig");
const udp_api = @import("../transport/socket/udp_api.zig");
const socket_state = @import("../transport/socket/state.zig");

/// Responder state machine
pub const ResponderState = constants.ResponderState;

/// mDNS Responder instance
pub const Responder = struct {
    /// UDP socket file descriptor
    sock_fd: ?usize,

    /// Local hostname (without .local suffix)
    hostname: [constants.MAX_HOSTNAME_LEN]u8,
    hostname_len: usize,

    /// Network interface reference
    iface: ?*Interface,

    /// Current state
    state: ResponderState,

    /// Probe counter (0-3)
    probe_count: u8,

    /// Tick counter for timing
    tick_count: u64,

    /// Next action tick (for probing/announcing delays)
    next_action_tick: u64,

    /// Announce counter
    announce_count: u8,

    /// Whether responder is active
    active: bool,

    // Rate limiting to prevent amplification attacks (RFC 6762 Section 6)
    /// Response tokens available (replenished each tick)
    rate_tokens: u8,
    /// Tick count of last token replenishment
    last_replenish_tick: u64,

    /// Initialize responder
    pub fn init(self: *Responder, iface: *Interface, hostname: []const u8) !void {
        self.iface = iface;
        self.sock_fd = null;
        self.state = .probing;
        self.probe_count = 0;
        self.tick_count = 0;
        self.next_action_tick = 0;
        self.announce_count = 0;
        self.active = false;
        self.rate_tokens = constants.RATE_LIMIT_TOKENS_MAX;
        self.last_replenish_tick = 0;

        // Copy hostname
        if (hostname.len == 0 or hostname.len > constants.MAX_HOSTNAME_LEN) {
            // Default hostname
            const default = "zk";
            @memcpy(self.hostname[0..default.len], default);
            self.hostname_len = default.len;
        } else {
            @memcpy(self.hostname[0..hostname.len], hostname);
            self.hostname_len = hostname.len;
        }

        // Create UDP socket
        self.sock_fd = lifecycle.socket(
            socket_types.AF_INET,
            socket_types.SOCK_DGRAM,
            0,
        ) catch {
            return error.SocketCreateFailed;
        };

        const fd = self.sock_fd.?;

        // Set SO_REUSEADDR to allow multiple listeners
        var reuse: i32 = 1;
        socket_options.setsockopt(
            fd,
            socket_types.SOL_SOCKET,
            socket_types.SO_REUSEADDR,
            @ptrCast(&reuse),
            @sizeOf(i32),
        ) catch {};

        // Bind to port 5353 on all interfaces (INADDR_ANY)
        // init takes IP in host byte order and port in host byte order
        const bind_addr = socket_types.SockAddrIn.init(0, constants.MDNS_PORT);

        lifecycle.bind(fd, &bind_addr) catch {
            lifecycle.close(fd) catch {};
            self.sock_fd = null;
            return error.BindFailed;
        };

        // Join multicast group 224.0.0.251
        // imr_multiaddr is in network byte order
        const mreq = socket_types.IpMreq{
            .imr_multiaddr = @byteSwap(constants.MDNS_MULTICAST_IPV4),
            .imr_interface = 0, // INADDR_ANY
        };

        socket_options.setsockopt(
            fd,
            socket_types.IPPROTO_IP,
            socket_types.IP_ADD_MEMBERSHIP,
            @ptrCast(&mreq),
            @sizeOf(socket_types.IpMreq),
        ) catch {
            lifecycle.close(fd) catch {};
            self.sock_fd = null;
            return error.MulticastJoinFailed;
        };

        // Set multicast TTL to 255 (required for mDNS link-local)
        var ttl: u8 = constants.MDNS_TTL;
        socket_options.setsockopt(
            fd,
            socket_types.IPPROTO_IP,
            socket_types.IP_MULTICAST_TTL,
            @ptrCast(&ttl),
            1,
        ) catch {};

        self.active = true;
        self.state = .probing;
        self.next_action_tick = self.tick_count + (constants.PROBE_WAIT_MS / 10); // Assuming 100Hz ticks
    }

    /// Deinitialize responder
    pub fn deinit(self: *Responder) void {
        if (self.sock_fd) |fd| {
            // Leave multicast group
            const mreq = socket_types.IpMreq{
                .imr_multiaddr = @byteSwap(constants.MDNS_MULTICAST_IPV4),
                .imr_interface = 0,
            };

            socket_options.setsockopt(
                fd,
                socket_types.IPPROTO_IP,
                socket_types.IP_DROP_MEMBERSHIP,
                @ptrCast(&mreq),
                @sizeOf(socket_types.IpMreq),
            ) catch {};

            lifecycle.close(fd) catch {};
            self.sock_fd = null;
        }
        self.active = false;
    }

    /// Periodic tick handler
    pub fn tick(self: *Responder) void {
        if (!self.active) return;

        self.tick_count +%= 1;

        // Replenish rate limit tokens periodically
        if (self.tick_count -% self.last_replenish_tick >= constants.RATE_LIMIT_REPLENISH_TICKS) {
            self.rate_tokens = constants.RATE_LIMIT_TOKENS_MAX;
            self.last_replenish_tick = self.tick_count;
        }

        // Check for pending actions based on state
        if (self.tick_count >= self.next_action_tick) {
            switch (self.state) {
                .probing => self.handleProbing(),
                .announcing => self.handleAnnouncing(),
                .running => {}, // Normal operation - just respond to queries
                .conflict => self.handleConflict(),
            }
        }

        // Process any incoming packets
        self.processIncoming();
    }

    /// Try to consume a rate limit token for sending a response
    /// Returns true if token consumed, false if rate limited
    fn tryConsumeRateToken(self: *Responder) bool {
        if (self.rate_tokens > 0) {
            self.rate_tokens -= 1;
            return true;
        }
        return false;
    }

    /// Handle probing state
    fn handleProbing(self: *Responder) void {
        if (self.probe_count >= constants.PROBE_COUNT) {
            // Probing complete, move to announcing
            self.state = .announcing;
            self.announce_count = 0;
            self.next_action_tick = self.tick_count; // Announce immediately
            return;
        }

        // Send probe query
        self.sendProbe();
        self.probe_count += 1;
        self.next_action_tick = self.tick_count + (constants.PROBE_WAIT_MS / 10);
    }

    /// Handle announcing state
    fn handleAnnouncing(self: *Responder) void {
        if (self.announce_count >= constants.ANNOUNCE_COUNT) {
            // Announcing complete, move to running
            self.state = .running;
            return;
        }

        // Send announcement
        self.sendAnnouncement();
        self.announce_count += 1;
        self.next_action_tick = self.tick_count + (constants.ANNOUNCE_WAIT_MS / 10);
    }

    /// Handle conflict state
    fn handleConflict(self: *Responder) void {
        // Append number to hostname and restart probing
        if (self.hostname_len < constants.MAX_HOSTNAME_LEN - 2) {
            self.hostname[self.hostname_len] = '-';
            self.hostname[self.hostname_len + 1] = '2';
            self.hostname_len += 2;
        }

        self.state = .probing;
        self.probe_count = 0;
        self.next_action_tick = self.tick_count + (constants.PROBE_WAIT_MS / 10);
    }

    /// Send probe query for our hostname
    fn sendProbe(self: *Responder) void {
        const fd = self.sock_fd orelse return;

        var buf: [512]u8 = [_]u8{0} ** 512;
        var pkt = dns.DnsPacket.init(&buf);

        // Build query for hostname.local ANY record
        pkt.writeHeader(0x0000, dns.FLAGS_QR_QUERY) catch return;

        // Write hostname.local
        var name_buf: [128]u8 = undefined;
        const name_len = self.buildHostnameFqdn(&name_buf);
        if (name_len == 0) return;

        pkt.writeName(name_buf[0..name_len]) catch return;
        pkt.writeQuestion(dns.TYPE_ANY, dns.CLASS_IN | 0x8000) catch return; // QU bit set

        // Send to multicast address
        // Send to multicast address (init takes IP and port in host byte order)
        const dest_addr = socket_types.SockAddrIn.init(constants.MDNS_MULTICAST_IPV4, constants.MDNS_PORT);

        _ = udp_api.sendto(fd, buf[0..pkt.pos], &dest_addr) catch {};
    }

    /// Send announcement for our hostname
    fn sendAnnouncement(self: *Responder) void {
        const fd = self.sock_fd orelse return;
        const iface = self.iface orelse return;

        var buf: [512]u8 = [_]u8{0} ** 512;
        var pkt = dns.DnsPacket.init(&buf);

        // Build response with our A record
        pkt.writeHeader(0x0000, dns.FLAGS_MDNS_RESPONSE) catch return;

        // Update header to show 0 questions, 1 answer
        pkt.setArCount(0, 0); // No additional
        // Security: Bounds check before direct header writes (CLAUDE.md - Network Stack Security)
        if (buf.len < dns.DNS_HEADER_SIZE) return;
        std.mem.writeInt(u16, buf[4..6], 0, .big); // 0 questions
        std.mem.writeInt(u16, buf[6..8], 1, .big); // 1 answer

        // Write A record for hostname.local
        var name_buf: [128]u8 = undefined;
        const name_len = self.buildHostnameFqdn(&name_buf);
        if (name_len == 0) return;

        pkt.writeARecord(
            name_buf[0..name_len],
            dns.CLASS_IN | dns.MDNS_CACHE_FLUSH_BIT,
            constants.MDNS_HOST_TTL,
            iface.ip_addr,
        ) catch return;

        // Send to multicast address (init takes IP and port in host byte order)
        const dest_addr = socket_types.SockAddrIn.init(constants.MDNS_MULTICAST_IPV4, constants.MDNS_PORT);

        _ = udp_api.sendto(fd, buf[0..pkt.pos], &dest_addr) catch {};
    }

    /// Process incoming packets
    fn processIncoming(self: *Responder) void {
        const fd = self.sock_fd orelse return;

        // Try to receive a packet (non-blocking would be ideal, but we'll just try once per tick)
        var buf: [1500]u8 = undefined;
        var src_addr: socket_types.SockAddrIn = undefined;

        const len = udp_api.recvfrom(fd, &buf, &src_addr) catch {
            return; // No packet or error
        };

        if (len < dns.DNS_HEADER_SIZE) return;

        self.processQuery(buf[0..len], src_addr.getAddr(), src_addr.getPort());
    }

    /// Process an incoming mDNS query
    fn processQuery(self: *Responder, pkt_data: []const u8, src_addr: u32, src_port: u16) void {
        if (pkt_data.len < dns.DNS_HEADER_SIZE) return;

        const hdr: *align(1) const dns.Header = @ptrCast(pkt_data.ptr);
        const flags = hdr.getFlags();

        // Check if this is a query (QR bit = 0)
        if ((flags & dns.FLAGS_QR_RESPONSE) != 0) {
            // This is a response - check for conflicts during probing
            if (self.state == .probing) {
                self.checkForConflict(pkt_data);
            }
            return;
        }

        // Parse questions
        const qd_count = hdr.getQdCount();
        if (qd_count == 0) return;

        var pos: usize = dns.DNS_HEADER_SIZE;
        var name_buf: [256]u8 = [_]u8{0} ** 256;

        var i: u16 = 0;
        while (i < qd_count) : (i += 1) {
            if (pos >= pkt_data.len) break;

            // Read question name
            const name_result = dns.readName(pkt_data, pos, &name_buf) catch break;
            pos = name_result.end_pos;

            if (pos + 4 > pkt_data.len) break;

            const qtype = std.mem.readInt(u16, pkt_data[pos..][0..2], .big);
            const qclass = std.mem.readInt(u16, pkt_data[pos + 2 ..][0..2], .big);
            pos += 4;

            // Check if QU bit is set (unicast response requested)
            const unicast = (qclass & 0x8000) != 0;

            // Check if this query matches our hostname
            if (self.matchesHostname(name_result.name)) {
                if (qtype == dns.TYPE_A or qtype == dns.TYPE_ANY) {
                    self.sendResponse(name_result.name, dns.TYPE_A, unicast, src_addr, src_port);
                }
            }

            // Check if this query matches a registered service
            self.handleServiceQuery(name_result.name, qtype, unicast, src_addr, src_port);
        }
    }

    /// Handle service-related queries (PTR, SRV, TXT)
    fn handleServiceQuery(self: *Responder, query_name: []const u8, qtype: u16, unicast: bool, src_addr: u32, src_port: u16) void {
        // DNS-SD Service Type Enumeration (RFC 6763 Section 9)
        // Query: _services._dns-sd._udp.local -> PTR response listing service types
        const sd_services = "_services._dns-sd._udp.local";
        if (caseInsensitiveEqual(query_name, sd_services)) {
            if (qtype == dns.TYPE_PTR or qtype == dns.TYPE_ANY) {
                self.sendServiceTypesResponse(unicast, src_addr, src_port);
            }
            return;
        }

        // Check if query is for a service type (PTR query for service enumeration)
        // e.g., "_http._tcp.local" -> PTR response listing service instances
        if (qtype == dns.TYPE_PTR or qtype == dns.TYPE_ANY) {
            // Extract service type from query (strip .local suffix if present)
            var svc_type_buf: [64]u8 = undefined;
            const svc_type = extractServiceType(query_name, &svc_type_buf) orelse return;

            // Find services of this type and respond with PTR records
            var iter = services.iterateByType(svc_type);
            var has_services = false;
            while (iter.next()) |_| {
                has_services = true;
                break;
            }
            if (has_services) {
                self.sendServicePtrResponse(svc_type, unicast, src_addr, src_port);
            }
        }

        // Check if query is for a specific service instance
        // e.g., "My Web Server._http._tcp.local" -> SRV/TXT response
        if (qtype == dns.TYPE_SRV or qtype == dns.TYPE_TXT or qtype == dns.TYPE_ANY) {
            // Parse instance name and service type from query
            var instance_buf: [64]u8 = undefined;
            var svc_type_buf: [64]u8 = undefined;
            if (parseServiceInstanceName(query_name, &instance_buf, &svc_type_buf)) |parsed| {
                if (services.find(parsed.instance, parsed.svc_type)) |svc| {
                    if (qtype == dns.TYPE_SRV or qtype == dns.TYPE_ANY) {
                        self.sendServiceSrvResponse(svc, unicast, src_addr, src_port);
                    }
                    if (qtype == dns.TYPE_TXT or qtype == dns.TYPE_ANY) {
                        self.sendServiceTxtResponse(svc, unicast, src_addr, src_port);
                    }
                }
            }
        }
    }

    /// Send PTR responses listing all service types (for _services._dns-sd._udp.local)
    fn sendServiceTypesResponse(self: *Responder, unicast: bool, src_addr: u32, src_port: u16) void {
        if (!self.tryConsumeRateToken()) return;
        const fd = self.sock_fd orelse return;

        // Get unique service types
        var type_bufs: [16][64]u8 = undefined;
        var type_slices: [16][]u8 = undefined;
        for (&type_slices, &type_bufs) |*slice, *buf| {
            slice.* = buf[0..];
        }
        const type_count = services.getServiceTypes(&type_slices, 16);
        if (type_count == 0) return;

        var buf: [512]u8 = [_]u8{0} ** 512;
        var pkt = dns.DnsPacket.init(&buf);

        pkt.writeHeader(0x0000, dns.FLAGS_MDNS_RESPONSE) catch return;
        // Security: Bounds check before direct header writes (CLAUDE.md - Network Stack Security)
        if (buf.len < dns.DNS_HEADER_SIZE) return;
        std.mem.writeInt(u16, buf[4..6], 0, .big); // 0 questions
        std.mem.writeInt(u16, buf[6..8], @truncate(type_count), .big); // N answers

        // Write PTR record for each service type
        var i: usize = 0;
        while (i < type_count) : (i += 1) {
            var ptr_name: [96]u8 = undefined;
            const svc_type = type_slices[i];
            const ptr_len = buildTypePtrName(svc_type, &ptr_name);
            if (ptr_len == 0) continue;

            pkt.writePtrRecord(
                "_services._dns-sd._udp.local",
                dns.CLASS_IN,
                constants.MDNS_SERVICE_TTL,
                ptr_name[0..ptr_len],
            ) catch continue;
        }

        const dest = if (unicast and src_port != constants.MDNS_PORT)
            socket_types.SockAddrIn.init(src_addr, src_port)
        else
            socket_types.SockAddrIn.init(constants.MDNS_MULTICAST_IPV4, constants.MDNS_PORT);

        _ = udp_api.sendto(fd, buf[0..pkt.pos], &dest) catch {};
    }

    /// Send PTR responses listing service instances of a given type
    fn sendServicePtrResponse(self: *Responder, svc_type: []const u8, unicast: bool, src_addr: u32, src_port: u16) void {
        if (!self.tryConsumeRateToken()) return;
        const fd = self.sock_fd orelse return;

        var buf: [512]u8 = [_]u8{0} ** 512;
        var pkt = dns.DnsPacket.init(&buf);

        pkt.writeHeader(0x0000, dns.FLAGS_MDNS_RESPONSE) catch return;

        // Build query name for the type (type.local)
        var query_name: [96]u8 = undefined;
        var qn_pos: usize = 0;
        if (qn_pos + svc_type.len >= query_name.len) return;
        @memcpy(query_name[qn_pos..][0..svc_type.len], svc_type);
        qn_pos += svc_type.len;
        const suffix = ".local";
        if (qn_pos + suffix.len >= query_name.len) return;
        @memcpy(query_name[qn_pos..][0..suffix.len], suffix);
        qn_pos += suffix.len;

        // Count and write PTR records for each service instance
        var iter = services.iterateByType(svc_type);
        var answer_count: u16 = 0;
        while (iter.next()) |svc| {
            var full_name: [128]u8 = undefined;
            const full_len = svc.getFullName(&full_name);
            if (full_len == 0) continue;

            pkt.writePtrRecord(
                query_name[0..qn_pos],
                dns.CLASS_IN,
                svc.ttl,
                full_name[0..full_len],
            ) catch continue;
            answer_count += 1;
        }

        if (answer_count == 0) return;

        // Update answer count in header
        // Security: Bounds check before direct header writes (CLAUDE.md - Network Stack Security)
        if (buf.len < dns.DNS_HEADER_SIZE) return;
        std.mem.writeInt(u16, buf[4..6], 0, .big);
        std.mem.writeInt(u16, buf[6..8], answer_count, .big);

        const dest = if (unicast and src_port != constants.MDNS_PORT)
            socket_types.SockAddrIn.init(src_addr, src_port)
        else
            socket_types.SockAddrIn.init(constants.MDNS_MULTICAST_IPV4, constants.MDNS_PORT);

        _ = udp_api.sendto(fd, buf[0..pkt.pos], &dest) catch {};
    }

    /// Send SRV response for a specific service
    fn sendServiceSrvResponse(self: *Responder, svc: *const services.Service, unicast: bool, src_addr: u32, src_port: u16) void {
        if (!self.tryConsumeRateToken()) return;
        const fd = self.sock_fd orelse return;

        var buf: [512]u8 = [_]u8{0} ** 512;
        var pkt = dns.DnsPacket.init(&buf);

        pkt.writeHeader(0x0000, dns.FLAGS_MDNS_RESPONSE) catch return;
        // Security: Bounds check before direct header writes (CLAUDE.md - Network Stack Security)
        if (buf.len < dns.DNS_HEADER_SIZE) return;
        std.mem.writeInt(u16, buf[4..6], 0, .big); // 0 questions
        std.mem.writeInt(u16, buf[6..8], 1, .big); // 1 answer

        // Build full service instance name
        var full_name: [128]u8 = undefined;
        const full_len = svc.getFullName(&full_name);
        if (full_len == 0) return;

        // Build target hostname (hostname.local)
        var target: [128]u8 = undefined;
        const target_len = self.buildHostnameFqdn(&target);
        if (target_len == 0) return;

        // Write SRV record: priority=0, weight=0, port, target
        pkt.writeSrvRecord(
            full_name[0..full_len],
            dns.CLASS_IN | dns.MDNS_CACHE_FLUSH_BIT,
            svc.ttl,
            0, // priority
            0, // weight
            svc.port,
            target[0..target_len],
        ) catch return;

        const dest = if (unicast and src_port != constants.MDNS_PORT)
            socket_types.SockAddrIn.init(src_addr, src_port)
        else
            socket_types.SockAddrIn.init(constants.MDNS_MULTICAST_IPV4, constants.MDNS_PORT);

        _ = udp_api.sendto(fd, buf[0..pkt.pos], &dest) catch {};
    }

    /// Send TXT response for a specific service
    fn sendServiceTxtResponse(self: *Responder, svc: *const services.Service, unicast: bool, src_addr: u32, src_port: u16) void {
        if (!self.tryConsumeRateToken()) return;
        const fd = self.sock_fd orelse return;

        var buf: [512]u8 = [_]u8{0} ** 512;
        var pkt = dns.DnsPacket.init(&buf);

        pkt.writeHeader(0x0000, dns.FLAGS_MDNS_RESPONSE) catch return;
        // Security: Bounds check before direct header writes (CLAUDE.md - Network Stack Security)
        if (buf.len < dns.DNS_HEADER_SIZE) return;
        std.mem.writeInt(u16, buf[4..6], 0, .big); // 0 questions
        std.mem.writeInt(u16, buf[6..8], 1, .big); // 1 answer

        // Build full service instance name
        var full_name: [128]u8 = undefined;
        const full_len = svc.getFullName(&full_name);
        if (full_len == 0) return;

        // Write TXT record
        pkt.writeTxtRecord(
            full_name[0..full_len],
            dns.CLASS_IN | dns.MDNS_CACHE_FLUSH_BIT,
            svc.ttl,
            svc.txt[0..svc.txt_len],
        ) catch return;

        const dest = if (unicast and src_port != constants.MDNS_PORT)
            socket_types.SockAddrIn.init(src_addr, src_port)
        else
            socket_types.SockAddrIn.init(constants.MDNS_MULTICAST_IPV4, constants.MDNS_PORT);

        _ = udp_api.sendto(fd, buf[0..pkt.pos], &dest) catch {};
    }

    /// Check if a response conflicts with our hostname during probing
    fn checkForConflict(self: *Responder, pkt_data: []const u8) void {
        if (pkt_data.len < dns.DNS_HEADER_SIZE) return;

        const hdr: *align(1) const dns.Header = @ptrCast(pkt_data.ptr);
        const an_count = hdr.getAnCount();
        if (an_count == 0) return;

        // Skip questions
        var pos: usize = dns.DNS_HEADER_SIZE;
        const qd_count = hdr.getQdCount();
        var name_buf: [256]u8 = [_]u8{0} ** 256;

        var i: u16 = 0;
        while (i < qd_count) : (i += 1) {
            const name_result = dns.readName(pkt_data, pos, &name_buf) catch return;
            // Security: Use checked arithmetic to prevent overflow (CLAUDE.md)
            pos = std.math.add(usize, name_result.end_pos, 4) catch return; // Skip qtype and qclass
        }

        // Check answers for our hostname
        i = 0;
        while (i < an_count) : (i += 1) {
            if (pos >= pkt_data.len) break;

            const rr_result = dns.readResourceRecordHeader(pkt_data, pos, &name_buf) catch break;

            if (self.matchesHostname(rr_result.name)) {
                // Someone else is claiming our hostname - conflict!
                self.state = .conflict;
                return;
            }

            // Skip RDATA - use checked arithmetic to prevent overflow (CLAUDE.md)
            pos = std.math.add(usize, rr_result.rdata_pos, rr_result.rdlength) catch break;
        }
    }

    /// Send a response for a query
    fn sendResponse(self: *Responder, name: []const u8, record_type: u16, unicast: bool, src_addr: u32, src_port: u16) void {
        // Rate limiting to prevent amplification attacks (RFC 6762 Section 6)
        if (!self.tryConsumeRateToken()) return;

        const fd = self.sock_fd orelse return;
        const iface = self.iface orelse return;

        var buf: [512]u8 = [_]u8{0} ** 512;
        var pkt = dns.DnsPacket.init(&buf);

        // Build response
        pkt.writeHeader(0x0000, dns.FLAGS_MDNS_RESPONSE) catch return;

        // Update header: 0 questions, 1 answer
        // Security: Bounds check before direct header writes (CLAUDE.md - Network Stack Security)
        if (buf.len < dns.DNS_HEADER_SIZE) return;
        std.mem.writeInt(u16, buf[4..6], 0, .big);
        std.mem.writeInt(u16, buf[6..8], 1, .big);

        // Write A record
        if (record_type == dns.TYPE_A) {
            pkt.writeARecord(
                name,
                dns.CLASS_IN | dns.MDNS_CACHE_FLUSH_BIT,
                constants.MDNS_HOST_TTL,
                iface.ip_addr,
            ) catch return;
        }

        // Determine destination
        const dest_addr = if (unicast and src_port != constants.MDNS_PORT)
            // Unicast response to querier
            socket_types.SockAddrIn.init(src_addr, src_port)
        else
            // Multicast response
            socket_types.SockAddrIn.init(constants.MDNS_MULTICAST_IPV4, constants.MDNS_PORT);

        _ = udp_api.sendto(fd, buf[0..pkt.pos], &dest_addr) catch {};
    }

    /// Build hostname.local FQDN
    fn buildHostnameFqdn(self: *Responder, out: []u8) usize {
        if (self.hostname_len + 6 >= out.len) return 0; // ".local" = 6 chars

        @memcpy(out[0..self.hostname_len], self.hostname[0..self.hostname_len]);
        const suffix = ".local";
        @memcpy(out[self.hostname_len..][0..suffix.len], suffix);

        return self.hostname_len + suffix.len;
    }

    /// Check if name matches our hostname.local
    fn matchesHostname(self: *Responder, name: []const u8) bool {
        var fqdn_buf: [128]u8 = undefined;
        const fqdn_len = self.buildHostnameFqdn(&fqdn_buf);
        if (fqdn_len == 0) return false;

        // Case-insensitive comparison
        if (name.len != fqdn_len) return false;

        for (name, fqdn_buf[0..fqdn_len]) |a, b| {
            const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (la != lb) return false;
        }

        return true;
    }
};

// =============================================================================
// Helper Functions (module level)
// =============================================================================

/// Case-insensitive string comparison (DNS names are case-insensitive per RFC 1035)
fn caseInsensitiveEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

/// Extract service type from a query name (strips .local suffix)
/// e.g., "_http._tcp.local" -> "_http._tcp"
fn extractServiceType(query_name: []const u8, out: []u8) ?[]const u8 {
    const local_suffix = ".local";
    if (query_name.len <= local_suffix.len) return null;

    // Check for .local suffix (case-insensitive)
    const suffix_start = query_name.len - local_suffix.len;
    if (!caseInsensitiveEqual(query_name[suffix_start..], local_suffix)) return null;

    const svc_type = query_name[0..suffix_start];
    if (svc_type.len == 0 or svc_type.len > out.len) return null;

    @memcpy(out[0..svc_type.len], svc_type);
    return out[0..svc_type.len];
}

/// Parsed service instance name result
const ParsedServiceInstance = struct {
    instance: []const u8,
    svc_type: []const u8,
};

/// Parse a service instance name into instance and type
/// e.g., "My Server._http._tcp.local" -> { "My Server", "_http._tcp" }
fn parseServiceInstanceName(query_name: []const u8, instance_out: []u8, type_out: []u8) ?ParsedServiceInstance {
    const local_suffix = ".local";
    if (query_name.len <= local_suffix.len) return null;

    // Check for .local suffix
    const suffix_start = query_name.len - local_suffix.len;
    if (!caseInsensitiveEqual(query_name[suffix_start..], local_suffix)) return null;

    const without_local = query_name[0..suffix_start];

    // Find the service type pattern (_xxx._yyy)
    // Look for ._xxx._yyy at the end
    var type_start: ?usize = null;
    var underscore_count: usize = 0;
    var i = without_local.len;
    while (i > 0) {
        i -= 1;
        if (without_local[i] == '_') {
            underscore_count += 1;
            if (underscore_count == 2) {
                // Found _protocol._transport pattern
                // Back up to find the dot before the first underscore
                if (i > 0 and without_local[i - 1] == '.') {
                    type_start = i;
                }
                break;
            }
        }
    }

    if (type_start == null) return null;
    const ts = type_start.?;

    // Instance name is everything before the service type (minus the dot)
    if (ts == 0) return null;
    const instance_len = ts - 1;
    if (instance_len == 0 or instance_len > instance_out.len) return null;

    // Service type is from ts to end
    const type_len = without_local.len - ts;
    if (type_len == 0 or type_len > type_out.len) return null;

    @memcpy(instance_out[0..instance_len], without_local[0..instance_len]);
    @memcpy(type_out[0..type_len], without_local[ts..]);

    return .{
        .instance = instance_out[0..instance_len],
        .svc_type = type_out[0..type_len],
    };
}

/// Build PTR name for a service type (type.local)
fn buildTypePtrName(svc_type: []const u8, out: []u8) usize {
    const suffix = ".local";
    if (svc_type.len + suffix.len > out.len) return 0;

    @memcpy(out[0..svc_type.len], svc_type);
    @memcpy(out[svc_type.len..][0..suffix.len], suffix);

    return svc_type.len + suffix.len;
}

/// Global responder instance
var global_responder: Responder = undefined;
var responder_initialized: bool = false;

/// Initialize the global responder
pub fn init(iface: *Interface, hostname: []const u8) !void {
    if (responder_initialized) return;

    try global_responder.init(iface, hostname);
    responder_initialized = true;
}

/// Deinitialize the global responder
pub fn deinit() void {
    if (!responder_initialized) return;

    global_responder.deinit();
    responder_initialized = false;
}

/// Tick handler for global responder
pub fn tick() void {
    if (!responder_initialized) return;
    global_responder.tick();
}

/// Get current responder state
pub fn getState() ResponderState {
    if (!responder_initialized) return .probing;
    return global_responder.state;
}

/// Get current hostname
pub fn getHostname() []const u8 {
    if (!responder_initialized) return "unknown";
    return global_responder.hostname[0..global_responder.hostname_len];
}
