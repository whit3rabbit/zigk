//! Virtual File System (VFS)
//!
//! Provides a unified interface for filesystem operations.
//! Manages mount points and dispatches operations to specific filesystems (InitRD, DevFS, SFS).
//!
//! Features:
//! - Mount point registry (`MAX_MOUNTS` entries).
//! - Path resolution to find the correct filesystem.
//! - `FileSystem` interface for pluggable FS implementations.
//! - Thread-safe operations via spinlock.
//! - Open file tracking to prevent use-after-free on unmount.

const std = @import("std");
const fd = @import("fd");
const heap = @import("heap");
const uapi = @import("uapi");
const initrd = @import("initrd.zig");
const sync = @import("sync");

// Maximum number of mount points
const MAX_MOUNTS = 8;
const MAX_PATH_LEN = 1024;

/// Error set for VFS operations
pub const Error = error{
    NotFound,
    AccessDenied,
    InvalidPath,
    NameTooLong,
    AlreadyMounted,
    MountPointFull,
    NotSupported,
    IsDirectory,
    NotDirectory,
    Busy,
    IOError,
    NoMemory,
};

/// FileSystem Interface
/// Each concrete filesystem (InitRD, DevFS, SFS) must implement this.
pub const FileSystem = struct {
    /// Context pointer for the filesystem instance
    context: ?*anyopaque,

    /// Open a file or directory
    open: *const fn (ctx: ?*anyopaque, path: []const u8, flags: u32) Error!*fd.FileDescriptor,

    /// Unmount the filesystem (optional cleanup)
    unmount: ?*const fn (ctx: ?*anyopaque) void,

    /// Unlink (delete) a file (optional - null for read-only filesystems)
    unlink: ?*const fn (ctx: ?*anyopaque, path: []const u8) Error!void,
};

/// Mount Point Structure
const MountPoint = struct {
    path: []const u8,
    fs: FileSystem,
    /// Number of open file handles on this mount point
    /// Used to prevent unmount while files are open (use-after-free protection)
    open_files: u32 = 0,
};

/// Global VFS State
pub const Vfs = struct {
    var mounts: [MAX_MOUNTS]?MountPoint = [_]?MountPoint{null} ** MAX_MOUNTS;
    var mount_count: usize = 0;
    /// Spinlock protecting mount table operations
    var lock: sync.Spinlock = .{};

    /// Initialize VFS
    pub fn init() void {
        // Clear mounts
        mount_count = 0;
        for (0..MAX_MOUNTS) |i| {
            mounts[i] = null;
        }
        // Register close hook so fd.zig can notify us when files are closed
        fd.vfs_close_hook = @This().decrementOpenFilesByIndex;
    }

    /// Mount a filesystem at a given path
    pub fn mount(path: []const u8, filesystem: FileSystem) Error!void {
        @import("console").info("VFS: Mount '{s}'", .{path});

        // Allocate copy of path outside the lock
        const path_copy = heap.allocator().dupe(u8, path) catch return error.NoMemory;
        errdefer heap.allocator().free(path_copy);

        const held = lock.acquire();
        defer held.release();

        if (mount_count >= MAX_MOUNTS) return error.MountPointFull;

        // Check if already mounted
        for (mounts) |m| {
            if (m) |mount_point| {
                if (std.mem.eql(u8, mount_point.path, path)) {
                    return error.AlreadyMounted;
                }
            }
        }

        // Find free slot
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i] == null) {
                mounts[i] = MountPoint{
                    .path = path_copy,
                    .fs = filesystem,
                };
                mount_count += 1;
                @import("console").info("VFS: Mounted '{s}' at slot {d}", .{ path, i });
                return;
            }
        }
    }

    /// Unmount a filesystem
    pub fn unmount(path: []const u8) Error!void {
        const held = lock.acquire();
        defer held.release();

        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |m| {
                if (std.mem.eql(u8, m.path, path)) {
                    // Security: Check for open file handles before unmount
                    // Prevents use-after-free when files are still open
                    if (m.open_files > 0) {
                        @import("console").warn("VFS: Cannot unmount '{s}': {d} open files", .{ path, m.open_files });
                        return error.Busy;
                    }
                    if (m.fs.unmount) |unmount_fn| {
                        unmount_fn(m.fs.context);
                    }
                    heap.allocator().free(m.path);
                    mounts[i] = null;
                    mount_count -= 1;
                    return;
                }
            }
        }
        return error.NotFound;
    }

    /// Open a file by path
    /// Resolves the mount point and delegates to the filesystem.
    pub fn open(path: []const u8, flags: u32) Error!*fd.FileDescriptor {
        @import("console").info("VFS: Open '{s}'", .{path});
        if (path.len == 0) return error.InvalidPath;
        if (path[0] != '/') return error.InvalidPath; // Absolute paths only for now

        const held = lock.acquire();
        defer held.release();

        // Find the longest matching mount point
        var best_idx: ?usize = null;
        var best_len: usize = 0;

        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mount_point| {
                if (std.mem.startsWith(u8, path, mount_point.path)) {
                    const mp_len = mount_point.path.len;

                    // Match rules:
                    // 1. Exact match: path == "/dev" and mount == "/dev"
                    // 2. Prefix match: path == "/dev/console" and mount == "/dev"
                    //    But check separator: "/devfoo" should not match "/dev"

                    var match = false;
                    if (path.len == mp_len) {
                        match = true;
                    } else if (path.len > mp_len) {
                        if (mp_len == 1 and mount_point.path[0] == '/') {
                            // Root matches everything starting with /
                            match = true;
                        } else if (path[mp_len] == '/') {
                            // Separator after mount point
                            match = true;
                        }
                    }

                    if (match and mp_len > best_len) {
                        best_idx = i;
                        best_len = mp_len;
                    }
                }
            }
        }

        if (best_idx) |idx| {
            const mp = &mounts[idx].?;
            // Strip mount point prefix
            var rel_path = path[best_len..];

            // If path was exactly the mount point, rel_path is empty.
            // Filesystems typically expect "/" or empty string for root.
            if (rel_path.len == 0) {
                rel_path = "/";
            }

            // For root mount (/), path "/foo" -> rel_path "/foo".
            // For dev mount (/dev), path "/dev/null" -> rel_path "/null".

            const file_desc = try mp.fs.open(mp.fs.context, rel_path, flags);

            // Track open file for unmount protection
            mp.open_files += 1;

            // Store mount index in FD for close tracking
            file_desc.vfs_mount_idx = @intCast(idx);

            return file_desc;
        }

        return error.NotFound;
    }

    /// Decrement open file count for a mount point by index
    /// Called by fd.zig when a file descriptor is closed
    fn decrementOpenFilesByIndex(idx: u8) void {
        const held = lock.acquire();
        defer held.release();

        if (idx < MAX_MOUNTS) {
            if (mounts[idx]) |*mp| {
                if (mp.open_files > 0) {
                    mp.open_files -= 1;
                }
            }
        }
    }

    /// Decrement open file count for a mount point by path (legacy)
    /// Deprecated: use vfs_mount_idx in FileDescriptor instead
    pub fn decrementOpenFiles(path: []const u8) void {
        const held = lock.acquire();
        defer held.release();

        // Find matching mount point
        var best_idx: ?usize = null;
        var best_len: usize = 0;

        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mount_point| {
                if (std.mem.startsWith(u8, path, mount_point.path)) {
                    const mp_len = mount_point.path.len;
                    var match = false;
                    if (path.len == mp_len) {
                        match = true;
                    } else if (path.len > mp_len) {
                        if (mp_len == 1 and mount_point.path[0] == '/') {
                            match = true;
                        } else if (path[mp_len] == '/') {
                            match = true;
                        }
                    }
                    if (match and mp_len > best_len) {
                        best_idx = i;
                        best_len = mp_len;
                    }
                }
            }
        }

        if (best_idx) |idx| {
            if (mounts[idx]) |*mp| {
                if (mp.open_files > 0) {
                    mp.open_files -= 1;
                }
            }
        }
    }

    /// Unlink (delete) a file by path
    /// Resolves the mount point and delegates to the filesystem.
    pub fn unlink(path: []const u8) Error!void {
        if (path.len == 0) return error.InvalidPath;
        if (path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        // Find the longest matching mount point (same logic as open)
        var best_match: ?*const MountPoint = null;
        var best_len: usize = 0;

        for (&mounts) |*m| {
            if (m.*) |*mount_point| {
                if (std.mem.startsWith(u8, path, mount_point.path)) {
                    const mp_len = mount_point.path.len;
                    var match = false;
                    if (path.len == mp_len) {
                        match = true;
                    } else if (path.len > mp_len) {
                        if (mp_len == 1 and mount_point.path[0] == '/') {
                            match = true;
                        } else if (path[mp_len] == '/') {
                            match = true;
                        }
                    }
                    if (match and mp_len > best_len) {
                        best_match = mount_point;
                        best_len = mp_len;
                    }
                }
            }
        }

        if (best_match) |mp| {
            // Check if filesystem supports unlink
            const unlink_fn = mp.fs.unlink orelse return error.NotSupported;

            // Strip mount point prefix
            var rel_path = path[best_len..];
            if (rel_path.len == 0) {
                rel_path = "/";
            }

            return unlink_fn(mp.fs.context, rel_path);
        }

        return error.NotFound;
    }
};

// =============================================================================
// Adapter for InitRD
// =============================================================================

fn initrdOpen(ctx: ?*anyopaque, path: []const u8, flags: u32) Error!*fd.FileDescriptor {
    _ = ctx;
    // InitRD implementation expects path relative to root?
    // InitRD.openFile normalizes path by removing leading /.

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/.")) {
        const access_mode = flags & fd.O_ACCMODE;
        if (access_mode != fd.O_RDONLY) {
            return error.IsDirectory;
        }

        const tag_ptr: ?*anyopaque = @ptrCast(@constCast(&fd.initrd_dir_tag));
        return fd.createFd(&fd.dir_ops, fd.O_RDONLY, tag_ptr) catch return error.NoMemory;
    }

    // We can just call InitRD.instance.openFile
    const res = initrd.InitRD.instance.openFile(path, flags) catch |err| {
        return switch (err) {
            error.FileNotFound => error.NotFound,
            error.OutOfMemory => error.NoMemory,
        };
    };
    return res;
}

fn initrdUnlink(ctx: ?*anyopaque, path: []const u8) Error!void {
    _ = ctx;
    _ = path;
    // InitRD is read-only, cannot unlink files
    return error.AccessDenied;
}

pub const initrd_fs = FileSystem{
    .context = null,
    .open = initrdOpen,
    .unmount = null,
    .unlink = initrdUnlink,
};
