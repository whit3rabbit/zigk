//! ext2 on-disk type definitions.
//!
//! Defines the canonical ext2/ext2fs on-disk structures as `extern struct` with
//! comptime size assertions. These definitions are shared across all ext2 phases.
//!
//! All fields are little-endian (native on both x86_64 and aarch64 freestanding targets).
//!
//! References:
//!   - ext2 specification: https://www.nongnu.org/ext2-doc/ext2.html
//!   - Linux kernel: fs/ext2/ext2.h

// ============================================================================
// Constants
// ============================================================================

/// Byte offset of the superblock from the start of the partition.
pub const SUPERBLOCK_OFFSET: u64 = 1024;

/// ext2 filesystem magic number (stored in Superblock.s_magic).
pub const EXT2_MAGIC: u16 = 0xEF53;

/// LBA sector containing the start of the superblock (1024 / 512 = sector 2).
pub const SUPERBLOCK_LBA: u64 = 2;

/// Inode number of the root directory.
pub const ROOT_INODE: u32 = 2;

/// Original ext2 revision (fixed inode size, no dynamic features).
pub const EXT2_GOOD_OLD_REV: u32 = 0;

/// Dynamic revision (variable inode size, feature flags).
pub const EXT2_DYNAMIC_REV: u32 = 1;

/// Inode size for EXT2_GOOD_OLD_REV (always 128 bytes).
pub const EXT2_GOOD_OLD_INODE_SIZE: u16 = 128;

// ============================================================================
// Incompatible feature flags (Superblock.s_feature_incompat)
// ============================================================================
// The kernel must refuse to mount if any unsupported INCOMPAT flag is set.

pub const INCOMPAT_COMPRESSION: u32 = 0x0001;
pub const INCOMPAT_FILETYPE: u32 = 0x0002;
pub const INCOMPAT_RECOVER: u32 = 0x0004;
pub const INCOMPAT_JOURNAL_DEV: u32 = 0x0008;
pub const INCOMPAT_META_BG: u32 = 0x0010;

/// Incompatible features this driver supports. mke2fs enables FILETYPE by default.
pub const SUPPORTED_INCOMPAT: u32 = INCOMPAT_FILETYPE;

// ============================================================================
// Inode mode constants (Inode.i_mode upper nibble)
// ============================================================================

pub const S_IFMT: u16 = 0xF000;
pub const S_IFSOCK: u16 = 0xC000;
pub const S_IFLNK: u16 = 0xA000;
pub const S_IFREG: u16 = 0x8000;
pub const S_IFBLK: u16 = 0x6000;
pub const S_IFDIR: u16 = 0x4000;
pub const S_IFCHR: u16 = 0x2000;
pub const S_IFIFO: u16 = 0x1000;

// ============================================================================
// Block pointer indices (Inode.i_block[])
// ============================================================================

/// Number of direct block pointers (i_block[0..11]).
pub const DIRECT_BLOCKS: u32 = 12;

/// Index of the single-indirect block pointer.
pub const INDIRECT_BLOCK: u32 = 12;

/// Index of the double-indirect block pointer.
pub const DOUBLE_INDIRECT_BLOCK: u32 = 13;

/// Index of the triple-indirect block pointer.
pub const TRIPLE_INDIRECT_BLOCK: u32 = 14;

// ============================================================================
// DirEntry file_type constants
// ============================================================================

pub const FT_UNKNOWN: u8 = 0;
pub const FT_REG_FILE: u8 = 1;
pub const FT_DIR: u8 = 2;
pub const FT_CHRDEV: u8 = 3;
pub const FT_BLKDEV: u8 = 4;
pub const FT_FIFO: u8 = 5;
pub const FT_SOCK: u8 = 6;
pub const FT_SYMLINK: u8 = 7;

// ============================================================================
// Superblock (1024 bytes, at byte offset 1024 from partition start)
// ============================================================================

/// ext2 superblock. Exactly 1024 bytes. Located at byte offset 1024 (LBA 2).
///
/// Use blockSize() to compute the filesystem block size from s_log_block_size.
/// Use groupCount() to compute the number of block groups.
pub const Superblock = extern struct {
    s_inodes_count: u32, // offset 0 -- total inode count
    s_blocks_count: u32, // offset 4 -- total block count
    s_r_blocks_count: u32, // offset 8 -- reserved blocks count
    s_free_blocks_count: u32, // offset 12 -- free blocks count
    s_free_inodes_count: u32, // offset 16 -- free inodes count
    s_first_data_block: u32, // offset 20 -- first data block (0 for 4KB blocks, 1 for 1KB)
    s_log_block_size: u32, // offset 24 -- block_size = 1024 << s_log_block_size
    s_log_frag_size: u32, // offset 28 -- fragment size (same as block size in practice)
    s_blocks_per_group: u32, // offset 32 -- blocks per block group
    s_frags_per_group: u32, // offset 36 -- fragments per block group
    s_inodes_per_group: u32, // offset 40 -- inodes per block group
    s_mtime: u32, // offset 44 -- last mount time (Unix timestamp)
    s_wtime: u32, // offset 48 -- last write time (Unix timestamp)
    s_mnt_count: u16, // offset 52 -- mount count since last fsck
    s_max_mnt_count: u16, // offset 54 -- max mounts before fsck required
    s_magic: u16, // offset 56 -- magic number (must be EXT2_MAGIC = 0xEF53)
    s_state: u16, // offset 58 -- filesystem state (1=clean, 2=errors)
    s_errors: u16, // offset 60 -- error handling policy
    s_minor_rev_level: u16, // offset 62 -- minor revision level
    s_lastcheck: u32, // offset 64 -- time of last fsck (Unix timestamp)
    s_checkinterval: u32, // offset 68 -- max time between fscks
    s_creator_os: u32, // offset 72 -- OS that created the filesystem
    s_rev_level: u32, // offset 76 -- revision level (0=GOOD_OLD, 1=DYNAMIC)
    s_def_resuid: u16, // offset 80 -- default UID for reserved blocks
    s_def_resgid: u16, // offset 82 -- default GID for reserved blocks
    // EXT2_DYNAMIC_REV fields (only valid when s_rev_level == EXT2_DYNAMIC_REV):
    s_first_ino: u32, // offset 84 -- first non-reserved inode
    s_inode_size: u16, // offset 88 -- inode size in bytes
    s_block_group_nr: u16, // offset 90 -- block group containing this superblock
    s_feature_compat: u32, // offset 92 -- compatible feature flags
    s_feature_incompat: u32, // offset 96 -- incompatible feature flags (must be supported)
    s_feature_ro_compat: u32, // offset 100 -- read-only compatible feature flags
    s_uuid: [16]u8, // offset 104 -- 128-bit filesystem UUID
    s_volume_name: [16]u8, // offset 120 -- volume label (null-padded)
    s_last_mounted: [64]u8, // offset 136 -- path where last mounted (null-padded)
    s_algo_bitmap: u32, // offset 200 -- compression algorithm bitmap
    // Performance hints:
    s_prealloc_blocks: u8, // offset 204 -- blocks to preallocate for files
    s_prealloc_dir_blocks: u8, // offset 205 -- blocks to preallocate for directories
    _padding1: u16, // offset 206 -- alignment padding
    // Journaling support (ext3):
    s_journal_uuid: [16]u8, // offset 208 -- journal superblock UUID
    s_journal_inum: u32, // offset 224 -- journal file inode number
    s_journal_dev: u32, // offset 228 -- journal file device number
    s_last_orphan: u32, // offset 232 -- head of orphan inode list
    // Directory indexing (HTree):
    s_hash_seed: [4]u32, // offset 236 -- HTREE hash seed
    s_def_hash_version: u8, // offset 252 -- default hash version
    _padding2: u8, // offset 253
    _padding3: u16, // offset 254
    // Other options:
    s_default_mount_opts: u32, // offset 256 -- default mount options
    s_first_meta_bg: u32, // offset 260 -- first metablock block group
    _reserved: [760]u8, // offset 264 -- pad to 1024 bytes (1024 - 264 = 760)

    comptime {
        if (@sizeOf(Superblock) != 1024) {
            @compileError("ext2 Superblock must be exactly 1024 bytes");
        }
    }

    /// Compute filesystem block size from s_log_block_size.
    /// block_size = 1024 << s_log_block_size (1KB, 2KB, or 4KB typically).
    pub fn blockSize(self: *const Superblock) u32 {
        return @as(u32, 1024) << @intCast(self.s_log_block_size);
    }

    /// Compute number of block groups, rounding up.
    pub fn groupCount(self: *const Superblock) u32 {
        return (self.s_blocks_count + self.s_blocks_per_group - 1) / self.s_blocks_per_group;
    }
};

// ============================================================================
// GroupDescriptor (32 bytes, one per block group)
// ============================================================================

/// Block group descriptor. Located in the block following the superblock.
/// There is one GroupDescriptor per block group.
pub const GroupDescriptor = extern struct {
    bg_block_bitmap: u32, // block number of block usage bitmap
    bg_inode_bitmap: u32, // block number of inode usage bitmap
    bg_inode_table: u32, // block number of first inode table block
    bg_free_blocks_count: u16, // free blocks count in this group
    bg_free_inodes_count: u16, // free inodes count in this group
    bg_used_dirs_count: u16, // number of directories in this group
    bg_pad: u16, // padding for alignment
    bg_reserved: [12]u8, // reserved (zeroed)

    comptime {
        if (@sizeOf(GroupDescriptor) != 32) {
            @compileError("ext2 GroupDescriptor must be exactly 32 bytes");
        }
    }
};

// ============================================================================
// Inode (128 bytes for EXT2_GOOD_OLD_INODE_SIZE)
// ============================================================================

/// ext2 inode. Fixed at 128 bytes for EXT2_GOOD_OLD_REV; may be larger
/// for EXT2_DYNAMIC_REV (check Superblock.s_inode_size).
///
/// i_block[0..11] = direct block pointers
/// i_block[12]    = single-indirect block pointer
/// i_block[13]    = double-indirect block pointer
/// i_block[14]    = triple-indirect block pointer
///
/// Note: i_blocks counts 512-byte units (not filesystem blocks).
pub const Inode = extern struct {
    i_mode: u16, // file mode (type + permissions)
    i_uid: u16, // owner UID (lower 16 bits)
    i_size: u32, // file size in bytes
    i_atime: u32, // last access time (Unix timestamp)
    i_ctime: u32, // inode change time (Unix timestamp)
    i_mtime: u32, // last modification time (Unix timestamp)
    i_dtime: u32, // deletion time (0 if not deleted)
    i_gid: u16, // owner GID (lower 16 bits)
    i_links_count: u16, // hard link count (0 = inode is free)
    i_blocks: u32, // 512-byte blocks allocated (NOT filesystem blocks)
    i_flags: u32, // file flags
    i_osd1: u32, // OS-specific field 1
    i_block: [15]u32, // block pointers (12 direct + 1 ind + 1 dind + 1 tind)
    i_generation: u32, // file version (used by NFS)
    i_file_acl: u32, // extended attributes block number
    i_dir_acl: u32, // upper 32 bits of file size for regular files in rev1
    i_faddr: u32, // fragment address (obsolete)
    i_osd2: [12]u8, // OS-specific field 2

    comptime {
        if (@sizeOf(Inode) != 128) {
            @compileError("ext2 Inode must be exactly 128 bytes");
        }
    }

    /// Returns true if this inode represents a directory.
    pub fn isDir(self: *const Inode) bool {
        return (self.i_mode & S_IFMT) == S_IFDIR;
    }

    /// Returns true if this inode represents a regular file.
    pub fn isRegular(self: *const Inode) bool {
        return (self.i_mode & S_IFMT) == S_IFREG;
    }

    /// Returns true if this inode represents a symbolic link.
    pub fn isSymlink(self: *const Inode) bool {
        return (self.i_mode & S_IFMT) == S_IFLNK;
    }
};

// ============================================================================
// DirEntry (8-byte fixed header; variable-length name follows)
// ============================================================================

/// Directory entry header. The name follows immediately after this struct in memory.
///
/// The name is NOT null-terminated on disk. name_len gives the actual length.
/// rec_len is the total entry length (header + name + padding to 4-byte boundary).
/// rec_len may be larger than 8 + name_len to skip deleted entries or pad to block end.
///
/// To iterate a directory block, walk by rec_len:
///   var offset: u16 = 0;
///   while (offset < block_size) : (offset += entry.rec_len) { ... }
pub const DirEntry = extern struct {
    inode: u32, // inode number (0 = entry is deleted/unused)
    rec_len: u16, // total entry length in bytes (including this header and name)
    name_len: u8, // actual length of the name (not including null terminator)
    file_type: u8, // file type (one of FT_* constants; requires INCOMPAT_FILETYPE)

    comptime {
        if (@sizeOf(DirEntry) != 8) {
            @compileError("ext2 DirEntry header must be exactly 8 bytes");
        }
    }
};
