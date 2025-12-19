// Zscapek Userland Syscall Wrappers
//
// Provides type-safe wrappers around x86_64 syscall instruction.
// All syscall numbers are imported from uapi to ensure kernel/userland consistency.
//
// Register Convention (x86_64 Linux ABI):
//   Entry:  RAX=number, RDI=arg1, RSI=arg2, RDX=arg3, R10=arg4, R8=arg5, R9=arg6
//   Return: RAX=result (or negative errno on error)
//   Clobbers: RCX, R11 (used by syscall instruction)
//
// Note: R10 is used instead of RCX for arg4 because syscall clobbers RCX

const std = @import("std");
pub const uapi = @import("uapi");
const syscalls = uapi.syscalls;
const Errno = uapi.errno.Errno;

/// Memory barrier for x86_64 userspace
inline fn memoryBarrier() void {
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );
}

/// Timespec structure for nanosleep and clock_gettime
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// Clock IDs for clock_gettime
pub const ClockId = enum(i32) {
    REALTIME = 0,
    MONOTONIC = 1,
    PROCESS_CPUTIME_ID = 2,
    THREAD_CPUTIME_ID = 3,
    MONOTONIC_RAW = 4,
    REALTIME_COARSE = 5,
    MONOTONIC_COARSE = 6,
    BOOTTIME = 7,
};

// =============================================================================
// Raw Syscall Primitives
// =============================================================================

/// Execute syscall with 0 arguments
pub inline fn syscall0(number: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 1 argument
pub inline fn syscall1(number: usize, arg1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 2 arguments
pub inline fn syscall2(number: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 3 arguments
pub inline fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 4 arguments
/// Note: R10 is used instead of RCX because syscall clobbers RCX
pub inline fn syscall4(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 5 arguments
pub inline fn syscall5(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
          [arg5] "{r8}" (arg5),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 6 arguments
pub inline fn syscall6(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
          [arg5] "{r8}" (arg5),
          [arg6] "{r9}" (arg6),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

// =============================================================================
// Error Handling
// =============================================================================

/// Result type for syscalls that can fail
pub const SyscallError = error{
    PermissionDenied,
    NoSuchFileOrDirectory,
    NoSuchProcess,
    Interrupted,
    IoError,
    NoSuchDevice,
    ArgumentListTooLong,
    ExecFormatError,
    BadFileDescriptor,
    NoChildProcesses,
    WouldBlock,
    OutOfMemory,
    AccessDenied,
    BadAddress,
    DeviceBusy,
    FileExists,
    InvalidArgument,
    TooManyOpenFiles,
    NotImplemented,
    Unexpected,
};

/// Convert raw syscall return value to error union
pub fn errorFromReturn(ret: usize) SyscallError {
    const err: isize = @bitCast(ret);
    if (err >= 0) return error.Unexpected;

    const errno_val: i32 = @truncate(-err);
    return switch (errno_val) {
        1 => error.PermissionDenied,
        2 => error.NoSuchFileOrDirectory,
        3 => error.NoSuchProcess,
        4 => error.Interrupted,
        5 => error.IoError,
        6 => error.NoSuchDevice,
        7 => error.ArgumentListTooLong,
        8 => error.ExecFormatError,
        9 => error.BadFileDescriptor,
        10 => error.NoChildProcesses,
        11 => error.WouldBlock,
        12 => error.OutOfMemory,
        13 => error.AccessDenied,
        14 => error.BadAddress,
        16 => error.DeviceBusy,
        17 => error.FileExists,
        22 => error.InvalidArgument,
        24 => error.TooManyOpenFiles,
        38 => error.NotImplemented,
        else => error.Unexpected,
    };
}

/// Check if return value indicates error (negative)
pub inline fn isError(ret: usize) bool {
    const signed: isize = @bitCast(ret);
    return signed < 0 and signed >= -4096;
}

// =============================================================================
// Basic I/O Syscalls (sys_read, sys_write)
// =============================================================================

/// Read from file descriptor
/// Returns number of bytes read, or error
pub fn read(fd: i32, buf: [*]u8, count: usize) SyscallError!usize {
    const ret = syscall3(syscalls.SYS_READ, @bitCast(@as(isize, fd)), @intFromPtr(buf), count);
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

/// Write to file descriptor
/// Returns number of bytes written, or error
pub fn write(fd: i32, buf: [*]const u8, count: usize) SyscallError!usize {
    const ret = syscall3(syscalls.SYS_WRITE, @bitCast(@as(isize, fd)), @intFromPtr(buf), count);
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

/// Write string to file descriptor (convenience wrapper)
pub fn writeString(fd: i32, str: []const u8) SyscallError!usize {
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
pub fn writev(fd: i32, iov: []const Iovec) SyscallError!usize {
    const ret = syscall3(
        syscalls.SYS_WRITEV,
        @bitCast(@as(isize, fd)),
        @intFromPtr(iov.ptr),
        iov.len,
    );
    if (isError(ret)) return errorFromReturn(ret);
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
    const ret = syscall3(syscalls.SYS_LSEEK, @bitCast(@as(isize, fd)), @bitCast(offset), @bitCast(@as(isize, whence)));
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

/// Open a file
pub fn open(path: [*:0]const u8, flags: i32, mode: u32) SyscallError!i32 {
    const ret = syscall3(syscalls.SYS_OPEN, @intFromPtr(path), @bitCast(@as(isize, flags)), mode);
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Close a file descriptor
pub fn close(fd: i32) SyscallError!void {
    const ret = syscall1(syscalls.SYS_CLOSE, @bitCast(@as(isize, fd)));
    if (isError(ret)) return errorFromReturn(ret);
}

/// Check user's permissions for a file
pub fn access(path: [*:0]const u8, mode: i32) SyscallError!void {
    const ret = syscall2(syscalls.SYS_ACCESS, @intFromPtr(path), @bitCast(@as(isize, mode)));
    if (isError(ret)) return errorFromReturn(ret);
}

/// Device control
pub fn ioctl(fd: i32, cmd: u32, arg: usize) SyscallError!i32 {
    const ret = syscall3(syscalls.SYS_IOCTL, @bitCast(@as(isize, fd)), cmd, arg);
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

// =============================================================================
// Process Control (sys_exit, sys_getpid)
// =============================================================================

/// Exit the process
/// This function never returns
pub fn exit(status: i32) noreturn {
    _ = syscall1(syscalls.SYS_EXIT, @bitCast(@as(isize, status)));
    unreachable;
}

/// Exit all threads in the process group
pub fn exit_group(status: i32) noreturn {
    _ = syscall1(syscalls.SYS_EXIT_GROUP, @bitCast(@as(isize, status)));
    unreachable;
}

pub const ARCH_SET_FS: usize = 0x1002;
pub const ARCH_GET_FS: usize = 0x1003;

pub fn arch_prctl(code: usize, addr: usize) SyscallError!void {
    const ret = syscall2(syscalls.SYS_ARCH_PRCTL, code, addr);
    if (isError(ret)) return errorFromReturn(ret);
}

// Signal handling
pub const SigAction = uapi.signal.SigAction;
pub const SigSet = uapi.signal.SigSet;

pub fn kill(pid: i32, sig: i32) SyscallError!void {
    const ret = syscall2(syscalls.SYS_KILL, @bitCast(@as(isize, pid)), @bitCast(@as(isize, sig)));
    if (isError(ret)) return errorFromReturn(ret);
}

pub fn sigaction(sig: i32, act: ?*const SigAction, oldact: ?*SigAction) SyscallError!void {
    const ret = syscall4(syscalls.SYS_RT_SIGACTION,
        @bitCast(@as(isize, sig)),
        if (act) |a| @intFromPtr(a) else 0,
        if (oldact) |a| @intFromPtr(a) else 0,
        @sizeOf(SigSet)
    );
    if (isError(ret)) return errorFromReturn(ret);
}

pub fn sigprocmask(how: i32, set: ?*const SigSet, oldset: ?*SigSet) SyscallError!void {
    const ret = syscall4(syscalls.SYS_RT_SIGPROCMASK,
        @bitCast(@as(isize, how)),
        if (set) |s| @intFromPtr(s) else 0,
        if (oldset) |s| @intFromPtr(s) else 0,
        @sizeOf(SigSet)
    );
    if (isError(ret)) return errorFromReturn(ret);
}

// sigreturn is weird because it doesn't return, but we shouldn't really call it from C manually usually.
// It's used by the kernel trampoline. But if we need it:
pub fn sigreturn() noreturn {
    _ = syscall0(syscalls.SYS_RT_SIGRETURN);
    unreachable;
}

/// Get process ID
pub fn getpid() i32 {
    const ret = syscall0(syscalls.SYS_GETPID);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Get parent process ID
pub fn getppid() i32 {
    const ret = syscall0(syscalls.SYS_GETPPID);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Get user ID
pub fn getuid() u32 {
    const ret = syscall0(syscalls.SYS_GETUID);
    return @truncate(ret);
}

/// Get group ID
pub fn getgid() u32 {
    const ret = syscall0(syscalls.SYS_GETGID);
    return @truncate(ret);
}

// =============================================================================
// Memory Management (sys_brk)
// =============================================================================

/// Change data segment size (heap)
/// brk(0) returns current break address
/// brk(addr) sets new break and returns new break (or error)
pub fn brk(addr: usize) SyscallError!usize {
    const ret = syscall1(syscalls.SYS_BRK, addr);
    // brk returns the new break address, or the current one if it failed
    // We need to check if it actually changed
    if (addr != 0 and ret != addr) {
        // Request to change break failed
        return error.OutOfMemory;
    }
    return ret;
}

/// Simple sbrk-like interface
/// Increments program break by `increment` bytes
/// Returns pointer to start of new memory, or error
pub fn sbrk(increment: isize) SyscallError![*]u8 {
    const current = try brk(0);
    if (increment == 0) {
        return @ptrFromInt(current);
    }

    const new_break: usize = if (increment > 0)
        current + @as(usize, @intCast(increment))
    else
        current - @as(usize, @intCast(-increment));

    _ = try brk(new_break);
    return @ptrFromInt(current);
}

// =============================================================================
// Scheduling (sys_sched_yield, sys_nanosleep)
// =============================================================================

/// Yield the processor to other threads
pub fn sched_yield() SyscallError!void {
    const ret = syscall0(syscalls.SYS_SCHED_YIELD);
    if (isError(ret)) return errorFromReturn(ret);
}

/// High-resolution sleep
/// Sleeps for the time specified in `req`
/// If interrupted, remaining time is stored in `rem` (if non-null)
pub fn nanosleep(req: *const Timespec, rem: ?*Timespec) SyscallError!void {
    const rem_ptr: usize = if (rem) |r| @intFromPtr(r) else 0;
    const ret = syscall2(syscalls.SYS_NANOSLEEP, @intFromPtr(req), rem_ptr);
    if (isError(ret)) return errorFromReturn(ret);
}

/// Sleep for specified number of milliseconds
pub fn sleep_ms(ms: u64) SyscallError!void {
    const req = Timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1_000_000),
    };
    try nanosleep(&req, null);
}

// =============================================================================
// Time (sys_clock_gettime)
// =============================================================================

/// Get time from a clock
pub fn clock_gettime(clk_id: ClockId, tp: *Timespec) SyscallError!void {
    const ret = syscall2(syscalls.SYS_CLOCK_GETTIME, @bitCast(@as(isize, @intFromEnum(clk_id))), @intFromPtr(tp));
    if (isError(ret)) return errorFromReturn(ret);
}

/// Get monotonic time in milliseconds (convenience wrapper)
pub fn gettime_ms() SyscallError!u64 {
    var ts: Timespec = undefined;
    try clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
}

// =============================================================================
// Random (sys_getrandom)
// =============================================================================

/// Flags for getrandom
pub const GRND_NONBLOCK: u32 = 1;
pub const GRND_RANDOM: u32 = 2;

/// Get random bytes from kernel
pub fn getrandom(buf: [*]u8, count: usize, flags: u32) SyscallError!usize {
    const ret = syscall3(syscalls.SYS_GETRANDOM, @intFromPtr(buf), count, flags);
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

// =============================================================================
// Zscapek Custom Extensions (1000+)
// =============================================================================

/// Framebuffer info structure
/// Contains dimensions, pitch, bits per pixel, and RGB channel layout.
/// Use red/green/blue_shift and _mask_size to construct pixel values:
///   pixel = (red << red_shift) | (green << green_shift) | (blue << blue_shift)
pub const FramebufferInfo = extern struct {
    /// Width in pixels
    width: u32,
    /// Height in pixels
    height: u32,
    /// Bytes per scanline (may include padding beyond width * bytes_per_pixel)
    pitch: u32,
    /// Bits per pixel (typically 32 for modern displays)
    bpp: u32,
    /// Bit position of red channel (e.g., 16 for BGRA)
    red_shift: u8,
    /// Number of bits in red channel (typically 8)
    red_mask_size: u8,
    /// Bit position of green channel (e.g., 8 for BGRA)
    green_shift: u8,
    /// Number of bits in green channel (typically 8)
    green_mask_size: u8,
    /// Bit position of blue channel (e.g., 0 for BGRA)
    blue_shift: u8,
    /// Number of bits in blue channel (typically 8)
    blue_mask_size: u8,
    /// Reserved for alignment
    _reserved: [2]u8 = .{ 0, 0 },
};

/// Write debug message to kernel log
pub fn debug_log(buf: [*]const u8, len: usize) SyscallError!usize {
    const ret = syscall2(syscalls.SYS_DEBUG_LOG, @intFromPtr(buf), len);
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

/// Write debug string to kernel log (convenience wrapper)
pub fn debug_print(str: []const u8) void {
    _ = debug_log(str.ptr, str.len) catch {};
}

/// Get framebuffer info
pub fn get_framebuffer_info(info: *FramebufferInfo) SyscallError!void {
    const ret = syscall1(syscalls.SYS_GET_FB_INFO, @intFromPtr(info));
    if (isError(ret)) return errorFromReturn(ret);
}

/// Map framebuffer into process address space
pub fn map_framebuffer() SyscallError![*]u8 {
    const ret = syscall0(syscalls.SYS_MAP_FB);
    if (isError(ret)) return errorFromReturn(ret);
    return @ptrFromInt(ret);
}

/// Read raw keyboard scancode (non-blocking)
/// Returns scancode or WouldBlock if no key available
pub fn read_scancode() SyscallError!u8 {
    const ret = syscall0(syscalls.SYS_READ_SCANCODE);
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(ret);
}

/// Read ASCII character from input buffer (blocking)
pub fn getchar() SyscallError!u8 {
    const ret = syscall0(syscalls.SYS_GETCHAR);
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(ret);
}

/// Write character to console
pub fn putchar(c: u8) SyscallError!void {
    const ret = syscall1(syscalls.SYS_PUTCHAR, c);
    if (isError(ret)) return errorFromReturn(ret);
}

// =============================================================================
// Standard File Descriptors
// =============================================================================

pub const STDIN_FILENO: i32 = 0;
pub const STDOUT_FILENO: i32 = 1;
pub const STDERR_FILENO: i32 = 2;

/// Write to stdout (convenience wrapper)
pub fn print(str: []const u8) void {
    _ = write(STDOUT_FILENO, str.ptr, str.len) catch {};
}

/// Write to stderr (convenience wrapper)
pub fn eprint(str: []const u8) void {
    _ = write(STDERR_FILENO, str.ptr, str.len) catch {};
}

// =============================================================================
// Socket Operations (sys_socket, sys_bind, sys_sendto, sys_recvfrom)
// =============================================================================

/// Address family constants
pub const AF_INET: i32 = 2;

/// Socket type constants
pub const SOCK_STREAM: i32 = 1; // TCP
pub const SOCK_DGRAM: i32 = 2; // UDP

/// Socket address structure (IPv4)
/// Compatible with Linux sockaddr_in
pub const SockAddrIn = extern struct {
    family: u16, // AF_INET
    port: u16, // Network byte order
    addr: u32, // Network byte order
    zero: [8]u8, // Padding

    /// Create sockaddr from IP (host order) and port (host order)
    pub fn init(ip: u32, port_host: u16) SockAddrIn {
        return .{
            .family = @as(u16, @intCast(AF_INET)),
            .port = @byteSwap(port_host),
            .addr = @byteSwap(ip),
            .zero = [_]u8{0} ** 8,
        };
    }

    /// Get port in host byte order
    pub fn getPort(self: *const SockAddrIn) u16 {
        return @byteSwap(self.port);
    }

    /// Get address in host byte order
    pub fn getAddr(self: *const SockAddrIn) u32 {
        return @byteSwap(self.addr);
    }
};

/// Create a socket
/// Returns socket file descriptor (>= 3) or error
pub fn socket(domain: i32, sock_type: i32, protocol: i32) SyscallError!i32 {
    const ret = syscall3(
        syscalls.SYS_SOCKET,
        @bitCast(@as(isize, domain)),
        @bitCast(@as(isize, sock_type)),
        @bitCast(@as(isize, protocol)),
    );
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Bind socket to local address
pub fn bind(fd: i32, addr: *const SockAddrIn) SyscallError!void {
    const ret = syscall3(
        syscalls.SYS_BIND,
        @bitCast(@as(isize, fd)),
        @intFromPtr(addr),
        @sizeOf(SockAddrIn),
    );
    if (isError(ret)) return errorFromReturn(ret);
}

/// Send data on socket to destination
/// Returns number of bytes sent
pub fn sendto(fd: i32, buf: []const u8, dest_addr: *const SockAddrIn) SyscallError!usize {
    const ret = syscall6(
        syscalls.SYS_SENDTO,
        @bitCast(@as(isize, fd)),
        @intFromPtr(buf.ptr),
        buf.len,
        0, // flags
        @intFromPtr(dest_addr),
        @sizeOf(SockAddrIn),
    );
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

/// Receive data from socket
/// Returns number of bytes received
/// src_addr is filled with sender's address if non-null
pub fn recvfrom(fd: i32, buf: []u8, src_addr: ?*SockAddrIn) SyscallError!usize {
    var addrlen: u32 = @sizeOf(SockAddrIn);
    const src_addr_ptr: usize = if (src_addr) |a| @intFromPtr(a) else 0;
    const addrlen_ptr: usize = if (src_addr != null) @intFromPtr(&addrlen) else 0;

    const ret = syscall6(
        syscalls.SYS_RECVFROM,
        @bitCast(@as(isize, fd)),
        @intFromPtr(buf.ptr),
        buf.len,
        0, // flags
        src_addr_ptr,
        addrlen_ptr,
    );
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

/// Parse dotted-decimal IP string to u32 (host byte order)
pub fn parseIp(str: []const u8) ?u32 {
    var ip: u32 = 0;
    var octet: u32 = 0;
    var dot_count: usize = 0;

    for (str) |c| {
        if (c >= '0' and c <= '9') {
            octet = octet * 10 + (c - '0');
            if (octet > 255) return null;
        } else if (c == '.') {
            ip = (ip << 8) | octet;
            octet = 0;
            dot_count += 1;
            if (dot_count > 3) return null;
        } else {
            return null;
        }
    }

    if (dot_count != 3) return null;
    ip = (ip << 8) | octet;
    return ip;
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
    const ret = syscall3(
        syscalls.SYS_POLL,
        @intFromPtr(ufds.ptr),
        ufds.len,
        @bitCast(@as(isize, timeout))
    );
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

// TCP specific syscalls (accept, listen, shutdown, connect)

/// Listen for connections on a socket
pub fn listen(fd: i32, backlog: i32) SyscallError!void {
    const ret = syscall2(syscalls.SYS_LISTEN, @bitCast(@as(isize, fd)), @bitCast(@as(isize, backlog)));
    if (isError(ret)) return errorFromReturn(ret);
}

/// Accept a connection on a socket
/// Returns new file descriptor for the connection
pub fn accept(fd: i32, addr: ?*SockAddrIn) SyscallError!i32 {
    var addrlen: u32 = @sizeOf(SockAddrIn);
    const addr_ptr: usize = if (addr) |a| @intFromPtr(a) else 0;
    const addrlen_ptr: usize = if (addr != null) @intFromPtr(&addrlen) else 0;
    
    const ret = syscall3(syscalls.SYS_ACCEPT, @bitCast(@as(isize, fd)), addr_ptr, addrlen_ptr);
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Initiate a connection on a socket
pub fn connect(fd: i32, addr: *const SockAddrIn) SyscallError!void {
    const ret = syscall3(
        syscalls.SYS_CONNECT, 
        @bitCast(@as(isize, fd)), 
        @intFromPtr(addr), 
        @sizeOf(SockAddrIn)
    );
    if (isError(ret)) return errorFromReturn(ret);
}

/// Shut down part of a full-duplex connection
/// how: 0=SHUT_RD, 1=SHUT_WR, 2=SHUT_RDWR
pub fn shutdown(fd: i32, how: i32) SyscallError!void {
     const ret = syscall2(syscalls.SYS_SHUTDOWN, @bitCast(@as(isize, fd)), @bitCast(@as(isize, how)));
     if (isError(ret)) return errorFromReturn(ret);
}

// =============================================================================
// Input/Mouse Syscalls (1010-1019)
// =============================================================================

/// Read next input event (non-blocking)
/// Returns EAGAIN if no event available
pub fn read_input_event(event: *uapi.input.InputEvent) SyscallError!void {
    const ret = syscall1(syscalls.SYS_READ_INPUT_EVENT, @intFromPtr(event));
    if (isError(ret)) return errorFromReturn(ret);
}

/// Get current cursor position
pub fn get_cursor_position(pos: *uapi.input.CursorPosition) SyscallError!void {
    const ret = syscall1(syscalls.SYS_GET_CURSOR_POSITION, @intFromPtr(pos));
    if (isError(ret)) return errorFromReturn(ret);
}

/// Set cursor bounds (screen dimensions)
pub fn set_cursor_bounds(width: u32, height: u32) SyscallError!void {
    // We construct the struct on stack and pass pointer
    // The syscall implementation in kernel handles copy_from_user
    const bounds = uapi.input.CursorBounds{
        .width = width,
        .height = height,
    };
    const ret = syscall1(syscalls.SYS_SET_CURSOR_BOUNDS, @intFromPtr(&bounds));
    if (isError(ret)) return errorFromReturn(ret);
}

/// Set input mode
/// mode: 0=relative, 1=absolute, 2=raw
pub fn set_input_mode(mode: uapi.input.InputMode) SyscallError!void {
    const ret = syscall1(syscalls.SYS_SET_INPUT_MODE, @intFromEnum(mode));
    if (isError(ret)) return errorFromReturn(ret);
}

// =============================================================================
// DMA/MMIO Syscalls (1030-1032)
// =============================================================================

/// Result from alloc_dma syscall
pub const DmaAllocResult = extern struct {
    /// Virtual address in userspace
    virt_addr: u64,
    /// Physical address for device programming
    phys_addr: u64,
    /// Size in bytes (page-aligned)
    size: u64,
};

/// Map a physical MMIO region into userspace
/// phys_addr must be page-aligned. Requires Mmio capability.
/// Returns virtual address or error.
pub fn mmap_phys(phys_addr: u64, size: usize) SyscallError!*anyopaque {
    const ret = syscall2(syscalls.SYS_MMAP_PHYS, @intCast(phys_addr), size);
    if (isError(ret)) return errorFromReturn(ret);
    return @ptrFromInt(ret);
}

/// Allocate DMA-capable memory with known physical address
/// page_count: Number of contiguous pages to allocate
/// Returns DmaAllocResult with virt/phys addresses, or error.
pub fn alloc_dma(page_count: u32) SyscallError!DmaAllocResult {
    var result: DmaAllocResult = undefined;
    const ret = syscall2(syscalls.SYS_ALLOC_DMA, @intFromPtr(&result), page_count);
    if (isError(ret)) return errorFromReturn(ret);
    return result;
}

/// Free DMA memory previously allocated with alloc_dma
pub fn free_dma(virt_addr: u64, size: usize) SyscallError!void {
    const ret = syscall2(syscalls.SYS_FREE_DMA, @intCast(virt_addr), size);
    if (isError(ret)) return errorFromReturn(ret);
}

// =============================================================================
// PCI Syscalls (1033-1035)
// =============================================================================

/// BAR info structure from PCI device
pub const BarInfo = extern struct {
    /// Physical base address
    base: u64,
    /// Size in bytes
    size: u64,
    /// 1 if MMIO, 0 if I/O port
    is_mmio: u8,
    /// 1 if 64-bit BAR
    is_64bit: u8,
    /// 1 if prefetchable
    prefetchable: u8,
    /// Reserved
    _pad: u8 = 0,
};

/// PCI device info structure
pub const PciDeviceInfo = extern struct {
    /// PCI bus number
    bus: u8,
    /// PCI device number (0-31)
    device: u8,
    /// PCI function number (0-7)
    func: u8,
    /// Reserved for alignment
    _pad0: u8 = 0,

    /// Vendor ID
    vendor_id: u16,
    /// Device ID
    device_id: u16,

    /// Class code
    class_code: u8,
    /// Subclass
    subclass: u8,
    /// Programming interface
    prog_if: u8,
    /// Revision ID
    revision: u8,

    /// BAR information (6 BARs)
    bar: [6]BarInfo,

    /// Interrupt line (IRQ)
    irq_line: u8,
    /// Interrupt pin (1=INTA, 2=INTB, etc.)
    irq_pin: u8,
    /// Reserved
    _pad1: [6]u8 = [_]u8{0} ** 6,

    /// Check if this is a VirtIO network device
    pub fn isVirtioNet(self: *const PciDeviceInfo) bool {
        // VirtIO Vendor ID
        if (self.vendor_id != 0x1AF4) return false;
        // Network device: legacy (0x1000) or modern (0x1041)
        return self.device_id == 0x1000 or self.device_id == 0x1041;
    }

    /// Check if this is a VirtIO block device
    pub fn isVirtioBlk(self: *const PciDeviceInfo) bool {
        // VirtIO Vendor ID
        if (self.vendor_id != 0x1AF4) return false;
        // Block device: legacy (0x1001) or modern (0x1042)
        return self.device_id == 0x1001 or self.device_id == 0x1042;
    }
};

/// Enumerate PCI devices
/// buf: Array to store device info
/// Returns number of devices found
pub fn pci_enumerate(buf: []PciDeviceInfo) SyscallError!usize {
    const ret = syscall2(syscalls.SYS_PCI_ENUMERATE, @intFromPtr(buf.ptr), buf.len);
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

/// Read 32-bit value from PCI configuration space
/// Requires PciConfig capability for the device.
pub fn pci_config_read(bus: u8, device: u5, func: u3, offset: u12) SyscallError!u32 {
    const ret = syscall4(
        syscalls.SYS_PCI_CONFIG_READ,
        bus,
        device,
        func,
        offset,
    );
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(ret);
}

/// Write 32-bit value to PCI configuration space
/// Requires PciConfig capability for the device.
pub fn pci_config_write(bus: u8, device: u5, func: u3, offset: u12, value: u32) SyscallError!void {
    const ret = syscall5(
        syscalls.SYS_PCI_CONFIG_WRITE,
        bus,
        device,
        func,
        offset,
        value,
    );
    if (isError(ret)) return errorFromReturn(ret);
}

// =============================================================================
// Port I/O Syscalls (1036-1037)
// =============================================================================

/// Write byte to I/O port
/// Requires IoPort capability for the port range.
pub fn outb(port: u16, value: u8) SyscallError!void {
    const ret = syscall2(syscalls.SYS_OUTB, port, value);
    if (isError(ret)) return errorFromReturn(ret);
}

/// Read byte from I/O port
/// Requires IoPort capability for the port range.
pub fn inb(port: u16) SyscallError!u8 {
    const ret = syscall1(syscalls.SYS_INB, port);
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(ret);
}

// =============================================================================
// io_uring Async I/O (425-427)
// =============================================================================

/// io_uring types from uapi
pub const io_ring = uapi.io_ring;
pub const IoUringSqe = io_ring.IoUringSqe;
pub const IoUringCqe = io_ring.IoUringCqe;
pub const IoUringParams = io_ring.IoUringParams;
pub const IORING_ENTER_GETEVENTS = io_ring.IORING_ENTER_GETEVENTS;
pub const IORING_OP_NOP = io_ring.IORING_OP_NOP;
pub const IORING_OP_READ = io_ring.IORING_OP_READ;
pub const IORING_OP_WRITE = io_ring.IORING_OP_WRITE;
pub const IORING_OP_ACCEPT = io_ring.IORING_OP_ACCEPT;
pub const IORING_OP_RECV = io_ring.IORING_OP_RECV;
pub const IORING_OP_SEND = io_ring.IORING_OP_SEND;
pub const IORING_OP_CLOSE = io_ring.IORING_OP_CLOSE;
pub const IORING_OFF_SQ_RING = io_ring.IORING_OFF_SQ_RING;
pub const IORING_OFF_CQ_RING = io_ring.IORING_OFF_CQ_RING;
pub const IORING_OFF_SQES = io_ring.IORING_OFF_SQES;

/// Setup an io_uring instance
/// entries: Number of SQ entries (must be power of 2)
/// params: In/out parameters for the ring
/// Returns ring file descriptor or error
pub fn io_uring_setup(entries: u32, params: *IoUringParams) SyscallError!i32 {
    const ret = syscall2(
        syscalls.SYS_IO_URING_SETUP,
        entries,
        @intFromPtr(params),
    );
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Submit SQEs and optionally wait for completions
/// ring_fd: File descriptor from io_uring_setup
/// to_submit: Number of SQEs to submit
/// min_complete: Minimum completions to wait for (0 for no wait)
/// flags: IORING_ENTER_* flags
/// Returns number of SQEs submitted or error
pub fn io_uring_enter(ring_fd: i32, to_submit: u32, min_complete: u32, flags: u32) SyscallError!u32 {
    const ret = syscall4(
        syscalls.SYS_IO_URING_ENTER,
        @bitCast(@as(isize, ring_fd)),
        to_submit,
        min_complete,
        flags,
    );
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(ret);
}

/// Register resources with an io_uring instance
/// ring_fd: File descriptor from io_uring_setup
/// opcode: IORING_REGISTER_* operation
/// arg: Operation-specific argument
/// nr_args: Number of arguments
pub fn io_uring_register(ring_fd: i32, opcode: u32, arg: usize, nr_args: u32) SyscallError!i32 {
    const ret = syscall4(
        syscalls.SYS_IO_URING_REGISTER,
        @bitCast(@as(isize, ring_fd)),
        opcode,
        arg,
        nr_args,
    );
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

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

/// Map memory region (for io_uring ring buffers)
pub fn mmap(addr: ?*anyopaque, length: usize, prot: i32, flags: i32, fd: i32, offset: u64) SyscallError![*]u8 {
    const ret = syscall6(
        syscalls.SYS_MMAP,
        @intFromPtr(addr),
        length,
        @bitCast(@as(isize, prot)),
        @bitCast(@as(isize, flags)),
        @bitCast(@as(isize, fd)),
        offset,
    );
    if (isError(ret)) return errorFromReturn(ret);
    return @ptrFromInt(ret);
}

/// Unmap memory region
pub fn munmap(addr: [*]u8, length: usize) SyscallError!void {
    const ret = syscall2(
        syscalls.SYS_MUNMAP,
        @intFromPtr(addr),
        length,
    );
    if (isError(ret)) return errorFromReturn(ret);
}

/// High-level io_uring ring wrapper for userspace
pub const IoUring = struct {
    ring_fd: i32,
    sq_ring: [*]u8,
    cq_ring: [*]u8,
    sqes: [*]IoUringSqe,
    sq_head: *volatile u32,
    sq_tail: *volatile u32,
    sq_mask: u32,
    sq_array: [*]u32,
    cq_head: *volatile u32,
    cq_tail: *volatile u32,
    cq_mask: u32,
    cqes: [*]IoUringCqe,
    sq_ring_size: usize,
    cq_ring_size: usize,
    sqes_size: usize,

    /// Initialize io_uring with given number of entries
    pub fn init(entries: u32) SyscallError!IoUring {
        var params: IoUringParams = std.mem.zeroes(IoUringParams);

        const ring_fd = try io_uring_setup(entries, &params);

        // Calculate sizes
        const sq_ring_size = params.sq_off.array + params.sq_entries * @sizeOf(u32);
        const cq_ring_size = params.cq_off.cqes + params.cq_entries * @sizeOf(IoUringCqe);
        const sqes_size = params.sq_entries * @sizeOf(IoUringSqe);

        // Map SQ ring
        const sq_ring = try mmap(
            null,
            sq_ring_size,
            PROT_READ | PROT_WRITE,
            MAP_SHARED | MAP_POPULATE,
            ring_fd,
            IORING_OFF_SQ_RING,
        );

        // Map CQ ring
        const cq_ring = try mmap(
            null,
            cq_ring_size,
            PROT_READ | PROT_WRITE,
            MAP_SHARED | MAP_POPULATE,
            ring_fd,
            IORING_OFF_CQ_RING,
        );

        // Map SQEs
        const sqes_ptr = try mmap(
            null,
            sqes_size,
            PROT_READ | PROT_WRITE,
            MAP_SHARED | MAP_POPULATE,
            ring_fd,
            IORING_OFF_SQES,
        );

        return IoUring{
            .ring_fd = ring_fd,
            .sq_ring = sq_ring,
            .cq_ring = cq_ring,
            .sqes = @ptrCast(@alignCast(sqes_ptr)),
            .sq_head = @ptrCast(@alignCast(sq_ring + params.sq_off.head)),
            .sq_tail = @ptrCast(@alignCast(sq_ring + params.sq_off.tail)),
            .sq_mask = params.sq_entries - 1,
            .sq_array = @ptrCast(@alignCast(sq_ring + params.sq_off.array)),
            .cq_head = @ptrCast(@alignCast(cq_ring + params.cq_off.head)),
            .cq_tail = @ptrCast(@alignCast(cq_ring + params.cq_off.tail)),
            .cq_mask = params.cq_entries - 1,
            .cqes = @ptrCast(@alignCast(cq_ring + params.cq_off.cqes)),
            .sq_ring_size = sq_ring_size,
            .cq_ring_size = cq_ring_size,
            .sqes_size = sqes_size,
        };
    }

    /// Clean up io_uring resources
    pub fn deinit(self: *IoUring) void {
        munmap(self.sq_ring, self.sq_ring_size) catch {};
        munmap(self.cq_ring, self.cq_ring_size) catch {};
        munmap(@ptrCast(self.sqes), self.sqes_size) catch {};
        close(self.ring_fd) catch {};
    }

    /// Get next SQE slot (returns null if queue full)
    pub fn getSqe(self: *IoUring) ?*IoUringSqe {
        const tail = self.sq_tail.*;
        const head = self.sq_head.*;

        if (tail - head >= self.sq_mask + 1) {
            return null; // Queue full
        }

        const index = tail & self.sq_mask;
        self.sq_array[index] = index;
        return &self.sqes[index];
    }

    /// Submit SQE (advances tail)
    pub fn submitSqe(self: *IoUring) void {
        memoryBarrier();
        self.sq_tail.* += 1;
        memoryBarrier();
    }

    /// Submit all pending SQEs and optionally wait
    pub fn submit(self: *IoUring, min_complete: u32) SyscallError!u32 {
        const to_submit = self.sq_tail.* - self.sq_head.*;
        if (to_submit == 0 and min_complete == 0) return 0;

        const flags: u32 = if (min_complete > 0) IORING_ENTER_GETEVENTS else 0;
        return io_uring_enter(self.ring_fd, to_submit, min_complete, flags);
    }

    /// Check if there are completions ready
    pub fn cqReady(self: *IoUring) u32 {
        return self.cq_tail.* - self.cq_head.*;
    }

    /// Get next CQE (returns null if none ready)
    pub fn peekCqe(self: *IoUring) ?*IoUringCqe {
        if (self.cq_head.* == self.cq_tail.*) {
            return null;
        }
        const index = self.cq_head.* & self.cq_mask;
        return &self.cqes[index];
    }

    /// Advance CQ head (consume a CQE)
    pub fn advanceCq(self: *IoUring) void {
        memoryBarrier();
        self.cq_head.* += 1;
        memoryBarrier();
    }

    /// Prepare accept SQE
    pub fn prepAccept(sqe: *IoUringSqe, fd: i32, addr: ?*SockAddrIn, addrlen: ?*u32, user_data: u64) void {
        sqe.* = std.mem.zeroes(IoUringSqe);
        sqe.opcode = IORING_OP_ACCEPT;
        sqe.fd = fd;
        sqe.addr = if (addr) |a| @intFromPtr(a) else 0;
        sqe.off = if (addrlen) |l| @intFromPtr(l) else 0;
        sqe.user_data = user_data;
    }

    /// Prepare recv SQE
    pub fn prepRecv(sqe: *IoUringSqe, fd: i32, buf: []u8, user_data: u64) void {
        sqe.* = std.mem.zeroes(IoUringSqe);
        sqe.opcode = IORING_OP_RECV;
        sqe.fd = fd;
        sqe.addr = @intFromPtr(buf.ptr);
        sqe.len = @truncate(buf.len);
        sqe.user_data = user_data;
    }

    /// Prepare send SQE
    pub fn prepSend(sqe: *IoUringSqe, fd: i32, buf: []const u8, user_data: u64) void {
        sqe.* = std.mem.zeroes(IoUringSqe);
        sqe.opcode = IORING_OP_SEND;
        sqe.fd = fd;
        sqe.addr = @intFromPtr(buf.ptr);
        sqe.len = @truncate(buf.len);
        sqe.user_data = user_data;
    }

    /// Prepare close SQE
    pub fn prepClose(sqe: *IoUringSqe, fd: i32, user_data: u64) void {
        sqe.* = std.mem.zeroes(IoUringSqe);
        sqe.opcode = IORING_OP_CLOSE;
        sqe.fd = fd;
        sqe.user_data = user_data;
    }
};

// =============================================================================
// IPC Syscalls (1020-1021)
// =============================================================================

/// IPC Message type re-exported for convenience
pub const IpcMessage = uapi.ipc_msg.Message;

/// Send an IPC message to a process (blocking)
/// Returns 0 on success, or error
pub fn send(target_pid: u32, msg: *const IpcMessage) SyscallError!void {
    const ret = syscall3(syscalls.SYS_SEND, target_pid, @intFromPtr(msg), @sizeOf(IpcMessage));
    if (isError(ret)) return errorFromReturn(ret);
}

/// Receive an IPC message (blocking)
/// Returns sender_pid on success, or error
pub fn recv(msg: *IpcMessage) SyscallError!u32 {
    const ret = syscall2(syscalls.SYS_RECV, @intFromPtr(msg), @sizeOf(IpcMessage));
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(ret);
}

// =============================================================================
// Service Registry Syscalls (1026-1027)
// =============================================================================

/// Register current process as a named service
pub fn register_service(name: []const u8) SyscallError!void {
    const ret = syscall2(syscalls.SYS_REGISTER_SERVICE, @intFromPtr(name.ptr), name.len);
    if (isError(ret)) return errorFromReturn(ret);
}

/// Lookup a service PID by name
pub fn lookup_service(name: []const u8) SyscallError!u32 {
    const ret = syscall2(syscalls.SYS_LOOKUP_SERVICE, @intFromPtr(name.ptr), name.len);
    if (isError(ret)) return errorFromReturn(ret);
    return @truncate(ret);
}
