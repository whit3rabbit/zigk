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

    // Phase 47: ext2 is read-only. Reject any write-mode open.
    const O_ACCMODE: u32 = 0o3;
    const O_RDONLY: u32 = 0;
    if ((flags & O_ACCMODE) != O_RDONLY) return error.AccessDenied;

    // Strip leading "/" from the VFS-relative path.
    // VFS strips the mount prefix "/mnt2" before calling open; the remainder
    // is either "/" (open the root directory itself) or "/filename".
    var rel_path = path;
    if (rel_path.len > 0 and rel_path[0] == '/') {
        rel_path = rel_path[1..];
    }

    // Opening the root directory itself ("/mnt2" -> rel_path "" or "/").
    if (rel_path.len == 0) {
        // Return a directory FD for the root inode.
        return openRootDir(fs, flags);
    }

    // Single-component lookup in the root directory.
    // Full multi-level path traversal is Phase 48.
    const inum = inode_mod.lookupInRootDir(fs, rel_path) catch |err| {
        return switch (err) {
            error.NotFound => error.NotFound,
            error.AccessDenied => error.AccessDenied,
            error.OutOfMemory => error.NoMemory,
            else => error.IOError,
        };
    };

    // Create a FileDescriptor for the found inode.
    const file_fd = inode_mod.openInode(fs, inum, flags) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.NoMemory,
            else => error.IOError,
        };
    };

    return file_fd;
}

/// Open the ext2 root directory (inode 2) and return a directory FD.
///
/// Phase 47 returns a simple directory-tag FD. Full getdents support
/// for ext2 directories is Phase 48.
fn openRootDir(fs: *Ext2Fs, flags: u32) vfs.Error!*fd.FileDescriptor {
    _ = fs; // Root dir inode read deferred to getdents (Phase 48)
    const tag_ptr: ?*anyopaque = @ptrCast(@constCast(&fd.initrd_dir_tag));
    return fd.createFd(&fd.dir_ops, flags, tag_ptr) catch return error.NoMemory;
}

fn ext2StatPath(ctx: ?*anyopaque, path: []const u8) ?vfs.FileMeta {
    const fs: *Ext2Fs = @ptrCast(@alignCast(ctx.?));

    // Strip leading "/" from VFS-relative path.
    var rel_path = path;
    if (rel_path.len > 0 and rel_path[0] == '/') {
        rel_path = rel_path[1..];
    }

    // Root directory stat.
    if (rel_path.len == 0) {
        // Read root inode (inode 2) for accurate metadata.
        const root_inode = inode_mod.readInode(fs, 2) catch {
            return vfs.FileMeta{
                .mode = @import("fs_meta").S_IFDIR | 0o755,
                .uid = 0,
                .gid = 0,
                .exists = true,
                .readonly = true,
            };
        };
        return vfs.FileMeta{
            .mode = @import("fs_meta").S_IFDIR | (@as(u32, root_inode.i_mode) & 0o777),
            .uid = @as(u32, root_inode.i_uid),
            .gid = @as(u32, root_inode.i_gid),
            .exists = true,
            .readonly = true,
            .ino = types.ROOT_INODE,
            .size = @as(u64, root_inode.i_size),
        };
    }

    // Single-component file lookup.
    const inum = inode_mod.lookupInRootDir(fs, rel_path) catch return null;
    const file_inode = inode_mod.readInode(fs, inum) catch return null;

    // Determine file type from inode mode upper nibble.
    const file_type: u32 = switch (file_inode.i_mode & types.S_IFMT) {
        types.S_IFDIR => @import("fs_meta").S_IFDIR,
        types.S_IFREG => @import("fs_meta").S_IFREG,
        types.S_IFLNK => @import("fs_meta").S_IFLNK,
        else => @import("fs_meta").S_IFREG,
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
    };

    return vfs.FileSystem{
        .context = self,
        .open = ext2Open,
        .unmount = ext2Unmount,
        .unlink = null,
        .stat_path = ext2StatPath,
        .chmod = null,
        .chown = null,
        .statfs = null,
        .rename = null,
        .rename2 = null,
        .truncate = null,
        .mkdir = null,
        .rmdir = null,
        .getdents = null,
        .link = null,
        .symlink = null,
        .readlink = null,
        .set_timestamps = null,
    };
}
