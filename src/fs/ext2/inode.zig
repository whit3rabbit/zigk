//! ext2 inode read and block resolution.
//!
//! Implements Phase 47+48 inode-based file I/O for the ext2 filesystem:
//!   - readInode: locate and read an inode from the inode table using BGDT
//!   - resolveBlock: translate a logical file block to a physical disk block
//!     through direct, single-indirect, and double-indirect block trees
//!   - Ext2File: private_data struct for open file descriptors
//!   - ext2_file_ops: FileOps vtable for read/seek/close/stat
//!   - lookupInRootDir: single-level directory scan (inode 2 entries only)
//!   - openInode: create a FileDescriptor for a given inode number
//!
//! Phase 48 additions:
//!   - INODE_CACHE_SIZE / InodeCacheEntry: 16-entry LRU inode cache (INODE-05)
//!   - getCachedInode: cache-backed inode read (wraps readInode)
//!   - lookupInDir: generic directory entry scan for any directory inode (DIR-01)
//!   - resolvePath: multi-component path traversal calling lookupInDir (DIR-01)
//!   - Ext2DirFd / ext2_dir_ops: directory FD private data and FileOps (DIR-02)
//!   - ext2GetdentsFromFd: walk directory entries by rec_len, emit Dirent64 (DIR-02)
//!   - openDirInode: open a directory inode as a directory FD
//!
//! Security rules applied:
//!   - All block buffers are heap-allocated (never stack) to prevent overflow
//!   - All buffers are @memset to 0 before DMA reads (DMA hygiene)
//!   - All offset arithmetic uses std.math.add/mul (overflow safety)
//!   - Block number 0 is treated as sparse (not read from disk)

const std = @import("std");
const types = @import("types.zig");
const fd = @import("fd");
const heap = @import("heap");
const console = @import("console");
const uapi = @import("uapi");
const meta = @import("fs_meta");
const vfs = @import("../vfs.zig");

// uapi.stat and uapi.dirent are needed for Stat and Dirent64 in Phase 48 functions.

const mount = @import("mount.zig");
const Ext2Fs = mount.Ext2Fs;

const SECTOR_SIZE = @import("block_device").SECTOR_SIZE;

// ============================================================================
// Error types
// ============================================================================

pub const Ext2Error = error{
    IOError,
    InvalidInode,
    InvalidSuperblock,
    OutOfMemory,
    FileTooLarge,
    NotFound,
    AccessDenied,
};

// ============================================================================
// readInode: locate and read an inode from the inode table
// ============================================================================

/// Read inode `inum` from the ext2 filesystem.
///
/// Uses the Block Group Descriptor Table (BGDT) to locate the inode table
/// for the appropriate block group, then reads the inode data from disk.
///
/// Returns the inode by value. The caller can cache or discard as needed.
///
/// Security: buffer is zero-initialized before DMA read. All arithmetic is
/// overflow-checked with std.math.add/mul.
pub fn readInode(fs: *Ext2Fs, inum: u32) Ext2Error!types.Inode {
    // Inode 0 is reserved/invalid in ext2. Guard against (inum-1) underflow.
    if (inum == 0) return error.InvalidInode;

    const ipg = fs.superblock.s_inodes_per_group;
    if (ipg == 0) return error.InvalidSuperblock;

    // Compute block group index (0-based). Inode numbering is 1-based.
    const group_idx = (inum - 1) / ipg;
    if (group_idx >= fs.group_count) {
        console.err("ext2: inode {d}: group_idx {d} >= group_count {d}", .{
            inum, group_idx, fs.group_count,
        });
        return error.InvalidInode;
    }

    // Offset within the group's inode table (0-based).
    const offset_in_group = (inum - 1) % ipg;

    // Get the block group descriptor for this group.
    const gd = fs.block_groups[group_idx];
    const inode_table_block = gd.bg_inode_table;

    // Byte offset from start of inode table: offset_in_group * inode_size.
    // Use inode_size (the stride), not @sizeOf(types.Inode), because DYNAMIC_REV
    // images may have larger inodes (e.g., 256 bytes instead of 128).
    const inode_size_u64: u64 = @as(u64, fs.inode_size);
    const byte_offset_in_table = std.math.mul(u64, @as(u64, offset_in_group), inode_size_u64) catch {
        console.err("ext2: inode {d}: byte_offset_in_table overflow", .{inum});
        return error.InvalidInode;
    };

    // Absolute byte offset on disk: inode_table_block * block_size + byte_offset_in_table.
    const block_size_u64: u64 = @as(u64, fs.block_size);
    const table_start_byte = std.math.mul(u64, @as(u64, inode_table_block), block_size_u64) catch {
        console.err("ext2: inode {d}: table_start_byte overflow", .{inum});
        return error.InvalidInode;
    };
    const inode_byte_offset = std.math.add(u64, table_start_byte, byte_offset_in_table) catch {
        console.err("ext2: inode {d}: inode_byte_offset overflow", .{inum});
        return error.InvalidInode;
    };

    // Convert byte offset to LBA (512-byte sectors).
    const lba: u64 = inode_byte_offset / SECTOR_SIZE;
    const byte_in_sector: usize = @intCast(inode_byte_offset % SECTOR_SIZE);

    // Read 2 sectors to handle an inode spanning a sector boundary.
    // 2 * 512 = 1024 bytes -- safe to put on the kernel stack (not 4KB!).
    // SECURITY: Zero-initialize buffer before DMA read (DMA hygiene).
    var buf: [2 * SECTOR_SIZE]u8 align(4) = [_]u8{0} ** (2 * SECTOR_SIZE);

    // Determine how many sectors we need (1 or 2, depending on alignment).
    const sectors_needed: u32 = if (byte_in_sector + @as(usize, fs.inode_size) > SECTOR_SIZE) 2 else 1;
    fs.dev.readSectors(lba, sectors_needed, buf[0 .. sectors_needed * SECTOR_SIZE]) catch {
        console.err("ext2: readInode({d}): readSectors lba={d} failed", .{ inum, lba });
        return error.IOError;
    };

    // Verify the inode fits in the buffer (safety check for malformed images).
    if (byte_in_sector + @sizeOf(types.Inode) > buf.len) {
        console.err("ext2: inode {d}: inode_byte_offset puts inode past buffer end", .{inum});
        return error.InvalidInode;
    }

    // Cast the relevant slice to *const types.Inode and return by value.
    // types.Inode is 128 bytes; we only read the standard fields.
    const inode: types.Inode = @as(*const types.Inode, @ptrCast(@alignCast(buf[byte_in_sector..].ptr))).*;

    console.debug("ext2: inode {d}: mode=0x{X:0>4} size={d} links={d} block[0]={d}", .{
        inum, inode.i_mode, inode.i_size, inode.i_links_count, inode.i_block[0],
    });

    return inode;
}

// ============================================================================
// resolveBlock: translate logical block number to physical block number
// ============================================================================

/// Translate a logical (file-relative) block number to a physical disk block.
///
/// Returns 0 for sparse blocks (physical block 0 means "not allocated" in ext2;
/// callers must return zeros for reads on sparse regions).
///
/// Supports:
///   - Direct blocks: logical_block 0..11 via i_block[0..11]
///   - Single-indirect: logical_block 12..12+ptrs_per_block-1 via i_block[12]
///   - Double-indirect: logical_block 12+ptrs_per_block..limit via i_block[13]
///   - Triple-indirect: returns error.FileTooLarge (deferred to ADV-01)
///
/// SECURITY: All block buffers are heap-allocated. All buffers are zeroed
/// before reads. All arithmetic is overflow-checked.
pub fn resolveBlock(fs: *Ext2Fs, inode: *const types.Inode, logical_block: u32) Ext2Error!u32 {
    const ptrs_per_block: u32 = fs.block_size / 4; // u32 pointers per block

    // ---- Direct blocks (i_block[0..11]) ------------------------------------
    if (logical_block < types.DIRECT_BLOCKS) {
        // Block 0 means sparse (not allocated); caller handles zeros.
        return inode.i_block[logical_block];
    }

    // Offset past the 12 direct blocks.
    const lb1 = logical_block - types.DIRECT_BLOCKS;

    // ---- Single-indirect (i_block[12]) -------------------------------------
    if (lb1 < ptrs_per_block) {
        const ind_num = inode.i_block[types.INDIRECT_BLOCK];
        if (ind_num == 0) return 0; // sparse

        const alloc = heap.allocator();
        // Use alignedAlloc so the buffer can be safely cast to []u32.
        const ibuf = alloc.alignedAlloc(u8, .@"4", fs.block_size) catch return error.OutOfMemory;
        defer alloc.free(ibuf);
        @memset(ibuf, 0); // DMA hygiene

        const ind_lba = std.math.mul(u64, @as(u64, ind_num), @as(u64, fs.sectors_per_block)) catch {
            return error.InvalidInode;
        };
        fs.dev.readSectors(ind_lba, fs.sectors_per_block, ibuf) catch {
            console.err("ext2: resolveBlock: single-indirect read lba={d} failed", .{ind_lba});
            return error.IOError;
        };

        const ptrs = std.mem.bytesAsSlice(u32, ibuf);
        if (lb1 >= ptrs.len) return error.InvalidInode;
        return ptrs[lb1];
    }

    // Offset past the single-indirect range.
    const lb2 = lb1 - ptrs_per_block;

    // ---- Double-indirect (i_block[13]) -------------------------------------
    // Check overflow: ptrs_per_block^2 could overflow u32 for small block sizes,
    // but for 4KB blocks ptrs_per_block=1024, so 1024*1024=1048576 fits in u32.
    const dind_range = std.math.mul(u32, ptrs_per_block, ptrs_per_block) catch {
        return error.FileTooLarge;
    };
    if (lb2 < dind_range) {
        const dind_num = inode.i_block[types.DOUBLE_INDIRECT_BLOCK];
        if (dind_num == 0) return 0; // sparse

        const alloc = heap.allocator();

        // Read the outer (double-indirect) pointer table.
        const outer = alloc.alignedAlloc(u8, .@"4", fs.block_size) catch return error.OutOfMemory;
        defer alloc.free(outer);
        @memset(outer, 0); // DMA hygiene

        const outer_lba = std.math.mul(u64, @as(u64, dind_num), @as(u64, fs.sectors_per_block)) catch {
            return error.InvalidInode;
        };
        fs.dev.readSectors(outer_lba, fs.sectors_per_block, outer) catch {
            console.err("ext2: resolveBlock: double-indirect outer read lba={d} failed", .{outer_lba});
            return error.IOError;
        };

        const outer_ptrs = std.mem.bytesAsSlice(u32, outer);
        const outer_idx = lb2 / ptrs_per_block;
        if (outer_idx >= outer_ptrs.len) return error.InvalidInode;
        const inner_num = outer_ptrs[outer_idx];
        if (inner_num == 0) return 0; // sparse inner table

        // Read the inner (single-indirect) pointer table.
        const inner = alloc.alignedAlloc(u8, .@"4", fs.block_size) catch return error.OutOfMemory;
        defer alloc.free(inner);
        @memset(inner, 0); // DMA hygiene

        const inner_lba = std.math.mul(u64, @as(u64, inner_num), @as(u64, fs.sectors_per_block)) catch {
            return error.InvalidInode;
        };
        fs.dev.readSectors(inner_lba, fs.sectors_per_block, inner) catch {
            console.err("ext2: resolveBlock: double-indirect inner read lba={d} failed", .{inner_lba});
            return error.IOError;
        };

        const inner_ptrs = std.mem.bytesAsSlice(u32, inner);
        const inner_idx = lb2 % ptrs_per_block;
        if (inner_idx >= inner_ptrs.len) return error.InvalidInode;
        return inner_ptrs[inner_idx];
    }

    // Triple-indirect is ADV-01 (deferred). Files requiring triple-indirect are
    // larger than 12 + 1024 + 1024^2 = 1049612 blocks = ~4GB at 4KB block size.
    console.err("ext2: resolveBlock: logical_block {d} requires triple-indirect (not implemented)", .{logical_block});
    return error.FileTooLarge;
}

// ============================================================================
// Ext2File: private_data for open ext2 file descriptors
// ============================================================================

/// Private data stored in FileDescriptor.private_data for open ext2 files.
const Ext2File = struct {
    /// Back-pointer to the mounted filesystem state.
    fs: *Ext2Fs,
    /// Inode number of this file (1-based ext2 inode numbering).
    inode_num: u32,
    /// Cached copy of the inode (read at open time, immutable for Phase 47).
    inode: types.Inode,
    /// File size in bytes (from inode.i_size at open time).
    size: u64,
};

// ============================================================================
// FileOps vtable for ext2 regular files
// ============================================================================

/// FileOps vtable for ext2 read-only file descriptors.
/// Phase 47: write is null (read-only). Phase 49 adds write support.
pub const ext2_file_ops = fd.FileOps{
    .read = ext2FileRead,
    .write = null,
    .close = ext2FileClose,
    .seek = ext2FileSeek,
    .stat = ext2FileStat,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
    .getdents = null,
    .chown = null,
};

// ============================================================================
// ext2FileRead: read file data block by block
// ============================================================================

fn ext2FileRead(file_desc: *fd.FileDescriptor, buf: []u8) isize {
    const file: *Ext2File = @ptrCast(@alignCast(file_desc.private_data.?));
    const fs = file.fs;

    // EOF check.
    if (file_desc.position >= file.size) return 0;

    const remaining = file.size - file_desc.position;
    const to_read = @min(buf.len, remaining);
    var read_count: usize = 0;
    var pos = file_desc.position;

    while (read_count < to_read) {
        // Compute which logical block covers the current position.
        const logical_block: u32 = @intCast(pos / fs.block_size);
        const byte_in_block: usize = @intCast(pos % fs.block_size);

        // Resolve the logical block to a physical block number.
        const phys_block = resolveBlock(fs, &file.inode, logical_block) catch |err| {
            console.err("ext2: read inode {d} block {d}: resolve error: {s}", .{
                file.inode_num, logical_block, @errorName(err),
            });
            return -5; // EIO
        };

        // How many bytes to copy from this block.
        const chunk = @min(to_read - read_count, fs.block_size - byte_in_block);

        if (phys_block == 0) {
            // Sparse block: return zeros (ext2 spec mandates zeros for holes).
            @memset(buf[read_count..][0..chunk], 0);
        } else {
            // SECURITY: Heap-allocate block buffer -- 4KB is too large for kernel stack
            // and would trigger stack overflow on aarch64 (MEMORY.md documented pattern).
            const alloc = heap.allocator();
            const block_buf = alloc.alloc(u8, fs.block_size) catch return -12; // ENOMEM
            defer alloc.free(block_buf);
            @memset(block_buf, 0); // DMA hygiene

            const lba = std.math.mul(u64, @as(u64, phys_block), @as(u64, fs.sectors_per_block)) catch {
                return -5; // EIO (overflow)
            };
            fs.dev.readSectors(lba, fs.sectors_per_block, block_buf) catch {
                console.err("ext2: read inode {d} phys_block {d} lba {d}: readSectors failed", .{
                    file.inode_num, phys_block, lba,
                });
                return -5; // EIO
            };

            @memcpy(buf[read_count..][0..chunk], block_buf[byte_in_block..][0..chunk]);
        }

        read_count += chunk;
        pos += chunk;
    }

    file_desc.position += read_count;
    return std.math.cast(isize, read_count) orelse return -75; // EOVERFLOW
}

// ============================================================================
// ext2FileClose: release Ext2File private_data
// ============================================================================

fn ext2FileClose(file_desc: *fd.FileDescriptor) isize {
    if (file_desc.private_data) |ptr| {
        const file: *Ext2File = @ptrCast(@alignCast(ptr));
        heap.allocator().destroy(file);
        file_desc.private_data = null;
    }
    return 0;
}

// ============================================================================
// ext2FileSeek: update file position
// ============================================================================

fn ext2FileSeek(file_desc: *fd.FileDescriptor, offset: i64, whence: u32) isize {
    const file: *Ext2File = @ptrCast(@alignCast(file_desc.private_data.?));
    const size = file.size;

    const new_pos: i64 = switch (whence) {
        0 => offset, // SEEK_SET
        1 => blk: { // SEEK_CUR
            const cur = std.math.cast(i64, file_desc.position) orelse return -22; // EINVAL
            break :blk std.math.add(i64, cur, offset) catch return -22;
        },
        2 => blk: { // SEEK_END
            const sz = std.math.cast(i64, size) orelse return -22;
            break :blk std.math.add(i64, sz, offset) catch return -22;
        },
        else => return -22, // EINVAL: invalid whence
    };

    if (new_pos < 0) return -22; // EINVAL: negative position

    // Clamp to file size for seek-past-end: allowed but reads return EOF.
    file_desc.position = @intCast(new_pos);

    return std.math.cast(isize, new_pos) orelse return -75; // EOVERFLOW
}

// ============================================================================
// ext2FileStat: return file metadata
// ============================================================================

fn ext2FileStat(file_desc: *fd.FileDescriptor, stat_buf: *anyopaque) isize {
    const file: *Ext2File = @ptrCast(@alignCast(file_desc.private_data.?));
    const inode = &file.inode;

    // SECURITY: Always use std.mem.zeroes to zero-initialize Stat to prevent
    // information leaks from padding fields (__pad0, __unused).
    var st = std.mem.zeroes(uapi.stat.Stat);

    st.ino = @as(u64, file.inode_num);
    st.mode = @as(u32, inode.i_mode); // i_mode includes type bits + permissions
    st.nlink = @as(u64, inode.i_links_count);
    st.uid = @as(u32, inode.i_uid);
    st.gid = @as(u32, inode.i_gid);
    st.size = @intCast(inode.i_size);
    st.blksize = @intCast(file.fs.block_size);
    // i_blocks counts 512-byte units (not filesystem blocks) per ext2 spec.
    st.blocks = @intCast(inode.i_blocks);
    st.atime = @intCast(inode.i_atime);
    st.mtime = @intCast(inode.i_mtime);
    st.ctime = @intCast(inode.i_ctime);
    // atime_nsec/mtime_nsec/ctime_nsec remain 0 (ext2 has no sub-second timestamps).
    // dev/rdev remain 0 (Phase 47 does not expose device info).

    @memcpy(
        @as([*]u8, @ptrCast(stat_buf))[0..@sizeOf(uapi.stat.Stat)],
        std.mem.asBytes(&st),
    );

    return 0;
}

// ============================================================================
// lookupInRootDir: scan root directory (inode 2) for a filename
// ============================================================================

/// Scan the root directory inode (inode 2) for a matching filename.
///
/// This is a single-level lookup: it only searches root directory entries.
/// Full multi-level path traversal is Phase 48.
///
/// Returns the inode number on match, or error.NotFound if the name is not
/// present in the root directory.
pub fn lookupInRootDir(fs: *Ext2Fs, name: []const u8) Ext2Error!u32 {
    if (name.len == 0) return error.NotFound;
    if (name.len > 255) return error.NotFound; // ext2 name_len is u8

    // Read the root directory inode (inode 2 is always the root in ext2).
    const root_inode = try readInode(fs, types.ROOT_INODE);

    if (!root_inode.isDir()) {
        console.err("ext2: inode 2 is not a directory (mode=0x{X:0>4})", .{root_inode.i_mode});
        return error.NotFound;
    }

    // Iterate over all data blocks of the root directory inode.
    // For Phase 47, we only scan direct blocks (12 maximum = 48KB of entries).
    // A typical root directory fits in 1-2 blocks; 12 is more than enough.
    const ptrs_per_block: u32 = fs.block_size / 4;
    _ = ptrs_per_block;

    // Count blocks needed: ceil(i_size / block_size)
    const dir_blocks: u32 = if (root_inode.i_size == 0)
        0
    else
        (root_inode.i_size + fs.block_size - 1) / fs.block_size;

    // Heap-allocate one block buffer for directory entry parsing.
    const alloc = heap.allocator();
    const block_buf = alloc.alloc(u8, fs.block_size) catch return error.OutOfMemory;
    defer alloc.free(block_buf);

    var lb: u32 = 0;
    while (lb < dir_blocks) : (lb += 1) {
        const phys_block = try resolveBlock(fs, &root_inode, lb);
        if (phys_block == 0) continue; // sparse directory block (unlikely but handle)

        @memset(block_buf, 0); // DMA hygiene
        const lba = std.math.mul(u64, @as(u64, phys_block), @as(u64, fs.sectors_per_block)) catch {
            return error.IOError;
        };
        fs.dev.readSectors(lba, fs.sectors_per_block, block_buf) catch {
            console.err("ext2: lookupInRootDir: readSectors lba={d} failed", .{lba});
            return error.IOError;
        };

        // Walk directory entries within this block.
        var offset: u32 = 0;
        while (offset < fs.block_size) {
            // Ensure at least the 8-byte DirEntry header fits.
            if (offset + @sizeOf(types.DirEntry) > fs.block_size) break;

            const entry: *const types.DirEntry = @ptrCast(@alignCast(block_buf[offset..].ptr));

            // rec_len == 0 would loop forever; break to next block.
            if (entry.rec_len == 0) break;

            // inode == 0 means deleted/unused entry; skip.
            if (entry.inode != 0 and entry.name_len > 0) {
                // Name follows immediately after the 8-byte header.
                const entry_name_start = offset + @sizeOf(types.DirEntry);
                const entry_name_end = entry_name_start + @as(u32, entry.name_len);

                if (entry_name_end <= fs.block_size) {
                    const entry_name = block_buf[entry_name_start..entry_name_end];
                    if (std.mem.eql(u8, entry_name, name)) {
                        console.debug("ext2: found '{s}' -> inode {d}", .{ name, entry.inode });
                        return entry.inode;
                    }
                }
            }

            offset += entry.rec_len;
        }
    }

    console.debug("ext2: '{s}' not found in root directory", .{name});
    return error.NotFound;
}

// ============================================================================
// openInode: create a FileDescriptor for a given inode number
// ============================================================================

/// Open inode `inum` and return a new FileDescriptor.
///
/// Reads the inode, allocates an Ext2File on the heap, and creates a
/// FileDescriptor with ext2_file_ops. Uses errdefer to clean up on failure.
pub fn openInode(fs: *Ext2Fs, inum: u32, flags: u32) !*fd.FileDescriptor {
    const inode = try readInode(fs, inum);

    const alloc = heap.allocator();
    const file_ctx = try alloc.create(Ext2File);
    errdefer alloc.destroy(file_ctx);

    file_ctx.* = .{
        .fs = fs,
        .inode_num = inum,
        .inode = inode,
        .size = @as(u64, inode.i_size),
    };

    const file_desc = fd.createFd(&ext2_file_ops, flags, file_ctx) catch {
        return error.OutOfMemory;
    };

    return file_desc;
}

// ============================================================================
// Phase 48: Inode LRU Cache (INODE-05)
// ============================================================================

/// Number of entries in the fixed-size LRU inode cache.
/// 16 entries handles a typical path depth of a/b/c/d (5 inodes) with room
/// for parent inodes being re-read during concurrent getdents operations.
/// Size contribution to Ext2Fs: 16 * (4 + 128 + 8) = 2240 bytes (heap-allocated).
pub const INODE_CACHE_SIZE: usize = 16;

/// One slot in the inode LRU cache.
/// inum == 0 is the empty-slot sentinel (safe since ext2 inode numbering is 1-based).
pub const InodeCacheEntry = struct {
    inum: u32, // 0 = empty slot
    inode: types.Inode,
    lru_gen: u64, // higher = more recently used; 0 = never used
};

/// Return the inode for `inum`, using the LRU cache to avoid redundant disk reads.
///
/// Cache probe is O(INODE_CACHE_SIZE) = O(16) -- negligible for this use case.
/// On miss, calls readInode and evicts the oldest (lowest lru_gen) slot.
///
/// Security: inum == 0 returns error.InvalidInode (0 is the empty-slot sentinel).
pub fn getCachedInode(fs: *Ext2Fs, inum: u32) Ext2Error!types.Inode {
    if (inum == 0) return error.InvalidInode;

    // Linear probe: find cache hit or track oldest slot for eviction.
    var oldest_gen: u64 = std.math.maxInt(u64);
    var oldest_slot: usize = 0;

    for (&fs.inode_cache, 0..) |*entry, i| {
        if (entry.inum == inum) {
            // Cache hit: bump LRU generation and return cached inode.
            fs.inode_cache_gen += 1;
            entry.lru_gen = fs.inode_cache_gen;
            console.debug("ext2: inode cache HIT inum={d} gen={d}", .{ inum, entry.lru_gen });
            return entry.inode;
        }
        if (entry.lru_gen < oldest_gen) {
            oldest_gen = entry.lru_gen;
            oldest_slot = i;
        }
    }

    // Cache miss: read from disk, evict oldest slot.
    console.debug("ext2: inode cache MISS inum={d}, evicting slot {d} (inum={d})", .{
        inum, oldest_slot, fs.inode_cache[oldest_slot].inum,
    });
    const inode = try readInode(fs, inum);

    fs.inode_cache_gen += 1;
    fs.inode_cache[oldest_slot] = .{
        .inum = inum,
        .inode = inode,
        .lru_gen = fs.inode_cache_gen,
    };

    return inode;
}

// ============================================================================
// Phase 48: Generic Directory Scan (DIR-01)
// ============================================================================

/// Scan a directory inode for an entry with the given name.
///
/// This is a generalization of lookupInRootDir: it takes a pre-read directory
/// inode instead of always reading inode 2. Supports all indirection levels
/// via resolveBlock (Phase 47).
///
/// Returns the inode number of the matching entry, or error.NotFound.
///
/// CRITICAL: Always walks by entry.rec_len, never by computed name_len+8.
/// The last entry in each directory block has rec_len padded to the block end.
pub fn lookupInDir(fs: *Ext2Fs, dir_inode: *const types.Inode, name: []const u8) Ext2Error!u32 {
    if (!dir_inode.isDir()) return error.NotFound;
    if (name.len == 0 or name.len > 255) return error.NotFound;

    // Count blocks needed: ceil(i_size / block_size).
    const dir_blocks: u32 = if (dir_inode.i_size == 0)
        0
    else
        (dir_inode.i_size + fs.block_size - 1) / fs.block_size;

    // SECURITY: Heap-allocate block buffer -- 4KB on kernel stack overflows aarch64.
    const alloc = heap.allocator();
    const block_buf = alloc.alloc(u8, fs.block_size) catch return error.OutOfMemory;
    defer alloc.free(block_buf);

    var lb: u32 = 0;
    while (lb < dir_blocks) : (lb += 1) {
        const phys_block = try resolveBlock(fs, dir_inode, lb);
        if (phys_block == 0) continue; // sparse directory block (unusual but handle)

        @memset(block_buf, 0); // DMA hygiene
        const lba = std.math.mul(u64, @as(u64, phys_block), @as(u64, fs.sectors_per_block)) catch {
            return error.IOError;
        };
        fs.dev.readSectors(lba, fs.sectors_per_block, block_buf) catch {
            console.err("ext2: lookupInDir: readSectors lba={d} failed", .{lba});
            return error.IOError;
        };

        // Walk directory entries in this block by rec_len.
        var offset: u32 = 0;
        while (offset < fs.block_size) {
            // Ensure at least the 8-byte DirEntry header fits.
            if (offset + @sizeOf(types.DirEntry) > fs.block_size) break;

            const entry: *const types.DirEntry = @ptrCast(@alignCast(block_buf[offset..].ptr));

            // rec_len == 0 would loop forever: break to next block.
            if (entry.rec_len == 0) break;

            if (entry.inode != 0 and entry.name_len > 0) {
                const name_start = offset + @sizeOf(types.DirEntry);
                const name_end = name_start + @as(u32, entry.name_len);

                if (name_end <= fs.block_size) {
                    const entry_name = block_buf[name_start..name_end];
                    if (std.mem.eql(u8, entry_name, name)) {
                        console.debug("ext2: lookupInDir: found '{s}' -> inode {d}", .{ name, entry.inode });
                        return entry.inode;
                    }
                }
            }

            // CRITICAL: stride by rec_len, NOT by computed align(8+name_len, 4).
            offset += entry.rec_len;
        }
    }

    console.debug("ext2: lookupInDir: '{s}' not found", .{name});
    return error.NotFound;
}

// ============================================================================
// Phase 48: Multi-Component Path Resolution (DIR-01)
// ============================================================================

/// Resolve a multi-component path relative to the ext2 root directory.
///
/// Starts from ROOT_INODE (inode 2) and iterates lookupInDir for each
/// '/' separated component. Returns the inode number of the final component.
///
/// Returns ROOT_INODE for empty path (root itself).
///
/// NOTE: Does NOT follow symlinks during traversal (Phase 48 scope).
/// If an intermediate path component is a symlink, the next component's
/// isDir() check will fail with error.NotFound (symlinks are not directories).
/// Symlink following during traversal is a future enhancement.
///
/// Safety: Component count is limited to 255 to prevent infinite loops from
/// circular structures (no symlink following means no true loops, but limit
/// is cheap insurance).
pub fn resolvePath(fs: *Ext2Fs, path: []const u8) Ext2Error!u32 {
    var current_inum: u32 = types.ROOT_INODE;

    // Strip leading '/'.
    var remaining = path;
    if (remaining.len > 0 and remaining[0] == '/') {
        remaining = remaining[1..];
    }

    // Root itself.
    if (remaining.len == 0) return current_inum;

    // Walk each path component.
    var component_count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, remaining, '/');
    while (it.next()) |component| {
        if (component.len == 0) continue; // Skip empty components (double-slash)
        if (component.len > 255) return error.NotFound; // ext2 name_len is u8

        component_count += 1;
        if (component_count > 255) {
            console.err("ext2: resolvePath: path depth > 255 components", .{});
            return error.NotFound;
        }

        // Read the current directory inode (cached).
        const dir_inode = try getCachedInode(fs, current_inum);

        // Each intermediate component must be a directory.
        if (!dir_inode.isDir()) {
            console.debug("ext2: resolvePath: component '{s}': inode {d} is not a directory", .{
                component, current_inum,
            });
            return error.NotFound;
        }

        // Look up the next component in the current directory.
        current_inum = try lookupInDir(fs, &dir_inode, component);
    }

    return current_inum;
}

// ============================================================================
// Phase 48: Directory FD (Ext2DirFd) and FileOps (ext2_dir_ops) (DIR-02)
// ============================================================================

/// Private data for directory FileDescriptors opened on ext2 directories.
const Ext2DirFd = struct {
    /// Back-pointer to the mounted filesystem state.
    fs: *Ext2Fs,
    /// Inode number of the open directory.
    dir_inode_num: u32,
    /// Cached copy of the directory inode (read at open time).
    dir_inode: types.Inode,
};

/// FileOps vtable for ext2 directory FileDescriptors.
///
/// read/write/seek are null (directories are not read/seeked directly).
/// getdents is the primary operation for directory FDs.
pub const ext2_dir_ops = fd.FileOps{
    .read = null,
    .write = null,
    .close = ext2DirClose,
    .seek = null,
    .stat = ext2DirStat,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
    .getdents = ext2GetdentsFromFd,
    .chown = null,
};

/// Release the Ext2DirFd private data on FD close.
fn ext2DirClose(file_desc: *fd.FileDescriptor) isize {
    if (file_desc.private_data) |ptr| {
        const dir: *Ext2DirFd = @ptrCast(@alignCast(ptr));
        heap.allocator().destroy(dir);
        file_desc.private_data = null;
    }
    return 0;
}

/// Return stat metadata for an open directory FD.
fn ext2DirStat(file_desc: *fd.FileDescriptor, stat_buf: *anyopaque) isize {
    const dir: *Ext2DirFd = @ptrCast(@alignCast(file_desc.private_data.?));
    const inode = &dir.dir_inode;

    // SECURITY: Use std.mem.zeroes to prevent information leaks from padding fields.
    var st = std.mem.zeroes(uapi.stat.Stat);

    st.ino = @as(u64, dir.dir_inode_num);
    st.mode = @as(u32, inode.i_mode); // includes S_IFDIR type bits + permissions
    st.nlink = @as(u64, inode.i_links_count);
    st.uid = @as(u32, inode.i_uid);
    st.gid = @as(u32, inode.i_gid);
    st.size = @intCast(inode.i_size);
    st.blksize = @intCast(dir.fs.block_size);
    st.blocks = @intCast(inode.i_blocks); // 512-byte units per ext2 spec
    st.atime = @intCast(inode.i_atime);
    st.mtime = @intCast(inode.i_mtime);
    st.ctime = @intCast(inode.i_ctime);

    @memcpy(
        @as([*]u8, @ptrCast(stat_buf))[0..@sizeOf(uapi.stat.Stat)],
        std.mem.asBytes(&st),
    );

    return 0;
}

// ============================================================================
// Phase 48: getdents for ext2 directory FDs (DIR-02)
// ============================================================================

/// Read directory entries from an ext2 directory FD into a userspace buffer.
///
/// Uses file_desc.position as an absolute byte offset into the directory data.
/// Walks DirEntry records by rec_len (CRITICAL: never by computed name_len+8).
/// The last entry in each directory block has rec_len padded to the block end;
/// walking by computed size silently misses it.
///
/// Writes Dirent64 entries to the userspace buffer at `dirp`. The buffer is
/// validated by sys_getdents64 before this function is called.
///
/// Returns bytes written, or negative errno on error.
fn ext2GetdentsFromFd(file_desc: *fd.FileDescriptor, dirp: usize, count: usize) isize {
    const dir: *Ext2DirFd = @ptrCast(@alignCast(file_desc.private_data.?));
    const fs = dir.fs;
    const dir_inode = &dir.dir_inode;

    // Use absolute byte offset in directory data as position.
    var abs_offset: u64 = file_desc.position;
    const dir_size: u64 = @as(u64, dir_inode.i_size);

    if (abs_offset >= dir_size) return 0; // EOF

    // SECURITY: Heap-allocate block buffer (4KB on kernel stack overflows aarch64).
    const alloc = heap.allocator();
    const block_buf = alloc.alloc(u8, fs.block_size) catch return -12; // ENOMEM
    defer alloc.free(block_buf);

    // Userspace buffer pointer (validated by sys_getdents64 caller).
    const user_buf: [*]volatile u8 = @ptrFromInt(dirp);
    var bytes_written: usize = 0;

    while (abs_offset < dir_size) {
        // Compute which directory block covers the current absolute byte offset.
        const logical_block: u32 = @intCast(abs_offset / fs.block_size);
        const byte_in_block: u32 = @intCast(abs_offset % fs.block_size);

        const phys_block = resolveBlock(fs, dir_inode, logical_block) catch return -5; // EIO
        if (phys_block == 0) {
            // Sparse directory block: advance past it.
            abs_offset = (@as(u64, logical_block) + 1) * fs.block_size;
            continue;
        }

        @memset(block_buf, 0); // DMA hygiene
        const lba = std.math.mul(u64, @as(u64, phys_block), @as(u64, fs.sectors_per_block)) catch {
            return -5; // EIO (overflow)
        };
        fs.dev.readSectors(lba, fs.sectors_per_block, block_buf) catch {
            console.err("ext2: getdents: readSectors lba={d} failed", .{lba});
            return -5; // EIO
        };

        // Walk entries in this block starting at byte_in_block.
        var block_offset: u32 = byte_in_block;
        while (block_offset < fs.block_size) {
            // Ensure at least the 8-byte DirEntry header fits.
            if (block_offset + @sizeOf(types.DirEntry) > fs.block_size) break;

            const entry: *const types.DirEntry = @ptrCast(@alignCast(block_buf[block_offset..].ptr));

            // rec_len == 0: corrupt or end-of-block sentinel.
            if (entry.rec_len == 0) break;

            const next_block_offset = block_offset + entry.rec_len;

            if (entry.inode != 0 and entry.name_len > 0) {
                const name_start: u32 = block_offset + @sizeOf(types.DirEntry);
                const name_len: usize = @as(usize, entry.name_len);
                const name_end: u32 = name_start + @as(u32, @intCast(name_len));

                if (name_end <= fs.block_size) {
                    const name = block_buf[name_start..name_end];

                    // Compute output Dirent64 size: header + name + null + 8-byte align.
                    const d_reclen_raw = @sizeOf(uapi.dirent.Dirent64) + name_len + 1;
                    const aligned_reclen = std.mem.alignForward(usize, d_reclen_raw, 8);

                    if (bytes_written + aligned_reclen > count) {
                        // Buffer full: stop before this entry, preserve position.
                        // Position points to the start of this entry in directory data.
                        const entry_abs_pos = (@as(u64, logical_block) * fs.block_size) +
                            @as(u64, block_offset);
                        file_desc.position = entry_abs_pos;
                        return std.math.cast(isize, bytes_written) orelse -75; // EOVERFLOW
                    }

                    // Map ext2 file_type to POSIX DT_* constants.
                    const d_type: u8 = switch (entry.file_type) {
                        types.FT_REG_FILE => uapi.dirent.DT_REG,
                        types.FT_DIR => uapi.dirent.DT_DIR,
                        types.FT_SYMLINK => uapi.dirent.DT_LNK,
                        types.FT_CHRDEV => uapi.dirent.DT_CHR,
                        types.FT_BLKDEV => uapi.dirent.DT_BLK,
                        types.FT_FIFO => uapi.dirent.DT_FIFO,
                        types.FT_SOCK => uapi.dirent.DT_SOCK,
                        else => uapi.dirent.DT_UNKNOWN,
                    };

                    // d_off: cookie pointing to the next entry (absolute byte offset).
                    const next_entry_abs: u64 = (@as(u64, logical_block) * fs.block_size) +
                        @as(u64, next_block_offset);

                    const ent = uapi.dirent.Dirent64{
                        .d_ino = @as(u64, entry.inode),
                        .d_off = @intCast(next_entry_abs),
                        .d_reclen = @intCast(aligned_reclen),
                        .d_type = d_type,
                        .d_name = undefined,
                    };

                    // Write Dirent64 header (excluding the zero-length d_name field).
                    const ent_bytes = std.mem.asBytes(&ent);
                    for (ent_bytes, 0..) |byte, j| user_buf[bytes_written + j] = byte;

                    // Write filename bytes after the header.
                    const name_offset_in_output = bytes_written + @offsetOf(uapi.dirent.Dirent64, "d_name");
                    for (name, 0..) |byte, j| user_buf[name_offset_in_output + j] = byte;
                    // Null terminator after the name.
                    user_buf[name_offset_in_output + name_len] = 0;

                    bytes_written += aligned_reclen;
                }
            }

            // CRITICAL: stride by rec_len. The last entry in each block has
            // rec_len padded to fill remaining block space (not align(8+name_len,4)).
            block_offset = next_block_offset;
        }

        // Advance to the next directory block.
        abs_offset = (@as(u64, logical_block) + 1) * fs.block_size;
    }

    file_desc.position = abs_offset;
    return std.math.cast(isize, bytes_written) orelse -75; // EOVERFLOW
}

// ============================================================================
// Phase 48: openDirInode -- open a directory inode as a directory FD
// ============================================================================

/// Open directory inode `inum` and return a new FileDescriptor with ext2_dir_ops.
///
/// Reads the inode via getCachedInode, verifies it is a directory, allocates
/// an Ext2DirFd on the heap, and creates a FileDescriptor.
/// Uses errdefer for cleanup on failure.
pub fn openDirInode(fs: *Ext2Fs, inum: u32, flags: u32) Ext2Error!*fd.FileDescriptor {
    const inode = try getCachedInode(fs, inum);

    if (!inode.isDir()) {
        console.err("ext2: openDirInode: inode {d} is not a directory (mode=0x{X:0>4})", .{
            inum, inode.i_mode,
        });
        return error.NotFound;
    }

    const alloc = heap.allocator();
    const dir_ctx = try alloc.create(Ext2DirFd);
    errdefer alloc.destroy(dir_ctx);

    dir_ctx.* = .{
        .fs = fs,
        .dir_inode_num = inum,
        .dir_inode = inode,
    };

    const file_desc = fd.createFd(&ext2_dir_ops, flags, dir_ctx) catch {
        return error.OutOfMemory;
    };

    return file_desc;
}
