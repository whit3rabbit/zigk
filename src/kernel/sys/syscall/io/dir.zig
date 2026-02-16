const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const heap = @import("heap");
const fs = @import("fs");
const user_mem = @import("user_mem");
const fd_mod = @import("fd");
const devfs = @import("devfs");
const utils = @import("utils.zig");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;
const isValidUserAccess = base.isValidUserAccess;
const AccessMode = base.AccessMode;
const safeFdCast = utils.safeFdCast;

/// sys_getdents64 (217) - Get directory entries
pub fn sys_getdents64(fd_num: usize, dirp: usize, count: usize) SyscallError!usize {
    const DT_CHR: u8 = 2;
    const DT_REG: u8 = 8;

    // Validate buffer
    if (!isValidUserAccess(dirp, count, AccessMode.Write)) {
        return error.EFAULT;
    }

    // For now, only InitRD root directory is supported
    // Check if FD corresponds to a directory.
    // Since we don't have open(directory) properly yet, let's assume if they call
    // sys_open("/", ...), they get an FD pointing to root.
    // But sys_open("/") fails in current impl (InitRD openFile).

    // We need to implement opening directories.
    // For MVP, if fd is not a valid file FD, maybe it's a dir FD?
    // Or we hack it: if they open a special path.

    // For `ls` to work, it needs to open the current directory.
    // We implemented `sys_getcwd` but `sys_open` fails on dirs.

    // Let's fix `sys_open` to handle "/" by creating a dummy FD for root dir.
    // (Handled in sys_open logic, assuming we have an FD here)

    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    // Check if this FD has a getdents operation (e.g., SFS, ext2, etc.)
    if (fd.ops.getdents) |getdents_fn| {
        const result = getdents_fn(fd, dirp, count);
        if (result < 0) {
            // Negative errno - return as IoError for now
            // TODO: Map specific errno values to proper errors
            return error.EIO;
        }
        return std.math.cast(usize, result) orelse return error.EIO;
    }

    if (fd.ops != &fd_mod.dir_ops) {
        return error.ENOTDIR;
    }

    const initrd_tag_ptr: ?*anyopaque = @ptrCast(@constCast(&fd_mod.initrd_dir_tag));
    const devfs_tag_ptr: ?*anyopaque = @ptrCast(@constCast(&fd_mod.devfs_dir_tag));

    // Use InitRD iterator
    if (fd.private_data == null or fd.private_data == initrd_tag_ptr) {
        // We need to store iteration state (offset) in the FD.
        // We can use fd.position as the offset into the tar file.

        const initrd = &fs.initrd.InitRD.instance;
        const start_offset = std.math.cast(usize, fd.position) orelse return error.EINVAL;
        if (start_offset > initrd.data.len) {
            return 0;
        }

        var iterator = fs.initrd.FileIterator{
            .initrd = initrd,
            .offset = start_offset,
        };

        var bytes_written: usize = 0;
        const buf_uptr = UserPtr.from(dirp);

        while (iterator.next()) |file| {
            const name_len = file.name.len;
            const reclen = @sizeOf(uapi.dirent.Dirent64) + name_len + 1;
            const aligned_reclen = std.mem.alignForward(usize, reclen, 8);

            if (bytes_written + aligned_reclen > count) {
                break;
            }

            var ent: uapi.dirent.Dirent64 = .{
                .d_ino = 1,
                .d_off = @intCast(iterator.offset),
                .d_reclen = @intCast(aligned_reclen),
                .d_type = DT_REG,
                .d_name = undefined,
            };

            const ent_bytes = std.mem.asBytes(&ent);
            _ = buf_uptr.offset(bytes_written).copyFromKernel(ent_bytes) catch return error.EFAULT;

            const name_offset = bytes_written + @offsetOf(uapi.dirent.Dirent64, "d_name");
            _ = buf_uptr.offset(name_offset).copyFromKernel(file.name) catch return error.EFAULT;
            _ = buf_uptr.offset(name_offset + name_len).writeValue(@as(u8, 0)) catch return error.EFAULT;

            bytes_written += aligned_reclen;
            fd.position = iterator.offset;
        }

        return bytes_written;
    }

    if (fd.private_data != devfs_tag_ptr) {
        return error.ENOTDIR;
    }

    const device_names = devfs.snapshotDeviceNames(heap.allocator()) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(device_names);

    const start_index = std.math.cast(usize, fd.position) orelse return error.EINVAL;
    if (start_index >= device_names.len) {
        return 0;
    }

    var bytes_written: usize = 0;
    const buf_uptr = UserPtr.from(dirp);
    var idx: usize = start_index;

    while (idx < device_names.len) : (idx += 1) {
        const name = device_names[idx];
        const name_len = name.len;
        const reclen = @sizeOf(uapi.dirent.Dirent64) + name_len + 1;
        const aligned_reclen = std.mem.alignForward(usize, reclen, 8);

        if (bytes_written + aligned_reclen > count) {
            break;
        }

        var ent: uapi.dirent.Dirent64 = .{
            .d_ino = 1,
            .d_off = @intCast(idx + 1),
            .d_reclen = @intCast(aligned_reclen),
            .d_type = DT_CHR,
            .d_name = undefined,
        };

        const ent_bytes = std.mem.asBytes(&ent);
        _ = buf_uptr.offset(bytes_written).copyFromKernel(ent_bytes) catch return error.EFAULT;

        const name_offset = bytes_written + @offsetOf(uapi.dirent.Dirent64, "d_name");
        _ = buf_uptr.offset(name_offset).copyFromKernel(name) catch return error.EFAULT;
        _ = buf_uptr.offset(name_offset + name_len).writeValue(@as(u8, 0)) catch return error.EFAULT;

        bytes_written += aligned_reclen;
        fd.position = idx + 1;
    }

    return bytes_written;
}

/// sys_getcwd (79) - Get current working directory
pub fn sys_getcwd(buf_ptr: usize, size: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();

    // SECURITY: Acquire cwd_lock to get consistent snapshot of cwd
    // and copy to a local buffer before releasing the lock
    var cwd_copy: [uapi.abi.MAX_PATH]u8 = undefined;
    var cwd_len: usize = undefined;
    {
        const held = proc.cwd_lock.acquire();
        cwd_len = proc.cwd_len;
        if (cwd_len > 0 and cwd_len <= uapi.abi.MAX_PATH) {
            @memcpy(cwd_copy[0..cwd_len], proc.cwd[0..cwd_len]);
        }
        held.release();
    }

    if (cwd_len == 0 or cwd_len > uapi.abi.MAX_PATH) {
        return error.ENOENT;
    }

    if (size < cwd_len + 1) {
        return error.ERANGE;
    }

    if (!isValidUserAccess(buf_ptr, size, AccessMode.Write)) {
        return error.EFAULT;
    }

    const uptr = UserPtr.from(buf_ptr);

    // Copy path from local buffer (not from proc.cwd which could change)
    _ = uptr.copyFromKernel(cwd_copy[0..cwd_len]) catch return error.EFAULT;

    // Null terminate
    uptr.offset(cwd_len).writeValue(@as(u8, 0)) catch return error.EFAULT;

    return cwd_len; // Return length excluding null (POSIX convention)
}

/// sys_chdir (80) - Change working directory
pub fn sys_chdir(path_ptr: usize) SyscallError!usize {
    const path_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(path_buf);

    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (path.len == 0) return error.ENOENT;

    // Canonicalize path: strip trailing slashes, handle "." and "/.."
    var canonical: [uapi.abi.MAX_PATH]u8 = undefined;
    var canon_len: usize = 0;

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/.")) {
        canonical[0] = '/';
        canon_len = 1;
    } else {
        // Check if path exists via VFS and is a directory
        const file_meta = fs.vfs.Vfs.statPath(path) orelse {
            return error.ENOENT;
        };
        if (!fs.meta.isDirectory(file_meta.mode)) {
            return error.ENOTDIR;
        }

        // Build canonical path: ensure leading '/', strip trailing '/'
        if (path[0] != '/') {
            canonical[0] = '/';
            canon_len = 1;
        }
        for (path) |c| {
            if (canon_len >= uapi.abi.MAX_PATH) return error.ENAMETOOLONG;
            canonical[canon_len] = c;
            canon_len += 1;
        }
        // Strip trailing slashes
        while (canon_len > 1 and canonical[canon_len - 1] == '/') {
            canon_len -= 1;
        }
    }

    const proc = base.getCurrentProcess();
    const held = proc.cwd_lock.acquire();
    @memcpy(proc.cwd[0..canon_len], canonical[0..canon_len]);
    proc.cwd_len = canon_len;
    held.release();
    return 0;
}

/// sys_fchdir (81 on x86_64, 50 on aarch64) - Change working directory via open FD
pub fn sys_fchdir(fd_num: usize) SyscallError!usize {
    // Validate FD number
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;

    // Get FD table and look up the FD
    const table = base.getGlobalFdTable();
    const fd = table.get(fd_u32) orelse return error.EBADF;

    // Verify the FD is a directory
    if (fd.ops != &fd_mod.dir_ops) {
        return error.ENOTDIR;
    }

    // Determine the directory path from the FD's private_data (DirTag)
    const initrd_tag_ptr: ?*anyopaque = @ptrCast(@constCast(&fd_mod.initrd_dir_tag));
    const devfs_tag_ptr: ?*anyopaque = @ptrCast(@constCast(&fd_mod.devfs_dir_tag));

    var canonical: [uapi.abi.MAX_PATH]u8 = undefined;
    var canon_len: usize = 0;

    if (fd.private_data == null or fd.private_data == initrd_tag_ptr) {
        // InitRD root directory -> "/"
        canonical[0] = '/';
        canon_len = 1;
    } else if (fd.private_data == devfs_tag_ptr) {
        // DevFS root directory -> "/dev"
        const dev_path = "/dev";
        @memcpy(canonical[0..dev_path.len], dev_path);
        canon_len = dev_path.len;
    } else {
        // Unknown directory tag or SFS directory
        // For now, SFS directories are not supported via fchdir
        // (would require storing the path in the FD or walking the VFS)
        return error.ENOTDIR;
    }

    // Update process cwd
    const proc = base.getCurrentProcess();
    const held = proc.cwd_lock.acquire();
    @memcpy(proc.cwd[0..canon_len], canonical[0..canon_len]);
    proc.cwd_len = canon_len;
    held.release();

    return 0;
}

