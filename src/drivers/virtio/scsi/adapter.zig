// VirtIO-SCSI Block Device Adapter
//
// Provides FileOps wrapper that translates byte-oriented syscalls (read/write)
// to block-based SCSI operations. Handles alignment and partial block access.
//
// Usage:
//   - Register `block_ops` in devfs for /dev/vda, /dev/vdb, etc.
//   - FileDescriptor.private_data stores the LUN index as usize

const std = @import("std");
const math = std.math;
const root = @import("root.zig");
const fd_mod = @import("fd");
const uapi = @import("uapi");
const heap = @import("heap");
const console = @import("console");

const FileDescriptor = fd_mod.FileDescriptor;
const FileOps = fd_mod.FileOps;
const Errno = uapi.errno.Errno;

/// Maximum blocks per transfer
const MAX_BLOCKS_PER_TRANSFER: usize = 256;

/// Block device operations for VirtIO-SCSI disks
pub const block_ops = FileOps{
    .read = blockRead,
    .write = blockWrite,
    .close = blockClose,
    .seek = blockSeek,
    .stat = blockStat,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

/// Read from block device
/// Handles misaligned reads by using bounce buffer for partial blocks
fn blockRead(fd: *FileDescriptor, buf: []u8) isize {
    if (buf.len == 0) return 0;

    const controller = root.getController() orelse {
        return Errno.EIO.toReturn();
    };

    // Get LUN index from private_data
    const lun_idx: u8 = @intCast(@intFromPtr(fd.private_data) & 0xFF);

    // Get LUN info
    const lun_info = controller.getLun(lun_idx) orelse {
        return Errno.ENODEV.toReturn();
    };

    if (!lun_info.active) {
        return Errno.ENODEV.toReturn();
    }

    const block_size = lun_info.block_size;
    if (block_size == 0) {
        return Errno.EIO.toReturn();
    }

    const pos = fd.position;

    // Check EOF
    if (pos >= lun_info.capacity_bytes) {
        return 0; // EOF
    }

    // Calculate block range (checked arithmetic)
    const start_block = pos / block_size;
    const start_offset = pos % block_size;

    const end_pos = math.add(u64, pos, buf.len) catch {
        console.warn("VirtIO-SCSI read: overflow in end_pos calculation (pos={}, buf.len={})", .{pos, buf.len});
        return Errno.EINVAL.toReturn();
    };
    const end_pos_clamped = @min(end_pos, lun_info.capacity_bytes);

    // Calculate end block (exclusive): for bytes [start, end), we need blocks [start_block, end_block)
    // If end_pos lands exactly on a block boundary, don't round up
    // Formula: end_block = ceil(end_pos / block_size) but only round up if there's a remainder
    const end_block_raw = end_pos_clamped / block_size;
    const end_block_remainder = end_pos_clamped % block_size;
    const end_block = if (end_block_remainder > 0) end_block_raw + 1 else end_block_raw;

    // Underflow check
    if (end_block < start_block) {
        console.warn("VirtIO-SCSI read: underflow (end_block={} < start_block={})", .{end_block, start_block});
        return Errno.EINVAL.toReturn();
    }
    const block_count_u64 = end_block - start_block;

    // Limit to max blocks per transfer
    if (block_count_u64 > MAX_BLOCKS_PER_TRANSFER) {
        console.warn("VirtIO-SCSI read: too many blocks ({} > MAX={})", .{block_count_u64, MAX_BLOCKS_PER_TRANSFER});
        return Errno.EINVAL.toReturn();
    }

    console.info("VirtIO-SCSI read: pos={}, buf.len={}, lun_cap={}, start_block={}, end_block={}, block_count={}", .{
        pos, buf.len, lun_info.capacity_bytes, start_block, end_block, block_count_u64
    });

    const block_count: u32 = @intCast(block_count_u64);

    // Check if aligned read (fast path)
    if (start_offset == 0 and buf.len % block_size == 0 and buf.len <= lun_info.capacity_bytes - pos) {
        const bytes = controller.readBlocks(lun_idx, start_block, block_count, buf) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += bytes;
        return @intCast(bytes);
    }

    // Misaligned read - need bounce buffer
    const bounce_size = math.mul(usize, block_count, block_size) catch {
        return Errno.EINVAL.toReturn();
    };
    const allocator = heap.allocator();
    const bounce = allocator.alloc(u8, bounce_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer allocator.free(bounce);

    _ = controller.readBlocks(lun_idx, start_block, block_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    // Copy relevant portion to user buffer
    const copy_start = @as(usize, @intCast(start_offset));
    const available = bounce_size - copy_start;
    const desired = @min(buf.len, lun_info.capacity_bytes - pos);
    const copy_len = @min(desired, available);

    @memcpy(buf[0..copy_len], bounce[copy_start .. copy_start + copy_len]);

    fd.position += copy_len;
    return @intCast(copy_len);
}

/// Write to block device
/// Handles misaligned writes with read-modify-write for partial blocks
fn blockWrite(fd: *FileDescriptor, buf: []const u8) isize {
    if (buf.len == 0) return 0;

    const controller = root.getController() orelse {
        return Errno.EIO.toReturn();
    };

    const lun_idx: u8 = @intCast(@intFromPtr(fd.private_data) & 0xFF);

    const lun_info = controller.getLun(lun_idx) orelse {
        return Errno.ENODEV.toReturn();
    };

    if (!lun_info.active) {
        return Errno.ENODEV.toReturn();
    }

    const block_size = lun_info.block_size;
    if (block_size == 0) {
        return Errno.EIO.toReturn();
    }

    const pos = fd.position;

    // Check EOF
    if (pos >= lun_info.capacity_bytes) {
        return Errno.ENOSPC.toReturn(); // No space left
    }

    // Calculate block range (checked arithmetic)
    const start_block = pos / block_size;
    const start_offset = pos % block_size;

    const end_pos = math.add(u64, pos, buf.len) catch {
        return Errno.EINVAL.toReturn();
    };
    const end_pos_clamped = @min(end_pos, lun_info.capacity_bytes);

    // Calculate end block (exclusive): ceil(end_pos / block_size) only if remainder
    const end_block_raw = end_pos_clamped / block_size;
    const end_block_remainder = end_pos_clamped % block_size;
    const end_block = if (end_block_remainder > 0) end_block_raw + 1 else end_block_raw;

    if (end_block < start_block) {
        return Errno.EINVAL.toReturn();
    }
    const block_count_u64 = end_block - start_block;

    if (block_count_u64 > MAX_BLOCKS_PER_TRANSFER) {
        return Errno.EINVAL.toReturn();
    }

    const block_count: u32 = @intCast(block_count_u64);

    // Check if aligned write (fast path)
    if (start_offset == 0 and buf.len % block_size == 0 and buf.len <= lun_info.capacity_bytes - pos) {
        const bytes = controller.writeBlocks(lun_idx, start_block, block_count, buf) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += bytes;
        return @intCast(bytes);
    }

    // Misaligned write - read-modify-write
    const bounce_size = math.mul(usize, block_count, block_size) catch {
        return Errno.EINVAL.toReturn();
    };
    const allocator = heap.allocator();
    const bounce = allocator.alloc(u8, bounce_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer allocator.free(bounce);

    // Read existing blocks
    _ = controller.readBlocks(lun_idx, start_block, block_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    // Modify with user data
    const copy_start = @as(usize, @intCast(start_offset));
    const available = bounce_size - copy_start;
    const desired = @min(buf.len, lun_info.capacity_bytes - pos);
    const copy_len = @min(desired, available);

    @memcpy(bounce[copy_start .. copy_start + copy_len], buf[0..copy_len]);

    // Write back
    _ = controller.writeBlocks(lun_idx, start_block, block_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    fd.position += copy_len;
    return @intCast(copy_len);
}

/// Close block device
fn blockClose(fd: *FileDescriptor) isize {
    // Flush cache on close for data integrity
    if (root.getController()) |controller| {
        const lun_idx: u8 = @intCast(@intFromPtr(fd.private_data) & 0xFF);
        const lun_info = controller.getLun(lun_idx);
        if (lun_info) |lun| {
            // Send SYNCHRONIZE CACHE command
            var cdb: [root.config.Limits.MAX_CDB_SIZE]u8 = undefined;
            root.command.buildSyncCache10(&cdb, 0, 0, false);
            _ = controller.executeCommandSync(lun.target, lun.lun, &cdb, null, null) catch {};
        }
    }
    return 0;
}

/// Seek in block device
fn blockSeek(fd: *FileDescriptor, offset: i64, whence: u32) isize {
    const SEEK_SET: u32 = 0;
    const SEEK_CUR: u32 = 1;
    const SEEK_END: u32 = 2;

    const controller = root.getController() orelse {
        return Errno.EIO.toReturn();
    };

    const lun_idx: u8 = @intCast(@intFromPtr(fd.private_data) & 0xFF);
    const lun_info = controller.getLun(lun_idx) orelse {
        return Errno.ENODEV.toReturn();
    };

    const disk_size: i64 = @intCast(lun_info.capacity_bytes);

    const new_pos: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => @as(i64, @intCast(fd.position)) + offset,
        SEEK_END => disk_size + offset,
        else => return Errno.EINVAL.toReturn(),
    };

    if (new_pos < 0) {
        return Errno.EINVAL.toReturn();
    }

    fd.position = @intCast(new_pos);
    return @intCast(new_pos);
}

/// Get file status
fn blockStat(fd: *FileDescriptor, stat_buf_ptr: *anyopaque) isize {
    const controller = root.getController() orelse {
        return Errno.EIO.toReturn();
    };

    const lun_idx: u8 = @intCast(@intFromPtr(fd.private_data) & 0xFF);
    const lun_info = controller.getLun(lun_idx) orelse {
        return Errno.ENODEV.toReturn();
    };

    const stat_buf: *uapi.stat.Stat = @ptrCast(@alignCast(stat_buf_ptr));

    // Clear stat buffer
    @memset(std.mem.asBytes(stat_buf), 0);

    // Fill in block device info
    stat_buf.mode = 0o060000; // S_IFBLK
    stat_buf.size = @intCast(lun_info.capacity_bytes);
    stat_buf.blksize = @intCast(lun_info.block_size);
    stat_buf.blocks = @intCast(lun_info.total_blocks);

    return 0;
}

// ============================================================================
// DMA Buffer Helpers
// ============================================================================

/// Allocate a DMA buffer for block I/O
pub fn allocDmaBuffer(size: usize) ?[]u8 {
    const controller = root.getController() orelse return null;

    const dma_buf = @import("dma").allocBuffer(controller.bdf, size, true) catch return null;
    return @as([*]u8, @ptrFromInt(dma_buf.getVirt()))[0..size];
}

/// Free a DMA buffer
pub fn freeDmaBuffer(buf: []u8) void {
    _ = buf;
    // Note: In a full implementation, we'd track the DmaBuffer struct
    // For now, this is a placeholder - the buffer will be freed when
    // the controller is destroyed
}
