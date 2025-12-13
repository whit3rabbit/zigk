
const std = @import("std");

/// DNS Query Types
pub const TYPE_A: u16 = 1;      // IPv4 Address
pub const TYPE_NS: u16 = 2;     // Name Server
pub const TYPE_CNAME: u16 = 5;  // Canonical Name
pub const TYPE_SOA: u16 = 6;    // Start of Authority
pub const TYPE_PTR: u16 = 12;   // Pointer
pub const TYPE_MX: u16 = 15;    // Mail Exchange
pub const TYPE_TXT: u16 = 16;   // Text
pub const TYPE_AAAA: u16 = 28;  // IPv6 Address

/// DNS Classes
pub const CLASS_IN: u16 = 1;    // Internet

/// DNS Header (12 bytes)
/// All fields are Network Byte Order (Big Endian)
pub const Header = extern struct {
    id: u16,
    flags: u16,
    qd_count: u16, // Question count
    an_count: u16, // Answer count
    ns_count: u16, // Authority count
    ar_count: u16, // Additional count

    pub fn getFlags(self: Header) u16 { return @byteSwap(self.flags); }
    pub fn getQdCount(self: Header) u16 { return @byteSwap(self.qd_count); }
    pub fn getAnCount(self: Header) u16 { return @byteSwap(self.an_count); }

    pub fn setFlags(self: *Header, f: u16) void { self.flags = @byteSwap(f); }
    pub fn setQdCount(self: *Header, c: u16) void { self.qd_count = @byteSwap(c); }

    comptime {
        if (@sizeOf(@This()) != 12) @compileError("DNS Header must be 12 bytes");
    }
};

/// DNS Flags
pub const FLAGS_QR_QUERY: u16    = 0x0000;
pub const FLAGS_QR_RESPONSE: u16 = 0x8000;
pub const FLAGS_OPCODE_STD: u16  = 0x0000;
pub const FLAGS_AA: u16          = 0x0400; // Authoritative Answer
pub const FLAGS_TC: u16          = 0x0200; // Truncated
pub const FLAGS_RD: u16          = 0x0100; // Recursion Desired
pub const FLAGS_RA: u16          = 0x0080; // Recursion Available
pub const FLAGS_RCODE_OK: u16    = 0x0000;
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

    pub fn writeHeader(self: *DnsPacket, id: u16, flags: u16) void {
        const hdr = Header{
            .id = @byteSwap(id),
            .flags = @byteSwap(flags),
            .qd_count = @byteSwap(@as(u16, 1)), // Default 1 question
            .an_count = 0,
            .ns_count = 0,
            .ar_count = 0,
        };
        const invalid: *const [12]u8 = @ptrCast(&hdr);
        @memcpy(self.buffer[self.pos..][0..12], invalid);
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
};
