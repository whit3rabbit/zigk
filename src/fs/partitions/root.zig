// Partition Management
//
// Handles scanning block devices for partition tables (MBR/GPT)
// and registering them as devices in DevFS.

const std = @import("std");
const ahci = @import("ahci");
const devfs = @import("devfs");
const heap = @import("heap");
const mbr = @import("mbr.zig");
const gpt = @import("gpt.zig");
const fd_mod = @import("fd");
const uapi = @import("uapi");
const console = @import("console");

const FileOps = fd_mod.FileOps;
const FileDescriptor = fd_mod.FileDescriptor;
const Errno = uapi.errno.Errno;

/// Partition information used as private_data for partition devices
pub const Partition = struct {
    port_num: u5,
    start_lba: u64,
    sector_count: u64,
    index: u32, // Partition index (1-based)
};

// =============================================================================
// Partition Block Operations
// =============================================================================

pub const partition_ops = FileOps{
    .read = partitionRead,
    .write = partitionWrite,
    .close = partitionClose,
    .seek = partitionSeek,
    .stat = null,
    .ioctl = null,
};

fn partitionRead(fd: *FileDescriptor, buf: []u8) isize {
    const part = @as(*Partition, @ptrCast(@alignCast(fd.private_data)));
    const controller = ahci.getController() orelse return Errno.EIO.toReturn();

    // Bounds checking against partition size
    const pos = fd.position;
    const end_pos = pos + buf.len;
    const part_size_bytes = part.sector_count * 512;

    if (pos >= part_size_bytes) return 0; // EOF

    var read_len = buf.len;
    if (end_pos > part_size_bytes) {
        read_len = @intCast(part_size_bytes - pos);
    }

    // Calculate LBA relative to disk
    // We reuse the ahci adapter logic logic, but we need to pass absolute LBAs to the controller.
    // The ahci adapter logic is in `src/drivers/storage/ahci/adapter.zig`.
    // We can't reuse `blockRead` directly easily because it expects `private_data` to be port number.
    // We will reimplement the logic here (or refactor adapter later).

    // Logic similar to adapter.zig:blockRead but with offset
    const start_lba = part.start_lba + (pos / 512);
    const start_offset = pos % 512;

    const end_lba = part.start_lba + ((pos + read_len + 512 - 1) / 512);
    const sector_count_u64 = end_lba - start_lba;

    if (sector_count_u64 > ahci.MAX_SECTORS_PER_TRANSFER) {
        return Errno.EINVAL.toReturn();
    }
    const sector_count: u16 = @intCast(sector_count_u64);

    // Fast path: aligned
    if (start_offset == 0 and read_len % 512 == 0) {
        controller.readSectors(part.port_num, start_lba, sector_count, buf[0..read_len]) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += read_len;
        return @intCast(read_len);
    }

    // Bounce buffer path
    const bounce_size = @as(usize, sector_count) * 512;
    const allocator = heap.allocator();
    const bounce = allocator.alloc(u8, bounce_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer allocator.free(bounce);

    controller.readSectors(part.port_num, start_lba, sector_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    const copy_start = @as(usize, @intCast(start_offset));
    @memcpy(buf[0..read_len], bounce[copy_start .. copy_start + read_len]);

    fd.position += read_len;
    return @intCast(read_len);
}

fn partitionWrite(fd: *FileDescriptor, buf: []const u8) isize {
    const part = @as(*Partition, @ptrCast(@alignCast(fd.private_data)));
    const controller = ahci.getController() orelse return Errno.EIO.toReturn();

    const pos = fd.position;
    const part_size_bytes = part.sector_count * 512;

    if (pos >= part_size_bytes) return Errno.ENOSPC.toReturn();

    var write_len = buf.len;
    if (pos + write_len > part_size_bytes) {
        write_len = @intCast(part_size_bytes - pos);
    }

    const start_lba = part.start_lba + (pos / 512);
    const start_offset = pos % 512;

    const end_lba = part.start_lba + ((pos + write_len + 512 - 1) / 512);
    const sector_count_u64 = end_lba - start_lba;

    if (sector_count_u64 > ahci.MAX_SECTORS_PER_TRANSFER) {
        return Errno.EINVAL.toReturn();
    }
    const sector_count: u16 = @intCast(sector_count_u64);

    if (start_offset == 0 and write_len % 512 == 0) {
        controller.writeSectors(part.port_num, start_lba, sector_count, buf[0..write_len]) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += write_len;
        return @intCast(write_len);
    }

    // RMW
    const bounce_size = @as(usize, sector_count) * 512;
    const allocator = heap.allocator();
    const bounce = allocator.alloc(u8, bounce_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer allocator.free(bounce);

    controller.readSectors(part.port_num, start_lba, sector_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    const copy_start = @as(usize, @intCast(start_offset));
    @memcpy(bounce[copy_start .. copy_start + write_len], buf[0..write_len]);

    controller.writeSectors(part.port_num, start_lba, sector_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    fd.position += write_len;
    return @intCast(write_len);
}

fn partitionClose(fd: *FileDescriptor) isize {
     const part = @as(*Partition, @ptrCast(@alignCast(fd.private_data)));
     if (ahci.getController()) |controller| {
         controller.flushCache(part.port_num) catch {};
     }
     return 0;
}

fn partitionSeek(fd: *FileDescriptor, offset: i64, whence: u32) isize {
    const part = @as(*Partition, @ptrCast(@alignCast(fd.private_data)));
    const part_size = part.sector_count * 512;

    const SEEK_SET: u32 = 0;
    const SEEK_CUR: u32 = 1;
    const SEEK_END: u32 = 2;

    const new_pos: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => @as(i64, @intCast(fd.position)) + offset,
        SEEK_END => @as(i64, @intCast(part_size)) + offset,
        else => return Errno.EINVAL.toReturn(),
    };

    if (new_pos < 0) {
        return Errno.EINVAL.toReturn();
    }

    // Allow seek past end? Standard linux behavior allows it, but read/write will fail or expand.
    // For block devices, usually fixed size.
    // Let's cap at end or just allow it and let read fail.

    fd.position = @intCast(new_pos);
    return @intCast(fd.position);
}

// =============================================================================
// Scanning Logic
// =============================================================================

/// Scan a disk for partitions and register them
pub fn scanAndRegister(port_num: u5) !void {
    const allocator = heap.allocator();
    const controller = ahci.getController() orelse return;

    // Register the raw disk first (e.g. sda)
    // We assume 0 -> 'a', 1 -> 'b', etc.
    const drive_char = @as(u8, 'a') + port_num;
    const disk_name = try std.fmt.allocPrint(allocator, "sd{c}", .{drive_char});
    // We can't reuse ahci.adapter.block_ops's private_data directly if we want to be consistent with pointer types.
    // ahci.adapter.block_ops expects private_data to be just the port number (usize).
    // Let's register it manually.
    try devfs.registerDevice(disk_name, &ahci.adapter.block_ops, @ptrFromInt(@as(usize, port_num)));

    console.info("Partitions: Scanning {s}...", .{disk_name});

    // Read LBA 0 (MBR)
    const mbr_sector = try allocator.alloc(u8, 512);
    defer allocator.free(mbr_sector);

    controller.readSectors(port_num, 0, 1, mbr_sector) catch |err| {
        console.warn("Partitions: Failed to read MBR from {s}: {}", .{disk_name, err});
        return;
    };

    const mbr_data: *align(1) mbr.Mbr = @ptrCast(mbr_sector);

    if (!mbr_data.isValid()) {
        console.info("Partitions: No valid MBR signature on {s}", .{disk_name});
        return;
    }

    // Check for GPT
    if (mbr_data.isGptProtective()) {
        console.info("Partitions: Found GPT protective MBR on {s}", .{disk_name});
        try scanGpt(port_num, disk_name);
        return;
    }

    // Process MBR partitions
    console.info("Partitions: Found MBR on {s}", .{disk_name});
    var index: u32 = 1;
    for (mbr_data.partitions()) |entry| {
        if (entry.isValid()) {
            try registerPartition(port_num, disk_name, index, entry.lba_start, entry.sector_count);
            index += 1;
        }
    }
}

fn scanGpt(port_num: u5, disk_name: []const u8) !void {
    const allocator = heap.allocator();
    const controller = ahci.getController() orelse return;

    // Read GPT Header (LBA 1)
    const header_sector = try allocator.alloc(u8, 512);
    defer allocator.free(header_sector);

    controller.readSectors(port_num, 1, 1, header_sector) catch {
        console.warn("Partitions: Failed to read GPT header", .{});
        return;
    };

    const header: *align(1) gpt.GptHeader = @ptrCast(header_sector);
    if (!header.isValid()) {
        console.warn("Partitions: Invalid GPT signature", .{});
        return;
    }

    // Read Partition Entries
    // They start at partition_entry_lba (usually 2)
    // Size is num_partition_entries * size_partition_entry
    const entries_size = header.num_partition_entries * header.size_partition_entry;
    const entries_sectors = (entries_size + 511) / 512;

    // Limit reasonable size to avoid OOM
    if (entries_sectors > 128) { // 64KB max for table
         console.warn("Partitions: GPT table too large", .{});
         return;
    }

    const table_buffer = try allocator.alloc(u8, entries_sectors * 512);
    defer allocator.free(table_buffer);

    controller.readSectors(port_num, header.partition_entry_lba, @intCast(entries_sectors), table_buffer) catch {
        console.warn("Partitions: Failed to read GPT entries", .{});
        return;
    };

    var index: u32 = 1;
    var i: u32 = 0;
    while (i < header.num_partition_entries) : (i += 1) {
        const offset = i * header.size_partition_entry;
        if (offset + @sizeOf(gpt.GptEntry) > table_buffer.len) break;

        const entry: *align(1) gpt.GptEntry = @ptrCast(table_buffer[offset..].ptr);

        if (entry.isValid()) {
            const size = entry.last_lba - entry.first_lba + 1;
            try registerPartition(port_num, disk_name, index, entry.first_lba, size);
            index += 1;
        }
    }
}

fn registerPartition(port_num: u5, disk_name: []const u8, index: u32, start: u64, count: u64) !void {
    const allocator = heap.allocator();

    // Create partition struct
    const part = try allocator.create(Partition);
    part.* = Partition{
        .port_num = port_num,
        .start_lba = start,
        .sector_count = count,
        .index = index,
    };

    // Create name: sda1, sda2...
    const name = try std.fmt.allocPrint(allocator, "{s}{d}", .{disk_name, index});

    // Register
    try devfs.registerDevice(name, &partition_ops, part);

    console.info("Partitions: Registered {s} (start={d}, sectors={d})", .{name, start, count});
}
