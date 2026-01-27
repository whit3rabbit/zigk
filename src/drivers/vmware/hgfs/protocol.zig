//! HGFS Protocol Definitions
//!
//! Wire format structures for VMware Host-Guest File System protocol V4.
//! All structures use packed layout for direct serialization.
//!
//! Reference: open-vm-tools/lib/include/hgfsProto.h

const std = @import("std");

// =============================================================================
// Protocol Constants
// =============================================================================

/// HGFS protocol version
pub const HGFS_PROTOCOL_VERSION: u32 = 4;

/// Maximum path length (NUL-separated components)
pub const MAX_PATH_LEN: usize = 1024;

/// Maximum filename length
pub const MAX_NAME_LEN: usize = 255;

/// Maximum data transfer per request
pub const MAX_IO_SIZE: usize = 62 * 1024; // 62KB to fit in 64KB RPCI limit with headers

/// Root handle (represents the share root)
pub const HGFS_ROOT_HANDLE: u32 = 0;

/// Invalid handle value
pub const HGFS_INVALID_HANDLE: u32 = 0xFFFFFFFF;

// =============================================================================
// Operation Codes
// =============================================================================

pub const HgfsOp = enum(u32) {
    // Session operations (V4)
    CreateSessionV4 = 31,
    DestroySessionV4 = 32,

    // File operations
    OpenV3 = 21,
    Close = 6,
    ReadV3 = 15,
    WriteV3 = 17,

    // Attribute operations
    GetAttrV2 = 12,
    SetAttrV2 = 13,

    // Directory operations
    SearchOpenV3 = 22,
    SearchReadV3 = 23,
    SearchClose = 10,
    CreateDirV3 = 24,
    DeleteFileV3 = 25,
    DeleteDirV3 = 26,
    RenameV3 = 27,

    // Symlink operations
    SymlinkCreate = 28,
    SymlinkRead = 11,
};

// =============================================================================
// Status Codes
// =============================================================================

pub const HgfsStatus = enum(u32) {
    Success = 0,
    NoSuchFile = 2,
    GenericError = 3,
    PermissionDenied = 13,
    InvalidHandle = 14,
    OperationNotSupported = 18,
    NameTooLong = 22,
    DirNotEmpty = 39,
    ProtocolError = 1000,
    NoTransport = 1002,
    BadOp = 1003,
    IoError = 1005,
    NotSupported = 1009,
    SessionNotFound = 1010,
    TooManySessions = 1011,
    StaleSession = 1012,
    _,

    pub fn isSuccess(self: HgfsStatus) bool {
        return self == .Success;
    }

    pub fn toErrno(self: HgfsStatus) i32 {
        return switch (self) {
            .Success => 0,
            .NoSuchFile => -2, // ENOENT
            .PermissionDenied => -13, // EACCES
            .InvalidHandle => -9, // EBADF
            .OperationNotSupported, .NotSupported => -38, // ENOSYS
            .NameTooLong => -36, // ENAMETOOLONG
            .DirNotEmpty => -39, // ENOTEMPTY
            .ProtocolError, .IoError => -5, // EIO
            .NoTransport => -111, // ECONNREFUSED
            .SessionNotFound, .StaleSession => -116, // ESTALE
            .TooManySessions => -23, // ENFILE
            else => -5, // EIO
        };
    }
};

// =============================================================================
// Request/Response Headers
// =============================================================================

/// HGFS request header (V4)
/// Layout: 9x u32 (36 bytes) + 2x u64 (16 bytes) = 52 bytes
pub const HgfsRequestHeader = extern struct {
    /// Protocol version
    version: u32 align(1) = HGFS_PROTOCOL_VERSION,
    /// Dummy field for alignment
    dummy: u32 align(1) = 0,
    /// Packet size (total including header)
    packet_size: u32 align(1),
    /// Header size
    header_size: u32 align(1),
    /// Request ID for correlation
    request_id: u32 align(1),
    /// Operation code
    op: u32 align(1),
    /// Status (0 for requests)
    status: u32 align(1),
    /// Flags
    flags: u32 align(1) = 0,
    /// Information (operation-specific)
    information: u32 align(1) = 0,
    /// Session ID
    session_id: u64 align(1),
    /// Reserved
    reserved: u64 align(1) = 0,

    pub const SIZE: usize = 52;

    pub fn init(op: HgfsOp, request_id: u32, session_id: u64) HgfsRequestHeader {
        return .{
            .packet_size = @intCast(SIZE),
            .header_size = @intCast(SIZE),
            .request_id = request_id,
            .op = @intFromEnum(op),
            .status = 0,
            .session_id = session_id,
        };
    }
};

comptime {
    if (@sizeOf(HgfsRequestHeader) != 52) {
        @compileError("HgfsRequestHeader size mismatch");
    }
}

/// HGFS reply header (V4)
/// Layout: 9x u32 (36 bytes) + 2x u64 (16 bytes) = 52 bytes
pub const HgfsReplyHeader = extern struct {
    /// Protocol version
    version: u32 align(1),
    /// Dummy field
    dummy: u32 align(1),
    /// Packet size
    packet_size: u32 align(1),
    /// Header size
    header_size: u32 align(1),
    /// Request ID (matches request)
    request_id: u32 align(1),
    /// Operation code
    op: u32 align(1),
    /// Status code
    status: u32 align(1),
    /// Flags
    flags: u32 align(1),
    /// Information
    information: u32 align(1),
    /// Session ID
    session_id: u64 align(1),
    /// Reserved
    reserved: u64 align(1),

    pub const SIZE: usize = 52;

    pub fn getStatus(self: *const HgfsReplyHeader) HgfsStatus {
        return @enumFromInt(self.status);
    }
};

comptime {
    if (@sizeOf(HgfsReplyHeader) != 52) {
        @compileError("HgfsReplyHeader size mismatch");
    }
}

// =============================================================================
// Session Operations
// =============================================================================

/// Create session request payload
pub const HgfsCreateSessionRequest = extern struct {
    /// Maximum packet size supported
    max_packet_size: u32 align(1) = 0x10000,
    /// Flags
    flags: u32 align(1) = 0,

    pub const SIZE: usize = 8;
};

/// Create session reply payload
pub const HgfsCreateSessionReply = extern struct {
    /// Session ID (use this for subsequent requests)
    session_id: u64 align(1),
    /// Number of shares available
    num_shares: u32 align(1),
    /// Maximum packet size
    max_packet_size: u32 align(1),
    /// Server flags
    flags: u32 align(1),
    /// Reserved
    reserved: u32 align(1),

    pub const SIZE: usize = 24;
};

// =============================================================================
// File Operations
// =============================================================================

/// Open flags
pub const HgfsOpenFlags = struct {
    pub const READ: u32 = 0x0001;
    pub const WRITE: u32 = 0x0002;
    pub const APPEND: u32 = 0x0004;
    pub const CREATE: u32 = 0x0010;
    pub const TRUNCATE: u32 = 0x0020;
    pub const EXCL: u32 = 0x0040;
    pub const DIRECTORY: u32 = 0x0100;
};

/// Open mode for file creation
pub const HgfsOpenMode = enum(u32) {
    OpenExisting = 0,
    OpenOrCreate = 1,
    CreateNew = 2,
    CreateAlways = 3,
    TruncateExisting = 4,
};

/// File type
pub const HgfsFileType = enum(u32) {
    Regular = 0,
    Directory = 1,
    Symlink = 2,
};

/// Open request (V3)
pub const HgfsOpenRequest = extern struct {
    /// Open mode
    mode: u32 align(1),
    /// Open flags
    flags: u32 align(1),
    /// Special flags
    special_flags: u32 align(1),
    /// Permissions for new file
    permissions: u32 align(1),
    /// Desired access
    desired_access: u32 align(1),
    /// Share access
    share_access: u32 align(1),
    /// Desired lock
    desired_lock: u32 align(1),
    /// Reserved
    reserved1: u32 align(1) = 0,
    reserved2: u32 align(1) = 0,
    /// File name length (NUL-separated path components)
    file_name_length: u32 align(1),
    // Followed by: u8[file_name_length] file_name

    pub const SIZE: usize = 40;
};

/// Open reply (V3)
pub const HgfsOpenReply = extern struct {
    /// File handle
    handle: u32 align(1),
    /// Server lock granted
    server_lock: u32 align(1),
    /// Acquired lock
    acquired_lock: u32 align(1),
    /// File flags
    flags: u32 align(1),

    pub const SIZE: usize = 16;
};

/// Read request (V3)
pub const HgfsReadRequest = extern struct {
    /// File handle
    handle: u32 align(1),
    /// Offset in file
    offset: u64 align(1),
    /// Number of bytes to read
    size: u32 align(1),
    /// Reserved
    reserved: u32 align(1) = 0,

    pub const SIZE: usize = 20;
};

/// Read reply (V3)
pub const HgfsReadReply = extern struct {
    /// Actual bytes read
    actual_size: u32 align(1),
    /// Reserved
    reserved: u32 align(1),
    // Followed by: u8[actual_size] data

    pub const SIZE: usize = 8;
};

/// Write request (V3)
pub const HgfsWriteRequest = extern struct {
    /// File handle
    handle: u32 align(1),
    /// Write flags
    flags: u32 align(1),
    /// Offset in file
    offset: u64 align(1),
    /// Number of bytes to write
    size: u32 align(1),
    /// Reserved
    reserved: u32 align(1) = 0,
    // Followed by: u8[size] data

    pub const SIZE: usize = 24;
};

/// Write reply (V3)
pub const HgfsWriteReply = extern struct {
    /// Actual bytes written
    actual_size: u32 align(1),
    /// Reserved
    reserved: u32 align(1),

    pub const SIZE: usize = 8;
};

/// Close request
pub const HgfsCloseRequest = extern struct {
    /// File handle
    handle: u32 align(1),
    /// Reserved
    reserved: u32 align(1) = 0,

    pub const SIZE: usize = 8;
};

// =============================================================================
// Attribute Operations
// =============================================================================

/// File attributes (V2)
pub const HgfsAttr = extern struct {
    /// Attribute mask (which fields are valid)
    mask: u64 align(1),
    /// File type
    file_type: u32 align(1),
    /// File size
    size: u64 align(1),
    /// Creation time (Windows FILETIME)
    creation_time: u64 align(1),
    /// Access time
    access_time: u64 align(1),
    /// Write time
    write_time: u64 align(1),
    /// Change time
    change_time: u64 align(1),
    /// Special permissions
    special_perms: u64 align(1),
    /// Owner permissions
    owner_perms: u64 align(1),
    /// Group permissions
    group_perms: u64 align(1),
    /// Other permissions
    other_perms: u64 align(1),
    /// Flags
    flags: u64 align(1),
    /// Allocation size
    alloc_size: u64 align(1),
    /// User ID
    uid: u32 align(1),
    /// Group ID
    gid: u32 align(1),
    /// Host file ID
    host_file_id: u64 align(1),
    /// Volume ID
    volume_id: u32 align(1),
    /// Effective permissions
    effective_perms: u32 align(1),
    /// Reserved
    reserved1: u64 align(1) = 0,
    reserved2: u64 align(1) = 0,

    pub const SIZE: usize = 144;

    /// Attribute mask bits
    pub const Mask = struct {
        pub const TYPE: u64 = 0x0001;
        pub const SIZE: u64 = 0x0002;
        pub const CREATE_TIME: u64 = 0x0004;
        pub const ACCESS_TIME: u64 = 0x0008;
        pub const WRITE_TIME: u64 = 0x0010;
        pub const CHANGE_TIME: u64 = 0x0020;
        pub const SPECIAL_PERMS: u64 = 0x0040;
        pub const OWNER_PERMS: u64 = 0x0080;
        pub const GROUP_PERMS: u64 = 0x0100;
        pub const OTHER_PERMS: u64 = 0x0200;
        pub const FLAGS: u64 = 0x0400;
        pub const ALLOC_SIZE: u64 = 0x0800;
        pub const UID: u64 = 0x1000;
        pub const GID: u64 = 0x2000;
        pub const FILEID: u64 = 0x4000;
        pub const VOLID: u64 = 0x8000;
    };

    /// Convert HGFS permissions to POSIX mode
    pub fn toMode(self: *const HgfsAttr) u32 {
        var mode: u32 = 0;

        // File type
        mode |= switch (@as(HgfsFileType, @enumFromInt(self.file_type))) {
            .Regular => 0o100000, // S_IFREG
            .Directory => 0o040000, // S_IFDIR
            .Symlink => 0o120000, // S_IFLNK
        };

        // Owner permissions
        if ((self.owner_perms & 0x04) != 0) mode |= 0o400; // read
        if ((self.owner_perms & 0x02) != 0) mode |= 0o200; // write
        if ((self.owner_perms & 0x01) != 0) mode |= 0o100; // exec

        // Group permissions
        if ((self.group_perms & 0x04) != 0) mode |= 0o040;
        if ((self.group_perms & 0x02) != 0) mode |= 0o020;
        if ((self.group_perms & 0x01) != 0) mode |= 0o010;

        // Other permissions
        if ((self.other_perms & 0x04) != 0) mode |= 0o004;
        if ((self.other_perms & 0x02) != 0) mode |= 0o002;
        if ((self.other_perms & 0x01) != 0) mode |= 0o001;

        return mode;
    }

    /// Convert Windows FILETIME (100ns since 1601) to Unix timestamp
    pub fn filetimeToUnix(filetime: u64) u64 {
        // FILETIME epoch is Jan 1, 1601. Unix epoch is Jan 1, 1970.
        // Difference is 11644473600 seconds = 116444736000000000 in 100ns units
        const FILETIME_UNIX_DIFF: u64 = 116444736000000000;
        if (filetime < FILETIME_UNIX_DIFF) return 0;
        return (filetime - FILETIME_UNIX_DIFF) / 10000000;
    }
};

/// GetAttr request (V2)
pub const HgfsGetAttrRequest = extern struct {
    /// Hints for attribute fetching
    hints: u64 align(1) = 0,
    /// Reserved
    reserved: u64 align(1) = 0,
    /// File name length
    file_name_length: u32 align(1),
    /// Case type (0 = default)
    case_type: u32 align(1) = 0,
    // Followed by: u8[file_name_length] file_name

    pub const SIZE: usize = 24;
};

/// GetAttr reply (V2)
pub const HgfsGetAttrReply = extern struct {
    /// File attributes
    attr: HgfsAttr align(1),
    /// Symlink target name length (if symlink)
    symlink_target_length: u32 align(1),
    // Followed by: u8[symlink_target_length] symlink_target (if symlink)

    pub const SIZE: usize = HgfsAttr.SIZE + 4;
};

// =============================================================================
// Directory Operations
// =============================================================================

/// SearchOpen request (V3) - start directory enumeration
pub const HgfsSearchOpenRequest = extern struct {
    /// Reserved
    reserved: u64 align(1) = 0,
    /// Directory name length
    dir_name_length: u32 align(1),
    /// Case type
    case_type: u32 align(1) = 0,
    // Followed by: u8[dir_name_length] dir_name

    pub const SIZE: usize = 16;
};

/// SearchOpen reply (V3)
pub const HgfsSearchOpenReply = extern struct {
    /// Search handle
    handle: u32 align(1),
    /// Reserved
    reserved: u32 align(1),

    pub const SIZE: usize = 8;
};

/// SearchRead request (V3) - read directory entries
pub const HgfsSearchReadRequest = extern struct {
    /// Search handle
    handle: u32 align(1),
    /// Offset (entry index)
    offset: u32 align(1),
    /// Flags
    flags: u32 align(1) = 0,
    /// Reserved
    reserved: u32 align(1) = 0,

    pub const SIZE: usize = 16;
};

/// Directory entry (V3)
pub const HgfsDirEntry = extern struct {
    /// Attributes
    attr: HgfsAttr align(1),
    /// File name length
    file_name_length: u32 align(1),
    /// Next entry offset (0 if last)
    next_entry_offset: u32 align(1),
    // Followed by: u8[file_name_length] file_name

    pub const HEADER_SIZE: usize = HgfsAttr.SIZE + 8;
};

/// SearchRead reply (V3)
pub const HgfsSearchReadReply = extern struct {
    /// Number of entries returned
    count: u32 align(1),
    /// Reserved
    reserved: u32 align(1),
    // Followed by: HgfsDirEntry entries (variable length)

    pub const SIZE: usize = 8;
};

/// SearchClose request
pub const HgfsSearchCloseRequest = extern struct {
    /// Search handle
    handle: u32 align(1),
    /// Reserved
    reserved: u32 align(1) = 0,

    pub const SIZE: usize = 8;
};

/// CreateDir request (V3)
pub const HgfsCreateDirRequest = extern struct {
    /// Permissions mask
    mask: u64 align(1) = HgfsAttr.Mask.OWNER_PERMS | HgfsAttr.Mask.GROUP_PERMS | HgfsAttr.Mask.OTHER_PERMS,
    /// Special permissions
    special_perms: u64 align(1) = 0,
    /// Owner permissions (RWX)
    owner_perms: u64 align(1) = 7,
    /// Group permissions
    group_perms: u64 align(1) = 5,
    /// Other permissions
    other_perms: u64 align(1) = 5,
    /// File name length
    file_name_length: u32 align(1),
    /// Case type
    case_type: u32 align(1) = 0,
    // Followed by: u8[file_name_length] file_name

    pub const SIZE: usize = 48;
};

/// Delete request (V3) - for files or directories
pub const HgfsDeleteRequest = extern struct {
    /// Hints
    hints: u64 align(1) = 0,
    /// Reserved
    reserved: u64 align(1) = 0,
    /// File name length
    file_name_length: u32 align(1),
    /// Case type
    case_type: u32 align(1) = 0,
    // Followed by: u8[file_name_length] file_name

    pub const SIZE: usize = 24;
};

/// Rename request (V3)
pub const HgfsRenameRequest = extern struct {
    /// Hints
    hints: u64 align(1) = 0,
    /// Reserved
    reserved: u64 align(1) = 0,
    /// Old name length
    old_name_length: u32 align(1),
    /// Old case type
    old_case_type: u32 align(1) = 0,
    /// New name length
    new_name_length: u32 align(1),
    /// New case type
    new_case_type: u32 align(1) = 0,
    // Followed by: u8[old_name_length] old_name
    //              u8[new_name_length] new_name

    pub const SIZE: usize = 32;
};

// =============================================================================
// Path Encoding
// =============================================================================

/// Encode a path for HGFS (NUL-separated components)
/// Returns the encoded length, or error if buffer too small
pub fn encodePath(path: []const u8, buf: []u8) error{BufferTooSmall}!usize {
    if (buf.len == 0) return error.BufferTooSmall;

    var pos: usize = 0;

    // Skip leading slash
    var src = path;
    if (src.len > 0 and src[0] == '/') {
        src = src[1..];
    }

    // Split on '/' and write NUL-separated components
    var iter = std.mem.splitScalar(u8, src, '/');
    var first = true;

    while (iter.next()) |component| {
        if (component.len == 0) continue;

        // SECURITY: Reject ".." traversal attempts
        if (std.mem.eql(u8, component, "..")) {
            continue; // Skip it - treat as invalid
        }

        // Skip "."
        if (std.mem.eql(u8, component, ".")) continue;

        // Add NUL separator (except for first component)
        if (!first) {
            if (pos >= buf.len) return error.BufferTooSmall;
            buf[pos] = 0;
            pos += 1;
        }
        first = false;

        // Copy component
        if (pos + component.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..component.len], component);
        pos += component.len;
    }

    return pos;
}

/// Decode an HGFS path (NUL-separated) to normal path
pub fn decodePath(encoded: []const u8, buf: []u8) error{BufferTooSmall}!usize {
    if (buf.len == 0) return error.BufferTooSmall;

    var pos: usize = 0;

    // Leading slash
    buf[pos] = '/';
    pos += 1;

    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == 0) {
            // NUL separator -> '/'
            if (pos >= buf.len) return error.BufferTooSmall;
            buf[pos] = '/';
            pos += 1;
        } else {
            if (pos >= buf.len) return error.BufferTooSmall;
            buf[pos] = encoded[i];
            pos += 1;
        }
        i += 1;
    }

    return pos;
}
