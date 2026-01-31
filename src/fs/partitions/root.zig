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
const nvme = @import("nvme");
const virtio_scsi = @import("virtio_scsi");
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
    // SECURITY: Use checked arithmetic to prevent overflow from malicious partition tables
    const pos_sectors = pos / 512;
    const start_lba = std.math.add(u64, part.start_lba, pos_sectors) catch return Errno.ERANGE.toReturn();
    const start_offset = pos % 512;

    const end_pos_padded = std.math.add(usize, pos + read_len, 511) catch return Errno.ERANGE.toReturn();
    const end_lba = std.math.add(u64, part.start_lba, end_pos_padded / 512) catch return Errno.ERANGE.toReturn();
    if (end_lba < start_lba) return Errno.ERANGE.toReturn();
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

    // SECURITY: Use checked arithmetic to prevent overflow from malicious partition tables
    const pos_sectors = pos / 512;
    const start_lba = std.math.add(u64, part.start_lba, pos_sectors) catch return Errno.ERANGE.toReturn();
    const start_offset = pos % 512;

    const end_pos_padded = std.math.add(usize, pos + write_len, 511) catch return Errno.ERANGE.toReturn();
    const end_lba = std.math.add(u64, part.start_lba, end_pos_padded / 512) catch return Errno.ERANGE.toReturn();
    if (end_lba < start_lba) return Errno.ERANGE.toReturn();
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

    // SECURITY: Use checked arithmetic to prevent signed overflow on SEEK_CUR/SEEK_END.
    // An attacker could craft offset values that wrap around in ReleaseFast builds.
    const new_pos: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => std.math.add(i64, pos_i64, offset) catch return Errno.ERANGE.toReturn(),
        SEEK_END => std.math.add(i64, size_i64, offset) catch return Errno.ERANGE.toReturn(),
        else => return Errno.EINVAL.toReturn(),
    };

    if (new_pos < 0) {
        return Errno.EINVAL.toReturn();
    }

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
    // SECURITY NOTE: Zero-initialization is NOT required here because:
    //   1. readSectors() is an atomic operation that either fills all 512 bytes or fails completely
    //   2. On failure, we return immediately without using the buffer contents
    //   3. The AHCI driver uses DMA which writes the full sector or returns an error
    //   4. No partial reads are possible - the hardware guarantees sector atomicity
    // This differs from RMW (read-modify-write) paths where partial data could leak.
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

    // SECURITY: Validate minimum partition entry size per UEFI spec (128 bytes).
    // Smaller values would cause overlapping reads when iterating entries.
    if (header.size_partition_entry < @sizeOf(gpt.GptEntry)) {
        console.warn("Partitions: GPT entry size too small ({} < 128)", .{header.size_partition_entry});
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

/// Register a partition with devfs.
/// SECURITY NOTE (Partition Bounds): We do not validate start+count against disk capacity here.
/// This is defense-in-depth: the underlying AHCI driver validates LBA bounds on every I/O
/// operation and returns errors for out-of-bounds access. A malicious partition table could
/// specify invalid bounds, but I/O would fail safely at the driver level rather than
/// accessing wrong memory regions.
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

// =============================================================================
// NVMe Partition Support
// =============================================================================

/// NVMe partition information
pub const NvmePartition = struct {
    ns_index: u8,
    nsid: u32,
    start_lba: u64,
    sector_count: u64,
    lba_size: u32,
    index: u32, // Partition index (1-based)
};

pub const nvme_partition_ops = FileOps{
    .read = nvmePartitionRead,
    .write = nvmePartitionWrite,
    .close = nvmePartitionClose,
    .seek = nvmePartitionSeek,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

fn nvmePartitionRead(fd: *FileDescriptor, buf: []u8) isize {
    const part = @as(*NvmePartition, @ptrCast(@alignCast(fd.private_data)));
    const controller = nvme.getController() orelse return Errno.EIO.toReturn();

    const pos = fd.position;
    const lba_size = part.lba_size;

    // Security: Use checked arithmetic to prevent overflow
    const part_size_bytes = std.math.mul(u64, part.sector_count, lba_size) catch return Errno.ERANGE.toReturn();
    if (pos >= part_size_bytes) return 0; // EOF

    var read_len = buf.len;
    const end_pos = std.math.add(usize, pos, buf.len) catch return Errno.ERANGE.toReturn();
    if (end_pos > part_size_bytes) {
        read_len = @intCast(part_size_bytes - pos);
    }

    // Calculate LBA relative to namespace
    const pos_lbas = pos / lba_size;
    const start_lba = std.math.add(u64, part.start_lba, pos_lbas) catch return Errno.ERANGE.toReturn();
    const start_offset = pos % lba_size;

    const end_pos_padded = std.math.add(usize, pos + read_len, lba_size - 1) catch return Errno.ERANGE.toReturn();
    const end_lba = std.math.add(u64, part.start_lba, end_pos_padded / lba_size) catch return Errno.ERANGE.toReturn();
    if (end_lba < start_lba) return Errno.ERANGE.toReturn();
    const block_count_u64 = end_lba - start_lba;

    // NVMe max transfer is typically 65535 blocks
    if (block_count_u64 > 65535) {
        return Errno.EINVAL.toReturn();
    }
    const block_count: u32 = @intCast(block_count_u64);

    // Fast path: aligned
    if (start_offset == 0 and read_len % lba_size == 0) {
        controller.readBlocks(part.nsid, start_lba, block_count, buf[0..read_len]) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += read_len;
        const result = std.math.cast(isize, read_len) orelse return Errno.ERANGE.toReturn();
        return result;
    }

    // Bounce buffer path
    const bounce_size = @as(usize, block_count) * lba_size;
    const allocator = heap.allocator();
    const bounce = allocator.alloc(u8, bounce_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer allocator.free(bounce);

    controller.readBlocks(part.nsid, start_lba, block_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    const copy_start: usize = start_offset;
    @memcpy(buf[0..read_len], bounce[copy_start .. copy_start + read_len]);

    fd.position += read_len;
    const result = std.math.cast(isize, read_len) orelse return Errno.ERANGE.toReturn();
    return result;
}

fn nvmePartitionWrite(fd: *FileDescriptor, buf: []const u8) isize {
    const part = @as(*NvmePartition, @ptrCast(@alignCast(fd.private_data)));
    const controller = nvme.getController() orelse return Errno.EIO.toReturn();

    const pos = fd.position;
    const lba_size = part.lba_size;

    const part_size_bytes = std.math.mul(u64, part.sector_count, lba_size) catch return Errno.ERANGE.toReturn();
    if (pos >= part_size_bytes) return Errno.ENOSPC.toReturn();

    var write_len = buf.len;
    const end_pos = std.math.add(usize, pos, write_len) catch return Errno.ERANGE.toReturn();
    if (end_pos > part_size_bytes) {
        write_len = @intCast(part_size_bytes - pos);
    }

    const pos_lbas = pos / lba_size;
    const start_lba = std.math.add(u64, part.start_lba, pos_lbas) catch return Errno.ERANGE.toReturn();
    const start_offset = pos % lba_size;

    const end_pos_padded = std.math.add(usize, pos + write_len, lba_size - 1) catch return Errno.ERANGE.toReturn();
    const end_lba = std.math.add(u64, part.start_lba, end_pos_padded / lba_size) catch return Errno.ERANGE.toReturn();
    if (end_lba < start_lba) return Errno.ERANGE.toReturn();
    const block_count_u64 = end_lba - start_lba;

    if (block_count_u64 > 65535) {
        return Errno.EINVAL.toReturn();
    }
    const block_count: u32 = @intCast(block_count_u64);

    if (start_offset == 0 and write_len % lba_size == 0) {
        controller.writeBlocks(part.nsid, start_lba, block_count, buf[0..write_len]) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += write_len;
        const result = std.math.cast(isize, write_len) orelse return Errno.ERANGE.toReturn();
        return result;
    }

    // RMW
    const bounce_size = @as(usize, block_count) * lba_size;
    const allocator = heap.allocator();
    const bounce = allocator.alloc(u8, bounce_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer allocator.free(bounce);

    controller.readBlocks(part.nsid, start_lba, block_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    const copy_start: usize = start_offset;
    @memcpy(bounce[copy_start .. copy_start + write_len], buf[0..write_len]);

    controller.writeBlocks(part.nsid, start_lba, block_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    fd.position += write_len;
    const result = std.math.cast(isize, write_len) orelse return Errno.ERANGE.toReturn();
    return result;
}

fn nvmePartitionClose(fd: *FileDescriptor) isize {
    const part = @as(*NvmePartition, @ptrCast(@alignCast(fd.private_data)));
    if (nvme.getController()) |controller| {
        controller.flush(part.nsid) catch {};
    }
    return 0;
}

fn nvmePartitionSeek(fd: *FileDescriptor, offset: i64, whence: u32) isize {
    const part = @as(*NvmePartition, @ptrCast(@alignCast(fd.private_data)));
    const part_size = std.math.mul(u64, part.sector_count, part.lba_size) catch return Errno.ERANGE.toReturn();

    const SEEK_SET: u32 = 0;
    const SEEK_CUR: u32 = 1;
    const SEEK_END: u32 = 2;

    const pos_i64 = std.math.cast(i64, fd.position) orelse return Errno.ERANGE.toReturn();
    const size_i64 = std.math.cast(i64, part_size) orelse return Errno.ERANGE.toReturn();

    // SECURITY: Use checked arithmetic to prevent signed overflow on SEEK_CUR/SEEK_END.
    const new_pos: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => std.math.add(i64, pos_i64, offset) catch return Errno.ERANGE.toReturn(),
        SEEK_END => std.math.add(i64, size_i64, offset) catch return Errno.ERANGE.toReturn(),
        else => return Errno.EINVAL.toReturn(),
    };

    if (new_pos < 0) {
        return Errno.EINVAL.toReturn();
    }

    fd.position = std.math.cast(usize, new_pos) orelse return Errno.ERANGE.toReturn();
    return std.math.cast(isize, fd.position) orelse return Errno.ERANGE.toReturn();
}

/// Scan an NVMe namespace for partitions and register them
pub fn scanAndRegisterNvme(ns_index: u8, nsid: u32) !void {
    const allocator = heap.allocator();
    const controller = nvme.getController() orelse return;
    const ns = controller.getNamespace(ns_index) orelse return;

    // Register the raw namespace first (e.g. nvme0n1)
    const disk_name = try std.fmt.allocPrint(allocator, "nvme0n{d}", .{nsid});

    // Register with NVMe adapter's block_ops
    try devfs.registerDevice(disk_name, &nvme.adapter.block_ops, @ptrFromInt(@as(usize, nsid)));

    console.info("Partitions: Scanning {s}...", .{disk_name});

    // Read LBA 0 (MBR)
    const lba_size = ns.lba_size;
    const mbr_buf_size = @max(lba_size, 512);
    const mbr_sector = try allocator.alloc(u8, mbr_buf_size);
    defer allocator.free(mbr_sector);

    controller.readBlocks(nsid, 0, 1, mbr_sector) catch |err| {
        console.warn("Partitions: Failed to read MBR from {s}: {}", .{ disk_name, err });
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
        try scanGptNvme(ns_index, nsid, disk_name, lba_size);
        return;
    }

    // Process MBR partitions
    console.info("Partitions: Found MBR on {s}", .{disk_name});
    var index: u32 = 1;
    for (mbr_data.partitions()) |entry| {
        if (entry.isValid()) {
            try registerNvmePartition(ns_index, nsid, disk_name, index, entry.lba_start, entry.sector_count, lba_size);
            index += 1;
        }
    }
}

fn scanGptNvme(ns_index: u8, nsid: u32, disk_name: []const u8, lba_size: u32) !void {
    const allocator = heap.allocator();
    const controller = nvme.getController() orelse return;

    // Read GPT Header (LBA 1)
    const header_buf_size = @max(lba_size, 512);
    const header_sector = try allocator.alloc(u8, header_buf_size);
    defer allocator.free(header_sector);

    controller.readBlocks(nsid, 1, 1, header_sector) catch {
        console.warn("Partitions: Failed to read GPT header", .{});
        return;
    };

    const header: *align(1) gpt.GptHeader = @ptrCast(header_sector);
    if (!header.isValid()) {
        console.warn("Partitions: Invalid GPT signature", .{});
        return;
    }

    // SECURITY: Validate minimum partition entry size per UEFI spec (128 bytes).
    if (header.size_partition_entry < @sizeOf(gpt.GptEntry)) {
        console.warn("Partitions: GPT entry size too small ({} < 128)", .{header.size_partition_entry});
        return;
    }

    // Read Partition Entries
    const entries_size = std.math.mul(u64, header.num_partition_entries, header.size_partition_entry) catch {
        console.warn("Partitions: GPT table size overflow", .{});
        return;
    };
    const entries_lbas = (entries_size + lba_size - 1) / lba_size;

    // Limit reasonable size
    if (entries_lbas > 128) {
        console.warn("Partitions: GPT table too large ({} LBAs)", .{entries_lbas});
        return;
    }

    const table_buffer = try allocator.alloc(u8, entries_lbas * lba_size);
    defer allocator.free(table_buffer);

    const entries_lbas_u32: u32 = @intCast(entries_lbas);
    controller.readBlocks(nsid, header.partition_entry_lba, entries_lbas_u32, table_buffer) catch {
        console.warn("Partitions: Failed to read GPT entries", .{});
        return;
    };

    var index: u32 = 1;
    var i: u32 = 0;
    while (i < header.num_partition_entries) : (i += 1) {
        const offset = std.math.mul(u32, i, header.size_partition_entry) catch break;
        const end_offset = std.math.add(u32, offset, @sizeOf(gpt.GptEntry)) catch break;
        if (end_offset > table_buffer.len) break;

        const entry: *align(1) gpt.GptEntry = @ptrCast(table_buffer[offset..].ptr);

        if (entry.isValid()) {
            const diff = std.math.sub(u64, entry.last_lba, entry.first_lba) catch continue;
            const size = std.math.add(u64, diff, 1) catch continue;
            try registerNvmePartition(ns_index, nsid, disk_name, index, entry.first_lba, size, lba_size);
            index += 1;
        }
    }
}

/// Register an NVMe partition with devfs.
/// SECURITY NOTE (Partition Bounds): Bounds validation deferred to NVMe driver layer.
/// See registerPartition() for rationale.
fn registerNvmePartition(ns_index: u8, nsid: u32, disk_name: []const u8, index: u32, start: u64, count: u64, lba_size: u32) !void {
    const allocator = heap.allocator();

    // Create partition struct
    const part = try allocator.create(NvmePartition);
    part.* = NvmePartition{
        .ns_index = ns_index,
        .nsid = nsid,
        .start_lba = start,
        .sector_count = count,
        .lba_size = lba_size,
        .index = index,
    };

    // Create name: nvme0n1p1, nvme0n1p2...
    const name = try std.fmt.allocPrint(allocator, "{s}p{d}", .{ disk_name, index });

    // Register
    try devfs.registerDevice(name, &nvme_partition_ops, part);

    console.info("Partitions: Registered {s} (start={d}, sectors={d})", .{ name, start, count });
}

// =============================================================================
// VirtIO-SCSI Partition Support
// =============================================================================

/// VirtIO-SCSI partition information
pub const VirtioScsiPartition = struct {
    lun_index: u8,
    start_lba: u64,
    sector_count: u64,
    block_size: u32,
    index: u32, // Partition index (1-based)
};

pub const virtio_scsi_partition_ops = FileOps{
    .read = virtioScsiPartitionRead,
    .write = virtioScsiPartitionWrite,
    .close = virtioScsiPartitionClose,
    .seek = virtioScsiPartitionSeek,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

fn virtioScsiPartitionRead(fd: *FileDescriptor, buf: []u8) isize {
    const part = @as(*VirtioScsiPartition, @ptrCast(@alignCast(fd.private_data)));
    const controller = virtio_scsi.getController() orelse return Errno.EIO.toReturn();

    const pos = fd.position;
    const block_size = part.block_size;

    // Security: Use checked arithmetic to prevent overflow
    const part_size_bytes = std.math.mul(u64, part.sector_count, block_size) catch return Errno.ERANGE.toReturn();
    if (pos >= part_size_bytes) return 0; // EOF

    var read_len = buf.len;
    const end_pos = std.math.add(usize, pos, buf.len) catch return Errno.ERANGE.toReturn();
    if (end_pos > part_size_bytes) {
        read_len = @intCast(part_size_bytes - pos);
    }

    // Calculate LBA relative to LUN
    const pos_blocks = pos / block_size;
    const start_lba = std.math.add(u64, part.start_lba, pos_blocks) catch return Errno.ERANGE.toReturn();
    const start_offset = pos % block_size;

    const end_pos_padded = std.math.add(usize, pos + read_len, block_size - 1) catch return Errno.ERANGE.toReturn();
    const end_lba = std.math.add(u64, part.start_lba, end_pos_padded / block_size) catch return Errno.ERANGE.toReturn();
    if (end_lba < start_lba) return Errno.ERANGE.toReturn();
    const block_count_u64 = end_lba - start_lba;

    // VirtIO-SCSI max transfer is typically 256 blocks
    if (block_count_u64 > 256) {
        return Errno.EINVAL.toReturn();
    }
    const block_count: u32 = @intCast(block_count_u64);

    // Fast path: aligned
    if (start_offset == 0 and read_len % block_size == 0) {
        _ = controller.readBlocks(part.lun_index, start_lba, block_count, buf[0..read_len]) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += read_len;
        const result = std.math.cast(isize, read_len) orelse return Errno.ERANGE.toReturn();
        return result;
    }

    // Bounce buffer path
    const bounce_size = @as(usize, block_count) * block_size;
    const allocator = heap.allocator();
    const bounce = allocator.alloc(u8, bounce_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer allocator.free(bounce);

    _ = controller.readBlocks(part.lun_index, start_lba, block_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    const copy_start: usize = start_offset;
    @memcpy(buf[0..read_len], bounce[copy_start .. copy_start + read_len]);

    fd.position += read_len;
    const result = std.math.cast(isize, read_len) orelse return Errno.ERANGE.toReturn();
    return result;
}

fn virtioScsiPartitionWrite(fd: *FileDescriptor, buf: []const u8) isize {
    const part = @as(*VirtioScsiPartition, @ptrCast(@alignCast(fd.private_data)));
    const controller = virtio_scsi.getController() orelse return Errno.EIO.toReturn();

    const pos = fd.position;
    const block_size = part.block_size;

    const part_size_bytes = std.math.mul(u64, part.sector_count, block_size) catch return Errno.ERANGE.toReturn();
    if (pos >= part_size_bytes) return Errno.ENOSPC.toReturn();

    var write_len = buf.len;
    const end_pos = std.math.add(usize, pos, write_len) catch return Errno.ERANGE.toReturn();
    if (end_pos > part_size_bytes) {
        write_len = @intCast(part_size_bytes - pos);
    }

    const pos_blocks = pos / block_size;
    const start_lba = std.math.add(u64, part.start_lba, pos_blocks) catch return Errno.ERANGE.toReturn();
    const start_offset = pos % block_size;

    const end_pos_padded = std.math.add(usize, pos + write_len, block_size - 1) catch return Errno.ERANGE.toReturn();
    const end_lba = std.math.add(u64, part.start_lba, end_pos_padded / block_size) catch return Errno.ERANGE.toReturn();
    if (end_lba < start_lba) return Errno.ERANGE.toReturn();
    const block_count_u64 = end_lba - start_lba;

    if (block_count_u64 > 256) {
        return Errno.EINVAL.toReturn();
    }
    const block_count: u32 = @intCast(block_count_u64);

    if (start_offset == 0 and write_len % block_size == 0) {
        _ = controller.writeBlocks(part.lun_index, start_lba, block_count, buf[0..write_len]) catch {
            return Errno.EIO.toReturn();
        };
        fd.position += write_len;
        const result = std.math.cast(isize, write_len) orelse return Errno.ERANGE.toReturn();
        return result;
    }

    // RMW
    const bounce_size = @as(usize, block_count) * block_size;
    const allocator = heap.allocator();
    const bounce = allocator.alloc(u8, bounce_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer allocator.free(bounce);

    _ = controller.readBlocks(part.lun_index, start_lba, block_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    const copy_start: usize = start_offset;
    @memcpy(bounce[copy_start .. copy_start + write_len], buf[0..write_len]);

    _ = controller.writeBlocks(part.lun_index, start_lba, block_count, bounce) catch {
        return Errno.EIO.toReturn();
    };

    fd.position += write_len;
    const result = std.math.cast(isize, write_len) orelse return Errno.ERANGE.toReturn();
    return result;
}

fn virtioScsiPartitionClose(_: *FileDescriptor) isize {
    // VirtIO-SCSI sync is handled by adapter.blockClose
    return 0;
}

fn virtioScsiPartitionSeek(fd: *FileDescriptor, offset: i64, whence: u32) isize {
    const part = @as(*VirtioScsiPartition, @ptrCast(@alignCast(fd.private_data)));
    const part_size = std.math.mul(u64, part.sector_count, part.block_size) catch return Errno.ERANGE.toReturn();

    const SEEK_SET: u32 = 0;
    const SEEK_CUR: u32 = 1;
    const SEEK_END: u32 = 2;

    const pos_i64 = std.math.cast(i64, fd.position) orelse return Errno.ERANGE.toReturn();
    const size_i64 = std.math.cast(i64, part_size) orelse return Errno.ERANGE.toReturn();

    // SECURITY: Use checked arithmetic to prevent signed overflow on SEEK_CUR/SEEK_END.
    const new_pos: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => std.math.add(i64, pos_i64, offset) catch return Errno.ERANGE.toReturn(),
        SEEK_END => std.math.add(i64, size_i64, offset) catch return Errno.ERANGE.toReturn(),
        else => return Errno.EINVAL.toReturn(),
    };

    if (new_pos < 0) {
        return Errno.EINVAL.toReturn();
    }

    fd.position = std.math.cast(usize, new_pos) orelse return Errno.ERANGE.toReturn();
    return std.math.cast(isize, fd.position) orelse return Errno.ERANGE.toReturn();
}

/// Scan a VirtIO-SCSI LUN for partitions and register them
pub fn scanAndRegisterVirtioScsi(lun_index: u8) !void {
    const allocator = heap.allocator();
    const controller = virtio_scsi.getController() orelse return;
    const lun_info = controller.getLun(lun_index) orelse return;

    if (!lun_info.active) return;

    // Register the raw LUN first (e.g. sda, sdb)
    // Use sd* naming for SCSI devices (consistent with AHCI and Linux convention)
    const drive_char = @as(u8, 'a') + lun_index;
    const disk_name = try std.fmt.allocPrint(allocator, "sd{c}", .{drive_char});

    // Register with VirtIO-SCSI adapter's block_ops
    try devfs.registerDevice(disk_name, &virtio_scsi.adapter.block_ops, @ptrFromInt(@as(usize, lun_index)));

    console.info("Partitions: Scanning {s}...", .{disk_name});

    // Read LBA 0 (MBR)
    const block_size = lun_info.block_size;
    const mbr_buf_size = @max(block_size, 512);
    const mbr_sector = try allocator.alloc(u8, mbr_buf_size);
    defer allocator.free(mbr_sector);

    _ = controller.readBlocks(lun_index, 0, 1, mbr_sector) catch |err| {
        console.warn("Partitions: Failed to read MBR from {s}: {}", .{ disk_name, err });
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
        try scanGptVirtioScsi(lun_index, disk_name, block_size);
        return;
    }

    // Process MBR partitions
    console.info("Partitions: Found MBR on {s}", .{disk_name});
    var index: u32 = 1;
    for (mbr_data.partitions()) |entry| {
        if (entry.isValid()) {
            try registerVirtioScsiPartition(lun_index, disk_name, index, entry.lba_start, entry.sector_count, block_size);
            index += 1;
        }
    }
}

fn scanGptVirtioScsi(lun_index: u8, disk_name: []const u8, block_size: u32) !void {
    const allocator = heap.allocator();
    const controller = virtio_scsi.getController() orelse return;

    // Read GPT Header (LBA 1)
    const header_buf_size = @max(block_size, 512);
    const header_sector = try allocator.alloc(u8, header_buf_size);
    defer allocator.free(header_sector);

    _ = controller.readBlocks(lun_index, 1, 1, header_sector) catch {
        console.warn("Partitions: Failed to read GPT header", .{});
        return;
    };

    const header: *align(1) gpt.GptHeader = @ptrCast(header_sector);
    if (!header.isValid()) {
        console.warn("Partitions: Invalid GPT signature", .{});
        return;
    }

    // SECURITY: Validate minimum partition entry size per UEFI spec (128 bytes).
    if (header.size_partition_entry < @sizeOf(gpt.GptEntry)) {
        console.warn("Partitions: GPT entry size too small ({} < 128)", .{header.size_partition_entry});
        return;
    }

    // Read Partition Entries
    const entries_size = std.math.mul(u64, header.num_partition_entries, header.size_partition_entry) catch {
        console.warn("Partitions: GPT table size overflow", .{});
        return;
    };
    const entries_blocks = (entries_size + block_size - 1) / block_size;

    // Limit reasonable size
    if (entries_blocks > 128) {
        console.warn("Partitions: GPT table too large ({} blocks)", .{entries_blocks});
        return;
    }

    const table_buffer = try allocator.alloc(u8, entries_blocks * block_size);
    defer allocator.free(table_buffer);

    const entries_blocks_u32: u32 = @intCast(entries_blocks);
    _ = controller.readBlocks(lun_index, header.partition_entry_lba, entries_blocks_u32, table_buffer) catch {
        console.warn("Partitions: Failed to read GPT entries", .{});
        return;
    };

    var index: u32 = 1;
    var i: u32 = 0;
    while (i < header.num_partition_entries) : (i += 1) {
        const offset = std.math.mul(u32, i, header.size_partition_entry) catch break;
        const end_offset = std.math.add(u32, offset, @sizeOf(gpt.GptEntry)) catch break;
        if (end_offset > table_buffer.len) break;

        const entry: *align(1) gpt.GptEntry = @ptrCast(table_buffer[offset..].ptr);

        if (entry.isValid()) {
            const diff = std.math.sub(u64, entry.last_lba, entry.first_lba) catch continue;
            const size = std.math.add(u64, diff, 1) catch continue;
            try registerVirtioScsiPartition(lun_index, disk_name, index, entry.first_lba, size, block_size);
            index += 1;
        }
    }
}

/// Register a VirtIO-SCSI partition with devfs.
/// SECURITY NOTE (Partition Bounds): Bounds validation deferred to VirtIO-SCSI driver layer.
/// See registerPartition() for rationale.
fn registerVirtioScsiPartition(lun_index: u8, disk_name: []const u8, index: u32, start: u64, count: u64, block_size: u32) !void {
    const allocator = heap.allocator();

    // Create partition struct
    const part = try allocator.create(VirtioScsiPartition);
    part.* = VirtioScsiPartition{
        .lun_index = lun_index,
        .start_lba = start,
        .sector_count = count,
        .block_size = block_size,
        .index = index,
    };

    // Create name: sda1, sda2...
    const name = try std.fmt.allocPrint(allocator, "{s}{d}", .{ disk_name, index });

    // Register
    try devfs.registerDevice(name, &virtio_scsi_partition_ops, part);

    console.info("Partitions: Registered {s} (start={d}, sectors={d})", .{ name, start, count });
}
