const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const heap = @import("heap");
const fs = @import("fs");
const user_mem = @import("user_mem");
const hal = @import("hal");
const utils = @import("utils.zig");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;
const isValidUserAccess = base.isValidUserAccess;
const AccessMode = base.AccessMode;
const safeFdCast = utils.safeFdCast;

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

/// sys_stat (4) - Get file status by path
pub fn sys_stat(path_ptr: usize, stat_buf_ptr: usize) SyscallError!usize {
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
    if (!isValidUserAccess(stat_buf_ptr, @sizeOf(uapi.stat.Stat), AccessMode.Write)) {
        return error.EFAULT;
    }

    // Get file metadata via VFS
    const file_meta = fs.vfs.Vfs.statPath(path) orelse return error.ENOENT;

    // SECURITY: Use UserPtr for SMAP-compliant writes to userspace
    const stat_result: uapi.stat.Stat = .{
        .dev = file_meta.dev,
        .ino = file_meta.ino,
        .nlink = 1,
        .mode = file_meta.mode,
        .uid = file_meta.uid,
        .gid = file_meta.gid,
        .__pad0 = 0,
        .rdev = 0,
        .size = @intCast(file_meta.size),
        .blksize = 512,
        .blocks = @intCast((file_meta.size + 511) / 512),
        .atime = 0,
        .atime_nsec = 0,
        .mtime = 0,
        .mtime_nsec = 0,
        .ctime = 0,
        .ctime_nsec = 0,
        .__unused = [_]i64{0} ** 3,
    };
    UserPtr.from(stat_buf_ptr).writeValue(stat_result) catch return error.EFAULT;

    return 0;
}

/// sys_lstat (6) - Get file status (do not follow symlinks)
pub fn sys_lstat(path_ptr: usize, stat_buf: usize) SyscallError!usize {
    // Current VFS implementation doesn't support symlinks fully,
    // so sys_lstat is equivalent to sys_stat for now.
    return sys_stat(path_ptr, stat_buf);
}

/// sys_fstat (5) - Get file status by file descriptor
pub fn sys_fstat(fd_num: usize, stat_buf_ptr: usize) SyscallError!usize {
    // Validate userspace buffer
    if (!isValidUserAccess(stat_buf_ptr, @sizeOf(uapi.stat.Stat), AccessMode.Write)) {
        return error.EFAULT;
    }

    // Get file descriptor
    const fd_table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const file_desc = fd_table.get(fd_u32) orelse return error.EBADF;

    // Call the FD's stat operation if available
    if (file_desc.ops.stat) |stat_fn| {
        // SECURITY: Zero-initialize at declaration per project guidelines
        var kstat = std.mem.zeroes(uapi.stat.Stat);

        const result = stat_fn(file_desc, &kstat);
        if (result < 0) {
            return error.EIO;
        }
        // SECURITY: Use UserPtr for SMAP-compliant writes to userspace
        UserPtr.from(stat_buf_ptr).writeValue(kstat) catch return error.EFAULT;
        return 0;
    }

    // No stat operation - return basic info
    // Heuristic: if it has vfs_mount_idx, it came from VFS
    const is_dir = file_desc.ops.read == null and file_desc.ops.write == null;
    const default_stat: uapi.stat.Stat = .{
        .dev = 0,
        .ino = @intCast(fd_num),
        .nlink = if (is_dir) 2 else 1,
        .mode = if (is_dir) 0o0040755 else 0o100644,
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
    // SECURITY: Use UserPtr for SMAP-compliant writes to userspace
    UserPtr.from(stat_buf_ptr).writeValue(default_stat) catch return error.EFAULT;

    return 0;
}

/// sys_statfs (137) - Get filesystem statistics
pub fn sys_statfs(path_ptr: usize, buf_ptr: usize) SyscallError!usize {
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
    if (!isValidUserAccess(buf_ptr, @sizeOf(uapi.stat.Statfs), AccessMode.Write)) {
        return error.EFAULT;
    }

    const result = fs.vfs.Vfs.statfs(path) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.NotSupported => error.ENOSYS,
            else => error.EIO,
        };
    };

    UserPtr.from(buf_ptr).writeValue(result) catch return error.EFAULT;
    return 0;
}

/// sys_fstatfs (138) - Get filesystem statistics by FD
pub fn sys_fstatfs(fd_num: usize, buf_ptr: usize) SyscallError!usize {
    // Get file descriptor
    const fd_table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const file_desc = fd_table.get(fd_u32) orelse return error.EBADF;

    // Validate userspace buffer
    if (!isValidUserAccess(buf_ptr, @sizeOf(uapi.stat.Statfs), AccessMode.Write)) {
        return error.EFAULT;
    }

    if (file_desc.vfs_mount_idx) |idx| {
        const result = fs.vfs.Vfs.statfsByIndex(idx) catch |err| {
            return switch (err) {
                error.NotFound => error.ENOENT,
                error.NotSupported => error.ENOSYS,
                else => error.EIO,
            };
        };
        UserPtr.from(buf_ptr).writeValue(result) catch return error.EFAULT;
        return 0;
    }

    return error.ENOSYS;
}
