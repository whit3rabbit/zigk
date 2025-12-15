// Simple File System (SFS)
//
// A minimal read/write filesystem for block devices.
// Structure:
//   Block 0: Superblock
//   Block 1-N: Root Directory (Fixed size)
//   Block N+1...: Data Blocks (Contiguous allocation)
//
// Limitations:
//   - Flat directory structure (no subdirectories)
//   - Contiguous file allocation (fragmentation issues, but simple)
//   - Fixed number of files (determined by root dir size)
//   - No permissions/ownership storage

const std = @import("std");
const fd = @import("fd");
const heap = @import("heap");
const vfs = @import("vfs.zig");
const uapi = @import("uapi");
const console = @import("console"); // Assuming console is available via build options or we need to add import

// Magic: "SFS1"
const SFS_MAGIC: u32 = 0x31534653;
const SECTOR_SIZE: u32 = 512;
const MAX_FILES: u32 = 64;
const ROOT_DIR_BLOCKS: u32 = (MAX_FILES * @sizeOf(DirEntry) + SECTOR_SIZE - 1) / SECTOR_SIZE;
const DATA_START_BLOCK: u32 = 1 + ROOT_DIR_BLOCKS;

const Superblock = extern struct {
    magic: u32,
    block_size: u32,
    file_count: u32,
    next_free_block: u32,
    _pad: [512 - 16]u8,
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
        if (sb.magic != SFS_MAGIC) {
            console.warn("SFS: Invalid magic, formatting...", .{});
            try self.format();
        } else {
            self.superblock = sb.*;
            console.info("SFS: Mounted. Files: {}, Free Block: {}", .{
                self.superblock.file_count,
                self.superblock.next_free_block,
            });
        }

        return vfs.FileSystem{
            .context = self,
            .open = sfsOpen,
            .unmount = sfsUnmount,
        };
    }

    fn format(self: *SFS) !void {
        // Initialize superblock
        self.superblock = Superblock{
            .magic = SFS_MAGIC,
            .block_size = SECTOR_SIZE,
            .file_count = 0,
            .next_free_block = DATA_START_BLOCK,
            ._pad = undefined,
        };

        // Write superblock
        try writeSector(self.device_fd, 0, std.mem.asBytes(&self.superblock));

        // Clear root directory blocks
        const zero_buf = [_]u8{0} ** 512;
        var i: u32 = 0;
        while (i < ROOT_DIR_BLOCKS) : (i += 1) {
            try writeSector(self.device_fd, 1 + i, &zero_buf);
        }
    }

    fn updateSuperblock(self: *SFS) !void {
        try writeSector(self.device_fd, 0, std.mem.asBytes(&self.superblock));
    }
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
        readSector(self.device_fd, 1 + block, &buf) catch return vfs.Error.IOError;

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

            // Allocate entry
            var new_entry = DirEntry{
                .name = [_]u8{0} ** 32,
                .start_block = self.superblock.next_free_block, // Optimistic allocation
                .size = 0,
                .flags = 1,
                ._pad = undefined,
            };
            @memcpy(new_entry.name[0..name.len], name);

            // Write entry to disk
            const block_idx = idx / 4;
            const offset_idx = idx % 4;

            var buf: [512]u8 = undefined;
            readSector(self.device_fd, 1 + block_idx, &buf) catch return vfs.Error.IOError;

            const dest: *DirEntry = @ptrCast(@alignCast(&buf[offset_idx * 128]));
            dest.* = new_entry;

            writeSector(self.device_fd, 1 + block_idx, &buf) catch return vfs.Error.IOError;

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

    // Calculate current blocks used
    const current_blocks = (file.size + 511) / 512;
    const end_block = file.start_block + current_blocks;

    const new_size_needed = file_desc.position + buf.len;
    const new_blocks_needed = (new_size_needed + 511) / 512;

    if (new_blocks_needed > current_blocks) {
        // Need to grow
        if (end_block != file.fs.superblock.next_free_block) {
            // Not at end of disk allocation
            // If file size is 0 (new file), it IS at next_free_block (set in open).
            if (file.size == 0) {
                 // It is at next_free_block
            } else {
                 console.warn("SFS: Cannot grow file not at end of allocation", .{});
                 return -28; // ENOSPC
            }
        }

        // Update superblock free pointer
        const blocks_to_add = std.math.cast(u32, new_blocks_needed - current_blocks) orelse return -28; // ENOSPC
        file.fs.superblock.next_free_block += blocks_to_add;
        file.fs.updateSuperblock() catch return -5;
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
        readSector(file.fs.device_fd, 1 + block_idx, &dir_buf) catch {};

        const entry: *DirEntry = @ptrCast(@alignCast(&dir_buf[offset_idx * 128]));
        entry.size = file.size;

        writeSector(file.fs.device_fd, 1 + block_idx, &dir_buf) catch {};
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
