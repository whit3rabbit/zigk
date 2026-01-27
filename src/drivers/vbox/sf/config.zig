//! VBoxSF Configuration Constants
//!
//! Constants and limits for VirtualBox Shared Folders driver.

const std = @import("std");

/// HGCM service name for shared folders
pub const HGCM_SERVICE_NAME = "VBoxSharedFolders";

/// Maximum path length for shared folder paths
pub const MAX_PATH_LEN: usize = 4096;

/// Maximum filename length
pub const MAX_NAME_LEN: usize = 255;

/// Maximum number of simultaneously open handles
pub const MAX_HANDLES: usize = 256;

/// Maximum read/write buffer size per operation
pub const MAX_IO_SIZE: usize = 64 * 1024; // 64KB

/// Maximum number of directory entries per readdir call
pub const MAX_DIRENT_COUNT: usize = 128;

/// Default timeout for HGCM calls (nanoseconds)
pub const DEFAULT_TIMEOUT_NS: u64 = 30_000_000_000; // 30 seconds

/// Maximum number of mounted shares
pub const MAX_MOUNTS: usize = 16;

/// Root handle value (returned from MAP_FOLDER)
pub const SHFLROOT_NIL: u32 = 0xFFFFFFFF;

/// Invalid handle value
pub const SHFLHANDLE_NIL: u64 = 0xFFFFFFFFFFFFFFFF;

/// File information flags
pub const FileInfoFlags = struct {
    /// Request file attributes
    pub const ATTR: u32 = 1 << 0;
    /// Request file size
    pub const SIZE: u32 = 1 << 1;
    /// Request allocation size
    pub const ALLOC_SIZE: u32 = 1 << 2;
    /// Request timestamps
    pub const TIMES: u32 = 1 << 3;
    /// All info
    pub const ALL: u32 = ATTR | SIZE | ALLOC_SIZE | TIMES;
};

/// File attributes (SHFL_FATTR_*)
pub const FileAttr = struct {
    pub const READONLY: u32 = 0x00000001;
    pub const HIDDEN: u32 = 0x00000002;
    pub const SYSTEM: u32 = 0x00000004;
    pub const DIRECTORY: u32 = 0x00000010;
    pub const ARCHIVE: u32 = 0x00000020;
    pub const SYMLINK: u32 = 0x00000400;
};

/// Create flags (SHFL_CF_*)
pub const CreateFlags = struct {
    /// Open existing file
    pub const OPEN_EXISTING: u32 = 0x00000000;
    /// Create new file, fail if exists
    pub const CREATE_NEW: u32 = 0x00000001;
    /// Open existing, create if not exists
    pub const OPEN_ALWAYS: u32 = 0x00000002;
    /// Truncate existing file
    pub const TRUNCATE_EXISTING: u32 = 0x00000003;
    /// Create new, truncate if exists
    pub const CREATE_ALWAYS: u32 = 0x00000004;

    /// Access mode mask
    pub const ACCESS_MASK: u32 = 0x00000038;
    /// No access (just query)
    pub const ACCESS_NONE: u32 = 0x00000000;
    /// Read access
    pub const ACCESS_READ: u32 = 0x00000008;
    /// Write access
    pub const ACCESS_WRITE: u32 = 0x00000010;
    /// Read/write access
    pub const ACCESS_READWRITE: u32 = 0x00000018;

    /// Open as directory
    pub const DIRECTORY: u32 = 0x00000040;

    /// Sharing mode mask
    pub const SHARING_MASK: u32 = 0x00001C00;
    /// Share read
    pub const SHARE_READ: u32 = 0x00000400;
    /// Share write
    pub const SHARE_WRITE: u32 = 0x00000800;
    /// Share delete
    pub const SHARE_DELETE: u32 = 0x00001000;
};

/// Create result codes (SHFL_RESULT_*)
pub const CreateResult = enum(u32) {
    /// Operation failed
    FAILED = 0,
    /// File was created
    CREATED = 1,
    /// File was opened
    OPENED = 2,
    /// File was truncated
    TRUNCATED = 3,
    /// File already exists (error for CREATE_NEW)
    FILE_EXISTS = 4,
    /// File not found (error for OPEN_EXISTING)
    FILE_NOT_FOUND = 5,
    /// Path not found
    PATH_NOT_FOUND = 6,
    _,
};
