//! File Descriptor Subsystem
//!
//! Manages file descriptors (FDs) which abstract access to files, devices,
//! sockets, and pipes. This module provides:
//!
//! - `FileDescriptor`: A struct representing an open resource, with pluggable
//!   operations (`FileOps`) for read, write, close, seek, etc.
//! - `FdTable`: A per-process table mapping integer FD numbers to `FileDescriptor` objects.
//!   Handles allocation, lookups, and lifecycle management (refcounting).
//!
//! Design:
//! - Fixed-size FD table (`MAX_FDS` entries) per process.
//! - Shared FDs via reference counting (for `fork` and `dup`).
//! - Standard I/O (stdin, stdout, stderr) pre-populated at slots 0, 1, 2.

const std = @import("std");
const heap = @import("heap");
const console = @import("console");
const uapi = @import("uapi");
const sync = @import("sync");

const Errno = uapi.errno.Errno;

/// Maximum number of file descriptors per thread/process
pub const MAX_FDS: usize = 256;

// Comptime validation of constants
comptime {
    // MAX_FDS must fit in u32 (fd_num is cast from usize to u32 in syscall handlers)
    std.debug.assert(MAX_FDS <= std.math.maxInt(u32));
    // MAX_FDS should be reasonable (not too large for stack arrays)
    std.debug.assert(MAX_FDS <= 1024);
    // MAX_FDS must be > 2 for stdin/stdout/stderr
    std.debug.assert(MAX_FDS >= 3);
}

/// File descriptor flags (Linux O_* flags we care about)
pub const O_RDONLY: u32 = 0x0000;
pub const O_WRONLY: u32 = 0x0001;
pub const O_RDWR: u32 = 0x0002;
pub const O_ACCMODE: u32 = 0x0003; // Mask for access mode
pub const O_CREAT: u32 = 0x0040;
pub const O_TRUNC: u32 = 0x0200;
pub const O_APPEND: u32 = 0x0400;
pub const O_NONBLOCK: u32 = 0x0800;

/// File operations vtable
/// Devices/files implement these to provide I/O functionality
///
/// Note: read/write use slices ([]u8, []const u8) instead of pointer+count.
/// This enforces bounds checking at the type level - the slice length
/// IS the count, preventing buffer overflows.
pub const FileOps = struct {
    /// Read data from file into buffer
    /// Returns bytes read, 0 for EOF, or negative errno
    /// Buffer is a slice - its .len is the maximum bytes to read
    read: ?*const fn (fd: *FileDescriptor, buf: []u8) isize,

    /// Write data from buffer to file
    /// Returns bytes written or negative errno
    /// Buffer is a slice - its .len is the byte count to write
    write: ?*const fn (fd: *FileDescriptor, buf: []const u8) isize,

    /// Close the file and release resources
    /// Called when refcount reaches 0
    close: ?*const fn (fd: *FileDescriptor) isize,

    /// Seek to position (optional, for seekable files)
    seek: ?*const fn (fd: *FileDescriptor, offset: i64, whence: u32) isize,

    /// Get file status (optional)
    stat: ?*const fn (fd: *FileDescriptor, stat_buf: *anyopaque) isize,

    /// I/O control (optional, for device-specific operations)
    ioctl: ?*const fn (fd: *FileDescriptor, request: u64, arg: u64) isize,

    /// Memory map operation (optional, for mappable files like io_uring)
    /// Returns physical address of the region to map, or 0 on error.
    /// offset: mmap offset (e.g., IORING_OFF_SQ_RING)
    /// size: Pointer to size (in/out - returns actual size)
    mmap: ?*const fn (fd: *FileDescriptor, offset: u64, size: *usize) u64,

    /// Poll for events (optional, for epoll support)
    /// Returns bitmask of ready events (EPOLLIN, EPOLLOUT, etc.)
    poll: ?*const fn (fd: *FileDescriptor, requested_events: u32) u32,
};

/// Directory-only operations marker for synthetic directory FDs.
/// Used to distinguish directory handles from regular files/devices.
pub const dir_ops = FileOps{
    .read = null,
    .write = null,
    .close = null,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = null,
};

pub const DirTag = enum {
    initrd_root,
    devfs_root,
};

pub var initrd_dir_tag: DirTag = .initrd_root;
pub var devfs_dir_tag: DirTag = .devfs_root;

/// Hook for VFS to decrement open file count when FD is closed
/// Set by VFS.init to avoid circular dependency between fd.zig and vfs.zig
pub var vfs_close_hook: ?*const fn (u8) void = null;

/// File descriptor structure
/// Represents an open file, device, socket, or pipe
pub const FileDescriptor = struct {
    /// Operations vtable for this file type
    ops: *const FileOps,

    /// Device/file specific data (e.g., device instance, socket state)
    private_data: ?*anyopaque,

    /// Open flags (O_RDONLY, O_WRONLY, O_RDWR, etc.)
    flags: u32,

    /// Reference count for shared FDs (atomic for thread-safety)
    refcount: std.atomic.Value(u32),

    /// Current file position (for seekable files)
    position: u64,

    /// Lock for atomic operations (e.g. writev)
    lock: sync.Spinlock,

    /// VFS mount index for open file tracking (null if not from VFS)
    /// Used to decrement open_files count when FD is closed
    vfs_mount_idx: ?u8 = null,

    /// Increment reference count (atomic, thread-safe)
    pub fn ref(self: *FileDescriptor) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    /// Decrement reference count, returns true if FD should be freed
    /// Uses release ordering to ensure all prior writes are visible before
    /// the FD is potentially freed by another thread seeing refcount == 0
    pub fn unref(self: *FileDescriptor) bool {
        const old = self.refcount.fetchSub(1, .release);
        if (old == 0) {
            // Underflow - this is a bug, but handle defensively
            console.warn("FD: unref on zero refcount", .{});
            // Restore to 0 to prevent wraparound
            self.refcount.store(0, .monotonic);
            return true;
        }
        if (old == 1) {
            // Was 1, now 0 - we're the last reference
            // On x86_64, the release ordering in fetchSub combined with
            // the strong memory model provides sufficient synchronization
            return true;
        }
        return false;
    }

    /// Check if file is readable
    pub fn isReadable(self: *const FileDescriptor) bool {
        const mode = self.flags & O_ACCMODE;
        return mode == O_RDONLY or mode == O_RDWR;
    }

    /// Check if file is writable
    pub fn isWritable(self: *const FileDescriptor) bool {
        const mode = self.flags & O_ACCMODE;
        return mode == O_WRONLY or mode == O_RDWR;
    }
};

/// File descriptor table
/// One per thread/process, holds all open FDs
pub const FdTable = struct {
    /// Array of FD pointers (null = unused slot)
    fds: [MAX_FDS]?*FileDescriptor,

    /// Number of open FDs
    count: usize,

    /// Initialize an empty FD table
    pub fn init() FdTable {
        return FdTable{
            .fds = [_]?*FileDescriptor{null} ** MAX_FDS,
            .count = 0,
        };
    }

    /// Allocate a new FD number (lowest available)
    /// Returns FD number or null if table is full
    pub fn allocFdNum(self: *FdTable) ?u32 {
        for (self.fds, 0..) |fd, i| {
            if (fd == null) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Allocate a specific FD number
    /// Returns true if successful, false if already in use
    pub fn allocSpecificFd(self: *FdTable, fd_num: u32) bool {
        if (fd_num >= MAX_FDS) return false;
        if (self.fds[fd_num] != null) return false;
        return true;
    }

    /// Install an FD at a specific slot
    /// Caller must have already allocated the slot
    pub fn install(self: *FdTable, fd_num: u32, fd: *FileDescriptor) void {
        if (fd_num >= MAX_FDS) {
            console.err("FD: install with invalid fd_num {d}", .{fd_num});
            return;
        }
        if (self.fds[fd_num] != null) {
            console.warn("FD: overwriting existing fd {d}", .{fd_num});
        }
        self.fds[fd_num] = fd;
        self.count += 1;
    }

    /// Get FD by number
    pub fn get(self: *const FdTable, fd_num: u32) ?*FileDescriptor {
        if (fd_num >= MAX_FDS) return null;
        return self.fds[fd_num];
    }

    /// Remove FD from table (does not free or close)
    pub fn remove(self: *FdTable, fd_num: u32) ?*FileDescriptor {
        if (fd_num >= MAX_FDS) return null;
        const fd = self.fds[fd_num];
        if (fd != null) {
            self.fds[fd_num] = null;
            self.count -= 1;
        }
        return fd;
    }

    /// Close an FD by number
    /// Decrements refcount and calls close op if refcount reaches 0
    pub fn close(self: *FdTable, fd_num: u32) isize {
        const fd = self.remove(fd_num) orelse {
            return Errno.EBADF.toReturn();
        };

        // Decrement refcount
        if (fd.unref()) {
            // Refcount reached 0, call close op if present
            if (fd.ops.close) |close_fn| {
                _ = close_fn(fd);
            }

            // Notify VFS to decrement open file count for this mount
            // This prevents use-after-free on unmount
            if (fd.vfs_mount_idx) |idx| {
                if (vfs_close_hook) |hook| {
                    hook(idx);
                }
            }

            // Free the FileDescriptor
            const alloc = heap.allocator();
            alloc.destroy(fd);
        }

        return 0;
    }

    /// Duplicate the FD table (for fork)
    /// Creates a new table with same FDs, incremented refcounts
    pub fn clone(self: *const FdTable) !*FdTable {
        const alloc = heap.allocator();
        const new_table = try alloc.create(FdTable);
        new_table.* = FdTable.init();

        // Copy all FDs and increment refcounts
        for (self.fds, 0..) |maybe_fd, i| {
            if (maybe_fd) |fd| {
                fd.ref();
                new_table.fds[i] = fd;
                new_table.count += 1;
            }
        }

        return new_table;
    }

    /// Duplicate a single FD to the lowest available slot
    pub fn dup(self: *FdTable, old_fd: u32) !u32 {
        const fd = self.get(old_fd) orelse return error.BadFd;
        const new_fd = self.allocFdNum() orelse return error.MFile;
        fd.ref();
        self.install(new_fd, fd);
        return new_fd;
    }

    /// Duplicate a single FD to a specific slot
    pub fn dup2(self: *FdTable, old_fd: u32, new_fd: u32) !u32 {
        if (old_fd == new_fd) {
            // Check if old_fd is valid
            if (self.get(old_fd) == null) return error.BadFd;
            return new_fd;
        }

        const fd = self.get(old_fd) orelse return error.BadFd;

        if (new_fd >= MAX_FDS) return error.BadFd;

        // Close new_fd if open
        if (self.fds[new_fd] != null) {
            _ = self.close(new_fd);
        }

        // Install new FD
        fd.ref();
        self.fds[new_fd] = fd;
        self.count += 1;

        return new_fd;
    }

    /// Close all FDs in the table
    pub fn closeAll(self: *FdTable) void {
        var i: u32 = 0;
        while (i < MAX_FDS) : (i += 1) {
            if (self.fds[i] != null) {
                _ = self.close(i);
            }
        }
    }
};

/// Create a new FileDescriptor
pub fn createFd(ops: *const FileOps, flags: u32, private_data: ?*anyopaque) !*FileDescriptor {
    const alloc = heap.allocator();
    const fd = try alloc.create(FileDescriptor);
    fd.* = FileDescriptor{
        .ops = ops,
        .private_data = private_data,
        .flags = flags,
        .refcount = .{ .raw = 1 },
        .position = 0,
        .lock = .{},
        .vfs_mount_idx = null,
    };
    return fd;
}

/// Create a new FdTable
pub fn createFdTable() !*FdTable {
    const alloc = heap.allocator();
    const table = try alloc.create(FdTable);
    table.* = FdTable.init();
    return table;
}

/// Destroy an FdTable (closes all FDs and frees table)
pub fn destroyFdTable(table: *FdTable) void {
    table.closeAll();
    const alloc = heap.allocator();
    alloc.destroy(table);
}
