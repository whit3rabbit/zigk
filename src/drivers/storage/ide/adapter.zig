// IDE Block Device Adapter
//
// Provides FileOps wrapper that translates byte-oriented syscalls (read/write)
// to sector-based IDE PIO operations. Handles alignment and partial sector access.
//
// Usage:
//   - Register `block_ops` in devfs for /dev/hda, /dev/hdb, etc.
//   - FileDescriptor.private_data encodes drive info (channel + drive number)

const std = @import("std");
const math = std.math;
const fd_mod = @import("fd");
const uapi = @import("uapi");
const heap = @import("heap");

const registers = @import("registers.zig");
const command = @import("command.zig");
const detect = @import("detect.zig");

const FileDescriptor = fd_mod.FileDescriptor;
const FileOps = fd_mod.FileOps;
const Errno = uapi.errno.Errno;

pub const SECTOR_SIZE: usize = 512;
pub const MAX_SECTORS_PER_TRANSFER: u16 = 256;

// ============================================================================
// Private Data Encoding
// ============================================================================

/// Encode drive info into private_data pointer
/// Format: bits 0-3 = channel (0=primary, 1=secondary), bit 4 = drive (0=master, 1=slave)
/// bits 5-7 = flags (bit 5 = supports_lba48)
pub const DriveRef = packed struct {
    channel: u1,
    drive: u1,
    supports_lba48: bool,
    _reserved: u5 = 0,

    pub fn encode(self: DriveRef) ?*anyopaque {
        const val: u8 = @bitCast(self);
        return @ptrFromInt(@as(usize, val));
    }

    pub fn decode(ptr: ?*anyopaque) DriveRef {
        const val: u8 = @truncate(@intFromPtr(ptr));
        return @bitCast(val);
    }
};

// ============================================================================
// Channel Access
// ============================================================================

/// Get channel from drive reference
fn getChannel(ref: DriveRef) registers.Channel {
    return if (ref.channel == 0)
        registers.Channel.primary()
    else
        registers.Channel.secondary();
}

// ============================================================================
// Block Device Operations
// ============================================================================

/// Block device operations for IDE disks
pub const block_ops = FileOps{
    .read = blockRead,
    .write = blockWrite,
    .close = blockClose,
    .seek = blockSeek,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

/// Read from block device
/// Handles misaligned reads by using bounce buffer for partial sectors
fn blockRead(fd: *FileDescriptor, buf: []u8) isize {
    if (buf.len == 0) return 0;

    const ref = DriveRef.decode(fd.private_data);
    const channel = getChannel(ref);

    const pos = fd.position;
    const start_lba = pos / SECTOR_SIZE;
    const start_offset = pos % SECTOR_SIZE;

    // Calculate how many sectors we need to read (checked arithmetic)
    const end_pos = math.add(u64, pos, buf.len) catch {
        return Errno.EINVAL.toReturn();
    };
    const end_lba = math.add(u64, end_pos, SECTOR_SIZE - 1) catch {
        return Errno.EINVAL.toReturn();
    } / SECTOR_SIZE;

    if (end_lba < start_lba) {
        return Errno.EINVAL.toReturn();
    }
    const sector_count_u64 = end_lba - start_lba;

    if (sector_count_u64 > MAX_SECTORS_PER_TRANSFER) {
        return Errno.EINVAL.toReturn();
    }

    const sector_count: u16 = @intCast(sector_count_u64);

    // Check if aligned read (fast path)
    if (start_offset == 0 and buf.len % SECTOR_SIZE == 0) {
        _ = command.readSectorsPio(
            channel,
            ref.drive,
            start_lba,
            sector_count,
            buf,
            ref.supports_lba48,
        ) catch {
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

    // Zero-initialize bounce buffer (security: prevent info leaks)
    @memset(bounce, 0);

    _ = command.readSectorsPio(
        channel,
        ref.drive,
        start_lba,
        sector_count,
        bounce,
        ref.supports_lba48,
    ) catch {
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

    const ref = DriveRef.decode(fd.private_data);
    const channel = getChannel(ref);

    const pos = fd.position;
    const start_lba = pos / SECTOR_SIZE;
    const start_offset = pos % SECTOR_SIZE;

    // Checked arithmetic
    const end_pos = math.add(u64, pos, buf.len) catch {
        return Errno.EINVAL.toReturn();
    };
    const end_lba = math.add(u64, end_pos, SECTOR_SIZE - 1) catch {
        return Errno.EINVAL.toReturn();
    } / SECTOR_SIZE;

    if (end_lba < start_lba) {
        return Errno.EINVAL.toReturn();
    }
    const sector_count_u64 = end_lba - start_lba;

    if (sector_count_u64 > MAX_SECTORS_PER_TRANSFER) {
        return Errno.EINVAL.toReturn();
    }

    const sector_count: u16 = @intCast(sector_count_u64);

    // Check if aligned write (fast path)
    if (start_offset == 0 and buf.len % SECTOR_SIZE == 0) {
        // Need mutable buffer for the command
        const allocator = heap.allocator();
        const write_buf = allocator.alloc(u8, buf.len) catch {
            return Errno.ENOMEM.toReturn();
        };
        defer allocator.free(write_buf);
        @memcpy(write_buf, buf);

        _ = command.writeSectorsPio(
            channel,
            ref.drive,
            start_lba,
            sector_count,
            write_buf,
            ref.supports_lba48,
        ) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += buf.len;
        return @intCast(buf.len);
    }

    // Misaligned write - need read-modify-write
    const bounce_size = @as(usize, sector_count) * SECTOR_SIZE;
    const allocator = heap.allocator();
    const bounce = allocator.alloc(u8, bounce_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer allocator.free(bounce);

    // Zero-initialize first
    @memset(bounce, 0);

    // Read existing data
    _ = command.readSectorsPio(
        channel,
        ref.drive,
        start_lba,
        sector_count,
        bounce,
        ref.supports_lba48,
    ) catch {
        return Errno.EIO.toReturn();
    };

    // Modify with new data
    const copy_start = @as(usize, @intCast(start_offset));
    const copy_len = @min(buf.len, bounce_size - copy_start);
    @memcpy(bounce[copy_start .. copy_start + copy_len], buf[0..copy_len]);

    // Write back
    _ = command.writeSectorsPio(
        channel,
        ref.drive,
        start_lba,
        sector_count,
        bounce,
        ref.supports_lba48,
    ) catch {
        return Errno.EIO.toReturn();
    };

    fd.position += copy_len;
    return @intCast(copy_len);
}

/// Seek in block device
fn blockSeek(fd: *FileDescriptor, offset: i64, whence: u32) isize {
    const SEEK_SET = 0;
    const SEEK_CUR = 1;
    const SEEK_END = 2;

    // TODO: Get actual drive size from controller
    // For now, allow seeking to any position
    const new_pos: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => @as(i64, @intCast(fd.position)) + offset,
        SEEK_END => {
            // Would need drive size here
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

/// Close block device
fn blockClose(fd: *FileDescriptor) isize {
    // Flush cache before close
    const ref = DriveRef.decode(fd.private_data);
    const channel = getChannel(ref);

    command.flushCache(channel, ref.drive, ref.supports_lba48) catch {
        // Ignore flush errors on close
    };

    fd.private_data = null;
    return 0;
}
