// 9P2000.u Protocol Implementation
//
// Message structures and serialization for the 9P2000.u protocol.
// All structures are designed for direct wire format serialization.
//
// Reference: http://man.cat-v.org/plan_9/5/intro
// Reference: https://github.com/chaos/diod/blob/master/protocol.md (9P2000.u extensions)

const std = @import("std");
const config = @import("config.zig");

// ============================================================================
// Message Types
// ============================================================================

/// 9P message types (T = request from client, R = response from server)
pub const MsgType = enum(u8) {
    // Base 9P2000 messages
    Tversion = 100,
    Rversion = 101,
    Tauth = 102,
    Rauth = 103,
    Tattach = 104,
    Rattach = 105,
    Terror = 106, // Not used (no client-side error)
    Rerror = 107,
    Tflush = 108,
    Rflush = 109,
    Twalk = 110,
    Rwalk = 111,
    Topen = 112,
    Ropen = 113,
    Tcreate = 114,
    Rcreate = 115,
    Tread = 116,
    Rread = 117,
    Twrite = 118,
    Rwrite = 119,
    Tclunk = 120,
    Rclunk = 121,
    Tremove = 122,
    Rremove = 123,
    Tstat = 124,
    Rstat = 125,
    Twstat = 126,
    Rwstat = 127,

    _,

    pub fn isRequest(self: MsgType) bool {
        const val = @intFromEnum(self);
        return val >= 100 and val <= 127 and (val % 2 == 0);
    }

    pub fn isResponse(self: MsgType) bool {
        const val = @intFromEnum(self);
        return val >= 101 and val <= 127 and (val % 2 == 1);
    }

    pub fn responseType(self: MsgType) MsgType {
        const val = @intFromEnum(self);
        if (self.isRequest()) {
            return @enumFromInt(val + 1);
        }
        return self;
    }
};

// ============================================================================
// Wire Format Header
// ============================================================================

/// 9P message header (7 bytes)
/// All messages start with: size[4] type[1] tag[2]
pub const P9Header = extern struct {
    /// Total message size including this header
    size: u32 align(1),
    /// Message type (MsgType)
    msg_type: u8 align(1),
    /// Message tag for request/response correlation
    tag: u16 align(1),

    pub const SIZE: usize = 7;
};

comptime {
    if (@sizeOf(P9Header) != 7) {
        @compileError("P9Header size mismatch");
    }
}

// ============================================================================
// Qid (Unique File Identifier)
// ============================================================================

/// 9P Qid - 13 bytes identifying a file
/// type[1] version[4] path[8]
pub const P9Qid = extern struct {
    /// File type (QidType flags)
    qid_type: u8 align(1),
    /// Version number (changes on file modification)
    version: u32 align(1),
    /// Unique path identifier (like inode number)
    path: u64 align(1),

    pub const SIZE: usize = 13;

    pub fn isDir(self: P9Qid) bool {
        return (self.qid_type & config.QidType.DIR) != 0;
    }

    pub fn isSymlink(self: P9Qid) bool {
        return (self.qid_type & config.QidType.SYMLINK) != 0;
    }
};

comptime {
    if (@sizeOf(P9Qid) != 13) {
        @compileError("P9Qid size mismatch");
    }
}

// ============================================================================
// Stat Structure (Variable Length)
// ============================================================================

/// Fixed portion of 9P stat structure
/// The full stat has variable-length strings following this
pub const P9StatFixed = extern struct {
    /// Total size of stat (excluding this 2-byte field)
    size: u16 align(1),
    /// Kernel type (server-dependent)
    kern_type: u16 align(1),
    /// Kernel device (server-dependent)
    dev: u32 align(1),
    /// Unique file identifier
    qid: P9Qid align(1),
    /// Permissions and mode bits
    mode: u32 align(1),
    /// Last access time (Unix timestamp)
    atime: u32 align(1),
    /// Last modification time (Unix timestamp)
    mtime: u32 align(1),
    /// File length
    length: u64 align(1),

    pub const SIZE: usize = 41;
};

comptime {
    if (@sizeOf(P9StatFixed) != 41) {
        @compileError("P9StatFixed size mismatch");
    }
}

/// Parsed stat structure with string data
pub const P9Stat = struct {
    fixed: P9StatFixed,
    /// File name
    name: []const u8,
    /// Owner name
    uid: []const u8,
    /// Group name
    gid: []const u8,
    /// Last modifier name
    muid: []const u8,
    // 9P2000.u extensions
    /// Extension string (symlink target, device info)
    extension: []const u8,
    /// Numeric UID
    n_uid: u32,
    /// Numeric GID
    n_gid: u32,
    /// Numeric MUID
    n_muid: u32,
};

// ============================================================================
// Message Serialization Buffer
// ============================================================================

/// Buffer for building/parsing 9P messages
pub const P9Buffer = struct {
    data: []u8,
    pos: usize,
    capacity: usize,

    const Self = @This();

    /// Initialize a buffer with backing storage
    pub fn init(backing: []u8) Self {
        return .{
            .data = backing,
            .pos = 0,
            .capacity = backing.len,
        };
    }

    /// Reset buffer position for reuse
    pub fn reset(self: *Self) void {
        self.pos = 0;
    }

    /// Get current message data
    pub fn getMessage(self: *const Self) []const u8 {
        return self.data[0..self.pos];
    }

    /// Get remaining capacity
    pub fn remaining(self: *const Self) usize {
        return self.capacity - self.pos;
    }

    // ========================================================================
    // Write Operations (for building requests)
    // ========================================================================

    /// Write a u8
    pub fn writeU8(self: *Self, val: u8) !void {
        if (self.remaining() < 1) return error.BufferFull;
        self.data[self.pos] = val;
        self.pos += 1;
    }

    /// Write a u16 (little-endian)
    pub fn writeU16(self: *Self, val: u16) !void {
        if (self.remaining() < 2) return error.BufferFull;
        std.mem.writeInt(u16, self.data[self.pos..][0..2], val, .little);
        self.pos += 2;
    }

    /// Write a u32 (little-endian)
    pub fn writeU32(self: *Self, val: u32) !void {
        if (self.remaining() < 4) return error.BufferFull;
        std.mem.writeInt(u32, self.data[self.pos..][0..4], val, .little);
        self.pos += 4;
    }

    /// Write a u64 (little-endian)
    pub fn writeU64(self: *Self, val: u64) !void {
        if (self.remaining() < 8) return error.BufferFull;
        std.mem.writeInt(u64, self.data[self.pos..][0..8], val, .little);
        self.pos += 8;
    }

    /// Write a length-prefixed string (2-byte length + data)
    pub fn writeString(self: *Self, str: []const u8) !void {
        const len = std.math.cast(u16, str.len) orelse return error.StringTooLong;
        try self.writeU16(len);
        if (self.remaining() < str.len) return error.BufferFull;
        @memcpy(self.data[self.pos..][0..str.len], str);
        self.pos += str.len;
    }

    /// Write raw bytes
    pub fn writeBytes(self: *Self, bytes: []const u8) !void {
        if (self.remaining() < bytes.len) return error.BufferFull;
        @memcpy(self.data[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    /// Write a Qid
    pub fn writeQid(self: *Self, qid: P9Qid) !void {
        try self.writeU8(qid.qid_type);
        try self.writeU32(qid.version);
        try self.writeU64(qid.path);
    }

    /// Write message header (updates size field at end)
    pub fn writeHeader(self: *Self, msg_type: MsgType, tag: u16) !void {
        // Reserve space for size (will be filled in later)
        try self.writeU32(0);
        try self.writeU8(@intFromEnum(msg_type));
        try self.writeU16(tag);
    }

    /// Finalize message by writing the size
    pub fn finalize(self: *Self) void {
        const size = @as(u32, @intCast(self.pos));
        std.mem.writeInt(u32, self.data[0..4], size, .little);
    }

    // ========================================================================
    // Read Operations (for parsing responses)
    // ========================================================================

    /// Read a u8
    pub fn readU8(self: *Self) !u8 {
        if (self.remaining() < 1) return error.BufferUnderflow;
        const val = self.data[self.pos];
        self.pos += 1;
        return val;
    }

    /// Read a u16 (little-endian)
    pub fn readU16(self: *Self) !u16 {
        if (self.remaining() < 2) return error.BufferUnderflow;
        const val = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return val;
    }

    /// Read a u32 (little-endian)
    pub fn readU32(self: *Self) !u32 {
        if (self.remaining() < 4) return error.BufferUnderflow;
        const val = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    /// Read a u64 (little-endian)
    pub fn readU64(self: *Self) !u64 {
        if (self.remaining() < 8) return error.BufferUnderflow;
        const val = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    /// Read a length-prefixed string
    /// Returns a slice into the buffer (valid until buffer is reused)
    pub fn readString(self: *Self) ![]const u8 {
        const len = try self.readU16();
        if (self.remaining() < len) return error.BufferUnderflow;
        const str = self.data[self.pos..][0..len];
        self.pos += len;
        return str;
    }

    /// Read raw bytes
    pub fn readBytes(self: *Self, count: usize) ![]const u8 {
        if (self.remaining() < count) return error.BufferUnderflow;
        const bytes = self.data[self.pos..][0..count];
        self.pos += count;
        return bytes;
    }

    /// Read a Qid
    pub fn readQid(self: *Self) !P9Qid {
        return P9Qid{
            .qid_type = try self.readU8(),
            .version = try self.readU32(),
            .path = try self.readU64(),
        };
    }

    /// Read message header
    pub fn readHeader(self: *Self) !P9Header {
        return P9Header{
            .size = try self.readU32(),
            .msg_type = try self.readU8(),
            .tag = try self.readU16(),
        };
    }

    /// Skip bytes
    pub fn skip(self: *Self, count: usize) !void {
        if (self.remaining() < count) return error.BufferUnderflow;
        self.pos += count;
    }

    pub const Error = error{
        BufferFull,
        BufferUnderflow,
        StringTooLong,
    };
};

// ============================================================================
// Message Builders
// ============================================================================

/// Build a Tversion message
pub fn buildTversion(buf: *P9Buffer, tag: u16, msize: u32, version: []const u8) !void {
    buf.reset();
    try buf.writeHeader(.Tversion, tag);
    try buf.writeU32(msize);
    try buf.writeString(version);
    buf.finalize();
}

/// Build a Tattach message
pub fn buildTattach(buf: *P9Buffer, tag: u16, fid: u32, afid: u32, uname: []const u8, aname: []const u8, n_uname: u32) !void {
    buf.reset();
    try buf.writeHeader(.Tattach, tag);
    try buf.writeU32(fid);
    try buf.writeU32(afid);
    try buf.writeString(uname);
    try buf.writeString(aname);
    try buf.writeU32(n_uname); // 9P2000.u extension
    buf.finalize();
}

/// Build a Twalk message
pub fn buildTwalk(buf: *P9Buffer, tag: u16, fid: u32, newfid: u32, names: []const []const u8) !void {
    if (names.len > config.Limits.MAX_WALK_ELEMS) return error.TooManyWalkElements;

    buf.reset();
    try buf.writeHeader(.Twalk, tag);
    try buf.writeU32(fid);
    try buf.writeU32(newfid);
    try buf.writeU16(@intCast(names.len));
    for (names) |name| {
        try buf.writeString(name);
    }
    buf.finalize();
}

/// Build a Topen message
pub fn buildTopen(buf: *P9Buffer, tag: u16, fid: u32, mode: u8) !void {
    buf.reset();
    try buf.writeHeader(.Topen, tag);
    try buf.writeU32(fid);
    try buf.writeU8(mode);
    buf.finalize();
}

/// Build a Tread message
pub fn buildTread(buf: *P9Buffer, tag: u16, fid: u32, offset: u64, count: u32) !void {
    buf.reset();
    try buf.writeHeader(.Tread, tag);
    try buf.writeU32(fid);
    try buf.writeU64(offset);
    try buf.writeU32(count);
    buf.finalize();
}

/// Build a Twrite message
pub fn buildTwrite(buf: *P9Buffer, tag: u16, fid: u32, offset: u64, data: []const u8) !void {
    const count = std.math.cast(u32, data.len) orelse return error.DataTooLarge;
    buf.reset();
    try buf.writeHeader(.Twrite, tag);
    try buf.writeU32(fid);
    try buf.writeU64(offset);
    try buf.writeU32(count);
    try buf.writeBytes(data);
    buf.finalize();
}

/// Build a Tclunk message
pub fn buildTclunk(buf: *P9Buffer, tag: u16, fid: u32) !void {
    buf.reset();
    try buf.writeHeader(.Tclunk, tag);
    try buf.writeU32(fid);
    buf.finalize();
}

/// Build a Tremove message
pub fn buildTremove(buf: *P9Buffer, tag: u16, fid: u32) !void {
    buf.reset();
    try buf.writeHeader(.Tremove, tag);
    try buf.writeU32(fid);
    buf.finalize();
}

/// Build a Tstat message
pub fn buildTstat(buf: *P9Buffer, tag: u16, fid: u32) !void {
    buf.reset();
    try buf.writeHeader(.Tstat, tag);
    try buf.writeU32(fid);
    buf.finalize();
}

/// Build a Tcreate message
pub fn buildTcreate(buf: *P9Buffer, tag: u16, fid: u32, name: []const u8, perm: u32, mode: u8, extension: []const u8) !void {
    buf.reset();
    try buf.writeHeader(.Tcreate, tag);
    try buf.writeU32(fid);
    try buf.writeString(name);
    try buf.writeU32(perm);
    try buf.writeU8(mode);
    try buf.writeString(extension); // 9P2000.u extension
    buf.finalize();
}

/// Build a Tflush message
pub fn buildTflush(buf: *P9Buffer, tag: u16, oldtag: u16) !void {
    buf.reset();
    try buf.writeHeader(.Tflush, tag);
    try buf.writeU16(oldtag);
    buf.finalize();
}

// ============================================================================
// Response Parsers
// ============================================================================

/// Parse Rversion response
pub fn parseRversion(buf: *P9Buffer) !struct { msize: u32, version: []const u8 } {
    const msize = try buf.readU32();
    const version = try buf.readString();
    return .{ .msize = msize, .version = version };
}

/// Parse Rattach response
pub fn parseRattach(buf: *P9Buffer) !P9Qid {
    return try buf.readQid();
}

/// Parse Rwalk response
pub fn parseRwalk(buf: *P9Buffer, qids: []P9Qid) !usize {
    const nwqid = try buf.readU16();
    if (nwqid > qids.len) return error.TooManyQids;
    for (0..nwqid) |i| {
        qids[i] = try buf.readQid();
    }
    return nwqid;
}

/// Parse Ropen response
pub fn parseRopen(buf: *P9Buffer) !struct { qid: P9Qid, iounit: u32 } {
    const qid = try buf.readQid();
    const iounit = try buf.readU32();
    return .{ .qid = qid, .iounit = iounit };
}

/// Parse Rread response
pub fn parseRread(buf: *P9Buffer) ![]const u8 {
    const count = try buf.readU32();
    return try buf.readBytes(count);
}

/// Parse Rwrite response
pub fn parseRwrite(buf: *P9Buffer) !u32 {
    return try buf.readU32();
}

/// Parse Rerror response
pub fn parseRerror(buf: *P9Buffer) !struct { ename: []const u8, errno: u32 } {
    const ename = try buf.readString();
    const errno = try buf.readU32(); // 9P2000.u extension
    return .{ .ename = ename, .errno = errno };
}

/// Parse Rstat response (returns stat data for further parsing)
pub fn parseRstat(buf: *P9Buffer) ![]const u8 {
    const stat_len = try buf.readU16();
    return try buf.readBytes(stat_len);
}

/// Parse Rcreate response
pub fn parseRcreate(buf: *P9Buffer) !struct { qid: P9Qid, iounit: u32 } {
    const qid = try buf.readQid();
    const iounit = try buf.readU32();
    return .{ .qid = qid, .iounit = iounit };
}

// Rclunk, Rremove, Rflush have no body - just header

// ============================================================================
// Stat Parsing
// ============================================================================

/// Parse a 9P2000.u stat structure from raw bytes
pub fn parseStat(data: []const u8) !P9Stat {
    if (data.len < P9StatFixed.SIZE) return error.StatTooShort;

    var buf = P9Buffer.init(@constCast(data));

    // Read fixed portion
    const size = try buf.readU16();
    _ = size; // Size field validated by caller

    var stat: P9Stat = undefined;
    stat.fixed.size = 0; // Will be set properly
    stat.fixed.kern_type = try buf.readU16();
    stat.fixed.dev = try buf.readU32();
    stat.fixed.qid = try buf.readQid();
    stat.fixed.mode = try buf.readU32();
    stat.fixed.atime = try buf.readU32();
    stat.fixed.mtime = try buf.readU32();
    stat.fixed.length = try buf.readU64();

    // Read variable-length strings
    stat.name = try buf.readString();
    stat.uid = try buf.readString();
    stat.gid = try buf.readString();
    stat.muid = try buf.readString();

    // 9P2000.u extensions
    stat.extension = try buf.readString();
    stat.n_uid = try buf.readU32();
    stat.n_gid = try buf.readU32();
    stat.n_muid = try buf.readU32();

    return stat;
}

// ============================================================================
// Additional Errors
// ============================================================================

pub const ProtocolError = error{
    BufferFull,
    BufferUnderflow,
    StringTooLong,
    TooManyWalkElements,
    TooManyQids,
    DataTooLarge,
    StatTooShort,
    InvalidMessageType,
    TagMismatch,
    UnexpectedResponse,
};

// ============================================================================
// Tests
// ============================================================================

test "P9Buffer write/read" {
    const testing = std.testing;
    var backing: [256]u8 = undefined;
    var buf = P9Buffer.init(&backing);

    try buf.writeU8(0x42);
    try buf.writeU16(0x1234);
    try buf.writeU32(0xDEADBEEF);
    try buf.writeString("hello");

    buf.pos = 0; // Reset for reading

    try testing.expectEqual(@as(u8, 0x42), try buf.readU8());
    try testing.expectEqual(@as(u16, 0x1234), try buf.readU16());
    try testing.expectEqual(@as(u32, 0xDEADBEEF), try buf.readU32());
    try testing.expectEqualStrings("hello", try buf.readString());
}

test "build Tversion" {
    var backing: [256]u8 = undefined;
    var buf = P9Buffer.init(&backing);

    try buildTversion(&buf, 0xFFFF, 8192, config.P9_PROTO_2000U);

    const msg = buf.getMessage();
    // Header: size[4] + type[1] + tag[2] = 7
    // Body: msize[4] + version_len[2] + version[8] = 14
    // Total = 21
    try std.testing.expectEqual(@as(usize, 21), msg.len);
}
