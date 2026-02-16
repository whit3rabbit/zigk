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
        @as(usize, @as(u32, @bitCast(ruid))),
        @as(usize, @as(u32, @bitCast(euid))),
        @as(usize, @as(u32, @bitCast(suid))),
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
        @as(usize, @as(u32, @bitCast(rgid))),
        @as(usize, @as(u32, @bitCast(egid))),
        @as(usize, @as(u32, @bitCast(sgid))),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set real and effective user IDs
pub fn setreuid(ruid: i32, euid: i32) SyscallError!void {
    const ret = primitive.syscall2(
        syscalls.SYS_SETREUID,
        @as(usize, @as(u32, @bitCast(ruid))),
        @as(usize, @as(u32, @bitCast(euid))),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set real and effective group IDs
pub fn setregid(rgid: i32, egid: i32) SyscallError!void {
    const ret = primitive.syscall2(
        syscalls.SYS_SETREGID,
        @as(usize, @as(u32, @bitCast(rgid))),
        @as(usize, @as(u32, @bitCast(egid))),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get supplementary group IDs
pub fn getgroups(size: i32, list: [*]u32) SyscallError!i32 {
    const ret = primitive.syscall2(
        syscalls.SYS_GETGROUPS,
        @as(usize, @as(u32, @bitCast(size))),
        @intFromPtr(list),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Set supplementary group IDs
pub fn setgroups(size: usize, list: [*]const u32) SyscallError!void {
    const ret = primitive.syscall2(
        syscalls.SYS_SETGROUPS,
        size,
        @intFromPtr(list),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set filesystem user ID -- returns previous fsuid value
pub fn setfsuid(fsuid: u32) u32 {
    const ret = primitive.syscall1(syscalls.SYS_SETFSUID, fsuid);
    return @truncate(ret);
}

/// Set filesystem group ID -- returns previous fsgid value
pub fn setfsgid(fsgid: u32) u32 {
    const ret = primitive.syscall1(syscalls.SYS_SETFSGID, fsgid);
    return @truncate(ret);
}

/// Change file owner and group by path
pub fn chown(path_ptr: [*]const u8, owner: u32, group: u32) SyscallError!void {
    const ret = primitive.syscall3(syscalls.SYS_CHOWN, @intFromPtr(path_ptr), owner, group);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Change file owner and group by file descriptor
pub fn fchown(fd: i32, owner: u32, group: u32) SyscallError!void {
    const ret = primitive.syscall3(syscalls.SYS_FCHOWN, @as(usize, @as(u32, @bitCast(fd))), owner, group);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Change symlink owner and group (no follow)
pub fn lchown(path_ptr: [*]const u8, owner: u32, group: u32) SyscallError!void {
    const ret = primitive.syscall3(syscalls.SYS_LCHOWN, @intFromPtr(path_ptr), owner, group);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Change file owner and group relative to directory fd
pub fn fchownat(dirfd: i32, path_ptr: [*]const u8, owner: u32, group: u32, flags: u32) SyscallError!void {
    const ret = primitive.syscall5(
        syscalls.SYS_FCHOWNAT,
        @as(usize, @as(u32, @bitCast(dirfd))),
        @intFromPtr(path_ptr),
        owner,
        group,
        flags,
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

// =============================================================================
// Modern Process Creation (clone3)
// =============================================================================

/// Clone arguments structure (matches Linux struct clone_args)
pub const CloneArgs = extern struct {
    flags: u64 = 0,
    pidfd: u64 = 0,
    child_tid: u64 = 0,
    parent_tid: u64 = 0,
    exit_signal: u64 = 0,
    stack: u64 = 0,
    stack_size: u64 = 0,
    tls: u64 = 0,
    set_tid: u64 = 0,
    set_tid_size: u64 = 0,
    cgroup: u64 = 0,
};

/// SIGCHLD signal number
pub const SIGCHLD: u64 = 17;

/// Create a child process using clone3
/// Returns: child PID to parent, 0 to child
pub fn clone3(args: *const CloneArgs) SyscallError!i32 {
    const ret = primitive.syscall2(
        syscalls.SYS_CLONE3,
        @intFromPtr(args),
        @sizeOf(CloneArgs),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

// =============================================================================
// waitid
// =============================================================================

/// waitid idtype values
pub const P_ALL: u32 = 0;
pub const P_PID: u32 = 1;
pub const P_PGID: u32 = 2;

/// waitid option flags
pub const WEXITED: u32 = 4;
pub const WSTOPPED: u32 = 2;
pub const WCONTINUED: u32 = 8;
pub const WNOWAIT: u32 = 0x01000000;

/// siginfo_t structure for waitid (128 bytes, Linux ABI)
pub const SigInfo = extern struct {
    si_signo: i32 = 0,
    si_errno: i32 = 0,
    si_code: i32 = 0,
    _pad0: i32 = 0,
    si_pid: i32 = 0,
    si_uid: i32 = 0,
    si_status: i32 = 0,
    _pad: [128 - 28]u8 = [_]u8{0} ** (128 - 28),
};

/// CLD_* codes for si_code
pub const CLD_EXITED: i32 = 1;
pub const CLD_KILLED: i32 = 2;
pub const CLD_DUMPED: i32 = 3;
pub const CLD_TRAPPED: i32 = 4;
pub const CLD_STOPPED: i32 = 5;
pub const CLD_CONTINUED: i32 = 6;

/// Wait for child process state changes (modern interface)
/// Returns 0 on success
pub fn waitid(idtype: u32, id: u32, info: *SigInfo, options: u32) SyscallError!void {
    const ret = primitive.syscall5(
        syscalls.SYS_WAITID,
        idtype,
        id,
        @intFromPtr(info),
        options,
        0, // rusage not implemented
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
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

// =============================================================================
// Process Control (prctl, CPU affinity)
// =============================================================================

/// prctl option constants
pub const PR_SET_NAME: usize = 15;
pub const PR_GET_NAME: usize = 16;

/// Perform process control operations
/// option: Operation to perform (PR_SET_NAME, PR_GET_NAME, etc)
/// arg2-arg5: Operation-specific arguments
/// Returns: Operation-specific value or 0 on success
pub fn prctl(option: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) SyscallError!usize {
    const ret = primitive.syscall5(syscalls.SYS_PRCTL, option, arg2, arg3, arg4, arg5);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Set CPU affinity mask for a process/thread
/// pid: Process/thread ID (0 = current thread)
/// cpusetsize: Size of mask buffer in bytes
/// mask: Pointer to CPU set bitmask
pub fn sched_setaffinity(pid: i32, cpusetsize: usize, mask: [*]const u8) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_SCHED_SETAFFINITY,
        @as(usize, @as(u32, @bitCast(pid))),
        cpusetsize,
        @intFromPtr(mask),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get CPU affinity mask for a process/thread
/// pid: Process/thread ID (0 = current thread)
/// cpusetsize: Size of mask buffer in bytes
/// mask: Pointer to CPU set bitmask (output)
/// Returns: Number of bytes written to mask
pub fn sched_getaffinity(pid: i32, cpusetsize: usize, mask: [*]u8) SyscallError!usize {
    const ret = primitive.syscall3(
        syscalls.SYS_SCHED_GETAFFINITY,
        @as(usize, @as(u32, @bitCast(pid))),
        cpusetsize,
        @intFromPtr(mask),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

// =============================================================================
// Capability Syscalls
// =============================================================================

/// Linux capability header for capget/capset
pub const CapUserHeader = extern struct {
    version: u32,
    pid: i32,
};

/// Linux capability data (one entry for v1, two for v3)
pub const CapUserData = extern struct {
    effective: u32,
    permitted: u32,
    inheritable: u32,
};

/// Capability version constants
pub const _LINUX_CAPABILITY_VERSION_1: u32 = 0x19980330;
pub const _LINUX_CAPABILITY_VERSION_2: u32 = 0x20071026;
pub const _LINUX_CAPABILITY_VERSION_3: u32 = 0x20080522;

/// Standard Linux capability constants (correct Linux values)
pub const CAP_CHOWN: u6 = 0;
pub const CAP_DAC_OVERRIDE: u6 = 1;
pub const CAP_DAC_READ_SEARCH: u6 = 2;
pub const CAP_FOWNER: u6 = 3;
pub const CAP_FSETID: u6 = 4;
pub const CAP_KILL: u6 = 5;
pub const CAP_SETGID: u6 = 6;
pub const CAP_SETUID: u6 = 7;
pub const CAP_SETPCAP: u6 = 8;
pub const CAP_LINUX_IMMUTABLE: u6 = 9;
pub const CAP_NET_BIND_SERVICE: u6 = 10;
pub const CAP_NET_BROADCAST: u6 = 11;
pub const CAP_NET_ADMIN: u6 = 12;
pub const CAP_NET_RAW: u6 = 13;
pub const CAP_IPC_LOCK: u6 = 14;
pub const CAP_IPC_OWNER: u6 = 15;
pub const CAP_SYS_MODULE: u6 = 16;
pub const CAP_SYS_RAWIO: u6 = 17;
pub const CAP_SYS_CHROOT: u6 = 18;
pub const CAP_SYS_PTRACE: u6 = 19;
pub const CAP_SYS_PACCT: u6 = 20;
pub const CAP_SYS_ADMIN: u6 = 21;
pub const CAP_SYS_BOOT: u6 = 22;
pub const CAP_SYS_NICE: u6 = 23;
pub const CAP_SYS_RESOURCE: u6 = 24;
pub const CAP_SYS_TIME: u6 = 25;
pub const CAP_SYS_TTY_CONFIG: u6 = 26;
pub const CAP_MKNOD: u6 = 27;
pub const CAP_LEASE: u6 = 28;
pub const CAP_AUDIT_WRITE: u6 = 29;
pub const CAP_AUDIT_CONTROL: u6 = 30;
pub const CAP_SETFCAP: u6 = 31;
pub const CAP_MAC_OVERRIDE: u6 = 32;
pub const CAP_MAC_ADMIN: u6 = 33;
pub const CAP_SYSLOG: u6 = 34;
pub const CAP_WAKE_ALARM: u6 = 35;
pub const CAP_BLOCK_SUSPEND: u6 = 36;
pub const CAP_AUDIT_READ: u6 = 37;
pub const CAP_PERFMON: u6 = 38;
pub const CAP_BPF: u6 = 39;
pub const CAP_CHECKPOINT_RESTORE: u6 = 40;
pub const CAP_LAST_CAP: u6 = 40;

/// All capabilities set (bits 0-40)
pub const CAP_FULL_SET: u64 = (@as(u64, 1) << (@as(u7, CAP_LAST_CAP) + 1)) - 1;

/// Get process capabilities
/// hdrp: pointer to CapUserHeader (version + pid)
/// datap: pointer to CapUserData array (1 entry for v1, 2 for v3) or null for version query
pub fn capget(hdrp: *CapUserHeader, datap: ?[*]CapUserData) SyscallError!void {
    const ret = primitive.syscall2(
        syscalls.SYS_CAPGET,
        @intFromPtr(hdrp),
        if (datap) |d| @intFromPtr(d) else 0,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set process capabilities
/// hdrp: pointer to CapUserHeader (version + pid)
/// datap: pointer to CapUserData array (1 entry for v1, 2 for v3)
pub fn capset(hdrp: *const CapUserHeader, datap: [*]const CapUserData) SyscallError!void {
    const ret = primitive.syscall2(
        syscalls.SYS_CAPSET,
        @intFromPtr(hdrp),
        @intFromPtr(datap),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Seccomp (syscall filtering)
// =============================================================================

/// Seccomp operations
pub const SECCOMP_SET_MODE_STRICT: usize = 0;
pub const SECCOMP_SET_MODE_FILTER: usize = 1;
pub const SECCOMP_GET_ACTION_AVAIL: usize = 2;

/// Seccomp return values
pub const SECCOMP_RET_KILL_PROCESS: u32 = 0x80000000;
pub const SECCOMP_RET_KILL_THREAD: u32 = 0x00000000;
pub const SECCOMP_RET_KILL: u32 = 0x00000000;
pub const SECCOMP_RET_ERRNO: u32 = 0x00050000;
pub const SECCOMP_RET_ALLOW: u32 = 0x7fff0000;
pub const SECCOMP_RET_DATA: u32 = 0x0000ffff;

/// Classic BPF instruction for seccomp filters
pub const SockFilterInsn = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

/// BPF program descriptor
pub const SockFprog = extern struct {
    len: u16,
    _pad: u16 = 0,
    _pad2: u32 = 0,
    filter: u64,
};

/// BPF opcodes needed for test construction
pub const BPF_LD: u16 = 0x00;
pub const BPF_RET: u16 = 0x06;
pub const BPF_JMP: u16 = 0x05;
pub const BPF_W: u16 = 0x00;
pub const BPF_ABS: u16 = 0x20;
pub const BPF_K: u16 = 0x00;
pub const BPF_JEQ: u16 = 0x10;

/// prctl constants for no_new_privs
pub const PR_SET_NO_NEW_PRIVS: usize = 38;
pub const PR_GET_NO_NEW_PRIVS: usize = 39;

/// Call seccomp syscall
pub fn seccomp(op: usize, flags: usize, args: usize) SyscallError!usize {
    const ret = primitive.syscall3(syscalls.SYS_SECCOMP, op, flags, args);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}
