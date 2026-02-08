const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const heap = @import("heap");
const error_helpers = @import("error_helpers.zig");
const utils = @import("utils.zig");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;
const isValidUserAccess = base.isValidUserAccess;
const AccessMode = base.AccessMode;

const safeFdCast = utils.safeFdCast;
const do_read_locked = utils.do_read_locked;
const do_write_locked = utils.do_write_locked;
const perform_write_locked = utils.perform_write_locked;
const perform_read_locked = utils.perform_read_locked;

/// Iovec structure for vectored I/O operations (scatter-gather)
const Iovec = extern struct {
    base: usize,
    len: usize,
};

/// sys_read (0) - Read from file descriptor
///
/// Reads up to count bytes from fd into buf.
/// Uses FD table to dispatch to appropriate device read operation.
///
/// DESIGN NOTE: sys_read intentionally does NOT acquire fd.lock.
/// This matches Linux behavior where concurrent read() calls can interleave.
/// File position atomicity is handled by the underlying device driver or
/// callers should use pread64() for atomic positioned reads.
/// In contrast, sys_write() acquires the lock to ensure output atomicity.
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
    console.debug("SYSCALL: sys_write fd={} count={}", .{ fd_num, count });
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

    console.debug("SYSCALL: sys_write copying from user", .{});
    // Copy from user to kernel
    const uptr = UserPtr.from(buf_ptr);
    _ = uptr.copyToKernel(kbuf) catch return error.EFAULT;

    console.debug("SYSCALL: sys_write acquiring fd.lock", .{});
    // Write from kernel buffer (legacy isize return from device ops)
    // Acquire lock for atomicity
    const held = fd.lock.acquire();
    defer held.release();

    console.debug("SYSCALL: sys_write calling do_write_locked", .{});
    const bytes_written = do_write_locked(fd, kbuf);

    console.debug("SYSCALL: sys_write complete, bytes={}", .{bytes_written});
    return error_helpers.mapDeviceError(bytes_written);
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

/// sys_readv (19) - Read data into multiple buffers
///
/// Args:
///   fd: File descriptor
///   bvec_ptr: Pointer to iovec array
///   count: Number of iovec structs
///
/// Returns: Total bytes read or error
pub fn sys_readv(fd: usize, bvec_ptr: usize, count: usize) SyscallError!usize {
    const MAX_READV_BYTES: usize = 16 * 1024 * 1024;

    if (count == 0) return 0;
    if (count > 1024) return error.EINVAL;

    // Copy iovecs from user
    const kvecs = heap.allocator().alloc(Iovec, count) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kvecs);

    const uptr = UserPtr.from(bvec_ptr);
    _ = uptr.copyToKernel(std.mem.sliceAsBytes(kvecs)) catch return error.EFAULT;

    var total_read: usize = 0;
    var total_len: usize = 0;

    // Acquire FD lock once for the entire vector operation
    // This ensures data from other threads doesn't interleave between vectors
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd) orelse return error.EBADF;
    const fd_obj = table.get(fd_u32) orelse {
        return error.EBADF;
    };

    // Check if readable
    if (!fd_obj.isReadable()) {
        return error.EBADF;
    }

    // Check if read operation is supported
    if (fd_obj.ops.read == null) {
        return error.EBADF;
    }

    const held = fd_obj.lock.acquire();
    defer held.release();

    // Validate total length doesn't overflow
    for (kvecs) |vec| {
        if (vec.len == 0) continue;
        const new_total = @addWithOverflow(total_len, vec.len);
        if (new_total[1] != 0 or new_total[0] > MAX_READV_BYTES) {
            return error.EINVAL;
        }
        total_len = new_total[0];
    }

    // Process each iovec
    for (kvecs) |vec| {
        if (vec.len == 0) continue;

        // Perform read using our locked helper, handling chunks if needed
        var offset: usize = 0;
        while (offset < vec.len) {
            // Cap to avoid huge allocations in perform_read_locked
            const remaining = vec.len - offset;
            const chunk_len = @min(remaining, 64 * 1024);

            // Check for pointer arithmetic overflow
            const base_offset = @addWithOverflow(vec.base, offset);
            if (base_offset[1] != 0) {
                // Pointer overflow - invalid iovec
                if (total_read > 0) return total_read;
                return error.EFAULT;
            }
            const current_base = base_offset[0];

            const res = perform_read_locked(fd_obj, current_base, chunk_len) catch |err| {
                if (total_read > 0) return total_read;
                return err;
            };

            // Check for accumulation overflow
            const new_total = @addWithOverflow(total_read, res);
            if (new_total[1] != 0) {
                // Overflow - return what we have so far
                return total_read;
            }
            total_read = new_total[0];
            offset += res;

            // If partial read occurred (less than requested for this chunk),
            // stop and return what we have (EOF or would block)
            if (res < chunk_len) {
                return total_read;
            }
        }
    }

    return total_read;
}

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
        return error.ESPIPE; // Pre-read usually not supported on streams (like stdin) unless seekable?
        // Actually, pread is for seekable files.
        // If device doesn't support seeking, it might fail.
        // But pread logic is: save pos, seek, read, restore pos (if implemented naively)
        // OR better: use device specific pread op.
        // Currently our FileDescriptor ops don't support pread.
        // So we must emulate it via seek/read/seek IF lock held.
    }

    // Check if seekable
    if (fd.ops.seek == null) {
        return error.ESPIPE;
    }

    // Acquire lock to ensure atomicity of seek+read+seek
    const held = fd.lock.acquire();
    defer held.release();

    // Save current position
    const old_pos = fd.position;

    // Seek to new offset
    // Note: fd.position is generic kernel tracking. Device might need explicit seek call?
    // Our seek implementation updates fd.position AND calls ops.seek.
    // We should do that.

    const seek_fn = fd.ops.seek.?;

    // 1. Seek to target
    const res1 = seek_fn(fd, @intCast(offset), 0); // SEEK_SET
    if (res1 < 0) return error.EINVAL; // Or map error
    fd.position = @intCast(res1);

    // 2. Perform Read
    // We can use a helper that doesn't re-acquire lock
    // sys_read acquires lock? No, sys_read does NOT acquire lock for the read call itself
    // because `read_fn` is expected to handle it or be fine?
    // Wait, sys_read does NOT acquire `fd.lock`.
    // But `do_read_locked` logic exists.
    // If `read_fn` is not thread safe, we rely on it?
    // In `sys_read`: `const read_fn = fd.ops.read; ... bytes_read = read_fn(fd, kbuf);`
    // It doesn't lock.
    // `sys_write` DOES lock.
    // Reading usually implies shared access or handled by driver.
    // But changing position is critical.
    // Since we hold the lock here, no one else can change position via pread or write.
    // But sys_read might run concurrently?
    // If sys_read relies on fd.position, then we have a race if sys_read doesn't lock.
    // We should probably verify if sys_read needs locking.
    // For now, assuming holding lock protects `fd.position`.

    // Perform read
    // We need to alloc buffer etc.
    // Reuse perform_read_locked helper?
    // Yes, use utils.perform_read_locked which allocates and reads.
    const bytes_read = utils.perform_read_locked(fd, buf_ptr, count) catch |err| {
        // Restore position before error
        _ = seek_fn(fd, @intCast(old_pos), 0);
        fd.position = old_pos;
        return err;
    };

    // 3. Restore position
    const res2 = seek_fn(fd, @intCast(old_pos), 0);
    if (res2 < 0) {
        // Critical error: failed to restore position.
        // We can't do much but warn.
        console.err("sys_pread64: failed to restore position!", .{});
    } else {
        fd.position = @intCast(res2);
    }

    return bytes_read;
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
        return error.ESPIPE;
    }

    // Check if seekable
    if (fd.ops.seek == null) {
        return error.ESPIPE;
    }

    // Acquire lock to ensure atomicity of seek+write+seek
    const held = fd.lock.acquire();
    defer held.release();

    // Save current position
    const old_pos = fd.position;

    const seek_fn = fd.ops.seek.?;

    // 1. Seek to target offset
    const res1 = seek_fn(fd, @intCast(offset), 0); // SEEK_SET
    if (res1 < 0) return error.EINVAL;
    fd.position = @intCast(res1);

    // 2. Perform Write
    const bytes_written = perform_write_locked(fd, buf_ptr, count) catch |err| {
        // Restore position before error
        _ = seek_fn(fd, @intCast(old_pos), 0);
        fd.position = old_pos;
        return err;
    };

    // 3. Restore position
    const res2 = seek_fn(fd, @intCast(old_pos), 0);
    if (res2 < 0) {
        // Critical error: failed to restore position.
        console.err("sys_pwrite64: failed to restore position!", .{});
    } else {
        fd.position = @intCast(res2);
    }

    return bytes_written;
}
