//! MBR (Master Boot Record) Parsing
//!
//! Provides structures for parsing legacy MBR partition tables.
//! MBR is found at LBA 0 and contains 4 primary partition entries.
//!
//! Layout:
//! - 0x000 - 0x1BD: Bootstrap code (ignored by us).
//! - 0x1BE - 0x1FD: Partition table (4 entries, 16 bytes each).
//! - 0x1FE - 0x1FF: Signature (0x55, 0xAA).

const std = @import("std");

pub const SECTOR_SIZE = 512;
pub const MBR_SIGNATURE = 0xAA55; // Little-endian 0x55AA

pub const PartitionType = enum(u8) {
    Empty = 0x00,
    FAT12 = 0x01,
    FAT16 = 0x04,
    Extended = 0x05,
    FAT16B = 0x06,
    NTFS = 0x07,
    FAT32 = 0x0B,
    FAT32LBA = 0x0C,
    FAT16LBA = 0x0E,
    ExtendedLBA = 0x0F,
    Linux = 0x83,
    GPTProtection = 0xEE,
    EFISystem = 0xEF,
    _,
};

pub const MbrEntry = packed struct {
    status: u8,
    chs_first_head: u8,
    chs_first_sect_cyl: u16,
    type: PartitionType,
    chs_last_head: u8,
    chs_last_sect_cyl: u16,
    lba_start: u32,
    sector_count: u32,

    pub fn isValid(self: MbrEntry) bool {
        return self.type != .Empty and self.sector_count > 0;
    }
};

pub const Mbr = extern struct {
    bootstrap: [446]u8,
    partition_bytes: [64]u8,
    signature: u16,

    pub fn isValid(self: Mbr) bool {
        return self.signature == MBR_SIGNATURE;
    }

    pub fn partitions(self: *align(1) const Mbr) []align(1) const MbrEntry {
        const bytes_ptr: [*]const u8 = @ptrCast(&self.partition_bytes);
        const bytes = bytes_ptr[0..self.partition_bytes.len];
        return std.mem.bytesAsSlice(MbrEntry, bytes);
    }

    pub fn isGptProtective(self: Mbr) bool {
        if (!self.isValid()) return false;
        // Check if any partition is type 0xEE
        for (self.partitions()) |p| {
            if (p.type == .GPTProtection) return true;
        }
        return false;
    }
};

comptime {
    std.debug.assert(@sizeOf(MbrEntry) == 16);
    std.debug.assert(@sizeOf(Mbr) == 512);
}
