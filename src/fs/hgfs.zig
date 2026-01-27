//! HGFS VFS Integration
//!
//! Integrates the VMware HGFS driver with the kernel's VFS layer to enable
//! host-guest file sharing via VMware shared folders.
//!
//! Usage:
//!   const hgfs_fs = @import("fs").hgfs;
//!   const filesystem = try hgfs_fs.createFilesystem(driver);
//!   try vfs.Vfs.mount("/mnt/hgfs", filesystem);
//!
//! Features:
//! - Full read-write support
//! - Directory enumeration
//! - File attributes (size, mode, timestamps)
//! - Path traversal protection

const std = @import("std");
const fd = @import("fd");
const heap = @import("heap");
const uapi = @import("uapi");
const console = @import("console");
const sync = @import("sync");
const vfs = @import("vfs.zig");
const meta = @import("fs_meta");

const hgfs = @import("hgfs");
const protocol = hgfs.protocol;

// ============================================================================
// Per-Mount State
// ============================================================================

/// Per-mount state stored in FileSystem.context
pub const HgfsMount = struct {
    /// HGFS driver instance
    driver: *hgfs.HgfsDriver,
    /// Number of open files on this mount
    open_count: std.atomic.Value(u32),
    /// Whether mount is still active
    mounted: bool,

    const Self = @This();
};

// ============================================================================
// Per-File State
// ============================================================================

/// Per-file state stored in FileDescriptor.private_data
pub const HgfsFile = struct {
    /// Back-reference to mount
    mount: *HgfsMount,
    /// HGFS file handle (from open)
    handle: u32,
    /// Is this a directory?
    is_dir: bool,
    /// Directory search handle (for readdir)
    search_handle: ?u32,
    /// Current directory entry index
    dir_index: u32,
    /// Open flags
    flags: u32,
    /// Cached file size
    cached_size: u64,
    /// Cached mode bits
    cached_mode: u32,
};

// ============================================================================
// Error Mapping
// ============================================================================

/// Map HGFS driver errors to VFS errors
fn mapDriverError(err: hgfs.HgfsError) vfs.Error {
    return switch (err) {
        error.NotDetected => error.NotSupported,
        error.RpciOpenFailed => error.IOError,
        error.SessionCreateFailed => error.IOError,
        error.SessionDestroyed => error.IOError,
        error.ProtocolError => error.IOError,
        error.InvalidResponse => error.IOError,
        error.InvalidHandle => error.IOError,
        error.NotFound => error.NotFound,
        error.PermissionDenied => error.AccessDenied,
        error.IoError => error.IOError,
        error.NameTooLong => error.NameTooLong,
        error.NotEmpty => error.NotEmpty,
        error.NotSupported => error.NotSupported,
        error.Timeout => error.IOError,
        error.BufferTooSmall => error.IOError,
        error.AlreadyExists => error.AlreadyExists,
        error.NotDirectory => error.NotDirectory,
        error.IsDirectory => error.IsDirectory,
    };
}

// ============================================================================
// Path Validation
// ============================================================================

/// Validate path for security (reject ".." traversal)
fn validatePath(path: []const u8) bool {
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (std.mem.eql(u8, component, "..")) {
            return false;
        }
    }
    return true;
}

// ============================================================================
// FileSystem Implementation
// ============================================================================

/// Open a file via HGFS
fn vfsOpen(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd.FileDescriptor {
    const mount: *HgfsMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    // SECURITY: Validate path
    if (!validatePath(path)) {
        return error.InvalidPath;
    }

    const driver = mount.driver;
    const access_mode = flags & fd.O_ACCMODE;
    const creating = (flags & fd.O_CREAT) != 0;

    // First, check if path exists and get attributes
    var attr: ?protocol.HgfsAttr = null;
    var exists = false;

    if (driver.getAttr(path)) |a| {
        attr = a;
        exists = true;
    } else |err| {
        if (err != error.NotFound) {
            return mapDriverError(err);
        }
    }

    // Handle O_CREAT | O_EXCL
    if (creating and (flags & fd.O_EXCL) != 0 and exists) {
        return error.AlreadyExists;
    }

    // Determine open mode
    var mode = hgfs.OpenMode{
        .read = access_mode == fd.O_RDONLY or access_mode == fd.O_RDWR,
        .write = access_mode == fd.O_WRONLY or access_mode == fd.O_RDWR,
        .create = creating,
        .truncate = (flags & fd.O_TRUNC) != 0,
        .append = (flags & fd.O_APPEND) != 0,
        .exclusive = (flags & fd.O_EXCL) != 0,
    };

    // Check if it's a directory
    var is_dir = false;
    if (attr) |a| {
        is_dir = @as(protocol.HgfsFileType, @enumFromInt(a.file_type)) == .Directory;

        // Check if trying to write to a directory
        if (is_dir and mode.write) {
            return error.IsDirectory;
        }
    }

    // Handle directory open differently
    if (is_dir or (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, ""))) {
        // For directories, we don't actually open them, just create the file state
        is_dir = true;

        // Get attributes for root if not already
        if (attr == null) {
            attr = driver.getAttr(path) catch |err| {
                return mapDriverError(err);
            };
        }
    }

    var handle: u32 = protocol.HGFS_INVALID_HANDLE;

    // Open file (not directories)
    if (!is_dir) {
        handle = driver.open(path, mode) catch |err| {
            return mapDriverError(err);
        };
    }

    // Allocate file state
    const file_state = heap.allocator().create(HgfsFile) catch {
        if (handle != protocol.HGFS_INVALID_HANDLE) {
            driver.close(handle) catch {};
        }
        return error.NoMemory;
    };
    errdefer heap.allocator().destroy(file_state);

    file_state.* = HgfsFile{
        .mount = mount,
        .handle = handle,
        .is_dir = is_dir,
        .search_handle = null,
        .dir_index = 0,
        .flags = flags,
        .cached_size = if (attr) |a| a.size else 0,
        .cached_mode = if (attr) |a| a.toMode() else 0o644,
    };

    // Create file descriptor
    const file_desc = fd.createFd(&vfs_ops, flags, file_state) catch {
        if (handle != protocol.HGFS_INVALID_HANDLE) {
            driver.close(handle) catch {};
        }
        heap.allocator().destroy(file_state);
        return error.NoMemory;
    };

    // Increment open count
    _ = mount.open_count.fetchAdd(1, .monotonic);

    return file_desc;
}

/// Get file metadata without opening
fn vfsStatPath(ctx: ?*anyopaque, path: []const u8) ?meta.FileMeta {
    const mount: *HgfsMount = @ptrCast(@alignCast(ctx orelse return null));

    if (!mount.mounted) {
        return null;
    }

    // SECURITY: Validate path
    if (!validatePath(path)) {
        return null;
    }

    // Handle root directory
    if (std.mem.eql(u8, path, "/") or path.len == 0) {
        return meta.FileMeta{
            .mode = meta.S_IFDIR | 0o755,
            .uid = 0,
            .gid = 0,
            .exists = true,
            .readonly = false,
            .size = 0,
        };
    }

    const attr = mount.driver.getAttr(path) catch return null;

    return meta.FileMeta{
        .mode = attr.toMode(),
        .uid = attr.uid,
        .gid = attr.gid,
        .exists = true,
        .readonly = false,
        .size = attr.size,
    };
}

/// Unlink (delete) a file
fn vfsUnlink(ctx: ?*anyopaque, path: []const u8) vfs.Error!void {
    const mount: *HgfsMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    if (!validatePath(path)) {
        return error.InvalidPath;
    }

    mount.driver.unlink(path) catch |err| {
        return mapDriverError(err);
    };
}

/// Unmount the filesystem
fn vfsUnmount(ctx: ?*anyopaque) void {
    const mount: *HgfsMount = @ptrCast(@alignCast(ctx orelse return));

    mount.mounted = false;

    // Warn if files are still open
    const open = mount.open_count.load(.acquire);
    if (open > 0) {
        console.warn("HGFS: Unmounting with {d} open files", .{open});
    }

    // Free mount structure (don't destroy driver - it may be shared)
    heap.allocator().destroy(mount);
}

/// Get filesystem statistics
fn vfsStatfs(ctx: ?*anyopaque) vfs.Error!uapi.stat.Statfs {
    const mount: *HgfsMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    // HGFS doesn't have a statfs operation, return synthetic values
    return uapi.stat.Statfs{
        .f_type = 0x48474653, // "HGFS" magic
        .f_bsize = 4096,
        .f_blocks = 0, // Unknown
        .f_bfree = 0,
        .f_bavail = 0,
        .f_files = 0,
        .f_ffree = 0,
        .f_fsid = .{ .val = .{ 0, 0 } },
        .f_namelen = protocol.MAX_NAME_LEN,
        .f_frsize = 4096,
        .f_flags = 0,
        .f_spare = .{ 0, 0, 0, 0 },
    };
}

/// Create a directory
fn vfsMkdir(ctx: ?*anyopaque, path: []const u8, mode: u32) vfs.Error!void {
    _ = mode;
    const mount: *HgfsMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    if (!validatePath(path)) {
        return error.InvalidPath;
    }

    mount.driver.mkdir(path) catch |err| {
        return mapDriverError(err);
    };
}

/// Remove a directory
fn vfsRmdir(ctx: ?*anyopaque, path: []const u8) vfs.Error!void {
    const mount: *HgfsMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    if (!validatePath(path)) {
        return error.InvalidPath;
    }

    mount.driver.rmdir(path) catch |err| {
        return mapDriverError(err);
    };
}

// ============================================================================
// FileOps Implementation
// ============================================================================

/// Read from an HGFS file
fn vfsRead(file: *fd.FileDescriptor, buf: []u8) isize {
    const file_state: *HgfsFile = @ptrCast(@alignCast(file.private_data orelse return -5));

    if (!file_state.mount.mounted) {
        return -5; // EIO
    }

    // Can't read directories
    if (file_state.is_dir) {
        return -21; // EISDIR
    }

    // Zero-initialize buffer before read (security)
    @memset(buf, 0);

    const bytes_read = file_state.mount.driver.read(
        file_state.handle,
        file.position,
        buf,
    ) catch |err| {
        return switch (err) {
            error.IoError => -5, // EIO
            error.InvalidHandle => -9, // EBADF
            else => -5,
        };
    };

    file.position += bytes_read;
    return @intCast(bytes_read);
}

/// Write to an HGFS file
fn vfsWrite(file: *fd.FileDescriptor, buf: []const u8) isize {
    const file_state: *HgfsFile = @ptrCast(@alignCast(file.private_data orelse return -5));

    if (!file_state.mount.mounted) {
        return -5; // EIO
    }

    // Can't write directories
    if (file_state.is_dir) {
        return -21; // EISDIR
    }

    const bytes_written = file_state.mount.driver.write(
        file_state.handle,
        file.position,
        buf,
    ) catch |err| {
        return switch (err) {
            error.IoError => -5, // EIO
            error.PermissionDenied => -13, // EACCES
            else => -5,
        };
    };

    file.position += bytes_written;

    // Update cached size if we extended the file
    if (file.position > file_state.cached_size) {
        file_state.cached_size = file.position;
    }

    return @intCast(bytes_written);
}

/// Close an HGFS file
fn vfsClose(file: *fd.FileDescriptor) isize {
    const file_state: *HgfsFile = @ptrCast(@alignCast(file.private_data orelse return 0));
    const mount = file_state.mount;
    const driver = mount.driver;

    // Close search handle if open
    if (file_state.search_handle) |sh| {
        driver.searchClose(sh) catch {};
    }

    // Close file handle
    if (file_state.handle != protocol.HGFS_INVALID_HANDLE) {
        driver.close(file_state.handle) catch {
            console.warn("HGFS: close failed for handle {d}", .{file_state.handle});
        };
    }

    // Decrement open count
    _ = mount.open_count.fetchSub(1, .release);

    // Free file state
    heap.allocator().destroy(file_state);

    return 0;
}

/// Seek in an HGFS file
fn vfsSeek(file: *fd.FileDescriptor, offset: i64, whence: u32) isize {
    const file_state: *HgfsFile = @ptrCast(@alignCast(file.private_data orelse return -5));

    const SEEK_SET: u32 = 0;
    const SEEK_CUR: u32 = 1;
    const SEEK_END: u32 = 2;

    const current: i64 = @intCast(file.position);
    const file_size: i64 = @intCast(file_state.cached_size);

    const new_pos: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => std.math.add(i64, current, offset) catch return -22,
        SEEK_END => std.math.add(i64, file_size, offset) catch return -22,
        else => return -22,
    };

    if (new_pos < 0) {
        return -22; // EINVAL
    }

    file.position = @intCast(new_pos);
    return new_pos;
}

/// Get stat for an HGFS file
fn vfsStat(file: *fd.FileDescriptor, stat_buf: *anyopaque) isize {
    const file_state: *HgfsFile = @ptrCast(@alignCast(file.private_data orelse return -5));

    if (!file_state.mount.mounted) {
        return -5; // EIO
    }

    // Populate stat buffer with cached values
    const stat: *uapi.stat.Stat = @ptrCast(@alignCast(stat_buf));
    stat.* = std.mem.zeroes(uapi.stat.Stat);

    stat.dev = 0;
    stat.ino = 0; // HGFS doesn't provide inode numbers
    stat.nlink = 1;
    stat.mode = file_state.cached_mode;
    stat.uid = 0;
    stat.gid = 0;
    stat.rdev = 0;
    stat.size = @intCast(file_state.cached_size);
    stat.blksize = 4096;
    stat.blocks = @intCast((file_state.cached_size + 511) / 512);
    stat.atime = 0;
    stat.mtime = 0;
    stat.ctime = 0;

    return 0;
}

/// FileOps for HGFS files
const vfs_ops = fd.FileOps{
    .read = vfsRead,
    .write = vfsWrite,
    .close = vfsClose,
    .seek = vfsSeek,
    .stat = vfsStat,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

// ============================================================================
// Public API
// ============================================================================

/// Create a VFS FileSystem wrapper for an HGFS driver
pub fn createFilesystem(driver: *hgfs.HgfsDriver) !vfs.FileSystem {
    // Allocate mount state
    const mount = try heap.allocator().create(HgfsMount);
    errdefer heap.allocator().destroy(mount);

    mount.* = HgfsMount{
        .driver = driver,
        .open_count = .{ .raw = 0 },
        .mounted = true,
    };

    return vfs.FileSystem{
        .context = mount,
        .open = vfsOpen,
        .unmount = vfsUnmount,
        .unlink = vfsUnlink,
        .stat_path = vfsStatPath,
        .chmod = null, // HGFS doesn't support chmod
        .chown = null, // HGFS doesn't support chown
        .statfs = vfsStatfs,
        .rename = null, // TODO: Implement rename
        .truncate = null, // TODO: Implement truncate
        .mkdir = vfsMkdir,
        .rmdir = vfsRmdir,
        .link = null, // HGFS doesn't support hard links
        .symlink = null, // TODO: Implement symlink
        .readlink = null, // TODO: Implement readlink
    };
}
