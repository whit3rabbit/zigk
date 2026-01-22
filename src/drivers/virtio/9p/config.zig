// VirtIO-9P Device Configuration
//
// Device configuration structures and feature bits per VirtIO Specification 1.2+ Section 5.11
// Protocol: 9P2000.u (Plan 9 filesystem with Unix extensions)
//
// Reference: https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html

const std = @import("std");

// ============================================================================
// PCI Device Identification
// ============================================================================

/// VirtIO vendor ID
pub const PCI_VENDOR_VIRTIO: u16 = 0x1AF4;

/// VirtIO-9P modern device ID (VirtIO 1.0+)
/// Modern ID = 0x1040 + device_type (device_type for 9P = 9)
pub const PCI_DEVICE_9P_MODERN: u16 = 0x1049;

/// VirtIO-9P legacy device ID (transitional)
pub const PCI_DEVICE_9P_LEGACY: u16 = 0x1009;

// ============================================================================
// VirtIO-9P Feature Bits
// ============================================================================

/// Feature flags for VirtIO-9P devices (Section 5.11.3)
pub const Features = struct {
    /// Device has a mount tag string in configuration space
    pub const MOUNT_TAG: u64 = 1 << 0;
};

// ============================================================================
// VirtIO-9P Configuration Space
// ============================================================================

/// Maximum mount tag length per VirtIO spec
pub const MAX_TAG_LEN: usize = 127;

/// VirtIO-9P device configuration (Section 5.11.4)
/// This structure is read from the device-specific configuration space
pub const Virtio9PConfig = extern struct {
    /// Length of mount tag string (tag follows immediately)
    tag_len: u16 align(1),
    /// Mount tag string (e.g., "hostshare")
    /// Null terminator not included in tag_len
    tag: [MAX_TAG_LEN]u8 align(1),

    /// Get the mount tag as a slice
    pub fn getTag(self: *const volatile Virtio9PConfig) []const u8 {
        const len = @min(self.tag_len, MAX_TAG_LEN);
        // Read tag bytes into a local buffer to avoid volatile issues
        var buf: [MAX_TAG_LEN]u8 = undefined;
        for (0..len) |i| {
            buf[i] = self.tag[i];
        }
        return buf[0..len];
    }

    /// Get the total config size
    pub fn size() usize {
        return @sizeOf(Virtio9PConfig);
    }
};

// Compile-time verification of config structure size
comptime {
    // VirtIO-9P config is 2 + 127 = 129 bytes per spec
    if (@sizeOf(Virtio9PConfig) != 129) {
        @compileError("Virtio9PConfig size mismatch - expected 129 bytes");
    }
}

// ============================================================================
// 9P2000.u Protocol Constants
// ============================================================================

/// 9P protocol version string for Tversion negotiation
pub const P9_PROTO_2000U = "9P2000.u";
pub const P9_PROTO_2000L = "9P2000.L"; // Linux extension (more features)

/// Default message size for negotiation (matches QEMU's default)
pub const P9_DEFAULT_MSIZE: u32 = 65536;

/// Maximum message size we support
pub const P9_MAX_MSIZE: u32 = 65536;

/// Special fid values
pub const P9_NOFID: u32 = 0xFFFFFFFF;

/// Root fid (conventionally 0)
pub const P9_ROOT_FID: u32 = 0;

// ============================================================================
// 9P Qid Types (file types encoded in qid.type)
// ============================================================================

pub const QidType = struct {
    /// Directory
    pub const DIR: u8 = 0x80;
    /// Append-only file
    pub const APPEND: u8 = 0x40;
    /// Exclusive use file
    pub const EXCL: u8 = 0x20;
    /// Mounted channel
    pub const MOUNT: u8 = 0x10;
    /// Authentication file
    pub const AUTH: u8 = 0x08;
    /// Temporary file (not backed by disk)
    pub const TMP: u8 = 0x04;
    /// Symbolic link
    pub const SYMLINK: u8 = 0x02;
    /// Hard link (9P2000.u extension)
    pub const LINK: u8 = 0x01;
    /// Regular file (no bits set)
    pub const FILE: u8 = 0x00;
};

// ============================================================================
// 9P Open Modes
// ============================================================================

pub const OpenMode = struct {
    /// Read access
    pub const READ: u8 = 0x00;
    /// Write access
    pub const WRITE: u8 = 0x01;
    /// Read and write access
    pub const RDWR: u8 = 0x02;
    /// Execute access (if supported)
    pub const EXEC: u8 = 0x03;
    /// Truncate file on open
    pub const TRUNC: u8 = 0x10;
    /// Close on exec (9P2000.u)
    pub const CEXEC: u8 = 0x20;
    /// Remove on close
    pub const RCLOSE: u8 = 0x40;
};

// ============================================================================
// 9P Permission Bits (for create/mkdir/wstat)
// ============================================================================

pub const DirMode = struct {
    /// Directory bit
    pub const DIR: u32 = 0x80000000;
    /// Append only
    pub const APPEND: u32 = 0x40000000;
    /// Exclusive use
    pub const EXCL: u32 = 0x20000000;
    /// Mounted channel
    pub const MOUNT: u32 = 0x10000000;
    /// Authentication file
    pub const AUTH: u32 = 0x08000000;
    /// Temporary file
    pub const TMP: u32 = 0x04000000;
    /// Symbolic link (9P2000.u)
    pub const SYMLINK: u32 = 0x02000000;
    /// Device file (9P2000.u)
    pub const DEVICE: u32 = 0x00800000;
    /// Named pipe (9P2000.u)
    pub const NAMEDPIPE: u32 = 0x00200000;
    /// Socket (9P2000.u)
    pub const SOCKET: u32 = 0x00100000;
    /// Setuid (9P2000.u)
    pub const SETUID: u32 = 0x00080000;
    /// Setgid (9P2000.u)
    pub const SETGID: u32 = 0x00040000;
};

// ============================================================================
// VirtIO Queue Configuration
// ============================================================================

/// VirtIO-9P uses a single virtqueue for request/response
pub const QueueIndex = struct {
    /// Request queue (9P messages)
    pub const REQUEST: u16 = 0;
};

// ============================================================================
// Driver Limits
// ============================================================================

/// Driver-imposed limits
pub const Limits = struct {
    /// Maximum number of tracked fids
    pub const MAX_FIDS: usize = 256;
    /// Maximum path component length
    pub const MAX_NAME_LEN: usize = 255;
    /// Maximum full path length
    pub const MAX_PATH_LEN: usize = 1024;
    /// Maximum walk elements per Twalk
    pub const MAX_WALK_ELEMS: usize = 16;
    /// Maximum pending requests
    pub const MAX_PENDING_REQUESTS: usize = 32;
    /// Default virtqueue size
    pub const DEFAULT_QUEUE_SIZE: u16 = 128;
    /// Request tag range (16-bit, 0xFFFF reserved)
    pub const MAX_TAG: u16 = 0xFFFE;
};

// ============================================================================
// Error Mapping (9P error strings -> POSIX errno)
// ============================================================================

/// Common 9P error strings and their errno equivalents
pub const ErrorMapping = struct {
    pattern: []const u8,
    errno: i32,
};

/// Standard 9P error mappings
pub const error_mappings = [_]ErrorMapping{
    .{ .pattern = "permission denied", .errno = 13 }, // EACCES
    .{ .pattern = "file not found", .errno = 2 }, // ENOENT
    .{ .pattern = "no such file", .errno = 2 }, // ENOENT
    .{ .pattern = "file exists", .errno = 17 }, // EEXIST
    .{ .pattern = "is a directory", .errno = 21 }, // EISDIR
    .{ .pattern = "not a directory", .errno = 20 }, // ENOTDIR
    .{ .pattern = "directory not empty", .errno = 39 }, // ENOTEMPTY
    .{ .pattern = "no space", .errno = 28 }, // ENOSPC
    .{ .pattern = "read-only", .errno = 30 }, // EROFS
    .{ .pattern = "invalid argument", .errno = 22 }, // EINVAL
    .{ .pattern = "operation not permitted", .errno = 1 }, // EPERM
    .{ .pattern = "bad fid", .errno = 9 }, // EBADF
    .{ .pattern = "too many open files", .errno = 24 }, // EMFILE
    .{ .pattern = "name too long", .errno = 36 }, // ENAMETOOLONG
    .{ .pattern = "i/o error", .errno = 5 }, // EIO
    .{ .pattern = "interrupted", .errno = 4 }, // EINTR
};

/// Map a 9P error string to a POSIX errno
/// Returns EIO (5) if no match found
pub fn mapP9Error(error_string: []const u8) i32 {
    // Convert to lowercase for case-insensitive matching
    var lower_buf: [256]u8 = undefined;
    const lower_len = @min(error_string.len, lower_buf.len);
    for (error_string[0..lower_len], 0..) |c, i| {
        lower_buf[i] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..lower_len];

    for (error_mappings) |mapping| {
        if (std.mem.indexOf(u8, lower, mapping.pattern) != null) {
            return mapping.errno;
        }
    }
    return 5; // EIO as default
}

// ============================================================================
// Tests
// ============================================================================

test "error mapping" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 2), mapP9Error("file not found"));
    try testing.expectEqual(@as(i32, 13), mapP9Error("Permission Denied")); // case insensitive
    try testing.expectEqual(@as(i32, 5), mapP9Error("unknown error")); // default
}
