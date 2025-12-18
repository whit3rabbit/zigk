// Network Checksum Calculations
//
// Implements IP and UDP/ICMP/TCP checksum algorithms.
// Uses the standard ones' complement sum algorithm per RFC 1071.
//
// BYTE ORDER: All checksum functions return the computed checksum value
// suitable for direct assignment to packed network header fields.
// The computation treats input bytes as network byte order (big-endian).
// On little-endian architectures (x86_64), the returned value, when stored
// to a u16 field, will produce correct network-order bytes if the struct
// field uses @byteSwap or equivalent for network<->host conversion.

/// Calculate IP header checksum.
/// Input: IP header bytes in network byte order.
/// Returns: Ones' complement checksum for direct assignment to header field.
pub fn ipChecksum(header: []const u8) u16 {
    return onesComplement(header);
}

/// Calculate ICMP checksum over entire ICMP message.
/// Input: ICMP message bytes in network byte order.
/// Returns: Ones' complement checksum for direct assignment to header field.
pub fn icmpChecksum(data: []const u8) u16 {
    return onesComplement(data);
}

/// Calculate UDP checksum with pseudo-header (RFC 768).
/// UDP only: protocol value (17) is baked in; do not reuse for TCP.
///
/// Parameters:
///   src_ip: Source IP address in network byte order (as stored in IP header).
///   dst_ip: Destination IP address in network byte order.
///   udp_segment_with_header: UDP header + payload bytes.
///
/// Returns: Ones' complement checksum for direct assignment to UDP checksum field.
///   Per RFC 768, returns 0xFFFF instead of 0x0000 (zero is reserved for "no checksum").
///
/// SECURITY: This function assumes the slice length is validated by the caller.
/// If an attacker provides a crafted IP packet claiming a total_length larger than
/// the actual buffer, the slice passed here may be shorter than claimed, producing
/// a checksum that validates truncated data. Conversely, slices > 65535 bytes
/// (impossible in valid IP) will have their length truncated to u16, potentially
/// causing checksum miscalculation.
///
/// Risk: Medium - checksum bypass or validation of corrupted data.
/// Mitigation: IP layer must validate total_length against actual buffer size
/// before calling transport checksum functions.
pub fn udpChecksum(src_ip: u32, dst_ip: u32, udp_segment_with_header: []const u8) u16 {
    // SECURITY: Reject segments that exceed maximum IP payload size.
    // Truncating lengths > 65535 to u16 would produce incorrect checksums
    // that could validate corrupted/truncated data. This should never happen
    // with properly validated IP packets, but we enforce it here as defense-in-depth.
    if (udp_segment_with_header.len > 65535) {
        return 0; // Invalid - checksum will fail validation
    }

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

/// Calculate TCP checksum with pseudo-header (RFC 793).
/// TCP only: protocol value (6) is baked in.
///
/// Parameters:
///   src_ip: Source IP address in network byte order (as stored in IP header).
///   dst_ip: Destination IP address in network byte order.
///   tcp_segment_with_header: TCP header + payload bytes.
///
/// Returns: Ones' complement checksum for direct assignment to TCP checksum field.
///   Per RFC 793, returns 0xFFFF instead of 0x0000 (zero would indicate no checksum,
///   but TCP checksum is mandatory unlike UDP).
///
/// SECURITY: Same considerations as udpChecksum - see that function's documentation.
/// Callers must validate segment length against IP total_length before calling.
pub fn tcpChecksum(src_ip: u32, dst_ip: u32, tcp_segment_with_header: []const u8) u16 {
    // SECURITY: Reject segments that exceed maximum IP payload size.
    // Same rationale as udpChecksum - prevents checksum bypass via length truncation.
    if (tcp_segment_with_header.len > 65535) {
        return 0; // Invalid - checksum will fail validation
    }

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

/// Ones' complement checksum (used by IP, ICMP).
/// Computes RFC 1071 Internet Checksum over the provided data.
/// Unlike UDP/TCP, IP and ICMP don't have pseudo-headers.
fn onesComplement(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    // Sum 16-bit words (treating bytes as big-endian per RFC 1071)
    while (i + 1 < data.len) : (i += 2) {
        const word = (@as(u32, data[i]) << 8) | @as(u32, data[i + 1]);
        sum += word;
    }

    // Handle odd byte (pad with zero per RFC 1071)
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    // Return ones' complement
    return ~@as(u16, @truncate(sum));
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

/// Incremental checksum update when modifying a single 16-bit field (RFC 1624).
/// Use this for efficient checksum recalculation when only one field changes
/// (e.g., TTL decrement during IP forwarding).
///
/// Parameters:
///   old_checksum: Current checksum value from the header.
///   old_value: Original value of the field being modified.
///   new_value: New value for the field.
///
/// All parameters should be in the same byte order (typically the value as stored
/// in the header field). The function preserves byte order of the checksum.
///
/// Returns: Updated checksum value.
pub fn updateChecksum(old_checksum: u16, old_value: u16, new_value: u16) u16 {
    // RFC 1624: HC' = ~(~HC + ~m + m')
    var sum: u32 = @as(u32, ~old_checksum & 0xFFFF);
    sum += @as(u32, ~old_value & 0xFFFF);
    sum += @as(u32, new_value);

    // Fold carries
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~@as(u16, @truncate(sum));
}
