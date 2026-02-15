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
pub const O_CLOEXEC: i32 = 0o2000000; // Close-on-exec (same as kernel's fd_mod.O_CLOEXEC)

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

/// Wait for I/O events on epoll instance with signal mask
/// When sigmask is null, behaves identically to epoll_wait.
pub fn epoll_pwait(epfd: i32, events: [*]EpollEvent, maxevents: u32, timeout: i32, sigmask: ?*const u64, sigsetsize: usize) SyscallError!usize {
    const ret = primitive.syscall6(
        syscalls.SYS_EPOLL_PWAIT,
        @bitCast(@as(isize, epfd)),
        @intFromPtr(events),
        @as(usize, maxevents),
        @bitCast(@as(isize, timeout)),
        if (sigmask) |s| @intFromPtr(s) else 0,
        sigsetsize,
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

pub fn pselect6(nfds: i32, readfds: ?*[128]u8, writefds: ?*[128]u8, exceptfds: ?*[128]u8, timeout: ?*const extern struct { tv_sec: i64, tv_nsec: i64 }, sigmask_ptr: usize) SyscallError!usize {
    const ret = primitive.syscall6(
        syscalls.SYS_PSELECT6,
        @bitCast(@as(isize, nfds)),
        if (readfds) |p| @intFromPtr(p) else 0,
        if (writefds) |p| @intFromPtr(p) else 0,
        if (exceptfds) |p| @intFromPtr(p) else 0,
        if (timeout) |p| @intFromPtr(p) else 0,
        sigmask_ptr,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// =============================================================================
// Event Notification File Descriptors
// =============================================================================

/// eventfd2 flags
pub const EFD_CLOEXEC: u32 = 0x80000;
pub const EFD_NONBLOCK: u32 = 0x800;
pub const EFD_SEMAPHORE: u32 = 0x1;

/// Create eventfd with flags
/// Returns a file descriptor for event notification
pub fn eventfd2(initval: u32, flags: u32) SyscallError!i32 {
    const ret = primitive.syscall2(syscalls.SYS_EVENTFD2, @as(usize, initval), @as(usize, flags));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @intCast(@as(isize, @bitCast(ret)));
}

/// Create eventfd with default flags (0)
/// Returns a file descriptor for event notification
pub fn eventfd(initval: u32) SyscallError!i32 {
    return eventfd2(initval, 0);
}

// =============================================================================
// Timer File Descriptors
// =============================================================================

/// Timespec structure (time specification with nanosecond precision)
pub const TimeSpec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// ITimerSpec structure (interval timer specification)
pub const ITimerSpec = extern struct {
    it_interval: TimeSpec, // Timer interval (periodic reload value)
    it_value: TimeSpec,    // Time until next expiration
};

/// timerfd_create flags
pub const TFD_CLOEXEC: u32 = 0x80000; // Close-on-exec
pub const TFD_NONBLOCK: u32 = 0x800;  // Non-blocking mode

/// timerfd_settime flags
pub const TFD_TIMER_ABSTIME: u32 = 0x1; // Absolute time (instead of relative)

/// Clock types
pub const CLOCK_REALTIME: i32 = 0;  // Wall clock time
pub const CLOCK_MONOTONIC: i32 = 1; // Monotonic time (not affected by time jumps)

/// Create a timerfd
/// Returns a file descriptor for timer notification
pub fn timerfd_create(clockid: i32, flags: u32) SyscallError!i32 {
    const ret = primitive.syscall2(
        syscalls.SYS_TIMERFD_CREATE,
        @bitCast(@as(isize, clockid)),
        @as(usize, flags),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @intCast(@as(isize, @bitCast(ret)));
}

/// Arm or disarm a timerfd
/// new_value: New timer settings
/// old_value: Optional pointer to receive old timer settings (null = ignore)
pub fn timerfd_settime(fd: i32, flags: u32, new_value: *const ITimerSpec, old_value: ?*ITimerSpec) SyscallError!void {
    const ret = primitive.syscall4(
        syscalls.SYS_TIMERFD_SETTIME,
        @bitCast(@as(isize, fd)),
        @as(usize, flags),
        @intFromPtr(new_value),
        if (old_value) |p| @intFromPtr(p) else 0,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get current timer settings
/// curr_value: Pointer to receive current timer settings
pub fn timerfd_gettime(fd: i32, curr_value: *ITimerSpec) SyscallError!void {
    const ret = primitive.syscall2(
        syscalls.SYS_TIMERFD_GETTIME,
        @bitCast(@as(isize, fd)),
        @intFromPtr(curr_value),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Signal FDs
// =============================================================================

/// signalfd4 flags
pub const SFD_CLOEXEC: u32 = 0x80000; // Close-on-exec
pub const SFD_NONBLOCK: u32 = 0x800;  // Non-blocking mode

/// Signal information structure returned by read() on signalfd
/// Must be exactly 128 bytes to match Linux ABI
pub const SignalFdSigInfo = extern struct {
    ssi_signo: u32,     // Signal number
    ssi_errno: i32,     // Error number (usually 0)
    ssi_code: i32,      // Signal code (SI_USER, SI_KERNEL, etc.)
    ssi_pid: u32,       // PID of sender
    ssi_uid: u32,       // Real UID of sender
    ssi_fd: i32,        // File descriptor (for SIGIO)
    ssi_tid: u32,       // Kernel timer ID (for timer signals)
    ssi_band: u32,      // Band event (for SIGIO)
    ssi_overrun: u32,   // Timer overrun count (for timer signals)
    ssi_trapno: u32,    // Trap number that caused signal
    ssi_status: i32,    // Exit status or signal (for SIGCHLD)
    ssi_int: i32,       // Integer sent with sigqueue()
    ssi_ptr: u64,       // Pointer sent with sigqueue()
    ssi_utime: u64,     // User CPU time consumed (for SIGCHLD)
    ssi_stime: u64,     // System CPU time consumed (for SIGCHLD)
    ssi_addr: u64,      // Address that caused fault
    ssi_addr_lsb: u16,  // Least significant bit of address
    _pad: [46]u8,       // Padding to 128 bytes

    comptime {
        const std_imported = @import("std");
        // Verify struct layout matches Linux ABI (128 bytes exactly)
        std_imported.debug.assert(@sizeOf(SignalFdSigInfo) == 128);
    }
};

/// Create a signalfd or update an existing one
/// fd: -1 to create new, >= 0 to update existing signalfd mask
/// mask: Pointer to u64 signal mask
/// flags: SFD_CLOEXEC | SFD_NONBLOCK
/// Returns: file descriptor number
pub fn signalfd4(fd: i32, mask: *const u64, flags: u32) SyscallError!i32 {
    const ret = primitive.syscall4(
        syscalls.SYS_SIGNALFD4,
        @bitCast(@as(isize, fd)),
        @intFromPtr(mask),
        @sizeOf(u64), // sizemask parameter
        @as(usize, flags),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @intCast(@as(isize, @bitCast(ret)));
}

/// Create a signalfd without flags (legacy)
/// Equivalent to signalfd4(fd, mask, 0)
pub fn signalfd(fd: i32, mask: *const u64) SyscallError!i32 {
    return signalfd4(fd, mask, 0);
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

/// MFD_CLOEXEC flag for memfd_create
pub const MFD_CLOEXEC: u32 = 0x0001;
/// MFD_ALLOW_SEALING flag for memfd_create
pub const MFD_ALLOW_SEALING: u32 = 0x0002;

/// MREMAP flags
pub const MREMAP_MAYMOVE: u32 = 1;

/// Create an anonymous memory-backed file descriptor
pub fn memfd_create(name: [*:0]const u8, flags: u32) SyscallError!i32 {
    const ret = primitive.syscall2(
        syscalls.SYS_MEMFD_CREATE,
        @intFromPtr(name),
        flags,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @intCast(ret);
}

/// Remap a virtual memory region
pub fn mremap(old_addr: [*]u8, old_size: usize, new_size: usize, flags: u32) SyscallError![*]u8 {
    const ret = primitive.syscall4(
        syscalls.SYS_MREMAP,
        @intFromPtr(old_addr),
        old_size,
        new_size,
        flags,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @ptrFromInt(ret);
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
// File Timestamp Syscalls
// =============================================================================

/// Special tv_nsec values for utimensat
pub const UTIME_NOW: i64 = (1 << 30) - 1; // 0x3fffffff
pub const UTIME_OMIT: i64 = (1 << 30) - 2; // 0x3ffffffe

/// Set file timestamps with nanosecond precision relative to directory FD
/// times: pointer to [2]Timespec (atime, mtime), or null to set both to current time
/// flags: 0 or AT_SYMLINK_NOFOLLOW (0x100)
pub fn utimensat(dirfd: i32, path: [*:0]const u8, times: ?*const [2]primitive.uapi.abi.Timespec, flags: i32) SyscallError!void {
    const times_ptr: usize = if (times) |t| @intFromPtr(t) else 0;
    const ret = primitive.syscall4(syscalls.SYS_UTIMENSAT, @bitCast(@as(isize, dirfd)), @intFromPtr(path), times_ptr, @bitCast(@as(isize, flags)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set file timestamps with microsecond precision relative to directory FD (legacy)
/// times: pointer to [2]Timeval (atime, mtime), or null to set both to current time
/// Note: Uses Timeval from time module
pub fn futimesat(dirfd: i32, path: [*:0]const u8, times: ?*const [2]@import("time.zig").Timeval) SyscallError!void {
    const times_ptr: usize = if (times) |t| @intFromPtr(t) else 0;
    const ret = primitive.syscall3(syscalls.SYS_FUTIMESAT, @bitCast(@as(isize, dirfd)), @intFromPtr(path), times_ptr);
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

/// Duplicate a file descriptor with flags (O_CLOEXEC)
pub fn dup3(oldfd: i32, newfd: i32, flags: i32) SyscallError!i32 {
    const ret = primitive.syscall3(
        syscalls.SYS_DUP3,
        @bitCast(@as(isize, oldfd)),
        @bitCast(@as(isize, newfd)),
        @bitCast(@as(isize, flags)),
    );
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

/// Write to file descriptor at a given offset without changing file position
pub fn pwrite64(fd: i32, buf: [*]const u8, count: usize, offset: u64) SyscallError!size_t {
    const ret = primitive.syscall4(syscalls.SYS_PWRITE64, @bitCast(@as(isize, fd)), @intFromPtr(buf), count, offset);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Read data into multiple buffers (scatter-gather read)
/// Returns total bytes read, or error
pub fn readv(fd: i32, iov: []const Iovec) SyscallError!size_t {
    const ret = primitive.syscall3(
        syscalls.SYS_READV,
        @bitCast(@as(isize, fd)),
        @intFromPtr(iov.ptr),
        iov.len,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Read into multiple buffers at a given offset (vectored positional read)
/// Returns total bytes read, or error
pub fn preadv(fd: i32, iov: []const Iovec, offset: u64) SyscallError!size_t {
    const ret = primitive.syscall4(
        syscalls.SYS_PREADV,
        @bitCast(@as(isize, fd)),
        @intFromPtr(iov.ptr),
        iov.len,
        offset,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Write from multiple buffers at a given offset (vectored positional write)
/// Returns total bytes written, or error
pub fn pwritev(fd: i32, iov: []const Iovec, offset: u64) SyscallError!size_t {
    const ret = primitive.syscall4(
        syscalls.SYS_PWRITEV,
        @bitCast(@as(isize, fd)),
        @intFromPtr(iov.ptr),
        iov.len,
        offset,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// RWF_* flags for preadv2/pwritev2
pub const RWF_HIPRI: u32 = 0x00000001;
pub const RWF_DSYNC: u32 = 0x00000002;
pub const RWF_SYNC: u32 = 0x00000004;
pub const RWF_NOWAIT: u32 = 0x00000008;
pub const RWF_APPEND: u32 = 0x00000010;

/// Read into multiple buffers at a given offset with flags (extended vectored positional read)
/// offset=-1 uses current file position
/// Returns total bytes read, or error
pub fn preadv2(fd: i32, iov: []const Iovec, offset: i64, flags: u32) SyscallError!size_t {
    const ret = primitive.syscall5(
        syscalls.SYS_PREADV2,
        @bitCast(@as(isize, fd)),
        @intFromPtr(iov.ptr),
        iov.len,
        @bitCast(offset),
        @as(usize, flags),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Write from multiple buffers at a given offset with flags (extended vectored positional write)
/// offset=-1 uses current file position
/// Returns total bytes written, or error
pub fn pwritev2(fd: i32, iov: []const Iovec, offset: i64, flags: u32) SyscallError!size_t {
    const ret = primitive.syscall5(
        syscalls.SYS_PWRITEV2,
        @bitCast(@as(isize, fd)),
        @intFromPtr(iov.ptr),
        iov.len,
        @bitCast(offset),
        @as(usize, flags),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Transfer data from file to file descriptor (zero-copy)
/// offset: optional pointer to read position (updated on success), null for current position
/// Returns total bytes transferred, or error
pub fn sendfile(out_fd: i32, in_fd: i32, offset: ?*u64, count: usize) SyscallError!size_t {
    const offset_ptr: usize = if (offset) |o| @intFromPtr(o) else 0;
    const ret = primitive.syscall4(
        syscalls.SYS_SENDFILE,
        @bitCast(@as(isize, out_fd)),
        @bitCast(@as(isize, in_fd)),
        offset_ptr,
        count,
    );
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

// =============================================================================
// Filesystem Statistics (statfs, fstatfs)
// =============================================================================

pub const Statfs = uapi.stat.Statfs;

/// Get filesystem statistics by path
pub fn statfs(path: [*:0]const u8, buf: *Statfs) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_STATFS, @intFromPtr(path), @intFromPtr(buf));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get filesystem statistics by file descriptor
pub fn fstatfs(fd: i32, buf: *Statfs) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_FSTATFS, @bitCast(@as(isize, fd)), @intFromPtr(buf));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// File Synchronization Syscalls (fsync, fdatasync, sync, syncfs)
// =============================================================================

/// Synchronize a file's in-core state with storage device
/// Flushes both data and metadata to disk
pub fn fsync(fd: i32) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_FSYNC, @bitCast(@as(isize, fd)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Synchronize a file's data with storage device
/// Like fsync, but skips non-essential metadata (e.g., atime)
pub fn fdatasync(fd: i32) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_FDATASYNC, @bitCast(@as(isize, fd)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Commit filesystem caches to disk (global flush)
/// Cannot fail per POSIX semantics
pub fn sync_() void {
    _ = primitive.syscall0(syscalls.SYS_SYNC);
}

/// Synchronize a filesystem
/// Flushes all buffers for the filesystem containing the given fd
pub fn syncfs(fd: i32) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_SYNCFS, @bitCast(@as(isize, fd)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Advanced File Operations (fallocate, renameat2)
// =============================================================================

pub const FALLOC_FL_KEEP_SIZE: u32 = 0x01;
pub const FALLOC_FL_PUNCH_HOLE: u32 = 0x02;

pub const RENAME_NOREPLACE: u32 = 1;
pub const RENAME_EXCHANGE: u32 = 2;

/// Pre-allocate or manipulate file space
pub fn fallocate(fd: i32, mode: u32, offset: i64, len: i64) SyscallError!void {
    const ret = primitive.syscall4(syscalls.SYS_FALLOCATE, @bitCast(@as(isize, fd)), @as(usize, mode), @bitCast(offset), @bitCast(len));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Rename file with flags (RENAME_NOREPLACE, RENAME_EXCHANGE)
pub fn renameat2(olddirfd: i32, oldpath: [*:0]const u8, newdirfd: i32, newpath: [*:0]const u8, flags: u32) SyscallError!void {
    const ret = primitive.syscall5(syscalls.SYS_RENAMEAT2, @bitCast(@as(isize, olddirfd)), @intFromPtr(oldpath), @bitCast(@as(isize, newdirfd)), @intFromPtr(newpath), @as(usize, flags));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Zero-Copy I/O (splice, tee, vmsplice, copy_file_range)
// =============================================================================

// Zero-copy I/O constants
pub const SPLICE_F_MOVE: u32 = 1;
pub const SPLICE_F_NONBLOCK: u32 = 2;
pub const SPLICE_F_MORE: u32 = 4;
pub const SPLICE_F_GIFT: u32 = 8;

/// Move data between a file descriptor and a pipe (kernel-side copy)
pub fn splice(fd_in: i32, off_in: ?*u64, fd_out: i32, off_out: ?*u64, len: usize, flags: u32) SyscallError!size_t {
    const ret = primitive.syscall6(
        syscalls.SYS_SPLICE,
        @bitCast(@as(isize, fd_in)),
        if (off_in) |p| @intFromPtr(p) else 0,
        @bitCast(@as(isize, fd_out)),
        if (off_out) |p| @intFromPtr(p) else 0,
        len,
        @as(usize, flags),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Duplicate pipe data without consuming the source
pub fn tee(fd_in: i32, fd_out: i32, len: usize, flags: u32) SyscallError!size_t {
    const ret = primitive.syscall4(
        syscalls.SYS_TEE,
        @bitCast(@as(isize, fd_in)),
        @bitCast(@as(isize, fd_out)),
        len,
        @as(usize, flags),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Splice user pages into a pipe
pub fn vmsplice(fd: i32, iov: []const Iovec, flags: u32) SyscallError!size_t {
    const ret = primitive.syscall4(
        syscalls.SYS_VMSPLICE,
        @bitCast(@as(isize, fd)),
        @intFromPtr(iov.ptr),
        iov.len,
        @as(usize, flags),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Copy data between two files within the kernel
pub fn copy_file_range(fd_in: i32, off_in: ?*u64, fd_out: i32, off_out: ?*u64, len: usize, flags: u32) SyscallError!size_t {
    const ret = primitive.syscall6(
        syscalls.SYS_COPY_FILE_RANGE,
        @bitCast(@as(isize, fd_in)),
        if (off_in) |p| @intFromPtr(p) else 0,
        @bitCast(@as(isize, fd_out)),
        if (off_out) |p| @intFromPtr(p) else 0,
        len,
        @as(usize, flags),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// Alias size_t to usize for compatibility if needed, but usize is standard in Zig.
const size_t = usize;
