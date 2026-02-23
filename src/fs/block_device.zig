//! BlockDevice -- driver-portable LBA-based block I/O interface.
//!
//! Provides a stateless abstraction over storage hardware (AHCI, VirtIO-SCSI, etc.).
//! All I/O is addressed by logical block address (LBA) and sector count, eliminating
//! the position-state races present in older fd-based I/O paths.
//!
//! Exports: BlockDevice, BlockDeviceError, SECTOR_SIZE

const std = @import("std");

pub const BlockDeviceError = error{
    IOError,
    InvalidLba,
    DeviceNotReady,
    BufferTooSmall,
};

/// Logical sector size in bytes. LBA addressing always uses 512-byte units.
/// Physical sector alignment may differ (see BlockDevice.sector_size).
pub const SECTOR_SIZE: usize = 512;

/// Driver-portable block device interface.
///
/// Drivers create a BlockDevice by filling in ctx, readSectorsFn, writeSectorsFn,
/// sector_count, and sector_size. Callers use the readSectors/writeSectors convenience
/// methods, which validate bounds and buffer size before delegating to the driver.
///
/// No shared position state: LBA is passed per-call, so multiple filesystem instances
/// can issue concurrent reads to different regions without coordination.
pub const BlockDevice = struct {
    /// Opaque driver context (e.g., *AhciPort, *VirtioScsiLun).
    ctx: *anyopaque,

    /// Driver-provided read function. Called by readSectors after validation.
    readSectorsFn: *const fn (ctx: *anyopaque, lba: u64, count: u32, buf: []u8) BlockDeviceError!void,

    /// Driver-provided write function. Called by writeSectors after validation.
    writeSectorsFn: *const fn (ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) BlockDeviceError!void,

    /// Total device capacity in 512-byte sectors.
    sector_count: u64,

    /// Physical sector size reported by the device (informational; usually 512, may be 4096).
    /// LBA addressing always uses 512-byte units regardless of this value.
    sector_size: u32,

    /// Read `count` sectors starting at `lba` into `buf`.
    ///
    /// Validates:
    /// - buf.len >= count * SECTOR_SIZE (overflow-safe via std.math.mul)
    /// - lba + count <= self.sector_count (overflow-safe via std.math.add)
    ///
    /// Returns BlockDeviceError.BufferTooSmall if buf is undersized.
    /// Returns BlockDeviceError.InvalidLba if the range is out of bounds or overflows.
    pub fn readSectors(self: BlockDevice, lba: u64, count: u32, buf: []u8) BlockDeviceError!void {
        const needed = std.math.mul(usize, @as(usize, count), SECTOR_SIZE) catch return error.InvalidLba;
        if (buf.len < needed) return error.BufferTooSmall;
        const end_lba = std.math.add(u64, lba, @as(u64, count)) catch return error.InvalidLba;
        if (end_lba > self.sector_count) return error.InvalidLba;
        return self.readSectorsFn(self.ctx, lba, count, buf);
    }

    /// Write `count` sectors from `buf` starting at `lba`.
    ///
    /// Validates:
    /// - buf.len >= count * SECTOR_SIZE (overflow-safe via std.math.mul)
    /// - lba + count <= self.sector_count (overflow-safe via std.math.add)
    ///
    /// Returns BlockDeviceError.BufferTooSmall if buf is undersized.
    /// Returns BlockDeviceError.InvalidLba if the range is out of bounds or overflows.
    pub fn writeSectors(self: BlockDevice, lba: u64, count: u32, buf: []const u8) BlockDeviceError!void {
        const needed = std.math.mul(usize, @as(usize, count), SECTOR_SIZE) catch return error.InvalidLba;
        if (buf.len < needed) return error.BufferTooSmall;
        const end_lba = std.math.add(u64, lba, @as(u64, count)) catch return error.InvalidLba;
        if (end_lba > self.sector_count) return error.InvalidLba;
        return self.writeSectorsFn(self.ctx, lba, count, buf);
    }
};
