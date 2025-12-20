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
const meta = @import("fs_meta");

const uapi = @import("uapi");
const console = @import("console");
const sync = @import("sync");

// Async I/O imports
const ahci = @import("ahci");
const io = @import("io");
const pmm = @import("pmm");

// Magic: "SFS3" (version 3 with permissions)
const SFS_MAGIC: u32 = 0x33534653;
const SFS_VERSION: u32 = 3;
// Previous version for read-only compatibility
const SFS_VERSION_2: u32 = 2;
const SFS_MAGIC_V2: u32 = 0x32534653;
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

/// Sync I/O error type for sector operations
const SectorError = error{IOError};

/// Read a single sector using async AHCI I/O (sync-over-async pattern)
/// Extracts port_num from device_fd.private_data and uses IRQ-driven completion
fn readSector(device_fd: *fd.FileDescriptor, lba: u32, buf: *[512]u8) SectorError!void {
    // Extract port number from device FD (same pattern as adapter.zig:50)
    const port_num: u5 = @intCast(@intFromPtr(device_fd.private_data) & 0x1F);

    const req = io.allocRequest(.disk_read) orelse return error.IOError;
    defer io.freeRequest(req);

    const buf_phys = ahci.adapter.blockReadAsync(port_num, lba, 1, req) catch return error.IOError;
    defer ahci.adapter.freeDmaBuffer(buf_phys, 512);

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => |bytes| {
            if (bytes < 512) return error.IOError;
            // SECURITY: Vuln 8 - Memory barrier ensures DMA writes are visible
            // before we copy from the buffer. Prevents data corruption from
            // out-of-order memory access or CPU cache inconsistency.
            asm volatile ("mfence" ::: .{ .memory = true });
            ahci.adapter.copyFromDmaBuffer(buf_phys, buf);
        },
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Write a single sector using async AHCI I/O (sync-over-async pattern)
/// Extracts port_num from device_fd.private_data and uses IRQ-driven completion
fn writeSector(device_fd: *fd.FileDescriptor, lba: u32, buf: []const u8) SectorError!void {
    if (buf.len < 512) return error.IOError;

    // Extract port number from device FD
    const port_num: u5 = @intCast(@intFromPtr(device_fd.private_data) & 0x1F);

    const req = io.allocRequest(.disk_write) orelse return error.IOError;
    defer io.freeRequest(req);

    // Allocate DMA buffer (1 page minimum for PMM)
    const buf_phys = pmm.allocZeroedPages(1) orelse return error.IOError;
    defer pmm.freePages(buf_phys, 1);

    // Copy data to DMA buffer
    ahci.adapter.copyToDmaBuffer(buf_phys, buf[0..512]);

    // Submit async write
    ahci.adapter.blockWriteAsync(port_num, lba, 1, buf_phys, req) catch return error.IOError;

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => {},
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

pub const SFS = struct {
    device_fd: *fd.FileDescriptor,
    superblock: Superblock,
    /// Lock protecting superblock updates (prevents TOCTOU in file growth)
    alloc_lock: sync.Spinlock = .{},
    /// AHCI port number for direct async I/O access
    port_num: u5,

    /// Initialize SFS on a device
    /// Opens the device, checks magic, formats if needed.
    pub fn init(device_path: []const u8) !vfs.FileSystem {
        // Open block device
        const device_fd = try vfs.Vfs.open(device_path, fd.O_RDWR);

        const alloc = heap.allocator();
        const self = try alloc.create(SFS);
        self.device_fd = device_fd;
        // Extract AHCI port number for direct async I/O access
        self.port_num = @intCast(@intFromPtr(device_fd.private_data) & 0x1F);

        // Read superblock using async I/O
        var buf: [512]u8 = undefined;
        try readSector(device_fd, 0, &buf);

        const sb: *Superblock = @ptrCast(@alignCast(&buf));
        if (sb.magic != SFS_MAGIC or sb.version != SFS_VERSION) {
            console.warn("SFS: Invalid magic or old version, formatting...", .{});
            try self.format();
        } else {
            // SECURITY: Validate superblock fields from untrusted disk source
            // Prevent malicious disk from causing out-of-bounds access or DoS
            if (!validateSuperblock(sb)) {
                console.err("SFS: Corrupted superblock detected, formatting...", .{});
                try self.format();
            } else {
                self.superblock = sb.*;
                console.info("SFS: Mounted. Files: {}, Free Blocks: {}", .{
                    self.superblock.file_count,
                    self.superblock.free_blocks,
                });
            }
        }

        return vfs.FileSystem{
            .context = self,
            .open = sfsOpen,
            .unmount = sfsUnmount,
            .unlink = sfsUnlink,
            .stat_path = sfsStatPath,
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
        // SECURITY: Use saturating add to prevent overflow from malicious disk data
        self.superblock.free_blocks = std.math.add(u32, self.superblock.free_blocks, 1) catch std.math.maxInt(u32);
        self.updateSuperblock() catch return error.IOError;
    }

    /// Free multiple contiguous blocks
    /// SECURITY: Uses checked arithmetic to prevent integer overflow attacks
    pub fn freeBlocks(self: *SFS, start_block: u32, count: u32) void {
        // Limit iteration count to prevent DoS from malicious disk data
        const safe_count = @min(count, self.superblock.total_blocks);

        var i: u32 = 0;
        while (i < safe_count) : (i += 1) {
            // SECURITY: Use checked arithmetic to detect overflow
            const block = std.math.add(u32, start_block, i) catch {
                console.warn("SFS: freeBlocks overflow at start_block={}, i={}", .{ start_block, i });
                return;
            };
            self.freeBlock(block) catch |err| {
                console.warn("SFS: Failed to free block {}: {}", .{ block, err });
            };
        }
    }

    const SfsError = error{
        IOError,
        InvalidBlock,
        ENOSPC,
    };
};

// =============================================================================
// Security: Input Validation
// =============================================================================

/// Validate filename to prevent path traversal and injection attacks
/// Returns false if filename contains dangerous characters
fn isValidFilename(name: []const u8) bool {
    if (name.len == 0) return false;

    // Reject path traversal attempts
    if (std.mem.indexOf(u8, name, "..")) |_| return false;

    // Reject path separators (shouldn't be in flat filename)
    if (std.mem.indexOf(u8, name, "/")) |_| return false;
    if (std.mem.indexOf(u8, name, "\\")) |_| return false;

    // SECURITY: Reject control characters (0x00-0x1F, 0x7F)
    // These can cause null-byte injection and display issues
    for (name) |c| {
        if (c < 0x20 or c == 0x7F) return false;
    }

    return true;
}

/// Validate superblock fields to prevent malicious disk attacks
/// Returns false if any field is out of expected bounds
fn validateSuperblock(sb: *const Superblock) bool {
    // Basic sanity checks
    if (sb.block_size != SECTOR_SIZE) {
        console.warn("SFS: Invalid block_size {}", .{sb.block_size});
        return false;
    }

    // Total blocks should be reasonable (max 2GB with 512B sectors = 4M blocks)
    const max_blocks: u32 = 4 * 1024 * 1024;
    if (sb.total_blocks == 0 or sb.total_blocks > max_blocks) {
        console.warn("SFS: Invalid total_blocks {}", .{sb.total_blocks});
        return false;
    }

    // Bitmap must start at block 1 (after superblock)
    if (sb.bitmap_start != 1) {
        console.warn("SFS: Invalid bitmap_start {}", .{sb.bitmap_start});
        return false;
    }

    // Bitmap blocks should be reasonable (max 256 blocks = 1M tracked blocks)
    if (sb.bitmap_blocks == 0 or sb.bitmap_blocks > 256) {
        console.warn("SFS: Invalid bitmap_blocks {}", .{sb.bitmap_blocks});
        return false;
    }

    // Root dir must come after bitmap
    const expected_root_start = sb.bitmap_start + sb.bitmap_blocks;
    if (sb.root_dir_start != expected_root_start) {
        console.warn("SFS: Invalid root_dir_start {}, expected {}", .{ sb.root_dir_start, expected_root_start });
        return false;
    }

    // Data start must come after root directory
    const expected_data_start = sb.root_dir_start + ROOT_DIR_BLOCKS;
    if (sb.data_start != expected_data_start) {
        console.warn("SFS: Invalid data_start {}, expected {}", .{ sb.data_start, expected_data_start });
        return false;
    }

    // Data start must be within total blocks
    if (sb.data_start >= sb.total_blocks) {
        console.warn("SFS: data_start {} >= total_blocks {}", .{ sb.data_start, sb.total_blocks });
        return false;
    }

    // Free blocks cannot exceed available data blocks
    const max_data_blocks = sb.total_blocks - sb.data_start;
    if (sb.free_blocks > max_data_blocks) {
        console.warn("SFS: free_blocks {} > max_data_blocks {}", .{ sb.free_blocks, max_data_blocks });
        return false;
    }

    // File count should be reasonable
    if (sb.file_count > MAX_FILES) {
        console.warn("SFS: file_count {} > MAX_FILES {}", .{ sb.file_count, MAX_FILES });
        return false;
    }

    // next_free_block must be within bounds
    if (sb.next_free_block > sb.total_blocks) {
        console.warn("SFS: next_free_block {} > total_blocks {}", .{ sb.next_free_block, sb.total_blocks });
        return false;
    }

    return true;
}

// =============================================================================
// Async I/O Helper Functions
// =============================================================================

/// Read a single sector using async AHCI I/O
/// Allocates DMA buffer, submits read, waits for completion, copies to dest
fn readSectorAsync(self: *SFS, lba: u32, buf: []u8) !void {
    const req = io.allocRequest(.disk_read) orelse return error.IOError;
    defer io.freeRequest(req);

    const buf_phys = ahci.adapter.blockReadAsync(self.port_num, lba, 1, req) catch return error.IOError;
    defer ahci.adapter.freeDmaBuffer(buf_phys, 512);

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => |bytes| {
            if (bytes < 512) return error.IOError;
            // SECURITY: Memory barrier ensures DMA writes are visible
            asm volatile ("mfence" ::: .{ .memory = true });
            ahci.adapter.copyFromDmaBuffer(buf_phys, buf[0..512]);
        },
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Write a single sector using async AHCI I/O
/// Allocates DMA buffer, copies data, submits write, waits for completion
fn writeSectorAsync(self: *SFS, lba: u32, buf: []const u8) !void {
    const req = io.allocRequest(.disk_write) orelse return error.IOError;
    defer io.freeRequest(req);

    // Allocate DMA buffer (1 page minimum for PMM)
    const buf_phys = pmm.allocZeroedPages(1) orelse return error.IOError;
    defer pmm.freePages(buf_phys, 1);

    // Copy data to DMA buffer
    ahci.adapter.copyToDmaBuffer(buf_phys, buf[0..512]);

    // Submit async write
    ahci.adapter.blockWriteAsync(self.port_num, lba, 1, buf_phys, req) catch return error.IOError;

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => {},
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Read multiple sectors using async AHCI I/O (batched)
/// More efficient than multiple single-sector reads
fn readSectorsAsync(self: *SFS, lba: u32, sector_count: u16, buf: []u8) !void {
    if (sector_count == 0) return;
    const total_bytes = @as(usize, sector_count) * 512;
    if (buf.len < total_bytes) return error.IOError;

    const req = io.allocRequest(.disk_read) orelse return error.IOError;
    defer io.freeRequest(req);

    const buf_phys = ahci.adapter.blockReadAsync(self.port_num, lba, sector_count, req) catch return error.IOError;
    defer ahci.adapter.freeDmaBuffer(buf_phys, total_bytes);

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => |bytes| {
            if (bytes < total_bytes) return error.IOError;
            // SECURITY: Memory barrier ensures DMA writes are visible
            asm volatile ("mfence" ::: .{ .memory = true });
            ahci.adapter.copyFromDmaBuffer(buf_phys, buf[0..total_bytes]);
        },
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Write multiple sectors using async AHCI I/O (batched)
fn writeSectorsAsync(self: *SFS, lba: u32, sector_count: u16, buf: []const u8) !void {
    if (sector_count == 0) return;
    const total_bytes = @as(usize, sector_count) * 512;
    if (buf.len < total_bytes) return error.IOError;

    const req = io.allocRequest(.disk_write) orelse return error.IOError;
    defer io.freeRequest(req);

    // Allocate DMA buffer
    const pages_needed = (total_bytes + 4095) / 4096;
    const buf_phys = pmm.allocZeroedPages(pages_needed) orelse return error.IOError;
    defer pmm.freePages(buf_phys, pages_needed);

    // Copy data to DMA buffer
    ahci.adapter.copyToDmaBuffer(buf_phys, buf[0..total_bytes]);

    // Submit async write
    ahci.adapter.blockWriteAsync(self.port_num, lba, sector_count, buf_phys, req) catch return error.IOError;

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => {},
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Read entire root directory in one async operation (batched)
/// Returns buffer containing all directory blocks
fn readDirectoryAsync(self: *SFS, buf: []u8) !void {
    const total_bytes = ROOT_DIR_BLOCKS * 512;
    if (buf.len < total_bytes) return error.IOError;

    try readSectorsAsync(self, self.superblock.root_dir_start, ROOT_DIR_BLOCKS, buf[0..total_bytes]);
}

/// Write entire root directory in one async operation (batched)
fn writeDirectoryAsync(self: *SFS, buf: []const u8) !void {
    const total_bytes = ROOT_DIR_BLOCKS * 512;
    if (buf.len < total_bytes) return error.IOError;

    try writeSectorsAsync(self, self.superblock.root_dir_start, ROOT_DIR_BLOCKS, buf[0..total_bytes]);
}

// Legacy sync wrappers removed - all I/O now uses async helpers above

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

    // SECURITY: Vuln 6 - Comprehensive path validation
    if (!isValidFilename(name)) {
        return vfs.Error.AccessDenied;
    }

    if (name.len == 0 or std.mem.eql(u8, name, ".")) {
        // Root directory - not supported as file yet
        return vfs.Error.IsDirectory;
    }

    if (name.len >= 32) return vfs.Error.NameTooLong;

    // Search for file in root directory using batched read
    var entry_idx: ?u32 = null;
    var free_idx: ?u32 = null;
    var entry: DirEntry = undefined;

    // Read all directory blocks at once (more efficient than one at a time)
    var dir_buf: [ROOT_DIR_BLOCKS * 512]u8 = undefined;
    readDirectoryAsync(self, &dir_buf) catch return vfs.Error.IOError;

    // Scan all entries from in-memory buffer
    const total_entries = ROOT_DIR_BLOCKS * 4; // 4 entries per block
    var idx: u32 = 0;
    while (idx < total_entries) : (idx += 1) {
        const offset = idx * 128;
        const e: *DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

        if (e.flags == 1) {
            // Active entry, check name
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (std.mem.eql(u8, e_name, name)) {
                entry_idx = idx;
                entry = e.*;
                break;
            }
        } else {
            if (free_idx == null) {
                free_idx = idx;
            }
        }
    }

    if (entry_idx) |found_idx| {
        // File found - use found_idx for entry tracking

        // SECURITY: Validate entry fields from untrusted disk source
        // Vuln 3: Ensure start_block is within data region
        if (entry.start_block < self.superblock.data_start or
            entry.start_block >= self.superblock.total_blocks)
        {
            console.warn("SFS: Corrupted entry '{s}' with invalid start_block {}", .{ name, entry.start_block });
            return vfs.Error.IOError;
        }

        // SECURITY: Vuln 5 - Validate size doesn't exceed possible allocation
        const max_possible_blocks = self.superblock.total_blocks - entry.start_block;
        const max_possible_size = max_possible_blocks * 512;
        if (entry.size > max_possible_size) {
            console.warn("SFS: Corrupted entry '{s}' with size {} > max {}", .{ name, entry.size, max_possible_size });
            return vfs.Error.IOError;
        }

        // NOTE: Permission checking is done at the syscall layer (sys_open/sys_openat)
        // before calling VFS.open. This avoids circular dependency between fs and perms.

        // Create FD
        const file_ctx = alloc.create(SfsFile) catch return vfs.Error.NoMemory;
        file_ctx.* = .{
            .fs = self,
            .start_block = entry.start_block,
            .size = entry.size,
            .entry_idx = found_idx,
        };

        return fd.createFd(&sfs_ops, flags, file_ctx) catch return vfs.Error.NoMemory;
    } else {
        // Not found. Create if O_CREAT?
        if ((flags & fd.O_CREAT) != 0) {
            if (self.superblock.file_count >= MAX_FILES) return vfs.Error.NoMemory; // Disk full (inodes)
            const new_idx = free_idx orelse return vfs.Error.NoMemory;

            // Allocate first block for new file using bitmap
            const start_block = self.allocateBlock() catch return vfs.Error.NoMemory;

            // Default permissions: regular file with rw-r--r-- (0o644)
            // The syscall layer can adjust ownership via chown after creation
            // if the calling process has different uid/gid
            const default_mode: u32 = meta.S_IFREG | 0o644;

            var new_entry = DirEntry{
                .name = [_]u8{0} ** 32,
                .start_block = start_block,
                .size = 0,
                .flags = 1,
                .mode = default_mode,
                .uid = 0, // Default to root, syscall layer adjusts via chown
                .gid = 0,
                .mtime = 0, // TODO: Get current timestamp when RTC is available
                ._pad = undefined,
            };
            @memcpy(new_entry.name[0..name.len], name);

            // Write entry to disk - reuse dir_buf we already read
            const block_idx = new_idx / 4;
            const offset_in_dir = new_idx * 128;

            // Update entry in our existing directory buffer
            const dest: *DirEntry = @ptrCast(@alignCast(&dir_buf[offset_in_dir]));
            dest.* = new_entry;

            // Write only the affected block back
            const block_start = block_idx * 512;
            writeSectorAsync(self, self.superblock.root_dir_start + block_idx, dir_buf[block_start..][0..512]) catch return vfs.Error.IOError;

            self.superblock.file_count += 1;
            self.updateSuperblock() catch return vfs.Error.IOError;

            const file_ctx = alloc.create(SfsFile) catch return vfs.Error.NoMemory;
            file_ctx.* = .{
                .fs = self,
                .start_block = new_entry.start_block,
                .size = 0,
                .entry_idx = new_idx,
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

pub const TruncateError = error{
    NotSfs,
    TooLarge,
    IOError,
};

pub fn truncateFd(file_desc: *fd.FileDescriptor, length: usize) TruncateError!void {
    if (file_desc.ops != &sfs_ops) {
        return error.NotSfs;
    }

    const file: *SfsFile = @ptrCast(@alignCast(file_desc.private_data));
    if (length > std.math.maxInt(u32)) {
        return error.TooLarge;
    }

    if (length > file.size) {
        return error.TooLarge;
    }

    // SECURITY: Vuln 4 - Acquire lock at start to prevent TOCTOU race with sfsWrite
    // The entire truncate operation must be atomic with respect to file size changes
    const held = file.fs.alloc_lock.acquire();
    defer held.release();

    // Re-check size under lock to prevent race
    if (length > file.size) {
        return error.TooLarge;
    }

    const new_size: u32 = @intCast(length);
    const current_blocks: u32 = if (file.size == 0) 1 else (file.size + 511) / 512;
    const requested_blocks: u32 = if (new_size == 0) 1 else (new_size + 511) / 512;

    if (requested_blocks < current_blocks) {
        const free_start = file.start_block + requested_blocks;
        const free_count = current_blocks - requested_blocks;
        if (free_count > 0) {
            file.fs.freeBlocks(free_start, free_count);
        }

        const end_block = file.start_block + current_blocks;
        if (end_block == file.fs.superblock.next_free_block) {
            file.fs.superblock.next_free_block = file.start_block + requested_blocks;
            file.fs.updateSuperblock() catch return error.IOError;
        }
    }

    file.size = new_size;
    if (file_desc.position > new_size) {
        file_desc.position = new_size;
    }

    const block_idx = file.entry_idx / 4;
    const offset_idx = file.entry_idx % 4;

    var dir_buf: [512]u8 = undefined;
    readSector(file.fs.device_fd, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return error.IOError;

    const entry: *DirEntry = @ptrCast(@alignCast(&dir_buf[offset_idx * 128]));
    entry.size = file.size;

    writeSector(file.fs.device_fd, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return error.IOError;
}

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

    // Calculate sector range needed
    const start_byte = file_desc.position;
    const end_byte = start_byte + to_read;
    const first_sector = start_byte / 512;
    const last_sector = (end_byte + 511) / 512; // Round up
    const sector_count = last_sector - first_sector;

    // Safe cast: sector offsets bounded by file size which is u32
    const first_sector_u32 = std.math.cast(u32, first_sector) orelse return -5;
    const sector_count_u16 = std.math.cast(u16, @min(sector_count, 256)) orelse return -5;

    // Optimization: For multi-sector reads, use batched async I/O
    if (sector_count > 1 and sector_count <= 256) {
        // Allocate temporary buffer for all sectors
        const total_bytes = @as(usize, sector_count_u16) * 512;
        var sector_buf: [256 * 512]u8 = undefined; // Max 256 sectors (128KB)

        const phys_block = file.start_block + first_sector_u32;
        readSectorsAsync(file.fs, phys_block, sector_count_u16, sector_buf[0..total_bytes]) catch return -5;

        // Copy relevant portion to output buffer
        const byte_offset = start_byte % 512;
        @memcpy(buf[0..to_read], sector_buf[byte_offset..][0..to_read]);

        file_desc.position += to_read;
        return std.math.cast(isize, to_read) orelse return -75;
    }

    // Fallback: Single-sector read or reads > 256 sectors
    var read_count: usize = 0;
    var current_pos = file_desc.position;

    while (read_count < to_read) {
        const rel_pos = current_pos;
        const block_offset = rel_pos / 512;
        const byte_offset = rel_pos % 512;

        const block_offset_u32 = std.math.cast(u32, block_offset) orelse return -5;
        const phys_block = file.start_block + block_offset_u32;

        var sector_buf: [512]u8 = undefined;
        readSector(file.fs.device_fd, phys_block, &sector_buf) catch return -5;

        const chunk = @min(to_read - read_count, 512 - byte_offset);
        @memcpy(buf[read_count..][0..chunk], sector_buf[byte_offset..][0..chunk]);

        read_count += chunk;
        current_pos += chunk;
    }

    file_desc.position += read_count;
    return std.math.cast(isize, read_count) orelse return -75;
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

    // Optimization: Batch write for sector-aligned multi-sector writes
    const start_byte_offset = current_pos % 512;

    // Check if we can do a batch write (aligned start, multiple full sectors)
    if (start_byte_offset == 0 and buf.len >= 1024) {
        // Calculate full sectors we can batch write
        const full_sectors = buf.len / 512;
        if (full_sectors >= 2 and full_sectors <= 256) {
            const block_offset_u32 = std.math.cast(u32, current_pos / 512) orelse return -5;
            const phys_block = file.start_block + block_offset_u32;
            const sector_count_u16: u16 = @intCast(full_sectors);
            const batch_bytes = full_sectors * 512;

            // Write all full sectors at once
            writeSectorsAsync(file.fs, phys_block, sector_count_u16, buf[0..batch_bytes]) catch return -5;

            written_count = batch_bytes;
            current_pos += batch_bytes;
        }
    }

    // Handle remaining bytes (partial sectors or single-sector fallback)
    while (written_count < buf.len) {
        const rel_pos = current_pos;
        const block_offset = rel_pos / 512;
        const byte_offset = rel_pos % 512;

        const block_offset_u32 = std.math.cast(u32, block_offset) orelse return -5;
        const phys_block = file.start_block + block_offset_u32;

        var sector_buf: [512]u8 = undefined;
        // Read-modify-write for partial sectors
        readSector(file.fs.device_fd, phys_block, &sector_buf) catch {
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

    // SECURITY: Vuln 6 - Comprehensive path validation
    if (!isValidFilename(name)) {
        return vfs.Error.AccessDenied;
    }

    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    // Read all directory blocks at once (batched async I/O)
    var dir_buf: [ROOT_DIR_BLOCKS * 512]u8 = undefined;
    readDirectoryAsync(self, &dir_buf) catch return vfs.Error.IOError;

    // Scan all entries from in-memory buffer
    const total_entries = ROOT_DIR_BLOCKS * 4;
    var idx: u32 = 0;
    while (idx < total_entries) : (idx += 1) {
        const offset = idx * 128;
        const e: *DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

        if (e.flags == 1) {
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (std.mem.eql(u8, e_name, name)) {
                // Found the file - free its blocks
                const blocks_used = (e.size + 511) / 512;
                if (blocks_used > 0) {
                    self.freeBlocks(e.start_block, blocks_used);
                }

                // Clear directory entry in buffer
                e.flags = 0;
                e.name = [_]u8{0} ** 32;
                e.start_block = 0;
                e.size = 0;

                // Write back only the affected directory block
                const block_idx = idx / 4;
                const block_start = block_idx * 512;
                writeSectorAsync(self, self.superblock.root_dir_start + block_idx, dir_buf[block_start..][0..512]) catch return vfs.Error.IOError;

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

    return vfs.Error.NotFound;
}

fn sfsStatPath(ctx: ?*anyopaque, path: []const u8) ?vfs.FileMeta {
    const self: *SFS = @ptrCast(@alignCast(ctx));

    // Handle root directory
    if (path.len == 0 or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, ".")) {
        return vfs.FileMeta{
            .mode = meta.S_IFDIR | 0o755, // Directory with rwxr-xr-x
            .uid = 0,
            .gid = 0,
            .exists = true,
            .readonly = false,
        };
    }

    // Normalize path (remove leading /)
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    // Validate filename
    if (!isValidFilename(name)) {
        return null;
    }

    if (name.len == 0 or name.len >= 32) return null;

    // Read all directory blocks at once (batched async I/O)
    var dir_buf: [ROOT_DIR_BLOCKS * 512]u8 = undefined;
    readDirectoryAsync(self, &dir_buf) catch return null;

    // Scan all entries from in-memory buffer
    const total_entries = ROOT_DIR_BLOCKS * 4;
    var idx: u32 = 0;
    while (idx < total_entries) : (idx += 1) {
        const offset = idx * 128;
        const e: *const DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

        if (e.flags == 1) {
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (std.mem.eql(u8, e_name, name)) {
                // Found the file - return actual permissions from DirEntry
                return vfs.FileMeta{
                    .mode = e.mode,
                    .uid = e.uid,
                    .gid = e.gid,
                    .exists = true,
                    .readonly = false,
                };
            }
        }
    }

    return null;
}

/// Change file mode (permissions)
fn sfsChmod(ctx: ?*anyopaque, path: []const u8, mode: u32) vfs.Error!void {
    const self: *SFS = @ptrCast(@alignCast(ctx));

    // Normalize path (remove leading /)
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    if (!isValidFilename(name)) {
        return vfs.Error.AccessDenied;
    }
    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    // Read all directory blocks
    var dir_buf: [ROOT_DIR_BLOCKS * 512]u8 = undefined;
    readDirectoryAsync(self, &dir_buf) catch return vfs.Error.IOError;

    // Find the entry
    const total_entries = ROOT_DIR_BLOCKS * 4;
    var idx: u32 = 0;
    while (idx < total_entries) : (idx += 1) {
        const offset = idx * 128;
        const e: *DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

        if (e.flags == 1) {
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (std.mem.eql(u8, e_name, name)) {
                // Found - update mode (keep file type, change permission bits)
                const file_type = e.mode & 0o170000;
                e.mode = file_type | (mode & 0o7777);

                // Write back the directory block
                const block_idx = idx / 4;
                const block_start = block_idx * 512;
                writeSectorAsync(self, self.superblock.root_dir_start + block_idx, dir_buf[block_start..][0..512]) catch return vfs.Error.IOError;

                return;
            }
        }
    }

    return vfs.Error.NotFound;
}

/// Change file owner and group
fn sfsChown(ctx: ?*anyopaque, path: []const u8, uid: ?u32, gid: ?u32) vfs.Error!void {
    const self: *SFS = @ptrCast(@alignCast(ctx));

    // Normalize path (remove leading /)
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    if (!isValidFilename(name)) {
        return vfs.Error.AccessDenied;
    }
    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    // Read all directory blocks
    var dir_buf: [ROOT_DIR_BLOCKS * 512]u8 = undefined;
    readDirectoryAsync(self, &dir_buf) catch return vfs.Error.IOError;

    // Find the entry
    const total_entries = ROOT_DIR_BLOCKS * 4;
    var idx: u32 = 0;
    while (idx < total_entries) : (idx += 1) {
        const offset = idx * 128;
        const e: *DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

        if (e.flags == 1) {
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (std.mem.eql(u8, e_name, name)) {
                // Found - update uid/gid if specified
                if (uid) |new_uid| {
                    e.uid = new_uid;
                }
                if (gid) |new_gid| {
                    e.gid = new_gid;
                }

                // Write back the directory block
                const block_idx = idx / 4;
                const block_start = block_idx * 512;
                writeSectorAsync(self, self.superblock.root_dir_start + block_idx, dir_buf[block_start..][0..512]) catch return vfs.Error.IOError;

                return;
            }
        }
    }

    return vfs.Error.NotFound;
}
