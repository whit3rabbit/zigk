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
// I/O Multiplexing - epoll
// =============================================================================

/// Create epoll instance with flags
pub fn epoll_create1(flags: u32) SyscallError!i32 {
    const ret = primitive.syscall1(syscalls.SYS_EPOLL_CREATE1, @as(usize, flags));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @intCast(@as(isize, @bitCast(ret)));
}

/// Control epoll instance (add/modify/delete file descriptors)
pub fn epoll_ctl(epfd: i32, op: u32, fd: i32, event: ?*EpollEvent) SyscallError!usize {
    const ev_ptr: usize = if (event) |e| @intFromPtr(e) else 0;
    const ret = primitive.syscall4(
        syscalls.SYS_EPOLL_CTL,
        @bitCast(@as(isize, epfd)),
        @as(usize, op),
        @bitCast(@as(isize, fd)),
        ev_ptr,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Wait for I/O events on epoll instance
pub fn epoll_wait(epfd: i32, events: [*]EpollEvent, maxevents: u32, timeout: i32) SyscallError!usize {
    const ret = primitive.syscall4(
        syscalls.SYS_EPOLL_WAIT,
        @bitCast(@as(isize, epfd)),
        @intFromPtr(events),
        @as(usize, maxevents),
        @bitCast(@as(isize, timeout)),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Epoll event structure
pub const EpollEvent = uapi.epoll.EpollEvent;

/// Epoll control operations
pub const EPOLL_CTL_ADD = uapi.epoll.EPOLL_CTL_ADD;
pub const EPOLL_CTL_DEL = uapi.epoll.EPOLL_CTL_DEL;
pub const EPOLL_CTL_MOD = uapi.epoll.EPOLL_CTL_MOD;

/// Epoll event flags
pub const EPOLLIN = uapi.epoll.EPOLLIN;
pub const EPOLLOUT = uapi.epoll.EPOLLOUT;
pub const EPOLLERR = uapi.epoll.EPOLLERR;
pub const EPOLLHUP = uapi.epoll.EPOLLHUP;
pub const EPOLLET = uapi.epoll.EPOLLET;
pub const EPOLLONESHOT = uapi.epoll.EPOLLONESHOT;

// =============================================================================
// I/O Multiplexing - select/pselect6
// =============================================================================

/// Synchronous I/O multiplexing
pub fn select(nfds: i32, readfds: ?*[128]u8, writefds: ?*[128]u8, exceptfds: ?*[128]u8, timeout: ?*extern struct { tv_sec: i64, tv_usec: i64 }) SyscallError!usize {
    const ret = primitive.syscall5(
        syscalls.SYS_SELECT,
        @bitCast(@as(isize, nfds)),
        if (readfds) |p| @intFromPtr(p) else 0,
        if (writefds) |p| @intFromPtr(p) else 0,
        if (exceptfds) |p| @intFromPtr(p) else 0,
        if (timeout) |p| @intFromPtr(p) else 0,
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

// =============================================================================
// AT* Family Syscalls (directory-relative operations)
// =============================================================================

/// Create directory relative to directory file descriptor
/// dirfd: directory FD or AT_FDCWD (-100) for current working directory
pub fn mkdirat(dirfd: i32, path: [*:0]const u8, mode: u32) SyscallError!void {
    const ret = primitive.syscall3(syscalls.SYS_MKDIRAT, @bitCast(@as(isize, dirfd)), @intFromPtr(path), mode);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get file status relative to directory file descriptor
/// flags: 0 or AT_SYMLINK_NOFOLLOW (0x100)
pub fn fstatat(dirfd: i32, path: [*:0]const u8, statbuf: *uapi.stat.Stat, flags: i32) SyscallError!void {
    const ret = primitive.syscall4(syscalls.SYS_NEWFSTATAT, @bitCast(@as(isize, dirfd)), @intFromPtr(path), @intFromPtr(statbuf), @bitCast(@as(isize, flags)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Remove file or directory relative to directory FD
/// flags: 0 for file, AT_REMOVEDIR (0x200) for directory
pub fn unlinkat(dirfd: i32, path: [*:0]const u8, flags: i32) SyscallError!void {
    const ret = primitive.syscall3(syscalls.SYS_UNLINKAT, @bitCast(@as(isize, dirfd)), @intFromPtr(path), @bitCast(@as(isize, flags)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Rename file relative to directory file descriptors
pub fn renameat(olddirfd: i32, oldpath: [*:0]const u8, newdirfd: i32, newpath: [*:0]const u8) SyscallError!void {
    const ret = primitive.syscall4(syscalls.SYS_RENAMEAT, @bitCast(@as(isize, olddirfd)), @intFromPtr(oldpath), @bitCast(@as(isize, newdirfd)), @intFromPtr(newpath));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Create hard link relative to directory file descriptors
/// flags: 0 or AT_SYMLINK_FOLLOW (0x400)
pub fn linkat(olddirfd: i32, oldpath: [*:0]const u8, newdirfd: i32, newpath: [*:0]const u8, flags: i32) SyscallError!void {
    const ret = primitive.syscall5(syscalls.SYS_LINKAT, @bitCast(@as(isize, olddirfd)), @intFromPtr(oldpath), @bitCast(@as(isize, newdirfd)), @intFromPtr(newpath), @bitCast(@as(isize, flags)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Create symbolic link relative to directory file descriptor
pub fn symlinkat(target: [*:0]const u8, newdirfd: i32, linkpath: [*:0]const u8) SyscallError!void {
    const ret = primitive.syscall3(syscalls.SYS_SYMLINKAT, @intFromPtr(target), @bitCast(@as(isize, newdirfd)), @intFromPtr(linkpath));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Read symbolic link relative to directory file descriptor
pub fn readlinkat(dirfd: i32, path: [*:0]const u8, buf: [*]u8, bufsiz: usize) SyscallError!size_t {
    const ret = primitive.syscall4(syscalls.SYS_READLINKAT, @bitCast(@as(isize, dirfd)), @intFromPtr(path), @intFromPtr(buf), bufsiz);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Change file permissions relative to directory FD
/// flags: 0 or AT_SYMLINK_NOFOLLOW (0x100) - currently ENOTSUP for AT_SYMLINK_NOFOLLOW
pub fn fchmodat(dirfd: i32, path: [*:0]const u8, mode: u32, flags: i32) SyscallError!void {
    const ret = primitive.syscall4(syscalls.SYS_FCHMODAT, @bitCast(@as(isize, dirfd)), @intFromPtr(path), mode, @bitCast(@as(isize, flags)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// File Descriptor Duplication & Pipes
// =============================================================================

/// Duplicate a file descriptor
pub fn dup(oldfd: i32) SyscallError!i32 {
    const ret = primitive.syscall1(syscalls.SYS_DUP, @bitCast(@as(isize, oldfd)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Duplicate a file descriptor to a specific number
pub fn dup2(oldfd: i32, newfd: i32) SyscallError!i32 {
    const ret = primitive.syscall2(syscalls.SYS_DUP2, @bitCast(@as(isize, oldfd)), @bitCast(@as(isize, newfd)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Create a pipe
pub fn pipe(pipefd: *[2]i32) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_PIPE, @intFromPtr(pipefd));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Create a pipe with flags
pub fn pipe2(pipefd: *[2]i32, flags: i32) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_PIPE2, @intFromPtr(pipefd), @bitCast(@as(isize, flags)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// File control operations
pub fn fcntl(fd: i32, cmd: i32, arg: usize) SyscallError!usize {
    const ret = primitive.syscall3(syscalls.SYS_FCNTL, @bitCast(@as(isize, fd)), @bitCast(@as(isize, cmd)), arg);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Read from file descriptor at a given offset without changing file position
pub fn pread64(fd: i32, buf: [*]u8, count: usize, offset: u64) SyscallError!size_t {
    const ret = primitive.syscall4(syscalls.SYS_PREAD64, @bitCast(@as(isize, fd)), @intFromPtr(buf), count, offset);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// =============================================================================
// File Info Operations (stat, truncate, rename, chmod, link, symlink, readlink)
// =============================================================================

pub const Stat = uapi.stat.Stat;

/// Get file status by path
pub fn stat(path: [*:0]const u8, buf: *Stat) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_STAT, @intFromPtr(path), @intFromPtr(buf));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get file status by file descriptor
pub fn fstat(fd: i32, buf: *Stat) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_FSTAT, @bitCast(@as(isize, fd)), @intFromPtr(buf));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get file status by path (does not follow symlinks)
pub fn lstat(path: [*:0]const u8, buf: *Stat) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_LSTAT, @intFromPtr(path), @intFromPtr(buf));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Truncate a file to a specified length by path
pub fn truncate(path: [*:0]const u8, length: usize) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_TRUNCATE, @intFromPtr(path), length);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Truncate a file to a specified length by file descriptor
pub fn ftruncate(fd: i32, length: usize) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_FTRUNCATE, @bitCast(@as(isize, fd)), length);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Rename a file
pub fn rename(old: [*:0]const u8, new: [*:0]const u8) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_RENAME, @intFromPtr(old), @intFromPtr(new));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Change file permissions
pub fn chmod(path: [*:0]const u8, mode: u32) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_CHMOD, @intFromPtr(path), mode);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Create a hard link
pub fn link(old: [*:0]const u8, new_path: [*:0]const u8) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_LINK, @intFromPtr(old), @intFromPtr(new_path));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Create a symbolic link
pub fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_SYMLINK, @intFromPtr(target), @intFromPtr(linkpath));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Read the target of a symbolic link
pub fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) SyscallError!size_t {
    const ret = primitive.syscall3(syscalls.SYS_READLINK, @intFromPtr(path), @intFromPtr(buf), bufsiz);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// =============================================================================
// Additional Memory Management Syscalls
// =============================================================================

/// Lock all pages in address space
pub fn mlockall(flags: u32) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_MLOCKALL, flags);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Unlock all pages in address space
pub fn munlockall() SyscallError!void {
    const ret = primitive.syscall0(syscalls.SYS_MUNLOCKALL);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get information about which pages are resident in memory
pub fn mincore(addr: [*]u8, length: usize, vec: [*]u8) SyscallError!void {
    const ret = primitive.syscall3(syscalls.SYS_MINCORE, @intFromPtr(addr), length, @intFromPtr(vec));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Advanced I/O Syscalls
// =============================================================================

/// Timespec for ppoll (re-export from time module if available, or define locally)
const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// Wait for events on file descriptors with timeout and signal mask
pub fn ppoll(fds: [*]PollFd, nfds: usize, timeout: ?*const Timespec, sigmask: ?*const u64) SyscallError!usize {
    const ret = primitive.syscall5(
        syscalls.SYS_PPOLL,
        @intFromPtr(fds),
        nfds,
        if (timeout) |t| @intFromPtr(t) else 0,
        if (sigmask) |m| @intFromPtr(m) else 0,
        8  // sigsetsize
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// Alias size_t to usize for compatibility if needed, but usize is standard in Zig.
const size_t = usize;
