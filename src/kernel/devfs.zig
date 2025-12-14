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
const ahci = @import("ahci");
const audio = @import("audio");
const vfs = @import("fs").vfs; // Import VFS for Error type

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
    name: []const u8,
    ops: *const FileOps,
};

/// Registered devices
/// Names are relative to /dev/
const devices = [_]DeviceEntry{
    .{ .name = "console", .ops = &console_ops },
    .{ .name = "tty", .ops = &console_ops }, // Alias for console
    .{ .name = "stdin", .ops = &console_ops },
    .{ .name = "stdout", .ops = &console_ops },
    .{ .name = "stderr", .ops = &console_ops },
    .{ .name = "null", .ops = &null_ops },
    .{ .name = "zero", .ops = &zero_ops },
    .{ .name = "sda", .ops = &ahci.adapter.block_ops },
    .{ .name = "dsp", .ops = &audio.ac97.dsp_ops },
};

/// Look up device operations by path
/// Returns null if path is not a known device
pub fn lookupDevice(path: []const u8) ?*const FileOps {
    // Path should be relative to /dev, e.g. "console", "null"
    // But existing code passes absolute path?
    // Let's support both for now or check usage.

    // Check if path starts with /dev/
    const name = if (std.mem.startsWith(u8, path, "/dev/"))
        path[5..]
    else
        path;

    for (devices) |dev| {
        if (std.mem.eql(u8, name, dev.name)) {
            return dev.ops;
        }
    }
    return null;
}

/// Open a device (VFS interface)
fn devfsOpen(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd_mod.FileDescriptor {
    _ = ctx;

    // Path is relative to /dev mount point.
    // e.g. "console", "null", "sda" (without leading / if mounted at /dev)

    // Remove leading slash if present (path passed from VFS might have it or not depending on normalization)
    // VFS currently passes path relative to mount point. If mount is /dev, and we ask for /dev/console, path is /console.
    // If we ask for /dev, path is /.

    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    const ops = lookupDevice(name) orelse return vfs.Error.NotFound;

    // For block devices, we need special handling to set private_data (port number)
    // Currently lookupDevice just returns ops.
    // We should improve this to support device instances.

    var private_data: ?*anyopaque = null;

    if (std.mem.eql(u8, name, "sda")) {
        // Assume port 0 for sda
        // We need to check if port 0 exists
        if (ahci.root.getController()) |controller| {
             if (controller.getPort(0)) |_| {
                 private_data = @ptrFromInt(0);
             } else {
                 return vfs.Error.NotFound;
             }
        } else {
            return vfs.Error.NotFound;
        }
    }

    const fd = fd_mod.createFd(ops, flags, private_data) catch return vfs.Error.NoMemory;
    return fd;
}

/// DevFS filesystem interface
pub const dev_fs = vfs.FileSystem{
    .context = null,
    .open = devfsOpen,
    .unmount = null,
};

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
