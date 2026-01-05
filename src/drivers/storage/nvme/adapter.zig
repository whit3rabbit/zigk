// NVMe Block Device Adapter
//
// Provides FileOps wrapper for NVMe namespaces, translating byte-oriented
// syscalls (read/write/seek) to block-based NVMe operations.
//
// Device naming: /dev/nvme0n1, /dev/nvme0n2, etc.
// Partition naming: /dev/nvme0n1p1, /dev/nvme0n1p2, etc.

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const heap = @import("heap");
const fd = @import("fd");
const pmm = @import("pmm");
const dma = @import("dma");
const io = @import("io");

const root = @import("root.zig");
const init_mod = @import("init.zig");

// ============================================================================
// Constants
// ============================================================================

const PAGE_SIZE: usize = init_mod.PAGE_SIZE;

// Error codes (negative errno values)
const EIO: isize = -5;
const ENOMEM: isize = -12;
const EINVAL: isize = -22;
const ENOSPC: isize = -28;
const ESPIPE: isize = -29;

// ============================================================================
// Private Data Structure
// ============================================================================

/// Per-file descriptor private data
pub const NvmePrivateData = struct {
    /// Controller reference
    controller: *root.NvmeController,
    /// Namespace ID
    nsid: u32,
    /// LBA size in bytes
    lba_size: u32,
    /// Total LBAs in namespace
    total_lbas: u64,
};

// ============================================================================
// FileOps Implementation
// ============================================================================

/// Block device operations for NVMe namespaces
pub const block_ops = fd.FileOps{
    .read = blockRead,
    .write = blockWrite,
    .close = blockClose,
    .seek = blockSeek,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

/// Read from NVMe namespace
fn blockRead(file: *fd.FileDescriptor, buf: []u8) isize {
    const priv = getPrivateData(file) orelse return EIO;

    if (buf.len == 0) return 0;

    const pos = file.position;
    const lba_size = priv.lba_size;

    // Calculate LBA range
    const start_lba = pos / lba_size;
    const start_offset = pos % lba_size;
    const end_pos = std.math.add(u64, pos, buf.len) catch return EINVAL;
    const end_lba_raw = (end_pos + lba_size - 1) / lba_size;

    // Check bounds
    if (start_lba >= priv.total_lbas) {
        return 0; // EOF
    }

    const end_lba = @min(end_lba_raw, priv.total_lbas);
    const block_count: u32 = @intCast(end_lba - start_lba);

    if (block_count == 0) {
        return 0;
    }

    // Fast path: aligned access, single transfer
    if (start_offset == 0 and buf.len >= block_count * lba_size) {
        // Aligned - can read directly into user buffer if it's DMA-safe
        // For now, always use bounce buffer for safety
    }

    // Allocate bounce buffer
    const total_bytes = @as(usize, block_count) * lba_size;

    const bounce = heap.allocator().alloc(u8, total_bytes) catch {
        return ENOMEM;
    };
    defer heap.allocator().free(bounce);

    // Zero-init bounce buffer (security)
    @memset(bounce, 0);

    // Perform read
    priv.controller.readBlocks(
        priv.nsid,
        start_lba,
        block_count,
        bounce,
    ) catch {
        return EIO;
    };

    // Copy to user buffer (handling offset and length)
    const copy_start = @as(usize, @intCast(start_offset));
    const available = total_bytes - copy_start;
    const copy_len = @min(buf.len, available);

    @memcpy(buf[0..copy_len], bounce[copy_start .. copy_start + copy_len]);

    // Update position
    file.position += copy_len;

    return @intCast(copy_len);
}

/// Write to NVMe namespace
fn blockWrite(file: *fd.FileDescriptor, buf: []const u8) isize {
    const priv = getPrivateData(file) orelse return EIO;

    if (buf.len == 0) return 0;

    const pos = file.position;
    const lba_size = priv.lba_size;

    // Calculate LBA range
    const start_lba = pos / lba_size;
    const start_offset = pos % lba_size;
    const end_pos = std.math.add(u64, pos, buf.len) catch return EINVAL;
    const end_lba_raw = (end_pos + lba_size - 1) / lba_size;

    // Check bounds
    if (start_lba >= priv.total_lbas) {
        return ENOSPC;
    }

    const end_lba = @min(end_lba_raw, priv.total_lbas);
    const block_count: u32 = @intCast(end_lba - start_lba);

    if (block_count == 0) {
        return 0;
    }

    const total_bytes = @as(usize, block_count) * lba_size;

    // Check if partial block write (requires read-modify-write)
    const is_partial = (start_offset != 0) or (buf.len % lba_size != 0);

    // Allocate bounce buffer
    const bounce = heap.allocator().alloc(u8, total_bytes) catch {
        return ENOMEM;
    };
    defer heap.allocator().free(bounce);

    if (is_partial) {
        // Read existing data first
        priv.controller.readBlocks(
            priv.nsid,
            start_lba,
            block_count,
            bounce,
        ) catch {
            return EIO;
        };
    } else {
        // Zero-init bounce buffer
        @memset(bounce, 0);
    }

    // Copy user data to bounce buffer
    const copy_start = @as(usize, @intCast(start_offset));
    const available = total_bytes - copy_start;
    const copy_len = @min(buf.len, available);

    @memcpy(bounce[copy_start .. copy_start + copy_len], buf[0..copy_len]);

    // Perform write
    priv.controller.writeBlocks(
        priv.nsid,
        start_lba,
        block_count,
        bounce,
    ) catch {
        return EIO;
    };

    // Update position
    file.position += copy_len;

    return @intCast(copy_len);
}

/// Close NVMe file descriptor
fn blockClose(file: *fd.FileDescriptor) isize {
    if (file.private_data) |ptr| {
        const priv: *NvmePrivateData = @ptrCast(@alignCast(ptr));
        heap.allocator().destroy(priv);
        file.private_data = null;
    }
    return 0;
}

/// Seek in NVMe namespace
fn blockSeek(file: *fd.FileDescriptor, offset: i64, whence: u32) isize {
    const priv = getPrivateData(file) orelse return EIO;

    const total_size: i64 = @intCast(priv.total_lbas * priv.lba_size);
    var new_pos: i64 = undefined;

    switch (whence) {
        0 => { // SEEK_SET
            new_pos = offset;
        },
        1 => { // SEEK_CUR
            new_pos = @as(i64, @intCast(file.position)) + offset;
        },
        2 => { // SEEK_END
            new_pos = total_size + offset;
        },
        else => return EINVAL,
    }

    if (new_pos < 0 or new_pos > total_size) {
        return EINVAL;
    }

    file.position = @intCast(new_pos);
    return @intCast(new_pos);
}

// ============================================================================
// Helper Functions
// ============================================================================

fn getPrivateData(file: *fd.FileDescriptor) ?*NvmePrivateData {
    if (file.private_data) |ptr| {
        return @ptrCast(@alignCast(ptr));
    }
    return null;
}

// ============================================================================
// File Descriptor Creation
// ============================================================================

/// Create a file descriptor for an NVMe namespace
pub fn createBlockFd(nsid: u32, flags: u32) !*fd.FileDescriptor {
    const controller = root.getController() orelse return error.NoController;
    const ns = controller.findNamespace(nsid) orelse return error.NamespaceNotFound;

    // Allocate private data
    const priv = try heap.allocator().create(NvmePrivateData);
    errdefer heap.allocator().destroy(priv);

    priv.* = NvmePrivateData{
        .controller = controller,
        .nsid = nsid,
        .lba_size = ns.lba_size,
        .total_lbas = ns.total_lbas,
    };

    // Create file descriptor
    return fd.createFd(&block_ops, flags, @ptrCast(priv));
}

// ============================================================================
// Async I/O Support
// ============================================================================

pub const AsyncBlockError = error{
    NoController,
    NamespaceNotFound,
    AllocationFailed,
    QueueFull,
};

/// Allocate DMA buffer and start async read
pub fn blockReadAsync(
    nsid: u32,
    lba: u64,
    block_count: u32,
    request: *io.IoRequest,
) AsyncBlockError!u64 {
    const controller = root.getController() orelse return error.NoController;
    const ns = controller.findNamespace(nsid) orelse return error.NamespaceNotFound;

    // Allocate DMA buffer
    const bytes_needed = @as(usize, block_count) * ns.lba_size;
    const pages = (bytes_needed + PAGE_SIZE - 1) / PAGE_SIZE;

    const buf_phys = pmm.allocZeroedPages(pages) orelse return error.AllocationFailed;

    // Store buffer info in request for cleanup
    request.buf_ptr = buf_phys;
    request.buf_len = bytes_needed;

    // Submit async request
    controller.readBlocksAsync(nsid, lba, block_count, buf_phys, request) catch |err| {
        pmm.freePages(buf_phys, pages);
        return switch (err) {
            error.NamespaceNotFound => error.NamespaceNotFound,
            error.NoCapacity => error.QueueFull,
            else => error.AllocationFailed,
        };
    };

    return buf_phys;
}

/// Allocate DMA buffer, copy data, and start async write
pub fn blockWriteAsync(
    nsid: u32,
    lba: u64,
    block_count: u32,
    data: []const u8,
    request: *io.IoRequest,
) AsyncBlockError!u64 {
    const controller = root.getController() orelse return error.NoController;
    const ns = controller.findNamespace(nsid) orelse return error.NamespaceNotFound;

    // Allocate DMA buffer
    const bytes_needed = @as(usize, block_count) * ns.lba_size;
    const pages = (bytes_needed + PAGE_SIZE - 1) / PAGE_SIZE;

    const buf_phys = pmm.allocZeroedPages(pages) orelse return error.AllocationFailed;

    // Copy data to DMA buffer
    const buf_virt: [*]u8 = @ptrCast(hal.paging.physToVirt(buf_phys));
    const copy_len = @min(data.len, bytes_needed);
    @memcpy(buf_virt[0..copy_len], data[0..copy_len]);

    // Store buffer info in request for cleanup
    request.buf_ptr = buf_phys;
    request.buf_len = bytes_needed;

    // Submit async request
    controller.writeBlocksAsync(nsid, lba, block_count, buf_phys, request) catch |err| {
        pmm.freePages(buf_phys, pages);
        return switch (err) {
            error.NamespaceNotFound => error.NamespaceNotFound,
            error.NoCapacity => error.QueueFull,
            else => error.AllocationFailed,
        };
    };

    return buf_phys;
}

/// Copy data from DMA buffer to destination
pub fn copyFromDmaBuffer(buf_phys: u64, dest: []u8) void {
    const src: [*]u8 = @ptrCast(hal.paging.physToVirt(buf_phys));
    @memcpy(dest, src[0..dest.len]);
}

/// Free DMA buffer after async operation completes
pub fn freeDmaBuffer(buf_phys: u64, size: usize) void {
    const pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;
    pmm.freePages(buf_phys, pages);
}

// ============================================================================
// Device Registration
// ============================================================================

/// Register NVMe namespaces with DevFS
pub fn registerNamespaces() !void {
    const controller = root.getController() orelse return error.NoController;
    const devfs = @import("devfs");

    for (0..controller.namespace_count) |i| {
        if (controller.getNamespace(@intCast(i))) |ns| {
            // Generate device name: nvme0n{nsid}
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "nvme0n{d}", .{ns.nsid}) catch continue;

            // Allocate private data
            const priv = heap.allocator().create(NvmePrivateData) catch continue;
            priv.* = NvmePrivateData{
                .controller = controller,
                .nsid = ns.nsid,
                .lba_size = ns.lba_size,
                .total_lbas = ns.total_lbas,
            };

            // Register with DevFS
            devfs.registerDevice(name, &block_ops, @ptrCast(priv)) catch |err| {
                console.warn("NVMe: Failed to register {s}: {}", .{ name, err });
                heap.allocator().destroy(priv);
                continue;
            };

            console.info("NVMe: Registered /dev/{s}", .{name});

            // Scan for partitions
            const partitions = @import("partitions");
            partitions.scanAndRegisterNvme(@intCast(i), ns.nsid) catch |err| {
                console.warn("NVMe: Partition scan failed for {s}: {}", .{ name, err });
            };
        }
    }
}
