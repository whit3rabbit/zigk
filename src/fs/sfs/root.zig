const std = @import("std");
const vfs = @import("../vfs.zig");
const fd = @import("fd");
const heap = @import("heap");
const console = @import("console");
const t = @import("types.zig");
const sfs_io = @import("io.zig");
const sfs_alloc = @import("alloc.zig");
const sfs_ops = @import("ops.zig");

// Re-export common types
pub const SFS = t.SFS;
pub const SfsFile = t.SfsFile;
pub const Superblock = t.Superblock;
pub const DirEntry = t.DirEntry;
pub const SfsError = t.SfsError;

/// Initialize SFS on a device
/// Opens the device, checks magic, formats if needed.
pub fn init(device_path: []const u8) !vfs.FileSystem {
    // Open block device
    const device_fd = try vfs.Vfs.open(device_path, fd.O_RDWR);

    const alloc = heap.allocator();
    const self = try alloc.create(SFS);
    self.* = .{
        .device_fd = device_fd,
        .superblock = undefined,
        .port_num = @intCast(@intFromPtr(device_fd.private_data) & 0x1F),
    };

    // Read superblock (before SFS struct fully initialized, use raw device_fd)
    // TEMPORARY: Direct FD access - switch to readSector(self, ...) after init
    var sb_buf: [512]u8 = undefined;
    {
        const old_pos = device_fd.position;
        device_fd.position = 0;
        if (device_fd.ops.read) |read_fn| {
            const bytes_read = read_fn(device_fd, &sb_buf);
            device_fd.position = old_pos;
            if (bytes_read < 512) {
                console.err("SFS: Failed to read superblock from {s}", .{device_path});
                return error.IOError;
            }
        } else {
            device_fd.position = old_pos;
            console.err("SFS: No read operation available on {s}", .{device_path});
            return error.IOError;
        }
    }
    self.superblock = @as(*const t.Superblock, @ptrCast(@alignCast(&sb_buf))).*;

    // Check magic
    if (self.superblock.magic != t.SFS_MAGIC) {
        if (self.superblock.magic == t.SFS_MAGIC_V2) {
            console.warn("SFS: Found legacy V2 filesystem, mounting read-only", .{});
        } else {
            console.info("SFS: No valid filesystem found on {s},formatting...", .{device_path});
            try format(self);
            console.info("SFS: Format complete", .{});
        }
    } else {
        // SECURITY: Validate superblock fields
        if (!sfs_alloc.validateSuperblock(&self.superblock)) {
            console.err("SFS: Malicious or corrupted superblock detected on {s}", .{device_path});
            return error.IOError;
        }

        if (self.superblock.file_count > 0) {
            console.info("SFS: Mounted '{s}' with {} files ({} bytes free)", .{
                device_path,
                self.superblock.file_count,
                self.superblock.free_blocks * t.SECTOR_SIZE,
            });
            console.info("SFS: Superblock magic=0x{X} files={} free={}", .{
                self.superblock.magic,
                self.superblock.file_count,
                self.superblock.free_blocks,
            });
        }
    }

    // SECURITY: Allocate bitmap cache to prevent heap fragmentation.
    // Resource exhaustion is bounded by validateSuperblock() which limits bitmap_blocks to 16,
    // resulting in a maximum allocation of 16 * 512 = 8KB per mount.
    // System-wide mount limits are enforced at the VFS layer (see vfs.zig MAX_MOUNTS).
    const bitmap_size = self.superblock.bitmap_blocks * t.SECTOR_SIZE;
    self.bitmap_cache = alloc.alloc(u8, bitmap_size) catch null;
    self.bitmap_cache_valid = false;

    return vfs.FileSystem{
        .context = self,
        .open = sfs_ops.sfsOpen,
        .unmount = sfs_ops.sfsUnmount,
        .unlink = sfs_ops.sfsUnlink,
        .stat_path = sfs_ops.sfsStatPath,
        .chmod = sfs_ops.sfsChmod,
        .chown = sfs_ops.sfsChown,
        .mkdir = sfs_ops.sfsMkdir,
        .rmdir = sfs_ops.sfsRmdir,
        .rename = sfs_ops.sfsRename,
        .getdents = sfs_ops.sfsGetdents,
        .statfs = sfs_ops.sfsStatfs,
        .link = sfs_ops.sfsLink,
        .set_timestamps = sfs_ops.sfsSetTimestamps,
    };
}

fn format(self: *SFS) !void {
    // Calculate total blocks (assume 16MB disk for now)
    const total_blocks: u32 = 32768; // 16MB / 512B per sector

    self.superblock = t.Superblock{
        .magic = t.SFS_MAGIC,
        .version = t.SFS_VERSION,
        .block_size = t.SECTOR_SIZE,
        .total_blocks = total_blocks,
        .file_count = 0,
        .free_blocks = total_blocks - t.DATA_START_BLOCK,
        .bitmap_start = 1,
        .bitmap_blocks = t.BITMAP_BLOCKS,
        .root_dir_start = 1 + t.BITMAP_BLOCKS,
        .data_start = t.DATA_START_BLOCK,
        .next_free_block = t.DATA_START_BLOCK,
        ._pad = [_]u8{0} ** (512 - 44),
    };

    try sfs_io.updateSuperblock(self);

    // Clear bitmap blocks
    const zero_buf = [_]u8{0} ** 512;
    var i: u32 = 0;
    while (i < t.BITMAP_BLOCKS) : (i += 1) {
        try sfs_io.writeSector(self, self.superblock.bitmap_start + i, &zero_buf);
    }

    // Clear root directory blocks
    i = 0;
    while (i < t.ROOT_DIR_BLOCKS) : (i += 1) {
        try sfs_io.writeSector(self, self.superblock.root_dir_start + i, &zero_buf);
    }
}
