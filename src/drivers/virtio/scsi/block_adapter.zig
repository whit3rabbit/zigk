//! VirtIO-SCSI BlockDevice adapter
//!
//! Bridges the `BlockDevice` vtable interface (LBA-based sector I/O) to
//! VirtioScsiController.readBlocks / writeBlocks calls.
//!
//! Usage:
//!   const bd = try block_adapter.asBlockDevice(controller, lun_idx);
//!   try bd.readSectors(lba, count, buf);

const std = @import("std");
const root = @import("root.zig");
const fs = @import("fs");
const heap = @import("heap");

const BlockDevice = fs.block_device.BlockDevice;
const BlockDeviceError = fs.block_device.BlockDeviceError;
const SECTOR_SIZE = fs.block_device.SECTOR_SIZE;

// ============================================================================
// Adapter context
// ============================================================================

/// Per-LUN context stored as the BlockDevice opaque context pointer.
const ScsiLunCtx = struct {
    /// Pointer to the global controller.
    controller: *root.VirtioScsiController,
    /// Which LUN this adapter represents.
    lun_idx: u8,
    /// Total capacity in 512-byte sectors.
    total_sectors: u64,
    /// Native block size of the LUN (informational; may differ from SECTOR_SIZE).
    lun_block_size: u32,
};

// ============================================================================
// vtable callbacks
// ============================================================================

fn scsiReadSectors(ctx: *anyopaque, lba: u64, count: u32, buf: []u8) BlockDeviceError!void {
    const self: *ScsiLunCtx = @ptrCast(@alignCast(ctx));
    const bsz = self.lun_block_size;

    if (bsz == 0) return error.IOError;

    // Convert 512-byte LBA/count to native LUN block addressing.
    // SECTOR_SIZE == 512; bsz is a power of 2 >= 512 by ext2/SCSI convention.
    const native_lba: u64 = blk: {
        if (bsz == SECTOR_SIZE) break :blk lba;
        // bsz > 512: native_lba = lba * 512 / bsz
        const numerator = std.math.mul(u64, lba, SECTOR_SIZE) catch return error.IOError;
        break :blk numerator / @as(u64, bsz);
    };

    const native_count: u32 = blk: {
        if (bsz == SECTOR_SIZE) break :blk count;
        // Ceiling division: native_count = ceil(count * 512 / bsz)
        const bytes_needed = std.math.mul(u64, @as(u64, count), SECTOR_SIZE) catch return error.IOError;
        const n = (bytes_needed + @as(u64, bsz) - 1) / @as(u64, bsz);
        if (n > std.math.maxInt(u32)) return error.IOError;
        break :blk @intCast(n);
    };

    _ = self.controller.readBlocks(self.lun_idx, native_lba, native_count, buf) catch return error.IOError;
}

fn scsiWriteSectors(ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) BlockDeviceError!void {
    const self: *ScsiLunCtx = @ptrCast(@alignCast(ctx));
    const bsz = self.lun_block_size;

    if (bsz == 0) return error.IOError;

    const native_lba: u64 = blk: {
        if (bsz == SECTOR_SIZE) break :blk lba;
        const numerator = std.math.mul(u64, lba, SECTOR_SIZE) catch return error.IOError;
        break :blk numerator / @as(u64, bsz);
    };

    const native_count: u32 = blk: {
        if (bsz == SECTOR_SIZE) break :blk count;
        const bytes_needed = std.math.mul(u64, @as(u64, count), SECTOR_SIZE) catch return error.IOError;
        const n = (bytes_needed + @as(u64, bsz) - 1) / @as(u64, bsz);
        if (n > std.math.maxInt(u32)) return error.IOError;
        break :blk @intCast(n);
    };

    _ = self.controller.writeBlocks(self.lun_idx, native_lba, native_count, buf) catch return error.IOError;
}

// ============================================================================
// Public API
// ============================================================================

/// Create a BlockDevice adapter for the given LUN on `controller`.
///
/// Heap-allocates a ScsiLunCtx; the caller is responsible for freeing it
/// (normally via unmount which calls the VFS unmount callback).
///
/// Returns error.IOError if the LUN does not exist or is not active.
pub fn asBlockDevice(controller: *root.VirtioScsiController, lun_idx: u8) !BlockDevice {
    const lun_info = controller.getLun(lun_idx) orelse return error.IOError;
    if (!lun_info.active) return error.IOError;

    const bsz = lun_info.block_size;
    if (bsz == 0) return error.IOError;

    // Compute total 512-byte sectors.  block_size is always a multiple of 512
    // for SCSI block devices; the division is exact.
    const sectors_per_block = std.math.divExact(u32, bsz, SECTOR_SIZE) catch return error.IOError;
    const total_sectors = std.math.mul(u64, lun_info.total_blocks, @as(u64, sectors_per_block)) catch return error.IOError;

    const ctx = try heap.allocator().create(ScsiLunCtx);
    errdefer heap.allocator().destroy(ctx);

    ctx.* = .{
        .controller = controller,
        .lun_idx = lun_idx,
        .total_sectors = total_sectors,
        .lun_block_size = bsz,
    };

    return BlockDevice{
        .ctx = ctx,
        .readSectorsFn = scsiReadSectors,
        .writeSectorsFn = scsiWriteSectors,
        .sector_count = total_sectors,
        .sector_size = bsz,
    };
}
