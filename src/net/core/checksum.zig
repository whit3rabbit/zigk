// Network Checksum Calculations
//
// Implements IP and UDP/ICMP checksum algorithms.
// Uses the standard ones' complement sum algorithm.

/// Calculate IP header checksum
/// Returns checksum in network byte order
pub fn ipChecksum(header: []const u8) u16 {
    return onesComplement(header);
}

/// Calculate ICMP checksum over entire ICMP message
/// Returns checksum in network byte order
pub fn icmpChecksum(data: []const u8) u16 {
    return onesComplement(data);
}

/// Calculate UDP checksum with pseudo-header.
/// UDP only: protocol value (17) is baked in; do not reuse for TCP.
/// src_ip and dst_ip should be in network byte order.
/// udp_segment_with_header must include the UDP header and payload.
pub fn udpChecksum(src_ip: u32, dst_ip: u32, udp_segment_with_header: []const u8) u16 {
    var sum: u32 = 0;

    // Pseudo-header: src_ip, dst_ip, zero, protocol, udp_length
    sum += @as(u32, @truncate(src_ip >> 16));
    sum += @as(u32, @truncate(src_ip));
    sum += @as(u32, @truncate(dst_ip >> 16));
    sum += @as(u32, @truncate(dst_ip));
    sum += 17; // UDP protocol
    sum += @as(u32, @truncate(udp_segment_with_header.len));

    // UDP header + data
    var i: usize = 0;
    while (i + 1 < udp_segment_with_header.len) : (i += 2) {
        const word = (@as(u32, udp_segment_with_header[i]) << 8) | @as(u32, udp_segment_with_header[i + 1]);
        sum += word;
    }

    // Handle odd byte
    if (i < udp_segment_with_header.len) {
        sum += @as(u32, udp_segment_with_header[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    // Return ones' complement
    const result = ~@as(u16, @truncate(sum));
    return if (result == 0) 0xFFFF else result;
}

/// Calculate TCP checksum with pseudo-header.
/// TCP only: protocol value (6) is baked in.
/// src_ip and dst_ip should be in network byte order.
/// tcp_segment_with_header must include the TCP header and payload.
pub fn tcpChecksum(src_ip: u32, dst_ip: u32, tcp_segment_with_header: []const u8) u16 {
    var sum: u32 = 0;

    // Pseudo-header: src_ip, dst_ip, zero, protocol, tcp_length
    sum += @as(u32, @truncate(src_ip >> 16));
    sum += @as(u32, @truncate(src_ip));
    sum += @as(u32, @truncate(dst_ip >> 16));
    sum += @as(u32, @truncate(dst_ip));
    sum += 6; // TCP protocol
    sum += @as(u32, @truncate(tcp_segment_with_header.len));

    // TCP header + data
    var i: usize = 0;
    while (i + 1 < tcp_segment_with_header.len) : (i += 2) {
        const word = (@as(u32, tcp_segment_with_header[i]) << 8) | @as(u32, tcp_segment_with_header[i + 1]);
        sum += word;
    }

    // Handle odd byte
    if (i < tcp_segment_with_header.len) {
        sum += @as(u32, tcp_segment_with_header[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    // Return ones' complement
    const result = ~@as(u16, @truncate(sum));
    return if (result == 0) 0xFFFF else result;
}

/// Ones' complement checksum (used by IP, ICMP, TCP, UDP)
fn onesComplement(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    // Sum 16-bit words
    while (i + 1 < data.len) : (i += 2) {
        const word = (@as(u32, data[i]) << 8) | @as(u32, data[i + 1]);
        sum += word;
    }

    // Handle odd byte
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    // Return ones' complement in network byte order
    return @byteSwap(~@as(u16, @truncate(sum)));
}

/// Verify IP header checksum
pub fn verifyIpChecksum(header: []const u8) bool {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i + 1 < header.len) : (i += 2) {
        const word = (@as(u32, header[i]) << 8) | @as(u32, header[i + 1]);
        sum += word;
    }

    // Fold and check
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return (@as(u16, @truncate(sum)) == 0xFFFF);
}

/// Incremental checksum update when modifying a field
/// old_value and new_value in host byte order
pub fn updateChecksum(old_checksum: u16, old_value: u16, new_value: u16) u16 {
    // RFC 1624 algorithm for incremental checksum update
    var sum: u32 = @as(u32, ~old_checksum & 0xFFFF);
    sum += @as(u32, ~old_value & 0xFFFF);
    sum += @as(u32, new_value);

    // Fold
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~@as(u16, @truncate(sum));
}
