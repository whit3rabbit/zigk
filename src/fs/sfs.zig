//! Simple File System (SFS)
//!
//! A minimal read/write filesystem for block devices (e.g., AHCI SATA drives).
//!
//! Structure:
//! - Block 0: Superblock (Magic, size, file count, next free block).
//! - Block 1-N: Root Directory (Fixed size, flat list of `DirEntry`s).
//! - Block N+1...: Data Blocks (Contiguous allocation).
//!
//! Limitations:
//! - Flat directory structure (no subdirectories).
//! - Contiguous file allocation (prone to fragmentation, simplifies read/write).
//! - Fixed number of files (determined by root directory size).
//! - No permissions/ownership storage.
//!
//! Intended for basic persistence until a full FS (EXT2/FAT) is implemented.

const std = @import("std");
const fd = @import("fd");
const heap = @import("heap");
const vfs = @import("vfs.zig");
const uapi = @import("uapi");
const console = @import("console"); // Assuming console is available via build options or we need to add import
const sync = @import("sync");

// Magic: "SFS2" (version 2 with bitmap allocation)
const SFS_MAGIC: u32 = 0x32534653;
const SFS_VERSION: u32 = 2;
const SECTOR_SIZE: u32 = 512;
const MAX_FILES: u32 = 64;
const ROOT_DIR_BLOCKS: u32 = (MAX_FILES * @sizeOf(DirEntry) + SECTOR_SIZE - 1) / SECTOR_SIZE;

// Bitmap configuration: Each bitmap block tracks 512*8 = 4096 blocks
const BITS_PER_BLOCK: u32 = SECTOR_SIZE * 8;
const BITMAP_BLOCKS: u32 = 4; // Supports up to 16384 blocks (8MB with 512B sectors)
const DATA_START_BLOCK: u32 = 1 + BITMAP_BLOCKS + ROOT_DIR_BLOCKS;

const Superblock = extern struct {
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

const DirEntry = extern struct {
    name: [32]u8,
    start_block: u32,
    size: u32,
    flags: u32, // 1 = Active
    _pad: [128 - 44]u8, // Pad to 128 bytes
};

pub const SFS = struct {
    device_fd: *fd.FileDescriptor,
    superblock: Superblock,
    /// Lock protecting superblock updates (prevents TOCTOU in file growth)
    alloc_lock: sync.Spinlock = .{},

    /// Initialize SFS on a device
    /// Opens the device, checks magic, formats if needed.
    pub fn init(device_path: []const u8) !vfs.FileSystem {
        // Open block device
        const device_fd = try vfs.Vfs.open(device_path, fd.O_RDWR);

        const alloc = heap.allocator();
        const self = try alloc.create(SFS);
        self.device_fd = device_fd;

        // Read superblock
        var buf: [512]u8 = undefined;
        _ = try readSector(device_fd, 0, &buf);

        const sb: *Superblock = @ptrCast(@alignCast(&buf));
        if (sb.magic != SFS_MAGIC or sb.version != SFS_VERSION) {
            console.warn("SFS: Invalid magic or old version, formatting...", .{});
            try self.format();
        } else {
            self.superblock = sb.*;
            console.info("SFS: Mounted. Files: {}, Free Blocks: {}", .{
                self.superblock.file_count,
                self.superblock.free_blocks,
            });
        }

        return vfs.FileSystem{
            .context = self,
            .open = sfsOpen,
            .unmount = sfsUnmount,
            .unlink = null, // TODO: implement sfsUnlink
        };
    }

    fn format(self: *SFS) !void {
        // Calculate total blocks (assume 16MB disk)
        const total_blocks: u32 = 32768; // 16MB / 512B per sector

        // Initialize superblock with bitmap layout
        self.superblock = Superblock{
            .magic = SFS_MAGIC,
            .version = SFS_VERSION,
            .block_size = SECTOR_SIZE,
            .total_blocks = total_blocks,
            .file_count = 0,
            .free_blocks = total_blocks - DATA_START_BLOCK,
            .bitmap_start = 1,
            .bitmap_blocks = BITMAP_BLOCKS,
            .root_dir_start = 1 + BITMAP_BLOCKS,
            .data_start = DATA_START_BLOCK,
            .next_free_block = DATA_START_BLOCK,
            ._pad = undefined,
        };

        // Write superblock
        try writeSector(self.device_fd, 0, std.mem.asBytes(&self.superblock));

        // Clear bitmap blocks (all zeros = all free)
        const zero_buf = [_]u8{0} ** 512;
        var i: u32 = 0;
        while (i < BITMAP_BLOCKS) : (i += 1) {
            try writeSector(self.device_fd, 1 + i, &zero_buf);
        }

        // Clear root directory blocks
        i = 0;
        while (i < ROOT_DIR_BLOCKS) : (i += 1) {
            try writeSector(self.device_fd, self.superblock.root_dir_start + i, &zero_buf);
        }
    }

    fn updateSuperblock(self: *SFS) !void {
        try writeSector(self.device_fd, 0, std.mem.asBytes(&self.superblock));
    }

    /// Allocate a free block from the bitmap
    /// Returns block number or error if disk is full
    pub fn allocateBlock(self: *SFS) !u32 {
        const held = self.alloc_lock.acquire();
        defer held.release();

        // Scan bitmap blocks for a free bit
        var bitmap_block: u32 = 0;
        while (bitmap_block < self.superblock.bitmap_blocks) : (bitmap_block += 1) {
            var buf: [512]u8 = undefined;
            readSector(self.device_fd, self.superblock.bitmap_start + bitmap_block, &buf) catch return error.IOError;

            // Scan bytes in this bitmap block
            for (&buf, 0..) |*byte_ptr, byte_idx| {
                const byte = byte_ptr.*;
                if (byte != 0xFF) {
                    // Found a byte with at least one free bit
                    var bit: u3 = 0;
                    while (bit < 8) : (bit += 1) {
                        if ((byte & (@as(u8, 1) << bit)) == 0) {
                            // Found free bit - mark as allocated
                            buf[byte_idx] |= (@as(u8, 1) << bit);
                            writeSector(self.device_fd, self.superblock.bitmap_start + bitmap_block, &buf) catch return error.IOError;

                            // Calculate absolute block number with overflow checking
                            const bitmap_offset = std.math.mul(u32, bitmap_block, BITS_PER_BLOCK) catch return error.IOError;
                            const byte_offset = std.math.mul(u32, @as(u32, @intCast(byte_idx)), 8) catch return error.IOError;
                            const bit_offset = std.math.add(u32, byte_offset, bit) catch return error.IOError;
                            const total_offset = std.math.add(u32, bitmap_offset, bit_offset) catch return error.IOError;
                            const block_num = std.math.add(u32, self.superblock.data_start, total_offset) catch return error.IOError;

                            // Update superblock free count
                            if (self.superblock.free_blocks > 0) {
                                self.superblock.free_blocks -= 1;
                            }
                            self.updateSuperblock() catch return error.IOError;

                            return block_num;
                        }
                    }
                }
            }
        }

        return error.ENOSPC; // No free blocks
    }

    /// Free a block back to the bitmap
    pub fn freeBlock(self: *SFS, block_num: u32) !void {
        if (block_num < self.superblock.data_start) return error.InvalidBlock;

        const held = self.alloc_lock.acquire();
        defer held.release();

        // Calculate bitmap position
        const relative_block = block_num - self.superblock.data_start;
        const bitmap_block_idx = relative_block / BITS_PER_BLOCK;
        const byte_idx = (relative_block % BITS_PER_BLOCK) / 8;
        const bit_idx: u3 = @intCast(relative_block % 8);

        if (bitmap_block_idx >= self.superblock.bitmap_blocks) return error.InvalidBlock;

        // Read bitmap block
        var buf: [512]u8 = undefined;
        readSector(self.device_fd, self.superblock.bitmap_start + bitmap_block_idx, &buf) catch return error.IOError;

        // Check if already free (double-free detection)
        if ((buf[byte_idx] & (@as(u8, 1) << bit_idx)) == 0) {
            console.warn("SFS: Double-free detected for block {}", .{block_num});
            return;
        }

        // Clear bit
        buf[byte_idx] &= ~(@as(u8, 1) << bit_idx);
        writeSector(self.device_fd, self.superblock.bitmap_start + bitmap_block_idx, &buf) catch return error.IOError;

        // Update superblock
        self.superblock.free_blocks += 1;
        self.updateSuperblock() catch return error.IOError;
    }

    /// Free multiple contiguous blocks
    pub fn freeBlocks(self: *SFS, start_block: u32, count: u32) void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            self.freeBlock(start_block + i) catch |err| {
                console.warn("SFS: Failed to free block {}: {}", .{ start_block + i, err });
            };
        }
    }

    const SfsError = error{
        IOError,
        InvalidBlock,
        ENOSPC,
    };
};

// Helper wrappers
fn readSector(device: *fd.FileDescriptor, lba: u32, buf: []u8) !void {
    // Seek to sector
    const offset: i64 = @as(i64, lba) * 512;
    if (device.ops.seek) |seek_fn| {
        _ = seek_fn(device, offset, 0); // SEEK_SET
    } else {
        return error.IOError;
    }

    // Read
    if (device.ops.read) |read_fn| {
        const res = read_fn(device, buf);
        if (res != buf.len) return error.IOError;
    } else {
        return error.IOError;
    }
}

fn writeSector(device: *fd.FileDescriptor, lba: u32, buf: []const u8) !void {
    const offset: i64 = @as(i64, lba) * 512;
    if (device.ops.seek) |seek_fn| {
        _ = seek_fn(device, offset, 0);
    } else {
        return error.IOError;
    }

    if (device.ops.write) |write_fn| {
        const res = write_fn(device, buf);
        if (res != buf.len) return error.IOError;
    } else {
        return error.IOError;
    }
}

// VFS Operations

fn sfsUnmount(ctx: ?*anyopaque) void {
    if (ctx) |ptr| {
        const self: *SFS = @ptrCast(@alignCast(ptr));
        // Close device FD?
        // Since VFS opened it, maybe VFS should close it?
        // But we opened it in init().
        if (self.device_fd.ops.close) |close_fn| {
            _ = close_fn(self.device_fd);
        }
        heap.allocator().destroy(self);
    }
}

fn sfsOpen(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd.FileDescriptor {
    const self: *SFS = @ptrCast(@alignCast(ctx));
    const alloc = heap.allocator();

    // Normalize path (remove leading /)
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    // Security: Reject path traversal attempts
    if (std.mem.indexOf(u8, name, "..")) |_| {
        return vfs.Error.AccessDenied;
    }

    if (name.len == 0 or std.mem.eql(u8, name, ".")) {
        // Root directory - not supported as file yet
        return vfs.Error.IsDirectory;
    }

    if (name.len >= 32) return vfs.Error.NameTooLong;

    // Search for file in root directory
    var entry_idx: ?u32 = null;
    var free_idx: ?u32 = null;
    var entry: DirEntry = undefined;

    // Read directory blocks
    var block: u32 = 0;
    while (block < ROOT_DIR_BLOCKS) : (block += 1) {
        var buf: [512]u8 = undefined;
        readSector(self.device_fd, self.superblock.root_dir_start + block, &buf) catch return vfs.Error.IOError;

        // Iterate entries in block (4 entries per 512 byte block, 128 bytes each)
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const offset = i * 128;
            const e: *DirEntry = @ptrCast(@alignCast(&buf[offset]));

            if (e.flags == 1) {
                // Active entry, check name
                const e_name = std.mem.sliceTo(&e.name, 0);
                if (std.mem.eql(u8, e_name, name)) {
                    entry_idx = block * 4 + i;
                    entry = e.*;
                    break;
                }
            } else {
                if (free_idx == null) {
                    free_idx = block * 4 + i;
                }
            }
        }
        if (entry_idx != null) break;
    }

    if (entry_idx) |idx| {
        // File found - use idx for entry tracking
        // Create FD
        const file_ctx = alloc.create(SfsFile) catch return vfs.Error.NoMemory;
        file_ctx.* = .{
            .fs = self,
            .start_block = entry.start_block,
            .size = entry.size,
            .entry_idx = idx,
        };

        return fd.createFd(&sfs_ops, flags, file_ctx) catch return vfs.Error.NoMemory;
    } else {
        // Not found. Create if O_CREAT?
        if ((flags & fd.O_CREAT) != 0) {
            if (self.superblock.file_count >= MAX_FILES) return vfs.Error.NoMemory; // Disk full (inodes)
            const idx = free_idx orelse return vfs.Error.NoMemory;

            // Allocate first block for new file using bitmap
            const start_block = self.allocateBlock() catch return vfs.Error.NoMemory;

            var new_entry = DirEntry{
                .name = [_]u8{0} ** 32,
                .start_block = start_block,
                .size = 0,
                .flags = 1,
                ._pad = undefined,
            };
            @memcpy(new_entry.name[0..name.len], name);

            // Write entry to disk
            const block_idx = idx / 4;
            const offset_idx = idx % 4;

            var buf: [512]u8 = undefined;
            readSector(self.device_fd, self.superblock.root_dir_start + block_idx, &buf) catch return vfs.Error.IOError;

            const dest: *DirEntry = @ptrCast(@alignCast(&buf[offset_idx * 128]));
            dest.* = new_entry;

            writeSector(self.device_fd, self.superblock.root_dir_start + block_idx, &buf) catch return vfs.Error.IOError;

            self.superblock.file_count += 1;
            self.updateSuperblock() catch return vfs.Error.IOError;

            const file_ctx = alloc.create(SfsFile) catch return vfs.Error.NoMemory;
            file_ctx.* = .{
                .fs = self,
                .start_block = new_entry.start_block,
                .size = 0,
                .entry_idx = idx,
            };

            return fd.createFd(&sfs_ops, flags, file_ctx) catch return vfs.Error.NoMemory;
        }

        return vfs.Error.NotFound;
    }
}

const SfsFile = struct {
    fs: *SFS,
    start_block: u32,
    size: u32,
    entry_idx: u32,
};

const sfs_ops = fd.FileOps{
    .read = sfsRead,
    .write = sfsWrite,
    .close = sfsClose,
    .seek = sfsSeek,
    .stat = sfsStat,
    .ioctl = null,
    .mmap = null,
    .poll = null,
};

fn sfsRead(file_desc: *fd.FileDescriptor, buf: []u8) isize {
    const file: *SfsFile = @ptrCast(@alignCast(file_desc.private_data));

    if (file_desc.position >= file.size) return 0;

    const remaining = file.size - file_desc.position;
    const to_read = @min(buf.len, remaining);

    var read_count: usize = 0;
    var current_pos = file_desc.position;

    while (read_count < to_read) {
        const rel_pos = current_pos; // Relative to file start
        const block_offset = rel_pos / 512;
        const byte_offset = rel_pos % 512;

        // Safe cast: block_offset bounded by file size which is u32
        const block_offset_u32 = std.math.cast(u32, block_offset) orelse return -5; // EIO
        const phys_block = file.start_block + block_offset_u32;

        var sector_buf: [512]u8 = undefined;
        readSector(file.fs.device_fd, phys_block, &sector_buf) catch return -5; // EIO

        const chunk = @min(to_read - read_count, 512 - byte_offset);
        @memcpy(buf[read_count..][0..chunk], sector_buf[byte_offset..][0..chunk]);

        read_count += chunk;
        current_pos += chunk;
    }

    file_desc.position += read_count;
    return std.math.cast(isize, read_count) orelse return -75; // EOVERFLOW
}

fn sfsWrite(file_desc: *fd.FileDescriptor, buf: []const u8) isize {
    const file: *SfsFile = @ptrCast(@alignCast(file_desc.private_data));

    // Contiguous allocation check: do we have enough blocks allocated?
    // Current allocated size is rounded up to block size.
    // If we write past end, we might need to allocate more blocks.
    // Since we use contiguous allocation from next_free_block, we can only grow
    // if we are the last file allocated OR we just reserve a huge chunk?
    // For "Simple FS", let's assume we can always append if we update next_free_block.
    // BUT, if another file was allocated after us, we can't grow contiguously without moving.
    // LIMITATION: Only support appending to the LAST allocated file, or if file was pre-allocated?
    // Or simpler: New files get allocated at `next_free_block`.
    // If we write to an existing file that is NOT at the end, we are stuck if we need to grow.
    // Let's implement: Can only grow if (start_block + current_blocks) == next_free_block.
    // Otherwise, EnOSPC (No space/fragmentation).

    // Calculate current blocks used (preliminary check before lock)
    const prelim_current_blocks = (file.size + 511) / 512;

    const new_size_needed = file_desc.position + buf.len;
    const new_blocks_needed = (new_size_needed + 511) / 512;

    if (new_blocks_needed > prelim_current_blocks) {
        // Need to grow - acquire lock to prevent TOCTOU race on superblock
        const held = file.fs.alloc_lock.acquire();
        defer held.release();

        // SECURITY: Recalculate under lock to prevent TOCTOU race
        // Another thread may have modified file.size between our check and lock acquisition
        const current_blocks = (file.size + 511) / 512;
        const end_block = file.start_block + current_blocks;

        // Re-check if we still need to grow after recalculation
        if (new_blocks_needed > current_blocks) {
            // Still need to grow - check if we can
            if (end_block != file.fs.superblock.next_free_block) {
                // Not at end of disk allocation
                // If file size is 0 (new file), it IS at next_free_block (set in open).
                if (file.size != 0) {
                    console.warn("SFS: Cannot grow file not at end of allocation", .{});
                    return -28; // ENOSPC
                }
            }

            // Update superblock free pointer atomically with the check
            const blocks_to_add = std.math.cast(u32, new_blocks_needed - current_blocks) orelse return -28; // ENOSPC
            file.fs.superblock.next_free_block += blocks_to_add;
            file.fs.updateSuperblock() catch return -5;
        }
        // else: Another thread already grew the file, no action needed
    }

    var written_count: usize = 0;
    var current_pos = file_desc.position;

    while (written_count < buf.len) {
        const rel_pos = current_pos;
        const block_offset = rel_pos / 512;
        const byte_offset = rel_pos % 512;

        // Safe cast: block_offset bounded by file size
        const block_offset_u32 = std.math.cast(u32, block_offset) orelse return -5; // EIO
        const phys_block = file.start_block + block_offset_u32;

        var sector_buf: [512]u8 = undefined;
        // Read-modify-write
        readSector(file.fs.device_fd, phys_block, &sector_buf) catch {
            // If reading failed (maybe uninitialized block), zero it
            @memset(&sector_buf, 0);
        };

        const chunk = @min(buf.len - written_count, 512 - byte_offset);
        @memcpy(sector_buf[byte_offset..][0..chunk], buf[written_count..][0..chunk]);

        writeSector(file.fs.device_fd, phys_block, &sector_buf) catch return -5;

        written_count += chunk;
        current_pos += chunk;
    }

    file_desc.position += written_count;
    if (file_desc.position > file.size) {
        // Safe cast: file.size is u32, position could exceed u32 max
        file.size = std.math.cast(u32, file_desc.position) orelse return -27; // EFBIG

        // Update directory entry size
        const block_idx = file.entry_idx / 4;
        const offset_idx = file.entry_idx % 4;

        var dir_buf: [512]u8 = undefined;
        readSector(file.fs.device_fd, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch {};

        const entry: *DirEntry = @ptrCast(@alignCast(&dir_buf[offset_idx * 128]));
        entry.size = file.size;

        writeSector(file.fs.device_fd, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch {};
    }

    return std.math.cast(isize, written_count) orelse return -75; // EOVERFLOW
}

fn sfsClose(file_desc: *fd.FileDescriptor) isize {
    const alloc = heap.allocator();
    const file: *SfsFile = @ptrCast(@alignCast(file_desc.private_data));
    alloc.destroy(file);
    return 0;
}

fn sfsSeek(file_desc: *fd.FileDescriptor, offset: i64, whence: u32) isize {
    const file: *SfsFile = @ptrCast(@alignCast(file_desc.private_data));
    // Safe casts: file.size is u32, position is usize - both fit in i64
    const size: i64 = @intCast(file.size);
    const current = std.math.cast(i64, file_desc.position) orelse return -75; // EOVERFLOW

    const new_pos: i64 = switch (whence) {
        0 => offset,
        1 => current + offset,
        2 => size + offset,
        else => return -22, // EINVAL
    };

    if (new_pos < 0) return -22;

    file_desc.position = std.math.cast(usize, new_pos) orelse return -75; // EOVERFLOW
    return std.math.cast(isize, new_pos) orelse return -75; // EOVERFLOW
}

fn sfsStat(file_desc: *fd.FileDescriptor, stat_buf: *anyopaque) isize {
    const file: *SfsFile = @ptrCast(@alignCast(file_desc.private_data));
    const stat: *uapi.stat.Stat = @ptrCast(@alignCast(stat_buf));

    stat.* = .{
        .dev = 0,
        .ino = file.entry_idx,
        .nlink = 1,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .rdev = 0,
        .size = @intCast(file.size),
        .blksize = 512,
        .blocks = @intCast((file.size + 511) / 512),
        .atime = 0,
        .atime_nsec = 0,
        .mtime = 0,
        .mtime_nsec = 0,
        .ctime = 0,
        .ctime_nsec = 0,
        .__pad0 = 0,
        .__unused = [_]i64{0} ** 3,
    };
    return 0;
}

/// Unlink (delete) a file from SFS
fn sfsUnlink(ctx: ?*anyopaque, path: []const u8) vfs.Error!void {
    const self: *SFS = @ptrCast(@alignCast(ctx));

    // Normalize path (remove leading /)
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    // Security: Reject path traversal attempts
    if (std.mem.indexOf(u8, name, "..")) |_| {
        return vfs.Error.AccessDenied;
    }

    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    // Find file in directory
    var block: u32 = 0;
    while (block < ROOT_DIR_BLOCKS) : (block += 1) {
        var buf: [512]u8 = undefined;
        readSector(self.device_fd, self.superblock.root_dir_start + block, &buf) catch return vfs.Error.IOError;

        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const offset = i * 128;
            const e: *DirEntry = @ptrCast(@alignCast(&buf[offset]));

            if (e.flags == 1) {
                const e_name = std.mem.sliceTo(&e.name, 0);
                if (std.mem.eql(u8, e_name, name)) {
                    // Found the file - free its blocks
                    const blocks_used = (e.size + 511) / 512;
                    if (blocks_used > 0) {
                        self.freeBlocks(e.start_block, blocks_used);
                    }

                    // Clear directory entry
                    e.flags = 0;
                    e.name = [_]u8{0} ** 32;
                    e.start_block = 0;
                    e.size = 0;

                    // Write back directory block
                    writeSector(self.device_fd, self.superblock.root_dir_start + block, &buf) catch return vfs.Error.IOError;

                    // Update file count
                    if (self.superblock.file_count > 0) {
                        self.superblock.file_count -= 1;
                    }
                    self.updateSuperblock() catch return vfs.Error.IOError;

                    console.info("SFS: Unlinked '{s}'", .{name});
                    return;
                }
            }
        }
    }

    return vfs.Error.NotFound;
}
