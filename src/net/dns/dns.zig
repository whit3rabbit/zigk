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
pub const TYPE_SRV: u16 = 33; // Service Location (RFC 2782)
pub const TYPE_ANY: u16 = 255; // Any type (query only)

/// EDNS0 (RFC 6891) constants
pub const EDNS0_UDP_SIZE: u16 = 2048; // Advertised UDP payload size
pub const TYPE_OPT: u16 = 41; // OPT pseudo-RR type
pub const OPT_RR_SIZE: usize = 11; // Root name(1) + type(2) + udp_size(2) + ext_rcode(4) + rdlen(2)

/// DNS Classes
pub const CLASS_IN: u16 = 1; // Internet

/// mDNS Constants (RFC 6762)
pub const MDNS_PORT: u16 = 5353;
pub const MDNS_MULTICAST_IPV4: u32 = 0xE00000FB; // 224.0.0.251
pub const MDNS_MULTICAST_IPV6: [16]u8 = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xfb };
pub const MDNS_TTL: u8 = 255; // Required TTL for link-local
pub const MDNS_CACHE_FLUSH_BIT: u16 = 0x8000; // Bit 15 of CLASS field
pub const MDNS_DEFAULT_TTL: u32 = 120; // Default record TTL (2 minutes)
pub const MDNS_HOST_TTL: u32 = 120; // Hostname record TTL
pub const MDNS_SERVICE_TTL: u32 = 4500; // Service record TTL (75 minutes)

/// mDNS response flags (Authoritative response, no recursion)
pub const FLAGS_MDNS_RESPONSE: u16 = FLAGS_QR_RESPONSE | FLAGS_AA;

/// SRV Record Data (RFC 2782)
pub const SrvRecord = struct {
    priority: u16,
    weight: u16,
    port: u16,
    target: []const u8, // DNS-encoded target name
};

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
        var it = std.mem.splitScalar(u8, name, '.');
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

    /// Update the AN (answer record) count in an already-written header.
    pub fn setAnCount(self: *DnsPacket, header_start: usize, count: u16) void {
        const an_offset = header_start + 6;
        if (an_offset + 2 <= self.buffer.len) {
            std.mem.writeInt(u16, self.buffer[an_offset..][0..2], count, .big);
        }
    }

    /// Write an SRV record RDATA section (RFC 2782).
    /// Format: Priority (2) + Weight (2) + Port (2) + Target (variable DNS name)
    /// Note: This writes only the RDATA portion. Caller must write name, type, class, TTL, rdlength first.
    pub fn writeSrvRdata(self: *DnsPacket, priority: u16, weight: u16, port: u16, target: []const u8) !void {
        // Need 6 bytes for fixed fields + variable target name
        if (self.pos + 6 > self.buffer.len) return error.BufferTooSmall;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], priority, .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], weight, .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], port, .big);
        self.pos += 2;

        // Write target as DNS name
        try self.writeName(target);
    }

    /// Write a complete resource record (name, type, class, TTL, rdlength placeholder).
    /// Returns the position of rdlength field for later update.
    pub fn writeResourceRecordHeader(self: *DnsPacket, name: []const u8, rtype: u16, class: u16, ttl: u32) !usize {
        try self.writeName(name);

        if (self.pos + 10 > self.buffer.len) return error.BufferTooSmall;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], rtype, .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], class, .big);
        self.pos += 2;
        std.mem.writeInt(u32, self.buffer[self.pos..][0..4], ttl, .big);
        self.pos += 4;

        // Return position of rdlength for later update
        const rdlen_pos = self.pos;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], 0, .big);
        self.pos += 2;

        return rdlen_pos;
    }

    /// Update rdlength field at a previously saved position.
    pub fn setRdLength(self: *DnsPacket, rdlen_pos: usize, length: u16) void {
        if (rdlen_pos + 2 <= self.buffer.len) {
            std.mem.writeInt(u16, self.buffer[rdlen_pos..][0..2], length, .big);
        }
    }

    /// Write an A record (IPv4 address).
    pub fn writeARecord(self: *DnsPacket, name: []const u8, class: u16, ttl: u32, ip: u32) !void {
        const rdlen_pos = try self.writeResourceRecordHeader(name, TYPE_A, class, ttl);
        const rdata_start = self.pos;

        if (self.pos + 4 > self.buffer.len) return error.BufferTooSmall;
        std.mem.writeInt(u32, self.buffer[self.pos..][0..4], ip, .big);
        self.pos += 4;

        self.setRdLength(rdlen_pos, @intCast(self.pos - rdata_start));
    }

    /// Write a PTR record (pointer to name).
    pub fn writePtrRecord(self: *DnsPacket, name: []const u8, class: u16, ttl: u32, target: []const u8) !void {
        const rdlen_pos = try self.writeResourceRecordHeader(name, TYPE_PTR, class, ttl);
        const rdata_start = self.pos;

        try self.writeName(target);

        self.setRdLength(rdlen_pos, @intCast(self.pos - rdata_start));
    }

    /// Write a TXT record (one or more character strings).
    pub fn writeTxtRecord(self: *DnsPacket, name: []const u8, class: u16, ttl: u32, txt: []const u8) !void {
        const rdlen_pos = try self.writeResourceRecordHeader(name, TYPE_TXT, class, ttl);
        const rdata_start = self.pos;

        // TXT record is one or more length-prefixed strings
        // For simplicity, write as single string (max 255 bytes per string)
        if (txt.len > 255) return error.LabelTooLong;
        if (self.pos + 1 + txt.len > self.buffer.len) return error.BufferTooSmall;

        self.buffer[self.pos] = @intCast(txt.len);
        self.pos += 1;
        @memcpy(self.buffer[self.pos..][0..txt.len], txt);
        self.pos += txt.len;

        self.setRdLength(rdlen_pos, @intCast(self.pos - rdata_start));
    }

    /// Write a complete SRV record.
    pub fn writeSrvRecord(self: *DnsPacket, name: []const u8, class: u16, ttl: u32, priority: u16, weight: u16, port: u16, target: []const u8) !void {
        const rdlen_pos = try self.writeResourceRecordHeader(name, TYPE_SRV, class, ttl);
        const rdata_start = self.pos;

        try self.writeSrvRdata(priority, weight, port, target);

        self.setRdLength(rdlen_pos, @intCast(self.pos - rdata_start));
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

/// Result of reading an SRV record
pub const ReadSrvResult = struct {
    priority: u16,
    weight: u16,
    port: u16,
    target: []const u8,
    end_pos: usize,
};

/// Read SRV record RDATA from buffer.
/// buf is the full packet, start is the offset to the RDATA section, rdlength is the RDATA length.
/// out is a buffer for the target name.
pub fn readSrvRecord(buf: []const u8, start: usize, rdlength: u16, out: []u8) error{ FormatError, BufferTooSmall }!ReadSrvResult {
    // SRV RDATA: priority(2) + weight(2) + port(2) + target(variable)
    if (rdlength < 7) return error.FormatError; // Minimum: 6 bytes fixed + 1 byte null root
    if (start + 6 > buf.len) return error.FormatError;

    const priority = std.mem.readInt(u16, buf[start..][0..2], .big);
    const weight = std.mem.readInt(u16, buf[start + 2 ..][0..2], .big);
    const port = std.mem.readInt(u16, buf[start + 4 ..][0..2], .big);

    // Read target name (may use compression pointers)
    const name_result = try readName(buf, start + 6, out);

    return .{
        .priority = priority,
        .weight = weight,
        .port = port,
        .target = name_result.name,
        .end_pos = start + rdlength,
    };
}

/// Read a resource record header from buffer.
/// Returns the type, class, TTL, rdlength, and position after the header.
pub const ReadRRHeaderResult = struct {
    name: []const u8,
    rtype: u16,
    class: u16,
    ttl: u32,
    rdlength: u16,
    rdata_pos: usize,
};

pub fn readResourceRecordHeader(buf: []const u8, start: usize, name_out: []u8) error{ FormatError, BufferTooSmall }!ReadRRHeaderResult {
    const name_result = try readName(buf, start, name_out);
    const pos = name_result.end_pos;

    if (pos + 10 > buf.len) return error.FormatError;

    const rtype = std.mem.readInt(u16, buf[pos..][0..2], .big);
    const class = std.mem.readInt(u16, buf[pos + 2 ..][0..2], .big);
    const ttl = std.mem.readInt(u32, buf[pos + 4 ..][0..4], .big);
    const rdlength = std.mem.readInt(u16, buf[pos + 8 ..][0..2], .big);

    return .{
        .name = name_result.name,
        .rtype = rtype,
        .class = class & ~MDNS_CACHE_FLUSH_BIT, // Mask out cache-flush bit
        .ttl = ttl,
        .rdlength = rdlength,
        .rdata_pos = pos + 10,
    };
}
