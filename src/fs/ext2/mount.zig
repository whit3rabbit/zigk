//! ext2 filesystem mount module.
//!
//! Provides superblock parsing, block group descriptor table (BGDT) reading,
//! and a VFS FileSystem adapter for ext2 read-only support.
//!
//! Phase 47 updates:
//!   - ext2Open now resolves single-component paths via root directory scan
//!   - ext2StatPath now returns real inode metadata
//!   - inode.zig provides readInode, resolveBlock, file ops, and lookupInRootDir

const std = @import("std");
const types = @import("types.zig");
const vfs = @import("../vfs.zig");
const fd = @import("fd");
const heap = @import("heap");
const console = @import("console");
const inode_mod = @import("inode.zig");
const uapi = @import("uapi");

const BlockDevice = @import("block_device").BlockDevice;
const SECTOR_SIZE = @import("block_device").SECTOR_SIZE;

// ============================================================================
// Error types
// ============================================================================

pub const Ext2Error = error{ InvalidSuperblock, NotSupported, IOError, OutOfMemory };

// ============================================================================
// Filesystem state
// ============================================================================

pub const Ext2Fs = struct {
    dev: BlockDevice,
    superblock: types.Superblock,
    block_groups: []types.GroupDescriptor,
    block_size: u32,
    sectors_per_block: u32,
    group_count: u32,
    inode_size: u16,
    /// LRU inode cache (INODE-05). Eliminates redundant readInode disk reads
    /// during multi-component path traversal. 16 entries handles typical path
    /// depths (a/b/c/d = 5 components) with zero eviction.
    /// SECURITY: Explicitly zeroed in init() -- heap.allocator().create() does
    /// not zero-initialize in ReleaseFast.
    inode_cache: [inode_mod.INODE_CACHE_SIZE]inode_mod.InodeCacheEntry,
    inode_cache_gen: u64,
};

// ============================================================================
// Superblock parsing
// ============================================================================

/// Read and validate the ext2 superblock from `dev`.
///
/// Reads 2 sectors (1024 bytes) from SUPERBLOCK_LBA (2), checks the magic
/// number, validates that s_blocks_per_group and s_inodes_per_group are
/// non-zero, and rejects any INCOMPAT features besides INCOMPAT_FILETYPE.
pub fn parseSuperblock(dev: BlockDevice) Ext2Error!types.Superblock {
    var sb_buf: [1024]u8 align(4) = [_]u8{0} ** 1024;
    dev.readSectors(types.SUPERBLOCK_LBA, 2, &sb_buf) catch return error.IOError;

    const sb: types.Superblock = @as(*const types.Superblock, @ptrCast(@alignCast(&sb_buf))).*;

    if (sb.s_magic != types.EXT2_MAGIC) {
        console.err("ext2: bad magic 0x{X:0>4} (expected 0xEF53)", .{sb.s_magic});
        return error.InvalidSuperblock;
    }

    if (sb.s_blocks_per_group == 0 or sb.s_inodes_per_group == 0) {
        console.err("ext2: superblock has zero blocks_per_group or inodes_per_group", .{});
        return error.InvalidSuperblock;
    }

    const unsupported = sb.s_feature_incompat & ~types.SUPPORTED_INCOMPAT;
    if (unsupported != 0) {
        console.err("ext2: unsupported INCOMPAT features 0x{X}", .{unsupported});
        return error.NotSupported;
    }

    console.info("ext2: superblock OK, magic=0xEF53, block_size={d}, blocks={d}, groups={d}", .{
        sb.blockSize(),
        sb.s_blocks_count,
        sb.groupCount(),
    });

    return sb;
}

// ============================================================================
// Block Group Descriptor Table
// ============================================================================

/// Read the Block Group Descriptor Table (BGDT) from `dev`.
///
/// Allocates and returns a slice of GroupDescriptors.  The caller owns the
/// slice and must free it (the Ext2Fs unmount callback handles this).
pub fn readBgdt(
    dev: BlockDevice,
    sb: types.Superblock,
    allocator: std.mem.Allocator,
) Ext2Error![]types.GroupDescriptor {
    const group_count = sb.groupCount();
    if (group_count == 0) return error.InvalidSuperblock;

    const block_size = sb.blockSize();
    const sectors_per_block = block_size / SECTOR_SIZE;

    // BGDT is in the block immediately after the superblock block.
    // For 1KB block size: s_first_data_block == 1, BGDT is in block 2.
    // For 4KB block size: s_first_data_block == 0, BGDT is in block 1.
    const bgdt_block = std.math.add(u32, sb.s_first_data_block, 1) catch return error.InvalidSuperblock;
    const bgdt_lba = std.math.mul(u64, @as(u64, bgdt_block), @as(u64, sectors_per_block)) catch return error.InvalidSuperblock;

    const bgdt_bytes = std.math.mul(usize, group_count, @sizeOf(types.GroupDescriptor)) catch return error.InvalidSuperblock;
    const bgdt_sectors = (bgdt_bytes + SECTOR_SIZE - 1) / SECTOR_SIZE;

    const raw_buf = allocator.alignedAlloc(u8, .@"4", bgdt_sectors * SECTOR_SIZE) catch return error.OutOfMemory;
    errdefer allocator.free(raw_buf);

    dev.readSectors(bgdt_lba, @intCast(bgdt_sectors), raw_buf) catch return error.IOError;

    const groups = allocator.alloc(types.GroupDescriptor, group_count) catch return error.OutOfMemory;
    errdefer allocator.free(groups);

    const gd_slice = std.mem.bytesAsSlice(types.GroupDescriptor, raw_buf[0..bgdt_bytes]);
    @memcpy(groups, gd_slice);
    allocator.free(raw_buf);

    console.info("ext2: BGDT OK, {d} groups, first inode_table=block {d}", .{
        group_count,
        groups[0].bg_inode_table,
    });

    return groups;
}

// ============================================================================
// VFS adapter callbacks
// ============================================================================

fn ext2Open(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd.FileDescriptor {
    const fs: *Ext2Fs = @ptrCast(@alignCast(ctx.?));

    // ext2 is read-only. Reject any write-mode open.
    const O_ACCMODE: u32 = 0o3;
    const O_RDONLY: u32 = 0;
    if ((flags & O_ACCMODE) != O_RDONLY) return error.AccessDenied;

    // Strip leading "/" from the VFS-relative path.
    // VFS strips the mount prefix "/mnt2" before calling open; the remainder
    // is either "" (root directory itself) or "subdir/file" etc.
    var rel_path = path;
    if (rel_path.len > 0 and rel_path[0] == '/') {
        rel_path = rel_path[1..];
    }

    // Opening the root directory itself ("/mnt2" -> rel_path "").
    if (rel_path.len == 0) {
        return inode_mod.openDirInode(fs, types.ROOT_INODE, flags) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.NoMemory,
                else => error.IOError,
            };
        };
    }

    // Multi-component path resolution (Phase 48: replaces single-component lookupInRootDir).
    const inum = inode_mod.resolvePath(fs, rel_path) catch |err| {
        return switch (err) {
            error.NotFound => error.NotFound,
            error.AccessDenied => error.AccessDenied,
            error.OutOfMemory => error.NoMemory,
            else => error.IOError,
        };
    };

    // Determine inode type and open accordingly.
    const inode = inode_mod.getCachedInode(fs, inum) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.NoMemory,
            else => error.IOError,
        };
    };

    if (inode.isDir()) {
        return inode_mod.openDirInode(fs, inum, flags) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.NoMemory,
                else => error.IOError,
            };
        };
    }

    if (inode.isRegular()) {
        // Create a FileDescriptor for the found regular file inode.
        return inode_mod.openInode(fs, inum, flags) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.NoMemory,
                else => error.IOError,
            };
        };
    }

    // Symlinks and other types are not directly openable in Phase 48.
    // (Symlinks are accessed via readlink; following during traversal is Phase 49+.)
    return error.NotSupported;
}

fn ext2StatPath(ctx: ?*anyopaque, path: []const u8) ?vfs.FileMeta {
    const fs: *Ext2Fs = @ptrCast(@alignCast(ctx.?));
    const fs_meta = @import("fs_meta");

    // Strip leading "/" from VFS-relative path.
    var rel_path = path;
    if (rel_path.len > 0 and rel_path[0] == '/') {
        rel_path = rel_path[1..];
    }

    // Root directory stat (rel_path "").
    if (rel_path.len == 0) {
        const root_inode = inode_mod.getCachedInode(fs, types.ROOT_INODE) catch {
            return vfs.FileMeta{
                .mode = fs_meta.S_IFDIR | 0o755,
                .uid = 0,
                .gid = 0,
                .exists = true,
                .readonly = true,
            };
        };
        return vfs.FileMeta{
            .mode = fs_meta.S_IFDIR | (@as(u32, root_inode.i_mode) & 0o777),
            .uid = @as(u32, root_inode.i_uid),
            .gid = @as(u32, root_inode.i_gid),
            .exists = true,
            .readonly = true,
            .ino = types.ROOT_INODE,
            .size = @as(u64, root_inode.i_size),
        };
    }

    // Multi-component path resolution (Phase 48: replaces single-component lookupInRootDir).
    const inum = inode_mod.resolvePath(fs, rel_path) catch return null;
    const file_inode = inode_mod.getCachedInode(fs, inum) catch return null;

    // Determine file type from inode mode upper nibble.
    const file_type: u32 = switch (file_inode.i_mode & types.S_IFMT) {
        types.S_IFDIR => fs_meta.S_IFDIR,
        types.S_IFREG => fs_meta.S_IFREG,
        types.S_IFLNK => fs_meta.S_IFLNK,
        else => fs_meta.S_IFREG,
    };

    return vfs.FileMeta{
        .mode = file_type | (@as(u32, file_inode.i_mode) & 0o777),
        .uid = @as(u32, file_inode.i_uid),
        .gid = @as(u32, file_inode.i_gid),
        .exists = true,
        .readonly = true,
        .ino = @as(u64, inum),
        .size = @as(u64, file_inode.i_size),
        .atime = @intCast(file_inode.i_atime),
        .mtime = @intCast(file_inode.i_mtime),
    };
}

/// Read a fast symlink target from an ext2 inode (DIR-03).
///
/// Fast symlinks store the target in i_block[] when i_size <= 60 AND i_blocks == 0.
/// Slow symlinks (ADV-02) are deferred.
fn ext2Readlink(ctx: ?*anyopaque, path: []const u8, buf: []u8) vfs.Error!usize {
    const fs: *Ext2Fs = @ptrCast(@alignCast(ctx.?));

    // Strip leading "/" from VFS-relative path.
    var rel_path = path;
    if (rel_path.len > 0 and rel_path[0] == '/') rel_path = rel_path[1..];

    // Resolve path to inode.
    const inum = inode_mod.resolvePath(fs, rel_path) catch |err| {
        return switch (err) {
            error.NotFound => vfs.Error.NotFound,
            else => vfs.Error.IOError,
        };
    };

    const inode = inode_mod.getCachedInode(fs, inum) catch return vfs.Error.IOError;

    if (!inode.isSymlink()) return vfs.Error.NotSupported; // EINVAL: not a symlink

    // Fast symlink detection: target in i_block[] requires both conditions.
    // Pitfall: checking only i_size <= 60 is insufficient -- an old ext2 tool may
    // allocate a disk block (i_blocks != 0) even for short symlinks (slow symlink).
    if (inode.i_size > 60 or inode.i_blocks != 0) {
        // Slow symlink (ADV-02, deferred -- target is in a data block).
        return vfs.Error.NotSupported;
    }

    const target_len: usize = @min(@as(usize, inode.i_size), buf.len);
    if (target_len == 0) return 0;

    // Cast the i_block array (15 x u32 = 60 bytes) as a byte buffer.
    const i_block_bytes: *const [60]u8 = @ptrCast(&inode.i_block);
    @memcpy(buf[0..target_len], i_block_bytes[0..target_len]);

    return target_len;
}

/// Return filesystem statistics for the ext2 mount (DIR-05).
///
/// Reads from fs.superblock (in-memory since Phase 46 mount). No disk read needed.
fn ext2Statfs(ctx: ?*anyopaque) vfs.Error!uapi.stat.Statfs {
    const fs: *Ext2Fs = @ptrCast(@alignCast(ctx.?));
    const sb = &fs.superblock;

    // f_bavail excludes reserved blocks (s_r_blocks_count, reserved for root).
    // Guard against underflow if reserved > free (unusual but possible on near-full fs).
    const bavail: u32 = if (sb.s_free_blocks_count >= sb.s_r_blocks_count)
        sb.s_free_blocks_count - sb.s_r_blocks_count
    else
        0;

    return uapi.stat.Statfs{
        .f_type = 0xEF53, // EXT2_SUPER_MAGIC
        .f_bsize = @as(i64, @intCast(fs.block_size)),
        .f_blocks = @as(i64, @intCast(sb.s_blocks_count)),
        .f_bfree = @as(i64, @intCast(sb.s_free_blocks_count)),
        .f_bavail = @as(i64, @intCast(bavail)),
        .f_files = @as(i64, @intCast(sb.s_inodes_count)),
        .f_ffree = @as(i64, @intCast(sb.s_free_inodes_count)),
        .f_fsid = .{ .val = .{ 0, 0 } },
        .f_namelen = 255, // EXT2_NAME_LEN
        .f_frsize = @as(i64, @intCast(fs.block_size)), // Fragment size = block size
        .f_flags = 1, // ST_RDONLY (1) -- ext2 mount is read-only in Phase 48
        .f_spare = [_]i64{0} ** 4,
    };
}

fn ext2Unmount(ctx: ?*anyopaque) void {
    const self: *Ext2Fs = @ptrCast(@alignCast(ctx));
    heap.allocator().free(self.block_groups);
    heap.allocator().destroy(self);
}

// ============================================================================
// Public init function
// ============================================================================

/// Initialize ext2 filesystem state from `dev` and return a VFS FileSystem.
///
/// Parses the superblock, reads the BGDT, heap-allocates an Ext2Fs, and
/// returns a fully populated VFS FileSystem adapter ready to pass to
/// vfs.Vfs.mount().
pub fn init(dev: BlockDevice) !vfs.FileSystem {
    const sb = try parseSuperblock(dev);
    const groups = try readBgdt(dev, sb, heap.allocator());

    const inode_size: u16 = if (sb.s_rev_level >= types.EXT2_DYNAMIC_REV)
        sb.s_inode_size
    else
        types.EXT2_GOOD_OLD_INODE_SIZE;

    const self = try heap.allocator().create(Ext2Fs);
    errdefer heap.allocator().destroy(self);

    self.* = .{
        .dev = dev,
        .superblock = sb,
        .block_groups = groups,
        .block_size = sb.blockSize(),
        .sectors_per_block = @intCast(sb.blockSize() / SECTOR_SIZE),
        .group_count = sb.groupCount(),
        .inode_size = inode_size,
        // Placeholder -- these fields will be overwritten below.
        // Cannot use inode_mod.InodeCacheEntry here due to forward ref.
        .inode_cache = undefined,
        .inode_cache_gen = 0,
    };

    // SECURITY: Explicitly zero-initialize the inode cache.
    // heap.allocator().create() does NOT zero-initialize in ReleaseFast;
    // uninitialized inum fields could accidentally match real inode numbers.
    for (&self.inode_cache) |*slot| {
        slot.inum = 0;
        slot.lru_gen = 0;
        // slot.inode is intentionally left undefined -- inum=0 marks slot as empty.
    }
    self.inode_cache_gen = 0;

    return vfs.FileSystem{
        .context = self,
        .open = ext2Open,
        .unmount = ext2Unmount,
        .unlink = null,
        .stat_path = ext2StatPath,
        .chmod = null,
        .chown = null,
        .statfs = ext2Statfs,
        .rename = null,
        .rename2 = null,
        .truncate = null,
        .mkdir = null,
        .rmdir = null,
        // NOTE: getdents is NOT wired at the VFS FileSystem level for ext2.
        // ext2 directory getdents is dispatched through the directory FD's
        // FileOps.getdents callback (ext2_dir_ops.getdents = ext2GetdentsFromFd),
        // which sys_getdents64 checks first before falling back to VFS.
        .getdents = null,
        .link = null,
        .symlink = null,
        .readlink = ext2Readlink,
        .set_timestamps = null,
    };
}
