const std = @import("std");
const packet = @import("../../core/packet.zig");
const PacketBuffer = packet.PacketBuffer;
const types = @import("types.zig");

/// Validate IPv4 options without processing them
pub fn validateOptions(pkt: *const PacketBuffer, header_len: usize) bool {
    if (header_len <= types.IP_HEADER_MIN) {
        return true;
    }

    if (pkt.ip_offset + header_len > pkt.len) {
        return false;
    }

    const options_start = pkt.ip_offset + types.IP_HEADER_MIN;
    const options_end = pkt.ip_offset + header_len;
    var offset = options_start;

    while (offset < options_end) {
        const option_type = pkt.data[offset];

        if (option_type == types.IPOPT_EOL) {
            return true;
        }

        if (option_type == types.IPOPT_NOP) {
            offset += 1;
            continue;
        }

        if (offset + 1 >= options_end) {
            return false;
        }

        const option_len = pkt.data[offset + 1];

        if (option_len < 2) {
            return false;
        }

        if (offset + option_len > options_end) {
            return false;
        }

        switch (option_type) {
            types.IPOPT_LSRR, types.IPOPT_SSRR, types.IPOPT_RR, types.IPOPT_TS => {
                return false;
            },
            else => {},
        }

        offset += option_len;
    }

    return true;
}
