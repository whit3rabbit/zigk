const std = @import("std");
const fd = @import("fd");
const console = @import("console");
const t = @import("types.zig");

/// Read a single sector - uses file descriptor operations (works with any block device)
/// SERIALIZED: Uses io_lock to prevent device_fd.position races
pub fn readSector(self: *t.SFS, lba: u32, buf: *[512]u8) t.SectorError!void {
    const held = self.io_lock.acquire();
    defer held.release();

    // Use file descriptor read operation - works for AHCI, VirtIO-SCSI, NVMe, etc.
    const device_fd = self.device_fd;
    const old_pos = device_fd.position;
    device_fd.position = @as(u64, lba) * 512;

    if (device_fd.ops.read) |read_fn| {
        const bytes_read = read_fn(device_fd, buf);
        device_fd.position = old_pos; // Restore position

        if (bytes_read < 0) {
            console.warn("SFS: Read failed with error code: {}", .{bytes_read});
            return error.IOError;
        }
        if (bytes_read < 512) {
            console.warn("SFS: Read returned only {} bytes (expected 512)", .{bytes_read});
            return error.IOError;
        }
        return;
    }

    console.warn("SFS: No read operation available on file descriptor", .{});
    device_fd.position = old_pos;
    return error.IOError;
}

/// Write a single sector - uses file descriptor operations (works with any block device)
/// SERIALIZED: Uses io_lock to prevent device_fd.position races
pub fn writeSector(self: *t.SFS, lba: u32, buf: []const u8) t.SectorError!void {
    if (buf.len < 512) return error.IOError;

    const held = self.io_lock.acquire();
    defer held.release();

    // Use file descriptor write operation - works for AHCI, VirtIO-SCSI, NVMe, etc.
    const device_fd = self.device_fd;
    const old_pos = device_fd.position;
    device_fd.position = @as(u64, lba) * 512;

    if (device_fd.ops.write) |write_fn| {
        const bytes_written = write_fn(device_fd, buf[0..512]);
        device_fd.position = old_pos; // Restore position

        if (bytes_written < 0) {
            console.warn("SFS: Write failed with error code: {}", .{bytes_written});
            return error.IOError;
        }
        if (bytes_written < 512) {
            console.warn("SFS: Write returned only {} bytes (expected 512)", .{bytes_written});
            return error.IOError;
        }
        return;
    }

    console.warn("SFS: No write operation available on file descriptor", .{});
    device_fd.position = old_pos;
    return error.IOError;
}

/// Read a single sector (SFS instance method) - uses FD-based I/O for driver portability
pub fn readSectorAsync(self: *t.SFS, lba: u32, buf: []u8) !void {
    // Use file descriptor read (works for all drivers: AHCI, VirtIO-SCSI, NVMe)
    var read_buf: [512]u8 = undefined;
    try readSector(self, lba, &read_buf);
    @memcpy(buf[0..512], &read_buf);
}

/// Write a single sector (SFS instance method) - uses FD-based I/O for driver portability
pub fn writeSectorAsync(self: *t.SFS, lba: u32, buf: []const u8) !void {
    // Use file descriptor write (works for all drivers: AHCI, VirtIO-SCSI, NVMe)
    var write_buf: [512]u8 = undefined;
    @memcpy(&write_buf, buf[0..512]);
    try writeSector(self, lba, &write_buf);
}

/// Read multiple sectors using FD-based I/O (driver portable)
pub fn readSectorsAsync(self: *t.SFS, lba: u32, sector_count: u16, buf: []u8) !void {
    if (sector_count == 0) return;
    const total_bytes = @as(usize, sector_count) * 512;
    if (buf.len < total_bytes) return error.IOError;

    // Use file descriptor read (read sector by sector)
    var current_lba = lba;
    var offset: usize = 0;
    var remaining = sector_count;
    var read_buf: [512]u8 = undefined;
    while (remaining > 0) : ({
        current_lba += 1;
        offset += 512;
        remaining -= 1;
    }) {
        try readSector(self, current_lba, &read_buf);
        @memcpy(buf[offset..][0..512], &read_buf);
    }
}

/// Write multiple sectors using FD-based I/O (driver portable)
pub fn writeSectorsAsync(self: *t.SFS, lba: u32, sector_count: u16, buf: []const u8) !void {
    if (sector_count == 0) return;
    const total_bytes = @as(usize, sector_count) * 512;
    if (buf.len < total_bytes) return error.IOError;

    // Use file descriptor write (write sector by sector)
    var current_lba = lba;
    var offset: usize = 0;
    var remaining = sector_count;
    var write_buf: [512]u8 = undefined;
    while (remaining > 0) : ({
        current_lba += 1;
        offset += 512;
        remaining -= 1;
    }) {
        @memcpy(&write_buf, buf[offset..][0..512]);
        try writeSector(self, current_lba, &write_buf);
    }
}

pub fn readDirectoryAsync(self: *t.SFS, buf: []u8) !void {
    const total_bytes = t.ROOT_DIR_BLOCKS * 512;
    if (buf.len < total_bytes) return error.IOError;
    try readSectorsAsync(self, self.superblock.root_dir_start, t.ROOT_DIR_BLOCKS, buf[0..total_bytes]);
}

pub fn writeDirectoryAsync(self: *t.SFS, buf: []const u8) !void {
    const total_bytes = t.ROOT_DIR_BLOCKS * 512;
    if (buf.len < total_bytes) return error.IOError;
    try writeSectorsAsync(self, self.superblock.root_dir_start, t.ROOT_DIR_BLOCKS, buf[0..total_bytes]);
}

pub fn updateSuperblock(self: *t.SFS) !void {
    try writeSector(self, 0, std.mem.asBytes(&self.superblock));
}
