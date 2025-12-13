// Pipe Implementation
//
// Implements a unidirectional data channel (pipe).
// Supports blocking reads and writes.
//
// Thread-safety:
// - Protected by internal spinlock for buffer access.
// - Supports multiple readers/writers (though POSIX pipe is typically 1:1).

const std = @import("std");
const heap = @import("heap");
const fd_mod = @import("fd");
const sched = @import("sched");
const sync = @import("sync");
const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");

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

            // Wake up writers
            if (pipe.blocked_writers) |t| {
                pipe.blocked_writers = null;
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

        // Wait for data
        pipe.blocked_readers = sched.getCurrentThread();

        // Critical section: Disable interrupts before releasing lock to ensure
        // we don't miss a wakeup if preempted immediately after release.
        // sched.block() expects to be called with interrupts enabled?
        // No, sched.block() handles its own atomicity via scheduler lock,
        // but the gap between held.release() (pipe lock) and sched.block() (acquires scheduler lock)
        // is vulnerable if we rely on pipe.blocked_readers.

        // If writer comes in here:
        // 1. We release pipe lock.
        // 2. Writer acquires pipe lock.
        // 3. Writer writes data.
        // 4. Writer sees blocked_readers != null (us).
        // 5. Writer calls sched.unblock(us).
        // 6. sched.unblock acquires scheduler lock, sets our state to Ready (if Blocked) or leaves it Running (if not yet Blocked).
        // 7. We call sched.block().
        //    - sched.block() acquires scheduler lock.
        //    - It sets state to Blocked.
        //    - It halts.

        // If unblock() happens BEFORE block():
        // - unblock() sees state is Running (we haven't blocked yet). It does nothing (or effectively nothing).
        // - block() sets state to Blocked. We sleep forever. LOST WAKEUP!

        // Fix: We need to hold scheduler lock or disable interrupts across the gap?
        // Or check state in block()?
        // sched.block() implementation checks `if (curr.state == .Running) return;` inside its critical section?
        // Actually, looking at sched.zig, block() sets state=.Blocked.

        // The pattern should be:
        // 1. Acquire pipe lock.
        // 2. Add self to waiter list.
        // 3. Disable interrupts (prevent preemption).
        // 4. Release pipe lock.
        // 5. Call sched.block() (which should handle the rest).

        // However, standard `sched.block()` in this kernel seems to be designed to be called from syscalls.
        // It acquires scheduler lock.

        // If we disable interrupts, we can't be preempted.
        // So writer can only run on another core.
        // If single core (MVP), disabling interrupts is sufficient.

        // For multi-core, spinlock protects data.
        // The issue is the gap.

        // Correct fix requires integrating with scheduler lock, or a "prepare_to_wait" API.
        // Given existing sched API, we can't easily hold scheduler lock here.

        // Workaround: Use disableInterrupts() to protect the gap on single core.
        // For SMP, this is still broken without a proper wait queue primitive.
        // Assuming single core for now (as per "MVP" notes in other files).

        // Use disableInterrupts() (cli) because disableInterruptsSaveFlags returns u64
        // which we can't easily pass to restoreInterrupts if we don't save it.
        // Actually, hal.cpu has disableInterruptsSaveFlags() -> u64
        // and restoreInterrupts(u64).

        // However, standard `disableInterrupts()` returns void.
        // I will use explicit `disableInterrupts()` and then assume interrupts were enabled
        // (standard kernel context) or use explicit enable if needed.
        // But the reviewer asked to restore.
        // Let's check if `disableInterrupts` returns something in `hal.cpu`.
        // Checked: `disableInterrupts()` returns void. `disableInterruptsSaveFlags()` returns u64.

        const interrupt_state = hal.cpu.disableInterruptsSaveFlags();
        held.release();

        sched.block();

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

            // Wake up readers
            if (pipe.blocked_readers) |t| {
                pipe.blocked_readers = null;
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

        // Wait for space
        pipe.blocked_writers = sched.getCurrentThread();

        // Protect wakeup gap
        const interrupt_state = hal.cpu.disableInterruptsSaveFlags();
        held.release();

        sched.block();

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
        // Wake up writers so they see EPIPE
        if (pipe.blocked_writers) |t| {
            pipe.blocked_writers = null;
            sched.unblock(t);
        }
    } else {
        pipe.writers -= 1;
        // Wake up readers so they see EOF
        if (pipe.blocked_readers) |t| {
            pipe.blocked_readers = null;
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
