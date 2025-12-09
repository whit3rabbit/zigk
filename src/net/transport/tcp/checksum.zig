const packet = @import("../../core/packet.zig");

/// Calculate TCP checksum with pseudo-header
/// src_ip and dst_ip in network byte order
pub fn tcpChecksum(src_ip: u32, dst_ip: u32, tcp_segment: []const u8) u16 {
    var sum: u32 = 0;

    // Pseudo-header: src_ip(4) + dst_ip(4) + zero(1) + proto(1) + tcp_len(2)
    sum += @as(u32, @truncate(src_ip >> 16));
    sum += @as(u32, @truncate(src_ip));
    sum += @as(u32, @truncate(dst_ip >> 16));
    sum += @as(u32, @truncate(dst_ip));
    sum += 6; // TCP protocol number
    sum += @as(u32, @truncate(tcp_segment.len));

    // TCP segment (header + data)
    var i: usize = 0;
    while (i + 1 < tcp_segment.len) : (i += 2) {
        const word = (@as(u32, tcp_segment[i]) << 8) | @as(u32, tcp_segment[i + 1]);
        sum += word;
    }

    // Handle odd byte
    if (i < tcp_segment.len) {
        sum += @as(u32, tcp_segment[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    // Return one's complement
    const result = ~@as(u16, @truncate(sum));
    return if (result == 0) 0xFFFF else result;
}
