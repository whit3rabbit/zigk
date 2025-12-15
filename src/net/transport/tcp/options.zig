const c = @import("constants.zig");
const state = @import("state.zig");
const Tcb = @import("types.zig").Tcb;
const TcpHeader = @import("types.zig").TcpHeader;
const PacketBuffer = @import("../../core/packet.zig").PacketBuffer;

/// Parsed TCP options structure
pub const TcpOptions = struct {
    mss_present: bool = false,
    mss: u16 = c.DEFAULT_MSS,
    wscale_present: bool = false,
    wscale: u8 = 0,
    sack_permitted: bool = false,
    timestamp_present: bool = false,
    ts_val: u32 = 0,
    ts_ecr: u32 = 0,
};

/// Parse MSS option from TCP header (legacy wrapper for backward compatibility)
pub fn parseMssOption(pkt: *const PacketBuffer, tcp_hdr: *const TcpHeader) ?u16 {
    var opts = TcpOptions{};
    parseOptions(pkt, tcp_hdr, &opts);
    return if (opts.mss_present) opts.mss else null;
}

/// Parse all TCP options from header (RFC 793, 7323, 2018)
/// Sets fields in the opts struct based on options found
pub fn parseOptions(pkt: *const PacketBuffer, tcp_hdr: *const TcpHeader, opts: *TcpOptions) void {
    const header_len = tcp_hdr.getDataOffset();
    if (header_len <= c.TCP_HEADER_SIZE) {
        return; // No options
    }

    // Security: Validate header length against packet bounds before parsing
    const options_start = pkt.transport_offset + c.TCP_HEADER_SIZE;
    const options_end = pkt.transport_offset + header_len;
    const options_len = header_len - c.TCP_HEADER_SIZE;

    if (options_end > pkt.len) {
        return; // Header claims more data than packet contains
    }

    // Track bytes consumed to detect malformed packets
    var bytes_consumed: usize = 0;
    var i = options_start;
    while (i < options_end and bytes_consumed < options_len) {
        const kind = pkt.data[i];

        switch (kind) {
            c.TCPOPT_EOL => return, // End of options list
            c.TCPOPT_NOP => {
                i += 1; // Single-byte option
                bytes_consumed += 1;
                continue;
            },
            c.TCPOPT_MSS => {
                // MSS option: Kind(1) + Length(1) + MSS(2)
                if (i + 1 >= options_end) return;
                if (i + c.TCPOLEN_MSS > options_end) return;
                if (pkt.data[i + 1] != c.TCPOLEN_MSS) {
                    const skip = pkt.data[i + 1];
                    if (skip < 2) return; // Invalid option length
                    if (i + skip > options_end) return; // Would exceed bounds
                    i += skip;
                    bytes_consumed += skip;
                    continue;
                }
                const mss = (@as(u16, pkt.data[i + 2]) << 8) | pkt.data[i + 3];
                opts.mss_present = true;
                // MSS should be clamped down, not up.
                // tcb.mss = min(peer_mss, our_mtu - headers)
                // Here we just record what the peer sent. The Tcb initiation logic should 
                // perform the min() calculation against local MTU.
                // Ideally we should enforce a sanity Min MSS to avoid silly small packets,
                // but RFC 879 says we shouldn't send larger than peer advertises.
                opts.mss = mss;
                i += c.TCPOLEN_MSS;
                bytes_consumed += c.TCPOLEN_MSS;
            },
            c.TCPOPT_WINDOW => {
                // Window Scale option: Kind(1) + Length(1) + ShiftCount(1)
                if (i + 1 >= options_end) return;
                if (i + c.TCPOLEN_WINDOW > options_end) return;
                if (pkt.data[i + 1] != c.TCPOLEN_WINDOW) {
                    const skip = pkt.data[i + 1];
                    if (skip < 2) return; // Invalid option length
                    if (i + skip > options_end) return; // Would exceed bounds
                    i += skip;
                    bytes_consumed += skip;
                    continue;
                }
                opts.wscale_present = true;
                opts.wscale = @min(pkt.data[i + 2], c.TCP_MAX_WSCALE);
                i += c.TCPOLEN_WINDOW;
                bytes_consumed += c.TCPOLEN_WINDOW;
            },
            c.TCPOPT_SACK_PERM => {
                // SACK Permitted option: Kind(1) + Length(1), no data
                if (i + 1 >= options_end) return;
                if (i + c.TCPOLEN_SACK_PERM > options_end) return;
                if (pkt.data[i + 1] != c.TCPOLEN_SACK_PERM) {
                    const skip = pkt.data[i + 1];
                    if (skip < 2) return; // Invalid option length
                    if (i + skip > options_end) return; // Would exceed bounds
                    i += skip;
                    bytes_consumed += skip;
                    continue;
                }
                opts.sack_permitted = true;
                i += c.TCPOLEN_SACK_PERM;
                bytes_consumed += c.TCPOLEN_SACK_PERM;
            },
            c.TCPOPT_TIMESTAMP => {
                // Timestamp option: Kind(1) + Length(1) + TSval(4) + TSecr(4)
                if (i + 1 >= options_end) return;
                if (i + c.TCPOLEN_TIMESTAMP > options_end) return;
                if (pkt.data[i + 1] != c.TCPOLEN_TIMESTAMP) {
                    const skip = pkt.data[i + 1];
                    if (skip < 2) return; // Invalid option length
                    if (i + skip > options_end) return; // Would exceed bounds
                    i += skip;
                    bytes_consumed += skip;
                    continue;
                }
                opts.timestamp_present = true;
                opts.ts_val = (@as(u32, pkt.data[i + 2]) << 24) |
                    (@as(u32, pkt.data[i + 3]) << 16) |
                    (@as(u32, pkt.data[i + 4]) << 8) |
                    @as(u32, pkt.data[i + 5]);
                opts.ts_ecr = (@as(u32, pkt.data[i + 6]) << 24) |
                    (@as(u32, pkt.data[i + 7]) << 16) |
                    (@as(u32, pkt.data[i + 8]) << 8) |
                    @as(u32, pkt.data[i + 9]);
                i += c.TCPOLEN_TIMESTAMP;
                bytes_consumed += c.TCPOLEN_TIMESTAMP;
            },
            c.TCPOPT_SACK => {
                // SACK blocks - skip for now (full SACK implementation is complex)
                if (i + 1 >= options_end) return;
                const opt_len = pkt.data[i + 1];
                if (opt_len < 2) return;
                if (i + opt_len > options_end) return;
                i += opt_len;
                bytes_consumed += opt_len;
            },
            else => {
                // Unknown option - skip using length field
                if (i + 1 >= options_end) return;
                const opt_len = pkt.data[i + 1];
                if (opt_len < 2) return;
                if (i + opt_len > options_end) return;
                i += opt_len;
                bytes_consumed += opt_len;
            },
        }
    }
}

/// Build TCP options for SYN/SYN-ACK segment
/// Returns the number of bytes written to buf (padded to 4-byte boundary)
pub fn buildSynOptions(buf: []u8, tcb: *Tcb, is_syn_ack: bool, peer_opts: ?*const TcpOptions) usize {
    var offset: usize = 0;

    // MSS option (4 bytes) - always include in SYN/SYN-ACK
    buf[offset] = c.TCPOPT_MSS;
    buf[offset + 1] = c.TCPOLEN_MSS;
    buf[offset + 2] = @intCast((c.DEFAULT_MSS >> 8) & 0xFF);
    buf[offset + 3] = @intCast(c.DEFAULT_MSS & 0xFF);
    offset += 4;

    // Window Scale option (3 bytes)
    // Only include if: (a) SYN from client, or (b) SYN-ACK and peer sent wscale
    const include_wscale = !is_syn_ack or (peer_opts != null and peer_opts.?.wscale_present);
    if (include_wscale) {
        // Calculate our window scale based on receive buffer size
        tcb.rcv_wscale = calculateWindowScale(c.BUFFER_SIZE);
        buf[offset] = c.TCPOPT_WINDOW;
        buf[offset + 1] = c.TCPOLEN_WINDOW;
        buf[offset + 2] = tcb.rcv_wscale;
        offset += 3;

        // If peer sent wscale, record it
        if (peer_opts) |opts| {
            if (opts.wscale_present) {
                tcb.snd_wscale = opts.wscale;
                tcb.wscale_ok = true;
            }
        }
    }

    // SACK Permitted option (2 bytes)
    // Only include if: (a) SYN from client, or (b) SYN-ACK and peer sent sack_permitted
    const include_sack = !is_syn_ack or (peer_opts != null and peer_opts.?.sack_permitted);
    if (include_sack) {
        buf[offset] = c.TCPOPT_SACK_PERM;
        buf[offset + 1] = c.TCPOLEN_SACK_PERM;
        offset += 2;

        if (is_syn_ack and peer_opts != null and peer_opts.?.sack_permitted) {
            tcb.sack_ok = true;
        }
    }

    // Timestamp option (10 bytes)
    // Only include if: (a) SYN from client, or (b) SYN-ACK and peer sent timestamp
    const include_ts = !is_syn_ack or (peer_opts != null and peer_opts.?.timestamp_present);
    if (include_ts) {
        buf[offset] = c.TCPOPT_TIMESTAMP;
        buf[offset + 1] = c.TCPOLEN_TIMESTAMP;
        const ts_val = state.nextTimestamp();
        tcb.ts_val = ts_val;
        buf[offset + 2] = @intCast((ts_val >> 24) & 0xFF);
        buf[offset + 3] = @intCast((ts_val >> 16) & 0xFF);
        buf[offset + 4] = @intCast((ts_val >> 8) & 0xFF);
        buf[offset + 5] = @intCast(ts_val & 0xFF);
        // TSecr = 0 for SYN, echo peer's TSval for SYN-ACK
        const ts_ecr: u32 = if (is_syn_ack and peer_opts != null) peer_opts.?.ts_val else 0;
        buf[offset + 6] = @intCast((ts_ecr >> 24) & 0xFF);
        buf[offset + 7] = @intCast((ts_ecr >> 16) & 0xFF);
        buf[offset + 8] = @intCast((ts_ecr >> 8) & 0xFF);
        buf[offset + 9] = @intCast(ts_ecr & 0xFF);
        offset += 10;

        if (is_syn_ack and peer_opts != null and peer_opts.?.timestamp_present) {
            tcb.ts_ok = true;
            tcb.ts_recent = peer_opts.?.ts_val;
        }
    }

    // Pad to 4-byte boundary with NOPs
    while (offset % 4 != 0) {
        buf[offset] = c.TCPOPT_NOP;
        offset += 1;
    }

    return offset;
}

/// Calculate window scale for our receive buffer (RFC 7323)
/// Returns shift count (0-14) needed to advertise our full buffer size
pub fn calculateWindowScale(buffer_size: usize) u8 {
    // Find smallest scale where (65535 << scale) >= buffer_size
    var scale: u8 = 0;
    var max_window: u32 = 65535;
    while (max_window < buffer_size and scale < c.TCP_MAX_WSCALE) {
        max_window <<= 1;
        scale += 1;
    }
    return scale;
}
