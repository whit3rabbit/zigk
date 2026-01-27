//! VBoxSF VFS Integration
//!
//! Integrates the VirtualBox Shared Folders driver with the kernel's VFS layer
//! to enable host-guest file sharing via VirtualBox Guest Additions.
//!
//! Usage:
//!   const fs = @import("fs").vboxsf;
//!   const filesystem = try fs.createFilesystem(driver, root_handle, "name");
//!   try vfs.Vfs.mount("/mnt/share", filesystem);

const std = @import("std");
const fd = @import("fd");
const heap = @import("heap");
const uapi = @import("uapi");
const console = @import("console");
const sync = @import("sync");
const vfs = @import("vfs.zig");
const meta = @import("fs_meta");

const vboxsf = @import("vboxsf");
const protocol = vboxsf.protocol;
const config = vboxsf.config;

// ============================================================================
// Per-Mount State
// ============================================================================

/// Per-mount state stored in FileSystem.context
pub const VBoxSfMount = struct {
    /// Driver instance
    driver: *vboxsf.VBoxSfDriver,
    /// SHFL root handle (from mapFolder)
    root: u32,
    /// Mount point name
    mount_name: [256]u8,
    mount_name_len: usize,
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
pub const VBoxSfFile = struct {
    /// Back-reference to mount
    mount: *VBoxSfMount,
    /// SHFL file handle (from CREATE)
    handle: u64,
    /// Is this a directory?
    is_dir: bool,
    /// Open flags
    flags: u32,
    /// Cached file info
    cached_info: protocol.FsObjInfo,
    /// Path for directory operations
    path: [config.MAX_PATH_LEN]u8,
    path_len: usize,
    /// Directory enumeration state
    dir_resume: u32,
};

// ============================================================================
// Error Mapping
// ============================================================================

/// Map VBoxSF driver errors to VFS errors
fn mapDriverError(err: vboxsf.VBoxSfError) vfs.Error {
    return switch (err) {
        error.VmmDevNotAvailable => error.NotSupported,
        error.HgcmNotAvailable => error.NotSupported,
        error.ConnectFailed => error.IOError,
        error.DisconnectFailed => error.IOError,
        error.CallFailed => error.IOError,
        error.InvalidParameter => error.InvalidPath,
        error.NotFound => error.NotFound,
        error.AccessDenied => error.AccessDenied,
        error.AlreadyExists => error.AlreadyExists,
        error.IsDirectory => error.IsDirectory,
        error.NotDirectory => error.NotDirectory,
        error.NotEmpty => error.NotEmpty,
        error.ReadOnly => error.NotSupported,
        error.NoMemory => error.NoMemory,
        error.BufferOverflow => error.NoMemory,
        error.InvalidHandle => error.InvalidPath,
        error.Timeout => error.IOError,
        error.PathTooLong => error.NameTooLong,
    };
}

// ============================================================================
// VFS Operations Implementation
// ============================================================================

/// Open a file (VFS interface)
fn vfsOpen(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd.FileDescriptor {
    const mnt: *VBoxSfMount = @ptrCast(@alignCast(ctx orelse return error.NotFound));
    if (!mnt.mounted) return error.IOError;

    // Map VFS flags to SHFL create flags
    var create_flags: u32 = 0;

    // Access mode
    if ((flags & fd.O_ACCMODE) == fd.O_RDONLY) {
        create_flags |= config.CreateFlags.ACCESS_READ;
    } else if ((flags & fd.O_ACCMODE) == fd.O_WRONLY) {
        create_flags |= config.CreateFlags.ACCESS_WRITE;
    } else {
        create_flags |= config.CreateFlags.ACCESS_READWRITE;
    }

    // Create mode
    if ((flags & fd.O_CREAT) != 0) {
        if ((flags & fd.O_EXCL) != 0) {
            create_flags |= config.CreateFlags.CREATE_NEW;
        } else if ((flags & fd.O_TRUNC) != 0) {
            create_flags |= config.CreateFlags.CREATE_ALWAYS;
        } else {
            create_flags |= config.CreateFlags.OPEN_ALWAYS;
        }
    } else if ((flags & fd.O_TRUNC) != 0) {
        create_flags |= config.CreateFlags.TRUNCATE_EXISTING;
    } else {
        create_flags |= config.CreateFlags.OPEN_EXISTING;
    }

    // Sharing
    create_flags |= config.CreateFlags.SHARE_READ | config.CreateFlags.SHARE_WRITE;

    // Create/open the file
    const result = mnt.driver.createFile(mnt.root, path, create_flags) catch |err| {
        return mapDriverError(err);
    };

    // Allocate file state
    const file_state = heap.allocator().create(VBoxSfFile) catch {
        mnt.driver.closeFile(mnt.root, result.handle) catch {};
        return error.NoMemory;
    };
    errdefer heap.allocator().destroy(file_state);

    file_state.* = VBoxSfFile{
        .mount = mnt,
        .handle = result.handle,
        .is_dir = result.info.isDirectory(),
        .flags = flags,
        .cached_info = result.info,
        .path = undefined,
        .path_len = @min(path.len, config.MAX_PATH_LEN),
        .dir_resume = 0,
    };
    @memcpy(file_state.path[0..file_state.path_len], path[0..file_state.path_len]);

    // Create file descriptor
    const file_desc = fd.createFd(&vboxsf_file_ops, flags, file_state) catch {
        mnt.driver.closeFile(mnt.root, result.handle) catch {};
        heap.allocator().destroy(file_state);
        return error.NoMemory;
    };

    // Set position if O_APPEND
    if ((flags & fd.O_APPEND) != 0) {
        file_desc.position = @intCast(@as(u64, @bitCast(result.info.obj_size)));
    }

    _ = mnt.open_count.fetchAdd(1, .monotonic);

    return file_desc;
}

/// Create a directory
fn vfsMkdir(ctx: ?*anyopaque, path: []const u8, _: u32) vfs.Error!void {
    const mnt: *VBoxSfMount = @ptrCast(@alignCast(ctx orelse return error.NotFound));
    if (!mnt.mounted) return error.IOError;

    mnt.driver.mkdir(mnt.root, path) catch |err| {
        return mapDriverError(err);
    };
}

/// Remove a file
fn vfsUnlink(ctx: ?*anyopaque, path: []const u8) vfs.Error!void {
    const mnt: *VBoxSfMount = @ptrCast(@alignCast(ctx orelse return error.NotFound));
    if (!mnt.mounted) return error.IOError;

    mnt.driver.removeFile(mnt.root, path) catch |err| {
        return mapDriverError(err);
    };
}

/// Remove a directory
fn vfsRmdir(ctx: ?*anyopaque, path: []const u8) vfs.Error!void {
    const mnt: *VBoxSfMount = @ptrCast(@alignCast(ctx orelse return error.NotFound));
    if (!mnt.mounted) return error.IOError;

    mnt.driver.removeDir(mnt.root, path) catch |err| {
        return mapDriverError(err);
    };
}

/// Rename a file or directory
fn vfsRename(ctx: ?*anyopaque, old_path: []const u8, new_path: []const u8) vfs.Error!void {
    const mnt: *VBoxSfMount = @ptrCast(@alignCast(ctx orelse return error.NotFound));
    if (!mnt.mounted) return error.IOError;

    mnt.driver.rename(mnt.root, old_path, new_path) catch |err| {
        return mapDriverError(err);
    };
}

/// Get file/directory attributes (VFS callback signature)
fn vfsStatPath(ctx: ?*anyopaque, path: []const u8) ?meta.FileMeta {
    const mnt: *VBoxSfMount = @ptrCast(@alignCast(ctx orelse return null));
    if (!mnt.mounted) return null;

    // Open to get info, then close
    const result = mnt.driver.createFile(mnt.root, path, config.CreateFlags.OPEN_EXISTING | config.CreateFlags.ACCESS_NONE) catch {
        return null;
    };
    defer mnt.driver.closeFile(mnt.root, result.handle) catch {};

    return fsobjToMeta(&result.info);
}

/// Convert FsObjInfo to FileMeta
fn fsobjToMeta(info: *const protocol.FsObjInfo) meta.FileMeta {
    // Determine file type bits
    const file_type_bits: u32 = if (info.isDirectory())
        meta.S_IFDIR
    else if (info.isSymlink())
        meta.S_IFLNK
    else
        meta.S_IFREG;

    // Combine file type with permission bits
    const perm_bits = info.toMode() & 0o7777;
    const mode = file_type_bits | perm_bits;

    return meta.FileMeta{
        .mode = mode,
        .uid = 0,
        .gid = 0,
        .exists = true,
        .readonly = false,
        .size = @bitCast(info.obj_size),
    };
}

// ============================================================================
// File Operations (isize return type per fd.FileOps contract)
// ============================================================================

/// Read from file
fn fileRead(file: *fd.FileDescriptor, buffer: []u8) isize {
    const state: *VBoxSfFile = @ptrCast(@alignCast(file.private_data orelse return -9)); // EBADF
    const mnt = state.mount;

    if (!mnt.mounted) return -5; // EIO
    if (state.is_dir) return -21; // EISDIR

    const offset: u64 = @intCast(file.position);
    const bytes_read = mnt.driver.readFile(mnt.root, state.handle, offset, buffer) catch {
        return -5; // EIO
    };

    file.position += @intCast(bytes_read);
    return @intCast(bytes_read);
}

/// Write to file
fn fileWrite(file: *fd.FileDescriptor, data: []const u8) isize {
    const state: *VBoxSfFile = @ptrCast(@alignCast(file.private_data orelse return -9)); // EBADF
    const mnt = state.mount;

    if (!mnt.mounted) return -5; // EIO
    if (state.is_dir) return -21; // EISDIR

    const offset: u64 = @intCast(file.position);
    const bytes_written = mnt.driver.writeFile(mnt.root, state.handle, offset, data) catch {
        return -5; // EIO
    };

    file.position += @intCast(bytes_written);

    // Update cached size if we wrote past EOF
    const new_end = offset + bytes_written;
    if (new_end > @as(u64, @bitCast(state.cached_info.obj_size))) {
        state.cached_info.obj_size = @bitCast(new_end);
    }

    return @intCast(bytes_written);
}

/// Close file
fn fileClose(file: *fd.FileDescriptor) isize {
    const state: *VBoxSfFile = @ptrCast(@alignCast(file.private_data orelse return 0));
    const mnt = state.mount;

    // Close the handle
    mnt.driver.closeFile(mnt.root, state.handle) catch {};

    // Update open count
    _ = mnt.open_count.fetchSub(1, .monotonic);

    // Free state
    heap.allocator().destroy(state);
    file.private_data = null;

    return 0;
}

/// Seek in file
fn fileSeek(file: *fd.FileDescriptor, offset: i64, whence: u32) isize {
    const state: *VBoxSfFile = @ptrCast(@alignCast(file.private_data orelse return -9)); // EBADF

    const file_size: i64 = state.cached_info.obj_size;
    const current: i64 = @intCast(file.position);

    const SEEK_SET: u32 = 0;
    const SEEK_CUR: u32 = 1;
    const SEEK_END: u32 = 2;

    const new_pos: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => std.math.add(i64, current, offset) catch return -22, // EINVAL
        SEEK_END => std.math.add(i64, file_size, offset) catch return -22,
        else => return -22, // EINVAL
    };

    if (new_pos < 0) {
        return -22; // EINVAL
    }

    file.position = @intCast(new_pos);
    return new_pos;
}

/// Get file info (fstat)
fn fileStat(file: *fd.FileDescriptor, stat_buf: *anyopaque) isize {
    const state: *VBoxSfFile = @ptrCast(@alignCast(file.private_data orelse return -9)); // EBADF
    const mnt = state.mount;

    if (!mnt.mounted) return -5; // EIO

    // Refresh cached info
    const info = mnt.driver.getInfo(mnt.root, state.handle) catch {
        return -5; // EIO
    };

    state.cached_info = info;

    // Fill stat buffer
    const stat_ptr: *uapi.stat.Stat = @ptrCast(@alignCast(stat_buf));

    // Determine file type bits
    const file_type_bits: u32 = if (info.isDirectory())
        meta.S_IFDIR
    else if (info.isSymlink())
        meta.S_IFLNK
    else
        meta.S_IFREG;

    const perm_bits = info.toMode() & 0o7777;

    stat_ptr.* = std.mem.zeroes(uapi.stat.Stat);
    stat_ptr.mode = file_type_bits | perm_bits;
    stat_ptr.nlink = 1;
    stat_ptr.size = @bitCast(info.obj_size);
    stat_ptr.blksize = 4096;
    stat_ptr.blocks = @intCast(@divTrunc(@as(u64, @bitCast(info.alloc_size)), 512));

    return 0;
}

/// VBoxSF file operations vtable
const vboxsf_file_ops = fd.FileOps{
    .read = fileRead,
    .write = fileWrite,
    .close = fileClose,
    .seek = fileSeek,
    .stat = fileStat,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

/// Unmount filesystem
fn vfsUnmount(ctx: ?*anyopaque) void {
    const mnt: *VBoxSfMount = @ptrCast(@alignCast(ctx orelse return));

    // Check for open files - if busy, log warning but continue
    if (mnt.open_count.load(.monotonic) > 0) {
        console.warn("VBoxSF: Unmounting with {} open files", .{mnt.open_count.load(.monotonic)});
    }

    // Unmap the folder
    mnt.driver.unmapFolder(mnt.root) catch |err| {
        console.warn("VBoxSF: Unmap failed: {}", .{err});
    };

    mnt.mounted = false;

    // Free mount state
    heap.allocator().destroy(mnt);
}

// ============================================================================
// Public API
// ============================================================================

/// Create a VFS filesystem from a VBoxSF driver and mounted share
/// The root handle should be obtained from vboxsf.mapFolder()
pub fn createFilesystem(driver: *vboxsf.VBoxSfDriver, root_handle: u32, name: []const u8) !vfs.FileSystem {
    // Allocate mount state
    const mnt_state = try heap.allocator().create(VBoxSfMount);
    errdefer heap.allocator().destroy(mnt_state);

    mnt_state.* = VBoxSfMount{
        .driver = driver,
        .root = root_handle,
        .mount_name = undefined,
        .mount_name_len = @min(name.len, 255),
        .open_count = std.atomic.Value(u32).init(0),
        .mounted = true,
    };
    @memcpy(mnt_state.mount_name[0..mnt_state.mount_name_len], name[0..mnt_state.mount_name_len]);
    mnt_state.mount_name[mnt_state.mount_name_len] = 0;

    // Create filesystem - return by value like virtiofs does
    return vfs.FileSystem{
        .context = mnt_state,
        .open = vfsOpen,
        .unmount = vfsUnmount,
        .unlink = vfsUnlink,
        .stat_path = vfsStatPath,
        .chmod = null,
        .chown = null,
        .statfs = null,
        .rename = vfsRename,
        .truncate = null,
        .mkdir = vfsMkdir,
        .rmdir = vfsRmdir,
        .link = null,
        .symlink = null,
        .readlink = null,
    };
}

/// Mount a VirtualBox shared folder
/// Convenience function that maps the folder and creates the filesystem
pub fn mount(driver: *vboxsf.VBoxSfDriver, share_name: []const u8, mount_point: []const u8) !void {
    // Map the folder
    const root = driver.mapFolder(share_name) catch |err| {
        console.warn("VBoxSF: Failed to map '{s}': {}", .{ share_name, err });
        return error.NotFound;
    };
    errdefer driver.unmapFolder(root) catch {};

    // Create filesystem
    const filesystem = try createFilesystem(driver, root, share_name);

    // Mount it
    vfs.Vfs.mount(mount_point, filesystem) catch |err| {
        console.warn("VBoxSF: Failed to mount at '{s}': {}", .{ mount_point, err });
        return error.IOError;
    };

    console.info("VBoxSF: Mounted '{s}' at {s}", .{ share_name, mount_point });
}
