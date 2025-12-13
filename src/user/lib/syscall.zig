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

const uapi = @import("uapi");
const syscalls = uapi.syscalls;
const Errno = uapi.errno.Errno;

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
inline fn syscall0(number: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 1 argument
inline fn syscall1(number: usize, arg1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 2 arguments
inline fn syscall2(number: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 3 arguments
inline fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
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
inline fn syscall4(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
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
inline fn syscall5(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
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
inline fn syscall6(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
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
fn errorFromReturn(ret: usize) SyscallError {
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
inline fn isError(ret: usize) bool {
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
