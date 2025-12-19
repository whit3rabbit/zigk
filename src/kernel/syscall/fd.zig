// File Descriptor Syscall Handlers
//
// Implements file descriptor management syscalls:
// - sys_open: Open a file or device
// - sys_close: Close a file descriptor
// - sys_dup, sys_dup2: Duplicate file descriptors
// - sys_pipe: Create a pipe
// - sys_lseek: Reposition file offset

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const fs = @import("fs");
const heap = @import("heap");
const pipe_mod = @import("pipe");
const fd_mod = @import("fd");
const user_mem = @import("user_mem");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;
const isValidUserAccess = base.isValidUserAccess;
const AccessMode = base.AccessMode;

/// Safe cast for file descriptor numbers from user space
fn safeFdCast(fd_num: usize) ?u32 {
    return std.math.cast(u32, fd_num);
}

fn joinPaths(base_path: []const u8, rel: []const u8, out_buf: []u8) ?[]const u8 {
    if (base_path.len == 0 or rel.len == 0) return null;

    var out_idx: usize = 0;
    if (base_path.len == 1 and base_path[0] == '/') {
        if (out_buf.len < 1 + rel.len) return null;
        out_buf[0] = '/';
        out_idx = 1;
    } else {
        const needs_sep = base_path[base_path.len - 1] != '/';
        const needed = base_path.len + (if (needs_sep) @as(usize, 1) else 0) + rel.len;
        if (out_buf.len < needed) return null;
        @memcpy(out_buf[0..base_path.len], base_path);
        out_idx = base_path.len;
        if (needs_sep) {
            out_buf[out_idx] = '/';
            out_idx += 1;
        }
    }

    @memcpy(out_buf[out_idx .. out_idx + rel.len], rel);
    out_idx += rel.len;

    return out_buf[0..out_idx];
}

fn openPath(path: []const u8, flags: usize, mode: usize) SyscallError!usize {
    _ = mode; // Mode is ignored for now

    if (path.len == 0) {
        return error.ENOENT;
    }

    const fd = fs.vfs.Vfs.open(path, @truncate(flags)) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.AccessDenied => error.EACCES,
            error.InvalidPath => error.ENOENT,
            error.NameTooLong => error.ENAMETOOLONG,
            error.IOError => error.EIO,
            error.NoMemory => error.ENOMEM,
            error.IsDirectory => error.EISDIR,
            else => error.EIO,
        };
    };

    const alloc = heap.allocator();
    errdefer alloc.destroy(fd);

    const table = base.getGlobalFdTable();
    const fd_num = table.allocFdNum() orelse {
        alloc.destroy(fd);
        return error.EMFILE;
    };

    table.install(fd_num, fd);
    return fd_num;
}

// =============================================================================
// File Descriptor Management
// =============================================================================

/// sys_access (21) - Check user's permissions for a file
///
/// Checks if the calling process can access the file pathname.
/// If pathname is a symbolic link, it is dereferenced.
///
/// Mode flags:
///   F_OK (0) - Check existence
///   R_OK (4) - Check read permission
///   W_OK (2) - Check write permission
///   X_OK (1) - Check execute permission
///
/// Returns: 0 on success, negative errno on error
pub fn sys_access(path_ptr: usize, mode: usize) SyscallError!usize {
    _ = mode; // We currently only support existence checking (effective F_OK) for all modes

    // Allocate path buffer on heap to preserve stack space
    const path_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(path_buf);

    // Validate and read path string from userspace
    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (path.len == 0) {
        return error.ENOENT;
    }

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/.")) {
        return 0;
    }

    // Use VFS to try opening the file
    // Note: This is a heavy way to check existence, but VFS doesn't expose stat/access yet
    const fd = fs.vfs.Vfs.open(path, 0) catch |err| {
        return switch (err) {
            error.NotFound => error.ENOENT,
            error.AccessDenied => error.EACCES,
            error.InvalidPath => error.ENOENT,
            error.NameTooLong => error.ENAMETOOLONG,
            error.IOError => error.EIO,
            error.NoMemory => error.ENOMEM,
            error.IsDirectory => 0, // Directories exist, so access returns success
            else => error.EIO,
        };
    };

    // If we opened it, it exists. Close it immediately.
    // First call the close operation to clean up private_data
    if (fd.ops.close) |close_fn| {
        _ = close_fn(fd);
    }
    // Always destroy the FileDescriptor to prevent memory leak
    // (createFd heap-allocates the FileDescriptor)
    heap.allocator().destroy(fd);

    return 0;
}

/// sys_open (2) - Open a file or device
///
/// Opens a file/device and returns a new file descriptor.
pub fn sys_open(path_ptr: usize, flags: usize, mode: usize) SyscallError!usize {
    // Allocate path buffer on heap to preserve stack space
    const path_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(path_buf);

    // Validate and read path string from userspace
    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (path.len == 0) {
        return error.ENOENT;
    }

    return openPath(path, flags, mode);
}

/// sys_close (3) - Close a file descriptor
///
/// Closes the file descriptor and releases associated resources.
pub fn sys_close(fd_num: usize) SyscallError!usize {
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const result = table.close(fd_u32);
    if (result < 0) {
        return error.EBADF;
    }
    return 0;
}

/// sys_dup (32) - Duplicate a file descriptor
pub fn sys_dup(oldfd: usize) SyscallError!usize {
    const table = base.getGlobalFdTable();
    const oldfd_u32 = safeFdCast(oldfd) orelse return error.EBADF;
    const newfd = table.dup(oldfd_u32) catch |err| {
        return switch (err) {
            error.BadFd => error.EBADF,
            error.MFile => error.EMFILE,
        };
    };
    return newfd;
}

/// sys_dup2 (33) - Duplicate a file descriptor to a specific slot
pub fn sys_dup2(oldfd: usize, newfd: usize) SyscallError!usize {
    const table = base.getGlobalFdTable();
    const oldfd_u32 = safeFdCast(oldfd) orelse return error.EBADF;
    const newfd_u32 = safeFdCast(newfd) orelse return error.EBADF;
    const result = table.dup2(oldfd_u32, newfd_u32) catch |err| {
        return switch (err) {
            error.BadFd => error.EBADF,
        };
    };
    return result;
}

/// sys_pipe (22) - Create a pipe
pub fn sys_pipe(pipefd_ptr: usize) SyscallError!usize {
    if (!isValidUserAccess(pipefd_ptr, 2 * @sizeOf(u32), AccessMode.Write)) {
        return error.EFAULT;
    }

    const table = base.getGlobalFdTable();
    var fds: [2]u32 = undefined;
    pipe_mod.createPipe(&fds, table) catch |err| {
        return switch (err) {
            error.MFile => error.EMFILE,
            error.OutOfMemory => error.ENOMEM,
        };
    };

    const uptr = UserPtr.from(pipefd_ptr);
    var fds_i32: [2]i32 = undefined;
    fds_i32[0] = @intCast(fds[0]);
    fds_i32[1] = @intCast(fds[1]);

    _ = uptr.copyFromKernel(std.mem.sliceAsBytes(&fds_i32)) catch {
        // Close FDs if copy fails
        _ = table.close(fds[0]);
        _ = table.close(fds[1]);
        return error.EFAULT;
    };

    return 0;
}

/// sys_lseek (8) - Reposition read/write file offset
///
/// Repositions the file offset of the open file description associated
/// with the file descriptor fd to the argument offset according to whence.
///
/// Args:
///   fd: File descriptor
///   offset: Offset value (interpretation depends on whence)
///   whence: 0=SEEK_SET (absolute), 1=SEEK_CUR (relative to current), 2=SEEK_END (relative to end)
///
/// Returns: New offset position on success, negative errno on error
pub fn sys_lseek(fd_num: usize, offset: i64, whence: u32) SyscallError!usize {
    const table = base.getGlobalFdTable();

    // Get the file descriptor with safe cast
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const file_desc = table.get(fd_u32) orelse {
        return error.EBADF;
    };

    // Check if the file supports seeking
    const seek_fn = file_desc.ops.seek orelse {
        // Device doesn't support seeking (e.g., pipes, sockets, console)
        return error.ESPIPE;
    };

    // Validate whence
    if (whence > 2) {
        return error.EINVAL;
    }

    // Call the device-specific seek operation (legacy isize return)
    const result = seek_fn(file_desc, offset, whence);
    if (result < 0) {
        const errno_val: i32 = @intCast(-result);
        return switch (errno_val) {
            9 => error.EBADF,
            22 => error.EINVAL,
            29 => error.ESPIPE,
            else => error.EINVAL,
        };
    }
    return @intCast(result);
}

// =============================================================================
// Additional FD Operations
// =============================================================================

/// sys_creat (85) - Create a file (legacy)
///
/// Equivalent to open() with O_CREAT|O_WRONLY|O_TRUNC
/// MVP: Stub - returns EROFS (read-only filesystem)
pub fn sys_creat(path_ptr: usize, mode: usize) SyscallError!usize {
    return sys_open(path_ptr, fd_mod.O_CREAT | fd_mod.O_WRONLY | fd_mod.O_TRUNC, mode);
}

/// sys_dup3 (292) - Duplicate FD with flags
///
/// Like dup2, but with flags (e.g., O_CLOEXEC)
pub fn sys_dup3(oldfd: usize, newfd: usize, flags: usize) SyscallError!usize {
    // For now, ignore flags and delegate to dup2
    _ = flags;
    return sys_dup2(oldfd, newfd);
}

/// sys_pipe2 (293) - Create pipe with flags
///
/// Like pipe, but with flags (e.g., O_CLOEXEC, O_NONBLOCK)
pub fn sys_pipe2(pipefd_ptr: usize, flags: usize) SyscallError!usize {
    // For now, ignore flags and delegate to pipe
    _ = flags;
    return sys_pipe(pipefd_ptr);
}

/// sys_openat (257) - Open file relative to directory FD
///
/// MVP: Stub - only supports AT_FDCWD (-100) which means use current directory
pub fn sys_openat(dirfd: usize, path_ptr: usize, flags: usize, mode: usize) SyscallError!usize {
    const AT_FDCWD: usize = @bitCast(@as(isize, -100));

    const path_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(path_buf);

    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (path.len == 0) {
        return error.ENOENT;
    }

    if (path[0] == '/') {
        return openPath(path, flags, mode);
    }

    const resolved_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(resolved_buf);

    const proc = base.getCurrentProcess();
    const initrd_tag_ptr: ?*anyopaque = @ptrCast(@constCast(&fd_mod.initrd_dir_tag));
    const devfs_tag_ptr: ?*anyopaque = @ptrCast(@constCast(&fd_mod.devfs_dir_tag));

    var base_path: []const u8 = undefined;
    if (dirfd == AT_FDCWD) {
        base_path = proc.cwd[0..proc.cwd_len];
    } else {
        const table = base.getGlobalFdTable();
        const fd_u32 = safeFdCast(dirfd) orelse return error.EBADF;
        const fd = table.get(fd_u32) orelse return error.EBADF;

        if (fd.ops != &fd_mod.dir_ops) {
            return error.ENOTDIR;
        }

        if (fd.private_data == devfs_tag_ptr) {
            base_path = "/dev";
        } else if (fd.private_data == null or fd.private_data == initrd_tag_ptr) {
            base_path = "/";
        } else {
            return error.ENOTDIR;
        }
    }

    const resolved = joinPaths(base_path, path, resolved_buf) orelse return error.ENAMETOOLONG;
    return openPath(resolved, flags, mode);
}
