// MBR (Master Boot Record) Parsing
//
// MBR is found at LBA 0. It contains 4 partition entries starting at offset 446 (0x1BE).
// Signature 0x55AA is at offset 510.

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
    chs_first: [3]u8,
    type: PartitionType,
    chs_last: [3]u8,
    lba_start: u32,
    sector_count: u32,

    pub fn isValid(self: MbrEntry) bool {
        return self.type != .Empty and self.sector_count > 0;
    }
};

pub const Mbr = packed struct {
    bootstrap: [446]u8,
    partitions: [4]MbrEntry,
    signature: u16,

    pub fn isValid(self: Mbr) bool {
        return self.signature == MBR_SIGNATURE;
    }

    pub fn isGptProtective(self: Mbr) bool {
        if (!self.isValid()) return false;
        // Check if any partition is type 0xEE
        for (self.partitions) |p| {
            if (p.type == .GPTProtection) return true;
        }
        return false;
    }
};

comptime {
    std.debug.assert(@sizeOf(MbrEntry) == 16);
    std.debug.assert(@sizeOf(Mbr) == 512);
}
