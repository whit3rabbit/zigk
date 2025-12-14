// Virtual File System (VFS)
//
// Provides a unified interface for filesystem operations.
// Manages mount points and dispatches operations to specific filesystems.

const std = @import("std");
const fd = @import("fd");
const heap = @import("heap");
const uapi = @import("uapi");
const initrd = @import("initrd.zig");

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
/// Each concrete filesystem (InitRD, DevFS, FAT32) must implement this.
pub const FileSystem = struct {
    /// Context pointer for the filesystem instance
    context: ?*anyopaque,

    /// Open a file or directory
    open: *const fn (ctx: ?*anyopaque, path: []const u8, flags: u32) Error!*fd.FileDescriptor,

    /// Unmount the filesystem (optional cleanup)
    unmount: ?*const fn (ctx: ?*anyopaque) void,
};

/// Mount Point Structure
const MountPoint = struct {
    path: []const u8,
    fs: FileSystem,
};

/// Global VFS State
pub const Vfs = struct {
    var mounts: [MAX_MOUNTS]?MountPoint = [_]?MountPoint{null} ** MAX_MOUNTS;
    var mount_count: usize = 0;

    /// Initialize VFS
    pub fn init() void {
        // Clear mounts
        mount_count = 0;
        for (0..MAX_MOUNTS) |i| {
            mounts[i] = null;
        }
    }

    /// Mount a filesystem at a given path
    pub fn mount(path: []const u8, fs: FileSystem) Error!void {
        @import("console").info("VFS: Mount '{s}'", .{path});
        if (mount_count >= MAX_MOUNTS) return error.MountPointFull;
        // ... (rest of logic) ...
        // Check if already mounted
        for (mounts) |m| {
            if (m) |mount_point| {
                if (std.mem.eql(u8, mount_point.path, path)) {
                    return error.AlreadyMounted;
                }
            }
        }

        // Allocate copy of path
        const path_copy = heap.allocator().dupe(u8, path) catch return error.NoMemory;

        // Find free slot
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i] == null) {
                mounts[i] = MountPoint{
                    .path = path_copy,
                    .fs = fs,
                };
                mount_count += 1;
                @import("console").info("VFS: Mounted '{s}' at slot {d}", .{path, i});
                return;
            }
        }
    }

    /// Unmount a filesystem
    pub fn unmount(path: []const u8) Error!void {
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |m| {
                if (std.mem.eql(u8, m.path, path)) {
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

        // Find the longest matching mount point
        var best_match: ?*const MountPoint = null;
        var best_len: usize = 0;

        for (&mounts) |*m| {
            if (m.*) |*mount_point| {
                // @import("console").debug("VFS: Check mount '{s}' vs '{s}'", .{mount_point.path, path});
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
                        best_match = mount_point;
                        best_len = mp_len;
                    }
                }
            }
        }

        if (best_match) |mp| {
            // Strip mount point prefix
            var rel_path = path[best_len..];

            // If path was exactly the mount point, rel_path is empty.
            // Filesystems typically expect "/" or empty string for root.
            if (rel_path.len == 0) {
                rel_path = "/";
            } else if (rel_path[0] != '/') {
                // Should not happen due to check above, but for safety
                // If mount is "/" and path is "/etc", rel_path is "etc".
                // We might want to ensure it starts with / if FS expects it.
                // InitRD expects path without leading /.
                // Let's standardise: pass relative path.
                // But for Root mount (/), rel_path starts with /.
            }

            // For root mount (/), path "/foo" -> rel_path "/foo".
            // For dev mount (/dev), path "/dev/null" -> rel_path "/null".

            return mp.fs.open(mp.fs.context, rel_path, flags);
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

    // We can just call InitRD.instance.openFile
    const res = initrd.InitRD.instance.openFile(path, flags) catch |err| {
        return switch (err) {
            error.FileNotFound => error.NotFound,
            error.OutOfMemory => error.NoMemory,
        };
    };
    return res;
}

pub const initrd_fs = FileSystem{
    .context = null,
    .open = initrdOpen,
    .unmount = null,
};
