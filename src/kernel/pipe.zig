//! Pipe Implementation
//!
//! Implements a unidirectional data channel (pipe) for inter-process communication.
//! Supports blocking and non-blocking reads and writes.
//!
//! Features:
//! - Circular buffer storage (`PIPE_BUF_SIZE` = 4KB).
//! - Support for multiple readers/writers (though typically 1:1).
//! - Blocking I/O with process sleep/wakeup.
//! - `EPIPE` generation on broken pipes (reader closed).
//!
//! Thread-safety:
//! - Protected by internal spinlock for buffer access.
//! - Hand-crafted synchronization with scheduler to prevent lost wakeups.

const std = @import("std");
const heap = @import("heap");
const fd_mod = @import("fd");
const sched = @import("sched");
const sync = @import("sync");
const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");
const io = @import("io");

const Errno = uapi.errno.Errno;

const PIPE_BUF_SIZE: usize = 4096; // 4KB buffer (atomic write guarantee limit on Linux)

/// Pipe structure
/// Shared between read and write ends
const Pipe = struct {
    buffer: [PIPE_BUF_SIZE]u8,
    read_pos: usize,
    write_pos: usize,
    data_len: usize,

    readers: usize,
    writers: usize,

    lock: sync.Spinlock,

    // Blocking support
    blocked_readers: ?*sched.Thread,
    blocked_writers: ?*sched.Thread,

    // SMP-safe wakeup flags to prevent lost wakeups.
    // Set atomically by waker before unblock(), checked by sleeper before block().
    reader_woken: std.atomic.Value(bool),
    writer_woken: std.atomic.Value(bool),

    // Async I/O support (Phase 2)
    pending_read: ?*anyopaque, // *IoRequest for async read
    pending_write: ?*anyopaque, // *IoRequest for async write

    pub fn init() Pipe {
        return Pipe{
            .buffer = undefined,
            .read_pos = 0,
            .write_pos = 0,
            .data_len = 0,
            .readers = 1,
            .writers = 1,
            .lock = .{},
            .blocked_readers = null,
            .blocked_writers = null,
            .reader_woken = std.atomic.Value(bool).init(false),
            .writer_woken = std.atomic.Value(bool).init(false),
            .pending_read = null,
            .pending_write = null,
        };
    }
};

const PipeEnd = enum {
    Read,
    Write,
};

const PipeHandle = struct {
    pipe: *Pipe,
    end: PipeEnd,
};

/// File operations for pipe
const pipe_ops = fd_mod.FileOps{
    .read = pipeRead,
    .write = pipeWrite,
    .close = pipeClose,
    .seek = null,
    .stat = null, // TODO: stat
    .ioctl = null,
    .mmap = null,
    .poll = null,
};

/// Create a new pipe
/// Returns two file descriptors: [0]=read, [1]=write
pub fn createPipe(fds: *[2]u32, table: *fd_mod.FdTable) !void {
    const alloc = heap.allocator();

    // Create shared pipe object
    const pipe = try alloc.create(Pipe);
    pipe.* = Pipe.init();

    // Create read handle
    const read_handle = try alloc.create(PipeHandle);
    read_handle.* = .{ .pipe = pipe, .end = .Read };

    const read_fd = try fd_mod.createFd(&pipe_ops, fd_mod.O_RDONLY, read_handle);
    errdefer alloc.destroy(read_fd);

    // Create write handle
    const write_handle = try alloc.create(PipeHandle);
    write_handle.* = .{ .pipe = pipe, .end = .Write };

    const write_fd = try fd_mod.createFd(&pipe_ops, fd_mod.O_WRONLY, write_handle);
    errdefer alloc.destroy(write_fd);

    // Allocate FD numbers
    const fd0 = table.allocFdNum() orelse {
        // Cleanup pipe objects
        alloc.destroy(read_fd);
        alloc.destroy(write_fd);
        alloc.destroy(read_handle);
        alloc.destroy(write_handle);
        alloc.destroy(pipe);
        return error.MFile;
    };

    table.install(fd0, read_fd);

    const fd1 = table.allocFdNum() orelse {
        // Unwind fd0 - this closes the read end, which decrements reader count
        _ = table.close(fd0);
        // Destroy write FD and handle (since not installed yet)
        alloc.destroy(write_fd);
        alloc.destroy(write_handle);
        // If pipe not freed by close(fd0), we might need to free it?
        // close(fd0) decrements readers. Pipe initialized with 1 reader/1 writer.
        // After close(fd0), readers=0, writers=1.
        // We still have the write end logic (we destroyed write_fd struct, but handle/pipe remain).
        // Since we are erroring out, we must manually clean up the pipe if close() didn't.
        // Actually, destroy(write_fd) destroys the struct but doesn't run close().
        // We manually need to cleanup.
        // Since we never exposed the pipe to anyone else, we can just destroy everything.
        // But table.close(fd0) might have side effects?
        // table.close(fd0) -> fd.close() -> pipeClose().
        // pipeClose() will see end=.Read, decrement readers.
        // readers=0, writers=1. free_pipe = false.

        // So we must manually destroy pipe because writers=1.
        alloc.destroy(pipe);

        return error.MFile;
    };

    table.install(fd1, write_fd);

    fds[0] = fd0;
    fds[1] = fd1;
}

fn pipeRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    const handle: *PipeHandle = @ptrCast(@alignCast(fd.private_data));
    if (handle.end != .Read) return Errno.EBADF.toReturn();

    const pipe = handle.pipe;

    if (buf.len == 0) return 0;

    while (true) {
        const held = pipe.lock.acquire();

        // If data available, read it
        if (pipe.data_len > 0) {
            const read_len = @min(buf.len, pipe.data_len);

            // Handle wrap-around
            const first_chunk = @min(read_len, PIPE_BUF_SIZE - pipe.read_pos);
            @memcpy(buf[0..first_chunk], pipe.buffer[pipe.read_pos..][0..first_chunk]);

            if (first_chunk < read_len) {
                const second_chunk = read_len - first_chunk;
                @memcpy(buf[first_chunk..read_len], pipe.buffer[0..second_chunk]);
            }

            pipe.read_pos = (pipe.read_pos + read_len) % PIPE_BUF_SIZE;
            pipe.data_len -= read_len;

            // Complete pending async write if any (buffer space now available)
            if (pipe.pending_write) |pending| {
                const request: *io.IoRequest = @ptrCast(@alignCast(pending));

                const space = PIPE_BUF_SIZE - pipe.data_len;
                if (space > 0) {
                    pipe.pending_write = null;

                    const data_ptr: [*]const u8 = @ptrFromInt(request.buf_ptr);
                    const async_to_write = @min(request.buf_len, space);

                    const async_first = @min(async_to_write, PIPE_BUF_SIZE - pipe.write_pos);
                    @memcpy(pipe.buffer[pipe.write_pos..][0..async_first], data_ptr[0..async_first]);

                    if (async_first < async_to_write) {
                        const async_second = async_to_write - async_first;
                        @memcpy(pipe.buffer[0..async_second], data_ptr[async_first..async_to_write]);
                    }

                    pipe.write_pos = (pipe.write_pos + async_to_write) % PIPE_BUF_SIZE;
                    pipe.data_len += async_to_write;

                    _ = request.complete(.{ .success = async_to_write });
                }
            }

            // Wake up writers - set flag BEFORE unblock to prevent lost wakeup
            if (pipe.blocked_writers) |t| {
                pipe.blocked_writers = null;
                pipe.writer_woken.store(true, .release);
                sched.unblock(t);
            }

            held.release();
            return @intCast(read_len);
        }

        // No data available

        // If writers are gone, return EOF (0)
        if (pipe.writers == 0) {
            held.release();
            return 0;
        }

        // Block if blocking mode
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            held.release();
            return Errno.EAGAIN.toReturn();
        }

        // Wait for data - SMP-safe lost wakeup prevention
        pipe.blocked_readers = sched.getCurrentThread();

        // Clear the woken flag before releasing lock.
        // Writer will set it atomically before calling unblock().
        pipe.reader_woken.store(false, .release);

        // Disable interrupts to minimize the gap between lock release and block().
        // On single core this prevents the race entirely.
        // On SMP, we use the woken flag as a secondary check.
        const interrupt_state = hal.cpu.disableInterruptsSaveFlags();
        held.release();

        // SECURITY: Check if woken flag was set before we block.
        // This catches the SMP race where unblock() happens between
        // release() and block(). If woken, skip the block entirely.
        if (!pipe.reader_woken.load(.acquire)) {
            sched.block();
        }

        // Restore interrupt state after waking up
        hal.cpu.restoreInterrupts(interrupt_state);

        // Retry loop
    }
}

fn pipeWrite(fd: *fd_mod.FileDescriptor, buf: []const u8) isize {
    const handle: *PipeHandle = @ptrCast(@alignCast(fd.private_data));
    if (handle.end != .Write) return Errno.EBADF.toReturn();

    const pipe = handle.pipe;

    if (buf.len == 0) return 0;

    // Check if readers exist
    {
        const held = pipe.lock.acquire();
        if (pipe.readers == 0) {
            held.release();
            // Should send SIGPIPE, but for now just EPIPE
            return Errno.EPIPE.toReturn();
        }
        held.release();
    }

    var written: usize = 0;

    while (written < buf.len) {
        const held = pipe.lock.acquire();

        // Re-check readers
        if (pipe.readers == 0) {
            held.release();
            if (written > 0) return @intCast(written);
            return Errno.EPIPE.toReturn();
        }

        const space = PIPE_BUF_SIZE - pipe.data_len;

        if (space > 0) {
            const to_write = @min(buf.len - written, space);

            // Handle wrap-around
            const first_chunk = @min(to_write, PIPE_BUF_SIZE - pipe.write_pos);
            @memcpy(pipe.buffer[pipe.write_pos..][0..first_chunk], buf[written..][0..first_chunk]);

            if (first_chunk < to_write) {
                const second_chunk = to_write - first_chunk;
                @memcpy(pipe.buffer[0..second_chunk], buf[written + first_chunk..][0..second_chunk]);
            }

            pipe.write_pos = (pipe.write_pos + to_write) % PIPE_BUF_SIZE;
            pipe.data_len += to_write;
            written += to_write;

            // Complete pending async read if any
            if (pipe.pending_read) |pending| {
                const request: *io.IoRequest = @ptrCast(@alignCast(pending));
                pipe.pending_read = null;

                // Read data for async consumer
                const async_read_len = @min(request.buf_len, pipe.data_len);
                const async_buf_ptr: [*]u8 = @ptrFromInt(request.buf_ptr);

                const async_first = @min(async_read_len, PIPE_BUF_SIZE - pipe.read_pos);
                @memcpy(async_buf_ptr[0..async_first], pipe.buffer[pipe.read_pos..][0..async_first]);

                if (async_first < async_read_len) {
                    const async_second = async_read_len - async_first;
                    @memcpy(async_buf_ptr[async_first..async_read_len], pipe.buffer[0..async_second]);
                }

                pipe.read_pos = (pipe.read_pos + async_read_len) % PIPE_BUF_SIZE;
                pipe.data_len -= async_read_len;

                _ = request.complete(.{ .success = async_read_len });
            }

            // Wake up readers - set flag BEFORE unblock to prevent lost wakeup
            if (pipe.blocked_readers) |t| {
                pipe.blocked_readers = null;
                pipe.reader_woken.store(true, .release);
                sched.unblock(t);
            }

            held.release();
            continue; // Continue writing if more data
        }

        // Buffer full

        // Block if blocking mode
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            held.release();
            if (written > 0) return @intCast(written);
            return Errno.EAGAIN.toReturn();
        }

        // Wait for space - SMP-safe lost wakeup prevention
        pipe.blocked_writers = sched.getCurrentThread();

        // Clear the woken flag before releasing lock.
        // Reader will set it atomically before calling unblock().
        pipe.writer_woken.store(false, .release);

        // Disable interrupts to minimize the gap between lock release and block().
        const interrupt_state = hal.cpu.disableInterruptsSaveFlags();
        held.release();

        // SECURITY: Check if woken flag was set before we block.
        // This catches the SMP race where unblock() happens between
        // release() and block(). If woken, skip the block entirely.
        if (!pipe.writer_woken.load(.acquire)) {
            sched.block();
        }

        // Restore interrupt state
        hal.cpu.restoreInterrupts(interrupt_state);

        // Retry loop
    }

    return @intCast(written);
}

fn pipeClose(fd: *fd_mod.FileDescriptor) isize {
    const handle: *PipeHandle = @ptrCast(@alignCast(fd.private_data));
    const pipe = handle.pipe;
    const alloc = heap.allocator();

    const held = pipe.lock.acquire();

    if (handle.end == .Read) {
        pipe.readers -= 1;
        // Complete pending async write with EPIPE
        if (pipe.pending_write) |pending| {
            const request: *io.IoRequest = @ptrCast(@alignCast(pending));
            pipe.pending_write = null;
            _ = request.complete(.{ .err = error.EPIPE });
        }
        // Wake up writers so they see EPIPE - set flag BEFORE unblock
        if (pipe.blocked_writers) |t| {
            pipe.blocked_writers = null;
            pipe.writer_woken.store(true, .release);
            sched.unblock(t);
        }
    } else {
        pipe.writers -= 1;
        // Complete pending async read with EOF (0 bytes)
        if (pipe.pending_read) |pending| {
            const request: *io.IoRequest = @ptrCast(@alignCast(pending));
            pipe.pending_read = null;
            _ = request.complete(.{ .success = 0 }); // EOF
        }
        // Wake up readers so they see EOF - set flag BEFORE unblock
        if (pipe.blocked_readers) |t| {
            pipe.blocked_readers = null;
            pipe.reader_woken.store(true, .release);
            sched.unblock(t);
        }
    }

    const free_pipe = (pipe.readers == 0 and pipe.writers == 0);
    held.release();

    if (free_pipe) {
        alloc.destroy(pipe);
    }

    alloc.destroy(handle);
    return 0;
}

// =============================================================================
// Async Pipe API (Phase 2)
// =============================================================================

const IoRequest = io.IoRequest;

/// Async pipe read - queue request for incoming data
/// Returns true if completed synchronously, false if pending
pub fn readAsync(fd: *fd_mod.FileDescriptor, request: *IoRequest, buf: []u8) !bool {
    const handle: *PipeHandle = @ptrCast(@alignCast(fd.private_data));
    if (handle.end != .Read) return error.EBADF;

    const pipe = handle.pipe;
    const held = pipe.lock.acquire();
    defer held.release();

    // If data available, read it
    if (pipe.data_len > 0) {
        const read_len = @min(buf.len, pipe.data_len);

        const first_chunk = @min(read_len, PIPE_BUF_SIZE - pipe.read_pos);
        @memcpy(buf[0..first_chunk], pipe.buffer[pipe.read_pos..][0..first_chunk]);

        if (first_chunk < read_len) {
            const second_chunk = read_len - first_chunk;
            @memcpy(buf[first_chunk..read_len], pipe.buffer[0..second_chunk]);
        }

        pipe.read_pos = (pipe.read_pos + read_len) % PIPE_BUF_SIZE;
        pipe.data_len -= read_len;

        _ = request.complete(.{ .success = read_len });
        return true;
    }

    // No data - check if writers gone (EOF)
    if (pipe.writers == 0) {
        _ = request.complete(.{ .success = 0 }); // EOF
        return true;
    }

    // Queue async request
    if (pipe.pending_read != null) {
        return error.EAGAIN; // Already have pending read
    }

    pipe.pending_read = request;
    request.buf_ptr = @intFromPtr(buf.ptr);
    request.buf_len = buf.len;
    return false; // Pending
}

/// Async pipe write - queue request for buffer space
/// Returns true if completed synchronously, false if pending
pub fn writeAsync(fd: *fd_mod.FileDescriptor, request: *IoRequest, buf: []const u8) !bool {
    const handle: *PipeHandle = @ptrCast(@alignCast(fd.private_data));
    if (handle.end != .Write) return error.EBADF;

    const pipe = handle.pipe;
    const held = pipe.lock.acquire();
    defer held.release();

    // Check if readers exist
    if (pipe.readers == 0) {
        _ = request.complete(.{ .err = error.EPIPE });
        return true;
    }

    const space = PIPE_BUF_SIZE - pipe.data_len;
    if (space > 0) {
        const to_write = @min(buf.len, space);

        const first_chunk = @min(to_write, PIPE_BUF_SIZE - pipe.write_pos);
        @memcpy(pipe.buffer[pipe.write_pos..][0..first_chunk], buf[0..first_chunk]);

        if (first_chunk < to_write) {
            const second_chunk = to_write - first_chunk;
            @memcpy(pipe.buffer[0..second_chunk], buf[first_chunk..to_write]);
        }

        pipe.write_pos = (pipe.write_pos + to_write) % PIPE_BUF_SIZE;
        pipe.data_len += to_write;

        _ = request.complete(.{ .success = to_write });
        return true;
    }

    // Buffer full - queue async request
    if (pipe.pending_write != null) {
        return error.EAGAIN; // Already have pending write
    }

    pipe.pending_write = request;
    request.buf_ptr = @intFromPtr(buf.ptr);
    request.buf_len = buf.len;
    return false; // Pending
}
