//! InitRD (Initial RAM Disk) Filesystem
//!
//! Provides read-only access to files loaded by the bootloader as modules.
//! The expected format is a USTAR tar archive.
//!
//! Usage:
//! - Initialized by `init_proc.zig` with module data from Limine.
//! - Used by `vfs.zig` to mount at `/`.
//! - Supports `open`, `read`, `seek`, `stat`, `close`.

const std = @import("std");
const fd = @import("fd");
const heap = @import("heap");
const uapi = @import("uapi");
const console = @import("console");

/// USTAR TAR Header (512 bytes)
/// Reference: specs/003.../contracts/initrd-format.md
/// Note: Using extern struct for fixed layout; packed not allowed for arrays in Zig 0.15+
pub const TarHeader = extern struct {
    name: [100]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    size: [12]u8,
    mtime: [12]u8,
    checksum: [8]u8,
    typeflag: u8,
    linkname: [100]u8,
    magic: [6]u8,
    version: [2]u8,
    uname: [32]u8,
    gname: [32]u8,
    devmajor: [8]u8,
    devminor: [8]u8,
    prefix: [155]u8,
    _pad: [12]u8,

    comptime {
        if (@sizeOf(@This()) != 512) @compileError("TarHeader must be 512 bytes");
    }

    pub fn isValid(self: *const @This()) bool {
        return std.mem.eql(u8, self.magic[0..5], "ustar");
    }

    pub fn getName(self: *const @This()) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..end];
    }

    pub fn getSize(self: *const @This()) ?usize {
        var size: usize = 0;
        for (self.size) |c| {
            if (c == ' ' or c == 0) break;
            if (c < '0' or c > '7') break;

            // Checked multiplication to detect overflow
            const mul_result = @mulWithOverflow(size, 8);
            if (mul_result[1] != 0) return null;

            // Checked addition to detect overflow
            const add_result = @addWithOverflow(mul_result[0], c - '0');
            if (add_result[1] != 0) return null;

            size = add_result[0];
        }
        return size;
    }

    pub fn isRegularFile(self: *const @This()) bool {
        return self.typeflag == '0' or self.typeflag == 0;
    }
};

/// Represents a file found in the InitRD
pub const InitRDFile = struct {
    name: []const u8,
    data: []const u8,
};

/// InitRD Filesystem Handler
pub const InitRD = struct {
    data: []const u8,

    /// Global instance
    pub var instance: InitRD = .{ .data = &[_]u8{} };

    /// Initialize the global instance
    pub fn init(data: []const u8) void {
        instance = InitRD{ .data = data };
    }

    /// Find a file by path in the InitRD
    pub fn findFile(self: *const @This(), path: []const u8) ?InitRDFile {
        // Normalize path: remove leading '/' if present
        const search_name = if (path.len > 0 and path[0] == '/')
            path[1..]
        else
            path;

        console.err("InitRD: findFile search='{s}' (orig='{s}')", .{search_name, path});

        var offset: usize = 0;
        // Need at least 512 bytes for a header
        while (offset + 512 <= self.data.len) {
            const header: *const TarHeader = @ptrCast(self.data.ptr + offset);

            // Check for end of archive (two zero blocks, checking first char suffices for now)
            if (header.name[0] == 0) break;

            // Validate USTAR magic
            if (!header.isValid()) break;

            const name = header.getName();
            const size = header.getSize() orelse break; // Overflow in size field

            // Calculate data bounds with overflow checking
            const data_start_result = @addWithOverflow(offset, 512);
            if (data_start_result[1] != 0) break;
            const data_start = data_start_result[0];

            const data_end_result = @addWithOverflow(data_start, size);
            if (data_end_result[1] != 0) break;
            const data_end = data_end_result[0];

            // Validate data bounds before slicing
            if (data_end > self.data.len) break;

            // Check if this is the file we are looking for
            // Normalize header name: remove leading './' if present (common in tar)
            var header_name = name;
            if (std.mem.startsWith(u8, header_name, "./")) {
                header_name = header_name[2..];
            }

            if (header.isRegularFile() and std.mem.eql(u8, header_name, search_name)) {
                return InitRDFile{
                    .name = name,
                    .data = self.data[data_start..data_end],
                };
            }

            // Calculate next offset with overflow checking
            const padded_size_result = @addWithOverflow(size, 511);
            if (padded_size_result[1] != 0) break;
            const data_blocks = padded_size_result[0] / 512;

            const block_bytes_result = @mulWithOverflow(data_blocks, 512);
            if (block_bytes_result[1] != 0) break;

            const next_offset_result = @addWithOverflow(data_start, block_bytes_result[0]);
            if (next_offset_result[1] != 0) break;
            const next_offset = next_offset_result[0];

            if (next_offset > self.data.len) break;
            offset = next_offset;
            
            // Debug Log
            console.debug("InitRD Scan: '{s}' (norm: '{s}') vs search '{s}'", .{name, header_name, search_name});
        }
        return null;
    }

    /// Iterator for listing files
    pub fn listFiles(self: *const @This()) FileIterator {
        return FileIterator{ .initrd = self, .offset = 0 };
    }

    /// Open a file from InitRD
    pub fn openFile(self: *const @This(), path: []const u8, flags: u32) !*fd.FileDescriptor {
        const file = self.findFile(path) orelse return error.FileNotFound;

        // Allocate a container for the file reference
        const alloc = heap.allocator();
        const file_ptr = try alloc.create(InitRDFile);
        file_ptr.* = file;

        // Create the descriptor
        return fd.createFd(&initrd_ops, flags, file_ptr);
    }
};

// File Operations for InitRD
const initrd_ops = fd.FileOps{
    .read = initrdRead,
    .write = initrdWrite, // Read-only
    .close = initrdClose,
    .seek = initrdSeek,
    .stat = initrdStat,
    .ioctl = null,
    .mmap = null,
};

fn initrdStat(file_desc: *fd.FileDescriptor, stat_buf: *anyopaque) isize {
    const file: *InitRDFile = @ptrCast(@alignCast(file_desc.private_data));
    const stat: *uapi.stat.Stat = @ptrCast(@alignCast(stat_buf));

    // Clamp size to i64 max for very large files
    const max_i64: usize = @intCast(std.math.maxInt(i64));
    const file_size: i64 = if (file.data.len > max_i64)
        std.math.maxInt(i64)
    else
        @intCast(file.data.len);
    const blocks: i64 = if (file.data.len > max_i64)
        std.math.maxInt(i64) / 512
    else
        @intCast((file.data.len + 511) / 512);

    stat.* = .{
        .dev = 0,
        .ino = 0,
        .nlink = 1,
        .mode = 0o100755, // Regular file
        .uid = 0,
        .gid = 0,
        .rdev = 0,
        .size = file_size,
        .blksize = 512,
        .blocks = blocks,
        .atime = 0,
        .atime_nsec = 0,
        .mtime = 0,
        .mtime_nsec = 0,
        .ctime = 0,
        .ctime_nsec = 0,
        .__pad0 = 0,
        .__unused = [_]i64{0} ** 3,
    };
    return 0;
}

fn initrdRead(file_desc: *fd.FileDescriptor, buf: []u8) isize {
    const file: *InitRDFile = @ptrCast(@alignCast(file_desc.private_data));

    // Bounds check
    if (file_desc.position >= file.data.len) return 0;

    const remaining = file.data.len - file_desc.position;
    const to_read = @min(buf.len, remaining);

    @memcpy(buf[0..to_read], file.data[file_desc.position..][0..to_read]);
    file_desc.position += to_read;

    // Safe cast: to_read bounded by buf.len which fits in isize
    return std.math.cast(isize, to_read) orelse return uapi.errno.Errno.ERANGE.toReturn();
}

fn initrdWrite(file_desc: *fd.FileDescriptor, buf: []const u8) isize {
    _ = file_desc;
    _ = buf;
    return uapi.errno.Errno.EROFS.toReturn();
}

fn initrdClose(file_desc: *fd.FileDescriptor) isize {
    // Free the InitRDFile container we allocated in openFile
    const alloc = heap.allocator();
    const file: *InitRDFile = @ptrCast(@alignCast(file_desc.private_data));
    alloc.destroy(file);
    return 0;
}

fn initrdSeek(file_desc: *fd.FileDescriptor, offset: i64, whence: u32) isize {
    const file: *InitRDFile = @ptrCast(@alignCast(file_desc.private_data));

    // Safe casts for file size and position to i64
    const file_size = std.math.cast(i64, file.data.len) orelse return uapi.errno.Errno.ERANGE.toReturn();
    const current = std.math.cast(i64, file_desc.position) orelse return uapi.errno.Errno.ERANGE.toReturn();

    const new_pos: i64 = switch (whence) {
        0 => offset,                    // SEEK_SET
        1 => current + offset,          // SEEK_CUR
        2 => file_size + offset,        // SEEK_END
        else => return uapi.errno.Errno.EINVAL.toReturn(),
    };

    if (new_pos < 0) return uapi.errno.Errno.EINVAL.toReturn();
    // In many filesystems you can seek past end (sparse files), but for InitRD read-only it makes sense to clamp or error?
    // Standard seeks usually allow seeking past end. But you can't read there.
    // Let's allow it but read will return 0.

    file_desc.position = std.math.cast(usize, new_pos) orelse return uapi.errno.Errno.ERANGE.toReturn();
    return std.math.cast(isize, new_pos) orelse return uapi.errno.Errno.ERANGE.toReturn();
}

pub const FileIterator = struct {
    initrd: *const InitRD,
    offset: usize,

    pub fn next(self: *@This()) ?InitRDFile {
        while (self.offset + 512 <= self.initrd.data.len) {
            const header: *const TarHeader = @ptrCast(self.initrd.data.ptr + self.offset);

            if (header.name[0] == 0) return null;
            if (!header.isValid()) return null;

            const name = header.getName();
            const size = header.getSize() orelse return null; // Overflow in size field

            // Calculate data bounds with overflow checking
            const data_start_result = @addWithOverflow(self.offset, 512);
            if (data_start_result[1] != 0) return null;
            const data_start = data_start_result[0];

            const data_end_result = @addWithOverflow(data_start, size);
            if (data_end_result[1] != 0) return null;
            const data_end = data_end_result[0];

            // Validate data bounds before slicing
            if (data_end > self.initrd.data.len) return null;

            // Calculate next offset with overflow checking
            const padded_size_result = @addWithOverflow(size, 511);
            if (padded_size_result[1] != 0) return null;
            const data_blocks = padded_size_result[0] / 512;

            const block_bytes_result = @mulWithOverflow(data_blocks, 512);
            if (block_bytes_result[1] != 0) return null;

            const next_offset_result = @addWithOverflow(data_start, block_bytes_result[0]);
            if (next_offset_result[1] != 0) return null;

            self.offset = next_offset_result[0];

            if (header.isRegularFile()) {
                return InitRDFile{
                    .name = name,
                    .data = self.initrd.data[data_start..data_end],
                };
            }
        }
        return null;
    }
};
