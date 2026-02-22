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
const meta = @import("fs_meta");

pub const FileMeta = meta.FileMeta;

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
    AlreadyExists,
    NotEmpty,
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

    /// Get file metadata without opening (optional - for permission checking)
    /// Returns null if file does not exist
    stat_path: ?*const fn (ctx: ?*anyopaque, path: []const u8) ?FileMeta,

    /// Change file mode (permissions) - optional, null for read-only filesystems
    chmod: ?*const fn (ctx: ?*anyopaque, path: []const u8, mode: u32) Error!void = null,

    /// Change file owner/group - optional, null for read-only filesystems
    chown: ?*const fn (ctx: ?*anyopaque, path: []const u8, uid: ?u32, gid: ?u32) Error!void = null,

    /// Get filesystem statistics - optional
    statfs: ?*const fn (ctx: ?*anyopaque) Error!uapi.stat.Statfs = null,

    /// Rename a file or directory - optional
    rename: ?*const fn (ctx: ?*anyopaque, old_path: []const u8, new_path: []const u8) Error!void = null,

    /// Rename with flags (RENAME_NOREPLACE, RENAME_EXCHANGE) - optional
    rename2: ?*const fn (ctx: ?*anyopaque, old_path: []const u8, new_path: []const u8, flags: u32) Error!void = null,

    /// Truncate (resize) a file - optional
    truncate: ?*const fn (ctx: ?*anyopaque, path: []const u8, length: u64) Error!void = null,

    /// Create a directory - optional
    mkdir: ?*const fn (ctx: ?*anyopaque, path: []const u8, mode: u32) Error!void = null,

    /// Remove a directory - optional
    rmdir: ?*const fn (ctx: ?*anyopaque, path: []const u8) Error!void = null,

    /// Get directory entries - optional, for filesystems that support directory listing
    getdents: ?*const fn (file_desc: *fd.FileDescriptor, dirp: usize, count: usize) isize = null,

    /// Create a hard link - optional
    link: ?*const fn (ctx: ?*anyopaque, old_path: []const u8, new_path: []const u8) Error!void = null,

    /// Create a symbolic link - optional
    symlink: ?*const fn (ctx: ?*anyopaque, target: []const u8, linkpath: []const u8) Error!void = null,

    /// Read the target of a symbolic link - optional
    readlink: ?*const fn (ctx: ?*anyopaque, path: []const u8, buf: []u8) Error!usize = null,

    /// Set file timestamps - optional, null for read-only filesystems
    /// atime/mtime of -1 means "leave unchanged" (UTIME_OMIT equivalent at VFS level)
    set_timestamps: ?*const fn (ctx: ?*anyopaque, path: []const u8, atime_sec: i64, atime_nsec: i64, mtime_sec: i64, mtime_nsec: i64) Error!void = null,
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

    /// Hook for inotify event generation
    pub var inotify_event_hook: ?*const fn ([]const u8, u32, ?[]const u8) void = null;

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

            // Assign file identifier for flock
            // Composite key: (mount_idx << 32) | file_id
            // For MVP, use hash of private_data pointer as file_id
            const mount_idx_u64: u64 = @intCast(idx);
            const file_id: u64 = if (file_desc.private_data) |ptr|
                @intFromPtr(ptr) & 0xFFFFFFFF // Use lower 32 bits of pointer
            else
                0;
            file_desc.file_identifier = (mount_idx_u64 << 32) | file_id;

            // Store path for inotify event generation on write/ftruncate/close
            const path_copy_len = @min(path.len, file_desc.vfs_path.len);
            @memcpy(file_desc.vfs_path[0..path_copy_len], path[0..path_copy_len]);
            file_desc.vfs_path_len = @intCast(path_copy_len);

            // Trigger inotify hooks if registered
            if (inotify_event_hook) |hook| {
                if ((flags & 0o100) != 0) { // O_CREAT
                    hook(path, 0x00000100, null); // IN_CREATE
                }
                hook(path, 0x00000020, null); // IN_OPEN
            }

            return file_desc;
        }

        return error.NotFound;
    }

    /// Get file metadata without opening the file
    /// Used for permission checking before open operations
    /// Returns null if file does not exist or filesystem doesn't support stat_path
    pub fn statPath(path: []const u8) ?FileMeta {
        if (path.len == 0) return null;
        if (path[0] != '/') return null; // Absolute paths only

        const held = lock.acquire();
        defer held.release();

        // Find the longest matching mount point (same logic as open)
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
            const mp = &mounts[idx].?;

            // Check if filesystem supports stat_path
            const stat_fn = mp.fs.stat_path orelse return null;

            // Strip mount point prefix
            var rel_path = path[best_len..];
            if (rel_path.len == 0) {
                rel_path = "/";
            }

            return stat_fn(mp.fs.context, rel_path);
        }

        return null;
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

            try unlink_fn(mp.fs.context, rel_path);

            // Trigger inotify hook
            if (inotify_event_hook) |hook| {
                hook(path, 0x00000200, null); // IN_DELETE
            }

            return;
        }

        return error.NotFound;
    }

    /// Change file mode (permissions)
    /// Resolves the mount point and delegates to the filesystem.
    pub fn chmod(path: []const u8, mode: u32) Error!void {
        if (path.len == 0) return error.InvalidPath;
        if (path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        // Find the longest matching mount point
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
            const chmod_fn = mp.fs.chmod orelse return error.NotSupported;

            var rel_path = path[best_len..];
            if (rel_path.len == 0) {
                rel_path = "/";
            }

            try chmod_fn(mp.fs.context, rel_path, mode);

            // Trigger inotify hook
            if (inotify_event_hook) |hook| {
                hook(path, 0x00000004, null); // IN_ATTRIB
            }

            return;
        }

        return error.NotFound;
    }

    /// Change file owner and group
    /// Resolves the mount point and delegates to the filesystem.
    pub fn chown(path: []const u8, uid: ?u32, gid: ?u32) Error!void {
        if (path.len == 0) return error.InvalidPath;
        if (path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        // Find the longest matching mount point
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
            const chown_fn = mp.fs.chown orelse return error.NotSupported;

            var rel_path = path[best_len..];
            if (rel_path.len == 0) {
                rel_path = "/";
            }

            try chown_fn(mp.fs.context, rel_path, uid, gid);

            // Trigger inotify hook
            if (inotify_event_hook) |hook| {
                hook(path, 0x00000004, null); // IN_ATTRIB
            }

            return;
        }

        return error.NotFound;
    }

    /// Change file owner and group (without following symlinks)
    /// Same as chown() in this kernel since VFS does not resolve symlinks,
    /// but maintained as separate entry point for API correctness (lchown).
    pub fn chownNoFollow(path: []const u8, uid: ?u32, gid: ?u32) Error!void {
        return chown(path, uid, gid);
    }

    /// Set file timestamps with nanosecond precision
    /// atime_sec/mtime_sec of -1 means "leave unchanged"
    pub fn setTimestamps(path: []const u8, atime_sec: i64, atime_nsec: i64, mtime_sec: i64, mtime_nsec: i64) Error!void {
        if (path.len == 0) return error.InvalidPath;
        if (path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        // Find the longest matching mount point
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
            const set_ts_fn = mp.fs.set_timestamps orelse return error.NotSupported;

            var rel_path = path[best_len..];
            if (rel_path.len == 0) {
                rel_path = "/";
            }

            return set_ts_fn(mp.fs.context, rel_path, atime_sec, atime_nsec, mtime_sec, mtime_nsec);
        }

        return error.NotFound;
    }

    /// Rename a file or directory
    pub fn rename(old_path: []const u8, new_path: []const u8) Error!void {
        if (old_path.len == 0 or new_path.len == 0) return error.InvalidPath;
        if (old_path[0] != '/' or new_path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        // 1. Find mount point for old_path
        var old_idx: ?usize = null;
        var old_best_len: usize = 0;
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mp| {
                if (std.mem.startsWith(u8, old_path, mp.path)) {
                    if (mp.path.len > old_best_len) {
                        old_idx = i;
                        old_best_len = mp.path.len;
                    }
                }
            }
        }

        // 2. Find mount point for new_path
        var new_idx: ?usize = null;
        var new_best_len: usize = 0;
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mp| {
                if (std.mem.startsWith(u8, new_path, mp.path)) {
                    if (mp.path.len > new_best_len) {
                        new_idx = i;
                        new_best_len = mp.path.len;
                    }
                }
            }
        }

        if (old_idx == null or new_idx == null) return error.NotFound;
        if (old_idx != new_idx) return error.NotSupported; // Cannot rename across filesystems

        const mp = &mounts[old_idx.?].?;
        const rename_fn = mp.fs.rename orelse return error.NotSupported;

        var rel_old = old_path[old_best_len..];
        if (rel_old.len == 0) rel_old = "/";
        var rel_new = new_path[new_best_len..];
        if (rel_new.len == 0) rel_new = "/";

        try rename_fn(mp.fs.context, rel_old, rel_new);

        // Trigger inotify hooks
        if (inotify_event_hook) |hook| {
            hook(old_path, 0x00000040, null); // IN_MOVED_FROM
            hook(new_path, 0x00000080, null); // IN_MOVED_TO
        }

        return;
    }

    /// Rename a file or directory with flags (RENAME_NOREPLACE, RENAME_EXCHANGE)
    pub fn rename2(old_path: []const u8, new_path: []const u8, flags: u32) Error!void {
        if (old_path.len == 0 or new_path.len == 0) return error.InvalidPath;
        if (old_path[0] != '/' or new_path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        // 1. Find mount point for old_path
        var old_idx: ?usize = null;
        var old_best_len: usize = 0;
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mp| {
                if (std.mem.startsWith(u8, old_path, mp.path)) {
                    if (mp.path.len > old_best_len) {
                        old_idx = i;
                        old_best_len = mp.path.len;
                    }
                }
            }
        }

        // 2. Find mount point for new_path
        var new_idx: ?usize = null;
        var new_best_len: usize = 0;
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mp| {
                if (std.mem.startsWith(u8, new_path, mp.path)) {
                    if (mp.path.len > new_best_len) {
                        new_idx = i;
                        new_best_len = mp.path.len;
                    }
                }
            }
        }

        if (old_idx == null or new_idx == null) return error.NotFound;
        if (old_idx != new_idx) return error.NotSupported; // Cannot rename across filesystems

        const mp = &mounts[old_idx.?].?;

        var rel_old = old_path[old_best_len..];
        if (rel_old.len == 0) rel_old = "/";
        var rel_new = new_path[new_best_len..];
        if (rel_new.len == 0) rel_new = "/";

        // If filesystem supports rename2, use it
        if (mp.fs.rename2) |rename2_fn| {
            try rename2_fn(mp.fs.context, rel_old, rel_new, flags);

            // Trigger inotify hooks
            if (inotify_event_hook) |hook| {
                hook(old_path, 0x00000040, null); // IN_MOVED_FROM
                hook(new_path, 0x00000080, null); // IN_MOVED_TO
            }

            return;
        }

        // Fallback: if flags == 0 and filesystem has rename, use it
        if (flags == 0) {
            if (mp.fs.rename) |rename_fn| {
                try rename_fn(mp.fs.context, rel_old, rel_new);

                // Trigger inotify hooks
                if (inotify_event_hook) |hook| {
                    hook(old_path, 0x00000040, null); // IN_MOVED_FROM
                    hook(new_path, 0x00000080, null); // IN_MOVED_TO
                }

                return;
            }
        }

        // No support for the requested operation
        return error.NotSupported;
    }

    /// Truncate a file to a given length
    pub fn truncate(path: []const u8, length: u64) Error!void {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        var best_idx: ?usize = null;
        var best_len: usize = 0;
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mp| {
                if (std.mem.startsWith(u8, path, mp.path)) {
                    if (mp.path.len > best_len) {
                        best_idx = i;
                        best_len = mp.path.len;
                    }
                }
            }
        }

        if (best_idx) |idx| {
            const mp = &mounts[idx].?;
            const truncate_fn = mp.fs.truncate orelse return error.NotSupported;

            var rel_path = path[best_len..];
            if (rel_path.len == 0) rel_path = "/";

            try truncate_fn(mp.fs.context, rel_path, length);

            // Trigger inotify hook
            if (inotify_event_hook) |hook| {
                hook(path, 0x00000002, null); // IN_MODIFY
            }

            return;
        }

        return error.NotFound;
    }

    /// Create a directory
    pub fn mkdir(path: []const u8, mode: u32) Error!void {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        var best_idx: ?usize = null;
        var best_len: usize = 0;
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mp| {
                if (std.mem.startsWith(u8, path, mp.path)) {
                    if (mp.path.len > best_len) {
                        best_idx = i;
                        best_len = mp.path.len;
                    }
                }
            }
        }

        if (best_idx) |idx| {
            const mp = &mounts[idx].?;
            const mkdir_fn = mp.fs.mkdir orelse return error.NotSupported;

            var rel_path = path[best_len..];
            if (rel_path.len == 0) rel_path = "/";

            try mkdir_fn(mp.fs.context, rel_path, mode);

            // Trigger inotify hook
            if (inotify_event_hook) |hook| {
                hook(path, 0x00000100, null); // IN_CREATE
            }

            return;
        }

        return error.NotFound;
    }

    /// Remove a directory
    pub fn rmdir(path: []const u8) Error!void {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        var best_idx: ?usize = null;
        var best_len: usize = 0;
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mp| {
                if (std.mem.startsWith(u8, path, mp.path)) {
                    if (mp.path.len > best_len) {
                        best_idx = i;
                        best_len = mp.path.len;
                    }
                }
            }
        }

        if (best_idx) |idx| {
            const mp = &mounts[idx].?;
            const rmdir_fn = mp.fs.rmdir orelse return error.NotSupported;

            var rel_path = path[best_len..];
            if (rel_path.len == 0) rel_path = "/";

            try rmdir_fn(mp.fs.context, rel_path);

            // Trigger inotify hook
            if (inotify_event_hook) |hook| {
                hook(path, 0x00000200, null); // IN_DELETE
            }

            return;
        }

        return error.NotFound;
    }

    /// Create a hard link
    pub fn link(old_path: []const u8, new_path: []const u8) Error!void {
        if (old_path.len == 0 or new_path.len == 0) return error.InvalidPath;
        if (old_path[0] != '/' or new_path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        var old_idx: ?usize = null;
        var old_best_len: usize = 0;
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mp| {
                if (std.mem.startsWith(u8, old_path, mp.path)) {
                    if (mp.path.len > old_best_len) {
                        old_idx = i;
                        old_best_len = mp.path.len;
                    }
                }
            }
        }

        var new_idx: ?usize = null;
        var new_best_len: usize = 0;
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mp| {
                if (std.mem.startsWith(u8, new_path, mp.path)) {
                    if (mp.path.len > new_best_len) {
                        new_idx = i;
                        new_best_len = mp.path.len;
                    }
                }
            }
        }

        if (old_idx == null or new_idx == null) return error.NotFound;
        if (old_idx != new_idx) return error.NotSupported; // Cannot link across filesystems

        const mp = &mounts[old_idx.?].?;
        const link_fn = mp.fs.link orelse return error.NotSupported;

        var rel_old = old_path[old_best_len..];
        if (rel_old.len == 0) rel_old = "/";
        var rel_new = new_path[new_best_len..];
        if (rel_new.len == 0) rel_new = "/";

        try link_fn(mp.fs.context, rel_old, rel_new);

        // Trigger inotify hooks
        if (inotify_event_hook) |hook| {
            hook(new_path, 0x00000100, null); // IN_CREATE (new link)
            hook(old_path, 0x00000004, null); // IN_ATTRIB (nlink changed)
        }

        return;
    }

    /// Create a symbolic link
    pub fn symlink(target: []const u8, linkpath: []const u8) Error!void {
        if (linkpath.len == 0 or linkpath[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        var best_idx: ?usize = null;
        var best_len: usize = 0;
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mp| {
                if (std.mem.startsWith(u8, linkpath, mp.path)) {
                    if (mp.path.len > best_len) {
                        best_idx = i;
                        best_len = mp.path.len;
                    }
                }
            }
        }

        if (best_idx) |idx| {
            const mp = &mounts[idx].?;
            const symlink_fn = mp.fs.symlink orelse return error.NotSupported;

            var rel_path = linkpath[best_len..];
            if (rel_path.len == 0) rel_path = "/";

            try symlink_fn(mp.fs.context, target, rel_path);

            // Trigger inotify hook
            if (inotify_event_hook) |hook| {
                hook(linkpath, 0x00000100, null); // IN_CREATE (new symlink)
            }

            return;
        }

        return error.NotFound;
    }

    /// Read the target of a symbolic link
    pub fn readlink(path: []const u8, buf: []u8) Error!usize {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        var best_idx: ?usize = null;
        var best_len: usize = 0;
        for (0..MAX_MOUNTS) |i| {
            if (mounts[i]) |mp| {
                if (std.mem.startsWith(u8, path, mp.path)) {
                    if (mp.path.len > best_len) {
                        best_idx = i;
                        best_len = mp.path.len;
                    }
                }
            }
        }

        if (best_idx) |idx| {
            const mp = &mounts[idx].?;
            const readlink_fn = mp.fs.readlink orelse return error.NotSupported;

            var rel_path = path[best_len..];
            if (rel_path.len == 0) rel_path = "/";

            return readlink_fn(mp.fs.context, rel_path, buf);
        }

        return error.NotFound;
    }

    /// Get filesystem statistics for a path
    pub fn statfs(path: []const u8) Error!uapi.stat.Statfs {
        if (path.len == 0) return error.InvalidPath;
        if (path[0] != '/') return error.InvalidPath;

        const held = lock.acquire();
        defer held.release();

        // Find the longest matching mount point
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
            const mp = &mounts[idx].?;
            const statfs_fn = mp.fs.statfs orelse return error.NotSupported;
            return statfs_fn(mp.fs.context);
        }

        return error.NotFound;
    }

    /// Get filesystem statistics for a mount point index (internal)
    pub fn statfsByIndex(idx: u8) Error!uapi.stat.Statfs {
        const held = lock.acquire();
        defer held.release();

        if (idx >= MAX_MOUNTS) return error.NotFound;
        if (mounts[idx]) |mp| {
            const statfs_fn = mp.fs.statfs orelse return error.NotSupported;
            return statfs_fn(mp.fs.context);
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

fn initrdStatPath(ctx: ?*anyopaque, path: []const u8) ?FileMeta {
    _ = ctx;

    // Handle root directory
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/.")) {
        return FileMeta{
            .mode = meta.S_IFDIR | 0o755, // Directory with rwxr-xr-x
            .uid = 0,
            .gid = 0,
            .exists = true,
            .readonly = true,
        };
    }

    // Look up any entry (file, directory, symlink) in InitRD
    const file = initrd.InitRD.instance.findEntry(path) orelse return null;

    // Parse permissions from TAR header
    const header = file.header;
    const mode = header.getMode();
    const uid = header.getUid();
    const gid = header.getGid();

    // Determine file type from TAR typeflag
    const file_type: u32 = switch (header.typeflag) {
        '5' => meta.S_IFDIR, // Directory
        '2' => meta.S_IFLNK, // Symlink
        else => meta.S_IFREG, // Regular file (typeflag '0' or '\0')
    };

    return FileMeta{
        .mode = file_type | (mode & 0o7777),
        .uid = uid,
        .gid = gid,
        .exists = true,
        .readonly = true, // InitRD is always read-only
        .size = @intCast(file.data.len),
    };
}

fn initrdStatfs(ctx: ?*anyopaque) Error!uapi.stat.Statfs {
    _ = ctx;
    // InitRD is a RAMdisk based on the loaded modules.
    // For now, return basic info.
    return uapi.stat.Statfs{
        .f_type = 0x01234567, // Generic RAMFS type
        .f_bsize = 512,
        .f_blocks = @intCast(initrd.InitRD.instance.data.len / 512),
        .f_bfree = 0,
        .f_bavail = 0,
        .f_files = 0,
        .f_ffree = 0,
        .f_fsid = .{ .val = .{ 0, 0 } },
        .f_namelen = 255,
        .f_frsize = 512,
        .f_flags = 1, // ST_RDONLY
        .f_spare = [_]i64{0} ** 4,
    };
}

pub const initrd_fs = FileSystem{
    .context = null,
    .open = initrdOpen,
    .unmount = null,
    .unlink = initrdUnlink,
    .stat_path = initrdStatPath,
    .statfs = initrdStatfs,
};
