//! VBoxSF SHFL Protocol Definitions
//!
//! SHFL (Shared Folder) protocol structures for VirtualBox Guest Additions.
//! These structures are used in HGCM calls to the VBoxSharedFolders service.
//!
//! Reference: VirtualBox source - include/VBox/shflsvc.h

const std = @import("std");
const config = @import("config.zig");

/// SHFL function numbers (HGCM function codes)
pub const Function = enum(u32) {
    /// Query mappings (list shared folders)
    QUERY_MAPPINGS = 1,
    /// Query map name (get share name by root)
    QUERY_MAP_NAME = 2,
    /// Map folder (mount a share)
    MAP_FOLDER = 11,
    /// Unmap folder (unmount)
    UNMAP_FOLDER = 12,
    /// Create/open file or directory
    CREATE = 3,
    /// Close handle
    CLOSE = 4,
    /// Read from file
    READ = 5,
    /// Write to file
    WRITE = 6,
    /// List directory
    LIST = 8,
    /// Get file information
    INFORMATION = 25,
    /// Set file information
    SET_INFORMATION = 26,
    /// Remove file
    REMOVE = 9,
    /// Rename file/directory
    RENAME = 10,
    /// Flush file
    FLUSH = 7,
    /// Set UTF-8 encoding
    SET_UTF8 = 20,
    /// Symlink (create)
    SYMLINK = 24,
    _,
};

/// SHFL string structure
/// Variable-length UTF-8 or UTF-16 string with length prefix
pub const ShflString = extern struct {
    /// Length in bytes (excluding null terminator)
    length: u16,
    /// Buffer size in bytes
    size: u16,
    /// String data (null-terminated)
    /// Actual data follows this header

    pub const HEADER_SIZE: usize = 4;

    /// Get pointer to string data
    pub fn getData(self: *ShflString) [*]u8 {
        const ptr: [*]u8 = @ptrCast(self);
        return ptr + HEADER_SIZE;
    }

    /// Get string as slice
    pub fn getSlice(self: *ShflString) []u8 {
        return self.getData()[0..self.length];
    }

    /// Initialize a ShflString in a buffer
    pub fn initInBuffer(buf: []u8, str: []const u8) ?*ShflString {
        const total_size = HEADER_SIZE + str.len + 1; // +1 for null
        if (buf.len < total_size) return null;

        const header: *ShflString = @ptrCast(@alignCast(buf.ptr));
        header.length = @intCast(str.len);
        header.size = @intCast(str.len + 1);

        const data = header.getData();
        @memcpy(data[0..str.len], str);
        data[str.len] = 0; // null terminate

        return header;
    }

    /// Get total size of this ShflString including header
    pub fn totalSize(self: *const ShflString) usize {
        return HEADER_SIZE + self.size;
    }
};

/// File object info (SHFLFSOBJINFO)
/// Contains file metadata
pub const FsObjInfo = extern struct {
    /// Total allocation size (rounded to cluster)
    alloc_size: i64,
    /// Actual file size
    obj_size: i64,
    /// Creation time (nanoseconds since UNIX epoch)
    creation_time: i64,
    /// Last access time
    access_time: i64,
    /// Last modification time
    modification_time: i64,
    /// Last status change time
    change_time: i64,
    /// File attributes (SHFL_FATTR_*)
    attr: u32,
    /// Additional attributes (reserved)
    additional_attr: u32,
    /// Birth time (same as creation on Windows)
    birth_time: i64,

    pub const SIZE: usize = 64;

    pub fn isDirectory(self: *const FsObjInfo) bool {
        return (self.attr & config.FileAttr.DIRECTORY) != 0;
    }

    pub fn isSymlink(self: *const FsObjInfo) bool {
        return (self.attr & config.FileAttr.SYMLINK) != 0;
    }

    pub fn isReadonly(self: *const FsObjInfo) bool {
        return (self.attr & config.FileAttr.READONLY) != 0;
    }

    /// Convert to POSIX mode
    pub fn toMode(self: *const FsObjInfo) u32 {
        var mode: u32 = 0;

        if (self.isDirectory()) {
            mode = 0o040000; // S_IFDIR
        } else if (self.isSymlink()) {
            mode = 0o120000; // S_IFLNK
        } else {
            mode = 0o100000; // S_IFREG
        }

        // Default permissions
        if (self.isDirectory()) {
            mode |= 0o755;
        } else if (self.isReadonly()) {
            mode |= 0o444;
        } else {
            mode |= 0o644;
        }

        return mode;
    }
};

/// Create parameters (SHFLCREATEPARMS)
pub const CreateParams = extern struct {
    /// Result of operation
    result: config.CreateResult,
    /// Creation flags (SHFL_CF_*)
    create_flags: u32,
    /// File attributes
    info: FsObjInfo,
    /// Returned handle
    handle: u64,

    pub const SIZE: usize = 80;

    pub fn init(flags: u32) CreateParams {
        return CreateParams{
            .result = .FAILED,
            .create_flags = flags,
            .info = std.mem.zeroes(FsObjInfo),
            .handle = config.SHFLHANDLE_NIL,
        };
    }
};

/// Directory entry (SHFLDIRINFO)
/// Variable-length structure returned by LIST
pub const DirInfo = extern struct {
    /// Offset to next entry (0 if last)
    next_offset: u32,
    /// Short name length
    short_name_len: u32,
    /// File info
    info: FsObjInfo,
    /// Short name (DOS 8.3 format), null-terminated
    short_name: [14]u8,
    /// Name follows (ShflString)

    pub const HEADER_SIZE: usize = @sizeOf(DirInfo);

    /// Get pointer to the name ShflString
    pub fn getName(self: *DirInfo) *ShflString {
        const ptr: [*]u8 = @ptrCast(self);
        return @ptrCast(@alignCast(ptr + HEADER_SIZE));
    }

    /// Get next entry, or null if this is the last
    pub fn getNext(self: *DirInfo) ?*DirInfo {
        if (self.next_offset == 0) return null;
        const ptr: [*]u8 = @ptrCast(self);
        return @ptrCast(@alignCast(ptr + self.next_offset));
    }
};

/// Volume info (SHFLVOLINFO)
pub const VolumeInfo = extern struct {
    /// Total bytes
    total_bytes: u64,
    /// Available bytes
    avail_bytes: u64,
    /// Bytes per allocation unit
    bytes_per_unit: u32,
    /// Bytes per sector
    bytes_per_sector: u32,
    /// Serial number
    serial: u32,
    /// File system attributes
    fs_attrs: u32,
    /// Max filename length
    max_name_len: u32,
    /// Filesystem name follows (ShflString)

    pub const SIZE: usize = 36;
};

/// Mapping info returned by QUERY_MAPPINGS
pub const MappingInfo = extern struct {
    /// Root handle for this mapping
    root: u32,
    /// Status flags
    status: u32,

    pub const SIZE: usize = 8;

    /// Mapping is valid
    pub const STATUS_VALID: u32 = 1 << 0;
    /// Mapping is auto-mounted
    pub const STATUS_AUTO_MOUNT: u32 = 1 << 1;
    /// Mapping is writable
    pub const STATUS_WRITABLE: u32 = 1 << 2;
};

/// SHFL error codes
pub const ErrorCode = enum(i32) {
    OK = 0,
    GENERAL_FAILURE = -1,
    INVALID_PARAMETER = -2,
    INVALID_HANDLE = -3,
    NOT_FOUND = -4,
    NO_MEMORY = -5,
    ALREADY_EXISTS = -6,
    ACCESS_DENIED = -7,
    BUFFER_OVERFLOW = -8,
    NOT_DIRECTORY = -9,
    IS_DIRECTORY = -10,
    NOT_EMPTY = -11,
    READ_ONLY = -12,
    _,

    pub fn isSuccess(self: ErrorCode) bool {
        return @intFromEnum(self) >= 0;
    }
};

// Compile-time size checks
comptime {
    if (@sizeOf(FsObjInfo) != 64) {
        @compileError("FsObjInfo size mismatch");
    }
    if (@sizeOf(CreateParams) != 80) {
        @compileError("CreateParams size mismatch");
    }
}
