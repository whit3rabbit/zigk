// AHCI Block Device Adapter
//
// Provides FileOps wrapper that translates byte-oriented syscalls (read/write)
// to sector-based AHCI operations. Handles alignment and partial sector access.
//
// Usage:
//   - Register `block_ops` in devfs for /dev/sda
//   - FileDescriptor.private_data stores the port number as usize

const std = @import("std");
const root = @import("root.zig");
const fd_mod = @import("fd");
const uapi = @import("uapi");
const heap = @import("heap");

const FileDescriptor = fd_mod.FileDescriptor;
const FileOps = fd_mod.FileOps;
const Errno = uapi.errno.Errno;

const SECTOR_SIZE = root.SECTOR_SIZE; // 512

/// Block device operations for AHCI disks
pub const block_ops = FileOps{
    .read = blockRead,
    .write = blockWrite,
    .close = blockClose,
    .seek = blockSeek,
    .stat = null,
    .ioctl = null,
    .mmap = null,
};

/// Read from block device
/// Handles misaligned reads by using bounce buffer for partial sectors
fn blockRead(fd: *FileDescriptor, buf: []u8) isize {
    if (buf.len == 0) return 0;

    const controller = root.getController() orelse {
        return Errno.EIO.toReturn();
    };

    // Get port number from private_data
    const port_num: u5 = @intCast(@intFromPtr(fd.private_data) & 0x1F);

    const pos = fd.position;
    const start_lba = pos / SECTOR_SIZE;
    const start_offset = pos % SECTOR_SIZE;

    // Calculate how many sectors we need to read
    const end_pos = pos + buf.len;
    const end_lba = (end_pos + SECTOR_SIZE - 1) / SECTOR_SIZE;
    const sector_count_u64 = end_lba - start_lba;

    // Limit to max sectors per transfer
    if (sector_count_u64 > root.MAX_SECTORS_PER_TRANSFER) {
        return Errno.EINVAL.toReturn();
    }

    const sector_count: u16 = @intCast(sector_count_u64);

    // Check if aligned read (fast path)
    if (start_offset == 0 and buf.len % SECTOR_SIZE == 0) {
        controller.readSectors(port_num, start_lba, sector_count, buf) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += buf.len;
        return @intCast(buf.len);
    }

    // Misaligned read - need bounce buffer
    const bounce_size = @as(usize, sector_count) * SECTOR_SIZE;
    const allocator = heap.allocator();
    const bounce = allocator.alloc(u8, bounce_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer allocator.free(bounce);

    controller.readSectors(port_num, start_lba, sector_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    // Copy relevant portion to user buffer
    const copy_start = @as(usize, @intCast(start_offset));
    const copy_len = @min(buf.len, bounce_size - copy_start);
    @memcpy(buf[0..copy_len], bounce[copy_start .. copy_start + copy_len]);

    fd.position += copy_len;
    return @intCast(copy_len);
}

/// Write to block device
/// Handles misaligned writes with read-modify-write for partial sectors
fn blockWrite(fd: *FileDescriptor, buf: []const u8) isize {
    if (buf.len == 0) return 0;

    const controller = root.getController() orelse {
        return Errno.EIO.toReturn();
    };

    const port_num: u5 = @intCast(@intFromPtr(fd.private_data) & 0x1F);

    const pos = fd.position;
    const start_lba = pos / SECTOR_SIZE;
    const start_offset = pos % SECTOR_SIZE;

    const end_pos = pos + buf.len;
    const end_lba = (end_pos + SECTOR_SIZE - 1) / SECTOR_SIZE;
    const sector_count_u64 = end_lba - start_lba;

    if (sector_count_u64 > root.MAX_SECTORS_PER_TRANSFER) {
        return Errno.EINVAL.toReturn();
    }

    const sector_count: u16 = @intCast(sector_count_u64);

    // Check if aligned write (fast path)
    if (start_offset == 0 and buf.len % SECTOR_SIZE == 0) {
        controller.writeSectors(port_num, start_lba, sector_count, buf) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += buf.len;
        return @intCast(buf.len);
    }

    // Misaligned write - read-modify-write
    const bounce_size = @as(usize, sector_count) * SECTOR_SIZE;
    const allocator = heap.allocator();
    const bounce = allocator.alloc(u8, bounce_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer allocator.free(bounce);

    // Read existing sectors
    controller.readSectors(port_num, start_lba, sector_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    // Modify with user data
    const copy_start = @as(usize, @intCast(start_offset));
    const copy_len = @min(buf.len, bounce_size - copy_start);
    @memcpy(bounce[copy_start .. copy_start + copy_len], buf[0..copy_len]);

    // Write back
    controller.writeSectors(port_num, start_lba, sector_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    fd.position += copy_len;
    return @intCast(copy_len);
}

/// Close block device
fn blockClose(fd: *FileDescriptor) isize {
    // Flush cache on close for data integrity
    if (root.getController()) |controller| {
        const port_num: u5 = @intCast(@intFromPtr(fd.private_data) & 0x1F);
        controller.flushCache(port_num) catch {};
    }
    return 0;
}

/// Seek in block device
fn blockSeek(fd: *FileDescriptor, offset: i64, whence: u32) isize {
    const SEEK_SET: u32 = 0;
    const SEEK_CUR: u32 = 1;
    const SEEK_END: u32 = 2;

    // Get disk size (would need to query from AHCI, for now use position-based)
    // TODO: Add getCapacity() to AHCI driver and use it here
    const new_pos: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => @as(i64, @intCast(fd.position)) + offset,
        SEEK_END => {
            // For now, don't support SEEK_END without disk size
            return Errno.EINVAL.toReturn();
        },
        else => return Errno.EINVAL.toReturn(),
    };

    if (new_pos < 0) {
        return Errno.EINVAL.toReturn();
    }

    fd.position = @intCast(new_pos);
    return @intCast(fd.position);
}

/// Create a block device FileDescriptor for a specific port
/// Used when opening /dev/sda, /dev/sdb, etc.
pub fn createBlockFd(port_num: u5, flags: u32) !*FileDescriptor {
    // Verify port is active
    const controller = root.getController() orelse return error.NoController;
    const port = controller.getPort(port_num) orelse return error.PortNotFound;
    _ = port;

    // Store port number in private_data (as usize cast to pointer)
    const private: ?*anyopaque = @ptrFromInt(@as(usize, port_num));
    return fd_mod.createFd(&block_ops, flags, private);
}
