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

/// Get user ID
pub fn getuid() u32 {
    const ret = primitive.syscall0(syscalls.SYS_GETUID);
    return @truncate(ret);
}

/// Get group ID
pub fn getgid() u32 {
    const ret = primitive.syscall0(syscalls.SYS_GETGID);
    return @truncate(ret);
}

// =============================================================================
// Memory Management (sys_brk)
// =============================================================================

/// Change data segment size (heap)
/// brk(0) returns current break address
/// brk(addr) sets new break and returns new break (or error)
pub fn brk(addr: usize) SyscallError!usize {
    const ret = primitive.syscall1(syscalls.SYS_BRK, addr);
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
