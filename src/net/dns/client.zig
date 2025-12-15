const std = @import("std");
const dns = @import("dns.zig");
const socket = @import("../transport/socket.zig");
const ipv4 = @import("../ipv4/ipv4.zig");
const hal = @import("hal");

pub const DnsError = error{
    SocketError,
    SendError,
    RecvError,
    FormatError,
    ServerFailure,
    NameError,
    NotImplemented,
    Refused,
    NoAnswer,
    TimedOut,
    NameTooLong, // RFC 1035: domain name exceeds 253 bytes
    Truncated, // TC flag set, response truncated (needs TCP)
    IdMismatch, // Transaction ID mismatch (possible spoofing)
    CnameLoop, // RFC 1034: exceeded max CNAME chain depth (8)
    BufferTooSmall, // Output buffer too small for name
};

/// Result of a single DNS query - either an IP address or a CNAME target
const ResolveResult = union(enum) {
    ip: u32,
    cname: []const u8,
};

/// Resolve hostname to IPv4 address with CNAME following.
/// Follows up to DNS_MAX_CNAME_DEPTH (8) CNAME redirects per RFC 1034.
/// allocator: Reserved for future use (EDNS0 large responses, DNS caching, TCP fallback)
/// server_ip: DNS server address in network byte order
pub fn resolve(allocator: std.mem.Allocator, hostname: []const u8, server_ip: u32) !u32 {
    // Stack-allocated buffers for CNAME chain (no heap allocation)
    var current_name_buf: [dns.DNS_MAX_NAME_LENGTH]u8 = undefined;
    var cname_buf: [dns.DNS_MAX_NAME_LENGTH]u8 = undefined;
    var current_name: []const u8 = hostname;

    var depth: u8 = 0;
    while (depth < dns.DNS_MAX_CNAME_DEPTH) : (depth += 1) {
        const result = try resolveOnce(allocator, current_name, server_ip, &cname_buf);

        switch (result) {
            .ip => |ip| return ip,
            .cname => |cname_target| {
                // Copy CNAME target for next iteration
                if (cname_target.len > current_name_buf.len) return DnsError.NameTooLong;
                @memcpy(current_name_buf[0..cname_target.len], cname_target);
                current_name = current_name_buf[0..cname_target.len];
            },
        }
    }

    return DnsError.CnameLoop; // Exceeded max CNAME depth
}

/// Compare two DNS names case-insensitively (DNS is case-insensitive per RFC 1035)
fn dnsNameEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

/// Single DNS query - returns either IP address or CNAME target.
/// cname_buf is used to store CNAME target if one is found.
fn resolveOnce(allocator: std.mem.Allocator, hostname: []const u8, server_ip: u32, cname_buf: []u8) !ResolveResult {
    _ = allocator; // Reserved for future use (EDNS0, caching, TCP fallback)

    // Validate hostname length per RFC 1035 (max 253 bytes)
    if (hostname.len > dns.DNS_MAX_NAME_LENGTH) return DnsError.NameTooLong;

    // Create UDP socket
    const fd_idx = try socket.socket(socket.AF_INET, socket.SOCK_DGRAM, 0);
    errdefer socket.close(fd_idx) catch {};

    // Security (RFC 5452): Explicitly bind to a random source port.
    // Uses Algorithm 3 (Random Port Randomization) for maximum entropy.
    // Combined with 16-bit transaction ID, provides ~32 bits of unpredictability
    // against DNS cache poisoning attacks.
    const random_port = socket.allocateRandomEphemeralPort();
    if (random_port == 0) return DnsError.SocketError;

    const bind_addr = socket.SockAddrIn{
        .family = socket.AF_INET,
        .port = socket.htons(random_port),
        .addr = 0, // INADDR_ANY
        .zero = [_]u8{0} ** 8,
    };
    socket.bind(fd_idx, &bind_addr) catch return DnsError.SocketError;

    // Set timeout (2 seconds)
    try socket.setsockopt(fd_idx, socket.SOL_SOCKET, socket.SO_RCVTIMEO, std.mem.asBytes(&socket.TimeVal.fromMillis(2000)), @sizeOf(socket.TimeVal));

    // Prepare buffer
    var send_buf: [512]u8 = undefined;
    var packet = dns.DnsPacket.init(&send_buf);

    // Generate random Transaction ID using hardware entropy directly.
    // Security: XORing entropy with timestamp can reduce entropy if either
    // source is predictable. Using hardware entropy directly preserves full
    // 16 bits of unpredictability for DNS spoofing resistance.
    const tx_id = @as(u16, @truncate(hal.entropy.getHardwareEntropy()));

    // Write Query
    packet.writeHeader(tx_id, dns.FLAGS_RD); // Recursion Desired
    try packet.writeName(hostname);
    try packet.writeQuestion(dns.TYPE_A, dns.CLASS_IN);

    const query_len = packet.pos;

    // Send to server
    const dest = socket.SockAddrIn{
        .family = socket.AF_INET,
        .port = socket.htons(53),
        .addr = server_ip,
        .zero = [_]u8{0} ** 8,
    };

    const sent = try socket.sendto(fd_idx, send_buf[0..query_len], &dest);
    if (sent != query_len) return DnsError.SendError;

    // Receive response
    var recv_buf: [512]u8 = undefined;
    var src_addr: socket.SockAddrIn = std.mem.zeroes(socket.SockAddrIn);
    var received: usize = 0;
    while (true) {
        received = try socket.recvfrom(fd_idx, &recv_buf, &src_addr);

        // Validate response came from expected DNS server (RFC 5452)
        if (src_addr.addr != server_ip or src_addr.getPort() != 53) {
            // Ignore spoofed packet, keep waiting until timeout
            continue;
        }

        if (received < 12) {
            // Malformed - ignore and keep waiting
            continue;
        }

        const resp = recv_buf[0..received];
        const resp_id = @as(u16, resp[0]) << 8 | resp[1];
        if (resp_id != tx_id) {
            // Keep listening until timeout expires
            continue;
        }

        break;
    }

    // Close socket (we are done with network)
    socket.close(fd_idx) catch {};

    // Parse Response
    const resp = recv_buf[0..received];

    const flags = @as(u16, resp[2]) << 8 | resp[3];

    // Validate this is a response, not a query
    if ((flags & dns.FLAGS_QR_RESPONSE) == 0) return DnsError.FormatError;

    // Check for truncation (TC flag)
    if ((flags & dns.FLAGS_TC) != 0) return DnsError.Truncated;

    // Handle RCODE
    const rcode = flags & 0x000F;
    switch (rcode) {
        0 => {}, // No error, continue
        1 => return DnsError.FormatError, // FORMERR
        2 => return DnsError.ServerFailure, // SERVFAIL
        3 => return DnsError.NameError, // NXDOMAIN
        4 => return DnsError.NotImplemented, // NOTIMP
        5 => return DnsError.Refused, // REFUSED
        else => return DnsError.FormatError, // Unknown RCODE
    }

    const qd_count = @as(u16, resp[4]) << 8 | resp[5];
    const an_count = @as(u16, resp[6]) << 8 | resp[7];

    // Validate counts to prevent DoS
    if (qd_count > 50 or an_count > 50) return DnsError.FormatError;

    if (an_count == 0) return DnsError.NoAnswer;

    // Skip Header
    var pos: usize = dns.DNS_HEADER_SIZE;

    // Verify Questions (RFC 5452)
    // The response must contain the same question we asked.
    var owner_name_buf: [dns.DNS_MAX_NAME_LENGTH]u8 = undefined;
    var i: usize = 0;
    while (i < qd_count) : (i += 1) {
        // Read name from question section
        const q_result = dns.readName(resp, pos, &owner_name_buf) catch |err| switch (err) {
            error.FormatError => return DnsError.FormatError,
            error.BufferTooSmall => return DnsError.BufferTooSmall,
        };
        
        // Security: Verify the question in the response matches what we asked
        // We only asked one question, so any question in response must match it
        if (!dnsNameEql(q_result.name, hostname)) {
             // Possible spoofing attempt or mixed-up response
             return DnsError.IdMismatch; 
        }
        
        pos = q_result.end_pos;

        // Skip QTYPE (2) and QCLASS (2)
        if (pos + 4 > resp.len) return DnsError.FormatError;
        
        // Optionally verify QTYPE/QCLASS too, but name is the most critical
        const qtype = @as(u16, resp[pos]) << 8 | resp[pos + 1];
        const qclass = @as(u16, resp[pos + 2]) << 8 | resp[pos + 3];
        
        if (qtype != dns.TYPE_A or qclass != dns.CLASS_IN) {
            // We only ask for A/IN
             return DnsError.FormatError;
        }

        pos += 4;
    }

    // Parse Answers - look for A record first, then CNAME if no A found
    var cname_result: ?ResolveResult = null;


    i = 0;
    while (i < an_count) : (i += 1) {
        // Read owner name to validate it matches our query (security check)
        const owner_result = dns.readName(resp, pos, &owner_name_buf) catch |err| switch (err) {
            error.FormatError => return DnsError.FormatError,
            error.BufferTooSmall => return DnsError.BufferTooSmall,
        };
        pos = owner_result.end_pos;

        if (pos + 10 > resp.len) return DnsError.FormatError;

        const rtype = @as(u16, resp[pos]) << 8 | resp[pos + 1];
        const rclass = @as(u16, resp[pos + 2]) << 8 | resp[pos + 3];
        // ttl (4) at pos+4
        const rdlen = @as(u16, resp[pos + 8]) << 8 | resp[pos + 9];
        pos += 10;

        if (pos + rdlen > resp.len) return DnsError.FormatError;

        // Security: Validate owner name matches our queried hostname to prevent
        // a malicious DNS server from injecting records for unrelated domains.
        const owner_matches = dnsNameEql(owner_result.name, hostname);

        if (rtype == dns.TYPE_A and rclass == dns.CLASS_IN and rdlen == 4 and owner_matches) {
            // Found A record for our query - return immediately
            const ip = std.mem.readInt(u32, resp[pos..][0..4], .big);
            return .{ .ip = ip };
        }

        if (rtype == dns.TYPE_CNAME and rclass == dns.CLASS_IN and cname_result == null and owner_matches) {
            // Found CNAME for our query - extract target name for potential follow-up
            const name_result = dns.readName(resp, pos, cname_buf) catch |err| switch (err) {
                error.FormatError => return DnsError.FormatError,
                error.BufferTooSmall => return DnsError.BufferTooSmall,
            };
            cname_result = .{ .cname = name_result.name };
        }

        pos += rdlen;
    }

    // No A record found - return CNAME if we found one
    if (cname_result) |result| {
        return result;
    }

    return DnsError.NoAnswer;
}

/// Skip over a DNS name in the response buffer
/// Handles both labels and compression pointers (RFC 1035 section 4.1.4)
/// Includes protection against malicious pointer loops (max 10 jumps)
fn skipName(buf: []const u8, start: usize) !usize {
    var pos = start;
    var jumps: u8 = 0;
    // L4: Use RFC 1035 constant instead of magic number
    const max_jumps = dns.DNS_MAX_COMPRESSION_JUMPS;

    while (true) {
        if (pos >= buf.len) return DnsError.FormatError;
        const len_byte = buf[pos];

        if (len_byte == 0) {
            return pos + 1; // End of name
        }

        if ((len_byte & 0xC0) == 0xC0) {
            // Compression pointer - check for loop attack
            jumps += 1;
            if (jumps > max_jumps) return DnsError.FormatError;
            // We don't follow the pointer (just skipping), but count it
            // to detect malformed packets with many pointers
            return pos + 2;
        }

        // Label - bounds check before skipping
        if (pos + 1 + len_byte > buf.len) return DnsError.FormatError;
        pos += 1 + len_byte;
    }
}
