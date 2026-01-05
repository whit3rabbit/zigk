//! DHCPv6 Options Parser/Builder (RFC 8415)
//!
//! Provides TLV (Type-Length-Value) parsing and building for DHCPv6 options.
//! All multi-byte integers are in network byte order (big-endian).

const std = @import("std");
const packet = @import("packet.zig");

// =============================================================================
// Option Codes (RFC 8415 Section 21)
// =============================================================================

pub const OPT_CLIENTID: u16 = 1;
pub const OPT_SERVERID: u16 = 2;
pub const OPT_IA_NA: u16 = 3; // Identity Association for Non-temporary Addresses
pub const OPT_IA_TA: u16 = 4; // Identity Association for Temporary Addresses
pub const OPT_IAADDR: u16 = 5; // IA Address
pub const OPT_ORO: u16 = 6; // Option Request Option
pub const OPT_PREFERENCE: u16 = 7;
pub const OPT_ELAPSED_TIME: u16 = 8;
pub const OPT_STATUS_CODE: u16 = 13;
pub const OPT_RAPID_COMMIT: u16 = 14;
pub const OPT_DNS_SERVERS: u16 = 23;
pub const OPT_DOMAIN_LIST: u16 = 24;

// Status codes (RFC 8415 Section 21.13)
pub const STATUS_SUCCESS: u16 = 0;
pub const STATUS_UNSPEC_FAIL: u16 = 1;
pub const STATUS_NO_ADDRS_AVAIL: u16 = 2;
pub const STATUS_NO_BINDING: u16 = 3;
pub const STATUS_NOT_ON_LINK: u16 = 4;
pub const STATUS_USE_MULTICAST: u16 = 5;

// =============================================================================
// Parsed Option Structures
// =============================================================================

/// IA_NA option (RFC 8415 Section 21.4)
pub const IaNaOption = struct {
    iaid: u32, // Identity Association ID
    t1: u32, // Renewal time (seconds)
    t2: u32, // Rebind time (seconds)
    options_data: []const u8, // Nested options (IA_ADDR, Status Code)
};

/// IA Address option (RFC 8415 Section 21.6)
pub const IaAddrOption = struct {
    addr: [16]u8, // IPv6 address
    preferred_lifetime: u32, // Seconds
    valid_lifetime: u32, // Seconds
    options_data: []const u8, // Nested options (Status Code)
};

/// Status Code option (RFC 8415 Section 21.13)
pub const StatusCodeOption = struct {
    status_code: u16,
    message: []const u8,
};

/// Generic option reference
pub const OptionRef = struct {
    code: u16,
    data: []const u8,
};

// =============================================================================
// Options Iterator
// =============================================================================

/// Iterator over DHCPv6 options in a buffer
pub const OptionsIterator = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) OptionsIterator {
        return .{ .data = data, .pos = 0 };
    }

    /// Get next option, returns null when exhausted
    pub fn next(self: *OptionsIterator) ?OptionRef {
        // Need at least 4 bytes for option header (code + length)
        if (self.pos + 4 > self.data.len) return null;

        const code = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        const length = std.mem.readInt(u16, self.data[self.pos + 2 ..][0..2], .big);

        const data_start = self.pos + 4;
        const data_end = data_start + length;

        // Validate bounds
        if (data_end > self.data.len) return null;

        self.pos = data_end;

        return OptionRef{
            .code = code,
            .data = self.data[data_start..data_end],
        };
    }

    /// Find option by code
    pub fn find(self: *OptionsIterator, target_code: u16) ?OptionRef {
        while (self.next()) |opt| {
            if (opt.code == target_code) return opt;
        }
        return null;
    }

    /// Reset iterator to beginning
    pub fn reset(self: *OptionsIterator) void {
        self.pos = 0;
    }
};

// =============================================================================
// Option Parsers
// =============================================================================

/// Parse IA_NA option data
pub fn parseIaNa(data: []const u8) ?IaNaOption {
    // IA_NA: IAID (4) + T1 (4) + T2 (4) + options
    if (data.len < 12) return null;

    return IaNaOption{
        .iaid = std.mem.readInt(u32, data[0..4], .big),
        .t1 = std.mem.readInt(u32, data[4..8], .big),
        .t2 = std.mem.readInt(u32, data[8..12], .big),
        .options_data = data[12..],
    };
}

/// Parse IA Address option data
pub fn parseIaAddr(data: []const u8) ?IaAddrOption {
    // IA_ADDR: Address (16) + Preferred (4) + Valid (4) + options
    if (data.len < 24) return null;

    return IaAddrOption{
        .addr = data[0..16].*,
        .preferred_lifetime = std.mem.readInt(u32, data[16..20], .big),
        .valid_lifetime = std.mem.readInt(u32, data[20..24], .big),
        .options_data = data[24..],
    };
}

/// Parse Status Code option data
pub fn parseStatusCode(data: []const u8) ?StatusCodeOption {
    if (data.len < 2) return null;

    return StatusCodeOption{
        .status_code = std.mem.readInt(u16, data[0..2], .big),
        .message = data[2..],
    };
}

/// Extract first IA_ADDR from IA_NA options
pub fn extractIaAddrFromIaNa(ia_na: IaNaOption) ?IaAddrOption {
    var iter = OptionsIterator.init(ia_na.options_data);
    while (iter.next()) |opt| {
        if (opt.code == OPT_IAADDR) {
            return parseIaAddr(opt.data);
        }
    }
    return null;
}

/// Check if options contain a status code error
pub fn checkStatusCode(options_data: []const u8) ?StatusCodeOption {
    var iter = OptionsIterator.init(options_data);
    while (iter.next()) |opt| {
        if (opt.code == OPT_STATUS_CODE) {
            if (parseStatusCode(opt.data)) |status| {
                if (status.status_code != STATUS_SUCCESS) {
                    return status;
                }
            }
        }
    }
    return null;
}

// =============================================================================
// Option Builders
// =============================================================================

/// Write option header (code + length), returns bytes written (4)
fn writeOptionHeader(buf: []u8, code: u16, length: u16) usize {
    if (buf.len < 4) return 0;
    std.mem.writeInt(u16, buf[0..2], code, .big);
    std.mem.writeInt(u16, buf[2..4], length, .big);
    return 4;
}

/// Write Client ID option (DUID-LL format)
/// Returns bytes written
pub fn writeClientId(buf: []u8, mac_addr: [6]u8) usize {
    // DUID-LL: Type (2) + Hardware Type (2) + Link-layer address (6) = 10 bytes
    const duid_len: u16 = 10;
    const total_len = 4 + duid_len; // header + data

    if (buf.len < total_len) return 0;

    var pos: usize = 0;
    pos += writeOptionHeader(buf[pos..], OPT_CLIENTID, duid_len);

    // DUID-LL type (3)
    std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(packet.DuidType.Ll), .big);
    pos += 2;

    // Hardware type (1 = Ethernet)
    std.mem.writeInt(u16, buf[pos..][0..2], 1, .big);
    pos += 2;

    // MAC address
    @memcpy(buf[pos..][0..6], &mac_addr);
    pos += 6;

    return pos;
}

/// Write IA_NA option (without nested IA_ADDR - for SOLICIT)
/// Returns bytes written
pub fn writeIaNa(buf: []u8, iaid: u32) usize {
    // IA_NA: IAID (4) + T1 (4) + T2 (4) = 12 bytes (no nested options for SOLICIT)
    const data_len: u16 = 12;
    const total_len = 4 + data_len;

    if (buf.len < total_len) return 0;

    var pos: usize = 0;
    pos += writeOptionHeader(buf[pos..], OPT_IA_NA, data_len);

    // IAID
    std.mem.writeInt(u32, buf[pos..][0..4], iaid, .big);
    pos += 4;

    // T1 = 0 (let server decide)
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;

    // T2 = 0 (let server decide)
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;

    return pos;
}

/// Write IA_NA option with IA_ADDR (for REQUEST after ADVERTISE)
/// Returns bytes written
pub fn writeIaNaWithAddr(buf: []u8, iaid: u32, addr: [16]u8, preferred: u32, valid: u32) usize {
    // IA_NA header (12) + IA_ADDR option (4 + 24)
    const ia_addr_len: u16 = 24; // addr(16) + preferred(4) + valid(4)
    const ia_na_data_len: u16 = 12 + 4 + ia_addr_len;
    const total_len = 4 + ia_na_data_len;

    if (buf.len < total_len) return 0;

    var pos: usize = 0;
    pos += writeOptionHeader(buf[pos..], OPT_IA_NA, ia_na_data_len);

    // IAID
    std.mem.writeInt(u32, buf[pos..][0..4], iaid, .big);
    pos += 4;

    // T1 = 0 (let server decide)
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;

    // T2 = 0 (let server decide)
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;

    // Nested IA_ADDR option
    pos += writeOptionHeader(buf[pos..], OPT_IAADDR, ia_addr_len);
    @memcpy(buf[pos..][0..16], &addr);
    pos += 16;
    std.mem.writeInt(u32, buf[pos..][0..4], preferred, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], valid, .big);
    pos += 4;

    return pos;
}

/// Write Elapsed Time option (centiseconds)
/// Returns bytes written
pub fn writeElapsedTime(buf: []u8, centiseconds: u16) usize {
    const total_len = 4 + 2;
    if (buf.len < total_len) return 0;

    var pos: usize = 0;
    pos += writeOptionHeader(buf[pos..], OPT_ELAPSED_TIME, 2);
    std.mem.writeInt(u16, buf[pos..][0..2], centiseconds, .big);
    pos += 2;

    return pos;
}

/// Write Option Request Option (ORO)
/// requested: array of option codes to request
/// Returns bytes written
pub fn writeOro(buf: []u8, requested: []const u16) usize {
    // SECURITY: Use checked arithmetic to prevent integer overflow
    // If requested.len >= 32768, the multiplication would overflow u16
    const data_len_usize = std.math.mul(usize, requested.len, 2) catch return 0;
    if (data_len_usize > std.math.maxInt(u16)) return 0;
    const data_len: u16 = @intCast(data_len_usize);
    const total_len = 4 + data_len;

    if (buf.len < total_len) return 0;

    var pos: usize = 0;
    pos += writeOptionHeader(buf[pos..], OPT_ORO, data_len);

    for (requested) |code| {
        std.mem.writeInt(u16, buf[pos..][0..2], code, .big);
        pos += 2;
    }

    return pos;
}

/// Write Rapid Commit option (empty, just presence indicates support)
/// Returns bytes written
pub fn writeRapidCommit(buf: []u8) usize {
    if (buf.len < 4) return 0;
    return writeOptionHeader(buf, OPT_RAPID_COMMIT, 0);
}

/// Write Server ID option (copy from received ADVERTISE)
/// Returns bytes written
pub fn writeServerId(buf: []u8, server_duid: []const u8) usize {
    if (server_duid.len > 128) return 0; // Sanity check
    const data_len: u16 = @truncate(server_duid.len);
    const total_len = 4 + data_len;

    if (buf.len < total_len) return 0;

    var pos: usize = 0;
    pos += writeOptionHeader(buf[pos..], OPT_SERVERID, data_len);
    @memcpy(buf[pos..][0..server_duid.len], server_duid);
    pos += server_duid.len;

    return pos;
}

// =============================================================================
// DNS Parsing Helpers
// =============================================================================

/// Extract DNS server addresses from DNS Servers option
/// Returns number of addresses extracted
pub fn extractDnsServers(data: []const u8, out: [][16]u8) usize {
    var count: usize = 0;
    var pos: usize = 0;

    while (pos + 16 <= data.len and count < out.len) {
        @memcpy(&out[count], data[pos..][0..16]);
        count += 1;
        pos += 16;
    }

    return count;
}
