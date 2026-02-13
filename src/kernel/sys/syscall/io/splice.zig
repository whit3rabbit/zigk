//! Zero-Copy I/O Syscalls
//!
//! Implements splice, tee, vmsplice, and copy_file_range for kernel-side data transfer.
//! Since zk has no page cache, these use kernel buffer copies (same pragmatic approach
//! as sendfile) rather than true zero-copy page remapping.

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const heap = @import("heap");
const error_helpers = @import("error_helpers.zig");
const utils = @import("utils.zig");
const hal = @import("hal");
const pipe_mod = @import("pipe");

const SyscallError = base.SyscallError;
const FileDescriptor = base.FileDescriptor;
const UserPtr = base.UserPtr;
const isValidUserAccess = base.isValidUserAccess;
const AccessMode = base.AccessMode;
const safeFdCast = utils.safeFdCast;

// Iovec structure for vectored I/O operations (scatter-gather)
const Iovec = extern struct {
    base: usize, // Address of buffer
    len: usize, // Length of buffer in bytes
};

// Splice flags
const SPLICE_F_MOVE: u32 = 1;
const SPLICE_F_NONBLOCK: u32 = 2;
const SPLICE_F_MORE: u32 = 4;
const SPLICE_F_GIFT: u32 = 8;

/// sys_splice (275/76) - Move data between a file and a pipe
///
/// Transfers data between a file descriptor and a pipe without copying to userspace.
/// Exactly one of fd_in or fd_out must be a pipe.
pub fn sys_splice(
    fd_in: usize,
    off_in_ptr: usize,
    fd_out: usize,
    off_out_ptr: usize,
    len: usize,
    flags: usize,
) SyscallError!usize {
    if (len == 0) return 0;

    // Validate flags
    const valid_flags = SPLICE_F_MOVE | SPLICE_F_NONBLOCK | SPLICE_F_MORE | SPLICE_F_GIFT;
    if ((flags & ~valid_flags) != 0) return error.EINVAL;

    // Get FDs
    const table = base.getGlobalFdTable();
    const in_fd_u32 = safeFdCast(fd_in) orelse return error.EBADF;
    const out_fd_u32 = safeFdCast(fd_out) orelse return error.EBADF;

    const in_fd = table.get(in_fd_u32) orelse return error.EBADF;
    const out_fd = table.get(out_fd_u32) orelse return error.EBADF;

    // Check readable/writable
    if (!in_fd.isReadable()) return error.EBADF;
    if (!out_fd.isWritable()) return error.EBADF;

    // Determine which is the pipe
    const in_is_pipe = pipe_mod.isPipe(in_fd);
    const out_is_pipe = pipe_mod.isPipe(out_fd);

    // Exactly one must be a pipe
    if (in_is_pipe == out_is_pipe) {
        // Both pipes or neither is a pipe
        return error.EINVAL;
    }

    if (in_is_pipe) {
        // Pipe to file
        return splicePipeToFile(in_fd, out_fd, off_out_ptr, len);
    } else {
        // File to pipe
        return spliceFileToPipe(in_fd, off_in_ptr, out_fd, len);
    }
}

/// Helper: Splice from file to pipe
fn spliceFileToPipe(
    file_fd: *FileDescriptor,
    off_in_ptr: usize,
    pipe_fd: *FileDescriptor,
    len: usize,
) SyscallError!usize {
    // Get pipe handle
    const pipe_handle = pipe_mod.getPipeHandle(pipe_fd) orelse return error.EBADF;
    if (pipe_handle.end != .Write) return error.EBADF;

    // File must be seekable
    if (file_fd.ops.read == null or file_fd.ops.seek == null) {
        return error.EINVAL;
    }

    // Handle offset parameter
    var read_offset: u64 = 0;
    var use_offset_ptr = false;

    if (off_in_ptr != 0) {
        if (!isValidUserAccess(off_in_ptr, @sizeOf(u64), AccessMode.Read)) {
            return error.EFAULT;
        }
        const uptr = UserPtr.from(off_in_ptr);
        var offset_buf: [8]u8 = undefined;
        _ = uptr.copyToKernel(&offset_buf) catch return error.EFAULT;
        read_offset = std.mem.readInt(u64, &offset_buf, .little);
        use_offset_ptr = true;
    } else {
        read_offset = file_fd.position;
    }

    // Transfer loop with kernel buffer
    const splice_buf_size: usize = 64 * 1024;
    const kbuf = heap.allocator().alloc(u8, splice_buf_size) catch return error.ENOMEM;
    defer heap.allocator().free(kbuf);

    var total_sent: usize = 0;

    while (total_sent < len) {
        const remaining = len - total_sent;
        const chunk_size = @min(remaining, splice_buf_size);

        // Read from file at offset
        const file_held = file_fd.lock.acquire();
        const old_file_pos = file_fd.position;

        const seek_fn = file_fd.ops.seek.?;
        const seek_res = seek_fn(file_fd, @intCast(read_offset), 0); // SEEK_SET
        if (seek_res < 0) {
            file_held.release();
            if (total_sent > 0) return total_sent;
            return error.EINVAL;
        }
        file_fd.position = @intCast(seek_res);

        const read_fn = file_fd.ops.read.?;
        const bytes_read_raw = read_fn(file_fd, kbuf[0..chunk_size]);

        // Restore position
        if (!use_offset_ptr) {
            const new_pos = old_file_pos + @as(u64, @intCast(@max(0, bytes_read_raw)));
            _ = seek_fn(file_fd, @intCast(new_pos), 0);
            file_fd.position = new_pos;
        } else {
            _ = seek_fn(file_fd, @intCast(old_file_pos), 0);
            file_fd.position = old_file_pos;
        }

        file_held.release();

        if (bytes_read_raw <= 0) {
            if (bytes_read_raw == 0) break; // EOF
            if (total_sent > 0) return total_sent;
            return error.EIO;
        }

        const bytes_read: usize = @intCast(bytes_read_raw);

        // Write to pipe buffer
        const bytes_written = pipe_mod.writeToPipeBuffer(pipe_handle, kbuf[0..bytes_read]);
        if (bytes_written == 0) {
            // Pipe full or broken
            if (total_sent > 0) return total_sent;
            return error.EAGAIN;
        }

        // Update counters
        const new_total = @addWithOverflow(total_sent, bytes_written);
        if (new_total[1] != 0) break;
        total_sent = new_total[0];

        const new_offset = @addWithOverflow(read_offset, bytes_written);
        if (new_offset[1] != 0) break;
        read_offset = new_offset[0];

        // Short write: stop
        if (bytes_written < bytes_read) break;
        // Short read (EOF): stop
        if (bytes_read < chunk_size) break;
    }

    // Write updated offset back to userspace if using offset_ptr
    if (use_offset_ptr and off_in_ptr != 0) {
        if (isValidUserAccess(off_in_ptr, @sizeOf(u64), AccessMode.Write)) {
            const uptr = UserPtr.from(off_in_ptr);
            var offset_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &offset_buf, read_offset, .little);
            _ = uptr.copyFromKernel(&offset_buf) catch {};
        }
    }

    return total_sent;
}

/// Helper: Splice from pipe to file
fn splicePipeToFile(
    pipe_fd: *FileDescriptor,
    file_fd: *FileDescriptor,
    off_out_ptr: usize,
    len: usize,
) SyscallError!usize {
    // Get pipe handle
    const pipe_handle = pipe_mod.getPipeHandle(pipe_fd) orelse return error.EBADF;
    if (pipe_handle.end != .Read) return error.EBADF;

    // File must be writable and seekable
    if (file_fd.ops.write == null or file_fd.ops.seek == null) {
        return error.EINVAL;
    }

    // Handle offset parameter
    var write_offset: u64 = 0;
    var use_offset_ptr = false;

    if (off_out_ptr != 0) {
        if (!isValidUserAccess(off_out_ptr, @sizeOf(u64), AccessMode.Read)) {
            return error.EFAULT;
        }
        const uptr = UserPtr.from(off_out_ptr);
        var offset_buf: [8]u8 = undefined;
        _ = uptr.copyToKernel(&offset_buf) catch return error.EFAULT;
        write_offset = std.mem.readInt(u64, &offset_buf, .little);
        use_offset_ptr = true;
    } else {
        write_offset = file_fd.position;
    }

    // Transfer loop with kernel buffer
    const splice_buf_size: usize = 64 * 1024;
    const kbuf = heap.allocator().alloc(u8, splice_buf_size) catch return error.ENOMEM;
    defer heap.allocator().free(kbuf);

    var total_sent: usize = 0;

    while (total_sent < len) {
        const remaining = len - total_sent;
        const chunk_size = @min(remaining, splice_buf_size);

        // Read from pipe buffer
        const bytes_read = pipe_mod.readFromPipeBuffer(pipe_handle, kbuf[0..chunk_size]);
        if (bytes_read == 0) {
            // Pipe empty - we've read everything available
            break;
        }

        // Write to file at offset
        const file_held = file_fd.lock.acquire();
        const old_file_pos = file_fd.position;

        const seek_fn = file_fd.ops.seek.?;
        const seek_res = seek_fn(file_fd, @intCast(write_offset), 0); // SEEK_SET
        if (seek_res < 0) {
            file_held.release();
            if (total_sent > 0) return total_sent;
            return error.EINVAL;
        }
        file_fd.position = @intCast(seek_res);

        const write_fn = file_fd.ops.write.?;
        const bytes_written_raw = write_fn(file_fd, kbuf[0..bytes_read]);

        // Restore position
        if (!use_offset_ptr) {
            const new_pos = old_file_pos + @as(u64, @intCast(@max(0, bytes_written_raw)));
            _ = seek_fn(file_fd, @intCast(new_pos), 0);
            file_fd.position = new_pos;
        } else {
            _ = seek_fn(file_fd, @intCast(old_file_pos), 0);
            file_fd.position = old_file_pos;
        }

        file_held.release();

        if (bytes_written_raw <= 0) {
            if (total_sent > 0) return total_sent;
            return error.EIO;
        }

        const bytes_written: usize = @intCast(bytes_written_raw);

        // Update counters
        const new_total = @addWithOverflow(total_sent, bytes_written);
        if (new_total[1] != 0) break;
        total_sent = new_total[0];

        const new_offset = @addWithOverflow(write_offset, bytes_written);
        if (new_offset[1] != 0) break;
        write_offset = new_offset[0];

        // Short write: stop
        if (bytes_written < bytes_read) break;
    }

    // Write updated offset back to userspace if using offset_ptr
    if (use_offset_ptr and off_out_ptr != 0) {
        if (isValidUserAccess(off_out_ptr, @sizeOf(u64), AccessMode.Write)) {
            const uptr = UserPtr.from(off_out_ptr);
            var offset_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &offset_buf, write_offset, .little);
            _ = uptr.copyFromKernel(&offset_buf) catch {};
        }
    }

    return total_sent;
}

/// sys_tee (276/77) - Duplicate pipe data without consuming
///
/// Copies data from one pipe to another without consuming from the source.
pub fn sys_tee(
    fd_in: usize,
    fd_out: usize,
    len: usize,
    flags: usize,
) SyscallError!usize {
    if (len == 0) return 0;

    // Validate flags
    const valid_flags = SPLICE_F_MOVE | SPLICE_F_NONBLOCK | SPLICE_F_MORE | SPLICE_F_GIFT;
    if ((flags & ~valid_flags) != 0) return error.EINVAL;

    // Get FDs
    const table = base.getGlobalFdTable();
    const in_fd_u32 = safeFdCast(fd_in) orelse return error.EBADF;
    const out_fd_u32 = safeFdCast(fd_out) orelse return error.EBADF;

    const in_fd = table.get(in_fd_u32) orelse return error.EBADF;
    const out_fd = table.get(out_fd_u32) orelse return error.EBADF;

    // Both must be pipes
    const in_handle = pipe_mod.getPipeHandle(in_fd) orelse return error.EINVAL;
    const out_handle = pipe_mod.getPipeHandle(out_fd) orelse return error.EINVAL;

    // in_fd must be read end, out_fd must be write end
    if (in_handle.end != .Read) return error.EBADF;
    if (out_handle.end != .Write) return error.EBADF;

    // Must not be the same pipe
    if (in_handle.pipe == out_handle.pipe) return error.EINVAL;

    // Single peek and copy (peekPipeBuffer doesn't advance read_pos, so loop would duplicate data)
    const tee_buf_size: usize = 64 * 1024;
    const kbuf = heap.allocator().alloc(u8, tee_buf_size) catch return error.ENOMEM;
    defer heap.allocator().free(kbuf);

    // Peek from source pipe (without consuming) - limited by requested len
    const peek_len = @min(len, tee_buf_size);
    const bytes_peeked = pipe_mod.peekPipeBuffer(in_handle, kbuf[0..peek_len]);
    if (bytes_peeked == 0) {
        // No data available
        return 0;
    }

    // Write to dest pipe
    const bytes_written = pipe_mod.writeToPipeBuffer(out_handle, kbuf[0..bytes_peeked]);
    if (bytes_written == 0) {
        // Dest pipe full, non-blocking
        return error.EAGAIN;
    }

    return bytes_written;
}

/// sys_vmsplice (278/75) - Splice user memory into a pipe
///
/// Copies user memory described by iovec array into the pipe buffer.
pub fn sys_vmsplice(
    fd: usize,
    iov_ptr: usize,
    nr_segs: usize,
    flags: usize,
) SyscallError!usize {
    // Validate flags
    const valid_flags = SPLICE_F_MOVE | SPLICE_F_NONBLOCK | SPLICE_F_MORE | SPLICE_F_GIFT;
    if ((flags & ~valid_flags) != 0) return error.EINVAL;

    // Validate iovec count
    if (nr_segs == 0) return 0;
    if (nr_segs > 1024) return error.EINVAL;

    // Get FD
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd) orelse return error.EBADF;
    const pipe_fd = table.get(fd_u32) orelse return error.EBADF;

    // Must be a pipe write end
    const pipe_handle = pipe_mod.getPipeHandle(pipe_fd) orelse return error.EINVAL;
    if (pipe_handle.end != .Write) return error.EBADF;

    // Copy iovec array from userspace
    const iovec_size = nr_segs * @sizeOf(Iovec);
    if (!isValidUserAccess(iov_ptr, iovec_size, AccessMode.Read)) {
        return error.EFAULT;
    }

    const uptr = UserPtr.from(iov_ptr);
    const kiovec = heap.allocator().alloc(Iovec, nr_segs) catch return error.ENOMEM;
    defer heap.allocator().free(kiovec);

    const iov_bytes = std.mem.sliceAsBytes(kiovec);
    _ = uptr.copyToKernel(iov_bytes) catch return error.EFAULT;

    // Validate each iovec and calculate total length
    var total_len: usize = 0;
    for (kiovec) |vec| {
        if (vec.len == 0) continue;
        if (!isValidUserAccess(vec.base, vec.len, AccessMode.Read)) {
            return error.EFAULT;
        }
        const new_total = @addWithOverflow(total_len, vec.len);
        if (new_total[1] != 0) return error.EINVAL;
        total_len = new_total[0];
    }

    // Copy each segment into pipe
    var total_written: usize = 0;

    for (kiovec) |vec| {
        if (vec.len == 0) continue;

        // Copy user segment to kernel buffer
        const seg_uptr = UserPtr.from(vec.base);
        const kbuf = heap.allocator().alloc(u8, vec.len) catch {
            if (total_written > 0) return total_written;
            return error.ENOMEM;
        };
        defer heap.allocator().free(kbuf);

        _ = seg_uptr.copyToKernel(kbuf) catch {
            if (total_written > 0) return total_written;
            return error.EFAULT;
        };

        // Write to pipe
        const bytes_written = pipe_mod.writeToPipeBuffer(pipe_handle, kbuf);
        if (bytes_written == 0) {
            // Pipe full or broken
            if (total_written > 0) return total_written;
            return error.EAGAIN;
        }

        const new_total = @addWithOverflow(total_written, bytes_written);
        if (new_total[1] != 0) break;
        total_written = new_total[0];

        // Short write: stop
        if (bytes_written < vec.len) break;
    }

    return total_written;
}

/// sys_copy_file_range (326/285) - Copy data between two files
///
/// Copies data from one file to another within the kernel.
pub fn sys_copy_file_range(
    fd_in: usize,
    off_in_ptr: usize,
    fd_out: usize,
    off_out_ptr: usize,
    len: usize,
    flags: usize,
) SyscallError!usize {
    if (len == 0) return 0;

    // Linux currently defines no flags for copy_file_range
    if (flags != 0) return error.EINVAL;

    // Get FDs
    const table = base.getGlobalFdTable();
    const in_fd_u32 = safeFdCast(fd_in) orelse return error.EBADF;
    const out_fd_u32 = safeFdCast(fd_out) orelse return error.EBADF;

    const in_fd = table.get(in_fd_u32) orelse return error.EBADF;
    const out_fd = table.get(out_fd_u32) orelse return error.EBADF;

    // Both must be regular files (not pipes or sockets)
    if (pipe_mod.isPipe(in_fd) or pipe_mod.isPipe(out_fd)) {
        return error.EINVAL;
    }

    // Validate FDs
    if (!in_fd.isReadable()) return error.EBADF;
    if (!out_fd.isWritable()) return error.EBADF;

    // Both must support seek
    if (in_fd.ops.read == null or in_fd.ops.seek == null) {
        return error.EINVAL;
    }
    if (out_fd.ops.write == null or out_fd.ops.seek == null) {
        return error.EINVAL;
    }

    // Handle offset parameters
    var read_offset: u64 = 0;
    var write_offset: u64 = 0;
    var use_in_offset_ptr = false;
    var use_out_offset_ptr = false;

    if (off_in_ptr != 0) {
        if (!isValidUserAccess(off_in_ptr, @sizeOf(u64), AccessMode.Read)) {
            return error.EFAULT;
        }
        const uptr = UserPtr.from(off_in_ptr);
        var offset_buf: [8]u8 = undefined;
        _ = uptr.copyToKernel(&offset_buf) catch return error.EFAULT;
        read_offset = std.mem.readInt(u64, &offset_buf, .little);
        use_in_offset_ptr = true;
    } else {
        read_offset = in_fd.position;
    }

    if (off_out_ptr != 0) {
        if (!isValidUserAccess(off_out_ptr, @sizeOf(u64), AccessMode.Read)) {
            return error.EFAULT;
        }
        const uptr = UserPtr.from(off_out_ptr);
        var offset_buf: [8]u8 = undefined;
        _ = uptr.copyToKernel(&offset_buf) catch return error.EFAULT;
        write_offset = std.mem.readInt(u64, &offset_buf, .little);
        use_out_offset_ptr = true;
    } else {
        write_offset = out_fd.position;
    }

    // Transfer loop with kernel buffer
    const copy_buf_size: usize = 64 * 1024;
    const kbuf = heap.allocator().alloc(u8, copy_buf_size) catch return error.ENOMEM;
    defer heap.allocator().free(kbuf);

    var total_copied: usize = 0;

    while (total_copied < len) {
        const remaining = len - total_copied;
        const chunk_size = @min(remaining, copy_buf_size);

        // Read from in_fd
        const in_held = in_fd.lock.acquire();
        const old_in_pos = in_fd.position;

        const in_seek_fn = in_fd.ops.seek.?;
        const in_seek_res = in_seek_fn(in_fd, @intCast(read_offset), 0);
        if (in_seek_res < 0) {
            in_held.release();
            if (total_copied > 0) return total_copied;
            return error.EINVAL;
        }
        in_fd.position = @intCast(in_seek_res);

        const read_fn = in_fd.ops.read.?;
        const bytes_read_raw = read_fn(in_fd, kbuf[0..chunk_size]);

        // Restore position
        if (!use_in_offset_ptr) {
            const new_pos = old_in_pos + @as(u64, @intCast(@max(0, bytes_read_raw)));
            _ = in_seek_fn(in_fd, @intCast(new_pos), 0);
            in_fd.position = new_pos;
        } else {
            _ = in_seek_fn(in_fd, @intCast(old_in_pos), 0);
            in_fd.position = old_in_pos;
        }

        in_held.release();

        if (bytes_read_raw <= 0) {
            if (bytes_read_raw == 0) break; // EOF
            if (total_copied > 0) return total_copied;
            return error.EIO;
        }

        const bytes_read: usize = @intCast(bytes_read_raw);

        // Write to out_fd
        const out_held = out_fd.lock.acquire();
        const old_out_pos = out_fd.position;

        const out_seek_fn = out_fd.ops.seek.?;
        const out_seek_res = out_seek_fn(out_fd, @intCast(write_offset), 0);
        if (out_seek_res < 0) {
            out_held.release();
            if (total_copied > 0) return total_copied;
            return error.EINVAL;
        }
        out_fd.position = @intCast(out_seek_res);

        const write_fn = out_fd.ops.write.?;
        const bytes_written_raw = write_fn(out_fd, kbuf[0..bytes_read]);

        // Restore position
        if (!use_out_offset_ptr) {
            const new_pos = old_out_pos + @as(u64, @intCast(@max(0, bytes_written_raw)));
            _ = out_seek_fn(out_fd, @intCast(new_pos), 0);
            out_fd.position = new_pos;
        } else {
            _ = out_seek_fn(out_fd, @intCast(old_out_pos), 0);
            out_fd.position = old_out_pos;
        }

        out_held.release();

        if (bytes_written_raw <= 0) {
            if (total_copied > 0) return total_copied;
            return error.EIO;
        }

        const bytes_written: usize = @intCast(bytes_written_raw);

        // Update counters
        const new_total = @addWithOverflow(total_copied, bytes_written);
        if (new_total[1] != 0) break;
        total_copied = new_total[0];

        const new_in_offset = @addWithOverflow(read_offset, bytes_written);
        if (new_in_offset[1] != 0) break;
        read_offset = new_in_offset[0];

        const new_out_offset = @addWithOverflow(write_offset, bytes_written);
        if (new_out_offset[1] != 0) break;
        write_offset = new_out_offset[0];

        // Short write: stop
        if (bytes_written < bytes_read) break;
        // Short read (EOF): stop
        if (bytes_read < chunk_size) break;
    }

    // Write updated offsets back to userspace
    if (use_in_offset_ptr and off_in_ptr != 0) {
        if (isValidUserAccess(off_in_ptr, @sizeOf(u64), AccessMode.Write)) {
            const uptr = UserPtr.from(off_in_ptr);
            var offset_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &offset_buf, read_offset, .little);
            _ = uptr.copyFromKernel(&offset_buf) catch {};
        }
    }

    if (use_out_offset_ptr and off_out_ptr != 0) {
        if (isValidUserAccess(off_out_ptr, @sizeOf(u64), AccessMode.Write)) {
            const uptr = UserPtr.from(off_out_ptr);
            var offset_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &offset_buf, write_offset, .little);
            _ = uptr.copyFromKernel(&offset_buf) catch {};
        }
    }

    return total_copied;
}
