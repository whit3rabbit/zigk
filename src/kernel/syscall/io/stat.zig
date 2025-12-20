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

/// sys_stat (4) - Get file status
pub fn sys_stat(path_ptr: usize, stat_buf: usize) SyscallError!usize {
    // Allocate path buffer
    const path_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(path_buf);

    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (path.len == 0) return error.ENOENT;

    // Handle root directory explicitly
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/.")) {
        if (!isValidUserAccess(stat_buf, @sizeOf(uapi.stat.Stat), AccessMode.Write)) {
            return error.EFAULT;
        }

        const stat = uapi.stat.Stat{
            .dev = 0,
            .ino = 1, // Root inode
            .nlink = 2,
            .mode = 0o0040755, // S_IFDIR | 0755
            .uid = 0,
            .gid = 0,
            .rdev = 0,
            .size = 4096,
            .blksize = 512,
            .blocks = 8,
            .atime = 0,
            .atime_nsec = 0,
            .mtime = 0,
            .mtime_nsec = 0,
            .ctime = 0,
            .ctime_nsec = 0,
            .__pad0 = 0,
            .__unused = [_]i64{0} ** 3,
        };

        UserPtr.from(stat_buf).writeValue(stat) catch return error.EFAULT;
        return 0;
    }

    // Check InitRD
    if (fs.initrd.InitRD.instance.findFile(path)) |file| {
        if (!isValidUserAccess(stat_buf, @sizeOf(uapi.stat.Stat), AccessMode.Write)) {
            return error.EFAULT;
        }

        // Clamp file size to i64 max for very large files
        const max_i64: usize = @intCast(std.math.maxInt(i64));
        const file_size: i64 = if (file.data.len > max_i64)
            std.math.maxInt(i64)
        else
            @intCast(file.data.len);
        const blocks: i64 = if (file.data.len > max_i64)
            std.math.maxInt(i64) / 512
        else
            @intCast((file.data.len + 511) / 512);

        const stat = uapi.stat.Stat{
            .dev = 0,
            .ino = 0,
            .nlink = 1,
            .mode = 0o100755, // Regular file, rwxr-xr-x
            .uid = 0,
            .gid = 0,
            .rdev = 0,
            .size = file_size,
            .blksize = 512,
            .blocks = blocks,
            .atime = 0,
            .atime_nsec = 0,
            .mtime = 0,
            .mtime_nsec = 0,
            .ctime = 0,
            .ctime_nsec = 0,
            .__pad0 = 0,
            .__unused = [_]i64{0} ** 3,
        };

        UserPtr.from(stat_buf).writeValue(stat) catch return error.EFAULT;
        return 0;
    }

    return error.ENOENT;
}

/// sys_lstat (6) - Get file status (no follow)
pub fn sys_lstat(path_ptr: usize, stat_buf: usize) SyscallError!usize {
    return sys_stat(path_ptr, stat_buf);
}

/// sys_fstat (5) - Get file status by FD
pub fn sys_fstat(fd_num: usize, stat_buf: usize) SyscallError!usize {
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    if (!isValidUserAccess(stat_buf, @sizeOf(uapi.stat.Stat), AccessMode.Write)) {
        return error.EFAULT;
    }

    // Use device specific stat if available
    if (fd.ops.stat) |stat_fn| {
        // We need to pass the kernel address of the struct, but stat_fn takes *anyopaque.
        // Wait, fd.ops.stat signature (in original io.zig) seemed to imply *Stat
        // "const res = stat_fn(fd, &kstat);"
        // So assuming device stat ops take *Stat.

        var kstat: uapi.stat.Stat = undefined;
        // Zero initialize
        const kstat_bytes = std.mem.asBytes(&kstat);
        hal.mem.fill(kstat_bytes.ptr, 0, kstat_bytes.len);

        const res = stat_fn(fd, &kstat);
        if (res < 0) {
            const errno_val: i32 = @intCast(-res);
            _ = errno_val;
            // Map errors? EIO?
            // Just return EIO for now if unknown
            return error.EIO;
        }

        // Copy to user
        UserPtr.from(stat_buf).writeValue(kstat) catch return error.EFAULT;
        return 0;
    }

    // Fallback generic stat
    // Check if it's our dummy root directory FD (private_data == null)
    const is_dir = fd.private_data == null;
    const mode: u32 = if (is_dir) 0o0040755 else 0o0020600; // Directory or Char Device

    const stat = uapi.stat.Stat{
        .dev = 0,
        .ino = @intCast(fd_num),
        .nlink = if (is_dir) 2 else 1,
        .mode = mode,
        .uid = 0,
        .gid = 0,
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
        .__pad0 = 0,
        .__unused = [_]i64{0} ** 3,
    };

    UserPtr.from(stat_buf).writeValue(stat) catch return error.EFAULT;
    return 0;
}
