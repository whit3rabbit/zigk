const std = @import("std");

const GptHeader = extern struct {
    signature: u64,
    revision: u32,
    header_size: u32,
    crc32: u32, // CRC32 of header with this field zeroed
    reserved: u32,
    current_lba: u64,
    backup_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: [16]u8,
    partition_entry_lba: u64,
    num_partition_entries: u32,
    partition_entry_size: u32,
    partition_crc32: u32, // CRC32 of partition entries array
};

const GptPartitionEntry = extern struct {
    type_guid: [16]u8,
    unique_guid: [16]u8,
    first_lba: u64,
    last_lba: u64,
    attributes: u64,
    name: [72]u8, // UTF-16LE
};

// MBR is 512 bytes total:
// 0-445: Bootstrap + disk ID + reserved
// 446-509: 4 partition entries (16 bytes each)
// 510-511: Signature (0x55, 0xAA)
const MBR_SIZE = 512;
const MBR_PARTITION_OFFSET = 446;
const MBR_SIGNATURE_OFFSET = 510;
const MBR_PARTITION_ENTRY_SIZE = 16;

fn writeMbrPartitionEntry(buf: []u8, status: u8, type_code: u8, lba_first: u32, sectors: u32) void {
    buf[0] = status;
    buf[1] = 0x00; // CHS first (head)
    buf[2] = 0x02; // CHS first (sector/cyl)
    buf[3] = 0x00; // CHS first (cyl)
    buf[4] = type_code;
    buf[5] = 0xFF; // CHS last (head)
    buf[6] = 0xFF; // CHS last (sector/cyl)
    buf[7] = 0xFF; // CHS last (cyl)
    std.mem.writeInt(u32, buf[8..12], lba_first, .little);
    std.mem.writeInt(u32, buf[12..16], sectors, .little);
}

// EFI System Partition GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
const EFI_SYSTEM_PARTITION_GUID = "\x28\x73\x2a\xc1\x1f\xf8\xd2\x11\xba\x4b\x00\xa0\xc9\x3e\xc9\x3b";

fn calculateCrc32(data: []const u8) u32 {
    const Crc32 = std.hash.Crc32;
    return Crc32.hash(data);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len != 3) {
        std.debug.print("Usage: {s} <input_fs_img> <output_disk_img>\n", .{args[0]});
        return error.InvalidArgs;
    }

    const input_path = args[1];
    const output_path = args[2];

    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();

    const stat = try input_file.stat();
    const input_data = try allocator.alloc(u8, stat.size);
    
    var total_read: usize = 0;
    while (total_read < input_data.len) {
        const n = try input_file.read(input_data[total_read..]);
        if (n == 0) break;
        total_read += n;
    }
    if (total_read != input_data.len) return error.UnexpectedEndOfFile;

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    // 1. Protective MBR (LBA 0)
    var mbr: [MBR_SIZE]u8 = [_]u8{0} ** MBR_SIZE;
    // Write protective MBR partition entry (type 0xEE for GPT)
    writeMbrPartitionEntry(mbr[MBR_PARTITION_OFFSET..][0..MBR_PARTITION_ENTRY_SIZE], 0x00, 0xEE, 1, 0xFFFFFFFF);
    // Write MBR signature
    mbr[MBR_SIGNATURE_OFFSET] = 0x55;
    mbr[MBR_SIGNATURE_OFFSET + 1] = 0xAA;

    // 2. Calculate Layout
    const sector_size = 512;
    const header_lba = 1;
    const partition_entries_start_lba = 2;
    const num_partition_entries = 128;
    const partition_entry_size = @sizeOf(GptPartitionEntry);
    const partition_entries_sectors = (num_partition_entries * partition_entry_size + sector_size - 1) / sector_size;
    
    const first_usable_lba = partition_entries_start_lba + partition_entries_sectors;
    
    // Align first LBA to 2048 (1MB) if possible, or just use next available
    // Standard practice aligns to 1MB (2048 sectors)
    const aligned_first_usable_lba = @max(first_usable_lba, 2048);
    
    const input_sectors = (input_data.len + sector_size - 1) / sector_size;
    const last_usable_lba = aligned_first_usable_lba + input_sectors - 1;
    
    // Backup GPT structures
    const backup_partition_entries_sectors = partition_entries_sectors;
    const backup_header_lba = last_usable_lba + 1 + backup_partition_entries_sectors;
    const current_lba = header_lba;
    
    // Total disk size
    const total_sectors = backup_header_lba + 1;
    
    // Update MBR partition size (sectors field is at offset 12 within the partition entry)
    const mbr_sectors: u32 = if (total_sectors > 0xFFFFFFFF) 0xFFFFFFFF else @as(u32, @intCast(total_sectors)) - 1;
    std.mem.writeInt(u32, mbr[MBR_PARTITION_OFFSET + 12 ..][0..4], mbr_sectors, .little);

    // Write MBR (LBA 0)
    try output_file.seekTo(0);
    try output_file.writeAll(&mbr);
    
    // 3. Prepare Partition Entries
    var entries = try allocator.alloc(GptPartitionEntry, num_partition_entries);
    @memset(entries, std.mem.zeroes(GptPartitionEntry));
    
    // Create ESP partition entry
    var unique_guid: [16]u8 = undefined;
    std.crypto.random.bytes(&unique_guid);
    
    entries[0] = .{
        .type_guid = EFI_SYSTEM_PARTITION_GUID.*,
        .unique_guid = unique_guid,
        .first_lba = aligned_first_usable_lba,
        .last_lba = last_usable_lba,
        .attributes = 0,
        .name = std.mem.zeroes([72]u8),
    };
    const name = std.unicode.utf8ToUtf16LeStringLiteral("EFI System Partition");
    const name_bytes = std.mem.sliceAsBytes(name);
    @memcpy(entries[0].name[0..name_bytes.len], name_bytes);
    
    const entries_bytes = std.mem.sliceAsBytes(entries);
    const partition_crc32 = calculateCrc32(entries_bytes);
    
    // 4. Primary GPT Header (LBA 1)
    var header: GptHeader = .{
        .signature = 0x5452415020494645, // "EFI PART"
        .revision = 0x00010000,
        .header_size = 92,
        .crc32 = 0,
        .reserved = 0,
        .current_lba = current_lba,
        .backup_lba = backup_header_lba,
        .first_usable_lba = aligned_first_usable_lba,
        .last_usable_lba = last_usable_lba,
        .disk_guid = undefined,
        .partition_entry_lba = partition_entries_start_lba,
        .num_partition_entries = num_partition_entries,
        .partition_entry_size = partition_entry_size,
        .partition_crc32 = partition_crc32,
    };
    std.crypto.random.bytes(&header.disk_guid);
    
    // Calc Header CRC
    header.crc32 = calculateCrc32(std.mem.asBytes(&header)[0..92]);

    // Write Primary Header
    try output_file.seekTo(header_lba * sector_size);
    try output_file.writeAll(std.mem.asBytes(&header)[0..92]);
    
    // Write Primary Partition Entries
    try output_file.seekTo(partition_entries_start_lba * sector_size);
    try output_file.writeAll(entries_bytes);
    
    // 5. Write Data
    try output_file.seekTo(aligned_first_usable_lba * sector_size);
    try output_file.writeAll(input_data);
    // Pad end of partition if needed (shouldn't be if we calculated logical blocks correctly)
    const written_size = input_data.len;
    const aligned_size = input_sectors * sector_size;
    if (aligned_size > written_size) {
        const padding = try allocator.alloc(u8, aligned_size - written_size);
        @memset(padding, 0);
        try output_file.writeAll(padding);
    }

    // 6. Backup Partition Entries
    const backup_entries_lba = last_usable_lba + 1;
    try output_file.seekTo(backup_entries_lba * sector_size);
    try output_file.writeAll(entries_bytes);
    
    // 7. Backup GPT Header
    var backup_header = header;
    backup_header.current_lba = backup_header_lba;
    backup_header.backup_lba = current_lba;
    backup_header.partition_entry_lba = backup_entries_lba;
    backup_header.crc32 = 0;
    backup_header.crc32 = calculateCrc32(std.mem.asBytes(&backup_header)[0..92]);
    
    try output_file.seekTo(backup_header_lba * sector_size);
    try output_file.writeAll(std.mem.asBytes(&backup_header)[0..92]);
    const padding = [_]u8{0} ** (sector_size - 92);
    try output_file.writeAll(&padding);
    
    std.debug.print("Created GPT disk image at {s}\n", .{output_path});
}
