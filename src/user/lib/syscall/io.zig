const std = @import("std");
const primitive = @import("primitive.zig");
const uapi = primitive.uapi;
const syscalls = uapi.syscalls;

pub const SyscallError = primitive.SyscallError;

// =============================================================================
// Basic I/O Syscalls (sys_read, sys_write)
// =============================================================================

/// Read from file descriptor
/// Returns number of bytes read, or error
pub fn read(fd: i32, buf: [*]u8, count: usize) SyscallError!size_t {
    const ret = primitive.syscall3(syscalls.SYS_READ, @bitCast(@as(isize, fd)), @intFromPtr(buf), count);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Write to file descriptor
/// Returns number of bytes written, or error
pub fn write(fd: i32, buf: [*]const u8, count: usize) SyscallError!size_t {
    const ret = primitive.syscall3(syscalls.SYS_WRITE, @bitCast(@as(isize, fd)), @intFromPtr(buf), count);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Write string to file descriptor (convenience wrapper)
pub fn writeString(fd: i32, str: []const u8) SyscallError!size_t {
    return write(fd, str.ptr, str.len);
}

/// Iovec structure for scatter-gather I/O (writev/readv)
pub const Iovec = extern struct {
    base: usize,
    len: usize,

    /// Create an Iovec from a slice
    pub fn fromSlice(slice: []const u8) Iovec {
        return .{
            .base = @intFromPtr(slice.ptr),
            .len = slice.len,
        };
    }
};

/// Write data from multiple buffers (scatter-gather write)
/// Returns total bytes written, or error
pub fn writev(fd: i32, iov: []const Iovec) SyscallError!size_t {
    const ret = primitive.syscall3(
        syscalls.SYS_WRITEV,
        @bitCast(@as(isize, fd)),
        @intFromPtr(iov.ptr),
        iov.len,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// =============================================================================
// File Operations (sys_open, sys_close)
// =============================================================================

/// Open flags
pub const O_RDONLY: i32 = 0;
pub const O_WRONLY: i32 = 1;
pub const O_RDWR: i32 = 2;
pub const O_CREAT: i32 = 0o100;
pub const O_EXCL: i32 = 0o200;
pub const O_TRUNC: i32 = 0o1000;
pub const O_APPEND: i32 = 0o2000;

/// Seek whence constants
pub const SEEK_SET: i32 = 0;
pub const SEEK_CUR: i32 = 1;
pub const SEEK_END: i32 = 2;

/// Reposition read/write file offset
pub fn lseek(fd: i32, offset: isize, whence: i32) SyscallError!usize {
    const ret = primitive.syscall3(syscalls.SYS_LSEEK, @bitCast(@as(isize, fd)), @bitCast(offset), @bitCast(@as(isize, whence)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Open a file
pub fn open(path: [*:0]const u8, flags: i32, mode: u32) SyscallError!i32 {
    const ret = primitive.syscall3(syscalls.SYS_OPEN, @intFromPtr(path), @bitCast(@as(isize, flags)), mode);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Close a file descriptor
pub fn close(fd: i32) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_CLOSE, @bitCast(@as(isize, fd)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Check user's permissions for a file
pub fn access(path: [*:0]const u8, mode: i32) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_ACCESS, @intFromPtr(path), @bitCast(@as(isize, mode)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Directory Operations (sys_mkdir, sys_rmdir, sys_chdir, sys_getcwd)
// =============================================================================

/// Create a directory
pub fn mkdir(path: [*:0]const u8, mode: u32) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_MKDIR, @intFromPtr(path), mode);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Remove a directory
pub fn rmdir(path: [*:0]const u8) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_RMDIR, @intFromPtr(path));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Delete a file
pub fn unlink(path: [*:0]const u8) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_UNLINK, @intFromPtr(path));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Change current working directory
pub fn chdir(path: [*:0]const u8) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_CHDIR, @intFromPtr(path));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get current working directory
/// Returns the length of the path on success (excluding null terminator)
pub fn getcwd(buf: [*]u8, size: usize) SyscallError!usize {
    const ret = primitive.syscall2(syscalls.SYS_GETCWD, @intFromPtr(buf), size);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Get directory entries (getdents64)
/// Returns number of bytes read into buffer
pub fn getdents64(fd: i32, dirp: [*]u8, count: usize) SyscallError!usize {
    const ret = primitive.syscall3(syscalls.SYS_GETDENTS64, @bitCast(@as(isize, fd)), @intFromPtr(dirp), count);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Device control
pub fn ioctl(fd: i32, cmd: u32, arg: usize) SyscallError!i32 {
    const ret = primitive.syscall3(syscalls.SYS_IOCTL, @bitCast(@as(isize, fd)), cmd, arg);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

// =============================================================================
// I/O Multiplexing (poll)
// =============================================================================

pub const PollFd = uapi.poll.PollFd;
pub const POLLIN = uapi.poll.POLLIN;
pub const POLLOUT = uapi.poll.POLLOUT;
pub const POLLERR = uapi.poll.POLLERR;
pub const POLLHUP = uapi.poll.POLLHUP;
pub const POLLNVAL = uapi.poll.POLLNVAL;

/// Wait for events on file descriptors
/// ufds: Array of PollFd structures
/// timeout: Timeout in milliseconds (-1 for infinite)
/// Returns number of descriptors with events, or error
pub fn poll(ufds: []PollFd, timeout: i32) SyscallError!usize {
    const ret = primitive.syscall3(
        syscalls.SYS_POLL,
        @intFromPtr(ufds.ptr),
        ufds.len,
        @bitCast(@as(isize, timeout))
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// =============================================================================
// Memory Mapping
// =============================================================================

/// Memory protection flags
pub const PROT_NONE: i32 = 0;
pub const PROT_READ: i32 = 1;
pub const PROT_WRITE: i32 = 2;
pub const PROT_EXEC: i32 = 4;

/// Memory mapping flags
pub const MAP_SHARED: i32 = 1;
pub const MAP_PRIVATE: i32 = 2;
pub const MAP_FIXED: i32 = 0x10;
pub const MAP_ANONYMOUS: i32 = 0x20;
pub const MAP_POPULATE: i32 = 0x8000;

/// Map memory region
pub fn mmap(addr: ?*anyopaque, length: usize, prot: i32, flags: i32, fd: i32, offset: u64) SyscallError![*]u8 {
    const ret = primitive.syscall6(
        syscalls.SYS_MMAP,
        @intFromPtr(addr),
        length,
        @bitCast(@as(isize, prot)),
        @bitCast(@as(isize, flags)),
        @bitCast(@as(isize, fd)),
        offset,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @ptrFromInt(ret);
}

/// Unmap memory region
pub fn munmap(addr: [*]u8, length: usize) SyscallError!void {
    const ret = primitive.syscall2(
        syscalls.SYS_MUNMAP,
        @intFromPtr(addr),
        length,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Change memory protection
pub fn mprotect(addr: [*]u8, length: usize, prot: i32) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_MPROTECT,
        @intFromPtr(addr),
        length,
        @bitCast(@as(isize, prot)),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Lock memory pages (prevent swapping)
pub fn mlock(addr: [*]u8, length: usize) SyscallError!void {
    const ret = primitive.syscall2(
        syscalls.SYS_MLOCK,
        @intFromPtr(addr),
        length,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Unlock memory pages
pub fn munlock(addr: [*]u8, length: usize) SyscallError!void {
    const ret = primitive.syscall2(
        syscalls.SYS_MUNLOCK,
        @intFromPtr(addr),
        length,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Memory advise hint to kernel
pub fn madvise(addr: [*]u8, length: usize, advice: i32) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_MADVISE,
        @intFromPtr(addr),
        length,
        @bitCast(@as(isize, advice)),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Synchronize memory with storage
pub fn msync(addr: [*]u8, length: usize, flags: i32) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_MSYNC,
        @intFromPtr(addr),
        length,
        @bitCast(@as(isize, flags)),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Standard File Descriptors
// =============================================================================

pub const STDIN_FILENO: i32 = 0;
pub const STDOUT_FILENO: i32 = 1;
pub const STDERR_FILENO: i32 = 2;

/// Write to stdout with error handling.
/// Returns error for callers who need to handle I/O failures
/// (e.g., security audit logging, transaction logging).
pub fn print_safe(str: []const u8) SyscallError!size_t {
    return write(STDOUT_FILENO, str.ptr, str.len);
}

/// Write to stdout (convenience wrapper)
/// Silently ignores errors - use print_safe() for security-sensitive output.
pub fn print(str: []const u8) void {
    _ = write(STDOUT_FILENO, str.ptr, str.len) catch {};
}

/// Write to stderr with error handling.
/// Returns error for callers who need to handle I/O failures.
pub fn eprint_safe(str: []const u8) SyscallError!size_t {
    return write(STDERR_FILENO, str.ptr, str.len);
}

/// Write to stderr (convenience wrapper)
/// Silently ignores errors - use eprint_safe() for security-sensitive output.
pub fn eprint(str: []const u8) void {
    _ = write(STDERR_FILENO, str.ptr, str.len) catch {};
}

/// Write debug message to kernel log
pub fn debug_log(buf: [*]const u8, len: usize) SyscallError!size_t {
    const ret = primitive.syscall2(syscalls.SYS_DEBUG_LOG, @intFromPtr(buf), len);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Write formatted debug message to kernel log (convenience wrapper)
pub fn debug_print(str: []const u8) void {
    _ = debug_log(str.ptr, str.len) catch {};
}

// =============================================================================
// File Locking Syscalls
// =============================================================================

/// Apply or remove an advisory lock on an open file
/// operation: LOCK_SH (shared), LOCK_EX (exclusive), LOCK_UN (unlock)
///            Can be OR'd with LOCK_NB for non-blocking
pub fn flock(fd: i32, operation: u32) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_FLOCK, @bitCast(@as(isize, fd)), operation);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// Alias size_t to usize for compatibility if needed, but usize is standard in Zig.
const size_t = usize;
