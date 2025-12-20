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
//!
//! Intended for basic persistence until a full FS (EXT2/FAT) is implemented.
//!
//! ## Lock Ordering (SECURITY: deadlock prevention)
//!
//! To prevent deadlocks, locks MUST be acquired in this order:
//!   1. SFS.alloc_lock (filesystem-wide allocation lock)
//!   2. FileDescriptor.lock (per-file descriptor lock)
//!
//! Current lock usage by operation:
//!   - sfsOpen: alloc_lock only (for open_counts)
//!   - sfsClose: alloc_lock only (for open_counts, pending_delete)
//!   - sfsRead: FD lock only (position/size access)
//!   - sfsWrite: FD lock, then alloc_lock if growing (nested, same thread)
//!   - sfsUnlink: alloc_lock only (for open_counts, pending_delete)
//!   - truncateFd: alloc_lock only (for size/block updates)
//!   - allocateBlock/freeBlock: alloc_lock only
//!
//! ## TOCTOU Considerations (SECURITY: race condition awareness)
//!
//! Permission checks occur at the syscall layer (sys_open/sys_openat) before
//! VFS.open is called. There is a potential TOCTOU window between permission
//! check and actual open. Mitigations:
//!   - pending_delete check catches concurrent unlink race
//!   - Permission changes during this window are accepted as low risk
//!   - Full mitigation would require VFS-level locking across stat+open

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
            // SECURITY: Memory barrier ensures DMA writes are visible
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

/// SECURITY: stores block allocation info at unlink time
/// Prevents block leaks if file is modified between unlink and close
const DeferredDeleteInfo = struct {
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

    // SECURITY: track mount state to prevent use-after-free on unmount
    /// True while filesystem is mounted and safe to use
    mounted: bool = true,

    // SECURITY: track open file descriptors per entry
    // Prevents use-after-free when file is unlinked while still open
    /// Count of open file descriptors per directory entry
    open_counts: [MAX_FILES]u32 = [_]u32{0} ** MAX_FILES,
    /// Tracks entries that were unlinked while open (deferred deletion)
    pending_delete: [MAX_FILES]bool = [_]bool{false} ** MAX_FILES,
    /// SECURITY: stores block info at unlink time (not close time)
    /// This ensures we free the correct blocks even if file was modified after unlink
    deferred_info: [MAX_FILES]DeferredDeleteInfo = [_]DeferredDeleteInfo{.{ .start_block = 0, .block_count = 0 }} ** MAX_FILES,

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
            // SECURITY: zero padding to prevent kernel stack leak to disk
            ._pad = [_]u8{0} ** (512 - 44),
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

    /// Load all bitmap blocks in a single batched async I/O operation
    /// Returns a buffer containing all bitmap data (caller must free)
    fn loadBitmapBatch(self: *SFS) ![]u8 {
        const alloc = heap.allocator();
        const bitmap_size = self.superblock.bitmap_blocks * SECTOR_SIZE;
        const bitmap_buf = alloc.alloc(u8, bitmap_size) catch return error.ENOMEM;
        errdefer alloc.free(bitmap_buf);

        // Allocate I/O request for batched read
        const req = io.allocRequest(.disk_read) orelse {
            alloc.free(bitmap_buf);
            return error.IOError;
        };
        defer io.freeRequest(req);

        // Read all bitmap blocks at once (1 async I/O instead of N)
        const sector_count: u16 = @intCast(self.superblock.bitmap_blocks);
        const buf_phys = ahci.adapter.blockReadAsync(
            self.port_num,
            self.superblock.bitmap_start,
            sector_count,
            req,
        ) catch {
            alloc.free(bitmap_buf);
            return error.IOError;
        };
        defer ahci.adapter.freeDmaBuffer(buf_phys, bitmap_size);

        // Wait for completion
        var future = io.Future{ .request = req };
        const result = future.wait();

        switch (result) {
            .success => |bytes| {
                if (bytes < bitmap_size) {
                    alloc.free(bitmap_buf);
                    return error.IOError;
                }
                // Memory barrier to ensure DMA writes are visible
                asm volatile ("mfence" ::: .{ .memory = true });
                ahci.adapter.copyFromDmaBuffer(buf_phys, bitmap_buf);
            },
            .err, .cancelled => {
                alloc.free(bitmap_buf);
                return error.IOError;
            },
            .pending => unreachable,
        }

        return bitmap_buf;
    }

    /// Allocate a free block from the bitmap
    /// Optimized: loads all bitmap blocks in one async I/O, scans in-memory
    pub fn allocateBlock(self: *SFS) !u32 {
        const held = self.alloc_lock.acquire();
        defer held.release();

        const alloc = heap.allocator();

        // Load all bitmap blocks in one batched read
        const bitmap_buf = self.loadBitmapBatch() catch return error.IOError;
        defer alloc.free(bitmap_buf);

        // Scan in-memory bitmap for free bit
        for (bitmap_buf, 0..) |byte, global_byte_idx| {
            if (byte != 0xFF) {
                // Found a byte with at least one free bit
                var bit: u3 = 0;
                while (bit < 8) : (bit += 1) {
                    if ((byte & (@as(u8, 1) << bit)) == 0) {
                        // Found free bit - mark as allocated in buffer
                        bitmap_buf[global_byte_idx] |= (@as(u8, 1) << bit);

                        // Calculate which bitmap block this byte belongs to
                        const bitmap_block_idx: u32 = @intCast(global_byte_idx / SECTOR_SIZE);
                        const block_start = bitmap_block_idx * SECTOR_SIZE;

                        // Write back only the modified bitmap block
                        const block_slice = bitmap_buf[block_start..][0..SECTOR_SIZE];
                        writeSectorAsync(self, self.superblock.bitmap_start + bitmap_block_idx, block_slice) catch return error.IOError;

                        // Calculate absolute block number
                        const byte_in_block = global_byte_idx % SECTOR_SIZE;
                        const bitmap_offset = std.math.mul(u32, bitmap_block_idx, BITS_PER_BLOCK) catch return error.IOError;
                        const byte_offset = std.math.mul(u32, @as(u32, @intCast(byte_in_block)), 8) catch return error.IOError;
                        const bit_offset = std.math.add(u32, byte_offset, bit) catch return error.IOError;
                        const total_offset = std.math.add(u32, bitmap_offset, bit_offset) catch return error.IOError;
                        const block_num = std.math.add(u32, self.superblock.data_start, total_offset) catch return error.IOError;

                        // SECURITY: validate block_num is within disk bounds
                        // Malicious disk could have bitmap_blocks > what total_blocks allows
                        if (block_num >= self.superblock.total_blocks) {
                            console.warn("SFS: Allocated block {} exceeds total_blocks {}", .{ block_num, self.superblock.total_blocks });
                            return error.ENOSPC;
                        }

                        // SECURITY: use checked subtraction for free_blocks
                        // Detects inconsistency between bitmap and superblock accounting
                        // A malformed disk could have free_blocks=0 but free bits in bitmap
                        self.superblock.free_blocks = std.math.sub(u32, self.superblock.free_blocks, 1) catch blk: {
                            console.warn("SFS: free_blocks underflow detected (bitmap/superblock mismatch)", .{});
                            break :blk 0;
                        };
                        self.updateSuperblock() catch return error.IOError;

                        return block_num;
                    }
                }
            }
        }

        return error.ENOSPC; // No free blocks
    }

    /// Free a block back to the bitmap
    /// Optimized: uses async I/O for read/write operations
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

        // Read bitmap block using async I/O
        var buf: [512]u8 = undefined;
        readSectorAsync(self, self.superblock.bitmap_start + @as(u32, @intCast(bitmap_block_idx)), &buf) catch return error.IOError;

        // Check if already free (double-free detection)
        if ((buf[byte_idx] & (@as(u8, 1) << bit_idx)) == 0) {
            console.warn("SFS: Double-free detected for block {}", .{block_num});
            return;
        }

        // Clear bit
        buf[byte_idx] &= ~(@as(u8, 1) << bit_idx);

        // Write back using async I/O
        writeSectorAsync(self, self.superblock.bitmap_start + @as(u32, @intCast(bitmap_block_idx)), &buf) catch return error.IOError;

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

    // SECURITY: limit bitmap_blocks to 16 (8KB max allocation)
    // Each bitmap block tracks 4096 blocks, so 16 blocks = 65536 trackable blocks (32MB disk)
    // This prevents heap exhaustion from malicious disk with large bitmap_blocks
    const MAX_BITMAP_BLOCKS: u32 = 16;
    if (sb.bitmap_blocks == 0 or sb.bitmap_blocks > MAX_BITMAP_BLOCKS) {
        console.warn("SFS: Invalid bitmap_blocks {} (max={})", .{ sb.bitmap_blocks, MAX_BITMAP_BLOCKS });
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

        // SECURITY: atomically mark as unmounted and check for open files
        // This prevents use-after-free if operations are in progress
        {
            const held = self.alloc_lock.acquire();
            defer held.release();

            // Mark as unmounted - all new operations will fail
            self.mounted = false;

            // Check if any files are still open
            for (self.open_counts) |count| {
                if (count > 0) {
                    // Files still open - log warning but proceed with unmount
                    // The mounted=false flag will cause in-flight operations to fail safely
                    console.warn("SFS: Unmounting with open files - operations may fail", .{});
                    break;
                }
            }
        }

        // Close device FD
        if (self.device_fd.ops.close) |close_fn| {
            _ = close_fn(self.device_fd);
        }
        heap.allocator().destroy(self);
    }
}

fn sfsOpen(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd.FileDescriptor {
    const self: *SFS = @ptrCast(@alignCast(ctx));

    // SECURITY: check mount state before any operation
    if (!self.mounted) return vfs.Error.IOError;

    const alloc = heap.allocator();

    // Normalize path (remove leading /)
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    // SECURITY: Comprehensive path validation
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
            // SECURITY: skip entries with corrupted names (no null terminator)
            if (e_name.len >= 32) continue;
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
        // Ensure start_block is within data region
        if (entry.start_block < self.superblock.data_start or
            entry.start_block >= self.superblock.total_blocks)
        {
            console.warn("SFS: Corrupted entry '{s}' with invalid start_block {}", .{ name, entry.start_block });
            return vfs.Error.IOError;
        }

        // SECURITY: Validate size doesn't exceed possible allocation
        const max_possible_blocks = self.superblock.total_blocks - entry.start_block;
        const max_possible_size = max_possible_blocks * 512;
        if (entry.size > max_possible_size) {
            console.warn("SFS: Corrupted entry '{s}' with size {} > max {}", .{ name, entry.size, max_possible_size });
            return vfs.Error.IOError;
        }

        // NOTE: Permission checking is done at the syscall layer (sys_open/sys_openat)
        // before calling VFS.open. This avoids circular dependency between fs and perms.
        //
        // SECURITY: TOCTOU between stat_path and open
        // There is a potential race where permissions could change between when
        // the syscall layer checks permissions (via stat_path) and when we open.
        // Full mitigation would require passing expected permissions here and
        // verifying atomically, or holding a VFS-level lock across both operations.
        // Current partial mitigation: pending_delete check below catches the
        // concurrent unlink case. For permission changes, the risk is acceptable
        // as the window is small and the syscall layer re-validates on each operation.

        // Create FD context first (allocation can be done outside lock)
        const file_ctx = alloc.create(SfsFile) catch return vfs.Error.NoMemory;
        file_ctx.* = .{
            .fs = self,
            .start_block = entry.start_block,
            .size = entry.size,
            .entry_idx = found_idx,
            // SECURITY: store actual permissions for sfsStat
            .mode = entry.mode,
            .uid = entry.uid,
            .gid = entry.gid,
        };

        // SECURITY: atomically check pending_delete AND increment open_counts
        // This prevents race condition where another thread completes deferred deletion
        // between our check and increment, leading to use-after-free of freed blocks.
        {
            const lock_held = self.alloc_lock.acquire();
            defer lock_held.release();

            // Check pending_delete UNDER lock to prevent TOCTOU race
            if (self.pending_delete[found_idx]) {
                alloc.destroy(file_ctx);
                return vfs.Error.NotFound;
            }
            // SECURITY: use checked addition to prevent overflow
            // Overflow would break deferred deletion and cause use-after-free
            self.open_counts[found_idx] = std.math.add(u32, self.open_counts[found_idx], 1) catch {
                alloc.destroy(file_ctx);
                return vfs.Error.NoMemory; // Too many open files
            };
        }

        return fd.createFd(&sfs_ops, flags, file_ctx) catch {
            // Decrement count on FD creation failure
            const lock_held = self.alloc_lock.acquire();
            defer lock_held.release();
            if (self.open_counts[found_idx] > 0) {
                self.open_counts[found_idx] -= 1;
            }
            alloc.destroy(file_ctx);
            return vfs.Error.NoMemory;
        };
    } else {
        // Not found. Create if O_CREAT?
        if ((flags & fd.O_CREAT) != 0) {
            // SECURITY: reserve slot under lock to prevent:
            // 1. Two threads finding same free_idx (directory entry aliasing)
            // 2. file_count race condition on increment
            //
            // Strategy: We cannot hold lock during allocateBlock (it has own lock).
            // Instead: (1) reserve slot under lock, (2) allocate block, (3) write entry under lock.

            var new_idx: u32 = undefined;

            // Phase 1: Reserve directory slot under lock
            {
                const lock_held = self.alloc_lock.acquire();
                defer lock_held.release();

                if (self.superblock.file_count >= MAX_FILES) return vfs.Error.NoMemory;

                // Re-scan for free slot under lock (another thread may have taken free_idx)
                var reserved_idx: ?u32 = null;
                for (0..MAX_FILES) |slot_i| {
                    const slot_idx: u32 = @intCast(slot_i);
                    const blk_idx = slot_idx / 4;
                    const off_idx = slot_idx % 4;
                    const e: *const DirEntry = @ptrCast(@alignCast(&dir_buf[blk_idx * 512 + off_idx * 128]));
                    if (e.flags == 0) {
                        reserved_idx = slot_idx;
                        break;
                    }
                }

                new_idx = reserved_idx orelse return vfs.Error.NoMemory;

                // Mark slot as reserved by setting flags=1 in memory
                // This prevents other threads from claiming this slot
                const blk_idx = new_idx / 4;
                const off_idx = new_idx % 4;
                const slot: *DirEntry = @ptrCast(@alignCast(&dir_buf[blk_idx * 512 + off_idx * 128]));
                slot.flags = 1; // Reserve in our local buffer

                // Increment file_count under lock
                self.superblock.file_count += 1;
            }

            // Phase 2: Allocate block (has its own internal locking)
            const start_block = self.allocateBlock() catch {
                // Rollback: decrement file_count
                const lock_held = self.alloc_lock.acquire();
                defer lock_held.release();
                if (self.superblock.file_count > 0) {
                    self.superblock.file_count -= 1;
                }
                return vfs.Error.NoMemory;
            };

            // SECURITY: free block if any subsequent operation fails
            errdefer self.freeBlock(start_block) catch {};

            // Default permissions: regular file with rw-r--r-- (0o644)
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
                // SECURITY: zero padding to prevent kernel stack leak to disk
                ._pad = [_]u8{0} ** (128 - 60),
            };
            @memcpy(new_entry.name[0..name.len], name);

            // Phase 3: Write entry to disk under lock
            {
                const lock_held = self.alloc_lock.acquire();
                defer lock_held.release();

                const block_idx = new_idx / 4;
                const offset_in_dir = new_idx * 128;

                // Update entry in our directory buffer
                const dest: *DirEntry = @ptrCast(@alignCast(&dir_buf[offset_in_dir]));
                dest.* = new_entry;

                // Write only the affected block back
                const block_start = block_idx * 512;
                writeSectorAsync(self, self.superblock.root_dir_start + block_idx, dir_buf[block_start..][0..512]) catch return vfs.Error.IOError;

                // Update superblock with new file_count
                self.updateSuperblock() catch return vfs.Error.IOError;

                // Increment open count for new file
                self.open_counts[new_idx] = std.math.add(u32, self.open_counts[new_idx], 1) catch {
                    return vfs.Error.NoMemory; // Too many open files
                };
            }

            const file_ctx = alloc.create(SfsFile) catch {
                // Decrement count on allocation failure
                const lock_held = self.alloc_lock.acquire();
                defer lock_held.release();
                if (self.open_counts[new_idx] > 0) {
                    self.open_counts[new_idx] -= 1;
                }
                return vfs.Error.NoMemory;
            };

            file_ctx.* = .{
                .fs = self,
                .start_block = new_entry.start_block,
                .size = 0,
                .entry_idx = new_idx,
                // SECURITY: store actual permissions for sfsStat
                .mode = new_entry.mode,
                .uid = new_entry.uid,
                .gid = new_entry.gid,
            };

            return fd.createFd(&sfs_ops, flags, file_ctx) catch {
                // Decrement count on FD creation failure
                const lock_held = self.alloc_lock.acquire();
                defer lock_held.release();
                if (self.open_counts[new_idx] > 0) {
                    self.open_counts[new_idx] -= 1;
                }
                alloc.destroy(file_ctx);
                return vfs.Error.NoMemory;
            };
        }

        return vfs.Error.NotFound;
    }
}

const SfsFile = struct {
    fs: *SFS,
    start_block: u32,
    size: u32,
    entry_idx: u32,
    // SECURITY: store actual permissions for sfsStat
    mode: u32,
    uid: u32,
    gid: u32,

    /// SECURITY: refresh size from directory entry to detect concurrent truncation
    /// Prevents stale cache from allowing reads of blocks that have been freed and reallocated.
    /// Must be called under file_desc.lock to prevent races with position updates.
    /// Returns current size from disk, or null on I/O error or torn read detection.
    fn refreshSizeFromDisk(self: *SfsFile) ?u32 {
        // Validate entry_idx before access
        if (self.entry_idx >= MAX_FILES) {
            return null;
        }

        const block_idx = self.entry_idx / 4;
        const offset_idx = self.entry_idx % 4;

        var dir_buf: [512]u8 = undefined;

        // SECURITY: memory fence before read to ensure we see consistent state
        asm volatile ("mfence" ::: .{ .memory = true });

        readSector(self.fs.device_fd, self.fs.superblock.root_dir_start + block_idx, &dir_buf) catch {
            return null;
        };

        const entry: *const DirEntry = @ptrCast(@alignCast(&dir_buf[offset_idx * 128]));

        // Verify entry is still active (not deleted)
        if (entry.flags != 1) {
            return null;
        }

        // SECURITY: validate fields for consistency to detect torn reads
        // 1. start_block must match our cached value (truncate doesn't change start_block)
        if (entry.start_block != self.start_block) {
            // Torn read or file was deleted and slot reused
            return null;
        }

        // 2. size must be reasonable (not exceed max possible file size)
        // Max file size = total_blocks * 512 bytes
        const max_size = @as(u64, self.fs.superblock.total_blocks) * 512;
        if (entry.size > max_size) {
            return null;
        }

        // 3. name must be null-terminated within bounds (sanity check)
        const name_slice = std.mem.sliceTo(&entry.name, 0);
        if (name_slice.len >= 32) {
            return null;
        }

        return entry.size;
    }
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

    // SECURITY: validate entry_idx to prevent OOB directory access
    // Corrupted SfsFile could cause arbitrary disk read/write
    if (file.entry_idx >= MAX_FILES) {
        return error.IOError;
    }

    if (length > std.math.maxInt(u32)) {
        return error.TooLarge;
    }

    if (length > file.size) {
        return error.TooLarge;
    }

    // SECURITY: Acquire lock at start to prevent TOCTOU race with sfsWrite
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

/// Maximum sectors for batched reads - 32 sectors = 16KB (safe for kernel stack)
const MAX_BATCH_SECTORS: u16 = 32;

fn sfsRead(file_desc: *fd.FileDescriptor, buf: []u8) isize {
    // SECURITY: acquire FD lock to prevent data races on position/size
    const held = file_desc.lock.acquire();
    defer held.release();

    const file: *SfsFile = @ptrCast(@alignCast(file_desc.private_data));

    // SECURITY: refresh size from disk to detect concurrent truncation
    // Another FD may have truncated the file, freeing blocks we would otherwise read.
    // This prevents information disclosure from reading reallocated blocks.
    const current_size = file.refreshSizeFromDisk() orelse {
        // Entry was deleted or I/O error - treat as EOF
        return 0;
    };
    // Update cached size if it was reduced (truncated)
    if (current_size < file.size) {
        file.size = current_size;
        // Also adjust position if it's now past EOF
        if (file_desc.position > current_size) {
            file_desc.position = current_size;
        }
    }

    if (file_desc.position >= file.size) return 0;

    const remaining = file.size - file_desc.position;
    const to_read = @min(buf.len, remaining);

    // Calculate sector range needed
    // SECURITY: use checked arithmetic to prevent integer overflow
    const start_byte = file_desc.position;
    const end_byte = std.math.add(usize, start_byte, to_read) catch {
        return 0; // Overflow - treat as EOF
    };
    const first_sector = start_byte / 512;
    // SECURITY: checked add for rounding up
    const last_sector = (std.math.add(usize, end_byte, 511) catch {
        return 0; // Overflow - treat as EOF
    }) / 512;
    const sector_count = last_sector - first_sector;

    // Safe cast: sector offsets bounded by file size which is u32
    const first_sector_u32 = std.math.cast(u32, first_sector) orelse return -5;

    // SECURITY: validate computed block is within file allocation and fs bounds
    const file_blocks: u32 = if (file.size == 0) 1 else (file.size + 511) / 512;
    if (first_sector_u32 >= file_blocks) {
        return 0; // EOF - position is beyond allocated blocks
    }

    const phys_block_start = file.start_block + first_sector_u32;
    if (phys_block_start >= file.fs.superblock.total_blocks) {
        console.warn("SFS: Read block {} exceeds total_blocks {}", .{ phys_block_start, file.fs.superblock.total_blocks });
        return -5; // EIO
    }

    // SECURITY: limit batch size to 16KB to avoid kernel stack overflow
    const sector_count_u16 = std.math.cast(u16, @min(sector_count, MAX_BATCH_SECTORS)) orelse return -5;

    // Optimization: For multi-sector reads, use batched async I/O
    if (sector_count > 1 and sector_count <= MAX_BATCH_SECTORS) {
        // Allocate temporary buffer for all sectors (max 16KB on stack)
        const total_bytes = @as(usize, sector_count_u16) * 512;
        var sector_buf: [MAX_BATCH_SECTORS * 512]u8 = undefined;

        // SECURITY: verify end block is also within bounds
        const end_block = phys_block_start + sector_count_u16 - 1;
        if (end_block >= file.fs.superblock.total_blocks) {
            console.warn("SFS: Read end block {} exceeds total_blocks {}", .{ end_block, file.fs.superblock.total_blocks });
            return -5; // EIO
        }

        readSectorsAsync(file.fs, phys_block_start, sector_count_u16, sector_buf[0..total_bytes]) catch return -5;

        // Copy relevant portion to output buffer
        const byte_offset = start_byte % 512;
        @memcpy(buf[0..to_read], sector_buf[byte_offset..][0..to_read]);

        file_desc.position += to_read;
        return std.math.cast(isize, to_read) orelse return -75;
    }

    // Fallback: Single-sector read or reads > MAX_BATCH_SECTORS sectors
    var read_count: usize = 0;
    var current_pos = file_desc.position;

    while (read_count < to_read) {
        const rel_pos = current_pos;
        const block_offset = rel_pos / 512;
        const byte_offset = rel_pos % 512;

        const block_offset_u32 = std.math.cast(u32, block_offset) orelse return -5;

        // SECURITY: validate each block access
        if (block_offset_u32 >= file_blocks) {
            break; // EOF reached
        }

        const phys_block = file.start_block + block_offset_u32;
        if (phys_block >= file.fs.superblock.total_blocks) {
            console.warn("SFS: Read block {} exceeds total_blocks {}", .{ phys_block, file.fs.superblock.total_blocks });
            return -5; // EIO
        }

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
    // SECURITY: acquire FD lock to prevent data races on position/size
    const held = file_desc.lock.acquire();
    defer held.release();

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
    const prelim_current_blocks: u32 = if (file.size == 0) 1 else (file.size + 511) / 512;

    // SECURITY: use checked arithmetic to prevent integer overflow
    const new_size_needed = std.math.add(u64, file_desc.position, buf.len) catch {
        return -27; // EFBIG - file too large
    };
    const new_blocks_needed = (new_size_needed + 511) / 512;

    // Validate new_blocks_needed fits in u32 (max file size ~2TB with 512B sectors)
    const new_blocks_needed_u32 = std.math.cast(u32, new_blocks_needed) orelse return -27; // EFBIG

    if (new_blocks_needed_u32 > prelim_current_blocks) {
        // Need to grow - acquire alloc lock (we already hold FD lock)
        const alloc_held = file.fs.alloc_lock.acquire();
        defer alloc_held.release();

        // SECURITY: Recalculate under lock to prevent TOCTOU race
        // Another thread may have modified file.size between our check and lock acquisition
        const current_blocks: u32 = if (file.size == 0) 1 else (file.size + 511) / 512;
        const end_block = file.start_block + current_blocks;

        // Re-check if we still need to grow after recalculation
        if (new_blocks_needed_u32 > current_blocks) {
            // Still need to grow - check if we can
            if (end_block != file.fs.superblock.next_free_block) {
                // Not at end of disk allocation
                // If file size is 0 (new file), it IS at next_free_block (set in open).
                if (file.size != 0) {
                    console.warn("SFS: Cannot grow file not at end of allocation", .{});
                    return -28; // ENOSPC
                }
            }

            // SECURITY: Verify we have enough free blocks
            const blocks_to_add = new_blocks_needed_u32 - current_blocks;
            if (blocks_to_add > file.fs.superblock.free_blocks) {
                return -28; // ENOSPC - not enough free blocks
            }

            // SECURITY: use checked arithmetic to prevent integer overflow
            // A malicious superblock with next_free_block near u32::MAX could wrap around
            const new_next_free = std.math.add(u32, file.fs.superblock.next_free_block, blocks_to_add) catch {
                return -28; // ENOSPC - overflow would occur
            };
            if (new_next_free > file.fs.superblock.total_blocks) {
                return -28; // ENOSPC - would exceed disk bounds
            }

            // Update superblock free pointer atomically with the check
            file.fs.superblock.next_free_block = new_next_free;
            file.fs.updateSuperblock() catch return -5;
        }
        // else: Another thread already grew the file, no action needed
    }

    var written_count: usize = 0;
    var current_pos = file_desc.position;

    // Optimization: Batch write for sector-aligned multi-sector writes
    const start_byte_offset = current_pos % 512;

    // Check if we can do a batch write (aligned start, multiple full sectors)
    // SECURITY: limit batch size to MAX_BATCH_SECTORS (16KB)
    if (start_byte_offset == 0 and buf.len >= 1024) {
        // Calculate full sectors we can batch write
        const full_sectors = @min(buf.len / 512, MAX_BATCH_SECTORS);
        if (full_sectors >= 2) {
            const block_offset_u32 = std.math.cast(u32, current_pos / 512) orelse return -5;
            const phys_block = file.start_block + block_offset_u32;

            // SECURITY: validate block bounds before write
            if (phys_block >= file.fs.superblock.total_blocks) {
                console.warn("SFS: Write block {} exceeds total_blocks {}", .{ phys_block, file.fs.superblock.total_blocks });
                return -5; // EIO
            }

            const sector_count_u16: u16 = @intCast(full_sectors);
            const end_block = phys_block + sector_count_u16 - 1;
            if (end_block >= file.fs.superblock.total_blocks) {
                console.warn("SFS: Write end block {} exceeds total_blocks {}", .{ end_block, file.fs.superblock.total_blocks });
                return -5; // EIO
            }

            const batch_bytes = @as(usize, sector_count_u16) * 512;

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

        // SECURITY: validate block bounds before write
        if (phys_block >= file.fs.superblock.total_blocks) {
            console.warn("SFS: Write block {} exceeds total_blocks {}", .{ phys_block, file.fs.superblock.total_blocks });
            return -5; // EIO
        }

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
        // SECURITY: we hold file_desc.lock here and access device_fd
        // This is safe because:
        // 1. device_fd uses async I/O (AHCI adapter) which has its own request locking
        // 2. We don't acquire device_fd.lock, only call its read/write ops
        // 3. The AHCI adapter uses per-port locking, not FD-level locking
        // If device I/O ever adds FD-level locking, this must be revisited.
        // SECURITY: validate entry_idx and handle I/O errors properly
        // Prevents directory corruption from uninitialized buffer write
        if (file.entry_idx >= MAX_FILES) {
            // Corrupted entry_idx - don't attempt directory update
            return std.math.cast(isize, written_count) orelse return -75;
        }

        const block_idx = file.entry_idx / 4;
        const offset_idx = file.entry_idx % 4;

        var dir_buf: [512]u8 = undefined;
        // SECURITY: if read fails, skip directory update rather than
        // writing garbage. The in-memory size is still correct; just disk metadata
        // may be stale until next successful write.
        readSector(file.fs.device_fd, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch {
            console.warn("SFS: Failed to read directory for size update, skipping", .{});
            return std.math.cast(isize, written_count) orelse return -75;
        };

        const entry: *DirEntry = @ptrCast(@alignCast(&dir_buf[offset_idx * 128]));
        entry.size = file.size;

        writeSector(file.fs.device_fd, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch {
            console.warn("SFS: Failed to write directory size update", .{});
        };
    }

    return std.math.cast(isize, written_count) orelse return -75; // EOVERFLOW
}

fn sfsClose(file_desc: *fd.FileDescriptor) isize {
    const alloc = heap.allocator();
    const file: *SfsFile = @ptrCast(@alignCast(file_desc.private_data));

    // SECURITY: decrement open count and handle deferred deletion
    const entry_idx = file.entry_idx;
    const fs = file.fs;

    // SECURITY: validate entry_idx bounds before array access
    // Prevents out-of-bounds access from memory corruption
    if (entry_idx >= MAX_FILES) {
        console.err("SFS: Invalid entry_idx {} in close (max={})", .{ entry_idx, MAX_FILES });
        alloc.destroy(file);
        return -5; // EIO
    }

    // Decrement open count under lock
    var should_delete = false;
    var deferred_start_block: u32 = 0;
    var deferred_block_count: u32 = 0;
    {
        const lock_held = fs.alloc_lock.acquire();
        defer lock_held.release();

        if (fs.open_counts[entry_idx] > 0) {
            fs.open_counts[entry_idx] -= 1;
        }

        // Check if this was the last reference to a deleted file
        if (fs.open_counts[entry_idx] == 0 and fs.pending_delete[entry_idx]) {
            should_delete = true;
            fs.pending_delete[entry_idx] = false;
            // SECURITY: use block info captured at unlink time
            // This prevents block leaks/corruption if file was modified after unlink
            deferred_start_block = fs.deferred_info[entry_idx].start_block;
            deferred_block_count = fs.deferred_info[entry_idx].block_count;
            // Clear the deferred info
            fs.deferred_info[entry_idx] = .{ .start_block = 0, .block_count = 0 };
        }
    }

    // If file was unlinked while open and this is the last reference, free blocks now
    if (should_delete) {
        // SECURITY: use stored block info, not current SfsFile data
        fs.freeBlocks(deferred_start_block, deferred_block_count);
        console.info("SFS: Deferred deletion completed for entry {} (freed {} blocks at {})", .{ entry_idx, deferred_block_count, deferred_start_block });
    }

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

    // SECURITY: limit seek position to u32::MAX (SFS file size limit)
    // Prevents writes at extreme positions that could corrupt block accounting
    // SFS uses u32 for file sizes, so positions beyond u32::MAX are invalid
    const max_pos: i64 = std.math.maxInt(u32);
    if (new_pos > max_pos) return -27; // EFBIG - file too large

    file_desc.position = std.math.cast(usize, new_pos) orelse return -75; // EOVERFLOW
    return std.math.cast(isize, new_pos) orelse return -75; // EOVERFLOW
}

fn sfsStat(file_desc: *fd.FileDescriptor, stat_buf: *anyopaque) isize {
    const file: *SfsFile = @ptrCast(@alignCast(file_desc.private_data));
    const stat: *uapi.stat.Stat = @ptrCast(@alignCast(stat_buf));

    // SECURITY: return actual permissions captured at open time
    stat.* = .{
        .dev = 0,
        .ino = file.entry_idx,
        .nlink = 1,
        .mode = file.mode, // Actual mode from DirEntry
        .uid = file.uid, // Actual owner
        .gid = file.gid, // Actual group
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

    // SECURITY: check mount state before any operation
    if (!self.mounted) return vfs.Error.IOError;

    // Normalize path (remove leading /)
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    // SECURITY: Comprehensive path validation
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
            // SECURITY: skip entries with corrupted names (no null terminator)
            if (e_name.len >= 32) continue;
            if (std.mem.eql(u8, e_name, name)) {
                // SECURITY: check if file is still open
                var is_open = false;
                // SECURITY: capture block info now, before any modifications
                const blocks_used: u32 = if (e.size == 0) 1 else (e.size + 511) / 512;
                {
                    const lock_held = self.alloc_lock.acquire();
                    defer lock_held.release();

                    if (self.open_counts[idx] > 0) {
                        // File is still open - defer deletion
                        is_open = true;
                        self.pending_delete[idx] = true;
                        // SECURITY: store block info at unlink time
                        // This ensures correct blocks are freed even if file is modified after unlink
                        self.deferred_info[idx] = .{
                            .start_block = e.start_block,
                            .block_count = blocks_used,
                        };
                        console.info("SFS: Deferring deletion of '{s}' (open_count={}, blocks={})", .{ name, self.open_counts[idx], blocks_used });
                    }
                }

                if (!is_open) {
                    // File is not open - free blocks immediately
                    self.freeBlocks(e.start_block, blocks_used);
                }

                // Clear directory entry in buffer (file becomes invisible to new opens)
                e.flags = 0;
                e.name = [_]u8{0} ** 32;
                // Note: We keep start_block and size for deferred deletion
                // They will be read from SfsFile in sfsClose
                if (!is_open) {
                    e.start_block = 0;
                    e.size = 0;
                }

                // Write back only the affected directory block
                const block_idx = idx / 4;
                const block_start = block_idx * 512;
                writeSectorAsync(self, self.superblock.root_dir_start + block_idx, dir_buf[block_start..][0..512]) catch return vfs.Error.IOError;

                // SECURITY: update file count under lock to prevent race
                // Concurrent sfsOpen with O_CREAT could cause lost updates otherwise
                {
                    const lock_held = self.alloc_lock.acquire();
                    defer lock_held.release();
                    self.superblock.file_count = std.math.sub(u32, self.superblock.file_count, 1) catch 0;
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

    // SECURITY: check mount state before any operation
    if (!self.mounted) return null;

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
            // SECURITY: skip entries with corrupted names (no null terminator)
            if (e_name.len >= 32) continue;
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

    // SECURITY: check mount state before any operation
    if (!self.mounted) return vfs.Error.IOError;

    // Normalize path (remove leading /)
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    if (!isValidFilename(name)) {
        return vfs.Error.AccessDenied;
    }
    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    // SECURITY: acquire lock for entire read-modify-write cycle
    // Prevents TOCTOU race where another thread could unlink/modify the entry
    const held = self.alloc_lock.acquire();
    defer held.release();

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
            // SECURITY: skip entries with corrupted names (no null terminator)
            if (e_name.len >= 32) continue;
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

    // SECURITY: check mount state before any operation
    if (!self.mounted) return vfs.Error.IOError;

    // Normalize path (remove leading /)
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    if (!isValidFilename(name)) {
        return vfs.Error.AccessDenied;
    }
    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    // SECURITY: acquire lock for entire read-modify-write cycle
    // Prevents TOCTOU race where another thread could unlink/modify the entry
    const held = self.alloc_lock.acquire();
    defer held.release();

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
            // SECURITY: skip entries with corrupted names (no null terminator)
            if (e_name.len >= 32) continue;
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
