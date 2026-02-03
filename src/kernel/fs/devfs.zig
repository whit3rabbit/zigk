//! Device Filesystem (DevFS)
//!
//! Provides virtual device file operations for standard devices and
//! a registry for dynamic devices.
//!
//! - /dev/console (stdin/stdout/stderr): Serial and keyboard I/O
//! - /dev/null: Discard writes, EOF on read
//! - /dev/zero: Infinite zeros on read, discard writes
//! - Dynamic devices: Registered by drivers (e.g., sda, dsp)
//!
//! This module implements a VFS interface (`dev_fs`) to allow
//! mounting at `/dev`.

const std = @import("std");
const fd_mod = @import("fd");
const console = @import("console");
const hal = @import("hal");
const keyboard = @import("keyboard");
const sched = @import("sched");
const uapi = @import("uapi");
const ahci = @import("ahci");
const vfs = @import("fs").vfs; // Import VFS for Error type
const meta = @import("fs").meta;
const heap = @import("heap");
const sync = @import("sync");
const syscall_base = @import("syscall_base");
const signals = @import("signals");

const FileDescriptor = fd_mod.FileDescriptor;
const FileOps = fd_mod.FileOps;
const Errno = uapi.errno.Errno;

// =============================================================================
// Console Device (/dev/console, stdin/stdout/stderr)
// =============================================================================

/// TTY state for job control
/// Stored in FileDescriptor.private_data
pub const TtyState = struct {
    /// Foreground process group ID (0 = no foreground group)
    foreground_pgid: std.atomic.Value(u32),
    /// Session ID that owns this terminal (0 = no session)
    session_id: std.atomic.Value(u32),

    pub fn init() TtyState {
        return .{
            .foreground_pgid = std.atomic.Value(u32).init(0),
            .session_id = std.atomic.Value(u32).init(0),
        };
    }
};

pub const console_ops = FileOps{
    .read = consoleRead,
    .write = consoleWrite,
    .close = consoleClose,
    .seek = null, // Not seekable
    .stat = null,
    .ioctl = consoleIoctl,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

/// Read from console (keyboard input)
/// Blocking read - waits for input if buffer is empty
fn consoleRead(fd: *FileDescriptor, buf: []u8) isize {
    if (buf.len == 0) return 0;

    // Job control: Check if background process is trying to read from terminal
    const signal = uapi.signal;
    const proc = syscall_base.getCurrentProcess();
    const thread = sched.getCurrentThread() orelse return -@as(isize, @intCast(@intFromEnum(Errno.ESRCH)));

    if (fd.private_data) |data| {
        const tty_state: *TtyState = @ptrCast(@alignCast(data));
        const fg_pgid = tty_state.foreground_pgid.load(.seq_cst);

        // If this process is in background (not foreground group), send SIGTTIN
        if (fg_pgid != 0 and proc.pgid != fg_pgid) {
            signals.deliverSignalToThread(thread, signal.SIGTTIN);
            // If signal stopped the thread (default action), return EINTR
            if (thread.stopped) {
                return -@as(isize, @intCast(@intFromEnum(Errno.EINTR)));
            }
        }
    }

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
    if (buf.len == 0) return 0;

    // Job control: Check if background process is trying to write to terminal
    const signal = uapi.signal;
    const proc = syscall_base.getCurrentProcess();
    const thread = sched.getCurrentThread() orelse return -@as(isize, @intCast(@intFromEnum(Errno.ESRCH)));

    if (fd.private_data) |data| {
        const tty_state: *TtyState = @ptrCast(@alignCast(data));
        const fg_pgid = tty_state.foreground_pgid.load(.seq_cst);

        // If this process is in background (not foreground group), send SIGTTOU
        if (fg_pgid != 0 and proc.pgid != fg_pgid) {
            signals.deliverSignalToThread(thread, signal.SIGTTOU);
            // If signal stopped the thread (default action), return EINTR
            if (thread.stopped) {
                return -@as(isize, @intCast(@intFromEnum(Errno.EINTR)));
            }
        }
    }

    // Write to serial console
    console.print(buf);

    return @intCast(buf.len);
}

/// Close console FD (cleanup TTY state)
fn consoleClose(fd: *FileDescriptor) isize {
    // TTY state is shared between stdin/stdout/stderr and lives for the process
    // lifetime, so we don't free it here. It will be freed when the process dies.
    // In a full implementation, we'd use refcounting on TtyState.
    _ = fd;
    return 0;
}

/// Console ioctl handler for job control
fn consoleIoctl(fd: *FileDescriptor, request: u64, arg: u64) isize {
    const UserPtr = syscall_base.UserPtr;

    // Get TTY state (all TTYs should have state attached)
    const tty_state: *TtyState = if (fd.private_data) |data|
        @ptrCast(@alignCast(data))
    else
        return -@intFromEnum(Errno.ENOTTY);

    const cmd: u32 = @truncate(request);

    switch (cmd) {
        uapi.tty.TIOCSCTTY => {
            // Make this terminal the controlling terminal
            // Requirements:
            // - Caller must be a session leader
            // - Session must not already have a controlling terminal

            const proc = syscall_base.getCurrentProcess();

            // Check if caller is session leader
            if (proc.sid != proc.pid) {
                return -@intFromEnum(Errno.EPERM);
            }

            // Check if session already has a controlling terminal
            if (proc.ctty != -1) {
                // arg can be 1 to "steal" the terminal (we don't support this yet)
                return -@intFromEnum(Errno.EPERM);
            }

            // Find which FD number this is in the process's FD table
            const table = syscall_base.getGlobalFdTable();
            var fd_num: i32 = -1;
            var i: usize = 0;
            while (i < fd_mod.MAX_FDS) : (i += 1) {
                if (table.get(@intCast(i))) |entry| {
                    if (entry == fd) {
                        fd_num = @intCast(i);
                        break;
                    }
                }
            }

            if (fd_num == -1) {
                return -@intFromEnum(Errno.EBADF);
            }

            // Set as controlling terminal
            proc.ctty = fd_num;
            tty_state.session_id.store(proc.sid, .seq_cst);

            // Set foreground process group to caller's process group
            tty_state.foreground_pgid.store(proc.pgid, .seq_cst);

            return 0;
        },

        uapi.tty.TIOCNOTTY => {
            // Give up the controlling terminal
            const proc = syscall_base.getCurrentProcess();

            // Check if this is our controlling terminal
            if (proc.ctty == -1) {
                return -@intFromEnum(Errno.ENOTTY);
            }

            // Clear controlling terminal
            proc.ctty = -1;

            // If we're the session leader, send SIGHUP to foreground group
            if (proc.sid == proc.pid) {
                const fg_pgid = tty_state.foreground_pgid.load(.seq_cst);
                if (fg_pgid != 0) {
                    // TODO: Send SIGHUP to foreground process group
                    // This requires access to the signal delivery function
                    // For now, just clear the state
                }
                tty_state.session_id.store(0, .seq_cst);
                tty_state.foreground_pgid.store(0, .seq_cst);
            }

            return 0;
        },

        uapi.tty.TIOCGPGRP => {
            // Get foreground process group ID
            // arg: pointer to i32 to store the result

            const proc = syscall_base.getCurrentProcess();

            // Must be our controlling terminal
            if (proc.ctty == -1) {
                return -@intFromEnum(Errno.ENOTTY);
            }

            // Get foreground pgid
            const fg_pgid: u32 = tty_state.foreground_pgid.load(.seq_cst);

            // Write to user pointer
            const uptr = UserPtr.from(arg);
            uptr.writeValue(@as(i32, @intCast(fg_pgid))) catch {
                return -@intFromEnum(Errno.EFAULT);
            };

            return 0;
        },

        uapi.tty.TIOCSPGRP => {
            // Set foreground process group ID
            // arg: pointer to i32 containing the new pgid

            const proc = syscall_base.getCurrentProcess();

            // Must be our controlling terminal
            if (proc.ctty == -1) {
                return -@intFromEnum(Errno.ENOTTY);
            }

            // Must be in the same session as the terminal
            const tty_sid = tty_state.session_id.load(.seq_cst);
            if (tty_sid != proc.sid) {
                return -@intFromEnum(Errno.EPERM);
            }

            // Read new pgid from user pointer
            const uptr = UserPtr.from(arg);
            const new_pgid_i32 = uptr.readValue(i32) catch {
                return -@intFromEnum(Errno.EFAULT);
            };

            if (new_pgid_i32 <= 0) {
                return -@intFromEnum(Errno.EINVAL);
            }

            const new_pgid: u32 = @intCast(new_pgid_i32);

            // Set foreground process group
            tty_state.foreground_pgid.store(new_pgid, .seq_cst);

            return 0;
        },

        uapi.tty.TCGETS => {
            // Check if this is a terminal (always succeeds for TTYs)
            // Used by isatty() in libc
            // arg is ignored (typically points to a termios struct we don't use)
            return 0;
        },

        else => {
            // Unknown ioctl command
            return -@intFromEnum(Errno.ENOTTY);
        },
    }
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
    .mmap = null,
    .poll = null,
    .truncate = null,
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
    .mmap = null,
    .poll = null,
    .truncate = null,
};

/// Read from /dev/zero fills buffer with zeros
fn zeroRead(fd: *FileDescriptor, buf: []u8) isize {
    _ = fd;

    // Fill buffer with zeros
    hal.mem.fill(buf.ptr, 0, buf.len);

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
pub const DeviceEntry = struct {
    name: []const u8,
    ops: *const FileOps,
    private_data: ?*anyopaque = null,
    next: ?*DeviceEntry = null,
};

/// Registered builtin devices
/// Names are relative to /dev/
const builtin_devices = [_]DeviceEntry{
    .{ .name = "console", .ops = &console_ops },
    .{ .name = "tty", .ops = &console_ops }, // Alias for console
    .{ .name = "stdin", .ops = &console_ops },
    .{ .name = "stdout", .ops = &console_ops },
    .{ .name = "stderr", .ops = &console_ops },
    .{ .name = "null", .ops = &null_ops },
    .{ .name = "zero", .ops = &zero_ops },
    // sda is registered dynamically by AHCI/NVMe/VirtIO-SCSI drivers
    // dsp is registered dynamically by audio driver (VirtIO-Sound, HDA, or AC97)
};

/// Dynamic device list head
var dynamic_devices: ?*DeviceEntry = null;

/// Lock protecting dynamic_devices linked list
/// Required for thread-safe device registration and lookup
var registry_lock: sync.Spinlock = .{};

/// Register a new device
/// Thread-safe: protected by registry_lock
pub fn registerDevice(name: []const u8, ops: *const FileOps, private_data: ?*anyopaque) !void {
    const allocator = heap.allocator();

    // Allocate outside lock to minimize critical section
    const entry = try allocator.create(DeviceEntry);
    errdefer allocator.destroy(entry);

    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    // Critical section: link into list
    const held = registry_lock.acquire();
    defer held.release();

    entry.* = DeviceEntry{
        .name = name_copy,
        .ops = ops,
        .private_data = private_data,
        .next = dynamic_devices,
    };

    dynamic_devices = entry;
}

/// Look up device entry by path
/// Returns null if path is not a known device
/// Thread-safe: dynamic device list access protected by registry_lock
///
/// SAFETY INVARIANT: Dynamic device entries are never freed after registration.
/// The returned pointer remains valid for the lifetime of the kernel. If device
/// unregistration is ever added, this function MUST be refactored to either:
/// 1. Hold lock during usage (restructure callers), or
/// 2. Add reference counting to DeviceEntry, or
/// 3. Return a copy of ops/private_data instead of a pointer
pub fn lookupDeviceEntry(path: []const u8) ?*const DeviceEntry {
    // Check if path starts with /dev/
    const name = if (std.mem.startsWith(u8, path, "/dev/"))
        path[5..]
    else
        path;

    // Check builtin devices first (immutable, no lock needed)
    for (&builtin_devices) |*dev| {
        if (std.mem.eql(u8, name, dev.name)) {
            return dev;
        }
    }

    // Check dynamic devices (requires lock)
    const held = registry_lock.acquire();
    defer held.release();

    var current = dynamic_devices;
    while (current) |dev| {
        if (std.mem.eql(u8, name, dev.name)) {
            return dev;
        }
        current = dev.next;
    }

    return null;
}

/// Look up device operations by path (legacy wrapper)
pub fn lookupDevice(path: []const u8) ?*const FileOps {
    if (lookupDeviceEntry(path)) |entry| {
        return entry.ops;
    }
    return null;
}

/// Open a device (VFS interface)
fn devfsOpen(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd_mod.FileDescriptor {
    _ = ctx;

    // Path is relative to /dev mount point.
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    if (name.len == 0 or std.mem.eql(u8, name, ".")) {
        const access_mode = flags & fd_mod.O_ACCMODE;
        if (access_mode != fd_mod.O_RDONLY) {
            return vfs.Error.IsDirectory;
        }

        const tag_ptr: ?*anyopaque = @ptrCast(@constCast(&fd_mod.devfs_dir_tag));
        return fd_mod.createFd(&fd_mod.dir_ops, fd_mod.O_RDONLY, tag_ptr) catch return vfs.Error.NoMemory;
    }

    const entry = lookupDeviceEntry(name) orelse return vfs.Error.NotFound;

    const fd = fd_mod.createFd(entry.ops, flags, entry.private_data) catch return vfs.Error.NoMemory;
    return fd;
}

/// Snapshot device names for directory listing.
/// Returns slices pointing to persistent device name storage.
///
/// SECURITY: Uses single lock acquisition to prevent TOCTOU race where
/// device count could change between counting and copying phases.
pub fn snapshotDeviceNames(alloc: std.mem.Allocator) ![]const []const u8 {
    // Hold lock for entire operation to prevent race condition where
    // new devices are registered between count and copy phases.
    const held = registry_lock.acquire();
    defer held.release();

    // Count dynamic devices while holding lock
    var dynamic_count: usize = 0;
    var current = dynamic_devices;
    while (current) |_| {
        dynamic_count += 1;
        current = current.?.next;
    }

    // Use checked arithmetic to prevent overflow (per CLAUDE.md security guidelines)
    const total = std.math.add(usize, builtin_devices.len, dynamic_count) catch {
        return error.OutOfMemory; // Overflow implies impossibly large count
    };

    // Allocate while holding lock - acceptable since device registration
    // is infrequent and allocation is fast for small arrays
    const names = try alloc.alloc([]const u8, total);
    errdefer alloc.free(names);

    // Copy builtin device names
    for (builtin_devices, 0..) |dev, i| {
        names[i] = dev.name;
    }

    // Copy dynamic device names - count is now guaranteed accurate
    var idx: usize = builtin_devices.len;
    current = dynamic_devices;
    while (current) |dev| {
        names[idx] = dev.name;
        idx += 1;
        current = dev.next;
    }

    return names;
}

fn devfsUnlink(ctx: ?*anyopaque, path: []const u8) vfs.Error!void {
    _ = ctx;
    _ = path;
    // DevFS devices cannot be unlinked
    return error.AccessDenied;
}

fn devfsStatPath(ctx: ?*anyopaque, path: []const u8) ?vfs.FileMeta {
    _ = ctx;

    // Handle root directory (/dev)
    if (path.len == 0 or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, ".")) {
        return vfs.FileMeta{
            .mode = meta.S_IFDIR | 0o755, // Directory with rwxr-xr-x
            .uid = 0,
            .gid = 0,
            .exists = true,
            .readonly = false,
        };
    }

    // Normalize path (remove leading /)
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    // Use lookupDeviceEntry to check actual registry (both builtin and dynamic)
    // This ensures stat() and open() have consistent behavior.
    const entry = lookupDeviceEntry(name) orelse return null;

    // Determine device type based on ops or name pattern
    // Block devices: sda, sdb, nvme*, etc. (registered by storage drivers)
    // Character devices: console, tty, null, zero, dsp, etc.
    const is_block_device = std.mem.startsWith(u8, entry.name, "sd") or
        std.mem.startsWith(u8, entry.name, "nvme");

    if (is_block_device) {
        return vfs.FileMeta{
            .mode = meta.S_IFBLK | 0o660, // Block device with rw-rw----
            .uid = 0,
            .gid = 0,
            .exists = true,
            .readonly = false,
        };
    } else {
        return vfs.FileMeta{
            .mode = meta.S_IFCHR | 0o666, // Character device with rw-rw-rw-
            .uid = 0,
            .gid = 0,
            .exists = true,
            .readonly = false,
        };
    }
}

/// DevFS filesystem interface
pub const dev_fs = vfs.FileSystem{
    .context = null,
    .open = devfsOpen,
    .unmount = null,
    .unlink = devfsUnlink,
    .stat_path = devfsStatPath,
};

/// Create pre-opened FDs for stdin/stdout/stderr (FDs 0/1/2)
/// Called during thread/process initialization
pub fn createStdFds(table: *fd_mod.FdTable) !void {
    const allocator = heap.allocator();

    // Allocate shared TTY state for all std FDs
    // All three FDs (stdin/stdout/stderr) share the same terminal state
    const tty_state = try allocator.create(TtyState);
    tty_state.* = TtyState.init();

    // FD 0: stdin (console, read-only)
    const stdin = try fd_mod.createFd(&console_ops, fd_mod.O_RDONLY, tty_state);
    table.install(0, stdin);

    // FD 1: stdout (console, write-only)
    const stdout = try fd_mod.createFd(&console_ops, fd_mod.O_WRONLY, tty_state);
    table.install(1, stdout);

    // FD 2: stderr (console, write-only)
    const stderr = try fd_mod.createFd(&console_ops, fd_mod.O_WRONLY, tty_state);
    table.install(2, stderr);

    // NOTE: Only one of the FDs will free the state in its close handler.
    // This is safe because they're all created together and the state is
    // logically shared. In a full implementation, we'd use refcounting.
}
