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

    // TODO: Check for open file handles on mount point
    // This requires iterating all FD tables and checking paths
    // For MVP, skip this check

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
/// Root (UID 0) always has mount permission for system administration
fn hasMountCapability(proc: *@import("process").Process, path: []const u8, op: u8) bool {
    // Root always has mount permission (needed for system setup)
    if (proc.uid == 0) return true;

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
/// Root (UID 0) always has permission for system administration
fn hasFileCapability(proc: *@import("process").Process, path: []const u8, op: u8) bool {
    // Root always has permission
    if (proc.uid == 0) return true;

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
fn getFilesystem(source: []const u8, fstype: []const u8) !fs.vfs.FileSystem {
    if (std.mem.eql(u8, fstype, "sfs")) {
        return fs.sfs.SFS.init(source);
    }
    // Add other filesystem types as needed
    return error.NotFound;
}
