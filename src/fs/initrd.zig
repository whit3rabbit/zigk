const std = @import("std");
const fd = @import("fd");
const heap = @import("heap");
const uapi = @import("uapi");

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

    pub fn getSize(self: *const @This()) usize {
        var size: usize = 0;
        for (self.size) |c| {
            if (c == ' ' or c == 0) break;
            if (c < '0' or c > '7') break;
            size = size * 8 + (c - '0');
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

        var offset: usize = 0;
        // Need at least 512 bytes for a header
        while (offset + 512 <= self.data.len) {
            const header: *const TarHeader = @ptrCast(@alignCast(self.data.ptr + offset));

            // Check for end of archive (two zero blocks, checking first char suffices for now)
            if (header.name[0] == 0) break;

            // Validate USTAR magic
            if (!header.isValid()) break;

            const name = header.getName();
            const size = header.getSize();

            // Check if this is the file we are looking for
            // For MVP, we ignore directories and assume flat structure or exact match
            if (header.isRegularFile() and std.mem.eql(u8, name, search_name)) {
                return InitRDFile{
                    .name = name,
                    .data = self.data[offset + 512 .. offset + 512 + size],
                };
            }

            // Advance to next header
            // Data is padded to 512-byte boundary
            const data_blocks = (size + 511) / 512;
            // Next header is at current offset + header + data blocks
            const next_offset = offset + 512 + (data_blocks * 512);
            
            if (next_offset > self.data.len) break;
            offset = next_offset;
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
    .stat = null, // TODO
    .ioctl = null,
};

fn initrdRead(file_desc: *fd.FileDescriptor, buf: []u8) isize {
    const file: *InitRDFile = @ptrCast(@alignCast(file_desc.private_data));

    // Bounds check
    if (file_desc.position >= file.data.len) return 0;

    const remaining = file.data.len - file_desc.position;
    const to_read = @min(buf.len, remaining);

    @memcpy(buf[0..to_read], file.data[file_desc.position..][0..to_read]);
    file_desc.position += to_read;

    return @intCast(to_read);
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
    const file_size: i64 = @intCast(file.data.len);
    const current: i64 = @intCast(file_desc.position);

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

    file_desc.position = @intCast(new_pos);
    return new_pos;
}

pub const FileIterator = struct {
    initrd: *const InitRD,
    offset: usize,

    pub fn next(self: *@This()) ?InitRDFile {
        while (self.offset + 512 <= self.initrd.data.len) {
            const header: *const TarHeader = @ptrCast(@alignCast(
                self.initrd.data.ptr + self.offset,
            ));

            if (header.name[0] == 0) return null;
            if (!header.isValid()) return null;

            const name = header.getName();
            const size = header.getSize();
            const data_offset = self.offset + 512;

            // Advance to next header
            const data_blocks = (size + 511) / 512;
            self.offset += 512 + (data_blocks * 512);

            if (header.isRegularFile()) {
                return InitRDFile{
                    .name = name,
                    .data = self.initrd.data[data_offset .. data_offset + size],
                };
            }
        }
        return null;
    }
};
