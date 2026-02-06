const std = @import("std");
const primitive = @import("primitive.zig");
const uapi = primitive.uapi;
const syscalls = uapi.syscalls;

pub const SyscallError = primitive.SyscallError;

// =============================================================================
// Process Control (sys_exit, sys_getpid, sys_sched_yield)
// =============================================================================

/// Yield the processor
pub fn sched_yield() SyscallError!void {
    const ret = primitive.syscall0(syscalls.SYS_SCHED_YIELD);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Exit the process
/// This function never returns
pub fn exit(status: i32) noreturn {
    _ = primitive.syscall1(syscalls.SYS_EXIT, @bitCast(@as(isize, status)));
    unreachable;
}

/// Exit all threads in the process group
pub fn exit_group(status: i32) noreturn {
    _ = primitive.syscall1(syscalls.SYS_EXIT_GROUP, @bitCast(@as(isize, status)));
    unreachable;
}

pub const ARCH_SET_FS: usize = 0x1002;
pub const ARCH_GET_FS: usize = 0x1003;

pub fn arch_prctl(code: usize, addr: usize) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_ARCH_PRCTL, code, addr);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get process ID
pub fn getpid() i32 {
    const ret = primitive.syscall0(syscalls.SYS_GETPID);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Get parent process ID
pub fn getppid() i32 {
    const ret = primitive.syscall0(syscalls.SYS_GETPPID);
    return @truncate(@as(isize, @bitCast(ret)));
}

// =============================================================================
// Process Groups and Sessions
// =============================================================================

/// Get process group ID of a process
pub fn getpgid(pid: i32) SyscallError!i32 {
    const ret = primitive.syscall1(syscalls.SYS_GETPGID, @bitCast(@as(isize, pid)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Get process group of calling process
pub fn getpgrp() SyscallError!i32 {
    const ret = primitive.syscall0(syscalls.SYS_GETPGRP);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Set process group ID
pub fn setpgid(pid: i32, pgid: i32) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_SETPGID, @bitCast(@as(isize, pid)), @bitCast(@as(isize, pgid)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Create new session and set process group ID
pub fn setsid() SyscallError!i32 {
    const ret = primitive.syscall0(syscalls.SYS_SETSID);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Get session ID of a process
pub fn getsid(pid: i32) SyscallError!i32 {
    const ret = primitive.syscall1(syscalls.SYS_GETSID, @bitCast(@as(isize, pid)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Get user ID
pub fn getuid() u32 {
    const ret = primitive.syscall0(syscalls.SYS_GETUID);
    return @truncate(ret);
}

/// Get effective user ID
pub fn geteuid() u32 {
    const ret = primitive.syscall0(syscalls.SYS_GETEUID);
    return @truncate(ret);
}

/// Get group ID
pub fn getgid() u32 {
    const ret = primitive.syscall0(syscalls.SYS_GETGID);
    return @truncate(ret);
}

/// Get effective group ID
pub fn getegid() u32 {
    const ret = primitive.syscall0(syscalls.SYS_GETEGID);
    return @truncate(ret);
}

/// Set user ID
pub fn setuid(uid: u32) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_SETUID, uid);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set group ID
pub fn setgid(gid: u32) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_SETGID, gid);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get real, effective, and saved user IDs
pub fn getresuid(ruid: *u32, euid: *u32, suid: *u32) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_GETRESUID,
        @intFromPtr(ruid),
        @intFromPtr(euid),
        @intFromPtr(suid),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set real, effective, and saved user IDs
pub fn setresuid(ruid: i32, euid: i32, suid: i32) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_SETRESUID,
        @bitCast(@as(u32, @bitCast(ruid))),
        @bitCast(@as(u32, @bitCast(euid))),
        @bitCast(@as(u32, @bitCast(suid))),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get real, effective, and saved group IDs
pub fn getresgid(rgid: *u32, egid: *u32, sgid: *u32) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_GETRESGID,
        @intFromPtr(rgid),
        @intFromPtr(egid),
        @intFromPtr(sgid),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set real, effective, and saved group IDs
pub fn setresgid(rgid: i32, egid: i32, sgid: i32) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_SETRESGID,
        @bitCast(@as(u32, @bitCast(rgid))),
        @bitCast(@as(u32, @bitCast(egid))),
        @bitCast(@as(u32, @bitCast(sgid))),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Memory Management (sys_brk)
// =============================================================================

/// Change data segment size (heap)
/// brk(0) returns current break address
/// brk(addr) sets new break and returns new break (or error)
/// Note: Kernel returns page-aligned break value, so we check ret >= addr
pub fn brk(addr: usize) SyscallError!usize {
    const ret = primitive.syscall1(syscalls.SYS_BRK, addr);
    // brk returns the new break address (page-aligned by kernel)
    // If the request failed, kernel returns the current break (< requested)
    if (addr != 0 and ret < addr) {
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

    // Use checked arithmetic to prevent integer overflow/underflow
    const new_break: usize = if (increment > 0) blk: {
        const inc: usize = @intCast(increment);
        break :blk std.math.add(usize, current, inc) catch return error.OutOfMemory;
    } else blk: {
        const dec: usize = @intCast(-increment);
        break :blk std.math.sub(usize, current, dec) catch return error.OutOfMemory;
    };

    _ = try brk(new_break);
    return @ptrFromInt(current);
}

// =============================================================================
// IPC Syscalls (1020-1021)
// =============================================================================

/// IPC Message type re-exported for convenience
pub const IpcMessage = uapi.ipc_msg.Message;

/// Send an IPC message to a process (blocking)
/// Returns 0 on success, or error
pub fn send(target_pid: u32, msg: *const IpcMessage) SyscallError!void {
    const ret = primitive.syscall3(syscalls.SYS_SEND, target_pid, @intFromPtr(msg), @sizeOf(IpcMessage));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Receive an IPC message (blocking)
/// Returns sender_pid on success, or error
pub fn recv(msg: *IpcMessage) SyscallError!u32 {
    const ret = primitive.syscall2(syscalls.SYS_RECV, @intFromPtr(msg), @sizeOf(IpcMessage));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(ret);
}

// =============================================================================
// Service Registry Syscalls (1026-1027)
// =============================================================================

/// Register current process as a named service
pub fn register_service(name: []const u8) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_REGISTER_SERVICE, @intFromPtr(name.ptr), name.len);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Lookup a service PID by name
pub fn lookup_service(name: []const u8) SyscallError!u32 {
    const ret = primitive.syscall2(syscalls.SYS_LOOKUP_SERVICE, @intFromPtr(name.ptr), name.len);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(ret);
}

// =============================================================================
// Process Management Syscalls (fork, wait4, execve)
// =============================================================================

/// Fork the current process
/// Returns: child PID to parent, 0 to child
pub fn fork() SyscallError!i32 {
    const ret = primitive.syscall0(syscalls.SYS_FORK);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Wait for a child process to change state
/// pid: Process ID to wait for (-1 = any child, >0 = specific child)
/// wstatus: Pointer to store exit status (null if not needed)
/// options: Wait options (WNOHANG = 1)
/// Returns: PID of child that changed state
pub fn wait4(pid: i32, wstatus: ?*i32, options: u32) SyscallError!i32 {
    const wstatus_ptr = if (wstatus) |ptr| @intFromPtr(ptr) else 0;
    const ret = primitive.syscall4(
        syscalls.SYS_WAIT4,
        @bitCast(@as(isize, pid)),
        wstatus_ptr,
        options,
        0, // rusage not implemented
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Wait options
pub const WNOHANG: u32 = 1; // Don't block if no child has exited

/// Wait for process state change (wrapper around wait4)
///
/// Standard POSIX waitpid() wrapper.
/// pid: Process ID to wait for (or -1 for any, 0 for process group, < -1 for specific group)
/// wstatus: Pointer to store exit status (null if not needed)
/// options: Wait options (WNOHANG = 1)
/// Returns: PID of child that changed state
pub fn waitpid(pid: i32, wstatus: ?*i32, options: u32) SyscallError!i32 {
    return try wait4(pid, wstatus, options);
}


/// Execute a program
/// path: Path to executable
/// argv: Null-terminated array of argument strings
/// envp: Null-terminated array of environment strings (can be null)
/// This function does not return on success
pub fn execve(path: []const u8, argv: [*:null]const ?[*:0]const u8, envp: ?[*:null]const ?[*:0]const u8) SyscallError!void {
    const envp_ptr = if (envp) |ptr| @intFromPtr(ptr) else 0;
    const ret = primitive.syscall3(
        syscalls.SYS_EXECVE,
        @intFromPtr(path.ptr),
        @intFromPtr(argv),
        envp_ptr,
    );
    // If we get here, execve failed
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    unreachable;
}

// =============================================================================
// Signal and Timing Syscalls
// =============================================================================

/// Wait for a signal
/// Always returns error.EINTR when interrupted by a signal
pub fn pause() SyscallError!void {
    const ret = primitive.syscall0(syscalls.SYS_PAUSE);
    // pause() always returns -EINTR when woken by a signal
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set an alarm to deliver SIGALRM after specified seconds
/// Returns: Number of seconds remaining from previous alarm (0 if none)
pub fn alarm(seconds: u32) u32 {
    const ret = primitive.syscall1(syscalls.SYS_ALARM, seconds);
    // alarm() never fails, returns remaining seconds
    return @truncate(ret);
}

// =============================================================================
// Misc Process/System Syscalls (umask, uname)
// =============================================================================

/// Set file mode creation mask
/// Returns the previous mask value
pub fn umask(mask: u32) u32 {
    const ret = primitive.syscall1(syscalls.SYS_UMASK, mask);
    return @truncate(ret);
}

/// System identification structure
pub const Utsname = extern struct {
    sysname: [65]u8,
    nodename: [65]u8,
    release: [65]u8,
    version: [65]u8,
    machine: [65]u8,
    domainname: [65]u8,
};

/// Get system identification
pub fn uname(buf: *Utsname) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_UNAME, @intFromPtr(buf));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}
