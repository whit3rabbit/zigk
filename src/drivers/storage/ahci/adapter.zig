// AHCI Block Device Adapter
//
// Provides FileOps wrapper that translates byte-oriented syscalls (read/write)
// to sector-based AHCI operations. Handles alignment and partial sector access.
//
// Usage:
//   - Register `block_ops` in devfs for /dev/sda
//   - FileDescriptor.private_data stores the port number as usize

const std = @import("std");
const math = std.math;
const root = @import("root.zig");
const fd_mod = @import("fd");
const uapi = @import("uapi");
const heap = @import("heap");
const io = @import("io");
const pmm = @import("pmm");
const hal = @import("hal");

const FileDescriptor = fd_mod.FileDescriptor;
const FileOps = fd_mod.FileOps;
const Errno = uapi.errno.Errno;
const IoRequest = io.IoRequest;
const IoOpType = io.IoOpType;

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
    .poll = null,
    .truncate = null,
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

    // Calculate how many sectors we need to read (checked arithmetic to prevent overflow)
    const end_pos = math.add(u64, pos, buf.len) catch {
        return Errno.EINVAL.toReturn();
    };
    const end_lba = math.add(u64, end_pos, SECTOR_SIZE - 1) catch {
        return Errno.EINVAL.toReturn();
    } / SECTOR_SIZE;

    // Underflow check: end_lba must be >= start_lba
    if (end_lba < start_lba) {
        return Errno.EINVAL.toReturn();
    }
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

    // Checked arithmetic to prevent overflow
    const end_pos = math.add(u64, pos, buf.len) catch {
        return Errno.EINVAL.toReturn();
    };
    const end_lba = math.add(u64, end_pos, SECTOR_SIZE - 1) catch {
        return Errno.EINVAL.toReturn();
    } / SECTOR_SIZE;

    // Underflow check: end_lba must be >= start_lba
    if (end_lba < start_lba) {
        return Errno.EINVAL.toReturn();
    }
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

// ============================================================================
// Async Block I/O API
// ============================================================================

/// Error type for async block operations
pub const AsyncBlockError = error{
    NoController,
    PortNotFound,
    InvalidParameter,
    AllocationFailed,
    PortNotConnected,
};

/// Read sectors asynchronously (non-blocking)
/// Allocates a DMA buffer and submits the request to AHCI.
/// The IoRequest will be completed by the AHCI IRQ handler.
/// Caller must free the DMA buffer after the request completes.
///
/// Returns the physical address of the allocated buffer.
pub fn blockReadAsync(
    port_num: u5,
    lba: u64,
    sector_count: u16,
    request: *IoRequest,
) AsyncBlockError!u64 {
    const controller = root.getController() orelse return error.NoController;

    if (sector_count == 0 or sector_count > root.MAX_SECTORS_PER_TRANSFER) {
        return error.InvalidParameter;
    }

    // Allocate DMA buffer (physically contiguous pages)
    const pages_needed = (@as(usize, sector_count) * SECTOR_SIZE + 4095) / 4096;
    const buf_phys = pmm.allocZeroedPages(pages_needed) orelse {
        return error.AllocationFailed;
    };

    // Check 64-bit capability - controller may not support addresses > 4GB
    if (!controller.cap.s64a and buf_phys > 0xFFFFFFFF) {
        pmm.freePages(buf_phys, pages_needed);
        return error.AllocationFailed;
    }

    // Store buffer info in request for cleanup
    request.buf_ptr = buf_phys;
    request.buf_len = @as(usize, sector_count) * SECTOR_SIZE;

    // Submit async read
    controller.readSectorsAsync(port_num, lba, sector_count, buf_phys, request) catch |err| {
        pmm.freePages(buf_phys, pages_needed);
        return switch (err) {
            root.AhciError.PortNotConnected => error.PortNotConnected,
            root.AhciError.InvalidParameter => error.InvalidParameter,
            root.AhciError.AllocationFailed => error.AllocationFailed,
            else => error.AllocationFailed,
        };
    };

    return buf_phys;
}

/// Write sectors asynchronously (non-blocking)
/// Data must already be in a DMA-accessible buffer at buf_phys.
/// The IoRequest will be completed by the AHCI IRQ handler.
pub fn blockWriteAsync(
    port_num: u5,
    lba: u64,
    sector_count: u16,
    buf_phys: u64,
    request: *IoRequest,
) AsyncBlockError!void {
    const controller = root.getController() orelse return error.NoController;

    if (sector_count == 0 or sector_count > root.MAX_SECTORS_PER_TRANSFER) {
        return error.InvalidParameter;
    }

    // Check 64-bit capability - controller may not support addresses > 4GB
    if (!controller.cap.s64a and buf_phys > 0xFFFFFFFF) {
        return error.InvalidParameter;
    }

    // Store buffer info in request
    request.buf_ptr = buf_phys;
    request.buf_len = @as(usize, sector_count) * SECTOR_SIZE;

    // Submit async write
    controller.writeSectorsAsync(port_num, lba, sector_count, buf_phys, request) catch |err| {
        return switch (err) {
            root.AhciError.PortNotConnected => error.PortNotConnected,
            root.AhciError.InvalidParameter => error.InvalidParameter,
            root.AhciError.AllocationFailed => error.AllocationFailed,
            else => error.AllocationFailed,
        };
    };
}

/// Copy data from DMA buffer to user buffer after async read completes
/// Call this after the IoRequest completes successfully.
pub fn copyFromDmaBuffer(buf_phys: u64, dest: []u8) void {
    const src: [*]u8 = @ptrCast(hal.paging.physToVirt(buf_phys));
    @memcpy(dest, src[0..dest.len]);
}

/// Copy data from user buffer to DMA buffer before async write
/// Call this before submitting blockWriteAsync.
pub fn copyToDmaBuffer(buf_phys: u64, src: []const u8) void {
    const dest: [*]u8 = @ptrCast(hal.paging.physToVirt(buf_phys));
    @memcpy(dest[0..src.len], src);
}

/// Free a DMA buffer after async operation completes
pub fn freeDmaBuffer(buf_phys: u64, size: usize) void {
    const pages = (size + 4095) / 4096;
    pmm.freePages(buf_phys, pages);
}
