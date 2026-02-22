const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const heap = @import("heap");
const error_helpers = @import("error_helpers.zig");
const utils = @import("utils.zig");
const inotify = @import("inotify.zig");
const page_cache = @import("page_cache");

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

/// RWF flags for preadv2/pwritev2 (per-call I/O behavior modifiers)
const RWF_HIPRI: u32 = 0x00000001; // High-priority I/O (requires polling infrastructure)
const RWF_DSYNC: u32 = 0x00000002; // Per-write equivalent of O_DSYNC
const RWF_SYNC: u32 = 0x00000004; // Per-write equivalent of O_SYNC
const RWF_NOWAIT: u32 = 0x00000008; // Non-blocking I/O (fail with EAGAIN if would block)
const RWF_APPEND: u32 = 0x00000010; // Per-write equivalent of O_APPEND
const RWF_SUPPORTED: u32 = RWF_HIPRI | RWF_DSYNC | RWF_SYNC | RWF_NOWAIT | RWF_APPEND;

/// Maximum sizes for vectored I/O operations
const MAX_READV_BYTES: usize = 16 * 1024 * 1024;
const MAX_WRITEV_BYTES: usize = 16 * 1024 * 1024;
const MAX_IOVEC_COUNT: usize = 1024;

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
    // Acquire lock for atomicity; release BEFORE inotify notification to avoid
    // lock ordering issues (inotify acquires global_instances_lock)
    const held = fd.lock.acquire();

    const bytes_written = do_write_locked(fd, kbuf);
    held.release();

    // Fire inotify IN_MODIFY AFTER lock is released
    if (bytes_written > 0) {
        inotify.notifyFromFd(fd, 0x00000002); // IN_MODIFY
    }

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
    if (count == 0) return 0;
    if (count > MAX_IOVEC_COUNT) return error.EINVAL;

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

    for (kvecs) |vec| {
        if (vec.len == 0) continue;
        const new_total = @addWithOverflow(total_len, vec.len);
        if (new_total[1] != 0 or new_total[0] > MAX_WRITEV_BYTES) {
            held.release();
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
                // Pointer overflow - invalid iovec; release lock, fire notification if any written
                held.release();
                if (total_written > 0) {
                    inotify.notifyFromFd(fd_obj, 0x00000002); // IN_MODIFY
                    return total_written;
                }
                return error.EFAULT;
            }
            const current_base = base_offset[0];

            const res = perform_write_locked(fd_obj, current_base, chunk_len) catch |err| {
                held.release();
                if (total_written > 0) {
                    inotify.notifyFromFd(fd_obj, 0x00000002); // IN_MODIFY
                    return total_written;
                }
                return err;
            };

            // Check for accumulation overflow
            const new_total = @addWithOverflow(total_written, res);
            if (new_total[1] != 0) {
                // Overflow - return what we have so far
                held.release();
                if (total_written > 0) inotify.notifyFromFd(fd_obj, 0x00000002); // IN_MODIFY
                return total_written;
            }
            total_written = new_total[0];
            offset += res;

            // If partial write occurred (less than requested for this chunk),
            // stop and return what we have
            if (res < chunk_len) {
                held.release();
                if (total_written > 0) inotify.notifyFromFd(fd_obj, 0x00000002); // IN_MODIFY
                return total_written;
            }
        }
    }

    // Release lock BEFORE inotify notification
    held.release();
    if (total_written > 0) inotify.notifyFromFd(fd_obj, 0x00000002); // IN_MODIFY
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
    if (count == 0) return 0;
    if (count > MAX_IOVEC_COUNT) return error.EINVAL;

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
    // Note: no defer - we release manually BEFORE inotify notification
    const held = fd.lock.acquire();

    // Save current position
    const old_pos = fd.position;

    const seek_fn = fd.ops.seek.?;

    // 1. Seek to target offset
    const res1 = seek_fn(fd, @intCast(offset), 0); // SEEK_SET
    if (res1 < 0) {
        held.release();
        return error.EINVAL;
    }
    fd.position = @intCast(res1);

    // 2. Perform Write
    const bytes_written = perform_write_locked(fd, buf_ptr, count) catch |err| {
        // Restore position before error
        _ = seek_fn(fd, @intCast(old_pos), 0);
        fd.position = old_pos;
        held.release();
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

    // Release lock BEFORE inotify notification
    held.release();
    if (bytes_written > 0) inotify.notifyFromFd(fd, 0x00000002); // IN_MODIFY
    return bytes_written;
}

/// sys_preadv (295) - Read into multiple buffers at offset
///
/// Combines vectored I/O with positional access.
/// Does not modify file position.
pub fn sys_preadv(fd_num: usize, bvec_ptr: usize, count: usize, offset: usize) SyscallError!usize {
    if (count == 0) return 0;
    if (count > MAX_IOVEC_COUNT) return error.EINVAL;

    // Copy iovecs from user
    const kvecs = heap.allocator().alloc(Iovec, count) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kvecs);

    const uptr = UserPtr.from(bvec_ptr);
    _ = uptr.copyToKernel(std.mem.sliceAsBytes(kvecs)) catch return error.EFAULT;

    var total_len: usize = 0;

    // Validate total length doesn't overflow
    for (kvecs) |vec| {
        if (vec.len == 0) continue;
        const new_total = @addWithOverflow(total_len, vec.len);
        if (new_total[1] != 0 or new_total[0] > MAX_READV_BYTES) {
            return error.EINVAL;
        }
        total_len = new_total[0];
    }

    // Get FD and validate
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    if (!fd.isReadable()) {
        return error.EBADF;
    }

    if (fd.ops.read == null) {
        return error.ESPIPE;
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

    const seek_fn = fd.ops.seek.?;

    // 1. Seek to target offset
    const res1 = seek_fn(fd, @intCast(offset), 0); // SEEK_SET
    if (res1 < 0) return error.EINVAL;
    fd.position = @intCast(res1);

    // 2. Perform vectored read
    var total_read: usize = 0;

    for (kvecs) |vec| {
        if (vec.len == 0) continue;

        var vec_offset: usize = 0;
        while (vec_offset < vec.len) {
            const remaining = vec.len - vec_offset;
            const chunk_len = @min(remaining, 64 * 1024);

            const base_offset = @addWithOverflow(vec.base, vec_offset);
            if (base_offset[1] != 0) {
                // Restore position before error
                _ = seek_fn(fd, @intCast(old_pos), 0);
                fd.position = old_pos;
                if (total_read > 0) return total_read;
                return error.EFAULT;
            }

            const res = perform_read_locked(fd, base_offset[0], chunk_len) catch |err| {
                // Restore position before error
                _ = seek_fn(fd, @intCast(old_pos), 0);
                fd.position = old_pos;
                if (total_read > 0) return total_read;
                return err;
            };

            const new_total = @addWithOverflow(total_read, res);
            if (new_total[1] != 0) {
                // Restore position
                _ = seek_fn(fd, @intCast(old_pos), 0);
                fd.position = old_pos;
                return total_read;
            }
            total_read = new_total[0];
            vec_offset += res;

            // Short read: restore position and return
            if (res < chunk_len) {
                _ = seek_fn(fd, @intCast(old_pos), 0);
                fd.position = old_pos;
                return total_read;
            }
        }
    }

    // 3. Restore position
    const res2 = seek_fn(fd, @intCast(old_pos), 0);
    if (res2 < 0) {
        console.err("sys_preadv: failed to restore position!", .{});
    } else {
        fd.position = @intCast(res2);
    }

    return total_read;
}

/// sys_pwritev (296) - Write from multiple buffers at offset
///
/// Combines vectored I/O with positional access.
/// Does not modify file position.
pub fn sys_pwritev(fd_num: usize, bvec_ptr: usize, count: usize, offset: usize) SyscallError!usize {
    if (count == 0) return 0;
    if (count > MAX_IOVEC_COUNT) return error.EINVAL;

    // Copy iovecs from user
    const kvecs = heap.allocator().alloc(Iovec, count) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kvecs);

    const uptr = UserPtr.from(bvec_ptr);
    _ = uptr.copyToKernel(std.mem.sliceAsBytes(kvecs)) catch return error.EFAULT;

    var total_len: usize = 0;

    // Validate total length doesn't overflow
    for (kvecs) |vec| {
        if (vec.len == 0) continue;
        const new_total = @addWithOverflow(total_len, vec.len);
        if (new_total[1] != 0 or new_total[0] > MAX_WRITEV_BYTES) {
            return error.EINVAL;
        }
        total_len = new_total[0];
    }

    // Get FD and validate
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
    // Note: no defer - we release manually BEFORE inotify notification
    const held = fd.lock.acquire();

    // Save current position
    const old_pos = fd.position;

    const seek_fn = fd.ops.seek.?;

    // 1. Seek to target offset
    const res1 = seek_fn(fd, @intCast(offset), 0); // SEEK_SET
    if (res1 < 0) {
        held.release();
        return error.EINVAL;
    }
    fd.position = @intCast(res1);

    // 2. Perform vectored write
    var total_written: usize = 0;

    for (kvecs) |vec| {
        if (vec.len == 0) continue;

        var vec_offset: usize = 0;
        while (vec_offset < vec.len) {
            const remaining = vec.len - vec_offset;
            const chunk_len = @min(remaining, 64 * 1024);

            const base_offset = @addWithOverflow(vec.base, vec_offset);
            if (base_offset[1] != 0) {
                // Restore position before error
                _ = seek_fn(fd, @intCast(old_pos), 0);
                fd.position = old_pos;
                held.release();
                if (total_written > 0) {
                    inotify.notifyFromFd(fd, 0x00000002); // IN_MODIFY
                    return total_written;
                }
                return error.EFAULT;
            }

            const res = perform_write_locked(fd, base_offset[0], chunk_len) catch |err| {
                // Restore position before error
                _ = seek_fn(fd, @intCast(old_pos), 0);
                fd.position = old_pos;
                held.release();
                if (total_written > 0) {
                    inotify.notifyFromFd(fd, 0x00000002); // IN_MODIFY
                    return total_written;
                }
                return err;
            };

            const new_total = @addWithOverflow(total_written, res);
            if (new_total[1] != 0) {
                // Restore position
                _ = seek_fn(fd, @intCast(old_pos), 0);
                fd.position = old_pos;
                held.release();
                if (total_written > 0) inotify.notifyFromFd(fd, 0x00000002); // IN_MODIFY
                return total_written;
            }
            total_written = new_total[0];
            vec_offset += res;

            // Short write: restore position and return
            if (res < chunk_len) {
                _ = seek_fn(fd, @intCast(old_pos), 0);
                fd.position = old_pos;
                held.release();
                if (total_written > 0) inotify.notifyFromFd(fd, 0x00000002); // IN_MODIFY
                return total_written;
            }
        }
    }

    // 3. Restore position
    const res2 = seek_fn(fd, @intCast(old_pos), 0);
    if (res2 < 0) {
        console.err("sys_pwritev: failed to restore position!", .{});
    } else {
        fd.position = @intCast(res2);
    }

    // Release lock BEFORE inotify notification
    held.release();
    if (total_written > 0) inotify.notifyFromFd(fd, 0x00000002); // IN_MODIFY
    return total_written;
}

/// sys_preadv2 (327) - Read into multiple buffers at offset with flags
///
/// Extended version of preadv with per-call RWF_* flags for I/O behavior control.
/// offset=-1 means use current file position (like readv).
pub fn sys_preadv2(fd_num: usize, bvec_ptr: usize, count: usize, offset: usize, flags: usize) SyscallError!usize {
    // Validate flags
    const flags_u32: u32 = @truncate(flags);
    if ((flags_u32 & ~RWF_SUPPORTED) != 0) {
        return error.ENOSYS; // Unknown flags
    }

    // RWF_HIPRI requires polling infrastructure we don't have
    if ((flags_u32 & RWF_HIPRI) != 0) {
        return error.ENOSYS;
    }

    // RWF_NOWAIT means fail if operation would block
    if ((flags_u32 & RWF_NOWAIT) != 0) {
        return error.EAGAIN; // Our I/O is synchronous
    }

    // RWF_APPEND is not valid for reads
    if ((flags_u32 & RWF_APPEND) != 0) {
        return error.EINVAL;
    }

    // RWF_DSYNC and RWF_SYNC accepted but ignored (no write-back cache)

    // Cast offset to i64 to check for -1
    const off_i64: i64 = @bitCast(offset);

    if (off_i64 == -1) {
        // Use current file position (like readv)
        return sys_readv(fd_num, bvec_ptr, count);
    } else {
        // Use specified offset (like preadv)
        return sys_preadv(fd_num, bvec_ptr, count, offset);
    }
}

/// sys_pwritev2 (328) - Write from multiple buffers at offset with flags
///
/// Extended version of pwritev with per-call RWF_* flags for I/O behavior control.
/// offset=-1 means use current file position (like writev).
/// RWF_APPEND only valid with offset=-1, seeks to EOF before writing.
pub fn sys_pwritev2(fd_num: usize, bvec_ptr: usize, count: usize, offset: usize, flags: usize) SyscallError!usize {
    // Validate flags
    const flags_u32: u32 = @truncate(flags);
    if ((flags_u32 & ~RWF_SUPPORTED) != 0) {
        return error.ENOSYS; // Unknown flags
    }

    // RWF_HIPRI requires polling infrastructure we don't have
    if ((flags_u32 & RWF_HIPRI) != 0) {
        return error.ENOSYS;
    }

    // RWF_NOWAIT means fail if operation would block
    if ((flags_u32 & RWF_NOWAIT) != 0) {
        return error.EAGAIN; // Our I/O is synchronous
    }

    // RWF_DSYNC and RWF_SYNC accepted but ignored (no write-back cache)

    // Cast offset to i64 to check for -1
    const off_i64: i64 = @bitCast(offset);

    // RWF_APPEND only valid with offset=-1 (current position mode)
    if ((flags_u32 & RWF_APPEND) != 0 and off_i64 != -1) {
        return error.EINVAL;
    }

    if (off_i64 == -1) {
        if ((flags_u32 & RWF_APPEND) != 0) {
            // Seek to EOF before writing
            // Get FD first
            const table = base.getGlobalFdTable();
            const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
            const fd = table.get(fd_u32) orelse return error.EBADF;

            if (!fd.isWritable()) {
                return error.EBADF;
            }

            if (fd.ops.seek == null) {
                return error.ESPIPE;
            }

            // Seek to end
            const held = fd.lock.acquire();

            const seek_fn = fd.ops.seek.?;
            const end_pos = seek_fn(fd, 0, 2); // SEEK_END
            if (end_pos < 0) {
                held.release();
                return error.EINVAL;
            }
            fd.position = @intCast(end_pos);

            held.release();
            return sys_writev(fd_num, bvec_ptr, count);
        } else {
            // Use current file position (like writev)
            return sys_writev(fd_num, bvec_ptr, count);
        }
    } else {
        // Use specified offset (like pwritev)
        return sys_pwritev(fd_num, bvec_ptr, count, offset);
    }
}

/// sys_sendfile (40) - Transfer data between file descriptors in kernel space
///
/// Efficiently copies data from in_fd to out_fd without userspace buffer.
/// Uses page cache for VFS source files, falls back to heap buffer for non-VFS.
/// offset_ptr: if non-zero, pointer to u64 offset (updated after transfer).
///             if zero, uses in_fd's current position.
pub fn sys_sendfile(out_fd_num: usize, in_fd_num: usize, offset_ptr: usize, count: usize) SyscallError!usize {
    if (count == 0) return 0;

    // Get FDs
    const table = base.getGlobalFdTable();

    const out_fd_u32 = safeFdCast(out_fd_num) orelse return error.EBADF;
    const out_fd = table.get(out_fd_u32) orelse return error.EBADF;

    const in_fd_u32 = safeFdCast(in_fd_num) orelse return error.EBADF;
    const in_fd = table.get(in_fd_u32) orelse return error.EBADF;

    // Validate FDs
    if (!out_fd.isWritable()) return error.EBADF;
    if (!in_fd.isReadable()) return error.EBADF;

    // in_fd must be seekable (no pipes/sockets as source)
    if (in_fd.ops.read == null or in_fd.ops.seek == null) {
        return error.EINVAL;
    }

    // out_fd cannot have O_APPEND flag (conflicting semantics)
    const O_APPEND: u32 = 0x0400; // From fd.zig
    if ((out_fd.flags & O_APPEND) != 0) {
        return error.EINVAL;
    }

    // Handle offset parameter
    var read_offset: u64 = 0;
    var use_offset_ptr = false;

    if (offset_ptr != 0) {
        // Read offset from userspace
        if (!isValidUserAccess(offset_ptr, @sizeOf(u64), AccessMode.Read)) {
            return error.EFAULT;
        }
        const uptr = UserPtr.from(offset_ptr);
        var offset_buf: [8]u8 = undefined;
        _ = uptr.copyToKernel(&offset_buf) catch return error.EFAULT;
        read_offset = std.mem.readInt(u64, &offset_buf, .little);
        use_offset_ptr = true;
    } else {
        // Use in_fd's current position
        read_offset = in_fd.position;
    }

    const in_file_id = in_fd.file_identifier;
    var total_sent: usize = 0;

    if (in_file_id != 0) {
        // Page cache path for VFS source files
        while (total_sent < count) {
            const remaining = count - total_sent;
            const chunk_size = @min(remaining, 4 * 4096); // Up to 4 pages at a time

            const refs = page_cache.getPages(in_file_id, read_offset, chunk_size, in_fd.ops.read.?, in_fd) catch {
                if (total_sent > 0) break;
                return error.ENOMEM;
            };

            if (refs.len == 0) break;

            var chunk_written: usize = 0;
            var should_stop = false;
            for (refs) |ref| {
                if (ref.len == 0) {
                    should_stop = true;
                    break;
                }
                const data = page_cache.getPageData(ref.page);
                const slice = data[ref.offset_in_page .. ref.offset_in_page + ref.len];

                // Write to out_fd
                const out_held = out_fd.lock.acquire();
                const write_fn = out_fd.ops.write orelse {
                    out_held.release();
                    should_stop = true;
                    break;
                };

                const bytes_written_raw = write_fn(out_fd, slice);
                out_held.release();

                if (bytes_written_raw <= 0) {
                    should_stop = true;
                    break;
                }

                const bytes_written: usize = @intCast(bytes_written_raw);

                const new_chunk = @addWithOverflow(chunk_written, bytes_written);
                if (new_chunk[1] != 0) {
                    should_stop = true;
                    break;
                }
                chunk_written = new_chunk[0];

                if (bytes_written < ref.len) {
                    should_stop = true;
                    break;
                }
            }

            page_cache.releasePages(refs);

            if (chunk_written == 0) {
                if (total_sent > 0) break;
                return error.EIO;
            }

            const new_total = @addWithOverflow(total_sent, chunk_written);
            if (new_total[1] != 0) break;
            total_sent = new_total[0];

            const new_offset = @addWithOverflow(read_offset, chunk_written);
            if (new_offset[1] != 0) break;
            read_offset = new_offset[0];

            if (should_stop or chunk_written < chunk_size) break;
        }

        // Update file position for non-offset-ptr path
        if (!use_offset_ptr) {
            const in_held = in_fd.lock.acquire();
            in_fd.position = std.math.add(u64, in_fd.position, @as(u64, @intCast(total_sent))) catch in_fd.position;
            in_held.release();
        }
    } else {
        // Fallback: 64KB heap buffer for non-VFS source files
        const sendfile_buf_size: usize = 64 * 1024;
        const kbuf = heap.allocator().alloc(u8, sendfile_buf_size) catch return error.ENOMEM;
        defer heap.allocator().free(kbuf);

        while (total_sent < count) {
            const remaining = count - total_sent;
            const chunk_size = @min(remaining, sendfile_buf_size);

            const in_held = in_fd.lock.acquire();
            const old_in_pos = in_fd.position;

            const seek_fn = in_fd.ops.seek.?;
            const seek_res = seek_fn(in_fd, @intCast(read_offset), 0);
            if (seek_res < 0) {
                in_held.release();
                if (total_sent > 0) break;
                return error.EINVAL;
            }
            in_fd.position = @intCast(seek_res);

            const read_fn = in_fd.ops.read.?;
            const bytes_read_raw = read_fn(in_fd, kbuf[0..chunk_size]);

            if (!use_offset_ptr) {
                _ = seek_fn(in_fd, @intCast(old_in_pos + @as(u64, @intCast(@max(0, bytes_read_raw)))), 0);
                in_fd.position = old_in_pos + @as(u64, @intCast(@max(0, bytes_read_raw)));
            } else {
                _ = seek_fn(in_fd, @intCast(old_in_pos), 0);
                in_fd.position = old_in_pos;
            }

            in_held.release();

            if (bytes_read_raw <= 0) {
                if (bytes_read_raw == 0) break;
                if (total_sent > 0) break;
                return error.EIO;
            }

            const bytes_read: usize = @intCast(bytes_read_raw);

            const out_held = out_fd.lock.acquire();
            const write_fn = out_fd.ops.write orelse {
                out_held.release();
                if (total_sent > 0) break;
                return error.EBADF;
            };

            const bytes_written_raw = write_fn(out_fd, kbuf[0..bytes_read]);
            out_held.release();

            if (bytes_written_raw <= 0) {
                if (total_sent > 0) break;
                return error.EIO;
            }

            const bytes_written: usize = @intCast(bytes_written_raw);

            const new_total = @addWithOverflow(total_sent, bytes_written);
            if (new_total[1] != 0) break;
            total_sent = new_total[0];

            const new_offset = @addWithOverflow(read_offset, bytes_written);
            if (new_offset[1] != 0) break;
            read_offset = new_offset[0];

            if (bytes_written < bytes_read) break;
            if (bytes_read < chunk_size) break;
        }
    }

    // Write updated offset back to userspace if using offset_ptr
    if (use_offset_ptr and offset_ptr != 0) {
        if (!isValidUserAccess(offset_ptr, @sizeOf(u64), AccessMode.Write)) {
            return total_sent;
        }
        const uptr = UserPtr.from(offset_ptr);
        var offset_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &offset_buf, read_offset, .little);
        _ = uptr.copyFromKernel(&offset_buf) catch {
            return total_sent;
        };
    }

    return total_sent;
}
