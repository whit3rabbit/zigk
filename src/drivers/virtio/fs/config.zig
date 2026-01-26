// VirtIO-FS Device Configuration
//
// Device configuration structures and feature bits per VirtIO Specification 1.2+
// Protocol: FUSE over VirtIO transport
//
// Reference: https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html
// Reference: https://www.kernel.org/doc/html/latest/filesystems/fuse.html

const std = @import("std");

// ============================================================================
// PCI Device Identification
// ============================================================================

/// VirtIO vendor ID
pub const PCI_VENDOR_VIRTIO: u16 = 0x1AF4;

/// VirtIO-FS modern device ID (VirtIO 1.0+)
/// Modern ID = 0x1040 + device_type (device_type for FS = 26)
pub const PCI_DEVICE_FS_MODERN: u16 = 0x105A;

/// VirtIO-FS legacy device ID (transitional)
pub const PCI_DEVICE_FS_LEGACY: u16 = 0x101A;

// ============================================================================
// VirtIO-FS Feature Bits
// ============================================================================

/// Feature flags for VirtIO-FS devices
pub const Features = struct {
    /// Device supports notification queue (not used in most implementations)
    pub const NOTIFICATION: u64 = 1 << 0;
};

// ============================================================================
// VirtIO-FS Configuration Space
// ============================================================================

/// Maximum mount tag length per VirtIO spec
pub const MAX_TAG_LEN: usize = 36;

/// VirtIO-FS device configuration
/// This structure is read from the device-specific configuration space
pub const VirtioFsConfig = extern struct {
    /// Mount tag string (e.g., "myfs")
    /// Null-padded, not necessarily null-terminated
    tag: [MAX_TAG_LEN]u8 align(1),
    /// Number of request queues (excludes hiprio queue)
    num_request_queues: u32 align(1),

    /// Get the mount tag as a slice (excluding null padding)
    pub fn getTag(self: *const volatile VirtioFsConfig) []const u8 {
        var buf: [MAX_TAG_LEN]u8 = undefined;
        var len: usize = 0;

        for (0..MAX_TAG_LEN) |i| {
            const c = self.tag[i];
            if (c == 0) break;
            buf[len] = c;
            len += 1;
        }

        // Return a copy to avoid volatile issues
        var result: [MAX_TAG_LEN]u8 = undefined;
        @memcpy(result[0..len], buf[0..len]);
        return result[0..len];
    }
};

// Compile-time verification of config structure size
comptime {
    // VirtIO-FS config is 36 + 4 = 40 bytes per spec
    if (@sizeOf(VirtioFsConfig) != 40) {
        @compileError("VirtioFsConfig size mismatch - expected 40 bytes");
    }
}

// ============================================================================
// VirtIO Queue Configuration
// ============================================================================

/// VirtIO-FS queue indices
pub const QueueIndex = struct {
    /// High-priority queue (FORGET, INTERRUPT)
    pub const HIPRIO: u16 = 0;
    /// First request queue (normal FUSE operations)
    pub const REQUEST: u16 = 1;
};

// ============================================================================
// FUSE Protocol Constants
// ============================================================================

/// FUSE kernel protocol version (major)
pub const FUSE_KERNEL_VERSION: u32 = 7;

/// FUSE kernel protocol minor version
/// We support FUSE 7.31+ for basic operations
pub const FUSE_KERNEL_MINOR_VERSION: u32 = 31;

/// Root node ID (always 1 in FUSE)
pub const FUSE_ROOT_ID: u64 = 1;

// ============================================================================
// FUSE Opcodes
// ============================================================================

/// FUSE operation codes
pub const FuseOpcode = enum(u32) {
    LOOKUP = 1,
    FORGET = 2, // No reply
    GETATTR = 3,
    SETATTR = 4,
    READLINK = 5,
    SYMLINK = 6,
    // 7 is missing (was GETDIR, removed)
    MKNOD = 8,
    MKDIR = 9,
    UNLINK = 10,
    RMDIR = 11,
    RENAME = 12,
    LINK = 13,
    OPEN = 14,
    READ = 15,
    WRITE = 16,
    STATFS = 17,
    RELEASE = 18,
    // 19 is missing
    FSYNC = 20,
    SETXATTR = 21,
    GETXATTR = 22,
    LISTXATTR = 23,
    REMOVEXATTR = 24,
    FLUSH = 25,
    INIT = 26,
    OPENDIR = 27,
    READDIR = 28,
    RELEASEDIR = 29,
    FSYNCDIR = 30,
    GETLK = 31,
    SETLK = 32,
    SETLKW = 33,
    ACCESS = 34,
    CREATE = 35,
    INTERRUPT = 36, // No reply expected
    BMAP = 37,
    DESTROY = 38,
    IOCTL = 39,
    POLL = 40,
    NOTIFY_REPLY = 41,
    BATCH_FORGET = 42,
    FALLOCATE = 43,
    READDIRPLUS = 44,
    RENAME2 = 45,
    LSEEK = 46,
    COPY_FILE_RANGE = 47,
    SETUPMAPPING = 48,
    REMOVEMAPPING = 49,

    _,

    pub fn noReply(self: FuseOpcode) bool {
        return self == .FORGET or self == .INTERRUPT or self == .BATCH_FORGET;
    }
};

// ============================================================================
// FUSE Init Flags
// ============================================================================

/// FUSE capability flags for INIT negotiation
pub const FuseInitFlags = struct {
    pub const ASYNC_READ: u32 = 1 << 0;
    pub const POSIX_LOCKS: u32 = 1 << 1;
    pub const FILE_OPS: u32 = 1 << 2;
    pub const ATOMIC_O_TRUNC: u32 = 1 << 3;
    pub const EXPORT_SUPPORT: u32 = 1 << 4;
    pub const BIG_WRITES: u32 = 1 << 5;
    pub const DONT_MASK: u32 = 1 << 6;
    pub const SPLICE_WRITE: u32 = 1 << 7;
    pub const SPLICE_MOVE: u32 = 1 << 8;
    pub const SPLICE_READ: u32 = 1 << 9;
    pub const FLOCK_LOCKS: u32 = 1 << 10;
    pub const HAS_IOCTL_DIR: u32 = 1 << 11;
    pub const AUTO_INVAL_DATA: u32 = 1 << 12;
    pub const DO_READDIRPLUS: u32 = 1 << 13;
    pub const READDIRPLUS_AUTO: u32 = 1 << 14;
    pub const ASYNC_DIO: u32 = 1 << 15;
    pub const WRITEBACK_CACHE: u32 = 1 << 16;
    pub const NO_OPEN_SUPPORT: u32 = 1 << 17;
    pub const PARALLEL_DIROPS: u32 = 1 << 18;
    pub const HANDLE_KILLPRIV: u32 = 1 << 19;
    pub const POSIX_ACL: u32 = 1 << 20;
    pub const ABORT_ERROR: u32 = 1 << 21;
    pub const MAX_PAGES: u32 = 1 << 22;
    pub const CACHE_SYMLINKS: u32 = 1 << 23;
    pub const NO_OPENDIR_SUPPORT: u32 = 1 << 24;
    pub const EXPLICIT_INVAL_DATA: u32 = 1 << 25;
    pub const MAP_ALIGNMENT: u32 = 1 << 26;
};

// ============================================================================
// FUSE Attribute Flags
// ============================================================================

/// Flags for SETATTR to indicate which fields to set
pub const FuseSetAttrFlags = struct {
    pub const MODE: u32 = 1 << 0;
    pub const UID: u32 = 1 << 1;
    pub const GID: u32 = 1 << 2;
    pub const SIZE: u32 = 1 << 3;
    pub const ATIME: u32 = 1 << 4;
    pub const MTIME: u32 = 1 << 5;
    pub const FH: u32 = 1 << 6;
    pub const ATIME_NOW: u32 = 1 << 7;
    pub const MTIME_NOW: u32 = 1 << 8;
    pub const LOCKOWNER: u32 = 1 << 9;
    pub const CTIME: u32 = 1 << 10;
};

// ============================================================================
// FUSE Open Flags
// ============================================================================

/// Flags for OPEN response
pub const FuseOpenFlags = struct {
    pub const DIRECT_IO: u32 = 1 << 0;
    pub const KEEP_CACHE: u32 = 1 << 1;
    pub const NONSEEKABLE: u32 = 1 << 2;
    pub const CACHE_DIR: u32 = 1 << 3;
    pub const STREAM: u32 = 1 << 4;
};

// ============================================================================
// File Type Bits (S_IF* from stat.h)
// ============================================================================

pub const FileType = struct {
    pub const S_IFMT: u32 = 0o170000; // Mask for file type
    pub const S_IFSOCK: u32 = 0o140000; // Socket
    pub const S_IFLNK: u32 = 0o120000; // Symbolic link
    pub const S_IFREG: u32 = 0o100000; // Regular file
    pub const S_IFBLK: u32 = 0o060000; // Block device
    pub const S_IFDIR: u32 = 0o040000; // Directory
    pub const S_IFCHR: u32 = 0o020000; // Character device
    pub const S_IFIFO: u32 = 0o010000; // FIFO

    pub fn isDir(mode: u32) bool {
        return (mode & S_IFMT) == S_IFDIR;
    }

    pub fn isRegular(mode: u32) bool {
        return (mode & S_IFMT) == S_IFREG;
    }

    pub fn isSymlink(mode: u32) bool {
        return (mode & S_IFMT) == S_IFLNK;
    }
};

// ============================================================================
// Driver Limits
// ============================================================================

/// Driver-imposed limits
pub const Limits = struct {
    /// Maximum message size (FUSE default is 128KB + headers)
    pub const MAX_MSG_SIZE: usize = 128 * 1024 + 4096;
    /// Default virtqueue size
    pub const DEFAULT_QUEUE_SIZE: u16 = 256;
    /// Maximum pending requests per queue
    pub const MAX_PENDING_REQUESTS: usize = 64;
    /// Maximum path length
    pub const MAX_PATH_LEN: usize = 4096;
    /// Maximum name length (single component)
    pub const MAX_NAME_LEN: usize = 255;
    /// Maximum cached inodes
    pub const MAX_CACHED_INODES: usize = 1024;
    /// Maximum cached dentries
    pub const MAX_CACHED_DENTRIES: usize = 2048;
    /// Default attribute TTL (seconds)
    pub const DEFAULT_ATTR_TTL_SECS: u64 = 1;
    /// Default entry TTL (seconds)
    pub const DEFAULT_ENTRY_TTL_SECS: u64 = 1;
    /// Maximum read/write size per request
    pub const MAX_IO_SIZE: u32 = 128 * 1024;
};

// ============================================================================
// FUSE Error Codes (negated errno values in out_header.error)
// ============================================================================

/// Map FUSE error code to positive errno
pub fn fuseErrorToErrno(fuse_error: i32) u32 {
    // FUSE uses negative errno values
    if (fuse_error < 0) {
        return @intCast(-fuse_error);
    }
    return 0;
}

// ============================================================================
// Tests
// ============================================================================

test "config struct sizes" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 40), @sizeOf(VirtioFsConfig));
}

test "opcode no reply" {
    const testing = std.testing;
    try testing.expect(FuseOpcode.FORGET.noReply());
    try testing.expect(FuseOpcode.INTERRUPT.noReply());
    try testing.expect(!FuseOpcode.LOOKUP.noReply());
    try testing.expect(!FuseOpcode.READ.noReply());
}
