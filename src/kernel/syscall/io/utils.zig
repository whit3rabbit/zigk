const std = @import("std");
const base = @import("base.zig");
const heap = @import("heap");
const error_helpers = @import("error_helpers.zig");
const hal = @import("hal");

const SyscallError = base.SyscallError;
const FileDescriptor = base.FileDescriptor;
const UserPtr = base.UserPtr;
const isValidUserAccess = base.isValidUserAccess;
const AccessMode = base.AccessMode;

/// Safe cast for file descriptor numbers from user space
pub fn safeFdCast(fd_num: usize) ?u32 {
    return std.math.cast(u32, fd_num);
}

pub fn mapSeekResult(result: isize) SyscallError!void {
    if (result >= 0) return;

    const errno_val: i32 = @intCast(-result);
    return switch (errno_val) {
        9 => error.EBADF,
        22 => error.EINVAL,
        29 => error.ESPIPE,
        else => error.EINVAL,
    };
}

/// Helper for locked write operations
pub fn do_write_locked(fd: *FileDescriptor, kbuf: []const u8) isize {
    const write_fn = fd.ops.write orelse return -5; // EIO
    return write_fn(fd, kbuf);
}

/// Helper for locked read operations
pub fn do_read_locked(fd: *FileDescriptor, kbuf: []u8) isize {
    const read_fn = fd.ops.read orelse return -5; // EIO
    return read_fn(fd, kbuf);
}

/// Helper: Allocates buffer, copies from user, and calls do_write_locked.
/// Caller must hold fd.lock.
pub fn perform_write_locked(fd: *FileDescriptor, buf_ptr: usize, count: usize) SyscallError!usize {
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
pub fn perform_read_locked(fd: *FileDescriptor, buf_ptr: usize, count: usize) SyscallError!usize {
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
