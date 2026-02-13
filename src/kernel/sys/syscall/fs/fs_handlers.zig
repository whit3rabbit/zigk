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
const vmm = @import("vmm");
const fd_syscall = @import("syscall_fd");
const hal = @import("hal");
const sched = @import("sched");

const perms = @import("perms");

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
) base.SyscallError!usize {
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
    const raw_target = user_mem.copyStringFromUser(target_buf, target_ptr) catch return error.EFAULT;
    const fstype = user_mem.copyStringFromUser(fstype_buf, fstype_ptr) catch return error.EFAULT;

    // Validate target is absolute path
    if (raw_target.len == 0 or raw_target[0] != '/') return error.EINVAL;

    // SECURITY: Canonicalize path BEFORE capability check to prevent bypass via "../"
    // Without this, an attacker with capability for "/data/mnt" could mount to
    // "/data/../bin" which resolves to "/bin" after the capability check passes.
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);
    const target = canonicalizePath(raw_target, canon_buf) orelse {
        // Path contains ".." or other invalid components - reject for security
        return error.EINVAL;
    };

    // Capability check on canonicalized path
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
pub fn sys_umount2(target_ptr: usize, flags: usize) base.SyscallError!usize {
    _ = flags; // TODO: Handle MNT_FORCE, MNT_DETACH

    const alloc = heap.allocator();
    const target_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(target_buf);

    const raw_target = user_mem.copyStringFromUser(target_buf, target_ptr) catch return error.EFAULT;

    if (raw_target.len == 0 or raw_target[0] != '/') return error.EINVAL;

    // SECURITY: Canonicalize path BEFORE capability check to prevent bypass via "../"
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);
    const target = canonicalizePath(raw_target, canon_buf) orelse {
        return error.EINVAL;
    };

    // Capability check on canonicalized path
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
/// Internal: unlink using a kernel-space path (already copied from userspace).
fn unlinkKernel(raw_path: []const u8) base.SyscallError!usize {
    const alloc = heap.allocator();
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    if (raw_path.len == 0 or raw_path[0] != '/') return error.ENOENT;

    const path = canonicalizePath(raw_path, canon_buf) orelse {
        return error.EACCES;
    };

    const proc = base.getCurrentProcess();
    if (!hasFileCapability(proc, path, caps.FileCapability.DELETE_OP)) {
        return error.EACCES;
    }

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

pub fn sys_unlink(path_ptr: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;

    return unlinkKernel(raw_path);
}

/// Helper: Check if process has mount capability for the given path and operation
/// Root (EUID 0) always has mount permission for system administration
fn hasMountCapability(proc: *@import("process").Process, path: []const u8, op: u8) bool {
    // POSIX DAC: Root always has mount permission (needed for system setup).
    // This is standard Unix behavior (CAP_SYS_ADMIN equivalent), distinct from
    // capability-based hardware access controls mentioned in CLAUDE.md.
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
    // POSIX DAC: Root always has file permission (CAP_DAC_OVERRIDE equivalent).
    // This is standard Unix behavior, distinct from capability-based hardware
    // access controls mentioned in CLAUDE.md.
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
// File Status Syscalls (access)
// =============================================================================

/// sys_access (21) - Check file access permissions
///
/// Args:
///   path_ptr: Path to file
///   mode: Access mode to check (R_OK=4, W_OK=2, X_OK=1, F_OK=0)
pub fn sys_access(path_ptr: usize, mode: usize) base.SyscallError!usize {

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
/// Internal: chmod using a kernel-space path (already copied from userspace).
fn chmodKernel(raw_path: []const u8, mode_arg: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    if (raw_path.len == 0) return error.ENOENT;

    const path = canonicalizePath(raw_path, canon_buf) orelse return error.ENOENT;

    const file_meta = fs.vfs.Vfs.statPath(path) orelse return error.ENOENT;

    const proc = base.getCurrentProcess();
    if (proc.euid != 0 and proc.euid != file_meta.uid) {
        return error.EPERM;
    }

    const new_mode: u32 = @truncate(mode_arg & 0o7777);

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

pub fn sys_chmod(path_ptr: usize, mode_arg: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;

    return chmodKernel(raw_path, mode_arg);
}

/// sys_fchmodat (268/53) - Change file permissions relative to directory FD
pub fn sys_fchmodat(dirfd: usize, path_ptr: usize, mode: usize, flags: usize) base.SyscallError!usize {
    const AT_SYMLINK_NOFOLLOW: usize = 0x100;

    if (flags & AT_SYMLINK_NOFOLLOW != 0) {
        return error.ENOSYS;
    }

    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (raw_path.len == 0) return error.ENOENT;

    if (raw_path[0] == '/') {
        return chmodKernel(raw_path, mode);
    }

    const resolved_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(resolved_buf);

    const resolved = fd_syscall.resolvePathAt(dirfd, raw_path, resolved_buf) catch |err| return err;

    return chmodKernel(resolved, mode);
}

/// Internal: chown using a kernel-space path with POSIX permission enforcement.
fn chownKernel(raw_path: []const u8, owner: usize, group: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    if (raw_path.len == 0) return error.ENOENT;
    const path = canonicalizePath(raw_path, canon_buf) orelse return error.ENOENT;

    // Get current file metadata for permission checks
    const file_meta = fs.vfs.Vfs.statPath(path) orelse return error.ENOENT;
    const proc = base.getCurrentProcess();

    // Convert -1 (0xFFFFFFFF) to null for "keep current"
    const new_uid: ?u32 = if (owner == 0xFFFFFFFF or owner == 0xFFFFFFFFFFFFFFFF) null else @truncate(owner);
    const new_gid: ?u32 = if (group == 0xFFFFFFFF or group == 0xFFFFFFFFFFFFFFFF) null else @truncate(group);

    // POSIX permission enforcement:
    // - Root (fsuid == 0) can change anything
    // - File owner can change group to a group they belong to
    // - Non-owner gets EPERM
    if (proc.fsuid != 0) {
        if (proc.fsuid != file_meta.uid) return error.EPERM;
        if (new_uid != null and new_uid.? != file_meta.uid) return error.EPERM;
        if (new_gid) |gid| {
            if (!proc.isGroupMember(gid)) return error.EPERM;
        }
    }

    // Perform the chown via VFS
    fs.vfs.Vfs.chown(path, new_uid, new_gid) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.NotSupported => error.EROFS,
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    // Clear suid/sgid bits on ownership change
    if (new_uid != null or new_gid != null) {
        const current_mode = file_meta.mode;
        const suid_sgid_mask: u32 = 0o6000;
        if (current_mode & suid_sgid_mask != 0) {
            const cleared_mode = current_mode & ~suid_sgid_mask;
            fs.vfs.Vfs.chmod(path, cleared_mode) catch {};
        }
    }

    return 0;
}

/// sys_chown (92) - Change file owner and group
///
/// Args:
///   path_ptr: Path to file
///   owner: New owner UID (-1 to keep current)
///   group: New group GID (-1 to keep current)
pub fn sys_chown(path_ptr: usize, owner: usize, group: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);
    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;
    return chownKernel(raw_path, owner, group);
}

/// sys_lchown (94) - Change file owner and group (no symlink follow)
///
/// Args:
///   path_ptr: Path to file
///   owner: New owner UID (-1 to keep current)
///   group: New group GID (-1 to keep current)
pub fn sys_lchown(path_ptr: usize, owner: usize, group: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);
    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;
    return chownKernel(raw_path, owner, group);
}

/// sys_fchown (93) - Change file owner and group via file descriptor
///
/// Args:
///   fd_num: File descriptor number
///   owner: New owner UID (-1 to keep current)
///   group: New group GID (-1 to keep current)
pub fn sys_fchown(fd_num: usize, owner: usize, group: usize) base.SyscallError!usize {
    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, fd_num) orelse return error.EBADF;
    const file_desc = table.get(fd_u32) orelse return error.EBADF;
    const proc = base.getCurrentProcess();
    const new_uid: ?u32 = if (owner == 0xFFFFFFFF or owner == 0xFFFFFFFFFFFFFFFF) null else @truncate(owner);
    const new_gid: ?u32 = if (group == 0xFFFFFFFF or group == 0xFFFFFFFFFFFFFFFF) null else @truncate(group);

    // Try direct FileOps.chown first
    if (file_desc.ops.chown) |chown_fn| {
        if (file_desc.ops.stat) |stat_fn| {
            var stat_buf: uapi.stat.Stat = undefined;
            const stat_ret = stat_fn(file_desc, @ptrCast(&stat_buf));
            if (stat_ret >= 0) {
                if (proc.fsuid != 0) {
                    if (proc.fsuid != stat_buf.uid) return error.EPERM;
                    if (new_uid != null and new_uid.? != stat_buf.uid) return error.EPERM;
                    if (new_gid) |gid| {
                        if (!proc.isGroupMember(gid)) return error.EPERM;
                    }
                }
            }
        }
        const result = chown_fn(file_desc, new_uid, new_gid);
        if (result < 0) return error.EIO;
        return 0;
    }

    return error.ENOSYS;
}

/// sys_fchownat (260) - Change file owner and group (relative to directory fd)
///
/// Args:
///   dirfd: Directory file descriptor (or AT_FDCWD for current working directory)
///   path_ptr: Path to file (relative or absolute)
///   owner: New owner UID (-1 to keep current)
///   group: New group GID (-1 to keep current)
///   flags: AT_SYMLINK_NOFOLLOW, AT_EMPTY_PATH
pub fn sys_fchownat(dirfd: usize, path_ptr: usize, owner: usize, group: usize, flags: usize) base.SyscallError!usize {
    const AT_SYMLINK_NOFOLLOW: usize = 0x100;
    const AT_EMPTY_PATH: usize = 0x1000;

    if (flags & AT_EMPTY_PATH != 0) {
        return sys_fchown(dirfd, owner, group);
    }

    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (raw_path.len == 0) return error.ENOENT;

    if (raw_path[0] == '/') {
        return chownKernel(raw_path, owner, group);
    }

    const resolved_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(resolved_buf);
    const resolved = fd_syscall.resolvePathAt(dirfd, raw_path, resolved_buf) catch |err| return err;

    _ = flags & AT_SYMLINK_NOFOLLOW; // Acknowledged, same codepath currently
    return chownKernel(resolved, owner, group);
}

// =============================================================================
// File Manipulation Syscalls (truncate, rename, link)
// =============================================================================

/// sys_truncate (76) - Truncate a file to a specified length
pub fn sys_truncate(path_ptr: usize, length: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;
    if (raw_path.len == 0) return error.ENOENT;

    const path = canonicalizePath(raw_path, canon_buf) orelse return error.ENOENT;

    // Check permissions (require write access)
    const file_meta = fs.vfs.Vfs.statPath(path) orelse return error.ENOENT;
    const proc = base.getCurrentProcess();
    if (!@import("perms").checkAccess(proc, file_meta, .Write, path)) {
        return error.EACCES;
    }

    fs.vfs.Vfs.truncate(path, @intCast(length)) catch |err| {
        return switch (err) {
            error.AccessDenied => error.EACCES,
            error.IsDirectory => error.EISDIR,
            error.NotSupported => error.EROFS,
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    return 0;
}

/// sys_ftruncate (77) - Truncate an open file to a specified length
pub fn sys_ftruncate(fd_num: usize, length: usize) base.SyscallError!usize {
    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, fd_num) orelse return error.EBADF;
    const file_desc = table.get(fd_u32) orelse return error.EBADF;

    if (!file_desc.isWritable()) {
        return error.EBADF;
    }

    // Check if the file operation supports truncate
    // We need to add 'truncate' to fd.FileOps
    if (file_desc.ops.truncate) |truncate_fn| {
        truncate_fn(file_desc, @intCast(length)) catch |err| {
            return switch (err) {
                error.AccessDenied => error.EACCES,
                error.IOError => error.EIO,
            };
        };
        return 0;
    }

    return error.EINVAL;
}

/// Internal: rename using kernel-space paths (already copied from userspace).
fn renameKernel(raw_old: []const u8, raw_new: []const u8) base.SyscallError!usize {
    const alloc = heap.allocator();
    const c_old_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(c_old_buf);
    const c_new_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(c_new_buf);

    if (raw_old.len == 0 or raw_new.len == 0) return error.ENOENT;

    const old_path = canonicalizePath(raw_old, c_old_buf) orelse return error.ENOENT;
    const new_path = canonicalizePath(raw_new, c_new_buf) orelse return error.ENOENT;

    const file_meta = fs.vfs.Vfs.statPath(old_path) orelse return error.ENOENT;
    const proc = base.getCurrentProcess();
    if (!@import("perms").checkAccess(proc, file_meta, .Write, old_path)) {
        return error.EACCES;
    }

    fs.vfs.Vfs.rename(old_path, new_path) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.AccessDenied => error.EACCES,
            error.NotSupported => error.EROFS,
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    return 0;
}

/// sys_rename (82) - Rename a file or directory
pub fn sys_rename(old_ptr: usize, new_ptr: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const old_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(old_buf);
    const new_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(new_buf);

    const raw_old = user_mem.copyStringFromUser(old_buf, old_ptr) catch return error.EFAULT;
    const raw_new = user_mem.copyStringFromUser(new_buf, new_ptr) catch return error.EFAULT;

    return renameKernel(raw_old, raw_new);
}

/// sys_renameat (264/38) - Rename file relative to directory file descriptors
pub fn sys_renameat(olddirfd: usize, oldpath_ptr: usize, newdirfd: usize, newpath_ptr: usize) base.SyscallError!usize {
    const alloc = heap.allocator();

    const old_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(old_buf);
    const new_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(new_buf);

    const oldpath = user_mem.copyStringFromUser(old_buf, oldpath_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };
    const newpath = user_mem.copyStringFromUser(new_buf, newpath_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (oldpath.len == 0 or newpath.len == 0) return error.ENOENT;

    // Resolve old path
    var resolved_old: []const u8 = undefined;
    var resolved_old_buf: []u8 = undefined;
    var need_free_old = false;
    defer if (need_free_old) alloc.free(resolved_old_buf);

    if (oldpath[0] == '/') {
        resolved_old = oldpath;
    } else {
        resolved_old_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
        need_free_old = true;
        resolved_old = fd_syscall.resolvePathAt(olddirfd, oldpath, resolved_old_buf) catch |err| return err;
    }

    // Resolve new path
    var resolved_new: []const u8 = undefined;
    var resolved_new_buf: []u8 = undefined;
    var need_free_new = false;
    defer if (need_free_new) alloc.free(resolved_new_buf);

    if (newpath[0] == '/') {
        resolved_new = newpath;
    } else {
        resolved_new_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
        need_free_new = true;
        resolved_new = fd_syscall.resolvePathAt(newdirfd, newpath, resolved_new_buf) catch |err| return err;
    }

    return renameKernel(resolved_old, resolved_new);
}

/// sys_mkdir (83) - Create a directory
pub fn sys_mkdir(path_ptr: usize, mode: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;
    if (raw_path.len == 0) return error.ENOENT;

    return mkdirKernel(raw_path, mode);
}

/// Internal: mkdir using a kernel-space path (already copied from userspace).
/// Shared by sys_mkdir (after copyStringFromUser) and sys_mkdirat (after path resolution).
fn mkdirKernel(raw_path: []const u8, mode: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    const path = canonicalizePath(raw_path, canon_buf) orelse return error.ENOENT;

    const proc = base.getCurrentProcess();
    if (!hasFileCapability(proc, path, caps.FileCapability.DELETE_OP)) {
        return error.EACCES;
    }

    fs.vfs.Vfs.mkdir(path, @intCast(mode & 0o7777)) catch |err| {
        return switch (err) {
            error.AlreadyExists => error.EEXIST,
            error.NotFound => error.ENOENT,
            error.NotSupported => error.EROFS,
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    return 0;
}

/// sys_mkdirat (258/34) - Create directory relative to directory file descriptor
pub fn sys_mkdirat(dirfd: usize, path_ptr: usize, mode: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (raw_path.len == 0) return error.ENOENT;

    // Handle absolute paths directly (bypass dirfd)
    if (raw_path[0] == '/') {
        return mkdirKernel(raw_path, mode);
    }

    // Allocate buffer for resolved path
    const resolved_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(resolved_buf);

    // Resolve path relative to dirfd
    const resolved = fd_syscall.resolvePathAt(dirfd, raw_path, resolved_buf) catch |err| return err;

    return mkdirKernel(resolved, mode);
}

/// Internal: rmdir using a kernel-space path (already copied from userspace).
fn rmdirKernel(raw_path: []const u8) base.SyscallError!usize {
    const alloc = heap.allocator();
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    if (raw_path.len == 0) return error.ENOENT;

    const path = canonicalizePath(raw_path, canon_buf) orelse return error.ENOENT;

    const proc = base.getCurrentProcess();
    if (!hasFileCapability(proc, path, caps.FileCapability.DELETE_OP)) {
        return error.EACCES;
    }

    fs.vfs.Vfs.rmdir(path) catch |err| {
        return switch (err) {
            error.NotEmpty => error.ENOTEMPTY,
            error.NotFound => error.ENOENT,
            error.AccessDenied => error.EACCES,
            error.Busy => error.EBUSY,
            error.NoMemory => error.ENOMEM,
            else => error.EIO,
        };
    };

    return 0;
}

/// sys_rmdir (84) - Remove a directory
pub fn sys_rmdir(path_ptr: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;

    return rmdirKernel(raw_path);
}

/// sys_unlinkat (263/35) - Remove file or directory relative to directory FD
pub fn sys_unlinkat(dirfd: usize, path_ptr: usize, flags: usize) base.SyscallError!usize {
    const AT_REMOVEDIR: usize = 0x200;

    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (raw_path.len == 0) return error.ENOENT;

    // Handle absolute paths directly (bypass dirfd)
    if (raw_path[0] == '/') {
        if (flags & AT_REMOVEDIR != 0) {
            return rmdirKernel(raw_path);
        } else {
            return unlinkKernel(raw_path);
        }
    }

    // Allocate buffer for resolved path
    const resolved_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(resolved_buf);

    // Resolve path relative to dirfd
    const resolved = fd_syscall.resolvePathAt(dirfd, raw_path, resolved_buf) catch |err| return err;

    if (flags & AT_REMOVEDIR != 0) {
        return rmdirKernel(resolved);
    } else {
        return unlinkKernel(resolved);
    }
}

/// Internal: link using kernel-space paths (already copied from userspace).
fn linkKernel(raw_old: []const u8, raw_new: []const u8) base.SyscallError!usize {
    const alloc = heap.allocator();
    const c_old_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(c_old_buf);
    const c_new_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(c_new_buf);

    if (raw_old.len == 0 or raw_new.len == 0) return error.ENOENT;

    const old_path = canonicalizePath(raw_old, c_old_buf) orelse return error.ENOENT;
    const new_path = canonicalizePath(raw_new, c_new_buf) orelse return error.ENOENT;

    // Check permissions
    const file_meta = fs.vfs.Vfs.statPath(old_path) orelse return error.ENOENT;
    const proc = base.getCurrentProcess();
    if (!@import("perms").checkAccess(proc, file_meta, .Write, old_path)) {
        return error.EACCES;
    }

    fs.vfs.Vfs.link(old_path, new_path) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.AlreadyExists => error.EEXIST,
            error.NotSupported => error.EROFS,
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    return 0;
}

/// sys_link (86) - Create a hard link
pub fn sys_link(old_ptr: usize, new_ptr: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const old_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(old_buf);
    const new_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(new_buf);

    const raw_old = user_mem.copyStringFromUser(old_buf, old_ptr) catch return error.EFAULT;
    const raw_new = user_mem.copyStringFromUser(new_buf, new_ptr) catch return error.EFAULT;

    return linkKernel(raw_old, raw_new);
}

/// sys_linkat (265/37) - Create hard link relative to directory file descriptors
pub fn sys_linkat(olddirfd: usize, oldpath_ptr: usize, newdirfd: usize, newpath_ptr: usize, flags: usize) base.SyscallError!usize {

    // For MVP, ignore flags parameter (AT_SYMLINK_FOLLOW is default behavior)
    _ = flags;

    const alloc = heap.allocator();

    // Allocate buffers for both paths
    const old_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(old_buf);
    const new_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(new_buf);

    // Copy both paths from userspace
    const oldpath = user_mem.copyStringFromUser(old_buf, oldpath_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };
    const newpath = user_mem.copyStringFromUser(new_buf, newpath_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (oldpath.len == 0 or newpath.len == 0) return error.ENOENT;

    // Handle absolute old path
    var resolved_old: []const u8 = undefined;
    var resolved_old_buf: []u8 = undefined;
    var need_free_old = false;
    defer if (need_free_old) alloc.free(resolved_old_buf);

    if (oldpath[0] == '/') {
        resolved_old = oldpath;
    } else {
        resolved_old_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
        need_free_old = true;
        resolved_old = fd_syscall.resolvePathAt(olddirfd, oldpath, resolved_old_buf) catch |err| return err;
    }

    // Handle absolute new path
    var resolved_new: []const u8 = undefined;
    var resolved_new_buf: []u8 = undefined;
    var need_free_new = false;
    defer if (need_free_new) alloc.free(resolved_new_buf);

    if (newpath[0] == '/') {
        resolved_new = newpath;
    } else {
        resolved_new_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
        need_free_new = true;
        resolved_new = fd_syscall.resolvePathAt(newdirfd, newpath, resolved_new_buf) catch |err| return err;
    }

    // Call kernel helper with resolved paths
    return linkKernel(resolved_old, resolved_new);
}

/// Internal: symlink using kernel-space paths (already copied from userspace).
/// Note: target is stored as-is (data, not resolved). Only raw_linkpath gets canonicalized.
fn symlinkKernel(target: []const u8, raw_linkpath: []const u8) base.SyscallError!usize {
    const alloc = heap.allocator();
    const c_link_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(c_link_buf);

    if (target.len == 0 or raw_linkpath.len == 0) return error.ENOENT;

    const linkpath = canonicalizePath(raw_linkpath, c_link_buf) orelse return error.ENOENT;

    // Simplified permission check: check write access to the directory where link will be created.
    // For now, we stub this with a generic check or relying on VFS/FS errors.

    fs.vfs.Vfs.symlink(target, linkpath) catch |err| {
        return switch (err) {
            error.AlreadyExists => error.EEXIST,
            error.NotSupported => error.EROFS,
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    return 0;
}

/// sys_symlink (88) - Create a symbolic link
pub fn sys_symlink(target_ptr: usize, linkpath_ptr: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const target_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(target_buf);
    const link_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(link_buf);

    const target = user_mem.copyStringFromUser(target_buf, target_ptr) catch return error.EFAULT;
    const raw_link = user_mem.copyStringFromUser(link_buf, linkpath_ptr) catch return error.EFAULT;

    return symlinkKernel(target, raw_link);
}

/// sys_symlinkat (266/36) - Create symbolic link relative to directory file descriptor
pub fn sys_symlinkat(target_ptr: usize, newdirfd: usize, linkpath_ptr: usize) base.SyscallError!usize {

    const alloc = heap.allocator();

    // Copy target from userspace (NOT resolved - symlinks store paths as-is)
    const target_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(target_buf);
    const target = user_mem.copyStringFromUser(target_buf, target_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    // Copy linkpath from userspace
    const link_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(link_buf);
    const linkpath = user_mem.copyStringFromUser(link_buf, linkpath_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (target.len == 0 or linkpath.len == 0) return error.ENOENT;

    // Handle absolute linkpath
    if (linkpath[0] == '/') {
        return symlinkKernel(target, linkpath);
    }

    // Resolve linkpath relative to newdirfd
    const resolved_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(resolved_buf);
    const resolved_link = fd_syscall.resolvePathAt(newdirfd, linkpath, resolved_buf) catch |err| return err;

    // Call kernel helper with literal target and resolved linkpath
    return symlinkKernel(target, resolved_link);
}

/// Internal: readlink using kernel-space path (already copied from userspace).
fn readlinkKernel(raw_path: []const u8, buf_ptr: usize, bufsiz: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);

    if (raw_path.len == 0) return error.ENOENT;

    const path = canonicalizePath(raw_path, canon_buf) orelse return error.ENOENT;

    // Validate user buffer
    if (!base.isValidUserAccess(buf_ptr, bufsiz, base.AccessMode.Write)) {
        return error.EFAULT;
    }

    const kbuf = alloc.alloc(u8, bufsiz) catch return error.ENOMEM;
    defer alloc.free(kbuf);

    const bytes_read = fs.vfs.Vfs.readlink(path, kbuf) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.NotSupported => error.EINVAL, // Not a symlink
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    // Copy to user memory
    const uptr = base.UserPtr.from(buf_ptr);
    _ = uptr.copyFromKernel(kbuf[0..bytes_read]) catch return error.EFAULT;

    return bytes_read;
}

/// sys_readlink (89) - Read target of a symbolic link
pub fn sys_readlink(path_ptr: usize, buf_ptr: usize, bufsiz: usize) base.SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;

    return readlinkKernel(raw_path, buf_ptr, bufsiz);
}

/// sys_readlinkat (267/78) - Read symbolic link relative to directory file descriptor
pub fn sys_readlinkat(dirfd: usize, path_ptr: usize, buf_ptr: usize, bufsiz: usize) base.SyscallError!usize {

    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (path.len == 0) return error.ENOENT;

    // Handle absolute paths directly (bypass dirfd)
    if (path[0] == '/') {
        return readlinkKernel(path, buf_ptr, bufsiz);
    }

    // Allocate buffer for resolved path
    const resolved_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(resolved_buf);

    // Resolve path relative to dirfd
    const resolved = fd_syscall.resolvePathAt(dirfd, path, resolved_buf) catch |err| return err;

    // Call kernel helper with resolved path
    return readlinkKernel(resolved, buf_ptr, bufsiz);
}

// =============================================================================
// File Synchronization Syscalls (fsync, fdatasync, sync, syncfs)
// =============================================================================

/// sys_fsync (74) - Synchronize file's in-core state with storage device
///
/// Flush file data and metadata to storage. Since this kernel has no write-back
/// buffer cache (SFS writes go directly to disk via writeSector), the data is
/// already on disk. This syscall validates the FD and returns success.
///
/// Args:
///   fd_num: File descriptor number
pub fn sys_fsync(fd_num: usize) base.SyscallError!usize {
    const fd_u32 = std.math.cast(u32, fd_num) orelse return error.EBADF;
    const table = base.getGlobalFdTable();
    _ = table.get(fd_u32) orelse return error.EBADF;

    // No buffer cache to flush -- data is already on disk
    return 0;
}

/// sys_fdatasync (75) - Synchronize file's data with storage device
///
/// Flush file data only (skip non-essential metadata like atime). Since this
/// kernel has no buffer cache, this is identical to fsync. Validate FD and
/// return success.
///
/// Args:
///   fd_num: File descriptor number
pub fn sys_fdatasync(fd_num: usize) base.SyscallError!usize {
    const fd_u32 = std.math.cast(u32, fd_num) orelse return error.EBADF;
    const table = base.getGlobalFdTable();
    _ = table.get(fd_u32) orelse return error.EBADF;

    // No buffer cache to flush -- data is already on disk
    return 0;
}

/// sys_sync (162) - Commit filesystem caches to disk
///
/// Flush all filesystem buffers globally. Since this kernel has no buffer cache,
/// this is a no-op. Always succeeds per POSIX semantics.
pub fn sys_sync() base.SyscallError!usize {
    // No buffer cache to flush -- all writes are synchronous
    return 0;
}

/// sys_syncfs (306) - Synchronize a filesystem
///
/// Flush buffers for the filesystem containing the given FD. Since this kernel
/// has no buffer cache, this validates the FD and returns success.
///
/// Args:
///   fd_num: File descriptor number
pub fn sys_syncfs(fd_num: usize) base.SyscallError!usize {
    const fd_u32 = std.math.cast(u32, fd_num) orelse return error.EBADF;
    const table = base.getGlobalFdTable();
    _ = table.get(fd_u32) orelse return error.EBADF;

    // No buffer cache to flush -- data is already on disk
    return 0;
}

// =============================================================================
// Advanced File Operations (fallocate, renameat2)
// =============================================================================

/// sys_fallocate (285 on x86_64, 47 on aarch64) - Pre-allocate or manipulate file space
///
/// Args:
///   fd_num: File descriptor number
///   mode: Allocation mode flags (FALLOC_FL_KEEP_SIZE, FALLOC_FL_PUNCH_HOLE)
///   offset_arg: Starting offset for allocation (i64)
///   len_arg: Length of allocation (i64)
pub fn sys_fallocate(fd_num: usize, mode: usize, offset_arg: usize, len_arg: usize) base.SyscallError!usize {
    // Mode flags
    const FALLOC_FL_KEEP_SIZE: usize = 0x01;
    const FALLOC_FL_PUNCH_HOLE: usize = 0x02;

    // Validate FD
    const fd_u32 = std.math.cast(u32, fd_num) orelse return error.EBADF;
    const table = base.getGlobalFdTable();
    const file_desc = table.get(fd_u32) orelse return error.EBADF;

    // Check fd is writable
    if (!file_desc.isWritable()) return error.EBADF;

    // Interpret offset and len as i64
    const offset = @as(i64, @bitCast(@as(u64, offset_arg)));
    const len = @as(i64, @bitCast(@as(u64, len_arg)));

    // Validate offset and len
    if (offset < 0) return error.EINVAL;
    if (len <= 0) return error.EINVAL;

    // Check for PUNCH_HOLE mode (not supported on SFS)
    if (mode & FALLOC_FL_PUNCH_HOLE != 0) {
        return error.ENOSYS;
    }

    // Check for unsupported modes (only KEEP_SIZE is supported)
    if (mode & ~FALLOC_FL_KEEP_SIZE != 0) {
        return error.ENOSYS;
    }

    // Calculate required size
    const offset_u64 = @as(u64, @intCast(offset));
    const len_u64 = @as(u64, @intCast(len));
    const required_size = std.math.add(u64, offset_u64, len_u64) catch return error.EFBIG;

    // Mode == 0: Extend file if needed (default fallocate behavior)
    if (mode == 0) {
        // Get current file size via stat
        var current_size: u64 = 0;
        if (file_desc.ops.stat) |stat_fn| {
            var kstat = std.mem.zeroes(uapi.stat.Stat);
            const result = stat_fn(file_desc, &kstat);
            if (result < 0) return error.EIO;
            current_size = @intCast(kstat.size);
        } else {
            return error.ENOSYS;
        }

        if (required_size > current_size) {
            // Use truncate to extend the file
            if (file_desc.ops.truncate) |truncate_fn| {
                truncate_fn(file_desc, required_size) catch |err| {
                    return switch (err) {
                        error.AccessDenied => error.EACCES,
                        error.IOError => error.EIO,
                    };
                };
            } else {
                return error.ENOSYS;
            }
        }
    }

    // Mode == FALLOC_FL_KEEP_SIZE: Space reservation hint, validate FD only
    // Since SFS allocates on-demand, this is a no-op after validation

    return 0;
}

/// Internal: rename2 using kernel-space paths with flags support
fn renameKernel2(raw_old: []const u8, raw_new: []const u8, flags: u32) base.SyscallError!usize {
    const alloc = heap.allocator();
    const c_old_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(c_old_buf);
    const c_new_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(c_new_buf);

    if (raw_old.len == 0 or raw_new.len == 0) return error.ENOENT;

    const old_path = canonicalizePath(raw_old, c_old_buf) orelse return error.ENOENT;
    const new_path = canonicalizePath(raw_new, c_new_buf) orelse return error.ENOENT;

    // Define RENAME flags locally
    const RENAME_NOREPLACE: u32 = 1;

    // RENAME_NOREPLACE: Fast-path check if destination exists
    if (flags & RENAME_NOREPLACE != 0) {
        if (fs.vfs.Vfs.statPath(new_path)) |_| {
            return error.EEXIST;
        }
    }

    // Permission check on old file
    const file_meta = fs.vfs.Vfs.statPath(old_path) orelse return error.ENOENT;
    const proc = base.getCurrentProcess();
    if (!@import("perms").checkAccess(proc, file_meta, .Write, old_path)) {
        return error.EACCES;
    }

    // Call VFS rename2
    fs.vfs.Vfs.rename2(old_path, new_path, flags) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.AccessDenied => error.EACCES,
            error.AlreadyExists => error.EEXIST,
            error.NotSupported => error.EROFS,
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    return 0;
}

/// sys_renameat2 (316 on x86_64, 276 on aarch64) - Rename file with flags
///
/// Args:
///   olddirfd: Old directory file descriptor (or AT_FDCWD)
///   oldpath_ptr: Old path (relative or absolute)
///   newdirfd: New directory file descriptor (or AT_FDCWD)
///   newpath_ptr: New path (relative or absolute)
///   flags: RENAME_NOREPLACE, RENAME_EXCHANGE, or 0
pub fn sys_renameat2(olddirfd: usize, oldpath_ptr: usize, newdirfd: usize, newpath_ptr: usize, flags: usize) base.SyscallError!usize {
    const RENAME_NOREPLACE: u32 = 1;
    const RENAME_EXCHANGE: u32 = 2;

    const alloc = heap.allocator();

    const old_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(old_buf);
    const new_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(new_buf);

    const oldpath = user_mem.copyStringFromUser(old_buf, oldpath_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };
    const newpath = user_mem.copyStringFromUser(new_buf, newpath_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (oldpath.len == 0 or newpath.len == 0) return error.ENOENT;

    // Validate flags (NOREPLACE and EXCHANGE are mutually exclusive)
    const flags_u32 = std.math.cast(u32, flags) orelse return error.EINVAL;
    if (flags_u32 & RENAME_NOREPLACE != 0 and flags_u32 & RENAME_EXCHANGE != 0) {
        return error.EINVAL;
    }

    // Resolve old path
    var resolved_old: []const u8 = undefined;
    var resolved_old_buf: []u8 = undefined;
    var need_free_old = false;
    defer if (need_free_old) alloc.free(resolved_old_buf);

    if (oldpath[0] == '/') {
        resolved_old = oldpath;
    } else {
        resolved_old_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
        need_free_old = true;
        resolved_old = fd_syscall.resolvePathAt(olddirfd, oldpath, resolved_old_buf) catch |err| return err;
    }

    // Resolve new path
    var resolved_new: []const u8 = undefined;
    var resolved_new_buf: []u8 = undefined;
    var need_free_new = false;
    defer if (need_free_new) alloc.free(resolved_new_buf);

    if (newpath[0] == '/') {
        resolved_new = newpath;
    } else {
        resolved_new_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
        need_free_new = true;
        resolved_new = fd_syscall.resolvePathAt(newdirfd, newpath, resolved_new_buf) catch |err| return err;
    }

    return renameKernel2(resolved_old, resolved_new, flags_u32);
}

// =============================================================================
// File Timestamp Syscalls (utimensat, futimesat)
// =============================================================================

/// Special timespec values for utimensat
const UTIME_NOW: i64 = (1 << 30) - 1; // 0x3fffffff
const UTIME_OMIT: i64 = (1 << 30) - 2; // 0x3ffffffe

/// Get current time in nanoseconds since epoch (for UTIME_NOW)
fn getCurrentTimeNs() u64 {
    const freq = hal.timing.getTscFrequency();
    if (freq > 0) {
        const tsc = hal.timing.rdtsc();
        const tsc_u128 = @as(u128, tsc);
        const ns_u128 = (tsc_u128 * 1_000_000_000) / freq;
        return @truncate(ns_u128);
    } else {
        // Fallback to tick count (10ms resolution)
        const ticks = sched.getTickCount();
        const ms = ticks *| 10; // saturating mul
        return ms * 1_000_000; // ms to ns
    }
}

/// sys_utimensat (280/88) - Set file timestamps with nanosecond precision
///
/// Args:
///   dirfd: Directory file descriptor (or AT_FDCWD for current working directory)
///   path_ptr: Path to file (relative or absolute)
///   times_ptr: Pointer to [2]Timespec array ([0]=atime, [1]=mtime), or NULL to set both to current time
///   flags: AT_SYMLINK_NOFOLLOW (0x100) or 0
pub fn sys_utimensat(dirfd: usize, path_ptr: usize, times_ptr: usize, flags: usize) base.SyscallError!usize {
    const AT_SYMLINK_NOFOLLOW: usize = 0x100;

    // Validate flags - AT_SYMLINK_NOFOLLOW is supported (VFS operates on literal paths,
    // so symlinks are not followed by default -- the flag is accepted and the path
    // refers to the symlink entry itself)
    if (flags & ~AT_SYMLINK_NOFOLLOW != 0) {
        return error.EINVAL; // Invalid flags
    }

    const alloc = heap.allocator();

    // Read timespec array from userspace (or use UTIME_NOW for both if NULL)
    var atime_sec: i64 = undefined;
    var atime_nsec: i64 = undefined;
    var mtime_sec: i64 = undefined;
    var mtime_nsec: i64 = undefined;

    if (times_ptr == 0) {
        // NULL times pointer: set both to current time
        const now_ns = getCurrentTimeNs();
        const now_sec = @as(i64, @intCast(now_ns / 1_000_000_000));
        const now_nsec = @as(i64, @intCast(now_ns % 1_000_000_000));
        atime_sec = now_sec;
        atime_nsec = now_nsec;
        mtime_sec = now_sec;
        mtime_nsec = now_nsec;
    } else {
        // Read [2]Timespec from userspace
        if (!base.isValidUserAccess(times_ptr, @sizeOf([2]uapi.abi.Timespec), base.AccessMode.Read)) {
            return error.EFAULT;
        }
        const uptr = base.UserPtr.from(times_ptr);
        const times = uptr.readValue([2]uapi.abi.Timespec) catch return error.EFAULT;

        // Validate and process atime (times[0])
        atime_sec = times[0].tv_sec;
        atime_nsec = times[0].tv_nsec;
        if (atime_nsec != UTIME_NOW and atime_nsec != UTIME_OMIT) {
            if (atime_nsec < 0 or atime_nsec > 999_999_999) {
                return error.EINVAL;
            }
        }

        // Validate and process mtime (times[1])
        mtime_sec = times[1].tv_sec;
        mtime_nsec = times[1].tv_nsec;
        if (mtime_nsec != UTIME_NOW and mtime_nsec != UTIME_OMIT) {
            if (mtime_nsec < 0 or mtime_nsec > 999_999_999) {
                return error.EINVAL;
            }
        }

        // Resolve UTIME_NOW for atime
        if (atime_nsec == UTIME_NOW) {
            const now_ns = getCurrentTimeNs();
            atime_sec = @as(i64, @intCast(now_ns / 1_000_000_000));
            atime_nsec = @as(i64, @intCast(now_ns % 1_000_000_000));
        } else if (atime_nsec == UTIME_OMIT) {
            atime_sec = -1; // Convention: -1 means "leave unchanged"
        }

        // Resolve UTIME_NOW for mtime
        if (mtime_nsec == UTIME_NOW) {
            const now_ns = getCurrentTimeNs();
            mtime_sec = @as(i64, @intCast(now_ns / 1_000_000_000));
            mtime_nsec = @as(i64, @intCast(now_ns % 1_000_000_000));
        } else if (mtime_nsec == UTIME_OMIT) {
            mtime_sec = -1; // Convention: -1 means "leave unchanged"
        }
    }

    // Copy path from userspace
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (raw_path.len == 0) return error.ENOENT;

    // Resolve path (absolute or relative to dirfd)
    var resolved: []const u8 = undefined;
    var resolved_buf: []u8 = undefined;
    var need_free = false;
    defer if (need_free) alloc.free(resolved_buf);

    if (raw_path[0] == '/') {
        resolved = raw_path;
    } else {
        resolved_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
        need_free = true;
        resolved = fd_syscall.resolvePathAt(dirfd, raw_path, resolved_buf) catch |err| return err;
    }

    // Canonicalize the path
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);
    const path = canonicalizePath(resolved, canon_buf) orelse return error.ENOENT;

    // Call VFS setTimestamps
    fs.vfs.Vfs.setTimestamps(path, atime_sec, atime_nsec, mtime_sec, mtime_nsec) catch |err| {
        return switch (err) {
            error.NotSupported => error.EROFS,
            error.NotFound => error.ENOENT,
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    return 0;
}

/// Timeval structure for futimesat (microsecond precision, legacy)
const Timeval = extern struct {
    tv_sec: i64,
    tv_usec: i64,
};

/// sys_futimesat (261/528) - Set file timestamps with microsecond precision (legacy)
///
/// Args:
///   dirfd: Directory file descriptor (or AT_FDCWD for current working directory)
///   path_ptr: Path to file (relative or absolute)
///   times_ptr: Pointer to [2]Timeval array ([0]=atime, [1]=mtime), or NULL to set both to current time
pub fn sys_futimesat(dirfd: usize, path_ptr: usize, times_ptr: usize) base.SyscallError!usize {
    // If times_ptr is NULL, delegate to utimensat with NULL times
    if (times_ptr == 0) {
        return sys_utimensat(dirfd, path_ptr, 0, 0);
    }

    // Read [2]Timeval from userspace
    if (!base.isValidUserAccess(times_ptr, @sizeOf([2]Timeval), base.AccessMode.Read)) {
        return error.EFAULT;
    }
    const uptr = base.UserPtr.from(times_ptr);
    const times = uptr.readValue([2]Timeval) catch return error.EFAULT;

    // Validate and convert timeval to timespec
    // Timeval has microsecond precision, Timespec has nanosecond precision
    for (times) |tv| {
        if (tv.tv_usec < 0 or tv.tv_usec >= 1_000_000) {
            return error.EINVAL;
        }
    }

    // Convert to timespec (microseconds to nanoseconds: multiply by 1000)
    var timespec_array: [2]uapi.abi.Timespec = undefined;
    timespec_array[0] = .{
        .tv_sec = times[0].tv_sec,
        .tv_nsec = times[0].tv_usec * 1000,
    };
    timespec_array[1] = .{
        .tv_sec = times[1].tv_sec,
        .tv_nsec = times[1].tv_usec * 1000,
    };

    // Allocate temporary kernel buffer to hold the timespec array
    const alloc = heap.allocator();
    const ts_buf = alloc.alloc(u8, @sizeOf([2]uapi.abi.Timespec)) catch return error.ENOMEM;
    defer alloc.free(ts_buf);

    // Copy timespec array to the buffer
    const ts_ptr: *[2]uapi.abi.Timespec = @ptrCast(@alignCast(ts_buf.ptr));
    ts_ptr.* = timespec_array;

    // Copy path from userspace
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (raw_path.len == 0) return error.ENOENT;

    // Resolve path (absolute or relative to dirfd)
    var resolved: []const u8 = undefined;
    var resolved_buf: []u8 = undefined;
    var need_free = false;
    defer if (need_free) alloc.free(resolved_buf);

    if (raw_path[0] == '/') {
        resolved = raw_path;
    } else {
        resolved_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
        need_free = true;
        resolved = fd_syscall.resolvePathAt(dirfd, raw_path, resolved_buf) catch |err| return err;
    }

    // Canonicalize the path
    const canon_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(canon_buf);
    const path = canonicalizePath(resolved, canon_buf) orelse return error.ENOENT;

    // Call VFS setTimestamps with converted values
    const atime_sec = timespec_array[0].tv_sec;
    const atime_nsec = timespec_array[0].tv_nsec;
    const mtime_sec = timespec_array[1].tv_sec;
    const mtime_nsec = timespec_array[1].tv_nsec;

    fs.vfs.Vfs.setTimestamps(path, atime_sec, atime_nsec, mtime_sec, mtime_nsec) catch |err| {
        return switch (err) {
            error.NotSupported => error.EROFS,
            error.NotFound => error.ENOENT,
            error.IOError => error.EIO,
            else => error.EIO,
        };
    };

    return 0;
}
