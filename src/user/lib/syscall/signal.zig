const primitive = @import("primitive.zig");
const uapi = primitive.uapi;
const syscalls = uapi.syscalls;

pub const SyscallError = primitive.SyscallError;

// Signal handling
pub const SigAction = uapi.signal.SigAction;
pub const SigSet = uapi.signal.SigSet;

pub fn kill(pid: i32, sig: i32) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_KILL, @bitCast(@as(isize, pid)), @bitCast(@as(isize, sig)));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Send signal to a process group
///
/// Convenience wrapper around kill(-pgid, sig).
/// pgid: Process group ID to signal
/// sig: Signal number to send
pub fn killpg(pgid: i32, sig: i32) SyscallError!void {
    return try kill(-pgid, sig);
}

pub fn sigaction(sig: i32, act: ?*const SigAction, oldact: ?*SigAction) SyscallError!void {
    const ret = primitive.syscall4(syscalls.SYS_RT_SIGACTION,
        @bitCast(@as(isize, sig)),
        if (act) |a| @intFromPtr(a) else 0,
        if (oldact) |a| @intFromPtr(a) else 0,
        @sizeOf(SigSet)
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

pub fn sigprocmask(how: i32, set: ?*const SigSet, oldset: ?*SigSet) SyscallError!void {
    const ret = primitive.syscall4(syscalls.SYS_RT_SIGPROCMASK,
        @bitCast(@as(isize, how)),
        if (set) |s| @intFromPtr(s) else 0,
        if (oldset) |s| @intFromPtr(s) else 0,
        @sizeOf(SigSet)
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// sigreturn is used by the kernel trampoline.
pub fn sigreturn() noreturn {
    _ = primitive.syscall0(syscalls.SYS_RT_SIGRETURN);
    unreachable;
}

/// Get pending signals
pub fn sigpending(set: *SigSet) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_RT_SIGPENDING,
        @intFromPtr(set),
        @sizeOf(SigSet)
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set alternate signal stack
pub fn sigaltstack(ss: ?*const uapi.signal.StackT, old_ss: ?*uapi.signal.StackT) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_SIGALTSTACK,
        if (ss) |s| @intFromPtr(s) else 0,
        if (old_ss) |s| @intFromPtr(s) else 0
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}
