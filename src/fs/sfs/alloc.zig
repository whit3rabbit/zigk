const std = @import("std");
const t = @import("types.zig");
const sfs_io = @import("io.zig");
const ahci = @import("ahci");
const io = @import("io");
const heap = @import("heap");
const console = @import("console");
const hal = @import("hal");

/// Check if running on emulator platform (QEMU TCG, unknown hypervisor)
/// On emulators, PCI interrupts may not work correctly, so use sync I/O
fn isEmulatorPlatform() bool {
    const hv = hal.hypervisor.getHypervisor();
    return hv == .qemu_tcg or hv == .unknown;
}

/// Load all bitmap blocks in a single batched async I/O operation
/// On emulators, uses sync I/O since PCI interrupts may not work
pub fn loadBitmapBatch(self: *t.SFS) ![]u8 {
    const alloc = heap.allocator();
    const bitmap_size = self.superblock.bitmap_blocks * t.SECTOR_SIZE;
    const bitmap_buf = alloc.alloc(u8, bitmap_size) catch return error.ENOMEM;

    // On emulators, use sync I/O (read sector by sector)
    if (isEmulatorPlatform()) {
        const controller = ahci.getController() orelse {
            alloc.free(bitmap_buf);
            return error.IOError;
        };
        var lba = self.superblock.bitmap_start;
        var offset: usize = 0;
        var remaining = self.superblock.bitmap_blocks;
        while (remaining > 0) : ({
            lba += 1;
            offset += 512;
            remaining -= 1;
        }) {
            controller.readSectors(self.port_num, lba, 1, bitmap_buf[offset..][0..512]) catch {
                alloc.free(bitmap_buf);
                return error.IOError;
            };
        }
        return bitmap_buf;
    }

    // On real hardware, use async I/O with IRQ completion
    const req = io.allocRequest(.disk_read) orelse {
        alloc.free(bitmap_buf);
        return error.IOError;
    };
    defer io.freeRequest(req);

    const buf_phys = ahci.adapter.blockReadAsync(self.port_num, self.superblock.bitmap_start, @truncate(self.superblock.bitmap_blocks), req) catch |err| {
        alloc.free(bitmap_buf);
        console.err("SFS: Failed to submit bitmap batch read: {}", .{err});
        return error.IOError;
    };
    defer ahci.adapter.freeDmaBuffer(buf_phys, bitmap_size);

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => |bytes| {
            if (bytes < bitmap_size) {
                alloc.free(bitmap_buf);
                return error.IOError;
            }
            hal.mmio.memoryBarrier();
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

/// Load bitmap into pre-allocated buffer (avoids heap allocation)
/// On emulators, uses sync I/O since PCI interrupts may not work
pub fn loadBitmapIntoCached(self: *t.SFS, dest: []u8) !void {
    const bitmap_size = self.superblock.bitmap_blocks * t.SECTOR_SIZE;
    if (dest.len < bitmap_size) return error.IOError;

    // On emulators, use sync I/O (read sector by sector)
    if (isEmulatorPlatform()) {
        const controller = ahci.getController() orelse return error.IOError;
        var lba = self.superblock.bitmap_start;
        var offset: usize = 0;
        var remaining = self.superblock.bitmap_blocks;
        while (remaining > 0) : ({
            lba += 1;
            offset += 512;
            remaining -= 1;
        }) {
            controller.readSectors(self.port_num, lba, 1, dest[offset..][0..512]) catch return error.IOError;
        }
        return;
    }

    // On real hardware, use async I/O with IRQ completion
    const req = io.allocRequest(.disk_read) orelse return error.IOError;
    defer io.freeRequest(req);

    const buf_phys = ahci.adapter.blockReadAsync(self.port_num, self.superblock.bitmap_start, @truncate(self.superblock.bitmap_blocks), req) catch return error.IOError;
    defer ahci.adapter.freeDmaBuffer(buf_phys, bitmap_size);

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => |bytes| {
            if (bytes < bitmap_size) return error.IOError;
            hal.mmio.memoryBarrier();
            ahci.adapter.copyFromDmaBuffer(buf_phys, dest[0..bitmap_size]);
        },
        .err, .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Allocate a free block from the bitmap
pub fn allocateBlock(self: *t.SFS) !u32 {
    const held = self.alloc_lock.acquire();
    defer held.release();

    var using_cache = false;
    const bitmap_buf = if (self.bitmap_cache) |cache| blk: {
        if (!self.bitmap_cache_valid) {
            loadBitmapIntoCached(self, cache) catch return error.IOError;
            self.bitmap_cache_valid = true;
        }
        using_cache = true;
        break :blk cache;
    } else blk: {
        break :blk loadBitmapBatch(self) catch return error.IOError;
    };

    defer if (!using_cache) heap.allocator().free(bitmap_buf);

    for (bitmap_buf, 0..) |byte, global_byte_idx| {
        if (byte != 0xFF) {
            var bit: u3 = 0;
            while (bit < 8) : (bit += 1) {
                if ((byte & (@as(u8, 1) << bit)) == 0) {
                    bitmap_buf[global_byte_idx] |= (@as(u8, 1) << bit);

                    const bitmap_block_idx = global_byte_idx / 512;
                    const lba = self.superblock.bitmap_start + @as(u32, @truncate(bitmap_block_idx));
                    
                    sfs_io.writeSector(self.device_fd, lba, bitmap_buf[bitmap_block_idx * 512 ..][0..512]) catch return error.IOError;

                    const bitmap_offset = @as(u32, @truncate(global_byte_idx)) * 8;
                    const bit_offset = @as(u32, bit);
                    const total_offset = std.math.add(u32, bitmap_offset, bit_offset) catch return error.IOError;
                    const block_num = std.math.add(u32, self.superblock.data_start, total_offset) catch return error.IOError;

                    if (block_num >= self.superblock.total_blocks) {
                        bitmap_buf[global_byte_idx] &= ~(@as(u8, 1) << bit);
                        return error.ENOSPC;
                    }

                    const sb_free = self.superblock.free_blocks;
                    self.superblock.free_blocks = blk: {
                        if (sb_free > 0) break :blk sb_free - 1;
                        break :blk 0;
                    };
                    sfs_io.updateSuperblock(self) catch return error.IOError;

                    return block_num;
                }
            }
        }
    }

    return error.ENOSPC;
}

/// Free a block back to the bitmap
pub fn freeBlock(self: *t.SFS, block_num: u32) !void {
    if (block_num < self.superblock.data_start) return error.InvalidBlock;

    const held = self.alloc_lock.acquire();
    defer held.release();

    const rel_block = block_num - self.superblock.data_start;
    const byte_idx = rel_block / 8;
    const bit_idx: u3 = @truncate(rel_block % 8);
    
    const bitmap_block_idx = byte_idx / 512;
    const byte_in_block = byte_idx % 512;
    const lba = self.superblock.bitmap_start + bitmap_block_idx;

    var sector_buf: [512]u8 = undefined;
    sfs_io.readSector(self.device_fd, lba, &sector_buf) catch return error.IOError;

    sector_buf[byte_in_block] &= ~(@as(u8, 1) << bit_idx);
    sfs_io.writeSector(self.device_fd, lba, &sector_buf) catch return error.IOError;

    if (self.bitmap_cache) |cache| {
        if (self.bitmap_cache_valid) {
            cache[byte_idx] &= ~(@as(u8, 1) << bit_idx);
        }
    }

    self.superblock.free_blocks = std.math.add(u32, self.superblock.free_blocks, 1) catch std.math.maxInt(u32);
    sfs_io.updateSuperblock(self) catch return error.IOError;
}

/// Free multiple contiguous blocks
pub fn freeBlocks(self: *t.SFS, start_block: u32, count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const block = std.math.add(u32, start_block, i) catch break;
        freeBlock(self, block) catch |err| {
            console.warn("SFS: Failed to free block {}: {}", .{ block, err });
        };
    }
}

/// Validate filename to prevent path traversal and injection attacks
pub fn isValidFilename(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOf(u8, name, "..")) |_| return false;
    if (std.mem.indexOf(u8, name, "/")) |_| return false;
    if (std.mem.indexOf(u8, name, "\\")) |_| return false;
    for (name) |c| {
        if (c < 0x20 or c == 0x7F) return false;
    }
    return true;
}

/// Validate superblock fields to prevent malicious disk attacks
pub fn validateSuperblock(sb: *const t.Superblock) bool {
    if (sb.block_size != t.SECTOR_SIZE) {
        console.warn("SFS: Invalid block_size {}", .{sb.block_size});
        return false;
    }

    const max_blocks: u32 = 4 * 1024 * 1024;
    if (sb.total_blocks == 0 or sb.total_blocks > max_blocks) {
        console.warn("SFS: Invalid total_blocks {}", .{sb.total_blocks});
        return false;
    }

    if (sb.bitmap_start != 1) {
        console.warn("SFS: Invalid bitmap_start {}", .{sb.bitmap_start});
        return false;
    }

    const MAX_BITMAP_BLOCKS: u32 = 16;
    if (sb.bitmap_blocks == 0 or sb.bitmap_blocks > MAX_BITMAP_BLOCKS) {
        console.warn("SFS: Invalid bitmap_blocks {} (max={})", .{ sb.bitmap_blocks, MAX_BITMAP_BLOCKS });
        return false;
    }

    const expected_root_start = sb.bitmap_start + sb.bitmap_blocks;
    if (sb.root_dir_start != expected_root_start) {
        console.warn("SFS: Invalid root_dir_start {},expected {}", .{ sb.root_dir_start, expected_root_start });
        return false;
    }

    const expected_data_start = sb.root_dir_start + t.ROOT_DIR_BLOCKS;
    if (sb.data_start != expected_data_start) {
        console.warn("SFS: Invalid data_start {},expected {}", .{ sb.data_start, expected_data_start });
        return false;
    }

    if (sb.data_start >= sb.total_blocks) {
        console.warn("SFS: data_start {} >= total_blocks {}", .{ sb.data_start, sb.total_blocks });
        return false;
    }

    const max_data_blocks = sb.total_blocks - sb.data_start;
    if (sb.free_blocks > max_data_blocks) {
        console.warn("SFS: free_blocks {} > max_data_blocks {}", .{ sb.free_blocks, max_data_blocks });
        return false;
    }

    if (sb.file_count > t.MAX_FILES) {
        console.warn("SFS: file_count {} > MAX_FILES {}", .{ sb.file_count, t.MAX_FILES });
        return false;
    }

    if (sb.next_free_block > sb.total_blocks) {
        console.warn("SFS: next_free_block {} > total_blocks {}", .{ sb.next_free_block, sb.total_blocks });
        return false;
    }

    return true;
}
