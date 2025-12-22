//! Partition Management
//!
//! Handles scanning block devices for partition tables (MBR/GPT)
//! and registering them as distinct devices in DevFS (e.g., `sda1`, `sda2`).
//!
//! Features:
//! - Scans MBR (LBA 0) for legacy partitions.
//! - Detects GPT Protective MBR and switches to GPT scanning (LBA 1+).
//! - Registers a `Partition` struct as private data for `partition_ops`.
//! - Provides block read/write operations offset by the partition start LBA.

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
    .mmap = null,
    .poll = null,
    .truncate = null,
};

fn partitionRead(fd: *FileDescriptor, buf: []u8) isize {
    const part = @as(*Partition, @ptrCast(@alignCast(fd.private_data)));
    const controller = ahci.getController() orelse return Errno.EIO.toReturn();

    // Bounds checking against partition size
    // Security: Use checked arithmetic to prevent overflow from malicious partition metadata
    const pos = fd.position;
    const end_pos = std.math.add(usize, pos, buf.len) catch return Errno.ERANGE.toReturn();
    const part_size_bytes = std.math.mul(u64, part.sector_count, 512) catch return Errno.ERANGE.toReturn();

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
    // Safe cast: sector_count_u64 <= MAX_SECTORS_PER_TRANSFER which is < u16 max
    const sector_count: u16 = std.math.cast(u16, sector_count_u64) orelse return Errno.EINVAL.toReturn();

    // Fast path: aligned
    if (start_offset == 0 and read_len % 512 == 0) {
        controller.readSectors(part.port_num, start_lba, sector_count, buf[0..read_len]) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += read_len;
        // Safe cast: read_len bounded by buf.len which fits in isize
        const result = std.math.cast(isize, read_len) orelse return Errno.ERANGE.toReturn();
        return result;
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

    // start_offset is pos % 512, always fits in usize
    const copy_start: usize = start_offset;
    @memcpy(buf[0..read_len], bounce[copy_start .. copy_start + read_len]);

    fd.position += read_len;
    const result = std.math.cast(isize, read_len) orelse return Errno.ERANGE.toReturn();
    return result;
}

fn partitionWrite(fd: *FileDescriptor, buf: []const u8) isize {
    const part = @as(*Partition, @ptrCast(@alignCast(fd.private_data)));
    const controller = ahci.getController() orelse return Errno.EIO.toReturn();

    // Security: Use checked arithmetic to prevent overflow from malicious partition metadata
    const pos = fd.position;
    const part_size_bytes = std.math.mul(u64, part.sector_count, 512) catch return Errno.ERANGE.toReturn();

    if (pos >= part_size_bytes) return Errno.ENOSPC.toReturn();

    var write_len = buf.len;
    const end_pos = std.math.add(usize, pos, write_len) catch return Errno.ERANGE.toReturn();
    if (end_pos > part_size_bytes) {
        write_len = @intCast(part_size_bytes - pos);
    }

    const start_lba = part.start_lba + (pos / 512);
    const start_offset = pos % 512;

    const end_lba = part.start_lba + ((pos + write_len + 512 - 1) / 512);
    const sector_count_u64 = end_lba - start_lba;

    if (sector_count_u64 > ahci.MAX_SECTORS_PER_TRANSFER) {
        return Errno.EINVAL.toReturn();
    }
    // Safe cast: bounded by MAX_SECTORS_PER_TRANSFER check above
    const sector_count: u16 = std.math.cast(u16, sector_count_u64) orelse return Errno.EINVAL.toReturn();

    if (start_offset == 0 and write_len % 512 == 0) {
        controller.writeSectors(part.port_num, start_lba, sector_count, buf[0..write_len]) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += write_len;
        const result = std.math.cast(isize, write_len) orelse return Errno.ERANGE.toReturn();
        return result;
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

    // start_offset is pos % 512, always fits in usize
    const copy_start: usize = start_offset;
    @memcpy(bounce[copy_start .. copy_start + write_len], buf[0..write_len]);

    controller.writeSectors(part.port_num, start_lba, sector_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    fd.position += write_len;
    const result = std.math.cast(isize, write_len) orelse return Errno.ERANGE.toReturn();
    return result;
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
    // Security: Use checked arithmetic to prevent overflow from malicious partition metadata
    const part_size = std.math.mul(u64, part.sector_count, 512) catch return Errno.ERANGE.toReturn();

    const SEEK_SET: u32 = 0;
    const SEEK_CUR: u32 = 1;
    const SEEK_END: u32 = 2;

    // Safe casts for position/size to i64 (validate they fit)
    const pos_i64 = std.math.cast(i64, fd.position) orelse return Errno.ERANGE.toReturn();
    const size_i64 = std.math.cast(i64, part_size) orelse return Errno.ERANGE.toReturn();

    const new_pos: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => pos_i64 + offset,
        SEEK_END => size_i64 + offset,
        else => return Errno.EINVAL.toReturn(),
    };

    if (new_pos < 0) {
        return Errno.EINVAL.toReturn();
    }

    // Allow seek past end? Standard linux behavior allows it, but read/write will fail or expand.
    // For block devices, usually fixed size.
    // Let's cap at end or just allow it and let read fail.

    fd.position = std.math.cast(usize, new_pos) orelse return Errno.ERANGE.toReturn();
    return std.math.cast(isize, fd.position) orelse return Errno.ERANGE.toReturn();
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
    // Security: Use checked arithmetic to prevent integer overflow from malicious GPT headers
    const entries_size = std.math.mul(u64, header.num_partition_entries, header.size_partition_entry) catch {
        console.warn("Partitions: GPT table size overflow (entries={}, size={})", .{ header.num_partition_entries, header.size_partition_entry });
        return;
    };
    const entries_sectors = (entries_size + 511) / 512;

    // Limit reasonable size to avoid OOM (128 sectors = 64KB)
    if (entries_sectors > 128) {
        console.warn("Partitions: GPT table too large ({} sectors)", .{entries_sectors});
        return;
    }

    const table_buffer = try allocator.alloc(u8, entries_sectors * 512);
    defer allocator.free(table_buffer);

    // Safe cast: entries_sectors already bounded to < 128 above
    const entries_sectors_u16: u16 = std.math.cast(u16, entries_sectors) orelse {
        console.warn("Partitions: GPT entries_sectors too large", .{});
        return;
    };
    controller.readSectors(port_num, header.partition_entry_lba, entries_sectors_u16, table_buffer) catch {
        console.warn("Partitions: Failed to read GPT entries", .{});
        return;
    };

    var index: u32 = 1;
    var i: u32 = 0;
    while (i < header.num_partition_entries) : (i += 1) {
        // Security: Use checked arithmetic to prevent offset overflow in ReleaseFast
        const offset = std.math.mul(u32, i, header.size_partition_entry) catch break;
        const end_offset = std.math.add(u32, offset, @sizeOf(gpt.GptEntry)) catch break;
        if (end_offset > table_buffer.len) break;

        const entry: *align(1) gpt.GptEntry = @ptrCast(table_buffer[offset..].ptr);

        if (entry.isValid()) {
            // SECURITY: Use checked arithmetic to prevent overflow from malicious GPT data
            const diff = std.math.sub(u64, entry.last_lba, entry.first_lba) catch continue;
            const size = std.math.add(u64, diff, 1) catch continue;
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
