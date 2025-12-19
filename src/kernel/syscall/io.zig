// I/O Syscall Handlers
//
// Implements file I/O and filesystem syscalls:
// - sys_read, sys_write, sys_writev: Basic I/O
// - sys_ioctl: Device control
// - sys_stat, sys_lstat, sys_fstat: File status
// - sys_getdents64: Directory entries
// - sys_getcwd, sys_chdir, sys_mkdir: Working directory
// - sys_fcntl: File descriptor control

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const fs = @import("fs");
const heap = @import("heap");
const fd_mod = @import("fd");
const user_mem = @import("user_mem");
const error_helpers = @import("error_helpers.zig");
const hal = @import("hal");
const devfs = @import("devfs");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;
const isValidUserAccess = base.isValidUserAccess;
const AccessMode = base.AccessMode;
const FileDescriptor = base.FileDescriptor;

/// Safe cast for file descriptor numbers from user space
fn safeFdCast(fd_num: usize) ?u32 {
    return std.math.cast(u32, fd_num);
}

fn mapSeekResult(result: isize) SyscallError!void {
    if (result >= 0) return;

    const errno_val: i32 = @intCast(-result);
    return switch (errno_val) {
        9 => error.EBADF,
        22 => error.EINVAL,
        29 => error.ESPIPE,
        else => error.EINVAL,
    };
}

// =============================================================================
// I/O Operations
// =============================================================================

/// sys_read (0) - Read from file descriptor
///
/// Reads up to count bytes from fd into buf.
/// Uses FD table to dispatch to appropriate device read operation.
pub fn sys_read(fd_num: usize, buf_ptr: usize, count: usize) SyscallError!usize {
    if (count == 0) {
        return 0;
    }

    // Get FD from table
    const table = base.getGlobalFdTable();

    // [Debug] Log reads on stdin (0)
    if (fd_num == 0) {
        console.debug("Syscall: read(0, {x}, {})", .{ buf_ptr, count });
    }

    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse {
        return error.EBADF;
    };

    // Check if FD is readable
    if (!fd.isReadable()) {
        return error.EBADF;
    }

    // Call device read operation
    const read_fn = fd.ops.read orelse {
        return error.ENOSYS;
    };

    // Allocate kernel buffer for the read
    // For large reads, we should loop. For MVP, we cap at 4KB or alloc from heap?
    // Let's alloc from heap to be safe for now, or just limit large reads to 4096.
    // For robustness, clamping to 4096 is safer for kernel stack, but allocating is better.
    // Given the kernel heap allocator is available, let's use it.

    // Cap read size to avoid massive allocations (e.g. 1GB)
    const max_read_size = 64 * 1024; // 64KB chunks
    const read_size = @min(count, max_read_size);

    // Validate buffer for write before consuming device data to avoid data loss
    if (!isValidUserAccess(buf_ptr, read_size, AccessMode.Write)) {
        return error.EFAULT;
    }

    const kbuf = heap.allocator().alloc(u8, read_size) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    // Read into kernel buffer (legacy isize return from device ops)
    const bytes_read = read_fn(fd, kbuf);
    const valid_read = try error_helpers.mapDeviceError(bytes_read);

    // Copy to user memory
    const uptr = UserPtr.from(buf_ptr);

    // Only copy what was actually read
    const copy_res = uptr.copyFromKernel(kbuf[0..valid_read]);
    if (copy_res == error.Fault) {
        return error.EFAULT;
    }

    return valid_read;
}

/// sys_write (1) - Write to file descriptor
///
/// Writes up to count bytes from buf to fd.
/// Uses FD table to dispatch to appropriate device write operation.
pub fn sys_write(fd_num: usize, buf_ptr: usize, count: usize) SyscallError!usize {
    console.debug("sys_write: fd={d} count={d} buf={x}", .{ fd_num, count, buf_ptr });

    if (count == 0) {
        return 0;
    }

    // Get FD from table
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse {
        return error.EBADF;
    };

    // Check if FD is writable
    if (!fd.isWritable()) {
        return error.EBADF;
    }

    // Call device write operation
    if (fd.ops.write == null) {
        console.warn("Syscall: Write on FD {} not supported", .{fd_num});
        return error.ENOSYS;
    }

    // Cap write size
    const max_write_size = 64 * 1024;
    const write_size = @min(count, max_write_size);

    if (!isValidUserAccess(buf_ptr, write_size, AccessMode.Read)) {
        return error.EFAULT;
    }

    const kbuf = heap.allocator().alloc(u8, write_size) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    // Copy from user to kernel
    const uptr = UserPtr.from(buf_ptr);
    _ = uptr.copyToKernel(kbuf) catch return error.EFAULT;

    // Write from kernel buffer (legacy isize return from device ops)
    // Acquire lock for atomicity
    const held = fd.lock.acquire();
    defer held.release();

    const bytes_written = do_write_locked(fd, kbuf);

    console.debug("sys_write: result={d}", .{bytes_written});

    return error_helpers.mapDeviceError(bytes_written);
}

/// Helper for locked write operations
fn do_write_locked(fd: *FileDescriptor, kbuf: []const u8) isize {
    const write_fn = fd.ops.write orelse return -5; // EIO
    return write_fn(fd, kbuf);
}

/// Helper for locked read operations
fn do_read_locked(fd: *FileDescriptor, kbuf: []u8) isize {
    const read_fn = fd.ops.read orelse return -5; // EIO
    return read_fn(fd, kbuf);
}

/// sys_writev (20) - Write data from multiple buffers
///
/// Args:
///   fd: File descriptor
///   bvec_ptr: Pointer to iovec array
///   count: Number of iovec structs
///
/// Returns: Total bytes written or error
pub fn sys_writev(fd: usize, bvec_ptr: usize, count: usize) SyscallError!usize {
    const Iovec = extern struct {
        base: usize,
        len: usize,
    };

    const MAX_WRITEV_BYTES: usize = 16 * 1024 * 1024;

    if (count == 0) return 0;
    if (count > 1024) return error.EINVAL;

    // Copy iovecs from user
    const kvecs = heap.allocator().alloc(Iovec, count) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kvecs);

    const uptr = UserPtr.from(bvec_ptr);
    _ = uptr.copyToKernel(std.mem.sliceAsBytes(kvecs)) catch return error.EFAULT;

    var total_written: usize = 0;
    var total_len: usize = 0;

    // Acquire FD lock once for the entire vector operation
    // This ensures output from other threads doesn't interleave between vectors
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd) orelse return error.EBADF;
    const fd_obj = table.get(fd_u32) orelse {
        // Should have been checked by sys_write logically, but here we need the object for locking
        // However, sys_write checks it internally. We need it here to lock.
        // Actually, we should check invalid FD here before loop.
        return error.EBADF;
    };

    // Check if writable
    if (!fd_obj.isWritable()) {
        return error.EBADF;
    }

    const held = fd_obj.lock.acquire();
    defer held.release();

    for (kvecs) |vec| {
        if (vec.len == 0) continue;
        const new_total = @addWithOverflow(total_len, vec.len);
        if (new_total[1] != 0 or new_total[0] > MAX_WRITEV_BYTES) {
            return error.EINVAL;
        }
        total_len = new_total[0];
    }

    for (kvecs) |vec| {
        if (vec.len == 0) continue;

        // Perform write using our locked helper, handling chunks if needed
        var offset: usize = 0;
        while (offset < vec.len) {
            // Cap to avoid huge allocations in perform_write_locked
            const remaining = vec.len - offset;
            const chunk_len = @min(remaining, 64 * 1024);

            // Check for pointer arithmetic overflow
            const base_offset = @addWithOverflow(vec.base, offset);
            if (base_offset[1] != 0) {
                // Pointer overflow - invalid iovec
                if (total_written > 0) return total_written;
                return error.EFAULT;
            }
            const current_base = base_offset[0];

            const res = perform_write_locked(fd_obj, current_base, chunk_len) catch |err| {
                if (total_written > 0) return total_written;
                return err;
            };

            // Check for accumulation overflow
            const new_total = @addWithOverflow(total_written, res);
            if (new_total[1] != 0) {
                // Overflow - return what we have so far
                return total_written;
            }
            total_written = new_total[0];
            offset += res;

            // If partial write occurred (less than requested for this chunk),
            // stop and return what we have
            if (res < chunk_len) {
                return total_written;
            }
        }
    }

    return total_written;
}

/// Helper: Allocates buffer, copies from user, and calls do_write_locked.
/// Caller must hold fd.lock.
fn perform_write_locked(fd: *FileDescriptor, buf_ptr: usize, count: usize) SyscallError!usize {
    if (count == 0) return 0;

    // Cap write size
    const max_write_size = 64 * 1024;
    const write_size = @min(count, max_write_size);

    if (!isValidUserAccess(buf_ptr, write_size, AccessMode.Read)) {
        return error.EFAULT;
    }

    const kbuf = heap.allocator().alloc(u8, write_size) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    // Copy from user to kernel
    const uptr = UserPtr.from(buf_ptr);
    _ = uptr.copyToKernel(kbuf) catch return error.EFAULT;

    const bytes_written = do_write_locked(fd, kbuf);
    return error_helpers.mapWriteError(bytes_written);
}

/// Helper: Allocates buffer, reads from device, and copies to user.
/// Caller must hold fd.lock.
fn perform_read_locked(fd: *FileDescriptor, buf_ptr: usize, count: usize) SyscallError!usize {
    if (count == 0) return 0;

    const max_read_size = 64 * 1024;
    const read_size = @min(count, max_read_size);

    if (!isValidUserAccess(buf_ptr, read_size, AccessMode.Write)) {
        return error.EFAULT;
    }

    const kbuf = heap.allocator().alloc(u8, read_size) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    const bytes_read = do_read_locked(fd, kbuf);
    const valid_read = try error_helpers.mapReadError(bytes_read);

    const uptr = UserPtr.from(buf_ptr);
    _ = uptr.copyFromKernel(kbuf[0..valid_read]) catch return error.EFAULT;

    return valid_read;
}

/// sys_ioctl (16) - Control device
///
/// MVP: Returns -ENOTTY (inappropriate ioctl for device)
/// This is sufficient for musl isatty() checks.
pub fn sys_ioctl(fd: usize, cmd: usize, arg: usize) SyscallError!usize {
    _ = fd;
    _ = cmd;
    _ = arg;
    return error.ENOTTY;
}

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
        // Wait, fd.ops.stat signature is:
        // stat: ?*const fn (fd: *FileDescriptor, stat_buf: *anyopaque) isize,
        // The stat_buf arg usually expects a kernel pointer to fill.

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
    const cwd_len = proc.cwd_len;

    if (size < cwd_len + 1) {
        return error.ERANGE;
    }

    if (!isValidUserAccess(buf_ptr, size, AccessMode.Write)) {
        return error.EFAULT;
    }

    const uptr = UserPtr.from(buf_ptr);

    // Copy path
    _ = uptr.copyFromKernel(proc.cwd[0..cwd_len]) catch return error.EFAULT;

    // Null terminate
    uptr.offset(cwd_len).writeValue(@as(u8, 0)) catch return error.EFAULT;

    return cwd_len + 1; // Return length including null? Linux returns length of string including null.
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
        proc.cwd[0] = '/';
        proc.cwd_len = 1;
        return 0;
    }

    return error.ENOENT;
}

/// sys_mkdir (83) - Create directory
pub fn sys_mkdir(path_ptr: usize, mode: usize) SyscallError!usize {
    _ = path_ptr;
    _ = mode;
    return error.EROFS; // Read-only filesystem
}

/// sys_fcntl (72) - File control
pub fn sys_fcntl(fd_num: usize, cmd: usize, arg: usize) SyscallError!usize {
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    // F_DUPFD (0)
    if (cmd == 0) {
        // Fix potential panic if arg > u32.max (DoS)
        if (arg > std.math.maxInt(u32)) return error.EINVAL;
        const min_fd: u32 = @truncate(arg);

        if (min_fd >= fd_mod.MAX_FDS) return error.EINVAL;

        // Find lowest available FD >= min_fd
        // For now, allocFdNum checks from 0.
        // We need to loop manually.
        var i: u32 = min_fd;
        var found_fd: ?u32 = null;
        while (i < fd_mod.MAX_FDS) : (i += 1) {
            if (table.get(i) == null) {
                found_fd = i;
                break;
            }
        }
        if (found_fd) |new_fd_num| {
            fd.ref();
            table.install(new_fd_num, fd);
            return new_fd_num;
        } else {
            return error.EMFILE;
        }
    }

    // F_GETFD (1)
    if (cmd == 1) {
        // Return flags (FD_CLOEXEC)
        // We don't track FD_CLOEXEC in flags yet (it's separate from O_ flags).
        return 0;
    }

    // F_SETFD (2)
    if (cmd == 2) {
        // Set flags
        return 0;
    }

    // F_GETFL (3)
    if (cmd == 3) {
        return fd.flags;
    }

    // F_SETFL (4)
    if (cmd == 4) {
        // Modify flags (only O_APPEND, O_ASYNC, O_DIRECT, O_NOATIME, O_NONBLOCK)
        const new_flags = @as(u32, @truncate(arg));
        // We only care about O_NONBLOCK for now
        if ((new_flags & fd_mod.O_NONBLOCK) != 0) {
            fd.flags |= fd_mod.O_NONBLOCK;
        } else {
            fd.flags &= ~fd_mod.O_NONBLOCK;
        }
        return 0;
    }

    return error.EINVAL;
}

// =============================================================================
// Positional I/O
// =============================================================================

/// sys_pread64 (17) - Read from file at offset
///
/// Reads from file at specified offset without modifying file position.
/// Atomic with respect to other pread/pwrite operations.
pub fn sys_pread64(fd_num: usize, buf_ptr: usize, count: usize, offset: usize) SyscallError!usize {
    if (count == 0) {
        return 0;
    }

    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    if (!fd.isReadable()) {
        return error.EBADF;
    }

    if (fd.ops.read == null) {
        return error.ENOSYS;
    }

    const seek_fn = fd.ops.seek orelse return error.ESPIPE;

    const offset_i64 = std.math.cast(i64, offset) orelse return error.EFBIG;
    const original_pos = std.math.cast(i64, fd.position) orelse return error.EFBIG;

    const held = fd.lock.acquire();
    defer held.release();

    try mapSeekResult(seek_fn(fd, offset_i64, 0));

    var total_read: usize = 0;
    while (total_read < count) {
        const remaining = count - total_read;
        const chunk_len = @min(remaining, 64 * 1024);

        const base_offset = @addWithOverflow(buf_ptr, total_read);
        if (base_offset[1] != 0) {
            _ = seek_fn(fd, original_pos, 0);
            if (total_read > 0) return total_read;
            return error.EFAULT;
        }

        const res = perform_read_locked(fd, base_offset[0], chunk_len) catch |err| {
            _ = seek_fn(fd, original_pos, 0);
            if (total_read > 0) return total_read;
            return err;
        };

        const new_total = @addWithOverflow(total_read, res);
        if (new_total[1] != 0) {
            _ = seek_fn(fd, original_pos, 0);
            return total_read;
        }
        total_read = new_total[0];

        if (res == 0 or res < chunk_len) {
            break;
        }
    }

    if (seek_fn(fd, original_pos, 0) < 0 and total_read == 0) {
        return error.EIO;
    }

    return total_read;
}

/// sys_pwrite64 (18) - Write to file at offset
///
/// Writes to file at specified offset without modifying file position.
/// Atomic with respect to other pread/pwrite operations.
pub fn sys_pwrite64(fd_num: usize, buf_ptr: usize, count: usize, offset: usize) SyscallError!usize {
    if (count == 0) {
        return 0;
    }

    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    if (!fd.isWritable()) {
        return error.EBADF;
    }

    if (fd.ops.write == null) {
        return error.ENOSYS;
    }

    const seek_fn = fd.ops.seek orelse return error.ESPIPE;

    const offset_i64 = std.math.cast(i64, offset) orelse return error.EFBIG;
    const original_pos = std.math.cast(i64, fd.position) orelse return error.EFBIG;

    const held = fd.lock.acquire();
    defer held.release();

    try mapSeekResult(seek_fn(fd, offset_i64, 0));

    var total_written: usize = 0;
    while (total_written < count) {
        const remaining = count - total_written;
        const chunk_len = @min(remaining, 64 * 1024);

        const base_offset = @addWithOverflow(buf_ptr, total_written);
        if (base_offset[1] != 0) {
            _ = seek_fn(fd, original_pos, 0);
            if (total_written > 0) return total_written;
            return error.EFAULT;
        }

        const res = perform_write_locked(fd, base_offset[0], chunk_len) catch |err| {
            _ = seek_fn(fd, original_pos, 0);
            if (total_written > 0) return total_written;
            return err;
        };

        const new_total = @addWithOverflow(total_written, res);
        if (new_total[1] != 0) {
            _ = seek_fn(fd, original_pos, 0);
            return total_written;
        }
        total_written = new_total[0];

        if (res < chunk_len) {
            break;
        }
    }

    if (seek_fn(fd, original_pos, 0) < 0 and total_written == 0) {
        return error.EIO;
    }

    return total_written;
}

/// sys_readv (19) - Read data into multiple buffers
///
/// Scatter read: reads data into multiple buffers (iovec array).
/// Commonly used by libc for efficient buffered I/O.
pub fn sys_readv(fd_num: usize, iov_ptr: usize, iovcnt: usize) SyscallError!usize {
    const Iovec = extern struct {
        base: usize,
        len: usize,
    };

    const MAX_READV_BYTES: usize = 16 * 1024 * 1024;

    if (iovcnt == 0) return 0;
    if (iovcnt > 1024) return error.EINVAL;

    const kvecs = heap.allocator().alloc(Iovec, iovcnt) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kvecs);

    const uptr = UserPtr.from(iov_ptr);
    _ = uptr.copyToKernel(std.mem.sliceAsBytes(kvecs)) catch return error.EFAULT;

    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd_obj = table.get(fd_u32) orelse return error.EBADF;

    if (!fd_obj.isReadable()) {
        return error.EBADF;
    }
    if (fd_obj.ops.read == null) {
        return error.ENOSYS;
    }

    var total_len: usize = 0;
    for (kvecs) |vec| {
        if (vec.len == 0) continue;
        const new_total = @addWithOverflow(total_len, vec.len);
        if (new_total[1] != 0 or new_total[0] > MAX_READV_BYTES) {
            return error.EINVAL;
        }
        total_len = new_total[0];
    }

    const held = fd_obj.lock.acquire();
    defer held.release();

    var total_read: usize = 0;

    for (kvecs) |vec| {
        if (vec.len == 0) continue;

        var offset: usize = 0;
        while (offset < vec.len) {
            const remaining = vec.len - offset;
            const chunk_len = @min(remaining, 64 * 1024);

            const base_offset = @addWithOverflow(vec.base, offset);
            if (base_offset[1] != 0) {
                if (total_read > 0) return total_read;
                return error.EFAULT;
            }
            const current_base = base_offset[0];

            const res = perform_read_locked(fd_obj, current_base, chunk_len) catch |err| {
                if (total_read > 0) return total_read;
                return err;
            };

            const new_total = @addWithOverflow(total_read, res);
            if (new_total[1] != 0) {
                return total_read;
            }
            total_read = new_total[0];
            offset += res;

            if (res == 0 or res < chunk_len) {
                return total_read;
            }
        }
    }

    return total_read;
}

// =============================================================================
// Filesystem Operations (Stubs)
// =============================================================================

/// sys_fsync (74) - Synchronize file to storage
///
/// MVP: Stub - always succeeds (no persistent storage)
pub fn sys_fsync(fd_num: usize) SyscallError!usize {
    _ = fd_num;
    return 0;
}

/// sys_fdatasync (75) - Synchronize file data to storage
///
/// MVP: Stub - always succeeds (no persistent storage)
pub fn sys_fdatasync(fd_num: usize) SyscallError!usize {
    _ = fd_num;
    return 0;
}

/// sys_truncate (76) - Truncate file to length
///
/// Truncation is currently only supported for SFS-backed files.
pub fn sys_truncate(path_ptr: usize, length: usize) SyscallError!usize {
    const path_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(path_buf);

    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (path.len == 0) return error.ENOENT;

    const fd = fs.vfs.Vfs.open(path, fd_mod.O_WRONLY) catch |err| {
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
    defer {
        if (fd.ops.close) |close_fn| {
            _ = close_fn(fd);
        }
        heap.allocator().destroy(fd);
    }

    if (!fd.isWritable()) {
        return error.EBADF;
    }
    if (fd.ops.seek == null) {
        return error.ESPIPE;
    }

    fs.sfs.truncateFd(fd, length) catch |err| {
        return switch (err) {
            error.NotSfs => error.EROFS,
            error.TooLarge => error.EFBIG,
            error.IOError => error.EIO,
        };
    };

    return 0;
}

/// sys_ftruncate (77) - Truncate file by fd to length
///
/// Truncation is currently only supported for SFS-backed files.
pub fn sys_ftruncate(fd_num: usize, length: usize) SyscallError!usize {
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    if (!fd.isWritable()) {
        return error.EBADF;
    }
    if (fd.ops.seek == null) {
        return error.ESPIPE;
    }

    fs.sfs.truncateFd(fd, length) catch |err| {
        return switch (err) {
            error.NotSfs => error.EROFS,
            error.TooLarge => error.EFBIG,
            error.IOError => error.EIO,
        };
    };

    return 0;
}

/// sys_getdents (78) - Get directory entries (legacy)
///
/// MVP: Returns ENOSYS - use getdents64 instead
pub fn sys_getdents(fd_num: usize, dirp: usize, count: usize) SyscallError!usize {
    _ = fd_num;
    _ = dirp;
    _ = count;
    return error.ENOSYS;
}

/// sys_fchdir (81) - Change working directory by fd
///
pub fn sys_fchdir(fd_num: usize) SyscallError!usize {
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    if (fd.ops != &fd_mod.dir_ops) {
        return error.ENOTDIR;
    }

    const initrd_tag_ptr: ?*anyopaque = @ptrCast(@constCast(&fd_mod.initrd_dir_tag));
    const devfs_tag_ptr: ?*anyopaque = @ptrCast(@constCast(&fd_mod.devfs_dir_tag));
    const proc = base.getCurrentProcess();

    if (fd.private_data == devfs_tag_ptr) {
        proc.cwd[0] = '/';
        proc.cwd[1] = 'd';
        proc.cwd[2] = 'e';
        proc.cwd[3] = 'v';
        proc.cwd_len = 4;
        return 0;
    }

    if (fd.private_data == null or fd.private_data == initrd_tag_ptr) {
        proc.cwd[0] = '/';
        proc.cwd_len = 1;
        return 0;
    }

    return error.ENOTDIR;
}

/// sys_rename (82) - Rename a file
///
/// MVP: Stub - returns EROFS (read-only filesystem)
pub fn sys_rename(oldpath_ptr: usize, newpath_ptr: usize) SyscallError!usize {
    _ = oldpath_ptr;
    _ = newpath_ptr;
    return error.EROFS;
}

/// sys_rmdir (84) - Remove a directory
///
/// MVP: Stub - returns EROFS (read-only filesystem)
pub fn sys_rmdir(path_ptr: usize) SyscallError!usize {
    _ = path_ptr;
    return error.EROFS;
}

/// sys_link (86) - Create a hard link
///
/// MVP: Stub - returns EROFS (read-only filesystem)
pub fn sys_link(oldpath_ptr: usize, newpath_ptr: usize) SyscallError!usize {
    _ = oldpath_ptr;
    _ = newpath_ptr;
    return error.EROFS;
}

// sys_unlink is implemented in fs_handlers.zig

/// sys_symlink (88) - Create a symbolic link
///
/// MVP: Stub - returns EROFS (read-only filesystem)
pub fn sys_symlink(target_ptr: usize, linkpath_ptr: usize) SyscallError!usize {
    _ = target_ptr;
    _ = linkpath_ptr;
    return error.EROFS;
}

/// sys_readlink (89) - Read value of symbolic link
///
/// MVP: Stub - returns EINVAL (no symlinks in initrd)
pub fn sys_readlink(path_ptr: usize, buf_ptr: usize, bufsize: usize) SyscallError!usize {
    _ = path_ptr;
    _ = buf_ptr;
    _ = bufsize;
    return error.EINVAL;
}

/// sys_chmod (90) - Change file mode
///
/// MVP: Stub - returns EROFS (read-only filesystem)
pub fn sys_chmod(path_ptr: usize, mode: usize) SyscallError!usize {
    _ = path_ptr;
    _ = mode;
    return error.EROFS;
}

/// sys_fchmod (91) - Change file mode by fd
///
/// MVP: Stub - returns EROFS (read-only filesystem)
pub fn sys_fchmod(fd_num: usize, mode: usize) SyscallError!usize {
    _ = fd_num;
    _ = mode;
    return error.EROFS;
}

/// sys_chown (92) - Change file owner
///
/// MVP: Stub - returns EROFS (read-only filesystem)
pub fn sys_chown(path_ptr: usize, uid: usize, gid: usize) SyscallError!usize {
    _ = path_ptr;
    _ = uid;
    _ = gid;
    return error.EROFS;
}

/// sys_fchown (93) - Change file owner by fd
///
/// MVP: Stub - returns EROFS (read-only filesystem)
pub fn sys_fchown(fd_num: usize, uid: usize, gid: usize) SyscallError!usize {
    _ = fd_num;
    _ = uid;
    _ = gid;
    return error.EROFS;
}

/// sys_lchown (94) - Change symlink owner
///
/// MVP: Stub - returns EROFS (read-only filesystem)
pub fn sys_lchown(path_ptr: usize, uid: usize, gid: usize) SyscallError!usize {
    _ = path_ptr;
    _ = uid;
    _ = gid;
    return error.EROFS;
}
