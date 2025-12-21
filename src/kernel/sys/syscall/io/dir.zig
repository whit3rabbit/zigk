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

    return cwd_len + 1; // Return length including null
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

    // Verify path exists (in InitRD)
    // Note: InitRD is flat, so only "/" is a directory.
    // All other paths are files.

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/.")) {
        const proc = base.getCurrentProcess();
        // SECURITY: Acquire cwd_lock when modifying cwd to prevent
        // races with concurrent openat reading the cwd
        const held = proc.cwd_lock.acquire();
        proc.cwd[0] = '/';
        proc.cwd_len = 1;
        held.release();
        return 0;
    }

    return error.ENOENT;
}

