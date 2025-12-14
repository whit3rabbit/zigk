// GPT (GUID Partition Table) Parsing
//
// GPT uses LBA 1 for the header and subsequent LBAs for partition entries.
// It supports many more partitions than MBR and uses 64-bit LBAs.

const std = @import("std");

pub const SECTOR_SIZE = 512;
pub const GPT_SIGNATURE = 0x5452415020494645; // "EFI PART" in little-endian

pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    pub fn eql(self: Guid, other: Guid) bool {
        return self.data1 == other.data1 and
               self.data2 == other.data2 and
               self.data3 == other.data3 and
               std.mem.eql(u8, &self.data4, &other.data4);
    }

    pub fn isZero(self: Guid) bool {
        return self.data1 == 0 and self.data2 == 0 and self.data3 == 0; // Optimization: check main parts
    }
};

pub const GptHeader = packed struct {
    signature: u64,
    revision: u32,
    header_size: u32,
    crc32_header: u32,
    reserved: u32,
    current_lba: u64,
    backup_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: Guid,
    partition_entry_lba: u64,
    num_partition_entries: u32,
    size_partition_entry: u32,
    crc32_partition_array: u32,
    // Header is usually 92 bytes, but sector size is 512.
    // We can just read the first 92 bytes or pad it manually if needed,
    // but for packed struct mapping we need to be careful with trailing bytes if we map the whole sector.
    // For now, let's just map the relevant fields.
    // The rest of the sector is reserved/padding.

    pub fn isValid(self: GptHeader) bool {
        return self.signature == GPT_SIGNATURE;
    }
};

pub const GptEntry = packed struct {
    type_guid: Guid,
    unique_guid: Guid,
    first_lba: u64,
    last_lba: u64,
    flags: u64,
    name: [72]u8, // UTF-16LE name

    pub fn isValid(self: GptEntry) bool {
        return !self.type_guid.isZero();
    }
};

comptime {
    std.debug.assert(@sizeOf(GptEntry) == 128);
}
