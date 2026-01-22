//! VirtIO-9P VFS Integration
//!
//! Integrates the VirtIO-9P driver with the kernel's VFS layer to enable
//! host-guest file sharing via QEMU's `-virtfs` option.
//!
//! Usage:
//!   const fs = @import("fs").virtio9p;
//!   const filesystem = try fs.createFilesystem(device);
//!   try vfs.Vfs.mount("/mnt/hostshare", filesystem);
//!
//! Features:
//! - Walk from root for each operation (simple, stateless)
//! - Standard file operations: open, read, write, seek, close, stat
//! - Supports multiple concurrent mounts with different tags

const std = @import("std");
const fd = @import("fd");
const heap = @import("heap");
const uapi = @import("uapi");
const console = @import("console");
const sync = @import("sync");
const vfs = @import("vfs.zig");
const meta = @import("fs_meta");

const virtio_9p = @import("virtio_9p");
const protocol = virtio_9p.protocol;
const config = virtio_9p.config;

// ============================================================================
// Per-Mount State
// ============================================================================

/// Per-mount state stored in FileSystem.context
pub const Virtio9PMount = struct {
    /// Driver device instance
    device: *virtio_9p.Virtio9PDevice,
    /// Root fid number (from Tattach)
    root_fid: u32,
    /// Mount tag string
    mount_tag: [128]u8,
    mount_tag_len: usize,
    /// Number of open files on this mount
    open_count: std.atomic.Value(u32),
    /// Whether mount is still active
    mounted: bool,
    /// Next fid to allocate (simple monotonic counter)
    next_fid: std.atomic.Value(u32),

    const Self = @This();

    /// Allocate a new fid number
    pub fn allocFid(self: *Self) u32 {
        // Start from 1 (0 is root_fid)
        const fid_val = self.next_fid.fetchAdd(1, .monotonic);
        // Wrap around if we hit the limit (unlikely with 32-bit counter)
        if (fid_val >= 0xFFFFFFFE) {
            self.next_fid.store(1, .monotonic);
            return 1;
        }
        return fid_val;
    }
};

// ============================================================================
// Per-File State
// ============================================================================

/// Per-file state stored in FileDescriptor.private_data
pub const Virtio9PFile = struct {
    /// Back-reference to mount
    mount: *Virtio9PMount,
    /// Fid number for this open file
    fid_num: u32,
    /// QID from walk/open
    qid: protocol.P9Qid,
    /// Negotiated I/O unit size
    iounit: u32,
    /// Cached file size (from stat)
    cached_size: u64,
    /// Cached mode bits
    cached_mode: u32,
    /// Is this a directory?
    is_directory: bool,
    /// Open mode (read/write/rdwr)
    open_mode: u8,
};

// ============================================================================
// Path Utilities
// ============================================================================

/// Maximum path components for walk
const MAX_PATH_COMPONENTS = 16;

/// Split a path into walk elements
/// Path "/foo/bar/baz" -> ["foo", "bar", "baz"]
/// Returns number of elements or error
/// SECURITY: Rejects ".." path traversal attempts
fn splitPath(path: []const u8, out_names: *[MAX_PATH_COMPONENTS][]const u8) !usize {
    var count: usize = 0;

    // Skip leading slash
    var remaining = path;
    if (remaining.len > 0 and remaining[0] == '/') {
        remaining = remaining[1..];
    }

    // Handle root case
    if (remaining.len == 0) {
        return 0;
    }

    var iter = std.mem.splitScalar(u8, remaining, '/');
    while (iter.next()) |component| {
        // Skip empty components (consecutive slashes)
        if (component.len == 0) continue;

        // SECURITY: Reject ".." traversal
        if (std.mem.eql(u8, component, "..")) {
            return error.InvalidPath;
        }

        // Skip "." (current directory)
        if (std.mem.eql(u8, component, ".")) continue;

        if (count >= MAX_PATH_COMPONENTS) {
            return error.PathTooLong;
        }

        out_names[count] = component;
        count += 1;
    }

    return count;
}

// ============================================================================
// Error Mapping
// ============================================================================

/// Map VirtIO-9P driver errors to VFS errors
fn mapDriverError(err: virtio_9p.P9Error) vfs.Error {
    return switch (err) {
        error.NotVirtio9P => error.NotSupported,
        error.InvalidBar => error.IOError,
        error.MappingFailed => error.IOError,
        error.CapabilityNotFound => error.NotSupported,
        error.ResetFailed => error.IOError,
        error.FeatureNegotiationFailed => error.IOError,
        error.QueueAllocationFailed => error.NoMemory,
        error.AllocationFailed => error.NoMemory,
        error.VersionMismatch => error.NotSupported,
        error.AttachFailed => error.IOError,
        error.WalkFailed => error.NotFound,
        error.OpenFailed => error.AccessDenied,
        error.ReadFailed => error.IOError,
        error.WriteFailed => error.IOError,
        error.ClunkFailed => error.IOError,
        error.StatFailed => error.IOError,
        error.CreateFailed => error.IOError,
        error.RemoveFailed => error.IOError,
        error.InvalidFid => error.IOError,
        error.FidTableFull => error.NoMemory,
        error.QueueFull => error.Busy,
        error.Timeout => error.IOError,
        error.ServerError => error.IOError,
        error.ProtocolError => error.IOError,
        error.PathTooLong => error.NameTooLong,
        error.TooManyWalkElements => error.NameTooLong,
        error.BufferTooSmall => error.IOError,
    };
}

// ============================================================================
// Mode Conversion
// ============================================================================

/// Convert 9P QID type to POSIX file type bits
fn qidTypeToMode(qid_type: u8) u32 {
    if ((qid_type & config.QidType.DIR) != 0) {
        return meta.S_IFDIR;
    } else if ((qid_type & config.QidType.SYMLINK) != 0) {
        return meta.S_IFLNK;
    } else {
        return meta.S_IFREG;
    }
}

/// Convert 9P stat mode to POSIX mode
fn p9ModeToMode(p9_mode: u32) u32 {
    // High bits indicate file type
    var posix_mode: u32 = 0;

    if ((p9_mode & config.DirMode.DIR) != 0) {
        posix_mode = meta.S_IFDIR;
    } else if ((p9_mode & config.DirMode.SYMLINK) != 0) {
        posix_mode = meta.S_IFLNK;
    } else if ((p9_mode & config.DirMode.DEVICE) != 0) {
        posix_mode = meta.S_IFCHR; // Assume char device
    } else if ((p9_mode & config.DirMode.NAMEDPIPE) != 0) {
        posix_mode = meta.S_IFIFO;
    } else if ((p9_mode & config.DirMode.SOCKET) != 0) {
        posix_mode = meta.S_IFSOCK;
    } else {
        posix_mode = meta.S_IFREG;
    }

    // Lower 9 bits are permission bits
    posix_mode |= (p9_mode & 0o777);

    return posix_mode;
}

/// Convert Linux open flags to 9P open mode
fn flagsToP9Mode(flags: u32) u8 {
    const access_mode = flags & fd.O_ACCMODE;
    var mode: u8 = switch (access_mode) {
        fd.O_RDONLY => config.OpenMode.READ,
        fd.O_WRONLY => config.OpenMode.WRITE,
        fd.O_RDWR => config.OpenMode.RDWR,
        else => config.OpenMode.READ,
    };

    if ((flags & fd.O_TRUNC) != 0) {
        mode |= config.OpenMode.TRUNC;
    }

    return mode;
}

// ============================================================================
// FileSystem Implementation
// ============================================================================

/// Open a file via VirtIO-9P
fn v9pOpen(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd.FileDescriptor {
    const mount: *Virtio9PMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    // Parse path into walk elements
    var names: [MAX_PATH_COMPONENTS][]const u8 = undefined;
    const num_names = splitPath(path, &names) catch return error.InvalidPath;

    // Allocate a new fid for this file
    const new_fid = mount.allocFid();

    // Walk from root to the file
    const qid = mount.device.walk(
        mount.root_fid,
        new_fid,
        names[0..num_names],
    ) catch |err| {
        return mapDriverError(err);
    };

    // Check if trying to open directory with write mode
    const is_dir = qid.isDir();
    const access_mode = flags & fd.O_ACCMODE;
    if (is_dir and access_mode != fd.O_RDONLY) {
        // Clunk the fid we just walked to
        mount.device.clunk(new_fid) catch {};
        return error.IsDirectory;
    }

    // Open the fid for I/O
    const p9_mode = flagsToP9Mode(flags);
    const open_result = mount.device.open(new_fid, p9_mode) catch |err| {
        // Clunk on failure
        mount.device.clunk(new_fid) catch {};
        return mapDriverError(err);
    };

    // Get file size via stat
    const stat_info = mount.device.stat(new_fid) catch |err| {
        mount.device.clunk(new_fid) catch {};
        return mapDriverError(err);
    };

    // Allocate file state
    const file_state = heap.allocator().create(Virtio9PFile) catch {
        mount.device.clunk(new_fid) catch {};
        return error.NoMemory;
    };
    errdefer heap.allocator().destroy(file_state);

    file_state.* = Virtio9PFile{
        .mount = mount,
        .fid_num = new_fid,
        .qid = open_result.qid,
        .iounit = open_result.iounit,
        .cached_size = stat_info.fixed.length,
        .cached_mode = p9ModeToMode(stat_info.fixed.mode),
        .is_directory = is_dir,
        .open_mode = p9_mode,
    };

    // Create file descriptor
    const file_desc = fd.createFd(&v9p_ops, flags, file_state) catch {
        mount.device.clunk(new_fid) catch {};
        heap.allocator().destroy(file_state);
        return error.NoMemory;
    };

    // Increment open count
    _ = mount.open_count.fetchAdd(1, .monotonic);

    return file_desc;
}

/// Get file metadata without opening
fn v9pStatPath(ctx: ?*anyopaque, path: []const u8) ?meta.FileMeta {
    const mount: *Virtio9PMount = @ptrCast(@alignCast(ctx orelse return null));

    if (!mount.mounted) {
        return null;
    }

    // Handle root directory
    if (std.mem.eql(u8, path, "/") or path.len == 0) {
        // Stat the root fid
        const stat_info = mount.device.stat(mount.root_fid) catch return null;
        return meta.FileMeta{
            .mode = p9ModeToMode(stat_info.fixed.mode),
            .uid = stat_info.n_uid,
            .gid = stat_info.n_gid,
            .exists = true,
            .readonly = false,
            .size = stat_info.fixed.length,
        };
    }

    // Parse path
    var names: [MAX_PATH_COMPONENTS][]const u8 = undefined;
    const num_names = splitPath(path, &names) catch return null;

    // Allocate a temporary fid for the stat
    const temp_fid = mount.allocFid();

    // Walk to the file
    const qid = mount.device.walk(
        mount.root_fid,
        temp_fid,
        names[0..num_names],
    ) catch {
        return null;
    };

    // Stat the file
    const stat_info = mount.device.stat(temp_fid) catch {
        mount.device.clunk(temp_fid) catch {};
        return null;
    };

    // Clunk the temporary fid
    mount.device.clunk(temp_fid) catch {};

    _ = qid; // Used implicitly via walk success

    return meta.FileMeta{
        .mode = p9ModeToMode(stat_info.fixed.mode),
        .uid = stat_info.n_uid,
        .gid = stat_info.n_gid,
        .exists = true,
        .readonly = false,
        .size = stat_info.fixed.length,
    };
}

/// Unlink (delete) a file - not yet implemented
fn v9pUnlink(ctx: ?*anyopaque, path: []const u8) vfs.Error!void {
    _ = ctx;
    _ = path;
    // Requires Tremove message support
    return error.NotSupported;
}

/// Unmount the filesystem
fn v9pUnmount(ctx: ?*anyopaque) void {
    const mount: *Virtio9PMount = @ptrCast(@alignCast(ctx orelse return));

    mount.mounted = false;

    // Warn if files are still open
    const open = mount.open_count.load(.acquire);
    if (open > 0) {
        console.warn("VirtIO-9P: Unmounting with {d} open files", .{open});
    }

    // Free mount structure
    heap.allocator().destroy(mount);
}

// ============================================================================
// FileOps Implementation
// ============================================================================

/// Read from a VirtIO-9P file
fn v9pRead(file: *fd.FileDescriptor, buf: []u8) isize {
    const file_state: *Virtio9PFile = @ptrCast(@alignCast(file.private_data orelse return -5));

    if (!file_state.mount.mounted) {
        return -5; // EIO
    }

    // Zero-initialize buffer before DMA (security)
    @memset(buf, 0);

    // Calculate read size (respect iounit if set)
    const max_read = if (file_state.iounit > 0)
        @min(buf.len, file_state.iounit)
    else
        @min(buf.len, 8192); // Default chunk size

    const bytes_read = file_state.mount.device.read(
        file_state.fid_num,
        file.position,
        @intCast(max_read),
        buf,
    ) catch |err| {
        return switch (err) {
            error.ReadFailed => -5, // EIO
            error.InvalidFid => -9, // EBADF
            error.Timeout => -110, // ETIMEDOUT
            else => -5, // EIO
        };
    };

    // Update position
    file.position += bytes_read;

    return @intCast(bytes_read);
}

/// Write to a VirtIO-9P file
fn v9pWrite(file: *fd.FileDescriptor, buf: []const u8) isize {
    const file_state: *Virtio9PFile = @ptrCast(@alignCast(file.private_data orelse return -5));

    if (!file_state.mount.mounted) {
        return -5; // EIO
    }

    // Calculate write size (respect iounit if set)
    const max_write = if (file_state.iounit > 0)
        @min(buf.len, file_state.iounit)
    else
        @min(buf.len, 8192); // Default chunk size

    const bytes_written = file_state.mount.device.write(
        file_state.fid_num,
        file.position,
        buf[0..max_write],
    ) catch |err| {
        return switch (err) {
            error.WriteFailed => -5, // EIO
            error.InvalidFid => -9, // EBADF
            error.Timeout => -110, // ETIMEDOUT
            else => -5, // EIO
        };
    };

    // Update position
    file.position += bytes_written;

    // Update cached size if we extended the file
    if (file.position > file_state.cached_size) {
        file_state.cached_size = file.position;
    }

    return @intCast(bytes_written);
}

/// Close a VirtIO-9P file
fn v9pClose(file: *fd.FileDescriptor) isize {
    const file_state: *Virtio9PFile = @ptrCast(@alignCast(file.private_data orelse return 0));
    const mount = file_state.mount;

    // Clunk the fid
    mount.device.clunk(file_state.fid_num) catch {
        // Log but don't fail - file is being closed anyway
        console.warn("VirtIO-9P: clunk failed for fid {d}", .{file_state.fid_num});
    };

    // Decrement open count
    _ = mount.open_count.fetchSub(1, .release);

    // Free file state
    heap.allocator().destroy(file_state);

    return 0;
}

/// Seek in a VirtIO-9P file
fn v9pSeek(file: *fd.FileDescriptor, offset: i64, whence: u32) isize {
    const file_state: *Virtio9PFile = @ptrCast(@alignCast(file.private_data orelse return -5));

    const SEEK_SET: u32 = 0;
    const SEEK_CUR: u32 = 1;
    const SEEK_END: u32 = 2;

    const current: i64 = @intCast(file.position);
    const file_size: i64 = @intCast(file_state.cached_size);

    // SECURITY: Use checked arithmetic to prevent overflow
    const new_pos: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => std.math.add(i64, current, offset) catch return -22, // EINVAL
        SEEK_END => std.math.add(i64, file_size, offset) catch return -22, // EINVAL
        else => return -22, // EINVAL
    };

    if (new_pos < 0) {
        return -22; // EINVAL - negative position
    }

    file.position = @intCast(new_pos);
    return new_pos;
}

/// Get stat for a VirtIO-9P file
fn v9pStat(file: *fd.FileDescriptor, stat_buf: *anyopaque) isize {
    const file_state: *Virtio9PFile = @ptrCast(@alignCast(file.private_data orelse return -5));

    if (!file_state.mount.mounted) {
        return -5; // EIO
    }

    // Refresh stat from device
    const stat_info = file_state.mount.device.stat(file_state.fid_num) catch |err| {
        return switch (err) {
            error.StatFailed => -5, // EIO
            error.InvalidFid => -9, // EBADF
            error.Timeout => -110, // ETIMEDOUT
            else => -5, // EIO
        };
    };

    // Update cached values
    file_state.cached_size = stat_info.fixed.length;
    file_state.cached_mode = p9ModeToMode(stat_info.fixed.mode);

    // Populate stat buffer
    // SECURITY: Zero-initialize to prevent info leaks
    const stat: *uapi.stat.Stat = @ptrCast(@alignCast(stat_buf));
    stat.* = std.mem.zeroes(uapi.stat.Stat);

    stat.dev = 0; // Virtual device
    stat.ino = stat_info.fixed.qid.path; // Use QID path as inode
    stat.nlink = 1;
    stat.mode = file_state.cached_mode;
    stat.uid = stat_info.n_uid;
    stat.gid = stat_info.n_gid;
    stat.rdev = 0;
    stat.size = @intCast(stat_info.fixed.length);
    stat.blksize = 4096;
    stat.blocks = @divFloor(@as(i64, @intCast(stat_info.fixed.length)) + 511, 512);
    stat.atime = stat_info.fixed.atime;
    stat.mtime = stat_info.fixed.mtime;
    stat.ctime = stat_info.fixed.mtime; // 9P doesn't have ctime

    return 0;
}

/// FileOps for VirtIO-9P files
const v9p_ops = fd.FileOps{
    .read = v9pRead,
    .write = v9pWrite,
    .close = v9pClose,
    .seek = v9pSeek,
    .stat = v9pStat,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

// ============================================================================
// Public API
// ============================================================================

/// Create a VFS FileSystem wrapper for a VirtIO-9P device
pub fn createFilesystem(device: *virtio_9p.Virtio9PDevice) !vfs.FileSystem {
    // Allocate mount state
    const mount = try heap.allocator().create(Virtio9PMount);
    errdefer heap.allocator().destroy(mount);

    // Copy mount tag
    const tag = device.getMountTag();
    const tag_len = @min(tag.len, mount.mount_tag.len);
    @memcpy(mount.mount_tag[0..tag_len], tag[0..tag_len]);

    mount.* = Virtio9PMount{
        .device = device,
        .root_fid = device.root_fid,
        .mount_tag = mount.mount_tag,
        .mount_tag_len = tag_len,
        .open_count = .{ .raw = 0 },
        .mounted = true,
        .next_fid = .{ .raw = 1 }, // Start from 1 (0 is root)
    };

    return vfs.FileSystem{
        .context = mount,
        .open = v9pOpen,
        .unmount = v9pUnmount,
        .unlink = v9pUnlink,
        .stat_path = v9pStatPath,
        .chmod = null,
        .chown = null,
        .statfs = null,
        .rename = null,
        .truncate = null,
        .mkdir = null,
        .rmdir = null,
        .link = null,
        .symlink = null,
        .readlink = null,
    };
}
