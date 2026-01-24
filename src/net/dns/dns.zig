const std = @import("std");

// RFC 1035 limits
pub const DNS_MAX_LABEL_LENGTH: usize = 63;
pub const DNS_MAX_NAME_LENGTH: usize = 253;
pub const DNS_MAX_UDP_SIZE: usize = 512;
pub const DNS_MAX_COMPRESSION_JUMPS: u8 = 10;
pub const DNS_HEADER_SIZE: usize = 12;
pub const DNS_MAX_CNAME_DEPTH: u8 = 8; // RFC 1034 recommendation for CNAME chain depth

/// DNS Query Types
pub const TYPE_A: u16 = 1; // IPv4 Address
pub const TYPE_NS: u16 = 2; // Name Server
pub const TYPE_CNAME: u16 = 5; // Canonical Name
pub const TYPE_SOA: u16 = 6; // Start of Authority
pub const TYPE_PTR: u16 = 12; // Pointer
pub const TYPE_MX: u16 = 15; // Mail Exchange
pub const TYPE_TXT: u16 = 16; // Text
pub const TYPE_AAAA: u16 = 28; // IPv6 Address

/// EDNS0 (RFC 6891) constants
pub const EDNS0_UDP_SIZE: u16 = 2048; // Advertised UDP payload size
pub const TYPE_OPT: u16 = 41; // OPT pseudo-RR type
pub const OPT_RR_SIZE: usize = 11; // Root name(1) + type(2) + udp_size(2) + ext_rcode(4) + rdlen(2)

/// DNS Classes
pub const CLASS_IN: u16 = 1; // Internet

/// DNS Header (12 bytes)
/// All fields are Network Byte Order (Big Endian)
pub const Header = extern struct {
    id: u16,
    flags: u16,
    qd_count: u16, // Question count
    an_count: u16, // Answer count
    ns_count: u16, // Authority count
    ar_count: u16, // Additional count

    pub fn getFlags(self: Header) u16 {
        return @byteSwap(self.flags);
    }
    pub fn getQdCount(self: Header) u16 {
        return @byteSwap(self.qd_count);
    }
    pub fn getAnCount(self: Header) u16 {
        return @byteSwap(self.an_count);
    }

    pub fn setFlags(self: *Header, f: u16) void {
        self.flags = @byteSwap(f);
    }
    pub fn setQdCount(self: *Header, c: u16) void {
        self.qd_count = @byteSwap(c);
    }

    comptime {
        if (@sizeOf(@This()) != 12) @compileError("DNS Header must be 12 bytes");
    }
};

/// DNS Flags
pub const FLAGS_QR_QUERY: u16 = 0x0000;
pub const FLAGS_QR_RESPONSE: u16 = 0x8000;
pub const FLAGS_OPCODE_STD: u16 = 0x0000;
pub const FLAGS_AA: u16 = 0x0400; // Authoritative Answer
pub const FLAGS_TC: u16 = 0x0200; // Truncated
pub const FLAGS_RD: u16 = 0x0100; // Recursion Desired
pub const FLAGS_RA: u16 = 0x0080; // Recursion Available
pub const FLAGS_RCODE_OK: u16 = 0x0000;
pub const FLAGS_RCODE_NXDOMAIN: u16 = 0x0003;

/// DNS Packet builder/parser helper
pub const DnsPacket = struct {
    buffer: []u8,
    pos: usize,

    pub fn init(buffer: []u8) DnsPacket {
        return .{
            .buffer = buffer,
            .pos = 0,
        };
    }

    /// Write DNS header (12 bytes) to packet buffer.
    /// Returns error.BufferTooSmall if insufficient space remains.
    pub fn writeHeader(self: *DnsPacket, id: u16, flags: u16) error{BufferTooSmall}!void {
        // Security: Bounds check before write (consistent with writeName/writeQuestion)
        if (self.pos + DNS_HEADER_SIZE > self.buffer.len) return error.BufferTooSmall;

        const hdr = Header{
            .id = @byteSwap(id),
            .flags = @byteSwap(flags),
            .qd_count = @byteSwap(@as(u16, 1)), // Default 1 question
            .an_count = 0,
            .ns_count = 0,
            .ar_count = 0,
        };
        const hdr_bytes: *const [12]u8 = @ptrCast(&hdr);
        @memcpy(self.buffer[self.pos..][0..12], hdr_bytes);
        self.pos += 12;
    }

    /// Write hostname in DNS format (length-prefixed labels)
    /// e.g. "google.com" -> \x06google\x03com\x00
    pub fn writeName(self: *DnsPacket, name: []const u8) !void {
        var it = std.mem.split(u8, name, ".");
        while (it.next()) |label| {
            if (label.len > 63) return error.LabelTooLong;
            if (self.pos + 1 + label.len > self.buffer.len) return error.BufferTooSmall;

            self.buffer[self.pos] = @intCast(label.len);
            self.pos += 1;
            @memcpy(self.buffer[self.pos..][0..label.len], label);
            self.pos += label.len;
        }
        if (self.pos >= self.buffer.len) return error.BufferTooSmall;
        self.buffer[self.pos] = 0; // Root label
        self.pos += 1;
    }

    pub fn writeQuestion(self: *DnsPacket, qtype: u16, qclass: u16) !void {
        if (self.pos + 4 > self.buffer.len) return error.BufferTooSmall;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], qtype, .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], qclass, .big);
        self.pos += 2;
    }

    /// Write an EDNS0 OPT pseudo-RR (RFC 6891) to the additional section.
    /// This advertises the client's UDP payload size to allow responses > 512 bytes.
    /// Format: root name (0x00) + TYPE_OPT + UDP size (as CLASS) + ext RCODE/version/flags + RDLENGTH
    pub fn writeOptRR(self: *DnsPacket, udp_size: u16) !void {
        if (self.pos + OPT_RR_SIZE > self.buffer.len) return error.BufferTooSmall;

        // Root name (empty label)
        self.buffer[self.pos] = 0x00;
        self.pos += 1;

        // TYPE = OPT (41)
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], TYPE_OPT, .big);
        self.pos += 2;

        // CLASS = UDP payload size
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], udp_size, .big);
        self.pos += 2;

        // Extended RCODE (1 byte) + Version (1 byte) + DO + Z (2 bytes) = 4 bytes, all zero
        self.buffer[self.pos] = 0;
        self.buffer[self.pos + 1] = 0;
        self.buffer[self.pos + 2] = 0;
        self.buffer[self.pos + 3] = 0;
        self.pos += 4;

        // RDLENGTH = 0 (no OPT options)
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], 0, .big);
        self.pos += 2;
    }

    /// Update the AR (additional record) count in an already-written header.
    /// header_start is the offset where the header begins in the buffer.
    pub fn setArCount(self: *DnsPacket, header_start: usize, count: u16) void {
        // ar_count is at offset 10-11 within the DNS header
        const ar_offset = header_start + 10;
        if (ar_offset + 2 <= self.buffer.len) {
            std.mem.writeInt(u16, self.buffer[ar_offset..][0..2], count, .big);
        }
    }
};

/// Result of reading a DNS name from a packet
pub const ReadNameResult = struct {
    name: []const u8,
    end_pos: usize,
};

/// Read a DNS name from buffer, handling compression pointers (RFC 1035 section 4.1.4).
/// Returns the extracted name as a slice into the output buffer, plus position after the name.
/// Uses provided buffer for output to avoid allocation in hot path.
pub fn readName(buf: []const u8, start: usize, out: []u8) error{ FormatError, BufferTooSmall }!ReadNameResult {
    var pos = start;
    var out_pos: usize = 0;
    var jumps: u8 = 0;
    var end_pos: ?usize = null; // Position after name in original buffer
    var total_name_len: usize = 0; // RFC 1035: track total name length (max 253)

    while (true) {
        if (pos >= buf.len) return error.FormatError;
        const len_byte = buf[pos];

        if (len_byte == 0) {
            if (end_pos == null) end_pos = pos + 1;
            break;
        }

        // RFC 1035 section 4.1.4: Two high-order bits determine label type
        // 00 = label (length in remaining 6 bits)
        // 11 = compression pointer
        // 01, 10 = reserved for future use - reject these
        if ((len_byte & 0xC0) == 0xC0) {
            // Compression pointer (11xxxxxx)
            jumps += 1;
            if (jumps > DNS_MAX_COMPRESSION_JUMPS) return error.FormatError;
            if (pos + 1 >= buf.len) return error.FormatError;

            if (end_pos == null) end_pos = pos + 2; // Save original end position before jump

            const offset: usize = (@as(u16, len_byte & 0x3F) << 8) | buf[pos + 1];
            if (offset >= buf.len) return error.FormatError;
            // RFC 1035 compression pointers must point backward to previously seen data.
            // Forward pointers could allow reading arbitrary buffer locations in crafted responses.
            if (offset >= pos) return error.FormatError;
            pos = offset;
            continue;
        }

        // Security: Reject reserved label types (01xxxxxx and 10xxxxxx)
        // These could be interpreted as label lengths 64-191, causing OOB reads
        if ((len_byte & 0xC0) != 0) {
            return error.FormatError;
        }

        // Regular label (00xxxxxx) - length is 0-63
        const label_len: usize = len_byte;
        if (pos + 1 + label_len > buf.len) return error.FormatError;

        // RFC 1035: Enforce total name length limit (253 bytes)
        // Each label contributes: label_len + 1 (for dot or null terminator)
        // Security: Use checked arithmetic per CLAUDE.md guidelines (defense in depth)
        const label_contribution = std.math.add(usize, label_len, 1) catch return error.FormatError;
        total_name_len = std.math.add(usize, total_name_len, label_contribution) catch return error.FormatError;
        if (total_name_len > DNS_MAX_NAME_LENGTH) return error.FormatError;

        // Add dot separator (except for first label)
        if (out_pos > 0) {
            if (out_pos >= out.len) return error.BufferTooSmall;
            out[out_pos] = '.';
            out_pos += 1;
        }

        // Copy label
        if (out_pos + label_len > out.len) return error.BufferTooSmall;
        @memcpy(out[out_pos..][0..label_len], buf[pos + 1 ..][0..label_len]);
        out_pos += label_len;
        pos += 1 + label_len;
    }

    return .{ .name = out[0..out_pos], .end_pos = end_pos.? };
}
