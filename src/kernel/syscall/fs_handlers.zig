// Filesystem Syscall Handlers
//
// Implements filesystem management syscalls:
// - sys_mount: Mount a filesystem
// - sys_umount2: Unmount a filesystem
// - sys_unlink: Delete a file

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const fs = @import("fs");
const heap = @import("heap");
const user_mem = @import("user_mem");
const caps = @import("capabilities");
const devfs = @import("devfs");

const SyscallError = base.SyscallError;

// Mount operation flags
const MOUNT_OP: u8 = 1;
const UMOUNT_OP: u8 = 2;

/// Canonicalize a path by removing redundant components
/// - Removes redundant slashes (// -> /)
/// - Removes . components (/a/./b -> /a/b)
/// - REJECTS paths containing .. (returns null)
/// - Returns slice into provided buffer
fn canonicalizePath(path: []const u8, out_buf: []u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] != '/') return null; // Require absolute path

    var out_idx: usize = 0;
    var i: usize = 0;

    while (i < path.len) {
        // Skip redundant slashes
        if (path[i] == '/') {
            // Add single slash if not already present
            if (out_idx == 0 or out_buf[out_idx - 1] != '/') {
                if (out_idx >= out_buf.len) return null;
                out_buf[out_idx] = '/';
                out_idx += 1;
            }
            i += 1;
            continue;
        }

        // Check for . or .. component
        const remaining = path[i..];
        if (std.mem.startsWith(u8, remaining, "..")) {
            // Check if it's ".." followed by / or end of string
            if (remaining.len == 2 or remaining[2] == '/') {
                // Security: REJECT path traversal
                return null;
            }
        } else if (std.mem.startsWith(u8, remaining, ".")) {
            // Check if it's "." followed by / or end of string
            if (remaining.len == 1 or remaining[1] == '/') {
                // Skip single . component
                i += 1;
                continue;
            }
        }

        // Copy regular path component
        while (i < path.len and path[i] != '/') {
            if (out_idx >= out_buf.len) return null;
            out_buf[out_idx] = path[i];
            out_idx += 1;
            i += 1;
        }
    }

    // Remove trailing slash (except for root)
    if (out_idx > 1 and out_buf[out_idx - 1] == '/') {
        out_idx -= 1;
    }

    return out_buf[0..out_idx];
}

/// sys_mount (165) - Mount a filesystem
///
/// Args:
///   source: Path to device (e.g., "/dev/sda")
///   target: Mount point path (e.g., "/mnt")
///   fstype: Filesystem type string ("sfs")
///   flags: Mount flags (currently ignored)
///   data: Filesystem-specific data (currently ignored)
pub fn sys_mount(
    source_ptr: usize,
    target_ptr: usize,
    fstype_ptr: usize,
    flags: usize,
    data: usize,
) SyscallError!usize {
    _ = flags;
    _ = data;

    const alloc = heap.allocator();

    // Allocate buffers for paths
    const source_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(source_buf);
    const target_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(target_buf);
    const fstype_buf = alloc.alloc(u8, 32) catch return error.ENOMEM;
    defer alloc.free(fstype_buf);

    // Copy strings from userspace
    const source = user_mem.copyStringFromUser(source_buf, source_ptr) catch return error.EFAULT;
    const target = user_mem.copyStringFromUser(target_buf, target_ptr) catch return error.EFAULT;
    const fstype = user_mem.copyStringFromUser(fstype_buf, fstype_ptr) catch return error.EFAULT;

    // Validate target is absolute path
    if (target.len == 0 or target[0] != '/') return error.EINVAL;

    // Capability check
    const proc = base.getCurrentProcess();
    if (!hasMountCapability(proc, target, MOUNT_OP)) {
        return error.EPERM;
    }

    // Get filesystem implementation based on fstype
    const filesystem = getFilesystem(source, fstype) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.NoMemory => error.ENOMEM,
            error.IOError => error.EIO,
            error.NotSupported => error.ENODEV, // Filesystem type not implemented
            else => error.EINVAL,
        };
    };

    // Perform mount
    fs.vfs.Vfs.mount(target, filesystem) catch |err| {
        return switch (err) {
            error.AlreadyMounted => error.EBUSY,
            error.MountPointFull => error.ENOMEM,
            error.NoMemory => error.ENOMEM,
            else => error.EINVAL,
        };
    };

    console.info("sys_mount: Mounted {s} at {s} (type={s})", .{ source, target, fstype });
    return 0;
}

/// sys_umount2 (166) - Unmount a filesystem
///
/// Args:
///   target: Mount point path
///   flags: Unmount flags (MNT_FORCE, MNT_DETACH - currently ignored)
pub fn sys_umount2(target_ptr: usize, flags: usize) SyscallError!usize {
    _ = flags; // TODO: Handle MNT_FORCE, MNT_DETACH

    const alloc = heap.allocator();
    const target_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(target_buf);

    const target = user_mem.copyStringFromUser(target_buf, target_ptr) catch return error.EFAULT;

    if (target.len == 0 or target[0] != '/') return error.EINVAL;

    // Capability check
    const proc = base.getCurrentProcess();
    if (!hasMountCapability(proc, target, UMOUNT_OP)) {
        return error.EPERM;
    }

    // Note: VFS.unmount() already checks for open file handles
    // and returns error.Busy if files are still open

    fs.vfs.Vfs.unmount(target) catch |err| {
        return switch (err) {
            error.NotFound => error.EINVAL,
            error.Busy => error.EBUSY,
            else => error.EINVAL,
        };
    };

    console.info("sys_umount2: Unmounted {s}", .{target});
    return 0;
}

/// sys_unlink (87) - Delete a file
pub fn sys_unlink(path_ptr: usize) SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;

    if (raw_path.len == 0 or raw_path[0] != '/') return error.ENOENT;

    // Security: Canonicalize path to normalize and reject traversal
    // This handles //, /./, and rejects any .. components
    const path = canonicalizePath(raw_path, canon_buf) orelse {
        // Path contains .. or other invalid components
        return error.EACCES;
    };

    // Permission check: require root OR FileCapability with DELETE_OP
    const proc = base.getCurrentProcess();
    if (!hasFileCapability(proc, path, caps.FileCapability.DELETE_OP)) {
        return error.EACCES;
    }

    // Delegate to VFS (which delegates to appropriate FS)
    fs.vfs.Vfs.unlink(path) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.AccessDenied => error.EACCES,
            error.IsDirectory => error.EISDIR,
            error.Busy => error.EBUSY,
            error.IOError => error.EIO,
            error.NotSupported => error.EROFS,
            else => error.EIO,
        };
    };

    return 0;
}

/// Helper: Check if process has mount capability for the given path and operation
/// Root (EUID 0) always has mount permission for system administration
fn hasMountCapability(proc: *@import("process").Process, path: []const u8, op: u8) bool {
    // Root always has mount permission (needed for system setup)
    // SECURITY: Use euid (effective UID) per POSIX semantics, not real uid
    if (proc.euid == 0) return true;

    for (proc.capabilities.items) |cap| {
        switch (cap) {
            .Mount => |mount_cap| {
                if (mount_cap.allows(path, op)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Helper: Check if process has file capability for the given path and operation
/// Root (EUID 0) always has permission for system administration
fn hasFileCapability(proc: *@import("process").Process, path: []const u8, op: u8) bool {
    // Root always has permission
    // SECURITY: Use euid (effective UID) per POSIX semantics, not real uid
    if (proc.euid == 0) return true;

    for (proc.capabilities.items) |cap| {
        switch (cap) {
            .File => |file_cap| {
                if (file_cap.allows(path, op)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Helper: Get filesystem implementation by type
/// Supports: sfs (block device), devfs (virtual), initrd (read-only tar)
fn getFilesystem(source: []const u8, fstype: []const u8) !fs.vfs.FileSystem {
    if (std.mem.eql(u8, fstype, "sfs")) {
        // SFS requires a block device path (e.g., /dev/sda)
        return fs.sfs.SFS.init(source);
    } else if (std.mem.eql(u8, fstype, "devfs")) {
        // DevFS is a singleton virtual filesystem

        return devfs.dev_fs;
    } else if (std.mem.eql(u8, fstype, "initrd")) {
        // InitRD is a singleton (already loaded at boot)

        return fs.vfs.initrd_fs;
    } else if (std.mem.eql(u8, fstype, "tmpfs")) {
        // tmpfs not yet implemented
        return error.NotSupported;
    }
    return error.NotFound;
}

// =============================================================================
// File Status Syscalls (stat, fstat, access)
// =============================================================================

/// sys_stat (4) - Get file status by path
///
/// Args:
///   path_ptr: Path to file
///   statbuf_ptr: Pointer to userspace Stat structure
pub fn sys_stat(path_ptr: usize, statbuf_ptr: usize) SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;
    if (raw_path.len == 0) return error.ENOENT;

    // Canonicalize path
    const path = canonicalizePath(raw_path, canon_buf) orelse return error.ENOENT;

    // Validate userspace buffer
    if (!user_mem.isValidUserPtr(statbuf_ptr, @sizeOf(uapi.stat.Stat))) {
        return error.EFAULT;
    }

    // Get file metadata via VFS
    const file_meta = fs.vfs.Vfs.statPath(path) orelse return error.ENOENT;

    // Fill Stat structure
    const stat_ptr: *uapi.stat.Stat = @ptrFromInt(statbuf_ptr);
    stat_ptr.* = .{
        .dev = 0,
        .ino = 0,
        .nlink = 1,
        .mode = file_meta.mode,
        .uid = file_meta.uid,
        .gid = file_meta.gid,
        .__pad0 = 0,
        .rdev = 0,
        .size = 0, // TODO: Get actual size from VFS
        .blksize = 512,
        .blocks = 0,
        .atime = 0,
        .atime_nsec = 0,
        .mtime = 0,
        .mtime_nsec = 0,
        .ctime = 0,
        .ctime_nsec = 0,
        .__unused = [_]i64{0} ** 3,
    };

    return 0;
}

/// sys_fstat (5) - Get file status by file descriptor
///
/// Args:
///   fd_num: File descriptor number
///   statbuf_ptr: Pointer to userspace Stat structure
pub fn sys_fstat(fd_num: usize, statbuf_ptr: usize) SyscallError!usize {
    const fd_mod = @import("fd");

    // Validate userspace buffer
    if (!user_mem.isValidUserPtr(statbuf_ptr, @sizeOf(uapi.stat.Stat))) {
        return error.EFAULT;
    }

    // Get file descriptor
    const fd_table = base.getGlobalFdTable();
    const file_desc = fd_table.get(@intCast(fd_num)) orelse return error.EBADF;

    // Call the FD's stat operation if available
    const stat_ptr: *uapi.stat.Stat = @ptrFromInt(statbuf_ptr);

    if (file_desc.ops.stat) |stat_fn| {
        const result = stat_fn(file_desc, stat_ptr);
        if (result < 0) {
            // Convert negative errno to SyscallError
            return error.EIO;
        }
        return 0;
    }

    // No stat operation - return basic info
    stat_ptr.* = .{
        .dev = 0,
        .ino = 0,
        .nlink = 1,
        .mode = 0o100644, // Regular file
        .uid = 0,
        .gid = 0,
        .__pad0 = 0,
        .rdev = 0,
        .size = 0,
        .blksize = 512,
        .blocks = 0,
        .atime = 0,
        .atime_nsec = 0,
        .mtime = 0,
        .mtime_nsec = 0,
        .ctime = 0,
        .ctime_nsec = 0,
        .__unused = [_]i64{0} ** 3,
    };

    _ = fd_mod;
    return 0;
}

/// sys_access (21) - Check file access permissions
///
/// Args:
///   path_ptr: Path to file
///   mode: Access mode to check (R_OK=4, W_OK=2, X_OK=1, F_OK=0)
pub fn sys_access(path_ptr: usize, mode: usize) SyscallError!usize {
    const perms = @import("perms");

    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;
    if (raw_path.len == 0) return error.ENOENT;

    // Canonicalize path
    const path = canonicalizePath(raw_path, canon_buf) orelse return error.ENOENT;

    // Get file metadata
    const file_meta = fs.vfs.Vfs.statPath(path) orelse return error.ENOENT;

    // F_OK (0) just checks existence
    if (mode == 0) return 0;

    // Check requested permissions
    const proc = base.getCurrentProcess();

    // Check read permission
    if ((mode & 4) != 0) {
        if (!perms.checkAccess(proc, file_meta, .Read, path)) {
            return error.EACCES;
        }
    }

    // Check write permission
    if ((mode & 2) != 0) {
        if (!perms.checkAccess(proc, file_meta, .Write, path)) {
            return error.EACCES;
        }
    }

    // Check execute permission
    if ((mode & 1) != 0) {
        if (!perms.checkAccess(proc, file_meta, .Execute, path)) {
            return error.EACCES;
        }
    }

    return 0;
}

// =============================================================================
// File Permission Modification Syscalls (chmod, chown)
// =============================================================================

/// sys_chmod (90) - Change file mode
///
/// Args:
///   path_ptr: Path to file
///   mode: New file mode (permissions only, lower 12 bits)
pub fn sys_chmod(path_ptr: usize, mode_arg: usize) SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;
    if (raw_path.len == 0) return error.ENOENT;

    // Canonicalize path
    const path = canonicalizePath(raw_path, canon_buf) orelse return error.ENOENT;

    // Get current file metadata to check ownership
    const file_meta = fs.vfs.Vfs.statPath(path) orelse return error.ENOENT;

    // Only owner or root can chmod
    const proc = base.getCurrentProcess();
    if (proc.euid != 0 and proc.euid != file_meta.uid) {
        return error.EPERM;
    }

    // Only use permission bits (lower 12 bits including setuid/setgid/sticky)
    const new_mode: u32 = @truncate(mode_arg & 0o7777);

    // Perform chmod via VFS
    fs.vfs.Vfs.chmod(path, new_mode) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.NotSupported => error.EROFS,
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    return 0;
}

/// sys_chown (92) - Change file owner and group
///
/// Args:
///   path_ptr: Path to file
///   owner: New owner UID (-1 to keep current)
///   group: New group GID (-1 to keep current)
pub fn sys_chown(path_ptr: usize, owner: usize, group: usize) SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;
    if (raw_path.len == 0) return error.ENOENT;

    // Canonicalize path
    const path = canonicalizePath(raw_path, canon_buf) orelse return error.ENOENT;

    // Only root can chown
    const proc = base.getCurrentProcess();
    if (proc.euid != 0) {
        return error.EPERM;
    }

    // Convert -1 (0xFFFFFFFF) to null for "keep current"
    const new_uid: ?u32 = if (owner == 0xFFFFFFFF) null else @truncate(owner);
    const new_gid: ?u32 = if (group == 0xFFFFFFFF) null else @truncate(group);

    // Perform chown via VFS
    fs.vfs.Vfs.chown(path, new_uid, new_gid) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.NotSupported => error.EROFS,
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    return 0;
}
