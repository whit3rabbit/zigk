// Device Filesystem Shim
//
// Provides virtual device file operations for standard devices:
//   - /dev/console (stdin/stdout/stderr)
//   - /dev/null (discard writes, EOF on read)
//   - /dev/zero (infinite zeros on read)
//
// These are registered at boot and used by sys_open for device paths.

const std = @import("std");
const fd_mod = @import("fd");
const console = @import("console");
const hal = @import("hal");
const keyboard = @import("keyboard");
const sched = @import("sched");
const uapi = @import("uapi");

const FileDescriptor = fd_mod.FileDescriptor;
const FileOps = fd_mod.FileOps;
const Errno = uapi.errno.Errno;

// =============================================================================
// Console Device (/dev/console, stdin/stdout/stderr)
// =============================================================================

/// Console device operations
pub const console_ops = FileOps{
    .read = consoleRead,
    .write = consoleWrite,
    .close = null, // Console cannot be closed
    .seek = null, // Not seekable
    .stat = null,
    .ioctl = null,
};

/// Read from console (keyboard input)
/// Blocking read - waits for input if buffer is empty
fn consoleRead(fd: *FileDescriptor, buf: []u8) isize {
    _ = fd; // Console has no per-fd state

    if (buf.len == 0) return 0;

    var bytes_read: usize = 0;
    while (bytes_read < buf.len) {
        // First try non-blocking read for any buffered characters
        if (keyboard.getChar()) |c| {
            buf[bytes_read] = c;
            bytes_read += 1;

            // Return after newline (line-buffered mode)
            if (c == '\n') {
                break;
            }
        } else {
            // No character available
            if (bytes_read > 0) {
                // Return what we have (partial line)
                break;
            }
            // Nothing read yet - block until character available
            // This properly sleeps the thread instead of busy-waiting
            const c = keyboard.getCharBlocking();
            buf[bytes_read] = c;
            bytes_read += 1;

            // Return after newline (line-buffered mode)
            if (c == '\n') {
                break;
            }
        }
    }

    return @intCast(bytes_read);
}

/// Write to console (serial output)
fn consoleWrite(fd: *FileDescriptor, buf: []const u8) isize {
    _ = fd; // Console has no per-fd state

    if (buf.len == 0) return 0;

    // Write to serial console
    console.print(buf);

    return @intCast(buf.len);
}

// =============================================================================
// Null Device (/dev/null)
// =============================================================================

/// Null device operations
pub const null_ops = FileOps{
    .read = nullRead,
    .write = nullWrite,
    .close = null,
    .seek = null,
    .stat = null,
    .ioctl = null,
};

/// Read from /dev/null always returns EOF (0 bytes)
fn nullRead(fd: *FileDescriptor, buf: []u8) isize {
    _ = fd;
    _ = buf;
    return 0; // EOF
}

/// Write to /dev/null always succeeds
fn nullWrite(fd: *FileDescriptor, buf: []const u8) isize {
    _ = fd;
    return @intCast(buf.len); // Discard all data
}

// =============================================================================
// Zero Device (/dev/zero)
// =============================================================================

/// Zero device operations
pub const zero_ops = FileOps{
    .read = zeroRead,
    .write = zeroWrite,
    .close = null,
    .seek = null,
    .stat = null,
    .ioctl = null,
};

/// Read from /dev/zero fills buffer with zeros
fn zeroRead(fd: *FileDescriptor, buf: []u8) isize {
    _ = fd;

    // Fill buffer with zeros
    @memset(buf, 0);

    return @intCast(buf.len);
}

/// Write to /dev/zero always succeeds (same as /dev/null)
fn zeroWrite(fd: *FileDescriptor, buf: []const u8) isize {
    _ = fd;
    return @intCast(buf.len);
}

// =============================================================================
// Device Registry
// =============================================================================

/// Device entry for path lookup
const DeviceEntry = struct {
    path: []const u8,
    ops: *const FileOps,
};

/// Registered devices
const devices = [_]DeviceEntry{
    .{ .path = "/dev/console", .ops = &console_ops },
    .{ .path = "/dev/tty", .ops = &console_ops }, // Alias for console
    .{ .path = "/dev/stdin", .ops = &console_ops },
    .{ .path = "/dev/stdout", .ops = &console_ops },
    .{ .path = "/dev/stderr", .ops = &console_ops },
    .{ .path = "/dev/null", .ops = &null_ops },
    .{ .path = "/dev/zero", .ops = &zero_ops },
};

/// Look up device operations by path
/// Returns null if path is not a known device
pub fn lookupDevice(path: []const u8) ?*const FileOps {
    for (devices) |dev| {
        if (std.mem.eql(u8, path, dev.path)) {
            return dev.ops;
        }
    }
    return null;
}

/// Create pre-opened FDs for stdin/stdout/stderr (FDs 0/1/2)
/// Called during thread/process initialization
pub fn createStdFds(table: *fd_mod.FdTable) !void {
    // FD 0: stdin (console, read-only)
    const stdin = try fd_mod.createFd(&console_ops, fd_mod.O_RDONLY, null);
    table.install(0, stdin);

    // FD 1: stdout (console, write-only)
    const stdout = try fd_mod.createFd(&console_ops, fd_mod.O_WRONLY, null);
    table.install(1, stdout);

    // FD 2: stderr (console, write-only)
    const stderr = try fd_mod.createFd(&console_ops, fd_mod.O_WRONLY, null);
    table.install(2, stderr);
}
