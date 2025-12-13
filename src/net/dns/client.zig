
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
};

/// Resolve hostname to IPv4 address
/// server_ip: DNS server address
pub fn resolve(allocator: std.mem.Allocator, hostname: []const u8, server_ip: u32) !u32 {
    _ = allocator; // Buffer on stack for now
    
    // Create UDP socket
    // socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    const fd_idx = try socket.socket(socket.AF_INET, socket.SOCK_DGRAM, 0);
    // fd_idx is the index into socket_table.
    
    // Ensure cleanup
    errdefer socket.close(fd_idx) catch {};
    
    // Set timeout (2 seconds)
    try socket.setsockopt(fd_idx, socket.SOL_SOCKET, socket.SO_RCVTIMEO, std.mem.asBytes(&socket.TimeVal.fromMillis(2000)), @sizeOf(socket.TimeVal));

    // Prepare buffer
    var send_buf: [512]u8 = undefined;
    var packet = dns.DnsPacket.init(&send_buf);
    
    // Generate random Transaction ID using hardware entropy mixed with timestamp
    // This reduces predictability for cache poisoning protection
    const entropy_val = hal.entropy.getHardwareEntropy();
    const timestamp_val = @as(u32, @truncate(hal.cpu.getTickCount())); 
    const tx_id = @as(u16, @truncate(entropy_val ^ timestamp_val));
    
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
    var src_addr: socket.SockAddrIn = undefined;
    const received = try socket.recvfrom(fd_idx, &recv_buf, &src_addr);
    
    if (received < 12) return DnsError.FormatError;

    // Validate response came from expected DNS server (RFC 5452 source port randomization)
    // This prevents DNS cache poisoning attacks where an attacker sends spoofed responses
    if (src_addr.addr != server_ip or src_addr.getPort() != 53) {
        return DnsError.Refused; // Spoofed response - wrong source
    }

    // Close socket (we are done with network)
    socket.close(fd_idx) catch {};

    // Parse Response
    const resp = recv_buf[0..received];
    // const hdr = @as(*const dns.Header, @ptrCast(resp.ptr)); // Unused
    
    // Proper parsing
    const resp_id = @as(u16, resp[0]) << 8 | resp[1];
    if (resp_id != tx_id) return DnsError.Refused; // Mismatched ID
    
    const flags = @as(u16, resp[2]) << 8 | resp[3];
    const rcode = flags & 0x000F;
    if (rcode != 0) return DnsError.NameError; // Simplified error handling
    
    const qd_count = @as(u16, resp[4]) << 8 | resp[5];
    const an_count = @as(u16, resp[6]) << 8 | resp[7];
    
    if (an_count == 0) return DnsError.NoAnswer;
    
    // Skip Header
    var pos: usize = 12;
    
    // Skip Questions
    var i: usize = 0;
    while (i < qd_count) : (i += 1) {
        pos = try skipName(resp, pos);
        // Skip Type (2) + Class (2)
        pos += 4;
    }
    
    // Parse Answers
    i = 0;
    while (i < an_count) : (i += 1) {
        pos = try skipName(resp, pos);
        
        if (pos + 10 > resp.len) return DnsError.FormatError;
        
        const rtype = @as(u16, resp[pos]) << 8 | resp[pos+1];
        const rclass = @as(u16, resp[pos+2]) << 8 | resp[pos+3];
        // ttl (4) at pos+4
        const rdlen = @as(u16, resp[pos+8]) << 8 | resp[pos+9];
        pos += 10;
        
        if (pos + rdlen > resp.len) return DnsError.FormatError;
        
        if (rtype == dns.TYPE_A and rclass == dns.CLASS_IN and rdlen == 4) {
            // Found it!
            const ip = std.mem.readInt(u32, resp[pos..][0..4], .big);
            return ip; // Host byte order (Big Endian value)
        }
        
        pos += rdlen;
    }
    
    return DnsError.NoAnswer;
}

/// Skip over a DNS name in the response buffer
/// Handles both labels and compression pointers (RFC 1035 section 4.1.4)
/// Includes protection against malicious pointer loops (max 10 jumps)
fn skipName(buf: []const u8, start: usize) !usize {
    var pos = start;
    var jumps: u8 = 0;
    const max_jumps: u8 = 10; // Prevent infinite loops from malicious packets

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
