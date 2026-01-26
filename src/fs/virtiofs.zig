//! VirtIO-FS VFS Integration
//!
//! Integrates the VirtIO-FS driver with the kernel's VFS layer to enable
//! host-guest file sharing via QEMU's virtiofsd daemon.
//!
//! Usage:
//!   const fs = @import("fs").virtiofs;
//!   const filesystem = try fs.createFilesystem(device);
//!   try vfs.Vfs.mount("/mnt/share", filesystem);
//!
//! Features:
//! - Full read-write support
//! - TTL-based inode and dentry caching
//! - Better performance than VirtIO-9P through caching
//! - Standard POSIX file operations

const std = @import("std");
const fd = @import("fd");
const heap = @import("heap");
const uapi = @import("uapi");
const console = @import("console");
const sync = @import("sync");
const vfs = @import("vfs.zig");
const meta = @import("fs_meta");

const virtio_fs = @import("virtio_fs");
const protocol = virtio_fs.protocol;
const config = virtio_fs.config;

// ============================================================================
// Per-Mount State
// ============================================================================

/// Per-mount state stored in FileSystem.context
pub const VirtioFsMount = struct {
    /// Driver device instance
    device: *virtio_fs.VirtioFsDevice,
    /// Mount tag string
    mount_tag: [config.MAX_TAG_LEN + 1]u8,
    mount_tag_len: usize,
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
pub const VirtioFsFile = struct {
    /// Back-reference to mount
    mount: *VirtioFsMount,
    /// FUSE node ID
    nodeid: u64,
    /// FUSE file handle (from OPEN response)
    fh: u64,
    /// Is this a directory?
    is_dir: bool,
    /// Open flags
    flags: u32,
    /// Cached file size
    cached_size: u64,
    /// Cached mode bits
    cached_mode: u32,
};

// ============================================================================
// Path Utilities
// ============================================================================

/// Maximum path components for path resolution
const MAX_PATH_COMPONENTS = 32;

/// Split a path into components and resolve each via LOOKUP
/// Returns the final nodeid or error
fn resolvePath(mount: *VirtioFsMount, path: []const u8) vfs.Error!u64 {
    // Handle root
    if (path.len == 0 or (path.len == 1 and path[0] == '/')) {
        return config.FUSE_ROOT_ID;
    }

    // Skip leading slash
    var remaining = path;
    if (remaining.len > 0 and remaining[0] == '/') {
        remaining = remaining[1..];
    }

    // Skip trailing slash
    if (remaining.len > 0 and remaining[remaining.len - 1] == '/') {
        remaining = remaining[0 .. remaining.len - 1];
    }

    if (remaining.len == 0) {
        return config.FUSE_ROOT_ID;
    }

    var current_nodeid: u64 = config.FUSE_ROOT_ID;
    var iter = std.mem.splitScalar(u8, remaining, '/');

    while (iter.next()) |component| {
        if (component.len == 0) continue;

        // SECURITY: Reject ".." traversal
        if (std.mem.eql(u8, component, "..")) {
            return error.InvalidPath;
        }

        // Skip "."
        if (std.mem.eql(u8, component, ".")) continue;

        // Lookup this component
        const entry = mount.device.lookup(current_nodeid, component) catch |err| {
            return mapDriverError(err);
        };

        current_nodeid = entry.nodeid;
    }

    return current_nodeid;
}

/// Resolve path to parent directory and extract filename
fn resolveParentAndName(mount: *VirtioFsMount, path: []const u8) vfs.Error!struct { parent: u64, name: []const u8 } {
    // Skip leading slash
    var working_path = path;
    if (working_path.len > 0 and working_path[0] == '/') {
        working_path = working_path[1..];
    }

    // Skip trailing slash
    if (working_path.len > 0 and working_path[working_path.len - 1] == '/') {
        working_path = working_path[0 .. working_path.len - 1];
    }

    if (working_path.len == 0) {
        return error.InvalidPath;
    }

    // Find last path separator
    var last_sep: ?usize = null;
    for (working_path, 0..) |c, i| {
        if (c == '/') last_sep = i;
    }

    if (last_sep) |sep_idx| {
        // Has parent directory
        const parent_path = working_path[0..sep_idx];
        const name = working_path[sep_idx + 1 ..];

        if (name.len == 0) return error.InvalidPath;

        const parent_nodeid = try resolvePath(mount, parent_path);
        return .{ .parent = parent_nodeid, .name = name };
    } else {
        // In root directory
        return .{ .parent = config.FUSE_ROOT_ID, .name = working_path };
    }
}

// ============================================================================
// Error Mapping
// ============================================================================

/// Map VirtIO-FS driver errors to VFS errors
fn mapDriverError(err: virtio_fs.FsError) vfs.Error {
    return switch (err) {
        error.NotVirtioFs => error.NotSupported,
        error.InvalidBar => error.IOError,
        error.MappingFailed => error.IOError,
        error.CapabilityNotFound => error.NotSupported,
        error.ResetFailed => error.IOError,
        error.FeatureNegotiationFailed => error.IOError,
        error.QueueAllocationFailed => error.NoMemory,
        error.AllocationFailed => error.NoMemory,
        error.InitFailed => error.IOError,
        error.LookupFailed => error.NotFound,
        error.GetAttrFailed => error.IOError,
        error.OpenFailed => error.AccessDenied,
        error.ReadFailed => error.IOError,
        error.WriteFailed => error.IOError,
        error.ReleaseFailed => error.IOError,
        error.CreateFailed => error.IOError,
        error.MkdirFailed => error.IOError,
        error.UnlinkFailed => error.IOError,
        error.RmdirFailed => error.IOError,
        error.RenameFailed => error.IOError,
        error.StatfsFailed => error.IOError,
        error.ReadDirFailed => error.IOError,
        error.InvalidNodeId => error.IOError,
        error.QueueFull => error.Busy,
        error.Timeout => error.IOError,
        error.ServerError => error.IOError,
        error.ProtocolError => error.IOError,
        error.PathTooLong => error.NameTooLong,
        error.NameTooLong => error.NameTooLong,
        error.NotDirectory => error.NotDirectory,
        error.IsDirectory => error.IsDirectory,
        error.NotFound => error.NotFound,
        error.PermissionDenied => error.AccessDenied,
        error.NoSpace => error.IOError,
        error.NotEmpty => error.NotEmpty,
        error.Exists => error.AlreadyExists,
    };
}

// ============================================================================
// Mode Conversion
// ============================================================================

/// Convert FUSE mode to POSIX mode
fn fuseModeToMode(fuse_mode: u32) u32 {
    return fuse_mode; // FUSE uses POSIX mode format
}

/// Convert Linux open flags to FUSE open flags
fn flagsToFuseFlags(flags: u32) u32 {
    // FUSE uses standard Linux open flags
    return flags & (fd.O_ACCMODE | fd.O_CREAT | fd.O_TRUNC | fd.O_APPEND | fd.O_EXCL);
}

// ============================================================================
// FileSystem Implementation
// ============================================================================

/// Open a file via VirtIO-FS
fn vfsOpen(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd.FileDescriptor {
    const mount: *VirtioFsMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    const fuse_flags = flagsToFuseFlags(flags);
    const creating = (flags & fd.O_CREAT) != 0;

    var nodeid: u64 = undefined;
    var fh: u64 = undefined;
    var attr: protocol.FuseAttr = undefined;
    var is_dir = false;

    if (creating) {
        // Try to create the file
        const parent_info = try resolveParentAndName(mount, path);

        if (mount.device.create(parent_info.parent, parent_info.name, fuse_flags, 0o644)) |result| {
            // Created successfully
            nodeid = result.entry.nodeid;
            attr = result.entry.attr;
            fh = result.open.fh;
            is_dir = false;
        } else |err| {
            // If O_CREAT without O_EXCL and file exists, try to open it
            if (err == error.Exists and (flags & fd.O_EXCL) == 0) {
                // Fall through to open existing
                nodeid = try resolvePath(mount, path);
                const attr_out = mount.device.getAttr(nodeid, null) catch |e| {
                    return mapDriverError(e);
                };
                attr = attr_out.attr;
                is_dir = config.FileType.isDir(attr.mode);

                const open_result = mount.device.open(nodeid, fuse_flags, is_dir) catch |e| {
                    return mapDriverError(e);
                };
                fh = open_result.fh;
            } else {
                return mapDriverError(err);
            }
        }
    } else {
        // Open existing file
        nodeid = try resolvePath(mount, path);

        const attr_out = mount.device.getAttr(nodeid, null) catch |err| {
            return mapDriverError(err);
        };
        attr = attr_out.attr;
        is_dir = config.FileType.isDir(attr.mode);

        // Check if trying to write to a directory
        const access_mode = flags & fd.O_ACCMODE;
        if (is_dir and access_mode != fd.O_RDONLY) {
            return error.IsDirectory;
        }

        const open_result = mount.device.open(nodeid, fuse_flags, is_dir) catch |err| {
            return mapDriverError(err);
        };
        fh = open_result.fh;
    }

    // Allocate file state
    const file_state = heap.allocator().create(VirtioFsFile) catch {
        mount.device.release(nodeid, fh, fuse_flags, is_dir) catch {};
        return error.NoMemory;
    };
    errdefer heap.allocator().destroy(file_state);

    file_state.* = VirtioFsFile{
        .mount = mount,
        .nodeid = nodeid,
        .fh = fh,
        .is_dir = is_dir,
        .flags = fuse_flags,
        .cached_size = attr.size,
        .cached_mode = fuseModeToMode(attr.mode),
    };

    // Create file descriptor
    const file_desc = fd.createFd(&vfs_ops, flags, file_state) catch {
        mount.device.release(nodeid, fh, fuse_flags, is_dir) catch {};
        heap.allocator().destroy(file_state);
        return error.NoMemory;
    };

    // Increment open count
    _ = mount.open_count.fetchAdd(1, .monotonic);

    return file_desc;
}

/// Get file metadata without opening
fn vfsStatPath(ctx: ?*anyopaque, path: []const u8) ?meta.FileMeta {
    const mount: *VirtioFsMount = @ptrCast(@alignCast(ctx orelse return null));

    if (!mount.mounted) {
        return null;
    }

    // Resolve path to nodeid
    const nodeid = resolvePath(mount, path) catch return null;

    // Get attributes
    const attr_out = mount.device.getAttr(nodeid, null) catch return null;

    return meta.FileMeta{
        .mode = fuseModeToMode(attr_out.attr.mode),
        .uid = attr_out.attr.uid,
        .gid = attr_out.attr.gid,
        .exists = true,
        .readonly = false,
        .size = attr_out.attr.size,
    };
}

/// Unlink (delete) a file
fn vfsUnlink(ctx: ?*anyopaque, path: []const u8) vfs.Error!void {
    const mount: *VirtioFsMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    const parent_info = try resolveParentAndName(mount, path);

    mount.device.unlink(parent_info.parent, parent_info.name) catch |err| {
        return mapDriverError(err);
    };
}

/// Unmount the filesystem
fn vfsUnmount(ctx: ?*anyopaque) void {
    const mount: *VirtioFsMount = @ptrCast(@alignCast(ctx orelse return));

    mount.mounted = false;

    // Warn if files are still open
    const open = mount.open_count.load(.acquire);
    if (open > 0) {
        console.warn("VirtIO-FS: Unmounting with {d} open files", .{open});
    }

    // Free mount structure
    heap.allocator().destroy(mount);
}

/// Get filesystem statistics
fn vfsStatfs(ctx: ?*anyopaque) vfs.Error!uapi.stat.Statfs {
    const mount: *VirtioFsMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    const statfs_out = mount.device.statfs(config.FUSE_ROOT_ID) catch |err| {
        return mapDriverError(err);
    };

    return uapi.stat.Statfs{
        .f_type = 0x65735546, // "FUSe" magic
        .f_bsize = statfs_out.st.bsize,
        .f_blocks = @bitCast(statfs_out.st.blocks),
        .f_bfree = @bitCast(statfs_out.st.bfree),
        .f_bavail = @bitCast(statfs_out.st.bavail),
        .f_files = @bitCast(statfs_out.st.files),
        .f_ffree = @bitCast(statfs_out.st.ffree),
        .f_fsid = .{ .val = .{ 0, 0 } },
        .f_namelen = statfs_out.st.namelen,
        .f_frsize = statfs_out.st.frsize,
        .f_flags = 0,
        .f_spare = .{ 0, 0, 0, 0 },
    };
}

/// Rename a file or directory
fn vfsRename(ctx: ?*anyopaque, old_path: []const u8, new_path: []const u8) vfs.Error!void {
    const mount: *VirtioFsMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    const old_info = try resolveParentAndName(mount, old_path);
    const new_info = try resolveParentAndName(mount, new_path);

    mount.device.rename(old_info.parent, old_info.name, new_info.parent, new_info.name) catch |err| {
        return mapDriverError(err);
    };
}

/// Create a directory
fn vfsMkdir(ctx: ?*anyopaque, path: []const u8, mode: u32) vfs.Error!void {
    const mount: *VirtioFsMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    const parent_info = try resolveParentAndName(mount, path);

    _ = mount.device.mkdir(parent_info.parent, parent_info.name, mode | config.FileType.S_IFDIR) catch |err| {
        return mapDriverError(err);
    };
}

/// Remove a directory
fn vfsRmdir(ctx: ?*anyopaque, path: []const u8) vfs.Error!void {
    const mount: *VirtioFsMount = @ptrCast(@alignCast(ctx orelse return error.IOError));

    if (!mount.mounted) {
        return error.IOError;
    }

    const parent_info = try resolveParentAndName(mount, path);

    mount.device.rmdir(parent_info.parent, parent_info.name) catch |err| {
        return mapDriverError(err);
    };
}

// ============================================================================
// FileOps Implementation
// ============================================================================

/// Read from a VirtIO-FS file
fn vfsRead(file: *fd.FileDescriptor, buf: []u8) isize {
    const file_state: *VirtioFsFile = @ptrCast(@alignCast(file.private_data orelse return -5));

    if (!file_state.mount.mounted) {
        return -5; // EIO
    }

    // Zero-initialize buffer before read (security)
    @memset(buf, 0);

    const bytes_read = file_state.mount.device.read(
        file_state.nodeid,
        file_state.fh,
        file.position,
        @intCast(@min(buf.len, file_state.mount.device.getMaxWrite())),
        buf,
    ) catch |err| {
        return switch (err) {
            error.ReadFailed => -5, // EIO
            error.Timeout => -110, // ETIMEDOUT
            else => -5,
        };
    };

    file.position += bytes_read;
    return @intCast(bytes_read);
}

/// Write to a VirtIO-FS file
fn vfsWrite(file: *fd.FileDescriptor, buf: []const u8) isize {
    const file_state: *VirtioFsFile = @ptrCast(@alignCast(file.private_data orelse return -5));

    if (!file_state.mount.mounted) {
        return -5; // EIO
    }

    const write_size = @min(buf.len, file_state.mount.device.getMaxWrite());

    const bytes_written = file_state.mount.device.write(
        file_state.nodeid,
        file_state.fh,
        file.position,
        buf[0..write_size],
    ) catch |err| {
        return switch (err) {
            error.WriteFailed => -5, // EIO
            error.NoSpace => -28, // ENOSPC
            error.Timeout => -110, // ETIMEDOUT
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

/// Close a VirtIO-FS file
fn vfsClose(file: *fd.FileDescriptor) isize {
    const file_state: *VirtioFsFile = @ptrCast(@alignCast(file.private_data orelse return 0));
    const mount = file_state.mount;

    // Release the file handle
    mount.device.release(
        file_state.nodeid,
        file_state.fh,
        file_state.flags,
        file_state.is_dir,
    ) catch {
        console.warn("VirtIO-FS: release failed for nodeid {d}", .{file_state.nodeid});
    };

    // Decrement open count
    _ = mount.open_count.fetchSub(1, .release);

    // Free file state
    heap.allocator().destroy(file_state);

    return 0;
}

/// Seek in a VirtIO-FS file
fn vfsSeek(file: *fd.FileDescriptor, offset: i64, whence: u32) isize {
    const file_state: *VirtioFsFile = @ptrCast(@alignCast(file.private_data orelse return -5));

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

/// Get stat for a VirtIO-FS file
fn vfsStat(file: *fd.FileDescriptor, stat_buf: *anyopaque) isize {
    const file_state: *VirtioFsFile = @ptrCast(@alignCast(file.private_data orelse return -5));

    if (!file_state.mount.mounted) {
        return -5; // EIO
    }

    // Refresh attributes from device
    const attr_out = file_state.mount.device.getAttr(file_state.nodeid, file_state.fh) catch |err| {
        return switch (err) {
            error.GetAttrFailed => -5,
            error.Timeout => -110,
            else => -5,
        };
    };

    // Update cached values
    file_state.cached_size = attr_out.attr.size;
    file_state.cached_mode = fuseModeToMode(attr_out.attr.mode);

    // Populate stat buffer
    const stat: *uapi.stat.Stat = @ptrCast(@alignCast(stat_buf));
    stat.* = std.mem.zeroes(uapi.stat.Stat);

    stat.dev = 0;
    stat.ino = attr_out.attr.ino;
    stat.nlink = attr_out.attr.nlink;
    stat.mode = attr_out.attr.mode;
    stat.uid = attr_out.attr.uid;
    stat.gid = attr_out.attr.gid;
    stat.rdev = attr_out.attr.rdev;
    stat.size = @intCast(attr_out.attr.size);
    stat.blksize = attr_out.attr.blksize;
    stat.blocks = @intCast(attr_out.attr.blocks);
    stat.atime = @intCast(attr_out.attr.atime);
    stat.mtime = @intCast(attr_out.attr.mtime);
    stat.ctime = @intCast(attr_out.attr.ctime);

    return 0;
}

/// FileOps for VirtIO-FS files
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

/// Create a VFS FileSystem wrapper for a VirtIO-FS device
pub fn createFilesystem(device: *virtio_fs.VirtioFsDevice) !vfs.FileSystem {
    // Allocate mount state
    const mount = try heap.allocator().create(VirtioFsMount);
    errdefer heap.allocator().destroy(mount);

    // Copy mount tag
    const tag = device.getMountTag();
    const tag_len = @min(tag.len, mount.mount_tag.len - 1);
    @memcpy(mount.mount_tag[0..tag_len], tag[0..tag_len]);
    mount.mount_tag[tag_len] = 0;

    mount.* = VirtioFsMount{
        .device = device,
        .mount_tag = mount.mount_tag,
        .mount_tag_len = tag_len,
        .open_count = .{ .raw = 0 },
        .mounted = true,
    };

    return vfs.FileSystem{
        .context = mount,
        .open = vfsOpen,
        .unmount = vfsUnmount,
        .unlink = vfsUnlink,
        .stat_path = vfsStatPath,
        .chmod = null,
        .chown = null,
        .statfs = vfsStatfs,
        .rename = vfsRename,
        .truncate = null,
        .mkdir = vfsMkdir,
        .rmdir = vfsRmdir,
        .link = null,
        .symlink = null,
        .readlink = null,
    };
}
