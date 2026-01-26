// IDE ATA Command Implementation
//
// Implements PIO-mode read/write sector commands.
// Uses checked arithmetic for all LBA calculations per security requirements.
//
// Reference: ATA/ATAPI-7 Specification

const std = @import("std");
const hal = @import("hal");
const registers = @import("registers.zig");

// ============================================================================
// Constants
// ============================================================================

pub const SECTOR_SIZE: usize = 512;
pub const MAX_SECTORS_LBA28: u64 = 0x0FFFFFFF;
pub const MAX_SECTORS_PER_TRANSFER: u16 = 256; // 0 means 256 in ATA

// ============================================================================
// Errors
// ============================================================================

pub const CommandError = error{
    Timeout,
    DeviceError,
    InvalidParameter,
    Overflow,
};

// ============================================================================
// PIO Read
// ============================================================================

/// Read sectors using PIO mode
///
/// Parameters:
///   channel: IDE channel to use
///   drive: Drive number (0=master, 1=slave)
///   lba: Starting logical block address
///   count: Number of sectors to read (1-256, 0 means 256)
///   buffer: Destination buffer (must be at least count * 512 bytes)
///   supports_lba48: Whether drive supports LBA48 mode
///
/// Returns: Number of bytes read, or error
pub fn readSectorsPio(
    channel: registers.Channel,
    drive: u1,
    lba: u64,
    count: u16,
    buffer: []u8,
    supports_lba48: bool,
) CommandError!usize {
    // Validate parameters
    if (count == 0) return error.InvalidParameter;

    // Check buffer size (using checked arithmetic)
    const required_size = std.math.mul(usize, @as(usize, count), SECTOR_SIZE) catch {
        return error.Overflow;
    };
    if (buffer.len < required_size) return error.InvalidParameter;

    // Determine if we need LBA48
    const use_lba48 = supports_lba48 and (lba > MAX_SECTORS_LBA28 or count > 256);

    if (!use_lba48 and lba > MAX_SECTORS_LBA28) {
        return error.InvalidParameter;
    }

    // Wait for drive to be ready
    registers.waitNotBusy(channel, registers.getBsyTimeout()) catch {
        return error.Timeout;
    };

    // Select drive and set up LBA
    if (use_lba48) {
        registers.setLba48(channel, drive, @truncate(lba), count);
        registers.writeCommand(channel, .read_sectors_ext);
    } else {
        // LBA28 mode - count 256 is represented as 0
        const count8: u8 = if (count == 256) 0 else @truncate(count);
        registers.setLba28(channel, drive, @truncate(lba), count8);
        registers.writeCommand(channel, .read_sectors);
    }

    // Read each sector
    var bytes_read: usize = 0;
    var sector: u16 = 0;
    while (sector < count) : (sector += 1) {
        // Wait for DRQ
        registers.waitDrq(channel, registers.getDrqTimeout()) catch |err| {
            switch (err) {
                error.DeviceError => return error.DeviceError,
                error.Timeout => return error.Timeout,
            }
        };

        // Calculate buffer offset (using checked arithmetic)
        const offset = std.math.mul(usize, @as(usize, sector), SECTOR_SIZE) catch {
            return error.Overflow;
        };

        // Read sector data
        const sector_buf: *[512]u8 = @ptrCast(buffer[offset..][0..512]);
        registers.readSector(channel, sector_buf);

        bytes_read = std.math.add(usize, bytes_read, SECTOR_SIZE) catch {
            return error.Overflow;
        };
    }

    return bytes_read;
}

/// Read a single sector
pub fn readSector(
    channel: registers.Channel,
    drive: u1,
    lba: u64,
    buffer: *[512]u8,
    supports_lba48: bool,
) CommandError!void {
    _ = try readSectorsPio(channel, drive, lba, 1, buffer, supports_lba48);
}

// ============================================================================
// PIO Write
// ============================================================================

/// Write sectors using PIO mode
///
/// Parameters:
///   channel: IDE channel to use
///   drive: Drive number (0=master, 1=slave)
///   lba: Starting logical block address
///   count: Number of sectors to write (1-256, 0 means 256)
///   buffer: Source buffer (must be at least count * 512 bytes)
///   supports_lba48: Whether drive supports LBA48 mode
///
/// Returns: Number of bytes written, or error
pub fn writeSectorsPio(
    channel: registers.Channel,
    drive: u1,
    lba: u64,
    count: u16,
    buffer: []const u8,
    supports_lba48: bool,
) CommandError!usize {
    // Validate parameters
    if (count == 0) return error.InvalidParameter;

    // Check buffer size (using checked arithmetic)
    const required_size = std.math.mul(usize, @as(usize, count), SECTOR_SIZE) catch {
        return error.Overflow;
    };
    if (buffer.len < required_size) return error.InvalidParameter;

    // Determine if we need LBA48
    const use_lba48 = supports_lba48 and (lba > MAX_SECTORS_LBA28 or count > 256);

    if (!use_lba48 and lba > MAX_SECTORS_LBA28) {
        return error.InvalidParameter;
    }

    // Wait for drive to be ready
    registers.waitNotBusy(channel, registers.getBsyTimeout()) catch {
        return error.Timeout;
    };

    // Select drive and set up LBA
    if (use_lba48) {
        registers.setLba48(channel, drive, @truncate(lba), count);
        registers.writeCommand(channel, .write_sectors_ext);
    } else {
        const count8: u8 = if (count == 256) 0 else @truncate(count);
        registers.setLba28(channel, drive, @truncate(lba), count8);
        registers.writeCommand(channel, .write_sectors);
    }

    // Write each sector
    var bytes_written: usize = 0;
    var sector: u16 = 0;
    while (sector < count) : (sector += 1) {
        // Wait for DRQ
        registers.waitDrq(channel, registers.getDrqTimeout()) catch |err| {
            switch (err) {
                error.DeviceError => return error.DeviceError,
                error.Timeout => return error.Timeout,
            }
        };

        // Calculate buffer offset
        const offset = std.math.mul(usize, @as(usize, sector), SECTOR_SIZE) catch {
            return error.Overflow;
        };

        // Write sector data
        const sector_buf: *const [512]u8 = @ptrCast(buffer[offset..][0..512]);
        registers.writeSector(channel, sector_buf);

        bytes_written = std.math.add(usize, bytes_written, SECTOR_SIZE) catch {
            return error.Overflow;
        };
    }

    // Wait for final sector to complete
    registers.waitNotBusy(channel, registers.getCommandTimeout()) catch {
        return error.Timeout;
    };

    // Check for errors
    const status = registers.readStatus(channel);
    if (status.err) {
        return error.DeviceError;
    }

    return bytes_written;
}

/// Write a single sector
pub fn writeSector(
    channel: registers.Channel,
    drive: u1,
    lba: u64,
    buffer: *const [512]u8,
    supports_lba48: bool,
) CommandError!void {
    _ = try writeSectorsPio(channel, drive, lba, 1, buffer, supports_lba48);
}

// ============================================================================
// Cache Operations
// ============================================================================

/// Flush write cache
pub fn flushCache(channel: registers.Channel, drive: u1, supports_lba48: bool) CommandError!void {
    // Wait for drive to be ready
    registers.waitNotBusy(channel, registers.getBsyTimeout()) catch {
        return error.Timeout;
    };

    // Select drive
    registers.selectDrive(channel, drive);

    // Issue flush command
    const cmd: registers.Command = if (supports_lba48) .cache_flush_ext else .cache_flush;
    registers.writeCommand(channel, cmd);

    // Wait for completion (can take up to 30 seconds)
    registers.waitNotBusy(channel, registers.Timeouts.FLUSH_US) catch {
        return error.Timeout;
    };

    // Check for errors
    const status = registers.readStatus(channel);
    if (status.err) {
        return error.DeviceError;
    }
}
