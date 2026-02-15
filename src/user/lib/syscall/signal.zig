const builtin = @import("builtin");
const primitive = @import("primitive.zig");
const uapi = primitive.uapi;
const syscalls = uapi.syscalls;

/// Signal restorer trampoline -- invokes sys_rt_sigreturn when a signal handler returns.
/// Exported so the linker can resolve it; address is placed in LR (aarch64) or on stack (x86_64).
export fn __restore_rt() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\mov x8, #139  // SYS_RT_SIGRETURN
            \\svc #0
            \\brk #0
        ),
        .x86_64 => asm volatile (
            \\mov $15, %%rax  // SYS_RT_SIGRETURN
            \\syscall
            \\ud2
        ),
        else => @compileError("unsupported arch"),
    }
}

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
    // Auto-provide restorer when installing a real handler (not SIG_DFL/SIG_IGN)
    var modified_act: SigAction = undefined;
    const act_to_use: ?*const SigAction = if (act) |a| blk: {
        modified_act = a.*;
        if (modified_act.restorer == 0 and modified_act.handler > 1) {
            modified_act.restorer = @intFromPtr(&__restore_rt);
            modified_act.flags |= uapi.signal.SA_RESTORER;
        }
        break :blk &modified_act;
    } else null;

    const ret = primitive.syscall4(syscalls.SYS_RT_SIGACTION,
        @bitCast(@as(isize, sig)),
        if (act_to_use) |a| @intFromPtr(a) else 0,
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

// =============================================================================
// Additional RT Signal Syscalls
// =============================================================================

/// Get pending signals (rt_sigpending)
pub fn rt_sigpending(set: *u64) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_RT_SIGPENDING, @intFromPtr(set), 8);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Suspend execution until signal arrives (rt_sigsuspend)
/// Note: Always returns EINTR on success per POSIX
pub fn rt_sigsuspend(mask: *const u64) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_RT_SIGSUSPEND, @intFromPtr(mask), 8);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Phase 20: Signal Handling Extensions
// =============================================================================

/// Timespec structure for signal timeout
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// SigInfo structure for rt_sigtimedwait/rt_sigqueueinfo (128 bytes, Linux ABI)
/// Reuses the same layout as waitid's SigInfo from process.zig
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

/// Signal info codes
pub const SI_USER: i32 = 0;
pub const SI_QUEUE: i32 = -1;
pub const SI_TIMER: i32 = -2;
pub const SI_TKILL: i32 = -6;

/// TIMER_ABSTIME flag for clock_nanosleep
pub const TIMER_ABSTIME: u32 = 1;

/// Clock IDs
pub const CLOCK_REALTIME: usize = 0;
pub const CLOCK_MONOTONIC: usize = 1;

/// rt_sigtimedwait - Synchronously wait for a queued signal
///
/// Waits for one of the signals in `set` to become pending.
/// Returns the signal number on success.
/// Returns EAGAIN on timeout.
pub fn rt_sigtimedwait(set: *const SigSet, info: ?*SigInfo, timeout: ?*const Timespec) SyscallError!u32 {
    const ret = primitive.syscall4(
        syscalls.SYS_RT_SIGTIMEDWAIT,
        @intFromPtr(set),
        if (info) |i| @intFromPtr(i) else 0,
        if (timeout) |t| @intFromPtr(t) else 0,
        @sizeOf(SigSet),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(ret);
}

/// rt_sigqueueinfo - Send a signal with data to a process
///
/// Sends signal `sig` with associated siginfo_t data to process `pid`.
/// si_code in info must be negative (SI_QUEUE or similar) -- kernel rejects si_code >= 0.
pub fn rt_sigqueueinfo(pid: i32, sig: i32, info: *const SigInfo) SyscallError!void {
    const ret = primitive.syscall3(
        syscalls.SYS_RT_SIGQUEUEINFO,
        @bitCast(@as(isize, pid)),
        @bitCast(@as(isize, sig)),
        @intFromPtr(info),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// rt_tgsigqueueinfo - Send a signal with data to a specific thread
pub fn rt_tgsigqueueinfo(tgid: i32, tid: i32, sig: i32, info: *const SigInfo) SyscallError!void {
    const ret = primitive.syscall4(
        syscalls.SYS_RT_TGSIGQUEUEINFO,
        @bitCast(@as(isize, tgid)),
        @bitCast(@as(isize, tid)),
        @bitCast(@as(isize, sig)),
        @intFromPtr(info),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// clock_nanosleep - High-resolution sleep with clock selection
///
/// Sleeps for the specified duration using the given clock source.
/// With TIMER_ABSTIME flag, sleeps until the absolute time is reached.
pub fn clock_nanosleep(clockid: usize, flags: u32, req: *const Timespec, rem: ?*Timespec) SyscallError!void {
    const ret = primitive.syscall4(
        syscalls.SYS_CLOCK_NANOSLEEP,
        clockid,
        flags,
        @intFromPtr(req),
        if (rem) |r| @intFromPtr(r) else 0,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}
