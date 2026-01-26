// FUSE Protocol Implementation
//
// Message structures and serialization for the FUSE protocol over VirtIO.
// All structures are designed for direct wire format serialization.
//
// Reference: https://www.kernel.org/doc/html/latest/filesystems/fuse.html
// Reference: include/uapi/linux/fuse.h

const std = @import("std");
const config = @import("config.zig");

// ============================================================================
// FUSE Message Headers
// ============================================================================

/// FUSE input (request) header - sent to daemon
/// Size: 40 bytes
pub const FuseInHeader = extern struct {
    /// Total message length including this header
    len: u32 align(1),
    /// Operation code (FuseOpcode)
    opcode: u32 align(1),
    /// Unique request ID for correlation
    unique: u64 align(1),
    /// Node ID (inode)
    nodeid: u64 align(1),
    /// User ID of requesting process
    uid: u32 align(1),
    /// Group ID of requesting process
    gid: u32 align(1),
    /// Process ID of requesting process
    pid: u32 align(1),
    /// Padding for alignment
    padding: u32 align(1),

    pub const SIZE: usize = 40;
};

comptime {
    if (@sizeOf(FuseInHeader) != 40) {
        @compileError("FuseInHeader size mismatch");
    }
}

/// FUSE output (response) header - sent from daemon
/// Size: 16 bytes
pub const FuseOutHeader = extern struct {
    /// Total message length including this header
    len: u32 align(1),
    /// Error code (negative errno, or 0 for success)
    @"error": i32 align(1),
    /// Unique request ID (must match request)
    unique: u64 align(1),

    pub const SIZE: usize = 16;
};

comptime {
    if (@sizeOf(FuseOutHeader) != 16) {
        @compileError("FuseOutHeader size mismatch");
    }
}

// ============================================================================
// FUSE Attribute Structure
// ============================================================================

/// FUSE file attributes
/// Size: 88 bytes
pub const FuseAttr = extern struct {
    /// Inode number
    ino: u64 align(1),
    /// File size in bytes
    size: u64 align(1),
    /// Number of 512-byte blocks allocated
    blocks: u64 align(1),
    /// Time of last access (seconds)
    atime: u64 align(1),
    /// Time of last modification (seconds)
    mtime: u64 align(1),
    /// Time of last status change (seconds)
    ctime: u64 align(1),
    /// Access time (nanoseconds)
    atimensec: u32 align(1),
    /// Modification time (nanoseconds)
    mtimensec: u32 align(1),
    /// Status change time (nanoseconds)
    ctimensec: u32 align(1),
    /// File mode (permissions + type)
    mode: u32 align(1),
    /// Number of hard links
    nlink: u32 align(1),
    /// Owner user ID
    uid: u32 align(1),
    /// Owner group ID
    gid: u32 align(1),
    /// Device ID (if special file)
    rdev: u32 align(1),
    /// Block size for filesystem I/O
    blksize: u32 align(1),
    /// Padding
    padding: u32 align(1),

    pub const SIZE: usize = 88;

    pub fn isDir(self: *const FuseAttr) bool {
        return config.FileType.isDir(self.mode);
    }

    pub fn isRegular(self: *const FuseAttr) bool {
        return config.FileType.isRegular(self.mode);
    }

    pub fn isSymlink(self: *const FuseAttr) bool {
        return config.FileType.isSymlink(self.mode);
    }
};

comptime {
    if (@sizeOf(FuseAttr) != 88) {
        @compileError("FuseAttr size mismatch");
    }
}

// ============================================================================
// FUSE Entry Out (LOOKUP response)
// ============================================================================

/// Response for LOOKUP, MKNOD, MKDIR, SYMLINK, LINK, CREATE
/// Size: 128 bytes (with attr alignment)
pub const FuseEntryOut = extern struct {
    /// Inode ID
    nodeid: u64 align(1),
    /// Inode generation number
    generation: u64 align(1),
    /// Entry cache timeout (seconds)
    entry_valid: u64 align(1),
    /// Attribute cache timeout (seconds)
    attr_valid: u64 align(1),
    /// Entry cache timeout (nanoseconds fraction)
    entry_valid_nsec: u32 align(1),
    /// Attribute cache timeout (nanoseconds fraction)
    attr_valid_nsec: u32 align(1),
    /// File attributes
    attr: FuseAttr align(1),

    pub const SIZE: usize = 40 + FuseAttr.SIZE; // 128
};

comptime {
    if (@sizeOf(FuseEntryOut) != 128) {
        @compileError("FuseEntryOut size mismatch");
    }
}

// ============================================================================
// FUSE INIT Structures
// ============================================================================

/// FUSE_INIT request body
pub const FuseInitIn = extern struct {
    /// Protocol major version
    major: u32 align(1),
    /// Protocol minor version
    minor: u32 align(1),
    /// Maximum readahead size
    max_readahead: u32 align(1),
    /// Capability flags
    flags: u32 align(1),

    pub const SIZE: usize = 16;
};

/// FUSE_INIT response body
pub const FuseInitOut = extern struct {
    /// Protocol major version
    major: u32 align(1),
    /// Protocol minor version
    minor: u32 align(1),
    /// Maximum readahead size
    max_readahead: u32 align(1),
    /// Accepted capability flags
    flags: u32 align(1),
    /// Maximum background requests
    max_background: u16 align(1),
    /// Congestion threshold
    congestion_threshold: u16 align(1),
    /// Maximum write buffer size
    max_write: u32 align(1),
    /// Time granularity (nanoseconds)
    time_gran: u32 align(1),
    /// Maximum pages per request (if MAX_PAGES flag)
    max_pages: u16 align(1),
    /// Map alignment (if MAP_ALIGNMENT flag)
    map_alignment: u16 align(1),
    /// Reserved padding
    unused: [8]u32 align(1),

    pub const SIZE: usize = 64;
};

comptime {
    if (@sizeOf(FuseInitIn) != 16) {
        @compileError("FuseInitIn size mismatch");
    }
    if (@sizeOf(FuseInitOut) != 64) {
        @compileError("FuseInitOut size mismatch");
    }
}

// ============================================================================
// FUSE GETATTR / SETATTR Structures
// ============================================================================

/// FUSE_GETATTR request body
pub const FuseGetAttrIn = extern struct {
    /// GETATTR flags
    getattr_flags: u32 align(1),
    /// Padding
    dummy: u32 align(1),
    /// File handle (if FUSE_GETATTR_FH flag)
    fh: u64 align(1),

    pub const SIZE: usize = 16;
};

/// FUSE_GETATTR response body
pub const FuseAttrOut = extern struct {
    /// Attribute cache timeout (seconds)
    attr_valid: u64 align(1),
    /// Attribute cache timeout (nanoseconds)
    attr_valid_nsec: u32 align(1),
    /// Padding
    dummy: u32 align(1),
    /// File attributes
    attr: FuseAttr align(1),

    pub const SIZE: usize = 16 + FuseAttr.SIZE; // 104
};

/// FUSE_SETATTR request body
pub const FuseSetAttrIn = extern struct {
    /// Valid attribute mask (FuseSetAttrFlags)
    valid: u32 align(1),
    /// Padding
    padding: u32 align(1),
    /// File handle
    fh: u64 align(1),
    /// New size
    size: u64 align(1),
    /// Lock owner
    lock_owner: u64 align(1),
    /// Access time (seconds)
    atime: u64 align(1),
    /// Modification time (seconds)
    mtime: u64 align(1),
    /// Status change time (seconds)
    ctime: u64 align(1),
    /// Access time (nanoseconds)
    atimensec: u32 align(1),
    /// Modification time (nanoseconds)
    mtimensec: u32 align(1),
    /// Status change time (nanoseconds)
    ctimensec: u32 align(1),
    /// New mode
    mode: u32 align(1),
    /// Unused
    unused4: u32 align(1),
    /// New UID
    uid: u32 align(1),
    /// New GID
    gid: u32 align(1),
    /// Unused
    unused5: u32 align(1),

    pub const SIZE: usize = 88;
};

comptime {
    if (@sizeOf(FuseGetAttrIn) != 16) {
        @compileError("FuseGetAttrIn size mismatch");
    }
    if (@sizeOf(FuseAttrOut) != 104) {
        @compileError("FuseAttrOut size mismatch");
    }
    if (@sizeOf(FuseSetAttrIn) != 88) {
        @compileError("FuseSetAttrIn size mismatch");
    }
}

// ============================================================================
// FUSE OPEN / CREATE Structures
// ============================================================================

/// FUSE_OPEN request body
pub const FuseOpenIn = extern struct {
    /// Open flags (O_RDONLY, O_WRONLY, etc.)
    flags: u32 align(1),
    /// Unused
    unused: u32 align(1),

    pub const SIZE: usize = 8;
};

/// FUSE_OPEN response body
pub const FuseOpenOut = extern struct {
    /// File handle (opaque to kernel)
    fh: u64 align(1),
    /// Open flags (FUSE_DIRECT_IO, etc.)
    open_flags: u32 align(1),
    /// Padding
    padding: u32 align(1),

    pub const SIZE: usize = 16;
};

/// FUSE_CREATE request body
pub const FuseCreateIn = extern struct {
    /// Open flags
    flags: u32 align(1),
    /// File mode (permissions)
    mode: u32 align(1),
    /// Umask
    umask: u32 align(1),
    /// Padding
    padding: u32 align(1),
    // Followed by filename (null-terminated)

    pub const SIZE: usize = 16;
};

comptime {
    if (@sizeOf(FuseOpenIn) != 8) {
        @compileError("FuseOpenIn size mismatch");
    }
    if (@sizeOf(FuseOpenOut) != 16) {
        @compileError("FuseOpenOut size mismatch");
    }
    if (@sizeOf(FuseCreateIn) != 16) {
        @compileError("FuseCreateIn size mismatch");
    }
}

// ============================================================================
// FUSE READ / WRITE Structures
// ============================================================================

/// FUSE_READ request body
pub const FuseReadIn = extern struct {
    /// File handle
    fh: u64 align(1),
    /// Offset in file
    offset: u64 align(1),
    /// Number of bytes to read
    size: u32 align(1),
    /// Read flags
    read_flags: u32 align(1),
    /// Lock owner
    lock_owner: u64 align(1),
    /// Flags
    flags: u32 align(1),
    /// Padding
    padding: u32 align(1),

    pub const SIZE: usize = 40;
};

/// FUSE_WRITE request body
pub const FuseWriteIn = extern struct {
    /// File handle
    fh: u64 align(1),
    /// Offset in file
    offset: u64 align(1),
    /// Number of bytes to write
    size: u32 align(1),
    /// Write flags
    write_flags: u32 align(1),
    /// Lock owner
    lock_owner: u64 align(1),
    /// Flags
    flags: u32 align(1),
    /// Padding
    padding: u32 align(1),
    // Followed by data to write

    pub const SIZE: usize = 40;
};

/// FUSE_WRITE response body
pub const FuseWriteOut = extern struct {
    /// Number of bytes written
    size: u32 align(1),
    /// Padding
    padding: u32 align(1),

    pub const SIZE: usize = 8;
};

comptime {
    if (@sizeOf(FuseReadIn) != 40) {
        @compileError("FuseReadIn size mismatch");
    }
    if (@sizeOf(FuseWriteIn) != 40) {
        @compileError("FuseWriteIn size mismatch");
    }
    if (@sizeOf(FuseWriteOut) != 8) {
        @compileError("FuseWriteOut size mismatch");
    }
}

// ============================================================================
// FUSE RELEASE Structures
// ============================================================================

/// FUSE_RELEASE / FUSE_RELEASEDIR request body
pub const FuseReleaseIn = extern struct {
    /// File handle
    fh: u64 align(1),
    /// Flags
    flags: u32 align(1),
    /// Release flags
    release_flags: u32 align(1),
    /// Lock owner
    lock_owner: u64 align(1),

    pub const SIZE: usize = 24;
};

comptime {
    if (@sizeOf(FuseReleaseIn) != 24) {
        @compileError("FuseReleaseIn size mismatch");
    }
}

// ============================================================================
// FUSE READDIR Structures
// ============================================================================

/// FUSE_READDIR request body (same as FUSE_READ)
pub const FuseReadDirIn = FuseReadIn;

/// Directory entry in READDIR response
/// Variable size: fixed header + name (padded to 8 bytes)
pub const FuseDirent = extern struct {
    /// Inode number
    ino: u64 align(1),
    /// Offset to next dirent
    off: u64 align(1),
    /// Name length
    namelen: u32 align(1),
    /// File type (DT_*)
    @"type": u32 align(1),
    // Followed by name[namelen], padded to 8-byte boundary

    pub const HEADER_SIZE: usize = 24;

    /// Calculate total size including name with padding
    pub fn totalSize(namelen: u32) usize {
        return HEADER_SIZE + std.mem.alignForward(usize, namelen, 8);
    }
};

// ============================================================================
// FUSE MKDIR / MKNOD / SYMLINK Structures
// ============================================================================

/// FUSE_MKDIR request body
pub const FuseMkdirIn = extern struct {
    /// Directory mode
    mode: u32 align(1),
    /// Umask
    umask: u32 align(1),
    // Followed by name (null-terminated)

    pub const SIZE: usize = 8;
};

/// FUSE_MKNOD request body
pub const FuseMknodIn = extern struct {
    /// File mode (type + permissions)
    mode: u32 align(1),
    /// Device number (for device files)
    rdev: u32 align(1),
    /// Umask
    umask: u32 align(1),
    /// Padding
    padding: u32 align(1),
    // Followed by name (null-terminated)

    pub const SIZE: usize = 16;
};

// FUSE_SYMLINK: name (null-terminated) + linkname (null-terminated)
// FUSE_LINK: FuseLinkIn + name (null-terminated)

/// FUSE_LINK request body
pub const FuseLinkIn = extern struct {
    /// Old node ID to link from
    oldnodeid: u64 align(1),
    // Followed by new name (null-terminated)

    pub const SIZE: usize = 8;
};

// ============================================================================
// FUSE RENAME Structures
// ============================================================================

/// FUSE_RENAME request body
pub const FuseRenameIn = extern struct {
    /// New parent directory node ID
    newdir: u64 align(1),
    // Followed by oldname + newname (both null-terminated)

    pub const SIZE: usize = 8;
};

/// FUSE_RENAME2 request body (with flags)
pub const FuseRename2In = extern struct {
    /// New parent directory node ID
    newdir: u64 align(1),
    /// Rename flags (RENAME_NOREPLACE, etc.)
    flags: u32 align(1),
    /// Padding
    padding: u32 align(1),
    // Followed by oldname + newname (both null-terminated)

    pub const SIZE: usize = 16;
};

// ============================================================================
// FUSE STATFS Structures
// ============================================================================

/// FUSE_STATFS response body
pub const FuseStatfsOut = extern struct {
    /// Filesystem statistics
    st: FuseKstatfs align(1),

    pub const SIZE: usize = FuseKstatfs.SIZE;
};

/// Filesystem statistics structure
pub const FuseKstatfs = extern struct {
    /// Total data blocks in filesystem
    blocks: u64 align(1),
    /// Free blocks in filesystem
    bfree: u64 align(1),
    /// Free blocks available to unprivileged user
    bavail: u64 align(1),
    /// Total file nodes in filesystem
    files: u64 align(1),
    /// Free file nodes in filesystem
    ffree: u64 align(1),
    /// Optimal transfer block size
    bsize: u32 align(1),
    /// Maximum length of filenames
    namelen: u32 align(1),
    /// Fragment size
    frsize: u32 align(1),
    /// Padding
    padding: u32 align(1),
    /// Spare
    spare: [6]u32 align(1),

    pub const SIZE: usize = 80;
};

comptime {
    if (@sizeOf(FuseKstatfs) != 80) {
        @compileError("FuseKstatfs size mismatch");
    }
}

// ============================================================================
// FUSE FORGET Structures
// ============================================================================

/// FUSE_FORGET request body (no response)
pub const FuseForgetIn = extern struct {
    /// Number of lookups to forget
    nlookup: u64 align(1),

    pub const SIZE: usize = 8;
};

/// FUSE_BATCH_FORGET request body (no response)
pub const FuseBatchForgetIn = extern struct {
    /// Number of forget requests
    count: u32 align(1),
    /// Padding
    dummy: u32 align(1),
    // Followed by count FuseForgetOne entries

    pub const SIZE: usize = 8;
};

/// Single forget entry in BATCH_FORGET
pub const FuseForgetOne = extern struct {
    /// Node ID to forget
    nodeid: u64 align(1),
    /// Number of lookups to forget
    nlookup: u64 align(1),

    pub const SIZE: usize = 16;
};

// ============================================================================
// Message Serialization Buffer
// ============================================================================

/// Buffer for building/parsing FUSE messages
pub const FuseBuffer = struct {
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
    // Write Operations
    // ========================================================================

    pub fn writeU8(self: *Self, val: u8) Error!void {
        if (self.remaining() < 1) return error.BufferFull;
        self.data[self.pos] = val;
        self.pos += 1;
    }

    pub fn writeU16(self: *Self, val: u16) Error!void {
        if (self.remaining() < 2) return error.BufferFull;
        std.mem.writeInt(u16, self.data[self.pos..][0..2], val, .little);
        self.pos += 2;
    }

    pub fn writeU32(self: *Self, val: u32) Error!void {
        if (self.remaining() < 4) return error.BufferFull;
        std.mem.writeInt(u32, self.data[self.pos..][0..4], val, .little);
        self.pos += 4;
    }

    pub fn writeI32(self: *Self, val: i32) Error!void {
        if (self.remaining() < 4) return error.BufferFull;
        std.mem.writeInt(i32, self.data[self.pos..][0..4], val, .little);
        self.pos += 4;
    }

    pub fn writeU64(self: *Self, val: u64) Error!void {
        if (self.remaining() < 8) return error.BufferFull;
        std.mem.writeInt(u64, self.data[self.pos..][0..8], val, .little);
        self.pos += 8;
    }

    /// Write null-terminated string
    pub fn writeString(self: *Self, str: []const u8) Error!void {
        if (self.remaining() < str.len + 1) return error.BufferFull;
        @memcpy(self.data[self.pos..][0..str.len], str);
        self.pos += str.len;
        self.data[self.pos] = 0;
        self.pos += 1;
    }

    /// Write raw bytes
    pub fn writeBytes(self: *Self, bytes: []const u8) Error!void {
        if (self.remaining() < bytes.len) return error.BufferFull;
        @memcpy(self.data[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    /// Write a struct
    pub fn writeStruct(self: *Self, comptime T: type, val: *const T) Error!void {
        const size = @sizeOf(T);
        if (self.remaining() < size) return error.BufferFull;
        const bytes: [*]const u8 = @ptrCast(val);
        @memcpy(self.data[self.pos..][0..size], bytes[0..size]);
        self.pos += size;
    }

    /// Reserve space and return a pointer to it
    pub fn reserve(self: *Self, size: usize) Error![]u8 {
        if (self.remaining() < size) return error.BufferFull;
        const ptr = self.data[self.pos..][0..size];
        self.pos += size;
        return ptr;
    }

    /// Update the length field in the header
    pub fn finalize(self: *Self) void {
        const len: u32 = @intCast(self.pos);
        std.mem.writeInt(u32, self.data[0..4], len, .little);
    }

    // ========================================================================
    // Read Operations
    // ========================================================================

    pub fn readU8(self: *Self) Error!u8 {
        if (self.remaining() < 1) return error.BufferUnderflow;
        const val = self.data[self.pos];
        self.pos += 1;
        return val;
    }

    pub fn readU16(self: *Self) Error!u16 {
        if (self.remaining() < 2) return error.BufferUnderflow;
        const val = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return val;
    }

    pub fn readU32(self: *Self) Error!u32 {
        if (self.remaining() < 4) return error.BufferUnderflow;
        const val = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    pub fn readI32(self: *Self) Error!i32 {
        if (self.remaining() < 4) return error.BufferUnderflow;
        const val = std.mem.readInt(i32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    pub fn readU64(self: *Self) Error!u64 {
        if (self.remaining() < 8) return error.BufferUnderflow;
        const val = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    /// Read a null-terminated string
    pub fn readString(self: *Self) Error![]const u8 {
        const start = self.pos;
        while (self.pos < self.capacity) {
            if (self.data[self.pos] == 0) {
                const str = self.data[start..self.pos];
                self.pos += 1; // Skip null terminator
                return str;
            }
            self.pos += 1;
        }
        return error.BufferUnderflow;
    }

    pub fn readBytes(self: *Self, count: usize) Error![]const u8 {
        if (self.remaining() < count) return error.BufferUnderflow;
        const bytes = self.data[self.pos..][0..count];
        self.pos += count;
        return bytes;
    }

    /// Read a struct
    pub fn readStruct(self: *Self, comptime T: type) Error!T {
        const size = @sizeOf(T);
        if (self.remaining() < size) return error.BufferUnderflow;
        const ptr: *align(1) const T = @ptrCast(self.data[self.pos..].ptr);
        self.pos += size;
        return ptr.*;
    }

    pub fn skip(self: *Self, count: usize) Error!void {
        if (self.remaining() < count) return error.BufferUnderflow;
        self.pos += count;
    }

    pub const Error = error{
        BufferFull,
        BufferUnderflow,
    };
};

// ============================================================================
// Message Builders
// ============================================================================

/// Build FUSE_INIT request
pub fn buildInit(buf: *FuseBuffer, unique: u64) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0); // len (filled in by finalize)
    try buf.writeU32(@intFromEnum(config.FuseOpcode.INIT));
    try buf.writeU64(unique);
    try buf.writeU64(0); // nodeid (not used for INIT)
    try buf.writeU32(0); // uid
    try buf.writeU32(0); // gid
    try buf.writeU32(0); // pid
    try buf.writeU32(0); // padding

    // INIT body
    try buf.writeU32(config.FUSE_KERNEL_VERSION);
    try buf.writeU32(config.FUSE_KERNEL_MINOR_VERSION);
    try buf.writeU32(config.Limits.MAX_IO_SIZE); // max_readahead
    try buf.writeU32(0); // flags (no special capabilities requested initially)

    buf.finalize();
}

/// Build FUSE_LOOKUP request
pub fn buildLookup(buf: *FuseBuffer, unique: u64, parent_nodeid: u64, name: []const u8) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.LOOKUP));
    try buf.writeU64(unique);
    try buf.writeU64(parent_nodeid);
    try buf.writeU32(0); // uid
    try buf.writeU32(0); // gid
    try buf.writeU32(0); // pid
    try buf.writeU32(0); // padding

    // Name (null-terminated)
    try buf.writeString(name);

    buf.finalize();
}

/// Build FUSE_GETATTR request
pub fn buildGetAttr(buf: *FuseBuffer, unique: u64, nodeid: u64, fh: ?u64) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.GETATTR));
    try buf.writeU64(unique);
    try buf.writeU64(nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // FuseGetAttrIn body
    if (fh) |handle| {
        try buf.writeU32(1); // FUSE_GETATTR_FH flag
        try buf.writeU32(0); // dummy
        try buf.writeU64(handle);
    } else {
        try buf.writeU32(0);
        try buf.writeU32(0);
        try buf.writeU64(0);
    }

    buf.finalize();
}

/// Build FUSE_OPEN request
pub fn buildOpen(buf: *FuseBuffer, unique: u64, nodeid: u64, flags: u32) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.OPEN));
    try buf.writeU64(unique);
    try buf.writeU64(nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // FuseOpenIn body
    try buf.writeU32(flags);
    try buf.writeU32(0); // unused

    buf.finalize();
}

/// Build FUSE_READ request
pub fn buildRead(buf: *FuseBuffer, unique: u64, nodeid: u64, fh: u64, offset: u64, size: u32) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.READ));
    try buf.writeU64(unique);
    try buf.writeU64(nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // FuseReadIn body
    try buf.writeU64(fh);
    try buf.writeU64(offset);
    try buf.writeU32(size);
    try buf.writeU32(0); // read_flags
    try buf.writeU64(0); // lock_owner
    try buf.writeU32(0); // flags
    try buf.writeU32(0); // padding

    buf.finalize();
}

/// Build FUSE_WRITE request (header only, data appended separately)
pub fn buildWriteHeader(buf: *FuseBuffer, unique: u64, nodeid: u64, fh: u64, offset: u64, size: u32) FuseBuffer.Error!void {
    buf.reset();

    // Header - length will be updated when data is added
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.WRITE));
    try buf.writeU64(unique);
    try buf.writeU64(nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // FuseWriteIn body
    try buf.writeU64(fh);
    try buf.writeU64(offset);
    try buf.writeU32(size);
    try buf.writeU32(0); // write_flags
    try buf.writeU64(0); // lock_owner
    try buf.writeU32(0); // flags
    try buf.writeU32(0); // padding
}

/// Build FUSE_RELEASE request
pub fn buildRelease(buf: *FuseBuffer, unique: u64, nodeid: u64, fh: u64, flags: u32, is_dir: bool) FuseBuffer.Error!void {
    buf.reset();

    const opcode: config.FuseOpcode = if (is_dir) .RELEASEDIR else .RELEASE;

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(opcode));
    try buf.writeU64(unique);
    try buf.writeU64(nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // FuseReleaseIn body
    try buf.writeU64(fh);
    try buf.writeU32(flags);
    try buf.writeU32(0); // release_flags
    try buf.writeU64(0); // lock_owner

    buf.finalize();
}

/// Build FUSE_READDIR request
pub fn buildReadDir(buf: *FuseBuffer, unique: u64, nodeid: u64, fh: u64, offset: u64, size: u32) FuseBuffer.Error!void {
    // Same structure as READ
    return buildRead(buf, unique, nodeid, fh, offset, size);
}

/// Build FUSE_OPENDIR request
pub fn buildOpenDir(buf: *FuseBuffer, unique: u64, nodeid: u64, flags: u32) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.OPENDIR));
    try buf.writeU64(unique);
    try buf.writeU64(nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // FuseOpenIn body
    try buf.writeU32(flags);
    try buf.writeU32(0);

    buf.finalize();
}

/// Build FUSE_CREATE request
pub fn buildCreate(buf: *FuseBuffer, unique: u64, parent_nodeid: u64, name: []const u8, flags: u32, mode: u32) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.CREATE));
    try buf.writeU64(unique);
    try buf.writeU64(parent_nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // FuseCreateIn body
    try buf.writeU32(flags);
    try buf.writeU32(mode);
    try buf.writeU32(0o022); // umask
    try buf.writeU32(0); // padding

    // Name (null-terminated)
    try buf.writeString(name);

    buf.finalize();
}

/// Build FUSE_MKDIR request
pub fn buildMkdir(buf: *FuseBuffer, unique: u64, parent_nodeid: u64, name: []const u8, mode: u32) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.MKDIR));
    try buf.writeU64(unique);
    try buf.writeU64(parent_nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // FuseMkdirIn body
    try buf.writeU32(mode);
    try buf.writeU32(0o022); // umask

    // Name (null-terminated)
    try buf.writeString(name);

    buf.finalize();
}

/// Build FUSE_UNLINK request
pub fn buildUnlink(buf: *FuseBuffer, unique: u64, parent_nodeid: u64, name: []const u8) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.UNLINK));
    try buf.writeU64(unique);
    try buf.writeU64(parent_nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // Name (null-terminated)
    try buf.writeString(name);

    buf.finalize();
}

/// Build FUSE_RMDIR request
pub fn buildRmdir(buf: *FuseBuffer, unique: u64, parent_nodeid: u64, name: []const u8) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.RMDIR));
    try buf.writeU64(unique);
    try buf.writeU64(parent_nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // Name (null-terminated)
    try buf.writeString(name);

    buf.finalize();
}

/// Build FUSE_RENAME request
pub fn buildRename(buf: *FuseBuffer, unique: u64, old_parent: u64, old_name: []const u8, new_parent: u64, new_name: []const u8) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.RENAME));
    try buf.writeU64(unique);
    try buf.writeU64(old_parent);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // FuseRenameIn body
    try buf.writeU64(new_parent);

    // Names (both null-terminated)
    try buf.writeString(old_name);
    try buf.writeString(new_name);

    buf.finalize();
}

/// Build FUSE_STATFS request
pub fn buildStatfs(buf: *FuseBuffer, unique: u64, nodeid: u64) FuseBuffer.Error!void {
    buf.reset();

    // Header only - no body
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.STATFS));
    try buf.writeU64(unique);
    try buf.writeU64(nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    buf.finalize();
}

/// Build FUSE_FORGET request (no response)
pub fn buildForget(buf: *FuseBuffer, unique: u64, nodeid: u64, nlookup: u64) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.FORGET));
    try buf.writeU64(unique);
    try buf.writeU64(nodeid);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);
    try buf.writeU32(0);

    // FuseForgetIn body
    try buf.writeU64(nlookup);

    buf.finalize();
}

/// Build FUSE_SETATTR request
/// valid_mask uses FuseSetAttrFlags to indicate which fields to set
pub fn buildSetAttr(
    buf: *FuseBuffer,
    unique: u64,
    nodeid: u64,
    valid_mask: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    atime: u64,
    atime_nsec: u32,
    mtime: u64,
    mtime_nsec: u32,
    fh: ?u64,
) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.SETATTR));
    try buf.writeU64(unique);
    try buf.writeU64(nodeid);
    try buf.writeU32(0); // uid
    try buf.writeU32(0); // gid
    try buf.writeU32(0); // pid
    try buf.writeU32(0); // padding

    // FuseSetAttrIn body (88 bytes)
    var mask = valid_mask;
    if (fh != null) {
        mask |= config.FuseSetAttrFlags.FH;
    }
    try buf.writeU32(mask); // valid
    try buf.writeU32(0); // padding
    try buf.writeU64(fh orelse 0); // fh
    try buf.writeU64(size); // size
    try buf.writeU64(0); // lock_owner
    try buf.writeU64(atime); // atime
    try buf.writeU64(mtime); // mtime
    try buf.writeU64(0); // ctime (unused, kernel sets)
    try buf.writeU32(atime_nsec); // atimensec
    try buf.writeU32(mtime_nsec); // mtimensec
    try buf.writeU32(0); // ctimensec
    try buf.writeU32(mode); // mode
    try buf.writeU32(0); // unused4
    try buf.writeU32(uid); // uid
    try buf.writeU32(gid); // gid
    try buf.writeU32(0); // unused5

    buf.finalize();
}

/// Build FUSE_SYMLINK request
/// Creates a symbolic link at parent_nodeid/name pointing to target
pub fn buildSymlink(buf: *FuseBuffer, unique: u64, parent_nodeid: u64, name: []const u8, target: []const u8) FuseBuffer.Error!void {
    buf.reset();

    // Header
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.SYMLINK));
    try buf.writeU64(unique);
    try buf.writeU64(parent_nodeid);
    try buf.writeU32(0); // uid
    try buf.writeU32(0); // gid
    try buf.writeU32(0); // pid
    try buf.writeU32(0); // padding

    // Body: name (null-terminated) + target (null-terminated)
    try buf.writeString(name);
    try buf.writeString(target);

    buf.finalize();
}

/// Build FUSE_READLINK request
/// Returns the symlink target for the given nodeid
pub fn buildReadlink(buf: *FuseBuffer, unique: u64, nodeid: u64) FuseBuffer.Error!void {
    buf.reset();

    // Header only - no body for READLINK
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.READLINK));
    try buf.writeU64(unique);
    try buf.writeU64(nodeid);
    try buf.writeU32(0); // uid
    try buf.writeU32(0); // gid
    try buf.writeU32(0); // pid
    try buf.writeU32(0); // padding

    buf.finalize();
}

/// Build FUSE_LINK request
/// Creates a hard link at new_parent/new_name pointing to oldnodeid
pub fn buildLink(buf: *FuseBuffer, unique: u64, oldnodeid: u64, new_parent: u64, new_name: []const u8) FuseBuffer.Error!void {
    buf.reset();

    // Header - nodeid is the new parent directory
    try buf.writeU32(0);
    try buf.writeU32(@intFromEnum(config.FuseOpcode.LINK));
    try buf.writeU64(unique);
    try buf.writeU64(new_parent);
    try buf.writeU32(0); // uid
    try buf.writeU32(0); // gid
    try buf.writeU32(0); // pid
    try buf.writeU32(0); // padding

    // FuseLinkIn body
    try buf.writeU64(oldnodeid);

    // New name (null-terminated)
    try buf.writeString(new_name);

    buf.finalize();
}

// ============================================================================
// Response Parsers
// ============================================================================

/// Parse FUSE response header
pub fn parseOutHeader(data: []const u8) ?FuseOutHeader {
    if (data.len < FuseOutHeader.SIZE) return null;
    const ptr: *align(1) const FuseOutHeader = @ptrCast(data.ptr);
    return ptr.*;
}

/// Parse FUSE_INIT response
pub fn parseInitOut(data: []const u8) ?FuseInitOut {
    if (data.len < FuseOutHeader.SIZE + FuseInitOut.SIZE) return null;
    const ptr: *align(1) const FuseInitOut = @ptrCast(data[FuseOutHeader.SIZE..].ptr);
    return ptr.*;
}

/// Parse FUSE_LOOKUP / FUSE_CREATE response
pub fn parseEntryOut(data: []const u8) ?FuseEntryOut {
    if (data.len < FuseOutHeader.SIZE + FuseEntryOut.SIZE) return null;
    const ptr: *align(1) const FuseEntryOut = @ptrCast(data[FuseOutHeader.SIZE..].ptr);
    return ptr.*;
}

/// Parse FUSE_GETATTR response
pub fn parseAttrOut(data: []const u8) ?FuseAttrOut {
    if (data.len < FuseOutHeader.SIZE + FuseAttrOut.SIZE) return null;
    const ptr: *align(1) const FuseAttrOut = @ptrCast(data[FuseOutHeader.SIZE..].ptr);
    return ptr.*;
}

/// Parse FUSE_OPEN / FUSE_OPENDIR / FUSE_CREATE response
pub fn parseOpenOut(data: []const u8) ?FuseOpenOut {
    if (data.len < FuseOutHeader.SIZE + FuseOpenOut.SIZE) return null;
    const ptr: *align(1) const FuseOpenOut = @ptrCast(data[FuseOutHeader.SIZE..].ptr);
    return ptr.*;
}

/// Parse FUSE_READ response (returns data slice)
pub fn parseReadData(data: []const u8) ?[]const u8 {
    if (data.len < FuseOutHeader.SIZE) return null;
    return data[FuseOutHeader.SIZE..];
}

/// Parse FUSE_WRITE response
pub fn parseWriteOut(data: []const u8) ?FuseWriteOut {
    if (data.len < FuseOutHeader.SIZE + FuseWriteOut.SIZE) return null;
    const ptr: *align(1) const FuseWriteOut = @ptrCast(data[FuseOutHeader.SIZE..].ptr);
    return ptr.*;
}

/// Parse FUSE_STATFS response
pub fn parseStatfsOut(data: []const u8) ?FuseStatfsOut {
    if (data.len < FuseOutHeader.SIZE + FuseStatfsOut.SIZE) return null;
    const ptr: *align(1) const FuseStatfsOut = @ptrCast(data[FuseOutHeader.SIZE..].ptr);
    return ptr.*;
}

/// Parse FUSE_READLINK response (returns symlink target as string slice)
pub fn parseReadlinkData(data: []const u8) ?[]const u8 {
    if (data.len < FuseOutHeader.SIZE) return null;
    // The target path follows the header, not null-terminated
    // Length is determined by (total_len - header_size)
    const header = parseOutHeader(data) orelse return null;
    if (header.@"error" != 0) return null;
    const payload_len = header.len -| FuseOutHeader.SIZE;
    if (data.len < FuseOutHeader.SIZE + payload_len) return null;
    return data[FuseOutHeader.SIZE..][0..payload_len];
}

// ============================================================================
// Tests
// ============================================================================

test "struct sizes" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 40), @sizeOf(FuseInHeader));
    try testing.expectEqual(@as(usize, 16), @sizeOf(FuseOutHeader));
    try testing.expectEqual(@as(usize, 88), @sizeOf(FuseAttr));
    try testing.expectEqual(@as(usize, 128), @sizeOf(FuseEntryOut));
}

test "FuseBuffer write/read" {
    const testing = std.testing;
    var backing: [256]u8 = undefined;
    var buf = FuseBuffer.init(&backing);

    try buf.writeU32(0xDEADBEEF);
    try buf.writeU64(0x123456789ABCDEF0);
    try buf.writeString("hello");

    buf.pos = 0;

    try testing.expectEqual(@as(u32, 0xDEADBEEF), try buf.readU32());
    try testing.expectEqual(@as(u64, 0x123456789ABCDEF0), try buf.readU64());
    try testing.expectEqualStrings("hello", try buf.readString());
}
