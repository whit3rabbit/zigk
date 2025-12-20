const std = @import("std");
const fd = @import("fd");
const sync = @import("sync");

// =============================================================================
// Constants
// =============================================================================

/// Magic: "SFS3" (version 3 with permissions)
pub const SFS_MAGIC: u32 = 0x33534653;
pub const SFS_VERSION: u32 = 3;
/// Previous version for read-only compatibility
pub const SFS_MAGIC_V2: u32 = 0x32534653;
pub const SFS_VERSION_2: u32 = 2;

pub const SECTOR_SIZE: u32 = 512;
pub const MAX_FILES: u32 = 64;

// =============================================================================
// On-Disk Structures
// =============================================================================

pub const Superblock = extern struct {
    magic: u32,
    version: u32,
    block_size: u32,
    total_blocks: u32,
    file_count: u32,
    free_blocks: u32,
    bitmap_start: u32,
    bitmap_blocks: u32,
    root_dir_start: u32,
    data_start: u32,
    next_free_block: u32, // Next block for sequential allocation
    _pad: [512 - 44]u8,
};

pub const DirEntry = extern struct {
    name: [32]u8,
    start_block: u32,
    size: u32,
    flags: u32, // 1 = Active
    mode: u32, // File type and permissions (e.g., 0o100644)
    uid: u32, // Owner user ID
    gid: u32, // Owner group ID
    mtime: u32, // Modification time (Unix timestamp)
    _pad: [128 - 60]u8, // Pad to 128 bytes

    /// Check if this is a regular file
    pub fn isRegularFile(self: *const @This()) bool {
        return (self.mode & 0o170000) == 0o100000;
    }

    /// Check if this is a directory
    pub fn isDirectory(self: *const @This()) bool {
        return (self.mode & 0o170000) == 0o040000;
    }

    /// Get permission bits only (lower 9 bits)
    pub fn getPermissions(self: *const @This()) u32 {
        return self.mode & 0o777;
    }
};

// =============================================================================
// Derived Constants
// =============================================================================

pub const ROOT_DIR_BLOCKS: u32 = (MAX_FILES * @sizeOf(DirEntry) + SECTOR_SIZE - 1) / SECTOR_SIZE;
/// Each bitmap block tracks 512*8 = 4096 blocks
pub const BITS_PER_BLOCK: u32 = SECTOR_SIZE * 8;
pub const BITMAP_BLOCKS: u32 = 4; // Supports up to 16384 blocks (8MB with 512B sectors)
pub const DATA_START_BLOCK: u32 = 1 + BITMAP_BLOCKS + ROOT_DIR_BLOCKS;

// =============================================================================
// Runtime Contexts
// =============================================================================

/// SECURITY: stores block allocation info at unlink time
/// Prevents block leaks if file is modified between unlink and close
pub const DeferredDeleteInfo = struct {
    start_block: u32,
    block_count: u32,
};

pub const SFS = struct {
    device_fd: *fd.FileDescriptor,
    superblock: Superblock,
    /// Lock protecting superblock updates (prevents TOCTOU in file growth)
    /// LOCK ORDERING: alloc_lock must be acquired BEFORE any FD locks
    alloc_lock: sync.Spinlock = .{},
    /// AHCI port number for direct async I/O access
    port_num: u5,
    /// True while filesystem is mounted and safe to use
    mounted: bool = true,

    /// Cached bitmap data to avoid frequent disk access and heap fragmentation
    /// Allocated once during init(), reused for all bitmap operations
    /// Size: MAX_BITMAP_BLOCKS * 512 = 16 * 512 = 8KB max
    bitmap_cache: ?[]u8 = null,
    bitmap_cache_valid: bool = false,

    // Statistics and tracking
    open_counts: [MAX_FILES]u32 = [_]u32{0} ** MAX_FILES,
    pending_delete: [MAX_FILES]bool = [_]bool{false} ** MAX_FILES,
    deferred_info: [MAX_FILES]DeferredDeleteInfo = [_]DeferredDeleteInfo{.{ .start_block = 0, .block_count = 0 }} ** MAX_FILES,

    /// Initialize SFS on a device
    pub fn init(device_path: []const u8) !@import("../vfs.zig").FileSystem {
        return @import("root.zig").init(device_path);
    }
};

pub const SfsFile = struct {
    fs: *SFS,
    start_block: u32,
    size: u32,
    entry_idx: u32,
    // SECURITY: store actual permissions for sfsStat
    mode: u32,
    uid: u32,
    gid: u32,

    pub const RefreshedMetadata = struct {
        size: u32,
        mode: u32,
        uid: u32,
        gid: u32,
    };
};

// =============================================================================
// Errors
// =============================================================================

pub const SfsError = error{
    IOError,
    InvalidBlock,
    ENOSPC,
    ENOMEM,
};

pub const SectorError = error{IOError};

pub const MsixVectorAllocation = struct {
    first_vector: u8,
    count: u8,
};
